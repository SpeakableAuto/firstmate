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
import os, sys, pathlib, time, json
h = pathlib.Path(os.environ['FM_HOME'])
with (h/'calls').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
if (h/'forge-error').exists():
    print('error: forbidden'); sys.exit(1)
if (h/'forge-sleep').exists(): time.sleep(10)
if sys.argv[1:3] == ['pr', 'diff']:
    if (h/'diff-error').exists(): print('error: missing diff'); sys.exit(1)
    print('pull_request:\\n  diff: '+json.dumps((h/'diff').read_text()))
elif sys.argv[1] == 'api' and '/pulls/' in sys.argv[2]:
    print('response:\\n  body: '+json.dumps((h/'head').read_text()))
else:
    print((h/'forge').read_text())
''')
        (self.home/'fakebin/tasks-axi').write_text('''#!/usr/bin/env python3
import os, pathlib
h = pathlib.Path(os.environ['FM_HOME'])
print((h/'tasks').read_text())
''')
        for p in (self.home/'fakebin').iterdir(): p.chmod(0o755)
        (self.home/'tasks').write_text('count: 0\ntasks: 0 tasks in this backlog\n')
        self.pr = dict(additions=1, url=URL, headRefOid=SHA, body='Goal: improve monitoring.\nCarve-outs: none',
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

    def test_due_once_with_evidence_and_merge_instruction(self):
        out = self.run_check()
        for text in (URL, SHA, str(self.home/'data/review/report.md'), '7260s', 'bin/fm-pr-merge.sh'):
            self.assertIn(text, out)
        self.assertNotIn('ask Zac', out)
        self.assertEqual(self.run_check(), '')
        calls = [json.loads(line) for line in (self.home/'calls').read_text().splitlines()]
        self.assertEqual(sum(call[:3] == ['api', 'POST', 'graphql'] for call in calls), 2)

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
            self.assertEqual(self.run_check(), '')
        self.report('# CLEAR - independent review\n'+URL+' '+SHA, NOW-7260)
        self.assertIn(URL, self.run_check())

    def test_large_body_transport_and_missing_chunk(self):
        self.pr['body'] += '\n' + ('Monitoring evidence. ' * 500)
        self.forge()
        original = (self.home/'forge').read_text()
        (self.home/'forge').write_text('\n'.join(original.splitlines()[:-1])+'\n')
        self.assertIn('missing complete PR data', self.run_check())
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

    def test_closed_pr_heads_pruned_after_complete_list(self):
        self.run_check()
        state = self.home/'state/.clear-unmerged.json'
        self.assertIn(URL, json.loads(state.read_text())['heads'])
        (self.home/'forge-error').touch()
        self.run_check()
        self.assertIn(URL, json.loads(state.read_text())['heads'])
        (self.home/'forge-error').unlink()
        other = json.loads(json.dumps(self.pr))
        other['url'] = 'https://github.com/example/demo/pull/8'
        self.forge(prs=[other])
        self.run_check()
        record = json.loads(state.read_text())
        self.assertEqual(list(record['heads']), [other['url']])
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
