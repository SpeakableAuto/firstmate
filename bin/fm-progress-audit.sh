#!/usr/bin/env bash
# fm-progress-audit.sh - judge every recorded crew by the work it has landed,
# account for each one, and recover a stalled one by cause at most twice.
#
# Usage:
#   fm-progress-audit.sh account [<task-id>...]
#   fm-progress-audit.sh tick
#   fm-progress-audit.sh recover <task-id> [--dry-run]
#
# Why this exists. The watcher's stale path judges a crew by its pane: a pane
# whose rendered text stops changing while the agent is not busy. A crew that
# loops (busy, pane always changing) or narrates progress it never lands passes
# that check indefinitely. This check judges a ship or scout by durable work
# only, over a bounded window, and never by pane text or what the crew says it
# is doing:
#   push    the reflog time of refs/remotes/origin/<branch> or
#           refs/remotes/origin/wip/<id> in the task's local copy (a push
#           updates its remote-tracking ref);
#   commit  the committer time of the local copy's HEAD;
#   status  the [at=<epoch>] stamp of the newest recognized status event;
#   report  the modification time of data/<id>/report.md.
# The window clock also restarts at spawn (spawn_gen=s<epoch>.), at a declared
# pause's due time, and at each recovery attempt, so a fresh or just-recovered
# crew gets a full window before it is judged again.
#
# account: one line per recorded task record (state/<id>.meta), so no crew is
# unaccounted for. Each record lands in exactly one bucket:
#   live      progress or a fresh start inside the window;
#   waiting   a stated reason: an open decision or blocker for firstmate, a
#             declared pause not yet due, a captain hold, an active validation
#             run, an idle secondmate, or a remote endpoint read elsewhere;
#   finished  the newest event is done or failed: landing or cleanup is owed;
#   stalled   no progress for the whole window while the endpoint exists;
#   missing   the endpoint, the local copy, or the record itself is gone.
# Line shape (tab-free, parseable):
#   <id> · <bucket> · <cause-or-reason> · progress=<kind>@<age>|none · attempts=<n>/2 · next=<action>
# Only a stalled or missing candidate pays for the bounded endpoint probe
# (bin/fm-backend.sh fm_backend_agent_state) and, when the agent may be alive,
# the bounded current-state read (bin/fm-crew-state.sh), which turns an active
# validation run into waiting rather than stalled.
#
# Causes and the recovery each one gets (attempt 1, then attempt 2):
#   no-progress     agent present, nothing landed      steer, then relaunch
#   pause-overdue   declared pause past due, nothing   steer, then relaunch
#   agent-exited    endpoint present, agent gone       relaunch, then relaunch
#   endpoint-gone   endpoint authoritatively absent    relaunch, then relaunch
#   worktree-gone   the local copy is gone             escalate at once
#   record-unreadable the task record cannot be read   escalate at once
# Attempts count only since the newest real progress (push, commit, status,
# report), so a crew that recovers and lands work earns a fresh allowance.
# After two attempts with no progress since, the next due action is a single
# escalation; once it is recorded the check stays silent for that crew until
# it lands progress or its record is cleaned up.
#
# tick: the watcher calls this every poll; it runs at most once per
# FM_PROGRESS_AUDIT_SECS (default 600, valid 60..1800) per home, gated by the
# mtime of state/.progress-audit/.last-tick; the first call in a home only
# starts that cadence. Only when a crew newly needs action (entered stalled or
# missing, became due for its next attempt, or became due for its one
# escalation) does it append one durable `check` wake keyed progress-audit and
# print that reason as `wake: <reason>`; an unchanged fleet prints nothing.
# The reason names each crew with its cause and next action, at most FM_PROGRESS_AUDIT_WAKE_ITEMS (default 8) of them, then points
# at `account` for the rest. Surfaced signatures live in
# state/.progress-audit/<id>; a record with no task meta is pruned there.
# Endpoint and current-state reads stop starting once the
# FM_PROGRESS_AUDIT_BUDGET_SECS budget (default 20, valid 1..60) is spent; a
# crew left unconfirmed keeps its previous signature and is read next tick.
#
# recover: performs the due action for one crew and records the attempt in
# state/<id>.recovery (lines `attempt <epoch> <n> <cause> <action> <result>`
# and `escalated <epoch> <cause>`). A steer goes through bin/fm-send.sh and a
# relaunch through bin/fm-control.sh relaunch with a consolidated note: the
# cause, the last landed progress, the recent status events, the directives the
# previous worker already acknowledged in its steering inbox, and (for a ship)
# bin/fm-checkpoint-freshness.sh's verdict. A failed action still counts as an
# attempt. --dry-run prints the due action and changes nothing.
# Exit status: 0 acted or nothing is due, 1 the action failed, 2 usage,
# 3 escalation due (printed as `escalate: ...`; firstmate records the failure
# and tells the captain the preserved work and the consequence).
#
# Window: FM_PROGRESS_WINDOW_SECS (default 2400, valid 300..7200). With the
# default cadence a crew that stops landing work is surfaced within
# window + cadence = 50 minutes. FM_PROGRESS_AUDIT_NOW pins the clock for tests.
# Read-only for task work: it never edits a local copy, branch, or status log,
# and the only lifecycle actions it takes are recover's steer and relaunch.
set -u
export LC_ALL=C

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
AUDIT_DIR="$STATE/.progress-audit"
CREW_STATE_BIN="${FM_PROGRESS_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
SEND_BIN="${FM_PROGRESS_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"
CONTROL_BIN="${FM_PROGRESS_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"
FRESHNESS_BIN="${FM_PROGRESS_FRESHNESS_BIN:-$SCRIPT_DIR/fm-checkpoint-freshness.sh}"
# A test seam: a command that prints one fm_backend_agent_state word for
# <backend> <target>. Unset means the real backend classifier.
AGENT_STATE_BIN="${FM_PROGRESS_AGENT_STATE_BIN:-}"
RETRY_MAX=2

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

bounded_int() {  # <name> <value> <min> <max>
  case "$2" in ''|*[!0-9]*) ;; *)
    if [ "$2" -ge "$3" ] && [ "$2" -le "$4" ]; then return 0; fi ;;
  esac
  printf 'fm-progress-audit: %s must be a whole number from %s to %s\n' "$1" "$3" "$4" >&2
  exit 2
}

WINDOW=${FM_PROGRESS_WINDOW_SECS:-2400}
bounded_int FM_PROGRESS_WINDOW_SECS "$WINDOW" 300 7200
CADENCE=${FM_PROGRESS_AUDIT_SECS:-600}
bounded_int FM_PROGRESS_AUDIT_SECS "$CADENCE" 60 1800
BUDGET=${FM_PROGRESS_AUDIT_BUDGET_SECS:-20}
bounded_int FM_PROGRESS_AUDIT_BUDGET_SECS "$BUDGET" 1 60
WAKE_ITEMS=${FM_PROGRESS_AUDIT_WAKE_ITEMS:-8}
bounded_int FM_PROGRESS_AUDIT_WAKE_ITEMS "$WAKE_ITEMS" 1 50
PAUSE_FALLBACK=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
case "$PAUSE_FALLBACK" in ''|*[!0-9]*) PAUSE_FALLBACK=$FM_PAUSE_RESURFACE_SECS_DEFAULT ;; esac

now_epoch() {
  case "${FM_PROGRESS_AUDIT_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_PROGRESS_AUDIT_NOW" ;;
  esac
}
NOW=$(now_epoch)

if [ "$(uname)" = Darwin ]; then
  file_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

valid_id() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

one_line() {  # <text> <max-chars>
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-"$2"
}

age_words() {  # <seconds>
  local s=$1
  if [ "$s" -lt 120 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 7200 ]; then printf '%sm' $(( s / 60 ))
  else printf '%sh' $(( s / 3600 ))
  fi
}

iso_utc() {  # <epoch>
  TZ=UTC0 date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null \
    || TZ=UTC0 date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null \
    || printf '%s' "$1"
}

# --- evidence ----------------------------------------------------------------

# Latest push time of <ref> in <worktree>, from its reflog; empty when unknown.
ref_push_epoch() {  # <worktree> <ref>
  local out
  out=$(git -C "$1" reflog show --date=unix --format=%gd -n1 "$2" -- 2>/dev/null) || return 0
  out=${out##*@\{}
  out=${out%\}}
  case "$out" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$out"
}

# Sets EVIDENCE_KIND / EVIDENCE_EPOCH to the newest real progress of the task.
collect_evidence() {  # <id> <worktree> <branch>
  local id=$1 wt=$2 branch=$3 e line
  EVIDENCE_KIND=none
  EVIDENCE_EPOCH=0
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    if [ -n "$branch" ]; then
      e=$(ref_push_epoch "$wt" "refs/remotes/origin/$branch")
      consider_evidence push "$e"
    fi
    e=$(ref_push_epoch "$wt" "refs/remotes/origin/wip/$id")
    consider_evidence push "$e"
    e=$(git -C "$wt" log -1 --format=%ct HEAD 2>/dev/null || true)
    consider_evidence commit "$e"
  fi
  line=$(last_status_line "$STATE/$id.status")
  if [ -n "$line" ]; then
    e=$(status_line_at_epoch "$line" 2>/dev/null || true)
    consider_evidence status "$e"
  fi
  if [ -f "$DATA/$id/report.md" ]; then
    consider_evidence report "$(file_mtime "$DATA/$id/report.md")"
  fi
}

consider_evidence() {  # <kind> <epoch>
  case "$2" in ''|*[!0-9]*) return 0 ;; esac
  # A clock-skewed future stamp is not evidence of anything yet.
  [ "$2" -le "$NOW" ] || return 0
  if [ "$2" -gt "$EVIDENCE_EPOCH" ]; then
    EVIDENCE_EPOCH=$2
    EVIDENCE_KIND=$1
  fi
}

# --- recovery ledger ---------------------------------------------------------

# Sets ATTEMPTS (attempts since <since>), LAST_ATTEMPT_EPOCH, ESCALATED_EPOCH
# (escalation since <since>, else 0) from state/<id>.recovery.
read_ledger() {  # <id> <since>
  local id=$1 since=$2 kind epoch n cause action result
  ATTEMPTS=0
  LAST_ATTEMPT_EPOCH=0
  ESCALATED_EPOCH=0
  [ -f "$STATE/$id.recovery" ] && [ ! -L "$STATE/$id.recovery" ] || return 0
  while read -r kind epoch n cause action result; do
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    [ "$epoch" -gt "$since" ] || continue
    case "$kind" in
      attempt)
        ATTEMPTS=$((ATTEMPTS + 1))
        # Only an action that went through restarts the window; a failed one
        # still spends an attempt but leaves the next one due at once.
        if [ "$result" = ok ] && [ "$epoch" -gt "$LAST_ATTEMPT_EPOCH" ]; then
          LAST_ATTEMPT_EPOCH=$epoch
        fi
        ;;
      escalated) ESCALATED_EPOCH=$epoch ;;
    esac
  done < "$STATE/$id.recovery"
  : "$n" "$cause" "$action"
}

ledger_append() {  # <id> <line>
  printf '%s\n' "$2" >> "$STATE/$1.recovery"
}

# --- classification ----------------------------------------------------------

meta_value() {  # <meta> <key>
  fm_meta_get "$1" "$2"
}

spawn_epoch() {  # <spawn_gen>
  local g=${1#s}
  g=${g%%.*}
  case "$g" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$g"
}

probe_agent_state() {  # <backend> <target>
  local out rc=0
  if [ -n "$AGENT_STATE_BIN" ]; then
    out=$(fm_run_timed 10 "$AGENT_STATE_BIN" "$1" "$2" 2>/dev/null) || rc=$?
  else
    # shellcheck disable=SC2016 # Positional parameters expand inside the child bash.
    out=$(fm_run_timed 10 bash -c '. "$1"; fm_backend_agent_state "$2" "$3"' \
      fm-agent-state "$SCRIPT_DIR/fm-backend.sh" "$1" "$2" 2>/dev/null) || rc=$?
  fi
  [ "$rc" -eq 0 ] || out=unreadable
  case "$out" in alive|dead|missing|ambiguous|unreadable|unverified) printf '%s' "$out" ;; *) printf unreadable ;; esac
}

# The bounded current-state read; prints the crew-state line or nothing.
probe_crew_state() {  # <id>
  fm_run_timed 15 env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 \
    "$CREW_STATE_BIN" "$1" 2>/dev/null | head -1 || true
}

budget_left() {
  [ "${PROBE_DEADLINE:-0}" -eq 0 ] || [ "$(date +%s)" -lt "$PROBE_DEADLINE" ]
}

# classify <id>: sets BUCKET, CAUSE (stalled/missing) or REASON (other buckets),
# ATTEMPTS, ESCALATED_EPOCH, NEXT, EVIDENCE_KIND/EPOCH, KIND, and UNCONFIRMED=1
# when the probe budget ran out before a candidate could be read.
classify() {
  local id=$1 meta="$STATE/$1.meta" kind wt branch backend target remote_host
  local open line verb note until at start clock pause_due=0 agent cs e
  BUCKET='' CAUSE='' REASON='' NEXT=- UNCONFIRMED=0 KIND=''
  ATTEMPTS=0 ESCALATED_EPOCH=0 LAST_ATTEMPT_EPOCH=0
  EVIDENCE_KIND=none EVIDENCE_EPOCH=0
  if [ ! -f "$meta" ] || [ -L "$meta" ] || ! cat "$meta" >/dev/null 2>&1; then
    BUCKET=missing CAUSE=record-unreadable
    read_ledger "$id" 0
    next_action
    return 0
  fi
  kind=$(meta_value "$meta" kind)
  KIND=$kind
  remote_host=$(meta_value "$meta" remote_host)
  case "$kind" in
    ship|scout) ;;
    secondmate)
      BUCKET=waiting REASON="secondmate: idle by charter, supervised through its routed status"
      return 0 ;;
    *)
      BUCKET=waiting REASON="record kind '${kind:-none}' is not a ship or scout; reconcile it by hand"
      return 0 ;;
  esac
  if [ -n "$remote_host" ]; then
    BUCKET=waiting REASON="remote on $remote_host: liveness is read by that home"
    return 0
  fi
  wt=$(meta_value "$meta" worktree)
  branch=$(meta_value "$meta" branch)
  collect_evidence "$id" "$wt" "$branch"

  # The status log first: what the crew or firstmate has declared.
  open=$(status_open_decisions "$STATE/$id.status" "$kind")
  if [ -n "$open" ]; then
    line=$(printf '%s\n' "$open" | tail -1)
    BUCKET=waiting
    REASON="open $(printf '%s' "$line" | cut -f2) [key=$(printf '%s' "$line" | cut -f1)] for firstmate: $(one_line "$(printf '%s' "$line" | cut -f3-)" 80)"
    return 0
  fi
  line=$(status_declared_wait_line "$STATE/$id.status")
  [ -n "$line" ] || line=$(last_status_line "$STATE/$id.status")
  status_line_verb "$line" verb
  note=$(one_line "$(status_line_note "$line")" 80)
  case "$verb" in
    done|failed)
      BUCKET=finished REASON="$verb: $note; landing or cleanup is owed"
      return 0 ;;
    "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}")
      BUCKET=waiting REASON="held for the captain: $note"
      return 0 ;;
    "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      until=$(status_paused_until "$line" 2>/dev/null || true)
      if [ -z "$until" ]; then
        at=$(status_line_at_epoch "$line" 2>/dev/null || true)
        [ -n "$at" ] || at=$(file_mtime "$STATE/$id.status")
        [ -n "$at" ] || at=$NOW
        until=$((at + PAUSE_FALLBACK))
      fi
      if [ "$until" -gt "$NOW" ]; then
        BUCKET=waiting REASON="paused until $(iso_utc "$until"): $note"
        return 0
      fi
      pause_due=$until ;;
  esac

  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    BUCKET=missing CAUSE=worktree-gone
    read_ledger "$id" "$EVIDENCE_EPOCH"
    next_action
    return 0
  fi

  read_ledger "$id" "$EVIDENCE_EPOCH"
  start=$(spawn_epoch "$(meta_value "$meta" spawn_gen)")
  clock=$EVIDENCE_EPOCH
  for e in "${start:-0}" "$pause_due" "$LAST_ATTEMPT_EPOCH"; do
    [ "$e" -le "$clock" ] || clock=$e
  done
  if [ "$clock" -gt 0 ] && [ $((NOW - clock)) -lt "$WINDOW" ]; then
    BUCKET=live
    if [ "$EVIDENCE_EPOCH" -gt 0 ] && [ "$EVIDENCE_EPOCH" -ge "$clock" ]; then
      REASON="landed a $EVIDENCE_KIND $(age_words $((NOW - EVIDENCE_EPOCH))) ago"
    else
      REASON="inside its window since $(iso_utc "$clock"); nothing landed yet"
    fi
    return 0
  fi

  # A candidate: prove what is there before calling it stalled.
  if ! budget_left; then
    BUCKET=stalled CAUSE=no-progress UNCONFIRMED=1
    next_action
    return 0
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  if [ -z "$target" ]; then
    agent=missing
  else
    agent=$(probe_agent_state "$backend" "$target")
  fi
  case "$agent" in
    missing) BUCKET=missing CAUSE=endpoint-gone ;;
    dead) BUCKET=stalled CAUSE=agent-exited ;;
    *)
      cs=$(probe_crew_state "$id")
      case "$cs" in
        "state: working · source: run-step"*|"state: parked · source: run-step"*)
          BUCKET=waiting
          REASON="validation run: $(one_line "${cs#state: }" 100)"
          return 0 ;;
      esac
      BUCKET=stalled
      if [ "$pause_due" -gt 0 ]; then CAUSE='pause-overdue'; else CAUSE='no-progress'; fi
      ;;
  esac
  next_action
}

# NEXT: the due action for a stalled or missing crew.
next_action() {
  if [ "$ESCALATED_EPOCH" -gt 0 ]; then
    NEXT="escalated $(iso_utc "$ESCALATED_EPOCH"); firstmate records the failure"
    return 0
  fi
  case "$CAUSE" in
    worktree-gone|record-unreadable) NEXT=escalate; return 0 ;;
  esac
  if [ "$ATTEMPTS" -ge "$RETRY_MAX" ]; then
    NEXT=escalate
    return 0
  fi
  case "$CAUSE" in
    no-progress|pause-overdue)
      if [ "$ATTEMPTS" -eq 0 ]; then NEXT=steer; else NEXT=relaunch; fi ;;
    *) NEXT=relaunch ;;
  esac
}

render_line() {  # <id>
  local detail progress
  case "$BUCKET" in
    stalled|missing) detail=$CAUSE ;;
    *) detail=$REASON ;;
  esac
  [ "$UNCONFIRMED" -eq 0 ] || detail="$detail (unconfirmed: probe budget spent)"
  if [ "$EVIDENCE_EPOCH" -gt 0 ]; then
    progress="$EVIDENCE_KIND@$(age_words $((NOW - EVIDENCE_EPOCH)))"
  else
    progress=none
  fi
  printf '%s · %s · %s · progress=%s · attempts=%s/%s · next=%s\n' \
    "$1" "$BUCKET" "$detail" "$progress" "$ATTEMPTS" "$RETRY_MAX" "$NEXT"
}

recorded_ids() {
  local m id
  for m in "$STATE"/*.meta; do
    [ -e "$m" ] || [ -L "$m" ] || continue
    id=${m##*/}
    id=${id%.meta}
    valid_id "$id" || continue
    printf '%s\n' "$id"
  done
}

cmd_account() {
  local id
  PROBE_DEADLINE=0
  if [ "$#" -eq 0 ]; then
    recorded_ids | while IFS= read -r id; do
      classify "$id"
      render_line "$id"
    done
    return 0
  fi
  for id in "$@"; do
    valid_id "$id" || { echo "fm-progress-audit: invalid task id: $id" >&2; exit 2; }
    classify "$id"
    render_line "$id"
  done
}

# --- tick --------------------------------------------------------------------

cmd_tick() {
  local id sig prev items=0 total=0 wake='' marker="$AUDIT_DIR/.last-tick" age reason
  local pending='' line
  mkdir -p "$AUDIT_DIR" 2>/dev/null || exit 1
  # The first call in a home only starts the cadence, so a watcher that has
  # just been set up gives its crews one cadence before the first roll-call.
  if [ ! -e "$marker" ]; then
    touch "$marker" || exit 1
    exit 0
  fi
  age=$((NOW - $(file_mtime "$marker" || echo 0)))
  [ "$age" -ge "$CADENCE" ] || exit 0
  # Claim the cadence before the scan, so a scan that dies is not retried on
  # every poll.
  touch "$marker" || exit 1
  PROBE_DEADLINE=$(( $(date +%s) + BUDGET ))
  while IFS= read -r id; do
    classify "$id"
    case "$BUCKET" in
      stalled|missing)
        [ "$UNCONFIRMED" -eq 0 ] || continue
        sig="$BUCKET:$CAUSE:$ATTEMPTS:$NEXT"
        case "$NEXT" in escalated*) sig="$BUCKET:$CAUSE:escalated" ;; esac
        ;;
      *) sig= ;;
    esac
    if [ -z "$sig" ]; then
      rm -f "$AUDIT_DIR/$id"
      continue
    fi
    prev=$(cat "$AUDIT_DIR/$id" 2>/dev/null || true)
    [ "$sig" != "$prev" ] || continue
    pending="$pending$id $sig"$'\n'
    case "$NEXT" in escalated*) continue ;; esac
    total=$((total + 1))
    if [ "$items" -lt "$WAKE_ITEMS" ]; then
      wake="$wake${wake:+; }$id $BUCKET $CAUSE, next $NEXT"
      items=$((items + 1))
    fi
  done < <(recorded_ids)
  for prev in "$AUDIT_DIR"/*; do
    [ -f "$prev" ] || continue
    id=${prev##*/}
    [ -e "$STATE/$id.meta" ] || rm -f "$prev"
  done
  if [ "$total" -gt 0 ]; then
    [ "$total" -le "$items" ] || wake="$wake; and $((total - items)) more"
    reason="check: progress-audit: $total crew need recovery by cause ($wake); run bin/fm-progress-audit.sh recover <id> for each, and account for the full roll-call"
    # Durable before the signatures move: a crash in between repeats the wake
    # next tick rather than losing it.
    fm_wake_append check progress-audit "$reason" || exit 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "${line#* }" > "$AUDIT_DIR/${line%% *}" || exit 1
  done <<EOF
$pending
EOF
  [ "$total" -eq 0 ] || printf 'wake: %s\n' "$reason"
}

# --- recover -----------------------------------------------------------------

steer_text() {  # <id>
  printf 'Progress check: this task has landed nothing (no push, commit, status line or report update) for %s. Land your progress now: commit and push a checkpoint, or update your report; if you are waiting on something, append a paused: line with its until time; if you are stuck, append a blocked: line naming what stops you.' \
    "$(age_words "$WINDOW")"
}

relaunch_note() {  # <id> <attempt>
  local id=$1 n=$2 meta="$STATE/$1.meta" events handled f fresh wt mode branch
  printf 'Relaunched by the progress check: cause %s, attempt %s of %s.\n' "$CAUSE" "$n" "$RETRY_MAX"
  if [ "$EVIDENCE_EPOCH" -gt 0 ]; then
    printf 'Last landed progress: a %s at %s.\n' "$EVIDENCE_KIND" "$(iso_utc "$EVIDENCE_EPOCH")"
  else
    printf 'Last landed progress: none recorded since the task started.\n'
  fi
  events=$(grep -E '^[a-z-]+( \[[^]]*\])*:' "$STATE/$id.status" 2>/dev/null | tail -3 || true)
  if [ -n "$events" ]; then
    printf 'Recent status events:\n%s\n' "$events"
  fi
  handled=
  for f in "$STATE/$id.inbox/handled"/*.msg; do
    [ -f "$f" ] || continue
    handled="$handled ${f##*/}"
  done
  if [ -n "$handled" ]; then
    printf 'Directives the previous worker already acknowledged still apply: read each of%s in %s in numeric order before continuing.\n' \
      "$handled" "$STATE/$id.inbox/handled"
  fi
  if [ "$KIND" = ship ]; then
    wt=$(meta_value "$meta" worktree)
    mode=$(meta_value "$meta" mode)
    branch=$(meta_value "$meta" branch)
    fresh=$(fm_run_timed 30 "$FRESHNESS_BIN" "$wt" "$STATE/$id.status" "$mode" "$branch" "wip/$id" 2>&1 | head -8 || true)
    [ -z "$fresh" ] || printf 'Checkpoint freshness at relaunch:\n%s\n' "$fresh"
  fi
  printf 'Land progress early: commit and push a checkpoint as soon as you have one.\n'
}

cmd_recover() {
  local id=${1:-} dry=0 lock rc=0 n out
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  case "${1:-}" in
    --dry-run) dry=1 ;;
    '') ;;
    *) usage >&2; exit 2 ;;
  esac
  valid_id "$id" || { echo "fm-progress-audit: invalid task id: $id" >&2; exit 2; }
  [ -e "$STATE/$id.meta" ] || [ -L "$STATE/$id.meta" ] \
    || { echo "fm-progress-audit: no task record for $id" >&2; exit 2; }
  PROBE_DEADLINE=0
  lock="$STATE/.progress-recover-$id.lock"
  if [ "$dry" -eq 0 ]; then
    fm_lock_try_acquire "$lock" || { echo "fm-progress-audit: another recovery of $id is running" >&2; exit 1; }
    trap 'fm_lock_release "$lock"' EXIT
  fi
  classify "$id"
  case "$BUCKET" in
    stalled|missing) ;;
    *) render_line "$id"; echo "nothing due: $id is $BUCKET"; exit 0 ;;
  esac
  case "$NEXT" in
    escalated*) render_line "$id"; echo "nothing due: $id was already escalated"; exit 0 ;;
    escalate)
      case "$CAUSE" in
        worktree-gone|record-unreadable)
          out="escalate: $id $BUCKET ($CAUSE): no recovery can run; check its branch and PR for landed work, then clean up the record or record the failure" ;;
        *)
          out="escalate: $id $BUCKET ($CAUSE) after $ATTEMPTS recovery attempt(s) with no progress landed since; its local copy and branch are preserved - record the failure and tell the captain the consequence" ;;
      esac
      if [ "$dry" -eq 1 ]; then echo "would $out"; exit 3; fi
      ledger_append "$id" "escalated $NOW $CAUSE" || exit 1
      echo "$out"
      exit 3 ;;
  esac
  n=$((ATTEMPTS + 1))
  if [ "$dry" -eq 1 ]; then
    echo "would $NEXT $id (cause $CAUSE, attempt $n of $RETRY_MAX)"
    exit 0
  fi
  case "$NEXT" in
    steer)
      out=$(FM_HOME="$FM_HOME" "$SEND_BIN" "$id" "$(steer_text "$id")" 2>&1) || rc=$?
      ;;
    relaunch)
      out=$(FM_HOME="$FM_HOME" "$CONTROL_BIN" "$id" relaunch --note "$(relaunch_note "$id" "$n")" 2>&1) || rc=$?
      ;;
  esac
  if [ "$rc" -eq 0 ]; then
    ledger_append "$id" "attempt $NOW $n $CAUSE $NEXT ok" || exit 1
    echo "$NEXT $id: cause $CAUSE, attempt $n of $RETRY_MAX"
    exit 0
  fi
  ledger_append "$id" "attempt $NOW $n $CAUSE $NEXT failed" || exit 1
  echo "$NEXT $id failed (cause $CAUSE, attempt $n of $RETRY_MAX): $(one_line "$out" 300)"
  exit 1
}

case "${1:-}" in
  account) shift; cmd_account "$@" ;;
  tick) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_tick ;;
  recover) shift; cmd_recover "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
