{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

module Control.Concurrent.Supervised where

import           Control.Applicative
import           Control.Concurrent.Lifted
import           Control.Concurrent.STM
import           Control.Exception.Lifted
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.Fix
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Maybe
import           Control.Monad.Trans.Reader
import           Data.Foldable
import           Data.List                   as List
import           Data.Map                    as Map
import           Data.Maybe
import           Data.Traversable            as Traversable

data ThreadInfo = ThreadInfo
    { _threadId    :: ThreadId
    , _threadName  :: Maybe String
    , _threadState :: ThreadState
    } deriving ( Show, Eq )

data ThreadState = New | Runnable | Waiting WaitTarget | Terminated deriving ( Show, Eq )

data WaitTarget = SupervisorEvent | SupervisedChannel deriving ( Show, Eq )

data Supervisor = Supervisor
    { _threads        :: TVar (Map ThreadId ThreadEntry)
    , _terminating    :: TVar Bool
    , _threadsRunning :: TVar Int
    }

data ThreadEntry = ThreadEntry (TVar (Maybe String)) (TVar ThreadState)

newtype SupervisedT s m a = SupervisedT { unSupervisedT :: ReaderT Supervisor m a } deriving
    ( Functor
    , Applicative
    , Alternative
    , Monad
    , MonadPlus
    , MonadFix
    , MonadIO
    , MonadTrans )

instance MonadTransControl (SupervisedT s) where
    newtype StT (SupervisedT s) a = StSupervisedT { unStSupervisedT :: StT (ReaderT Supervisor) a }
    liftWith = defaultLiftWith SupervisedT unSupervisedT StSupervisedT
    restoreT = defaultRestoreT SupervisedT unStSupervisedT

instance (MonadBase b m) => MonadBase b (SupervisedT s m) where
    liftBase = liftBaseDefault

instance (MonadBaseControl b m) => MonadBaseControl b (SupervisedT s m) where
    newtype StM (SupervisedT s m) a = StMSupervisedT { unStMSupervisedT :: ComposeSt (SupervisedT s) m a }

    liftBaseWith = defaultLiftBaseWith StMSupervisedT
    restoreM     = defaultRestoreM unStMSupervisedT

runSupervisedT :: (MonadBaseControl IO m) => (forall s . SupervisedT s m a) -> m a
runSupervisedT action = do
    bracket
       startSupervisor
       stopSupervisor
       (runReaderT $ unSupervisedT action)
    where
        startSupervisor = liftBase $ do
            thisThread <- myThreadId
            atomically $ do
                threadEntry <- ThreadEntry <$> newTVar Nothing <*> newTVar Runnable
                threads <- newTVar $ Map.singleton thisThread threadEntry
                threadsRunning <- newTVar 1
                terminating <- newTVar False
                return Supervisor { _threads = threads
                                  , _threadsRunning = threadsRunning
                                  , _terminating = terminating }

        stopSupervisor supervisor = liftBase $ do
            thisThread <- myThreadId
            threads <- atomically $ do
                writeTVar (_terminating supervisor) True
                readTVar $ _threads supervisor
            traverse_ killThread $ List.filter ((/=)thisThread) $ Map.keys threads
            return ()

setThreadState' :: Supervisor -> ThreadEntry -> ThreadState -> STM ()
setThreadState' supervisor (ThreadEntry _ threadState) newValue = do
    oldValue <- readTVar threadState
    when (oldValue /= newValue) $ do
        writeTVar threadState newValue
        case (oldValue, newValue) of
            (New,         Runnable) -> modifyTVar (_threadsRunning supervisor) (succ)
            (New,       Terminated) -> return ()

            (Waiting _,    Runnable) -> modifyTVar (_threadsRunning supervisor) (succ)
            (Waiting _,  Terminated) -> return ()

            (Runnable,   Waiting _) -> modifyTVar (_threadsRunning supervisor) (pred)
            (Runnable,  Terminated) -> modifyTVar (_threadsRunning supervisor) (pred)

            _ -> error $ "supervised-concurrency panic: unexcepted thread state transition: " ++ (show oldValue) ++ " -> " ++ (show newValue) ++ "."

setThreadState :: Supervisor -> ThreadId -> ThreadState -> STM ()
setThreadState supervisor threadId threadState = do
    threads <- readTVar $ _threads supervisor
    setThreadState' supervisor (threads Map.! threadId) threadState

getThreadEntry :: (MonadBase IO m) => Supervisor -> ThreadId -> m (Maybe ThreadEntry)
getThreadEntry supervisor threadId = liftBase $ atomically $ readTVar (_threads supervisor) >>= return . Map.lookup threadId

-- | Spawns new supervised thread. This method will block till the new thread will register itself.
spawn' :: (MonadBaseControl IO m) => Maybe String -> SupervisedT s m () -> SupervisedT s m ThreadId
spawn' name action = SupervisedT $ do
    threadEntry@(ThreadEntry _ threadState) <- liftBase $ atomically $ ThreadEntry <$> newTVar name <*> newTVar New
    supervisor <- ask
    uninterruptibleMask_ $ do
        newThread <- forkWithUnmask $ \unmask -> do
            thisThread <- myThreadId
            terminated <- liftBase $ atomically $ do
                terminating <- readTVar (_terminating supervisor)
                case terminating of
                    False -> do
                        setThreadState' supervisor threadEntry Runnable
                        modifyTVar (_threads supervisor) (Map.insert thisThread threadEntry)
                    True  ->
                        setThreadState' supervisor threadEntry Terminated
                return terminating
            when (not terminated) $ finally (unmask (unSupervisedT action)) $ liftBase $ atomically $ do
                setThreadState' supervisor threadEntry Terminated
                modifyTVar (_threads supervisor) (Map.delete thisThread)
        -- I use uninterruptibleMask_ because I want to guarantee that calling thread will be blocked till
        -- new thread registered. Otherwise calling thread could be interruped on retry which is not desired.
        -- Thread is guaranted not to be deadlocked because new thread will eventually update it's status.
        liftBase $ atomically $ readTVar threadState >>= check . (/=) New
        return newThread

spawn :: (MonadBaseControl IO m) => SupervisedT s m () -> SupervisedT s m ThreadId
spawn = spawn' Nothing

spawnNamed :: (MonadBaseControl IO m) => String -> SupervisedT s m () -> SupervisedT s m ThreadId
spawnNamed = spawn' . Just

getOthersThreadName :: (MonadBase IO m) => ThreadId -> SupervisedT s m (Maybe String)
getOthersThreadName threadId = SupervisedT $ do
    supervisor <- ask
    runMaybeT $ do
        (ThreadEntry threadNameVar _) <- MaybeT $ getThreadEntry supervisor threadId
        MaybeT $ liftBase $ atomically $ readTVar threadNameVar

getThreadName :: (MonadBase IO m) =>  SupervisedT s m (Maybe String)
getThreadName =  liftBase myThreadId >>= getOthersThreadName

setOthersThreadName :: (MonadBase IO m) => ThreadId -> String -> SupervisedT s m Bool
setOthersThreadName threadId threadName = SupervisedT $ do
    supervisor <- ask
    fmap isJust $ runMaybeT $ do
        (ThreadEntry threadNameVar _) <- MaybeT $ getThreadEntry supervisor threadId
        liftBase $ atomically $ writeTVar threadNameVar $ Just threadName

data SupervisorEvent result where
    ThreadState :: ThreadId -> (ThreadInfo -> Maybe result) -> SupervisorEvent (Maybe result)
    SupervisorState :: (Map ThreadId ThreadInfo -> Maybe result) -> SupervisorEvent result
    NoRunningThreads :: SupervisorEvent ()

toThreadInfo :: ThreadId -> ThreadEntry -> STM ThreadInfo
toThreadInfo threadId (ThreadEntry threadNameVar threadStateVar) = do
    threadName <- readTVar threadNameVar
    threadState <- readTVar threadStateVar
    return ThreadInfo
        { _threadId = threadId
        , _threadName = threadName
        , _threadState = threadState
        }

waitTill :: (MonadBaseControl IO m) => SupervisorEvent a -> SupervisedT s m a
waitTill event = SupervisedT $ do
    thisThread  <- myThreadId
    supervisor <- ask
    -- Update thread state and wait for event (masked, interruptable)
    liftBase $ mask_ $ do
        atomically $ setThreadState supervisor thisThread $ Waiting SupervisorEvent
        finally
            ( case event of
                ThreadState threadId f -> runMaybeT $ do
                    threadEntry <- MaybeT $ getThreadEntry supervisor threadId
                    liftIO $ atomically $ toThreadInfo threadId threadEntry >>= fromMaybe retry . fmap return . f
                SupervisorState f -> atomically $ do
                    threads <- readTVar (_threads supervisor)
                    state <- Traversable.sequence $ Map.mapWithKey toThreadInfo threads
                    fromMaybe retry $ fmap return $ f state
                NoRunningThreads -> atomically $ readTVar (_threadsRunning supervisor) >>= check . (==) 0 )
            ( atomically $ setThreadState supervisor thisThread Runnable )

-- | Sender channel
type Sender s m a = a -> m () -- Для ошибок можно использовать исключения, либо MonadError

-- | Receiver channel
type Receiver s m a = m a

data Unsupervised

data Channel s m a = Channel (Sender s m a) (Receiver s m a)

data ChannelState = Free Int Int       -- ^ Channel is free to send recieve (num of messages pending, num of recievers waiting).
                  | SenderLock         -- ^ Sender put lock on the channel (no one can send, reciever should reply, if any).
                  | RecieverLock
                  | RecieverReply Bool -- ^ Recievers reply to current sender (bool indicated if a message was actually recieved or reciever was interrupted).
    deriving ( Show )

tryAny :: (MonadBaseControl IO m, Exception e) => m a -> m (Either e a)
tryAny = try

registerChannel' :: (MonadBaseControl IO m) => (Channel Unsupervised m a) -> SupervisedT s m (Channel  s m a)
registerChannel' (Channel sender reciever) = SupervisedT $ do
    channelStateVar <- liftBase $ atomically $ newTVar $ Free 0 0
    supervisor <- ask

    let whenNotTerminating :: (MonadBase IO m) => STM a -> MaybeT m a
        whenNotTerminating f = MaybeT $ liftBase $ atomically $ do
            terminating <- readTVar (_terminating supervisor)
            case terminating of
                True -> return Nothing
                False -> Just <$> f

        waitChannelFree :: (MonadBase IO m) => ChannelState -> MaybeT m ChannelState
        waitChannelFree lock = whenNotTerminating $ do
            currentState <- readTVar channelStateVar
            case currentState of
                Free _ _ -> do
                    writeTVar channelStateVar lock
                    return currentState
                _ -> retry

        sendSupervised message = mask_ $ liftM (maybe () id) . runMaybeT $ do
            -- Await channel free under interruptible mask and put sender lock on it.
            channelState@(Free messagesPending threadsWaiting) <- waitChannelFree SenderLock
            -- Send message under interruptible mask and restore state if sending fails.
            onException
                ( lift $ sender message)
                ( liftBase $ atomically $ writeTVar channelStateVar channelState )

            let waitRecieverReply :: Int -> STM ()
                -- No waiting threads, increase pending messages count and free the channel.
                waitRecieverReply 0 = writeTVar channelStateVar $ Free (succ messagesPending) $ 0
                waitRecieverReply nowWaiting = do
                    currentState <- readTVar channelStateVar
                    case currentState of
                        -- Reciever got message. Decrease waiting threads count and free the channel.
                        RecieverReply True  -> writeTVar channelStateVar $ Free messagesPending $ pred nowWaiting
                        -- Reciever terminated, setting SenderLock and waiting for channel state updates
                        RecieverReply False -> do
                            writeTVar channelStateVar SenderLock
                            waitRecieverReply (pred nowWaiting)
                        -- Otherwise wait for channel state update
                        SenderLock -> retry
                        other -> error $ "supervised-concurrency panic: channel state disrupted: got " ++ (show other) ++ " with sender lock on."

            --  Uninterruptible wait for reciever reply or terminated no recievers condition.
            uninterruptibleMask_ $ whenNotTerminating $ waitRecieverReply threadsWaiting

        recieveSupervised = mask_ $ do
            thisThread  <- myThreadId
            threadEntry <- maybe (error "supervised-concurrency panic: thread entry not found for current thread.") id <$> getThreadEntry supervisor thisThread
            maybeRecieved <- runMaybeT $ do
                stateIfLocked <- whenNotTerminating $ do
                    channelState <- readTVar channelStateVar
                    case channelState of
                        -- Channel is free and has no messages. Update waiting threads count, enter the wait state.
                        Free 0 threadsWaiting -> do
                            setThreadState' supervisor threadEntry $ Waiting SupervisedChannel
                            writeTVar channelStateVar $ Free 0 $ succ threadsWaiting
                            return Nothing
                        -- Channel is free and has messages. Put reciever lock to prevent other threads from stealing messages.
                        Free _ _ -> do
                            writeTVar channelStateVar RecieverLock
                            return $ Just channelState
                        -- Channel is busy, let's wait.
                        _ -> retry

                let finalise success = case stateIfLocked of
                        -- Channel was locked by the current thread
                        Just channelState -> case success of
                            -- Unlock channel and decrease message counter
                            True -> do
                                let (Free messagesPending threadsWaiting) = channelState
                                writeTVar channelStateVar $ Free (pred messagesPending) threadsWaiting
                            -- Just unlock the channel.
                            False -> writeTVar channelStateVar channelState
                        -- Channel was not locked and the thread was in waiting state.
                        Nothing -> do
                            setThreadState' supervisor threadEntry $ Runnable
                            currentState <- readTVar channelStateVar
                            case currentState of
                                -- Channel is free and success is false (possibly timeout termination)
                                (Free messagesPending threadsWaiting) | not success -> writeTVar channelStateVar $ Free messagesPending (pred threadsWaiting)
                                -- Channel is free and success is true. This should never happen, because in case of success sender will always wait notification.
                                (Free _ _) | success -> error "supervised-concurrency panic: channel state disrupted: waiting thread has recieved a message with no sender lock."
                                -- Reciever want reply from us
                                RecieverLock -> writeTVar channelStateVar $ RecieverReply success
                                -- some other sort of communication, ignore
                                _ -> retry

                message <- onException
                      ( lift reciever )
                      ( uninterruptibleMask_ $ whenNotTerminating $ finalise False )
                uninterruptibleMask_ $ whenNotTerminating $ finalise True
                return message
            case maybeRecieved of
                Just message -> return message
                Nothing -> throwIO ThreadKilled

    return $ Channel sendSupervised recieveSupervised

send :: (Monad m) => Channel s m a -> a -> SupervisedT s m ()
send (Channel sender _) = lift . sender

recieve :: (Monad m) => Channel s m a -> SupervisedT s m a
recieve (Channel _ reciever) = lift reciever
