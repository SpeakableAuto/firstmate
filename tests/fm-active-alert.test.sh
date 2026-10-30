#!/usr/bin/env bash
# Urgent captain alerts: condition allow-list, Telegram Hermes hand-off,
# rate limits, dedupe, failure retry, message-id log and the machine probe.
# A recording sender replaces Hermes through FM_URGENT_ALERT_EXEC; nothing
# leaves the machine.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export FM_HOME="$TMP/home"
mkdir -p "$FM_HOME/state"
CLI="$ROOT/bin/fm-urgent-alert.sh"
SENT_DIR="$TMP/sent"
mkdir -p "$SENT_DIR"
cat > "$TMP/sender" <<'SENDER'
#!/usr/bin/env bash
# Records the target and the message, then answers like `hermes send --json`.
dir=$(dirname "$0")/sent
n=$(( $(find "$dir" -type f | wc -l) + 1 ))
{ printf 'target=%s\n' "$1"; cat; } > "$dir/$n"
case "${SENDER_MODE:-ok}" in
  ok) printf '{"success": true, "platform": "telegram", "chat_id": "999", "message_id": "%s"}\n' "$((4000 + n))" ;;
  error) printf '{"error": "Telegram send failed"}\n'; exit 1 ;;
  noid) printf '{"success": true}\n' ;;
  banner) printf 'Sending to telegram...\n{"success": true, "message_id": "%s"}\n' "$((4000 + n))" ;;
  pretty) printf '{\n  "success": true,\n  "message_id": "%s"\n}\n' "$((4000 + n))" ;;
  hang) sleep 30 ;;
esac
SENDER
chmod +x "$TMP/sender"
export FM_URGENT_ALERT_EXEC="$TMP/sender"
LOG="$FM_HOME/state/urgent-alert/sent.jsonl"
CLOCK="$TMP/clock"
printf '%s\n' 100000 > "$CLOCK"
# The CLI reads the time through `date +%s`; a PATH shim pins it.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/date" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = +%s ]; then cat "$CLOCK"; else exec /bin/date "\$@"; fi
SHIM
chmod +x "$TMP/bin/date"
export PATH="$TMP/bin:$PATH"
at() { printf '%s\n' "$1" > "$CLOCK"; }
sent_count() { find "$SENT_DIR" -type f | wc -l | tr -d ' '; }
check() { [ "$1" = "$2" ] || fail "$3 (got '$1', expected '$2')"; pass "$3"; }
run() { FULL=$("$CLI" "$@" 2>/dev/null) && RC=0 || RC=$?; OUT=${FULL%%$'\n'*}; }

run send routine-update k 'All shipshape.'
check "$RC" 2 'a routine update is not an urgent condition'
check "$(sent_count)" 0 'unknown condition never reaches the sender'
run send 'supervisor-down carve-out-blocked' joined 'Firstmate: combined condition.'
check "$RC" 2 'joined urgent conditions are rejected'
check "$(sent_count)" 0 'joined conditions cannot bypass the sender allow-list'
run send test setup 'Firstmate weekend alerts are set up'
check "$RC" 2 'the test condition is only reachable through the test subcommand'

run test
check "$RC" 0 'setup test message delivered'
check "$OUT" sent 'test reports sent'
check "$(printf '%s\n' "$FULL" | sed -n 's/^message_id=//p')" 4001 'test prints the delivered message id'
check "$(sed -n 1p "$SENT_DIR/1")" target=telegram 'fixed Telegram home target is used'
check "$(sed -n 2p "$SENT_DIR/1")" 'Firstmate weekend alerts are set up' 'exact setup words are sent'
check "$(tail -1 "$LOG" | jq -c '[.condition,.result,.message_id]')" '["test","sent","4001"]' 'log records the message id'
grep -q '999' "$LOG" && fail 'chat id leaked into the log'
grep -q 'weekend alerts' "$LOG" && fail 'message text leaked into the log'
pass 'log keeps the message id but never the chat id or text'

at 100100
run send supervisor-down sup-1 'Firstmate: the supervisor stopped making progress and a restart did not bring it back.'
check "$OUT" sent 'first supervisor-down alert delivered'
at 100200
run send supervisor-down sup-2 'Firstmate: still stopped.'
check "$OUT" skipped:condition-rate-limit 'same condition within six hours is held back'
check "$RC" 0 'a rate-limited skip is not a failure'
at $((100100 + 21600))
run send supervisor-down sup-1 'Firstmate: the supervisor stopped making progress and a restart did not bring it back.'
check "$OUT" skipped:duplicate 'same condition and key is deduplicated for a day'
run send supervisor-down sup-3 'Firstmate: supervisor stopped again.'
check "$OUT" sent 'a new key after six hours is delivered'
check "$(sent_count)" 3 'only three messages reached the sender so far'

run send carve-out-blocked pr-83 'Firstmate: every priority task is waiting on your decision about the payments change.'
check "$OUT" sent 'a different condition is not held back by another condition'
run send machine-down m0002 'Firstmate: the 0002 machine has been unreachable for 20 minutes.'
check "$OUT" skipped:daily-cap 'daily cap holds the fifth message in 24 hours'
check "$(sent_count)" 4 'daily cap stops delivery'
at $((100000 + 86400 + 1))
run send machine-down m0002 'Firstmate: the 0002 machine has been unreachable for 20 minutes.'
check "$OUT" sent 'daily cap rolls after 24 hours'

# A failed delivery is logged, retried only after the retry window.
rm -rf "$FM_HOME/state/urgent-alert" "$SENT_DIR"; mkdir -p "$SENT_DIR"
at 200000
SENDER_MODE=error run send supervisor-down sup 'Firstmate: supervisor stopped.'
check "$RC" 1 'Hermes error is a failure'
check "$OUT" failed:delivery-failed 'Hermes error reported'
at 200100
run send supervisor-down sup 'Firstmate: supervisor stopped.'
check "$OUT" skipped:retry-backoff 'failed delivery is not hammered'
at 200901
run send supervisor-down sup 'Firstmate: supervisor stopped.'
check "$OUT" sent 'failed delivery retries after the retry window'
rm -rf "$FM_HOME/state/urgent-alert"
SENDER_MODE=noid run send supervisor-down sup 'Firstmate: supervisor stopped.'
check "$OUT" failed:no-message-id 'a reply without a message id is not proof of delivery'
rm -rf "$FM_HOME/state/urgent-alert"
SENDER_MODE=hang FM_WEDGE_ALARM_TIMEOUT_SECS=1 run send supervisor-down sup 'Firstmate: supervisor stopped.'
check "$OUT" failed:delivery-timeout 'a hung sender is bounded'

# An ambiguous delivery may have reached the phone, so it counts against the
# condition limit and the daily cap instead of retrying every retry window.
rm -rf "$FM_HOME/state/urgent-alert" "$SENT_DIR"; mkdir -p "$SENT_DIR"
at 210000
SENDER_MODE=noid run send supervisor-down sup-a 'Firstmate: supervisor stopped.'
check "$OUT" failed:no-message-id 'an id-less reply is still not proof of delivery'
check "$(tail -1 "$LOG" | jq -r .result)" unconfirmed 'an id-less reply is logged as unconfirmed'
at 211000
run send supervisor-down sup-b 'Firstmate: supervisor still stopped.'
check "$OUT" skipped:condition-rate-limit 'an unconfirmed delivery holds its condition like a sent one'
SENDER_MODE=hang FM_WEDGE_ALARM_TIMEOUT_SECS=1 run send machine-down m0002 'Firstmate: 0002 unreachable.'
check "$OUT" failed:delivery-timeout 'a timed-out delivery is still not proof'
check "$(tail -1 "$LOG" | jq -r .result)" unconfirmed 'a timed-out delivery is logged as unconfirmed'
FM_URGENT_ALERT_DAILY_CAP=2 run send carve-out-blocked pr-1 'Firstmate: waiting on your decision.'
check "$OUT" skipped:daily-cap 'unconfirmed deliveries count toward the daily cap'
check "$(sent_count)" 2 'only the two ambiguous attempts reached the sender'
for t in 1 2 3 4 5 6 7 8; do
  at $((211000 + t * 3600))
  SENDER_MODE=noid run send supervisor-down "sup-$t" 'Firstmate: supervisor stopped.'
done
check "$(sent_count)" 3 'id-less replies reach the phone at most once per condition window'

# A text line before the JSON, or pretty-printed JSON, still yields the id.
for mode in banner pretty; do
  rm -rf "$FM_HOME/state/urgent-alert" "$SENT_DIR"; mkdir -p "$SENT_DIR"
  SENDER_MODE=$mode run send supervisor-down "sup-$mode" 'Firstmate: supervisor stopped.'
  check "$OUT" sent "a $mode Hermes reply is parsed"
  check "$(tail -1 "$LOG" | jq -r .message_id)" 4001 "a $mode Hermes reply records its message id"
done

# One torn log line never silences later alerts or loses the intact limits.
rm -rf "$FM_HOME/state/urgent-alert" "$SENT_DIR"; mkdir -p "$SENT_DIR"
at 220000
run send supervisor-down s1 'Firstmate: supervisor stopped.'
check "$OUT" sent 'first alert before the torn line is delivered'
printf '{"at":220001,"condition":"machi' >> "$LOG"
at 220100
run send supervisor-down s2 'Firstmate: supervisor still stopped.'
check "$OUT" skipped:condition-rate-limit 'intact records still enforce limits past a torn line'
run send machine-down m0002 'Firstmate: 0002 unreachable.'
check "$OUT" sent 'a torn line does not silence a new alert'
check "$(tail -1 "$LOG" | jq -r .result)" sent 'the record after a torn line starts on its own line'
check "$(jq -R 'fromjson? | .result' "$LOG" | wc -l | tr -d ' ')" 3 'only the torn line is unreadable'

run log
check "$RC" 2 'the unrelated log subcommand is not exposed'

# The real Hermes hand-off: home-channel target, JSON mode, message file.
rm -rf "$FM_HOME/state/urgent-alert"
cat > "$TMP/hermes" <<'HERMES'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$(dirname "$0")/hermes-args"
cat "$6" > "$(dirname "$0")/hermes-body"
printf '{"success": true, "platform": "telegram", "chat_id": "1", "message_id": "77"}\n'
HERMES
chmod +x "$TMP/hermes"
OUT=$(env -u FM_URGENT_ALERT_EXEC FM_HERMES_BIN="$TMP/hermes" "$CLI" test)
check "$(printf '%s\n' "$OUT" | tr '\n' ' ')" 'sent message_id=77 ' 'real sender path parses the Hermes reply'
check "$(head -5 "$TMP/hermes-args" | tr '\n' ' ')" 'send --to telegram --json --file ' 'Hermes gets the home-channel target in JSON mode'
check "$(cat "$TMP/hermes-body")" 'Firstmate weekend alerts are set up' 'message travels in a file Hermes reads'
[ ! -e "$(sed -n 6p "$TMP/hermes-args")" ] || fail 'message file left behind'
pass 'message file is removed after delivery'

# Machine probe: alert once after a sustained outage, never on one blip.
rm -rf "$FM_HOME/state/urgent-alert" "$SENT_DIR"; mkdir -p "$SENT_DIR"
cat > "$TMP/probe" <<'PROBE'
#!/usr/bin/env bash
[ "$(cat "$(dirname "$0")/probe-state")" = up ]
PROBE
chmod +x "$TMP/probe"
export FM_MACHINE_PROBE="$TMP/probe"
printf 'down\n' > "$TMP/probe-state"
at 300000; run check-machine m0002 mac-mini-0002
check "$OUT" unreachable 'one failed probe only records the outage'
at 300300; run check-machine m0002 mac-mini-0002
printf 'up\n' > "$TMP/probe-state"
at 300600; run check-machine m0002 mac-mini-0002
check "$OUT" reachable 'a recovery clears the outage'
printf 'down\n' > "$TMP/probe-state"
for t in 301000 301300 301600; do at "$t"; run check-machine m0002 mac-mini-0002; done
check "$OUT" unreachable 'three failures inside fifteen minutes are not yet an outage'
at 301900; run check-machine m0002 mac-mini-0002
check "$OUT" sent 'sustained outage sends one machine-down alert'
grep -q 'm0002 machine has been unreachable for 15 minutes' "$SENT_DIR/1" || fail 'machine alert is not plain words'
pass 'machine alert names the machine and the outage length'
at 302200; run check-machine m0002 mac-mini-0002
check "$OUT" unreachable 'the same outage never alerts twice'
check "$(sent_count)" 1 'one outage, one message'
if "$CLI" check-machine '../x' host >/dev/null 2>&1; then fail 'unsafe machine label accepted'; fi
pass 'machine label is restricted to a safe file name'

rm -rf "$FM_HOME/state/urgent-alert" "$SENT_DIR"; mkdir -p "$SENT_DIR"
printf 'down\n' > "$TMP/probe-state"
for t in 400000 400300 400600; do at "$t"; run check-machine m0002 mac-mini-0002; done
export FM_URGENT_ALERT_DAILY_CAP=0
at 400900; run check-machine m0002 mac-mini-0002
unset FM_URGENT_ALERT_DAILY_CAP
check "$OUT" skipped:daily-cap 'a limited machine alert reports the limiter result'
check "$(jq -r .alerted "$FM_HOME/state/urgent-alert/machine-m0002.json")" false 'a limited alert leaves the outage open'
at 401200; run check-machine m0002 mac-mini-0002
check "$OUT" sent 'the open outage retries after the limit clears'
check "$(jq -r .alerted "$FM_HOME/state/urgent-alert/machine-m0002.json")" true 'delivery closes the outage alert episode'

rm -rf "$FM_HOME/state/urgent-alert" "$SENT_DIR"; mkdir -p "$SENT_DIR"
for t in 500000 500300 500600; do at "$t"; run check-machine m0002 mac-mini-0002; done
at 500900; SENDER_MODE=error run check-machine m0002 mac-mini-0002
check "$OUT" failed:delivery-failed 'a failed machine alert reports delivery failure'
check "$(jq -r .alerted "$FM_HOME/state/urgent-alert/machine-m0002.json")" false 'a failed delivery leaves the outage open'
at 501801; run check-machine m0002 mac-mini-0002
check "$OUT" sent 'the open outage retries after delivery backoff'
