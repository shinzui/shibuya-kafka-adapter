---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Wake the source on record arrival instead of polling on a timer](1-wake-the-source-on-record-arrival.md) - Once hw-kafka-client exposes librdkafka's queue event notification, the adapter should wait on that notification while its queue is empty instead of checking the queue every 10 ms, removing the idle wake-ups and the added latency that the timer costs.

