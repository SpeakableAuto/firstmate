#!/usr/bin/env bash
# Behavior tests for bin/fm-work-drive.sh using disposable drives and fake tools.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-work-drive)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/npm" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'config get') cat "$HOME/npm-cache" 2>/dev/null || echo "$HOME/.npm" ;;
  'config set') printf '%s\n' "$4" > "$HOME/npm-cache"; printf '%s\n' "$*" >> "$HOME/npm-calls" ;;
  *) exit 1 ;;
esac
SH
cat > "$FAKEBIN/defaults" <<'SH'
#!/usr/bin/env bash
case "$1" in
  read) cat "$HOME/xcode-dd" 2>/dev/null || exit 1 ;;
  write) printf '%s\n' "$5" > "$HOME/xcode-dd" ;;
  *) exit 1 ;;
esac
SH
cat > "$FAKEBIN/xcrun" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HOME/xcrun-args"
SH
cat > "$FAKEBIN/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/launchctl-calls"
case "${1:-}" in
  bootout) rm -f "$HOME/launchctl-loaded" ;;
  bootstrap)
    [ ! -e "$HOME/launchctl-fail-bootstrap" ] || exit 17
    touch "$HOME/launchctl-loaded" ;;
  print) [ -e "$HOME/launchctl-loaded" ] || exit 113 ;;
esac
SH
chmod +x "$FAKEBIN"/*

TARGETS="Build/DerivedData Build/Tmp Caches/npm Caches/Playwright SimulatorDevices"
new_case() {
  case_dir="$TMP_ROOT/$1"
  user="$case_dir/user"
  fm="$case_dir/fm"
  drive="$case_dir/drive"
  mkdir -p "$user" "$fm/config"
  # The fresh login shell finds the fake tools only through the user's profile.
  # shellcheck disable=SC2016 # $PATH expands when the profile is sourced.
  printf 'export PATH=%s:$PATH\nexport KEEP_ME=1\n' "$FAKEBIN" > "$user/.bash_profile"
  cat > "$fm/config/work-drive" <<EOF
root=$drive
env=PLAYWRIGHT_BROWSERS_PATH=Caches/Playwright
npm-cache=Caches/npm
xcode-derived-data=Build/DerivedData
simulator-set=SimulatorDevices
build-tmp=Build/Tmp
shell-env-file=$user/.bash_profile
EOF
}
make_drive() {
  local rel
  for rel in $TARGETS; do mkdir -p "$drive/$rel"; done
}
write_placement() {
  jq -n --arg d "$drive" --arg t "$TARGETS" \
    '{drive:$d,required_drive_dirs:($t|split(" "))}' > "$fm/config/crew-placement.json"
}
# FM_WORK_DRIVE_TEST_MOUNT stands in for a real mount; unset it to test refusal.
wd() {
  env HOME="$user" SHELL="$(command -v bash)" FM_HOME="$fm" PATH="$FAKEBIN:$PATH" \
    FM_WORK_DRIVE_TEST_MOUNT="${mount_seam-$drive}" bash "$ROOT/bin/fm-work-drive.sh" "$@"
}

new_case missing
mount_seam=
set +e; out=$(wd check 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'missing drive refuses'
assert_contains "$out" 'refused drive' 'missing drive is named'
set +e; out=$(wd exec -- touch "$case_dir/ran" 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'exec refuses on a missing drive'
[ ! -e "$case_dir/ran" ] || fail 'exec ran its command without the drive'
[ ! -e "$drive" ] || fail 'a missing drive was created on internal storage'
unset mount_seam
pass 'missing drive refuses check and exec with no fallback'

new_case unmounted
make_drive
mount_seam=
set +e; out=$(wd check 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'ordinary directory refuses'
assert_contains "$out" 'not a mounted volume' 'unmounted drive is named'
set +e; wd exec -- touch "$case_dir/ran" >/dev/null 2>&1; rc=$?; set -e
assert_equals 3 "$rc" 'exec refuses an unmounted drive'
[ ! -e "$case_dir/ran" ] || fail 'exec ran on an unmounted drive'
unset mount_seam
pass 'a directory that is not a mount is refused'

new_case targets
make_drive
rmdir "$drive/Caches/npm"
mv "$drive/SimulatorDevices" "$case_dir/elsewhere"
ln -s "$case_dir/elsewhere" "$drive/SimulatorDevices"
set +e; out=$(wd check 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'bad targets refuse'
assert_contains "$out" "refused npm-cache: $drive/Caches/npm is missing" 'missing target is named'
assert_contains "$out" 'refused simulator-set' 'symlinked target is named'
assert_contains "$out" "ok build-tmp $drive/Build/Tmp" 'healthy targets still report'
[ ! -e "$drive/Caches/npm" ] || fail 'check created a missing target'
if [ "$(id -u)" != 0 ]; then
  rm "$drive/SimulatorDevices"; mkdir "$drive/SimulatorDevices" "$drive/Caches/npm"
  chmod 0555 "$drive/Build/Tmp"
  set +e; out=$(wd check 2>&1); rc=$?; set -e
  chmod 0755 "$drive/Build/Tmp"
  assert_equals 3 "$rc" 'unwritable target refuses'
  assert_contains "$out" "refused build-tmp: $drive/Build/Tmp is not writable" 'unwritable target is named'
fi
pass 'missing, symlinked and unwritable targets are refused, never created'

new_case exec
make_drive
out=$(wd check)
assert_contains "$out" "ok drive $drive" 'healthy drive passes'
[ -z "$(find "$drive" -name '.fm-work-drive.*')" ] || fail 'write probes left files'
set +e
# shellcheck disable=SC2016 # Expanded by the command exec runs.
wd exec -- bash -c 'printf "%s\n%s\n%s\n" "$TMPDIR" "$PLAYWRIGHT_BROWSERS_PATH" "$npm_config_cache" > "$HOME/seen"; touch "$TMPDIR/work"; exit 7'
rc=$?
set -e
assert_equals 7 "$rc" 'exec returns the command status'
assert_equals "$drive/Build/Tmp/job." "$(sed -n 1p "$user/seen" | sed 's/job\..*/job./')" 'TMPDIR is a job directory on the drive'
assert_equals "$drive/Caches/Playwright" "$(sed -n 2p "$user/seen")" 'env entries reach the command'
assert_equals "$drive/Caches/npm" "$(sed -n 3p "$user/seen")" 'npm cache reaches the command'
[ -z "$(ls -A "$drive/Build/Tmp")" ] || fail 'exec left its job directory behind'
wd simctl list devices
assert_equals "simctl --set $drive/SimulatorDevices list devices" "$(cat "$user/xcrun-args")" 'simctl uses the drive device set'
pass 'exec and simctl run on the drive and clean up'

new_case placement_absent
make_drive
set +e; out=$(wd verify 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'verify refuses before install'
assert_contains "$out" 'refused fresh-shell PLAYWRIGHT_BROWSERS_PATH' 'missing shell export is named'
assert_contains "$out" 'refused placement:' 'absent placement profile refuses verification'
set +e; out=$(wd install --dry-run 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'install refuses without placement admission'
assert_contains "$out" 'refused placement:' 'install names its missing placement admission'
pass 'verify and install fail closed until placement admission is active'

new_case install
mkdir -p "$drive"
write_placement
chmod 0600 "$user/.bash_profile"
cp "$user/.bash_profile" "$case_dir/profile-before"
out=$(wd install --dry-run)
assert_contains "$out" "export PLAYWRIGHT_BROWSERS_PATH='$drive/Caches/Playwright'" 'dry run shows the block'
assert_contains "$out" "would create directory $drive/Caches/Playwright" 'dry run shows missing drive folders'
assert_contains "$out" 'local.firstmate.internal-growth' 'dry run prints the LaunchAgent plist'
assert_contains "$out" 'launchctl bootstrap' 'dry run prints the bootstrap command'
cmp -s "$user/.bash_profile" "$case_dir/profile-before" || fail 'dry run changed the profile'
[ ! -e "$user/npm-calls" ] || fail 'dry run changed npm'
[ ! -e "$user/Library/LaunchAgents/local.firstmate.internal-growth.plist" ] || fail 'dry run wrote the LaunchAgent'
[ ! -e "$drive/Caches/Playwright" ] || fail 'dry run created a target directory'
out=$(wd install)
assert_contains "$out" "ok fresh-shell PLAYWRIGHT_BROWSERS_PATH=$drive/Caches/Playwright" 'fresh shell sees the export'
assert_contains "$out" "ok npm cache $drive/Caches/npm" 'npm resolves the drive cache'
assert_contains "$out" "ok xcode derived data $drive/Build/DerivedData" 'Xcode default points at the drive'
assert_contains "$out" 'enrolled local.firstmate.internal-growth' 'daily growth check is enrolled'
assert_contains "$out" "ok internal growth LaunchAgent gui/$(id -u)/local.firstmate.internal-growth" 'final verification sees the loaded LaunchAgent'
for rel in $TARGETS; do [ -d "$drive/$rel" ] || fail "install did not create $rel"; done
plist="$user/Library/LaunchAgents/local.firstmate.internal-growth.plist"
python3 - "$plist" "$ROOT" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    plist = plistlib.load(handle)
assert plist["Label"] == "local.firstmate.internal-growth"
assert plist["ProgramArguments"] == ["/bin/bash", sys.argv[2] + "/bin/fm-internal-growth.sh"]
assert plist["StartCalendarInterval"] == {"Hour": 3, "Minute": 30}
PY
assert_contains "$(cat "$user/launchctl-calls")" "bootstrap gui/$(id -u) $plist" 'install bootstraps the per-user LaunchAgent'
wd install >/dev/null
assert_equals 1 "$(grep -c '^# >>> firstmate work drive >>>$' "$user/.bash_profile")" 'install is idempotent'
grep -qx 'export KEEP_ME=1' "$user/.bash_profile" || fail 'install dropped unmanaged lines'
[ -n "$(find "$user/.bash_profile" -perm 0600)" ] || fail 'install changed the file mode'
pass 'install writes persistent settings that a fresh login shell inherits'

printf 'HOME\nPATH\n' > "$fm/config/launch-env-allowlist"
set +e; out=$(wd verify 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'allowlist without the name refuses'
assert_contains "$out" 'PLAYWRIGHT_BROWSERS_PATH is not listed' 'dropped name is named'
echo PLAYWRIGHT_BROWSERS_PATH >> "$fm/config/launch-env-allowlist"
wd verify >/dev/null
jq -n --arg d "$drive" --arg dirs "$TARGETS" '{drive:$d,required_drive_dirs:$dirs}' > "$fm/config/crew-placement.json"
set +e; out=$(wd verify 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'placement directory string refuses'
assert_contains "$out" 'an array of directory strings' 'invalid placement schema is named'
jq -n --arg d "$drive" '{drive:$d,required_drive_dirs:["Build/Tmp"]}' > "$fm/config/crew-placement.json"
set +e; out=$(wd verify 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'placement missing a target refuses'
assert_contains "$out" 'required_drive_dirs lacks Caches/npm' 'uncovered target is named'
write_placement
out=$(wd verify)
assert_contains "$out" 'ok placement requires SimulatorDevices' 'matching placement passes'
pass 'verify checks the launch allowlist and placement profile'

project="$case_dir/project"
treehouse_root="$drive/Treehouse"
mkdir -p "$project" "$treehouse_root"
printf 'root = "%s"\n' "$treehouse_root" > "$project/treehouse.toml"
out=$(wd verify --project "$project")
assert_contains "$out" "ok treehouse root $treehouse_root" 'literal project Treehouse root passes'
printf '[pool]\nroot = "%s"\n' "$treehouse_root" > "$project/treehouse.toml"
set +e; out=$(wd verify --project "$project" 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'nested Treehouse root refuses'
assert_contains "$out" 'must contain one literal top-level root' 'non-top-level root is named'
printf 'root = "%s"\n' "$drive/MissingTreehouse" > "$project/treehouse.toml"
set +e; out=$(wd verify --project "$project" 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'missing Treehouse root refuses'
assert_contains "$out" 'is missing or not a real directory' 'missing Treehouse root is named'
printf 'root = "%s"\n' "$case_dir" > "$project/treehouse.toml"
set +e; out=$(wd verify --project "$project" 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'Treehouse root outside the drive refuses'
assert_contains "$out" "is outside $drive" 'outside Treehouse root is named'
rm "$project/treehouse.toml"
printf 'root = "%s"\n' "$treehouse_root" > "$case_dir/treehouse.toml"
ln -s "$case_dir/treehouse.toml" "$project/treehouse.toml"
set +e; out=$(wd verify --project "$project" 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'symlinked Treehouse config refuses'
assert_contains "$out" 'or symlinked' 'symlinked Treehouse config is named'
pass 'verify checks each project Treehouse root on the drive'

new_case enrollment_failure
mkdir -p "$drive"
write_placement
touch "$user/launchctl-fail-bootstrap"
set +e; out=$(wd install 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'failed LaunchAgent bootstrap refuses install'
assert_contains "$out" 'launchctl bootstrap failed' 'failed bootstrap is named'
assert_not_contains "$out" 'enrolled local.firstmate.internal-growth' 'failed bootstrap is not reported as enrolled'
assert_not_contains "$out" 'ok fresh-shell' 'verification does not run after failed enrollment'
set +e; out=$(wd verify 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'standalone verify refuses after failed bootstrap'
assert_contains "$out" "refused internal growth LaunchAgent: gui/$(id -u)/local.firstmate.internal-growth is not loaded" 'standalone verify names the unloaded LaunchAgent'
assert_contains "$(cat "$user/launchctl-calls")" "print gui/$(id -u)/local.firstmate.internal-growth" 'standalone verify queries the per-user LaunchAgent'
pass 'install stops when daily growth enrollment fails'

new_case block_order
make_drive
write_placement
cat > "$user/.bash_profile" <<EOF
export KEEP_BEFORE=1
# <<< firstmate work drive <<<
export KEEP_MIDDLE=1
# >>> firstmate work drive >>>
export KEEP_AFTER=1
EOF
cp "$user/.bash_profile" "$case_dir/profile-before"
set +e; out=$(wd install 2>&1); rc=$?; set -e
assert_equals 3 "$rc" 'reversed work-drive block refuses'
assert_contains "$out" 'unbalanced or repeated work-drive block' 'invalid block order is named'
cmp -s "$user/.bash_profile" "$case_dir/profile-before" || fail 'reversed block changed the shell profile'
[ ! -e "$user/npm-calls" ] || fail 'reversed block changed npm configuration'
[ ! -e "$user/launchctl-calls" ] || fail 'reversed block enrolled the LaunchAgent'
pass 'install preserves a shell profile with reversed block markers'

new_case invalid
printf 'root=%s\nenv=X=../escape\n' "$drive" > "$fm/config/work-drive"
set +e; out=$(wd check 2>&1); rc=$?; set -e
assert_equals 2 "$rc" 'escaping target is invalid'
rm "$fm/config/work-drive"
set +e; out=$(wd check 2>&1); rc=$?; set -e
assert_equals 2 "$rc" 'missing configuration is invalid'
pass 'invalid or missing configuration refuses before any probe'
