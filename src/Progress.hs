{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module Progress where

import           Control.Concurrent
import qualified Control.Exception          as E
import qualified Control.Monad.Trans.Class  as MT
import           Control.Monad.Trans.State
import           Data.Aeson                 as A hiding (json)
import qualified Data.ByteString.Lazy.Char8 as B8
import           Data.HashMap.Lazy          as HM
import           Data.Maybe
import           Debug
import           GHC.Generics
import           GHC.IO.Handle
import           System.Exit
import qualified System.IO                  as IO
import           System.Process

type Standard = String
type ProcessID = (FilePath, Standard)

checkProgresses :: StateT Progresses IO ()
checkProgresses = do
    st <- get
    newst <- MT.lift $ mapM checkProgress st
    put newst

checkProgress :: Progress -> IO Progress
checkProgress pr
    | (status (json pr) /= Progress.InProgress) = return pr
    | otherwise = do
        code <- getProcessExitCode $ processHandle phs
        case code of
            Just code -> return $ handleExit code
            Nothing -> E.handle onIOException $ do
                str <- hGetLastLine (stdout phs)
                -- errs <- hGetLinesReverse (stderr p)
                -- update errors
                let j' = j { status = Progress.InProgress }
                -- update percentage
                let hm = A.eitherDecode (B8.pack str) :: Either String (HashMap String Float)
                let j'' = if str == "" then j' else
                        case hm of
                            (Left err) -> error err
                            (Right m) -> j' { percentage = m HM.! "percentage" }
                return $ pr { json = j'' }
    where
        (Just phs) = handles pr
        j = json pr

        handleExit :: ExitCode -> Progress
        handleExit ExitSuccess = pr { json = j { percentage = 100, status = Done } }
        handleExit (ExitFailure k) = pr { json = j { status = Progress.Error } }

        onIOException :: E.IOException -> IO Progress
        onIOException e = do
            -- check again the exit code
            code <- getProcessExitCode $ processHandle phs
            return $ 
                case code of
                    Nothing -> handleExit (ExitFailure 1)
                    Just code -> handleExit code

decodeProgress :: B8.ByteString -> ProgressJSON
decodeProgress s =
    case A.eitherDecode s of
        Left err -> Prelude.error err
        Right p  -> p


hGetLastLine :: Handle -> IO String
hGetLastLine = hGetLastLine' ""
    where
        hGetLastLine' sofar hd = do
            ready <- IO.hReady hd
            if ready then do
                l <- hGetLine hd
                hGetLastLine' l hd
            else return sofar

hGetLinesReverse :: Handle -> IO String
hGetLinesReverse = hGetLinesReverse' ""
    where
        hGetLinesReverse' sofar hd = do
            ready <- IO.hReady hd
            if ready then do
                l <- hGetLine hd
                hGetLinesReverse' (l ++ "\n" ++ sofar) hd
            else return sofar


type Progresses = HashMap (FilePath, Standard) Progress

data Progress = Progress {
      handles :: Maybe ProgressHandles
    , json    :: ProgressJSON
}

data ProgressHandles = ProgressHandles {
      stdin         :: Handle
    , stdout        :: Handle
    -- , stderr :: Handle
    , processHandle :: ProcessHandle
}

data ProgressJSON = ProgressJSON {
      url        :: FilePath
    , percentage :: Float
    , status     :: Status
    , standard   :: Standard
    -- , errors     :: String
    , command    :: String
    , size       :: Integer
} deriving (Generic, FromJSON, ToJSON, Show, Read)

data Status = Queued | InProgress | Done | Error | UserStopped | Added deriving (Generic, Read, Show, ToJSON, FromJSON, Eq)

updateStatus :: Progress -> Status -> Progress
updateStatus p s = p { json = (json p) { status = s } } 
