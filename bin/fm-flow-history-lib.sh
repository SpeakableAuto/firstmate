# shellcheck shell=bash
# Shared journal hooks for fm-tasks-axi.sh and lifecycle backlog mutations.
# Call begin before the mutation and finish with its unchanged output/status.
# Requires fm-backlog-transition-lib.sh for the bounded priority read.
FM_FLOW_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fm_flow_begin() {  # <data> <verb> <id> <none|merge|local>; sets FM_FLOW_TOKEN
  local data=$1 verb=$2 id=$3 landing=$4 detail priority kind serves parent_detail
  FM_FLOW_TOKEN=
  case "$verb" in start|done|close|reopen) ;; *) return 0 ;; esac
  case "$verb:$landing" in
    done:none|done:merge|done:local|done:report|close:none|close:merge|close:local|close:report) ;;
    start:*|reopen:*) landing=none ;;
    *) echo 'flow-history: invalid landing authority' >&2; return 1 ;;
  esac
  detail=$(fm_backlog_row_show "$data" "$id") || return 1
  # Share placement's impact parsing, including trailing metadata and legacy
  # numeric priorities. Native adapters retain their numeric field fallback.
  priority=$(printf '%s\n' "$detail" | sed -n 's/^  priority: *//p' | head -1)
  serves=$(printf '%s\n' "$detail" | sed -n 's/^  title:.*(serves: *\([A-Za-z0-9][A-Za-z0-9._-]*\)).*/\1/p' | head -1)
  kind=$(printf '%s\n' "$detail" | sed -n 's/^  kind: *//p' | head -1)
  case "$priority" in ''|'-'|'"-"') priority=2 ;; esac
  if [ -f "$data/backlog.md" ]; then
    # shellcheck source=bin/fm-backlog-lib.sh
    . "$FM_FLOW_SCRIPT_DIR/fm-backlog-lib.sh"
    detail=$(backlog_json "$data/backlog.md" | jq -r --arg id "$id" '.records[] | select(.id==$id) | [.impact,.kind // "task",.serves // ""] | @tsv')
    if [ -n "$detail" ]; then
      IFS=$'\t' read -r priority kind serves <<< "$detail"
      priority=${priority#P}
    fi
  fi
  # Only a real In-flight parent establishes this relation at recording time.
  if [ -n "$serves" ] && [ "$serves" != "$id" ]; then
    parent_detail=$(fm_backlog_row_show "$data" "$serves") || parent_detail=
    if ! printf '%s\n' "$parent_detail" | grep -q '^  state: in_flight$'; then serves=; fi
  else
    serves=
  fi
  case "$priority" in ''|*[!0-9]*) echo 'flow-history: cannot read task priority' >&2; return 1 ;; esac
  # The sourcing caller reads this output variable after the function returns.
  # shellcheck disable=SC2034
  FM_FLOW_TOKEN=$(python3 "$FM_FLOW_SCRIPT_DIR/fm-flow-history.py" --data "$data" begin "$id" "$priority" "$landing" --kind "${kind:-task}" --serves "$serves")
}
fm_flow_finish() {  # <data> <token> <verb> <id> <status> <output>
  local action=$3 finish_ok=1 health warning_latch
  [ -n "$2" ] || return 0
  [ "$action" != close ] || action="done"
  if ! printf '%s\n' "$6" | python3 "$FM_FLOW_SCRIPT_DIR/fm-flow-history.py" --data "$1" finish "$2" "$action" "$4" "$5"; then
    finish_ok=0
    fm_flow_warning "$1" 'receipt missing; history incomplete'
  fi
  if ! health=$(python3 "$FM_FLOW_SCRIPT_DIR/fm-flow-history.py" --data "$1" health 2>&1); then
    fm_flow_warning "$1" "$health"
  elif [ "$finish_ok" = 1 ]; then
    warning_latch="${FM_STATE_OVERRIDE:-${1%/*}/state}/.flow-history-warning"
    rm -f -- "$warning_latch" 2>/dev/null || true
  fi
}

fm_flow_warning() {  # <data> <message>; advisory, deduplicated durable wake
  bash "$FM_FLOW_SCRIPT_DIR/fm-flow-warning.sh" "$1" "$2"
}
