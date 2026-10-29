#!/usr/bin/env bash
# Live drive of bin/fm-teardown.sh merge-proved slot removal:
# real Treehouse pool, real git clone of the public repo, real gh merge proof (PR #40),
# private tmux server inside the lab. Only `no-mistakes` is stubbed (reports no run) so the
# gate agent never aborts a real pipeline run.
set -u
WT=$1 VARIANT=$2   # merged | unmerged-pr | force
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
cleanup() { TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"; chmod 700 "$LAB/tmux"
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux"
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_DATA_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
mkdir -p "$LAB/stub"; printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/stub/no-mistakes"; chmod +x "$LAB/stub/no-mistakes"
export PATH="$LAB/stub:$PATH"
P="$LAB/projects/firstmate"
git clone -q --filter=blob:none https://github.com/SpeakableAuto/firstmate.git "$P"
printf 'max_trees = 16\nroot = "%s/trees"\n' "$LAB" > "$P/treehouse.toml"
printf 'treehouse.toml\n' >> "$P/.git/info/exclude"
S=$( cd "$P" && treehouse get --lease 2>/dev/null )
echo "real treehouse slot: $S"
case "$VARIANT" in
  merged|force)
    PRURL=https://github.com/SpeakableAuto/firstmate/pull/40
    git -C "$P" fetch -q origin a67a28b71a555892d01fdbbd7deb073f3cff9cb0
    git -C "$S" checkout -q -b fm/task-x1 a67a28b71a555892d01fdbbd7deb073f3cff9cb0 ;;
  unmerged-pr)
    PRURL=https://github.com/SpeakableAuto/firstmate/pull/40
    git -C "$S" checkout -q -b fm/task-x1 origin/main
    git -C "$S" -c user.name=t -c user.email=t@x commit -q --allow-empty -m "local-only work not in PR 40"
    git -C "$S" push -q --dry-run origin HEAD 2>/dev/null; : ;;
esac
echo "slot HEAD: $(git -C "$S" log -1 --format='%h %s')"
printf '1\n' > "$LAB/config/worktree-slot-cap"
cat > "$LAB/state/task-x1.meta" <<M
window=firstmate:fm-task-x1
endpoint_task_id=task-x1
worktree=$S
project=$P
kind=ship
mode=no-mistakes
backend=tmux
pr=$PRURL
spawn_gen=live-task-x1
M
tmux new-session -d -s firstmate -n fm-task-x1 -c "$S" "sleep 600"
echo "slots before: $(jq -r '.worktrees|length' "$(dirname "$(dirname "$S")")/treehouse-state.json")"
echo "room before:  $(bash "$WT/bin/fm-worktree-slots.sh" room "$P")"
ARGS=(); [ "$VARIANT" = force ] && ARGS=(--force)
echo "\$ fm-teardown.sh task-x1 ${ARGS[*]-}"
( cd "$WT" && bash bin/fm-teardown.sh task-x1 "${ARGS[@]+"${ARGS[@]}"}" ) 2>&1 | grep -iE 'slot|REFUSED|error|torn|teardown:' | head -20
echo "[teardown exit ${PIPESTATUS[0]}]"
[ -d "$S" ] && echo "RESULT: slot still on disk" || echo "RESULT: slot removed from disk"
( cd "$P" && git worktree list )
echo "room after:   $(bash "$WT/bin/fm-worktree-slots.sh" room "$P")"
