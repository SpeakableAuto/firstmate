#!/usr/bin/env bash
# Claude crew admission. fm-control.sh uses it as a read-only relaunch preflight;
# fm-spawn.sh repeats it while holding the home-wide .claude-admission.lock
# through launch and metadata publication. No supervisor or secondmate admission
# is charged against crew.
# docs/configuration.md "Claude crew admission" owns configuration and semantics.
# Usage: fm_claude_admission_check <config> <state> <id> <identity> <floor-scope> <floor-min-percent> [model]
# The caller supplies the selected Claude config root, or ordinary, as identity.
# Existing records without identity are conservatively charged to every account.
# Backend recovery-grade liveness is reused, never inferred from status events.
# fm_claude_admission_state <config> <state> <snapshot-file> reports the same
# limits, live count, and session reading as one JSON object for dispatch,
# without refusing anything; bin/fm-quota-snapshot.sh attaches it to every
# snapshot so a parent can apply this machine's guard from a remote read.

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-control-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-quota-pacing-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-pacing-lib.sh"

fm_claude_profile_floor_valid() {
  jq -en --arg scope "$1" --arg min_percent "$2" '
    ($scope | length) > 0
    and (($min_percent | tonumber?) as $n |
      ($n | type) == "number" and $n >= 0 and $n <= 100)
  ' >/dev/null 2>&1
}

# Admission needs proof of an agent-free pane, not a usable registration.
fm_claude_admission_agent_state() {  # <backend> <target>
  fm_quota_pacing_agent_state "$@"
}

# Session-floor evidence from one Claude quota row: {pct} from the session
# windows when the row is explicitly fresh, otherwise {unknown}. Shared by the
# admission verdict and the dispatch state so both read the floor identically.
# shellcheck disable=SC2016,SC2034  # jq program text; read by the sourcing consumers
FM_CLAUDE_SESSION_JQ='
  def claude_session($p):
    def known: type == "number" and . >= 0 and . <= 100;
    if $p == null then {unknown: "no Claude quota row"}
    elif $p.state.stale != false then {unknown: "Claude quota reading is not explicitly fresh"}
    else ([$p.windows[]? | select(.id == "five_hour" or .kind == "five_hour" or .kind == "session")]) as $rows |
      if ($rows | length) == 0 or any($rows[]; (.percentRemaining | known) | not)
      then {unknown: "Claude session window percentage is unknown"}
      else {pct: ($rows | map(.percentRemaining) | min)} end
    end;
'

# fm_claude_admission_limits <settings-json> <floor-scope> <floor-min-percent>
# Prints {cap, floor, floors} or prints one refusal and returns 1.
fm_claude_admission_limits() {
  local settings=$1 floor_scope=$2 floor_min_percent=$3
  if [ -n "$floor_scope$floor_min_percent" ]; then
    if [ -z "$floor_scope" ] || [ -z "$floor_min_percent" ] \
       || ! fm_claude_profile_floor_valid "$floor_scope" "$floor_min_percent"; then
      echo 'error: invalid selected Claude profile floor; scope must be non-empty and min_percent must be 0..100' >&2
      return 1
    fi
  fi
  printf '%s\n' "$settings" | jq -ce --arg floor_scope "$floor_scope" --arg floor_min_percent "$floor_min_percent" '
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
  ' 2>/dev/null || {
    echo 'error: invalid Claude admission settings or selected profile floor; max_concurrent must be 1..3 and min_session_percent must be 40..100' >&2
    return 1
  }
}

# fm_claude_admission_count <state> <exclude-id> <identity>
# Sets FM_CLAUDE_ADMISSION_COUNT and FM_CLAUDE_ADMISSION_COUNTED (a ", " list)
# for this home's live or unverified direct Claude crew charged to identity,
# excluding the named task. It runs in the caller's shell so backends it
# loads stay loaded there.
fm_claude_admission_count() {
  local state=$1 id=$2 identity=$3
  local meta account backend target verdict absence count=0 counted='' task gen started now recorded_harness recorded_family
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
  FM_CLAUDE_ADMISSION_COUNT=$count
  FM_CLAUDE_ADMISSION_COUNTED=$counted
}

# fm_claude_admission_quota_row <identity>
# Prints the identity's bound Claude quota row from one bounded read, or
# returns 1 when quota is unavailable or invalid.
fm_claude_admission_quota_row() {
  local identity=$1 snapshot var
  local -a quota_env=(env)
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
  printf '%s\n' "$snapshot" | fm_quota_json_valid || return 1
  printf '%s\n' "$snapshot" | jq -c "$FM_QUOTA_ROW_JQ"'quota_row(.; "claude"; "")'
}

fm_claude_pacing_for_row() { # <config> <quota-row-json> <selected-scope> <model>
  local config=$1 row=$2 scope=$3 model=$4 account_key calculated bare
  [ -f "$config/crew-dispatch.json" ] || { printf 'null\n'; return 0; }
  account_key=$(printf '%s\n' "$row" | jq -r '.accountKey // "default"')
  calculated=$(printf '%s\n' "$row" | node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-pacing.mjs" \
    "$config/crew-dispatch.json" -) || return 1
  bare=${model##*/}
  printf '%s\n' "$calculated" | jq -c --arg scope "$scope" --arg model "$bare" --arg account "$account_key" '
      [.accounts[] | select(.provider == "claude" and .accountKey == $account
        and (.scope == "all_models" or .scope == "all_products" or .scope == $scope
          or ($model != "" and $model != "default" and (.scope == ("model:" + $model) or .scope == ("product:" + $model)))))]
      | if length == 0 then null
        else {allowedConcurrency: ([.[].allowedConcurrency | select(. != null)] | min // null),
              unknown: (any(.[]; .allowedConcurrency == null)),
              accounts: .} end'
}

fm_claude_admission_check() {
  local config=$1 state=$2 id=$3 identity=$4 floor_scope=$5 floor_min_percent=$6 model=${7:-}
  local settings='{}' limits cap floor floors count counted row result pacing pacing_cap pacing_count pacing_counted pacing_snapshot account_key
  if [ -e "$config/crew-dispatch.json" ] || [ -L "$config/crew-dispatch.json" ]; then
    settings=$(cat "$config/crew-dispatch.json") || return 1
  fi
  limits=$(fm_claude_admission_limits "$settings" "$floor_scope" "$floor_min_percent") || return 1
  cap=$(printf '%s\n' "$limits" | jq -r .cap)
  floor=$(printf '%s\n' "$limits" | jq -r .floor)
  floors=$(printf '%s\n' "$limits" | jq -c .floors)
  fm_claude_admission_count "$state" "$id" "$identity"
  count=$FM_CLAUDE_ADMISSION_COUNT
  counted=$FM_CLAUDE_ADMISSION_COUNTED
  if [ "$count" -ge "$cap" ]; then
    echo "error: Claude crew admission refused for account $identity: $count live or unverified crew, limit $cap; counted tasks: $counted; choose Codex or route to a second mate on another account" >&2
    return 1
  fi
  if [ "$identity" = unknown ]; then
    echo 'error: Claude crew admission refused because quota is unverifiable for a raw command whose credential selection cannot be proved; choose Codex or route to a second mate on another account' >&2
    return 1
  fi
  if ! row=$(fm_claude_admission_quota_row "$identity"); then
    echo 'error: Claude crew admission refused because quota is unavailable or invalid; choose Codex or route to a second mate on another account' >&2
    return 1
  fi
  pacing=$(fm_claude_pacing_for_row "$config" "$row" "$floor_scope" "$model") || return 1
  if [ "$pacing" != null ]; then
    if [ "$(printf '%s\n' "$pacing" | jq -r .unknown)" = true ]; then
      echo "error: Claude crew admission refused for account $identity: quota pacing evidence is incomplete" >&2
      return 1
    fi
    pacing_cap=$(printf '%s\n' "$pacing" | jq -r .allowedConcurrency)
    pacing_snapshot=$(mktemp) || return 1
    if ! printf '%s\n' "$row" | jq -c '{schemaVersion:(if has("accountKey") then 6 else 5 end),providers:[.]}' > "$pacing_snapshot"; then
      rm -f "$pacing_snapshot"
      return 1
    fi
    account_key=$(printf '%s\n' "$row" | jq -r '.accountKey // "default"')
    fm_quota_pacing_count "$state" "$pacing_snapshot" "$id" claude "$account_key"
    rm -f "$pacing_snapshot"
    pacing_count=$FM_QUOTA_PACING_COUNT
    pacing_counted=$FM_QUOTA_PACING_COUNTED
    if [ "$pacing_count" -ge "$pacing_cap" ]; then
      echo "error: Claude crew admission refused for account $identity: $pacing_count live or unverified crew, limit $pacing_cap; counted tasks: $pacing_counted; choose Codex or route to a second mate on another account" >&2
      return 1
    fi
    [ "$pacing_cap" -lt "$cap" ] && cap=$pacing_cap
  fi
  if [ "$count" -ge "$cap" ]; then
    echo "error: Claude crew admission refused for account $identity: $count live or unverified crew, limit $cap; counted tasks: $counted; choose Codex or route to a second mate on another account" >&2
    return 1
  fi
  printf '%s\n' "$row" | jq -r 'select(.firstmateCache != null) |
    "Claude quota: cached reading \(.firstmateCache.ageSeconds)s old"' >&2
  result=$(printf '%s\n' "$row" | jq -r --argjson floor "$floor" --argjson floors "$floors" "$FM_CLAUDE_SESSION_JQ"'
    . as $p |
    def known: type == "number" and . >= 0 and . <= 100;
    (claude_session($p)) as $session |
    (if $p.state.stale == false then [
      (if $session.unknown then {scope:"five_hour",unknown:true}
        else {scope:"five_hour",pct:$session.pct,min:$floor} end),
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

# fm_claude_admission_state <config> <state> <snapshot-file>
# Prints this home's Claude crew guard evidence as one JSON object:
# {cap, floor, count, counted, account, session: {pct}|{unknown}}, or
# {unknown: <reason>} when the limits or account cannot be established. The
# snapshot file is the caller's own quota read; it supplies the session window
# only when both the launch account and the ambient account are ordinary,
# otherwise the account's own bounded read does. Never refuses or exits.
fm_claude_admission_state() {
  local config=$1 state=$2 snapshot_file=$3
  local settings='{}' limits pin identity ambient row session pacing pacing_cap
  if [ -e "$config/crew-dispatch.json" ] || [ -L "$config/crew-dispatch.json" ]; then
    settings=$(cat "$config/crew-dispatch.json" 2>/dev/null) || settings=
  fi
  if ! limits=$(fm_claude_admission_limits "$settings" '' '' 2>/dev/null); then
    jq -nc '{unknown: "invalid Claude admission settings"}'
    return 0
  fi
  ambient=$(fm_worker_account_claude_ambient_identity 2>/dev/null) || ambient=unknown
  if ! pin=$(fm_worker_account_resolve claude "$config" 2>/dev/null); then
    jq -nc '{unknown: "invalid Claude account pin"}'
    return 0
  fi
  if [ -n "$pin" ]; then
    identity=${pin%%$'\t'*}
  else
    identity=$ambient
  fi
  if [ "$identity" = unknown ]; then
    jq -nc '{unknown: "the Claude account a launch would use cannot be proved"}'
    return 0
  fi
  fm_claude_admission_count "$state" '' "$identity"
  if [ "$identity" = ordinary ] && [ "$ambient" = ordinary ]; then
    row=$(jq -c "$FM_QUOTA_ROW_JQ"'quota_row(.; "claude"; "")' "$snapshot_file" 2>/dev/null) || row=null
  else
    row=$(fm_claude_admission_quota_row "$identity") || row=null
  fi
  session=$(printf '%s\n' "${row:-null}" | jq -c "$FM_CLAUDE_SESSION_JQ"'claude_session(.)' 2>/dev/null) \
    || session='{"unknown":"Claude quota row is unreadable"}'
  pacing=$(fm_claude_pacing_for_row "$config" "${row:-null}" '' '' 2>/dev/null) || pacing='{"unknown":true}'
  pacing_cap=$(printf '%s\n' "$pacing" | jq -r '.allowedConcurrency // empty' 2>/dev/null)
  if [ -n "$pacing_cap" ] && [ "$pacing_cap" -lt "$(printf '%s\n' "$limits" | jq -r .cap)" ]; then
    limits=$(printf '%s\n' "$limits" | jq -c --argjson cap "$pacing_cap" '.cap = $cap')
  fi
  jq -nc --argjson limits "$limits" --arg count "$FM_CLAUDE_ADMISSION_COUNT" --arg counted "$FM_CLAUDE_ADMISSION_COUNTED" \
    --arg account "$([ "$identity" = ordinary ] && printf ordinary || printf pinned)" --argjson session "$session" '
    {cap: $limits.cap, floor: $limits.floor, count: ($count | tonumber),
     counted: (if $counted == "" then [] else ($counted | split(", ")) end),
     account: $account, session: $session}'
}
