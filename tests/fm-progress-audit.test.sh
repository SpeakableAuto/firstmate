#!/usr/bin/env bash
# tests/fm-progress-audit.test.sh - the progress audit judges crews by landed
# work, accounts for every record, and recovers by cause at most twice.
#
# Hermetic: a real git repository with a local bare origin supplies push and
# commit evidence, while the endpoint classifier, current-state read, steer and
# relaunch are stubbed through the script's documented seams so each cause is
# driven deliberately. The clock is pinned with FM_PROGRESS_AUDIT_NOW.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUDIT="$ROOT/bin/fm-progress-audit.sh"
T=$(fm_test_tmproot fm-progress-audit) || fail "could not create a temp root"
HOME_DIR="$T/home"
STATE="$HOME_DIR/state"
STUBS="$T/stubs"
mkdir -p "$STATE" "$HOME_DIR/data" "$STUBS"

fm_git_identity
fm_git_worktree "$T/repo" "$T/wt" fm/busy
WT="$T/wt"
REAL_NOW=$(date +%s)
WINDOW=2400

cat > "$STUBS/agent-state" <<'SH'
#!/usr/bin/env bash
f="$FM_TEST_STUBS/agent-${2#lab:}"
if [ -f "$f" ]; then cat "$f"; else printf alive; fi
SH
cat > "$STUBS/crew-state" <<'SH'
#!/usr/bin/env bash
f="$FM_TEST_STUBS/cs-$1"
if [ -f "$f" ]; then cat "$f"; else echo "state: unknown · source: none · stub"; fi
SH
cat > "$STUBS/send" <<'SH'
#!/usr/bin/env bash
printf 'send %s\n' "$*" >> "$FM_TEST_STUBS/calls"
exit "$(cat "$FM_TEST_STUBS/send-rc" 2>/dev/null || echo 0)"
SH
cat > "$STUBS/control" <<'SH'
#!/usr/bin/env bash
printf 'control %s\n' "$*" >> "$FM_TEST_STUBS/calls"
exit "$(cat "$FM_TEST_STUBS/control-rc" 2>/dev/null || echo 0)"
SH
cat > "$STUBS/freshness" <<'SH'
#!/usr/bin/env bash
echo "checkpoint fresh: stub"
SH
chmod +x "$STUBS"/*

audit() {  # <now> <args...>
  local now=$1
  shift
  env FM_HOME="$HOME_DIR" FM_TEST_STUBS="$STUBS" FM_PROGRESS_AUDIT_NOW="$now" \
    FM_PROGRESS_WINDOW_SECS="$WINDOW" \
    FM_PROGRESS_AGENT_STATE_BIN="$STUBS/agent-state" \
    FM_PROGRESS_CREW_STATE_BIN="$STUBS/crew-state" \
    FM_PROGRESS_SEND_BIN="$STUBS/send" \
    FM_PROGRESS_CONTROL_BIN="$STUBS/control" \
    FM_PROGRESS_FRESHNESS_BIN="$STUBS/freshness" \
    "$AUDIT" "$@"
}

crew() {  # <id> [kind] [worktree]
  fm_write_meta "$STATE/$1.meta" \
    "window=lab:$1" "endpoint_task_id=$1" "worktree=${3:-$WT}" "project=$T/repo" \
    "harness=claude" "kind=${2:-ship}" "mode=direct-PR" "yolo=off" "branch=fm/$1" \
    "spawn_gen=s$((REAL_NOW - 100)).1.1"
}

status() {  # <id> <line>
  printf '%s\n' "$2" >> "$STATE/$1.status"
}

line_for() {  # <account-output> <id>
  printf '%s\n' "$1" | grep "^$2 · " || true
}

# --- the roll-call: every record lands in exactly one bucket ------------------

crew busy                       # busy pane, nothing landed: judged stalled anyway
echo "state: working · source: pane · busy" > "$STUBS/cs-busy"
crew validating
echo "state: working · source: run-step · run abc running" > "$STUBS/cs-validating"
crew exited
printf dead > "$STUBS/agent-exited"
crew gone
printf missing > "$STUBS/agent-gone"
crew nocopy ship "$T/no-such-copy"
crew pushed
git -C "$WT" checkout -q -b fm/pushed
git -C "$WT" commit -q --allow-empty -m checkpoint
git -C "$WT" push -q origin HEAD:refs/heads/fm/pushed
git -C "$WT" checkout -q fm/busy
crew waiting-pause
status waiting-pause "paused [at=$REAL_NOW]: waiting on the review until 2099-01-01T00:00Z"
crew overdue-pause
status overdue-pause "paused [at=$((REAL_NOW - 9000))]: waiting until $(TZ=UTC0 date -u -r $((REAL_NOW - 8000)) +%Y-%m-%dT%H:%MZ 2>/dev/null || TZ=UTC0 date -u -d @$((REAL_NOW - 8000)) +%Y-%m-%dT%H:%MZ)"
crew asking
status asking "needs-decision [key=shape] [at=$((REAL_NOW - 9000))]: pick a shape"
crew finished scout
status finished "done [at=$((REAL_NOW - 9000))]: report written"
fm_write_secondmate_meta "$STATE/mate.meta" "$T/mate-home"

LATER=$((REAL_NOW + WINDOW + 600))
OUT=$(audit "$LATER" account) || fail "account failed: $OUT"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 11 ] \
  || fail "account must print exactly one line per record (11), got: $OUT"
for id in busy validating exited gone nocopy pushed waiting-pause overdue-pause asking finished mate; do
  [ "$(printf '%s\n' "$OUT" | grep -c "^$id · ")" = 1 ] || fail "record $id is not accounted for exactly once: $OUT"
done
assert_contains "$(line_for "$OUT" busy)" "busy · stalled · no-progress" \
  "a busy pane that landed nothing is stalled: judged by landed work, not by the pane"
assert_contains "$(line_for "$OUT" busy)" "next=steer" "the first recovery for a live agent is a steer"
assert_contains "$(line_for "$OUT" validating)" "validating · waiting · validation run" \
  "an active validation run waits instead of stalling"
assert_contains "$(line_for "$OUT" exited)" "exited · stalled · agent-exited" "an exited agent is stalled by cause"
assert_contains "$(line_for "$OUT" exited)" "next=relaunch" "an exited agent is relaunched"
assert_contains "$(line_for "$OUT" gone)" "gone · missing · endpoint-gone" "a gone endpoint is missing"
assert_contains "$(line_for "$OUT" nocopy)" "nocopy · missing · worktree-gone" "a gone local copy is missing"
assert_contains "$(line_for "$OUT" nocopy)" "next=escalate" "a gone local copy escalates without a retry"
assert_contains "$(line_for "$OUT" waiting-pause)" "waiting · paused until 2099-01-01T00:00Z" "a future pause waits"
assert_contains "$(line_for "$OUT" overdue-pause)" "stalled · pause-overdue" "a long-overdue pause with nothing landed stalls"
assert_contains "$(line_for "$OUT" asking)" "asking · waiting · open needs-decision [key=shape] for firstmate" \
  "an open decision waits on firstmate"
assert_contains "$(line_for "$OUT" finished)" "finished · finished · done" "a done crew is finished"
assert_contains "$(line_for "$OUT" mate)" "mate · waiting · secondmate" "a secondmate is accounted for"
pass "account places every record in exactly one bucket with its cause or reason"

OUT=$(audit "$((REAL_NOW + 60))" account pushed busy) || fail "account by id failed: $OUT"
assert_contains "$(line_for "$OUT" pushed)" "pushed · live · landed a push" "a fresh push keeps a crew live"
assert_contains "$(line_for "$OUT" busy)" "busy · live · landed a commit" "a fresh commit keeps a crew live"
OUT=$(audit "$((REAL_NOW + WINDOW + 600))" account pushed) || fail "account by id failed: $OUT"
assert_contains "$OUT" "pushed · stalled · no-progress · progress=push@" \
  "an old push no longer keeps a crew live once the window passes"
crew fresh "" "$T/plain-copy"
mkdir -p "$T/plain-copy"
OUT=$(audit "$((REAL_NOW + 60))" account fresh) || fail "account by id failed: $OUT"
assert_contains "$OUT" "fresh · live · inside its window since" "a fresh spawn keeps a crew live before it lands anything"
rm -f "$STATE/fresh.meta"
pass "pushes, commits and a fresh start keep a crew live only inside the window"

# --- recovery by cause, at most twice, then one escalation --------------------

T1=$LATER
OUT=$(audit "$T1" recover busy --dry-run) || fail "dry run failed: $OUT"
assert_contains "$OUT" "would steer busy (cause no-progress, attempt 1 of 2)" "dry run names the due action"
assert_absent "$STATE/busy.recovery" "a dry run must not record an attempt"
OUT=$(audit "$T1" recover busy) || fail "first recovery failed: $OUT"
assert_contains "$OUT" "steer busy: cause no-progress, attempt 1 of 2" "attempt 1 steers"
assert_grep "send busy Progress check:" "$STUBS/calls" "the steer goes through fm-send to the task"
OUT=$(audit "$T1" account busy)
assert_contains "$OUT" "busy · live" "a recovery attempt restarts the window"
T2=$((T1 + WINDOW + 1))
mkdir -p "$STATE/busy.inbox/handled"
echo "keep the API shape" > "$STATE/busy.inbox/handled/001.msg"
status busy "working [at=$((REAL_NOW - 50000))]: an old line that predates every attempt"
OUT=$(audit "$T2" account busy)
assert_contains "$OUT" "attempts=1/2 · next=relaunch" "attempt 2 for a live agent is a relaunch"
OUT=$(audit "$T2" recover busy) || fail "second recovery failed: $OUT"
assert_contains "$OUT" "relaunch busy: cause no-progress, attempt 2 of 2" "attempt 2 relaunches"
assert_grep "control busy relaunch --note Relaunched by the progress check: cause no-progress, attempt 2 of 2." \
  "$STUBS/calls" "the relaunch goes through fm-control with a consolidated note"
assert_grep "001.msg in $STATE/busy.inbox/handled" "$STUBS/calls" \
  "the relaunch note carries the directives the previous worker acknowledged"
assert_grep "checkpoint fresh: stub" "$STUBS/calls" "a ship's relaunch note carries checkpoint freshness"
T3=$((T2 + WINDOW + 1))
rc=0; OUT=$(audit "$T3" recover busy) || rc=$?
expect_code 3 "$rc" "the third due action is an escalation"
assert_contains "$OUT" "escalate: busy stalled (no-progress) after 2 recovery attempt(s)" "the escalation names the cause and attempts"
[ "$(grep -cE '^(control|send) ' "$STUBS/calls")" = 2 ] || fail "an escalation must not act on the crew again"
OUT=$(audit "$T3" recover busy) || fail "a recovery after escalation should exit 0: $OUT"
assert_contains "$OUT" "nothing due: busy was already escalated" "the escalation happens once"
pass "a stalled crew is steered, then relaunched, then escalated exactly once"

mkdir -p "$HOME_DIR/data/busy"
echo "findings" > "$HOME_DIR/data/busy/report.md"
fm_touch_epoch "$((T3 + 10))" "$HOME_DIR/data/busy/report.md"
OUT=$(audit "$((T3 + WINDOW + 15))" account busy)
assert_contains "$OUT" "attempts=0/2 · next=steer" "landed progress earns a fresh allowance"
pass "progress landed after recovery resets the allowance"

# A looping crew that answers every steer with a status line and lands nothing
# still reaches the cap: a status line keeps the window fresh, never the
# allowance.
: > "$STUBS/calls"
crew looper
L=$LATER
for n in 1 2; do
  OUT=$(audit "$L" recover looper) || fail "looper recovery $n failed: $OUT"
  assert_contains "$OUT" "attempt $n of 2" "looper attempt $n is counted"
  status looper "working [at=$((L + 10))]: still on it"
  OUT=$(audit "$((L + 20))" account looper)
  assert_contains "$OUT" "looper · live" "a status line keeps the window fresh"
  L=$((L + 10 + WINDOW + 1))
  OUT=$(audit "$L" account looper)
  assert_contains "$OUT" "attempts=$n/2" "a status line does not reset the allowance after attempt $n"
done
assert_grep "send looper Progress check:" "$STUBS/calls" "the looper's first recovery is a steer"
assert_grep "control looper relaunch" "$STUBS/calls" "the looper's second recovery is a relaunch"
rc=0; OUT=$(audit "$L" recover looper) || rc=$?
expect_code 3 "$rc" "a looper that only answers with status lines escalates after two attempts"
assert_contains "$OUT" "escalate: looper stalled (no-progress) after 2 recovery attempt(s)" "the looper escalation names the cause"
pass "status lines alone never reset the two-attempt allowance"

: > "$STUBS/calls"
echo 1 > "$STUBS/control-rc"
rc=0; OUT=$(audit "$LATER" recover exited) || rc=$?
expect_code 1 "$rc" "a failed relaunch reports failure"
assert_contains "$OUT" "relaunch exited failed (cause agent-exited, attempt 1 of 2)" "the failure is named"
# A relaunch that launched something before failing its own checks rewrites
# the spawn generation; that launch is not a fresh start.
sed -i.bak "s/^spawn_gen=.*/spawn_gen=s$LATER.2.2/" "$STATE/exited.meta" && rm -f "$STATE/exited.meta.bak"
OUT=$(audit "$LATER" account exited)
assert_contains "$OUT" "exited · stalled · agent-exited" "a failed attempt does not restart the window"
assert_contains "$OUT" "attempts=1/2 · next=relaunch" "a failed attempt still spends one of the two"
rm -f "$STUBS/control-rc"
pass "a failed action counts as an attempt and leaves the next one due at once"

rc=0; OUT=$(audit "$LATER" recover nocopy) || rc=$?
expect_code 3 "$rc" "a gone local copy escalates at once"
assert_contains "$OUT" "no recovery can run" "the escalation says no retry is possible"
rc=0; OUT=$(audit "$LATER" recover no-such-task 2>&1) || rc=$?
expect_code 2 "$rc" "recover refuses an id with no task record"
rc=0; OUT=$(audit "$LATER" recover validating) || rc=$?
expect_code 0 "$rc" "nothing is due for a waiting crew"
assert_contains "$OUT" "nothing due: validating is waiting" "recover never acts on a waiting crew"
pass "recover refuses unknown ids and leaves waiting crews alone"

crew deadrun
printf dead > "$STUBS/agent-deadrun"
echo "state: working · source: run-step · run def running" > "$STUBS/cs-deadrun"
OUT=$(audit "$LATER" account deadrun)
assert_contains "$OUT" "deadrun · waiting · validation run" "an active validation run waits even with its agent gone"
rm -f "$STUBS/cs-deadrun"
OUT=$(audit "$LATER" account deadrun)
assert_contains "$OUT" "deadrun · stalled · agent-exited" "once the run stops, the gone agent is due a relaunch"
pass "a dead agent with an active validation run waits for the run"

crew abandoned
OUT=$(audit "$((REAL_NOW + 90000))" account abandoned)
assert_contains "$OUT" "abandoned · stalled · long-idle" "a record idle past the long-idle bound is long-idle"
assert_contains "$OUT" "next=escalate" "a long-idle record escalates instead of relaunching stale work"
: > "$STUBS/calls"
rc=0; OUT=$(audit "$((REAL_NOW + 90000))" recover abandoned) || rc=$?
expect_code 3 "$rc" "a long-idle record escalates at once"
assert_contains "$OUT" "too stale for an automatic retry" "the long-idle escalation asks for hand reconciliation"
[ ! -s "$STUBS/calls" ] || fail "a long-idle record must not be steered or relaunched: $(cat "$STUBS/calls")"
pass "a record abandoned past the long-idle bound goes to hand reconciliation"

ABSENT_VOL="/Volumes/fm-progress-audit-absent-$$"
[ ! -e "$ABSENT_VOL" ] || fail "test volume path unexpectedly exists: $ABSENT_VOL"
crew offdrive1 ship "$ABSENT_VOL/pool/1/copy"
crew offdrive2 ship "$ABSENT_VOL/pool/2/copy"
OUT=$(audit "$LATER" account offdrive1 offdrive2)
assert_contains "$(line_for "$OUT" offdrive1)" "offdrive1 · waiting · storage unavailable: " \
  "a copy on unreachable storage waits instead of escalating"
assert_contains "$(line_for "$OUT" offdrive2)" "next=-" "unreachable storage never makes a per-crew escalation due"
rc=0; OUT=$(audit "$LATER" recover offdrive1) || rc=$?
expect_code 0 "$rc" "nothing is due for a copy on unreachable storage"
rm -f "$STATE/offdrive1.meta" "$STATE/offdrive2.meta"
pass "missing storage is a wait, not a mass escalation"

# --- tick: bounded cadence, one durable wake per new finding ------------------

TICK_HOME="$T/tick-home"
mkdir -p "$TICK_HOME/state"
STATE="$TICK_HOME/state"
crew stuck
printf dead > "$STUBS/agent-stuck"
crew healthy
status healthy "working [at=$((LATER - 60))]: fresh"

tick() {  # <now> <args...>
  local now=$1
  shift
  env FM_HOME="$TICK_HOME" FM_TEST_STUBS="$STUBS" FM_PROGRESS_AUDIT_NOW="$now" \
    FM_PROGRESS_WINDOW_SECS="$WINDOW" FM_PROGRESS_AUDIT_SECS=600 \
    FM_PROGRESS_AGENT_STATE_BIN="$STUBS/agent-state" \
    FM_PROGRESS_CREW_STATE_BIN="$STUBS/crew-state" \
    FM_PROGRESS_SEND_BIN="$STUBS/send" FM_PROGRESS_CONTROL_BIN="$STUBS/control" \
    FM_PROGRESS_FRESHNESS_BIN="$STUBS/freshness" \
    "$AUDIT" "$@"
}
age_marker() {  # <epoch>
  fm_touch_epoch "$1" "$STATE/.progress-audit/.last-tick"
}

OUT=$(tick "$LATER" tick) || fail "first tick failed"
assert_equals "" "$OUT" "the first tick in a home only starts the cadence"
assert_present "$STATE/.progress-audit/.last-tick" "the first tick records the cadence marker"
age_marker "$((LATER - 30))"
OUT=$(tick "$LATER" tick) || fail "an early tick failed"
assert_equals "" "$OUT" "a tick inside the cadence does nothing"
age_marker "$((LATER - 601))"
OUT=$(tick "$LATER" tick) || fail "a due tick failed"
assert_contains "$OUT" "wake: check: progress-audit: 1 crew need recovery by cause (stuck stalled agent-exited, next relaunch)" \
  "a due tick surfaces the stalled crew with its cause and next action"
assert_not_contains "$OUT" healthy "a live crew is not surfaced"
assert_grep "progress-audit" "$STATE/.wake-queue" "the wake is appended to the durable queue"
age_marker "$((LATER - 601))"
OUT=$(tick "$LATER" tick) || fail "a repeat tick failed"
assert_equals "" "$OUT" "an unchanged finding is surfaced once"
pass "tick surfaces a new stall once, durably, on its own cadence"

OUT=$(tick "$LATER" recover stuck) || fail "tick-home recovery failed: $OUT"
age_marker "$((LATER + WINDOW))"
OUT=$(tick "$((LATER + WINDOW + 700))" tick) || fail "post-attempt tick failed"
assert_contains "$OUT" "stuck stalled agent-exited, next relaunch" "a crew still stuck after an attempt is surfaced again"
OUT=$(tick "$((LATER + WINDOW + 700))" recover stuck) || fail "second tick-home recovery failed: $OUT"
age_marker "$((LATER + 2 * WINDOW + 800))"
OUT=$(tick "$((LATER + 3 * WINDOW))" tick) || fail "exhausted tick failed"
assert_contains "$OUT" "next escalate" "after two attempts the tick surfaces the escalation"
rc=0; tick "$((LATER + 3 * WINDOW))" recover stuck >/dev/null || rc=$?
expect_code 3 "$rc" "the surfaced escalation is due"
age_marker "$((LATER + 3 * WINDOW - 700))"
OUT=$(tick "$((LATER + 3 * WINDOW))" tick) || fail "post-escalation tick failed"
assert_equals "" "$OUT" "an escalated crew stays silent"
rm -f "$STATE/stuck.meta"
age_marker "$((LATER + 3 * WINDOW - 700))"
tick "$((LATER + 3 * WINDOW))" tick >/dev/null || fail "pruning tick failed"
assert_absent "$STATE/.progress-audit/stuck" "a cleaned-up crew's signature is pruned"
pass "tick follows the two attempts, surfaces one escalation, then goes quiet"

crew offdrive1 ship "$ABSENT_VOL/pool/1/copy"
crew offdrive2 ship "$ABSENT_VOL/pool/2/copy"
age_marker "$((LATER + 3 * WINDOW - 700))"
OUT=$(tick "$((LATER + 3 * WINDOW))" tick) || fail "storage tick failed"
assert_contains "$OUT" "local-copy storage not reachable: " "unreachable storage is surfaced"
assert_contains "$OUT" "(2 crew)" "one storage finding counts the crews it holds"
assert_not_contains "$OUT" "need recovery" "crews on unreachable storage are not surfaced one by one"
age_marker "$((LATER + 3 * WINDOW - 700))"
OUT=$(tick "$((LATER + 3 * WINDOW))" tick) || fail "repeat storage tick failed"
assert_equals "" "$OUT" "unchanged unreachable storage is surfaced once"
rm -f "$STATE/offdrive1.meta" "$STATE/offdrive2.meta"
age_marker "$((LATER + 3 * WINDOW - 700))"
tick "$((LATER + 3 * WINDOW))" tick >/dev/null || fail "storage-clear tick failed"
assert_absent "$STATE/.progress-audit/.storage" "the storage signature clears when nothing is held there"
pass "tick names unreachable storage once, as one fleet-level finding"

rc=0; env FM_HOME="$TICK_HOME" FM_PROGRESS_WINDOW_SECS=5 "$AUDIT" account >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" "an out-of-range window is refused"
pass "configuration outside its bounds is refused"

# --- the real watcher poll runs the tick and wakes on its finding -------------

WATCH_HOME="$T/watch-home"
mkdir -p "$WATCH_HOME/state" "$WATCH_HOME/data" "$WATCH_HOME/config" "$WATCH_HOME/projects"
# No window is recorded, so the pane-based stale path has nothing to poll and
# only the progress audit can notice this crew.
fm_write_meta "$WATCH_HOME/state/silent.meta" \
  "endpoint_task_id=silent" "worktree=$WT" "project=$T/repo" "harness=claude" \
  "kind=ship" "mode=direct-PR" "yolo=off" "branch=fm/silent" "spawn_gen=s$((REAL_NOW - WINDOW - 600)).1.1"
mkdir -p "$WATCH_HOME/state/.progress-audit"
fm_touch_epoch "$((REAL_NOW - 120))" "$WATCH_HOME/state/.progress-audit/.last-tick"
WATCH_OUT="$T/watch.out"
env FM_HOME="$WATCH_HOME" FM_STATE_OVERRIDE="$WATCH_HOME/state" FM_TEST_STUBS="$STUBS" \
  FM_PROGRESS_AUDIT_NOW="$((REAL_NOW + WINDOW + 600))" FM_PROGRESS_AUDIT_SECS=60 \
  FM_PROGRESS_WINDOW_SECS="$WINDOW" \
  FM_PROGRESS_CREW_STATE_BIN="$STUBS/crew-state" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch.sh" > "$WATCH_OUT" 2>&1 &
WATCH_PID=$!
i=0
while [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.1
  i=$((i + 1))
done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
assert_grep "check: progress-audit: 1 crew need recovery by cause (silent missing endpoint-gone, next relaunch)" \
  "$WATCH_OUT" "the watcher poll surfaces the progress audit's finding"
assert_grep "progress-audit" "$WATCH_HOME/state/.wake-queue" "the watcher's progress wake is durable"
pass "the real watcher poll runs the progress tick and wakes on a silent crew"
