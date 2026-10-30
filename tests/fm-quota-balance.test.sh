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
    SCRIPT_DIR="$ROOT/bin" FM_HOME="$GATE_HOME" CONFIG="$GATE_HOME/config" DATA="$GATE_HOME/data" STATE="$GATE_HOME/state"
    # shellcheck source=bin/fm-quota-balance-lib.sh
    . "$ROOT/bin/fm-quota-balance-lib.sh"
    rc=0
    fm_quota_balance_gate t1 "$1" "$2" "$3" "$GATE_HOME/projects/app" || rc=$?
    printf '%s|%s|%s\n' "$rc" "$FM_QUOTA_BALANCE_REASON" "$FM_QUOTA_BALANCE_RECORD" )
}

printf '%s\n' '{"rules":[{"when":"x","use":[{"harness":"codex","model":"gpt-6-astra","effort":"high"}]}]}' > "$GATE_HOME/config/crew-dispatch.json"
write_quota -5 -30
assert_equals '0||null' "$(gate codex gpt-6-astra high)" 'no quota_balance: the gate does not apply'

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
assert_equals 1 "${result%%|*}" 'a profile in no rule is refused'
assert_contains "$result" 'is in no dispatch rule' 'the refusal says why'
pass 'the spawn gate enforces the balanced pick, honors only recorded overrides, and records every verdict'

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
# 10 points over 2 crew-hours, then 5 points over half a crew-hour: 6 per crew-hour.
assert_equals '6000:2500:3600' "$(jq -r '.models["codex:gpt-6-astra"] | "\(.points_per_hour * 1000 | round):\(.crew_hours * 1000 | round):\(.run_seconds)"' <<<"$rates")" \
  'points per crew-hour and finished-crew lifetime are measured'
assert_equals '6000:3600' "$(jq -r '.models["codex:gpt-6-astra"] | "\(.draw * 1000 | round):\(.span)"' <<<"$rates")" 'draw is rate times run, owed over the run'
assert_equals null "$(jq -c '.models["claude:opus"] // null' <<<"$rates")" 'an allowance with no crew evidence keeps the fixed default'
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
