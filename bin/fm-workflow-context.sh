#!/usr/bin/env bash
# Read this home's opt-in scoped workflow instructions without changing state.
# Usage: fm-workflow-context.sh startup [--now <UTC timestamp>]
#        fm-workflow-context.sh project <project-name> [--task <task-id>] [--now <UTC timestamp>]
# docs/configuration.md "Private workflow context" owns setup and index schema.
# FM_HOME, FM_DATA_OVERRIDE and FM_CONFIG_OVERRIDE select the same private roots
# as session-start. Nothing is inherited elsewhere.
# A condition is displayed, never executed or assumed satisfied. A reached until
# withholds active content and reports a required owner boundary check. Stopped
# content remains visible even after its date: expiry never lifts a stop.
# Superseded/expired records are references only, never active instructions.
# Startup renders global content and a scoped navigation index. Project renders
# global, matching project, then matching task content; other bodies are not read.
# These are scoped instructions, not an authority grant or automatic work resume.
# Invalid configuration/index or unreadable selected content fails with no partial
# context. --now allows deterministic read-only replay; default is current UTC.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  --help|-h) sed -n '2,/^set -eu/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
esac
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
if [ ! -e "$CONFIG/workflow-context" ] && [ ! -L "$CONFIG/workflow-context" ]; then
  exit 0
fi
if [ -L "$CONFIG" ] || [ -L "$CONFIG/workflow-context" ]; then
  printf '%s\n' 'WORKFLOW_CONTEXT: symlinked workflow configuration' >&2
  exit 1
fi
if [ ! -f "$CONFIG/workflow-context" ] || ! workflow_context_setting=$(< "$CONFIG/workflow-context"); then
  printf 'WORKFLOW_CONTEXT: missing regular workflow input: %s\n' "$CONFIG/workflow-context" >&2
  exit 1
fi
case "$workflow_context_setting" in
  off) exit 0 ;;
  on)
    if ! command -v python3 >/dev/null 2>&1; then
      printf '%s\n' 'WORKFLOW_CONTEXT: python3 is required when config/workflow-context is on' >&2
      exit 1
    fi
    ;;
  *)
    printf '%s\n' 'WORKFLOW_CONTEXT: config/workflow-context must be on or off' >&2
    exit 1
    ;;
esac
exec python3 - "$SCRIPT_DIR" "$FM_HOME" "${FM_DATA_OVERRIDE:-$FM_HOME/data}" "$CONFIG" "$@" <<'PY'
import datetime as dt
import pathlib
import re
import shlex
import sys


def fail(message):
    raise ValueError(message)


def timestamp(value):
    return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def read_plain(root, relative):
    path = root
    for part in pathlib.PurePosixPath(relative).parts:
        path = path / part
        if path.is_symlink():
            fail("symlinked workflow input: " + str(path))
    if not path.is_file():
        fail("missing regular workflow input: " + str(path))
    return path.read_text(encoding="utf-8")


def main():
    _, script_dir, home, data, config, *args = sys.argv
    root = pathlib.Path(data) / "workflow"
    config_root = pathlib.Path(config)
    setting = config_root / "workflow-context"
    if setting.is_symlink() or config_root.is_symlink():
        fail("symlinked workflow configuration")
    if not setting.exists():
        return
    enabled = read_plain(config_root, "workflow-context").strip()
    if enabled == "off":
        return
    if enabled != "on":
        fail("config/workflow-context must be on or off")
    if not args or args[0] not in ("startup", "project"):
        fail("expected startup or project <name>")
    mode = args.pop(0)
    project = args.pop(0) if mode == "project" and args else ""
    task = ""
    now = dt.datetime.now(dt.timezone.utc)
    while args:
        flag = args.pop(0)
        if not args:
            fail("missing value for " + flag)
        value = args.pop(0)
        if flag == "--now":
            now = timestamp(value)
        elif flag == "--task" and mode == "project" and not task:
            task = value
        else:
            fail("unknown or repeated option: " + flag)
    name = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
    if mode == "project" and not name.fullmatch(project):
        fail("invalid project name")
    if task and not name.fullmatch(task):
        fail("invalid task id")
    refresh = [str(pathlib.Path(script_dir) / "fm-workflow-context.sh"), mode]
    if mode == "project":
        refresh.append(project)
        if task:
            refresh += ["--task", task]
    if root.is_symlink() or pathlib.Path(data).is_symlink():
        fail("symlinked workflow data directory")
    rows = []
    seen = set()
    header = False
    for line in read_plain(root, "index.md").splitlines():
        if not line.strip().startswith("|"):
            continue
        fields = [field.strip() for field in line.strip().strip("|").split("|")]
        if fields == ["Scope", "Status", "Path", "Source", "End-check"]:
            if header:
                fail("duplicate workflow table")
            header = True
            continue
        if header and len(fields) == 5 and all(re.fullmatch(r":?-+:?", f) for f in fields):
            continue
        if not header or len(fields) != 5 or not all(fields):
            fail("invalid workflow table row")
        scope, status, path, source, end = fields
        if scope != "global" and not re.fullmatch(r"(?:project|task):[A-Za-z0-9][A-Za-z0-9._-]*", scope):
            fail("invalid scope: " + scope)
        if status not in ("active", "stopped", "superseded", "expired"):
            fail("invalid status: " + status)
        parts = pathlib.PurePosixPath(path).parts
        if not parts or path.startswith("/") or ".." in parts or "\\" in path or not path.endswith(".md"):
            fail("invalid workflow path: " + path)
        if (scope, path) in seen:
            fail("duplicate workflow scope/path: " + path)
        seen.add((scope, path))
        due = False
        if end.startswith("until:"):
            due = now >= timestamp(end[6:])
        elif end != "none" and not (end.startswith("condition:") and end[10:].strip()):
            fail("invalid end-check: " + end)
        rows.append((scope, status, path, source, end, due))
    if not header or not rows:
        fail("workflow index has no records")
    out = ["## Scoped workflow context", "Read at " + now.strftime("%Y-%m-%dT%H:%M:%SZ"),
           "Source: " + str(root / "index.md"),
           "Refresh: " + " ".join(["FM_HOME=" + shlex.quote(home), "FM_DATA_OVERRIDE=" + shlex.quote(data),
                                    "FM_CONFIG_OVERRIDE=" + shlex.quote(config)] + [shlex.quote(v) for v in refresh]),
           "Selection does not grant authority or resume work. A stop requires its owner's explicit resolution.",
           "Re-read applicable context before dependent work when scope, instructions or an end-check changes."]
    selected = ["global"]
    if mode == "project":
        selected.append("project:" + project)
        if task:
            selected.append("task:" + task)
    for scope in selected:
        for record_scope, status, path, source, end, due in rows:
            if record_scope != scope:
                continue
            out += ["", "### " + scope + " / " + path,
                    "Status: " + status + "; Source: " + source + "; End-check: " + end]
            if status in ("superseded", "expired") or (due and status == "active"):
                out.append("INACTIVE: content withheld. Resolve the end boundary with its owner; this never lifts a stop or resumes work.")
                continue
            if status == "stopped":
                out.append("STOP REMAINS: a date or condition does not clear this instruction.")
            if end.startswith("condition:"):
                out.append("OWNER CHECK REQUIRED: evaluate the named condition before relying on this record; no automatic condition check occurred.")
            out += ["BEGIN " + str(root / path), read_plain(root, path).rstrip(), "END " + str(root / path)]
    if mode == "startup":
        out += ["", "### Context available on project/task selection",
                "Retrieve with bin/fm-workflow-context.sh project <project-name> [--task <task-id>]."]
        for scope, status, path, source, end, due in rows:
            if scope != "global":
                label = "end-check due" if due else status
                out.append(scope + " | " + label + " | " + path + " | " + source + " | " + end)
    print("\n".join(out))


try:
    main()
except (ValueError, OSError, UnicodeError) as exc:
    print("WORKFLOW_CONTEXT: " + str(exc), file=sys.stderr)
    sys.exit(1)
PY
