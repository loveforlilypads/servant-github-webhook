{-|
Module      : Servant.GitHub.Webhook
Description : Easily write safe GitHub webhook handlers with Servant
Copyright   : (c) Jacob Thomas Errington, 2016
License     : MIT
Maintainer  : servant-github-webhook@mail.jerrington.me
Stability   : experimental

The GitHub webhook machinery will attach three headers to the HTTP requests
that it fires: @X-Github-Event@, @X-Hub-Signature@, and @X-Github-Delivery@.
The former two headers correspond with the 'GitHubEvent' and
'GitHubSignedReqBody' routing combinators. This library ignores the
@X-Github-Delivery@ header for the most part; if you would like to access its
value, then use the builtin 'Header' combinator from servant.

Usage of the library is straightforward: protect routes with the 'GitHubEvent'
combinator to ensure that the route is only reached for specific
'RepoWebhookEvent's, and replace any 'ReqBody' combinators you would write
under that route with 'GitHubSignedReqBody'. It is advised to always include a
'GitHubSignedReqBody', as this is the only way you can be sure that it is
GitHub who is sending the request, and not a malicious user. If you don't care
about the request body, then simply use Aeson\'s 'Object' type as the
deserialization target -- @GitHubSignedReqBody \'[JSON] Object@ -- and ignore
the @Object@ in the handler.

The 'GitHubSignedReqBody' combinator makes use of the Servant 'Context' in
order to extract the signing key. This is the same key that must be entered in
the configuration of the webhook on GitHub. See 'GitHubKey' for more details.
-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Servant.GitHub.Webhook
( -- * Combinators
  GitHubSignedReqBody
, GitHubEvent
, GitHubKey(..)

  -- ** Example
  --
  -- $example

  -- * GitHub library reexports
, RepoWebhookEvent(..)

  -- * Implementation details
  -- ** Type-level programming machinery
, Demote(..)
, Reflect(..)
  -- ** Stringy stuff
, parseHeaderMaybe
, matchEvent
) where

import Control.Monad.IO.Class ( liftIO )
import Data.Aeson ( decode', encode )
import qualified Data.ByteString as BS
import Data.ByteString.Lazy ( fromStrict, toStrict )
import qualified Data.ByteString.Base16 as B16
import Data.HMAC ( hmac_sha1 )
import Data.Maybe ( catMaybes, fromMaybe )
import Data.Proxy
import Data.String.Conversions ( cs )
import qualified Data.Text.Encoding as E
import GHC.TypeLits
import GitHub.Data.Webhooks
import Network.HTTP.Types hiding (Header, ResponseHeaders)
import Network.Wai ( requestHeaders, strictRequestBody )
import Servant
import Servant.API.ContentTypes ( AllCTUnrender(..) )
import Servant.Server.Internal


-- | A clone of Servant\'s 'ReqBody' combinator, except that it will also
-- verify the signature provided by GitHub in the @X-Hub-Signature@ header by
-- computing the SHA1 HMAC of the request body and comparing.
--
-- The use of this combinator will require that the router context contain a
-- 'GitHubKey' entry. Consequently, it will be necessary to use
-- 'serveWithContext' instead of 'serve'.
--
-- Other routes are not tried upon the failure of this combinator, and a 401
-- response is generated.
data GitHubSignedReqBody (list :: [*]) (result :: *) where

-- | A routing combinator that succeeds only for a webhook request that matches
-- one of the given 'RepoWebhookEvent' given in the type-level list @events@.
--
-- If the list contains 'WebhookWildcardEvent', then all events will be
-- matched.
--
-- The combinator will require that its associated handler take a
-- 'RepoWebhookEvent' parameter, and the matched event will be passed to the
-- handler. This allows the handler to determine which event triggered it from
-- the list.
--
-- Other routes are tried if there is a mismatch.
data GitHubEvent (events :: [RepoWebhookEvent]) where

-- | A wrapper for an IO strategy to obtain the signing key for the webhook as
-- configured in GitHub. The strategy is executed each time the
-- 'GitHubSignedReqBody''s routing logic is executed.
--
-- We allow the use of @IO@ here so that you can fetch the key from a cache or
-- a database. If the key is a constant or read only once, just use 'pure'.
newtype GitHubKey = GitHubKey { unGitHubKey :: IO BS.ByteString }

instance forall sublayout context list result.
  ( HasServer sublayout context
  , HasContextEntry context GitHubKey
  , AllCTUnrender list result
  )
  => HasServer (GitHubSignedReqBody list result :> sublayout) context where

  type ServerT (GitHubSignedReqBody list result :> sublayout) m
    = result -> ServerT sublayout m

  route
    :: forall env. Proxy (GitHubSignedReqBody list result :> sublayout)
    -> Context context
    -> Delayed env (result -> Server sublayout)
    -> Router env
  route _ context subserver
    = route (Proxy :: Proxy sublayout) context (addBodyCheck subserver go)
    where
      lookupSig = lookup "X-Hub-Signature"

      go :: DelayedIO result
      go = withRequest $ \req -> do
        let hdrs = requestHeaders req
        key <- BS.unpack <$> liftIO (unGitHubKey $ getContextEntry context)
        msg <- BS.unpack <$> liftIO (toStrict <$> strictRequestBody req)
        let sig = B16.encode $ BS.pack $ hmac_sha1 key msg
        let contentTypeH = fromMaybe "application/octet-stream"
                         $ lookup hContentType $ hdrs
        let mrqbody =
              handleCTypeH (Proxy :: Proxy list) (cs contentTypeH) $
              fromStrict (BS.pack msg)

        case mrqbody of
          Nothing -> delayedFailFatal err415
          Just (Left e) -> delayedFailFatal err400 { errBody = cs e }
          Just (Right v) -> case parseHeaderMaybe =<< lookupSig hdrs of
            Nothing -> delayedFailFatal err401
            Just h -> do
              let h' = BS.drop 5 $ E.encodeUtf8 h -- remove "sha1=" prefix
              if h' == sig
              then pure v
              else delayedFailFatal err401

instance forall sublayout context events.
  (Reflect events, HasServer sublayout context)
  => HasServer (GitHubEvent events :> sublayout) context where

  type ServerT (GitHubEvent events :> sublayout) m
    = RepoWebhookEvent -> ServerT sublayout m

  route
    :: forall env. Proxy (GitHubEvent events :> sublayout)
    -> Context context
    -> Delayed env (RepoWebhookEvent -> Server sublayout)
    -> Router env
  route Proxy context subserver
    = route
      (Proxy :: Proxy sublayout)
      context
      (addAuthCheck subserver go)
    where
      lookupGHEvent = lookup "X-Github-Event"

      events :: [RepoWebhookEvent]
      events = reflect (Proxy :: Proxy events)

      go :: DelayedIO RepoWebhookEvent
      go = withRequest $ \req -> do
        case lookupGHEvent (requestHeaders req) of
          Nothing -> delayedFail err401
          Just h ->
            case catMaybes $ map (`matchEvent` h) events of
              [] -> delayedFail err400
              (event:_) -> pure event

-- | Type function that reflects a kind to a type.
type family Demote' (kparam :: KProxy k) :: *
type Demote (a :: k) = Demote' ('KProxy :: KProxy k)

type instance Demote' ('KProxy :: KProxy Symbol) = String
type instance Demote' ('KProxy :: KProxy [k]) = [Demote' ('KProxy :: KProxy k)]
type instance Demote' ('KProxy :: KProxy RepoWebhookEvent) = RepoWebhookEvent

-- | Class of types that can be reflected to values.
class Reflect (a :: k) where
  reflect :: Proxy (a :: k) -> Demote a

instance KnownSymbol s => Reflect (s :: Symbol) where
  reflect = symbolVal

instance Reflect '[] where
  reflect _ = []

instance (Reflect x, Reflect xs) => Reflect (x ': xs) where
  reflect _ = reflect x : reflect xs where
    x = Proxy :: Proxy x
    xs = Proxy :: Proxy xs

instance Reflect 'WebhookWildcardEvent where
  reflect _ = WebhookWildcardEvent

instance Reflect 'WebhookCommitCommentEvent where
  reflect _ = WebhookCommitCommentEvent

instance Reflect 'WebhookCreateEvent where
  reflect _ = WebhookCreateEvent

instance Reflect 'WebhookDeleteEvent where
  reflect _ = WebhookDeleteEvent

instance Reflect 'WebhookDeploymentEvent where
  reflect _ = WebhookDeploymentEvent

instance Reflect 'WebhookDeploymentStatusEvent where
  reflect _ = WebhookDeploymentStatusEvent

instance Reflect 'WebhookForkEvent where
  reflect _ = WebhookForkEvent

instance Reflect 'WebhookGollumEvent where
  reflect _ = WebhookGollumEvent

instance Reflect 'WebhookIssueCommentEvent where
  reflect _ = WebhookIssueCommentEvent

instance Reflect 'WebhookIssuesEvent where
  reflect _ = WebhookIssuesEvent

instance Reflect 'WebhookMemberEvent where
  reflect _ = WebhookMemberEvent

instance Reflect 'WebhookPageBuildEvent where
  reflect _ = WebhookPageBuildEvent

instance Reflect 'WebhookPublicEvent where
  reflect _ = WebhookPublicEvent

instance Reflect 'WebhookPullRequestReviewCommentEvent where
  reflect _ = WebhookPullRequestReviewCommentEvent

instance Reflect 'WebhookPullRequestEvent where
  reflect _ = WebhookPullRequestEvent

instance Reflect 'WebhookPushEvent where
  reflect _ = WebhookPushEvent

instance Reflect 'WebhookReleaseEvent where
  reflect _ = WebhookReleaseEvent

instance Reflect 'WebhookStatusEvent where
  reflect _ = WebhookStatusEvent

instance Reflect 'WebhookTeamAddEvent where
  reflect _ = WebhookTeamAddEvent

instance Reflect 'WebhookWatchEvent where
  reflect _ = WebhookWatchEvent

-- | Helper that parses a header using a 'FromHttpApiData' instance and
-- discards the parse error message if any.
parseHeaderMaybe :: FromHttpApiData a => BS.ByteString -> Maybe a
parseHeaderMaybe = eitherMaybe . parseHeader where
  eitherMaybe :: Either e a -> Maybe a
  eitherMaybe e = case e of
    Left _ -> Nothing
    Right x -> Just x

matchEvent :: RepoWebhookEvent -> BS.ByteString -> Maybe RepoWebhookEvent
matchEvent WebhookWildcardEvent s = decode' (fromStrict s)
matchEvent e name
  | toStrict (encode e) == name = Just e
  | otherwise = Nothing

-- $example
-- > import Data.Aeson ( Object )
-- > import qualified Data.ByteString as BS
-- > import Servant.GitHub.Webhook
-- > import Servant.Server
-- > import Network.Wai ( Application )
-- > import Network.Wai.Handler.Warp ( run )
-- >
-- > main :: IO ()
-- > main = do
-- >   key <- BS.init <$> BS.readFile "hook-secret"
-- >   run 8080 (app (GitHubKey $ pure key))
-- >
-- > app :: GitHubKey -> Application
-- > app key
-- >   = serveWithContext
-- >     (Proxy :: Proxy API)
-- >     (key :. EmptyContext)
-- >     server
-- >
-- > server :: Server API
-- > server = pushEvent
-- >
-- > pushEvent :: RepoWebHookEvent -> Object -> Handler ()
-- > pushEvent _ _
-- >   = liftIO $ putStrLn "someone pushed to servant-github-webhook!"
-- >
-- > type API
-- >   =
-- >   :<|> "servant-github-webhook"
-- >     :> GitHubEvent '[ 'WebhookPushEvent ]
-- >     :> GitHubSignedReqBody '[JSON] Object
-- >     :> Post '[JSON] ()