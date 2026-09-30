#!/bin/bash
set -u

root=$1
output_file=$2
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-bash32-backlog.XXXXXX") || exit 1
trap 'rm -rf "$probe_dir"' EXIT
backlog="$probe_dir/backlog.md"

for tool in tasks-axi node perl bash sleep; do
  tool_path=$(command -v "$tool") || exit 1
  ln -s "$tool_path" "$probe_dir/$tool" || exit 1
done

run_bounded_tasks_axi() (
  set -u
  unset BASHPID 2>/dev/null || true
  . "$root/bin/fm-backlog-transition-lib.sh"
  PATH=$probe_dir FM_TASKS_AXI_TIMEOUT=5 fm_tasks_axi "$@"
)

{
  printf 'runtime: %s\n' "$(/bin/bash --version | /usr/bin/head -n 1)"
  printf 'restricted PATH entries: tasks-axi node perl bash sleep (no sh)\n'
  run_bounded_tasks_axi add bash32-live-proof 'Bash 3.2 bounded backlog proof' --file "$backlog"
  run_bounded_tasks_axi start bash32-live-proof --file "$backlog"
  run_bounded_tasks_axi show bash32-live-proof --full --file "$backlog"
} 2>&1 | tee "$output_file"
test ${PIPESTATUS[0]} -eq 0
