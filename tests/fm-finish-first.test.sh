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
