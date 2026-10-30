#!/usr/bin/env bash
# Advisory journal warning in a separate process: wake globals stay private.
# Usage: fm-flow-warning.sh <data> <message>
set -u
FLOW_WARNING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-${1%/*}/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "$FLOW_WARNING_DIR/fm-wake-lib.sh"
echo "flow-history: $2" >&2
if [ "$(cat "$STATE/.flow-history-warning" 2>/dev/null)" != "$2" ]; then
  fm_wake_append check flow-history "check: flow-history: $2; inspect flow-history.jsonl; preserve damaged rows" \
    && printf '%s\n' "$2" > "$STATE/.flow-history-warning"
fi
