#!/usr/bin/env bash
# fm-claude-cd-guard.sh - Claude working-directory guard entrypoint.
# Usage: <hook JSON on stdin> | bin/fm-claude-cd-guard.sh
# Grok loads Claude settings too; this Claude entrypoint must stand down there.
set -u
[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/fm-cd-pretool-check.sh" --claude
