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
bash "$ROOT/bin/fm-tasks-axi.sh" hold urgent --reason 'outside answer' --kind external >/dev/null
check 1 oldest candidate
bash "$ROOT/bin/fm-tasks-axi.sh" unhold urgent >/dev/null
check 0 'allowed' urgent
bash "$ROOT/bin/fm-tasks-axi.sh" hold urgent --reason 'outside answer' --kind external >/dev/null
check 0 'resume' current
# Held and blocked items never order otherwise dispatchable work.
bash "$ROOT/bin/fm-tasks-axi.sh" hold oldest --reason 'outside answer' --kind external >/dev/null
check 1 carried candidate
bash "$ROOT/bin/fm-tasks-axi.sh" block carried --by held >/dev/null
check 1 current candidate
bash "$ROOT/bin/fm-tasks-axi.sh" hold current --reason 'outside answer' --kind external >/dev/null
check 0 allowed candidate
# WIP counts backlog rows, including holds, and never parked metadata.
bash "$ROOT/bin/fm-tasks-axi.sh" unhold urgent >/dev/null
printf '1\n' > "$FM_HOME/config/crew-slot-cap"
check 1 'WIP' urgent
bash "$ROOT/bin/fm-tasks-axi.sh" unhold current >/dev/null
check 0 resume current
printf '2\n' > "$FM_HOME/config/crew-slot-cap"
check 0 allowed urgent
printf 'oops\n' > "$FM_HOME/config/crew-slot-cap"
check 2 'crew-slot-cap' urgent
rm "$FM_HOME/config/crew-slot-cap"
mkdir -p "$FM_HOME/state"
printf 'kind=ship\n' > "$FM_HOME/state/parked.meta"
check 0 allowed urgent
check 2 'missing' absent
pass 'finish-first orders real backlog rows and bounds WIP without task-record counts'

# Existing placement crew limits supply the WIP default.
printf '{"version":1,"max_crew":1}\n' > "$FM_HOME/config/crew-placement.json"
check 1 WIP urgent
printf '2\n' > "$FM_HOME/config/crew-slot-cap"
check 0 allowed urgent
rm "$FM_HOME/config/crew-slot-cap"
printf '{"version":1,"max_crew":true}\n' > "$FM_HOME/config/crew-placement.json"
check 2 'max_crew' urgent
pass 'WIP reuses placement crew limits with an explicit override'
# The placement decision must retain the finish-first refusal and queue it.
printf '{"version":1,"max_crew":1}\n' > "$FM_HOME/config/crew-placement.json"
CONFIG="$FM_HOME/config" DATA="$FM_HOME/data" STATE="$FM_HOME/state"
SCRIPT_DIR="$ROOT/bin"
. "$ROOT/bin/fm-tasks-axi-lib.sh"
. "$ROOT/bin/fm-backlog-transition-lib.sh"
. "$ROOT/bin/fm-placement-lib.sh"
FM_PLACEMENT_ID=urgent
FM_PLACEMENT_ACTIVE=1
RELAUNCH=0
KIND=ship
PROJ=demo
seed='{"task":"urgent","request":{},"checks":{},"admitted":true}'
decision=$(fm_placement_finish_first "$seed")
assert_equals fail "$(jq -r '.checks["finish-first"].status' <<< "$decision")" 'placement checks order and WIP'
rc=0
fm_placement_publish "$decision" >/dev/null 2>&1 || rc=$?
expect_code 1 "$rc" 'placement refuses work above WIP'
assert_equals '["finish-first"]' "$(jq -c '.waits.urgent.failed' "$STATE/capacity.json")" 'refusal enters existing queue'
printf '2\n' > "$CONFIG/crew-slot-cap"
FM_PLACEMENT_MODE=recheck
decision=$(fm_placement_finish_first "$seed")
fm_placement_publish "$decision" >/dev/null
assert_equals ready "$(jq -r '.waits.urgent.state' "$STATE/capacity.json")" 'capacity recheck releases the waiting item'
pass 'finish-first refusal and recovery use the placement ledger'
# The real spawn entrypoint refuses before allocating a worker or local copy.
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"
spawn_home="$TMP_ROOT/spawn-home"
fm_test_spawn_home "$spawn_home" claude
fm_test_spawn_brief "$spawn_home" candidate
printf 'backend = "markdown"\n' > "$spawn_home/.tasks.toml"
cp "$ROOT/tests/fixtures/finish-first/backlog.md" "$spawn_home/data/backlog.md"
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
assert_contains "$out" 'finish urgent first' 'real spawn names priority leader'
assert_absent "$spawn_home/allocated" 'refusal happens before worker allocation'
assert_absent "$spawn_home/state/candidate.meta" 'refusal leaves no parked task record'
assert_contains "$(TASKS_AXI_FILE="$spawn_home/data/backlog.md" tasks-axi show candidate)" 'state: queued' 'refused job remains queued'
pass 'real spawn enforces finish-first before resource allocation'
