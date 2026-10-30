# shellcheck shell=bash
# Quota balance spawn gate. With quota_balance in config/crew-dispatch.json, a
# crewmate or scout spawn (fresh or relaunch) proceeds only when the requested
# profile is on the allowance the balanced pick names, so the balance rule is
# enforced at launch instead of resting on whoever chose the profile.
# docs/configuration.md "Quota balance" owns the policy; bin/fm-dispatch-resolve.sh
# --rule ... --check owns the pick and records the placement's charge.
#
# fm_quota_balance_gate <id> <harness> <model> <effort> <project-path>
#   Returns 0 to proceed (no quota_balance configured, the balanced pick, or a
#   recorded override) and 1 to refuse, with FM_QUOTA_BALANCE_REASON set.
#   FM_QUOTA_BALANCE_RECORD is the JSON evidence for the capacity decision, or
#   null when the gate does not apply.
# The rule comes from data/<id>/placement.json dispatch_rule, else the default
# profiles when they hold the requested profile, else the first rule that does.
# A non-empty placement.json balance_override is the only way past a refusal:
# it states why the task class needs this profile, and the decision keeps it.
# Needs SCRIPT_DIR, FM_HOME, CONFIG, DATA, and STATE from the sourcing caller.

fm_quota_balance_gate() {
  local id=$1 harness=$2 model=$3 effort=$4 project=$5
  local rules="$CONFIG/crew-dispatch.json" work="$DATA/$1/placement.json" brief="$DATA/$1/brief.md"
  local rule='' override='' out verdict
  local -a extra=()
  FM_QUOTA_BALANCE_REASON=''
  FM_QUOTA_BALANCE_RECORD=null
  [ -f "$rules" ] || return 0
  jq -e 'type == "object" and has("quota_balance")' "$rules" >/dev/null 2>&1 || return 0
  if [ -f "$work" ]; then
    rule=$(jq -r 'if (.dispatch_rule | type) == "number" and .dispatch_rule >= 0 then "rule_\(.dispatch_rule + 1)" else empty end' "$work" 2>/dev/null) || rule=''
    override=$(jq -r '.balance_override // empty | strings' "$work" 2>/dev/null) || override=''
  fi
  if [ -z "$rule" ]; then
    rule=$(jq -r --arg h "$harness" --arg m "$model" --arg e "$effort" '
      def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
      def holds($v): any(profiles($v)[]; .harness == $h and (.model // "") == $m and (.effort // "") == $e);
      if holds(.default // null) then "default"
      else ([(.rules // []) | to_entries[] | select(holds(.value.use)) | "rule_\(.key + 1)"] | first // empty) end
    ' "$rules" 2>/dev/null) || rule=''
  fi
  if [ -z "$rule" ]; then
    if [ -n "$override" ]; then
      FM_QUOTA_BALANCE_RECORD=$(jq -cn --arg override "$override" '{verdict: "override", reason: "profile is in no dispatch rule", override: $override}')
      return 0
    fi
    FM_QUOTA_BALANCE_REASON="quota balance: $harness:${model:-default} is in no dispatch rule, so it cannot be the balanced pick; record balance_override in placement.json only when the task class needs it"
    FM_QUOTA_BALANCE_RECORD=$(jq -cn --arg reason "$FM_QUOTA_BALANCE_REASON" '{verdict: "refused", reason: $reason}')
    return 1
  fi
  [ -r "$brief" ] || brief=/dev/null
  [ -z "$override" ] || extra=(--override "$override")
  out=$(env -u TYPESAFE_API_KEY FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-dispatch-resolve.sh" --rule "$rule" --check "$harness" "$model" "$effort" ${extra[@]+"${extra[@]}"} \
    "$brief" --project "$(basename "$project")" 2>/dev/null | tail -1)
  verdict=$(printf '%s\n' "$out" | jq -r '.check.verdict // empty' 2>/dev/null) || verdict=''
  FM_QUOTA_BALANCE_RECORD=$(printf '%s\n' "$out" | jq -c --arg rule "$rule" '
    def who($c): if $c == null then null else
      {home: $c.home, harness: $c.profile.harness, model: ($c.profile.model // ""), provider: $c.provider,
       account: $c.account, headroom: ($c.headroom // null)} end;
    {verdict: .check.verdict, rule: $rule, reason: (.check.reason // null), override: (.check.override // null),
     requested: who(.check.requested), pick: who(.check.pick // .chosen),
     spread: (.spread // .global_spread // null | if . == null then null else {top: .top.label, bottom: .bottom.label, points, alarm} end)}
  ' 2>/dev/null) || FM_QUOTA_BALANCE_RECORD=null
  case "$verdict" in
    balanced) return 0 ;;
    override)
      echo "quota balance: override recorded for $id: $override" >&2
      return 0 ;;
    refused)
      FM_QUOTA_BALANCE_REASON="quota balance: $(printf '%s\n' "$out" | jq -r '.check.reason')" ;;
    *)
      FM_QUOTA_BALANCE_REASON="quota balance: the balanced pick could not be established ($(printf '%s\n' "$out" | jq -r '.reason // "resolver gave no verdict"' 2>/dev/null || printf 'resolver gave no verdict'))"
      [ "$FM_QUOTA_BALANCE_RECORD" != null ] \
        || FM_QUOTA_BALANCE_RECORD=$(jq -cn --arg reason "$FM_QUOTA_BALANCE_REASON" '{verdict: "unknown", reason: $reason}') ;;
  esac
  return 1
}
