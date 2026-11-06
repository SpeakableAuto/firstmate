# Changes

## 7 November 2026: bound crew-state reads in the watcher's stale scan

PR: pending (this branch, fm/watcher-scan-bound).
The watcher's stale scan reads each parked or held crew's current state, and that read runs Git in the crew's task folder; on a slow or hung drive it blocked with no limit and the monitoring heartbeat went stale.
Each read now has a 10-second limit and each poll cycle a 120-second shared budget (`FM_CREW_STATE_READ_SECS`, `FM_CREW_STATE_CYCLE_BUDGET_SECS`).
A read that hits the limit is recorded as unknown: nothing is absorbed, paused or escalated on it, the crew is judged again next cycle, and firstmate gets one notice per recheck window.
The heartbeat is still written only at the top of each cycle, so a watcher stuck anywhere else still shows as stale.
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
