#!/usr/bin/env python3
"""Admission policy for fm-finish-first.sh's tasks-axi list output."""
import datetime
import json
import pathlib
import re
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
            return []
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
        row['priority'] = 3 if priority == '-' else int(priority)
        if row['created'] != '-':
            datetime.date.fromisoformat(row['created'])
        row['order'] = (row['created'] if row['created'] != '-' else '', len(rows))
        rows.append(row)
    if len(rows) != count or len({row['id'] for row in rows}) != count:
        raise ValueError('truncated or duplicate tasks-axi task list')
    return rows


def admit(rows, task_id, cap_file):
    cap = None
    if cap_file.is_symlink():
        raise ValueError('crew-slot-cap must be a regular file')
    if cap_file.exists():
        if not cap_file.is_file():
            raise ValueError('crew-slot-cap must be a regular file')
        raw = cap_file.read_text()
        if not re.fullmatch(r'[1-9][0-9]{0,8}\n?', raw):
            raise ValueError('crew-slot-cap must be a positive decimal integer')
        cap = int(raw)
    else:
        placement = cap_file.with_name('crew-placement.json')
        if placement.exists() or placement.is_symlink():
            if placement.is_symlink() or not placement.is_file():
                raise ValueError('crew-placement.json must be a regular file')
            profile = json.loads(placement.read_text())
            cap = profile.get('max_crew') if isinstance(profile, dict) else None
            if type(cap) is not int or cap <= 0:
                raise ValueError('crew-placement.json max_crew must be a positive integer')
    target = next((row for row in rows if row['id'] == task_id), None)
    if target is None:
        raise ValueError(f'backlog item {task_id} missing')
    if target['held'] == 'yes' or target['blocked'] == 'yes':
        print(f'finish-first: {task_id} is held or blocked')
        return 1
    if target['state'] == 'in_flight':
        print(f'finish-first: resume allowed for {task_id}')
        return 0
    if target['state'] != 'queued':
        raise ValueError(f'{task_id} is not queued or in flight')
    work = [r for r in rows if r['kind'] not in ('captain', 'secondmate', 'public-followup', 'program')]
    inflight = [r for r in work if r['state'] == 'in_flight']
    if cap is not None and len(inflight) >= 2 * cap:
        oldest = min(inflight, key=lambda r: (r['priority'], r['order']))
        print(f"finish-first: WIP {len(inflight)}/{2 * cap}; finish {oldest['id']} first")
        return 1
    older = [r for r in work if r['id'] != task_id
             and r['state'] in ('queued', 'in_flight')
             and r['held'] == 'no' and r['blocked'] == 'no'
             and (r['priority'] < target['priority']
                  or (r['priority'] == target['priority'] and r['order'] < target['order']))]
    if older:
        first = min(older, key=lambda r: (r['priority'], r['order']))
        print(f"finish-first: finish {first['id']} first (priority {first['priority']}, {first['state']})")
        return 1
    print(f'finish-first: start allowed for {task_id}')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(admit(read_rows(sys.stdin.read()), sys.argv[1], pathlib.Path(sys.argv[2])))
    except (ValueError, OSError) as exc:
        print(f'finish-first: {exc}', file=sys.stderr)
        sys.exit(2)
