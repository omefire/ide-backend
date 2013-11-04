{-# LANGUAGE FlexibleContexts, GeneralizedNewtypeDeriving #-}
-- | IDE session updates
--
-- We should only be using internal types here (explicit strictness/sharing)
module IdeSession.Update (
    -- * Starting and stopping
    initSession
  , SessionInitParams(..)
  , defaultSessionInitParams
  , shutdownSession
  , restartSession
    -- * Session updates
  , IdeSessionUpdate -- Abstract
  , updateSession
  , updateSourceFile
  , updateSourceFileFromFile
  , updateSourceFileDelete
  , updateGhcOptions
  , updateCodeGeneration
  , updateDataFile
  , updateDataFileFromFile
  , updateDataFileDelete
  , updateEnv
  , updateArgs
  , updateStdoutBufferMode
  , updateStderrBufferMode
  , buildExe
  , buildDoc
  , buildLicenses
    -- * Running code
  , runStmt
  , resume
  , setBreakpoint
  , printVar
    -- * Debugging
  , forceRecompile
  , crashGhcServer
  , buildLicsFromPkgs
  )
  where

import Prelude hiding (mod, span)
import Control.Monad (when, void, forM, unless)
import Control.Monad.State (MonadState, StateT, runStateT)
import Control.Monad.Reader (MonadReader, ReaderT, runReaderT, asks)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Applicative (Applicative, (<$>), (<*>))
import qualified Control.Exception as Ex
import Data.List (delete, elemIndices, intercalate)
import Data.Monoid (Monoid(..))
import Data.Accessor ((.>), (^.), (^=))
import Data.Accessor.Monad.MTL.State (get, modify, set)
import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.ByteString.Char8 as BSS
import Data.Maybe (fromMaybe, catMaybes)
import Data.Foldable (forM_)
import qualified System.Directory as Dir
import System.FilePath (
    takeDirectory
  , makeRelative
  , (</>)
  , splitSearchPath
  , searchPathSeparator
  , takeExtension
  , replaceExtension
  , takeFileName
  , dropFileName
  )
import System.Posix.Files (setFileTimes)
import System.IO.Temp (createTempDirectory)
import System.IO.Error (isDoesNotExistError)
import qualified Data.Text as Text
import System.Environment (getEnv, getEnvironment)
import Data.Version (Version(..))
import System.Cmd (system)
import System.Exit (ExitCode(..))

import Distribution.Simple (PackageDBStack, PackageDB(..))

import IdeSession.State
import IdeSession.Cabal
import IdeSession.Config
import IdeSession.GHC.API
import IdeSession.GHC.Client
import IdeSession.Types.Private hiding (RunResult(..))
import IdeSession.Types.Public (RunBufferMode(..))
import IdeSession.Types.Translation (removeExplicitSharing)
import qualified IdeSession.Types.Private as Private
import qualified IdeSession.Types.Public  as Public
import IdeSession.Types.Progress
import IdeSession.Util
import IdeSession.Strict.Container
import IdeSession.RPC.Client (ExternalException)
import qualified IdeSession.Strict.IntMap as IntMap
import qualified IdeSession.Strict.Map    as Map
import qualified IdeSession.Strict.Maybe  as Maybe
import qualified IdeSession.Strict.List   as List
import qualified IdeSession.Strict.Trie   as Trie
import IdeSession.Strict.MVar

{------------------------------------------------------------------------------
  Starting and stopping
------------------------------------------------------------------------------}

-- | How should the session be initialized?
--
-- Client code should use 'defaultSessionInitParams' to protect itself against
-- future extensions of this record.
data SessionInitParams = SessionInitParams {
    -- | Previously computed cabal macros,
    -- or 'Nothing' to compute them on startup
    sessionInitCabalMacros :: Maybe BSL.ByteString
  }

defaultSessionInitParams :: SessionInitParams
defaultSessionInitParams = SessionInitParams {
    sessionInitCabalMacros = Nothing
  }

-- | Create a fresh session, using some initial configuration.
--
-- Throws an exception if the configuration is invalid, or if GHC_PACKAGE_PATH
-- is set.
initSession :: SessionInitParams -> SessionConfig -> IO IdeSession
initSession initParams ideConfig@SessionConfig{..} = do
  verifyConfig ideConfig

  -- TODO: Don't hardcode ghc version
  let ghcOpts = configStaticOpts
             ++ packageDbArgs (Version [7,4,2] []) configPackageDBStack

  configDirCanon <- Dir.canonicalizePath configDir
  ideSourcesDir  <- createTempDirectory configDirCanon "src."
  ideDataDir     <- createTempDirectory configDirCanon "data."
  ideDistDir     <- createTempDirectory configDirCanon "dist."
  env            <- envWithPathOverride configExtraPathDirs
  _ideGhcServer  <- forkGhcServer configGenerateModInfo ghcOpts
                                  (Just ideDataDir) env configInProcess
  -- The value of _ideLogicalTimestamp field is a workaround for
  -- the problems with 'invalidateModSummaryCache', which itself is
  -- a workaround for http://hackage.haskell.org/trac/ghc/ticket/7478.
  -- We have to make sure that file times never reach 0, because this will
  -- trigger an exception (http://hackage.haskell.org/trac/ghc/ticket/7567).
  -- We rather arbitrary start at Jan 2, 1970.
  ideState <- newMVar $ IdeSessionIdle IdeIdleState {
                          _ideLogicalTimestamp = 86400
                        , _ideComputed         = Maybe.nothing
                        , _ideNewOpts          = Nothing
                        , _ideGenerateCode     = False
                        , _ideManagedFiles     = ManagedFilesInternal [] []
                        , _ideObjectFiles      = []
                        , _ideBuildExeStatus   = Nothing
                        , _ideBuildDocStatus   = Nothing
                        , _ideBuildLicensesStatus = Nothing
                        , _ideEnv              = []
                        , _ideArgs             = []
                        , _ideUpdatedEnv       = False
                        , _ideUpdatedArgs      = False -- Server default is []
                          -- Make sure 'ideComputed' is set on first call
                          -- to updateSession
                        , _ideUpdatedCode      = True
                        , _ideStdoutBufferMode = RunNoBuffering
                        , _ideStderrBufferMode = RunNoBuffering
                        , _ideBreakInfo        = Maybe.nothing
                        , _ideGhcServer
                        }
  let ideStaticInfo = IdeStaticInfo{..}
  let session = IdeSession{..}

  execInitParams ideStaticInfo initParams

  return session

-- | Set up the initial state of the session according to the given parameters
execInitParams :: IdeStaticInfo -> SessionInitParams -> IO ()
execInitParams staticInfo SessionInitParams{..} = do
  -- TODO: for now, this location is safe, but when the user
  -- is allowed to overwrite .h files, we need to create an extra dir.
  writeMacros staticInfo sessionInitCabalMacros

-- | Verify configuration, and throw an exception if configuration is invalid
verifyConfig :: SessionConfig -> IO ()
verifyConfig SessionConfig{..} = do
    unless (isValidPackageDB configPackageDBStack) $
      Ex.throw . userError $ "Invalid package DB stack: "
                          ++ show configPackageDBStack

    checkPackageDbEnvVar
  where
    isValidPackageDB :: PackageDBStack -> Bool
    isValidPackageDB stack =
          elemIndices GlobalPackageDB stack == [0]
       && elemIndices UserPackageDB stack `elem` [[], [1]]

-- Copied directly from Cabal
checkPackageDbEnvVar :: IO ()
checkPackageDbEnvVar = do
    hasGPP <- (getEnv "GHC_PACKAGE_PATH" >> return True)
              `catchIO` (\_ -> return False)
    when hasGPP $
      die $ "Use of GHC's environment variable GHC_PACKAGE_PATH is "
         ++ "incompatible with Cabal. Use the flag --package-db to specify a "
         ++ "package database (it can be used multiple times)."
  where
    -- Definitions so that the copied code from Cabal works

    die = Ex.throwIO . userError

    catchIO :: IO a -> (IOError -> IO a) -> IO a
    catchIO = Ex.catch

envWithPathOverride :: [FilePath] -> IO (Maybe [(String, String)])
envWithPathOverride []            = return Nothing
envWithPathOverride extraPathDirs = do
    env <- getEnvironment
    let path  = fromMaybe "" (lookup "PATH" env)
        path' = intercalate [searchPathSeparator]
                  (splitSearchPath path ++ extraPathDirs)
        env'  = ("PATH", path') : filter (\(var, _) -> var /= "PATH") env
    return (Just env')

-- | Write per-package CPP macros.
writeMacros :: IdeStaticInfo -> Maybe BSL.ByteString -> IO ()
writeMacros IdeStaticInfo{ ideConfig = SessionConfig {..}
                         , ideDistDir
                         }
            configCabalMacros = do
  macros <- case configCabalMacros of
              Nothing     -> generateMacros configPackageDBStack configExtraPathDirs
              Just macros -> return (BSL.unpack macros)
  writeFile (cabalMacrosLocation ideDistDir) macros

-- | Close a session down, releasing the resources.
--
-- This operation is the only one that can be run after a shutdown was already
-- performed. This lets the API user execute an early shutdown, e.g., before
-- the @shutdownSession@ placed inside 'bracket' is triggered by a normal
-- program control flow.
--
-- If code is still running, it will be interrupted.
shutdownSession :: IdeSession -> IO ()
shutdownSession IdeSession{ideState, ideStaticInfo} = do
  snapshot <- modifyMVar ideState $ \state -> return (IdeSessionShutdown, state)
  case snapshot of
    IdeSessionRunning runActions idleState -> do
      -- We need to terminate the running program before we can shut down
      -- the session, because the RPC layer will sequentialize all concurrent
      -- calls (and if code is still running we still have an active
      -- RPC conversation)
      interrupt runActions
      void $ runWaitAll runActions
      shutdownGhcServer $ _ideGhcServer idleState
      cleanupDirs
    IdeSessionIdle idleState -> do
      shutdownGhcServer $ _ideGhcServer idleState
      cleanupDirs
    IdeSessionShutdown ->
      return ()
    IdeSessionServerDied _ _ ->
      cleanupDirs
 where
  cleanupDirs = do
    let dataDir    = ideDataDir ideStaticInfo
        sourcesDir = ideSourcesDir ideStaticInfo
    -- TODO: this has a race condition (not sure we care; if not, say why not)
    dataExists <- Dir.doesDirectoryExist dataDir
    when dataExists $ Dir.removeDirectoryRecursive dataDir
    sourceExists <- Dir.doesDirectoryExist sourcesDir
    when sourceExists $ Dir.removeDirectoryRecursive sourcesDir

-- | Restarts a session. Technically, a new session is created under the old
-- @IdeSession@ handle, with a state cloned from the old session,
-- which is then shut down. The only behavioural difference between
-- the restarted session and the old one is that any running code is stopped
-- (even if it was stuck and didn't respond to interrupt requests)
-- and that no modules are loaded, though all old modules and data files
-- are still contained in the new session and ready to be compiled with
-- the same flags and environment variables as before.
--
-- (We don't automatically recompile the code using the new session, because
-- what would we do with the progress messages?)
--
-- If the environment changed, you should pass in new 'SessionInitParams';
-- otherwise, pass 'Nothing'.
restartSession :: IdeSession -> Maybe SessionInitParams -> IO ()
restartSession IdeSession{ideStaticInfo, ideState} mInitParams = do
    -- Reflect changes in the environment, if any
    forM_ mInitParams (execInitParams ideStaticInfo)

    -- Restart the session
    modifyMVar_ ideState $ \state ->
      case state of
        IdeSessionIdle idleState ->
          restart idleState
        IdeSessionRunning runActions idleState -> do
          forceCancel runActions
          restart idleState
        IdeSessionShutdown ->
          fail "Shutdown session cannot be restarted."
        IdeSessionServerDied _externalException idleState ->
          restart idleState
  where
    restart :: IdeIdleState -> IO IdeSessionState
    restart idleState = do
      forceShutdownGhcServer $ _ideGhcServer idleState
      env    <- envWithPathOverride configExtraPathDirs
      let ghcOpts = configStaticOpts
                 ++ packageDbArgs (Version [7,4,2] []) configPackageDBStack
      server <-
        forkGhcServer
          configGenerateModInfo ghcOpts workingDir env configInProcess
      return . IdeSessionIdle
             . (ideComputed    ^= Maybe.nothing)
             . (ideUpdatedEnv  ^= True)
             . (ideUpdatedArgs ^= True)
             . (ideUpdatedCode ^= True)
             . (ideGhcServer   ^= server)
             $ idleState

    workingDir = Just (ideDataDir ideStaticInfo)
    SessionConfig{..} = ideConfig ideStaticInfo

{------------------------------------------------------------------------------
  Session updates
------------------------------------------------------------------------------}

-- | We use the 'IdeSessionUpdate' type to represent the accumulation of a
-- bunch of updates.
--
-- In particular it is an instance of 'Monoid', so multiple primitive updates
-- can be easily combined. Updates can override each other left to right.
newtype IdeSessionUpdate a = IdeSessionUpdate {
    _runSessionUpdate :: ReaderT (IdeStaticInfo, Progress -> IO ())
                          (StateT IdeIdleState IO)
                            a
  }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadReader (IdeStaticInfo, Progress -> IO ())
           , MonadState IdeIdleState
           , MonadIO
           )

runSessionUpdate :: IdeSessionUpdate a
                 -> IdeStaticInfo
                 -> (Progress -> IO ())
                 -> IdeIdleState
                 -> IO (a, IdeIdleState)
runSessionUpdate upd staticInfo callback idleState =
  runStateT (runReaderT (_runSessionUpdate upd) (staticInfo, callback)) idleState

execSessionUpdate :: IdeSessionUpdate ()
                  -> IdeStaticInfo
                  -> (Progress -> IO ())
                  -> IdeIdleState
                  -> IO IdeIdleState
execSessionUpdate upd staticInfo callback idleState =
  snd <$> runSessionUpdate upd staticInfo callback idleState

-- We assume, if updates are combined within the monoid, they can all
-- be applied in the context of the same session.
-- Otherwise, call 'updateSession' sequentially with the updates.
instance Monoid a => Monoid (IdeSessionUpdate a) where
  mempty        = return mempty
  f `mappend` g = mappend <$> f <*> g

-- | Given the current IDE session state, go ahead and
-- update the session, eventually resulting in a new session state,
-- with fully updated computed information (typing, etc.).
--
-- The update can be a long running operation, so we support a callback
-- which can be used to monitor progress of the operation.
updateSession :: IdeSession -> IdeSessionUpdate () -> (Progress -> IO ()) -> IO ()
updateSession session@IdeSession{ideStaticInfo, ideState} update callback = do
    -- We don't want to call 'restartSession' while we hold the lock
    shouldRestart <- modifyMVar ideState $ \state -> case state of
      IdeSessionIdle idleState -> Ex.handle (handleExternal idleState) $ do
        idleState' <- execSessionUpdate (update >> recompileObjectFiles)
                                        ideStaticInfo
                                        callback
                                        idleState

        -- Update environment
        when (idleState' ^. ideUpdatedEnv) $
          rpcSetEnv (idleState ^. ideGhcServer) (idleState' ^. ideEnv)

        when (idleState' ^. ideUpdatedArgs) $
          rpcSetArgs (idleState ^. ideGhcServer) (idleState' ^. ideArgs)

        -- Recompile
        computed <- if (idleState' ^. ideUpdatedCode)
          then do
            GhcCompileResult{..} <- rpcCompile (idleState' ^. ideGhcServer)
                                               (idleState' ^. ideNewOpts)
                                               (ideSourcesDir ideStaticInfo)
                                               (ideDistDir    ideStaticInfo)
                                               (idleState' ^. ideGenerateCode)
                                               callback

            let applyDiff :: Strict (Map ModuleName) (Diff v)
                          -> (Computed -> Strict (Map ModuleName) v)
                          -> Strict (Map ModuleName) v
                applyDiff diff f = applyMapDiff diff
                                 $ Maybe.maybe Map.empty f
                                 $ idleState' ^. ideComputed

            let diffSpan  = Map.map (fmap mkIdMap)  ghcCompileSpanInfo
                diffTypes = Map.map (fmap mkExpMap) ghcCompileExpTypes
                diffAuto  = Map.map (fmap (constructAuto ghcCompileCache)) ghcCompileAuto

            return $ Maybe.just Computed {
                computedErrors        = ghcCompileErrors
              , computedLoadedModules = ghcCompileLoaded
              , computedImports       = ghcCompileImports  `applyDiff` computedImports
              , computedAutoMap       = diffAuto           `applyDiff` computedAutoMap
              , computedSpanInfo      = diffSpan           `applyDiff` computedSpanInfo
              , computedExpTypes      = diffTypes          `applyDiff` computedExpTypes
              , computedUseSites      = ghcCompileUseSites `applyDiff` computedUseSites
              , computedPkgDeps       = ghcCompilePkgDeps  `applyDiff` computedPkgDeps
              , computedCache         = mkRelative ghcCompileCache
              }
          else return $ idleState' ^. ideComputed

        -- Update state
        return ( IdeSessionIdle
               . (ideComputed    ^= computed)
               . (ideUpdatedEnv  ^= False)
               . (ideUpdatedCode ^= False)
               . (ideUpdatedArgs ^= False)
               $ idleState'
               , False
               )

      IdeSessionServerDied _ _ ->
        return (state, True)

      IdeSessionRunning _ _ ->
        Ex.throwIO (userError "Cannot update session in running mode")
      IdeSessionShutdown ->
        Ex.throwIO (userError "Session already shut down.")

    when shouldRestart $ do
      restartSession session Nothing
      updateSession session update callback
  where
    mkRelative :: ExplicitSharingCache -> ExplicitSharingCache
    mkRelative ExplicitSharingCache{..} =
      let aux :: BSS.ByteString -> BSS.ByteString
          aux = BSS.pack . makeRelative (ideSourcesDir ideStaticInfo) . BSS.unpack
      in ExplicitSharingCache {
        filePathCache = IntMap.map aux filePathCache
      , idPropCache   = idPropCache
      }

    handleExternal :: IdeIdleState -> ExternalException -> IO (IdeSessionState, Bool)
    handleExternal idleState e = return (IdeSessionServerDied e idleState, False)

    constructAuto :: ExplicitSharingCache -> Strict [] IdInfo
                  -> Strict Trie (Strict [] IdInfo)
    constructAuto cache lk =
        Trie.fromListWith (List.++) $ map aux (toLazyList lk)
      where
        aux :: IdInfo -> (BSS.ByteString, Strict [] IdInfo)
        aux idInfo@IdInfo{idProp = k} =
          let idProp = IntMap.findWithDefault
                         (error "constructAuto: could not resolve idPropPtr")
                         (idPropPtr k)
                         (idPropCache cache)
          in ( BSS.pack . Text.unpack . idName $ idProp
             , List.singleton idInfo
             )

recompileObjectFiles :: IdeSessionUpdate ()
recompileObjectFiles = do
    callback     <- getCallback
    staticInfo   <- getStaticInfo
    managedFiles <- get (ideManagedFiles .> managedSource)

    let cFiles :: [(FilePath, LogicalTimestamp)]
        cFiles = filter ((`elem` cExtensions) . takeExtension . fst)
               $ map (\(fp, (_, ts)) -> (fp, ts))
               $ managedFiles

        srcDir, objDir :: FilePath
        srcDir = ideSourcesDir staticInfo
        objDir = ideDistDir staticInfo </> "objs"

    recompiled <- forM cFiles $ \(fp, ts) -> do
      let absC     = srcDir </> fp
          absObj   = objDir </> replaceExtension fp ".o"

      mObjFile <- get (ideObjectFiles .> lookup' fp)

      -- Unload the old object (if necessary)
      case mObjFile of
        Just (objFile, ts') | ts' < ts -> do
          callback $ progress "Unloading" objFile
          unloadObject objFile
        _ ->
          return ()

      -- Recompile (if necessary)
      case mObjFile of
        Just (_objFile, ts') | ts' > ts ->
          -- The object is newer than the C file. Recompilation unnecessary
          return Nothing
        _ -> do
          -- TODO: We need to deal with errors in the C code
          callback $ progress "Compiling" fp
          liftIO $ Dir.createDirectoryIfMissing True (dropFileName absObj)
          ExitSuccess <- runGcc absC absObj
          ts' <- updateFileTimes absObj
          callback $ progress "Loading" absObj
          loadObject absObj
          set (ideObjectFiles .> lookup' fp) (Just (absObj, ts'))
          return (Just fp)

    markAsUpdated (update (catMaybes recompiled))
  where
    -- TODO: Think about more meaningful numbers here
    -- TODO: And possibly adjust the gHc progress numbers too
    -- TODO: Can we ask gcc for a progress message?
    progress :: String -> FilePath -> Progress
    progress prefix fp =
      Progress { progressStep      = 0
               , progressNumSteps  = 0
               , progressParsedMsg = msg
               , progressOrigMsg   = msg
               }
      where
        msg = Just . Text.pack $ prefix ++ " " ++ takeFileName fp

    -- NOTE: When using HscInterpreted/LinkInMemory, then C symbols get
    -- resolved during compilation, not during a separate linking step. To be
    -- precise, they get resolved from deep inside the compiler. Example
    -- callchain:
    --
    -- >            lookupStaticPtr   <-- does the resolution
    -- > called by  generateCCall
    -- > called by  schemeT
    -- > called by  schemeE
    -- > called by  doCase
    -- > called by  schemeE
    -- > called by  schemeER_wrk
    -- > called by  schemeR_wrk
    -- > called by  schemeR
    -- > called by  schemeTopBind
    -- > called by  byteCodeGen
    -- > called by  hscInteractive
    --
    -- Hence, we really need to recompile, rather than just relink.
    --
    -- TODO: If we knew which Haskell modules depended on which C files,
    -- we should do better here. For now we recompile all Haskell modules
    -- whenever any C file gets recompiled.
    update :: [FilePath] -> FilePath -> Bool
    update recompiled src = not (null recompiled)
                         && takeExtension src == ".hs"

-- | A session update that changes a source file by providing some contents.
-- This can be used to add a new module or update an existing one.
-- The @FilePath@ argument determines the directory
-- and file where the module is located within the project.
-- In case of Haskell source files, the actual internal
-- compiler module name, such as the one given by the
-- @getLoadedModules@ query, comes from within @module ... end@.
-- Usually the two names are equal, but they needn't be.
--
updateSourceFile :: FilePath -> BSL.ByteString -> IdeSessionUpdate ()
updateSourceFile m bs = do
  IdeStaticInfo{ideSourcesDir} <- getStaticInfo
  let internal = internalFile ideSourcesDir m
  old <- get (ideManagedFiles .> managedSource .> lookup' m)
  -- We always overwrite the file, and then later set the timestamp back
  -- to what it was if it turns out the hash was the same. If we compute
  -- the hash first, we would force the entire lazy bytestring into memory
  newHash <- liftIO $ writeFileAtomic internal bs
  case old of
    Just (oldHash, oldTS) | oldHash == newHash ->
      liftIO $ setFileTimes internal oldTS oldTS
    _ -> do
      newTS <- updateFileTimes internal
      set (ideManagedFiles .> managedSource .> lookup' m) (Just (newHash, newTS))
      set ideUpdatedCode True

-- | Like 'updateSourceFile' except that instead of passing the source by
-- value, it's given by reference to an existing file, which will be copied.
--
updateSourceFileFromFile :: FilePath -> IdeSessionUpdate ()
updateSourceFileFromFile p = do
  -- We just call 'updateSourceFile' because we need to read the file anyway
  -- to compute the hash.
  bs <- liftIO $ BSL.readFile p
  updateSourceFile p bs

-- | A session update that deletes an existing source file.
--
updateSourceFileDelete :: FilePath -> IdeSessionUpdate ()
updateSourceFileDelete m = do
  IdeStaticInfo{ideSourcesDir} <- getStaticInfo
  liftIO $ Dir.removeFile (internalFile ideSourcesDir m)
      `Ex.catch` \e -> if isDoesNotExistError e
                       then return ()
                       else Ex.throwIO e
  set (ideManagedFiles .> managedSource .> lookup' m) Nothing
  set ideUpdatedCode True

-- | Update dynamic compiler flags, including pragmas and packages to use.
-- Warning: only dynamic flags can be set here.
-- Static flags need to be set at server startup.
updateGhcOptions :: (Maybe [String]) -> IdeSessionUpdate ()
updateGhcOptions opts = do
  set ideNewOpts opts
  set ideUpdatedCode True

-- | Enable or disable code generation in addition
-- to type-checking. Required by 'runStmt'.
updateCodeGeneration :: Bool -> IdeSessionUpdate ()
updateCodeGeneration b = do
  set ideGenerateCode b
  set ideUpdatedCode True

-- | A session update that changes a data file by giving a new value for the
-- file. This can be used to add a new file or update an existing one.
-- Since source files can include data files (e.g., via TH), we set
-- @ideUpdatedCode@ to force recompilation (see #94).
--
updateDataFile :: FilePath -> BSL.ByteString -> IdeSessionUpdate ()
updateDataFile n bs = do
  IdeStaticInfo{ideDataDir} <- getStaticInfo
  liftIO $ writeFileAtomic (ideDataDir </> n) bs
  modify (ideManagedFiles .> managedData) (n :)
  set ideUpdatedCode True

-- | Like 'updateDataFile' except that instead of passing the file content by
-- value, it's given by reference to an existing file (the second argument),
-- which will be copied.
--
updateDataFileFromFile :: FilePath -> FilePath -> IdeSessionUpdate ()
updateDataFileFromFile n p = do
  IdeStaticInfo{ideDataDir} <- getStaticInfo
  let targetPath = ideDataDir </> n
      targetDir  = takeDirectory targetPath
  liftIO $ Dir.createDirectoryIfMissing True targetDir
  liftIO $ Dir.copyFile p targetPath
  modify (ideManagedFiles .> managedData) (n :)
  set ideUpdatedCode True

-- | A session update that deletes an existing data file.
--
updateDataFileDelete :: FilePath -> IdeSessionUpdate ()
updateDataFileDelete n = do
  IdeStaticInfo{ideDataDir} <- getStaticInfo
  liftIO $ Dir.removeFile (ideDataDir </> n)
      `Ex.catch` \e -> if isDoesNotExistError e
                       then return ()
                       else Ex.throwIO e
  modify (ideManagedFiles .> managedData) $ delete n
  set ideUpdatedCode True

-- | Set an environment variable
--
-- Use @updateEnv var Nothing@ to unset @var@.
updateEnv :: String -> Maybe String -> IdeSessionUpdate ()
updateEnv var val = do
  set (ideEnv .> lookup' var) (Just val)
  set ideUpdatedEnv True

-- | Set command line arguments for snippets
-- (i.e., the expected value of `getArgs`)
updateArgs :: [String] -> IdeSessionUpdate ()
updateArgs args = do
  set ideArgs args
  set ideUpdatedArgs True

-- | Set buffering mode for snippets' stdout
updateStdoutBufferMode :: RunBufferMode -> IdeSessionUpdate ()
updateStdoutBufferMode bufferMode = do
  set ideStdoutBufferMode bufferMode

-- | Set buffering mode for snippets' stderr
updateStderrBufferMode :: RunBufferMode -> IdeSessionUpdate ()
updateStderrBufferMode bufferMode = do
  set ideStderrBufferMode bufferMode

-- | Run a given function in a given module (the name of the module
-- is the one between @module ... end@, which may differ from the file name).
-- The function resembles a query, but it's not instantaneous
-- and the running code can be interrupted or interacted with.
--
-- 'runStmt' will throw an exception if the code has not been compiled yet,
-- or when the server is in a dead state (i.e., when ghc has crashed). In the
-- latter case 'getSourceErrors' will report the ghc exception; it is the
-- responsibility of the client code to check for this.
runStmt :: IdeSession -> String -> String -> IO (RunActions Public.RunResult)
runStmt ideSession m fun = runCmd ideSession $ \idleState -> RunStmt {
    runCmdModule   = m
  , runCmdFunction = fun
  , runCmdStdout   = idleState ^. ideStdoutBufferMode
  , runCmdStderr   = idleState ^. ideStderrBufferMode
  }

-- | Resume a previously interrupted statement
resume :: IdeSession -> IO (RunActions Public.RunResult)
resume ideSession = runCmd ideSession (const Resume)

-- | Internal geneneralization used in 'runStmt' and 'resume'
runCmd :: IdeSession -> (IdeIdleState -> RunCmd) -> IO (RunActions Public.RunResult)
runCmd session mkCmd = modifyIdleState session $ \idleState ->
  case (toLazyMaybe (idleState ^. ideComputed), idleState ^. ideGenerateCode) of
    (Just comp, True) -> do
      let cmd   = mkCmd idleState
          cache = computedCache comp
      checkStateOk comp cmd
      isBreak    <- newEmptyMVar
      runActions <- rpcRun (idleState ^. ideGhcServer)
                           cmd
                           (translateRunResult isBreak)
      registerTerminationCallback runActions (restoreToIdle cache isBreak)
      return (IdeSessionRunning runActions idleState, runActions)
    _ ->
      -- This 'fail' invocation is, in part, a workaround for
      -- http://hackage.haskell.org/trac/ghc/ticket/7539
      -- which would otherwise lead to a hard GHC crash,
      -- instead of providing a sensible error message
      -- that we could show to the user.
      fail "Cannot run before the code is generated."
  where
    checkStateOk :: Computed -> RunCmd -> IO ()
    checkStateOk comp RunStmt{..} =
      -- ideManagedFiles is irrelevant, because only the module name inside
      -- 'module .. where' counts.
      unless (Text.pack runCmdModule `List.elem` computedLoadedModules comp) $
        fail $ "Module " ++ show runCmdModule
                         ++ " not successfully loaded, when trying to run code."
    checkStateOk _comp Resume =
      -- TODO: should we check that there is anything to resume here?
      return ()

    restoreToIdle :: ExplicitSharingCache -> StrictMVar (Strict Maybe BreakInfo) -> Public.RunResult -> IO ()
    restoreToIdle cache isBreak _ = do
      mBreakInfo <- readMVar isBreak
      modifyMVar_ (ideState session) $ \state -> case state of
        IdeSessionIdle _ ->
          Ex.throwIO (userError "The impossible happened!")
        IdeSessionRunning _ idleState -> do
          let upd = ideBreakInfo ^= fmap (removeExplicitSharing cache) mBreakInfo
          return $ IdeSessionIdle (upd idleState)
        IdeSessionShutdown ->
          return state
        IdeSessionServerDied _ _ ->
          return state

    translateRunResult :: StrictMVar (Strict Maybe BreakInfo)
                       -> Maybe Private.RunResult
                       -> IO Public.RunResult
    translateRunResult isBreak (Just Private.RunOk) = do
      putMVar isBreak Maybe.nothing
      return $ Public.RunOk
    translateRunResult isBreak (Just (Private.RunProgException str)) = do
      putMVar isBreak Maybe.nothing
      return $ Public.RunProgException str
    translateRunResult isBreak (Just (Private.RunGhcException str)) = do
      putMVar isBreak Maybe.nothing
      return $ Public.RunGhcException str
    translateRunResult isBreak (Just (Private.RunBreak breakInfo)) = do
      putMVar isBreak (Maybe.just breakInfo)
      return $ Public.RunBreak
    translateRunResult _isBreak Nothing =
      -- Termination handler not called in this case, no need to update _isBreak
      return $ Public.RunForceCancelled

-- | Breakpoint
--
-- Set a breakpoint at the specified location. Returns @Just@ the old value of the
-- breakpoint if successful, or @Nothing@ otherwise.
setBreakpoint :: IdeSession
              -> ModuleName        -- ^ Module where the breakshould should be set
              -> Public.SourceSpan -- ^ Location of the breakpoint
              -> Bool              -- ^ New value for the breakpoint
              -> IO (Maybe Bool)   -- ^ Old value of the breakpoint (if valid)
setBreakpoint session mod span value = withIdleState session $ \idleState ->
  rpcBreakpoint (idleState ^. ideGhcServer) mod span value

-- | Print and/or force values during debugging
--
-- Only valid in breakpoint state.
printVar :: IdeSession
         -> Public.Name -- ^ Variable to print
         -> Bool        -- ^ Should printing bind new vars? (@:print@ vs. @:sprint@)
         -> Bool        -- ^ Should the value be forced? (@:print@ vs. @:force@)
         -> IO Public.VariableEnv
printVar session var bind forceEval = withBreakInfo session $ \idleState _ ->
  rpcPrint (idleState ^. ideGhcServer) var bind forceEval

-- | Build an exe from sources added previously via the ide-backend
-- updateSourceFile* mechanism. The modules that contains the @main@ code are
-- indicated by the arguments to @buildExe@. The function can be called
-- multiple times with different arguments.
--
-- We assume any indicated module is already successfully processed by GHC API
-- in a compilation mode that makes @computedImports@ available (but no code
-- needs to be generated). The environment (package dependencies, ghc options,
-- preprocessor program options, etc.) for building the exe is the same as when
-- previously compiling the code via GHC API. The module does not have to be
-- called @Main@, but we assume the main function is always @main@ (we don't
-- check this and related conditions, but GHC does when eventually called to
-- build the exe).
--
-- The executable files are placed in the filesystem inside the @build@
-- subdirectory of 'Query.getDistDir', in subdirectories corresponding to the given
-- module names. The build directory does not overlap with any of the other
-- used directories and its path.
--
-- Logs from the building process are saved in files
-- @build\/ide-backend-exe.stdout@ and @build\/ide-backend-exe.stderr@
-- in the 'Query.getDistDir' directory.
--
-- Note: currently it requires @configGenerateModInfo@ to be set (see #86).
buildExe :: [(ModuleName, FilePath)] -> IdeSessionUpdate ()
buildExe ms = do
    IdeStaticInfo{..} <- getStaticInfo
    callback          <- getCallback
    mcomputed         <- get ideComputed
    ghcNewOpts        <- get ideNewOpts
    let SessionConfig{ configDynLink
                     , configPackageDBStack
                     , configGenerateModInfo
                     , configStaticOpts
                     , configExtraPathDirs } = ideConfig
        -- Note that these do not contain the @packageDbArgs@ options.
        ghcOpts = fromMaybe configStaticOpts ghcNewOpts
    when (not configGenerateModInfo) $
      -- TODO: replace the check with an inspection of state component (#87)
      fail "Features using cabal API require configGenerateModInfo, currently (#86)."
    exitCode <- liftIO $ Ex.bracket
      Dir.getCurrentDirectory
      Dir.setCurrentDirectory
      (const $ do Dir.setCurrentDirectory ideDataDir
                  buildExecutable ideSourcesDir ideDistDir configExtraPathDirs
                                  ghcOpts configDynLink configPackageDBStack
                                  mcomputed callback ms)
    set ideBuildExeStatus (Just exitCode)

-- | Build haddock documentation from sources added previously via
-- the ide-backend updateSourceFile* mechanism. Similarly to 'buildExe',
-- it needs the project modules to be already loaded within the session
-- and the generated docs can be found in the @doc@ subdirectory
-- of 'Query.getDistDir'.
--
-- Logs from the documentation building process are saved in files
-- @doc\/ide-backend-doc.stdout@ and @doc\/ide-backend-doc.stderr@
-- in the 'Query.getDistDir' directory.
--
-- Note: currently it requires @configGenerateModInfo@ to be set (see #86).
buildDoc :: IdeSessionUpdate ()
buildDoc = do
    IdeStaticInfo{..} <- getStaticInfo
    callback          <- getCallback
    mcomputed         <- get ideComputed
    ghcNewOpts        <- get ideNewOpts
    let SessionConfig{ configDynLink
                     , configPackageDBStack
                     , configGenerateModInfo
                     , configStaticOpts
                     , configExtraPathDirs } = ideConfig
        ghcOpts = fromMaybe configStaticOpts ghcNewOpts
    when (not configGenerateModInfo) $
      -- TODO: replace the check with an inspection of state component (#87)
      fail "Features using cabal API require configGenerateModInfo, currently (#86)."
    exitCode <- liftIO $ Ex.bracket
      Dir.getCurrentDirectory
      Dir.setCurrentDirectory
      (const $ do Dir.setCurrentDirectory ideDataDir
                  buildHaddock ideSourcesDir ideDistDir configExtraPathDirs
                               ghcOpts configDynLink configPackageDBStack
                               mcomputed callback)
    set ideBuildDocStatus (Just exitCode)

-- | Build a file containing licenses of all used packages.
-- Similarly to 'buildExe', the function needs the project modules to be
-- already loaded within the session. The concatenated licenses can be found
-- in file @licenses.txt@ inside the 'Query.getDistDir' directory.
--
-- The function expects .cabal files of all used packages,
-- except those mentioned in 'configLicenseExc',
-- to be gathered in the directory given as the first argument.
-- The code then expects to find those packages installed and their
-- license files in the usual place that Cabal puts them
-- (or the in-place packages should be correctly embedded in the GHC tree).
--
-- We guess the installed locations of the license files on the basis
-- of the haddock interfaces path. If the default setting does not work
-- properly, the haddock interfaces path should be set manually. E.g.,
-- @cabal configure --docdir=the_same_path --htmldir=the_same_path@
-- affects the haddock interfaces path (because it is by default based
-- on htmldir) and is reported to work for some values of @the_same_path@.
--
-- Logs from the license search and catenation process are saved in files
-- @licenses.stdout@ and @licenses.stderr@
-- in the 'Query.getDistDir' directory.
--
-- Note: currently 'configGenerateModInfo' needs to be set
-- for this function to work (see #86).
buildLicenses :: FilePath -> IdeSessionUpdate ()
buildLicenses cabalsDir = do
    IdeStaticInfo{..} <- getStaticInfo
    callback          <- getCallback
    mcomputed         <- get ideComputed
    let SessionConfig{..} = ideConfig
    when (not configGenerateModInfo) $
      -- TODO: replace the check with an inspection of state component (#87)
      fail "Features using cabal API require configGenerateModInfo, currently (#86)."
    exitCode <- liftIO $
      buildLicenseCatenation mcomputed
                             cabalsDir ideDistDir configExtraPathDirs
                             configPackageDBStack
                             configLicenseExc configLicenseFixed
                             callback
    set ideBuildLicensesStatus (Just exitCode)

{------------------------------------------------------------------------------
  Debugging
------------------------------------------------------------------------------}

-- | Force recompilation of all modules. For debugging only.
forceRecompile :: IdeSessionUpdate ()
forceRecompile = markAsUpdated (const True)

-- | Crash the GHC server. For debugging only. If the specified delay is
-- @Nothing@, crash immediately; otherwise, set up a thread that throws
-- an exception to the main thread after the delay.
crashGhcServer :: IdeSession -> Maybe Int -> IO ()
crashGhcServer session delay = withIdleState session $ \idleState ->
  rpcCrash (idleState ^. ideGhcServer) delay

{------------------------------------------------------------------------------
  Internal session updates
------------------------------------------------------------------------------}

getStaticInfo :: IdeSessionUpdate IdeStaticInfo
getStaticInfo = asks fst

getCallback :: MonadIO m => IdeSessionUpdate (Progress -> m ())
getCallback = (liftIO .) <$> asks snd

-- | Load an object file
loadObject :: FilePath -> IdeSessionUpdate ()
loadObject path = do
  ghcServer <- get ideGhcServer
  liftIO $ rpcLoad ghcServer path False

-- | Unload an object file
unloadObject :: FilePath -> IdeSessionUpdate ()
unloadObject path = do
  ghcServer <- get ideGhcServer
  liftIO $ rpcLoad ghcServer path True

-- | Force recompilation of the given modules
markAsUpdated :: (FilePath -> Bool) -> IdeSessionUpdate ()
markAsUpdated shouldMark = do
  IdeStaticInfo{ideSourcesDir} <- getStaticInfo
  sources  <- get (ideManagedFiles .> managedSource)
  sources' <- forM sources $ \(path, (digest, oldTS)) ->
    if shouldMark path
      then do set ideUpdatedCode True
              newTS <- updateFileTimes (internalFile ideSourcesDir path)
              return (path, (digest, newTS))
      else return (path, (digest, oldTS))
  set (ideManagedFiles .> managedSource) sources'

-- | Update the file times of the given file with the next logical timestamp
updateFileTimes :: FilePath -> IdeSessionUpdate LogicalTimestamp
updateFileTimes path = do
  ts <- nextLogicalTimestamp
  liftIO $ setFileTimes path ts ts
  return ts

-- | Get the next available logical timestamp
nextLogicalTimestamp :: MonadState IdeIdleState m => m LogicalTimestamp
nextLogicalTimestamp = do
  newTS <- get ideLogicalTimestamp
  modify ideLogicalTimestamp (+ 1)
  return newTS

-- | Call gcc
--
-- TODO: For now we manually invoke gcc with no options at all. We need to
-- figure out what cabal does and make sure that we do the same thing
runGcc :: FilePath -> FilePath -> IdeSessionUpdate ExitCode
runGcc src dst = liftIO $
    system $ gcc ++ " -c -o " ++ dst ++ " " ++ src
  where
    -- TODO: this should be configurable
    gcc :: FilePath
    gcc = "/usr/bin/gcc"

{------------------------------------------------------------------------------
  Aux
------------------------------------------------------------------------------}

withBreakInfo :: IdeSession -> (IdeIdleState -> Public.BreakInfo -> IO a) -> IO a
withBreakInfo session act = withIdleState session $ \idleState ->
  case toLazyMaybe (idleState ^. ideBreakInfo) of
    Just breakInfo -> act idleState breakInfo
    Nothing        -> Ex.throwIO (userError "Not in breakpoint state")

withIdleState :: IdeSession -> (IdeIdleState -> IO a) -> IO a
withIdleState session act = modifyIdleState session $ \idleState -> do
  result <- act idleState
  return (IdeSessionIdle idleState, result)

modifyIdleState :: IdeSession -> (IdeIdleState -> IO (IdeSessionState, a)) -> IO a
modifyIdleState IdeSession{..} act = modifyMVar ideState $ \state -> case state of
  IdeSessionIdle idleState -> act idleState
  _                        -> Ex.throwIO $ userError "State not idle"
