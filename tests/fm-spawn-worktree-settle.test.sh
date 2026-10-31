#!/usr/bin/env bash
# Regression tests for how fm-spawn.sh acquires and enters a fresh task's
# Treehouse slot (bin/fm-spawn.sh's spawn_treehouse_lease_slot and the
# launch-boundary cwd check, spawn_assert_agent_worktree).
#
# A fresh spawn takes its slot as a durable `treehouse get --lease`, so a task
# whose worker exits keeps its copy until its own teardown returns it, and the
# next spawn is given a different slot. A slot that another unfinished task
# still records (one taken before crew spawns leased) is never used: it stays
# leased and another one is taken. A spawn that aborts before publishing its
# record gives its clean, unrecorded lease back.
#
# The recorded worktree is the path Treehouse reports, never a pane cwd read,
# so a pane that transiently reports a stale unrelated checkout or the
# repository primary on its first reads is waited out at the launch boundary,
# and a pane that never reaches the leased copy refuses there.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree - and
# a treehouse whose lease reports FM_FAKE_PANE_PATH (tests/lib.sh).
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    elif [ -n "${FM_FAKE_PANE_CWD_FILE:-}" ] && [ -s "$FM_FAKE_PANE_CWD_FILE" ]; then
      cat "$FM_FAKE_PANE_CWD_FILE"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    # With FM_FAKE_PANE_CWD_FILE set, the pane follows the spawn's top-level
    # `cd -- '<path>'`, as a real shell does.
    if [ -n "${FM_FAKE_PANE_CWD_FILE:-}" ]; then
      for a in "$@"; do
        case "$a" in
          "cd -- '"*"'")
            a=${a#"cd -- '"}
            printf '%s\n' "${a%"'"}" > "$FM_FAKE_PANE_CWD_FILE"
            ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the original incident) must never become the
# recorded worktree: the record is the leased path, and the launch-boundary
# check waits the transient out.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# The leased path comes from Treehouse's own output, so a pane already in the
# copy costs exactly one cwd read: the launch-boundary check. No discovery poll
# runs before it. Counting the pane reads measures that directly; wall-clock
# time would fold in every other cost of a spawn and drift with the machine.
test_already_settled_pane_costs_one_cwd_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 1 ] || fail "already-settled pane took $reads cwd reads - expected only the launch-boundary check"
  pass "a leased spawn reads the pane cwd once, at the launch boundary"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout, as it did
# while an interactive `treehouse get` prepared a slot. The settled, leased path
# is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The pane reports the repository primary for the first reads, then settles
# into the leased slot. The primary is never adopted as the worktree, so the
# spawn lands on the leased slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the
# launch-boundary deadline rather than waiting forever or launching there.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "not its recorded worktree '$WT_DIR'" \
    "spawn did not explain that the pane never reached the leased worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the launch boundary"
}

test_slot_cap_refuses_before_endpoint_allocation() {
  local rec id out status
  id=slot-cap-refusal
  rec=$(make_settle_case slot-cap "$id" 0)
  read_settle_record "$rec"
  printf '1\n' > "$HOME_DIR/config/worktree-slot-cap"
  # A recorded pool slot fills the cap. Admission must preserve it even when
  # no process currently inhabits it; no Treehouse command may run here.
  printf '{"worktrees":[{"path":"%s"}]}\n' "$WT_DIR" > "$(dirname "$(dirname "$WT_DIR")")/treehouse-state.json"
  printf 'worktree=%s\n' "$WT_DIR" > "$HOME_DIR/state/existing.meta"
  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "slot cap allowed spawn: $out"
  assert_contains "$out" 'worktree slot cap 1 reached' 'cap refusal reason'
  [ ! -e "$COUNTFILE" ] || fail 'refused spawn polled an allocated endpoint'
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail 'refused spawn published metadata'
  [ -d "$WT_DIR" ] || fail 'recorded worktree removed'
  pass 'slot cap refuses spawn before endpoint allocation and keeps recorded work'
}

# --- durable slot leases ----------------------------------------------------
#
# make_pool_case <name> <slots> builds a project with a Treehouse-shaped pool
# of <slots> clean detached slots (<pool>/<n>/repo beside the pool state file)
# and a stateful treehouse fake modelling Treehouse's allocation rule: `get
# --lease` hands out the first slot with neither a durable lease nor a live
# process, and `return` releases a slot, honouring --if-lease-holder. The fake
# refuses the interactive `get`, so a spawn that falls back to it fails here.
# FM_FAKE_TH_DIR holds slots (one path per line), leases/<n> (the holder),
# process/<n> (a live interactive process lease) and log (every invocation).
make_pool_case() {
  local name=$1 slots=$2 case_dir home proj fakebin th n
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  th="$case_dir/th"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$proj.origin.git"
  git -C "$proj" fetch --quiet origin
  mkdir -p "$case_dir/pool" "$th/leases" "$th/process"
  : > "$th/slots"
  : > "$th/log"
  for n in $(seq 1 "$slots"); do
    git -C "$proj" worktree add --quiet --detach "$case_dir/pool/$n/repo" origin/main
    (cd "$case_dir/pool/$n/repo" && pwd -P) >> "$th/slots"
  done
  printf '{"worktrees":[]}\n' > "$case_dir/pool/treehouse-state.json"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_TH_DIR
printf '%s\n' "$*" >> "$D/log"
slot_index() {  # <path>
  local want n=0 slot
  want=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  while IFS= read -r slot; do
    n=$((n + 1))
    [ "$slot" != "$want" ] || { printf '%s\n' "$n"; return 0; }
  done < "$D/slots"
  return 1
}
cmd=${1:-}
[ $# -eq 0 ] || shift
case "$cmd" in
  get)
    lease=0 holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) lease=1 ;;
        --lease-holder) holder=${2:-}; shift ;;
      esac
      shift
    done
    [ "$lease" = 1 ] || { echo "fake treehouse: interactive get is not modelled" >&2; exit 3; }
    n=0
    while IFS= read -r slot; do
      n=$((n + 1))
      if [ ! -e "$D/leases/$n" ] && [ ! -e "$D/process/$n" ]; then
        printf '%s\n' "$holder" > "$D/leases/$n"
        printf '%s\n' "$slot"
        exit 0
      fi
    done < "$D/slots"
    echo "fake treehouse: no free slot" >&2
    exit 1
    ;;
  return)
    holder= path=
    while [ $# -gt 0 ]; do
      case "$1" in
        --if-lease-holder) holder=${2:-}; shift ;;
        --force) ;;
        *) path=$1 ;;
      esac
      shift
    done
    n=$(slot_index "$path") || exit 1
    if [ -n "$holder" ] && [ "$(cat "$D/leases/$n" 2>/dev/null)" != "$holder" ]; then
      echo "fake treehouse: lease holder does not match" >&2
      exit 1
    fi
    rm -f "$D/leases/$n" "$D/process/$n"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$case_dir|$home|$proj|$fakebin|$th"
}

read_pool_record() {
  IFS='|' read -r POOL_CASE HOME_DIR PROJ_DIR FAKEBIN_DIR TH_DIR <<EOF
$1
EOF
}

pool_slot() {  # <n>
  sed -n "${1}p" "$TH_DIR/slots"
}

run_pool_spawn() {  # <id> [fm-spawn args...]; POOL_PANE_IGNORES_CD=1 keeps the pane out of the slot
  local id=$1 cwd_file
  shift
  cwd_file="$POOL_CASE/pane-cwd"
  [ "${POOL_PANE_IGNORES_CD:-0}" != 1 ] || cwd_file=
  fm_test_spawn_brief "$HOME_DIR" "$id" "Exercise slot leasing for $id."
  : > "$POOL_CASE/pane-cwd"
  : > "$POOL_CASE/pane-count"
  mkdir -p "$POOL_CASE/user-home"
  env -u TREEHOUSE_ROOT -u TREEHOUSE_WORKTREE_PATH \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$POOL_CASE/user-home" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$PROJ_DIR" FM_FAKE_PANE_CWD_FILE="$cwd_file" \
    FM_FAKE_PANE_COUNTFILE="$POOL_CASE/pane-count" FM_FAKE_TH_DIR="$TH_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@" 2>&1
}

slot_claim_task() {  # <slot-path>
  sed -n 's/^task=//p' "$(dirname "$1")/.fm-slot-owner" 2>/dev/null
}

# The reported incident: a task's worker exits while the task is still in
# flight (paused for a review, or exited to free a seat), and the next spawn is
# handed that task's copy. With the durable lease, the exited worker's copy
# stays reserved, so the next spawn gets a different slot and the first task's
# record and claim are untouched.
test_exited_worker_keeps_its_slot_from_the_next_spawn() {
  local rec out status slot_a slot_b
  rec=$(make_pool_case lease-exited 3)
  read_pool_record "$rec"

  out=$(run_pool_spawn lease-task-a)
  status=$?
  expect_code 0 "$status" "the first spawn should lease a slot"$'\n'"$out"
  slot_a=$(pool_slot 1)
  assert_grep "worktree=$slot_a" "$HOME_DIR/state/lease-task-a.meta" "first task did not record the first slot"
  assert_grep "get --lease --lease-holder lease-task-a" "$TH_DIR/log" "spawn did not take a durable lease named for its task"
  [ "$(slot_claim_task "$slot_a")" = lease-task-a ] || fail "first task did not claim its slot"

  # Exit task A's agent: nothing runs in its copy any more. Only an
  # interactive process lease would lapse here; the durable lease must not.
  rm -f "$TH_DIR/process/1"
  [ -e "$TH_DIR/leases/1" ] || fail "the first task's lease did not survive its worker exiting"

  out=$(run_pool_spawn lease-task-b)
  status=$?
  expect_code 0 "$status" "the second spawn should lease a slot"$'\n'"$out"
  slot_b=$(pool_slot 2)
  assert_grep "worktree=$slot_b" "$HOME_DIR/state/lease-task-b.meta" "second task was not given a different slot"
  assert_no_grep "worktree=$slot_a" "$HOME_DIR/state/lease-task-b.meta" "second task was given the exited task's slot"
  assert_grep "worktree=$slot_a" "$HOME_DIR/state/lease-task-a.meta" "the first task's record was changed"
  [ "$(slot_claim_task "$slot_a")" = lease-task-a ] || fail "the second spawn replaced the first task's slot claim"
  [ "$(slot_claim_task "$slot_b")" = lease-task-b ] || fail "second task did not claim its own slot"
  pass "an exited worker's slot stays its task's; the next spawn leases a different one"
}

# A slot taken before crew spawns leased carries no lease, so Treehouse can
# offer one whose task is still in flight. The spawn must not use it: it stays
# leased (now protected) and the spawn takes the next one, leaving the recorded
# task's claim alone.
test_unleased_recorded_slot_is_kept_and_skipped() {
  local rec out status slot_old slot_new
  rec=$(make_pool_case lease-legacy 3)
  read_pool_record "$rec"
  slot_old=$(pool_slot 1)
  printf 'worktree=%s\nproject=%s\n' "$slot_old" "$PROJ_DIR" > "$HOME_DIR/state/legacy-paused.meta"
  printf 'task=legacy-paused\nhome=%s\n' "$HOME_DIR" > "$(dirname "$slot_old")/.fm-slot-owner"

  out=$(run_pool_spawn lease-task-c)
  status=$?
  expect_code 0 "$status" "the spawn should skip the recorded slot and lease another"$'\n'"$out"
  slot_new=$(pool_slot 2)
  assert_grep "worktree=$slot_new" "$HOME_DIR/state/lease-task-c.meta" "spawn did not move on to a free slot"
  assert_contains "$out" "legacy-paused still records" "spawn did not name the task whose slot it skipped"
  [ -e "$TH_DIR/leases/1" ] || fail "the recorded slot was handed back instead of staying leased"
  [ "$(slot_claim_task "$slot_old")" = legacy-paused ] || fail "the recorded task's slot claim was replaced"
  assert_grep "worktree=$slot_old" "$HOME_DIR/state/legacy-paused.meta" "the recorded task's record was changed"
  pass "an unleased slot another task records stays leased and is skipped"
}

# A spawn that aborts after leasing, before publishing its record, gives its
# clean and unrecorded lease back so the slot is not lost to the pool.
test_aborted_spawn_returns_its_lease() {
  local rec out status
  rec=$(make_pool_case lease-abort 2)
  read_pool_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  # The pane never follows the cd, so the launch-boundary check refuses.
  out=$(POOL_PANE_IGNORES_CD=1 run_pool_spawn lease-task-d)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched although its pane never entered the leased slot"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/lease-task-d.meta" ] || fail "aborted spawn published task metadata"
  assert_grep "return --if-lease-holder lease-task-d $(pool_slot 1)" "$TH_DIR/log" "aborted spawn did not return its own lease"
  [ ! -e "$TH_DIR/leases/1" ] || fail "aborted spawn left its slot leased"
  [ ! -e "$(dirname "$(pool_slot 1)")/.fm-slot-owner" ] || fail "aborted spawn left its slot claim"
  pass "an aborted spawn returns its clean, unrecorded lease"
}

# Real Treehouse, when installed: an interactive slot whose process exited (the
# old crew shape) is still recorded by its task, then two leased spawns run.
# Neither may take the recorded slot, and the two must differ.
test_real_treehouse_leases_skip_recorded_and_leased_slots() {
  local rec out status case_dir th_home legacy slot_a slot_b
  if ! command -v treehouse >/dev/null 2>&1 \
     || ! treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'; then
    printf 'skip: real treehouse with --lease is not installed\n'
    return 0
  fi
  rec=$(make_pool_case lease-real 0)
  read_pool_record "$rec"
  rm -f "$FAKEBIN_DIR/treehouse"
  case_dir=$POOL_CASE
  th_home="$case_dir/user-home"
  mkdir -p "$th_home"
  # The old crew shape: an interactive get whose shell has already exited.
  legacy=$(cd "$PROJ_DIR" && printf 'pwd -P\nexit\n' | env -u TREEHOUSE_ROOT -u TREEHOUSE_WORKTREE_PATH \
    HOME="$th_home" SHELL=/bin/bash treehouse get 2>/dev/null | tail -1)
  [ -n "$legacy" ] && [ -d "$legacy" ] || fail "could not create a real interactive slot: '$legacy'"
  printf 'worktree=%s\nproject=%s\n' "$legacy" "$PROJ_DIR" > "$HOME_DIR/state/legacy-real.meta"
  printf 'task=legacy-real\nhome=%s\n' "$HOME_DIR" > "$(dirname "$legacy")/.fm-slot-owner"

  out=$(run_pool_spawn lease-real-a)
  status=$?
  expect_code 0 "$status" "the first real leased spawn should succeed"$'\n'"$out"
  slot_a=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/lease-real-a.meta")
  out=$(run_pool_spawn lease-real-b)
  status=$?
  expect_code 0 "$status" "the second real leased spawn should succeed"$'\n'"$out"
  slot_b=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/lease-real-b.meta")
  [ -n "$slot_a" ] && [ -n "$slot_b" ] || fail "real spawns did not record their slots"
  [ "$slot_a" != "$legacy" ] || fail "first real spawn took the recorded interactive slot"
  [ "$slot_b" != "$legacy" ] || fail "second real spawn took the recorded interactive slot"
  [ "$slot_a" != "$slot_b" ] || fail "both real spawns were given the same slot"
  out=$(cd "$PROJ_DIR" && env -u TREEHOUSE_ROOT HOME="$th_home" treehouse status 2>/dev/null)
  assert_contains "$out" "held by lease-real-a" "first real spawn's slot is not durably leased"
  assert_contains "$out" "held by lease-real-b" "second real spawn's slot is not durably leased"
  [ "$(slot_claim_task "$legacy")" = legacy-real ] || fail "the recorded task's real slot claim was replaced"
  (cd "$PROJ_DIR" && env -u TREEHOUSE_ROOT HOME="$th_home" treehouse destroy "$(dirname "$(dirname "$legacy")")" --all --yes --include-unlanded >/dev/null 2>&1) || true
  pass "real Treehouse: leased spawns skip a recorded interactive slot and never share a slot"
}

test_slot_cap_refuses_before_endpoint_allocation

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_cwd_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_exited_worker_keeps_its_slot_from_the_next_spawn
test_unleased_recorded_slot_is_kept_and_skipped
test_aborted_spawn_returns_its_lease
test_real_treehouse_leases_skip_recorded_and_leased_slots

echo "# all fm-spawn-worktree-settle tests passed"
