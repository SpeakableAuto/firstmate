#!/usr/bin/env bash
# fm-claude-arm-guard.sh - Claude watcher-arm guard entrypoint.
# Usage: <hook JSON on stdin> | bin/fm-claude-arm-guard.sh
# Grok loads Claude settings too; its native registration owns this event.
set -u
[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/fm-arm-pretool-check.sh" --claude
