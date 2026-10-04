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
