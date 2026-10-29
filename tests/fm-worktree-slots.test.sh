#!/usr/bin/env bash
# Bounded pool admission, read-only inspection, and safe-reclaim refusal paths.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-worktree-slots-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-slots)
fm_git_identity fmtest fmtest@example.invalid

make_case() {
  CASE="$TMP_ROOT/$1"
  export FM_HOME="$CASE/home"
  mkdir -p "$FM_HOME"/{projects,config,state,data} "$CASE/bin" "$CASE/pool/1"
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
# This fake models the safe tool boundary; the subject must never bypass it.
[ -z "$(git -C "$2" status --porcelain)" ] || exit 1
git -C "$2" merge-base --is-ancestor HEAD main || exit 1
project=$(git -C "$2" rev-parse --path-format=absolute --git-common-dir)
project=${project%/.git}
pool=$(dirname "$(dirname "$2")")
git -C "$project" worktree remove "$2"
jq --arg slot "$2" '.worktrees |= map(select(.path != $slot))' "$pool/treehouse-state.json" > "$pool/next"
mv "$pool/next" "$pool/treehouse-state.json"
EOF
  cat > "$CASE/bin/lsof" <<'EOF'
#!/usr/bin/env bash
if [ "${SLOT_TEST_LIVE:-0}" = 1 ]; then echo 12345; exit 0; fi
exit 1
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
# Reading a real pool must not even run a Treehouse status/preview command.
cp "$CASE/pool/treehouse-state.json" "$CASE/before"
printf '1\n' > "$FM_HOME/config/worktree-slot-cap"
refuses 'at cap'
[ "$FM_WORKTREE_SLOT_RECLAIMABLE" = 1 ] || fail 'idle candidate not found'
[ ! -e "$SLOT_TEST_LOG" ] || fail 'room check invoked mutating Treehouse inspection'
cmp -s "$CASE/before" "$CASE/pool/treehouse-state.json" || fail 'room changed pool'
assert_contains "$FM_WORKTREE_SLOT_ROOM_REASON" 'pools: pool 1' 'refusal must name pools'
reclaim
[ ! -d "$SLOT" ] || fail 'safe slot not reclaimed'
room || fail 'reclaim did not free room'
pass 'absent cap, malformed config, read-only room, bounded safe reclaim'

for risk in dirty unlanded live claimed recorded leased; do
  make_case "$risk"
  printf '1\n' > "$FM_HOME/config/worktree-slot-cap"
  case "$risk" in
    dirty) echo work > "$SLOT/untracked" ;;
    unlanded) echo work > "$SLOT/file"; git -C "$SLOT" add file; git -C "$SLOT" commit -qm work ;;
    live) export SLOT_TEST_LIVE=1 ;;
    claimed) printf 'task=active\nhome=%s\n' "$FM_HOME" > "$CASE/pool/1/.fm-slot-owner" ;;
    recorded) printf 'worktree=%s\n' "$SLOT" > "$FM_HOME/state/active.meta" ;;
    leased) jq '.worktrees[0].leased=true' "$CASE/pool/treehouse-state.json" > "$CASE/next"; mv "$CASE/next" "$CASE/pool/treehouse-state.json" ;;
  esac
  refuses "$risk"
  reclaim
  [ -d "$SLOT" ] || fail "$risk slot removed"
  refuses "$risk remains at cap"
  [ "$risk" = unlanded ] || [ ! -e "$SLOT_TEST_LOG" ] || fail "$risk attempted destruction"
  unset SLOT_TEST_LIVE
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
