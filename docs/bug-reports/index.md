---
okf_version: "0.2"
---

# Bug Report

- [Buffered retry leaves acknowledged successors uncommitted](1-buffered-retry-leaves-acknowledged-successors-uncommitted.md) - A single live consumer handles every record successfully after one retry but remains behind the broker log end.
- [Buffered successors execute before a retried record](2-buffered-successors-execute-before-a-retried-record.md) - A serial adapter runs successor handlers before redelivering an earlier failed record.
- [Broker restart ends live adapter consumers](3-broker-restart-ends-adapter-consumers.md) - Two live adapter workers exit after a broker restart, leaving acknowledged records unhandled.
- [Group rebalances end live adapter consumers](4-group-rebalance-ends-live-adapter-consumers.md) - Surviving adapter workers end normally during membership changes, sometimes leaving acknowledged records unhandled.
- [Later retry overwrites an earlier seek barrier](5-later-retry-overwrites-earlier-seek-barrier.md) - Two buffered retries can commit past a record that never succeeded.
