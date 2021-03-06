{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}

module Web.VKHS.API.Base where

import Data.List
import Data.Maybe
import Data.Time
import Data.Either
import Control.Arrow ((***),(&&&))
import Control.Category ((>>>))
import Control.Applicative
import Control.Monad
import Control.Monad.State
import Control.Monad.Writer
import Control.Monad.Cont

import Data.Text(Text)
import qualified Data.Text as Text

import Data.ByteString.Char8 (ByteString)
import Data.ByteString.Lazy (fromStrict,toChunks)
import qualified Data.ByteString.Char8 as BS

import Data.Aeson ((.=), (.:))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.Aeson.Encode.Pretty as Aeson

import Text.Printf

import Web.VKHS.Types
import Web.VKHS.Client hiding (Response(..))
import Web.VKHS.Monad
import Web.VKHS.Error
import Web.VKHS.API.Types

import Debug.Trace

data APIState = APIState {
    api_access_token :: String
  } deriving (Show)

defaultState = APIState {
    api_access_token = ""
  }

class ToGenericOptions s => ToAPIState s where
  toAPIState :: s -> APIState
  modifyAPIState :: (APIState -> APIState) -> (s -> s)

-- | Class of monads able to run VK API calls. @m@ - the monad itself, @x@ -
-- type of early error, @s@ - type of state (see alse @ToAPIState@)
class (MonadIO (m (R m x)), MonadClient (m (R m x)) s, ToAPIState s, MonadVK (m (R m x)) (R m x)) =>
  MonadAPI m x s | m -> s

type API m x a = m (R m x) a

-- | Utility function to parse JSON object
parseJSON :: (MonadAPI m x s)
    => ByteString
    -> API m x JSON
parseJSON bs = do
  case Aeson.decode (fromStrict bs) of
    Just js -> return (JSON js)
    Nothing -> raise (JSONParseFailure bs)

-- | Invoke the request. Returns answer as JSON object .
--
-- See the official documentation:
-- <https://vk.com/dev/methods>
-- <https://vk.com/dev/json_schema>
--
-- FIXME: We currentyl use Text.unpack to encode text into strings. Use encodeUtf8
-- instead.
apiJ :: (MonadAPI m x s)
    => String
    -- ^ API method name
    -> [(String, Text)]
    -- ^ API method arguments
    -> API m x JSON
apiJ mname (map (id *** tunpack) -> margs) = do
  GenericOptions{..} <- gets toGenericOptions
  APIState{..} <- gets toAPIState
  let protocol = (case o_use_https of
                    True -> "https"
                    False -> "http")
  url <- ensure $ pure
        (urlCreate
          (URL_Protocol protocol)
          (URL_Host o_api_host)
          (Just (URL_Port (show o_port)))
          (URL_Path ("/method/" ++ mname))
          (buildQuery (("access_token", api_access_token):margs)))

  debug $ "> " <> (tshow url)

  req <- ensure (requestCreateGet url (cookiesCreate ()))
  (res, jar') <- requestExecute req
  parseJSON (responseBody res)


-- | Invoke the request, returns answer as a Haskell datatype. On error fall out
-- to the supervizer (e.g. @VKHS.defaultSuperviser@) without possibility to
-- continue
api :: (Aeson.FromJSON a, MonadAPI m x s)
    => String
    -- ^ API method name
    -> [(String, Text)]
    -- ^ API method arguments
    -> API m x a
api m args = do
  j@JSON{..} <- apiJ m args
  case Aeson.parseEither Aeson.parseJSON js_aeson of
    Right a -> return a
    Left e -> terminate (JSONParseFailure' j e)


-- | Invoke the request, returns answer as a Haskell datatype or @ErrorRecord@
-- object
apiE :: (Aeson.FromJSON a, MonadAPI m x s)
    => String           -- ^ API method name
    -> [(String, Text)] -- ^ API method arguments
    -> API m x (Either (Response ErrorRecord) a)
apiE m args = apiJ m args >>= convert where
  convert j@JSON{..} = do
    err <- pure $ Aeson.parseEither Aeson.parseJSON js_aeson
    ans <- pure $ Aeson.parseEither Aeson.parseJSON js_aeson
    case  (ans, err) of
      (Right a, _) -> return (Right a)
      (Left a, Right e) -> return (Left e)
      (Left a, Left e) -> do
        j' <- raise (JSONCovertionFailure j)
        convert j'

-- | Invoke the request, returns answer or the default value in case of error
apiD :: (Aeson.FromJSON a, MonadAPI m x s)
    => a
    -> String           -- ^ API method name
    -> [(String, Text)] -- ^ API method arguments
    -> API m x a
apiD def m args =
  apiE m args >>= \case
    Left err -> return def
    Right x -> return x

-- | String version of @api@
-- Deprecated
api_S :: (Aeson.FromJSON a, MonadAPI m x s)
    => String -> [(String, String)] -> API m x a
api_S m args = api m (map (id *** tpack) args)

-- Encode JSON back to string
jsonEncode :: JSON -> ByteString
jsonEncode JSON{..} = BS.concat $ toChunks $ Aeson.encode js_aeson

jsonEncodePretty :: JSON -> ByteString
jsonEncodePretty JSON{..} = BS.concat $ toChunks $ Aeson.encodePretty js_aeson

