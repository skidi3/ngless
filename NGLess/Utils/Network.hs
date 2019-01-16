{- Copyright 2013-2019 NGLess Authors
 - License: MIT
 -}
module Utils.Network
    ( downloadFile
    , downloadOrCopyFile
    , downloadExpandTar
    ) where

import Control.Monad.IO.Class (liftIO, MonadIO(..))
import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import           Data.Conduit ((.|))
import qualified Data.Conduit.Tar as CTar

import qualified Data.ByteString.Char8 as B
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Simple as HTTPSimple
import           Data.Conduit.Algorithms.Async (conduitPossiblyCompressedFile)

import qualified Data.Conduit.Binary as CB
import System.Directory (copyFile, createDirectoryIfMissing, removeFile)
import Data.List (isPrefixOf)
import System.FilePath

import Output
import NGLess
import Utils.Conduit
import Utils.ProgressBar

downloadOrCopyFile :: FilePath -> FilePath -> NGLessIO ()
downloadOrCopyFile src dest
    | any (`isPrefixOf` src) ["http://", "https://", "ftp://"] = downloadFile src dest
    | otherwise = liftIO $ copyFile src dest


downloadFile :: String -> FilePath -> NGLessIO ()
downloadFile url destPath = do
    outputListLno' TraceOutput ["Downloading ", url]
    req <- HTTP.parseRequest url
    let req' = req { HTTP.decompress = const False }
    r <- liftIO $ HTTPSimple.withResponse req' $ \res ->
        case HTTPSimple.getResponseStatusCode res of
            200 -> do
                C.runConduitRes $
                    HTTP.responseBody res
                        .| case lookup "Content-Length" (HTTP.responseHeaders res) of
                            Nothing -> CL.map id
                            Just csize -> printProgress (read (B.unpack csize))
                        .| CB.sinkFileCautious destPath
                return $ Right ()
            err -> return . throwSystemError $ "Could not connect to "++url++" (got error code: "++show err++")"
    runNGLess (r :: NGLess ())

-- | Download a tar.gz file and expand it onto 'destdir'
downloadExpandTar :: FilePath -> FilePath -> NGLessIO ()
downloadExpandTar url destdir = do
    let tarName = destdir <.> "tar.gz"

    liftIO $ createDirectoryIfMissing True destdir
    -- We could avoid creating the tar file by streaming directly to untarWithExceptions
    downloadOrCopyFile url tarName
    liftIO $ do
        void $ C.runConduitRes $
            conduitPossiblyCompressedFile tarName
                .| CTar.untarWithExceptions (CTar.restoreFileIntoLenient destdir)
        removeFile tarName


printProgress :: MonadIO m => Int -> C.ConduitT B.ByteString B.ByteString m ()
printProgress csize = liftIO (mkProgressBar 40) >>= loop 0
  where
    loop !len pbar = awaitJust $ \bs -> do
            let len' = len + B.length bs
                progress = fromIntegral len' / fromIntegral csize
            pbar' <- liftIO (updateProgressBar pbar progress)
            C.yield bs
            loop len' pbar'


