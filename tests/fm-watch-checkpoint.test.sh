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
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# A home opted into the supervision host whose checkpoint runs a stub host in
# a fixture code root: the stub records the bound it was given, then closes
# the way $FM_HOME/host-kind says.
make_host_home() {  # <name>
  local home
  home=$(make_home "$1")
  mkdir -p "$home/root/bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cat > "$home/root/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\nprimary=%s\npark=%s\nlimit=%s\n' "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_SUPERVISION_HOST_PARK_SECONDS:-}" "${FM_SUPERVISION_HOST_PARK_LIMIT:-}" > "$FM_HOME/host-env"
case "$(cat "$FM_HOME/host-kind")" in
  boundary) printf 'supervision-host: cycle boundary - fixture\n' ;;
  handback)
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
    printf 'signal: demo.status\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\n'
    ;;
  stood-down) printf 'supervision-host stood down: this session no longer owns supervision\n' ;;
esac
SH
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-supervision-host.sh"
  : > "$home/config/supervision-host"
  printf '%s\n' "$home"
}

run_host_checkpoint() {  # <home> <kind> [checkpoint args...]; sets STATUS
  local home=$1
  printf '%s\n' "$2" > "$home/host-kind"
  shift 2
  STATUS=0
  FM_HOME="$home" "$home/root/bin/fm-watch-checkpoint.sh" "$@" >"$home/out.txt" 2>"$home/err.txt" || STATUS=$?
}

test_host_checkpoint_bounds_the_park_by_posture() {
  local home f
  home=$(make_host_home host-bound)
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a host park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 5s" "the boundary must read as the ordinary quiet line"
  assert_contains "$(cat "$home/host-env")" $'args=park\nprimary=codex\npark=5\nlimit=1235' \
    "attended, the host must park for the checkpoint's own bound with the codex pin and a turn limit past it"
  : > "$home/state/.afk-contract"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "an away park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 3600s" "away, the bound must be raised"
  assert_contains "$(cat "$home/host-env")" 'park=3600' "away, the host must park for the away bound"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 5
  assert_contains "$(cat "$home/host-env")" 'park=900' "the away bound must be configurable"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 1000
  assert_contains "$(cat "$home/host-env")" 'park=1000' "the away bound must never shorten a longer checkpoint"
  # Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
  # QUIET), so the checkpoint keeps its attended bound beside it.
  for f in fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$home/root/bin/$f"; done
  rm -f "$home/state/.afk-contract"
  FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a park beside a quiet record that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/host-env")" 'park=5' "beside a quiet record the host must park for the attended bound"
  pass "checkpoint: an opted-in home runs the host for the checkpoint's bound, raised only while away"
}

test_host_checkpoint_passes_a_handback_and_reports_a_stand_down() {
  local home
  home=$(make_host_home host-handback)
  run_host_checkpoint "$home" handback --seconds 5
  expect_code 0 "$STATUS" "a handed-back wake is an actionable checkpoint"
  assert_contains "$(cat "$home/out.txt")" $'signal: demo.status\nsupervision-host: the away session could not take this wake' \
    "the wake and its host line must pass through"
  assert_not_contains "$(cat "$home/out.txt")" "watcher: started" "the host's cycle status is not part of the wake"
  run_host_checkpoint "$home" stood-down --seconds 5
  expect_code 1 "$STATUS" "a host that stood down is a failed checkpoint"
  assert_contains "$(cat "$home/out.txt")" "supervision-host stood down" "the stand-down must be shown"
  pass "checkpoint: a handed-back wake passes through, and a host stand-down is a failure"
}

# The real host under a fake Codex harness that holds the home's session lock.
# shellcheck disable=SC2016 # the fake harness's script expands in its own shell
test_real_host_checkpoint_ends_quietly_at_its_bound() {
  local home fakebin status
  home=$(make_home host-real)
  : > "$home/config/supervision-host"
  fakebin="$TMP_ROOT/host-real-bin"
  mkdir -p "$fakebin"
  ln -s /bin/bash "$fakebin/codex"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$fakebin/codex" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$0" --seconds 4
  ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 124 "$status" "a quiet host checkpoint: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 4s" "the real host's boundary must read as the quiet line"
  assert_grep '	boundary	' "$home/state/.supervision-host.log" "the host must have ended its own park"
  if [ -e "$home/state/.watch.lock/pid" ] && kill -0 "$(cat "$home/state/.watch.lock/pid")" 2>/dev/null; then
    fail "a host checkpoint left its watcher running"
  fi
  pass "checkpoint: the real host ends its park at the checkpoint bound as a quiet checkpoint"
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
  assert_contains "$out" 'revisit due programs and surfaced program errors' "program wake did not preserve due-only reconciliation"
  assert_not_contains "$out" 'revisit all unfinished programs' "program wake invited a future-only reconciliation"
  assert_contains "$out" 'product-a' "due project absent from wake"
  assert_not_contains "$out" 'uncommissioned' "queued idea silently commissioned"
  # Outstanding event is durable and never multiplied by another tick.
  FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"; fm_program_reconcile_tick "$2/state"' _ "$ROOT" "$home" >/dev/null
  [ "$(awk -F '\t' '$3 == "check" && $4 == "program-reconcile" {n++} END {print n+0}' "$home/state/.wake-queue")" -eq 1 ]     || fail "duplicate program event while unacknowledged"
  pass "multiple accepted projects survive zero workers and one child finishing, with durable deduplicated wake"
}

test_program_future_pause_and_parse_failure() {
  local home parse_home status out projection
  home=$(make_home future-program)
  parse_home=$(make_home malformed-commissioning)
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
  cat > "$parse_home/data/backlog.md" <<'EOF'
## In flight
Accepted programmer note (kind: programmer)
## Queued
Uncommissioned idea (kind: program)
EOF
  projection=$(FM_HOME="$parse_home" "$ROOT/bin/fm-programs.sh" --json) || fail "non-program projection failed"
  printf '%s' "$projection" | jq -e '
    (.supervision_needed | not) and (.programs | length == 0) and (.errors | length == 0)
  ' >/dev/null || fail "queued or prefix-matched non-program text created commissioned work"
  cat > "$parse_home/data/backlog.md" <<'EOF'
## In flight
Malformed accepted commission (kind: program)
Accepted programmer note (kind: programmer)
## Queued
Uncommissioned idea (kind: program)
EOF
  projection=$(FM_HOME="$parse_home" "$ROOT/bin/fm-programs.sh" --json) || fail "malformed program projection failed"
  printf '%s' "$projection" | jq -e '
    .supervision_needed and (.programs | length == 0)
    and (.errors == [{"id":"unparseable-program","errors":["malformed program backlog row"]}])
  ' >/dev/null || fail "exact in-flight malformed program commissioning was not isolated"
  pass "future, pause, timing, and exact malformed commissioning boundaries remain visible"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_host_checkpoint_bounds_the_park_by_posture
test_host_checkpoint_passes_a_handback_and_reports_a_stand_down
test_real_host_checkpoint_ends_quietly_at_its_bound

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

test_future_program_receipt_surfaces_malformed_transition() {
  local home json bearings out
  home=$(make_home future-malformed-program)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] future-delivery - Future accepted delivery (repo: alpha) (kind: program)
  recheck-at: 2099-01-01T00:00:00Z
EOF
  out=$(FM_HOME="$home" FM_PROGRAM_NOW_EPOCH=1000 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$home") || fail "future-only quiet tick failed"
  [ -z "$out" ] || fail "future-only program reconciled before its due time"
  [ ! -s "$home/state/.wake-queue" ] || fail "future-only program emitted an early wake"

  printf '## In flight\n- [ ] future-delivery - Future accepted delivery (repo: alpha) (kind: mystery)\n' > "$home/data/backlog.md"
  json=$(FM_HOME="$home" "$ROOT/bin/fm-programs.sh" --json) || fail "future malformed CLI projection unavailable"
  printf '%s' "$json" | jq -e '
    .supervision_needed
    and (.programs | length == 0)
    and (.errors | any(.id == "future-delivery" and (.errors | length) > 0))
  ' >/dev/null || fail "future-only receipt lost its malformed transition in the full CLI"
  FM_HOME="$home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2/state"' _ "$ROOT" "$home" \
    || fail "future-only malformed transition stopped shared zero-worker supervision"
  bearings=$(FM_HOME="$home" FM_SNAPSHOT_NOW=2026-09-13T00:00:01Z FM_SNAPSHOT_NOW_EPOCH=1001 \
    "$ROOT/bin/fm-bearings-snapshot.sh" --json) || fail "future malformed Bearings projection unavailable"
  printf '%s' "$bearings" | jq -e '
    (.programs | length == 0)
    and (.program_errors | any(.id == "future-delivery" and (.errors | contains("previously observed unfinished program"))))
  ' >/dev/null || fail "compact Bearings dropped the canonical continuity error"
  out=$(FM_HOME="$home" FM_PROGRAM_NOW_EPOCH=1001 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$home") || fail "future malformed transition did not reconcile"
  assert_contains "$out" 'program-reconcile' "future malformed transition emitted no durable wake"
  printf '## Done\n- [x] future-delivery - Future accepted delivery (repo: alpha) (kind: mystery)\n' > "$home/data/backlog.md"
  json=$(FM_HOME="$home" "$ROOT/bin/fm-programs.sh" --json) || fail "malformed Done CLI projection unavailable"
  printf '%s' "$json" | jq -e '
    .supervision_needed
    and (.programs | length == 0)
    and (.errors | any(.id == "future-delivery" and (.errors | length) > 0))
    and (.observed_unfinished_program_ids | contains(["future-delivery"]))
  ' >/dev/null || fail "malformed Done row silently retired a previously observed program"
  FM_HOME="$home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2/state"' _ "$ROOT" "$home" \
    || fail "malformed Done row stopped shared supervision"
  [ -e "$home/state/.program-reconciliation" ] || fail "malformed Done row discarded its continuity receipt"
  pass "future receipts preserve malformed in-flight and Done continuity through every projection"
}
test_future_program_receipt_surfaces_malformed_transition

test_program_receipt_sync_transitions() {
  local home concurrent lost duplicate json out first_emission second_emission
  home=$(make_home receipt-cleanup)
  concurrent=$(make_home receipt-concurrent)
  lost=$(make_home receipt-loss)
  duplicate=$(make_home receipt-duplicate)

  printf '## In flight\n- [ ] release - Accepted release (repo: alpha) (kind: program)\n' > "$home/data/backlog.md"
  out=$(FM_HOME="$home" FM_PROGRAM_NOW_EPOCH=1000 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$home") || fail "cleanup fixture did not queue its due wake"
  assert_contains "$out" 'program-reconcile' "cleanup fixture emitted no due wake"
  printf '## Done\n- [x] release - Accepted release (repo: alpha) (kind: program)\n' > "$home/data/backlog.md"
  json=$(FM_HOME="$home" "$ROOT/bin/fm-programs.sh" --json) || fail "observed Done projection failed"
  printf '%s' "$json" | jq -e '
    .receipt_sync_needed and .supervision_needed
    and (.programs | length == 0) and (.errors | length == 0)
  ' >/dev/null || fail "observed valid Done did not request receipt cleanup"
  FM_HOME="$home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2/state"' _ "$ROOT" "$home" \
    || fail "shared supervision went idle before Done receipt cleanup"
  out=$(FM_HOME="$home" FM_PROGRAM_NOW_EPOCH=1001 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$home") || fail "Done receipt cleanup tick failed"
  [ -z "$out" ] || fail "Done receipt cleanup emitted a duplicate wake"
  [ ! -e "$home/state/.program-reconciliation" ] || fail "Done receipt cleanup retained stale identity"
  printf '## Done\n' > "$home/data/backlog.md"
  out=$(FM_HOME="$home" FM_PROGRAM_NOW_EPOCH=1002 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$home") || fail "pruned Done tick failed"
  [ -z "$out" ] || fail "ordinary Done pruning emitted an alarm"
  if FM_HOME="$home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2/state"' _ "$ROOT" "$home"; then
    fail "ordinary Done pruning left permanent supervision"
  fi

  printf '## In flight\n- [ ] primary - Primary delivery (repo: alpha) (kind: program)\n' > "$concurrent/data/backlog.md"
  FM_HOME="$concurrent" FM_PROGRAM_NOW_EPOCH=2000 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$concurrent" >/dev/null || fail "concurrent fixture did not queue its first wake"
  first_emission=$(cut -f1-2 "$concurrent/state/.program-reconciliation")
  cat > "$concurrent/data/backlog.md" <<'EOF'
## In flight
- [ ] primary - Primary delivery (repo: alpha) (kind: program)
- [ ] future - Future delivery (repo: beta) (kind: program)
  recheck-at: 2099-01-01T00:00:00Z
EOF
  out=$(FM_HOME="$concurrent" FM_PROGRAM_NOW_EPOCH=2001 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$concurrent") || fail "queued-event observation tick failed"
  [ -z "$out" ] || fail "queued-event observation duplicated its wake"
  second_emission=$(cut -f1-2 "$concurrent/state/.program-reconciliation")
  [ "$second_emission" = "$first_emission" ] || fail "identity bookkeeping changed the emission receipt"
  cut -f3 "$concurrent/state/.program-reconciliation" | jq -e 'contains(["primary","future"])' >/dev/null \
    || fail "queued-event dedupe lost a newly observed future program"
  cat > "$concurrent/data/backlog.md" <<'EOF'
## In flight
- [ ] future - Future delivery (repo: beta) (kind: mystery)
## Done
- [x] primary - Primary delivery (repo: alpha) (kind: program)
EOF
  json=$(FM_HOME="$concurrent" "$ROOT/bin/fm-programs.sh" --json) || fail "concurrent malformed projection failed"
  printf '%s' "$json" | jq -e '
    .supervision_needed
    and (.errors | any(.id == "future" and (.errors | length) > 0))
    and (.observed_unfinished_program_ids == ["future"])
  ' >/dev/null || fail "queued-event identity sync lost the later malformed program"

  cat > "$lost/data/backlog.md" <<'EOF'
## In flight
- [ ] future - Future delivery (repo: gamma) (kind: program)
  recheck-at: 2099-01-01T00:00:00Z
EOF
  FM_HOME="$lost" FM_PROGRAM_NOW_EPOCH=3000 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-programs-lib.sh"
    fm_program_reconcile_tick "$2/state"
  ' _ "$ROOT" "$lost" >/dev/null || fail "receipt-loss fixture observation failed"
  rm -f "$lost/state/.program-reconciliation"
  printf '## In flight\n- [ ] future - Future delivery (repo: gamma) (kind: mystery)\n' > "$lost/data/backlog.md"
  json=$(FM_HOME="$lost" "$ROOT/bin/fm-programs.sh" --json) || fail "receipt-loss projection failed"
  printf '%s' "$json" | jq -e '
    (.supervision_needed | not) and (.programs | length == 0) and (.errors | length == 0)
  ' >/dev/null || fail "receipt loss invented historical program evidence"

  printf '## In flight\n- [ ] same - First (repo: delta) (kind: program)\n- [ ] same - Second (repo: delta) (kind: program)\n' > "$duplicate/data/backlog.md"
  json=$(FM_HOME="$duplicate" "$ROOT/bin/fm-programs.sh" --json) || fail "duplicate program projection failed"
  printf '%s' "$json" | jq -e '
    .supervision_needed and (.errors | any(.id == "same" and (.errors | contains(["duplicate program id"]))))
  ' >/dev/null || fail "duplicate program IDs did not remain visible"
  pass "program receipts synchronize Done, queued-event, loss, and duplicate transitions"
}
test_program_receipt_sync_transitions

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
