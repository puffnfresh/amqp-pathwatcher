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
import Data.Configurator
import qualified Data.ByteString.Lazy.Char8 as BL

data MainOpts = MainOpts
    { conf :: FilePath
    , queue :: Text
    }

mainOpts :: Parser MainOpts
mainOpts = MainOpts
           <$> (strOption $ short 'c' <> metavar "CONFIG" <> help "Configuration file")
           <*> fmap pack (argument str $ metavar "QUEUE" <> help "AMQP queue name")

longHelp :: Parser (a -> a)
longHelp = abortOption ShowHelpText (long "help" <> hidden)

opts :: ParserInfo MainOpts
opts = info (longHelp <*> mainOpts) $ fullDesc <> progDesc "Dump close_write inotify events onto an AMQP queue."

main :: IO ()
main = execParser opts >>= withINotify . notifier

notifier :: MainOpts -> INotify -> IO ()
notifier o i = bracket acquire (uncurry release) (const block)
    where acquire = do
            p <- load [Required $ conf o]
            listenPath <- require p "incoming.path"
            host <- require p "amqp.connection.host"
            user <- require p "amqp.connection.username"
            pass <- require p "amqp.connection.password"
            conn <- openConnection host "/" user pass
            w <- addWatch i [CloseWrite] listenPath $ handleEvent listenPath (queue o) conn
            return (conn, w)
          release conn w = do
            removeWatch w
            closeConnection conn
          -- Blocks the main thread, watchers are separate threads
          block = newEmptyMVar >>= takeMVar

handleEvent :: FilePath -> Text -> Connection -> Event -> IO ()
handleEvent listenPath q conn = maybe (return ()) handlePath . maybeFilePath
  where handlePath :: FilePath -> IO ()
        handlePath path = do
          chan <- openChannel conn

          void $ declareQueue chan newQueue { queueName = q }

          let wholePath = listenPath </> path
          publishMsg chan "" q newMsg { msgBody = BL.pack wholePath
                                              , msgDeliveryMode = Just Persistent }
