{- | Unit tests for 'Shibuya.Adapter.Kafka.Tracing.traced'.

Drives the 'traced' stream transformer over a single synthetic 'Ingested',
captures the resulting OTel span with an in-memory 'SpanProcessor', and
asserts span shape: trace parenting, attribute set, and that the original
'AckDecision' still flows through the wrapped 'AckHandle.finalize'.

No Kafka broker is required. The processor implementation mirrors
@OpenTelemetry.Exporter.InMemory.Span.inMemoryListExporter@ from
hs-opentelemetry-exporter-in-memory; the latter is not used directly
because its current Hackage release pins @hs-opentelemetry-api <0.3@,
while this repository resolves to 0.3.1.0.
-}
module Shibuya.Adapter.Kafka.TracingTest (tests) where

import Control.Concurrent.Async (async)
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Kafka.Types (TopicName (..))
import OpenTelemetry.Attributes (Attribute (..), PrimitiveAttribute (..), lookupAttribute, unkey)
import OpenTelemetry.Processor.Span (ShutdownResult (..), SpanProcessor (..))
import OpenTelemetry.SemanticConventions qualified as Sem
import OpenTelemetry.Trace.Core (
    ImmutableSpan (..),
    SpanContext (..),
    Tracer,
    createTracerProvider,
    emptyTracerProviderOptions,
    getSpanContext,
    makeTracer,
    shutdownTracerProvider,
    tracerOptions,
 )
import OpenTelemetry.Trace.Id (Base (..), spanIdBaseEncodedText, traceIdBaseEncodedText)
import Shibuya.Adapter.Kafka.Tracing (traced)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..), TraceHeaders)
import Shibuya.Telemetry.Effect (runTracing)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
    testGroup
        "Tracing"
        [ testCase "envelope traceparent becomes span parent" testParentedSpan
        , testCase "missing traceContext yields root span" testRootSpan
        , testCase "messaging attributes populated from envelope" testAttributes
        , testCase "span name follows spec pattern" testSpanName
        , testCase "AckDecision threads through wrapped finalize" testAckPassthrough
        ]

-- | SpanProcessor that records ended spans to an IORef.
recordingProcessor :: IO (SpanProcessor, IORef [ImmutableSpan])
recordingProcessor = do
    ref <- newIORef []
    let processor =
            SpanProcessor
                { spanProcessorOnStart = \_ _ -> pure ()
                , spanProcessorOnEnd = \spanRef -> do
                    s <- readIORef spanRef
                    atomicModifyIORef ref (\l -> (s : l, ()))
                , spanProcessorShutdown = async (pure ShutdownSuccess)
                , spanProcessorForceFlush = pure ()
                }
    pure (processor, ref)

withRecordingTracer :: (IORef [ImmutableSpan] -> Tracer -> IO a) -> IO a
withRecordingTracer k = do
    (processor, spansRef) <- recordingProcessor
    bracket
        (createTracerProvider [processor] emptyTracerProviderOptions)
        shutdownTracerProvider
        $ \tp ->
            k spansRef (makeTracer tp "shibuya-kafka-adapter-test" tracerOptions)

-- Known-good W3C traceparent with recoverable trace and span ids.
expectedTraceIdHex :: Text
expectedTraceIdHex = "0af7651916cd43dd8448eb211c80319c"

expectedSpanIdHex :: Text
expectedSpanIdHex = "b7ad6b7169203331"

sampleTraceparent :: ByteString
sampleTraceparent =
    TE.encodeUtf8 ("00-" <> expectedTraceIdHex <> "-" <> expectedSpanIdHex <> "-01")

mkEnvelope :: Maybe TraceHeaders -> Envelope ()
mkEnvelope tc =
    Envelope
        { messageId = MessageId "orders-2-42"
        , cursor = Just (CursorInt 42)
        , partition = Just "2"
        , enqueuedAt = Nothing
        , traceContext = tc
        , attempt = Nothing
        , payload = ()
        }

mkIngestedFor ::
    (IOE :> es) =>
    IORef (Maybe AckDecision) ->
    Envelope () ->
    Ingested es ()
mkIngestedFor ackRef env =
    Ingested
        { envelope = env
        , ack = AckHandle $ \decision -> liftIO $ writeIORef ackRef (Just decision)
        , lease = Nothing
        }

-- | Drive 'traced' over a single envelope, calling finalize with 'AckOk'.
runOneThroughTraced ::
    Tracer ->
    Envelope () ->
    IORef (Maybe AckDecision) ->
    IO ()
runOneThroughTraced tracer env ackRef = runEff . runTracing tracer $ do
    let ing = mkIngestedFor ackRef env
    Stream.fold Fold.drain $
        Stream.mapM callFinalize $
            traced (TopicName "orders") $
                Stream.fromList [ing]
  where
    callFinalize :: Ingested es () -> Eff es ()
    callFinalize i =
        let AckHandle fin = i.ack
         in fin AckOk

testParentedSpan :: Assertion
testParentedSpan = withRecordingTracer $ \spansRef tracer -> do
    ackRef <- newIORef Nothing
    runOneThroughTraced tracer (mkEnvelope (Just [("traceparent", sampleTraceparent)])) ackRef
    spans <- readIORef spansRef
    case spans of
        [s] -> do
            assertEqual
                "span traceId matches parent"
                expectedTraceIdHex
                (traceIdBaseEncodedText Base16 s.spanContext.traceId)
            case s.spanParent of
                Just parentSpan -> do
                    parentCtx <- getSpanContext parentSpan
                    assertEqual
                        "parent traceId"
                        expectedTraceIdHex
                        (traceIdBaseEncodedText Base16 parentCtx.traceId)
                    assertEqual
                        "parent spanId"
                        expectedSpanIdHex
                        (spanIdBaseEncodedText Base16 parentCtx.spanId)
                Nothing -> assertFailure "expected spanParent to be set"
        other -> assertFailure ("expected exactly one span, got " <> show (length other))

testRootSpan :: Assertion
testRootSpan = withRecordingTracer $ \spansRef tracer -> do
    ackRef <- newIORef Nothing
    runOneThroughTraced tracer (mkEnvelope Nothing) ackRef
    spans <- readIORef spansRef
    case spans of
        [s] -> case s.spanParent of
            Nothing -> pure ()
            Just _ -> assertFailure "expected root span to have no parent"
        other -> assertFailure ("expected exactly one span, got " <> show (length other))

testAttributes :: Assertion
testAttributes = withRecordingTracer $ \spansRef tracer -> do
    ackRef <- newIORef Nothing
    runOneThroughTraced tracer (mkEnvelope (Just [("traceparent", sampleTraceparent)])) ackRef
    spans <- readIORef spansRef
    case spans of
        [s] -> do
            let attrs = s.spanAttributes
            -- Generic messaging.* attributes.
            assertEqual
                "messaging.system"
                (Just (AttributeValue (TextAttribute "kafka")))
                (lookupAttribute attrs "messaging.system")
            assertEqual
                "messaging.destination.name"
                (Just (AttributeValue (TextAttribute "orders")))
                (lookupAttribute attrs "messaging.destination.name")
            assertEqual
                "messaging.operation"
                (Just (AttributeValue (TextAttribute "process")))
                (lookupAttribute attrs "messaging.operation")
            assertEqual
                "messaging.message.id"
                (Just (AttributeValue (TextAttribute "orders-2-42")))
                (lookupAttribute attrs "messaging.message.id")
            -- Kafka-specific typed attributes (Int64 on the wire).
            assertEqual
                "messaging.kafka.destination.partition"
                (Just (AttributeValue (IntAttribute 2)))
                (lookupAttribute attrs (unkey Sem.messaging_kafka_destination_partition))
            assertEqual
                "messaging.kafka.message.offset"
                (Just (AttributeValue (IntAttribute 42)))
                (lookupAttribute attrs (unkey Sem.messaging_kafka_message_offset))
            -- The deleted pre-alignment key must NOT be present.
            assertEqual
                "messaging.destination.partition.id absent"
                Nothing
                (lookupAttribute attrs "messaging.destination.partition.id")
        other -> assertFailure ("expected exactly one span, got " <> show (length other))

testSpanName :: Assertion
testSpanName = withRecordingTracer $ \spansRef tracer -> do
    ackRef <- newIORef Nothing
    runOneThroughTraced tracer (mkEnvelope Nothing) ackRef
    spans <- readIORef spansRef
    case spans of
        [s] -> assertEqual "span name" "orders process" s.spanName
        other -> assertFailure ("expected exactly one span, got " <> show (length other))

testAckPassthrough :: Assertion
testAckPassthrough = withRecordingTracer $ \_ tracer -> do
    ackRef <- newIORef Nothing
    runOneThroughTraced tracer (mkEnvelope Nothing) ackRef
    decision <- readIORef ackRef
    assertEqual "underlying finalize received the decision" (Just AckOk) decision
