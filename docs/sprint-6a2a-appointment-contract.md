# Sprint 6A-2A — review candidate, not deployed

Base: `9e44e79a2ad33174af77377549a2b38f6c2176b9`.
Branch: `sprint-6a2a-appointment-reschedule-cancel`.
Migration: `20261004182242_appointment_reschedule_cancel_v1.sql`.

## Verified starting point

- GitHub main matched the expected SHA; D1-A PR #17 remained separate.
- LIVE had 28 migrations, ending with `20260929061533_job_lifecycle_reviews_v1`.
- The four target function definitions matched the repository baseline after SQL formatting normalization.
- Appointments/workflows had RLS and authenticated SELECT only. No client mutation policies were added.
- LIVE was read only throughout this task. No test rows, DDL, or migrations were sent to LIVE.

## Model and invariants

Keep one appointment row per listing. Add `cancelled` to its status and nullable
`cancelled_at`, `cancelled_by`, `cancel_reason`. These fields record the **last**
cancellation and survive a new proposal; a subsequent cancellation replaces them.
This is minimum audit metadata, not a complete event history.

Both selected parties can propose a different time for a confirmed appointment.
The opposite party must accept. The workflow remains `scheduled` during this
negotiation, but departure requires the latest appointment to be `confirmed`.
Reschedule proposals/acceptance increment workflow revision to invalidate stale
workflow screens. Initial pending proposals retain the previous workflow behavior.

Cancellation is permitted only in `awaiting_appointment` or `scheduled`.
It returns the workflow to `awaiting_appointment`, increments revisions and leaves
`listings.status = chosen` and `chosen_quote` unchanged. Only the customer can
start a fresh proposal after cancellation.

All appointment writes lock listing, workflow and appointment in that order.
The existing workflow RPC also locks the listing first, serializing departure
against appointment changes. Both accounts must be active and unblocked.
The existing parties-only read policies and historical access are preserved.

## RPC contract for the later frontend integration

| RPC | Parameters | Result |
| --- | --- | --- |
| `propose_listing_appointment` | `p_listing_id bigint`, `p_proposed_at timestamptz`, `p_expected_revision bigint` | Updated `listing_appointments` row |
| `accept_listing_appointment` | `p_listing_id bigint`, `p_expected_revision bigint` | Updated appointment row |
| `cancel_listing_appointment` | `p_listing_id bigint`, `p_expected_revision bigint`, `p_cancel_reason text = null` | Updated appointment row |

- Existing RPC signatures are preserved. No caller-supplied user/role is trusted.
- Use revision `0` only when no appointment exists. Otherwise send the exact
  appointment revision currently displayed, including after cancellation.
- Retrying the same mutation uses the **same original revision and payload**.
  An immediate successful retry returns the existing row without a notification
  or revision increment. A retry after an intervening action is stale and rejected.
- Proposal retry also retains the existing future-date validation; an expired
  proposal is not revived by retry.
- `40001`: reload appointment **and workflow** before offering another action.
  `42501`: caller, account, relationship or workflow state disallows the action.
- Reasons are optional, trimmed and limited to 500 characters. Notifications do
  not include them. Render stored reasons as text, never raw HTML.
- Send an offset-bearing ISO timestamp; display in `Europe/Istanbul`.
  The future-date and 90-day limit remain enforced.
- `cancelled` means appointment cancellation only. The frontend must not label
  the job cancelled or offer expert re-selection.
- Refresh workflow revision after each appointment mutation. Hide/disable
  departure while the appointment is pending; the backend independently enforces it.

Notifications: `appointment_reschedule_proposed`, `appointment_cancelled`,
existing `appointment_confirmed`, and existing initial `appointment_proposed`.
Each goes to the other party once per successful mutation.

## Validation evidence

Executed with an isolated PostgreSQL engine (`@electric-sql/pglite` 0.5.8), actual
repository tables/RLS/functions and synthetic auth identities. Minimal Supabase
auth/storage scaffolding was provided locally; hosted Auth/REST was not exercised.
The historical baseline additionally needs the repository's
`GUVENLIK-SERTLESTIRME-v13.sql` helper before the Sprint 2 cleanup migration.
This existing setup dependency was not changed in this sprint.

- `tests/appointment_reschedule_cancel_rollback.sql`: **59/59 PASS**, including
  the requested 24 scenarios. Negative scenarios PASS when the expected rejection
  occurs. Authenticated and anon roles were actually selected in the database.
- Existing `job_lifecycle_rollback.sql`: PASS unchanged.
- Existing `preselection_messaging_rollback.sql`: PASS unchanged.
- Existing `expert_authorization_rollback.sql`: PASS unchanged.
- Payment preference, selected chat, completion and review covered by new suite.
- Migration reapplied in the isolated database: PASS.
- Migration plus test fixtures in a single transaction followed by rollback: PASS.
- Full public catalog before/after migration rollback matched: function bodies,
  ACLs, columns, constraints, relations, RLS flags, policies and triggers.
- Synthetic fixture count after rollback: zero.
- Real simultaneous multi-connection contention/load test: not executed. Lock
  order and serial stale/retry outcomes were reviewed/tested, respectively.

## Safe test/deployment procedure and risks

The SQL test file ends in `ROLLBACK`. Run it on a disposable database containing
the baseline and candidate migration. To test the migration itself reversibly,
place its body and the test body in **one outer transaction**, removing their
inner BEGIN/COMMIT/ROLLBACK wrappers, then ROLLBACK. Do not accidentally retain the
migration's COMMIT in such a rollback run. This was done only in the local engine.

No deployment is authorized by this PR. Before a future deployment, recheck main,
LIVE function/schema drift and notification types. The migration changes CHECK
constraints and acquires DDL locks; lock timeout is 3 seconds and statement timeout
30 seconds. On timeout/error, abort the whole transaction and investigate.

Existing callers cannot modify the tables directly. New frontend controls are
not part of this PR. Coordinate later UI handling of `cancelled`, pending
reschedule and refreshed workflow revisions before exposing the new actions.

Pre-commit transaction rollback is verified. After production commit and new
cancellation data, do not blindly restore the old status constraint/function set:
it cannot represent `cancelled`. Use a reviewed forward fix preserving audit data.

The candidate migration is intentionally absent from LIVE history; this is an
unapplied PR, not a claim of deployed repo/LIVE synchronization.
