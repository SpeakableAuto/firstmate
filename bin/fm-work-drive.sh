#!/usr/bin/env bash
# Point build output and caches at a dedicated work drive, with no internal fallback.
# Usage: FM_HOME=/absolute/firstmate fm-work-drive.sh check|install [--dry-run]
#        FM_HOME=/absolute/firstmate fm-work-drive.sh verify [--project <path>]
#        FM_HOME=/absolute/firstmate fm-work-drive.sh exec -- <command> [args...]
#        FM_HOME=/absolute/firstmate fm-work-drive.sh simctl <simctl args...>
# Config: $FM_HOME/config/work-drive, plain lines (never sourced):
#   root=/Volumes/Kitchen                 required absolute drive mount
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
# config/crew-placement.json must exist, its drive must equal root, and its
# required_drive_dirs must cover every target, so placement refuses heavy work on
# the same paths. verify and install fail closed until that profile is active.
# install and verify require a non-writable mount parent (for the current user).
# This prevents tools from recreating an absent mount path on the internal disk,
# including tools already running and light work outside placement admission.
# Provision mount parents through the host administrator, never this command.
# verify also requires a valid internal-growth config, successful read-only
# measurement, and the daily internal-growth LaunchAgent to be loaded.
# install creates a missing internal-growth config with scan=$HOME, the Data
# volume on macOS (otherwise /), and explicit allowances for Firstmate's
# operational folders, user apps/application support and internal Codex sessions.
# Existing invalid config is never replaced. The initial measurement/baseline
# must succeed before enrollment. Additional always-on services need explicit
# allow= entries reviewed by the operator; project folders are not allowed.
# install first proves the drive root, creates missing target directories on that
# mounted drive, rewrites only the marked block in the shell env file, sets the
# user npm cache and Xcode DerivedData default, enrolls the daily internal-growth
# LaunchAgent, then verifies. --dry-run prints those actions without changing
# anything.
# exec creates a private job directory under build-tmp, runs the command with
# TMPDIR pointing there plus every env entry, removes the job directory, and
# returns the command's status. It is opt-in for build jobs: a global TMPDIR on
# the drive would lengthen Unix socket paths that some tests require to be short.
# simctl runs `xcrun simctl --set <simulator-set>`; Xcode offers no supported
# default device-set override, so only simctl calls made through this command use
# the drive. xcodebuild and Simulator.app keep the default device set.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
GROWTH_LABEL=local.firstmate.internal-growth

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
run_drive_check() {
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
}
run_check() {
  local failed=0 target label path
  run_drive_check || return $?
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

check_placement() {
  local failed=0 placement target
  placement="$CONFIG/crew-placement.json"
  if [ ! -f "$placement" ] || [ -L "$placement" ]; then
    echo "refused placement: $placement is missing, not a file, or symlinked" >&2
    return 3
  fi
  if ! command -v jq >/dev/null; then
    echo 'refused placement: jq is unavailable' >&2
    return 3
  fi
  if ! jq -e '
    type == "object" and
    (.drive | type == "string") and
    (.required_drive_dirs | type == "array") and
    all(.required_drive_dirs[]; type == "string")
  ' "$placement" >/dev/null 2>&1; then
    echo 'refused placement: crew-placement.json must contain a string drive and an array of directory strings' >&2
    return 3
  fi
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
  [ "$failed" -eq 0 ] || return 3
}

check_project_treehouse() {
  local project=$1 file treehouse_root
  file="$project/treehouse.toml"
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    echo "refused treehouse: $file is missing, not a regular file, or symlinked" >&2
    return 3
  fi
  if ! treehouse_root=$(python3 - "$file" <<'PY'
import re
import sys

roots = []
in_table = False
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        line = raw.rstrip("\r\n")
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("["):
            in_table = True
            continue
        if in_table or not re.match(r"root\s*=", stripped):
            continue
        match = re.fullmatch(r'root\s*=\s*"([^"\\]*)"\s*(?:#.*)?', stripped)
        if not match:
            sys.exit(1)
        roots.append(match.group(1))
if len(roots) != 1:
    sys.exit(1)
print(roots[0])
PY
  ); then
    echo "refused treehouse: $file must contain one literal top-level root" >&2
    return 3
  fi
  if ! real_dir "$treehouse_root"; then
    echo "refused treehouse: $treehouse_root is missing or not a real directory" >&2
    return 3
  fi
  case "$treehouse_root" in
    "$root"|"$root"/*) ;;
    *)
      echo "refused treehouse: $treehouse_root is outside $root" >&2
      return 3 ;;
  esac
  echo "ok treehouse root $treehouse_root"
}

check_mount_parent() {
  local parent
  parent=$(dirname "$root")
  if ! real_dir "$parent" || [ -w "$parent" ]; then
    echo "refused mount parent: $parent must be a real directory not writable by $(id -un); otherwise tools can recreate an absent drive internally" >&2
    return 3
  fi
  echo "ok protected mount parent $parent"
}

prepare_growth_config() {
  local dry=$1 path volume part tmp
  path="$CONFIG/internal-growth"
  # Existing malformed files and symlinks are left to the checker's parser.
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 0
  volume=/
  [ ! -d /System/Volumes/Data ] || volume=/System/Volumes/Data
  if [ "$dry" = 1 ]; then
    echo "would create $path: volume=$volume, scan=$HOME, threshold_gib=1 with explicit operational allowances"
    return 0
  fi
  tmp=$(mktemp "$CONFIG/.internal-growth.XXXXXXXX") || return 3
  {
    printf 'volume=%s\nscan=%s\nthreshold_gib=1\ndepth=3\n' "$volume" "$HOME"
    for part in bin config data state docs .agents skills; do
      printf 'allow=%s/%s\n' "$FM_HOME" "$part"
    done
    printf 'allow=%s/Applications\nallow=%s/Library/Application Support\nallow=%s/.codex/sessions\n' "$HOME" "$HOME" "$HOME"
  } > "$tmp"
  # Create only when still absent; never replace another install's configuration.
  if ! ln "$tmp" "$path"; then
    rm -f "$tmp"
    echo 'refused internal growth configuration: concurrent creation' >&2
    return 3
  fi
  rm -f "$tmp"
  echo "created internal growth configuration $path"
}

check_growth_measurement() {
  if ! bash "$SCRIPT_DIR/fm-internal-growth.sh" --dry-run; then
    echo 'refused internal growth measurement: configure a valid internal-growth file and resolve its measurement error before enrollment' >&2
    return 3
  fi
  echo 'ok internal growth measurement'
}

check_growth_enrollment() {
  local service
  service="gui/$(id -u)/$GROWTH_LABEL"
  if command -v launchctl >/dev/null && launchctl print "$service" >/dev/null 2>&1; then
    echo "ok internal growth LaunchAgent $service"
    return 0
  fi
  echo "refused internal growth LaunchAgent: $service is not loaded" >&2
  return 3
}

run_verify() {
  local project=${1:-} failed=0 out sh script name expected actual i allow
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
  check_placement || failed=1
  check_mount_parent || failed=1
  check_growth_measurement || failed=1
  [ -z "$project" ] || check_project_treehouse "$project" || failed=1
  check_growth_enrollment || failed=1
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
  local file=$1 dir tmp
  if [ -L "$file" ]; then
    echo "refused shell env: $file is a symlink; edit its target by hand" >&2
    return 3
  fi
  dir=$(dirname "$file")
  if [ -e "$file" ]; then
    if ! awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
      $0 == b { if (state != 0) invalid = 1; state = 1; next }
      $0 == e { if (state != 1) invalid = 1; state = 2; next }
      END { exit(invalid || state == 1) }
    ' "$file"; then
      echo "refused shell env: $file has an unbalanced or repeated work-drive block" >&2
      return 3
    fi
  fi
  tmp=$(mktemp "$dir/.fm-work-drive-env.XXXXXXXX") || return 1
  # Copying first carries the file's mode; the rewrite below keeps it.
  if [ -e "$file" ]; then
    cp -p -- "$file" "$tmp" || { rm -f -- "$tmp"; return 1; }
  else
    chmod 0644 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  {
    if [ -e "$file" ]; then
      awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }' "$file"
    fi
    render_block
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"
}
ensure_target_dir() {
  local rel=$1 path=$root part
  local -a parts
  IFS=/ read -r -a parts <<< "$rel"
  for part in "${parts[@]}"; do
    path="$path/$part"
    if [ -e "$path" ] || [ -L "$path" ]; then
      if ! real_dir "$path"; then
        echo "refused target directory: $path is not a real directory" >&2
        return 3
      fi
    else
      mkdir -- "$path" || { echo "refused target directory: could not create $path" >&2; return 3; }
    fi
  done
}
prepare_targets() {
  local dry=$1 target rel path part missing
  local -a parts
  for target in "${targets[@]+"${targets[@]}"}"; do
    rel=${target#*$'\t'}
    if [ "$dry" = 0 ]; then
      ensure_target_dir "$rel" || return $?
      continue
    fi
    path=$root
    missing=0
    IFS=/ read -r -a parts <<< "$rel"
    for part in "${parts[@]}"; do
      path="$path/$part"
      if [ "$missing" = 0 ] && { [ -e "$path" ] || [ -L "$path" ]; }; then
        if ! real_dir "$path"; then
          echo "refused target directory: $path is not a real directory" >&2
          return 3
        fi
      else
        missing=1
      fi
    done
    [ "$missing" = 0 ] || echo "would create directory $root/$rel"
  done
}
render_growth_plist() {
  python3 - "$FM_HOME" "$HOME" "$SCRIPT_DIR" "$GROWTH_LABEL" <<'PY'
import os
import plistlib
import sys

fm_home, home, script_dir, label = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": ["/bin/bash", os.path.join(script_dir, "fm-internal-growth.sh")],
    "EnvironmentVariables": {
        "FM_HOME": fm_home,
        "HOME": home,
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    },
    "StartCalendarInterval": {"Hour": 3, "Minute": 30},
    "LowPriorityIO": True,
    "Nice": 10,
    "StandardOutPath": os.path.join(home, "Library", "Logs", "firstmate-internal-growth.log"),
    "StandardErrorPath": os.path.join(home, "Library", "Logs", "firstmate-internal-growth.log"),
}
sys.stdout.buffer.write(plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=False))
PY
}
enroll_growth_check() {
  local dry=$1 launch_dir log_dir plist tmp domain
  launch_dir="$HOME/Library/LaunchAgents"
  log_dir="$HOME/Library/Logs"
  plist="$launch_dir/$GROWTH_LABEL.plist"
  domain="gui/$(id -u)"
  if [ "$dry" = 1 ]; then
    echo "would write $plist:"
    render_growth_plist
    echo "would run: launchctl bootout $domain/$GROWTH_LABEL"
    echo "would run: launchctl bootstrap $domain $(shell_quote "$plist")"
    return 0
  fi
  if ! mkdir -p -- "$launch_dir" "$log_dir"; then
    echo 'refused internal growth enrollment: could not create launchd directories' >&2
    return 3
  fi
  if ! tmp=$(mktemp "$launch_dir/.fm-internal-growth.XXXXXXXX"); then
    echo 'refused internal growth enrollment: could not create the temporary plist' >&2
    return 3
  fi
  if ! render_growth_plist > "$tmp"; then
    rm -f -- "$tmp"
    echo 'refused internal growth enrollment: could not render the plist' >&2
    return 3
  fi
  if ! chmod 0644 "$tmp"; then
    rm -f -- "$tmp"
    echo 'refused internal growth enrollment: could not set the plist mode' >&2
    return 3
  fi
  if ! mv -f -- "$tmp" "$plist"; then
    rm -f -- "$tmp"
    echo 'refused internal growth enrollment: could not install the plist' >&2
    return 3
  fi
  launchctl bootout "$domain/$GROWTH_LABEL" >/dev/null 2>&1 || true
  if ! launchctl bootstrap "$domain" "$plist"; then
    echo 'refused internal growth enrollment: launchctl bootstrap failed' >&2
    return 3
  fi
  echo "enrolled $GROWTH_LABEL"
}
run_install() {
  local dry=$1
  run_drive_check >/dev/null || return $?
  check_placement >/dev/null || return $?
  check_mount_parent >/dev/null || return $?
  command -v python3 >/dev/null || { echo 'refused internal growth enrollment: python3 is unavailable' >&2; return 3; }
  command -v launchctl >/dev/null || { echo 'refused internal growth enrollment: launchctl is unavailable' >&2; return 3; }
  prepare_growth_config "$dry" || return $?
  if [ "$dry" = 0 ] || [ -e "$CONFIG/internal-growth" ] || [ -L "$CONFIG/internal-growth" ]; then
    check_growth_measurement || return $?
  fi
  prepare_targets "$dry" || return $?
  if [ "$dry" = 1 ]; then
    echo "would write to $shell_env_file:"
    render_block
    [ -z "$npm_rel" ] || echo "would run: npm config set cache $(shell_quote "$root/$npm_rel") --location=user"
    [ -z "$xcode_rel" ] || echo "would run: defaults write com.apple.dt.Xcode IDECustomDerivedDataLocation -string $(shell_quote "$root/$xcode_rel")"
    enroll_growth_check 1
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
  if ! bash "$SCRIPT_DIR/fm-internal-growth.sh"; then
    echo 'refused internal growth baseline: initial check failed; daily service not enrolled' >&2
    return 3
  fi
  enroll_growth_check 0 || return $?
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
  verify)
    project=
    case "${1:-}" in --project) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; project=$2; shift 2 ;; esac
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    run_verify "$project" ;;
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
