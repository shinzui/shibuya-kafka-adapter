---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Running Redpanda broker does not answer published host ports](1-running-redpanda-broker-does-not-answer-published-host-ports.md) - The shared container reports running and answers internal metadata while host-side Kafka requests time out, preventing live acceptance.
- [Producer cleanup outlives the live fixture timeout when broker metadata stalls](2-producer-cleanup-outlives-the-live-fixture-timeout-when-broker-metadata-stalls.md) - An unavailable broker leaves producer cleanup in native code beyond the test timeout, requiring a process watchdog and bounded message expiration.
- [Default private Redpanda port block is already occupied](3-default-private-redpanda-port-block-is-already-occupied.md) - Enabling nix.redpanda used a host port block already bound by another container, so project-specific ports were required.

