#!/usr/bin/env bash
# Live guard for the supervisor watchdog's screen reading against the
# INSTALLED Claude Code, in a guarded named Herdr lab. This is the live check
# the watchdog's version pin depends on: run it after every Claude upgrade and
# move FM_WATCHDOG_CLAUDE_VERSION only when it passes.
# Claude's API base URL points at a closed local port, so it spends no model
# tokens and produces the real terminal network-error screen.
# Proves: an idle empty prompt reads clear or conservatively pending when its
# only content is Claude's Try suggestion, a typed draft reads pending and is
# never typed over, the real network error reads error, and one guarded resume
# is typed, submitted and confirmed as a new turn.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_LIVE_WATCHDOG_CLAUDE claude herdr jq
LAB=$(mktemp -d)
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name watchdog-live)
cleanup_live_lab() {
  local rc=$?
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup_live_lab EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
h() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
# A checkout directory Claude already trusts avoids the first-run trust prompt.
h workspace create --cwd "$ROOT" --label watchdog-live > "$LAB/workspace.json"
PANE_ID=$(h pane list | jq -er '.result.panes[0].pane_id')
export FM_HOME="$LAB/home"
mkdir -p "$FM_HOME/state/supervisor-watchdog"
# shellcheck source=bin/fm-supervisor-watchdog.sh
. "$ROOT/bin/fm-supervisor-watchdog.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
fm_backend_source herdr
fm_backend_herdr_cli() {
  [ "$1" = "$HERDR_LAB_SESSION" ] || return 1
  shift
  h "$@"
}
SESSION=$HERDR_LAB_SESSION
DIR="$FM_HOME/state/supervisor-watchdog"
STATE="$FM_HOME/state"
FM_WAKE_QUEUE="$DIR/.wake-queue"
IDLE=10 BACKOFF=10 WAKE_AGE=600 STALL_SECS=1800
watchdog_under_way() { return 1; }
# Provider reachability is not under test; the dead base URL is.
watchdog_probe() { return 0; }
version=$(claude --version)
wait_verdict() {  # <verdict> <seconds>
  local attempt
  for ((attempt=0; attempt<$2; attempt++)); do
    watchdog_observe 2>/dev/null
    [ "$VERDICT" = "$1" ] && return 0
    sleep 1
  done
  return 1
}
wait_idle_prompt() {  # <seconds>
  local attempt content
  for ((attempt=0; attempt<$1; attempt++)); do
    watchdog_observe 2>/dev/null
    if [ "$VERDICT" = clear ]; then
      IDLE_READING=clear
      return 0
    fi
    if [ "$VERDICT" = composer-pending ]; then
      content=$(fm_composer_extract_selected_content "$CAPS" "$STYLED") || content=''
      if [[ $content =~ ^Try\ \"[^\"]+\"$ ]]; then
        IDLE_READING='composer-pending (Try suggestion)'
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}
printf -v command_line 'cd %q && CLAUDE_CODE_MAX_RETRIES=1 ANTHROPIC_BASE_URL=http://127.0.0.1:9 claude --dangerously-skip-permissions' "$ROOT"
h pane run "$PANE_ID" "$command_line" >/dev/null
wait_idle_prompt 60 || fail "Claude $version: idle prompt not read safely (got $VERDICT)"
pass "Claude $version: idle prompt reads $IDLE_READING"
h pane send-text "$PANE_ID" 'a typed draft' >/dev/null
sleep 1
watchdog_observe
[ "$VERDICT" = composer-pending ] || fail "Claude $version: typed draft not read as pending (got $VERDICT)"
pass "Claude $version: a typed draft reads pending"
h pane send-keys "$PANE_ID" ctrl+u >/dev/null
wait_idle_prompt 10 || fail "Claude $version: cleared prompt not read safely (got $VERDICT)"
pass "Claude $version: cleared prompt reads $IDLE_READING"
h pane send-text "$PANE_ID" 'hello' >/dev/null
sleep 0.3
h pane send-keys "$PANE_ID" enter >/dev/null
# Claude retries the closed port before it gives up and shows the error.
wait_verdict error 540 || fail "Claude $version: network error screen not recognized (got $VERDICT)"
pass "Claude $version: the real network error reads error"
watchdog_tick
sleep 11
watchdog_tick
[ "$(tail -1 "$DIR/events.jsonl" | jq -c '[.event,.detail]')" = '["submitted","nudge"]' ] \
  || fail "Claude $version: resume not confirmed (events: $(tail -3 "$DIR/events.jsonl" | tr '\n' ' '))"
watchdog_read | fm_composer_strip_ansi | grep -q '❯ Resume the interrupted work.' \
  || fail "Claude $version: resume turn not visible"
pass "Claude $version: one guarded resume is typed, submitted and confirmed"
h pane send-keys "$PANE_ID" ctrl+c >/dev/null
printf 'verification: %s on Herdr %s; pin FM_WATCHDOG_CLAUDE_VERSION=%q\n' \
  "$version" "$(h status --json | jq -r .server.version)" "$version"
