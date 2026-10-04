#!/usr/bin/env bash
# A queue append without a new status signature must still end the watch cycle.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(fm_test_tmproot fm-watch-durable-queue)
now=$(date +%s)

home="$tmp/ordinary-home"
mkdir -p "$home/state" "$home/config" "$home/data"
printf '%s\t1\tcheck\texternal\tpending\n' "$now" > "$home/state/.wake-queue"
printf '1\n' > "$home/state/.wake-queue.seq"
printf 'pending:handling:queue-ordinary.1.aaa\n' > "$home/state/.watcher-down"
chmod 600 "$home/state/.watcher-down"
out=$(FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5) \
  || fail 'watcher did not surface an already queued wake'
assert_contains "$out" 'check: pending durable wakes' 'pending queue did not wake the supervisor'
[ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" = 1 ] \
  || fail 'queue replay appended a duplicate row'
pass 'already queued main wake ends the watcher cycle without a duplicate'

home="$tmp/recovery-home"
mkdir -p "$home/state" "$home/config" "$home/data"
printf '%s\t1\tcheck\texternal\tpending\n' "$now" > "$home/state/.wake-queue"
printf '1\n' > "$home/state/.wake-queue.seq"
printf 'pending:downtime:queue-recovery.1.aaa\n' > "$home/state/.watcher-down"
chmod 600 "$home/state/.watcher-down"
out=$(FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
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
