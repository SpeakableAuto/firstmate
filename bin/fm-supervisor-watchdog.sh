#!/usr/bin/env bash
# External, one-shot supervision watchdog for Claude on Herdr.
# Usage: FM_HOME=/absolute/home fm-supervisor-watchdog.sh tick
# Required environment (no endpoint discovery or default-session fallback):
#   FM_SUPERVISOR_TARGET       exact session:pane-id
#   FM_WATCHDOG_CLAUDE_VERSION installed Claude version approved by a live check
#   FM_WATCHDOG_PROBE_URL      HTTPS provider endpoint (no credentials/query)
# Optional: FM_WATCHDOG_IDLE_SECS=120, FM_WATCHDOG_BACKOFF_SECS=900,
# FM_WATCHDOG_WAKE_AGE_SECS=600, FM_WATCHDOG_STALL_SECS=1800,
# FM_WATCHDOG_STALL_RESTART=0 (nudge then urgent alert without stopping the
# supervisor), FM_WATCHDOG_RESTART_COMMAND=claude (the supervisor launch
# command, without its prompt), FM_WATCHDOG_RESTART_CWD=FM_HOME,
# FM_WATCHDOG_TRANSCRIPT_DIR (the supervisor's Claude transcript directory).
# Schedule tick with launchd StartInterval, independently of the supervisor.
# State/logs: FM_HOME/state/supervisor-watchdog/{incident.json,events.jsonl}.
# Version drift: when `claude --version` differs from the pin, one check wake
# and one active alert fire per newly seen version, and the tick continues in
# a degraded mode that types nothing into the supervisor: the network nudge,
# queue ring and stall nudge are withheld because they rely on
# version-specific screen parsing. The wake-age alert and stall timer keep
# running, and the second stall interval sends one urgent supervisor-down
# alert. An enabled restart remains held while the version is unverified. A
# matching version ends drift; repeat the live check before moving the pin.
# Stall: while the home needs supervision, progress is a newer watcher beacon
# while Claude is natively idle or done, a change of the oldest main-owned wake
# row (an acknowledgement), a newer transcript file, or a semantic pane change.
# Spinner rows, elapsed durations and token counters are ignored, while other
# numbers remain semantic progress. A visible usage-limit notice counts as
# progress because Claude resumes by itself and typing would cancel that. After
# STALL_SECS without progress the watchdog sends one guarded nudge. By default,
# another STALL_SECS without progress never stops the supervisor and sends one
# urgent alert that it needs restarting by hand. FM_WATCHDOG_STALL_RESTART=1
# opts into restart from the latest handoff only when a fresh verified frame
# proves the composer is empty. Otherwise it holds the restart and sends one
# urgent alert because unsent input may be in the box. A permitted restart
# stops only the target pane's foreground processes, relaunches RESTART_COMMAND
# there, and proves the new session started as a real Claude agent process. It
# records the restart before stopping Claude and retries one interrupted attempt.
# An unproven restart or no progress for STALL_SECS after a proven one sends one
# urgent supervisor-down alert through fm_urgent_alert.
# Progress of any kind rearms the timer.
# State: FM_HOME/state/supervisor-watchdog/{stall.json,version-alert}.
# A stable viewport with a terminal network error, native Claude idle/done,
# no busy footer, and a proven empty composer must survive two observations
# at least IDLE_SECS apart (minimum 10 seconds), with no semantic screen change.
# A clear frame resets the pending error window immediately.
# Claude's dim rotating empty-composer suggestion and the rotating hint row
# below the composer's closing rule are excluded from that check.
# Unknown state, drafts, usage-limit notices and version drift defer the nudge.
# A successful TLS HTTP response below 500 (except 429) proves reachability;
# failed probes use exponential backoff, capped at BACKOFF_SECS.
# Before typing, re-read every guard; before Enter, require exactly our payload.
# A narrow pane wraps the payload and the composer reader joins its rows with a
# space, so that comparison ignores whitespace only.
# Never clear input, retry Enter, kill an agent, or execute shell commands there.
# Claim the incident durably BEFORE the nudge; ambiguous delivery is not retried.
# A changed screen or draft holds the incident and queues a firstmate check.
# Held/acted incidents rearm after a stable, readable, error-free viewport for
# IDLE_SECS; the retained action timestamp enforces cross-incident backoff.
# Independently, a main-owned durable wake older than
# FM_WATCHDOG_WAKE_AGE_SECS while Claude is idle or done queues one check and
# fires the configured active-alert channels once for that unchanged oldest row.
# If the empty composer then stays semantically unchanged for IDLE_SECS, the
# watchdog rings the supervisor with one drain line under the same guards as
# the nudge, re-rings after both a new stable idle window and BACKOFF_SECS while
# that row stays undelivered, and holds an ambiguous ring until the oldest row
# changes or the queue drains.
# State: FM_HOME/state/supervisor-watchdog/{queue-alert,queue-nudge.json}.
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
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
WATCHDOG_STOP_POLLS=${WATCHDOG_STOP_POLLS:-15}
WATCHDOG_RESTART_POLLS=${WATCHDOG_RESTART_POLLS:-90}

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

# Drop the footer below the current composer's closing rule. Claude rotates
# transient hints there (update notices, the effort badge, paste hints), so it
# is not a semantic change; busy and usage-limit footers are read separately.
watchdog_above_footer() {
  awk '
    {rows[NR]=$0}
    /^[[:space:]]*[❯›>]/ {composer=NR}
    END {
      last=NR
      if (composer) for (i=composer+1; i<=NR; i++) if (rows[i] ~ /^[[:space:]]*[─━-]{3,}[[:space:]]*$/) { last=i; break }
      for (i=1; i<=last; i++) print rows[i]
    }'
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
  NATIVE_STATE=
  STYLED=$(watchdog_read) || { VERDICT=unreadable; return; }
  SCREEN=$(printf '%s\n' "$STYLED" | fm_composer_strip_ansi)
  [ -n "$SCREEN" ] || { VERDICT=unreadable; return; }
  identity=$(watchdog_identity) || { VERDICT=unreadable; return; }
  NATIVE_STATE=${identity#*$'\t'}
  case "$identity" in
    claude$'\t'idle|claude$'\t'done) ;;
    claude$'\t'*) VERDICT=not-idle; return ;;
    *) VERDICT=unsupported-harness; return ;;
  esac
  SCREEN_KIND=$(watchdog_screen "$SCREEN")
  VERDICT=$SCREEN_KIND
  case "$VERDICT" in usage-limit|busy) return ;; esac
  # An unverified Claude version may render its composer differently, so no
  # verdict that would authorize typing is derived from it.
  [ "${DRIFT:-0}" = 0 ] || { VERDICT=unverified; return; }
  composer=$(fm_composer_classify_screen "$CAPS" "$STYLED" '' "$identity")
  [ "$composer" = empty ] || { VERDICT="composer-${composer:-unknown}"; return; }
  semantic=$(printf '%s\n' "$STYLED" | fm_composer_strip_ghost | fm_composer_strip_ansi | watchdog_above_footer)
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

# Print "<epoch> <seq>" for the oldest main-owned durable wake row, excluding
# rows a live branch grant reserves; print nothing for an empty queue.
watchdog_oldest_row() {
  local grant='' queue=${FM_WAKE_QUEUE:-$DIR/.wake-queue}
  [ -f "$queue" ] || return 0
  if fm_wake_branch_grant_live "$STATE/.branch-eligible-rows" "$STATE/.branch-eligible-owner"; then
    grant="$STATE/.branch-eligible-rows"
  fi
  awk -F '\t' -v grant="$grant" '
    BEGIN { if (grant != "") while ((getline line < grant) > 0) reserved[line] = 1 }
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && !($2 in reserved) {
      if (!found || $1 < epoch) { epoch=$1; seq=$2; found=1 }
    }
    END { if (found) print epoch " " seq }
  ' "$queue"
}

# Alert on a main-owned row that has waited past the configured age while the
# native agent is idle or done. Alerting is a separate, once-per-row episode
# published through the existing check-wake route; delivery recovery for an
# idle supervisor is watchdog_queue_recover below.
watchdog_queue_alert() {
  local oldest epoch seq previous='' marker="$DIR/queue-alert"
  QUEUE_AGED=
  case "$VERDICT" in not-idle|busy|usage-limit|unreadable|unsupported-harness) return 0 ;; esac
  oldest=$(watchdog_oldest_row) || return 1
  [ -n "$oldest" ] || { rm -f "$marker"; return 0; }
  epoch=${oldest%% *}; seq=${oldest#* }
  [ "$epoch" -le "$NOW" ] || return 0
  [ "$((NOW-epoch))" -ge "$WAKE_AGE" ] || return 0
  QUEUE_AGED="$epoch:$seq"
  if [ -f "$marker" ]; then read -r previous < "$marker" || true; fi
  previous=${previous%% *}
  [ "$previous" != "$epoch:$seq" ] || return 0
  local summary="Supervisor idle with undelivered wakes for $((NOW-epoch))s (oldest row $seq). Inspect and drain the main wake queue; the watchdog rings the supervisor once it stays idle with an empty prompt."
  fm_wake_append check supervisor-watchdog "$summary" || return 1
  printf '%s\n' "$epoch:$seq" > "$marker.tmp"
  mv "$marker.tmp" "$marker"
  watchdog_log alerted wake-queue-stalled
  wedge_alarm_notify "$summary" "$marker"
}

# Deliver an aged queue to an idle supervisor that nothing else will wake: a
# turn that ended without the Stop hook leaves no watcher to deliver rows.
# The ring types one short drain line under the same guards as the network
# nudge: native idle or done, no busy footer or usage-limit notice, a proven
# empty composer (an unstyled Claude suggestion reads as pending) that
# stays semantically unchanged
# for IDLE_SECS, fresh checks before typing, and exactly our payload before
# Enter, with no clear or Enter retry. A confirmed ring re-rings after another
# stable idle window and BACKOFF_SECS while the same row stays undelivered; an
# ambiguous ring holds until the oldest row changes or the queue drains.
watchdog_queue_save() {
  printf '%s\n' "$QREC" > "$DIR/queue-nudge.json.tmp"
  mv "$DIR/queue-nudge.json.tmp" "$DIR/queue-nudge.json"
}
watchdog_queue_update() {
  local updated
  updated=$(printf '%s\n' "$QREC" | jq -c "$@")
  [ "$updated" != "$QREC" ] || return 0
  QREC=$updated
  watchdog_queue_save
}
watchdog_queue_hold() {
  watchdog_queue_update --arg reason "$1" '.held=$reason | .since=0'
  watchdog_log held "queue-$1"
  fm_wake_append check supervisor-watchdog \
    "Supervisor wake-queue ring withheld: $1. Inspect state/supervisor-watchdog/events.jsonl; input preserved, no automatic retry." || return 1
}
watchdog_queue_recover() {
  local payload after content
  QUEUE_ACTED=0
  QREC='{"row":"","hash":"","since":0,"last":0,"held":""}'
  if [ -e "$DIR/queue-nudge.json" ]; then
    QREC=$(cat "$DIR/queue-nudge.json")
    printf '%s\n' "$QREC" | jq -e '
      type == "object" and ([.row,.hash,.held]|all(type=="string")) and
      ([.since,.last] | all(type=="number" and .>=0 and floor==.))' >/dev/null \
      || { watchdog_log refused corrupt-queue-state; return 1; }
  fi
  if [ -z "$QUEUE_AGED" ]; then
    # A drained queue ends the episode; a busy or unsafe observation only
    # breaks the continuous idle window, keeping any hold and the re-ring time.
    if [ -z "$(watchdog_oldest_row)" ]; then
      rm -f "$DIR/queue-nudge.json"
    elif [ -e "$DIR/queue-nudge.json" ]; then
      watchdog_queue_update '.hash="" | .since=0'
    fi
    return 0
  fi
  if [ "$(printf '%s' "$QREC" | jq -r .row)" != "$QUEUE_AGED" ]; then
    watchdog_queue_update --arg row "$QUEUE_AGED" '.row=$row | .hash="" | .since=0 | .held=""'
  fi
  [ -z "$(printf '%s' "$QREC" | jq -r .held)" ] || return 0
  if [ "$VERDICT" != clear ]; then
    watchdog_queue_update '.hash="" | .since=0'
    return 0
  fi
  if [ "$(printf '%s' "$QREC" | jq -r .since)" -eq 0 ] || [ "$HASH" != "$(printf '%s' "$QREC" | jq -r .hash)" ]; then
    watchdog_queue_update --arg hash "$HASH" --argjson now "$NOW" '.hash=$hash | .since=$now'
    watchdog_log observed queue-idle
    return 0
  fi
  [ "$((NOW-$(printf '%s' "$QREC" | jq -r .since)))" -ge "$IDLE" ] || return 0
  [ "$((NOW-$(printf '%s' "$QREC" | jq -r .last)))" -ge "$BACKOFF" ] || return 0
  payload='Watchdog: undelivered wakes queued; run bin/fm-wake-drain.sh'
  # Nothing is typed yet, so a change here only restarts the idle window.
  watchdog_observe
  if [ "$VERDICT" != clear ] || [ "$HASH" != "$(printf '%s' "$QREC" | jq -r .hash)" ]; then
    watchdog_queue_update '.hash="" | .since=0'
    watchdog_log deferred queue-changed-before-action
    return 0
  fi
  QUEUE_ACTED=1
  watchdog_queue_update --argjson now "$NOW" '.last=$now | .since=0'
  watchdog_log action-claimed queue-nudge
  watchdog_send "$payload" || { watchdog_queue_hold send-failed; return; }
  sleep 0.2
  after=$(watchdog_read) || { watchdog_queue_hold capture-failed; return; }
  case "$(watchdog_screen "$after")" in usage-limit|busy) watchdog_queue_hold unsafe-before-submit; return ;; esac
  content=$(fm_composer_extract_selected_content "$CAPS" "$after") || { watchdog_queue_hold composer-unreadable; return; }
  watchdog_is_payload "$content" "$payload" || { watchdog_queue_hold input-changed; return; }
  watchdog_enter || { watchdog_queue_hold enter-failed; return; }
  if watchdog_confirm "$payload"; then
    watchdog_log submitted queue-nudge
  else
    watchdog_queue_hold submit-not-confirmed
  fi
}
# True when the composer holds exactly our payload, ignoring only whitespace a
# wrapped composer row adds or moves.
watchdog_is_payload() {
  [ "$(printf '%s' "$1" | tr -d '[:space:]')" = "$(printf '%s' "$2" | tr -d '[:space:]')" ]
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

# One check wake and one active alert per newly seen unverified version; the
# marker clears once the installed version matches the pin again.
watchdog_version_alert() {
  local marker="$DIR/version-alert" previous='' summary
  if [ "${DRIFT:-0}" = 0 ]; then rm -f "$marker"; return 0; fi
  if [ -f "$marker" ]; then
    read -r previous < "$marker" || true
    [ "$previous" != "v:$INSTALLED_VERSION" ] || return 0
  fi
  summary="Claude changed from '$FM_WATCHDOG_CLAUDE_VERSION' to '${INSTALLED_VERSION:-unknown}'. The supervisor watchdog keeps its wake-age alert and stall timer, but types nothing into the supervisor. After the second stall interval it sends an urgent supervisor-down alert, and an enabled restart remains held until the live check is repeated and FM_WATCHDOG_CLAUDE_VERSION is updated."
  fm_wake_append check supervisor-watchdog "$summary" || return 1
  printf 'v:%s\n' "$INSTALLED_VERSION" > "$marker.tmp"
  mv "$marker.tmp" "$marker"
  watchdog_log drift "claude-version-changed:${INSTALLED_VERSION:-unknown}"
  wedge_alarm_notify "$summary" "$marker"
}

# Whether the home has work under way; fm-supervision-lib.sh owns that
# condition set, the same one the turn-end guard uses.
watchdog_under_way() {
  fm_supervision_status "$STATE"
  [ "$FM_SUP_NEEDED" = true ]
}

# Semantic pane fingerprint for stall progress, read from the latest
# observation: dim and unstyled Claude suggestions, ANSI styling, spinner rows,
# elapsed durations and token counters are dropped while other numbers remain semantic progress.
watchdog_progress_hash() {
  case "${VERDICT:-}" in unreadable|unsupported-harness|'') printf 'unreadable'; return ;; esac
  printf '%s\n' "$STYLED" | fm_composer_strip_ghost | fm_composer_strip_ansi | watchdog_above_footer \
    | LC_ALL=C sed -E 's/^([[:space:]]*❯([[:space:]]| )*)Try "[^"]+"([[:space:]]| )*$/❯/' \
    | LC_ALL=C awk '!/^[[:space:]]*(✻|✽|✢|✳|✶|✺|·|\*)/' \
    | LC_ALL=C sed -E 's/[0-9]+(h|m|s)([[:space:]]+[0-9]+(h|m|s))*/#/g; s/[0-9]+([.][0-9]+)?[kKmM]?[[:space:]]+tokens/# tokens/g; s/[[:space:]]+/ /g' \
    | shasum -a 256 | awk '{print $1}'
}

watchdog_transcript_baseline() {
  local dir=${FM_WATCHDOG_TRANSCRIPT_DIR:-}
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  touch "$DIR/transcript-mark"
}

# True when any supervisor transcript file is newer than the last tick's mark.
watchdog_transcript_moved() {
  local dir=${FM_WATCHDOG_TRANSCRIPT_DIR:-} mark="$DIR/transcript-mark" newer
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  if [ ! -e "$mark" ]; then watchdog_transcript_baseline; return 1; fi
  newer=$(find "$dir" -maxdepth 3 -type f -name '*.jsonl' -newer "$mark" -print 2>/dev/null | head -1)
  [ -n "$newer" ] || return 1
  watchdog_transcript_baseline
}

watchdog_stall_save() {
  printf '%s\n' "$SREC" > "$DIR/stall.json.tmp"
  mv "$DIR/stall.json.tmp" "$DIR/stall.json"
}
watchdog_stall_update() {
  local updated
  updated=$(printf '%s\n' "$SREC" | jq -c "$@")
  [ "$updated" != "$SREC" ] || return 0
  SREC=$updated
  watchdog_stall_save
}

# One guarded line into an idle supervisor, under the network nudge's guards:
# native idle or done, an empty composer re-read just before typing, exactly
# our payload before Enter, and a confirmed new turn. Sets FAIL_REASON on
# failure (no subshell, so observation state survives); nothing is cleared or
# retried.
watchdog_submit() {  # <payload>
  local payload=$1 before=$HASH after content
  watchdog_observe
  [ "$VERDICT" = clear ] && [ "$HASH" = "$before" ] || { FAIL_REASON='changed-before-action'; return 1; }
  watchdog_send "$payload" || { FAIL_REASON='send-failed'; return 1; }
  sleep 0.2
  after=$(watchdog_read) || { FAIL_REASON='capture-failed'; return 1; }
  case "$(watchdog_screen "$after")" in usage-limit|busy) FAIL_REASON='unsafe-before-submit'; return 1 ;; esac
  content=$(fm_composer_extract_selected_content "$CAPS" "$after") || { FAIL_REASON='composer-unreadable'; return 1; }
  watchdog_is_payload "$content" "$payload" || { FAIL_REASON='input-changed'; return 1; }
  watchdog_enter || { FAIL_REASON='enter-failed'; return 1; }
  watchdog_confirm "$payload" || { FAIL_REASON='submit-not-confirmed'; return 1; }
}

watchdog_stall_nudge() {
  local payload reason
  payload="Watchdog: no supervision progress for $((STALL_SECS / 60)) minutes; run bin/fm-wake-drain.sh and resume supervising."
  if [ "${DRIFT:-0}" = 1 ] || [ "$VERDICT" != clear ]; then
    watchdog_log withheld "stall-nudge-$VERDICT"
    return 0
  fi
  STALL_ACTED=1
  watchdog_log action-claimed stall-nudge
  if watchdog_submit "$payload"; then
    watchdog_log submitted stall-nudge
  else
    reason=$FAIL_REASON
    watchdog_log held "stall-nudge-$reason"
    fm_wake_append check supervisor-watchdog \
      "Supervisor stall nudge withheld: $reason. Input preserved; the watchdog restarts the supervisor if it still makes no progress." || true
  fi
}

# Stop only the target pane's foreground processes (never its shell, never
# another pane): TERM, then KILL, until Herdr reports a bare shell.
watchdog_stop_supervisor() {
  local info shell_pid pids attempt
  info=$(fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE_ID") || return 1
  shell_pid=$(printf '%s' "$info" | jq -er --arg pane "$PANE_ID" '
    .result.process_info | select(.pane_id == $pane) | .shell_pid | select(type == "number" and . > 1) | floor') || return 1
  pids=$(printf '%s' "$info" | jq -r --argjson shell "$shell_pid" '
    .result.process_info.foreground_processes[]?.pid | select(type == "number" and . > 1 and . != $shell) | floor')
  [ -n "$pids" ] || [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" != shell ] || return 0
  [ -n "$pids" ] || return 1
  # shellcheck disable=SC2086 # Word-split the numeric pid list.
  kill -TERM $pids 2>/dev/null || true
  for ((attempt=0; attempt<WATCHDOG_STOP_POLLS; attempt++)); do
    [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" != shell ] || return 0
    sleep 1
  done
  # shellcheck disable=SC2086 # Word-split the numeric pid list.
  kill -KILL $pids 2>/dev/null || true
  for ((attempt=0; attempt<5; attempt++)); do
    [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" != shell ] || return 0
    sleep 1
  done
  return 1
}

watchdog_restart_prompt() {
  local handoff
  handoff=$(find "${FM_DATA_OVERRIDE:-$FM_HOME/data}" -maxdepth 1 -type f -name 'supervisor-handoff-*.md' -print 2>/dev/null \
    | while IFS= read -r f; do printf '%s\t%s\n' "$(fm_sup_stat_mtime "$f")" "$f"; done | sort -rn | head -1 | cut -f2-)
  printf 'Watchdog restart: the previous supervisor session made no progress for %s minutes and was stopped. ' "$((2 * STALL_SECS / 60))"
  printf 'Run session start if its digest is not shown, '
  [ -z "$handoff" ] || printf 'read %s for the latest handoff, ' "$handoff"
  printf 'then resume supervising every live task. Workers were not touched.'
}

watchdog_restart_composer() {
  local styled identity composer
  [ "${DRIFT:-0}" = 0 ] || { printf 'unverified'; return; }
  styled=$(watchdog_read) || { printf 'unreadable'; return; }
  identity=$(watchdog_identity) || { printf 'unreadable'; return; }
  case "$identity" in claude$'\t'*) ;; *) printf 'unsupported-harness'; return ;; esac
  composer=$(fm_composer_classify_screen "$CAPS" "$styled" '' "$identity") || composer=unknown
  printf '%s' "${composer:-unknown}"
}

watchdog_restart_proven() {
  local state identity
  state=$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")
  [ "$state" = agent ] || return 1
  identity=$(watchdog_identity 2>/dev/null) || return 1
  case "$identity" in claude$'\t'*) return 0 ;; *) return 1 ;; esac
}

# Relaunch the supervisor in its own pane and prove a new Claude session
# started there. Sets FAIL_REASON on failure.
watchdog_restart() {
  local cmd attempt composer
  composer=$(watchdog_restart_composer)
  [ "$composer" = empty ] || { FAIL_REASON="held:$composer"; return 1; }
  watchdog_stop_supervisor || { FAIL_REASON='stop-failed'; return 1; }
  printf -v cmd 'cd %q && %s %q' "$RESTART_CWD" "$RESTART_COMMAND" "$(watchdog_restart_prompt)"
  fm_backend_herdr_cli "$SESSION" pane run "$PANE_ID" "$cmd" >/dev/null || { FAIL_REASON='launch-failed'; return 1; }
  for ((attempt=0; attempt<WATCHDOG_RESTART_POLLS; attempt++)); do
    sleep 1
    watchdog_restart_proven && return 0
  done
  FAIL_REASON=not-proven
  return 1
}

watchdog_restart_baseline() {
  local beacon oldest
  beacon=$(fm_sup_stat_mtime "$STATE/.last-watcher-beat") || beacon=
  oldest=$(watchdog_oldest_row) || oldest=
  watchdog_transcript_baseline || true
  watchdog_stall_update --arg b "$beacon" --arg o "$oldest" --argjson now "$NOW" \
    '.beacon=$b | .oldest=$o | .pane="unreadable" | .progress=$now
    | .stage="restarted" | .stage_at=$now | .restart_tries=0'
}

watchdog_restart_attempt() {
  local reason
  if watchdog_restart; then
    watchdog_log restarted supervisor
    watchdog_restart_baseline
    return 0
  fi
  reason=$FAIL_REASON
  case "$reason" in
    held:*)
      watchdog_log held "stall-restart-${reason#held:}"
      watchdog_enter_down "restart held because unsent input may be in the box"
      ;;
    *)
      watchdog_log held "restart-$reason"
      watchdog_enter_down "a restart attempt failed ($reason)"
      ;;
  esac
}

watchdog_supervisor_down() {
  local why message result
  why=$(printf '%s' "$SREC" | jq -r .down_reason)
  message="Firstmate needs you: the supervisor on $(hostname -s 2>/dev/null || printf 'this machine') stalled; $why. Workers keep running, but nothing is being reviewed or merged until it is restarted by hand."
  FM_URGENT_ALERT_RESULT=
  fm_urgent_alert supervisor-down "$PANE_ID-$(printf '%s' "$SREC" | jq -r .progress)" "$message" >/dev/null || true
  result=${FM_URGENT_ALERT_RESULT:-}
  case "$result" in sent|skipped:duplicate) watchdog_stall_update '.alerted=true' ;; esac
}

watchdog_enter_down() {
  local why=$1 queue_wake=${2:-1}
  watchdog_stall_update --argjson now "$NOW" --arg why "$why" \
    '.stage="down" | .stage_at=$now | .down_reason=$why | .alerted=false'
  watchdog_log alerted "supervisor-down"
  if [ "$queue_wake" = 1 ]; then
    fm_wake_append check supervisor-watchdog "Supervisor down: $why. Urgent alert attempted." || true
  fi
  wedge_alarm_notify "Supervisor down: $why" "$DIR/stall.json"
  watchdog_supervisor_down
}

watchdog_reconcile_restart() {
  local tries
  STALL_ACTED=1
  if watchdog_restart_proven; then
    watchdog_log restarted supervisor
    watchdog_restart_baseline
    return 0
  fi
  tries=$(printf '%s' "$SREC" | jq -r .restart_tries)
  if [ "$tries" -ge 2 ]; then
    watchdog_log held restart-retry-exhausted
    watchdog_enter_down "an interrupted restart could not be proven after one retry"
    return 0
  fi
  watchdog_log action-claimed restart-retry
  watchdog_stall_update --argjson now "$NOW" \
    '.stage_at=$now | .restart_tries += 1'
  watchdog_restart_attempt
}

# Stall detection and recovery; see the header for the progress contract.
watchdog_stall() {
  local beacon oldest pane progressed=0 stage stage_at quiet prev
  STALL_ACTED=0
  if ! watchdog_under_way; then rm -f "$DIR/stall.json"; return 0; fi
  beacon=$(fm_sup_stat_mtime "$STATE/.last-watcher-beat") || beacon=
  oldest=$(watchdog_oldest_row) || return 1
  pane=$(watchdog_progress_hash)
  if [ ! -e "$DIR/stall.json" ]; then
    SREC=$(jq -cn --arg b "$beacon" --arg o "$oldest" --arg p "$pane" --argjson now "$NOW" \
      '{beacon:$b,oldest:$o,pane:$p,progress:$now,stage:"watching",stage_at:$now,restart_tries:0,down_reason:"",alerted:false}')
    watchdog_stall_save
    watchdog_transcript_moved || true
    return 0
  fi
  SREC=$(cat "$DIR/stall.json")
  if ! printf '%s\n' "$SREC" | jq -e '
    type == "object" and ([.beacon,.oldest,.pane,.stage]|all(type=="string")) and
    (.stage as $stage | ["watching","nudged","restarting","restarted","down","held"] | index($stage) != null) and
    ([.progress,.stage_at] | all(type=="number" and .>=0 and floor==.)) and
    ((.restart_tries // 0) | type=="number" and .>=0 and floor==.) and
    ((.down_reason // "") | type=="string") and ((.alerted // false) | type=="boolean")' >/dev/null 2>&1; then
    # Keep the evidence and start a fresh timer rather than refusing every tick.
    mv "$DIR/stall.json" "$DIR/stall.json.corrupt"
    watchdog_log refused corrupt-stall-state
    return 0
  fi
  watchdog_stall_update '
    .restart_tries //= 0 | .down_reason //= "" | .alerted //= false
    | if .stage == "down" and .down_reason == "" then .down_reason="automatic recovery did not bring it back" else . end'
  stage=$(printf '%s' "$SREC" | jq -r .stage)
  if [ "$stage" = restarting ]; then
    watchdog_reconcile_restart
    return 0
  fi
  prev=$(printf '%s' "$SREC" | jq -r .beacon)
  case "${NATIVE_STATE:-}" in
    idle|done) [ "$VERDICT" = busy ] || [ -z "$beacon" ] || [ "$beacon" = "$prev" ] || progressed=1 ;;
  esac
  prev=$(printf '%s' "$SREC" | jq -r .oldest)
  [ -z "$prev" ] || [ "$oldest" = "$prev" ] || progressed=1
  prev=$(printf '%s' "$SREC" | jq -r .pane)
  if [ "$pane" != unreadable ]; then
    [ "$prev" = unreadable ] || [ "$pane" = "$prev" ] || progressed=1
  fi
  ! watchdog_transcript_moved || progressed=1
  [ "$VERDICT" != usage-limit ] || progressed=1
  watchdog_stall_update --arg b "$beacon" --arg o "$oldest" --arg p "$pane" '.beacon=$b | .oldest=$o | .pane=$p'
  if [ "$progressed" = 1 ]; then
    [ "$stage" = watching ] || watchdog_log rearmed "stall-$stage"
    watchdog_stall_update --argjson now "$NOW" \
      '.progress=$now | .stage="watching" | .stage_at=$now | .restart_tries=0 | .down_reason="" | .alerted=false'
    return 0
  fi
  stage_at=$(printf '%s' "$SREC" | jq -r .stage_at)
  quiet=$((NOW - $(printf '%s' "$SREC" | jq -r .progress)))
  case "$stage" in
    watching)
      [ "$quiet" -ge "$STALL_SECS" ] || return 0
      watchdog_log observed "stall-${quiet}s"
      watchdog_stall_update --argjson now "$NOW" '.stage="nudged" | .stage_at=$now'
      watchdog_stall_nudge
      ;;
    nudged)
      [ "$((NOW - stage_at))" -ge "$STALL_SECS" ] || return 0
      STALL_ACTED=1
      if [ "$STALL_RESTART" = 0 ]; then
        watchdog_log action-claimed supervisor-down
        watchdog_enter_down "it stopped making progress and did not recover after a nudge, so it needs restarting by hand" 0
        return 0
      fi
      watchdog_log action-claimed restart
      watchdog_stall_update --argjson now "$NOW" \
        '.stage="restarting" | .stage_at=$now | .restart_tries=1'
      watchdog_restart_attempt
      ;;
    restarted)
      [ "$((NOW - stage_at))" -ge "$STALL_SECS" ] || return 0
      watchdog_enter_down "it still made no progress $((STALL_SECS / 60)) minutes after an automatic restart"
      ;;
    down)
      [ "$(printf '%s' "$SREC" | jq -r .alerted)" = true ] || watchdog_supervisor_down
      ;;
    *) return 0 ;;
  esac
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
  watchdog_version_alert || true
  watchdog_queue_alert || return 1
  watchdog_queue_recover || return 1
  [ "$QUEUE_ACTED" -eq 0 ] || return 0
  watchdog_stall || return 1
  [ "$STALL_ACTED" -eq 0 ] || return 0
  # The network nudge reads the composer, which an unverified version may
  # render differently.
  [ "${DRIFT:-0}" = 0 ] || return 0
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
  watchdog_is_payload "$content" "$payload" || { watchdog_hold input-changed; return; }
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
  STALL_SECS=${FM_WATCHDOG_STALL_SECS:-1800}
  STALL_RESTART=${FM_WATCHDOG_STALL_RESTART-0}
  case "$STALL_RESTART" in 0|1) ;; *) echo 'watchdog: FM_WATCHDOG_STALL_RESTART must be 0 or 1' >&2; return 2 ;; esac
  RESTART_COMMAND=${FM_WATCHDOG_RESTART_COMMAND:-claude}
  RESTART_CWD=${FM_WATCHDOG_RESTART_CWD:-$FM_HOME}
  case "$RESTART_CWD" in /*) ;; *) echo 'watchdog: FM_WATCHDOG_RESTART_CWD must be absolute' >&2; return 2 ;; esac
  for n in "$IDLE" "$BACKOFF" "$WAKE_AGE" "$STALL_SECS"; do
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
  # Drift is a degraded mode, not a refusal: see watchdog_version_alert.
  INSTALLED_VERSION=$(claude --version 2>/dev/null) || INSTALLED_VERSION=
  DRIFT=0
  [ "$INSTALLED_VERSION" = "$FM_WATCHDOG_CLAUDE_VERSION" ] || DRIFT=1
  fm_backend_source herdr
  watchdog_tick
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then watchdog_main "$@"; fi
