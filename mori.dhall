let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/a3c59033a08c2eaef2cfba4a3c99fc9c192ca6d7/package.dhall
        sha256:18258ef583580a897f4af3e7c86db0342afb42fb40efc535b217ba1089230141

let emptyRuntime = { deployable = False, exposesApi = False }

let emptyDeps = [] : List Schema.Dependency

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
          [ Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "shinzui/kafka-effectful"
          , Schema.Dependency.ByName "haskell-works/hw-kafka-client"
          , Schema.Dependency.ByName "shinzui/shibuya"
          , Schema.Dependency.ByName "composewell/streamly"
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
        , dependencies = emptyDeps
        , docs = emptyDocs
        , config = emptyConfig
        }
      ]
    , dependencies =
      [ "shinzui/shibuya"
      , "effectful/effectful"
      , "composewell/streamly"
      , "shinzui/kafka-effectful"
      , "haskell-works/hw-kafka-client"
      , "confluentinc/librdkafka"
      , "Bodigrim/tasty-bench"
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
    }
