{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Main where

import           Control.Concurrent
import           Control.Concurrent.Supervised
import           Control.Monad
import           Control.Monad.Base

worker1 :: (MonadSupervisor m) => m ()
worker1 = do
    liftBase $ threadDelay 1000000
    void $ spawn worker2
    threadId <- spawn worker2
    liftBase $ do
        killThread threadId -- note you may use haskell functions to kill supervised thread
        putStrLn $ "worker1 done."

worker2 :: (MonadBase IO m) => m ()
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