-- | Configuration types for the Kafka adapter.
module Shibuya.Adapter.Kafka.Config (
    -- * Main Configuration
    KafkaAdapterConfig (..),

    -- * Defaults
    defaultConfig,
)
where

import GHC.Generics (Generic)
import Kafka.Consumer.Types (OffsetReset (..))
import Kafka.Types (BatchSize (..), Timeout (..), TopicName)

{- | Configuration for the Kafka adapter.

Consumer properties (brokers, group ID, etc.) are provided when running
@runKafkaConsumer@ — the adapter operates /within/ the @KafkaConsumer@
effect scope, not outside it.
-}
data KafkaAdapterConfig = KafkaAdapterConfig
    { topics :: ![TopicName]
    -- ^ Topics to consume from
    , pollTimeout :: !Timeout
    -- ^ Timeout for each poll call (default: 1000ms)
    , batchSize :: !BatchSize
    -- ^ Maximum messages per poll batch (default: 100)
    , offsetReset :: !OffsetReset
    -- ^ Where to start when no committed offset exists (default: Earliest)
    }
    deriving stock (Show, Eq, Generic)

{- | Default adapter configuration for the given topics.

Defaults:

* @pollTimeout@: 1000ms
* @batchSize@: 100
* @offsetReset@: Earliest
-}
defaultConfig :: [TopicName] -> KafkaAdapterConfig
defaultConfig ts =
    KafkaAdapterConfig
        { topics = ts
        , pollTimeout = Timeout 1000
        , batchSize = BatchSize 100
        , offsetReset = Earliest
        }
