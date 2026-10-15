---
name: tamisim-playwright
description: Run focused Tamİşim browser regression and responsive checks with Playwright without replacing required physical Android/PWA verification.
---

# Tamİşim Playwright skill

Use this skill when implementing or reviewing Tamİşim UI, navigation, PWA, or browser-facing flows.

## Scope rule
- Test the changed contract first; do not automatically run every historical flow.
- Preserve existing customer/expert/auth/history behavior unless the sprint explicitly changes it.
- Playwright PASS is automation evidence, not a replacement for required physical Android/PWA PASS.

## Standard responsive matrix
Run the affected critical screen at:
- 390x844 phone
- 768x1024 tablet
- 1366x768 laptop
- 1920x1080 desktop

For D1-D4 critical UI, verify:
- no horizontal overflow
- primary CTA is visible and not clipped
- desktop is not a narrow mobile column
- mobile bottom navigation remains usable
- desktop navigation appears only at the intended breakpoint
- loading/empty/error/modal states do not break layout when relevant

## Navigation checks
When navigation is affected:
- verify browser Back/Forward
- verify modal/drawer closing behavior
- verify login -> target screen -> back path
- do not claim Android hardware-back PASS from desktop Playwright alone

## Evidence
On failure capture screenshot and trace.
For visual acceptance, produce viewport screenshots.
Report:
1. branch/commit
2. command
3. viewport/project
4. PASS/FAIL
5. exact failing assertion
6. screenshot/trace path
7. remaining physical test

## Safety
- Do not mutate LIVE Supabase just to satisfy an E2E test.
- Do not use production destructive data.
- Do not merge or deploy automatically.
