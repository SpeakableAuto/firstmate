#!/usr/bin/env bash
# Real backlog mutations feed the journal; report fixtures exercise day windows.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-flow-report)
command -v tasks-axi >/dev/null || { echo 'ok - skipped (tasks-axi missing)'; exit 0; }
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/data" "$FM_HOME/config"
printf 'backend = "markdown"\n' > "$FM_HOME/.tasks.toml"
cp "$ROOT/tests/fixtures/finish-first/backlog.md" "$FM_HOME/data/backlog.md"
wrapper="$ROOT/bin/fm-tasks-axi.sh"
report="$ROOT/bin/fm-flow-report.sh"
out=$(bash "$report" --since 2020-10-27 --until 2020-10-30)
assert_contains "$out" unknown 'missing history must not invent counts'
bash "$wrapper" start candidate >/dev/null
bash "$wrapper" start candidate >/dev/null
bash "$wrapper" done candidate --note 'test delivered' --no-prune >/dev/null
bash "$wrapper" done candidate --note 'test delivered' --no-prune >/dev/null
bash "$wrapper" reopen candidate >/dev/null
bash "$wrapper" reopen candidate >/dev/null
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PY'
import json, sys
rows=[json.loads(line) for line in open(sys.argv[1])]
events=[r for r in rows if r['type']=='transition']
assert [r['action'] for r in events] == ['start','done','reopen'], events
assert all(r['task_id']=='candidate' and r['priority']==2 and r['timestamp'] for r in events)
PY
# Lifecycle mutations must use the same journal, without relying on wrapper use.
FM_HOME="$FM_HOME" bash -c '
  . "$1/bin/fm-tasks-axi-lib.sh"
  . "$1/bin/fm-backlog-transition-lib.sh"
  fm_backlog_start "$FM_HOME/data" candidate
  fm_backlog_done "$FM_HOME/data" candidate --note delivered --no-prune
' _ "$ROOT" || fail 'lifecycle mutations failed'
python3 - "$FM_HOME/data/flow-history.jsonl" <<'PY'
import json, sys
rows=[json.loads(line) for line in open(sys.argv[1])]
assert [r['action'] for r in rows if r['type']=='transition'] == ['start','done','reopen','start','done']
# Keep real mutation evidence, move timestamps into a completed UTC day.
rows[0]['timestamp']='2020-10-26T23:00:00Z'
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
out=$(bash "$report" --since 2020-10-25 --until 2020-10-29)
assert_contains "$out" '2020-10-25 unknown' 'pre-journal day unknown'
assert_contains "$out" '2020-10-27 finished=1 started=1 reopened=1' 'same job counted once per day'
assert_contains "$out" 'finished: candidate' 'finished jobs named separately'
assert_contains "$out" 'started: candidate' 'started jobs named separately'
assert_contains "$out" 'stop_starting: yes' 'two consecutive days raise the signal'
out=$(bash "$report" --since 2020-10-29 --until 2020-10-29)
assert_contains "$out" 'stop_starting: yes' 'lookback preserves the signal in a one-day morning report'
out=$(bash "$report" --since 2020-10-29 --until 2020-10-30)
assert_contains "$out" 'stop_starting: no' 'an empty day breaks the run'
# Bad history is not silently ignored, and the report remains read-only.
printf 'broken\n' >> "$FM_HOME/data/flow-history.jsonl"
before=$(cksum "$FM_HOME/data/flow-history.jsonl")
out=$(bash "$report" --since 2020-10-27 --until 2020-10-29)
assert_contains "$out" unknown 'corrupt history reports unknown'
assert_equals "$before" "$(cksum "$FM_HOME/data/flow-history.jsonl")" 'report must not repair history'
pass 'flow journal and read-only report preserve transitions, coverage and two-day signal'
