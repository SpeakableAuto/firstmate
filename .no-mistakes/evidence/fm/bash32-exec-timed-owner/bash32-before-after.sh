#!/bin/bash
set -u

base_commit=$1
changed_root=$2
output_file=$3
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-bash32-proof.XXXXXX") || exit 1
trap 'rm -rf "$probe_dir"' EXIT

for tool in perl bash sleep; do
  tool_path=$(command -v "$tool") || exit 1
  ln -s "$tool_path" "$probe_dir/$tool" || exit 1
done
git show "$base_commit:bin/fm-timeout-lib.sh" > "$probe_dir/base-lib.sh" || exit 1

{
  printf 'runtime: %s\n' "$(/bin/bash --version | /usr/bin/head -n 1)"
  printf 'restricted PATH entries: perl bash sleep (no sh)\n'

  base_output=$(
    /bin/bash -c '
      set -u
      unset BASHPID 2>/dev/null || true
      . "$1"
      PATH=$2 fm_exec_timed 5 1 bash -c '\''printf "bounded\n"; exit 7'\''
    ' _ "$probe_dir/base-lib.sh" "$probe_dir" 2>&1
  )
  base_rc=$?
  printf 'base %s rc=%s output=%s\n' "$base_commit" "$base_rc" "$base_output"

  changed_output=$(
    /bin/bash -c '
      set -u
      unset BASHPID 2>/dev/null || true
      . "$1/bin/fm-timeout-lib.sh"
      PATH=$2 fm_exec_timed 5 1 bash -c '\''printf "bounded\n"; exit 7'\''
    ' _ "$changed_root" "$probe_dir" 2>&1
  )
  changed_rc=$?
  printf 'changed rc=%s output=%s\n' "$changed_rc" "$changed_output"

  [ "$base_rc" -ne 7 ] || exit 1
  case "$base_output" in
    *'BASHPID: unbound variable'*) ;;
    *) exit 1 ;;
  esac
  [ "$changed_rc" -eq 7 ] || exit 1
  [ "$changed_output" = bounded ] || exit 1
} 2>&1 | tee "$output_file"
test ${PIPESTATUS[0]} -eq 0
