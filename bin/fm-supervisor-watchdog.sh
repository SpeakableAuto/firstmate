#!/usr/bin/env bash
# External, one-shot supervision watchdog for Claude on Herdr.
# Usage: FM_HOME=/absolute/home fm-supervisor-watchdog.sh tick
# Required environment (no endpoint discovery or default-session fallback):
#   FM_SUPERVISOR_TARGET       exact session:pane-id
#   FM_WATCHDOG_CLAUDE_VERSION installed Claude version approved by a live check
#   FM_WATCHDOG_PROBE_URL      HTTPS provider endpoint (no credentials/query)
# Optional: FM_WATCHDOG_IDLE_SECS=120, FM_WATCHDOG_BACKOFF_SECS=900,
# FM_WATCHDOG_WAKE_AGE_SECS=600.
# Schedule tick with launchd StartInterval, independently of the supervisor.
# State/logs: FM_HOME/state/supervisor-watchdog/{incident.json,events.jsonl}.
# A stable viewport with a terminal network error, native Claude idle/done,
# no busy footer, and a proven empty composer must survive two observations
# at least IDLE_SECS apart (minimum 10 seconds), with no semantic screen change.
# A clear frame resets the pending error window immediately.
# Claude's dim rotating empty-composer suggestion is excluded from that check.
# Unknown state, drafts, usage-limit notices and version drift defer recovery.
# A successful TLS HTTP response below 500 (except 429) proves reachability;
# failed probes use exponential backoff, capped at BACKOFF_SECS.
# Before typing, re-read every guard; before Enter, require exactly our payload.
# Never clear input, retry Enter, kill an agent, or execute shell commands there.
# Claim the incident durably BEFORE the nudge; ambiguous delivery is not retried.
# A changed screen or draft holds the incident and queues a firstmate check.
# Held/acted incidents rearm after a stable, readable, error-free viewport for
# IDLE_SECS; the retained action timestamp enforces cross-incident backoff.
# Independently, a main-owned durable wake older than
# FM_WATCHDOG_WAKE_AGE_SECS while Claude is idle queues one check and fires the
# configured active-alert channels once for that unchanged oldest row without
# typing into the supervisor pane.
# Only hashes/classifications are logged, never pane text or prompt contents.
# Unsupported harnesses/backends fail closed; this does not repair dead shells.
# Residual race: reads and sends are not atomic. A human keystroke in the final
# read/send window can mix with the nudge. This is guarded best-effort recovery,
# not an input lock. Mixed input is never cleared or submitted intentionally.
# shellcheck disable=SC2016 # jq programs use literal jq variables.
set -eu
FM_WATCHDOG_HOME=${FM_HOME:-}
CAPS=$'styled=1\ncursor=0\nidentity=1'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$SCRIPT_DIR/fm-composer-lib.sh"
# shellcheck source=bin/fm-active-alert-lib.sh
. "$SCRIPT_DIR/fm-active-alert-lib.sh"

watchdog_log() {
  jq -cn --arg event "$1" --arg detail "${2:-}" --argjson at "$NOW" \
    '{at:$at,event:$event,detail:$detail}' >> "$DIR/events.jsonl"
}
log() { watchdog_log notifier "$*"; }
watchdog_save() {
  printf '%s\n' "$RECORD" > "$DIR/incident.json.tmp"
  mv "$DIR/incident.json.tmp" "$DIR/incident.json"
}
watchdog_update() {
  local updated
  updated=$(printf '%s\n' "$RECORD" | jq -c "$@")
  [ "$updated" != "$RECORD" ] || return 0
  RECORD=$updated
  watchdog_save
}

# Public fixture interface: classify a captured viewport without touching a pane.
watchdog_screen() {
  local screen=$1 last live
  screen=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
  fm_composer_normalize_spaces_var screen
  if printf '%s\n' "$screen" | grep -Eiq 'usage limit reached|continuing automatically'; then
    printf 'usage-limit'; return
  fi
  # Only the last conversational output before the current composer counts.
  # A later user prompt or assistant response invalidates an old visible error.
  last=$(printf '%s\n' "$screen" | awk '
    {rows[NR]=$0}
    /^[[:space:]]*[❯›>]/ {composer=NR}
    END {
      for (i=1; i<composer; i++) {
        line=rows[i]
        if (line ~ /^[[:space:]─━│╭╰╮╯┌└┐┘-]*$/) continue
        if (line ~ /^[[:space:]]*Update available! Run:/) continue
        if (line ~ /^[[:space:]]*[✻✽✢✳✶✺].* for [0-9].*· done /) continue
        if (line ~ /^[[:space:]]*●[[:space:]]+(low|medium|high|max)[[:space:]]+·[[:space:]]+\/effort[[:space:]]*$/) continue
        last=line
      }
      print last
    }')
  # Match only the latest output row and current composer/footer region.
  # Earlier transcript rows can quote busy hints or retain an old spinner.
  live=$(printf '%s\n' "$screen" | awk '
    {rows[NR]=$0}
    /^[[:space:]]*[❯›>]/ {composer=NR}
    END {if (composer) for (i=composer; i<=NR; i++) print rows[i]}')
  if printf '%s\n%s\n' "$last" "$live" | fm_busy_lines_match claude; then
    printf 'busy'; return
  fi
  if printf '%s\n' "$last" | grep -Eiq '^[[:space:]⎿⏺●]*((API Error:.*(ENOTFOUND|EAI_AGAIN|ECONNRESET|ECONNREFUSED|ETIMEDOUT|network|connection|fetch failed))|((Unable|Cannot|Could not) to (connect to|reach) (the )?API))'; then
    printf 'error'
  else
    printf 'clear'
  fi
}

# Transport primitives are separate from policy so fixtures can supply pane
# observations. All live calls are explicitly scoped, read-only except the
# single send-text/Enter pair; none can auto-start a server or discover a pane.
watchdog_read() {
  fm_backend_herdr_cli "$SESSION" pane read "$PANE_ID" --source visible --format ansi
}
watchdog_identity() {
  fm_backend_herdr_cli "$SESSION" agent get "$PANE_ID" \
    | jq -er '[.result.agent.agent, .result.agent.agent_status] | @tsv'
}
watchdog_observe() {
  local identity composer semantic
  STYLED=$(watchdog_read) || { VERDICT=unreadable; return; }
  SCREEN=$(printf '%s\n' "$STYLED" | fm_composer_strip_ansi)
  [ -n "$SCREEN" ] || { VERDICT=unreadable; return; }
  identity=$(watchdog_identity) || { VERDICT=unreadable; return; }
  case "$identity" in
    claude$'\t'idle|claude$'\t'done) ;;
    claude$'\t'*) VERDICT=not-idle; return ;;
    *) VERDICT=unsupported-harness; return ;;
  esac
  SCREEN_KIND=$(watchdog_screen "$SCREEN")
  VERDICT=$SCREEN_KIND
  case "$VERDICT" in usage-limit|busy) return ;; esac
  composer=$(fm_composer_classify_screen "$CAPS" "$STYLED" '' "$identity")
  [ "$composer" = empty ] || { VERDICT="composer-${composer:-unknown}"; return; }
  semantic=$(printf '%s\n' "$STYLED" | fm_composer_strip_ghost)
  fm_composer_normalize_spaces_var semantic
  HASH=$(printf '%s' "$semantic" | shasum -a 256 | awk '{print $1}')
}

watchdog_hold() {
  local reason=$1
  watchdog_update --arg reason "$reason" '.held=$reason | .since=0'
  watchdog_log held "$reason"
  watchdog_alert
}
watchdog_alert() {
  local reason alerted
  reason=$(printf '%s' "$RECORD" | jq -r .held)
  alerted=$(printf '%s' "$RECORD" | jq -r .alerted)
  [ "$alerted" != "$reason" ] || return 0
  fm_wake_append check supervisor-watchdog \
    "Supervisor recovery withheld: $reason. Inspect state/supervisor-watchdog/events.jsonl; input preserved, no automatic retry." || return 1
  watchdog_update --arg reason "$reason" '.alerted=$reason'
}

# Alert on a main-owned row that has waited past the configured age while the
# native agent is idle. The watcher is responsible for delivery; this path only
# publishes an alert through the existing check-wake route and never types.
watchdog_queue_alert() {
  local grant='' oldest epoch seq previous='' marker="$DIR/queue-alert" queue=${FM_WAKE_QUEUE:-$DIR/.wake-queue}
  case "$VERDICT" in not-idle|busy|usage-limit|unreadable|unsupported-harness) return 0 ;; esac
  [ -f "$queue" ] || { rm -f "$marker"; return 0; }
  if fm_wake_branch_grant_live "$STATE/.branch-eligible-rows" "$STATE/.branch-eligible-owner"; then
    grant="$STATE/.branch-eligible-rows"
  fi
  oldest=$(awk -F '\t' -v grant="$grant" '
    BEGIN { if (grant != "") while ((getline line < grant) > 0) reserved[line] = 1 }
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && !($2 in reserved) {
      if (!found || $1 < epoch) { epoch=$1; seq=$2; found=1 }
    }
    END { if (found) print epoch " " seq }
  ' "$queue") || return 1
  [ -n "$oldest" ] || { rm -f "$marker"; return 0; }
  epoch=${oldest%% *}; seq=${oldest#* }
  [ "$epoch" -le "$NOW" ] || return 0
  [ "$((NOW-epoch))" -ge "$WAKE_AGE" ] || return 0
  if [ -f "$marker" ]; then read -r previous < "$marker" || true; fi
  previous=${previous%% *}
  [ "$previous" != "$epoch:$seq" ] || return 0
  local summary="Supervisor idle with undelivered wakes for $((NOW-epoch))s (oldest row $seq). Inspect and drain the main wake queue; no input was sent."
  fm_wake_append check supervisor-watchdog "$summary" || return 1
  printf '%s\n' "$epoch:$seq" > "$marker.tmp"
  mv "$marker.tmp" "$marker"
  watchdog_log alerted wake-queue-stalled
  wedge_alarm_notify "$summary" "$marker"
}
watchdog_send() { fm_backend_herdr_cli "$SESSION" pane send-text "$PANE_ID" "$1" >/dev/null; }
watchdog_enter() { fm_backend_herdr_cli "$SESSION" pane send-keys "$PANE_ID" enter >/dev/null; }
watchdog_confirm() {
  local payload=$1 attempt styled plain identity composer
  for ((attempt=0; attempt<10; attempt++)); do
    sleep 0.5
    styled=$(watchdog_read) || return 1
    plain=$(printf '%s\n' "$styled" | fm_composer_strip_ansi)
    identity=$(watchdog_identity) || return 1
    composer=$(fm_composer_classify_screen "$CAPS" "$styled" '' "$identity")
    # The empty composer alone is not proof of a new turn: require native
    # working or our exact prompt in the transcript above that empty composer.
    if [ "$composer" = empty ] && { [ "$identity" = $'claude\tworking' ] \
      || printf '%s\n' "$plain" | grep -Fq "❯ $payload"; }; then return 0; fi
  done
  return 1
}

watchdog_probe() {
  local code
  code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 10 --proto '=https' "$FM_WATCHDOG_PROBE_URL") || return 1
  case "$code" in 429|5??|000) return 1 ;; [1234][0-9][0-9]) return 0 ;; *) return 1 ;; esac
}

watchdog_tick() {
  local since acted next failures delay oldhash last_action clean content after payload held
  NOW=$(date +%s)
  RECORD='{"hash":"","since":0,"acted":false,"next":0,"failures":0,"last_action":0,"clean":0,"clean_hash":"","held":"","alerted":""}'
  if [ -e "$DIR/incident.json" ]; then
    RECORD=$(cat "$DIR/incident.json")
    printf '%s\n' "$RECORD" | jq -e '
      type == "object" and ([.hash,.clean_hash,.held,.alerted]|all(type=="string")) and (.acted|type=="boolean") and
      ([.since,.next,.failures,.last_action,.clean] | all(type=="number" and .>=0 and floor==.))' >/dev/null \
      || { watchdog_log refused corrupt-state; return 1; }
  fi
  watchdog_observe
  watchdog_queue_alert || return 1
  oldhash=$(printf '%s' "$RECORD" | jq -r .hash)
  acted=$(printf '%s' "$RECORD" | jq -r .acted)
  last_action=$(printf '%s' "$RECORD" | jq -r .last_action)
  held=$(printf '%s' "$RECORD" | jq -r .held)
  if [ "$VERDICT" = clear ]; then
    # Break pending observation continuity without releasing a claim or hold.
    # Healthy panes with no incident need no clean-window bookkeeping.
    if [ "$acted" = false ] && [ -z "$held" ]; then
      watchdog_update '.hash="" | .since=0'
      return
    fi
    clean=$(printf '%s' "$RECORD" | jq -r .clean)
    if [ "$clean" -eq 0 ] || [ "$HASH" != "$(printf '%s' "$RECORD" | jq -r .clean_hash)" ]; then
      watchdog_update --argjson now "$NOW" --arg hash "$HASH" '.clean=$now | .clean_hash=$hash'
      return
    fi
    if [ "$clean" -gt 0 ] && [ "$((NOW-clean))" -ge "$IDLE" ]; then
      watchdog_update '.hash="" | .since=0 | .acted=false | .next=0 | .failures=0 | .held="" | .alerted="" | .clean=0 | .clean_hash=""'
      [ -z "$oldhash" ] || watchdog_log rearmed
    fi
    return
  fi
  watchdog_update '.clean=0 | .clean_hash=""'
  if [ -n "$held" ]; then watchdog_alert; return; fi
  if [ "$VERDICT" != error ]; then
    # Unsafe observations break the continuous idle window, but never release
    # an action claim merely because a draft or an unreadable frame hid it.
    case "$VERDICT" in
      composer-*)
        if [ -n "$oldhash" ] || [ "${SCREEN_KIND:-}" = error ]; then
          watchdog_hold "$VERDICT"
        else
          watchdog_update '.since=0'
        fi
        ;;
      *) watchdog_update '.since=0'; watchdog_log deferred "$VERDICT" ;;
    esac
    return
  fi
  [ "$acted" = false ] || return 0
  since=$(printf '%s' "$RECORD" | jq -r .since)
  if [ -n "$oldhash" ] && [ "$HASH" != "$oldhash" ]; then
    watchdog_hold screen-changed
    return
  fi
  if [ "$since" -eq 0 ]; then
    watchdog_update --arg hash "$HASH" --argjson now "$NOW" '.hash=$hash | .since=$now'
    watchdog_log observed network-error
    return
  fi
  [ "$((NOW-since))" -ge "$IDLE" ] || return 0
  [ "$((NOW-last_action))" -ge "$BACKOFF" ] || return 0
  next=$(printf '%s' "$RECORD" | jq -r .next)
  [ "$NOW" -ge "$next" ] || return 0
  if ! watchdog_probe; then
    failures=$(printf '%s' "$RECORD" | jq -r .failures)
    [ "$failures" -ge 6 ] || failures=$((failures+1))
    delay=$((15 * (1 << failures)))
    [ "$delay" -le "$BACKOFF" ] || delay=$BACKOFF
    watchdog_update --argjson next "$((NOW+delay))" --argjson failures "$failures" '.next=$next | .failures=$failures'
    watchdog_log deferred network-unavailable
    return
  fi
  watchdog_observe
  [ "$VERDICT" = error ] && [ "$HASH" = "$oldhash" ] || { watchdog_hold changed-before-action; return; }
  # This is the guarded primary nudge path. Do not use the general submit
  # helper's clear/retry fallback: another writer's input must be preserved.
  watchdog_update --argjson now "$NOW" '.acted=true | .last_action=$now'
  watchdog_log action-claimed nudge
  payload='Resume the interrupted work.'
  watchdog_observe
  [ "$VERDICT" = error ] && [ "$HASH" = "$oldhash" ] || { watchdog_hold changed-after-claim; return; }
  watchdog_send "$payload" || { watchdog_hold send-failed; return; }
  sleep 0.2
  after=$(watchdog_read) || { watchdog_hold capture-failed; return; }
  case "$(watchdog_screen "$after")" in usage-limit|busy) watchdog_hold unsafe-before-submit; return ;; esac
  content=$(fm_composer_extract_selected_content "$CAPS" "$after") || { watchdog_hold composer-unreadable; return; }
  [ "$content" = "$payload" ] || { watchdog_hold input-changed; return; }
  watchdog_enter || { watchdog_hold enter-failed; return; }
  if watchdog_confirm "$payload"; then
    watchdog_log submitted nudge
  else
    watchdog_hold submit-not-confirmed
  fi
}

watchdog_main() {
  case "${1:-}" in
    -h|--help) sed -n '2,/^set -eu/{ /^#/s/^# \{0,1\}//p; }' "$0"; return ;;
    tick) ;;
    *) echo 'usage: fm-supervisor-watchdog.sh tick' >&2; return 2 ;;
  esac
  : "${FM_WATCHDOG_HOME:?explicit FM_HOME required}" "${FM_SUPERVISOR_TARGET:?exact supervisor target required}"
  : "${FM_WATCHDOG_CLAUDE_VERSION:?verified Claude version required}" "${FM_WATCHDOG_PROBE_URL:?provider probe URL required}"
  case "${FM_SUPERVISOR_BACKEND:-herdr}" in herdr) ;; *) echo 'watchdog: only Claude on Herdr is supported' >&2; return 2 ;; esac
  case "$FM_HOME" in /*) ;; *) echo 'watchdog: FM_HOME must be absolute' >&2; return 2 ;; esac
  case "$FM_WATCHDOG_PROBE_URL" in https://*) ;; *) echo 'watchdog: HTTPS probe required' >&2; return 2 ;; esac
  case "$FM_WATCHDOG_PROBE_URL" in *'@'*|*'?'*|*'#'*) echo 'watchdog: probe must not contain credentials/query/fragment' >&2; return 2 ;; esac
  TARGET=$FM_SUPERVISOR_TARGET
  SESSION=${TARGET%%:*}
  PANE_ID=${TARGET#*:}
  case "$TARGET" in *:*) ;; *) echo 'watchdog: explicit session:pane-id required' >&2; return 2 ;; esac
  [ -n "$SESSION" ] && [ -n "$PANE_ID" ] || return 2
  IDLE=${FM_WATCHDOG_IDLE_SECS:-120}
  BACKOFF=${FM_WATCHDOG_BACKOFF_SECS:-900}
  WAKE_AGE=${FM_WATCHDOG_WAKE_AGE_SECS:-600}
  for n in "$IDLE" "$BACKOFF" "$WAKE_AGE"; do
    case "$n" in ''|*[!0-9]*|0*) echo 'watchdog: positive integer intervals required' >&2; return 2 ;; esac
    [ "$n" -ge 10 ] && [ "$n" -le 86400 ] || { echo 'watchdog: intervals must be 10..86400 seconds' >&2; return 2; }
  done
  STATE="$FM_HOME/state"
  unset FM_STATE_OVERRIDE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  DIR="$STATE/supervisor-watchdog"
  umask 077
  mkdir -p "$DIR"
  NOW=$(date +%s)
  fm_lock_try_acquire "$DIR/lock" || return 0
  trap 'fm_lock_release "$DIR/lock"' EXIT
  if [ "$(claude --version 2>/dev/null)" != "$FM_WATCHDOG_CLAUDE_VERSION" ]; then
    watchdog_log refused claude-version-changed
    echo 'watchdog: Claude version changed; repeat live verification before updating the pin' >&2
    return 1
  fi
  fm_backend_source herdr
  watchdog_tick
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then watchdog_main "$@"; fi
