# Bundle Update Log

## 2026-10-26
* **Update**: FRIC-3 resolved: Project-local broker starts and answers both Admin and Kafka probes on the configured ports.
* **Update**: FRIC-2 accepted: Accept the native cleanup limitation with explicit broker preflight and bounded failure handling.
* **Update**: FRIC-1 accepted: Project-private Redpanda restores live validation without altering shared services.
* **Addition**: FRIC-3 records detour environment friction with mori://shinzui/seihou-modules/templates/nix-haskell-flake: Default private Redpanda port block is already occupied
* **Addition**: FRIC-2 records detour interface friction with mori://haskell-works/hw-kafka-client: Producer cleanup outlives the live fixture timeout when broker metadata stalls
* **Addition**: FRIC-1 records blocked environment friction with https://github.com/apple/container: Running Redpanda broker does not answer published host ports
* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
