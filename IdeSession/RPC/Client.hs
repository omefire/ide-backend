{-# LANGUAGE TemplateHaskell, CPP, ScopedTypeVariables #-}
module IdeSession.RPC.Client (
    RpcServer
  , RpcConversation(..)
  , forkRpcServer
  , connectToRpcServer
  , rpc
  , rpcConversation
  , shutdown
  , forceShutdown
  , ExternalException(..)
  , illscopedConversationException
  , serverKilledException
  , getRpcExitCode
  ) where

import Control.Applicative ((<$>))
import Control.Concurrent.MVar (MVar, newMVar, tryTakeMVar)
import Control.Monad (void, unless)
import Data.Binary (Binary, encode, decode)
import Data.IORef (writeIORef, readIORef, newIORef)
import Data.Typeable (Typeable)
import Prelude hiding (take)
import System.Directory (canonicalizePath, getPermissions, executable)
import System.Exit (ExitCode)
import System.IO (Handle)
import System.Posix.IO (createPipe, closeFd, fdToHandle)
import System.Posix.Signals (signalProcess, sigKILL)
import System.Posix.Types (Fd)
import System.Process
  ( createProcess
  , proc
  , ProcessHandle
  , waitForProcess
  , CreateProcess(cwd, env)
  , getProcessExitCode
  )
import System.Process.Internals (withProcessHandle, ProcessHandle__(..))
import qualified Control.Exception as Ex
import qualified Data.ByteString.Lazy.Char8 as BSL

import IdeSession.Util.BlockingOps
import IdeSession.RPC.API
import IdeSession.RPC.Stream

--------------------------------------------------------------------------------
-- Client-side API                                                            --
--------------------------------------------------------------------------------

-- | Abstract data type representing RPC servers
data RpcServer = RpcServer {
    -- | Handle to write requests to
    rpcRequestW  :: Handle
    -- | Handle to read server errors from
  , rpcErrorsR   :: Handle
    -- | Handle on the server process itself
    --
    -- This is Nothing if we connected to an existing RPC server
    -- ('connectToRpcServer') rather than started a new server
    -- ('forkRpcServer')
  , rpcProc :: Maybe ProcessHandle
    -- | IORef containing the server response stream
  , rpcResponseR :: Stream Response
    -- | Server state
  , rpcState :: MVar RpcClientSideState
    -- | Identity of this server (for debugging purposes)
  , rpcIdentity :: String
  }

-- | RPC server state
data RpcClientSideState =
    -- | The server is running.
    RpcRunning
    -- | The server was stopped, either manually or because of an exception
  | RpcStopped Ex.SomeException

-- | Fork an RPC server as a separate process
--
-- @forkRpcServer exec args@ starts executable @exec@ with arguments
-- @args ++ args'@ where @args'@ are internal arguments generated by
-- 'forkRpcServer'. These internal arguments should be passed as arguments
-- to 'rpcServer'.
--
-- As a typical example, you might pass @["--server"]@ as @args@, and the
-- 'main' function of @exec@ might look like
--
-- > main = do
-- >   args <- getArgs
-- >   case args of
-- >     "--server" : args' ->
-- >       rpcServer args' <<your request handler>>
-- >     _ ->
-- >       <<deal with other cases>>
forkRpcServer :: FilePath        -- ^ Filename of the executable
              -> [String]        -- ^ Arguments
              -> Maybe FilePath  -- ^ Working directory
              -> Maybe [(String, String)] -- ^ Environment
              -> IO RpcServer
forkRpcServer path args workingDir menv = do
  (requestR,  requestW)  <- createPipe
  (responseR, responseW) <- createPipe
  (errorsR,   errorsW)   <- createPipe

  let showFd :: Fd -> String
      showFd fd = show (fromIntegral fd :: Int)

  let args' = args ++ map showFd [ requestR,  requestW
                                 , responseR, responseW
                                 , errorsR,   errorsW
                                 ]

  fullPath <- pathToExecutable path
  (Nothing, Nothing, Nothing, ph) <- createProcess (proc fullPath args') {
                                         cwd = workingDir,
                                         env = menv
                                       }

  -- Close the ends of the pipes that we're not using, and convert the rest
  -- to handles
  closeFd requestR
  closeFd responseW
  closeFd errorsW
  requestW'  <- fdToHandle requestW
  responseR' <- fdToHandle responseR
  errorsR'   <- fdToHandle errorsR

  st    <- newMVar RpcRunning
  input <- newStream responseR'
  return RpcServer {
      rpcRequestW  = requestW'
    , rpcErrorsR   = errorsR'
    , rpcProc      = Just ph
    , rpcState     = st
    , rpcResponseR = input
    , rpcIdentity  = path
    }
  where
    pathToExecutable :: FilePath -> IO FilePath
    pathToExecutable relPath = do
      fullPath    <- canonicalizePath relPath
      permissions <- getPermissions fullPath
      if executable permissions
        then return fullPath
        else Ex.throwIO . userError $ relPath ++ " not executable"

-- | Connect to an existing RPC server
--
-- It is the responsibility of the caller to make sure that each triplet
-- of named pipes is only used for RPC connection.
connectToRpcServer :: FilePath   -- ^ stdin named pipe
                   -> FilePath   -- ^ stdout named pipe
                   -> FilePath   -- ^ stderr named pipe
                   -> IO RpcServer
connectToRpcServer requestW responseR errorsR = do
  -- TODO: here and in forkRpcServer, deal with exceptions
  requestW'  <- openPipeForWriting requestW  timeout
  responseR' <- openPipeForReading responseR timeout
  errorsR'   <- openPipeForReading errorsR   timeout
  st         <- newMVar RpcRunning
  input      <- newStream responseR'
  return RpcServer {
      rpcRequestW  = requestW'
    , rpcErrorsR   = errorsR'
    , rpcProc      = Nothing
    , rpcState     = st
    , rpcResponseR = input
    , rpcIdentity  = requestW 
    }
  where
    timeout :: Int
    timeout = 1000000 -- 1sec

-- | Specialized form of 'rpcConversation' to do single request and wait for
-- a single response.
rpc :: (Typeable req, Typeable resp, Binary req, Binary resp) => RpcServer -> req -> IO resp
rpc server req = rpcConversation server $ \RpcConversation{..} -> put req >> get

-- | Run an RPC conversation. If the handler throws an exception during
-- the conversation the server is terminated.
rpcConversation :: RpcServer
                -> (RpcConversation -> IO a)
                -> IO a
rpcConversation server handler = withRpcServer server $ \st ->
  case st of
    RpcRunning -> do
      -- We want to be able to detect when a conversation is used out of scope
      inScope <- newIORef True

      -- Call the handler, update the state, and return the result
      a <- handler . conversation $ do isInScope <- readIORef inScope
                                       unless isInScope $
                                         Ex.throwIO illscopedConversationException

      -- Record that the conversation is no longer in scope and return
      writeIORef inScope False
      return (RpcRunning, a)
    RpcStopped ex ->
      Ex.throwIO ex
  where
    conversation :: IO () -> RpcConversation
    conversation verifyScope = RpcConversation {
        put = \req -> do
                 verifyScope
                 mapIOToExternal server $ do
                   let msg = encode $ Request (IncBS $ encode req)
                   hPutFlush (rpcRequestW server) msg
      , get = do verifyScope
                 mapIOToExternal server $ do
                   Response resp <- nextInStream (rpcResponseR server)
                   Ex.evaluate $ decode (unIncBS resp)
      }

illscopedConversationException :: Ex.IOException
illscopedConversationException =
  userError "Attempt to use RPC conversation outside its scope"

-- | Shut down the RPC server
--
-- This simply kills the remote process. If you want to shut down the remote
-- process cleanly you must implement your own termination protocol before
-- calling 'shutdown'.
shutdown :: RpcServer -> IO ()
shutdown server = withRpcServer server $ \_ -> do
  terminate server
  let ex = Ex.toException (userError "Manual shutdown")
  return (RpcStopped ex, ())

-- | Force shutdown.
--
-- In order to faciliate a force shutdown while another thread may be
-- communicating with the RPC server, we _try_ to update the MVar underlying
-- the RPC server, but if we fail, we terminate the server anyway. This means
-- that this may leave the 'RpcServer' in an invalid state -- so you shouldn't
-- be using it anymore after calling forceShutdown!
forceShutdown :: RpcServer -> IO ()
forceShutdown server = Ex.mask_ $ do
  mst <- tryTakeMVar (rpcState server)

  ignoreAllExceptions $ forceTerminate server
  let ex = Ex.toException (userError "Forced manual shutdown")

  case mst of
    Nothing -> -- We failed to take the MVar. Shrug.
      return ()
    Just _ ->
      $putMVar (rpcState server) (RpcStopped ex)

-- | Silently ignore all exceptions
ignoreAllExceptions :: IO () -> IO ()
ignoreAllExceptions = Ex.handle ignore
  where
    ignore :: Ex.SomeException -> IO ()
    ignore _ = return ()

-- | Terminate the RPC connection
--
-- If we connected using 'forkRpcServer' (rather than 'connectToRpcServer')
-- we wait for the remote process to terminate.
terminate :: RpcServer -> IO ()
terminate server = do
    ignoreIOExceptions $ hPutFlush (rpcRequestW server) (encode RequestShutdown)
    case rpcProc server of
      Just ph -> void $ waitForProcess ph
      Nothing -> return ()

-- | Force-terminate the external process
--
-- Throws an exception when we are connected to an existing RPC server
forceTerminate :: RpcServer -> IO ()
forceTerminate server =
    case rpcProc server of
      Just ph ->
        withProcessHandle ph $ \p_ ->
          case p_ of
            ClosedHandle _ ->
              leaveHandleAsIs p_
            OpenHandle pID -> do
              signalProcess sigKILL pID
              leaveHandleAsIs p_
      Nothing ->
        Ex.throwIO $ userError "forceTerminate: parallel connection"
  where
    leaveHandleAsIs _p =
#if MIN_VERSION_process(1,2,0)
      return ()
#else
      return (_p, ())
#endif

-- | Like modifyMVar, but terminate the server on exceptions
withRpcServer :: RpcServer
              -> (RpcClientSideState -> IO (RpcClientSideState, a))
              -> IO a
withRpcServer server io =
  Ex.mask $ \restore -> do
    st <- $takeMVar (rpcState server)

    mResult <- Ex.try $ restore (io st)

    case mResult of
      Right (st', a) -> do
        $putMVar (rpcState server) st'
        return a
      Left ex -> do
   --     terminate server
        $putMVar (rpcState server) (RpcStopped (Ex.toException (userError (rpcIdentity server ++ ": " ++ show (ex :: Ex.SomeException)))))
        Ex.throwIO ex

-- | Get the exit code of the RPC server, unless still running.
--
-- Thross an exception for connections to existing RPC servers.
getRpcExitCode :: RpcServer -> IO (Maybe ExitCode)
getRpcExitCode RpcServer{rpcProc} =
  case rpcProc of
    Just ph -> getProcessExitCode ph
    Nothing -> Ex.throwIO $ userError "getRpcExitCode: parallel connection"

{------------------------------------------------------------------------------
  Aux
------------------------------------------------------------------------------}

-- | Map IO exceptions to external exceptions, using the error written
-- by the server (if any)
mapIOToExternal :: RpcServer -> IO a -> IO a
mapIOToExternal server p = Ex.catch p $ \ex -> do
  let _ = ex :: Ex.IOException
  merr <- BSL.unpack <$> BSL.hGetContents (rpcErrorsR server)
  if null merr
    then Ex.throwIO (serverKilledException (Just ex))
    else Ex.throwIO (ExternalException merr (Just ex))

