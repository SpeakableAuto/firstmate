#!/usr/bin/env bash
# Exercise the preflight alone against a real SQLite store, never a live response.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v sqlite3 >/dev/null 2>&1 || fail 'install sqlite3 to test review-round enforcement'
TMP=$(fm_test_tmproot fm-nm-review-round-cap)
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
export NM_CAP_DB="$TMP/state.sqlite" NM_CAP_OVERRIDE_DIR="$TMP/review-round-overrides"
export NM_CAP_BINARY=/usr/bin/true NM_CAP_DRYRUN=1 NM_REVIEW_ROUND_CAP=2
GUARD="$ROOT/bin/fm-nm-review-round-cap.sh"
# Minimal, data-free shape of a real fix_review gate observed on no-mistakes.
# The historical run had two review invocations and a review-fix invocation.
RUN=01M62WGRRHNXS5KCMW6A07Q1PS
OTHER_RUN=01M62WGRRHNXS5KCMW6A07Q1PT
BRANCH='fixture+branch'
git init -q "$TMP/repo"
git -C "$TMP/repo" symbolic-ref HEAD "refs/heads/$BRANCH"
git init -q "$TMP/other-repo"
git -C "$TMP/other-repo" symbolic-ref HEAD "refs/heads/$BRANCH"
sqlite3 "$NM_CAP_DB" <<SQL
CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT, branch TEXT, created_at INTEGER);
CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, status TEXT);
CREATE TABLE agent_invocations (run_id TEXT, step_name TEXT, purpose TEXT, round INTEGER);
INSERT INTO repos VALUES ('repo', '$TMP/repo');
INSERT INTO repos VALUES ('other-repo', '$TMP/other-repo');
INSERT INTO runs VALUES ('$RUN', 'repo', '$BRANCH', 1);
INSERT INTO runs VALUES ('$OTHER_RUN', 'other-repo', '$BRANCH', 2);
INSERT INTO step_results VALUES ('review-step', '$RUN', 'review', 'fix_review');
INSERT INTO step_results VALUES ('other-review-step', '$OTHER_RUN', 'review', 'fix_review');
INSERT INTO agent_invocations VALUES ('$RUN', 'review', 'review', 1);
INSERT INTO agent_invocations VALUES ('$RUN', 'review', 'review-fix', 2);
INSERT INTO agent_invocations VALUES ('$RUN', 'review', 'review', 2);
INSERT INTO agent_invocations VALUES ('$OTHER_RUN', 'review', 'review', 1);
INSERT INTO agent_invocations VALUES ('$OTHER_RUN', 'review', 'review', 2);
SQL

out=$(sh "$GUARD" axi status --run "$RUN" 2>&1); rc=$?
expect_code 0 "$rc" 'inspection must remain available'
pass 'status inspection is allowed'

out=$(sh "$GUARD" axi respond --run "$RUN" --step review --action fix 2>&1); rc=$?
expect_code 3 "$rc" 'explicit review must enforce the cap'
assert_contains "$out" 'review-round cap reached (2 of 2)' 'explicit selection must report the real count and owner'
pass 'explicit review reports the real capped count'

out=$(sh "$GUARD" axi respond --run "$RUN" --action fix 2>&1); rc=$?
expect_code 3 "$rc" 'implicit fix_review must enforce the cap'
assert_contains "$out" 'review-round cap reached (2 of 2)' 'fix_review must report the real count instead of unreadable'
pass 'run-shaped fix_review gate reports two reviews and escalates'

mkdir -p "$NM_CAP_OVERRIDE_DIR/consumed"
: >"$NM_CAP_OVERRIDE_DIR/$RUN.review-3"
out=$(sh "$GUARD" axi respond --run "$RUN" --action fix 2>&1); rc=$?
expect_code 3 "$rc" 'a token file must never authorize a capped fix'
assert_contains "$out" 'review-round cap reached (2 of 2): stop and send the findings to firstmate for triage' 'cap refusal must name triage'
[ -f "$NM_CAP_OVERRIDE_DIR/$RUN.review-3" ] || fail 'read-only preflight changed a token file'
[ -z "$(ls -A "$NM_CAP_OVERRIDE_DIR/consumed")" ] || fail 'read-only preflight wrote token state'
pass 'token file cannot authorize a capped fix and remains untouched'

sqlite3 "$NM_CAP_DB" "DELETE FROM agent_invocations WHERE run_id='$RUN' AND purpose='review' AND round=2;"
for state in awaiting_approval fix_review; do
  sqlite3 "$NM_CAP_DB" "UPDATE step_results SET status='$state';"
  out=$(sh "$GUARD" axi respond --run "$RUN" --action fix 2>&1); rc=$?
  expect_code 0 "$rc" "first fix at $state must be allowed"
  assert_contains "$out" 'review round 1 of 2: fix allowed' 'review-fix invocation must not increase the count'
  pass "first fix allowed at $state"
done

out=$(sh "$GUARD" axi respond --run="$RUN" --step=review-step --action=fix 2>&1); rc=$?
expect_code 0 "$rc" 'explicit step ID and equals flags must work'
assert_contains "$out" 'review round 1 of 2: fix allowed' 'explicit step ID count'
pass 'explicit step ID and equals arguments are supported'

out=$(cd "$TMP/repo" && sh "$GUARD" axi respond fix 2>&1); rc=$?
expect_code 0 "$rc" 'implicit run must resolve the current branch'
assert_contains "$out" 'review round 1 of 2: fix allowed' 'implicit run count'
pass 'valid plus branch resolves within the current repository'

out=$(cd "$TMP/other-repo" && sh "$GUARD" axi respond fix 2>&1); rc=$?
expect_code 3 "$rc" 'the same branch in another repository must use its own run'
assert_contains "$out" 'review-round cap reached (2 of 2)' 'foreign repository count must not leak into current lookup'
pass 'implicit lookup is scoped by repository and branch'

sqlite3 "$NM_CAP_DB" "INSERT INTO agent_invocations VALUES ('$RUN', 'review', 'review', 3);"
out=$(sh "$GUARD" axi respond --run "$RUN" --action fix 2>&1); rc=$?
expect_code 3 "$rc" 'past the cap must be refused'
assert_contains "$out" 'review-round cap reached (3 of 2)' 'past-cap refusal must report the actual count'
pass 'past-cap review is refused'

sqlite3 "$NM_CAP_DB" "UPDATE step_results SET status='completed'; INSERT INTO step_results VALUES ('test-step', '$RUN', 'test', 'fix_review');"
out=$(sh "$GUARD" axi respond --run "$RUN" --action fix 2>&1); rc=$?
expect_code 0 "$rc" 'non-review fixes must remain allowed'
assert_contains "$out" "step 'test' is not review: allow" 'non-review gate selection'
pass 'non-review fix_review gate remains allowed'

for action in approve skip; do
  out=$(sh "$GUARD" axi respond --run "$RUN" --action "$action" 2>&1); rc=$?
  expect_code 0 "$rc" "$action is outside the fix cap"
done
pass 'approval and skip remain unchanged'

sqlite3 "$NM_CAP_DB" "UPDATE step_results SET status='completed';"
out=$(sh "$GUARD" axi respond --run "$RUN" --action fix 2>&1); rc=$?
expect_code 3 "$rc" 'missing gate must fail closed'
assert_contains "$out" 'escalate this review gate to firstmate' 'missing gate remediation'
pass 'missing gate fails closed'

sqlite3 "$NM_CAP_DB" "UPDATE step_results SET status='fix_review' WHERE step_name='review'; DELETE FROM agent_invocations;"
out=$(sh "$GUARD" axi respond --run "$RUN" --action fix 2>&1); rc=$?
expect_code 3 "$rc" 'missing count must fail closed'
assert_contains "$out" 'review round count could not be read' 'missing count diagnostic'
pass 'missing count fails closed'

out=$(NM_CAP_DB="$TMP/missing.sqlite" sh "$GUARD" axi respond --run "$RUN" --action fix 2>&1); rc=$?
expect_code 3 "$rc" 'unavailable store must fail closed'
[ ! -e "$TMP/missing.sqlite" ] || fail 'preflight must not create a database'
pass 'unavailable store fails closed without creating it'
