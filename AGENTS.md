# Tamİşim repository instructions

## Product boundary
- V1 is the Mersin pilot. Do not add nice-to-have features unless they are explicitly accepted into V1.
- Protect the core chain: customer -> listing -> quote -> selection -> appointment -> job -> price -> payment record -> review/dispute.
- Treat 33 categories / ~330 services as catalog architecture, not a reason to bloat `index.html`.

## Change discipline
- Keep each sprint small enough to finish analysis -> implementation -> tests -> report in one work session.
- One sprint should solve one major result/risk. Do not silently expand scope.
- Do not do opportunistic framework rewrites or broad refactors while fixing a focused issue.
- Preserve existing public contracts unless the task explicitly changes them.

## Git and LIVE safety
- Never push directly to `main`.
- Use branch -> changes -> tests -> PR -> review -> merge.
- Never apply ad-hoc SQL to LIVE Supabase.
- Schema/RPC/RLS changes must be migration-backed and need rollback/regression coverage.
- Do not merge a PR or deploy to LIVE unless explicitly requested.

## Backend / security
- Authorization must be enforced server/database-side; never trust frontend gating alone.
- For critical mutations check authorization, state, stale revision/concurrency, idempotency, duplicate notification risk, and rollback.
- Keep RLS enabled on user data. Review SECURITY DEFINER functions, grants, search_path, and direct bypass paths.
- Payment work must not enable real charges before webhook signature, idempotency, ledger, refund, and reconciliation are ready.

## Frontend / PWA
- Mobile-first does not mean mobile-only. Critical screens must remain usable on phone, tablet, laptop, and desktop.
- Preserve Android back/history, PWA navigation, auth state, loading/empty/error states, and existing customer/expert flows.
- A Playwright pass does not replace physical Android/PWA verification when the task requires it.

## Done means evidence
- Do not call a task done because code exists.
- Report: branch, commit, PR, changed files/contracts, test results, known risks, rollback, and any required physical PASS.
- Reuse existing passing regression evidence where valid; do not rerun unrelated large suites without reason.

## PR review
- When reviewing a PR, use the `tamisim-pr-review` repo skill if available.
