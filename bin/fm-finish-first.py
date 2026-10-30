#!/usr/bin/env python3
"""WIP admission; queue ordering belongs to the existing placement queue."""
import datetime
import re
import json
import pathlib
import sys


def fields(line):
    """Decode the flat TOON row, including JSON-escaped quoted scalars."""
    values = []
    while line:
        if line.startswith('"'):
            value, end = json.JSONDecoder().raw_decode(line)
            line = line[end:]
        else:
            value, sep, rest = line.partition(',')
            line = sep + rest
        values.append(str(value))
        if line and not line.startswith(','):
            raise ValueError('malformed tasks-axi row')
        line = line[1:]
    return values


def read_rows(text):
    lines = text.splitlines()
    headers = [(i, re.fullmatch(r'tasks\[(\d+)\]\{([^}]+)\}:', line))
               for i, line in enumerate(lines)]
    headers = [(i, match) for i, match in headers if match]
    if not headers:
        if lines and lines[0] == 'count: 0':
            return {'present': True, 'records': []}
        raise ValueError('tasks-axi returned no complete task list')
    if len(headers) != 1:
        raise ValueError('ambiguous tasks-axi task list')
    index, match = headers[0]
    count = int(match[1])
    names = match[2].split(',')
    required = {'id', 'state', 'kind', 'blocked', 'held', 'created', 'priority'}
    if not required.issubset(names) or len(set(names)) != len(names):
        raise ValueError('tasks-axi returned an unsupported task schema')
    rows = []
    for line in lines[index + 1:index + 1 + count]:
        if not line.startswith('  '):
            raise ValueError('truncated tasks-axi task list')
        values = fields(line[2:])
        if len(values) != len(names):
            raise ValueError('malformed tasks-axi task row')
        row = dict(zip(names, values))
        if row['blocked'] not in ('yes', 'no') or row['held'] not in ('yes', 'no'):
            raise ValueError('invalid backlog hold or dependency state')
        if row['state'] not in ('queued', 'in_flight', 'done'):
            raise ValueError('invalid backlog state')
        priority = row['priority']
        if priority != '-' and not re.fullmatch(r'[0-9]+', priority):
            raise ValueError('invalid backlog priority')
        row['priority'] = 2 if priority == '-' else int(priority)
        if row['created'] != '-':
            datetime.date.fromisoformat(row['created'])
        row['order'] = (row['created'] if row['created'] != '-' else '', len(rows))
        rows.append(row)
    if len(rows) != count or len({row['id'] for row in rows}) != count:
        raise ValueError('truncated or duplicate tasks-axi task list')
    return {'present': True, 'records': [dict(r, structured=True, impact='P'+str(r['priority']), hold_reason=r['held']=='yes', unresolved_blocker_ids=['blocked'] if r['blocked']=='yes' else []) for r in rows]}


def admit(backlog, task_id, config_dir):
    if not backlog.get('present'):
        raise ValueError('backlog missing')
    rows = [row for row in backlog['records'] if row.get('structured')]
    target = next((row for row in rows if row['id'] == task_id), None)
    if target is None:
        raise ValueError(f'backlog item {task_id} missing')
    if target.get('hold_reason') or target.get('unresolved_blocker_ids'):
        print(f'finish-first: {task_id} is held or blocked')
        return 1
    if target['state'] == 'in_flight':
        print(f'finish-first: resume allowed for {task_id}')
        return 0
    if target['state'] != 'queued':
        raise ValueError(f'{task_id} is not queued or in flight')
    if target['impact'] == 'P0':
        print(f'finish-first: P0 start allowed for {task_id}')
        return 0
    placement = config_dir / 'crew-placement.json'
    if placement.exists() or placement.is_symlink():
        if placement.is_symlink() or not placement.is_file():
            raise ValueError('crew-placement.json must be a regular file')
        profile = json.loads(placement.read_text())
        cap = profile.get('max_crew') if isinstance(profile, dict) else None
        if type(cap) is not int or cap <= 0:
            raise ValueError('crew-placement.json max_crew must be a positive integer')
        inflight = [r for r in rows if r['state'] == 'in_flight'
                    and r['kind'] not in ('captain', 'secondmate', 'public-followup', 'program')]
        if len(inflight) >= 2 * cap:
            available = [r for r in inflight if not r.get('hold_reason')
                         and not r.get('unresolved_blocker_ids')]
            action = ('finish ' + available[0]['id'] + ' first') if available else 'all open work is held or blocked'
            print(f'finish-first: WIP {len(inflight)}/{2 * cap}; {action}')
            return 1
    print(f'finish-first: start allowed for {task_id}')
    return 0


if __name__ == '__main__':
    try:
        backlog = read_rows(sys.stdin.read()) if '--native' in sys.argv else json.load(sys.stdin)
        sys.exit(admit(backlog, sys.argv[1], pathlib.Path(sys.argv[2])))
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print(f'finish-first: {exc}', file=sys.stderr)
        sys.exit(2)
