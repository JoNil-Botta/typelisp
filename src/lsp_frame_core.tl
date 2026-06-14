;; lsp_frame_core.tl - Main-free selfhost LSP stdio framing and JSON-RPC slice (#592/#789).
;;
;; This driver owns JSON-RPC/LSP Content-Length framing over stdin/stdout plus
;; the first selfhost protocol loop: initialize/shutdown, document tracking, and
;; diagnostics for full-document open/change notifications.
(import "../stdlib/io.tl")

(import "../stdlib/json.tl")

(import "compiler_check_core.tl")

(import "compiler_load.tl")

(import "../stdlib/string.tl")

(import "../stdlib/str_cat.tl")

(defenum LspFrameRead
  (LspFrameOk String)
  (LspFrameEof)
  (LspFrameErr String))

(defenum LspLengthParse
  (LspLengthIgnore)
  (LspLengthOk i64)
  (LspLengthErr String))

(defenum LspStringResult
  (OkLspString String)
  (ErrLspString String))

(defenum LspUriPath
  (OkLspUriPath String)
  (ErrLspUriPath String))

(defenum LspJsonText
  (OkLspJsonText String)
  (MissingLspJsonText))

(defenum LspDocumentLookup
  (FoundLspDocument String String String)
  (MissingLspDocument))

(defstruct LspDocument
  (uri String)
  (path String)
  (text String)
  (diagnostic-uri String))

(defstruct LspDocuments
  (slots (Array LspDocument))
  (len i64))

(defenum LspHandleResult
  (LspContinue LspDocuments)
  (LspExit LspDocuments))

(defstruct LspLineCol
  (line i64)
  (col i64))

(defenum LspDefLocation
  (FoundDefLoc String i64 i64 i64)
  (MissingDefLoc))

(define (lsp-frame-space? [c : char]) : bool
  (or (= c #\space') (= c #\tab')))

(define (lsp-frame-trim-right-space-cr [text : String]) : String
  (let
    [i : i64 (string-length text)]
    [end : i64 (string-length text)]
    [done : bool false]
    (begin
      (while (> i 0)
        (if done
          (set! i 0)
          (let
            [c : char (string-ref text (- i 1))]
            (if (or (lsp-frame-space? c) (= c #\return'))
              (begin
                (set! end (- i 1))
                (set! i (- i 1)))
              (set! done true)))))
      (substring text 0 end))))

(define (lsp-frame-trim-left-space [text : String]) : String
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [start : i64 0]
    [done : bool false]
    (begin
      (while (< i n)
        (if done
          (set! i n)
          (if (lsp-frame-space? (string-ref text i))
            (begin
              (set! start (+ i 1))
              (set! i (+ i 1)))
            (set! done true))))
      (substring text start (- n start)))))

(define (lsp-frame-trim-header-value [text : String]) : String
  (lsp-frame-trim-left-space (lsp-frame-trim-right-space-cr text)))

(define (lsp-frame-starts-with? [text : String] [prefix : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    [i : i64 0]
    [ok : bool true]
    (if (< text-len prefix-len)
      false
      (begin
        (while (< i prefix-len)
          (if ok
            (if (= (string-ref text i) (string-ref prefix i))
              (set! i (+ i 1))
              (begin
                (set! ok false)
                (set! i prefix-len)))
            (set! i prefix-len)))
        ok))))

(define (lsp-frame-digit? [c : char]) : bool
  (and (>= c #0') (<= c #9')))

(define (lsp-frame-decimal? [text : String]) : bool
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [ok : bool true]
    (if (= n 0)
      false
      (begin
        (while (< i n)
          (if ok
            (if (lsp-frame-digit? (string-ref text i))
              (set! i (+ i 1))
              (begin
                (set! ok false)
                (set! i n)))
            (set! i n)))
        ok))))

(define (lsp-frame-parse-content-length [line : String]) : LspLengthParse
  (if (lsp-frame-starts-with? line "Content-Length:")
    (let
      [value : String
        (lsp-frame-trim-header-value
          (substring line 15 (- (string-length line) 15)))]
      (if (lsp-frame-decimal? value)
        (let
          [n : i64 (string->int value)]
          (if (< n 0)
            (LspLengthErr "lsp: invalid Content-Length")
            (LspLengthOk n)))
        (LspLengthErr "lsp: invalid Content-Length")))
    LspLengthIgnore))

(define (lsp-frame-read-message) : LspFrameRead
  (let
    [content-length : i64 -1]
    [saw-header : bool false]
    [done : bool false]
    [clean-eof : bool false]
    [err : String ""]
    (begin
      (while (not done)
        (if (string-eq err "")
          (let
            [line-read : StdinRead (stdin-read-line)]
            [line : String
              (lsp-frame-trim-right-space-cr (stdin-read-text line-read))]
            (if (stdin-read-eof? line-read)
              (if (= (string-length line) 0)
                (if saw-header
                  (begin
                    (set! err "lsp: EOF before header terminator")
                    (set! done true))
                  (begin
                    (set! clean-eof true)
                    (set! done true)))
                (begin
                  (set! saw-header true)
                  (match (lsp-frame-parse-content-length line)
                    [(LspLengthIgnore) unit]
                    [(LspLengthOk n) (set! content-length n)]
                    [(LspLengthErr message)
                      (begin
                        (set! err message)
                        (set! done true))])))
              (if (string-eq line "")
                (set! done true)
                (begin
                  (set! saw-header true)
                  (match (lsp-frame-parse-content-length line)
                    [(LspLengthIgnore) unit]
                    [(LspLengthOk n) (set! content-length n)]
                    [(LspLengthErr message)
                      (begin
                        (set! err message)
                        (set! done true))])))))
          (set! done true)))
      (cond
        clean-eof
        LspFrameEof
        (not (string-eq err ""))
        (LspFrameErr err)
        (< content-length 0)
        (LspFrameErr "lsp: missing Content-Length")
        (let
          [payload-read : StdinRead (stdin-read-bytes content-length)]
          [payload : String (stdin-read-text payload-read)]
          (if (and
            (stdin-read-eof? payload-read)
            (< (string-length payload) content-length))
            (LspFrameErr "lsp: truncated payload")
            (LspFrameOk payload)))))))

(define (lsp-frame-stdout-write [text : String]) : unit
  (stdout-write (& text)))

(define (lsp-frame-stderr-write [text : String]) : unit
  (stderr-write (& text)))

(define (lsp-frame-write-body [body : String]) : unit
  (begin
    (lsp-frame-stdout-write
      (str-cat
        "Content-Length: "
        (int->string (string-length body))
        "\r\n\r\n"
        body
        ""))
    (stdout-flush)))

(define (lsp-json-number [value : i64]) : Json
  (JsonNumber (int->string value)))

(define (lsp-json-member [k : String] [v : Json] [rest : JsonMemberList]) : JsonMemberList
  (JsonMemberListCons k v (box rest)))

(define (lsp-json-object [members : JsonMemberList]) : Json
  (JsonObject (box members)))

(define (lsp-json-list-cons [value : Json] [rest : JsonList]) : JsonList
  (JsonListCons value (box rest)))

(define (lsp-json-array [items : JsonList]) : Json
  (JsonArray (box items)))

(define (lsp-json-rpc-member [rest : JsonMemberList]) : JsonMemberList
  (lsp-json-member "jsonrpc" (JsonString "2.0") rest))

(define (lsp-json-object1 [k : String] [v : Json]) : Json
  (lsp-json-object (lsp-json-member k v JsonMemberListNil)))

(define (lsp-json-object2 [k1 : String] [v1 : Json] [k2 : String] [v2 : Json]) : Json
  (lsp-json-object
    (lsp-json-member k1 v1 (lsp-json-member k2 v2 JsonMemberListNil))))

(define (lsp-json-object4
  [k1 : String]
  [v1 : Json]
  [k2 : String]
  [v2 : Json]
  [k3 : String]
  [v3 : Json]
  [k4 : String]
  [v4 : Json]) : Json
  (lsp-json-object
    (lsp-json-member
      k1
      v1
      (lsp-json-member
        k2
        v2
        (lsp-json-member k3 v3 (lsp-json-member k4 v4 JsonMemberListNil))))))

(define (lsp-json-string-field [value : Json] [key : String]) : LspJsonText
  (match (json-object-get value (& key))
    [(JsonFound field)
      (match field
        [(JsonString text) (OkLspJsonText text)]
        [_ MissingLspJsonText])]
    [(JsonMissing) MissingLspJsonText]))

(define (lsp-json-string-field-default
  [value : Json]
  [key : String]
  [fallback : String]) : String
  (match (lsp-json-string-field value key)
    [(OkLspJsonText text) text]
    [(MissingLspJsonText) fallback]))

(define (lsp-write-json [value : Json]) : unit
  (lsp-frame-write-body (json-stringify value)))

(define (lsp-write-response [id : Json] [result : Json]) : unit
  (lsp-write-json
    (lsp-json-object
      (lsp-json-rpc-member
        (lsp-json-member
          "id"
          id
          (lsp-json-member "result" result JsonMemberListNil))))))

(define (lsp-write-error [id : Json] [code : i64] [message : String]) : unit
  (lsp-write-json
    (lsp-json-object
      (lsp-json-rpc-member
        (lsp-json-member
          "id"
          id
          (lsp-json-member
            "error"
            (lsp-json-object2
              "code"
              (lsp-json-number code)
              "message"
              (JsonString message))
            JsonMemberListNil))))))

(define (lsp-write-parse-error [message : String]) : unit
  (lsp-write-error JsonNull -32700 message))

(define (lsp-initialize-result) : Json
  (lsp-json-object2
    "capabilities"
    (lsp-json-object4
      "textDocumentSync"
      (lsp-json-object2
        "openClose"
        (JsonBool true)
        "change"
        (lsp-json-number 1))
      "definitionProvider"
      (JsonBool true)
      "completionProvider"
      (lsp-json-object1 "resolveProvider" (JsonBool false))
      "inlayHintProvider"
      (JsonBool true))
    "serverInfo"
    (lsp-json-object2
      "name"
      (JsonString "typelisp")
      "version"
      (JsonString "selfhost"))))

(define (lsp-documents-slots [docs : LspDocuments]) : (Array LspDocument)
  (struct-get docs slots))

(define (lsp-documents-len [docs : LspDocuments]) : i64
  (struct-get docs len))

(define (lsp-documents-capacity [docs : LspDocuments]) : i64
  (array-length (lsp-documents-slots docs)))

(define (lsp-documents-with-capacity [capacity : i64]) : LspDocuments
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (LspDocuments (make-array LspDocument cap) 0)))

(define (lsp-documents-new) : LspDocuments
  (lsp-documents-with-capacity 4))

(define (lsp-documents-copy-range
  [dst : (Array LspDocument)]
  [src : (Array LspDocument)]
  [index : i64]
  [count : i64]) : unit
  (let
    [i : i64 index]
    (while (< i count)
      (begin
        (array-set! dst i (array-ref src i))
        (set! i (+ i 1))))))

(define (lsp-documents-grow [docs : LspDocuments]) : LspDocuments
  (let
    [n : i64 (lsp-documents-len docs)]
    [bigger : (Array LspDocument)
      (make-array LspDocument (* (lsp-documents-capacity docs) 2))]
    (begin
      (lsp-documents-copy-range bigger (lsp-documents-slots docs) 0 n)
      (LspDocuments bigger n))))

(define (lsp-documents-push [docs : LspDocuments] [doc : LspDocument]) : LspDocuments
  (if (< (lsp-documents-len docs) (lsp-documents-capacity docs))
    (let
      [slots : (Array LspDocument) (lsp-documents-slots docs)]
      (begin
        (array-set! slots (lsp-documents-len docs) doc)
        (LspDocuments slots (+ (lsp-documents-len docs) 1))))
    (lsp-documents-push (lsp-documents-grow docs) doc)))

(define (lsp-documents-set-index!
  [docs : LspDocuments]
  [index : i64]
  [doc : LspDocument]) : LspDocuments
  (begin
    (if (if (>= index 0)
      (< index (lsp-documents-len docs))
      false)
      (array-set! (lsp-documents-slots docs) index doc)
      unit)
    docs))

(define (lsp-documents-find-index-from
  [docs : LspDocuments]
  [uri : String]
  [index : i64]) : i64
  (let
    [i : i64 index]
    [found : i64 -1]
    [done : bool false]
    (begin
      (while (< i (lsp-documents-len docs))
        (if done
          (set! i (lsp-documents-len docs))
          (let
            [doc : LspDocument (array-ref (lsp-documents-slots docs) i)]
            (if (string-eq (struct-get doc uri) uri)
              (begin
                (set! found i)
                (set! done true)
                (set! i (lsp-documents-len docs)))
              (set! i (+ i 1))))))
      found)))

(define (lsp-documents-find-index [docs : LspDocuments] [uri : String]) : i64
  (lsp-documents-find-index-from docs uri 0))

(define (lsp-documents-set
  [docs : LspDocuments]
  [uri : String]
  [path : String]
  [text : String]
  [diagnostic-uri : String]) : LspDocuments
  (let
    [doc : LspDocument (LspDocument uri path text diagnostic-uri)]
    [index : i64 (lsp-documents-find-index docs uri)]
    (if (>= index 0)
      (lsp-documents-set-index! docs index doc)
      (lsp-documents-push docs doc))))

(define (lsp-documents-shift-left! [docs : LspDocuments] [index : i64]) : unit
  (let
    [i : i64 index]
    [last : i64 (- (lsp-documents-len docs) 1)]
    (begin
      (while (< i last)
        (begin
          (array-set!
            (lsp-documents-slots docs)
            i
            (array-ref (lsp-documents-slots docs) (+ i 1)))
          (set! i (+ i 1)))))))

(define (lsp-documents-remove-index [docs : LspDocuments] [index : i64]) : LspDocuments
  (if (if (>= index 0)
    (< index (lsp-documents-len docs))
    false)
    (begin
      (lsp-documents-shift-left! docs index)
      (LspDocuments (lsp-documents-slots docs) (- (lsp-documents-len docs) 1)))
    docs))

(define (lsp-documents-remove [docs : LspDocuments] [uri : String]) : LspDocuments
  (lsp-documents-remove-index docs (lsp-documents-find-index docs uri)))

(define (lsp-documents-lookup [docs : LspDocuments] [uri : String]) : LspDocumentLookup
  (let
    [index : i64 (lsp-documents-find-index docs uri)]
    (if (>= index 0)
      (let
        [doc : LspDocument (array-ref (lsp-documents-slots docs) index)]
        (FoundLspDocument
          (struct-get doc path)
          (struct-get doc text)
          (struct-get doc diagnostic-uri)))
      MissingLspDocument)))

(define (lsp-hex-value [c : char]) : i64
  (let
    [code : i64 (cast c : i64)]
    (cond
      (and (>= code 48) (<= code 57))
      (- code 48)
      (and (>= code 65) (<= code 70))
      (+ 10 (- code 65))
      (and (>= code 97) (<= code 102))
      (+ 10 (- code 97))
      -1)))

(define (lsp-percent-decode [text : String]) : LspStringResult
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [out : String ""]
    [err : String ""]
    (begin
      (while (< i n)
        (if (string-eq err "")
          (if (= (string-ref text i) #%')
            (if (< (+ i 2) n)
              (let
                [hi : i64 (lsp-hex-value (string-ref text (+ i 1)))]
                [lo : i64 (lsp-hex-value (string-ref text (+ i 2)))]
                (if (and (>= hi 0) (>= lo 0))
                  (match (json-codepoint-string (+ (* hi 16) lo))
                    [(OkJsonCodepointString decoded)
                      (begin
                        (set! out (string-append out decoded))
                        (set! i (+ i 3)))]
                    [(ErrJsonCodepointString message)
                      (begin
                        (set! err message)
                        (set! i n))])
                  (begin
                    (set! err "lsp: invalid percent escape in file URI")
                    (set! i n))))
              (begin
                (set! err "lsp: invalid percent escape in file URI")
                (set! i n)))
            (begin
              (set! out (string-append out (substring text i 1)))
              (set! i (+ i 1))))
          (set! i n)))
      (if (string-eq err "")
        (OkLspString out)
        (ErrLspString err)))))

(define (lsp-uri-path-strip-windows-leading-slash [path : String]) : String
  (let
    [n : i64 (string-length path)]
    (if (and (> n 2) (= (string-ref path 0) #/') (= (string-ref path 2) #:'))
      (substring path 1 (- n 1))
      path)))

(define (lsp-file-uri-to-path [uri : String]) : LspUriPath
  (if (lsp-frame-starts-with? uri "file://")
    (match (lsp-percent-decode (substring uri 7 (- (string-length uri) 7)))
      [(OkLspString decoded)
        (let
          [path : String (lsp-uri-path-strip-windows-leading-slash decoded)]
          (if (> (string-length path) 0)
            (OkLspUriPath path)
            (ErrLspUriPath "unsupported TypeLisp LSP URI: empty file path")))]
      [(ErrLspString message) (ErrLspUriPath message)])
    (ErrLspUriPath "unsupported TypeLisp LSP URI: expected file:// URI")))

(define (lsp-uri-safe-code? [code : i64]) : bool
  (or
    (and (>= code 65) (<= code 90))
    (and (>= code 97) (<= code 122))
    (and (>= code 48) (<= code 57))
    (= code 45)
    (= code 46)
    (= code 95)
    (= code 126)
    (= code 47)
    (= code 58)))

(define (lsp-percent-encode-path [path : String]) : String
  (let
    [n : i64 (string-length path)]
    [i : i64 0]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (let
            [code : i64 (cast (string-ref path i) : i64)]
            (if (lsp-uri-safe-code? code)
              (set! out (string-append out (substring path i 1)))
              (set!
                out
                (str-cat
                  out
                  "%"
                  (string-append
                    (json-hex-digit (/ code 16))
                    (json-hex-digit (- code (* (/ code 16) 16))))))))
          (set! i (+ i 1))))
      out)))

(define (lsp-path-to-file-uri [path : String]) : String
  (if (and (> (string-length path) 0) (= (string-ref path 0) #/'))
    (string-append "file://" (lsp-percent-encode-path path))
    (string-append "file:///" (lsp-percent-encode-path path))))

(define (lsp-zero-based [value : i64]) : i64
  (if (> value 0)
    (- value 1)
    0))

(define (lsp-position [line : i64] [character : i64]) : Json
  (lsp-json-object2
    "line"
    (lsp-json-number (lsp-zero-based line))
    "character"
    (lsp-json-number (lsp-zero-based character))))

(define (lsp-range [line : i64] [col : i64]) : Json
  (lsp-json-object2
    "start"
    (lsp-position line col)
    "end"
    (lsp-position line (+ col 1))))

(define (lsp-diagnostic
  [line : i64]
  [col : i64]
  [message : String]
  [code : String]) : Json
  (if (string-eq code "")
    (lsp-json-object4
      "range"
      (lsp-range line col)
      "severity"
      (lsp-json-number 1)
      "source"
      (JsonString "typelisp")
      "message"
      (JsonString message))
    (lsp-json-object
      (lsp-json-member
        "range"
        (lsp-range line col)
        (lsp-json-member
          "severity"
          (lsp-json-number 1)
          (lsp-json-member
            "source"
            (JsonString "typelisp")
            (lsp-json-member
              "code"
              (JsonString code)
              (lsp-json-member "message" (JsonString message) JsonMemberListNil))))))))

(define (lsp-compiler-diagnostic [diag : CompilerDiagnostic]) : Json
  (lsp-diagnostic
    (compiler-diagnostic-line diag)
    (compiler-diagnostic-col diag)
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-code-or-empty diag)))

(define (lsp-compiler-diagnostic-code-ok?
  [diag : CompilerDiagnostic]
  [want : String]) : bool
  (match (lsp-json-string-field (lsp-compiler-diagnostic diag) "code")
    [(OkLspJsonText code) (string-eq code want)]
    [(MissingLspJsonText) false]))

(define (lsp-compiler-diagnostic-uncoded-ok? [diag : CompilerDiagnostic]) : bool
  (match (lsp-json-string-field (lsp-compiler-diagnostic diag) "code")
    [(OkLspJsonText _) false]
    [(MissingLspJsonText) true]))

(define (lsp-diagnostic-metadata-smoke) : i64
  (let
    [parse-diag : CompilerDiagnostic
      (compiler-diagnostic-with-code
        (compiler-diagnostic-simple "parse.tl" 2 3 "missing paren")
        (compiler-diagnostic-code-parse))]
    [typecheck-diag : CompilerDiagnostic
      (compiler-diagnostic-with-code
        (compiler-diagnostic-simple "type.tl" 4 5 "not assignable")
        (compiler-diagnostic-code-typecheck))]
    [uncoded : CompilerDiagnostic
      (compiler-diagnostic-simple "plain.tl" 1 1 "typecheck: prefix text only")]
    (begin
      (unless
        (lsp-compiler-diagnostic-code-ok?
          parse-diag
          (compiler-diagnostic-code-parse))
        (return 1))
      (unless
        (lsp-compiler-diagnostic-code-ok?
          typecheck-diag
          (compiler-diagnostic-code-typecheck))
        (return 2))
      (unless (lsp-compiler-diagnostic-uncoded-ok? uncoded) (return 3))
      (unless (lsp-frame-session-cache-smoke-ok?) (return 4))
      (unless (lsp-definition-smoke-ok?) (return 5))
      42)))

(define (lsp-diagnostic-uri
  [root-uri : String]
  [root-path : String]
  [diag : CompilerDiagnostic]) : String
  (let
    [diag-path : String (compiler-diagnostic-path diag)]
    (if (or (string-eq diag-path "") (string-eq diag-path root-path))
      root-uri
      (lsp-path-to-file-uri diag-path))))

(define (lsp-publish-diagnostics [uri : String] [diagnostics : JsonList]) : unit
  (lsp-write-json
    (lsp-json-object
      (lsp-json-rpc-member
        (lsp-json-member
          "method"
          (JsonString "textDocument/publishDiagnostics")
          (lsp-json-member
            "params"
            (lsp-json-object2
              "uri"
              (JsonString uri)
              "diagnostics"
              (lsp-json-array diagnostics))
            JsonMemberListNil))))))

(define (lsp-publish-uri-diagnostic [uri : String] [message : String]) : unit
  (lsp-publish-diagnostics
    uri
    (lsp-json-list-cons (lsp-diagnostic 1 1 message "") JsonListNil)))

(define (lsp-clear-stale-diagnostic
  [docs : LspDocuments]
  [uri : String]
  [next-diagnostic-uri : String]) : unit
  (match (lsp-documents-lookup docs uri)
    [(FoundLspDocument _ _ old-diagnostic-uri)
      (if (or
        (string-eq old-diagnostic-uri "")
        (string-eq old-diagnostic-uri uri)
        (string-eq old-diagnostic-uri next-diagnostic-uri))
        unit
        (lsp-publish-diagnostics old-diagnostic-uri JsonListNil))]
    [(MissingLspDocument) unit]))

(define (lsp-clear-close-diagnostics [docs : LspDocuments] [uri : String]) : unit
  (match (lsp-documents-lookup docs uri)
    [(FoundLspDocument _ _ old-diagnostic-uri)
      (begin
        (lsp-publish-diagnostics uri JsonListNil)
        (if (or
          (string-eq old-diagnostic-uri "")
          (string-eq old-diagnostic-uri uri))
          unit
          (lsp-publish-diagnostics old-diagnostic-uri JsonListNil)))]
    [(MissingLspDocument) (lsp-publish-diagnostics uri JsonListNil)]))

(define (lsp-analyze-document
  [uri : String]
  [path : String]
  [text : String]
  [stdlib-roots : StringVec]) : String
  (match (compiler-check-source-with-roots path text stdlib-roots)
    [(OkCompilerCheck _)
      (begin
        (lsp-publish-diagnostics uri JsonListNil)
        "")]
    [(ErrCompilerCheck diag)
      (let
        [diag-uri : String (lsp-diagnostic-uri uri path diag)]
        (begin
          (if (string-eq diag-uri uri)
            unit
            (lsp-publish-diagnostics uri JsonListNil))
          (lsp-publish-diagnostics
            diag-uri
            (lsp-json-list-cons (lsp-compiler-diagnostic diag) JsonListNil))
          diag-uri))]))

(define (lsp-first-change-text [params : Json]) : LspJsonText
  (let
    [key : String "contentChanges"]
    (match (json-object-get params (& key))
      [(JsonFound value)
        (match value
          [(JsonArray items)
            (match (box-get items)
              [(JsonListNil) MissingLspJsonText]
              [(JsonListCons first _) (lsp-json-string-field first "text")])]
          [_ MissingLspJsonText])]
      [(JsonMissing) MissingLspJsonText])))

(define (lsp-did-open
  [params : Json]
  [docs : LspDocuments]
  [stdlib-roots : StringVec]) : LspHandleResult
  (let
    [key : String "textDocument"]
    (match (json-object-get params (& key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(OkLspJsonText uri)
            (let
              [text : String (lsp-json-string-field-default document "text" "")]
              (match (lsp-file-uri-to-path uri)
                [(OkLspUriPath path)
                  (let
                    [diagnostic-uri : String
                      (lsp-analyze-document uri path text stdlib-roots)]
                    (begin
                      (lsp-clear-stale-diagnostic docs uri diagnostic-uri)
                      (LspContinue
                        (lsp-documents-set docs uri path text diagnostic-uri))))]
                [(ErrLspUriPath message)
                  (begin
                    (lsp-publish-uri-diagnostic uri message)
                    (LspContinue docs))]))]
          [(MissingLspJsonText) (LspContinue docs)])]
      [(JsonMissing) (LspContinue docs)])))

(define (lsp-did-change
  [params : Json]
  [docs : LspDocuments]
  [stdlib-roots : StringVec]) : LspHandleResult
  (let
    [key : String "textDocument"]
    (match (json-object-get params (& key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(OkLspJsonText uri)
            (match (lsp-first-change-text params)
              [(OkLspJsonText text)
                (match (lsp-file-uri-to-path uri)
                  [(OkLspUriPath path)
                    (let
                      [diagnostic-uri : String
                        (lsp-analyze-document uri path text stdlib-roots)]
                      (begin
                        (lsp-clear-stale-diagnostic docs uri diagnostic-uri)
                        (LspContinue
                          (lsp-documents-set docs uri path text diagnostic-uri))))]
                  [(ErrLspUriPath message)
                    (begin
                      (lsp-publish-uri-diagnostic uri message)
                      (LspContinue docs))])]
              [(MissingLspJsonText)
                (match (lsp-documents-lookup docs uri)
                  [(FoundLspDocument path text _)
                    (begin
                      (lsp-analyze-document uri path text stdlib-roots)
                      (LspContinue docs))]
                  [(MissingLspDocument) (LspContinue docs)])])]
          [(MissingLspJsonText) (LspContinue docs)])]
      [(JsonMissing) (LspContinue docs)])))

(define (lsp-did-close [params : Json] [docs : LspDocuments]) : LspHandleResult
  (let
    [key : String "textDocument"]
    (match (json-object-get params (& key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(OkLspJsonText uri)
            (begin
              (lsp-clear-close-diagnostics docs uri)
              (LspContinue (lsp-documents-remove docs uri)))]
          [(MissingLspJsonText) (LspContinue docs)])]
      [(JsonMissing) (LspContinue docs)])))

;; --------------------------------------------------------------------------
;; Go-to-definition (textDocument/definition).
;;
;; Top-level AST declarations do not yet carry source spans (compiler_ast_types
;; defers them), so definitions are resolved by scanning the document text for
;; the defining form. The scan skips string literals, character literals, and
;; `;` comments so fixture sources that embed TypeLisp inside literals never
;; produce a false match.
;; --------------------------------------------------------------------------
(define (lsp-ident-char? [c : char]) : bool
  (or
    (and (>= c #a') (<= c #z'))
    (and (>= c #A') (<= c #Z'))
    (and (>= c #0') (<= c #9'))
    (= c #-')
    (= c #+')
    (= c #*')
    (= c #/')
    (= c #?')
    (= c #!')
    (= c #>')
    (= c #<')
    (= c #=')
    (= c #&')
    (= c #:')
    (= c #_')
    (= c #.')
    (= c #%')))

(define (lsp-ws? [c : char]) : bool
  (or (= c #\space') (= c #\tab') (= c #\newline') (= c #\return')))

(define (lsp-skip-space [text : String] [i : i64] [n : i64]) : i64
  (let
    [j : i64 i]
    (begin
      (while (and (< j n) (lsp-ws? (string-ref text j)))
        (set! j (+ j 1)))
      j)))

(define (lsp-scan-ident [text : String] [i : i64] [n : i64]) : i64
  (let
    [j : i64 i]
    (begin
      (while (and (< j n) (lsp-ident-char? (string-ref text j)))
        (set! j (+ j 1)))
      j)))

(define (lsp-skip-line [text : String] [i : i64] [n : i64]) : i64
  (let
    [j : i64 i]
    (begin
      (while (and (< j n) (not (= (string-ref text j) #\newline')))
        (set! j (+ j 1)))
      (if (< j n)
        (+ j 1)
        j))))

(define (lsp-skip-string [text : String] [i : i64] [n : i64]) : i64
  (let
    [j : i64 (+ i 1)]
    [done : bool false]
    (begin
      (while (and (< j n) (not done))
        (let
          [c : char (string-ref text j)]
          (cond
            (= c #\\')
            (set! j (+ j 2))
            (= c #"')
            (begin
              (set! done true)
              (set! j (+ j 1)))
            (set! j (+ j 1)))))
      j)))

(define (lsp-skip-char-literal [text : String] [i : i64] [n : i64]) : i64
  (let
    [j : i64 (+ i 1)]
    [seen-payload : bool false]
    [done : bool false]
    (begin
      (while (and (< j n) (not done))
        (let
          [c : char (string-ref text j)]
          (if (and seen-payload (= c #''))
            (begin
              (set! done true)
              (set! j (+ j 1)))
            (begin
              (set! seen-payload true)
              (set! j (+ j 1))))))
      j)))

;; Maximal identifier token covering `off`, or "" when `off` is not on one.
(define (lsp-symbol-at-offset [text : String] [off : i64]) : String
  (let
    [n : i64 (string-length text)]
    (if (or (< off 0) (>= off n))
      ""
      (if (not (lsp-ident-char? (string-ref text off)))
        ""
        (let
          [start : i64 off]
          [end : i64 (lsp-scan-ident text off n)]
          (begin
            (while (and
              (> start 0)
              (lsp-ident-char? (string-ref text (- start 1))))
              (set! start (- start 1)))
            (substring text start (- end start))))))))

;; Base name of a possibly module-qualified symbol (`core/cond` -> `cond`,
;; `core.cond` -> `cond`).
(define (lsp-symbol-base [s : String]) : String
  (let
    [n : i64 (string-length s)]
    [i : i64 0]
    [k : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (or (= (string-ref s i) #/') (= (string-ref s i) #.'))
            (set! k i)
            unit)
          (set! i (+ i 1))))
      (if (>= k 0)
        (substring s (+ k 1) (- n (+ k 1)))
        s))))

;; Byte offset of a 0-based (line, character) position, clamped to the line.
(define (lsp-offset-at-position [text : String] [line0 : i64] [char0 : i64]) : i64
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [ln : i64 0]
    [col : i64 0]
    (begin
      (while (and (< i n) (< ln line0))
        (begin
          (if (= (string-ref text i) #\newline')
            (set! ln (+ ln 1))
            unit)
          (set! i (+ i 1))))
      (while (and
        (< i n)
        (< col char0)
        (not (= (string-ref text i) #\newline')))
        (begin
          (set! i (+ i 1))
          (set! col (+ col 1))))
      i)))

;; 1-based line/column of a byte offset.
(define (lsp-line-col-at-offset [text : String] [off : i64]) : LspLineCol
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [line : i64 1]
    [col : i64 1]
    (begin
      (while (and (< i n) (< i off))
        (begin
          (if (= (string-ref text i) #\newline')
            (begin
              (set! line (+ line 1))
              (set! col 1))
            (set! col (+ col 1)))
          (set! i (+ i 1))))
      (LspLineCol line col))))

(define (lsp-def-keyword? [kw : String]) : bool
  (or
    (string-eq kw "define")
    (string-eq kw "defmacro")
    (string-eq kw "defstruct")
    (string-eq kw "defenum")
    (string-eq kw "defdispatch")
    (string-eq kw "extern")))

;; When `text[i]` opens a top-level definition form, return the byte offset of
;; the defined name (skipping an optional `(` for function/extern forms);
;; otherwise -1.
(define (lsp-def-name-offset-at [text : String] [i : i64] [n : i64]) : i64
  (let
    [after-open : i64 (lsp-skip-space text (+ i 1) n)]
    [kw-end : i64 (lsp-scan-ident text after-open n)]
    (if (<= kw-end after-open)
      -1
      (let
        [kw : String (substring text after-open (- kw-end after-open))]
        (if (lsp-def-keyword? kw)
          (let
            [after-kw : i64 (lsp-skip-space text kw-end n)]
            [name-start : i64
              (if (and (< after-kw n) (= (string-ref text after-kw) #('))
                (lsp-skip-space text (+ after-kw 1) n)
                after-kw)]
            (if (< name-start n)
              (if (lsp-ident-char? (string-ref text name-start))
                name-start
                -1)
              -1))
          -1)))))

;; Byte offset of the definition of `needle` in `text`, or -1. Strings,
;; character literals, and `;` comments are skipped so embedded source never
;; matches.
(define (lsp-find-def-offset-in [text : String] [needle : String]) : i64
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< i n) (< found 0))
        (let
          [c : char (string-ref text i)]
          (cond
            (= c #;')
            (set! i (lsp-skip-line text i n))
            (= c ##')
            (set! i (lsp-skip-char-literal text i n))
            (= c #"')
            (set! i (lsp-skip-string text i n))
            (= c #(')
            (let
              [name-off : i64 (lsp-def-name-offset-at text i n)]
              (if (>= name-off 0)
                (if (string-eq (lsp-symbol-at-offset text name-off) needle)
                  (set! found name-off)
                  (set! i (+ i 1)))
                (set! i (+ i 1))))
            (set! i (+ i 1)))))
      found)))

(define (lsp-def-loc-from
  [uri : String]
  [text : String]
  [off : i64]
  [needle : String]) : LspDefLocation
  (let
    [lc : LspLineCol (lsp-line-col-at-offset text off)]
    (FoundDefLoc
      uri
      (struct-get lc line)
      (struct-get lc col)
      (string-length needle))))

(define (lsp-find-definition-in-docs
  [docs : LspDocuments]
  [current-uri : String]
  [needle : String]
  [idx : i64]) : LspDefLocation
  (if (>= idx (lsp-documents-len docs))
    MissingDefLoc
    (let
      [doc : LspDocument (array-ref (lsp-documents-slots docs) idx)]
      (if (string-eq (struct-get doc uri) current-uri)
        (lsp-find-definition-in-docs docs current-uri needle (+ idx 1))
        (let
          [off : i64 (lsp-find-def-offset-in (struct-get doc text) needle)]
          (if (>= off 0)
            (lsp-def-loc-from
              (struct-get doc uri)
              (struct-get doc text)
              off
              needle)
            (lsp-find-definition-in-docs docs current-uri needle (+ idx 1))))))))

;; Resolve `needle` to a definition: the current document first, then any other
;; open document.
(define (lsp-find-definition
  [docs : LspDocuments]
  [current-uri : String]
  [current-text : String]
  [needle : String]) : LspDefLocation
  (let
    [off : i64 (lsp-find-def-offset-in current-text needle)]
    (if (>= off 0)
      (lsp-def-loc-from current-uri current-text off needle)
      (lsp-find-definition-in-docs docs current-uri needle 0))))

(define (lsp-json-int-field-default
  [value : Json]
  [key : String]
  [fallback : i64]) : i64
  (match (json-object-get value (& key))
    [(JsonFound field)
      (match field
        [(JsonNumber text)
          (match (json-number->i64 (& text))
            [(OkJsonNumberI64 number) number]
            [(ErrJsonNumberI64 _) fallback])]
        [_ fallback])]
    [(JsonMissing) fallback]))

(define (lsp-definition-location
  [uri : String]
  [line : i64]
  [col : i64]
  [len : i64]) : Json
  (lsp-json-object2
    "uri"
    (JsonString uri)
    "range"
    (lsp-json-object2
      "start"
      (lsp-position line col)
      "end"
      (lsp-position line (+ col len)))))

(define (lsp-definition-respond
  [id : Json]
  [uri : String]
  [position : Json]
  [docs : LspDocuments]) : unit
  (match (lsp-documents-lookup docs uri)
    [(FoundLspDocument _ text _)
      (let
        [line0 : i64 (lsp-json-int-field-default position "line" 0)]
        [char0 : i64 (lsp-json-int-field-default position "character" 0)]
        [off : i64 (lsp-offset-at-position text line0 char0)]
        [sym : String (lsp-symbol-at-offset text off)]
        (if (string-eq sym "")
          (lsp-write-response id JsonNull)
          (match (lsp-find-definition docs uri text (lsp-symbol-base sym))
            [(FoundDefLoc def-uri def-line def-col def-len)
              (lsp-write-response
                id
                (lsp-definition-location def-uri def-line def-col def-len))]
            [(MissingDefLoc) (lsp-write-response id JsonNull)])))]
    [(MissingLspDocument) (lsp-write-response id JsonNull)]))

(define (lsp-handle-definition
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json-object-get params (& td-key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(OkLspJsonText uri)
            (let
              [pos-key : String "position"]
              (match (json-object-get params (& pos-key))
                [(JsonFound position)
                  (lsp-definition-respond id uri position docs)]
                [(JsonMissing) (lsp-write-response id JsonNull)]))]
          [(MissingLspJsonText) (lsp-write-response id JsonNull)])]
      [(JsonMissing) (lsp-write-response id JsonNull)])))

(define (lsp-definition-smoke-basic?) : bool
  (let
    [src : String
      "(define (foo [x : i64]) : i64 x)\n(define (bar) : i64 (foo 1))\n"]
    [off : i64 (lsp-offset-at-position src 1 22)]
    [sym : String (lsp-symbol-at-offset src off)]
    (if (not (string-eq sym "foo"))
      false
      (match (lsp-find-definition
        (lsp-documents-new)
        "file:///smoke.tl"
        src
        (lsp-symbol-base sym))
        [(FoundDefLoc _ line col len) (and (= line 1) (= col 10) (= len 3))]
        [(MissingDefLoc) false]))))

(define (lsp-definition-smoke-skips-strings?) : bool
  (let
    [src : String
      "(define greeting : String \"(define decoy 1)\")\n(define (use) : i64 0)\n"]
    (match (lsp-find-definition
      (lsp-documents-new)
      "file:///smoke.tl"
      src
      "decoy")
      [(FoundDefLoc _ _ _ _) false]
      [(MissingDefLoc) true])))

(define (lsp-definition-smoke-skips-char-literals?) : bool
  (let
    [src : String
      "(define (quote-char) : char #\"')\n(define (target) : i64 1)\n(define (use) : i64 (target))\n"]
    (match (lsp-find-definition
      (lsp-documents-new)
      "file:///smoke.tl"
      src
      "target")
      [(FoundDefLoc _ line col len) (and (= line 2) (= col 10) (= len 6))]
      [(MissingDefLoc) false])))

(define (lsp-definition-smoke-qualified-base?) : bool
  (and
    (string-eq (lsp-symbol-base "core/cond") "cond")
    (string-eq (lsp-symbol-base "core.cond") "cond")))

(define (lsp-definition-smoke-ok?) : bool
  (and
    (lsp-definition-smoke-basic?)
    (lsp-definition-smoke-skips-strings?)
    (lsp-definition-smoke-skips-char-literals?)
    (lsp-definition-smoke-qualified-base?)))

;; --------------------------------------------------------------------------
;; Completion (textDocument/completion).
;;
;; Offers the language's special forms, builtins, and primitive types, plus the
;; top-level names defined in any open document. The client filters by the
;; typed prefix, so the full candidate set is returned.
;; --------------------------------------------------------------------------
(define (lsp-completion-keywords) : String
  "define lambda let if begin while set! return match foreach cond when unless and or with-arena with-escape try unsafe quote quasiquote unquote ann init cast type defstruct defenum defmacro defdispatch import export extern module comptime comptime-decl comptime-decls include-str include-bin test spmd-reduce spmd-broadcast")

(define (lsp-completion-builtins) : String
  "ptr-null ptr-read ptr-write! ptr-offset ptr-cast ptr->int int->ptr ptr-null? ptr-addr-of make-array array-ref array-set! array-push! array-data tuple-ref struct-get string-data string-from-bytes program-argc program-argv program-envp cpuid-eax cpuid-ebx cpuid-ecx cpuid-edx xgetbv syscall box box-get array tuple")

(define (lsp-completion-types) : String
  "i64 i32 i16 i8 u64 u32 u16 u8 f64 f32 bool char String str unit never Array Tuple Box Ptr MutPtr")

(define (lsp-split-spaces [s : String]) : StringVec
  (let
    [n : i64 (string-length s)]
    [i : i64 0]
    [start : i64 0]
    [acc : StringVec (string-vec-new)]
    (begin
      (while (< i n)
        (begin
          (if (= (string-ref s i) #\space')
            (begin
              (if (> i start)
                (set! acc (string-vec-push acc (substring s start (- i start))))
                unit)
              (set! start (+ i 1)))
            unit)
          (set! i (+ i 1))))
      (if (> n start)
        (set! acc (string-vec-push acc (substring s start (- n start))))
        unit)
      acc)))

(define (lsp-completion-item [label : String] [kind : i64]) : Json
  (lsp-json-object2 "label" (JsonString label) "kind" (lsp-json-number kind)))

(define (lsp-completion-items-from
  [labels : StringVec]
  [kind : i64]
  [idx : i64]
  [acc : JsonList]) : JsonList
  (if (>= idx (string-vec-len labels))
    acc
    (lsp-completion-items-from
      labels
      kind
      (+ idx 1)
      (lsp-json-list-cons
        (lsp-completion-item (string-vec-get labels idx "") kind)
        acc))))

;; Collect every top-level definition name in `text`, skipping strings/comments.
(define (lsp-collect-def-names [text : String] [acc : StringVec]) : StringVec
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [out : StringVec acc]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (cond
            (= c #;')
            (set! i (lsp-skip-line text i n))
            (= c #"')
            (set! i (lsp-skip-string text i n))
            (= c #(')
            (let
              [name-off : i64 (lsp-def-name-offset-at text i n)]
              (begin
                (if (>= name-off 0)
                  (set!
                    out
                    (string-vec-push out (lsp-symbol-at-offset text name-off)))
                  unit)
                (set! i (+ i 1))))
            (set! i (+ i 1)))))
      out)))

(define (lsp-collect-def-names-all
  [docs : LspDocuments]
  [idx : i64]
  [acc : StringVec]) : StringVec
  (if (>= idx (lsp-documents-len docs))
    acc
    (lsp-collect-def-names-all
      docs
      (+ idx 1)
      (lsp-collect-def-names
        (struct-get (array-ref (lsp-documents-slots docs) idx) text)
        acc))))

(define (lsp-completion-respond [id : Json] [docs : LspDocuments]) : unit
  (let
    [names : StringVec (lsp-collect-def-names-all docs 0 (string-vec-new))]
    [items : JsonList
      (lsp-completion-items-from
        names
        3
        0
        (lsp-completion-items-from
          (lsp-split-spaces (lsp-completion-types))
          7
          0
          (lsp-completion-items-from
            (lsp-split-spaces (lsp-completion-builtins))
            3
            0
            (lsp-completion-items-from
              (lsp-split-spaces (lsp-completion-keywords))
              14
              0
              JsonListNil))))]
    (lsp-write-response id (lsp-json-array items))))

;; --------------------------------------------------------------------------
;; Inlay hints (textDocument/inlayHint) for inferred types.
;;
;; The typechecker records the inferred type + position of each un-annotated
;; `let` binding value (see tc-inlay-hint-* in compiler_typecheck_core). Here we
;; re-check the document with collection enabled, then emit a `: <type>` hint at
;; each recorded position that the open document confirms is a real un-annotated
;; binding within the requested range.
;; --------------------------------------------------------------------------
;; True when `off` is the start of the value in an un-annotated `[name value]`
;; binding: the char before (past whitespace) is the name, preceded by `[`.
(define (lsp-inlay-valid-binding? [text : String] [off : i64]) : bool
  (let
    [p : i64 (- off 1)]
    (begin
      (while (and (>= p 0) (lsp-ws? (string-ref text p)))
        (set! p (- p 1)))
      (if (< p 0)
        false
        (if (not (lsp-ident-char? (string-ref text p)))
          false
          (begin
            (while (and (>= p 0) (lsp-ident-char? (string-ref text p)))
              (set! p (- p 1)))
            (while (and (>= p 0) (lsp-ws? (string-ref text p)))
              (set! p (- p 1)))
            (and (>= p 0) (= (string-ref text p) #['))))))))

(define (lsp-inlay-range-line [range : Json] [which : String] [fallback : i64]) : i64
  (match (json-object-get range (& which))
    [(JsonFound endpoint) (lsp-json-int-field-default endpoint "line" fallback)]
    [(JsonMissing) fallback]))

(define (lsp-inlay-hint-json [line : i64] [col : i64] [ty : String]) : Json
  (lsp-json-object4
    "position"
    (lsp-position line col)
    "label"
    (JsonString (string-append ": " ty))
    "kind"
    (lsp-json-number 1)
    "paddingRight"
    (JsonBool true)))

(define (lsp-inlay-build [text : String] [start-line : i64] [end-line : i64]) : JsonList
  (let
    [size : i64 (tc-inlay-hints-size)]
    [i : i64 0]
    [acc : JsonList JsonListNil]
    (begin
      (while (< i size)
        (let
          [line1 : i64 (tc-inlay-hint-line-at i)]
          [col1 : i64 (tc-inlay-hint-col-at i)]
          [line0 : i64 (- line1 1)]
          (begin
            (if (and
              (and (>= line0 start-line) (<= line0 end-line))
              (lsp-inlay-valid-binding?
                text
                (lsp-offset-at-position text line0 (- col1 1))))
              (set!
                acc
                (lsp-json-list-cons
                  (lsp-inlay-hint-json line1 col1 (tc-inlay-hint-type-at i))
                  acc))
              unit)
            (set! i (+ i 1)))))
      acc)))

(define (lsp-inlay-respond
  [id : Json]
  [uri : String]
  [range : Json]
  [docs : LspDocuments]
  [stdlib-roots : StringVec]) : unit
  (match (lsp-documents-lookup docs uri)
    [(FoundLspDocument path text _)
      (let
        [start-line : i64 (lsp-inlay-range-line range "start" 0)]
        [end-line : i64 (lsp-inlay-range-line range "end" 1000000000)]
        (begin
          (tc-inlay-hints-enable!)
          (match (compiler-check-source-with-roots path text stdlib-roots)
            [(OkCompilerCheck _) unit]
            [(ErrCompilerCheck _) unit])
          (let
            [hints : JsonList (lsp-inlay-build text start-line end-line)]
            (begin
              (tc-inlay-hints-disable!)
              (lsp-write-response id (lsp-json-array hints))))))]
    [(MissingLspDocument) (lsp-write-response id (lsp-json-array JsonListNil))]))

(define (lsp-handle-inlay
  [id : Json]
  [params : Json]
  [docs : LspDocuments]
  [stdlib-roots : StringVec]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json-object-get params (& td-key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(OkLspJsonText uri)
            (let
              [range-key : String "range"]
              (match (json-object-get params (& range-key))
                [(JsonFound range)
                  (lsp-inlay-respond id uri range docs stdlib-roots)]
                [(JsonMissing)
                  (lsp-write-response id (lsp-json-array JsonListNil))]))]
          [(MissingLspJsonText)
            (lsp-write-response id (lsp-json-array JsonListNil))])]
      [(JsonMissing) (lsp-write-response id (lsp-json-array JsonListNil))])))

(define (lsp-maybe-write-method-not-found [message : Json]) : unit
  (let
    [key : String "id"]
    (match (json-object-get message (& key))
      [(JsonFound id) (lsp-write-error id -32601 "Method not found")]
      [(JsonMissing) unit])))

(define (lsp-handle-message
  [message : Json]
  [docs : LspDocuments]
  [stdlib-roots : StringVec]) : LspHandleResult
  (match (lsp-json-string-field message "method")
    [(OkLspJsonText method)
      (cond
        (string-eq method "initialize")
        (begin
          (let
            [key : String "id"]
            (match (json-object-get message (& key))
              [(JsonFound id) (lsp-write-response id (lsp-initialize-result))]
              [(JsonMissing) unit]))
          (LspContinue docs))
        (string-eq method "initialized")
        (LspContinue docs)
        (string-eq method "shutdown")
        (begin
          (let
            [key : String "id"]
            (match (json-object-get message (& key))
              [(JsonFound id) (lsp-write-response id JsonNull)]
              [(JsonMissing) unit]))
          (LspContinue docs))
        (string-eq method "exit")
        (LspExit docs)
        (string-eq method "textDocument/didOpen")
        (let
          [key : String "params"]
          (match (json-object-get message (& key))
            [(JsonFound params) (lsp-did-open params docs stdlib-roots)]
            [(JsonMissing) (LspContinue docs)]))
        (string-eq method "textDocument/didChange")
        (let
          [key : String "params"]
          (match (json-object-get message (& key))
            [(JsonFound params) (lsp-did-change params docs stdlib-roots)]
            [(JsonMissing) (LspContinue docs)]))
        (string-eq method "textDocument/didClose")
        (let
          [key : String "params"]
          (match (json-object-get message (& key))
            [(JsonFound params) (lsp-did-close params docs)]
            [(JsonMissing) (LspContinue docs)]))
        (string-eq method "textDocument/definition")
        (begin
          (let
            [id-key : String "id"]
            (match (json-object-get message (& id-key))
              [(JsonFound id)
                (let
                  [params-key : String "params"]
                  (match (json-object-get message (& params-key))
                    [(JsonFound params) (lsp-handle-definition id params docs)]
                    [(JsonMissing) (lsp-write-response id JsonNull)]))]
              [(JsonMissing) unit]))
          (LspContinue docs))
        (string-eq method "textDocument/completion")
        (begin
          (let
            [id-key : String "id"]
            (match (json-object-get message (& id-key))
              [(JsonFound id) (lsp-completion-respond id docs)]
              [(JsonMissing) unit]))
          (LspContinue docs))
        (string-eq method "textDocument/inlayHint")
        (begin
          (let
            [id-key : String "id"]
            (match (json-object-get message (& id-key))
              [(JsonFound id)
                (let
                  [params-key : String "params"]
                  (match (json-object-get message (& params-key))
                    [(JsonFound params)
                      (lsp-handle-inlay id params docs stdlib-roots)]
                    [(JsonMissing)
                      (lsp-write-response id (lsp-json-array JsonListNil))]))]
              [(JsonMissing) unit]))
          (LspContinue docs))
        (begin
          (lsp-maybe-write-method-not-found message)
          (LspContinue docs)))]
    [(MissingLspJsonText) (LspContinue docs)]))

(define (lsp-stdlib-roots-from [idx : i64] [count : i64]) : StringVec
  (let
    [i : i64 idx]
    [roots : StringVec (string-vec-new)]
    (begin
      (while (< i count)
        (if (string-eq (arg i) "--stdlib-root")
          (if (< (+ i 1) count)
            (begin
              (set! roots (string-vec-push roots (arg (+ i 1))))
              (set! i (+ i 2)))
            (set! i count))
          (set! i (+ i 1))))
      roots)))

(define (lsp-stdlib-roots [idx : i64]) : StringVec
  (lsp-stdlib-roots-from idx (arg-count)))

(define (lsp-frame-session-cache-enable!) : unit
  (compiler-load-session-cache-enable!))

(define (lsp-frame-session-cache-smoke-ok?) : bool
  (begin
    (compiler-load-session-cache-disable-for-test!)
    (lsp-frame-session-cache-enable!)
    (let
      [ok : bool (compiler-load-session-cache-enabled?)]
      (begin
        (compiler-load-session-cache-disable-for-test!)
        ok))))

(define (lsp-frame-run-from [idx : i64] [count : i64]) : i64
  (let
    [done : bool false]
    [status : i64 0]
    [docs : LspDocuments (lsp-documents-new)]
    [stdlib-roots : StringVec (lsp-stdlib-roots-from idx count)]
    (begin
      (lsp-frame-session-cache-enable!)
      (while (not done)
        (match (lsp-frame-read-message)
          [(LspFrameOk payload)
            (let
              [text : String payload]
              (match (json-parse (& text))
                [(OkJson message)
                  (match (lsp-handle-message message docs stdlib-roots)
                    [(LspContinue next-docs) (set! docs next-docs)]
                    [(LspExit next-docs)
                      (begin
                        (set! docs next-docs)
                        (set! done true))])]
                [(ErrJson message) (lsp-write-parse-error message)]))]
          [(LspFrameEof) (set! done true)]
          [(LspFrameErr message)
            (begin
              (lsp-write-parse-error message)
              (lsp-frame-stderr-write message)
              (set! status 1)
              (set! done true))]))
      status)))

(define (lsp-frame-run) : i64
  (lsp-frame-run-from 1 (arg-count)))