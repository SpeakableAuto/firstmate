#!/usr/bin/env bash
# Replay proof for quota balance: the recorded crew starts of the week Codex
# ran dry (tests/fixtures/quota-replay-2026-10-28.json, measured draw per start,
# no task names) replayed twice through tests/fm-quota-balance-replay.py.
# Kept on the providers they really used, Codex falls under the 10% reserve
# while Claude keeps most of its fresh week. Through the real resolver's
# balanced pick at every start, across this machine and the second machine
# (its own Claude account, the shared Codex account), no allowance is drained
# first: Codex keeps its reserve and the allowances end within the 20-point
# spread. Only ssh is faked; the real snapshot and remote-read path run.
set -u
unset TYPESAFE_API_KEY

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-balance-replay)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
REMOTE_HOME="$TMP_ROOT/remote-home"
FIXTURE="$ROOT/tests/fixtures/quota-replay-2026-10-28.json"
export QUOTA_FIXTURE="$TMP_ROOT/quota.json" REMOTE_QUOTA_FIXTURE="$TMP_ROOT/remote-quota.json"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$REMOTE_HOME/config" "$REMOTE_HOME/state"
cat > "$FAKEBIN/ssh" <<SH
#!/usr/bin/env bash
set -u
while [ "\$#" -gt 0 ] && [ "\$1" != -- ]; do shift; done
shift
args=()
while IFS= read -r -d '' arg; do args+=("\$arg"); done < <(printf '%s' "\$6" | base64 --decode 2>/dev/null || printf '%s' "\$6" | base64 -D)
exec env FM_HOME="$REMOTE_HOME" QUOTA_FIXTURE="$REMOTE_QUOTA_FIXTURE" "$ROOT/bin/\${args[0]}" "\${args[@]:1}"
SH
chmod +x "$FAKEBIN/ssh"
export FM_SSH_BIN="$FAKEBIN/ssh"
printf '%s\n' '- app [direct-PR] - Replayed project (added 2030-01-01)' > "$HOME_DIR/data/projects.md"
cat > "$HOME_DIR/data/secondmates.md" <<'MD'
# Secondmates

- m0002 - Second machine. (host: m0002-host; root: /srv/firstmate-code; home: /srv/firstmate-home; scope: any work; projects: app; added 2030-01-01)
MD
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
cat "${QUOTA_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"
# The machine's rule shape with the 40% floors replaced by quota balance.
cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{
  "quota_balance": { "reserve_percent": 10, "spread_points": 20 },
  "rules": [
    { "when": "Trivial mechanical edit.",
      "use": [ { "harness": "codex", "model": "gpt-6-luna", "effort": "high" },
               { "harness": "claude", "model": "haiku", "effort": "high" },
               { "harness": "claude", "model": "sonnet", "effort": "high" } ] },
    { "when": "Design work.", "select": "candidate-order",
      "use": [ { "harness": "claude", "model": "fable", "effort": "high" },
               { "harness": "claude", "model": "opus", "effort": "high" } ] },
    { "when": "Hard engineering.",
      "use": [ { "harness": "codex", "model": "gpt-6-astra", "effort": "high" },
               { "harness": "claude", "model": "opus", "effort": "high" } ] }
  ],
  "default": [ { "harness": "codex", "model": "gpt-6-sol", "effort": "high" },
               { "harness": "claude", "model": "sonnet", "effort": "high" },
               { "harness": "claude", "model": "opus", "effort": "high" } ]
}
JSON
cp "$HOME_DIR/config/crew-dispatch.json" "$REMOTE_HOME/config/crew-dispatch.json"

replay() {  # <mode>
  PATH="$FAKEBIN:$PATH" python3 "$ROOT/tests/fm-quota-balance-replay.py" "$ROOT" "$HOME_DIR" "$REMOTE_HOME" "$FIXTURE" "$1"
}

historical=$(replay historical) || fail 'historical replay failed'
printf '# historical: %s\n' "$historical"
assert_equals true "$(jq '.lowest_percent.codex < 10' <<<"$historical")" 'the recorded starts drain Codex under the reserve (reproduces the week)'
assert_equals true "$(jq '.final_spread > 20' <<<"$historical")" 'the recorded starts leave the allowances far apart'
pass 'replaying the recorded provider choices reproduces Codex running dry first'

balanced=$(replay balanced) || fail 'balanced replay failed'
printf '# balanced: %s\n' "$balanced"
assert_equals true "$(jq '.lowest_percent.codex >= 10' <<<"$balanced")" 'Codex keeps its reserve under the balanced pick'
# The alarm holds new work past 20 points; time alone can open the gap by up
# to one crew's measured draw before the next start is judged.
assert_equals true "$(jq --argjson draw "$(jq '.draw.codex.points_per_start' "$FIXTURE")" '.final_spread <= 20 + $draw' <<<"$balanced")" \
  'the allowances end within the 20-point spread plus one crew'\''s draw'
assert_equals 0 "$(jq '.behind_placements' <<<"$balanced")" 'no start lands on an allowance more than 20 points behind'
assert_equals 0 "$(jq '.unplaced' <<<"$balanced")" 'every recorded start is placed within the window'
assert_equals true "$(jq '.historical_codex_starts_refused > 0' <<<"$balanced")" 'the spawn check refuses recorded Codex starts that were off balance'
assert_equals true "$(jq '.placed | all(.[]; . > 0)' <<<"$balanced")" 'every allowance takes work'
pass 'replaying the same starts through the balanced pick drains the allowances evenly'

printf '# all fm-quota-balance-replay tests passed\n'
