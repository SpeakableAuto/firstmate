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
rm -f "$GATE_HOME/state/quota-balance-"* "$GATE_HOME/state/.wake-queue"*
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
rm -f "$GATE_HOME/state/quota-balance-last.json"
result=$(QUOTA_FIXTURE="$TMP_ROOT/claude-only.json" gate codex gpt-6-astra high)
assert_equals 0 "${result%%|*}" 'no candidate with quota evidence proceeds'
assert_equals unverifiable "$(printf '%s\n' "${result##*|}" | jq -r .verdict)" 'and records that the balance was unverifiable'
assert_equals 1 "$(wc -l < "$GATE_HOME/state/quota-balance-unverifiable.jsonl" | tr -d ' ')" 'a home without placement config records the degraded start'
assert_equals 1 "$(grep -c 'check: quota-balance-unverifiable' "$GATE_HOME/state/.wake-queue")" 'the first degraded start alerts firstmate'
[ -f "$GATE_HOME/state/quota-balance-unverifiable.open" ] || fail 'the degraded episode remains open'
result=$(QUOTA_FIXTURE="$TMP_ROOT/claude-only.json" gate codex gpt-6-astra high)
assert_equals 0 "${result%%|*}" 'another degraded start in the episode still proceeds'
assert_equals 2 "$(wc -l < "$GATE_HOME/state/quota-balance-unverifiable.jsonl" | tr -d ' ')" 'every degraded start is recorded'
assert_equals 1 "$(grep -c 'check: quota-balance-unverifiable' "$GATE_HOME/state/.wake-queue")" 'an open episode alerts only once'

balance_rules "$GATE_HOME/config"
result=$(gate codex gpt-6-astra high)
assert_equals 1 "${result%%|*}" 'a profile off the balanced allowance is refused'
assert_contains "$result" 'quota balance: the balanced pick is claude:opus on claude (headroom -5)' 'the refusal names the pick'
assert_equals refused "$(printf '%s\n' "${result##*|}" | jq -r .verdict)" 'the refusal is recorded'
assert_absent "$GATE_HOME/state/quota-balance-unverifiable.open" 'a refused verdict closes the degraded episode'
rm -f "$GATE_HOME/state/quota-balance-last.json"
printf '%s\n' '{"rules":[{"when":"x","use":[{"harness":"codex","model":"gpt-6-astra","effort":"high"}]}]}' > "$GATE_HOME/config/crew-dispatch.json"
result=$(QUOTA_FIXTURE="$TMP_ROOT/claude-only.json" gate codex gpt-6-astra high)
assert_equals 0 "${result%%|*}" 'a later degraded episode proceeds independently'
assert_equals 2 "$(grep -c 'check: quota-balance-unverifiable' "$GATE_HOME/state/.wake-queue")" 'a later degraded episode alerts again'

now=$(date +%s)
jq -n --argjson at "$now" '{at:$at,accounts:[
  {home:"local",provider:"claude",account:"",headroom:-5,label:"claude"},
  {home:"local",provider:"codex",account:"",headroom:-30,label:"codex"}]}' > "$GATE_HOME/state/quota-balance-last.json"
result=$(QUOTA_FIXTURE="$TMP_ROOT/claude-only.json" gate codex gpt-6-astra high)
assert_equals 1 "${result%%|*}" 'a fresh last reading refuses a known-behind allowance when live evidence disappears'
assert_contains "$result" 'last known reading' 'the refusal names its evidence source'
assert_contains "$result" 'codex is 25 points behind claude' 'the refusal names the known spread'
assert_absent "$GATE_HOME/state/quota-balance-unverifiable.open" 'the last-reading refusal closes the degraded episode'

printf '%s\n' '{"balance_override":"P0 needs this mapped profile","impact":"P0"}' > "$GATE_HOME/data/t1/placement.json"
result=$(QUOTA_FIXTURE="$TMP_ROOT/claude-only.json" gate codex gpt-6-astra high)
assert_equals 0 "${result%%|*}" 'an override is honored on the last-reading path'
assert_equals codex "$(jq -r 'select(.key=="t1")|.provider' "$GATE_HOME/state/dispatch-charges.jsonl")" 'an unverifiable override still charges its mapped allowance'
rm "$GATE_HOME/data/t1/placement.json"

balance_rules "$GATE_HOME/config"
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
assert_equals 1 "${result%%|*}" 'a profile in no rule is refused without an override'
assert_contains "$result" 'record balance_override in data/t1/placement.json' 'the refusal names the required record'
jq -n '{balance_override:"raw harness required by this task fixture"}' > "$GATE_HOME/data/t1/placement.json"
result=$(gate grok grok-4 high)
f8=${result%%|*}
rm "$GATE_HOME/data/t1/placement.json"
# A profile present only in a specialist rule is not evidence of task fit.
write_quota -60 -3
jq '.rules += [{when:"Design",use:[{harness:"claude",model:"fable",effort:"high"}]}]' "$GATE_HOME/config/crew-dispatch.json" > "$TMP_ROOT/rules.json"
mv "$TMP_ROOT/rules.json" "$GATE_HOME/config/crew-dispatch.json"
result=$(gate claude fable high)
f1=${result%%|*}
printf '%s\n' '{"dispatch_rule":99}' > "$GATE_HOME/data/t1/placement.json"
result=$(gate codex gpt-6-astra high)
f2rule=${result%%|*}
rm "$GATE_HOME/data/t1/placement.json"
write_quota -5 -30
jq '.providers[0].quotaSemantics.effectiveAvailability[0].pace="x"' "$QUOTA_FIXTURE" > "$TMP_ROOT/bad-pace.json"
result=$(QUOTA_FIXTURE="$TMP_ROOT/bad-pace.json" gate codex gpt-6-astra high)
printf '# review probes: F1=%s F2rule=%s F2shape=%s F8=%s (all must refuse with 1)\n' "$f1" "$f2rule" "${result%%|*}" "$f8"
assert_equals 1 "$f8" 'an override with no mapped allowance refuses rather than starting uncharged'
assert_equals 1 "$f1" 'an inferred specialist rule cannot drain an allowance behind the global pool'
assert_equals 1 "$f2rule" 'an invalid recorded rule is a structural refusal, not quota uncertainty'
assert_equals 1 "${result%%|*}" 'a resolver shape error fails closed' 
pass 'the spawn gate enforces the balanced pick, alerts degraded starts, uses fresh evidence, and honors recorded overrides'

# Parent placement survives the child missing the parent's charge ledger.
balance_rules "$GATE_HOME/config"
write_quota -30 -5
printf 'm0002\n' > "$GATE_HOME/.fm-secondmate-home"
hash=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$GATE_HOME/data/t1/brief.md")
jq -n --arg hash "$hash" --argjson at "$(date +%s)" '{dispatch_rule:0,parent_placement:{version:1,at:$at,task:"t1",brief_sha256:$hash,target:"m0002",provider:"claude",account:"",profile:{harness:"claude",model:"opus",effort:"high"}}}' > "$GATE_HOME/data/t1/placement.json"
result=$(gate claude opus high)
assert_equals 0 "${result%%|*}" 'the receiving home honors a current parent pool placement'
jq '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining=12' "$QUOTA_FIXTURE" > "$TMP_ROOT/low-parent.json"
result=$(QUOTA_FIXTURE="$TMP_ROOT/low-parent.json" gate claude opus high)
assert_equals 1 "${result%%|*}" 'a parent decision cannot pass the receiving allowance reserve'
printf '%s\n' '{"dispatch_rule":0,"impact":"P0","balance_override":"restore failed booking system"}' > "$GATE_HOME/data/t1/placement.json"
result=$(QUOTA_FIXTURE="$TMP_ROOT/low-parent.json" gate claude opus high)
assert_equals 0 "${result%%|*}" 'a recorded P0 can draw below 10 while leaving 5'
QUOTA_FIXTURE="$TMP_ROOT/low-parent.json" gate claude opus high >/dev/null
assert_equals 1 "$(grep -c 'check: quota-p0:' "$GATE_HOME/state/.wake-queue")" 'P0 reserve use alerts once per task'
jq '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining=9' "$QUOTA_FIXTURE" > "$TMP_ROOT/too-low-parent.json"
result=$(QUOTA_FIXTURE="$TMP_ROOT/too-low-parent.json" gate claude opus high)
assert_equals 1 "${result%%|*}" 'P0 cannot breach the hard 5% floor after its own draw'
rm "$GATE_HOME/data/t1/placement.json"

# Live Claude resets jitter across reads, including minute boundaries.
balance_rules "$GATE_HOME/config"
rm -f "$GATE_HOME/state/quota-spread.json" "$GATE_HOME/state/quota-spread-notified.json" "$GATE_HOME/state/.wake-queue"
for stamp in 59.5 60.5 61.5 62.5; do
  write_quota -5 -30
  jq --arg stamp "$stamp" '.providers[0].windows[0].resetsAt=("2030-01-01T01:00:"+$stamp+"Z")' "$QUOTA_FIXTURE" > "$TMP_ROOT/jitter.json"
  QUOTA_FIXTURE="$TMP_ROOT/jitter.json" gate claude opus high >/dev/null
done
alarm_wakes=$(grep -c 'check: quota-spread' "$GATE_HOME/state/.wake-queue")
alarm_open=$(jq '.conditions|length' "$GATE_HOME/state/quota-spread.json")
# Close and reopen immediately: do not page the supervisor again.
write_quota -5 -10
gate claude opus high >/dev/null
write_quota -5 -30
gate claude opus high >/dev/null
printf '# jitter probes: wakes=%s open=%s reopen=%s (want 1/1/1)\n' "$alarm_wakes" "$alarm_open" "$(grep -c 'check: quota-spread' "$GATE_HOME/state/.wake-queue")"
assert_equals 1 "$alarm_wakes" 'jitter does not repeat the spread alarm'
assert_equals 1 "$alarm_open" 'jitter does not leave orphan conditions'
assert_equals 1 "$(grep -c 'check: quota-spread' "$GATE_HOME/state/.wake-queue")" 'a reopened condition is rate limited'

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
# Observe two different window units through the real sample/rates interface.
now=$(($(date +%s) - 7200))
BURN3="$TMP_ROOT/burn3"
mkdir -p "$BURN3"
printf '%s\n' '[{"task":"a","provider":"claude","model":"opus"}]' > "$BURN3/crews.json"
for offset in 0 3600 7200; do
  jq -n --argjson step "$((offset / 3600))" '{providers:[{provider:"claude",windows:[
    {id:"five_hour",percentRemaining:(90-40*$step),resetsAt:("2030-01-01T05:00:0"+($step|tostring)+".5Z")},
    {id:"seven_day",percentRemaining:(90-2*$step),resetsAt:("2030-01-07T05:00:0"+($step|tostring)+".5Z")}],
    quotaSemantics:{effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:(90-40*$step),limitingWindowIds:["five_hour"]}]}}]}' > "$BURN3/q.json"
  python3 "$ROOT/bin/fm-quota-burn.py" sample "$BURN3" "$BURN3/q.json" "$BURN3/crews.json" $((now + offset))
done
rates=$(python3 "$ROOT/bin/fm-quota-burn.py" rates "$BURN3" $((now + 7200)))
printf '# window burn probe: %s\n' "$rates"
assert_equals '40:2' "$(jq -r '.models["claude:opus"].windows | "\(.five_hour.points_per_hour|round):\(.seven_day.points_per_hour|round)"' <<<"$rates")" 'jittered resets preserve separate session and weekly burn units'
cp "$BURN3/quota-samples.jsonl" "$GATE_HOME/state/quota-samples.jsonl"
write_quota -5 -30
jq '.providers[0].windows=[
    {id:"five_hour",kind:"session",percentRemaining:90,pace:{reservePercentPoints:5}},
    {id:"seven_day",kind:"weekly",percentRemaining:45,pace:{reservePercentPoints:-5}}] |
    .providers[0].quotaSemantics.effectiveAvailability[0] += {boundedBy:["five_hour","seven_day"],limitingWindowIds:["seven_day"],effectivePercentRemaining:45}' "$QUOTA_FIXTURE" > "$TMP_ROOT/window-units.json"
result=$(QUOTA_FIXTURE="$TMP_ROOT/window-units.json" gate claude opus high)
assert_equals 0 "${result%%|*}" '40 session points do not become a 40-point weekly admission charge'
assert_equals '40:2' "$(jq -r 'select(.key=="t1")|"\(.windows.five_hour.draw|round):\(.windows.seven_day.draw|round)"' "$GATE_HOME/state/dispatch-charges.jsonl")" 'the ledger keeps each window in its own units'
rm -f "$GATE_HOME/state/quota-samples.jsonl"
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
cp "$home/data/$id/brief.md" "$case_dir/brief.saved"
printf '# Task\n' > "$home/data/$id/brief.md"
out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout --harness codex --model gpt-6-astra --effort high)
assert_absent "$home/state/dispatch-charges.jsonl" 'a later brief refusal leaves no phantom quota charge'
cp "$case_dir/brief.saved" "$home/data/$id/brief.md"
out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout --harness codex --model gpt-6-astra --effort high)
status=$?
expect_code 0 "$status" "the balanced crew start launches: $out"
assert_grep 'harness=codex' "$home/state/$id.meta" 'the balanced crew is recorded'
assert_equals codex "$(jq -r 'select(.key == "balance-spawn-z1") | .provider' "$home/state/dispatch-charges.jsonl")" 'the launch charged its allowance'
pass 'fm-spawn refuses an off-balance crew before provisioning and launches the balanced one'

printf '# all fm-quota-balance tests passed\n'
