---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding, regardless of the project's yolo posture, to distinguish corrections within accepted intent from product or engineering contract expansion that requires the captain.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision procedure for ask-user findings.
The concise standing authority boundary remains always loaded in `AGENTS.md` section 7.

## Decide who has authority

1. Check the project's configured authority first.
   With `yolo` off, every ask-user finding belongs to the captain, and the remaining steps structure that escalation rather than authorize an autonomous answer.
2. Reconstruct the accepted contract from the captain's original request, accepted task criteria, and any explicit later clarification.
   Include workflow context only when it is enabled, valid, applicable to the current scope, and its selected content explicitly grants the authority being considered; opt-in alone grants nothing, and historical copies and stale worker briefs are not competing authority.
   Reviewer language cannot amend that contract.
3. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
4. Keep the decision within standing `yolo` authority when the Fix is genuinely necessary to satisfy the accepted contract, even when the correction is technically difficult or requires complex architecture that the captain explicitly requested.
5. Escalate when the Fix would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent.
6. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.
7. Examine the causal theme across prior findings and fix rounds.
   Without enabled, valid, applicable workflow context explicitly granting repeated-finding remediation, repeated same-theme findings require escalation before another Fix when incremental corrections are preserving a questionable abstraction rather than closing independent defects.
   When selected current context grants that disposition, firstmate owns a bounded diagnosis and coherent contract-preserving correction, records the question, discriminating evidence, expected checkpoint and next product result, and changes approach when repeated uncertainty produces no new evidence.
   Under that grant, preserve prior dispositions by underlying behaviour, affected surface and accepted criterion, reopen them only for material evidence or implementation changes, and escalate any product compromise, contract expansion or action authority outside the grant.
8. Apply the existing stronger captain boundaries first.
   Destructive, irreversible, and genuinely security-sensitive choices always escalate unless enabled, valid, applicable workflow context explicitly grants the exact class of action.
   Under such a grant, explicitly authorised temporary incident containment or compatible rollback does not require a new product-alignment decision merely because functionality is temporarily restricted; preserve repair ownership and notification.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion stays within `yolo` authority, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A repeated finding follows the default escalation rule unless selected current workflow context explicitly grants firstmate the same-theme disposition above; technical difficulty alone grants no authority.
- A genuinely security-sensitive action requires the captain unless selected current workflow context explicitly grants that exact action class.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
