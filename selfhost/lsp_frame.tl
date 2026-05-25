;; lsp_frame.tl - Selfhost LSP stdio framing and JSON-RPC slice (#592/#789).
;;
;; This driver owns JSON-RPC/LSP Content-Length framing over stdin/stdout plus
;; the first selfhost protocol loop: initialize/shutdown, document tracking, and
;; diagnostics for full-document open/change notifications.
(import "stdlib/io.tl")

(import "stdlib/json.tl")

(import "compiler_check_core.tl")

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
  (FoundLspDocument String String)
  (MissingLspDocument))

(defenum LspDocumentList
  (LspDocumentNil)
  (LspDocumentCons String String String LspDocumentList))

(defenum LspHandleResult
  (LspContinue LspDocumentList)
  (LspExit LspDocumentList))

(define (lsp-frame-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (lsp-frame-cat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (string-append a (string-append b (string-append c (string-append d e)))))

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
      (if clean-eof
        LspFrameEof
        (if (not (string-eq err ""))
          (LspFrameErr err)
          (if (< content-length 0)
            (LspFrameErr "lsp: missing Content-Length")
            (let
              [payload-read : StdinRead (stdin-read-bytes content-length)]
              [payload : String (stdin-read-text payload-read)]
              (if (and
                (stdin-read-eof? payload-read)
                (< (string-length payload) content-length))
                (LspFrameErr "lsp: truncated payload")
                (LspFrameOk payload)))))))))

(define (lsp-frame-write-body [body : String]) : unit
  (begin
    (stdout-write
      (lsp-frame-cat5
        "Content-Length: "
        (int->string (string-length body))
        "\r\n\r\n"
        body
        ""))
    (stdout-flush)))

(define (lsp-json-number [value : i64]) : Json
  (JsonNumber (int->string value)))

(define (lsp-json-rpc-member [rest : JsonMemberList]) : JsonMemberList
  (JsonMemberListCons "jsonrpc" (JsonString "2.0") rest))

(define (lsp-json-object1 [k : String] [v : Json]) : Json
  (JsonObject (JsonMemberListCons k v JsonMemberListNil)))

(define (lsp-json-object2 [k1 : String] [v1 : Json] [k2 : String] [v2 : Json]) : Json
  (JsonObject
    (JsonMemberListCons k1 v1 (JsonMemberListCons k2 v2 JsonMemberListNil))))

(define (lsp-json-object4
  [k1 : String]
  [v1 : Json]
  [k2 : String]
  [v2 : Json]
  [k3 : String]
  [v3 : Json]
  [k4 : String]
  [v4 : Json]) : Json
  (JsonObject
    (JsonMemberListCons
      k1
      v1
      (JsonMemberListCons
        k2
        v2
        (JsonMemberListCons k3 v3 (JsonMemberListCons k4 v4 JsonMemberListNil))))))

(define (lsp-json-string-field [value : Json] [key : String]) : LspJsonText
  (match (json-object-get value key)
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
    (JsonObject
      (lsp-json-rpc-member
        (JsonMemberListCons
          "id"
          id
          (JsonMemberListCons "result" result JsonMemberListNil))))))

(define (lsp-write-error [id : Json] [code : i64] [message : String]) : unit
  (lsp-write-json
    (JsonObject
      (lsp-json-rpc-member
        (JsonMemberListCons
          "id"
          id
          (JsonMemberListCons
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
    (lsp-json-object1
      "textDocumentSync"
      (lsp-json-object2
        "openClose"
        (JsonBool true)
        "change"
        (lsp-json-number 1)))
    "serverInfo"
    (lsp-json-object2
      "name"
      (JsonString "typelisp")
      "version"
      (JsonString "selfhost"))))

(define (lsp-documents-set
  [docs : LspDocumentList]
  [uri : String]
  [path : String]
  [text : String]) : LspDocumentList
  (match docs
    [(LspDocumentNil) (LspDocumentCons uri path text LspDocumentNil)]
    [(LspDocumentCons item-uri item-path item-text rest)
      (if (string-eq item-uri uri)
        (LspDocumentCons uri path text rest)
        (LspDocumentCons
          item-uri
          item-path
          item-text
          (lsp-documents-set rest uri path text)))]))

(define (lsp-documents-remove [docs : LspDocumentList] [uri : String]) : LspDocumentList
  (match docs
    [(LspDocumentNil) LspDocumentNil]
    [(LspDocumentCons item-uri item-path item-text rest)
      (if (string-eq item-uri uri)
        rest
        (LspDocumentCons
          item-uri
          item-path
          item-text
          (lsp-documents-remove rest uri)))]))

(define (lsp-documents-lookup [docs : LspDocumentList] [uri : String]) : LspDocumentLookup
  (match docs
    [(LspDocumentNil) MissingLspDocument]
    [(LspDocumentCons item-uri item-path item-text rest)
      (if (string-eq item-uri uri)
        (FoundLspDocument item-path item-text)
        (lsp-documents-lookup rest uri))]))

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
    (if (and
      (> n 2)
      (and (= (string-ref path 0) #/') (= (string-ref path 2) #:')))
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
    (or
      (and (>= code 97) (<= code 122))
      (or
        (and (>= code 48) (<= code 57))
        (or
          (= code 45)
          (or
            (= code 46)
            (or (= code 95) (or (= code 126) (or (= code 47) (= code 58))))))))))

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
                (lsp-frame-cat3
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

(define (lsp-diagnostic-code [message : String]) : String
  (if (lsp-frame-starts-with? message "parse:")
    "E0100"
    (if (lsp-frame-starts-with? message "typecheck:")
      "E0200"
      "")))

(define (lsp-diagnostic [line : i64] [col : i64] [message : String]) : Json
  (let
    [code : String (lsp-diagnostic-code message)]
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
      (JsonObject
        (JsonMemberListCons
          "range"
          (lsp-range line col)
          (JsonMemberListCons
            "severity"
            (lsp-json-number 1)
            (JsonMemberListCons
              "source"
              (JsonString "typelisp")
              (JsonMemberListCons
                "code"
                (JsonString code)
                (JsonMemberListCons
                  "message"
                  (JsonString message)
                  JsonMemberListNil)))))))))

(define (lsp-compiler-diagnostic [diag : CompilerDiagnostic]) : Json
  (lsp-diagnostic
    (compiler-diagnostic-line diag)
    (compiler-diagnostic-col diag)
    (compiler-diagnostic-message diag)))

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
    (JsonObject
      (lsp-json-rpc-member
        (JsonMemberListCons
          "method"
          (JsonString "textDocument/publishDiagnostics")
          (JsonMemberListCons
            "params"
            (lsp-json-object2
              "uri"
              (JsonString uri)
              "diagnostics"
              (JsonArray diagnostics))
            JsonMemberListNil))))))

(define (lsp-publish-uri-diagnostic [uri : String] [message : String]) : unit
  (lsp-publish-diagnostics
    uri
    (JsonListCons (lsp-diagnostic 1 1 message) JsonListNil)))

(define (lsp-analyze-document
  [uri : String]
  [path : String]
  [text : String]
  [stdlib-roots : CompilerLoadRootList]) : unit
  (match (compiler-check-source-with-roots path text stdlib-roots)
    [(OkCompilerCheck _) (lsp-publish-diagnostics uri JsonListNil)]
    [(ErrCompilerCheck diag)
      (let
        [diag-uri : String (lsp-diagnostic-uri uri path diag)]
        (begin
          (if (string-eq diag-uri uri)
            unit
            (lsp-publish-diagnostics uri JsonListNil))
          (lsp-publish-diagnostics
            diag-uri
            (JsonListCons (lsp-compiler-diagnostic diag) JsonListNil))))]))

(define (lsp-first-change-text [params : Json]) : LspJsonText
  (match (json-object-get params "contentChanges")
    [(JsonFound value)
      (match value
        [(JsonArray items)
          (match items
            [(JsonListNil) MissingLspJsonText]
            [(JsonListCons first _) (lsp-json-string-field first "text")])]
        [_ MissingLspJsonText])]
    [(JsonMissing) MissingLspJsonText]))

(define (lsp-did-open
  [params : Json]
  [docs : LspDocumentList]
  [stdlib-roots : CompilerLoadRootList]) : LspHandleResult
  (match (json-object-get params "textDocument")
    [(JsonFound document)
      (match (lsp-json-string-field document "uri")
        [(OkLspJsonText uri)
          (let
            [text : String (lsp-json-string-field-default document "text" "")]
            (match (lsp-file-uri-to-path uri)
              [(OkLspUriPath path)
                (let
                  [next-docs : LspDocumentList
                    (lsp-documents-set docs uri path text)]
                  (begin
                    (lsp-analyze-document uri path text stdlib-roots)
                    (LspContinue next-docs)))]
              [(ErrLspUriPath message)
                (begin
                  (lsp-publish-uri-diagnostic uri message)
                  (LspContinue docs))]))]
        [(MissingLspJsonText) (LspContinue docs)])]
    [(JsonMissing) (LspContinue docs)]))

(define (lsp-did-change
  [params : Json]
  [docs : LspDocumentList]
  [stdlib-roots : CompilerLoadRootList]) : LspHandleResult
  (match (json-object-get params "textDocument")
    [(JsonFound document)
      (match (lsp-json-string-field document "uri")
        [(OkLspJsonText uri)
          (match (lsp-first-change-text params)
            [(OkLspJsonText text)
              (match (lsp-file-uri-to-path uri)
                [(OkLspUriPath path)
                  (let
                    [next-docs : LspDocumentList
                      (lsp-documents-set docs uri path text)]
                    (begin
                      (lsp-analyze-document uri path text stdlib-roots)
                      (LspContinue next-docs)))]
                [(ErrLspUriPath message)
                  (begin
                    (lsp-publish-uri-diagnostic uri message)
                    (LspContinue docs))])]
            [(MissingLspJsonText)
              (match (lsp-documents-lookup docs uri)
                [(FoundLspDocument path text)
                  (begin
                    (lsp-analyze-document uri path text stdlib-roots)
                    (LspContinue docs))]
                [(MissingLspDocument) (LspContinue docs)])])]
        [(MissingLspJsonText) (LspContinue docs)])]
    [(JsonMissing) (LspContinue docs)]))

(define (lsp-did-close [params : Json] [docs : LspDocumentList]) : LspHandleResult
  (match (json-object-get params "textDocument")
    [(JsonFound document)
      (match (lsp-json-string-field document "uri")
        [(OkLspJsonText uri)
          (begin
            (lsp-publish-diagnostics uri JsonListNil)
            (LspContinue (lsp-documents-remove docs uri)))]
        [(MissingLspJsonText) (LspContinue docs)])]
    [(JsonMissing) (LspContinue docs)]))

(define (lsp-maybe-write-method-not-found [message : Json]) : unit
  (match (json-object-get message "id")
    [(JsonFound id) (lsp-write-error id -32601 "Method not found")]
    [(JsonMissing) unit]))

(define (lsp-handle-message
  [message : Json]
  [docs : LspDocumentList]
  [stdlib-roots : CompilerLoadRootList]) : LspHandleResult
  (match (lsp-json-string-field message "method")
    [(OkLspJsonText method)
      (if (string-eq method "initialize")
        (begin
          (match (json-object-get message "id")
            [(JsonFound id) (lsp-write-response id (lsp-initialize-result))]
            [(JsonMissing) unit])
          (LspContinue docs))
        (if (string-eq method "initialized")
          (LspContinue docs)
          (if (string-eq method "shutdown")
            (begin
              (match (json-object-get message "id")
                [(JsonFound id) (lsp-write-response id JsonNull)]
                [(JsonMissing) unit])
              (LspContinue docs))
            (if (string-eq method "exit")
              (LspExit docs)
              (if (string-eq method "textDocument/didOpen")
                (match (json-object-get message "params")
                  [(JsonFound params) (lsp-did-open params docs stdlib-roots)]
                  [(JsonMissing) (LspContinue docs)])
                (if (string-eq method "textDocument/didChange")
                  (match (json-object-get message "params")
                    [(JsonFound params)
                      (lsp-did-change params docs stdlib-roots)]
                    [(JsonMissing) (LspContinue docs)])
                  (if (string-eq method "textDocument/didClose")
                    (match (json-object-get message "params")
                      [(JsonFound params) (lsp-did-close params docs)]
                      [(JsonMissing) (LspContinue docs)])
                    (begin
                      (lsp-maybe-write-method-not-found message)
                      (LspContinue docs)))))))))]
    [(MissingLspJsonText) (LspContinue docs)]))

(define (lsp-stdlib-roots [idx : i64]) : CompilerLoadRootList
  (if (>= idx (arg-count))
    CompilerLoadRootNil
    (if (string-eq (arg idx) "--stdlib-root")
      (if (< (+ idx 1) (arg-count))
        (CompilerLoadRootCons (arg (+ idx 1)) (lsp-stdlib-roots (+ idx 2)))
        CompilerLoadRootNil)
      (lsp-stdlib-roots (+ idx 1)))))

(define (lsp-frame-run) : i64
  (let
    [done : bool false]
    [status : i64 0]
    [docs : LspDocumentList LspDocumentNil]
    [stdlib-roots : CompilerLoadRootList (lsp-stdlib-roots 1)]
    (begin
      (while (not done)
        (match (lsp-frame-read-message)
          [(LspFrameOk payload)
            (match (json-parse payload)
              [(OkJson message)
                (match (lsp-handle-message message docs stdlib-roots)
                  [(LspContinue next-docs) (set! docs next-docs)]
                  [(LspExit next-docs)
                    (begin
                      (set! docs next-docs)
                      (set! done true))])]
              [(ErrJson message) (lsp-write-parse-error message)])]
          [(LspFrameEof) (set! done true)]
          [(LspFrameErr message)
            (begin
              (lsp-write-parse-error message)
              (stderr-write message)
              (set! status 1)
              (set! done true))]))
      status)))

(define (main) : i64
  (lsp-frame-run))