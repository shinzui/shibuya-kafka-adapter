# Propagate fatal Kafka errors through the adapter

Intention: intention_01khv57nhzesc9hx46f9bz0vbq

MasterPlan: docs/masterplans/1-0.1.0.0-release-prep.md

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this work, a `shibuya-kafka-adapter` consumer whose broker connection fails
in a way that cannot be recovered (for example, an SSL handshake failure, an
authentication failure, or an invalid broker configuration) will stop its processor
and surface a `KafkaError` to the caller, instead of silently looking healthy
forever. The caller observes the failure by receiving a `Left err` from the
`runError @KafkaError` scope around `runApp`, matching the existing Shibuya pattern
for reporting unrecoverable adapter failures.

In the current implementation (as of 2026-04-18), the relevant code in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` reads:

    let messageSource =
            Stream.mapMaybeM
                ( \case
                    Right cr -> pure (Just (mkIngested cr))
                    Left _err -> pure Nothing
                )
                (kafkaSource config)

The upstream `kafkaSource` is:

    kafkaSource config =
        skipNonFatal $
            Stream.repeatM pollBatch
                & Stream.concatMap Stream.fromList

`skipNonFatal` (from `hw-kafka-streamly`, module `Kafka.Streamly.Source`) drops
every `KafkaError` for which `isFatal` returns `False` (poll timeouts and partition
EOFs, plus the full list in `isFatal`'s source). Any `Left err` that reaches the
adapter's `mapMaybeM` is therefore a fatal error by construction — but the current
`mapMaybeM` discards it. The stream then keeps polling indefinitely against a dead
connection.

The fix has three parts: surface fatal errors, tighten an unused effect
constraint, and document the one user-visible behavior that a casual reader might
otherwise assume incorrectly (that `AckHalt` automatically resumes the paused
partition). Together these changes bring the adapter's error semantics in line
with the `shibuya-pgmq-adapter` sibling, which does propagate its backing errors.

To verify the outcome, a contributor writes or adapts an integration test that
injects a fatal error and observes the processor failing cleanly, and the library
still compiles with all existing tests green.


## Milestones

### Milestone 1: Read and internalize the existing error plumbing

Before editing code, read three files to understand the current shape:

* `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` — the `kafkaAdapter`
  function and its `mapMaybeM`.
* `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs` — `kafkaSource`,
  `mkIngested`, `mkAckHandle`.
* `/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly/hw-kafka-streamly/src/Kafka/Streamly/Source.hs`
  for the exact definition of `isFatal` and `skipNonFatal`. Understanding which
  errors are considered fatal is required to write a meaningful test.

Also read
`/Users/shinzui/Keikaku/bokuno/kafka-effectful/src/Kafka/Effectful/Consumer/Effect.hs`
and its interpreter in the sibling `Interpreter.hs`: note that `pollMessageBatch`
returns `[Either KafkaError ...]` without throwing, while `storeOffsetMessage`,
`pausePartitions`, and `commitAllOffsets` all throw via `Error KafkaError`. This
difference is what motivates the constraint-tightening in Milestone 3.

At the end of this milestone the contributor can state, in a sentence, why the
`Error KafkaError :> es` constraint on `kafkaSource` is not load-bearing (because
`pollMessageBatch` does not throw; errors are in-band `Left` values).

### Milestone 2: Surface fatal errors from the stream

Change the `mapMaybeM` in `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` so
that a `Left err` that survives `skipNonFatal` is thrown via the `Error KafkaError`
effect instead of being silently dropped. The effect is already required by
`kafkaAdapter`'s type signature:

    kafkaAdapter ::
        (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
        KafkaAdapterConfig ->
        Eff es (Adapter es (Maybe ByteString))

The new shape:

    import Effectful.Error.Static (Error, throwError)

    let messageSource =
            Stream.mapMaybeM
                ( \case
                    Right cr -> pure (Just (mkIngested cr))
                    Left err -> throwError err
                )
                (kafkaSource config)

`throwError err` inside `Stream.mapMaybeM` aborts the stream computation and the
error escapes to the nearest `runError @KafkaError` scope, which the caller
established around `runKafkaConsumer` (see the jitsurei examples in
`shibuya-kafka-adapter-jitsurei/app/`).

Update the `Message Lifecycle` section of the Haddock at the top of
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` to state that fatal broker
errors terminate the stream and surface as `KafkaError` via the `Error` effect.

Build and run the existing tests to confirm nothing regresses:

    cabal build shibuya-kafka-adapter
    cabal test shibuya-kafka-adapter

The existing `IntegrationTest.hs` does not exercise fatal-error paths, so the
suite should pass without modification.

### Milestone 3: Tighten the `Error KafkaError` constraint on `kafkaSource`

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`, the type of
`kafkaSource` is currently:

    kafkaSource ::
        (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
        KafkaAdapterConfig ->
        Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))

The body uses only `pollMessageBatch`, which does not require the `Error` effect.
Drop the constraint:

    kafkaSource ::
        (KafkaConsumer :> es, IOE :> es) =>
        KafkaAdapterConfig ->
        Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))

Keep the constraint on `mkAckHandle` and `mkIngested` — those functions call
`storeOffsetMessage` and `pausePartitions`, both of which do throw via `Error
KafkaError`.

Rebuild and retest:

    cabal build shibuya-kafka-adapter
    cabal test shibuya-kafka-adapter

### Milestone 4: Document AckHalt partition-pause semantics

Add a paragraph to the module-level Haddock in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` that states, in plain prose,
that `AckHalt` pauses the originating partition via `pausePartitions` and that the
partition is not automatically resumed within the current consumer session. A new
consumer session (a new call to `runKafkaConsumer`) starts with no paused
partitions, so resumption happens implicitly on restart but not mid-session.

This is not a behavior change — it is documentation of existing behavior that a
user cannot infer from the types alone. Place the paragraph near the existing
`Message Lifecycle` section.

### Milestone 5: Decide and document shutdown-commit error handling

The `shutdown` action of `kafkaAdapter` currently is:

    shutdown = do
        liftIO $ atomically $ writeTVar shutdownVar True
        commitAllOffsets OffsetCommit

If the caller invokes `shutdown` after the `KafkaConsumer` effect scope has already
been torn down (for example, a handler that stores `shutdown` in an `IORef` and
calls it from outside `runKafkaConsumer`), `commitAllOffsets` will throw a
`KafkaError` for a consumer that is no longer valid.

Decide one of three behaviors and implement it. The recommended choice for this
plan is to leave the throw in place and document the invariant: callers must call
`shutdown` while the `KafkaConsumer` scope is still active. The rationale lives in
the Decision Log. The alternative (catching the error with `catchError`) changes
observable behavior during happy-path shutdown and is not justified without a
user-reported incident.

Add a sentence to the Haddock on `kafkaAdapter` stating the invariant: `shutdown`
must be invoked while the `KafkaConsumer` effect is still in scope.

### Milestone 6: Exercise the fatal-error path in tests

Add a new test case to
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs` that exercises
the surfacing of a fatal error. Direct injection of a fatal broker error is hard
against a real Redpanda broker. The two viable approaches are:

1. Configure an invalid broker address (for example, `localhost:1`) so that
   `pollMessageBatch` returns a `KafkaBrokerTransportFailure` or similar. Confirm
   the test observes this as a `Left err` from the `runError @KafkaError` scope
   rather than hanging. Use a short timeout so the test does not wait for
   rebalance retries.
2. Write a smaller unit test in `ConvertTest.hs` (or a new `AdapterTest.hs`) that
   constructs a stream directly containing a `Left fatalErr`, wraps it through the
   same `mapMaybeM` logic, and asserts `runError` yields `Left fatalErr`. This is
   a white-box test of the error-propagation code path and does not need a broker.

Prefer option 2 for speed and reliability. If the `mapMaybeM` logic is buried
inside `kafkaAdapter` and not independently callable, refactor it into a small
named helper (for example, `ingestedStream` in `Internal.hs`) that both
`kafkaAdapter` and the test can call. Refactor in place; this is a 3-line
extraction.

Run the test:

    cabal test shibuya-kafka-adapter

Expected output: the new test case passes, and the existing integration tests
still pass when the Redpanda broker is running (started via `process-compose up`).


## Progress

- [x] Milestone 1: Read `Kafka.hs`, `Internal.hs`, `hw-kafka-streamly/Source.hs`,
      and `kafka-effectful` consumer effect & interpreter. Confirmed that
      `pollMessageBatch` returns `[Either KafkaError ...]` without throwing —
      errors are in-band, so `Error KafkaError :> es` on `kafkaSource` is not
      load-bearing. (2026-04-18)
- [x] Milestone 2: Replaced `mapMaybeM` `Left _` drop with `throwError err` in
      `kafkaAdapter`. (2026-04-18)
- [x] Milestone 2: Added a dedicated `Fatal Error Propagation` section to the
      module-level Haddock in `Shibuya.Adapter.Kafka` stating that fatal broker
      errors terminate the stream and surface via the `Error KafkaError` effect.
      (2026-04-18)
- [x] Milestone 2: `cabal build all` passes. (2026-04-18)
- [x] Milestone 3: Dropped `Error KafkaError :> es` from `kafkaSource` in
      `Internal.hs`. Kept on `mkIngested` and `mkAckHandle`. (2026-04-18)
- [x] Milestone 3: Rebuild passes; no regressions. (2026-04-18)
- [x] Milestone 4: Added `AckHalt Partition Pause Semantics` paragraph to the
      module-level Haddock. (2026-04-18)
- [x] Milestone 5: Added shutdown invariant sentence to `kafkaAdapter` Haddock.
      (2026-04-18)
- [x] Milestone 6: Extracted `ingestedStream` helper in `Internal.hs`,
      parameterized over the record-wrapping function so the test does not need
      to stand up a `KafkaConsumer` interpreter. Exposed
      `Shibuya.Adapter.Kafka.Internal` in the cabal library (moved from
      `other-modules` to `exposed-modules`) so the test suite can import it.
      (2026-04-18)
- [x] Milestone 6: Added `Shibuya.Adapter.Kafka.AdapterTest` with two white-box
      test cases asserting that `runError` yields `Left (_, fatalErr)` for a
      synthetic fatal input, and that the stream aborts on the first fatal
      `Left` without forcing later elements. (2026-04-18)
- [x] Milestone 6: Full test suite (23 tests) passes against a running Redpanda
      broker. (2026-04-18)


## Surprises & Discoveries

- `Effectful.Error.Static.runError` returns `Either (CallStack, e) a`, not
  `Either e a`. The call stack is attached to every thrown error. The initial
  version of the white-box test compared `show`-ed values and failed because the
  actual value was rendered as
  `([(\"throwError\", SrcLoc {...})], KafkaBadConfiguration)`. Resolved by
  destructuring `Left (_cs, err)` and using `Eq KafkaError` directly. (2026-04-18)

- `Shibuya.Adapter.Kafka.Internal` was previously listed in `other-modules` of
  the library stanza, so the test suite (which depends on the library) could
  not import it. Extracting `ingestedStream` into `Internal.hs` required
  promoting the module to `exposed-modules`. The module already documented
  itself as "not part of the public API" at the Haddock level, which matches
  the common Haskell `.Internal` convention. (2026-04-18)

- Test approach chosen: a parameterized `ingestedStream` that takes the
  record-wrapping function as an argument. This keeps the helper's effect
  constraints minimal (`Error KafkaError :> es` only), so the test does not
  need to provide a `KafkaConsumer` interpreter at all. Integration option 1
  from the plan (invalid broker address) was not needed. (2026-04-18)


## Decision Log

- Decision: surface fatal errors via `throwError` rather than terminating the
  stream silently. Rationale: a stream that ends cleanly looks the same as one
  whose topic drained. A thrown error is observably distinct at the `runError`
  boundary, which is where Shibuya callers already handle adapter failures (see
  `shibuya-pgmq-adapter` for the equivalent pattern). Date: 2026-04-18.

- Decision: leave `commitAllOffsets` in `shutdown` able to throw rather than
  wrapping it in `catchError`. Rationale: silencing the error would mask real
  commit failures during normal shutdown. The edge case (calling `shutdown`
  outside the `KafkaConsumer` scope) is caller error and is documented as an
  invariant. If a production incident demonstrates a need, the catching behavior
  can be added in a future release with a clear motivation. Date: 2026-04-18.

- Decision: document but do not implement auto-resume after `AckHalt`.
  Rationale: programmatic resume is new adapter surface (a method on `Adapter` or
  a side channel from the handler). It is scope creep for a point release and has
  no user-reported need yet. Document the existing behavior so callers know to
  restart the consumer to resume the partition. Date: 2026-04-18.

- Decision: parameterize `ingestedStream` over the record-wrapping function
  rather than hard-coding `mkIngested`. Rationale: the helper's only genuine
  effect requirement is `Error KafkaError :> es` for `throwError`. Hard-coding
  `mkIngested` would force the constraint set to also carry `KafkaConsumer :> es`
  (inherited from `mkAckHandle`), which in turn would force the white-box test
  to stand up a `KafkaConsumer` interpreter even though the test exercises only
  the `Left` branch. Parameterization is a trivial signature change that makes
  the helper independently unit-testable. Date: 2026-04-18.

- Decision: promote `Shibuya.Adapter.Kafka.Internal` from `other-modules` to
  `exposed-modules` in the library cabal stanza. Rationale: the test suite
  depends on the library and needs to import `ingestedStream`. The module
  already self-documents as "not part of the public API and may change without
  notice", which matches the conventional Haskell `.Internal` pattern and
  preserves the intent that external consumers avoid the module. Date:
  2026-04-18.


## Outcomes & Retrospective

Implemented on 2026-04-18.

Delivered: fatal Kafka errors (as defined by `hw-kafka-streamly`'s `isFatal`)
that reach the adapter's ingestion stage are now thrown through the
`Error KafkaError` effect instead of being silently dropped. A Shibuya consumer
whose broker connection fails unrecoverably — for example via SSL handshake
failure, authentication failure, or invalid configuration — now stops cleanly
and the caller observes a `Left err` from the `runError @KafkaError` scope,
matching the `shibuya-pgmq-adapter` pattern.

Also delivered as part of the same change set:

* `kafkaSource` no longer carries the `Error KafkaError :> es` constraint,
  since `pollMessageBatch` returns errors in-band rather than throwing. The
  tighter signature documents intent.
* Module-level Haddock now documents the fatal-error propagation contract, the
  partition-pause semantics of `AckHalt` (no mid-session auto-resume), and the
  caller-side invariant that `shutdown` must be invoked while the
  `KafkaConsumer` scope is still active.
* A `ingestedStream` helper was extracted into `Shibuya.Adapter.Kafka.Internal`
  and exposed for testing. Two new white-box test cases in
  `Shibuya.Adapter.Kafka.AdapterTest` prove fatal-error propagation without
  needing a real broker and in under 10 milliseconds combined.

Acceptance against the plan: full suite (23 tests, including the 5 Redpanda
integration tests and the 2 new fatal-propagation tests) passes. No
observable behavior changes for non-fatal paths (timeouts, partition EOFs,
normal shutdown).

What was discovered along the way: `Effectful.Error.Static.runError` yields
`Either (CallStack, e) a` rather than `Either e a`; the call stack is part of
the public failure surface and is not hidden behind a pattern synonym. Tests
that compare error values need to destructure the tuple.

What remains: the plan noted a future option to add programmatic resume after
`AckHalt`. That is deliberately out of scope — no user-reported need, and it
would expand the `Adapter` surface. Documented as existing behavior only.
