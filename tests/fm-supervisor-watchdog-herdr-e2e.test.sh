#!/usr/bin/env bash
# Real Herdr transport with a stub supervisor, not a live-Claude certification.
# Every Herdr call, including the stub's status reports, goes through the lab
# helper with an explicitly named non-default session. No model tokens spent.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by herdr)"; exit 0; }
LAB=$(mktemp -d)
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name kw1-watchdog)
cleanup_watchdog_lab() {
  local rc=$?
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup_watchdog_lab EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
h() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
h workspace create --cwd "$LAB" --label watchdog-fixture > "$LAB/workspace.json"
PANE_ID=$(h pane list | jq -er '.result.panes[0].pane_id')
cat > "$LAB/stub.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
helper=$1 session=$2 pane=$3 directory=$4
mode=$(cat "$directory/mode")
buf= transcript=
report() { "$helper" run "$session" pane report-agent "$pane" --source watchdog-fixture --agent claude --state "$1" >/dev/null; }
redraw() {
  printf '\033[2J\033[H'
  case "$mode" in
    queue*) printf '● Fixture turn finished\n' ;;
    *) printf 'API Error: ENOTFOUND\n' ;;
  esac
  [ "$mode" != usage ] || printf 'Usage limit reached · continuing automatically\n'
  [ -z "$transcript" ] || printf '❯ %s\nRecovered fixture turn\n' "$transcript"
  printf '\n────────────────────────────────────────\n❯ %s' "$buf"
  # Claude's dim rotating suggestion occupies an otherwise empty composer.
  case "$mode:$buf" in queue*:) printf '\033[2myes, continue with the next step\033[0m' ;; esac
}
case "$mode" in draft|queue-draft) buf='human draft' ;; esac
old_stty=$(stty -g)
trap 'stty "$old_stty"' EXIT
stty -echo -icanon min 1 time 0
# A finished turn leaves a queue-mode supervisor done rather than freshly idle.
case "$mode" in queue*) report working ;; esac
report idle
redraw
while IFS= read -r -n 1 ch; do
  case "$ch" in
    ''|$'\r'|$'\n')
      printf '%s\n' "$buf" >> "$directory/submissions"
      report working
      transcript=$buf
      buf=
      redraw
      sleep 1
      report idle
      ;;
    *)
      if [ -z "$buf" ]; then
        buf=$ch
        printf '%s' "$ch" >> "$directory/typed"
        # Replace the dim queue suggestion once; subsequent characters can
        # render incrementally like ordinary terminal input.
        case "$mode" in queue*) redraw ;; *) printf '%s' "$ch" ;; esac
      else
        buf="$buf$ch"
        printf '%s' "$ch" >> "$directory/typed"
        printf '%s' "$ch"
      fi
      ;;
  esac
done
STUB
printf '%s\n' success > "$LAB/mode"
# Bash quote each fixed argument; no user data or credentials enter this command.
printf -v command_line 'bash %q %q %q %q %q' "$LAB/stub.sh" "$HERDR_LAB_HELPER" "$HERDR_LAB_SESSION" "$PANE_ID" "$LAB"
h pane run "$PANE_ID" "$command_line" >/dev/null
export FM_HOME="$LAB/home"
mkdir -p "$FM_HOME/state/supervisor-watchdog"
# shellcheck source=bin/fm-supervisor-watchdog.sh
. "$ROOT/bin/fm-supervisor-watchdog.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
fm_backend_source herdr
# Keep the production transport/guards; route all its CLI calls through the
# safety helper instead of letting a backend launch or discover a session.
fm_backend_herdr_cli() {
  [ "$1" = "$HERDR_LAB_SESSION" ] || return 1
  shift
  h "$@"
}
SESSION=$HERDR_LAB_SESSION
DIR="$FM_HOME/state/supervisor-watchdog"
IDLE=10 BACKOFF=10
# Network states are deliberate fixture inputs; no live provider is contacted.
NETWORK=down
watchdog_probe() { [ "$NETWORK" = up ]; }
for _ in {1..40}; do
  watchdog_observe
  [ "$VERDICT" = error ] && break
  sleep 0.2
done
[ "$VERDICT" = error ] || fail "stub error/composer not recognized: $VERDICT"
watchdog_tick
sleep 10
watchdog_tick
[ ! -e "$LAB/typed" ] || fail 'network-down tick typed input'
pass 'real Herdr transport withholds input while network fixture is down'
# Advance only the persisted probe deadline, not the observation window.
# The real empty-prompt observations above were ten seconds apart.
jq '.next=0' "$DIR/incident.json" > "$DIR/edit.json"
mv "$DIR/edit.json" "$DIR/incident.json"
NETWORK=up
watchdog_tick
[ "$(cat "$LAB/submissions")" = 'Resume the interrupted work.' ] || fail 'resume did not land as its own turn'
[ "$(tail -1 "$DIR/events.jsonl" | jq -r .event)" = submitted ] || fail 'resume was not confirmed'
pass 'real Herdr transport submits and confirms one resume turn'
watchdog_tick
[ "$(wc -l < "$LAB/submissions" | tr -d ' ')" = 1 ] || fail 'incident replayed'
pass 'durable incident prevents a duplicate resume'
# Fresh panes give draft/usage cases their own incident and owned stub process.
for mode in draft usage; do
  CASE_DIR="$LAB/$mode"
  mkdir -p "$CASE_DIR"
  printf '%s\n' "$mode" > "$CASE_DIR/mode"
  h workspace create --cwd "$CASE_DIR" --label "watchdog-$mode" > "$CASE_DIR/workspace.json"
  PANE_ID=$(h pane list | jq -er '.result.panes[-1].pane_id')
  printf -v command_line 'bash %q %q %q %q %q' "$LAB/stub.sh" "$HERDR_LAB_HELPER" "$HERDR_LAB_SESSION" "$PANE_ID" "$CASE_DIR"
  h pane run "$PANE_ID" "$command_line" >/dev/null
  DIR="$CASE_DIR/state"
  mkdir -p "$DIR"
  for _ in {1..40}; do
    watchdog_observe 2>/dev/null
    case "$VERDICT" in composer-pending|usage-limit) break ;; esac
    sleep 0.2
  done
  case "$mode:$VERDICT" in draft:composer-pending|usage:usage-limit) ;; *) fail "$mode stub not ready: $VERDICT" ;; esac
  watchdog_tick
  [ ! -e "$CASE_DIR/typed" ] && [ ! -e "$CASE_DIR/submissions" ] || fail "$mode received input"
  pass "real Herdr transport preserves $mode screen"
done
# An aged durable wake on a finished supervisor with an empty prompt is rung.
WAKE_AGE=600
for mode in queue queue-draft; do
  CASE_DIR="$LAB/$mode"
  mkdir -p "$CASE_DIR"
  printf '%s\n' "$mode" > "$CASE_DIR/mode"
  h workspace create --cwd "$CASE_DIR" --label "watchdog-$mode" > "$CASE_DIR/workspace.json"
  PANE_ID=$(h pane list | jq -er '.result.panes[-1].pane_id')
  printf -v command_line 'bash %q %q %q %q %q' "$LAB/stub.sh" "$HERDR_LAB_HELPER" "$HERDR_LAB_SESSION" "$PANE_ID" "$CASE_DIR"
  h pane run "$PANE_ID" "$command_line" >/dev/null
  DIR="$CASE_DIR/state"
  mkdir -p "$DIR"
  FM_WAKE_QUEUE="$DIR/.wake-queue"
  printf '%s\t41\tcheck\tfixture\tcheck: fixture row\n' "$(( $(date +%s) - 700 ))" > "$FM_WAKE_QUEUE"
  for _ in {1..40}; do
    watchdog_observe 2>/dev/null
    case "$VERDICT" in clear|composer-pending) break ;; esac
    sleep 0.2
  done
  case "$mode:$VERDICT" in queue:clear|queue-draft:composer-pending) ;; *) fail "$mode stub not ready: $VERDICT" ;; esac
  identity=$(watchdog_identity)
  watchdog_tick
  sleep 10
  watchdog_tick
  if [ "$mode" = queue ]; then
    [ "$(cat "$CASE_DIR/submissions" 2>/dev/null)" = 'Supervisor watchdog: wakes are queued undelivered. Run bin/fm-wake-drain.sh now.' ] \
      || fail "queue ring did not land as its own turn on a ${identity#*$'\t'} supervisor"
    [ "$(tail -1 "$DIR/events.jsonl" | jq -c '[.event,.detail]')" = '["submitted","queue-nudge"]' ] || fail 'queue ring was not confirmed'
    pass "real Herdr transport rings an aged queue on a ${identity#*$'\t'} supervisor with a dim suggestion"
  else
    [ ! -e "$CASE_DIR/typed" ] && [ ! -e "$CASE_DIR/submissions" ] || fail 'queue ring typed over a draft'
    pass 'real Herdr transport never rings over a draft'
  fi
done
unset FM_WAKE_QUEUE
printf 'verification: Herdr %s; stub supervisor only, real Claude/operator check remains required\n' "$(h status --json | jq -r .server.version)"
