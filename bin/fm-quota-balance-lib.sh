# shellcheck shell=bash
# Quota balance spawn gate. Whenever config/crew-dispatch.json exists, a
# crewmate or scout spawn (fresh or relaunch) proceeds only when the requested
# profile is on the allowance the balanced pick names, so the balance rule is
# enforced at launch instead of resting on whoever chose the profile. Quota
# balance is the default with a fixed 10% reserve and 20-point spread.
# docs/configuration.md "Quota balance" owns the policy; bin/fm-dispatch-resolve.sh
# --rule ... --check owns the pick and records the placement's charge.
#
# fm_quota_balance_gate <id> <harness> <model> <effort> <project-path>
#   Returns 0 to proceed (no crew-dispatch.json, the balanced pick, a recorded
#   override, or disclosed quota uncertainty) and 1 to refuse, with
#   FM_QUOTA_BALANCE_REASON set. An unreadable or malformed crew-dispatch.json
#   refuses rather than skipping the gate.
#   FM_QUOTA_BALANCE_RECORD is the JSON evidence for the capacity decision, or
#   null when the gate does not apply.
# The rule comes from data/<id>/placement.json dispatch_rule, else the default
# profiles when they hold the requested profile, else the first rule that does.
# A profile in no rule refuses without a non-empty placement.json
# balance_override; with one, it proceeds only when its allowance can be mapped.
# Unknown quota for every candidate is disclosed uncertainty, recorded and
# alerted once per open episode; a recent successful reading can still refuse a
# known-behind account. An override states why the task class needs this profile,
# and the decision keeps it.
# Needs SCRIPT_DIR, FM_HOME, CONFIG, DATA, and STATE from the sourcing caller.

# Remote transfer: the resolver emits parent_placement for a remote pick.
# Carry that object unchanged into the receiving data/<id>/placement.json.
# It binds version=1, at (15-minute lifetime), task, brief_sha256, target
# (.fm-secondmate-home), provider, account and profile. It authorizes the pool
# choice, not a reserve/capacity exception. An invalid supplied record refuses.
# A sixth argument "preflight" returns charge evidence without writing a
# charge; fm_quota_balance_charge commits it only after a successful launch.

fm_quota_balance_episode_clear() {
  rm -f "$STATE/quota-balance-unverifiable.open"
}

fm_quota_balance_wake_append() {
  # shellcheck disable=SC2016 # The child Bash expands its positional parameters.
  env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" bash -c '
    wake_lib=$1
    shift
    . "$wake_lib"
    fm_wake_append "$@"
  ' fm-quota-balance-wake "$SCRIPT_DIR/fm-wake-lib.sh" "$@"
}

fm_quota_balance_unverifiable() { # <id> <harness> <model> <reason>
  local id=$1 harness=$2 model=$3 reason=$4 at open
  at=$(date +%s)
  open="$STATE/quota-balance-unverifiable.open"
  mkdir -p "$STATE" || return 0
  if [ ! -e "$CONFIG/crew-placement.json" ] && [ ! -L "$CONFIG/crew-placement.json" ]; then
    jq -cn --argjson at "$at" --arg task "$id" --arg harness "$harness" --arg model "$model" --arg reason "$reason" \
      '{at: $at, task: $task, harness: $harness, model: $model, reason: $reason}' \
      >> "$STATE/quota-balance-unverifiable.jsonl" 2>/dev/null || true
  fi
  if (set -C; : > "$open") 2>/dev/null; then
    if ! fm_quota_balance_wake_append check "quota-balance-unverifiable-$at" \
      "check: quota-balance-unverifiable: crew starts are proceeding without a balanced pick ($reason)"; then
      rm -f "$open"
    fi
  fi
}

fm_quota_balance_last_refusal() { # <resolver-output> <rule> <harness> <model>
  local out=$1 rule=$2 harness=$3 model=$4 file provider account now result
  file="$STATE/quota-balance-last.json"
  [ -r "$file" ] && [ ! -L "$file" ] || return 1
  now=$(date +%s)
  provider=$(printf '%s\n' "$out" | jq -r '.check.requested.provider // empty' 2>/dev/null) || provider=''
  account=$(printf '%s\n' "$out" | jq -r '.check.requested.account // empty' 2>/dev/null) || account=''
  if [ -z "$provider" ]; then
    provider=$(jq -r --arg rule "$rule" --arg h "$harness" --arg m "$model" '
      def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
      (if $rule == "default" then profiles(.default // null)
       elif ($rule | test("^rule_[1-9][0-9]*$")) then profiles(.rules[(($rule | ltrimstr("rule_") | tonumber) - 1)].use)
       else [] end)
      | map(select(.harness == $h and (.model // "") == $m)) | first | .provider // empty
    ' "$CONFIG/crew-dispatch.json" 2>/dev/null) || provider=''
  fi
  if [ -z "$provider" ] && [ "$(type -t fm_quota_single_provider_for_harness)" = function ]; then
    provider=$(fm_quota_single_provider_for_harness "$harness" 2>/dev/null) || provider=''
  fi
  [ -n "$provider" ] || return 1
  result=$(jq -r --argjson now "$now" --arg provider "$provider" --arg account "$account" '
    select((.at | type) == "number" and $now - .at >= 0 and $now - .at < 900 and (.accounts | type) == "array") |
    [.accounts[] | select(.home == "local" and .provider == $provider)] as $provider_accounts |
    (if $account != "" then [$provider_accounts[] | select((.account // "") == $account)]
     elif ($provider_accounts | length) == 1 then $provider_accounts else [] end) as $requested |
    select(($requested | length) == 1 and ([.accounts[].headroom | select(type == "number")] | length) > 0) |
    ($requested[0]) as $req | (.accounts | max_by(.headroom)) as $full |
    (((($full.headroom - $req.headroom) * 100) | round) / 100) as $points |
    select($points > 20) |
    [$points, ($req.label // $req.provider), ($full.label // $full.provider), .at] | @tsv
  ' "$file" 2>/dev/null) || return 1
  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

fm_quota_balance_mapped_charge() { # <id> <harness> <model> <rules>
  local id=$1 harness=$2 model=$3 rules=$4 provider
  provider=$(jq -r --arg h "$harness" --arg m "$model" '
    [(.default // []), (.rules[]?.use)] | flatten
    | map(select(.harness == $h and (.model // "") == $m)) | first | .provider // empty
  ' "$rules" 2>/dev/null) || provider=''
  if [ -z "$provider" ]; then
    if [ "$(type -t fm_quota_single_provider_for_harness)" != function ]; then
      # shellcheck source=bin/fm-quota-axi-lib.sh
      . "$SCRIPT_DIR/fm-quota-axi-lib.sh"
    fi
    provider=$(fm_quota_single_provider_for_harness "$harness" 2>/dev/null) || provider=''
  fi
  [ -n "$provider" ] || return 1
  FM_QUOTA_BALANCE_CHARGE=$(jq -cn --arg key "$id" --arg p "$provider" --arg m "$model" --argjson at "$(date +%s)" \
    '{key:$key,at:$at,home:"local",provider:$p,account:"",model:$m,scopes:["all_models"],claude:($p=="claude"),draw:5,span:900}')
}

fm_quota_balance_gate() {
  local id=$1 harness=$2 model=$3 effort=$4 project=$5
  # shellcheck disable=SC2153 # DATA is supplied by the sourcing caller.
  local rules="$CONFIG/crew-dispatch.json" work="$DATA/$1/placement.json" brief="$DATA/$1/brief.md"
  local rule='' override='' inferred=0 out verdict local_reason last points requested fuller seen
  local -a extra=()
  FM_QUOTA_BALANCE_REASON=''
  FM_QUOTA_BALANCE_RECORD=null
  [ -e "$rules" ] || [ -L "$rules" ] || return 0
  if ! jq -e 'type == "object"' "$rules" >/dev/null 2>&1; then
    FM_QUOTA_BALANCE_REASON="quota balance: $rules is unreadable or malformed; fix it before starting crew"
    FM_QUOTA_BALANCE_RECORD=$(jq -cn --arg reason "$FM_QUOTA_BALANCE_REASON" '{verdict: "refused", reason: $reason}')
    fm_quota_balance_episode_clear
    return 1
  fi
  if [ -f "$work" ]; then
    if ! jq -e 'type == "object" and (has("dispatch_rule") | not) or
      (type == "object" and (.dispatch_rule|type)=="number" and .dispatch_rule>=0 and .dispatch_rule==(.dispatch_rule|floor))' "$work" >/dev/null 2>&1; then
      FM_QUOTA_BALANCE_REASON='quota balance: invalid placement classification; dispatch_rule must be a nonnegative integer'
      return 1
    fi
    rule=$(jq -r 'if (.dispatch_rule | type) == "number" and .dispatch_rule >= 0 then "rule_\(.dispatch_rule + 1)" else empty end' "$work" 2>/dev/null) || rule=''
    override=$(jq -r '.balance_override // empty | strings' "$work" 2>/dev/null) || override=''
  fi
  if [ -z "$rule" ]; then
    inferred=1
    rule=$(jq -r --arg h "$harness" --arg m "$model" --arg e "$effort" '
      def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
      def holds($v): any(profiles($v)[]; .harness == $h and (.model // "") == $m and (.effort // "") == $e);
      if holds(.default // null) then "default"
      else ([(.rules // []) | to_entries[] | select(holds(.value.use)) | "rule_\(.key + 1)"] | first // empty) end
    ' "$rules" 2>/dev/null) || rule=''
  fi
  if [ -z "$rule" ]; then
    if [ -z "$override" ]; then
      FM_QUOTA_BALANCE_REASON="quota balance: $harness:${model:-default} is in no dispatch rule; record balance_override in data/$id/placement.json stating why the task class needs it"
      FM_QUOTA_BALANCE_RECORD=$(jq -cn --arg reason "$FM_QUOTA_BALANCE_REASON" '{verdict: "refused", reason: $reason}')
      fm_quota_balance_episode_clear
      return 1
    fi
    local charge
    if ! fm_quota_balance_mapped_charge "$id" "$harness" "$model" "$rules"; then
      FM_QUOTA_BALANCE_REASON="quota balance: $harness:${model:-default} is in no dispatch rule and its override allowance cannot be mapped"
      FM_QUOTA_BALANCE_RECORD=$(jq -cn --arg reason "$FM_QUOTA_BALANCE_REASON" '{verdict: "refused", reason: $reason}')
      fm_quota_balance_episode_clear
      return 1
    fi
    charge=$FM_QUOTA_BALANCE_CHARGE
    FM_QUOTA_BALANCE_RECORD=$(jq -cn --arg override "$override" --argjson charge "$charge" \
      '{verdict: "override", reason: "profile is in no dispatch rule", override: $override, charge: $charge}')
    [ "${6:-charge}" = preflight ] || fm_quota_balance_charge || return 1
    echo "quota balance: override recorded for $id: $override" >&2
    return 0
  fi
  [ -r "$brief" ] || brief=/dev/null
  [ -z "$override" ] || extra=(--override "$override")
  [ "$inferred" = 0 ] || extra+=(--global-check)
  if jq -e 'has("parent_placement")' "$work" >/dev/null 2>&1; then
    local parent target brief_hash
    target=$(cat "$FM_HOME/.fm-secondmate-home" 2>/dev/null || true)
    brief_hash=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$brief") || return 1
    parent=$(jq -ce --arg target "$target" --arg hash "$brief_hash" --arg id "$id" \
      --arg h "$harness" --arg m "$model" --arg e "$effort" --argjson now "$(date +%s)" '
      .parent_placement | select(.version == 1 and .task == $id and .target == $target and $target != ""
        and .brief_sha256 == $hash and (.at|type)=="number" and $now-.at >= 0 and $now-.at < 900
        and .profile.harness == $h and (.profile.model // "") == $m and (.profile.effort // "") == $e
        and (.provider|type)=="string" and (.account|type)=="string")' "$work") || {
      FM_QUOTA_BALANCE_REASON='quota balance: parent placement is invalid, expired, or does not match this task, machine and profile'
      return 1
    }
    extra+=(--parent-placement "$parent")
  fi
  if [ -n "$override" ] && jq -e '.impact == "P0"' "$work" >/dev/null 2>&1; then extra+=(--p0); fi
  [ "${6:-charge}" != preflight ] || extra+=(--no-charge)
  out=$(env -u TYPESAFE_API_KEY FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-dispatch-resolve.sh" --rule "$rule" --check "$harness" "$model" "$effort" ${extra[@]+"${extra[@]}"} \
    "$brief" --project "$(basename "$project")" 2>/dev/null | tail -1)
  verdict=$(printf '%s\n' "$out" | jq -r '.check.verdict // empty' 2>/dev/null) || verdict=''
  # No candidate with quota evidence (or no quota read at all) cannot be balanced.
  if [ "$verdict" != balanced ] && [ "$verdict" != override ] && printf '%s\n' "$out" | jq -e '
      .error_kind == "quota_unavailable"
      or ((.check.requested.eligible // false) and (.check.requested.unranked // false)
          and ([.candidates[]? | select(.eligible and ((.unranked // false) | not))] | length) == 0)' >/dev/null 2>&1; then
    verdict=unverifiable
  fi
  FM_QUOTA_BALANCE_RECORD=$(printf '%s\n' "$out" | jq -c --arg rule "$rule" '
    def who($c): if $c == null then null else
      {home: $c.home, harness: $c.profile.harness, model: ($c.profile.model // ""), provider: $c.provider,
       account: $c.account, headroom: ($c.headroom // null)} end;
    {charge: (.check.charge // null), verdict: .check.verdict, rule: $rule, reason: (.check.reason // .reason // null), override: (.check.override // null),
     requested: who(.check.requested), pick: who(.check.pick // .chosen),
     spread: (.spread // .global_spread // null | if . == null then null else {top: .top.label, bottom: .bottom.label, points, alarm} end)}
  ' 2>/dev/null) || FM_QUOTA_BALANCE_RECORD=null
  case "$verdict" in
    balanced)
      fm_quota_balance_episode_clear
      return 0 ;;
    unverifiable)
      FM_QUOTA_BALANCE_RECORD=$(printf '%s\n' "$FM_QUOTA_BALANCE_RECORD" | jq -c '.verdict = "unverifiable"' 2>/dev/null) \
        || FM_QUOTA_BALANCE_RECORD='{"verdict":"unverifiable"}'
      local_reason=$(printf '%s\n' "$FM_QUOTA_BALANCE_RECORD" | jq -r '.reason // "no candidate has quota evidence"' 2>/dev/null) \
        || local_reason='no candidate has quota evidence'
      if [ -z "$override" ] && last=$(fm_quota_balance_last_refusal "$out" "$rule" "$harness" "$model"); then
        IFS=$'\t' read -r points requested fuller seen <<< "$last"
        FM_QUOTA_BALANCE_REASON="quota balance: last known reading at $seen shows $requested is $points points behind $fuller; refusing an unverifiable start"
        FM_QUOTA_BALANCE_RECORD=$(jq -cn --arg rule "$rule" --arg reason "$FM_QUOTA_BALANCE_REASON" \
          '{verdict: "refused", rule: $rule, reason: $reason}')
        fm_quota_balance_episode_clear
        return 1
      fi
      if [ -n "$override" ]; then
        local charge
        if ! fm_quota_balance_mapped_charge "$id" "$harness" "$model" "$rules"; then
          FM_QUOTA_BALANCE_REASON='quota balance: override allowance cannot be mapped while quota is unavailable'
          return 1
        fi
        charge=$FM_QUOTA_BALANCE_CHARGE
        FM_QUOTA_BALANCE_RECORD=$(jq -c --argjson charge "$charge" --arg override "$override" '. + {charge:$charge,override:$override}' <<<"$FM_QUOTA_BALANCE_RECORD")
        [ "${6:-charge}" = preflight ] || fm_quota_balance_charge || return 1
      fi
      fm_quota_balance_unverifiable "$id" "$harness" "$model" "$local_reason"
      echo "quota balance: $local_reason; starting $id without a balanced pick (recorded)" >&2
      return 0 ;;
    override)
      if jq -e '.impact == "P0"' "$work" >/dev/null 2>&1 && (set -C; : > "$STATE/quota-p0-$id.open") 2>/dev/null; then
        fm_quota_balance_wake_append check "quota-p0-$id" "check: quota-p0: $id may use the reserve down to the hard 5% floor" || true
      fi
      echo "quota balance: override recorded for $id: $override" >&2
      return 0 ;;
    refused)
      FM_QUOTA_BALANCE_REASON="quota balance: $(printf '%s\n' "$out" | jq -r '.check.reason')" ;;
    *)
      FM_QUOTA_BALANCE_REASON="quota balance: the balanced pick could not be established ($(printf '%s\n' "$out" | jq -r '.reason // "resolver gave no verdict"' 2>/dev/null || printf 'resolver gave no verdict'))"
      [ "$FM_QUOTA_BALANCE_RECORD" != null ] \
        || FM_QUOTA_BALANCE_RECORD=$(jq -cn --arg reason "$FM_QUOTA_BALANCE_REASON" '{verdict: "unknown", reason: $reason}') ;;
  esac
  fm_quota_balance_episode_clear
  return 1
}

# Commit only after launch succeeds; failed admission/provisioning owes no draw.
fm_quota_balance_charge() {
  local record=${FM_QUOTA_BALANCE_RECORD:-null} charge
  charge=$(jq -c '.charge // null' <<<"$record") || return 1
  [ "$charge" != null ] || return 0
  printf '%s\n' "$charge" | python3 "$SCRIPT_DIR/fm-quota-burn.py" charge "$STATE"
}

# Shared read-only pool evidence, also attached to remote quota snapshots.
fm_quota_balance_machine_state() { # <config> <state> [exclude-id]
  local count=-1
  if fm_live_workers_count "$2" "${3:-}" >/dev/null 2>&1; then count=$FM_LIVE_WORKERS_COUNT; fi
  python3 "$SCRIPT_DIR/fm-placement.py" pool "$1" "$count"
}
