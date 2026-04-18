# Add `Shibuya.Adapter.Kafka.Tracing` for in-repo span instrumentation

Intention: intention_01kpgjfhrfe499b5vtpa043pyx

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

`shibuya-kafka-adapter` already plumbs W3C `traceparent`/`tracestate`
into every `Envelope.traceContext` through
`Shibuya.Adapter.Kafka.Convert.extractTraceHeaders`, but no part of the
adapter actually opens an OpenTelemetry span around the messages it
yields. Today every caller that wants tracing must write the same
~25-line `withExtractedContext` + `withSpan' processMessageSpanName
consumerSpanArgs` + `addAttribute` stanza by hand around their own
handler. The jitsurei executable
`shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs` (added in
`docs/plans/8-investigate-hw-kafka-client-instrumentation.md`
Milestone 2) is the canonical example of that boilerplate.

This plan eliminates the boilerplate by adding a new opt-in module
`Shibuya.Adapter.Kafka.Tracing` to the public surface of
`shibuya-kafka-adapter`. The module exposes a single stream
transformer `traced` that wraps each emitted `Ingested` in a
Consumer-kind span derived from the envelope's
`traceContext`. A caller that wants tracing writes:

    Adapter{source} <- kafkaAdapter cfg
    Stream.fold drainHandler (traced (Stream.mapM userHandler source))

instead of the per-record block in `OtelDemo.hs`. A caller that does
not want tracing writes the existing line and pays nothing — the new
module is additive and reachable only via direct import.

Scope is deliberately small. This plan does **not** add a producer
helper (the adapter has no in-library producer call sites today; the
follow-up DLQ plan can add one when it lands), does **not** change the
adapter's public type or batch-poll behaviour, and does **not** depend
on `hs-opentelemetry-instrumentation-hw-kafka-client`. Plan 8's
gap-analysis section ("Question 1" and "Question 3" in its Outcomes &
Retrospective) is the basis for those scoping decisions; readers who
want the why should read it before this one.

After this plan completes a reader can:

- Run `cabal test shibuya-kafka-adapter` and see a new test that
  proves `traced` opens exactly one span per envelope, that the span
  is `CHILD_OF` the envelope's incoming `traceparent` when present,
  that the span is a root span when absent, and that the span carries
  `messaging.{system,destination.name,destination.partition.id,message.id}`
  populated from the envelope.
- Run a refactored `cabal run otel-demo` and see the same Jaeger
  output as before Plan 8 Milestone 2 closed (same span name, same
  attributes, same parent linkage), but with the demo's handler now
  reduced to a one-liner that `traced` wraps. The reader confirms by
  diffing `OtelDemo.hs` against its Plan 8 Milestone 2 form.
- Read the new module
  `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs` and
  understand its single exported function in under five minutes.

Observable, end-to-end behaviour is identical to what Plan 8 Milestone
2 already proved. The win is in caller code size and the elimination
of a foot-gun: every adapter caller now gets correct attribute keys
and correct span shape automatically, instead of having to remember
both.


## Progress

- [x] Milestone 1 (2026-04-18): Add the dependency edge — make
      `shibuya-kafka-adapter` build-depend on `hs-opentelemetry-api`
      directly (transitive presence via `shibuya-core` is real but
      cabal does not let us import from a transitively-present
      package, as Plan 8 Milestone 2 confirmed). Verify
      `cabal build all` is clean.
- [x] Milestone 2 (2026-04-18): Create
      `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs`
      with the `traced` stream transformer. Add it to the cabal
      `exposed-modules`. Write a unit test
      `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`
      that exercises the four cases above using
      `Shibuya.Telemetry.Effect.runTracing` plus an in-memory exporter,
      or — if no in-memory exporter is available — using
      `OTel.getSpanContext` inside the wrapped handler to assert the
      span shape. Add the test to the test suite's `other-modules`.
      Run `cabal test shibuya-kafka-adapter`; expect all tests
      including the four new ones to pass.
- [ ] Milestone 3: Refactor
      `shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs` to use
      `traced`. Confirm by re-running the Plan 8 Milestone 2
      verification recipe (produce one record with a known
      `traceparent`, run the demo, query Jaeger) that the output is
      identical — same span name, same kind, same attributes, same
      `CHILD_OF` reference. Document the diff in Surprises &
      Discoveries.
- [ ] Milestone 4: Document the new module in `README.md` and in the
      cabal description, if appropriate. Update the changelog if the
      project keeps one. Bump `shibuya-kafka-adapter`'s version per
      semver — this is an additive change that should be a minor
      bump.
- [ ] Milestone 5: Outcomes & Retrospective.


## Surprises & Discoveries

(None yet. Plan 8's Surprises section called out attribute-namespace
divergence between Shibuya's v1.27 messaging conventions and the
upstream Kafka-namespaced keys. This plan **must** stick to the v1.27
keys defined in `Shibuya.Telemetry.Semantic` — any Surprise observed
during implementation that suggests otherwise needs to be flagged
explicitly.)


## Decision Log

- Decision: New module lives in `shibuya-kafka-adapter` proper, not in
  a separate package. Rationale: every adapter caller already
  transitively depends on `shibuya-core` (which ships
  `Shibuya.Telemetry`), so there is no closure to widen. Splitting
  into a `shibuya-kafka-adapter-tracing` package would only add cabal
  ceremony.
  Date: 2026-04-18

- Decision: Opt-in via direct import; no change to the `Adapter` type
  or to `kafkaAdapter`'s signature. Rationale: Plan 8's recommendation
  was explicit that tracing should be additive and reversible. A
  caller who never imports `Shibuya.Adapter.Kafka.Tracing` pays
  nothing — no extra closure, no extra span overhead. The
  `Tracing :> es` constraint on `traced` ensures only callers that
  have a tracer in scope can use it.
  Date: 2026-04-18

- Decision: Use the v1.27 messaging-conventions attribute keys
  (`messaging.message.id`, `messaging.destination.partition.id`)
  exclusively, taken from `Shibuya.Telemetry.Semantic`. Do **not**
  also emit the Kafka-namespaced keys
  (`messaging.kafka.message.offset`,
  `messaging.kafka.destination.partition`) for "interop" with the
  upstream library. Rationale: Plan 8 Milestone 5's gap analysis flags
  attribute-namespace divergence as a real downstream interop hazard;
  the right fix is to pick one set and stick to it everywhere, not to
  emit both.
  Date: 2026-04-18

- Decision: Span name is `Shibuya.Telemetry.Semantic.processMessageSpanName`
  (currently `"shibuya.process.message"`), not `"process <topic>"` as
  the upstream library uses. Rationale: stable framework-prefixed
  name lets dashboard authors filter on a single string regardless of
  topic count.
  Date: 2026-04-18

- Decision: Resolve Milestone 2's design question in favour of option
  (A) — `traced :: TopicName -> Stream ... -> Stream ...`. The caller
  passes the topic name explicitly; `traced` does not parse it back
  out of `MessageId`. Rationale: every realistic caller already has
  the topic name in scope from the adapter configuration, so the
  parameter is effectively free, and it sidesteps the fragility of
  splitting `"<topic>-<partition>-<offset>"` when a topic name itself
  contains dashes. This is the resolution the plan pre-authorized.
  Date: 2026-04-18

- Decision: Tests inline a ~15-line in-memory `SpanProcessor` rather
  than depending on `hs-opentelemetry-exporter-in-memory`. Rationale:
  the current Hackage release (0.0.1.4) pins `hs-opentelemetry-api
  <0.3`, incompatible with this repository's resolved 0.3.1.0. The
  inlined processor mirrors `inMemoryListExporter` exactly (append to
  `IORef [ImmutableSpan]` on span end) and keeps the test footprint
  self-contained.
  Date: 2026-04-18


## Outcomes & Retrospective

(To be filled during and after implementation. At completion this
must answer: does `traced` close all four shapes the test enumerates?
Did `OtelDemo.hs` actually shrink? Are there any callers in the wider
Shibuya monorepo that would benefit from the same pattern but cannot
adopt it because of an effect-stack mismatch?)


## Context and Orientation

A novice reading only this plan needs to know what already exists in
the repository. The relevant pieces:

- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` — exports
  `kafkaAdapter :: KafkaAdapterConfig -> Eff es (Adapter es (Maybe ByteString))`.
  Produces an `Adapter` whose `source` is a
  `Stream (Eff es) (Ingested es (Maybe ByteString))`.
- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs` — the
  hot path. `kafkaSource` polls the broker via
  `Kafka.Effectful.Consumer.Effect.pollMessageBatch`,
  `mkIngested` converts each `ConsumerRecord` to an `Ingested`,
  `ingestedStream` flattens `Either KafkaError (ConsumerRecord ...)`
  into either an `Ingested` or a thrown `KafkaError`. **This file is
  not modified by this plan.**
- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs` —
  contains `extractTraceHeaders` which already populates
  `Envelope.traceContext` from the W3C headers. **Also not modified.**
- `shibuya-core` (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/`) —
  source of:
  - `Shibuya.Telemetry.Effect`: `Tracing` static effect, `runTracing`,
    `withSpan'`, `withExtractedContext`, `addAttribute`. Implementation
    at `src/Shibuya/Telemetry/Effect.hs`.
  - `Shibuya.Telemetry.Propagation`: `extractTraceContext ::
    TraceHeaders -> Maybe SpanContext`. Implementation at
    `src/Shibuya/Telemetry/Propagation.hs`.
  - `Shibuya.Telemetry.Semantic`: `processMessageSpanName`,
    `consumerSpanArgs`, the v1.27 attribute key constants. Source at
    `src/Shibuya/Telemetry/Semantic.hs`.
  - `Shibuya.Core.Types`: `Envelope`, `MessageId`, `TraceHeaders`.
  - `Shibuya.Core.Ingested`: `Ingested { envelope, ack, lease }`.
  - `Shibuya.Core.AckHandle`: `AckHandle { finalize :: AckDecision -> Eff es () }`.
- `shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs` — the canonical
  per-call-site boilerplate this plan eliminates. Read it before
  starting Milestone 3.
- `shibuya-kafka-adapter-jitsurei/app/OtelProducerDemo.hs` — provides
  the producer-side analogue. Out of scope for this plan but
  illustrates the same pattern for the future DLQ work.
- `process-compose.yaml` and `.dev/jaeger-config.yaml` start a Jaeger
  v2 instance on the OTel ports for end-to-end verification. Bring
  both up with `just process-up`.

The Shibuya `Tracing` effect is a `Static 'WithSideEffects` effect.
Its `runTracing` runner takes a `Tracer` (from the OTel SDK) and
brings the effect into scope. Inside, `withSpan'` creates a span and
hands the user a callback receiving the `OTel.Span`. `addAttribute`
sets one attribute on a span. `withExtractedContext (Maybe SpanContext)
action` makes `action`'s freshly-opened spans children of the given
parent context (or root spans when the argument is `Nothing`). All of
this is no-op-on-zero-cost when `runTracingNoop` is used instead of
`runTracing`.

The OpenTelemetry hs-opentelemetry-api API (in `shibuya-core`'s
closure already, but not directly importable from
`shibuya-kafka-adapter` until Milestone 1 adds the explicit
build-dep): `OpenTelemetry.Trace.Core.{getSpanContext, SpanContext}`,
`OpenTelemetry.Trace.Id.{traceIdBaseEncodedText, spanIdBaseEncodedText, Base(Base16)}`.


## Plan of Work

### Milestone 1 — Make the API package directly importable

**Scope.** Edit `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`'s
`library` stanza to add `hs-opentelemetry-api ^>=0.3` to
`build-depends`. The bound exactly matches what `shibuya-core` already
declares. Run `cabal build all` and confirm a clean build, no new
solver activity (the package is already in the closure via
`shibuya-core`).

**Why.** Plan 8 Milestone 2 demonstrated, with a concrete GHC
`-87110` error on `OpenTelemetry.Trace.Core`, that transitive
presence is not enough. The new module imports `Span`,
`SpanContext`, and `getSpanContext` directly from
`OpenTelemetry.Trace.Core` and so requires the explicit edge.

**What will exist at the end.** A committed cabal change adding one
build-depends line. Nothing user-visible has changed yet.

**Acceptance.** `cabal build all` exits 0. `cabal build --dry-run all
2>&1 | grep hs-opentelemetry-api` shows the package being satisfied
without re-resolution.

### Milestone 2 — Add the `traced` stream transformer and tests

**Scope.** Create
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs` exposing
exactly one function:

    traced
      :: forall es v.
         (Tracing :> es, IOE :> es)
      => Stream (Eff es) (Ingested es v)
      -> Stream (Eff es) (Ingested es v)

The implementation transforms each `Ingested` by replacing its
`AckHandle.finalize` with a wrapper that opens a
`shibuya.process.message` span (kind=Consumer) — using
`processMessageSpanName` and `consumerSpanArgs` from
`Shibuya.Telemetry.Semantic` — populates the four messaging
attributes from the envelope, and keeps the span open across the
caller's eventual call to `finalize ackDecision`. Sketch:

    traced =
        Stream.mapM $ \ing@Ingested{envelope, ack = AckHandle finalize} -> do
            let parentCtx = envelope.traceContext >>= extractTraceContext
                wrappedFinalize decision =
                    withExtractedContext parentCtx $
                        withSpan' processMessageSpanName consumerSpanArgs $ \sp -> do
                            populateAttrs sp envelope
                            finalize decision
            pure ing { ack = AckHandle wrappedFinalize }

`populateAttrs sp Envelope{messageId, partition}` calls
`addAttribute sp attrMessagingSystem ("kafka" :: Text)`,
`addAttribute sp attrMessagingDestinationName <topicName>`,
`addAttribute sp attrMessagingMessageId (unMessageId messageId)`, and
when `partition` is `Just p` also
`addAttribute sp attrMessagingDestinationPartitionId p`. The topic
name is derived from the envelope's `messageId` (which is
`"<topic>-<partition>-<offset>"` per `Shibuya.Adapter.Kafka.Convert.mkMessageId`)
or — better — passed to `traced` as a curried `Text` argument.

Important design call to make in this milestone: **does
`populateAttrs` need the topic name from outside the envelope, or can
it parse it back from `MessageId`?** The Convert module synthesises
`MessageId` as `<topic>-<partition>-<offset>`, but the topic name is
not separately addressable on the envelope. Two acceptable resolutions:

- (A) `traced :: TopicName -> Stream ... -> Stream ...` and the caller
  passes the topic. Simplest, no parsing fragility, but requires the
  caller to keep the topic name in sync with the adapter's
  configuration. The jitsurei refactor in Milestone 3 already has the
  topic name in scope so this is free for it.
- (B) parse the topic out of `MessageId` by splitting on the **last
  two** dashes from the right. Robust to topic names containing
  dashes, no extra parameter, but adds an implementation footgun if
  the `MessageId` format ever changes.

Resolve in favour of (A) and document the choice in the Decision Log
during this milestone.

Test file:
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`
with four cases:

1. Envelope carrying a valid `traceparent` produces a span whose
   `getSpanContext`'s `traceId` equals the parent's `traceId` and
   whose `parentSpanId` equals the parent's `spanId`.
2. Envelope with `traceContext = Nothing` produces a span that is a
   root span (its `traceId` is fresh, no `parentSpanId`).
3. The four messaging attributes are present on the emitted span
   (read them back via `OTel.spanGetAttributes` if the API exposes
   it; otherwise capture them via an in-memory exporter — a minimal
   one is roughly 30 lines of Haskell against `OpenTelemetry.Exporter.Span`).
4. The original handler's `AckDecision` is still threaded through —
   pass an `AckOk` and assert it was observed by a side-channel `IORef`.

Tests run under `runTracing` with a tracer wired to an in-memory
exporter. Use `Shibuya.Telemetry.Effect.runTracing` directly; do not
require Redpanda.

Add `Shibuya.Adapter.Kafka.Tracing` to the library's `exposed-modules`
list, add `Shibuya.Adapter.Kafka.TracingTest` to the test suite's
`other-modules`, and run `cabal test shibuya-kafka-adapter`. Expect
all existing tests to keep passing and the four new ones to pass.

**Why.** Test coverage is the only thing that prevents future drift
of attribute names back to the wrong namespace, and the only thing
that can guarantee `traced` does not leak an open span on an
exception. Plan 8 Milestone 5 explicitly flagged this as the most
important code-quality control.

**What will exist at the end.** New module + new test file +
updated cabal. `cabal test shibuya-kafka-adapter` exits 0.

**Acceptance.** All test cases above pass. The new module is exported
from `Shibuya.Adapter.Kafka.Tracing` per `cabal info
shibuya-kafka-adapter | grep Tracing`.

### Milestone 3 — Refactor `OtelDemo.hs` to use `traced`

**Scope.** Replace the per-record `withExtractedContext` +
`withSpan'` + `addAttribute` block in
`shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs` with a single call to
`traced topicName` wrapping the existing `Stream.mapM` pipeline. The
file should shrink by roughly 25 lines. The diagnostic prints (parent
trace ID, opened span trace ID) should remain — they are useful both
as evidence and as a smoke test.

Re-run the Plan 8 Milestone 2 verification recipe from
`docs/plans/8-investigate-hw-kafka-client-instrumentation.md`:

    just process-up
    just create-topics
    rpk topic produce orders --key k1 \
        -H 'traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' \
        <<< 'hello-otel'
    cabal run otel-demo

Confirm the trace in Jaeger has identical structure to the one
recorded in Plan 8's Surprises (Milestone 2 entry): one
`shibuya.process.message` span (kind=Consumer) under
`CHILD_OF b7ad6b7169203331`, four messaging attributes set.

**Why.** The refactor is the user-visible win this plan delivers and
the proof that `traced` actually subsumes the boilerplate it claims
to subsume.

**What will exist at the end.** A shorter, simpler `OtelDemo.hs`. The
producer demo and the upstream-probe demo remain untouched.

**Acceptance.** `OtelDemo.hs` no longer imports
`Shibuya.Telemetry.Effect.{withExtractedContext, withSpan'}`,
`Shibuya.Telemetry.Propagation`, `Shibuya.Telemetry.Semantic`. It
imports only `Shibuya.Adapter.Kafka.Tracing.traced` plus
`Shibuya.Telemetry.Effect.runTracing` (still needed to install the
tracer). The Jaeger trace for the same input matches Plan 8 Milestone
2's recorded baseline byte-for-byte on operationName, kind, refs, and
the four messaging attributes.

### Milestone 4 — Documentation and version bump

**Scope.** Add a short paragraph to
`shibuya-kafka-adapter/README.md` (if it exists; create it if not)
showing the two-line tracing wiring. Add a `CHANGELOG.md` entry under
a new `0.2.0.0` heading describing the additive module. Update
`shibuya-kafka-adapter.cabal`'s `version: 0.1.0.0` to `0.2.0.0`. Do
**not** bump `shibuya-kafka-adapter-jitsurei` or
`shibuya-kafka-adapter-bench` versions — those are internal.

**Why.** The new exposed module is a surface-area expansion. Semver
calls for a minor bump and a changelog so downstream callers can find
the new capability.

**Acceptance.** `cabal build all` clean. `git diff` shows the
README/CHANGELOG entry, the cabal version bump, and nothing else of
substance.

### Milestone 5 — Outcomes & Retrospective

**Scope.** Fill in the section. Confirm `OtelDemo.hs` shrank as
expected, that the in-memory exporter approach worked (or that the
fallback `getSpanContext` strategy was needed instead, and why), and
note any drift discovered between v1.27 messaging conventions in
`Shibuya.Telemetry.Semantic` and what the OTel ecosystem currently
expects.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/`.
Every commit must include `ExecPlan: docs/plans/9-add-shibuya-kafka-tracing-module.md`
and the `Intention:` trailer above. Every commit must be preceded by
`nix fmt` (project rule in `CLAUDE.md`).

### Milestone 1 steps

1. Edit `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`. In the
   `library` stanza's `build-depends`, add the line
   `, hs-opentelemetry-api  ^>=0.3` in the appropriate alphabetical
   position. Do not touch the `test-suite` stanza.
2. Run `cabal build all`. Expected: clean build, no new package
   downloads (the package is already in the closure via
   `shibuya-core`).
3. Run `nix fmt`. Commit.

### Milestone 2 steps

1. Create
   `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs` with
   the implementation sketched above. Use `populateAttrs` as a private
   helper in the same module.
2. Add `Shibuya.Adapter.Kafka.Tracing` to the `exposed-modules` list
   in `shibuya-kafka-adapter.cabal`.
3. Create
   `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`.
   Use the existing test conventions (look at
   `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/ConvertTest.hs`
   for the per-test boilerplate). For the in-memory exporter, the
   minimum surface needed:

       data InMemorySpan = InMemorySpan { name :: Text, kind :: SpanKind, ... }
       newInMemoryExporter :: IO (SpanExporter, IO [InMemorySpan])

   Implement against `OpenTelemetry.Exporter.Span.SpanExporter` from
   `hs-opentelemetry-api`; `export` appends to an `IORef [InMemorySpan]`,
   `shutdown`/`forceFlush` are no-ops.
4. Add `Shibuya.Adapter.Kafka.TracingTest` to the test suite's
   `other-modules`.
5. Run `cabal test shibuya-kafka-adapter`. Expected: all four new
   cases pass; existing tests are unaffected.
6. `nix fmt`. Commit.

### Milestone 3 steps

1. Edit
   `shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs`. Remove the
   `withExtractedContext` + `withSpan'` + four `addAttribute` block.
   Remove the now-unused imports
   (`Shibuya.Telemetry.Effect.{withExtractedContext, withSpan',
   addAttribute}`, `Shibuya.Telemetry.Propagation.extractTraceContext`,
   the `Shibuya.Telemetry.Semantic.attr*` and
   `Shibuya.Telemetry.Semantic.consumerSpanArgs` and
   `Shibuya.Telemetry.Semantic.processMessageSpanName`). Add
   `import Shibuya.Adapter.Kafka.Tracing (traced)`.
2. Apply `traced (TopicName topicName)` to the source stream:

       Stream.fold Fold.drain
           $ Stream.mapM (\ing -> ackOk ing) -- existing print + finalize logic
           $ Stream.take messagesToProcess
           $ traced (TopicName topicName) source

3. `cabal build shibuya-kafka-adapter-jitsurei:otel-demo`.
4. Bring up Redpanda + Jaeger (`just process-up` in another shell).
   Produce the same test record:

       rpk topic produce orders --key k1 \
           -H 'traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' \
           <<< 'hello-otel-after-refactor'

5. `cabal run shibuya-kafka-adapter-jitsurei:otel-demo`. Expect
   identical Jaeger output to Plan 8 Milestone 2's recorded baseline.
6. Capture a brief diff summary or line count comparison in
   Surprises & Discoveries to demonstrate the boilerplate reduction.
7. `nix fmt`. Commit.

### Milestone 4 steps

1. Bump `version: 0.1.0.0` to `version: 0.2.0.0` in
   `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`.
2. If `shibuya-kafka-adapter/CHANGELOG.md` exists (per the cabal
   `extra-doc-files`), add a `## 0.2.0.0` entry describing the new
   module. If `shibuya-kafka-adapter/README.md` exists, add a section
   showing the two-line tracing wiring example.
3. `cabal build all`. `nix fmt`. Commit.

### Milestone 5 steps

1. Open this plan file. Fill in Outcomes & Retrospective.
2. Commit.


## Validation and Acceptance

At any milestone's completion, the following must hold:

- `cabal build all` exits 0.
- `cabal test shibuya-kafka-adapter` passes (requires Redpanda for
  the integration tests; tracing tests do not).
- `nix fmt` has been run, `git diff --check` is clean.
- Every commit carries `ExecPlan:` and `Intention:` git trailers.

Plan-wide acceptance:

- A new exposed module
  `Shibuya.Adapter.Kafka.Tracing` exporting one function `traced`
  exists in `shibuya-kafka-adapter` 0.2.0.0.
- Four unit tests in
  `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`
  pass (parented span, root span, attribute set, ack passthrough).
- The Plan 8 Milestone 2 Jaeger recipe still produces an identical
  trace shape after `OtelDemo.hs` is refactored to use `traced`.


## Idempotence and Recovery

Every step is reversible:

- Milestone 1: revert by deleting the added `hs-opentelemetry-api`
  build-depends line.
- Milestone 2: revert by deleting the new module and test files and
  removing them from the cabal file.
- Milestone 3: revert by restoring `OtelDemo.hs` to its current form
  on master (`git show HEAD:shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs`).
- Milestone 4: revert the version bump and the doc additions.

If `cabal test shibuya-kafka-adapter` fails after Milestone 2, the
likely cause is the in-memory exporter implementation. Fall back to
the `getSpanContext`-based assertion strategy described in the
Milestone 2 scope; record the fallback in the Decision Log.


## Interfaces and Dependencies

The final new public interface is exactly:

    module Shibuya.Adapter.Kafka.Tracing
      ( traced
      ) where

    traced
      :: (Tracing :> es, IOE :> es)
      => TopicName
      -> Stream (Eff es) (Ingested es v)
      -> Stream (Eff es) (Ingested es v)

No other public function is added. No public type is changed.

New build-depends edges introduced by this plan:

- `shibuya-kafka-adapter` library →
  `hs-opentelemetry-api ^>=0.3` (Milestone 1).

Already-present edges relied on (no new install):

- `shibuya-kafka-adapter` library →
  `shibuya-core ^>=0.1.0.0` (provides `Shibuya.Telemetry.{Effect,Propagation,Semantic}`).
- `shibuya-kafka-adapter` library →
  `streamly ^>=0.11`, `streamly-core ^>=0.3` (provides `Stream.mapM`).

Out of scope:

- No producer-side helper. The DLQ follow-up plan can add one.
- No change to `Shibuya.Adapter.Kafka.kafkaAdapter` signature or to
  `Adapter`'s type.
- No new dep on
  `hs-opentelemetry-instrumentation-hw-kafka-client`. Plan 8 Milestone
  5 is the authoritative reasoning for this exclusion.
- No change to Jaeger / process-compose configuration. Plan 8
  Milestone 1 already provides the verification scaffolding.
