#!/usr/bin/env bash
# Exercise the preflight alone against a real SQLite store, never a live response.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v sqlite3 >/dev/null 2>&1 || fail 'install sqlite3 to test review-round enforcement'
TMP=$(fm_test_tmproot fm-nm-review-round-cap)
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
export NM_CAP_DB="$TMP/state.sqlite" NM_CAP_BINARY=/bin/true NM_CAP_DRYRUN=1 NM_REVIEW_ROUND_CAP=2
GUARD="$ROOT/bin/fm-nm-review-round-cap.sh"
# Minimal, data-free shape of a real fix_review gate observed on no-mistakes.
# The historical run had two review invocations and a review-fix invocation.
RUN=01M62WGRRHNXS5KCMW6A07Q1PS
sqlite3 "$NM_CAP_DB" <<SQL
CREATE TABLE runs (id TEXT PRIMARY KEY, branch TEXT, created_at INTEGER);
CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, status TEXT);
CREATE TABLE agent_invocations (run_id TEXT, step_name TEXT, purpose TEXT, round INTEGER);
INSERT INTO runs VALUES ('$RUN', 'fixture-branch', 1);
INSERT INTO step_results VALUES ('review-step', '$RUN', 'review', 'fix_review');
INSERT INTO agent_invocations VALUES ('$RUN', 'review', 'review', 1);
INSERT INTO agent_invocations VALUES ('$RUN', 'review', 'review-fix', 2);
INSERT INTO agent_invocations VALUES ('$RUN', 'review', 'review', 2);
SQL

out=$(sh "$GUARD" axi status --run "$RUN" 2>&1); rc=$?
expect_code 0 "$rc" 'inspection must remain available'
pass 'status inspection is allowed'

out=$(sh "$GUARD" axi respond --run "$RUN" --step review --action fix 2>&1); rc=$?
expect_code 3 "$rc" 'explicit review must enforce the cap'
assert_contains "$out" 'already had 2 review round(s)' 'explicit selection must report the real count'
assert_contains "$out" 'firstmate for triage' 'refusal must name the next step'
pass 'explicit review reports the real capped count'

out=$(sh "$GUARD" axi respond --run "$RUN" --action fix 2>&1); rc=$?
expect_code 3 "$rc" 'implicit fix_review must enforce the cap'
assert_contains "$out" 'already had 2 review round(s)' 'fix_review must report the real count instead of unreadable'
assert_contains "$out" 'firstmate for triage' 'refusal must name the next step'
pass 'run-shaped fix_review gate reports two reviews and escalates'

sqlite3 "$NM_CAP_DB" "DELETE FROM agent_invocations WHERE purpose='review' AND round=2;"
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

git init -q "$TMP/repo"
git -C "$TMP/repo" symbolic-ref HEAD refs/heads/fixture-branch
out=$(cd "$TMP/repo" && sh "$GUARD" axi respond fix 2>&1); rc=$?
expect_code 0 "$rc" 'implicit run must resolve the current branch'
assert_contains "$out" 'review round 1 of 2: fix allowed' 'implicit run count'
pass 'current-branch run lookup and positional fix are supported'

sqlite3 "$NM_CAP_DB" "INSERT INTO agent_invocations VALUES ('$RUN', 'review', 'review', 3);"
out=$(sh "$GUARD" axi respond --run "$RUN" --action fix 2>&1); rc=$?
expect_code 3 "$rc" 'past the cap must be refused'
assert_contains "$out" 'already had 3 review round(s)' 'past-cap refusal must report the actual count'
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
