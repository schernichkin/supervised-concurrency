{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Main where

import           Control.Concurrent
import           Control.Concurrent.Supervised
import           Control.Monad
import           Control.Monad.Base

worker :: (MonadBase IO m) => String -> SupervisedT s m ()
worker name = go
    where
        go = do
            liftBase $ do
                putStrLn $ "hello from worker " ++ name
                threadDelay 1000000
            go

main :: IO ()
main = do
    runSupervisedT $ do
        spawn $ worker "worker 1"
        spawn $ worker "worker 2"
        liftBase $ do
            putStrLn "Press any key to terminate.."
            void $ getChar
    putStrLn "All threads terminated. Press any key to exit."
    void $ getChar