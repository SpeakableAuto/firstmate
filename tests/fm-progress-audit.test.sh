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

status busy "working [at=$((T3 + 10))]: pushed a checkpoint"
OUT=$(audit "$((T3 + WINDOW + 15))" account busy)
assert_contains "$OUT" "attempts=0/2 · next=steer" "landed progress earns a fresh allowance"
pass "progress landed after recovery resets the allowance"

: > "$STUBS/calls"
echo 1 > "$STUBS/control-rc"
rc=0; OUT=$(audit "$LATER" recover exited) || rc=$?
expect_code 1 "$rc" "a failed relaunch reports failure"
assert_contains "$OUT" "relaunch exited failed (cause agent-exited, attempt 1 of 2)" "the failure is named"
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

rc=0; env FM_HOME="$TICK_HOME" FM_PROGRESS_WINDOW_SECS=5 "$AUDIT" account >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" "an out-of-range window is refused"
pass "configuration outside its bounds is refused"
