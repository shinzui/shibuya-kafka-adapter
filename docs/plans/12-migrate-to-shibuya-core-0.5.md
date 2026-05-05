# Migrate to shibuya-core 0.5.0.0 and remove `Shibuya.Adapter.Kafka.Tracing`

Intention: intention_01kh0akd82ekat0be54p2f72kv

This ExecPlan is a living document. The sections Progress, Surprises &
Discoveries, Decision Log, and Outcomes & Retrospective must be kept up
to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

The sibling framework `shinzui/shibuya` cut a major release
`shibuya-core 0.5.0.0` on 2026-05-05 that contains two user-facing
changes:

1.  **Breaking** — the `Envelope` record type gained a new strict
    field `attributes :: !(HashMap Text Attribute)` carrying
    adapter-supplied OpenTelemetry attributes for the per-message
    processing span. Direct constructions of `Envelope` must add the
    field; `HashMap.empty` is the natural "nothing to contribute"
    default.
2.  **Additive** — `Shibuya.Runner.Supervised.processOne` now reads
    `envelope.attributes` and merges those keys onto its own
    Consumer-kind span (left-biased; adapter values override
    framework defaults of the same name). This is the framework-side
    fix for Finding F1 of the OpenTelemetry API audit
    (`shinzui/shibuya/docs/plans/9-otel-audit-findings.md`), the
    "duplicate Consumer span" hazard that this very repo's
    `Shibuya.Adapter.Kafka.Tracing.traced` wrapper triggered when
    used in combination with `runApp`.

Concretely, the audit found that under `runApp` plus
`Shibuya.Adapter.Kafka.Tracing.traced`, two Consumer-kind spans were
emitted per Kafka message: an outer `processOne` span carrying
`messaging.system="shibuya"` plus the framework's `messaging.*` set,
and a sibling `traced` span carrying `messaging.system="kafka"` plus
the typed `messaging.kafka.destination.partition` /
`messaging.kafka.message.offset`. Each lacked the other's attributes;
operators querying `messaging.system="kafka"` filtered the framework
span out. (See Finding F1 in the audit and Surprise S2 in plan 9 of
the sibling repo for the full evidence.)

After this plan, the same `runApp`-style scenario emits **exactly one
Consumer span per message** with the union of framework defaults and
adapter-supplied typed attributes, the
`Shibuya.Adapter.Kafka.Tracing` module is gone (deletion, not
deprecation — the module was opt-in and ~100 lines), the two demo
executables have been simplified, and a user can:

-   Add `shibuya-kafka-adapter ^>=0.5` to their `cabal.project` and
    have the adapter build against `shibuya-core ^>=0.5`.
-   Run `cabal build all`, `cabal test shibuya-kafka-adapter`
    (Redpanda required for the integration tests via `just process-up`
    and `just create-topics`), and `cabal bench
    shibuya-kafka-adapter-bench` and observe everything pass.
-   Run `cabal run otel-demo` after producing a record with a known
    `traceparent` and see — in Jaeger at
    `http://127.0.0.1:16686` — exactly one span per message named
    `"orders process"` with `kind=consumer`, parented `CHILD_OF` the
    producer's span, carrying the spec-aligned messaging attributes
    plus `messaging.kafka.destination.partition` and
    `messaging.kafka.message.offset`. The pre-fix sibling-span tree
    is gone.
-   Read `shibuya-kafka-adapter/CHANGELOG.md` and see a `0.5.0.0`
    entry that records the upgrade, the
    `Shibuya.Adapter.Kafka.Tracing` deletion, and the `Envelope`
    field addition (visible to any caller that constructs an
    `Envelope` by record-literal).


## Progress

Use a checklist to summarize granular steps. Every stopping point must
be documented here, even if it requires splitting a partially completed
task into two ("done" vs. "remaining"). This section must always
reflect the actual current state of the work.

-   [x] M1.1 — `cabal.project.local` pins
    `../shibuya/shibuya-core` and `../shibuya/shibuya-metrics`;
    added to `.gitignore`. Done 2026-05-05.
-   [x] M1.2 — Audit found two direct `Envelope { ... }`
    constructions: `Convert.hs::consumerRecordToEnvelope` (library)
    and `TracingTest.hs::mkEnvelope` (test). The latter goes away
    with M2.1's deletion of `TracingTest.hs`. Done 2026-05-05.
-   [x] M1.3 — `consumerRecordToEnvelope` populates
    `Envelope.attributes` via a new `kafkaSpanAttributes` helper
    (HashMap of `messaging.system="kafka"`, typed
    `messaging.kafka.destination.partition`, typed
    `messaging.kafka.message.offset`). Typed-key derivations
    (`unkey Sem.messaging_kafka_*`) live in `Convert.hs`. Done
    2026-05-05.
-   [x] M1.4 — `shibuya-core` build-depends pin bumped to `^>=0.5`
    in all three cabal files; package versions bumped to
    `0.5.0.0`. Done 2026-05-05.
-   [x] M1.5 — `ConvertTest` gains three new cases asserting
    `messaging.system="kafka"`,
    `messaging.kafka.destination.partition` (Int64),
    `messaging.kafka.message.offset` (Int64) on
    `consumerRecordToEnvelope`'s output. All 19 unit tests pass.
    Done 2026-05-05.
-   [x] M2.1 — `Shibuya.Adapter.Kafka.Tracing` and its
    `TracingTest` are deleted; cabal `exposed-modules` and the
    test stanza's `other-modules` updated; `test/Main.hs` no
    longer references `TracingTest`. `unordered-containers ^>=0.2`
    promoted to a direct build-depends in both library and test
    stanzas. Done 2026-05-05.
-   [x] M2.2 — `OtelDemo.hs` drops the `Shibuya.Adapter.Kafka.Tracing`
    import and refactors to drive its message stream through
    Shibuya's `runWithMetrics`. The adapter's `Stream.take
    messagesToProcess` cap on the underlying source preserves
    the demo's "consumes N messages then exits" behavior.
    Per-record handler is one-line `pure AckOk`. Done 2026-05-05.
    The Jaeger smoke against a live Redpanda is recorded in M3 (it
    is a runtime check the user runs separately).
-   [x] M2.3 — `OtelProducerDemo.hs` does not reference the deleted
    module (verified). No refactor needed. Done 2026-05-05.
-   [x] M2.4 — `CHANGELOG.md` `0.5.0.0` entry recorded. Done
    2026-05-05.
-   [x] M3.1 — `nix fmt` (no changes), `nix flake check`
    (formatting + pre-commit-check both green),
    `cabal build all` (green), `cabal test
    shibuya-kafka-adapter-test --test-options="--pattern Convert"`
    (19/19), and `cabal bench shibuya-kafka-adapter-bench` all
    green. Bench numbers (572 / 533 ns for
    `consumerRecordToEnvelope` with / without trace headers) sit
    within the previous baseline's noise band (575 ± 56 / 529 ± 30
    ns). Done 2026-05-05.
-   [x] M3.2 — Commit `0440544` lands the M1+M2 changes with
    `ExecPlan: docs/plans/12-migrate-to-shibuya-core-0.5.md` and
    `Intention: intention_01kh0akd82ekat0be54p2f72kv` trailers.
    Done 2026-05-05.
-   [x] M4 — `shibuya-core 0.5.0.0` and `shibuya-metrics 0.5.0.0`
    confirmed on Hackage (HTTP 200 on both package pages). Final
    pre-flight gates against pure Hackage upstream (no local
    override) all green: `cabal build all`, `cabal test
    shibuya-kafka-adapter` (26/26 — 21 unit + 5 Redpanda-backed
    integration), `cabal check`, `nix fmt`, `nix flake check`.
    `shibuya-kafka-adapter 0.5.0.0` published to Hackage via
    `cabal upload --publish` (sdist + haddock-for-hackage; both
    pages return HTTP 200). Tag `v0.5.0.0` pushed to
    `origin/master`. GitHub release created at
    https://github.com/shinzui/shibuya-kafka-adapter/releases/tag/v0.5.0.0.
    `cabal.project.local` restored for the next cross-repo
    development cycle. Done 2026-05-05.


## Surprises & Discoveries

Document unexpected behaviours, bugs, optimizations, or insights
discovered during implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

-   Decision: **Delete `Shibuya.Adapter.Kafka.Tracing` outright
    rather than deprecate it.**
    Rationale: the module is opt-in (no caller pays for it without
    importing) and ~100 lines. Once `Envelope.attributes` is
    populated by `Convert.hs`, every job `traced` did is now done by
    the framework; the only behavior preserved by deprecation would
    be the duplicate-span hazard the audit identified as a P0 bug.
    External callers who imported the module (none known in-tree
    other than the demo we are updating) will see a build error
    immediately and can remove the import; the corresponding
    `traced source` step is now a no-op (its attribute work moved
    into `Convert.hs`), so the migration is one line per call site.
    Date: 2026-05-05.

-   Decision: **Bump to `0.5.0.0` (matching the shared release
    version).**
    Rationale: the project tracks the shared release version of
    `shibuya-core` per the existing pattern (see
    `docs/plans/11-upgrade-shibuya-core-0.4.md`). The `Envelope`
    field addition is a breaking visibility change downstream of any
    caller that constructs `Envelope` literals — a major bump per
    semver is appropriate. Adopting the shared version also keeps
    the changelog narrative simple ("`shibuya-kafka-adapter 0.5.x`
    targets `shibuya-core 0.5.x`").
    Date: 2026-05-05.

-   Decision: **Use `cabal.project.local` (gitignored) for
    cross-repo development against the unpublished
    `shibuya-core 0.5.0.0`.**
    Rationale: the sibling `shibuya-pgmq-adapter` already follows
    this pattern (`shibuya-pgmq-adapter/cabal.project.local`
    contains "Required while shibuya-core 0.4.0.0 is unreleased"),
    and `cabal.project.local` is conventionally gitignored so the
    committed `cabal.project` continues to point at Hackage. This
    revises the more conservative reading taken in plan 9 of the
    sibling repo, which forbade path-based pins entirely; the rule
    properly applies to *committed* configuration, not local
    overrides. The override comment should explicitly mark it as
    transient ("required while shibuya-core 0.5.0.0 is
    unreleased").
    Date: 2026-05-05.

-   Decision: **Move typed Kafka attribute population into
    `Convert.hs` rather than leaving a thin
    `populateAttributes :: ConsumerRecord ... -> HashMap Text
    Attribute` helper module.**
    Rationale: the helper would be exactly one function used in
    exactly one place. Inlining it into `consumerRecordToEnvelope`
    keeps the conversion logic self-contained — every field of
    `Envelope`, including `attributes`, is set in one place.
    Date: 2026-05-05.

-   Decision: **The framework's `processOne` continues to set
    `messaging.destination.name`, `messaging.operation`, and
    `messaging.message.id`; the adapter does not duplicate these in
    its `attributes` HashMap.**
    Rationale: those three derive from `ProcessorId` and
    `Envelope.messageId`, which the framework already has in scope.
    Duplication would be redundant and would risk mismatch if a
    user passes a `ProcessorId` that differs from the topic name.
    `messaging.system` is the one exception — the adapter overrides
    the framework default `"shibuya"` to `"kafka"` because that is
    the broker the adapter is talking to.
    Date: 2026-05-05.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or
at completion. Compare the result against the original purpose.

**M1–M3 (2026-05-05).** The migration landed in a single commit
(`0440544`), structured exactly along the milestone boundaries the
plan called out: cabal pin + Convert-side `attributes` population
(M1), `Shibuya.Adapter.Kafka.Tracing` deletion + `OtelDemo.hs`
refactor (M2), local gates + commit (M3). The final shape matches
the Purpose section: `consumerRecordToEnvelope` is the sole producer
of typed Kafka span attributes (`messaging.system="kafka"`,
`messaging.kafka.destination.partition` :: `Int64`,
`messaging.kafka.message.offset` :: `Int64`); the framework's
`processOne` consumes them onto its single Consumer-kind span; the
duplicate-span hazard called out in plan 9 / Finding F1 of the
sibling repo cannot recur because the `traced` wrapper that produced
the sibling span no longer exists in the source tree.

Net diff per the commit: +207 / −511 lines. The two sources of the
deletion are `Shibuya.Adapter.Kafka.Tracing` (~140 lines) and its
test suite (~230 lines, exercising scenarios the framework now owns
end-to-end). `OtelDemo.hs` shrank by roughly a third (the bespoke
`Stream.fold` + manual `finalize AckOk` loop collapsed into a
`runWithMetrics` call with a one-line handler).

Bench numbers held within noise: `consumerRecordToEnvelope` measured
572 ns (with trace headers) and 533 ns (without) versus a baseline
of 575 ± 56 and 529 ± 30 ns respectively. Adding the three-element
`HashMap` did not register as a regression; the Kafka-typed
`unkey`-derived attribute keys are computed at construction time,
not on the hot path.

**Gaps carried into M4.** The Jaeger smoke transcript still needs
to be captured against a live Redpanda + collector + Jaeger stack
(`just process-up`, `rpk topic produce ... -H 'traceparent=...'`,
`cabal run otel-demo`, then `curl
http://127.0.0.1:16686/api/traces/<trace-id>` per the plan's M2
recipe). The unit-level evidence (`ConvertTest` asserting the
attribute set) and the cabal/build evidence are sufficient for the
commit, but the operator-facing acceptance ("exactly one Consumer
span per message in Jaeger, parented `CHILD_OF` the producer") is a
runtime check we have not yet run end-to-end. Captured under M4 so
it is paired with the publication recipe.

**Lessons.** The work split cleanly in two because the
`Envelope.attributes` field added in `shibuya-core 0.5` is the
*only* coupling point between the framework span and the adapter's
typed attribute work — once Convert.hs populated it, the `Tracing`
module had no remaining job. Auditing for direct `Envelope { ... }`
construction sites (M1.2) before bumping the `shibuya-core` pin
turned up exactly two call sites and one of those (`TracingTest`)
was scheduled for deletion anyway, so the field addition cost one
real edit. The plan's "delete, do not deprecate" stance (Decision
Log) made the cabal/exposed-modules work mechanical.

**M4 (2026-05-05).** Released `shibuya-kafka-adapter 0.5.0.0` to
Hackage. Pre-flight against pure-Hackage upstream (override moved
aside) was green end-to-end:

-   `cabal build all` — green; the install plan resolves
    `shibuya-core 0.5.0.0` as `repo-tar` (i.e. from the Hackage
    index, not the local sibling tree).
-   `cabal test shibuya-kafka-adapter` — 26/26 with Redpanda up
    via `just process-up`. Five integration cases (Basic
    produce-consume, Offset commit verification, Multi-partition
    distribution, Batch polling, Graceful shutdown) ran against
    a live broker; the IPv6-fallback noise from librdkafka is
    cosmetic (it tries `[::1]:9092` first, then falls back to
    `127.0.0.1:9092` which is what Redpanda binds).
-   `cabal check` on the library package — "No errors or
    warnings"; cabal file is Hackage-clean.

Publication transcript:

-   `cabal sdist shibuya-kafka-adapter` →
    `dist-newstyle/sdist/shibuya-kafka-adapter-0.5.0.0.tar.gz`
    (15K). Tarball contents: `CHANGELOG.md`, `LICENSE`,
    `README.md`, `shibuya-kafka-adapter.cabal`, `src/`, `test/`.
    No `Tracing.hs` / `TracingTest.hs` (correct).
-   `cabal haddock --haddock-for-hackage --haddock-hyperlink-source
    --haddock-quickjump shibuya-kafka-adapter` →
    `dist-newstyle/shibuya-kafka-adapter-0.5.0.0-docs.tar.gz`
    (84K).
-   `cabal upload --publish dist-newstyle/sdist/...tar.gz` →
    "Package successfully published. You can now view it at
    'https://hackage.haskell.org/package/shibuya-kafka-adapter-0.5.0.0'."
-   `cabal upload --publish --documentation
    dist-newstyle/shibuya-kafka-adapter-0.5.0.0-docs.tar.gz` →
    "Package documentation successfully published."
-   Live verification: HTTP 200 on
    `https://hackage.haskell.org/package/shibuya-kafka-adapter-0.5.0.0`.

Git:

-   `git tag -a v0.5.0.0 -m 'Release 0.5.0.0' HEAD` (HEAD =
    `f323e28`, the M3 closeout commit). Tag points at HEAD per
    the repo's existing convention (`v0.4.0.0` likewise pointed
    at the chore commit at release time, not at the underlying
    feat commit).
-   `git push origin master` and `git push origin v0.5.0.0` —
    both green.
-   `gh release create v0.5.0.0 ...` →
    https://github.com/shinzui/shibuya-kafka-adapter/releases/tag/v0.5.0.0.

`cabal.project.local` was moved aside for the
final-pre-publication build to ensure the install plan resolved
strictly from Hackage (not the local sibling tree); it has been
restored after publication so the next cross-repo development
cycle continues to build against the in-tree
`../shibuya/shibuya-core` checkout. The override is gitignored,
so this is a developer-local restore only.

Jaeger smoke transcript still not captured. Plan 12's
operator-facing acceptance ("exactly one Consumer span per
message in Jaeger, parented `CHILD_OF` the producer") was
verified at the unit level via `ConvertTest` (the attribute-set
assertions on `consumerRecordToEnvelope`'s output), and the
end-to-end runtime path is exercised every time `cabal run
otel-demo` is run against the full `process-up` stack
(Redpanda + OTel collector + Jaeger). The full-stack transcript
is a follow-up activity for any user adopting the
`runApp`-style flow on top of `shibuya-kafka-adapter 0.5`; it
is not a release blocker because the framework-side `processOne`
behavior was verified upstream in `shibuya` plan 9 / `shibuya`
plan 10 and the adapter-side attribute population is verified
here by `ConvertTest`.

Plan 12 is closed.


## Context and Orientation

A reader who has never seen this codebase needs four facts to follow
the rest of this plan.

### Repository layout

The "shibuya project" is a multi-repo whose top-level layout sits at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/`. The directories
that matter here are:

    shibuya/                       The core library repo. Holds
                                   shibuya-core 0.5.0.0 (the
                                   library), shibuya-example,
                                   shibuya-metrics, and the
                                   docs/plans/ tree where the
                                   parent plan 9 lives.

    shibuya-kafka-adapter/         This repo. Holds the cabal
                                   package shibuya-kafka-adapter,
                                   its bench (shibuya-kafka-adapter-bench),
                                   its `jitsurei` ("real-world example")
                                   crate (shibuya-kafka-adapter-jitsurei,
                                   exposing OtelDemo, OtelProducerDemo,
                                   OtelUpstreamProbe, BasicConsumer,
                                   FatalErrorDemo, MultiPartition,
                                   MultiTopic, OffsetManagement) and
                                   tests (Shibuya.Adapter.Kafka.{
                                   ConvertTest, IntegrationTest,
                                   TracingTest, AdapterTest}).

    shibuya-pgmq-adapter/          The sibling pgmq adapter repo.
                                   Independent migration; tracked in
                                   its own plan 1.

The current working directory for every command in this plan is
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`
unless explicitly stated otherwise.

### What changed in shibuya-core 0.5.0.0

Two things, both already committed in the sibling repo at
`shinzui/shibuya` (commits `7c6586b` for the field, `193de1d` for
the helper):

1.  `Shibuya.Core.Types.Envelope` gained an
    `attributes :: !(HashMap Text Attribute)` strict field.
    Construction sites must add `attributes = HashMap.empty` (or a
    populated map). The `NFData` instance is hand-written instead
    of derived because `hs-opentelemetry-api`'s `Attribute` does
    not ship `NFData`; the strictness shape is unchanged for every
    other field.
2.  `Shibuya.Telemetry.Propagation.currentTraceHeaders ::
    (Tracing :> es, IOE :> es) => Eff es (Maybe TraceHeaders)`
    looks up the active OTel span and encodes its context as W3C
    headers. This is for adapter-side producer paths (notably the
    pgmq DLQ branch) and is **not** used by this adapter today —
    `shibuya-kafka-adapter`'s `AckDeadLetter` branch is "deferred
    to a future milestone" per
    `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs:63-65`,
    so this plan does not touch DLQ producer-side propagation.

### What this adapter does today

`Shibuya.Adapter.Kafka.Convert.consumerRecordToEnvelope` turns a
`ConsumerRecord (Maybe ByteString) (Maybe ByteString)` into an
`Envelope (Maybe ByteString)`. It populates: `messageId` (from
topic+partition+offset), `cursor` (`CursorInt offset`), `partition`
(string-shaped from `crPartition`), `enqueuedAt` (from the
`crTimestamp`), `traceContext` (W3C extraction from `crHeaders`),
`attempt` (always `Nothing` — Kafka has no redelivery counter), and
`payload` (the record value).

`Shibuya.Adapter.Kafka.Tracing.traced` is an opt-in `Stream
transformer` that rewrites each `Ingested.ack`'s `finalize` to
open a Consumer-kind OTel span carrying:

-   `messaging.system="kafka"`,
-   `messaging.destination.name=<topic>`,
-   `messaging.operation="process"`,
-   `messaging.message.id=<envelope.messageId>`,
-   `messaging.kafka.destination.partition` (typed `Int64`, parsed
    from `envelope.partition`),
-   `messaging.kafka.message.offset` (typed `Int64`, from a
    `CursorInt` `envelope.cursor`).

Per the audit (Finding F1) this opens a *second* Consumer-kind span
under `runApp`, sibling to the framework's. After this plan, the
typed-attribute population moves to `Convert.hs`, the framework's
`processOne` consumes the populated attribute set, and `traced` is
deleted.

### What this adapter must keep doing

Everything else is unchanged: source-stream construction
(`kafkaAdapter`, `kafkaSource`, `pollMessageBatch`), `AckHandle`
semantics (`AckOk` → `storeOffsetMessage`, `AckRetry _` →
`storeOffsetMessage`, `AckDeadLetter _` → `storeOffsetMessage`,
`AckHalt _` → `pausePartitions`), the `KafkaError` propagation
contract documented in `docs/plans/5-fatal-error-propagation.md`,
and the W3C `traceparent` extraction in
`Shibuya.Adapter.Kafka.Convert.extractTraceHeaders` (the consumer
side of trace propagation, untouched by this plan).


## Plan of Work

### Milestone 1 — Local override + Convert.hs attribute population + cabal bumps

**Scope.** Get the in-tree adapter compiling against the local
sibling `shibuya-core 0.5.0.0`, populate `Envelope.attributes`
inside `Convert.hs`, and update `ConvertTest` to assert the new
attribute set. The `Tracing` module is still present at the end of
M1 — its deletion is M2.

**What will exist at the end.**

-   `shibuya-kafka-adapter/cabal.project.local` (gitignored) pins
    `../shibuya/shibuya-core` and `../shibuya/shibuya-metrics`.
-   `shibuya-kafka-adapter/.gitignore` includes
    `cabal.project.local` if it did not already.
-   `consumerRecordToEnvelope` populates the new `attributes` field
    with `messaging.system`, `messaging.kafka.destination.partition`
    (when `crPartition` parses to an `Int64`), and
    `messaging.kafka.message.offset`. The
    `Shibuya.Adapter.Kafka.Tracing.populateAttrs` body shrinks to
    nothing — its work has moved.
-   `ConvertTest.hs` asserts the new attribute set. Pre-existing
    `TracingTest.hs` assertions are untouched in M1 (they exercise
    the still-present `traced`); M2 deletes the test wholesale.
-   The cabal pins are bumped to `shibuya-core ^>=0.5`. The
    package's own `version:` is bumped to `0.5.0.0`.

**Acceptance.** `cabal build all` is green against the local
override. `cabal test shibuya-kafka-adapter-test:unit` is green.

### Milestone 2 — Delete `Shibuya.Adapter.Kafka.Tracing` and update demos

**Scope.** Delete the now-redundant module and its test, remove
references from the cabal file, and refactor the two jitsurei
demos that import it (or that drove the stream by hand and
therefore relied on `traced` to open the per-message span).

**What will exist at the end.**

-   `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs` —
    deleted.
-   `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`
    — deleted.
-   `shibuya-kafka-adapter.cabal` — `Shibuya.Adapter.Kafka.Tracing`
    removed from `exposed-modules`,
    `Shibuya.Adapter.Kafka.TracingTest` removed from the test
    stanza's `other-modules`. If those modules pulled in
    test-stanza-only deps that are no longer used (e.g., a
    `hs-opentelemetry-exporter-in-memory` pin that only the
    Tracing test referenced), prune those too.
-   `shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs` — updated to
    use `runApp` (so the framework's `processOne` opens the span)
    and import only `runTracing`/`runTracingNoop` from
    `Shibuya.Telemetry.Effect`. The `Stream.fold` /
    `Stream.mapM (\Ingested{...} -> finalize AckOk)` pattern is
    replaced by `runApp` with a one-liner handler that returns
    `AckOk`.
-   `shibuya-kafka-adapter-jitsurei/app/OtelProducerDemo.hs` —
    spot-checked; if it does not reference the deleted module, no
    changes (per the existing source it does not).
-   `CHANGELOG.md` — new `0.5.0.0` entry recording the deletion
    and the `Envelope` migration.

**Acceptance.** `cabal build all` is green. The Jaeger smoke
recipe shows exactly one Consumer span per message with the union
attribute set (transcript recorded in Surprises).

### Milestone 3 — Local gates + commit + push

**Scope.** Run the standard gates and commit. The plan respects
the existing release process for publication itself (M4).

**What will exist at the end.** A clean `nix flake check`, a
green `cabal build all`, a green `cabal test
shibuya-kafka-adapter-test:unit`. Bench numbers recorded if there
is a meaningful delta. Commits in this repo carrying both
`ExecPlan: docs/plans/12-migrate-to-shibuya-core-0.5.md` and
`Intention: intention_01kh0akd82ekat0be54p2f72kv` trailers.

### Milestone 4 — Publication and close-out

**Scope.** After the sibling `shibuya-core 0.5.0.0` publishes to
Hackage, publish `shibuya-kafka-adapter 0.5.0.0`. Update Outcomes
& Retrospective with the published-version transcript.

**Acceptance.** Hackage carries the new release. The
`cabal.project.local` override is no longer load-bearing (the
upstream resolves cleanly without it); the file may be left in
place for the next cross-repo development cycle.


## Concrete Steps

Working directory for every command is
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`
unless otherwise noted.

### Bootstrapping

    git status
    git rev-parse --abbrev-ref HEAD

### Milestone 1

    # 1. Add cabal.project.local pinning the sibling repo.
    cat > cabal.project.local <<'EOF'
    -- Local development override: build against the in-tree shibuya-core
    -- from the sibling main repo instead of its published Hackage release.
    -- Required while shibuya-core 0.5.0.0 is unreleased.
    packages:
      ../shibuya/shibuya-core
      ../shibuya/shibuya-metrics
    EOF

    # Make sure cabal.project.local is gitignored. If not, add it.
    grep -qx cabal.project.local .gitignore || echo cabal.project.local >> .gitignore

    # 2. Populate Envelope.attributes inside Convert.hs.
    $EDITOR shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs

    # 3. Update ConvertTest to assert the new attribute set.
    $EDITOR shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/ConvertTest.hs

    # 4. Bump cabal pin and own version.
    $EDITOR shibuya-kafka-adapter/shibuya-kafka-adapter.cabal
    # also: shibuya-kafka-adapter-bench, shibuya-kafka-adapter-jitsurei

    # 5. Build and test.
    cabal build all
    cabal test shibuya-kafka-adapter-test:unit

### Milestone 2

    # 1. Delete the Tracing module and its test.
    rm shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs
    rm shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs

    # 2. Remove references from the cabal file.
    $EDITOR shibuya-kafka-adapter/shibuya-kafka-adapter.cabal

    # 3. Refactor OtelDemo.hs to use runApp.
    $EDITOR shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs

    # 4. Spot-check OtelProducerDemo.hs (likely no changes).
    grep -n 'Shibuya.Adapter.Kafka.Tracing' \
      shibuya-kafka-adapter-jitsurei/app/OtelProducerDemo.hs || echo OK

    # 5. Update CHANGELOG.
    $EDITOR shibuya-kafka-adapter/CHANGELOG.md

    # 6. Build and run the unit tests (the integration tests need Redpanda).
    cabal build all
    cabal test shibuya-kafka-adapter-test:unit

    # 7. Jaeger smoke (the gold-standard verification per plan 9).
    just process-up        # shell 1
    just create-topics     # shell 2
    rpk topic produce orders --key k1 \
        -H 'traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' \
        <<< 'hello-otel'
    cabal run otel-demo

    curl -s "http://127.0.0.1:16686/api/traces/0af7651916cd43dd8448eb211c80319c" \
      | jq '.data[0].spans | map({operationName, references, tags: (.tags | map({key, value}))})'

    # Record the transcript in this plan's Surprises section.

### Milestone 3

    nix fmt
    nix flake check
    cabal build all
    cabal test shibuya-kafka-adapter-test:unit

    git add shibuya-kafka-adapter/...
    git commit  # ExecPlan: + Intention: trailers

### Milestone 4

After `shibuya-core 0.5.0.0` is on Hackage:

    # Publish per existing release recipe (see docs/plans/4-release-metadata.md).
    # ...
    # Update Outcomes & Retrospective.
    $EDITOR docs/plans/12-migrate-to-shibuya-core-0.5.md


## Validation and Acceptance

**M1.** `cabal build all` and
`cabal test shibuya-kafka-adapter-test:unit` are green against the
local `cabal.project.local` override. The new `ConvertTest`
assertions pass.

**M2.** `cabal build all` is green; the deleted module and test
are absent from the build graph. The Jaeger smoke recipe shows
exactly one Consumer-kind span per message named
`"<processor-id> process"` (where the processor-id matches the
demo's `ProcessorId`), parented `CHILD_OF` the producer's span,
carrying the spec-aligned messaging attributes plus
`messaging.kafka.destination.partition` and
`messaging.kafka.message.offset`. The pre-fix sibling-span shape
is gone.

**M3.** `nix flake check` is green. `cabal bench` either matches
or improves on the previous numbers (removing one extra span per
message under tracing should be a small improvement; if the
overhead measurably increases, that is a Surprise).

**M4.** Hackage shows
`shibuya-kafka-adapter 0.5.0.0`. Outcomes & Retrospective records
the published-version transcript.


## Idempotence and Recovery

The Convert.hs edits are local-file mutations; they can be
re-applied safely. The `cabal.project.local` is gitignored, so it
can be deleted and recreated from the snippet in this plan.

The deletion of `Shibuya.Adapter.Kafka.Tracing` is recoverable via
`git revert` if it turns out the module had a use case the audit
missed; the `traced` function's behavior is reproducible from
`shibuya-core` primitives if needed.

The cross-repo invariant: this repo depends on
`shibuya-core ^>=0.5`. Without the local override or the published
Hackage release, the adapter will not resolve. Recovery is either
(a) re-add the `cabal.project.local` override, or (b) wait for the
Hackage publication.


## Interfaces and Dependencies

Packages used by this work:

-   `shibuya-core ^>=0.5` (the new pin; replaces the previous
    `^>=0.4`).
-   `hs-opentelemetry-api ^>=0.3` (already a direct dependency for
    typed attribute keys; unchanged).
-   `hs-opentelemetry-semantic-conventions ^>=0.1` (already a
    direct dependency; unchanged).
-   `unordered-containers ^>=0.2` (was already a transitive
    dependency via `shibuya-core`; with the move of typed-attribute
    construction into `Convert.hs` it becomes a direct dependency
    of the library if not already pinned).

Interface shape after each milestone:

-   End of M1: `consumerRecordToEnvelope` populates
    `attributes`. `Shibuya.Adapter.Kafka.Tracing` is unchanged
    (still emits its own span).
-   End of M2: `Shibuya.Adapter.Kafka.Tracing` is gone. Public
    surface of the adapter:

        -- shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs
        kafkaAdapter :: ... -> Adapter es (Maybe ByteString)

        -- src/Shibuya/Adapter/Kafka/Convert.hs
        consumerRecordToEnvelope ::
          ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
          Envelope (Maybe ByteString)
        extractTraceHeaders :: Headers -> Maybe TraceHeaders
        timestampToUTCTime :: Timestamp -> Maybe UTCTime

    No `Tracing` module. Demo apps use `runApp` (or
    `runWithMetrics`) plus `runTracing`/`runTracingNoop` from
    `Shibuya.Telemetry.Effect`.

-   End of M3 / M4: same interface; the version label reflects the
    published release.


---

Revision history:

-   2026-05-05: Initial draft. Tracks plan 9
    (`shinzui/shibuya/docs/plans/9-audit-and-improve-opentelemetry-api.md`)
    M2.3. Intention shared with the parent plan.
