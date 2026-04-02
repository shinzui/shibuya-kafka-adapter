-- | Configuration types for the Kafka adapter.
module Shibuya.Adapter.Kafka.Config (
    -- * Main Configuration
    KafkaAdapterConfig (..),

    -- * Defaults
    defaultConfig,
)
where

-- | Configuration for the Kafka adapter.
data KafkaAdapterConfig = KafkaAdapterConfig
    deriving stock (Show, Eq)

-- | Default adapter configuration for the given topics.
defaultConfig :: KafkaAdapterConfig
defaultConfig = KafkaAdapterConfig
