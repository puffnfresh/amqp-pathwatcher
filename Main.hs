{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Concurrent         (threadDelay)
import           Control.Exception.Base     (bracket)
import           Control.Monad              (MonadPlus, filterM, forever, join,
                                             mfilter, void)
import qualified Data.ByteString.Lazy.Char8 as BL
import           Data.Configurator
import           Data.Maybe
import           Data.Text                  hiding (filter, map)
import           Network.AMQP
import           Options.Applicative
import           System.Directory
import           System.FilePath
import           System.INotify             hiding (isDirectory)
import           System.IO
import           System.Log.Formatter       (simpleLogFormatter)
import           System.Log.Handler         (setFormatter)
import           System.Log.Handler.Simple  (streamHandler)
import           System.Log.Logger
import qualified System.Posix.Files         as F
import           System.Remote.Monitoring   (forkServer)

data MainOpts = MainOpts
    { conf  :: FilePath
    , queue :: Text
    }

mainOpts :: Parser MainOpts
mainOpts = MainOpts
           <$> strOption (short 'c' <> metavar "CONFIG" <> help "Configuration file")
           <*> fmap pack (argument str $ metavar "QUEUE" <> help "AMQP queue name")

longHelp :: Parser (a -> a)
longHelp = abortOption ShowHelpText (long "help" <> hidden)

opts :: ParserInfo MainOpts
opts = info (longHelp <*> mainOpts) $ fullDesc <> progDesc "Dump close_write inotify events onto an AMQP queue."

main :: IO ()
main = forkServer "0.0.0.0" 8354 >> execParser opts >>= withINotify . notifier

microsFromHours :: Int -> Int
microsFromHours = (60 * 60 * 1000 * 1000 *)

isDirectory :: FilePath -> IO Bool
isDirectory = fmap F.isDirectory . F.getFileStatus

isRegularFile :: FilePath -> IO Bool
isRegularFile = fmap F.isRegularFile . F.getFileStatus

toAbsolute :: (Functor m, MonadPlus m) => FilePath -> m FilePath -> m FilePath
toAbsolute path = fmap (path </>) . filterHidden

absoluteContents :: FilePath -> IO [FilePath]
absoluteContents path = toAbsolute path <$> getDirectoryContents path

recursiveDirectories :: FilePath -> IO [FilePath]
recursiveDirectories path = do
  contents <- absoluteContents path
  directories <- filterM isDirectory contents
  rest <- mapM recursiveDirectories directories
  return (path:join rest)

notifier :: MainOpts -> INotify -> IO ()
notifier o i = do
  p <- load [Required $ conf o]
  listenPath <- require p "fileIngest.incomingPath"
  delayMicros <- microsFromHours <$> lookupDefault 12 p "fileIngest.delayedRequeueHours"
  relative <- lookupDefault False p "fileIngest.inotify.relative"
  host <- require p "amqp.connection.host"
  user <- require p "amqp.connection.username"
  pass <- require p "amqp.connection.password"
  vhost <- lookupDefault "/" p "amqp.connection.virtualHost"

  logHandler <- streamHandler stderr DEBUG
  let formatHandler' = setFormatter logHandler $ simpleLogFormatter "$time [$prio] $loggername - $msg"
  updateGlobalLogger rootLoggerName removeHandler
  updateGlobalLogger "amqp-pathwatcher" (setLevel DEBUG . setHandlers [formatHandler'])

  let q = queue o
      acquire = do
        infoM "amqp-pathwatcher" $ "Openning connection to " ++ host ++ " on vhost " ++ unpack vhost
        conn <- openConnection host vhost user pass
        infoM "amqp-pathwatcher" $ "Adding watchers to " ++ listenPath
        toWatch <- recursiveDirectories listenPath
        addConnectionClosedHandler conn True (warningM "amqp-pathwatcher" "AMQP connection closed")
        ws <- mapM (\d -> addWatch i [CloseWrite, MoveIn] d (handleEvent relative listenPath d conn q)) toWatch
        return (conn, toWatch, ws)
      release conn _ ws = do
        mapM_ removeWatch ws
        closeConnection conn
      queueAndBlock conn dirs = do
        infoM "amqp-pathwatcher" $ "Doing an initial queueing of all files in " ++ listenPath
        mapM_ (\d -> queueContents relative listenPath d conn q) dirs
        -- Blocks the main thread, watchers are separate threads
        threadDelay delayMicros

  -- Open a new connection to AMQP and a new inotify handle every delayedRequeueHours
  forever $ bracket acquire (\(a, b, c) -> release a b c) (\(a, b, _) -> queueAndBlock a b)

type Relativize = Bool
type Prefix = FilePath

modifyPath :: Relativize -> Prefix -> FilePath -> FilePath
modifyPath r = if r then makeRelative else const id

queueContents :: Relativize -> FilePath -> FilePath -> Connection -> Text -> IO ()
queueContents r listenPath path conn q =
  absoluteContents path >>=
  filterM isRegularFile >>=
  publishPaths conn q . fmap (modifyPath r listenPath)

eventFilePath :: Event -> Maybe FilePath
eventFilePath (Closed _ f _) = f
eventFilePath (MovedIn _ f _) = Just f
eventFilePath _ = Nothing

handleEvent :: Relativize -> FilePath -> FilePath -> Connection -> Text -> Event -> IO ()
handleEvent r listenPath path conn q event = do
  infoM "amqp-pathwatcher" $ "Got event: " ++ show event
  maybe (return ()) (publishPaths conn q . (:[]) . modifyPath r listenPath) . toAbsolute path $ eventFilePath event

filterHidden :: MonadPlus m => m FilePath -> m FilePath
filterHidden = mfilter (maybe False (/= '.') . listToMaybe)

publishPaths :: Connection -> Text -> [FilePath] -> IO ()
publishPaths conn q paths = do
  chan <- openChannel conn
  addReturnListener chan (infoM "amqp-pathwatcher" . ("Response: " ++) . show)
  void $ declareQueue chan newQueue { queueName = q }
  mapM_ (publish chan) paths
  closeChannel chan
  where publish :: Channel -> FilePath -> IO ()
        publish chan p = publishMsg chan "" q newMsg { msgBody = BL.pack p
                                                     , msgDeliveryMode = Just Persistent }
