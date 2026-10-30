#!/usr/bin/env bash
# Exercise the executable check and its registered watcher shim in isolated homes.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ROOT
python3 - <<'PY'
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(os.environ['ROOT'])
CHECK = ROOT / 'bin/fm-clear-unmerged-check.sh'
SHA = 'a' * 40
URL = 'https://github.com/example/demo/pull/7'
NOW = 1800000000

def iso(epoch):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(epoch))

class Check(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        for p in ('state', 'data/review', 'config', 'projects/demo', 'fakebin'):
            (self.home / p).mkdir(parents=True, exist_ok=True)
        self.env = dict(os.environ, FM_HOME=str(self.home), FM_CLEAR_UNMERGED_NOW=str(NOW))
        for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
            self.env.pop(key, None)
        self.env['PATH'] = str(self.home/'fakebin') + ':' + self.env['PATH']
        subprocess.run(['git', 'init', '-q', str(self.home/'projects/demo')], check=True)
        subprocess.run(['git', '-C', str(self.home/'projects/demo'), 'remote', 'add', 'origin', 'https://github.com/example/demo.git'], check=True)
        (self.home/'data/projects.md').write_text('- demo [no-mistakes +yolo] - demo\n')
        (self.home/'fakebin/gh-axi').write_text('''#!/usr/bin/env python3
import os, sys, pathlib, time, json, re, base64
h = pathlib.Path(os.environ['FM_HOME'])
with (h/'calls').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
if (h/'forge-error').exists():
    print('error: forbidden'); sys.exit(1)
if (h/'forge-sleep').exists(): time.sleep(10)
if sys.argv[1:3] == ['pr', 'diff']:
    if (h/('slow-diff-'+sys.argv[3])).exists(): time.sleep(10)
    if (h/'diff-error').exists(): print('error: missing diff'); sys.exit(1)
    print('pull_request:\\n  diff: '+json.dumps((h/'diff').read_text()))
elif sys.argv[1] == 'api' and '/pulls/' in sys.argv[2]:
    print('response:\\n  body: '+json.dumps((h/'head').read_text()))
else:
    query = next((a for a in sys.argv if a.startswith('query=')), '')
    match = re.search(r'pullRequest\(number:([0-9]+)\)', query)
    if match:
        number = match[1]
        if (h/('slow-pr-'+number)).exists(): time.sleep(10)
        if (h/('fail-pr-'+number)).exists(): print('error: forbidden'); sys.exit(1)
        raw = (h/'forge').read_text()
        lines = raw.splitlines()
        if len(lines)-1 != int(re.search(r'chunks\[([0-9]+)\]', lines[0])[1]):
            print(raw); sys.exit(0)
        listed = json.loads(base64.b64decode(''.join(line[2:] for line in lines[1:])))['data']['repository']['pullRequests']
        rows = listed['nodes']
        if listed['pageInfo']['hasNextPage']:
            for row in rows: row['files']['pageInfo']['hasNextPage'] = True
        pr = next((p for p in rows if p['url'].endswith('/'+number)), None)
        response = dict(data=dict(repository=dict(pullRequest=pr)))
        if pr is None and (h/'not-found-errors').exists():
            response['errors'] = [dict(type='NOT_FOUND', path=['repository', 'pullRequest'],
                                       message='Could not resolve to a PullRequest')]
        encoded = base64.b64encode(json.dumps(response).encode()).decode()
        chunks = [encoded[i:i+1000] for i in range(0,len(encoded),1000)]
        print('chunks['+str(len(chunks))+']{part}:\\n'+''.join('  '+c+'\\n' for c in chunks), end='')
    else:
        print((h/'forge').read_text())
''')
        (self.home/'fakebin/tasks-axi').write_text('''#!/usr/bin/env python3
import os, pathlib
import time
h = pathlib.Path(os.environ['FM_HOME'])
if (h/'tasks-sleep').exists(): time.sleep(10)
print((h/'tasks').read_text())
''')
        for p in (self.home/'fakebin').iterdir(): p.chmod(0o755)
        (self.home/'tasks').write_text('count: 0\ntasks: 0 tasks in this backlog\n')
        self.pr = dict(state='OPEN', isDraft=False, additions=1, url=URL, headRefOid=SHA, body='Goal: improve monitoring.\nCarve-outs: none',
                       createdAt=iso(NOW-20000), updatedAt=iso(NOW-10000),
                       files=dict(pageInfo=dict(hasNextPage=False), nodes=[dict(path='bin/monitor.sh')]),
                       commits=dict(nodes=[dict(commit=dict(oid=SHA, pushedDate=iso(NOW-10000)))]),
                       timelineItems=dict(nodes=[]))
        (self.home/'diff').write_text('diff --git a/bin/monitor.sh b/bin/monitor.sh\n--- a/bin/monitor.sh\n+++ b/bin/monitor.sh\n@@ -0,0 +1 @@\n+print(1)\n')
        (self.home/'head').write_text(SHA)
        self.report('# CLEAR\n\n'+URL+' at `'+SHA+'`.\n', NOW-7260)
        self.forge()

    def report(self, content, epoch):
        p = self.home/'data/review/report.md'
        p.write_text(content)
        os.utime(p, (epoch, epoch))

    def forge(self, more=False, prs=None):
        response = dict(data=dict(repository=dict(pullRequests=dict(nodes=prs or [self.pr],pageInfo=dict(hasNextPage=more)))))
        encoded = base64.b64encode(json.dumps(response).encode()).decode()
        chunks = [encoded[i:i+1000] for i in range(0,len(encoded),1000)]
        (self.home/'forge').write_text('chunks['+str(len(chunks))+']{part}:\n'+''.join('  '+chunk+'\n' for chunk in chunks))

    def run_check(self, action='check'):
        r = subprocess.run(['bash', str(CHECK), action], env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(r.returncode, 0, r.stdout+r.stderr)
        return r.stdout

    def metadata_calls(self):
        path = self.home/'calls'
        return [json.loads(line) for line in path.read_text().splitlines()
                if json.loads(line)[:3] == ['api', 'POST', 'graphql']] if path.exists() else []

    def record(self):
        return json.loads((self.home/'state/.clear-unmerged.json').read_text())

    def drafts(self, count):
        prs = []
        for number in range(1, count+1):
            pr = json.loads(json.dumps(self.pr))
            pr['url'] = 'https://github.com/example/demo/pull/'+str(number)
            pr['isDraft'] = True
            prs.append(pr)
        self.forge(prs=prs)
        self.report('# CLEAR\n'+' '.join(pr['url'] for pr in prs)+' '+SHA, NOW-7260)
        return prs

    def project(self, name, origin=None, tags='no-mistakes'):
        subprocess.run(['git', 'init', '-q', str(self.home/'projects'/name)], check=True)
        if origin:
            subprocess.run(['git', '-C', str(self.home/'projects'/name), 'remote', 'add', 'origin', origin], check=True)
        with (self.home/'data/projects.md').open('a') as registry:
            registry.write('- '+name+' ['+tags+'] - '+name+'\n')

    def two_reports(self):
        other = json.loads(json.dumps(self.pr))
        other['url'] = 'https://github.com/example/other/pull/8'
        other['isDraft'] = True
        subprocess.run(['git', 'init', '-q', str(self.home/'projects/other')], check=True)
        subprocess.run(['git', '-C', str(self.home/'projects/other'), 'remote', 'add', 'origin',
                        'https://github.com/example/other.git'], check=True)
        (self.home/'data/projects.md').write_text('- demo [no-mistakes] - demo\n- other [no-mistakes] - other\n')
        path = self.home/'data/review2/report.md'
        path.parent.mkdir()
        path.write_text('# CLEAR\n'+other['url']+' '+SHA)
        os.utime(path, (NOW-7260, NOW-7260))
        self.forge(prs=[self.pr, other])
        return other

    def test_thirty_repos_read_only_two_clear_candidates(self):
        self.two_reports()
        with (self.home/'data/projects.md').open('a') as registry:
            for i in range(28):
                name = 'unreviewed'+str(i)
                subprocess.run(['git', 'init', '-q', str(self.home/'projects'/name)], check=True)
                subprocess.run(['git', '-C', str(self.home/'projects'/name), 'remote', 'add',
                                'origin', 'https://github.com/example/'+name+'.git'], check=True)
                registry.write('- '+name+' [no-mistakes] - demo\n')
        out = self.run_check()
        self.assertIn('CLEAR unmerged: '+URL, out)
        self.assertEqual(len(self.metadata_calls()), 2)
        calls = (self.home/'calls').read_text().splitlines()
        self.assertEqual(len(calls), 4)  # two metadata reads, eligible diff and head recheck

    def test_origin_spelled_in_other_case_still_alerts(self):
        subprocess.run(['git', '-C', str(self.home/'projects/demo'), 'remote', 'set-url', 'origin',
                        'https://github.com/Example/Demo.git'], check=True)
        canonical = 'https://github.com/Example/Demo/pull/7'
        self.pr['url'] = canonical
        self.forge()
        out = self.run_check()
        self.assertEqual(out.splitlines()[0].split(' head=')[0], 'CLEAR unmerged: '+canonical)
        self.assertNotIn('diagnostics', out)
        self.assertEqual(self.record()['alerted'], [canonical+'@'+SHA])
        self.assertEqual(self.run_check(), '')

    def test_clear_url_without_registered_origin_is_named(self):
        subprocess.run(['git', '-C', str(self.home/'projects/demo'), 'remote', 'set-url', 'origin',
                        'https://github.com/example/old-demo.git'], check=True)
        out = self.run_check()
        self.assertIn('CLEAR unmerged scan diagnostics: ', out)
        self.assertIn(URL+': skipped: no registered project has this repository as origin', out)
        self.assertNotIn('check unavailable', out)
        self.assertFalse((self.home/'calls').exists())
        self.assertEqual(self.run_check(), '')

    def test_local_only_and_gerrit_projects_stay_quiet(self):
        self.project('scratch', tags='local-only')
        self.project('gr', 'ssh://me@review.example:29418/gr', 'no-mistakes forge=gerrit')
        out = self.run_check()
        self.assertEqual(len(out.splitlines()), 1, out)
        self.assertIn('CLEAR unmerged: '+URL, out)

    def test_whole_check_failures_say_unavailable(self):
        (self.home/'tasks').write_text('error: backend unavailable\n')
        self.assertIn('CLEAR unmerged check unavailable: captain hold', self.run_check())
        (self.home/'tasks').write_text('count: 0\ntasks: 0 tasks in this backlog\n')
        (self.home/'data/projects.md').unlink()
        self.assertIn('CLEAR unmerged check unavailable: ', self.run_check())

    def test_call_budget_too_small_for_one_alert_is_refused(self):
        self.env['FM_CLEAR_UNMERGED_MAX_CALLS'] = '2'
        out = self.run_check()
        self.assertIn('check unavailable: FM_CLEAR_UNMERGED_MAX_CALLS must be at least 3', out)
        self.assertFalse((self.home/'calls').exists())

    def test_missing_pr_is_not_reread_every_tick(self):
        for errors in (False, True):
            (self.home/'state/.clear-unmerged.json').unlink(missing_ok=True)
            (self.home/'calls').unlink(missing_ok=True)
            if errors:
                (self.home/'not-found-errors').touch()
            self.forge(prs=[dict(self.pr, url='https://github.com/example/demo/pull/9')])
            self.assertEqual(self.run_check(), '')
            self.assertEqual(self.record()['finished'][URL]['state'], 'MISSING')
            self.assertEqual(self.run_check(), '')
            self.assertEqual(len(self.metadata_calls()), 1)

    def test_time_budget_in_registry_keeps_rotation_cursor(self):
        self.two_reports()
        real = subprocess.run(['/bin/sh', '-c', 'command -v git'], capture_output=True, text=True, check=True).stdout.strip()
        (self.home/'fakebin/git').write_text('#!/bin/sh\nsleep 10\nexec '+real+' "$@"\n')
        (self.home/'fakebin/git').chmod(0o755)
        cursor = 'https://github.com/example/other/pull/8'
        (self.home/'state/.clear-unmerged.json').write_text(json.dumps(
            dict(schema=1, alerted=[], error='', cursor=cursor)))
        self.env['FM_CHECK_TIMEOUT'] = '3'
        out = self.run_check()
        self.assertIn('deferred 2', out)
        self.assertNotIn('check unavailable', out)
        self.assertEqual(self.record()['cursor'], cursor)

    def test_head_clock_pruned_when_clear_report_is_gone(self):
        self.env['FM_CLEAR_UNMERGED_NOW'] = str(NOW-3600)
        self.run_check()
        self.assertIn(URL, self.record()['heads'])
        (self.home/'data/review/report.md').unlink()
        self.run_check()
        self.assertEqual(self.record()['heads'], {})

    def test_merged_clear_prs_are_not_reread_and_overdue_pr_checked_each_tick(self):
        prs, words = [], []
        for number in range(1, 41):
            pr = json.loads(json.dumps(self.pr))
            pr['url'] = 'https://github.com/example/demo/pull/'+str(number)
            if number <= 38:
                pr['state'] = 'MERGED'
            prs.append(pr)
            words.append(pr['url'])
        self.forge(prs=prs)
        self.report('# CLEAR\n'+' '.join(words)+' '+SHA, NOW-3600)
        for _ in range(4):
            out = self.run_check()
            if 'deferred' not in out and not self.record()['deferred']:
                break
        self.assertFalse(self.record()['deferred'])
        self.assertNotIn('CLEAR unmerged: ', out)
        self.assertEqual(len(self.record()['finished']), 38)
        (self.home/'calls').unlink()
        self.env['FM_CLEAR_UNMERGED_NOW'] = str(NOW+3700)
        out = self.run_check()
        self.assertEqual(len(self.metadata_calls()), 2)
        self.assertRegex(out, r'CLEAR unmerged: https://github.com/example/demo/pull/(39|40) ')
        self.assertNotIn('diagnostics', out)

    def test_deferral_note_is_stable_across_ticks(self):
        self.drafts(4)
        self.env['FM_CLEAR_UNMERGED_MAX_CALLS'] = '3'
        self.assertIn('read 3, deferred 1, finished-skipped 0', self.run_check())
        self.assertEqual(self.run_check(), '')
        self.assertEqual(len(self.metadata_calls()), 6)

    def test_closed_pr_with_newer_clear_report_is_reread(self):
        self.pr['state'] = 'CLOSED'
        self.forge()
        self.run_check()
        self.assertEqual(self.record()['finished'][URL]['state'], 'CLOSED')
        self.run_check()
        self.assertEqual(len(self.metadata_calls()), 1)
        self.pr['state'] = 'OPEN'
        self.forge()
        self.env['FM_CLEAR_UNMERGED_NOW'] = str(NOW+600)
        self.report('# CLEAR\n\n'+URL+' at `'+SHA+'`.\n', NOW+300)
        self.run_check()
        self.assertEqual(len(self.metadata_calls()), 2)
        self.assertNotIn(URL, self.record()['finished'])

    def test_call_budget_defers_and_resumes_next_candidate(self):
        # No candidate needs a diff, so each call must advance one candidate.
        prs = self.drafts(4)
        self.env['FM_CLEAR_UNMERGED_MAX_CALLS'] = '3'
        out = self.run_check()
        self.assertIn('read 3, deferred 1', out)
        self.assertEqual(self.record()['deferred'], [prs[3]['url']])
        self.assertNotIn('check unavailable', out)
        self.assertEqual(len(self.metadata_calls()), 3)
        self.run_check()
        calls = self.metadata_calls()
        self.assertEqual(len(calls), 6)
        self.assertIn('pullRequest(number:4)', ' '.join(calls[3]))

    def test_one_candidate_failure_does_not_hide_other_alert(self):
        other = self.two_reports()
        (self.home/'fail-pr-8').touch()
        out = self.run_check()
        self.assertIn('CLEAR unmerged: '+URL, out)
        self.assertIn(other['url'], out)
        self.assertIn('skipped', out)
        self.assertNotIn('check unavailable', out)

    def test_overdue_candidate_deferred_after_metadata_then_alerts_next_tick(self):
        other = self.two_reports()
        self.pr['isDraft'] = True
        other['isDraft'] = False
        self.forge(prs=[self.pr, other])
        self.env['FM_CLEAR_UNMERGED_MAX_CALLS'] = '3'
        first = self.run_check()
        self.assertNotIn('CLEAR unmerged: ', first)
        self.assertIn('deferred 1', first)
        self.assertEqual(self.record()['deferred'], [other['url']])
        second = self.run_check()
        self.assertIn('CLEAR unmerged: '+other['url'], second)
        self.assertNotIn('check unavailable', second)

    def test_failed_first_candidate_still_allows_next_repo_alert(self):
        other = self.two_reports()
        other['isDraft'] = False
        self.forge(prs=[self.pr, other])
        (self.home/'fail-pr-7').touch()
        out = self.run_check()
        self.assertIn(URL+': skipped:', out)
        self.assertIn('CLEAR unmerged: '+other['url'], out)
        self.assertNotIn('check unavailable', out)

    def test_timed_out_repo_defers_other_repo_to_next_tick(self):
        other = self.two_reports()
        other['isDraft'] = False
        self.forge(prs=[self.pr, other])
        (self.home/'slow-pr-7').touch()
        self.env['FM_CHECK_TIMEOUT'] = '4'
        first = self.run_check()
        self.assertIn('scan time budget exhausted reading gh-axi', first)
        self.assertIn('deferred 2', first)
        self.assertEqual(self.record()['deferred'], [other['url'], URL])
        self.assertNotIn('check unavailable', first)
        second = self.run_check()
        self.assertIn('CLEAR unmerged: '+other['url'], second)
        self.assertNotIn('check unavailable', second)

    def test_closed_merged_draft_and_moved_head_stop_after_metadata(self):
        for changes in ({'state': 'CLOSED'}, {'state': 'MERGED'}, {'isDraft': True},
                        {'headRefOid': 'b'*40}):
            pr = dict(self.pr, **changes)
            self.forge(prs=[pr])
            (self.home/'calls').unlink(missing_ok=True)
            (self.home/'state/.clear-unmerged.json').unlink(missing_ok=True)
            self.assertEqual(self.run_check(), '')
            self.assertEqual(len((self.home/'calls').read_text().splitlines()), 1)

    def test_no_clear_reports_means_no_forge_reads(self):
        (self.home/'data/review/report.md').unlink()
        (self.home/'forge-error').touch()
        self.assertEqual(self.run_check(), '')
        self.assertFalse((self.home/'calls').exists())

    def test_due_once_with_evidence_and_merge_instruction(self):
        out = self.run_check()
        for text in (URL, SHA, str(self.home/'data/review/report.md'), '7260s', 'bin/fm-pr-merge.sh'):
            self.assertIn(text, out)
        self.assertNotIn('ask Zac', out)
        self.assertEqual(self.run_check(), '')
        calls = [json.loads(line) for line in (self.home/'calls').read_text().splitlines()]
        self.assertEqual(sum(call[:3] == ['api', 'POST', 'graphql'] for call in calls), 2)

    def assert_report_skipped(self, path, reason):
        out = self.run_check()
        self.assertIn('CLEAR unmerged: '+URL, out)
        self.assertIn('CLEAR unmerged report diagnostics:', out)
        self.assertIn(str(path), out)
        self.assertIn(reason, out)
        self.assertNotIn('check unavailable', out)
        self.assertEqual(self.run_check(), '')

    def test_large_unrelated_report_does_not_silence_valid_review(self):
        path = self.home/'data/oversized/report.md'
        path.parent.mkdir()
        path.write_text('x' * (3*1024*1024))
        self.assert_report_skipped(path, 'prefix')

    def test_unreadable_report_does_not_silence_valid_review(self):
        if os.geteuid() == 0:
            self.skipTest('mode 000 requires an unprivileged test runner')
        path = self.home/'data/unreadable/report.md'
        path.parent.mkdir()
        path.write_text('# CLEAR\n'+URL+' '+SHA)
        path.chmod(0)
        self.addCleanup(path.chmod, 0o600)
        self.assert_report_skipped(path, 'Permission denied')

    def test_bad_utf8_report_does_not_silence_valid_review(self):
        path = self.home/'data/bad-utf8/report.md'
        path.parent.mkdir()
        path.write_bytes(b'# CLEAR\n\xff')
        self.assert_report_skipped(path, 'decode')

    def test_large_clear_report_uses_identity_in_prefix(self):
        self.report('# CLEAR\n'+URL+' '+SHA+'\n'+'x'*(3*1024*1024), NOW-7260)
        out = self.run_check()
        self.assertIn('CLEAR unmerged: '+URL, out)
        self.assertNotIn('unavailable', out)

    def test_clear_identity_beyond_prefix_does_not_alert(self):
        for prefix in ('# CLEAR\n'+URL+'\n', '# CLEAR\n'+SHA+'\n'):
            (self.home/'state/.clear-unmerged.json').unlink(missing_ok=True)
            self.report(prefix+'x'*(3*1024*1024)+'\n'+URL+' '+SHA, NOW-7260)
            out = self.run_check()
            self.assertNotIn('CLEAR unmerged: ', out)
            self.assertIn('missing PR URL or full head SHA', out)
            self.assertIn('report.md', out)
            self.assertNotIn('unavailable', out)

    def test_utf8_character_across_prefix_boundary_is_not_corruption(self):
        head = '# CLEAR\n'+URL+' '+SHA+'\n'
        self.report(head+'x'*(64*1024-len(head)-1)+'é\n', NOW-7260)
        self.assertIn('CLEAR unmerged: '+URL, self.run_check())

    def test_partial_sha_at_prefix_boundary_cannot_alert(self):
        head = '# CLEAR\n'+URL+'\n'
        self.report(head+'x'*(64*1024-len(head)-41)+' '+SHA+'a\n', NOW-7260)
        out = self.run_check()
        self.assertNotIn('CLEAR unmerged: ', out)
        self.assertIn('missing PR URL or full head SHA', out)

    def test_report_directory_is_skipped(self):
        path = self.home/'data/directory/report.md'
        path.parent.mkdir()
        path.mkdir()
        self.assert_report_skipped(path, 'Is a directory')

    def test_clear_must_start_on_line_one(self):
        self.report('Introduction\n# CLEAR\n'+URL+' '+SHA, NOW-7260)
        self.assertEqual(self.run_check(), '')

    def test_not_due_at_119_minutes_or_exactly_two_hours(self):
        for age in (7140,7200):
            self.report('# CLEAR\n'+URL+' '+SHA, NOW-age)
            self.assertEqual(self.run_check(), '')

    def test_changed_head_invalidates_clear(self):
        self.pr['headRefOid'] = 'b'*40
        self.pr['commits']['nodes'][0]['commit']['oid'] = 'b'*40
        self.forge()
        self.assertEqual(self.run_check(), '')

    def test_later_head_change_restarts_clock(self):
        self.pr['timelineItems']['nodes'] = [dict(createdAt=iso(NOW-7140))]
        self.forge()
        self.assertEqual(self.run_check(), '')

    def test_declared_and_inferred_carveouts(self):
        for body, path in [('Carve-outs: payments', 'x'), ('Handle Stripe payments', 'x'),
                           ('Update service', 'db/migration.sql'), ('Update service', 'src/auth.ts')]:
            self.pr['body'] = body
            self.pr['files']['nodes'] = [dict(path=path)]
            self.forge()
            self.assertEqual(self.run_check(), '')

    def test_none_declaration_cannot_override_carveout_paths(self):
        self.pr['files']['nodes'] = [dict(path='src/payments/checkout.py')]
        self.forge()
        self.assertEqual(self.run_check(), '')

    def test_diff_only_carveout_suppresses_alert(self):
        self.pr['body'] = 'Improve service'
        (self.home/'diff').write_text('diff --git a/src/client.py b/src/client.py\n--- a/src/client.py\n+++ b/src/client.py\n@@ -0,0 +1 @@\n+stripe.PaymentIntent.create()\n')
        self.forge()
        self.assertEqual(self.run_check(), '')

    def test_diff_unavailable_incomplete_or_head_moved_refuses(self):
        (self.home/'diff-error').touch()
        self.assertIn('unavailable', self.run_check())
        (self.home/'diff-error').unlink()
        (self.home/'diff').write_text('')
        self.assertIn('incomplete', self.run_check())
        (self.home/'diff').write_text('+print(1)\n')
        (self.home/'head').write_text('b'*40)
        self.assertIn('head changed', self.run_check())
        self.assertEqual(json.loads((self.home/'state/.clear-unmerged.json').read_text())['alerted'], [])

    def test_malformed_registry_row_does_not_silence_healthy_repo(self):
        (self.home/'data/projects.md').write_text('- . [no-mistakes] - malformed\n- demo [no-mistakes] - demo\n')
        out = self.run_check()
        self.assertIn('CLEAR unmerged: '+URL, out)
        self.assertIn('.: invalid project registry name', out)

    def test_michael_repo_config_and_registry(self):
        (self.home/'config/clear-unmerged-skip-repos').write_text('# Michael repositories\nexample/demo\n')
        self.assertEqual(self.run_check(), '')
        self.assertFalse((self.home/'calls').exists())
        (self.home/'config/clear-unmerged-skip-repos').unlink()
        (self.home/'data/projects.md').write_text('- demo [no-mistakes] - owned by Michael\n')
        self.assertEqual(self.run_check(), '')
        self.assertFalse((self.home/'calls').exists())

    def test_captain_hold_by_url_or_task(self):
        (self.home/'tasks').write_text('count: 1\ntasks[1]{id,state,kind,repo,title,hold_kind,links,body}:\n  ship,queued,task,demo,Wait,captain,'+URL+',""\n')
        self.assertEqual(self.run_check(), '')
        (self.home/'tasks').write_text('count: 1\ntasks[1]{id,state,kind,repo,title,hold_kind,links,body}:\n  ship,queued,task,demo,Wait,captain,none,""\n')
        (self.home/'state/ship.meta').write_text('pr='+URL+'\n')
        self.assertEqual(self.run_check(), '')

    def test_bad_or_incomplete_forge_never_records_success(self):
        (self.home/'forge-error').touch()
        self.assertIn('gh-axi', self.run_check())
        (self.home/'forge-error').unlink()
        self.forge(more=True)
        self.assertIn('incomplete', self.run_check())
        self.forge()
        self.assertIn(URL, self.run_check())

    def test_hold_read_killed_by_time_budget_is_deferred(self):
        (self.home/'tasks-sleep').touch()
        self.env['FM_CHECK_TIMEOUT'] = '4'
        out = self.run_check()
        self.assertIn('CLEAR unmerged scan diagnostics: scan time budget exhausted reading', out)
        self.assertIn('read 0, deferred 1', out)
        self.assertNotIn('check unavailable', out)
        self.assertEqual(self.record()['cursor'], URL)

    def test_bad_hold_read_is_diagnostic(self):
        (self.home/'tasks').write_text('error: backend unavailable\n')
        self.assertIn('hold', self.run_check())

    def test_budget_is_bounded_and_visible(self):
        (self.home/'forge-sleep').touch()
        self.env['FM_CHECK_TIMEOUT'] = '4'
        start = time.monotonic()
        self.assertIn('budget', self.run_check())
        self.assertLess(time.monotonic()-start, 5)

    def test_only_first_heading_clear_and_full_identity(self):
        for text in ('# Findings\n# CLEAR\n'+URL+' '+SHA, '# CLEARANCE\n'+URL+' '+SHA,
                     '# CLEAR\n'+URL+' '+SHA[:12], '# CLEAR\n'+URL+'0 '+SHA, '# CLEAR\n'+URL+'extra '+SHA):
            self.report(text, NOW-7260)
            self.assertNotIn('CLEAR unmerged: ', self.run_check())
        self.report('# CLEAR - independent review\n'+URL+' '+SHA, NOW-7260)
        self.assertIn(URL, self.run_check())

    def test_large_body_transport_and_missing_chunk(self):
        self.pr['body'] += '\n' + ('Monitoring evidence. ' * 500)
        self.forge()
        original = (self.home/'forge').read_text()
        (self.home/'forge').write_text('\n'.join(original.splitlines()[:-1])+'\n')
        out = self.run_check()
        self.assertIn('missing complete PR data', out)
        self.assertNotIn('check unavailable', out)
        (self.home/'forge').write_text(original)
        self.assertIn(URL, self.run_check())

    def test_missing_push_timestamp_uses_conservative_activity_bound(self):
        self.pr['commits']['nodes'][0]['commit']['pushedDate'] = None
        self.pr['updatedAt'] = iso(NOW-7140)
        self.forge()
        self.assertEqual(self.run_check(), '')
        (self.home/'state/.clear-unmerged.json').unlink()
        self.pr['updatedAt'] = iso(NOW-8000)
        self.forge()
        self.assertIn(URL, self.run_check())

    def test_comments_do_not_reset_an_observed_head_clock(self):
        self.pr['commits']['nodes'][0]['commit']['pushedDate'] = None
        self.pr['updatedAt'] = iso(NOW-10000)
        self.report('# CLEAR\n'+URL+' '+SHA, NOW-7140)
        self.forge()
        self.assertEqual(self.run_check(), '')
        self.env['FM_CLEAR_UNMERGED_NOW'] = str(NOW+121)
        self.pr['updatedAt'] = iso(NOW+100)
        self.forge()
        self.assertIn(URL, self.run_check())

    def test_quoted_at_stamp_does_not_move_clock(self):
        self.report('# CLEAR\nresolved [at='+str(NOW-100)+']\n'+URL+' '+SHA, NOW-7260)
        self.assertIn(URL, self.run_check())
        (self.home/'state/.clear-unmerged.json').unlink()
        self.report('# CLEAR\nresolved [at='+str(NOW-10000)+']\n'+URL+' '+SHA, NOW-7140)
        self.assertEqual(self.run_check(), '')

    def test_future_mtime_clamps_to_first_poll(self):
        self.report('# CLEAR\n'+URL+' '+SHA, NOW+5000)
        self.assertEqual(self.run_check(), '')
        self.env['FM_CLEAR_UNMERGED_NOW'] = str(NOW+7200)
        self.assertEqual(self.run_check(), '')
        self.env['FM_CLEAR_UNMERGED_NOW'] = str(NOW+7201)
        self.assertIn('age=7201s', self.run_check())

    def test_later_non_clear_review_blocks(self):
        later = self.home/'data/review2/report.md'
        later.parent.mkdir()
        later.write_text('# Changes requested\n'+URL+' '+SHA)
        os.utime(later, (NOW-7230, NOW-7230))
        self.assertEqual(self.run_check(), '')
        os.utime(later, (NOW-7300, NOW-7300))
        self.assertIn(URL, self.run_check())

    def test_bad_pr_or_project_does_not_silence_others(self):
        bad = json.loads(json.dumps(self.pr))
        bad['url'] = 'https://github.com/example/demo/pull/6'
        bad['body'] = 'Carve-outs: maybe'
        self.forge(prs=[bad, self.pr])
        self.report('# CLEAR\n'+bad['url']+' '+URL+' '+SHA, NOW-7260)
        subprocess.run(['git', 'init', '-q', str(self.home/'projects/other')], check=True)
        subprocess.run(['git', '-C', str(self.home/'projects/other'), 'remote', 'add', 'origin', '/srv/other.git'], check=True)
        (self.home/'data/projects.md').write_text('- demo [no-mistakes] - demo\n- other [no-mistakes] - other\n')
        out = self.run_check()
        self.assertIn('CLEAR unmerged: '+URL, out)
        self.assertIn('pull/6 has invalid Carve-outs', out)
        self.assertIn('other:', out)
        self.assertNotIn('pull/6', json.loads((self.home/'state/.clear-unmerged.json').read_text())['alerted'][0])

    def test_alerted_pr_does_not_spend_budget_needed_by_next(self):
        alerted, later = (json.loads(json.dumps(self.pr)) for _ in range(2))
        alerted['url'] = 'https://github.com/example/demo/pull/6'
        later['url'] = 'https://github.com/example/demo/pull/8'
        self.forge(prs=[alerted, self.pr, later])
        self.report('# CLEAR\n'+' '.join([alerted['url'], URL, later['url'], SHA]), NOW-7260)
        (self.home/'state/.clear-unmerged.json').write_text(json.dumps(
            dict(schema=1, alerted=[alerted['url']+'@'+SHA], error='')))
        for number in ('6', '8'):
            (self.home/('slow-diff-'+number)).touch()
        self.env['FM_CHECK_TIMEOUT'] = '6'
        out = self.run_check()
        self.assertIn('CLEAR unmerged: '+URL, out)
        self.assertNotIn('unavailable', out)
        record = json.loads((self.home/'state/.clear-unmerged.json').read_text())
        self.assertEqual(record['alerted'], [alerted['url']+'@'+SHA, URL+'@'+SHA])
        self.assertEqual(set(record['heads']), {alerted['url'], URL, later['url']})

    def test_closed_pr_head_pruned_after_individual_read(self):
        self.run_check()
        state = self.home/'state/.clear-unmerged.json'
        self.assertIn(URL, json.loads(state.read_text())['heads'])
        (self.home/'forge-error').touch()
        self.run_check()
        self.assertIn(URL, json.loads(state.read_text())['heads'])
        (self.home/'forge-error').unlink()
        other = json.loads(json.dumps(self.pr))
        other['state'] = 'CLOSED'
        self.forge(prs=[other])
        self.run_check()
        record = json.loads(state.read_text())
        self.assertEqual(record['heads'], {})
        self.assertIn(URL+'@'+SHA, record['alerted'])

    def test_missing_paths_and_malformed_declaration_refuse(self):
        self.pr['body'] = 'Improve monitoring'
        self.pr['files']['pageInfo']['hasNextPage'] = True
        self.forge()
        self.assertIn('incomplete changed paths', self.run_check())
        self.pr['body'] = 'Carve-outs: none, payments'
        self.forge()
        self.assertIn('invalid Carve-outs', self.run_check())

    def test_real_captain_hold_producer(self):
        (self.home/'fakebin/tasks-axi').unlink()
        (self.home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        for args in (['fm-tasks-axi.sh', 'add', 'ship', 'Wait for decision', '--repo', 'demo'],
                     ['fm-captain-hold.sh', 'hold', 'ship', '--reason', 'Await decision']):
            r = subprocess.run(['bash', str(ROOT/'bin'/args[0]), *args[1:]], env=self.env,
                               text=True, capture_output=True, timeout=15)
            self.assertEqual(r.returncode, 0, r.stdout+r.stderr)
        (self.home/'state/ship.meta').write_text('pr='+URL+'\n')
        self.assertEqual(self.run_check(), '')

    def test_related_captain_hold_origin(self):
        body = 'Origin: ship\nA decision with "quotes", commas and '+URL
        row = ','.join(['decision', 'queued', 'task', 'demo', 'Wait', 'captain', 'none', json.dumps(body)])
        (self.home/'tasks').write_text('count: 1\ntasks[1]{id,state,kind,repo,title,hold_kind,links,body}:\n  '+row+'\n')
        self.assertEqual(self.run_check(), '')
        body = 'Origin: ship\nNo PR link required'
        row = ','.join(['decision', 'queued', 'task', 'demo', 'Wait', 'captain', 'none', json.dumps(body)])
        (self.home/'tasks').write_text('count: 1\ntasks[1]{id,state,kind,repo,title,hold_kind,links,body}:\n  '+row+'\n')
        (self.home/'state/ship.meta').write_text('pr='+URL+'\n')
        self.assertEqual(self.run_check(), '')

    def test_real_watcher_publishes_durable_alert(self):
        self.run_check('arm')
        env = dict(self.env, FM_POLL='1', FM_SIGNAL_GRACE='1', FM_CHECK_INTERVAL='1',
                   FM_HEARTBEAT='999999', FM_WATCH_HANDLING_SUCCESSOR='0')
        r = subprocess.run(['bash', str(ROOT/'bin/fm-watch-checkpoint.sh'), '--seconds', '10'],
                           env=env, text=True, capture_output=True, timeout=15)
        self.assertEqual(r.returncode, 0, r.stdout+r.stderr)
        self.assertIn('check:', r.stdout)
        self.assertIn(URL, r.stdout)
        queue = (self.home/'state/.wake-queue').read_text()
        self.assertIn(URL, queue)
        self.assertIn('bin/fm-pr-merge.sh', queue)

    def test_refuse_symlink_arm(self):
        target = self.home/'target'
        target.write_text('preserve')
        (self.home/'state/clear-unmerged.check.sh').symlink_to(target)
        r = subprocess.run(['bash', str(CHECK), 'arm'], env=self.env, text=True, capture_output=True)
        self.assertNotEqual(r.returncode,0)
        self.assertEqual(target.read_text(),'preserve')

    def test_arm_register_execute_disarm(self):
        self.assertIn('armed', self.run_check('arm'))
        shim = self.home/'state/clear-unmerged.check.sh'
        self.assertTrue(shim.exists())
        self.assertTrue((self.home/'state/clear-unmerged.check-trust').exists())
        result = subprocess.run(['bash', str(shim)], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(URL,result.stdout)
        self.assertIn('unregistered', self.run_check('disarm'))
        self.assertFalse(shim.exists())
        self.assertFalse((self.home/'state/clear-unmerged.check-trust').exists())

unittest.main()
PY
