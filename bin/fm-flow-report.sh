#!/usr/bin/env bash
# Read-only UTC daily finished, started and reopened work from backlog history.
# Usage: fm-flow-report.sh --since YYYY-MM-DD [--until YYYY-MM-DD]
# Default end is yesterday UTC. Missing/incomplete history prints unknown;
# no date is backfilled from current backlog rows. fm-flow-history.py owns
# the journal schema, coverage limits and two-completed-days signal.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
exec python3 "$SCRIPT_DIR/fm-flow-history.py" --data "$DATA" report "$@"
