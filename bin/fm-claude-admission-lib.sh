#!/usr/bin/env bash
# Claude crew admission. fm-control.sh uses it as a read-only relaunch preflight;
# fm-spawn.sh repeats it while holding the home-wide .claude-admission.lock
# through launch and metadata publication. No supervisor or secondmate admission
# is charged against crew.
# docs/configuration.md "Claude crew admission" owns configuration and semantics.
# Usage: fm_claude_admission_check <config> <state> <id> <identity> <floor-scope> <floor-min-percent>
# The caller supplies the selected Claude config root, or ordinary, as identity.
# Existing records without identity are conservatively charged to every account.
# Backend recovery-grade liveness is reused, never inferred from status events.

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-control-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-worker-account-lib.sh"

fm_claude_profile_floor_valid() {
  jq -en --arg scope "$1" --arg min_percent "$2" '
    ($scope | length) > 0
    and (($min_percent | tonumber?) as $n |
      ($n | type) == "number" and $n >= 0 and $n <= 100)
  ' >/dev/null 2>&1
}

# Admission needs proof of an agent-free pane, not a usable registration.
# Keep this fallback local so other control paths retain their classifier.
fm_claude_admission_agent_state() {  # <backend> <target>
  local backend=$1 target=$2 verdict
  [ -n "$target" ] || { printf 'unreadable'; return 0; }
  verdict=$(fm_backend_agent_state "$backend" "$target")
  if [ "$backend:$verdict" = herdr:unreadable ] \
     && fm_backend_herdr_parse_target "$target" \
     && [ "$(fm_backend_herdr_pane_process_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")" = shell ]; then
    verdict=dead
  fi
  printf '%s' "$verdict"
}

fm_claude_admission_check() {
  local config=$1 state=$2 id=$3 identity=$4 floor_scope=$5 floor_min_percent=$6
  local settings='{}' limits cap floor floors meta account backend target verdict absence count=0 counted='' task
  local snapshot row result gen started now recorded_harness recorded_family var
  local -a quota_env=(env)
  if [ -e "$config/crew-dispatch.json" ] || [ -L "$config/crew-dispatch.json" ]; then
    settings=$(cat "$config/crew-dispatch.json") || return 1
  fi
  if [ -n "$floor_scope$floor_min_percent" ]; then
    if [ -z "$floor_scope" ] || [ -z "$floor_min_percent" ] \
       || ! fm_claude_profile_floor_valid "$floor_scope" "$floor_min_percent"; then
      echo 'error: invalid selected Claude profile floor; scope must be non-empty and min_percent must be 0..100' >&2
      return 1
    fi
  fi
  limits=$(printf '%s\n' "$settings" | jq -ce --arg floor_scope "$floor_scope" --arg floor_min_percent "$floor_min_percent" '
    if type != "object" then error("invalid dispatch object") else . end |
    (if has("claude_admission") then .claude_admission else {} end) as $c |
    ($c | if has("max_concurrent") then .max_concurrent else 3 end) as $cap |
    ($c | if has("min_session_percent") then .min_session_percent else 40 end) as $floor |
    (if $floor_min_percent == "" then null else (try ($floor_min_percent | tonumber) catch null) end) as $profile_min |
    if ($c | type) != "object" or ($cap | type) != "number" or $cap < 1 or $cap > 3 or $cap != ($cap | floor)
      or ($floor | type) != "number" or $floor < 40 or $floor > 100
      then error("invalid claude_admission") else . end |
    (if $floor_scope == "" then [] else [{scope:$floor_scope,min_percent:$profile_min}] end) as $floors |
    {cap:$cap, floor:$floor, floors:$floors}
  ' 2>/dev/null) || {
    echo 'error: invalid Claude admission settings or selected profile floor; max_concurrent must be 1..3 and min_session_percent must be 40..100' >&2
    return 1
  }
  cap=$(printf '%s\n' "$limits" | jq -r .cap)
  floor=$(printf '%s\n' "$limits" | jq -r .floor)
  floors=$(printf '%s\n' "$limits" | jq -c .floors)
  now=$(date +%s)
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$meta" != "$state/$id.meta" ] || continue
    recorded_harness=$(fm_meta_get "$meta" harness)
    recorded_family=$(fm_control_harness_family "$recorded_harness") || continue
    [ "$recorded_family" = claude ] || continue
    [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
    account=$(fm_meta_get "$meta" claude_quota_identity)
    [ -n "$account" ] || account=$(fm_meta_get "$meta" account)
    # Legacy unpinned workers and raw commands have no proven identity.
    [ -z "$account" ] || [ "$identity" = unknown ] || [ "$account" = unknown ] || [ "$account" = "$identity" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if fm_backend_source "$backend"; then
      verdict=$(fm_claude_admission_agent_state "$backend" "$target")
    else
      verdict=unverified
    fi
    if [ "$verdict" = missing ]; then
      absence=$(fm_control_endpoint_absence_verdict "$backend" "$target")
      case "${absence%%$'\t'*}" in
        gone|dead) verdict=dead ;;
        *) verdict=unreadable ;;
      esac
    fi
    case "$verdict" in
      dead)
        # Launch publication precedes vendor startup. Reserve that slot while
        # a newly launched process is still coming up in its shell.
        gen=$(fm_meta_get "$meta" spawn_gen)
        started=${gen#s}; started=${started%%.*}
        case "$started" in ''|*[!0-9]*) continue ;; esac
        [ "$((now - started))" -lt 60 ] || continue
        ;;
    esac
    count=$((count + 1))
    task=${meta##*/}; task=${task%.meta}
    counted="${counted:+$counted, }$task"
  done
  if [ "$count" -ge "$cap" ]; then
    echo "error: Claude crew admission refused for account $identity: $count live or unverified crew, limit $cap; counted tasks: $counted; choose Codex or route to a second mate on another account" >&2
    return 1
  fi
  if [ "$identity" = unknown ]; then
    echo 'error: Claude crew admission refused because quota is unverifiable for a raw command whose credential selection cannot be proved; choose Codex or route to a second mate on another account' >&2
    return 1
  fi
  for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    quota_env+=(-u "$var")
  done
  if [ "$identity" != ordinary ]; then
    quota_env+=("CLAUDE_CONFIG_DIR=$identity")
    quota_env+=(quota-axi --provider claude --profile-only --no-credential-refresh --json)
  else
    quota_env+=(-u CLAUDE_CONFIG_DIR)
    quota_env+=(quota-axi --provider claude --no-credential-refresh --json)
  fi
  snapshot=$(fm_quota_read_json 15 "${quota_env[@]}" 2>/dev/null) || snapshot=
  if ! printf '%s\n' "$snapshot" | fm_quota_json_valid; then
    echo 'error: Claude crew admission refused because quota is unavailable or invalid; choose Codex or route to a second mate on another account' >&2
    return 1
  fi
  row=$(printf '%s\n' "$snapshot" | jq -c "$FM_QUOTA_ROW_JQ"'quota_row(.; "claude"; "")') || return 1
  printf '%s\n' "$row" | jq -r 'select(.firstmateCache != null) |
    "Claude quota: cached reading \(.firstmateCache.ageSeconds)s old"' >&2
  result=$(printf '%s\n' "$row" | jq -r --argjson floor "$floor" --argjson floors "$floors" '
    . as $p |
    def known: type == "number" and . >= 0 and . <= 100;
    (if $p.state.stale == false then [
      ([.windows[]? | select(.id == "five_hour" or .kind == "five_hour" or .kind == "session")]) as $session_rows |
      (if ($session_rows | length) == 0 or any($session_rows[]; (.percentRemaining | known) | not)
        then {scope:"five_hour",unknown:true}
        else {scope:"five_hour",pct:($session_rows | map(.percentRemaining) | min),min:$floor} end),
      ($floors[] | . as $f |
        ([$p.quotaSemantics.effectiveAvailability[]? | select(.scope == $f.scope)]) as $rows |
        if ($rows | length) == 0
           or any($rows[]; .status != "known" or ((.effectivePercentRemaining | known) | not))
          then {scope:$f.scope,unknown:true}
          else {scope:$f.scope,pct:($rows | map(.effectivePercentRemaining) | min),min:$f.min_percent} end)
    ] else [] end) as $checks |
    ([$checks[] | select(.unknown != true and .pct < .min)] | first) as $bad |
    if $bad then "refuse: \($bad.scope) remaining \($bad.pct)% below \($bad.min)%"
    elif ($checks | length) == 0 or any($checks[]; .unknown) then "unknown"
    else "allow" end
  ') || return 1
  case "$result" in
    refuse:*)
      echo "error: Claude crew admission refused for account $identity: ${result#refuse: }; choose Codex or route to a second mate on another account" >&2
      return 1 ;;
    unknown)
      echo 'error: Claude crew admission refused because the quota floor is unverifiable; choose Codex or route to a second mate on another account' >&2
      return 1 ;;
  esac
}
