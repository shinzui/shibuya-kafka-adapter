let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/3522f4a51181d73c9c90fc27a7c0838bd29ae95f/package.dhall
        sha256:dcb19e2312e790bad14e622cc98a1281cd2298c5b564a2f0d0534d3c718d8803

let emptyRuntime = { deployable = False, exposesApi = False }

let emptyDocs = [] : List Schema.DocRef.Type

let emptyConfig = [] : List Schema.ConfigItem.Type

in  Schema.Project::{ project =
      Schema.ProjectIdentity::{ name = "shibuya-kafka-adapter"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , description = Some
          "Kafka adapter for the Shibuya queue processing framework"
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Active
      , domains = [ "concurrency", "queue-processing", "kafka" ]
      , owners = [ "shinzui" ]
      }
    , repos =
      [ Schema.Repo::{ name = "shibuya-kafka-adapter"
        , github = Some "shinzui/shibuya-kafka-adapter"
        , localPath = Some "."
        }
      ]
    , packages =
      [ Schema.Package::{ name = "shibuya-kafka-adapter"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-kafka-adapter"
        , description = Some
            "Kafka adapter with polling, offset commit semantics, partition awareness, and graceful shutdown"
        , runtime = emptyRuntime
        , dependencies =
          [ Schema.Dependency.ByName "shinzui/shibuya:shibuya-core"
          , Schema.Dependency.ByName "effectful/effectful:effectful-core"
          , Schema.Dependency.ByName "composewell/streamly:streamly"
          , Schema.Dependency.ByName "composewell/streamly:streamly-core"
          , Schema.Dependency.ByName "shinzui/kafka-effectful"
          , Schema.Dependency.ByName
              "haskell-works/hw-kafka-client:hw-kafka-client"
          , Schema.Dependency.ByName
              "shinzui/hw-kafka-streamly:hw-kafka-streamly"
          , Schema.Dependency.ByName
              "iand675/hs-opentelemetry:hs-opentelemetry-api"
          , Schema.Dependency.ByName
              "iand675/hs-opentelemetry:hs-opentelemetry-semantic-conventions"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        }
      , Schema.Package::{ name = "shibuya-kafka-adapter-bench"
        , type = Schema.PackageType.Other "Benchmark"
        , language = Schema.Language.Haskell
        , path = Some "shibuya-kafka-adapter-bench"
        , description = Some
            "Micro-benchmarks for conversion hot path: ConsumerRecord to Envelope, W3C header extraction, timestamps"
        , visibility = Schema.Visibility.Internal
        , runtime = emptyRuntime
        , dependencies =
          [ Schema.Dependency.ByName "Bodigrim/tasty-bench"
          , Schema.Dependency.ByName "shinzui/shibuya:shibuya-core"
          , Schema.Dependency.ByName "composewell/streamly:streamly"
          , Schema.Dependency.ByName "composewell/streamly:streamly-core"
          , Schema.Dependency.ByName
              "haskell-works/hw-kafka-client:hw-kafka-client"
          , Schema.Dependency.ByName
              "shinzui/hw-kafka-streamly:hw-kafka-streamly"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        }
      , Schema.Package::{ name = "shibuya-kafka-adapter-jitsurei"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "shibuya-kafka-adapter-jitsurei"
        , description = Some
            "Runnable examples: basic consumer, multi-topic, offset management, multi-partition"
        , visibility = Schema.Visibility.Internal
        , runtime = { deployable = True, exposesApi = False }
        , dependencies =
          [ Schema.Dependency.ByName "shinzui/shibuya:shibuya-core"
          , Schema.Dependency.ByName "effectful/effectful:effectful-core"
          , Schema.Dependency.ByName "composewell/streamly:streamly"
          , Schema.Dependency.ByName "composewell/streamly:streamly-core"
          , Schema.Dependency.ByName "shinzui/kafka-effectful"
          , Schema.Dependency.ByName
              "haskell-works/hw-kafka-client:hw-kafka-client"
          , Schema.Dependency.ByName
              "iand675/hs-opentelemetry:hs-opentelemetry-api"
          , Schema.Dependency.ByName
              "iand675/hs-opentelemetry:hs-opentelemetry-sdk"
          , Schema.Dependency.ByName
              "iand675/hs-opentelemetry:hs-opentelemetry-exporter-otlp"
          , Schema.Dependency.ByName
              "iand675/hs-opentelemetry:hs-opentelemetry-instrumentation-hw-kafka-client"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        }
      ]
    , dependencies =
      [ "shinzui/shibuya:shibuya-core"
      , "effectful/effectful:effectful-core"
      , "composewell/streamly:streamly"
      , "composewell/streamly:streamly-core"
      , "shinzui/kafka-effectful"
      , "haskell-works/hw-kafka-client:hw-kafka-client"
      , "shinzui/hw-kafka-streamly:hw-kafka-streamly"
      , "confluentinc/librdkafka"
      , "Bodigrim/tasty-bench"
      , "iand675/hs-opentelemetry:hs-opentelemetry-api"
      , "iand675/hs-opentelemetry:hs-opentelemetry-semantic-conventions"
      , "iand675/hs-opentelemetry:hs-opentelemetry-sdk"
      , "iand675/hs-opentelemetry:hs-opentelemetry-exporter-otlp"
      , "iand675/hs-opentelemetry:hs-opentelemetry-instrumentation-hw-kafka-client"
      ]
    , dependencyRefs =
      [ Schema.MoriRef::{ namespace = "shinzui"
        , name = "shibuya"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "shibuya-core"
        }
      , Schema.MoriRef::{ namespace = "effectful"
        , name = "effectful"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "effectful-core"
        }
      , Schema.MoriRef::{ namespace = "composewell"
        , name = "streamly"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "streamly"
        }
      , Schema.MoriRef::{ namespace = "composewell"
        , name = "streamly"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "streamly-core"
        }
      , Schema.MoriRef::{ namespace = "shinzui", name = "kafka-effectful" }
      , Schema.MoriRef::{ namespace = "haskell-works"
        , name = "hw-kafka-client"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hw-kafka-client"
        }
      , Schema.MoriRef::{ namespace = "shinzui"
        , name = "hw-kafka-streamly"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hw-kafka-streamly"
        }
      , Schema.MoriRef::{ namespace = "confluentinc", name = "librdkafka" }
      , Schema.MoriRef::{ namespace = "Bodigrim", name = "tasty-bench" }
      , Schema.MoriRef::{ namespace = "iand675"
        , name = "hs-opentelemetry"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hs-opentelemetry-api"
        }
      , Schema.MoriRef::{ namespace = "iand675"
        , name = "hs-opentelemetry"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hs-opentelemetry-semantic-conventions"
        }
      , Schema.MoriRef::{ namespace = "iand675"
        , name = "hs-opentelemetry"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hs-opentelemetry-sdk"
        }
      , Schema.MoriRef::{ namespace = "iand675"
        , name = "hs-opentelemetry"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hs-opentelemetry-exporter-otlp"
        }
      , Schema.MoriRef::{ namespace = "iand675"
        , name = "hs-opentelemetry"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hs-opentelemetry-instrumentation-hw-kafka-client"
        }
      ]
    , agents =
      [ Schema.AgentHint::{ role = "adapter-dev"
        , description = Some
            "Kafka adapter development: polling, conversion, offset semantics"
        , includePaths =
          [ "shibuya-kafka-adapter/src/**"
          , "shibuya-kafka-adapter/test/**"
          ]
        , excludePaths =
          [ "dist-newstyle/**"
          ]
        , relatedPackages =
          [ "shibuya-kafka-adapter"
          ]
        }
      , Schema.AgentHint::{ role = "bench-dev"
        , description = Some
            "Benchmark development: conversion micro-benchmarks and regression baselines"
        , includePaths =
          [ "shibuya-kafka-adapter-bench/**"
          ]
        , excludePaths =
          [ "dist-newstyle/**"
          ]
        , relatedPackages =
          [ "shibuya-kafka-adapter-bench"
          ]
        }
      , Schema.AgentHint::{ role = "examples-dev"
        , description = Some
            "Jitsurei examples: usage patterns for Kafka adapter"
        , includePaths =
          [ "shibuya-kafka-adapter-jitsurei/**"
          ]
        , excludePaths =
          [ "dist-newstyle/**"
          ]
        , relatedPackages =
          [ "shibuya-kafka-adapter-jitsurei"
          ]
        }
      ]
    , okfBundles =
      [ Schema.OkfBundle::{ name = "capabilities"
        , path = "docs/capabilities"
        , profile = Some "docs/capabilities/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "What shibuya-kafka-adapter provides today, one concept per capability, with evidence"
        }
      ]
    }
