#!/usr/bin/env bash
# Compare the latest status checkpoint with a branch on origin.
# Usage: fm-checkpoint-freshness.sh <worktree> <status-file> <branch>
# A checkpoint line records checkpoint_sha=<full SHA>. The caller chooses the
# remote branch: the ship branch after publication, or wip/<task-id> before it.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo 'usage: fm-checkpoint-freshness.sh <worktree> <status-file> <branch>' >&2
  exit 2
fi
worktree=$1 status_file=$2 branch=$3
[[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || { echo 'invalid branch' >&2; exit 2; }
[ -f "$status_file" ] || { echo 'checkpoint note missing' >&2; exit 1; }

line=$(grep 'checkpoint_sha=' "$status_file" | tail -n 1 || true)
if [ -z "$line" ]; then
  echo 'checkpoint note missing SHA'
  exit 1
fi
sha=$(printf '%s\n' "$line" | sed -n 's/.*checkpoint_sha=\([0-9a-fA-F]\{40\}\).*/\1/p')
if [ -z "$sha" ]; then
  echo 'checkpoint note missing SHA'
  exit 1
fi

if ! git -C "$worktree" fetch --no-tags origin "refs/heads/$branch" >/dev/null 2>&1; then
  echo "cannot read origin/$branch" >&2
  exit 2
fi
head=$(git -C "$worktree" rev-parse --verify FETCH_HEAD^{commit})
if [ "$sha" = "$head" ]; then
  echo "checkpoint note fresh at $head"
  exit 0
fi
if ! git -C "$worktree" cat-file -e "$sha^{commit}" 2>/dev/null; then
  echo "checkpoint SHA $sha is unavailable; cannot determine lag"
  exit 1
fi
if ! git -C "$worktree" merge-base --is-ancestor "$sha" "$head"; then
  echo "checkpoint SHA $sha is not an ancestor of origin/$branch ($head)"
  exit 1
fi
count=$(git -C "$worktree" rev-list --count "$sha..$head")
echo "note lags branch by $count commits (origin/$branch $head)"
git -C "$worktree" log --format='- %h %s' --reverse "$sha..$head"
exit 1
