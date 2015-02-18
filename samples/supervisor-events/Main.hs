{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Main where

import           Control.Concurrent
import           Control.Concurrent.Supervised
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.Trans.Control

worker1 :: (MonadBaseControl IO m) => SupervisedT s m ()
worker1 = do
    liftBase $ threadDelay 1000000
    void $ spawn worker2
    liftBase $ putStrLn $ "worker1 done."

worker2 :: (MonadBase IO m) => SupervisedT s m ()
worker2 = liftBase $ do
    threadDelay 1000000
    putStrLn $ "worker2 done."

main :: IO ()
main = do
    runSupervisedT $ do
        void $ spawn worker1
        waitTill NoRunningThreads
    putStrLn "All threads terminated. Press any key to exit."
    void $ getChar