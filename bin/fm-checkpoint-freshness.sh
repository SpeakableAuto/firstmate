#!/usr/bin/env bash
# Compare the latest status checkpoint with every pushed delivery head.
# Usage: fm-checkpoint-freshness.sh <worktree> <status-file> <mode> <branch> [branch...]
# A checkpoint line records checkpoint_sha=<full SHA>. Missing origin branches
# are ignored. A completed no-mistakes push contributes its pipeline head too.
set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo 'usage: fm-checkpoint-freshness.sh <worktree> <status-file> <mode> <branch> [branch...]' >&2
  exit 2
fi
worktree=$1 status_file=$2 mode=$3
shift 3
branches=("$@")
case "$mode" in
  direct-PR|no-mistakes) ;;
  *) echo 'invalid delivery mode' >&2; exit 2 ;;
esac
for branch in "${branches[@]}"; do
  [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || { echo 'invalid branch' >&2; exit 2; }
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

heads=()
labels=()
for branch in "${branches[@]}"; do
  if git -C "$worktree" fetch --no-tags origin "refs/heads/$branch" >/dev/null 2>&1; then
    head=$(git -C "$worktree" rev-parse --verify 'FETCH_HEAD^{commit}')
    heads+=("$head")
    labels+=("origin/$branch")
    continue
  fi
  if ! remote_head=$(git -C "$worktree" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null); then
    echo 'cannot read origin' >&2
    exit 2
  fi
  if [ -n "$remote_head" ]; then
    echo "cannot fetch origin/$branch" >&2
    exit 2
  fi
done

if [ "$mode" = no-mistakes ]; then
  command -v no-mistakes >/dev/null 2>&1 || { echo 'cannot read no-mistakes pipeline head' >&2; exit 2; }
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # shellcheck source=bin/fm-nm-run-lib.sh
  . "$script_dir/fm-nm-run-lib.sh"
  if ! pipeline_status=$(fm_nm_run_checked "$worktree" 15 axi status); then
    echo 'cannot read no-mistakes pipeline head' >&2
    exit 2
  fi
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$pipeline_status" branch)")
  pipeline_head=$(fm_nm_strip_quotes "$(fm_nm_field "$pipeline_status" head_sha)")
  [ -n "$pipeline_head" ] || pipeline_head=$(fm_nm_strip_quotes "$(fm_nm_field "$pipeline_status" head)")
  if [ "$run_branch" = "${branches[0]}" ] \
     && printf '%s\n' "$pipeline_status" | grep -Eq '^[[:space:]]*push,[[:space:]]*completed,'; then
    [[ "$pipeline_head" =~ ^[0-9a-fA-F]{40}$ ]] \
      || { echo 'no-mistakes pushed head is invalid' >&2; exit 2; }
    heads+=("$pipeline_head")
    labels+=("no-mistakes/$run_branch")
  fi
fi

[ "${#heads[@]}" -gt 0 ] || { echo 'no pushed delivery head is available' >&2; exit 2; }
if ! git -C "$worktree" cat-file -e "$sha^{commit}" 2>/dev/null; then
  echo "checkpoint SHA $sha is unavailable; cannot determine lag"
  exit 1
fi

stale=0
contained=0
checked=
index=0
while [ "$index" -lt "${#heads[@]}" ]; do
  head=${heads[$index]}
  label=${labels[$index]}
  checked="${checked:+$checked, }$label"
  if [ "$sha" != "$head" ] && ! git -C "$worktree" cat-file -e "$head^{commit}" 2>/dev/null; then
    echo "checkpoint SHA $sha differs from pushed head $head ($label); the pushed commit is unavailable locally"
    stale=1
    index=$((index + 1))
    continue
  fi
  if git -C "$worktree" merge-base --is-ancestor "$sha" "$head"; then
    contained=1
    if [ "$sha" != "$head" ]; then
      count=$(git -C "$worktree" rev-list --count "$sha..$head")
      echo "note lags branch by $count commits ($label $head)"
      git -C "$worktree" log --format='- %h %s' --reverse "$sha..$head"
      stale=1
    fi
  elif ! git -C "$worktree" merge-base --is-ancestor "$head" "$sha"; then
    echo "checkpoint SHA $sha diverges from $label ($head)"
    git -C "$worktree" log --format='- %h %s' --reverse "$sha..$head"
    stale=1
  fi
  index=$((index + 1))
done
[ "$stale" -eq 0 ] || exit 1
if [ "$contained" -eq 0 ]; then
  echo "checkpoint SHA $sha is not present on any checked remote branch ($checked)"
  exit 1
fi
echo "checkpoint note fresh at $sha across $checked"
