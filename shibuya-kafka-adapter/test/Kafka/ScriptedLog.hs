-- | A broker-free 'KafkaConsumer' interpreter backed by an in-memory,
-- single-partition log that supports poll, seek, and offset store.
module Kafka.ScriptedLog
  ( ScriptedLog (..),
    newScriptedLog,
    runScriptedConsumer,
    scriptedTopic,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Int (Int64)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kafka.Consumer (RdKafkaRespErrT (..))
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), PartitionOffset (..), SubscribedPartitions (..), Timestamp (..), TopicPartition (..))
import Kafka.Effectful.Consumer.Effect (KafkaConsumer (..))
import Kafka.Types (BatchSize (..), KafkaError (..), PartitionId (..), Timeout (..), TopicName (..))

data ScriptedLog = ScriptedLog
  { records :: ![ConsumerRecord (Maybe ByteString) (Maybe ByteString)],
    -- | Index of the next record a poll returns.
    position :: !(IORef Int),
    -- | Offsets passed to @storeOffsetMessage@, oldest first.
    stored :: !(IORef [Int64]),
    -- | Offsets passed to @seekPartitions@, oldest first.
    seeks :: !(IORef [Int64]),
    -- | Timeout in milliseconds of every poll the adapter made, oldest first.
    polls :: !(IORef [Int])
  }

scriptedTopic :: TopicName
scriptedTopic = TopicName "orders"

-- | A log holding offsets @0 .. count - 1@ on partition 0 of 'scriptedTopic'.
newScriptedLog :: Int -> IO ScriptedLog
newScriptedLog count =
  ScriptedLog (map recordAt [0 .. fromIntegral count - 1])
    <$> newIORef 0
    <*> newIORef []
    <*> newIORef []
    <*> newIORef []
  where
    recordAt offset =
      ConsumerRecord
        { crTopic = scriptedTopic,
          crPartition = PartitionId 0,
          crOffset = Offset offset,
          crTimestamp = NoTimestamp,
          crHeaders = mempty,
          crKey = Nothing,
          crValue = Just (BS8.pack (show offset))
        }

runScriptedConsumer :: (IOE :> es) => ScriptedLog -> Eff (KafkaConsumer : es) a -> Eff es a
runScriptedConsumer scripted =
  interpret $ \_env -> \case
    PollMessageBatch (Timeout millis) (BatchSize size) -> liftIO $ do
      atomicModifyIORef' scripted.polls (\done -> (done <> [millis], ()))
      batch <-
        atomicModifyIORef' scripted.position $ \current ->
          let batch = take size (drop current scripted.records)
           in (current + length batch, batch)
      -- A real poll blocks for its timeout when the partition is drained.
      if null batch then threadDelay (millis * 1000) else pure ()
      pure (map Right batch)
    SeekPartitions targets _ -> liftIO $
      forM_ targets $ \target -> case target.tpOffset of
        PartitionOffset offset -> do
          atomicModifyIORef' scripted.position (const (fromIntegral offset, ()))
          atomicModifyIORef' scripted.seeks (\done -> (done <> [offset], ()))
        other -> error ("ScriptedLog: unsupported seek target " <> show other)
    StoreOffsetMessage cr -> liftIO $ atomicModifyIORef' scripted.stored (\done -> (done <> [unOffset cr.crOffset], ()))
    Subscription -> pure [(scriptedTopic, SubscribedPartitionsAll)]
    CommitAllOffsets _ -> pure ()
    PausePartitions _ -> pure ()
    PollMessageEither (Timeout millis) -> liftIO $ do
      atomicModifyIORef' scripted.polls (\done -> (done <> [millis], ()))
      next <-
        atomicModifyIORef' scripted.position $ \current ->
          case drop current scripted.records of
            record : _ -> (current + 1, Just record)
            [] -> (current, Nothing)
      case next of
        Just record -> pure (Right record)
        Nothing -> do
          -- A real poll blocks for its timeout when the partition is drained.
          threadDelay (millis * 1000)
          pure (Left (KafkaResponseError RdKafkaRespErrTimedOut))
    PollMessage _ -> error "ScriptedLog: PollMessage not scripted"
    CommitOffsetMessage _ _ -> error "ScriptedLog: CommitOffsetMessage not scripted"
    CommitPartitionsOffsets _ _ -> error "ScriptedLog: CommitPartitionsOffsets not scripted"
    StoreOffsets _ -> error "ScriptedLog: StoreOffsets not scripted"
    Assign _ -> error "ScriptedLog: Assign not scripted"
    ResumePartitions _ -> error "ScriptedLog: ResumePartitions not scripted"
    Committed _ _ -> error "ScriptedLog: Committed not scripted"
    Position _ -> error "ScriptedLog: Position not scripted"
    Assignment -> error "ScriptedLog: Assignment not scripted"
    AskConsumerHandle -> error "ScriptedLog: AskConsumerHandle not scripted"
