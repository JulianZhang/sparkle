{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE StaticPointers #-}
module Control.Distributed.Spark where

import           Closure
import           Control.Distributed.Closure
-- import           Data.Binary.Serialise.CBOR
import qualified Data.ByteString as BS
import           Data.ByteString (ByteString)
import           Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import           Data.Monoid     ((<>))
import           Foreign.C.String (withCString)
import           Foreign.C.Types
import           Foreign.Marshal.Array (withArrayLen, peekArray)
import           Foreign.Marshal.Alloc (alloca)
import           Foreign.Storable (peek)
import           JNI
import qualified Language.C.Inline as C

C.context (C.baseCtx <> jniCtx)

-- TODO:
-- eventually turn all the 'type's into 'newtype's?

type SparkConf = JObject

newSparkConf :: String -> IO SparkConf
newSparkConf appname = do
  cls <- findClass "org/apache/spark/SparkConf"
  setAppName <- findMethod cls "setAppName" "(Ljava/lang/String;)Lorg/apache/spark/SparkConf;"
  cnf <- newObject cls "()V" []
  jname <- newString appname
  callObjectMethod cnf setAppName [JObj jname]
  return cnf

type SparkContext = JObject

newSparkContext :: SparkConf -> IO SparkContext
newSparkContext conf = do
  cls <- findClass "org/apache/spark/api/java/JavaSparkContext"
  newObject cls "(Lorg/apache/spark/SparkConf;)V" [JObj conf]

type RDD a = JObject

parallelize :: SparkContext -> [CInt] -> IO (RDD CInt)
parallelize sc xs = do
  cls <- findClass "Helper"
  method <- findStaticMethod cls "parallelize" "(Lorg/apache/spark/api/java/JavaSparkContext;[I)Lorg/apache/spark/api/java/JavaRDD;"
  jxs <- newIntArray (fromIntegral $ length xs) xs
  callStaticObjectMethod cls method [JObj sc, JObj jxs]

rddmap :: Closure (CInt -> CInt)
       -> RDD CInt
       -> IO (RDD CInt)
rddmap clos rdd =
  unsafeUseAsCStringLen closBS $ \(closBuf, closSize) -> do
    closArr <- newByteArray' (fromIntegral closSize) closBuf
    cls <- findClass "Helper"
    method <- findStaticMethod cls "map" "(Lorg/apache/spark/api/java/JavaRDD;[B)Lorg/apache/spark/api/java/JavaRDD;"
    callStaticObjectMethod cls method [JObj rdd, JObj closArr]

  where closBS = clos2bs clos

-- TODO: rewrite this without using inline-c
collect :: RDD CInt -> IO [CInt]
collect rdd = fmap (map fromIntegral) $
  alloca $ \buf ->
  alloca $ \size -> do
    [C.block| void {
      collect($(jobject rdd), $(int** buf), $(size_t* size));
    } |]
    sz <- peek size
    b  <- peek buf
    peekArray (fromIntegral sz) b

type PairRDD a b = JObject

zipWithIndex :: RDD a -> IO (PairRDD CLong a)
zipWithIndex rdd = do
  cls <- findClass "org/apache/spark/api/java/JavaRDD"
  method <- findMethod cls "zipWithIndex" "()Lorg/apache/spark/api/java/JavaPairRDD;"
  prdd <- callObjectMethod rdd method []
  helper <- findClass "Helper"
  swap <- findStaticMethod helper "swapPairs" "(Lorg/apache/spark/api/java/JavaPairRDD;)Lorg/apache/spark/api/java/JavaPairRDD;"
  callStaticObjectMethod helper swap [JObj prdd]

textFile :: SparkContext -> String -> IO (RDD String)
textFile sc path = do
  jpath <- newString path
  cls <- findClass "org/apache/spark/api/java/JavaSparkContext"
  method <- findMethod cls "textFile" "(Ljava/lang/String;)Lorg/apache/spark/api/java/JavaRDD;"
  callObjectMethod sc method [JObj jpath]

wholeTextFiles :: SparkContext -> String -> IO (PairRDD String String)
wholeTextFiles sc uri = do
  juri <- newString uri
  cls <- findClass "org/apache/spark/api/java/JavaSparkContext"
  method <- findMethod cls "wholeTextFiles" "(Ljava/lang/String;)Lorg/apache/spark/api/java/JavaPairRDD;"
  callObjectMethod sc method [JObj juri]

justValues :: PairRDD a b -> IO (RDD b)
justValues prdd = do
  cls <- findClass "org/apache/spark/api/java/JavaPairRDD"
  values <- findMethod cls "values" "()Lorg/apache/spark/api/java/JavaRDD;"
  callObjectMethod prdd values []

type SQLContext = JObject

newSQLContext :: SparkContext -> IO SQLContext
newSQLContext sc = do
  cls <- findClass "org/apache/spark/sql/SQLContext"
  newObject cls "(Lorg/apache/spark/api/java/JavaSparkContext;)V" [JObj sc]

type Row = JObject
type DataFrame = JObject

toRows :: PairRDD a b -> IO (RDD Row)
toRows prdd = do
  cls <- findClass "Helper"
  mth <- findStaticMethod cls "toRows" "(Lorg/apache/spark/api/java/JavaPairRDD;)Lorg/apache/spark/api/java/JavaRDD;"
  callStaticObjectMethod cls mth [JObj prdd]

toDF :: SQLContext -> RDD Row -> String -> String -> IO DataFrame
toDF sqlc rdd s1 s2 = do
  cls <- findClass "Helper"
  mth <- findStaticMethod cls "toDF" "(Lorg/apache/spark/sql/SQLContext;Lorg/apache/spark/api/java/JavaRDD;Ljava/lang/String;Ljava/lang/String;)Lorg/apache/spark/sql/DataFrame;"
  col1 <- newString s1
  col2 <- newString s2
  callStaticObjectMethod cls mth [JObj sqlc, JObj rdd, JObj col1, JObj col2]

type RegexTokenizer = JObject

newTokenizer :: String -> String -> IO RegexTokenizer
newTokenizer icol ocol = do
  cls <- findClass "org/apache/spark/ml/feature/RegexTokenizer"
  tok0 <- newObject cls "()V" []
  let patt = "\\p{L}+"
  let gaps = False
  let jgaps = if gaps then 1 else 0
  jpatt <- newString patt
  jicol <- newString icol
  jocol <- newString ocol
  helper <- findClass "Helper"
  setuptok <- findStaticMethod helper "setupTokenizer" "(Lorg/apache/spark/ml/feature/RegexTokenizer;Ljava/lang/String;Ljava/lang/String;ZLjava/lang/String;)Lorg/apache/spark/ml/feature/RegexTokenizer;"
  callStaticObjectMethod helper setuptok [JObj tok0, JObj jicol, JObj jocol, JBoolean jgaps, JObj jpatt]

tokenize :: RegexTokenizer -> DataFrame -> IO DataFrame
tokenize tok df = do
  cls <- findClass "org/apache/spark/ml/feature/RegexTokenizer"
  mth <- findMethod cls "transform" "(Lorg/apache/spark/sql/DataFrame;)Lorg/apache/spark/sql/DataFrame;"
  callObjectMethod tok mth [JObj df]

type StopWordsRemover = JObject

newStopWordsRemover :: [String] -> String -> String -> IO StopWordsRemover
newStopWordsRemover stopwords icol ocol = do
  cls <- findClass "org/apache/spark/ml/feature/StopWordsRemover"
  swr0 <- newObject cls "()V" []
  setSw <- findMethod cls "setStopWords" "([Ljava/lang/String;)Lorg/apache/spark/ml/feature/StopWordsRemover;"
  stringCls <- findClass "java/lang/String"
  let len = fromIntegral (length stopwords)
  jstopwords <- newObjectArray len stringCls =<< mapM newString stopwords
  swr1 <- callObjectMethod swr0 setSw [JObj jstopwords]
  setCS <- findMethod cls "setCaseSensitive" "(Z)Lorg/apache/spark/ml/feature/StopWordsRemover;"
  swr2 <- callObjectMethod swr1 setCS [JBoolean 0]
  seticol <- findMethod cls "setInputCol" "(Ljava/lang/String;)Lorg/apache/spark/ml/feature/StopWordsRemover;"
  setocol <- findMethod cls "setOutputCol" "(Ljava/lang/String;)Lorg/apache/spark/ml/feature/StopWordsRemover;"
  jicol <- newString icol
  jocol <- newString ocol
  swr3 <- callObjectMethod swr2 seticol [JObj jicol]
  callObjectMethod swr3 setocol [JObj jocol]

removeStopWords :: StopWordsRemover -> DataFrame -> IO DataFrame
removeStopWords sw df = do
  cls <- findClass "org/apache/spark/ml/feature/StopWordsRemover"
  mth <- findMethod cls "transform" "(Lorg/apache/spark/sql/DataFrame;)Lorg/apache/spark/sql/DataFrame;"
  callObjectMethod sw mth [JObj df]

type CountVectorizer = JObject

newCountVectorizer :: CInt -> String -> String -> IO CountVectorizer
newCountVectorizer vocSize icol ocol = do
  cls <- findClass "org/apache/spark/ml/feature/CountVectorizer"
  cv  <- newObject cls "()V" []
  setInpc <- findMethod cls "setInputCol" "(Ljava/lang/String;)Lorg/apache/spark/ml/feature/CountVectorizer;"
  jfiltered <- newString icol
  cv' <- callObjectMethod cv setInpc [JObj jfiltered]
  setOutc <- findMethod cls "setOutputCol" "(Ljava/lang/String;)Lorg/apache/spark/ml/feature/CountVectorizer;"
  jfeatures <- newString ocol
  cv'' <- callObjectMethod cv' setOutc [JObj jfeatures]
  setVocSize <- findMethod cls "setVocabSize" "(I)Lorg/apache/spark/ml/feature/CountVectorizer;"
  callObjectMethod cv'' setVocSize [JInt vocSize]

type CountVectorizerModel = JObject

fitCV :: CountVectorizer -> DataFrame -> IO CountVectorizerModel
fitCV cv df = do
  cls <- findClass "org/apache/spark/ml/feature/CountVectorizer"
  mth <- findMethod cls "fit" "(Lorg/apache/spark/sql/DataFrame;)Lorg/apache/spark/ml/feature/CountVectorizerModel;"
  callObjectMethod cv mth [JObj df]

type SparkVector = JObject

toTokenCounts :: CountVectorizerModel -> DataFrame -> String -> String -> IO (PairRDD CLong SparkVector)
toTokenCounts cvModel df col1 col2 = do
  cls <- findClass "org/apache/spark/ml/feature/CountVectorizerModel"
  mth <- findMethod cls "transform" "(Lorg/apache/spark/sql/DataFrame;)Lorg/apache/spark/sql/DataFrame;"
  df' <- callObjectMethod cvModel mth [JObj df]

  helper <- findClass "Helper"
  fromDF <- findStaticMethod helper "fromDF" "(Lorg/apache/spark/sql/DataFrame;Ljava/lang/String;Ljava/lang/String;)Lorg/apache/spark/api/java/JavaRDD;"
  fromRows <- findStaticMethod helper "fromRows" "(Lorg/apache/spark/api/java/JavaRDD;)Lorg/apache/spark/api/java/JavaPairRDD;"
  jcol1 <- newString col1
  jcol2 <- newString col2
  rdd <- callStaticObjectMethod helper fromDF [JObj df', JObj jcol1, JObj jcol2]
  callStaticObjectMethod helper fromRows [JObj rdd]

type LDA = JObject

newLDA :: CDouble -- ^ fraction of documents
       -> CInt    -- ^ number of topics
       -> CInt    -- ^ maximum number of iterations
       -> IO LDA
newLDA frac numTopics maxIterations = do
  cls <- findClass "org/apache/spark/mllib/clustering/LDA"
  lda <- newObject cls "()V" []

  opti_cls <- findClass "org/apache/spark/mllib/clustering/OnlineLDAOptimizer"
  opti <- newObject opti_cls "()V" []
  setMiniBatch <- findMethod opti_cls "setMiniBatchFraction" "(D)Lorg/apache/spark/mllib/clustering/OnlineLDAOptimizer;"
  opti' <- callObjectMethod opti setMiniBatch [JDouble frac]

  setOpti <- findMethod cls "setOptimizer" "(Lorg/apache/spark/mllib/clustering/LDAOptimizer;)Lorg/apache/spark/mllib/clustering/LDA;"
  lda' <- callObjectMethod lda setOpti [JObj opti']

  setK <- findMethod cls "setK" "(I)Lorg/apache/spark/mllib/clustering/LDA;"
  lda'' <- callObjectMethod lda' setK [JInt numTopics]

  setMaxIter <- findMethod cls "setMaxIterations" "(I)Lorg/apache/spark/mllib/clustering/LDA;"
  lda''' <- callObjectMethod lda'' setMaxIter [JInt maxIterations]

  setDocConc <- findMethod cls "setDocConcentration" "(D)Lorg/apache/spark/mllib/clustering/LDA;"
  lda'''' <- callObjectMethod lda''' setDocConc [JDouble $ negate 1]

  setTopicConc <- findMethod cls "setTopicConcentration" "(D)Lorg/apache/spark/mllib/clustering/LDA;"
  lda''''' <- callObjectMethod lda'''' setTopicConc [JDouble $ negate 1]

  return lda'''''

type LDAModel = JObject

runLDA :: LDA -> PairRDD CLong SparkVector -> IO LDAModel
runLDA lda rdd = do
  cls <- findClass "Helper"
  run <- findStaticMethod cls "runLDA" "(Lorg/apache/spark/mllib/clustering/LDA;Lorg/apache/spark/api/java/JavaPairRDD;)Lorg/apache/spark/mllib/clustering/LDAModel;"
  callStaticObjectMethod cls run [JObj lda, JObj rdd]

describeResults :: LDAModel -> CountVectorizerModel -> CInt -> IO ()
describeResults lm cvm maxTerms = do
  cls <- findClass "Helper"
  mth <- findStaticMethod cls "describeResults" "(Lorg/apache/spark/mllib/clustering/LDAModel;Lorg/apache/spark/ml/feature/CountVectorizerModel;I)V"
  callStaticVoidMethod cls mth [JObj lm, JObj cvm, JInt maxTerms]

selectDF :: DataFrame -> [String] -> IO DataFrame
selectDF df (col:cols) = do
  cls <- findClass "org/apache/spark/sql/DataFrame"
  mth <- findMethod cls "select" "(Ljava/lang/String;[Ljava/lang/String;)Lorg/apache/spark/sql/DataFrame;"
  jcol <- newString col
  jcols <- mapM newString cols
  strCls <- findClass "java/lang/String"
  jcolA <- newObjectArray (fromIntegral $ length jcols) strCls jcols
  callObjectMethod df mth [JObj jcol, JObj jcolA]

debugDF :: DataFrame -> IO ()
debugDF df = do
  cls <- findClass "org/apache/spark/sql/DataFrame"
  mth <- findMethod cls "show" "()V"
  callVoidMethod df mth []