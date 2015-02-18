{-# LANGUAGE MonomorphismRestriction #-}
{-# LANGUAGE MonomorphismRestriction #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}

-- | Main entry point to the application.
module Main where

import Pipes
import Pipes.Core
import Pipes.Concurrent
import Pipes.Internal
import Control.Concurrent.Supervised as S
import Control.Monad.IO.Class
import Control.Monad.Error
import Control.Concurrent.STM
import Control.Monad.Trans.Control

-- adaptors for input/output

data MailboxError = MailboxSealed deriving ( Show )

instance Error MailboxError where

toSender :: (MonadIO m, MonadError MailboxError m) => Output a -> Sender m a
toSender output = \message -> do
    alive <- liftIO $ atomically $ send output message
    if alive then return ()
             else throwError MailboxSealed

toReciever :: (MonadIO m, MonadError MailboxError m) => Input a -> Receiver m a
toReciever input = do
    ma <- liftIO $ atomically $ recv input
    case ma of
        Just a -> return a
        Nothing -> throwError MailboxSealed


-- adaptor - event processor to pipe
{-
toHandler :: (Monad m) => Consumer SupervisorEvent m a -> SupervisorEventHandler m a
toHandler = go
    where
        go (Request () f) = Consume $ \event -> go $ f event
        go (Respond _ f)  = go $ f () -- consumer should never respond, but still we can handle it (ignore respond)
        go (M action)     = Execute $ action >>= return . go
        go (Pure result)  = Done result
-}
-- hujnya

test :: (MonadError MailboxError m, MonadIO m, MonadBaseControl IO m) => SupervisedT s m ()
test = do
    (i1, o1, s1) <- liftIO $ spawn' Unbounded
    channel@(SupervisedChannel si1 so1) <- registerChannel $ Channel (toSender i1) (toReciever o1)
    -- S.spawn $ test2 so1
    -- sendSupervised si1 (10 :: Int)
    return ()

test2 :: (MonadError MailboxError m, MonadIO m) => SupervisedReciever s m a -> SupervisedT s m a
test2 rec = do
    a <- recieveSupervised rec
    return a
{-
--testHandler :: (MonadError MailboxError m, MonadIO m, MonadBaseControl IO (SupervisedT s m)) => SupervisorEventHandler (SupervisedT s m) a
testHandler =  replicateM_ 10 $ do
    event <- await
    (i1, o1, s1) <- liftIO $ spawn' Unbounded
    channel@(SupervisedChannel si1 so1) <- lift $ registerChannel $ Channel (toSender i1) (toReciever o1)
    -- lift $ S.spawn $ test2 so1
    liftIO $ print event
-}
-- | The main entry point.
main :: IO ()
main = do
    -- runErrorT $ runEventHandler (toHandler testHandler)
    putStrLn "Welcome to FP Haskell Center!"
    putStrLn "Have a good day!"
