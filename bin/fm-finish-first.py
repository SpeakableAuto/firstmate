#!/usr/bin/env python3
"""WIP and two-day flow admission; queue ordering belongs to placement."""
import concurrent.futures
import os
import signal
import subprocess
import time
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
        serves = re.search(r'\(serves:\s*([A-Za-z0-9][A-Za-z0-9._-]*)\)', row.get('title', ''))
        row['serves'] = serves[1] if serves else None
        if row['created'] != '-':
            datetime.date.fromisoformat(row['created'])
        row['order'] = (row['created'] if row['created'] != '-' else '', len(rows))
        rows.append(row)
    if len(rows) != count or len({row['id'] for row in rows}) != count:
        raise ValueError('truncated or duplicate tasks-axi task list')
    return {'present': True, 'records': [dict(r, structured=True, impact='P'+str(r['priority']), hold_reason=r['held']=='yes', unresolved_blocker_ids=['blocked'] if r['blocked']=='yes' else []) for r in rows]}


def bounded_read(command):
    """Read a provider without leaving its subprocesses behind on timeout."""
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, start_new_session=True) as process:
        try:
            output, _ = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise ValueError('activity read timed out')
        if process.returncode:
            raise ValueError('activity read failed')
        return output


def activity(row, state, now):
    """Only positive evidence in the preceding 72 hours charges an open job."""
    task = row['id']
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', task):
        return 'unknown'
    try:
        status = state / (task + '.status')
        if status.is_file() and not status.is_symlink():
            with status.open('rb') as stream:
                stream.seek(max(0, status.stat().st_size - 262144))
                stamps = re.findall(rb'\[at=(\d+)\]', stream.read())
            if any(0 <= now - int(stamp) <= 72 * 3600 for stamp in stamps):
                return 'active'
        meta = state / (task + '.meta')
        metadata = meta.read_text() if meta.is_file() and not meta.is_symlink() else ''
        unknown = False
        if metadata:
            try:
                live = bounded_read(['bash', str(pathlib.Path(__file__).with_name('fm-flow-live.sh')), str(state), task])
                if live.strip() == '1':
                    return 'active'
            except (ValueError, OSError):
                unknown = True
        links = str(row.get('pr_url') or row.get('links') or '') + '\n' + metadata
        pr = re.search(r'https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)(?![0-9])', links)
        if pr:
            try:
                output = bounded_read(['gh-axi', 'api', f'/repos/{pr[1]}/pulls/{pr[2]}', '--jq', '.updated_at'])
                match = re.fullmatch(r'api_response:\n  body: "([^"\n]+)"\n  truncated: false\s*', output)
                if not match:
                    raise ValueError('invalid PR update response')
                updated = datetime.datetime.strptime(match[1], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
                if 0 <= now - updated <= 72 * 3600:
                    return 'active'
            except (ValueError, OSError):
                unknown = True
        return 'unknown' if unknown else 'stale'
    except OSError:
        return 'unknown'


def wip_settings(config_dir):
    mode_path = config_dir / 'finish-first-wip-mode'
    if mode_path.is_symlink():
        raise ValueError('finish-first-wip-mode must be a regular file')
    mode = mode_path.read_text().strip() if mode_path.exists() else 'warn'
    if mode not in ('warn', 'enforce'):
        raise ValueError('finish-first-wip-mode must be warn or enforce')
    placement = config_dir / 'crew-placement.json'
    if not placement.exists() and not placement.is_symlink():
        return mode, None
    if placement.is_symlink() or not placement.is_file():
        raise ValueError('crew-placement.json must be a regular file')
    profile = json.loads(placement.read_text())
    cap = profile.get('max_crew') if isinstance(profile, dict) else None
    if type(cap) is not int or cap <= 0:
        raise ValueError('crew-placement.json max_crew must be a positive integer')
    return mode, 2 * cap


def admit(backlog, task_id, config_dir, stop_starting):
    if not backlog.get('present'):
        raise ValueError('backlog missing')
    if stop_starting not in ('yes', 'no', 'unknown'):
        raise ValueError('invalid stop-starting signal')
    rows = [row for row in backlog['records'] if row.get('structured')]
    target = next((row for row in rows if row['id'] == task_id), None)
    report_only = task_id == '--report'
    if target is None and not report_only:
        raise ValueError(f'backlog item {task_id} missing')
    if not report_only:
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
    # A recorded link, never a task-name convention, identifies finishing work.
    open_ids = {r['id'] for r in rows if r['state'] == 'in_flight'}
    def finishing(row):
        return row.get('serves') in open_ids and row.get('serves') != row['id']
    if not report_only and finishing(target):
        print(f"finish-first: {task_id} serves {target['serves']}; finishing work allowed")
        return 0
    mode, cap = wip_settings(config_dir)
    workers = [r for r in rows if r['state'] == 'in_flight'
               and r['kind'] not in ('captain', 'secondmate', 'public-followup', 'program')]
    eligible = {r['id'] for r in workers if not r.get('hold_reason')
                and not r.get('unresolved_blocker_ids') and not finishing(r)}
    # Triage lists all stale unfinished jobs, including held/support work;
    # admission only needs activity evidence for rows eligible to charge WIP.
    candidates = [r for r in workers if report_only or r['id'] in eligible]
    candidates.sort(key=lambda r: (r.get('since') or r.get('created') or '', r['id']))
    state = pathlib.Path(os.environ.get('FM_STATE_OVERRIDE', str(config_dir.parent / 'state')))
    now = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        states = list(pool.map(lambda row: activity(row, state, now), candidates))
    finishable = [r for r, status in zip(candidates, states) if status == 'active' and r['id'] in eligible]
    stale = [r['id'] for r, status in zip(candidates, states) if status == 'stale']
    unknown = [r['id'] for r, status in zip(candidates, states) if status == 'unknown']
    if unknown:
        print('finish-first: activity unavailable (not counted): ' + ', '.join(unknown), file=sys.stderr)
    over_cap = cap is not None and len(finishable) >= cap
    oldest = ', '.join(r['id'] for r in finishable)
    if report_only:
        print(f'WIP over cap ({len(finishable)} of {cap})' if over_cap else
              f'WIP active: {len(finishable)}; cap: {cap if cap is not None else "off"}')
        print(f'WIP mode: {mode}; oldest active: {oldest or "-"}')
        print("stale, for Zac's triage: " + (', '.join(stale) or '-'))
        if unknown:
            print('activity unavailable, for triage: ' + ', '.join(unknown))
        return 0
    if over_cap:
        prefix = 'warning: ' if mode == 'warn' else ''
        print(f'finish-first: {prefix}WIP {len(finishable)}/{cap}; oldest active: {oldest}')
        if mode == 'enforce':
            return 1
    if stop_starting == 'yes' and finishable:
        first = min(finishable, key=lambda row: int(row['impact'][1:]))
        if int(target['impact'][1:]) >= int(first['impact'][1:]):
            print(f"finish-first: two-day stop; finish {first['id']} first ({first['impact']}, in_flight)")
            return 1
    print(f'finish-first: start allowed for {task_id}')
    return 0


if __name__ == '__main__':
    try:
        backlog = read_rows(sys.stdin.read()) if '--native' in sys.argv else json.load(sys.stdin)
        sys.exit(admit(backlog, sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]))
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print(f'finish-first: {exc}', file=sys.stderr)
        sys.exit(2)
