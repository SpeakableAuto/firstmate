#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_program_continuation_without_workers() {
  local home out status projection
  home=$(make_home programs)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] product-a - First accepted product (repo: alpha) (kind: program)
  children: child-a
- [ ] product-b - Second accepted product (repo: beta) (kind: program)
  recheck-at: 2099-01-01T00:00:00Z
## Queued
- [ ] uncommissioned - Idea only (repo: gamma) (kind: program)
## Done
- [x] child-a - Source ready (repo: alpha) (kind: ship)
EOF
  projection=$(FM_HOME="$home" "$ROOT/bin/fm-programs.sh" --json) || fail "program projection failed"
  printf '%s' "$projection" | jq -e '
    .supervision_needed and (.programs | length == 2)
    and (.programs | any(.id == "product-a" and .due and .children[0].state == "done"))
    and (.programs | any(.id == "product-b" and (.due | not)))
  ' >/dev/null || fail "accepted programs lost or child completion mistaken for parent completion"
  FM_HOME="$home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2/state"' _ "$ROOT" "$home"     || fail "zero-worker accepted projects do not require supervision"
  status=0
  out=$(FM_HOME="$home" FM_POLL=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 4) || status=$?
  expect_code 0 "$status" "zero-worker program wake"
  assert_contains "$out" 'check: program-reconcile' "program work did not wake checkpoint"
  assert_contains "$out" 'product-a' "due project absent from wake"
  assert_not_contains "$out" 'uncommissioned' "queued idea silently commissioned"
  # Outstanding event is durable and never multiplied by another tick.
  FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"; fm_program_reconcile_tick "$2/state"' _ "$ROOT" "$home" >/dev/null
  [ "$(awk -F '\t' '$3 == "check" && $4 == "program-reconcile" {n++} END {print n+0}' "$home/state/.wake-queue")" -eq 1 ]     || fail "duplicate program event while unacknowledged"
  pass "multiple accepted projects survive zero workers and one child finishing, with durable deduplicated wake"
}

test_program_future_pause_and_parse_failure() {
  local home status out
  home=$(make_home future-program)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] future - Future checkpoint (repo: alpha) (kind: program)
  recheck-at: 2099-01-01T00:00:00Z
- [ ] paused - Explicit pause (repo: beta) (kind: program)
  continuation: paused
EOF
  FM_HOME="$home" "$ROOT/bin/fm-programs.sh" --json | jq -e '.supervision_needed and ([.programs[] | select(.due)] | length == 0)' >/dev/null     || fail "future checkpoint either forgotten or prematurely due"
  status=0
  out=$(FM_HOME="$home" FM_POLL=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1) || status=$?
  expect_code 124 "$status" "future project quiet wait"
  assert_contains "$out" 'checkpoint:' "future program should quietly keep checkpointing"
  printf '  recheck-at: not-a-date\n' >> "$home/data/backlog.md"
  FM_HOME="$home" "$ROOT/bin/fm-programs.sh" --json | jq -e '.supervision_needed and (.errors | length > 0)' >/dev/null     || fail "invalid continuation input silently became completed or inactive"
  pass "future checks retain supervision, explicit pauses stay quiet, and malformed timing is visible"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success

test_program_continuation_without_workers
test_program_future_pause_and_parse_failure

test_program_malformed_transition_and_overrides() {
  local home terminal isolated unrelated json out seq generation
  home=$(make_home malformed-program)
  terminal=$(make_home terminal-program)
  isolated=$(make_home isolated-state)
  unrelated=$(make_home unrelated-home)

  printf '## In flight\n- [ ] delivery - Accepted delivery (repo: alpha) (kind: program)\n' > "$home/data/backlog.md"
  FM_HOME="$home" FM_PROGRAM_NOW_EPOCH=1000 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$home" >/dev/null || fail "valid program did not emit"
  seq=$(awk -F '\t' 'END {print $2}' "$home/state/.wake-queue")
  out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1) || fail "valid program event did not present"
  generation=$(printf '%s\n' "$out" | sed -n 's/.*--recovery-generation \([^ ]*\).*/\1/p' | head -1)
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null 2>&1 \
    || fail "valid program event did not acknowledge"

  printf '## In flight\n- [ ] delivery - Accepted delivery (repo: alpha) (kind: mystery)\n' > "$home/data/backlog.md"
  json=$(FM_HOME="$home" "$ROOT/bin/fm-programs.sh" --json) || fail "malformed transition projection unavailable"
  printf '%s' "$json" | jq -e '
    .supervision_needed
    and (.errors | any(.id == "delivery" and (.errors | length) > 0))
  ' >/dev/null || fail "previously emitted program disappeared after an unrecognized kind transition"
  FM_HOME="$home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2/state"' _ "$ROOT" "$home" \
    || fail "malformed transition stopped zero-worker supervision"
  out=$(FM_HOME="$home" FM_POLL=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 4) \
    || fail "malformed transition did not wake checkpoint"
  assert_contains "$out" 'check: program-reconcile' "malformed transition had no durable reconciliation wake"

  printf '## In flight\n- [ ] release - Accepted release (repo: beta) (kind: program)\n' > "$terminal/data/backlog.md"
  FM_HOME="$terminal" FM_PROGRAM_NOW_EPOCH=1000 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$terminal" >/dev/null || fail "terminal fixture did not emit"
  printf '## In flight\n- [ ] release - Accepted release (repo: beta) (kind: program)\n  continuation: paused\n' > "$terminal/data/backlog.md"
  json=$(FM_HOME="$terminal" "$ROOT/bin/fm-programs.sh" --json) || fail "paused transition projection unavailable"
  printf '%s' "$json" | jq -e '(.supervision_needed | not) and (.errors | length == 0)' >/dev/null \
    || fail "explicit pause became a continuity alarm"
  printf '## Done\n- [x] release - Accepted release (repo: beta) (kind: program)\n' > "$terminal/data/backlog.md"
  FM_HOME="$terminal" bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$terminal" >/dev/null || fail "terminal transition did not reconcile"
  json=$(FM_HOME="$terminal" "$ROOT/bin/fm-programs.sh" --json) || fail "terminal projection unavailable"
  printf '%s' "$json" | jq -e '(.supervision_needed | not) and (.errors | length == 0)' >/dev/null \
    || fail "legitimate Done transition became a continuity alarm"
  [ ! -e "$terminal/state/.program-reconciliation" ] || fail "terminal transition retained an unfinished receipt"

  printf '## In flight\n- [ ] state-root - State override program (repo: gamma) (kind: program)\n' > "$home/data/backlog.md"
  printf '## In flight\n' > "$unrelated/data/backlog.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$isolated/state" bash -c '
    . "$1/bin/fm-supervision-lib.sh"
    fm_supervision_needed "$2/state"
  ' _ "$ROOT" "$isolated" || fail "state-only override redirected the effective data root"
  FM_HOME="$unrelated" FM_STATE_OVERRIDE="$isolated/state" FM_DATA_OVERRIDE="$home/data" bash -c '
    . "$1/bin/fm-supervision-lib.sh"
    fm_supervision_needed "$2/state"
  ' _ "$ROOT" "$isolated" || fail "explicit data override did not independently select the backlog"
  pass "program receipts expose malformed transitions while pauses, Done, and independent roots remain valid"
}
test_program_malformed_transition_and_overrides

test_program_hold_rechecks_after_ack_without_spinning() {
  local home out seq generation
  home=$(make_home held-program)
  printf '## In flight\n- [ ] delivery - Accepted delivery (repo: alpha) (kind: program) (hold: provider unavailable) (hold-kind: external)\n' > "$home/data/backlog.md"
  out=$(FM_HOME="$home" FM_PROGRAM_NOW_EPOCH=1000 FM_PROGRAM_RECHECK_SECS=60 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$home") || fail "initial held-program check failed"
  assert_contains "$out" 'program-reconcile' "held obligation disappeared"
  seq=$(awk -F '\t' 'END {print $2}' "$home/state/.wake-queue")
  out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1) || fail "program event presentation failed"
  generation=$(printf '%s\n' "$out" | sed -n 's/.*--recovery-generation \([^ ]*\).*/\1/p' | head -1)
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null 2>&1     || fail "program event acknowledgement failed"
  out=$(FM_HOME="$home" FM_PROGRAM_NOW_EPOCH=1001 FM_PROGRAM_RECHECK_SECS=60 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$home") || fail "quiet held-program tick failed"
  [ -z "$out" ] || fail "unchanged held program spun immediately after ack"
  out=$(FM_HOME="$home" FM_PROGRAM_NOW_EPOCH=1060 FM_PROGRAM_RECHECK_SECS=60 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$home") || fail "due held-program tick failed"
  assert_contains "$out" 'program-reconcile' "held program had no durable later recheck"
  [ ! -e "$home/state/delivery.meta" ] || fail "program continuation invented a worker"
  pass "external hold remains quiet between acknowledged due checks and wakes later without dummy worker"
}
test_program_hold_rechecks_after_ack_without_spinning
