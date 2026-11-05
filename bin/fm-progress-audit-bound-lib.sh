#!/usr/bin/env bash
# Audit-only bounded reads. Source this library; never pass crew lifecycle work.
# fm_progress_audit_run <state> <slot> <seconds> <command> [args...]
# uses fm_run_timed for a NEW command group, with regular-file output so a
# surviving descendant cannot hold the caller's output pipe open. The caller
# polls for at most seconds + 2 (plus one whole-second clock rounding interval),
# never waits for a kernel-stuck child, and returns 124 with partial stdout on
# timeout or an unreconciled prior invocation. Nonzero results are incomplete,
# never evidence of absent/completed work. The timeout library alone signals
# its newly created group; this library only checks liveness, never signals it.
#
# state/.progress-audit/.owned-<slot> retains owner, runner, group, stdout,
# stderr and result until all owned processes are gone. A later call may reclaim
# it only after its prior caller and runner exited (or the same serial caller
# returned), and the recorded group is absent. Incomplete ownership records
# fail closed for operator inspection;
# no retries accumulate behind a stuck process, and no recorded PID is killed.
# State must be on the reachable operational-home filesystem, not the task's
# suspect storage. No userspace deadline can bound the caller's own blocked
# state filesystem operations. Slots are tick or task-<validated task id>.
#
# fm_progress_audit_tick <state> <audit-script>
# bounds the entire synchronous tick (including script initialization) to the
# evidence budget + 2 seconds for publication, with the runner's cleanup margin
# above. Invalid budgets refuse with 2. The audit script owns budget range.

# shellcheck source=bin/fm-timeout-lib.sh
. "${BASH_SOURCE[0]%/*}/fm-timeout-lib.sh"

fm_progress_audit_group_gone() {
  local group
  [ -s "$1/group" ] || return 1
  read -r group < "$1/group"
  case "$group" in ''|0|1|*[!0-9]*) return 1 ;; esac
  ! kill -0 -- "-$group" 2>/dev/null
}

fm_progress_audit_run() {
  local state=$1 slot=$2 seconds=$3 dir owner runner current rc=124 deadline
  shift 3
  case "$slot" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
  case "$seconds" in ''|0*|*[!0-9]*) return 2 ;; esac
  current=${BASHPID:-$(exec /bin/sh -c 'printf "%s\n" "$PPID"')}
  dir="$state/.progress-audit/.owned-$slot"
  [ ! -L "$dir" ] || return 124
  mkdir -p "$state/.progress-audit" || return 1
  if [ -d "$dir" ]; then
    # Never reclaim a concurrent caller's output or an unaccounted-for child.
    owner='' runner=''
    read -r owner < "$dir/owner" 2>/dev/null || return 124
    read -r runner < "$dir/runner" 2>/dev/null || return 124
    case "$owner:$runner" in *[!0-9:]*|:*|*:) return 124 ;; esac
    if [ "$owner" != "$current" ]; then
      kill -0 "$owner" 2>/dev/null && return 124
    fi
    kill -0 "$runner" 2>/dev/null && return 124
    fm_progress_audit_group_gone "$dir" || return 124
    mkdir "$dir/reaping" 2>/dev/null || return 124
    # Another caller may have retired the old directory and acquired a new
    # slot between our reads and mkdir. Never remove that new invocation.
    if [ "$(cat "$dir/owner" 2>/dev/null)" != "$owner" ] || \
      [ "$(cat "$dir/runner" 2>/dev/null)" != "$runner" ]; then
      rmdir "$dir/reaping" 2>/dev/null || true
      return 124
    fi
    rm -rf "$dir"
  fi
  (umask 077; mkdir "$dir") 2>/dev/null || return 124
  owner=$current
  printf '%s\n' "$owner" > "$dir/owner" || return 1
  deadline=$((SECONDS + seconds + 2))
  (
    # The group is recorded from INSIDE the new timeout-owned command, before
    # any evidence read. It is never a worker, watcher, or inherited group.
    # shellcheck disable=SC2016
    fm_run_timed "$seconds" bash -c '
      dir=$1; shift
      group=$(ps -o pgid= -p "$$") || exit 125
      group=${group//[[:space:]]/}
      printf "%s\n" "$group" > "$dir/group" || exit 125
      exec "$@"
    ' fm-audit-read "$dir" "$@"
    rc=$?
    printf '%s\n' "$rc" > "$dir/result.tmp"
    mv "$dir/result.tmp" "$dir/result"
  ) </dev/null > "$dir/stdout" 2> "$dir/stderr" &
  runner=$!
  printf '%s\n' "$runner" > "$dir/runner"
  while [ ! -f "$dir/result" ] && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.1
  done
  if [ -f "$dir/result" ]; then
    read -r rc < "$dir/result"
    case "$rc" in ''|*[!0-9]*) rc=124 ;; esac
  fi
  cat "$dir/stdout"
  # Retain partial output and ownership on timeout, even if cleanup succeeded;
  # the next invocation verifies absence before starting another read.
  if [ "$rc" -eq 0 ] && fm_progress_audit_group_gone "$dir"; then
    rm -rf "$dir"
  elif [ "$rc" -eq 0 ]; then
    rc=124
  fi
  return "$rc"
}

fm_progress_audit_tick() {
  local budget=${FM_PROGRESS_AUDIT_BUDGET_SECS:-20}
  case "$budget" in ''|*[!0-9]*) return 2 ;; esac
  [ "$budget" -ge 1 ] && [ "$budget" -le 60 ] || return 2
  fm_progress_audit_run "$1" tick "$((budget + 2))" "$2" _tick
}
