{- | Opt-in per-message tracing for the Shibuya Kafka adapter.

Exposes a single stream transformer, 'traced', that wraps each 'Ingested'
emitted by 'Shibuya.Adapter.Kafka.kafkaAdapter' so that when a downstream
handler eventually calls the envelope's 'AckHandle.finalize', the call is
enclosed in an OpenTelemetry Consumer-kind span following the messaging
semantic-conventions span-name pattern @"<destination> <operation>"@,
e.g. @"orders process"@ for a topic named @orders@ (see
'Shibuya.Telemetry.Semantic.processSpanName').

The span:

* Is a child of the W3C trace context carried on the envelope, when present.
  The parent is recovered via 'Shibuya.Telemetry.Propagation.extractTraceContext'
  from @envelope.traceContext@. When absent, the span is a fresh root span.
* Carries the spec-aligned messaging attributes @messaging.system=kafka@,
  @messaging.destination.name@, @messaging.operation=process@, and
  @messaging.message.id@.
* Carries the Kafka-specific typed attributes
  @messaging.kafka.destination.partition@ (Int64, from @envelope.partition@
  parsed as an integer) and @messaging.kafka.message.offset@ (Int64, from
  @envelope.cursor@ when it is a 'CursorInt'). If the partition text fails
  to parse as an integer, the shibuya-namespaced @shibuya.partition@ is
  emitted as a defensive fallback.

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

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Read qualified as TR
import Effectful (Eff, IOE, (:>))
import Kafka.Types (TopicName (..))
import OpenTelemetry.Attributes (unkey)
import OpenTelemetry.SemanticConventions qualified as Sem
import OpenTelemetry.Trace.Core (Span)
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Telemetry.Effect (
    Tracing,
    addAttribute,
    withExtractedContext,
    withSpan',
 )
import Shibuya.Telemetry.Propagation (extractTraceContext)
import Shibuya.Telemetry.Semantic (
    attrMessagingDestinationName,
    attrMessagingMessageId,
    attrMessagingOperation,
    attrMessagingSystem,
    attrShibuyaPartition,
    consumerSpanArgs,
    processSpanName,
 )
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

{- | Rewrite each 'Ingested' so that its 'AckHandle.finalize' opens a
Consumer-kind span parented on the envelope's carried trace context
(when any), named @"<topic> process"@ per
'Shibuya.Telemetry.Semantic.processSpanName', and populated with the
spec-aligned messaging attributes plus the Kafka-specific
@messaging.kafka.*@ attributes.

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
                    withSpan' (processSpanName topicName) consumerSpanArgs $
                        \sp -> do
                            populateAttrs sp topicName envelope
                            finalize decision
        pure ing{ack = AckHandle wrappedFinalize}

{- | Set the spec-aligned messaging attribute set on a span, plus the
Kafka-specific typed attributes when the envelope carries them.
-}
populateAttrs ::
    (Tracing :> es, IOE :> es) =>
    Span ->
    Text ->
    Envelope v ->
    Eff es ()
populateAttrs sp topicName envelope = do
    -- Generic messaging.* attributes (wire-names from shibuya-core's
    -- aligned Semantic module, which derives them from typed AttributeKeys).
    addAttribute sp attrMessagingSystem ("kafka" :: Text)
    addAttribute sp attrMessagingDestinationName topicName
    addAttribute sp attrMessagingOperation ("process" :: Text)
    let MessageId msgIdText = envelope.messageId
    addAttribute sp attrMessagingMessageId msgIdText

    -- Kafka-specific typed attributes (wire-names from AttributeKey
    -- values in OpenTelemetry.SemanticConventions).
    case envelope.partition of
        Just p -> case TR.decimal p of
            Right (n :: Int64, "") ->
                addAttribute sp (unkey Sem.messaging_kafka_destination_partition) n
            _ ->
                -- Defensive: the partition text didn't parse as an int.
                -- Emit the shibuya-namespaced fallback so the information
                -- is not lost.
                addAttribute sp attrShibuyaPartition p
        Nothing -> pure ()
    case envelope.cursor of
        Just (CursorInt off) ->
            addAttribute
                sp
                (unkey Sem.messaging_kafka_message_offset)
                (fromIntegral off :: Int64)
        _ -> pure ()
