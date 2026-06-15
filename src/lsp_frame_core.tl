;; lsp_frame_core.tl - Main-free selfhost LSP stdio framing and JSON-RPC slice (#592/#789).
;;
;; This driver owns JSON-RPC/LSP Content-Length framing over stdin/stdout plus
;; the first selfhost protocol loop: initialize/shutdown, document tracking, and
;; diagnostics for full-document open/change notifications.
(import stdlib.io as io_mod)

(import stdlib.json as json_mod)

(import "compiler_check_core.tl")

(import "compiler_load.tl")

(import "format_rules.tl")

(import "lint_driver_core.tl")

(import stdlib.string as string_mod)

(import stdlib.vector as vector_mod)

(import stdlib.str_cat)

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

(defenum LspDefSource
  (FoundDefSource String i64)
  (MissingDefSource))

(defenum LspVariantHit
  (FoundVariant String String)
  (MissingVariant))

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
      (string_mod.substring text 0 end))))

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
      (string_mod.substring text start (- n start)))))

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
          (string_mod.substring line 15 (- (string-length line) 15)))]
      (if (lsp-frame-decimal? value)
        (let
          [n : i64 (string_mod.string->int value)]
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
        (if (string_mod.string-eq err "")
          (let
            [line-read : io_mod.StdinRead (io_mod.stdin-read-line)]
            [line : String
              (lsp-frame-trim-right-space-cr (io_mod.stdin-read-text line-read))]
            (if (io_mod.stdin-read-eof? line-read)
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
              (if (string_mod.string-eq line "")
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
      (if clean-eof
        LspFrameEof
        (if (not (string_mod.string-eq err ""))
          (LspFrameErr err)
          (if (< content-length 0)
            (LspFrameErr "lsp: missing Content-Length")
            (let
              [payload-read : io_mod.StdinRead
                (io_mod.stdin-read-bytes content-length)]
              [payload : String (io_mod.stdin-read-text payload-read)]
              (if (and
                (io_mod.stdin-read-eof? payload-read)
                (< (string-length payload) content-length))
                (LspFrameErr "lsp: truncated payload")
                (LspFrameOk payload)))))))))

(define (lsp-frame-stdout-write [text : String]) : unit
  (io_mod.stdout-write (& text)))

(define (lsp-frame-stderr-write [text : String]) : unit
  (io_mod.stderr-write (& text)))

(define (lsp-frame-write-body [body : String]) : unit
  (begin
    (lsp-frame-stdout-write
      (str_cat.str-cat
        "Content-Length: "
        (string_mod.int->string (string-length body))
        "\r\n\r\n"
        body
        ""))
    (io_mod.stdout-flush)))

(define (lsp-json-number [value : i64]) : json_mod.Json
  (json_mod.JsonNumber (string_mod.int->string value)))

(define (lsp-json-member
  [k : String]
  [v : json_mod.Json]
  [rest : json_mod.JsonMemberList]) : json_mod.JsonMemberList
  (json_mod.JsonMemberListCons k v (box rest)))

(define (lsp-json-object [members : json_mod.JsonMemberList]) : json_mod.Json
  (json_mod.JsonObject (box members)))

(define (lsp-json-list-cons [value : json_mod.Json] [rest : json_mod.JsonList]) : json_mod.JsonList
  (json_mod.JsonListCons value (box rest)))

(define (lsp-json-array [items : json_mod.JsonList]) : json_mod.Json
  (json_mod.JsonArray (box items)))

(define (lsp-json-rpc-member [rest : json_mod.JsonMemberList]) : json_mod.JsonMemberList
  (lsp-json-member "jsonrpc" (json_mod.JsonString "2.0") rest))

(define (lsp-json-object1 [k : String] [v : json_mod.Json]) : json_mod.Json
  (lsp-json-object (lsp-json-member k v json_mod.JsonMemberListNil)))

(define (lsp-json-object2
  [k1 : String]
  [v1 : json_mod.Json]
  [k2 : String]
  [v2 : json_mod.Json]) : json_mod.Json
  (lsp-json-object
    (lsp-json-member k1 v1 (lsp-json-member k2 v2 json_mod.JsonMemberListNil))))

(define (lsp-json-object4
  [k1 : String]
  [v1 : json_mod.Json]
  [k2 : String]
  [v2 : json_mod.Json]
  [k3 : String]
  [v3 : json_mod.Json]
  [k4 : String]
  [v4 : json_mod.Json]) : json_mod.Json
  (lsp-json-object
    (lsp-json-member
      k1
      v1
      (lsp-json-member
        k2
        v2
        (lsp-json-member
          k3
          v3
          (lsp-json-member k4 v4 json_mod.JsonMemberListNil))))))

(define (lsp-json-string-field [value : json_mod.Json] [key : String]) : LspJsonText
  (match (json_mod.json-object-get value (& key))
    [(json_mod.JsonFound field)
      (match field
        [(json_mod.JsonString text) (OkLspJsonText text)]
        [_ MissingLspJsonText])]
    [(json_mod.JsonMissing) MissingLspJsonText]))

(define (lsp-json-string-field-default
  [value : json_mod.Json]
  [key : String]
  [fallback : String]) : String
  (match (lsp-json-string-field value key)
    [(OkLspJsonText text) text]
    [(MissingLspJsonText) fallback]))

(define (lsp-write-json [value : json_mod.Json]) : unit
  (lsp-frame-write-body (json_mod.json-stringify value)))

(define (lsp-write-response [id : json_mod.Json] [result : json_mod.Json]) : unit
  (lsp-write-json
    (lsp-json-object
      (lsp-json-rpc-member
        (lsp-json-member
          "id"
          id
          (lsp-json-member "result" result json_mod.JsonMemberListNil))))))

(define (lsp-write-error [id : json_mod.Json] [code : i64] [message : String]) : unit
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
              (json_mod.JsonString message))
            json_mod.JsonMemberListNil))))))

(define (lsp-write-parse-error [message : String]) : unit
  (lsp-write-error json_mod.JsonNull -32700 message))

(define (lsp-initialize-result) : json_mod.Json
  (lsp-json-object2
    "capabilities"
    (lsp-json-object
      (lsp-json-member
        "textDocumentSync"
        (lsp-json-object2
          "openClose"
          (json_mod.JsonBool true)
          "change"
          (lsp-json-number 1))
        (lsp-json-member
          "definitionProvider"
          (json_mod.JsonBool true)
          (lsp-json-member
            "completionProvider"
            (lsp-json-object1 "resolveProvider" (json_mod.JsonBool false))
            (lsp-json-member
              "inlayHintProvider"
              (json_mod.JsonBool true)
              (lsp-json-member
                "documentFormattingProvider"
                (json_mod.JsonBool true)
                (lsp-json-member
                  "hoverProvider"
                  (json_mod.JsonBool true)
                  (lsp-json-member
                    "documentLinkProvider"
                    (lsp-json-object1
                      "resolveProvider"
                      (json_mod.JsonBool false))
                    json_mod.JsonMemberListNil))))))))
    "serverInfo"
    (lsp-json-object2
      "name"
      (json_mod.JsonString "typelisp")
      "version"
      (json_mod.JsonString "selfhost"))))

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
            (if (string_mod.string-eq (struct-get doc uri) uri)
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
    (if (and (>= code 48) (<= code 57))
      (- code 48)
      (if (and (>= code 65) (<= code 70))
        (+ 10 (- code 65))
        (if (and (>= code 97) (<= code 102))
          (+ 10 (- code 97))
          -1)))))

(define (lsp-percent-decode [text : String]) : LspStringResult
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [out : String ""]
    [err : String ""]
    (begin
      (while (< i n)
        (if (string_mod.string-eq err "")
          (if (= (string-ref text i) #%')
            (if (< (+ i 2) n)
              (let
                [hi : i64 (lsp-hex-value (string-ref text (+ i 1)))]
                [lo : i64 (lsp-hex-value (string-ref text (+ i 2)))]
                (if (and (>= hi 0) (>= lo 0))
                  (match (json_mod.json-codepoint-string (+ (* hi 16) lo))
                    [(json_mod.OkJsonCodepointString decoded)
                      (begin
                        (set! out (string_mod.string-append out decoded))
                        (set! i (+ i 3)))]
                    [(json_mod.ErrJsonCodepointString message)
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
              (set!
                out
                (string_mod.string-append out (string_mod.substring text i 1)))
              (set! i (+ i 1))))
          (set! i n)))
      (if (string_mod.string-eq err "")
        (OkLspString out)
        (ErrLspString err)))))

(define (lsp-uri-path-strip-windows-leading-slash [path : String]) : String
  (let
    [n : i64 (string-length path)]
    (if (and (> n 2) (= (string-ref path 0) #/') (= (string-ref path 2) #:'))
      (string_mod.substring path 1 (- n 1))
      path)))

(define (lsp-file-uri-to-path [uri : String]) : LspUriPath
  (if (lsp-frame-starts-with? uri "file://")
    (match (lsp-percent-decode
      (string_mod.substring uri 7 (- (string-length uri) 7)))
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
              (set!
                out
                (string_mod.string-append out (string_mod.substring path i 1)))
              (set!
                out
                (str_cat.str-cat
                  out
                  "%"
                  (string_mod.string-append
                    (json_mod.json-hex-digit (/ code 16))
                    (json_mod.json-hex-digit (- code (* (/ code 16) 16))))))))
          (set! i (+ i 1))))
      out)))

(define (lsp-path-to-file-uri [path : String]) : String
  (if (and (> (string-length path) 0) (= (string-ref path 0) #/'))
    (string_mod.string-append "file://" (lsp-percent-encode-path path))
    (string_mod.string-append "file:///" (lsp-percent-encode-path path))))

(define (lsp-zero-based [value : i64]) : i64
  (if (> value 0)
    (- value 1)
    0))

(define (lsp-position [line : i64] [character : i64]) : json_mod.Json
  (lsp-json-object2
    "line"
    (lsp-json-number (lsp-zero-based line))
    "character"
    (lsp-json-number (lsp-zero-based character))))

(define (lsp-range [line : i64] [col : i64]) : json_mod.Json
  (lsp-json-object2
    "start"
    (lsp-position line col)
    "end"
    (lsp-position line (+ col 1))))

(define (lsp-diagnostic
  [line : i64]
  [col : i64]
  [message : String]
  [code : String]) : json_mod.Json
  (if (string_mod.string-eq code "")
    (lsp-json-object4
      "range"
      (lsp-range line col)
      "severity"
      (lsp-json-number 1)
      "source"
      (json_mod.JsonString "typelisp")
      "message"
      (json_mod.JsonString message))
    (lsp-json-object
      (lsp-json-member
        "range"
        (lsp-range line col)
        (lsp-json-member
          "severity"
          (lsp-json-number 1)
          (lsp-json-member
            "source"
            (json_mod.JsonString "typelisp")
            (lsp-json-member
              "code"
              (json_mod.JsonString code)
              (lsp-json-member
                "message"
                (json_mod.JsonString message)
                json_mod.JsonMemberListNil))))))))

(define (lsp-compiler-diagnostic [diag : CompilerDiagnostic]) : json_mod.Json
  (lsp-diagnostic
    (compiler-diagnostic-line diag)
    (compiler-diagnostic-col diag)
    (compiler-diagnostic-message diag)
    (compiler-diagnostic-code-or-empty diag)))

(define (lsp-compiler-diagnostic-code-ok?
  [diag : CompilerDiagnostic]
  [want : String]) : bool
  (match (lsp-json-string-field (lsp-compiler-diagnostic diag) "code")
    [(OkLspJsonText code) (string_mod.string-eq code want)]
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
    (if (or
      (string_mod.string-eq diag-path "")
      (string_mod.string-eq diag-path root-path))
      root-uri
      (lsp-path-to-file-uri diag-path))))

(define (lsp-publish-diagnostics
  [uri : String]
  [diagnostics : json_mod.JsonList]) : unit
  (lsp-write-json
    (lsp-json-object
      (lsp-json-rpc-member
        (lsp-json-member
          "method"
          (json_mod.JsonString "textDocument/publishDiagnostics")
          (lsp-json-member
            "params"
            (lsp-json-object2
              "uri"
              (json_mod.JsonString uri)
              "diagnostics"
              (lsp-json-array diagnostics))
            json_mod.JsonMemberListNil))))))

(define (lsp-publish-uri-diagnostic [uri : String] [message : String]) : unit
  (lsp-publish-diagnostics
    uri
    (lsp-json-list-cons (lsp-diagnostic 1 1 message "") json_mod.JsonListNil)))

(define (lsp-clear-stale-diagnostic
  [docs : LspDocuments]
  [uri : String]
  [next-diagnostic-uri : String]) : unit
  (match (lsp-documents-lookup docs uri)
    [(FoundLspDocument _ _ old-diagnostic-uri)
      (if (or
        (string_mod.string-eq old-diagnostic-uri "")
        (string_mod.string-eq old-diagnostic-uri uri)
        (string_mod.string-eq old-diagnostic-uri next-diagnostic-uri))
        unit
        (lsp-publish-diagnostics old-diagnostic-uri json_mod.JsonListNil))]
    [(MissingLspDocument) unit]))

(define (lsp-clear-close-diagnostics [docs : LspDocuments] [uri : String]) : unit
  (match (lsp-documents-lookup docs uri)
    [(FoundLspDocument _ _ old-diagnostic-uri)
      (begin
        (lsp-publish-diagnostics uri json_mod.JsonListNil)
        (if (or
          (string_mod.string-eq old-diagnostic-uri "")
          (string_mod.string-eq old-diagnostic-uri uri))
          unit
          (lsp-publish-diagnostics old-diagnostic-uri json_mod.JsonListNil)))]
    [(MissingLspDocument) (lsp-publish-diagnostics uri json_mod.JsonListNil)]))

;; --------------------------------------------------------------------------
;; Lint findings as diagnostics (Warning severity), published for the open
;; document alongside the compiler error diagnostics. Findings carry the rule
;; id as the diagnostic code; `;; lint-allow: <rule-id>` suppressions and
;; derived-origin (macro-expanded) filtering match the `typelisp lint` CLI.
;; --------------------------------------------------------------------------
(define (lsp-lint-diagnostic
  [line : i64]
  [col : i64]
  [message : String]
  [code : String]) : json_mod.Json
  (lsp-json-object
    (lsp-json-member
      "range"
      (lsp-range line col)
      (lsp-json-member
        "severity"
        (lsp-json-number 2)
        (lsp-json-member
          "source"
          (json_mod.JsonString "typelisp-lint")
          (lsp-json-member
            "code"
            (json_mod.JsonString code)
            (lsp-json-member
              "message"
              (json_mod.JsonString message)
              json_mod.JsonMemberListNil)))))))

(define (lsp-lint-finding-diagnostic [finding : LintFinding]) : json_mod.Json
  (let
    [span : AstSourceSpan (struct-get finding span)]
    (lsp-lint-diagnostic
      (struct-get span start-line)
      (struct-get span start-col)
      (struct-get finding message)
      (struct-get finding rule-id))))

(define (lsp-lint-findings-to-json
  [text : String]
  [findings : LintFindings]
  [i : i64]
  [acc : json_mod.JsonList]) : json_mod.JsonList
  (if (>= i (lint-findings-count findings))
    acc
    (let
      [finding : LintFinding (array-ref (lint-findings-slots findings) i)]
      (if (selfhost-lint-suppressed? text finding)
        (lsp-lint-findings-to-json text findings (+ i 1) acc)
        (lsp-lint-findings-to-json
          text
          findings
          (+ i 1)
          (lsp-json-list-cons (lsp-lint-finding-diagnostic finding) acc))))))

(define (lsp-lint-diagnostics
  [path : String]
  [text : String]
  [stdlib-roots : vector_mod.StringVec]) : json_mod.JsonList
  (lsp-lint-findings-to-json
    text
    (selfhost-lint-source-with-roots path text stdlib-roots)
    0
    json_mod.JsonListNil))

(define (lsp-analyze-document
  [uri : String]
  [path : String]
  [text : String]
  [stdlib-roots : vector_mod.StringVec]) : String
  (let
    [lint-diags : json_mod.JsonList
      (lsp-lint-diagnostics path text stdlib-roots)]
    (match (compiler-check-source-with-roots path text stdlib-roots)
      [(OkCompilerCheck _)
        (begin
          (lsp-publish-diagnostics uri lint-diags)
          "")]
      [(ErrCompilerCheck diag)
        (let
          [diag-uri : String (lsp-diagnostic-uri uri path diag)]
          (if (string_mod.string-eq diag-uri uri)
            (begin
              (lsp-publish-diagnostics
                uri
                (lsp-json-list-cons (lsp-compiler-diagnostic diag) lint-diags))
              uri)
            (begin
              (lsp-publish-diagnostics uri lint-diags)
              (lsp-publish-diagnostics
                diag-uri
                (lsp-json-list-cons
                  (lsp-compiler-diagnostic diag)
                  json_mod.JsonListNil))
              diag-uri)))])))

(define (lsp-first-change-text [params : json_mod.Json]) : LspJsonText
  (let
    [key : String "contentChanges"]
    (match (json_mod.json-object-get params (& key))
      [(json_mod.JsonFound value)
        (match value
          [(json_mod.JsonArray items)
            (match (box-get items)
              [(json_mod.JsonListNil) MissingLspJsonText]
              [(json_mod.JsonListCons first _)
                (lsp-json-string-field first "text")])]
          [_ MissingLspJsonText])]
      [(json_mod.JsonMissing) MissingLspJsonText])))

(define (lsp-did-open
  [params : json_mod.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector_mod.StringVec]) : LspHandleResult
  (let
    [key : String "textDocument"]
    (match (json_mod.json-object-get params (& key))
      [(json_mod.JsonFound document)
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
      [(json_mod.JsonMissing) (LspContinue docs)])))

(define (lsp-did-change
  [params : json_mod.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector_mod.StringVec]) : LspHandleResult
  (let
    [key : String "textDocument"]
    (match (json_mod.json-object-get params (& key))
      [(json_mod.JsonFound document)
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
      [(json_mod.JsonMissing) (LspContinue docs)])))

(define (lsp-did-close [params : json_mod.Json] [docs : LspDocuments]) : LspHandleResult
  (let
    [key : String "textDocument"]
    (match (json_mod.json-object-get params (& key))
      [(json_mod.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(OkLspJsonText uri)
            (begin
              (lsp-clear-close-diagnostics docs uri)
              (LspContinue (lsp-documents-remove docs uri)))]
          [(MissingLspJsonText) (LspContinue docs)])]
      [(json_mod.JsonMissing) (LspContinue docs)])))

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
          (if (= c #\\')
            (set! j (+ j 2))
            (if (= c #"')
              (begin
                (set! done true)
                (set! j (+ j 1)))
              (set! j (+ j 1))))))
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
            (string_mod.substring text start (- end start))))))))

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
        (string_mod.substring s (+ k 1) (- n (+ k 1)))
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
    (string_mod.string-eq kw "define")
    (string_mod.string-eq kw "defmacro")
    (string_mod.string-eq kw "defstruct")
    (string_mod.string-eq kw "defenum")
    (string_mod.string-eq kw "defdispatch")
    (string_mod.string-eq kw "extern")))

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
        [kw : String
          (string_mod.substring text after-open (- kw-end after-open))]
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
          (if (= c #;')
            (set! i (lsp-skip-line text i n))
            (if (= c ##')
              (set! i (lsp-skip-char-literal text i n))
              (if (= c #"')
                (set! i (lsp-skip-string text i n))
                (if (= c #(')
                  (let
                    [name-off : i64 (lsp-def-name-offset-at text i n)]
                    (if (>= name-off 0)
                      (if (string_mod.string-eq
                        (lsp-symbol-at-offset text name-off)
                        needle)
                        (set! found name-off)
                        (set! i (+ i 1)))
                      (set! i (+ i 1))))
                  (set! i (+ i 1))))))))
      found)))

;; Offset of the variant named `needle` within a defenum body [start, end), or
;; -1. Each top-level ( ... ) in the body is a variant constructor.
(define (lsp-variant-name-offset-in
  [text : String]
  [start : i64]
  [end : i64]
  [needle : String]) : i64
  (let
    [i : i64 start]
    [result : i64 -1]
    (begin
      (while (and (< i end) (< result 0))
        (let
          [c : char (string-ref text i)]
          (if (= c #"')
            (set! i (lsp-skip-string text i end))
            (if (= c #(')
              (let
                [vs : i64 (lsp-skip-space text (+ i 1) end)]
                [ve : i64 (lsp-scan-ident text vs end)]
                (if (string_mod.string-eq
                  (string_mod.substring text vs (- ve vs))
                  needle)
                  (set! result vs)
                  (set! i (lsp-skip-paren-group text i end))))
              (set! i (+ i 1))))))
      result)))

;; Offset of the enum variant named `needle` (within its defenum), or -1.
(define (lsp-find-variant-offset-in [text : String] [needle : String]) : i64
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [result : i64 -1]
    (begin
      (while (and (< i n) (< result 0))
        (let
          [c : char (string-ref text i)]
          (if (= c #;')
            (set! i (lsp-skip-line text i n))
            (if (= c ##')
              (set! i (lsp-skip-char-literal text i n))
              (if (= c #"')
                (set! i (lsp-skip-string text i n))
                (if (= c #(')
                  (let
                    [kw-start : i64 (lsp-skip-space text (+ i 1) n)]
                    [kw-end : i64 (lsp-scan-ident text kw-start n)]
                    (if (string_mod.string-eq
                      (string_mod.substring text kw-start (- kw-end kw-start))
                      "defenum")
                      (let
                        [name-end : i64
                          (lsp-scan-ident text (lsp-skip-space text kw-end n) n)]
                        [form-end : i64 (lsp-skip-paren-group text i n)]
                        [voff : i64
                          (lsp-variant-name-offset-in
                            text
                            name-end
                            form-end
                            needle)]
                        (if (>= voff 0)
                          (set! result voff)
                          (set! i form-end)))
                      (set! i (+ i 1))))
                  (set! i (+ i 1))))))))
      result)))

;; A top-level definition, else an enum variant.
(define (lsp-find-def-or-variant-offset-in [text : String] [needle : String]) : i64
  (let
    [off : i64 (lsp-find-def-offset-in text needle)]
    (if (>= off 0)
      off
      (lsp-find-variant-offset-in text needle))))

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
      (if (string_mod.string-eq (struct-get doc uri) current-uri)
        (lsp-find-definition-in-docs docs current-uri needle (+ idx 1))
        (let
          [off : i64
            (lsp-find-def-or-variant-offset-in (struct-get doc text) needle)]
          (if (>= off 0)
            (lsp-def-loc-from
              (struct-get doc uri)
              (struct-get doc text)
              off
              needle)
            (lsp-find-definition-in-docs docs current-uri needle (+ idx 1))))))))

;; Resolve `needle` to a definition: the current document first, then any other
;; open document.
;; Collect every (import "spec") spec from the document, skipping strings and
;; comments so embedded source never yields a false import.
(define (lsp-collect-imports [text : String] [acc : vector_mod.StringVec]) : vector_mod.StringVec
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [out : vector_mod.StringVec acc]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (if (= c #;')
            (set! i (lsp-skip-line text i n))
            (if (= c #"')
              (set! i (lsp-skip-string text i n))
              (if (= c #(')
                (let
                  [kw-start : i64 (lsp-skip-space text (+ i 1) n)]
                  [kw-end : i64 (lsp-scan-ident text kw-start n)]
                  (if (and
                    (> kw-end kw-start)
                    (string_mod.string-eq
                      (string_mod.substring text kw-start (- kw-end kw-start))
                      "import"))
                    (let
                      [q : i64 (lsp-skip-space text kw-end n)]
                      (if (and (< q n) (= (string-ref text q) #"'))
                        (let
                          [str-end : i64 (lsp-skip-string text q n)]
                          (begin
                            (set!
                              out
                              (vector_mod.string-vec-push
                                out
                                (string_mod.substring
                                  text
                                  (+ q 1)
                                  (- str-end (+ q 2)))))
                            (set! i str-end)))
                        (set! i (+ i 1))))
                    (set! i (+ i 1))))
                (set! i (+ i 1)))))))
      out)))

(defstruct LspModuleSet
  (paths vector_mod.StringVec)
  (texts vector_mod.StringVec))

(define (lsp-string-vec-contains? [v : vector_mod.StringVec] [s : String]) : bool
  (let
    [n : i64 (vector_mod.string-vec-len v)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (if (string_mod.string-eq (vector_mod.string-vec-get v i "") s)
          (set! found true)
          (set! i (+ i 1))))
      found)))

;; Add a resolved module path (and its source) to the set if new and under cap.
(define (lsp-module-set-add-path [set : LspModuleSet] [resolved : String]) : LspModuleSet
  (let
    [paths : vector_mod.StringVec (struct-get set paths)]
    [texts : vector_mod.StringVec (struct-get set texts)]
    (if (and
      (< (vector_mod.string-vec-len paths) 512)
      (not (lsp-string-vec-contains? paths resolved)))
      (LspModuleSet
        (vector_mod.string-vec-push paths resolved)
        (vector_mod.string-vec-push texts (io_mod.read-file-or (& resolved) "")))
      set)))

;; Add every module `text` imports (resolved like the loader) to the set.
(define (lsp-module-set-add-imports
  [importer-path : String]
  [text : String]
  [stdlib-roots : vector_mod.StringVec]
  [set : LspModuleSet]) : LspModuleSet
  (let
    [specs : vector_mod.StringVec
      (lsp-collect-imports text (vector_mod.string-vec-new))]
    [out : LspModuleSet set]
    [j : i64 0]
    (begin
      (while (< j (vector_mod.string-vec-len specs))
        (begin
          (set!
            out
            (lsp-module-set-add-path
              out
              (compiler-load-normalize-path
                (compiler-load-resolve-import-with-roots
                  importer-path
                  (vector_mod.string-vec-get specs j "")
                  stdlib-roots))))
          (set! j (+ j 1))))
      out)))

;; Every module transitively reachable from the document (plus the core
;; prelude), each read once. Shared by go-to-definition and hover.
(define (lsp-transitive-modules
  [start-path : String]
  [start-text : String]
  [stdlib-roots : vector_mod.StringVec]) : LspModuleSet
  (let
    [seeded : LspModuleSet
      (lsp-module-set-add-path
        (LspModuleSet (vector_mod.string-vec-new) (vector_mod.string-vec-new))
        (compiler-load-normalize-path
          (compiler-load-resolve-import-with-roots
            start-path
            "stdlib/core_macros.tl"
            stdlib-roots)))]
    [set : LspModuleSet
      (lsp-module-set-add-imports start-path start-text stdlib-roots seeded)]
    [i : i64 0]
    (begin
      (while (< i (vector_mod.string-vec-len (struct-get set paths)))
        (let
          [src : String (vector_mod.string-vec-get (struct-get set texts) i "")]
          (begin
            (if (string_mod.string-eq src "")
              unit
              (set!
                set
                (lsp-module-set-add-imports
                  (vector_mod.string-vec-get (struct-get set paths) i "")
                  src
                  stdlib-roots
                  set)))
            (set! i (+ i 1)))))
      set)))

;; Search the transitively reachable modules for the definition.
(define (lsp-find-definition-in-modules
  [set : LspModuleSet]
  [needle : String]
  [idx : i64]) : LspDefLocation
  (if (>= idx (vector_mod.string-vec-len (struct-get set paths)))
    MissingDefLoc
    (let
      [src : String (vector_mod.string-vec-get (struct-get set texts) idx "")]
      [off : i64 (lsp-find-def-or-variant-offset-in src needle)]
      (if (>= off 0)
        (lsp-def-loc-from
          (lsp-path-to-file-uri
            (vector_mod.string-vec-get (struct-get set paths) idx ""))
          src
          off
          needle)
        (lsp-find-definition-in-modules set needle (+ idx 1))))))

;; Resolve `needle`: current document, then any other open document, then the
;; modules transitively reachable from this document.
(define (lsp-find-definition
  [docs : LspDocuments]
  [current-uri : String]
  [current-path : String]
  [current-text : String]
  [stdlib-roots : vector_mod.StringVec]
  [needle : String]) : LspDefLocation
  (let
    [off : i64 (lsp-find-def-or-variant-offset-in current-text needle)]
    (if (>= off 0)
      (lsp-def-loc-from current-uri current-text off needle)
      (match (lsp-find-definition-in-docs docs current-uri needle 0)
        [(FoundDefLoc def-uri def-line def-col def-len)
          (FoundDefLoc def-uri def-line def-col def-len)]
        [(MissingDefLoc)
          (lsp-find-definition-in-modules
            (lsp-transitive-modules current-path current-text stdlib-roots)
            needle
            0)]))))

(define (lsp-json-int-field-default
  [value : json_mod.Json]
  [key : String]
  [fallback : i64]) : i64
  (match (json_mod.json-object-get value (& key))
    [(json_mod.JsonFound field)
      (match field
        [(json_mod.JsonNumber text)
          (match (json_mod.json-number->i64 (& text))
            [(json_mod.OkJsonNumberI64 number) number]
            [(json_mod.ErrJsonNumberI64 _) fallback])]
        [_ fallback])]
    [(json_mod.JsonMissing) fallback]))

(define (lsp-definition-location
  [uri : String]
  [line : i64]
  [col : i64]
  [len : i64]) : json_mod.Json
  (lsp-json-object2
    "uri"
    (json_mod.JsonString uri)
    "range"
    (lsp-json-object2
      "start"
      (lsp-position line col)
      "end"
      (lsp-position line (+ col len)))))

(define (lsp-definition-respond
  [id : json_mod.Json]
  [uri : String]
  [position : json_mod.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector_mod.StringVec]) : unit
  (match (lsp-documents-lookup docs uri)
    [(FoundLspDocument path text _)
      (let
        [line0 : i64 (lsp-json-int-field-default position "line" 0)]
        [char0 : i64 (lsp-json-int-field-default position "character" 0)]
        [off : i64 (lsp-offset-at-position text line0 char0)]
        [sym : String (lsp-symbol-at-offset text off)]
        (if (string_mod.string-eq sym "")
          (lsp-write-response id json_mod.JsonNull)
          (match (lsp-find-definition
            docs
            uri
            path
            text
            stdlib-roots
            (lsp-symbol-base sym))
            [(FoundDefLoc def-uri def-line def-col def-len)
              (lsp-write-response
                id
                (lsp-definition-location def-uri def-line def-col def-len))]
            [(MissingDefLoc) (lsp-write-response id json_mod.JsonNull)])))]
    [(MissingLspDocument) (lsp-write-response id json_mod.JsonNull)]))

(define (lsp-handle-definition
  [id : json_mod.Json]
  [params : json_mod.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector_mod.StringVec]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json_mod.json-object-get params (& td-key))
      [(json_mod.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(OkLspJsonText uri)
            (let
              [pos-key : String "position"]
              (match (json_mod.json-object-get params (& pos-key))
                [(json_mod.JsonFound position)
                  (lsp-definition-respond id uri position docs stdlib-roots)]
                [(json_mod.JsonMissing)
                  (lsp-write-response id json_mod.JsonNull)]))]
          [(MissingLspJsonText) (lsp-write-response id json_mod.JsonNull)])]
      [(json_mod.JsonMissing) (lsp-write-response id json_mod.JsonNull)])))

(define (lsp-definition-smoke-basic?) : bool
  (let
    [src : String
      "(define (foo [x : i64]) : i64 x)\n(define (bar) : i64 (foo 1))\n"]
    [off : i64 (lsp-offset-at-position src 1 22)]
    [sym : String (lsp-symbol-at-offset src off)]
    (if (not (string_mod.string-eq sym "foo"))
      false
      (match (lsp-find-definition
        (lsp-documents-new)
        "file:///smoke.tl"
        "smoke.tl"
        src
        (vector_mod.string-vec-new)
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
      "smoke.tl"
      src
      (vector_mod.string-vec-new)
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
      "smoke.tl"
      src
      (vector_mod.string-vec-new)
      "target")
      [(FoundDefLoc _ line col len) (and (= line 2) (= col 10) (= len 6))]
      [(MissingDefLoc) false])))

(define (lsp-definition-smoke-qualified-base?) : bool
  (and
    (string_mod.string-eq (lsp-symbol-base "core/cond") "cond")
    (string_mod.string-eq (lsp-symbol-base "core.cond") "cond")))

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

(define (lsp-split-spaces [s : String]) : vector_mod.StringVec
  (let
    [n : i64 (string-length s)]
    [i : i64 0]
    [start : i64 0]
    [acc : vector_mod.StringVec (vector_mod.string-vec-new)]
    (begin
      (while (< i n)
        (begin
          (if (= (string-ref s i) #\space')
            (begin
              (if (> i start)
                (set!
                  acc
                  (vector_mod.string-vec-push
                    acc
                    (string_mod.substring s start (- i start))))
                unit)
              (set! start (+ i 1)))
            unit)
          (set! i (+ i 1))))
      (if (> n start)
        (set!
          acc
          (vector_mod.string-vec-push
            acc
            (string_mod.substring s start (- n start))))
        unit)
      acc)))

(define (lsp-completion-item [label : String] [kind : i64]) : json_mod.Json
  (lsp-json-object2
    "label"
    (json_mod.JsonString label)
    "kind"
    (lsp-json-number kind)))

(define (lsp-completion-items-from
  [labels : vector_mod.StringVec]
  [kind : i64]
  [idx : i64]
  [acc : json_mod.JsonList]) : json_mod.JsonList
  (if (>= idx (vector_mod.string-vec-len labels))
    acc
    (lsp-completion-items-from
      labels
      kind
      (+ idx 1)
      (lsp-json-list-cons
        (lsp-completion-item (vector_mod.string-vec-get labels idx "") kind)
        acc))))

;; Collect every top-level definition name in `text`, skipping strings/comments.
(define (lsp-collect-def-names [text : String] [acc : vector_mod.StringVec]) : vector_mod.StringVec
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [out : vector_mod.StringVec acc]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (if (= c #;')
            (set! i (lsp-skip-line text i n))
            (if (= c #"')
              (set! i (lsp-skip-string text i n))
              (if (= c #(')
                (let
                  [name-off : i64 (lsp-def-name-offset-at text i n)]
                  (begin
                    (if (>= name-off 0)
                      (set!
                        out
                        (vector_mod.string-vec-push
                          out
                          (lsp-symbol-at-offset text name-off)))
                      unit)
                    (set! i (+ i 1))))
                (set! i (+ i 1)))))))
      out)))

(define (lsp-collect-def-names-all
  [docs : LspDocuments]
  [idx : i64]
  [acc : vector_mod.StringVec]) : vector_mod.StringVec
  (if (>= idx (lsp-documents-len docs))
    acc
    (lsp-collect-def-names-all
      docs
      (+ idx 1)
      (lsp-collect-def-names
        (struct-get (array-ref (lsp-documents-slots docs) idx) text)
        acc))))

(define (lsp-completion-respond [id : json_mod.Json] [docs : LspDocuments]) : unit
  (let
    [names : vector_mod.StringVec
      (lsp-collect-def-names-all docs 0 (vector_mod.string-vec-new))]
    [items : json_mod.JsonList
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
              json_mod.JsonListNil))))]
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

(define (lsp-inlay-range-line
  [range : json_mod.Json]
  [which : String]
  [fallback : i64]) : i64
  (match (json_mod.json-object-get range (& which))
    [(json_mod.JsonFound endpoint)
      (lsp-json-int-field-default endpoint "line" fallback)]
    [(json_mod.JsonMissing) fallback]))

(define (lsp-inlay-hint-json [line : i64] [col : i64] [ty : String]) : json_mod.Json
  (lsp-json-object4
    "position"
    (lsp-position line col)
    "label"
    (json_mod.JsonString (string_mod.string-append ": " ty))
    "kind"
    (lsp-json-number 1)
    "paddingRight"
    (json_mod.JsonBool true)))

(define (lsp-inlay-build [text : String] [start-line : i64] [end-line : i64]) : json_mod.JsonList
  (let
    [size : i64 (tc-inlay-hints-size)]
    [i : i64 0]
    [acc : json_mod.JsonList json_mod.JsonListNil]
    (begin
      (while (< i size)
        (let
          [line1 : i64 (tc-inlay-hint-line-at i)]
          [col1 : i64 (tc-inlay-hint-col-at i)]
          [line0 : i64 (- line1 1)]
          (begin
            (if (and
              (>= line0 start-line)
              (<= line0 end-line)
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
  [id : json_mod.Json]
  [uri : String]
  [range : json_mod.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector_mod.StringVec]) : unit
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
            [hints : json_mod.JsonList
              (lsp-inlay-build text start-line end-line)]
            (begin
              (tc-inlay-hints-disable!)
              (lsp-write-response id (lsp-json-array hints))))))]
    [(MissingLspDocument)
      (lsp-write-response id (lsp-json-array json_mod.JsonListNil))]))

(define (lsp-handle-inlay
  [id : json_mod.Json]
  [params : json_mod.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector_mod.StringVec]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json_mod.json-object-get params (& td-key))
      [(json_mod.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(OkLspJsonText uri)
            (let
              [range-key : String "range"]
              (match (json_mod.json-object-get params (& range-key))
                [(json_mod.JsonFound range)
                  (lsp-inlay-respond id uri range docs stdlib-roots)]
                [(json_mod.JsonMissing)
                  (lsp-write-response id (lsp-json-array json_mod.JsonListNil))]))]
          [(MissingLspJsonText)
            (lsp-write-response id (lsp-json-array json_mod.JsonListNil))])]
      [(json_mod.JsonMissing)
        (lsp-write-response id (lsp-json-array json_mod.JsonListNil))])))

;; --------------------------------------------------------------------------
;; Document formatting (textDocument/formatting), enabling format-on-save.
;;
;; Reuses the `typelisp fmt` formatter (format-rules, width 80). On a parse
;; error the document is left untouched (empty edit list) so saving never
;; mangles in-progress code.
;; --------------------------------------------------------------------------
(define (lsp-formatting-edit [text : String] [formatted : String]) : json_mod.Json
  (let
    [end : LspLineCol (lsp-line-col-at-offset text (string-length text))]
    (lsp-json-object2
      "range"
      (lsp-json-object2
        "start"
        (lsp-position 1 1)
        "end"
        (lsp-position (struct-get end line) (struct-get end col)))
      "newText"
      (json_mod.JsonString formatted))))

(define (lsp-formatting-respond
  [id : json_mod.Json]
  [uri : String]
  [docs : LspDocuments]) : unit
  (match (lsp-documents-lookup docs uri)
    [(FoundLspDocument _ text _)
      (match (format-rules-render-source-width-result text 80)
        [(OkFormatString formatted)
          (lsp-write-response
            id
            (lsp-json-array
              (lsp-json-list-cons
                (lsp-formatting-edit text formatted)
                json_mod.JsonListNil)))]
        [(ErrFormatString _)
          (lsp-write-response id (lsp-json-array json_mod.JsonListNil))])]
    [(MissingLspDocument)
      (lsp-write-response id (lsp-json-array json_mod.JsonListNil))]))

(define (lsp-handle-formatting
  [id : json_mod.Json]
  [params : json_mod.Json]
  [docs : LspDocuments]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json_mod.json-object-get params (& td-key))
      [(json_mod.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(OkLspJsonText uri) (lsp-formatting-respond id uri docs)]
          [(MissingLspJsonText)
            (lsp-write-response id (lsp-json-array json_mod.JsonListNil))])]
      [(json_mod.JsonMissing)
        (lsp-write-response id (lsp-json-array json_mod.JsonListNil))])))

;; --------------------------------------------------------------------------
;; Hover (textDocument/hover).
;;
;; Entirely text-based: parameter/let-binding types come from the [name : type]
;; declaration, function signatures from the (define ...) header, and docs from
;; the ;: / ;# comment lines directly above the definition (current document,
;; other open documents, or imported modules).
;; --------------------------------------------------------------------------
;; Offset just past a balanced ( ... ) group starting at `i`.
(define (lsp-skip-paren-group [text : String] [i : i64] [n : i64]) : i64
  (let
    [j : i64 i]
    [depth : i64 0]
    [done : bool false]
    (begin
      (while (and (< j n) (not done))
        (let
          [c : char (string-ref text j)]
          (if (= c #;')
            (set! j (lsp-skip-line text j n))
            (if (= c ##')
              (set! j (lsp-skip-char-literal text j n))
              (if (= c #"')
                (set! j (lsp-skip-string text j n))
                (if (= c #(')
                  (begin
                    (set! depth (+ depth 1))
                    (set! j (+ j 1)))
                  (if (= c #)')
                    (begin
                      (set! depth (- depth 1))
                      (set! j (+ j 1))
                      (if (<= depth 0)
                        (set! done true)
                        unit))
                    (set! j (+ j 1)))))))))
      j)))

;; End offset of one type expression (a ( ... ) group or a single token).
(define (lsp-scan-type [text : String] [i : i64] [n : i64]) : i64
  (if (and (< i n) (= (string-ref text i) #('))
    (lsp-skip-paren-group text i n)
    (lsp-scan-ident text i n)))

;; Declared type of the nearest [sym : TYPE] binding whose name starts at or
;; before `limit`, or "" if none (function params and let bindings).
(define (lsp-binding-type [text : String] [sym : String] [limit : i64]) : String
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [result : String ""]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (if (= c #;')
            (set! i (lsp-skip-line text i n))
            (if (= c ##')
              (set! i (lsp-skip-char-literal text i n))
              (if (= c #"')
                (set! i (lsp-skip-string text i n))
                (if (= c #[')
                  (let
                    [name-start : i64 (lsp-skip-space text (+ i 1) n)]
                    [name-end : i64 (lsp-scan-ident text name-start n)]
                    (begin
                      (if (and
                        (> name-end name-start)
                        (<= name-start limit)
                        (string_mod.string-eq
                          (string_mod.substring
                            text
                            name-start
                            (- name-end name-start))
                          sym))
                        (let
                          [after : i64 (lsp-skip-space text name-end n)]
                          (if (and (< after n) (= (string-ref text after) #:'))
                            (let
                              [ty-start : i64
                                (lsp-skip-space text (+ after 1) n)]
                              [ty-end : i64 (lsp-scan-type text ty-start n)]
                              (set!
                                result
                                (string_mod.substring
                                  text
                                  ty-start
                                  (- ty-end ty-start))))
                            unit))
                        unit)
                      (set! i (+ i 1))))
                  (set! i (+ i 1))))))))
      result)))

;; Offset of the ( that opens the definition form whose name is `needle`, or -1.
(define (lsp-find-def-form-in [text : String] [needle : String]) : i64
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< i n) (< found 0))
        (let
          [c : char (string-ref text i)]
          (if (= c #;')
            (set! i (lsp-skip-line text i n))
            (if (= c ##')
              (set! i (lsp-skip-char-literal text i n))
              (if (= c #"')
                (set! i (lsp-skip-string text i n))
                (if (= c #(')
                  (let
                    [name-off : i64 (lsp-def-name-offset-at text i n)]
                    (if (>= name-off 0)
                      (if (string_mod.string-eq
                        (lsp-symbol-at-offset text name-off)
                        needle)
                        (set! found i)
                        (set! i (+ i 1)))
                      (set! i (+ i 1))))
                  (set! i (+ i 1))))))))
      found)))

(define (lsp-hover-resolve-in-docs
  [docs : LspDocuments]
  [current-uri : String]
  [needle : String]
  [idx : i64]) : LspDefSource
  (if (>= idx (lsp-documents-len docs))
    MissingDefSource
    (let
      [doc : LspDocument (array-ref (lsp-documents-slots docs) idx)]
      (if (string_mod.string-eq (struct-get doc uri) current-uri)
        (lsp-hover-resolve-in-docs docs current-uri needle (+ idx 1))
        (let
          [doc-text : String (struct-get doc text)]
          [off : i64 (lsp-find-def-form-in doc-text needle)]
          (if (>= off 0)
            (FoundDefSource doc-text off)
            (lsp-hover-resolve-in-docs docs current-uri needle (+ idx 1))))))))

(define (lsp-hover-resolve-in-modules
  [set : LspModuleSet]
  [needle : String]
  [idx : i64]) : LspDefSource
  (if (>= idx (vector_mod.string-vec-len (struct-get set paths)))
    MissingDefSource
    (let
      [src : String (vector_mod.string-vec-get (struct-get set texts) idx "")]
      [off : i64 (lsp-find-def-form-in src needle)]
      (if (>= off 0)
        (FoundDefSource src off)
        (lsp-hover-resolve-in-modules set needle (+ idx 1))))))

(define (lsp-hover-resolve
  [docs : LspDocuments]
  [current-uri : String]
  [current-path : String]
  [current-text : String]
  [stdlib-roots : vector_mod.StringVec]
  [needle : String]) : LspDefSource
  (let
    [off : i64 (lsp-find-def-form-in current-text needle)]
    (if (>= off 0)
      (FoundDefSource current-text off)
      (match (lsp-hover-resolve-in-docs docs current-uri needle 0)
        [(FoundDefSource src form-off) (FoundDefSource src form-off)]
        [(MissingDefSource)
          (lsp-hover-resolve-in-modules
            (lsp-transitive-modules current-path current-text stdlib-roots)
            needle
            0)]))))

;; The (define ...) header up to and including the return type, e.g.
;; "(define (foo [a : i64]) : bool".
(define (lsp-define-header [text : String] [form-off : i64]) : String
  (let
    [n : i64 (string-length text)]
    [after-open : i64 (lsp-skip-space text (+ form-off 1) n)]
    [kw-end : i64 (lsp-scan-ident text after-open n)]
    [kw : String (string_mod.substring text after-open (- kw-end after-open))]
    (if (or
      (string_mod.string-eq kw "defenum")
      (string_mod.string-eq kw "defstruct"))
      ;; Enums/structs have no (params) : ret; show the whole form (variants
      ;; or fields), so multi-line definitions render in full.
      (string_mod.substring
        text
        form-off
        (- (lsp-skip-paren-group text form-off n) form-off))
      (let
        [j : i64 (lsp-skip-space text kw-end n)]
        (begin
          (if (and (< j n) (= (string-ref text j) #('))
            (set! j (lsp-skip-paren-group text j n))
            (set! j (lsp-scan-ident text j n)))
          (let
            [k : i64 (lsp-skip-space text j n)]
            (if (and (< k n) (= (string-ref text k) #:'))
              (set! j (lsp-scan-type text (lsp-skip-space text (+ k 1) n) n))
              unit))
          (string_mod.substring text form-off (- j form-off)))))))

;; Start index of the line containing `pos`.
(define (lsp-line-start-before [text : String] [pos : i64]) : i64
  (let
    [i : i64 pos]
    (begin
      (while (and (> i 0) (not (= (string-ref text (- i 1)) #\newline')))
        (set! i (- i 1)))
      i)))

;; True when the line at `line-start` is a ;: or ;# documentation comment.
(define (lsp-doc-comment-line? [text : String] [line-start : i64] [n : i64]) : bool
  (let
    [i : i64 line-start]
    (begin
      (while (and
        (< i n)
        (or (= (string-ref text i) #\space') (= (string-ref text i) #\tab')))
        (set! i (+ i 1)))
      (and
        (< (+ i 1) n)
        (= (string-ref text i) #;')
        (or (= (string-ref text (+ i 1)) #:') (= (string-ref text (+ i 1)) ##'))))))

;; Text of a ;: / ;# doc-comment line (prefix and one space stripped).
(define (lsp-doc-comment-text [text : String] [line-start : i64] [n : i64]) : String
  (let
    [i : i64 line-start]
    (begin
      (while (and
        (< i n)
        (or (= (string-ref text i) #\space') (= (string-ref text i) #\tab')))
        (set! i (+ i 1)))
      (set! i (+ i 2))
      (if (and (< i n) (= (string-ref text i) #\space'))
        (set! i (+ i 1))
        unit)
      (let
        [end : i64 i]
        (begin
          (while (and (< end n) (not (= (string-ref text end) #\newline')))
            (set! end (+ end 1)))
          (string_mod.substring text i (- end i)))))))

;; Contiguous doc-comment lines immediately above the definition form, joined.
(define (lsp-doc-comments-above [text : String] [form-off : i64]) : String
  (let
    [n : i64 (string-length text)]
    [line-start : i64 (lsp-line-start-before text form-off)]
    [acc : String ""]
    [done : bool false]
    (begin
      (while (and (> line-start 0) (not done))
        (let
          [prev-line-start : i64 (lsp-line-start-before text (- line-start 1))]
          (if (lsp-doc-comment-line? text prev-line-start n)
            (begin
              (set!
                acc
                (string_mod.string-append
                  (lsp-doc-comment-text text prev-line-start n)
                  (string_mod.string-append "\n" acc)))
              (set! line-start prev-line-start))
            (set! done true))))
      acc)))

(define (lsp-hover-markdown [body : String] [docs : String]) : String
  (if (string_mod.string-eq docs "")
    (string_mod.string-append
      "```typelisp\n"
      (string_mod.string-append body "\n```"))
    (string_mod.string-append
      "```typelisp\n"
      (string_mod.string-append
        body
        (string_mod.string-append "\n```\n\n" docs)))))

(define (lsp-hover-result
  [markdown : String]
  [line : i64]
  [col : i64]
  [len : i64]) : json_mod.Json
  (lsp-json-object2
    "contents"
    (lsp-json-object2
      "kind"
      (json_mod.JsonString "markdown")
      "value"
      (json_mod.JsonString markdown))
    "range"
    (lsp-json-object2
      "start"
      (lsp-position line col)
      "end"
      (lsp-position line (+ col len)))))

;; Within a defenum's body [start, end), the form of the variant named `needle`
;; (e.g. "(OkCleanConfig CleanConfig)"), or "" if no variant matches.
(define (lsp-variant-form-in
  [text : String]
  [start : i64]
  [end : i64]
  [needle : String]) : String
  (let
    [i : i64 start]
    [result : String ""]
    (begin
      (while (and (< i end) (string_mod.string-eq result ""))
        (let
          [c : char (string-ref text i)]
          (if (= c #"')
            (set! i (lsp-skip-string text i end))
            (if (= c #(')
              (let
                [vs : i64 (lsp-skip-space text (+ i 1) end)]
                [ve : i64 (lsp-scan-ident text vs end)]
                (if (string_mod.string-eq
                  (string_mod.substring text vs (- ve vs))
                  needle)
                  (set!
                    result
                    (string_mod.substring
                      text
                      i
                      (- (lsp-skip-paren-group text i end) i)))
                  (set! i (lsp-skip-paren-group text i end))))
              (set! i (+ i 1))))))
      result)))

;; If `needle` names an enum variant, return its enum name and constructor form.
(define (lsp-enum-of-variant [text : String] [needle : String]) : LspVariantHit
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [enum-name : String ""]
    [variant-form : String ""]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (let
          [c : char (string-ref text i)]
          (if (= c #;')
            (set! i (lsp-skip-line text i n))
            (if (= c ##')
              (set! i (lsp-skip-char-literal text i n))
              (if (= c #"')
                (set! i (lsp-skip-string text i n))
                (if (= c #(')
                  (let
                    [kw-start : i64 (lsp-skip-space text (+ i 1) n)]
                    [kw-end : i64 (lsp-scan-ident text kw-start n)]
                    (if (string_mod.string-eq
                      (string_mod.substring text kw-start (- kw-end kw-start))
                      "defenum")
                      (let
                        [name-start : i64 (lsp-skip-space text kw-end n)]
                        [name-end : i64 (lsp-scan-ident text name-start n)]
                        [form-end : i64 (lsp-skip-paren-group text i n)]
                        [variant : String
                          (lsp-variant-form-in text name-end form-end needle)]
                        (if (string_mod.string-eq variant "")
                          (set! i form-end)
                          (begin
                            (set!
                              enum-name
                              (string_mod.substring
                                text
                                name-start
                                (- name-end name-start)))
                            (set! variant-form variant)
                            (set! found true))))
                      (set! i (+ i 1))))
                  (set! i (+ i 1))))))))
      (if found
        (FoundVariant enum-name variant-form)
        MissingVariant))))

(define (lsp-resolve-variant-in-docs
  [docs : LspDocuments]
  [current-uri : String]
  [needle : String]
  [idx : i64]) : LspVariantHit
  (if (>= idx (lsp-documents-len docs))
    MissingVariant
    (let
      [doc : LspDocument (array-ref (lsp-documents-slots docs) idx)]
      (if (string_mod.string-eq (struct-get doc uri) current-uri)
        (lsp-resolve-variant-in-docs docs current-uri needle (+ idx 1))
        (match (lsp-enum-of-variant (struct-get doc text) needle)
          [(FoundVariant enum-name variant-form)
            (FoundVariant enum-name variant-form)]
          [(MissingVariant)
            (lsp-resolve-variant-in-docs docs current-uri needle (+ idx 1))])))))

(define (lsp-resolve-variant-in-modules
  [set : LspModuleSet]
  [needle : String]
  [idx : i64]) : LspVariantHit
  (if (>= idx (vector_mod.string-vec-len (struct-get set paths)))
    MissingVariant
    (match (lsp-enum-of-variant
      (vector_mod.string-vec-get (struct-get set texts) idx "")
      needle)
      [(FoundVariant enum-name variant-form)
        (FoundVariant enum-name variant-form)]
      [(MissingVariant) (lsp-resolve-variant-in-modules set needle (+ idx 1))])))

;; Find the enum/variant in the current document, other open documents, then
;; imported modules (same reach as go-to-definition).
(define (lsp-resolve-variant
  [docs : LspDocuments]
  [current-uri : String]
  [current-path : String]
  [current-text : String]
  [stdlib-roots : vector_mod.StringVec]
  [needle : String]) : LspVariantHit
  (match (lsp-enum-of-variant current-text needle)
    [(FoundVariant enum-name variant-form)
      (FoundVariant enum-name variant-form)]
    [(MissingVariant)
      (match (lsp-resolve-variant-in-docs docs current-uri needle 0)
        [(FoundVariant enum-name variant-form)
          (FoundVariant enum-name variant-form)]
        [(MissingVariant)
          (lsp-resolve-variant-in-modules
            (lsp-transitive-modules current-path current-text stdlib-roots)
            needle
            0)])]))

;; Curated hover for builtins, operators, and special forms (no source
;; (define ...) exists for these). Returns markdown, or "" when unknown.
(define (lsp-builtin-hover [name : String]) : String
  (let
    [result : String ""]
    (begin
      (if (and
        (string_mod.string-eq result "")
        (or
          (string_mod.string-eq name "i64")
          (string_mod.string-eq name "i32")
          (string_mod.string-eq name "i16")
          (string_mod.string-eq name "i8")))
        (set!
          result
          (lsp-hover-markdown
            name
            "Signed integer (two's complement) of the named bit width."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (or
          (string_mod.string-eq name "u64")
          (string_mod.string-eq name "u32")
          (string_mod.string-eq name "u16")
          (string_mod.string-eq name "u8")))
        (set!
          result
          (lsp-hover-markdown name "Unsigned integer of the named bit width."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (or (string_mod.string-eq name "f64") (string_mod.string-eq name "f32")))
        (set!
          result
          (lsp-hover-markdown
            name
            "IEEE-754 floating-point number (64- or 32-bit)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "bool"))
        (set! result (lsp-hover-markdown "bool" "Boolean: `true` or `false`."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "char"))
        (set!
          result
          (lsp-hover-markdown "char" "A character value (written like `#a'`)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "String"))
        (set!
          result
          (lsp-hover-markdown "String" "Owned, heap-allocated UTF-8 string."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "str"))
        (set!
          result
          (lsp-hover-markdown
            "str"
            "Borrowed string slice (used as `(& str)`)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "unit"))
        (set!
          result
          (lsp-hover-markdown "unit" "The unit type; its only value is `unit`."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "never"))
        (set!
          result
          (lsp-hover-markdown
            "never"
            "The empty type, for expressions that never return (e.g. `panic`)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "Array"))
        (set!
          result
          (lsp-hover-markdown
            "(Array T)"
            "Dynamically sized, heap-allocated array of `T`."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "Tuple"))
        (set!
          result
          (lsp-hover-markdown
            "(Tuple A B ...)"
            "Fixed-size tuple of the given element types."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "Box"))
        (set!
          result
          (lsp-hover-markdown
            "(Box T)"
            "Heap-allocated `T`; used for recursive data structures."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "Ptr"))
        (set!
          result
          (lsp-hover-markdown
            "(Ptr T)"
            "Raw immutable pointer to `T` (unsafe to dereference)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "MutPtr"))
        (set!
          result
          (lsp-hover-markdown
            "(MutPtr T)"
            "Raw mutable pointer to `T` (unsafe to dereference)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (or
          (string_mod.string-eq name "+")
          (string_mod.string-eq name "-")
          (string_mod.string-eq name "*")
          (string_mod.string-eq name "/")))
        (set!
          result
          (lsp-hover-markdown
            (string_mod.string-append name " : (-> num num num)")
            "Arithmetic on two integers or floats of the same numeric type."))
        unit)
      (if (and (string_mod.string-eq result "") (string_mod.string-eq name "%"))
        (set!
          result
          (lsp-hover-markdown
            "% : (-> int int int)"
            "Integer remainder (modulo)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (or (string_mod.string-eq name "=") (string_mod.string-eq name "!=")))
        (set!
          result
          (lsp-hover-markdown
            (string_mod.string-append name " : (-> a a bool)")
            "Equality / inequality comparison."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (or
          (string_mod.string-eq name "<")
          (string_mod.string-eq name "<=")
          (string_mod.string-eq name ">")
          (string_mod.string-eq name ">=")))
        (set!
          result
          (lsp-hover-markdown
            (string_mod.string-append name " : (-> a a bool)")
            "Ordering comparison."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (or (string_mod.string-eq name "shl") (string_mod.string-eq name "shr")))
        (set!
          result
          (lsp-hover-markdown
            (string_mod.string-append name " : (-> int int int)")
            "Bit shift left / right."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (or
          (string_mod.string-eq name "bit-and")
          (string_mod.string-eq name "bit-or")
          (string_mod.string-eq name "bit-xor")))
        (set!
          result
          (lsp-hover-markdown
            (string_mod.string-append name " : (-> int int int)")
            "Bitwise and / or / xor."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "bit-not"))
        (set!
          result
          (lsp-hover-markdown "bit-not : (-> int int)" "Bitwise complement."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "not"))
        (set!
          result
          (lsp-hover-markdown "not : (-> bool bool)" "Logical negation."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "neg"))
        (set!
          result
          (lsp-hover-markdown "neg : (-> num num)" "Numeric negation."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "string-length"))
        (set!
          result
          (lsp-hover-markdown
            "string-length : (-> String i64)"
            "Number of bytes in a string."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "string-ref"))
        (set!
          result
          (lsp-hover-markdown
            "string-ref : (-> String i64 char)"
            "Byte at the given index."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "string-data"))
        (set!
          result
          (lsp-hover-markdown
            "string-data : (-> String (Ptr u8))"
            "Pointer to a string's bytes."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "make-array"))
        (set!
          result
          (lsp-hover-markdown
            "make-array : (-> Type i64 (Array T))"
            "Allocate a zero-initialized array of the given element type and length."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "array-ref"))
        (set!
          result
          (lsp-hover-markdown
            "array-ref : (-> (Array T) i64 T)"
            "Read an array element (bounds-checked)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "array-set!"))
        (set!
          result
          (lsp-hover-markdown
            "array-set! : (-> (Array T) i64 T unit)"
            "Write an array element (bounds-checked)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "array-push!"))
        (set!
          result
          (lsp-hover-markdown
            "array-push! : (-> (Array T) T unit)"
            "Append a value to a dynamic array."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "array-data"))
        (set!
          result
          (lsp-hover-markdown
            "array-data : (-> (Array T) (Ptr T))"
            "Pointer to an array's storage."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "tuple-ref"))
        (set!
          result
          (lsp-hover-markdown
            "tuple-ref : (-> Tuple i64 T)"
            "Read a tuple element by constant index."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "struct-get"))
        (set!
          result
          (lsp-hover-markdown
            "struct-get : (-> Struct field T)"
            "Read a struct field by name."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "ptr-null"))
        (set!
          result
          (lsp-hover-markdown
            "ptr-null : (-> (Ptr T))"
            "Null pointer of the given type."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "ptr-null?"))
        (set!
          result
          (lsp-hover-markdown
            "ptr-null? : (-> (Ptr T) bool)"
            "Whether a pointer is null."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "ptr-read"))
        (set!
          result
          (lsp-hover-markdown
            "ptr-read : (-> (Ptr T) i64 T)"
            "Read the element at an offset from a pointer (unsafe)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "ptr-write!"))
        (set!
          result
          (lsp-hover-markdown
            "ptr-write! : (-> (MutPtr T) i64 T unit)"
            "Write the element at an offset through a pointer (unsafe)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "ptr-offset"))
        (set!
          result
          (lsp-hover-markdown
            "ptr-offset : (-> (Ptr T) i64 (Ptr T))"
            "Offset a pointer by N elements (unsafe)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "ptr-cast"))
        (set!
          result
          (lsp-hover-markdown
            "ptr-cast : (-> (Ptr A) Type (Ptr B))"
            "Reinterpret a pointer's element type (unsafe)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "ptr->int"))
        (set!
          result
          (lsp-hover-markdown
            "ptr->int : (-> (Ptr T) u64)"
            "Pointer to integer address (unsafe)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "int->ptr"))
        (set!
          result
          (lsp-hover-markdown
            "int->ptr : (-> u64 Type (Ptr T))"
            "Integer address to pointer (unsafe)."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "if"))
        (set!
          result
          (lsp-hover-markdown
            "(if cond then else)"
            "Conditional expression; both branches must have the same type."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "let"))
        (set!
          result
          (lsp-hover-markdown
            "(let [name : T value] ... body)"
            "Introduce local bindings, then evaluate the body."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "begin"))
        (set!
          result
          (lsp-hover-markdown
            "(begin expr ...)"
            "Evaluate expressions in sequence; the result is the last."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "while"))
        (set!
          result
          (lsp-hover-markdown
            "(while cond body)"
            "Loop while the condition is true."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "set!"))
        (set!
          result
          (lsp-hover-markdown "(set! name value)" "Mutate an existing binding."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "match"))
        (set!
          result
          (lsp-hover-markdown
            "(match value [pattern body] ...)"
            "Pattern match on an enum value."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "return"))
        (set!
          result
          (lsp-hover-markdown
            "(return value)"
            "Return early from the enclosing function."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "lambda"))
        (set!
          result
          (lsp-hover-markdown "(lambda [p : T] ... body)" "Anonymous function."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "cast"))
        (set!
          result
          (lsp-hover-markdown
            "(cast value : Type)"
            "Convert a value to another numeric or pointer type."))
        unit)
      (if (and
        (string_mod.string-eq result "")
        (string_mod.string-eq name "unsafe"))
        (set!
          result
          (lsp-hover-markdown
            "(unsafe body)"
            "Permit unsafe operations (raw pointers, syscalls) within the body."))
        unit)
      result)))

(define (lsp-hover-respond
  [id : json_mod.Json]
  [uri : String]
  [position : json_mod.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector_mod.StringVec]) : unit
  (match (lsp-documents-lookup docs uri)
    [(FoundLspDocument path text _)
      (let
        [line0 : i64 (lsp-json-int-field-default position "line" 0)]
        [char0 : i64 (lsp-json-int-field-default position "character" 0)]
        [off : i64 (lsp-offset-at-position text line0 char0)]
        [sym : String (lsp-symbol-at-offset text off)]
        (if (string_mod.string-eq sym "")
          (lsp-write-response id json_mod.JsonNull)
          (let
            [needle : String (lsp-symbol-base sym)]
            [bind-type : String (lsp-binding-type text needle off)]
            [builtin : String (lsp-builtin-hover needle)]
            (if (not (string_mod.string-eq bind-type ""))
              (lsp-write-response
                id
                (lsp-hover-result
                  (lsp-hover-markdown
                    (string_mod.string-append
                      needle
                      (string_mod.string-append " : " bind-type))
                    "")
                  line0
                  char0
                  (string-length sym)))
              (if (not (string_mod.string-eq builtin ""))
                (lsp-write-response
                  id
                  (lsp-hover-result builtin line0 char0 (string-length sym)))
                (match (lsp-hover-resolve
                  docs
                  uri
                  path
                  text
                  stdlib-roots
                  needle)
                  [(FoundDefSource def-text form-off)
                    (lsp-write-response
                      id
                      (lsp-hover-result
                        (lsp-hover-markdown
                          (lsp-define-header def-text form-off)
                          (lsp-doc-comments-above def-text form-off))
                        line0
                        char0
                        (string-length sym)))]
                  [(MissingDefSource)
                    (match (lsp-resolve-variant
                      docs
                      uri
                      path
                      text
                      stdlib-roots
                      needle)
                      [(FoundVariant enum-name variant-form)
                        (lsp-write-response
                          id
                          (lsp-hover-result
                            (lsp-hover-markdown
                              variant-form
                              (string_mod.string-append
                                "Variant of `"
                                (string_mod.string-append enum-name "`.")))
                            line0
                            char0
                            (string-length sym)))]
                      [(MissingVariant)
                        (lsp-write-response id json_mod.JsonNull)])]))))))]
    [(MissingLspDocument) (lsp-write-response id json_mod.JsonNull)]))

(define (lsp-handle-hover
  [id : json_mod.Json]
  [params : json_mod.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector_mod.StringVec]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json_mod.json-object-get params (& td-key))
      [(json_mod.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(OkLspJsonText uri)
            (let
              [pos-key : String "position"]
              (match (json_mod.json-object-get params (& pos-key))
                [(json_mod.JsonFound position)
                  (lsp-hover-respond id uri position docs stdlib-roots)]
                [(json_mod.JsonMissing)
                  (lsp-write-response id json_mod.JsonNull)]))]
          [(MissingLspJsonText) (lsp-write-response id json_mod.JsonNull)])]
      [(json_mod.JsonMissing) (lsp-write-response id json_mod.JsonNull)])))

;; --------------------------------------------------------------------------
;; Document links (textDocument/documentLink): make (import "spec") paths
;; clickable, navigating to the resolved module file.
;; --------------------------------------------------------------------------
(define (lsp-document-link-json
  [text : String]
  [path : String]
  [stdlib-roots : vector_mod.StringVec]
  [content-start : i64]
  [content-end : i64]) : json_mod.Json
  (let
    [spec : String
      (string_mod.substring text content-start (- content-end content-start))]
    [resolved : String
      (compiler-load-normalize-path
        (compiler-load-resolve-import-with-roots path spec stdlib-roots))]
    [start-lc : LspLineCol (lsp-line-col-at-offset text content-start)]
    [end-lc : LspLineCol (lsp-line-col-at-offset text content-end)]
    (lsp-json-object2
      "range"
      (lsp-json-object2
        "start"
        (lsp-position (struct-get start-lc line) (struct-get start-lc col))
        "end"
        (lsp-position (struct-get end-lc line) (struct-get end-lc col)))
      "target"
      (json_mod.JsonString (lsp-path-to-file-uri resolved)))))

(define (lsp-document-links
  [text : String]
  [path : String]
  [stdlib-roots : vector_mod.StringVec]) : json_mod.JsonList
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [acc : json_mod.JsonList json_mod.JsonListNil]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (if (= c #;')
            (set! i (lsp-skip-line text i n))
            (if (= c ##')
              (set! i (lsp-skip-char-literal text i n))
              (if (= c #"')
                (set! i (lsp-skip-string text i n))
                (if (= c #(')
                  (let
                    [kw-start : i64 (lsp-skip-space text (+ i 1) n)]
                    [kw-end : i64 (lsp-scan-ident text kw-start n)]
                    (if (and
                      (> kw-end kw-start)
                      (string_mod.string-eq
                        (string_mod.substring text kw-start (- kw-end kw-start))
                        "import"))
                      (let
                        [q : i64 (lsp-skip-space text kw-end n)]
                        (if (and (< q n) (= (string-ref text q) #"'))
                          (let
                            [str-end : i64 (lsp-skip-string text q n)]
                            (begin
                              (set!
                                acc
                                (lsp-json-list-cons
                                  (lsp-document-link-json
                                    text
                                    path
                                    stdlib-roots
                                    (+ q 1)
                                    (- str-end 1))
                                  acc))
                              (set! i str-end)))
                          (set! i (+ i 1))))
                      (set! i (+ i 1))))
                  (set! i (+ i 1))))))))
      acc)))

(define (lsp-document-link-respond
  [id : json_mod.Json]
  [uri : String]
  [docs : LspDocuments]
  [stdlib-roots : vector_mod.StringVec]) : unit
  (match (lsp-documents-lookup docs uri)
    [(FoundLspDocument path text _)
      (lsp-write-response
        id
        (lsp-json-array (lsp-document-links text path stdlib-roots)))]
    [(MissingLspDocument)
      (lsp-write-response id (lsp-json-array json_mod.JsonListNil))]))

(define (lsp-handle-document-link
  [id : json_mod.Json]
  [params : json_mod.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector_mod.StringVec]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json_mod.json-object-get params (& td-key))
      [(json_mod.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(OkLspJsonText uri)
            (lsp-document-link-respond id uri docs stdlib-roots)]
          [(MissingLspJsonText)
            (lsp-write-response id (lsp-json-array json_mod.JsonListNil))])]
      [(json_mod.JsonMissing)
        (lsp-write-response id (lsp-json-array json_mod.JsonListNil))])))

(define (lsp-maybe-write-method-not-found [message : json_mod.Json]) : unit
  (let
    [key : String "id"]
    (match (json_mod.json-object-get message (& key))
      [(json_mod.JsonFound id) (lsp-write-error id -32601 "Method not found")]
      [(json_mod.JsonMissing) unit])))

(define (lsp-handle-message
  [message : json_mod.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector_mod.StringVec]) : LspHandleResult
  (match (lsp-json-string-field message "method")
    [(OkLspJsonText method)
      (let
        [handled : bool false]
        [result : LspHandleResult (LspContinue docs)]
        (begin
          (if (and (not handled) (string_mod.string-eq method "initialize"))
            (begin
              (set! handled true)
              (let
                [key : String "id"]
                (match (json_mod.json-object-get message (& key))
                  [(json_mod.JsonFound id)
                    (lsp-write-response id (lsp-initialize-result))]
                  [(json_mod.JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and (not handled) (string_mod.string-eq method "initialized"))
            (begin
              (set! handled true)
              (set! result (LspContinue docs)))
            unit)
          (if (and (not handled) (string_mod.string-eq method "shutdown"))
            (begin
              (set! handled true)
              (let
                [key : String "id"]
                (match (json_mod.json-object-get message (& key))
                  [(json_mod.JsonFound id)
                    (lsp-write-response id json_mod.JsonNull)]
                  [(json_mod.JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and (not handled) (string_mod.string-eq method "exit"))
            (begin
              (set! handled true)
              (set! result (LspExit docs)))
            unit)
          (if (and
            (not handled)
            (string_mod.string-eq method "textDocument/didOpen"))
            (begin
              (set! handled true)
              (let
                [key : String "params"]
                (match (json_mod.json-object-get message (& key))
                  [(json_mod.JsonFound params)
                    (set! result (lsp-did-open params docs stdlib-roots))]
                  [(json_mod.JsonMissing) (set! result (LspContinue docs))])))
            unit)
          (if (and
            (not handled)
            (string_mod.string-eq method "textDocument/didChange"))
            (begin
              (set! handled true)
              (let
                [key : String "params"]
                (match (json_mod.json-object-get message (& key))
                  [(json_mod.JsonFound params)
                    (set! result (lsp-did-change params docs stdlib-roots))]
                  [(json_mod.JsonMissing) (set! result (LspContinue docs))])))
            unit)
          (if (and
            (not handled)
            (string_mod.string-eq method "textDocument/didClose"))
            (begin
              (set! handled true)
              (let
                [key : String "params"]
                (match (json_mod.json-object-get message (& key))
                  [(json_mod.JsonFound params)
                    (set! result (lsp-did-close params docs))]
                  [(json_mod.JsonMissing) (set! result (LspContinue docs))])))
            unit)
          (if (and
            (not handled)
            (string_mod.string-eq method "textDocument/definition"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json_mod.json-object-get message (& id-key))
                  [(json_mod.JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json_mod.json-object-get message (& params-key))
                        [(json_mod.JsonFound params)
                          (lsp-handle-definition id params docs stdlib-roots)]
                        [(json_mod.JsonMissing)
                          (lsp-write-response id json_mod.JsonNull)]))]
                  [(json_mod.JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and
            (not handled)
            (string_mod.string-eq method "textDocument/completion"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json_mod.json-object-get message (& id-key))
                  [(json_mod.JsonFound id) (lsp-completion-respond id docs)]
                  [(json_mod.JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and
            (not handled)
            (string_mod.string-eq method "textDocument/inlayHint"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json_mod.json-object-get message (& id-key))
                  [(json_mod.JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json_mod.json-object-get message (& params-key))
                        [(json_mod.JsonFound params)
                          (lsp-handle-inlay id params docs stdlib-roots)]
                        [(json_mod.JsonMissing)
                          (lsp-write-response
                            id
                            (lsp-json-array json_mod.JsonListNil))]))]
                  [(json_mod.JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and
            (not handled)
            (string_mod.string-eq method "textDocument/formatting"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json_mod.json-object-get message (& id-key))
                  [(json_mod.JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json_mod.json-object-get message (& params-key))
                        [(json_mod.JsonFound params)
                          (lsp-handle-formatting id params docs)]
                        [(json_mod.JsonMissing)
                          (lsp-write-response
                            id
                            (lsp-json-array json_mod.JsonListNil))]))]
                  [(json_mod.JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and
            (not handled)
            (string_mod.string-eq method "textDocument/hover"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json_mod.json-object-get message (& id-key))
                  [(json_mod.JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json_mod.json-object-get message (& params-key))
                        [(json_mod.JsonFound params)
                          (lsp-handle-hover id params docs stdlib-roots)]
                        [(json_mod.JsonMissing)
                          (lsp-write-response id json_mod.JsonNull)]))]
                  [(json_mod.JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and
            (not handled)
            (string_mod.string-eq method "textDocument/documentLink"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json_mod.json-object-get message (& id-key))
                  [(json_mod.JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json_mod.json-object-get message (& params-key))
                        [(json_mod.JsonFound params)
                          (lsp-handle-document-link id params docs stdlib-roots)]
                        [(json_mod.JsonMissing)
                          (lsp-write-response
                            id
                            (lsp-json-array json_mod.JsonListNil))]))]
                  [(json_mod.JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (not handled)
            (begin
              (lsp-maybe-write-method-not-found message)
              (set! result (LspContinue docs)))
            unit)
          result))]
    [(MissingLspJsonText) (LspContinue docs)]))

(define (lsp-stdlib-roots-from [idx : i64] [count : i64]) : vector_mod.StringVec
  (let
    [i : i64 idx]
    [roots : vector_mod.StringVec (vector_mod.string-vec-new)]
    (begin
      (while (< i count)
        (if (string_mod.string-eq (io_mod.arg i) "--stdlib-root")
          (if (< (+ i 1) count)
            (begin
              (set!
                roots
                (vector_mod.string-vec-push roots (io_mod.arg (+ i 1))))
              (set! i (+ i 2)))
            (set! i count))
          (set! i (+ i 1))))
      roots)))

(define (lsp-stdlib-roots [idx : i64]) : vector_mod.StringVec
  (lsp-stdlib-roots-from idx (io_mod.arg-count)))

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
    [stdlib-roots : vector_mod.StringVec (lsp-stdlib-roots-from idx count)]
    (begin
      (lsp-frame-session-cache-enable!)
      (while (not done)
        (match (lsp-frame-read-message)
          [(LspFrameOk payload)
            (let
              [text : String payload]
              (match (json_mod.json-parse (& text))
                [(json_mod.OkJson message)
                  (match (lsp-handle-message message docs stdlib-roots)
                    [(LspContinue next-docs) (set! docs next-docs)]
                    [(LspExit next-docs)
                      (begin
                        (set! docs next-docs)
                        (set! done true))])]
                [(json_mod.ErrJson message) (lsp-write-parse-error message)]))]
          [(LspFrameEof) (set! done true)]
          [(LspFrameErr message)
            (begin
              (lsp-write-parse-error message)
              (lsp-frame-stderr-write message)
              (set! status 1)
              (set! done true))]))
      status)))

(define (lsp-frame-run) : i64
  (lsp-frame-run-from 1 (io_mod.arg-count)))