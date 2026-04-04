let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/8415b4b8a746a84eecf982f0f1d7194368bf7b54/package.dhall
        sha256:d19ae156d6c357d982a1aea0f1b6ba1f01d76d2d848545b150db75ed4c39a8a9

let emptyRuntime = { deployable = False, exposesApi = False }

let emptyDeps = [] : List Schema.Dependency

let emptyDocs = [] : List Schema.DocRef

let emptyConfig = [] : List Schema.ConfigItem

in  { project =
      { name = "shibuya-kafka-adapter"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , description = Some
          "Kafka adapter for the Shibuya queue processing framework"
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Active
      , domains = [ "concurrency", "queue-processing", "kafka" ]
      , owners = [ "shinzui" ]
      , origin = Schema.Origin.Own
      }
    , repos =
      [ { name = "shibuya-kafka-adapter"
        , github = Some "shinzui/shibuya-kafka-adapter"
        , gitlab = None Text
        , git = None Text
        , localPath = Some "."
        }
      ]
    , packages =
      [ { name = "shibuya-kafka-adapter"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-kafka-adapter"
        , description = Some
            "Kafka adapter with polling, offset commit semantics, partition awareness, and graceful shutdown"
        , lifecycle = None Schema.Lifecycle
        , visibility = Schema.Visibility.Public
        , runtime = emptyRuntime
        , runtimeEnvironment = None Schema.RuntimeEnvironment
        , dependencies =
          [ Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "shinzui/kafka-effectful"
          , Schema.Dependency.ByName "haskell-works/hw-kafka-client"
          , Schema.Dependency.ByName "shinzui/shibuya"
          , Schema.Dependency.ByName "composewell/streamly"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        , apiSource = None Schema.ApiSource
        }
      , { name = "shibuya-kafka-adapter-bench"
        , type = Schema.PackageType.Other "Benchmark"
        , language = Schema.Language.Haskell
        , path = Some "shibuya-kafka-adapter-bench"
        , description = Some
            "Micro-benchmarks for conversion hot path: ConsumerRecord to Envelope, W3C header extraction, timestamps"
        , lifecycle = None Schema.Lifecycle
        , visibility = Schema.Visibility.Internal
        , runtime = emptyRuntime
        , runtimeEnvironment = None Schema.RuntimeEnvironment
        , dependencies =
          [ Schema.Dependency.ByName "Bodigrim/tasty-bench"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        , apiSource = None Schema.ApiSource
        }
      , { name = "shibuya-kafka-adapter-jitsurei"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "shibuya-kafka-adapter-jitsurei"
        , description = Some
            "Runnable examples: basic consumer, multi-topic, offset management, multi-partition"
        , lifecycle = None Schema.Lifecycle
        , visibility = Schema.Visibility.Internal
        , runtime = { deployable = True, exposesApi = False }
        , runtimeEnvironment = None Schema.RuntimeEnvironment
        , dependencies = emptyDeps
        , docs = emptyDocs
        , config = emptyConfig
        , apiSource = None Schema.ApiSource
        }
      ]
    , bundles = [] : List Schema.PackageBundle
    , dependencies =
      [ "shinzui/shibuya"
      , "effectful/effectful"
      , "composewell/streamly"
      , "shinzui/kafka-effectful"
      , "haskell-works/hw-kafka-client"
      , "confluentinc/librdkafka"
      , "Bodigrim/tasty-bench"
      , "iand675/hs-opentelemetry"
      ]
    , apis = [] : List Schema.Api
    , agents =
      [ { role = "adapter-dev"
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
      , { role = "bench-dev"
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
      , { role = "examples-dev"
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
    , skills = [] : List Schema.Skill
    , subagents = [] : List Schema.Subagent
    , standards = [] : List Text
    , docs =
      [ { key = "plans"
        , kind = Schema.DocKind.Reference
        , audience = Schema.DocAudience.Internal
        , description = Some "Execution plans for adapter development"
        , location = Schema.DocLocation.LocalDir "docs/plans"
        }
      ]
    }
