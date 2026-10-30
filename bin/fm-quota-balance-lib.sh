# shellcheck shell=bash
# Quota balance spawn gate. Whenever config/crew-dispatch.json exists, a
# crewmate or scout spawn (fresh or relaunch) proceeds only when the requested
# profile is on the allowance the balanced pick names, so the balance rule is
# enforced at launch instead of resting on whoever chose the profile. Quota
# balance is the default; quota_balance only tunes its numbers.
# docs/configuration.md "Quota balance" owns the policy; bin/fm-dispatch-resolve.sh
# --rule ... --check owns the pick and records the placement's charge.
#
# fm_quota_balance_gate <id> <harness> <model> <effort> <project-path>
#   Returns 0 to proceed (no crew-dispatch.json, the balanced pick, a recorded
#   override, or no quota evidence for any candidate) and 1 to refuse, with
#   FM_QUOTA_BALANCE_REASON set. An unreadable or malformed crew-dispatch.json
#   refuses rather than skipping the gate.
#   FM_QUOTA_BALANCE_RECORD is the JSON evidence for the capacity decision, or
#   null when the gate does not apply.
# The rule comes from data/<id>/placement.json dispatch_rule, else the default
# profiles when they hold the requested profile, else the first rule that does.
# A profile in no rule is an explicit choice outside the rules (a captain
# override, a raw launch): it proceeds with that verdict recorded, and homes
# with crew placement still refuse it at the fit check. Unknown quota for every
# candidate is disclosed uncertainty, recorded as unverifiable, never a block.
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
  [ -e "$rules" ] || [ -L "$rules" ] || return 0
  if ! jq -e 'type == "object"' "$rules" >/dev/null 2>&1; then
    FM_QUOTA_BALANCE_REASON="quota balance: $rules is unreadable or malformed; fix it before starting crew"
    FM_QUOTA_BALANCE_RECORD=$(jq -cn --arg reason "$FM_QUOTA_BALANCE_REASON" '{verdict: "refused", reason: $reason}')
    return 1
  fi
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
    FM_QUOTA_BALANCE_RECORD=$(jq -cn --arg override "$override" --arg profile "$harness:${model:-default}:${effort:-default}" \
      '{verdict: "outside-rules", reason: "\($profile) is in no dispatch rule, so no balanced pick applies"}
       + (if $override == "" then {} else {override: $override} end)')
    echo "quota balance: $harness:${model:-default} is in no dispatch rule; starting it as an explicit choice outside the rules" >&2
    return 0
  fi
  [ -r "$brief" ] || brief=/dev/null
  [ -z "$override" ] || extra=(--override "$override")
  out=$(env -u TYPESAFE_API_KEY FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-dispatch-resolve.sh" --rule "$rule" --check "$harness" "$model" "$effort" ${extra[@]+"${extra[@]}"} \
    "$brief" --project "$(basename "$project")" 2>/dev/null | tail -1)
  verdict=$(printf '%s\n' "$out" | jq -r '.check.verdict // empty' 2>/dev/null) || verdict=''
  # No candidate with quota evidence (or no quota read at all) cannot be balanced.
  if [ "$verdict" != balanced ] && [ "$verdict" != override ] && printf '%s\n' "$out" | jq -e '
      .status == "error"
      or ((.check.requested.eligible // false) and (.check.requested.unranked // false)
          and ([.candidates[]? | select(.eligible and ((.unranked // false) | not))] | length) == 0)' >/dev/null 2>&1; then
    verdict=unverifiable
  fi
  FM_QUOTA_BALANCE_RECORD=$(printf '%s\n' "$out" | jq -c --arg rule "$rule" '
    def who($c): if $c == null then null else
      {home: $c.home, harness: $c.profile.harness, model: ($c.profile.model // ""), provider: $c.provider,
       account: $c.account, headroom: ($c.headroom // null)} end;
    {verdict: .check.verdict, rule: $rule, reason: (.check.reason // .reason // null), override: (.check.override // null),
     requested: who(.check.requested), pick: who(.check.pick // .chosen),
     spread: (.spread // .global_spread // null | if . == null then null else {top: .top.label, bottom: .bottom.label, points, alarm} end)}
  ' 2>/dev/null) || FM_QUOTA_BALANCE_RECORD=null
  case "$verdict" in
    balanced) return 0 ;;
    unverifiable)
      FM_QUOTA_BALANCE_RECORD=$(printf '%s\n' "$FM_QUOTA_BALANCE_RECORD" | jq -c '.verdict = "unverifiable"' 2>/dev/null) \
        || FM_QUOTA_BALANCE_RECORD='{"verdict":"unverifiable"}'
      echo "quota balance: no candidate has quota evidence; starting $id without a balanced pick (recorded)" >&2
      return 0 ;;
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
