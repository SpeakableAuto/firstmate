# Work drive and internal growth check

A host with a dedicated external work drive can keep build output and caches there instead of on its internal disk.
`bin/fm-work-drive.sh` points those tools at real directories on the drive and refuses to run drive-bound work when the drive is missing, unmounted, or unwritable; it never falls back to internal storage.
`bin/fm-internal-growth.sh` is the daily check that flags internal folders that grew past a threshold outside an allowed list.
Both script headers and `--help` own the exact configuration keys, exit codes, state files, and alert semantics.
Neither is enrolled automatically, and a host without a work drive configures neither.

## Configure the work drive

Create the drive's work directories first; the scripts never create them.
Then write `config/work-drive` in the persistent Firstmate home, for example:

```text
root=/Volumes/Work
env=PLAYWRIGHT_BROWSERS_PATH=Caches/Playwright
npm-cache=Caches/npm
xcode-derived-data=Build/DerivedData
simulator-set=SimulatorDevices
build-tmp=Build/Tmp
```

Run `FM_HOME=/absolute/firstmate bin/fm-work-drive.sh check` to prove the drive is a real mount and every target is a writable real directory.
Run `install --dry-run`, review the planned changes, then run `install`.
It writes the `env=` exports into a marked block of the user's shell environment file (`~/.zshenv` by default, read by every zsh including worker panes after a reboot), sets the user npm `cache`, and sets Xcode's `IDECustomDerivedDataLocation` default.
Remove any hand-written exports of the same names outside the marked block so one copy remains.
`verify` then reads each setting back from a fresh login shell started with an empty environment, so it proves what a newly launched worker inherits rather than what the current process happens to have.
When `config/launch-env-allowlist` exists, `verify` also requires every exported name to be listed there, because worker launches otherwise drop it.

## Refusing heavy work when the drive fails

Worker placement refuses heavy work on a missing or unwritable drive when `config/crew-placement.json` names the same drive and lists every work-drive target in its required directories.
`verify` reports that profile as pending while it is absent and refuses a profile whose drive or directories disagree with `config/work-drive`.
The tool settings above point at the drive with no fallback, so a tool started while the drive is absent fails instead of writing to internal storage.

## Build jobs and simulators

`fm-work-drive.sh exec -- <command>` runs one build job with `TMPDIR` set to a private directory under `build-tmp`, removes that directory afterwards, and returns the command's status.
It is opt-in because a drive-wide `TMPDIR` lengthens Unix socket paths that some tests need to stay short.
`fm-work-drive.sh simctl <args>` runs `xcrun simctl --set` against the drive's device set.
Xcode offers no supported setting that moves the default simulator device set, so `xcodebuild` and Simulator.app keep using the internal default set; only simctl calls made through this command use the drive.
Codex keeps session history under its home directory beside its sign-in files, and its documented `log_dir` setting moves only local logs while turning on a plaintext log, so session history stays on the internal disk.

## Configure the internal growth check

Write `config/internal-growth` in the same home, for example:

```text
volume=/System/Volumes/Data
threshold_gib=1
depth=3
scan=/Users/me
scan=/opt/homebrew
allow=/Users/me/firstmate
allow=/Users/me/Library/Mail
```

Each `scan=` path must be on `volume`; `du -x` keeps each measurement on that volume, so the work drive is never counted.
List under `allow=` only folders that are meant to live internally, such as the Firstmate home, always-on services, and application data.
Run `FM_HOME=/absolute/firstmate bin/fm-internal-growth.sh --dry-run` first to see the measurement without writing state.
The first real run records the baseline; later runs compare with it and queue one Firstmate check wake per new episode.
Each run appends one JSON line to `state/internal-growth/log.jsonl` with free space, the used-space change, and any flagged folders.
A large scan can take several minutes, so schedule it rather than running it interactively.

## Install a daily launchd agent

Install as the logged-in user, replacing `/absolute/firstmate` and `/absolute/user`, and save the following as `~/Library/LaunchAgents/local.firstmate.internal-growth.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.firstmate.internal-growth</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>/absolute/firstmate/bin/fm-internal-growth.sh</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>FM_HOME</key><string>/absolute/firstmate</string>
    <key>HOME</key><string>/absolute/user</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer>
  </dict>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>/absolute/user/Library/Logs/firstmate-internal-growth.log</string>
  <key>StandardErrorPath</key><string>/absolute/user/Library/Logs/firstmate-internal-growth.log</string>
</dict></plist>
```

Validate and load it the same way as the [local disk guard](disk-guard.md#install-a-local-launchd-agent), using this label.
The baseline's minimum age keeps a missed or repeated run comparing against an approximately day-old baseline.

## Verification

Run `bash bin/fm-test-run.sh tests/fm-work-drive.test.sh tests/fm-internal-growth.test.sh` for the refusal, fresh-shell, threshold, and alert-deduplication checks.
