# Refine the Shibuya.Adapter.Kafka public surface

Intention: intention_01kpgf1jjwep58kvk47aasf2ek

MasterPlan: docs/masterplans/1-0.1.0.0-release-prep.md

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this work, a user who imports `Shibuya.Adapter.Kafka` gets a small,
curated set of re-exported types from `hw-kafka-client` rather than every
symbol in the `Kafka.Types` and `Kafka.Consumer.Types` modules. This keeps
the adapter's public API intentional: new additions are conscious choices
rather than incidental consequences of an upstream release.

In the current implementation (as of 2026-04-18), the library module
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` declares:

    module Shibuya.Adapter.Kafka (
        -- * Adapter
        kafkaAdapter,

        -- * Configuration
        KafkaAdapterConfig (..),

        -- * Defaults
        defaultConfig,

        -- * Re-exports from kafka-effectful / hw-kafka-client
        module Kafka.Types,
        module Kafka.Consumer.Types,
    )

`module Kafka.Types` re-exports every public symbol of that module, including
many types a user of this adapter never touches (internal wrappers, helpers
unrelated to consumers, etc.). This plan replaces the two `module` re-exports
with an explicit list that names exactly the types a caller needs.

To verify the outcome, a contributor runs `cabal build all` (library, tests,
bench, jitsurei) and confirms everything still compiles. The jitsurei examples
are the de facto user of the re-export list; anything they import from the
adapter module transitively must remain available.


## Milestones

### Milestone 1: Enumerate what the examples and tests rely on

Before editing, open each file that imports from `Shibuya.Adapter.Kafka`
or `Kafka.Effectful.Consumer` and list the types it uses. The files are:

* `shibuya-kafka-adapter-jitsurei/app/BasicConsumer.hs`
* `shibuya-kafka-adapter-jitsurei/app/MultiTopic.hs`
* `shibuya-kafka-adapter-jitsurei/app/MultiPartition.hs`
* `shibuya-kafka-adapter-jitsurei/app/OffsetManagement.hs`
* `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs`
* `shibuya-kafka-adapter/test/Kafka/TestEnv.hs`

Inspecting the imports (as of 2026-04-18) the adapter-facing types in use are:

* From `Kafka.Types`: `TopicName`, `BrokerAddress`, `BatchSize`, `Timeout`,
  `KafkaError`.
* From `Kafka.Consumer.Types`: `OffsetReset`, `OffsetCommit`,
  `ConsumerGroupId`.

Most of these imports come via `Kafka.Effectful.Consumer`, not via
`Shibuya.Adapter.Kafka`'s re-exports, so the examples already have a direct
path for them. The purpose of the re-exports is ergonomic: a user building
against the adapter should need only one import (`Shibuya.Adapter.Kafka`) to
construct a `KafkaAdapterConfig` and read its fields.

Build the minimal set of re-exports required to construct the config from
outside the module. `KafkaAdapterConfig` exposes `topics :: [TopicName]`,
`pollTimeout :: Timeout`, `batchSize :: BatchSize`, `offsetReset :: OffsetReset`.
Callers need those four types. They also need `OffsetCommit` for the common
pattern of calling `commitAllOffsets OffsetCommit` on shutdown, and `KafkaError`
to scope `runError @KafkaError`. `BrokerAddress` and `ConsumerGroupId` are
needed to build `ConsumerProperties` but they are typically imported from
`Kafka.Effectful.Consumer` in examples; re-exporting them keeps the
"one-import path" story coherent.

### Milestone 2: Replace the module re-exports with an explicit list

Edit the export list in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` to replace the two
`module ...` lines with an explicit list. The final export list:

    module Shibuya.Adapter.Kafka (
        -- * Adapter
        kafkaAdapter,

        -- * Configuration
        KafkaAdapterConfig (..),

        -- * Defaults
        defaultConfig,

        -- * Re-exports
        TopicName (..),
        BrokerAddress (..),
        ConsumerGroupId (..),
        OffsetReset (..),
        OffsetCommit (..),
        Timeout (..),
        BatchSize (..),
        KafkaError,
    )

Update the imports in the same file so every re-exported name is in scope:

    import Kafka.Consumer.Types (OffsetCommit (..), OffsetReset (..), ConsumerGroupId (..))
    import Kafka.Types (KafkaError, TopicName (..), BrokerAddress (..), BatchSize (..), Timeout (..))

Remove any import that was pulled in only by the deleted `module` re-exports
and is not otherwise used. The simplest way to find these is to run `cabal
build shibuya-kafka-adapter` after the edit and follow the unused-import
warnings.

For `KafkaError`, re-export the type without constructors. Users match on it
with `show` or pattern-match against specific constructors imported
separately from `Kafka.Types` — shipping every constructor through the
adapter surface inflates the public API without adding value. If a downstream
user needs `KafkaResponseError` or similar, they import it from `Kafka.Types`
directly.

### Milestone 3: Rebuild everything and fix breakage

Run:

    cabal build all
    cabal test shibuya-kafka-adapter
    cabal bench shibuya-kafka-adapter-bench --enable-benchmarks

If the jitsurei examples or the test suite fail because a previously-
transitive re-export is missing, add targeted imports to the affected files
rather than re-adding a wildcard to `Shibuya.Adapter.Kafka`. The goal is an
explicit surface; shifting an import to the call site is preferred over
expanding the adapter's surface.

If a genuinely-needed re-export is missing from the list in Milestone 2,
add it — but in that case also note it in the Surprises & Discoveries
section so the Decision Log reflects the final surface.

### Milestone 4: Confirm the Haddock rendering

Run:

    cabal haddock shibuya-kafka-adapter

Open the generated
`dist-newstyle/build/*/ghc-*/shibuya-kafka-adapter-0.1.0.0/doc/html/shibuya-kafka-adapter/Shibuya-Adapter-Kafka.html`
and confirm the "Re-exports" section shows a named list rather than two full
module dumps. This is the user-visible outcome of this plan.


## Progress

- [x] Milestone 1: Enumerated imports from the four jitsurei files, the
      integration test, `TestEnv.hs`, and the additional `FatalErrorDemo.hs`
      example. Confirmed: every caller of `Shibuya.Adapter.Kafka` either uses
      named-symbol imports of `kafkaAdapter`, `defaultConfig`, and
      `KafkaAdapterConfig (..)`, or imports the underlying types directly from
      `Kafka.Types`, `Kafka.Consumer.Types`, or via `Kafka.Effectful.Consumer`'s
      own re-exports. No file relies on the wildcard re-exports being removed,
      so the explicit list in Milestone 2 is safe. (2026-04-18)
- [x] Milestone 2: Replaced `module Kafka.Types` / `module Kafka.Consumer.Types`
      re-exports with the explicit list in
      `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`. (2026-04-18)
- [x] Milestone 2: Updated imports in the same file to bring every re-exported
      name into scope. (2026-04-18)
- [x] Milestone 3: `cabal build all` succeeds. (2026-04-18)
- [x] Milestone 3: `cabal test shibuya-kafka-adapter` succeeds (Redpanda
      running on localhost:9092 — all 23 tests passed in 20.34 s).
      (2026-04-18)
- [x] Milestone 3: `cabal bench shibuya-kafka-adapter-bench` succeeds — all 15
      bench tests passed in 27.21 s. (2026-04-18)
- [x] Milestone 4: `cabal haddock shibuya-kafka-adapter` succeeds and the
      rendered `Shibuya-Adapter-Kafka.html` shows a curated re-export list —
      verified that all eight names (`TopicName`, `BrokerAddress`,
      `ConsumerGroupId`, `OffsetReset`, `OffsetCommit`, `Timeout`, `BatchSize`,
      `KafkaError`) appear individually under the "Re-exports" heading rather
      than as wholesale module dumps. (2026-04-18)


## Surprises & Discoveries

- The wildcard re-exports of `Kafka.Types` and `Kafka.Consumer.Types` were
  fully cosmetic: nothing in the repository (jitsurei examples, integration
  test, `TestEnv`, `FatalErrorDemo`) actually relied on them. Every caller
  imports the underlying types either directly from `Kafka.Types` /
  `Kafka.Consumer.Types` or via `Kafka.Effectful.Consumer`'s own re-exports.
  The shrinking of the surface had no downstream impact on the build.

- `cabal build` of the test suite emits a handful of unused-import warnings in
  `shibuya-kafka-adapter/test/Kafka/TestEnv.hs` (`IORef`, `Eff`, `IOE`, `(:>)`,
  `Error`, and `KafkaConsumer`). These are pre-existing — they are not pulled
  in by the deleted wildcard re-exports — and out of scope for this plan.


## Decision Log

- Decision: re-export `KafkaError` opaquely (no `(..)`) rather than with
  constructors. Rationale: the constructor set is large and upstream-driven,
  and users needing specific variants are better served by importing them
  from `Kafka.Types` directly. The adapter's surface should signal "there is
  a KafkaError type you'll see" without committing to every current or future
  constructor. Date: 2026-04-18.

- Decision: keep `BrokerAddress` and `ConsumerGroupId` in the re-export list
  even though the adapter itself does not require them. Rationale: these are
  needed to build the `ConsumerProperties` passed to `runKafkaConsumer` right
  above a call to `kafkaAdapter`. Including them means a user following the
  module Haddock's example snippet does not have to hunt for a second import.
  Date: 2026-04-18.


## Outcomes & Retrospective

`Shibuya.Adapter.Kafka` now re-exports an explicit, curated set of eight
types — `TopicName`, `BrokerAddress`, `ConsumerGroupId`, `OffsetReset`,
`OffsetCommit`, `Timeout`, `BatchSize`, and `KafkaError` (opaque) — instead
of two `module ...` re-exports that pulled in every public symbol of
`Kafka.Types` and `Kafka.Consumer.Types`. A user importing
`Shibuya.Adapter.Kafka` now sees only the names needed to build a
`KafkaAdapterConfig`, scope `runError @KafkaError`, and follow the example
snippet in the module Haddock. Future additions to upstream `hw-kafka-client`
no longer leak into the adapter surface unintentionally; broadening the API
becomes a deliberate edit to the export list.

Verification produced no surprises: `cabal build all`, `cabal test
shibuya-kafka-adapter` (23 tests, 20.34 s, against Redpanda on
localhost:9092), and `cabal bench shibuya-kafka-adapter-bench` (15 bench
tests, 27.21 s) all succeeded. `cabal haddock shibuya-kafka-adapter` confirmed
the rendered "Re-exports" section now lists the eight names individually.

Lessons: the wildcard re-exports turned out to have zero downstream callers
in this repo, so the shrink was costless from a churn perspective. The plan
correctly anticipated this — Milestone 1's enumeration was the de-risking
step that made Milestone 2 a one-line edit. Date: 2026-04-18.
