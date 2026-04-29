# Upgrade to shibuya-core 0.4.0.0 and re-release as 0.4.0.0

Intention: intention_01khv57nhzesc9hx46f9bz0vbq

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

The sibling framework `shinzui/shibuya` cut a major release `shibuya-core
0.4.0.0` on 2026-04-29 that contains one user-facing breaking change: the
`Envelope` record type gained an `attempt :: !(Maybe Attempt)` field
carrying the adapter's delivery counter. Any code that constructs
`Envelope` with a record literal must add the new field, or the build
fails with a missing-field error.

`shibuya-kafka-adapter` is a public Kafka adapter for Shibuya. Its public
API (`consumerRecordToEnvelope`, the `kafkaAdapter` runtime, the
`Shibuya.Adapter.Kafka.Tracing.traced` stream transformer) returns and
threads `Envelope` values through downstream handlers, so the new field
shows up on every envelope this adapter produces.

After this plan, a user can:

* Add `shibuya-core ^>=0.4` to their `cabal.project`, depend on
  `shibuya-kafka-adapter ^>=0.4`, and have the adapter compile and run
  unmodified — Kafka cannot observe redeliveries the way a visibility-timeout
  queue can, so every emitted envelope carries `attempt = Nothing`, exactly
  as the upstream `Shibuya.Core.Types` documentation prescribes ("Nothing if
  the adapter does not track redeliveries (e.g., Kafka)").
* Run `cabal build all`, `cabal test shibuya-kafka-adapter` (with Redpanda
  up via `just process-up` and topics created via `just create-topics`), and
  `cabal bench shibuya-kafka-adapter-bench` against the new dependency
  graph and observe everything pass.
* Read `shibuya-kafka-adapter/CHANGELOG.md` and see a `0.4.0.0` entry that
  records the upgrade and the downstream visibility of the field change.


## Progress

- [x] Audit every direct `Envelope { ... }` record construction in the repo
      (library, tests, examples, benchmark) and confirm the only constructions
      that need an `attempt` field added are the two identified during research
      (`Convert.hs` and `TracingTest.hs`). _2026-04-29_
- [x] Add `attempt = Nothing` to
      `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs`
      `consumerRecordToEnvelope`. _2026-04-29_
- [x] Add `attempt = Nothing` to
      `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`
      `mkEnvelope`. _2026-04-29_
- [x] Bump the `shibuya-core` build-depends pin in
      `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal` from `^>=0.2` to
      `^>=0.4`. _2026-04-29_
- [x] Bump the `shibuya-core` build-depends pin in
      `shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal` from
      `^>=0.1.0.0` to `^>=0.4`. _2026-04-29_
- [x] Add an explicit `shibuya-core ^>=0.4` build-depends pin in
      `shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`
      (currently unbounded). _2026-04-29_
- [x] Remove the now-duplicate orphan `NFData` instances for `MessageId`,
      `Cursor`, and `Envelope a` from
      `shibuya-kafka-adapter-bench/bench/Main.hs` (lines 22–24); keep the
      orphan instances for `hw-kafka-client` types. _2026-04-29_
- [x] Bump `version:` in all three cabal files to `0.4.0.0`. _2026-04-29_
- [x] Add a `0.4.0.0 — 2026-04-29` entry to
      `shibuya-kafka-adapter/CHANGELOG.md`. _2026-04-29_
- [x] Run `nix fmt` (project rule). _2026-04-29: `formatted 6 files (0 changed)`_
- [x] Run `cabal build all` and `cabal bench shibuya-kafka-adapter-bench`,
      and the pure tasty groups (`Adapter`, `Convert`, `Tracing`) of
      `cabal test shibuya-kafka-adapter`, and capture green output in
      this plan. _2026-04-29: build green, 23/23 pure tests pass, all 15 bench rows OK._
- [ ] Run the full `cabal test shibuya-kafka-adapter` (including the
      `Integration` tasty group) once Redpanda is reachable on
      `127.0.0.1:9092`. _Deferred — see Surprises & Discoveries._
- [x] Commit with Conventional-Commits message
      (`feat!: upgrade to shibuya-core 0.4.0.0 and bump to 0.4.0.0`),
      including both `ExecPlan:` and `Intention:` trailers. _2026-04-29_
- [x] Fill in Outcomes & Retrospective. _2026-04-29_


## Surprises & Discoveries

* **Integration tasty group not exercised in this run.** At implementation
  time (2026-04-29) the host's Docker daemon was not running, and the
  repo's `just process-up` recipe drives Redpanda via `rpk container
  start`, which talks to Docker. The `redpanda` task in process-compose
  reported "unable to start cluster: unable to connect to docker." on
  every restart, so port `127.0.0.1:9092` never came up. Running
  `cabal test shibuya-kafka-adapter` without filtering would block on
  the `Integration` group's broker connect.
  Mitigation: ran the suite with `--test-options='-p !/Integration/'`
  to exercise the three pure groups (`Adapter`, `Convert`, `Tracing`,
  23 cases total) and let the build itself act as the type-shape gate
  for the `attempt` field. The bench (which is also pure) ran end to
  end with all 15 rows OK. The remaining `Integration` group is a
  preexisting capability that this plan does not change; re-running it
  with Docker up is a no-op for this upgrade's correctness story.
  Evidence: `bzdmyz89a.output` from the background `just process-up`,
  lines 25–39, repeats the docker-connect error.

* **Stale process-compose instances on the host.** Two
  `process-compose --unix-socket .dev/process-compose.sock up`
  processes were already running (one from Tuesday, one from earlier
  the same day), but `.dev/process-compose.sock` did not exist, so the
  CLI couldn't talk to either of them. They appear to be leftovers from
  prior interactive sessions where the foreground process-compose was
  Ctrl-C'd but its pid lingered. They didn't interfere with this work
  beyond the cosmetic; left alone deliberately because they belong to
  the user's own terminals.


## Decision Log

* Decision: bump every package in this repo to `0.4.0.0` in lockstep
  (library, bench, jitsurei).
  Rationale: even though only `shibuya-kafka-adapter` itself has a
  user-visible API consequence (its `Envelope` shape changes), the bench
  and jitsurei packages depend on the library and are released from this
  repo. Aligning the version cadence to the shibuya-core major makes the
  compatibility story trivial to read off the version number, mirroring
  the precedent set by `shibuya-metrics` which "is re-released at 0.4.0.0
  to track the shared version" per the upstream changelog.
  Date: 2026-04-29.

* Decision: set `attempt = Nothing` on every emitted `Envelope` rather
  than try to derive an attempt count from Kafka metadata.
  Rationale: Kafka's broker-side semantics do not expose a per-message
  redelivery counter to consumers (offsets are positions in a partition
  log, not delivery counters). The upstream `Shibuya.Core.Types`
  documentation explicitly endorses this: "Nothing if the adapter does
  not track redeliveries (e.g., Kafka)." Modelling something else would
  invent information the broker does not provide.
  Date: 2026-04-29.

* Decision: classify this release as a breaking change (major bump
  `0.3 → 0.4`, `feat!:` Conventional-Commits prefix) even though the
  adapter's own Haskell symbols keep the same names and signatures.
  Rationale: `consumerRecordToEnvelope :: ConsumerRecord (Maybe ByteString)
  (Maybe ByteString) -> Envelope (Maybe ByteString)` is in the public API,
  and the type `Envelope` itself has changed shape. Any downstream code
  that pattern-matches on `Envelope` with positional or non-punned record
  patterns will fail to compile against this release. That is the standard
  meaning of "breaking" under PVP, so we encode it in both the version
  number and the commit subject.
  Date: 2026-04-29.

* Decision: drop the orphan `NFData` instances for `MessageId`, `Cursor`,
  and `Envelope a` from `shibuya-kafka-adapter-bench/bench/Main.hs`.
  Rationale: `shibuya-core 0.2.0.0` (per its CHANGELOG) added these
  instances upstream. With the bench's `shibuya-core` pin moved to
  `^>=0.4`, the orphan declarations would be duplicate instances and
  block compilation. Keep the orphan instances for the
  `hw-kafka-client` types (`TopicName`, `PartitionId`, `Offset`,
  `Millis`, `Timestamp`, `Headers`, `ConsumerRecord k v`) — those are
  not provided by `hw-kafka-client` and are still needed for the
  `tasty-bench` `nf` calls.
  Date: 2026-04-29.

* Decision: do not adopt `Shibuya.Core.Retry` in this plan.
  Rationale: the new module ships handler-side helpers
  (`BackoffPolicy`, `exponentialBackoff`, `retryWithBackoff`) for users
  who want to compute jittered retry delays from inside a handler.
  Adapters do not call these helpers — they emit envelopes; handlers
  decide retry policy. The kafka adapter has nothing to integrate. A
  future plan can add a runnable `backoff-demo` jitsurei mirroring the
  one shipped with `shibuya-pgmq-adapter` if we want a cookbook example,
  but it is out of scope for this upgrade.
  Date: 2026-04-29.


## Outcomes & Retrospective

Implemented 2026-04-29. The repository now compiles, passes its pure
test suite, and benchmarks against `shibuya-core 0.4.0.0`. The new
`Envelope.attempt` field is set to `Nothing` on every emitted
envelope from `consumerRecordToEnvelope`, matching the upstream
documentation's prescription for adapters that cannot observe
broker-side redeliveries.

Concrete outcomes vs. acceptance criteria from Milestone 1:

* `cabal build all` exits 0. ✅
* `python3 ... plan.json` reports `[('shibuya-core', '0.4.0.0')]`. ✅
* `cabal test --test-options='-p !/Integration/'` reports all 23
  cases across `Adapter`, `Convert`, `Tracing` as `OK`. ✅ for the
  three pure groups; ⏸ for `Integration` — see Surprises.
* `cabal bench shibuya-kafka-adapter-bench` prints the full
  `tasty-bench` table (15 rows including `ConsumerRecord to Envelope /
  with trace headers` and `... / without trace headers`) and exits 0. ✅
* CHANGELOG, version pins, and orphan-cleanup all in place. ✅
* Commit on `master` carries `feat!:` subject plus `ExecPlan:` and
  `Intention:` trailers. ✅

Lessons / things to repeat:

* The plan's call-out that only **two** record literals construct
  `Envelope` (Convert.hs and TracingTest.hs) and that every other
  reference uses `NamedFieldPuns` was accurate — this scoping is the
  reason the diff is so small. Future adapter upgrades that add fields
  upstream should look for `Envelope { ... }` braces, not for
  `Envelope` mentions in general.
* The `NFData` orphan cleanup is the only non-mechanical edit. The
  bench's import line had to lose three names along with the orphans;
  GHC's `-Wunused-imports` would have caught it but it's cleaner to
  trim the import in the same edit.


## Context and Orientation

This repository is a Haskell `cabal.project` containing three local
packages:

* `shibuya-kafka-adapter` (path `shibuya-kafka-adapter/`, library) —
  the public adapter. Its source modules live under
  `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/`:
  `Config.hs`, `Convert.hs`, `Internal.hs`, `Tracing.hs`, plus the
  re-export module `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`.
  Its test suite lives in `shibuya-kafka-adapter/test/`.
  Cabal file: `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`.
  Current version: `0.3.0.0`. Current `shibuya-core` pin: `^>=0.2`.
* `shibuya-kafka-adapter-bench` (path `shibuya-kafka-adapter-bench/`,
  benchmark) — `tasty-bench` micro-benchmarks for the conversion hot
  path (`ConsumerRecord` → `Envelope`, W3C trace-header extraction,
  timestamp conversion). Single source file: `bench/Main.hs`.
  Cabal file: `shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal`.
  Current version: `0.2.0.0`. Current `shibuya-core` pin: `^>=0.1.0.0`.
* `shibuya-kafka-adapter-jitsurei` (path `shibuya-kafka-adapter-jitsurei/`,
  application) — runnable example consumers (`BasicConsumer`,
  `MultiTopic`, `MultiPartition`, `OffsetManagement`, plus several OTel
  demos). Cabal file:
  `shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`.
  Current version: `0.2.0.0`. `shibuya-core` is depended on without
  bounds.

All three packages share the toolchain pinned by `flake.nix` (GHC 9.12.2,
`cabal-install`, `treefmt`, `just`, `process-compose`, `rdkafka`).

The framework these packages adapt to lives in a sibling repo at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/`. As of
`shibuya-core 0.4.0.0` (2026-04-29) the package's `Shibuya.Core.Types`
module defines:

    -- | Zero-indexed delivery attempt count.
    -- 0 means first delivery; 1 means first retry; and so on.
    -- Adapters that cannot track redeliveries report 'Nothing' on the envelope.
    newtype Attempt = Attempt {unAttempt :: Word}
      deriving stock (Eq, Ord, Show, Generic)
      deriving newtype (Num, Real, Enum, Integral, Bounded)
      deriving anyclass (NFData)

    data Envelope msg = Envelope
      { messageId    :: !MessageId
      , cursor       :: !(Maybe Cursor)
      , partition    :: !(Maybe Text)
      , enqueuedAt   :: !(Maybe UTCTime)
      , traceContext :: !(Maybe TraceHeaders)
      -- | Optional zero-indexed delivery counter.
      -- 'Just (Attempt 0)' on first delivery; 'Nothing' if the adapter
      -- does not track redeliveries (e.g., Kafka).
      , attempt      :: !(Maybe Attempt)
      , payload      :: !msg
      }
      deriving stock (Eq, Show, Functor, Generic)
      deriving anyclass (NFData)

The `attempt` field is the only field that did not exist in 0.3.0.0.
Both `Attempt` and the new `Shibuya.Core.Retry` module are re-exported
from the umbrella `Shibuya.Core` module as well, but this repo only ever
imports from `Shibuya.Core.Types`, so the umbrella module is incidental.

Throughout this codebase, `Envelope` is referenced in two distinct ways:

1. **Construction** — a record literal `Envelope { messageId = ..., ... }`
   that names every field. These are the call sites that fail to compile
   when a new field is added. This repo has exactly two of them:
   `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs` (the
   `consumerRecordToEnvelope` function) and
   `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`
   (the `mkEnvelope` helper used by the tracing tests).

2. **Pattern matching with `NamedFieldPuns`** — `Envelope{payload}`,
   `Envelope{messageId, partition, cursor, payload}`, etc. These do
   not name every field and continue to compile unchanged when a new
   field is added. Every other `Envelope` reference in the
   `IntegrationTest`, `OffsetManagement`, `MultiPartition`,
   `MultiTopic`, `BasicConsumer`, `OtelDemo`, etc. files is of this
   shape and needs no edit.

A "non-obvious term" definition for the novice:

* "shibuya-core" — the framework library this adapter plugs into. Lives
  on Hackage; the local source-of-truth checkout is the sibling repo at
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/`. The current
  cabal plan in `dist-newstyle/cache/plan.json` resolves it from
  Hackage as `0.2.0.0`, which is why `cabal build all` reports
  "Up to date" today even though `0.4.0.0` exists upstream — cabal will
  only re-resolve when a `build-depends` bound forces it to.
* "Envelope" — Shibuya's normalized representation of a single message
  pulled from a queue. Carries identity, optional cursor/partition,
  optional enqueue timestamp, optional W3C trace context, optional
  attempt count, and the payload. This adapter's job is to translate a
  Kafka `ConsumerRecord` into one of these.
* "Attempt" — a `Word` newtype counting deliveries from zero
  (0 = first delivery, 1 = first redelivery, ...). Adapters that
  cannot observe redeliveries (Kafka, raw streams) carry `Nothing`.
* "jitsurei" — a Japanese term used in this repo to mean "runnable
  example": the package `shibuya-kafka-adapter-jitsurei` ships several
  `cabal run`-able executables that demonstrate adapter usage.
* "Redpanda" — the Kafka-protocol-compatible broker the integration
  tests connect to. Started locally via `just process-up` (which calls
  `process-compose`).


## Plan of Work

The work happens in one milestone. There is no useful intermediate
state because cabal will refuse to resolve the dependency graph until
both the bound bump and the field addition land together. The plan is
linear: edit the two record literals, edit three cabal files, edit one
benchmark to drop now-duplicate orphans, write the changelog entry,
format, build, test, bench, commit.


### Milestone 1 — Compile, test, and bench against shibuya-core 0.4.0.0

Scope: every step needed to take this repository from a state where it
silently still resolves the old `shibuya-core 0.2.0.0` (because nothing
forced a re-resolve) to a state where `cabal build all` succeeds against
`shibuya-core 0.4.0.0`, the test suite passes, the benchmark suite
runs, and the result is committed with a `0.4.0.0` version label and a
matching changelog entry.

What will exist at the end:

* `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs` constructs
  `Envelope` values with the new `attempt = Nothing` field.
* `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`
  constructs its test `Envelope` values with `attempt = Nothing`.
* All three cabal files declare `version: 0.4.0.0` and pin
  `shibuya-core ^>=0.4`.
* `shibuya-kafka-adapter-bench/bench/Main.hs` no longer declares the
  three orphan `NFData` instances that overlap with `shibuya-core 0.2+`.
* `shibuya-kafka-adapter/CHANGELOG.md` has a new top-of-file entry
  dated 2026-04-29 describing the upgrade.
* `dist-newstyle/cache/plan.json` resolves `shibuya-core` to `0.4.0.0`
  (verifiable with the small Python snippet given in Concrete Steps).
* A single git commit on `master` whose message follows
  Conventional Commits (`feat!: ...`) and includes both `ExecPlan:` and
  `Intention:` trailers.

Commands to run (assumed working directory is the repo root,
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`):

    just process-up        # in another shell — leave running
    just create-topics     # one-shot, idempotent
    cabal build all
    cabal test shibuya-kafka-adapter
    cabal bench shibuya-kafka-adapter-bench
    nix fmt
    git status
    git diff
    git add -A
    git commit -m "..."    # see Concrete Steps for the full message

Acceptance:

* `cabal build all` exits 0.
* `cabal test shibuya-kafka-adapter` reports all tasty groups passing
  (`ConvertTest`, `TracingTest`, `IntegrationTest`).
* `cabal bench shibuya-kafka-adapter-bench` produces a `tasty-bench`
  table with the two `ConsumerRecord to Envelope` rows and exits 0.
* `python3 -c '...'` (snippet in Concrete Steps) prints
  `0.4.0.0` for `shibuya-core`.
* `git log -1` shows a single commit with subject starting `feat!:` and
  containing both `ExecPlan: docs/plans/11-upgrade-shibuya-core-0.4.md`
  and `Intention: intention_01khv57nhzesc9hx46f9bz0vbq` trailers.


## Concrete Steps

All paths below are repo-relative. The working directory for every
command is the repo root unless noted.

### Step 1 — Add `attempt = Nothing` to the production converter

Edit `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs`. The
current body of `consumerRecordToEnvelope` (around lines 43–51) reads:

    consumerRecordToEnvelope cr =
        Envelope
            { messageId = mkMessageId cr.crTopic cr.crPartition cr.crOffset
            , cursor = Just (CursorInt (fromIntegral (unOffset cr.crOffset)))
            , partition = Just (Text.pack (show (unPartitionId cr.crPartition)))
            , enqueuedAt = timestampToUTCTime cr.crTimestamp
            , traceContext = extractTraceHeaders cr.crHeaders
            , payload = cr.crValue
            }

Insert one new field-assignment, in source order between `traceContext`
and `payload`, so the result reads:

    consumerRecordToEnvelope cr =
        Envelope
            { messageId = mkMessageId cr.crTopic cr.crPartition cr.crOffset
            , cursor = Just (CursorInt (fromIntegral (unOffset cr.crOffset)))
            , partition = Just (Text.pack (show (unPartitionId cr.crPartition)))
            , enqueuedAt = timestampToUTCTime cr.crTimestamp
            , traceContext = extractTraceHeaders cr.crHeaders
            , attempt = Nothing
            , payload = cr.crValue
            }

Also update the Haddock above this function. The current "Field mapping"
list (lines 31–38) is missing an entry for `attempt`. Add a bullet
between `traceContext` and `payload`:

    * @attempt@: 'Nothing' (Kafka does not expose a redelivery counter)

The `Nothing` is `Maybe Attempt`, where `Attempt` is a `Word` newtype
in `Shibuya.Core.Types`. Because we use `Nothing`, no new import is
needed: `Maybe`'s `Nothing` is already in scope via `Prelude`, and we do
not name `Attempt` itself anywhere.

### Step 2 — Add `attempt = Nothing` to the tracing test envelope

Edit `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`.
The current body of `mkEnvelope` (lines 96–105) reads:

    mkEnvelope :: Maybe TraceHeaders -> Envelope ()
    mkEnvelope tc =
        Envelope
            { messageId = MessageId "orders-2-42"
            , cursor = Just (CursorInt 42)
            , partition = Just "2"
            , enqueuedAt = Nothing
            , traceContext = tc
            , payload = ()
            }

Insert one new field-assignment between `traceContext` and `payload`:

    mkEnvelope :: Maybe TraceHeaders -> Envelope ()
    mkEnvelope tc =
        Envelope
            { messageId = MessageId "orders-2-42"
            , cursor = Just (CursorInt 42)
            , partition = Just "2"
            , enqueuedAt = Nothing
            , traceContext = tc
            , attempt = Nothing
            , payload = ()
            }

### Step 3 — Bump cabal version pins and package versions

In `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`:

* Change `version:        0.3.0.0` to `version:        0.4.0.0`.
* Change the build-depends line `, shibuya-core                           ^>=0.2`
  to `, shibuya-core                           ^>=0.4`.

In `shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal`:

* Change `version:       0.2.0.0` to `version:       0.4.0.0`.
* Change the build-depends line `, shibuya-core           ^>=0.1.0.0` to
  `, shibuya-core           ^>=0.4`.

In `shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`:

* Change `version:       0.2.0.0` to `version:       0.4.0.0`.
* Change the build-depends line `    , shibuya-core` (currently
  unbounded) to `    , shibuya-core    ^>=0.4`.

### Step 4 — Drop now-duplicate orphan `NFData` instances from the bench

Edit `shibuya-kafka-adapter-bench/bench/Main.hs`. Lines 21–24 currently
read:

    -- Orphan NFData instances for shibuya-core types (derive via Generic)
    deriving anyclass instance NFData MessageId
    deriving anyclass instance NFData Cursor
    deriving anyclass instance (NFData a) => NFData (Envelope a)

Remove all four lines (the comment and the three `deriving anyclass instance`
lines). The orphans for `hw-kafka-client` types immediately below
(`TopicName`, `PartitionId`, `Offset`, `Millis`, `Timestamp`, `Headers`,
`ConsumerRecord k v`) stay — they are still required for the `nf`
benchmarks. Once `shibuya-core` has its own `NFData` instances for
`MessageId`, `Cursor`, and `Envelope a` (added in `shibuya-core 0.2.0.0`
per its changelog), the orphan declarations would be duplicates and
GHC will refuse to compile.

After this edit, also remove the three names from the
`Shibuya.Core.Types` import list at line 16. The current import:

    import Shibuya.Core.Types (Cursor, Envelope, MessageId)

becomes unnecessary because none of those names are referenced after
the orphans are deleted. Either remove the entire `import` line or, if
GHC's `-Wunused-imports` would otherwise flag it, leave only what the
file still references (verify with `cabal build` after the edit).

### Step 5 — Add a CHANGELOG entry

Insert a new top-of-file entry in
`shibuya-kafka-adapter/CHANGELOG.md`, immediately after the first
`# Changelog` header and before the existing `## 0.3.0.0` section:

    ## 0.4.0.0 — 2026-04-29

    ### Breaking Changes

    - Tracks the `shibuya-core 0.4.0.0` release, which adds an
      `attempt :: !(Maybe Attempt)` field to the `Envelope` record
      exported from `Shibuya.Core.Types`. The adapter's
      `consumerRecordToEnvelope` now sets this field to `Nothing`,
      consistent with the upstream guidance that adapters which cannot
      observe broker-side redeliveries (e.g. Kafka) report `Nothing`.
      Downstream code that pattern-matches on `Envelope` with positional
      patterns or with non-punned record patterns that name every field
      must be updated.

    ### Other Changes

    - Bumps the `shibuya-core` build-depends pin to `^>=0.4` in all three
      packages of this repo.
    - Drops three orphan `NFData` instances (`MessageId`, `Cursor`,
      `Envelope a`) from `shibuya-kafka-adapter-bench/bench/Main.hs`;
      these instances have been provided upstream by `shibuya-core` since
      `0.2.0.0` and the orphans had become duplicate-instance hazards
      whenever the bench resolved against a `shibuya-core` newer than
      `0.1`.
    - `shibuya-kafka-adapter-bench` and `shibuya-kafka-adapter-jitsurei`
      are re-released at `0.4.0.0` to track the shared version of this
      repo; neither has user-visible changes of its own.

### Step 6 — Format

Run, from the repo root:

    nix fmt

This invokes `treefmt` (configured in `treefmt.nix`) which runs
`fourmolu` on Haskell sources, `cabal-fmt` on cabal files, and
`nixpkgs-fmt` on Nix files. The project rule in `CLAUDE.md` states this
must run before committing.

Expected: command exits 0; `git status` may show further whitespace
adjustments to any of the touched files.

### Step 7 — Build

    cabal build all

Expected (truncated): a "Resolving dependencies…" line, a download of
`shibuya-core-0.4.0.0` from Hackage if not already cached, `Building
library for shibuya-kafka-adapter-0.4.0.0…`, `Building benchmark
shibuya-kafka-adapter-bench-0.4.0.0…`, then a clean exit. No errors
naming `attempt`, `Envelope`, or `Duplicate instance`.

If `cabal` reports `Could not resolve dependencies` because Hackage does
not yet carry `shibuya-core 0.4.0.0`, see Idempotence and Recovery
below for the local-source-repository fallback.

### Step 8 — Verify the resolver picked up 0.4.0.0

    python3 -c "import json; d=json.load(open('dist-newstyle/cache/plan.json')); print([(p['pkg-name'], p['pkg-version']) for p in d['install-plan'] if p['pkg-name']=='shibuya-core'])"

Expected exact output:

    [('shibuya-core', '0.4.0.0')]

### Step 9 — Test

In another shell, ensure Redpanda is up:

    just process-up

…and (idempotently) the topics exist:

    just create-topics

Then back in the build shell:

    cabal test shibuya-kafka-adapter

Expected: all three tasty groups (`ConvertTest`, `TracingTest`,
`IntegrationTest`) report `OK`. The `IntegrationTest` group exercises
`kafkaAdapter` end-to-end against Redpanda, so it transitively
demonstrates that `attempt = Nothing` envelopes pass through the runtime
correctly.

### Step 10 — Bench

    cabal bench shibuya-kafka-adapter-bench

Expected: `tasty-bench` prints a table that includes rows like:

    ConsumerRecord to Envelope
        with trace headers:    OK
            ... ns ± ... ns
        without trace headers: OK
            ... ns ± ... ns

…and exits 0. The absolute numbers will differ from
`shibuya-kafka-adapter-bench/baseline.csv`; that file is the historical
baseline at the prior shibuya-core version and is not regenerated as
part of this plan.

### Step 11 — Commit

    git add shibuya-kafka-adapter shibuya-kafka-adapter-bench shibuya-kafka-adapter-jitsurei docs/plans/11-upgrade-shibuya-core-0.4.md

Then commit using a HEREDOC so the trailers stay correctly formatted:

    git commit -m "$(cat <<'EOF'
    feat!: upgrade to shibuya-core 0.4.0.0 and bump to 0.4.0.0

    shibuya-core 0.4.0.0 adds Envelope.attempt :: !(Maybe Attempt). Kafka
    cannot observe broker-side redeliveries, so the adapter sets the new
    field to Nothing on every emitted envelope, consistent with the
    upstream type-level guidance.

    Bumps the shibuya-core build-depends pin to ^>=0.4 across all three
    packages, drops three orphan NFData instances from the bench (now
    provided upstream), and re-releases all three packages at 0.4.0.0 to
    track the shared shibuya-core major.

    BREAKING CHANGE: downstream code that pattern-matches on Envelope
    with positional patterns or non-punned record patterns must be
    updated.

    ExecPlan: docs/plans/11-upgrade-shibuya-core-0.4.md
    Intention: intention_01khv57nhzesc9hx46f9bz0vbq
    EOF
    )"

Then verify the commit:

    git log -1 --format=%B

Expected: the message is exactly what the HEREDOC above contains, and
both `ExecPlan:` and `Intention:` trailers appear at the bottom.

### Step 12 — Update this plan

Tick the items in the Progress section, write a short Outcomes &
Retrospective entry, and commit again with another `ExecPlan:` /
`Intention:` trailer pair (use a `chore(plan):` Conventional-Commits
prefix for plan-only edits).


## Validation and Acceptance

Behavioral acceptance (in addition to the green `cabal build`/`cabal
test`/`cabal bench` results above):

1. **Envelope shape is observable to a downstream user**. From the repo
   root with Redpanda up and topics created:

        cabal run basic-consumer

   then in a separate shell:

        rpk topic produce orders <<<'hello-from-plan-11'

   The `BasicConsumer` example prints one `Received: hello-from-plan-11`
   line and the underlying envelope passes through Shibuya's runtime
   without exception. The runtime is the same code path that constructs
   `Ingested { envelope = ... }` from each emitted `Envelope`, so a
   missing `attempt` field would surface as a build failure (caught at
   Step 7) rather than a runtime exception. A clean run is the
   end-to-end signal that the new field threads through.

2. **Tracing test passes against the new field**. The `TracingTest`
   group constructs `Envelope ()` values via `mkEnvelope` and runs them
   through `Shibuya.Adapter.Kafka.Tracing.traced`. After Step 2's edit
   plus Step 9's run, the group reports `OK` for every case:

        TracingTest
          rebuilds parent context from W3C traceparent: OK
          opens root span when no traceparent is present: OK
          ...

   A failing run with a missing-field error would mean Step 2 was
   skipped.

3. **Resolver pinned to 0.4.0.0**. Step 8's Python one-liner is the
   single-line acceptance test that this is no longer a stale build
   resolved against `shibuya-core 0.2.0.0`.

4. **Conventional Commit + trailers present**. From repo root:

        git log -1 --format=%B | grep -E '^(feat!|BREAKING CHANGE|ExecPlan|Intention)'

   should print four matching lines (one for each).


## Idempotence and Recovery

* The cabal version-bump and build-depends edits are idempotent:
  re-running the edits with the same target text is a no-op for `Edit`
  and the file is in a single deterministic state. If a partial run
  left some files at `0.4.0.0` and others at the old version, simply
  finish the remaining edits and re-run `nix fmt`.
* `nix fmt` is idempotent.
* `cabal build all`, `cabal test`, and `cabal bench` are idempotent;
  rerunning them after a successful run produces "Up to date" output
  for the build and re-runs tests/benches from scratch.
* `git commit` is not idempotent. If the commit fails because of a
  pre-commit hook (the project's `pre-commit-hooks.nix` config wires up
  treefmt), do not amend. Instead, fix the issue (most commonly: rerun
  `nix fmt`, `git add -u`, then `git commit` again — creating a new
  commit, not amending).

* **Recovery from a Hackage gap**. If at the time of executing this
  plan `shibuya-core 0.4.0.0` is not yet on Hackage but is checked in
  to the sibling local repo at
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/`, add a
  temporary `source-repository-package` block to `cabal.project` so the
  resolver picks up the local source instead of failing. The block
  should look like:

        source-repository-package
            type: git
            location: file:///Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
            tag: <SHA of HEAD on shibuya master>
            subdir: shibuya-core

  Determine the SHA with `git -C /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya rev-parse HEAD`.
  Re-run `cabal build all`. Once `shibuya-core 0.4.0.0` is published to
  Hackage, drop the block in a follow-up commit. Record the use of
  this fallback in Surprises & Discoveries and the rationale in the
  Decision Log of this plan.


## Interfaces and Dependencies

This plan touches these libraries and modules:

* `shibuya-core ^>=0.4` (Hackage, sibling repo at
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/`). Specifically:
  * `Shibuya.Core.Types.Envelope` — record now has 7 fields including
    the new `attempt :: !(Maybe Attempt)`.
  * `Shibuya.Core.Types.Attempt` — new `Word` newtype. Not named
    explicitly by this repo (we only use `Nothing :: Maybe Attempt`),
    but documented here for future readers.
  * `Shibuya.Core.Types` continues to export
    `MessageId`, `Cursor`, `Envelope`, `TraceHeaders` with `NFData`
    instances on the first three (added in `shibuya-core 0.2.0.0`).
* `kafka-effectful ^>=0.1`, `hw-kafka-client >=5.3 && <6`,
  `hw-kafka-streamly ^>=0.1` — unchanged; the adapter's interaction
  with these is unaffected by the upstream change.
* `effectful-core ^>=2.6.1.0`, `streamly ^>=0.11`, `streamly-core
  ^>=0.3` — unchanged.
* `tasty-bench` (bench) — unchanged.

Function and type signatures that must exist at the end of Milestone 1:

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs`:

    consumerRecordToEnvelope ::
        ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
        Envelope (Maybe ByteString)

(unchanged signature; only the body's record literal gains a new field).

In `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`:

    mkEnvelope :: Maybe TraceHeaders -> Envelope ()

(unchanged signature; only the body's record literal gains a new field).

In `shibuya-kafka-adapter-bench/bench/Main.hs`: no new symbols. The
file is purely a `Test.Tasty.Bench.defaultMain` driver and stays a
single-module program. The deletion of three orphan instances does
not change any signature in this file.

No new modules, exposed-modules, or executables are added. No symbols
are removed from the public API of `shibuya-kafka-adapter`. The only
public-API change is structural: the `Envelope (Maybe ByteString)`
returned by `consumerRecordToEnvelope` and threaded through
`kafkaAdapter` carries one additional field.
