#!/usr/bin/env bash
# Urgent captain alerts that leave the machine, for blockers firstmate cannot
# repair itself. Routine updates never use this path.
# Usage:
#   FM_HOME=/abs/home fm-urgent-alert.sh send <condition> <key> <message...>
#   FM_HOME=/abs/home fm-urgent-alert.sh test
#   FM_HOME=/abs/home fm-urgent-alert.sh log [count]
#   FM_HOME=/abs/home fm-urgent-alert.sh check-machine <label> <ssh-host>
# Conditions: supervisor-down, carve-out-blocked, machine-down.
# `send` passes a plain-words message through fm_urgent_alert in
# bin/fm-active-alert-lib.sh, which owns the target config, the Hermes
# delivery, the rate limits and the sent.jsonl log; it prints sent,
# skipped:<reason> or failed:<reason>, plus `message_id=<id>` when delivered.
# `test` sends the fixed setup message "Firstmate weekend alerts are set up"
# under the `test` condition and prints its message id.
# `log` prints the most recent attempts (default 10) from
# state/urgent-alert/sent.jsonl.
# `check-machine` is one bounded reachability probe for a scheduled job:
# `ssh -o BatchMode=yes -o ConnectTimeout=10 <ssh-host> true`, replaceable by
# FM_MACHINE_PROBE (a command run with the host as $1). Failures are counted
# in state/urgent-alert/machine-<label>.json; once the machine has failed
# FM_MACHINE_DOWN_PROBES (default 3) consecutive probes spanning at least
# FM_MACHINE_DOWN_SECS (default 900), one machine-down alert is sent for that
# outage. A successful probe ends the outage.
# Exit: 0 sent or rate-limited skip (or machine reachable), 1 delivery failed
# or not configured, 2 usage error.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-active-alert-lib.sh
. "$SCRIPT_DIR/fm-active-alert-lib.sh"

log() { printf 'fm-urgent-alert: %s\n' "$*" >&2; }
usage() { sed -n '2,/^set -eu/{ /^#/s/^# \{0,1\}//p; }' "$0"; }

urgent_send() {  # <condition> <key> <message>
  local rc=0
  fm_urgent_alert "$@" || rc=$?
  [ -z "$FM_URGENT_ALERT_MESSAGE_ID" ] || printf 'message_id=%s\n' "$FM_URGENT_ALERT_MESSAGE_ID"
  return "$rc"
}

machine_probe() {  # <host>
  if [ -n "${FM_MACHINE_PROBE:-}" ]; then
    "$FM_MACHINE_PROBE" "$1" >/dev/null 2>&1
    return
  fi
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$1" true >/dev/null 2>&1 </dev/null
}

check_machine() {  # <label> <host>
  local label=$1 host=$2 dir file now record first fails alerted probes secs rc=0
  case "$label" in ''|*[!A-Za-z0-9._-]*) echo 'fm-urgent-alert: label must be [A-Za-z0-9._-]+' >&2; return 2 ;; esac
  [ -n "$host" ] || { usage >&2; return 2; }
  dir="${FM_STATE_OVERRIDE:-$FM_HOME/state}/urgent-alert"
  file="$dir/machine-$label.json"
  mkdir -p "$dir"
  now=$(date +%s)
  if machine_probe "$host"; then
    rm -f "$file"
    printf 'reachable\n'
    return 0
  fi
  record='{"first":0,"fails":0,"alerted":false}'
  [ ! -f "$file" ] || record=$(jq -c 'select(type == "object")' "$file" 2>/dev/null) || record='{"first":0,"fails":0,"alerted":false}'
  [ -n "$record" ] || record='{"first":0,"fails":0,"alerted":false}'
  first=$(printf '%s' "$record" | jq -r '.first // 0')
  fails=$(printf '%s' "$record" | jq -r '.fails // 0')
  alerted=$(printf '%s' "$record" | jq -r '.alerted // false')
  [ "$first" -gt 0 ] || first=$now
  fails=$((fails + 1))
  probes=$(fm_urgent_alert_int "${FM_MACHINE_DOWN_PROBES:-}" 3)
  secs=$(fm_urgent_alert_int "${FM_MACHINE_DOWN_SECS:-}" 900)
  if [ "$alerted" = false ] && [ "$fails" -ge "$probes" ] && [ "$((now - first))" -ge "$secs" ]; then
    fm_urgent_alert machine-down "$label-$first" \
      "Firstmate: the $label machine has been unreachable for $(( (now - first) / 60 )) minutes. Work routed to it is stopped until it is back online." || rc=$?
    case "$FM_URGENT_ALERT_RESULT" in sent|skipped:*) alerted=true ;; esac
  else
    printf 'unreachable\n'
  fi
  jq -cn --argjson first "$first" --argjson fails "$fails" --argjson alerted "$alerted" \
    '{first:$first,fails:$fails,alerted:$alerted}' > "$file.tmp"
  mv "$file.tmp" "$file"
  return "$rc"
}

main() {
  local cmd=${1:-}
  case "$cmd" in -h|--help) usage; return 0 ;; esac
  : "${FM_HOME:?explicit FM_HOME required}"
  case "$FM_HOME" in /*) ;; *) echo 'fm-urgent-alert: FM_HOME must be absolute' >&2; return 2 ;; esac
  shift || true
  case "$cmd" in
    send)
      [ "$#" -ge 3 ] || { usage >&2; return 2; }
      [ "$1" != test ] || { echo 'fm-urgent-alert: use the test subcommand for the setup message' >&2; return 2; }
      local condition=$1 key=$2
      shift 2
      urgent_send "$condition" "$key" "$*"
      ;;
    test)
      [ "$#" -eq 0 ] || { usage >&2; return 2; }
      urgent_send test setup 'Firstmate weekend alerts are set up'
      ;;
    log)
      local n=${1:-10} file="${FM_STATE_OVERRIDE:-$FM_HOME/state}/urgent-alert/sent.jsonl"
      case "$n" in ''|*[!0-9]*) usage >&2; return 2 ;; esac
      [ ! -f "$file" ] || tail -n "$n" "$file"
      ;;
    check-machine)
      [ "$#" -eq 2 ] || { usage >&2; return 2; }
      check_machine "$1" "$2"
      ;;
    *) usage >&2; return 2 ;;
  esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
