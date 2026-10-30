# shellcheck shell=bash
# Shared journal hooks for fm-tasks-axi.sh and lifecycle backlog mutations.
# Call begin before the mutation and finish with its unchanged output/status.
# Requires fm-backlog-transition-lib.sh for the bounded priority read.
FM_FLOW_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fm_flow_begin() {  # <data> <verb> <id> <none|merge|local>; sets FM_FLOW_TOKEN
  local data=$1 verb=$2 id=$3 landing=$4 detail priority
  FM_FLOW_TOKEN=
  case "$verb" in start|done|close|reopen) ;; *) return 0 ;; esac
  case "$verb:$landing" in
    done:none|done:merge|done:local|close:none|close:merge|close:local) ;;
    start:*|reopen:*) landing=none ;;
    *) echo 'flow-history: invalid landing authority' >&2; return 1 ;;
  esac
  detail=$(fm_backlog_row_show "$data" "$id") || return 1
  priority=$(printf '%s\n' "$detail" | sed -n 's/^  priority: *//p' | head -1)
  case "$priority" in '-'|'"-"') priority=3 ;; esac
  case "$priority" in ''|*[!0-9]*) echo 'flow-history: cannot read task priority' >&2; return 1 ;; esac
  # The sourcing caller reads this output variable after the function returns.
  # shellcheck disable=SC2034
  FM_FLOW_TOKEN=$(python3 "$FM_FLOW_SCRIPT_DIR/fm-flow-history.py" --data "$data" begin "$id" "$priority" "$landing")
}
fm_flow_finish() {  # <data> <token> <verb> <id> <status> <output>
  local action=$3
  [ -n "$2" ] || return 0
  [ "$action" != close ] || action="done"
  printf '%s\n' "$6" | python3 "$FM_FLOW_SCRIPT_DIR/fm-flow-history.py" --data "$1" finish "$2" "$action" "$4" "$5"
}
