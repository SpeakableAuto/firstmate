#!/usr/bin/env bash
# Compare the latest status checkpoint with the relevant branches on origin.
# Usage: fm-checkpoint-freshness.sh <worktree> <status-file> <branch> [branch...]
# A checkpoint line records checkpoint_sha=<full SHA>. Missing branches are
# ignored, but every branch that exists on origin is checked.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo 'usage: fm-checkpoint-freshness.sh <worktree> <status-file> <branch> [branch...]' >&2
  exit 2
fi
worktree=$1 status_file=$2
shift 2
branches=("$@")
refs=()
for branch in "${branches[@]}"; do
  [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || { echo 'invalid branch' >&2; exit 2; }
  refs+=("refs/heads/$branch")
done
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

if ! remote_heads=$(git -C "$worktree" ls-remote --heads origin "${refs[@]}" 2>/dev/null); then
  echo 'cannot read origin' >&2
  exit 2
fi
fetch_refs=()
for branch in "${branches[@]}"; do
  head=$(printf '%s\n' "$remote_heads" | awk -v ref="refs/heads/$branch" '$2 == ref { print $1; exit }')
  [ -z "$head" ] || fetch_refs+=("refs/heads/$branch")
done
[ "${#fetch_refs[@]}" -gt 0 ] || { echo 'no checked branch exists on origin' >&2; exit 2; }
if ! git -C "$worktree" fetch --no-tags origin "${fetch_refs[@]}" >/dev/null 2>&1; then
  echo 'cannot fetch checked branches from origin' >&2
  exit 2
fi
if ! git -C "$worktree" cat-file -e "$sha^{commit}" 2>/dev/null; then
  echo "checkpoint SHA $sha is unavailable; cannot determine lag"
  exit 1
fi

stale=0
contained=0
checked=
for branch in "${branches[@]}"; do
  head=$(printf '%s\n' "$remote_heads" | awk -v ref="refs/heads/$branch" '$2 == ref { print $1; exit }')
  [ -n "$head" ] || continue
  checked="${checked:+$checked, }origin/$branch"
  if git -C "$worktree" merge-base --is-ancestor "$sha" "$head"; then
    contained=1
    if [ "$sha" != "$head" ]; then
      count=$(git -C "$worktree" rev-list --count "$sha..$head")
      echo "note lags branch by $count commits (origin/$branch $head)"
      git -C "$worktree" log --format='- %h %s' --reverse "$sha..$head"
      stale=1
    fi
  elif ! git -C "$worktree" merge-base --is-ancestor "$head" "$sha"; then
    echo "checkpoint SHA $sha diverges from origin/$branch ($head)"
    git -C "$worktree" log --format='- %h %s' --reverse "$sha..$head"
    stale=1
  fi
done
[ "$stale" -eq 0 ] || exit 1
if [ "$contained" -eq 0 ]; then
  echo "checkpoint SHA $sha is not present on any checked remote branch ($checked)"
  exit 1
fi
echo "checkpoint note fresh at $sha across $checked"
