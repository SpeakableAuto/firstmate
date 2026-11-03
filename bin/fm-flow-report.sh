#!/usr/bin/env bash
# Read-only AEST finished, closed-not-landed and started work from backlog history.
# Usage: fm-flow-report.sh [--date YYYY-MM-DD]
# The default date is yesterday. Missing or incomplete history prints unknown;
# no date is backfilled from current backlog rows. fm-flow-history.py owns
# the journal schema, coverage limits and two-completed-days signal.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
case "${1:-}" in
  --help|-h) exec python3 "$SCRIPT_DIR/fm-flow-history.py" --data "$DATA" report "$@" ;;
esac
python3 "$SCRIPT_DIR/fm-flow-history.py" --data "$DATA" report "$@"
# The current backlog appendix is independent of historical daily counts.
if ! bash "$SCRIPT_DIR/fm-finish-first.sh" --report; then
  printf 'WIP activity: unknown; inspect the admission diagnostic above\n'
fi
