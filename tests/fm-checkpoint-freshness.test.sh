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
REAL_GIT=$(command -v git)
printf 'one\n' > "$TMP/worktree/file"
git -C "$TMP/worktree" add file
git -C "$TMP/worktree" commit -qm 'first checkpoint'
first=$(git -C "$TMP/worktree" rev-parse HEAD)
git -C "$TMP/worktree" push -q origin HEAD:refs/heads/wip/task
git -C "$TMP/worktree" push -q origin HEAD:refs/heads/fm/task
printf 'working: checkpoint_sha=%s done=first\n' "$first" > "$TMP/status"

out=$(bash "$ROOT/bin/fm-checkpoint-freshness.sh" "$TMP/worktree" "$TMP/status" direct-PR fm/task wip/task 2>&1); rc=$?
expect_code 0 "$rc" 'matching checkpoint should be fresh'
assert_contains "$out" "checkpoint note fresh at $first" 'fresh result lost exact commit'
pass 'matching checkpoint is fresh'

printf 'two\n' >> "$TMP/worktree/file"
git -C "$TMP/worktree" commit -qam 'step three shipped'
second=$(git -C "$TMP/worktree" rev-parse HEAD)
git -C "$TMP/worktree" push -q origin HEAD:refs/heads/staged
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = fetch ] && [ ! -e "$FM_TEST_FETCH_MOVED" ]; then
    : > "$FM_TEST_FETCH_MOVED"
    "$FM_TEST_REAL_GIT" --git-dir="$FM_TEST_REMOTE" update-ref refs/heads/wip/task "$FM_TEST_NEW_HEAD"
  fi
done
exec "$FM_TEST_REAL_GIT" "$@"
SH
chmod +x "$TMP/fakebin/git"
out=$(PATH="$TMP/fakebin:$PATH" FM_TEST_FETCH_MOVED="$TMP/fetch-moved" \
  FM_TEST_REAL_GIT="$REAL_GIT" FM_TEST_REMOTE="$TMP/origin.git" FM_TEST_NEW_HEAD="$second" \
  bash "$ROOT/bin/fm-checkpoint-freshness.sh" "$TMP/worktree" "$TMP/status" direct-PR fm/task wip/task 2>&1); rc=$?
expect_code 1 "$rc" 'lagging checkpoint should return a stale verdict'
assert_contains "$out" 'note lags branch by 1 commits' 'lag count missing'
assert_contains "$out" 'origin/wip/task' 'newer checkpoint ref was hidden by the older ship branch'
assert_contains "$out" 'step three shipped' 'lagging commit subject missing'
pass 'freshness verdict uses the fetched branch head'

printf 'working: checkpoint_sha=%s done=second\n' "$second" > "$TMP/status"
out=$(bash "$ROOT/bin/fm-checkpoint-freshness.sh" "$TMP/worktree" "$TMP/status" direct-PR fm/task wip/task 2>&1); rc=$?
expect_code 0 "$rc" 'an older ship branch should not make the newer checkpoint stale'
assert_contains "$out" "checkpoint note fresh at $second" 'fresh checkpoint was rejected because the ship branch is older'
pass 'newer checkpoint is fresh across an older ship branch'

git init --bare -q "$TMP/fork.git"
printf 'three\n' >> "$TMP/worktree/file"
git -C "$TMP/worktree" commit -qam 'pipeline fix pushed to fork'
third=$(git -C "$TMP/worktree" rev-parse HEAD)
git -C "$TMP/worktree" push -q "$TMP/fork.git" HEAD:refs/heads/fm/task
cat > "$TMP/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = 'axi status' ] || exit 2
cat <<EOF
run:
  branch: fm/task
  status: running
  head: ${FM_TEST_PIPELINE_HEAD:0:8}
  head_sha: $FM_TEST_PIPELINE_HEAD
  steps[2]{step,status,findings,duration_ms}:
    push,completed,0,1
    pr,pending,0,0
EOF
SH
chmod +x "$TMP/fakebin/no-mistakes"
out=$(PATH="$TMP/fakebin:$PATH" FM_TEST_FETCH_MOVED="$TMP/fetch-moved" \
  FM_TEST_REAL_GIT="$REAL_GIT" FM_TEST_REMOTE="$TMP/origin.git" FM_TEST_NEW_HEAD="$second" \
  FM_TEST_PIPELINE_HEAD="$third" \
  bash "$ROOT/bin/fm-checkpoint-freshness.sh" "$TMP/worktree" "$TMP/status" no-mistakes fm/task wip/task 2>&1); rc=$?
expect_code 1 "$rc" 'fork-pushed pipeline head should make the older checkpoint stale'
assert_contains "$out" 'no-mistakes/fm/task' 'fork-pushed pipeline head was not compared'
assert_contains "$out" 'pipeline fix pushed to fork' 'fork-pushed commit subject missing'
pass 'completed no-mistakes fork push participates in freshness'

printf 'working: done=first next=step-three\n' > "$TMP/status"
out=$(bash "$ROOT/bin/fm-checkpoint-freshness.sh" "$TMP/worktree" "$TMP/status" direct-PR fm/task wip/task 2>&1); rc=$?
expect_code 1 "$rc" 'checkpoint without a SHA cannot be trusted'
assert_contains "$out" 'checkpoint note missing SHA' 'missing SHA not reported'
pass 'checkpoint without SHA is reported'
