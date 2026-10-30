# Supervision active-alert channels

`config/wedge-alarm` configures the shared pane-independent channels for serious supervision failures.
The away-mode sub-supervisor uses them when escalation injection cannot confirm a submit past `FM_MAX_DEFER_SECS`.
The optional supervisor watchdog also uses them when a main-owned durable wake exceeds `FM_WATCHDOG_WAKE_AGE_SECS` while Claude is idle or done, when the installed Claude version drifts from its verified pin, and when a stalled supervisor enters the down stage.
Each caller owns its condition, durable marker, and rate limit, and the away-mode caller retains its tmux status-line flash as an additional signal.

## Channels

`config/wedge-alarm` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with one directive.

- `off` disables every configured active notification while retaining the caller's durable marker and any caller-specific visual signal.
- `auto` or `default` resolves to `osascript` on macOS.
  Other platforms have no built-in OS channel, so configure `command:` when a durable marker alone is insufficient.
- `osascript` posts a macOS Notification Center banner outside the terminal pane.
- `herdr` calls `herdr notification show` outside the supervised pane.
- `command:<cmd>` runs `<cmd>` through `sh -c` with the alarm summary as `$1` and on stdin, allowing delivery to a phone or pager service.

An absent `config/wedge-alarm` behaves as `auto`, which is default-on on macOS.
This is deliberate because both callers represent a supervision failure that should not remain silent.
The away-mode caller alerts at most once per max-defer window.
The supervisor watchdog alerts once for each unchanged oldest-row episode, once per newly seen unverified Claude version, and once when a stall enters the down stage.

Each channel is best-effort.
A missing binary or non-zero exit logs a warning and continues to the next channel without aborting the caller.
Every invocation is process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS`, which defaults to 10 seconds, including `command:`, `osascript`, `herdr`, and the test seam.
On timeout or daemon shutdown, the notifier process group is terminated and the next configured channel may run.
AppleScript receives the summary as an argv item rather than interpolated source, so summary text cannot alter the script.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Urgent captain alerts

[`bin/fm-urgent-alert.sh`](../bin/fm-urgent-alert.sh) is a separate path that reaches the captain away from the machine through Hermes, for conditions that block all priority progress and that firstmate cannot repair itself.
It accepts only `supervisor-down`, `carve-out-blocked` and `machine-down`, plus its own `test` subcommand, and never carries routine updates.
It always sends to Hermes' Telegram home channel.
Hermes keeps the platform login; firstmate only hands it the plain message.
Delivery is rate limited to one message per condition per six hours, the same condition and key once per day after Hermes confirms it, and four messages in any 24 hours.
Every attempt is logged in `state/urgent-alert/sent.jsonl`, delivered attempts include the platform message id, and message text and Telegram chat ids are never logged.
Once Hermes has run, a timeout, an error exit or a reply without a message id may still have reached the phone, so it is reported as failed and counts toward the daily cap, while the same key retries a few times about an hour apart instead of being treated as delivered.
For a supervisor-down incident, retries continue at a slower pace after the initial attempts, still within the daily cap.
Delivery waits up to 60 seconds, enough for Hermes to start and finish its own Telegram retries, and an unreadable log line is skipped rather than muting later alerts.
`fm_urgent_alert` in [`bin/fm-active-alert-lib.sh`](../bin/fm-active-alert-lib.sh) owns those limits and the log format, and the script header owns the commands, including the scheduled `check-machine` probe.
`tests/fm-active-alert.test.sh` covers the allow-list, fixed Telegram hand-off, rate limits, retry, message-id log and machine probe with a recording sender.

## Test safety

The urgent sender refuses automatic Hermes discovery in tests and no-mistakes gate agents; its marker and explicit sender override contract lives in [`bin/fm-active-alert-lib.sh`](../bin/fm-active-alert-lib.sh).
The alert suite injects recording senders with an isolated home and executable search path, and proves that both automatic lookup routes are refused under test and gate markers.

Every notifier routes through `FM_WEDGE_ALARM_EXEC` in `wedge_alarm_emit`.
The daemon defaults that seam to `discard` when sourced as a library, and test callers otherwise replace the notifier or point the seam at a recorder before exercising an alert.
`tests/wake-helpers.sh` provides the shared recorder for suites that assert channel selection and summary propagation.
Production leaves the seam unset and uses the configured real channels.

`tests/fm-daemon.test.sh` covers directive parsing, rate limiting, timeout and process-group cleanup, argv-safe dispatch, channel fallback, and safe `command:` summary delivery.
`tests/fm-supervisor-watchdog.test.sh` covers the watchdog's aged-wake episode and active-alert call.
[`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) records the bounded manual macOS and Herdr channel proof.
