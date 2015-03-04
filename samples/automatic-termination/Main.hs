{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Main where

import           Control.Concurrent
import           Control.Concurrent.Supervised
import           Control.Monad
import           Control.Monad.Base

worker :: (MonadSupervisor m) => m ()
worker = do
    (Just name) <- getThreadName
    liftBase $ do
        putStrLn $ "hello from worker " ++ name
        threadDelay 1000000
    worker

main :: IO ()
main = do
    runSupervisedT $ do
        void $ spawnNamed "worker 1" worker
        void $ spawnNamed "worker 2" worker
        liftBase $ do
            putStrLn "Press any key to terminate.."
            void $ getChar
    putStrLn "All threads terminated. Press any key to exit."
    void $ getChar