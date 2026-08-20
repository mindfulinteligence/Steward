# Memory Auditor Reliability

## Goal

Prevent a proposed memory from generating unbounded audit writes, and make the
owner, memory, reason, and rate of any future audit failure discoverable from
structured logs without waking the production database for diagnosis.

## Shipped In This Change

- Treat `approve`, `reject`, and `human_review` as settled verdicts even when a
  status transition was interrupted.
- Expose the skip classification as `Acs.Memory.Auditor.audit_skip_reason/1`
  so the invariant is directly regression-tested.
- Include per-cycle audit counts and skip-reason counts in the structured
  `memory_auditor.cycle` event.
- Emit `memory_auditor.audit_error` with `memory_id`, `org`, error count, and
  reason. These fields are explicitly allowlisted by the Axiom log backend.
- Keep string or malformed error counts from crashing the skip guard.
- Add shared Axiom panels for cycle volume, error rate by reason, and repeated
  memory IDs.

## Operating Procedure

1. Query the structured `memory_auditor.audit_error` events by `org` and
   `memory_id`, then compare their rate with `memory_auditor.cycle` counts.
2. If one memory repeats, inspect its current status and auditor flags through
   the application or read-only database tooling. Do not begin with ad-hoc
   writes.
3. Correct the memory through the normal memory transition workflow. Preserve
   the audit event reason and request/incident context.
4. After the writer is quiet, stop all diagnostic queries for at least the
   configured Neon suspend timeout before checking endpoint state once.

## Follow-Up Work

- Alert on repeated audit errors for one memory and on a non-zero audit-error
  rate sustained across multiple cycles.
- Add a periodic invariant report for proposed rows with settled verdicts,
  repeated error counts, or no-progress age.
- Add a bounded audit queue and per-memory backoff/quarantine policy for
  provider outages and future pre-filter failures.
- Record a request or execution ID when an audit revision is created so a
  single incident can be traced across memory commits, logs, and tool calls.

## Verification

- Focused ExUnit coverage must include each settled verdict and malformed flag
  input.
- CI must pass test, release, lint, and tool-smoke jobs before promotion.
- Production verification requires a successful deploy, normal-workflow data
  correction, and a quiet five-minute suspension observation.
