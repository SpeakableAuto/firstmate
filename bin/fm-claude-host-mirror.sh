#!/usr/bin/env bash
# fm-claude-host-mirror.sh - Claude host-mirror hook entrypoint.
# Usage: <hook JSON on stdin> | bin/fm-claude-host-mirror.sh
# Grok loads Claude settings too; this Claude entrypoint must stand down there.
set -u
[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/fm-host-mirror.sh" hook claude
