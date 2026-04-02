-- | Kafka adapter for the Shibuya queue processing framework.
module Shibuya.Adapter.Kafka (
    -- * Adapter
    kafkaAdapter,

    -- * Configuration
    KafkaAdapterConfig (..),

    -- * Defaults
    defaultConfig,
)
where

import Shibuya.Adapter.Kafka.Config (KafkaAdapterConfig (..), defaultConfig)

{- | Create a Kafka adapter with the given configuration.

The adapter operates within an existing 'KafkaConsumer' effect scope.
Consumer lifecycle (connection, group membership) is managed by
@runKafkaConsumer@ from kafka-effectful.
-}
kafkaAdapter :: ()
kafkaAdapter = ()
