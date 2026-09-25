---
type: Bug Report
title: Broker restart ends live adapter consumers before they drain acknowledged records
description: Two serial adapter consumers exit normally after a private broker is killed and restarted, leaving acknowledged records unhandled and the group behind the log end.
generated:
  by: process:codex
  at: "2026-09-25T01:28:17Z"
bugId: BUG-3
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya-kafka-adapter
affectedVersion: "0.9.0.1"
environment: Redpanda 26.2.1 in a private Apple Container; macOS aarch64; GHC 9.12.4; released cohort with Hackage shibuya-kafka-adapter 0.9.0.1, shibuya-core 0.9.0.3, kafka-effectful 0.3.1.0, hw-kafka-streamly 0.2.0.0, and hw-kafka-client 5.3.0.
observed: >-
  After the broker is killed and restarted, both live adapter workers emit
  "crash-consumer exited before stop: Right ()" and exit without surfacing a
  Kafka fatal error. In two reduced runs, all 1,000 producer records receive
  successful delivery callbacks, but the original workers handle only 374
  and 434 respectively and their group does not reach zero lag within 30
  seconds. A default 20-second-outage run likewise acknowledges 15,000 and
  handles only 401 before both workers exit.
expected: Existing adapter consumers should reconnect without process restart, handle every broker-acknowledged record within the recovery deadline, reach zero group lag, and expose a terminal Kafka error if they cannot continue.
reproduction:
  - Build the released Kenshou cohort containing the Hackage shibuya-kafka-adapter 0.9.0.1 tarball (SHA-256 1918bae0c591ab47ba45d044a50170e7a340bddb1b562752cd16f556e86314e6).
  - Run `cabal run kenshou -- run kafka/adapter/concurrency/broker-outage-and-reconnect --out runs --set kafka.messages=1000 --set kafka.outage-seconds=3 --set kafka.recovery-deadline-seconds=30` from mori://shinzui/keiro-runtime-kenshou. The scenario starts two serial adapter workers and a 500-records-per-second callback producer, kills the private broker after one second, starts it after the requested outage, and waits for recovery.
  - Inspect run `01a0d624-2294-77c0-927d-a952855ed178` (seed 8745063177570223) and run `01a0d62b-dd17-7101-819f-472923759969` (seed 657561724505188). Both record 1,000 successful delivery callbacks, no delivery failures, two unexpected worker exits, and nonzero final lag. The later run's replacement-worker control reaches zero lag and handles all 1,000 IDs across original and replacement workers.
  - The default run `01a0d626-ef89-76cc-9e84-4dcedba62a6d` (seed 4718453199430480) reproduces the two exits after a 20-second outage with 15,000 successful delivery callbacks and 401 original handler facts.
  - The reduced proxy-blackhole control `01a0d626-2a64-713a-b162-03cc64417be8` (seed 3516467579919409) keeps both workers alive and handles all 1,000 acknowledged IDs after the connection is restored.
workaround: Restarting adapter consumer processes after broker recovery drained the backlog in one reduced control run; another reduced control reached zero lag while nine acknowledged IDs still lacked handler facts, so a process restart alone has not been shown to preserve the no-loss contract.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-25T01:28:17Z"
    document_timestamp: "2026-09-25T01:28:17Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: GPT-6
    effort: medium
    context: Compared repeated broker-kill runs, a passing proxy-blackhole control, worker control logs, sealed cohort identities, and the released adapter source. The exact source-level termination path remains to be isolated; no owner fix was tested.
---

# Broker restart ends live adapter consumers

Each run uses its own Redpanda container and prefixed topic and group. The
producer's successful delivery callbacks establish broker acknowledgement;
the worker's durable `ok` messages record handler decisions. The reduced
broker-kill runs under `mori://shinzui/keiro-runtime-kenshou` at
`runs/01a0d624-2294-77c0-927d-a952855ed178/` and
`runs/01a0d62b-dd17-7101-819f-472923759969/` show the same unexpected
normal exit on both workers. An artifact-level Mori URI for run directories
is pending. The default-duration run repeats the result with more traffic.

The adapter source uses `kafkaSource` and `ingestedStream` in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`. The current
evidence establishes the visible process and group behavior, but does not
identify which poll, acknowledgement, or runner path completes the stream.
The passing proxy-blackhole control narrows the trigger to the broker restart
path in this cohort. A separate restart control recovered all IDs in one run;
another recovered the lag but lacked nine handler facts, so no general
recovery workaround is asserted.
