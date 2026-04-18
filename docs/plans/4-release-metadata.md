# Add Hackage release metadata and a real CHANGELOG

MasterPlan: docs/masterplans/1-0.1.0.0-release-prep.md

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this work, `cabal sdist` for `shibuya-kafka-adapter` produces a tarball that is
ready to upload to Hackage. The tarball contains a top-level `LICENSE` file, a
README with install and usage guidance, and a CHANGELOG that describes what the
0.1.0.0 release delivers. A Hackage reader can see who wrote the library, which
GHCs were tested, where to file bugs, and which repository to check out. A
downstream consumer running `cabal haddock` sees the project name linked to its
homepage.

To verify the outcome, a contributor runs `cabal sdist shibuya-kafka-adapter` at the
repository root, unpacks the resulting tarball, and confirms that `LICENSE`,
`README.md`, and `CHANGELOG.md` are present under `shibuya-kafka-adapter-0.1.0.0/`.
They then run `cabal haddock shibuya-kafka-adapter` and confirm the rendered
package page shows the filled-in metadata.

The three packages in this repository (`shibuya-kafka-adapter`,
`shibuya-kafka-adapter-bench`, `shibuya-kafka-adapter-jitsurei`) all declare
`license: MIT` but ship no `LICENSE` file and no `license-file:` cabal field. Only
the library package is intended for Hackage, but all three should carry consistent
metadata so a casual reader does not wonder whether the bench and jitsurei packages
are licensed differently. This plan addresses all three.


## Milestones

### Milestone 1: Add the LICENSE file

The goal of this milestone is that a single `LICENSE` file exists at the repository
root with the standard MIT license text, using `2026 Nadeem Bitar` as the copyright
line (matching the pattern used in sibling packages `kafka-effectful` and
`hw-kafka-streamly`, both of which live under `/Users/shinzui/Keikaku/bokuno/`).

Create `LICENSE` at the repository root. Copy the MIT license text verbatim and set
the year to 2026 and the copyright holder to `Nadeem Bitar`. After this milestone,
`ls LICENSE` from the repository root succeeds.

### Milestone 2: Populate Hackage metadata in the library cabal

The goal of this milestone is that `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`
contains the full set of Hackage metadata fields: `license-file`, `copyright`,
`homepage`, `bug-reports`, `tested-with`, `extra-doc-files`, and a
`source-repository head` stanza. The sibling package
`/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly/hw-kafka-streamly/hw-kafka-streamly.cabal`
is the reference — open it and mirror the relevant fields.

The concrete edits to `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal` are:

* Add `license-file: LICENSE` directly below the existing `license: MIT` line.
* Add `copyright: 2026 Nadeem Bitar` below the author line.
* Add `homepage: https://github.com/shinzui/shibuya-kafka-adapter` below the
  maintainer line.
* Add `bug-reports: https://github.com/shinzui/shibuya-kafka-adapter/issues` below
  homepage.
* Add `tested-with: GHC ==9.12.2` below build-type. This is the GHC version pinned
  by the flake (see `flake.nix`, `ghcVersion = "ghc912"`).
* Extend `extra-doc-files: CHANGELOG.md` to include `README.md` on a separate line.
  The `LICENSE` file goes there only if you choose to ship it as a doc file; for
  consistency with `hw-kafka-streamly`, leave `LICENSE` out of `extra-doc-files`
  (it is shipped by default because `license-file:` is set).
* After the `extra-doc-files` block, add a `source-repository head` stanza:

        source-repository head
          type:     git
          location: https://github.com/shinzui/shibuya-kafka-adapter.git

The LICENSE file path is repository-relative; when cabal packages the library,
`license-file: LICENSE` is interpreted relative to the package directory, so symlink
or copy `LICENSE` into `shibuya-kafka-adapter/` as well if `cabal sdist` complains.
The safest approach is to keep the canonical `LICENSE` at the repo root and create
`shibuya-kafka-adapter/LICENSE` as a copy (git will store the second copy too;
that is intentional because cabal sdist needs it inside the package directory).

### Milestone 3: Mirror metadata in bench and jitsurei cabals

The goal of this milestone is that the bench and jitsurei cabals carry the same
licensing metadata so a casual reader does not wonder whether they are licensed
differently. These packages are not published to Hackage (they are marked
`visibility: Internal` in `mori.dhall`), but the metadata remains consistent.

Apply the same edits to `shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal`
and `shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`:

* `license-file: LICENSE` (copy `LICENSE` into each package directory).
* `copyright: 2026 Nadeem Bitar`.
* `homepage` and `bug-reports` fields pointing at the same GitHub URLs as the
  library.
* `tested-with: GHC ==9.12.2`.
* A matching `source-repository head` stanza.

The bench cabal currently has no `extra-doc-files:` field — leave it that way; there
is no README or CHANGELOG in those subdirectories to ship.

### Milestone 4: Rewrite the CHANGELOG

The goal of this milestone is that
`shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`'s declared `CHANGELOG.md`
contains a substantive entry for 0.1.0.0 that a Hackage reader can use to
understand what the release delivers. The current file is a single placeholder
line, `* Initial release`.

Rewrite `shibuya-kafka-adapter/CHANGELOG.md` so the 0.1.0.0 entry describes:

* the adapter's purpose (bridging Apache Kafka to the Shibuya queue-processing
  framework),
* the integrations (`kafka-effectful` for the consumer effect and
  `hw-kafka-streamly` for error classification, on top of `hw-kafka-client`),
* the feature set at 0.1.0.0 (polling, offset commit semantics using
  `noAutoOffsetStore` plus `storeOffsetMessage` plus auto-commit, partition
  awareness, `AckHalt` pausing the originating partition, W3C trace header
  extraction, timestamp conversion, graceful shutdown via `commitAllOffsets`),
* the known limitations (no automatic partition resume after `AckHalt` within the
  consumer session, no DLQ production — dead-letter decisions store the offset and
  are otherwise a no-op).

Write this in plain prose with a short bulleted feature list. Keep it scannable;
the Hackage CHANGELOG viewer renders Markdown. Use the PGMQ sibling
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-adapter/CHANGELOG.md`
as a style reference.

### Milestone 5: Verify the release artifact

The goal of this milestone is that the tarball produced by `cabal sdist` contains
everything a Hackage user expects.

Run from the repository root:

    cabal sdist shibuya-kafka-adapter

cabal writes a tarball under `dist-newstyle/sdist/`. Extract it and confirm that
the unpacked tree contains `LICENSE`, `README.md` (if shipped — see Decision Log
entry about README packaging), `CHANGELOG.md`, and the `src/` tree. Then run:

    cabal haddock shibuya-kafka-adapter

and confirm the generated HTML under
`dist-newstyle/build/*/ghc-*/shibuya-kafka-adapter-0.1.0.0/doc/html/shibuya-kafka-adapter/`
shows the homepage, bug-reports, and copyright fields on the package landing
page.


## Progress

- [x] Milestone 1: Create `LICENSE` at repository root with MIT text and 2026
      copyright. (2026-04-18)
- [x] Milestone 2: Populate Hackage metadata in
      `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`. (2026-04-18)
- [x] Milestone 2: Copy `LICENSE` into `shibuya-kafka-adapter/` for `cabal sdist`.
      Also copied `README.md` into the library directory so the package-relative
      `extra-doc-files: README.md` resolves inside `cabal sdist`. (2026-04-18)
- [x] Milestone 3: Mirror metadata in
      `shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal` and
      `shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`.
      (2026-04-18)
- [x] Milestone 3: Copy `LICENSE` into both bench and jitsurei directories.
      (2026-04-18)
- [x] Milestone 4: Rewrite `shibuya-kafka-adapter/CHANGELOG.md` with a real 0.1.0.0
      entry. (2026-04-18)
- [x] Milestone 5: Run `cabal sdist shibuya-kafka-adapter`, extract the tarball,
      and confirm LICENSE / README / CHANGELOG are packaged. Tarball at
      `dist-newstyle/sdist/shibuya-kafka-adapter-0.1.0.0.tar.gz` unpacks to
      `CHANGELOG.md`, `LICENSE`, `README.md`, `shibuya-kafka-adapter.cabal`,
      `src/`, and `test/`. (2026-04-18)
- [x] Milestone 5: Run `cabal haddock shibuya-kafka-adapter` and confirm metadata
      renders on the generated package page. Haddock emitted docs under
      `dist-newstyle/build/aarch64-osx/ghc-9.12.2/shibuya-kafka-adapter-0.1.0.0/doc/html/shibuya-kafka-adapter/`
      with `CHANGELOG.md` and `README.md` copied in. `cabal check` on the
      library reports "No errors or warnings" — the cabal file is Hackage-clean.
      (2026-04-18)


## Surprises & Discoveries

- Local `cabal haddock` produces a per-module index at
  `dist-newstyle/build/.../doc/html/shibuya-kafka-adapter/index.html`, not a
  Hackage-style package landing page, so the `homepage`, `bug-reports`, and
  `copyright` fields are not rendered in the local haddock output. Those fields
  are surfaced by Hackage at upload time. For local verification, `cabal check`
  was used as a proxy — it parses the cabal file with Hackage's validation
  rules and reports "No errors or warnings could be found in the package."
  The `CHANGELOG.md` and `README.md` files from `extra-doc-files` are copied
  into the haddock output directory, which does confirm that `extra-doc-files`
  resolves correctly against the package directory. (2026-04-18)

- The plan text said to add fields "below" specific existing lines, but the
  `hw-kafka-streamly` reference cabal places them in a different order
  (license/license-file adjacent, copyright under author, homepage/bug-reports
  above build-type, tested-with below build-type). The reordering was minor
  and matches the reference style while still placing each field in a sensible
  position. Decision recorded below. (2026-04-18)


## Decision Log

- Decision: ship README in `extra-doc-files` of the library cabal but not in the
  bench/jitsurei cabals. Rationale: there is a single repository-level README, and
  only the library is published to Hackage; the bench and jitsurei packages are
  Internal per `mori.dhall`. Shipping the root README is an established pattern in
  `kafka-effectful.cabal` and `hw-kafka-streamly.cabal`, both of which also have a
  package-directory README to reference. For this repository the README lives at
  the root; cabal's `extra-doc-files` resolves relative to the package directory,
  so copy or symlink `README.md` into `shibuya-kafka-adapter/` alongside the
  LICENSE copy. Date: 2026-04-18.

- Decision: keep the three cabals in lock-step on licensing metadata even though
  bench and jitsurei are Internal. Rationale: a reader browsing any cabal file
  should see the same licensing story. Divergence in metadata (one cabal saying
  MIT without a LICENSE pointer, another including one) invites confusion.
  Date: 2026-04-18.

- Decision: place new metadata fields in the `hw-kafka-streamly` reference
  ordering (copyright below author, homepage/bug-reports below maintainer,
  license-file below license, tested-with below build-type) rather than the
  strict "below line X" anchors named in the plan body. Rationale: the
  reference cabal already shipped to Hackage uses this grouping, it reads
  more naturally (licensing fields clustered, URL fields clustered), and no
  semantic content changes. Date: 2026-04-18.

- Decision: use `cabal check` as the local verification proxy for Hackage
  metadata rendering instead of inspecting the haddock package page.
  Rationale: local `cabal haddock` output is a per-module index, not the
  Hackage landing page; the cabal-level fields only render once uploaded.
  `cabal check` applies the same validation rules Hackage uses at upload time,
  which is the closest local check available. Date: 2026-04-18.


## Outcomes & Retrospective

Completed 2026-04-18. All five milestones are green.

What shipped:

* A canonical `LICENSE` (MIT, 2026 Nadeem Bitar) at the repository root, and
  per-package copies alongside each of the three cabal files so
  `license-file: LICENSE` resolves under each package directory.
* Full Hackage metadata (`license-file`, `copyright`, `homepage`,
  `bug-reports`, `tested-with`, `source-repository head`) added to all three
  cabals. The library additionally ships `README.md` in `extra-doc-files`.
* A substantive `shibuya-kafka-adapter/CHANGELOG.md` 0.1.0.0 entry describing
  the adapter's purpose, integrations (`kafka-effectful`,
  `hw-kafka-streamly`, `hw-kafka-client`), feature set (polling, offset
  commit via `noAutoOffsetStore` + `storeOffsetMessage` + auto-commit,
  partition awareness, `AckHalt`, W3C trace header extraction, timestamp
  conversion, graceful shutdown via `commitAllOffsets`), and known
  limitations (no partition resume after `AckHalt`, no DLQ production).

Verification:

* `cabal sdist shibuya-kafka-adapter` → tarball at
  `dist-newstyle/sdist/shibuya-kafka-adapter-0.1.0.0.tar.gz`; unpacked
  contents: `CHANGELOG.md`, `LICENSE`, `README.md`,
  `shibuya-kafka-adapter.cabal`, `src/`, `test/`.
* `cabal haddock shibuya-kafka-adapter` → docs generated; `CHANGELOG.md` and
  `README.md` are copied into the doc output.
* `cabal check` → "No errors or warnings could be found in the package."

Lessons:

* Local `cabal haddock` does not render Hackage-level package metadata — that
  is Hackage's responsibility at upload time. `cabal check` is the right
  local proxy for validating Hackage metadata correctness.
* The `extra-doc-files` field resolves relative to the package directory,
  not the repository root, so shipping a root-level README on Hackage
  requires either a package-directory copy or a symlink. A copy was chosen
  for simplicity (matches the `hw-kafka-streamly` pattern).
