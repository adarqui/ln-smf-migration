{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module LN.SMF.Migration.ThreadPost (
  createLegacyThreadPosts,
  deleteLegacyThreadPosts
) where



import           Control.Monad                  (forM_, void)
import           Control.Monad.IO.Class         (liftIO)
import           Control.Monad.Trans.RWS
import qualified Data.ByteString.Char8          as BSC
import           Data.Int
import           Data.Text                      (Text)
import           Database.MySQL.Simple
import           LN.Api
import           LN.SMF.Migration.Connect.Redis
import           LN.SMF.Migration.Control
import           LN.SMF.Migration.Sanitize
import           LN.T



createLegacyThreadPosts :: MigrateRWST ()
createLegacyThreadPosts = do

  liftIO $ putStrLn "migrating thread posts.."

  mysql <- asks rMySQL
  limit <- asks rLimit


  thread_posts <- liftIO $ query mysql "select id_msg, id_topic, poster_time, id_member, subject, body, poster_ip from smf_messages LIMIT ?" (Only limit)

  thread_post_ids <- smfIds "threadPostsName"

  forum_ids <- lnIds "forumsName"

  case forum_ids of
    [] -> liftIO $ putStrLn "Forum does not exist."
    (_:_) -> do

      forM_
        (filter (\(id_msg, _, _, _, _, _, _) -> not $ id_msg `elem` thread_post_ids) thread_posts)
        (\(id_msg :: Int64,
           id_topic :: Int64,
           poster_time :: Int64,
           id_member :: Int64,
           subject :: Text,
           body :: Text,
           poster_ip :: Text
          ) -> do

            liftIO $ print $ (id_msg, id_topic, poster_time, id_member, subject, poster_ip)

            mtopic <- findLnIdFromSmfId "threadsName" id_topic
            muser  <- findLnIdFromSmfId "usersName" id_member

            case (mtopic, muser) of
              (Just topic, Just user) -> do
                eresult <- liftIO $ rw (postThreadPost_ByThreadId [UnixTimestamp poster_time] topic $
                  ThreadPostRequest (Just $ sanitizeHtml subject) (PostDataBBCode $ sanitizeHtml body) [] []) (BSC.pack $ show user)

                case eresult of
                  (Left err) -> liftIO $ print err
                  (Right thread_post_response) -> do
                    createRedisMap "threadPostsName" id_msg (threadPostResponseId thread_post_response)

              (_, _) -> return ()
        )

  return ()



deleteLegacyThreadPosts :: MigrateRWST ()
deleteLegacyThreadPosts = do

  thread_post_ids <- lnIds "threadPostsName"

  forM_ thread_post_ids
    (\thread_post_id -> do

      liftIO $ putStrLn $ show thread_post_id

      eresult <- liftIO $ rd (getThreadPost' thread_post_id)
      case eresult of
        Left err -> liftIO $ print err
        Right thread_post_response -> do

          void $ liftIO $ rw (deleteThreadPost' thread_post_id) (BSC.pack $ show $ threadPostResponseUserId thread_post_response)
          deleteRedisMapByLnId "threadPostsName" thread_post_id
    )

  return ()