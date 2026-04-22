# Align `Shibuya.Adapter.Kafka.Tracing` with OTel messaging semantic conventions

Intention: intention_01khv57nhzesc9hx46f9bz0vbq

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

The sibling project `shibuya` recently aligned its core tracing with the
upstream OpenTelemetry messaging semantic conventions — see
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/docs/plans/2-align-opentelemetry-semantic-conventions.md`
(already committed; Progress shows all milestones checked off). That
work (i) derived the `messaging.*` attribute-key strings from the typed
`AttributeKey` values exported by `OpenTelemetry.SemanticConventions`,
(ii) renamed the per-message span from the constant
`"shibuya.process.message"` to the spec pattern
`"<destination> <operation>"`, (iii) introduced
`messaging.operation = "process"` as an always-set attribute on the
consumer span, and (iv) deleted the never-defined
`messaging.destination.partition.id` key in favor of a shibuya-namespaced
`shibuya.partition` (or, for broker-aware adapters, a
system-specific key such as `messaging.kafka.destination.partition`).

`shibuya-kafka-adapter`'s opt-in tracing wrapper
`Shibuya.Adapter.Kafka.Tracing.traced` (added in
`docs/plans/9-add-shibuya-kafka-tracing-module.md`) predates that
alignment. It emits the **old** wire format: span name
`"shibuya.process.message"`, no `messaging.operation` attribute, and
the invalid `messaging.destination.partition.id` key. It is currently
importing two symbols that no longer exist in the aligned
`Shibuya.Telemetry.Semantic` (`processMessageSpanName` and
`attrMessagingDestinationPartitionId`), so the module will stop
building the moment the kafka-adapter bumps its `shibuya-core`
dependency bound to pull in the aligned release (`shibuya-core
0.2.0.0`, published to Hackage on 2026-04-22).

After this plan, running the Plan 9 Milestone 3 Jaeger recipe
(`just process-up`, produce one record with a known `traceparent`,
`cabal run otel-demo`) will show — under the same trace id
`0af7651916cd43dd8448eb211c80319c` — a span whose:

-   `operationName` is `"orders process"` (the topic name followed by
    `" process"`), not `"shibuya.process.message"`.
-   `span.kind` is still `consumer`, parented `CHILD_OF b7ad6b7169203331`.
-   `tags` include the spec-aligned messaging attributes
    `messaging.system=kafka`, `messaging.destination.name=orders`,
    `messaging.operation=process`, `messaging.message.id=orders-0-0`.
-   `tags` also include the Kafka-specific typed attributes
    `messaging.kafka.destination.partition` (Int64) and
    `messaging.kafka.message.offset` (Int64), derived from
    `Envelope.partition` and `Envelope.cursor` respectively.
-   `tags` **do not** include `messaging.destination.partition.id`
    (removed upstream) or the shibuya-namespaced
    `shibuya.partition` (we emit the better-typed, broker-specific
    `messaging.kafka.destination.partition` instead, since we know this
    is Kafka).

Observable outcomes a reader can verify:

1.  `cabal test shibuya-kafka-adapter` passes. The four existing cases
    in `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`
    still hold; the `testAttributes` case is updated to assert the new
    wire names and gains assertions for `messaging.operation`,
    `messaging.kafka.destination.partition`, and
    `messaging.kafka.message.offset`. A new tiny case asserts the span
    name equals `"orders process"`.
2.  `grep -n 'messaging.destination.partition.id'
    shibuya-kafka-adapter/` returns zero lines.
    `grep -n 'shibuya.process.message' shibuya-kafka-adapter/` returns
    zero lines.
3.  A reader of
    `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs` sees
    every wire-name string either imported from
    `Shibuya.Telemetry.Semantic` (for generic `messaging.*` keys) or
    derived via `unkey` from a typed `AttributeKey` in
    `OpenTelemetry.SemanticConventions` (for Kafka-specific keys). No
    free-standing `"messaging.*"` string literals remain in the
    module.
4.  The version bump to `0.3.0.0` records that the wire format
    emitted on spans has changed in a way that downstream dashboards
    filtering on the old strings must be updated.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be
documented here, even if it requires splitting a partially completed task into
two ("done" vs. "remaining"). This section must always reflect the actual
current state of the work.

-   [x] M1 — Bump `shibuya-core ^>=0.1.0.0` to `shibuya-core ^>=0.2`
    in `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`. The
    aligned `shibuya-core 0.2.0.0` is on Hackage (published
    2026-04-22), so no `source-repository-package` pin is needed.
    Verify with `cabal build shibuya-kafka-adapter` that the build
    fails on the two now-missing symbols (`processMessageSpanName`,
    `attrMessagingDestinationPartitionId`) — the failure is the
    evidence that the new `Semantic` is in scope.
-   [x] M2 — Add `hs-opentelemetry-semantic-conventions ^>=0.1` to
    both the `library` and `test-suite` `build-depends` stanzas in
    `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`. The package
    is on Hackage (`0.1.0.0`, transitively present in the closure
    already via shibuya-core 0.2.0.0), so no `cabal.project` change
    is needed — just an explicit edge per the same lesson from plan 9
    M1 (transitive presence is not enough to import from).
-   [ ] M3 — Refactor
    `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs` to
    emit the spec-aligned wire format:
    -   Import `processSpanName`, `attrMessagingOperation`, and
        `attrShibuyaPartition` from `Shibuya.Telemetry.Semantic` (the
        aligned module's exports).
    -   Drop imports of the deleted `processMessageSpanName` and
        `attrMessagingDestinationPartitionId`.
    -   Call `withSpan' (processSpanName (unTopicName topic)) consumerSpanArgs`
        instead of `withSpan' processMessageSpanName consumerSpanArgs`.
    -   In `populateAttrs`, add
        `addAttribute sp attrMessagingOperation ("process" :: Text)`.
    -   Replace the `addAttribute sp attrMessagingDestinationPartitionId p`
        call with typed Kafka-specific attributes: parse the
        `Envelope.partition` text back to `Int32` and emit
        `messaging.kafka.destination.partition` via the
        `OpenTelemetry.SemanticConventions.messaging_kafka_destination_partition ::
        AttributeKey Int64` key; also read `Envelope.cursor` and,
        when it is a `CursorInt off`, emit
        `messaging.kafka.message.offset` via
        `messaging_kafka_message_offset :: AttributeKey Int64`. If the
        partition text fails to parse as an integer, fall back to
        emitting the shibuya-namespaced `attrShibuyaPartition` with
        the raw text (a defensive path; not expected to fire for
        Kafka-origin envelopes because `mkMessageId` always encodes an
        `Int32`).
-   [ ] M4 — Update the Haddock on `Shibuya.Adapter.Kafka.Tracing` and
    the test
    `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`:
    -   Update the module-level Haddock to describe the new span name
        pattern and the new attribute set.
    -   In `testAttributes`, change the expected
        `messaging.destination.partition.id` assertion to assert
        `messaging.kafka.destination.partition` (an integer attribute),
        and add an assertion for `messaging.operation=process`.
    -   Add an assertion that reads back `messaging.kafka.message.offset`
        (integer) — the envelope's `cursor` is `CursorInt 42`, so the
        expected value is `42`.
    -   Add a new case `"span name follows spec pattern"` asserting
        `s.spanName == "orders process"`.
-   [ ] M5 — Re-run the Plan 9 Milestone 3 Jaeger verification recipe
    end-to-end and record the new tag dump in Surprises & Discoveries.
    Confirm the span name equals `"orders process"`, the parent linkage
    is preserved byte-for-byte, and the attribute set matches the new
    expectation.
-   [ ] M6 — Bump `shibuya-kafka-adapter.cabal`'s `version: 0.2.0.0` to
    `0.3.0.0`. Add a `## 0.3.0.0` entry to
    `shibuya-kafka-adapter/CHANGELOG.md` describing the wire-format
    change and calling out the breaking nature for dashboard
    authors. Update the "Tracing (opt-in)" section of
    `shibuya-kafka-adapter/README.md` to match the new attribute set
    and span-name pattern.
-   [ ] M7 — Outcomes & Retrospective: fill in this section comparing
    the achieved wire format against the plan's Big Picture.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered
during implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

-   Decision: Follow the sibling shibuya project's plan 2 choice and
    derive the generic `messaging.*` attribute keys from the typed
    `AttributeKey` values in `OpenTelemetry.SemanticConventions`,
    **not** from hand-written strings. For the kafka-adapter
    specifically this is satisfied by importing the already-aligned
    helpers (`attrMessagingSystem`, `attrMessagingDestinationName`,
    `attrMessagingMessageId`, `attrMessagingOperation`) from
    `Shibuya.Telemetry.Semantic`, which in turn derives them from the
    typed keys. No re-implementation is needed for the generic layer.
    Rationale: shibuya-core has already done this work in its plan 2.
    Re-using its exports keeps a single chokepoint for messaging wire
    names across the whole shibuya ecosystem, matching the invariant
    that "only one module constructs attribute-key strings."
    Date: 2026-04-22.

-   Decision: For Kafka-specific attributes
    (`messaging.kafka.destination.partition`,
    `messaging.kafka.message.offset`) add a direct
    `build-depends: hs-opentelemetry-semantic-conventions` edge on the
    `shibuya-kafka-adapter` library, and import the typed keys
    `messaging_kafka_destination_partition` and
    `messaging_kafka_message_offset` (both `AttributeKey Int64`) from
    `OpenTelemetry.SemanticConventions`.
    Rationale: these keys are broker-specific; shibuya-core
    intentionally does not re-export them. The same typed-key rationale
    from shibuya plan 2 applies here — using `AttributeKey Int64`
    rather than a hand-written `"messaging.kafka.destination.partition"`
    string gives us (a) a compile-time failure if upstream ever
    renames the key, and (b) type-checked values (Int64 rather than
    Text). The hw-kafka-client instrumentation package bundled with
    `hs-opentelemetry-project` imports the same keys the same way
    (see `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/instrumentation/hw-kafka-client/src/OpenTelemetry/Instrumentation/Kafka.hs`
    lines 59–66), so we are aligned with the in-tree worked example.
    Date: 2026-04-22.

-   Decision: Prefer `messaging.kafka.destination.partition` (the
    Kafka-specific Int64 key) over shibuya-core's
    `shibuya.partition` (a generic Text fallback) for Kafka envelopes
    whose partition text parses as an integer. Fall back to
    `shibuya.partition` only in the defensive case where parsing
    fails.
    Rationale: Shibuya plan 2's Decision Log explicitly allows
    broker-aware adapters to emit system-specific keys, noting that
    `shibuya.partition` exists because a generic envelope's partition
    is "an opaque partition string" — but the kafka-adapter knows
    better. Emitting both would be redundant and would invite
    dashboard confusion over which is canonical. This also fixes a
    small wire-format loss: today the partition goes out as Text
    (`"2"`) when upstream Kafka instrumentation emits Int64. Aligning
    the type improves Jaeger numeric filters and matches what the
    hw-kafka-client instrumentation produces on the producer side.
    Date: 2026-04-22.

-   Decision: Do **not** emit `messaging.kafka.consumer.group` in this
    plan, even though the upstream convention and the hw-kafka-client
    instrumentation both set it. The consumer-group identifier is
    known to the adapter's runtime (via `ConsumerGroupId`) but is
    **not** carried on `Envelope`, and `traced`'s current signature
    (`TopicName -> Stream ... -> Stream ...`) does not thread it
    through.
    Rationale: adding the consumer group would require widening
    `traced`'s signature, which is a user-facing API break beyond the
    semantic-conventions alignment this plan is scoped to. It is a
    natural follow-up and can ship in its own small plan; the wire
    format after this plan is still spec-compliant without it (the
    spec marks `messaging.kafka.consumer.group` as Recommended, not
    Required).
    Date: 2026-04-22.

-   Decision: Do **not** emit `messaging.kafka.message.key` in this
    plan. The envelope carries the payload and does expose
    `Envelope.messageId` (which encodes `<topic>-<partition>-<offset>`)
    but has no dedicated `key :: Maybe Text` field; `Convert.hs`
    currently discards the Kafka record's key when building the
    envelope.
    Rationale: adding a message-key attribute would require first
    widening `Envelope` (or plumbing the key via a Kafka-specific
    side channel) to expose the key at all. Out of scope; follow-up
    if demand surfaces.
    Date: 2026-04-22.

-   Decision: Pull both `shibuya-core 0.2.0.0` and
    `hs-opentelemetry-semantic-conventions 0.1.0.0` straight from
    Hackage rather than adding any `source-repository-package` pins
    to `cabal.project`.
    Rationale: the user published `shibuya-core 0.2.0.0` to Hackage
    on 2026-04-22 (confirmed via `cabal info shibuya-core` showing
    `Versions available: 0.1.0.0, 0.2.0.0`). Its declared deps
    include `hs-opentelemetry-semantic-conventions >=0.1 && <0.2`,
    which resolves to the `0.1.0.0` release that is also on Hackage.
    Both packages are therefore reachable purely via the index,
    which sidesteps the sibling-git-pin mechanism that shibuya's own
    `cabal.project` uses internally for in-development builds.
    `cabal.project` stays untouched — packages list only, no
    source-repository-package blocks — matching the kafka-adapter's
    current convention.
    Date: 2026-04-22.

-   Decision: Bump `shibuya-kafka-adapter` from `0.2.0.0` to
    `0.3.0.0` (semver minor, since the public Haskell API is
    unchanged) while calling out the **wire-format breaking** nature
    of the change in the CHANGELOG.
    Rationale: SemVer applies to the Haskell interface, not to the
    OTel wire format. The module signature of
    `Shibuya.Adapter.Kafka.Tracing` is literally unchanged —
    `traced` still takes `TopicName -> Stream ... -> Stream ...`. But
    downstream consumers of the emitted telemetry (Jaeger/Tempo
    queries, Grafana dashboards) will see different attribute keys
    and a different span name. A minor bump keeps the Haskell-level
    semantics honest while the CHANGELOG carries the necessary
    operator warning; a major bump would mislead Haskell callers into
    thinking their `import` needs to change when it does not.
    Date: 2026-04-22.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at
completion. Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

A reader familiar only with this plan needs the following pointers into
the two repositories in play.

**This repository** (the one this plan is in):
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/`

Layout:

    shibuya-kafka-adapter/                       # The library being changed.
      src/Shibuya/Adapter/Kafka.hs               # Public entry: kafkaAdapter.
      src/Shibuya/Adapter/Kafka/Config.hs
      src/Shibuya/Adapter/Kafka/Convert.hs       # ConsumerRecord -> Envelope. Has mkMessageId.
      src/Shibuya/Adapter/Kafka/Internal.hs      # Poll loop + stream plumbing.
      src/Shibuya/Adapter/Kafka/Tracing.hs       # <-- THE MODULE THIS PLAN REWRITES.
      test/Shibuya/Adapter/Kafka/TracingTest.hs  # <-- THE TEST THIS PLAN UPDATES.
      test/Shibuya/Adapter/Kafka/{Adapter,Convert,Integration}Test.hs
      shibuya-kafka-adapter.cabal                # build-depends, version.

    shibuya-kafka-adapter-jitsurei/              # Runnable usage examples.
      app/OtelDemo.hs                            # Calls traced (TopicName "orders"). No edits needed.
      app/OtelProducerDemo.hs                    # Producer-side spike. Uses attrMessagingSystem
                                                 #   and attrMessagingDestinationName from shibuya-core;
                                                 #   both names survived shibuya plan 2 and so do not
                                                 #   need edits here.
      app/OtelUpstreamProbe.hs                   # Uses OpenTelemetry.Instrumentation.Kafka.pollMessage.
      app/{BasicConsumer,MultiPartition,MultiTopic,OffsetManagement,FatalErrorDemo}.hs
                                                 # No tracing imports; unaffected.

    shibuya-kafka-adapter-bench/
      bench/Main.hs                              # Micro-benchmarks; no tracing.

    cabal.project                                # packages:, allow-newer:. May gain a
                                                 #   source-repository-package block in M1 or M2.
    flake.nix                                    # Nix devShell.

Current state of `Shibuya.Adapter.Kafka.Tracing` (the module this plan
rewrites; see the file for full content):

    module Shibuya.Adapter.Kafka.Tracing (traced) where
    ...
    import Shibuya.Telemetry.Semantic
      ( attrMessagingDestinationName
      , attrMessagingDestinationPartitionId    -- <-- deleted upstream in shibuya plan 2
      , attrMessagingMessageId
      , attrMessagingSystem
      , consumerSpanArgs
      , processMessageSpanName                 -- <-- deleted upstream in shibuya plan 2
      )

    traced (TopicName topicName) = Stream.mapM $ \ing -> do
        let envelope    = ing.envelope
            AckHandle finalize = ing.ack
            parentCtx   = envelope.traceContext >>= extractTraceContext
            wrappedFinalize decision =
                withExtractedContext parentCtx $
                    withSpan' processMessageSpanName consumerSpanArgs $ \sp -> do
                        populateAttrs sp topicName envelope
                        finalize decision
        pure ing { ack = AckHandle wrappedFinalize }

    populateAttrs sp topicName envelope = do
        addAttribute sp attrMessagingSystem ("kafka" :: Text)
        addAttribute sp attrMessagingDestinationName topicName
        let MessageId msgIdText = envelope.messageId
        addAttribute sp attrMessagingMessageId msgIdText
        case envelope.partition of
            Just p  -> addAttribute sp attrMessagingDestinationPartitionId p
            Nothing -> pure ()

**The sibling repository** (the one whose alignment this plan mirrors):
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/`

Key files the kafka-adapter consumes:

-   `shibuya-core/src/Shibuya/Telemetry/Semantic.hs` — after
    plan 2 landed, this module:
    -   Exports `processSpanName :: Text -> Text` (the spec-aligned
        replacement for the old `processMessageSpanName :: Text`
        constant).
    -   Exports `attrMessagingOperation :: Text` (derived from
        `Sem.messaging_operation`).
    -   Exports `attrShibuyaPartition :: Text = "shibuya.partition"`
        (the replacement for the deleted
        `attrMessagingDestinationPartitionId`, scoped to
        shibuya-namespaced fallback usage).
    -   **No longer exports** `processMessageSpanName` or
        `attrMessagingDestinationPartitionId` — importing either is a
        compile error.
-   The aligned `shibuya-core`'s `cabal.project` ships a
    `source-repository-package` block pointing at
    `git@github.com:iand675/hs-opentelemetry` with
    `subdir: semantic-conventions`, reusing the same tag the other
    `hs-opentelemetry-*` subpackages are pinned to. The kafka-adapter
    needs the same block to pull
    `hs-opentelemetry-semantic-conventions` into its build closure as
    a direct dependency (see Milestone 2).

**The upstream Haskell OTel project** (read-only; pulled via mori):
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/`

Relevant exports for this plan, inside
`hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs`:

    messaging_kafka_destination_partition :: AttributeKey Int64
    messaging_kafka_destination_partition = AttributeKey "messaging.kafka.destination.partition"

    messaging_kafka_message_offset :: AttributeKey Int64
    messaging_kafka_message_offset = AttributeKey "messaging.kafka.message.offset"

and also — for reference only, not used in this plan —
`messaging_kafka_consumer_group :: AttributeKey Text`,
`messaging_kafka_message_key :: AttributeKey Text`,
`messaging_kafka_message_tombstone :: AttributeKey Bool`.

The worked example at
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/instrumentation/hw-kafka-client/src/OpenTelemetry/Instrumentation/Kafka.hs`
demonstrates these exact imports in use and is worth skimming before
starting M3.

Terms used in this plan:

-   **Spec / conventions**: the OpenTelemetry Semantic Conventions at
    `https://opentelemetry.io/docs/specs/semconv/messaging/`, in
    particular the Kafka section at
    `https://opentelemetry.io/docs/specs/semconv/messaging/kafka/`.
-   **Wire format**: the attribute-key strings and span names that
    actually get exported to the OTLP endpoint. A wire-format change
    is invisible at the Haskell level but visible in Jaeger/Tempo.
-   **AttributeKey a**: a typed, phantom-typed newtype over Text
    (`newtype AttributeKey a = AttributeKey { unkey :: Text }`) that
    carries both the wire-name string and the expected Haskell value
    type. Importing `messaging_kafka_destination_partition :: AttributeKey Int64`
    tells the compiler "this key expects an Int64 value" — the Shibuya
    `addAttribute` helper accepts a `Text` key, so wiring uses
    `unkey` to extract the string.
-   **Plan 9**: `docs/plans/9-add-shibuya-kafka-tracing-module.md` in
    this repository. Read it (already committed; all milestones
    checked off) for the prior art — it added the `traced` module
    this plan now refines.


## Plan of Work

Seven small milestones. Each leaves the repository in a working state:
`cabal build all` clean, `cabal test shibuya-kafka-adapter` passing,
`nix fmt` idempotent.

### Milestone 1 — Pick up the aligned `shibuya-core`

**Scope.** Bump the `shibuya-core` dependency bound so the build
resolves to the aligned `shibuya-core 0.2.0.0` on Hackage (published
2026-04-22 in response to this plan). Edit
`shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`'s library stanza:

    - , shibuya-core          ^>=0.1.0.0
    + , shibuya-core          ^>=0.2

Run `cabal build shibuya-kafka-adapter`. No `cabal.project` change is
needed — shibuya-core 0.2.0.0 is on Hackage.

The evidence this milestone succeeded is that the build **fails**
with two specific errors:

    Module 'Shibuya.Telemetry.Semantic' does not export 'processMessageSpanName'
    Module 'Shibuya.Telemetry.Semantic' does not export 'attrMessagingDestinationPartitionId'

These errors are expected and are the signal that the aligned
`Semantic` module is in scope. Do not fix them yet — that is
Milestones 2 and 3.

**What will exist at the end.** A commit touching only the cabal
file. No Haskell source change yet.

**Acceptance.** `cabal build --dry-run shibuya-kafka-adapter 2>&1 |
grep shibuya-core` shows `shibuya-core-0.2.0.0` being pulled from
Hackage, and the build error cited above reproduces.

### Milestone 2 — Add `hs-opentelemetry-semantic-conventions` as a direct dependency

**Scope.** The kafka-adapter needs to import
`messaging_kafka_destination_partition` and
`messaging_kafka_message_offset` from
`OpenTelemetry.SemanticConventions` directly (the generic wrappers in
shibuya-core's `Semantic` do not re-export the Kafka-specific keys,
and should not — they are broker-specific). The package is on Hackage
as `hs-opentelemetry-semantic-conventions 0.1.0.0` and is already in
the build closure transitively via `shibuya-core 0.2.0.0`. An
explicit edge is still needed because cabal does not let a library
import from a transitively-present package (same lesson as plan 9
M1). Therefore:

1.  In
    `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`'s `library`
    stanza, add the line
    `, hs-opentelemetry-semantic-conventions  ^>=0.1` to
    `build-depends` under the existing
    `, hs-opentelemetry-api                   ^>=0.3` line. The
    `^>=0.1` bound matches the bound declared by
    `shibuya-core 0.2.0.0` so the solver treats the two edges as
    consistent.
2.  Also add `, hs-opentelemetry-semantic-conventions  ^>=0.1` to
    the `test-suite shibuya-kafka-adapter-test`'s `build-depends` so
    the test file can import the same typed keys when asserting
    `lookupAttribute`.
3.  No `cabal.project` change is needed.

**What will exist at the end.** `cabal build shibuya-kafka-adapter`
still fails with the same two compile errors from M1, but no longer
fails for missing-package reasons.

**Acceptance.** `cabal build --dry-run shibuya-kafka-adapter 2>&1 |
grep hs-opentelemetry-semantic-conventions` shows the package being
satisfied. `ghci -e 'import OpenTelemetry.SemanticConventions
(messaging_kafka_destination_partition)'` (run from the project
root's `nix develop` shell) prints the key's wire string
`"messaging.kafka.destination.partition"` without import failure.

### Milestone 3 — Rewrite `Shibuya.Adapter.Kafka.Tracing`

**Scope.** Single-file edit to
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs`.

Imports (the diff):

-   **Remove** `processMessageSpanName` and
    `attrMessagingDestinationPartitionId` from the
    `Shibuya.Telemetry.Semantic` import list.
-   **Add** `processSpanName`, `attrMessagingOperation`, and
    `attrShibuyaPartition` to that same list.
-   **Add** `import qualified OpenTelemetry.SemanticConventions as Sem`
    (for the typed Kafka-specific keys).
-   **Add** `import OpenTelemetry.Attributes (unkey)` if `unkey` is
    not already in scope via an existing import; plan 2 discovered it
    is re-exported from `OpenTelemetry.Attributes` via
    `AttributeKey(..)`.
-   **Add** `import Shibuya.Core.Types (Cursor (..))` if not already
    imported, so the module can pattern-match on `CursorInt`.
-   **Add** `import Data.Int (Int64)` (for the `addAttribute` call on
    Int64 values).
-   **Add** `import qualified Data.Text.Read as TR` (for parsing the
    partition text back to Int32).

Span name (inside `wrappedFinalize`):

    withSpan' (processSpanName topicName) consumerSpanArgs $ \sp -> do

(the `topicName` binding is already in scope from
`traced (TopicName topicName) = ...`).

Attribute population (rewrite `populateAttrs`):

    populateAttrs ::
        (Tracing :> es, IOE :> es) =>
        Span ->
        Text ->
        Envelope v ->
        Eff es ()
    populateAttrs sp topicName envelope = do
        -- Generic messaging.* attributes (wire-names from shibuya-core's
        -- aligned Semantic module, which derives them from typed AttributeKeys).
        addAttribute sp attrMessagingSystem         ("kafka"   :: Text)
        addAttribute sp attrMessagingDestinationName topicName
        addAttribute sp attrMessagingOperation      ("process" :: Text)
        let MessageId msgIdText = envelope.messageId
        addAttribute sp attrMessagingMessageId msgIdText

        -- Kafka-specific attributes (wire-names from the typed
        -- AttributeKeys in OpenTelemetry.SemanticConventions).
        case envelope.partition of
            Just p -> case TR.decimal p of
                Right (n :: Int64, "") ->
                    addAttribute sp (unkey Sem.messaging_kafka_destination_partition) n
                _ ->
                    -- Defensive: the partition text didn't parse as an int.
                    -- Emit the shibuya-namespaced fallback so the information
                    -- is not lost.
                    addAttribute sp attrShibuyaPartition p
            Nothing -> pure ()
        case envelope.cursor of
            Just (CursorInt off) ->
                addAttribute sp
                    (unkey Sem.messaging_kafka_message_offset)
                    (fromIntegral off :: Int64)
            _ -> pure ()

Rationale for choosing `Int64` as the value type for both Kafka keys:
that is what `OpenTelemetry.SemanticConventions` declares
(`AttributeKey Int64`). The Shibuya `addAttribute` helper is
polymorphic over the value (`addAttribute :: ToAttribute a => Span ->
Text -> a -> Eff es ()`), so Int64 values route to
`IntAttribute` on the wire.

Haddock:

-   Update the module header so the "v1.27 messaging-conventions
    attribute set" paragraph reflects the new keys:
    `messaging.system`, `messaging.destination.name`,
    `messaging.operation`, `messaging.message.id`, and — for Kafka —
    `messaging.kafka.destination.partition` and
    `messaging.kafka.message.offset`. Replace
    `processMessageSpanName` in the sentence "is enclosed in an
    OpenTelemetry Consumer-kind span named @shibuya.process.message@"
    with the new span-name pattern.
-   Update the Haddock on `traced` to reference
    `Shibuya.Telemetry.Semantic.processSpanName`.

**What will exist at the end.**
`cabal build shibuya-kafka-adapter` is clean. No existing tests are
touched yet, so `cabal test shibuya-kafka-adapter` will fail in
`testAttributes` (expected — it still asserts the old wire names);
fix that in M4.

**Acceptance.** `cabal build shibuya-kafka-adapter` exits 0.
`grep -n 'messaging.destination.partition.id\|shibuya.process.message'
shibuya-kafka-adapter/src/` returns no lines. `grep -n 'Sem\.' shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs`
shows the two Kafka-specific key references.

### Milestone 4 — Update the unit test

**Scope.** Edit
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`:

1.  Imports: `import OpenTelemetry.Attributes (Attribute (..),
    PrimitiveAttribute (..), lookupAttribute)` already exists and
    `IntAttribute` is one of the `PrimitiveAttribute` constructors
    (see the aligned `hs-opentelemetry-api`). Import `import qualified
    OpenTelemetry.SemanticConventions as Sem` and `import
    OpenTelemetry.Attributes (unkey)` for the Kafka-specific keys.
2.  Rewrite `testAttributes`:

        testAttributes :: Assertion
        testAttributes = withRecordingTracer $ \spansRef tracer -> do
            ackRef <- newIORef Nothing
            runOneThroughTraced tracer (mkEnvelope (Just [("traceparent", sampleTraceparent)])) ackRef
            spans <- readIORef spansRef
            case spans of
                [s] -> do
                    let attrs = s.spanAttributes
                    -- Generic messaging.* attributes.
                    assertEqual
                        "messaging.system"
                        (Just (AttributeValue (TextAttribute "kafka")))
                        (lookupAttribute attrs "messaging.system")
                    assertEqual
                        "messaging.destination.name"
                        (Just (AttributeValue (TextAttribute "orders")))
                        (lookupAttribute attrs "messaging.destination.name")
                    assertEqual
                        "messaging.operation"
                        (Just (AttributeValue (TextAttribute "process")))
                        (lookupAttribute attrs "messaging.operation")
                    assertEqual
                        "messaging.message.id"
                        (Just (AttributeValue (TextAttribute "orders-2-42")))
                        (lookupAttribute attrs "messaging.message.id")
                    -- Kafka-specific attributes (Int64 on the wire).
                    assertEqual
                        "messaging.kafka.destination.partition"
                        (Just (AttributeValue (IntAttribute 2)))
                        (lookupAttribute attrs (unkey Sem.messaging_kafka_destination_partition))
                    assertEqual
                        "messaging.kafka.message.offset"
                        (Just (AttributeValue (IntAttribute 42)))
                        (lookupAttribute attrs (unkey Sem.messaging_kafka_message_offset))
                    -- The deleted pre-alignment key must NOT be present.
                    assertEqual
                        "messaging.destination.partition.id absent"
                        Nothing
                        (lookupAttribute attrs "messaging.destination.partition.id")
                other -> assertFailure ("expected exactly one span, got " <> show (length other))

    Note that `mkEnvelope` already sets `partition = Just "2"` and
    `cursor = Just (CursorInt 42)`, so the Int64 values `2` and `42`
    are the expected decoded values.

3.  Add a new test case `"span name follows spec pattern"`:

        testSpanName :: Assertion
        testSpanName = withRecordingTracer $ \spansRef tracer -> do
            ackRef <- newIORef Nothing
            runOneThroughTraced tracer (mkEnvelope Nothing) ackRef
            spans <- readIORef spansRef
            case spans of
                [s] -> assertEqual "span name" "orders process" s.spanName
                other -> assertFailure ("expected exactly one span, got " <> show (length other))

    Register it in the `tests` list. (`ImmutableSpan` exposes
    `spanName :: Text` directly; the plan 9 test code already uses
    the record via `s.spanContext`, `s.spanParent`, and
    `s.spanAttributes`, so `s.spanName` is the same pattern.)

4.  Re-verify: `testParentedSpan`, `testRootSpan`, and
    `testAckPassthrough` are unchanged — they assert properties
    (trace-id equality, spanParent absence, ack passthrough) that do
    not depend on the wire-format changes in this plan.

**What will exist at the end.** Five test cases, all passing.
`cabal test shibuya-kafka-adapter` exits 0.

**Acceptance.** Test runner output shows `Tracing` group with five
passing cases (was four). The `messaging.destination.partition.id
absent` assertion is the guard that catches any regression back to
the old wire format.

### Milestone 5 — Re-run the Plan 9 Jaeger verification recipe

**Scope.** Execute the end-to-end Jaeger smoke-check from Plan 9
Milestone 3, compare the resulting tags to the recorded baseline, and
capture the new expected tag dump in **Surprises & Discoveries** of
this plan.

Commands (from the repo root):

    just process-up              # shell 1: brings up Redpanda + Jaeger
    just create-topics           # shell 2
    rpk topic produce orders --key k1 \
        -H 'traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' \
        <<< 'hello-otel-post-alignment'
    cabal run otel-demo          # shell 2

Then query Jaeger's HTTP API for the trace:

    curl -s "http://127.0.0.1:16686/api/traces/0af7651916cd43dd8448eb211c80319c" \
      | jq '.data[0].spans[] | {name: .operationName, kind: .kind, tags: (.tags | map({key,value}))}'

Expected output (the new baseline — record it verbatim in
Surprises & Discoveries):

    operationName: "orders process"         -- was "shibuya.process.message"
    span.kind:     "consumer"               -- unchanged
    references:    [CHILD_OF 0af7651916cd43dd8448eb211c80319c/b7ad6b7169203331]
                                            -- unchanged
    tags:
      messaging.system                       = "kafka"
      messaging.destination.name             = "orders"
      messaging.operation                    = "process"     -- NEW
      messaging.message.id                   = "orders-0-0"
      messaging.kafka.destination.partition  = 0             -- NEW (int)
      messaging.kafka.message.offset         = 0             -- NEW (int)
      otel.scope.name                        = "shibuya-kafka-adapter-jitsurei"

The tag `messaging.destination.partition.id` must **not** appear.
Record the exact returned JSON in **Surprises & Discoveries**.

**What will exist at the end.** A Surprises & Discoveries entry
dated 2026-04-XX with the full tag dump and the observation that
parent linkage and kind are unchanged from Plan 9's baseline.

**Acceptance.** The Surprises section has the tag dump. The trace
matches the expected output item-by-item. If any tag is missing or
extra, stop and fix before continuing.

### Milestone 6 — Version bump + documentation

**Scope.** Three files:

1.  `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`: change
    `version: 0.2.0.0` to `version: 0.3.0.0`.
2.  `shibuya-kafka-adapter/CHANGELOG.md`: add a new section at the
    top (above the existing `## 0.2.0.0` heading):

        ## 0.3.0.0 — 2026-04-22

        Telemetry wire-format change. No Haskell API break —
        `Shibuya.Adapter.Kafka.Tracing.traced`'s signature is
        unchanged — but operators with dashboards filtering on the
        old attribute-key strings or span name must update their
        queries.

        ### Changed

        - Per-message spans now follow the OpenTelemetry messaging
          semantic-conventions span-name pattern
          `"<destination> <operation>"`, yielding e.g.
          `"orders process"` in place of the previous constant
          `"shibuya.process.message"`.
        - The `messaging.operation` attribute is now set to
          `"process"` on every consumer span.
        - The Kafka partition is now emitted as the typed Kafka-
          specific key `messaging.kafka.destination.partition`
          (Int64), replacing the never-defined
          `messaging.destination.partition.id` (Text).
        - The Kafka offset is now emitted as
          `messaging.kafka.message.offset` (Int64), derived from
          `Envelope.cursor`.

        ### Aligned with

        - `Shibuya.Telemetry.Semantic` as of sibling `shibuya`
          plan 2 (`docs/plans/2-align-opentelemetry-semantic-conventions.md`
          in the shibuya repo). Attribute keys for the generic
          `messaging.*` namespace are sourced from that module, which
          in turn derives them from typed `AttributeKey` values in
          `OpenTelemetry.SemanticConventions`.
        - `OpenTelemetry.SemanticConventions` (new direct
          `build-depends`) for the typed Kafka-specific keys
          `messaging_kafka_destination_partition` and
          `messaging_kafka_message_offset`.

3.  `shibuya-kafka-adapter/README.md`: in the "Tracing (opt-in)"
    section, replace the old attribute-set paragraph:

        > ...populated with the v1.27 messaging-conventions attributes
        > (`messaging.system=kafka`, `messaging.destination.name`,
        > `messaging.message.id`, and `messaging.destination.partition.id`
        > when the partition is known).

    with the new description:

        > ...populated with the spec-aligned messaging attributes
        > (`messaging.system=kafka`, `messaging.destination.name`,
        > `messaging.operation=process`, `messaging.message.id`) and
        > the Kafka-specific typed attributes
        > `messaging.kafka.destination.partition` (Int64) and
        > `messaging.kafka.message.offset` (Int64) when available.
        > The per-message span is named following the OpenTelemetry
        > messaging convention `"<destination> <operation>"`, e.g.
        > `"orders process"`.

    Also update the prose about `shibuya.process.message` to
    `"<destination> process"` if any mentions remain.

**What will exist at the end.** A single commit carrying the three
edits. `cabal build all` clean. `nix fmt` idempotent.

**Acceptance.** `git diff --stat HEAD~1 HEAD` shows the three files
touched and nothing else of substance.

### Milestone 7 — Outcomes & Retrospective

**Scope.** Fill in the section with:

-   Whether the purpose was met (every bullet in the Big Picture).
-   Test count before/after (was 4 tracing cases → now 5).
-   Whether the Jaeger baseline matched the expected new tag dump.
-   Any lessons — in particular, any divergence from plan 2's
    approach and why.
-   Known gaps (most likely: `messaging.kafka.consumer.group` and
    `messaging.kafka.message.key`, deferred per Decision Log).


## Concrete Steps

Working directory for every command in this section is the repository
root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/`,
unless stated. Every commit must include both trailers:

    ExecPlan: docs/plans/10-align-kafka-adapter-otel-semantic-conventions.md
    Intention: intention_01khv57nhzesc9hx46f9bz0vbq

Every commit must be preceded by `nix fmt` (project rule in
`CLAUDE.md`).

### Milestone 1 steps

    # 1. Confirm starting state.
    git status
    # Expect: the pre-existing "M mori.dhall" / "M mori/cookbook.dhall"
    # modifications and no other in-flight work. If the working tree is
    # dirty for unrelated reasons, stash first.

    cabal update
    # Ensures the Hackage index has shibuya-core 0.2.0.0 visible.
    cabal info shibuya-core 2>&1 | grep "Versions available"
    # Expect: "Versions available: 0.1.0.0, 0.2.0.0"

    cabal build shibuya-kafka-adapter
    # Expect: clean build (current state — pre-alignment shibuya-core
    # 0.1.0.0 is still resolving).

    # 2. Bump the cabal bound.
    $EDITOR shibuya-kafka-adapter/shibuya-kafka-adapter.cabal
    # Change: shibuya-core ^>=0.1.0.0  --> shibuya-core ^>=0.2

    # 3. Reveal the expected compile errors.
    cabal build shibuya-kafka-adapter 2>&1 | tail -30
    # Expect: "not exported from 'Shibuya.Telemetry.Semantic':
    #           processMessageSpanName, attrMessagingDestinationPartitionId"

    nix fmt

    # 4. Commit.
    git add shibuya-kafka-adapter/shibuya-kafka-adapter.cabal
    git commit

Commit message for Milestone 1:

    chore(deps): bump shibuya-core to pick up OTel semantic-conventions alignment

    The sibling shibuya project landed plan 2 which aligns its
    Telemetry.Semantic module with the upstream OpenTelemetry
    semantic conventions. This commit pulls the aligned shibuya-core
    into the kafka-adapter's build closure. The next commits update
    Tracing.hs to match.

    Build is intentionally broken at this commit on two now-missing
    symbols (processMessageSpanName,
    attrMessagingDestinationPartitionId) — fix follows in plan 10
    milestone 3.

    ExecPlan: docs/plans/10-align-kafka-adapter-otel-semantic-conventions.md
    Intention: intention_01khv57nhzesc9hx46f9bz0vbq

### Milestone 2 steps

    # 1. Add the direct dep to both library and test-suite stanzas.
    $EDITOR shibuya-kafka-adapter/shibuya-kafka-adapter.cabal
    # In the library stanza, under "hs-opentelemetry-api ^>=0.3,", add:
    #     , hs-opentelemetry-semantic-conventions  ^>=0.1
    # In the test-suite stanza, also add:
    #     , hs-opentelemetry-semantic-conventions  ^>=0.1

    # 2. Smoke-test the new dep is importable.
    cabal repl shibuya-kafka-adapter <<< ':m + OpenTelemetry.SemanticConventions'
    # Expect: ghci prompt returns cleanly with the module loaded.

    nix fmt

    # 3. Commit.
    git add shibuya-kafka-adapter/shibuya-kafka-adapter.cabal
    git commit

Commit message for Milestone 2:

    chore(deps): add direct dep on hs-opentelemetry-semantic-conventions

    Needed so Shibuya.Adapter.Kafka.Tracing can import the typed
    Kafka-specific AttributeKeys (messaging_kafka_destination_partition,
    messaging_kafka_message_offset) directly from
    OpenTelemetry.SemanticConventions. The generic messaging.* keys
    continue to flow via shibuya-core's aligned
    Shibuya.Telemetry.Semantic module.

    ExecPlan: docs/plans/10-align-kafka-adapter-otel-semantic-conventions.md
    Intention: intention_01khv57nhzesc9hx46f9bz0vbq

### Milestone 3 steps

    # 1. Rewrite the tracing module per the "Rewrite
    #    Shibuya.Adapter.Kafka.Tracing" section above.
    $EDITOR shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs

    # 2. Build.
    cabal build shibuya-kafka-adapter
    # Expect: clean.

    # 3. Test — testAttributes will fail because it still asserts the
    #    old wire format. That is expected; M4 fixes it.
    cabal test shibuya-kafka-adapter 2>&1 | tail -40
    # Expect: 4 passes, 1 fail (testAttributes).

    nix fmt

    # 4. Commit — do NOT bundle M4 here, so that bisection can pin
    #    the source-change commit separately from the test-update
    #    commit.
    git add shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs
    git commit

Commit message for Milestone 3:

    refactor(tracing): align span name and attribute keys with OTel messaging conventions

    - Span name now follows the spec pattern "<destination> <operation>"
      via Shibuya.Telemetry.Semantic.processSpanName.
    - Always emit messaging.operation="process".
    - Drop the never-defined messaging.destination.partition.id.
      Replace with the typed Kafka-specific key
      messaging.kafka.destination.partition (Int64) from
      OpenTelemetry.SemanticConventions, with a defensive fallback
      to shibuya.partition when the envelope partition text does
      not parse as an integer.
    - Emit messaging.kafka.message.offset (Int64) derived from
      Envelope.cursor.

    Test suite is one step behind at this commit (testAttributes
    still asserts the old keys); brought up to date in the next
    commit.

    ExecPlan: docs/plans/10-align-kafka-adapter-otel-semantic-conventions.md
    Intention: intention_01khv57nhzesc9hx46f9bz0vbq

### Milestone 4 steps

    # 1. Update the test file per the scope above.
    $EDITOR shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs

    # 2. Run tests.
    cabal test shibuya-kafka-adapter 2>&1 | tail -20
    # Expect: Tracing group has 5 cases, all pass. Other groups
    # unchanged.

    nix fmt
    git add shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs
    git commit

Commit message for Milestone 4:

    test(tracing): assert spec-aligned attribute keys and span name

    Rewrite testAttributes to check the new wire format:
    messaging.operation=process is present, partition/offset are
    emitted as the typed Kafka-specific Int64 keys, and the deleted
    messaging.destination.partition.id is absent. Add a new case
    testSpanName asserting the span name equals "orders process".

    ExecPlan: docs/plans/10-align-kafka-adapter-otel-semantic-conventions.md
    Intention: intention_01khv57nhzesc9hx46f9bz0vbq

### Milestone 5 steps

    # 1. Bring up infra (process-compose already provides Redpanda + Jaeger v2).
    just process-up                          # shell 1

    # 2. Create topics.
    just create-topics                       # shell 2

    # 3. Produce one record with a known traceparent.
    rpk topic produce orders --key k1 \
        -H 'traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' \
        <<< 'hello-otel-post-alignment'

    # 4. Run the consumer demo.
    cabal run otel-demo                      # shell 2

    # 5. Query Jaeger's trace API and capture the tag dump.
    curl -s "http://127.0.0.1:16686/api/traces/0af7651916cd43dd8448eb211c80319c" \
      | jq '.data[0].spans[] | {name: .operationName, kind: .references[0].refType,
                                refs: .references,
                                tags: (.tags | map({key: .key, type: .type, value: .value}))}'

    # 6. Paste the result into docs/plans/10-...md's Surprises &
    #    Discoveries section. Confirm against the expected new
    #    baseline recorded in this plan's M5 scope.

    # 7. Bring infra down (optional).
    just process-down

No git commit happens at M5 — the verification is recorded in the
plan file, which is committed at the end of M7.

### Milestone 6 steps

    # 1. Bump version.
    $EDITOR shibuya-kafka-adapter/shibuya-kafka-adapter.cabal
    # Change: version: 0.2.0.0  --> version: 0.3.0.0

    # 2. Changelog entry.
    $EDITOR shibuya-kafka-adapter/CHANGELOG.md

    # 3. README entry.
    $EDITOR shibuya-kafka-adapter/README.md

    # 4. Build + format.
    cabal build all
    cabal test shibuya-kafka-adapter
    nix fmt

    # 5. Commit.
    git add shibuya-kafka-adapter/shibuya-kafka-adapter.cabal \
            shibuya-kafka-adapter/CHANGELOG.md \
            shibuya-kafka-adapter/README.md
    git commit

Commit message for Milestone 6:

    chore(release): bump to 0.3.0.0 with OTel semantic-conventions alignment

    ExecPlan: docs/plans/10-align-kafka-adapter-otel-semantic-conventions.md
    Intention: intention_01khv57nhzesc9hx46f9bz0vbq

### Milestone 7 steps

    # 1. Fill Outcomes & Retrospective.
    $EDITOR docs/plans/10-align-kafka-adapter-otel-semantic-conventions.md

    # 2. Commit.
    git add docs/plans/10-align-kafka-adapter-otel-semantic-conventions.md
    git commit -m "docs(plan-10): outcomes and retrospective

    ExecPlan: docs/plans/10-align-kafka-adapter-otel-semantic-conventions.md
    Intention: intention_01khv57nhzesc9hx46f9bz0vbq"


## Validation and Acceptance

Plan-wide acceptance requires all of the following to hold
simultaneously at the final commit:

1.  `cabal build all` exits 0.
2.  `cabal test shibuya-kafka-adapter` passes, with **5** cases in
    the `Tracing` test group (was 4 at plan 9's close). Run:

        cabal test shibuya-kafka-adapter 2>&1 | grep -A2 "Tracing"

    Expect `Tracing` group, 5 passing.
3.  `grep -n 'messaging.destination.partition.id\|shibuya.process.message' \
       shibuya-kafka-adapter/src shibuya-kafka-adapter/test` returns
    no lines.
4.  `grep -n 'messaging.kafka.destination.partition\|messaging.kafka.message.offset' \
       shibuya-kafka-adapter/src` returns the expected lines inside
    `Shibuya/Adapter/Kafka/Tracing.hs` (via the `Sem.` references) and
    inside Haddock.
5.  The Plan 9 Milestone 3 Jaeger recipe produces the new baseline
    recorded in this plan's M5 scope:
    -   `operationName = "orders process"`.
    -   Same `CHILD_OF` parent reference as Plan 9's baseline.
    -   Tags include `messaging.operation=process`,
        `messaging.kafka.destination.partition=0` (int),
        `messaging.kafka.message.offset=0` (int).
    -   Tags do **not** include `messaging.destination.partition.id`.
6.  `shibuya-kafka-adapter.cabal` shows `version: 0.3.0.0`.
    `CHANGELOG.md` has a `## 0.3.0.0` section describing the
    wire-format change.
7.  `nix fmt` is idempotent — a second run produces no diff.
8.  Every commit on the branch carries both `ExecPlan:` and
    `Intention:` git trailers.


## Idempotence and Recovery

Every milestone is reversible by a simple `git revert` of its commit:

-   M1 revert: restores the pre-alignment shibuya-core dependency.
    Combined with reverting M3, returns the build to its current
    working state.
-   M2 revert: removes the direct
    `hs-opentelemetry-semantic-conventions` edge and the sibling
    `source-repository-package` block (if added). Safe as long as
    M3's revert is also applied; M3's code imports from the package.
-   M3 revert: restores the old span name and attribute wiring.
    Combined with M4 revert, returns the full system.
-   M4 revert: restores the old test assertions.
-   M5: no commit — re-run the Jaeger recipe any number of times; the
    verification is idempotent.
-   M6 revert: restores `0.2.0.0` and the old CHANGELOG/README.

Risky operations to watch for:

-   **Partial milestone commits.** Do not commit M3 and M4 together
    even though they are tightly related; keeping them separate
    preserves bisectability — anyone doing a future
    `git bisect` on a Jaeger regression benefits from being able to
    land on the wire-format-change commit specifically.
-   **Tag/SHA drift in source-repository-package.** If M1 or M2 adds
    a git pin, copy the exact tag from the aligned shibuya-core's
    cabal.project rather than reading the latest main; otherwise we
    risk pulling a different `hs-opentelemetry-*` version than
    shibuya-core compiles against, which will either fail to build
    or, worse, link but export subtly different AttributeKey
    strings.
-   **Jaeger caching.** If the recorded M5 tag dump shows old keys
    after the refactor, check `process-compose down && up` to reset
    Jaeger's in-memory store; a stale trace from before the rebuild
    can masquerade as a regression.
-   **Pre-commit hook failures.** Project's `CLAUDE.md` requires
    `nix fmt` before commit. Standard fix: run `nix fmt`, re-stage,
    commit again. Do **not** pass `--no-verify`.


## Interfaces and Dependencies

Packages used:

-   `shibuya-core ^>=0.2` (bound bumped in M1, from `^>=0.1.0.0`) —
    resolves to `shibuya-core 0.2.0.0` on Hackage. Supplies
    `processSpanName :: Text -> Text`,
    `attrMessagingOperation :: Text`, and `attrShibuyaPartition ::
    Text` from `Shibuya.Telemetry.Semantic`. The generic
    `attrMessaging{System,DestinationName,MessageId}` constants
    continue to flow through unchanged.
-   `hs-opentelemetry-api ^>=0.3` (already depended on since plan 9
    M1) — supplies `AttributeKey`, `unkey`, `Span`, `addAttribute`
    plumbing.
-   `hs-opentelemetry-semantic-conventions ^>=0.1` (**new** direct
    dependency, added in M2) — resolves to
    `hs-opentelemetry-semantic-conventions 0.1.0.0` on Hackage.
    Supplies the typed Kafka-specific `AttributeKey`s this plan uses:

        messaging_kafka_destination_partition :: AttributeKey Int64
        -- wire: "messaging.kafka.destination.partition"

        messaging_kafka_message_offset        :: AttributeKey Int64
        -- wire: "messaging.kafka.message.offset"

    Source lives on disk at
    `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs`.

Interface shape at the end of each milestone:

-   End of **M1**: cabal resolution changes, no Haskell interface
    change yet. Build is intentionally broken on missing-symbol
    errors.
-   End of **M2**: a direct build-depends edge on
    `hs-opentelemetry-semantic-conventions`. Build still broken on
    the same missing-symbol errors.
-   End of **M3**: `Shibuya.Adapter.Kafka.Tracing`'s public interface
    is unchanged:

        traced
          :: (Tracing :> es, IOE :> es)
          => TopicName
          -> Stream (Eff es) (Ingested es v)
          -> Stream (Eff es) (Ingested es v)

    But the span it opens now carries a different name and attribute
    set. Build is clean; tests are one step behind.
-   End of **M4**: five passing test cases. No new exported symbols.
-   End of **M5**: a Jaeger trace dump recorded in this plan file.
-   End of **M6**: `shibuya-kafka-adapter 0.3.0.0`. No Haskell
    interface change relative to 0.2.0.0.
-   End of **M7**: no interface change.

Out of scope:

-   **`messaging.kafka.consumer.group` attribute**. Emitting it
    requires widening `traced`'s signature; defer to a follow-up.
-   **`messaging.kafka.message.key` attribute**. Requires widening
    `Envelope` or a Kafka-specific side channel to carry the key;
    defer.
-   **Producer-side alignment** (`OtelProducerDemo.hs`). That demo
    uses `Shibuya.Telemetry.Semantic.{attrMessagingSystem,
    attrMessagingDestinationName}`, both of which survive the
    alignment. No edits needed.
-   **`shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs`**. Already uses
    `traced (TopicName "orders") source` — signature unchanged by
    this plan, so the demo continues to work without edits. M5's
    recipe runs it as-is.
-   **`shibuya-kafka-adapter-bench`**. No tracing code; unaffected.

---

Revision history:

-   2026-04-22: Initial draft.
-   2026-04-22 (revision): User published `shibuya-core 0.2.0.0` (with
    the plan 2 alignment) and `hs-opentelemetry-semantic-conventions
    0.1.0.0` to Hackage after this plan was drafted. M1 and M2
    simplified accordingly: no `source-repository-package` pin is
    needed — both packages are reachable purely via the Hackage index.
    Progress, Plan of Work, Concrete Steps, Decision Log, and
    Interfaces and Dependencies sections updated. No milestone
    re-ordering, no scope change, no signature change.
