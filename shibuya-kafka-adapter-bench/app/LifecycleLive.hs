-- | EP-45 live Kafka performance, retained-memory, and restart fixture.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, wait)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO, writeTVar)
import Control.Exception qualified as Exception
import Control.Monad (forever, unless, when)
import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:))
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Word (Word64)
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Kafka.Consumer.Types (ConsumerGroupId (..), OffsetReset (..))
import Kafka.Effectful.Consumer (brokersList, groupId, noAutoOffsetStore, offsetReset, runKafkaConsumer, topics)
import Kafka.Effectful.Producer (flushProducer, produceMessage, runKafkaProducer)
import Kafka.Effectful.Producer qualified as Producer
import Kafka.Producer.Types (ProducePartition (..), ProducerRecord (..))
import Kafka.Types (BatchSize (..), BrokerAddress (..), KafkaError, Timeout (..), TopicName (..))
import Shibuya.Adapter.Kafka (KafkaAdapterConfig (..), kafkaAdapter)
import Shibuya.App
  ( ProcessorId (..),
    ShutdownConfig (drainTimeout, totalShutdownTimeout),
    defaultAppConfig,
    defaultShutdownConfig,
    mkProcessor,
    runApp,
    stopAppGracefully,
  )
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (Handle, IOMode (..), hFlush, hPutStrLn, withFile)
import System.Mem (performMajorGC)
import System.Process (callProcess, readProcess)
import Text.Read (readMaybe)

data Config = Config
  { durationSecs :: !Int,
    messagesPerSecond :: !Int,
    sampleIntervalSecs :: !Int,
    outputCsv :: !FilePath,
    runId :: !String,
    restartAtSecs :: !Int,
    shutdownDrainSecs :: !Int,
    shutdownTotalSecs :: !Int
  }

data Sample = Sample
  { timestamp :: !UTCTime,
    elapsedSecs :: !Int,
    messagesProduced :: !Int,
    messagesProcessed :: !Int,
    messagesFailed :: !Int,
    queueDepth :: !Int64,
    retainedBytes :: !Word64,
    maxLiveBytes :: !Word64
  }

data GroupDescription = GroupDescription
  { totalLag :: !Int64
  }

instance FromJSON GroupDescription where
  parseJSON = withObject "GroupDescription" $ \value -> GroupDescription <$> value .: "total_lag"

broker :: BrokerAddress
broker = BrokerAddress "127.0.0.1:9092"

main :: IO ()
main = do
  config <- loadConfig
  let suffix = filter validResourceChar config.runId
      topic = TopicName $ Text.pack ("ep45-" <> suffix)
      group = ConsumerGroupId $ Text.pack ("ep45-" <> suffix <> "-group")
  putStrLn "=== Shibuya Kafka lifecycle live fixture ==="
  putStrLn $ "Duration: " <> show config.durationSecs <> " seconds"
  putStrLn $ "Target rate: " <> show config.messagesPerSecond <> " msg/s"
  putStrLn $ "Restart at: " <> show config.restartAtSecs <> " seconds"
  putStrLn $ "Topic: " <> Text.unpack (unTopicName topic)
  Exception.bracket_
    (callProcess "rpk" ["topic", "create", Text.unpack (unTopicName topic), "-p", "4"])
    (callProcess "rpk" ["topic", "delete", Text.unpack (unTopicName topic)])
    (runFixture config topic group)
  where
    validResourceChar char =
      ('a' <= char && char <= 'z')
        || ('A' <= char && char <= 'Z')
        || ('0' <= char && char <= '9')
        || char == '-'

loadConfig :: IO Config
loadConfig = do
  duration <- envInt "DURATION_SECS" 1800
  rate <- envInt "MESSAGES_PER_SECOND" 1000
  interval <- envInt "SAMPLE_INTERVAL_SECS" 30
  output <- envString "OUTPUT_CSV" "kafka-lifecycle.csv"
  now <- getCurrentTime
  identifier <- envString "LIFECYCLE_RUN_ID" (formatTime defaultTimeLocale "%Y%m%d%H%M%S" now)
  restart <- envInt "RESTART_AT_SECS" (duration `div` 2)
  shutdownDrain <- envInt "SHUTDOWN_DRAIN_SECS" 30
  shutdownTotal <- envInt "SHUTDOWN_TOTAL_SECS" 60
  pure
    Config
      { durationSecs = duration,
        messagesPerSecond = rate,
        sampleIntervalSecs = interval,
        outputCsv = output,
        runId = identifier,
        restartAtSecs = max 1 (min (duration - 1) restart),
        shutdownDrainSecs = shutdownDrain,
        shutdownTotalSecs = shutdownTotal
      }

envString :: String -> String -> IO String
envString key fallback = maybe fallback id <$> lookupEnv key

envInt :: String -> Int -> IO Int
envInt key fallback = maybe fallback id . (>>= readMaybe) <$> lookupEnv key

runFixture :: Config -> TopicName -> ConsumerGroupId -> IO ()
runFixture config topic group = do
  producedVar <- newTVarIO (0 :: Int)
  processedRef <- newIORef (0 :: Int)
  failedRef <- newIORef (0 :: Int)
  stopVar <- newTVarIO False
  startTime <- getCurrentTime

  withFile config.outputCsv WriteMode $ \handle -> do
    hPutStrLn handle csvHeader
    producerThread <- async $ runProducer config topic producedVar stopVar
    samplerThread <- async $ runSampler config topic group startTime producedVar processedRef failedRef handle

    runConsumerSegment config topic group processedRef failedRef $ do
      threadDelay (config.restartAtSecs * 1_000_000)
      putStrLn "Graceful midpoint stop"

    putStrLn "Restarting with the same consumer group"
    runConsumerSegment config topic group processedRef failedRef $ do
      threadDelay ((config.durationSecs - config.restartAtSecs) * 1_000_000)
      atomically $ writeTVar stopVar True
      wait producerThread
      waitForDrain producedVar processedRef 60
      waitForBrokerDrain group 20

    cancel samplerThread
    finalSample <- sampleMetrics topic group startTime producedVar processedRef failedRef
    hPutStrLn handle $ sampleToCsv finalSample
    hFlush handle

    let passed =
          finalSample.messagesFailed == 0
            && finalSample.messagesProcessed == finalSample.messagesProduced
            && finalSample.queueDepth == 0
    putStrLn $ "Produced: " <> show finalSample.messagesProduced
    putStrLn $ "Processed: " <> show finalSample.messagesProcessed
    putStrLn $ "Broker lag: " <> show finalSample.queueDepth
    unless passed exitFailure

runProducer :: Config -> TopicName -> TVar Int -> TVar Bool -> IO ()
runProducer config topic producedVar stopVar = do
  outcome <- runEff . runError @KafkaError $ runKafkaProducer (Producer.brokersList [broker]) $ loop (0 :: Int)
  case outcome of
    Left err -> error $ "Kafka producer failed: " <> show err
    Right () -> pure ()
  where
    delayMicros = 1_000_000 `div` max 1 config.messagesPerSecond
    loop index = do
      shouldStop <- liftIO $ readTVarIO stopVar
      if shouldStop
        then flushProducer
        else do
          produceMessage
            ProducerRecord
              { prTopic = topic,
                prPartition = UnassignedPartition,
                prKey = Just $ BS8.pack (show (index `mod` 1024)),
                prValue = Just $ BS8.pack ("ep45-" <> show index),
                prHeaders = mempty
              }
          liftIO $ atomically $ modifyTVar' producedVar (+ 1)
          when (delayMicros > 0) $ liftIO $ threadDelay delayMicros
          loop (index + 1)

runConsumerSegment :: Config -> TopicName -> ConsumerGroupId -> IORef Int -> IORef Int -> IO () -> IO ()
runConsumerSegment config topic group processedRef _failedRef action = do
  let properties = brokersList [broker] <> groupId group <> noAutoOffsetStore
      subscription = topics [topic] <> offsetReset Earliest
      adapterConfig =
        KafkaAdapterConfig
          { topics = [topic],
            pollTimeout = Timeout 250,
            batchSize = BatchSize 500
          }
  outcome <- runEff . runError @KafkaError $ runKafkaConsumer properties subscription $ runTracingNoop $ do
    adapter <- kafkaAdapter adapterConfig
    result <- runApp defaultAppConfig [(ProcessorId "kafka-ep45", mkProcessor adapter handler)]
    case result of
      Left err -> liftIO $ error $ "runApp failed: " <> show err
      Right appHandle -> do
        liftIO action
        liftIO $ putStrLn "Stopping Shibuya application"
        let shutdownConfig =
              defaultShutdownConfig
                { drainTimeout = fromIntegral config.shutdownDrainSecs,
                  totalShutdownTimeout = fromIntegral config.shutdownTotalSecs
                }
        drained <- stopAppGracefully shutdownConfig appHandle
        liftIO $ putStrLn $ "Shibuya graceful drain: " <> show drained
        unless drained $ liftIO $ error "Shibuya application required forced shutdown"
  case outcome of
    Left err -> error $ "Kafka consumer failed: " <> show err
    Right () -> pure ()
  where
    handler _ = do
      liftIO $ atomicModifyIORef' processedRef $ \count -> (count + 1, ())
      pure AckOk

runSampler :: Config -> TopicName -> ConsumerGroupId -> UTCTime -> TVar Int -> IORef Int -> IORef Int -> Handle -> IO ()
runSampler config topic group startTime producedVar processedRef failedRef handle = forever $ do
  threadDelay (config.sampleIntervalSecs * 1_000_000)
  sample <- sampleMetrics topic group startTime producedVar processedRef failedRef
  hPutStrLn handle $ sampleToCsv sample
  hFlush handle
  putStrLn $
    "["
      <> show sample.elapsedSecs
      <> "s] produced="
      <> show sample.messagesProduced
      <> " processed="
      <> show sample.messagesProcessed
      <> " lag="
      <> show sample.queueDepth
      <> " retained="
      <> show sample.retainedBytes

sampleMetrics :: TopicName -> ConsumerGroupId -> UTCTime -> TVar Int -> IORef Int -> IORef Int -> IO Sample
sampleMetrics _topic group startTime producedVar processedRef failedRef = do
  now <- getCurrentTime
  produced <- readTVarIO producedVar
  processed <- readIORef processedRef
  failed <- readIORef failedRef
  lag <- groupLag group
  (retained, highWater) <- getMemoryBytes
  pure
    Sample
      { timestamp = now,
        elapsedSecs = round $ diffUTCTime now startTime,
        messagesProduced = produced,
        messagesProcessed = processed,
        messagesFailed = failed,
        queueDepth = lag,
        retainedBytes = retained,
        maxLiveBytes = highWater
      }

groupLag :: ConsumerGroupId -> IO Int64
groupLag (ConsumerGroupId name) = do
  output <- readProcess "rpk" ["group", "describe", Text.unpack name, "--format", "json"] ""
  case eitherDecode (LBS8.pack output) :: Either String [GroupDescription] of
    Right (description : _) -> pure description.totalLag
    Right [] -> pure 0
    Left err -> error $ "Cannot decode rpk group lag: " <> err

getMemoryBytes :: IO (Word64, Word64)
getMemoryBytes = do
  enabled <- getRTSStatsEnabled
  if enabled
    then do
      performMajorGC
      stats <- getRTSStats
      pure (gcdetails_live_bytes stats.gc, max_live_bytes stats)
    else pure (0, 0)

waitForDrain :: TVar Int -> IORef Int -> Int -> IO ()
waitForDrain producedVar processedRef timeoutSecs = loop (timeoutSecs * 10)
  where
    loop remaining = do
      produced <- readTVarIO producedVar
      processed <- readIORef processedRef
      if processed >= produced
        then pure ()
        else
          if remaining > 0
            then threadDelay 100_000 >> loop (remaining - 1)
            else error $ "Timed out draining produced messages: produced=" <> show produced <> " processed=" <> show processed

waitForBrokerDrain :: ConsumerGroupId -> Int -> IO ()
waitForBrokerDrain group timeoutSecs = loop (timeoutSecs * 10)
  where
    loop remaining = do
      lag <- groupLag group
      if lag <= 0
        then pure ()
        else
          if remaining > 0
            then threadDelay 100_000 >> loop (remaining - 1)
            else error $ "Timed out draining Kafka consumer group: lag=" <> show lag

csvHeader :: String
csvHeader = "timestamp,elapsed_secs,produced,processed,failed,queue_depth,retained_bytes,max_live_bytes"

sampleToCsv :: Sample -> String
sampleToCsv sample =
  Text.unpack $
    Text.intercalate
      ","
      [ Text.pack $ formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" sample.timestamp,
        Text.pack $ show sample.elapsedSecs,
        Text.pack $ show sample.messagesProduced,
        Text.pack $ show sample.messagesProcessed,
        Text.pack $ show sample.messagesFailed,
        Text.pack $ show sample.queueDepth,
        Text.pack $ show sample.retainedBytes,
        Text.pack $ show sample.maxLiveBytes
      ]
