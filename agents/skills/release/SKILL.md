---
name: release
description: Release shibuya-kafka-adapter to Hackage following PVP, coordinating with shibuya-core releases
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# Adapter Release Skill

Release the `shibuya-kafka-adapter` package to Hackage. This repo
publishes one library; the examples and benchmarks ride along on the
same version line for repo consistency but are not published.

## Versioning Strategy

The adapter follows a **shared version line with `shibuya-core`**: when
`shibuya-core` cuts a new release that affects the adapter (new
`Envelope` field, new `Shibuya.Core.*` API the adapter consumes,
breaking changes, etc.), bump the adapter to the same `A.B.C.D` so
users have a one-glance compatibility signal.

A single git tag `v<version>` marks each release.

## Packages

Released to Hackage:

1. **shibuya-kafka-adapter** — the only library released from this repo.

NOT released (but kept on the same version line for repo consistency):

- **shibuya-kafka-adapter-jitsurei** — runnable example consumers.
- **shibuya-kafka-adapter-bench** — benchmark suite.

## Arguments

`$ARGUMENTS` is optional:
- `major`, `minor`, or `patch` — specifies the bump level.
- If omitted, determine the bump level from the changes (see step 2).

## Steps

### 1. Determine what changed since the last release

- Read the current version from
  `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`.
- Find the latest git tag matching `v*`. If none exists, this is the
  first tagged release; use the repo's initial commit as the diff
  base.
- Run `git log --oneline <last-tag>..HEAD` to list commits since the
  last release.
- If there are no commits since the last tag, inform the user there is
  nothing to release and stop.

Note: the cabal version may already be ahead of the latest tag (a
release was prepped in-cabal but never cut). In that case, decide with
the user whether to ship the prepped version as-is or to bump
further.

Present a summary showing:
- Current cabal version
- Latest git tag (or "none — first tagged release")
- Number of commits since last tag
- The current `shibuya-core ^>=` bound declared in the cabal file
- The latest published `shibuya-core` version on Hackage (run
  `cabal update && cabal info shibuya-core | head` or check
  https://hackage.haskell.org/package/shibuya-core)

### 2. Determine the next version using PVP

The Haskell PVP version format is `A.B.C.D`:
- `A.B` — **major**: breaking API changes (removed/renamed exports,
  changed types, changed semantics).
- `C` — **minor**: backwards-compatible API additions (new exports,
  new modules, new instances).
- `D` — **patch**: bug fixes, docs, internal-only changes,
  performance.

Rules:
- If `$ARGUMENTS` is `major`, `minor`, or `patch`, use that bump
  level.
- If a new `shibuya-core` release is the trigger, the adapter
  typically matches `shibuya-core`'s bump level (a major in core that
  the adapter exposes through its own API surface ⇒ adapter major; a
  core-only addition the adapter merely depends on ⇒ adapter patch
  unless the adapter also gained API of its own).
- Otherwise analyse commits:
  - "breaking", "remove", "rename", "change type" → major
  - "add", "new", "feature", "export" → minor
  - "fix", "docs", "refactor", "internal" → patch
- Present the proposed bump to the user and ask for confirmation
  before proceeding.

Increment the version:
- **major**: increment `B`, reset `C` and `D` to 0.
- **minor**: increment `C`, reset `D` to 0.
- **patch**: increment `D`.

### 3. Verify upstream is on Hackage

The adapter cannot be released to Hackage if its `build-depends` are
satisfied only by a local sibling checkout — Hackage's build bot won't
have access to it.

- Read the declared `shibuya-core ^>=A.B.C.D` bound in
  `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal` (both the
  `library` and `test-suite` sections).
- Confirm `shibuya-core A.B.C.D` (or a compatible version) is
  published on Hackage:
  - `cabal update`
  - `cabal info shibuya-core` (or fetch
    https://hackage.haskell.org/package/shibuya-core)
- Inspect `cabal.project.local` (if it exists). If it contains a
  `packages:` stanza pointing at `../shibuya/shibuya-core` (or any
  other local override that shadows a Hackage dep used by the adapter
  library), the override **must be removed or commented out** before
  the release — otherwise the local build is misleading and the sdist
  will fail to build on Hackage.
  - `cabal.project.local` is gitignored, so removal is local-only; no
    commit needed for that file.
- Re-run `cabal build all` after removing the override to confirm the
  adapter still builds against the published `shibuya-core`.

If upstream isn't on Hackage yet, **stop**: cut the upstream
`shibuya-core` release first (using the sibling `shibuya/` repo's
`/release` skill), then re-run this skill.

### 4. Update version, dependency bound, and changelog

#### Version update
- Edit `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal` and set the
  new version.
- Edit `shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`
  to the same version.
- Edit `shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal`
  to the same version. Keeping siblings aligned is a deliberate
  convention for this repo, even though only the library is published.

#### Dependency bound update
- If this release pairs with a new `shibuya-core` major or minor,
  update the `shibuya-core ^>=A.B.C.D` bound to point at the new
  release, in **both** the `library` and `test-suite` sections of
  `shibuya-kafka-adapter.cabal`.
- Use PVP-compatible bounds: `^>=A.B.C.D` matching the published
  release.
- Audit any code that depends on changed core APIs (e.g. for the
  shibuya-core 0.4.0.0 cycle: the new `Envelope.attempt` field —
  any direct `Envelope` constructor calls in `Convert.hs`, tests, or
  example code must be updated).

#### Changelog update
- `shibuya-kafka-adapter/CHANGELOG.md`: add a new section above prior
  entries with today's date in `YYYY-MM-DD` format. Move content from
  any "Unreleased" section into the new version section.
- If a root `CHANGELOG.md` exists, give it the same treatment;
  otherwise the package-level changelog is canonical.
- Group entries by:
  - **Breaking Changes** (if major)
  - **New Features** (if minor or major)
  - **Bug Fixes** (if any)
  - **Other Changes** (docs, build, internal)
  - Only include categories with entries.
- If the release is paired with a new `shibuya-core`, mention the new
  required lower bound under **Build** or **Other Changes**.

Show the user the full diff (versions, dep bound, changelog entries)
for review before committing.

### 5. Verify builds

- Run `nix fmt` to ensure formatting is clean.
- Run `cabal build all` to confirm the cabal build still succeeds
  against the published `shibuya-core` (i.e. with no local override).
- Run `cabal test shibuya-kafka-adapter` to confirm tests pass.
  - Integration tests require Redpanda (started via `just
    process-up`). If the dev stack isn't running, ask the user before
    skipping — do not silently skip.
- Run `nix flake check` to verify treefmt and pre-commit checks pass.
  - The flake intentionally does **not** expose
    `packages.default` — building the Haskell package itself is
    `cabal build all`'s job. The flake only carries the dev shell,
    formatter, and the formatting + pre-commit checks. Don't add a
    `packages.default` overlay back unless someone is willing to
    maintain `callHackageDirect` overrides for `shibuya-core`,
    `kafka-effectful`, `hw-kafka-streamly`,
    `hs-opentelemetry-semantic-conventions`, plus `streamly` /
    `streamly-core` bumps.
  - Note: newly created files must be `git add`-ed before nix
    evaluation will see them (nix uses the git tree).
  - If any check fails, fix the issue before proceeding.

### 6. Commit, tag, and push

- Stage the modified `.cabal` files and `CHANGELOG.md`.
- Create a single commit using a Conventional Commits message:
  `chore(release): <new-version>` (project-wide convention — see
  global `CLAUDE.md`). The body should summarize what's in the release
  and, if applicable, which `shibuya-core` release this pairs with.
- Create a single annotated tag:
  `git tag -a v<version> -m "Release <version>"`.
- Push commit and tag: `git push && git push --tags`.

The commit and tag should only be created **after** user approval of
the diff in step 4.

### 7. Publish to Hackage

All cabal commands target the `shibuya-kafka-adapter` package
explicitly so the non-published sibling packages are not touched.

1. From the repo root, run `cabal check` against the package:
   `cd shibuya-kafka-adapter && cabal check && cd ..`
2. Run `cabal test shibuya-kafka-adapter` for a final test pass (skip
   only if previously confirmed in step 5; never skip silently).
3. `cabal sdist shibuya-kafka-adapter`, then
   `cabal upload --publish dist-newstyle/sdist/shibuya-kafka-adapter-<version>.tar.gz`.
4. `cabal haddock shibuya-kafka-adapter --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`,
   then
   `cabal upload --publish --documentation dist-newstyle/shibuya-kafka-adapter-<version>-docs.tar.gz`.
5. Report the Hackage URL:
   `https://hackage.haskell.org/package/shibuya-kafka-adapter-<version>`.

If the upload fails (e.g. "version already exists"), stop and report
to the user — do **not** retry blindly.

### 8. Create GitHub release

After the Hackage upload succeeds (so release notes can link to a live
package page):

```bash
gh release create v<version> --title "v<version>" --notes "$(cat <<'EOF'
## Package

[shibuya-kafka-adapter <version> on Hackage](https://hackage.haskell.org/package/shibuya-kafka-adapter-<version>)

Paired with [shibuya-core <core-version>](https://hackage.haskell.org/package/shibuya-core-<core-version>) (if applicable).

## What's Changed

<changelog entries for this version from shibuya-kafka-adapter/CHANGELOG.md>
EOF
)"
```

- Use the package CHANGELOG entries for the body.
- Mention the paired `shibuya-core` version when the release is driven
  by an upstream change.
- Report the GitHub release URL.

### 9. Restore local development override (optional)

If the user typically develops against an in-tree sibling
`shibuya-core`, restore the `cabal.project.local` override they
removed in step 3 (or remind them to do so). This file is gitignored
so it doesn't affect downstream consumers.

## Important

- Always ask the user to confirm the version bump and changelog before
  committing.
- Never skip `nix fmt`, `cabal check`, tests, `nix build`, or
  `nix flake check`.
- If `cabal test` cannot be run because Redpanda isn't up, surface
  this to the user and ask whether to proceed or to start
  `just process-up` first — do not silently skip integration tests.
- Never release while `cabal.project.local` shadows `shibuya-core`
  with a local checkout — Hackage cannot see local paths.
- If any step fails, stop and report — do not paper over failures.
- The commit and tag should only be created AFTER user approval of all
  changes.
