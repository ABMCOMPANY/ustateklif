---
name: tamisim-pr-review
description: Review Tamİşim pull requests for scope, regressions, security, state-machine integrity, responsive/PWA behavior, and release evidence.
---

# Tamİşim PR review

Use this skill for pull-request review or pre-merge verification.

## 1. Confirm scope
- State the PR goal in one sentence.
- Identify any change outside the stated sprint.
- Flag broad refactors, hidden contract changes, or new V1 features.

## 2. Inspect contracts
For backend changes, verify affected tables, RPCs/functions, RLS/policies, grants, notifications, revisions, idempotency, and rollback.
For frontend changes, verify existing action/navigation/auth contracts are preserved unless explicitly changed.

## 3. Security review
Check:
- unauthorized/third-party access
- direct API/RLS bypass
- stale revision/race conditions
- double-submit/idempotency
- user-controlled HTML/XSS
- upload ownership/type/size when relevant
- secrets/service-role exposure
- SECURITY DEFINER + search_path + grant surface

## 4. Product/state review
Trace the affected part of:
customer -> listing -> quote -> selection -> appointment -> job -> price -> payment record -> review/dispute.

Reject transitions that skip required approval or leave frontend/backend states inconsistent.

## 5. Responsive/PWA review
When UI is touched, check phone/tablet/desktop behavior, horizontal overflow, Android back/history, modal/drawer behavior, loading/empty/error states, and PWA navigation.

## 6. Evidence
Require relevant tests and evidence. Prefer targeted tests plus regression around the changed contract.
Physical Android/PWA PASS remains separate when required.

## 7. Verdict
Return one of:
- PASS
- PASS WITH FOLLOW-UP
- BLOCK

List only concrete findings with file/line or contract references when possible. Do not merge or deploy.
