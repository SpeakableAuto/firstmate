"""Replay placement failure conditions through admission and queue entrypoints.

Machine measurements, endpoint observations, vendor quota, and backlog probing are fixtures.
The disabled-gate control omits the opt-in machine profile before admission,
exercising the production unconfigured-home bypass, not a mock admission result.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT, TEMP, SELECT = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
DISABLED = os.environ.get('FM_TEST_PLACEMENT_GATE_DISABLED') == '1'
NOW = 1793638800  # Fixed scenario clock; ages below are relative to this instant.


class PlacementScenarios(unittest.TestCase):
    def setUp(self):
        self.base = TEMP / self.id().split('.')[-1]
        self.base.mkdir()
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.drive = self.base / 'drive'
        (self.drive / 'pool').mkdir(parents=True)
        (self.drive / 'Build').mkdir()
        self.project = self.base / 'project'
        self.project.mkdir()
        (self.project / 'treehouse.toml').write_text('root = ' + json.dumps(str(self.drive / 'pool')) + '\n')
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        REAL_PYTHON=sys.executable, FM_TEST_NOW=str(NOW),
                        FM_TEST_DRIVE=str(self.drive), FM_TEST_DRIVE_UP='1')
        self.tool('tmux', """case "$1" in
list-windows)
  if [ -f "$FM_HOME/tmux-unreadable" ]; then echo 'server busy' >&2; exit 1; fi
  for meta in "$FM_HOME/state/"*.meta; do
    [ -f "${meta%.meta}.live" ] || continue
    basename "$meta" .meta
  done;;
display-message)
  [ "${@: -1}" != '#{pane_current_command}' ] || printf 'codex';;
*) exit 1;;
esac
""")
        self.tool('df', 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\\nfixture 99999999 1 41943040 1%% /\\n"\n')
        self.tool('quota-axi', '''printf '%s\\n' '{"schemaVersion":5,"providers":[{"provider":"codex","state":{"stale":false},"windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":62,"runway":{"status":"through_reset"}}]}}]}'
''')
        self.tool('tasks-axi', '''case "$1" in
--version) echo 99.0.0;;
update) echo --archive-body;;
mv) echo '[<id>...]';;
show)
  for arg in "$@"; do
    if [ -f "$FM_HOME/hold-$arg" ]; then
      printf '  state: queued\\n  held: yes\\n  blocked: no\\n  hold_kind: external\\n'; exit 0
    fi
  done
  printf '  state: queued\\n  held: no\\n  blocked: no\\n';;
esac
''')
        wrapper = self.base / 'measurements.py'
        wrapper.write_text('''import importlib.util,os,sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('placement',sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
sys.argv=sys.argv[1:]
with patch.object(m.time,'time',return_value=int(os.environ['FM_TEST_NOW'])), patch.object(m,'memory',return_value=(80,0)), patch.object(Path,'is_mount',lambda p: str(p)==os.environ['FM_TEST_DRIVE'] and os.environ['FM_TEST_DRIVE_UP']=='1'), patch.object(m.os,'statvfs',return_value=SimpleNamespace(f_bavail=40,f_frsize=1024**3)):
 m.main()
''')
        self.tool('python3', 'if [[ "${1:-}" = */fm-placement.py ]]; then\n  exec "$REAL_PYTHON" ' + repr(str(wrapper)) + ' "$@"\nfi\nexec "$REAL_PYTHON" "$@"\n')

    def tool(self, name, body):
        path = self.bin / name
        path.write_text('#!/usr/bin/env bash\n' + body)
        path.chmod(0o755)

    def home(self, name, heavy=False, count=0):
        home = self.base / name
        for part in ('config', 'state', 'data'):
            (home / part).mkdir(parents=True)
        profile = dict(version=1, workloads=['iphone', 'website', 'big-tests'] if heavy else ['backend', 'review', 'scout'],
                       max_crew=4 if heavy else 3, min_free_memory_percent=15, max_swap_mib=512,
                       drive=str(self.drive) if heavy else None)
        if heavy:
            profile.update(required_drive_dirs=['Build'], data_volume=dict(path=str(home), min_free_gib=15))
        if not DISABLED:
            self.write(home / 'config/crew-placement.json', profile)
        self.write(home / 'config/crew-dispatch.json', dict(rules=[dict(when='fixture task fit', use=[dict(harness='codex', model='test', effort='high')])]))
        (home / 'data/backlog.md').write_text('## Queued\n')
        for i in range(count):
            self.live(home, f'occupant-{i}')
        return home

    @staticmethod
    def live(home, name):
        (home / f'state/{name}.meta').write_text(f'kind=ship\nharness=codex\nbackend=tmux\nwindow=fixture:{name}\n')
        (home / f'state/{name}.live').touch()

    def crew_count(self, home):
        script = '''SCRIPT_DIR=$1/bin
STATE=$FM_STATE_OVERRIDE FM_PLACEMENT_ID=candidate
. "$SCRIPT_DIR/fm-backend.sh"
. "$SCRIPT_DIR/fm-claude-admission-lib.sh"
. "$SCRIPT_DIR/fm-placement-lib.sh"
absence=$(fm_control_endpoint_absence_verdict tmux fixture:parked-0)
[ "${absence%%$'\t'*}" = unproven ] || exit 1
fm_placement_count
'''
        result = subprocess.run(['bash', '-c', script, 'count', str(ROOT)], env=self.env_for(home), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        heavy, light = map(int, result.stdout.split())
        self.assertEqual(light, 0, 'no light_workloads configured, so every crew counts heavy')
        return heavy

    def test_live_only_crew_count(self):
        home = self.home('heavy', True)
        self.task(home, 'candidate', 'website')
        for i in range(65):
            name = f'parked-{i}'
            (home / f'state/{name}.meta').write_text(f'kind=ship\nbackend=tmux\nwindow=fixture:{name}\nstatus={"paused" if i % 2 else "done"}\n')
        count = self.crew_count(home)
        result = self.admit(home, 'candidate')
        reason = self.ledger(home)['decisions'][-1]['checks']['room']['reason']
        self.assertEqual((count, result.returncode), (0, 0), f'65 absent endpoints must not consume crew capacity: {reason}')
        self.assertIn('crew=0/4', reason)
        for i in range(4):
            self.live(home, f'live-{i}')
            self.assertEqual(self.crew_count(home), i + 1)
            result = self.admit(home, 'candidate')
            self.assertEqual(result.returncode == 0, i < 3, result.stderr)
        self.assertIn('count=4, cap=4', self.ledger(home)['decisions'][-1]['checks']['room']['reason'])

    def test_unreadable_crew_liveness_refuses_room(self):
        home = self.home('heavy', True, count=4)
        self.task(home, 'candidate', 'website')
        (home / 'tmux-unreadable').touch()
        result = self.admit(home, 'candidate')
        room = self.ledger(home)['decisions'][-1]['checks']['room']
        self.assertNotEqual(result.returncode, 0, 'unreadable liveness must not admit')
        self.assertEqual((room['status'], room['reason']), ('fail', 'crew liveness unreadable: tmux'))

    def test_recent_launch_counts_toward_crew(self):
        home = self.home('heavy', True, count=3)
        self.task(home, 'candidate', 'website')
        launched = int(__import__('time').time()) - 10
        (home / 'state/fresh.meta').write_text(f'kind=ship\nbackend=tmux\nwindow=fixture:fresh\nspawn_gen=s{launched}.1.1\n')
        self.assertEqual(self.crew_count(home), 4)
        result = self.admit(home, 'candidate')
        self.assertNotEqual(result.returncode, 0, 'a crew launched 10 s ago must hold its slot')
        self.assertIn('count=4, cap=4', self.ledger(home)['decisions'][-1]['checks']['room']['reason'])

    @staticmethod
    def write(path, value):
        path.write_text(json.dumps(value))

    def task(self, home, name, workload, priority='P2'):
        data = home / 'data' / name
        data.mkdir()
        brief = ('Scenario task ' + name + '\n').encode()
        (data / 'brief.md').write_bytes(brief)
        self.write(data / 'placement.json', dict(version=1, workload=workload, requires_drive=workload in ('iphone', 'website', 'big-tests'),
                   dispatch_rule=0, brief_sha256=hashlib.sha256(brief).hexdigest()))
        with (home / 'data/backlog.md').open('a') as f:
            f.write(f'- [ ] {name} - Scenario task (impact: {priority})\n')

    def env_for(self, home):
        return dict(self.env, FM_HOME=str(home), FM_CONFIG_OVERRIDE=str(home / 'config'), FM_DATA_OVERRIDE=str(home / 'data'),
                    FM_STATE_OVERRIDE=str(home / 'state'), FM_WAKE_QUEUE=str(home / 'state/.wake-queue'),
                    FM_WAKE_QUEUE_LOCK=str(home / 'state/.wake-queue.lock'))

    def admit(self, home, task):
        # Same admission owner used by spawn, without allocating a worker.
        script = '''SCRIPT_DIR=$1/bin
CONFIG=$FM_CONFIG_OVERRIDE DATA=$FM_DATA_OVERRIDE STATE=$FM_STATE_OVERRIDE PROJ=$2
. "$SCRIPT_DIR/fm-wake-lib.sh"
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
. "$SCRIPT_DIR/fm-claude-admission-lib.sh"
. "$SCRIPT_DIR/fm-placement-lib.sh"
trap fm_placement_release EXIT
fm_placement_begin "$3" && fm_placement_check codex test high unknown
'''
        return subprocess.run(['bash', '-c', script, 'scenario', str(ROOT), str(self.project), task], env=self.env_for(home), capture_output=True, text=True)

    def tick(self, home):
        result = subprocess.run(['bash', str(ROOT / 'bin/fm-placement.sh'), 'tick'], env=self.env_for(home), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def ledger(self, home):
        path = home / 'state/capacity.json'
        return json.loads(path.read_text()) if path.exists() else dict(decisions=[], waits={})

    def rows(self, home):
        result = subprocess.run(['bash', str(ROOT / 'bin/fm-placement.sh'), 'waits'], env=self.env_for(home), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def age(self, home, ages):
        value = self.ledger(home)
        for name, seconds in ages.items():
            value['waits'][name]['since'] = NOW - seconds
        self.write(home / 'state/capacity.json', value)

    def wake_order(self, home):
        path = home / 'state/.wake-queue'
        if not path.exists():
            return []
        return [line.split('capacity-ready ')[1].split(':')[0] for line in path.read_text().splitlines() if 'capacity-ready ' in line]

    def refuse(self, home, name, check):
        result = self.admit(home, name)
        self.assertNotEqual(result.returncode, 0, f'{name}: unsafe placement admitted with gate disabled')
        decision = self.ledger(home)['decisions'][-1]
        self.assertIn(check, decision['failed'])
        self.assertTrue({'fit', 'room', 'quota', 'locks'} <= decision['checks'].keys())
        return decision

    def test_s13_kitchen_drive_missing(self):
        heavy = self.home('heavy', True)
        light = self.home('light', count=1)
        self.env['FM_TEST_DRIVE_UP'] = '0'
        for name, workload in [('website', 'website'), ('iphone', 'iphone'), ('tests', 'big-tests')]:
            self.task(heavy, name, workload)
            decision = self.refuse(heavy, name, 'drive')
            self.assertEqual(decision['checks']['data-disk']['status'], 'pass', '40 GiB internal disk does not waive drive rule')
            self.assertEqual(self.ledger(heavy)['waits'][name]['state'], 'capacity')
        self.task(light, 'review', 'review')
        self.assertEqual(self.admit(light, 'review').returncode, 0, 'light review can still run')
        self.tick(heavy)
        queue = (heavy / 'state/.wake-queue').read_text()
        self.assertEqual(queue.count('placement-condition'), 1, 'one alert for shared missing drive')
        self.assertEqual(self.wake_order(heavy), [])
        self.env['FM_TEST_DRIVE_UP'] = '1'
        (heavy / 'state/.capacity-freed').touch()
        self.tick(heavy)
        self.assertCountEqual(self.wake_order(heavy), ['website', 'iphone', 'tests'])

    def test_s14_iphone_build_0002(self):
        light = self.home('light', count=1)
        heavy = self.home('heavy', True, count=4)
        for home in [light, heavy]:
            self.task(home, 'iphone', 'iphone')
        self.refuse(light, 'iphone', 'fit')
        self.refuse(heavy, 'iphone', 'room')
        self.assertEqual(self.ledger(heavy)['waits']['iphone']['state'], 'capacity')
        self.tick(heavy)
        self.assertEqual(self.wake_order(heavy), [])
        (heavy / 'state/occupant-0.meta').unlink()
        self.tick(heavy)
        self.assertEqual(self.wake_order(heavy), ['iphone'])
        value = self.ledger(heavy)
        value['last_recheck'] -= 901
        self.write(heavy / 'state/capacity.json', value)
        self.tick(heavy)
        self.assertGreater(len(self.ledger(heavy)['decisions']), len(value['decisions']), '15 minute retry without manual event')

    def test_s17_capacity_queue_after_finish(self):
        home = self.home('light', count=3)
        for name, workload, impact in [('a', 'scout', 'P3'), ('b', 'backend', 'P2'), ('c', 'backend', 'P2'), ('d', 'backend', 'P1')]:
            self.task(home, name, workload, impact)
            self.refuse(home, name, 'room')
        # d was already held, not a two-day capacity wait converted now.
        held = subprocess.run(['python3', str(ROOT / 'bin/fm-placement.py'), 'hold', str(home / 'state'), 'd', 'captain'], env=self.env_for(home), capture_output=True, text=True)
        self.assertEqual(held.returncode, 0, held.stderr)
        self.age(home, dict(a=18300, b=3900, c=10800, d=172800))
        (home / 'hold-d').touch()
        (home / 'state/occupant-0.meta').unlink()
        self.tick(home)
        self.assertEqual(self.wake_order(home), ['c', 'b', 'a'])
        self.assertEqual(self.ledger(home)['waits']['d']['state'], 'hold')
        self.assertEqual([r['task'] for r in self.rows(home) if r['over_four_hours']], ['a'])
        # The next morning must report the bottleneck even if the scout started.
        self.assertEqual(self.admit(home, 'a').returncode, 0)
        rows = self.rows(home)
        self.assertTrue(any(r['task'] == 'a' and r['over_four_hours'] and r['state'] == 'history' for r in rows), 's17: served over-four-hour wait disappeared from morning report')
        self.tick(home)
        history = [r for r in self.rows(home) if r['task'] == 'a']
        self.assertEqual(len(history), 1, 'history is not requeued or duplicated')
        self.assertEqual(history[0]['wait_seconds'], 18300)
        self.assertEqual(history[0]['failed'], ['room'])
        self.env['FM_TEST_NOW'] = str(NOW + 86400)
        self.assertTrue(any(r['task'] == 'a' and r['state'] == 'history' for r in self.rows(home)), 'next morning retains resolved bottleneck')
        self.env['FM_TEST_NOW'] = str(NOW + 172801)
        self.assertFalse(any(r['task'] == 'a' for r in self.rows(home)), 'report window expires without deleting evidence')
        self.assertTrue(any(r['task'] == 'a' for r in self.ledger(home)['bottlenecks'].values()))

    def test_n15_queue_level_beats_age(self):
        home = self.home('light', count=3)
        for name, impact in [('a', 'P2'), ('b', 'P1'), ('c', 'P3')]:
            self.task(home, name, 'backend', impact)
            self.refuse(home, name, 'room')
        self.age(home, dict(a=25200, b=5400, c=106200))
        (home / 'state/occupant-0.meta').unlink()
        self.tick(home)
        self.assertEqual(self.wake_order(home), ['b', 'a', 'c'])
        self.assertEqual([r['task'] for r in self.rows(home) if r['over_four_hours']], ['a', 'c'])

    def test_n16_queue_fit_before_age(self):
        heavy = self.home('heavy', True, count=4)
        light = self.home('light', count=3)
        for home, name, workload, impact in [(light, 'a', 'backend', 'P2'), (heavy, 'a', 'backend', 'P2'), (heavy, 'b', 'iphone', 'P2'), (heavy, 'c', 'website', 'P1')]:
            self.task(home, name, workload, impact)
            self.refuse(home, name, 'fit' if home == heavy and name == 'a' else 'room')
        self.age(heavy, dict(a=7200, b=3600, c=10800))
        (heavy / 'hold-c').touch()
        (heavy / 'state/occupant-0.meta').unlink()
        self.tick(heavy)
        self.tick(light)
        self.assertEqual(self.wake_order(heavy), ['b'])
        self.assertEqual(self.wake_order(light), [])
        self.assertEqual(self.ledger(light)['waits']['a']['state'], 'capacity')
        self.assertEqual(self.ledger(heavy)['waits']['c']['state'], 'hold')
        decision = self.ledger(heavy)['decisions'][-1]
        self.assertTrue(all(decision['checks'][k]['status'] == 'pass' for k in ('fit', 'room', 'quota', 'locks')))


suite = unittest.defaultTestLoader.loadTestsFromTestCase(PlacementScenarios)
if SELECT:
    suite = unittest.TestSuite(t for t in suite if SELECT in t.id())
    if not suite.countTestCases():
        raise SystemExit('unknown scenario: ' + SELECT)
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(not result.wasSuccessful())
