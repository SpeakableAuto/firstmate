#!/usr/bin/env python3
"""Report overdue independently cleared PRs, never merge them.

Armed via fm-clear-unmerged-check.sh; uses one bounded gh-axi GraphQL list per
registered GitHub repository (100 PRs, 100 paths per PR; incomplete reads refuse).
Registry names follow fm-project-mode.sh; origin resolves each registered clone.
Local-only and Gerrit projects are excluded through that script's public interface.
The optional config/clear-unmerged-skip-repos lists owner/repo or host/owner/repo,
one per line, with # comments. Registry rows naming Michael are also excluded.
No inference about ownership is made from an organization name.

A report in data/*/report.md names a PR when its text contains the full PR URL
and head SHA. The latest such report (by mtime) decides: it must have a first
Markdown heading starting with '# CLEAR' as a whole word; a later non-CLEAR
review at the same head blocks the alert. Report time is the file mtime only;
a future mtime is clamped to the first poll that saw it, retained while that
mtime is unchanged. The clock starts at the later of that time and the PR
creation/latest force-push/head push.
GitHub often omits pushedDate; updatedAt at the first observation of each head
is then a conservative upper bound on head-change time. This can delay the
initial alert; subsequent unrelated PR activity does not keep resetting it.
A changed SHA without a matching CLEAR cannot alert. Exactly two hours is not
more than two hours. This is an alert, not a grant of merge authority.

Carve-out declarations are honored and never override fm-pr-lint.py's classifier
on body, paths and added code. Eligible overdue PRs require a complete bounded
gh-axi diff plus a head recheck; missing evidence refuses. Malformed declarations refuse. All non-Done
captain holds are read through fm-tasks-axi.sh, including URL-linked backlog
rows and tasks bound by state/*.meta pr= or a matching review task id.

state/.clear-unmerged.json stores schema=1, alerted PR+head identities, observed
head clocks (pruned per repository after a complete PR list), clamped future
report times, and the last diagnostic for repeat suppression. A nonblocking flock serializes checks.
A failed project, repository or PR read is reported and skipped; the remaining
items are still evaluated, and the failed item is never marked alerted.
At most one new alert per pass keeps watcher output bounded; subsequent polls
advance through the remaining candidates. Disarming retains this history.
The entire scan is bounded to min(20, FM_CHECK_TIMEOUT-2) seconds, with a 10s
per-command cap. Budget/forge/registry/hold failures report missing evidence;
they never mark a PR alerted. A test-only FM_CLEAR_UNMERGED_NOW freezes age
calculation, never the real-time budget. No credentials or shell code are read.
"""
import base64
import datetime
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('pr_lint', BIN / 'fm-pr-lint.py')
LINT = importlib.util.module_from_spec(spec)
spec.loader.exec_module(LINT)
SLUG = r'[A-Za-z0-9_.-]+'
URL = re.compile(r'https://[A-Za-z0-9.-]+/'+SLUG+'/'+SLUG+r'/pull/[1-9][0-9]*(?![A-Za-z0-9_/?#=-])')
SHA = re.compile(r'(?<![a-fA-F0-9])[a-fA-F0-9]{40}(?![a-fA-F0-9])')


class Unavailable(Exception):
    pass


ITEM_ERRORS = (Unavailable, OSError, ValueError, KeyError, TypeError, IndexError, AttributeError)


class Poll:
    def __init__(self):
        self.home = Path(os.environ.get('FM_HOME', BIN.parent)).resolve()
        for field in ('state', 'data', 'config', 'projects'):
            setattr(self, field, Path(os.environ.get('FM_'+field.upper()+'_OVERRIDE', self.home/field)))
        timeout = int(os.environ.get('FM_CHECK_TIMEOUT', '30'))
        if timeout < 3:
            raise Unavailable('FM_CHECK_TIMEOUT must be at least 3 seconds')
        self.deadline = time.monotonic() + min(20, timeout-2)
        self.now = time.time()
        if os.environ.get('FM_TEST_SEAM') == '1':
            self.now = int(os.environ.get('FM_CLEAR_UNMERGED_NOW', self.now))

    def remaining(self):
        left = self.deadline-time.monotonic()
        if left <= 0:
            raise Unavailable('scan budget exhausted; retry or reduce registered repository count')
        return min(10, left)

    def run(self, args):
        bound = self.remaining()
        with subprocess.Popen([str(a) for a in args], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, start_new_session=True) as proc:
            try:
                out, err = proc.communicate(timeout=bound)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
                raise Unavailable(f'budget exhausted reading {Path(args[0]).name}; no eligibility established')
        if proc.returncode or re.search(r'^\s*(?:error:|truncated: true)', out, re.M):
            # Do not echo arbitrary tool stderr: it can contain private server data.
            raise Unavailable(f'{Path(args[0]).name} read unavailable; check access and complete output')
        return out

    def read(self, path):
        self.remaining()
        if path.stat().st_size > 2*1024*1024:
            raise Unavailable(f'{path} exceeds the 2 MiB read bound')
        return path.read_text()

    def repos(self, errors):
        skip_file = self.config/'clear-unmerged-skip-repos'
        skipped = set()
        if skip_file.exists():
            for line in self.read(skip_file).splitlines():
                line = line.split('#', 1)[0].strip().lower()
                if not line:
                    continue
                if not re.fullmatch(r'(?:[a-z0-9.-]+/)?'+SLUG+'/'+SLUG, line):
                    raise Unavailable('invalid config/clear-unmerged-skip-repos; use owner/repo or host/owner/repo')
                skipped.add(line)
        repos = set()
        for row in self.read(self.data/'projects.md').splitlines():
            if not row.startswith('- '):
                continue
            name = re.split(r' \[| - ', row[2:], maxsplit=1)[0].strip()
            try:
                if not name or name in ('.', '..') or '/' in name:
                    raise Unavailable('invalid project registry name')
                if re.search(r'\bMichael\b', row, re.I):
                    continue
                mode = self.run([BIN/'fm-project-mode.sh', name]).strip()
                forge = self.run([BIN/'fm-project-mode.sh', '--forge', name]).strip()
                if mode.split()[0] == 'local-only' or forge == 'gerrit':
                    continue
                remote = self.run(['git', '-C', self.projects/name, 'remote', 'get-url', 'origin']).strip()
                match = re.fullmatch(r'(?:https?://|ssh://git@|git@)([A-Za-z0-9.-]+)[:/]('+SLUG+'/'+SLUG+r')(?:\.git)?/?', remote)
                if not match:
                    raise Unavailable(f'unsupported origin for {name}; a GitHub origin is required')
            except (Unavailable, IndexError) as error:
                errors.append(f'{name}: {error}')
                continue
            host, repo = match.groups()
            repo = repo.removesuffix('.git')
            if repo.lower() not in skipped and (host+'/'+repo).lower() not in skipped:
                repos.add((host.lower(), repo))
        return sorted(repos)

    def reports(self, record):
        reports, previous, clamped = [], record.get('clamped', {}), {}
        for path in sorted(self.data.glob('*/report.md')):
            if len(reports) > 10000:
                raise Unavailable('report scan exceeds 10000 reports')
            text = self.read(path)
            urls = set(URL.findall(text))
            if not urls:
                continue
            heading = re.search(r'^#{1,6} .+$', LINT.prose(text), re.M)
            clear = bool(heading and re.match(r'^# CLEAR(?:\s|$)', heading[0]))
            mtime = path.stat().st_mtime
            seen = previous.get(str(path))
            if seen and seen['mtime'] == mtime:
                clamped[str(path)] = seen
            elif mtime > self.now:
                clamped[str(path)] = {'mtime': mtime, 'at': self.now}
            stamp = clamped[str(path)]['at'] if str(path) in clamped else mtime
            reports.append((path, urls, {s.lower() for s in SHA.findall(text)}, stamp, clear))
        record['clamped'] = clamped
        return reports

    def holds(self):
        try:
            out = self.run([BIN/'fm-tasks-axi.sh', 'list', '--fields', 'hold_kind,links,body', '--limit', '10000'])
        except Unavailable as error:
            raise Unavailable(f'captain hold data unavailable: {error}') from error
        count = re.search(r'^count: ([0-9]+)$', out, re.M)
        if not count:
            raise Unavailable('captain hold listing missing count; repair tasks-axi access')
        count = int(count[1])
        if count == 0 and 'tasks: 0 tasks in this backlog' in out:
            return set(), set()
        header = re.search(r'^tasks\[([0-9]+)\]\{([^}]+)\}:\n', out, re.M)
        if not header or int(header[1]) != count or count >= 10000:
            raise Unavailable('captain hold listing incomplete; compatible tasks-axi required')
        fields = header[2].split(',')
        if not {'id', 'state', 'hold_kind', 'links', 'body'} <= set(fields):
            raise Unavailable('captain hold listing missing fields')
        lines = out[header.end():].splitlines()[:count]
        rows = [toon_row(line[2:]) for line in lines if line.startswith('  ')]
        if len(rows) != count or any(len(row) != len(fields) for row in rows):
            raise Unavailable('captain hold listing malformed')
        ids, urls = set(), set()
        for values in rows:
            row = dict(zip(fields, values))
            if row['state'] != 'done' and row['hold_kind'] == 'captain':
                ids.add(row['id'])
                ids.update(re.findall(r'^Origin: ([A-Za-z0-9._-]+)\s*$', row['body'], re.M))
                urls.update(URL.findall(row['links']+' '+row['body']))
        for path in self.state.glob('*.meta'):
            lines = self.read(path).splitlines()
            decisions = [key for line in lines if line.startswith('decision_keys=')
                         for key in line.split('=', 1)[1].split(',') if key]
            held = path.stem in ids or any(key in ids or path.stem+'-decision-'+key in ids for key in decisions)
            if held:
                for line in lines:
                    if line.startswith('pr='):
                        urls.update(URL.findall(line[3:]))
        return ids, urls

    def prs(self, host, repo):
        owner, name = repo.split('/')
        query = '''query { repository(owner:%s,name:%s) {
          pullRequests(states:OPEN,first:100,orderBy:{field:CREATED_AT,direction:ASC}) {
            pageInfo { hasNextPage } nodes {
              url headRefOid body createdAt updatedAt additions
              files(first:100) { pageInfo { hasNextPage } nodes { path } }
              commits(last:1) { nodes { commit { oid pushedDate } } }
              timelineItems(last:1,itemTypes:[HEAD_REF_FORCE_PUSHED_EVENT]) {
                nodes { ... on HeadRefForcePushedEvent { createdAt } }
              }
            }
          }
        }}''' % (json.dumps(owner), json.dumps(name))
        out = self.run(['gh-axi', 'api', 'POST', 'graphql', '--hostname', host,
                        '--field', 'query='+query, '--jq', '@base64 | {chunks: [scan(".{1,1000}") | {part: .}]}'])
        try:
            # gh-axi caps raw output at 4000 and individual strings at 2000.
            # Caller-shaped 1000-byte scalar chunks preserve the entire result
            # in one list call without relying on an unsupported --full flag.
            header = re.search(r'^chunks\[([0-9]+)\]\{part\}:\n', out)
            if not header:
                raise ValueError('missing chunk envelope')
            chunks = out[header.end():].rstrip('\n').splitlines()
            if len(chunks) != int(header[1]) or any(not line.startswith('  ') for line in chunks):
                raise ValueError('incomplete chunk envelope')
            encoded = ''.join(line[2:] for line in chunks)
            result = json.loads(base64.b64decode(encoded, validate=True))
            if result.get('errors'):
                raise ValueError('GraphQL errors')
            prs = result['data']['repository']['pullRequests']
            if prs['pageInfo']['hasNextPage'] is not False:
                raise Unavailable(f'incomplete PR list for {host}/{repo}; exceeds 100 open PRs')
            if not isinstance(prs['nodes'], list):
                raise ValueError('nodes missing')
            return prs['nodes']
        except (ValueError, KeyError, TypeError) as error:
            raise Unavailable(f'gh-axi missing complete PR data for {host}/{repo}') from error

    def head_time(self, pr, record):
        pushed = pr['commits']['nodes'][-1]['commit']
        if pushed['oid'] != pr['headRefOid']:
            raise Unavailable(f"head changed during forge read for {pr['url']}; retry")
        heads = record.setdefault('heads', {})
        previous = heads.get(pr['url'], {})
        changed = epoch(pushed['pushedDate'] or pr['updatedAt'])
        if previous.get('sha') == pr['headRefOid']:
            changed = previous['changed_at']
        changed = max(changed, epoch(pr['createdAt']),
                      *[epoch(n['createdAt']) for n in pr['timelineItems']['nodes']])
        heads[pr['url']] = {'sha': pr['headRefOid'], 'changed_at': changed}
        return changed

    def candidate(self, pr, reports, held_ids, held_urls, head_time):
        url, sha = pr['url'], pr['headRefOid']
        if not URL.fullmatch(url) or not re.fullmatch('[a-f0-9]{40}', sha):
            raise Unavailable('forge returned invalid PR identity')
        if url in held_urls:
            return None
        matches = [(stamp, not clear, p) for p, urls, shas, stamp, clear in reports
                   if url in urls and sha in shas and p.parent.name not in held_ids]
        if not matches:
            return None
        # The latest review at this head decides; a re-review resets the grace period.
        clear_time, blocked, path = max(matches)
        if blocked:
            return None
        body = pr['body']
        declared = re.findall(r'^Carve-outs:\s*([^\n]*)$', LINT.prose(body), re.M | re.I)
        if declared:
            if len(declared) != 1:
                raise Unavailable(f'{url} has ambiguous Carve-outs declarations')
            categories = {c.strip().lower() for c in declared[0].split(',')}
            if categories == {'none'}:
                pass
            elif categories and categories <= set(LINT.CATEGORIES):
                return None
            else:
                raise Unavailable(f'{url} has invalid Carve-outs declaration')
        files = pr['files']
        if files['pageInfo']['hasNextPage'] is not False:
            raise Unavailable(f'incomplete changed paths for {url}; carve-out classification unavailable')
        paths = [node['path'] for node in files['nodes']]
        if LINT.carve_out_signals(body, paths):
            return None
        age = int(self.now - max(clear_time, head_time))
        if age <= 7200:
            return None
        changes = self.added_lines(pr)
        if LINT.carve_out_signals(body, paths, changes):
            return None
        identity = url+'@'+sha
        note = f'CLEAR unmerged: {url} head={sha} report={path} age={age}s; firstmate should merge via bin/fm-pr-merge.sh under existing merge guards'
        return identity, note

    def added_lines(self, pr):
        """Use the shared forge scalar contract, bound reads, and recheck the head."""
        url = pr['url']
        host, owner, repo, _, number = url.removeprefix('https://').split('/')
        diff = LINT.toon_scalar(self.run(['gh-axi', 'pr', 'diff', number,
                               '-R', owner+'/'+repo, '--hostname', host, '--full']), 'diff', 2)
        head = LINT.toon_scalar(self.run(['gh-axi', 'api', f'/repos/{owner}/{repo}/pulls/{number}',
                               '--hostname', host, '--jq', '.head.sha']), 'body', 2)
        if head != pr['headRefOid']:
            raise Unavailable(f'head changed while reading diff for {url}; retry')
        # Count additions against the list response so a shortened patch cannot
        # silently pass classification. Binary changes cannot be classified.
        added = [line[1:] for line in diff.splitlines()
                 if line.startswith('+') and not line.startswith('+++ ')]
        if (type(pr['additions']) is not int or len(added) != pr['additions']
                or re.search(r'^(?:Binary files |GIT binary patch)', diff, re.M)):
            raise Unavailable(f'incomplete added-code evidence for {url}; carve-out classification unavailable')
        return '\n'.join(added)


def toon_row(line):
    """TOON tabular scalars use JSON string escapes, not CSV quote doubling."""
    values = []
    while True:
        if line.startswith('"'):
            value, end = json.JSONDecoder().raw_decode(line)
            line = line[end:]
        else:
            value, sep, tail = line.partition(',')
            line = sep+tail
        values.append(value)
        if not line:
            return values
        if not line.startswith(','):
            raise Unavailable('captain hold row has malformed scalar separators')
        line = line[1:]


def epoch(value):
    stamp = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if stamp.tzinfo is None:
        raise Unavailable('forge timestamp missing timezone')
    return stamp.timestamp()


def save(path, record):
    fd, temp = tempfile.mkstemp(prefix='.clear-unmerged-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(record, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def check():
    poll = Poll()
    if poll.state.is_symlink():
        raise Unavailable('state directory is a symlink')
    poll.state.mkdir(parents=True, exist_ok=True)
    lock = poll.state/'.clear-unmerged.lock'
    record_path = poll.state/'.clear-unmerged.json'
    if lock.is_symlink() or record_path.is_symlink():
        raise Unavailable('clear-unmerged state paths must be ordinary files')
    with lock.open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        record = json.loads(poll.read(record_path)) if record_path.exists() else {'schema': 1, 'alerted': [], 'error': ''}
        if not isinstance(record, dict) or record.get('schema') != 1 or not isinstance(record.get('alerted'), list):
            raise Unavailable('invalid clear-unmerged history; preserve it and repair the record')
        errors = []
        try:
            repos = poll.repos(errors)
            reports = poll.reports(record) if repos else []
            held_ids, held_urls = poll.holds() if repos else (set(), set())
            candidate = None
            heads = record.setdefault('heads', {})
            for host, repo in repos:
                try:
                    prs = poll.prs(host, repo)
                except ITEM_ERRORS as error:
                    errors.append(str(error))
                    continue
                prefix = f'https://{host}/{repo}/pull/'.lower()
                listed = {pr.get('url') for pr in prs}
                for url in [u for u in heads if u.lower().startswith(prefix) and u not in listed]:
                    del heads[url]
                for pr in prs:
                    try:
                        poll.remaining()
                        head_time = poll.head_time(pr, record)
                        found = poll.candidate(pr, reports, held_ids, held_urls, head_time)
                    except ITEM_ERRORS as error:
                        errors.append(str(error))
                        continue
                    if found and found[0] not in record['alerted'] and candidate is None:
                        candidate = found
            if candidate:
                # Output precedes the receipt: failed persistence can repeat an
                # alert but cannot silently suppress an alert never produced.
                print(candidate[1], flush=True)
                record['alerted'].append(candidate[0])
        except ITEM_ERRORS as error:
            errors.append(str(error))
        note = ''
        if errors:
            note = 'CLEAR unmerged check unavailable: '+'; '.join(' '.join(e.split()) for e in dict.fromkeys(errors))
            if note != record.get('error'):
                print(note, flush=True)
        record['error'] = note
        save(record_path, record)


if __name__ == '__main__':
    if sys.argv[1:] == ['--help']:
        print(__doc__)
    elif sys.argv[1:]:
        sys.exit('usage: fm-clear-unmerged-check.py [--help]')
    else:
        try:
            check()
        except (Unavailable, OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
            print('CLEAR unmerged check unavailable: '+' '.join(str(exc).split()))
