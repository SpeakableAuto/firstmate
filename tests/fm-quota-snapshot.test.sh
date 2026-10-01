#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-snapshot.sh.
#
# The local form runs against a fake quota-axi on PATH. The --secondmate form
# runs the real bin/fm-on.sh with FM_SSH_BIN pointed at a fake ssh that decodes
# the argv stream fm-on.sh sends and runs that command from this checkout, as
# the remote host would, with its own fake quota-axi serving a different
# fixture. Only the SSH transport is simulated; no case touches a network,
# a real account, or a live quota source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-quota-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-snapshot)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/local")
REMOTE_BIN=$(fm_fakebin "$TMP_ROOT/remote")
BASE_PATH=$PATH
CACHE="$HOME_DIR/state/quota-remote"
SSH_CALLS="$TMP_ROOT/ssh.calls"
SSH_MODE="$TMP_ROOT/ssh.mode"
mkdir -p "$HOME_DIR/data"

write_quota() { # <path> <claude-percent>
  cat > "$1" <<JSON
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "claude", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": $2, "runway": { "status": "through_reset" }, "selection": { "status": "known", "spendPriority": 1.5 } } ] } }
  ]
}
JSON
}
write_quota "$TMP_ROOT/local.json" 58
write_quota "$TMP_ROOT/remote.json" 95
printf '{"schemaVersion": 5, "providers": "not-a-list"}\n' > "$TMP_ROOT/invalid.json"

for side in local remote; do
  bin=$FAKEBIN
  [ "$side" = remote ] && bin=$REMOTE_BIN
  cat > "$bin/quota-axi" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = --json ] || exit 2
printf '%s\\n' "\${QUOTA_AXI_MAX_AGE:-unset}" > "$TMP_ROOT/$side.max-age"
case "\${FAKE_QUOTA_MODE:-ok}" in
  fail) exit 3 ;;
  hang) exec sleep 30 ;;
  invalid) cat "$TMP_ROOT/invalid.json" ;;
  *) cat "$TMP_ROOT/$side.json" ;;
esac
SH
  chmod +x "$bin/quota-axi"
done

# The fake ssh honours the mode file: ok runs the decoded command as the remote
# host would, unreachable is OpenSSH's transport failure, hang never answers,
# and remote-invalid serves a snapshot the remote quota-axi got wrong.
cat > "$FAKEBIN/ssh" <<SH
#!/usr/bin/env bash
set -u
while [ "\$#" -gt 0 ] && [ "\$1" != -- ]; do shift; done
shift
host=\$1
argv_b64=\$6
printf '%s\n' "\$host" >> "$SSH_CALLS"
mode=\$(cat "$SSH_MODE" 2>/dev/null || printf ok)
case "\$mode" in
  unreachable) printf 'ssh: connect to host %s: Connection refused\n' "\$host" >&2; exit 255 ;;
  hang) exec sleep 30 ;;
esac
args=()
while IFS= read -r -d '' arg; do args+=("\$arg"); done < <(printf '%s' "\$argv_b64" | base64 --decode 2>/dev/null || printf '%s' "\$argv_b64" | base64 -D)
quota_mode=ok
[ "\$mode" = remote-invalid ] && quota_mode=invalid
[ "\$mode" = remote-fail ] && quota_mode=fail
exec env -u FM_HOME -u FM_STATE_OVERRIDE -u FM_REMOTE_QUOTA_TTL FAKE_QUOTA_MODE="\$quota_mode" PATH="$REMOTE_BIN:$BASE_PATH" "$ROOT/bin/\${args[0]}" "\${args[@]:1}"
SH
chmod +x "$FAKEBIN/ssh"

cat > "$HOME_DIR/data/secondmates.md" <<'MD'
# Secondmates

- peer - Overflow machine for test work. (host: peer-host; root: /srv/firstmate-code; home: /srv/firstmate-home; scope: overflow work; projects: pager; added 2030-01-01)
MD

code='' out='' err=''
run() { # <exit-var> <out-var> <err-var> [env...] -- [args...]
  local __exit=$1 __out=$2 __err=$3 _out _code
  local -a envs=()
  shift 3
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  _out=$(env PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/ssh" ${envs[@]+"${envs[@]}"} "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}
ssh_calls() { if [ -f "$SSH_CALLS" ]; then wc -l < "$SSH_CALLS" | tr -d ' '; else printf 0; fi; }
reset_remote() { rm -rf "$CACHE" "$SSH_CALLS"; printf '%s\n' "${1:-ok}" > "$SSH_MODE"; }

# --- local snapshot ------------------------------------------------------------
run code out err --
expect_code 0 "$code" "local snapshot exits 0"
assert_equals 58 "$(jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining' <<<"$out")" "local snapshot is this machine's quota"
assert_equals '' "$err" "a good local snapshot is silent on stderr"
assert_equals 15m "$(cat "$TMP_ROOT/local.max-age")" "snapshot reads opt into vendor cache reuse"
run code out err QUOTA_AXI_MAX_AGE=2m --
assert_equals 2m "$(cat "$TMP_ROOT/local.max-age")" "an explicit vendor reuse age is preserved"
pass "local snapshot prints validated output and requests configurable credential-aware cache reuse"

run code out err FAKE_QUOTA_MODE=invalid --
expect_code 1 "$code" "invalid local snapshot exits 1"
assert_equals '' "$out" "invalid local snapshot prints nothing on stdout"
assert_contains "$err" 'quota-snapshot: unavailable (quota-axi --json returned an invalid snapshot)' "invalid local snapshot is named"
run code out err FAKE_QUOTA_MODE=fail --
expect_code 1 "$code" "failing quota-axi exits 1"
assert_contains "$err" 'quota-axi --json exited 3' "failing quota-axi names its exit"
run code out err FAKE_QUOTA_MODE=hang FM_QUOTA_SNAPSHOT_TIMEOUT=1 --
expect_code 1 "$code" "hanging quota-axi exits 1"
assert_contains "$err" 'quota-axi --json exceeded 1s' "hanging quota-axi is bounded"
run code out err PATH="$TMP_ROOT/none:/usr/bin:/bin" --
expect_code 1 "$code" "missing quota-axi exits 1"
assert_contains "$err" 'quota-axi not installed' "missing quota-axi is named"
pass "local snapshot failures are unknown quota, bounded and named"

# --- remote snapshot through fm-on ----------------------------------------------
reset_remote ok
run code out err -- --secondmate peer
expect_code 0 "$code" "remote snapshot exits 0"
assert_equals 95 "$(jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining' <<<"$out")" "remote snapshot is the remote machine's quota"
assert_equals peer-host "$(cat "$SSH_CALLS")" "remote snapshot travels through the registered SSH alias"
write_quota "$TMP_ROOT/remote.json" 96
run code out err -- --secondmate peer
expect_code 0 "$code" "a consecutive remote snapshot exits 0"
assert_equals 96 "$(jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining' <<<"$out")" "a consecutive dispatch sees changed remote quota"
assert_equals 2 "$(ssh_calls)" "every successful snapshot performs a remote read"
assert_absent "$CACHE/peer.json" "successful snapshots are never cached"
pass "remote snapshot reads current quota through fm-on every time"

reset_remote unreachable
run code out err -- --secondmate peer
expect_code 1 "$code" "unreachable remote exits 1"
assert_equals '' "$out" "unreachable remote prints nothing on stdout"
assert_contains "$err" "quota-snapshot: unavailable (peer's machine unreachable: ssh: connect to host peer-host: Connection refused)" "unreachable remote is named"
printf 'ok\n' > "$SSH_MODE"
run code out err -- --secondmate peer
expect_code 1 "$code" "a fresh failure is reused"
assert_contains "$err" '(cached)' "the reused failure says it is cached"
assert_equals 1 "$(ssh_calls)" "an unreachable host costs one bounded wait per TTL window"
fm_touch_epoch "$(( $(date +%s) - 600 ))" "$CACHE/peer.err"
run code out err -- --secondmate peer
expect_code 0 "$code" "an expired failure is retried and recovers"
assert_equals 2 "$(ssh_calls)" "the retry reads the remote again"
pass "unreachable remote quota is disclosed, cached briefly, and retried"

reset_remote hang
run code out err FM_REMOTE_QUOTA_TIMEOUT=1 -- --secondmate peer
expect_code 1 "$code" "hanging remote exits 1"
assert_contains "$err" 'remote read of peer exceeded 1s' "hanging remote is bounded"

reset_remote remote-invalid
run code out err -- --secondmate peer
expect_code 1 "$code" "an invalid remote snapshot exits 1"
assert_contains "$err" 'quota-snapshot: unavailable (quota-axi --json returned an invalid snapshot)' "the remote's own validation failure crosses the transport"
assert_absent "$CACHE/peer.json" "an invalid remote snapshot is never cached as good"

reset_remote remote-fail
run code out err -- --secondmate peer
expect_code 1 "$code" "a failing remote quota-axi exits 1"
assert_contains "$err" 'remote read of peer exited 1: quota-snapshot: unavailable (quota-axi --json exited 3)' "the remote failure reason is relayed"
pass "remote timeouts and remote quota failures stay unknown quota"

reset_remote ok
run code out err -- --secondmate nobody
expect_code 1 "$code" "an unregistered route exits 1"
assert_contains "$err" "no remote secondmate or SSH alias matches 'nobody'" "the route refusal is relayed"
assert_equals 0 "$(ssh_calls)" "an unregistered route never reaches ssh"

run code out err -- --secondmate ../escape
expect_code 2 "$code" "an unsafe id is a usage error"
run code out err -- --bogus
expect_code 2 "$code" "an unknown flag is a usage error"
run code out err -- --help
expect_code 0 "$code" "--help exits 0"
assert_contains "$out" 'Usage:' "--help prints usage"
pass "route and usage errors are refused before any transport"

printf '# all fm-quota-snapshot tests passed\n'
