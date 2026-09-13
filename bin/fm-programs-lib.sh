# shellcheck shell=bash
# Accepted delivery continuation, derived only from the native backlog.
# fm_programs_json <backlog> [epoch] is read-only and never queries workers.
# In-flight kind=program rows are accepted commissions; queued rows are not.
# Optional exact body lines (one each):
#   continuation: active|paused       default active; paused requires user authority
#   recheck-at: YYYY-MM-DDTHH:MM:SSZ   earliest check, UTC; omitted means now
#   children: id id ...               references, never a second task owner
#   agreement: path                   evidence pointer, never executed/read here
# Unfinished holds/dependencies remain visible and keep the watcher alive.
# A due event is an engineering reconciliation request, NEVER dispatch authority.
# fm_program_reconcile_tick <state> runs under the existing singleton watcher.
# It appends one check/program-reconcile event using fm-wake-lib, then records
# only a content fingerprint and emission time in state/.program-reconciliation.
# Unacknowledged events suppress duplicates; unchanged content retries after
# FM_PROGRAM_RECHECK_SECS (default 900, minimum 60), even with no live workers.
# Runtime receipts are disposable; accepted work remains solely in backlog.md.
# FM_PROGRAM_NOW_EPOCH is an optional deterministic clock for isolated fixtures.

# shellcheck source=bin/fm-backlog-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-backlog-lib.sh"

fm_programs_json() {
  local backlog=$1 now=${2:-${FM_PROGRAM_NOW_EPOCH:-$(date +%s)}} raw
  case "$now" in ''|*[!0-9]*) return 2 ;; esac
  if [ -e "$backlog" ]; then
    [ -f "$backlog" ] && [ -r "$backlog" ] || return 1
  fi
  raw=$(backlog_json "$backlog") || return 1
  printf '%s' "$raw" | jq --argjson now "$now" '
    . as $backlog
    | [.records[] | select((.structured | not) and (.state == "in_flight" or .state == "queued")
        and (.raw | test("kind:[[:space:]]*program")))
        | {id:"unparseable-program",errors:["malformed program backlog row"]}] as $parse_errors
    | def values($key): [.body_lines[]? | select(startswith($key + ":")) | sub("^[^:]*:[[:space:]]*"; "")];
      def child($id):
        [$backlog.records[] | select(.structured and .id == $id)] as $r
        | {id:$id,state:(if ($r | length) == 1 then $r[0].state else "unknown" end)};
      [.records[] | select(.structured and .kind == "program" and .state == "in_flight")
       | . as $row
       | values("continuation") as $continuations
       | values("recheck-at") as $checks
       | values("children") as $children
       | values("agreement") as $agreements
       | ($continuations[0] // "active") as $continuation
       | ($checks[0] // null) as $check
       | (if $check == null then null else try ($check | fromdateiso8601) catch null end) as $at
       | ([if ($continuations | length) > 1 or (["active","paused"] | index($continuation)) == null then "invalid continuation" else empty end,
           if ($checks | length) > 1 or ($check != null and ($at == null or (try ($at | todateiso8601) catch "") != $check)) then "invalid recheck-at" else empty end,
           if ($children | length) > 1 or ($agreements | length) > 1 then "duplicate program field" else empty end,
           if ([$backlog.records[] | select(.structured and .id == $row.id)] | length) != 1 then "duplicate program id" else empty end]) as $errors
       | {id,repo,title,hold_kind,hold_reason,unresolved_blocker_ids,
          agreement:($agreements[0] // null),
          children:((($children[0] // "") | split(" ") | map(select(length > 0))) | map(child(.))),
          continuation:$continuation,recheck_at:$check,errors:$errors,
          supervision_needed:($continuation != "paused" or ($errors | length) > 0),
          due:(($errors | length) > 0 or ($continuation != "paused" and ($at == null or $at <= $now)))}] as $programs
    | {schema:"fm-programs.v1",path:$backlog.path,present:$backlog.present,
       programs:$programs,
       errors:($parse_errors + [$programs[] | select(.errors | length > 0) | {id,errors}]),
       supervision_needed:(($parse_errors | length) > 0 or any($programs[]; .supervision_needed))}'
}

fm_program_backlog_path() {
  # State overrides must never fall through to another homes real backlog.
  if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
    printf '%s/backlog.md\n' "$FM_DATA_OVERRIDE"
  elif [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    printf '%s/data/backlog.md\n' "$(dirname "$FM_STATE_OVERRIDE")"
  else
    printf '%s/data/backlog.md\n' "${FM_HOME:-$(dirname "$1")}"
  fi
}

fm_program_reconcile_tick() {
  local state=$1 now=${FM_PROGRAM_NOW_EPOCH:-$(date +%s)} interval=${FM_PROGRAM_RECHECK_SECS:-900}
  local snapshot due fingerprint prior last=0 stored='' queued tmp reason
  case "$interval" in ''|*[!0-9]*) interval=900 ;; esac
  [ "$interval" -ge 60 ] || interval=60
  local backlog
  backlog=$(fm_program_backlog_path "$state")
  snapshot=$(fm_programs_json "$backlog" "$now") || snapshot=
  if [ -z "$snapshot" ] || { [ -f "$state/.program-reconciliation" ] && [ ! -f "$backlog" ]; }; then
    snapshot='{"programs":[],"errors":[{"id":"backlog","errors":["program input unreadable"]}],"supervision_needed":true}'
  fi
  due=$(printf '%s' "$snapshot" | jq -r '[.programs[] | select(.due) | .id] | join(", ")') || return 1
  [ -n "$due" ] || {
    [ "$(printf '%s' "$snapshot" | jq '.errors | length')" -gt 0 ] || return 0
    due='unreadable program records'
  }
  # Include all program state so changes elsewhere in the portfolio trigger a
  # complete reconciliation, not only the most recently discussed project.
  fingerprint=$(printf '%s' "$snapshot" | cksum) || return 1
  prior="$state/.program-reconciliation"
  if [ -f "$prior" ] && [ ! -L "$prior" ]; then
    IFS=$(printf '\t') read -r last stored < "$prior" || true
  fi
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$stored" != "$fingerprint" ] || [ "$now" -lt "$last" ] || [ $((now - last)) -ge "$interval" ] || return 0
  queued=$(fm_wake_queued_keys check) || return 1
  case "
$queued
" in *"
program-reconcile
"*) return 0 ;; esac
  reason="check: program-reconcile: revisit all unfinished programs; due: $due. Reconcile scope, blockers, children and acceptance before dispatch; a child finishing is not product completion."
  fm_wake_append check program-reconcile "$reason" || return 1
  # Enqueue before suppression; a crash retains the event and may only retry it.
  tmp=$(mktemp "$state/.program-reconciliation.XXXXXX") || return 1
  if ! printf '%s\t%s\n' "$now" "$fingerprint" > "$tmp" || ! mv -f "$tmp" "$prior"; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s\n' "$reason"
}
