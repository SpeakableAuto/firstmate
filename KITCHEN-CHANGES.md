# Changes

## 7 November 2026: a stalled machine drive refuses placement within seconds

PR: https://github.com/SpeakableAuto/firstmate/pull/64
Placement checks the machine drive (mounted, writable, its required folders, free space, the worktree pool root) before a crew starts, and those reads had no time limit; when the drive stalled, the check waited for an hour and a half and nothing could start.
Every drive and data-volume read in placement now runs in a separate short-lived process with a 10-second limit (`FM_PLACEMENT_DRIVE_SECS`); on the limit it is stopped and placement refuses with the existing "required machine drive unavailable" reason, so starting a crew and choosing where it runs both move on.
A reader that cannot be stopped, as can happen with a drive stuck in the operating system, is left behind rather than waited on.
When a home has a worktree slot cap, spawn also counts and, at the cap, clears the pool's old slots on the drive before placement; both now have the same 10-second limit (`FM_WORKTREE_SLOTS_READ_SECS`) and refuse naming the drive.
Within one start attempt the first check that hits the limit marks the attempt, so the later checks refuse at once: a stalled drive costs one start about 11 seconds, with or without a slot cap, and the next attempt checks the drive afresh.
Restarting a crew whose task folder is on the machine drive now checks that folder first under the same limit, so a stalled drive refuses the restart before anything reads the folder or stops the old crew.
Watch for repeated drive-unavailable refusals: they mean the drive is stalled, which this does not fix, and each start attempt still spends up to 10 seconds finding that out.
A reader stuck in the operating system can outlive its check; this does not clear it.
A slot clear stopped by the limit can leave that slot marked as being deleted in the pool's record (Treehouse 2.1.1 marks it before deleting), with the copy itself still intact; the slot count keeps it as held and clearing skips it until Treehouse drops the mark.
Deployed: no; no operating home was changed.

## 7 November 2026: bound crew-state reads in the watcher's stale scan

PR: https://github.com/SpeakableAuto/firstmate/pull/63
The watcher's stale scan reads each parked or held crew's current state, and that read runs Git in the crew's task folder; on a slow or hung drive it blocked with no limit and the monitoring heartbeat went stale.
Each read now has a 10-second limit, and after 120 seconds into a cycle no new read starts except the cycle's first, which always runs so every cycle checks at least one crew (`FM_CREW_STATE_READ_SECS`, `FM_CREW_STATE_CYCLE_BUDGET_SECS`); this limits when reads start, not how long the whole scan takes.
A crew whose read timed out is not read again for 5 minutes (`FM_CREW_STATE_RETRY_SECS`), and while a cycle runs out of read time, crews already tried wait until every crew has had a turn, so healthy crews behind slow ones are always reached. A reader stuck on the drive, including any inner bounded call it makes, keeps an ownership record that is written before that call can run (on hosts left with only the plain bash timeout, which cannot do that, the watcher reports those crews as unknown instead of reading them), so reads cannot pile up behind it; the watcher's reads also skip the optional PR lookup on the forge.
A read that hits the limit, or could not run at all, is recorded as unknown: nothing is absorbed, paused, surfaced as finished or escalated on it, no wedge timer is reset, and firstmate gets one notice listing every such crew per recheck window.
During a long scan the heartbeat moves only when a window or check finishes (`FM_WATCHER_PROGRESS_BEAT_SECS`), so a watcher stuck on one operation still shows as stale.
Watch for repeated crew-state notices: they mean a task folder's drive is slow, which this does not fix.
Deployed: no; no operating home was changed.

## 5 November 2026: bound progress-audit reads

PR: pending no-mistakes publication.
A stalled audit evidence read returns an incomplete result within a fixed budget so the watcher can continue checking the fleet.
Confirmed partial evidence and previous task/storage signatures survive, and unknown reads cannot initiate recovery.
Timeout cleanup targets only newly created audit command groups, while unresolved audit ownership prevents duplicate probes.
Watch for incomplete ownership records that need reconciliation and remember that this does not repair unavailable task storage.
Deployed: no; no operating home was changed.

## 30 October 2026: alert on cleared work left unmerged

PR: https://github.com/SpeakableAuto/firstmate/pull/45
An optional registered home check alerts firstmate after a current-head CLEAR review has waited more than two hours.
It excludes declared or inferred carve-outs, configured owner exclusions and captain holds, and points to the guarded merge command without merging anything.
A declaration of no carve-outs cannot override body, path or added-code evidence; unavailable or changed-head diffs refuse an alert.
Malformed registry rows report an error while healthy repositories remain eligible.
Repeated polls suppress the same PR and head alert.
Watch for incomplete forge reads and missing push timestamps: diagnostics are explicit, and the fallback clock may delay an alert after unrelated PR activity.
Deployed: no; no operating home was armed.

## 30 October 2026: refuse unrequested research findings caps

PR: https://github.com/SpeakableAuto/firstmate/pull/44; targets zac-runtime after https://github.com/SpeakableAuto/firstmate/pull/43 merged.
The optional brief check now refuses capped research, study, audit, inventory and review tasks with a fix naming complete coverage and the deliverable page.
An explicit cap request in captain intent permits only the same subject and no more than the requested count; a claim in the implementation specification cannot supply that authority.
Only imperative fix, repair or resolve instructions for capped defects in captain intent are exempt; research about bugs or errors is checked; required preamble declarations and the specification cannot disable the depth check.
A cap request explicitly withdrawn or overridden in the same or next sentence no longer authorizes a limit; ordinary "not" or "instead" wording keeps it.
Uncapped briefs, PR-body checks and absent/off homes retain their existing behavior.
Watch for conservative text matching: this is a scaffold-time check, not enforcement of every later manual edit or finished report.
Deployed: no; no operating home was changed.

## 30 October 2026: optional brief and PR evidence check

PR: https://github.com/SpeakableAuto/firstmate/pull/43
Incomplete task briefs and GitHub PR bodies can now be refused with a specific fix before scaffolding or readiness registration.
The check covers the goal, recorded commands and exit codes, missing live-proof disclosure, carve-out classification and the staff Update link.
It is off unless a home enables it, so existing homes keep their current behavior.
Watch for conservative path/text matches: record a specific false-positive explanation for independent review when a match is documentation or local test data.
The follow-up restores broad checkout, keys and tokens matching in prose while keeping added-code matching specific, so ordinary Git checkout and dictionary operations do not create carve-out flags.
Card references, including credit-card and debit-card prose and paths, now also require payments classification; bare card variables in added code remain unflagged.
A passing shape check is not proof of deployment or release approval, and required-check wiring is deferred.
Deployed: no; no operating home was changed.
