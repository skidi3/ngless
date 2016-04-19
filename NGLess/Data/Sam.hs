{- Copyright 2014-2016 NGLess Authors
 - License: MIT
 -}
{-# LANGUAGE FlexibleContexts, OverloadedStrings #-}
module Data.Sam
    ( SamLine(..)
    , SamResult(..)
    , samLength
    , readSamGroupsC
    , readSamLine
    , encodeSamLine
    , isAligned
    , isPositive
    , isNegative
    , isFirstInPair
    , isSecondInPair
    , matchSize
    , matchIdentity
    ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Char8 as S8
import qualified Data.Text as T
import qualified Data.Conduit.List as CL
import qualified Data.Conduit as C
import           Data.Strict.Tuple (Pair(..))
import Data.Bits (testBit)
import Control.Error (note)
import Control.DeepSeq

import Data.Maybe
import Data.Conduit ((=$=))
import Data.Function (on)
import Control.Monad.Except
import NGLess.NGError
import Utils.Conduit


data SamLine = SamLine
            { samQName :: !B.ByteString
            , samFlag :: {-# UNPACK #-} !Int
            , samRName :: {-# UNPACK #-} !B.ByteString
            , samPos :: {-# UNPACK #-} !Int
            , samMapq :: {-# UNPACK #-} !Int
            , samCigar :: {-# UNPACK #-} !B.ByteString
            , samRNext :: {-# UNPACK #-} !B.ByteString
            , samPNext :: {-# UNPACK #-} !Int
            , samTLen :: {-# UNPACK #-} !Int
            , samSeq :: {-# UNPACK #-} !B.ByteString
            , samQual :: {-# UNPACK #-} !B.ByteString
            , samExtra :: {-# UNPACK #-} !B.ByteString
            } | SamHeader !B.ByteString
             deriving (Eq, Show, Ord)


instance NFData SamLine where
    rnf SamLine{} = ()
    rnf (SamHeader !_) = ()

data SamResult = Total | Aligned | Unique | LowQual deriving (Enum)

isHeader SamHeader{} = True
isHeader SamLine{} = False

samLength = B8.length . samSeq

-- log 2 of N
-- 4 -> 2
isAligned :: SamLine -> Bool
isAligned = not . (`testBit` 2) . samFlag

-- 16 -> 4
isNegative :: SamLine -> Bool
isNegative = (`testBit` 4) . samFlag

-- all others
isPositive :: SamLine -> Bool
isPositive = not . isNegative

isFirstInPair :: SamLine -> Bool
isFirstInPair = (`testBit` 6) . samFlag

isSecondInPair :: SamLine -> Bool
isSecondInPair = (`testBit` 7) . samFlag


newtype SimpleParser a = SimpleParser { runSimpleParser :: B.ByteString -> Maybe (Pair a B.ByteString) }
instance Functor SimpleParser where
    fmap f p = SimpleParser $ \b -> do
                                (v :!: rest) <- runSimpleParser p b
                                return $! (f v :!: rest)

instance Applicative SimpleParser where
    pure v = SimpleParser (\b -> Just (v :!: b))
    f <*> g = SimpleParser (\b -> do
                                (f' :!: rest) <- runSimpleParser f b
                                (g' :!: rest') <- runSimpleParser g rest
                                return $! (f' g' :!: rest'))

encodeSamLine :: SamLine -> B.ByteString
encodeSamLine (SamHeader b) = b
encodeSamLine samline = B.intercalate "\t"
    [ samQName samline
    , int2BS . samFlag $ samline
    , samRName samline
    , int2BS . samPos $ samline
    , int2BS . samMapq $ samline
    , samCigar samline
    , samRNext samline
    , int2BS . samPNext $ samline
    , int2BS . samTLen $ samline
    , samSeq samline
    , samQual samline
    , samExtra samline
    ]
    where int2BS = B8.pack . show

readSamLine :: B.ByteString -> Either NGError SamLine
readSamLine line
    | B8.head line == '@' = return (SamHeader line)
    | otherwise = case runSimpleParser samP line of
        Just (v :!: _) -> return v
        Nothing -> throwDataError ("Could not parse sam line "++show line)

tabDelim :: SimpleParser B.ByteString
tabDelim = SimpleParser $ \input -> do
    ix <- B8.elemIndex '\t' input
    return $! (B.take ix input :!: B.drop (ix+1) input)

readIntTab = SimpleParser $ \b -> do
        (v,rest) <- B8.readInt b
        return $! (v :!: B.tail rest)
restParser = SimpleParser $ \b -> Just (b :!: B.empty)
samP = SamLine
    <$> tabDelim
    <*> readIntTab
    <*> tabDelim
    <*> readIntTab
    <*> readIntTab
    <*> tabDelim
    <*> tabDelim
    <*> readIntTab
    <*> readIntTab
    <*> tabDelim
    <*> tabDelim
    <*> restParser

{--
Op     Description
M alignment match (can be a sequence match or mismatch).
I insertion to the reference
D deletion from the reference.
N skipped region from the reference.
S soft clipping (clipped sequences present inSEQ)
H hard clipping (clipped sequences NOT present inSEQ)
P padding (silent deletion from padded reference).
= sequence match.
X sequence mismatch.
--}

matchSize :: SamLine -> Either NGError Int
matchSize = matchSize' . samCigar
matchSize' cigar
    | B8.null cigar = return 0
    | otherwise = case B8.readInt cigar of
        Nothing -> throwDataError ("could not parse cigar '"++S8.unpack cigar ++"'")
        Just (n,code_rest) -> do
            let code = S8.head code_rest
                rest = S8.tail code_rest
                n' = if code `elem` ("M=X" :: String) then n else 0
            r <- matchSize' rest
            return (n' + r)

matchIdentity :: SamLine -> Either NGError Double
matchIdentity samline = do
    let errmsg = T.pack $ "Could not get NM tag for samline " ++ B8.unpack (samQName samline) ++ ", extra tags were: "++ B8.unpack (samExtra samline)
    errors <- note (NGError DataError errmsg) $ samIntTag samline "NM"
    len <- matchSize samline
    let toDouble = fromInteger . toInteger
        mid = toDouble (len - errors) / toDouble len
    return mid

samIntTag :: SamLine -> B.ByteString -> Maybe Int
samIntTag samline tname
    | isHeader samline = Nothing
    | otherwise = listToMaybe . mapMaybe gettag . B8.split '\t' . samExtra $ samline
    where
        gettag match
            | B.take 2 match == tname
                    && (fst <$> B8.uncons (B.drop 3 match)) == Just 'i' = fst <$> B8.readInt (B.drop 5 match)
            | otherwise = Nothing

-- | take in *lines* and transform them into groups of SamLines all refering to the same read
readSamGroupsC :: (MonadError NGError m) => C.Conduit ByteLine m [SamLine]
readSamGroupsC = readSamLineOrDie =$= CL.groupBy groupLine
    where
        readSamLineOrDie = C.awaitForever $ \(ByteLine line) ->
            case readSamLine line of
                Left err -> throwError err
                Right parsed@SamLine{} -> C.yield parsed
                _ -> return ()
        groupLine = (==) `on` samQName

