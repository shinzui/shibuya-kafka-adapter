---
id: 14
slug: upgrade-shibuya-and-opentelemetry-dependencies
title: "Upgrade Shibuya and OpenTelemetry dependencies"
kind: exec-plan
created_at: 2026-05-31T19:41:44Z
---

# Upgrade Shibuya and OpenTelemetry dependencies

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`shibuya-kafka-adapter` currently builds against `shibuya-core ^>=0.5` and the
older `hs-opentelemetry` package family (`hs-opentelemetry-api ^>=0.3`,
`hs-opentelemetry-semantic-conventions ^>=0.1`, and example-only SDK/exporter
packages on `^>=0.1`). The sibling framework project `shinzui/shibuya` has now
completed its upgrade to `shibuya-core 0.6.0.0` and the `hs-opentelemetry`
1.0 ecosystem. This plan moves the Kafka adapter to that same dependency set so
adapter users see the current OpenTelemetry messaging wire keys on Shibuya's
per-message spans.

After implementation, a user can run `cabal build all` and `cabal test
shibuya-kafka-adapter-test` in this repository and observe the adapter compiling
against `shibuya-core ^>=0.6.0.0`, `hs-opentelemetry-api ^>=1.0`, and
`hs-opentelemetry-semantic-conventions ^>=1.40`. The pure conversion tests will
still prove that Kafka envelopes contribute `messaging.system="kafka"`,
`messaging.kafka.destination.partition`, and `messaging.kafka.message.offset`.
An OpenTelemetry demo run through Jaeger should show the framework span using
the current generic operation key `messaging.operation.type="process"` rather
than the deprecated `messaging.operation="process"`.

The plan deliberately does not adopt new `hs-opentelemetry` 1.0 features such as
metrics, logs, `OpenTelemetry.SDK.withOpenTelemetry`, new propagators, or custom
exception handling. It is a dependency and semantic-convention alignment change:
upgrade to the latest Shibuya release, upgrade the OpenTelemetry packages to the
1.0 release family, use the latest Haskell generated semantic-conventions
package available with that release (`1.40.0.0`), and audit the emitted Kafka
messaging keys against the live OpenTelemetry semantic-conventions 1.41.0 docs.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-05-31: M1 - Updated `cabal.project` with the
  `hs-opentelemetry` 1.0 source package set used by sibling `shinzui/shibuya`.
  A first dry-run exposed a transitive `kafka-effectful` bound on
  `hs-opentelemetry-api ^>=0.3`; after `kafka-effectful 0.3.0.0` was released
  with native `hs-opentelemetry` 1.0 bounds, the adapter now depends on
  `kafka-effectful ^>=0.3.0.0` without a temporary `allow-newer`.
- [x] 2026-05-31: M2 - Bumped package bounds and package versions across the
  library, examples, and benchmark package to `0.6.0.0`, `shibuya-core
  ^>=0.6.0.0`, and the relevant `hs-opentelemetry` 1.0 / 1.40 bounds.
- [x] 2026-05-31: M3 - Updated example source for the
  `hs-opentelemetry-api` 1.0 `shutdownTracerProvider` timeout argument. No
  `Convert.hs` or conversion-test source change was required; the existing
  typed Kafka semantic-convention keys compile against
  `hs-opentelemetry-semantic-conventions 1.40.0.0`.
- [x] 2026-05-31: M4 - Ran dependency dry-runs, `cabal build all`, pure unit
  groups, full Redpanda-backed integration tests, benchmark, `nix fmt`, `nix
  flake check`, and the Jaeger smoke path. The first full test run was stopped
  after repeated `localhost:9092` connection refusals; after `just process-up`
  and `just create-topics`, the full suite passed.
- [x] 2026-05-31: M5 - Updated README, example Haddock, and changelog for the
  `messaging.operation.type` key and dependency upgrade. Ready to commit with
  the required ExecPlan trailer.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: `kafka-effectful-0.2.0.0` still declares
  `hs-opentelemetry-api ^>=0.3` and
  `hs-opentelemetry-semantic-conventions ^>=0.1`, so the first Cabal dry-run
  could not solve after the adapter moved to `hs-opentelemetry-api ^>=1.0`.
  Running the same dry-run with a narrow `allow-newer` for those two
  `kafka-effectful` dependencies solved successfully and selected
  `kafka-effectful-0.2.0.0`, `hs-opentelemetry-api-1.0.0.0`, and
  `hs-opentelemetry-semantic-conventions-1.40.0.0`.
  Evidence:

    rejecting: kafka-effectful-0.2.0.0 (conflict: hs-opentelemetry-api==1.0.0.0, kafka-effectful => hs-opentelemetry-api^>=0.3)
    kafka-effectful-0.2.0.0 (lib) (requires download & build)
    hs-opentelemetry-api-1.0.0.0 (lib) (requires build)
    hs-opentelemetry-semantic-conventions-1.40.0.0 (lib) (requires build)

- Observation: `kafka-effectful 0.3.0.0` was released on Hackage during this
  implementation and carries the required OpenTelemetry 1.0 bounds, so the
  adapter can depend on it directly instead of carrying an `allow-newer`
  workaround.
  Evidence:

    Versions available: 0.1.0.0, 0.2.0.0, 0.3.0.0
    hs-opentelemetry-api >=1.0 && <1.1
    hs-opentelemetry-semantic-conventions >=1.40 && <2

- Observation: `hs-opentelemetry-api` 1.0 changes `shutdownTracerProvider` to
  take an optional timeout. The three example executables needed to pass
  `Just 5_000_000` as the shutdown timeout.
  Evidence:

    Couldn't match expected type: TracerProvider -> IO b0
                  with actual type: Maybe Timeout -> IO ()
    Probable cause: `shutdownTracerProvider' is applied to too few arguments

- Observation: The full test suite still requires Redpanda on
  `localhost:9092`; without the local process stack it repeatedly reports
  connection refusals and does not reach the integration assertions. Starting
  the stack with `just process-up` and creating topics with `just create-topics`
  allowed all 26 tests to pass.
  Evidence:

    localhost:9092/bootstrap: Connect to ipv4#127.0.0.1:9092 failed: Connection refused
    All 26 tests passed (15.32s)


## Decision Log

Record every decision made while working on the plan.

- Decision: Target `shibuya-core ^>=0.6.0.0` and bump this repository's three
  Cabal package versions to `0.6.0.0`.
  Rationale: `shinzui/shibuya` commit `bbbe319` bumps Shibuya packages to
  `0.6.0.0`, and commit `1b86540` records that `0.6.0.0` changes the
  OpenTelemetry messaging operation wire key from `messaging.operation` to
  `messaging.operation.type`. Prior adapter plans track the shared Shibuya
  version (`docs/plans/11-upgrade-shibuya-core-0.4.md` and
  `docs/plans/12-migrate-to-shibuya-core-0.5.md`), so the Kafka adapter should
  continue that convention.
  Date: 2026-05-31.

- Decision: Use the `hs-opentelemetry` Git source package pin from
  `shinzui/shibuya/cabal.project`: tag `hs-opentelemetry-api-types-1.0.0.0`
  with subdirs `api`, `api-types`, `sdk`, `otlp`, `propagators/w3c`,
  `semantic-conventions`, `instrumentation/hw-kafka-client`, and
  `exporters/otlp`.
  Rationale: the sibling Shibuya upgrade already proved this tag resolves on
  GHC 9.12.2. The local `hs-opentelemetry` corpus shows that non-semantic
  packages are `1.0.0.0`, while
  `hs-opentelemetry-semantic-conventions` is versioned to the semantic
  convention spec it was generated from, `1.40.0.0`.
  Date: 2026-05-31.

- Decision: Preserve Kafka adapter-owned attributes
  `messaging.system`, `messaging.kafka.destination.partition`, and
  `messaging.kafka.message.offset`, and do not add
  `messaging.operation.name` in `Shibuya.Adapter.Kafka.Convert`.
  Rationale: `consumerRecordToEnvelope` only contributes adapter attributes
  through `Envelope.attributes`; the generic Shibuya runner contributes
  destination, message id, span name, and operation type. The live
  OpenTelemetry messaging spec treats `messaging.operation.name` as a
  system-specific operation name. This adapter currently converts consumed
  Kafka records into Shibuya envelopes and does not own a separate
  system-specific span operation name at that conversion boundary.
  Date: 2026-05-31.

- Decision: Require `kafka-effectful ^>=0.3.0.0` instead of carrying a
  project-local `allow-newer` workaround for `kafka-effectful-0.2.0.0`.
  Rationale: `kafka-effectful 0.3.0.0` is the first release with native
  `hs-opentelemetry` 1.0 bounds. Depending on it directly keeps dependency
  constraints honest and avoids building a 0.2.0.0 source release against an
  API it was not released for.
  Date: 2026-05-31.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Completed on 2026-05-31. The repository now resolves and builds against
`shibuya-core-0.6.0.0`, `kafka-effectful-0.3.0.0`,
`hs-opentelemetry-api-1.0.0.0`, and
`hs-opentelemetry-semantic-conventions-1.40.0.0`. The adapter package,
examples, and benchmark package are versioned `0.6.0.0`.

The adapter-owned Kafka attributes remained stable:
`messaging.system`, `messaging.kafka.destination.partition`, and
`messaging.kafka.message.offset`. The framework-owned operation attribute is
documented and smoke-tested as `messaging.operation.type="process"`, matching
Shibuya 0.6 and the generated semantic-conventions package.

Validation completed:

    cabal build shibuya-kafka-adapter --dry-run
    cabal build all --dry-run
    cabal build all
    cabal test shibuya-kafka-adapter-test --test-options "--pattern Adapter"
    cabal test shibuya-kafka-adapter-test --test-options "--pattern Convert"
    just process-up
    just create-topics
    cabal test shibuya-kafka-adapter-test
    cabal bench shibuya-kafka-adapter-bench
    nix fmt
    nix flake check
    rpk topic produce orders --key k1 -H 'traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'
    OTEL_DEMO_GROUP=otel-demo-verify cabal run otel-demo -- 1
    curl -s 'http://localhost:16686/api/traces?service=unknown_service%3Aotel-demo&limit=5'

The Jaeger API returned a Consumer span named `orders process` with
`messaging.destination.name="orders"`,
`messaging.operation.type="process"`,
`messaging.kafka.destination.partition=0`,
`messaging.kafka.message.offset=0`, `messaging.message.id="orders-0-0"`, and
`messaging.system="kafka"`.


## Context and Orientation

This repository has three Cabal packages. The library lives in
`shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`, runnable examples live in
`shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`, and
micro-benchmarks live in
`shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal`. The root
`cabal.project` currently lists only these packages and has no
`source-repository-package` stanza for `hs-opentelemetry`.

The main conversion code is
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs`.
`consumerRecordToEnvelope` converts a `Kafka.Consumer.Types.ConsumerRecord` into
a `Shibuya.Core.Types.Envelope`. An `Envelope` is the Shibuya framework's
message container; its `attributes` field is a map of OpenTelemetry attributes
that adapters can attach to the framework's per-message span. This adapter
currently sets:

    messaging.system = "kafka"
    messaging.kafka.destination.partition = <Kafka partition as Int64>
    messaging.kafka.message.offset = <Kafka offset as Int64>

The corresponding tests are in
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/ConvertTest.hs`. They import
`OpenTelemetry.Attributes` and `OpenTelemetry.SemanticConventions`, then look up
the Kafka-specific typed keys with `unkey
Sem.messaging_kafka_destination_partition` and `unkey
Sem.messaging_kafka_message_offset`.

The sibling dependency `shinzui/shibuya` is registered in mori at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. Its current
`shibuya-core/shibuya-core.cabal` declares `version: 0.6.0.0` and depends on
`hs-opentelemetry-api ^>=1.0`,
`hs-opentelemetry-propagator-w3c ^>=1.0`, and
`hs-opentelemetry-semantic-conventions ^>=1.40`. Its upgrade commit
`7e12493 fix(telemetry): upgrade OpenTelemetry dependencies to 1.0` made three
important changes for this adapter:

1. `cabal.project` now pins `https://github.com/iand675/hs-opentelemetry` at tag
   `hs-opentelemetry-api-types-1.0.0.0` and includes the new `api-types`
   subdir.
2. `Shibuya.Telemetry.Semantic.attrMessagingOperation` still has the same
   Haskell name, but now resolves to the typed key
   `OpenTelemetry.SemanticConventions.messaging_operation_type`, whose wire
   name is `messaging.operation.type`.
3. Telemetry tests read ended span data through 1.0's `spanHot`,
   `hotName`, `hotAttributes`, and `hotEvents`, and
   `shutdownTracerProvider` now receives a timeout argument.

The local `hs-opentelemetry` corpus is registered in mori at
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project`. Its
`docs/OpenTelemetry-1.0-Upgrade-Guide.md` states that `hs-opentelemetry-api`,
`-sdk`, `-otlp`, exporters, and propagators move together to `1.0.0.0`, while
`hs-opentelemetry-semantic-conventions` is versioned to the spec it tracks,
`1.40.0.0`. The Cabal file
`hs-opentelemetry/semantic-conventions/hs-opentelemetry-semantic-conventions.cabal`
confirms `version: 1.40.0.0` and describes itself as generated from semantic
conventions v1.40. The generated module exports the keys this adapter needs:

    messaging_operation_type = AttributeKey "messaging.operation.type"
    messaging_operation_name = AttributeKey "messaging.operation.name"
    messaging_kafka_destination_partition = AttributeKey "messaging.kafka.destination.partition"
    messaging_kafka_message_offset = AttributeKey "messaging.kafka.message.offset"

OpenTelemetry semantic conventions are the standard names and meanings for span
attributes. A typed `AttributeKey` is a Haskell value whose type restricts the
kind of value that can be attached, so using typed keys catches spelling and type
mistakes at compile time. The live OpenTelemetry semantic-conventions docs on
2026-05-31 advertise semantic conventions 1.41.0; the Haskell package available
with `hs-opentelemetry` 1.0 tracks 1.40.0.0, so implementation must use the
newest Haskell typed package and document any live-spec gap.


## Plan of Work

Milestone 1 updates dependency resolution. Edit `cabal.project` to mirror the
working Shibuya 1.0 pin, adding a `source-repository-package` stanza after the
package list. Include the subdirs this repository imports directly or
indirectly from its example package: `api`, `api-types`, `sdk`, `otlp`,
`propagators/w3c`, `semantic-conventions`,
`instrumentation/hw-kafka-client`, and `exporters/otlp`. Keep the existing
`allow-newer` stanza unchanged. Verify this
milestone by running `cabal build shibuya-kafka-adapter --dry-run` and checking
that the install plan mentions `hs-opentelemetry-api-1.0.0.0` and
`hs-opentelemetry-semantic-conventions-1.40.0.0`.

Milestone 2 bumps bounds and versions. In
`shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`, change `version:` to
`0.6.0.0`, change library and test bounds from `hs-opentelemetry-api ^>=0.3` to
`^>=1.0`, from `hs-opentelemetry-semantic-conventions ^>=0.1` to `^>=1.40`, and
from `shibuya-core ^>=0.5` or unbounded `shibuya-core` to `^>=0.6.0.0`. In
`shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`, change
`version:` to `0.6.0.0`, update `hs-opentelemetry-api`, `hs-opentelemetry-sdk`,
`hs-opentelemetry-exporter-otlp`,
`hs-opentelemetry-instrumentation-hw-kafka-client`, and `shibuya-core` bounds
to the 1.0 / 0.6 set. In
`shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal`, change
`version:` to `0.6.0.0` and `shibuya-core` to `^>=0.6.0.0`. Verify by running
`cabal build all --dry-run`; Cabal should no longer try to solve with
`hs-opentelemetry-api-0.3` or `shibuya-core-0.5`.

Milestone 3 updates code and tests. First run `cabal build all` after Milestone
2. If compilation fails, use the error messages to make minimal source changes.
Expected changes, based on the sibling Shibuya upgrade, are most likely in the
example programs under `shibuya-kafka-adapter-jitsurei/app`, not in
`Convert.hs`: `shutdownTracerProvider` may now need a timeout argument,
in-memory exporter imports may have moved if used, and any direct reads from
`ImmutableSpan` may need `spanHot`/`hotAttributes`. Keep
`consumerRecordToEnvelope`'s Kafka-specific attribute behavior in
`Convert.hs`, but confirm it still derives key strings through
`OpenTelemetry.SemanticConventions` rather than literal Kafka key strings.
Update `ConvertTest.hs` only if the `Attribute` constructors or typed key names
changed; the expected wire keys remain `messaging.system`,
`messaging.kafka.destination.partition`, and `messaging.kafka.message.offset`.

Milestone 4 proves semantic alignment. Add or update a test that makes the
framework-level operation-key change visible from this repository. The least
invasive route is a test around a Shibuya runner path if one already exists in
the adapter tests; otherwise document that the invariant is covered upstream by
`shinzui/shibuya/shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs` and add a
repository-local grep validation that the adapter does not assert or document
`messaging.operation = "process"` as the current key. Update README and example
comments to say the framework span carries `messaging.operation.type=process`.
If the Kafka adapter chooses to add `messaging.operation.name`, record the new
decision here with the exact system-specific value and evidence from the live
spec. The default plan is not to add it.

Milestone 5 runs full validation and records results. Run formatting, build,
tests, benchmarks if practical, and the OpenTelemetry smoke path. The Jaeger
smoke path should produce one Kafka message and run `cabal run otel-demo`; the
observed trace should include the current generic key
`messaging.operation.type=process` from Shibuya and the Kafka-specific keys from
the adapter. Update `shibuya-kafka-adapter/CHANGELOG.md` with a `0.6.0.0`
entry that calls out the breaking dashboard/query rename from
`messaging.operation` to `messaging.operation.type`, plus the dependency
upgrades. Fill `Outcomes & Retrospective`, then commit with:

    ExecPlan: docs/plans/14-upgrade-shibuya-and-opentelemetry-dependencies.md


## Concrete Steps

Run all commands from the repository root:

    cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter

Confirm the dependency context through mori before editing:

    mori show --full
    mori registry show shinzui/shibuya --full
    mori registry show iand675/hs-opentelemetry --full
    mori registry docs shinzui/shibuya
    mori registry docs iand675/hs-opentelemetry

Expected facts to see: this project depends on `shinzui/shibuya`; Shibuya's
local path is `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`;
hs-opentelemetry's local path is
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project`; Shibuya docs
include a changelog; hs-opentelemetry docs include
`OpenTelemetry-1.0-Upgrade-Guide.md` and
`OpenTelemetry-Semantic-Conventions-Guide.md`.

Read the source of the relevant dependencies:

    sed -n '1,130p' /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/cabal.project
    sed -n '1,170p' /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/shibuya-core.cabal
    sed -n '80,125p' /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src/Shibuya/Telemetry/Semantic.hs
    sed -n '1,220p' /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/docs/OpenTelemetry-1.0-Upgrade-Guide.md
    sed -n '1,220p' /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/hs-opentelemetry-semantic-conventions.cabal
    rg -n "messaging_operation_type|messaging_operation_name|messaging_kafka_destination_partition|messaging_kafka_message_offset" /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs

Expected evidence:

    shibuya-core.cabal: version: 0.6.0.0
    shibuya-core.cabal: hs-opentelemetry-api ^>=1.0
    shibuya-core.cabal: hs-opentelemetry-semantic-conventions ^>=1.40
    Semantic.hs: attrMessagingOperation = unkey Sem.messaging_operation_type
    hs-opentelemetry-semantic-conventions.cabal: version: 1.40.0.0
    SemanticConventions.hs: messaging_operation_type = AttributeKey "messaging.operation.type"

After editing `cabal.project` and Cabal files, run:

    cabal build shibuya-kafka-adapter --dry-run
    cabal build all --dry-run

Useful expected install-plan fragments:

    hs-opentelemetry-api-1.0.0.0
    hs-opentelemetry-api-types-1.0.0.0
    hs-opentelemetry-semantic-conventions-1.40.0.0
    shibuya-core-0.6.0.0

Then build and test:

    cabal build all
    cabal test shibuya-kafka-adapter-test
    cabal bench shibuya-kafka-adapter-bench
    nix fmt
    nix flake check

If the Redpanda-backed integration tests require local services, start them
with the existing project commands before the full test run:

    just process-up
    just create-topics
    cabal test shibuya-kafka-adapter-test

For the OpenTelemetry smoke, use the existing example instructions in
`shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs` and the local stack in
`process-compose.yaml`. Produce one message, run:

    cabal run otel-demo

Then query Jaeger for the trace. The span should include:

    messaging.system = "kafka"
    messaging.operation.type = "process"
    messaging.kafka.destination.partition = <int>
    messaging.kafka.message.offset = <int>

Before committing, update this plan's Progress and Outcomes sections, then run:

    git status --short
    git add cabal.project shibuya-kafka-adapter shibuya-kafka-adapter-jitsurei shibuya-kafka-adapter-bench docs/plans/14-upgrade-shibuya-and-opentelemetry-dependencies.md
    git commit -m "feat!: upgrade Shibuya and OpenTelemetry dependencies" -m "Move the Kafka adapter to shibuya-core 0.6.0.0 and the hs-opentelemetry 1.0 package set. Align documented messaging operation attributes with the current semantic-conventions key." -m "ExecPlan: docs/plans/14-upgrade-shibuya-and-opentelemetry-dependencies.md"


## Validation and Acceptance

Acceptance requires these observable results:

1. `cabal build all` exits 0 and the resolved plan contains
   `shibuya-core-0.6.0.0`, `hs-opentelemetry-api-1.0.0.0`, and
   `hs-opentelemetry-semantic-conventions-1.40.0.0`.
2. `cabal test shibuya-kafka-adapter-test` exits 0. The conversion tests prove
   Kafka envelopes still carry `messaging.system="kafka"`,
   `messaging.kafka.destination.partition`, and
   `messaging.kafka.message.offset` with typed `Attribute` values.
3. `rg -n '"messaging.operation"|messaging.operation ' shibuya-kafka-adapter shibuya-kafka-adapter-jitsurei shibuya-kafka-adapter-bench`
   has no result that presents `messaging.operation` as the current emitted key.
   Historical changelog entries and this plan may mention the old key only to
   describe the migration.
4. `rg -n 'messaging.operation.type' shibuya-kafka-adapter shibuya-kafka-adapter-jitsurei`
   finds the current documentation or tests describing the framework span key.
5. The OpenTelemetry smoke test through `otel-demo` exports a Consumer span with
   `messaging.operation.type=process` and the Kafka-specific typed attributes.
6. `nix fmt` and `nix flake check` exit 0.
7. `shibuya-kafka-adapter/CHANGELOG.md` has a `0.6.0.0` entry describing the
   dependency upgrade and the telemetry wire-key rename.


## Idempotence and Recovery

All read-only research commands are safe to repeat. Cabal dry-runs, builds,
tests, `nix fmt`, and `nix flake check` are also safe to repeat. If Cabal
resolves old OpenTelemetry versions after the `cabal.project` edit, remove only
Cabal's local build artifacts if needed with `cabal clean` and rerun the
dry-run; do not edit anything under `/nix/store` and do not search the
filesystem root.

If a source change fails halfway, use `git diff` to inspect the partial edit and
continue from the failing compiler error. Do not use `git reset --hard` or
`git checkout --` unless the user explicitly asks for that destructive cleanup.
If the `source-repository-package` pin later becomes unnecessary because Hackage
has compatible packages for GHC 9.12.2, remove it in a separate small change and
record the decision in this plan before committing.

If Jaeger or Redpanda ports are occupied, use the existing
`process-compose.yaml` as the source of service names and either stop the
conflicting local service or change only local runtime configuration. Do not
commit machine-specific port changes unless they are intentionally part of the
fix.


## Interfaces and Dependencies

Repository interfaces that must remain intact:

`Shibuya.Adapter.Kafka.Convert.consumerRecordToEnvelope` remains:

    consumerRecordToEnvelope ::
        ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
        Envelope (Maybe ByteString)

`Shibuya.Adapter.Kafka.Convert.extractTraceHeaders` remains:

    extractTraceHeaders :: Headers -> Maybe TraceHeaders

`Shibuya.Adapter.Kafka.Convert.timestampToUTCTime` remains:

    timestampToUTCTime :: Timestamp -> Maybe UTCTime

Dependency interfaces to use:

`Shibuya.Core.Types.Envelope` comes from `shibuya-core ^>=0.6.0.0`. Its
`attributes :: HashMap Text Attribute` field remains the place for adapter-owned
OpenTelemetry attributes.

`OpenTelemetry.Attributes.Attribute`, `toAttribute`, and `unkey` come from
`hs-opentelemetry-api ^>=1.0`. If 1.0 re-exports these from
`hs-opentelemetry-api-types`, keep importing through `OpenTelemetry.Attributes`
unless the compiler says the module moved.

`OpenTelemetry.SemanticConventions` comes from
`hs-opentelemetry-semantic-conventions ^>=1.40`. It must provide:

    messaging_operation_type :: AttributeKey Text
    messaging_operation_name :: AttributeKey Text
    messaging_kafka_destination_partition :: AttributeKey Int64
    messaging_kafka_message_offset :: AttributeKey Int64

The Kafka adapter should derive Kafka-specific wire keys with `unkey
Sem.messaging_kafka_destination_partition` and `unkey
Sem.messaging_kafka_message_offset`. The framework-level operation key should
come from `shibuya-core` through `Shibuya.Telemetry.Semantic`, not by duplicating
generic key construction in the adapter.

Runtime services used only for integration and smoke validation are Redpanda (a
Kafka-compatible broker) and Jaeger (an OpenTelemetry trace viewer) as defined
by `process-compose.yaml`.
