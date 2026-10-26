module Shibuya.Adapter.Kafka.SourceGateTest (tests, afterYields, await, waitUntil) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, writeTVar)
import Control.Exception qualified as IOExc
import Control.Monad (unless)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty qualified as NE
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Exception qualified as Exception
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), RebalanceEvent (..))
import Kafka.ScriptedLog
import Kafka.Types (BatchSize (..), KafkaError, PartitionId (..), Timeout (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (KafkaAdapterConfig (..), kafkaAdapter, kafkaRebalanceHandler)
import Shibuya.Adapter.Kafka.AckHandleTest hiding (tests)
import Shibuya.Adapter.Kafka.Internal (KafkaAdapterState (..), Polled (..), gateRecords, kafkaSource, mkAckHandle, newKafkaAdapterState)
import Shibuya.App (ProcessorId (..), defaultAppConfig, defaultShutdownConfig, mkBatchProcessor, mkProcessor, runApp, stopApp, stopAppGracefully)
import Shibuya.Batch (BatchConfig (..), BatchInfo (..), BatchTrigger (..), ackAllOk, ackExcept, defaultBatchConfig)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Source gate"
    [ testCase "buffered retry commits every successor (scripted log)" (scriptedRetry 1),
      testCase "a record that retries twice still commits every successor (scripted log)" (scriptedRetry 2),
      testCase "pre-seek successors are dropped" testStale,
      testCase "replay holds successor until success" (testHold "ok"),
      testCase "retry drops held successor" (testHold "retry"),
      testCase "shutdown wakes held successor" (testHold "shutdown"),
      testCase "halt wakes held successor" (testHold "halt"),
      testCase "revocation wakes held successor" (testHold "revoke"),
      testCase "dead letter releases held successor" (testHold "dead-letter"),
      testCase "cancellation releases held gate worker" (testHold "cancel"),
      testCase "fatal acknowledgement wakes held successor" (testHold "fatal"),
      testCase "missing replay fences old callbacks" testGap,
      testCase "seek affects only its own partition" testPartitionIsolation,
      testCase "requested incomplete seek makes records stale" testPendingSeek,
      testCase "batch timeout releases replay and stores all successors" testBatchLiveness
    ]

-- Signal on the pull after the nth yield, before pulling upstream again.
afterYields :: (IOE :> es) => Int -> MVar () -> Stream (Eff es) a -> Stream (Eff es) a
afterYields count ready = Stream.unfoldrM step . (0,)
  where
    step (n, stream) = do
      if n == count then liftIO (putMVar ready ()) else pure ()
      next <- Stream.uncons stream
      pure $ case next of
        Nothing -> Nothing
        Just (value, rest) -> Just (value, (n + 1, rest))

await :: String -> MVar a -> IO a
await label var = timeout 5000000 (takeMVar var) >>= maybe (assertFailure (label <> " timed out") >> error label) pure

waitUntil :: String -> IO Bool -> IO ()
waitUntil label check = do
  result <- timeout 10000000 loop
  unless (result == Just ()) $ assertFailure (label <> " timed out")
  where
    loop = check >>= \done -> unless done (threadDelay 1000 >> loop)

scriptedRetry :: Int -> IO ()
scriptedRetry retries = do
  scripted <- newScriptedLog 12
  deliveries <- newIORef ([] :: [Int64])
  attempts <- newIORef (0 :: Int)
  queued <- newEmptyMVar
  outcome <- timeout 30000000 $
    runEff . runErrorNoCallStack @KafkaError . runScriptedConsumer scripted . runTracingNoop $ do
      upstream <- kafkaAdapter KafkaAdapterConfig {topics = [scriptedTopic], pollTimeout = Timeout 5, batchSize = BatchSize 100}
      let adapter = upstream {source = afterYields 12 queued upstream.source}
          handler Message {envelope} = do
            let offset = case envelope.cursor of
                  Just (CursorInt value) -> fromIntegral value
                  _ -> -1
            liftIO $ atomicModifyIORef' deliveries (\xs -> (xs <> [offset], ()))
            if offset == 4
              then do
                attempt <- liftIO $ atomicModifyIORef' attempts (\n -> (n + 1, n))
                if attempt == 0 then liftIO (await "initial inbox" queued) else pure ()
                pure $ if attempt < retries then AckRetry (RetryDelay 0) else AckOk
              else pure AckOk
      app <- runApp defaultAppConfig [(ProcessorId "scripted-retry", mkProcessor adapter handler)]
      case app of
        Left err -> liftIO $ assertFailure (show err)
        Right handle ->
          Exception.finally
            ( do
                liftIO $
                  waitUntil "all offsets stored" ((== [0 .. 11]) <$> readIORef scripted.stored)
                    `IOExc.onException` ( do
                                            stores <- readIORef scripted.stored
                                            trace <- readIORef deliveries
                                            putStrLn ("stored=" <> show stores <> " deliveries=" <> show trace)
                                        )
                drained <- stopAppGracefully defaultShutdownConfig handle
                liftIO $ assertEqual "successful drain" True drained
            )
            (stopApp handle)
  observed <- readIORef deliveries
  stores <- readIORef scripted.stored
  seeks <- readIORef scripted.seeks
  assertEqual ("completion; deliveries=" <> show observed <> "; stored=" <> show stores) (Just (Right ())) outcome
  assertEqual "stored offsets" [0 .. 11] stores
  assertEqual "seeks" (replicate retries 4) seeks

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> error "unexpected Left") pure

gateOffsets :: KafkaAdapterState -> [Polled] -> IO [Int64]
gateOffsets state values = runEff $ Stream.fold Fold.toList $ fmap (either (const (-1)) (unOffset . (.crOffset))) $ gateRecords state $ Stream.fromList (map Right values)

testStale :: IO ()
testStale = do
  state <- newKafkaAdapterState
  mock <- newIORef defaultMockState
  runFinalizer mock (finalizeRecord state (recordAt 42) (AckRetry (RetryDelay 0))) >>= assertRight
  gateOffsets state [Polled 0 (recordAt 43), Polled 0 (recordAt 44)] >>= assertEqual "stale records" []

testHold :: String -> IO ()
testHold mode = do
  state <- newKafkaAdapterState
  mock <- newIORef defaultMockState
  runFinalizer mock (finalizeRecord state (recordAt 42) (AckRetry (RetryDelay 0))) >>= assertRight
  emitted <- newEmptyMVar
  offered <- newEmptyMVar
  successor <- newEmptyMVar
  let input =
        Stream.mapM
          ( \p -> do
              if p.record.crOffset == Offset 43 then liftIO (putMVar offered ()) else pure ()
              pure (Right p)
          )
          $ Stream.fromList [Polled 1 (recordAt 42), Polled 1 (recordAt 43)]
      worker =
        runEff
          $ Stream.fold Fold.drain
          $ Stream.mapM
            ( \case
                Right cr | cr.crOffset == Offset 42 -> liftIO $ do
                  ack <- runFinalizer mock (mkAckHandle state testConfig cr) >>= right
                  putMVar emitted ack
                Right _ -> liftIO (putMVar successor ())
                Left _ -> error "unexpected error"
            )
          $ gateRecords state input
  Async.withAsync worker $ \async -> do
    AckHandle finalize <- await "replay emission" emitted
    await "successor offered" offered
    timeout 200000 (takeMVar successor) >>= assertEqual "held successor" Nothing
    case mode of
      "shutdown" -> atomically $ writeTVar state.shutdownVar True
      "revoke" -> kafkaRebalanceHandler state (error "unused consumer") (RebalanceRevoke [(scriptedTopic, PartitionId 0)])
      "cancel" -> Async.cancel async
      "fatal" -> do
        atomicModifyIORef' mock (\m -> (m {storeFailuresRemaining = 99}, ()))
        failed <- IOExc.try @IOExc.SomeException $ runFinalizer mock (finalizeRecord state (recordAt 1) {crPartition = PartitionId 1} AckOk)
        case failed of
          Left _ -> pure ()
          Right _ -> assertFailure "expected exhausted acknowledgement"
      _ ->
        runFinalizer
          mock
          ( finalize
              ( case mode of
                  "retry" -> AckRetry (RetryDelay 0)
                  "halt" -> AckHalt (HaltFatal "stop")
                  "dead-letter" -> AckDeadLetter MaxRetriesExceeded
                  _ -> AckOk
              )
          )
          >>= assertRight
    if mode == "cancel"
      then do
        timeout 1000000 (runFinalizer mock (finalize AckOk)) >>= maybe (assertFailure "lock leaked") assertRight
      else do
        timeout 1000000 (Async.wait async) >>= assertEqual "gate worker exits" (Just ())
        if mode `elem` ["ok", "dead-letter"]
          then await "successor released" successor
          else timeout 10000 (takeMVar successor) >>= assertEqual "successor dropped" Nothing
    if mode == "fatal"
      then do
        result <- runFinalizer mock $ Stream.fold Fold.drain $ gateRecords state $ kafkaSource state testConfig
        case result of
          Left _ -> pure ()
          Right _ -> assertFailure "fatal slot must fail before polling"
      else pure ()

testGap :: IO ()
testGap = mapM_ check [AckOk, AckRetry (RetryDelay 0)]
  where
    check decision = do
      state <- newKafkaAdapterState
      mock <- newIORef defaultMockState
      old <- runFinalizer mock (mkAckHandle state testConfig (recordAt 46)) >>= right
      runFinalizer mock (finalizeRecord state (recordAt 42) (AckRetry (RetryDelay 0))) >>= assertRight
      gateOffsets state [Polled 1 (recordAt 45), Polled 1 (recordAt 46)] >>= assertEqual "gap resumes" [45, 46]
      let AckHandle finalize = old
      runFinalizer mock (finalize decision >> finalizeRecord state (recordAt 45) AckOk) >>= assertRight
      m <- readIORef mock
      assertEqual "only new delivery stores" [Offset 45] m.storedOffsets
      assertEqual "old callback cannot seek" 1 (length m.seekCalls)

testPartitionIsolation :: IO ()
testPartitionIsolation = do
  state <- newKafkaAdapterState
  mock <- newIORef defaultMockState
  runFinalizer mock (finalizeRecord state (recordAt 42) (AckRetry (RetryDelay 0))) >>= assertRight
  gateOffsets state [Polled 0 (recordAt 43) {crPartition = PartitionId 1}] >>= assertEqual "other partition stays current" [43]
  kafkaRebalanceHandler state (error "unused") (RebalanceRevoke [(scriptedTopic, PartitionId 0)])
  gateOffsets state [Polled 1 (recordAt 42)] >>= assertEqual "revoked partition" []

testPendingSeek :: IO ()
testPendingSeek = do
  state <- newKafkaAdapterState
  started <- newEmptyMVar
  release <- newEmptyMVar
  mock <- newIORef defaultMockState {seekBlock = Just (started, release)}
  Async.withAsync (runFinalizer mock (finalizeRecord state (recordAt 42) (AckRetry (RetryDelay 0)))) $ \worker -> do
    await "seek entered" started
    gateOffsets state [Polled 0 (recordAt 42)] >>= assertEqual "pending seek drops record" []
    putMVar release ()
    Async.wait worker >>= assertRight
    gateOffsets state [Polled 1 (recordAt 42)] >>= assertEqual "completed seek admits replay" [42]

testBatchLiveness :: IO ()
testBatchLiveness = do
  scripted <- newScriptedLog 12
  first <- newIORef True
  batches <- newIORef []
  outcome <- timeout 10000000 $
    runEff . runErrorNoCallStack @KafkaError . runScriptedConsumer scripted . runTracingNoop $ do
      adapter <- kafkaAdapter KafkaAdapterConfig {topics = [scriptedTopic], pollTimeout = Timeout 5, batchSize = BatchSize 100}
      let config = defaultBatchConfig {batchSize = 12, batchTimeout = 0.05, tickInterval = Just 0.01}
          handler info messages = do
            isFirst <- liftIO $ atomicModifyIORef' first (\x -> (False, x))
            liftIO $ atomicModifyIORef' batches (\xs -> (xs <> [(info.trigger, info.size)], ()))
            pure $ if isFirst then ackExcept [((NE.head messages).envelope.messageId, AckRetry (RetryDelay 0))] else ackAllOk
      app <- runApp defaultAppConfig [(ProcessorId "batch-replay", mkBatchProcessor adapter handler config)]
      case app of
        Left err -> liftIO $ assertFailure (show err)
        Right handle ->
          Exception.finally
            ( do
                liftIO $ waitUntil "batch stores" ((== [0 .. 11]) <$> readIORef scripted.stored)
                drained <- stopAppGracefully defaultShutdownConfig handle
                liftIO $ assertEqual "drain" True drained
            )
            (stopApp handle)
  assertEqual "completion" (Just (Right ())) outcome
  observed <- readIORef batches
  unless ((TriggerTimeout, 1) `elem` observed) $ assertFailure ("missing replay timeout: " <> show observed)
