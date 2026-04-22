let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/02a8a876f6f7074510eb03071116d57f5529378b/package.dhall
        sha256:a19f5dd9181db28ba7a6a1b77b5ab8715e81aba3e2a8f296f40973003a0b4412

let Cookbook =
      https://raw.githubusercontent.com/shinzui/mori-schema/02a8a876f6f7074510eb03071116d57f5529378b/extensions/cookbook/package.dhall
        sha256:ebad17941153398677bb37b4f7913db1b2186664c92999e10934b94dbd6db66f

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
