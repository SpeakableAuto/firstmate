#!/usr/bin/env bash
# Read-only finish-first admission for a new ship/scout backlog item.
# Usage: fm-finish-first.sh <task-id>
# Uses this home's tasks-axi backlog, never task metadata or worktree counts.
# Exit 0 allows (including resuming an In-flight row), 1 names earlier work or
# a reached WIP bound, 2 means the inputs cannot be proved. No state is changed.
# The optional config/crew-slot-cap setting is owned by docs/configuration.md.
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
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
if ! rows=$(fm_exec_timed 15 15 bash "$SCRIPT_DIR/fm-tasks-axi.sh" list --fields blocked,held,created,priority); then
  echo 'finish-first: cannot read backlog; repair tasks-axi before dispatch' >&2
  exit 2
fi
printf '%s\n' "$rows" | python3 "$SCRIPT_DIR/fm-finish-first.py" "$1" "$CONFIG/crew-slot-cap"
