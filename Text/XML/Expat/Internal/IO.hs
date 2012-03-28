{-# LANGUAGE ForeignFunctionInterface, EmptyDataDecls #-}

-- | Low-level interface to Expat. Unless speed is paramount, this should
-- normally be avoided in favour of the interfaces provided by
-- 'Text.XML.Expat.SAX' and 'Text.XML.Expat.Tree', etc.  Basic usage is:
--
-- (1) Make a new parser: 'newParser'.
--
-- (2) Set up callbacks on the parser: 'setStartElementHandler', etc.
--
-- (3) Feed data into the parser: 'parse', 'parse'' or 'parseChunk'.  Some of
--     these functions must be wrapped in 'withParser'.

module Text.XML.Expat.Internal.IO (
  -- ** Parser Setup
  Parser, newParser,
  ParseOptions(..),

  -- ** Parsing
  parse, parse',
  withParser,
  ParserPtr, Parser_struct,
  parseChunk,
  Encoding(..),
  XMLParseError(..),
  getParseLocation,
  XMLParseLocation(..),

  -- ** Parser Callbacks
  XMLDeclarationHandler,
  StartElementHandler,
  EndElementHandler,
  CharacterDataHandler,
  ExternalEntityRefHandler,
  SkippedEntityHandler,
  StartCDataHandler,
  EndCDataHandler,
  CommentHandler,
  ProcessingInstructionHandler,
  setXMLDeclarationHandler,
  setStartElementHandler,
  setEndElementHandler,
  setCharacterDataHandler,
  setStartCDataHandler,
  setEndCDataHandler,
  setProcessingInstructionHandler,
  setCommentHandler,
  setExternalEntityRefHandler,
  setSkippedEntityHandler,
  setUseForeignDTD,
  setStartNamespaceDeclHandler,
  setEndNamespaceDeclHandler,

  -- ** Lower-level interface
  parseExternalEntityReference,
  ExpatHandlers,
  unsafeSetHandlers,
  unsafeReleaseHandlers,

  -- ** Helpers
  encodingToString

  ) where

import           Control.Concurrent
import           Control.DeepSeq
import           Control.Exception (bracket)
import           Control.Monad
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import           Data.Char
import           Data.IORef
import           Data.Text(Text)
import           Foreign hiding (unsafePerformIO)
import           Foreign.C
import           System.IO.Unsafe (unsafePerformIO)

-- |Opaque parser type.
data Parser_struct
type ParserPtr = Ptr Parser_struct
data Parser = Parser
    { _parserObj                    :: ForeignPtr Parser_struct
    , _xmlDeclarationHandler        :: IORef CXMLDeclarationHandler
    , _startElementHandler          :: IORef CStartElementHandler
    , _endElementHandler            :: IORef CEndElementHandler
    , _cdataHandler                 :: IORef CCharacterDataHandler
    , _externalEntityRefHandler     :: IORef (Maybe CExternalEntityRefHandler)
    , _skippedEntityHandler         :: IORef (Maybe CSkippedEntityHandler)
    , _startCDataHandler            :: IORef CStartCDataHandler
    , _endCDataHandler              :: IORef CEndCDataHandler
    , _processingInstructionHandler :: IORef CProcessingInstructionHandler
    , _commentHandler               :: IORef CCommentHandler
    , _startNamespaceDeclHandler    :: IORef CStartNamespaceDeclHandler
    , _endNamespaceDeclHandler      :: IORef CEndNamespaceDeclHandler
    }

instance Show Parser where
    showsPrec _ (Parser fp _ _ _ _ _ _ _ _ _ _ _ _) = showsPrec 0 fp

-- |Encoding types available for the document encoding.
data Encoding = ASCII | UTF8 | UTF16 | ISO88591
encodingToString :: Encoding -> String
encodingToString ASCII    = "US-ASCII"
encodingToString UTF8     = "UTF-8"
encodingToString UTF16    = "UTF-16"
encodingToString ISO88591 = "ISO-8859-1"

withOptEncoding :: Maybe Encoding -> (CString -> IO a) -> IO a
withOptEncoding Nothing    f = f nullPtr
withOptEncoding (Just enc) f = withCString (encodingToString enc) f


parserCreate :: Maybe Encoding -> IO (ParserPtr)
parserCreate a1 =
  withOptEncoding a1 $ \a1' -> do
      pp <- parserCreate'_ a1'
      xmlSetUserData pp pp
      return pp

data ParseOptions = ParseOptions
    { overrideEncoding :: Maybe Encoding
          -- ^ The encoding parameter, if provided, overrides the document's
          -- encoding declaration.
    , entityDecoder  :: Maybe (Text -> Maybe Text)
          -- ^ If provided, entity references (i.e. @&nbsp;@ and friends) will
          -- be decoded into text using the supplied lookup function
    }


parserCreateNS :: Maybe Encoding -> Char -> IO (ParserPtr)
parserCreateNS a1 sep=
  withOptEncoding a1 $ \a1' -> do
      pp <- parserCreateNS'_ a1' (fromIntegral (ord sep))
      xmlSetUserData pp pp
      return pp


-- | Create a 'Parser'.

newParser :: Maybe Encoding
             -> Maybe Char -- ^ Character to delimit namespaces or nothing
                           -- to ignore them
             -> IO Parser
newParser enc del = do
  ptr          <- case del of
                       Nothing -> parserCreate enc
                       Just delim -> parserCreateNS enc delim
  fptr         <- newForeignPtr parserFree ptr
  nullXMLDeclH <- newIORef nullCXMLDeclarationHandler
  nullStartH   <- newIORef nullCStartElementHandler
  nullEndH     <- newIORef nullCEndElementHandler
  nullCharH    <- newIORef nullCCharacterDataHandler
  extH         <- newIORef Nothing
  skipH        <- newIORef Nothing
  nullSCDataH  <- newIORef nullCStartCDataHandler
  nullECDataH  <- newIORef nullCEndCDataHandler
  nullPIH      <- newIORef nullCProcessingInstructionHandler
  nullCommentH <- newIORef nullCCommentHandler
  nullStartNS  <- newIORef nullCStartNamespaceDeclHandler
  nullEndNS    <- newIORef nullCEndNamespaceDeclHandler

  return $ Parser fptr nullXMLDeclH nullStartH nullEndH nullCharH extH skipH
    nullSCDataH nullECDataH nullPIH nullCommentH nullStartNS nullEndNS

setUseForeignDTD :: Parser -> Bool -> IO ()
setUseForeignDTD p b = withParser p $ \p' -> xmlUseForeignDTD p' b'
  where
    b' = if b then 1 else 0

-- ByteString.useAsCStringLen is almost what we need, but C2HS wants a CInt
-- instead of an Int.
withBStringLen :: BS.ByteString -> ((CString, CInt) -> IO a) -> IO a
withBStringLen bs f = do
  BS.useAsCStringLen bs $ \(str, len) -> f (str, fromIntegral len)

unStatus :: CInt -> Bool
unStatus 0 = False
unStatus _ = True

-- |@parse data@ feeds /lazy/ ByteString data into a 'Parser'. It returns
-- Nothing on success, or Just the parse error.
parse :: Parser -> BSL.ByteString -> IO (Maybe XMLParseError)
parse parser bs = withParser parser $ \pp -> do
    let
        doParseChunks [] = doParseChunk pp BS.empty True
        doParseChunks (c:cs) = do
            ok <- doParseChunk pp c False
            if ok
                then doParseChunks cs
                else return False
    ok <- doParseChunks (BSL.toChunks bs)
    if ok
        then return Nothing
        else Just `fmap` getError pp

-- |@parse data@ feeds /strict/ ByteString data into a 'Parser'. It returns
-- Nothing on success, or Just the parse error.
parse' :: Parser -> BS.ByteString -> IO (Maybe XMLParseError)
parse' parser bs = withParser parser $ \pp -> do
    ok <- doParseChunk pp bs True
    if ok
        then return Nothing
        else Just `fmap` getError pp

parseExternalEntityReference :: Parser
                             -> CString         -- ^ context
                             -> Maybe Encoding  -- ^ encoding
                             -> CStringLen      -- ^ text
                             -> IO Bool
parseExternalEntityReference parser context encoding (text,sz) =
    withParser parser $ \pp -> do
        extp <- withOptEncoding encoding $
                xmlExternalEntityParserCreate pp context
        e <- doParseChunk'_ extp text (fromIntegral sz) 1
        parserFree' extp
        return $ e == 1

-- |@parseChunk data False@ feeds /strict/ ByteString data into a
-- 'Parser'.  The end of the data is indicated by passing @True@ for the
-- final parameter.   It returns Nothing on success, or Just the parse error.
parseChunk :: ParserPtr
           -> BS.ByteString
           -> Bool
           -> IO (Maybe XMLParseError)
parseChunk pp xml final = do
    ok <- doParseChunk pp xml final
    if ok
        then return Nothing
        else Just `fmap` getError pp

getError :: ParserPtr -> IO XMLParseError
getError pp = do
    code <- xmlGetErrorCode pp
    cerr <- xmlErrorString code
    err <- peekCString cerr
    loc <- getParseLocation pp
    return $ XMLParseError err loc

data ExpatHandlers = ExpatHandlers
    (FunPtr CXMLDeclarationHandler)
    (FunPtr CStartElementHandler)
    (FunPtr CEndElementHandler)
    (FunPtr CCharacterDataHandler)
    (Maybe (FunPtr CExternalEntityRefHandler))
    (Maybe (FunPtr CSkippedEntityHandler))
    (FunPtr CStartCDataHandler)
    (FunPtr CEndCDataHandler)
    (FunPtr CProcessingInstructionHandler)
    (FunPtr CCommentHandler)
    (FunPtr CStartNamespaceDeclHandler)
    (FunPtr CEndNamespaceDeclHandler)


-- | Most of the low-level functions take a ParserPtr so are required to be
-- called inside @withParser@.
withParser :: Parser
           -> (ParserPtr -> IO a)  -- ^ Computation where parseChunk and other low-level functions may be used
           -> IO a
withParser parser code =
  withForeignPtr (_parserObj parser) $ \pp -> do
    bracket
       (unsafeSetHandlers parser pp)
        unsafeReleaseHandlers
        (\_ -> code pp)

unsafeSetHandlers :: Parser -> ParserPtr -> IO ExpatHandlers
unsafeSetHandlers (Parser _ xmlDeclRef startRef
                              endRef charRef extRef skipRef
                              startCDataRef endCDataRef processingInstructionRef
                              commentRef startNSRef endNSRef) pp =
      do
        cXMLDeclH <- mkCXMLDeclarationHandler =<< readIORef xmlDeclRef
        cStartH <- mkCStartElementHandler =<< readIORef startRef
        cEndH   <- mkCEndElementHandler =<< readIORef endRef
        cCharH  <- mkCCharacterDataHandler =<< readIORef charRef
        mExtH   <- readIORef extRef >>=
                       maybe (return Nothing)
                             (\h -> liftM Just $ mkCExternalEntityRefHandler h)

        mSkipH  <- readIORef skipRef >>=
                       maybe (return Nothing)
                             (\h -> liftM Just $ mkCSkippedEntityHandler h)

        cStartCDataH <- mkCStartCDataHandler =<< readIORef startCDataRef
        cEndCDataH   <- mkCEndCDataHandler =<< readIORef endCDataRef

        cProcessingInstructionH   <- mkCProcessingInstructionHandler =<< readIORef processingInstructionRef
        cCommentH   <- mkCCommentHandler =<< readIORef commentRef
        cStartNS <- mkCStartNamespaceDeclHandler =<< readIORef startNSRef
        cEndNS <- mkCEndNamespaceDeclHandler =<< readIORef endNSRef

        xmlSetxmldeclhandler       pp cXMLDeclH
        xmlSetstartelementhandler  pp cStartH
        xmlSetendelementhandler    pp cEndH
        xmlSetcharacterdatahandler pp cCharH
        xmlSetstartcdatahandler  pp cStartCDataH
        xmlSetendcdatahandler    pp cEndCDataH
        xmlSetprocessinginstructionhandler pp cProcessingInstructionH
        xmlSetcommenthandler pp cCommentH
        maybe (return ())
              (xmlSetExternalEntityRefHandler pp)
              mExtH
        maybe (return ())
              (xmlSetSkippedEntityHandler pp)
              mSkipH
        xmlSetNamespaceDeclHandler pp cStartNS cEndNS

        return $ ExpatHandlers cXMLDeclH cStartH cEndH cCharH mExtH mSkipH
            cStartCDataH cEndCDataH cProcessingInstructionH cCommentH
            cStartNS cEndNS

unsafeReleaseHandlers :: ExpatHandlers -> IO ()
unsafeReleaseHandlers (ExpatHandlers cXMLDeclH cStartH cEndH cCharH mcExtH
                                     mcSkipH cStartCDataH cEndCDataH
                                     cProcessingInstructionH cCommentH
                                     cStartNS cEndNS
                      ) = do
        freeHaskellFunPtr cXMLDeclH
        freeHaskellFunPtr cStartH
        freeHaskellFunPtr cEndH
        freeHaskellFunPtr cCharH
        maybe (return ()) freeHaskellFunPtr mcExtH
        maybe (return ()) freeHaskellFunPtr mcSkipH
        freeHaskellFunPtr cStartCDataH
        freeHaskellFunPtr cEndCDataH
        freeHaskellFunPtr cProcessingInstructionH
        freeHaskellFunPtr cCommentH
        freeHaskellFunPtr cStartNS
        freeHaskellFunPtr cEndNS

-- |Obtain C value from Haskell 'Bool'.
--
cFromBool :: Num a => Bool -> a
cFromBool  = fromBool

doParseChunk :: ParserPtr -> BS.ByteString -> Bool -> IO (Bool)
doParseChunk = ensureBoundThread $ \a1 a2 a3 ->
  withBStringLen a2 $ \(a2'1, a2'2) ->
  let {a3' = cFromBool a3} in
  doParseChunk'_ a1 a2'1  a2'2 a3' >>= \res ->
  let {res' = unStatus res} in
  return (res')

data WorkerIface = WorkerIface (MVar (ParserPtr, BS.ByteString, Bool)) (MVar Bool)

workerIfaceRef :: IORef (Maybe WorkerIface)
{-# NOINLINE workerIfaceRef #-}
workerIfaceRef = unsafePerformIO $ newIORef Nothing

-- If the calling thread is not bound, we delegate to a bound thread, because
-- otherwise we get a thread explosion (this is true in ghc-6.12.X).
-- See test/thread-leak/ directory for a test case.
ensureBoundThread :: (ParserPtr -> BS.ByteString -> Bool -> IO Bool)
                  -> ParserPtr
                  -> BS.ByteString
                  -> Bool
                  -> IO Bool
ensureBoundThread doit p bs last = do
    bound <- isCurrentThreadBound
    if rtsSupportsBoundThreads && not bound
        then delegate
        else doit p bs last
  where
    delegate = do
        mIface <- readIORef workerIfaceRef
        case mIface of
            Just iface -> pipeTo iface
            Nothing -> do
                inV <- newEmptyMVar
                outV <- newEmptyMVar
                let iface = WorkerIface inV outV
                justSetItGlobally <- atomicModifyIORef workerIfaceRef $ \mIface ->
                    case mIface of
                        Just _  -> (mIface, False)
                        Nothing -> (Just iface, True)
                if justSetItGlobally
                    then do
                        _ <- forkOS $ worker iface
                        pipeTo iface
                    else
                        -- If it wasn't changed, then this is because we got a race
                        -- condition with another thread.  We resolve this by trying
                        -- again.  We'll succeed on the second attempt.  The mvars
                        -- we allocated here will be GC'd.
                        delegate

    pipeTo (WorkerIface inV outV) =
        putMVar inV (p, bs, last) >> takeMVar outV

    worker (WorkerIface inV outV) = forever $
        putMVar outV =<< uncurry3 doit =<< takeMVar inV
      where
        uncurry3 f (a, b, c) = f a b c

-- | Parse error, consisting of message text and error location
data XMLParseError = XMLParseError String XMLParseLocation deriving (Eq, Show)

instance NFData XMLParseError where
    rnf (XMLParseError msg loc) = rnf (msg, loc)

-- | Specifies a location of an event within the input text
data XMLParseLocation = XMLParseLocation {
        xmlLineNumber   :: Int64,  -- ^ Line number of the event
        xmlColumnNumber :: Int64,  -- ^ Column number of the event
        xmlByteIndex    :: Int64,  -- ^ Byte index of event from start of document
        xmlByteCount    :: Int64   -- ^ The number of bytes in the event
    }
    deriving (Eq, Show)

instance NFData XMLParseLocation where
    rnf (XMLParseLocation lin col ind cou) = rnf (lin, col, ind, cou)

getParseLocation :: ParserPtr -> IO XMLParseLocation
getParseLocation pp = do
    line <- xmlGetCurrentLineNumber pp
    col <- xmlGetCurrentColumnNumber pp
    index <- xmlGetCurrentByteIndex pp
    count <- xmlGetCurrentByteCount pp
    return $ XMLParseLocation {
            xmlLineNumber = fromIntegral line,
            xmlColumnNumber = fromIntegral col,
            xmlByteIndex = fromIntegral index,
            xmlByteCount = fromIntegral count
        }

-- | The type of the \"XML declaration\" callback.  Parameters are version,
-- encoding (which can be nullPtr), and standalone declaration, where -1 = no
-- declaration, 0 = "no" and 1 = "yes". Return True to continue parsing as
-- normal, or False to terminate the parse.
type XMLDeclarationHandler = ParserPtr -> CString -> CString -> CInt -> IO Bool

-- | The type of the \"element started\" callback.  The first parameter is the
-- element name; the second are the (attribute, value) pairs. Return True to
-- continue parsing as normal, or False to terminate the parse.
type StartElementHandler  = ParserPtr -> CString -> [(CString, CString)] -> IO Bool

-- | The type of the \"element ended\" callback.  The parameter is the element
-- name. Return True to continue parsing as normal, or False to terminate the
-- parse.
type EndElementHandler    = ParserPtr -> CString -> IO Bool

-- | The type of the \"character data\" callback.  The parameter is the
-- character data processed.  This callback may be called more than once while
-- processing a single conceptual block of text. Return True to continue
-- parsing as normal, or False to terminate the parse.
type CharacterDataHandler = ParserPtr -> CStringLen -> IO Bool

-- | The type of the \"start cdata\" callback.   Return True to continue
-- parsing as normal, or False to terminate the parse.
type StartCDataHandler = ParserPtr -> IO Bool

-- | The type of the \"end cdata\" callback.   Return True to continue
-- parsing as normal, or False to terminate the parse.
type EndCDataHandler = ParserPtr -> IO Bool

-- | The type of the \"processing instruction\" callback.  The first parameter
-- is the first word in the processing instruction.  The second parameter is
-- the rest of the characters in the processing instruction after skipping all
-- whitespace after the initial word. Return True to continue parsing as normal,
-- or False to terminate the parse.
type ProcessingInstructionHandler = ParserPtr -> CString -> CString -> IO Bool

-- | The type of the \"comment\" callback.  The parameter is the comment text.
-- Return True to continue parsing as normal, or False to terminate the parse.
type CommentHandler = ParserPtr -> CString -> IO Bool

-- | The type of the \"external entity reference\" callback. See the expat
-- documentation.
type ExternalEntityRefHandler =  Parser
                              -> CString   -- context
                              -> CString   -- base
                              -> CString   -- systemID
                              -> CString   -- publicID
                              -> IO Bool


type StartNamespaceDeclHandler =  ParserPtr
                               -> CString  -- ^ prefix
                               -> CString  -- ^ URI
                               -> IO Bool

type EndNamespaceDeclHandler =  ParserPtr
                             -> CString  -- ^ prefix
                             -> IO Bool

-- | Set a skipped entity handler. This is called in two situations:
--
-- 1. An entity reference is encountered for which no declaration has been read
-- and this is not an error.
--
-- 2. An internal entity reference is read, but not expanded, because
-- @XML_SetDefaultHandler@ has been called.
type SkippedEntityHandler =  ParserPtr
                          -> CString   -- entityName
                          -> Int       -- is a parameter entity?
                          -> IO Bool


type CXMLDeclarationHandler = ParserPtr -> CString -> CString -> CInt -> IO ()

nullCXMLDeclarationHandler :: CXMLDeclarationHandler
nullCXMLDeclarationHandler _ _ _ _ = return ()

foreign import ccall safe "wrapper"
  mkCXMLDeclarationHandler :: CXMLDeclarationHandler
                           -> IO (FunPtr CXMLDeclarationHandler)

wrapXMLDeclarationHandler :: Parser -> XMLDeclarationHandler -> CXMLDeclarationHandler
wrapXMLDeclarationHandler parser handler = h
  where
    h pp ver enc sd | ver /= nullPtr = do
        stillRunning <- handler pp ver enc sd
        unless stillRunning $ stopp parser
    {- From expat.h:
       The XML declaration handler is called for *both* XML declarations
       and text declarations. The way to distinguish is that the version
       parameter will be NULL for text declarations.
     -}
    h _ _ _ _ = return ()  -- text declaration (ignore)

-- | Attach a XMLDeclarationHandler to a Parser.
setXMLDeclarationHandler :: Parser -> XMLDeclarationHandler -> IO ()
setXMLDeclarationHandler parser handler = do
    let xmlDeclRef = _xmlDeclarationHandler parser
    writeIORef xmlDeclRef $ wrapXMLDeclarationHandler parser handler





type CStartNamespaceDeclHandler = ParserPtr -> CString -> CString -> IO ()

nullCStartNamespaceDeclHandler :: CStartNamespaceDeclHandler
nullCStartNamespaceDeclHandler _ _ _ = return ()

foreign import ccall safe "wrapper"
  mkCStartNamespaceDeclHandler :: CStartNamespaceDeclHandler
                         -> IO (FunPtr CStartNamespaceDeclHandler)

wrapStartNamespaceDeclHandler :: Parser -> StartNamespaceDeclHandler -> CStartNamespaceDeclHandler
wrapStartNamespaceDeclHandler parser handler = h
  where
    h pp pref uri = do
        stillRunning <- handler pp pref uri
        unless stillRunning $ stopp parser

-- | Attach a StartNamespaceDeclHandler to a Parser.
setStartNamespaceDeclHandler :: Parser -> StartNamespaceDeclHandler -> IO ()
setStartNamespaceDeclHandler parser handler = do
    let nshandler = _startNamespaceDeclHandler parser
    writeIORef nshandler $ wrapStartNamespaceDeclHandler parser handler



type CEndNamespaceDeclHandler = ParserPtr -> CString -> IO ()

nullCEndNamespaceDeclHandler :: CEndNamespaceDeclHandler
nullCEndNamespaceDeclHandler _ _ = return ()

foreign import ccall safe "wrapper"
  mkCEndNamespaceDeclHandler :: CEndNamespaceDeclHandler
                         -> IO (FunPtr CEndNamespaceDeclHandler)

wrapEndNamespaceDeclHandler :: Parser -> EndNamespaceDeclHandler -> CEndNamespaceDeclHandler
wrapEndNamespaceDeclHandler parser handler = h
  where
    h pp pref = do
        stillRunning <- handler pp pref
        unless stillRunning $ stopp parser

-- | Attach a EndNamespaceDeclHandler to a Parser.
setEndNamespaceDeclHandler :: Parser -> EndNamespaceDeclHandler -> IO ()
setEndNamespaceDeclHandler parser handler = do
    let nshandler = _endNamespaceDeclHandler parser
    writeIORef nshandler $ wrapEndNamespaceDeclHandler parser handler


type CStartElementHandler = ParserPtr -> CString -> Ptr CString -> IO ()

nullCStartElementHandler :: CStartElementHandler
nullCStartElementHandler _ _ _ = return ()

foreign import ccall safe "wrapper"
  mkCStartElementHandler :: CStartElementHandler
                         -> IO (FunPtr CStartElementHandler)

wrapStartElementHandler :: Parser -> StartElementHandler -> CStartElementHandler
wrapStartElementHandler parser handler = h
  where
    h pp cname cattrs = do
        cattrlist <- peekArray0 nullPtr cattrs
        stillRunning <- handler pp cname (pairwise cattrlist)
        unless stillRunning $ stopp parser

-- | Attach a StartElementHandler to a Parser.
setStartElementHandler :: Parser -> StartElementHandler -> IO ()
setStartElementHandler parser handler = do
    let startRef = _startElementHandler parser
    writeIORef startRef $ wrapStartElementHandler parser handler


type CEndElementHandler = ParserPtr -> CString -> IO ()

nullCEndElementHandler :: CEndElementHandler
nullCEndElementHandler _ _ = return ()

foreign import ccall safe "wrapper"
  mkCEndElementHandler :: CEndElementHandler
                       -> IO (FunPtr CEndElementHandler)
wrapEndElementHandler :: Parser -> EndElementHandler -> CEndElementHandler
wrapEndElementHandler parser handler = h
  where
    h pp cname = do
        stillRunning <- handler pp cname
        unless stillRunning $ stopp parser

-- | Attach an EndElementHandler to a Parser.
setEndElementHandler :: Parser -> EndElementHandler -> IO ()
setEndElementHandler parser handler = do
    let endRef = _endElementHandler parser
    writeIORef endRef $ wrapEndElementHandler parser handler


type CCharacterDataHandler = ParserPtr -> CString -> CInt -> IO ()

nullCCharacterDataHandler :: CCharacterDataHandler
nullCCharacterDataHandler _ _ _ = return ()

foreign import ccall safe "wrapper"
  mkCCharacterDataHandler :: CCharacterDataHandler
                          -> IO (FunPtr CCharacterDataHandler)
wrapCharacterDataHandler :: Parser -> CharacterDataHandler -> CCharacterDataHandler
wrapCharacterDataHandler parser handler = h
  where
    h pp cdata len = do
        stillRunning <- handler pp (cdata, fromIntegral len)
        unless stillRunning $ stopp parser

-- | Attach an CharacterDataHandler to a Parser.
setCharacterDataHandler :: Parser -> CharacterDataHandler -> IO ()
setCharacterDataHandler parser handler = do
    let charRef = _cdataHandler parser
    writeIORef charRef $ wrapCharacterDataHandler parser handler


type CStartCDataHandler = ParserPtr -> IO ()

nullCStartCDataHandler :: CStartCDataHandler
nullCStartCDataHandler _ = return ()

foreign import ccall safe "wrapper"
  mkCStartCDataHandler :: CStartCDataHandler
                         -> IO (FunPtr CStartCDataHandler)

wrapStartCDataHandler :: Parser -> StartCDataHandler -> CStartCDataHandler
wrapStartCDataHandler parser handler = h
  where
    h pp = do
        stillRunning <- handler pp
        unless stillRunning $ stopp parser

-- | Attach a StartCDataHandler to a Parser.
setStartCDataHandler :: Parser -> StartCDataHandler -> IO ()
setStartCDataHandler parser handler = do
    let startCData = _startCDataHandler parser
    writeIORef startCData $ wrapStartCDataHandler parser handler


type CEndCDataHandler = ParserPtr -> IO ()

nullCEndCDataHandler :: CEndCDataHandler
nullCEndCDataHandler _ = return ()

foreign import ccall safe "wrapper"
  mkCEndCDataHandler :: CEndCDataHandler
                         -> IO (FunPtr CEndCDataHandler)

wrapEndCDataHandler :: Parser -> EndCDataHandler -> CEndCDataHandler
wrapEndCDataHandler parser handler = h
  where
    h pp = do
        stillRunning <- handler pp
        unless stillRunning $ stopp parser

-- | Attach a EndCDataHandler to a Parser.
setEndCDataHandler :: Parser -> EndCDataHandler -> IO ()
setEndCDataHandler parser handler = do
    let endCData = _endCDataHandler parser
    writeIORef endCData $ wrapEndCDataHandler parser handler


type CProcessingInstructionHandler = ParserPtr -> CString -> CString -> IO ()

nullCProcessingInstructionHandler :: CProcessingInstructionHandler
nullCProcessingInstructionHandler _ _ _ = return ()

foreign import ccall safe "wrapper"
  mkCProcessingInstructionHandler :: CProcessingInstructionHandler
                          -> IO (FunPtr CProcessingInstructionHandler)

wrapProcessingInstructionHandler :: Parser -> ProcessingInstructionHandler -> CProcessingInstructionHandler
wrapProcessingInstructionHandler parser handler = h
  where
    h pp ctarget cdata = do
        stillRunning <- handler pp ctarget cdata
        unless stillRunning $ stopp parser

-- | Attach a ProcessingInstructionHandler to a Parser.
setProcessingInstructionHandler :: Parser -> ProcessingInstructionHandler -> IO ()
setProcessingInstructionHandler parser handler = do
    let piRef = _processingInstructionHandler parser
    writeIORef piRef $ wrapProcessingInstructionHandler parser handler


type CCommentHandler = ParserPtr -> CString -> IO ()

nullCCommentHandler :: CCommentHandler
nullCCommentHandler _ _ = return ()

foreign import ccall safe "wrapper"
  mkCCommentHandler :: CCommentHandler
                          -> IO (FunPtr CCommentHandler)

wrapCommentHandler :: Parser -> CommentHandler -> CCommentHandler
wrapCommentHandler parser handler = h
  where
    h pp cdata = do
        stillRunning <- handler pp cdata
        unless stillRunning $ stopp parser

-- | Attach a CommentHandler to a Parser.
setCommentHandler :: Parser -> CommentHandler -> IO ()
setCommentHandler parser handler = do
    let commentRef = _commentHandler parser
    writeIORef commentRef $ wrapCommentHandler parser handler


pairwise :: [a] -> [(a,a)]
pairwise (x1:x2:xs) = (x1,x2) : pairwise xs
pairwise _          = []

stopp :: Parser -> IO ()
stopp parser = withParser parser $ \p -> xmlStopParser p 0

------------------------------------------------------------------------------
-- C imports

foreign import ccall unsafe "XML_ParserCreate"
  parserCreate'_ :: Ptr CChar -> IO ParserPtr

foreign import ccall unsafe "XML_ParserCreateNS"
  parserCreateNS'_ :: Ptr CChar -> CChar -> IO ParserPtr

foreign import ccall unsafe "XML_SetUserData"
  xmlSetUserData :: ParserPtr -> ParserPtr -> IO ()

foreign import ccall unsafe "XML_SetXmlDeclHandler"
  xmlSetxmldeclhandler :: ParserPtr -> FunPtr CXMLDeclarationHandler -> IO ()

foreign import ccall unsafe "XML_SetStartElementHandler"
  xmlSetstartelementhandler :: ParserPtr -> ((FunPtr (ParserPtr -> ((Ptr CChar) -> ((Ptr (Ptr CChar)) -> (IO ())))) -> (IO ())))

foreign import ccall unsafe "XML_SetEndElementHandler"
  xmlSetendelementhandler :: ParserPtr -> ((FunPtr (ParserPtr -> ((Ptr CChar) -> (IO ()))) -> (IO ())))

foreign import ccall unsafe "XML_SetCharacterDataHandler"
  xmlSetcharacterdatahandler :: ParserPtr -> ((FunPtr (ParserPtr -> ((Ptr CChar) -> (CInt -> (IO ())))) -> (IO ())))

foreign import ccall unsafe "XML_SetStartCdataSectionHandler"
  xmlSetstartcdatahandler :: ParserPtr -> FunPtr CStartCDataHandler -> IO ()

foreign import ccall unsafe "XML_SetEndCdataSectionHandler"
  xmlSetendcdatahandler :: ParserPtr -> FunPtr CStartCDataHandler -> IO ()

foreign import ccall unsafe "XML_SetCommentHandler"
  xmlSetcommenthandler :: ParserPtr -> ((FunPtr (ParserPtr -> ((Ptr CChar) -> (IO ()))) -> (IO ())))

foreign import ccall unsafe "XML_SetProcessingInstructionHandler"
  xmlSetprocessinginstructionhandler :: ParserPtr -> ((FunPtr (ParserPtr -> ((Ptr CChar) -> ((Ptr CChar) -> (IO ())))) -> (IO ())))

foreign import ccall unsafe "XML_SetNamespaceDeclHandler"
  xmlSetNamespaceDeclHandler :: ParserPtr
                                -> FunPtr CStartNamespaceDeclHandler
                                -> FunPtr CEndNamespaceDeclHandler
                                -> IO ()

foreign import ccall safe "XML_Parse"
  doParseChunk'_ :: ParserPtr -> ((Ptr CChar) -> (CInt -> (CInt -> (IO CInt))))

foreign import ccall unsafe "XML_UseForeignDTD"
  xmlUseForeignDTD :: ParserPtr     -- ^ parser
                   -> CChar         -- ^ use foreign DTD? (external entity ref
                                    -- handler will be called with publicID &
                                    -- systemID set to null
                   -> IO ()



foreign import ccall "&XML_ParserFree" parserFree :: FunPtr (ParserPtr -> IO ())
foreign import ccall "XML_ParserFree" parserFree' :: ParserPtr -> IO ()

type CExternalEntityRefHandler = ParserPtr   -- parser
                              -> Ptr CChar   -- context
                              -> Ptr CChar   -- base
                              -> Ptr CChar   -- systemID
                              -> Ptr CChar   -- publicID
                              -> IO ()

foreign import ccall unsafe "wrapper"
  mkCExternalEntityRefHandler :: CExternalEntityRefHandler
                              -> IO (FunPtr CExternalEntityRefHandler)


foreign import ccall unsafe "XML_SetExternalEntityRefHandler"
  xmlSetExternalEntityRefHandler :: ParserPtr
                                 -> FunPtr CExternalEntityRefHandler
                                 -> IO ()

foreign import ccall unsafe "XML_SetSkippedEntityHandler"
  xmlSetSkippedEntityHandler :: ParserPtr
                             -> FunPtr CSkippedEntityHandler
                             -> IO ()

foreign import ccall unsafe "XML_ExternalEntityParserCreate"
  xmlExternalEntityParserCreate :: ParserPtr
                                -> CString   -- ^ context
                                -> CString   -- ^ encoding
                                -> IO ParserPtr

type CSkippedEntityHandler =  ParserPtr -- user data pointer
                           -> CString   -- entity name
                           -> CInt      -- is a parameter entity?
                           -> IO ()

foreign import ccall safe "wrapper"
  mkCSkippedEntityHandler :: CSkippedEntityHandler
                          -> IO (FunPtr CSkippedEntityHandler)


wrapExternalEntityRefHandler :: Parser
                             -> ExternalEntityRefHandler
                             -> CExternalEntityRefHandler
wrapExternalEntityRefHandler parser handler = h
  where
    h _ context base systemID publicID = do
        stillRunning <- handler parser context base systemID publicID
        unless stillRunning $ stopp parser


wrapSkippedEntityHandler :: Parser
                         -> SkippedEntityHandler
                         -> CSkippedEntityHandler
wrapSkippedEntityHandler parser handler = h
  where
    h pp entityName i = do
        stillRunning <- handler pp entityName (fromIntegral i)
        unless stillRunning $ stopp parser


setExternalEntityRefHandler :: Parser -> ExternalEntityRefHandler -> IO ()
setExternalEntityRefHandler parser h =
    writeIORef ref $ Just $ wrapExternalEntityRefHandler parser h
  where
    ref = _externalEntityRefHandler parser

setSkippedEntityHandler :: Parser -> SkippedEntityHandler -> IO ()
setSkippedEntityHandler parser h =
    writeIORef ref $ Just $ wrapSkippedEntityHandler parser h
  where
    ref = _skippedEntityHandler parser

-- Note on word sizes:
--
-- on expat 2.0:
-- XML_GetCurrentLineNumber returns XML_Size
-- XML_GetCurrentColumnNumber returns XML_Size
-- XML_GetCurrentByteIndex returns XML_Index
-- These are defined in expat_external.h
--
-- debian-i386 says XML_Size and XML_Index are 4 bytes.
-- ubuntu-amd64 says XML_Size and XML_Index are 8 bytes.
-- These two systems do NOT define XML_LARGE_SIZE, which would force these types
-- to be 64-bit.
--
-- If we guess the word size too small, it shouldn't matter: We will just discard
-- the most significant part.  If we get the word size too large, we will get
-- garbage (very bad).
--
-- So - what I will do is use CLong and CULong, which correspond to what expat
-- is using when XML_LARGE_SIZE is disabled, and give the correct sizes on the
-- two machines mentioned above.  At the absolute worst the word size will be too
-- short.

foreign import ccall unsafe "expat.h XML_GetErrorCode" xmlGetErrorCode
    :: ParserPtr -> IO CInt
foreign import ccall unsafe "expat.h XML_GetCurrentLineNumber" xmlGetCurrentLineNumber
    :: ParserPtr -> IO CULong
foreign import ccall unsafe "expat.h XML_GetCurrentColumnNumber" xmlGetCurrentColumnNumber
    :: ParserPtr -> IO CULong
foreign import ccall unsafe "expat.h XML_GetCurrentByteIndex" xmlGetCurrentByteIndex
    :: ParserPtr -> IO CLong
foreign import ccall unsafe "expat.h XML_GetCurrentByteCount" xmlGetCurrentByteCount
    :: ParserPtr -> IO CInt
foreign import ccall unsafe "expat.h XML_ErrorString" xmlErrorString
    :: CInt -> IO CString
foreign import ccall unsafe "expat.h XML_StopParser" xmlStopParser
    :: ParserPtr -> CInt -> IO ()

