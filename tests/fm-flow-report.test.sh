#!/usr/bin/env bash
# Real backlog mutations feed the journal; report fixtures exercise day windows.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-flow-report)
command -v tasks-axi >/dev/null || { echo 'ok - skipped (tasks-axi missing)'; exit 0; }
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE
export TZ=UTC
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/data" "$FM_HOME/config"
printf 'backend = "markdown"\n' > "$FM_HOME/.tasks.toml"
cp "$ROOT/tests/fixtures/finish-first/backlog.md" "$FM_HOME/data/backlog.md"
wrapper="$ROOT/bin/fm-tasks-axi.sh"
report="$ROOT/bin/fm-flow-report.sh"
out=$(bash "$report" --date 2020-10-30)
assert_contains "$out" unknown 'missing history must not invent counts'
bash "$wrapper" start candidate >/dev/null
bash "$wrapper" start candidate >/dev/null
bash "$wrapper" "done" candidate --note 'test delivered' --no-prune >/dev/null
bash "$wrapper" "done" candidate --note 'test delivered' --no-prune >/dev/null
bash "$wrapper" reopen candidate >/dev/null
bash "$wrapper" reopen candidate >/dev/null
bash "$wrapper" "done" oldest --pr https://github.com/example/repo/pull/2 --no-prune >/dev/null
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PY'
import json, sys
rows=[json.loads(line) for line in open(sys.argv[1])]
events=[r for r in rows if r['type']=='transition']
assert [r['action'] for r in events] == ['start','done','reopen','done'], events
assert all(r['priority']==2 and r['timestamp'] for r in events)
assert [r['landing'] for r in events] == ['none','none','none','merge'], events
PY
# Help is read-only and must reach the underlying CLI unchanged.
before=$(cksum "$FM_HOME/data/flow-history.jsonl")
out=$(bash "$wrapper" start --help)
assert_contains "$out" 'usage: tasks-axi start' 'mutation help remains available'
assert_equals "$before" "$(cksum "$FM_HOME/data/flow-history.jsonl")" 'help does not journal'
# Lifecycle mutations must use the same journal, without relying on wrapper use.
FM_HOME="$FM_HOME" bash -c '
  . "$1/bin/fm-tasks-axi-lib.sh"
  . "$1/bin/fm-backlog-transition-lib.sh"
  fm_backlog_start "$FM_HOME/data" candidate
  fm_backlog_done "$FM_HOME/data" candidate --note "local main" --no-prune
' _ "$ROOT" || fail 'lifecycle mutations failed'
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PY'
import json, sys
rows=[json.loads(line) for line in open(sys.argv[1])]
events=[r for r in rows if r['type']=='transition']
assert [r['action'] for r in events] == ['start','done','reopen','done','start','done']
assert [r['landing'] for r in events] == ['none','none','none','merge','none','local']
# Keep real mutation evidence, move timestamps into a completed AEST day.
rows[0]['timestamp']='2020-10-26T13:00:00Z'
for row in rows[1:]: row['timestamp']='2020-10-27T12:00:00Z'
# Two days with more starts than finishes, and a reopened job.
for day in ('28','29'):
    for task in ('first','second'):
        token=f'{task}-{day}'
        row=dict(timestamp=f'2020-10-{day}T12:00:00Z',task_id=token,priority=2,token=token)
        rows.append(dict(row,type='attempt'))
        rows.append(dict(row,type='transition',action='start',result=0))
with open(sys.argv[1],'w') as f:
    for row in rows: f.write(json.dumps(row)+'\n')
PY
out=$(bash "$report" --date 2020-10-25)
assert_contains "$out" '2020-10-25 unknown' 'pre-journal day unknown'
out=$(bash "$report" --date 2020-10-27)
assert_contains "$out" '2020-10-27 finished=2 closed-not-landed=1 started=1 reopened=1' 'landed and bare closes are separated'
assert_contains "$out" 'finished: candidate, oldest' 'landed jobs named separately'
assert_contains "$out" 'closed-not-landed: candidate' 'bare close is not reported as finished'
assert_contains "$out" 'started: candidate' 'started jobs named separately'
out=$(bash "$report" --date 2020-10-29)
assert_contains "$out" 'stop_starting: yes' 'two consecutive days raise the signal'
out=$(bash "$report" --date 2020-10-30)
assert_contains "$out" 'stop_starting: no' 'an empty day breaks the run'
# Reporting always uses AEST, without changing UTC journal stamps.
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PY'
import json, sys
path=sys.argv[1]
rows=[json.loads(line) for line in open(path)]
rows[0]['timestamp']='2020-10-26T23:00:00Z'
with open(path,'w') as stream:
    for row in rows:
        stream.write(json.dumps(row)+'\n')
PY
out=$(bash "$report" --date 2020-10-27)
assert_contains "$out" 'flow_history: AEST' 'calendar is fixed to AEST'
assert_contains "$out" 'complete coverage from 2020-10-28' 'first partial AEST day is excluded'
assert_contains "$out" '2020-10-27 unknown' 'UTC evening header falls on the next AEST day'
rc=0
out=$(bash "$report" --since 2020-10-27 2>&1) || rc=$?
expect_code 2 "$rc" 'arbitrary report ranges are rejected'
assert_contains "$out" 'unrecognized arguments' 'removed range interface stays unavailable'
cp "$FM_HOME/data/flow-history.jsonl" "$TMP_ROOT/good-history"
# Bad history is not silently ignored, and the report remains read-only.
printf 'broken\n' >> "$FM_HOME/data/flow-history.jsonl"
before=$(cksum "$FM_HOME/data/flow-history.jsonl")
out=$(bash "$report" --date 2020-10-29)
assert_contains "$out" unknown 'corrupt history reports unknown'
assert_equals "$before" "$(cksum "$FM_HOME/data/flow-history.jsonl")" 'report must not repair history'
pass 'flow journal and read-only report preserve transitions, coverage and two-day signal'

# Valid JSON with the wrong shape is also unknown, rather than a traceback.
printf '[]\n' > "$FM_HOME/data/flow-history.jsonl"
out=$(bash "$report" --date 2020-10-29 2>&1)
assert_contains "$out" 'flow_history: unknown' 'non-object journal row rejected'
assert_not_contains "$out" Traceback 'schema failure is a supported unknown result'
cp "$TMP_ROOT/good-history" "$FM_HOME/data/flow-history.jsonl"
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PYBAD'
import json, sys
p=sys.argv[1]
rows=[json.loads(line) for line in open(p)]
rows[2]['timestamp']='2020-10-25T12:00:00Z'
with open(p,'w') as f:
    for row in rows: f.write(json.dumps(row)+'\n')
PYBAD
out=$(bash "$report" --date 2020-10-29)
assert_contains "$out" 'flow_history: unknown' 'receipt before its attempt is invalid'
cp "$TMP_ROOT/good-history" "$FM_HOME/data/flow-history.jsonl"
printf '{"type":"attempt","timestamp":"2020-10-30T12:00:00Z","token":"unfinished","task_id":"unfinished","priority":3}\n' >> "$FM_HOME/data/flow-history.jsonl"
out=$(bash "$report" --date 2020-10-29)
assert_contains "$out" 'stop_starting: unknown' 'unmatched attempt never certifies complete history'
pass 'journal edges preserve help, calendar boundaries and honest unknown results'
