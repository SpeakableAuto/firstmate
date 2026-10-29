#!/usr/bin/env bash
# Point build output and caches at a dedicated work drive, with no internal fallback.
# Usage: FM_HOME=/absolute/firstmate fm-work-drive.sh check|verify|install [--dry-run]
#        FM_HOME=/absolute/firstmate fm-work-drive.sh exec -- <command> [args...]
#        FM_HOME=/absolute/firstmate fm-work-drive.sh simctl <simctl args...>
# Config: $FM_HOME/config/work-drive, plain lines (never sourced):
#   root=/Volumes/Work                    required absolute drive mount
#   env=PLAYWRIGHT_BROWSERS_PATH=Caches/Playwright   repeatable NAME=relative
#   npm-cache=Caches/npm                  user npm config `cache`
#   xcode-derived-data=Build/DerivedData  Xcode IDECustomDerivedDataLocation
#   simulator-set=SimulatorDevices        device set used by the simctl command
#   build-tmp=Build/Tmp                   parent of per-job TMPDIRs for exec
#   shell-env-file=/absolute/.zshenv      managed export block (default $HOME/.zshenv)
# Relative targets live beneath root; empty, absolute or `..` targets are refused.
# check proves root is a real mount point (no symlinked component), and that root
# and every configured target are existing real directories where a temporary
# create/unlink succeeds. It never creates a directory and never falls back to
# internal storage. Exit 0 means usable, 3 means refused (named on stderr), 2
# means invalid configuration or usage.
# verify runs check, then reads each setting from a fresh login shell started
# with an empty environment ($SHELL -l), from `npm config get cache`, and from
# `defaults read com.apple.dt.Xcode`, so it proves what a newly launched worker
# inherits rather than this process's environment. When config/launch-env-allowlist
# exists, every env name must be listed there or worker launches would drop it.
# When config/crew-placement.json exists, its drive must equal root and its
# required_drive_dirs must cover every target, so placement refuses heavy work on
# the same paths; an absent profile is reported as pending, not as a pass.
# install (after a passing check) rewrites only the marked block in the shell env
# file, sets the user npm cache and the Xcode DerivedData default, then verifies.
# --dry-run prints those actions without changing anything.
# exec creates a private job directory under build-tmp, runs the command with
# TMPDIR pointing there plus every env entry, removes the job directory, and
# returns the command's status. It is opt-in for build jobs: a global TMPDIR on
# the drive would lengthen Unix socket paths that some tests require to be short.
# simctl runs `xcrun simctl --set <simulator-set>`; Xcode offers no supported
# default device-set override, so only simctl calls made through this command use
# the drive. xcodebuild and Simulator.app keep the default device set.
set -euo pipefail
usage() { sed -n '2,/^set /{ /^#/{ s/^# \{0,1\}//; p; }; }' "$0"; }
case "${1:-}" in
  --help|-h|'') usage; [ -n "${1:-}" ] || exit 2; exit 0 ;;
esac
: "${FM_HOME:?set FM_HOME to the Firstmate home}"
case "$FM_HOME" in /*) ;; *) echo 'FM_HOME must be absolute' >&2; exit 2 ;; esac
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
config="$CONFIG/work-drive"
BLOCK_BEGIN='# >>> firstmate work drive >>>'
BLOCK_END='# <<< firstmate work drive <<<'

root=
env_names=()
env_rels=()
npm_rel=
xcode_rel=
sim_rel=
tmp_rel=
shell_env_file="$HOME/.zshenv"

config_error() { echo "invalid work-drive configuration: $*" >&2; exit 2; }
valid_rel() {
  case "/$1/" in
    //|*//*|*/../*|*/./*) return 1 ;;
  esac
  case "$1" in /*|*$'\n'*|*\'*) return 1 ;; esac
}
[ -f "$config" ] && [ ! -L "$config" ] || { echo "work drive not configured: $config" >&2; exit 2; }
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) continue ;;
    root=*) root=${line#root=} ;;
    env=*)
      pair=${line#env=}
      name=${pair%%=*}
      [ "$name" != "$pair" ] || config_error "$line"
      [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || config_error "$line"
      env_names+=("$name"); env_rels+=("${pair#*=}") ;;
    npm-cache=*) npm_rel=${line#*=} ;;
    xcode-derived-data=*) xcode_rel=${line#*=} ;;
    simulator-set=*) sim_rel=${line#*=} ;;
    build-tmp=*) tmp_rel=${line#*=} ;;
    shell-env-file=*) shell_env_file=${line#*=} ;;
    *) config_error "$line" ;;
  esac
done < "$config"
case "$root" in /?*) ;; *) config_error 'root must be an absolute path' ;; esac
root=${root%/}
valid_rel "${root#/}" || config_error 'root must be a plain absolute path'
case "$shell_env_file" in /?*) ;; *) config_error 'shell-env-file must be an absolute path' ;; esac
# Every target, in a fixed order: label<TAB>relative path.
targets=()
for i in "${!env_names[@]}"; do targets+=("env ${env_names[$i]}"$'\t'"${env_rels[$i]}"); done
[ -z "$npm_rel" ] || targets+=("npm-cache"$'\t'"$npm_rel")
[ -z "$xcode_rel" ] || targets+=("xcode-derived-data"$'\t'"$xcode_rel")
[ -z "$sim_rel" ] || targets+=("simulator-set"$'\t'"$sim_rel")
[ -z "$tmp_rel" ] || targets+=("build-tmp"$'\t'"$tmp_rel")
for target in "${targets[@]+"${targets[@]}"}"; do
  valid_rel "${target#*$'\t'}" || config_error "target for ${target%%$'\t'*} must be a plain relative path"
done

is_mount() {
  # FM_TEST_SEAM lets portable tests stand in a temporary directory for a mount.
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_WORK_DRIVE_TEST_MOUNT:-}" ] &&
    [ "$1" = "$FM_WORK_DRIVE_TEST_MOUNT" ]; then
    return 0
  fi
  python3 -c 'import os, sys; sys.exit(0 if os.path.ismount(sys.argv[1]) else 1)' "$1"
}
real_dir() {
  local resolved
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  resolved=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  [ "$resolved" = "$1" ]
}
write_probe() {
  local probe
  probe=$(mktemp "$1/.fm-work-drive.XXXXXXXX" 2>/dev/null) || return 1
  rm -f -- "$probe"
}
run_check() {
  local failed=0 target label path
  if ! real_dir "$root"; then
    echo "refused drive: $root is missing, not a directory, or reached through a symlink" >&2
    return 3
  fi
  if ! is_mount "$root"; then
    echo "refused drive: $root is not a mounted volume" >&2
    return 3
  fi
  if ! write_probe "$root"; then
    echo "refused drive: $root is not writable" >&2
    return 3
  fi
  echo "ok drive $root"
  for target in "${targets[@]+"${targets[@]}"}"; do
    label=${target%%$'\t'*}
    path="$root/${target#*$'\t'}"
    if ! real_dir "$path"; then
      echo "refused $label: $path is missing or not a real directory" >&2
      failed=1
    elif ! write_probe "$path"; then
      echo "refused $label: $path is not writable" >&2
      failed=1
    else
      echo "ok $label $path"
    fi
  done
  [ "$failed" -eq 0 ] || return 3
}
shell_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

run_verify() {
  local failed=0 out sh script name expected actual i allow placement target
  run_check || return $?
  sh=${SHELL:-/bin/sh}
  script=
  for name in "${env_names[@]+"${env_names[@]}"}"; do
    script+="printf '%s=%s\\n' $name \"\${$name-<unset>}\"; "
  done
  if [ -n "$npm_rel" ]; then
    script+="printf 'npm-cache=%s\\n' \"\$(npm config get cache 2>/dev/null || echo '<npm unavailable>')\"; "
  fi
  # A fresh login shell from an empty environment: what a new worker pane sees.
  if ! out=$(env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-${USER:-}}" SHELL="$sh" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin TERM=dumb "$sh" -l -c "$script" </dev/null 2>/dev/null); then
    echo "refused fresh-shell: $sh -l could not run" >&2
    return 3
  fi
  for i in "${!env_names[@]}"; do
    name=${env_names[$i]}
    expected="$root/${env_rels[$i]}"
    actual=$(printf '%s\n' "$out" | sed -n "s/^$name=//p" | tail -n1)
    if [ "$actual" = "$expected" ]; then
      echo "ok fresh-shell $name=$actual"
    else
      echo "refused fresh-shell $name: expected $expected, got ${actual:-<missing>}" >&2
      failed=1
    fi
  done
  if [ -n "$npm_rel" ]; then
    actual=$(printf '%s\n' "$out" | sed -n 's/^npm-cache=//p' | tail -n1)
    if [ "$actual" = "$root/$npm_rel" ]; then
      echo "ok npm cache $actual"
    else
      echo "refused npm cache: expected $root/$npm_rel, got ${actual:-<missing>}" >&2
      failed=1
    fi
  fi
  if [ -n "$xcode_rel" ]; then
    actual=$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null || true)
    if [ "$actual" = "$root/$xcode_rel" ]; then
      echo "ok xcode derived data $actual"
    else
      echo "refused xcode derived data: expected $root/$xcode_rel, got ${actual:-<unset>}" >&2
      failed=1
    fi
  fi
  allow="$CONFIG/launch-env-allowlist"
  if [ -e "$allow" ] || [ -L "$allow" ]; then
    for name in "${env_names[@]+"${env_names[@]}"}"; do
      if grep -qx -- "$name" "$allow" 2>/dev/null; then
        echo "ok launch allowlist keeps $name"
      else
        echo "refused launch allowlist: $name is not listed, so worker launches drop it" >&2
        failed=1
      fi
    done
  fi
  placement="$CONFIG/crew-placement.json"
  if [ -e "$placement" ] || [ -L "$placement" ]; then
    if [ "$(jq -r '.drive // ""' "$placement" 2>/dev/null)" != "$root" ]; then
      echo "refused placement: crew-placement.json drive is not $root" >&2
      failed=1
    else
      for target in "${targets[@]+"${targets[@]}"}"; do
        if jq -e --arg rel "${target#*$'\t'}" '(.required_drive_dirs // []) | index($rel) != null' \
          "$placement" >/dev/null 2>&1; then
          echo "ok placement requires ${target#*$'\t'}"
        else
          echo "refused placement: required_drive_dirs lacks ${target#*$'\t'}" >&2
          failed=1
        fi
      done
    fi
  else
    echo "pending placement: no crew-placement.json, so heavy work is not refused when the drive fails"
  fi
  [ "$failed" -eq 0 ] || return 3
}

render_block() {
  local i
  printf '%s\n' "$BLOCK_BEGIN"
  for i in "${!env_names[@]}"; do
    printf 'export %s=%s\n' "${env_names[$i]}" "$(shell_quote "$root/${env_rels[$i]}")"
  done
  printf '%s\n' "$BLOCK_END"
}
write_shell_env() {
  local file=$1 dir tmp begins ends
  if [ -L "$file" ]; then
    echo "refused shell env: $file is a symlink; edit its target by hand" >&2
    return 3
  fi
  dir=$(dirname "$file")
  if [ -e "$file" ]; then
    begins=$(grep -cxF -- "$BLOCK_BEGIN" "$file" || true)
    ends=$(grep -cxF -- "$BLOCK_END" "$file" || true)
    if [ "$begins" != "$ends" ] || [ "${begins:-0}" -gt 1 ]; then
      echo "refused shell env: $file has an unbalanced or repeated work-drive block" >&2
      return 3
    fi
  fi
  tmp=$(mktemp "$dir/.fm-work-drive-env.XXXXXXXX") || return 1
  {
    if [ -e "$file" ]; then
      awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }' "$file"
    fi
    render_block
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ -e "$file" ]; then
    chmod "$(stat -f %Lp "$file" 2>/dev/null || stat -c %a "$file")" "$tmp" || { rm -f -- "$tmp"; return 1; }
  else
    chmod 0644 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  mv -f -- "$tmp" "$file"
}
run_install() {
  local dry=$1
  run_check >/dev/null || return $?
  if [ "$dry" = 1 ]; then
    echo "would write to $shell_env_file:"
    render_block
    [ -z "$npm_rel" ] || echo "would run: npm config set cache $(shell_quote "$root/$npm_rel") --location=user"
    [ -z "$xcode_rel" ] || echo "would run: defaults write com.apple.dt.Xcode IDECustomDerivedDataLocation -string $(shell_quote "$root/$xcode_rel")"
    return 0
  fi
  write_shell_env "$shell_env_file" || return $?
  echo "wrote work-drive block to $shell_env_file"
  if [ -n "$npm_rel" ]; then
    command -v npm >/dev/null || { echo 'refused npm cache: npm is not on PATH' >&2; return 3; }
    npm config set cache "$root/$npm_rel" --location=user
  fi
  if [ -n "$xcode_rel" ]; then
    command -v defaults >/dev/null || { echo 'refused xcode derived data: defaults is unavailable' >&2; return 3; }
    defaults write com.apple.dt.Xcode IDECustomDerivedDataLocation -string "$root/$xcode_rel"
  fi
  run_verify
}
run_exec() {
  local status i
  [ -n "$tmp_rel" ] || config_error 'exec needs build-tmp'
  run_check >/dev/null || return $?
  # Global so the EXIT trap still sees it after this function returns.
  exec_job=$(mktemp -d "$root/$tmp_rel/job.XXXXXXXX") || { echo "refused build-tmp: cannot create a job directory" >&2; return 3; }
  trap 'rm -rf -- "$exec_job"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for i in "${!env_names[@]}"; do export "${env_names[$i]}=$root/${env_rels[$i]}"; done
  [ -z "$npm_rel" ] || export npm_config_cache="$root/$npm_rel"
  status=0
  TMPDIR=$exec_job "$@" || status=$?
  return "$status"
}

cmd=$1; shift
case "$cmd" in
  check) [ "$#" -eq 0 ] || { usage >&2; exit 2; }; run_check ;;
  verify) [ "$#" -eq 0 ] || { usage >&2; exit 2; }; run_verify ;;
  install)
    dry=0
    case "${1:-}" in --dry-run) dry=1; shift ;; esac
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    run_install "$dry" ;;
  exec)
    [ "${1:-}" = -- ] && shift
    [ "$#" -gt 0 ] || { usage >&2; exit 2; }
    run_exec "$@" ;;
  simctl)
    [ -n "$sim_rel" ] || config_error 'simctl needs simulator-set'
    run_check >/dev/null || exit $?
    exec xcrun simctl --set "$root/$sim_rel" "$@" ;;
  *) usage >&2; exit 2 ;;
esac
