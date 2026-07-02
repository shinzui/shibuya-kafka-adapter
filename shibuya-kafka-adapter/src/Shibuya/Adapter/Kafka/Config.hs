-- | Configuration types for the Kafka adapter.
module Shibuya.Adapter.Kafka.Config (
    -- * Main Configuration
    KafkaAdapterConfig (..),

    -- * Defaults
    defaultConfig,
)
where

import GHC.Generics (Generic)
import Kafka.Types (BatchSize (..), Timeout (..), TopicName)

{- | Configuration for the Kafka adapter.

Consumer properties (brokers, group ID, etc.) are provided when running
@runKafkaConsumer@ — the adapter operates /within/ the @KafkaConsumer@
effect scope, not outside it.
-}
data KafkaAdapterConfig = KafkaAdapterConfig
    { topics :: ![TopicName]
    {- ^ Topics expected by the adapter, used for observability metadata and
    checked against the live consumer subscription at construction. The
    actual subscription, including offset-reset policy, is supplied to
    @runKafkaConsumer@ by the caller.
    -}
    , pollTimeout :: !Timeout
    -- ^ Timeout for each poll call (default: 1000ms)
    , batchSize :: !BatchSize
    -- ^ Maximum messages per poll batch (default: 100)
    }
    deriving stock (Show, Eq, Generic)

{- | Default adapter configuration for the given topics.

Defaults:

* @pollTimeout@: 1000ms
* @batchSize@: 100
-}
defaultConfig :: [TopicName] -> KafkaAdapterConfig
defaultConfig ts =
    KafkaAdapterConfig
        { topics = ts
        , pollTimeout = Timeout 1000
        , batchSize = BatchSize 100
        }
