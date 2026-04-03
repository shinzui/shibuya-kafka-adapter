# Add benchmark package with tasty-bench

Intention: intention_01khv57nhzesc9hx46f9bz0vbq

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this work, a developer can run `cabal bench` from the repository root and get
reproducible, low-noise CPU time measurements for the pure conversion functions in the
shibuya-kafka-adapter library. The benchmarks cover the hot path of message ingestion:
converting a Kafka `ConsumerRecord` into a Shibuya `Envelope`, extracting W3C trace
headers, converting timestamps, and constructing message IDs. This gives the team a
quantitative baseline to detect performance regressions and evaluate optimizations to
the adapter's per-message overhead.

The benchmark output looks like this (times will vary):

    All
      ConsumerRecord to Envelope
        consumerRecordToEnvelope/with trace headers:  OK (0.12s)
          230 ns +- 11 ns
        consumerRecordToEnvelope/without trace headers: OK (0.09s)
          185 ns +- 9  ns
      Trace header extraction
        extractTraceHeaders/with both headers:        OK (0.07s)
          68  ns +- 3  ns
        ...

    All 7 tests passed (0.84s)


## Progress

- [x] Create `shibuya-kafka-adapter-bench/` directory at the repository root. (2026-04-03)
- [x] Create `shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal`. (2026-04-03)
- [x] Create `shibuya-kafka-adapter-bench/bench/Main.hs` with benchmark suite. (2026-04-03)
- [x] Add `shibuya-kafka-adapter-bench` to `cabal.project` packages list. (2026-04-03)
- [x] Add tasty-bench local path to `cabal.project` local dependencies. (2026-04-03)
- [x] Verify `cabal build shibuya-kafka-adapter-bench` compiles. (2026-04-03)
- [x] Run `cabal bench shibuya-kafka-adapter-bench` and capture output. (2026-04-03)
- [x] Verify benchmark results are stable (relative standard deviation under 5%). (2026-04-03)


## Surprises & Discoveries

- The `Headers` data constructor is not exported from `Kafka.Types` in hw-kafka-client.
  The public API provides `headersFromList` as the smart constructor instead. The plan
  originally assumed direct constructor access; switched to `headersFromList` during
  implementation. The `NFData` orphan instance for `Headers` still works because
  `DeriveAnyClass` uses the `Generic` instance which doesn't require the constructor
  to be in scope.

- The `GHC.Generics (Generic)` import was unused because `GHC2024` includes
  `DerivingStrategies` and the types already derive `Generic` in their home modules.
  The standalone `deriving anyclass instance` declarations work without re-importing
  `Generic`.


## Decision Log

- Decision: Create a separate package (`shibuya-kafka-adapter-bench`) rather than adding a
  `benchmark` stanza to the existing `shibuya-kafka-adapter.cabal`.
  Rationale: This follows the project's established pattern of separate packages for
  different concerns (`shibuya-kafka-adapter` for library, `shibuya-kafka-adapter-jitsurei`
  for examples). A separate package keeps the library's cabal file focused and avoids
  pulling benchmark dependencies into the library's dependency closure.
  Date: 2026-04-03

- Decision: Benchmark only the pure conversion functions (`consumerRecordToEnvelope`,
  `extractTraceHeaders`, `timestampToUTCTime`, `mkMessageId`), not the effectful functions
  (`kafkaSource`, `mkAckHandle`, `kafkaAdapter`).
  Rationale: The effectful functions require a running `KafkaConsumer` effect and a broker.
  The pure conversion functions are the per-message hot path that the adapter runs for every
  single record, making them the natural target for micro-benchmarks. IO-based benchmarks
  against a real broker would belong in a separate integration benchmark suite.
  Date: 2026-04-03

- Decision: Use `nf` (normal form) for all benchmarks.
  Rationale: All conversion functions produce strict types (`Envelope`, `MessageId`,
  `Maybe UTCTime`, `Maybe TraceHeaders`). Using `nf` ensures the full result is evaluated,
  giving accurate measurements. Using `whnf` would only evaluate to the outermost
  constructor, hiding the cost of computing nested fields.
  Date: 2026-04-03


## Outcomes & Retrospective

All 7 benchmarks compile and run successfully. Baseline results on Apple Silicon (aarch64-osx,
GHC 9.12.2, -O1):

    ConsumerRecord to Envelope / with trace headers:    534 ns +- 19 ns
    ConsumerRecord to Envelope / without trace headers: 508 ns +- 22 ns
    Trace header extraction / both headers:             44.4 ns +- 3.0 ns
    Trace header extraction / traceparent only:         28.3 ns +- 2.4 ns
    Trace header extraction / no trace headers:         8.94 ns +- 502 ps
    Timestamp conversion / CreateTime:                  398 ns +- 37 ns
    Timestamp conversion / NoTimestamp:                  2.24 ns +- 210 ps

The envelope conversion (~500 ns) is dominated by timestamp conversion (~400 ns of the
~500 ns total), specifically the `posixSecondsToUTCTime` call. Trace header extraction
is very cheap (~44 ns for two headers). The NoTimestamp path short-circuits to ~2 ns.

The plan was implemented as designed with two minor adjustments: using `headersFromList`
instead of the `Headers` constructor (not publicly exported), and removing an unused
`GHC.Generics` import.


## Context and Orientation

The repository is a Haskell multi-package project built with Cabal. The root
`cabal.project` file (at the repository root) lists each package directory and local
dependency paths. There are currently two packages:

The main library at `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal` exposes three
public modules and one internal module. The module `Shibuya.Adapter.Kafka.Convert`
contains the pure conversion functions that this benchmark targets. It exports three
public functions: `consumerRecordToEnvelope`, `extractTraceHeaders`, and
`timestampToUTCTime`. There is also an internal helper `mkMessageId` used by
`consumerRecordToEnvelope`.

The examples package at `shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`
contains four executable stanzas, each with its own `Main` in the `app/` source directory.

The project uses GHC 9.12 (`GHC2024` language, `base ^>=4.21.0.0`) and Nix flakes for
the development shell.

tasty-bench is a featherlight benchmark framework that integrates with the tasty test
framework. Its source is available locally at
`/Users/shinzui/Keikaku/hub/haskell/tasty-bench-project/tasty-bench`. Key API:

- `defaultMain :: [Benchmark] -> IO ()` runs benchmarks and reports CPU times.
- `bench :: String -> Benchmarkable -> Benchmark` names a single benchmark.
- `bgroup :: String -> [Benchmark] -> Benchmark` groups benchmarks under a heading.
- `nf :: NFData b => (a -> b) -> a -> Benchmarkable` measures full evaluation of a pure
  function applied to an argument.

The `NFData` constraint requires importing `Control.DeepSeq` and having `NFData` instances
for the result types. The shibuya-core types (`Envelope`, `MessageId`, `Cursor`) derive
`Generic` and will need standalone `NFData` instances or explicit `rnf` definitions in
the benchmark module.

The hw-kafka-client types (`ConsumerRecord`, `TopicName`, `PartitionId`, `Offset`,
`Timestamp`, `Millis`, `Headers`) are used to construct benchmark input data. A
`ConsumerRecord` is constructed with fields: `crTopic`, `crPartition`, `crOffset`,
`crTimestamp`, `crKey`, `crValue`, `crHeaders`.


## Plan of Work

The work has a single milestone: creating the benchmark package, wiring it into the
build, and running it.


### Milestone 1: Create benchmark package and run benchmarks

At the end of this milestone, running `cabal bench shibuya-kafka-adapter-bench` from the
repository root produces a benchmark report for the four conversion functions. The
benchmark compiles, runs, and reports stable times.


#### Step 1: Create the cabal file

Create the file `shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal`. It
defines a single `benchmark` component (type `exitcode-stdio-1.0`) with `bench/Main.hs`
as the entry point. The key dependencies are `base`, `tasty-bench`,
`shibuya-kafka-adapter`, `shibuya-core`, `hw-kafka-client`, `bytestring`, `deepseq`,
and `time`.

The cabal file must use `cabal-version: 3.12` and `default-language: GHC2024` to match
the existing packages. The `ghc-options` should include `-with-rtsopts=-A32m` to set the
GC nursery size and reduce allocation noise. Do NOT include `-threaded` as this interferes
with tasty-bench's measurement. Include `-fproc-alignment=64` for stable baseline
comparisons.

The `default-extensions` should match the existing packages so that the benchmark code
can use `OverloadedStrings` and other extensions without per-file pragmas.


#### Step 2: Create the benchmark module

Create the file `shibuya-kafka-adapter-bench/bench/Main.hs`. This module:

1. Imports `Test.Tasty.Bench` (`defaultMain`, `bench`, `bgroup`, `nf`).
2. Imports the functions under test from `Shibuya.Adapter.Kafka.Convert`.
3. Imports the Kafka types needed to construct sample `ConsumerRecord` values.
4. Defines `NFData` instances for the shibuya-core types that lack them. The types
   `MessageId`, `Cursor`, and `Envelope` derive `Generic` in shibuya-core but do not
   have `NFData` instances. The benchmark module defines orphan instances using
   `DeriveAnyClass` and `StandaloneDeriving`:

       deriving anyclass instance NFData MessageId
       deriving anyclass instance NFData Cursor
       deriving anyclass instance NFData a => NFData (Envelope a)

5. Defines sample data: a `ConsumerRecord` with trace headers and one without, plus an
   isolated `Headers` value for the trace-header extraction benchmarks.
6. Defines the benchmark tree with `defaultMain`:

   - Group "ConsumerRecord to Envelope" with two benchmarks: one with trace headers
     present and one without.
   - Group "Trace header extraction" with three benchmarks: both headers present,
     traceparent only, and no trace headers.
   - Group "Timestamp conversion" with two benchmarks: `CreateTime` and `NoTimestamp`.


#### Step 3: Wire into cabal.project

Add `shibuya-kafka-adapter-bench` to the first `packages:` stanza in `cabal.project`,
alongside the existing two packages.


#### Step 4: Build and run

Build the benchmark with `cabal build shibuya-kafka-adapter-bench`. Then run it with
`cabal bench shibuya-kafka-adapter-bench`. Verify the output shows timing results for
all benchmark groups.


## Concrete Steps

All commands are run from the repository root:
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`.


#### Create directory

    mkdir -p shibuya-kafka-adapter-bench/bench

#### Create cabal file

Write the file `shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal` with the
content described in Step 1 of the Plan of Work.


#### Create benchmark module

Write the file `shibuya-kafka-adapter-bench/bench/Main.hs` with the content described
in Step 2 of the Plan of Work.


#### Update cabal.project

In `cabal.project`, change the first `packages:` stanza from:

    packages:
      shibuya-kafka-adapter
      shibuya-kafka-adapter-jitsurei

to:

    packages:
      shibuya-kafka-adapter
      shibuya-kafka-adapter-jitsurei
      shibuya-kafka-adapter-bench


#### Build

    cabal build shibuya-kafka-adapter-bench

Expected: compilation succeeds with no errors.


#### Run benchmarks

    cabal bench shibuya-kafka-adapter-bench

Expected output (times will vary):

    All
      ConsumerRecord to Envelope
        with trace headers:       OK (...)
          ... ns +- ... ns
        without trace headers:    OK (...)
          ... ns +- ... ns
      Trace header extraction
        both headers:             OK (...)
          ... ns +- ... ns
        traceparent only:         OK (...)
          ... ns +- ... ns
        no trace headers:         OK (...)
          ... ns +- ... ns
      Timestamp conversion
        CreateTime:               OK (...)
          ... ns +- ... ns
        NoTimestamp:               OK (...)
          ... ns +- ... ns

    All 7 tests passed (...)


## Validation and Acceptance

Success is verified by running:

    cabal bench shibuya-kafka-adapter-bench

The benchmarks must:

1. Compile without errors or warnings (aside from orphan instance warnings, which are
   expected and can be suppressed with `-Wno-orphans`).
2. Run to completion, reporting "All 7 tests passed" (the benchmark count may differ
   if benchmarks are added or removed during implementation).
3. Report times with relative standard deviation under 5% for each benchmark (this is
   tasty-bench's default target; if a benchmark consistently exceeds 5%, investigate
   whether the input data is too small or whether GC is interfering).

To generate a CSV baseline for future regression detection:

    cabal bench shibuya-kafka-adapter-bench --benchmark-options '--csv baseline.csv'

To compare against a saved baseline:

    cabal bench shibuya-kafka-adapter-bench --benchmark-options '--baseline baseline.csv'


## Idempotence and Recovery

All steps are safe to repeat. Creating directories with `mkdir -p` is idempotent.
Overwriting the cabal file or benchmark source is safe. The `cabal.project` edit is
additive. Building and running benchmarks has no side effects beyond the
`dist-newstyle/` build cache.

If the build fails partway through, fix the error and re-run `cabal build
shibuya-kafka-adapter-bench`. Cabal's incremental compilation avoids redundant work.


## Interfaces and Dependencies

The benchmark package depends on:

- `base ^>=4.21.0.0` (GHC 9.12 boot library)
- `tasty-bench` (benchmark framework; available locally at
  `/Users/shinzui/Keikaku/hub/haskell/tasty-bench-project/tasty-bench`)
- `shibuya-kafka-adapter` (the library under test)
- `shibuya-core ^>=0.1.0.0` (for types used in `NFData` instances)
- `hw-kafka-client >=5.3 && <6` (for `ConsumerRecord` and related types)
- `bytestring ^>=0.12` (for constructing test data)
- `deepseq` (for `NFData` class and `rnf`)
- `time ^>=1.14` (not directly needed but may be useful for timestamp benchmarks)

The `tasty-bench` library is not on Hackage in the project's current dependency set. It
must be added as a local package path or source-repository-package in `cabal.project`.
Check whether it is already resolvable; if not, add the local path
`/Users/shinzui/Keikaku/hub/haskell/tasty-bench-project/tasty-bench` to the
`cabal.project` packages stanza or as an `optional-packages` entry.

The benchmark module `bench/Main.hs` must define or import the following:

In `shibuya-kafka-adapter-bench/bench/Main.hs`:

    main :: IO ()

    -- Sample data constructors
    sampleRecordWithHeaders :: ConsumerRecord (Maybe ByteString) (Maybe ByteString)
    sampleRecordNoHeaders :: ConsumerRecord (Maybe ByteString) (Maybe ByteString)
    sampleHeaders :: Headers
    sampleHeadersNoTrace :: Headers

    -- Orphan NFData instances (needed for nf to evaluate results fully)
    instance NFData MessageId
    instance NFData Cursor
    instance NFData (Envelope a)  -- with NFData a constraint
