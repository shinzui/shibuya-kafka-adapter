---
type: Bug Report
title: Group rebalances end live adapter consumers before their group drains
description: Surviving serial adapter consumers return normally during group membership changes, sometimes leaving acknowledged records unhandled and committed offsets behind.
generated:
  by: process:codex
  at: "2026-09-25T01:46:59Z"
bugId: BUG-4
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya-kafka-adapter
affectedVersion: "0.9.0.1"
environment: Redpanda 26.2.1 in a private Apple Container; macOS aarch64; GHC 9.12.4; released cohort with Hackage shibuya-kafka-adapter 0.9.0.1, shibuya-core 0.9.0.3, kafka-effectful 0.3.1.0, hw-kafka-streamly 0.2.0.0, and hw-kafka-client 5.3.0.
observed: >-
  During a four-step group membership change with steady producer traffic,
  surviving adapter consumers emit "crash-consumer exited before stop: Right ()"
  after assignment and revoke callbacks. A reduced 3,000-record run had three
  unexpected normal exits, handled only 1,695 records, and ended with nonzero
  lag despite 3,000 successful producer delivery callbacks. A second 4,000-record
  run had two unexpected normal exits and eventually reached zero lag, so
  permanent loss is schedule-dependent. Both runs installed kafkaRebalanceHandler.
expected: Surviving adapter consumers should remain active through group joins, graceful departures, member kills, and restarts; they should handle acknowledged records until the group reaches zero lag, or surface a terminal error if they cannot continue.
reproduction:
  - Build the released Kenshou cohort containing the Hackage shibuya-kafka-adapter 0.9.0.1 tarball (SHA-256 1918bae0c591ab47ba45d044a50170e7a340bddb1b562752cd16f556e86314e6).
  - Run `cabal run kenshou -- run kafka/adapter/concurrency/group-rebalance-with-inflight --out runs --set kafka.messages=3000 --set kafka.membership-interval-seconds=1 --set kafka.service-ms=5` from mori://shinzui/keiro-runtime-kenshou. The scenario starts three adapter workers, adds a fourth, stops one gracefully, kills another, and restarts it.
  - Inspect run `01a0d639-dce0-7333-9256-3ee15d0e29c0` and its worker control logs. Three surviving workers end normally before stop, 1,523 acknowledged IDs have no handler fact, and eleven of twelve partitions retain lag after the recovery deadline.
  - Repeat with `--set kafka.messages=4000 --set kafka.membership-interval-seconds=3 --set kafka.service-ms=10`. Run `01a0d63c-dfb0-762c-a9e6-c3f23156afc5` records two early exits while eventually handling all IDs and reaching zero lag.
workaround: Restarting a consumer process can help the group drain, but the first run still failed after one killed member was restarted; no reliable workaround is established.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-25T01:46:59Z"
    document_timestamp: "2026-09-25T01:46:59Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: GPT-6
    effort: medium
    context: Compared two live runs, producer delivery callbacks, per-worker control logs, group offset snapshots, and the released adapter source. The source-level stream termination path remains unknown.
---

# Group rebalances end live adapter consumers

The harness launched one private broker and used prefixed topics and groups for
each run. Every worker installed the caller-provided `kafkaRebalanceHandler` and
logged assignment and revoke callbacks. The worker errors report that
`waitApp` returned normally before the harness sent a stop command. They do
not identify the source-level path that ended the stream.

The two sealed run directories are under
`mori://shinzui/keiro-runtime-kenshou` at
`runs/01a0d639-dce0-7333-9256-3ee15d0e29c0/` and
`runs/01a0d63c-dfb0-762c-a9e6-c3f23156afc5/`. An artifact-level Mori URI
for run directories is pending. The first run also found offset-order
reversals and incomplete processing; the second found duplicate deliveries
beyond the declared membership windows. Those separate safety observations
need isolation and are not assumed to share this exit cause.
