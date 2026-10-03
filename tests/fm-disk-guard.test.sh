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
  [ ! -e "$HOME/docker-fail" ] || exit 1
  if [ "$3" = image ] && [ -e "$HOME/image-fail" ]; then exit 1; fi
  [ "$3" != builder ] || [ ! -e "$HOME/builder-fail" ]
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
    while [ ! -e "$3.release" ]; do sleep 0.1; done
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
  touch "$case_home/alert-lock-ready.release"
  wait "$alert_holder" 2>/dev/null || true
  fail 'missed starting alert reported success'
fi
touch "$case_home/alert-lock-ready.release"
wait "$alert_holder"
[ ! -e "$case_home/user/.npm/_cacache/cache" ] || fail 'blocked starting alert prevented cleanup'
[ "$(wc -l < "$case_home/fm/state/.disk-guard-alerts/alerts" | tr -d ' ')" = 2 ] \
  || fail 'timed-out alerts were not persisted in one ordered journal'
echo 20971520 > "$case_home/user/free"
run_guard --dry-run
[ ! -e "$case_home/fm/state/.wake-queue" ] || fail 'dry-run retried pending alerts'
run_guard
grep -q 'low space:' "$case_home/fm/state/.wake-queue" || fail 'starting alert not retried'
grep -q 'cleanup complete:.*failures=1' "$case_home/fm/state/.wake-queue" \
  || fail 'result alert not retried after disk recovered'
[ ! -e "$case_home/fm/state/.disk-guard-alerts/alerts" ] || fail 'delivered alerts retained for retry'
FM_HOME="$case_home/fm" FM_STATE_OVERRIDE="$case_home/fm/state" \
  FM_WAKE_QUEUE="$case_home/fm/state/.wake-queue" \
  FM_WAKE_QUEUE_LOCK="$case_home/fm/state/.wake-queue.lock" \
  bash "$ROOT/bin/fm-wake-drain.sh" > "$case_home/drain.out" 2> "$case_home/drain.err" \
  || fail 'real wake consumer could not drain retried alerts'
grep -q 'cleanup complete:.*failures=1' "$case_home/drain.out" \
  || fail 'wake deduplication did not retain the cleanup result'
if grep -q 'starting configured cleanup' "$case_home/drain.out"; then
  fail 'wake deduplication surfaced the superseded starting alert'
fi
cp "$case_home/fm/state/.wake-queue" "$TMP_ROOT/delivered-alerts"
run_guard
cmp "$case_home/fm/state/.wake-queue" "$TMP_ROOT/delivered-alerts" || fail 'delivered alerts repeated'
pass 'both timed-out alerts retry chronologically and the real wake consumer retains the result'

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

# Inject replacements at filesystem-operation boundaries in the public cleaner.
# These are real renames/links; no filesystem result or deletion is stubbed.
python3 - "$ROOT/bin/fm-disk-cache-clear.py" "$TMP_ROOT" <<'PY'
import os
import runpy
import sys
from pathlib import Path
from unittest.mock import patch

clean = runpy.run_path(sys.argv[1])["clear_cache"]
base = Path(sys.argv[2]).resolve()
for boundary in ("listdir", "open", "unlink"):
    for target in (".npm", ".npm/_cacache", ".npm/_cacache/child"):
        for replacement in ("link", "directory"):
            home = base / (boundary + target.replace("/", "-") + replacement)
            cache = home / ".npm/_cacache"
            (cache / "child").mkdir(parents=True)
            (cache / "child/keep").write_text("cache")
            victim = home / "preserved"
            (victim / "_cacache/child").mkdir(parents=True)
            (victim / "child").mkdir()
            for name in ("keep", "child/keep", "_cacache/child/keep"):
                (victim / name).write_text("protected")
            original = home / target
            moved = home / "moved"
            triggered = []
            real = getattr(os, boundary)
            listed_inode = os.stat(original if target.endswith("/child") else cache).st_ino

            def swap():
                if triggered:
                    return
                triggered.append(True)
                original.rename(moved)
                if replacement == "link":
                    original.symlink_to(victim, target_is_directory=True)
                else:
                    (original / "_cacache/child").mkdir(parents=True)
                    (original / "child").mkdir()
                    for name in ("keep", "child/keep", "_cacache/child/keep"):
                        (original / name).write_text("replacement")

            def operation(*args, **kwargs):
                # listdir: cache opened and validated, before enumerating it.
                # open: child stat validated, before its no-follow open.
                # unlink: all identity checks passed, immediately before removal.
                if boundary == "listdir" and os.fstat(args[0]).st_ino == listed_inode:
                    swap()
                elif boundary == "open" and args[0] == "child":
                    swap()
                elif boundary == "unlink":
                    swap()
                return real(*args, **kwargs)

            try:
                with patch.object(os, boundary, operation):
                    clean(str(home), ".npm/_cacache")
            except OSError:
                pass
            else:
                raise AssertionError(("replacement was not refused", boundary, target, replacement))
            assert triggered, (boundary, target, replacement)
            for name in ("keep", "child/keep", "_cacache/child/keep"):
                assert (victim / name).read_text() == "protected"
                if replacement == "directory":
                    assert (original / name).read_text() == "replacement"
print("18 real directory replacements preserved data outside pinned cache handles")
PY
pass 'ancestor, cache-root and child replacements cannot redirect deletion'

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
[ "$(wc -l < "$case_home/user/docker-calls" | tr -d ' ')" = 3 ] || fail 'image failure skipped builder prune'
pass 'Docker failures alert while both prunes and other caches are processed'

for prune in image builder; do
  new_case "${prune}_failure"
  printf 'cache=docker\n' > "$case_home/fm/config/disk-guard"
  touch "$case_home/user/$prune-fail"
  if run_guard; then fail "$prune failure reported success"; fi
  cmp "$TMP_ROOT/expected-docker" "$case_home/user/docker-calls" || fail "$prune failure skipped a prune"
  grep -q 'failures=1' "$case_home/fm/state/.wake-queue" || fail "$prune failure not alerted"
done
pass 'each Docker prune failure is retained without skipping the other prune'

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
