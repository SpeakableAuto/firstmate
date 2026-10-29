# shellcheck shell=bash
# Placement gate for configured homes. The parent holds .placement-admission.lock
# from begin through launch publication/rollback; cleanup always releases it.
# fm_placement_begin <id> initializes one attempt before spawn's existing locks.
# fm_placement_check <harness> <model> <effort> <quota-pass|fail|unknown>
# publishes one decision BEFORE provisioning. fm_placement_abort records early
# refusals whose fit/room/quota evidence could not be obtained, exactly once.
# fm-placement.py owns the atomic decision/wait format. Configuration lives in
# docs/configuration.md. The optional room seam is fm-worktree-room.sh <project>;
# absent is recorded as not-installed, present must exit 0 (no slot cleanup here).

FM_PLACEMENT_ACTIVE=0
FM_PLACEMENT_RECORDED=0
FM_PLACEMENT_LOCK_HELD=0

fm_placement_begin() {
  FM_PLACEMENT_ID=$1
  # An absent config preserves unconfigured template homes. A present but
  # unreadable/malformed file enables the gate and fails closed in assess.
  [ -e "$CONFIG/crew-placement.json" ] || [ -L "$CONFIG/crew-placement.json" ] \
    || [ -e "$STATE/capacity.json" ] || return 0
  FM_PLACEMENT_ACTIVE=1
  FM_PLACEMENT_LOCK="$STATE/.placement-admission.lock"
  if fm_lock_try_acquire "$FM_PLACEMENT_LOCK"; then
    FM_PLACEMENT_LOCK_HELD=1
    return 0
  fi
  fm_placement_abort locks
  echo 'error: placement refused: locks (placement admission is occupied)' >&2
  return 1
}

fm_placement_publish() {
  local decision=$1 mode=${FM_PLACEMENT_MODE:-spawn} recorded
  decision=$(printf '%s\n' "$decision" | jq --arg project "${PROJ_ABS:-${PROJ:-}}" --argjson relaunch "${RELAUNCH:-0}" \
    '.request.project=$project | .request.relaunch=$relaunch') || return 1
  if fm_backlog_row_probe "$DATA" "$FM_PLACEMENT_ID" >/dev/null 2>&1; then
    case "$FM_BACKLOG_ROW_STATE" in
      'queued no no'|'in_flight no no') ;;
      *) decision=$(printf '%s\n' "$decision" | jq --arg hold "${FM_BACKLOG_ROW_HOLD_KIND:-external}" '.hold=$hold') || return 1 ;;
    esac
  fi
  recorded=$(printf '%s\n' "$decision" | python3 "$SCRIPT_DIR/fm-placement.py" record "$STATE" "$FM_PLACEMENT_ID" "$mode") || return 1
  FM_PLACEMENT_RECORDED=1
  if ! printf '%s\n' "$recorded" | jq -e '.admitted' >/dev/null; then
    printf 'error: placement refused: %s (state/capacity.json)\n' "$(printf '%s\n' "$recorded" | jq -r '[.checks|to_entries[]|select(.value.status != "pass")|"\(.key): \(.value.reason)"]|join("; ")')" >&2
    return 1
  fi
}

fm_placement_abort() {
  local reason=${1:-locks} decision
  [ "$FM_PLACEMENT_ACTIVE" = 1 ] && [ "$FM_PLACEMENT_RECORDED" = 0 ] || return 0
  decision=$(jq -cn --arg reason "$reason" '{locks:{status:"fail",reason:$reason}}' |
    python3 "$SCRIPT_DIR/fm-placement.py" assess "$CONFIG" "$DATA" "$FM_PLACEMENT_ID" \
      "${HARNESS:-${HARNESS_ARG:-}}" "${MODEL:-}" "${EFFORT:-}") || return 1
  fm_placement_publish "$decision" || return 1
}

fm_placement_release() {
  [ "$FM_PLACEMENT_LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$FM_PLACEMENT_LOCK" || return 1
  FM_PLACEMENT_LOCK_HELD=0
}

fm_placement_count() {
  local meta backend target verdict count=0 gen started now
  now=$(date +%s)
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$meta" != "$STATE/$FM_PLACEMENT_ID.meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    verdict=unreadable
    if fm_backend_source "$backend"; then
      verdict=$(fm_quota_pacing_agent_state "$backend" "$target")
      if [ "$verdict" = missing ]; then
        verdict=$(fm_control_endpoint_absence_verdict "$backend" "$target")
        verdict=${verdict%%$'\t'*}
      fi
    fi
    case "$verdict" in
      dead|gone)
        gen=$(fm_meta_get "$meta" spawn_gen)
        started=${gen#s}; started=${started%%.*}
        case "$started" in ''|*[!0-9]*) continue ;; esac
        [ "$((now - started))" -lt 60 ] || continue
        ;;
    esac
    count=$((count + 1))
  done
  printf '%s' "$count"
}

fm_placement_profile() { # <harness> <model> <effort>
  jq -ce --slurpfile work "$DATA/$FM_PLACEMENT_ID/placement.json" --arg h "$1" --arg m "$2" --arg e "$3" '
    .rules[$work[0].dispatch_rule].use | if type == "array" then . else [.] end |
    map(select(.harness == $h and (.model // "") == $m and (.effort // "") == $e)) |
    if length == 1 then .[0] else error("selected profile absent or ambiguous") end
  ' "$CONFIG/crew-dispatch.json"
}

fm_placement_quota() { # <harness> <model> <effort>; Claude guard handled by caller
  local harness=$1 model=$2 snapshot provider lane selected
  FM_PLACEMENT_QUOTA_DETAIL='{"status":"fail","reason":"quota snapshot or selected account mapping absent"}'
  snapshot=$("$SCRIPT_DIR/fm-quota-snapshot.sh") || return 1
  selected=$(fm_placement_profile "$harness" "$model" "$3") || return 1
  provider=$(printf '%s\n' "$selected" | jq -r '.provider // ""') || return 1
  [ -n "$provider" ] || provider=$(fm_quota_single_provider_for_harness "$harness") || return 1
  lane=$(jq -rn --arg h "$harness" --arg m "$model" "$FM_QUOTA_ROW_JQ"'quota_lane($h; $m)') || return 1
  FM_PLACEMENT_QUOTA_DETAIL=$(printf '%s\n' "$snapshot" | jq -c --arg provider "$provider" --arg lane "$lane" --arg model "$model" "$FM_QUOTA_ROW_JQ"'
    quota_row(.; $provider; $lane) as $row |
    ($row.quotaSemantics.effectiveAvailability // [] | map(select(
      .scope == "all_models" or .scope == "all_products" or
      .scope == ("model:" + ($model | split("/") | last)) or
      .scope == ("product:" + ($model | split("/") | last))))) as $bounds |
    {provider:$provider,accountKey:($row.accountKey // "default"),model:$model,
      bounds:($bounds|map({scope,status,effectivePercentRemaining}))} +
    (if $row == null then {status:"fail",reason:"matched machine/account quota absent"}
     elif $row.state.stale != false then {status:"fail",reason:"quota freshness absent or stale"}
     elif ($bounds|length) == 0 then {status:"fail",reason:"applicable quota bound absent"}
     elif any($bounds[]; .status != "known" or (.effectivePercentRemaining|type) != "number")
       then {status:"fail",reason:"quota measurement unknown or missing"}
     elif any($bounds[]; .effectivePercentRemaining <= 0 or .runway.status == "exhausted_now")
       then {status:"fail",reason:"account quota exhausted"}
     else {status:"pass",reason:"fresh selected machine/account quota"} end)
  ') || return 1
  printf '%s\n' "$FM_PLACEMENT_QUOTA_DETAIL" | jq -e '.status == "pass"' >/dev/null
}

fm_placement_check() {
  local harness=$1 model=$2 effort=$3 quota=$4 disk=fail slots=not-installed locks=fail count evidence decision memory
  [ "$FM_PLACEMENT_ACTIVE" = 1 ] || return 0
  [ "$FM_PLACEMENT_LOCK_HELD" != 1 ] || locks=pass
  if FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-disk-guard.sh" --check-room >/dev/null 2>&1; then disk=pass; fi
  if [ -e "$SCRIPT_DIR/fm-worktree-room.sh" ]; then
    slots=fail
    if "$SCRIPT_DIR/fm-worktree-room.sh" "${PROJ_ABS:-${PROJ:-}}" >/dev/null 2>&1; then slots=pass; fi
  fi
  count=$(fm_placement_count) || count=null
  memory=$(python3 "$SCRIPT_DIR/fm-placement.py" memory) || memory='{}'
  FM_PLACEMENT_QUOTA_DETAIL=$(jq -cn --arg status "$quota" --arg account "${CLAUDE_QUOTA_IDENTITY:-}" \
    '{status:$status,reason:"selected account admission",account:$account}') || return 1
  if [ "$quota" = unknown ]; then
    quota=fail
    if fm_placement_quota "$harness" "$model" "$effort"; then quota=pass; fi
  fi
  evidence=$(jq -cn --argjson quota "$FM_PLACEMENT_QUOTA_DETAIL" --arg disk "$disk" --arg slots "$slots" --arg locks "$locks" --argjson count "$count" --argjson memory "$memory" '
    {quota:$quota,disk:{status:$disk},
     slots:{status:$slots},locks:{status:$locks,reason:"placement and spawn locks"},crew_count:$count,memory:$memory}') || return 1
  decision=$(printf '%s\n' "$evidence" | python3 "$SCRIPT_DIR/fm-placement.py" assess "$CONFIG" "$DATA" "$FM_PLACEMENT_ID" "$harness" "$model" "$effort") || return 1
  fm_placement_publish "$decision"
}
