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
receipt_data="$TMP_ROOT/receipt/data"
receipt_state="$TMP_ROOT/receipt/state"
mkdir -p "$receipt_data" "$receipt_state"
receipt_token=$(python3 "$ROOT/bin/fm-flow-history.py" --data "$receipt_data" begin badreceipt 2 none --kind ship)
FM_STATE_OVERRIDE="$receipt_state" bash -c '
  . "$1"
  fm_flow_finish "$2" "$3" start badreceipt 0 malformed
  fm_flow_finish "$2" "$3" start badreceipt 0 malformed
' _ "$ROOT/bin/fm-flow-history-lib.sh" "$receipt_data" "$receipt_token"
assert_contains "$(cat "$receipt_state/.flow-history-warning")" 'receipt missing' 'current receipt failure keeps its warning episode open'
receipt_alerts=$(awk -F '\t' '$3 == "check" && $4 == "flow-history" { count++ } END { print count + 0 }' "$receipt_state/.wake-queue")
assert_equals 1 "$receipt_alerts" 'grace-period health does not duplicate an active receipt warning'
pass 'failed current receipts retain warning deduplication during health grace'
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
assert [r['landing'] for r in events] == ['none','none','none','none'], events
PY
# Help is read-only and must reach the underlying CLI unchanged.
before=$(cksum "$FM_HOME/data/flow-history.jsonl")
out=$(bash "$wrapper" start --help)
assert_contains "$out" 'usage: tasks-axi start' 'mutation help remains available'
assert_equals "$before" "$(cksum "$FM_HOME/data/flow-history.jsonl")" 'help does not journal'
# Teardown-owned markers carry verified merge and local-landing authority.
FM_HOME="$FM_HOME" bash -c '
  . "$1/bin/fm-tasks-axi-lib.sh"
  . "$1/bin/fm-backlog-transition-lib.sh"
  mkdir -p "$FM_HOME/state"
  FM_BACKLOG_FLOW_LANDING=merge
  fm_backlog_close_marker_write "$FM_HOME/state" oldest "$FM_HOME/data" test-merge \
    --pr https://github.com/example/repo/pull/2
  FM_BACKLOG_FLOW_LANDING=none
  fm_backlog_close_marker_replay "$FM_HOME/state" "$FM_HOME/state/oldest.backlog-close" "$FM_HOME/data"
  fm_backlog_start "$FM_HOME/data" candidate
  FM_BACKLOG_FLOW_LANDING=local
  fm_backlog_close_marker_write "$FM_HOME/state" candidate "$FM_HOME/data" test-local \
    --note "local main"
  FM_BACKLOG_FLOW_LANDING=none
  fm_backlog_close_marker_replay "$FM_HOME/state" "$FM_HOME/state/candidate.backlog-close" "$FM_HOME/data"
' _ "$ROOT" || fail 'lifecycle mutations failed'
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PY'
import json, sys
rows=[json.loads(line) for line in open(sys.argv[1])]
events=[r for r in rows if r['type']=='transition']
assert [r['action'] for r in events] == ['start','done','reopen','done','done','start','done']
assert [r['landing'] for r in events] == ['none','none','none','none','merge','none','local']
# Keep real mutation evidence, move timestamps into a completed AEST day.
rows[0]['timestamp']='2020-10-26T13:00:00Z'
for row in rows[1:]: row['timestamp']='2020-10-27T12:00:00Z'
# Two days with more starts than finishes.
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
assert_contains "$out" '2020-10-27 finished=2 closed-not-landed=0 started=1' 'landing evidence wins the daily job classification'
assert_contains "$out" 'finished: candidate, oldest' 'landed jobs named separately'
assert_contains "$out" 'closed-not-landed: -' 'landed jobs are not also reported as closed-not-landed'
assert_contains "$out" 'started: candidate' 'started jobs named separately'
assert_not_contains "$out" reopened 'reopen transitions are not a public report category'
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
assert_contains "$out" 'history_warning: unknown days' 'receipt before its attempt is invalid'
assert_contains "$out" 'stop_starting: yes' 'older corrupt receipt does not blind later valid days'
cp "$TMP_ROOT/good-history" "$FM_HOME/data/flow-history.jsonl"
printf '{"type":"attempt","timestamp":"2020-10-30T12:00:00Z","token":"unfinished","task_id":"unfinished","priority":3}\n' >> "$FM_HOME/data/flow-history.jsonl"
out=$(bash "$report" --date 2020-10-29)
assert_contains "$out" 'stop_starting: yes' 'future unmatched attempt does not blind prior complete days'
pass 'journal edges preserve help, calendar boundaries and honest unknown results'

# Invalid wrapper calls retain native diagnostics; option-first calls work.
rc=0
out=$(bash "$wrapper" start 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'missing id must fail'
[ -n "$out" ] || fail 'missing id must explain the error'
rc=0
out=$(bash "$wrapper" start nosuch 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'unknown id must fail'
[ -n "$out" ] || fail 'unknown id must explain the error'
bash "$wrapper" "done" --note x carried --no-prune >/dev/null || fail 'flag-first mutation works'
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PYFLAG'
import json, sys
rows=[json.loads(line) for line in open(sys.argv[1])]
assert rows[-1]['type']=='transition' and rows[-1]['action']=='done' and rows[-1]['task_id']=='carried', rows[-1]
PYFLAG
# A torn tail does not poison later receipts.
bash "$wrapper" reopen oldest >/dev/null
printf '{"type":"attempt","tok' >> "$FM_HOME/data/flow-history.jsonl"
bash "$wrapper" start oldest >/dev/null || fail 'torn tail must not block lifecycle'
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PYTAIL'
import json, sys
rows=[]
for line in open(sys.argv[1]):
    try: rows.append(json.loads(line))
    except ValueError: pass
assert rows[-1]['type']=='transition' and rows[-1]['task_id']=='oldest', rows[-1]
PYTAIL
first_alerts=$(awk -F '\t' '$3 == "check" && $4 == "flow-history" { count++ } END { print count + 0 }' "$FM_HOME/state/.wake-queue")
cp "$TMP_ROOT/good-history" "$FM_HOME/data/flow-history.jsonl"
bash "$wrapper" "done" oldest --note repaired --no-prune >/dev/null
assert_absent "$FM_HOME/state/.flow-history-warning" 'healthy history closes the warning episode'
bash "$wrapper" reopen oldest >/dev/null
printf '{"type":"attempt","tok' >> "$FM_HOME/data/flow-history.jsonl"
bash "$wrapper" start oldest >/dev/null || fail 'second torn tail must not block lifecycle'
second_alerts=$(awk -F '\t' '$3 == "check" && $4 == "flow-history" { count++ } END { print count + 0 }' "$FM_HOME/state/.wake-queue")
assert_equals "$((first_alerts + 1))" "$second_alerts" 'a later identical incident publishes a new warning'
pass 'wrapper errors recover and later incidents alert again'

# Historical signals do not change when current backlog holds change.
cp "$TMP_ROOT/good-history" "$FM_HOME/data/flow-history.jsonl"
cat >> "$FM_HOME/data/backlog.md" <<'HELD'
## In flight
- [ ] first-28 - Held job (kind: ship) (hold: Outside answer) (hold-kind: external)
- [ ] second-28 - Held job (kind: ship) (hold: Outside answer) (hold-kind: captain)
- [ ] first-29 - Held job (kind: ship) (hold: Outside answer) (hold-kind: external)
- [ ] second-29 - Held job (kind: ship) (hold: Outside answer) (hold-kind: captain)
HELD
out=$(bash "$report" --date 2020-10-29)
assert_contains "$out" 'started=2' 'held starts remain visible in the daily report'
assert_contains "$out" 'stop_starting: yes' 'current holds do not rewrite recorded starts'
pass 'signal is stable after current backlog state changes'

assert_contains "$(cat "$FM_HOME/state/.wake-queue")" 'flow-history' 'damaged history wakes the supervisor'
# A completed scout counts as delivered on the same basis as a landed ship.
cp "$TMP_ROOT/good-history" "$FM_HOME/data/flow-history.jsonl"
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PYSCOUT'
import json, sys
p=sys.argv[1]
with open(p,'a') as f:
    for day in ('28','29'):
        for name in ('first','second'):
            task=f'{name}-{day}'
            row=dict(token=f'delivered-{task}', task_id=task, priority=2, kind='scout', landing='report', timestamp=f'2020-10-{day}T13:00:00Z')
            f.write(json.dumps(dict(row,type='attempt'))+'\n')
            f.write(json.dumps(dict(row,type='transition',action='done',result=0))+'\n')
PYSCOUT
out=$(bash "$report" --date 2020-10-29)
assert_contains "$out" 'finished=2' 'scout reports are finished work'
assert_contains "$out" 'stop_starting: no' 'delivered scouts balance their starts'
pass 'scout delivery and damaged-history wake are visible'

# Real parallel wrappers must retain complete receipts under contention.
pids=()
for i in 1 2 3 4 5 6; do
  bash "$wrapper" add "parallel-$i" 'Concurrent fixture' --kind ship >/dev/null
  bash "$wrapper" start "parallel-$i" > "$TMP_ROOT/parallel-$i.out" 2>&1 &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || fail 'parallel start failed'; done
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PYPARALLEL'
import json, sys
rows=[json.loads(line) for line in open(sys.argv[1])]
starts=[r['task_id'] for r in rows if r['type']=='transition' and r['action']=='start' and r['task_id'].startswith('parallel-')]
assert len(set(starts))==6 and len(starts)==6, starts
PYPARALLEL
pass 'parallel real wrapper starts retain every transition'

# Independent report probes pin classification, non-worker starts and bounded damage.
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PYPROBES'
import json, sys
rows=[dict(type='coverage',version=1,timestamp='2020-10-26T00:00:00Z')]
for day in ('27','28','29'):
    for kind, action, landing in [('ship','done','none'),('captain','start','none')]:
        task=f'{kind}-{day}'
        row=dict(token=task,task_id=task,priority=2,kind=kind,landing=landing,timestamp=f'2020-10-{day}T12:00:00Z')
        rows.extend([dict(row,type='attempt'),dict(row,type='transition',action=action,result=0)])
with open(sys.argv[1],'w') as f:
    for i,row in enumerate(rows):
        f.write(json.dumps(row)+'\n')
        if i==1: f.write('torn line\n')
PYPROBES
out=$(bash "$report" --date 2020-10-29)
assert_contains "$out" '2020-10-29 finished=0 closed-not-landed=1 started=1' 'a bare close is never delivered'
assert_contains "$out" 'closed-not-landed: ship-29' 'bare close stays named'
assert_contains "$out" 'stop_starting: no' 'captain starts do not activate the stop'
out=$(bash "$report" --date 2020-10-27)
assert_contains "$out" '2020-10-27 unknown' 'torn row damages its own day'
pass 'bare closes, non-worker starts and bounded torn rows retain report semantics'

# Journal a real linked review start, then prove its identity survives later parent closure.
cat >> "$FM_HOME/data/backlog.md" <<'SERVES'
## Queued
- [ ] helper - Independent review (kind: scout) (serves: current)
SERVES
bash "$wrapper" start helper >/dev/null
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PYSERVES'
import json, sys
rows=[json.loads(line) for line in open(sys.argv[1]) if not line.startswith('torn')]
helper=[r for r in rows if r.get('task_id')=='helper']
assert len(helper)==2 and all(r.get('serves')=='current' for r in helper), helper
# Put the real receipt on each of two completed days.
rows=[dict(type='coverage',version=1,timestamp='2020-10-26T00:00:00Z')]
for day in ('28','29'):
    for row in helper:
        rows.append(dict(row,timestamp=f'2020-10-{day}T12:00:00Z',token=f'helper-{day}'))
with open(sys.argv[1],'w') as f:
    for row in rows: f.write(json.dumps(row)+'\n')
PYSERVES
bash "$wrapper" done current --no-prune >/dev/null
out=$(bash "$report" --date 2020-10-29)
assert_contains "$out" 'finished=0 closed-not-landed=0 started=0' 'support work is not a new job'
assert_contains "$out" 'stop_starting: no' 'recorded support work cannot activate the stop'
pass 'linked review receipts preserve finishing-work identity'
