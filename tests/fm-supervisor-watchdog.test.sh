#!/usr/bin/env bash
# Pane fixtures exercise the public classifier/tick API with a recording transport.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-supervisor-watchdog.sh
. "$ROOT/bin/fm-supervisor-watchdog.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DIR=$TMP
IDLE=10
BACKOFF=60
ERROR=$'❯ continue\n⎿ API Error: ENOTFOUND\n────────────────────\n❯ \n────────────────────'
CLEAR=$'● Healthy response\n────────────────────\n❯ \n────────────────────'
date() { if [ "${1:-}" = +%s ]; then printf '%s\n' "$TICK"; else command date "$@"; fi; }
sleep() { :; }
watchdog_read() { [ "$READ_FAIL" = 0 ] || return 1; printf '%s\n' "$PANE"; }
watchdog_identity() { [ "$IDENTITY_FAIL" = 0 ] || return 1; printf '%s\n' "$IDENTITY"; }
curl() { printf '%s\n' probe >> "$DIR/probes"; printf '%s' "$HTTP_CODE"; return "$CURL_RC"; }
fm_wake_append() { printf '%s\n' "$*" >> "$DIR/alerts"; }
fm_wake_branch_grant_live() { return 1; }
wedge_alarm_notify() { printf '%s\n' "$1" >> "$DIR/notifications"; }
# Stall detection is off unless a case puts work under way.
watchdog_under_way() { [ "${UNDER_WAY:-0}" = 1 ]; }
watchdog_send() {
  SENT=$((SENT+1))
  [ "$SEND_FAIL" = 0 ] || return 1
  PANE="API Error: ENOTFOUND"$'\n❯ '"$1"
  [ "$CHANGE_DURING_SEND" = 0 ] || PANE="$PANE human draft"
  [ "$LIMIT_DURING_SEND" = 0 ] || PANE="$PANE"$'\nUsage limit reached · continuing automatically'
  [ "$READ_FAIL_AFTER_SEND" = 0 ] || READ_FAIL=1
}
watchdog_enter() {
  ENTERED=$((ENTERED+1))
  [ "$ENTER_FAIL" = 0 ] || return 1
  [ "$STALL" = 0 ] || return 0
  if [ "$CONFIRM_NATIVE" = 1 ]; then IDENTITY=$'claude\tworking'; PANE=$'❯ '; return; fi
  PANE=$'❯ Resume the interrupted work.\n● Resumed\n────────────────────\n❯ \n────────────────────'
}
check() { [ "$1" = "$2" ] || fail "$3 (got $1, expected $2)"; pass "$3"; }
reset_case() {
  rm -f "$DIR/incident.json" "$DIR/events.jsonl" "$DIR/alerts" "$DIR/probes" "$DIR/notifications"
  TICK=1000; IDENTITY=$'claude\tidle'; PANE=$ERROR
  SENT=0; ENTERED=0; HTTP_CODE=200; CURL_RC=0
  CONFIRM_NATIVE=0
  READ_FAIL=0; IDENTITY_FAIL=0; SEND_FAIL=0; ENTER_FAIL=0; STALL=0
  CHANGE_DURING_SEND=0; LIMIT_DURING_SEND=0; READ_FAIL_AFTER_SEND=0
  FM_WATCHDOG_STALL_RESTART=0; STALL_RESTART=0
  FM_WATCHDOG_PROBE_URL=https://provider.example/
}
arm() { watchdog_tick; TICK=1011; }
held() { jq -r .held "$DIR/incident.json"; }
reset_case
check "$(watchdog_screen "$ERROR")" error 'terminal ENOTFOUND detected'
check "$(watchdog_screen "${ERROR/ENOTFOUND/ECONNRESET}")" error 'independent connection failure detected'
check "$(watchdog_screen $'Unable to connect to API\n❯ ')" error 'connection banner detected without API Error prefix'
check "$(watchdog_screen $'API Error: ENOTFOUND\n● Work completed\n❯ ')" clear 'historic error followed by output ignored'
check "$(watchdog_screen $'❯ continue\n⏺ API Error: Connection refused — a firewall or proxy may be blocking it (ECONNREFUSED)\n\n✻ Brewed for 0s · done 6:33 AM\n\n● high · /effort\n────────\n❯ \n────────')" error 'real Claude effort row does not hide terminal network error'
check "$(watchdog_screen "$ERROR"$'\nUsage limit reached · continuing automatically')" usage-limit 'automatic usage-limit continuation vetoes recovery'
check "$(watchdog_screen $'API Error: 401 unauthorized\n❯ ')" clear 'auth failure is not network recovery'
check "$(watchdog_screen "$ERROR"$'\nesc to interrupt')" busy 'rendered busy footer overrides native idle'
watchdog_tick
check "$SENT" 0 'first observation never acts'
TICK=1009; watchdog_tick
check "$SENT" 0 'less than ten seconds cannot authorize input'
TICK=1011; HTTP_CODE=503; watchdog_tick
check "$SENT" 0 'provider failure blocks action'
TICK=1012; HTTP_CODE=200; watchdog_tick
check "$(wc -l < "$DIR/probes" | tr -d ' ')" 1 'probe backoff persists across ticks'
TICK=1042; watchdog_tick
check "$SENT" 1 'unchanged idle error nudged once after connectivity returns'
check "$ENTERED" 1 'exact watchdog payload submitted once'
check "$(tail -1 "$DIR/events.jsonl" | jq -r .event)" submitted 'new turn in transcript confirms submission'
PANE=$ERROR; TICK=1200; watchdog_tick
check "$SENT" 1 'same incident never replays'
PANE=$CLEAR; TICK=1201; watchdog_tick
PANE=$ERROR; TICK=1202; watchdog_tick
check "$SENT" 1 'transient clear frame does not release incident claim'
# A single clear frame breaks an unclaimed error's continuous idle window.
reset_case
watchdog_tick
PANE=$CLEAR; TICK=1005; watchdog_tick
PANE="${ERROR/ENOTFOUND/ECONNRESET}"; TICK=1011; watchdog_tick
check "$SENT" 0 'different error cannot reuse time before a clear frame'
check "$(jq -r .since "$DIR/incident.json")" 1011 'different error starts a fresh observation window'
check "$(held)" '' 'different error after clear is a new incident'
TICK=1020; watchdog_tick
check "$SENT" 0 'different error waits the entire new idle interval'
TICK=1021; watchdog_tick
check "$SENT" 1 'different stable error recovers after a full fresh interval'
# Old transcript text must not impersonate the live footer or spinner.
for historical in '● The footer says esc to interrupt' '✻ Thinking… (12s · old turn)'; do
  reset_case
  PANE="$historical"$'\n'"$ERROR"
  check "$(watchdog_screen "$PANE")" error 'historical busy text does not veto terminal network error'
  arm; watchdog_tick
  check "$SENT" 1 'idle network error recovers despite historical busy text'
done
reset_case
PANE=$'❯ continue\n⎿ API Error: ENOTFOUND\n✻ Thinking… (12s · live turn)\n────────────────────\n❯ \n────────────────────'
check "$(watchdog_screen "$PANE")" busy 'current spinner above composer still vetoes recovery'
arm; watchdog_tick
check "$SENT" 0 'current spinner never receives a nudge'
reset_case
PANE="$ERROR"$'\nesc to interrupt'
arm; watchdog_tick
check "$SENT" 0 'current footer never receives a nudge'
reset_case
PANE=$'❯ continue\n⎿ API Error: ENOTFOUND\n────────────────────\n❯ \033[2mTry "write a test"\033[0m\n────────────────────'
watchdog_tick
TICK=1011
PANE=$'❯ continue\n⎿ API Error: ENOTFOUND\n────────────────────\n❯ \033[2mTry "explain this code"\033[0m\n────────────────────'
watchdog_tick
check "$SENT" 1 'rotating empty-composer suggestion does not break error stability'
reset_case
BACKOFF=900
arm
watchdog_tick
check "$SENT" 1 'first incident nudged before cross-incident backoff starts'
PANE=$CLEAR; TICK=1100; watchdog_tick
TICK=1111; watchdog_tick
PANE=$ERROR; TICK=1200; watchdog_tick
TICK=1910; watchdog_tick
check "$SENT" 1 'new incident remains throttled until action backoff elapses'
TICK=1911; watchdog_tick
check "$SENT" 2 'stable recovery rearms before backoff for a later incident'
BACKOFF=60
reset_case; arm
PANE="$ERROR extra output"; watchdog_tick
check "$SENT" 0 'screen change blocks nudge'
check "$(held)" screen-changed 'screen change holds incident'
check "$(wc -l < "$DIR/alerts" | tr -d ' ')" 1 'screen change alerts firstmate'
watchdog_tick
check "$(wc -l < "$DIR/alerts" | tr -d ' ')" 1 'same hold does not flood wake queue'
reset_case; arm
PANE=$'API Error: ENOTFOUND\n❯ draft'; watchdog_tick
check "$SENT" 0 'existing draft never receives watchdog input'
check "$(held)" composer-pending 'draft holds incident'
PANE=$ERROR; TICK=1300; watchdog_tick
check "$SENT" 0 'removing draft does not silently release hold'
reset_case; arm; IDENTITY=$'claude\tworking'; watchdog_tick
check "$SENT" 0 'working native status vetoes stale error'
reset_case; arm; IDENTITY=$'codex\tidle'; watchdog_tick
check "$SENT" 0 'unsupported harness refused'
reset_case; arm; PANE="$ERROR"$'\nUsage limit reached · continuing automatically'; watchdog_tick
check "$SENT" 0 'usage notice receives no input'
reset_case; arm; READ_FAIL=1; watchdog_tick
check "$SENT" 0 'unreadable pane receives no input'
reset_case; arm; IDENTITY_FAIL=1; watchdog_tick
check "$SENT" 0 'unreadable native state receives no input'
reset_case; arm; CONFIRM_NATIVE=1; watchdog_tick
check "$(tail -1 "$DIR/events.jsonl" | jq -r .event)" submitted 'native working plus empty composer confirms new turn'
reset_case; PANE=$'Healthy response\n❯ human draft'; watchdog_tick
[ ! -e "$DIR/alerts" ] || fail 'ordinary healthy drafting must not alert'
pass 'healthy drafting does not create a recovery alert'
reset_case; arm; CHANGE_DURING_SEND=1; watchdog_tick
check "$ENTERED" 0 'mixed input never submitted or cleared'
check "$(held)" input-changed 'mixed input alerts firstmate'
check "$(jq -r .acted "$DIR/incident.json")" true 'ambiguous attempt consumes incident'
reset_case; arm; LIMIT_DURING_SEND=1; watchdog_tick
check "$ENTERED" 0 'usage notice before Enter blocks submission'
reset_case; arm; SEND_FAIL=1; watchdog_tick
check "$(held)" send-failed 'transport send failure alerts without retry'
reset_case; arm; ENTER_FAIL=1; watchdog_tick
check "$(held)" enter-failed 'Enter failure alerts without retry'
check "$ENTERED" 1 'Enter attempted only once'
reset_case; arm; READ_FAIL_AFTER_SEND=1; watchdog_tick
check "$ENTERED" 0 'capture failure after typing withholds Enter'
reset_case; arm; STALL=1; watchdog_tick
check "$(held)" submit-not-confirmed 'missing new turn alerts instead of claiming success'
reset_case
for HTTP_CODE in 000 429 500 503; do
  if watchdog_probe; then fail "HTTP $HTTP_CODE must defer"; fi
done
for HTTP_CODE in 200 301 401 404; do watchdog_probe || fail "HTTP $HTTP_CODE must prove transport"; done
CURL_RC=7
if watchdog_probe; then fail 'connection failure must defer'; fi
pass 'provider probe distinguishes transport response, throttling, outage, and connection failure'
# No active incident means healthy observations have nothing to persist.
reset_case
PANE=$CLEAR
watchdog_tick; TICK=1011; watchdog_tick; TICK=1022; watchdog_tick
PANE=$'Healthy response\n❯ human draft'; watchdog_tick
[ ! -e "$DIR/incident.json" ] || fail 'healthy observations wrote empty state'
pass 'healthy clear panes and drafts do not create redundant state files'
reset_case; arm; watchdog_tick
PANE=$CLEAR; TICK=1100; watchdog_tick; TICK=1111; watchdog_tick
check "$(jq -r .clean "$DIR/incident.json")" 0 'rearming clears completed clean window'
# A hard link detects atomic replacement portably without timestamp sleeps.
ln "$DIR/incident.json" "$DIR/rearmed-snapshot"
TICK=1122; watchdog_tick; TICK=1133; watchdog_tick
PANE=$'Healthy response\n❯ human draft'; watchdog_tick
[ "$DIR/incident.json" -ef "$DIR/rearmed-snapshot" ] || fail 'unchanged state was rewritten'
pass 'healthy ticks after rearming preserve the existing state file'
rm "$DIR/rearmed-snapshot"
# Re-read the real transport observation after the network check.
reset_case; arm
curl() { PANE=ignored; printf '200'; }
# curl runs in a subshell, so use a file-backed hook at the observation boundary.
watchdog_probe() { PANE=$'API Error: ENOTFOUND\n❯ draft'; return 0; }
watchdog_tick
check "$SENT" 0 'draft appearing during network check blocks typing'
check "$(held)" changed-before-action 'last-window change alerts firstmate'
reset_case
printf '{bad\n' > "$DIR/incident.json"
if watchdog_tick 2>/dev/null; then fail 'corrupt incident must refuse'; fi
pass 'corrupt state fails closed'
# Public executable refuses unsafe configuration before touching any endpoint.
for interval in 0 9 010 garbage 86401; do
  if FM_HOME="$TMP" FM_SUPERVISOR_TARGET=lab:w1:p1 FM_WATCHDOG_IDLE_SECS="$interval" \
    FM_WATCHDOG_CLAUDE_VERSION=unused FM_WATCHDOG_PROBE_URL=https://provider.example/ \
    bash "$ROOT/bin/fm-supervisor-watchdog.sh" tick >/dev/null 2>&1; then fail "unsafe interval $interval accepted"; fi
done
pass 'executable enforces minimum ten-second observation interval'
for restart in '' -1 2 01 yes; do
  if FM_HOME="$TMP" FM_SUPERVISOR_TARGET=lab:w1:p1 FM_WATCHDOG_STALL_RESTART="$restart" \
    FM_WATCHDOG_CLAUDE_VERSION=unused FM_WATCHDOG_PROBE_URL=https://provider.example/ \
    bash "$ROOT/bin/fm-supervisor-watchdog.sh" tick >/dev/null 2>&1; then fail "unsafe restart setting '$restart' accepted"; fi
done
pass 'executable rejects invalid restart settings'

# An aged durable wake is an alert-only condition, independent of network
# recovery. A dim suggestion is empty input; a real draft stays untouched.
reset_case
STATE=$TMP
FM_WAKE_QUEUE="$DIR/.wake-queue"
WAKE_AGE=600
printf '399\t27\tcheck\tmail\tpending\n' > "$FM_WAKE_QUEUE"
PANE=$'● Healthy response\n────────────────────\n❯ \033[2mapproved item 27, deploy it now\033[0m\n────────────────────'
watchdog_tick
check "$VERDICT" clear 'dim suggestion leaves the Claude composer empty'
check "$(wc -l < "$DIR/alerts" | tr -d ' ')" 1 'idle supervisor alerts on aged wake'
check "$(wc -l < "$DIR/notifications" | tr -d ' ')" 1 'aged wake reaches active alert channel'
check "$SENT" 0 'first aged-queue observation never types into the supervisor'
TICK=1010; PANE=$'● Healthy response\n❯ human draft'; watchdog_tick
check "$VERDICT" composer-pending 'real typed draft remains pending'
check "$(wc -l < "$DIR/alerts" | tr -d ' ')" 1 'same queued row is rate limited'
check "$(wc -l < "$DIR/notifications" | tr -d ' ')" 1 'active alert is rate limited too'
check "$SENT" 0 'real typed draft is not touched'
TICK=1900; watchdog_tick
check "$(wc -l < "$DIR/alerts" | tr -d ' ')" 1 'unchanged oldest row alerts only once'
check "$(wc -l < "$DIR/notifications" | tr -d ' ')" 1 'unchanged oldest row does not repeat active alerts'
printf '400\t28\tcheck\tmail\tpending next\n' > "$FM_WAKE_QUEUE"
watchdog_tick
check "$(wc -l < "$DIR/alerts" | tr -d ' ')" 2 'a changed oldest row starts a new alert episode'
check "$(wc -l < "$DIR/notifications" | tr -d ' ')" 2 'a changed oldest row reaches active alerts'
TICK=1901; IDENTITY=$'claude\tworking'; watchdog_tick
check "$(wc -l < "$DIR/alerts" | tr -d ' ')" 2 'working supervisor is exempt from queue alarm'
TICK=1902; IDENTITY=$'claude\tidle'; PANE=$'Usage limit reached · continuing automatically\n❯ '; watchdog_tick
check "$(wc -l < "$DIR/alerts" | tr -d ' ')" 2 'usage-limit guard remains active'
rm "$FM_WAKE_QUEUE"
PANE=$CLEAR; watchdog_tick
[ ! -e "$DIR/queue-alert" ] || fail 'drained queue did not reset alert episode'
pass 'queue alarm resets after drain'

# An aged queue on an idle or done supervisor with an empty prompt is rung:
# nothing else wakes a supervisor whose turn ended without the Stop hook.
queue_case() {
  reset_case
  rm -f "$DIR/queue-alert" "$DIR/queue-nudge.json"
  printf '300\t31\tcheck\tmail\tpending\n' > "$FM_WAKE_QUEUE"
  IDENTITY=$'claude\tdone'
  CONFIRM_NATIVE=1
  PANE=$'● Done\n────────────────────\n❯ \033[2myes, give firstmate read-only access\033[0m\n────────────────────'
}
watchdog_send() {
  SENT=$((SENT+1))
  [ "$SEND_FAIL" = 0 ] || return 1
  PANE=$'● Done\n────────────────────\n❯ '"$1"
  [ "$CHANGE_DURING_SEND" = 0 ] || PANE="$PANE human draft"
  [ "$LIMIT_DURING_SEND" = 0 ] || PANE="$PANE"$'\nUsage limit reached · continuing automatically'
  [ "$READ_FAIL_AFTER_SEND" = 0 ] || READ_FAIL=1
}
queue_case
watchdog_tick
check "$VERDICT" clear 'done supervisor with a dim suggestion is an empty idle prompt'
check "$(wc -l < "$DIR/alerts" | tr -d ' ')" 1 'done supervisor alerts on aged wake'
check "$SENT" 0 'first idle observation never rings'
TICK=1011
PANE=$'● Done\n────────────────────\n❯ \033[2mrun the next wave\033[0m\n────────────────────'
watchdog_tick
check "$SENT" 1 'stable idle done supervisor is rung once for the aged queue'
check "$ENTERED" 1 'queue ring submitted exactly once'
check "$(tail -1 "$DIR/events.jsonl" | jq -c '[.event,.detail]')" '["submitted","queue-nudge"]' 'queue ring confirms the new turn'
IDENTITY=$'claude\tdone'
PANE=$'● Done\n────────────────────\n❯ \033[2mrun the next wave\033[0m\n────────────────────'
TICK=1050; watchdog_tick
TICK=1065; watchdog_tick
check "$SENT" 1 'undelivered queue is not re-rung before the backoff'
TICK=1080; watchdog_tick
check "$SENT" 2 'still undelivered queue is re-rung after the backoff'
rm "$FM_WAKE_QUEUE"
TICK=1090; watchdog_tick
[ ! -e "$DIR/queue-nudge.json" ] || fail 'drained queue kept its ring episode'
pass 'drained queue ends the ring episode'

queue_case
IDENTITY=$'claude\tidle'
watchdog_tick; TICK=1011; watchdog_tick
check "$SENT" 1 'idle supervisor is rung for the aged queue too'

queue_case
watchdog_tick
TICK=1011; PANE=$'● Done\n❯ human draft'; watchdog_tick
TICK=1030; watchdog_tick
check "$SENT" 0 'queue ring never types over a draft'

queue_case
watchdog_tick
TICK=1011; PANE=$'Usage limit reached · continuing automatically\n❯ '; watchdog_tick
TICK=1030; watchdog_tick
check "$SENT" 0 'queue ring never acts during a usage-limit pause'

queue_case
watchdog_tick
TICK=1011; PANE=$'● Done\n✻ Thinking… (2s · live turn)\n❯ \nesc to interrupt'; watchdog_tick
TICK=1030; watchdog_tick
check "$SENT" 0 'queue ring never interrupts a busy supervisor'

queue_case
watchdog_tick
TICK=1011; CHANGE_DURING_SEND=1; watchdog_tick
check "$ENTERED" 0 'mixed input after the ring is never submitted'
check "$(jq -r .held "$DIR/queue-nudge.json")" input-changed 'mixed input holds the queue ring'
CHANGE_DURING_SEND=0
PANE=$'● Done\n────────────────────\n❯ \033[2mrun the next wave\033[0m\n────────────────────'
TICK=1200; watchdog_tick; TICK=1300; watchdog_tick
check "$SENT" 1 'held queue ring is not retried for the same row'
printf '301\t32\tcheck\tmail\tlater\n' > "$FM_WAKE_QUEUE"
TICK=1400; watchdog_tick; TICK=1411; watchdog_tick
check "$SENT" 2 'a changed oldest row releases the held ring'

# A change seen in the final read before typing restarts the idle window
# without typing or holding, so a later stable idle prompt is still rung.
queue_case
watchdog_tick
TICK=1011
real_watchdog_observe=$(declare -f watchdog_observe)
OBSERVED=0
eval "${real_watchdog_observe/watchdog_observe/real_observe}"
watchdog_observe() {
  OBSERVED=$((OBSERVED+1))
  [ "$OBSERVED" -lt 2 ] || PANE=$'● Done\n● New output arrived\n────────────────────\n❯ \n────────────────────'
  real_observe
}
watchdog_tick
check "$SENT" 0 'a change in the final pre-typing read never types'
check "$(jq -r .held "$DIR/queue-nudge.json")" '' 'a pre-typing change does not hold the ring'
OBSERVED=0
eval "${real_watchdog_observe}"
TICK=1030; watchdog_tick
TICK=1041; watchdog_tick
check "$SENT" 1 'the next stable idle window rings normally'

# A narrow pane wraps the ring across composer rows; the reader joins them with
# a space, which must not read as foreign input.
queue_case
watchdog_send() {
  SENT=$((SENT+1))
  PANE=$'● Done\n────────────────────\n❯ '"${1:0:20}"$'\n'"${1:20}"
}
watchdog_tick; TICK=1011; watchdog_tick
check "$ENTERED" 1 'a ring wrapped across composer rows is still submitted'
check "$(tail -1 "$DIR/events.jsonl" | jq -c '[.event,.detail]')" '["submitted","queue-nudge"]' 'wrapped ring confirms the new turn'
queue_case
watchdog_send() {
  SENT=$((SENT+1))
  PANE=$'● Done\n────────────────────\n❯ '"${1:0:20}"$'\n'"${1:20}x"
}
watchdog_tick; TICK=1011; watchdog_tick
check "$ENTERED" 0 'wrapped ring with one extra character is never submitted'

# Claude's footer row below the prompt's closing rule rotates hints (seen live
# on 2.1.295); a rotating hint is not a semantic change of a stable error.
reset_case
rm -f "$FM_WAKE_QUEUE" "$DIR/queue-alert" "$DIR/queue-nudge.json"
watchdog_send() { SENT=$((SENT+1)); PANE="API Error: ENOTFOUND"$'\n❯ '"$1"; }
watchdog_probe() { return 0; }
PANE="$ERROR"$'\n  ⏵⏵ bypass permissions on · ← for agents   Update available! Run: brew upgrade claude-code@latest'
watchdog_tick
TICK=1011
PANE="$ERROR"$'\n  ⏵⏵ bypass permissions on · ← for agents\n                                   ● high · /effort'
watchdog_tick
check "$SENT" 1 'rotating footer hint does not break a stable network error'

# Version drift alerts once per newly seen version and never types, while
# the aged-wake alert keeps working.
drift_case() {
  reset_case
  rm -f "$DIR/version-alert" "$DIR/queue-alert" "$DIR/queue-nudge.json" "$FM_WAKE_QUEUE"
  DRIFT=1 INSTALLED_VERSION='2.1.312 (Claude Code)' FM_WATCHDOG_CLAUDE_VERSION='2.1.295 (Claude Code)'
}
drift_case
watchdog_tick; TICK=1011; watchdog_tick; TICK=1500; watchdog_tick
check "$SENT" 0 'drift never types the network nudge'
check "$(grep -c "to '2.1.312" "$DIR/alerts")" 1 'drift raises one check wake for the new version'
check "$(grep -c "to '2.1.312" "$DIR/notifications")" 1 'drift raises one active alert for the new version'
grep -q 'an enabled restart remains held' "$DIR/alerts" || fail 'drift alert still promised automatic restart'
pass 'drift alert explains the optional restart hold'
check "$(jq -r 'select(.event=="refused") | .detail' "$DIR/events.jsonl" | wc -l | tr -d ' ')" 0 'drift is not a refusal'
check "$(jq -r 'select(.event=="drift") | .detail' "$DIR/events.jsonl")" 'claude-version-changed:2.1.312 (Claude Code)' 'drift is logged once'
INSTALLED_VERSION='2.1.320 (Claude Code)'; TICK=1600; watchdog_tick
check "$(grep -c "to '2.1.320" "$DIR/alerts")" 1 'a further version change alerts again'
printf '300\t31\tcheck\tmail\tpending\n' > "$FM_WAKE_QUEUE"
IDENTITY=$'claude\tdone'; PANE=$CLEAR; TICK=1700; watchdog_tick; TICK=1711; watchdog_tick
check "$(grep -c 'undelivered wakes' "$DIR/alerts")" 1 'aged-wake alert still fires during drift'
check "$SENT" 0 'queue ring is withheld during drift'
rm -f "$FM_WAKE_QUEUE"
DRIFT=0; TICK=1800; watchdog_tick
[ ! -e "$DIR/version-alert" ] || fail 'matching version kept the drift marker'
pass 'a matching version ends drift'
DRIFT=0

# Stall detection: nudge, urgent default, opt-in restart, and progress rearming.
STALL_SECS=1800
RESTART_COMMAND='claude --model opus'
RESTART_CWD=/fm/home
SESSION=lab
PANE_ID=w1:p1
WATCHDOG_RESTART_POLLS=2
FM_HOME=$TMP/fmhome
mkdir -p "$FM_HOME/data"
printf 'old\n' > "$FM_HOME/data/supervisor-handoff-1029.md"
printf 'new\n' > "$FM_HOME/data/supervisor-handoff-1030.md"
touch -t 202610290000 "$FM_HOME/data/supervisor-handoff-1029.md"
fm_sup_stat_mtime() { case "$1" in *.last-watcher-beat) printf '%s' "$BEACON" ;; *) command stat -f %m "$1" ;; esac; }
real_fm_urgent_alert=$(declare -f fm_urgent_alert)
fm_urgent_alert() {
  printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$DIR/urgent"
  FM_URGENT_ALERT_RESULT=${URGENT_RESULT:-sent}
  case "$FM_URGENT_ALERT_RESULT" in failed:*) return 1 ;; esac
}
fm_backend_herdr_pane_process_state() { printf '%s' "$PROC_STATE"; }
watchdog_stop_supervisor() { STOPPED=$((STOPPED+1)); [ "$STOP_OK" = 1 ]; }
fm_backend_herdr_cli() {
  case "$2 $3" in
    'pane run') printf '%s\n' "$5" >> "$DIR/launches"; [ "$LAUNCH_OK" = 1 ] || return 1
      if [ "$RESTART_WRITES_TRANSCRIPT" = 1 ]; then
        printf '{"restart":true}\n' > "$FM_WATCHDOG_TRANSCRIPT_DIR/restart.jsonl"
      fi
      PROC_STATE=$AFTER_LAUNCH_STATE ;;
    *) return 1 ;;
  esac
}
watchdog_send() {
  SENT=$((SENT+1)); LAST_SENT=$1
  PANE=$'● Done\n────────────────────\n❯ '"$1"
}
stall_case() {
  reset_case
  rm -f "$DIR/stall.json" "$DIR/typed" "$DIR/transcript-mark" "$DIR/urgent" "$DIR/launches" "$FM_WAKE_QUEUE" "$DIR/queue-alert" "$DIR/queue-nudge.json"
  UNDER_WAY=1 BEACON=500 PANE=$CLEAR CONFIRM_NATIVE=1 STOPPED=0 STOP_OK=1 LAUNCH_OK=1
  PROC_STATE=agent AFTER_LAUNCH_STATE=agent LAST_SENT='' URGENT_RESULT=sent
  FM_WATCHDOG_TRANSCRIPT_DIR='' RESTART_WRITES_TRANSCRIPT=0
}
restart_case() { stall_case; FM_WATCHDOG_STALL_RESTART=1; STALL_RESTART=1; }
stage() { jq -r .stage "$DIR/stall.json"; }
HUNG=$'❯ run it\n✻ Thinking… (12s · esc to interrupt)\n────────────────────\n❯ \n────────────────────'
hung_case() { stall_case; PANE=$HUNG; IDENTITY=$'claude\tworking'; }
restart_hung_case() { hung_case; FM_WATCHDOG_STALL_RESTART=1; STALL_RESTART=1; }
stall_case
watchdog_tick
check "$(stage)" watching 'stall timer starts while work is under way'
TICK=2799; watchdog_tick
check "$SENT" 0 'no nudge before thirty quiet minutes'
TICK=2800; watchdog_tick
check "$SENT" 1 'thirty quiet minutes send one stall nudge'
case "$LAST_SENT" in 'Watchdog: no supervision progress for 30 minutes; run bin/fm-wake-drain.sh'*) pass 'stall nudge names the drain' ;; *) fail "unexpected stall payload: $LAST_SENT" ;; esac
check "$(stage)" nudged 'nudge moves the stall to its restart window'
# The screen left by the watchdog's own nudge is not progress; an idle
# watcher beacon after it is.
IDENTITY=$'claude\tidle'; PANE=$'● Draining now\n────────────────────\n❯ \n────────────────────'; TICK=2815; watchdog_tick
check "$(stage)" nudged 'the screen left by the nudged turn is not progress'
BEACON=501; TICK=2830; watchdog_tick
check "$(stage)" watching 'an idle watcher beacon after the nudge rearms the timer'
PANE=$'● Later output\n────────────────────\n❯ \n────────────────────'; TICK=2845; watchdog_tick
check "$(stage)" watching 'screen progress counts again once real progress cleared the nudge'

# A supervisor whose every turn fails (an expired login) prints a new error
# row and returns to idle after each nudge; that is not progress.
# Only typing starts a turn here, so the screen moves only after the watchdog types.
failing_turn() {
  [ "$SENT" -gt "$ANSWERED" ] || return 0
  ANSWERED=$SENT; FAILS=$((FAILS + 1)); IDENTITY=$'claude\tidle'
  PANE=$'❯ Watchdog: no supervision progress\n⎿ API Error: 401 unauthorized (attempt '"$FAILS"$')\n────────────────────\n❯ \n────────────────────'
  [ -z "$FM_WATCHDOG_TRANSCRIPT_DIR" ] || printf '{"n":%s}\n' "$FAILS" > "$FM_WATCHDOG_TRANSCRIPT_DIR/turn.jsonl"
}
stall_case; FAILS=0 ANSWERED=0
FM_WATCHDOG_TRANSCRIPT_DIR=$TMP/failing-transcripts
rm -rf "$FM_WATCHDOG_TRANSCRIPT_DIR"; mkdir -p "$FM_WATCHDOG_TRANSCRIPT_DIR"
watchdog_tick
for t in $(seq 1300 300 44200); do
  failing_turn; TICK=$t; watchdog_tick
done
check "$SENT" 1 'a supervisor failing every turn is nudged once, not every half hour'
check "$(stage)" down 'a supervisor failing every turn reaches the down stage'
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'a supervisor failing every turn sends one urgent alert'
check "$(jq -r 'select(.event=="alerted") | .at' "$DIR/events.jsonl" | head -1)" 4600 'the failing-loop alert fires one stall interval after the nudge'

# The aged-queue ring is also the watchdog's own typing: a ring answered by
# a failing turn cannot keep resetting the stall timer.
stall_case; FAILS=0 ANSWERED=0
printf '300\t31\tcheck\tmail\tpending\n' > "$FM_WAKE_QUEUE"
watchdog_tick
for t in $(seq 1300 300 8200); do
  failing_turn; TICK=$t; watchdog_tick
  TICK=$((t + 15)); watchdog_tick
done
[ "$SENT" -ge 2 ] || fail "the queue ring case never rang (sent $SENT)"
pass 'the stuck queue is rung while the supervisor fails'
check "$(stage)" down 'rings answered by failing turns reach the down stage'
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'rings answered by failing turns send one urgent alert'
rm -f "$FM_WAKE_QUEUE"

hung_case
PANE=$'❯ run it\n● Processed 1/100 records\n────────────────────\n❯ \n────────────────────'
watchdog_tick
TICK=2700
PANE=$'❯ run it\n● Processed 2/100 records\n────────────────────\n❯ \n────────────────────'
watchdog_tick
TICK=2800; watchdog_tick
check "$(stage)" watching 'changing business counters are semantic progress'

hung_case
PANE=$'❯ run it\n● Working for 12s · 3.2k tokens\n────────────────────\n❯ \n────────────────────'
watchdog_tick
TICK=1900; PANE=$'❯ run it\n● Working for 3m 12s · 3.3k tokens\n────────────────────\n❯ \n────────────────────'; watchdog_tick
TICK=2400; PANE=$'❯ run it\n● Working for 1h 2m · 4k tokens\n────────────────────\n❯ \n────────────────────'; watchdog_tick
TICK=2800; watchdog_tick
check "$(stage)" nudged 'elapsed durations and token counters do not fake progress'

stall_case
PANE=$'❯ run it\n✻ Thinking… (12s · esc to interrupt)\n────────────────────\n❯ \n────────────────────'
IDENTITY=$'claude\tworking'; watchdog_tick
for t in 1900 2400 2799; do
  BEACON=$((BEACON + 1))
  PANE=$'❯ run it\n✻ Pondering… ('"$((t-988))"$'s · esc to interrupt)\n────────────────────\n❯ \n────────────────────'
  TICK=$t; watchdog_tick
done
check "$(stage)" watching 'a live watcher beacon does not reset a hung working turn'
TICK=2800; watchdog_tick
check "$SENT" 0 'a busy supervisor never receives the stall nudge'
check "$(stage)" nudged 'a ticking spinner is not progress'
check "$(jq -r 'select(.event=="withheld") | .detail' "$DIR/events.jsonl")" stall-nudge-not-idle 'withheld nudge is logged'
TICK=4599; watchdog_tick
check "$STOPPED" 0 'no restart before the second window'
TICK=4600; watchdog_tick
check "$STOPPED" 0 'the default stall policy never stops the supervisor'
check "$(stage)" down 'the default stall policy marks an unrecovered supervisor down'
[ ! -e "$DIR/launches" ] || fail 'the default stall policy launched a replacement supervisor'
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'the default stall policy sends one urgent alert'
grep -q 'stopped making progress and did not recover after a nudge, so it needs restarting by hand' "$DIR/urgent" \
  || fail 'default stall alert did not explain the manual restart'
pass 'default stall alert explains the manual recovery in plain words'
TICK=4601; watchdog_tick
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'a delivered default stall alert is not repeated'
PANE=$'❯ run it\n● Recovered after the alert\n────────────────────\n❯ \n────────────────────'; TICK=4602; watchdog_tick
check "$(stage)" watching 'real progress after a default stall alert rearms monitoring'

stall_case
PANE=$HUNG
IDENTITY=$'claude\tidle'
watchdog_tick
for t in 1900 2400 2800; do
  BEACON=$((BEACON + 1))
  TICK=$t; watchdog_tick
done
check "$(stage)" nudged 'an idle native state cannot hide a busy rendered stall'
BEACON=$((BEACON + 1)); TICK=4600; watchdog_tick
check "$STOPPED" 0 'a busy rendered stall is not stopped by the default policy'
check "$(stage)" down 'a busy rendered stall reaches the down stage despite fresh beacons'
[ ! -e "$DIR/launches" ] || fail 'a busy rendered stall launched a replacement supervisor'
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'a busy rendered stall sends one urgent alert'

stall_case
IDENTITY=$'claude\tidle'
PANE=$'● Done\n────────────────────\n❯\302\240Try "review this?"\n────────────────────'
watchdog_tick
check "$VERDICT" composer-pending 'an unstyled Try hint remains unsafe for typing'
for hint in 'explain this code' 'write a test' 'review the changes'; do
  PANE=$'● Done\n────────────────────\n❯\302\240Try "'"$hint"$'"\n────────────────────'
  TICK=$((TICK + 600)); watchdog_tick
done
check "$(stage)" nudged 'rotating unstyled Try hints do not hide a stall'
PANE=$'● Done\n────────────────────\n❯\302\240Try "summarize the work"\n────────────────────'
TICK=4600; watchdog_tick
check "$STOPPED" 0 'rotating unstyled Try hints never trigger a default restart'
check "$(stage)" down 'rotating unstyled Try hints reach the down stage'
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'rotating unstyled Try hints send one urgent alert'

real_fm_wake_append=$(declare -f fm_wake_append)
stall_case
PANE=$HUNG
IDENTITY=$'claude\tworking'
DRIFT=1 INSTALLED_VERSION='2.1.312 (Claude Code)' FM_WATCHDOG_CLAUDE_VERSION='2.1.295 (Claude Code)'
WAKE_ATTEMPTS=0
fm_wake_append() { WAKE_ATTEMPTS=$((WAKE_ATTEMPTS + 1)); return 1; }
watchdog_tick; TICK=2800; watchdog_tick; TICK=4600; watchdog_tick
check "$WAKE_ATTEMPTS" 3 'a failed drift wake is retried on every tick'
check "$STOPPED" 0 'failed drift wakes do not enable a restart'
check "$(stage)" down 'failed drift wakes do not block stall protection'
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'failed drift wakes still reach the urgent stall alert'
eval "$real_fm_wake_append"
DRIFT=0

stall_case
IDENTITY=$'claude\tidle'
DRIFT=1 INSTALLED_VERSION='2.1.312 (Claude Code)' FM_WATCHDOG_CLAUDE_VERSION='2.1.295 (Claude Code)'
for t in 1000 1900 2800 3700 4600; do
  PANE=$'❯ run it\n⠋ Unrecognized activity frame '"$t"$'\n────────────────────\n❯ \n────────────────────'
  TICK=$t; watchdog_tick
done
check "$SENT" 0 'rotating unverified pane content is never typed into'
check "$(stage)" down 'rotating unverified pane content cannot hide a drift stall'
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'a drift stall with rotating pane content sends one urgent alert'

stall_case
IDENTITY=$'claude\tidle'
DRIFT=1 INSTALLED_VERSION='2.1.312 (Claude Code)' FM_WATCHDOG_CLAUDE_VERSION='2.1.295 (Claude Code)'
watchdog_tick
for t in 2800 4600 6400; do
  BEACON=$((BEACON + 1))
  TICK=$t; watchdog_tick
done
check "$(stage)" watching 'an idle moving beacon remains progress during drift'
[ ! -e "$DIR/urgent" ] || fail 'a healthy idle drift beacon alerted the captain'
pass 'a healthy idle drift beacon does not alert'
DRIFT=0

hung_case; URGENT_RESULT=failed:delivery-failed
watchdog_tick; TICK=2800; watchdog_tick; TICK=4600; watchdog_tick
check "$(jq -r .alerted "$DIR/stall.json")" false 'failed default urgent delivery leaves the incident open'
URGENT_RESULT=sent; TICK=4601; watchdog_tick
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 2 'the default down incident retries urgent delivery on a later tick'
check "$(jq -r .alerted "$DIR/stall.json")" true 'successful default retry closes the alert episode'

# The real limiter: a supervisor-down alert whose first send times out is
# not delivered, so the incident stays open and retries two hours later.
cat > "$TMP/urgent-sender" <<'SENDER'
#!/usr/bin/env bash
dir=$(dirname "$0")
n=$(( $(cat "$dir/urgent-calls" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$dir/urgent-calls"
cat > /dev/null
case "$(cat "$dir/urgent-mode")" in
  hang-first) [ "$n" -gt 1 ] || exec /bin/sleep 30 ;;
  hang) exec /bin/sleep 30 ;;
esac
printf '{"success": true, "message_id": "%s"}\n' "$((500 + n))"
SENDER
chmod +x "$TMP/urgent-sender"
stub_fm_urgent_alert=$(declare -f fm_urgent_alert)
eval "$real_fm_urgent_alert"
real_urgent_case() {
  hung_case
  rm -rf "$FM_HOME/state/urgent-alert" "$TMP/urgent-calls"
  printf '%s\n' "$1" > "$TMP/urgent-mode"
}
# The runner counts whole seconds, so a short bound leaves room for a healthy reply.
export FM_URGENT_ALERT_EXEC="$TMP/urgent-sender" FM_URGENT_ALERT_TIMEOUT_SECS=3
real_urgent_case hang-first
for t in $(seq 1000 600 94600); do TICK=$t; watchdog_tick; done
check "$(cat "$TMP/urgent-calls")" 2 'a timed-out supervisor-down alert is retried once Hermes recovers'
check "$(jq -r .alerted "$DIR/stall.json")" true 'the retried alert closes the incident only after delivery'
check "$(jq -r 'select(.result=="sent") | .at' "$FM_HOME/state/urgent-alert/sent.jsonl")" 11800 'the retry lands two hours after the timed-out send'
real_urgent_case hang
for t in $(seq 1000 600 94600); do TICK=$t; watchdog_tick; done
check "$(jq -s '[.[] | select(.result=="unconfirmed") | .at] | . as $a | [$a[] as $t | [$a[] | select(. >= $t and . < $t + 86400)] | length] | max' "$FM_HOME/state/urgent-alert/sent.jsonl")" 12 'a sender that keeps timing out stays within twelve tries a day'
check "$(jq -r 'select(.result=="unconfirmed") | .at' "$FM_HOME/state/urgent-alert/sent.jsonl" | head -3 | tr '\n' ' ')" '4600 11800 19000 ' 'timed-out alerts retry two hours apart'
check "$(jq -r .alerted "$DIR/stall.json")" false 'an alert never confirmed never reads as delivered'
check "$(stage)" down 'an unconfirmed alert keeps the incident down'
unset FM_URGENT_ALERT_EXEC FM_URGENT_ALERT_TIMEOUT_SECS
eval "$stub_fm_urgent_alert"

restart_hung_case
watchdog_tick; TICK=2800; watchdog_tick; TICK=4600; watchdog_tick
check "$STOPPED" 1 'working supervisor with an empty composer restarts after the second window'
check "$(stage)" restarted 'restart is recorded'
launch=$(cat "$DIR/launches")
case "$launch" in "cd /fm/home && claude --model opus Watchdog\\ restart"*) pass 'restart relaunches the configured command in the home' ;; *) fail "unexpected launch: $launch" ;; esac
case "$launch" in *supervisor-handoff-1030.md*) pass 'restart prompt names the newest handoff' ;; *) fail "restart prompt lacks newest handoff: $launch" ;; esac
check "$(tail -1 "$DIR/events.jsonl" | jq -c '[.event,.detail]')" '["restarted","supervisor"]' 'proven restart is logged'
[ ! -e "$DIR/urgent" ] || fail 'a proven first restart must not reach the captain'
pass 'a proven restart is not an urgent alert'
TICK=6399; watchdog_tick
TICK=6400; watchdog_tick
check "$(stage)" down 'no progress after the restart marks the supervisor down'
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'supervisor down sends one urgent alert'
check "$(cut -d'|' -f1 "$DIR/urgent")" supervisor-down 'urgent alert uses the supervisor-down condition'
grep -q 'after an automatic restart' "$DIR/urgent" || fail 'urgent alert is not plain'
pass 'urgent alert says what happened in plain words'
TICK=9000; watchdog_tick; TICK=20000; watchdog_tick
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'down supervisor is not re-alerted every tick'
BEACON=501; TICK=20001; watchdog_tick
check "$(stage)" down 'a working supervisor cannot claim progress from the watcher beacon'
IDENTITY=$'claude\tidle'; PANE=$CLEAR; BEACON=502; TICK=20002; watchdog_tick
check "$(stage)" watching 'an idle supervisor can rearm from a fresh watcher beacon'

restart_hung_case
PANE=$'❯ run it\n✻ Thinking… (12s · esc to interrupt)\n────────────────────\n❯ typed follow-up\n────────────────────'
watchdog_tick; TICK=2800; watchdog_tick; TICK=4600; watchdog_tick
check "$STOPPED" 0 'a working supervisor with typed input is never stopped'
check "$(stage)" down 'typed input holds the restart as a down incident'
grep -q 'restart held because unsent input may be in the box' "$DIR/urgent" || fail 'typed-input hold did not send the urgent alert'
pass 'working typed input uses the urgent held-restart path'

restart_hung_case
watchdog_tick; TICK=2800; watchdog_tick
READ_FAIL=1; TICK=4600; watchdog_tick
check "$STOPPED" 0 'an unreadable supervisor is never stopped'
check "$(stage)" down 'an unreadable frame holds the restart as a down incident'
grep -q 'restart held because unsent input may be in the box' "$DIR/urgent" || fail 'unreadable-frame hold did not send the urgent alert'
pass 'unreadable frame uses the urgent held-restart path'

# Unproven restarts alert at once; a draft is never destroyed.
restart_hung_case; AFTER_LAUNCH_STATE=shell; URGENT_RESULT=failed:delivery-failed
watchdog_tick; TICK=2800; watchdog_tick; TICK=4600; watchdog_tick
check "$(stage)" down 'unproven restart marks the supervisor down'
grep -q 'restart attempt failed (not-proven)' "$DIR/urgent" || fail 'unproven restart did not alert'
check "$(jq -r .alerted "$DIR/stall.json")" false 'failed urgent delivery leaves the incident open'
URGENT_RESULT=skipped:retry-backoff; TICK=4601; watchdog_tick
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 2 'an open incident retries through the limiter'
URGENT_RESULT=sent; TICK=5501; watchdog_tick
check "$(jq -r .alerted "$DIR/stall.json")" true 'later delivery closes the incident alert'
TICK=5502; watchdog_tick
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 3 'a delivered incident stops retrying'
restart_hung_case; AFTER_LAUNCH_STATE=other
watchdog_tick; TICK=2800; watchdog_tick; TICK=4600; watchdog_tick
check "$(stage)" down 'a non-agent process cannot prove the restarted supervisor'
grep -q 'restart attempt failed (not-proven)' "$DIR/urgent" || fail 'non-agent restart did not alert'
pass 'restart proof requires a real Claude agent process'
restart_hung_case; STOP_OK=0
watchdog_tick; TICK=2800; watchdog_tick; TICK=4600; watchdog_tick
[ ! -e "$DIR/launches" ] || fail 'a supervisor that cannot be stopped was relaunched over'
pass 'a supervisor that cannot be stopped is not relaunched over'
grep -q 'stop-failed' "$DIR/urgent" || fail 'failed stop did not alert'
pass 'failed stop sends the urgent alert'
restart_case; PANE=$'● Done\n❯ half-typed answer'
watchdog_tick; TICK=2800; watchdog_tick; TICK=4600; watchdog_tick
check "$STOPPED" 0 'a draft in the prompt holds the restart'
check "$(stage)" down 'a verified draft is recorded as a down incident'
grep -q 'restart held because unsent input may be in the box' "$DIR/urgent" || fail 'verified draft hold did not send the urgent alert'
pass 'a verified draft uses the urgent held-restart path'

restart_hung_case
FM_WATCHDOG_TRANSCRIPT_DIR=$TMP/restart-transcripts
mkdir -p "$FM_WATCHDOG_TRANSCRIPT_DIR"
RESTART_WRITES_TRANSCRIPT=1
watchdog_tick; TICK=2800; watchdog_tick; TICK=4600; watchdog_tick
check "$(stage)" restarted 'restart transcript is baselined after proof'
TICK=6400; watchdog_tick
check "$(stage)" down 'restart-generated transcript does not rearm a hung supervisor'
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'hung restarted supervisor alerts after one interval'

restart_hung_case
watchdog_tick
jq '.stage="restarting" | .stage_at=1000 | .restart_tries=1' "$DIR/stall.json" > "$DIR/stall.json.tmp"
mv "$DIR/stall.json.tmp" "$DIR/stall.json"
PROC_STATE=shell
TICK=1001; watchdog_tick
check "$STOPPED" 1 'an interrupted restart retries once'
check "$(stage)" restarted 'the interrupted restart retry is proven'
check "$(jq -r .restart_tries "$DIR/stall.json")" 0 'a proven retry clears its restart receipt'

# A leftover restarting record never stops anything once restart is off.
for proc in shell agent; do
  hung_case
  watchdog_tick
  jq '.stage="restarting" | .stage_at=1000 | .restart_tries=1' "$DIR/stall.json" > "$DIR/stall.json.tmp"
  mv "$DIR/stall.json.tmp" "$DIR/stall.json"
  PROC_STATE=$proc PANE=$CLEAR IDENTITY=$'claude\tidle'
  TICK=1001; watchdog_tick
  check "$STOPPED" 0 "a leftover restart record with restart off never stops the supervisor ($proc)"
  [ ! -e "$DIR/launches" ] || fail "a leftover restart record with restart off launched a supervisor ($proc)"
  pass "a leftover restart record with restart off never launches a supervisor ($proc)"
done
check "$(stage)" watching 'a running supervisor after a leftover restart record resumes watching'
[ ! -e "$DIR/urgent" ] || fail 'a running supervisor after a leftover restart record alerted the captain'
pass 'a running supervisor after a leftover restart record does not alert'
hung_case
watchdog_tick
jq '.stage="restarting" | .stage_at=1000 | .restart_tries=1' "$DIR/stall.json" > "$DIR/stall.json.tmp"
mv "$DIR/stall.json.tmp" "$DIR/stall.json"
PROC_STATE=shell; TICK=1001; watchdog_tick
check "$(stage)" down 'no supervisor in the pane after a leftover restart record is a down incident'
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'no supervisor after a leftover restart record sends one urgent alert'

restart_hung_case
watchdog_tick
jq '.stage="restarting" | .stage_at=1000 | .restart_tries=2' "$DIR/stall.json" > "$DIR/stall.json.tmp"
mv "$DIR/stall.json.tmp" "$DIR/stall.json"
PROC_STATE=shell
TICK=1001; watchdog_tick
check "$STOPPED" 0 'an interrupted restart is never retried twice'
check "$(stage)" down 'an exhausted restart retry becomes a down incident'
grep -q 'could not be proven after one retry' "$DIR/urgent" || fail 'exhausted restart retry did not alert'
pass 'restart retry exhaustion sends the urgent alert'

restart_case
watchdog_tick
jq 'del(.restart_tries)' "$DIR/stall.json" > "$DIR/stall.json.tmp"
mv "$DIR/stall.json.tmp" "$DIR/stall.json"
TICK=1001; watchdog_tick
check "$(jq -r .restart_tries "$DIR/stall.json")" 0 'an older stall record gains the restart receipt field'
check "$(stage)" watching 'an older stall record remains usable'

# A proven restart remains local even when another stall follows.
restart_hung_case
watchdog_tick; TICK=2800; watchdog_tick; TICK=4600; watchdog_tick
IDENTITY=$'claude\tidle'; PANE=$CLEAR; BEACON=600; TICK=4700; watchdog_tick
IDENTITY=$'claude\tworking'
TICK=6500; watchdog_tick; TICK=8300; watchdog_tick
check "$STOPPED" 2 'a second stall restarts again'
[ ! -e "$DIR/urgent" ] || fail 'a proven repeated restart must not reach the captain'
pass 'a proven repeated restart is only logged locally'

# Progress signals: acknowledgement, usage limit, nothing under way.
stall_case
printf '300\t31\tcheck\tmail\tpending\n' > "$FM_WAKE_QUEUE"
IDENTITY=$'claude\tworking'; watchdog_tick
printf '301\t32\tcheck\tmail\tlater\n' > "$FM_WAKE_QUEUE"
TICK=2800; watchdog_tick
check "$(stage)" watching 'an acknowledged wake is progress'
rm -f "$FM_WAKE_QUEUE"
stall_case; PANE=$'● Done\n────────────────────\n❯ \n────────────────────'
watchdog_tick
printf '300\t31\tcheck\tmail\tpending\n' > "$FM_WAKE_QUEUE"
TICK=2800; IDENTITY=$'claude\tworking'; watchdog_tick
check "$(stage)" nudged 'a newly queued wake is not progress'
rm -f "$FM_WAKE_QUEUE"
stall_case; PANE=$'Usage limit reached · continuing automatically at 3pm\n❯ '
watchdog_tick; TICK=2800; watchdog_tick; TICK=4600; watchdog_tick
check "$STOPPED" 0 'a usage-limit pause is never restarted'
check "$SENT" 0 'a usage-limit pause is never typed into'
# A usage-limit notice counts as progress only for one interval; a long limit
# reaches the urgent alert without typing or restarting.
restart_case; PANE=$'Usage limit reached · continuing automatically at 3pm\n────────────────────\n❯ \n────────────────────'
for t in $(seq 1000 900 260200); do TICK=$t; watchdog_tick; done
check "$SENT" 0 'a 72-hour usage limit is never typed into'
check "$STOPPED" 0 'a 72-hour usage limit is never restarted'
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'a 72-hour usage limit sends one urgent alert'
check "$(jq -r 'select(.event=="alerted") | .at' "$DIR/events.jsonl" | head -1)" 4600 'the usage-limit alert fires one interval after the notice stops counting'
grep -Eq 'shown a usage-limit notice for [0-9]+ minutes with no other progress, so it cannot work until the limit resets' "$DIR/urgent" || fail 'usage-limit alert is not plain'
pass 'usage-limit alert says the supervisor is stopped by a usage limit'
stall_case; PANE=$'Usage limit reached · continuing automatically at 3pm\n────────────────────\n❯ \n────────────────────'
for t in $(seq 1000 60 3400); do TICK=$t; watchdog_tick; done
PANE=$CLEAR; IDENTITY=$'claude\tworking'; TICK=3460; watchdog_tick
check "$(stage)" watching 'Claude resuming after a short usage limit is progress'
[ ! -e "$DIR/urgent" ] || fail 'a short usage limit reached the captain'
pass 'a usage limit that clears inside the window never alerts'
check "$(jq -r .usage_since "$DIR/stall.json")" 0 'the usage-limit window resets once the notice clears'
stall_case; UNDER_WAY=0
watchdog_tick; TICK=2800; watchdog_tick
[ ! -e "$DIR/stall.json" ] || fail 'idle home kept a stall timer'
pass 'no work under way means no stall timer'
stall_case
printf '{bad\n' > "$DIR/stall.json"
watchdog_tick
[ -e "$DIR/stall.json.corrupt" ] || fail 'corrupt stall state was not preserved'
watchdog_tick
check "$(stage)" watching 'corrupt stall state restarts the timer instead of refusing forever'

# Drift holds a restart because the unverified composer may contain a draft.
restart_case; PANE=$'● Done\n❯ half-typed answer'; DRIFT=1 INSTALLED_VERSION='2.1.312 (Claude Code)'
watchdog_tick; TICK=2800; watchdog_tick
check "$SENT" 0 'drift withholds the stall nudge'
TICK=4600; watchdog_tick
check "$STOPPED" 0 'drift never stops a supervisor with unverified input'
check "$(stage)" down 'drift records the held restart as a down incident'
grep -q 'supervisor .* stalled; restart held because unsent input may be in the box' "$DIR/urgent" || fail 'drift alert did not explain the held restart'
pass 'drift sends the held-restart alert in plain words'
TICK=4601; watchdog_tick
check "$(wc -l < "$DIR/urgent" | tr -d ' ')" 1 'delivered drift alert is not repeated'
DRIFT=0
