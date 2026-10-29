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
GOOD = '''Goal: staff can find the newest notice.
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

    def test_complete(self):
        r = self.run_lint(GOOD)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_each_missing_field_names_fix(self):
        for removed, error in [('Goal: staff can find the newest notice.\n', 'goal'),
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

    def test_staff_update(self):
        staff = GOOD.replace('Staff-facing: no', 'Staff-facing: yes')
        self.assertIn('admin-update', self.run_lint(staff).stderr)
        self.assertEqual(self.run_lint(staff+'\nAdmin Update: https://admin.example.org/updates/4 | Coming soon\n').returncode, 0)
        self.assertEqual(self.run_lint(staff+'\nAdmin Update: https://admin.example.org/updates/4 | Draft\n').returncode, 1)

    def test_evidence_cannot_be_hidden_or_placeholder(self):
        self.assertEqual(self.run_lint('```markdown\n'+GOOD+'```\n').returncode, 1)
        self.assertEqual(self.run_lint(GOOD.replace('Goal: staff can find the newest notice.', 'Goal: TODO')).returncode, 1)
        self.assertEqual(self.run_lint(GOOD.replace('| 0 |', '| pending |')).returncode, 1)
        self.assertEqual(self.run_lint(GOOD+'\nCarve-outs: payments\n').returncode, 1)

    def test_real_evidence(self):
        data = json.loads((ROOT/'tests/fixtures/pr-lint-evidence.json').read_text())
        for item in data['sources']:
            with self.subTest(source=item['source']):
                raw = item['text']
                self.assertEqual(self.run_lint(raw).returncode, 1)
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
