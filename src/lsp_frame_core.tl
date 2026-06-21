;; lsp_frame_core.tl - Main-free selfhost LSP stdio framing and JSON-RPC slice (#592/#789).
;;
;; This driver owns JSON-RPC/LSP Content-Length framing over stdin/stdout plus
;; the first selfhost protocol loop: initialize/shutdown, document tracking, and
;; diagnostics for full-document open/change notifications.
(import "../stdlib/fs.tl")
(import "../stdlib/json.tl")
(import "compiler_check_core.tl")
(import "compiler_load.tl")
(import "format_rules.tl")
(import "lint_driver_core.tl")
(import "lsp_vector_families.tl")
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

(defenum LspEditResult
  (OkLspEdit String)
  (ErrLspEdit String))

(defenum LspFunctionList
  (OkLspFunctionList (Array String))
  (ErrLspFunctionList String))

(defenum LspValidationResult
  (ValidLspForms)
  (InvalidLspForms i64 i64 String String))

(define (lsp-frame-space? [c : char]) : bool
  (or (= c ' ') (= c '\t')))

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
            (if (or (lsp-frame-space? c) (= c '\r'))
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
  (and (>= c '0') (<= c '9')))

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
        [clean-eof LspFrameEof]
        [(not (string-eq err "")) (LspFrameErr err)]
        [(< content-length 0) (LspFrameErr "lsp: missing Content-Length")]
        [else
          (let
            [payload-read : StdinRead (stdin-read-bytes content-length)]
            [payload : String (stdin-read-text payload-read)]
            (if (and
              (stdin-read-eof? payload-read)
              (< (string-length payload) content-length))
              (LspFrameErr "lsp: truncated payload")
              (LspFrameOk payload)))]))))

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
    (lsp-json-object
      (lsp-json-member
        "textDocumentSync"
        (lsp-json-object2
          "openClose"
          (JsonBool true)
          "change"
          (lsp-json-number 1))
        (lsp-json-member
          "definitionProvider"
          (JsonBool true)
          (lsp-json-member
            "completionProvider"
            (lsp-json-object1 "resolveProvider" (JsonBool false))
            (lsp-json-member
              "inlayHintProvider"
              (JsonBool true)
              (lsp-json-member
                "documentFormattingProvider"
                (JsonBool true)
                (lsp-json-member
                  "hoverProvider"
                  (JsonBool true)
                  (lsp-json-member
                    "documentLinkProvider"
                    (lsp-json-object1 "resolveProvider" (JsonBool false))
                    JsonMemberListNil))))))))
    "serverInfo"
    (lsp-json-object2
      "name"
      (JsonString "typelisp")
      "version"
      (JsonString "selfhost"))))

(define (lsp-document-fallback) : LspDocument
  (LspDocument "" "" "" ""))

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
            [doc : LspDocument
              (lsp-documents-get docs i (lsp-document-fallback))]
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
      (lsp-documents-set! docs index doc)
      (lsp-documents-push docs doc))))

(define (lsp-documents-shift-left! [docs : LspDocuments] [index : i64]) : unit
  (let
    [i : i64 index]
    [last : i64 (- (lsp-documents-len docs) 1)]
    (begin
      (while (< i last)
        (begin
          (lsp-documents-set!
            docs
            i
            (lsp-documents-get docs (+ i 1) (lsp-document-fallback)))
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
        [doc : LspDocument
          (lsp-documents-get docs index (lsp-document-fallback))]
        (FoundLspDocument
          (struct-get doc path)
          (struct-get doc text)
          (struct-get doc diagnostic-uri)))
      MissingLspDocument)))

(define (lsp-hex-value [c : char]) : i64
  (let
    [code : i64 (cast c : i64)]
    (cond
      [(and (>= code 48) (<= code 57)) (- code 48)]
      [(and (>= code 65) (<= code 70)) (+ 10 (- code 65))]
      [(and (>= code 97) (<= code 102)) (+ 10 (- code 97))]
      [else -1])))

(define (lsp-percent-decode [text : String]) : LspStringResult
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [out : String ""]
    [err : String ""]
    (begin
      (while (< i n)
        (if (string-eq err "")
          (if (= (string-ref text i) '%')
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
    (if (and (> n 2) (= (string-ref path 0) '/') (= (string-ref path 2) ':'))
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
  (if (and (> (string-length path) 0) (= (string-ref path 0) '/'))
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

(define (lsp-range-from-compiler-span [span : CompilerDiagnosticSpan]) : Json
  (let
    [start-line : i64 (compiler-diagnostic-span-start-line span)]
    [start-col : i64 (compiler-diagnostic-span-start-col span)]
    [raw-end-line : i64 (compiler-diagnostic-span-end-line span)]
    [safe-end-line : i64
      (if (>= raw-end-line start-line)
        raw-end-line
        start-line)]
    [raw-end-col : i64 (compiler-diagnostic-span-end-col span)]
    [safe-end-col : i64
      (if (and (= start-line safe-end-line) (<= raw-end-col start-col))
        (+ start-col 1)
        raw-end-col)]
    (lsp-json-object2
      "start"
      (lsp-position start-line start-col)
      "end"
      (lsp-position safe-end-line safe-end-col))))

(define (lsp-diagnostic-related-uri
  [fallback-path : String]
  [span : CompilerDiagnosticSpan]) : String
  (let
    [path : String (compiler-diagnostic-span-path span)]
    (lsp-path-to-file-uri
      (if (string-eq path "")
        fallback-path
        path))))

(define (lsp-diagnostic-related-message [label : CompilerDiagnosticMaybeString]) : String
  (match label
    [(CompilerDiagnosticSomeString text) text]
    [CompilerDiagnosticNoString "related location"]))

(define (lsp-diagnostic-related-information
  [fallback-path : String]
  [entry : CompilerDiagnosticLabel]) : Json
  (let
    [span : CompilerDiagnosticSpan (struct-get entry span)]
    (lsp-json-object2
      "location"
      (lsp-json-object2
        "uri"
        (JsonString (lsp-diagnostic-related-uri fallback-path span))
        "range"
        (lsp-range-from-compiler-span span))
      "message"
      (JsonString (lsp-diagnostic-related-message (struct-get entry label))))))

(define (lsp-diagnostic-related-information-list
  [fallback-path : String]
  [labels : CompilerDiagnosticLabelList]) : JsonList
  (match labels
    [(CompilerDiagnosticLabelNil) JsonListNil]
    [(CompilerDiagnosticLabelCons entry rest)
      (lsp-json-list-cons
        (lsp-diagnostic-related-information fallback-path entry)
        (lsp-diagnostic-related-information-list fallback-path (box-get rest)))]))

(define (lsp-diagnostic-message-tail [message : String]) : JsonMemberList
  (lsp-json-member "message" (JsonString message) JsonMemberListNil))

(define (lsp-diagnostic-code-tail [code : String] [tail : JsonMemberList]) : JsonMemberList
  (if (string-eq code "")
    tail
    (lsp-json-member "code" (JsonString code) tail)))

(define (lsp-diagnostic-with-range-tail
  [range : Json]
  [code : String]
  [tail : JsonMemberList]) : Json
  (lsp-json-object
    (lsp-json-member
      "range"
      range
      (lsp-json-member
        "severity"
        (lsp-json-number 1)
        (lsp-json-member
          "source"
          (JsonString "typelisp")
          (lsp-diagnostic-code-tail code tail))))))

(define (lsp-diagnostic-with-range
  [range : Json]
  [message : String]
  [code : String]) : Json
  (lsp-diagnostic-with-range-tail
    range
    code
    (lsp-diagnostic-message-tail message)))

(define (lsp-diagnostic
  [line : i64]
  [col : i64]
  [message : String]
  [code : String]) : Json
  (lsp-diagnostic-with-range (lsp-range line col) message code))

(define (lsp-compiler-diagnostic [diag : CompilerDiagnostic]) : Json
  (let
    [span : CompilerDiagnosticSpan (compiler-diagnostic-primary-span diag)]
    [path : String (compiler-diagnostic-span-path span)]
    [labels : CompilerDiagnosticLabelList
      (compiler-diagnostic-secondary-spans diag)]
    [range : Json (lsp-range-from-compiler-span span)]
    [message : String (compiler-diagnostic-message diag)]
    [code : String (compiler-diagnostic-code-or-empty diag)]
    (match labels
      [(CompilerDiagnosticLabelNil)
        (lsp-diagnostic-with-range range message code)]
      [(CompilerDiagnosticLabelCons _ _)
        (lsp-diagnostic-with-range-tail
          range
          code
          (lsp-json-member
            "relatedInformation"
            (lsp-json-array
              (lsp-diagnostic-related-information-list path labels))
            (lsp-diagnostic-message-tail message)))])))

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

(cfg
  test
  (define (lsp-compiler-diagnostic-related-ok?) : bool
    (let
      [diag : CompilerDiagnostic
        (compiler-diagnostic-with-secondary
          (compiler-diagnostic-with-code
            (compiler-diagnostic-from-span
              "primary.tl"
              (SourceSpan 2 3 2 9)
              "wide primary")
            "E7777")
          (CompilerDiagnosticSpan "" 4 5 4 8)
          (CompilerDiagnosticSomeString "borrow remains live"))]
      [rendered : String (json-stringify (lsp-compiler-diagnostic diag))]
      [related-key : String "\"relatedInformation\""]
      [related-message : String "\"message\":\"borrow remains live\""]
      [related-uri : String "\"uri\":\"file:///primary.tl\""]
      [primary-line : String "\"line\":1"]
      [primary-end : String "\"character\":8"]
      [secondary-line : String "\"line\":3"]
      [secondary-end : String "\"character\":7"]
      (and
        (string-contains (& rendered) (& related-key))
        (string-contains (& rendered) (& related-message))
        (string-contains (& rendered) (& related-uri))
        (string-contains (& rendered) (& primary-line))
        (string-contains (& rendered) (& primary-end))
        (string-contains (& rendered) (& secondary-line))
        (string-contains (& rendered) (& secondary-end))))))

(define (lsp-validate-forms-smoke-ok?) : bool
  (let
    [valid1 : bool (lsp-text-is-valid-forms "(define (foo) : i64 1)")]
    [valid2 : bool
      (lsp-text-is-valid-forms "(define (foo) : i64 1)\n(define (bar) : i64 2)")]
    [err1 : String (lsp-validate-forms-error "(define (foo) : i64 1")]
    [needle : String "unterminated"]
    (and
      valid1
      valid2
      (not (string-eq err1 ""))
      (string-contains (& err1) (& needle)))))

(define (lsp-validate-forms-line-context-ok?) : bool
  (match (lsp-validate-forms-result "(let [x : badtype] 1)")
    [(ValidLspForms) false]
    [(InvalidLspForms line col msg ctx)
      (and
        (= line 1)
        (= col 1)
        (not (string-eq msg ""))
        (not (string-eq ctx "")))]))

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
      (cfg test (unless (lsp-compiler-diagnostic-related-ok?) (return 4)) unit)
      (unless (lsp-frame-session-cache-smoke-ok?) (return 5))
      (unless (lsp-definition-smoke-ok?) (return 6))
      (cfg test (unless (lsp-validate-forms-smoke-ok?) (return 7)) unit)
      (cfg test (unless (lsp-validate-forms-line-context-ok?) (return 8)) unit)
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
  [code : String]) : Json
  (lsp-json-object
    (lsp-json-member
      "range"
      (lsp-range line col)
      (lsp-json-member
        "severity"
        (lsp-json-number 2)
        (lsp-json-member
          "source"
          (JsonString "typelisp-lint")
          (lsp-json-member
            "code"
            (JsonString code)
            (lsp-json-member "message" (JsonString message) JsonMemberListNil)))))))

(define (lsp-lint-finding-diagnostic [finding : LintFinding]) : Json
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
  [acc : JsonList]) : JsonList
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
  [stdlib-roots : StringVec]) : JsonList
  (lsp-lint-findings-to-json
    text
    (selfhost-lint-source-with-roots path text stdlib-roots)
    0
    JsonListNil))

(define (lsp-analyze-document
  [uri : String]
  [path : String]
  [text : String]
  [stdlib-roots : StringVec]) : String
  (let
    [lint-diags : JsonList (lsp-lint-diagnostics path text stdlib-roots)]
    (match (compiler-check-source-with-roots path text stdlib-roots)
      [(OkCompilerCheck _)
        (begin
          (lsp-publish-diagnostics uri lint-diags)
          "")]
      [(ErrCompilerCheck diag)
        (let
          [diag-uri : String (lsp-diagnostic-uri uri path diag)]
          (if (string-eq diag-uri uri)
            (begin
              (lsp-publish-diagnostics
                uri
                (lsp-json-list-cons (lsp-compiler-diagnostic diag) lint-diags))
              uri)
            (begin
              (lsp-publish-diagnostics uri lint-diags)
              (lsp-publish-diagnostics
                diag-uri
                (lsp-json-list-cons (lsp-compiler-diagnostic diag) JsonListNil))
              diag-uri)))])))

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
    (and (>= c 'a') (<= c 'z'))
    (and (>= c 'A') (<= c 'Z'))
    (and (>= c '0') (<= c '9'))
    (= c '-')
    (= c '+')
    (= c '*')
    (= c '/')
    (= c '?')
    (= c '!')
    (= c '>')
    (= c '<')
    (= c '=')
    (= c '&')
    (= c ':')
    (= c '_')
    (= c '.')
    (= c '%')))

(define (lsp-ws? [c : char]) : bool
  (or (= c ' ') (= c '\t') (= c '\n') (= c '\r')))

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
      (while (and (< j n) (not (= (string-ref text j) '\n')))
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
          (if (= c '\\')
            (set! j (+ j 2))
            (if (= c '"')
              (begin
                (set! done true)
                (set! j (+ j 1)))
              (set! j (+ j 1))))))
      j)))

(define (lsp-apostrophe-char-escape? [c : char]) : bool
  (or (= c 'n') (= c 't') (= c 'r') (= c '0') (= c '\\') (= c '\'')))

(define (lsp-skip-apostrophe-char-literal [text : String] [i : i64] [n : i64]) : i64
  (if (< (+ i 1) n)
    (let
      [payload : char (string-ref text (+ i 1))]
      (cond
        [(= payload '\\')
          (if (and
            (< (+ i 3) n)
            (lsp-apostrophe-char-escape? (string-ref text (+ i 2)))
            (= (string-ref text (+ i 3)) '\''))
            (+ i 4)
            (+ i 1))]
        [(or (= payload '\'') (= payload '\n') (= payload '\r')) (+ i 1)]
        [else
          (if (and (< (+ i 2) n) (= (string-ref text (+ i 2)) '\''))
            (+ i 3)
            (+ i 1))]))
    (+ i 1)))

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
          (if (or (= (string-ref s i) '/') (= (string-ref s i) '.'))
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
          (if (= (string-ref text i) '\n')
            (set! ln (+ ln 1))
            unit)
          (set! i (+ i 1))))
      (while (and (< i n) (< col char0) (not (= (string-ref text i) '\n')))
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
          (if (= (string-ref text i) '\n')
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
              (if (and (< after-kw n) (= (string-ref text after-kw) '('))
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
            [(= c ';') (set! i (lsp-skip-line text i n))]
            [(= c '\'') (set! i (lsp-skip-apostrophe-char-literal text i n))]
            [(= c '"') (set! i (lsp-skip-string text i n))]
            [(= c '(')
              (let
                [name-off : i64 (lsp-def-name-offset-at text i n)]
                (if (>= name-off 0)
                  (if (string-eq (lsp-symbol-at-offset text name-off) needle)
                    (set! found name-off)
                    (set! i (+ i 1)))
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
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
          (if (= c '"')
            (set! i (lsp-skip-string text i end))
            (if (= c '(')
              (let
                [vs : i64 (lsp-skip-space text (+ i 1) end)]
                [ve : i64 (lsp-scan-ident text vs end)]
                (if (string-eq (substring text vs (- ve vs)) needle)
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
          (cond
            [(= c ';') (set! i (lsp-skip-line text i n))]
            [(= c '\'') (set! i (lsp-skip-apostrophe-char-literal text i n))]
            [(= c '"') (set! i (lsp-skip-string text i n))]
            [(= c '(')
              (let
                [kw-start : i64 (lsp-skip-space text (+ i 1) n)]
                [kw-end : i64 (lsp-scan-ident text kw-start n)]
                (if (string-eq
                  (substring text kw-start (- kw-end kw-start))
                  "defenum")
                  (let
                    [name-end : i64
                      (lsp-scan-ident text (lsp-skip-space text kw-end n) n)]
                    [form-end : i64 (lsp-skip-paren-group text i n)]
                    [voff : i64
                      (lsp-variant-name-offset-in text name-end form-end needle)]
                    (if (>= voff 0)
                      (set! result voff)
                      (set! i form-end)))
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
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
      [doc : LspDocument (lsp-documents-get docs idx (lsp-document-fallback))]
      (if (string-eq (struct-get doc uri) current-uri)
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
(define (lsp-collect-imports [text : String] [acc : StringVec]) : StringVec
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [out : StringVec acc]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (cond
            [(= c ';') (set! i (lsp-skip-line text i n))]
            [(= c '"') (set! i (lsp-skip-string text i n))]
            [(= c '(')
              (let
                [kw-start : i64 (lsp-skip-space text (+ i 1) n)]
                [kw-end : i64 (lsp-scan-ident text kw-start n)]
                (if (and
                  (> kw-end kw-start)
                  (string-eq
                    (substring text kw-start (- kw-end kw-start))
                    "import"))
                  (let
                    [q : i64 (lsp-skip-space text kw-end n)]
                    (if (and (< q n) (= (string-ref text q) '"'))
                      (let
                        [str-end : i64 (lsp-skip-string text q n)]
                        (begin
                          (set!
                            out
                            (string-vec-push
                              out
                              (substring text (+ q 1) (- str-end (+ q 2)))))
                          (set! i str-end)))
                      (set! i (+ i 1))))
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
      out)))

(defstruct LspModuleSet
  (paths StringVec)
  (texts StringVec))

(define (lsp-string-vec-contains? [v : StringVec] [s : String]) : bool
  (let
    [n : i64 (string-vec-len v)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (if (string-eq (string-vec-get v i "") s)
          (set! found true)
          (set! i (+ i 1))))
      found)))

;; Add a resolved module path (and its source) to the set if new and under cap.
(define (lsp-module-set-add-path [set : LspModuleSet] [resolved : String]) : LspModuleSet
  (let
    [paths : StringVec (struct-get set paths)]
    [texts : StringVec (struct-get set texts)]
    (if (and
      (< (string-vec-len paths) 512)
      (not (lsp-string-vec-contains? paths resolved)))
      (LspModuleSet
        (string-vec-push paths resolved)
        (string-vec-push texts (read-file-or (& resolved) "")))
      set)))

;; Add every module `text` imports (resolved like the loader) to the set.
(define (lsp-module-set-add-imports
  [importer-path : String]
  [text : String]
  [stdlib-roots : StringVec]
  [set : LspModuleSet]) : LspModuleSet
  (let
    [specs : StringVec (lsp-collect-imports text (string-vec-new))]
    [out : LspModuleSet set]
    [j : i64 0]
    (begin
      (while (< j (string-vec-len specs))
        (begin
          (set!
            out
            (lsp-module-set-add-path
              out
              (compiler-load-normalize-path
                (compiler-load-resolve-import-with-roots
                  importer-path
                  (string-vec-get specs j "")
                  stdlib-roots))))
          (set! j (+ j 1))))
      out)))

;; Every module transitively reachable from the document (plus the core
;; prelude), each read once. Shared by go-to-definition and hover.
(define (lsp-transitive-modules
  [start-path : String]
  [start-text : String]
  [stdlib-roots : StringVec]) : LspModuleSet
  (let
    [seeded : LspModuleSet
      (lsp-module-set-add-path
        (LspModuleSet (string-vec-new) (string-vec-new))
        (compiler-load-normalize-path
          (compiler-load-resolve-import-with-roots
            start-path
            "stdlib/core_macros.tl"
            stdlib-roots)))]
    [set : LspModuleSet
      (lsp-module-set-add-imports start-path start-text stdlib-roots seeded)]
    [i : i64 0]
    (begin
      (while (< i (string-vec-len (struct-get set paths)))
        (let
          [src : String (string-vec-get (struct-get set texts) i "")]
          (begin
            (if (string-eq src "")
              unit
              (set!
                set
                (lsp-module-set-add-imports
                  (string-vec-get (struct-get set paths) i "")
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
  (if (>= idx (string-vec-len (struct-get set paths)))
    MissingDefLoc
    (let
      [src : String (string-vec-get (struct-get set texts) idx "")]
      [off : i64 (lsp-find-def-or-variant-offset-in src needle)]
      (if (>= off 0)
        (lsp-def-loc-from
          (lsp-path-to-file-uri (string-vec-get (struct-get set paths) idx ""))
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
  [stdlib-roots : StringVec]
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
  [docs : LspDocuments]
  [stdlib-roots : StringVec]) : unit
  (match (lsp-documents-lookup docs uri)
    [(FoundLspDocument path text _)
      (let
        [line0 : i64 (lsp-json-int-field-default position "line" 0)]
        [char0 : i64 (lsp-json-int-field-default position "character" 0)]
        [off : i64 (lsp-offset-at-position text line0 char0)]
        [sym : String (lsp-symbol-at-offset text off)]
        (if (string-eq sym "")
          (lsp-write-response id JsonNull)
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
            [(MissingDefLoc) (lsp-write-response id JsonNull)])))]
    [(MissingLspDocument) (lsp-write-response id JsonNull)]))

(define (lsp-handle-definition
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
              [pos-key : String "position"]
              (match (json-object-get params (& pos-key))
                [(JsonFound position)
                  (lsp-definition-respond id uri position docs stdlib-roots)]
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
        "smoke.tl"
        src
        (string-vec-new)
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
      (string-vec-new)
      "decoy")
      [(FoundDefLoc _ _ _ _) false]
      [(MissingDefLoc) true])))

(define (lsp-definition-smoke-skips-char-literals?) : bool
  (let
    [src : String
      "(define (quote-char) : char '\"')\n(define (apostrophe-quote-char) : char '\"')\n(define (target) : i64 1)\n(define (use) : i64 (target))\n"]
    (match (lsp-find-definition
      (lsp-documents-new)
      "file:///smoke.tl"
      "smoke.tl"
      src
      (string-vec-new)
      "target")
      [(FoundDefLoc _ line col len) (and (= line 3) (= col 10) (= len 6))]
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
  "define lambda let if begin while set! return match foreach cond when unless and or with-arena with-escape with-scratch try unsafe quote quasiquote unquote ann init cast type defstruct defenum defmacro defdispatch import export extern module comptime comptime-decl comptime-decls include-str include-bin test spmd-reduce spmd-scan spmd-broadcast program-index program-count")

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
          (if (= (string-ref s i) ' ')
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
            [(= c ';') (set! i (lsp-skip-line text i n))]
            [(= c '"') (set! i (lsp-skip-string text i n))]
            [(= c '(')
              (let
                [name-off : i64 (lsp-def-name-offset-at text i n)]
                (begin
                  (if (>= name-off 0)
                    (set!
                      out
                      (string-vec-push out (lsp-symbol-at-offset text name-off)))
                    unit)
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
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
        (struct-get (lsp-documents-get docs idx (lsp-document-fallback)) text)
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
            (and (>= p 0) (= (string-ref text p) '['))))))))

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

;; --------------------------------------------------------------------------
;; Document formatting (textDocument/formatting), enabling format-on-save.
;;
;; Reuses the `typelisp fmt` formatter (format-rules, width 80). On a parse
;; error the document is left untouched (empty edit list) so saving never
;; mangles in-progress code.
;; --------------------------------------------------------------------------
(define (lsp-formatting-edit [text : String] [formatted : String]) : Json
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
      (JsonString formatted))))

(define (lsp-formatting-respond
  [id : Json]
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
                JsonListNil)))]
        [(ErrFormatString _)
          (lsp-write-response id (lsp-json-array JsonListNil))])]
    [(MissingLspDocument) (lsp-write-response id (lsp-json-array JsonListNil))]))

(define (lsp-handle-formatting
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json-object-get params (& td-key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(OkLspJsonText uri) (lsp-formatting-respond id uri docs)]
          [(MissingLspJsonText)
            (lsp-write-response id (lsp-json-array JsonListNil))])]
      [(JsonMissing) (lsp-write-response id (lsp-json-array JsonListNil))])))

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
          (cond
            [(= c ';') (set! j (lsp-skip-line text j n))]
            [(= c '\'') (set! j (lsp-skip-apostrophe-char-literal text j n))]
            [(= c '"') (set! j (lsp-skip-string text j n))]
            [(= c '(')
              (begin
                (set! depth (+ depth 1))
                (set! j (+ j 1)))]
            [(= c ')')
              (begin
                (set! depth (- depth 1))
                (set! j (+ j 1))
                (if (<= depth 0)
                  (set! done true)
                  unit))]
            [else (set! j (+ j 1))])))
      j)))

;; End offset of one type expression (a ( ... ) group or a single token).
(define (lsp-scan-type [text : String] [i : i64] [n : i64]) : i64
  (if (and (< i n) (= (string-ref text i) '('))
    (lsp-skip-paren-group text i n)
    (lsp-scan-ident text i n)))

;; Validate that text is a single complete parenthesized form with no trailing content.
;; Returns true if text is non-empty, starts with '(' (after whitespace), and has a
;; matching closing ')'.
(define (lsp-text-is-valid-form [text : String]) : bool
  (let
    [n : i64 (string-length text)]
    (if (= n 0)
      false
      (let
        [start : i64 (lsp-skip-space text 0 n)]
        (if (or (>= start n) (not (= (string-ref text start) '(')))
          false
          (let
            [j : i64 start]
            [depth : i64 0]
            [done : bool false]
            (begin
              (while (and (< j n) (not done))
                (let
                  [c : char (string-ref text j)]
                  (cond
                    [(= c ';') (set! j (lsp-skip-line text j n))]
                    [(= c '\'')
                      (set! j (lsp-skip-apostrophe-char-literal text j n))]
                    [(= c '"') (set! j (lsp-skip-string text j n))]
                    [(= c '(')
                      (begin
                        (set! depth (+ depth 1))
                        (set! j (+ j 1)))]
                    [(= c ')')
                      (begin
                        (set! depth (- depth 1))
                        (set! j (+ j 1))
                        (if (<= depth 0)
                          (set! done true)
                          unit))]
                    [else (set! j (+ j 1))])))
              (if done
                (= (lsp-skip-space text j n) n)
                false))))))))

;; Validate that text contains one or more complete parenthesized forms.
;; Returns true if all non-whitespace content consists of valid forms.
;; Now uses the real compiler parser for accurate error reporting.
(define (lsp-text-is-valid-forms [text : String]) : bool
  (let
    [n : i64 (string-length text)]
    [i : i64 (lsp-skip-space text 0 n)]
    (if (= i n)
      false
      (match (lsp-validate-forms-result text)
        [(ValidLspForms) true]
        [(InvalidLspForms _ _ _ _) false]))))

;; Return a formatted error message, or empty string if valid.
(define (lsp-validate-forms-error [text : String]) : String
  (match (lsp-validate-forms-result text)
    [(ValidLspForms) ""]
    [(InvalidLspForms line col msg ctx)
      (str-cat
        msg
        " at line "
        (int->string line)
        ", col "
        (int->string col)
        " | "
        ctx)]))

;; Extract the line at position (1-based line)
(define (lsp-line-at [text : String] [line1 : i64]) : String
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [current-line : i64 1]
    [start : i64 0]
    [done : bool false]
    (begin
      (while (and (< i n) (not done))
        (if (= current-line line1)
          (if (or (= i n) (= (string-ref text i) '\n'))
            (set! done true)
            (set! i (+ i 1)))
          (begin
            (if (= (string-ref text i) '\n')
              (set! current-line (+ current-line 1))
              unit)
            (set! i (+ i 1))
            (set! start i))))
      (if (= current-line line1)
        (substring text start (- i start))
        ""))))

;; Validate forms using real parser. Returns ValidLspForms on success,
;; or InvalidLspForms with line, col, message, and context on failure.
(define (lsp-validate-forms-result [text : String]) : LspValidationResult
  (match (lex-spanned-result text)
    [(ErrSpannedTokens err)
      (let
        [span : SourceSpan (source-error-span err)]
        [line : i64 (span-start-line span)]
        [col : i64 (span-start-col span)]
        [msg : String (source-error-message err)]
        (InvalidLspForms line col msg (lsp-line-at text line)))]
    [(OkSpannedTokens toks)
      (let
        [cur : (Array i64) (make-array i64 1)]
        [dispatch : SymI64Env (compiler-parse-dispatch-env)]
        [done : bool false]
        [result : LspValidationResult ValidLspForms]
        (begin
          (array-set! cur 0 0)
          (while (and
            (not done)
            (not (= (peek-spanned-tag toks cur) (tag-end))))
            (match (read-form-spanned-result toks cur)
              [(ErrSpannedSexpr err)
                (let
                  [span : SourceSpan (source-error-span err)]
                  [line : i64 (span-start-line span)]
                  [col : i64 (span-start-col span)]
                  [msg : String (source-error-message err)]
                  (begin
                    (set!
                      result
                      (InvalidLspForms line col msg (lsp-line-at text line)))
                    (set! done true)))]
              [(OkSpannedSexpr sexpr)
                (match (parse-ast-decl-maybe dispatch sexpr)
                  [(ErrAstMaybeDecl msg)
                    (match (parse-ast-expr dispatch sexpr)
                      [(ErrAstExpr _)
                        (let
                          [span : SourceSpan (spanned-sexpr-span sexpr)]
                          [line : i64 (span-start-line span)]
                          [col : i64 (span-start-col span)]
                          (begin
                            (set!
                              result
                              (InvalidLspForms
                                line
                                col
                                msg
                                (lsp-line-at text line)))
                            (set! done true)))]
                      [(OkAstExpr _) unit])]
                  [(OkAstNoDecl)
                    (match (parse-ast-expr dispatch sexpr)
                      [(ErrAstExpr msg)
                        (let
                          [span : SourceSpan (spanned-sexpr-span sexpr)]
                          [line : i64 (span-start-line span)]
                          [col : i64 (span-start-col span)]
                          (begin
                            (set!
                              result
                              (InvalidLspForms
                                line
                                col
                                msg
                                (lsp-line-at text line)))
                            (set! done true)))]
                      [(OkAstExpr _) unit])]
                  [(OkAstSomeDecl _) unit]
                  [(OkAstDecls _) unit])]))
          result))]))

;; Find the byte offset where the body of a define/defmacro begins,
;; given the offset of the opening '(' of the form.
(define (lsp-find-body-start-offset [text : String] [form-start : i64]) : i64
  (let
    [n : i64 (string-length text)]
    [i : i64 form-start]
    (begin
      ; skip '('
      (set! i (+ i 1))
      ; skip keyword (define / defmacro)
      (set! i (lsp-scan-ident text i n))
      ; skip whitespace
      (set! i (lsp-skip-space text i n))
      ; skip param list '(...)'
      (set! i (lsp-skip-paren-group text i n))
      ; skip whitespace
      (set! i (lsp-skip-space text i n))
      ; if type annotation ': type', skip it
      (if (and (< i n) (= (string-ref text i) ':'))
        (begin
          (set! i (+ i 1))
          ; skip ':'
          (set! i (lsp-skip-space text i n))
          (set! i (lsp-scan-type text i n))
          (set! i (lsp-skip-space text i n)))
        unit)
      i)))

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
          (cond
            [(= c ';') (set! i (lsp-skip-line text i n))]
            [(= c '\'') (set! i (lsp-skip-apostrophe-char-literal text i n))]
            [(= c '"') (set! i (lsp-skip-string text i n))]
            [(= c '[')
              (let
                [name-start : i64 (lsp-skip-space text (+ i 1) n)]
                [name-end : i64 (lsp-scan-ident text name-start n)]
                (begin
                  (if (and
                    (> name-end name-start)
                    (<= name-start limit)
                    (string-eq
                      (substring text name-start (- name-end name-start))
                      sym))
                    (let
                      [after : i64 (lsp-skip-space text name-end n)]
                      (if (and (< after n) (= (string-ref text after) ':'))
                        (let
                          [ty-start : i64 (lsp-skip-space text (+ after 1) n)]
                          [ty-end : i64 (lsp-scan-type text ty-start n)]
                          (set!
                            result
                            (substring text ty-start (- ty-end ty-start))))
                        unit))
                    unit)
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
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
          (cond
            [(= c ';') (set! i (lsp-skip-line text i n))]
            [(= c '\'') (set! i (lsp-skip-apostrophe-char-literal text i n))]
            [(= c '"') (set! i (lsp-skip-string text i n))]
            [(= c '(')
              (let
                [name-off : i64 (lsp-def-name-offset-at text i n)]
                (if (>= name-off 0)
                  (if (string-eq (lsp-symbol-at-offset text name-off) needle)
                    (set! found i)
                    (set! i (+ i 1)))
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
      found)))

(define (lsp-hover-resolve-in-docs
  [docs : LspDocuments]
  [current-uri : String]
  [needle : String]
  [idx : i64]) : LspDefSource
  (if (>= idx (lsp-documents-len docs))
    MissingDefSource
    (let
      [doc : LspDocument (lsp-documents-get docs idx (lsp-document-fallback))]
      (if (string-eq (struct-get doc uri) current-uri)
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
  (if (>= idx (string-vec-len (struct-get set paths)))
    MissingDefSource
    (let
      [src : String (string-vec-get (struct-get set texts) idx "")]
      [off : i64 (lsp-find-def-form-in src needle)]
      (if (>= off 0)
        (FoundDefSource src off)
        (lsp-hover-resolve-in-modules set needle (+ idx 1))))))

(define (lsp-hover-resolve
  [docs : LspDocuments]
  [current-uri : String]
  [current-path : String]
  [current-text : String]
  [stdlib-roots : StringVec]
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
    [kw : String (substring text after-open (- kw-end after-open))]
    (if (or (string-eq kw "defenum") (string-eq kw "defstruct"))
      ;; Enums/structs have no (params) : ret; show the whole form (variants
      ;; or fields), so multi-line definitions render in full.
      (substring
        text
        form-off
        (- (lsp-skip-paren-group text form-off n) form-off))
      (let
        [j : i64 (lsp-skip-space text kw-end n)]
        (begin
          (if (and (< j n) (= (string-ref text j) '('))
            (set! j (lsp-skip-paren-group text j n))
            (set! j (lsp-scan-ident text j n)))
          (let
            [k : i64 (lsp-skip-space text j n)]
            (if (and (< k n) (= (string-ref text k) ':'))
              (set! j (lsp-scan-type text (lsp-skip-space text (+ k 1) n) n))
              unit))
          (substring text form-off (- j form-off)))))))

;; Start index of the line containing `pos`.
(define (lsp-line-start-before [text : String] [pos : i64]) : i64
  (let
    [i : i64 pos]
    (begin
      (while (and (> i 0) (not (= (string-ref text (- i 1)) '\n')))
        (set! i (- i 1)))
      i)))

;; True when the line at `line-start` is a ;: or ;# documentation comment.
(define (lsp-doc-comment-line? [text : String] [line-start : i64] [n : i64]) : bool
  (let
    [i : i64 line-start]
    (begin
      (while (and
        (< i n)
        (or (= (string-ref text i) ' ') (= (string-ref text i) '\t')))
        (set! i (+ i 1)))
      (and
        (< (+ i 1) n)
        (= (string-ref text i) ';')
        (or (= (string-ref text (+ i 1)) ':') (= (string-ref text (+ i 1)) '#'))))))

;; Text of a ;: / ;# doc-comment line (prefix and one space stripped).
(define (lsp-doc-comment-text [text : String] [line-start : i64] [n : i64]) : String
  (let
    [i : i64 line-start]
    (begin
      (while (and
        (< i n)
        (or (= (string-ref text i) ' ') (= (string-ref text i) '\t')))
        (set! i (+ i 1)))
      (set! i (+ i 2))
      (if (and (< i n) (= (string-ref text i) ' '))
        (set! i (+ i 1))
        unit)
      (let
        [end : i64 i]
        (begin
          (while (and (< end n) (not (= (string-ref text end) '\n')))
            (set! end (+ end 1)))
          (substring text i (- end i)))))))

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
                (string-append
                  (lsp-doc-comment-text text prev-line-start n)
                  (string-append "\n" acc)))
              (set! line-start prev-line-start))
            (set! done true))))
      acc)))

(define (lsp-hover-markdown [body : String] [docs : String]) : String
  (if (string-eq docs "")
    (string-append "```typelisp\n" (string-append body "\n```"))
    (string-append
      "```typelisp\n"
      (string-append body (string-append "\n```\n\n" docs)))))

(define (lsp-hover-result
  [markdown : String]
  [line : i64]
  [col : i64]
  [len : i64]) : Json
  (lsp-json-object2
    "contents"
    (lsp-json-object2
      "kind"
      (JsonString "markdown")
      "value"
      (JsonString markdown))
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
      (while (and (< i end) (string-eq result ""))
        (let
          [c : char (string-ref text i)]
          (if (= c '"')
            (set! i (lsp-skip-string text i end))
            (if (= c '(')
              (let
                [vs : i64 (lsp-skip-space text (+ i 1) end)]
                [ve : i64 (lsp-scan-ident text vs end)]
                (if (string-eq (substring text vs (- ve vs)) needle)
                  (set!
                    result
                    (substring text i (- (lsp-skip-paren-group text i end) i)))
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
          (cond
            [(= c ';') (set! i (lsp-skip-line text i n))]
            [(= c '\'') (set! i (lsp-skip-apostrophe-char-literal text i n))]
            [(= c '"') (set! i (lsp-skip-string text i n))]
            [(= c '(')
              (let
                [kw-start : i64 (lsp-skip-space text (+ i 1) n)]
                [kw-end : i64 (lsp-scan-ident text kw-start n)]
                (if (string-eq
                  (substring text kw-start (- kw-end kw-start))
                  "defenum")
                  (let
                    [name-start : i64 (lsp-skip-space text kw-end n)]
                    [name-end : i64 (lsp-scan-ident text name-start n)]
                    [form-end : i64 (lsp-skip-paren-group text i n)]
                    [variant : String
                      (lsp-variant-form-in text name-end form-end needle)]
                    (if (string-eq variant "")
                      (set! i form-end)
                      (begin
                        (set!
                          enum-name
                          (substring text name-start (- name-end name-start)))
                        (set! variant-form variant)
                        (set! found true))))
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
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
      [doc : LspDocument (lsp-documents-get docs idx (lsp-document-fallback))]
      (if (string-eq (struct-get doc uri) current-uri)
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
  (if (>= idx (string-vec-len (struct-get set paths)))
    MissingVariant
    (match (lsp-enum-of-variant
      (string-vec-get (struct-get set texts) idx "")
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
  [stdlib-roots : StringVec]
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
        (string-eq result "")
        (or
          (string-eq name "i64")
          (string-eq name "i32")
          (string-eq name "i16")
          (string-eq name "i8")))
        (set!
          result
          (lsp-hover-markdown
            name
            "Signed integer (two's complement) of the named bit width."))
        unit)
      (if (and
        (string-eq result "")
        (or
          (string-eq name "u64")
          (string-eq name "u32")
          (string-eq name "u16")
          (string-eq name "u8")))
        (set!
          result
          (lsp-hover-markdown name "Unsigned integer of the named bit width."))
        unit)
      (if (and
        (string-eq result "")
        (or (string-eq name "f64") (string-eq name "f32")))
        (set!
          result
          (lsp-hover-markdown
            name
            "IEEE-754 floating-point number (64- or 32-bit)."))
        unit)
      (if (and (string-eq result "") (string-eq name "bool"))
        (set! result (lsp-hover-markdown "bool" "Boolean: `true` or `false`."))
        unit)
      (if (and (string-eq result "") (string-eq name "char"))
        (set!
          result
          (lsp-hover-markdown "char" "A character value (written like `'a'`)."))
        unit)
      (if (and (string-eq result "") (string-eq name "String"))
        (set!
          result
          (lsp-hover-markdown "String" "Owned, heap-allocated UTF-8 string."))
        unit)
      (if (and (string-eq result "") (string-eq name "str"))
        (set!
          result
          (lsp-hover-markdown
            "str"
            "Borrowed string slice (used as `(& str)`)."))
        unit)
      (if (and (string-eq result "") (string-eq name "unit"))
        (set!
          result
          (lsp-hover-markdown "unit" "The unit type; its only value is `unit`."))
        unit)
      (if (and (string-eq result "") (string-eq name "never"))
        (set!
          result
          (lsp-hover-markdown
            "never"
            "The empty type, for expressions that never return (e.g. `panic`)."))
        unit)
      (if (and (string-eq result "") (string-eq name "Array"))
        (set!
          result
          (lsp-hover-markdown
            "(Array T)"
            "Dynamically sized, heap-allocated array of `T`."))
        unit)
      (if (and (string-eq result "") (string-eq name "Tuple"))
        (set!
          result
          (lsp-hover-markdown
            "(Tuple A B ...)"
            "Fixed-size tuple of the given element types."))
        unit)
      (if (and (string-eq result "") (string-eq name "Box"))
        (set!
          result
          (lsp-hover-markdown
            "(Box T)"
            "Heap-allocated `T`; used for recursive data structures."))
        unit)
      (if (and (string-eq result "") (string-eq name "Ptr"))
        (set!
          result
          (lsp-hover-markdown
            "(Ptr T)"
            "Raw immutable pointer to `T` (unsafe to dereference)."))
        unit)
      (if (and (string-eq result "") (string-eq name "MutPtr"))
        (set!
          result
          (lsp-hover-markdown
            "(MutPtr T)"
            "Raw mutable pointer to `T` (unsafe to dereference)."))
        unit)
      (if (and
        (string-eq result "")
        (or
          (string-eq name "+")
          (string-eq name "-")
          (string-eq name "*")
          (string-eq name "/")))
        (set!
          result
          (lsp-hover-markdown
            (string-append name " : (-> num num num)")
            "Arithmetic on two integers or floats of the same numeric type."))
        unit)
      (if (and (string-eq result "") (string-eq name "%"))
        (set!
          result
          (lsp-hover-markdown
            "% : (-> int int int)"
            "Integer remainder (modulo)."))
        unit)
      (if (and
        (string-eq result "")
        (or (string-eq name "=") (string-eq name "!=")))
        (set!
          result
          (lsp-hover-markdown
            (string-append name " : (-> a a bool)")
            "Equality / inequality comparison."))
        unit)
      (if (and
        (string-eq result "")
        (or
          (string-eq name "<")
          (string-eq name "<=")
          (string-eq name ">")
          (string-eq name ">=")))
        (set!
          result
          (lsp-hover-markdown
            (string-append name " : (-> a a bool)")
            "Ordering comparison."))
        unit)
      (if (and
        (string-eq result "")
        (or (string-eq name "shl") (string-eq name "shr")))
        (set!
          result
          (lsp-hover-markdown
            (string-append name " : (-> int int int)")
            "Bit shift left / right."))
        unit)
      (if (and
        (string-eq result "")
        (or
          (string-eq name "bit-and")
          (string-eq name "bit-or")
          (string-eq name "bit-xor")))
        (set!
          result
          (lsp-hover-markdown
            (string-append name " : (-> int int int)")
            "Bitwise and / or / xor."))
        unit)
      (if (and (string-eq result "") (string-eq name "bit-not"))
        (set!
          result
          (lsp-hover-markdown "bit-not : (-> int int)" "Bitwise complement."))
        unit)
      (if (and (string-eq result "") (string-eq name "not"))
        (set!
          result
          (lsp-hover-markdown "not : (-> bool bool)" "Logical negation."))
        unit)
      (if (and (string-eq result "") (string-eq name "neg"))
        (set!
          result
          (lsp-hover-markdown "neg : (-> num num)" "Numeric negation."))
        unit)
      (if (and (string-eq result "") (string-eq name "string-length"))
        (set!
          result
          (lsp-hover-markdown
            "string-length : (-> String i64)"
            "Number of bytes in a string."))
        unit)
      (if (and (string-eq result "") (string-eq name "string-ref"))
        (set!
          result
          (lsp-hover-markdown
            "string-ref : (-> String i64 char)"
            "Byte at the given index."))
        unit)
      (if (and (string-eq result "") (string-eq name "string-data"))
        (set!
          result
          (lsp-hover-markdown
            "string-data : (-> String (Ptr u8))"
            "Pointer to a string's bytes."))
        unit)
      (if (and (string-eq result "") (string-eq name "make-array"))
        (set!
          result
          (lsp-hover-markdown
            "make-array : (-> Type i64 (Array T))"
            "Allocate a zero-initialized array of the given element type and length."))
        unit)
      (if (and (string-eq result "") (string-eq name "array-ref"))
        (set!
          result
          (lsp-hover-markdown
            "array-ref : (-> (Array T) i64 T)"
            "Read an array element (bounds-checked)."))
        unit)
      (if (and (string-eq result "") (string-eq name "array-set!"))
        (set!
          result
          (lsp-hover-markdown
            "array-set! : (-> (Array T) i64 T unit)"
            "Write an array element (bounds-checked)."))
        unit)
      (if (and (string-eq result "") (string-eq name "array-push!"))
        (set!
          result
          (lsp-hover-markdown
            "array-push! : (-> (Array T) T unit)"
            "Append a value to a dynamic array."))
        unit)
      (if (and (string-eq result "") (string-eq name "array-data"))
        (set!
          result
          (lsp-hover-markdown
            "array-data : (-> (Array T) (Ptr T))"
            "Pointer to an array's storage."))
        unit)
      (if (and (string-eq result "") (string-eq name "tuple-ref"))
        (set!
          result
          (lsp-hover-markdown
            "tuple-ref : (-> Tuple i64 T)"
            "Read a tuple element by constant index."))
        unit)
      (if (and (string-eq result "") (string-eq name "struct-get"))
        (set!
          result
          (lsp-hover-markdown
            "struct-get : (-> Struct field T)"
            "Read a struct field by name."))
        unit)
      (if (and (string-eq result "") (string-eq name "ptr-null"))
        (set!
          result
          (lsp-hover-markdown
            "ptr-null : (-> (Ptr T))"
            "Null pointer of the given type."))
        unit)
      (if (and (string-eq result "") (string-eq name "ptr-null?"))
        (set!
          result
          (lsp-hover-markdown
            "ptr-null? : (-> (Ptr T) bool)"
            "Whether a pointer is null."))
        unit)
      (if (and (string-eq result "") (string-eq name "ptr-read"))
        (set!
          result
          (lsp-hover-markdown
            "ptr-read : (-> (Ptr T) i64 T)"
            "Read the element at an offset from a pointer (unsafe)."))
        unit)
      (if (and (string-eq result "") (string-eq name "ptr-write!"))
        (set!
          result
          (lsp-hover-markdown
            "ptr-write! : (-> (MutPtr T) i64 T unit)"
            "Write the element at an offset through a pointer (unsafe)."))
        unit)
      (if (and (string-eq result "") (string-eq name "ptr-offset"))
        (set!
          result
          (lsp-hover-markdown
            "ptr-offset : (-> (Ptr T) i64 (Ptr T))"
            "Offset a pointer by N elements (unsafe)."))
        unit)
      (if (and (string-eq result "") (string-eq name "ptr-cast"))
        (set!
          result
          (lsp-hover-markdown
            "ptr-cast : (-> (Ptr A) Type (Ptr B))"
            "Reinterpret a pointer's element type (unsafe)."))
        unit)
      (if (and (string-eq result "") (string-eq name "ptr->int"))
        (set!
          result
          (lsp-hover-markdown
            "ptr->int : (-> (Ptr T) u64)"
            "Pointer to integer address (unsafe)."))
        unit)
      (if (and (string-eq result "") (string-eq name "int->ptr"))
        (set!
          result
          (lsp-hover-markdown
            "int->ptr : (-> u64 Type (Ptr T))"
            "Integer address to pointer (unsafe)."))
        unit)
      (if (and (string-eq result "") (string-eq name "if"))
        (set!
          result
          (lsp-hover-markdown
            "(if cond then else)"
            "Conditional expression; both branches must have the same type."))
        unit)
      (if (and (string-eq result "") (string-eq name "let"))
        (set!
          result
          (lsp-hover-markdown
            "(let [name : T value] ... body)"
            "Introduce local bindings, then evaluate the body."))
        unit)
      (if (and (string-eq result "") (string-eq name "begin"))
        (set!
          result
          (lsp-hover-markdown
            "(begin expr ...)"
            "Evaluate expressions in sequence; the result is the last."))
        unit)
      (if (and (string-eq result "") (string-eq name "while"))
        (set!
          result
          (lsp-hover-markdown
            "(while cond body)"
            "Loop while the condition is true."))
        unit)
      (if (and (string-eq result "") (string-eq name "set!"))
        (set!
          result
          (lsp-hover-markdown "(set! name value)" "Mutate an existing binding."))
        unit)
      (if (and (string-eq result "") (string-eq name "match"))
        (set!
          result
          (lsp-hover-markdown
            "(match value [pattern body] ...)"
            "Pattern match on an enum value."))
        unit)
      (if (and (string-eq result "") (string-eq name "return"))
        (set!
          result
          (lsp-hover-markdown
            "(return value)"
            "Return early from the enclosing function."))
        unit)
      (if (and (string-eq result "") (string-eq name "lambda"))
        (set!
          result
          (lsp-hover-markdown "(lambda [p : T] ... body)" "Anonymous function."))
        unit)
      (if (and (string-eq result "") (string-eq name "cast"))
        (set!
          result
          (lsp-hover-markdown
            "(cast value : Type)"
            "Convert a value to another numeric or pointer type."))
        unit)
      (if (and (string-eq result "") (string-eq name "unsafe"))
        (set!
          result
          (lsp-hover-markdown
            "(unsafe body)"
            "Permit unsafe operations (raw pointers, syscalls) within the body."))
        unit)
      result)))

(define (lsp-hover-respond
  [id : Json]
  [uri : String]
  [position : Json]
  [docs : LspDocuments]
  [stdlib-roots : StringVec]) : unit
  (match (lsp-documents-lookup docs uri)
    [(FoundLspDocument path text _)
      (let
        [line0 : i64 (lsp-json-int-field-default position "line" 0)]
        [char0 : i64 (lsp-json-int-field-default position "character" 0)]
        [off : i64 (lsp-offset-at-position text line0 char0)]
        [sym : String (lsp-symbol-at-offset text off)]
        (if (string-eq sym "")
          (lsp-write-response id JsonNull)
          (let
            [needle : String (lsp-symbol-base sym)]
            [bind-type : String (lsp-binding-type text needle off)]
            [builtin : String (lsp-builtin-hover needle)]
            (if (not (string-eq bind-type ""))
              (lsp-write-response
                id
                (lsp-hover-result
                  (lsp-hover-markdown
                    (string-append needle (string-append " : " bind-type))
                    "")
                  line0
                  char0
                  (string-length sym)))
              (if (not (string-eq builtin ""))
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
                              (string-append
                                "Variant of `"
                                (string-append enum-name "`.")))
                            line0
                            char0
                            (string-length sym)))]
                      [(MissingVariant) (lsp-write-response id JsonNull)])]))))))]
    [(MissingLspDocument) (lsp-write-response id JsonNull)]))

(define (lsp-handle-hover
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
              [pos-key : String "position"]
              (match (json-object-get params (& pos-key))
                [(JsonFound position)
                  (lsp-hover-respond id uri position docs stdlib-roots)]
                [(JsonMissing) (lsp-write-response id JsonNull)]))]
          [(MissingLspJsonText) (lsp-write-response id JsonNull)])]
      [(JsonMissing) (lsp-write-response id JsonNull)])))

;; --------------------------------------------------------------------------
;; Document links (textDocument/documentLink): make (import "spec") paths
;; clickable, navigating to the resolved module file.
;; --------------------------------------------------------------------------
(define (lsp-document-link-json
  [text : String]
  [path : String]
  [stdlib-roots : StringVec]
  [content-start : i64]
  [content-end : i64]) : Json
  (let
    [spec : String (substring text content-start (- content-end content-start))]
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
      (JsonString (lsp-path-to-file-uri resolved)))))

(define (lsp-document-links
  [text : String]
  [path : String]
  [stdlib-roots : StringVec]) : JsonList
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [acc : JsonList JsonListNil]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (cond
            [(= c ';') (set! i (lsp-skip-line text i n))]
            [(= c '\'') (set! i (lsp-skip-apostrophe-char-literal text i n))]
            [(= c '"') (set! i (lsp-skip-string text i n))]
            [(= c '(')
              (let
                [kw-start : i64 (lsp-skip-space text (+ i 1) n)]
                [kw-end : i64 (lsp-scan-ident text kw-start n)]
                (if (and
                  (> kw-end kw-start)
                  (string-eq
                    (substring text kw-start (- kw-end kw-start))
                    "import"))
                  (let
                    [q : i64 (lsp-skip-space text kw-end n)]
                    (if (and (< q n) (= (string-ref text q) '"'))
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
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
      acc)))

(define (lsp-document-link-respond
  [id : Json]
  [uri : String]
  [docs : LspDocuments]
  [stdlib-roots : StringVec]) : unit
  (match (lsp-documents-lookup docs uri)
    [(FoundLspDocument path text _)
      (lsp-write-response
        id
        (lsp-json-array (lsp-document-links text path stdlib-roots)))]
    [(MissingLspDocument) (lsp-write-response id (lsp-json-array JsonListNil))]))

(define (lsp-handle-document-link
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
            (lsp-document-link-respond id uri docs stdlib-roots)]
          [(MissingLspJsonText)
            (lsp-write-response id (lsp-json-array JsonListNil))])]
      [(JsonMissing) (lsp-write-response id (lsp-json-array JsonListNil))])))

(define (lsp-maybe-write-method-not-found [message : Json]) : unit
  (let
    [key : String "id"]
    (match (json-object-get message (& key))
      [(JsonFound id) (lsp-write-error id -32601 "Method not found")]
      [(JsonMissing) unit])))

(define (lsp-decl-entry-fallback) : LspDeclEntry
  (LspDeclEntry "" "" 0 0 0 0 0 0 0))

(define (lsp-decl-kind-at [text : String] [i : i64] [n : i64]) : String
  (let
    [after-open : i64 (lsp-skip-space text (+ i 1) n)]
    [kw-end : i64 (lsp-scan-ident text after-open n)]
    (if (<= kw-end after-open)
      "unknown"
      (let
        [kw : String (substring text after-open (- kw-end after-open))]
        (cond
          [(string-eq kw "define") "function"]
          [(string-eq kw "defmacro") "macro"]
          [(string-eq kw "defstruct") "struct"]
          [(string-eq kw "defenum") "enum"]
          [(string-eq kw "defdispatch") "dispatch"]
          [(string-eq kw "extern") "extern"]
          [else "unknown"])))))

(define (lsp-scan-decls [text : String]) : LspDeclList
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [depth : i64 0]
    [result : LspDeclList (lsp-decl-list-with-capacity 16)]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (begin
            (cond
              [(= c ';') (set! i (lsp-skip-line text i n))]
              [(= c '\'') (set! i (lsp-skip-apostrophe-char-literal text i n))]
              [(= c '"') (set! i (lsp-skip-string text i n))]
              [(= c '(')
                (begin
                  (set! depth (+ depth 1))
                  (if (= depth 1)
                    (let
                      [name-off : i64 (lsp-def-name-offset-at text i n)]
                      (if (>= name-off 0)
                        (let
                          [name : String (lsp-symbol-at-offset text name-off)]
                          [kind : String (lsp-decl-kind-at text i n)]
                          [form-end : i64 (lsp-skip-paren-group text i n)]
                          [name-lc : LspLineCol
                            (lsp-line-col-at-offset text name-off)]
                          [form-start-lc : LspLineCol
                            (lsp-line-col-at-offset text i)]
                          [form-end-lc : LspLineCol
                            (lsp-line-col-at-offset text form-end)]
                          (set!
                            result
                            (lsp-decl-list-push
                              result
                              (LspDeclEntry
                                kind
                                name
                                (struct-get name-lc line)
                                (struct-get name-lc col)
                                (string-length name)
                                (struct-get form-start-lc line)
                                (struct-get form-start-lc col)
                                (struct-get form-end-lc line)
                                (struct-get form-end-lc col)))))
                        unit))
                    unit)
                  (set! i (+ i 1)))]
              [(= c ')')
                (begin
                  (set! depth (- depth 1))
                  (set! i (+ i 1)))]
              [else (set! i (+ i 1))]))))
      result)))

;; Helper: extract document from params
(define (lsp-get-document [params : Json] [docs : LspDocuments]) : LspDocumentLookup
  (let
    [key : String "textDocument"]
    (match (json-object-get params (& key))
      [(JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(OkLspJsonText uri) (lsp-documents-lookup docs uri)]
          [(MissingLspJsonText) MissingLspDocument])]
      [(JsonMissing) MissingLspDocument])))

;; Helper: build JSON array of declaration names from LspDeclList
(define (lsp-decls-to-name-list [decls : LspDeclList] [idx : i64]) : JsonList
  (if (>= idx (lsp-decl-list-len decls))
    JsonListNil
    (let
      [entry : LspDeclEntry
        (lsp-decl-list-get decls idx (lsp-decl-entry-fallback))]
      [name : String (struct-get entry name)]
      (lsp-json-list-cons
        (JsonString name)
        (lsp-decls-to-name-list decls (+ idx 1))))))

;; Helper: build JSON array of all declarations with metadata
(define (lsp-decls-to-json-list [decls : LspDeclList] [idx : i64]) : JsonList
  (if (>= idx (lsp-decl-list-len decls))
    JsonListNil
    (let
      [entry : LspDeclEntry
        (lsp-decl-list-get decls idx (lsp-decl-entry-fallback))]
      [obj : Json
        (lsp-json-object
          (lsp-json-member
            "kind"
            (JsonString (struct-get entry kind))
            (lsp-json-member
              "name"
              (JsonString (struct-get entry name))
              (lsp-json-member
                "line"
                (lsp-json-number (struct-get entry name-line))
                (lsp-json-member
                  "column"
                  (lsp-json-number (struct-get entry name-col))
                  (lsp-json-member
                    "length"
                    (lsp-json-number (struct-get entry name-len))
                    JsonMemberListNil))))))]
      (lsp-json-list-cons obj (lsp-decls-to-json-list decls (+ idx 1))))))

;; Helper: replace text from (sl,sc) to (el,ec) with new-text
;; Positions are 1-based (from scanner), convert to 0-based for offset-at-position
(define (lsp-edit-at-pos
  [text : String]
  [sl : i64]
  [sc : i64]
  [el : i64]
  [ec : i64]
  [new-text : String]) : String
  (let
    [start-off : i64 (lsp-offset-at-position text (- sl 1) (- sc 1))]
    [end-off : i64 (lsp-offset-at-position text (- el 1) (- ec 1))]
    [before : String (substring text 0 start-off)]
    [after : String (substring text end-off (- (string-length text) end-off))]
    (string-append (string-append before new-text) after)))

;; tl/listFunctions - List all top-level function names in a document
(define (lsp-handle-tl-list-functions
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (let
        [decls : LspDeclList (lsp-scan-decls text)]
        [items : JsonList (lsp-decls-to-name-list decls 0)]
        (begin
          (lsp-write-response id (lsp-json-array items))
          (LspContinue docs)))]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; tl/astDump - Return full declaration metadata
(define (lsp-handle-tl-ast-dump
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (let
        [decls : LspDeclList (lsp-scan-decls text)]
        [items : JsonList (lsp-decls-to-json-list decls 0)]
        (begin
          (lsp-write-response id (lsp-json-array items))
          (LspContinue docs)))]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; tl/structuralReplace - Replace a top-level form by name
(define (lsp-handle-tl-structural-replace
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (match (lsp-json-string-field params "name")
        [(OkLspJsonText name)
          (match (lsp-json-string-field params "newText")
            [(OkLspJsonText new-text)
              (let
                [text-copy : String (string-copy-borrowed (& text))]
                [decls : LspDeclList (lsp-scan-decls text-copy)]
                [i : i64 0]
                [n : i64 (lsp-decl-list-len decls)]
                [found : bool false]
                [result : String ""]
                (begin
                  (while (and (< i n) (not found))
                    (let
                      [entry : LspDeclEntry
                        (lsp-decl-list-get decls i (lsp-decl-entry-fallback))]
                      (if (string-eq (struct-get entry name) name)
                        (begin
                          (set!
                            result
                            (lsp-edit-at-pos
                              text
                              (struct-get entry form-start-line)
                              (struct-get entry form-start-col)
                              (struct-get entry form-end-line)
                              (struct-get entry form-end-col)
                              new-text))
                          (set! found true)
                          unit)
                        (begin
                          (set! i (+ i 1))
                          unit))))
                  (if found
                    (let
                      [formatted : String
                        (format-rules-render-source-width result 80)]
                      (begin
                        (lsp-write-response
                          id
                          (lsp-json-object2
                            "success"
                            (JsonBool true)
                            "text"
                            (JsonString formatted)))
                        (LspContinue docs)))
                    (begin
                      (lsp-write-error id -32600 "Declaration not found")
                      (LspContinue docs)))))]
            [(MissingLspJsonText)
              (begin
                (lsp-write-error id -32600 "Missing newText parameter")
                (LspContinue docs))])]
        [(MissingLspJsonText)
          (begin
            (lsp-write-error id -32600 "Missing name parameter")
            (LspContinue docs))])]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; tl/insertFunction - Insert a function after another
(define (lsp-handle-tl-insert-function
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (match (lsp-json-string-field params "after")
        [(OkLspJsonText after-name)
          (match (lsp-json-string-field params "newText")
            [(OkLspJsonText new-text)
              (let
                [text-copy : String (string-copy-borrowed (& text))]
                [decls : LspDeclList (lsp-scan-decls text-copy)]
                [i : i64 0]
                [n : i64 (lsp-decl-list-len decls)]
                [found : bool false]
                [result : String ""]
                (begin
                  (while (and (< i n) (not found))
                    (let
                      [entry : LspDeclEntry
                        (lsp-decl-list-get decls i (lsp-decl-entry-fallback))]
                      (if (string-eq (struct-get entry name) after-name)
                        (begin
                          (set!
                            result
                            (lsp-edit-at-pos
                              text
                              (struct-get entry form-end-line)
                              (struct-get entry form-end-col)
                              (struct-get entry form-end-line)
                              (struct-get entry form-end-col)
                              (string-append "\n\n" new-text)))
                          (set! found true)
                          unit)
                        (begin
                          (set! i (+ i 1))
                          unit))))
                  (if found
                    (let
                      [formatted : String
                        (format-rules-render-source-width result 80)]
                      (begin
                        (lsp-write-response
                          id
                          (lsp-json-object2
                            "success"
                            (JsonBool true)
                            "text"
                            (JsonString formatted)))
                        (LspContinue docs)))
                    (begin
                      (lsp-write-error id -32600 "Declaration not found")
                      (LspContinue docs)))))]
            [(MissingLspJsonText)
              (begin
                (lsp-write-error id -32600 "Missing newText parameter")
                (LspContinue docs))])]
        [(MissingLspJsonText)
          (begin
            (lsp-write-error id -32600 "Missing after parameter")
            (LspContinue docs))])]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; tl/deleteFunction - Delete a function by name
(define (lsp-handle-tl-delete-function
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (match (lsp-json-string-field params "name")
        [(OkLspJsonText name)
          (let
            [text-copy : String (string-copy-borrowed (& text))]
            [decls : LspDeclList (lsp-scan-decls text-copy)]
            [i : i64 0]
            [n : i64 (lsp-decl-list-len decls)]
            [found : bool false]
            [result : String ""]
            (begin
              (while (and (< i n) (not found))
                (let
                  [entry : LspDeclEntry
                    (lsp-decl-list-get decls i (lsp-decl-entry-fallback))]
                  (if (string-eq (struct-get entry name) name)
                    (begin
                      (set!
                        result
                        (lsp-edit-at-pos
                          text
                          (struct-get entry form-start-line)
                          (struct-get entry form-start-col)
                          (struct-get entry form-end-line)
                          (struct-get entry form-end-col)
                          ""))
                      (set! found true)
                      unit)
                    (begin
                      (set! i (+ i 1))
                      unit))))
              (if found
                (let
                  [formatted : String
                    (format-rules-render-source-width result 80)]
                  (begin
                    (lsp-write-response
                      id
                      (lsp-json-object2
                        "success"
                        (JsonBool true)
                        "text"
                        (JsonString formatted)))
                    (LspContinue docs)))
                (begin
                  (lsp-write-error id -32600 "Declaration not found")
                  (LspContinue docs)))))]
        [(MissingLspJsonText)
          (begin
            (lsp-write-error id -32600 "Missing name parameter")
            (LspContinue docs))])]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; Helper: get offset from LspDeclEntry start position
(define (lsp-offset-from-entry-start [text : String] [entry : LspDeclEntry]) : i64
  (lsp-offset-at-position
    text
    (- (struct-get entry form-start-line) 1)
    (- (struct-get entry form-start-col) 1)))

;; Helper: get offset from LspDeclEntry end position
(define (lsp-offset-from-entry-end [text : String] [entry : LspDeclEntry]) : i64
  (lsp-offset-at-position
    text
    (- (struct-get entry form-end-line) 1)
    (- (struct-get entry form-end-col) 1)))

;; tl/structuralMove - Move a form up/down in the file
(define (lsp-handle-tl-structural-move
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (match (lsp-json-string-field params "name")
        [(OkLspJsonText name)
          (match (lsp-json-string-field params "direction")
            [(OkLspJsonText direction)
              (let
                [text-copy : String (string-copy-borrowed (& text))]
                [decls : LspDeclList (lsp-scan-decls text-copy)]
                [i : i64 0]
                [n : i64 (lsp-decl-list-len decls)]
                [found-idx : i64 -1]
                (begin
                  (while (and (< i n) (= found-idx -1))
                    (let
                      [entry : LspDeclEntry
                        (lsp-decl-list-get decls i (lsp-decl-entry-fallback))]
                      (if (string-eq (struct-get entry name) name)
                        (set! found-idx i)
                        (set! i (+ i 1)))))
                  (if (= found-idx -1)
                    (begin
                      (lsp-write-error id -32600 "Declaration not found")
                      (LspContinue docs))
                    (let
                      [target-idx : i64
                        (if (string-eq direction "up")
                          (- found-idx 1)
                          (if (string-eq direction "down")
                            (+ found-idx 1)
                            -1))]
                      (if (or
                        (< target-idx 0)
                        (>= target-idx n)
                        (= target-idx -1))
                        (begin
                          (lsp-write-error
                            id
                            -32600
                            "Invalid direction or cannot move further")
                          (LspContinue docs))
                        (let
                          [found-entry : LspDeclEntry
                            (lsp-decl-list-get
                              decls
                              found-idx
                              (lsp-decl-entry-fallback))]
                          [target-entry : LspDeclEntry
                            (lsp-decl-list-get
                              decls
                              target-idx
                              (lsp-decl-entry-fallback))]
                          [found-first : bool (< found-idx target-idx)]
                          [first-entry : LspDeclEntry
                            (if found-first
                              found-entry
                              target-entry)]
                          [second-entry : LspDeclEntry
                            (if found-first
                              target-entry
                              found-entry)]
                          [first-start : i64
                            (lsp-offset-from-entry-start text first-entry)]
                          [first-end : i64
                            (lsp-offset-from-entry-end text first-entry)]
                          [second-start : i64
                            (lsp-offset-from-entry-start text second-entry)]
                          [second-end : i64
                            (lsp-offset-from-entry-end text second-entry)]
                          [text-before : String (substring text 0 first-start)]
                          [second-text : String
                            (substring
                              text
                              second-start
                              (- second-end second-start))]
                          [middle : String
                            (substring
                              text
                              first-end
                              (- second-start first-end))]
                          [first-text : String
                            (substring
                              text
                              first-start
                              (- first-end first-start))]
                          [text-after : String
                            (substring
                              text
                              second-end
                              (- (string-length text) second-end))]
                          [result : String ""]
                          (begin
                            (set! result text-before)
                            (set! result (string-append result second-text))
                            (set! result (string-append result middle))
                            (set! result (string-append result first-text))
                            (set! result (string-append result text-after))
                            (let
                              [formatted : String
                                (format-rules-render-source-width result 80)]
                              (begin
                                (lsp-write-response
                                  id
                                  (lsp-json-object2
                                    "success"
                                    (JsonBool true)
                                    "text"
                                    (JsonString formatted)))
                                (LspContinue docs))))))))))]
            [(MissingLspJsonText)
              (begin
                (lsp-write-error id -32600 "Missing direction parameter")
                (LspContinue docs))])]
        [(MissingLspJsonText)
          (begin
            (lsp-write-error id -32600 "Missing name parameter")
            (LspContinue docs))])]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; tl/expandMacro - Find the form at cursor position and return its text
;; For now, returns the top-level form by name.
;; Full macro expansion would require compiler macro expansion integration.
(define (lsp-handle-tl-expand-macro
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (match (lsp-json-string-field params "name")
        [(OkLspJsonText name)
          (let
            [text-copy : String (string-copy-borrowed (& text))]
            [decls : LspDeclList (lsp-scan-decls text-copy)]
            [i : i64 0]
            [n : i64 (lsp-decl-list-len decls)]
            [found-idx : i64 -1]
            (begin
              (while (and (< i n) (= found-idx -1))
                (let
                  [entry : LspDeclEntry
                    (lsp-decl-list-get decls i (lsp-decl-entry-fallback))]
                  (if (string-eq (struct-get entry name) name)
                    (set! found-idx i)
                    (set! i (+ i 1)))))
              (if (= found-idx -1)
                (begin
                  (lsp-write-error id -32600 "Form not found")
                  (LspContinue docs))
                (let
                  [entry : LspDeclEntry
                    (lsp-decl-list-get
                      decls
                      found-idx
                      (lsp-decl-entry-fallback))]
                  [start-off : i64
                    (lsp-offset-at-position
                      text
                      (- (struct-get entry form-start-line) 1)
                      (- (struct-get entry form-start-col) 1))]
                  [end-off : i64
                    (lsp-offset-at-position
                      text
                      (- (struct-get entry form-end-line) 1)
                      (- (struct-get entry form-end-col) 1))]
                  [result : String
                    (substring text start-off (- end-off start-off))]
                  (begin
                    (lsp-write-response
                      id
                      (lsp-json-object2
                        "success"
                        (JsonBool true)
                        "text"
                        (JsonString result)))
                    (LspContinue docs))))))]
        [(MissingLspJsonText)
          (begin
            (lsp-write-error id -32600 "Missing name parameter")
            (LspContinue docs))])]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; tl/getTypeAt - Type of expression at cursor
(define (lsp-handle-tl-get-type-at
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (let
        [result : LspEditResult (ErrLspEdit "Not yet implemented")]
        (match result
          [(OkLspEdit new-text)
            (begin
              (lsp-write-response
                id
                (lsp-json-object2
                  "success"
                  (JsonBool true)
                  "text"
                  (JsonString new-text)))
              (LspContinue docs))]
          [(ErrLspEdit message)
            (begin
              (lsp-write-error id -32600 message)
              (LspContinue docs))]))]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; tl/findReferences - All uses of a name
(define (lsp-handle-tl-find-references
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (let
        [result : LspEditResult (ErrLspEdit "Not yet implemented")]
        (match result
          [(OkLspEdit new-text)
            (begin
              (lsp-write-response
                id
                (lsp-json-object2
                  "success"
                  (JsonBool true)
                  "text"
                  (JsonString new-text)))
              (LspContinue docs))]
          [(ErrLspEdit message)
            (begin
              (lsp-write-error id -32600 message)
              (LspContinue docs))]))]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

(define (lsp-tl-source-file-name? [entry : String]) : bool
  (let
    [entry-len : i64 (string-length entry)]
    (if (< entry-len 3)
      false
      (and
        (= (string-ref entry (- entry-len 3)) '.')
        (= (string-ref entry (- entry-len 2)) 't')
        (= (string-ref entry (- entry-len 1)) 'l')))))

(define (lsp-decls-contain-name? [decls : LspDeclList] [needle : String]) : bool
  (let
    [n : i64 (lsp-decl-list-len decls)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (let
          [entry : LspDeclEntry
            (lsp-decl-list-get decls i (lsp-decl-entry-fallback))]
          (if (string-eq (struct-get entry name) needle)
            (set! found true)
            (set! i (+ i 1)))))
      found)))

;; tl/projectSearch - Search for a declaration name across .tl files in a directory
(define (lsp-handle-tl-project-search
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-json-string-field params "name")
    [(OkLspJsonText name)
      (if (string-eq name "")
        (begin
          (lsp-write-error id -32600 "name cannot be empty")
          (LspContinue docs))
        (let
          [td-key : String "textDocument"]
          (match (json-object-get params (& td-key))
            [(JsonFound document)
              (match (lsp-json-string-field document "uri")
                [(OkLspJsonText uri)
                  (match (lsp-file-uri-to-path uri)
                    [(OkLspUriPath path)
                      (match (try-read-dir-vec (& path))
                        [(OkIoStringVec entries)
                          (let
                            [n : i64 (string-vec-len entries)]
                            [i : i64 0]
                            [results : JsonList JsonListNil]
                            (begin
                              (while (< i n)
                                (let
                                  [entry : String (string-vec-get entries i "")]
                                  (begin
                                    (if (lsp-tl-source-file-name? entry)
                                      (let
                                        [entry-path : String
                                          (fs-path-join (& path) (& entry))]
                                        (match (try-read-file (& entry-path))
                                          [(OkIoString source)
                                            (if (lsp-decls-contain-name?
                                              (lsp-scan-decls source)
                                              name)
                                              (let
                                                [entry-uri : String
                                                  (lsp-path-to-file-uri
                                                    (fs-path-normalize
                                                      (& entry-path)))]
                                                (set!
                                                  results
                                                  (lsp-json-list-cons
                                                    (lsp-json-object2
                                                      "uri"
                                                      (JsonString entry-uri)
                                                      "name"
                                                      (JsonString name))
                                                    results)))
                                              unit)]
                                          [(ErrIoString _) unit]))
                                      unit)
                                    (set! i (+ i 1)))))
                              (lsp-write-response
                                id
                                (lsp-json-object2
                                  "success"
                                  (JsonBool true)
                                  "results"
                                  (lsp-json-array results)))
                              (LspContinue docs)))]
                        [(ErrIoStringVec message)
                          (begin
                            (lsp-write-error
                              id
                              -32600
                              (str-cat
                                "Failed to read directory: "
                                (io-error-message message)))
                            (LspContinue docs))])]
                    [(ErrLspUriPath message)
                      (begin
                        (lsp-write-error id -32600 message)
                        (LspContinue docs))])]
                [(MissingLspJsonText)
                  (begin
                    (lsp-write-error
                      id
                      -32600
                      "Missing uri in textDocument parameter")
                    (LspContinue docs))])]
            [(JsonMissing)
              (begin
                (lsp-write-error id -32600 "Missing textDocument parameter")
                (LspContinue docs))])))]
    [(MissingLspJsonText)
      (begin
        (lsp-write-error id -32600 "Missing name parameter")
        (LspContinue docs))]))

;; tl/signatureHelp - Parameter types for function at cursor
(define (lsp-handle-tl-eval-at-point
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (let
        [result : LspEditResult (ErrLspEdit "Not yet implemented")]
        (match result
          [(OkLspEdit new-text)
            (begin
              (lsp-write-response
                id
                (lsp-json-object2
                  "success"
                  (JsonBool true)
                  "text"
                  (JsonString new-text)))
              (LspContinue docs))]
          [(ErrLspEdit message)
            (begin
              (lsp-write-error id -32600 message)
              (LspContinue docs))]))]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; tl/signatureHelp - Parameter types for function at cursor
(define (lsp-handle-tl-signature-help
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (let
        [result : LspEditResult (ErrLspEdit "Not yet implemented")]
        (match result
          [(OkLspEdit new-text)
            (begin
              (lsp-write-response
                id
                (lsp-json-object2
                  "success"
                  (JsonBool true)
                  "text"
                  (JsonString new-text)))
              (LspContinue docs))]
          [(ErrLspEdit message)
            (begin
              (lsp-write-error id -32600 message)
              (LspContinue docs))]))]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; tl/appendFunction - Append a form at the end of the file
(define (lsp-handle-tl-append-function
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (match (lsp-json-string-field params "newText")
        [(OkLspJsonText new-text)
          (if (not (lsp-text-is-valid-forms new-text))
            (begin
              (lsp-write-error
                id
                -32600
                (str-cat
                  "newText is not valid form(s): "
                  (lsp-validate-forms-error new-text)))
              (LspContinue docs))
            (let
              [text-copy : String (string-copy-borrowed (& text))]
              [decls : LspDeclList (lsp-scan-decls text-copy)]
              [n : i64 (lsp-decl-list-len decls)]
              [result : String ""]
              (begin
                (if (= n 0)
                  (set!
                    result
                    (string-append (string-append text "\n\n") new-text))
                  (let
                    [last-entry : LspDeclEntry
                      (lsp-decl-list-get
                        decls
                        (- n 1)
                        (lsp-decl-entry-fallback))]
                    (set!
                      result
                      (lsp-edit-at-pos
                        text
                        (struct-get last-entry form-end-line)
                        (struct-get last-entry form-end-col)
                        (struct-get last-entry form-end-line)
                        (struct-get last-entry form-end-col)
                        (string-append "\n\n" new-text)))))
                (let
                  [formatted : String
                    (format-rules-render-source-width result 80)]
                  (begin
                    (lsp-write-response
                      id
                      (lsp-json-object2
                        "success"
                        (JsonBool true)
                        "text"
                        (JsonString formatted)))
                    (LspContinue docs))))))]
        [(MissingLspJsonText)
          (begin
            (lsp-write-error id -32600 "Missing newText parameter")
            (LspContinue docs))])]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; tl/replaceBody - Replace the body of a function, keeping its signature
(define (lsp-handle-tl-replace-body
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (match (lsp-json-string-field params "name")
        [(OkLspJsonText name)
          (match (lsp-json-string-field params "newBody")
            [(OkLspJsonText new-body)
              (let
                [text-copy : String (string-copy-borrowed (& text))]
                [decls : LspDeclList (lsp-scan-decls text-copy)]
                [i : i64 0]
                [n : i64 (lsp-decl-list-len decls)]
                [found : bool false]
                [result : String ""]
                (begin
                  (while (and (< i n) (not found))
                    (let
                      [entry : LspDeclEntry
                        (lsp-decl-list-get decls i (lsp-decl-entry-fallback))]
                      (if (string-eq (struct-get entry name) name)
                        (begin
                          (set! found true)
                          (let
                            [kind : String (struct-get entry kind)]
                            [n2 : i64 (string-length text)]
                            (if (or
                              (string-eq kind "function")
                              (string-eq kind "macro"))
                              (let
                                [form-start-off : i64
                                  (lsp-offset-at-position
                                    text
                                    (- (struct-get entry form-start-line) 1)
                                    (- (struct-get entry form-start-col) 1))]
                                [after-kw : i64
                                  (lsp-skip-space text (+ form-start-off 1) n2)]
                                [kw-end : i64 (lsp-scan-ident text after-kw n2)]
                                [after-kw2 : i64
                                  (lsp-skip-space text kw-end n2)]
                                (if (and
                                  (< after-kw2 n2)
                                  (= (string-ref text after-kw2) '('))
                                  (let
                                    [body-start-off : i64
                                      (lsp-find-body-start-offset
                                        text
                                        form-start-off)]
                                    [body-end-off : i64
                                      (-
                                        (lsp-offset-at-position
                                          text
                                          (- (struct-get entry form-end-line) 1)
                                          (- (struct-get entry form-end-col) 1))
                                        1)]
                                    [body-start-lc : LspLineCol
                                      (lsp-line-col-at-offset
                                        text
                                        body-start-off)]
                                    [body-end-lc : LspLineCol
                                      (lsp-line-col-at-offset text body-end-off)]
                                    (set!
                                      result
                                      (lsp-edit-at-pos
                                        text
                                        (struct-get body-start-lc line)
                                        (struct-get body-start-lc col)
                                        (struct-get body-end-lc line)
                                        (struct-get body-end-lc col)
                                        new-body)))
                                  (begin
                                    (lsp-write-error
                                      id
                                      -32600
                                      "replaceBody only supported for function/macro definitions with parameter lists")
                                    (set! result ""))))
                              (begin
                                (lsp-write-error
                                  id
                                  -32600
                                  "replaceBody only supported for define and defmacro")
                                (set! result "")))))
                        (begin
                          (set! i (+ i 1))
                          unit))))
                  (if found
                    (if (string-eq result "")
                      (LspContinue docs)
                      (if (not (lsp-text-is-valid-forms new-body))
                        (begin
                          (lsp-write-error
                            id
                            -32600
                            (str-cat
                              "newBody is not a valid form: "
                              (lsp-validate-forms-error new-body)))
                          (LspContinue docs))
                        (let
                          [formatted : String
                            (format-rules-render-source-width result 80)]
                          (begin
                            (lsp-write-response
                              id
                              (lsp-json-object2
                                "success"
                                (JsonBool true)
                                "text"
                                (JsonString formatted)))
                            (LspContinue docs)))))
                    (begin
                      (lsp-write-error id -32600 "Declaration not found")
                      (LspContinue docs)))))]
            [(MissingLspJsonText)
              (begin
                (lsp-write-error id -32600 "Missing newBody parameter")
                (LspContinue docs))])]
        [(MissingLspJsonText)
          (begin
            (lsp-write-error id -32600 "Missing name parameter")
            (LspContinue docs))])]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

(define (lsp-handle-message
  [message : Json]
  [docs : LspDocuments]
  [stdlib-roots : StringVec]) : LspHandleResult
  (match (lsp-json-string-field message "method")
    [(OkLspJsonText method)
      (let
        [handled : bool false]
        [result : LspHandleResult (LspContinue docs)]
        (begin
          (if (and (not handled) (string-eq method "initialize"))
            (begin
              (set! handled true)
              (let
                [key : String "id"]
                (match (json-object-get message (& key))
                  [(JsonFound id)
                    (lsp-write-response id (lsp-initialize-result))]
                  [(JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and (not handled) (string-eq method "initialized"))
            (begin
              (set! handled true)
              (set! result (LspContinue docs)))
            unit)
          (if (and (not handled) (string-eq method "shutdown"))
            (begin
              (set! handled true)
              (let
                [key : String "id"]
                (match (json-object-get message (& key))
                  [(JsonFound id) (lsp-write-response id JsonNull)]
                  [(JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and (not handled) (string-eq method "exit"))
            (begin
              (set! handled true)
              (set! result (LspExit docs)))
            unit)
          (if (and (not handled) (string-eq method "textDocument/didOpen"))
            (begin
              (set! handled true)
              (let
                [key : String "params"]
                (match (json-object-get message (& key))
                  [(JsonFound params)
                    (set! result (lsp-did-open params docs stdlib-roots))]
                  [(JsonMissing) (set! result (LspContinue docs))])))
            unit)
          (if (and (not handled) (string-eq method "textDocument/didChange"))
            (begin
              (set! handled true)
              (let
                [key : String "params"]
                (match (json-object-get message (& key))
                  [(JsonFound params)
                    (set! result (lsp-did-change params docs stdlib-roots))]
                  [(JsonMissing) (set! result (LspContinue docs))])))
            unit)
          (if (and (not handled) (string-eq method "textDocument/didClose"))
            (begin
              (set! handled true)
              (let
                [key : String "params"]
                (match (json-object-get message (& key))
                  [(JsonFound params) (set! result (lsp-did-close params docs))]
                  [(JsonMissing) (set! result (LspContinue docs))])))
            unit)
          (if (and (not handled) (string-eq method "textDocument/definition"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (lsp-handle-definition id params docs stdlib-roots)]
                        [(JsonMissing) (lsp-write-response id JsonNull)]))]
                  [(JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and (not handled) (string-eq method "textDocument/completion"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id) (lsp-completion-respond id docs)]
                  [(JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and (not handled) (string-eq method "textDocument/inlayHint"))
            (begin
              (set! handled true)
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
              (set! result (LspContinue docs)))
            unit)
          (if (and (not handled) (string-eq method "textDocument/formatting"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (lsp-handle-formatting id params docs)]
                        [(JsonMissing)
                          (lsp-write-response id (lsp-json-array JsonListNil))]))]
                  [(JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and (not handled) (string-eq method "textDocument/hover"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (lsp-handle-hover id params docs stdlib-roots)]
                        [(JsonMissing) (lsp-write-response id JsonNull)]))]
                  [(JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and (not handled) (string-eq method "textDocument/documentLink"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (lsp-handle-document-link id params docs stdlib-roots)]
                        [(JsonMissing)
                          (lsp-write-response id (lsp-json-array JsonListNil))]))]
                  [(JsonMissing) unit]))
              (set! result (LspContinue docs)))
            unit)
          (if (and (not handled) (string-eq method "tl/astDump"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set! result (lsp-handle-tl-ast-dump id params docs))]
                        [(JsonMissing)
                          (lsp-write-response id (lsp-json-array JsonListNil))]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/listFunctions"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-list-functions id params docs))]
                        [(JsonMissing)
                          (lsp-write-response id (lsp-json-array JsonListNil))]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/structuralReplace"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (let
                            [name-key : String "name"]
                            (match (json-object-get params (& name-key))
                              [(JsonFound name)
                                (set!
                                  result
                                  (lsp-handle-tl-structural-replace
                                    id
                                    params
                                    docs))]
                              [(JsonMissing)
                                (set!
                                  result
                                  (lsp-handle-tl-structural-replace-at
                                    id
                                    params
                                    docs))]))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/insertFunction"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-insert-function id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/deleteFunction"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-delete-function id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/structuralMove"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-structural-move id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/expandMacro"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-expand-macro id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/getTypeAt"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-get-type-at id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/findReferences"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-find-references id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/evalAtPoint"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-eval-at-point id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/appendFunction"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-append-function id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/replaceBody"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-replace-body id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/signatureHelp"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-signature-help id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/replacePattern"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-replace-pattern id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/batchEdit"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-batch-edit id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/projectSearch"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-project-search id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/rename"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set! result (lsp-handle-tl-rename id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/deleteAt"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set! result (lsp-handle-tl-delete-at id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/insertAfter"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-insert-after id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/replaceBodyAt"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-replace-body-at id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/replacePatternAt"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-replace-pattern-at id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (and (not handled) (string-eq method "tl/readFormAt"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json-object-get message (& id-key))
                  [(JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json-object-get message (& params-key))
                        [(JsonFound params)
                          (set!
                            result
                            (lsp-handle-tl-read-form-at id params docs))]
                        [(JsonMissing)
                          (lsp-write-error id -32600 "Missing params")]))]
                  [(JsonMissing) unit])))
            unit)
          (if (not handled)
            (begin
              (lsp-maybe-write-method-not-found message)
              (set! result (LspContinue docs)))
            unit)
          result))]
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

(define (lsp-replace-all-words [text : String] [old : String] [new : String]) : String
  (let
    [n : i64 (string-length text)]
    [old-len : i64 (string-length old)]
    [result : String ""]
    [i : i64 0]
    (begin
      (while (<= i (- n old-len))
        (if (and
          (string-eq (substring text i old-len) old)
          (or (= i 0) (not (lsp-ident-char? (string-ref text (- i 1)))))
          (or
            (>= (+ i old-len) n)
            (not (lsp-ident-char? (string-ref text (+ i old-len))))))
          (begin
            (set! result (string-append result new))
            (set! i (+ i old-len)))
          (begin
            (set! result (string-append result (substring text i 1)))
            (set! i (+ i 1)))))
      (while (< i n)
        (begin
          (set! result (string-append result (substring text i 1)))
          (set! i (+ i 1))))
      result)))

(define (lsp-handle-tl-rename [id : Json] [params : Json] [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (match (lsp-json-string-field params "oldName")
        [(OkLspJsonText old-name)
          (match (lsp-json-string-field params "newName")
            [(OkLspJsonText new-name)
              (if (string-eq old-name "")
                (begin
                  (lsp-write-error id -32600 "oldName cannot be empty")
                  (LspContinue docs))
                (if (string-eq new-name "")
                  (begin
                    (lsp-write-error id -32600 "newName cannot be empty")
                    (LspContinue docs))
                  (let
                    [result : String
                      (lsp-replace-all-words text old-name new-name)]
                    [formatted : String
                      (format-rules-render-source-width result 80)]
                    (begin
                      (lsp-write-response
                        id
                        (lsp-json-object2
                          "success"
                          (JsonBool true)
                          "text"
                          (JsonString formatted)))
                      (LspContinue docs)))))]
            [(MissingLspJsonText)
              (begin
                (lsp-write-error id -32600 "Missing newName parameter")
                (LspContinue docs))])]
        [(MissingLspJsonText)
          (begin
            (lsp-write-error id -32600 "Missing oldName parameter")
            (LspContinue docs))])]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

(define (lsp-handle-tl-replace-pattern
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (match (lsp-json-string-field params "name")
        [(OkLspJsonText name)
          (match (lsp-json-string-field params "oldPattern")
            [(OkLspJsonText old-pattern)
              (begin
                (when
                  (string-eq old-pattern "")
                  (begin
                    (lsp-write-error id -32600 "oldPattern cannot be empty")
                    (return (LspContinue docs))))
                (match (lsp-json-string-field params "newPattern")
                  [(OkLspJsonText new-pattern)
                    (let
                      [text-copy : String (string-copy-borrowed (& text))]
                      [decls : LspDeclList (lsp-scan-decls text-copy)]
                      [i : i64 0]
                      [n : i64 (lsp-decl-list-len decls)]
                      [found : bool false]
                      [result : String ""]
                      (begin
                        (while (and (< i n) (not found))
                          (let
                            [entry : LspDeclEntry
                              (lsp-decl-list-get
                                decls
                                i
                                (lsp-decl-entry-fallback))]
                            (if (string-eq (struct-get entry name) name)
                              (begin
                                (set! found true)
                                (let
                                  [kind : String (struct-get entry kind)]
                                  [n2 : i64 (string-length text)]
                                  (if (or
                                    (string-eq kind "function")
                                    (string-eq kind "macro"))
                                    (let
                                      [form-start-off : i64
                                        (lsp-offset-at-position
                                          text
                                          (-
                                            (struct-get entry form-start-line)
                                            1)
                                          (-
                                            (struct-get entry form-start-col)
                                            1))]
                                      [after-kw : i64
                                        (lsp-skip-space
                                          text
                                          (+ form-start-off 1)
                                          n2)]
                                      [kw-end : i64
                                        (lsp-scan-ident text after-kw n2)]
                                      [after-kw2 : i64
                                        (lsp-skip-space text kw-end n2)]
                                      (if (and
                                        (< after-kw2 n2)
                                        (= (string-ref text after-kw2) '('))
                                        (let
                                          [body-start-off : i64
                                            (lsp-find-body-start-offset
                                              text
                                              form-start-off)]
                                          [body-end-off : i64
                                            (-
                                              (lsp-offset-at-position
                                                text
                                                (-
                                                  (struct-get
                                                    entry
                                                    form-end-line)
                                                  1)
                                                (-
                                                  (struct-get
                                                    entry
                                                    form-end-col)
                                                  1))
                                              1)]
                                          [body-start-lc : LspLineCol
                                            (lsp-line-col-at-offset
                                              text
                                              body-start-off)]
                                          [body-end-lc : LspLineCol
                                            (lsp-line-col-at-offset
                                              text
                                              body-end-off)]
                                          [body-text : String
                                            (substring
                                              text
                                              body-start-off
                                              (- body-end-off body-start-off))]
                                          [replaced-body : String
                                            (lsp-replace-all-words
                                              body-text
                                              old-pattern
                                              new-pattern)]
                                          (if (not
                                            (lsp-text-is-valid-forms
                                              replaced-body))
                                            (begin
                                              (lsp-write-error
                                                id
                                                -32600
                                                (str-cat
                                                  "newPattern produces an invalid form in body: "
                                                  (lsp-validate-forms-error
                                                    replaced-body)))
                                              (set! result ""))
                                            (set!
                                              result
                                              (lsp-edit-at-pos
                                                text
                                                (struct-get body-start-lc line)
                                                (struct-get body-start-lc col)
                                                (struct-get body-end-lc line)
                                                (struct-get body-end-lc col)
                                                replaced-body))))
                                        (begin
                                          (lsp-write-error
                                            id
                                            -32600
                                            "replacePattern only supported for function/macro definitions with parameter lists")
                                          (set! result ""))))
                                    (begin
                                      (lsp-write-error
                                        id
                                        -32600
                                        "replacePattern only supported for define and defmacro")
                                      (set! result "")))))
                              (begin
                                (set! i (+ i 1))
                                unit))))
                        (if found
                          (if (string-eq result "")
                            (LspContinue docs)
                            (let
                              [formatted : String
                                (format-rules-render-source-width result 80)]
                              (begin
                                (lsp-write-response
                                  id
                                  (lsp-json-object2
                                    "success"
                                    (JsonBool true)
                                    "text"
                                    (JsonString formatted)))
                                (LspContinue docs))))
                          (begin
                            (lsp-write-error id -32600 "Declaration not found")
                            (LspContinue docs)))))]
                  [(MissingLspJsonText)
                    (begin
                      (lsp-write-error id -32600 "Missing newPattern parameter")
                      (LspContinue docs))]))]
            [(MissingLspJsonText)
              (begin
                (lsp-write-error id -32600 "Missing oldPattern parameter")
                (LspContinue docs))])]
        [(MissingLspJsonText)
          (begin
            (lsp-write-error id -32600 "Missing name parameter")
            (LspContinue docs))])]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; Pure text transformation helpers for tl/batchEdit.
(define (lsp-replace-body-text
  [text : String]
  [name : String]
  [new-body : String]) : LspEditResult
  (let
    [text-copy : String (string-copy-borrowed (& text))]
    [decls : LspDeclList (lsp-scan-decls text-copy)]
    [i : i64 0]
    [n : i64 (lsp-decl-list-len decls)]
    [found : bool false]
    [result : String ""]
    [err : String ""]
    (begin
      (while (and (< i n) (not found))
        (let
          [entry : LspDeclEntry
            (lsp-decl-list-get decls i (lsp-decl-entry-fallback))]
          (if (string-eq (struct-get entry name) name)
            (begin
              (set! found true)
              (let
                [kind : String (struct-get entry kind)]
                [n2 : i64 (string-length text)]
                (if (or (string-eq kind "function") (string-eq kind "macro"))
                  (let
                    [form-start-off : i64
                      (lsp-offset-at-position
                        text
                        (- (struct-get entry form-start-line) 1)
                        (- (struct-get entry form-start-col) 1))]
                    [after-kw : i64
                      (lsp-skip-space text (+ form-start-off 1) n2)]
                    [kw-end : i64 (lsp-scan-ident text after-kw n2)]
                    [after-kw2 : i64 (lsp-skip-space text kw-end n2)]
                    (if (and
                      (< after-kw2 n2)
                      (= (string-ref text after-kw2) '('))
                      (let
                        [body-start-off : i64
                          (lsp-find-body-start-offset text form-start-off)]
                        [body-end-off : i64
                          (-
                            (lsp-offset-at-position
                              text
                              (- (struct-get entry form-end-line) 1)
                              (- (struct-get entry form-end-col) 1))
                            1)]
                        [body-start-lc : LspLineCol
                          (lsp-line-col-at-offset text body-start-off)]
                        [body-end-lc : LspLineCol
                          (lsp-line-col-at-offset text body-end-off)]
                        (if (not (lsp-text-is-valid-forms new-body))
                          (begin
                            (set!
                              err
                              (str-cat
                                "newBody is not a valid form: "
                                (lsp-validate-forms-error new-body)))
                            (set! result ""))
                          (set!
                            result
                            (lsp-edit-at-pos
                              text
                              (struct-get body-start-lc line)
                              (struct-get body-start-lc col)
                              (struct-get body-end-lc line)
                              (struct-get body-end-lc col)
                              new-body))))
                      (set!
                        err
                        "replaceBody only supported for function/macro definitions with parameter lists")))
                  (set!
                    err
                    "replaceBody only supported for define and defmacro"))))
            (begin
              (set! i (+ i 1))
              unit))))
      (unless found (return (ErrLspEdit "Declaration not found")))
      (unless (string-eq err "") (return (ErrLspEdit err)))
      (when
        (string-eq result "")
        (return (ErrLspEdit "replaceBody: unknown error")))
      (OkLspEdit result))))

(define (lsp-replace-pattern-text
  [text : String]
  [name : String]
  [old-pattern : String]
  [new-pattern : String]) : LspEditResult
  (if (string-eq old-pattern "")
    (ErrLspEdit "oldPattern cannot be empty")
    (let
      [text-copy : String (string-copy-borrowed (& text))]
      [decls : LspDeclList (lsp-scan-decls text-copy)]
      [i : i64 0]
      [n : i64 (lsp-decl-list-len decls)]
      [found : bool false]
      [result : String ""]
      [err : String ""]
      (begin
        (while (and (< i n) (not found))
          (let
            [entry : LspDeclEntry
              (lsp-decl-list-get decls i (lsp-decl-entry-fallback))]
            (if (string-eq (struct-get entry name) name)
              (begin
                (set! found true)
                (let
                  [kind : String (struct-get entry kind)]
                  [n2 : i64 (string-length text)]
                  (if (or (string-eq kind "function") (string-eq kind "macro"))
                    (let
                      [form-start-off : i64
                        (lsp-offset-at-position
                          text
                          (- (struct-get entry form-start-line) 1)
                          (- (struct-get entry form-start-col) 1))]
                      [after-kw : i64
                        (lsp-skip-space text (+ form-start-off 1) n2)]
                      [kw-end : i64 (lsp-scan-ident text after-kw n2)]
                      [after-kw2 : i64 (lsp-skip-space text kw-end n2)]
                      (if (and
                        (< after-kw2 n2)
                        (= (string-ref text after-kw2) '('))
                        (let
                          [body-start-off : i64
                            (lsp-find-body-start-offset text form-start-off)]
                          [body-end-off : i64
                            (-
                              (lsp-offset-at-position
                                text
                                (- (struct-get entry form-end-line) 1)
                                (- (struct-get entry form-end-col) 1))
                              1)]
                          [body-start-lc : LspLineCol
                            (lsp-line-col-at-offset text body-start-off)]
                          [body-end-lc : LspLineCol
                            (lsp-line-col-at-offset text body-end-off)]
                          [body-text : String
                            (substring
                              text
                              body-start-off
                              (- body-end-off body-start-off))]
                          [replaced-body : String
                            (lsp-replace-all-words
                              body-text
                              old-pattern
                              new-pattern)]
                          (if (not (lsp-text-is-valid-forms replaced-body))
                            (begin
                              (set!
                                err
                                (str-cat
                                  "newPattern produces an invalid form in body: "
                                  (lsp-validate-forms-error replaced-body)))
                              (set! result ""))
                            (set!
                              result
                              (lsp-edit-at-pos
                                text
                                (struct-get body-start-lc line)
                                (struct-get body-start-lc col)
                                (struct-get body-end-lc line)
                                (struct-get body-end-lc col)
                                replaced-body))))
                        (set!
                          err
                          "replacePattern only supported for function/macro definitions with parameter lists")))
                    (set!
                      err
                      "replacePattern only supported for define and defmacro"))))
              (begin
                (set! i (+ i 1))
                unit))))
        (unless found (return (ErrLspEdit "Declaration not found")))
        (unless (string-eq err "") (return (ErrLspEdit err)))
        (when
          (string-eq result "")
          (return (ErrLspEdit "replacePattern: unknown error")))
        (OkLspEdit result)))))

(define (lsp-structural-replace-text
  [text : String]
  [name : String]
  [new-text : String]) : LspEditResult
  (if (not (lsp-text-is-valid-forms new-text))
    (ErrLspEdit
      (str-cat
        "newText is not valid form(s): "
        (lsp-validate-forms-error new-text)))
    (let
      [text-copy : String (string-copy-borrowed (& text))]
      [decls : LspDeclList (lsp-scan-decls text-copy)]
      [i : i64 0]
      [n : i64 (lsp-decl-list-len decls)]
      [found : bool false]
      [result : String ""]
      (begin
        (while (and (< i n) (not found))
          (let
            [entry : LspDeclEntry
              (lsp-decl-list-get decls i (lsp-decl-entry-fallback))]
            (if (string-eq (struct-get entry name) name)
              (begin
                (set!
                  result
                  (lsp-edit-at-pos
                    text
                    (struct-get entry form-start-line)
                    (struct-get entry form-start-col)
                    (struct-get entry form-end-line)
                    (struct-get entry form-end-col)
                    new-text))
                (set! found true)
                unit)
              (begin
                (set! i (+ i 1))
                unit))))
        (if found
          (OkLspEdit result)
          (ErrLspEdit "Declaration not found"))))))

(define (lsp-batch-edit-step
  [text : String]
  [edit-kind : String]
  [edit-params : Json]) : LspEditResult
  (cond
    [(string-eq edit-kind "replace-body")
      (match (lsp-json-string-field edit-params "name")
        [(OkLspJsonText name)
          (match (lsp-json-string-field edit-params "newBody")
            [(OkLspJsonText new-body)
              (lsp-replace-body-text text name new-body)]
            [(MissingLspJsonText) (ErrLspEdit "replace-body: missing newBody")])]
        [(MissingLspJsonText) (ErrLspEdit "replace-body: missing name")])]
    [(string-eq edit-kind "replace-pattern")
      (match (lsp-json-string-field edit-params "name")
        [(OkLspJsonText name)
          (match (lsp-json-string-field edit-params "oldPattern")
            [(OkLspJsonText old-pattern)
              (match (lsp-json-string-field edit-params "newPattern")
                [(OkLspJsonText new-pattern)
                  (lsp-replace-pattern-text text name old-pattern new-pattern)]
                [(MissingLspJsonText)
                  (ErrLspEdit "replace-pattern: missing newPattern")])]
            [(MissingLspJsonText)
              (ErrLspEdit "replace-pattern: missing oldPattern")])]
        [(MissingLspJsonText) (ErrLspEdit "replace-pattern: missing name")])]
    [(string-eq edit-kind "structural-replace")
      (match (lsp-json-string-field edit-params "name")
        [(OkLspJsonText name)
          (match (lsp-json-string-field edit-params "newText")
            [(OkLspJsonText new-text)
              (lsp-structural-replace-text text name new-text)]
            [(MissingLspJsonText)
              (ErrLspEdit "structural-replace: missing newText")])]
        [(MissingLspJsonText) (ErrLspEdit "structural-replace: missing name")])]
    [else (ErrLspEdit (str-cat "Unknown edit kind: " edit-kind))]))

(define (lsp-batch-edit-apply [text : String] [edits : JsonList]) : LspEditResult
  (match edits
    [(JsonListNil) (OkLspEdit text)]
    [(JsonListCons first rest)
      (match first
        [(JsonObject _)
          (match (lsp-json-string-field first "kind")
            [(OkLspJsonText kind)
              (match (lsp-batch-edit-step text kind first)
                [(OkLspEdit new-text)
                  (lsp-batch-edit-apply new-text (box-get rest))]
                [(ErrLspEdit err) (ErrLspEdit err)])]
            [(MissingLspJsonText) (ErrLspEdit "Edit missing 'kind' field")])]
        [_ (ErrLspEdit "Edit is not a JSON object")])]))

(define (lsp-handle-tl-batch-edit
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (let
        [edits-key : String "edits"]
        (match (json-object-get params (& edits-key))
          [(JsonFound edits-value)
            (match edits-value
              [(JsonArray edits-list)
                (match (lsp-batch-edit-apply text (box-get edits-list))
                  [(OkLspEdit result-text)
                    (let
                      [formatted : String
                        (format-rules-render-source-width result-text 80)]
                      (begin
                        (lsp-write-response
                          id
                          (lsp-json-object2
                            "success"
                            (JsonBool true)
                            "text"
                            (JsonString formatted)))
                        (LspContinue docs)))]
                  [(ErrLspEdit err)
                    (begin
                      (lsp-write-error id -32600 err)
                      (LspContinue docs))])]
              [_
                (begin
                  (lsp-write-error id -32600 "edits must be an array")
                  (LspContinue docs))])]
          [(JsonMissing)
            (begin
              (lsp-write-error id -32600 "Missing edits parameter")
              (LspContinue docs))]))]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

(test
  lsp-validate-forms-smoke
  (unless
    (lsp-validate-forms-smoke-ok?)
    (panic "lsp-validate-forms-smoke failed")))

(test
  lsp-validate-forms-line-context
  (unless
    (lsp-validate-forms-line-context-ok?)
    (panic "lsp-validate-forms-line-context failed")))

;; Position-based editing helpers
;; Find start index of innermost form containing offset. Returns -1 if not found.
;; Uses string-ref on literal parens since char literals for parens confuse the parser.
(define (lsp-find-form-at-offset [text : String] [offset : i64]) : i64
  (if (or (< offset 0) (>= offset (string-length text)))
    -1
    (let
      [i : i64 offset]
      [depth : i64 0]
      [result : i64 -1]
      (begin
        (while (and (>= i 0) (= result -1))
          (let
            [c : char (string-ref text i)]
            (begin
              (if (= c (string-ref ")" 0))
                (set! depth (+ depth 1))
                (if (= c (string-ref "(" 0))
                  (if (= depth 0)
                    (set! result i)
                    (set! depth (- depth 1)))
                  unit))
              (set! i (- i 1)))))
        result))))

;; Find end index (exclusive) of form starting at start. Returns -1 if unterminated.
(define (lsp-find-form-end-at-offset [text : String] [start : i64]) : i64
  (let
    [n : i64 (string-length text)]
    (if (or
      (< start 0)
      (>= start n)
      (not (= (string-ref text start) (string-ref "(" 0))))
      -1
      (let
        [i : i64 (+ start 1)]
        [depth : i64 1]
        [result : i64 -1]
        (begin
          (while (and (< i n) (= result -1))
            (let
              [c : char (string-ref text i)]
              (begin
                (if (= c (string-ref "(" 0))
                  (set! depth (+ depth 1))
                  (if (= c (string-ref ")" 0))
                    (begin
                      (set! depth (- depth 1))
                      (if (= depth 0)
                        (set! result (+ i 1))
                        unit))
                    unit))
                (set! i (+ i 1)))))
          result)))))

;; Replace form at position (line, col) with new-text. Returns original text if position invalid.
(define (lsp-replace-form-at-position
  [text : String]
  [line : i64]
  [col : i64]
  [new-text : String]) : String
  (if (or (< line 0) (< col 0))
    text
    (let
      [offset : i64 (lsp-offset-at-position text line col)]
      (if (>= offset (string-length text))
        text
        (let
          [form-start : i64 (lsp-find-form-at-offset text offset)]
          (if (= form-start -1)
            text
            (let
              [form-end : i64 (lsp-find-form-end-at-offset text form-start)]
              (if (or (= form-end -1) (<= form-end offset))
                text
                (let
                  [before : String (substring text 0 form-start)]
                  [after : String
                    (substring text form-end (- (string-length text) form-end))]
                  (str-cat before new-text after))))))))))

;; tl/structuralReplaceAt - Replace form at position (line, character)
(define (lsp-handle-tl-structural-replace-at
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (let
        [pos-key : String "position"]
        (match (json-object-get params (& pos-key))
          [(JsonFound position)
            (match (lsp-json-string-field params "newText")
              [(OkLspJsonText new-text)
                (let
                  [line : i64 (lsp-json-int-field-default position "line" 0)]
                  [col : i64
                    (lsp-json-int-field-default position "character" 0)]
                  [replaced : String
                    (lsp-replace-form-at-position text line col new-text)]
                  [formatted : String
                    (format-rules-render-source-width replaced 80)]
                  (begin
                    (lsp-write-response
                      id
                      (lsp-json-object2
                        "success"
                        (JsonBool true)
                        "text"
                        (JsonString formatted)))
                    (LspContinue docs)))]
              [(MissingLspJsonText)
                (begin
                  (lsp-write-error id -32600 "Missing newText parameter")
                  (LspContinue docs))])]
          [(JsonMissing)
            (begin
              (lsp-write-error id -32600 "Missing position parameter")
              (LspContinue docs))]))]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; Find the start of the outer form enclosing the form at start.
;; outer = 0 means return start itself.
(define (lsp-find-outer-form-start [text : String] [start : i64] [outer : i64]) : i64
  (if (<= outer 0)
    start
    (if (<= start 0)
      -1
      (let
        [prev-start : i64 (lsp-find-form-at-offset text (- start 1))]
        (if (= prev-start -1)
          -1
          (lsp-find-outer-form-start text prev-start (- outer 1)))))))

;; Read the form at a given (line, col), optionally going outer levels up.
(define (lsp-read-form-at-position
  [text : String]
  [line : i64]
  [col : i64]
  [outer : i64]) : String
  (if (or (< line 0) (< col 0))
    ""
    (let
      [offset : i64 (lsp-offset-at-position text line col)]
      (if (>= offset (string-length text))
        ""
        (let
          [form-start : i64 (lsp-find-form-at-offset text offset)]
          (if (= form-start -1)
            ""
            (let
              [actual-start : i64
                (lsp-find-outer-form-start text form-start outer)]
              (if (= actual-start -1)
                ""
                (let
                  [form-end : i64
                    (lsp-find-form-end-at-offset text actual-start)]
                  (if (= form-end -1)
                    ""
                    (substring text actual-start (- form-end actual-start))))))))))))

;; tl/deleteAt - Delete the form at a given position
(define (lsp-handle-tl-delete-at
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (let
        [pos-key : String "position"]
        (match (json-object-get params (& pos-key))
          [(JsonFound position)
            (let
              [line : i64 (lsp-json-int-field-default position "line" 0)]
              [col : i64 (lsp-json-int-field-default position "character" 0)]
              (if (or (< line 0) (< col 0))
                (begin
                  (lsp-write-error id -32600 "No form found at position")
                  (LspContinue docs))
                (let
                  [offset : i64 (lsp-offset-at-position text line col)]
                  (if (>= offset (string-length text))
                    (begin
                      (lsp-write-error id -32600 "No form found at position")
                      (LspContinue docs))
                    (let
                      [form-start : i64 (lsp-find-form-at-offset text offset)]
                      (if (= form-start -1)
                        (begin
                          (lsp-write-error
                            id
                            -32600
                            "No form found at position")
                          (LspContinue docs))
                        (let
                          [form-end : i64
                            (lsp-find-form-end-at-offset text form-start)]
                          (if (= form-end -1)
                            (begin
                              (lsp-write-error
                                id
                                -32600
                                "No form found at position")
                              (LspContinue docs))
                            (let
                              [before : String (substring text 0 form-start)]
                              [after : String
                                (substring
                                  text
                                  form-end
                                  (- (string-length text) form-end))]
                              [deleted : String (str-cat before after)]
                              [formatted : String
                                (format-rules-render-source-width deleted 80)]
                              (begin
                                (lsp-write-response
                                  id
                                  (lsp-json-object2
                                    "success"
                                    (JsonBool true)
                                    "text"
                                    (JsonString formatted)))
                                (LspContinue docs)))))))))))]
          [(JsonMissing)
            (begin
              (lsp-write-error id -32600 "Missing position parameter")
              (LspContinue docs))]))]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; tl/insertAfter - Insert a new form after the form at a given position
(define (lsp-handle-tl-insert-after
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (match (lsp-json-string-field params "newText")
        [(OkLspJsonText new-text)
          (let
            [pos-key : String "position"]
            (match (json-object-get params (& pos-key))
              [(JsonFound position)
                (let
                  [line : i64 (lsp-json-int-field-default position "line" 0)]
                  [col : i64
                    (lsp-json-int-field-default position "character" 0)]
                  (if (or (< line 0) (< col 0))
                    (begin
                      (lsp-write-error id -32600 "No form found at position")
                      (LspContinue docs))
                    (let
                      [offset : i64 (lsp-offset-at-position text line col)]
                      (if (>= offset (string-length text))
                        (begin
                          (lsp-write-error
                            id
                            -32600
                            "No form found at position")
                          (LspContinue docs))
                        (let
                          [form-start : i64
                            (lsp-find-form-at-offset text offset)]
                          (if (= form-start -1)
                            (begin
                              (lsp-write-error
                                id
                                -32600
                                "No form found at position")
                              (LspContinue docs))
                            (let
                              [form-end : i64
                                (lsp-find-form-end-at-offset text form-start)]
                              (if (= form-end -1)
                                (begin
                                  (lsp-write-error
                                    id
                                    -32600
                                    "No form found at position")
                                  (LspContinue docs))
                                (let
                                  [before : String (substring text 0 form-end)]
                                  [after : String
                                    (substring
                                      text
                                      form-end
                                      (- (string-length text) form-end))]
                                  [new-doc-text : String
                                    (str-cat before "\n" new-text after)]
                                  [formatted : String
                                    (format-rules-render-source-width
                                      new-doc-text
                                      80)]
                                  (begin
                                    (lsp-write-response
                                      id
                                      (lsp-json-object2
                                        "success"
                                        (JsonBool true)
                                        "text"
                                        (JsonString formatted)))
                                    (LspContinue docs)))))))))))]
              [(JsonMissing)
                (begin
                  (lsp-write-error id -32600 "Missing position parameter")
                  (LspContinue docs))]))]
        [(MissingLspJsonText)
          (begin
            (lsp-write-error id -32600 "Missing newText parameter")
            (LspContinue docs))])]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

(define (lsp-is-whitespace [c : char]) : bool
  (lsp-ws? c))

;; Helper: Extract function name from a define or defmacro form.
(define (lsp-extract-define-name [text : String]) : String
  (let
    [n : i64 (string-length text)]
    (begin
      (when (= n 0) (return ""))
      (let
        [open : i64 (lsp-skip-space text 0 n)]
        (begin
          (when
            (or (>= open n) (not (= (string-ref text open) (string-ref "(" 0))))
            (return ""))
          (let
            [kw-start : i64 (lsp-skip-space text (+ open 1) n)]
            [kw-end : i64 0]
            [kw : String ""]
            (begin
              (set! kw-end (lsp-scan-ident text kw-start n))
              (when (= kw-end kw-start) (return ""))
              (set! kw (substring text kw-start (- kw-end kw-start)))
              (when
                (not (or (string-eq kw "define") (string-eq kw "defmacro")))
                (return ""))
              (let
                [name-start : i64 (lsp-skip-space text kw-end n)]
                (begin
                  (when (>= name-start n) (return ""))
                  (if (= (string-ref text name-start) (string-ref "(" 0))
                    (set! name-start (lsp-skip-space text (+ name-start 1) n))
                    unit)
                  (let
                    [name-end : i64 (lsp-scan-ident text name-start n)]
                    (if (= name-end name-start)
                      ""
                      (substring text name-start (- name-end name-start)))))))))))))

;; Helper: Find form at position and extract its name.
(define (lsp-find-and-extract-name [text : String] [line : i64] [col : i64]) : String
  (if (or (< line 0) (< col 0))
    ""
    (let
      [offset : i64 (lsp-offset-at-position text line col)]
      (if (>= offset (string-length text))
        ""
        (let
          [form-start : i64 (lsp-find-form-at-offset text offset)]
          (if (= form-start -1)
            ""
            (let
              [form-end : i64 (lsp-find-form-end-at-offset text form-start)]
              (if (= form-end -1)
                ""
                (let
                  [form-text : String
                    (substring text form-start (- form-end form-start))]
                  (lsp-extract-define-name form-text))))))))))

;; tl/replaceBodyAt - Replace body of function at a given position
(define (lsp-handle-tl-replace-body-at
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (let
        [pos-key : String "position"]
        (match (json-object-get params (& pos-key))
          [(JsonFound position)
            (let
              [line : i64 (lsp-json-int-field-default position "line" 0)]
              [col : i64 (lsp-json-int-field-default position "character" 0)]
              [name : String (lsp-find-and-extract-name text line col)]
              (if (= (string-length name) 0)
                (begin
                  (lsp-write-error
                    id
                    -32600
                    "Could not extract function name at position")
                  (LspContinue docs))
                (match (lsp-json-string-field params "newBody")
                  [(OkLspJsonText new-body)
                    (match (lsp-replace-body-text text name new-body)
                      [(OkLspEdit replaced)
                        (let
                          [formatted : String
                            (format-rules-render-source-width replaced 80)]
                          (begin
                            (lsp-write-response
                              id
                              (lsp-json-object2
                                "success"
                                (JsonBool true)
                                "text"
                                (JsonString formatted)))
                            (LspContinue docs)))]
                      [(ErrLspEdit message)
                        (begin
                          (lsp-write-error id -32600 message)
                          (LspContinue docs))])]
                  [(MissingLspJsonText)
                    (begin
                      (lsp-write-error id -32600 "Missing newBody parameter")
                      (LspContinue docs))])))]
          [(JsonMissing)
            (begin
              (lsp-write-error id -32600 "Missing position parameter")
              (LspContinue docs))]))]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; tl/replacePatternAt - Replace pattern in function at a given position
(define (lsp-handle-tl-replace-pattern-at
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (let
        [pos-key : String "position"]
        (match (json-object-get params (& pos-key))
          [(JsonFound position)
            (let
              [line : i64 (lsp-json-int-field-default position "line" 0)]
              [col : i64 (lsp-json-int-field-default position "character" 0)]
              [name : String (lsp-find-and-extract-name text line col)]
              (if (= (string-length name) 0)
                (begin
                  (lsp-write-error
                    id
                    -32600
                    "Could not extract function name at position")
                  (LspContinue docs))
                (match (lsp-json-string-field params "oldPattern")
                  [(OkLspJsonText old-pattern)
                    (match (lsp-json-string-field params "newPattern")
                      [(OkLspJsonText new-pattern)
                        (match (lsp-replace-pattern-text
                          text
                          name
                          old-pattern
                          new-pattern)
                          [(OkLspEdit replaced)
                            (let
                              [formatted : String
                                (format-rules-render-source-width replaced 80)]
                              (begin
                                (lsp-write-response
                                  id
                                  (lsp-json-object2
                                    "success"
                                    (JsonBool true)
                                    "text"
                                    (JsonString formatted)))
                                (LspContinue docs)))]
                          [(ErrLspEdit message)
                            (begin
                              (lsp-write-error id -32600 message)
                              (LspContinue docs))])]
                      [(MissingLspJsonText)
                        (begin
                          (lsp-write-error
                            id
                            -32600
                            "Missing newPattern parameter")
                          (LspContinue docs))])]
                  [(MissingLspJsonText)
                    (begin
                      (lsp-write-error id -32600 "Missing oldPattern parameter")
                      (LspContinue docs))])))]
          [(JsonMissing)
            (begin
              (lsp-write-error id -32600 "Missing position parameter")
              (LspContinue docs))]))]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))

;; tl/readFormAt - Read the form at a given position
(define (lsp-handle-tl-read-form-at
  [id : Json]
  [params : Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(FoundLspDocument path text _)
      (let
        [pos-key : String "position"]
        (match (json-object-get params (& pos-key))
          [(JsonFound position)
            (let
              [line : i64 (lsp-json-int-field-default position "line" 0)]
              [col : i64 (lsp-json-int-field-default position "character" 0)]
              [outer : i64 (lsp-json-int-field-default params "outer" 0)]
              [form-text : String
                (lsp-read-form-at-position text line col outer)]
              (if (= (string-length form-text) 0)
                (begin
                  (lsp-write-error id -32600 "No form found at position")
                  (LspContinue docs))
                (begin
                  (lsp-write-response
                    id
                    (lsp-json-object2
                      "success"
                      (JsonBool true)
                      "form"
                      (JsonString form-text)))
                  (LspContinue docs))))]
          [(JsonMissing)
            (begin
              (lsp-write-error id -32600 "Missing position parameter")
              (LspContinue docs))]))]
    [(MissingLspDocument)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspContinue docs))]))