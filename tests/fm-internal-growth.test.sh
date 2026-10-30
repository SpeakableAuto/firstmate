#!/usr/bin/env bash
# Behavior tests for bin/fm-internal-growth.sh with a fake du over fixture sizes.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-internal-growth)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
# Fake du: prints fixture rows ("<KiB><TAB><path>") from $DU_FIXTURE for
# `-xk -d N <scan>` (rows at or below scan within N levels) and `-xk -s <paths>`.
cat > "$FAKEBIN/du" <<'SH'
#!/usr/bin/env bash
[ ! -e "$DU_FIXTURE.fail" ] || { echo 'du: fixture failure' >&2; exit 1; }
[ ! -e "$DU_FIXTURE.slow" ] || exec sleep 5
printf '%s\n' "$*" >> "$DU_FIXTURE.calls"
shift
if [ "$1" = -d ]; then
  depth=$2 scan=$3
  awk -F '\t' -v scan="$scan" -v depth="$depth" '
    $2 == scan { print; next }
    index($2, scan "/") == 1 {
      rest = substr($2, length(scan) + 2)
      if (split(rest, parts, "/") <= depth) print
    }' "$DU_FIXTURE"
else
  shift
  for path in "$@"; do awk -F '\t' -v p="$path" '$2 == p' "$DU_FIXTURE"; done
fi
[ ! -e "$DU_FIXTURE.unreadable" ] || {
  while IFS= read -r path; do printf 'du: %s: Operation not permitted\n' "$path" >&2; done < "$DU_FIXTURE.unreadable"
  exit 1
}
SH
cat > "$FAKEBIN/df" <<'SH'
#!/usr/bin/env bash
read -r used free < "$DF_FIXTURE"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fixture 999999999 %s %s 1%% %s\n' "$used" "$free" "${*: -1}"
SH
chmod +x "$FAKEBIN/du" "$FAKEBIN/df"
GIB=1048576

new_case() {
  case_dir="$TMP_ROOT/$1"
  fm="$case_dir/fm"
  scan="$case_dir/scan"
  mkdir -p "$fm/config" "$fm/state" "$scan"
  printf '1000000 100000000\n' > "$case_dir/df"
  cat > "$fm/config/internal-growth" <<EOF
volume=$case_dir
scan=$scan
allow=$scan/allowed
depth=2
min_baseline_hours=0
EOF
}
usage() { printf '%s %s\n' "$1" "$2" > "$case_dir/df"; }
# sizes <path-suffix>=<KiB> ...: rewrite the fixture; the scan total is the sum.
sizes() {
  local total=0 pair
  : > "$case_dir/du"
  for pair in "$@"; do
    printf '%s\t%s\n' "${pair#*=}" "$scan/${pair%%=*}" >> "$case_dir/du"
    case "${pair%%=*}" in */*) ;; *) total=$((total + ${pair#*=})) ;; esac
  done
  printf '%s\t%s\n' "$total" "$scan" >> "$case_dir/du"
}
run_check() {
  env FM_HOME="$fm" FM_WAKE_QUEUE="${wake_queue:-$fm/state/.wake-queue}" \
    FM_WAKE_QUEUE_LOCK="$fm/state/.wake-queue.lock" DU_FIXTURE="$case_dir/du" \
    DF_FIXTURE="$case_dir/df" PATH="$FAKEBIN:$PATH" bash "$ROOT/bin/fm-internal-growth.sh" "$@"
}
wakes() {
  [ -f "$fm/state/.wake-queue" ] || { echo 0; return; }
  grep -c 'check: internal-growth:' "$fm/state/.wake-queue" || true
}
last_log() { tail -n1 "$fm/state/internal-growth/log.jsonl"; }

new_case growth
sizes a=100 a/deep=50 allowed=10 b=10 c=0 c/x=0 c/y=0
run_check
assert_equals 0 "$(wakes)" 'first run only records a baseline'
assert_equals created "$(last_log | jq -r .baseline)" 'baseline creation is logged'
pass 'first run records a baseline without alerting'

sizes a=$((100 + 2 * GIB)) a/deep=$((50 + 2 * GIB)) allowed=$((10 + 5 * GIB)) b=$((10 + GIB / 2)) \
  c=$((GIB * 6 / 5)) c/x=$((GIB * 3 / 5)) c/y=$((GIB * 3 / 5))
run_check
assert_equals 1 "$(wakes)" 'one wake for the new episodes'
flagged=$(last_log | jq -r '[.flagged[].path] | sort | join(" ")')
assert_equals "$scan/a/deep $scan/c" "$flagged" 'deepest folders over the threshold are flagged; allowed and small growth are not'
assert_contains "$(cat "$fm/state/.wake-queue")" "$scan/a/deep (+2.0 GiB)" 'alert names the folder and growth'
case "$(cat "$fm/state/.wake-queue")" in *"$scan/allowed"*|*"$scan/b "*) fail 'alert named an allowed or small folder' ;; esac
pass 'growth over the threshold outside the allowed list alerts once'

grow_more() {
  sizes a=$((100 + $1 * GIB)) a/deep=$((50 + $1 * GIB)) allowed=$((10 + 5 * GIB)) b=$((10 + GIB / 2)) \
    c=$((GIB * 6 * $2 / 5)) c/x=$((GIB * 3 * $2 / 5)) c/y=$((GIB * 3 * $2 / 5))
}
grow_more 4 2
run_check
assert_equals 1 "$(wakes)" 'open episodes stay silent'
assert_equals '[]' "$(last_log | jq -c .new)" 'no new episodes logged'
assert_equals 2 "$(last_log | jq '.flagged | length')" 'the open episodes are still flagged'
pass 'continued growth does not repeat the alert'

run_check
assert_equals 0 "$(last_log | jq '.flagged | length')" 'no growth closes the episodes'
[ ! -s "$fm/state/internal-growth/episodes.tsv" ] || fail 'closed episodes remain open'
grow_more 6 2
run_check
assert_equals 2 "$(wakes)" 'growth after an episode closed alerts again'
pass 'an episode closes when growth stops and a new one alerts again'

new_case allowed_removed
printf '%s\t%s\n%s\t%s\n' "$((5 * GIB))" "$scan/allowed" "$((5 * GIB))" "$scan" > "$case_dir/du"
run_check
printf '%s\t%s\n' "$((2 * GIB))" "$scan" > "$case_dir/du"
run_check
assert_equals "$scan" "$(last_log | jq -r '.flagged[0].path')" 'removed allowed data does not mask root growth'
assert_equals "$((2 * GIB))" "$(last_log | jq -r '.flagged[0].growth_kib')" 'missing allowed path is treated as zero'
pass 'allowed deltas use the union of baseline and current paths'

new_case unreadable
mkdir -p "$scan/protected"
sizes a=1
printf '%s\n' "$scan/protected" > "$case_dir/du.unreadable"
run_check
assert_equals 1 "$(wakes)" 'an unreadable folder opens one episode'
assert_equals "$scan/protected" "$(last_log | jq -r '.unmeasured[0]')" 'the log lists the unreadable folder'
assert_contains "$(cat "$fm/state/.wake-queue")" "UNMEASURED: $scan/protected" 'the alert identifies the unreadable folder'
run_check
assert_equals 1 "$(wakes)" 'an ongoing unreadable episode stays silent'
sizes a=$((2 * GIB + 1))
run_check
assert_equals 2 "$(wakes)" 'new growth alerts beside an open unreadable episode'
assert_contains "$(tail -n1 "$fm/state/.wake-queue")" "UNMEASURED: $scan/protected" 'every alert lists current unreadable folders'
pass 'nonzero du with a root total records UNMEASURED without failing'

new_case unexplained
sizes a=1
usage 1000000 100000000
run_check
usage $((1000000 + 2 * GIB)) $((100000000 - 2 * GIB))
run_check
assert_equals unexplained-volume "$(last_log | jq -r '.flagged[0].kind')" 'unexplained volume growth opens its own episode'
assert_contains "$(cat "$fm/state/.wake-queue")" 'unexplained volume growth (+2.0 GiB)' 'the alert names unexplained growth'
pass 'df volume growth outside measured folders alerts'

new_case explained
sizes a=1
usage 1000000 100000000
run_check
sizes a=$((2 * GIB + 1))
usage $((1000000 + 2 * GIB)) $((100000000 - 2 * GIB))
run_check
assert_equals folder "$(last_log | jq -r '.flagged[0].kind')" 'measured folder growth remains the primary finding'
assert_equals 0 "$(last_log | jq '[.flagged[] | select(.kind == "unexplained-volume")] | length')" 'explained volume growth is not duplicated'
pass 'flagged folder growth is not repeated as unexplained volume growth'

new_case measurement
sizes a=1
run_check
touch "$case_dir/du.fail"
set +e; run_check 2>/dev/null; rc=$?; set -e
assert_equals 1 "$rc" 'failed measurement exits 1'
assert_equals 1 "$(wakes)" 'failed measurement alerts'
assert_contains "$(tail -n1 "$fm/state/.wake-queue")" 'could not measure' 'measurement alert is named'
set +e; run_check 2>/dev/null; set -e
assert_equals 1 "$(wakes)" 'repeated measurement failure stays silent'
rm "$case_dir/du.fail"
pass 'measurement failure is one alerted episode'

new_case undelivered
sizes a=1
run_check
sizes a=$((2 * GIB))
: > "$case_dir/blocker"
set +e; wake_queue="$case_dir/blocker/queue" run_check 2>/dev/null; rc=$?; set -e
assert_equals 1 "$rc" 'undelivered alert exits 1'
[ ! -s "$fm/state/internal-growth/episodes.tsv" ] || fail 'undelivered alert opened an episode'
sizes a=$((4 * GIB))
run_check
assert_equals 1 "$(wakes)" 'the next run retries the alert'
pass 'an alert that cannot be queued is retried next run'

new_case slow
sizes a=1
echo timeout_seconds=1 >> "$fm/config/internal-growth"
touch "$case_dir/du.slow"
started=$(date +%s)
set +e; run_check 2>/dev/null; rc=$?; set -e
[ $(($(date +%s) - started)) -lt 5 ] || fail 'a slow measurement was not cut off'
assert_equals 1 "$rc" 'a measurement over budget exits 1'
assert_contains "$(cat "$fm/state/.wake-queue")" 'du exceeded the 1 second budget' 'over-budget measurement alerts'
pass 'a measurement over its budget is killed and alerts'

new_case dry
sizes a=1
out=$(run_check --dry-run)
assert_equals created "$(printf '%s\n' "$out" | jq -r .baseline)" 'dry run reports the measurement'
[ ! -e "$fm/state/internal-growth" ] || fail 'dry run wrote state'
printf 'volume=%s\nscan=%s\nscan=%s/a\n' "$case_dir" "$scan" "$scan" > "$fm/config/internal-growth"
set +e; run_check >/dev/null 2>&1; rc=$?; set -e
assert_equals 2 "$rc" 'overlapping scan paths are invalid'
printf 'volume=%s\nscan=%s\nexclude=%s/protected\n' "$case_dir" "$scan" "$scan" > "$fm/config/internal-growth"
set +e; run_check >/dev/null 2>&1; rc=$?; set -e
assert_equals 2 "$rc" 'exclude is not an accepted blind spot'
pass 'dry run writes nothing and invalid configuration refuses'
