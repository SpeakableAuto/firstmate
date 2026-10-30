#!/usr/bin/env bash
# Configured, bounded active alert channels for supervision failures.
# Callers provide FM_HOME and log(); this file owns the channel contract.
: "${WEDGE_ALARM_TIMEOUT_SECS_DEFAULT:=10}"

# --- backend-independent active supervision alerts --------------------------
# These helpers provide a shared configured alert that does not depend on any
# pane or backend status-line: an OS-level macOS notification, a Herdr
# notification, or a captain-supplied command such as a phone push.
# Callers own their durable marker, rate limit, and any local visual signal.
# Every channel is best-effort: a missing or failing channel logs and is skipped
# without aborting the caller.
#
# Config: config/wedge-alarm (local, gitignored), one channel directive per
# non-empty, non-comment line. FM_WEDGE_ALARM_CHANNEL overrides the file with a
# single directive. Directives:
#   off              disable the active alert entirely, regardless of position
#                    (caller-owned markers and local signals remain)
#   auto | default   platform default: macOS -> osascript; otherwise none
#   osascript        macOS Notification Center banner (backend-independent)
#   herdr            herdr UI notification (herdr notification show)
#   command:<cmd>    run <cmd> via `sh -c`, summary on $1 and on stdin
# An absent config means auto, i.e. default-ON on macOS: the alarm's whole
# purpose is to never be silent, so the reachable OS channel fires unless the
# captain explicitly disables it.

# Print the configured channel directives, one per line. FM_WEDGE_ALARM_CHANNEL
# wins (a single directive); else each non-empty, non-comment line of
# config/wedge-alarm; else "auto".
wedge_alarm_configured_channels() {
  local cfg line found=
  if [ -n "${FM_WEDGE_ALARM_CHANNEL:-}" ]; then
    printf '%s\n' "$FM_WEDGE_ALARM_CHANNEL"
    return 0
  fi
  cfg="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/wedge-alarm"
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in '#'*) continue ;; esac
      printf '%s\n' "$line"
      found=1
    done < "$cfg"
  fi
  [ -n "$found" ] || printf 'auto\n'
}

# Resolve the platform's default OS-level channel for `auto`. macOS reaches the
# captain via an osascript Notification Center banner; other platforms have no
# built-in OS channel (the captain wires a command: directive), so this prints
# nothing and wedge_alarm_notify logs that the marker is the only signal.
wedge_alarm_platform_default() {
  case "$(uname)" in
    Darwin) command -v osascript >/dev/null 2>&1 && printf 'osascript' ;;
    *) : ;;
  esac
}

wedge_alarm_run_bounded() {
  local channel=$1 timeout monitor_was_on=0 pid start elapsed rc
  shift
  timeout=${FM_WEDGE_ALARM_TIMEOUT_SECS:-$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*) timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
    *) [ "$timeout" -gt 0 ] 2>/dev/null || timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
  esac
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  case $- in
    *m*) ;;
    *) log "wedge alarm: ${channel} notifier skipped because its watchdog could not start"; return 125 ;;
  esac
  "$@" &
  pid=$!
  WEDGE_ALARM_NOTIFIER_PID=$pid
  start=$SECONDS
  while kill -0 "-$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      wedge_alarm_stop_active_notifier
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      log "wedge alarm: ${channel} notifier timed out after ${elapsed}s (limit ${timeout}s)"
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  WEDGE_ALARM_NOTIFIER_PID=
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  return "$rc"
}

wedge_alarm_stop_active_notifier() {
  local pid=${WEDGE_ALARM_NOTIFIER_PID:-}
  [ -n "$pid" ] || return 0
  WEDGE_ALARM_NOTIFIER_PID=
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# The single execution seam for every configured notifier channel.
# FM_WEDGE_ALARM_EXEC, when set, REPLACES the real notifier: the resolved channel
# name and summary are handed to that command instead of ever invoking osascript
# or herdr or a captain-supplied command. Test callers set this seam to a
# recorder or to the special value "discard", which fires nothing. Unset means
# production, so the configured real channels fire.
wedge_alarm_os_notifier_override() {  # <channel> <summary>
  local channel=$1 summary=$2 rc exec_override=${FM_WEDGE_ALARM_EXEC:-}
  case "$exec_override" in
    '') return 2 ;;
    discard) return 0 ;;
    *)
      wedge_alarm_run_bounded "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      log "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
}

# Post a macOS Notification Center banner. `display notification` is OS-level,
# independent of any terminal pane or multiplexer status-line. The summary is
# passed as an argv item (never interpolated into the AppleScript source) so its
# text can never break the script. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_osascript() {  # <summary>
  local summary=$1 rc
  wedge_alarm_os_notifier_override osascript "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v osascript >/dev/null 2>&1 || {
    log "wedge alarm: osascript not found; cannot post a macOS notification"; return 1; }
  wedge_alarm_run_bounded osascript osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "firstmate: away-mode escalations WEDGED" sound name "Basso"' \
    -e 'end run' "$summary" >/dev/null 2>&1 && return 0
  log "wedge alarm: osascript notification failed"
  return 1
}

# Post a herdr UI notification - herdr's own surface, separate from the pane and
# its status-line. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_herdr() {  # <summary>
  local summary=$1 rc
  wedge_alarm_os_notifier_override herdr "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v herdr >/dev/null 2>&1 || {
    log "wedge alarm: herdr not found; cannot post a herdr notification"; return 1; }
  wedge_alarm_run_bounded herdr herdr notification show "firstmate: away-mode escalations WEDGED" \
    --body "$summary" --sound request >/dev/null 2>&1 && return 0
  log "wedge alarm: herdr notification failed"
  return 1
}

# Run a captain-supplied command with the summary on $1 and on stdin, so an
# alert can reach a phone/pager (ntfy, Slack, SMS) even when the captain is away
# from the machine entirely. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_command() {  # <cmd> <summary>
  local cmd=$1 summary=$2 rc
  if [ "${WEDGE_ALARM_EMIT_ACTIVE:-}" != 1 ]; then
    wedge_alarm_emit command "$summary" "$cmd"
    return $?
  fi
  [ -n "$cmd" ] || { log "wedge alarm: empty command: channel; nothing to run"; return 1; }
  wedge_alarm_run_bounded command sh -c "$cmd" fm-wedge-alarm "$summary" \
    <<< "$summary" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  log "wedge alarm: command channel exited $rc (command redacted)"
  return 1
}

wedge_alarm_emit() {  # <channel> <summary>
  local channel=$1 summary=$2 cmd=${3:-} rc exec_override=${FM_WEDGE_ALARM_EXEC:-} WEDGE_ALARM_EMIT_ACTIVE=1
  case "$exec_override" in
    '') ;;
    discard) return 0 ;;
    *)
      wedge_alarm_run_bounded "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      log "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
  case "$channel" in
    osascript) wedge_alarm_via_osascript "$summary" ;;
    herdr) wedge_alarm_via_herdr "$summary" ;;
    command) wedge_alarm_via_command "$cmd" "$summary" ;;
  esac
}

# Fire every configured active-alert channel, best-effort. Always returns 0: a
# channel failure can never abort the caller. Any
# `off` directive disables the alert, regardless of position; an unresolvable
# `auto` (no OS channel on this platform) logs that the durable marker is the
# only signal. Every notifier routes through the override seam above.
wedge_alarm_notify() {  # <summary> <marker>
  local summary=$1 marker=$2 ch
  local -a channels=()
  while IFS= read -r ch; do
    [ -n "$ch" ] || continue
    channels+=("$ch")
  done < <(wedge_alarm_configured_channels)
  for ch in "${channels[@]}"; do
    [ "$ch" = off ] && return 0
  done
  for ch in "${channels[@]}"; do
    case "$ch" in auto|default) ch=$(wedge_alarm_platform_default) ;; esac
    case "$ch" in
      '') log "wedge alarm: no OS-level alert channel on $(uname); durable marker $marker is the only signal - set config/wedge-alarm (e.g. a command: directive)" ;;
      osascript|herdr) wedge_alarm_emit "$ch" "$summary" || true ;;
      command:*) wedge_alarm_emit command "$summary" "${ch#command:}" || true ;;
      *) log "wedge alarm: unrecognized active-alert channel directive (redacted); marker still written" ;;
    esac
  done
  return 0
}

# --- urgent captain escalation ----------------------------------------------
# The wedge alarm above is local and fires for every supervision failure. The
# urgent path below reaches the captain away from the machine, so it accepts
# only conditions that block all priority progress and that firstmate cannot
# repair itself, never routine updates:
#   supervisor-down    the supervisor still makes no progress after a restart
#                      attempt, or the restart could not be proven
#   carve-out-blocked  a captain-only decision is blocking every priority task
#   machine-down       a fleet machine stayed unreachable
#   test               the explicit setup test message only
#
# Delivery writes the plain message to a private file and runs
# `hermes send --to telegram --json --file <file>`; Hermes owns the platform
# login, so firstmate never reads it. FM_HERMES_BIN overrides the binary.
# FM_URGENT_ALERT_EXEC, when set, REPLACES the sender for tests: it runs with
# `telegram` as $1 and the message on stdin, and prints Hermes-shaped JSON
# ({"success":true,"message_id":"..."} or {"error":"..."}).
#
# Rate limits, checked under one lock before any send:
#   - at most one delivered message per condition per
#     FM_URGENT_ALERT_CONDITION_SECS (default 21600, six hours);
#   - the same condition and key are not re-sent within
#     FM_URGENT_ALERT_DEDUPE_SECS (default 86400);
#   - at most FM_URGENT_ALERT_DAILY_CAP (default 4) delivered messages in any
#     rolling 24 hours, across all conditions;
#   - a failed delivery may retry the same condition after
#     FM_URGENT_ALERT_RETRY_SECS (default 900).
# Every attempt appends one JSON line to state/urgent-alert/sent.jsonl with its
# time, condition, key, result, reason, message hash and, when delivered, the
# platform message id. Message text and platform chat ids are never logged.

URGENT_ALERT_CONDITIONS='supervisor-down carve-out-blocked machine-down test'

fm_urgent_alert_condition_ok() {  # <condition>
  case " $URGENT_ALERT_CONDITIONS " in *" $1 "*) return 0 ;; esac
  return 1
}

fm_urgent_alert_int() {  # <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

fm_urgent_alert_record() {  # <log> <now> <condition> <key> <result> <reason> <sha> [message-id]
  jq -cn --argjson at "$2" --arg condition "$3" --arg key "$4" --arg result "$5" \
    --arg reason "$6" --arg sha "$7" --arg id "${8:-}" \
    '{at:$at,condition:$condition,key:$key,result:$result,reason:$reason,message_sha:$sha}
     + (if $id == "" then {} else {message_id:$id} end)' >> "$1"
}

# The bounded runner starts a background job, which does not reliably inherit
# a pipe on stdin, so the message travels through a private file instead.
fm_urgent_alert_deliver() {  # <message-file>  -> prints Hermes JSON
  local file=$1 hermes
  if [ -n "${FM_URGENT_ALERT_EXEC:-}" ]; then
    # shellcheck disable=SC2016 # Positional parameters expand in the child.
    wedge_alarm_run_bounded urgent bash -c 'exec "$1" "$2" < "$3"' fm-urgent-alert \
      "$FM_URGENT_ALERT_EXEC" telegram "$file"
    return
  fi
  hermes=${FM_HERMES_BIN:-}
  [ -n "$hermes" ] || hermes=$(command -v hermes 2>/dev/null) || hermes=
  [ -n "$hermes" ] || [ ! -x "$HOME/.local/bin/hermes" ] || hermes="$HOME/.local/bin/hermes"
  [ -n "$hermes" ] || return 127
  wedge_alarm_run_bounded urgent "$hermes" send --to telegram --json --file "$file"
}

fm_urgent_alert_mtime() {  # <path>
  /usr/bin/stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# Record and print one fm_urgent_alert result; FM_URGENT_ALERT_RESULT lets a
# caller read it without a subshell that would lose FM_URGENT_ALERT_MESSAGE_ID.
fm_urgent_alert_result() {
  FM_URGENT_ALERT_RESULT=$1
  printf '%s\n' "$1"
}

# fm_urgent_alert <condition> <key> <message>
# Prints one result: sent, skipped:<reason>, or failed:<reason>. Returns 0 for
# sent or a rate-limited skip, 1 for a failed delivery, 2 for
# a condition outside the urgent list or an empty key or message. Also sets
# FM_URGENT_ALERT_RESULT and, when sent, FM_URGENT_ALERT_MESSAGE_ID.
fm_urgent_alert() {
  local condition=$1 key=${2:-} message=${3:-} dir log lock now sha out id rc reason
  local cond_secs dedupe_secs cap retry_secs held verdict
  FM_URGENT_ALERT_MESSAGE_ID=
  fm_urgent_alert_condition_ok "$condition" || { fm_urgent_alert_result 'failed:unknown-condition'; return 2; }
  [ -n "$key" ] && [ -n "$message" ] || { fm_urgent_alert_result 'failed:empty'; return 2; }
  dir="${FM_STATE_OVERRIDE:-$FM_HOME/state}/urgent-alert"
  log="$dir/sent.jsonl"
  lock="$dir/lock"
  mkdir -p "$dir" || { fm_urgent_alert_result 'failed:state'; return 1; }
  now=$(date +%s)
  sha=$(printf '%s' "$message" | shasum -a 256 | awk '{print $1}')
  cond_secs=$(fm_urgent_alert_int "${FM_URGENT_ALERT_CONDITION_SECS:-}" 21600)
  dedupe_secs=$(fm_urgent_alert_int "${FM_URGENT_ALERT_DEDUPE_SECS:-}" 86400)
  cap=$(fm_urgent_alert_int "${FM_URGENT_ALERT_DAILY_CAP:-}" 4)
  retry_secs=$(fm_urgent_alert_int "${FM_URGENT_ALERT_RETRY_SECS:-}" 900)
  # A lock left by a killed sender is reclaimed after two minutes; a live one
  # means another sender is mid-delivery, so this attempt stands down.
  if ! mkdir "$lock" 2>/dev/null; then
    held=$(fm_urgent_alert_mtime "$lock") || held=$now
    if [ "$((now - held))" -lt 120 ] || ! rm -rf "$lock" || ! mkdir "$lock" 2>/dev/null; then
      fm_urgent_alert_result 'skipped:busy'
      return 0
    fi
  fi
  [ -f "$log" ] || : > "$log"
  reason=
  verdict=$(jq -rs --argjson now "$now" --arg c "$condition" --arg k "$key" \
    --argjson cs "$cond_secs" --argjson ds "$dedupe_secs" --argjson rs "$retry_secs" '
      [ .[] | select(type == "object") ] as $r
      | if any($r[]; .result == "sent" and .condition == $c and .key == $k and $now - .at < $ds) then "duplicate"
        elif any($r[]; .result == "sent" and .condition == $c and $now - .at < $cs) then "condition-rate-limit"
        elif any($r[]; .result == "failed" and .condition == $c and $now - .at < $rs) then "retry-backoff"
        else [$r[] | select(.result == "sent" and $now - .at < 86400)] | length | tostring end' "$log" 2>/dev/null) \
    || verdict=corrupt-log
  case "$verdict" in
    duplicate|condition-rate-limit|retry-backoff|corrupt-log) reason=$verdict ;;
    ''|*[!0-9]*) reason='corrupt-log' ;;
    *) [ "$verdict" -lt "$cap" ] || reason='daily-cap' ;;
  esac
  if [ -n "$reason" ]; then
    fm_urgent_alert_record "$log" "$now" "$condition" "$key" skipped "$reason" "$sha"
    rm -rf "$lock"
    fm_urgent_alert_result "skipped:$reason"
    return 0
  fi
  ( umask 077; printf '%s\n' "$message" > "$lock/message" )
  if out=$(fm_urgent_alert_deliver "$lock/message" 2>/dev/null); then rc=0; else rc=$?; fi
  id=$(printf '%s' "$out" | jq -r 'select(type == "object" and .success == true and .error == null)
    | .message_id // empty | tostring' 2>/dev/null) || id=
  if [ "$rc" -eq 0 ] && [ -n "$id" ]; then
    fm_urgent_alert_record "$log" "$now" "$condition" "$key" sent '' "$sha" "$id"
    rm -rf "$lock"
    # shellcheck disable=SC2034 # Read by callers after a send.
    FM_URGENT_ALERT_MESSAGE_ID=$id
    fm_urgent_alert_result 'sent'
    return 0
  fi
  case "$rc" in
    0) reason='no-message-id' ;;
    124) reason='delivery-timeout' ;;
    127) reason='hermes-not-found' ;;
    *) reason='delivery-failed' ;;
  esac
  fm_urgent_alert_record "$log" "$now" "$condition" "$key" failed "$reason" "$sha"
  rm -rf "$lock"
  fm_urgent_alert_result "failed:$reason"
  return 1
}
