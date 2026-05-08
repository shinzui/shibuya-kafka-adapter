# Upgrade to hw-kafka-streamly 0.2.0.0

Intention: intention_01khv57nhzesc9hx46f9bz0vbq

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

The Kafka adapter currently depends on `hw-kafka-streamly ^>=0.1` (resolved on Hackage as
`hw-kafka-streamly-0.1.0.0`). The upstream library has shipped a breaking-rename release,
`hw-kafka-streamly-0.2.0.0`, that renames its consumer/producer modules from the
conduit-flavoured `Source`/`Sink` vocabulary to the Streamly-native `Stream`/`Fold`
vocabulary. The library function the adapter actually consumes (`skipNonFatal`) keeps the
same signature; only the module path moves. `0.2.0.0` is already published on Hackage and
provides no backwards-compatible re-exports — callers are expected to mechanically
substitute identifiers per the upstream changelog.

After this change, anyone running `cabal build all` from a fresh clone will resolve
`hw-kafka-streamly-0.2.0.0` from Hackage, the adapter library and benchmark package will
build clean, all 21 existing tests will pass, and the benchmark suite will run end to end.
The adapter's user-visible behaviour does not change: `skipNonFatal` continues to filter
non-fatal poll errors out of the consumer stream, and the adapter still exposes
`kafkaAdapter` returning an `Adapter es (Maybe ByteString)`. The user benefit is purely
that the adapter stays current with the upstream library so future improvements (new
combinators, bug fixes, GHC support) can be picked up by another version-constraint bump
rather than being blocked behind a rename migration.

To see it working: a successful `nix fmt && cabal build all && cabal test
shibuya-kafka-adapter && cabal bench shibuya-kafka-adapter-bench` after the change, with
no compilation errors referencing `Kafka.Streamly.Source`, demonstrates the upgrade.


## Progress

- [x] Update cabal version constraints to `hw-kafka-streamly ^>=0.2` in the two
  packages that depend on it. (2026-05-08)
- [x] Rename the import in `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`
  from `Kafka.Streamly.Source` to `Kafka.Streamly.Stream`. (2026-05-08)
- [x] Rename the import in `shibuya-kafka-adapter-bench/bench/Main.hs` from
  `Kafka.Streamly.Source` to `Kafka.Streamly.Stream`. (2026-05-08)
- [x] Update Haddock cross-references (`'Kafka.Streamly.Source.…'` → `'Kafka.Streamly.Stream.…'`)
  in `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` and
  `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`. (2026-05-08)
- [x] Update README cross-reference at
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/README.md`. (2026-05-08)
- [x] Run `nix fmt` from the repo root — no files changed. (2026-05-08)
- [x] Run `cabal build all` and confirm clean build (after `cabal update` to
  refresh the local Hackage index — see Surprises & Discoveries). (2026-05-08)
- [x] Run `cabal test shibuya-kafka-adapter` against a running Redpanda — all 26
  tests pass. (Plan said 21; the suite has grown since plan 3.) (2026-05-08)
- [x] Run `cabal bench shibuya-kafka-adapter-bench` — all 15 benchmarks complete,
  numbers track the plan-3 baseline. (2026-05-08)
- [x] Add a CHANGELOG entry to
  `shibuya-kafka-adapter/CHANGELOG.md` describing the dependency upgrade. (2026-05-08)
- [x] Commit with a Conventional Commits message and the
  `ExecPlan: docs/plans/13-upgrade-to-hw-kafka-streamly-0.2.md` git trailer
  (commit `5f3e92c`). (2026-05-08)


## Surprises & Discoveries

- The first `cabal build all` failed with a solver `[Cabal-7107]` error rejecting
  `hw-kafka-streamly-0.1.0.0` for `^>=0.2` even though `0.2.0.0` is on Hackage.
  The local Hackage index was stale (`index-state` older than the `0.2.0.0`
  upload). `cabal update` refreshed it to `2026-05-08T07:32:31Z` and the build
  resolved cleanly on the next attempt. Worth keeping in mind on shared CI
  runners that may pin or cache the index.

- The library test suite is now **26 tests**, not the 21 captured in plan 3. The
  growth came from milestone work in plans 9 (`shibuya-kafka-adapter-tracing`),
  10 (OTel semconv alignment), and 12 (shibuya-core 0.5 migration), which added
  Convert-side assertions on the typed Kafka attributes (`messaging.system`,
  `messaging.kafka.destination.partition`, `messaging.kafka.message.offset`).
  This is not a regression; it just means the acceptance number in this plan was
  inherited from a stale source.

- Benchmark numbers at HEAD (`hw-kafka-streamly-0.2.0.0`):

      Stream pipeline / isFatal classification
        fatal (SSL):                3.23 ns
        non-fatal (timeout):        3.43 ns
        non-fatal (partition EOF):  3.45 ns
      Stream pipeline / skipNonFatal
        10k (95% Right):           37.7 μs
        10k baseline (no filter):  26.2 μs    → ~1.15 ns / element
      Stream pipeline / mapMaybeM
        10k (new path):            37.7 μs
        10k (old path):            25.7 μs    → ~1.20 ns / element
      Stream drain baseline (10k Int):  25.9 μs

  These match plan 3's recorded values within stdev (skipNonFatal +1.22 ns then,
  +1.15 ns now; mapMaybeM +1.20 ns then, +1.20 ns now). The module rename had
  no measurable performance effect, as expected.


## Decision Log

- Decision: Treat the upgrade as a single milestone.
  Rationale: All consumer-side call sites only use `skipNonFatal` and `isFatal`; both keep
  identical signatures in 0.2.0.0 and live in the renamed `Kafka.Streamly.Stream` module.
  The adapter does not depend on any of the producer-side identifiers
  (`kafkaSink`/`kafkaBatchSink`/`withKafkaProducer`) that were renamed to `kafkaFold` /
  `kafkaBatchFold` / module `Kafka.Streamly.Fold`. Splitting this into multiple milestones
  would manufacture ceremony around a five-import-line change that is fully verified by
  the existing test and benchmark suites.
  Date: 2026-05-08

- Decision: Do not rename the adapter's internal `kafkaSource` function in
  `Shibuya.Adapter.Kafka.Internal`.
  Rationale: The upstream rename `kafkaSource → kafkaStream` only applies to the upstream
  library's *managed-consumer* constructor — a function the adapter has never used
  (Plan 3, Decision Log entry from 2026-04-09 explicitly chose Option 1, "use only
  combinators", precisely because the upstream source constructors are incompatible with
  kafka-effectful's lifecycle). The adapter's own `kafkaSource` is an internal helper that
  builds a `Stream (Eff es) (Either KafkaError ConsumerRecord)` from
  `pollMessageBatch`; the name happens to collide but the symbol is local and the rename
  does not propagate. Renaming the local function would be a gratuitous churn-only change.
  Date: 2026-05-08

- Decision: Bump the adapter's own version to `0.5.0.1`.
  Rationale: The change touches a Haddock cross-reference (`Kafka.Streamly.Source.…` →
  `Kafka.Streamly.Stream.…`) that is rendered into the published documentation, and the
  rebuildable build-depends constraint changes. No public type or function signature
  changes. Under PVP this is a patch-level bump. If the user prefers `0.5.1.0` to flag
  the documentation refresh more visibly, that is also acceptable; this plan picks
  `0.5.0.1` as the minimal, mechanically-justified bump.
  Date: 2026-05-08

- Decision: Do not vendor `hw-kafka-streamly` from
  `/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly/` into `cabal.project` while making
  this change.
  Rationale: Version `0.2.0.0` is already published on Hackage (verified 2026-05-08 with
  `curl -s -o /dev/null -w "%{http_code}\n" https://hackage.haskell.org/package/hw-kafka-streamly-0.2.0.0/hw-kafka-streamly.cabal`
  returning `200`). Vendoring would defeat the purpose of the upgrade — if the Hackage
  release works, the cabal-only constraint bump is the correct change.
  Date: 2026-05-08


## Outcomes & Retrospective

The upgrade landed exactly as scoped. Five edits (two cabal version-constraint
bumps, two `.cabal` package-version bumps to `0.5.0.1`, three import/Haddock
renames in two `.hs` files, one Haddock prose tweak in the public-API module,
one README cross-reference update, one CHANGELOG entry) were enough to take the
adapter from `hw-kafka-streamly-0.1.0.0` to `hw-kafka-streamly-0.2.0.0`. The
formatter accepted the result on first run, the build was clean once the local
Hackage index was refreshed, all 26 tests passed against a running Redpanda
(IPv6 connection-refused noise on producer/consumer fallback is routine and
does not fail tests), and all 15 benchmarks completed with numbers within
stdev of the plan-3 baseline.

Two things worth recording for the next dependency-upgrade plan in this repo:

1. The plan claimed the test count was 21, citing plan 3. It is now 26. Future
   plans should not hard-code expected test counts — `cabal test` either passes
   or it doesn't, and the count drifts as test coverage grows. Future
   acceptance criteria should phrase this as "all tests pass" rather than "N
   tests pass".

2. The `cabal update` step was not in the original plan. On a developer machine
   where the local Hackage index has not been refreshed in a while, a
   constraint bump pointing at a recently-uploaded version will fail to
   resolve until `cabal update` runs. Adding "run `cabal update` first if the
   target version was uploaded recently" as a pre-build sanity check would
   save a minute on similar future plans.

The dependency upgrade is complete and the adapter is ready for any further
work that wants to consume new combinators from `hw-kafka-streamly-0.2.x`.


## Context and Orientation

This section explains the repository, the dependency, and the gap between them, with no
prior knowledge assumed. Anyone reading this plan should be able to make the change
without consulting earlier plans.

### The Kafka adapter

The repository at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/`
is `shibuya-kafka-adapter` — a Cabal-based Haskell library that adapts Apache Kafka into
the Shibuya queue-processing framework. "Shibuya" is the parent framework that defines the
`Adapter`, `Ingested`, `Envelope`, and `AckHandle` abstractions used here. The adapter
contains three Cabal packages, all at top-level subdirectories:

- `shibuya-kafka-adapter/` — the public library. Source under `src/Shibuya/Adapter/`.
- `shibuya-kafka-adapter-bench/` — `tasty-bench` micro-benchmarks of the conversion
  hot path and the streaming pipeline. Source under `bench/Main.hs`.
- `shibuya-kafka-adapter-jitsurei/` — runnable example programs ("jitsurei" is a Japanese
  loanword used here for "examples"). Source under `app/`. Does not depend on
  `hw-kafka-streamly`.

The library's relevant source files are:

- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` — the public-API module. Exports
  `kafkaAdapter`, `KafkaAdapterConfig`, `defaultConfig`, and a few re-exports from
  `hw-kafka-client`. Contains a Haddock cross-reference to
  `Kafka.Streamly.Source.isFatal` in its module-header documentation.
- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs` — internal stream
  construction. Imports `Kafka.Streamly.Source (skipNonFatal)`. Builds the consumer
  stream by `Stream.repeatM pollBatch & Stream.concatMap Stream.fromList` and applies
  `skipNonFatal` to drop non-fatal poll errors. Contains a Haddock cross-reference to
  `Kafka.Streamly.Source.skipNonFatal` in its `ingestedStream` docstring.
- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs` — pure conversion
  helpers (`consumerRecordToEnvelope`, `extractTraceHeaders`, `timestampToUTCTime`). No
  reference to `hw-kafka-streamly`.
- `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Config.hs` — `KafkaAdapterConfig`
  record. No reference to `hw-kafka-streamly`.

The benchmark package's relevant source file is:

- `shibuya-kafka-adapter-bench/bench/Main.hs` — imports
  `Kafka.Streamly.Source (isFatal, skipNonFatal)` to drive the "Stream pipeline"
  benchmark group (8 benchmarks: 3 `isFatal` classifications, 2 `skipNonFatal` filter
  measurements, 2 `mapMaybeM` extraction measurements, 1 stream drain baseline).

The README at the repo root,
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/README.md`,
documents the adapter. It mentions `Kafka.Streamly.Source.skipNonFatalExcept` in the
"Error handling" section as the upstream helper to use if a caller wants to keep
partition-EOF markers in their stream.

The two `.cabal` files that pin `hw-kafka-streamly` are:

- `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal` — line: `, hw-kafka-streamly                      ^>=0.1`.
- `shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal` — line: `, hw-kafka-streamly      ^>=0.1`.

The `cabal.project` file at the repo root contains no override or local-package entry for
`hw-kafka-streamly`, so the constraint resolves against Hackage.

### The hw-kafka-streamly library

`hw-kafka-streamly` is a separate Hackage package authored by the same maintainer
(Nadeem Bitar). Its source tree lives locally at
`/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly/` for development reference, but the
Kafka adapter consumes it through Hackage. The library provides a thin Streamly layer
over `hw-kafka-client`:

- Consumer-side: streams that yield `Either KafkaError (ConsumerRecord (Maybe ByteString)
  (Maybe ByteString))` from a Kafka consumer, plus error predicates (`isFatal`,
  `isPollTimeout`, `isPartitionEOF`), error filters (`skipNonFatal`,
  `skipNonFatalExcept`), and value-mapping helpers (`mapFirst`, `mapValue`,
  `bimapValue`).
- Producer-side: Streamly `Fold` values that consume `ProducerRecord` streams.
- Shared combinators: `batchByOrFlush`, `batchByOrFlushEither`, `throwLeft`,
  `throwLeftSatisfy`.

### What changed in 0.2.0.0

The upstream changelog at
`/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly/hw-kafka-streamly/CHANGELOG.md` describes
the 0.2.0.0 release as a single breaking change: the consumer-side and producer-side
modules were renamed from a conduit-flavoured vocabulary to Streamly's native vocabulary.
The full mapping (reproduced verbatim from the upstream CHANGELOG):

    | Old (0.1.0.0)                  | New (0.2.0.0)                |
    |--------------------------------|------------------------------|
    | `Kafka.Streamly.Source`        | `Kafka.Streamly.Stream`      |
    | `Kafka.Streamly.Sink`          | `Kafka.Streamly.Fold`        |
    | `kafkaSource`                  | `kafkaStream`                |
    | `kafkaSourceAutoClose`         | `kafkaStreamAutoClose`       |
    | `kafkaSourceNoClose`           | `kafkaStreamNoClose`         |
    | `kafkaSink`                    | `kafkaFold`                  |
    | `kafkaBatchSink`               | `kafkaBatchFold`             |

The upstream notes that **no backwards-compatible re-exports are provided**; callers
must rename mechanically.

The combinators module is unchanged (still `Kafka.Streamly.Combinators`). The function
the adapter uses, `skipNonFatal`, lives in the renamed module — in 0.1.0.0 at
`Kafka.Streamly.Source.skipNonFatal`, and in 0.2.0.0 at `Kafka.Streamly.Stream.skipNonFatal`
— with an unchanged signature `Monad m => Stream m (Either KafkaError b) -> Stream m
(Either KafkaError b)`. The error predicate `isFatal` (used in benchmarks) is likewise
exported from the renamed `Kafka.Streamly.Stream` module with an unchanged signature
`KafkaError -> Bool`. Both are listed in the export list of `Kafka.Streamly.Stream` in
the local 0.2.0.0 source under `-- * Error filters` and `-- * Error predicates`
respectively.

The dependency floor is unchanged: 0.2.0.0 still requires `streamly-core >=0.3 && <0.5`,
so the adapter's existing `streamly ^>=0.11` / `streamly-core ^>=0.3` constraints continue
to resolve without an `allow-newer` clause. Hackage release of 0.2.0.0 was verified on
2026-05-08 by fetching its `.cabal` file and observing HTTP 200.

### Why the rename does not change the adapter's public API

The adapter's public API is the export list of `Shibuya.Adapter.Kafka` plus
`Shibuya.Adapter.Kafka.Config`. Neither re-exports anything from `hw-kafka-streamly`.
The only public-facing surface the upgrade touches is the Haddock module-header text in
`Shibuya.Adapter.Kafka.hs` and the `ingestedStream` Haddock in
`Shibuya.Adapter.Kafka.Internal.hs`, both of which mention the upstream module path by
name. Updating those mentions is mechanical: replace the old module name with the new
one in the rendered prose.


## Plan of Work

This plan executes one milestone — the dependency upgrade — and validates it with the
existing test and benchmark suites. The work has eight concrete edits and four
verification commands.

### Milestone 1: bump the dependency, rename the imports, validate the build

At the end of this milestone, every reference to `Kafka.Streamly.Source` in the
repository has been replaced with `Kafka.Streamly.Stream`, both `.cabal` files pin
`hw-kafka-streamly ^>=0.2`, the formatter has run cleanly, every package builds, every
test passes against a running Redpanda, and every benchmark runs end to end. A
single commit captures the change with a Conventional Commits message and an
`ExecPlan:` git trailer.

Edits, in order, with full repository-relative paths:

1. **`shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`.**
   Find the `build-depends:` line `, hw-kafka-streamly                      ^>=0.1`
   inside the `library` stanza and change it to
   `, hw-kafka-streamly                      ^>=0.2`. Preserve the exact column-aligned
   spacing — `cabal-fmt` (run by `nix fmt`) reformats this stanza, so getting the
   indent perfect by hand is unnecessary, but do not introduce a trailing-comma or
   leading-comma change that would diff noisily.

2. **`shibuya-kafka-adapter/shibuya-kafka-adapter.cabal` — version field.**
   Change `version:         0.5.0.0` to `version:         0.5.0.1`.

3. **`shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal`.**
   Find the `build-depends:` line `, hw-kafka-streamly      ^>=0.1` and change it to
   `, hw-kafka-streamly      ^>=0.2`. Also bump the `version:` field from `0.5.0.0` to
   `0.5.0.1` so the bench package stays in lockstep with the library it benchmarks (this
   is the pattern used by every previous version bump in the repo — see the CHANGELOG
   entries on plans 11 and 12 of this directory).

4. **`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`.**
   At the import block (currently around line 28), change

       import Kafka.Streamly.Source (skipNonFatal)

   to

       import Kafka.Streamly.Stream (skipNonFatal)

   In the Haddock for `ingestedStream` (currently around line 100), change the prose
   `'Kafka.Streamly.Source.skipNonFatal' has already dropped non-fatal errors` to
   `'Kafka.Streamly.Stream.skipNonFatal' has already dropped non-fatal errors`.

5. **`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`.**
   In the module-header Haddock (currently around line 39), change the prose
   `non-fatal set defined by @hw-kafka-streamly@'s 'Kafka.Streamly.Source.isFatal'`
   to `non-fatal set defined by @hw-kafka-streamly@'s 'Kafka.Streamly.Stream.isFatal'`.

6. **`shibuya-kafka-adapter-bench/bench/Main.hs`.**
   At the import block (currently line 9), change

       import Kafka.Streamly.Source (isFatal, skipNonFatal)

   to

       import Kafka.Streamly.Stream (isFatal, skipNonFatal)

7. **`README.md` (repo root).**
   In the "Fatal Error Propagation" subsection, change the sentence
   `the upstream `Kafka.Streamly.Source.skipNonFatalExcept` helper takes a predicate
   list` to `the upstream `Kafka.Streamly.Stream.skipNonFatalExcept` helper takes a
   predicate list`. The other mention in the README — the link
   `[`hw-kafka-streamly`](https://hackage.haskell.org/package/hw-kafka-streamly)` —
   stays unchanged because the package name on Hackage has not changed.

8. **`shibuya-kafka-adapter/CHANGELOG.md`.**
   Insert a new top-level section immediately above the existing
   `## 0.5.0.0 — 2026-05-05` heading:

       ## 0.5.0.1 — 2026-05-08

       ### Changed

       - Upgraded `hw-kafka-streamly` dependency from `^>=0.1` to `^>=0.2`. The
         upstream 0.2.0.0 release renames `Kafka.Streamly.Source` to
         `Kafka.Streamly.Stream` and `Kafka.Streamly.Sink` to `Kafka.Streamly.Fold`
         to match Streamly's native vocabulary. The adapter only used `skipNonFatal`
         and `isFatal` from the renamed module, both of which keep identical
         signatures; this is a mechanical import rename with no API-shape change.
         Haddock cross-references in `Shibuya.Adapter.Kafka` and
         `Shibuya.Adapter.Kafka.Internal` are updated accordingly.

   Use today's date as printed by the `currentDate` line at the top of this conversation
   (2026-05-08). If the implementation date drifts, update the heading to match the
   actual day the commit lands.

After the edits, run `nix fmt` from the repository root. This invokes `treefmt` which
runs `fourmolu`, `cabal-fmt`, and `nixpkgs-fmt`. The expected outcome is "OK" with no
files reformatted, since the import-rename and constraint-bump are minimal. If
`cabal-fmt` reformats the build-depends list, accept the reformatted output.

Then run `cabal build all`. The expected outcome is a clean build of all three
packages. The first build will rebuild all transitive Haskell dependencies because the
constraint change rewinds the install plan; this can take several minutes on a fresh
store but is one-shot.

Then in another shell, run `just process-up` to start the local Redpanda stack via
`process-compose` (defined in `process-compose.yaml` at the repo root). With Redpanda
running, run `cabal test shibuya-kafka-adapter`. The expected outcome is **21 tests
passed (16 unit + 5 integration)**, matching the count recorded in plan 3, Progress
section, Milestone 2.

Then run `cabal bench shibuya-kafka-adapter-bench`. The expected outcome is **15
benchmarks completing without error** across four groups: `ConsumerRecord to Envelope`
(2), `Trace header extraction` (3), `Timestamp conversion` (2), and `Stream pipeline`
(8). Numerical results may vary modestly from the captured baseline at
`shibuya-kafka-adapter-bench/baseline.csv`; this plan does not require zero numerical
drift, only successful completion. If the user wants a baseline-comparison sanity
check, the optional command
`cabal bench shibuya-kafka-adapter-bench --benchmark-options '--baseline shibuya-kafka-adapter-bench/baseline.csv'`
will print regression flags relative to the recorded baseline.

Finally, commit. The Conventional Commits message format is:

    chore(deps): upgrade hw-kafka-streamly to 0.2

    Renames the upstream module imports from Kafka.Streamly.Source to
    Kafka.Streamly.Stream to match the 0.2.0.0 release of hw-kafka-streamly,
    which renames Source/Sink modules to Stream/Fold to align with Streamly's
    native vocabulary. The adapter only consumes skipNonFatal and isFatal,
    both of which keep identical signatures; the change is a mechanical
    rename of imports and Haddock cross-references plus a version-constraint
    bump in the two .cabal files that depend on hw-kafka-streamly. Bumps
    shibuya-kafka-adapter and shibuya-kafka-adapter-bench from 0.5.0.0 to
    0.5.0.1.

    ExecPlan: docs/plans/13-upgrade-to-hw-kafka-streamly-0.2.md
    Intention: intention_01khv57nhzesc9hx46f9bz0vbq


## Concrete Steps

All commands assume the repository root is the working directory:
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/`.

### Edit verification

After completing the eight edits above, verify nothing references the old module names:

    grep -rn "Kafka.Streamly.Source\|Kafka.Streamly.Sink\|kafkaSource\|kafkaSink\|kafkaSourceAutoClose\|kafkaSourceNoClose\|kafkaBatchSink" \
        shibuya-kafka-adapter shibuya-kafka-adapter-bench shibuya-kafka-adapter-jitsurei README.md \
        --include="*.hs" --include="*.cabal" --include="*.md"

The expected output is empty (no matches outside `docs/plans/` and `docs/masterplans/`,
which contain historical plan files and should not be touched). If
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs` still appears in the grep
output for `kafkaSource`, that match is the **adapter's own internal helper function**
of the same name — see the second entry in the Decision Log; do not rename it. The
specific lines `kafkaSource ::` and `kafkaSource config =` should remain.

### Format

    nix fmt

Expected output: the formatter reports no files changed, or reports a small reformat of
the two `.cabal` files' build-depends sections (this is `cabal-fmt`'s prerogative and is
acceptable). If `fourmolu` reformats the `.hs` files, inspect the diff — it should be
limited to whitespace around the renamed import line.

### Build

    cabal build all

Expected output (truncated):

    Resolving dependencies...
    Build profile: -w ghc-9.12.2 -O1
    ...
    Building library for shibuya-kafka-adapter-0.5.0.1...
    ...
    Building benchmark 'shibuya-kafka-adapter-bench' for shibuya-kafka-adapter-bench-0.5.0.1...
    ...

A successful build ends with no errors and exit code 0. If `cabal` reports
`hw-kafka-streamly-0.2.0.0` cannot be found, run `cabal update` first to refresh the
local Hackage index and retry.

### Test

In another shell, start Redpanda:

    just process-up

In the original shell, run the test suite:

    cabal test shibuya-kafka-adapter

Expected output:

    Running 1 test suites...
    Test suite shibuya-kafka-adapter-test: RUNNING...
    ...
    Test suite shibuya-kafka-adapter-test: PASS
    ...

The summary line should report 21 passing tests (16 unit + 5 integration). If integration
tests fail with broker-connection errors, confirm `just process-up` is still running and
that `rpk topic list` returns the topics created by `just create-topics`. The integration
tests need topics `orders`, `events`, `multi-partition-demo`, and `offset-mgmt-demo`;
recreate them with `just create-topics` if needed.

When testing is finished, stop Redpanda from the second shell with `just process-down`
or Ctrl-C in the `process-up` shell.

### Bench

    cabal bench shibuya-kafka-adapter-bench

Expected output (excerpt — exact numbers vary):

    Running 1 benchmarks...
    Benchmark shibuya-kafka-adapter-bench: RUNNING...
    All
      ConsumerRecord to Envelope
        with trace headers:    OK ... ns
        without trace headers: OK ... ns
      Trace header extraction
        both headers:          OK ... ns
        traceparent only:      OK ... ns
        no trace headers:      OK ... ns
      Timestamp conversion
        CreateTime:             OK ... ns
        NoTimestamp:            OK ... ns
      Stream pipeline
        isFatal classification
          fatal error (SSL):       OK ... ns
          non-fatal (timeout):     OK ... ns
          non-fatal (partition EOF): OK ... ns
        skipNonFatal
          10k elements (95% Right):           OK ... μs
          10k elements baseline (no filter):  OK ... μs
        mapMaybeM extraction
          10k elements (new path: mapMaybeM): OK ... μs
          10k elements (old path: mapM):      OK ... μs
        Stream drain baseline (10k Int):     OK ... μs
    All 15 benchmarks passed.
    Benchmark shibuya-kafka-adapter-bench: FINISH

15 benchmarks total, all passing.

### Commit

After every gate is green, commit:

    git add shibuya-kafka-adapter/shibuya-kafka-adapter.cabal \
            shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs \
            shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs \
            shibuya-kafka-adapter/CHANGELOG.md \
            shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal \
            shibuya-kafka-adapter-bench/bench/Main.hs \
            README.md \
            docs/plans/13-upgrade-to-hw-kafka-streamly-0.2.md
    git commit -m "$(cat <<'EOF'
    chore(deps): upgrade hw-kafka-streamly to 0.2

    Renames the upstream module imports from Kafka.Streamly.Source to
    Kafka.Streamly.Stream to match the 0.2.0.0 release of hw-kafka-streamly,
    which renames Source/Sink modules to Stream/Fold to align with Streamly's
    native vocabulary. The adapter only consumes skipNonFatal and isFatal,
    both of which keep identical signatures; the change is a mechanical
    rename of imports and Haddock cross-references plus a version-constraint
    bump in the two .cabal files that depend on hw-kafka-streamly. Bumps
    shibuya-kafka-adapter and shibuya-kafka-adapter-bench from 0.5.0.0 to
    0.5.0.1.

    ExecPlan: docs/plans/13-upgrade-to-hw-kafka-streamly-0.2.md
    Intention: intention_01khv57nhzesc9hx46f9bz0vbq
    EOF
    )"

Verify the commit:

    git log -1 --format=fuller


## Validation and Acceptance

The plan is accepted when every one of the following observable outcomes holds.

The grep `grep -rn "Kafka.Streamly.Source" shibuya-kafka-adapter shibuya-kafka-adapter-bench
shibuya-kafka-adapter-jitsurei README.md --include="*.hs" --include="*.cabal"
--include="*.md"` returns no matches. Historical plan files in `docs/plans/` and
`docs/masterplans/` are intentionally excluded from this scope; they are records of
prior work and remain accurate as historical text.

The command `cabal build all` succeeds with exit code 0 and the build log mentions
`Building library for shibuya-kafka-adapter-0.5.0.1` and
`Building benchmark 'shibuya-kafka-adapter-bench' for shibuya-kafka-adapter-bench-0.5.0.1`.

With Redpanda running via `just process-up` and the topics created via
`just create-topics`, `cabal test shibuya-kafka-adapter` reports 21 passing tests and
exits 0.

`cabal bench shibuya-kafka-adapter-bench` reports 15 passing benchmarks (4 groups: 2 + 3
+ 2 + 8) and exits 0.

The `git log -1` output shows a single commit whose body contains both the line
`ExecPlan: docs/plans/13-upgrade-to-hw-kafka-streamly-0.2.md` and the line
`Intention: intention_01khv57nhzesc9hx46f9bz0vbq`, and whose subject line follows the
Conventional Commits pattern (`chore(deps): upgrade hw-kafka-streamly to 0.2`).

Optionally — not required for acceptance — the command
`cabal bench shibuya-kafka-adapter-bench --benchmark-options '--baseline shibuya-kafka-adapter-bench/baseline.csv'`
shows no benchmark exceeding a 2× standard-deviation regression versus the baseline. If
any benchmark does exceed that threshold, document the result in Surprises &
Discoveries with the absolute numbers; this plan does not block on benchmark drift
because the change is a pure module rename with no functional or fusion-level
difference.


## Idempotence and Recovery

Every edit in this plan is idempotent at the file level: running the same `sed`-style
rename twice produces the same content. If the formatter or build fails partway through,
the working tree is restorable by `git checkout -- <path>` for any individual file or
by `git restore .` for the whole working tree (the latter discards all edits).

Cabal solver state is not modified by this plan. If `cabal build all` cannot find
`hw-kafka-streamly-0.2.0.0`, run `cabal update` to refresh the local Hackage index and
retry. If the solver chooses an undesired version of an unrelated dependency, inspect
`dist-newstyle/cache/plan.json` (or run `cabal build --dry-run` for a textual install
plan) before troubleshooting further.

If a test fails, do not bypass it. The 21-test count from plan 3 is the contract; a
regression here is a real problem that needs root-cause investigation, not a `--no-run`
skip.

If the commit is created with the wrong message or wrong file set, run
`git reset --soft HEAD~1` to keep the changes staged and try again.


## Interfaces and Dependencies

The change touches one external interface and one published package version.

The external interface is `Kafka.Streamly.Stream` from `hw-kafka-streamly-0.2.0.0`.
Specifically, the adapter and benchmark packages will rely on these signatures, which
are stable across the 0.1.0.0 → 0.2.0.0 rename:

    module Kafka.Streamly.Stream where

    skipNonFatal :: Monad m => Stream m (Either KafkaError b) -> Stream m (Either KafkaError b)
    isFatal      :: KafkaError -> Bool

The published package version constraint is `^>=0.2`, which under PVP allows any
`0.2.x.y.z` release but rejects `0.3.0.0` and onwards. This is the conservative choice
matching the previous `^>=0.1` style. If the upstream maintainer signals API stability
across major versions, the constraint can later be relaxed to `>=0.2 && <0.4` or
similar; this plan does not pre-emptively widen the bound.

The adapter's `streamly`, `streamly-core`, `hw-kafka-client`, `effectful-core`,
`shibuya-core`, and `kafka-effectful` constraints are unchanged. The full
`build-depends:` block of `shibuya-kafka-adapter.cabal` after the change should match
the current block exactly, with the single substitution `^>=0.1` → `^>=0.2` on the
`hw-kafka-streamly` line.

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`, the function
`kafkaSource` will retain the signature

    kafkaSource ::
        (KafkaConsumer :> es) =>
        KafkaAdapterConfig ->
        Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))

unchanged.

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`, the function `kafkaAdapter`
will retain the signature

    kafkaAdapter ::
        (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
        KafkaAdapterConfig ->
        Eff es (Adapter es (Maybe ByteString))

unchanged.
