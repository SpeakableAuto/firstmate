# shellcheck shell=bash
# fm-worktree-slots-lib.sh - the bounded Treehouse slot pool contract (one owner).
# Usage: . bin/fm-worktree-slots-lib.sh (after bin/fm-wake-lib.sh)
#
# WHY. A Treehouse pool keeps every slot it ever created: teardown returns a
# task's slot to the pool, where it waits, reset and clean, for the next spawn
# of that project. A machine that spawns across many projects therefore keeps
# one full copy per historical concurrent task of every project, and those
# copies only ever accumulate. This library bounds them for a home that opts in
# with config/worktree-slot-cap (docs/configuration.md owns the setting).
# Absent, nothing here runs and every caller keeps today's behaviour.
#
# CONTRACT.
#   - Counting. A home's slots are every slot in the Treehouse pool of each git
#     project under its projects/ directory, plus the spawning project, read
#     from Git worktree registrations and their pool state files, deduplicated
#     by slot path. No Treehouse command runs during a room check: status
#     itself heals and rewrites pool state.
#   - Room. fm_worktree_slot_room is the one separately callable room check:
#     it changes nothing, so a caller may re-run it freely. A spawn that would
#     allocate needs held < cap. At the cap, spawn first tries safe reclaim
#     and rechecks. This conservatively reserves one slot even if get could
#     reuse an existing copy; no speculative reuse can exceed the bound.
#   - Candidates. A slot can be considered only when its pool record says it is
#     unreserved, with no uncommitted changes or observed process, no
#     Firstmate slot-owner claim sits beside it (bin/fm-wake-lib.sh owns the
#     claim), and no task record in any local Firstmate home names it as its
#     worktree= or home=. This identifies candidates, not merge proof.
#     Removal itself goes through `treehouse destroy <slot> --yes` with
#     no --include-* flag, so Treehouse's own disposable class (merged, clean,
#     idle, unleased) is the last word and anything else is skipped.
#   - Merge-proved removal. bin/fm-teardown.sh removes a task's own slot right
#     after returning it only when the task's PR merge was proved by its own
#     pr_is_merged check, or for a scout whose report and completion gate
#     passed; fm_worktree_slot_remove_returned owns the removal.
#   - Locks. Every removal holds the slot's project lock
#     (fm_treehouse_project_lock_path), the same lock spawn and teardown hold
#     around allocation and return. A caller already holding one project's lock
#     names it so it is not re-acquired; a contended lock skips that slot.
#   - Tool floor. Removal requires a Treehouse whose destroy is safe by
#     default (its help offers --include-unlanded); an older Treehouse removes
#     nothing and says so.

if ! command -v fm_treehouse_project_lock_path >/dev/null 2>&1; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "${BASH_SOURCE[0]%/*}/fm-wake-lib.sh"
fi
if ! command -v fm_meta_get >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh
  . "${BASH_SOURCE[0]%/*}/fm-backend.sh"
fi
if ! command -v secondmate_registry_parse_line >/dev/null 2>&1; then
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "${BASH_SOURCE[0]%/*}/fm-secondmate-registry-lib.sh"
fi

FM_WORKTREE_SLOT_CAP_FILE=worktree-slot-cap
FM_WORKTREE_SLOT_CAP=
FM_WORKTREE_SLOTS_ERROR=

fm_worktree_slots_canonical_dir() {  # <dir>
  [ -n "$1" ] && [ -d "$1" ] || return 1
  ( CDPATH='' cd -- "$1" 2>/dev/null && pwd -P )
}

fm_worktree_slots_link_count() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

# Read config/worktree-slot-cap. Sets FM_WORKTREE_SLOT_CAP to the cap, or to
# empty when the file is absent (the opt-out). Returns 1 with
# FM_WORKTREE_SLOTS_ERROR for a file that is present but not exactly one
# positive decimal integer and one newline in a regular, single-linked file
# beneath a non-symlinked config directory (at most nine digits).
fm_worktree_slot_cap_read() {  # <config-dir>
  local dir=$1 path value
  FM_WORKTREE_SLOT_CAP=
  FM_WORKTREE_SLOTS_ERROR=
  path="$dir/$FM_WORKTREE_SLOT_CAP_FILE"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  if [ -L "$dir" ] || [ ! -d "$dir" ] || [ -L "$path" ] || [ ! -f "$path" ] \
     || [ "$(fm_worktree_slots_link_count "$path")" != 1 ]; then
    FM_WORKTREE_SLOTS_ERROR="config/$FM_WORKTREE_SLOT_CAP_FILE must be a regular, single-linked file in a real config directory"
    return 1
  fi
  value=$(<"$path") || {
    FM_WORKTREE_SLOTS_ERROR="config/$FM_WORKTREE_SLOT_CAP_FILE could not be read"
    return 1
  }
  case "$value" in
    ''|0*|*[!0-9]*) value= ;;
  esac
  if [ -z "$value" ] || [ "${#value}" -gt 9 ] || ! printf '%s\n' "$value" | cmp -s "$path" -; then
    FM_WORKTREE_SLOTS_ERROR="config/$FM_WORKTREE_SLOT_CAP_FILE must hold one positive integer (at most 9 digits) followed by one newline"
    return 1
  fi
  FM_WORKTREE_SLOT_CAP=$value
}

# Every local Firstmate home's state directory, starting with <record-state>:
# the root home reached by fm_firstmate_root_home and every local secondmate
# home its registries name, recursively. Remote registry entries are skipped
# because their records live on another machine. Sets TREEHOUSE_OWNER_STATES.
collect_local_firstmate_states() {  # <record-state>
  local record_state=$1 root home reg line child known existing i=0
  local -a homes
  TREEHOUSE_OWNER_STATES=("$record_state")
  root=$(fm_firstmate_root_home "$FM_HOME") || {
    echo "REFUSED: cannot resolve the root Firstmate home; nothing was changed" >&2
    return 1
  }
  homes=("$root")
  while [ "$i" -lt "${#homes[@]}" ]; do
    home=${homes[$i]}
    i=$((i + 1))
    known=0
    for existing in "${TREEHOUSE_OWNER_STATES[@]}"; do
      [ "$existing" != "$home/state" ] || known=1
    done
    [ "$known" = 1 ] || TREEHOUSE_OWNER_STATES+=("$home/state")
    reg="$home/data/secondmates.md"
    [ ! -e "$reg" ] && [ ! -L "$reg" ] && continue
    [ -f "$reg" ] && [ ! -L "$reg" ] || {
      echo "REFUSED: local Firstmate registry is unsafe at $reg; nothing was changed" >&2
      return 1
    }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "- "*)
          secondmate_registry_parse_line "$line" || {
            echo "REFUSED: malformed local Firstmate registry entry in $reg; nothing was changed" >&2
            return 1
          }
          [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
          child=$(fm_worktree_slots_canonical_dir "$SECONDMATE_REGISTRY_HOME") || {
            echo "REFUSED: registered local Firstmate home is unavailable: $SECONDMATE_REGISTRY_HOME; nothing was changed" >&2
            return 1
          }
          known=0
          for existing in "${homes[@]}"; do
            [ "$existing" != "$child" ] || known=1
          done
          [ "$known" = 1 ] || homes+=("$child")
          ;;
      esac
    done < "$reg"
  done
}

# Does any task record in any local Firstmate home name <slot> as its
# worktree= or home=? <exclude-meta>, when given, is the caller's own record:
# skipped by identity, not spelling, so the same record reached through a
# differently resolved state directory is still skipped while a differently
# named hardlink still counts as another task's record.
# Returns 0 and sets FM_WORKTREE_SLOT_RECORD_ID and FM_WORKTREE_SLOT_RECORD_FIELD
# when one does, 1 when none does, and 2 when the homes cannot be enumerated.
fm_worktree_slot_record_named() {  # <slot> <record-state> [<exclude-meta>]
  local slot=$1 record_state=$2 exclude=${3-} state_dir other field other_path other_slot
  FM_WORKTREE_SLOT_RECORD_ID=
  FM_WORKTREE_SLOT_RECORD_FIELD=
  collect_local_firstmate_states "$record_state" || return 2
  for state_dir in "${TREEHOUSE_OWNER_STATES[@]}"; do
    for other in "$state_dir"/*.meta; do
      [ -f "$other" ] && [ ! -L "$other" ] || continue
      if [ -n "$exclude" ] && [ "${other##*/}" = "${exclude##*/}" ] && [ "$other" -ef "$exclude" ]; then
        continue
      fi
      for field in worktree home; do
        other_path=$(fm_meta_get "$other" "$field")
        [ -n "$other_path" ] || continue
        other_slot=$(fm_worktree_slots_canonical_dir "$other_path") || continue
        [ "$other_slot" = "$slot" ] || continue
        # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
        FM_WORKTREE_SLOT_RECORD_ID=$(basename "$other" .meta)
        # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
        FM_WORKTREE_SLOT_RECORD_FIELD=$field
        return 0
      done
    done
  done
  return 1
}

# Read registered Treehouse slots without running Treehouse (even status writes
# state). Git owns worktree discovery; the existing pool recognizer owns the
# pool layout. All entries of each discovered pool are counted, including
# missing directories and reservations, so a broken entry never creates room.
# Ordinary non-pool worktrees are outside this Treehouse-only setting.
# Output arrays: PATHS, STATUSES, PROJECTS; POOLS holds path/count TSV lines.
fm_worktree_slots_scan() {  # <projects-dir> [<project-dir>...]
  local projects=$1 dir top entries field path pool state rows status existing known count
  local -a dirs=() pools=()
  shift
  FM_WORKTREE_SLOT_PATHS=()
  FM_WORKTREE_SLOT_STATUSES=()
  FM_WORKTREE_SLOT_PROJECTS=()
  FM_WORKTREE_SLOT_POOLS=
  FM_WORKTREE_SLOTS_ERROR=
  command -v jq >/dev/null 2>&1 || {
    FM_WORKTREE_SLOTS_ERROR="jq is not on PATH, so pool slots cannot be counted"
    return 1
  }
  for dir in "$@" "$projects"/*/; do
    dir=$(fm_worktree_slots_canonical_dir "$dir") || continue
    top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || continue
    top=$(fm_worktree_slots_canonical_dir "$top") || continue
    [ "$top" = "$dir" ] || continue
    known=0
    for existing in "${dirs[@]+"${dirs[@]}"}"; do
      [ "$existing" != "$dir" ] || known=1
    done
    [ "$known" = 1 ] || dirs+=("$dir")
  done
  for dir in "${dirs[@]+"${dirs[@]}"}"; do
    entries=$(git -C "$dir" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || {
      FM_WORKTREE_SLOTS_ERROR="cannot read worktree registrations for $dir"
      return 1
    }
    while IFS= read -r field; do
      case "$field" in worktree\ *) path=${field#worktree } ;; *) continue ;; esac
      case "$path" in
        \"*)
          FM_WORKTREE_SLOTS_ERROR="cannot inspect a quoted Git worktree path for $dir"
          return 1
          ;;
      esac
      pool=$(dirname "$(dirname "$path")")
      state="$pool/treehouse-state.json"
      [ -e "$state" ] || [ -L "$state" ] || continue
      known=0
      for existing in "${pools[@]+"${pools[@]}"}"; do
        [ "$existing" != "$pool" ] || known=1
      done
      [ "$known" = 0 ] || continue
      if [ ! -f "$state" ] || [ -L "$state" ] || ! rows=$(jq -er '
        if (.worktrees | type) != "array" then error("invalid pool") else .worktrees end |
        map(if (.path | type) != "string" or (.path | startswith("/") | not)
          or (.path | test("[\\t\\r\\n]")) then error("invalid path") else . end) |
        map([.path, (if .leased == true then "leased"
          elif .destroying == true then "destroying"
          elif ((.owner_pid // 0) != 0) then "reserved" else "candidate" end)] | @tsv) |
        join("\n")' "$state" 2>/dev/null); then
        FM_WORKTREE_SLOTS_ERROR="cannot read Treehouse pool $pool"
        return 1
      fi
      pools+=("$pool")
      count=0
      while IFS=$'\t' read -r path status; do
        [ -n "$path" ] || continue
        # Resolve existing paths; retain missing entries conservatively.
        top=$(fm_worktree_slots_canonical_dir "$path") && path=$top
        if [ -z "$path" ]; then
          FM_WORKTREE_SLOTS_ERROR="Treehouse pool $pool has an unavailable worktree"
          return 1
        fi
        known=0
        for existing in "${FM_WORKTREE_SLOT_PATHS[@]+"${FM_WORKTREE_SLOT_PATHS[@]}"}"; do
          [ "$existing" != "$path" ] || known=1
        done
        [ "$known" = 0 ] || continue
        FM_WORKTREE_SLOT_PATHS+=("$path")
        FM_WORKTREE_SLOT_STATUSES+=("$status")
        FM_WORKTREE_SLOT_PROJECTS+=("$dir")
        count=$((count + 1))
      done <<< "$rows"
      FM_WORKTREE_SLOT_POOLS+="$pool"$'\t'"$count"$'\n'
    done <<< "$entries"
  done
}

# Does no process have its working directory in <slot> or under it? One
# system-wide `lsof -a -d cwd` listing, bounded by process count, never the
# recursive +D walk of the copy's file tree. A missing lsof, an lsof error or
# unparsable output is uncertainty, never evidence of an idle slot.
fm_worktree_slot_cwd_idle() {  # <slot>
  local dir out line
  dir=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || return 1
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      p[0-9]*|fcwd|'') ;;
      n*)
        case "${line#n}" in
          "$dir"|"$dir"/*) return 1 ;;
        esac
        ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
}

# Is scanned slot <index> a reclaim candidate (see CONTRACT)? Read-only.
# Returns 0 when it is, 1 when it is not (FM_WORKTREE_SLOT_KEPT_REASON says
# why), and 2 when the local homes cannot be enumerated.
fm_worktree_slot_reclaimable() {  # <index> <record-state>
  local idx=$1 record_state=$2 slot rc=0 dirty
  slot=${FM_WORKTREE_SLOT_PATHS[$idx]}
  FM_WORKTREE_SLOT_KEPT_REASON=
  if [ "${FM_WORKTREE_SLOT_STATUSES[$idx]}" != candidate ]; then
    FM_WORKTREE_SLOT_KEPT_REASON="treehouse reports it ${FM_WORKTREE_SLOT_STATUSES[$idx]}"
    return 1
  fi
  if ! fm_treehouse_pool_slot "${FM_WORKTREE_SLOT_PROJECTS[$idx]}" "$slot"; then
    FM_WORKTREE_SLOT_KEPT_REASON="slot ownership cannot be verified"
    return 1
  fi
  fm_treehouse_slot_owner_state "$slot" ""
  if [ "$FM_TREEHOUSE_SLOT_OWNER" != absent ]; then
    FM_WORKTREE_SLOT_KEPT_REASON="a slot-owner claim${FM_TREEHOUSE_SLOT_OWNER_ID:+ for task $FM_TREEHOUSE_SLOT_OWNER_ID} sits beside it"
    return 1
  fi
  fm_worktree_slot_record_named "$slot" "$record_state" || rc=$?
  case "$rc" in
    0)
      FM_WORKTREE_SLOT_KEPT_REASON="task $FM_WORKTREE_SLOT_RECORD_ID records it as its $FM_WORKTREE_SLOT_RECORD_FIELD"
      return 1
      ;;
    1) ;;
    *) return 2 ;;
  esac
  dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "$slot" status --porcelain --untracked-files=all 2>/dev/null) || {
    FM_WORKTREE_SLOT_KEPT_REASON="worktree status cannot be verified"
    return 1
  }
  if [ -n "$dirty" ]; then
    FM_WORKTREE_SLOT_KEPT_REASON="worktree has uncommitted changes"
    return 1
  fi
  if ! fm_worktree_slot_cwd_idle "$slot"; then
    FM_WORKTREE_SLOT_KEPT_REASON="worktree has a live process or process inspection failed"
    return 1
  fi
  return 0
}

# The one room check (see CONTRACT). Changes nothing.
# Sets FM_WORKTREE_SLOT_ROOM_REASON, FM_WORKTREE_SLOT_HELD, and
# FM_WORKTREE_SLOT_RECLAIMABLE (possible reclaim candidates; Treehouse must still prove them disposable).
# Returns 0 for room (allow) and 1 for no room (refuse); a malformed cap or an
# unreadable pool refuses, because an unproved bound is not room.
fm_worktree_slot_room() {  # <config-dir> <projects-dir> <project-dir> <record-state>
  local config=$1 projects=$2 project=$3 record_state=$4 i rc pools
  FM_WORKTREE_SLOT_ROOM_REASON=
  FM_WORKTREE_SLOT_HELD=0
  FM_WORKTREE_SLOT_RECLAIMABLE=0
  if ! fm_worktree_slot_cap_read "$config"; then
    FM_WORKTREE_SLOT_ROOM_REASON="worktree slot cap unreadable: $FM_WORKTREE_SLOTS_ERROR"
    return 1
  fi
  if [ -z "$FM_WORKTREE_SLOT_CAP" ]; then
    FM_WORKTREE_SLOT_ROOM_REASON="no worktree slot cap configured"
    return 0
  fi
  project=$(fm_worktree_slots_canonical_dir "$project") || {
    FM_WORKTREE_SLOT_ROOM_REASON="worktree slot cap $FM_WORKTREE_SLOT_CAP: project $3 is not a directory"
    return 1
  }
  if ! git -C "$project" rev-parse --show-toplevel >/dev/null 2>&1; then
    FM_WORKTREE_SLOT_ROOM_REASON="worktree slot cap $FM_WORKTREE_SLOT_CAP: project $project is not a Git worktree"
    return 1
  fi
  if ! fm_worktree_slots_scan "$projects" "$project"; then
    FM_WORKTREE_SLOT_ROOM_REASON="worktree slot cap $FM_WORKTREE_SLOT_CAP: $FM_WORKTREE_SLOTS_ERROR"
    return 1
  fi
  FM_WORKTREE_SLOT_HELD=${#FM_WORKTREE_SLOT_PATHS[@]}
  if [ "$FM_WORKTREE_SLOT_HELD" -lt "$FM_WORKTREE_SLOT_CAP" ]; then
    FM_WORKTREE_SLOT_ROOM_REASON="worktree slot cap $FM_WORKTREE_SLOT_CAP: $FM_WORKTREE_SLOT_HELD slots held"
    return 0
  fi
  for i in "${!FM_WORKTREE_SLOT_PATHS[@]}"; do
    rc=0
    fm_worktree_slot_reclaimable "$i" "$record_state" || rc=$?
    case "$rc" in
      0) FM_WORKTREE_SLOT_RECLAIMABLE=$((FM_WORKTREE_SLOT_RECLAIMABLE + 1)) ;;
      2)
        FM_WORKTREE_SLOT_ROOM_REASON="worktree slot cap $FM_WORKTREE_SLOT_CAP: local Firstmate homes cannot be enumerated to prove which slots are free"
        return 1
        ;;
    esac
  done
  pools=$(printf '%s' "$FM_WORKTREE_SLOT_POOLS" | awk -F'\t' 'NF == 2 { n = split($1, p, "/"); printf "%s%s %s", (c++ ? ", " : ""), p[n], $2 }')
  FM_WORKTREE_SLOT_ROOM_REASON="worktree slot cap $FM_WORKTREE_SLOT_CAP reached: $FM_WORKTREE_SLOT_HELD slots held (pools: $pools); $FM_WORKTREE_SLOT_RECLAIMABLE possible reclaim candidates (Treehouse merge proof still required)"
  return 1
}

# Can this Treehouse remove a slot safely by default?
fm_worktree_slot_destroy_supported() {
  command -v treehouse >/dev/null 2>&1 || return 1
  treehouse destroy --help 2>/dev/null | grep -q -- '--include-unlanded'
}

# Print <slot> as its pool's treehouse-state.json spells it. Treehouse matches
# that spelling exactly, so a pool reached through a symlink (/var vs
# /private/var) would otherwise be "not managed"; canonical paths stay for
# comparisons only. Fails when no recorded entry resolves to <slot>.
fm_worktree_slot_recorded_path() {  # <slot>
  local slot recorded
  slot=$(fm_worktree_slots_canonical_dir "$1") || return 1
  while IFS= read -r recorded; do
    [ -n "$recorded" ] || continue
    [ "$(fm_worktree_slots_canonical_dir "$recorded")" = "$slot" ] || continue
    printf '%s\n' "$recorded"
    return 0
  done <<EOF
$(jq -r '.worktrees[].path | strings' "$(dirname "$(dirname "$slot")")/treehouse-state.json" 2>/dev/null)
EOF
  return 1
}

# Remove one slot through Treehouse's own safe destroy: no --include-* flag, so
# only a merged, clean, idle, unleased slot goes. Run from the project, which is
# how Treehouse resolves the pool. FM_WORKTREE_SLOT_DESTROY_OUTPUT keeps
# Treehouse's own output for the caller's report.
fm_worktree_slot_destroy() {  # <project-dir> <slot>
  local project=$1 slot=$2
  FM_WORKTREE_SLOT_DESTROY_OUTPUT=
  fm_worktree_slot_destroy_supported || {
    FM_WORKTREE_SLOT_DESTROY_OUTPUT="this treehouse has no safe-by-default destroy, so nothing was removed"
    return 1
  }
  slot=$(fm_worktree_slot_recorded_path "$slot") || {
    FM_WORKTREE_SLOT_DESTROY_OUTPUT="no treehouse-state.json entry records $2, so nothing was removed"
    return 1
  }
  FM_WORKTREE_SLOT_DESTROY_OUTPUT=$( ( CDPATH='' cd -- "$project" && treehouse destroy "$slot" --yes ) 2>&1)
}

# Merge-proved removal of a task's own slot, called by bin/fm-teardown.sh after
# a successful return while it still holds the slot's project lock. The task's
# own claim must already be released and no other record may name the slot.
# Returns 0 when the slot was removed and 1 when it was kept, with
# FM_WORKTREE_SLOT_KEPT_REASON saying why.
fm_worktree_slot_remove_returned() {  # <project-dir> <slot> <record-state> <own-meta>
  local project=$1 slot=$2 record_state=$3 own_meta=$4 rc=0
  FM_WORKTREE_SLOT_KEPT_REASON=
  fm_treehouse_pool_slot "$project" "$slot" || {
    FM_WORKTREE_SLOT_KEPT_REASON="it is not a Treehouse pool slot of $project"
    return 1
  }
  slot=$(fm_worktree_slots_canonical_dir "$slot") || {
    FM_WORKTREE_SLOT_KEPT_REASON="it is gone"
    return 1
  }
  fm_treehouse_slot_owner_state "$slot" ""
  if [ "$FM_TREEHOUSE_SLOT_OWNER" != absent ]; then
    FM_WORKTREE_SLOT_KEPT_REASON="a slot-owner claim${FM_TREEHOUSE_SLOT_OWNER_ID:+ for task $FM_TREEHOUSE_SLOT_OWNER_ID} sits beside it"
    return 1
  fi
  fm_worktree_slot_record_named "$slot" "$record_state" "$own_meta" || rc=$?
  case "$rc" in
    0)
      FM_WORKTREE_SLOT_KEPT_REASON="task $FM_WORKTREE_SLOT_RECORD_ID records it as its $FM_WORKTREE_SLOT_RECORD_FIELD"
      return 1
      ;;
    2)
      FM_WORKTREE_SLOT_KEPT_REASON="local Firstmate homes cannot be enumerated"
      return 1
      ;;
  esac
  if ! fm_worktree_slot_destroy "$project" "$slot"; then
    FM_WORKTREE_SLOT_KEPT_REASON="treehouse kept it: $(printf '%s\n' "$FM_WORKTREE_SLOT_DESTROY_OUTPUT" | grep -v '^[[:space:]]*$' | tail -1)"
    return 1
  fi
}

# Reclaim up to <limit> disposable candidates (0 = all) from the scan already in the
# FM_WORKTREE_SLOT_* arrays. <held-lock> is a project lock the caller already
# holds (or empty). Each candidate is re-proved under its own project lock
# before removal. dry-run calls no Treehouse command and reports candidates,
# without merge proof; even Treehouse destroy previews write state and fetch.
# Prints one line per slot considered:
#   reclaimed: <slot> | candidate (...): <slot> | kept: <slot>: <why>
# and sets FM_WORKTREE_SLOT_RECLAIMED to the count removed (or previewed).
fm_worktree_slots_reclaim() {  # <record-state> <held-lock> <apply|dry-run> <limit>
  local record_state=$1 held=$2 mode=$3 limit=$4 i rc lock slot project took
  FM_WORKTREE_SLOT_RECLAIMED=0
  for i in "${!FM_WORKTREE_SLOT_PATHS[@]}"; do
    [ "$limit" = 0 ] || [ "$FM_WORKTREE_SLOT_RECLAIMED" -lt "$limit" ] || break
    slot=${FM_WORKTREE_SLOT_PATHS[$i]}
    project=${FM_WORKTREE_SLOT_PROJECTS[$i]}
    rc=0
    fm_worktree_slot_reclaimable "$i" "$record_state" || rc=$?
    [ "$rc" != 2 ] || return 2
    if [ "$rc" != 0 ]; then
      printf 'kept: %s: %s\n' "$slot" "$FM_WORKTREE_SLOT_KEPT_REASON"
      continue
    fi
    if [ "$mode" = dry-run ]; then
      printf 'candidate (Treehouse merge proof still required): %s\n' "$slot"
      FM_WORKTREE_SLOT_RECLAIMED=$((FM_WORKTREE_SLOT_RECLAIMED + 1))
      continue
    fi
    lock=$(fm_treehouse_project_lock_path "$project") || {
      printf 'kept: %s: its project lock cannot be resolved\n' "$slot"
      continue
    }
    took=0
    if [ "$lock" != "$held" ]; then
      fm_lock_try_acquire "$lock" || {
        printf 'kept: %s: another slot allocation or return holds its project lock\n' "$slot"
        continue
      }
      took=1
    fi
    # Re-prove under the lock: the scan may be stale by now.
    rc=0
    fm_worktree_slot_reclaimable "$i" "$record_state" || rc=$?
    if [ "$rc" = 0 ] && fm_worktree_slot_destroy "$project" "$slot"; then
      printf 'reclaimed: %s\n' "$slot"
      FM_WORKTREE_SLOT_RECLAIMED=$((FM_WORKTREE_SLOT_RECLAIMED + 1))
    elif [ "$rc" = 0 ]; then
      printf 'kept: %s: treehouse kept it: %s\n' "$slot" \
        "$(printf '%s\n' "$FM_WORKTREE_SLOT_DESTROY_OUTPUT" | grep -v '^[[:space:]]*$' | tail -1)"
    else
      printf 'kept: %s: %s\n' "$slot" "${FM_WORKTREE_SLOT_KEPT_REASON:-it changed since the scan}"
    fi
    [ "$took" = 0 ] || fm_lock_release "$lock" || true
    [ "$rc" != 2 ] || return 2
  done
}
