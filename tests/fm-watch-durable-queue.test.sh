#!/usr/bin/env bash
# A queue append without a new status signature must still end the watch cycle.
set -eu
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

tmp=$(fm_test_tmproot fm-watch-durable-queue)
now=$(date +%s)

home="$tmp/ordinary-home"
mkdir -p "$home/state" "$home/config" "$home/data"
printf '%s\t1\tcheck\texternal\tpending\n' "$now" > "$home/state/.wake-queue"
printf '1\n' > "$home/state/.wake-queue.seq"
printf 'pending:handling:queue-ordinary.1.aaa\n' > "$home/state/.watcher-down"
chmod 600 "$home/state/.watcher-down"
out=$(FM_HOME="$home" FM_WATCH_HANDLING_SUCCESSOR=0 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5) \
  || fail 'watcher did not surface an already queued wake'
assert_contains "$out" 'check: pending durable wakes' 'pending queue did not wake the supervisor'
[ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" = 1 ] \
  || fail 'queue replay appended a duplicate row'
pass 'already queued main wake ends the watcher cycle without a duplicate'

home="$tmp/after-drain-home"
mkdir -p "$home/state" "$home/config" "$home/data"
printf 'pending:handling:queue-after-drain.1.aaa\n' > "$home/state/.watcher-down"
chmod 600 "$home/state/.watcher-down"
append_wake "$home/state" check earlier 'check: earlier row'
FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" > "$home/drain.out" 2> "$home/drain.err" \
  || fail 'the handling turn could not drain its earlier row'
ack_drain_err "$home/state" "$home/drain.err" \
  || fail 'the handling turn could not acknowledge its earlier row'
append_wake "$home/state" check later 'check: row queued mid-turn'
# In the old order, unreadable program input produces another check before the
# queued row is surfaced.
mkfifo "$home/data/backlog.md"
FM_HOME="$home" FM_WATCH_PREDECESSOR_ARM_PID='' FM_WATCH_HANDLING_SUCCESSOR=0 FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch-arm.sh" > "$home/stop-arm.out" 2>&1 &
arm_pid=$!
i=0
while kill -0 "$arm_pid" 2>/dev/null && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
if kill -0 "$arm_pid" 2>/dev/null; then
  kill -TERM "$arm_pid" 2>/dev/null || true
  wait "$arm_pid" 2>/dev/null || true
  fail 'the Stop-owned arm delayed the row queued after drain/ack'
fi
wait "$arm_pid" || fail 'the Stop-owned arm failed after the handling turn'
out=$(cat "$home/stop-arm.out")
assert_contains "$out" 'check: rearm-resurface' 'turn-end watcher delayed the new row behind fleet checks'
assert_contains "$(cat "$home/state/.wake-queue")" "$(printf '\tcheck\tlater\t')" \
  'turn-end watcher removed the durable row before the next drain'
pass 'turn-end watcher delivers a row queued after in-turn drain and acknowledgement before slow checks'

home="$tmp/recovery-home"
mkdir -p "$home/state" "$home/config" "$home/data"
printf '%s\t1\tcheck\texternal\tpending\n' "$now" > "$home/state/.wake-queue"
printf '1\n' > "$home/state/.wake-queue.seq"
printf 'pending:downtime:queue-recovery.1.aaa\n' > "$home/state/.watcher-down"
chmod 600 "$home/state/.watcher-down"
out=$(FM_HOME="$home" FM_WATCH_HANDLING_SUCCESSOR=0 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5) \
  || fail 'recovery watcher did not surface its downtime episode'
assert_contains "$out" 'check: rearm-resurface' 'downtime recovery lost precedence over queue replay'
assert_not_contains "$out" 'check: pending durable wakes' 'queue replay shadowed downtime recovery'
pass 'downtime recovery precedes generic queue replay'

home="$tmp/successor-home"
mkdir -p "$home/state" "$home/config" "$home/data"
printf '%s\t1\tcheck\texternal\tpending\n' "$now" > "$home/state/.wake-queue"
printf '1\n' > "$home/state/.wake-queue.seq"
set +e
out=$(FM_HOME="$home" FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 2>&1)
status=$?
set -e
[ "$status" -eq 124 ] || fail "handling successor replayed its queued delivery: $out"
assert_contains "$out" 'checkpoint: no actionable wake' 'handling successor did not remain in its poll loop'
pass 'handling successor supervises without recursively replaying its queued row'

out_file="$home/later-row.out"
rm -f "$home/state/.last-watcher-beat"
FM_HOME="$home" FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5 > "$out_file" 2>&1 &
watch_pid=$!
i=0
while [ ! -e "$home/state/.last-watcher-beat" ] && [ "$i" -lt 30 ]; do
  sleep 0.1
  i=$((i + 1))
done
[ -e "$home/state/.last-watcher-beat" ] || fail 'handling successor did not start for later-row replay'
printf '%s\t2\tcheck\tlater\tcheck: later row\n' "$now" >> "$home/state/.wake-queue"
printf '2\n' > "$home/state/.wake-queue.seq"
set +e
wait "$watch_pid"
status=$?
set -e
out=$(cat "$out_file")
[ "$status" -eq 0 ] || fail "handling successor did not replay a later row: $out"
assert_contains "$out" 'check: pending durable wakes' 'later row did not wake the supervisor'
[ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" = 2 ] \
  || fail 'later-row replay appended a duplicate queue row'
out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2> "$home/drain.err") \
  || fail "later queued row could not be drained: $(cat "$home/drain.err")"
assert_contains "$out" "$(printf '\tcheck\tlater\t')" 'later queued row was not presented to the supervisor'
pass 'handling successor replays a row appended after its inherited delivery'

home="$tmp/branch-release-home"
mkdir -p "$home/state" "$home/config" "$home/data"
printf '%s\t1\tcheck\tbranch-held\tcheck: branch-held row\n' "$now" > "$home/state/.wake-queue"
printf '%s\t2\tcheck\tmain-owned\tcheck: main-owned row\n' "$now" >> "$home/state/.wake-queue"
printf '2\n' > "$home/state/.wake-queue.seq"
FM_HOME="$home" "$ROOT/bin/fm-wake-grant.sh" activate "$$" branch-release \
  || fail 'branch owner could not activate for released-row replay'
FM_HOME="$home" "$ROOT/bin/fm-wake-grant.sh" publish branch-release 1 \
  || fail 'branch-held row could not be granted'
out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2> "$home/initial-drain.err") \
  || fail "main-owned row could not be presented: $(cat "$home/initial-drain.err")"
assert_contains "$out" "$(printf '\tcheck\tmain-owned\t')" 'initial main drain did not present its owned row'
assert_not_contains "$out" "$(printf '\tcheck\tbranch-held\t')" 'initial main drain presented the branch-held row'

out_file="$home/released-row.out"
FM_HOME="$home" FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5 > "$out_file" 2>&1 &
watch_pid=$!
i=0
while [ ! -e "$home/state/.last-watcher-beat" ] && [ "$i" -lt 30 ]; do
  sleep 0.1
  i=$((i + 1))
done
[ -e "$home/state/.last-watcher-beat" ] || fail 'handling successor did not start for released-row replay'
FM_HOME="$home" "$ROOT/bin/fm-wake-grant.sh" release branch-release \
  || fail 'branch-held row could not be released to main'
set +e
wait "$watch_pid"
status=$?
set -e
out=$(cat "$out_file")
[ "$status" -eq 0 ] || fail "handling successor did not replay the released branch row: $out"
assert_contains "$out" 'check: pending durable wakes' 'released branch row did not wake the supervisor'
out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2> "$home/released-drain.err") \
  || fail "released branch row could not be drained: $(cat "$home/released-drain.err")"
assert_contains "$out" "$(printf '\tcheck\tbranch-held\t')" 'released branch row was not presented to the supervisor'
pass 'handling successor replays a branch-held row after its grant releases'
