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
base='{"impact":"P1","crew_count":0,"memory":{"free_percent":50,"swap_mib":0},"disk":{"status":"pass"},"slots":{"status":"pass"},"quota":{"status":"pass"},"locks":{"status":"pass"}}'
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
pool_full=$(python3 "$TOOL" pool "$CONFIG" 2)
assert_equals false "$(jq .available <<<"$pool_full")" 'the quota pool excludes a full machine before ranking'
assert_contains "$(jq -r .reason <<<"$pool_full")" 'crew cap: 2/2' 'the pool publishes its concrete room refusal'
pool_unknown=$(python3 "$TOOL" pool "$CONFIG" -1)
assert_equals false "$(jq .available <<<"$pool_unknown")" 'unknown live crew count cannot promise room'
pass 'fit, room, quota, locks and missing evidence refuse bad placement'

# The last crew slot is kept for one urgent task at a time.
reserved=$(jq '.crew_count=1' <<< "$base")
bad=$(assess "$reserved")
assert_equals fail "$(jq -r .checks.room.status <<< "$bad")" 'an ordinary start may not take the last slot'
assert_contains "$(jq -r .checks.room.reason <<< "$bad")" 'last slot reserved for urgent work' 'the reserved-slot refusal is named'
assert_equals true "$(assess "$(jq '.impact="P0"' <<< "$reserved")" | jq -r .admitted)" 'a P0 task takes the reserved slot'
cp "$DATA/task-one/placement.json" "$TMP_ROOT/work"
jq '.urgent=true' "$TMP_ROOT/work" > "$DATA/task-one/placement.json"
assert_equals true "$(assess "$reserved" | jq -r .admitted)" 'a Firstmate-flagged urgent task takes the reserved slot'
bad=$(assess "$(jq '.crew_count=2' <<< "$base")")
assert_contains "$(jq -r .checks.room.reason <<< "$bad")" 'count=2, cap=2' 'a second urgent task waits once the reserved slot is taken'
assert_equals yes "$(python3 "$TOOL" urgent "$DATA/task-one/placement.json" P2)" 'the urgent rule reads the intake flag'
for label in '.urgent="yes"' '.reported_urgency="urgent"' '.reporter={"urgent":true}'; do
  jq "$label" "$TMP_ROOT/work" > "$DATA/task-one/placement.json"
  assert_equals false "$(assess "$reserved" | jq -r .admitted)" "a reporter-style label is not urgent: $label"
  assert_equals no "$(python3 "$TOOL" urgent "$DATA/task-one/placement.json" P1)" "the urgent rule ignores $label"
done
cp "$TMP_ROOT/work" "$DATA/task-one/placement.json"
# A relaunch resumes the slot it held, and a live urgent task fills the reserve.
assert_equals true "$(assess "$(jq '.relaunch=true' <<< "$reserved")" | jq -r .admitted)" 'an ordinary relaunch is not refused by the reserved slot'
assert_equals true "$(assess "$(jq '.urgent_live=1' <<< "$reserved")" | jq -r .admitted)" 'ordinary work keeps max_crew - 1 slots while an urgent task runs'
assert_equals false "$(assess "$(jq '.crew_count=2 | .relaunch=true | .urgent_live=1' <<< "$base")" | jq -r .admitted)" 'neither exemption passes the full cap'
mkdir -p "$DATA/outage" "$DATA/flagged-live"
printf '{"version":1,"urgent":true}\n' > "$DATA/flagged-live/placement.json"
live_rows='{"records":[{"id":"outage","impact":"P0"},{"id":"legacy","impact":"P2"}]}'
assert_equals 2 "$(python3 "$TOOL" urgent-live "$DATA" task-one outage flagged-live legacy <<< "$live_rows")" 'live urgent tally reads backlog P0 and the intake mark only'
# Pool evidence reads live memory, so this profile accepts any measurement.
mkdir -p "$TMP_ROOT/roomy"
jq '.min_free_memory_percent=0.001 | .max_swap_mib=1048575' "$CONFIG/crew-placement.json" > "$TMP_ROOT/roomy/crew-placement.json"
pool_reserved=$(python3 "$TOOL" pool "$TMP_ROOT/roomy" 1)
assert_equals 'true:true' "$(jq -r '"\(.available):\(.reserved_only)"' <<<"$pool_reserved")" 'shared machine evidence says only the reserved slot is left'
assert_equals false "$(python3 "$TOOL" pool "$TMP_ROOT/roomy" 0 | jq .reserved_only)" 'an ordinary slot is still free below the reserve'
assert_equals false "$(python3 "$TOOL" pool "$TMP_ROOT/roomy" 1 1 | jq .reserved_only)" 'a live urgent task leaves the ordinary slots open'
pass 'the reserved slot admits one urgent task and refuses ordinary and reporter-labelled work'

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
cat > "$BIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows) [ ! -f "$FM_HOME/state/occupant.meta" ] || printf 'occupant\n' ;;
  display-message) [ "${@: -1}" != '#{pane_current_command}' ] || printf 'codex' ;;
  *) exit 1 ;;
esac
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
  list)
    printf '%s\n' 'count: 1' 'tasks[1]{id,state,kind,blocked,held,created,priority}:' '  task-one,queued,ship,no,no,-,3'
    ;;
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
printf '# Backlog\n## Queued\n- [ ] task-one - Ready work (kind: ship) (impact: P1)\n' > "$DATA/backlog.md"
jq '.max_crew=1' "$CONFIG/crew-placement.json" > "$CONFIG/next"
mv "$CONFIG/next" "$CONFIG/crew-placement.json"
printf 'kind=ship\nharness=codex\nbackend=tmux\nwindow=fixture:occupant\n' > "$STATE/occupant.meta"
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
assert_equals '1:15:10:900' "$(jq -r '"\(.placement.max_crew):\(.disk.threshold_gib):\(.claude.floor):\(.recheck_seconds)"' <<< "$effective")" 'effective limits expose configured cap and owner defaults'
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

# Count positive liveness plus the launch grace; unreadable liveness refuses.
# The existing classifier owns vendor-specific evidence; this fixture drives
# each classification through the shared placement counting interface.
(
  SCRIPT_DIR="$ROOT/bin"
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/fm-claude-admission-lib.sh"
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/fm-placement-lib.sh"
  STATE="$TMP_ROOT/count-state"
  FM_PLACEMENT_ID=candidate
  mkdir -p "$STATE"
  # shellcheck disable=SC2329 # invoked indirectly by fm_placement_count
  fm_backend_source() { [ "$1" != unsupported ]; }
  # shellcheck disable=SC2329 # invoked indirectly by fm_placement_count
  fm_backend_agent_state() { fm_backend_source "$1" || { printf unverified; return 0; }; printf '%s' "${2#fixture:}"; }
  for verdict in missing dead gone ambiguous unverified; do
    printf 'kind=ship\nbackend=tmux\nwindow=fixture:%s\nspawn_gen=s1.0\n' "$verdict" > "$STATE/worker.meta"
    assert_equals 0 "$(fm_placement_count)" "absent '$verdict' never consumes crew"
    printf 'kind=ship\nbackend=tmux\nwindow=fixture:%s\nspawn_gen=s%s.0\n' "$verdict" "$(( $(date +%s) - 10 ))" > "$STATE/worker.meta"
    assert_equals 1 "$(fm_placement_count)" "record launched 10 s ago counts despite '$verdict'"
  done
  printf 'kind=ship\nbackend=herdr\nwindow=fixture:unreadable\nspawn_gen=s1.0\n' > "$STATE/worker.meta"
  reason=$(fm_placement_count) && fail 'unreadable liveness must refuse'
  assert_equals 'crew liveness unreadable: herdr' "$reason" 'unreadable liveness names its backend'
  printf 'kind=ship\nbackend=tmux\nwindow=fixture:alive\nspawn_gen=s%s.0\n' "$(( $(date +%s) + 3600 ))" > "$STATE/worker.meta"
  assert_equals 1 "$(fm_placement_count)" 'future timestamp falls through to liveness'
  printf 'kind=ship\nbackend=tmux\nwindow=fixture:missing\nspawn_gen=s%s.0\n' "$(( $(date +%s) + 3600 ))" > "$STATE/worker.meta"
  assert_equals 0 "$(fm_placement_count)" 'future timestamp never reserves a slot'
  printf 'kind=ship\nbackend=tmux\nwindow=fixture:missing\nspawn_gen=s99999999999999999999.0\n' > "$STATE/worker.meta"
  assert_equals 0 "$(fm_placement_count)" 'overlong timestamp never reserves a slot'
  for verdict in '' alive; do
    printf 'kind=ship\nbackend=unsupported\nwindow=fixture:%s\n' "$verdict" > "$STATE/worker.meta"
    assert_equals 0 "$(fm_placement_count)" "unclassified backend '$verdict' neither counts nor refuses"
  done
  for backend in tmux herdr zellij orca cmux; do
    printf 'kind=ship\nbackend=%s\nwindow=fixture:alive\nstatus=paused\n' "$backend" > "$STATE/worker.meta"
    assert_equals 1 "$(fm_placement_count)" "$backend positively alive counts even if status says paused"
  done
  cp "$STATE/worker.meta" "$STATE/candidate.meta"
  printf 'kind=secondmate\nbackend=tmux\nwindow=fixture:alive\n' > "$STATE/secondmate.meta"
  assert_equals 1 "$(fm_placement_count)" 'candidate and secondmates excluded'
) || exit 1
pass 'crew count requires positive liveness or launch grace and refuses only unreadable liveness'

# A stalled machine drive refuses placement within the drive-check deadline.
# The fixture blocks every stat, lstat, statvfs, access, open, scandir and
# listdir under one directory in a real kernel wait (opening a FIFO that never
# gets a writer). It proves the parent never waits on such a read; it does not
# reproduce a stalled disk's kernel I/O, whose reader may not die on a signal.
python3 - "$TOOL" "$TMP_ROOT" "$ROOT/tests/fixtures/stalled-drive" <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

tool = sys.argv[1]
base = Path(sys.argv[2]).resolve() / 'stalled'
drive = base / 'drive'
relative = ['Build/Tmp', 'Caches/npm']
for name in relative + ['pool/slot']:
    (drive / name).mkdir(parents=True)
internal = base / 'internal'
internal.mkdir()
fifo = base / 'never-written'
os.mkfifo(fifo)
log = base / 'stalled.log'
escaped = base / 'escaped.pid'
site = Path(sys.argv[3])
config = base / 'config'
config.mkdir()
(config / 'crew-placement.json').write_text(json.dumps(dict(
    version=1, workloads=['backend'], max_crew=2, min_free_memory_percent=0.001, max_swap_mib=1048575,
    drive=str(drive), required_drive_dirs=relative,
    data_volume=dict(path=str(internal), min_free_gib=0.001))))
project = base / 'repo'
project.mkdir()
(project / 'treehouse.toml').write_text('root = ' + json.dumps(str(drive / 'pool')) + '\n')
evidence = json.dumps(dict(project=str(project)))
failures = []
DEADLINE = 2
BOUND = 15


def run(name, args, stall=None, escape=False, stdin='', deadline=DEADLINE):
    """Run the CLI in its own group; the test, not the CLI, bounds a hang."""
    # Only this fixture's seams are set; inherited values cannot select them.
    env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_TEST_STALL', 'FM_PLACEMENT_'))}
    env.update(PYTHONPATH=str(site), FM_TEST_FAKE_MOUNT=str(drive),
               FM_TEST_STALL_FIFO=str(fifo), FM_TEST_STALL_LOG=str(log))
    if deadline is not None:
        env['FM_PLACEMENT_DRIVE_SECS'] = str(deadline)
    if stall:
        env['FM_TEST_STALL_PREFIX'] = str(stall)
    if escape:
        env['FM_TEST_STALL_ESCAPE'] = str(escaped)
    if log.exists():
        log.unlink()
    started = time.monotonic()
    proc = subprocess.Popen([sys.executable, tool, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, env=env, start_new_session=True)
    try:
        out, err = proc.communicate(stdin, timeout=BOUND)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate()
        blocked = log.read_text().split() if log.exists() else []
        where = 'the placement command itself' if blocked[:1] == [str(proc.pid)] else 'a descendant'
        failures.append(f'{name}: still running after {BOUND}s; blocked reader was {where}: {" ".join(blocked)}')
        print(f'not ok - {name}: hung {BOUND}s (blocked in {where})')
        return None
    elapsed = time.monotonic() - started
    print(f'{name}: exit={proc.returncode} elapsed={elapsed:.2f}s stdout={out.strip()} stderr={err.strip()}')
    readers = [int(line.split()[0]) for line in log.read_text().splitlines()] if log.exists() else []
    return dict(rc=proc.returncode, out=out, elapsed=elapsed, pid=proc.pid, readers=readers)


def check(name, condition, detail=''):
    if not condition:
        failures.append(f'{name} {detail}')
        print(f'not ok - {name} {detail}')


healthy = run('healthy pool', ['pool', str(config), '0'])
if healthy:
    check('healthy pool admits', json.loads(healthy['out']).get('available') is True, healthy['out'])
healthy = run('healthy assess', ['assess', str(config), str(base / 'data'), 'task', 'codex', 'test', 'high'], stdin=evidence)
if healthy:
    checks = json.loads(healthy['out'])['checks']
    for key in ['drive', 'drive-dir:' + relative[0], 'drive-dir:' + relative[1], 'data-disk', 'treehouse-root']:
        check(f'healthy assess passes {key}', checks.get(key, {}).get('status') == 'pass', json.dumps(checks.get(key)))
    check('healthy probes clean up', not list(drive.rglob('.fm-placement-*')))
healthy = run('healthy worktree', ['worktree', str(config), str(project), str(drive / 'pool' / 'slot')])
if healthy:
    check('healthy worktree passes', json.loads(healthy['out'])['status'] == 'pass', healthy['out'])

for name, args, stdin, escape in [
        ('stalled pool', ['pool', str(config), '0'], '', False),
        ('stalled pool, escaped descendant', ['pool', str(config), '0'], '', True),
        ('stalled assess', ['assess', str(config), str(base / 'data'), 'task', 'codex', 'test', 'high'], evidence, False),
        ('stalled worktree', ['worktree', str(config), str(project)], '', False)]:
    got = run(name, args, stall=drive, escape=escape, stdin=stdin)
    if escaped.exists():
        # Stop only the descendant this fixture started and recorded.
        try:
            os.kill(int(escaped.read_text()), signal.SIGKILL)
        except ProcessLookupError:
            pass
        escaped.unlink()
    if not got:
        continue
    check(f'{name} returns within the deadline', got['elapsed'] < DEADLINE + 3, f"elapsed={got['elapsed']:.2f}")
    check(f'{name} reached the stalled read', got['readers'] != [], 'no blocked reader logged')
    check(f'{name} never blocks the placement command itself', got['pid'] not in got['readers'], str(got['readers']))
    value = json.loads(got['out'] or 'null')
    if args[0] == 'pool':
        check(f'{name} refuses the machine', value.get('available') is False, got['out'])
        reason = value.get('reason', '')
    elif args[0] == 'assess':
        check(f'{name} refuses placement', value.get('admitted') is False and 'drive' in value.get('failed', []), got['out'])
        check(f'{name} alerts once, for the drive', value['checks']['drive'].get('alert') is True
              and not value['checks']['treehouse-root'].get('alert'), got['out'])
        reason = value['checks']['drive']['reason']
    else:
        check(f'{name} refuses the pool root', value.get('status') == 'fail', got['out'])
        reason = value.get('reason', '')
    check(f'{name} names the existing drive refusal', 'required machine drive unavailable' in reason, reason)
    time.sleep(0.5)
    for reader in got['readers']:
        try:
            os.kill(reader, 0)
            check(f'{name} stops its blocked reader', False, f'pid {reader} still alive')
        except ProcessLookupError:
            pass

got = run('stalled pool, default deadline', ['pool', str(config), '0'], stall=drive, deadline=None)
if got:
    check('the default deadline is ten seconds', 9.5 < got['elapsed'] < 15, f"elapsed={got['elapsed']:.2f}")
    check('the default deadline refuses the drive', 'required machine drive unavailable'
          in json.loads(got['out']).get('reason', ''), got['out'])

got = run('stalled data volume', ['pool', str(config), '0'], stall=internal)
if got:
    value = json.loads(got['out'])
    check('stalled data volume refuses within the deadline', value.get('available') is False and got['elapsed'] < DEADLINE + 3, got['out'])
    check('stalled data volume is named as the disk, not the drive',
          'machine disk measurement unavailable' in value.get('reason', ''), got['out'])

if failures:
    print('\n'.join('FAIL: ' + f for f in failures))
    sys.exit(1)
print('ok - a stalled drive or data volume refuses placement within the deadline; healthy checks still pass')
PY
expect_code 0 "$?" 'stalled drive placement is bounded'

# The reported path: a real spawn and the dispatch resolver's machine evidence
# stop waiting on the stalled drive, refuse it by name and leave routing free.
STALL_HOME="$TMP_ROOT/stall-home"
fm_test_spawn_home "$STALL_HOME" codex
fm_test_spawn_brief "$STALL_HOME" drive-task 'backend work that needs the machine drive'
cp "$TMP_ROOT/stalled/config/crew-placement.json" "$CONFIG/crew-dispatch.json" "$STALL_HOME/config/"
hash=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$STALL_HOME/data/drive-task/brief.md")
jq -n --arg hash "$hash" '{version:1,workload:"backend",requires_drive:true,priority:"P1",dispatch_rule:0,brief_sha256:$hash}' > "$STALL_HOME/data/drive-task/placement.json"
printf '## Queued\n- [ ] drive-task - Drive fixture (impact: P1)\n' > "$STALL_HOME/data/backlog.md"
python3 - "$ROOT" "$TMP_ROOT" "$STALL_HOME" "$SPAWN_PROJECT" "$SPAWN_BIN" <<'PY'
import json
import shutil
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root, base, home, project, fakebin = sys.argv[1], Path(sys.argv[2]).resolve() / 'stalled', sys.argv[3], sys.argv[4], sys.argv[5]
BOUND = 60
stall = dict(PYTHONPATH=root + '/tests/fixtures/stalled-drive', FM_TEST_FAKE_MOUNT=str(base / 'drive'),
             FM_TEST_STALL_PREFIX=str(base / 'drive'), FM_TEST_STALL_FIFO=str(base / 'never-written'),
             FM_TEST_STALL_LOG=str(base / 'stalled.log'), FM_PLACEMENT_DRIVE_SECS='2')
failures = []


def run(name, command, env):
    started = time.monotonic()
    proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, env=env, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=BOUND)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate()
        failures.append(f'{name}: still running after {BOUND}s')
        print(f'not ok - {name}: hung {BOUND}s')
        return None
    elapsed = time.monotonic() - started
    print(f'{name}: exit={proc.returncode} elapsed={elapsed:.2f}s output={out.strip()}')
    return proc.returncode, out, elapsed


# Same environment as tests/fixtures.sh fm_test_run_spawn, plus the stall.
inherited = {k: v for k, v in os.environ.items() if not k.startswith(('FM_TEST_STALL', 'FM_PLACEMENT_'))}
spawn_env = dict(inherited, **stall, FM_ROOT_OVERRIDE='', FM_HOME=home, HOME=home + '/user-home',
                 CLAUDE_CONFIG_DIR='', FM_STATE_OVERRIDE=home + '/state', FM_DATA_OVERRIDE=home + '/data',
                 FM_PROJECTS_OVERRIDE=home + '/projects', FM_CONFIG_OVERRIDE=home + '/config',
                 FM_SPAWN_NO_GUARD='1', FM_FAKE_PANE_PATH=project, TMUX=os.environ.get('TMUX', 'fake,1,0'),
                 PATH=fakebin + ':' + os.environ['PATH'])
os.makedirs(home + '/user-home', exist_ok=True)
log = base / 'stalled.log'
started_at = time.time() - 1


def spawn(name, env):
    log.unlink(missing_ok=True)
    got = run(name, [root + '/bin/fm-spawn.sh', 'drive-task', project, '--scout',
                     '--harness', 'codex', '--model', 'test', '--effort', 'high'], env)
    if not got:
        return None
    readers = [int(line.split()[0]) for line in log.read_text().splitlines()] if log.exists() else []
    decision = [d for d in json.loads(Path(home, 'state', 'capacity.json').read_text())['decisions']
                if d['task'] == 'drive-task'][-1]
    print(f'{name} blocked readers: {readers}; failed checks: {",".join(decision["failed"])}')
    return got + (readers, decision)


# The spawn project names the fixture pool, so a healthy spawn is admitted.
Path(project, 'treehouse.toml').write_text('root = ' + json.dumps(str(base / 'drive' / 'pool')) + '\n')
# finish-first needs tasks-axi; without it on PATH that one check is the only refusal allowed.
backlog_tool = shutil.which('tasks-axi', path=spawn_env['PATH'])
print(f'tasks-axi for finish-first: {backlog_tool or "absent, finish-first refusal tolerated"}')


def admitted(name, got):
    decision = got[4]
    allowed = [] if backlog_tool else ['finish-first']
    if decision['failed'] != allowed or (backlog_tool and decision['admitted'] is not True):
        failures.append(f'{name} was not admitted: failed={decision["failed"]} ' + json.dumps(decision['checks']))
    if got[3]:
        failures.append(f'{name} reached the stall')


# Control: the same spawn with the drive answering is admitted through the bounded checks.
got = spawn('healthy spawn', dict(spawn_env, FM_TEST_STALL_PREFIX=str(base / 'not-the-drive')))
if got:
    admitted('healthy spawn', got)
got = spawn('stalled spawn', spawn_env)
if got:
    rc, out, elapsed, readers, decision = got
    if rc != 1 or 'placement refused' not in out or 'required machine drive unavailable' not in out:
        failures.append('stalled spawn did not refuse the drive by name')
    if elapsed > 30:
        failures.append(f'stalled spawn took {elapsed:.2f}s')
    if len(readers) != 1:
        failures.append(f'stalled spawn waited on the drive {len(readers)} times, not once: {readers}')
    for reader in readers:
        try:
            os.kill(reader, 0)
            failures.append(f'stalled spawn left blocked reader {reader} running')
        except ProcessLookupError:
            pass
    checks = decision['checks']
    if checks['fit']['status'] != 'pass' or checks['drive']['status'] != 'fail':
        failures.append('stalled spawn was not refused on its drive: ' + json.dumps(checks))
    # The balance gate's pool evidence passes this machine over, so the
    # requested local profile is no longer a candidate: routing moved on.
    if 'not a candidate' not in checks['quota'].get('reason', ''):
        failures.append('stalled machine was not passed over by the balance gate: ' + json.dumps(checks['quota']))
    wait = json.loads(Path(home, 'state', 'capacity.json').read_text())['waits'].get('drive-task', {})
    if wait.get('state') != 'capacity' or 'drive' not in wait.get('failed', []):
        failures.append(f'stalled spawn left no capacity wait naming the drive: {wait}')
    if Path(home, 'state', 'drive-task.meta').exists():
        failures.append('stalled spawn published worker metadata')
    if Path(home, 'state', '.placement-admission.lock').exists():
        failures.append('stalled spawn kept the admission lock')
# With a worktree slot cap, spawn also reads the pool's Git registrations
# before placement; a git that blocks `worktree list` stands in for that read.
shim = base / 'git-shim'
shim.mkdir(exist_ok=True)
real_git = subprocess.run(['/bin/sh', '-c', 'command -v git'], capture_output=True, text=True).stdout.strip()
(shim / 'git').write_text('#!/usr/bin/env bash\ncase " $* " in *" worktree list "*)\n'
                          '  printf "%s git\\n" "$$" >> "$FM_TEST_STALL_LOG"\n  exec 3< "$FM_TEST_STALL_FIFO" ;;\nesac\n'
                          'exec ' + real_git + ' "$@"\n')
(shim / 'git').chmod(0o755)
Path(home, 'config', 'worktree-slot-cap').write_text('2\n')
got = spawn('stalled spawn with a slot cap', dict(spawn_env, PATH=str(shim) + ':' + spawn_env['PATH'],
                                                  FM_WORKTREE_SLOTS_READ_SECS='2'))
Path(home, 'config', 'worktree-slot-cap').unlink()
if got:
    rc, out, elapsed, readers, decision = got
    print(f'stalled spawn with a slot cap: blocked log: {log.read_text().split() if log.exists() else []}')
    if rc != 1 or 'worktree slot room skipped' not in out or 'required machine drive unavailable' not in out:
        failures.append('stalled spawn with a slot cap did not refuse room and drive by name')
    if 'slots' not in decision['failed'] or 'drive' not in decision['failed']:
        failures.append('stalled spawn with a slot cap did not record slots and drive: ' + ','.join(decision['failed']))
    if log.read_text().splitlines() != [f'{readers[0]} git'] if readers else True:
        failures.append('stalled spawn with a slot cap did not wait exactly once, on the pool read')
    if elapsed > 30:
        failures.append(f'stalled spawn with a slot cap took {elapsed:.2f}s')
# The whole command at the default deadlines: one 10-second wait per attempt.
defaults = {k: v for k, v in spawn_env.items() if k not in ('FM_PLACEMENT_DRIVE_SECS', 'FM_WORKTREE_SLOTS_READ_SECS')}
for name, env, cap in [('stalled spawn, default deadline', defaults, False),
                       ('stalled spawn with a slot cap, default deadline',
                        dict(defaults, PATH=str(shim) + ':' + defaults['PATH']), True)]:
    if cap:
        Path(home, 'config', 'worktree-slot-cap').write_text('2\n')
    got = spawn(name, env)
    if cap:
        Path(home, 'config', 'worktree-slot-cap').unlink()
    if got:
        rc, out, elapsed, readers, decision = got
        if rc != 1 or 'required machine drive unavailable' not in out or len(readers) != 1:
            failures.append(f'{name}: did not refuse after exactly one drive wait: {readers}')
        if not 9.5 < elapsed < 20:
            failures.append(f'{name}: took {elapsed:.2f}s, not one ten-second wait')
# The next attempt on an answering drive is not refused by the earlier stall.
got = spawn('healthy spawn after the stall', dict(spawn_env, FM_TEST_STALL_PREFIX=str(base / 'not-the-drive')))
if got:
    admitted('healthy spawn after the stall', got)
leftover = sorted(p.name for p in Path(os.environ.get('TMPDIR', '/tmp')).glob('fm-placement-attempt.*')
                  if p.stat().st_mtime >= started_at)
if leftover:
    failures.append(f'spawn attempts left their notes behind: {leftover}')
got = run('stalled resolver machine evidence',
          ['bash', '-c', 'SCRIPT_DIR=$1/bin; . "$SCRIPT_DIR/fm-backend.sh"; . "$SCRIPT_DIR/fm-live-workers-lib.sh"; . "$SCRIPT_DIR/fm-quota-balance-lib.sh"; fm_quota_balance_machine_state "$2" "$3"',
           'bash', root, home + '/config', home + '/state'], spawn_env)
if got:
    rc, out, elapsed = got
    value = json.loads(out.strip().splitlines()[-1]) if rc == 0 and out.strip() else {}
    if value.get('available') is not False or 'required machine drive unavailable' not in value.get('reason', ''):
        failures.append(f'resolver evidence did not pass the stalled machine over: {out.strip()}')
if failures:
    print('\n'.join('FAIL: ' + f for f in failures))
    sys.exit(1)
print('ok - a real spawn and the resolver machine evidence refuse a stalled drive within seconds')
PY
expect_code 0 "$?" 'stalled drive spawn and resolver evidence are bounded'
