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
mkdir -p "$FM_HOME/data" "$FM_HOME/config" "$FM_HOME/state"
printf 'enforce\n' > "$FM_HOME/config/finish-first-wip-mode"
for task in current carried held; do
  printf 'working [at=%s]: active fixture\n' "$(date +%s)" > "$FM_HOME/state/$task.status"
done
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
printf 'warn\n' > "$FM_HOME/config/finish-first-wip-mode"
check 1 'two-day stop' candidate
check 0 allowed elevated
check 0 P0 urgent
printf 'enforce\n' > "$FM_HOME/config/finish-first-wip-mode"
rm "$FM_HOME/data/flow-history.jsonl"
pass 'WIP and two-day flow bounds new starts; higher priorities and resumes remain runnable'

# Finishing an existing job cannot wait for that same job to vacate WIP.
cp "$FM_HOME/data/backlog.md" "$TMP_ROOT/before-serves.md"
cat > "$FM_HOME/data/backlog.md" <<'LINKED'
## In flight
- [ ] ship1 - Waiting for review (kind: ship) (impact: P2)
- [ ] ship2 - Waiting for replay (kind: ship) (impact: P2)
- [ ] ship3 - Waiting for fixes (kind: ship) (impact: P2)
- [ ] ship4 - Waiting for recheck (kind: ship) (impact: P2)
## Queued
- [ ] ship1-review - Independent review (kind: scout) (impact: P2) (serves: ship1)
- [ ] new-job - New implementation (kind: ship) (impact: P2)
- [ ] fake-review - Unlinked review (kind: scout) (impact: P2) (serves: missing)
LINKED
for task in ship1 ship2 ship3 ship4; do
  printf 'working [at=%s]: active fixture\n' "$(date +%s)" > "$FM_HOME/state/$task.status"
done
printf '{"version":1,"max_crew":2}\n' > "$FM_HOME/config/crew-placement.json"
check 1 'WIP 4/4' new-job
check 1 'WIP 4/4' fake-review
check 0 'serves ship1' ship1-review
# The same recorded relation exempts the review from a two-day stop.
backlog_json_cmd=' . "$1/bin/fm-backlog-lib.sh"; backlog_json "$2"'
linked=$(bash -c "$backlog_json_cmd" _ "$ROOT" "$FM_HOME/data/backlog.md")
out=$(printf '%s\n' "$linked" | python3 "$ROOT/bin/fm-finish-first.py" ship1-review "$FM_HOME/config" yes)
assert_contains "$out" 'serves ship1' 'linked review starts under both bounds'
native=$(TASKS_AXI_FILE="$FM_HOME/data/backlog.md" tasks-axi list --fields blocked,held,created,priority)
out=$(printf '%s\n' "$native" | python3 "$ROOT/bin/fm-finish-first.py" ship1-review "$FM_HOME/config" yes --native)
assert_contains "$out" 'serves ship1' 'native task title preserves the same explicit relation'
bash "$ROOT/bin/fm-tasks-axi.sh" hold ship1-review --reason 'awaiting scope' --kind external >/dev/null
check 1 held ship1-review
bash "$ROOT/bin/fm-tasks-axi.sh" unhold ship1-review >/dev/null
# Existing finishing work consumes no additional WIP item.
python3 - "$FM_HOME/data/backlog.md" <<'PYSERVES'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text().replace('(impact: P2)\n## Queued', '(impact: P2) (serves: ship1)\n## Queued')
p.write_text(s)
PYSERVES
check 0 allowed new-job
cp "$TMP_ROOT/before-serves.md" "$FM_HOME/data/backlog.md"
pass 'recorded finishing work starts at the exact WIP bound and under the two-day stop'

# An over-cap installation warns by default; old and held records never charge WIP.
printf '{"version":1,"max_crew":1}\n' > "$FM_HOME/config/crew-placement.json"
rm "$FM_HOME/config/finish-first-wip-mode"
check 0 'warning: WIP 2/2' candidate
out=$(bash "$ROOT/bin/fm-flow-report.sh")
assert_contains "$out" 'WIP over cap (2 of 2)' 'morning report shows the admission bound'
printf 'warn\n' > "$FM_HOME/config/finish-first-wip-mode"
check 0 warning candidate
printf 'enforce\n' > "$FM_HOME/config/finish-first-wip-mode"
check 1 'WIP 2/2' candidate
# Missing activity, a future stamp and a stamp older than 72 hours are not current work.
printf 'working [at=1]: old job\nworking [at=9999999999]: invalid future\n' > "$FM_HOME/state/current.status"
check 0 allowed candidate
out=$(bash "$ROOT/bin/fm-flow-report.sh")
assert_contains "$out" "stale, for Zac's triage: current" 'stale job remains visible for triage'
printf 'working [at=1]: held old job\n' > "$FM_HOME/state/held.status"
out=$(bash "$ROOT/bin/fm-flow-report.sh")
assert_contains "$out" 'held' 'old held jobs are also visible for triage'
printf 'working [at=%s]: held recent job\n' "$(date +%s)" > "$FM_HOME/state/held.status"
assert_contains "$(cat "$FM_HOME/data/backlog.md")" '- [ ] current' 'stale work is never auto-closed'
# Held rows are excluded even with fresh status; a completed blocker also clears normally.
printf 'working [at=%s]: active again\n' "$(date +%s)" > "$FM_HOME/state/current.status"
bash "$ROOT/bin/fm-tasks-axi.sh" hold current --reason waiting --kind external >/dev/null
check 0 allowed candidate
bash "$ROOT/bin/fm-tasks-axi.sh" unhold current >/dev/null
cp "$FM_HOME/data/backlog.md" "$TMP_ROOT/unblocked.md"
python3 - "$FM_HOME/data/backlog.md" <<'PYBLOCK'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace('- [ ] current -', '- [ ] current - blocked-by: oldest -'))
PYBLOCK
check 0 allowed candidate
cp "$TMP_ROOT/unblocked.md" "$FM_HOME/data/backlog.md"
printf 'invalid\n' > "$FM_HOME/config/finish-first-wip-mode"
check 2 'warn or enforce' candidate
printf 'enforce\n' > "$FM_HOME/config/finish-first-wip-mode"
# Recent PR updates and live launch reservations are independent activity evidence.
printf 'working [at=1]: old job\n' > "$FM_HOME/state/current.status"
printf 'pr=https://github.com/example/repo/pull/7\n' > "$FM_HOME/state/current.meta"
mkdir -p "$TMP_ROOT/activity-tools"
cat > "$TMP_ROOT/activity-tools/gh-axi" <<'PRUPDATE'
#!/usr/bin/env bash
printf 'api_response:\n  body: "%s"\n  truncated: false\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PRUPDATE
chmod +x "$TMP_ROOT/activity-tools/gh-axi"
old_path=$PATH
export PATH="$TMP_ROOT/activity-tools:$PATH"
check 1 'WIP 2/2' candidate
cat > "$TMP_ROOT/activity-tools/gh-axi" <<'PRFAIL'
#!/usr/bin/env bash
exit 1
PRFAIL
check 0 'activity unavailable' candidate
export PATH=$old_path
printf 'backend=tmux\nwindow=fixture:current\nkind=ship\nspawn_gen=s%s.1\n' "$(date +%s)" > "$FM_HOME/state/current.meta"
check 1 'WIP 2/2' candidate
rm "$FM_HOME/state/current.meta"
printf 'working [at=%s]: restored\n' "$(date +%s)" > "$FM_HOME/state/current.status"
pass 'WIP modes and current activity exclude stale and held backlog records'
# Redacted operating-home shape: 79 open jobs, 49 held, 22 recently active.
fixture_home=$FM_HOME
export FM_HOME="$TMP_ROOT/overloaded-home"
mkdir -p "$FM_HOME/data" "$FM_HOME/state" "$FM_HOME/config"
printf 'backend = "markdown"\n' > "$FM_HOME/.tasks.toml"
printf '{"max_crew":4}\n' > "$FM_HOME/config/crew-placement.json"
python3 - "$FM_HOME" <<'PYREAL'
from pathlib import Path
import sys,time
home=Path(sys.argv[1]); rows=['## In flight']
for i in range(79):
    task=f'job-{i:02d}'
    held=' (hold: outside answer) (hold-kind: external)' if i<49 else ''
    rows.append(f'- [ ] {task} - Work item (kind: ship) (priority: 2){held}')
    if i<71:
        (home/'state'/f'{task}.status').write_text(f'working [at={int(time.time())}]: checkpoint\n')
rows.extend(['## Queued','- [ ] candidate - New work (kind: ship) (priority: 2)'])
(home/'data/backlog.md').write_text('\n'.join(rows)+'\n')
PYREAL
before=$(cksum "$FM_HOME/data/backlog.md")
check 0 'warning: WIP 22/8' candidate
out=$(bash "$ROOT/bin/fm-flow-report.sh")
assert_contains "$out" 'WIP over cap (22 of 8)' 'morning report exposes overload without freezing starts'
assert_contains "$out" "stale, for Zac's triage: job-71" 'old jobs stay listed for triage'
assert_equals "$before" "$(cksum "$FM_HOME/data/backlog.md")" 'admission and reporting never close old jobs'
export FM_HOME=$fixture_home
pass 'operating-home overload warns and ordinary work stays runnable'


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
printf 'enforce\n' > "$spawn_home/config/finish-first-wip-mode"
for task in current carried; do
  printf 'working [at=%s]: active fixture\n' "$(date +%s)" > "$spawn_home/state/$task.status"
done
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
