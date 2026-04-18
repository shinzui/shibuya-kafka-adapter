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

# Open the Jaeger UI in the default browser (jaeger is started by `process-up`)
[group("services")]
jaeger-ui:
    open http://localhost:16686

# Tail jaeger logs (process-compose combined stream)
[group("services")]
jaeger-logs:
    process-compose --unix-socket .dev/process-compose.sock process logs jaeger -f


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
