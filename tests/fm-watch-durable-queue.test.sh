#!/usr/bin/env bash
# A queue append without a new status signature must still end the watch cycle.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(fm_test_tmproot fm-watch-durable-queue)
home="$tmp/home"
mkdir -p "$home/state" "$home/config" "$home/data"
now=$(date +%s)
printf '%s\t1\tcheck\texternal\tpending\n' "$now" > "$home/state/.wake-queue"
printf '1\n' > "$home/state/.wake-queue.seq"
out=$(FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5) \
  || fail 'watcher did not surface an already queued wake'
assert_contains "$out" 'check: pending durable wakes' 'pending queue did not wake the supervisor'
[ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" = 1 ] \
  || fail 'queue replay appended a duplicate row'
pass 'already queued main wake ends the watcher cycle without a duplicate'
