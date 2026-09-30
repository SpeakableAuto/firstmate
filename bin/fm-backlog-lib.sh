# shellcheck shell=bash
# Canonical read-only Markdown backlog parser, shared by fleet and program views.
# backlog_json [path] preserves all native records, bodies and dependency facts.
# Sourced by bin/fm-fleet-snapshot.sh (via bin/fm-programs-lib.sh) and
# bin/fm-programs-lib.sh; it reads SNAPSHOT_NOW, SNAPSHOT_TODAY and
# FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS when the caller pinned them.

backlog_json() {  # [<backlog-path>] - defaults to this home's $BACKLOG
  local backlog=${1:-${BACKLOG:-${FM_HOME:-.}/data/backlog.md}}
  # fm-fleet-snapshot.sh pins these clocks once per snapshot; other callers
  # (fm-programs-lib.sh) fall back to the current UTC time and default age.
  local now=${SNAPSHOT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  local today=${SNAPSHOT_TODAY:-${now%%T*}}
  local age_days=${FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS:-14}
  if [ ! -f "$backlog" ]; then
    jq -n --arg path "$backlog" '{path:$path,present:false,records:[]}'
    return 0
  fi

  # shellcheck disable=SC2094
  jq -Rn --arg path "$backlog" --arg today "$today" --arg now "$now" \
    --argjson age_days "$age_days" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def timestamp_epoch($d):
      if ($d | type) != "string" then null
      elif ($d | test("T")) then try ($d | fromdateiso8601) catch null
      else try (($d + "T00:00:00Z") | fromdateiso8601) catch null end;
    def days_between($from; $to):
      (timestamp_epoch($from)) as $a
      | (timestamp_epoch($to)) as $b
      | if $a == null or $b == null then null
        else (($b - $a) / 86400 | floor) end;
    def section_state:
      if . == "In flight" then "in_flight"
      elif . == "Queued" then "queued"
      elif . == "Done" then "done"
      else null end;
    def cap($rest; $re):
      (((($rest | capture($re)?) // {}) | .v) // null) as $v
      | if $v == null then null else ($v | trim) end;
    def metadata($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
    # LOAD-BEARING, do not remove as a duplicate definition of the kind field.
    # tasks-axi 0.2.5 omits the (kind: ...) metadata when a title starts with
    # uppercase SCOUT or SHIP at a JavaScript word boundary (ASCII letters,
    # digits, and underscore are word characters), so those rows carry no
    # explicit kind to read. Without this fallback a scout whose title starts
    # with SCOUT reports kind null, its
    # recorded report stops counting as a delivery, and it drops out of Recently
    # Landed - the defect this selector exists to fix. Pinned by
    # the producer word-boundary regression in tests/fm-bearings-snapshot.test.sh.
    def kind_of($rest):
      metadata($rest; "kind") as $kind
      | if $kind != null then $kind
        elif ($rest | test("^SCOUT(?![A-Za-z0-9_])")) then "scout"
        elif ($rest | test("^SHIP(?![A-Za-z0-9_])")) then "ship"
        else null end;
    def hold_metadata($rest):
      cap($rest; ".*\\(hold:[[:space:]]*(?<v>[^)]*)");
    def metadata_word($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + "[[:space:]]+(?<v>[^,)]*)");
    def url_pattern: "https?://[^[:space:])\"<>]+";
    def wrapped_url_pattern: "<?" + url_pattern + ">?";
    def links($rest): [$rest | scan(url_pattern)];
    def strip_trailing_metadata:
      reduce range(0; 20) as $_ (.;
        sub("[[:space:]]*\\([[:space:]]*(?:(?:repo|kind|priority|hold|hold-kind|hold-until):[[:space:]]*[^)]*|(?:since|merged|reported|done)[[:space:]]+[^)]*)[[:space:]]*\\)[[:space:]]*$"; ""));
    def strip_title_artifacts:
      sub("[[:space:]]+-[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+-[[:space:]]+local main$"; "")
      | sub("[[:space:]]+local main$"; "")
      | sub("[[:space:]]+-[[:space:]]*$"; "");
    def clean_title:
      strip_trailing_metadata
      | strip_title_artifacts
      | gsub("[[:space:]]+"; " ")
      | trim;
    def title_of($rest):
      $rest
      | gsub(wrapped_url_pattern; "")
      | sub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$"; "")
      | gsub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+"; "")
      | clean_title;
    def blocked_by_ids($rest):
      [ $rest | scan("blocked-by:[[:space:]]+(?<id>[^[:space:])]+)") | .[0] ]
      | reduce .[] as $id ([]; if index($id) == null then . + [$id] else . end);
    def blocked_reason($rest):
      cap($rest; ".*blocked-by:[[:space:]]*[^[:space:])]+[[:space:]]+-[[:space:]]*(?<v>.*)$") as $reason
      | if $reason == null then null
        else ($reason | clean_title | if . == "" then null else . end)
        end;
    def local_note($rest):
      cap(($rest | strip_trailing_metadata); ".*(?:^|[[:space:]]+-[[:space:]]+|[[:space:]])(?<v>local main)$");
    def completion($rest):
      (metadata_word($rest; "merged")) as $merged
      | (metadata_word($rest; "reported")) as $reported
      | (metadata_word($rest; "done")) as $done
      | if $merged != null then {verb:"merged",date:$merged}
        elif $reported != null then {verb:"reported",date:$reported}
        elif $done != null then {verb:"done",date:$done}
        else {verb:null,date:null} end;
    def row_match($line):
      (($line | capture("^[-*][[:space:]]+\\[(?<check>[ xX])\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")?) //
       (($line | capture("^[-*][[:space:]]+\\*\\*(?<id>[^*]+)\\*\\*[[:space:]]+-[[:space:]]+(?<rest>.*)$")?)
        | if . == null then null else . + {check:" "} end));
    def structured_row($line):
      ($line | test("^[-*][[:space:]]+\\[[ xX]\\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+"))
      or ($line | test("^[-*][[:space:]]+\\*\\*[^*]+\\*\\*[[:space:]]+-[[:space:]]+"));
    def parse_row($line; $section; $order):
      row_match($line) as $m
      | if $m == null then
          {order:$order,state:$section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}
        else
          ($m.rest) as $rest
          | {order:$order,
             state:$section,
             structured:true,
             id:($m.id | trim),
             checked:($m.check | test("[xX]")),
             title:title_of($rest),
             repo:metadata($rest; "repo"),
             kind:kind_of($rest),
             priority:metadata($rest; "priority"),
             hold_reason:hold_metadata($rest),
             hold_kind:metadata($rest; "hold-kind"),
             hold_until:metadata($rest; "hold-until"),
             hold_set:null,
             blocked_by:cap($rest; ".*blocked-by:[[:space:]]*(?<v>[^[:space:])]+).*"),
             blocked_by_ids:blocked_by_ids($rest),
             blocked_reason:blocked_reason($rest),
             since:metadata_word($rest; "since"),
             merged:metadata_word($rest; "merged"),
             reported:metadata_word($rest; "reported"),
             done:metadata_word($rest; "done"),
             completion:completion($rest),
             links:links($rest),
             pr_url:((links($rest) | map(select(test("/pull/[0-9]+"))) | .[0]) // null),
             report_path:cap($rest; ".*(?<v>data/[^[:space:])]+/report\\.md).*"),
             local_note:local_note($rest),
             raw:$line,
             body_lines:[],
             body_excerpt:null}
        end;
    reduce inputs as $line
      ({path:$path,present:true,records:[],section:null,order:0};
       if ($line | test("^##[[:space:]]+")) then
         .section = (($line | sub("^##[[:space:]]+";"") | trim) | section_state)
       elif .section == null or ($line | trim) == "" then
         .
       elif structured_row($line) then
         .order += 1
         | .records += [parse_row($line; .section; .order)]
       elif ((.records | length) > 0 and (.records[-1].structured == true) and ($line | test("^[[:space:]]+"))) then
         ($line | trim) as $body
         | if $body == "" then .
           else .records[-1].body_lines += [$body] end
       else
         .order += 1
         | .records += [{order:.order,state:.section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}]
       end)
    | .records |= map(
        if (.body_lines | length) > 0 then
          .hold_set = cap(.body_lines[0]; "^Captain hold set:[[:space:]]*(?<v>[0-9]{4}-[0-9]{2}-[0-9]{2}(?:T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?)$")
          | .local_note = (.local_note
              // (if any(.body_lines[];
                    test("^Resolution recorded by fm-(captain|decision)-hold\\.$"))
                  then null
                  else cap(.body_lines[-1]; "^(?<v>local main)$")
                  end))
          | .body_excerpt = ((.body_lines | join(" "))[:240])
        else . end)
    | .records as $records
    | (reduce ($records[] | select(.structured)) as $record ({};
         .[$record.id] = ((.[$record.id] // true) and ($record.state == "done")))) as $resolved_ids
    | .records |= map(
        if .structured then
          . as $record
          | .unresolved_blocker_ids = [
              $record.blocked_by_ids[] as $blocker
              | select($resolved_ids[$blocker] != true)
              | $blocker
            ]
          | .current_role =
              (if .state == "in_flight" and .hold_reason != null and .hold_kind != null then "held"
               elif .state == "in_flight" and .kind == "program" then "program"
               elif .state == "in_flight" then "worker"
               elif .state == "queued" then "queued"
               else "done" end)
          | .requires_child_metadata = (.current_role == "worker")
          | .hold_age_days = days_between((.hold_set // .since); $now)
          | .hold_bucket =
              (if .hold_kind != "captain" or .hold_reason == null or .state == "done" then null
               elif (.unresolved_blocker_ids | length) > 0 then "blocked"
               elif .hold_until != null and .hold_until > $today then "dated"
               elif .hold_until == null and .hold_age_days != null
                    and .hold_age_days >= $age_days then "aged"
               else "live" end)
          | .captain_actionable = (.hold_bucket == "live")
        else . end)
    | del(.section,.order)
  ' < "$backlog"
}
