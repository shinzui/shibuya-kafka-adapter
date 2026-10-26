---
type: Friction Entry
title: "Producer cleanup outlives the live fixture timeout when broker metadata stalls"
description: "An unavailable broker leaves producer cleanup in native code beyond the test timeout, requiring a process watchdog and bounded message expiration."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-26T19:57:32Z"
frictionId: FRIC-2
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shibuya-kafka-adapter"
affects: "mori://haskell-works/hw-kafka-client"
plan: "docs/plans/17-skip-superseded-buffered-deliveries-so-successors-cannot-run-before-a-retried-record.md"
workaround: "New live scenarios use a five-second producer message expiration; broker-unavailable verification is additionally bounded by an external process watchdog."
---
# Producer cleanup outlives the live fixture timeout when broker metadata stalls

## Attempted

Run the bounded live buffered-retry regression with System.Timeout.timeout 60000000.

## Encountered

Producer API-version negotiation repeatedly reset and native cleanup did not finish on timeout or SIGTERM; the owned test process required SIGKILL.

```text
127.0.0.1:9092/bootstrap: Disconnected: connection reset by peer (after 10002ms in state APIVERSION_QUERY)
```

## Workaround

New live scenarios use a five-second producer message expiration; broker-unavailable verification is additionally bounded by an external process watchdog.
