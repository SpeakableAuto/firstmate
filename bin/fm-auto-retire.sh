#!/usr/bin/env bash
# Retire a task automatically once its work has landed or a captain decision
# closed it, so a finished worker does not linger as a parked pane that keeps
# drawing rechecks.
# Usage: fm-auto-retire.sh [--emit-wake] <task-id> merged|decision
#   merged    the task's PR was merged (bin/fm-watch.sh's merge poll).
#   decision  a captain decision closed the task (bin/fm-captain-hold.sh).
#   --emit-wake prints the outcome's wake payload as a second stdout line,
#             `wake: <payload>`, instead of appending it, for a caller that is
#             itself the watcher and must append and deliver its own wakes.
# The retirement is exactly bin/fm-teardown.sh <task-id> with no flags: never
# --force and never --legacy-record, so every landed-work, captain-call, slot
# ownership and endpoint guard teardown owns still decides, and a task with
# unlanded work is refused and left untouched rather than cleaned up.
# A second mate is never retired here: it is persistent and is retired only on
# an explicit decision (AGENTS.md section 6).
# Every attempted retirement leaves one durable `check` wake row keyed
# auto-retire-<task-id>, whether teardown cleaned the task up or refused, so
# the supervisor learns the outcome even when the caller discards this
# script's output (a keyed-answer channel does). No row is written when there
# is nothing to retire.
# A refusal is attempted and reported once per cause for one spawned
# incarnation: state/<id>.auto-retire-refused records the cause and the
# record's spawn_gen, so a re-observed merge cannot re-run a refused teardown
# and re-wake the supervisor for the same refusal, while a respawned task of
# the same id is attempted afresh. Resolving the refusal is the supervisor's,
# through an ordinary bin/fm-teardown.sh run.
# Prints one line (plus the --emit-wake line) and exits:
#   0 `retired: <id>`             teardown cleaned the task up
#   0 `absent: <id>`              no task record left: nothing to retire
#   0 `skipped: <id>: <why>`      a second mate, never retired automatically, or
#                                 a task whose interrupted cleanup session
#                                 start replays
#   0 `already-refused: <id>`     this refusal was already attempted and reported
#   1 `refused: <id>: <reason>`   teardown refused or did not finish; nothing
#                                 was forced, so unlanded work stays in place
#   2                             invalid request, nothing attempted
# FM_TEARDOWN_BIN overrides the teardown executable for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  echo "usage: fm-auto-retire.sh [--emit-wake] <task-id> merged|decision" >&2
  exit 2
}
EMIT=0
if [ "${1-}" = --emit-wake ]; then EMIT=1; shift; fi
if [ "$#" -ne 2 ] || ! fm_pr_task_id_valid "$1"; then usage; fi
ID=$1
case "$2" in
  merged) CAUSE="its PR merged" ;;
  decision) CAUSE="a captain decision closed it" ;;
  *) usage ;;
esac

# The one wording of the outcome row, appended here or handed to the caller.
report() {  # <stdout-line> <wake-payload>
  printf '%s\n' "$1"
  if [ "$EMIT" = 1 ]; then
    printf 'wake: %s\n' "$2"
  else
    fm_wake_append check "auto-retire-$ID" "$2" || true
  fi
}
if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
  echo "error: state directory is unavailable" >&2
  exit 2
fi

META="$STATE/$ID.meta"
REFUSED="$STATE/$ID.auto-retire-refused"

refusal_marker_safe_or_absent() {
  if [ ! -e "$REFUSED" ] && [ ! -L "$REFUSED" ]; then
    return 0
  fi
  [ -f "$REFUSED" ] && [ ! -L "$REFUSED" ] \
    && [ "$(fm_pr_file_link_count "$REFUSED" 2>/dev/null)" = 1 ]
}

report_unsafe_refusal_marker() {
  local reason="unsafe automatic-retirement refusal marker state/$ID.auto-retire-refused"
  report "refused: $ID: $reason" \
    "check: auto-retire $ID: automatic cleanup after $CAUSE did not complete and nothing was forced: $reason"
  exit 1
}

write_refusal_marker() {
  local attempt=$1 tmp state_device
  refusal_marker_safe_or_absent || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.$ID.auto-retire-refused.XXXXXX") || return 1
  if ! printf '%s\n' "$attempt" > "$tmp" \
    || ! chmod 600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! refusal_marker_safe_or_absent \
    || ! mv -f -- "$tmp" "$REFUSED"; then
    rm -f -- "$tmp"
    return 1
  fi
}

if [ ! -e "$META" ]; then
  rm -f "$REFUSED"
  printf 'absent: %s\n' "$ID"
  exit 0
fi
if [ "$(fm_meta_get "$META" kind)" = secondmate ]; then
  printf 'skipped: %s: a second mate is retired only on an explicit decision\n' "$ID"
  exit 0
fi
# An interrupted earlier cleanup is session start's to replay from its own
# pending-close record; a fresh teardown here would rewrite that record.
if [ -e "$STATE/$ID.backlog-close" ] || [ -L "$STATE/$ID.backlog-close" ]; then
  printf 'skipped: %s: an interrupted cleanup is pending its session-start replay\n' "$ID"
  exit 0
fi

attempt="$2 $(fm_meta_get "$META" spawn_gen)"
if [ -e "$REFUSED" ] || [ -L "$REFUSED" ]; then
  refusal_marker_safe_or_absent || report_unsafe_refusal_marker
  refused_identity=$(fm_pr_file_identity "$REFUSED") || report_unsafe_refusal_marker
  refused_attempt=$(cat "$REFUSED" 2>/dev/null) || report_unsafe_refusal_marker
  refusal_marker_safe_or_absent || report_unsafe_refusal_marker
  [ "$(fm_pr_file_identity "$REFUSED" 2>/dev/null)" = "$refused_identity" ] \
    || report_unsafe_refusal_marker
  if [ "$refused_attempt" = "$attempt" ]; then
    printf 'already-refused: %s\n' "$ID"
    exit 0
  fi
fi

out=$(FM_STATE_OVERRIDE="$STATE" "${FM_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}" "$ID" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  rm -f "$REFUSED"
  report "retired: $ID" "check: auto-retire $ID: cleaned up automatically after $CAUSE"
  exit 0
fi
# A concurrent cleanup that won the task's lock leaves nothing to report, but a
# cleanup that removed the record and then failed its backlog close (its
# pending-close record survives) is still reported.
if [ ! -e "$META" ] && [ ! -e "$STATE/$ID.backlog-close" ]; then
  rm -f "$REFUSED"
  printf 'absent: %s\n' "$ID"
  exit 0
fi
reason=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | grep -i 'error\|refus' | tail -1)
[ -n "$reason" ] || reason=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)
[ -n "$reason" ] || reason="teardown exited $rc"
reason=$(printf '%s' "$reason" | fm_wake_clean_field)
if ! write_refusal_marker "$attempt"; then
  refusal_marker_safe_or_absent || report_unsafe_refusal_marker
fi
report "refused: $ID: $reason" \
  "check: auto-retire $ID: automatic cleanup after $CAUSE did not complete and nothing was forced: $reason"
exit 1
