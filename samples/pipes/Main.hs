{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}

module Main where

import           Control.Concurrent            (threadDelay, ThreadId)
import           Control.Concurrent.Supervised
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Maybe
import           Pipes
import qualified Pipes.Concurrent              as Pipes

newChannel :: (MonadBaseControl IO m) => Pipes.Buffer a -> SupervisedT s m (Sender s (MaybeT IO) a, Receiver s (MaybeT IO) a)
newChannel buffer = fmap simplify (newChannel' buffer)
    where simplify (sender, reciever, _) = (sender, reciever)

newChannel' :: (MonadBaseControl IO m) => Pipes.Buffer a -> SupervisedT s m (Sender s (MaybeT IO) a, Receiver s (MaybeT IO) a, IO ())
newChannel' buffer = do
    (o, i, s) <- liftBase $ Pipes.spawn' buffer

    let sender message = MaybeT $ do
            sent <- Pipes.atomically $ Pipes.send o message
            return $ if sent then Just ()
                             else Nothing

        reciever = MaybeT $ Pipes.atomically $ Pipes.recv i

        sealer = Pipes.atomically s

    Channel registeredSender registeredReciever <- registerChannel $ Channel sender reciever
    return (registeredSender, registeredReciever, sealer)

send :: (MonadBase IO m) => Sender s (MaybeT IO) a -> a -> SupervisedT s m Bool
send sender = liftM (maybe False $ const True) . liftBase . runMaybeT . sender

recv :: (MonadBase IO m) => Receiver s (MaybeT IO) a -> SupervisedT s m (Maybe a)
recv reciever = liftBase $ runMaybeT reciever

seal :: (MonadBase IO m) => IO () -> SupervisedT s m ()
seal = liftBase

fromInput :: (MonadBase IO m) => Receiver s (MaybeT IO) a -> Producer' a (SupervisedT s m) ()
fromInput reciever = loop
    where
        loop = do
            ma <- lift $ recv reciever
            case ma of
                Nothing -> return ()
                Just a  -> do
                    yield a
                    loop

toOutput :: (MonadBase IO m) => Sender s (MaybeT IO) a -> Consumer' a (SupervisedT s m) ()
toOutput sender = loop
  where
    loop = do
        a     <- await
        alive <- lift $ send sender a
        when alive loop

consumer :: (MonadIO m) => Consumer Int (SupervisedT s m) ()
consumer = do
    liftIO $ threadDelay 100000
    liftIO $ putStrLn $ "consumer started"
    forever $ do
        a <- await
        liftIO $ do
            putStrLn $ "Got message " ++ (show a)
            threadDelay 200000

producer :: (MonadIO m) => Producer Int (SupervisedT s m) ()
producer = do
    liftIO $ threadDelay 200000
    liftIO $ putStrLn $ "producer started"
    forM_ [0..9] $ \a -> do
        liftIO $ putStrLn $ "Sending message " ++ (show a)
        yield a
        liftIO $ threadDelay 100000

tracer  :: (MonadBaseControl IO m) => ThreadId -> ThreadState -> SupervisedT s m ()
tracer threadId prevState = do
    maybeInfo <- waitTill $ ThreadState threadId (\info -> if _threadState info /= prevState then Just info else Nothing)
    case maybeInfo of
        Nothing -> return ()
        Just info -> do
            liftBase $ print info
            tracer threadId (_threadState info)

main :: IO ()
main = do
    runSupervisedT $ do
        (output, input) <- newChannel Pipes.Unbounded
        consumerId <- spawnNamed "consumer" $ runEffect (fromInput input >-> consumer)
        void $ spawnNamed "tracer1" $ tracer consumerId Unstarted
        producerId <- spawnNamed "producer" $ runEffect (producer >-> toOutput output)
        void $ spawnNamed "tracer2" $ tracer producerId Unstarted
        waitTill NoRunningThreads
    putStrLn "All threads terminated"
