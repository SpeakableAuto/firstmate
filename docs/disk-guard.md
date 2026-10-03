# Local disk guard

`bin/fm-disk-guard.sh` checks the user's home filesystem and queues durable Firstmate alerts when space is low.
It runs independently of the primary harness and worker runtime backend; the existing wake queue delivers its alerts.
Its header and `--help` own configuration syntax, cache targets, error handling, and lock recovery.
No host is enrolled automatically.
Only rebuildable caches are eligible; backups, application data, Docker volumes and containers remain outside the allowlist.
Cleanup can evict caches used by active builds, so subsequent builds may take longer.

## Configure and verify

Use an absolute path to the persistent Firstmate home, not a disposable worktree.
Create `config/disk-guard` there with the targets this machine should clean, for example:

```text
threshold_gib=15
cache=xcode-derived-data
cache=npm
cache=docker
```

Omit any cache the machine should not clean.
The npm target uses the standard home cache only; custom npm cache locations are not followed.
For Docker, use a local Unix socket context and ensure Docker is available in the scheduled job's environment.
An unavailable Docker daemon is reported as a cleanup failure while other configured caches are still processed.

Run the installed script with `FM_HOME` set and `--dry-run` first.
Dry-run measures real space and prints the planned targets only when below threshold; it performs no cleanup or alert writes.
A successful cleanup check can still leave the disk below threshold; inspect the before/after values in the result alert.
The next scheduled check retries while space remains low.

## Install a local launchd agent

Install separately as the logged-in user on each Mac.
Replace `/absolute/firstmate` and `/absolute/user` below with that machine's real paths, XML-escaping any special characters.
The script path must point to a persistent installed checkout containing its sibling libraries.
Create the log directory first, and save the following as `~/Library/LaunchAgents/local.firstmate.disk-guard.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.firstmate.disk-guard</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>/absolute/firstmate/bin/fm-disk-guard.sh</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>FM_HOME</key><string>/absolute/firstmate</string>
    <key>HOME</key><string>/absolute/user</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>900</integer>
  <key>StandardOutPath</key><string>/absolute/user/Library/Logs/firstmate-disk-guard.log</string>
  <key>StandardErrorPath</key><string>/absolute/user/Library/Logs/firstmate-disk-guard.log</string>
</dict></plist>
```

Validate and load the agent after reviewing the allowlist:

```sh
mkdir -p "$HOME/Library/Logs" "$HOME/Library/LaunchAgents"
plutil -lint "$HOME/Library/LaunchAgents/local.firstmate.disk-guard.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.firstmate.disk-guard.plist"
launchctl print "gui/$(id -u)/local.firstmate.disk-guard"
```

Loading runs the first check immediately, then every 15 minutes while the user session is available.
For an update, unload the old job with `launchctl bootout "gui/$(id -u)/local.firstmate.disk-guard"`, edit and validate the plist, then bootstrap it again.
To disable automatic checks, use that same bootout command.
Do not install as root or share a guard between different Firstmate homes on the same host.

## Verification

Run `bash bin/fm-test-run.sh tests/fm-disk-guard.test.sh` for the deterministic cache-boundary and alert checks.
The tests use temporary homes and stub disk/Docker commands; they do not clean the operator's caches or install a launchd job.
