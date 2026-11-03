#!/usr/bin/env bash
# Read-only activity proof for one backlog row, using shared worker liveness.
# Usage: fm-flow-live.sh <state> <task-id>
set -euo pipefail
FLOW_LIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-live-workers-lib.sh
. "$FLOW_LIVE_DIR/fm-live-workers-lib.sh"
fm_flow_live_selected() { [ "$1" = "$2/$3.meta" ]; }
fm_live_workers_count "$1" '' fm_flow_live_selected "$1" "$2"
printf '%s\n' "$FM_LIVE_WORKERS_COUNT"
