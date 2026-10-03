#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-resolve.sh.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv, the request body it read from stdin, and the header it
# read from file descriptor 3, and answers with a canned typesafe.ai response.
# A fake quota-axi serves the selected schema-5 fixture. No case touches the
# network, and the absent-key case proves the tool makes no call
# at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-dispatch-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NO_CURL_BIN="$TMP_ROOT/no-curl-bin"
LOG="$TMP_ROOT/log"
BRIEF="$TMP_ROOT/brief.md"
BASE_RULES="$TMP_ROOT/rules.json"
RULES="$HOME_DIR/config/crew-dispatch.json"
QUOTA="$TMP_ROOT/quota.json"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/config" "$LOG" "$NO_CURL_BIN"
for command_name in bash chmod cp dirname jq mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_CURL_BIN/$command_name"
done

cat > "$BRIEF" <<'MD'
# Task
Fix the off-by-one in the pager: root cause is the `<=` on line 40 of pager.sh, expected behavior is one page per call.
MD

cat > "$BASE_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "New feature work on the app.",
      "floor": { "scope": "model:fable", "min_percent": 20, "provider": "claude" },
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" },
      "why": "SECRET-WHY-TEXT feature work wants the strongest model"
    },
    {
      "when": "The task generates images.",
      "use": [
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
        { "harness": "codex", "model": "gpt-5.6-sol", "floor": { "scope": "all_models", "min_percent": 50 } }
      ]
    },
    {
      "when": "Genuinely very difficult design or planning work.",
      "approval": "captain",
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" }
    },
    {
      "when": "A simple bug fix with a stated root cause.",
      "use": [
        { "harness": "claude", "model": "sonnet", "effort": "high" },
        { "harness": "cursor", "model": "cursor-grok-4.6-medium" },
        { "harness": "kimi", "model": "kimi-code/k3" }
      ]
    }
  ],
  "default": [
    { "harness": "claude", "model": "opus" },
    { "harness": "cursor", "model": "cursor-grok-4.6-high" }
  ]
}
JSON
cp "$BASE_RULES" "$RULES"

write_quota() {  # <path> <cursor spendPriority> [<claude all_models spendPriority>]
  local path=$1 cursor=$2 claude=${3:--0.4627}
  cat > "$path" <<JSON
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "claude", "state": { "status": "fresh", "stale": false }, "windows": [ { "id": "five_hour", "kind": "session", "percentRemaining": 79 } ], "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 79, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": $claude } },
      { "scope": "model:fable", "status": "known", "effectivePercentRemaining": 15, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -0.79 } } ] } },
    { "provider": "codex", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 31, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -0.1649 } } ] } },
    { "provider": "cursor", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 91, "runway": { "status": "through_reset" }, "selection": { "spendPriority": $cursor } } ] } },
    { "provider": "agy", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 64, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.4 } } ] } },
    { "provider": "google", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 72, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.3 } } ] } },
    { "provider": "kimi", "state": { "status": "unknown" }, "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } }
  ]
}
JSON
}
write_quota "$QUOTA" 0.7597

set_runway() {  # <path> <provider> <runway status>
  jq --arg p "$2" --arg r "$3" '(.providers[] | select(.provider == $p) | .quotaSemantics.effectiveAvailability[].runway.status) = $r' "$1" > "$1.tmp" \
    && mv "$1.tmp" "$1"
}

write_response() {  # <path> <choice> <confidence>
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "rule_1": 0.01, "rule_2": 0.01, "rule_3": 0.01, "rule_4": 0.96, "default": 0.01 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
}

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: records argv (minus the -o target), the stdin body, and the header
# read from fd 3, then answers with FAKE_CURL_RESPONSE and FAKE_CURL_HTTP.
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'curl:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'curl:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
if [ -n "${FAKE_CURL_MUTATE_SOURCE:-}" ]; then
  cp "$FAKE_CURL_MUTATE_SOURCE" "${FAKE_CURL_MUTATE_TARGET:?}"
fi
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'quota-axi:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'quota-axi:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
[ "${FAKE_QUOTA_FAIL:-0}" = 1 ] && exit 1
[ "${1:-}" = --json ] || exit 2
case "$*" in
  *--max-age*)
    if [ -n "${QUOTA_AXI_RECOVERY_FIXTURE:-}" ]; then cat "$QUOTA_AXI_RECOVERY_FIXTURE"; exit; fi ;;
esac
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"

RESPONSE="$TMP_ROOT/response.json"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" QUOTA_AXI_CALLS="$LOG/quota-axi.calls" QUOTA_AXI_FIXTURE="$QUOTA" CHILD_ENV_LOG="$LOG/child-env"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run <exit-var> <out-var> <err-var> [args...]: the tool with fakebin first on
# PATH and an isolated FM_HOME; TYPESAFE_API_KEY comes from the caller's env.
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  # Each call starts with no recent placements unless a case keeps them.
  [ "${KEEP_LEDGER:-0}" = 1 ] || rm -f "$HOME_DIR/state/dispatch-charges.jsonl"
  _out=$(env -u CLAUDE_CONFIG_DIR -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
    PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

run_without_curl() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$NO_CURL_BIN" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

KEY='test-key-9f1c2d3e-never-on-argv'
code='' out='' err=''

# --- absent key: off, silent on stdout, no network, no quota read -----------
reset_log
write_response "$RESPONSE" rule_4 0.9
run code out err "$BRIEF" --project pager
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing on stdout"
assert_contains "$err" 'dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and' "absent key explains itself on stderr"
assert_absent "$LOG/argv" "absent key never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent key never reads quota-axi"
pass "absent key is off: one stderr line, exit 0, no network call"

# --- .env key, and the environment wins over it ------------------------------
printf '%s\n' '# local secrets' 'FMX_PAIRING_TOKEN=abc' "export TYPESAFE_API_KEY=\"$KEY\"" > "$HOME_DIR/.env"
reset_log
run code out err "$BRIEF" --project pager
expect_code 0 "$code" ".env key resolves"
assert_contains "$out" '  status: clear' ".env key produces a clear result"
assert_contains "$(cat "$LOG/header")" "Authorization: Bearer $KEY" ".env key reaches curl on the fd header"
reset_log
TYPESAFE_API_KEY=env-wins run code out err "$BRIEF" --project pager
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "environment key wins over .env"
rm -f "$HOME_DIR/.env"
OVERRIDE_CONFIG="$TMP_ROOT/override-config"
mkdir -p "$OVERRIDE_CONFIG"
cp "$BASE_RULES" "$OVERRIDE_CONFIG/crew-dispatch.json"
reset_log
TYPESAFE_API_KEY=$KEY FM_CONFIG_OVERRIDE="$OVERRIDE_CONFIG" run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "FM_CONFIG_OVERRIDE selects the canonical rules directory"
pass "TYPESAFE_API_KEY= in .env activates the tool; environment and config overrides work"

# --- clear: request shape, secret handling, argmax --------------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "clear exits 0"
assert_contains "$out" 'dispatch-resolve:' "TOON block header"
assert_contains "$out" '  status: clear' "clear status"
assert_contains "$out" '  rule: rule_4 (A simple bug fix with a stated root cause.)   confidence: 0.9' "rule and confidence line"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "argmax picks the highest spendPriority"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible' "every candidate is accounted for"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  provider=kimi  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty' "unmeasured provider stays listed as eligible and unranked"
assert_contains "$out" '  note: 1 eligible candidate(s) unranked (kimi)' "clear results flag eligible unranked candidates once"
assert_not_contains "$out" '--effort' "cursor profile without effort emits no --effort"
argv=$(cat "$LOG/argv")
assert_not_contains "$argv" "$KEY" "the key never appears on curl argv"
assert_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "the request uses the fixed typesafe.ai endpoint"
assert_contains "$argv" $'--max-time\n5' "the request uses the fixed five-second timeout"
assert_contains "$argv" '@/dev/fd/3' "the header is read from a file descriptor"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "curl receives the bearer header on fd 3"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "the API key is absent from every child environment"
body=$(cat "$LOG/body")
assert_equals 'jev-latest' "$(jq -r .model <<<"$body")" "default model is jev-latest"
assert_equals 'pager' "$(jq -r .state.task.project <<<"$body")" "project rides in the state"
assert_contains "$(jq -r .state.task.brief <<<"$body")" 'off-by-one in the pager' "a brief without task headings rides whole in the state"
assert_equals '["rule"]' "$(jq -c '.questions | keys' <<<"$body")" "only the rule Choice is asked"
assert_equals '["default","rule_1","rule_2","rule_3","rule_4"]' "$(jq -c '.questions.rule.criteria | keys' <<<"$body")" "one option per rule plus default"
assert_equals 'No listed rule applies to this task.' "$(jq -r '.questions.rule.criteria.default' <<<"$body")" "the fixed generic none criterion is the default option"
assert_equals 'A simple bug fix with a stated root cause.' "$(jq -r '.questions.rule.criteria.rule_4' <<<"$body")" "rule when text is the option verbatim"
assert_not_contains "$body" 'SECRET-WHY-TEXT' "why text never leaves the machine"
assert_not_contains "$body" 'spendPriority' "quota never leaves the machine"
assert_not_contains "$body" 'cursor-grok' "use profiles never leave the machine"
pass "clear: one rule Choice request, key on the fd header only, spendPriority argmax over every candidate"

# --- optional pacing: reset preference, hard floor, and mirror queue ----------
soon=$(node -e 'process.stdout.write(new Date(Date.now() + 3600000).toISOString())')
later=$(node -e 'process.stdout.write(new Date(Date.now() + 10800000).toISOString())')
jq '.rules[3].use = [
      {"harness":"claude","model":"sonnet","provider":"claude"},
      {"harness":"codex","model":"gpt-5.6-sol","provider":"codex"}
    ] |
    .quota_pacing.accounts = [
      {"provider":"claude","scope":"all_models","window_id":"weekly","window_seconds":7200,"floor_percent":20,"max_concurrent":3},
      {"provider":"codex","scope":"all_models","window_id":"weekly","window_seconds":14400,"floor_percent":20,"max_concurrent":3}
    ]' "$BASE_RULES" > "$RULES"
jq --arg soon "$soon" --arg later "$later" '
  .providers |= map(
    if .provider == "claude" then
      .windows += [{"id":"weekly","percentRemaining":79,"resetsAt":$soon}] |
      .quotaSemantics.effectiveAvailability[0].selection.spendPriority = 0.1 |
      .quotaSemantics.effectiveAvailability[0].runway.status = "through_reset"
    elif .provider == "codex" then
      .windows = [{"id":"weekly","percentRemaining":31,"resetsAt":$later}] |
      .quotaSemantics.effectiveAvailability[0].selection.spendPriority = 0.9 |
      .quotaSemantics.effectiveAvailability[0].runway.status = "through_reset"
    else . end
  )' "$QUOTA" > "$QUOTA.next" && mv "$QUOTA.next" "$QUOTA"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
assert_contains "$out" "profile: --harness 'claude' --model 'sonnet'" "soonest paced reset wins despite lower spend priority"
assert_contains "$out" 'pacing=ahead slots=3' "candidate output exposes pacing allowance"
assert_equals "$soon" "$(jq -r '.accounts[] | select(.provider == "claude") | .nextWindow' "$HOME_DIR/state/quota-pacing.json")" "mirror exposes the next window"
assert_equals '0' "$(jq '[.accounts[].queuedTaskIds[]] | length' "$HOME_DIR/state/quota-pacing.json")" "placed task is not queued"
for n in 1 2 3 4; do cp "$BRIEF" "$TMP_ROOT/pace-$n.md"; done
TYPESAFE_API_KEY=$KEY run code out err \
  "$TMP_ROOT/pace-1.md" --project pager "$TMP_ROOT/pace-2.md" --project pager \
  "$TMP_ROOT/pace-3.md" --project pager "$TMP_ROOT/pace-4.md" --project pager
assert_contains "$out" 'local:claude:sonnet=3' "paced account never exceeds three charged crews"
assert_contains "$out" 'local:codex:gpt-5.6-sol=1' "fourth task moves to another account"
jq '(.providers[] | select(.provider == "claude" or .provider == "codex") |
      .quotaSemantics.effectiveAvailability[0].effectivePercentRemaining) = 19 |
    (.providers[] | select(.provider == "claude" or .provider == "codex") |
      .windows[] | select(.id == "weekly") | .percentRemaining) = 19' "$QUOTA" > "$QUOTA.next"
mv "$QUOTA.next" "$QUOTA"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
assert_contains "$out" 'status: escalate' "below-floor candidates do not place"
assert_contains "$out" 'quota pacing at or below floor' "floor refusal is explained"
assert_equals '1' "$(jq '[.accounts[].queuedTaskIds[]] | length' "$HOME_DIR/state/quota-pacing.json")" "blocked task is queued for one reset"
assert_equals 'all_models' "$(jq -r '.accounts[] | select(.queuedTaskIds | length > 0) | .scope' "$HOME_DIR/state/quota-pacing.json")" "the task is queued on the scope that blocked it"
jq '.quota_pacing.accounts += [
      {"provider":"claude","scope":"model:sonnet","window_id":"weekly","window_seconds":7200,"floor_percent":79,"max_concurrent":3}
    ]' "$RULES" > "$RULES.next" && mv "$RULES.next" "$RULES"
jq '(.providers[] | select(.provider == "claude") |
      .quotaSemantics.effectiveAvailability[0].effectivePercentRemaining) = 79 |
    (.providers[] | select(.provider == "claude") |
      .windows[] | select(.id == "weekly") | .percentRemaining) = 79' "$QUOTA" > "$QUOTA.next"
mv "$QUOTA.next" "$QUOTA"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
assert_contains "$out" 'status: escalate' "a model-scoped pacing floor can block the selected model"
assert_equals 'model:sonnet' "$(jq -r '.accounts[] | select(.queuedTaskIds | length > 0) | .scope' "$HOME_DIR/state/quota-pacing.json")" "the task moves to the actual model-scoped blocker"
cp "$BASE_RULES" "$RULES"
write_quota "$QUOTA" 0.7597
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
assert_equals '0' "$(jq '.accounts | length' "$HOME_DIR/state/quota-pacing.json")" "accounts absent from the current pool are removed"
pass "paced dispatch prefers the next reset and publishes a blocked task queue"

# --- never-send list: a match or a bad list withholds the request -------------
NEVER_SEND="$HOME_DIR/config/dispatch-never-send"
PRIVATE_BRIEF="$TMP_ROOT/private-brief.md"
cat > "$PRIVATE_BRIEF" <<'MD'
# Task
## Captain's intent
Fix the pager for the Acme-Ledger account 4417-2290.

## Firstmate spec
- Keep the change small.
MD
expect_withheld() {  # <label> <stderr fragment> [<value that must not print>...]
  local label=$1 fragment=$2
  shift 2
  expect_code 0 "$code" "$label exits 0"
  assert_equals '' "$out" "$label prints nothing on stdout, so firstmate uses its existing intake"
  assert_contains "$err" "dispatch-resolve: off ($fragment" "$label names why on stderr"
  assert_contains "$err" 'nothing sent)' "$label says nothing was sent"
  assert_equals '1' "$(grep -c . <<<"$err")" "$label prints one diagnostic line"
  assert_absent "$LOG/argv" "$label never calls curl"
  assert_absent "$LOG/quota-axi.calls" "$label never reads quota"
  local value
  for value in "$@"; do
    assert_not_contains "$err" "$value" "$label never prints the listed value"
  done
}

printf '%s\n' '# private values' '' '   ' 'Unlisted-Value' > "$NEVER_SEND"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
assert_contains "$out" '  status: clear' "a list with no match leaves resolution unchanged"
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'Acme-Ledger' "a list with no match sends the task text"

printf '%s\n' '# private values' '' '  acme-ledger  ' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a case-insensitive literal match" "brief text matches $NEVER_SEND line 3" 'acme-ledger' 'Acme-Ledger'

WRAPPED_BRIEF="$TMP_ROOT/wrapped-brief.md"
printf '# Task\n## Captain'"'"'s intent\nFix the pager for Example Client\nLtd before\tthe\xc2\xa0release.\n' > "$WRAPPED_BRIEF"
printf '%s\n' 'example  client ltd' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$WRAPPED_BRIEF" --project pager
expect_withheld "a literal the brief wraps across lines" "brief text matches $NEVER_SEND line 1" 'example' 'Example'

printf '%s\n' 'before the release' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$WRAPPED_BRIEF" --project pager
expect_withheld "a literal the brief spaces with a tab and a no-break space" "brief text matches $NEVER_SEND line 1" 'release'

printf '%s\n' 'orion-private' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project orion-private
expect_withheld "a project-name match" "brief text matches $NEVER_SEND line 1" 'orion-private'

printf '%s\n' 'stated root cause' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_withheld "a rule-criterion match" "brief text matches $NEVER_SEND line 1" 'stated root cause'

SECOND_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SECOND_HOME/config"
printf '%s\n' 'acme-ledger' > "$NEVER_SEND"
# A child shell keeps the lib's own globals (such as out) out of this script
# shellcheck disable=SC2016 # Expanded by the child shell
bash -c '. "$1" && propagate_inheritable_config "$2" "$3"' _ \
  "$ROOT/bin/fm-config-inherit-lib.sh" "$HOME_DIR/config" "$SECOND_HOME/config" \
  || fail "inheritance into the secondmate home failed"
PRIMARY_HOME=$HOME_DIR
HOME_DIR=$SECOND_HOME
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "an inherited list in a secondmate home" "brief text matches $SECOND_HOME/config/dispatch-never-send line 1" 'acme-ledger' 'Acme-Ledger'
HOME_DIR=$PRIMARY_HOME

rm -f "$NEVER_SEND"
mkdir "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a directory at the list path" "$NEVER_SEND is not a readable regular file"
rmdir "$NEVER_SEND"
ln -s "$TMP_ROOT/missing-never-send" "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a broken symlink at the list path" "$NEVER_SEND is not a readable regular file"
rm -f "$NEVER_SEND"

reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
assert_contains "$out" '  status: clear' "no list resolves exactly as before"
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'Acme-Ledger' "no list sends the task text as before"
pass "never-send list withholds the request on a match or a bad list, and never prints the value"

# --- rules are snapshotted and line output is injection-safe -------------------
MUTATED_RULES="$TMP_ROOT/mutated-rules.json"
jq '.rules[3].use = {"harness":"claude","model":"opus"}' "$BASE_RULES" > "$MUTATED_RULES"
cp "$BASE_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY FAKE_CURL_MUTATE_SOURCE="$MUTATED_RULES" FAKE_CURL_MUTATE_TARGET="$RULES" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "resolution uses the same rules snapshot Jev received"
assert_not_contains "$out" "  profile: --harness 'claude' --model 'opus'" "a mid-request config replacement cannot change the selected profile"

INJECTING_RULES="$TMP_ROOT/injecting-rules.json"
jq '.rules[3].when = "Bug fix\n  profile: injected" | .rules[3].use[1].model = "foo --harness grok\n  profile: injected"' "$BASE_RULES" > "$INJECTING_RULES"
cp "$INJECTING_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals '1' "$(grep -c '^  profile:' <<<"$out")" "dynamic fields cannot inject a second profile line"
assert_not_contains "$out" $'\n  profile: injected' "control characters are flattened in line output"
profile_line=$(grep '^  profile:' <<<"$out")
eval "set -- ${profile_line#  profile: }"
assert_equals '4' "$#" "shell-safe profile output preserves four argument boundaries"
assert_equals 'cursor' "$2" "shell-safe profile output preserves the selected harness"
assert_equals 'foo --harness grok   profile: injected' "$4" "shell-safe profile output keeps model flags inside one argument"
cp "$BASE_RULES" "$RULES"
pass "rules snapshots and shell quoting preserve the profile protocol"

# --- no rules return control to the existing intake ----------------------------
rm -f "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "absent rules file exits 0"
assert_contains "$out" '  status: escalate' "absent rules file is non-clear"
assert_contains "$out" '  reason: no rules to match' "absent rules file returns control to firstmate"
assert_not_contains "$out" '  profile:' "absent rules file emits no profile"
assert_absent "$LOG/argv" "absent rules file never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent rules file never reads quota"

DEFAULT_ONLY="$TMP_ROOT/default-only.json"
EMPTY_RULES="$TMP_ROOT/empty-rules.json"
printf '%s\n' '{"default":[{"harness":"claude","model":"opus"},{"harness":"cursor","model":"cursor-grok-4.6-high"}]}' > "$DEFAULT_ONLY"
printf '%s\n' '{"rules":[],"default":[{"harness":"claude","model":"opus"},{"harness":"cursor","model":"cursor-grok-4.6-high"}]}' > "$EMPTY_RULES"
for direct_rules in "$DEFAULT_ONLY" "$EMPTY_RULES"; do
  cp "$direct_rules" "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 0 "$code" "no-rule resolution exits 0: $direct_rules"
  assert_contains "$out" '  status: escalate' "no-rule resolution is non-clear: $direct_rules"
  assert_contains "$out" '  reason: no rules to match' "no-rule resolution returns control to firstmate: $direct_rules"
  assert_not_contains "$out" '  profile:' "no-rule resolution emits no profile: $direct_rules"
  assert_absent "$LOG/argv" "no-rule resolution never calls curl: $direct_rules"
  assert_absent "$LOG/quota-axi.calls" "no-rule resolution never reads quota: $direct_rules"
done

AGY_RULE="$TMP_ROOT/agy-rule.json"
printf '%s\n' '{"rules":[{"when":"Agy work.","use":{"harness":"agy"}}]}' > "$AGY_RULE"
cp "$AGY_RULE" "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.99,"probabilities":{"rule_1":0.99,"default":0.01}}},"usage":{"input_tokens":100,"output_tokens":60}}
JSON
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: agy:-  provider=agy  scope=all_models  remaining=64%  spendPriority=0.4  runway=through_reset  -> eligible' "agy uses its resolver-only authoritative quota provider"
assert_contains "$out" "  profile: --harness 'agy'" "provider-less agy rule resolves"

GEMINI_RULE="$TMP_ROOT/gemini-rule.json"
printf '%s\n' '{"rules":[{"when":"Gemini work.","use":{"harness":"gemini","model":"gemini-3.8-flash-high","provider":"google"}}]}' > "$GEMINI_RULE"
cp "$GEMINI_RULE" "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: gemini:gemini-3.8-flash-high  provider=google  scope=all_models  remaining=72%  spendPriority=0.3  runway=through_reset  -> eligible' "Gemini resolves through its explicit provider"
assert_contains "$out" "  profile: --harness 'gemini' --model 'gemini-3.8-flash-high'" "Gemini is a typed verified dispatch harness"

cp "$ROOT/docs/examples/crew-dispatch.json" "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"default","confidence":0.9,"probabilities":{"rule_1":0.02,"rule_2":0.02,"rule_3":0.02,"default":0.94}}},"usage":{"input_tokens":812,"output_tokens":60}}
JSON
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "the documented example passes opted-in resolution"
assert_contains "$out" 'candidate: pi:anthropic/claude-sonnet-5  provider=claude' "the documented Pi default uses its declared Claude provider"
assert_not_contains "$err" 'malformed rules file' "the documented example reaches resolution"
cp "$BASE_RULES" "$RULES"
pass "no-rule fallback, Agy, Gemini, and documented configurations resolve"

# --- ambiguous: fixed confidence floor -----------------------------------------
reset_log
write_response "$RESPONSE" rule_4 0.41
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "ambiguous exits 0"
assert_contains "$out" '  status: ambiguous' "below the floor is ambiguous"
assert_contains "$out" '  reason: confidence 0.41 below floor 0.6' "ambiguous names the floor"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible' "ambiguous preserves matched candidate evidence"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  provider=kimi  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty' "ambiguous preserves eligible unranked candidate evidence"
assert_not_contains "$out" '  profile:' "ambiguous emits no profile line"
pass "ambiguous: confidence below the fixed floor hands the decision back"

# --- per-rule confidence floor ------------------------------------------------
write_floor_response() {  # <path> <choice> <confidence> <rule_1> <rule_2> <rule_3> <rule_4> <default>
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "rule_1": $4, "rule_2": $5, "rule_3": $6, "rule_4": $7, "default": $8 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
}
FLOOR_RULES="$TMP_ROOT/floor-rules.json"
jq '.rules[1].min_confidence = 0.9 | .rules[3].min_confidence = 0.1' "$BASE_RULES" > "$FLOOR_RULES"
cp "$FLOOR_RULES" "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.02 0.76 0.02 0.18 0.02
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a top rule below its own floor falls to a runner-up that clears its floor"
assert_contains "$out" '  rule: rule_2 (The task generates images.)   confidence: 0.76' "the model's own pick stays visible"
assert_contains "$out" '  fallback: rule_4 (A simple bug fix with a stated root cause.) probability 0.18 clears its floor 0.1; rule_2 probability 0.76 is below its floor 0.9' "the fallback names both floors"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the runner-up rule's profiles are resolved"
assert_not_contains "$(cat "$LOG/body")" 'min_confidence' "the model never sees confidence floors"

reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.02 0.76 0.02 0.08 0.12
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "no runner-up clearing its own floor is ambiguous"
assert_contains "$out" '  reason: rule_2 probability 0.76 below its floor 0.9; no other option clears its own floor' "the undeclared default keeps the global floor as a runner-up"
assert_not_contains "$out" '  fallback:' "no fallback is reported when none is taken"
assert_not_contains "$out" '  profile:' "ambiguous per-rule floor emits no profile"

jq '.rules[0].min_confidence = 0.1' "$FLOOR_RULES" > "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.12 0.76 0.0 0.12 0.0
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "equally probable runner-ups never break by option order"
assert_contains "$out" '  reason: rule_2 probability 0.76 below its floor 0.9; runner-up tie' "a runner-up tie is named"

cp "$FLOOR_RULES" "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_4 0.45 0.01 0.01 0.01 0.45 0.52
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "a declared floor below the global floor lets the picked rule resolve"

# A declared floor needs the same support from a rule as the pick or as a runner-up
jq '.rules[3].min_confidence = 0.3' "$FLOOR_RULES" > "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_4 0.25 0.25 0.05 0.05 0.35 0.30
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a picked rule clears its declared floor on its own probability, not the answer confidence"
assert_not_contains "$out" '  fallback:' "a picked rule that clears its own floor takes no fallback"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the picked rule resolves at probability 0.35 over floor 0.3"

reset_log
write_floor_response "$RESPONSE" rule_2 0.95 0.05 0.55 0.05 0.30 0.05
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a high answer confidence does not lift a picked rule over its own floor"
assert_contains "$out" '  fallback: rule_4 (A simple bug fix with a stated root cause.) probability 0.30 clears its floor 0.3; rule_2 probability 0.55 is below its floor 0.9' "the runner-up clears the same floor it would need as the pick"

reset_log
write_floor_response "$RESPONSE" rule_2 0.55 0.05 0.55 0.05 0.25 0.10
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a runner-up below its own floor is not taken"
assert_contains "$out" '  reason: rule_2 probability 0.55 below its floor 0.9; no other option clears its own floor' "the missed runner-up floor is named"
cp "$BASE_RULES" "$RULES"

reset_log
write_floor_response "$RESPONSE" rule_2 0.55 0.01 0.55 0.01 0.42 0.01
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "without declared floors a low pick stays ambiguous"
assert_contains "$out" '  reason: confidence 0.55 below floor 0.6' "without declared floors the global floor reason is unchanged"
assert_not_contains "$out" '  fallback:' "without declared floors no runner-up is taken"
pass "per-rule confidence floors fall to the most probable runner-up that clears its own floor"

# --- the model sees only the task-specific brief sections ----------------------
SCAFFOLD_BRIEF="$TMP_ROOT/scaffold-brief.md"
cat > "$SCAFFOLD_BRIEF" <<'MD'
# Task
## Captain's intent
Add a flag to the pager.

## Firstmate spec
Touch pager.sh only.
```sh
# Not a heading inside a fence
## Setup
```
### Out of scope
Anything else.

# Setup
BOILERPLATE-SETUP never push to the default branch.

## Captain intent authorized for --intent
BOILERPLATE-DUPLICATE
MD
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$SCAFFOLD_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' "the captain's intent section is sent"
assert_contains "$sent" $'## Firstmate spec\nTouch pager.sh only.' "the Firstmate spec section is sent"
assert_contains "$sent" $'# Not a heading inside a fence\n## Setup\n```\n### Out of scope\nAnything else.' "fenced lines and subheadings stay inside the section"
assert_not_contains "$sent" 'BOILERPLATE' "scaffold boilerplate after the task sections is not sent"
assert_not_contains "$sent" '# Task' "the enclosing Task heading is not sent"
assert_not_contains "$sent" 'Brief kind:' "a brief without a scout contract line gets no kind line"

SPEC_ONLY_BRIEF="$TMP_ROOT/spec-only-brief.md"
printf '%s\n' '# Task' '## Firstmate spec' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals $'## Firstmate spec\nSpec text.' "$(jq -r .state.task.brief "$LOG/body")" "one recognized section is enough"

printf '%s\n' '# Task' '## Firstmate spec   ' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a heading with trailing blanks is not a section, matching spawn validation"

printf '%s\n' 'Preamble.' '## Firstmate spec' 'Spec text.' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a section outside the Task heading is not a task section"

KIND_BRIEF="$TMP_ROOT/kind-brief.md"
{ cat "$SCAFFOLD_BRIEF"; printf '%s\n' '# Definition of done' 'Delivery contract: mode=no-mistakes' 'Delivery contract: mode=direct-PR'; } > "$KIND_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$KIND_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' "a ship brief still sends its task sections"
assert_not_contains "$sent" 'Brief kind:' "a ship brief gets no kind line"
assert_not_contains "$sent" 'mode=' "a ship brief's delivery mode is not sent"

{ cat "$SCAFFOLD_BRIEF"; printf '%s\n' 'This is a SCOUT task: the deliverable is a written report, not a PR.'; } > "$KIND_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$KIND_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'Brief kind: scout (report only)\n\n## Captain\'s intent' "a scout brief's contract line names its kind"
assert_not_contains "$sent" 'This is a SCOUT task' "the scout contract line itself is not sent"

reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals "$(cat "$BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a brief with neither heading is sent whole"
pass "only the brief's task sections and scout tag reach the model, with a whole-brief fallback"

# --- escalate: captain approval ------------------------------------------------
reset_log
write_response "$RESPONSE" rule_3 0.95
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "escalate exits 0"
assert_contains "$out" '  status: escalate' "approval-gated rule escalates"
assert_contains "$out" "  reason: rule requires the captain's explicit approval before dispatch" "escalate names the approval gate"
assert_contains "$out" 'candidate: claude:fable  provider=claude  scope=model:fable  remaining=15%  spendPriority=-0.79  runway=projected_exhaustion  bounds=all_models:79%/projected_exhaustion,model:fable:15%/projected_exhaustion  -> eligible' "approval escalation preserves matched candidate evidence"
assert_not_contains "$out" '  profile:' "escalate emits no profile line"
pass "escalate: a rule declared approval: captain never yields a profile"

# --- rule floor fails: fall through to default -------------------------------
reset_log
write_response "$RESPONSE" rule_1 0.97
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "rule floor fall-through still resolves"
assert_contains "$out" '  note: rule rule_1 floor model:fable below 20%: fall through to default' "rule floor fall-through is explained"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "fall-through resolves among the default profiles"
assert_not_contains "$out" 'candidate: claude:fable' "the floored rule's own profile is not a candidate"

MISSING_RULE_FLOOR="$TMP_ROOT/missing-rule-floor.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) |= map(select(.scope != "model:fable"))' "$QUOTA" > "$MISSING_RULE_FLOOR"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$MISSING_RULE_FLOOR" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "an unverifiable rule floor escalates"
assert_contains "$out" '  reason: rule rule_1 floor claude/model:fable is unverifiable' "the unverifiable rule floor names its provider and scope"
assert_not_contains "$out" '  profile:' "an unverifiable rule floor never authorizes default routing"
pass "rule floor: known shortfall falls through while unavailable evidence escalates"

# --- declared provider and profile floor --------------------------------------
reset_log
write_response "$RESPONSE" rule_2 0.99
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%' "declared provider routes a Pi profile to the codex row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  -> not eligible: profile floor all_models below 50%' "profile floor makes a candidate ineligible with its reason"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "the remaining eligible candidate wins"

FLOOR_BOUNDS="$TMP_ROOT/floor-bounds.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":10,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":-0.9}}
]' "$QUOTA" > "$FLOOR_BOUNDS"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$FLOOR_BOUNDS" run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:10%/projected_exhaustion  -> not eligible: profile floor all_models below 50%' "a failed profile floor reports its named row while retaining all bounds"

FLOOR_WITH_UNKNOWN="$TMP_ROOT/floor-with-unknown.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:gpt-5.6-sol","status":"unknown","runway":{"status":"unknown"}}
])' "$QUOTA" > "$FLOOR_WITH_UNKNOWN"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$FLOOR_WITH_UNKNOWN" run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:-%/unknown  -> not eligible: profile floor all_models below 50%' "a known profile-floor shortfall wins over unrelated unknown model evidence"

MISSING_PROFILE_FLOOR_RULES="$TMP_ROOT/missing-profile-floor-rules.json"
jq '.rules[1].use[1].floor.scope = "model:missing"' "$BASE_RULES" > "$MISSING_PROFILE_FLOOR_RULES"
cp "$MISSING_PROFILE_FLOOR_RULES" "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=model:missing  remaining=-%  spendPriority=-  runway=-  -> eligible, unranked: profile floor model:missing is unverifiable: not rankable: disclosed uncertainty' "a missing profile floor remains eligible but unranked"
assert_not_contains "$out" 'profile floor model:missing below' "missing profile evidence is not described as a shortfall"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "another candidate may clear without misrepresenting missing floor evidence"
SELECTED_CLAUDE_FLOOR_RULES="$TMP_ROOT/selected-claude-floor-rules.json"
jq '(.rules[3].use[0].floor) = {scope:"all_models",min_percent:50}' "$BASE_RULES" > "$SELECTED_CLAUDE_FLOOR_RULES"
cp "$SELECTED_CLAUDE_FLOOR_RULES" "$RULES"
SELECTED_CLAUDE_QUOTA="$TMP_ROOT/selected-claude-quota.json"
write_quota "$SELECTED_CLAUDE_QUOTA" -0.9 0.8
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[].runway.status) = "through_reset"' \
  "$SELECTED_CLAUDE_QUOTA" > "$TMP_ROOT/selected-claude-edit.json"
mv "$TMP_ROOT/selected-claude-edit.json" "$SELECTED_CLAUDE_QUOTA"
write_response "$RESPONSE" rule_4 0.99
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SELECTED_CLAUDE_QUOTA" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high' --profile-floor-scope 'all_models' --profile-floor-min-percent '50'" "the selected Claude candidate carries only its own floor into spawn"
cp "$BASE_RULES" "$RULES"
pass "declared provider and profile floor evidence are applied in code"

# --- malformed ranking evidence is never ordered -------------------------------
reset_log
NONNUMERIC="$TMP_ROOT/nonnumeric-spend-priority.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models") | .selection.spendPriority) = "high"' "$QUOTA" > "$NONNUMERIC"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NONNUMERIC" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=-  runway=through_reset  -> eligible, unranked: spendPriority missing or non-numeric at all_models: not rankable: disclosed uncertainty' "a nonnumeric spendPriority remains eligible but unranked"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "numeric evidence wins without mixed-type ordering"
pass "nonnumeric spendPriority evidence is never ranked"

# --- partial providers retain their known row evidence --------------------------
reset_log
PARTIAL="$TMP_ROOT/partial.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.status) = "partial"' "$QUOTA" > "$PARTIAL"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset  -> eligible' "a known row from a partial provider remains rankable"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "partial provider evidence can win the argmax"

PARTIAL_UNKNOWN="$TMP_ROOT/partial-unknown.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
])' "$QUOTA" > "$PARTIAL_UNKNOWN"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL_UNKNOWN" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=model:cursor-grok-4.6-medium  remaining=-%  spendPriority=-  runway=-  bounds=all_models:91%/through_reset,model:cursor-grok-4.6-medium:-%/unknown  -> eligible, unranked: quota row model:cursor-grok-4.6-medium unknown: not rankable: disclosed uncertainty' "an unknown exact-model row preserves partial known evidence without ranking"
assert_contains "$out" '  note: 2 eligible candidate(s) unranked (cursor, kimi)' "clear result lists every provider with unranked uncertainty"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "another measured candidate can clear"

PARTIAL_EXHAUSTED="$TMP_ROOT/partial-exhausted.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
] | .effectiveAvailability[] |= if .scope == "all_models" then .effectivePercentRemaining = 0 | .runway.status = "exhausted_now" else . end)' "$QUOTA" > "$PARTIAL_EXHAUSTED"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL_EXHAUSTED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now  bounds=all_models:0%/exhausted_now,model:cursor-grok-4.6-medium:-%/unknown  -> not eligible: runway exhausted_now at all_models' "known exhaustion vetoes a candidate despite unknown exact-model evidence"
assert_contains "$out" '  note: 1 eligible candidate(s) unranked (kimi)' "an exhausted candidate is excluded from the unranked uncertainty note"

UNKNOWN_EXHAUSTED="$TMP_ROOT/unknown-exhausted.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) = {
  "status":"unknown","effectiveAvailability":[
    {"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}
  ]
}' "$QUOTA" > "$UNKNOWN_EXHAUSTED"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$UNKNOWN_EXHAUSTED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=-%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at all_models' "unknown provider semantics cannot mask concrete exhaustion"

NO_APPLICABLE="$TMP_ROOT/no-applicable.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability) = [
  {"scope":"model:other","status":"known","effectivePercentRemaining":91,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}
]' "$QUOTA" > "$NO_APPLICABLE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NO_APPLICABLE" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  -> eligible, unranked: no applicable quota row for provider cursor: disclosed uncertainty' "a candidate without an applicable row remains eligible but unranked"
assert_contains "$out" '  note: 2 eligible candidate(s) unranked (cursor, kimi)' "no-applicable-row uncertainty appears in the clear-result note"
pass "partial and missing quota evidence remain eligible but unranked"

# --- provider-wide rows remain bounds beside exact model rows ------------------
reset_log
BOUNDED="$TMP_ROOT/bounded.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:sonnet","status":"known","effectivePercentRemaining":99,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.9}}
]' "$QUOTA" > "$BOUNDED"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$BOUNDED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627' "the limiting provider-wide row drives ranking"
assert_contains "$out" 'bounds=all_models:79%/projected_exhaustion,model:sonnet:99%/through_reset' "all applicable quota bounds are disclosed"

EXHAUSTED_WIDE="$TMP_ROOT/exhausted-wide.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models")) |= (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")' "$BOUNDED" > "$EXHAUSTED_WIDE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$EXHAUSTED_WIDE" run code out err "$BRIEF"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=0%' "the exhausted account-wide bound is the candidate evidence"
assert_contains "$out" '-> not eligible: runway exhausted_now at all_models' "a healthy exact row cannot bypass an exhausted account-wide bound"
pass "provider-wide and exact quota rows combine into one limiting candidate"

# --- opt-in candidate order keeps gates and quota-balanced compatibility -------
ORDER_RULES="$TMP_ROOT/order-rules.json"
ORDER_QUOTA="$TMP_ROOT/order-quota.json"
jq '.select = "candidate-order" |
  .rules[3].use = [
    {harness:"codex", model:"gpt-6-astra"},
    {harness:"claude", model:"opus", floor:{scope:"all_models", min_percent:40}}] |
  .default = .rules[3].use |
  .rules[2] |= (del(.approval) | .use = [
    {harness:"claude", model:"fable", floor:{scope:"all_models", min_percent:40}},
    {harness:"codex", model:"gpt-6-astra"}])' "$BASE_RULES" > "$ORDER_RULES"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[]) |=
  (.effectivePercentRemaining = 47 | .selection.spendPriority = 17.6 | .runway.status = "through_reset") |
  (.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[]) |=
  (.selection.spendPriority = 0.6 | .runway.status = "through_reset")' "$QUOTA" > "$ORDER_QUOTA"
order_case() {
  reset_log
  cp "$ORDER_RULES" "$RULES"
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$ORDER_QUOTA" run code out err "$BRIEF"
  expect_code 0 "$code" "ordered dispatch exits successfully"
}
write_response "$RESPONSE" rule_4 0.9
order_case
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6-astra'" "file opt-in chooses Codex despite Claude having higher spendPriority above its floor"
assert_contains "$out" 'selection: candidate-order' "selection policy is inspectable"
assert_contains "$out" 'remaining=47%  spendPriority=17.6' "higher-ranked quota is still reported"
assert_not_contains "$(cat "$LOG/body")" 'candidate-order' "selection policy never reaches the classifier"

# Runway preference changes only ordered candidates with a known safe alternative.
cp "$ORDER_QUOTA" "$TMP_ROOT/order-healthy.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[].runway.status) = "projected_exhaustion"' "$ORDER_QUOTA" > "$TMP_ROOT/order-edit.json"
mv "$TMP_ROOT/order-edit.json" "$ORDER_QUOTA"
order_case
assert_contains "$out" "profile: --harness 'claude' --model 'opus'" "projected Codex yields to through-reset Claude above its floor"
assert_contains "$out" 'passed over: codex:gpt-6-astra: projected to run out before reset' "runway preference explains the skipped candidate"
write_response "$RESPONSE" rule_3 0.9
order_case
assert_contains "$out" "profile: --harness 'claude' --model 'fable'" "design still selects Fable when Codex has projected exhaustion"
write_response "$RESPONSE" rule_4 0.9
cp "$ORDER_QUOTA" "$TMP_ROOT/order-projected.json"
for alternate in below-floor projected_exhaustion unknown; do
  jq --arg alternate "$alternate" '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[]) |=
    (if $alternate == "below-floor" then .effectivePercentRemaining = 39 else .runway.status = $alternate end)' "$TMP_ROOT/order-projected.json" > "$ORDER_QUOTA"
  order_case
  assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6-astra'" "configured order survives when later Claude is $alternate"
  assert_not_contains "$out" 'passed over:' "no runway skip without a rankable through-reset alternative"
done
cp "$TMP_ROOT/order-healthy.json" "$ORDER_QUOTA"
pass "candidate-order avoids projected exhaustion only with a passing through-reset alternative"

jq 'del(.select) | .rules[3].select = "candidate-order"' "$ORDER_RULES" > "$TMP_ROOT/order-edit.json"
mv "$TMP_ROOT/order-edit.json" "$ORDER_RULES"
order_case
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6-astra'" "rule opt-in chooses Codex without file opt-in"
jq '.select = "candidate-order" | .rules[3].select = "quota-balanced"' "$ORDER_RULES" > "$TMP_ROOT/order-edit.json"
mv "$TMP_ROOT/order-edit.json" "$ORDER_RULES"
order_case
assert_contains "$out" "profile: --harness 'claude' --model 'opus'" "rule quota-balanced overrides file order"
jq 'del(.select, .rules[3].select)' "$ORDER_RULES" > "$TMP_ROOT/order-edit.json"
mv "$TMP_ROOT/order-edit.json" "$ORDER_RULES"
order_case
assert_contains "$out" "profile: --harness 'claude' --model 'opus'" "no opt-in retains spendPriority ranking"
jq '.select = "candidate-order"' "$ORDER_RULES" > "$TMP_ROOT/order-edit.json"
mv "$TMP_ROOT/order-edit.json" "$ORDER_RULES"

write_response "$RESPONSE" rule_3 0.9
order_case
assert_contains "$out" "profile: --harness 'claude' --model 'fable'" "design preserves its Claude-first order"
for percent in 40 39; do
  jq --argjson pct "$percent" '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models").effectivePercentRemaining) = $pct' "$ORDER_QUOTA" > "$TMP_ROOT/order-edit.json"
  mv "$TMP_ROOT/order-edit.json" "$ORDER_QUOTA"
  order_case
  if [ "$percent" = 40 ]; then
    assert_contains "$out" "profile: --harness 'claude' --model 'fable'" "floor equality is eligible"
  else
    assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6-astra'" "ordered design skips Claude below floor"
    assert_contains "$out" 'not eligible: profile floor all_models below 40%' "below-floor exclusion is visible"
  fi
done
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models")) |=
  ({scope: .scope, status: "unknown", runway: {status: "unknown"}})' "$ORDER_QUOTA" > "$TMP_ROOT/order-edit.json"
mv "$TMP_ROOT/order-edit.json" "$ORDER_QUOTA"
order_case
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6-astra'" "unknown earlier floor stays unrankable"
assert_contains "$out" 'eligible, unranked:' "unknown evidence is disclosed"

# A neutral default uses the file policy; a matched rule keeps its policy even
# when one machine's rule floor falls through to default profiles.
write_response "$RESPONSE" default 0.9
order_case
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6-astra'" "default inherits candidate order"
jq '.rules[0].select = "quota-balanced" | .rules[0].floor.min_percent = 90' "$ORDER_RULES" > "$TMP_ROOT/order-edit.json"
mv "$TMP_ROOT/order-edit.json" "$ORDER_RULES"
write_response "$RESPONSE" rule_1 0.9
order_case
assert_contains "$out" 'fall through to default' "rule floor falls through"
assert_contains "$out" 'selection: quota-balanced' "the matched rule policy survives its floor fallback"

# Ordered selection also resolves equal quota evidence by explicit preference.
jq '(.providers[] | .quotaSemantics.effectiveAvailability[]) |=
  (.status = "known" | .effectivePercentRemaining = 47 | .runway.status = "through_reset" | .selection.spendPriority = 0.6)' "$ORDER_QUOTA" > "$TMP_ROOT/order-edit.json"
mv "$TMP_ROOT/order-edit.json" "$ORDER_QUOTA"
write_response "$RESPONSE" rule_4 0.9
order_case
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-6-astra'" "equal quota does not override configured preference"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[].runway.status) = "exhausted_now"' "$ORDER_QUOTA" > "$TMP_ROOT/order-edit.json"
mv "$TMP_ROOT/order-edit.json" "$ORDER_QUOTA"
order_case
assert_contains "$out" "profile: --harness 'claude' --model 'opus'" "ordered selection skips exhausted first candidate"
assert_contains "$out" 'not eligible: runway exhausted_now' "runway gate remains visible"
cp "$BASE_RULES" "$RULES"
pass "candidate-order honors file/rule preference, default fallback, floors, uncertainty, and exhaustion"

# --- default choice ------------------------------------------------------------
reset_log
write_response "$RESPONSE" default 0.88
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  rule: default (No listed rule applies to this task.)' "default names the fixed neutral none option"
assert_contains "$out" '  note: no rule matched' "default is explained"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "default resolves by argmax"
pass "default: no rule matched resolves among the default profiles"

# --- quota-balanced near-ties break by configured order ---------------------------
# The default array lists claude:opus before cursor:cursor-grok-4.6-high.
TIE="$TMP_ROOT/tie.json"
write_response "$RESPONSE" default 0.88

reset_log
write_quota "$TIE" 0.6 0.5
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TIE" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a clear spendPriority winner resolves"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "a clear winner wins even when configured later"
assert_not_contains "$out" 'near-tie' "a clear winner reports no near-tie"

reset_log
write_quota "$TIE" 0.54 0.5
set_runway "$TIE" claude through_reset
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TIE" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a near-tie resolves instead of escalating"
assert_contains "$out" "  profile: --harness 'claude' --model 'opus'" "a near-tie resolves to the first configured candidate"
assert_contains "$out" '  near-tie broken by configured order: claude:opus=0.5, cursor:cursor-grok-4.6-high=0.54 (within 0.05)' "the near-tie is reported with every tied candidate"

reset_log
write_quota "$TIE" 0.5 0.5
set_runway "$TIE" claude through_reset
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TIE" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "an exact tie resolves instead of escalating"
assert_contains "$out" "  profile: --harness 'claude' --model 'opus'" "an exact tie resolves to the first configured candidate"
assert_contains "$out" '  near-tie broken by configured order: claude:opus=0.5, cursor:cursor-grok-4.6-high=0.5 (within 0.05)' "the exact tie is reported"

reset_log
jq '.default[0].floor = {scope: "all_models", min_percent: 80}' "$BASE_RULES" > "$RULES"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TIE" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a near-tie beside a below-floor candidate resolves"
assert_contains "$out" 'candidate: claude:opus  provider=claude  scope=all_models  remaining=79%  spendPriority=-  runway=through_reset  -> not eligible: profile floor all_models below 80%' "the below-floor candidate stays excluded"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "configured order never revives a below-floor candidate"
assert_not_contains "$out" 'near-tie' "an excluded candidate never joins a near-tie"
cp "$BASE_RULES" "$RULES"
pass "near-tie: configured order breaks quota-balanced ties within the band; clear winners and floors are unchanged"

# --- projected exhaustion is vetoed when a through-reset candidate exists -------
reset_log
write_quota "$TIE" 0.3 1.5
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TIE" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "a through-reset candidate wins over a higher projected-exhaustion one"
assert_contains "$out" '  passed over: claude:opus: projected to run out before reset; another eligible candidate in the pool has runway through_reset' "the veto names the passed-over candidate"
set_runway "$TIE" cursor projected_exhaustion
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TIE" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'claude' --model 'opus'" "with no through-reset alternative the highest spendPriority still wins"
assert_not_contains "$out" 'passed over' "nothing is vetoed without a through-reset alternative"
pass "quota-balanced selection vetoes projected exhaustion only when a through-reset candidate remains"

# --- nothing rankable escalates -------------------------------------------------
reset_log
NONE="$TMP_ROOT/none.json"
jq '.providers |= map(if .provider == "cursor" or .provider == "claude" then .quotaSemantics.effectiveAvailability |= map(.runway.status = "exhausted_now") else . end)' "$QUOTA" > "$NONE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NONE" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "no rankable candidate escalates"
assert_contains "$out" '  reason: no rankable eligible candidate' "no-candidate reason"
assert_contains "$out" '-> not eligible: runway exhausted_now' "exhausted candidates keep their reason"
pass "no rankable candidate: the tool escalates instead of guessing"

# --- schema 6: rows keyed by provider + accountKey bind per account ----------------
# quota-axi emits schema 6 once a provider expands to several accounts; every
# row then carries accountKey and one provider id may appear on several rows.
# Native Codex and Pi lanes bind to their own account rows, with no row
# chosen by position or summed across accounts.
LANE_RULES="$TMP_ROOT/lane-rules.json"
SCHEMA6="$TMP_ROOT/schema6.json"
SCHEMA5_PAIR="$TMP_ROOT/schema5-pair.json"
cat > "$LANE_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "Codex work.",
      "use": [
        { "harness": "pi", "model": "openai-codex-work/gpt-5.6-terra", "provider": "codex" },
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
        { "harness": "codex", "model": "gpt-5.6-sol" }
      ]
    }
  ]
}
JSON
cat > "$SCHEMA6" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 6,
  "providers": [
    { "provider": "claude", "accountKey": "default", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } },
    { "provider": "codex", "accountKey": "openai-codex", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 0, "runway": { "status": "exhausted_now" }, "selection": { "spendPriority": -1.4788 } } ] } },
    { "provider": "codex", "accountKey": "openai-codex-work", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 11, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -5.6819 } } ] } },
    { "provider": "cursor", "accountKey": "default", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 24, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": 0.3917 } } ] } }
  ]
}
JSON
cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "rule_1", "confidence": 0.9,
    "probabilities": { "rule_1": 0.97, "default": 0.03 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
cp "$LANE_RULES" "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6" run code out err "$BRIEF"
expect_code 0 "$code" "schema 6 snapshot exits 0"
assert_contains "$out" '  status: clear' "schema 6 snapshot resolves"
assert_contains "$out" 'candidate: pi:openai-codex-work/gpt-5.6-terra  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible' "a Pi lane binds to its own account row"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol  provider=codex  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at all_models' "the sibling lane reads its own exhausted row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  -> eligible, unranked: provider codex has no quota row for account codex-home: disclosed uncertainty' "native Codex never infers an account from a Pi lane"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex-work/gpt-5.6-terra'" "the lane with headroom is chosen"
assert_equals '--json' "$(cat "$LOG/quota-axi.calls")" "schema 6 needs one quota-axi --json read"

SCHEMA6_NATIVE="$TMP_ROOT/schema6-native.json"
jq '
  .providers |= map(if .provider == "codex" then
    .quotaSemantics.effectiveAvailability |= map(.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")
    else . end) |
  (.providers[] | select(.accountKey == "openai-codex-work")) as $account |
  .providers += [($account | .accountKey = "default"),
    ($account | .accountKey = "codex-home" |
      .quotaSemantics.effectiveAvailability |= map(
        .effectivePercentRemaining = 80 | .runway.status = "through_reset" | .selection.spendPriority = 0.8))]
' "$SCHEMA6" > "$SCHEMA6_NATIVE"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6_NATIVE" run code out err "$BRIEF"
expect_code 0 "$code" "native Codex schema 6 snapshot exits 0"
assert_contains "$out" '  status: clear' "native Codex headroom resolves despite exhausted Pi and default rows"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset  -> eligible' "native Codex reads codex-home"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex headroom is chosen"

jq '.providers |= reverse' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-reversed.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-reversed.json" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex selection ignores row order"

jq '.providers |= map(select(.provider != "codex" or .accountKey != "default") |
  if .accountKey == "codex-home" then .accountKey = "default" else . end)' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-default.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-default.json" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex falls back to the default row when codex-home is absent"
pass "native Codex binds to codex-home before default, independently of Pi accounts and row order"

jq '.schemaVersion = 5 | .providers |= map(select(.accountKey != "openai-codex")) | del(.providers[].accountKey)' "$SCHEMA6" > "$SCHEMA5_PAIR"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA5_PAIR" run code out err "$BRIEF"
assert_contains "$out" '  near-tie broken by configured order: pi:openai-codex-work/gpt-5.6-terra=-5.6819, pi:openai-codex/gpt-5.6-sol=-5.6819, codex:gpt-5.6-sol=-5.6819 (within 0.05)' "every codex profile reads the one schema 5 codex row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible' "a schema 5 row never needs accountKey"

SCHEMA6_PI_NATIVE="$TMP_ROOT/schema6-pi-native.json"
jq '.providers |= map(select(.provider != "codex" or .accountKey != "default"))' "$SCHEMA6_NATIVE" > "$SCHEMA6_PI_NATIVE"
for harness in pi pi-signed; do
  jq --arg harness "$harness" '.rules[0].use |= map(if .harness == "codex" then
    {harness: $harness, model: "codex-native/gpt-6-astra", provider: "codex", effort: "ultra"}
    else . end)' "$LANE_RULES" > "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6_PI_NATIVE" run code out err "$BRIEF"
  expect_code 0 "$code" "$harness native adapter schema 6 exits 0"
  assert_contains "$out" '  status: clear' "$harness native adapter resolves with codex-home and no default row"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset  -> eligible" "$harness native adapter reads codex-home"
  assert_contains "$out" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter is chosen over exhausted Pi accounts"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-default.json" run code out err "$BRIEF"
  assert_contains "$out" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter falls back to default"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6" run code out err "$BRIEF"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  -> eligible, unranked: provider codex has no quota row for account codex-home: disclosed uncertainty" "$harness native adapter never borrows a Pi account"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA5_PAIR" run code out err "$BRIEF"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible" "$harness native adapter still joins schema 5 by provider alone"
done
cp "$LANE_RULES" "$RULES"
pass "Pi native adapters bind to codex-home with existing fallbacks and schema 5 compatibility"

jq 'del(.providers[1].accountKey)' "$SCHEMA6" > "$TMP_ROOT/schema6-keyless.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-keyless.json" run code out err "$BRIEF"
assert_contains "$out" '  status: error' "a schema 6 row without accountKey is an error outcome"
assert_contains "$out" '  reason: quota-axi --json returned an invalid snapshot' "keyless schema 6 row is named as an invalid snapshot"
cp "$BASE_RULES" "$RULES"
pass "schema 6: each candidate binds to its account row; schema 5 is unchanged"

# --- quota-axi is read exactly once --------------------------------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "quota-axi path exits 0"
assert_equals '--json' "$(cat "$LOG/quota-axi.calls")" "quota-axi --json is called exactly once"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "quota-axi snapshot drives the argmax"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_QUOTA_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "quota-axi failure exits 0"
assert_contains "$out" '  status: error' "quota-axi failure is an error outcome"
assert_contains "$out" '  reason: quota-axi --json failed' "quota-axi failure is named"
pass "quota evidence comes from one quota-axi --json read, and its failure is an error outcome"

# --- API and response failures are error outcomes, exit 0 ----------------------
reset_log
run_without_curl code out err "$BRIEF"
expect_code 0 "$code" "missing curl exits 0"
assert_contains "$out" '  status: error' "missing curl is a structured error outcome"
assert_contains "$out" '  reason: curl not installed' "missing curl is named in the TOON block"
assert_contains "$err" 'dispatch-resolve: error (curl not installed)' "missing curl is also reported on stderr"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=429 run code out err "$BRIEF"
expect_code 0 "$code" "http 429 exits 0"
assert_contains "$out" '  status: error' "http 429 is an error outcome"
assert_contains "$out" '  reason: http 429 after' "http status is reported"
assert_contains "$err" 'dispatch-resolve: error (http 429' "error also goes to stderr"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "curl failure exits 0"
assert_contains "$out" '  reason: http 000 after' "transport failure reads as http 000"
reset_log
printf '%s\n' '{"model":"jev","answers":{}}' > "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  reason: response is not a rule Choice answer' "a malformed answer is an error outcome"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.usage = "bad"' "$RESPONSE" > "$TMP_ROOT/malformed-usage.json"
mv "$TMP_ROOT/malformed-usage.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "malformed usage is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "malformed usage cannot break text rendering silently"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq 'del(.answers.rule.probabilities.default)' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "missing probability choice is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must name every offered choice"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.rule.probabilities.rule_4 = "high"' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "nonnumeric probability is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must be numeric and bounded"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.rule.probabilities[] = 0' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "a zero-mass probability distribution is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must sum to approximately one"
reset_log
write_response "$RESPONSE" rule_4 2
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "out-of-range confidence is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "out-of-range confidence is a malformed answer"
reset_log
write_response "$RESPONSE" rule_9 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "an unknown rule id is an error outcome"
assert_contains "$out" '  reason: rule rule_9 is not in the rules file' "unknown rule id is named"
write_response "$RESPONSE" rule_0 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "rule zero is an error outcome"
assert_contains "$out" '  reason: rule rule_0 is not in the rules file' "rule zero cannot alias the final rule"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=500 run code out err "$BRIEF"
assert_contains "$out" '  status: error' "http 500 is a TOON error outcome"
pass "API, transport, and response failures are error outcomes with exit 0"

# --- configuration errors exit 2 and select nothing ----------------------------------
reset_log
TYPESAFE_API_KEY=$KEY run code out err
expect_code 2 "$code" "missing brief exits 2"
assert_contains "$err" 'brief file required' "missing brief is named"
rm -f "$RULES"
ln -s "$TMP_ROOT/missing-rules-target.json" "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "broken canonical rules symlink exits 2"
assert_contains "$err" "rules file not readable: $RULES" "broken rules symlink is actionable"
rm -f "$RULES"
printf '%s\n' '{"rules":[' > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "non-JSON rules exits 2"
assert_contains "$err" 'not JSON' "non-JSON rules is named"
for bad in \
  '{"select":"mystery","rules":[{"when":"x","use":{"harness":"codex"}}]}|unknown select: mystery' \
  '{"select":null,"rules":[{"when":"x","use":{"harness":"codex"}}]}|select must be a non-empty string' \
  '{"select":false,"rules":[{"when":"x","use":{"harness":"codex"}}]}|select must be a non-empty string' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"approval":"firstmate"}]}|approval must be "captain" when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"select":"mystery"}]}|unknown select: mystery' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":"high"}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":1.5}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20,"provider":"CLAUDE"}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":""}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":" claude"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":"claude\n"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex","floor":{"scope":"all_models","min_percent":20,"provider":"claude"}}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":[{"harness":"codex","model":"gpt-5.5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]}]}|each rule use must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":[{"harness":"claude","model":"opus"},{"harness":"claude","model":"opus"}]}|default must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"spaceship"}}]}|each use profile must name a verified harness' \
  '{"rules":[{"when":"x","use":{"harness":"grok","effort":"max"}}]}|each use profile effort must be supported by its harness and model' \
  '{"rules":[{"when":"x","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5"}}]}|use profiles whose harness lacks one authoritative provider family require provider: opencode' \
  '{"rules":[{"when":"x","use":{"harness":"rovo"}}]}|use profiles whose harness lacks one authoritative provider family require provider: rovo' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":{"harness":"pi","model":"anthropic/claude-sonnet-5"}}|default profiles whose harness lacks one authoritative provider family require provider: pi'; do
  printf '%s\n' "${bad%%|*}" > "$RULES"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 2 "$code" "malformed rules exit 2: ${bad#*|}"
  assert_contains "$err" "malformed rules file: $RULES - ${bad#*|}" "malformed rules are named: ${bad#*|}"
done
assert_absent "$LOG/argv" "configuration errors never reach the network"
cp "$BASE_RULES" "$RULES"
for removed in --json --rules --quota; do
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" "$removed"
  expect_code 2 "$code" "removed option is rejected: $removed"
  assert_contains "$err" "unknown flag $removed" "removed option has no public path: $removed"
done
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --bogus
expect_code 2 "$code" "unknown flag exits 2"
run code out err --help
expect_code 0 "$code" "--help exits 0"
assert_contains "$out" 'Usage:' "--help prints usage"
pass "configuration errors exit 2 before any network call"

# --- one pool across machines: every machine that has the project ---------------
# The real fm-quota-snapshot.sh and fm-on.sh run; only ssh is a fake that runs
# the decoded remote command from this checkout as the remote home, against
# REMOTE_QUOTA, so the remote Claude crew evidence comes from REMOTE_HOME.
REMOTE_QUOTA="$TMP_ROOT/remote-quota.json"
REMOTE_HOME="$TMP_ROOT/remote-home"
SSH_CALLS="$TMP_ROOT/ssh.calls"
SSH_MODE="$TMP_ROOT/ssh.mode"
mkdir -p "$REMOTE_HOME/state"
cat > "$FAKEBIN/ssh" <<SH
#!/usr/bin/env bash
set -u
while [ "\$#" -gt 0 ] && [ "\$1" != -- ]; do shift; done
shift
printf '%s\n' "\$1" >> "$SSH_CALLS"
if [ "\$(cat "$SSH_MODE" 2>/dev/null)" = unreachable ]; then
  printf 'ssh: connect to host %s: Connection refused\n' "\$1" >&2
  exit 255
fi
args=()
while IFS= read -r -d '' arg; do args+=("\$arg"); done < <(printf '%s' "\$6" | base64 --decode 2>/dev/null || printf '%s' "\$6" | base64 -D)
exec env FM_HOME="$REMOTE_HOME" QUOTA_AXI_FIXTURE="$REMOTE_QUOTA" "$ROOT/bin/\${args[0]}" "\${args[@]:1}"
SH
chmod +x "$FAKEBIN/ssh"
export FM_SSH_BIN="$FAKEBIN/ssh"
mkdir -p "$HOME_DIR/data"
cat > "$HOME_DIR/data/projects.md" <<'MD'
- pager [direct-PR] - Pager tool (added 2030-01-01)
- solo-pager [local-only] - Machine-local pager (added 2030-01-01)
- other [direct-PR] - Another project (added 2030-01-01)
MD
cat > "$HOME_DIR/data/secondmates.md" <<'MD'
# Secondmates

- peer - Second machine for test work. (host: peer-host; root: /srv/firstmate-code; home: /srv/firstmate-home; scope: any work; projects: solo-pager, pager, remote-pager; added 2030-01-01)
MD
cp "$BASE_RULES" "$RULES"
placement_case() { # <ssh-mode> [args...]
  rm -rf "$HOME_DIR/state/quota-remote" "$SSH_CALLS"
  printf '%s\n' "$1" > "$SSH_MODE"
  shift
  reset_log
  write_response "$RESPONSE" "${PLACEMENT_RULE:-rule_4}" 0.9
  TYPESAFE_API_KEY="$KEY" run code out err "$BRIEF" "$@"
}
ssh_calls() { if [ -f "$SSH_CALLS" ]; then wc -l < "$SSH_CALLS" | tr -d ' '; else printf 0; fi; }

write_quota "$REMOTE_QUOTA" 0.8
placement_case ok --project pager
expect_code 0 "$code" "pooled resolution exits 0"
assert_contains "$out" 'status: clear' "the pooled result is clear"
assert_contains "$out" "profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the pooled profile is published"
assert_contains "$out" 'placement: secondmate peer (peer cursor:cursor-grok-4.6-medium has the pool'"'"'s highest spendPriority 0.8)' "a remote candidate wins on spendPriority with no home-machine margin"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=0.7597' "the local candidates are listed"
assert_contains "$out" 'candidate: home=peer cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=0.8  runway=through_reset  -> eligible' "the remote candidates are listed beside them"
assert_contains "$out" 'home: peer  claude-crew=0/3  session=79%' "the remote machine's Claude guard evidence is shown"
assert_equals peer-host "$(cat "$SSH_CALLS")" "the remote quota is read through the registered route"
write_quota "$REMOTE_QUOTA" 0.7
placement_case ok --project pager
assert_contains "$out" 'placement: local (local cursor:cursor-grok-4.6-medium has the pool'"'"'s highest spendPriority 0.7597)' "a higher local candidate keeps the task local"
pass "the pool ranks every machine's candidates by spendPriority with no home-machine margin"

PLACEMENT_RULE=rule_3 placement_case ok --project pager
assert_contains "$out" 'status: escalate' "an approval-gated answer keeps its status"
assert_contains "$out" 'candidate: home=peer claude:fable' "an approval-gated answer includes remote candidates"
assert_equals 1 "$(ssh_calls)" "an approval-gated answer reads the remote machine"
unset PLACEMENT_RULE
rm -rf "$HOME_DIR/state/quota-remote" "$SSH_CALLS"
printf 'ok\n' > "$SSH_MODE"
reset_log
write_response "$RESPONSE" rule_4 0.41
TYPESAFE_API_KEY="$KEY" run code out err "$BRIEF" --project pager
assert_contains "$out" 'status: ambiguous' "an ambiguous answer keeps its status"
assert_contains "$out" 'candidate: home=peer cursor:cursor-grok-4.6-medium' "an ambiguous answer includes remote candidates"
assert_equals 1 "$(ssh_calls)" "an ambiguous answer reads the remote machine"
pass "every candidate-bearing answer evaluates the whole machine pool"

printf 'not-json\n' > "$TMP_ROOT/invalid-local-quota.json"
rm -rf "$HOME_DIR/state/quota-remote" "$SSH_CALLS"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY="$KEY" QUOTA_AXI_FIXTURE="$TMP_ROOT/invalid-local-quota.json" run code out err "$BRIEF" --project pager
assert_contains "$out" 'status: clear' "a healthy remote machine resolves despite local quota failure"
assert_contains "$out" 'home: local  unknown: quota-axi --json returned an invalid snapshot: disclosed uncertainty' "the local failure is disclosed on its home line"
assert_contains "$out" 'placement: secondmate peer' "the healthy remote machine receives the task"
assert_equals 1 "$(ssh_calls)" "local quota failure does not skip the remote snapshot"
pass "local quota failure leaves this home unavailable without blocking peers"

write_quota "$REMOTE_QUOTA" 0.3
set_runway "$REMOTE_QUOTA" claude through_reset
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models") | .selection.spendPriority) = 0.75' \
  "$REMOTE_QUOTA" > "$REMOTE_QUOTA.tmp" && mv "$REMOTE_QUOTA.tmp" "$REMOTE_QUOTA"
placement_case ok --project pager
assert_contains "$out" 'placement: secondmate peer (peer claude:sonnet wins a near-tie at spendPriority 0.75 by configured order)' "a cross-machine near-tie resolves by configured order"
assert_contains "$out" 'near-tie broken by configured order: home=peer claude:sonnet=0.75, cursor:cursor-grok-4.6-medium=0.7597 (within 0.05)' "near-tie evidence names each machine"
pass "configured order breaks near-ties across the pool"

jq '.select = "candidate-order" | .rules[0].select = "quota-balanced"' "$BASE_RULES" > "$RULES"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) |= map(
  if .scope == "all_models" then .runway.status = "through_reset" | .selection.spendPriority = 2.5
  elif .scope == "model:fable" then .effectivePercentRemaining = 95 | .runway.status = "through_reset" | .selection.spendPriority = 2.25
  else . end
)' "$QUOTA" > "$REMOTE_QUOTA"
PLACEMENT_RULE=rule_1 placement_case ok --project pager
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-high' "the local rule floor falls through to local defaults"
assert_contains "$out" 'candidate: home=peer claude:fable' "the remote machine evaluates the matched rule against its own floor"
assert_contains "$out" "profile: --harness 'claude' --model 'fable' --effort 'xhigh'" "the remote rule profile wins the pool"
assert_contains "$out" 'placement: secondmate peer' "the task is placed where the rule applies"
assert_contains "$out" 'selection: quota-balanced' "the matched rule selects one policy for every machine"
assert_contains "$out" '  note: rule matched' "the top-level note describes the chosen remote rule profile"
assert_contains "$out" 'home: local  claude-crew=0/3  session=79%  note=rule rule_1 floor model:fable below 20%: fall through to default' "the local floor fallback stays on the local home line"

jq '.rules[0].approval = "captain"' "$RULES" > "$TMP_ROOT/rules-edit.json"
mv "$TMP_ROOT/rules-edit.json" "$RULES"
PLACEMENT_RULE=rule_1 placement_case ok --project pager
assert_contains "$out" 'status: escalate' "the approval gate keeps its status"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-high' "the approval-gated local home contributes defaults below its rule floor"
assert_not_contains "$out" 'candidate: claude:fable' "the approval-gated local home does not contribute the floored rule profile"
assert_contains "$out" 'candidate: home=peer claude:fable' "the approval-gated remote home contributes the passing rule profile"
assert_contains "$out" 'home: local  claude-crew=0/3  session=79%  note=rule rule_1 floor model:fable below 20%: fall through to default' "the approval-gated local floor fallback is disclosed"

jq 'del(.rules[0].approval)' "$RULES" > "$TMP_ROOT/rules-edit.json"
mv "$TMP_ROOT/rules-edit.json" "$RULES"
rm -rf "$HOME_DIR/state/quota-remote" "$SSH_CALLS"
printf 'ok\n' > "$SSH_MODE"
reset_log
write_response "$RESPONSE" rule_1 0.41
TYPESAFE_API_KEY="$KEY" run code out err "$BRIEF" --project pager
assert_contains "$out" 'status: ambiguous' "the confidence gate keeps its status"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-high' "the ambiguous local home contributes defaults below its rule floor"
assert_not_contains "$out" 'candidate: claude:fable' "the ambiguous local home does not contribute the floored rule profile"
assert_contains "$out" 'candidate: home=peer claude:fable' "the ambiguous remote home contributes the passing rule profile"
assert_contains "$out" 'home: local  claude-crew=0/3  session=79%  note=rule rule_1 floor model:fable below 20%: fall through to default' "the ambiguous local floor fallback is disclosed"
cp "$BASE_RULES" "$RULES"
pass "each machine resolves its floor for clear, approval-gated, and ambiguous outcomes"

placement_case unreachable --project pager
expect_code 0 "$code" "an unreachable machine still exits 0"
assert_contains "$out" 'status: clear' "an unreachable machine never blocks local dispatch"
assert_contains "$out" "profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the local profile survives an unreachable machine"
assert_contains "$out" 'placement: local' "an unreachable machine leaves the task local"
assert_contains "$out" "home: peer  unknown: peer's machine unreachable" "the unreachable machine is disclosed"
assert_contains "$out" 'disclosed uncertainty' "the unknown remote quota is named as uncertainty"
pass "an unreachable remote machine is disclosed and falls back to local"

placement_case ok --project solo-pager
assert_not_contains "$out" 'placement:' "a local-only project is never placed remotely"
assert_equals 0 "$(ssh_calls)" "a local-only project reads no remote quota"
placement_case ok --project other
assert_not_contains "$out" 'placement:' "a project only registered on this machine stays local"
assert_equals 0 "$(ssh_calls)" "a project no remote machine has reads no remote quota"
placement_case ok
assert_not_contains "$out" 'placement:' "no project means no pool"
assert_equals 0 "$(ssh_calls)" "no project reads no remote quota"
write_quota "$REMOTE_QUOTA" 0.1
placement_case ok --project remote-pager
assert_contains "$out" 'home: local  not eligible: project remote-pager is not registered on this machine' "a project registered only remotely excludes this machine"
assert_not_contains "$out" 'candidate: cursor:' "this machine contributes no candidates for a project it does not have"
assert_contains "$out" 'placement: secondmate peer' "the project goes to the machine that has it even at lower quota"
pass "a project is eligible exactly on the machines that have it"

write_quota "$REMOTE_QUOTA" 0.3
jq '(.providers[] | select(.provider == "claude" or .provider == "cursor") | .quotaSemantics.effectiveAvailability[].runway.status) = "exhausted_now"' "$QUOTA" > "$TMP_ROOT/exhausted.json"
QUOTA_AXI_FIXTURE="$TMP_ROOT/exhausted.json" placement_case ok --project pager
assert_contains "$out" 'status: clear' "remote headroom resolves the pool when nothing local is rankable"
assert_contains "$out" 'placement: secondmate peer' "an exhausted machine yields to one with headroom"
pass "an exhausted local machine places work on a machine with headroom"

# --- per-account guards on each machine ------------------------------------------
# A rule of Claude and Codex profiles, as each machine's two accounts.
POOL_RULES="$TMP_ROOT/pool-rules.json"
cat > "$POOL_RULES" <<'JSON'
{
  "rules": [
    { "when": "A simple bug fix with a stated root cause.",
      "use": [ { "harness": "claude", "model": "sonnet" }, { "harness": "codex", "model": "gpt-5.6-sol" } ] }
  ],
  "default": [ { "harness": "codex", "model": "gpt-5.6-sol" } ]
}
JSON
write_pool_quota() {  # <path> <claude spendPriority> <claude runway> <codex spendPriority> <codex runway> [<session %>] [<codex %>]
  cat > "$1" <<JSON
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "claude", "state": { "status": "fresh", "stale": false }, "windows": [ { "id": "five_hour", "kind": "session", "percentRemaining": ${6:-90} } ],
      "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": ${6:-90}, "runway": { "status": "$3" }, "selection": { "spendPriority": $2 } } ] } },
    { "provider": "codex", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": ${7:-90}, "runway": { "status": "$5" }, "selection": { "spendPriority": $4 } } ] } }
  ]
}
JSON
}
write_pool_response() {  # <path>
  cat > "$1" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "rule_1", "confidence": 0.95,
    "probabilities": { "rule_1": 0.95, "default": 0.05 } } },
  "usage": { "input_tokens": 400, "output_tokens": 30 } }
JSON
}
live_claude() {  # <state-dir> <count>
  local n=1
  rm -f "$1"/crew*.meta
  while [ "$n" -le "$2" ]; do
    printf 'harness=claude\nkind=ship\nbackend=unknown\nwindow=recorded-%s\naccount=ordinary\n' "$n" > "$1/crew$n.meta"
    n=$((n + 1))
  done
}
pool_case() {  # [args...]
  rm -rf "$HOME_DIR/state/quota-remote" "$SSH_CALLS"
  printf 'ok\n' > "$SSH_MODE"
  reset_log
  write_pool_response "$RESPONSE"
  TYPESAFE_API_KEY="$KEY" QUOTA_AXI_FIXTURE="$TMP_ROOT/pool-local.json" run code out err "$@"
}
cp "$POOL_RULES" "$RULES"
mkdir -p "$HOME_DIR/state"

write_pool_quota "$TMP_ROOT/pool-local.json" 1.0 through_reset 0.2 through_reset
write_pool_quota "$REMOTE_QUOTA" 0.6 through_reset 0.2 through_reset
live_claude "$HOME_DIR/state" 3
pool_case "$BRIEF" --project pager
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=90%  spendPriority=1.0  runway=through_reset  -> not eligible: Claude crew at its limit on this machine: 3 of 3 (live: crew1, crew2, crew3)' "the local Claude guard counts this machine's live crew"
assert_contains "$out" "profile: --harness 'claude' --model 'sonnet'" "Claude is still chosen"
assert_contains "$out" 'placement: secondmate peer (peer claude:sonnet has the pool'"'"'s highest spendPriority 0.6)' "local Claude at its limit places on the other machine's Claude"
assert_contains "$out" 'home: local  claude-crew=3/3  session=90%' "the local guard evidence is shown"
live_claude "$HOME_DIR/state" 0
live_claude "$REMOTE_HOME/state" 3
write_pool_quota "$REMOTE_QUOTA" 1.4 through_reset 0.2 through_reset
pool_case "$BRIEF" --project pager
assert_contains "$out" 'candidate: home=peer claude:sonnet  provider=claude  scope=all_models  remaining=90%  spendPriority=1.4  runway=through_reset  -> not eligible: Claude crew at its limit on peer: 3 of 3 (live: crew1, crew2, crew3)' "the remote guard comes from the remote home's own crew"
assert_contains "$out" 'placement: local' "a remote machine at its Claude limit leaves Claude work here"
live_claude "$REMOTE_HOME/state" 0
write_pool_quota "$REMOTE_QUOTA" 1.4 through_reset 0.2 through_reset 38
pool_case "$BRIEF" --project pager
assert_contains "$out" 'not eligible: Claude session 38% below the 40% floor on peer' "the 40% session floor applies per machine"
assert_contains "$out" 'placement: local' "a remote account under its session floor is passed by"
pass "the Claude crew cap and session floor apply per account on each machine"

write_pool_quota "$TMP_ROOT/pool-local.json" 1.0 through_reset 0.2 through_reset
write_pool_quota "$REMOTE_QUOTA" 1.0 through_reset 0.2 through_reset
live_claude "$HOME_DIR/state" 1
live_claude "$REMOTE_HOME/state" 0
pool_case "$BRIEF" --project pager
assert_contains "$out" 'exact cross-home tie: claude:sonnet=1.0 workers=1, home=peer claude:sonnet=1.0 workers=0 -> home=peer claude:sonnet by fewer live workers' "the exact tie line names both account loads and the deciding rule"
assert_contains "$out" 'placement: secondmate peer (peer claude:sonnet wins an exact cross-home tie at spendPriority 1.0 by fewer live workers)' "the placement reason names the worker-count tie-break"

live_claude "$HOME_DIR/state" 0
mkdir -p "$TMP_ROOT/data/hash-a" "$TMP_ROOT/data/hash-b"
cp "$BRIEF" "$TMP_ROOT/data/hash-a/brief.md"
cp "$BRIEF" "$TMP_ROOT/data/hash-b/brief.md"
pool_case "$TMP_ROOT/data/hash-a/brief.md" --project pager
hash_a_out=$out
hash_a_placement=$(grep '^  placement:' <<<"$out")
pool_case "$TMP_ROOT/data/hash-b/brief.md" --project pager
hash_b_out=$out
hash_b_placement=$(grep '^  placement:' <<<"$out")
assert_contains "$hash_a_out" 'by stable task-key hash' "equal worker counts use the task-key hash"
assert_contains "$hash_b_out" 'by stable task-key hash' "the hash rule is reported for another task key"
assert_not_equals "$hash_a_placement" "$hash_b_placement" "different task keys can spread exact ties across machines"
pool_case "$TMP_ROOT/data/hash-a/brief.md" --project pager
assert_equals "$hash_a_placement" "$(grep '^  placement:' <<<"$out")" "the same task key resolves the tie stably"
pass "exact cross-home ties use account load, then a stable task-key hash"

write_pool_quota "$TMP_ROOT/pool-local.json" 0.4 projected_exhaustion 1.8 projected_exhaustion
write_pool_quota "$REMOTE_QUOTA" 0.3 through_reset 1.6 projected_exhaustion
pool_case "$BRIEF" --project pager
assert_contains "$out" "profile: --harness 'claude' --model 'sonnet'" "Claude that runs through reset beats higher Codex projected to run out"
assert_contains "$out" 'placement: secondmate peer (peer claude:sonnet has the pool'"'"'s highest spendPriority 0.3; 3 candidate(s) projected to run out before reset passed over)' "the veto is named in the placement reason"
assert_contains "$out" 'passed over: codex:gpt-5.6-sol: projected to run out before reset; another eligible candidate in the pool has runway through_reset' "the vetoed Codex candidate is shown"
write_pool_quota "$TMP_ROOT/pool-local.json" 0.3 projected_exhaustion 0.2 projected_exhaustion
write_pool_quota "$REMOTE_QUOTA" 0.1 projected_exhaustion 0.56 unknown 90 63
pool_case "$BRIEF" --project pager
assert_contains "$out" 'candidate: home=peer codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=63%  spendPriority=0.56  runway=unknown  -> eligible, runway unknown: disclosed uncertainty' "unknown runway with a known percentage stays eligible and disclosed"
assert_contains "$out" 'placement: secondmate peer (peer codex:gpt-5.6-sol has the pool'"'"'s highest spendPriority 0.56)' "unknown runway never blocks placement"
pass "Codex projected to run out is vetoed while Claude anywhere runs through reset"

jq '.select = "candidate-order" | .rules[0].use |= reverse' "$POOL_RULES" > "$RULES"
write_pool_quota "$TMP_ROOT/pool-local.json" 1.5 through_reset 0.6 through_reset
write_pool_quota "$REMOTE_QUOTA" 1.5 through_reset 1.2 through_reset
pool_case "$BRIEF" --project pager
assert_contains "$out" "profile: --harness 'codex' --model 'gpt-5.6-sol'" "configured order keeps Codex first across the pool"
assert_contains "$out" 'placement: secondmate peer (peer codex:gpt-5.6-sol is the first passing candidate in configured order across the pool)' "quota picks the machine for the preferred profile"
write_pool_quota "$REMOTE_QUOTA" 1.5 through_reset 1.2 projected_exhaustion
pool_case "$BRIEF" --project pager
assert_contains "$out" 'passed over: home=peer codex:gpt-5.6-sol: projected to run out before reset; later eligible candidate has runway through_reset' "ordered selection passes over a projected remote candidate"
assert_contains "$out" 'placement: local (local codex:gpt-5.6-sol is the first passing candidate in configured order across the pool' "the same profile on a safe machine is next in order"
cp "$POOL_RULES" "$RULES"
pass "candidate-order ranks the pool by configured position, then quota, with the runway pass-over"

# --- a burst spreads: each placement is charged before the next -------------------
write_pool_quota "$TMP_ROOT/pool-local.json" 1.0 through_reset 0.9 through_reset 90 90
write_pool_quota "$REMOTE_QUOTA" 1.0 through_reset 0.95 through_reset 90 90
BATCH=()
for n in $(seq 1 20); do
  cp "$BRIEF" "$TMP_ROOT/brief-$n.md"
  BATCH+=("$TMP_ROOT/brief-$n.md" --project pager)
done
pool_case "${BATCH[@]}"
expect_code 0 "$code" "a batch exits 0"
assert_equals 20 "$(grep -c '^dispatch-resolve:$' <<<"$out")" "a batch prints one block per brief"
assert_contains "$out" "  brief: $TMP_ROOT/brief-20.md" "each block names its brief"
assert_contains "$out" '  briefs: 20   clear: 20   other: 0' "every brief is placed"
assert_contains "$out" '  machine: local=10 peer=10' "the burst spreads across both machines"
assert_contains "$out" '  provider: claude=6 codex=14' "Claude stops at three per account per machine and Codex takes the rest"
assert_contains "$out" 'local:claude:sonnet=3' "this machine's Claude account takes three"
assert_contains "$out" 'peer:claude:sonnet=3' "the other machine's Claude account takes three"
assert_contains "$out" 'local:codex:gpt-5.6-sol=7' "this machine's Codex account shares the rest"
assert_contains "$out" 'peer:codex:gpt-5.6-sol=7' "the other machine's Codex account shares the rest"
assert_contains "$out" 'charged=' "later placements show the charge of earlier ones"
assert_equals 1 "$(ssh_calls)" "a batch reads each remote machine once"
first_block=$(awk '/^dispatch-resolve:$/ { n++ } n == 1' <<<"$out" | grep -v -e '^  brief: ' -e '^  project: ' -e '^  model: ')
pool_case "$TMP_ROOT/brief-1.md" --project pager
assert_equals "$first_block" "$(grep -v '^  model: ' <<<"$out")" "the same brief resolves identically alone and first in a batch"
pass "a batch of 20 charges each placement and spreads across accounts and machines"

# Separate calls inside the charge window spread like one batch.
mkdir -p "$TMP_ROOT/data/task-a" "$TMP_ROOT/data/task-b"
cp "$BRIEF" "$TMP_ROOT/data/task-a/brief.md"
cp "$BRIEF" "$TMP_ROOT/data/task-b/brief.md"
write_pool_quota "$TMP_ROOT/pool-local.json" 1.0 through_reset 0.2 through_reset
write_pool_quota "$REMOTE_QUOTA" 0.95 through_reset 0.2 through_reset
pool_case "$TMP_ROOT/data/task-a/brief.md" --project pager
assert_contains "$out" 'placement: local' "the first call takes the best candidate"
assert_equals 'task-a local claude true' "$(jq -r '"\(.key) \(.home) \(.provider) \(.claude)"' "$HOME_DIR/state/dispatch-charges.jsonl")" "the placement is recorded for later calls"
KEEP_LEDGER=1 pool_case "$TMP_ROOT/data/task-a/brief.md" --project pager
assert_contains "$out" 'placement: local' "resolving the same task again is not charged against itself"
KEEP_LEDGER=1 pool_case "$TMP_ROOT/data/task-b/brief.md" --project pager
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=85%  spendPriority=0.9  runway=through_reset  charged=1 recent placement(s)  -> eligible' "a later call is charged with the earlier placement"
assert_contains "$out" 'home: local  claude-crew=0/3 +1 recent placement(s)' "the recent Claude placement holds a slot"
assert_contains "$out" 'placement: secondmate peer' "a later separate call spreads to the next account"
jq -c '.at -= 1000' "$HOME_DIR/state/dispatch-charges.jsonl" > "$TMP_ROOT/aged.jsonl"
cp "$TMP_ROOT/aged.jsonl" "$HOME_DIR/state/dispatch-charges.jsonl"
KEEP_LEDGER=1 pool_case "$TMP_ROOT/data/task-b/brief.md" --project pager
assert_contains "$out" 'placement: local' "placements older than the charge window stop counting"
live_claude "$HOME_DIR/state" 0
pass "placements are charged across separate calls inside the charge window"

SCOPED_QUOTA="$TMP_ROOT/scoped-quota.json"
cat > "$SCOPED_QUOTA" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "codex", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 90, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 1.0 } },
      { "scope": "model:gpt-5.6-sol", "status": "known", "effectivePercentRemaining": 70, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.8 } },
      { "scope": "model:gpt-6-astra", "status": "known", "effectivePercentRemaining": 80, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 1.0 } }
    ] } }
  ]
}
JSON
jq '.rules[0].use = [{harness:"codex", model:"gpt-5.6-sol"}] | .default = .rules[0].use' "$POOL_RULES" > "$RULES"
write_pool_response "$RESPONSE"
rm -f "$HOME_DIR/state/dispatch-charges.jsonl"
TYPESAFE_API_KEY="$KEY" QUOTA_AXI_FIXTURE="$SCOPED_QUOTA" run code out err "$TMP_ROOT/data/task-a/brief.md"
assert_equals 'gpt-5.6-sol all_models,model:gpt-5.6-sol' "$(jq -r '[.model, (.scopes | sort | join(","))] | join(" ")' "$HOME_DIR/state/dispatch-charges.jsonl")" "the ledger records the selected model and applicable scopes"
jq '.rules[0].use = [{harness:"codex", model:"gpt-6-astra"}] | .default = .rules[0].use' "$POOL_RULES" > "$RULES"
KEEP_LEDGER=1 TYPESAFE_API_KEY="$KEY" QUOTA_AXI_FIXTURE="$SCOPED_QUOTA" run code out err "$TMP_ROOT/data/task-b/brief.md"
assert_contains "$out" 'remaining=85%  spendPriority=0.9  runway=through_reset  bounds=all_models:85%/through_reset,model:gpt-6-astra:80%/through_reset' "the shared account row is charged while the unrelated model row is unchanged"
pass "placement charges apply only to the selected profile's quota scopes"

cp "$BASE_RULES" "$RULES"
rm -f "$HOME_DIR/state"/crew*.meta "$REMOTE_HOME/state"/crew*.meta

printf 'withheld-ledger\n' > "$HOME_DIR/config/dispatch-never-send"
printf '# Task\nReconcile the withheld-ledger totals.\n' > "$TMP_ROOT/brief-secret.md"
placement_case ok --project pager "$TMP_ROOT/brief-secret.md" --project other
expect_code 0 "$code" "a batch with a withheld brief exits 0"
assert_contains "$out" '  status: off' "the withheld brief reports off in its own block"
assert_contains "$out" "  reason: brief text matches $HOME_DIR/config/dispatch-never-send line 1" "the withheld brief names only the list line"
assert_not_contains "$out" 'withheld-ledger' "the withheld value never prints"
assert_contains "$out" '  briefs: 2   clear: 1   other: 1' "the other brief still resolves"
assert_not_contains "$(cat "$LOG/body")" 'withheld-ledger' "the withheld brief never reached the network"
rm -f "$HOME_DIR/config/dispatch-never-send"
pass "a never-send match withholds only its own brief in a batch"

# Rate-limit recovery reuses vendor semantics; old and other failures stay unknown.
export TYPESAFE_API_KEY="$KEY"
write_response "$RESPONSE" default 0.95
jq '.default = [{harness:"codex",model:"gpt-5.6-sol"},{harness:"claude",model:"opus"}]' "$BASE_RULES" > "$RULES"
write_quota "$QUOTA" 0.1 1.2
export QUOTA_AXI_RECOVERY_FIXTURE="$TMP_ROOT/recovered.json"
cp "$QUOTA" "$TMP_ROOT/fresh.json"
jq '.providers |= map(select(.provider == "claude")) |
  .providers[].state = {status:"fresh",stale:false,reused:true,refreshedAt:((now-300)|floor|todateiso8601|sub("Z$";".000Z"))}' \
    "$TMP_ROOT/fresh.json" > "$QUOTA_AXI_RECOVERY_FIXTURE"
jq '(.providers[] | select(.provider == "claude")) |=
  (.state = {status:"stale",stale:true,error:"Claude quota endpoint rate limited"} |
   .quotaSemantics = {status:"unknown",effectiveAvailability:[]})' "$TMP_ROOT/fresh.json" > "$QUOTA"
reset_log
run code out err "$BRIEF"
assert_contains "$out" "profile: --harness 'claude'" "recent rate-limited Claude is ranked using the cached priority"
assert_contains "$out" 'cached=' "resolver discloses the cached reading age"
assert_equals 2 "$(wc -l < "$QUOTA_AXI_CALLS" | tr -d ' ')" "only the rate-limited provider gets one cache retry"
# A one-provider recovery may be schema 5 while the original multi-account
# report is schema 6. The original join key must survive that replacement.
jq '.schemaVersion = 6 | .providers[].accountKey = "default"' "$QUOTA" > "$TMP_ROOT/expanded.json"
cp "$TMP_ROOT/expanded.json" "$QUOTA"
run code out err "$BRIEF"
assert_contains "$out" "profile: --harness 'claude'" "schema-5 cache recovery preserves the schema-6 default account key"
jq '.schemaVersion = 6 | .providers[].accountKey = "other-account"' \
    "$QUOTA_AXI_RECOVERY_FIXTURE" > "$TMP_ROOT/other-account.json"
QUOTA_AXI_RECOVERY_FIXTURE="$TMP_ROOT/other-account.json" run code out err "$BRIEF"
assert_contains "$out" 'provider claude unmeasured (unknown)' "a different account cannot supply cached evidence"
jq '.select = "candidate-order"' "$RULES" > "$TMP_ROOT/ordered.json"
cp "$TMP_ROOT/ordered.json" "$RULES"
run code out err "$BRIEF"
assert_contains "$out" "profile: --harness 'codex'" "Codex-first ordering is unchanged by higher cached Claude priority"
for age in 1200 -300; do
  jq --argjson age "$age" '.providers[].state.refreshedAt = ((now-$age)|floor|todateiso8601)' \
    "$QUOTA_AXI_RECOVERY_FIXTURE" > "$TMP_ROOT/recovered-edit.json"
  cp "$TMP_ROOT/recovered-edit.json" "$QUOTA_AXI_RECOVERY_FIXTURE"
  run code out err "$BRIEF"
  assert_contains "$out" 'provider claude unmeasured (unknown)' "old or future-dated cache is unranked"
  assert_not_contains "$out" 'cached=' "unusable cache is not advertised as evidence"
done
jq '.providers[].state.refreshedAt = ((now-300)|floor|todateiso8601)' \
    "$QUOTA_AXI_RECOVERY_FIXTURE" > "$TMP_ROOT/recovered-edit.json"
cp "$TMP_ROOT/recovered-edit.json" "$QUOTA_AXI_RECOVERY_FIXTURE"
jq '(.providers[] | select(.provider == "claude") | .state.error) = "authentication failed"' \
    "$QUOTA" > "$TMP_ROOT/auth-failure.json"
cp "$TMP_ROOT/auth-failure.json" "$QUOTA"
reset_log
run code out err "$BRIEF"
assert_contains "$out" 'provider claude unmeasured (unknown)' "other failures remain unknown"
assert_equals 1 "$(wc -l < "$QUOTA_AXI_CALLS" | tr -d ' ')" "other failures never retry the cache"
unset QUOTA_AXI_RECOVERY_FIXTURE
pass "bounded Claude cache recovery ranks recent evidence, preserves candidate order, and discloses age"

printf '# all fm-dispatch-resolve tests passed\n'
