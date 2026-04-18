{- | Opt-in per-message tracing for the Shibuya Kafka adapter.

Exposes a single stream transformer, 'traced', that wraps each 'Ingested'
emitted by 'Shibuya.Adapter.Kafka.kafkaAdapter' so that when a downstream
handler eventually calls the envelope's 'AckHandle.finalize', the call is
enclosed in an OpenTelemetry Consumer-kind span named
@shibuya.process.message@ (see 'Shibuya.Telemetry.Semantic.processMessageSpanName').

The span:

* Is a child of the W3C trace context carried on the envelope, when present.
  The parent is recovered via 'Shibuya.Telemetry.Propagation.extractTraceContext'
  from @envelope.traceContext@. When absent, the span is a fresh root span.
* Carries the v1.27 messaging-conventions attribute set:
  @messaging.system@, @messaging.destination.name@, @messaging.message.id@,
  and — when a partition is known — @messaging.destination.partition.id@.

Typical usage:

@
Adapter{source} <- kafkaAdapter (defaultConfig [TopicName \"orders\"])
Stream.fold Fold.drain
    $ Stream.mapM userHandler
    $ traced (TopicName \"orders\") source
@

A caller that does not import this module pays nothing: the adapter's public
surface is unchanged and no span is opened.
-}
module Shibuya.Adapter.Kafka.Tracing (
    traced,
)
where

import Data.Text (Text)
import Effectful (Eff, IOE, (:>))
import Kafka.Types (TopicName (..))
import OpenTelemetry.Trace.Core (Span)
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Telemetry.Effect (
    Tracing,
    addAttribute,
    withExtractedContext,
    withSpan',
 )
import Shibuya.Telemetry.Propagation (extractTraceContext)
import Shibuya.Telemetry.Semantic (
    attrMessagingDestinationName,
    attrMessagingDestinationPartitionId,
    attrMessagingMessageId,
    attrMessagingSystem,
    consumerSpanArgs,
    processMessageSpanName,
 )
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

{- | Rewrite each 'Ingested' so that its 'AckHandle.finalize' opens a
Consumer-kind span parented on the envelope's carried trace context
(when any) and populated with the v1.27 messaging attributes.

The topic name is supplied by the caller rather than parsed from the
envelope's 'MessageId' — see the Decision Log of
@docs/plans/9-add-shibuya-kafka-tracing-module.md@ for the rationale.
-}
traced ::
    forall es v.
    (Tracing :> es, IOE :> es) =>
    TopicName ->
    Stream (Eff es) (Ingested es v) ->
    Stream (Eff es) (Ingested es v)
traced (TopicName topicName) =
    Stream.mapM $ \ing -> do
        let envelope = ing.envelope
            AckHandle finalize = ing.ack
            parentCtx = envelope.traceContext >>= extractTraceContext
            wrappedFinalize decision =
                withExtractedContext parentCtx $
                    withSpan' processMessageSpanName consumerSpanArgs $
                        \sp -> do
                            populateAttrs sp topicName envelope
                            finalize decision
        pure ing{ack = AckHandle wrappedFinalize}

-- | Set the messaging-conventions v1.27 attribute set on a span.
populateAttrs ::
    (Tracing :> es, IOE :> es) =>
    Span ->
    Text ->
    Envelope v ->
    Eff es ()
populateAttrs sp topicName envelope = do
    addAttribute sp attrMessagingSystem ("kafka" :: Text)
    addAttribute sp attrMessagingDestinationName topicName
    let MessageId msgIdText = envelope.messageId
    addAttribute sp attrMessagingMessageId msgIdText
    case envelope.partition of
        Just p -> addAttribute sp attrMessagingDestinationPartitionId p
        Nothing -> pure ()
