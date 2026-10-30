#!/usr/bin/env bash
# Behavior tests for the quota balance spawn gate (bin/fm-quota-balance-lib.sh)
# and the measured-draw tool (bin/fm-quota-burn.py), plus one real fm-spawn run
# proving a non-balanced crew is refused before anything is provisioned and the
# balanced one launches. A fake quota-axi serves each fixture; nothing reaches
# a vendor or the network.
set -u
unset TYPESAFE_API_KEY

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-balance)
QUOTA_FIXTURE="$TMP_ROOT/quota.json"
export QUOTA_FIXTURE

balance_rules() {  # <config-dir>
  cat > "$1/crew-dispatch.json" <<'JSON'
{
  "quota_balance": { "reserve_percent": 10, "spread_points": 20 },
  "rules": [
    { "when": "Hard engineering.",
      "use": [ { "harness": "codex", "model": "gpt-6-astra", "effort": "high" },
               { "harness": "claude", "model": "opus", "effort": "high" } ] }
  ],
  "default": [ { "harness": "codex", "model": "gpt-6-sol", "effort": "high" },
               { "harness": "claude", "model": "sonnet", "effort": "high" } ]
}
JSON
}

write_quota() {  # <claude headroom> <codex headroom>
  cat > "$QUOTA_FIXTURE" <<JSON
{ "schemaVersion": 5, "providers": [
  { "provider": "claude", "state": { "status": "fresh", "stale": false },
    "windows": [ { "id": "five_hour", "kind": "session", "percentRemaining": 70 } ],
    "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 70,
        "pace": { "worstReservePercentPoints": $1 }, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": 0.1 } } ] } },
  { "provider": "codex", "state": { "status": "fresh", "stale": false },
    "windows": [ { "id": "weekly", "kind": "weekly", "percentRemaining": 60 } ],
    "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 60,
        "pace": { "worstReservePercentPoints": $2 }, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": 0.9 } } ] } } ] }
JSON
}

fake_quota_axi() {  # <fakebin>
  cat > "$1/quota-axi" <<'SH'
#!/usr/bin/env bash
cat "${QUOTA_FIXTURE:?}"
SH
  chmod +x "$1/quota-axi"
}

# --- the gate, through its sourced function -----------------------------------
GATE_HOME="$TMP_ROOT/gate"
GATE_BIN=$(fm_fakebin "$TMP_ROOT/gate-fake")
fake_quota_axi "$GATE_BIN"
mkdir -p "$GATE_HOME/config" "$GATE_HOME/data/t1" "$GATE_HOME/state"
printf '# Task\n' > "$GATE_HOME/data/t1/brief.md"

gate() {  # <harness> <model> <effort>; prints "<rc>|<reason>|<record>"
  ( PATH="$GATE_BIN:$PATH"
    # shellcheck disable=SC2034  # read by the sourced gate library
    SCRIPT_DIR="$ROOT/bin" FM_HOME="$GATE_HOME" CONFIG="$GATE_HOME/config" DATA="$GATE_HOME/data" STATE="$GATE_HOME/state"
    # shellcheck source=bin/fm-quota-balance-lib.sh
    . "$ROOT/bin/fm-quota-balance-lib.sh"
    rc=0
    fm_quota_balance_gate t1 "$1" "$2" "$3" "$GATE_HOME/projects/app" || rc=$?
    printf '%s|%s|%s\n' "$rc" "$FM_QUOTA_BALANCE_REASON" "$FM_QUOTA_BALANCE_RECORD" )
}

write_quota -5 -30
assert_equals '0||null' "$(gate codex gpt-6-astra high)" 'no crew-dispatch.json: no rules, no gate'
printf '{"rules":[\n' > "$GATE_HOME/config/crew-dispatch.json"
result=$(gate codex gpt-6-astra high)
assert_equals 1 "${result%%|*}" 'malformed dispatch config refuses instead of skipping the gate'
assert_contains "$result" 'is unreadable or malformed' 'the refusal names the broken config'
# Quota balance is the default: with no quota_balance key the gate still applies.
printf '%s\n' '{"rules":[{"when":"x","use":[{"harness":"codex","model":"gpt-6-astra","effort":"high"},{"harness":"claude","model":"opus","effort":"high"}]}]}' > "$GATE_HOME/config/crew-dispatch.json"
result=$(gate codex gpt-6-astra high)
assert_equals 1 "${result%%|*}" 'the gate applies without any quota_balance key'
jq 'del(.providers[1])' "$QUOTA_FIXTURE" > "$TMP_ROOT/claude-only.json"
printf '%s\n' '{"rules":[{"when":"x","use":[{"harness":"codex","model":"gpt-6-astra","effort":"high"}]}]}' > "$GATE_HOME/config/crew-dispatch.json"
result=$(QUOTA_FIXTURE="$TMP_ROOT/claude-only.json" gate codex gpt-6-astra high)
assert_equals 0 "${result%%|*}" 'no candidate with quota evidence proceeds'
assert_equals unverifiable "$(printf '%s\n' "${result##*|}" | jq -r .verdict)" 'and records that the balance was unverifiable'

balance_rules "$GATE_HOME/config"
result=$(gate codex gpt-6-astra high)
assert_equals 1 "${result%%|*}" 'a profile off the balanced allowance is refused'
assert_contains "$result" 'quota balance: the balanced pick is claude:opus on claude (headroom -5)' 'the refusal names the pick'
assert_equals refused "$(printf '%s\n' "${result##*|}" | jq -r .verdict)" 'the refusal is recorded'
result=$(gate claude opus high)
assert_equals 0 "${result%%|*}" 'the balanced profile proceeds'
assert_equals 'balanced:rule_1:claude' "$(printf '%s\n' "${result##*|}" | jq -r '"\(.verdict):\(.rule):\(.pick.provider)"')" 'the pass is recorded with its rule and pick'
result=$(gate codex gpt-6-sol high)
assert_equals 1 "${result%%|*}" 'the default profiles are checked when no rule is recorded'
assert_contains "$result" 'claude:sonnet' 'the default rule names its own pick'

hash=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$GATE_HOME/data/t1/brief.md")
jq -n --arg hash "$hash" '{version:1,workload:"backend",requires_drive:false,dispatch_rule:0,brief_sha256:$hash,
  balance_override:"needs the Codex computer-use skill for this browser journey"}' > "$GATE_HOME/data/t1/placement.json"
result=$(gate codex gpt-6-astra high)
assert_equals 0 "${result%%|*}" 'a recorded override proceeds'
assert_equals 'override:needs the Codex computer-use skill for this browser journey' \
  "$(printf '%s\n' "${result##*|}" | jq -r '"\(.verdict):\(.override)"')" 'the override and its reason are kept'
rm "$GATE_HOME/data/t1/placement.json"
result=$(gate grok grok-4 high)
assert_equals 0 "${result%%|*}" 'a profile in no rule starts as an explicit choice outside the rules'
assert_equals outside-rules "$(printf '%s\n' "${result##*|}" | jq -r .verdict)" 'and that verdict is recorded'
pass 'the spawn gate enforces the balanced pick by default, refuses broken config, honors only recorded overrides, and records every verdict'

# --- measured draw --------------------------------------------------------------
BURN="$TMP_ROOT/burn"
mkdir -p "$BURN"
now=1900000000
write_quota -5 -30
printf '%s\n' '[{"task":"a","provider":"codex","model":"gpt-6-astra"},{"task":"b","provider":"codex","model":"openai-codex/gpt-6-astra"}]' > "$BURN/crews.json"
python3 "$ROOT/bin/fm-quota-burn.py" sample "$BURN" "$QUOTA_FIXTURE" "$BURN/crews.json" "$now"
python3 "$ROOT/bin/fm-quota-burn.py" sample "$BURN" "$QUOTA_FIXTURE" "$BURN/crews.json" $((now + 30))
assert_equals 1 "$(wc -l < "$BURN/quota-samples.jsonl" | tr -d ' ')" 'a sample within a minute of the last is skipped'
assert_equals 'codex:60:gpt-6-astra,gpt-6-astra' "$(jq -r '[(.rows[]|select(.provider=="codex")|"\(.provider):\(.pct)"), ([.crews[].model]|join(","))]|join(":")' "$BURN/quota-samples.jsonl")" \
  'a sample keeps each allowance and the live crew by bare model'
jq '.providers[1].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = 50' "$QUOTA_FIXTURE" > "$BURN/q2.json"
printf '%s\n' '[{"task":"a","provider":"codex","model":"gpt-6-astra"}]' > "$BURN/crews2.json"
python3 "$ROOT/bin/fm-quota-burn.py" sample "$BURN" "$BURN/q2.json" "$BURN/crews2.json" $((now + 3600))
jq '.providers[1].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = 45' "$QUOTA_FIXTURE" > "$BURN/q3.json"
printf '[]\n' > "$BURN/crews3.json"
python3 "$ROOT/bin/fm-quota-burn.py" sample "$BURN" "$BURN/q3.json" "$BURN/crews3.json" $((now + 5400))
rates=$(python3 "$ROOT/bin/fm-quota-burn.py" rates "$BURN" $((now + 5400)))
# Interval 1: a at both ends (weight 1), b only at the start (0.5): 10 points
# over 1.5 crew-hours. Interval 2: a only at the start: 5 points over 0.25.
assert_equals '8571:1750:3600' "$(jq -r '.models["codex:gpt-6-astra"] | "\(.points_per_hour * 1000 | round):\(.crew_hours * 1000 | round):\(.run_seconds)"' <<<"$rates")" \
  'points per crew-hour and finished-crew lifetime are measured'
assert_equals '8571:3600' "$(jq -r '.models["codex:gpt-6-astra"] | "\(.draw * 1000 | round):\(.span)"' <<<"$rates")" 'draw is rate times run, owed over the run'
assert_equals null "$(jq -c '.models["claude:opus"] // null' <<<"$rates")" 'an allowance with no crew evidence keeps the fixed default'
# A crew that starts between two samples carries that interval's loss, and a
# later model does not absorb an earlier crew's loss alone.
BURN2="$TMP_ROOT/burn2"
mkdir -p "$BURN2"
printf '[]\n' > "$BURN2/none.json"
printf '%s\n' '[{"task":"a","provider":"codex","model":"gpt-6-astra"}]' > "$BURN2/a.json"
printf '%s\n' '[{"task":"a","provider":"codex","model":"gpt-6-astra"},{"task":"b","provider":"codex","model":"gpt-6-sol"}]' > "$BURN2/ab.json"
while read -r offset pct crews; do
  jq --argjson pct "$pct" '.providers[1].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = $pct' "$QUOTA_FIXTURE" > "$BURN2/q.json"
  python3 "$ROOT/bin/fm-quota-burn.py" sample "$BURN2" "$BURN2/q.json" "$BURN2/$crews.json" $((now + offset))
done <<'STEPS'
0 60 none
3600 54 a
7200 48 ab
STEPS
rates=$(python3 "$ROOT/bin/fm-quota-burn.py" rates "$BURN2" $((now + 7200)))
assert_equals '10000:1500' "$(jq -r '.models["codex:gpt-6-astra"] | "\(.points_per_hour * 1500 | round):\(.crew_hours * 1000 | round)"' <<<"$rates")" \
  'a crew that started inside an interval is charged its share of that loss'
assert_equals '2000:500' "$(jq -r '.models["codex:gpt-6-sol"] | "\(.points_per_hour * 500 | round):\(.crew_hours * 1000 | round)"' <<<"$rates")" \
  'a later model takes only its own share'
pass 'measured draw comes from sampled allowance loss per crew-hour and crew lifetimes'

# --- one real spawn: refused off-balance, launched on-balance --------------------
id=balance-spawn-z1
case_dir="$TMP_ROOT/spawn"
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
fake_quota_axi "$fakebin"
fm_test_spawn_home "$home" codex
fm_git_worktree "$proj" "$wt" "wt-$id"
fm_test_spawn_brief "$home" "$id"
balance_rules "$home/config"
write_quota -5 -30
out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout --harness codex --model gpt-6-astra --effort high)
status=$?
expect_code 1 "$status" "an off-balance crew start is refused: $out"
assert_contains "$out" 'error: quota balance: the balanced pick is claude:opus on claude (headroom -5)' 'spawn names the balanced pick'
assert_absent "$home/state/$id.meta" 'the refusal happens before any metadata or worktree'
write_quota -30 -5
out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout --harness codex --model gpt-6-astra --effort high)
status=$?
expect_code 0 "$status" "the balanced crew start launches: $out"
assert_grep 'harness=codex' "$home/state/$id.meta" 'the balanced crew is recorded'
assert_equals codex "$(jq -r 'select(.key == "balance-spawn-z1") | .provider' "$home/state/dispatch-charges.jsonl")" 'the launch charged its allowance'
pass 'fm-spawn refuses an off-balance crew before provisioning and launches the balanced one'

printf '# all fm-quota-balance tests passed\n'
