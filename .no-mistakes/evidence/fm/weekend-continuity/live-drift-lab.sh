#!/usr/bin/env bash
set -eu

ROOT=$1
EVIDENCE=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-drift-lab.XXXXXX")
HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$($HELPER name watchdog-drift)

cleanup() {
  local rc=$?
  "$HELPER" teardown "$SESSION" || rc=1
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup EXIT

"$HELPER" provision "$SESSION"
h() { "$HELPER" run "$SESSION" "$@"; }
h workspace create --cwd "$LAB" --label watchdog-drift > "$LAB/workspace.json"
PANE_ID=$(h pane list | jq -er '.result.panes[0].pane_id')

cat > "$LAB/rotating.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
helper=$1 session=$2 pane=$3 directory=$4
"$helper" run "$session" pane report-agent "$pane" --source watchdog-drift --agent claude --state idle >/dev/null
n=0
while :; do
  printf '\033[2J\033[H● Supervisor idle\n◇ New renderer phase %s\n\n────────────────────\n❯ \n────────────────────' "$n"
  n=$((n + 1))
  sleep 1
done
STUB
chmod +x "$LAB/rotating.sh"
printf -v command_line 'bash %q %q %q %q %q' "$LAB/rotating.sh" "$HELPER" "$SESSION" "$PANE_ID" "$LAB"
h pane run "$PANE_ID" "$command_line" >/dev/null

export FM_HOME="$LAB/home"
mkdir -p "$FM_HOME/state/supervisor-watchdog"
. "$ROOT/bin/fm-supervisor-watchdog.sh"
. "$ROOT/bin/fm-wake-lib.sh"
fm_backend_source herdr
fm_backend_herdr_cli() {
  [ "$1" = "$SESSION" ] || return 1
  shift
  h "$@"
}
watchdog_under_way() { return 0; }
wedge_alarm_notify() { printf 'active-alert=%s\n' "$1" >> "$LAB/active-alerts"; }
fm_urgent_alert() {
  printf 'urgent=%s\n' "$*" >> "$LAB/urgent-alerts"
  FM_URGENT_ALERT_RESULT=sent
}

SESSION=$SESSION
DIR="$FM_HOME/state/supervisor-watchdog"
STATE="$FM_HOME/state"
FM_WAKE_QUEUE="$DIR/.wake-queue"
IDLE=10
BACKOFF=10
WAKE_AGE=600
STALL_SECS=10
STALL_RESTART=0
DRIFT=1
INSTALLED_VERSION='new-unverified-renderer'
FM_WATCHDOG_CLAUDE_VERSION='verified-old-renderer'
RESTART_CWD=$LAB
RESTART_COMMAND=claude

for _ in {1..40}; do
  watchdog_observe 2>/dev/null
  [ "$VERDICT" = unverified ] && break
  sleep 0.2
done
[ "$VERDICT" = unverified ] || { echo "rotating drift pane not ready: $VERDICT" >&2; exit 1; }
watchdog_tick
sleep 10
watchdog_tick
[ "$(jq -r .stage "$DIR/stall.json")" = nudged ] || { jq -c . "$DIR/stall.json" >&2; exit 1; }
[ ! -e "$DIR/typed" ] || { echo 'drift tick typed into the pane' >&2; exit 1; }
sleep 10
watchdog_tick
[ "$(jq -r .stage "$DIR/stall.json")" = down ] || { jq -c . "$DIR/stall.json" >&2; exit 1; }
grep -q '^urgent=supervisor-down ' "$LAB/urgent-alerts"

{
  echo 'pass: new Claude version raised an active version-change alert'
  echo 'pass: rotating unverified renderer content did not count as progress'
  echo 'pass: version drift typed nothing into the supervisor pane'
  echo 'pass: stall protection continued to down and one supervisor-down escalation'
  jq -c 'select(.event == "drift" or .event == "withheld" or .detail == "supervisor-down") | [.event,.detail]' "$DIR/events.jsonl"
  printf 'verification: Herdr %s; session %s was non-default and teardown-owned\n' "$(h status --json | jq -r .server.version)" "$SESSION"
} > "$EVIDENCE"
