{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent.MVar (newEmptyMVar, takeMVar)
import Control.Exception.Base (bracket)
import Control.Monad (void)
import Data.Text
import Network.AMQP
import Options.Applicative
import System.FilePath
import System.INotify
import qualified Data.ByteString.Lazy.Char8 as BL

data PathWatcher = PathWatcher
    { host :: String
    , user :: Text
    , pass :: Text
    , queue :: Text
    , listenPath :: FilePath
    }

pathWatcher :: Parser PathWatcher
pathWatcher = PathWatcher
              <$> strOption (short 'h' <> metavar "HOST" <> help "AMQP host")
              <*> fmap pack (strOption $ short 'u' <> metavar "USER" <> help "AMQP username")
              <*> fmap pack (strOption $ short 'p' <> metavar "PASS" <> help "AMQP password")
              <*> fmap pack (strOption $ short 'q' <> metavar "QUEUE" <> help "AMQP queue name")
              <*> argument str (metavar "DIRECTORY" <> help "Path to listen for close_write events")

longHelp :: Parser (a -> a)
longHelp = abortOption ShowHelpText (long "help" <> hidden)

opts :: ParserInfo PathWatcher
opts = info (longHelp <*> pathWatcher) $ fullDesc <> progDesc "Dump close_write inotify events onto an AMQP queue."

main :: IO ()
main = execParser opts >>= withINotify . notifier

notifier :: PathWatcher -> INotify -> IO ()
notifier p i = bracket acquire (uncurry release) (const block)
    where acquire = do
            conn <- openConnection (host p) "/" (user p) (pass p)
            w <- addWatch i [CloseWrite] (listenPath p) $ handleEvent p conn
            return (conn, w)
          release conn w = do
            removeWatch w
            closeConnection conn
          -- Blocks the main thread, watchers are separate threads
          block = newEmptyMVar >>= takeMVar

handleEvent :: PathWatcher -> Connection -> Event -> IO ()
handleEvent p conn = maybe (return ()) handlePath . maybeFilePath
  where handlePath :: FilePath -> IO ()
        handlePath path = do
          chan <- openChannel conn

          void $ declareQueue chan newQueue { queueName = queue p }

          let wholePath = listenPath p </> path
          publishMsg chan "" (queue p) newMsg { msgBody = BL.pack wholePath
                                              , msgDeliveryMode = Just Persistent }
