{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module LN.SMF.Migration.ThreadPostLike (
  createLegacyThreadPostLikes,
  deleteLegacyThreadPostLikes
) where



import           Control.Monad                  (forM_, void)
import           Control.Monad.IO.Class         (liftIO)
import           Control.Monad.Trans.RWS
import qualified Data.ByteString.Char8          as BSC
import           Data.Int
import           Database.MySQL.Simple
import           LN.Api
import           LN.SMF.Migration.Connect.Redis
import           LN.SMF.Migration.Control
import           LN.T




createLegacyThreadPostLikes :: MigrateRWST ()
createLegacyThreadPostLikes = do

  liftIO $ putStrLn "migrating thread post likes"

  mysql <- asks rMySQL
  limit <- asks rLimit


  thread_post_likes <- liftIO $ query mysql "select id, id_msg, id_member, score from smf_log_gpbp LIMIT ?" (Only limit)

  thread_post_likes_ids <- smfIds "threadPostLikesName"

  forum_ids <- lnIds "forumsName"

  case forum_ids of
    [] -> liftIO $ putStrLn "Forum does not exist."
    (_:_) -> do

      forM_
        (filter (\(id_gpbp, _, _, _) -> not $ id_gpbp `elem` thread_post_likes_ids) thread_post_likes)
        (\(id_gpbp :: Int64,
           id_msg :: Int64,
           id_member :: Int64,
           score :: Int64
          ) -> do

            liftIO $ print $ (id_msg, id_member, score)

            mpost <- findLnIdFromSmfId "threadPostsName" id_msg
            muser <- findLnIdFromSmfId "usersName" id_member

            case (mpost, muser) of
              (Nothing, _) -> return ()
              (_, Nothing) -> return ()
              (Just post, Just user) -> do

                let like_score = if score == 1 then Like else Dislike

                eresult <- liftIO $ rw (postLike_ByThreadPostId' post $ LikeRequest like_score Nothing) (BSC.pack $ show user)

                case eresult of
                  (Left err) -> liftIO $ print err
                  (Right thread_post_like_response) -> do
                    createRedisMap "threadPostLikesName" id_gpbp (likeResponseId thread_post_like_response)

              (_, _) -> return ()
        )

  return ()



deleteLegacyThreadPostLikes :: MigrateRWST ()
deleteLegacyThreadPostLikes = do

  thread_post_likes_ids <- lnIds "threadPostLikesName"

  forM_ thread_post_likes_ids
    (\thread_post_like_id -> do

      liftIO $ putStrLn $ show thread_post_like_id

      eresult <- liftIO $ rd (getLike' thread_post_like_id)
      case eresult of
        Left err -> liftIO $ print err
        Right like_response -> do

          void $ liftIO $ rw (deleteLike' thread_post_like_id) (BSC.pack $ show $ likeResponseUserId like_response)
          deleteRedisMapByLnId "threadPostLikesName" thread_post_like_id
    )

  return ()