#!/usr/bin/env bash
# Checkpoint warnings never change status lifecycle decisions.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-checkpoint-fields)
sha=1234567890123456789012345678901234567890
good="working [at=1793316706]: checkpoint; done=tests; next=review; how_to_resume=run tests; branch=fm/example; checkpoint_sha=$sha"
warning=$(status_checkpoint_warning "$good")
assert_equals '' "$warning" 'complete checkpoint must be quiet'
warning=$(status_checkpoint_warning 'paused [at=1793316706]: waiting for CI until 2026-10-30T03:00Z')
assert_contains "$warning" 'done' 'missing pause fields named'
assert_contains "$warning" 'checkpoint_sha' 'missing sha named'
warning=$(status_checkpoint_warning 'working: checkpoint; done=tests; next= ; how_to_resume=review; branch=fm/example; checkpoint_sha=local')
assert_contains "$warning" 'next' 'empty field rejected'
assert_equals '' "$(status_checkpoint_warning 'working: setup complete')" 'ordinary progress is not a checkpoint'
assert_equals '' "$(status_checkpoint_warning 'done: report complete')" 'terminal result is not a checkpoint'
printf '%s\n' "$good" 'working: checkpoint; done=tests' > "$TMP_ROOT/item.status"
out=$(scan_unread_surface_lines "$TMP_ROOT")
assert_contains "$out" 'working: checkpoint; done=tests' 'malformed checkpoint surfaced to drain'
assert_not_contains "$out" "$good" 'complete checkpoint stays silent'
# Generated scout and ship output shares the same fixed fields.
for kind in ship scout; do
  extra=(--scout)
  [ "$kind" != ship ] || extra=(--mode local-only)
  FM_HOME="$TMP_ROOT/home" bash "$ROOT/bin/fm-brief.sh" "$kind" demo "${extra[@]+"${extra[@]}"}" >/dev/null
  brief=$(cat "$TMP_ROOT/home/data/$kind/brief.md")
  assert_contains "$brief" 'how_to_resume=' 'generated brief specifies fixed resume field'
  assert_contains "$brief" 'checkpoint_sha=' 'generated brief specifies fixed commit field'
done
pass 'fixed checkpoint fields warn through unread status and appear in both brief roles'

# Exercise the supervisor's actual drain surface and its once-only cursor.
# shellcheck source=tests/wake-helpers.sh
. "$ROOT/tests/wake-helpers.sh"
dir=$(make_case checkpoint-drain)
printf 'note: initialize cursor\n' > "$dir/state/checkpoint.status"
FM_STATE_OVERRIDE="$dir/state" bash "$ROOT/bin/fm-wake-drain.sh" >/dev/null || fail 'initial drain'
printf '%s\n' 'working: checkpoint; done=tests' >> "$dir/state/checkpoint.status"
out=$(FM_STATE_OVERRIDE="$dir/state" bash "$ROOT/bin/fm-wake-drain.sh") || fail 'checkpoint drain'
assert_contains "$out" 'warning: checkpoint missing or invalid' 'actual drain prints advisory warning'
out=$(FM_STATE_OVERRIDE="$dir/state" bash "$ROOT/bin/fm-wake-drain.sh") || fail 'second drain'
assert_not_contains "$out" 'warning: checkpoint missing or invalid' 'warning is presented once'
pass 'checkpoint warnings reach the actual drain once without blocking it'
