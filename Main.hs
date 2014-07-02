{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception.Base (bracket)
import Control.Monad (forever, void)
import Data.Configurator
import Data.Maybe
import Data.Text hiding (filter, map)
import Network.AMQP
import Options.Applicative
import System.Directory
import System.FilePath
import System.INotify
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
            listenPath <- require p "fileIngest.incomingPath"
            host <- require p "amqp.connection.host"
            user <- require p "amqp.connection.username"
            pass <- require p "amqp.connection.password"
            conn <- openConnection host "/" user pass

            let q = queue o
            handleStartup listenPath conn q
            w <- addWatch i [CloseWrite] listenPath $ handleEvent listenPath conn q

            return (conn, w)
          release conn w = do
            removeWatch w
            closeConnection conn
          -- Blocks the main thread, watchers are separate threads
          block = forever (threadDelay 100000000000)

handleStartup :: FilePath -> Connection -> Text -> IO ()
handleStartup listenPath conn q = getDirectoryContents listenPath >>= publishPaths conn q . map (listenPath </>) . filter ((/= Just '.') . listToMaybe)

handleEvent :: FilePath -> Connection -> Text -> Event -> IO ()
handleEvent listenPath conn q = maybe (return ()) (publishPaths conn q . ((:[]) . (listenPath </>))) . maybeFilePath

publishPaths :: Connection -> Text -> [FilePath] -> IO ()
publishPaths conn q paths = do
  chan <- openChannel conn

  void $ declareQueue chan newQueue { queueName = q }

  mapM_ (publish chan) paths
  where publish :: Channel -> FilePath -> IO ()
        publish chan p = publishMsg chan "" q newMsg { msgBody = BL.pack p
                                                     , msgDeliveryMode = Just Persistent }
