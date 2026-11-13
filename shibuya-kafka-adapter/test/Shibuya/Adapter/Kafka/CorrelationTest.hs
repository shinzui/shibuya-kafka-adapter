-- | Trace correlation of Kafka processing spans, broker-free.
--
-- A scripted single-partition log feeds one record carrying a known producer
-- @traceparent@ through 'kafkaAdapter' and Shibuya's runner, with a tracer
-- that exports into memory. The cases inspect the exported Consumer span:
-- its trace, its parent and its links.
module Shibuya.Adapter.Kafka.CorrelationTest (tests) where

import Control.Exception qualified as Exception
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.Foldable (toList)
import Data.IORef (newIORef, readIORef)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), Timestamp (..))
import Kafka.ScriptedLog (ScriptedLog (..), runScriptedConsumer, scriptedTopic)
import Kafka.Types (BatchSize (..), KafkaError, PartitionId (..), Timeout (..), headersFromList)
import OpenTelemetry.Attributes (emptyAttributes)
import OpenTelemetry.Exporter.InMemory (inMemoryListExporter)
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id (Base (..))
import OpenTelemetry.Trace.Id qualified as OTel.Id
import OpenTelemetry.Trace.Id.Generator (IdGenerator (..))
import OpenTelemetry.Util (appendOnlyBoundedCollectionValues)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka
  ( AdapterTelemetry (traceCorrelation),
    KafkaAdapterConfig (..),
    TraceCorrelation (..),
    defaultAdapterTelemetry,
    defaultConfig,
    kafkaAdapter,
  )
import Shibuya.Adapter.Kafka.SourceGateTest (waitUntil)
import Shibuya.App (ProcessorId (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopApp, stopAppGracefully)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Telemetry.Effect (runTracing, runTracingNoop)
import Shibuya.Telemetry.Semantic (processSpanName)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Trace correlation"
    [ testCase "defaultConfig uses ParentAndLink" $
        assertEqual "default policy" ParentAndLink (defaultConfig [scriptedTopic]).telemetry.traceCorrelation,
      testCase "the adapter exposes a LinkOnly override" $ do
        scripted <- scriptedLog []
        result <-
          runEff . runErrorNoCallStack @KafkaError . runScriptedConsumer scripted . runTracingNoop $ do
            adapter <- kafkaAdapter (configWith linkOnly)
            pure adapter.telemetry.traceCorrelation
        assertEqual "adapter policy" (Right LinkOnly) result,
      testCase "ParentAndLink: process span is a child of the producer with one link" $ do
        [sp] <- processRecord defaultAdapterTelemetry
        assertEqual "span name" (processSpanName processorName) sp.name
        assertEqual "trace" producerTraceHex (hexTrace sp.context)
        assertEqual "parent" (Just producerSpanHex) (hexSpan <$> sp.parent)
        assertEqual "links" [(producerTraceHex, producerSpanHex)] (linkIds sp),
      testCase "LinkOnly: process span is a linked root" $ do
        [sp] <- processRecord linkOnly
        assertBool "new trace" (hexTrace sp.context /= producerTraceHex)
        assertBool "no parent" (isNothing sp.parent)
        assertEqual "links" [(producerTraceHex, producerSpanHex)] (linkIds sp)
    ]

producerParent :: ByteString
producerParent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

producerTraceHex :: Text
producerTraceHex = "0af7651916cd43dd8448eb211c80319c"

producerSpanHex :: Text
producerSpanHex = "b7ad6b7169203331"

processorName :: Text
processorName = "kafka-correlation"

linkOnly :: AdapterTelemetry
linkOnly = defaultAdapterTelemetry {traceCorrelation = LinkOnly}

configWith :: AdapterTelemetry -> KafkaAdapterConfig
configWith telemetry =
  (defaultConfig [scriptedTopic]) {pollTimeout = Timeout 5, batchSize = BatchSize 100, telemetry = telemetry}

scriptedLog :: [ConsumerRecord (Maybe ByteString) (Maybe ByteString)] -> IO ScriptedLog
scriptedLog records =
  ScriptedLog records <$> newIORef 0 <*> newIORef [] <*> newIORef [] <*> newIORef []

producedRecord :: ConsumerRecord (Maybe ByteString) (Maybe ByteString)
producedRecord =
  ConsumerRecord
    { crTopic = scriptedTopic,
      crPartition = PartitionId 0,
      crOffset = Offset 0,
      crTimestamp = NoTimestamp,
      crHeaders = headersFromList [("traceparent", producerParent)],
      crKey = Nothing,
      crValue = Just (BS8.pack "correlated")
    }

-- | Process the one producer record with the given telemetry and return the
-- exported Consumer spans.
processRecord :: AdapterTelemetry -> IO [ConsumerSpan]
processRecord telemetry = do
  scripted <- scriptedLog [producedRecord]
  (spanProcessor, spansRef) <- inMemoryListExporter
  outcome <-
    Exception.bracket
      (OTel.createTracerProvider [spanProcessor] OTel.emptyTracerProviderOptions {OTel.tracerProviderOptionsIdGenerator = DefaultIdGenerator})
      (\provider -> OTel.shutdownTracerProvider provider (Just 5_000_000))
      $ \provider -> do
        let tracer = OTel.makeTracer provider (OTel.InstrumentationLibrary "kafka-correlation" "" "" emptyAttributes) OTel.tracerOptions
        runEff . runErrorNoCallStack @KafkaError . runScriptedConsumer scripted . runTracing tracer $ do
          adapter <- kafkaAdapter (configWith telemetry)
          app <- runApp defaultAppConfig [(ProcessorId processorName, mkProcessor adapter (\_ -> pure AckOk))]
          case app of
            Left err -> liftIO $ assertFailure (show err)
            Right handle -> do
              liftIO $ waitUntil "record stored" ((== [0]) <$> readIORef scripted.stored)
              drained <- stopAppGracefully defaultShutdownConfig handle
              if drained then pure () else stopApp handle
  assertEqual "app outcome" (Right ()) outcome
  consumerSpans =<< readIORef spansRef

data ConsumerSpan = ConsumerSpan
  { name :: Text,
    context :: OTel.SpanContext,
    parent :: Maybe OTel.SpanContext,
    links :: [OTel.SpanContext]
  }

consumerSpans :: [OTel.ImmutableSpan] -> IO [ConsumerSpan]
consumerSpans exported = traverse describeSpan [sp | sp <- exported, OTel.spanKind sp == OTel.Consumer]
  where
    describeSpan sp = do
      hot <- readIORef (OTel.spanHot sp)
      parent <- traverse OTel.getSpanContext (OTel.spanParent sp)
      pure
        ConsumerSpan
          { name = OTel.hotName hot,
            context = OTel.spanContext sp,
            parent,
            links = map OTel.frozenLinkContext (toList (appendOnlyBoundedCollectionValues (OTel.hotLinks hot)))
          }

linkIds :: ConsumerSpan -> [(Text, Text)]
linkIds sp = [(hexTrace l, hexSpan l) | l <- sp.links]

hexTrace :: OTel.SpanContext -> Text
hexTrace ctx = OTel.Id.traceIdBaseEncodedText Base16 ctx.traceId

hexSpan :: OTel.SpanContext -> Text
hexSpan ctx = OTel.Id.spanIdBaseEncodedText Base16 ctx.spanId
