#!/usr/bin/env bash
# Behavior tests using disposable cache trees and fake disk/Docker commands.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-disk-guard)
mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/df" <<'SH'
#!/usr/bin/env bash
[ ! -e "$HOME/df-fail" ] || exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture 99999999 1 %s 1%% /\n' "$(cat "$HOME/free")"
SH
cat > "$TMP_ROOT/fakebin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/docker-calls"
if [ "$1" = context ]; then
  cat "$HOME/endpoint"
else
  [ ! -e "$HOME/docker-fail" ]
fi
SH
chmod +x "$TMP_ROOT/fakebin/"*
new_case() {
  case_home="$TMP_ROOT/$1"
  mkdir -p "$case_home/user" "$case_home/fm/config"
  echo 10485760 > "$case_home/user/free"
  echo unix:///fixture/docker.sock > "$case_home/user/endpoint"
}
run_guard() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT HOME="$case_home/user" \
    FM_HOME="$case_home/fm" FM_STATE_OVERRIDE="$case_home/fm/state" \
    FM_WAKE_QUEUE="$case_home/fm/state/.wake-queue" \
    FM_WAKE_QUEUE_LOCK="$case_home/fm/state/.wake-queue.lock" \
    PATH="$TMP_ROOT/fakebin:$PATH" bash "$ROOT/bin/fm-disk-guard.sh" "$@"
}
seed_caches() {
  mkdir -p "$case_home/user/Library/Developer/Xcode/DerivedData/build" "$case_home/user/.npm/_cacache/cache"
  echo important > "$case_home/user/backup.tgz"
  echo config > "$case_home/user/.npm/config"
  echo cache > "$case_home/user/.npm/_cacache/.hidden"
}
new_case healthy
seed_caches
printf 'cache=npm\ncache=docker\n' > "$case_home/fm/config/disk-guard"
echo 15728640 > "$case_home/user/free"
run_guard
[ -d "$case_home/user/.npm/_cacache/cache" ] || fail 'threshold equality cleaned caches'
[ ! -e "$case_home/fm/state" ] || fail 'healthy check wrote state'
[ ! -e "$case_home/user/docker-calls" ] || fail 'healthy check ran Docker'
pass 'at the threshold: no cleanup or alert'

new_case low
seed_caches
printf 'cache=xcode-derived-data\ncache=npm\ncache=docker\n' > "$case_home/fm/config/disk-guard"
run_guard
[ ! -e "$case_home/user/.npm/_cacache/cache" ] || fail 'npm cache retained'
[ ! -e "$case_home/user/.npm/_cacache/.hidden" ] || fail 'hidden cache retained'
[ ! -e "$case_home/user/Library/Developer/Xcode/DerivedData/build" ] || fail 'DerivedData retained'
[ -f "$case_home/user/backup.tgz" ] && [ -f "$case_home/user/.npm/config" ] || fail 'non-cache files removed'
printf '%s\n' 'context inspect --format {{.Endpoints.docker.Host}}' \
  '--host unix:///fixture/docker.sock image prune --force' \
  '--host unix:///fixture/docker.sock builder prune --force' > "$TMP_ROOT/expected-docker"
cmp "$TMP_ROOT/expected-docker" "$case_home/user/docker-calls" || fail 'Docker did more than the allowed prunes'
grep -q 'low space:' "$case_home/fm/state/.wake-queue" || fail 'missing initial alert'
grep -q 'before=10485760 KiB after=10485760 KiB.*failures=0' "$case_home/fm/state/.wake-queue" || fail 'missing result alert'
run_guard
[ ! -d "$case_home/fm/state/.disk-guard.lock" ] || fail 'cleanup left lock'
pass 'low-space cleanup is repeatable, alerts, and preserves non-cache data'

new_case selective
seed_caches
echo cache=npm > "$case_home/fm/config/disk-guard"
run_guard
[ -d "$case_home/user/Library/Developer/Xcode/DerivedData/build" ] || fail 'unselected target cleaned'
[ ! -e "$case_home/user/docker-calls" ] || fail 'unselected Docker ran'
pass 'only selected caches are cleaned'

new_case no_targets
seed_caches
run_guard
[ -d "$case_home/user/.npm/_cacache/cache" ] || fail 'implicit target cleaned'
grep -q 'cleanup complete:' "$case_home/fm/state/.wake-queue" || fail 'empty allowlist did not alert'
pass 'missing configuration alerts without implicit cleanup'

new_case blocked_alert
seed_caches
echo cache=npm > "$case_home/fm/config/disk-guard"
mkdir -p "$case_home/fm/state"
FM_HOME="$case_home/fm" FM_STATE_OVERRIDE="$case_home/fm/state" \
  FM_WAKE_QUEUE="$case_home/fm/state/.wake-queue" \
  FM_WAKE_QUEUE_LOCK="$case_home/fm/state/.wake-queue.lock" \
  bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    printf "ready\n" > "$3"
    sleep 3
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$case_home/fm/state/.wake-queue.lock" "$case_home/alert-lock-ready" &
alert_holder=$!
for _ in {1..100}; do
  [ -s "$case_home/alert-lock-ready" ] && break
  sleep 0.05
done
if [ ! -s "$case_home/alert-lock-ready" ]; then
  kill "$alert_holder" 2>/dev/null || true
  wait "$alert_holder" 2>/dev/null || true
  fail 'alert lock holder did not start'
fi
if run_guard; then
  wait "$alert_holder" 2>/dev/null || true
  fail 'missed starting alert reported success'
fi
wait "$alert_holder"
[ ! -e "$case_home/user/.npm/_cacache/cache" ] || fail 'blocked starting alert prevented cleanup'
grep -q 'cleanup complete:.*failures=1' "$case_home/fm/state/.wake-queue" \
  || fail 'result alert did not durably report the missed starting alert'
pass 'a blocked starting alert is bounded and cleanup remains reported'

new_case dry_run
seed_caches
echo cache=npm > "$case_home/fm/config/disk-guard"
run_guard --dry-run > "$TMP_ROOT/dry-output"
grep -q 'planned caches: npm' "$TMP_ROOT/dry-output" || fail 'missing dry-run plan'
[ -d "$case_home/user/.npm/_cacache/cache" ] && [ ! -d "$case_home/fm/state" ] || fail 'dry-run mutated'
printf 'threshold_gib=9\ncache=npm\n' > "$case_home/fm/config/disk-guard"
run_guard
[ -d "$case_home/user/.npm/_cacache/cache" ] || fail 'custom threshold ignored'
pass 'dry-run is read-only and configurable threshold is respected'

for bad in 'cache=/tmp' 'cache=volumes' 'threshold_gib=0' 'threshold_gib=foo' 'threshold_gib=999999999999999'; do
  new_case invalid
  seed_caches
  printf 'cache=npm\n%s\n' "$bad" > "$case_home/fm/config/disk-guard"
  if run_guard > /dev/null 2>&1; then fail "accepted invalid configuration $bad"; fi
  [ -d "$case_home/user/.npm/_cacache/cache" ] || fail 'invalid config cleaned before validation'
done
pass 'invalid allowlist and threshold fail before any cleanup'

new_case linked
mkdir -p "$case_home/user/preserved/_cacache"
echo data > "$case_home/user/preserved/_cacache/important"
ln -s "$case_home/user/preserved" "$case_home/user/.npm"
echo cache=npm > "$case_home/fm/config/disk-guard"
if run_guard 2>/dev/null; then fail 'linked ancestor accepted'; fi
[ -f "$case_home/user/preserved/_cacache/important" ] || fail 'followed cache symlink'
grep -q 'failures=1' "$case_home/fm/state/.wake-queue" || fail 'symlink refusal not alerted'
pass 'linked cache ancestors are refused and reported'

new_case child_link
seed_caches
ln -s "$case_home/user/backup.tgz" "$case_home/user/.npm/_cacache/link"
echo cache=npm > "$case_home/fm/config/disk-guard"
run_guard
[ -f "$case_home/user/backup.tgz" ] || fail 'followed child symlink'
pass 'cache child symlinks do not delete their targets'

new_case remote_docker
printf 'cache=docker\n' > "$case_home/fm/config/disk-guard"
echo tcp://remote:2375 > "$case_home/user/endpoint"
if run_guard 2>/dev/null; then fail 'remote Docker accepted'; fi
[ "$(wc -l < "$case_home/user/docker-calls" | tr -d ' ')" = 1 ] || fail 'remote Docker cleanup ran'
pass 'remote Docker is refused'

new_case docker_failure
seed_caches
printf 'cache=docker\ncache=npm\n' > "$case_home/fm/config/disk-guard"
touch "$case_home/user/docker-fail"
if run_guard; then fail 'Docker failure reported success'; fi
[ ! -e "$case_home/user/.npm/_cacache/cache" ] || fail 'Docker failure prevented other cleanup'
grep -q 'failures=1' "$case_home/fm/state/.wake-queue" || fail 'Docker failure not alerted'
pass 'Docker failures alert while other caches are processed'

new_case measurement_failure
seed_caches
echo cache=npm > "$case_home/fm/config/disk-guard"
touch "$case_home/user/df-fail"
if run_guard; then fail 'measurement failure reported success'; fi
[ -d "$case_home/user/.npm/_cacache/cache" ] || fail 'failed measurement cleaned'
grep -q 'measurement failed' "$case_home/fm/state/.wake-queue" || fail 'measurement failure not alerted'
pass 'measurement failure does not clean and raises an alert'

new_case overlapping
seed_caches
echo cache=npm > "$case_home/fm/config/disk-guard"
mkdir -p "$case_home/fm/state/.disk-guard.lock"
if run_guard; then fail 'existing cleanup lock ignored'; fi
[ -d "$case_home/user/.npm/_cacache/cache" ] || fail 'overlapping cleanup ran'
pass 'existing lock prevents concurrent cleanup'
