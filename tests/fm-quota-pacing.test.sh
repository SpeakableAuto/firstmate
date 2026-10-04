#!/usr/bin/env bash
# Exercise the public pacing calculator with fixed windows and percentages.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-quota-pacing.mjs"
TMP_ROOT=$(fm_test_tmproot fm-quota-pacing)
CONFIG="$TMP_ROOT/config.json"
SNAPSHOT="$TMP_ROOT/snapshot.json"
NOW=1893456000

cat > "$CONFIG" <<'JSON'
{"quota_pacing":{"accounts":[
  {"provider":"vendor","account_key":"first","scope":"all_models","window_id":"weekly","window_seconds":1000,"floor_percent":40,"max_concurrent":3},
  {"provider":"vendor","account_key":"second","scope":"all_models","window_id":"weekly","window_seconds":1000,"floor_percent":40,"max_concurrent":3}
]}}
JSON

write_snapshot() { # first remaining, second remaining
  cat > "$SNAPSHOT" <<JSON
{"providers":[
  {"provider":"vendor","accountKey":"first","state":{"stale":false},
   "windows":[{"id":"weekly","percentRemaining":$1,"resetsAt":"2030-01-01T00:08:20Z"}],
   "quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":$1}]}},
  {"provider":"vendor","accountKey":"second","state":{"stale":false},
   "windows":[{"id":"weekly","percentRemaining":$2,"resetsAt":"2030-01-01T00:08:20Z"}],
   "quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":$2}]}}
]}
JSON
}

write_snapshot 80 50
out=$(node "$TOOL" "$CONFIG" "$SNAPSHOT" "$NOW")
assert_equals '70' "$(jq -r '.accounts[0].pathPercent' <<<"$out")" "halfway path ends at configured floor"
assert_equals 'ahead:3' "$(jq -r '.accounts[0] | "\(.state):\(.allowedConcurrency)"' <<<"$out")" "ahead account runs at its configured cap"
assert_equals 'behind:1' "$(jq -r '.accounts[1] | "\(.state):\(.allowedConcurrency)"' <<<"$out")" "behind account slows to one"
pass "ahead and behind accounts follow the linear reset path"

write_snapshot 69.9 80
out=$(node "$TOOL" "$CONFIG" "$SNAPSHOT" "$NOW")
assert_equals 'behind:2' "$(jq -r '.accounts[0] | "\(.state):\(.allowedConcurrency)"' <<<"$out")" "even slightly behind lowers concurrency"

write_snapshot 41 40
out=$(node "$TOOL" "$CONFIG" "$SNAPSHOT" "$NOW")
assert_equals 'behind:1' "$(jq -r '.accounts[0] | "\(.state):\(.allowedConcurrency)"' <<<"$out")" "near floor retains one crew"
assert_equals 'at_floor:0' "$(jq -r '.accounts[1] | "\(.state):\(.allowedConcurrency)"' <<<"$out")" "the floor itself preserves its reserve"
write_snapshot 39 80
out=$(node "$TOOL" "$CONFIG" "$SNAPSHOT" "$NOW")
assert_equals 'below_floor:0' "$(jq -r '.accounts[0] | "\(.state):\(.allowedConcurrency)"' <<<"$out")" "below floor blocks crew"
pass "the configured floor slows before blocking and caps concurrency at three"

jq '.providers[0].windows[0].resetsAt = null' "$SNAPSHOT" > "$SNAPSHOT.next"
mv "$SNAPSHOT.next" "$SNAPSHOT"
out=$(node "$TOOL" "$CONFIG" "$SNAPSHOT" "$NOW")
assert_equals 'unknown:null' "$(jq -r '.accounts[0] | "\(.state):\(.allowedConcurrency)"' <<<"$out")" "missing reset stays unknown"
pass "incomplete reset evidence never fabricates pacing headroom"

jq '.quota_pacing.accounts[0].max_concurrent = 0' "$CONFIG" > "$CONFIG.bad"
node "$TOOL" "$CONFIG.bad" "$SNAPSHOT" "$NOW" > "$TMP_ROOT/bad.out" 2> "$TMP_ROOT/bad.err"
rc=$?
expect_code 2 "$rc" "invalid concurrency configuration refuses"
assert_contains "$(cat "$TMP_ROOT/bad.err")" 'invalid quota_pacing account settings' "invalid settings report a concrete error"
pass "invalid opt-in settings fail closed"
