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
fakebin="$home/fakebin"
mkdir -p "$home/state" "$home/config" "$home/data" "$fakebin"
fm_test_track_watcher_state "$home/state"
printf 'pending:handling:queue-after-drain.1.aaa\n' > "$home/state/.watcher-down"
chmod 600 "$home/state/.watcher-down"
append_wake "$home/state" check earlier 'check: earlier row'
FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" > "$home/drain.out" 2> "$home/drain.err" \
  || fail 'the handling turn could not drain its earlier row'
ack_drain_err "$home/state" "$home/drain.err" \
  || fail 'the handling turn could not acknowledge its earlier row'
printf '%s\n' '## In flight' '- [ ] slow-program - Slow program (repo: fixture) (kind: program)' \
  > "$home/data/backlog.md"
real_cksum=$(command -v cksum)
cat > "$fakebin/cksum" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/state/program-reconcile-blocked"
i=0
while [ ! -e "$FM_HOME/state/program-reconcile-release" ] \
  && [ "$i" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
  sleep 1
  i=$((i + 1))
done
exec "$FM_REAL_CKSUM" "$@"
SH
chmod +x "$fakebin/cksum"
PATH="$fakebin:$PATH" FM_REAL_CKSUM="$real_cksum" FM_HOME="$home" \
  FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch.sh" > "$home/handling-watcher.out" 2>&1 &
watcher_pid=$!
i=0
while [ ! -e "$home/state/program-reconcile-blocked" ] && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
[ -e "$home/state/program-reconcile-blocked" ] \
  || fail 'the handling watcher did not enter its slow synchronous reconciliation call'
append_wake "$home/state" check later 'check: row queued mid-turn'
PATH="$fakebin:$PATH" FM_REAL_CKSUM="$real_cksum" FM_HOME="$home" \
  FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 FM_GUARD_GRACE=30 \
  "$ROOT/bin/fm-watch-arm.sh" > "$home/stop-arm.out" 2>&1 &
arm_pid=$!
wait_for_exit "$arm_pid" 30 \
  || fail 'the Stop-owned arm delayed the post-check row behind the blocked watcher'
out=$(cat "$home/stop-arm.out")
assert_contains "$out" 'check: pending durable wakes' \
  'turn-end attachment did not surface the row appended after the watcher queue check'
is_live_non_zombie "$watcher_pid" \
  || fail 'the slow watcher exited before the turn-end attachment proved the race'
assert_contains "$(cat "$home/state/.wake-queue")" "$(printf '\tcheck\tlater\t')" \
  'turn-end watcher removed the durable row before the next drain'
touch "$home/state/program-reconcile-release"
wait_for_exit "$watcher_pid" 50 >/dev/null 2>&1 || true
pass 'turn-end attachment promptly delivers a post-check row while the watcher is blocked'

# The same race with the blocked watcher's beacon aged past the arm's grace but
# still below the watcher's eviction bound: no replacement can take the live
# lock, so the turn-end arm must surface the row instead of failing to arm.
home="$tmp/stale-beacon-home"
fakebin="$home/fakebin"
mkdir -p "$home/state" "$home/config" "$home/data" "$fakebin"
fm_test_track_watcher_state "$home/state"
printf 'pending:handling:queue-stale-beacon.1.aaa\n' > "$home/state/.watcher-down"
chmod 600 "$home/state/.watcher-down"
append_wake "$home/state" check earlier 'check: earlier row'
FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" > "$home/drain.out" 2> "$home/drain.err" \
  || fail 'the stale-beacon handling turn could not drain its earlier row'
ack_drain_err "$home/state" "$home/drain.err" \
  || fail 'the stale-beacon handling turn could not acknowledge its earlier row'
printf '%s\n' '## In flight' '- [ ] slow-program - Slow program (repo: fixture) (kind: program)' \
  > "$home/data/backlog.md"
cp "$tmp/after-drain-home/fakebin/cksum" "$fakebin/cksum"
PATH="$fakebin:$PATH" FM_REAL_CKSUM="$real_cksum" FM_HOME="$home" \
  FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_GUARD_GRACE=30 FM_WATCHER_STALL_BOUND=3600 \
  "$ROOT/bin/fm-watch.sh" > "$home/handling-watcher.out" 2>&1 &
watcher_pid=$!
i=0
while [ ! -e "$home/state/program-reconcile-blocked" ] && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
[ -e "$home/state/program-reconcile-blocked" ] \
  || fail 'the stale-beacon watcher did not enter its slow synchronous reconciliation call'
fm_touch_epoch "$(( $(date +%s) - 120 ))" "$home/state/.last-watcher-beat"
append_wake "$home/state" check later 'check: row queued behind a stale beacon'
PATH="$fakebin:$PATH" FM_REAL_CKSUM="$real_cksum" FM_HOME="$home" \
  FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 FM_GUARD_GRACE=30 FM_WATCHER_STALL_BOUND=3600 \
  "$ROOT/bin/fm-watch-arm.sh" > "$home/stop-arm.out" 2>&1 &
arm_pid=$!
set +e
wait_for_exit "$arm_pid" 30
status=$?
set -e
out=$(cat "$home/stop-arm.out")
[ "$status" -eq 0 ] || fail "turn-end arm failed behind the stale-beacon watcher (exit $status): $out"
assert_contains "$out" 'check: pending durable wakes' \
  'turn-end arm did not surface the row queued behind a stale-beacon watcher'
assert_not_contains "$out" 'watcher: attached' 'turn-end arm reported a stale-beacon watcher as healthy'
is_live_non_zombie "$watcher_pid" \
  || fail 'the stale-beacon watcher exited before the turn-end arm proved the race'
assert_contains "$(cat "$home/state/.wake-queue")" "$(printf '\tcheck\tlater\t')" \
  'turn-end arm removed the durable row before the next drain'
touch "$home/state/program-reconcile-release"
wait_for_exit "$watcher_pid" 50 >/dev/null 2>&1 || true
pass 'turn-end arm delivers a post-check row while the blocked watcher beacon is stale but not evictable'

# A stray successor flag in the arm's environment must not reach an ordinary
# watcher, which would otherwise pin the queued row as already delivered.
home="$tmp/stray-successor-flag-home"
mkdir -p "$home/state" "$home/config" "$home/data"
fm_test_track_watcher_state "$home/state"
printf 'pending:handling:queue-stray-flag.1.aaa\n' > "$home/state/.watcher-down"
chmod 600 "$home/state/.watcher-down"
append_wake "$home/state" check queued 'check: row queued before the arm'
FM_WATCH_HANDLING_SUCCESSOR=1 FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=5 \
  "$ROOT/bin/fm-watch-arm.sh" > "$home/arm.out" 2>&1 &
arm_pid=$!
set +e
wait_for_exit "$arm_pid" 100
status=$?
set -e
out=$(cat "$home/arm.out")
[ "$status" -eq 0 ] || fail "ordinary arm with a stray successor flag did not deliver (exit $status): $out"
printf '%s\n' "$out" | grep -Eq '^check: (pending durable wakes|rearm-resurface)' \
  || fail "stray successor flag hid an already queued row from an ordinary watcher: $out"
pass 'ordinary arm never passes a stray successor flag to its watcher'

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
