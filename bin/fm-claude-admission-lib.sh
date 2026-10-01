#!/usr/bin/env bash
# Claude crew admission, called only by fm-spawn.sh while holding its home-wide
# .claude-admission.lock through launch and metadata publication (including abort
# cleanup). No supervisor or secondmate admission is charged against crew.
# docs/configuration.md "Claude crew admission" owns configuration and semantics.
# Usage: fm_claude_admission_check <config> <state> <id> <identity> <model> <effort>
# The caller supplies the selected Claude config root, or ordinary, as identity.
# Existing records without identity are conservatively charged to every account.
# Backend recovery-grade liveness is reused, never inferred from status events.

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

fm_claude_admission_check() {
  local config=$1 state=$2 id=$3 identity=$4 model=$5 effort=$6
  local settings='{}' limits cap floor floors meta account backend target verdict count=0
  local snapshot row result gen started now
  if [ -e "$config/crew-dispatch.json" ] || [ -L "$config/crew-dispatch.json" ]; then
    settings=$(cat "$config/crew-dispatch.json") || return 1
  fi
  limits=$(printf '%s\n' "$settings" | jq -ce --arg model "$model" --arg effort "$effort" '
    def profiles: if type == "array" then . elif type == "object" then [.] else error("invalid profiles") end;
    def valid_floor: type == "object" and (.scope | type == "string" and length > 0)
      and (.min_percent | type == "number" and . >= 0 and . <= 100);
    if type != "object" then error("invalid dispatch object") else . end |
    (if has("claude_admission") then .claude_admission else {} end) as $c |
    ($c | if has("max_concurrent") then .max_concurrent else 3 end) as $cap |
    ($c | if has("min_session_percent") then .min_session_percent else 40 end) as $floor |
    if ($c | type) != "object" or ($cap | type) != "number" or $cap < 1 or $cap != ($cap | floor)
      or ($floor | type) != "number" or $floor < 0 or $floor > 100 then error("invalid claude_admission") else . end |
    ([((.rules // [])[] | .use | profiles[]), ((.default // []) | profiles[])] |
      map(select(.harness == "claude")) |
      if any(.[]; has("floor") and (.floor | valid_floor | not)) then error("invalid Claude profile floor") else . end |
      map(select(($model == "" or (.model // "") == "" or .model == $model)
        and ($effort == "" or (.effort // "") == "" or .effort == $effort))) |
      map(select(has("floor")) | .floor)) as $floors |
    {cap:$cap, floor:$floor, floors:$floors}
  ' 2>/dev/null) || {
    echo 'error: invalid Claude admission settings or profile floors in config/crew-dispatch.json; correct the configuration before spawning' >&2
    return 1
  }
  cap=$(printf '%s\n' "$limits" | jq -r .cap)
  floor=$(printf '%s\n' "$limits" | jq -r .floor)
  floors=$(printf '%s\n' "$limits" | jq -c .floors)
  now=$(date +%s)
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$meta" != "$state/$id.meta" ] || continue
    [ "$(fm_meta_get "$meta" harness)" = claude ] || continue
    [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
    account=$(fm_meta_get "$meta" claude_quota_identity)
    [ -n "$account" ] || account=$(fm_meta_get "$meta" account)
    # Legacy unpinned workers and raw commands have no proven identity.
    [ -z "$account" ] || [ "$identity" = unknown ] || [ "$account" = unknown ] || [ "$account" = "$identity" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    verdict=unreadable
    [ -z "$target" ] || verdict=$(fm_backend_agent_state "$backend" "$target")
    case "$verdict" in
      dead|missing)
        # Launch publication precedes vendor startup. Reserve that slot while
        # a newly launched process is still coming up in its shell.
        gen=$(fm_meta_get "$meta" spawn_gen)
        started=${gen#s}; started=${started%%.*}
        case "$started" in ''|*[!0-9]*) continue ;; esac
        [ "$((now - started))" -lt 60 ] || continue
        ;;
    esac
    count=$((count + 1))
  done
  if [ "$count" -ge "$cap" ]; then
    echo "error: Claude crew admission refused for account $identity: $count live or unverified crew, limit $cap; choose Codex or route to a secondmate on another account" >&2
    return 1
  fi
  if [ "$identity" = unknown ]; then
    echo 'warning: Claude quota unknown for unpinned raw command; concurrency cap still enforced' >&2
    return 0
  fi
  # Explicit roots use profile-only so another credential source cannot answer
  # for the selected account. Ordinary Claude uses quota-axi's default row.
  if [ "$identity" != ordinary ]; then
    snapshot=$(CLAUDE_CONFIG_DIR="$identity" fm_run_timed 15 quota-axi --provider claude --profile-only --no-credential-refresh --json 2>/dev/null) || snapshot=
  else
    snapshot=$(fm_run_timed 15 quota-axi --provider claude --no-credential-refresh --json 2>/dev/null) || snapshot=
  fi
  if ! printf '%s\n' "$snapshot" | fm_quota_json_valid; then
    echo 'warning: Claude quota unknown (unavailable or invalid snapshot); concurrency cap still enforced' >&2
    return 0
  fi
  row=$(printf '%s\n' "$snapshot" | jq -c "$FM_QUOTA_ROW_JQ"'quota_row(.; "claude"; "")') || return 1
  result=$(printf '%s\n' "$row" | jq -r --argjson floor "$floor" --argjson floors "$floors" '
    . as $p |
    def known: type == "number" and . >= 0 and . <= 100;
    (if $p.state.stale == true then [] else [
      ([.windows[]? | select(.id == "five_hour" or .kind == "five_hour" or .kind == "session") |
        .percentRemaining | select(known)] | if length == 0 then {scope:"five_hour",unknown:true}
        else {scope:"five_hour",pct:min,min:$floor} end),
      ($floors[] | . as $f |
        ([$p.quotaSemantics.effectiveAvailability[]? | select(.scope == $f.scope and .status == "known") |
          .effectivePercentRemaining | select(known)]) as $rows |
        if ($rows | length) == 0 then {scope:$f.scope,unknown:true}
        else {scope:$f.scope,pct:($rows|min),min:$f.min_percent} end)
    ] end) as $checks |
    ([$checks[] | select(.unknown != true and .pct < .min)] | first) as $bad |
    if $bad then "refuse: \($bad.scope) remaining \($bad.pct)% below \($bad.min)%"
    elif ($checks | length) == 0 or any($checks[]; .unknown) then "unknown"
    else "allow" end
  ') || return 1
  case "$result" in
    refuse:*)
      echo "error: Claude crew admission refused for account $identity: ${result#refuse: }; choose Codex or route to a secondmate on another account" >&2
      return 1 ;;
    unknown) echo 'warning: Claude quota floor unverifiable; disclosed uncertainty, concurrency cap still enforced' >&2 ;;
  esac
}
