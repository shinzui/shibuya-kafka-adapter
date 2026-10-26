# Justfile for shibuya-kafka-adapter

# Default recipe to display help
default:
    @just --list


# --- Services ---

# Start development services via process-compose (Ctrl-C to stop)
[group("services")]
process-up:
    process-compose --tui=false --unix-socket .dev/process-compose.sock up

# Stop Redpanda
[group("services")]
process-down:
    process-compose --unix-socket .dev/process-compose.sock down || true

# Open the Jaeger UI in the default browser (jaeger is started by `process-up`)
[group("services")]
jaeger-ui:
    open http://localhost:16686

# Tail jaeger logs (process-compose combined stream)
[group("services")]
jaeger-logs:
    process-compose --unix-socket .dev/process-compose.sock process logs jaeger -f


# Start this project's private Redpanda cluster (Apple Silicon macOS)
[group("services")]
redpanda-up:
    redpanda-local-up

# Stop this project's private broker, preserving its data
[group("services")]
redpanda-down:
    redpanda-local-down

# Inspect this project's private broker
[group("services")]
redpanda-status:
    redpanda-local-status

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

# Run the library test suite (start the broker with just redpanda-up)
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


# --- Docs ---

# Validate the capability catalog (profile-enforced) and its concept graph
[group("docs")]
capabilities:
    mori validate
    okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
    okf graph docs/capabilities
