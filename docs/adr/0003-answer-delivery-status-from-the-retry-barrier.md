# 0003: Answer delivery status from the retry barrier

- Status: Accepted
- Date: 2026-10-26

## Context

The source gate retains replayed successors but cannot recall records already in
the runner's inbox. Their callbacks are offset-fenced, yet their handlers could
run before a retry resolves. The core admission contract is recorded in
`mori://shinzui/shibuya`, at
`docs/adr/0013-let-adapters-supersede-a-delivery-before-its-handler-runs.md`;
artifact-level ADR URIs are pending for that filesystem corpus.

## Decision

Register a delivery attempt once and share it between its finalizer and its
`deliveryStatus` action. Read the acknowledgement ledger without the consumer
lock. A delivery is current only if its assignment generation and token are
accepted and either no retry barrier exists, its offset precedes the barrier,
or it is a newer attempt at the barrier offset. Original retry attempts and
successors above a pending barrier are superseded. The token floor survives
successful replay and missing-offset recovery, fencing old buffered deliveries.

The serial single-message runner finalizes a retry before it checks the next
buffered delivery, so the retry supersedes every original successor. After that
retry succeeds, the source gate releases fresh successors and their handlers run
in partition order. This requires the feature-bearing core 0.12.0.0 candidate.

## Consequences

There is no exactly-once guarantee across failures or restarts. Members of one
batch are already admitted together; a retry cannot undo successors in that
same batch, while later superseded batches are skipped. Concurrent processing
is unsupported and can admit successors before a preceding retry is recorded.
With the rebalance helper installed, attempts already revoked at the check are
skipped, but a subsequent revocation cannot cancel an admitted handler.
Missing retry offsets follow ADR 0002's explicit abandonment policy.

The admission action is a prompt, nonthrowing ledger read and allocates no
consumer lock. No new metric or tracing event name is added. Direct consumers
of internal constructors retain their existing signatures.

## Evidence

[Plan 17](../plans/17-skip-superseded-buffered-deliveries-so-successors-cannot-run-before-a-retried-record.md)
records synchronized one/two-retry order assertions, the forced-current negative
control, status tests and benchmark results. The scripted tests run the real
adapter and runner; live ordering, durable committed offset and restart
acceptance are separate tests in `IntegrationTest.hs`. They pass on the generated
project-private Redpanda broker at `127.0.0.1:29092`, including the exact handler
exception trace. Ten consecutive full-suite runs pass all 74 tests.
