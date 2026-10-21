#!/usr/bin/env bash
set -eu

ROOT=/Users/maxverstappen/.no-mistakes/worktrees/02f7ed18429b/01M5EN0PXNGDWGBSKBVAARTJF3
EVIDENCE=/Users/maxverstappen/.no-mistakes/evidence/01M5EN0PXNGDWGBSKBVAARTJF3
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
ORIGINAL_PATH=$PATH
SESSION=$($LAB_HELPER name claude-control)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
TEARDOWN_OK=0

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

cleanup() {
  rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  chmod -R u+rwX "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
  [ "$rc" -eq 0 ] && TEARDOWN_OK=1 || true
  exit "$rc"
}
trap cleanup EXIT

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
printf 'herdr\n' > "$LAB/config/backend"
printf 'manual\n' > "$LAB/config/backlog-backend"

SHIM="$LAB/herdr-shim"
mkdir -p "$SHIM"
cat > "$SHIM/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -eq 2 ] && [ "\${args[0]}" = status ] && [ "\${args[1]}" = --json ]; then
  exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" status --json
fi
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$SHIM/herdr"

"$LAB_HELPER" provision "$SESSION"
export PATH="$SHIM:$ORIGINAL_PATH"
export FM_HOME="$LAB"
export HERDR_SESSION="$SESSION"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

lab() {
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"
}

PROJECT="$LAB/project"
WT="$LAB/worktree"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
printf '# live control fixture\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name='Firstmate Live Gate' -c user.email='live-gate@example.invalid' commit -qm initial
git -C "$PROJECT" worktree add --quiet -b live-control "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "could not load the Herdr backend"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "could not create the lab container"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "could not create the task pane"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "task creation returned no endpoint"
TARGET="$SESSION:$PANE_ID"

mkdir -p "$LAB/data/hsmoke"
cat > "$LAB/data/hsmoke/brief.md" <<'EOF'
# Task

Wait for Firstmate instructions. This is an isolated live lifecycle validation.
EOF
cat > "$LAB/state/hsmoke.meta" <<EOF
window=$TARGET
endpoint_task_id=hsmoke
worktree=$WT
project=$PROJECT
harness=claude
kind=scout
model=default
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WORKSPACE_ID
herdr_tab_id=$TAB_ID
herdr_pane_id=$PANE_ID
EOF

CLAUDE_VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1)
HERDR_VERSION=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1)
lab pane run "$PANE_ID" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --name Firstmate-live-titled --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude"

idle=0
trusted=0
for _ in $(seq 1 75); do
  screen=$(lab pane read "$PANE_ID" --source visible 2>/dev/null || true)
  case "$screen" in
    *'bypass permissions on'*|*'auto mode on'*)
      status=$(lab agent get "$PANE_ID" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
      case "$status" in idle|done) idle=1; break ;; esac
      ;;
    *'Yes, I trust this folder'*)
      if [ "$trusted" -eq 0 ]; then
        trusted=1
        lab pane send-keys "$PANE_ID" down enter >/dev/null
      fi
      ;;
  esac
  sleep 1
done
[ "$idle" -eq 1 ] || fail "Claude never reached an idle composer"

state=$(fm_backend_herdr_composer_state "$TARGET")
[ "$state" = empty ] || fail "idle Claude composer classified '$state', expected empty"
printf 'ok - idle real Claude composer classified empty (%s; %s; session %s)\n' "$CLAUDE_VERSION" "$HERDR_VERSION" "$SESSION"

ACTED="$LAB/doorbell-acted"
FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" hsmoke \
  "Firstmate live check: run exactly this shell command now: touch '$ACTED'. Then follow the inbox instruction and move this message to handled. Reply with one short line." \
  >/dev/null || fail "fm-send refused the live doorbell"

RECORD="$LAB/state/hsmoke.inbox/001.msg"
HANDLED="$LAB/state/hsmoke.inbox/handled/001.msg"
[ -f "$RECORD" ] || fail "fm-send did not create the durable inbox record"
for _ in $(seq 1 120); do
  [ -e "$ACTED" ] && [ -f "$HANDLED" ] && break
  sleep 1
done
[ -e "$ACTED" ] || fail "Claude did not act on the doorbell instruction"
[ -f "$HANDLED" ] || fail "Claude did not acknowledge the inbox record"
printf 'ok - fm-send doorbell reached real Claude, which acted and moved 001.msg to handled\n'

for _ in $(seq 1 60); do
  status=$(lab agent get "$PANE_ID" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$status" in idle|done) break ;; esac
  sleep 1
done

lab pane read "$PANE_ID" --source visible > "$EVIDENCE/claude-idle-after-doorbell.ansi"
perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g' "$EVIDENCE/claude-idle-after-doorbell.ansi" \
  > "$EVIDENCE/claude-idle-after-doorbell.txt"

DRAFT="UNSUBMITTED-LIVE-DRAFT-$RANDOM"
lab pane send-text "$PANE_ID" "$DRAFT" >/dev/null
for _ in $(seq 1 30); do
  state=$(fm_backend_herdr_composer_state "$TARGET" 2>/dev/null || true)
  [ "$state" = pending ] && break
  sleep 0.2
done
[ "$state" = pending ] || fail "typed draft classified '$state', expected pending"

set +e
REFUSAL=$(FM_HOME="$LAB" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=8 \
  "$ROOT/bin/fm-control.sh" hsmoke exit 2>&1)
REFUSAL_RC=$?
set -e
[ "$REFUSAL_RC" -ne 0 ] || fail "fm-control exit accepted a non-empty composer"
case "$REFUSAL" in
  *"composer visibly holds pending text"*) ;;
  *) fail "fm-control refusal did not name the pending draft: $REFUSAL" ;;
esac
content=$(fm_backend_herdr_composer_content "$TARGET" 2>/dev/null || true)
case "$content" in
  *"$DRAFT"*) ;;
  *) fail "the refused exit did not preserve the draft" ;;
esac
printf 'ok - fm-control refused exit with a pending draft and preserved the draft\n'

lab pane send-keys "$PANE_ID" ctrl+u >/dev/null
for _ in $(seq 1 30); do
  state=$(fm_backend_herdr_composer_state "$TARGET" 2>/dev/null || true)
  [ "$state" = empty ] && break
  sleep 0.2
done
[ "$state" = empty ] || fail "Ctrl+U did not restore an empty composer (got '$state')"

RELAUNCH=$(FM_HOME="$LAB" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=20 FM_CONTROL_LAUNCH_WAIT=40 \
  "$ROOT/bin/fm-control.sh" hsmoke relaunch --note "Live gate relaunch after verified idle composer." 2>&1) \
  || fail "fm-control relaunch failed: $RELAUNCH"
case "$RELAUNCH" in
  *"relaunched hsmoke"*) ;;
  *) fail "fm-control relaunch returned an unexpected result: $RELAUNCH" ;;
esac

NEW_TARGET=$(sed -n 's/^window=//p' "$LAB/state/hsmoke.meta" | tail -1)
NEW_PANE=$(sed -n 's/^herdr_pane_id=//p' "$LAB/state/hsmoke.meta" | tail -1)
[ "$NEW_TARGET" = "$TARGET" ] || fail "relaunch replaced the live endpoint instead of reusing it"
alive=0
for _ in $(seq 1 40); do
  state=$(fm_backend_agent_state herdr "$NEW_TARGET" 2>/dev/null || true)
  [ "$state" = alive ] && { alive=1; break; }
  sleep 0.5
done
[ "$alive" -eq 1 ] || fail "replacement Claude agent was not alive"
printf 'ok - fm-control relaunched real Claude in the same Herdr endpoint\n'
printf 'ok - isolated lab teardown follows\n'
