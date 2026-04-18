# Add a Justfile, stricter warnings, and README polish

Intention: intention_01khv57nhzesc9hx46f9bz0vbq

MasterPlan: docs/masterplans/1-0.1.0.0-release-prep.md

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this work, a fresh contributor enters the repository, runs `direnv allow`
(which activates the Nix dev shell and puts `just`, `rpk`, `process-compose`,
and `cabal` on the PATH), and runs `just` to see a curated list of recipes for
bringing up the test broker, creating the topics used by the integration tests
and jitsurei examples, building, testing, benchmarking, and formatting. The
GHC warning set matches the one used across the sibling packages
(`kafka-effectful`, `hw-kafka-streamly`), so a warning that surfaces in one
repository surfaces in the others. The README explains a non-obvious caveat
about `skipNonFatal` that a user could otherwise stumble on, and the
project-level manifest (`mori.dhall`) no longer lists a dependency that the
code does not actually use.

The observable outcomes are:

* `just --list` prints the recipes below and their group headings.
* `just process-up` brings up a Redpanda broker on `localhost:9092`.
* `just create-topics` creates the topics `orders`, `events`,
  `multi-partition-demo`, and `offset-mgmt-demo`.
* `cabal build all` emits a richer warning set than before (typically the
  same clean output, because the existing code is disciplined, but any new
  offenders are fixed as part of this plan).
* Opening the README shows a short paragraph about partition-EOF being
  dropped by `skipNonFatal`, with a pointer to `skipNonFatalExcept` for users
  who want to observe EOF.
* `mori show --full` no longer lists `iand675/hs-opentelemetry` as a project
  dependency.


## Milestones

### Milestone 1: Add the Justfile

Create `Justfile` at the repository root (the same directory as `cabal.project`,
`flake.nix`, `process-compose.yaml`). Model it on
`/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly/Justfile` but adapt the topic
list and package names to this repository.

Contents:

    # Justfile for shibuya-kafka-adapter

    # Default recipe to display help
    default:
        @just --list


    # --- Services ---

    # Start Redpanda via process-compose (runs in foreground; Ctrl-C to stop)
    [group("services")]
    process-up:
        process-compose --tui=false --unix-socket .dev/process-compose.sock up

    # Stop Redpanda
    [group("services")]
    process-down:
        process-compose --unix-socket .dev/process-compose.sock down || true


    # --- Kafka (rpk) ---

    # Create every topic exercised by the integration tests and jitsurei examples
    [group("kafka")]
    create-topics:
        rpk topic create orders -p 1 || true
        rpk topic create events -p 1 || true
        rpk topic create multi-partition-demo -p 3 || true
        rpk topic create offset-mgmt-demo -p 1 || true

    # Delete the topics created by create-topics
    [group("kafka")]
    delete-topics:
        rpk topic delete orders events multi-partition-demo offset-mgmt-demo || true

    # List all topics
    [group("kafka")]
    list-topics:
        rpk topic list


    # --- Build ---

    # Build all packages
    [group("build")]
    build:
        cabal build all

    # Run the library test suite (requires process-up in another shell)
    [group("build")]
    test:
        cabal test shibuya-kafka-adapter

    # Run micro-benchmarks
    [group("build")]
    bench:
        cabal bench shibuya-kafka-adapter-bench

    # Clean build artifacts
    [group("build")]
    clean:
        cabal clean

    # Format code via treefmt (fourmolu + cabal-fmt + nixpkgs-fmt)
    [group("build")]
    fmt:
        nix fmt

The `|| true` after each topic creation means the recipe is idempotent: running
`just create-topics` twice does not fail on the second run.

Verify: from the repository root inside the dev shell, run `just --list`.
Expected output includes the four group headings (`services`, `kafka`,
`build`) and the recipes named above.

Verify that `just` is already on the PATH in the dev shell. Open
`flake.nix` — the `devShells.default.nativeBuildInputs` list includes
`pkgs.just`. No flake edit should be required. If for some reason `just` is
not available, add `pkgs.just` to the `nativeBuildInputs` list and record the
correction in Surprises & Discoveries.

### Milestone 2: Align GHC warnings with the sibling packages

The reference warning set is the one in
`/Users/shinzui/Keikaku/bokuno/kafka-effectful/kafka-effectful.cabal`, under
the `common warnings` stanza:

    common warnings
      ghc-options:
        -Wall -Wcompat -Widentities -Wincomplete-uni-patterns
        -Wincomplete-record-updates -Wredundant-constraints
        -fhide-source-paths -Wmissing-export-lists -Wpartial-fields
        -Wmissing-deriving-strategies

Apply this verbatim to the `common warnings` stanza in all three cabal files:

* `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`
* `shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal`
* `shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`

For the bench cabal, the existing `ghc-options` also contains flags specific to
benchmarking (`-Wno-orphans -rtsopts -with-rtsopts=-A32m
-fproc-alignment=64`). Keep those in addition to the warning set — they live on
the `benchmark` stanza, not the `common warnings` stanza, so there is no
collision.

Run `cabal build all`. Address any new warnings that surface. The likely
offenders, based on a pre-change read of the sources, are:

* `-Wmissing-export-lists` on jitsurei `Main.hs` files. Each declares
  `module Main (main) where`, which already has an export list, so this
  should pass. Verify.
* `-Wmissing-deriving-strategies` may flag stock-derived typeclasses that do
  not name their strategy. The source already uses `deriving stock` in the
  library; the bench uses `deriving anyclass` explicitly. Expect a clean
  build.
* `-Wredundant-constraints` will likely flag the `Error KafkaError :> es`
  constraint on `kafkaSource` if Plan 5 has not yet landed. Coordinate with
  Plan 5 if this plan lands first — either drop the constraint here (which
  does part of Plan 5's Milestone 3 work) and note the cross-plan action in
  Surprises & Discoveries, or wait for Plan 5 to merge first.

If any warning is not worth fixing (an unusual situation), add a targeted
`-Wno-...` suppression in the specific stanza rather than the common one, and
record the rationale in the Decision Log.

### Milestone 3: README polish

Edit `README.md` to add a short "Error classification" or "Notes" section that
explains the partition-EOF caveat. Suggested wording, in plain prose:

> The adapter filters non-fatal Kafka errors via `skipNonFatal` from
> `hw-kafka-streamly`. This drops poll timeouts and partition-EOF markers
> alongside genuinely benign errors. If your application relies on observing
> partition EOF (for example, to terminate a bounded read), the upstream
> `Kafka.Streamly.Source.skipNonFatalExcept` helper takes a predicate list
> that lets EOFs through; use it in place of the adapter and build your own
> envelope conversion if you need that behavior.

Also update the `Building` section (or add a new `Development` section) to
mention the Justfile:

> Common development tasks are available as `just` recipes. Run `just` (with
> no arguments) for the full list. The usual flow is `just process-up` in one
> shell (starts Redpanda), `just create-topics`, then `just test` or
> `just bench` or `cabal run <example>`.

Do not duplicate information that lives in the Justfile itself. Keep the
README terse — pointers, not redundant tables of commands.

### Milestone 4: Remove the stale `hs-opentelemetry` entry from mori.dhall

Open `mori.dhall`. In the `dependencies` list near the bottom of the file, the
entry `"iand675/hs-opentelemetry"` appears. No `.cabal` file in this
repository references `hs-opentelemetry`. Remove the line.

Verify with `mori show --full`. The `Dependencies` section should no longer
list `iand675/hs-opentelemetry`.

If `hs-opentelemetry` does appear in a build graph through a transitive
dependency of `shibuya-core` (which uses it), that transitive use is tracked
via `shinzui/shibuya` — it does not justify a direct dependency declaration
in this repository's manifest.

### Milestone 5: End-to-end verification

From the repository root, inside the dev shell:

    just process-up

In a second shell:

    just create-topics
    just build
    just test
    just bench
    just fmt

Each command should complete without error. `just test` requires the Redpanda
broker started by `just process-up`. `just fmt` should be a no-op (the tree
should already be formatted). `just bench` runs the micro-benchmarks and
prints timings; compare against `shibuya-kafka-adapter-bench/baseline.csv` to
confirm nothing regressed dramatically — this is not a formal gate, just a
sanity check.

Tear down:

    just delete-topics
    just process-down


## Progress

- [x] Milestone 1: Create `Justfile` at repository root with the recipes listed
      above. (2026-04-18)
- [x] Milestone 1: `just --list` prints the expected groups and recipes from
      within the Nix dev shell. (2026-04-18)
- [ ] Milestone 2: Apply the aligned warning set to all three cabal files'
      `common warnings` stanzas.
- [ ] Milestone 2: `cabal build all` passes with the new warnings.
- [ ] Milestone 2: Fix any new warnings or record targeted suppressions with
      rationale.
- [ ] Milestone 3: Add the partition-EOF caveat paragraph to `README.md`.
- [ ] Milestone 3: Add a Development/Justfile pointer to `README.md`.
- [ ] Milestone 4: Remove `"iand675/hs-opentelemetry"` from `mori.dhall`'s
      `dependencies` list.
- [ ] Milestone 4: `mori show --full` no longer lists `hs-opentelemetry`.
- [ ] Milestone 5: `just process-up` / `create-topics` / `build` / `test` /
      `bench` / `fmt` all succeed.
- [ ] Milestone 5: Teardown with `just delete-topics` / `process-down`
      succeeds.


## Surprises & Discoveries

(None yet. Record discoveries here as implementation proceeds. Likely
candidates: unexpected warnings from the aligned warning set; `just`
unexpectedly missing from the dev shell; an `rpk topic create` variant that
returns nonzero even with `|| true`.)


## Decision Log

- Decision: model the Justfile on `hw-kafka-streamly`'s layout rather than
  inventing a new recipe taxonomy. Rationale: contributors moving between
  Kafka-related repositories encounter the same commands, which reduces
  cognitive load. The topic names in `create-topics` come from the jitsurei
  examples and the tests' default patterns. Date: 2026-04-18.

- Decision: include idempotency (`|| true`) on every `rpk topic create` and
  `rpk topic delete`. Rationale: making the recipes re-runnable without
  error is worth the small loss in error visibility. If a topic creation
  genuinely fails for an unrelated reason, the subsequent `just test` run
  will surface it. Date: 2026-04-18.

- Decision: copy the warning set verbatim from `kafka-effectful` rather than
  cherry-picking a subset. Rationale: consistency with the sibling packages
  is more valuable than debating each flag. If a specific flag proves
  counterproductive in this repository, the fix is a targeted `-Wno-` in the
  one stanza that needs it, not a divergent common stanza. Date: 2026-04-18.

- Decision: keep the README short and point at the Justfile rather than
  enumerate recipes twice. Rationale: the Justfile is self-documenting via
  `just --list`; duplicating recipe descriptions in the README creates two
  places to update and invites drift. Date: 2026-04-18.


## Outcomes & Retrospective

To be filled in on completion.
