#!/usr/bin/env python3
"""Report overdue independently cleared PRs, never merge them.

Armed via fm-clear-unmerged-check.sh; discovers PR URLs from local CLEAR reports,
then uses one bounded gh-axi GraphQL metadata read per candidate (100 paths;
incomplete reads refuse). Repositories without CLEAR reports need no forge read.
Registry names follow fm-project-mode.sh; origin resolves each registered clone.
Local-only and Gerrit projects are excluded through that script's public interface.
The optional config/clear-unmerged-skip-repos lists owner/repo or host/owner/repo,
one per line, with # comments. Registry rows naming Michael are also excluded.
No inference about ownership is made from an organization name.

A report in data/*/report.md names a PR when its text contains the full PR URL
and head SHA within its first 64 KiB (complete lines only when truncated).
Unreadable or incomplete report prefixes are skipped with separate diagnostics;
large reports with complete prefix evidence remain eligible.
The latest such report (by mtime) decides: its first line must start with
'# CLEAR' as a whole word; a later non-CLEAR review at the same head blocks the
alert. Report time is the file mtime only;
a future mtime is clamped to the first poll that saw it, retained while that
mtime is unchanged. The clock starts at the later of that time and the PR
creation/latest force-push/head push.
GitHub often omits pushedDate; updatedAt at the first observation of each head
is then a conservative upper bound on head-change time. This can delay the
initial alert; subsequent unrelated PR activity does not keep resetting it.
A changed SHA without a matching CLEAR cannot alert. Exactly two hours is not
more than two hours. This is an alert, not a grant of merge authority.

Carve-out declarations are honored and never override fm-pr-lint.py's classifier
on body, paths and added code. Closed, merged, draft, or moved-head PRs stop
after metadata. Eligible overdue PRs require a complete bounded
gh-axi diff plus a head recheck; missing evidence refuses. Already-alerted PR+head
identities, and every PR after this pass selects its alert, skip that diff read so
they cannot spend the scan budget. Malformed declarations refuse. All non-Done
captain holds are read through fm-tasks-axi.sh, including URL-linked backlog
rows and tasks bound by state/*.meta pr= or a matching review task id.

state/.clear-unmerged.json stores schema=1, alerted PR+head identities, observed
head clocks (removed when a candidate is closed or absent), a next-candidate
cursor and the deferred URLs for budget continuation, and a finished map of
PR URL -> {state, head, seen_at} for PRs read as MERGED or CLOSED. MERGED URLs
are never read again; CLOSED URLs are reread only after a newer CLEAR report
names them. Entries leave the map when no CLEAR report names the URL, CLOSED
entries after 30 days, and the oldest beyond 5000. Clamped future
report times, and the last error and report-skip diagnostics for repeat
suppression. A nonblocking flock serializes checks.
A failed project, repository or PR read is reported and skipped; the remaining
items are still evaluated, and the failed item is never marked alerted.
At most one new alert per pass keeps watcher output bounded; subsequent polls
advance through the remaining candidates. Disarming retains this history.
The entire scan is bounded to min(20, FM_CHECK_TIMEOUT-2) seconds, with a 10s
per-command cap. FM_CLEAR_UNMERGED_MAX_CALLS bounds forge calls per tick
(default 12); an overdue eligible candidate needs three calls including metadata,
diff and head recheck. Unreached candidates are counted as deferred (URLs in
the state record) and resumed first next tick. Item failures are named as skipped, not whole-check unavailable.
Budget/forge/registry/hold failures never mark a PR alerted. A test-only FM_CLEAR_UNMERGED_NOW freezes age
calculation, never the real-time budget. No credentials or shell code are read.
"""
import base64
import codecs
import datetime
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import shutil
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
REPORT_PREFIX_BYTES = 64 * 1024
FINISHED_CLOSED_SECONDS = 30*24*3600
FINISHED_LIMIT = 5000
SHA = re.compile(r'(?<![a-fA-F0-9])[a-fA-F0-9]{40}(?![a-fA-F0-9])')


class Unavailable(Exception):
    pass


class Deferred(Unavailable):
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
        self.calls_left = int(os.environ.get('FM_CLEAR_UNMERGED_MAX_CALLS', '12'))
        if self.calls_left < 1:
            raise Unavailable('FM_CLEAR_UNMERGED_MAX_CALLS must be positive')
        self.now = time.time()
        if os.environ.get('FM_TEST_SEAM') == '1':
            self.now = int(os.environ.get('FM_CLEAR_UNMERGED_NOW', self.now))

    def remaining(self):
        left = self.deadline-time.monotonic()
        if left <= 0:
            raise Deferred('scan time budget exhausted')
        return min(10, left)

    def run(self, args):
        bound = self.remaining()
        if args[0] == 'gh-axi':
            if self.calls_left == 0:
                raise Deferred('forge call budget exhausted')
            self.calls_left -= 1
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

    def repos(self, errors, wanted):
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
                remote = self.run(['git', '-C', self.projects/name, 'remote', 'get-url', 'origin']).strip()
                match = re.fullmatch(r'(?:https?://|ssh://git@|git@)([A-Za-z0-9.-]+)[:/]('+SLUG+'/'+SLUG+r')(?:\.git)?/?', remote)
                if not match:
                    raise Unavailable(f'unsupported origin for {name}; a GitHub origin is required')
                host, repo = match.groups()
                repo = repo.removesuffix('.git')
                if (host.lower(), repo) not in wanted:
                    continue
                mode = self.run([BIN/'fm-project-mode.sh', name]).strip()
                forge = self.run([BIN/'fm-project-mode.sh', '--forge', name]).strip()
                if mode.split()[0] == 'local-only' or forge == 'gerrit':
                    continue
            except Deferred:
                raise
            except (Unavailable, IndexError) as error:
                errors.append(f'{name}: {error}')
                continue
            host, repo = match.groups()
            repo = repo.removesuffix('.git')
            if repo.lower() not in skipped and (host+'/'+repo).lower() not in skipped:
                repos.add((host.lower(), repo))
        return sorted(repos)

    def reports(self, record, diagnostics):
        reports, previous, clamped = [], record.get('clamped', {}), {}
        for path in sorted(self.data.glob('*/report.md')):
            if len(reports) > 10000:
                raise Unavailable('report scan exceeds 10000 reports')
            self.remaining()
            try:
                with path.open('rb') as stream:
                    prefix = stream.read(REPORT_PREFIX_BYTES)
                    truncated = bool(stream.read(1))
                    mtime = os.fstat(stream.fileno()).st_mtime
                # A valid UTF-8 character can straddle the byte boundary.
                text = codecs.getincrementaldecoder('utf-8')().decode(prefix, final=not truncated)
                if truncated:
                    # Never accept a URL or SHA cut short at the prefix boundary.
                    text = text.rpartition('\n')[0]
            except (OSError, UnicodeError) as error:
                diagnostics.append(f'{path}: skipped report: {error}')
                continue
            urls = set(URL.findall(text))
            shas = {s.lower() for s in SHA.findall(text)}
            clear = bool(re.match(r'^# CLEAR(?:\s|$)', text))
            if not urls or not shas:
                if clear or truncated:
                    diagnostics.append(f'{path}: skipped report: missing PR URL or full head SHA in report prefix')
                continue
            seen = previous.get(str(path))
            if seen and seen['mtime'] == mtime:
                clamped[str(path)] = seen
            elif mtime > self.now:
                clamped[str(path)] = {'mtime': mtime, 'at': self.now}
            stamp = clamped[str(path)]['at'] if str(path) in clamped else mtime
            reports.append((path, urls, shas, stamp, clear))
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

    def pr(self, url):
        host, owner, name, _, number = url.removeprefix('https://').split('/')
        repo = owner+'/'+name
        query = '''query { repository(owner:%s,name:%s) {
          pullRequest(number:%s) {
              url state isDraft headRefOid body createdAt updatedAt additions
              files(first:100) { pageInfo { hasNextPage } nodes { path } }
              commits(last:1) { nodes { commit { oid pushedDate } } }
              timelineItems(last:1,itemTypes:[HEAD_REF_FORCE_PUSHED_EVENT]) {
                nodes { ... on HeadRefForcePushedEvent { createdAt } }
              }
          }
        }}''' % (json.dumps(owner), json.dumps(name), number)
        out = self.run(['gh-axi', 'api', 'POST', 'graphql', '--hostname', host,
                        '--field', 'query='+query, '--jq', '@base64 | {chunks: [scan(".{1,1000}") | {part: .}]}'])
        try:
            # gh-axi caps raw output at 4000 and individual strings at 2000.
            # Caller-shaped 1000-byte scalar chunks preserve the entire result
            # in one metadata call without relying on an unsupported --full flag.
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
            return result['data']['repository']['pullRequest']
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

    def candidate(self, pr, reports, held_ids, held_urls, head_time, alerted):
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
        identity = url+'@'+sha
        if age <= 7200 or identity in alerted:
            return None
        if self.calls_left < 2:
            raise Deferred('forge call budget needs two reads for diff and head recheck')
        changes = self.added_lines(pr)
        if LINT.carve_out_signals(body, paths, changes):
            return None
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
        # Count additions against the metadata response so a shortened patch cannot
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
        errors, diagnostics = [], []
        candidate = None
        urls = []
        global_failure = False
        try:
            reports = poll.reports(record, diagnostics)
            urls = sorted({url for _, urls, _, _, clear in reports if clear for url in urls})
            finished = {url: entry for url, entry in record.get('finished', {}).items() if url in urls
                        and (entry['state'] == 'MERGED' or entry['seen_at'] > poll.now-FINISHED_CLOSED_SECONDS)}
            finished = dict(sorted(finished.items(), key=lambda item: item[1]['seen_at'])[-FINISHED_LIMIT:])
            record['finished'] = finished
            reviewed = {}
            for _, report_urls, _, stamp, clear in reports:
                for url in report_urls if clear else ():
                    reviewed[url] = max(stamp, reviewed.get(url, stamp))
            skipped_finished = [url for url in urls if url in finished and (finished[url]['state'] == 'MERGED'
                                or reviewed[url] <= finished[url]['seen_at'])]
            urls = [url for url in urls if url not in skipped_finished]
            if urls and shutil.which('gh-axi') is None:
                global_failure = True
                raise Unavailable('gh-axi missing; install gh-axi')
            wanted = {tuple(url.removeprefix('https://').split('/', 1)) for url in urls}
            wanted = {(host.lower(), tail.rsplit('/pull/', 1)[0]) for host, tail in wanted}
            repos = set(poll.repos(errors, wanted)) if urls else set()
            urls = [url for url in urls if
                    (url.split('/')[2].lower(), '/'.join(url.split('/')[3:5])) in repos]
            held_ids, held_urls = poll.holds() if urls else (set(), set())
            cursor = record.get('cursor')
            if cursor in urls:
                index = urls.index(cursor)
                urls = urls[index:] + urls[:index]
            heads = record.setdefault('heads', {})
            deferred, read = [], 0
            for index, url in enumerate(urls):
                try:
                    poll.remaining()
                    if poll.calls_left == 0:
                        raise Deferred('forge call budget exhausted')
                    read += 1
                    pr = poll.pr(url)
                    finished.pop(url, None)
                    if pr is None or pr['state'] in ('CLOSED', 'MERGED'):
                        heads.pop(url, None)
                        if pr is not None:
                            finished[url] = {'state': pr['state'], 'head': pr['headRefOid'], 'seen_at': poll.now}
                        continue
                    if pr['url'] != url:
                        raise Unavailable('forge returned a different PR identity')
                    if pr['state'] != 'OPEN':
                        raise Unavailable('forge returned unknown PR state')
                    if pr['isDraft']:
                        continue
                    if not any(url in report_urls and pr['headRefOid'] in shas and clear
                               for _, report_urls, shas, _, clear in reports):
                        continue
                    head_time = poll.head_time(pr, record)
                    if candidate is None:
                        candidate = poll.candidate(pr, reports, held_ids, held_urls, head_time, record['alerted'])
                        if candidate:
                            # Emit immediately after the diff/head guard, before other PR reads.
                            # A failed save can repeat an alert but cannot hide an unprinted one.
                            print(candidate[1], flush=True)
                            record['alerted'].append(candidate[0])
                except Deferred as error:
                    deferred = urls[index:]
                    errors.append(f'{error}; read {read}, deferred {len(deferred)}, '
                                  f'finished-skipped {len(skipped_finished)}')
                    break
                except ITEM_ERRORS as error:
                    errors.append(f'{url}: skipped: {error}')
            record['cursor'] = deferred[0] if deferred else None
            record['deferred'] = deferred
        except Deferred as error:
            record['cursor'] = urls[0] if urls else record.get('cursor')
            record['deferred'] = urls
            errors.append(f'{error}; read 0, deferred {len(urls)}')
        except ITEM_ERRORS as error:
            errors.append(str(error))
        note = ''
        if errors:
            note = ('CLEAR unmerged check unavailable: ' if global_failure
                    else 'CLEAR unmerged scan diagnostics: ')+'; '.join(' '.join(e.split()) for e in dict.fromkeys(errors))
            if note != record.get('error'):
                print(note, flush=True)
        record['error'] = note
        diagnostic = '; '.join(' '.join(d.split()) for d in diagnostics)
        if diagnostic and diagnostic != record.get('report_diagnostics'):
            print('CLEAR unmerged report diagnostics: '+diagnostic, flush=True)
        record['report_diagnostics'] = diagnostic
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
