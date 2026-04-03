# Implement initial shibuya-kafka-adapter

Intention: intention_01km3c2s7xeamb7gkfjkve90ma

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this work, a user can connect Shibuya's supervised queue processing framework
to Apache Kafka topics via a `kafkaAdapter`. They write a `Handler es (Maybe ByteString)`,
wire it into `runApp`, and Shibuya handles supervision, metrics, concurrency, and graceful
shutdown -- while the Kafka adapter owns all Kafka-specific semantics: polling, offset
commits, partition awareness, and optional dead-letter production.

The main package includes a test suite for unit and integration tests (run against a
Redpanda broker via rpk). A second package (`shibuya-kafka-adapter-jitsurei`) provides
extensive runnable examples that demonstrate real-world adapter usage patterns --
multi-topic consumption, graceful shutdown, offset management, and multi-partition
processing -- serving as both documentation and a validation harness.


## Progress

### Milestone 1: Project scaffolding
- [x] Create `cabal.project` at repo root referencing both packages (2026-04-02)
- [x] Create `shibuya-kafka-adapter.cabal` with library and test-suite stanzas (2026-04-02)
- [x] Create `shibuya-kafka-adapter-jitsurei.cabal` with executable stanzas (2026-04-02)
- [x] Create module stubs for adapter library and test suite (2026-04-02)
- [x] Create module stubs for jitsurei examples (2026-04-02)
- [x] Update `flake.nix` to include `rdkafka` native dependency and `process-compose` (2026-04-02)
- [x] Create `process-compose.yaml` at repo root for rpk container management (2026-04-02)
- [x] Verify `cabal build all` compiles the skeleton (2026-04-02)

### Milestone 2: Configuration and type conversion
- [x] Implement `Shibuya.Adapter.Kafka.Config` with `KafkaAdapterConfig` and related types (2026-04-02)
- [x] Implement `Shibuya.Adapter.Kafka.Convert` mapping `ConsumerRecord` to `Envelope` (2026-04-02)
- [x] Unit test conversion functions in main package test suite (pure tests, no broker needed) (2026-04-02)

### Milestone 3: Core adapter implementation
- [x] Implement `kafkaSource` polling stream in `Internal.hs` (2026-04-02)
- [x] Implement `mkAckHandle` for Kafka offset commit semantics (2026-04-02)
- [x] Implement `kafkaAdapter` constructor in `Shibuya.Adapter.Kafka` (2026-04-02)
- [x] Implement shutdown logic (consumer close + offset flush) (2026-04-02)
- [x] Verify compilation with `cabal build all` (2026-04-02)

### Milestone 4: Integration tests (main package test suite)
- [x] Implement `Kafka.TestEnv` with broker setup, topic helpers, effectful integration (2026-04-02)
- [x] Test: basic produce-then-consume via adapter stream (2026-04-02)
- [x] Test: offset commit verification (consume, ack, restart, verify no re-delivery) (2026-04-02)
- [x] Test: multi-partition message distribution and partition field population (2026-04-02)
- [x] Test: batch polling efficiency (2026-04-02)
- [x] Test: graceful shutdown (adapter.shutdown stops stream, flushes offsets) (2026-04-02)
- [ ] Run full test suite against rpk-managed Redpanda: `process-compose up` then `cabal test`

### Milestone 5: Jitsurei examples
- [x] Implement `basic-consumer` example: single-topic consume-and-print (2026-04-02)
- [x] Implement `multi-topic` example: two adapters under independent consumer sessions (2026-04-02)
- [x] Implement `offset-management` example: demonstrate offset commit lifecycle and restart behavior (2026-04-02)
- [x] Implement `multi-partition` example: partition-aware processing with keyed messages (2026-04-02)
- [ ] Verify all examples run against rpk-managed Redpanda


## Surprises & Discoveries

- `cabal.project` needed absolute paths for local dependencies (shibuya-core, kafka-effectful, hw-kafka-client) and `source-repository-package` stanzas for hs-opentelemetry (transitive dependency of shibuya-core). Date: 2026-04-02.
- Record dot syntax (`adapter.source`, `ingested.ack.finalize`) doesn't work across package boundaries for types defined with `NoFieldSelectors`. Use explicit record pattern matching (`Adapter{source}`, `Ingested{envelope, ack = AckHandle finalize}`) instead. Date: 2026-04-02.


## Decision Log

- Decision: Use two packages -- `shibuya-kafka-adapter` (library + tests) and `shibuya-kafka-adapter-jitsurei` (extensive runnable examples).
  Rationale: Tests belong in the main package where they can exercise internals and run in CI. The jitsurei package is a separate concern: extensive, runnable examples that demonstrate real-world usage patterns against a live broker. This follows the `hw-kafka-client-jitsurei` naming convention and mirrors how hw-kafka-client separates its examples into executables.
  Date: 2026-04-02

- Decision: Message payload type is `Maybe ByteString` (the Kafka value field).
  Rationale: Kafka messages have key and value, both `Maybe ByteString`. The value is the natural "payload" in Shibuya's model. The key is captured as the partition field in the Envelope for routing. Users can `fmap` over the Envelope to deserialize as needed.
  Date: 2026-04-02

- Decision: No `Lease` for Kafka adapter.
  Rationale: Shibuya's Lease type models temporary ownership (SQS visibility timeout, DB locks). Kafka has no visibility timeout mechanism -- once polled, messages stay consumed for the session. The `Shibuya.Core.Lease` module docs explicitly note "Kafka adapters won't use this."
  Date: 2026-04-02

- Decision: Use `noAutoOffsetStore` with manual `storeOffsetMessage` + auto-commit for offset management.
  Rationale: This is the standard Kafka consumer pattern for at-least-once delivery. Disabling auto-store means polled messages aren't automatically marked as consumed. On `AckOk`, we call `storeOffsetMessage` to mark the offset ready. The consumer's auto-commit (default 5s) batches the actual commits to the broker efficiently. On shutdown, we call `commitAllOffsets` to flush. This balances correctness with performance.
  Date: 2026-04-02

- Decision: `AckRetry` stores the offset (same as AckOk) in the initial version.
  Rationale: Kafka fundamentally cannot "un-read" a message within a consumer session. True per-message retry requires producing to a retry topic (adds Producer effect dependency and significant complexity). For the initial version, AckRetry stores the offset like AckOk. A future milestone can add retry-topic support. Document this limitation.
  Date: 2026-04-02

- Decision: `AckDeadLetter` without a configured DLQ topic stores the offset and logs a warning.
  Rationale: DLQ support requires a KafkaProducer effect, which adds complexity. For the initial version, if no DLQ is configured, dead-lettered messages are acknowledged (offset stored) and the decision is logged. A future milestone will add `kafkaAdapterWithDlq` that requires KafkaProducer.
  Date: 2026-04-02

- Decision: `AckHalt` pauses the partition and does not store the offset.
  Rationale: This ensures the message will be re-consumed when the partition is resumed or the consumer restarts. Pausing the partition prevents further messages from that partition from being delivered, which aligns with Shibuya's halt semantics (stop processing to preserve ordering).
  Date: 2026-04-02

- Decision: Use tasty (+ tasty-hunit) as the test framework.
  Rationale: User preference. tasty provides composable test trees, `withResource` for resource lifecycle management (broker handles), and `--pattern` for selective test execution. tasty-hunit provides familiar assertion functions (`assertEqual`, `assertBool`).
  Date: 2026-04-02

- Decision: Require `Error KafkaError :> es` in the adapter constraint.
  Rationale: kafka-effectful interpreters require `Error KafkaError :> es`. Since the adapter operates within the `KafkaConsumer` effect scope, this constraint naturally propagates. The adapter surfaces Kafka errors through the effectful Error mechanism.
  Date: 2026-04-02


## Outcomes & Retrospective

### Completed (2026-04-02)

All 5 milestones implemented:

- **Library** (`shibuya-kafka-adapter`): 4 modules — `Config`, `Convert`, `Internal`, `Kafka` — implementing `kafkaAdapter` that produces a `Adapter es (Maybe ByteString)` from a `KafkaAdapterConfig`.
- **Pure tests**: 16 conversion tests pass (messageId, cursor, partition, timestamp, trace headers).
- **Integration tests**: 5 tests written (basic produce-consume, offset commit, multi-partition, batch polling, graceful shutdown). Require Redpanda broker to run.
- **Examples** (`shibuya-kafka-adapter-jitsurei`): 4 executables — `basic-consumer`, `multi-topic`, `offset-management`, `multi-partition`.

### Remaining

- Integration tests and examples need to be validated against a running Redpanda broker (`process-compose up`).
- `cabal-version: 3.14` is not supported by the installed `cabal-fmt`; downgraded to `3.12`.
- Record dot syntax (e.g., `adapter.source`) does not work across package boundaries for types defined with `NoFieldSelectors`; explicit pattern matching is required.


## Context and Orientation

### Repository State

This repository (`shibuya-kafka-adapter`) is a freshly bootstrapped Haskell project with:
- Nix flake for GHC 9.12 development environment
- treefmt + fourmolu for formatting
- Pre-commit hooks
- No source code or cabal files yet

### Key External Codebases

**Shibuya framework** (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/`)

A supervised queue processing framework built on effectful + streamly + NQE. Key types:

- `Adapter es msg` (`shibuya-core/src/Shibuya/Adapter.hs`): The interface we implement. Has three fields:
  - `adapterName :: Text` -- for logging/observability
  - `source :: Stream (Eff es) (Ingested es msg)` -- the message stream
  - `shutdown :: Eff es ()` -- graceful stop

- `Ingested es msg` (`shibuya-core/src/Shibuya/Core/Ingested.hs`): What handlers receive:
  - `envelope :: Envelope msg` -- message metadata + payload
  - `ack :: AckHandle es` -- acknowledgment handle
  - `lease :: Maybe (Lease es)` -- visibility timeout extension (not used for Kafka)

- `Envelope msg` (`shibuya-core/src/Shibuya/Core/Types.hs`): Message metadata:
  - `messageId :: MessageId` -- unique ID (Text)
  - `cursor :: Maybe Cursor` -- offset position
  - `partition :: Maybe Text` -- partition key
  - `enqueuedAt :: Maybe UTCTime` -- timestamp
  - `traceContext :: Maybe TraceHeaders` -- W3C trace headers
  - `payload :: msg` -- the message content

- `AckHandle es` (`shibuya-core/src/Shibuya/Core/AckHandle.hs`): `newtype AckHandle es = AckHandle { finalize :: AckDecision -> Eff es () }`

- `AckDecision` (`shibuya-core/src/Shibuya/Core/Ack.hs`): `AckOk | AckRetry RetryDelay | AckDeadLetter DeadLetterReason | AckHalt HaltReason`

The reference adapter implementation is `shibuya-pgmq-adapter` in the same monorepo. Our Kafka adapter follows its structure closely.

**kafka-effectful** (`/Users/shinzui/Keikaku/bokuno/libraries/haskell/kafka-effectful/`)

Effectful effects and interpreters for hw-kafka-client. Key API:

- `KafkaConsumer` effect with operations:
  - `pollMessage :: Timeout -> Eff es (ConsumerRecord (Maybe ByteString) (Maybe ByteString))`
  - `pollMessageBatch :: Timeout -> BatchSize -> Eff es [Either KafkaError (ConsumerRecord ...)]`
  - `commitOffsetMessage :: OffsetCommit -> ConsumerRecord k v -> Eff es ()`
  - `commitAllOffsets :: OffsetCommit -> Eff es ()`
  - `storeOffsetMessage :: ConsumerRecord k v -> Eff es ()`
  - `pausePartitions :: [(TopicName, PartitionId)] -> Eff es ()`
  - `assignment :: Eff es (Map TopicName [PartitionId])`

- `runKafkaConsumer :: (IOE :> es, Error KafkaError :> es) => ConsumerProperties -> Subscription -> Eff (KafkaConsumer : es) a -> Eff es a`

- Key types re-exported: `ConsumerRecord`, `TopicName`, `PartitionId`, `Offset`, `Timeout`, `BatchSize`, `BrokerAddress`, `ConsumerGroupId`, `Headers`, `Timestamp`, `KafkaError`

**hw-kafka-client** (`/Users/shinzui/Keikaku/hub/haskell/hw-kafka-client-project/`)

The underlying Kafka client binding to librdkafka. Relevant for test patterns:

- `process-compose.yaml`: Starts Redpanda with `rpk container start -n 1 --kafka-ports 9092`, shuts down with `rpk container purge`, readiness probe via `rpk cluster info`.
- `tests-it/Kafka/TestEnv.hs`: Test helpers using random prefixes for isolation, `KAFKA_TEST_BROKER` env var, hspec `beforeAll`/`afterAll` for resource lifecycle, MVar-based rebalance wait. (Note: hw-kafka-client uses hspec; our tests use tasty instead.)
- `ConsumerRecord` type: `{ crTopic, crPartition, crOffset, crTimestamp, crHeaders, crKey, crValue }`

### Terms

- **rpk**: Redpanda CLI tool. Can manage Redpanda containers (`rpk container start/stop/purge`) and Kafka-compatible clusters.
- **Redpanda**: Kafka-compatible streaming platform, lighter-weight for local testing.
- **Offset**: Sequential position in a Kafka partition. Consumers track progress by committing offsets.
- **Consumer Group**: Set of consumers that share partition assignment for a topic.
- **Rebalance**: When consumer group membership changes, partitions are redistributed among consumers.
- **effectful**: Haskell effect system library. Effects are declared as GADTs, dispatched via interpreters.
- **streamly**: High-performance streaming library for Haskell. Used by Shibuya for message pipelines.
- **NQE**: Actor/supervisor library used by Shibuya for process management.
- **Store vs Commit**: In Kafka, "store" marks an offset in the client's local state. "Commit" sends stored offsets to the broker. Auto-commit periodically commits all stored offsets.


## Plan of Work

### Milestone 1: Project scaffolding

Create the multi-package Cabal project structure and Nix infrastructure.

**At the end of this milestone**: `cabal build all` succeeds with empty module stubs. `process-compose up` starts a Redpanda broker accessible at `localhost:9092`.

Create `cabal.project` at the repo root listing both packages:
```
packages:
  shibuya-kafka-adapter
  shibuya-kafka-adapter-jitsurei
```

Create `shibuya-kafka-adapter/` directory with `shibuya-kafka-adapter.cabal`:
- Library stanza:
  - Exposed modules: `Shibuya.Adapter.Kafka`, `Shibuya.Adapter.Kafka.Config`, `Shibuya.Adapter.Kafka.Convert`
  - Other modules: `Shibuya.Adapter.Kafka.Internal`
  - Dependencies: `base`, `bytestring`, `containers`, `effectful-core`, `hw-kafka-client`, `kafka-effectful`, `shibuya-core`, `stm`, `streamly`, `streamly-core`, `text`, `time`
- Test-suite stanza (`shibuya-kafka-adapter-test`):
  - Unit tests (pure conversion tests) and integration tests (broker-dependent)
  - Dependencies: `base`, `bytestring`, `effectful-core`, `tasty`, `tasty-hunit`, `hw-kafka-client`, `kafka-effectful`, `shibuya-core`, `shibuya-kafka-adapter`, `text`, `random`, `containers`, `stm`, `streamly`, `streamly-core`
  - Test helpers in `Kafka.TestEnv`
- GHC2024, same default-extensions as shibuya-pgmq-adapter

Create `shibuya-kafka-adapter-jitsurei/` directory with `shibuya-kafka-adapter-jitsurei.cabal` (examples package):
- Multiple executable stanzas, one per example scenario
- Dependencies: `base`, `bytestring`, `effectful-core`, `hw-kafka-client`, `kafka-effectful`, `shibuya-core`, `shibuya-kafka-adapter`, `text`
- Each executable is a self-contained, runnable demonstration of an adapter usage pattern

Create module stubs in each package with minimal exports.

Update `flake.nix`:
- Add `pkgs.rdkafka` to `nativeBuildInputs`
- Set `withProcessCompose = true` and add `pkgs.process-compose`

Create `process-compose.yaml` at repo root (copied from hw-kafka-client pattern):
```yaml
version: "0.5"
log_location: ./.dev/process-compose.log
log_level: debug

processes:
  redpanda:
    command: rpk container start -n 1 --kafka-ports 9092
    shutdown:
      command: rpk container purge
    readiness_probe:
      exec:
        command: "rpk cluster info"
      initial_delay_seconds: 5
      period_seconds: 5
      timeout_seconds: 5
      success_threshold: 1
      failure_threshold: 10
    availability:
      restart: on_failure
```

### Milestone 2: Configuration and type conversion

Implement the configuration types and the conversion from Kafka's `ConsumerRecord` to Shibuya's `Envelope`.

**At the end of this milestone**: Config types compile, and pure conversion tests pass.

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Config.hs`:

```haskell
data KafkaAdapterConfig = KafkaAdapterConfig
  { topics        :: ![TopicName]
  , pollTimeout   :: !Timeout
  , batchSize     :: !BatchSize
  , offsetReset   :: !OffsetReset
  }
```

We deliberately keep the config minimal. Consumer properties (brokers, group ID, etc.) are provided when the user runs `runKafkaConsumer` -- the adapter operates *within* the `KafkaConsumer` effect scope, not outside it. This follows kafka-effectful's design where the interpreter owns the consumer lifecycle.

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs`:

Define `consumerRecordToEnvelope`:
- `messageId`: `"{topic}-{partition}-{offset}"` (globally unique within a cluster)
- `cursor`: `CursorInt (fromIntegral offset)`
- `partition`: `Just (Text.pack (show partitionId))`
- `enqueuedAt`: Convert `Timestamp` to `UTCTime` if `CreateTime` or `LogAppendTime`
- `traceContext`: Extract `traceparent`/`tracestate` from `Headers`
- `payload`: The `crValue` field (`Maybe ByteString`)

Define `extractTraceHeaders`:
- Look for `traceparent` and `tracestate` keys in `Headers`
- Return `Maybe TraceHeaders`

In `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/ConvertTest.hs`:
- Test `consumerRecordToEnvelope` with a constructed `ConsumerRecord`
- Test `extractTraceHeaders` with various header combinations
- Test timestamp conversion edge cases
- Uses `tasty` + `tasty-hunit` for test structure and assertions

### Milestone 3: Core adapter implementation

Implement the adapter that bridges kafka-effectful's consumer to Shibuya's `Adapter` type.

**At the end of this milestone**: `kafkaAdapter` compiles and produces a valid `Adapter es (Maybe ByteString)`.

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`:

**`kafkaSource`**: Create a Streamly `Stream (Eff es) (ConsumerRecord ...)` by repeatedly calling `pollMessageBatch`. Skip `Left` (error) entries from the batch. Flatten the batch into individual records.

```haskell
kafkaSource ::
  (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
  KafkaAdapterConfig ->
  Stream (Eff es) (ConsumerRecord (Maybe ByteString) (Maybe ByteString))
```

**`mkAckHandle`**: Create an `AckHandle es` for a single `ConsumerRecord`. The finalize function:
- `AckOk` -> `storeOffsetMessage record`
- `AckRetry _` -> `storeOffsetMessage record` (see Decision Log for rationale)
- `AckDeadLetter _` -> `storeOffsetMessage record` (DLQ production deferred to future milestone)
- `AckHalt _` -> `pausePartitions [(crTopic, crPartition)]` (do NOT store offset)

```haskell
mkAckHandle ::
  (KafkaConsumer :> es, Error KafkaError :> es) =>
  ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
  AckHandle es
```

**`mkIngested`**: Combine `consumerRecordToEnvelope` and `mkAckHandle` to produce `Ingested es (Maybe ByteString)`. Lease is always `Nothing`.

```haskell
mkIngested ::
  (KafkaConsumer :> es, Error KafkaError :> es) =>
  ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
  Ingested es (Maybe ByteString)
```

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`:

**`kafkaAdapter`**: The public constructor.

```haskell
kafkaAdapter ::
  (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
  KafkaAdapterConfig ->
  Eff es (Adapter es (Maybe ByteString))
```

Implementation:
1. Create a `TVar Bool` for the shutdown signal.
2. Build the source stream: `kafkaSource config` piped through `fmap mkIngested`, wrapped with `takeUntilShutdown`.
3. Build shutdown action: set the TVar, then `commitAllOffsets OffsetCommit` to flush stored offsets.
4. Return `Adapter { adapterName, source, shutdown }`.

The adapter name should be `"kafka:" <> Text.intercalate "," (map unTopicName config.topics)`.

### Milestone 4: Integration tests (main package test suite)

Write integration tests in the main package that run against a real Redpanda broker.

**At the end of this milestone**: `process-compose up` + `cabal test shibuya-kafka-adapter` passes all tests.

In `shibuya-kafka-adapter/test/Kafka/TestEnv.hs`:

Adapt hw-kafka-client's TestEnv pattern for effectful:
- `testPrefix :: String` -- random 10-char prefix for isolation
- `brokerAddress :: BrokerAddress` -- from `KAFKA_TEST_BROKER` env or default `localhost:9092`
- `testTopic :: TopicName` -- `"{prefix}-topic"`
- `testGroupId :: ConsumerGroupId` -- from prefix
- `consumerProps :: ConsumerProperties` -- brokers + groupId + noAutoOffsetStore + callbacks
- `producerProps :: ProducerProperties` -- brokers + callbacks
- `testSubscription :: TopicName -> Subscription` -- topics + offsetReset Earliest
- Helper to produce messages via kafka-effectful's KafkaProducer
- Helper to consume N messages via the adapter stream
- Use `tasty` `withResource` for resource lifecycle (acquire broker handles before tests, release after)

In `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs`:

**Test: Basic produce-consume**
1. Create a unique topic (rpk topic create)
2. Produce 5 messages with known payloads
3. Create adapter, consume from stream
4. Verify all 5 messages received with correct payloads
5. Verify envelopes have correct messageId, cursor, partition fields

**Test: Offset commit verification**
1. Produce 3 messages
2. Consume all 3, AckOk each
3. Flush offsets (adapter shutdown)
4. Create new consumer in same group
5. Poll -- should get no messages (all committed)

**Test: Multi-partition distribution**
1. Create topic with 3 partitions
2. Produce messages with different keys
3. Verify partition field is populated in envelopes
4. Verify messages distributed across partitions

**Test: Batch polling**
1. Produce 20 messages
2. Configure adapter with batchSize 10
3. Consume all messages
4. Verify all 20 received

**Test: Graceful shutdown**
1. Start consuming from infinite-poll adapter
2. Call adapter.shutdown
3. Verify stream terminates
4. Verify committed offsets reflect processed messages

### Milestone 5: Jitsurei examples

Write runnable examples in `shibuya-kafka-adapter-jitsurei` that demonstrate real-world adapter usage patterns. Each example is a standalone executable.

**At the end of this milestone**: `process-compose up` + `cabal run <example>` works for each example, producing observable output to stdout.

**`basic-consumer`**: Minimal single-topic consumer. Subscribes to a topic, prints each message's envelope (messageId, partition, offset, payload), and AckOk's. Demonstrates the simplest possible adapter wiring.

**`multi-topic`**: Two adapters (e.g., "orders" and "events") running under `runApp` with supervision. Each has its own handler. Demonstrates multi-queue processing with independent handlers and `IgnoreFailures` strategy.

**`offset-management`**: Consumes N messages, shuts down, restarts in the same consumer group, and verifies no re-delivery. Demonstrates offset commit lifecycle and restart behavior.

**`multi-partition`**: Produces keyed messages to a multi-partition topic, consumes them, and prints the partition assignment for each message. Demonstrates partition-aware processing.


## Concrete Steps

### Milestone 1

**Working directory**: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`

1. Create `cabal.project`:
```
packages:
  shibuya-kafka-adapter
  shibuya-kafka-adapter-jitsurei
```

2. Create directory structure:
```bash
mkdir -p shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka
mkdir -p shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka
mkdir -p shibuya-kafka-adapter/test/Kafka
mkdir -p shibuya-kafka-adapter-jitsurei/app
```

3. Create `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal` (see Interfaces section for full content).

4. Create library module stubs:
- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` -- re-exports
- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Config.hs` -- empty config
- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs` -- empty convert
- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs` -- empty internal

5. Create test stubs in main package:
- `shibuya-kafka-adapter/test/Main.hs` -- tasty test main (imports and runs all test groups)
- `shibuya-kafka-adapter/test/Kafka/TestEnv.hs` -- empty env module
- `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/ConvertTest.hs` -- empty convert tests
- `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs` -- empty integration tests

6. Create `shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`.

7. Create example stubs:
- `shibuya-kafka-adapter-jitsurei/app/BasicConsumer.hs` -- minimal consumer
- `shibuya-kafka-adapter-jitsurei/app/MultiTopic.hs` -- multi-queue processing
- `shibuya-kafka-adapter-jitsurei/app/OffsetManagement.hs` -- offset lifecycle
- `shibuya-kafka-adapter-jitsurei/app/MultiPartition.hs` -- partition-aware processing

7. Update `flake.nix` to add `pkgs.rdkafka` to nativeBuildInputs and enable process-compose.

8. Create `process-compose.yaml` at repo root.

9. Verify: `cabal build all` should succeed.

Expected output:
```
Build profile: -w ghc-9.12.x ...
Building library for shibuya-kafka-adapter-0.1.0.0..
[1 of 4] Compiling ...
```

### Milestone 2

1. Implement `Config.hs` with `KafkaAdapterConfig`, `defaultConfig`.
2. Implement `Convert.hs` with `consumerRecordToEnvelope`, `extractTraceHeaders`, `timestampToUTCTime`.
3. Write `ConvertTest.hs` with pure tests.
4. Verify: `cabal build all && cabal test shibuya-kafka-adapter` (conversion tests pass).

### Milestone 3

1. Implement `Internal.hs` with `kafkaSource`, `mkAckHandle`, `mkIngested`.
2. Implement `Kafka.hs` public API with `kafkaAdapter`.
3. Verify: `cabal build all` succeeds.

### Milestone 4

1. Implement `TestEnv.hs` with broker helpers.
2. Implement `IntegrationTest.hs` tests one by one.
3. Start Redpanda: `process-compose up -d`
4. Run: `cabal test shibuya-kafka-adapter`
5. Clean up: `process-compose down`

Expected output:
```
Integration tests
  Basic produce-consume:  OK
  Offset commit:          OK
  Multi-partition:        OK
  Batch polling:          OK
  Graceful shutdown:      OK

All 5 tests passed
```

### Milestone 5

1. Implement each example executable in `shibuya-kafka-adapter-jitsurei/app/`.
2. Start Redpanda: `process-compose up -d`
3. Run each example:
   - `cabal run basic-consumer`
   - `cabal run multi-topic`
   - `cabal run offset-management`
   - `cabal run multi-partition`
4. Verify each prints expected output to stdout.

Expected output (basic-consumer):
```
[kafka:orders] Received message: messageId=orders-0-0 partition=0 offset=0 payload=...
[kafka:orders] AckOk
...
```


## Validation and Acceptance

1. **Compilation**: `cabal build all` succeeds with no warnings under `-Wall`.

2. **Pure tests**: `cabal test shibuya-kafka-adapter --test-option='-p Convert'` passes conversion tests without a broker.

3. **Integration tests**: With Redpanda running (`process-compose up`), `cabal test shibuya-kafka-adapter` passes all specs.

4. **Examples**: With Redpanda running, `cabal run basic-consumer`, `cabal run multi-topic`, etc. each produce expected output and exit cleanly.

5. **End-to-end verification**: A user can write:
```haskell
import Shibuya.App (runApp, mkProcessor)
import Shibuya.Adapter.Kafka (kafkaAdapter, defaultConfig)
import Kafka.Effectful.Consumer (runKafkaConsumer, consumerProps)

main :: IO ()
main = runEff
  . runError @KafkaError
  . runTracingNoop
  . runKafkaConsumer props sub
  $ do
      adapter <- kafkaAdapter (defaultConfig [TopicName "orders"])
      result <- runApp IgnoreFailures 100
        [ (ProcessorId "orders", mkProcessor adapter myHandler) ]
      ...
```

6. **Graceful shutdown**: After `adapter.shutdown`, the stream stops and offsets are flushed. Re-consuming in the same group does not re-deliver committed messages.


## Idempotence and Recovery

- Milestone 1 (scaffolding) can be re-run safely; creating files that already exist is harmless.
- `process-compose up` is idempotent (starts containers only if not running).
- Integration tests use random topic/group prefixes, so re-runs don't conflict with prior runs.
- If a test fails mid-suite, re-running the suite is safe (new prefix each run).
- `rpk container purge` fully removes the Redpanda container for a clean slate.


## Interfaces and Dependencies

### Libraries Used

| Library | Version | Purpose |
|---------|---------|---------|
| shibuya-core | ^>=0.1.0.0 | Adapter, Ingested, Envelope, AckHandle, AckDecision types |
| kafka-effectful | ^>=0.1 | KafkaConsumer effect, operations (pollMessageBatch, storeOffsetMessage, etc.) |
| hw-kafka-client | >=5.3 && <6 | ConsumerRecord, TopicName, BrokerAddress, Headers, KafkaError, config builders |
| effectful-core | ^>=2.6.1.0 | Eff monad, effect dispatch, Error effect |
| streamly | ^>=0.11 | Stream type, repeatM, filter, mapM, takeWhileM |
| streamly-core | ^>=0.3 | Stream.Prelude (parBuffered) |
| stm | ^>=2.5 | TVar for shutdown signal |
| bytestring | ^>=0.12 | ByteString (message payload type) |
| text | ^>=2.1 | Text (messageId, partition key) |
| time | ^>=1.14 | UTCTime (enqueuedAt) |
| containers | ^>=0.7 | Map (for assignment queries in tests) |
| tasty | ^>=1.5 | Test framework (main package test suite) |
| tasty-hunit | ^>=0.10 | HUnit integration for tasty assertions |
| random | (any) | Random prefix for test isolation |

### Types and Signatures

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Config.hs`, define:

```haskell
data KafkaAdapterConfig = KafkaAdapterConfig
  { topics      :: ![TopicName]
  , pollTimeout :: !Timeout
  , batchSize   :: !BatchSize
  , offsetReset :: !OffsetReset
  }

defaultConfig :: [TopicName] -> KafkaAdapterConfig
```

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs`, define:

```haskell
consumerRecordToEnvelope ::
  ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
  Envelope (Maybe ByteString)

extractTraceHeaders :: Headers -> Maybe TraceHeaders

timestampToUTCTime :: Timestamp -> Maybe UTCTime
```

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`, define:

```haskell
kafkaSource ::
  (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
  KafkaAdapterConfig ->
  Stream (Eff es) (ConsumerRecord (Maybe ByteString) (Maybe ByteString))

mkAckHandle ::
  (KafkaConsumer :> es, Error KafkaError :> es) =>
  ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
  AckHandle es

mkIngested ::
  (KafkaConsumer :> es, Error KafkaError :> es) =>
  ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
  Ingested es (Maybe ByteString)
```

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`, define:

```haskell
kafkaAdapter ::
  (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
  KafkaAdapterConfig ->
  Eff es (Adapter es (Maybe ByteString))
```

In `shibuya-kafka-adapter/test/Kafka/TestEnv.hs`, define:

```haskell
testPrefix     :: String
brokerAddress  :: BrokerAddress
testTopic      :: TopicName
testGroupId    :: ConsumerGroupId
consumerProps  :: ConsumerProperties
producerProps  :: ProducerProperties
testSubscription :: TopicName -> Subscription
```

In `shibuya-kafka-adapter-jitsurei/app/`, each executable is a `Main.hs`-style module:

- `BasicConsumer.hs`: `main :: IO ()` -- single-topic consume-and-print
- `MultiTopic.hs`: `main :: IO ()` -- two adapters under `runApp`
- `OffsetManagement.hs`: `main :: IO ()` -- consume, shutdown, restart, verify
- `MultiPartition.hs`: `main :: IO ()` -- keyed messages across partitions
