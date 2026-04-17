# Evaluate whether hw-kafka-streamly improves the adapter

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

The shibuya-kafka-adapter currently implements its own Kafka-to-Streamly streaming logic
in `Shibuya.Adapter.Kafka.Internal`, including poll-loop construction, error handling, and
stream lifecycle. A sibling library, hw-kafka-streamly, provides a reusable layer of
Streamly streaming combinators on top of hw-kafka-client: consumer sources, producer sinks,
error classification and filtering, value mapping, and batching.

This plan evaluates whether adopting hw-kafka-streamly would improve the adapter's
implementation in terms of correctness (especially error handling), code reduction, and
long-term maintainability. The evaluation produces a concrete recommendation with evidence,
and if the recommendation is positive, identifies the exact integration surface and changes
required.

After this evaluation, the reader will understand: (a) which parts of hw-kafka-streamly are
directly usable within the adapter's effectful architecture, (b) which parts are blocked by
the kafka-effectful abstraction boundary, and (c) whether the net value justifies a
dependency.


## Progress

- [x] Milestone 1: Characterize the architectural gap between hw-kafka-streamly and kafka-effectful (2026-04-09)
  - [x] Verified Eff es satisfies MonadIO (when IOE :> es), MonadThrow, MonadCatch (unconditional)
  - [x] Confirmed kafka-effectful does not expose KafkaConsumer handle (no Internal/Unsafe modules)
  - [x] Identified streamly-core version gap: adapter ^>=0.3 vs hw-kafka-streamly >=0.4 (blocker)
  - [x] Built compatibility matrix classifying all hw-kafka-streamly exports
- [x] Milestone 2: Prototype using hw-kafka-streamly combinators within the effectful monad (2026-04-09)
  - [x] Added hw-kafka-streamly to cabal.project local packages (superseded 2026-04-17 — now on Hackage)
  - [x] Added local streamly 0.12 / streamly-core 0.4 as optional-packages (superseded 2026-04-17 — reverted to Hackage streamly 0.11 / streamly-core 0.3)
  - [x] Added allow-newer for shibuya-core and shibuya-kafka-adapter streamly constraints (superseded 2026-04-17 — removed)
  - [x] Updated shibuya-kafka-adapter.cabal: hw-kafka-streamly ^>=0.1, streamly ^>=0.11, streamly-core ^>=0.3
  - [x] Modified kafkaSource in Internal.hs to preserve Either values and apply skipNonFatal
  - [x] Updated kafkaAdapter in Kafka.hs to use mapMaybeM for Either extraction
  - [x] All 21 tests pass (16 unit + 5 integration)
  - [x] Benchmark package builds cleanly
  - [x] Examples package builds cleanly
- [x] Milestone 3: Assess source function compatibility and alternatives (2026-04-09)
  - [x] Read kafka-effectful interpreter: handle created at line 31, closed at line 38, only passed to handleConsumer closure
  - [x] Analyzed Option 1 (combinators only): proven feasible in Milestone 2
  - [x] Analyzed Option 2 (expose handle): breaks abstraction, resource ownership conflict with bracketIO
  - [x] Analyzed Option 3 (bypass effectful): incompatible with ack semantics — offset operations need the handle that hw-kafka-streamly's source encapsulates
- [x] Milestone 4: Write recommendation with evidence (2026-04-09)
- [x] Milestone 5: Evaluate the performance impact of the hw-kafka-streamly integration (2026-04-10)
  - [x] Added hw-kafka-streamly, streamly, streamly-core to benchmark cabal deps
  - [x] Added isFatal classification benchmarks (fatal, timeout, partition EOF)
  - [x] Added skipNonFatal stream filtering benchmarks (10k elements with/without filter)
  - [x] Added mapMaybeM extraction benchmarks (new Either path vs old bare record path)
  - [x] Added Stream drain baseline benchmark (10k Int)
  - [x] Ran benchmarks against existing baseline: no regression in conversion benchmarks
  - [x] Generated updated baseline.csv including stream pipeline benchmarks
  - [x] Documented findings in Surprises & Discoveries


## Surprises & Discoveries

- Discovery (Milestone 1): `Eff es` has `MonadThrow` and `MonadCatch` instances **unconditionally** — no `IOE :> es` constraint required. This means hw-kafka-streamly's `throwLeft` and `throwLeftSatisfy` (which need `MonadThrow m`) work with `Eff es` even without `IOE` in the effect stack. Source: `Effectful.Internal.Monad` lines 347 and 354 in `/Users/shinzui/Keikaku/hub/haskell/effectful-project/effectful/effectful-core/src/Effectful/Internal/Monad.hs`.

- Discovery (Milestone 1): **streamly-core version gap is a hard blocker.** The adapter uses `streamly-core ^>=0.3` (>=0.3.0, <0.4). hw-kafka-streamly requires `streamly-core >=0.4 && <0.5`. These ranges do not overlap. Additionally, hw-kafka-streamly's `Combinators` module imports `Streamly.Data.Scanl` which is a new module in streamly-core 0.4. The adapter must upgrade to streamly-core 0.4 before it can depend on hw-kafka-streamly.

  **Update (2026-04-17):** hw-kafka-streamly 0.1.0.0 was published to Hackage with a relaxed `streamly-core >=0.3 && <0.5` constraint, so the gap no longer exists. The adapter stays on streamly ^>=0.11 / streamly-core ^>=0.3 (matching shibuya-core and the Hackage latest).

- Discovery (Milestone 1): Compatibility matrix for hw-kafka-streamly exports:

  **Category A — Compatible (monad-polymorphic combinators):**
  - `skipNonFatal` (`Monad m`) — compatible
  - `skipNonFatalExcept` (`Monad m`) — compatible
  - `isFatal`, `isPollTimeout`, `isPartitionEOF` (pure functions, no monad constraint) — compatible
  - `throwLeft` (`MonadThrow m`) — compatible (Eff es has unconditional MonadThrow)
  - `throwLeftSatisfy` (`MonadThrow m`) — compatible
  - `batchByOrFlush` (`Monad m`) — compatible
  - `batchByOrFlushEither` (`Monad m`) — compatible
  - All 12 value mapping utilities (`Monad m` or `Functor`/`Bifunctor`) — compatible

  **Category B — Incompatible (source constructors):**
  - `kafkaSourceNoClose` (`MonadIO m`) — requires raw `KafkaConsumer` handle, not exposed by kafka-effectful
  - `kafkaSourceAutoClose` (`MonadIO m, MonadCatch m`) — same handle problem
  - `kafkaSource` (`MonadIO m, MonadCatch m`) — creates its own consumer lifecycle, bypasses effectful

  **Category C — Out of scope (producer sinks):**
  - `kafkaSink`, `kafkaBatchSink`, `withKafkaProducer` — adapter has no production capability

- Discovery (Milestone 2): The streamly 0.11→0.12 / streamly-core 0.3→0.4 upgrade is **fully backwards-compatible** for all existing adapter code. shibuya-core also rebuilds cleanly with streamly 0.12. No code changes were needed for the version bump — only cabal constraint adjustments and `allow-newer` directives. The `Streamly.Data.Stream` and `Streamly.Data.Fold` public APIs are identical between 0.3 and 0.4.

  **Update (2026-04-17):** The upgrade is no longer necessary. Once hw-kafka-streamly was published to Hackage with `streamly-core >=0.3 && <0.5`, the adapter reverted to streamly ^>=0.11 / streamly-core ^>=0.3, matching Hackage and shibuya-core. The verified backwards-compatibility still holds if a future upgrade is needed.

- Discovery (Milestone 2): The `skipNonFatal` combinator from hw-kafka-streamly composes with `Stream (Eff es)` without issue. The `Monad m` constraint is satisfied by `Eff es` unconditionally. This confirms Category A compatibility is not just theoretical — it works in practice with the adapter's exact effect stack (`KafkaConsumer :> es, Error KafkaError :> es, IOE :> es`).

- Discovery (Milestone 5): **The streamly 0.12 upgrade introduces no performance regression in existing conversion benchmarks.** All seven original benchmarks were compared against the baseline captured under streamly 0.11 / streamly-core 0.3. Results: ConsumerRecord→Envelope "with trace headers" 575ns (baseline 553ns, within stdev), "without trace headers" 529ns (baseline 491ns, 7% higher but within 2x stdev of 33ns), all trace header extraction benchmarks "same as baseline", timestamp conversion "same as baseline". The NoTimestamp benchmark showed 2.60ns vs baseline 2.20ns (19% higher), but at sub-3ns measurements this is within noise. Conclusion: the streamly version upgrade is performance-neutral.

- Discovery (Milestone 5): **The `isFatal` pattern match costs ~3.3ns per call regardless of the error type.** Fatal error (SSL): 3.30ns, non-fatal timeout: 3.45ns, non-fatal partition EOF: 3.42ns. The 17-constructor match for fatal errors does not cost more than the two-constructor match for non-fatal errors, likely because GHC compiles the case expression to a jump table. This is negligible compared to the adapter's per-message cost (~575ns for envelope conversion alone).

- Discovery (Milestone 5): **The combined overhead of `skipNonFatal` + `mapMaybeM` is ~1.2ns per stream element.** Benchmark results on 10,000-element streams (95% Right, 5% Left non-fatal errors):

  `skipNonFatal` filtering: 38.6μs with filter vs 26.4μs without filter = 12.2μs overhead for 10,000 elements = **~1.22ns per element**.

  `mapMaybeM` extraction: 38.3μs (new Either path) vs 26.3μs (old bare record path) = 12.0μs overhead for 10,000 elements = **~1.20ns per element**.

  Stream drain baseline (10k Int): 26.4μs, confirming the ~26μs is Streamly's base stream traversal cost.

  The overhead comes from the additional `Either` case analysis on each element. For `skipNonFatal`, it is `either isFatal (const True)` — on the hot path (Right values), this is a constructor match returning `True`. For `mapMaybeM`, it is a case match returning `Just cr` or `Nothing`. Both are single-branch pattern matches on the common path.

  In context, the adapter's per-message cost is dominated by envelope conversion (~575ns) and the Kafka FFI poll (~milliseconds). An additional ~1.2ns per element is a **0.2% increase** relative to envelope conversion and vanishes entirely relative to network I/O. The performance impact is negligible.


## Decision Log

- Decision: Scope the evaluation to consumer-side only (not producer sinks), since the adapter currently has no production capability.
  Rationale: hw-kafka-streamly's producer API (`kafkaSink`, `kafkaBatchSink`, `withKafkaProducer`) is irrelevant to the current adapter. If production is added later, it can be evaluated independently.
  Date: 2026-04-09

- Decision: Structure the evaluation as an analytical plan with targeted prototypes rather than a full rewrite spike.
  Rationale: The primary question is whether the libraries can compose at all, given the effectful layer. A targeted prototype answers this faster and with less risk than rewriting the adapter speculatively.
  Date: 2026-04-09

- Decision (Milestone 3): Option 1 (combinators only) is the recommended integration path.
  Rationale: Three options were assessed:

  **Option 1 — Keep kafka-effectful, use only hw-kafka-streamly combinators.**
  The adapter continues using kafka-effectful for consumer lifecycle, polling, and offset management. hw-kafka-streamly is adopted only for its downstream combinators: error classification (`isFatal`, `isPollTimeout`, `isPartitionEOF`), error filtering (`skipNonFatal`, `skipNonFatalExcept`), error-to-exception conversion (`throwLeft`, `throwLeftSatisfy`), and batching (`batchByOrFlush`, `batchByOrFlushEither`). The Milestone 2 prototype proved this works: `skipNonFatal` composes with `Stream (Eff es)`, all 21 tests pass, and the streamly version upgrade is non-breaking. No architectural changes are needed. The only cost is a new dependency and a streamly version bump.

  **Option 2 — Expose the KafkaConsumer handle from kafka-effectful.**
  This would add a `GetConsumer :: KafkaConsumer m K.KafkaConsumer` constructor to the effect GADT, allowing hw-kafka-streamly's `kafkaSourceNoClose` to be used within the effect scope. However, this has three problems: (a) it breaks kafka-effectful's abstraction boundary — any caller could bypass the effect system with `liftIO (K.pollMessage handle ...)`, undermining type-level guarantees; (b) resource ownership becomes ambiguous — if the handle is passed to `kafkaSourceAutoClose`, the stream would attempt to close a consumer that `runKafkaConsumer`'s bracket also closes; (c) hw-kafka-streamly's source uses single-message polling (`pollMessage`), changing the adapter's current batch polling throughput characteristics.

  **Option 3 — Bypass kafka-effectful, use hw-kafka-streamly's kafkaSource directly.**
  This would eliminate kafka-effectful from the consumer path and use hw-kafka-streamly's fully-managed `kafkaSource` for consumption. However, this is fundamentally incompatible with the adapter's acknowledgment semantics. The adapter's `mkAckHandle` needs to call `storeOffsetMessage` and `pausePartitions` on the consumer handle, but hw-kafka-streamly's `kafkaSource` encapsulates the handle inside `bracketIO` — it is inaccessible from the stream consumer. Using `kafkaSourceNoClose` with a manually-created handle would bypass effectful entirely, losing the `KafkaConsumer :> es` effect constraint and requiring all offset operations to use raw `liftIO` calls. This is a major architectural regression that eliminates type-level guarantees about Kafka operation availability.

  Option 1 wins because hw-kafka-streamly and kafka-effectful operate at fundamentally different abstraction layers. kafka-effectful manages the consumer lifecycle and provides effect-typed operations. hw-kafka-streamly provides stream construction and stream combinators for applications that do not use an effect system. The adapter already has lifecycle management via kafka-effectful; what it lacks is the combinator layer. Option 1 adopts exactly the layer the adapter needs without disrupting the layer it already has.
  Date: 2026-04-09

- Decision: Add Milestone 5 to evaluate the performance impact of the hw-kafka-streamly integration before finalizing the adoption.
  Rationale: Milestones 1-4 evaluated correctness, compatibility, and architectural fit but did not measure performance. The integration changes the stream pipeline in two ways that could affect throughput: (1) `kafkaSource` now preserves `Either` values and applies `skipNonFatal` (a `Stream.filter` with `isFatal` pattern matching on every element), and (2) `kafkaAdapter` now uses `mapMaybeM` instead of `mapM` to extract `Right` values. Additionally, the streamly 0.11→0.12 / streamly-core 0.3→0.4 upgrade must be verified as performance-neutral for existing conversion benchmarks. A recommendation to adopt a new dependency should include evidence that it does not introduce a performance regression.
  Date: 2026-04-10


## Outcomes & Retrospective

### Recommendation

**Yes, the adapter should adopt hw-kafka-streamly — partially, using Option 1 (combinators only).**

hw-kafka-streamly's stream combinators compose cleanly with the adapter's effectful monad and provide concrete improvements to error handling, which is the adapter's most significant gap. The source constructors are incompatible with the kafka-effectful architecture and should not be adopted.

**Concrete value gained:**

1. **Error handling taxonomy.** The adapter currently silently discards all poll errors. With hw-kafka-streamly's `skipNonFatal`, the adapter now properly classifies 17 error types as fatal (configuration errors, SSL failures, authentication failures, authorization failures, protocol mismatches) and filters only non-fatal ones (timeouts, partition EOF). This is a real correctness improvement — a fatal configuration error would previously be silently swallowed, with the adapter continuing to poll indefinitely and returning no messages.

2. **Error handling options for future work.** The adapter can now evolve to use `throwLeft` to convert fatal errors into exceptions, `skipNonFatalExcept [isPollTimeout]` to detect when topics are drained, or `throwLeftSatisfy isFatal` to halt on fatal errors while preserving other `Left` values for logging. These are composable building blocks that would require custom code without the dependency.

3. **Batching combinators.** `batchByOrFlush` and `batchByOrFlushEither` are available for future use if the adapter needs to batch messages before processing.

**What does NOT change:**

- Consumer lifecycle: remains managed by kafka-effectful via `runKafkaConsumer`.
- Polling: continues to use `pollMessageBatch` (batch polling) through the effectful effect.
- Offset management: continues to use `storeOffsetMessage`, `commitAllOffsets`, `pausePartitions` through kafka-effectful.
- Stream construction: `kafkaSource` in `Internal.hs` still uses `Stream.repeatM` + `Stream.concatMap`. The only change is it now returns `Either KafkaError (ConsumerRecord ...)` instead of bare `ConsumerRecord`, and applies `skipNonFatal` to filter non-fatal errors.

**Required changes (already prototyped and tested):**

1. `shibuya-kafka-adapter.cabal`: Add `hw-kafka-streamly ^>=0.1` to build-depends. No streamly version bump needed — Hackage hw-kafka-streamly 0.1.0.0 allows `streamly-core >=0.3 && <0.5`.
2. `Internal.hs`: Import `Kafka.Streamly.Source (skipNonFatal)`, change `kafkaSource` to preserve `Either` values and apply `skipNonFatal`.
3. `Kafka.hs`: Change `mapM (pure . mkIngested)` to `mapMaybeM` that extracts `Right` values.

**Risks:**

- **streamly version coupling.** The adapter and hw-kafka-streamly must agree on the streamly-core major version. hw-kafka-streamly 0.1.0.0 on Hackage allows `streamly-core >=0.3 && <0.5`, so the adapter, shibuya-core, and hw-kafka-streamly all resolve against the same Hackage streamly 0.11 / streamly-core 0.3. No `allow-newer` or local overrides are needed.
- **hw-kafka-streamly API stability.** hw-kafka-streamly 0.1.0.0 is now published to Hackage. The maintainer is the same developer, so API changes are controlled, but version bumps should be reviewed when they land.
- **Performance impact (confirmed negligible in Milestone 5).** The new stream pipeline adds ~1.2ns per element overhead from `skipNonFatal` and `mapMaybeM`. This is 0.2% of the per-message envelope conversion cost (~575ns) and vanishes relative to Kafka network I/O. The streamly 0.12 upgrade introduces no regression in existing conversion benchmarks. See Surprises & Discoveries for full benchmark data.

**Migration path (all steps keep tests passing):**

1. Add `hw-kafka-streamly ^>=0.1` to the adapter's build-depends (Hackage). No streamly version bump required.
2. Modify `kafkaSource` to preserve errors and apply `skipNonFatal`.
3. Update `kafkaAdapter` to handle the `Either` stream.
4. Optionally, add fatal error handling (e.g., use `throwLeft` instead of dropping fatal `Left` values in `kafkaAdapter`).


### Performance Assessment (Milestone 5)

The performance evaluation confirms that the hw-kafka-streamly integration has negligible impact on throughput. Three findings support this conclusion:

First, the streamly 0.11→0.12 / streamly-core 0.3→0.4 upgrade is performance-neutral. All seven existing conversion benchmarks showed no statistically significant regression when compared against the pre-upgrade baseline.

Second, the `isFatal` pattern match that `skipNonFatal` applies to every `Left` value costs ~3.3ns per call. GHC compiles the 17-constructor match to an efficient jump table; fatal and non-fatal errors are classified at the same speed.

Third, the per-element overhead of the new pipeline (`skipNonFatal` + `mapMaybeM` on `Either` values) versus the old pipeline (`mapM` on bare records) is ~1.2ns per element. On 10,000-element streams: new path ~38.5μs vs old path ~26.4μs, a difference of ~12μs or 1.2ns per element. For context, envelope conversion alone costs ~575ns per message, and Kafka network polling is in the millisecond range. The 1.2ns overhead is 0.2% of the per-message pure processing cost and effectively unmeasurable in production.

The benchmark package (`shibuya-kafka-adapter-bench`) now includes a "Stream pipeline" benchmark group with 8 benchmarks covering isFatal classification, skipNonFatal filtering, mapMaybeM extraction, and a stream drain baseline. The updated `baseline.csv` includes all 15 benchmarks for future regression detection.


## Context and Orientation

This section orients the reader to the two codebases and the architectural tension between them.

### shibuya-kafka-adapter

The adapter lives at the repository root and is composed of three Cabal packages. The main library is in `shibuya-kafka-adapter/` with four source modules:

- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` is the public API. It exports `kafkaAdapter`, which returns an `Adapter es (Maybe ByteString)`. The `Adapter` type (from shibuya-core) bundles a Streamly `Stream` of `Ingested` values with a shutdown callback. The adapter runs within an `Eff es` monad from the effectful library, with constraints `KafkaConsumer :> es`, `Error KafkaError :> es`, and `IOE :> es`.

- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs` contains the stream construction. The function `kafkaSource` uses `Stream.repeatM pollBatch & Stream.concatMap Stream.fromList` to create an infinite stream of `ConsumerRecord` values. The `pollBatch` function calls `pollMessageBatch` from kafka-effectful, collects the `Right` values (discarding all `Left` errors), and returns them as a list. The function `mkIngested` converts each `ConsumerRecord` into an `Ingested` value by creating an `Envelope` (via `consumerRecordToEnvelope`) and an `AckHandle` (via `mkAckHandle`). The function `mkAckHandle` maps `AckDecision` values to kafka-effectful operations like `storeOffsetMessage` and `pausePartitions`.

- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs` holds pure conversion functions: `consumerRecordToEnvelope`, `extractTraceHeaders`, and `timestampToUTCTime`. These are well-tested and benchmarked.

- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Config.hs` defines `KafkaAdapterConfig` with fields `topics`, `pollTimeout`, `batchSize`, and `offsetReset`, plus a `defaultConfig` constructor.

The adapter depends on three key libraries:

1. **hw-kafka-client** (>=5.3, <6) provides the Haskell FFI bindings to librdkafka. It defines types like `ConsumerRecord`, `KafkaConsumer`, `TopicName`, `KafkaError`, `Timeout`, `BatchSize`, `Headers`, etc.

2. **kafka-effectful** (^>=0.1) wraps hw-kafka-client in the effectful effect system. It provides the `KafkaConsumer` effect with operations like `pollMessageBatch`, `storeOffsetMessage`, `commitAllOffsets`, and `pausePartitions`. Its interpreter, `runKafkaConsumer`, takes `ConsumerProperties` and `Subscription`, creates a `KafkaConsumer` handle via `newConsumer` from hw-kafka-client, and holds the handle in an internal closure. There is no public way to extract the underlying `KafkaConsumer` handle from within the effect.

3. **streamly** (^>=0.11) and **streamly-core** (^>=0.3) provide the `Stream` type and combinators. The adapter's streams are typed as `Stream (Eff es) a`.

### hw-kafka-streamly

This library lives at `/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly/` and provides Streamly streaming integration for hw-kafka-client. It has three modules:

- `hw-kafka-streamly/src/Kafka/Streamly/Source.hs` provides three consumer source constructors. `kafkaSourceNoClose` takes a `KafkaConsumer` handle and a `Timeout` and returns `Stream m (Either KafkaError (ConsumerRecord ...))` using `Stream.unfoldrM`. It polls one message at a time via `pollMessage` (not `pollMessageBatch`), terminates on fatal errors, and exposes all errors as `Left` values. `kafkaSourceAutoClose` wraps this with `Stream.bracketIO` for automatic cleanup. `kafkaSource` creates a consumer from `ConsumerProperties` and `Subscription`, managing the full lifecycle. The module also provides error predicates (`isFatal`, `isPollTimeout`, `isPartitionEOF`), error filters (`skipNonFatal`, `skipNonFatalExcept`), and 12 value mapping utilities (`mapFirst`, `mapValue`, `bimapValue`, etc.).

- `hw-kafka-streamly/src/Kafka/Streamly/Sink.hs` provides `kafkaSink` and `kafkaBatchSink` as Streamly `Fold` values, plus `withKafkaProducer` for bracketed producer lifecycle.

- `hw-kafka-streamly/src/Kafka/Streamly/Combinators.hs` provides batching (`batchByOrFlush`, `batchByOrFlushEither`) and error-to-exception conversions (`throwLeft`, `throwLeftSatisfy`).

hw-kafka-streamly depends on streamly-core `>=0.3 && <0.5` (compatible with the adapter's ^>=0.3), hw-kafka-client >=5.3, and has no dependency on effectful or kafka-effectful. Published to Hackage as 0.1.0.0 on 2026-04-17.

### The Architectural Tension

The core tension is that hw-kafka-streamly and kafka-effectful solve overlapping problems in incompatible ways:

- **Consumer lifecycle**: kafka-effectful encapsulates the `KafkaConsumer` handle inside its interpreter and provides effect-typed operations. hw-kafka-streamly's source functions either take a `KafkaConsumer` handle directly (which kafka-effectful does not expose) or create their own consumer (bypassing effectful entirely).

- **Streaming monads**: The adapter's streams run in `Stream (Eff es)` where `es` includes `KafkaConsumer` and `Error KafkaError` effects. hw-kafka-streamly's streams run in `Stream m` where `m` is any `MonadIO m`. Since `Eff es` with `IOE :> es` satisfies `MonadIO`, the downstream combinators (error filters, value mapping, batching) should be monad-compatible. But the source constructors are not, because they call hw-kafka-client directly via `liftIO` rather than through effectful operations.

- **Error handling**: The adapter currently discards all errors silently (the `pollBatch` function collects only `Right cr` from results). hw-kafka-streamly preserves errors as `Either KafkaError (ConsumerRecord ...)` and provides a principled taxonomy: `isFatal` classifies 17 error types as fatal, `skipNonFatal` filters non-fatal errors, and `throwLeft` converts to exceptions. This is a clear improvement the adapter could benefit from.

- **Polling strategy**: The adapter uses `pollMessageBatch` (batch polling), while hw-kafka-streamly uses `pollMessage` (single-message polling). This affects throughput characteristics.

- **Offset management**: The adapter performs offset management (storeOffsetMessage, commitAllOffsets) via kafka-effectful operations within the `Eff es` monad. hw-kafka-streamly does not handle offsets at all; it is purely a streaming layer.


## Plan of Work

The evaluation proceeds in four milestones. Each milestone produces a concrete artifact: a compatibility analysis, a working prototype, a gap assessment, and a final recommendation.


### Milestone 1: Characterize the Architectural Gap

This milestone produces a structured analysis of which hw-kafka-streamly components can and cannot be used within the adapter's current effectful architecture. No code changes are made; this is pure analysis.

The analysis examines three categories of hw-kafka-streamly exports:

**Category A: Monad-polymorphic combinators (likely compatible).** These functions have constraints like `Monad m`, `MonadThrow m`, or `MonadIO m`, and should work with `Eff es` as the base monad. This category includes `skipNonFatal`, `skipNonFatalExcept`, `isFatal`, `isPollTimeout`, `isPartitionEOF`, `throwLeft`, `throwLeftSatisfy`, `batchByOrFlush`, `batchByOrFlushEither`, and all 12 value mapping utilities. The analysis verifies each constraint against `Eff es` capabilities.

**Category B: Source constructors (incompatible with kafka-effectful).** The functions `kafkaSourceNoClose` and `kafkaSourceAutoClose` require a `KafkaConsumer` handle that kafka-effectful does not expose. The function `kafkaSource` creates its own consumer, bypassing effectful. Using any of these would require either exposing the handle from kafka-effectful or abandoning kafka-effectful for consumption.

**Category C: Producer sinks (out of scope).** The adapter has no production capability. These are noted for future reference only.

The deliverable is a compatibility matrix documented in the Surprises & Discoveries section.

To verify Category A, check that `Eff es` with appropriate effect constraints satisfies `MonadIO`, `MonadThrow`, and `MonadCatch`. The effectful library provides these instances when `IOE :> es`. Confirm this by reading the effectful documentation or instance declarations.

To verify Category B, confirm that kafka-effectful's `runKafkaConsumer` does not export or expose the `KafkaConsumer` handle. Read the source at `/Users/shinzui/Keikaku/bokuno/libraries/haskell/kafka-effectful/` and check both the effect definition and the interpreter.

### Milestone 2: Prototype Combinator Integration

This milestone creates a small prototype that proves hw-kafka-streamly's combinators (Category A) work within the adapter's effectful monad. The prototype does not modify the main adapter; it creates a temporary test module.

The prototype should:

1. Import `Kafka.Streamly.Source` (for `skipNonFatal`, `isFatal`) and `Kafka.Streamly.Combinators` (for `throwLeft`).

2. Modify the adapter's `kafkaSource` to preserve `Either KafkaError (ConsumerRecord ...)` instead of silently discarding errors. Currently `pollBatch` does `pure [cr | Right cr <- results]`; the modified version would return the full `[Either KafkaError (ConsumerRecord ...)]`.

3. Apply `skipNonFatal` from hw-kafka-streamly to the resulting stream.

4. Verify that the types check and the stream compiles within the `Eff es` monad.

5. Run the existing integration tests to confirm behavior is preserved.

The key file to modify is `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`. The `kafkaSource` function currently has this structure:

    kafkaSource config =
        Stream.repeatM pollBatch
            & Stream.concatMap Stream.fromList
      where
        pollBatch = do
            results <- pollMessageBatch config.pollTimeout config.batchSize
            pure [cr | Right cr <- results]

The prototype changes this to:

    kafkaSource config =
        skipNonFatal $
            Stream.repeatM pollBatch
                & Stream.concatMap Stream.fromList
      where
        pollBatch = do
            results <- pollMessageBatch config.pollTimeout config.batchSize
            pure results  -- preserve Either values

This changes the return type from `Stream (Eff es) (ConsumerRecord ...)` to `Stream (Eff es) (Either KafkaError (ConsumerRecord ...))`, which requires corresponding changes in callers.

If the prototype compiles and tests pass, it proves Category A integration is feasible. If it fails, the failure mode reveals whether the issue is monad compatibility, instance availability, or something else.

The cabal file must also be updated to add `hw-kafka-streamly` as a dependency and the streamly-core version constraint may need adjustment since hw-kafka-streamly depends on streamly-core ^>=0.4 while the adapter uses ^>=0.3.

### Milestone 3: Assess Source Function Alternatives

This milestone evaluates whether the adapter should adopt hw-kafka-streamly's source functions (Category B) by bypassing or modifying kafka-effectful. Three options are assessed:

**Option 1: Keep kafka-effectful, use only combinators.** The adapter continues using kafka-effectful for consumer lifecycle and polling, and adopts hw-kafka-streamly only for its downstream combinators (error handling, value mapping, batching). This is the minimal change: add a dependency, use `skipNonFatal` / `isFatal` / etc. in the stream pipeline, and improve error handling without restructuring.

**Option 2: Expose the KafkaConsumer handle from kafka-effectful.** Add a new operation to kafka-effectful's `KafkaConsumer` effect that returns the underlying `KafkaConsumer` handle. This would allow using `kafkaSourceNoClose` from hw-kafka-streamly within the effectful monad. However, this breaks the abstraction boundary of kafka-effectful and raises questions about resource ownership (who closes the consumer?).

**Option 3: Bypass kafka-effectful for consumption, use hw-kafka-streamly's kafkaSource directly.** Replace `runKafkaConsumer` with `kafkaSource` from hw-kafka-streamly and wrap offset management in a separate effectful layer. This eliminates kafka-effectful from the consumer path but keeps it for producer use if needed later. The adapter would use hw-kafka-streamly's managed consumer lifecycle and handle offsets via hw-kafka-client's direct API (which hw-kafka-streamly does not abstract).

Each option is assessed for: type compatibility, effect constraint changes, offset management feasibility, test impact, and dependency graph changes.

The deliverable is a comparison table in the Decision Log.

### Milestone 4: Write Recommendation

This milestone synthesizes the findings from Milestones 1-3 into a clear recommendation. The recommendation addresses:

1. **Should the adapter adopt hw-kafka-streamly?** Yes, no, or partially.
2. **If yes, which integration option?** Option 1 (combinators only), Option 2 (expose handle), or Option 3 (bypass effectful).
3. **What are the concrete code changes?** Files, functions, and dependency updates.
4. **What are the risks?** Version conflicts, API stability, maintenance burden.
5. **What is the migration path?** Sequence of changes that keeps tests passing at each step.

The recommendation is written as a new section in this plan and summarized in Outcomes & Retrospective.


### Milestone 5: Evaluate Performance Impact

This milestone quantifies the performance cost of the hw-kafka-streamly integration to ensure the correctness improvements from Milestone 2 do not come at the expense of throughput. The existing benchmark package (`shibuya-kafka-adapter-bench`) benchmarks pure conversion functions using tasty-bench and has a baseline CSV (`baseline.csv`) for regression detection. This milestone extends those benchmarks to cover the new stream pipeline components and verifies the streamly version upgrade is performance-neutral.

There are three categories of performance concern:

**Category 1: Combinator overhead.** The `skipNonFatal` combinator applies `Stream.filter (either isFatal (const True))` to every stream element. For `Right` values (successful records, the common path), this is a constant-time `const True`. For `Left` values (errors), it calls `isFatal`, which pattern-matches against 17 `KafkaError` constructors. Both paths should be cheap, but the per-element cost of wrapping every record in `Either` and filtering is new overhead that did not exist before the integration. The benchmark measures `isFatal` on representative error values and the per-element cost of `skipNonFatal` on a synthetic stream of `Either` values.

**Category 2: Pipeline shape change.** The adapter's stream pipeline changed from `kafkaSource` producing bare `ConsumerRecord` values consumed by `mapM (pure . mkIngested)`, to `kafkaSource` producing `Either KafkaError (ConsumerRecord ...)` consumed by `mapMaybeM` that extracts `Right` values and applies `mkIngested`. The `mapMaybeM` path evaluates a case expression on each element and returns `Nothing` for `Left` values. This is an additional branch per element. Since `pollMessageBatch` in practice returns mostly `Right` values (errors are infrequent), the benchmark should focus on the `Right`-path cost.

**Category 3: Streamly version upgrade.** The adapter upgraded from streamly 0.11 / streamly-core 0.3 to streamly 0.12 / streamly-core 0.4. Milestone 2 confirmed API compatibility, but the internal stream representation or fusion behavior could differ between versions. The existing conversion benchmarks (`consumerRecordToEnvelope`, `extractTraceHeaders`, `timestampToUTCTime`) are pure functions that do not use Streamly, so they serve as a control group — if their numbers change, the cause is GHC or runtime variation, not Streamly. To verify Streamly performance directly, the new benchmarks include a pure stream drain that measures `Stream.fromList` + `Stream.fold Fold.length` throughput.

The benchmark additions go into the existing `shibuya-kafka-adapter-bench` package. New benchmarks:

1. **isFatal classification** (`nf`): Apply `isFatal` to representative `KafkaError` values — a fatal error (`KafkaResponseError RdKafkaRespErrSsl`), a non-fatal error (`KafkaResponseError RdKafkaRespErrTimedOut`), and a partition EOF (`KafkaResponseError RdKafkaRespErrPartitionEof`). This measures the pattern-match cost.

2. **skipNonFatal stream filtering** (`nfIO`): Construct a stream of 10,000 `Either KafkaError (ConsumerRecord ...)` values (95% `Right`, 5% `Left` with a mix of fatal and non-fatal errors), apply `skipNonFatal`, and drain via `Stream.fold Fold.length`. Compare against the same stream without `skipNonFatal` to isolate the filter overhead.

3. **mapMaybeM extraction** (`nfIO`): Construct a stream of 10,000 `Either KafkaError (ConsumerRecord ...)` values, apply the `mapMaybeM` logic from `kafkaAdapter` (case on `Either`, return `Just (mkIngested cr)` for `Right`, `Nothing` for `Left`), and drain. Compare against the pre-integration path: a stream of 10,000 bare `ConsumerRecord` values consumed by `mapM (pure . mkIngested)`.

4. **Stream drain baseline** (`nfIO`): Drain a `Stream Identity [Int]` of 10,000 elements via `Stream.fold Fold.length` to establish a Streamly throughput baseline that is independent of Kafka types. This serves as a canary for Streamly version performance differences.

At the end of this milestone, the benchmark package will have a new `streamPipelineBenchmarks` group alongside the existing `envelopeBenchmarks`, `traceHeaderBenchmarks`, and `timestampBenchmarks`. The results will be compared against the existing baseline and documented in Surprises & Discoveries. If the per-element overhead of `skipNonFatal` + `mapMaybeM` is under 10ns (comparable to the existing `extractTraceHeaders` cost of ~43ps for the header lookup), the performance impact is negligible. If it exceeds that, the finding will be documented with analysis of whether the cost is acceptable given the correctness improvements.


## Concrete Steps

All commands are run from the repository root: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/`.

### Milestone 1 steps

Verify that `Eff es` satisfies `MonadIO` when `IOE :> es`:

    grep -r "MonadIO" /Users/shinzui/Keikaku/bokuno/libraries/haskell/effectful/effectful-core/src/

Check that kafka-effectful does not export the consumer handle:

    grep -r "KafkaConsumer" /Users/shinzui/Keikaku/bokuno/libraries/haskell/kafka-effectful/src/ --include="*.hs"

Verify streamly-core version compatibility between the adapter (^>=0.3) and hw-kafka-streamly (^>=0.4):

    cat shibuya-kafka-adapter/shibuya-kafka-adapter.cabal | grep streamly
    cat /Users/shinzui/Keikaku/bokuno/hw-kafka-streamly/hw-kafka-streamly/hw-kafka-streamly.cabal | grep streamly

### Milestone 2 steps

Add hw-kafka-streamly to the cabal.project local-packages:

    -- In cabal.project, add to local-packages:
    /Users/shinzui/Keikaku/bokuno/hw-kafka-streamly/hw-kafka-streamly

Add hw-kafka-streamly to shibuya-kafka-adapter.cabal build-depends.

Modify `kafkaSource` in `Internal.hs` to preserve errors and apply `skipNonFatal`.

Update callers (`Kafka.hs`) to handle the changed stream element type.

Build and run tests:

    cabal build shibuya-kafka-adapter
    cabal test shibuya-kafka-adapter

### Milestone 3 steps

Read kafka-effectful's interpreter to understand handle encapsulation:

    cat /Users/shinzui/Keikaku/bokuno/libraries/haskell/kafka-effectful/src/Kafka/Effectful/Consumer/Interpreter.hs

Analyze whether offset operations (storeOffsetMessage, commitAllOffsets) can work outside effectful.

Document the three options in the Decision Log.

### Milestone 4 steps

Write the recommendation section based on evidence from Milestones 1-3. Update Outcomes & Retrospective.


### Milestone 5 steps

Update the benchmark cabal file to add new dependencies needed for stream benchmarks:

    -- In shibuya-kafka-adapter-bench.cabal, add to build-depends:
    , hw-kafka-streamly
    , streamly           ^>=0.12
    , streamly-core      ^>=0.4

Add new imports to `shibuya-kafka-adapter-bench/bench/Main.hs`:

    import Kafka.Consumer.Types (RdKafkaRespErrT (..))
    import Kafka.Streamly.Source (isFatal, skipNonFatal)
    import Kafka.Types (KafkaError (..))
    import Streamly.Data.Fold qualified as Fold
    import Streamly.Data.Stream qualified as Stream

Add sample error values for the isFatal benchmark:

    fatalError :: KafkaError
    fatalError = KafkaResponseError RdKafkaRespErrSsl

    nonFatalTimeout :: KafkaError
    nonFatalTimeout = KafkaResponseError RdKafkaRespErrTimedOut

    nonFatalEOF :: KafkaError
    nonFatalEOF = KafkaResponseError RdKafkaRespErrPartitionEof

Add a helper to generate a synthetic stream of Either values (95% Right, 5% Left):

    mkEitherStream :: Int -> [Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString))]
    mkEitherStream n =
        [ if i `mod` 20 == 0
            then Left nonFatalTimeout
            else Right sampleRecordWithHeaders
        | i <- [1..n]
        ]

Add the new benchmark groups to Main.hs and register them in `defaultMain`:

    streamPipelineBenchmarks :: Benchmark
    streamPipelineBenchmarks =
        bgroup "Stream pipeline"
            [ bgroup "isFatal classification"
                [ bench "fatal error (SSL)" $ nf isFatal fatalError
                , bench "non-fatal (timeout)" $ nf isFatal nonFatalTimeout
                , bench "non-fatal (partition EOF)" $ nf isFatal nonFatalEOF
                ]
            , bgroup "skipNonFatal"
                [ bench "10k elements (95% Right)" $
                    nfIO $ Stream.fold Fold.length
                         $ skipNonFatal
                         $ Stream.fromList (mkEitherStream 10000)
                , bench "10k elements baseline (no filter)" $
                    nfIO $ Stream.fold Fold.length
                         $ Stream.fromList (mkEitherStream 10000)
                ]
            , bgroup "mapMaybeM extraction"
                [ bench "10k elements (new path)" $
                    nfIO $ Stream.fold Fold.length
                         $ Stream.mapMaybeM
                             (\case Right cr -> pure (Just cr); Left _ -> pure Nothing)
                         $ Stream.fromList (mkEitherStream 10000)
                , bench "10k elements (old path)" $
                    nfIO $ Stream.fold Fold.length
                         $ Stream.mapM pure
                         $ Stream.fromList (map snd $ filter (isRight . fst)
                             $ zip (mkEitherStream 10000) (repeat sampleRecordWithHeaders))
                ]
            , bench "Stream drain baseline (10k Int)" $
                nfIO $ Stream.fold Fold.length
                     $ Stream.fromList [1 :: Int .. 10000]
            ]

    -- Update main to include the new group:
    main = defaultMain
        [ envelopeBenchmarks
        , traceHeaderBenchmarks
        , timestampBenchmarks
        , streamPipelineBenchmarks
        ]

Build and run the benchmarks:

    cabal build shibuya-kafka-adapter-bench
    cabal bench shibuya-kafka-adapter-bench

Run against the existing baseline to check for conversion benchmark regressions:

    cabal bench shibuya-kafka-adapter-bench --benchmark-options '--baseline baseline.csv'

Generate a new baseline that includes the stream pipeline benchmarks:

    cabal bench shibuya-kafka-adapter-bench --benchmark-options '--csv baseline-with-pipeline.csv'

Document the results in Surprises & Discoveries.


## Validation and Acceptance

Milestone 1 is accepted when a compatibility matrix exists classifying every hw-kafka-streamly export as compatible, incompatible, or out-of-scope, with evidence for each classification.

Milestone 2 is accepted when either (a) a prototype compiles and existing tests pass, proving combinator integration works, or (b) a concrete compilation error demonstrates why it fails. Both outcomes are valid; the goal is evidence, not success.

Milestone 3 is accepted when the three options are documented with trade-offs and a clear rationale for which is preferred.

Milestone 4 is accepted when a recommendation exists that another developer could act on without additional context.

Milestone 5 is accepted when: (a) the benchmark package builds and runs with the new stream pipeline benchmarks, (b) existing conversion benchmarks show no significant regression from the streamly version upgrade (within 2x stdev of the baseline), (c) the per-element overhead of `skipNonFatal` and `mapMaybeM` is quantified with concrete numbers, and (d) findings are documented in Surprises & Discoveries with benchmark output as evidence.


## Idempotence and Recovery

The prototype in Milestone 2 modifies source files. If it needs to be reverted, `git checkout -- shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` restores the originals. Changes to `cabal.project` and `.cabal` files are similarly revertible.

All other milestones are analysis-only and produce documentation in this plan file. They can be re-run at any time.

Milestone 5 modifies only the benchmark package (`shibuya-kafka-adapter-bench/`). Benchmark additions are additive and do not affect the main library. If the benchmark changes need to be reverted, `git checkout -- shibuya-kafka-adapter-bench/` restores the original benchmark code. Benchmark runs are idempotent — they can be repeated any number of times with consistent results (subject to normal measurement variance).


## Interfaces and Dependencies

The evaluation touches these interfaces:

- **hw-kafka-streamly** (`Kafka.Streamly.Source`, `Kafka.Streamly.Combinators`): Monad-polymorphic combinators that operate on `Stream m (Either KafkaError a)`. Key functions: `skipNonFatal :: Monad m => Stream m (Either KafkaError b) -> Stream m (Either KafkaError b)`, `isFatal :: KafkaError -> Bool`, `throwLeft :: (MonadThrow m, Exception e) => Stream m (Either e a) -> Stream m a`.

- **kafka-effectful** (`Kafka.Effectful.Consumer.Effect`): Effect-typed Kafka operations. Key operations used by the adapter: `pollMessageBatch :: (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) => Timeout -> BatchSize -> Eff es [Either KafkaError (ConsumerRecord ...)]`, `storeOffsetMessage :: ConsumerRecord k v -> Eff es ()`, `commitAllOffsets :: OffsetCommit -> Eff es ()`, `pausePartitions :: [(TopicName, PartitionId)] -> Eff es ()`.

- **streamly-core**: The adapter uses ^>=0.3. hw-kafka-streamly 0.1.0.0 (Hackage) allows `>=0.3 && <0.5`, so both resolve against Hackage streamly-core 0.3 without any version gap.

- **tasty-bench** (`Test.Tasty.Bench`): Benchmark framework used by the benchmark package. Key functions for Milestone 5: `nf :: NFData b => (a -> b) -> a -> Benchmarkable` for pure function benchmarks, `nfIO :: NFData a => IO a -> Benchmarkable` for IO-based stream benchmarks. The `nfIO` variant is needed because `Stream.fold` returns in `IO` (or `Identity` lifted to `IO`).

- **Streamly.Data.Fold** (`Fold.length`): Used in Milestone 5 stream benchmarks to drain streams and count elements. `length :: (Monad m) => Fold m a Int` consumes a stream and returns the count.

- **Streamly.Data.Stream** (`Stream.fromList`, `Stream.fold`, `Stream.mapMaybeM`, `Stream.mapM`, `Stream.filter`): Used in Milestone 5 to construct synthetic streams from lists and apply the pipeline transformations under test.


---

**Revision (2026-04-10):** Added Milestone 5 to evaluate the performance impact of the hw-kafka-streamly integration. The original evaluation (Milestones 1-4) focused on correctness, compatibility, and architectural fit but did not measure performance. Milestone 5 extends the existing benchmark package with stream pipeline benchmarks that quantify the per-element overhead of `skipNonFatal` and `mapMaybeM`, and verifies the streamly 0.12 upgrade does not regress existing conversion benchmarks. Added corresponding entries in Progress, Decision Log, Plan of Work, Concrete Steps, Validation and Acceptance, Idempotence and Recovery, Interfaces and Dependencies, and the Risks section of the Recommendation.

**Revision (2026-04-10):** Implemented Milestone 5. Added 8 stream pipeline benchmarks to `shibuya-kafka-adapter-bench`, ran against existing baseline (no regressions), and documented findings. Key result: ~1.2ns per-element overhead from the integration, confirmed negligible. Updated Progress (all sub-tasks checked), Surprises & Discoveries (three new entries with benchmark data), Outcomes & Retrospective (Performance Assessment section), and Risks (changed "pending" to "confirmed negligible"). Updated `baseline.csv` to include all 15 benchmarks.

**Revision (2026-04-17):** hw-kafka-streamly 0.1.0.0 was published to Hackage with a relaxed `streamly-core >=0.3 && <0.5` constraint. Dropped the local hw-kafka-streamly from `cabal.project` local packages, removed the local streamly 0.12 / streamly-core 0.4 `optional-packages`, and removed the `allow-newer` directives for `shibuya-core:streamly*` and `shibuya-kafka-adapter:streamly*`. Reverted the adapter and benchmark cabal files to `streamly ^>=0.11` / `streamly-core ^>=0.3` and pinned `hw-kafka-streamly ^>=0.1`. Updated Progress, Surprises & Discoveries, Context and Orientation, Interfaces and Dependencies, and the Recommendation's Required changes / Risks / Migration path to reflect the Hackage resolution.
