{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Control.Exception (SomeException(..),catch,bracket)
import Control.Monad
import Control.Monad.Trans
import Control.Monad.Trans.Either
import Data.Maybe
import Data.List
import Data.Char
import Data.Text(Text(..),pack)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS
import Options.Applicative
import System.Environment
import System.Exit
import System.IO
import Text.RegexPR
import Text.Printf

import Web.VKHS
import Web.VKHS.Types
import Web.VKHS.Client as Client
import Web.VKHS.Monad hiding (catch)
import Web.VKHS.API as API
import Web.VKHS.API.Types as API

import Util

data Options
  = Login LoginOptions
  | API APIOptions
  | Music MusicOptions
  | UserQ UserOptions
  | WallQ WallOptions
  | GroupQ GroupOptions
  deriving(Show)

genericOptions :: Parser GenericOptions
genericOptions = GenericOptions
  <$> (pure $ o_login_host defaultOptions)
  <*> (pure $ o_api_host defaultOptions)
  <*> (pure $ o_port defaultOptions)
  <*> flag False True (long "verbose" <> help "Be verbose")
  <*> (pure $ o_use_https defaultOptions)
  <*> fmap read (strOption (value (show $ o_max_request_rate_per_sec defaultOptions) <> long "req-per-sec" <> metavar "N" <> help "Max number of requests per second"))
  <*> flag True False (long "interactive" <> help "Allow interactive queries")

loginOptions :: Parser LoginOptions
loginOptions = LoginOptions
  <$> genericOptions
  <*> (AppID <$> strOption (long "appid" <> metavar "APPID" <> value "3128877" <> help "Application ID, defaults to VKHS" ))
  <*> argument str (metavar "USER" <> help "User name or email")
  <*> argument str (metavar "PASS" <> help "User password")

loginOptions' :: Parser LoginOptions
loginOptions' = LoginOptions
  <$> genericOptions
  <*> (AppID <$> strOption (long "appid" <> metavar "APPID" <> value "3128877" <> help "Application ID, defaults to VKHS" ))
  <*> strOption (long "user" <> value "" <> metavar "STR" <> help "User name or email")
  <*> strOption (long "pass" <> value "" <> metavar "STR" <> help "Password")

toMaybe :: (Functor f) => f String -> f (Maybe String)
toMaybe = fmap (\s -> if s == "" then Nothing else Just s)

opts m =
  let access_token_flag = strOption (short 'a' <> m <> metavar "ACCESS_TOKEN" <>
        help "Access token. Honores VKQ_ACCESS_TOKEN environment variable")
      api_cmd = (info (API <$> (APIOptions
        <$> loginOptions'
        <*> access_token_flag
        <*> switch (long "preparse" <> short 'p' <> help "Preparse into Aeson format")
        <*> argument str (metavar "METHOD" <> help "Method name")
        <*> argument str (metavar "PARAMS" <> help "Method arguments, KEY=VALUE[,KEY2=VALUE2[,,,]]")))
        ( progDesc "Call VK API method" ))
  in subparser (
    command "login" (info (Login <$> loginOptions)
      ( progDesc "Login and print access token (also prints user_id and expiration time)" ))
    <> command "call" api_cmd
    <> command "api" api_cmd
    <> command "music" (info ( Music <$> (MusicOptions
      <$> loginOptions'
      <*> access_token_flag
      <*> switch (long "list" <> short 'l' <> help "List music files")
      <*> strOption
        ( metavar "STR"
        <> long "query" <> short 'q' <> value [] <> help "Query string")
      <*> strOption
        ( metavar "FORMAT"
        <> short 'f'
        <> value "%o_%i %U\t%t"
        <> help "Listing format, supported tags: %i %o %a %t %d %u"
        )
      <*> strOption
        ( metavar "FORMAT"
        <> short 'F'
        <> value "%o_%i %U\t%t"
        <> help ("Output format, supported tags:" ++ (listTags mr_tags))
        )
      <*> toMaybe (strOption (metavar "DIR" <> short 'o' <> help "Output directory" <> value ""))
      <*> many (argument str (metavar "RECORD_ID" <> help "Download records"))
      <*> flag False True (long "skip-existing" <> help "Don't download existing files")
      ))
      ( progDesc "List or download music files"))
    <> command "user" (info ( UserQ <$> (UserOptions
      <$> loginOptions'
      <*> access_token_flag
      <*> strOption (long "query" <> short 'q' <> help "String to query")
      ))
      ( progDesc "Extract various user information"))
    <> command "wall" (info ( WallQ <$> (WallOptions
      <$> loginOptions'
      <*> access_token_flag
      <*> strOption (long "id" <> short 'i' <> help "Owner id")
      ))
      ( progDesc "Extract wall information"))
    <> command "group" (info ( GroupQ <$> (GroupOptions
      <$> loginOptions'
      <*> access_token_flag
      <*> strOption (long "query" <> short 'q' <> value [] <> help "Group search string")
      <*> strOption
        ( metavar "FORMAT"
        <> short 'F'
        <> value "%o_%i %U\t%t"
        <> help ("Output format, supported tags:" ++ (listTags gr_tags))
        )
      ))
      ( progDesc "Extract groups information"))
    )

main :: IO ()
main = ( do
  m <- maybe (value "") (value) <$> lookupEnv "VKQ_ACCESS_TOKEN"
  o <- execParser (info (helper <*> opts m) (fullDesc <> header "VKontakte social network tool"))
  r <- runEitherT (cmd o)
  case r of
    Left err -> do
      hPutStrLn stderr err
      exitFailure
    Right _ -> do
      return ()
  )`catch` (\(e::SomeException) -> do
    putStrLn $ (show e)
    exitFailure
  )

{-
  ____ _     ___
 / ___| |   |_ _|
| |   | |    | |
| |___| |___ | |
 \____|_____|___|

 -}

cmd :: Options -> EitherT String IO ()

-- Login
cmd (Login lo) = do
  AccessToken{..} <- runLogin lo
  liftIO $ putStrLn at_access_token

-- API
cmd (API (APIOptions{..})) = do
  runAPI a_login_options a_access_token (apiJ a_method (splitFragments "," "=" a_args))
  return ()

cmd (Music (mo@MusicOptions{..}))

  -- Query music files
  |not (null m_search_string) = do
    runAPI m_login_options m_access_token $ do
      API.Response _ (SizedList len ms) <- api "audio.search" [("q",m_search_string)]
      forM_ ms $ \m -> do
        io $ printf "%s\n" (mr_format m_output_format m)
      io $ printf "total %d\n" len

  -- List music files
  |m_list_music = do
    runAPI m_login_options m_access_token $ do
      (API.Response _ (ms :: [MusicRecord])) <- api "audio.get" [("q",m_search_string)]
      forM_ ms $ \m -> do
        io $ printf "%s\n" (mr_format m_output_format m)

  -- Download music files
  |not (null m_records_id) = do
    let out_dir = fromMaybe "." m_out_dir
    runAPI m_login_options m_access_token $ do
      (API.Response _ (ms :: [MusicRecord])) <- api "audio.getById" [("audios", concat $ intersperse "," m_records_id)]
      forM_ ms $ \mr@MusicRecord{..} -> do
        (f, mh) <- liftIO $ openFileMR mo mr
        case mh of
          Just h -> do
            u <- ensure (pure $ Client.urlFromString mr_url_str)
            r <- Client.downloadFileWith u (BS.hPut h)
            io $ printf "%d_%d\n" mr_owner_id mr_id
            io $ printf "%s\n" mr_title
            io $ printf "%s\n" f
          Nothing -> do
            io $ hPutStrLn stderr ("File " ++ f ++ " already exist, skipping")
        return ()


-- Download audio files
-- cmd (Options v (Music (MO act False [] _ ofmt odir rid sk))) = do
--   let e = (envcall act) { verbose = v }
--   Response (ms :: [MusicRecord]) <- api_ e "audio.getById" [("audios", concat $ intersperse "," rid)]
--   forM_ ms $ \m -> do
--     (fp, mh) <- openFileMR odir sk ofmt m
--     case mh of
--       Just h -> do
--         r <- vk_curl_file e (url m) $ \ bs -> do
--           BS.hPut h bs
--         checkRight r
--         printf "%d_%d\n" (owner_id m) (aid m)
--         printf "%s\n" (title m)
--         printf "%s\n" fp
--       Nothing -> do
--         hPutStrLn stderr (printf "File %s already exist, skipping" fp)
--     return ()

-- Query groups files
cmd (GroupQ (GroupOptions{..}))

  |not (null g_search_string) = do

    runAPI g_login_options g_access_token $ do

      API.Response _ (Many cnt (grs :: [GroupRecord])) <-
        api "groups.search"
          [("q",g_search_string),
           ("v","5.44"),
           ("fields", "can_post,members_count"),
           ("count", "1000")]

      forM_ grs $ \gr -> do
        liftIO $ printf "%s\n" (gr_format g_output_format gr)
