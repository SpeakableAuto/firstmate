# Supervisor network-error watchdog

The optional watchdog runs outside the supervisor session and nudges an idle Claude supervisor on Herdr after a network error and restored provider connectivity.
Its state machine, guards, supported configuration, and residual input race are owned by [`bin/fm-supervisor-watchdog.sh`](../bin/fm-supervisor-watchdog.sh), whose `--help` prints the operator contract.
It does not restart a process, repair a dead shell, or manage workers.
Other primary harnesses and tmux, Zellij, Orca, cmux, and Codex App are unsupported and must not be configured as targets.

Recovery uses two unchanged, empty-prompt observations at least ten seconds apart, followed by fresh checks immediately before sending one short resume line.
A draft or observed screen change holds recovery and queues a `check: supervisor-watchdog` alert for Firstmate.
Herdr cannot atomically check the prompt and send input, so a human keystroke in the final read/send window can still mix with the nudge.
This is a guarded best-effort safeguard; it is not an input lock.
The watchdog never clears mixed input or retries a submission, and it verifies a new turn before reporting success.

## Local launchd setup

Use a stable installed checkout, not a task worktree, and choose the exact supervisor session and pane explicitly.
Pin the complete output of `claude --version` in the job and perform a supervised real-harness acceptance check after installation before relying on unattended recovery.
A version change disables recovery until that operator verification is repeated.
Choose an HTTPS endpoint on the actual provider's API host that answers without credentials; a 401 or 404 is sufficient to prove transport reachability, while 429, server errors, TLS failures, and timeouts defer the action.
This probe checks connectivity, not account access or model availability.

Create `~/Library/LaunchAgents/local.firstmate.supervisor-watchdog.plist` with the following template, replacing the example paths, target, version, and provider URL.
Create the home's `state/supervisor-watchdog` directory first so launchd can open its logs.
Set `PATH` to include the actual installed locations of Bash, Herdr, Claude, jq, curl, and shasum.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.firstmate.supervisor-watchdog</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>/absolute/firstmate/bin/fm-supervisor-watchdog.sh</string>
    <string>tick</string>
  </array>
  <key>WorkingDirectory</key><string>/absolute/firstmate</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/absolute/tool-bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    <key>FM_HOME</key><string>/absolute/firstmate-home</string>
    <key>FM_SUPERVISOR_BACKEND</key><string>herdr</string>
    <key>FM_SUPERVISOR_TARGET</key><string>chosen-session:w1:p1</string>
    <key>FM_WATCHDOG_CLAUDE_VERSION</key><string>REPLACE WITH VERIFIED VERSION OUTPUT</string>
    <key>FM_WATCHDOG_PROBE_URL</key><string>https://api.anthropic.com/</string>
  </dict>
  <key>StartInterval</key><integer>15</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>/absolute/firstmate-home/state/supervisor-watchdog/launchd.out.log</string>
  <key>StandardErrorPath</key><string>/absolute/firstmate-home/state/supervisor-watchdog/launchd.err.log</string>
</dict></plist>
```

Validate and load the job locally:

```sh
plutil -lint "$HOME/Library/LaunchAgents/local.firstmate.supervisor-watchdog.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.firstmate.supervisor-watchdog.plist"
launchctl print "gui/$(id -u)/local.firstmate.supervisor-watchdog"
```

Stop it before changing its target or investigating an input hold:

```sh
launchctl bootout "gui/$(id -u)/local.firstmate.supervisor-watchdog"
```

Inspect `state/supervisor-watchdog/events.jsonl` and the launchd error log to distinguish a refused configuration, a network wait, a held incident, and a confirmed submission.
These records contain timestamps and classifications, not prompt contents or pane captures.
Treat `held` as requiring inspection; it does not mean the original error recovered.
A continuously stable, error-free idle screen can release the incident after the configured cooldown.
If an operator explicitly resets an incident after inspection, archive `incident.json` while the job is stopped, then reload the job.
Do not delete incident state during an outage to force repeated nudges.
Retain or rotate the local logs according to the home's normal operational policy.

## Verification

Run the portable regression with `bin/fm-test-run.sh tests/fm-supervisor-watchdog.test.sh`.
Run the isolated transport test with `bin/fm-test-run.sh tests/fm-supervisor-watchdog-herdr-e2e.test.sh`.
It uses a guarded, named Herdr lab and a stub supervisor that prints fixture pane text.
It exercises real terminal delivery and native state reporting without contacting any model provider.
This is transport evidence, not certification of the installed Claude renderer or provider credentials.
The operator must verify the real supervisor after installation, including the visible error shape, unchanged empty prompt, provider probe, and one confirmed resume turn.
Current version-specific results belong in [runtime backend verification](verification/runtime-backends.md).
