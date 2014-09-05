{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception.Base (bracket)
import Control.Monad (MonadPlus, mfilter, forever, void)
import Data.Configurator
import Data.Maybe
import Data.Text hiding (filter, map)
import Network.AMQP
import Options.Applicative
import System.Directory
import System.FilePath
import System.INotify
import System.IO
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
notifier o i = do
  p <- load [Required $ conf o]
  listenPath <- require p "fileIngest.incomingPath"
  relative <- lookupDefault False p "fileIngest.inotify.relative"
  host <- require p "amqp.connection.host"
  user <- require p "amqp.connection.username"
  pass <- require p "amqp.connection.password"

  let q = queue o
      dayMicros = 24 * 60 * 60 * 1000 * 1000
      acquire = do
        conn <- openConnection host "/" user pass
        w <- addWatch i [CloseWrite, MoveIn] listenPath $ handleEvent relative listenPath conn q
        return (conn, w)
      release conn w = do
        removeWatch w
        closeConnection conn
      dailyStartup conn w = do
        handleStartup relative listenPath conn q
        -- Blocks the main thread, watchers are separate threads
        _ <- forever $ threadDelay dayMicros
        dailyStartup conn w

  bracket acquire (uncurry release) (uncurry dailyStartup)

type Relativize = Bool
type Prefix = FilePath

modifyPath :: Relativize -> Prefix -> FilePath -> FilePath
modifyPath r = if not r then (</>) else const id

handleStartup :: Relativize -> FilePath -> Connection -> Text -> IO ()
handleStartup r listenPath conn q = getDirectoryContents listenPath >>= publishPaths conn q . map (modifyPath r listenPath) . filterHidden

eventFilePath :: Event -> Maybe FilePath
eventFilePath (Closed _ f _) = f
eventFilePath (MovedIn _ f _) = Just f
eventFilePath _ = Nothing

handleEvent :: Relativize -> FilePath -> Connection -> Text -> Event -> IO ()
handleEvent r listenPath conn q event = do
  hPutStr stderr "Got event: "
  hPrint stderr event
  maybe (return ()) (publishPaths conn q . ((:[]) . (modifyPath r listenPath))) . filterHidden $ eventFilePath event

filterHidden :: MonadPlus m => m FilePath -> m FilePath
filterHidden = mfilter (maybe False (/= '.') . listToMaybe)

publishPaths :: Connection -> Text -> [FilePath] -> IO ()
publishPaths conn q paths = do
  chan <- openChannel conn

  void $ declareQueue chan newQueue { queueName = q }

  mapM_ (publish chan) paths
  where publish :: Channel -> FilePath -> IO ()
        publish chan p = publishMsg chan "" q newMsg { msgBody = BL.pack p
                                                     , msgDeliveryMode = Just Persistent }
