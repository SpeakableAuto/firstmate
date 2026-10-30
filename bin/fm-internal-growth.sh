#!/usr/bin/env bash
# Flag internal-volume folders that grew past a threshold outside an allowed list.
# Usage: FM_HOME=/absolute/firstmate fm-internal-growth.sh [--dry-run]
# Config: $FM_HOME/config/internal-growth, plain lines (never sourced):
#   volume=/System/Volumes/Data   required; free space is read from it
#   scan=/Users/me                repeatable, required; must be on that volume
#   allow=/Users/me/firstmate     repeatable; growth at or below it is ignored
#   threshold_gib=1               default 1
#   depth=3                       folder depth below each scan path, default 3
#   min_baseline_hours=20         default 20; 0 rolls the baseline every run
#   timeout_seconds=1800          whole-run measurement budget, default 1800
# Paths are plain absolute paths; overlapping scan paths and unknown keys refuse.
# Each run measures folder sizes with `du -xk -d <depth>` and total volume use
# with `df -kP`. Growth of an allowed folder is subtracted from its ancestors,
# and only the deepest folder whose remaining growth exceeds the threshold is
# flagged. Volume growth not explained by allowed or already flagged folder
# growth opens its own episode. A folder that du cannot read is recorded as
# UNMEASURED in every log row and any alert. Only a missing scan-root total fails
# the measurement. A measurement over the budget is killed and reported as a
# failed measurement. The first complete run records a baseline.
# The baseline rolls forward when it is at least min_baseline_hours old, so extra
# runs within a day compare against the same day-old baseline.
# One Firstmate check wake names every newly flagged folder. A flagged folder is
# an open episode and stays silent on later runs until a run no longer flags it;
# a failed measurement is its own episode. A wake that cannot be queued leaves
# the episode closed, so the next run retries it.
# State lives in state/internal-growth/: baseline.tsv, episodes.tsv, and
# log.jsonl, which gains one JSON line per run (used and free KiB, used delta,
# unmeasured and flagged folders, new episodes, any alert) as the inspectable
# capacity record.
# --dry-run measures and prints that JSON line without writing state or alerting.
# Exit 0 means the check completed and any alert was queued; 1 means measurement
# or alert delivery failed; 2 means invalid usage or configuration.
# A per-home lock skips a run that overlaps a live one; a dead holder's lock
# is reaped. See docs/work-drive.md.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '2,/^set /{ /^#/{ s/^# \{0,1\}//; p; }; }' "$0"; }
: "${FM_HOME:?set FM_HOME to the Firstmate home}"
case "$FM_HOME" in /*) ;; *) echo 'FM_HOME must be absolute' >&2; exit 2 ;; esac
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
dry=()
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --dry-run) dry=(--dry-run); shift ;;
  --queue-alert)
    # Internal: the Python check queues its alert through the shared wake queue.
    [ "$#" -eq 2 ] || exit 2
    fm_wake_append check internal-growth "check: internal-growth: $2"
    exit ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }
if [ "${#dry[@]}" -eq 0 ]; then
  mkdir -p "$STATE"
  lock="$STATE/.internal-growth.lock"
  if ! fm_lock_try_acquire "$lock"; then
    echo "another live internal growth check holds $lock; skipped" >&2
    exit 1
  fi
  trap 'fm_lock_release "$lock"' EXIT
fi
python3 "$SCRIPT_DIR/fm-internal-growth.py" "$CONFIG/internal-growth" \
  "$STATE/internal-growth" "$SCRIPT_DIR/fm-internal-growth.sh" "${dry[@]+"${dry[@]}"}"
