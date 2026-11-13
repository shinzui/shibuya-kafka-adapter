-- | Configuration types for the Kafka adapter.
module Shibuya.Adapter.Kafka.Config
  ( -- * Main Configuration
    KafkaAdapterConfig (..),

    -- * Defaults
    defaultConfig,
  )
where

import GHC.Generics (Generic)
import Kafka.Types (BatchSize (..), Timeout (..), TopicName)
import Shibuya.Adapter (AdapterTelemetry, defaultAdapterTelemetry)

-- | Configuration for the Kafka adapter.
--
-- Consumer properties (brokers, group ID, etc.) are provided when running
-- @runKafkaConsumer@ — the adapter operates /within/ the @KafkaConsumer@
-- effect scope, not outside it.
data KafkaAdapterConfig = KafkaAdapterConfig
  { -- | Topics expected by the adapter, used for observability metadata and
    --     checked against the live consumer subscription at construction. The
    --     actual subscription, including offset-reset policy, is supplied to
    --     @runKafkaConsumer@ by the caller.
    topics :: ![TopicName],
    -- | Timeout for each poll call (default: 1000ms)
    pollTimeout :: !Timeout,
    -- | Maximum messages per poll batch (default: 100)
    batchSize :: !BatchSize,
    -- | Telemetry options copied unchanged into the 'Shibuya.Adapter.Adapter'.
    --
    -- The default is 'defaultAdapterTelemetry', whose @traceCorrelation@ is
    -- 'Shibuya.Adapter.ParentAndLink': each record's processing span is a
    -- child of the producer's span and also links to it, giving one connected
    -- trace. Choose 'Shibuya.Adapter.LinkOnly' with
    -- @defaultAdapterTelemetry {traceCorrelation = LinkOnly}@ when records are
    -- replayed from old offsets, when the consumer runs with sustained lag, or
    -- when many consumer groups read the same topic: each record's processing
    -- then starts its own trace, related to the producer only by the link.
    telemetry :: !AdapterTelemetry
  }
  deriving stock (Show, Eq, Generic)

-- | Default adapter configuration for the given topics.
--
-- Defaults:
--
-- * @pollTimeout@: 1000ms
-- * @batchSize@: 100
-- * @telemetry@: 'defaultAdapterTelemetry' (@traceCorrelation = ParentAndLink@)
defaultConfig :: [TopicName] -> KafkaAdapterConfig
defaultConfig ts =
  KafkaAdapterConfig
    { topics = ts,
      pollTimeout = Timeout 1000,
      batchSize = BatchSize 100,
      telemetry = defaultAdapterTelemetry
    }
