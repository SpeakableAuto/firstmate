#!/usr/bin/env bash
# Capacity queue read/recheck entrypoint (never launches a worker).
# Usage: fm-placement.sh effective | waits | tick | freed
# effective prints configured limits, defaults, cadence and slot seam.
# waits prints morning-report JSON, including >4h flags and 48h history rows.
# tick rechecks after a freeing fingerprint change and no later than 900 seconds
# while the ordinary watcher runs. Successful rechecks enqueue capacity-ready
# through the existing wake queue; firstmate reroutes through normal dispatch.
# Captain/external holds and non-queued backlog items never enter rechecks;
# done or missing backlog rows leave the queue, and unplaceable (fit-refused)
# waits stay listed for rerouting but are never rechecked here.
# freed marks a slot reclaim event for the next watcher tick.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-claude-admission-lib.sh
. "$SCRIPT_DIR/fm-claude-admission-lib.sh"
# shellcheck source=bin/fm-placement-lib.sh
. "$SCRIPT_DIR/fm-placement-lib.sh"
case "${1:-}" in
  --help|-h) sed -n '2,12s/^# //p' "$0"; exit 0 ;;
  waits) backlog_json "$DATA/backlog.md" | python3 "$SCRIPT_DIR/fm-placement.py" ordered "$STATE"; exit ;;
  effective)
    profile=null
    enabled=false
    if [ -e "$CONFIG/crew-placement.json" ] || [ -L "$CONFIG/crew-placement.json" ]; then
      enabled=true
      profile=$(jq '{version,workloads,max_crew,min_free_memory_percent,max_swap_mib,drive,required_drive_dirs,data_volume}' "$CONFIG/crew-placement.json") || exit 1
    fi
    [ ! -e "$STATE/capacity.json" ] || enabled=true
    settings='{}'
    [ ! -e "$CONFIG/crew-dispatch.json" ] || settings=$(cat "$CONFIG/crew-dispatch.json") || exit 1
    limits=$(fm_claude_admission_limits "$settings" '' '') || exit 1
    disk=$(FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-disk-guard.sh" --print-config) || exit 1
    slots=not-installed
    [ ! -e "$SCRIPT_DIR/fm-worktree-slots.sh" ] || slots="$SCRIPT_DIR/fm-worktree-slots.sh"
    jq -n --argjson profile "$profile" --argjson disk "$disk" --argjson claude "$limits" \
      --arg slots "$slots" --arg age "${QUOTA_AXI_MAX_AGE:-15m}" --argjson enabled "$enabled" \
      '{enabled:$enabled,placement:$profile,disk:$disk,claude:$claude,slot_seam:$slots,quota_max_age:$age,
        recheck_seconds:900,wait_alert_seconds:14400}'
    exit ;;
  freed) touch "$STATE/.capacity-freed"; exit ;;
  tick) ;;
  *) echo 'usage: fm-placement.sh effective|waits|tick|freed' >&2; exit 2 ;;
esac
[ -f "$STATE/capacity.json" ] || exit 0
fm_lock_try_acquire "$STATE/.capacity-recheck.lock" || exit 0
trap 'fm_placement_release; fm_lock_release "$STATE/.capacity-recheck.lock"' EXIT
fm_placement_alerts || exit 1
[ -n "$(python3 "$SCRIPT_DIR/fm-placement.py" due "$STATE")" ] || exit 0
rows=$(backlog_json "$DATA/backlog.md" | python3 "$SCRIPT_DIR/fm-placement.py" ordered "$STATE") || exit 1
while IFS= read -r row; do
  [ "$(printf '%s\n' "$row" | jq -r '.state')" != history ] || continue
  id=$(printf '%s\n' "$row" | jq -r '.task')
  RELAUNCH=$(printf '%s\n' "$row" | jq -r '.request.relaunch // 0')
  # The backlog remains the authority: missing or terminal rows leave the queue,
  # unreadable rows stay untouched until the next tick.
  if ! fm_backlog_row_probe "$DATA" "$id"; then
    [ "$FM_BACKLOG_ROW_RESULT" != not_found ] \
      || python3 "$SCRIPT_DIR/fm-placement.py" drop "$STATE" "$id" >/dev/null || exit 1
    continue
  fi
  if [ "${FM_BACKLOG_ROW_STATE%% *}" = "done" ]; then
    python3 "$SCRIPT_DIR/fm-placement.py" drop "$STATE" "$id" >/dev/null || exit 1
    continue
  fi
  if [ "$FM_BACKLOG_ROW_STATE" != 'queued no no' ] \
     && { [ "$RELAUNCH" != 1 ] || [ "$FM_BACKLOG_ROW_STATE" != 'in_flight no no' ]; }; then
    python3 "$SCRIPT_DIR/fm-placement.py" hold "$STATE" "$id" "${FM_BACKLOG_ROW_HOLD_KIND:-external}" >/dev/null || exit 1
    continue
  fi
  [ "$(printf '%s\n' "$row" | jq -r '.state')" != unplaceable ] || continue
  [ "$RELAUNCH" = 1 ] || [ ! -e "$STATE/$id.meta" ] || continue
  FM_PLACEMENT_ACTIVE=0 FM_PLACEMENT_RECORDED=0 FM_PLACEMENT_MODE=recheck
  fm_placement_begin "$id" || continue
  locked=0
  for lock in "$STATE/.spawn-$id.lock" "$STATE/.control-$id.lock" "$(fm_task_set_lock_path "$STATE")"; do
    [ ! -e "$lock" ] || locked=1
  done
  if [ "$locked" = 1 ]; then
    fm_placement_abort locks || true
    fm_placement_release
    continue
  fi
  harness=$(printf '%s\n' "$row" | jq -r '.request.harness')
  model=$(printf '%s\n' "$row" | jq -r '.request.model')
  effort=$(printf '%s\n' "$row" | jq -r '.request.effort')
  PROJ=$(printf '%s\n' "$row" | jq -r '.request.project // ""')
  quota=unknown
  if [ "$harness" = claude ]; then
    quota=fail
    account=$(fm_worker_account_select claude "$CONFIG" "$model" claude '') || account=unknown
    if [ "$account" = unknown ]; then
      identity=unknown
    elif [ -n "$account" ]; then
      identity=${account%%$'\t'*}
    else
      identity=$(fm_worker_account_claude_ambient_identity) || identity=unknown
    fi
    CLAUDE_QUOTA_IDENTITY=$identity
    selected=$(fm_placement_profile "$harness" "$model" "$effort") || selected='{}'
    scope=$(printf '%s\n' "$selected" | jq -r '.floor.scope // ""')
    floor=$(printf '%s\n' "$selected" | jq -r '.floor.min_percent // ""')
    if fm_claude_admission_check "$CONFIG" "$STATE" "$id" "$identity" "$scope" "$floor" "$model"; then quota=pass; fi
  elif fm_quota_pacing_config_applies "$CONFIG" "$harness" "$model"; then
    if ! fm_quota_pacing_admission_check "$CONFIG" "$STATE" "$id" "$harness" "$model"; then quota=fail; fi
  fi
  if fm_placement_check "$harness" "$model" "$effort" "$quota"; then
    fm_wake_append check capacity-ready "check: capacity-ready $id: placement recheck passed; reroute through dispatch" || exit 1
  fi
  fm_placement_release
done < <(printf '%s\n' "$rows" | jq -c '.[]')
