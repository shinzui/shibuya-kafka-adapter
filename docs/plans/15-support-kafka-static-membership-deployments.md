---
id: 15
slug: support-kafka-static-membership-deployments
title: "Support Kafka Static Membership Deployments"
kind: exec-plan
created_at: 2026-08-21T23:01:58Z
intention: "intention_01m0k8yc7yeat9vpn3rg9b366n"
---

# Support Kafka Static Membership Deployments

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kafka redistributes topic partitions whenever the membership of a consumer group
changes. That redistribution is called a rebalance, and an ordinary rolling
deployment can make every consumer in the group pause while the group agrees on
a new assignment. Kafka static membership gives each consumer a stable
`group.instance.id`, allowing a restarted consumer to reclaim its assignment
without changing group membership when it returns within the configured session
timeout.

After this plan is complete, an application using `shibuya-kafka-adapter` can
opt into static membership through the `ConsumerProperties` passed to
`runKafkaConsumer`, obtain the instance identifier from a stable Kubernetes
StatefulSet pod identity, and perform a rolling restart without revoking
partitions from the surviving group members. A live Redpanda-backed integration
test will prove that a consumer which closes and rejoins with the same instance
identifier keeps its assignment and does not cause a revoke event on the other
member. A second test will prove that accidentally starting two consumers with
the same identifier terminates one consumer with a visible fatal Kafka error
instead of leaving the adapter polling forever.

This feature reduces group-wide pauses; it cannot consume the restarted
member's partitions while that process is absent. A group with only one member
therefore still pauses completely for the duration of its restart.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: make the released Haskell Kafka dependency path surface
  static-member fencing errors and expose a named static-membership property
  builder.
- [ ] Milestone 2: add opt-in adapter documentation and a runnable example that
  obtains a stable instance identifier from deployment configuration.
- [ ] Milestone 3: add live tests for restart-without-revoke behavior and
  duplicate-identifier fatal fencing.
- [ ] Milestone 4: run the complete validation matrix, update capability and
  release records, and record the observed results in this plan.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep this ExecPlan in `shibuya-kafka-adapter`, while representing
  the `hw-kafka-client` change as a cross-repository prerequisite.
  Rationale: The user-visible outcome is safe deployment of a Shibuya Kafka
  adapter. The adapter owns the documentation, runnable example, dependency
  requirement, and end-to-end evidence, even though the low-level fatal-error
  fix belongs to the Kafka binding.
  Date: 2026-08-21.

- Decision: Configure static membership on `ConsumerProperties`; do not add a
  field to `KafkaAdapterConfig`.
  Rationale: `runKafkaConsumer` creates the consumer before `kafkaAdapter` is
  called. `KafkaAdapterConfig` can neither affect an already-created consumer
  nor choose a deployment-stable identity. Adding the field there would imply
  control that the adapter does not have.
  Date: 2026-08-21.

- Decision: Treat observable duplicate-identifier fencing as a prerequisite
  for production support.
  Rationale: Released `hw-kafka-client 5.3.0` accepts arbitrary librdkafka
  properties, including `group.instance.id`, but its asynchronous batch-poll
  path can consume the generic fatal event on the callback queue and leave the
  application polling an empty redirected queue. The fix at
  `mori://shinzui/hw-kafka-client/commits/6caed636898a78e9f6e5a9c93eeb5562cbb2580a`
  checks librdkafka's fatal state on every poll and makes the condition visible
  to this adapter's existing fatal-error propagation path.
  Date: 2026-08-21.

- Decision: Recommend Kubernetes StatefulSet identity and explicitly warn
  against using an ordinary Deployment pod name.
  Rationale: A StatefulSet assigns each pod a stable ordinal name and replaces
  that identity rather than inventing a new one on every rollout. Deployment
  pod names change, and `maxSurge` can overlap old and new pods. A new identifier
  defeats static membership; one shared identifier fences colliding members.
  Date: 2026-08-21.

- Decision: Keep cooperative-sticky assignment outside this plan.
  Rationale: Static membership addresses short restarts of known members.
  Cooperative assignment addresses genuine membership changes such as scaling.
  The adapter currently clears retry barriers on revocation but does not fence
  in-flight work during a cooperative rebalance, so combining the changes would
  make the safety claim broader than the implementation evidence.
  Date: 2026-08-21.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Kafka stores each record in a topic partition. Consumers with the same
`group.id` form a consumer group, and Kafka assigns each partition to one group
member at a time. A dynamic member receives a broker-generated member identity;
when it leaves or another dynamic member joins, the group normally rebalances.
A static member additionally supplies `group.instance.id`, a non-empty string
which must be unique within that group. Kafka retains the static member's slot
until `session.timeout.ms` expires, so the same logical process can restart and
resume the slot. If two live processes use the same identifier, Kafka fences a
member. Fencing means the broker permanently rejects that consumer instance;
the process must surface the fatal error, close the consumer, and create a new
one with a correct identity.

The public adapter is implemented in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`. Its `kafkaAdapter` function
runs inside a `KafkaConsumer` effect which already exists. The adapter polls
records, converts them to Shibuya messages, stores acknowledged offsets, and
commits stored offsets during shutdown. The associated configuration in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Config.hs` contains only topic
metadata, poll timeout, and batch size. Its module documentation explicitly
states that brokers, group identity, and other consumer properties belong to
`runKafkaConsumer`.

`runKafkaConsumer` comes from
`mori://shinzui/kafka-effectful/packages/kafka-effectful`. It accepts a
`ConsumerProperties` value, creates a raw consumer through
`hw-kafka-client`, and closes the consumer when the effect scope ends. Its
`Kafka.Effectful.Consumer` facade already re-exports the general
`extraProp :: Text -> Text -> ConsumerProperties` builder. Consequently static
membership already reaches librdkafka when a caller writes:

    props =
        brokersList brokers
            <> groupId consumerGroup
            <> noAutoOffsetStore
            <> extraProp "group.instance.id" stableInstanceId
            <> extraProp "session.timeout.ms" "120000"

The `120000` value above is an example, not a universal default. It represents
120 seconds. Operators must choose a timeout above their measured high-percentile
pod replacement time, with enough margin for image pulls and scheduling. A
longer timeout avoids rebalances during longer restarts but also leaves a failed
member's partitions unavailable for longer before Kafka assigns them elsewhere.
The broker's configured minimum and maximum session timeouts constrain the
allowed value.

This repository currently declares `hw-kafka-client >=5.3 && <6` in
`shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`. As of 2026-08-21, the
authoritative Hackage index and upstream tags both identify 5.3.0 as the current
release. The root `cabal.project` has no `source-repository-package` stanza for
the local fork, and `cabal.project.local` deliberately disables local dependency
overrides for release verification. The published adapter therefore selects
the released binding rather than the fatal-observability fix in
`mori://shinzui/hw-kafka-client/repos/hw-kafka-client`.

The current adapter source uses `pollMessageBatch` in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs` and passes its
results through `Kafka.Streamly.Stream.skipNonFatal`. Once a Kafka fatal error
appears as a `Left KafkaError`, the existing `ingestedStream` throws it through
the `Error KafkaError` effect. No new adapter error channel is needed; the
dependency must reliably return the error from batch polling.

Live integration tests reside in
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs`. Test
helpers in `shibuya-kafka-adapter/test/Kafka/TestEnv.hs` allocate a random topic
and consumer group per test and connect to the shared Redpanda broker at
`127.0.0.1:9092`. The test suite already depends on `async` and has examples of
bounded waits through `System.Timeout.timeout`, so the new multi-consumer tests
can coordinate concurrent consumers without introducing a new package.

This investigation was prompted by Broadway Kafka 0.6.0. The comparison project
is intended to be referenced as `mori://elixir-broadway/broadway_kafka`; it was
not registered when this plan was written, so artifact-level resolution is
pending. Its repository-relative `CHANGELOG.md` describes static membership and
its `lib/broadway_kafka/producer_options.ex` exposes `group_instance_id` after
upgrading the underlying Brod client. The relevant lesson is the ownership
boundary: the framework validates and passes the option, while the Kafka client
implements group membership and fencing.


## Plan of Work

Milestone 1 establishes a released dependency path that is safe to advertise.
Use Mori to locate the source for
`mori://shinzui/hw-kafka-client/repos/hw-kafka-client`, then verify the current
released versions against Hackage and both the upstream and fork release tags.
Bring the fatal-observability change represented by
`mori://shinzui/hw-kafka-client/commits/6caed636898a78e9f6e5a9c93eeb5562cbb2580a`
onto the dependency's releasable branch without losing unrelated upstream work.
Add `GroupInstanceId` to `Kafka.Consumer.Types` and a
`groupInstanceId :: GroupInstanceId -> ConsumerProperties` builder to
`Kafka.Consumer.ConsumerProperties`, implemented as the existing arbitrary
property mechanism with key `group.instance.id`. Re-export both through
`Kafka.Consumer`, add focused property-composition tests, and add a live test
which proves a duplicate identifier produces an observable fatal result in
both supported poll shapes. Follow that repository's release procedure and do
not update this adapter's lower bound until the release is visible in the
authoritative package registry and its upstream release tag resolves. Then
re-export `GroupInstanceId` and `groupInstanceId` from
`Kafka.Effectful.Consumer` in
`mori://shinzui/kafka-effectful/packages/kafka-effectful`, release that package
if a new public version is required, and update this repository to the first
released versions containing the complete path. At the end of the milestone,
an adapter build must resolve only released packages and batch polling must
surface a fenced static member as a fatal `KafkaError`.

Milestone 2 makes the feature understandable and usable while retaining opt-in
semantics. Add a static-membership section to `README.md` and the module-level
Haddock in `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`. Explain that
the property is supplied before `kafkaAdapter` is constructed, that every live
member in one group needs a unique stable identifier, and that a restart must
complete inside `session.timeout.ms` to avoid a rebalance. Document that only
the restarted member's partitions pause. Describe the Kubernetes StatefulSet
pattern: inject the stable pod name using the Downward API, include the
namespace or workload name when several StatefulSets share a group, and suffix
the identifier when a pod starts more than one consumer in the same group.
State explicitly why an ordinary Deployment pod name does not provide the
needed identity.

Add `shibuya-kafka-adapter-jitsurei/app/StaticMembership.hs` and a corresponding
`static-membership` executable stanza in
`shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`. The
example must require `KAFKA_GROUP_INSTANCE_ID`, accept an optional
`KAFKA_SESSION_TIMEOUT_MS`, build properties with `groupInstanceId`, log the
chosen non-secret values at startup, and otherwise follow the serial processing
and shutdown structure of `app/BasicConsumer.hs`. Missing or empty instance
identity must fail before consumer creation with an actionable message. At the
end of the milestone, a user can run the example twice in succession with the
same identifier and observe the configuration being reused.

Milestone 3 adds behavioral evidence. Extend
`shibuya-kafka-adapter/test/Kafka/TestEnv.hs` with helpers for static consumer
properties which accept a `GroupInstanceId`, a session timeout, and an optional
rebalance callback. Extend
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs` with two
bounded live tests. The restart test creates a topic with at least four
partitions, starts members `member-0` and `member-1`, waits until both have
assignments, records those assignments and clears the callback event log,
closes `member-1`, recreates it with the same static identifier before the
session timeout, and asserts that `member-0` received no revoke event and that
the recreated member recovered its previous partitions. The fencing test
starts a second live consumer using an identifier already held by another
member and asserts that the affected adapter returns a fatal Kafka error within
a short timeout. Every acquired consumer must be closed by its bracket even
when an assertion fails. Use a random group and topic for each test so static
membership state cannot leak between test runs.

Milestone 4 completes the public record and validates the supported path. Add
the new example and integration evidence to
`docs/capabilities/kafka-message-source.md`; update
`shibuya-kafka-adapter/CHANGELOG.md` with the opt-in feature, dependency
requirement, StatefulSet limitation, and timeout tradeoff. Run formatting,
builds, broker-free tests, live tests, the capability validator, and Nix flake
checks. Record exact versions and concise successful output in Progress,
Surprises & Discoveries, and Outcomes & Retrospective. The capability is
complete only if a clean dependency solve uses published artifacts and both
static-membership integration tests pass repeatedly.


## Concrete Steps

Run all adapter commands from the repository root:

    cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter

Before editing dependency bounds, locate the dependencies through Mori and
verify releases through authoritative registries and upstream tags. Do not
search `/nix/store` or the filesystem root.

    mori registry show shinzui/hw-kafka-client --full
    mori registry show shinzui/kafka-effectful --full
    mori path mori://shinzui/hw-kafka-client/repos/hw-kafka-client
    cabal list --simple-output hw-kafka-client | tail -n 10
    git ls-remote --tags https://github.com/haskell-works/hw-kafka-client.git
    git ls-remote --tags https://github.com/shinzui/hw-kafka-client.git

If Mori refuses to start because its projection catalog does not match the
installed binary, repair or deliberately migrate that Mori installation before
continuing dependency work. Do not replace source inspection with guesses.

In the dependency checkout returned by Mori, run the unit and live validation
used by that repository. The current checkout documents these commands:

    cabal test all
    KAFKA_TEST_BROKER=127.0.0.1:9092 \
      cabal test --test-show-details=direct --flag it

The expected live evidence includes a duplicate static instance identifier
being reported as a fatal consumer error rather than repeated empty batches.
Commit dependency work with Conventional Commits and cross-repository plan and
intention trailers. Because the plan is owned by another repository, its
trailer uses the canonical URI:

    ExecPlan: mori://shinzui/shibuya-kafka-adapter/plans/15-support-kafka-static-membership-deployments
    Intention: intention_01m0k8yc7yeat9vpn3rg9b366n

After the dependency releases are visible, update the Cabal bounds and adapter
sources in this repository. Check resolution before building:

    cabal build shibuya-kafka-adapter --dry-run
    cabal build all

The dry-run must name released `hw-kafka-client` and `kafka-effectful` versions
which contain the new interface and fatal polling behavior. It must not rely on
a sibling checkout or a developer-only `cabal.project.local` override.

Confirm the shared Redpanda cluster is available and run the focused live
tests. The test names introduced by Milestone 3 must contain `Static membership`
so they can be selected together.

    rpk cluster info -X brokers=127.0.0.1:9092
    cabal test shibuya-kafka-adapter-test \
      --test-options "--pattern 'Static membership'"

Expected output has two passing cases equivalent to:

    Static membership restart preserves group assignments: OK
    Static membership duplicate identifier surfaces fatal error: OK

Run the full repository validation:

    cabal test shibuya-kafka-adapter-test
    cabal bench shibuya-kafka-adapter-bench
    nix fmt
    nix flake check
    just capabilities

Exercise the example with a stable identifier. Use a disposable consumer group
or topic when testing manually so it does not interfere with production group
state.

    KAFKA_GROUP_INSTANCE_ID=orders-consumer-0 \
      KAFKA_SESSION_TIMEOUT_MS=120000 \
      cabal run static-membership

The first startup lines must identify static membership as enabled, print
`orders-consumer-0`, and print the selected timeout. They must not print broker
credentials or other consumer properties.

As implementation progresses, update this plan at every stopping point. Every
commit in this repository must end with:

    ExecPlan: docs/plans/15-support-kafka-static-membership-deployments.md
    Intention: intention_01m0k8yc7yeat9vpn3rg9b366n


## Validation and Acceptance

Acceptance requires all of the following observable behavior.

With two static consumers in the same random group and at least four topic
partitions, closing one consumer and recreating it with the same
`GroupInstanceId` before its session timeout does not deliver a
`RebalanceBeforeRevoke` or `RebalanceRevoke` callback to the surviving member.
The recreated consumer receives the same set of partitions it held before it
closed. The test must use bounded waits and fail with the captured event and
assignment logs rather than hanging.

With two concurrent consumers in the same group configured with the same
`GroupInstanceId`, the broker fences a member and the adapter's
`runError @KafkaError` scope returns a fatal Kafka error within the test timeout.
Repeated empty batches are not acceptable. If the low-level API exposes the
underlying cause, the test or diagnostic log should identify the fenced
instance error; the adapter-facing assertion may remain on the generic fatal
Kafka error because that is the stable stream contract.

Running `cabal run static-membership` without
`KAFKA_GROUP_INSTANCE_ID` fails immediately and explains how to provide the
value. Running it with a non-empty identifier shows the enabled identity and
session timeout before joining Kafka. The README and Haddock show the same
property ownership as the executable: consumer properties are passed to
`runKafkaConsumer`, while `KafkaAdapterConfig` remains unchanged.

The Kubernetes guidance must say that a StatefulSet pod name or ordinal is
stable across replacement, while an ordinary Deployment pod name is not. It
must explain the consequences of both duplicate and changing identifiers, the
availability tradeoff of a longer session timeout, and the remaining pause for
the restarted member's own partitions.

Finally, `cabal build all`, the entire adapter test suite, the benchmark smoke
run, `nix flake check`, and `just capabilities` must succeed from a clean
released dependency solution. Passing only with a local source override does
not satisfy the plan.


## Idempotence and Recovery

The documentation, source edits, builds, formatting, and test commands are safe
to repeat. Integration tests must generate random topic and group names, so a
failed static member from an earlier run cannot collide with a later run. Each
test must close consumers with brackets and use a short test-only session
timeout. If a test process is killed before cleanup, wait for that timeout or
rerun with a new random group instead of deleting shared broker state.

Publishing a dependency release is not idempotent. Before choosing a version or
tag, re-read the authoritative package registry and upstream tags. If the
desired version already exists, inspect its source and use it rather than
republishing. If a release attempt partially succeeds, determine whether the
registry artifact or Git tag is authoritative before retrying; never move or
overwrite a public tag.

Do not add a permanent sibling `packages:` entry or leave a source override in
`cabal.project.local` as a recovery shortcut. A temporary override may be used
to develop Milestones 2 and 3 before the dependency release, but keep it
uncommitted and remove it before final validation. Preserve unrelated changes
in every working tree and do not reset or overwrite them.

If the restart test proves that the selected broker or librdkafka version does
rebalance despite correct static identifiers, capture callback logs with
`debug=cgrp` and record the broker, librdkafka, and client versions in
Surprises & Discoveries before changing the design. If Kubernetes Deployment
identity is required instead of StatefulSet identity, stop and split stable
slot allocation into a separate design; do not derive a shared identifier from
the Deployment name.


## Interfaces and Dependencies

The low-level interface belongs to
`mori://shinzui/hw-kafka-client/packages/hw-kafka-client`. At the end of
Milestone 1, its public consumer modules must expose an instance-identifier type
consistent with the existing `ConsumerGroupId` style and a property builder:

    newtype GroupInstanceId = GroupInstanceId
        { unGroupInstanceId :: Text
        }

    groupInstanceId :: GroupInstanceId -> ConsumerProperties

`groupInstanceId (GroupInstanceId value)` must be equivalent to
`extraProp "group.instance.id" value`. Its documentation must require a
non-empty identifier unique among live consumers in the same group. If the
constructor remains public for consistency with `ConsumerGroupId`, validation
continues to occur when librdkafka constructs the consumer; examples and
environment parsing must reject empty input earlier for a clearer message.

`pollMessage` and `pollMessageBatch` must return
`KafkaResponseError RdKafkaRespErrFatal` promptly whenever librdkafka reports a
fatal client state. The optional diagnostic function from the existing fork,

    consumerFatalError ::
        MonadIO m =>
        KafkaConsumer ->
        m (Maybe (KafkaError, Text))

must remain available so callers can recover the underlying fenced-instance
cause for logs and alerts.

`mori://shinzui/kafka-effectful/packages/kafka-effectful` must re-export
`GroupInstanceId`, `groupInstanceId`, and the existing `extraProp` through
`Kafka.Effectful.Consumer`. Its `runKafkaConsumer` signature remains unchanged:

    runKafkaConsumer ::
        (IOE :> es, Error KafkaError :> es) =>
        ConsumerProperties ->
        Subscription ->
        Eff (KafkaConsumer : es) a ->
        Eff es a

`shibuya-kafka-adapter` consumes these interfaces but does not add static
membership to `KafkaAdapterConfig`. The public adapter signatures remain
unchanged. The new example reads configuration from the process environment and
builds `ConsumerProperties` before entering `runKafkaConsumer`.

The live service dependency is the shared Redpanda broker at
`127.0.0.1:9092`. Redpanda implements the Kafka group protocol needed by the
tests. The native client is librdkafka; verify its installed version with
`pkg-config --modversion rdkafka` and record it with test results because static
membership and fatal-state behavior cross the Haskell/native boundary. Kafka
brokers must support static membership, which requires Kafka protocol support
equivalent to broker version 2.3 or later.

The deployment interface is an environment variable rather than a library
default. `KAFKA_GROUP_INSTANCE_ID` carries the stable identifier and
`KAFKA_SESSION_TIMEOUT_MS` carries an optional positive integer timeout. In a
Kubernetes StatefulSet, use the Downward API to populate the identifier from
the pod's stable metadata name. No secret material belongs in either variable.
