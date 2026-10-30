# shellcheck shell=bash
# Shared admission count, independent of attended, away, or quiet posture.
# Usage: fm_live_workers_count <state> <exclude-id> [filter-function [filter-args...]]
# The optional filter receives <meta> then its arguments and selects the crew
# charged to a particular account/provider. Secondmates never consume a slot.
# Sets FM_LIVE_WORKERS_COUNT and FM_LIVE_WORKERS_COUNTED (comma-space task ids).
# Counts positively alive endpoints and launches in the preceding 60 seconds.
# Missing/dead/gone, ambiguous (open endpoint without an agent) and unverified
# (no classifier) endpoints do not consume capacity, even when their absence is
# not strong enough to authorize lifecycle recovery. Never recover or delete an
# endpoint here. Only a backend read failure refuses, with return 2 and
# FM_LIVE_WORKERS_ERROR="crew liveness unreadable: <backend>" (also on stderr).
# Call under the caller's admission lock and propagate failures, never use a
# partial count. Malformed targets and present-but-invalid spawn generations
# are skipped with a task-named stderr diagnostic, never a backend refusal.
# Missing spawn_gen/backend fields retain legacy endpoint lookup semantics.
# Task metadata and status events alone are not liveness proof.

if ! declare -F fm_backend_agent_state >/dev/null; then
  # shellcheck source=bin/fm-backend.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-backend.sh"
fi

# Validate only address structure, without contacting any backend. Recovery's
# unreadable verdict also covers invalid addresses; admission must distinguish
# those records from a failed runtime read before invoking that classifier.
fm_live_workers_target_valid() { # <backend> <target>
  local backend=$1 target=$2
  [ -n "$target" ] || return 1
  case "$backend" in
    tmux)
      case "$target" in *:*:*|'':*|*:'') return 1 ;; *:*) return 0 ;; *) return 1 ;; esac ;;
    herdr|zellij|cmux)
      case "$target" in '':*|*:'') return 1 ;; *:*) return 0 ;; *) return 1 ;; esac ;;
    *) return 0 ;;
  esac
}

fm_live_workers_agent_state() { # <backend> <target>
  local backend=$1 target=$2 verdict
  [ -n "$target" ] || { printf 'missing'; return 0; }
  fm_backend_source "$backend" || { printf 'unverified'; return 0; }
  verdict=$(fm_backend_agent_state "$backend" "$target") || return 1
  if [ "$backend:$verdict" = herdr:unreadable ] \
     && fm_backend_herdr_parse_target "$target" \
     && [ "$(fm_backend_herdr_pane_process_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")" = shell ]; then
    verdict=dead
  fi
  printf '%s' "$verdict"
}

fm_live_workers_count() {
  local state=$1 exclude=$2 filter=${3:-}
  shift 2
  [ -z "$filter" ] || shift
  local meta backend target verdict gen started now task count=0 counted=''
  FM_LIVE_WORKERS_COUNT=0
  FM_LIVE_WORKERS_COUNTED=''
  FM_LIVE_WORKERS_ERROR=''
  now=$(date +%s)
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$meta" != "$state/$exclude.meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
    if [ -n "$filter" ]; then "$filter" "$meta" "$@" || continue; fi
    task=${meta##*/}; task=${task%.meta}
    backend=$(fm_backend_of_meta "$meta") || backend=unknown
    target=$(fm_backend_target_of_meta "$meta") || target=
    if ! fm_live_workers_target_valid "$backend" "$target"; then
      printf 'crew record skipped: %s: malformed target (%s)\n' "$task" "$backend" >&2
      continue
    fi
    gen=$(fm_meta_get "$meta" spawn_gen)
    if [ -n "$gen" ] && ! [[ "$gen" =~ ^s[0-9]{1,10}(\.[0-9]+)+$ ]]; then
      printf 'crew record skipped: %s: malformed spawn_gen\n' "$task" >&2
      continue
    fi
    started=${gen#s}; started=${started%%.*}
    verdict=''
    case "$started" in
      ''|*[!0-9]*) ;;
      *)
        # Reject future and overlong timestamps rather than reserving forever
        # (or overflowing shell arithmetic on malformed historical records).
        if [ "${#started}" -le 10 ] && [ "$started" -le "$now" ] && [ "$((now - 10#$started))" -lt 60 ]; then
          verdict=alive
        fi ;;
    esac
    if [ -z "$verdict" ]; then
      verdict=$(fm_live_workers_agent_state "$backend" "$target") || verdict=unreadable
    fi
    case "$verdict" in
      alive) ;;
      missing|dead|gone|unproven-absent|ambiguous|unverified) continue ;;
      *)
        FM_LIVE_WORKERS_ERROR="crew liveness unreadable: ${backend:-unknown}"
        printf '%s\n' "$FM_LIVE_WORKERS_ERROR" >&2
        return 2 ;;
    esac
    count=$((count + 1))
    task=${meta##*/}; task=${task%.meta}
    counted="${counted:+$counted, }$task"
  done
  # shellcheck disable=SC2034 # Shared output read by admission, pacing, placement and spawn callers.
  FM_LIVE_WORKERS_COUNT=$count
  # shellcheck disable=SC2034 # Shared output read by admission and pacing callers.
  FM_LIVE_WORKERS_COUNTED=$counted
}
