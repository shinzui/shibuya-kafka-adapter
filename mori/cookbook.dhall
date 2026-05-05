let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/1f70781427426c09673d46f8e6733b7e7d0abedc/package.dhall
        sha256:3b79aae9216456678300441ca8616b64a4b4fa520a1286dfcc418f60899d5d4a

let Cookbook =
      https://raw.githubusercontent.com/shinzui/mori-schema/1f70781427426c09673d46f8e6733b7e7d0abedc/extensions/cookbook/package.dhall
        sha256:5d41094fcc37d35ddef48af2e0401764d0ae77f9bd25127a979473b964affbb7

let ContentType = Cookbook.ContentType

let Topic = Cookbook.Topic

in  Cookbook.CookbookCatalog::{
    , entries =
      [ Cookbook.CookbookEntry::{
        , key = "basic-consumer"
        , title = "Minimal single-topic Kafka consumer"
        , contentType = ContentType.SampleCode
        , topics = [ Topic.Streaming ]
        , packages = [ "shibuya-kafka-adapter", "kafka-effectful", "streamly" ]
        , language = Schema.Language.Haskell
        , audience = Schema.DocAudience.User
        , location =
            Schema.DocLocation.LocalFile
              "shibuya-kafka-adapter-jitsurei/app/BasicConsumer.hs"
        , description = Some
            "Simplest adapter wiring: subscribe to one topic, print envelopes, AckOk each message"
        }
      , Cookbook.CookbookEntry::{
        , key = "multi-topic"
        , title = "Consume from multiple topics concurrently"
        , contentType = ContentType.SampleCode
        , topics = [ Topic.Streaming ]
        , packages = [ "shibuya-kafka-adapter", "kafka-effectful", "streamly" ]
        , language = Schema.Language.Haskell
        , audience = Schema.DocAudience.User
        , location =
            Schema.DocLocation.LocalFile
              "shibuya-kafka-adapter-jitsurei/app/MultiTopic.hs"
        , description = Some
            "Two independent adapters under separate consumer groups, each handling a different topic"
        }
      , Cookbook.CookbookEntry::{
        , key = "offset-management"
        , title = "Verify offset commit and restart semantics"
        , contentType = ContentType.SampleCode
        , topics = [ Topic.Streaming, Topic.Testing ]
        , packages = [ "shibuya-kafka-adapter", "kafka-effectful", "streamly" ]
        , language = Schema.Language.Haskell
        , audience = Schema.DocAudience.User
        , location =
            Schema.DocLocation.LocalFile
              "shibuya-kafka-adapter-jitsurei/app/OffsetManagement.hs"
        , description = Some
            "Produce, consume with AckOk, restart in same group, verify no re-delivery"
        }
      , Cookbook.CookbookEntry::{
        , key = "multi-partition"
        , title = "Partition-aware consumption with keyed messages"
        , contentType = ContentType.SampleCode
        , topics = [ Topic.Streaming ]
        , packages = [ "shibuya-kafka-adapter", "kafka-effectful", "streamly" ]
        , language = Schema.Language.Haskell
        , audience = Schema.DocAudience.User
        , location =
            Schema.DocLocation.LocalFile
              "shibuya-kafka-adapter-jitsurei/app/MultiPartition.hs"
        , description = Some
            "Produce keyed messages to a 3-partition topic and observe partition assignment in envelopes"
        }
      , Cookbook.CookbookEntry::{
        , key = "conversion-benchmarks"
        , title = "Benchmark the ConsumerRecord-to-Envelope hot path"
        , contentType = ContentType.SampleCode
        , topics = [ Topic.Performance ]
        , packages =
          [ "shibuya-kafka-adapter", "tasty-bench", "hw-kafka-client" ]
        , language = Schema.Language.Haskell
        , audience = Schema.DocAudience.Module
        , location =
            Schema.DocLocation.LocalFile
              "shibuya-kafka-adapter-bench/bench/Main.hs"
        , description = Some
            "Micro-benchmarks with tasty-bench for envelope conversion, W3C header extraction, and timestamp conversion"
        }
      , Cookbook.CookbookEntry::{
        , key = "integration-test-pattern"
        , title = "Integration testing with Redpanda and test helpers"
        , contentType = ContentType.Pattern
        , topics = [ Topic.Testing, Topic.Streaming ]
        , packages = [ "shibuya-kafka-adapter", "kafka-effectful", "tasty" ]
        , language = Schema.Language.Haskell
        , audience = Schema.DocAudience.Module
        , location =
            Schema.DocLocation.LocalFile
              "shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs"
        , description = Some
            "Reusable test pattern: produce-consume roundtrips, offset commit verification, multi-partition, graceful shutdown"
        }
      , Cookbook.CookbookEntry::{
        , key = "otel-tracing"
        , title = "OpenTelemetry tracing for consumed Kafka messages"
        , contentType = ContentType.SampleCode
        , topics = [ Topic.Observability, Topic.Streaming ]
        , packages =
          [ "shibuya-kafka-adapter", "shibuya", "hs-opentelemetry-sdk" ]
        , language = Schema.Language.Haskell
        , audience = Schema.DocAudience.User
        , location =
            Schema.DocLocation.LocalFile
              "shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs"
        , description = Some
            "Wrap each envelope's AckHandle with Shibuya's traced transformer so handler finalize runs inside a Consumer-kind shibuya.process.message span parented on the carried W3C traceparent"
        }
      , Cookbook.CookbookEntry::{
        , key = "redpanda-dev-env"
        , title = "Local Redpanda dev environment with process-compose"
        , contentType = ContentType.Configuration
        , topics = [ Topic.Other "DevEnvironment", Topic.Streaming ]
        , packages = [ "shibuya-kafka-adapter" ]
        , language = Schema.Language.Other "YAML"
        , audience = Schema.DocAudience.Module
        , location = Schema.DocLocation.LocalFile "process-compose.yaml"
        , description = Some
            "Single-node Redpanda via rpk container with readiness probe and auto-purge on shutdown"
        }
      ]
    }
