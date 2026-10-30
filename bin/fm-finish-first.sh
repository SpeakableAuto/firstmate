#!/usr/bin/env bash
# Read-only finish-first admission for a new ship/scout backlog item.
# Usage: fm-finish-first.sh <task-id>
# Uses this home's tasks-axi backlog, never task metadata or worktree counts.
# Exit 0 allows (including resuming an In-flight row), 1 names a hold or
# a reached WIP bound, 2 means the inputs cannot be proved. No state is changed.
# Configured placement supplies the crew count used for the WIP bound.
# The same command can be called by placement admission before fm-spawn.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  --help|-h) sed -n '2,8s/^# *//p' "$0"; exit 0 ;;
esac
[ "$#" -eq 1 ] || { echo 'usage: fm-finish-first.sh <task-id>' >&2; exit 2; }
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-backlog-lib.sh
. "$SCRIPT_DIR/fm-backlog-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
backend=$(fm_tasks_axi_backend_resolve "${DATA%/*}") || exit 2
if [ "$backend" = markdown ]; then
  backlog_json "$DATA/backlog.md" | python3 "$SCRIPT_DIR/fm-finish-first.py" "$1" "$CONFIG"
else
  # Native adapters expose their own holds/dependencies and numeric priority.
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  fm_exec_timed 15 15 bash "$SCRIPT_DIR/fm-tasks-axi.sh" list --fields blocked,held,created,priority \
    | python3 "$SCRIPT_DIR/fm-finish-first.py" "$1" "$CONFIG" --native
fi
