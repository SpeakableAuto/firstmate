#!/usr/bin/env bash
# Real tasks-axi fixture follows a redacted operational backlog's section,
# priority, since, hold and merged metadata shapes. No live home is mutated.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-finish-first)
command -v tasks-axi >/dev/null || { echo 'ok - skipped (tasks-axi missing)'; exit 0; }
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/data" "$FM_HOME/config"
printf 'backend = "markdown"\n' > "$FM_HOME/.tasks.toml"
cp "$ROOT/tests/fixtures/finish-first/backlog.md" "$FM_HOME/data/backlog.md"
check() {
  local want=$1 needle=$2 out rc
  shift 2
  rc=0
  out=$(bash "$ROOT/bin/fm-finish-first.sh" "$@" 2>&1) || rc=$?
  expect_code "$want" "$rc" "$out"
  assert_contains "$out" "$needle" "admission diagnostic"
}
# Open work, missing briefs and capacity waits must not serialize a level.
check 0 allowed candidate
check 0 allowed elevated
check 0 allowed urgent
check 0 resume current
mkdir -p "$FM_HOME/state"
printf 'kind=ship\n' > "$FM_HOME/state/parked.meta"
check 0 allowed candidate
printf '{"version":1,"max_crew":1}\n' > "$FM_HOME/config/crew-placement.json"
check 1 WIP candidate
check 0 'P0' urgent
check 0 resume current
# Canonical impact overrides legacy priority, including trailing metadata.
python3 - "$FM_HOME/data/backlog.md" <<'PYROW'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text().replace('(priority: 0)', '(priority: 3) (impact: P0)')
p.write_text(s)
PYROW
check 0 P0 urgent
printf '{"version":1,"max_crew":2}\n' > "$FM_HOME/config/crew-placement.json"
check 0 allowed candidate
printf '{"version":1,"max_crew":true}\n' > "$FM_HOME/config/crew-placement.json"
check 2 max_crew candidate
rm "$FM_HOME/config/crew-placement.json"
check 2 missing absent
bash "$ROOT/bin/fm-tasks-axi.sh" hold candidate --reason 'outside answer' --kind external >/dev/null
check 1 held candidate
bash "$ROOT/bin/fm-tasks-axi.sh" unhold candidate >/dev/null
# Two prior AEST days with more starts than finishes activate the stop signal.
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PY'
import datetime as dt, json, sys
aest = dt.timezone(dt.timedelta(hours=10))
today = dt.datetime.now(dt.timezone.utc).astimezone(aest).date()
rows = [{'type':'coverage','version':1,
         'timestamp':dt.datetime.combine(today-dt.timedelta(days=3), dt.time(), aest).astimezone(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}]
for offset in (2, 1):
    day = today-dt.timedelta(days=offset)
    for number in (1, 2):
        token = f'{day}-{number}'
        stamp = dt.datetime.combine(day, dt.time(12), aest).astimezone(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        base = {'token':token,'task_id':token,'priority':2,'landing':'none','timestamp':stamp}
        rows.append(dict(base, type='attempt'))
        rows.append(dict(base, type='transition', action='start', result=0))
with open(sys.argv[1], 'w') as stream:
    for row in rows:
        stream.write(json.dumps(row)+'\n')
PY
check 1 'two-day stop' candidate
check 0 allowed elevated
check 0 P0 urgent
rm "$FM_HOME/data/flow-history.jsonl"
pass 'WIP and two-day flow bounds new starts; higher priorities and resumes remain runnable'

# The placement decision must retain the finish-first refusal and queue it.
printf '{"version":1,"max_crew":1}\n' > "$FM_HOME/config/crew-placement.json"
CONFIG="$FM_HOME/config" DATA="$FM_HOME/data" STATE="$FM_HOME/state"
SCRIPT_DIR="$ROOT/bin"
. "$ROOT/bin/fm-tasks-axi-lib.sh"
. "$ROOT/bin/fm-backlog-transition-lib.sh"
. "$ROOT/bin/fm-placement-lib.sh"
FM_PLACEMENT_ID=candidate
FM_PLACEMENT_ACTIVE=1
RELAUNCH=0
KIND=ship
PROJ=demo
seed='{"task":"candidate","request":{},"checks":{},"admitted":true}'
placement_state=$FM_HOME/state
decision=$(fm_placement_finish_first "$seed")
assert_equals fail "$(jq -r '.checks["finish-first"].status' <<< "$decision")" 'placement checks order and WIP'
rc=0
fm_placement_publish "$decision" >/dev/null 2>&1 || rc=$?
expect_code 1 "$rc" 'placement refuses work above WIP'
assert_equals wip "$(jq -r '.waits.candidate.state' "$placement_state/capacity.json")" 'WIP wait is not a machine-capacity bottleneck'
assert_equals '["finish-first"]' "$(jq -c '.waits.candidate.failed' "$placement_state/capacity.json")" 'refusal enters existing queue'
printf '{"version":1,"max_crew":2}\n' > "$CONFIG/crew-placement.json"
FM_PLACEMENT_MODE=recheck
decision=$(fm_placement_finish_first "$seed")
fm_placement_publish "$decision" >/dev/null
assert_equals ready "$(jq -r '.waits.candidate.state' "$placement_state/capacity.json")" 'capacity recheck releases the waiting item'
# Queue ordering is independent of admission: older queued work leads, and
# carried resumptions lead new work within the same impact level.
for id in oldest current; do
  printf '%s\n' "$decision" | jq --arg id "$id" '.task=$id | .impact="P2"' | python3 "$ROOT/bin/fm-placement.py" record "$placement_state" "$id" recheck >/dev/null
done
ordered=$(backlog_json "$DATA/backlog.md" | python3 "$ROOT/bin/fm-placement.py" ordered "$placement_state")
assert_equals 'current,oldest,candidate' "$(jq -r '[.[].task]|join(",")' <<< "$ordered")" 'carried work then oldest queued work leads its level'
pass 'finish-first refusal, recovery and runnable queue order use the placement ledger'
# The real spawn entrypoint refuses before allocating a worker or local copy.
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"
spawn_home="$TMP_ROOT/spawn-home"
fm_test_spawn_home "$spawn_home" claude
fm_test_spawn_brief "$spawn_home" candidate
printf 'backend = "markdown"\n' > "$spawn_home/.tasks.toml"
cp "$ROOT/tests/fixtures/finish-first/backlog.md" "$spawn_home/data/backlog.md"
printf '{"version":1,"max_crew":1}\n' > "$spawn_home/config/crew-placement.json"
fm_git_init_commit "$spawn_home/projects/demo"
fm_git_add_origin "$spawn_home/projects/demo" "$TMP_ROOT/demo.origin.git"
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/spawn-tools" gh gh-axi no-mistakes)
mv "$fakebin/tmux" "$fakebin/tmux-original"
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in new-window) touch "$FM_HOME/allocated" ;; esac
exec "$(dirname "$0")/tmux-original" "$@"
SH
chmod +x "$fakebin/tmux"
rc=0
out=$(fm_test_run_spawn "$spawn_home" "$TMP_ROOT/never-allocated" "$fakebin" \
  candidate "$spawn_home/projects/demo" --mode no-mistakes --yolo off) || rc=$?
expect_code 1 "$rc" 'real spawn rejects newer work'
assert_contains "$out" 'WIP' 'real spawn names priority leader'
assert_absent "$spawn_home/allocated" 'refusal happens before worker allocation'
assert_absent "$spawn_home/state/candidate.meta" 'refusal leaves no parked task record'
assert_contains "$(TASKS_AXI_FILE="$spawn_home/data/backlog.md" tasks-axi show candidate)" 'state: queued' 'refused job remains queued'
pass 'real spawn enforces finish-first before resource allocation'
