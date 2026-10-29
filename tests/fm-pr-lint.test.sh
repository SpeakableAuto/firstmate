#!/usr/bin/env bash
# Exercise the linter CLI, real evidence excerpts, and opt-in scaffold behavior.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT
python3 - <<'PY'
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ['ROOT'])
TOOL = ROOT / 'bin/fm-pr-lint.py'
GOOD = '''Goal: incomplete evidence is caught before use.
NOT PROVEN WHERE USERS SEE IT: isolated staging is unavailable.
Carve-outs: none
Staff-facing: no
## Verification
| Command | Exit |
| --- | --- |
| `python3 -m unittest` | 0 |
'''


class Linter(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def run_lint(self, body, *args):
        p = self.root / 'body.md'
        p.write_text(body)
        return subprocess.run(['python3', str(TOOL), '--file', str(p), *args],
                              text=True, capture_output=True)

    def brief(self, intent, spec='Write the requested report.'):
        return GOOD + "\n## Captain's intent\n" + intent + "\n## Firstmate spec\n" + spec + "\n"

    def assert_depth_refused(self, body):
        result = self.run_lint(body, '--kind', 'brief')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('refuse: research-depth; fix:', result.stderr)
        for fix in ('every item', 'complete coverage', 'page', 'Captain', 'Zac asked'):
            self.assertIn(fix, result.stderr)

    def test_rule23_source_cases(self):
        data = json.loads((ROOT/'tests/fixtures/brief-depth-rule23.json').read_text())
        for intent in [data['not_this'], *data['refused']]:
            with self.subTest(intent=intent):
                self.assert_depth_refused(self.brief(intent))
        for intent in [data['do_this'], data['accepted_exception'], *data['allowed']]:
            with self.subTest(intent=intent):
                result = self.run_lint(self.brief(intent), '--kind', 'brief')
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_research_depth_cap_variants(self):
        for activity in ('Research', 'Study', 'Audit', 'Learn from', 'Inventory', 'Review of'):
            for cap in ('top-3 ideas', 'best 10 ideas', 'a few ideas', 'shortlist of 5 ideas',
                        'five key findings', 'maximum of 3 useful recommendations'):
                with self.subTest(activity=activity, cap=cap):
                    self.assert_depth_refused(self.brief(f'{activity} the tool and return {cap}.'))
        self.assert_depth_refused(self.brief('Understand the tool.', 'Research it and return the top 5 ideas.'))
        self.assert_depth_refused(GOOD.replace('incomplete evidence is caught before use.',
                                              'Research the tool and return the top 5 ideas.'))

    def test_research_depth_exception_provenance(self):
        for mention in ('Zac asked for the top 3.', 'Zac wants the best five.', 'Zac requested the 3 best.'):
            with self.subTest(mention=mention):
                result = self.run_lint(self.brief('Research the tool. '+mention), '--kind', 'brief')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_depth_refused(self.brief('Research the tool and return the top 3.', mention))
        for mention in ('Zac asked not to cap at the top 3.',
                        '<!-- Zac asked for the top 3. -->',
                        '```text\nZac asked for the top 3.\n```'):
            self.assert_depth_refused(self.brief('Research the tool and return the top 3.\n'+mention))
        result = self.run_lint(self.brief('Research the tool.\n> Zac asked for the top 3.'), '--kind', 'brief')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_research_depth_scope(self):
        for intent in ('Build a UI listing the top 5 bookings.', 'Research the tool without limiting findings.',
                       'Learn from the tool and inventory every option.'):
            result = self.run_lint(self.brief(intent), '--kind', 'brief')
            self.assertEqual(result.returncode, 0, result.stderr)
        body = self.brief('Research the tool and return the top 5 ideas.')
        self.assertEqual(self.run_lint(body).returncode, 0)
        wrapped = '# Worker role\nResearch examples: top 5 ideas.\n# Task\n'+self.brief('Build a UI listing the top 5 bookings.')
        wrapped += '# Standing orders\nResearch everything, never a top 5.\n'
        result = self.run_lint(wrapped, '--kind', 'brief')
        self.assertEqual(result.returncode, 0, result.stderr)
        body = self.brief('Research the tool and return the top 5 ideas.')
        body += '\n## Verification\nZac asked for the top 5.\n'
        self.assert_depth_refused(body)
        self.assert_depth_refused('# Worker role\n# Task\n'+self.brief('Research the tool and return the top 5 ideas.')+'# Rules\nFix bugs.\n')

    def test_research_depth_scaffold(self):
        home = self.root/'depth-home'
        (home/'config').mkdir(parents=True)
        env = dict(os.environ, FM_HOME=str(home))
        for key in ('FM_ROOT_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE'):
            env.pop(key, None)
        task = self.root/'task.md'
        task.write_text(self.brief('Research pstack and return the top 5 ideas we can borrow.'))
        def scaffold(name):
            return subprocess.run(['bash', str(ROOT/'bin/fm-brief.sh'), name, 'demo',
                                   '--scout', '--task-file', str(task)],
                                  env=env, text=True, capture_output=True)
        for setting in (None, 'off', 'on'):
            config = home/'config/brief-pr-lint'
            if setting is not None:
                config.write_text(setting+'\n')
            name = 'depth-'+str(setting)
            result = scaffold(name)
            if setting == 'on':
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn('research-depth', result.stderr)
                self.assertFalse((home/'data'/name).exists())
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('return the top 5 ideas', (home/'data'/name/'brief.md').read_text())
        task.write_text(self.brief('Research the market. Zac asked for the top 3 competitors only.'))
        result = scaffold('depth-authorized')
        self.assertEqual(result.returncode, 0, result.stderr)
        emitted = (home/'data/depth-authorized/brief.md').read_text()
        self.assertEqual(self.run_lint(emitted, '--kind', 'brief').returncode, 0)

    def test_complete(self):
        r = self.run_lint(GOOD)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_each_missing_field_names_fix(self):
        for removed, error in [('Goal: incomplete evidence is caught before use.\n', 'goal'),
                               ('Carve-outs: none\n', 'carve-outs'),
                               ('Staff-facing: no\n', 'staff-facing'),
                               ('## Verification', 'verification'),
                               ('| `python3 -m unittest` | 0 |', 'command'),
                               ('NOT PROVEN WHERE USERS SEE IT: isolated staging is unavailable.\n', 'live-proof')]:
            with self.subTest(error=error):
                r = self.run_lint(GOOD.replace(removed, ''))
                self.assertEqual(r.returncode, 1, r.stderr)
                self.assertIn(error, r.stderr)
                self.assertIn('fix:', r.stderr)

    def test_carve_out_paths_and_text(self):
        for path, category in [('src/stripe/refund.ts', 'payments'),
                               ('src/card.ts', 'payments'),
                               ('src/credit-card.ts', 'payments'),
                               ('src/debit_card.ts', 'payments'),
                               ('app/login.ts', 'logins-keys-secrets'),
                               ('db/migrations/004.sql', 'shared-database-schema')]:
            with self.subTest(path=path):
                r = self.run_lint(GOOD, '--changed-path', path)
                self.assertEqual(r.returncode, 1)
                self.assertIn(category, r.stderr)
                r = self.run_lint(GOOD.replace('Carve-outs: none', 'Carve-outs: '+category),
                                  '--changed-path', path)
                self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.run_lint(GOOD+'\nChanges Stripe partial refunds.\n').returncode, 1)

    def test_broad_prose_carve_outs(self):
        for text, category in [
                ('Moves the booking checkout total to the new pricing helper', 'payments'),
                ('Rotates the webhook signing keys', 'logins-keys-secrets'),
                ('Rotates the integration tokens', 'logins-keys-secrets')]:
            for kind in ('pr', 'brief'):
                with self.subTest(text=text, kind=kind):
                    body = GOOD+'\n'+text+'\n'
                    result = self.run_lint(body, '--kind', kind)
                    self.assertEqual(result.returncode, 1, result.stdout)
                    self.assertIn('carve-outs/'+category, result.stderr)
                    declared = body.replace('Carve-outs: none', 'Carve-outs: '+category)
                    result = self.run_lint(declared, '--kind', kind)
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_card_goal_requires_payments_classification(self):
        for wording in ('card', 'credit-card', 'debit card'):
            for kind in ('pr', 'brief'):
                with self.subTest(wording=wording, kind=kind):
                    body = GOOD.replace('incomplete evidence is caught before use.',
                                        f'store a customer {wording} reference for future use.')
                    result = self.run_lint(body, '--kind', kind)
                    self.assertEqual(result.returncode, 1, result.stdout)
                    self.assertIn('carve-outs/payments', result.stderr)
                    declared = body.replace('Carve-outs: none', 'Carve-outs: payments')
                    result = self.run_lint(declared, '--kind', kind)
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_verification_tables(self):
        piped = GOOD.replace('`python3 -m unittest`', '`git log --oneline \\| head -3`')
        self.assertEqual(self.run_lint(piped).returncode, 0, self.run_lint(piped).stderr)
        for command in ('``grep -n \'`x`\' file``', '`` `x` ``', '``echo `pwd` \\| wc``', '```a``b```'):
            with self.subTest(command=command):
                body = GOOD.replace('`python3 -m unittest`', command)
                self.assertEqual(self.run_lint(body).returncode, 0, self.run_lint(body).stderr)
        for command in ('``pwd`', '`pwd``', '``', '` `', '`` ``', '`a`b`', '``a``b``'):
            with self.subTest(command=command):
                body = GOOD.replace('`python3 -m unittest`', command)
                self.assertIn('verification-command', self.run_lint(body).stderr)
        hand = GOOD+'\nChecked by hand:\n\n| Check | Result |\n| --- | --- |\n| Opened the page | looked right |\n'
        self.assertEqual(self.run_lint(hand).returncode, 0, self.run_lint(hand).stderr)
        after = GOOD+'\n| Command | Exit |\n| --- | --- |\n| `pwd` | pending |\n'
        self.assertIn('verification-command', self.run_lint(after).stderr)

    def test_diff_carve_outs(self):
        url = 'https://github.com/example/repo/pull/1'
        def lint_diff(diff):
            return subprocess.run(['python3', str(TOOL), '--pr-url', url],
                                  env=self.forge(diff=diff), text=True, capture_output=True)
        real = (ROOT/'tests/fixtures/firstmate-pr41.diff').read_text()
        r = lint_diff(real)
        self.assertEqual(r.returncode, 0, r.stderr)
        ordinary = ('diff --git a/bin/x.sh b/bin/x.sh\n--- a/bin/x.sh\n+++ b/bin/x.sh\n'
                    '+git checkout -b demo\n+for k in d.keys(): tokens.append(k)\n'
                    '+card = render_summary_card(data)\n')
        r = lint_diff(ordinary)
        self.assertEqual(r.returncode, 0, r.stderr)
        for line, category in [('+const intent = await stripe.paymentIntents.create({ amount });', 'payments'),
                               ('+const key = process.env.STRIPE_SECRET_KEY;', 'logins-keys-secrets'),
                               ("+jwt.sign(payload, secret, { expiresIn: '1h' });", 'logins-keys-secrets'),
                               ('+ALTER TABLE portal_users ADD COLUMN role text;', 'shared-database-schema'),
                               ('+model Booking {', 'shared-database-schema')]:
            with self.subTest(line=line):
                r = lint_diff('diff --git a/src/app.ts b/src/app.ts\n--- a/src/app.ts\n+++ b/src/app.ts\n'+line+'\n')
                self.assertEqual(r.returncode, 1)
                self.assertIn('carve-outs/'+category, r.stderr)

    def test_staff_update(self):
        staff = GOOD.replace('Staff-facing: no', 'Staff-facing: yes')
        self.assertIn('admin-update', self.run_lint(staff).stderr)
        self.assertEqual(self.run_lint(staff+'\nAdmin Update: https://admin.example.org/updates/4 | Coming soon\n').returncode, 0)
        self.assertEqual(self.run_lint(staff+'\nAdmin Update: https://admin.example.org/updates/4 | Draft\n').returncode, 1)

    def test_evidence_cannot_be_hidden_or_placeholder(self):
        self.assertEqual(self.run_lint('```markdown\n'+GOOD+'```\n').returncode, 1)
        self.assertEqual(self.run_lint(GOOD.replace('Goal: incomplete evidence is caught before use.', 'Goal: TODO')).returncode, 1)
        self.assertEqual(self.run_lint(GOOD.replace('| 0 |', '| pending |')).returncode, 1)
        self.assertEqual(self.run_lint(GOOD+'\nCarve-outs: payments\n').returncode, 1)
        self.assertEqual(self.run_lint('<!--\n'+GOOD+'\n-->').returncode, 1)
        self.assertEqual(self.run_lint(GOOD.replace('Carve-outs: none', 'Carve-outs: none, payments')).returncode, 1)

    def test_live_link_and_false_positive_explanation(self):
        proven = GOOD.replace('NOT PROVEN WHERE USERS SEE IT: isolated staging is unavailable.\n', '')
        self.assertEqual(self.run_lint(proven+'\nLive proof: https://evidence.example.org/outcome/4\n').returncode, 0)
        self.assertEqual(self.run_lint(proven+'\nLive proof: javascript:alert(1)\n').returncode, 1)
        review = GOOD+'\nCarve-out review: shared-database-schema | This is the local JSON fixture schema, not a database change.\n'
        self.assertEqual(self.run_lint(review, '--changed-path', 'tests/schema.json').returncode, 0)
        self.assertEqual(self.run_lint(GOOD.replace('python3 -m unittest', 'pwd')).returncode, 0)
        disclosure = GOOD.replace('NOT PROVEN WHERE USERS SEE IT: isolated staging is unavailable.',
                                  '**NOT PROVEN WHERE USERS SEE IT**\n\nIsolated staging is unavailable.')
        self.assertEqual(self.run_lint(disclosure).returncode, 0)
        marker = self.root/'never-execute'
        self.assertEqual(self.run_lint(GOOD.replace('python3 -m unittest', 'touch '+str(marker))).returncode, 0)
        self.assertFalse(marker.exists())

    def forge(self, body=GOOD, diff='', mode='ok'):
        fixture = self.root/'forge.json'
        fixture.write_text(json.dumps({'body': body, 'diff': diff, 'mode': mode}))
        fake = self.root/'gh-axi'
        fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
p=pathlib.Path(os.environ['FORGE_FIXTURE'])
d=json.loads(p.read_text())
if sys.argv[1]=='api':
    n=int(p.with_suffix('.count').read_text()) if p.with_suffix('.count').exists() else 0
    p.with_suffix('.count').write_text(str(n+1))
    print('api_response:\\n  body: '+('b'*40 if d['mode']=='changed' and n else 'a'*40)+'\\n  truncated: false')
elif sys.argv[2]=='view':
    print('pull_request:\\n  body: '+json.dumps(d['body']))
elif sys.argv[2]=='diff':
    print('pr_diff:\\n  diff: '+json.dumps(d['diff']))
if d['mode']=='truncated': print('  truncated: true')
''')
        fake.chmod(0o755)
        return dict(os.environ, PATH=str(self.root)+os.pathsep+os.environ['PATH'], FORGE_FIXTURE=str(fixture))

    def test_forge_reads_and_head_race(self):
        for mode, expected in [('ok', 0), ('changed', 1), ('truncated', 1)]:
            with self.subTest(mode=mode):
                count = self.root/'forge.count'
                count.unlink(missing_ok=True)
                r = subprocess.run(['python3', str(TOOL), '--pr-url', 'https://github.com/example/repo/pull/1'],
                                   env=self.forge(mode=mode), text=True, capture_output=True)
                self.assertEqual(r.returncode, expected, r.stderr)
        # Body says none, but a removed/renamed credential path still needs review.
        r = subprocess.run(['python3', str(TOOL), '--pr-url', 'https://github.com/example/repo/pull/1'],
                           env=self.forge(diff='--- a/src/secrets.py\n+++ b/src/utils.py\n'), text=True, capture_output=True)
        self.assertEqual(r.returncode, 1)
        self.assertIn('logins-keys-secrets', r.stderr)

    def test_pr_registration_refuses_before_side_effects(self):
        home = self.root/'home'
        (home/'config').mkdir(parents=True)
        (home/'state').mkdir()
        (home/'config/brief-pr-lint').write_text('on\n')
        meta = home/'state/task.meta'
        original = 'kind=ship\nmode=no-mistakes\n'
        meta.write_text(original)
        env = self.forge(body='Missing everything.')
        env['FM_HOME'] = str(home)
        for k in ('FM_ROOT_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE'):
            env.pop(k, None)
        r = subprocess.run(['bash', str(ROOT/'bin/fm-pr-check.sh'), 'task', 'https://github.com/example/repo/pull/1'],
                           env=env, text=True, capture_output=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('refuse: goal', r.stderr)
        self.assertEqual(meta.read_text(), original)
        self.assertEqual(list((home/'state').iterdir()), [meta])

    def test_real_evidence(self):
        data = json.loads((ROOT/'tests/fixtures/pr-lint-evidence.json').read_text())
        for item in data['sources']:
            with self.subTest(source=item['source']):
                raw = item['text']
                r = self.run_lint(raw)
                self.assertEqual(r.returncode, 1)
                self.assertIn('refuse: goal', r.stderr)
                if 'refuses' in item:
                    shaped = GOOD.replace('## Verification', raw+'\n## Verification')
                    r = self.run_lint(shaped)
                    self.assertEqual(r.returncode, 1)
                    for code in item['refuses']:
                        self.assertIn('refuse: '+code+';', r.stderr)
                    if 'staff-facing' in item['refuses']:
                        r = self.run_lint(shaped.replace('Staff-facing: no', 'Staff-facing: yes'))
                        self.assertIn('refuse: admin-update;', r.stderr)
                if 'head' in item:
                    corrected = GOOD[:GOOD.index('## Verification')] + raw
                else:
                    # Preserve the actual transcript as a quoted artifact; add explicit
                    # shape evidence, not an invented claim that its release occurred.
                    corrected = GOOD+'\n## Source transcript\n```text\n'+raw+'\n```\n'
                result = self.run_lint(corrected)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_opt_in_scaffold(self):
        home = self.root/'home'
        (home/'config').mkdir(parents=True)
        env = dict(os.environ, FM_HOME=str(home))
        for k in ('FM_ROOT_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE'):
            env.pop(k, None)
        def scaffold(task, *args):
            return subprocess.run(['bash', str(ROOT/'bin/fm-brief.sh'), task, 'demo',
                                   '--mode', 'direct-PR', *args], env=env, text=True, capture_output=True)
        self.assertEqual(scaffold('legacy').returncode, 0)
        (home/'config/brief-pr-lint').write_text('on\n')
        r = scaffold('missing')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('--task-file', r.stderr)
        self.assertFalse((home/'data/missing/brief.md').exists())
        task = self.root/'task.md'
        task.write_text(GOOD+"\n## Captain's intent\nCatch missing evidence.\n## Firstmate spec\nUse the linter.\n")
        r = scaffold('complete', '--task-file', str(task))
        self.assertEqual(r.returncode, 0, r.stderr)
        emitted = (home/'data/complete/brief.md').read_text()
        self.assertIn(GOOD, emitted)
        self.assertEqual(self.run_lint(emitted, '--kind', 'brief').returncode, 0)
        (home/'config/brief-pr-lint').write_text('typo\n')
        self.assertNotEqual(scaffold('bad-config', '--task-file', str(task)).returncode, 0)


unittest.main()
PY
