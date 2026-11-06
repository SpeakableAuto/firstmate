#!/usr/bin/env bash
# Bounded pool admission, read-only inspection, and safe-reclaim refusal paths.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-worktree-slots-lib.sh
. "$ROOT/bin/fm-worktree-slots-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-slots)
fm_git_identity fmtest fmtest@example.invalid

make_case() {
  CASE="$TMP_ROOT/$1"
  export FM_HOME="$CASE/home"
  mkdir -p "$FM_HOME"/{projects,config,state,data} "$CASE/bin" "$CASE/real-pool/1"
  # POOL_VIA=link reaches the pool through a symlink (as /var -> /private/var
  # does), so Treehouse records a spelling that differs from the resolved path.
  if [ "${POOL_VIA:-}" = link ]; then ln -s real-pool "$CASE/pool"; else mv "$CASE/real-pool" "$CASE/pool"; fi
  PROJECT="$FM_HOME/projects/project"
  SLOT="$CASE/pool/1/project"
  fm_git_worktree "$PROJECT" "$SLOT" fixture-task
  printf '{"worktrees":[{"path":"%s"}]}\n' "$SLOT" > "$CASE/pool/treehouse-state.json"
  export SLOT_TEST_LOG="$CASE/treehouse.log"
  cat > "$CASE/bin/treehouse" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$*" = 'destroy --help' ]; then
  [ "${SLOT_TEST_OLD:-0}" = 0 ] && echo '--include-unlanded'
  exit 0
fi
printf '%s\n' "$*" >> "$SLOT_TEST_LOG"
[ "$1" = destroy ] && [ "$#" = 3 ] && [ "$3" = --yes ] || exit 99
pool=$(dirname "$(dirname "$2")")
# Like real Treehouse, match only the path exactly as recorded.
jq -e --arg slot "$2" 'any(.worktrees[]; .path == $slot)' "$pool/treehouse-state.json" >/dev/null || {
  echo "$2 is not managed by treehouse"; exit 1; }
# This fake models the safe tool boundary; the subject must never bypass it.
[ -z "$(git -C "$2" status --porcelain)" ] || exit 1
git -C "$2" merge-base --is-ancestor HEAD main || exit 1
project=$(git -C "$2" rev-parse --path-format=absolute --git-common-dir)
project=${project%/.git}
git -C "$project" worktree remove "$2"
jq --arg slot "$2" '.worktrees |= map(select(.path != $slot))' "$pool/treehouse-state.json" > "$pool/next"
mv "$pool/next" "$pool/treehouse-state.json"
EOF
  cat > "$CASE/bin/lsof" <<'EOF'
#!/usr/bin/env bash
[ "$*" = '-a -d cwd -Fpn' ] || exit 99
[ -z "${SLOT_TEST_LSOF_FAIL:-}" ] || exit 2
printf 'p1\nfcwd\nn/\n'
if [ -n "${SLOT_TEST_LIVE:-}" ]; then printf 'p12345\nfcwd\nn%s\n' "$SLOT_TEST_LIVE"; fi
EOF
  chmod +x "$CASE/bin/"*
  export PATH="$CASE/bin:$ORIGINAL_PATH"
}
ORIGINAL_PATH=$PATH
room() { fm_worktree_slot_room "$FM_HOME/config" "$FM_HOME/projects" "$PROJECT" "$FM_HOME/state"; }
reclaim() { fm_worktree_slots_reclaim "$FM_HOME/state" '' apply 0; }
refuses() { if room; then fail "$1: unexpectedly allowed"; fi; }

make_case absent
room || fail 'absent cap should allow'
[ ! -e "$SLOT_TEST_LOG" ] || fail 'absent cap called treehouse'
for value in 0 -1 01 abc 99999999999999999999; do
  printf '%s\n' "$value" > "$FM_HOME/config/worktree-slot-cap"
  refuses "invalid cap $value"
done
printf '2' > "$FM_HOME/config/worktree-slot-cap"
refuses 'cap without newline'
printf '2\n' > "$FM_HOME/config/worktree-slot-cap"
room || fail "under cap: $FM_WORKTREE_SLOT_ROOM_REASON"
[ "$FM_WORKTREE_SLOT_HELD" = 1 ] || fail 'did not count slot'
for n in $(seq 1 65); do
  printf 'kind=ship\nbackend=tmux\nwindow=firstmate:old-%s\n' "$n" > "$FM_HOME/state/old-$n.meta"
done
room || fail 'parked task records consumed disk slots'
[ "$FM_WORKTREE_SLOT_HELD" = 1 ] || fail 'metadata records inflated disk slot count'
pass '65 parked records do not consume worktree slots'
# Reading a real pool must not even run a Treehouse status/preview command.
cp "$CASE/pool/treehouse-state.json" "$CASE/before"
printf '1\n' > "$FM_HOME/config/worktree-slot-cap"
refuses 'at cap'
[ "$FM_WORKTREE_SLOT_RECLAIMABLE" = 1 ] || fail 'idle candidate not found'
[ ! -e "$SLOT_TEST_LOG" ] || fail 'room check invoked mutating Treehouse inspection'
cmp -s "$CASE/before" "$CASE/pool/treehouse-state.json" || fail 'room changed pool'
assert_contains "$FM_WORKTREE_SLOT_ROOM_REASON" 'pools: pool 1' 'refusal must name pools'
printf '{}' > "$FM_HOME/state/capacity.json"
reclaim
[ -f "$FM_HOME/state/.capacity-freed" ] || fail 'safe reclaim did not signal capacity recheck'
[ ! -d "$SLOT" ] || fail 'safe slot not reclaimed'
room || fail 'reclaim did not free room'
pass 'absent cap, malformed config, read-only room, bounded safe reclaim'

for risk in dirty unlanded live lsof-fails claimed recorded leased; do
  make_case "$risk"
  printf '1\n' > "$FM_HOME/config/worktree-slot-cap"
  case "$risk" in
    dirty) echo work > "$SLOT/untracked" ;;
    unlanded) echo work > "$SLOT/file"; git -C "$SLOT" add file; git -C "$SLOT" commit -qm work ;;
    live) mkdir -p "$SLOT/sub"; SLOT_TEST_LIVE=$(cd "$SLOT/sub" && pwd -P); export SLOT_TEST_LIVE ;;
    lsof-fails) export SLOT_TEST_LSOF_FAIL=1 ;;
    claimed) printf 'task=active\nhome=%s\n' "$FM_HOME" > "$CASE/pool/1/.fm-slot-owner" ;;
    recorded) printf 'worktree=%s\n' "$SLOT" > "$FM_HOME/state/active.meta" ;;
    leased) jq '.worktrees[0].leased=true' "$CASE/pool/treehouse-state.json" > "$CASE/next"; mv "$CASE/next" "$CASE/pool/treehouse-state.json" ;;
  esac
  refuses "$risk"
  reclaim
  [ -d "$SLOT" ] || fail "$risk slot removed"
  refuses "$risk remains at cap"
  [ "$risk" = unlanded ] || [ ! -e "$SLOT_TEST_LOG" ] || fail "$risk attempted destruction"
  unset SLOT_TEST_LIVE SLOT_TEST_LSOF_FAIL
  pass "$risk slot retained and admission refused"
done

make_case old-tool
printf '1\n' > "$FM_HOME/config/worktree-slot-cap"
refuses 'old tool'
export SLOT_TEST_OLD=1
reclaim
unset SLOT_TEST_OLD
[ -d "$SLOT" ] && [ ! -e "$SLOT_TEST_LOG" ] || fail 'unsafe old destroy used'
pass 'old Treehouse cannot destroy slots'

make_case contended
printf '1\n' > "$FM_HOME/config/worktree-slot-cap"
refuses 'contended'
lock=$(fm_treehouse_project_lock_path "$PROJECT")
fm_lock_try_acquire "$lock" || fail 'fixture lock'
bash "$ROOT/bin/fm-worktree-slots.sh" reclaim
fm_lock_release "$lock"
[ -d "$SLOT" ] || fail 'removed under contended lock'
pass 'contended project lock keeps slot'

make_case corrupt
printf '1\n' > "$FM_HOME/config/worktree-slot-cap"
printf '{broken' > "$CASE/pool/treehouse-state.json"
refuses 'unreadable pool'
assert_contains "$FM_WORKTREE_SLOT_ROOM_REASON" 'cannot read Treehouse pool' 'corrupt pool reason'
pass 'unreadable pool fails closed'

for risk in none dirty; do
  POOL_VIA="link" make_case "symlinked-$risk"
  [ "$(fm_worktree_slots_canonical_dir "$SLOT")" != "$SLOT" ] || fail 'fixture pool is not reached through a symlink'
  printf '1\n' > "$FM_HOME/config/worktree-slot-cap"
  [ "$risk" = none ] || echo work > "$SLOT/untracked"
  refuses "symlinked pool $risk"
  reclaim
  if [ "$risk" = none ]; then
    [ ! -d "$SLOT" ] || fail 'symlinked pool: reclaimable slot kept'
    grep -qxF "destroy $SLOT --yes" "$SLOT_TEST_LOG" || fail 'treehouse not given the recorded slot path'
    room || fail 'symlinked pool: reclaim did not free room'
  else
    [ -d "$SLOT" ] || fail 'symlinked pool: dirty slot removed'
    [ ! -e "$SLOT_TEST_LOG" ] || fail 'symlinked pool: dirty slot destruction attempted'
    refuses 'symlinked pool dirty remains at cap'
  fi
done
pass 'symlinked pool root: recorded spelling reclaims, protected slot kept'

make_case merged-returned
printf '{}' > "$FM_HOME/state/capacity.json"
fm_worktree_slot_remove_returned "$PROJECT" "$SLOT" "$FM_HOME/state" "$FM_HOME/state/completed.meta" || fail 'proved returned slot was not removed'
[ ! -d "$SLOT" ] || fail 'returned slot remains'
[ -f "$FM_HOME/state/.capacity-freed" ] || fail 'merge-proved slot removal did not signal capacity'
pass 'merge-proved returned slot removal signals automatic capacity recheck'

# A stalled pool read refuses room within its bound instead of waiting forever.
# The fixture's git blocks `worktree list` in a real kernel wait (opening a
# FIFO that never gets a writer); it does not reproduce a stalled disk's I/O.
make_case stalled
printf '1\n' > "$FM_HOME/config/worktree-slot-cap"
mkfifo "$CASE/never-written"
SLOT_TEST_REAL_GIT=$(PATH=$ORIGINAL_PATH command -v git)
export SLOT_TEST_REAL_GIT SLOT_TEST_STALL_LOG="$CASE/stall.log" SLOT_TEST_STALL_FIFO="$CASE/never-written"
cat > "$CASE/bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" worktree list "*)
    printf '%s\n' "$$" >> "$SLOT_TEST_STALL_LOG"
    exec 3< "$SLOT_TEST_STALL_FIFO" ;;
esac
exec "$SLOT_TEST_REAL_GIT" "$@"
EOF
chmod +x "$CASE/bin/git"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
started=$(date +%s)
# The outer bound only keeps a regression from hanging this suite.
out=$(FM_WORKTREE_SLOTS_READ_SECS=2 fm_run_timed 30 "$ROOT/bin/fm-worktree-slots.sh" room "$PROJECT" 2>&1) && rc=0 || rc=$?
elapsed=$(( $(date +%s) - started ))
printf 'stalled room CLI: exit=%s elapsed=%ss output=%s\n' "$rc" "$elapsed" "$out"
[ "$rc" = 1 ] || fail "stalled room CLI did not refuse (exit $rc after ${elapsed}s)"
assert_contains "$out" 'refuse: worktree slot cap 1: room unavailable, the pool read did not finish within 2s' 'stalled room names its bound'
assert_contains "$out" 'required machine drive unavailable' 'stalled room names the drive refusal'
[ "$elapsed" -le 8 ] || fail "stalled room CLI took ${elapsed}s"
[ -s "$SLOT_TEST_STALL_LOG" ] || fail 'stalled room never reached the blocked pool read'
sleep 1
while IFS= read -r reader; do
  if kill -0 "$reader" 2>/dev/null; then fail "stalled room left blocked reader $reader running"; fi
done < "$SLOT_TEST_STALL_LOG"
: > "$SLOT_TEST_STALL_LOG"
started=$(date +%s)
if FM_WORKTREE_SLOTS_READ_SECS=2 room; then fail 'stalled room allowed in-process'; fi
elapsed=$(( $(date +%s) - started ))
printf 'stalled room in-process: elapsed=%ss timed_out=%s reclaimable=%s\n' "$elapsed" "$FM_WORKTREE_SLOT_ROOM_TIMED_OUT" "$FM_WORKTREE_SLOT_RECLAIMABLE"
assert_equals '1:0' "$FM_WORKTREE_SLOT_ROOM_TIMED_OUT:$FM_WORKTREE_SLOT_RECLAIMABLE" 'stalled room marks the bound and offers no reclaim'
[ "$elapsed" -le 8 ] || fail "stalled room in-process took ${elapsed}s"
[ -s "$SLOT_TEST_STALL_LOG" ] || fail 'in-process stalled room never reached the blocked pool read'
rm "$CASE/bin/git"
printf '2\n' > "$FM_HOME/config/worktree-slot-cap"
room || fail "healthy room after the stall: $FM_WORKTREE_SLOT_ROOM_REASON"
assert_equals '0:1' "$FM_WORKTREE_SLOT_ROOM_TIMED_OUT:$FM_WORKTREE_SLOT_HELD" 'healthy room after the stall counts through the bounded read'
pass 'a stalled pool read refuses room within its bound, CLI and in-process'

# A reclaim that stalls on the drive stops at its bound and leaves the slot.
make_case stalled-reclaim
printf '1\n' > "$FM_HOME/config/worktree-slot-cap"
mkfifo "$CASE/never-written"
export SLOT_TEST_STALL_LOG="$CASE/stall.log" SLOT_TEST_STALL_FIFO="$CASE/never-written"
cat > "$CASE/bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" status --porcelain "*)
    if [ -n "${SLOT_TEST_STALL_STATUS:-}" ]; then
      printf '%s\n' "$$" >> "$SLOT_TEST_STALL_LOG"
      exec 3< "$SLOT_TEST_STALL_FIFO"
    fi ;;
esac
exec "$SLOT_TEST_REAL_GIT" "$@"
EOF
chmod +x "$CASE/bin/git"
if room; then fail 'stalled reclaim fixture: room unexpectedly allowed'; fi
assert_equals '0:1' "$FM_WORKTREE_SLOT_ROOM_TIMED_OUT:$FM_WORKTREE_SLOT_RECLAIMABLE" 'stalled reclaim fixture starts with one candidate'
started=$(date +%s)
# shellcheck disable=SC2016 # expanded by the bounded child
out=$(SLOT_TEST_STALL_STATUS=1 FM_WORKTREE_SLOTS_READ_SECS=2 fm_run_timed 30 bash -c '
  . "$1/bin/fm-worktree-slots-lib.sh"
  rc=0
  fm_worktree_slots_reclaim_bounded "$FM_HOME/projects" "$2" "$FM_HOME/state" "" 1 || rc=$?
  printf "rc=%s timed_out=%s reason=%s\n" "$rc" "$FM_WORKTREE_SLOT_ROOM_TIMED_OUT" "$FM_WORKTREE_SLOT_ROOM_REASON"' bash "$ROOT" "$PROJECT" 2>&1) && rc=0 || rc=$?
elapsed=$(( $(date +%s) - started ))
printf 'stalled reclaim: exit=%s elapsed=%ss output=%s\n' "$rc" "$elapsed" "$out"
[ "$rc" = 0 ] || fail "stalled reclaim did not return (exit $rc after ${elapsed}s)"
assert_contains "$out" 'rc=124 timed_out=1' 'stalled reclaim reports its bound'
assert_contains "$out" 'worktree slot reclaim did not finish within 2s (required machine drive unavailable' 'stalled reclaim names the drive refusal'
[ "$elapsed" -le 8 ] || fail "stalled reclaim took ${elapsed}s"
[ -s "$SLOT_TEST_STALL_LOG" ] || fail 'stalled reclaim never reached the blocked slot read'
[ -d "$SLOT" ] || fail 'stalled reclaim removed the slot'
[ ! -e "$SLOT_TEST_LOG" ] || fail 'stalled reclaim reached Treehouse destroy'
sleep 1
while IFS= read -r reader; do
  if kill -0 "$reader" 2>/dev/null; then fail "stalled reclaim left blocked reader $reader running"; fi
done < "$SLOT_TEST_STALL_LOG"
fm_worktree_slots_reclaim_bounded "$FM_HOME/projects" "$PROJECT" "$FM_HOME/state" "" 1 > "$CASE/reclaimed" ||
  fail "healthy bounded reclaim failed: $FM_WORKTREE_SLOT_ROOM_REASON"
assert_contains "$(cat "$CASE/reclaimed")" "reclaimed: $SLOT" 'healthy bounded reclaim reports and removes the slot'
[ ! -d "$SLOT" ] || fail 'healthy bounded reclaim kept the slot'
room || fail "room after a healthy bounded reclaim: $FM_WORKTREE_SLOT_ROOM_REASON"
pass 'a stalled reclaim stops at its bound and keeps the slot; a healthy bounded reclaim still frees room'
