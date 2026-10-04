#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-checkpoint-freshness)
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worktree"
git -C "$TMP/worktree" config user.name Test
git -C "$TMP/worktree" config user.email test@example.invalid
git -C "$TMP/worktree" remote add origin "$TMP/origin.git"
printf 'one\n' > "$TMP/worktree/file"
git -C "$TMP/worktree" add file
git -C "$TMP/worktree" commit -qm 'first checkpoint'
first=$(git -C "$TMP/worktree" rev-parse HEAD)
git -C "$TMP/worktree" push -q origin HEAD:refs/heads/wip/task
printf 'working: checkpoint_sha=%s done=first\n' "$first" > "$TMP/status"

out=$(bash "$ROOT/bin/fm-checkpoint-freshness.sh" "$TMP/worktree" "$TMP/status" wip/task 2>&1); rc=$?
expect_code 0 "$rc" 'matching checkpoint should be fresh'
assert_contains "$out" "checkpoint note fresh at $first" 'fresh result lost exact commit'
pass 'matching checkpoint is fresh'

printf 'two\n' >> "$TMP/worktree/file"
git -C "$TMP/worktree" commit -qam 'step three shipped'
git -C "$TMP/worktree" push -q origin HEAD:refs/heads/wip/task
out=$(bash "$ROOT/bin/fm-checkpoint-freshness.sh" "$TMP/worktree" "$TMP/status" wip/task 2>&1); rc=$?
expect_code 1 "$rc" 'lagging checkpoint should return a stale verdict'
assert_contains "$out" 'note lags branch by 1 commits' 'lag count missing'
assert_contains "$out" 'step three shipped' 'lagging commit subject missing'
pass 'lagging checkpoint lists commits'

printf 'working: done=first next=step-three\n' > "$TMP/status"
out=$(bash "$ROOT/bin/fm-checkpoint-freshness.sh" "$TMP/worktree" "$TMP/status" wip/task 2>&1); rc=$?
expect_code 1 "$rc" 'checkpoint without a SHA cannot be trusted'
assert_contains "$out" 'checkpoint note missing SHA' 'missing SHA not reported'
pass 'checkpoint without SHA is reported'
