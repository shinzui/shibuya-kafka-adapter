# 0001: Fence acknowledgements by delivery and assignment

- Status: Accepted
- Date: 2026-09-20

## Context

Kafka stores only the highest acknowledged offset for a partition. A single
overwriteable seek barrier therefore cannot distinguish the callback that
requested a retry from a later replay, and it can lose an earlier recovery
obligation when buffered callbacks complete out of order. A callback may also
outlive partition ownership during a group rebalance. Finally, parking an
exhausted acknowledgement error for a future source poll is insufficient after
ingestion has ended.

This decision implements
`mori://shinzui/shibuya/plans/40-prevent-kafka-acknowledgements-from-skipping-unresolved-deliveries`
under
`mori://shinzui/shibuya/masterplans/6-comprehensive-lifecycle-remediation-and-release-assurance`.

## Decision

The adapter assigns every delivered record a process-local monotonic token and
captures the partition's assignment generation. Per-partition state preserves
the earliest unresolved offset and the token that requested its retry. A
callback above that boundary cannot store an offset, and the original callback
cannot resolve its own retry; only a newer delivery token at the boundary can
clear it. Successful finalization becomes idempotent per delivery, while failed
or cancelled finalization remains retryable.

`kafkaRebalanceHandler` advances the assignment generation across revoke and
assign events. When callers install that optional callback and share its state
with `kafkaAdapterWith`, callbacks from an old generation cannot store, seek, or
pause the new assignment.

An acknowledgement operation that exhausts its bounded retry budget throws a
synchronous typed exception from the finalizer. The diagnostic fatal slot is
retained, but is no longer the sole propagation route.

The adapter remains serial-only. It continues to have no DLQ producer;
`AckDeadLetter` deliberately warns and stores the offset.

## Consequences

- Later buffered callbacks cannot replace or cross an earlier retry obligation.
- Reassignment fencing is available only when the documented callback is
  installed before consumer creation.
- A delivery token and a small per-handle lock are allocated for each record.
- Tokens and generations are process-local; Kafka's committed offset remains
  the durable recovery boundary across restart.
- Terminal acknowledgement failures reach Shibuya's lifecycle result even when
  no future source poll occurs.

## Evidence

The deterministic state-machine tests are in
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/AckHandleTest.hs`. Live broker
retry, restart, shutdown, synthetic-revocation, and actual group-reassignment
tests are in
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs`.
