#!/usr/bin/env bash
# Check free space on the user's home filesystem and clean opted-in caches.
# Usage: FM_HOME=/absolute/firstmate fm-disk-guard.sh [--dry-run]
# Config: $FM_HOME/config/disk-guard, plain lines (never sourced):
#   threshold_gib=15
#   cache=xcode-derived-data
#   cache=npm
#   cache=docker
# Default threshold is 15 GiB; no caches are enabled implicitly. Unknown keys,
# targets, and invalid thresholds fail before cleanup. Threshold is 1..1048576.
# xcode-derived-data clears ~/Library/Developer/Xcode/DerivedData contents;
# npm clears only ~/.npm/_cacache contents. Python 3 pins directory handles;
# symlinked ancestors and detected directory replacements are refused.
# docker uses the selected local unix socket, prunes dangling images and unused
# build cache only, never volumes, containers, or all images. Remote endpoints
# are refused. Missing tools or failed cleanup alert and exit 1.
# Below threshold, queue a Firstmate check wake before cleanup, then a result
# wake with before/after KiB and failures. Failed measurement also alerts.
# Alerts first persist in an ordered journal below state/.disk-guard-alerts and
# retry on every check, even after space recovers. Delivery is at least once.
# Healthy checks without pending alerts are silent. Dry-run never mutates.
# A per-home mkdir lock prevents overlapping cleanup; contention exits 1.
# After an interrupted run, remove state/.disk-guard.lock only after verifying
# no guard process remains. Exit 0 means check completed, not space recovered.
# See docs/disk-guard.md for local launchd installation (no automatic install).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '2,/^set /{ /^#/{ s/^# \{0,1\}//; p; }; }' "$0"; }
dry_run=0
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --dry-run) dry_run=1; shift ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }
: "${FM_HOME:?set FM_HOME to the receiving Firstmate home}"
case "$FM_HOME" in /*) ;; *) echo 'FM_HOME must be absolute' >&2; exit 2 ;; esac
# Resolve the user home once, so aliases in its parent do not count as cache links.
user_home=$(cd "$HOME" && pwd -P)
[ "$user_home" != / ] || { echo 'refusing root as user home' >&2; exit 2; }
threshold=15
caches=()
config="$FM_HOME/config/disk-guard"
if [ -e "$config" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      threshold_gib=*) threshold=${line#*=} ;;
      cache=xcode-derived-data|cache=npm|cache=docker) caches+=("${line#*=}") ;;
      *) echo "invalid disk-guard configuration: $line" >&2; exit 2 ;;
    esac
  done < "$config"
fi
case "$threshold" in ''|*[!0-9]*|0*) echo 'invalid threshold_gib' >&2; exit 2 ;; esac
[ "${#threshold}" -le 7 ] && [ "$threshold" -le 1048576 ] || { echo 'invalid threshold_gib' >&2; exit 2; }
threshold_kib=$((threshold * 1048576))

pending="$FM_HOME/state/.disk-guard-alerts"
pending_journal="$pending/alerts"
pending_lock="$pending/.lock"
wake_lib_loaded=0
load_wake_lib() {
  [ "$wake_lib_loaded" -eq 0 ] || return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh" || return 1
  wake_lib_loaded=1
}

persist_alert() {
  local payload=$1 tmp status=0
  mkdir -p "$pending" || return 1
  load_wake_lib || return 1
  fm_lock_acquire_wait "$pending_lock" || return 1
  tmp=$(mktemp "$pending/.alerts.XXXXXXXX") || status=1
  if [ "$status" -eq 0 ]; then
    if [ -e "$pending_journal" ] || [ -L "$pending_journal" ]; then
      if [ -f "$pending_journal" ] && [ ! -L "$pending_journal" ]; then
        cat "$pending_journal" > "$tmp" || status=1
      else
        status=1
      fi
    fi
  fi
  if [ "$status" -eq 0 ]; then
    printf 'check: disk-guard: %s\n' "$payload" >> "$tmp" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    chmod 0600 "$tmp" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    mv -f -- "$tmp" "$pending_journal" || status=1
  fi
  if [ "$status" -ne 0 ] && [ -n "${tmp:-}" ]; then rm -f -- "$tmp"; fi
  fm_lock_release "$pending_lock" || status=1
  return "$status"
}
flush_alerts() {
  local status=0 payload
  if [ ! -e "$pending_journal" ] && [ ! -L "$pending_journal" ]; then return 0; fi
  [ -f "$pending_journal" ] && [ ! -L "$pending_journal" ] || return 1
  load_wake_lib || return 1
  fm_lock_acquire_wait "$pending_lock" || return 1
  if [ ! -e "$pending_journal" ] && [ ! -L "$pending_journal" ]; then
    fm_lock_release "$pending_lock"
    return 0
  fi
  if [ ! -f "$pending_journal" ] || [ -L "$pending_journal" ]; then
    fm_lock_release "$pending_lock"
    return 1
  fi
  if ! fm_lock_acquire_wait_bounded "$FM_WAKE_QUEUE_LOCK" 2; then
    fm_lock_release "$pending_lock"
    return 1
  fi
  while IFS= read -r payload || [ -n "$payload" ]; do
    if ! fm_wake_append_locked check disk-guard "$payload"; then
      status=1
      break
    fi
  done < "$pending_journal"
  if [ "$status" -eq 0 ]; then rm -- "$pending_journal" || status=1; fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
  fm_lock_release "$pending_lock" || status=1
  return "$status"
}
alert() {
  if [ "$dry_run" -eq 1 ]; then printf '%s\n' "$*"; return; fi
  persist_alert "$*" || return 1
  flush_alerts
}
retry_status=0
if [ "$dry_run" -eq 0 ]; then flush_alerts || retry_status=1; fi
free_kib() {
  local output available
  output=$(LC_ALL=C df -Pk "$user_home") || return 1
  available=$(printf '%s\n' "$output" | awk 'NR == 2 {print $4}')
  case "$available" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$available"
}
if ! before=$(free_kib); then
  alert 'free-space measurement failed; no caches touched'
  exit 1
fi
[ "$before" -lt "$threshold_kib" ] || exit "$retry_status"
if [ "$dry_run" -eq 1 ]; then
  printf 'below %s GiB: %s KiB available; planned caches:' "$threshold" "$before"
  printf ' %s' "${caches[@]+${caches[@]}}"
  printf '\n'
  exit 0
fi
mkdir -p "$FM_HOME/state"
lock="$FM_HOME/state/.disk-guard.lock"
if ! mkdir "$lock" 2>/dev/null; then
  alert 'cleanup lock exists; verify the prior guard before removing state/.disk-guard.lock'
  exit 1
fi
trap 'rmdir "$lock"' EXIT
failures=0
if ! alert "low space: $before KiB available, threshold $threshold GiB; starting configured cleanup"; then
  echo 'could not queue the starting alert; continuing configured cleanup' >&2
  failures=$((failures + 1))
fi

clear_cache() {
  python3 "$SCRIPT_DIR/fm-disk-cache-clear.py" "$user_home" "$1"
}
clear_docker() {
  local endpoint
  command -v docker >/dev/null || return 1
  if [ -n "${DOCKER_CONTEXT:-}" ] || [ -z "${DOCKER_HOST:-}" ]; then
    endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}') || return 1
  else
    endpoint=$DOCKER_HOST
  fi
  case "$endpoint" in unix:///*) ;; *) echo 'refusing non-local Docker endpoint' >&2; return 1 ;; esac
  # Pin the inspected endpoint; never let ambient context override it.
  (unset DOCKER_CONTEXT DOCKER_HOST
   status=0
   docker --host "$endpoint" image prune --force || status=1
   docker --host "$endpoint" builder prune --force || status=1
   exit "$status")
}
for cache in "${caches[@]+${caches[@]}}"; do
  case "$cache" in
    xcode-derived-data) clear_cache Library/Developer/Xcode/DerivedData || failures=$((failures + 1)) ;;
    npm) clear_cache .npm/_cacache || failures=$((failures + 1)) ;;
    docker) clear_docker || failures=$((failures + 1)) ;;
  esac
done
if ! after=$(free_kib); then after=unknown; failures=$((failures + 1)); fi
if ! alert "cleanup complete: before=$before KiB after=$after KiB threshold=$threshold GiB failures=$failures"; then
  echo 'could not queue the cleanup result alert' >&2
  failures=$((failures + 1))
fi
[ "$failures" -eq 0 ]
