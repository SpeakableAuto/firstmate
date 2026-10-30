#!/usr/bin/env bash
# Admission uses live endpoints, never historical metadata or unrelated holds.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-workers)

# Test the shared public count contract at a fixed clock. Vendor classification
# remains covered by the backend suites; no lifecycle operation runs here.
test_count_contract() (
  # shellcheck source=bin/fm-claude-admission-lib.sh
  . "$ROOT/bin/fm-claude-admission-lib.sh"
  local state="$TMP_ROOT/count" backend verdict
  mkdir -p "$state"
  date() { printf '2000000000\n'; }
  fm_backend_source() { return 0; }
  fm_backend_agent_state() { printf '%s' "$2"; }
  for backend in tmux herdr orca cmux zellij; do
    for verdict in alive missing dead gone unproven-absent; do
      fm_write_meta "$state/worker.meta" "backend=$backend" "window=$verdict" 'kind=ship' 'harness=claude'
      fm_live_workers_count "$state" '' || fail "$backend $verdict count failed"
      if [ "$verdict" = alive ]; then expected=1; else expected=0; fi
      assert_equals "$expected" "$FM_LIVE_WORKERS_COUNT" "$backend $verdict count"
    done
    fm_write_meta "$state/worker.meta" "backend=$backend" 'window=unverified' 'kind=ship' 'harness=claude'
    if fm_live_workers_count "$state" '' 2>/dev/null; then fail "$backend unverified count accepted"; fi
    assert_equals "crew liveness unreadable: $backend" "$FM_LIVE_WORKERS_ERROR" 'named refusal'
  done
  fm_write_meta "$state/worker.meta" 'backend=tmux' 'window=missing' 'kind=ship' 'harness=claude' 'spawn_gen=s1999999941.1'
  fm_live_workers_count "$state" ''
  assert_equals 1 "$FM_LIVE_WORKERS_COUNT" '59-second launch reservation'
  fm_live_workers_count "$state" worker
  assert_equals 0 "$FM_LIVE_WORKERS_COUNT" 'relaunch excludes own reservation'
  sed 's/1999999941/1999999940/' "$state/worker.meta" > "$state/next"
  mv "$state/next" "$state/worker.meta"
  fm_live_workers_count "$state" ''
  assert_equals 0 "$FM_LIVE_WORKERS_COUNT" '60-second reservation expires'
  fm_write_meta "$state/mate.meta" 'backend=unknown' 'kind=secondmate' 'spawn_gen=s2000000000.1'
  fm_live_workers_count "$state" ''
  assert_equals 0 "$FM_LIVE_WORKERS_COUNT" 'secondmates never reserve crew slots'
  for n in $(seq 1 65); do
    fm_write_meta "$state/old-$n.meta" 'backend=tmux' 'window=missing' 'kind=ship' 'harness=claude'
  done
  fm_claude_admission_count "$state" '' ordinary
  assert_equals 0 "$FM_CLAUDE_ADMISSION_COUNT" 'Claude account excludes parked records'
  printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"claude"}]}' > "$TMP_ROOT/count-quota.json"
  fm_quota_pacing_count "$state" "$TMP_ROOT/count-quota.json" '' claude default
  assert_equals 0 "$FM_QUOTA_PACING_COUNT" 'quota pacing excludes parked records'
  fm_write_meta "$state/worker.meta" 'backend=tmux' 'window=alive' 'kind=ship' 'harness=claude' 'account=other'
  fm_claude_admission_count "$state" '' ordinary
  assert_equals 0 "$FM_CLAUDE_ADMISSION_COUNT" 'other account excluded'
  fm_claude_admission_count "$state" '' other
  assert_equals 1 "$FM_CLAUDE_ADMISSION_COUNT" 'selected account counted'
  fm_write_meta "$state/worker.meta" 'backend=tmux' 'window=unreadable' 'kind=ship' 'harness=claude'
  if fm_claude_admission_count "$state" '' ordinary 2>/dev/null; then fail 'Claude swallowed liveness failure'; fi
  if fm_quota_pacing_count "$state" "$TMP_ROOT/count-quota.json" '' claude default 2>/dev/null; then fail 'pacing swallowed liveness failure'; fi
  pass 'shared count: backend verdicts, grace, exclusions, account filters, and failure propagation'
)
test_count_contract

make_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/tools" codex)
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" ready-task
  fm_git_worktree "$CASE/project" "$WT" fixture
  mv "$FAKEBIN/tmux" "$FAKEBIN/tmux-base"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows)
    if [ "${LIVE_TEST_UNREADABLE:-0}" = 1 ]; then echo 'inventory transport failed' >&2; exit 1; fi
    printf '%s\n' "${LIVE_TEST_WINDOWS:-}"
    exit 0 ;;
  display-message)
    case "$*" in *pane_current_command*) echo codex; exit 0 ;; esac ;;
esac
exec "$(dirname "$0")/tmux-base" "$@"
SH
  chmod +x "$FAKEBIN/tmux"
  unset LIVE_TEST_UNREADABLE LIVE_TEST_WINDOWS
  local n
  for n in $(seq 1 65); do
    fm_write_meta "$HOME_DIR/state/old-$n.meta" 'backend=tmux' "window=firstmate:old-$n" 'kind=ship' 'harness=codex' 'spawn_gen=s1.1'
  done
  cp -R "$HOME_DIR/state" "$CASE/before"
}

spawn() {
  fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" ready-task "$CASE/project" --mode direct-PR --yolo off
}

for posture in normal away quiet; do
  make_case "$posture"
  if [ "$posture" != normal ]; then
    FM_HOME="$HOME_DIR" FM_AFK_MODE="$posture" "$ROOT/bin/fm-afk-contract.sh" enter --spend 4 >/dev/null
  fi
  out=$(spawn) || fail "$posture: 65 parked records refused spawn: $out"
  assert_present "$HOME_DIR/state/ready-task.meta" "$posture: no worker published"
  for n in $(seq 1 65); do
    cmp "$CASE/before/old-$n.meta" "$HOME_DIR/state/old-$n.meta" || fail 'old record changed'
  done
  pass "$posture: 65 parked records admit spawn and remain unchanged"
done

make_case cap
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-afk-contract.sh" enter --spend 4 >/dev/null
export LIVE_TEST_WINDOWS=$'old-1\nold-2\nold-3\nold-4'
if out=$(spawn); then fail 'four live workers admitted at cap four'; fi
assert_contains "$out" 'caps concurrent workers at 4 and 4 ordinary task(s) are live' 'live cap refusal'
assert_absent "$HOME_DIR/state/ready-task.meta" 'refused task published'
pass 'four live workers refuse at cap four'

make_case unreadable
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-afk-contract.sh" enter --spend 4 >/dev/null
export LIVE_TEST_UNREADABLE=1
if out=$(spawn); then fail 'unreadable backend admitted spawn'; fi
assert_contains "$out" 'crew liveness unreadable: tmux' 'unreadable must name backend'
pass 'backend failure refuses with named liveness reason'

# One real tasks-axi fixture, reused without closing any held item. Exercise
# the hold writer too, then drive ready -> spawn through the actual backlog gate.
if command -v tasks-axi >/dev/null 2>&1; then
  make_case holds-seed
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  tasks() { FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" "$@"; }
  for n in $(seq 1 100); do
    tasks add "held-$n" 'Pending decision' >/dev/null
    tasks hold "held-$n" --reason 'Decision pending' --kind captain >/dev/null
  done
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-captain-hold.sh" hold held-1 --reason 'Decision pending' >/dev/null
  tasks add blocked-task 'Waiting on another task' >/dev/null
  tasks block blocked-task --by held-1 >/dev/null
  tasks add ready-task 'Independent queued task' >/dev/null
  cp "$HOME_DIR/data/backlog.md" "$TMP_ROOT/held-backlog.md"
  for posture in normal away quiet; do
    make_case "holds-$posture"
    cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
    cp "$TMP_ROOT/held-backlog.md" "$HOME_DIR/data/backlog.md"
    if [ "$posture" != normal ]; then
      FM_HOME="$HOME_DIR" FM_AFK_MODE="$posture" "$ROOT/bin/fm-afk-contract.sh" enter --spend 4 >/dev/null
    fi
    out=$(tasks ready)
    assert_contains "$out" ready-task 'ready task disappeared behind holds'
    assert_not_contains "$out" held-1 'held task became dispatchable'
    assert_not_contains "$out" blocked-task 'dependent task became dispatchable'
    tasks show held-1 > "$CASE/held-before"
    # Away dispatch also exercises the relocated supervisor's queued-row gate.
    if [ "$posture" = away ]; then
      out=$(FM_SUPERVISION_ACTOR=branch spawn) || fail "away branch dispatch with holds: $out"
    else
      out=$(spawn) || fail "$posture dispatch with holds: $out"
    fi
    assert_contains "$(tasks show ready-task)" 'state: in_flight' 'ready task did not dispatch'
    tasks show held-1 > "$CASE/held-after"
    cmp "$CASE/held-before" "$CASE/held-after" || fail 'dispatch changed unrelated hold'
    # Every held row is still present and held after dispatch.
    out=$(tasks ready --include-held)
    assert_contains "$out" 'held[100]' 'dispatch lost held work'
    pass "$posture: 100 held decisions and one blocked task do not stop independent dispatch"
  done
else
  echo 'skip: tasks-axi not found (hold/ready integration)'
fi
