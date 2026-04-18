# Investigate hw-kafka-client-instrumentation integration

Intention: intention_01kpgjfhrfe499b5vtpa043pyx

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

This plan is an **investigation**, not an unconditional integration. The deliverable
is a grounded, go/no-go recommendation on adopting the Hackage package
`hs-opentelemetry-instrumentation-hw-kafka-client` (version `0.1.0.0`, from the
`iand675/hs-opentelemetry` project) inside the `shibuya-kafka-adapter` repository.

The central question is not "can we add a tracing library?" — it is "what does the
**upstream** `hw-kafka-client` wrapper add that Shibuya's own telemetry stack does
not already provide?" That framing matters because the Shibuya framework already
ships OpenTelemetry integration:

- `shibuya-core` exposes `Shibuya.Telemetry` which re-exports
  `Shibuya.Telemetry.Effect`, `Shibuya.Telemetry.Propagation`,
  `Shibuya.Telemetry.Semantic`, and `Shibuya.Telemetry.Config`.
- The `Tracing` static effect in `Shibuya.Telemetry.Effect` offers `withSpan`,
  `withSpan'`, `withExtractedContext`, `runTracing`, and `runTracingNoop`. Its
  `StaticRep` holds an `OTel.Tracer` plus an `enabled` flag so tracing can be
  toggled off at no cost.
- `Shibuya.Telemetry.Propagation` provides `extractTraceContext :: TraceHeaders ->
  Maybe SpanContext` and `injectTraceContext :: Span -> IO TraceHeaders`, both
  using `OpenTelemetry.Propagator.W3CTraceContext` directly — no propagator
  registration required.
- `Shibuya.Telemetry.Semantic` defines `consumerSpanArgs`, `internalSpanArgs`,
  `processMessageSpanName` (`"shibuya.process.message"`), attribute keys
  (`messaging.system`, `messaging.destination.name`,
  `messaging.destination.partition.id`, `messaging.message.id`, plus Shibuya-specific
  `shibuya.processor.id`, `shibuya.inflight.count`, `shibuya.inflight.max`,
  `shibuya.ack.decision`), and helper `NewEvent` builders.
- `shibuya-core/shibuya-core.cabal` already has `build-depends`
  `hs-opentelemetry-api ^>=0.3` and `hs-opentelemetry-propagator-w3c ^>=0.1` —
  **these dependencies are already in this adapter's transitive closure** via
  `shibuya-core`.

The `shibuya-kafka-adapter` library already participates in this stack in one way:
`Shibuya.Adapter.Kafka.Convert.extractTraceHeaders` copies `traceparent` and
`tracestate` out of a `ConsumerRecord`'s headers into `Envelope.traceContext`
(`type TraceHeaders = [(ByteString, ByteString)]`). It does **not** currently open
spans, extract a `SpanContext`, or inject trace state on produce — but the types
and effect are already available upstream.

The upstream package under investigation takes a different shape. Its single
module `OpenTelemetry.Instrumentation.Kafka` offers two **drop-in wrappers**
around raw `hw-kafka-client` calls:

- `produceMessage` — a wrapper around `Kafka.Producer.produceMessage` that opens
  a `SpanKind = Producer` span named `"send <topic>"`, records messaging
  attributes, and calls the global propagator's `inject` to append trace headers
  to the record before forwarding to the underlying produce call.
- `pollMessage` — a wrapper around `Kafka.Consumer.pollMessage` that, on each
  received record, `extract`s context from the record's headers, `attachContext`s
  it to the thread-local context, and opens a no-op `SpanKind = Consumer` span
  named `"process <topic>"`.

Both are **single-message** APIs. The Shibuya Kafka adapter uses the **batch**
call `pollMessageBatch` in `Shibuya.Adapter.Kafka.Internal.kafkaSource`. That gap
and the overlap with Shibuya's own Tracing effect are the two axes this plan
measures.

After working through this plan, a reader knows:

1. Whether the upstream library can be depended on cleanly in this repo's
   GHC 9.12 cabal plan (in principle yes, since its transitive deps are already
   resolved via `shibuya-core`; this milestone verifies it in practice).
2. Whether the upstream wrappers add anything on top of Shibuya's `Tracing`
   effect for the consumer side, given that the runtime around
   `Adapter.source` can already call `withExtractedContext` and `withSpan` on
   every envelope using `Envelope.traceContext`.
3. Whether the producer-side wrapper is useful here. The adapter is
   consumer-only today; the only existing producer call in the repo is the
   test helper `Kafka.TestEnv.produceMessages`, which uses
   `Kafka.Producer.produceMessage`. A future DLQ milestone may introduce
   in-adapter producer use.
4. What, specifically, is missing from the upstream library to instrument
   batch polling, and whether a minimal in-adapter wrapper over
   `pollMessageBatch` built directly on `Shibuya.Telemetry` would be simpler
   than adopting the upstream package.

Observable outcomes at completion:

- A runnable jitsurei example `otel-demo` in
  `shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs` that uses the **real
  adapter** (not raw `hw-kafka-client`) plus Shibuya's `runTracing` and
  `withExtractedContext`. Running it against a local Redpanda + Jaeger
  (both started via `just process-up`) shows `shibuya.process.message`
  spans with the correct `messaging.*` attributes both on stdout (handle
  exporter) and in the Jaeger UI at `http://localhost:16686`. When the
  producer sent a `traceparent`, parent-child linkage is visible in the
  Jaeger trace view.
- A smaller spike `otel-upstream-probe` that calls the **upstream**
  wrappers directly (mirroring
  `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/examples/hw-kafka-client-example/`)
  so the two shapes can be compared side by side.
- A completed gap analysis in Outcomes & Retrospective with a recommendation.
  The three candidate recommendations are:
  - **Adopt** — swap `pollMessageBatch` for the upstream `pollMessage` on the
    adapter hot path; add the upstream library as a direct dep.
  - **Extend in-repo** — keep batch polling; add a thin module
    `Shibuya.Adapter.Kafka.Tracing` built on `Shibuya.Telemetry` that opens a
    consumer-kind span around each record yielded by the batch, without
    depending on the upstream wrapper at all.
  - **Defer** — the existing `Envelope.traceContext` plumbing plus the
    Shibuya runtime's downstream `withSpan` already delivers distributed
    trace continuity; no Kafka-layer span is worth the code or dep weight.


## Progress

- [x] Milestone 1 (2026-04-18): three OTel deps wired into
      `shibuya-kafka-adapter-jitsurei.cabal`
      (`hs-opentelemetry-instrumentation-hw-kafka-client ^>=0.1`,
      `hs-opentelemetry-sdk ^>=0.1`,
      `hs-opentelemetry-exporter-otlp ^>=0.1`); `cabal build all` succeeds;
      `.dev/jaeger-config.yaml`, `process-compose.yaml` `jaeger` service, and
      `just jaeger-ui`/`just jaeger-logs` recipes added; `just process-up`
      brings up Redpanda + Jaeger; `curl http://localhost:16686/` → 200;
      `curl POST http://localhost:4318/v1/traces` → 200. The handle exporter
      was dropped from scope (see Decision Log + Surprises).
- [x] Milestone 2 (2026-04-18): `otel-demo` jitsurei executable lives at
      `shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs`. It drives
      `kafkaAdapter` under `runTracing`, calls `extractTraceContext` on the
      envelope's `traceContext`, and wraps the ack in
      `withExtractedContext` + `withSpan' processMessageSpanName
      consumerSpanArgs`. Produced a record carrying
      `traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01`,
      ran the demo, and confirmed (a) the printed child `traceId` matches
      `0af7651916cd43dd8448eb211c80319c` and (b) Jaeger received a span with
      the correct `CHILD_OF b7ad6b7169203331` reference and
      `messaging.{system,destination.name,destination.partition.id,message.id}`
      tags. Required adding `hs-opentelemetry-api ^>=0.3` as a direct
      build-dep (transitive presence wasn't enough to import
      `OpenTelemetry.Trace.Core` for `getSpanContext`).
- [x] Milestone 3 (2026-04-18): `otel-upstream-probe` lives at
      `shibuya-kafka-adapter-jitsurei/app/OtelUpstreamProbe.hs`. It uses
      `OpenTelemetry.Instrumentation.Kafka.pollMessage` directly on a raw
      `hw-kafka-client` consumer, no Shibuya, no `kafka-effectful`. Run with
      `OTEL_SERVICE_NAME=otel-upstream-probe`; it loops 10 times against
      `orders`, polls one record per iteration, and the upstream wrapper
      opens one `process orders` (kind=Consumer) span per record polled,
      complete with `messaging.{operation,destination.name,kafka.consumer.group,kafka.destination.partition,kafka.message.key,kafka.message.offset}`
      tags. The new record produced with
      `traceparent=00-1c00...abcd-2a00...abcdef-01` shows up in Jaeger
      with the correct CHILD_OF reference.
- [x] Milestone 4 (2026-04-18): `otel-producer-demo` lives at
      `shibuya-kafka-adapter-jitsurei/app/OtelProducerDemo.hs`. Produces
      twice — once via the upstream `produceMessage` wrapper, once via a
      DIY helper composed from `withSpan' Producer` +
      `injectTraceContext` + raw `Kafka.Producer.produceMessage`. Both
      records carried `traceparent` (verified via
      `rpk topic consume orders --num 4`). `otel-demo` was made
      args/env-driven (`cabal run otel-demo -- 4` with
      `OTEL_DEMO_GROUP=...`) so the four records could be re-consumed under
      a fresh group; the resulting Jaeger traces show end-to-end
      producer→consumer linkage:
      trace `6d635cd6...` = `otel-producer-demo:send orders` (Producer)
      with `otel-demo:shibuya.process.message` as `CHILD_OF` it; trace
      `bffdcec4...` = `otel-producer-demo:shibuya.send.message` (Producer,
      DIY) with `otel-demo:shibuya.process.message` as `CHILD_OF` it.
- [ ] Milestone 5: gap analysis and recommendation, written into Outcomes &
      Retrospective below.
- [ ] Milestone 6 (conditional, only if Milestone 5 recommends Adopt or Extend):
      spin out a follow-up ExecPlan `docs/plans/9-<slug>.md`.


## Surprises & Discoveries

### Milestone 1 (2026-04-18)

- **Hackage `hs-opentelemetry-exporter-handle 0.0.1.2` is incompatible with
  `shibuya-core`'s API bound.** `cabal info hs-opentelemetry-exporter-handle`
  reports `Dependencies: ... hs-opentelemetry-api >=0.2 && <0.3`, while
  `shibuya-core.cabal` requires `hs-opentelemetry-api ^>=0.3`. The local source
  tree at
  `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/exporters/handle/package.yaml`
  has been bumped to `^>=0.3` but no Hackage release exists yet.
  Consequence: the handle exporter was dropped from Milestone 1's dependency
  set. Stdout evidence in subsequent milestones is captured by reading
  `Span` IDs out of `withSpan'` callbacks and printing them, plus by querying
  Jaeger's HTTP API. See Decision Log.
- **Jaeger v2 OTLP receivers verified.** `jaeger validate
  --config=file:.dev/jaeger-config.yaml` exits 0 against v2.15.0; after
  `just process-up`, `curl http://localhost:16686/` returns `200` and
  `curl -X POST http://localhost:4318/v1/traces -H 'Content-Type:
  application/json' -d '{}'` returns `200`. No collector-component renames
  were needed.
- **Solver pulled `hs-opentelemetry-otlp-0.2.0.0`, `proto-lens-0.7.1.7`,
  and the full `crypton-*` / `tls-2.4.1` chain as transitive deps of the
  OTLP exporter.** No conflicts with shibuya-core's existing closure; first
  build took roughly two minutes on a cold cache.

### Milestone 2 (2026-04-18)

- **`hs-opentelemetry-api` had to be declared explicitly even though it is
  transitively present.** `OpenTelemetry.Trace.Core` is exported by
  `hs-opentelemetry-api`, not the SDK; importing it for `getSpanContext`
  failed with `GHC-87110: It is a member of the hidden package
  hs-opentelemetry-api-0.3.1.0` until I added the dep. Plan rationale for
  *not* declaring it (avoid bounds clash) is wrong: the SDK pins
  `hs-opentelemetry-api >=0.3 && <0.4`, which matches `shibuya-core`
  exactly, so an explicit `^>=0.3` is safe. Updated the cabal file and the
  plan's Interfaces section accordingly.
- **Default OTel service name was `unknown_service:otel-demo`, not the
  tracer name `shibuya-kafka-adapter-jitsurei`.** The SDK's
  `detectService` falls back to the executable name when
  `OTEL_SERVICE_NAME` / `OTEL_RESOURCE_ATTRIBUTES` are unset; `makeTracer
  provider "name" tracerOptions` only affects `otel.scope.name`, not
  `service.name`. Jaeger queries therefore go through
  `service=unknown_service:otel-demo` (or `OTEL_SERVICE_NAME=...` can be
  exported before running).
- **Verified end-to-end propagation.** Producer header
  `traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01` →
  `Envelope.traceContext` → `extractTraceContext` →
  `withExtractedContext` → child span. Jaeger trace
  `0af7651916cd43dd8448eb211c80319c` has one span:

      operationName: shibuya.process.message
      kind:          consumer
      duration:      142µs
      references:    CHILD_OF 0af7651916cd43dd8448eb211c80319c/b7ad6b7169203331
      tags:          messaging.system=kafka
                     messaging.destination.name=orders
                     messaging.destination.partition.id=0
                     messaging.message.id=orders-0-0
                     otel.scope.name=shibuya-kafka-adapter-jitsurei
                     span.kind=consumer

  This is the **baseline** that Milestones 3 and 4 are compared against.

### Milestone 3 (2026-04-18)

- **Upstream `pollMessage` opens a span only on records that were *not*
  previously polled in the same broker session, but it opens one per
  successful return regardless of consumer-group state.** First run polled
  both records on `orders` (the one from M2 and the one freshly produced
  for M3) and the wrapper opened a span only for the freshly produced
  record. The earlier record had already been committed by `otel-demo`'s
  consumer group, so the upstream-probe's group `otel-upstream-probe`
  re-read it from `Earliest` — and the wrapper *did* span it. Trace
  `0af7...` therefore now contains *both*
  `shibuya.process.message` (from M2) and `process orders` (from M3) as
  siblings under parent `b7ad6b7169203331`. Trace `1c00...abcd` has just
  the upstream `process orders` span. Both confirm that **the upstream
  W3C extractor honours `traceparent` exactly as Shibuya's
  `extractTraceContext` does**.
- **Span shape captured for Milestone 5 comparison.** Upstream span
  `process orders` (kind=Consumer, `otel.scope.name =
  hs-pntlmtry-nstrmnttn-hw-kfk-clnt v0.1.0.0`) carries seven `messaging.*`
  tags vs Milestone 2's four:

  | Attribute                                  | Milestone 2 (Shibuya) | Milestone 3 (upstream) |
  | ------------------------------------------ | --------------------- | ---------------------- |
  | `messaging.system`                         | `kafka` (set by demo) | (absent)               |
  | `messaging.operation`                      | (absent)              | `process`              |
  | `messaging.destination.name`               | `orders`              | `orders`               |
  | `messaging.destination.partition.id`       | `0`                   | (absent)               |
  | `messaging.kafka.destination.partition`    | (absent)              | `0`                    |
  | `messaging.message.id`                     | `orders-0-0`          | (absent)               |
  | `messaging.kafka.message.offset`           | (absent)              | `1`                    |
  | `messaging.kafka.message.key`              | (absent)              | `k2`                   |
  | `messaging.kafka.consumer.group`           | (absent)              | `otel-upstream-probe`  |

  The two stacks pick **different** OTel attribute names for the same
  concept (`destination.partition.id` vs `kafka.destination.partition`).
  Shibuya emits the (now-stable) v1.27 messaging-conventions key; the
  upstream library emits the older Kafka-namespaced key. This is the
  single largest gap to flag in Milestone 5.
- **librdkafka IPv6 fallback noise reappears on every run.** Two
  `Connect to ipv6#[::1]:9092 failed` warnings precede every successful
  poll. Same noise documented in Plan 7's retrospective; the upstream
  probe shows it more clearly because it does not suppress librdkafka
  logs.

### Milestone 4 (2026-04-18)

- **Both producer paths inject `traceparent` correctly; both produce
  spans of kind=Producer.** `rpk topic consume orders --num 4` returns
  the upstream-wrapper record carrying
  `traceparent=00-6d635cd6...c0ccca3546c44686-797d7e20235d6b0c-01`
  and the DIY record carrying
  `traceparent=00-bffdcec479dc281c2aa5cdae0ca83292-adc2786907910ffa-01`,
  both with an empty `tracestate`. Producer span attributes differ
  exactly the way the consumer spans did (M2 vs M3 table above):
  upstream `send orders` has `messaging.operation = send` and
  `messaging.kafka.message.key = upstream-key`; DIY
  `shibuya.send.message` has `messaging.system = kafka` and
  `messaging.destination.name = orders` (whatever the spike author
  passed to `addAttribute`). The DIY path requires the caller to pick a
  span name, set kind=Producer in `SpanArguments`, and add every
  attribute by hand — the upstream wrapper does all three from the
  `ProducerRecord` automatically.
- **End-to-end propagation verified across services.** Jaeger trace
  `6d635cd6bf6ac903c0ccca3546c44686` contains exactly two spans:
  `otel-producer-demo:send orders` (root, Producer) and
  `otel-demo:shibuya.process.message` (Consumer, CHILD_OF the root).
  Trace `bffdcec479dc281c2aa5cdae0ca83292` is the symmetric DIY case:
  `otel-producer-demo:shibuya.send.message` (root, Producer) and
  `otel-demo:shibuya.process.message` (Consumer, CHILD_OF the root).
  This is the strongest single piece of evidence in the investigation —
  it shows that whichever producer-side option is chosen, Shibuya's
  consumer-side `extractTraceContext` already closes the loop.
- **`otel-demo` was extended to read its message count from
  `argv[0]` and its consumer group from `OTEL_DEMO_GROUP`.** Default
  behaviour (consume 1 message under group `otel-demo-group`) is
  preserved. The change made M4's verification ergonomic without
  forking a copy of `otel-demo` for the spike.


## Decision Log

- Decision: Treat this plan as investigation-only. Do not modify the production
  `shibuya-kafka-adapter` library (under `shibuya-kafka-adapter/src/`) in any
  milestone here, other than additive work in a new module if a later milestone
  demands it. A full integration, if recommended, is spun out as a follow-up plan.
  Rationale: The upstream library only exposes single-message wrappers; the
  adapter uses batch polling for throughput. Shibuya's own Tracing effect already
  covers the "span per processed message" case. Committing to a direction before
  running both spikes would be premature. Keeping the adapter untouched also
  keeps the plan reversible — if the recommendation is "defer", nothing in the
  library needs to be rolled back.
  Date: 2026-04-18

- Decision: Do all spike work inside `shibuya-kafka-adapter-jitsurei`. Do not
  modify the test suite to add tracing.
  Rationale: The jitsurei package already carries the relevant build-depends on
  `hw-kafka-client`, `kafka-effectful`, and the adapter itself, and has
  precedent (`FatalErrorDemo.hs`, `BasicConsumer.hs`) for demonstrating real
  broker behavior. Additive executables there are low blast-radius and
  reviewable in isolation. The test suite is the library's acceptance surface;
  adding OTel dependencies to it would confuse unit-level testing with
  observability prototyping.
  Date: 2026-04-18

- Decision: Prefer depending on `hs-opentelemetry-*` packages directly from
  Hackage; only add a `source-repository-package` pin if the cabal solver fails
  to find a plan against GHC 9.12.
  Rationale: `hs-opentelemetry-instrumentation-hw-kafka-client` is on Hackage at
  `0.1.0.0`, and `shibuya-core` already pulls in `hs-opentelemetry-api ^>=0.3`
  and `hs-opentelemetry-propagator-w3c ^>=0.1` from Hackage with no git pins —
  verified by reading `shibuya-core.cabal`. The solver should therefore already
  have most deps in hand. Verified availability by running `cabal info
  hs-opentelemetry-instrumentation-hw-kafka-client hs-opentelemetry-api
  hs-opentelemetry-sdk hs-opentelemetry-propagator-w3c
  hs-opentelemetry-semantic-conventions` on 2026-04-18.
  Date: 2026-04-18

- Decision: Export spans primarily over OTLP to a local Jaeger instance;
  keep the handle exporter wired in parallel as a stdout dump for pasting
  evidence into Surprises & Discoveries.
  Rationale: The Jaeger binary `jaeger` (v2.15.0) is already on `PATH` (verified
  via `which jaeger`; version via `jaeger --version`). Jaeger v2 is an
  OpenTelemetry Collector distribution with native OTLP receivers on ports
  4317 (gRPC) and 4318 (HTTP) and a UI on port 16686. Visual verification of
  parent-child trace linkage in the Jaeger UI is much more convincing than
  comparing JSON `traceId` strings by eye, and since the binary is local, the
  infrastructure cost is zero. The handle exporter stays useful for
  reviewers who want to audit span attributes without running a Jaeger.
  Date: 2026-04-18

- Decision: Milestone 2 tests the **real adapter** wired through Shibuya's
  `runTracing`, while Milestone 3 tests the **upstream wrappers** directly. The
  comparison is what feeds the gap analysis in Milestone 5.
  Rationale: The most probable outcome of this investigation is "we don't need
  the upstream library because Shibuya already covers our case." Proving that
  requires actually running Shibuya's stack over the adapter's output, not just
  re-enacting the upstream example.
  Date: 2026-04-18

- Decision: Milestone 1 ships **without** `hs-opentelemetry-exporter-handle`.
  Rationale: Hackage's only published version (0.0.1.2) bounds
  `hs-opentelemetry-api <0.3`, while `shibuya-core` requires `^>=0.3`, so the
  solver cannot accept it. The local source tree has the bound bumped but
  there is no corresponding Hackage release. Pinning a fork via
  `source-repository-package` for what amounts to "stdout JSON printer"
  imposes an outsized maintenance burden on this investigation. Instead the
  spike milestones will surface span/trace IDs by reading
  `OTel.getSpanContext` inside `withSpan'` callbacks and by hitting the
  Jaeger HTTP API (`http://localhost:16686/api/traces?service=...`), both of
  which give equivalent textual evidence to paste into Surprises &
  Discoveries. If a Hackage release of the handle exporter compatible with
  `hs-opentelemetry-api ^>=0.3` lands later, this decision is trivially
  reversible.
  Date: 2026-04-18


## Outcomes & Retrospective

(To be filled during and after implementation. At completion this must answer:
is the upstream library usable as-is here? what does it uniquely offer over
`Shibuya.Telemetry`? what is the recommended path forward in terms of concrete
follow-up work, if any?)


## Context and Orientation

This section describes the repository, the upstream library, and the Shibuya
telemetry stack in enough detail that the rest of the plan is self-contained. A
novice reading only this file and the working tree can orient themselves.

### What `shibuya-kafka-adapter` is

`shibuya-kafka-adapter` is one adapter for the Shibuya queue-processing
framework. Its single public function `kafkaAdapter :: KafkaAdapterConfig -> Eff
es (Adapter es (Maybe ByteString))` in module `Shibuya.Adapter.Kafka` at
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` returns an `Adapter` whose
`source` is a `Stream (Eff es) (Ingested es (Maybe ByteString))`. The Shibuya
runtime consumes that stream; this repo does not run the runtime itself in the
library path — the jitsurei examples do, directly.

The adapter sits on three upstream libraries:

- `hw-kafka-client` — the low-level binding over librdkafka. Ships the
  single-message `Kafka.Consumer.pollMessage`, the batch
  `Kafka.Consumer.pollMessageBatch`, and the single-message
  `Kafka.Producer.produceMessage`.
- `kafka-effectful` (at `/Users/shinzui/Keikaku/bokuno/kafka-effectful`) — the
  effectful wrapper. Defines a dynamic effect `KafkaConsumer` in
  `Kafka/Effectful/Consumer/Effect.hs` whose constructors include
  `PollMessage`, `PollMessageBatch`, `StoreOffsetMessage`, `PausePartitions`,
  etc. The interpreter `Kafka/Effectful/Consumer/Interpreter.hs` calls directly
  into `Kafka.Consumer` from `hw-kafka-client`. The adapter never calls
  `hw-kafka-client` directly; it calls through the effect.
- `hw-kafka-streamly` — provides
  `skipNonFatal :: Stream (Eff es) (Either KafkaError a) -> Stream (Eff es)
  (Either KafkaError a)` which drops poll timeouts and partition-EOF errors.
  The adapter uses it in `kafkaSource`.

### The adapter's consumer loop

Read `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs` before
starting work. The loop in short:

    kafkaSource config =
        skipNonFatal $
            Stream.repeatM pollBatch
                & Stream.concatMap Stream.fromList
      where
        pollBatch =
            pollMessageBatch config.pollTimeout config.batchSize

In each iteration the adapter calls `pollMessageBatch`, which returns
`[Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString))]`,
then flattens the list into the stream. There is **no single-message poll**
in production code. Per-record processing happens downstream, in
`ingestedStream` (which throws on the first `Left` that survives `skipNonFatal`)
and in the handler passed to `Stream.fold` by the caller (see
`shibuya-kafka-adapter-jitsurei/app/BasicConsumer.hs`).

### The Shibuya telemetry stack

`shibuya-core` ships a complete OpenTelemetry-integrated telemetry story. The
relevant paths are all under
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src/`:

- `Shibuya/Telemetry.hs` — umbrella module re-exporting `.Effect`,
  `.Propagation`, `.Semantic`, and `.Config`.
- `Shibuya/Telemetry/Effect.hs` — the `Tracing` static effect. Exports include
  `runTracing :: Tracer -> Eff (Tracing : es) a -> Eff es a`,
  `runTracingNoop` (no-op runner, zero overhead),
  `withSpan :: Text -> SpanArguments -> Eff es a -> Eff es a`,
  `withSpan' :: Text -> SpanArguments -> (Span -> Eff es a) -> Eff es a`,
  `withExtractedContext :: Maybe SpanContext -> Eff es a -> Eff es a` (used to
  link child spans to an upstream trace), and span-modification helpers
  `addAttribute`, `addAttributes`, `addEvent`, `recordException`, `setStatus`.
- `Shibuya/Telemetry/Propagation.hs` — pure helpers over W3C trace context.
  `extractTraceContext :: TraceHeaders -> Maybe SpanContext` and
  `injectTraceContext :: Span -> IO TraceHeaders` both use
  `OpenTelemetry.Propagator.W3CTraceContext` directly; there is no dependency
  on the global propagator registry.
- `Shibuya/Telemetry/Semantic.hs` — span-name and attribute-key constants
  following OTel messaging semantic conventions, plus `consumerSpanArgs ::
  SpanArguments` (kind `Consumer`) and `internalSpanArgs`.

Crucially, `shibuya-core.cabal` already lists
`hs-opentelemetry-api ^>=0.3` and `hs-opentelemetry-propagator-w3c ^>=0.1` as
build-depends. Since `shibuya-kafka-adapter` depends on `shibuya-core`, those
libraries are already in the cabal plan — the cost of adding the upstream
instrumentation package or the SDK is incremental, not foundational.

### The upstream library under investigation

The dependency is at `hs-opentelemetry-instrumentation-hw-kafka-client 0.1.0.0`
on Hackage. Its source lives on disk at
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/instrumentation/hw-kafka-client`.
Its single exported module is `OpenTelemetry.Instrumentation.Kafka`. Key points
from its source at
`instrumentation/hw-kafka-client/src/OpenTelemetry/Instrumentation/Kafka.hs`:

- Both wrappers live in `MonadUnliftIO m => m`. The `effectful` stack satisfies
  this when `IOE` is in scope (effectful-core provides a `MonadUnliftIO`
  instance for `Eff es` under an `IOE` constraint). No dedicated "effectful"
  binding exists upstream.
- The producer wrapper creates span `"send <topic>"` with kind `Producer`,
  records `messaging.operation = "send"`, `messaging.destination.name`, and
  conditionally `messaging.kafka.destination.partition` (only on
  `SpecifiedPartition`) and `messaging.kafka.message.key` (only when UTF-8
  decodable). It then calls `inject` from `OpenTelemetry.Propagator` to get
  propagation headers (for W3C, `traceparent` and optionally `tracestate`),
  **appends** them to `prHeaders`, and forwards to
  `Kafka.Producer.produceMessage`.
- The consumer wrapper takes an extra `ConsumerProperties` argument, used
  **only** to read `group.id` via `M.lookup "group.id" (cpProps props)`. This
  is a documented workaround because `hw-kafka-client` does not expose a way
  to read the group id from an already-constructed `KafkaConsumer`. After
  polling one record it uses `extract` to decode trace context, `attachContext`
  to install it thread-locally, and opens a `SpanKind = Consumer` span
  `"process <topic>"` whose body is `pure record`. The span represents
  **arrival**, not handler execution.
- The cabal dependency set is:
  `base`, `containers`, `text`, `bytestring`, `hs-opentelemetry-api`,
  `hs-opentelemetry-semantic-conventions`, `hw-kafka-client`, `unliftio-core`,
  `case-insensitive`, `http-types`. Notably it does **not** depend on the SDK
  or on a specific propagator — the consumer configures the SDK separately, for
  example by calling `OpenTelemetry.Trace.initializeGlobalTracerProvider` from
  `hs-opentelemetry-sdk`.

A user-facing guide is readable on disk at
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/docs/OpenTelemetry-hw-kafka-client-Instrumentation-Guide.md`.
It documents three limitations relevant here:

- "Only the single-message APIs are wrapped." `produceMessageBatch` and
  `pollMessageBatch` are **not** instrumented.
- "Consumer group lookup is a workaround." Requires `groupId ...` in the
  passed-in `ConsumerProperties`.
- "Consumer spans close around a no-op." The span wraps receipt, not handling.

### What already exists in the adapter

`Shibuya.Adapter.Kafka.Convert.extractTraceHeaders :: Headers -> Maybe
TraceHeaders` pulls `traceparent` and `tracestate` off Kafka headers and stores
them on `Envelope.traceContext` (`type TraceHeaders = [(ByteString,
ByteString)]` from `shibuya-core`'s `Shibuya.Core.Types`). Downstream, a
Shibuya runtime can feed that into `Shibuya.Telemetry.Propagation.extractTraceContext`
to obtain a `Maybe SpanContext` and wrap the handler in `withExtractedContext`
+ `withSpan`. Nothing in the current adapter opens spans or reads a tracer.

### What the `mori.dhall` history tells us

Commit 8786853 (2026-04-18) removed `iand675/hs-opentelemetry` from this
repo's `mori.dhall` `dependencies` list with the rationale "No cabal file in
this repository references hs-opentelemetry." That was correct at the time;
adopting the upstream library here would reverse it. Keep this context in
mind when writing any new commits: the mori declaration should be
re-added if and only if a cabal file in this repo adds a direct
`hs-opentelemetry-*` build-depends.


## Plan of Work

Five independent milestones, executed in order. Each milestone leaves the
repository in a working, testable state. Any milestone may decide to terminate
the investigation with a "no" recommendation (recorded in Outcomes &
Retrospective) without invalidating earlier milestones' work.

### Milestone 1 — Prove the dependencies build against GHC 9.12, and wire Jaeger

**Scope.** Add four new dependencies to
`shibuya-kafka-adapter-jitsurei` **only**:
`hs-opentelemetry-instrumentation-hw-kafka-client ^>=0.1`,
`hs-opentelemetry-sdk ^>=0.1`,
`hs-opentelemetry-exporter-otlp ^>=0.1`, and
`hs-opentelemetry-exporter-handle ^>=0.1`. Do not import them yet; just prove
they cabal-solve and compile.

Also in this milestone, add a `jaeger` service to `process-compose.yaml` and a
minimal Jaeger v2 config file at `.dev/jaeger-config.yaml` (git-ignored
location for runtime artifacts, consistent with `.dev/process-compose.sock`),
plus a `just jaeger-up` / `just jaeger-ui` recipe pair. Confirm `curl -s
http://localhost:16686` returns the UI's landing HTML.

The jitsurei package already transitively has `hs-opentelemetry-api` via
`shibuya-core`, so **do not** add it explicitly — that would be redundant and
could create bounds conflicts.

**Rationale.** Local blast radius: library and test suite untouched. If the
solver fails, the plan terminates with "defer" (or with a decision recorded to
use `source-repository-package` pins).

**What will exist at the end.** A committed change to
`shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal` adding
the four new build-depends lines; a committed `.dev/jaeger-config.yaml`, a
`jaeger` process in `process-compose.yaml`, and `jaeger-up`/`jaeger-ui`
recipes in `Justfile`. `cabal build all` succeeds.

**Acceptance.** `cabal build all` prints no errors. `cabal build --dry-run
all 2>&1 | grep hs-opentelemetry` mentions at least the four new libraries
and `hs-opentelemetry-api` (pulled transitively). `just process-up` in one
shell now starts both Redpanda and Jaeger; `curl -s -o /dev/null -w "%{http_code}"
http://localhost:16686/` prints `200`; `curl -s -o /dev/null -w "%{http_code}"
http://localhost:4318/v1/traces -X POST -H 'Content-Type: application/json'
-d '{}'` prints a 2xx or 4xx (not connection-refused).

### Milestone 2 — Adapter + Shibuya Tracing consumer spike

**Scope.** Add a new executable `otel-demo` at
`shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs`. This demo uses the **real
adapter** (`kafkaAdapter`, `Adapter.source`) and drives it under Shibuya's
`runTracing`. Concretely it:

1. Initializes an OTel `TracerProvider` using
   `hs-opentelemetry-sdk`'s `initializeGlobalTracerProvider`. The SDK reads
   `OTEL_EXPORTER_OTLP_ENDPOINT` (default
   `http://localhost:4318` via the HTTP exporter, or `http://localhost:4317`
   for gRPC — confirm which one `hs-opentelemetry-exporter-otlp` uses at the
   time of spike; 0.1.x defaults to gRPC on 4317). Also install
   `hs-opentelemetry-exporter-handle` as a secondary span processor so the
   same spans are echoed to stdout for easy paste-into-plan evidence.
2. Obtains a `Tracer` via `makeTracer provider "shibuya-kafka-adapter-jitsurei"
   tracerOptions`.
3. Runs
   `runTracing tracer . runEff . runError @KafkaError . runKafkaConsumer
   props sub $ do ... kafkaAdapter defaultConfig ...`.
4. In the consumer fold, for each `Ingested { envelope }`, calls
   `Shibuya.Telemetry.Propagation.extractTraceContext envelope.traceContext`,
   then `Shibuya.Telemetry.Effect.withExtractedContext` and
   `Shibuya.Telemetry.Effect.withSpan processMessageSpanName consumerSpanArgs`
   to wrap the ack + print. Adds attributes for
   `messaging.destination.name`, `messaging.destination.partition.id`, and
   `messaging.message.id` using the constants in
   `Shibuya.Telemetry.Semantic`.
5. Calls `shutdownTracerProvider` on exit.

**Rationale.** This demo represents the "do nothing new, use what Shibuya
already gives us" baseline. Whatever `otel-demo` prints defines the starting
point for comparison; any additional span, attribute, or header the upstream
wrapper would emit is the **marginal** value being measured.

**What will exist at the end.** `OtelDemo.hs`, an `executable otel-demo`
stanza in the cabal file, and a committed transcript of its output in
Surprises & Discoveries.

**Acceptance.** Run sequence, from the repo root:

    just process-up          # shell 1, leave running (starts Redpanda and Jaeger)
    just create-topics       # shell 2
    rpk topic produce orders --key k1 -H 'traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' <<< 'hello-otel'
    cabal run otel-demo      # shell 2

Expected two independent confirmations:

1. Stdout (handle exporter): `otel-demo` prints one
   `shibuya.process.message` span with `kind = Consumer`, attributes
   including `messaging.destination.name = orders`, and a `traceId` of
   `0af7651916cd43dd8448eb211c80319c` (from the producer header).
2. Jaeger UI (`just jaeger-ui`, then browse
   `http://localhost:16686/search?service=shibuya-kafka-adapter-jitsurei`):
   one trace appears with trace id `0af7651916cd43dd8448eb211c80319c`. The
   trace view shows the `shibuya.process.message` span as a child of the
   span id `b7ad6b7169203331` (which is dangling because no producer
   reported it — acceptable; the parent-span linkage is what matters).

### Milestone 3 — Upstream-wrapper-only probe

**Scope.** Add a second executable `otel-upstream-probe` at
`shibuya-kafka-adapter-jitsurei/app/OtelUpstreamProbe.hs`. This one does
**not** use the adapter, `kafka-effectful`, or Shibuya's `Tracing` effect. It
uses raw `Kafka.Consumer` plus
`OpenTelemetry.Instrumentation.Kafka.pollMessage`, exactly in the shape of
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/examples/hw-kafka-client-example/app/consumer/Main.hs`.
It initializes the tracer provider with the handle exporter, opens a consumer
with `groupId (ConsumerGroupId "otel-upstream-probe")`, calls `pollMessage
cp consumer (Timeout 1000)` in a loop of ten iterations, and prints both
results and spans.

**Rationale.** Establishes a side-by-side comparison point. The same message
produced in Milestone 2's acceptance step should flow through `otel-demo` and
`otel-upstream-probe` to stdout. Differences — span names, attribute keys,
kind, parent linkage — are the upstream library's unique contribution.

**What will exist at the end.** `OtelUpstreamProbe.hs`, its cabal stanza,
and a captured transcript in Surprises & Discoveries showing the upstream
span shape next to Milestone 2's.

**Acceptance.** With Redpanda and Jaeger up (`just process-up`), produce a
message as in Milestone 2, then run `cabal run otel-upstream-probe`. The
program prints a span `process orders` of kind `Consumer` with attributes
`messaging.operation = process`, `messaging.destination.name = orders`,
`messaging.kafka.consumer.group = otel-upstream-probe`, and carrying the
same `traceId` from the producer's `traceparent`. In Jaeger UI
(`http://localhost:16686`) a trace with that id shows the upstream-style
span; filter by service name `haskell-consumer` or whatever the upstream
example's tracer name resolves to (from
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/examples/hw-kafka-client-example/app/consumer/Main.hs`:
`makeTracer tracerProvider "haskell-consumer"`).

### Milestone 4 — Producer-side spike

**Scope.** Add one more executable `otel-producer-demo` at
`shibuya-kafka-adapter-jitsurei/app/OtelProducerDemo.hs`. Produce a message to
topic `orders` twice, side by side:

1. Using the **upstream**
   `OpenTelemetry.Instrumentation.Kafka.produceMessage` wrapper, under
   `initializeGlobalTracerProvider`. Verify the span named `send orders`
   appears and that the produced record carries a `traceparent` header.
2. Using a **DIY helper** composed from `Shibuya.Telemetry.Effect.withSpan'`
   plus `Shibuya.Telemetry.Propagation.injectTraceContext` plus a raw
   `Kafka.Producer.produceMessage` call. Verify the same.

**Rationale.** The upstream producer wrapper is one of the two halves of what
`hw-kafka-client-instrumentation` provides; the DIY alternative uses
Shibuya's existing telemetry primitives only. Milestone 5 compares their
code size, ergonomics, attribute parity, and interaction with `effectful`
to recommend a direction.

**What will exist at the end.** `OtelProducerDemo.hs`, its cabal stanza, and
both produced messages in Redpanda with `traceparent` headers.

**Acceptance.** Running

    rpk topic consume orders -f '%h\n%v\n' --num 2

prints two records, each with a header line containing `traceparent`. Running
`cabal run otel-demo` in another shell (Milestone 2's consumer) consumes both
and emits two `shibuya.process.message` spans whose `traceId`s match the two
producer spans. Additionally, in Jaeger UI two complete traces are visible,
each containing a `send orders` (Producer) span and a
`shibuya.process.message` (Consumer) span linked as parent and child. A
screenshot or a text description of what the Jaeger trace tree looks like
goes into Surprises & Discoveries.

### Milestone 5 — Gap analysis and recommendation

**Scope.** Fill in Outcomes & Retrospective. Answer each of the following
questions with evidence from Milestones 2–4:

1. On the consumer side, does the upstream wrapper add anything the Shibuya
   `Tracing` effect doesn't already provide, given that the adapter already
   plumbs `traceparent`/`tracestate` into `Envelope.traceContext`? Compare
   Milestone 2's span (Shibuya-only, `shibuya.process.message`) with
   Milestone 3's span (upstream, `process orders`) on attribute coverage,
   span kind, timing, and effort.
2. Does the upstream library expose an API sufficient to instrument
   `pollMessageBatch`? (Confirmed: it does not in `0.1.0.0`.) Would making
   the adapter call `pollMessage` instead of `pollMessageBatch` be acceptable
   given the hot-path implications (refer to
   `shibuya-kafka-adapter-bench/baseline.csv` — which measures conversion,
   not polling — and note that `pollMessageBatch` batches syscalls and
   minimises the streamly `repeatM` overhead)?
3. Is there a minimal in-adapter alternative built on `Shibuya.Telemetry` that
   would work over the batch path? Sketch, in prose, a new module
   `Shibuya.Adapter.Kafka.Tracing` exposing a `traced :: Tracing :> es =>
   Stream (Eff es) (Ingested es v) -> Stream (Eff es) (Ingested es v)` that
   wraps each emitted `Ingested` in `withExtractedContext` +
   `withSpan consumerSpanArgs`. Evaluate whether this is simpler, looser,
   or tighter than adopting the upstream package.
4. On the producer side, compare the upstream wrapper to Milestone 4's DIY
   helper. Does the upstream version's line-count and attribute-set win
   justify a direct dependency for what is today exactly one test-helper
   call site (`Kafka.TestEnv.produceMessages`) plus hypothetical future DLQ
   work?
5. What is the consumer-group-id workaround's impact here? (Expected: every
   adapter caller today already passes `groupId ...` — see
   `shibuya-kafka-adapter-jitsurei/app/BasicConsumer.hs` line 45 — so the
   workaround is free.)

Conclude with a one-paragraph recommendation choosing **Adopt**, **Extend
in-repo**, or **Defer**, and cite the evidence from the above questions.

**Acceptance.** Outcomes & Retrospective is non-empty, answers all five
questions, and delivers the recommendation.

### Milestone 6 — (conditional) spin out follow-up plan

If Milestone 5 recommends **Adopt** or **Extend in-repo**, invoke the
`/exec-plan create` skill with a prompt describing the chosen direction. Its
output becomes `docs/plans/9-<slug>.md`. Record the filename in Outcomes &
Retrospective. Do not perform library changes in the current plan.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/` unless
noted. When output proves acceptance, an expected excerpt is shown. Every
commit must include the `ExecPlan:` and `Intention:` trailers (see top of this
file) and must be preceded by `nix fmt` (project rule in `CLAUDE.md`).

### Milestone 1 steps

1. Open
   `shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`. Under
   `common common-deps` (where `shibuya-core`, `hw-kafka-client`, etc. already
   live), append:

        , hs-opentelemetry-instrumentation-hw-kafka-client ^>=0.1
        , hs-opentelemetry-sdk                             ^>=0.1
        , hs-opentelemetry-exporter-otlp                   ^>=0.1
        , hs-opentelemetry-exporter-handle                 ^>=0.1

   Do **not** add `hs-opentelemetry-api` explicitly; it is already pulled in
   transitively via `shibuya-core` and an explicit bound here could clash.

2. Run `cabal build all`. Expected: a plan is produced and all packages
   compile. If the solver fails, inspect the message. Typical remediations,
   in order of preference:
   - Narrow the bounds above (for example `^>=0.1.0` instead of `^>=0.1`) if
     a newer Hackage version introduces incompatibility.
   - Add `hs-opentelemetry-api: <something-compatible-with-shibuya-core>`
     allow-newer in `cabal.project`, if needed.
   - As a last resort, add a `source-repository-package` stanza pinning
     `iand675/hs-opentelemetry` to a known-good commit from
     `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/` —
     `git -C /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry
     rev-parse HEAD` gives the hash. Record the fallback in the Decision Log.

3. Create `.dev/jaeger-config.yaml`. The Jaeger v2 binary is an OpenTelemetry
   Collector distribution: it accepts OTLP on 4317/4318, stores traces
   in-process via its `memstore` backend, and exposes the classic Jaeger UI on
   16686. Minimal config:

        service:
          extensions: [jaeger_storage, jaeger_query]
          pipelines:
            traces:
              receivers: [otlp]
              processors: [batch]
              exporters: [jaeger_storage_exporter]

        extensions:
          jaeger_query:
            storage:
              traces: memstore
          jaeger_storage:
            backends:
              memstore:
                memory:
                  max_traces: 100000

        receivers:
          otlp:
            protocols:
              grpc:
                endpoint: 0.0.0.0:4317
              http:
                endpoint: 0.0.0.0:4318

        processors:
          batch: {}

        exporters:
          jaeger_storage_exporter:
            trace_storage: memstore

   If `jaeger validate --config=file:.dev/jaeger-config.yaml` reports a
   component rename or signature drift for your installed version
   (`jaeger --version` reports `v2.15.0` at the time of writing), adjust the
   keys accordingly — Jaeger v2 follows upstream collector component naming.

4. Add a `jaeger` process to `process-compose.yaml` alongside `redpanda`:

        jaeger:
          command: jaeger --config=file:.dev/jaeger-config.yaml
          readiness_probe:
            http_get:
              host: 127.0.0.1
              port: 16686
              path: /
            initial_delay_seconds: 2
            period_seconds: 2
            timeout_seconds: 2
            failure_threshold: 15
          availability:
            restart: on_failure

5. Add Justfile recipes to the `services` group:

        # Open the Jaeger UI in the default browser
        [group("services")]
        jaeger-ui:
            open http://localhost:16686

        # Tail jaeger logs (process-compose combined stream)
        [group("services")]
        jaeger-logs:
            process-compose --unix-socket .dev/process-compose.sock process logs jaeger -f

   `just process-up` already starts every process in the compose file, so no
   dedicated `jaeger-up` is needed; document this in the recipe comments.

6. Verify end-to-end: `just process-up` in shell 1, then in shell 2:

        curl -s -o /dev/null -w "%{http_code}\n" http://localhost:16686/
        # expect: 200

7. Run `nix fmt`. Commit the change. The `.dev/` directory is already a
   runtime artifacts directory — confirm `.gitignore` excludes generated
   files there but **does not** exclude `.dev/jaeger-config.yaml` (which is
   a committed config, not a runtime artifact). Add a git-tracked placeholder
   or adjust `.gitignore` as needed.

8. Update Progress: check off Milestone 1 with a timestamp.

### Milestone 2 steps

1. Create `shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs`. Reference
   `BasicConsumer.hs` for the `runKafkaConsumer` + `kafkaAdapter` scaffolding.
   The new imports are:

        import OpenTelemetry.Trace
          ( initializeGlobalTracerProvider
          , makeTracer
          , shutdownTracerProvider
          , tracerOptions
          )
        import Shibuya.Telemetry.Effect
          ( runTracing, withSpan, withSpan', withExtractedContext
          , addAttribute
          )
        import Shibuya.Telemetry.Propagation (extractTraceContext)
        import Shibuya.Telemetry.Semantic
          ( processMessageSpanName, consumerSpanArgs
          , attrMessagingDestinationName
          , attrMessagingDestinationPartitionId
          , attrMessagingMessageId
          )

   The program structure:

        main :: IO ()
        main = do
          bracket initializeGlobalTracerProvider shutdownTracerProvider $ \provider -> do
            let tracer = makeTracer provider "shibuya-kafka-adapter-jitsurei" tracerOptions
            result <- runEff . runError @KafkaError . runTracing tracer $ do
              let props = ...        -- same shape as BasicConsumer.hs
                  sub   = ...
              runKafkaConsumer props sub $ do
                Adapter{source} <- kafkaAdapter (defaultConfig [TopicName "orders"])
                Stream.fold Fold.drain $
                  Stream.mapM (handle) $
                    Stream.take 3 source
            case result of
              Left err -> putStrLn ("error: " <> show err)
              Right () -> putStrLn "otel-demo done"
          where
            handle (Ingested{envelope = env@Envelope{messageId, partition, traceContext}, ack = AckHandle finalize}) = do
              let parentCtx = traceContext >>= extractTraceContext
              withExtractedContext parentCtx $
                withSpan' processMessageSpanName consumerSpanArgs $ \sp -> do
                  case messageId of
                    MessageId txt -> addAttribute sp attrMessagingMessageId txt
                  addAttribute sp attrMessagingDestinationName ("orders" :: Text)
                  mapM_ (addAttribute sp attrMessagingDestinationPartitionId) partition
                  liftIO $ print env
                  finalize AckOk

   (The above is illustrative: compile errors are expected on first pass;
   iterate until it compiles. The important parts are the three library
   calls — `runTracing`, `extractTraceContext`, `withExtractedContext` +
   `withSpan'`.)

2. Add the cabal stanza:

        executable otel-demo
          import:         warnings, common-deps
          hs-source-dirs: app
          main-is:        OtelDemo.hs
          ghc-options:    -threaded -rtsopts -with-rtsopts=-N

3. Ensure Redpanda is up (`just process-up` in another shell) and topics
   created (`just create-topics`). Produce a message with an explicit
   `traceparent` so parent-child linkage can be verified:

        rpk topic produce orders --key k1 \
          -H 'traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' \
          <<< 'hello-otel'

4. Run `cabal run otel-demo`. Expected transcript excerpt:

        Envelope{messageId = MessageId "orders-0-0", ...}
        {"name":"shibuya.process.message","kind":"Consumer",
         "traceId":"0af7651916cd43dd8448eb211c80319c",
         "spanId":"<new>",
         "parentSpanId":"b7ad6b7169203331",
         "attributes":{"messaging.destination.name":"orders",
                       "messaging.message.id":"orders-0-0", ...}}

5. Paste the first `shibuya.process.message` span line into Surprises &
   Discoveries verbatim.

6. `nix fmt`; commit; update Progress.

### Milestone 3 steps

1. Create `shibuya-kafka-adapter-jitsurei/app/OtelUpstreamProbe.hs`. Model
   after
   `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/examples/hw-kafka-client-example/app/consumer/Main.hs`.
   Outline:

        module Main where

        import           Control.Exception (bracket)
        import qualified Kafka.Consumer as KC
        import           OpenTelemetry.Instrumentation.Kafka (pollMessage)
        import           OpenTelemetry.Trace
                          ( initializeGlobalTracerProvider
                          , shutdownTracerProvider
                          )

        main :: IO ()
        main = do
          bracket initializeGlobalTracerProvider shutdownTracerProvider $ \_ -> do
            let cp  = KC.brokersList [KC.BrokerAddress "localhost:9092"]
                    <> KC.groupId   (KC.ConsumerGroupId "otel-upstream-probe")
                sub = KC.topics     [KC.TopicName "orders"]
                    <> KC.offsetReset KC.Earliest
            bracket (KC.newConsumer cp sub) closeIt (loop cp 10)
          where
            closeIt (Left _)  = pure (Just ())
            closeIt (Right c) = (() <$) <$> KC.closeConsumer c
            loop _  _ (Left err) = putStrLn $ "error: " <> show err
            loop _  0 _          = pure ()
            loop cp n (Right consumer) = do
              res <- pollMessage cp consumer (KC.Timeout 1000)
              print res
              loop cp (n - 1) (Right consumer)

2. Add the cabal stanza analogous to `otel-demo`.

3. Produce a fresh message as in Milestone 2 (with the same `traceparent`),
   then run `cabal run otel-upstream-probe`. Expected transcript excerpt:

        {"name":"process orders","kind":"Consumer",
         "traceId":"0af7651916cd43dd8448eb211c80319c",
         "attributes":{"messaging.operation":"process",
                       "messaging.destination.name":"orders",
                       "messaging.kafka.consumer.group":"otel-upstream-probe",
                       "messaging.kafka.message.offset":0,
                       "messaging.kafka.destination.partition":0, ...}}

4. Paste the first `process orders` span into Surprises & Discoveries next to
   Milestone 2's output. The visible difference between the two blocks is
   Milestone 5's raw material.

5. `nix fmt`; commit; update Progress.

### Milestone 4 steps

1. Create `shibuya-kafka-adapter-jitsurei/app/OtelProducerDemo.hs`. Two
   branches in `main`: `upstream` and `diy`. The upstream branch:

        import OpenTelemetry.Instrumentation.Kafka (produceMessage)
        ...
        let rec = ProducerRecord{prTopic = TopicName "orders", ...
                                 prHeaders = mempty, ...}
        produceMessage producer rec

   The DIY branch uses `withSpan'` plus `injectTraceContext`:

        import qualified Kafka.Producer as KP
        import Shibuya.Telemetry.Effect (withSpan')
        import Shibuya.Telemetry.Propagation (injectTraceContext)
        import Shibuya.Telemetry.Semantic (consumerSpanArgs) -- or a producerSpanArgs
          -- helper if added; consumerSpanArgs has kind Consumer, so for a
          -- real producer span we set kind = Producer explicitly.
        ...
        withSpan' "send orders" (defaultSpanArguments{kind = Producer}) $ \sp -> do
          hdrs <- liftIO (injectTraceContext sp)
          let rec = ProducerRecord{prTopic = TopicName "orders", ...,
                                   prHeaders = headersFromList hdrs}
          liftIO (KP.produceMessage producer rec) >>= ...

2. Add the cabal stanza.

3. Run `cabal run otel-producer-demo`. Then:

        rpk topic consume orders -f '%h\n%v\n' --num 2

   Expected: each of the two records carries a `traceparent` header.

4. In another shell, run `cabal run otel-demo` and confirm both messages are
   consumed as child spans of the two producer traces. Record the trace ids
   for the four spans (two producer, two consumer) into Surprises &
   Discoveries as evidence of end-to-end propagation.

5. `nix fmt`; commit; update Progress.

### Milestone 5 steps

1. Open this ExecPlan file. Fill in Outcomes & Retrospective per the scope
   description in the Plan of Work above. Include verbatim excerpts from the
   handle-exporter output captured in Milestones 2–4 as evidence.

2. Add a prose sketch of the hypothetical `Shibuya.Adapter.Kafka.Tracing`
   module described in Question 3 of Milestone 5. Do not implement it; just
   describe types and function signatures.

3. Commit the plan update. Commit message summary: "Plan 8 Milestone 5:
   gap analysis and recommendation".

### Milestone 6 steps (conditional)

If the recommendation is Adopt or Extend in-repo, invoke
`/exec-plan create <summary>` to produce `docs/plans/9-<slug>.md`. Record the
filename in Outcomes & Retrospective.


## Validation and Acceptance

At any milestone's completion, the following must hold:

- `cabal build all` exits 0.
- `nix fmt` has been run, and `git diff --check` is clean.
- `cabal test shibuya-kafka-adapter` still passes (requires Redpanda; run
  `just process-up` first). This plan must not regress the existing test suite.
- Each committed change carries both the `ExecPlan:` and `Intention:` git
  trailers.

Plan-wide acceptance is:

- Jitsurei executables `otel-demo`, `otel-upstream-probe`,
  `otel-producer-demo` exist and produce the spans described in each
  milestone's acceptance section.
- Outcomes & Retrospective answers the five gap-analysis questions in
  Milestone 5 and delivers a one-paragraph recommendation.


## Idempotence and Recovery

Every step in this plan is reversible:

- Milestone 1's cabal edit is reversed by removing the three added lines.
- Milestones 2–4 add new files and new `executable` stanzas. Reverting
  commits removes them.
- Milestone 5 only edits this plan file; reverting restores the prior text.

If `cabal build all` fails in Milestone 1 due to solver conflicts, do not
globally bump bounds on other Hackage packages. First narrow the new bounds
to the exact majors installed. If that fails, fall back to a
`source-repository-package` stanza in `cabal.project` and record the chosen
commit hash in the Decision Log.

Redpanda side effects (topic creation, stored offsets) are reversible via
`just delete-topics` and by choosing fresh `groupId` values for each demo.
Every executable's `groupId` is unique by design for this reason.

Jaeger state is ephemeral: the memstore backend holds traces in RAM only, so
a simple `just process-down` followed by `just process-up` clears all spans.
No disk migration or cleanup is ever needed. If a spike run accidentally
records spans at an exporter endpoint other than Jaeger, the remediation is
to unset `OTEL_EXPORTER_OTLP_ENDPOINT` or re-launch the jitsurei executable
with the correct value.


## Interfaces and Dependencies

The upstream module `OpenTelemetry.Instrumentation.Kafka` exposes exactly two
functions whose signatures the plan relies on. They are reproduced here so the
plan remains self-contained:

    produceMessage
      :: (MonadUnliftIO m, HasCallStack)
      => KafkaProducer
      -> ProducerRecord
      -> m (Maybe KafkaError)

    pollMessage
      :: (MonadUnliftIO m, HasCallStack)
      => ConsumerProperties
      -> KafkaConsumer
      -> Timeout
      -> m (Either KafkaError
                   (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))

Note: `KafkaConsumer` here is `Kafka.Consumer.KafkaConsumer` from
`hw-kafka-client`, **not** the dynamic effect
`Kafka.Effectful.Consumer.Effect.KafkaConsumer` used by the adapter. The names
collide. The upstream-probe spike (Milestone 3) uses the raw type; the
adapter-driven spike (Milestone 2) never touches it.

The Shibuya telemetry surface used by the plan is:

    runTracing          :: IOE :> es => Tracer -> Eff (Tracing : es) a -> Eff es a
    withSpan            :: (Tracing :> es, IOE :> es) => Text -> SpanArguments -> Eff es a -> Eff es a
    withSpan'           :: (Tracing :> es, IOE :> es) => Text -> SpanArguments -> (Span -> Eff es a) -> Eff es a
    withExtractedContext:: (Tracing :> es, IOE :> es) => Maybe SpanContext -> Eff es a -> Eff es a
    addAttribute        :: (Tracing :> es, IOE :> es, ToAttribute a) => Span -> Text -> a -> Eff es ()
    extractTraceContext :: TraceHeaders -> Maybe SpanContext
    injectTraceContext  :: Span -> IO TraceHeaders
    consumerSpanArgs    :: SpanArguments   -- kind = Consumer, empty attrs
    processMessageSpanName :: Text          -- "shibuya.process.message"

Supporting Hackage packages added in Milestone 1:

- `hs-opentelemetry-sdk` — `initializeGlobalTracerProvider`,
  `shutdownTracerProvider`, `makeTracer`, `tracerOptions`,
  `createTracerProvider`. Pulls in a default W3C propagator and a default
  sampler. For deterministic exporter wiring the spike uses
  `createTracerProvider` + `SimpleProcessor` explicitly rather than relying
  on SDK auto-configuration.
- `hs-opentelemetry-exporter-otlp` — primary exporter. Ships span over OTLP
  (gRPC on port 4317 by default; HTTP on 4318 is also supported) to the
  Jaeger v2 binary running via process-compose.
- `hs-opentelemetry-exporter-handle` — secondary exporter. Writes JSON
  lines to stdout; useful for pasting span records into Surprises &
  Discoveries.
- `hs-opentelemetry-instrumentation-hw-kafka-client` — the upstream library
  under investigation. Used only in Milestone 3's `otel-upstream-probe` and
  in Milestone 4's upstream branch.

External runtime dependency: the `jaeger` binary (Jaeger v2.15.0) on `PATH`.
It is an OpenTelemetry Collector distribution; its config lives at
`.dev/jaeger-config.yaml` and is driven by process-compose (Milestone 1 adds
the service). Nothing in the plan installs Jaeger — the assumption is the
user's dev environment provides it (verified on 2026-04-18: `which jaeger`
returned `/Users/shinzui/.local/bin/jaeger`).

`hs-opentelemetry-api` and `hs-opentelemetry-propagator-w3c` are already in
the cabal plan via `shibuya-core` — do not add direct bounds on them from
this repo.

No changes to the public API of `shibuya-kafka-adapter` are contemplated in
this plan. If Milestone 5 recommends "Extend in-repo", the follow-up plan
(Milestone 6) will design a new module such as
`Shibuya.Adapter.Kafka.Tracing` and the types that belong in it.
