#!/usr/bin/env python3
"""Append-only backlog transition history and local-calendar daily flow report.

The journal is data/flow-history.jsonl, bounded at 16 MiB. Writers refuse
before mutation if the journal cannot accept an attempt; a successful mutation
whose receipt cannot be written leaves an unmatched attempt, making reports
unknown. Receipts preserve only action, task id, priority and UTC timestamp,
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
    if stream.tell() + len(payload.encode()) >= LIMIT:
        raise ValueError('journal reached 16 MiB; preserve it and arrange archival')
    stream.write(payload)
    stream.flush()
    os.fsync(stream.fileno())


def begin(path, task_id, priority, landing):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', task_id):
        raise ValueError('invalid task id')
    if landing not in ('none', 'merge', 'local'):
        raise ValueError('invalid landing evidence')
    with journal(path, True) as stream:
        if os.fstat(stream.fileno()).st_size == 0:
            append(stream, {'type': 'coverage', 'version': 1, 'timestamp': now()})
        token = uuid.uuid4().hex
        append(stream, dict(type='attempt', token=token, task_id=task_id,
                            priority=priority, landing=landing, timestamp=now()))
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
        rows = [json.loads(line) for line in stream]
        if any(not isinstance(row, dict) for row in rows):
            raise ValueError('journal rows must be objects')
        attempt = next((r for r in rows if r.get('type') == 'attempt' and r.get('token') == token), None)
        if attempt is None or attempt['task_id'] != task_id:
            raise ValueError('missing journal attempt')
        if any(r.get('token') == token and r.get('type') != 'attempt' for r in rows):
            raise ValueError('journal attempt already completed')
        append(stream, dict(type='transition' if changed else 'complete', token=token,
                            action=action, task_id=task_id, priority=attempt['priority'],
                            landing=attempt.get('landing', 'none'), timestamp=now(), result=result))


def read_history(path):
    with journal(path) as stream:
        rows = [json.loads(line) for line in stream]
    if any(not isinstance(row, dict) for row in rows):
        raise ValueError('journal rows must be objects')
    if not rows or rows[0].get('type') != 'coverage' or rows[0].get('version') != 1:
        raise ValueError('coverage header missing')
    attempts = {}
    completed = set()
    events = []
    for row in rows:
        stamp = dt.datetime.strptime(row['timestamp'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)
        row['stamp'] = stamp
        row['day'] = stamp.astimezone(AEST).date()
        if stamp < rows[0].get('stamp', stamp):
            raise ValueError('journal row precedes coverage')
        if row['type'] == 'coverage':
            if row is not rows[0]:
                raise ValueError('duplicate coverage header')
            continue
        token = row['token']
        if not isinstance(token, str) or not token:
            raise ValueError('invalid journal token')
        if row['type'] == 'attempt':
            if token in attempts:
                raise ValueError('duplicate attempt')
            if row.get('landing', 'none') not in ('none', 'merge', 'local'):
                raise ValueError('invalid landing evidence')
            attempts[token] = row
        elif row['type'] in ('transition', 'complete'):
            if token not in attempts or token in completed:
                raise ValueError('invalid journal receipt')
            attempt = attempts[token]
            if stamp < attempt['stamp']:
                raise ValueError('journal receipt precedes attempt')
            if row['task_id'] != attempt['task_id'] or row['priority'] != attempt['priority']:
                raise ValueError('journal receipt identity mismatch')
            if row['action'] not in ('start', 'done', 'reopen'):
                raise ValueError('invalid journal action')
            landing = row.get('landing', attempt.get('landing', 'none'))
            if landing != attempt.get('landing', 'none'):
                raise ValueError('journal receipt landing mismatch')
            if row['action'] != 'done' and landing != 'none':
                raise ValueError('landing evidence belongs only to completion')
            row['landing'] = landing
            completed.add(token)
            if row['type'] == 'transition':
                if row['result'] != 0:
                    raise ValueError('failed transition receipt')
                events.append(row)
        else:
            raise ValueError('unsupported journal row')
    if set(attempts) != completed:
        raise ValueError('incomplete transition attempt; history may have a gap')
    return rows[0]['day'] + dt.timedelta(days=1), events


def report(path, day):
    try:
        coverage, events = read_history(path)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'flow_history: unknown ({exc})')
        print('stop_starting: unknown')
        return
    print(f'flow_history: AEST; complete coverage from {coverage}; wrapper/lifecycle transitions only')
    daily = {}
    for row in events:
        items = daily.setdefault(row['day'], {
            'start': set(), 'finished': set(), 'closed-not-landed': set(), 'reopen': set()
        })
        if row['action'] == 'done':
            key = 'finished' if row['landing'] in ('merge', 'local') else 'closed-not-landed'
            items[key].add(row['task_id'])
        else:
            items[row['action']].add(row['task_id'])
    empty = {'start': set(), 'finished': set(), 'closed-not-landed': set(), 'reopen': set()}
    def counts(value):
        return daily.get(value, empty)
    today = dt.datetime.now(dt.timezone.utc).astimezone(AEST).date()
    if day < coverage or day >= today:
        print(f'{day} unknown (outside complete journal coverage)')
    else:
        items = counts(day)
        print(f"{day} finished={len(items['finished'])} closed-not-landed={len(items['closed-not-landed'])} "
              f"started={len(items['start'])} reopened={len(items['reopen'])}")
        for key, label in (('finished', 'finished'), ('closed-not-landed', 'closed-not-landed'),
                           ('start', 'started'), ('reopen', 'reopened')):
            print(f"  {label}: {', '.join(sorted(items[key])) or '-'}")
    previous = day - dt.timedelta(days=1)
    if previous < coverage or day >= today:
        signal = 'unknown'
    else:
        signal = 'yes' if all(len(counts(d)['start']) > len(counts(d)['finished'])
                              for d in (previous, day)) else 'no'
    print(f'stop_starting: {signal}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', required=True, type=Path)
    commands = parser.add_subparsers(dest='command', required=True)
    start = commands.add_parser('begin')
    start.add_argument('task_id')
    start.add_argument('priority', type=int)
    start.add_argument('landing', choices=['none', 'merge', 'local'])
    end = commands.add_parser('finish')
    end.add_argument('token')
    end.add_argument('action', choices=['start', 'done', 'reopen'])
    end.add_argument('task_id')
    end.add_argument('result', type=int)
    show = commands.add_parser('report')
    show.add_argument('--date', type=dt.date.fromisoformat,
                      help='completed AEST date; default yesterday')
    args = parser.parse_args()
    path = args.data / 'flow-history.jsonl'
    try:
        if args.command == 'begin':
            begin(path, args.task_id, args.priority, args.landing)
        elif args.command == 'finish':
            finish(path, args.token, args.action, args.task_id, args.result, sys.stdin.read())
        else:
            day = args.date or dt.datetime.now(dt.timezone.utc).astimezone(AEST).date() - dt.timedelta(days=1)
            report(path, day)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'flow-history: {exc}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
