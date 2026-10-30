#!/usr/bin/env python3
"""Append-only backlog transition history and local-calendar daily flow report.

The journal is data/flow-history.jsonl, bounded at 16 MiB. Recording failures
warn without blocking lifecycle mutations. Unmatched attempts and malformed rows
make affected days unknown, while later valid days remain reportable. Receipts preserve action, task id, kind, priority and UTC timestamp,
never task bodies. A crash, malformed row, oversized journal, or incomplete
attempt is reported as unknown; this reader never repairs or truncates history.
The first recording day is partial, so only subsequent complete calendar days can
produce counts. Direct tasks-axi calls and manual backlog edits are outside
this history; use fm-tasks-axi.sh or the lifecycle helpers for transitions.
"""
import argparse
import contextlib
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
import uuid

LIMIT = 16 * 1024 * 1024
AEST = dt.timezone(dt.timedelta(hours=10), 'AEST')


def now():
    return dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


@contextlib.contextmanager
def journal(path, write=False):
    flags = (os.O_RDWR | os.O_CREAT) if write else os.O_RDONLY
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError('journal must be a regular, single-linked file')
        deadline = time.monotonic() + 2
        while True:
            try:
                fcntl.flock(fd, (fcntl.LOCK_EX if write else fcntl.LOCK_SH) | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ValueError('journal lock timed out')
                time.sleep(.05)
        if os.fstat(fd).st_size >= LIMIT:
            raise ValueError('journal reached 16 MiB; preserve it and arrange archival')
        with os.fdopen(fd, 'r+' if write else 'r', encoding='utf-8', closefd=False) as stream:
            yield stream
    finally:
        os.close(fd)


def append(stream, row):
    payload = json.dumps(row, separators=(',', ':')) + '\n'
    stream.seek(0, os.SEEK_END)
    size = stream.tell()
    if size and os.pread(stream.fileno(), 1, size - 1) != b'\n':
        stream.write('\n')
    if stream.tell() + len(payload.encode()) >= LIMIT:
        raise ValueError('journal reached 16 MiB; preserve it and arrange archival')
    stream.write(payload)
    stream.flush()
    os.fsync(stream.fileno())


def begin(path, task_id, priority, landing, kind, serves):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', task_id):
        raise ValueError('invalid task id')
    if landing not in ('none', 'merge', 'local', 'report'):
        raise ValueError('invalid landing evidence')
    with journal(path, True) as stream:
        if os.fstat(stream.fileno()).st_size == 0:
            append(stream, {'type': 'coverage', 'version': 1, 'timestamp': now()})
        token = uuid.uuid4().hex
        append(stream, dict(type='attempt', token=token, task_id=task_id,
                            priority=priority, kind=kind, serves=serves, landing=landing, timestamp=now()))
    print(token)


def finish(path, token, action, task_id, result, output):
    changed = False
    if result == 0:
        if output.lstrip().startswith('{'):
            response = json.loads(output)
            if response.get('ok') is not True or response.get('action') != action:
                raise ValueError('unsupported tasks-axi mutation receipt')
            if response.get('task', {}).get('id') != task_id:
                raise ValueError('tasks-axi receipt task mismatch')
            changed = not response.get('already', False)
        else:
            first = output.splitlines()[0] if output else ''
            if not first.startswith(f'ok: {action} {task_id} '):
                raise ValueError('unsupported tasks-axi mutation receipt')
            changed = not first.startswith(f'ok: {action} {task_id} already')
    with journal(path, True) as stream:
        rows = []
        for line in stream:
            try:
                row = json.loads(line)
                if isinstance(row, dict): rows.append(row)
            except ValueError:
                pass
        attempt = next((r for r in rows if r.get('type') == 'attempt' and r.get('token') == token), None)
        if attempt is None or attempt['task_id'] != task_id:
            raise ValueError('missing journal attempt')
        if any(r.get('token') == token and r.get('type') != 'attempt' for r in rows):
            raise ValueError('journal attempt already completed')
        prior = [r for r in rows if r.get('type') == 'transition' and r.get('task_id') == task_id]
        reset = max((i for i, r in enumerate(prior) if r.get('action') in ('start', 'reopen')), default=-1)
        already_landed = any(r.get('action') == 'done' and r.get('landing', 'none') != 'none' for r in prior[reset + 1:])
        landed = action == 'done' and attempt.get('landing', 'none') != 'none' and result == 0 and not already_landed
        append(stream, dict(type='transition' if changed or landed else 'complete', token=token,
                            action=action, task_id=task_id, priority=attempt['priority'], kind=attempt.get('kind', 'task'),
                            serves=attempt.get('serves', ''), landing=attempt.get('landing', 'none'), timestamp=now(), result=result))


def read_history(path, grace=0):
    with journal(path) as stream:
        lines = list(stream)
    rows = []
    for line in lines:
        try:
            row = json.loads(line)
            stamp = dt.datetime.strptime(row['timestamp'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)
            row.update(stamp=stamp, day=stamp.astimezone(AEST).date())
        except (ValueError, KeyError, TypeError):
            row = None
        rows.append(row)
    if not rows or not rows[0] or rows[0].get('type') != 'coverage' or rows[0].get('version') != 1:
        raise ValueError('coverage header missing')
    attempts, completed, events, unknown = {}, set(), [], set()
    for index, row in enumerate(rows[1:], 1):
        if row is None:
            # A torn line has no trusted date. Bound its uncertainty by adjacent
            # valid timestamps; an open tail is unknown through today.
            before = next(r['day'] for r in reversed(rows[:index]) if r)
            after = next((r['day'] for r in rows[index + 1:] if r), dt.datetime.now(AEST).date())
            unknown.update(before + dt.timedelta(days=n) for n in range(max(0, (after-before).days) + 1))
            continue
        try:
            if row['stamp'] < rows[0]['stamp']:
                raise ValueError('row precedes coverage')
            token = row['token']
            if not isinstance(token, str) or not token:
                raise ValueError('invalid token')
            if row['type'] == 'attempt':
                if token in attempts:
                    unknown.add(attempts[token]['day'])
                    raise ValueError('duplicate attempt')
                attempts[token] = row
            elif row['type'] in ('transition', 'complete'):
                attempt = attempts[token]
                if token in completed or row['stamp'] < attempt['stamp']:
                    unknown.add(attempt['day'])
                    raise ValueError('invalid receipt order')
                if row['task_id'] != attempt['task_id'] or row['priority'] != attempt['priority']:
                    raise ValueError('receipt identity mismatch')
                if row['action'] not in ('start', 'done', 'reopen'):
                    raise ValueError('invalid action')
                landing = row.get('landing', attempt.get('landing', 'none'))
                if landing not in ('none', 'merge', 'local', 'report') or landing != attempt.get('landing', 'none'):
                    raise ValueError('invalid landing')
                if row['action'] != 'done' and landing != 'none':
                    raise ValueError('landing only belongs to completion')
                if row['type'] == 'transition' and row['result'] != 0:
                    raise ValueError('failed transition')
                row['landing'] = landing
                if row.get('serves', '') != attempt.get('serves', ''):
                    raise ValueError('receipt finishing-work mismatch')
                completed.add(token)
                if row['type'] == 'transition': events.append(row)
            else:
                raise ValueError('unsupported row')
        except (ValueError, KeyError, TypeError):
            unknown.add(row['day'])
    unknown.update(row['day'] for token, row in attempts.items() if token not in completed
                   and (dt.datetime.now(dt.timezone.utc) - row['stamp']).total_seconds() >= grace)
    return rows[0]['day'] + dt.timedelta(days=1), events, unknown


def report(path, day):
    try:
        coverage, events, unknown = read_history(path)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'flow_history: unknown ({exc})')
        print('stop_starting: unknown')
        return
    print(f'flow_history: AEST; complete coverage from {coverage}; wrapper/lifecycle transitions only')
    if unknown:
        print('history_warning: unknown days ' + f'{min(unknown)}..{max(unknown)} ({len(unknown)} days)')
    daily = {}
    for row in events:
        if row.get('serves'):
            continue
        items = daily.setdefault(row['day'], {
            'start': set(), 'finished': set(), 'closed-not-landed': set(), 'worker-start': set()
        })
        if row['action'] == 'done':
            if row['landing'] in ('merge', 'local', 'report'):
                items['finished'].add(row['task_id'])
                items['closed-not-landed'].discard(row['task_id'])
            elif row['task_id'] not in items['finished']:
                items['closed-not-landed'].add(row['task_id'])
        elif row['action'] == 'start':
            items['start'].add(row['task_id'])
            if row.get('kind', 'task') not in ('program', 'captain', 'secondmate', 'public-followup'):
                items['worker-start'].add(row['task_id'])
    empty = {'start': set(), 'finished': set(), 'closed-not-landed': set(), 'worker-start': set()}
    def counts(value):
        return daily.get(value, empty)
    today = dt.datetime.now(dt.timezone.utc).astimezone(AEST).date()
    if day < coverage or day >= today or day in unknown:
        print(f'{day} unknown (outside complete journal coverage)')
    else:
        items = counts(day)
        print(f"{day} finished={len(items['finished'])} closed-not-landed={len(items['closed-not-landed'])} "
              f"started={len(items['start'])}")
        for key, label in (('finished', 'finished'), ('closed-not-landed', 'closed-not-landed'),
                           ('start', 'started')):
            print(f"  {label}: {', '.join(sorted(items[key])) or '-'}")
    previous = day - dt.timedelta(days=1)
    if previous < coverage or day >= today or {previous, day} & unknown:
        signal = 'unknown'
    else:
        signal = 'yes' if all(len(counts(d)['worker-start']) > len(counts(d)['finished'])
                              for d in (previous, day)) else 'no'
    print('signal_basis: recorded worker starts; proven deliveries')
    print(f'stop_starting: {signal}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', required=True, type=Path)
    commands = parser.add_subparsers(dest='command', required=True)
    start = commands.add_parser('begin')
    start.add_argument('task_id')
    start.add_argument('priority', type=int)
    start.add_argument('landing', choices=['none', 'merge', 'local', 'report'])
    start.add_argument('--kind', default='task')
    start.add_argument('--serves', default='')
    end = commands.add_parser('finish')
    end.add_argument('token')
    end.add_argument('action', choices=['start', 'done', 'reopen'])
    end.add_argument('task_id')
    end.add_argument('result', type=int)
    commands.add_parser('health')
    show = commands.add_parser('report')
    show.add_argument('--date', type=dt.date.fromisoformat,
                      help='completed AEST date; default yesterday')
    args = parser.parse_args()
    path = args.data / 'flow-history.jsonl'
    try:
        if args.command == 'begin':
            begin(path, args.task_id, args.priority, args.landing, args.kind, args.serves)
        elif args.command == 'finish':
            finish(path, args.token, args.action, args.task_id, args.result, sys.stdin.read())
        elif args.command == 'health':
            _, _, unknown = read_history(path, grace=60)
            if unknown:
                print('unknown flow days: ' + f'{min(unknown)}..{max(unknown)} ({len(unknown)} days)')
                return 1
        else:
            day = args.date or dt.datetime.now(dt.timezone.utc).astimezone(AEST).date() - dt.timedelta(days=1)
            report(path, day)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'flow-history: {exc}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
