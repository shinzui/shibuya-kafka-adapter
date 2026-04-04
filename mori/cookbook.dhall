let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/8415b4b8a746a84eecf982f0f1d7194368bf7b54/package.dhall
        sha256:d19ae156d6c357d982a1aea0f1b6ba1f01d76d2d848545b150db75ed4c39a8a9

let ContentType =
      https://raw.githubusercontent.com/shinzui/mori-schema/8415b4b8a746a84eecf982f0f1d7194368bf7b54/extensions/cookbook/ContentType.dhall
        sha256:113d783ba6a6c6f2dd852075cc3ba3b2b5f75eccf0f85ef4ea219ff2b04b0d7a

let Topic =
      https://raw.githubusercontent.com/shinzui/mori-schema/8415b4b8a746a84eecf982f0f1d7194368bf7b54/extensions/cookbook/Topic.dhall
        sha256:1292c3f57141c6805272bbd0a168797a41f069bd069b887b864e3a4856dd0300

in  { entries =
      [ { key = "basic-consumer"
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
      , { key = "multi-topic"
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
      , { key = "offset-management"
        , title = "Verify offset commit and restart semantics"
        , contentType = ContentType.SampleCode
        , topics = [ Topic.Streaming, Topic.Testing ]
        , packages =
          [ "shibuya-kafka-adapter", "kafka-effectful", "streamly" ]
        , language = Schema.Language.Haskell
        , audience = Schema.DocAudience.User
        , location =
            Schema.DocLocation.LocalFile
              "shibuya-kafka-adapter-jitsurei/app/OffsetManagement.hs"
        , description = Some
            "Produce, consume with AckOk, restart in same group, verify no re-delivery"
        }
      , { key = "multi-partition"
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
      , { key = "conversion-benchmarks"
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
      , { key = "integration-test-pattern"
        , title = "Integration testing with Redpanda and test helpers"
        , contentType = ContentType.Pattern
        , topics = [ Topic.Testing, Topic.Streaming ]
        , packages =
          [ "shibuya-kafka-adapter", "kafka-effectful", "tasty" ]
        , language = Schema.Language.Haskell
        , audience = Schema.DocAudience.Module
        , location =
            Schema.DocLocation.LocalFile
              "shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs"
        , description = Some
            "Reusable test pattern: produce-consume roundtrips, offset commit verification, multi-partition, graceful shutdown"
        }
      , { key = "redpanda-dev-env"
        , title = "Local Redpanda dev environment with process-compose"
        , contentType = ContentType.Configuration
        , topics = [ Topic.Other "DevEnvironment", Topic.Streaming ]
        , packages = [ "shibuya-kafka-adapter" ]
        , language = Schema.Language.Other "YAML"
        , audience = Schema.DocAudience.Module
        , location =
            Schema.DocLocation.LocalFile "process-compose.yaml"
        , description = Some
            "Single-node Redpanda via rpk container with readiness probe and auto-purge on shutdown"
        }
      ]
    }
