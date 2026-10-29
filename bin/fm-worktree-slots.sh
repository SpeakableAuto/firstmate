#!/usr/bin/env bash
# Inspect and reclaim this home's bounded Treehouse worktree slots.
# Usage:
#   fm-worktree-slots.sh room <project-dir>
#   fm-worktree-slots.sh reclaim [--dry-run]
#
# `room` is the side-effect-free room check a spawn or an admission gate calls
# before allocating a slot for <project-dir>. It prints exactly one line and
# exits 0 `allow: <reason>` or 1 `refuse: <reason>`; the reason names the cap,
# the slots held per pool, and how many are reclaimable. With no
# config/worktree-slot-cap it always allows.
# `reclaim` removes every reclaimable slot in this home's pools through
# Treehouse's own safe destroy, re-proving each under its project lock, and
# prints one `reclaimed:`, `kept:`, or (with --dry-run) `would-reclaim:` line
# per free slot. It runs whether or not a cap is configured, so an operator can
# preview or clear released copies on demand.
# bin/fm-worktree-slots-lib.sh owns what counts as a slot, as reclaimable, and
# as room. Exit 2 is a usage error or an unreadable pool or home set.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
export FM_HOME

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-worktree-slots-lib.sh
. "$SCRIPT_DIR/fm-worktree-slots-lib.sh"

usage() {
  sed -n '2,18{s/^# \{0,1\}//;p;}' "$0" >&2
  exit 2
}

case "${1-}" in
  room)
    [ "$#" -eq 2 ] || usage
    if fm_worktree_slot_room "$CONFIG" "$PROJECTS" "$2" "$STATE"; then
      printf 'allow: %s\n' "$FM_WORKTREE_SLOT_ROOM_REASON"
      exit 0
    fi
    printf 'refuse: %s\n' "$FM_WORKTREE_SLOT_ROOM_REASON"
    exit 1
    ;;
  reclaim)
    mode=apply
    case "$#:${2-}" in
      1:) ;;
      2:--dry-run) mode=dry-run ;;
      *) usage ;;
    esac
    if ! fm_worktree_slots_scan "$PROJECTS"; then
      printf 'error: %s\n' "$FM_WORKTREE_SLOTS_ERROR" >&2
      exit 2
    fi
    fm_worktree_slots_reclaim "$STATE" "" "$mode" 0 || {
      echo "error: local Firstmate homes cannot be enumerated, so no further slot can be proved free" >&2
      exit 2
    }
    exit 0
    ;;
  -h|--help) sed -n '2,18{s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  *) usage ;;
esac
