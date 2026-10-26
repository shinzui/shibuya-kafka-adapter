---
type: Friction Entry
title: "Default private Redpanda port block is already occupied"
description: "Enabling nix.redpanda used a host port block already bound by another container, so project-specific ports were required."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-26T23:06:10Z"
frictionId: FRIC-3
status: "resolved"
impact: detour
kind: environment
origin: "mori://shinzui/shibuya-kafka-adapter"
affects: "mori://shinzui/seihou-modules/templates/nix-haskell-flake"
plan: "docs/plans/17-skip-superseded-buffered-deliveries-so-successors-cannot-run-before-a-retried-record.md"
workaround: "Configure the project-private block explicitly: Kafka 29092, Admin 29644, Schema Registry 28081, HTTP Proxy 28082, Console 28080."
resolution: "Persist a noncolliding project port block through nix-haskell-flake settings: Kafka 29092, Admin 29644, Schema Registry 28081, HTTP Proxy 28082, Console 28080."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-26T23:08:40Z"
    change: "Project-local broker starts and answers both Admin and Kafka probes on the configured ports."
---
# Default private Redpanda port block is already occupied

## Attempted

seihou update nix-haskell-flake --var nix.redpanda=true; nix develop -c redpanda-local-up

## Encountered

Apple Container failed broker bootstrap because the configured 39092/39644/38081/38082 host ports were already listening.

```text
bind(descriptor:ptr:bytes:): Address already in use (errno: 48)
```

## Workaround

Configure the project-private block explicitly: Kafka 29092, Admin 29644, Schema Registry 28081, HTTP Proxy 28082, Console 28080.
