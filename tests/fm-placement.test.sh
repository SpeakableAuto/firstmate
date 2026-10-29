#!/usr/bin/env bash
# Placement public calculator/ledger tests; no vendor, worktree, or worker starts.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-placement)
TOOL="$ROOT/bin/fm-placement.py"
CONFIG="$TMP_ROOT/config"
DATA="$TMP_ROOT/data"
STATE="$TMP_ROOT/state"
mkdir -p "$CONFIG" "$DATA/task-one" "$STATE"
printf 'Placement test brief\n' > "$DATA/task-one/brief.md"
hash=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$DATA/task-one/brief.md")
cat > "$CONFIG/crew-placement.json" <<'JSON'
{"version":1,"workloads":["backend","review","scout"],"max_crew":2,"min_free_memory_percent":15,"max_swap_mib":512,"drive":null}
JSON
cat > "$CONFIG/crew-dispatch.json" <<'JSON'
{"rules":[{"when":"backend","use":[{"harness":"codex","model":"test","effort":"high"}]}]}
JSON
jq -n --arg hash "$hash" '{version:1,workload:"backend",priority:"P1",requires_drive:false,dispatch_rule:0,brief_sha256:$hash}' > "$DATA/task-one/placement.json"
base='{"impact":"P1","crew_count":1,"memory":{"free_percent":50,"swap_mib":0},"disk":{"status":"pass"},"slots":{"status":"pass"},"quota":{"status":"pass"},"locks":{"status":"pass"}}'
assess() {
  printf '%s\n' "$1" | python3 "$TOOL" assess "$CONFIG" "$DATA" task-one codex test high
}
good=$(assess "$base")
assert_equals true "$(jq -r .admitted <<< "$good")" 'complete evidence admits'
for missing in quota locks memory disk; do
  bad=$(assess "$(jq --arg key "$missing" 'del(.[$key])' <<< "$base")")
  assert_equals false "$(jq -r .admitted <<< "$bad")" "missing $missing refuses"
done
for mutation in '.crew_count=2' '.memory.free_percent=14' '.memory.swap_mib=513'; do
  bad=$(assess "$(jq "$mutation" <<< "$base")")
  assert_equals fail "$(jq -r .checks.room.status <<< "$bad")" "$mutation refuses room"
done
cp "$DATA/task-one/placement.json" "$TMP_ROOT/work"
jq '.workload="iphone"' "$TMP_ROOT/work" > "$DATA/task-one/placement.json"
bad=$(assess "$base")
assert_equals fail "$(jq -r .checks.fit.status <<< "$bad")" 'iPhone builds refused on light profile'
assert_equals '["fit"]' "$(jq -c .failed <<< "$bad")" 'fit refusal still measures room and names only fit'
iphone=$bad
jq '.requires_drive=true' "$TMP_ROOT/work" > "$DATA/task-one/placement.json"
bad=$(assess "$base")
assert_equals fail "$(jq -r .checks.fit.status <<< "$bad")" 'drive work refused on a no-drive machine'
cp "$TMP_ROOT/work" "$DATA/task-one/placement.json"
printf 'changed\n' >> "$DATA/task-one/brief.md"
assert_equals false "$(assess "$base" | jq -r .admitted)" 'stale brief binding refuses'
printf 'Placement test brief\n' > "$DATA/task-one/brief.md"
bad=$(printf '%s\n' "$base" | python3 "$TOOL" assess "$CONFIG" "$DATA" task-one codex wrong high)
assert_equals fail "$(jq -r .checks.fit.status <<< "$bad")" 'model outside matched task-fit rule refuses'
cp "$CONFIG/crew-placement.json" "$TMP_ROOT/profile"
jq --arg drive "$TMP_ROOT" '.drive=$drive' "$TMP_ROOT/profile" > "$CONFIG/crew-placement.json"
assert_equals fail "$(assess "$base" | jq -r .checks.drive.status)" 'ordinary directory is not a real required drive'
mv "$TMP_ROOT/profile" "$CONFIG/crew-placement.json"
bad=$(assess "$(jq '.slots={status:"fail",reason:"refuse: slot cap reached"}' <<< "$base")")
assert_equals fail "$(jq -r .checks.slots.status <<< "$bad")" 'named slot refusal'
assert_contains "$(jq -r .checks.slots.reason <<< "$bad")" 'slot cap reached' 'slot seam reason retained'
pass 'fit, room, quota, locks and missing evidence refuse bad placement'

blocked=$(assess "$(jq '.crew_count=2' <<< "$base")")
printf '%s\n' "$blocked" | python3 "$TOOL" record "$STATE" task-one spawn >/dev/null
assert_equals '1:1' "$(jq -r '"\(.decisions|length):\(.waits|length)"' "$STATE/capacity.json")" 'one transaction publishes decision and wait'
for pair in 'p3:P3' 'p0-old:P0' 'p0-new:P0' 'p2:P2'; do
  id=${pair%:*}; priority=${pair#*:}
  jq --arg id "$id" --arg p "$priority" '.task=$id|.impact=$p' <<< "$blocked" |
    python3 "$TOOL" record "$STATE" "$id" spawn >/dev/null
done
# Pin historical times to prove age order and the report flag without sleeping.
jq '.waits["p0-old"].since=1|.waits["p0-new"].since=2' "$STATE/capacity.json" > "$STATE/next"
mv "$STATE/next" "$STATE/capacity.json"
waits=$(python3 "$TOOL" waits "$STATE")
assert_equals 'p0-old,p0-new,task-one,p2,p3' "$(jq -r 'map(.task)|join(",")' <<< "$waits")" 'P0-P3, oldest within level'
assert_equals true "$(jq -r '.[0].over_four_hours' <<< "$waits")" 'morning report flags waits older than four hours'
jq '.task="iphone-wait"' <<< "$iphone" | python3 "$TOOL" record "$STATE" iphone-wait spawn >/dev/null
jq '.waits["iphone-wait"].since=1' "$STATE/capacity.json" > "$STATE/next"
mv "$STATE/next" "$STATE/capacity.json"
iphone_row=$(python3 "$TOOL" waits "$STATE" | jq -c '.[]|select(.task=="iphone-wait")')
assert_equals unplaceable "$(jq -r .state <<< "$iphone_row")" 'fit refusal is unplaceable, not a capacity wait'
assert_equals '["fit"]:false' "$(jq -r '"\(.failed|tostring):\(.over_four_hours)"' <<< "$iphone_row")" 'unplaceable wait names fit and is never a capacity bottleneck'
python3 "$TOOL" drop "$STATE" iphone-wait >/dev/null
assert_equals due "$(python3 "$TOOL" due "$STATE")" 'first tick is due'
assert_equals '' "$(python3 "$TOOL" due "$STATE")" 'unchanged capacity does not busy poll'
touch "$STATE/.capacity-freed"
assert_equals due "$(python3 "$TOOL" due "$STATE")" 'slot release triggers automatic recheck'
jq '.last_recheck-=901' "$STATE/capacity.json" > "$STATE/next"
mv "$STATE/next" "$STATE/capacity.json"
assert_equals due "$(python3 "$TOOL" due "$STATE")" 'fifteen minute recheck remains due without freeing events'
printf '%s\n' "$good" | python3 "$TOOL" record "$STATE" task-one recheck >/dev/null
assert_equals ready "$(jq -r '.waits["task-one"].state' "$STATE/capacity.json")" 'room release admits a waiting task for ordinary dispatch'
assert_equals P1 "$(jq -r '.waits["task-one"].impact' "$STATE/capacity.json")" 'recheck preserves task priority'
pass 'atomic queue ordering, freeing events, timed rechecks, and morning age flags'

# Independent processes must not lose any transaction or expose partial JSON.
pids=()
for n in 1 2 3 4 5 6 7 8; do
  (jq --arg id "concurrent-$n" '.task=$id' <<< "$blocked" |
    python3 "$TOOL" record "$STATE" "concurrent-$n" spawn >/dev/null) &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || fail 'concurrent write failed'; done
assert_equals 8 "$(jq '[.decisions[]|select(.task|startswith("concurrent-"))]|length' "$STATE/capacity.json")" 'concurrent decisions are all recorded'
assert_equals 8 "$(jq '[.waits|keys[]|select(startswith("concurrent-"))]|length' "$STATE/capacity.json")" 'concurrent refusals all retain waits'
pass 'concurrent atomic records retain every decision and wait'

# Exercise the real tick with command fixtures at the external evidence seams.
# No real vendor is queried and no production home is touched.
BIN="$TMP_ROOT/fakebin"
mkdir -p "$BIN"
REAL_PYTHON=$(command -v python3)
export REAL_PYTHON
cat > "$BIN/python3" <<'SH'
#!/usr/bin/env bash
if [ "${2:-}" = memory ]; then
  printf '%s\n' '{"free_percent":80,"swap_mib":0}'
else
  exec "$REAL_PYTHON" "$@"
fi
SH
cat > "$BIN/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 999999999 1 999999998 1%% /\n'
SH
cat > "$BIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) echo 99.0.0 ;;
  update) echo --archive-body ;;
  mv) echo '[<id>...]' ;;
  show)
    for arg in "$@"; do
      [ ! -f "$FM_HOME/missing-$arg" ] || { echo 'code: NOT_FOUND'; exit 1; }
      [ ! -f "$FM_HOME/done-$arg" ] || { printf '  state: done\n  held: no\n  blocked: no\n'; exit 0; }
    done
    if [ -f "$FM_HOME/held" ]; then
      printf '  state: queued\n  held: yes\n  blocked: no\n  hold_kind: captain\n'
    else
      printf '  state: queued\n  held: no\n  blocked: no\n'
    fi
    ;;
esac
SH
cat > "$BIN/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_QUOTA_FILE:-}" ]; then cat "$FM_TEST_QUOTA_FILE"; exit; fi
printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"codex","state":{"stale":false},"windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"}}]}}]}'
SH
chmod +x "$BIN/"*
# Start a separate ledger with only one queued request.
rm -f "$STATE/capacity.json"
printf '%s\n' "$blocked" | python3 "$TOOL" record "$STATE" task-one spawn >/dev/null
printf '# Backlog\n' > "$DATA/backlog.md"
jq '.max_crew=1' "$CONFIG/crew-placement.json" > "$CONFIG/next"
mv "$CONFIG/next" "$CONFIG/crew-placement.json"
printf 'kind=ship\nharness=codex\nbackend=unverifiable\nwindow=unknown\n' > "$STATE/occupant.meta"
tick() {
  env PATH="$BIN:$PATH" FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" \
    FM_WAKE_QUEUE="$STATE/.wake-queue" FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock" \
    bash "$ROOT/bin/fm-placement.sh" tick
}
tick > "$TMP_ROOT/tick.out" 2> "$TMP_ROOT/tick.err"
assert_equals capacity "$(jq -r '.waits["task-one"].state' "$STATE/capacity.json")" 'actual tick retains a full machine wait'
rm "$STATE/occupant.meta"
tick > "$TMP_ROOT/tick.out" 2> "$TMP_ROOT/tick.err"
assert_equals ready "$(jq -r '.waits["task-one"].state' "$STATE/capacity.json")" 'actual tick admits after crew metadata removal'
assert_contains "$(cat "$STATE/.wake-queue")" 'capacity-ready task-one' 'admission uses durable ordinary wake queue'
assert_equals '' "$(cat "$TMP_ROOT/tick.out")" 'capacity-ready is delivered only through the wake queue'
assert_equals 1 "$(grep -c 'capacity-ready task-one' "$STATE/.wake-queue")" 'one recheck queues one capacity-ready row'
assert_absent "$STATE/task-one.meta" 'retry cannot launch a worker itself'
count=$(jq '.decisions|length' "$STATE/capacity.json")
tick >/dev/null 2>&1
assert_equals "$count" "$(jq '.decisions|length' "$STATE/capacity.json")" 'recheck lock itself cannot trigger a polling loop'
touch "$TMP_ROOT/held" "$STATE/.capacity-freed"
tick >/dev/null 2>&1
assert_equals hold "$(jq -r '.waits["task-one"].state' "$STATE/capacity.json")" 'captain hold is excluded from capacity admission'
assert_equals "$count" "$(jq '.decisions|length' "$STATE/capacity.json")" 'held task does not run placement checks'
pass 'executable retry admits after freeing event, keeps holds, and never launches'

rm "$TMP_ROOT/held"
jq '.task="iphone-wait"' <<< "$iphone" | python3 "$TOOL" record "$STATE" iphone-wait spawn >/dev/null
for id in gone-task done-task; do
  jq --arg id "$id" '.task=$id' <<< "$blocked" | python3 "$TOOL" record "$STATE" "$id" spawn >/dev/null
done
touch "$TMP_ROOT/missing-gone-task" "$TMP_ROOT/done-done-task" "$STATE/.capacity-freed"
count=$(jq '.decisions|length' "$STATE/capacity.json")
tick >/dev/null 2>&1
assert_equals unplaceable "$(jq -r '.waits["iphone-wait"].state' "$STATE/capacity.json")" 'unplaceable wait stays listed for rerouting'
assert_equals 0 "$(jq '[.decisions[]|select(.task=="iphone-wait")]|length - 1' "$STATE/capacity.json")" 'unplaceable wait is never rechecked'
assert_equals null "$(jq -r '.waits["gone-task"]' "$STATE/capacity.json")" 'wait for a removed backlog row leaves the queue'
assert_equals null "$(jq -r '.waits["done-task"]' "$STATE/capacity.json")" 'wait for a done backlog row leaves the queue'
python3 "$TOOL" drop "$STATE" iphone-wait >/dev/null
pass 'fit refusals are not rechecked and finished or removed tasks leave the queue'

"$BIN/quota-axi" | jq '.providers[0].state.stale=true' > "$TMP_ROOT/stale-quota.json"
touch "$STATE/.capacity-freed"
FM_TEST_QUOTA_FILE="$TMP_ROOT/stale-quota.json" tick >/dev/null 2>&1
assert_equals capacity "$(jq -r '.waits["task-one"].state' "$STATE/capacity.json")" 'stale quota cannot admit a waiting task'
assert_contains "$(jq -r '.decisions[-1].checks.quota.reason' "$STATE/capacity.json")" 'stale' 'refusal names stale quota evidence'
effective=$(FM_HOME="$TMP_ROOT" FM_CONFIG_OVERRIDE="$CONFIG" bash "$ROOT/bin/fm-placement.sh" effective)
assert_equals '1:15:40:900' "$(jq -r '"\(.placement.max_crew):\(.disk.threshold_gib):\(.claude.floor):\(.recheck_seconds)"' <<< "$effective")" 'effective limits expose configured cap and owner defaults'
pass 'stale quota refuses and effective limits are inspectable'

SUP_STATE="$TMP_ROOT/supervision-only/state"
mkdir -p "$SUP_STATE"
printf '%s\n' "$blocked" | python3 "$TOOL" record "$SUP_STATE" task-one spawn >/dev/null
needed=$(bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_status "$2"; printf "%s" "$FM_SUP_NEEDED"' bash "$ROOT" "$SUP_STATE")
assert_equals true "$needed" 'capacity wait alone keeps supervision running'
UNPLACEABLE_STATE="$TMP_ROOT/unplaceable-only/state"
mkdir -p "$UNPLACEABLE_STATE"
printf '%s\n' "$iphone" | python3 "$TOOL" record "$UNPLACEABLE_STATE" task-one spawn >/dev/null
needed=$(bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_status "$2"; printf "%s" "$FM_SUP_NEEDED"' bash "$ROOT" "$UNPLACEABLE_STATE")
assert_equals false "$needed" 'unplaceable wait alone does not keep supervision running'
pass 'capacity waits remain watched without any live worker'

# One real spawn invocation proves the gate is wired ahead of allocation.
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"
SPAWN_HOME="$TMP_ROOT/spawn-home"
SPAWN_PROJECT="$TMP_ROOT/project"
fm_test_spawn_home "$SPAWN_HOME" codex
fm_test_spawn_brief "$SPAWN_HOME" iphone-task
fm_git_init_commit "$SPAWN_PROJECT"
SPAWN_BIN=$(fm_test_make_spawn_fakebin "$TMP_ROOT/spawn-tools" codex)
cp "$BIN/python3" "$BIN/df" "$BIN/quota-axi" "$SPAWN_BIN/"
cp "$CONFIG/crew-placement.json" "$CONFIG/crew-dispatch.json" "$SPAWN_HOME/config/"
hash=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$SPAWN_HOME/data/iphone-task/brief.md")
jq -n --arg hash "$hash" '{version:1,workload:"iphone",requires_drive:false,priority:"P0",dispatch_rule:0,brief_sha256:$hash}' > "$SPAWN_HOME/data/iphone-task/placement.json"
printf '## Queued\n- [ ] iphone-task - iPhone fixture (impact: P0) (priority: 3)\n' > "$SPAWN_HOME/data/backlog.md"
out=$(fm_test_run_spawn "$SPAWN_HOME" "$SPAWN_PROJECT" "$SPAWN_BIN" iphone-task "$SPAWN_PROJECT" --scout --harness codex --model test --effort high)
rc=$?
expect_code 1 "$rc" 'spawn refuses iPhone on a light machine'
assert_contains "$out" 'placement refused' 'spawn reports the placement failure'
assert_equals 1 "$(jq '.decisions|length' "$SPAWN_HOME/state/capacity.json")" 'spawn publishes exactly one atomic decision'
assert_equals P0 "$(jq -r '.waits["iphone-task"].impact' "$SPAWN_HOME/state/capacity.json")" 'spawn refusal preserves intake priority'
assert_absent "$SPAWN_HOME/state/iphone-task.meta" 'bad placement never publishes worker metadata'
assert_absent "$SPAWN_HOME/state/.placement-admission.lock" 'refusal releases admission lock'
fm_test_spawn_brief "$SPAWN_HOME" invalid-task
printf '%s\n' "$blocked" | jq '.task="invalid-task"' | python3 "$TOOL" record "$SPAWN_HOME/state" invalid-task spawn >/dev/null
printf -- '- [ ] invalid-task - Invalid project fixture (impact: P1)\n' >> "$SPAWN_HOME/data/backlog.md"
out=$(fm_test_run_spawn "$SPAWN_HOME" "$SPAWN_PROJECT" "$SPAWN_BIN" invalid-task "$TMP_ROOT/no-such-project" --scout --harness codex --model test --effort high)
rc=$?
expect_code 1 "$rc" 'spawn refuses a missing project'
assert_equals null "$(jq -r '.waits["invalid-task"]' "$SPAWN_HOME/state/capacity.json")" 'non-capacity spawn exit leaves no capacity wait'
assert_equals 'spawn ended before placement for a non-capacity reason' "$(jq -r '[.decisions[]|select(.task=="invalid-task")][-1].terminal' "$SPAWN_HOME/state/capacity.json")" 'non-capacity spawn exit records a terminal decision'
pass 'real spawn refuses bad placement before allocating a worker'

# Canonical impact wins conflicting legacy priority; missing impact defaults P2.
# shellcheck source=bin/fm-backlog-lib.sh
. "$ROOT/bin/fm-backlog-lib.sh"
cat > "$DATA/backlog.md" <<'BACKLOG'
## Queued
- [ ] p3 - Most urgent (impact: P0) (priority: 3)
- [ ] task-one - Ordinary (priority: 0)
BACKLOG
parsed=$(backlog_json "$DATA/backlog.md")
assert_equals P0 "$(jq -r '.records[0].impact' <<< "$parsed")" 'explicit impact is parsed'
assert_equals 'Most urgent' "$(jq -r '.records[0].title' <<< "$parsed")" 'impact metadata stripped from display title'
waits=$(printf '%s\n' "$parsed" | python3 "$TOOL" ordered "$STATE")
assert_equals P2 "$(jq -r '.[]|select(.task=="task-one")|.impact' <<< "$waits")" 'missing impact ignores legacy priority'
pass 'canonical impact and display title handling'

python3 - "$TOOL" "$TMP_ROOT" <<'PY'
import importlib.util
import io
import json
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('placement', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
base = Path(sys.argv[2]).resolve() / 'external'
base.mkdir()
drive = base / 'drive'
drive.mkdir()
project = base / 'repo'
project.mkdir()
pool = drive / 'pool'
pool.mkdir()
slot = pool / 'slot'
slot.mkdir()
internal = base / 'internal'
internal.mkdir()
relative = ['Build/DerivedData', 'Build/Tmp', 'Caches/npm', 'Caches/Playwright', 'SimulatorDevices', 'Logs/Codex']
for name in relative:
    (drive / name).mkdir(parents=True)
profile = dict(drive=str(drive), required_drive_dirs=relative,
               data_volume=dict(path=str(internal), min_free_gib=10))
config = project / 'treehouse.toml'
assert m.treehouse_root(profile, project)['status'] == 'fail', 'missing repo config'
config.write_text('root = ' + json.dumps(str(internal)) + '\n')
assert m.treehouse_root(profile, project)['status'] == 'fail', 'internal root refused'
link = drive / 'link'
link.symlink_to(pool, target_is_directory=True)
config.write_text('root = ' + json.dumps(str(link)) + '\n')
assert m.treehouse_root(profile, project)['status'] == 'fail', 'symlink root refused'
config.write_text('root = ' + json.dumps(str(pool)) + '\n')
assert m.treehouse_root(profile, project, slot)['status'] == 'pass', 'valid external allocation'
assert m.treehouse_root(profile, project, internal)['status'] == 'fail', 'wrong acquired path'
config.write_text('root = ' + json.dumps(str(pool)) + '\nworktree_path = "../escape"\n')
assert m.treehouse_root(profile, project)['status'] == 'fail', 'custom layout refused'
config.write_text('root = ' + json.dumps(str(pool)) + '\n')
with patch.object(Path, 'is_mount', return_value=False):
    assert m.external_checks(profile, project)['drive']['status'] == 'fail', 'stale mountpoint refused'
# Hardware evidence is mocked; directories and cleaned write probes are real.
with patch.object(Path, 'is_mount', return_value=True), patch.object(m.os, 'statvfs', return_value=SimpleNamespace(f_bavail=20, f_frsize=1024**3)):
    good = m.external_checks(profile, project)
    assert all(x['status'] == 'pass' for x in good.values()), good
    assert not list(drive.rglob('.fm-placement-*')), 'write probes cleaned'
    missing = drive / relative[0]
    missing.rmdir()
    assert m.external_checks(profile, project)['drive-dir:' + relative[0]]['status'] == 'fail'
    missing.mkdir()
    real_probe = m.write_probe
    def deny(path):
        if path == missing:
            raise PermissionError('fixture read-only')
        real_probe(path)
    with patch.object(m, 'write_probe', side_effect=deny):
        bad = m.external_checks(profile, project)
        assert 'unwritable' in bad['drive-dir:' + relative[0]]['reason']
    with patch.object(m.os, 'statvfs', return_value=SimpleNamespace(f_bavail=9, f_frsize=1024**3)):
        assert m.external_checks(profile, project)['data-disk']['status'] == 'fail'
    with patch.object(m.os, 'statvfs', side_effect=OSError('no measurement')):
        assert 'measurement absent' in m.external_checks(profile, project)['data-disk']['reason']
state = base / 'state'
def record(checks, operation='record', previous=None):
    decision = dict(task='heavy', impact='P0', request={}, checks=checks,
                    failed=[k for k,v in checks.items() if v['status'] != 'pass'],
                    admitted=all(v['status'] == 'pass' for v in checks.values()))
    if previous:
        decision.update(id=previous['id'], at=previous['at'], mode='spawn')
    with patch.object(sys, 'stdin', io.StringIO(json.dumps(decision))):
        return m.ledger(state, operation, 'heavy', 'spawn')
first = record(good)
rejected = dict(good, **{'acquired-worktree': m.treehouse_root(profile, project, internal)})
updated = record(rejected, 'amend', first)
assert updated['id'] == first['id']
assert len(m.read(state / 'capacity.json')['decisions']) == 1, 'amend retains one spawn decision'
assert m.ledger(state, 'waits')[0]['failed'] == ['acquired-worktree']
alerts = m.ledger(state, 'alerts')
assert len(alerts) == 1
m.ledger(state, 'ack-alert', alerts[0]['key'], alerts[0]['token'])
record(rejected)
assert m.ledger(state, 'alerts') == [], 'same condition does not alert every recheck'
record(dict(good, **{'acquired-worktree': m.treehouse_root(profile, project, slot)}))
record(rejected)
assert len(m.ledger(state, 'alerts')) == 1, 'recovered then recurring condition alerts again'
print('ok - external mount, directories, disk floor, pool root, atomic acquired-path refusal and alert recovery')
PY
expect_code 0 "$?" 'external placement checks'

# The post-acquisition rollback never returns a relaunch, dirty copy, or slot
# another task records. Only the Treehouse return command is replaced here.
(
  SCRIPT_DIR="$ROOT/bin"
  # shellcheck source=bin/fm-placement-lib.sh
  . "$SCRIPT_DIR/fm-placement-lib.sh"
  FM_PLACEMENT_ID=reject-test
  RETURN_PROJECT="$TMP_ROOT/return-project"
  fm_git_init_commit "$RETURN_PROJECT"
  STATE="$TMP_ROOT/return-state"
  mkdir -p "$STATE" "$TMP_ROOT/return-bin"
  cat > "$TMP_ROOT/return-bin/treehouse" <<'RETURN'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RETURN_LOG"
[ "$#" = 2 ] && [ "$1" = return ]
RETURN
  chmod +x "$TMP_ROOT/return-bin/treehouse"
  export PATH="$TMP_ROOT/return-bin:$PATH" RETURN_LOG="$TMP_ROOT/returned"
  fm_treehouse_pool_slot() { return 0; }
  fm_treehouse_slot_owner_state() { FM_TREEHOUSE_SLOT_OWNER=${TEST_OWNER:-mine}; }
  fm_treehouse_slot_owner_release() { touch "$STATE/released"; }
  fm_worktree_slot_record_named() { return "${TEST_RECORD_RC:-1}"; }
  RELAUNCH=0 SPAWN_ENDPOINT_CLOSED=1 SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=1 SPAWN_SLOT_CLAIMED=1
  TEST_OWNER=other
  if fm_placement_return_rejected "$RETURN_PROJECT" "$RETURN_PROJECT"; then fail 'returned another claim'; fi
  TEST_OWNER=mine TEST_RECORD_RC=0
  if fm_placement_return_rejected "$RETURN_PROJECT" "$RETURN_PROJECT"; then fail 'returned a recorded copy'; fi
  TEST_RECORD_RC=1 RELAUNCH=1
  if fm_placement_return_rejected "$RETURN_PROJECT" "$RETURN_PROJECT"; then fail 'returned a relaunch'; fi
  RELAUNCH=0
  touch "$RETURN_PROJECT/uncommitted"
  if fm_placement_return_rejected "$RETURN_PROJECT" "$RETURN_PROJECT"; then fail 'returned a dirty copy'; fi
  rm "$RETURN_PROJECT/uncommitted"
  assert_absent "$RETURN_LOG" 'unsafe copies never call Treehouse return'
  fm_placement_return_rejected "$RETURN_PROJECT" "$RETURN_PROJECT" || fail 'safe rejected allocation was not returned'
  [ -f "$STATE/released" ] || fail 'successful return releases claim'
  [ -f "$STATE/.capacity-freed" ] || fail 'successful return signals capacity'
) || fail 'safe allocation rollback'
pass 'rejected allocation returns only a clean, unrecorded freshly owned slot'
