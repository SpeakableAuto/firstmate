#!/usr/bin/env bash
# Live drive of bin/fm-worktree-slots.sh against a real Treehouse pool in a lab home.
set -u
WT=$1
export PATH="$HOME/.local/bin:$PATH"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)  # pool root must match Treehouse's recorded spelling
trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_DATA_OVERRIDE
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare -b main "$LAB/origin.git"
P="$LAB/projects/project"
git clone -q "$LAB/origin.git" "$P" 2>/dev/null
printf 'max_trees = 16\nroot = "%s/trees"\n' "$LAB" > "$P/treehouse.toml"
( cd "$P" && git checkout -q -b main && git add treehouse.toml && git commit -qm init && git push -q origin main )
S="$WT/bin/fm-worktree-slots.sh"
step() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
lease() { ( cd "$P" && treehouse get --lease 2>/dev/null ); }
ret() { ( cd "$P" && treehouse return --force "$1" >/dev/null 2>&1 ); }

echo "=== S1: no config/worktree-slot-cap (opt-out) ==="
A=$(lease); echo "leased slot A: $A"; ret "$A"
step bash "$S" room "$P"

echo; echo "=== S2: cap 1, one returned merged slot -> refuse, dry-run, reclaim via real treehouse, allow ==="
printf '1\n' > "$LAB/config/worktree-slot-cap"
step bash "$S" room "$P"
step bash "$S" reclaim --dry-run
[ -d "$A" ] && echo "after dry-run: slot A still exists"
step bash "$S" reclaim
[ -d "$A" ] && echo "slot A STILL EXISTS" || echo "after reclaim: slot A removed from disk"
( cd "$P" && git worktree list )
step bash "$S" room "$P"

echo; echo "=== S3 (adversarial): unmerged committed work in returned slot -> kept ==="
B=$(lease); echo "leased slot B: $B"
ret "$B"
( cd "$B" && git checkout -q -b feat && echo x > f && git add f && git commit -qm unlanded )
echo "slot B returned (unleased) but on unmerged commit"
step bash "$S" room "$P"
step bash "$S" reclaim
[ -d "$B" ] && echo "slot B kept (commit $(git -C "$B" log -1 --format=%s))"
step bash "$S" room "$P"


echo; echo "=== S4 (adversarial): leased (in-use) slot -> kept, admission refused ==="
( cd "$P" && treehouse destroy "$B" --include-unlanded --yes >/dev/null 2>&1 )
C=$(lease); echo "leased slot C (still leased): $C"
step bash "$S" room "$P"
step bash "$S" reclaim
[ -d "$C" ] && echo "slot C kept"

echo; echo "=== S5 (adversarial): dirty returned slot -> kept ==="
ret "$C"; echo scratch > "$C/untracked.txt"
step bash "$S" reclaim
[ -d "$C" ] && echo "slot C kept with untracked file"

echo; echo "=== S6 (adversarial): a task record names the slot -> kept ==="
rm -f "$C/untracked.txt"
printf 'worktree=%s\n' "$C" > "$LAB/state/task-live.meta"
step bash "$S" reclaim
[ -d "$C" ] && echo "slot C kept while recorded"
rm -f "$LAB/state/task-live.meta"
step bash "$S" reclaim
[ -d "$C" ] || echo "slot C removed once record gone"
step bash "$S" room "$P"
