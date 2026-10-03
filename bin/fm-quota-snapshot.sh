#!/usr/bin/env bash
# fm-quota-snapshot.sh - one validated, read-only quota-axi --json snapshot,
# from this machine or from the machine hosting a remote second mate.
#
# Usage:
#   fm-quota-snapshot.sh
#   fm-quota-snapshot.sh --secondmate <id>
#
# With no arguments it reads `quota-axi --json` on this machine, bounded by
# FM_QUOTA_SNAPSHOT_TIMEOUT seconds (default 10), checks the result with
# fm_quota_json_valid from bin/fm-quota-axi-lib.sh, fills the rows it could
# not measure from this home's optional config/quota-feed through
# fm_quota_feed_merge (a fresh feed also stands in for a failed read), and
# prints it on stdout with top-level firstmateClaudeAdmission and
# firstmatePacing objects: this home's admission and opted-in pacing evidence,
# so a parent dispatching into this machine applies its guards from the same
# read. bin/fm-claude-admission-lib.sh owns the Claude guard.
# Cache reuse is owned by docs/configuration.md "Quota snapshot reuse".
# This is also the command the --secondmate form runs on the remote host.
#
# --secondmate <id> reads the same snapshot from the machine hosting the remote
# route <id> in data/secondmates.md, through bin/fm-on.sh, bounded by
# FM_REMOTE_QUOTA_TIMEOUT seconds (default 25), and validates it again here.
# The remote host's quota-axi must be on the remote job PATH that
# bin/fm-remote-job-lib.sh composes. A successful read is kept under
# state/quota-remote/<id>.json and reused while it is younger than
# FM_REMOTE_QUOTA_OK_TTL seconds (default 60), with its age added as
# firstmateRemoteCache.ageSeconds, so a burst of dispatches costs one remote
# read. A failure is kept under state/quota-remote/<id>.err and reused while it
# is younger than FM_REMOTE_QUOTA_TTL seconds (default 120), so an unreachable
# host costs one bounded wait per window. Nothing is reused past its TTL.
#
# Exit 0 prints a validated snapshot. Exit 1 prints nothing on stdout and one
# "quota-snapshot: unavailable (<reason>)" line on stderr: that quota is
# unknown, which callers disclose and never read as exhausted or as healthy.
# Exit 2 is a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-claude-admission-lib.sh
. "$SCRIPT_DIR/fm-claude-admission-lib.sh"

usage() { sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; }
die_usage() { printf 'error: %s\n' "$1" >&2; exit 2; }
unavailable() { printf 'quota-snapshot: unavailable (%s)\n' "$1" >&2; exit 1; }

positive_int() { # <name> <value>
  case "$2" in ''|0*|*[!0-9]*) die_usage "$1 must be a positive integer: $2" ;; esac
}

SECONDMATE=
case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  --secondmate)
    [ "$#" -eq 2 ] || die_usage "--secondmate takes exactly one id"
    SECONDMATE=$2
    case "$SECONDMATE" in
      ''|-*|.*|*[!A-Za-z0-9._-]*) die_usage "secondmate id must be a safe route id: $SECONDMATE" ;;
    esac
    ;;
  *) die_usage "unknown argument: $1" ;;
esac
[ -z "$SECONDMATE" ] && [ "$#" -gt 0 ] && die_usage "unexpected arguments"

command -v jq >/dev/null 2>&1 || unavailable "jq not installed"

if [ -z "$SECONDMATE" ]; then
  LOCAL_TIMEOUT=${FM_QUOTA_SNAPSHOT_TIMEOUT:-10}
  positive_int FM_QUOTA_SNAPSHOT_TIMEOUT "$LOCAL_TIMEOUT"
  SNAPSHOT_FILE=$(mktemp) || unavailable "mktemp failed"
  MERGED_FILE=$(mktemp) || { rm -f "$SNAPSHOT_FILE"; unavailable "mktemp failed"; }
  trap 'rm -f "$SNAPSHOT_FILE" "$MERGED_FILE"' EXIT
  live_failure=
  if ! command -v quota-axi >/dev/null 2>&1; then
    live_failure="quota-axi not installed"
  else
    snapshot=$(fm_quota_read_json "$LOCAL_TIMEOUT" quota-axi --json 2>/dev/null </dev/null); rc=$?
    if fm_timed_out "$rc"; then live_failure="quota-axi --json exceeded ${LOCAL_TIMEOUT}s"
    elif [ "$rc" -ne 0 ]; then live_failure="quota-axi --json exited $rc"
    elif ! printf '%s\n' "$snapshot" | fm_quota_json_valid; then live_failure="quota-axi --json returned an invalid snapshot"
    else printf '%s\n' "$snapshot" > "$SNAPSHOT_FILE" || unavailable "could not stage the snapshot"
    fi
  fi
  # A configured quota feed fills the rows this read could not measure, or
  # stands in for a failed read; docs/configuration.md owns the contract.
  fm_quota_feed_merge "$CONFIG" "$SNAPSHOT_FILE" > "$MERGED_FILE" || unavailable "$live_failure"
  admission=$(fm_claude_admission_state "$CONFIG" "$STATE" "$MERGED_FILE" 2>/dev/null) \
    || admission='{"unknown":"Claude crew guard evidence failed"}'
  pacing='{"schemaVersion":1,"accounts":[]}'
  if [ -f "$CONFIG/crew-dispatch.json" ]; then
    pacing=$(node "$SCRIPT_DIR/fm-quota-pacing.mjs" "$CONFIG/crew-dispatch.json" "$MERGED_FILE") \
      || unavailable "invalid quota pacing settings"
  fi
  jq -c --argjson admission "$admission" --argjson pacing "$pacing" \
    '. + {firstmateClaudeAdmission: $admission, firstmatePacing: $pacing}' "$MERGED_FILE" \
    || unavailable "could not attach Claude crew guard evidence"
  exit 0
fi

REMOTE_TIMEOUT=${FM_REMOTE_QUOTA_TIMEOUT:-25}
TTL=${FM_REMOTE_QUOTA_TTL:-120}
OK_TTL=${FM_REMOTE_QUOTA_OK_TTL:-60}
positive_int FM_REMOTE_QUOTA_TIMEOUT "$REMOTE_TIMEOUT"
positive_int FM_REMOTE_QUOTA_TTL "$TTL"
positive_int FM_REMOTE_QUOTA_OK_TTL "$OK_TTL"
CACHE_DIR="$STATE/quota-remote"
CACHE_ERR="$CACHE_DIR/$SECONDMATE.err"
CACHE_OK="$CACHE_DIR/$SECONDMATE.json"

fresh() { # <file> <ttl>
  local age
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  age=$(fm_lock_age "$1") || return 1
  [ "$age" -ge 0 ] && [ "$age" -lt "$2" ]
}

if fresh "$CACHE_OK" "$OK_TTL" && fm_quota_json_valid < "$CACHE_OK"; then
  age=$(fm_lock_age "$CACHE_OK")
  if jq -c --argjson age "$age" '. + {firstmateRemoteCache: {ageSeconds: $age}}' "$CACHE_OK" 2>/dev/null; then
    exit 0
  fi
fi

if fresh "$CACHE_ERR" "$TTL"; then
  reason=$(head -c 300 "$CACHE_ERR" | tr -d '\n')
  unavailable "${reason:-remote read failed} (cached)"
fi

record_failure() { # <reason>
  local tmp
  if mkdir -p "$CACHE_DIR" 2>/dev/null && tmp=$(mktemp "$CACHE_DIR/.$SECONDMATE.err.XXXXXX" 2>/dev/null); then
    if ! { printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$CACHE_ERR"; }; then
      rm -f "$tmp"
    fi
  fi
  unavailable "$1"
}

OUT=$(mktemp) || unavailable "mktemp failed"
ERR=$(mktemp) || { rm -f "$OUT"; unavailable "mktemp failed"; }
trap 'rm -f "$OUT" "$ERR"' EXIT
fm_run_timed "$REMOTE_TIMEOUT" "$SCRIPT_DIR/fm-on.sh" "$SECONDMATE" fm-quota-snapshot.sh > "$OUT" 2> "$ERR"; rc=$?
if fm_timed_out "$rc"; then record_failure "remote read of $SECONDMATE exceeded ${REMOTE_TIMEOUT}s"; fi
# The first stderr line, from the route check or the remote snapshot, names
# the cause; it is bounded and flattened before it reaches a cache or a caller.
detail=$(head -n 1 "$ERR" | head -c 200 | tr -d '\r\n' | tr '\t' ' ')
case "$rc" in
  0) ;;
  255) record_failure "$SECONDMATE's machine unreachable${detail:+: $detail}" ;;
  *) record_failure "remote read of $SECONDMATE exited $rc${detail:+: $detail}" ;;
esac
fm_quota_json_valid < "$OUT" || record_failure "$SECONDMATE returned an invalid snapshot"
rm -f "$CACHE_ERR" 2>/dev/null || true
if mkdir -p "$CACHE_DIR" 2>/dev/null && tmp=$(mktemp "$CACHE_DIR/.$SECONDMATE.json.XXXXXX" 2>/dev/null); then
  if ! { cp "$OUT" "$tmp" && mv -f "$tmp" "$CACHE_OK"; }; then
    rm -f "$tmp"
  fi
fi
cat "$OUT"
exit 0
