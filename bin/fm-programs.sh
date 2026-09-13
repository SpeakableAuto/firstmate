#!/usr/bin/env bash
# fm-programs.sh --json
# Read-only complete accepted-program view for this FM_HOME; never capped.
# bin/fm-programs-lib.sh owns the native backlog body fields and clock contract.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-programs-lib.sh
. "$SCRIPT_DIR/fm-programs-lib.sh"
case "${1:---json}" in
  --json) ;;
  --help|-h) sed -n '2,4s/^# //p' "$0"; exit 0 ;;
  *) printf 'usage: fm-programs.sh --json\n' >&2; exit 2 ;;
esac
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
fm_programs_json "${FM_DATA_OVERRIDE:-$FM_HOME/data}/backlog.md"
