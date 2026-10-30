# Supervisor watchdog

The optional watchdog runs outside the supervisor session and nudges an idle Claude supervisor on Herdr after a network error and restored provider connectivity, or when queued wakes sit undelivered.
It also restarts a supervisor that stops making progress while work is under way.
Its state machine, guards, supported configuration, and residual input race are owned by [`bin/fm-supervisor-watchdog.sh`](../bin/fm-supervisor-watchdog.sh), whose `--help` prints the operator contract.
It never touches worker panes or repairs a dead shell.
Other primary harnesses and tmux, Zellij, Orca, cmux, and Codex App are unsupported and must not be configured as targets.

Recovery requires two continuous, semantically unchanged terminal-network-error observations with an empty prompt at least ten seconds apart, followed by fresh checks immediately before sending one short resume line.
An intervening clear frame discards the pending observation window, so any returning error must remain stable for a full new interval.
Only the latest output row and current composer/footer region can veto recovery as busy; busy-looking text from earlier transcript rows is ignored.
Claude's dim rotating empty-composer suggestion is also ignored by the stability check, while a draft or substantive change during an error holds recovery and queues a `check: supervisor-watchdog` alert for Firstmate.
Herdr cannot atomically check the prompt and send input, so a human keystroke in the final read/send window can still mix with the nudge.
This is a guarded best-effort safeguard; it is not an input lock.
The watchdog never clears mixed input or retries an ambiguous submission, and it verifies a new turn before reporting success.
Separately, a main-owned wake older than `FM_WATCHDOG_WAKE_AGE_SECS` (600 seconds by default) while Claude is idle or done queues a `check: supervisor-watchdog` row and uses the [configured active-alert channels](wedge-alarm.md).
That alarm fires once for each unchanged oldest-row episode, rearming when the oldest row changes or the queue drains.
Because an idle supervisor wakes only on new input, the watchdog then rings it with one short drain line when the prompt stays empty and unchanged for the idle interval, which covers a turn that ended without its Stop hook and so left no watcher running.
The ring uses the network nudge's guards: native idle or done, no busy footer or usage-limit notice, a dim suggestion counted as empty, fresh checks before typing, and exactly its own line before Enter.
A confirmed ring repeats after another stable idle interval and the backoff while the same row stays undelivered; an ambiguous ring holds and alerts until the oldest row changes or the queue drains.

## Stall recovery

While the home needs supervision, the watchdog treats a newer watcher beacon only while Claude is natively idle or done, and it also treats an acknowledged wake, a newer supervisor transcript file, or a semantic screen change as progress.
Spinner rows, elapsed durations, token counters and Claude's rotating hint row below the prompt are ignored, while other numbers remain semantic progress.
A visible usage-limit notice counts as progress, because Claude resumes by itself and typing would cancel that.
After `FM_WATCHDOG_STALL_SECS` (1800 seconds by default) without progress it sends one guarded nudge, which is withheld when the supervisor is busy or its version is unverified.
After a second quiet interval it reads a fresh frame and restarts only when the installed version is verified and the composer is explicitly empty.
A pending, unknown or unreadable composer, an unsupported harness, or version drift holds the restart and sends one urgent alert that says unsent input may be in the box.
A permitted restart stops only the target pane's foreground processes, relaunches `FM_WATCHDOG_RESTART_COMMAND` in `FM_WATCHDOG_RESTART_CWD` with a prompt naming the newest `data/supervisor-handoff-*.md`, and proves a new Claude session started in that pane.
An unproven restart or no progress for another interval after a proven one sends one urgent supervisor-down alert through the [urgent captain alert path](wedge-alarm.md#urgent-captain-alerts).
The same incident retries delivery through the alert limiter until Hermes sends it or reports the incident as a duplicate.

## Claude version drift

The job pins the complete `claude --version` output that passed the live check.
A different installed version raises one check wake and one active alert per newly seen version and switches the watchdog to a degraded mode rather than disabling it.
In that mode nothing is typed into or stopped in the supervisor, because the network nudge, queue ring, stall nudge and safe restart all depend on verified screen reading.
The wake-age alert and stall timer keep running, and after the second quiet interval one urgent alert says the supervisor stalled and its restart was held because unsent input may be in the box.

After every Claude upgrade, run the live guard and move the pin only when it passes:

```sh
FM_LIVE_WATCHDOG_CLAUDE=1 bash bin/fm-test-run.sh tests/fm-supervisor-watchdog-claude-live-e2e.test.sh
```

It runs the installed Claude in a guarded named Herdr lab with its API base URL pointed at a closed local port, so it spends no tokens, and its last line prints the exact pin.
Apply that pin to the installed job and reload it:

```sh
P="$HOME/Library/LaunchAgents/local.firstmate.supervisor-watchdog.plist"
launchctl bootout "gui/$(id -u)/local.firstmate.supervisor-watchdog"
plutil -replace EnvironmentVariables.FM_WATCHDOG_CLAUDE_VERSION -string "$(claude --version)" "$P"
plutil -lint "$P"
launchctl bootstrap "gui/$(id -u)" "$P"
```

Keep one Claude install on the job's `PATH`, the same binary the supervisor runs, so the pinned version is the version in use.

## Local launchd setup

Use a stable installed checkout, not a task worktree, and choose the exact supervisor session and pane explicitly.
Pin the complete output of `claude --version` in the job after the live guard above passes.
A version change degrades recovery as described above until the guard is repeated and the pin moved.
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
    <key>FM_WATCHDOG_RESTART_COMMAND</key><string>claude</string>
    <key>FM_WATCHDOG_TRANSCRIPT_DIR</key><string>/absolute/.claude/projects/encoded-supervisor-cwd</string>
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

Inspect `state/supervisor-watchdog/events.jsonl` and the launchd error log to distinguish a refused configuration, an aged-wake alert, a queue ring, a network wait, a held incident, and a confirmed submission.
These records contain timestamps and classifications, not prompt contents or pane captures.
Treat `held` as requiring inspection; it does not mean the original error recovered.
A continuously stable, error-free idle screen releases the incident after the idle interval, while the retained action timestamp still delays another nudge until the configured backoff elapses.
If an operator explicitly resets an incident after inspection, archive `incident.json` while the job is stopped, then reload the job.
Do not delete incident state during an outage to force repeated nudges.
Retain or rotate the local logs according to the home's normal operational policy.

## Verification

Run the portable regression with `bin/fm-test-run.sh tests/fm-supervisor-watchdog.test.sh`.
Run the isolated transport test with `bin/fm-test-run.sh tests/fm-supervisor-watchdog-herdr-e2e.test.sh`.
It uses a guarded, named Herdr lab and a stub supervisor that prints fixture pane text, including a controlled stall that is restarted in its own pane while a neighbouring worker pane keeps running.
It exercises real terminal delivery and native state reporting without contacting any model provider.
This is transport evidence, not certification of the installed Claude renderer or provider credentials.
The live guard `tests/fm-supervisor-watchdog-claude-live-e2e.test.sh` certifies the installed Claude renderer: the visible error shape, the empty and drafted prompt, and one confirmed resume turn.
Current version-specific results belong in [runtime backend verification](verification/runtime-backends.md).
