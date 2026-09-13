#!/usr/bin/env bash
# Behavior checks for scoped private context and its ordinary-crew handoff.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-workflow-context)
CONTEXT_HOME="$TMP_ROOT/home"
mkdir -p "$CONTEXT_HOME/config" "$CONTEXT_HOME/data/workflow/projects"
context() {
  FM_HOME="$CONTEXT_HOME" "$ROOT/bin/fm-workflow-context.sh" "$@"
}
out=$(context startup)
[ -z "$out" ] || fail "unconfigured context should be inert"
printf 'on\n' > "$CONTEXT_HOME/config/workflow-context"
cat > "$CONTEXT_HOME/data/workflow/index.md" <<'EOF'
# Workflow context
| Scope | Status | Path | Source | End-check |
| --- | --- | --- | --- | --- |
| global | active | agreement.md | approved global | none |
| project:alpha | active | projects/alpha.md | approved alpha | none |
| project:beta | active | projects/beta.md | approved beta | none |
| task:alpha-task | active | temporary.md | exact temporary allowance | until:2026-09-13T00:00:00Z |
| task:alpha-task | stopped | stop.md | explicit stop | until:2026-09-12T00:00:00Z |
| project:alpha | superseded | old.md | old agreement | none |
| project:alpha | active | condition.md | current owner | condition:owner confirms demo ready |
EOF
printf 'GLOBAL_RULE\n' > "$CONTEXT_HOME/data/workflow/agreement.md"
printf 'ALPHA_RULE\n' > "$CONTEXT_HOME/data/workflow/projects/alpha.md"
printf 'BETA_RULE\n' > "$CONTEXT_HOME/data/workflow/projects/beta.md"
printf 'TEMPORARY_ALLOWANCE\n' > "$CONTEXT_HOME/data/workflow/temporary.md"
printf 'STOP_UNTIL_EXPLICIT_RELEASE\n' > "$CONTEXT_HOME/data/workflow/stop.md"
printf 'OLD_AUTHORITY\n' > "$CONTEXT_HOME/data/workflow/old.md"
printf 'CONDITIONAL_RULE\n' > "$CONTEXT_HOME/data/workflow/condition.md"

out=$(context startup --now 2026-09-13T00:00:00Z)
assert_contains "$out" GLOBAL_RULE "startup lacks shared working agreement"
assert_contains "$out" project:alpha "startup lacks project discovery"
assert_not_contains "$out" ALPHA_RULE "startup eagerly loads project alpha"
assert_not_contains "$out" BETA_RULE "startup eagerly loads project beta"
pass "cold startup includes shared agreement and scoped discovery only"

out=$(context project alpha --task alpha-task --now 2026-09-12T23:59:59Z)
assert_contains "$out" GLOBAL_RULE "project loses global rule"
assert_contains "$out" ALPHA_RULE "matching project absent"
assert_contains "$out" TEMPORARY_ALLOWANCE "active allowance absent before deadline"
assert_contains "$out" STOP_UNTIL_EXPLICIT_RELEASE "elapsed stop was lifted"
assert_contains "$out" 'OWNER CHECK REQUIRED' "condition was assumed satisfied"
assert_not_contains "$out" BETA_RULE "unrelated project leaks into context"
assert_not_contains "$out" OLD_AUTHORITY "superseded authority reactivated"
out=$(context project alpha --task alpha-task --now 2026-09-13T00:00:00Z)
assert_not_contains "$out" TEMPORARY_ALLOWANCE "deadline did not withhold allowance"
assert_contains "$out" 'INACTIVE: content withheld' "end boundary not explained"
assert_contains "$out" STOP_UNTIL_EXPLICIT_RELEASE "expiry resumed stopped work"
out=$(context project beta --now 2026-09-13T00:00:00Z)
assert_contains "$out" BETA_RULE "second project missing"
assert_not_contains "$out" ALPHA_RULE "alpha preference leaked into beta"
assert_not_contains "$out" STOP_UNTIL_EXPLICIT_RELEASE "task stop leaked into unrelated project"
pass "scope selection and expiry preserve explicit stops and condition ownership"

# Unrelated project files need not be readable to retrieve alpha.
rm "$CONTEXT_HOME/data/workflow/projects/beta.md"
context project alpha >/dev/null || fail "selector read unrelated project body"
if context project beta > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then
  fail "missing selected input was accepted"
fi
[ ! -s "$TMP_ROOT/out" ] || fail "invalid context emitted partial instructions"
pass "missing applicable content refuses atomically without reading other bodies"

FM_HOME="$CONTEXT_HOME" "$ROOT/bin/fm-brief.sh" alpha-task alpha --mode direct-PR >/dev/null
brief="$CONTEXT_HOME/data/alpha-task/brief.md"
assert_grep GLOBAL_RULE "$brief" "crew loses global agreement"
assert_grep ALPHA_RULE "$brief" "crew loses project instructions"
assert_grep STOP_UNTIL_EXPLICIT_RELEASE "$brief" "crew loses stop"
assert_grep 'Refresh:' "$brief" "crew lacks current retrieval command"
assert_not_contains "$(cat "$brief")" BETA_RULE "crew receives unrelated preferences"
if FM_HOME="$CONTEXT_HOME" "$ROOT/bin/fm-brief.sh" bad-task beta --scout > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then
  fail "brief accepted missing project context"
fi
[ ! -e "$CONTEXT_HOME/data/bad-task/brief.md" ] || fail "invalid context left a scaffold"
pass "ordinary crew receives selected context and invalid context blocks scaffolding"

# Verify the actual generated interface, not the scaffold's implementation.
# Every mode keeps private material outside the first Task section, including
# scouts whose report could later be copied into a PR or another evidence packet.
for mode in no-mistakes direct-PR local-only scout; do
  if [ "$mode" = scout ]; then
    FM_HOME="$CONTEXT_HOME" "$ROOT/bin/fm-brief.sh" "privacy-$mode" alpha --scout >/dev/null
  else
    FM_HOME="$CONTEXT_HOME" "$ROOT/bin/fm-brief.sh" "privacy-$mode" alpha --mode "$mode" >/dev/null
  fi
  python3 - "$CONTEXT_HOME/data/privacy-$mode/brief.md" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
brief = path.read_text().replace("{TASK}", "PUBLIC_ACCEPTANCE: return the agreed result.")
task_start = brief.index("# Task\n") + len("# Task\n")
task_end = brief.index("\n# ", task_start)
task = brief[task_start:task_end]
assert "PUBLIC_ACCEPTANCE" in task
for private in ("GLOBAL_RULE", "ALPHA_RULE", "data/workflow", "Refresh:"):
    assert private not in task, (path.name, "private content in task", private)
private_start = brief.index("# Private operational context - never publish")
assert private_start > brief.index("# Definition of done") > task_end
assert "GLOBAL_RULE" in brief[private_start:]
assert "ALPHA_RULE" in brief[private_start:]
assert "outside the Task and its publishable implementation intent" in brief[private_start:]
assert "`--intent`, PRs, commits, reports or evidence artifacts" in brief[private_start:]
assert "without private policy text or provenance" in brief[private_start:]
assert "never attach this section or the complete brief" in brief[private_start:]
PY
done
pass "all generated delivery modes separate private context from publishable task intent"

# A symlink never widens the private document boundary.
rm "$CONTEXT_HOME/data/workflow/projects/alpha.md"
ln -s "$CONTEXT_HOME/data/workflow/agreement.md" "$CONTEXT_HOME/data/workflow/projects/alpha.md"
if context project alpha > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then
  fail "symlinked selected document was followed"
fi
[ ! -s "$TMP_ROOT/out" ] || fail "symlink failure emitted partial context"
printf 'invalid\n' > "$CONTEXT_HOME/config/workflow-context"
if context startup > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then
  fail "malformed configuration was silently ignored"
fi
pass "invalid settings and unsafe document paths refuse"
