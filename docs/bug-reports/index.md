---
okf_version: "0.2"
---

# Bug Report

- [Buffered retry leaves acknowledged successors uncommitted](1-buffered-retry-leaves-acknowledged-successors-uncommitted.md) - A single live consumer handles every record successfully after one retry but remains behind the broker log end.
- [Buffered successors execute before a retried record](2-buffered-successors-execute-before-a-retried-record.md) - A serial adapter runs successor handlers before redelivering an earlier failed record.
- [Broker restart ends live adapter consumers](3-broker-restart-ends-adapter-consumers.md) - Two live adapter workers exit after a broker restart, leaving acknowledged records unhandled.
- [Group rebalances end live adapter consumers](4-group-rebalance-ends-live-adapter-consumers.md) - Surviving adapter workers end normally during membership changes, sometimes leaving acknowledged records unhandled.
- [Later retry overwrites an earlier seek barrier](5-later-retry-overwrites-earlier-seek-barrier.md) - Two buffered retries can commit past a record that never succeeded.
- [Group rebalance replays committed offsets out of order](6-rebalance-replays-committed-offsets-out-of-order.md) - A serial consumer handles an already committed lower offset after a higher offset within one assignment.
- [Caught-up consumer finalizes about three records per second](7-caught-up-consumer-finalizes-about-three-records-per-second.md) - Every offset store waits behind an idle poll that holds the consumer lock for about 0.3 seconds.
