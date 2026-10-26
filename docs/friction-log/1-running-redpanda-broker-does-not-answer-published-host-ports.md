---
type: Friction Entry
title: "Running Redpanda broker does not answer published host ports"
description: "The shared container reports running and answers internal metadata while host-side Kafka requests time out, preventing live acceptance."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-26T19:45:36Z"
frictionId: FRIC-1
status: logged
impact: blocked
kind: environment
origin: "mori://shinzui/shibuya-kafka-adapter"
affects: "https://github.com/apple/container"
plan: "docs/plans/16-hold-replayed-successors-so-a-buffered-retry-cannot-stall-partition-commits.md"
---
# Running Redpanda broker does not answer published host ports

## Attempted

rpk cluster info -X brokers=127.0.0.1:9092; redpanda-up

## Encountered

Kafka host metadata times out despite redpanda-up reporting the broker already running; container exec redpanda-0 rpk cluster info succeeds.

```text
unable to request metadata: read tcp 127.0.0.1:65014->127.0.0.1:9092: i/o timeout
```
