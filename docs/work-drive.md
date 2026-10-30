# Work drive and internal growth check

A host with a dedicated external work drive can keep build output and caches there instead of on its internal disk.
`bin/fm-work-drive.sh` points those tools at real directories on the drive and refuses to run drive-bound work when the drive is missing, unmounted, or unwritable; it never falls back to internal storage.
`bin/fm-internal-growth.sh` is the daily check that flags internal folders that grew past a threshold outside an allowed list.
Both script headers and `--help` own the exact configuration keys, exit codes, state files, and alert semantics.
The work-drive install command creates the configured drive folders, persists the tool settings, and enrolls the daily growth check for the logged-in user.
A host without a work drive configures neither mechanism.

## Configure the work drive

Write `config/work-drive` in the persistent Firstmate home, for example:

```text
root=/Volumes/Kitchen
env=PLAYWRIGHT_BROWSERS_PATH=Caches/Playwright
npm-cache=Caches/npm
xcode-derived-data=Build/DerivedData
simulator-set=SimulatorDevices
build-tmp=Build/Tmp
```

Run `FM_HOME=/absolute/firstmate bin/fm-work-drive.sh check` to prove an already configured drive and its targets are usable.
Run `install --dry-run`, review the planned changes, then run `install`.
Install first proves that `/Volumes/Kitchen` is a real writable mount, then creates missing configured target folders on that drive.
It never creates the drive root and never falls back to internal storage.
It writes the `env=` exports into a marked block of the user's shell environment file (`~/.zshenv` by default, read by every zsh including worker panes after a reboot), sets the user npm `cache`, and sets Xcode's `IDECustomDerivedDataLocation` default.
It also writes and bootstraps `~/Library/LaunchAgents/local.firstmate.internal-growth.plist` with a daily 3:30 am schedule.
Remove any hand-written exports of the same names outside the marked block so one copy remains.
`verify` reads the environment exports and npm cache from a fresh login shell started with an empty environment, then reads the Xcode default directly.
This proves what a newly launched worker inherits rather than what the current process happens to have.
When `config/launch-env-allowlist` exists, `verify` also requires every exported name to be listed there, because worker launches otherwise drop it.

## Refusing heavy work when the drive fails

Worker placement refuses heavy work on a missing or unwritable drive when `config/crew-placement.json` names the same drive and lists every work-drive target in its required directories.
The [crew-placement configuration](configuration.md#crew-placement-configcrew-placementjson) owns that profile's full contract and example.
`verify` and `install` refuse an absent profile, a different drive, or a profile that does not cover every target in `config/work-drive`.
This fail-closed behavior prevents an incomplete host configuration from being reported as active.
Installation and verification also require the real mount parent to be non-writable by the build user, as `/Volumes` normally is on macOS.
This filesystem boundary prevents any configured tool, including an already running process or light work outside placement admission, from recreating an absent mount directory internally.
The installer refuses unsafe parents and never changes host permissions; an administrator must provision the mount location first.
Do not run build tools as root or deliberately replace that protected mount arrangement.
Placement still checks the mounted drive and required targets before heavy admission; these are separate checks for admission and persistent tool paths.

## Treehouse project pools

Each primary project clone keeps an untracked, ignored `treehouse.toml` in its repository root with one literal top-level pool root on the work drive, for example:

```toml
root = "/Volumes/Kitchen"
```

At spawn, the placement gate reads that file and pins `TREEHOUSE_ROOT` to its root instead of relying on a global export.
Run `fm-work-drive.sh verify --project /absolute/project` for each primary clone.
The check refuses unless `treehouse.toml` is a regular non-symlinked file and its literal top-level `root` is an existing real directory at or below the configured work-drive root.

## Build jobs and simulators

`fm-work-drive.sh exec -- <command>` runs one build job with `TMPDIR` set to a private directory under `build-tmp`, removes that directory afterwards, and returns the command's status.
It is opt-in because a drive-wide `TMPDIR` lengthens Unix socket paths that some tests need to stay short.
`fm-work-drive.sh simctl <args>` runs `xcrun simctl --set` against the drive's device set.
Xcode offers no supported setting that moves the default simulator device set, so `xcodebuild` and Simulator.app keep using the internal default set; only simctl calls made through this command use the drive.
Codex session data is separable through its documented `log_dir` and `sqlite_home` settings, but `log_dir` enables a plaintext TUI log and the work drive is unencrypted, so session data deliberately stays on the internal disk beside its sign-in files.

## Configure the internal growth check

Install creates `config/internal-growth` if absent, with the user's home as its scan root and concrete allowances for operational folders, user applications/application support, and the retained internal Codex sessions.
Review that generated list and add specific always-on service directories when applicable; project directories are not blanket-allowed.
An existing invalid configuration is refused rather than replaced.
To customize the scope before installation, write `config/internal-growth` in the same home, for example:

```text
volume=/System/Volumes/Data
threshold_gib=1
depth=3
scan=/Users/me
scan=/opt/homebrew
allow=/Users/me/firstmate/data
allow=/Users/me/firstmate/config
allow=/Users/me/firstmate/state
```

Each `scan=` path must be on `volume`; `du -x` keeps each measurement on that volume, so the work drive is never counted.
List under `allow=` only folders that are meant to live internally, such as specific Firstmate operational directories, always-on services, and application data.
An existing allowed folder outside every scan root is measured directly and must be a real directory on `volume`.
A folder that `du` cannot read is retained in the log row's `unmeasured` list and labeled `UNMEASURED` in any alert emitted during that run.
A nonzero `du` exit remains a usable partial measurement when the scan-root total exists, while a missing scan-root total is a failed measurement.
The check also reads total volume use from `df` and opens a separate episode when used-space growth above the threshold is not explained by allowed or already flagged folder growth.
A run that exceeds `timeout_seconds` is stopped and reported as a failed measurement rather than left hanging.
Run `FM_HOME=/absolute/firstmate bin/fm-internal-growth.sh --dry-run` first to see the measurement without writing state.
The first successful measurement records the baseline; later runs compare with it and queue one Firstmate check wake naming every new episode.
Each non-dry measurement attempt appends one JSON line to `state/internal-growth/log.jsonl` with free space, the used-space change, and any flagged folders.
A large scan can take several minutes, so schedule it rather than running it interactively.

## Daily launchd enrollment

`fm-work-drive.sh install` performs host enrollment by writing and bootstrapping the per-user `local.firstmate.internal-growth` LaunchAgent.
Installation requires a valid growth configuration, a successful read-only measurement, and an initial recorded check before enrollment, and refuses a failed bootstrap.
The enrolled service retains the effective `FM_CONFIG_OVERRIDE` and `FM_STATE_OVERRIDE` directories used during installation.
`verify` requires that same valid configuration and read-only measurement as well as the loaded LaunchAgent; a loaded service alone is not proof that the check works.
Failed dry-run measurements return a nonzero status without creating baseline, logs, or alerts.
`install --dry-run` prints the complete plist and the `launchctl bootout` and `launchctl bootstrap` commands without writing or loading anything.
The baseline's minimum age keeps a missed or repeated run comparing against an approximately day-old baseline.

## Verification

Run `bash bin/fm-test-run.sh tests/fm-work-drive.test.sh tests/fm-internal-growth.test.sh` for the refusal, fresh-shell, threshold, and alert-deduplication checks.
