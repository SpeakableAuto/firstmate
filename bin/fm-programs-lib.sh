# shellcheck shell=bash
# Accepted delivery continuation, derived only from the native backlog.
# fm_programs_json <backlog> [epoch] [receipt] is read-only and never queries workers.
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
# only a content fingerprint, emission time and observed unfinished ids in
# state/.program-reconciliation as epoch<TAB>fingerprint-or-unemitted<TAB>JSON ids.
# Unacknowledged events suppress duplicates; unchanged content retries after
# FM_PROGRAM_RECHECK_SECS (default 900, minimum 60), even with no live workers.
# Runtime receipts are disposable; accepted work remains solely in backlog.md.
# Current valid programs remain discoverable after receipt loss, but missing or
# retagged historical program identities cannot be reconstructed after deletion.
# FM_PROGRAM_NOW_EPOCH is an optional deterministic clock for isolated fixtures.

# shellcheck source=bin/fm-backlog-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-backlog-lib.sh"

fm_programs_json() {
  local backlog=$1 now=${2:-${FM_PROGRAM_NOW_EPOCH:-$(date +%s)}} receipt=${3:-}
  local raw observed='[]' receipt_observed
  case "$now" in ''|*[!0-9]*) return 2 ;; esac
  if [ -e "$backlog" ]; then
    [ -f "$backlog" ] && [ -r "$backlog" ] || return 1
  fi
  raw=$(backlog_json "$backlog") || return 1
  if [ -n "$receipt" ] && [ -f "$receipt" ] && [ ! -L "$receipt" ]; then
    IFS=$(printf '\t') read -r _ _ receipt_observed < "$receipt" || true
    if printf '%s' "$receipt_observed" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
      observed=$receipt_observed
    fi
  fi
  printf '%s' "$raw" | jq --argjson now "$now" --argjson observed "$observed" '
    . as $backlog
    | [.records[] | select((.structured | not) and (.state == "in_flight" or .state == "queued")
        and (.raw | test("kind:[[:space:]]*program")))
        | {id:"unparseable-program",errors:["malformed program backlog row"]}] as $parse_errors
    | def values($key): [.body_lines[]? | select(startswith($key + ":")) | sub("^[^:]*:[[:space:]]*"; "")];
      def child($id):
        [$backlog.records[] | select(.structured and .id == $id)] as $r
        | {id:$id,state:(if ($r | length) == 1 then $r[0].state else "unknown" end)};
      [$observed[] as $id
       | [.records[] | select(.structured and .id == $id)] as $matches
       | select(($matches | length) != 1
                or (($matches[0].kind == "program"
                     and ($matches[0].state == "done" or $matches[0].state == "in_flight")) | not))
       | {id:$id,errors:["previously observed unfinished program no longer has one valid current or completed kind=program record"]}] as $continuity_errors
    | [$observed[] as $id
       | [.records[] | select(.structured and .id == $id)] as $matches
       | select(($matches | length) != 1 or $matches[0].state != "done" or $matches[0].kind != "program")
       | $id] as $retained_observed
    | [.records[] | select(.structured and .kind == "program" and .state == "in_flight")
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
       observed_unfinished_program_ids:($retained_observed + [$programs[].id] | unique),
       errors:($parse_errors + $continuity_errors + [$programs[] | select(.errors | length > 0) | {id,errors}]),
       supervision_needed:(($parse_errors | length) > 0 or ($continuity_errors | length) > 0 or any($programs[]; .supervision_needed))}'
}

fm_program_backlog_path() {
  if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
    printf '%s/backlog.md\n' "$FM_DATA_OVERRIDE"
  else
    printf '%s/data/backlog.md\n' "${FM_HOME:-$(dirname "$1")}"
  fi
}

fm_program_receipt_write() {
  local prior=$1 emitted=$2 fingerprint=$3 observed=$4 tmp
  tmp=$(mktemp "$(dirname "$prior")/.program-reconciliation.XXXXXX") || return 1
  if ! printf '%s\t%s\t%s\n' "$emitted" "$fingerprint" "$observed" > "$tmp" || ! mv -f "$tmp" "$prior"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_program_reconcile_tick() {
  local state=$1 now=${FM_PROGRAM_NOW_EPOCH:-$(date +%s)} interval=${FM_PROGRAM_RECHECK_SECS:-900}
  local snapshot due fingerprint prior last=0 stored='unemitted' recorded='[]' observed queued reason
  case "$interval" in ''|*[!0-9]*) interval=900 ;; esac
  [ "$interval" -ge 60 ] || interval=60
  local backlog
  backlog=$(fm_program_backlog_path "$state")
  prior="$state/.program-reconciliation"
  if [ -f "$prior" ] && [ ! -L "$prior" ]; then
    IFS=$(printf '\t') read -r last stored recorded < "$prior" || true
    if ! printf '%s' "$recorded" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
      recorded='[]'
    fi
  fi
  snapshot=$(fm_programs_json "$backlog" "$now" "$prior") || snapshot=
  if [ -z "$snapshot" ] || { [ -f "$prior" ] && [ ! -f "$backlog" ]; }; then
    snapshot=$(jq -n --argjson observed "$recorded" '{programs:[],observed_unfinished_program_ids:$observed,errors:[{id:"backlog",errors:["program input unreadable"]}],supervision_needed:true}')
  fi
  observed=$(printf '%s' "$snapshot" | jq -c '.observed_unfinished_program_ids // []') || return 1
  due=$(printf '%s' "$snapshot" | jq -r '[.programs[] | select(.due) | .id] | join(", ")') || return 1
  [ -n "$due" ] || {
    if [ "$(printf '%s' "$snapshot" | jq '.errors | length')" -eq 0 ]; then
      if [ "$observed" != "$recorded" ]; then
        if [ "$observed" = '[]' ]; then
          rm -f "$prior"
        else
          fm_program_receipt_write "$prior" "$last" "$stored" "$observed" || return 1
        fi
      fi
      return 0
    fi
    due='unreadable program records'
  }
  # Include all program state so changes elsewhere in the portfolio trigger a
  # complete reconciliation, not only the most recently discussed project.
  fingerprint=$(printf '%s' "$snapshot" | cksum) || return 1
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$stored" != "$fingerprint" ] || [ "$now" -lt "$last" ] || [ $((now - last)) -ge "$interval" ] || return 0
  queued=$(fm_wake_queued_keys check) || return 1
  case "
$queued
" in *"
program-reconcile
"*) return 0 ;; esac
  reason="check: program-reconcile: revisit due programs and surfaced program errors; due: $due. Reconcile scope, blockers, children and acceptance before dispatch; a child finishing is not product completion."
  fm_wake_append check program-reconcile "$reason" || return 1
  fm_program_receipt_write "$prior" "$now" "$fingerprint" "$observed" || return 1
  printf '%s\n' "$reason"
}
