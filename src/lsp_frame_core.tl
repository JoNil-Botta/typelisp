;; lsp_frame_core.tl - Main-free selfhost LSP stdio framing and JSON-RPC slice (#592/#789).
;;
;; This driver owns JSON-RPC/LSP Content-Length framing over stdin/stdout plus
;; the first selfhost protocol loop: initialize/shutdown, document tracking, and
;; diagnostics for full-document open/change notifications.
(import stdlib.fs)
(import stdlib.io)
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.json)
(import stdlib.vector)
(import "compiler_check_core.tl")
(import "compiler_load.tl")
(import "format_rules.tl")
(import "lint_driver_core.tl")
(import "lsp_vector_families.tl")
(import stdlib.string)
(import token)
(import sym_i64_env)

(define (lsp-str2 [a : String] [b : String]) : String
  (string.string-concat3 a b ""))

(define (lsp-str3 [a : String] [b : String] [c : String]) : String
  (string.string-concat3 a b c))

(define (lsp-str4 [a : String] [b : String] [c : String] [d : String]) : String
  (string.string-concat4 a b c d))

(define (lsp-str5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (string.string-concat5 a b c d e))

(define (lsp-str7
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]
  [g : String]) : String
  (string.string-concat3 (lsp-str4 a b c d) (lsp-str3 e f g) ""))

(defenum LspFrameRead
  (Ok String)
  (Eof)
  (Err String))

(defenum LspLengthParse
  (Ignore)
  (Ok i64)
  (Err String))

(defenum LspStringResult
  (Ok String)
  (Err String))

(defenum LspUriPath
  (Ok String)
  (Err String))

(defenum LspJsonText
  (Ok String)
  (Missing))

(defenum LspDocumentLookup
  (Found String String String)
  (Missing))

(defenum LspDocumentDeclsLookup
  (Found String String String LspDeclList)
  (Missing))

(defenum LspHandleResult
  (Continue LspDocuments)
  (Exit LspDocuments))

(defstruct LspLineCol
  (line i64)
  (col i64))

(defstruct LspLineColCache
  (offset i64)
  (line i64)
  (col i64))

(defenum LspDefLocation
  (Found String i64 i64 i64)
  (Missing))

(defenum LspImportTarget
  (Found String i64 i64)
  (Missing))

(defenum LspDefSource
  (Found String i64)
  (Missing))

(defenum LspVariantHit
  (Found String String)
  (Missing))

(defenum LspEditResult
  (Ok String)
  (Err String))

(defenum LspFunctionList
  (Ok (Array String))
  (Err String))

(defenum LspValidationResult
  (Valid)
  (Invalid i64 i64 String String))

(define (lsp-frame-space? [c : char]) : bool
  (or (= c ' ') (= c '\t')))

(define (lsp-frame-trim-right-space-cr [text : String]) : String
  (let
    [i : i64 (string.string-length text)]
    [end : i64 (string.string-length text)]
    [done : bool false]
    (begin
      (while (> i 0)
        (if done
          (set! i 0)
          (let
            [c : char (string.string-ref text (- i 1))]
            (if (or (lsp-frame-space? c) (= c '\r'))
              (begin
                (set! end (- i 1))
                (set! i (- i 1)))
              (set! done true)))))
      (string.substring text 0 end))))

(define (lsp-frame-trim-left-space [text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [start : i64 0]
    [done : bool false]
    (begin
      (while (< i n)
        (if done
          (set! i n)
          (if (lsp-frame-space? (string.string-ref text i))
            (begin
              (set! start (+ i 1))
              (set! i (+ i 1)))
            (set! done true))))
      (string.substring text start (- n start)))))

(define (lsp-frame-trim-header-value [text : String]) : String
  (lsp-frame-trim-left-space (lsp-frame-trim-right-space-cr text)))

(define (lsp-frame-starts-with? [text : String] [prefix : String]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [prefix-len : i64 (string.string-length prefix)]
    [i : i64 0]
    [ok : bool true]
    (if (< text-len prefix-len)
      false
      (begin
        (while (< i prefix-len)
          (if ok
            (if (= (string.string-ref text i) (string.string-ref prefix i))
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
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [ok : bool true]
    (if (= n 0)
      false
      (begin
        (while (< i n)
          (if ok
            (if (lsp-frame-digit? (string.string-ref text i))
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
          (string.substring line 15 (- (string.string-length line) 15)))]
      (if (lsp-frame-decimal? value)
        (let
          [n : i64 (string.string->int value)]
          (if (< n 0)
            (LspLengthParse.Err "lsp: invalid Content-Length")
            (LspLengthParse.Ok n)))
        (LspLengthParse.Err "lsp: invalid Content-Length")))
    LspLengthParse.Ignore))

(define (lsp-frame-read-message) : LspFrameRead
  (let
    [content-length : i64 -1]
    [saw-header : bool false]
    [done : bool false]
    [clean-eof : bool false]
    [err : String ""]
    [has-error : bool false]
    (begin
      (while (not done)
        (let
          [line-read : io.StdinRead (stdin-read-line)]
          [line : String
            (lsp-frame-trim-right-space-cr (io.stdin-read-text line-read))]
          (if (io.stdin-read-eof? line-read)
            (if (= (string.string-length line) 0)
              (if saw-header
                (begin
                  (set! err "lsp: EOF before header terminator")
                  (set! has-error true)
                  (set! done true))
                (begin
                  (set! clean-eof true)
                  (set! done true)))
              (begin
                (set! saw-header true)
                (match (lsp-frame-parse-content-length line)
                  [(LspLengthParse.Ignore) unit]
                  [(LspLengthParse.Ok n) (set! content-length n)]
                  [(LspLengthParse.Err message)
                    (begin
                      (set! err message)
                      (set! has-error true)
                      (set! done true))])))
            (if (string.string-eq line "")
              (set! done true)
              (begin
                (set! saw-header true)
                (match (lsp-frame-parse-content-length line)
                  [(LspLengthParse.Ignore) unit]
                  [(LspLengthParse.Ok n) (set! content-length n)]
                  [(LspLengthParse.Err message)
                    (begin
                      (set! err message)
                      (set! has-error true)
                      (set! done true))]))))))
      (cond
        [clean-eof LspFrameRead.Eof]
        [has-error (LspFrameRead.Err err)]
        [(< content-length 0) (LspFrameRead.Err "lsp: missing Content-Length")]
        [else
          (let
            [payload-read : io.StdinRead (io.stdin-read-bytes content-length)]
            [payload : String (io.stdin-read-text payload-read)]
            (if (and
              (io.stdin-read-eof? payload-read)
              (< (string.string-length payload) content-length))
              (LspFrameRead.Err "lsp: truncated payload")
              (LspFrameRead.Ok payload)))]))))

(define (lsp-frame-stdout-write [text : String]) : unit
  (io.stdout-write (& text)))

(define (lsp-frame-stderr-write [text : String]) : unit
  (io.stderr-write (& text)))

(define (lsp-frame-write-body [body : String]) : unit
  (begin
    (lsp-frame-stdout-write
      (lsp-str5
        "Content-Length: "
        (string.int->string (string.string-length body))
        "\r\n\r\n"
        body
        ""))
    (stdout-flush)))

(define (lsp-json-number [value : i64]) : json.Json
  (json.JsonNumber (string.int->string value)))

(define (lsp-json-member
  [k : String]
  [v : json.Json]
  [rest : json.JsonMemberList]) : json.JsonMemberList
  (json.JsonMemberListCons k v (box rest)))

(define (lsp-json-object [members : json.JsonMemberList]) : json.Json
  (json.JsonObject (box members)))

(define (lsp-json-list-cons [value : json.Json] [rest : json.JsonList]) : json.JsonList
  (json.JsonListCons value (box rest)))

(define (lsp-json-array [items : json.JsonList]) : json.Json
  (json.JsonArray (box items)))

(define (lsp-json-rpc-member [rest : json.JsonMemberList]) : json.JsonMemberList
  (lsp-json-member "jsonrpc" (json.JsonString "2.0") rest))

(define (lsp-json-object1 [k : String] [v : json.Json]) : json.Json
  (lsp-json-object (lsp-json-member k v json.JsonMemberListNil)))

(define (lsp-json-object2
  [k1 : String]
  [v1 : json.Json]
  [k2 : String]
  [v2 : json.Json]) : json.Json
  (lsp-json-object
    (lsp-json-member k1 v1 (lsp-json-member k2 v2 json.JsonMemberListNil))))

(define (lsp-json-object3
  [k1 : String]
  [v1 : json.Json]
  [k2 : String]
  [v2 : json.Json]
  [k3 : String]
  [v3 : json.Json]) : json.Json
  (lsp-json-object
    (lsp-json-member
      k1
      v1
      (lsp-json-member k2 v2 (lsp-json-member k3 v3 json.JsonMemberListNil)))))

(define (lsp-json-object4
  [k1 : String]
  [v1 : json.Json]
  [k2 : String]
  [v2 : json.Json]
  [k3 : String]
  [v3 : json.Json]
  [k4 : String]
  [v4 : json.Json]) : json.Json
  (lsp-json-object
    (lsp-json-member
      k1
      v1
      (lsp-json-member
        k2
        v2
        (lsp-json-member k3 v3 (lsp-json-member k4 v4 json.JsonMemberListNil))))))

(define (lsp-json-string-field [value : json.Json] [key : String]) : LspJsonText
  (match (json.json-object-get value (& key))
    [(json.JsonFound field)
      (match field
        [(json.JsonString text) (LspJsonText.Ok text)]
        [_ LspJsonText.Missing])]
    [(json.JsonMissing) LspJsonText.Missing]))

(define (lsp-json-string-field-default
  [value : json.Json]
  [key : String]
  [fallback : String]) : String
  (match (lsp-json-string-field value key)
    [(LspJsonText.Ok text) text]
    [(LspJsonText.Missing) fallback]))

(define (lsp-write-json [value : json.Json]) : unit
  (lsp-frame-write-body (json.json-stringify value)))

(define (lsp-write-response [id : json.Json] [result : json.Json]) : unit
  (lsp-write-json
    (lsp-json-object
      (lsp-json-rpc-member
        (lsp-json-member
          "id"
          id
          (lsp-json-member "result" result json.JsonMemberListNil))))))

(define (lsp-write-error [id : json.Json] [code : i64] [message : String]) : unit
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
              (json.JsonString message))
            json.JsonMemberListNil))))))

(define (lsp-write-parse-error [message : String]) : unit
  (lsp-write-error json.JsonNull -32700 message))

(define (lsp-initialize-result) : json.Json
  (lsp-json-object2
    "capabilities"
    (lsp-json-object
      (lsp-json-member
        "textDocumentSync"
        (lsp-json-object2
          "openClose"
          (json.JsonBool true)
          "change"
          (lsp-json-number 1))
        (lsp-json-member
          "definitionProvider"
          (json.JsonBool true)
          (lsp-json-member
            "completionProvider"
            (lsp-json-object1 "resolveProvider" (json.JsonBool false))
            (lsp-json-member
              "inlayHintProvider"
              (json.JsonBool true)
              (lsp-json-member
                "documentFormattingProvider"
                (json.JsonBool true)
                (lsp-json-member
                  "hoverProvider"
                  (json.JsonBool true)
                  (lsp-json-member
                    "documentLinkProvider"
                    (lsp-json-object1 "resolveProvider" (json.JsonBool false))
                    json.JsonMemberListNil))))))))
    "serverInfo"
    (lsp-json-object2
      "name"
      (json.JsonString "typelisp")
      "version"
      (json.JsonString "selfhost"))))

(define (lsp-document-fallback) : LspDocument
  (LspDocument "" "" "" "" (lsp-decl-list-new) false))

(define lsp-document-cache-arena : i64
  0)

(define (lsp-documents-find-index-from
  [docs : LspDocuments]
  [uri : String]
  [index : i64]) : i64
  (let
    [i : i64 index]
    [found : i64 -1]
    [done : bool false]
    (begin
      (while (< i (lsp-documents-len (& docs)))
        (if done
          (set! i (lsp-documents-len (& docs)))
          (let
            [doc : LspDocument
              (lsp-documents-get (& docs) i (lsp-document-fallback))]
            (if (string.string-eq (struct-get doc uri) uri)
              (begin
                (set! found i)
                (set! done true)
                (set! i (lsp-documents-len (& docs))))
              (set! i (+ i 1))))))
      found)))

(define (lsp-documents-find-index [docs : LspDocuments] [uri : String]) : i64
  (lsp-documents-find-index-from docs uri 0))

(define lsp-documents-max-capacity : i64
  16)

(define (lsp-documents-set
  [docs : LspDocuments]
  [uri : String]
  [path : String]
  [text : String]
  [diagnostic-uri : String]) : LspDocuments
  (let
    [index : i64 (lsp-documents-find-index docs uri)]
    (if (>= index 0)
      (let
        [old-doc : LspDocument
          (lsp-documents-get (& docs) index (lsp-document-fallback))]
        [old-text : String (struct-get old-doc text)]
        [old-decls : LspDeclList (struct-get old-doc decls)]
        [old-decls-valid : bool (struct-get old-doc decls-valid)]
        [new-decls : LspDeclList
          (if (string.string-eq old-text text)
            old-decls
            (lsp-decl-list-new))]
        [new-decls-valid : bool
          (if (string.string-eq old-text text)
            old-decls-valid
            false)]
        (begin
          (lsp-documents-set!
            (&mut docs)
            index
            (LspDocument uri path text diagnostic-uri new-decls new-decls-valid))
          docs))
      (let
        [doc : LspDocument
          (LspDocument uri path text diagnostic-uri (lsp-decl-list-new) false)]
        (if (>= (lsp-documents-len (& docs)) lsp-documents-max-capacity)
          (begin
            (lsp-documents-shift-left! docs 0)
            (lsp-documents-set!
              (&mut docs)
              (- (lsp-documents-len (& docs)) 1)
              doc)
            docs)
          (begin
            (lsp-documents-push (&mut docs) doc)
            docs))))))

(define (lsp-documents-shift-left! [docs : LspDocuments] [index : i64]) : unit
  (let
    [i : i64 index]
    [last : i64 (- (lsp-documents-len (& docs)) 1)]
    (while (< i last)
      (let
        [next : LspDocument
          (lsp-documents-get (& docs) (+ i 1) (lsp-document-fallback))]
        (begin
          (lsp-documents-set! (&mut docs) i next)
          (set! i (+ i 1)))))))

(define (lsp-documents-remove-index [docs : LspDocuments] [index : i64]) : LspDocuments
  (if (if (>= index 0)
    (< index (lsp-documents-len (& docs)))
    false)
    (begin
      (lsp-documents-shift-left! docs index)
      (set! (struct-get docs len) (- (lsp-documents-len (& docs)) 1))
      docs)
    docs))

(define (lsp-documents-remove [docs : LspDocuments] [uri : String]) : LspDocuments
  (lsp-documents-remove-index docs (lsp-documents-find-index docs uri)))

(define (lsp-documents-lookup [docs : LspDocuments] [uri : String]) : LspDocumentLookup
  (let
    [index : i64 (lsp-documents-find-index docs uri)]
    (if (>= index 0)
      (let
        [doc : LspDocument
          (lsp-documents-get (& docs) index (lsp-document-fallback))]
        (LspDocumentLookup.Found
          (struct-get doc path)
          (struct-get doc text)
          (struct-get doc diagnostic-uri)))
      LspDocumentLookup.Missing)))

(define (lsp-documents-smoke-add [docs : LspDocuments] [uri : String]) : LspDocuments
  (lsp-documents-set docs uri uri uri uri))

(define (lsp-documents-smoke-missing? [docs : LspDocuments] [uri : String]) : bool
  (match (lsp-documents-lookup docs uri)
    [(LspDocumentLookup.Found _ _ _) false]
    [(LspDocumentLookup.Missing) true]))

(define (lsp-documents-smoke-text-eq?
  [docs : LspDocuments]
  [uri : String]
  [expected-text : String]) : bool
  (match (lsp-documents-lookup docs uri)
    [(LspDocumentLookup.Found _ text _) (string.string-eq text expected-text)]
    [(LspDocumentLookup.Missing) false]))

(define (lsp-documents-cache-bound-smoke-ok?) : bool
  (let
    [docs : LspDocuments (lsp-documents-new)]
    (begin
      (set! docs (lsp-documents-smoke-add docs "file:///doc00.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc01.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc02.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc03.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc04.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc05.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc06.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc07.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc08.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc09.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc10.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc11.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc12.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc13.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc14.tl"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc15.tl"))
      (set!
        docs
        (lsp-documents-set
          docs
          "file:///doc10.tl"
          "doc10.tl"
          "updated"
          "diag10"))
      (set! docs (lsp-documents-smoke-add docs "file:///doc16.tl"))
      (and
        (= (lsp-documents-len (& docs)) lsp-documents-max-capacity)
        (lsp-documents-smoke-missing? docs "file:///doc00.tl")
        (lsp-documents-smoke-text-eq?
          docs
          "file:///doc01.tl"
          "file:///doc01.tl")
        (lsp-documents-smoke-text-eq? docs "file:///doc10.tl" "updated")
        (lsp-documents-smoke-text-eq?
          docs
          "file:///doc16.tl"
          "file:///doc16.tl")))))

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
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [out : String ""]
    [err : String ""]
    [has-error : bool false]
    (begin
      (while (< i n)
        (if (not has-error)
          (if (= (string.string-ref text i) '%')
            (if (< (+ i 2) n)
              (let
                [hi : i64 (lsp-hex-value (string.string-ref text (+ i 1)))]
                [lo : i64 (lsp-hex-value (string.string-ref text (+ i 2)))]
                (if (and (>= hi 0) (>= lo 0))
                  (match (json.json-codepoint-string (+ (* hi 16) lo))
                    [(json.OkJsonCodepointString decoded)
                      (begin
                        (set! out (string.string-concat3 out decoded ""))
                        (set! i (+ i 3)))]
                    [(json.ErrJsonCodepointString message)
                      (begin
                        (set! err message)
                        (set! has-error true)
                        (set! i n))])
                  (begin
                    (set! err "lsp: invalid percent escape in file URI")
                    (set! has-error true)
                    (set! i n))))
              (begin
                (set! err "lsp: invalid percent escape in file URI")
                (set! has-error true)
                (set! i n)))
            (begin
              (set!
                out
                (string.string-concat3 out (string.substring text i 1) ""))
              (set! i (+ i 1))))
          (set! i n)))
      (if (not has-error)
        (LspStringResult.Ok out)
        (LspStringResult.Err err)))))

(define (lsp-uri-path-strip-windows-leading-slash [path : String]) : String
  (let
    [n : i64 (string.string-length path)]
    (if (and
      (> n 2)
      (= (string.string-ref path 0) '/')
      (= (string.string-ref path 2) ':'))
      (string.substring path 1 (- n 1))
      path)))

(define (lsp-file-uri-to-path [uri : String]) : LspUriPath
  (if (lsp-frame-starts-with? uri "file://")
    (match (lsp-percent-decode
      (string.substring uri 7 (- (string.string-length uri) 7)))
      [(LspStringResult.Ok decoded)
        (let
          [path : String (lsp-uri-path-strip-windows-leading-slash decoded)]
          (if (> (string.string-length path) 0)
            (LspUriPath.Ok path)
            (LspUriPath.Err "unsupported TypeLisp LSP URI: empty file path")))]
      [(LspStringResult.Err message) (LspUriPath.Err message)])
    (LspUriPath.Err "unsupported TypeLisp LSP URI: expected file:// URI")))

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
    [n : i64 (string.string-length path)]
    [i : i64 0]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (let
            [code : i64 (cast (string.string-ref path i) : i64)]
            (if (lsp-uri-safe-code? code)
              (set!
                out
                (string.string-concat3 out (string.substring path i 1) ""))
              (set!
                out
                (lsp-str4
                  out
                  "%"
                  (json.json-hex-digit (/ code 16))
                  (json.json-hex-digit (- code (* (/ code 16) 16)))))))
          (set! i (+ i 1))))
      out)))

(define (lsp-path-to-file-uri [path : String]) : String
  (if (and (> (string.string-length path) 0) (= (string.string-ref path 0) '/'))
    (lsp-str2 "file://" (lsp-percent-encode-path path))
    (lsp-str2 "file:///" (lsp-percent-encode-path path))))

(define (lsp-resolved-path-to-file-uri [path : String]) : String
  (let
    [normalized : String (fs.fs-path-normalize (& path))]
    (lsp-path-to-file-uri
      (if (fs.fs-path-absolute? (& normalized))
        normalized
        (let
          [cwd : String (fs.fs-current-dir)]
          [joined : String (fs.fs-path-join (& cwd) (& normalized))]
          (fs.fs-path-normalize (& joined)))))))

(define (lsp-zero-based [value : i64]) : i64
  (if (> value 0)
    (- value 1)
    0))

(define (lsp-position [line : i64] [character : i64]) : json.Json
  (lsp-json-object2
    "line"
    (lsp-json-number (lsp-zero-based line))
    "character"
    (lsp-json-number (lsp-zero-based character))))

(define (lsp-range [line : i64] [col : i64]) : json.Json
  (lsp-json-object2
    "start"
    (lsp-position line col)
    "end"
    (lsp-position line (+ col 1))))

(define (lsp-range-from-compiler-span [span : CompilerDiagnosticSpan]) : json.Json
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
    (lsp-resolved-path-to-file-uri
      (if (string.string-eq path "")
        fallback-path
        path))))

(define (lsp-diagnostic-related-message [label : CompilerDiagnosticMaybeString]) : String
  (match label
    [(CompilerDiagnosticSomeString text) text]
    [CompilerDiagnosticNoString "related location"]))

(define (lsp-diagnostic-related-information
  [fallback-path : String]
  [entry : CompilerDiagnosticLabel]) : json.Json
  (let
    [span : CompilerDiagnosticSpan (struct-get entry span)]
    (lsp-json-object2
      "location"
      (lsp-json-object2
        "uri"
        (json.JsonString (lsp-diagnostic-related-uri fallback-path span))
        "range"
        (lsp-range-from-compiler-span span))
      "message"
      (json.JsonString
        (lsp-diagnostic-related-message (struct-get entry label))))))

(define (lsp-diagnostic-related-information-list
  [fallback-path : String]
  [labels : CompilerDiagnosticLabelList]) : json.JsonList
  (match labels
    [(CompilerDiagnosticLabelNil) json.JsonListNil]
    [(CompilerDiagnosticLabelCons entry rest)
      (lsp-json-list-cons
        (lsp-diagnostic-related-information fallback-path entry)
        (lsp-diagnostic-related-information-list fallback-path (box-get rest)))]))

(define (lsp-diagnostic-message-tail [message : String]) : json.JsonMemberList
  (lsp-json-member "message" (json.JsonString message) json.JsonMemberListNil))

(define (lsp-diagnostic-code-tail [code : String] [tail : json.JsonMemberList]) : json.JsonMemberList
  (if (string.string-eq code "")
    tail
    (lsp-json-member "code" (json.JsonString code) tail)))

(define (lsp-diagnostic-with-range-tail
  [range : json.Json]
  [code : String]
  [tail : json.JsonMemberList]) : json.Json
  (lsp-json-object
    (lsp-json-member
      "range"
      range
      (lsp-json-member
        "severity"
        (lsp-json-number 1)
        (lsp-json-member
          "source"
          (json.JsonString "typelisp")
          (lsp-diagnostic-code-tail code tail))))))

(define (lsp-diagnostic-with-range
  [range : json.Json]
  [message : String]
  [code : String]) : json.Json
  (lsp-diagnostic-with-range-tail
    range
    code
    (lsp-diagnostic-message-tail message)))

(define (lsp-diagnostic
  [line : i64]
  [col : i64]
  [message : String]
  [code : String]) : json.Json
  (lsp-diagnostic-with-range (lsp-range line col) message code))

(define (lsp-compiler-diagnostic [diag : CompilerDiagnostic]) : json.Json
  (let
    [span : CompilerDiagnosticSpan (compiler-diagnostic-primary-span diag)]
    [path : String (compiler-diagnostic-span-path span)]
    [labels : CompilerDiagnosticLabelList
      (compiler-diagnostic-secondary-spans diag)]
    [range : json.Json (lsp-range-from-compiler-span span)]
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
    [(LspJsonText.Ok code) (string.string-eq code want)]
    [(LspJsonText.Missing) false]))

(define (lsp-compiler-diagnostic-uncoded-ok? [diag : CompilerDiagnostic]) : bool
  (match (lsp-json-string-field (lsp-compiler-diagnostic diag) "code")
    [(LspJsonText.Ok _) false]
    [(LspJsonText.Missing) true]))

(cfg
  test
  (define (lsp-compiler-diagnostic-related-ok?) : bool
    (let
      [diag : CompilerDiagnostic
        (compiler-diagnostic-with-secondary
          (compiler-diagnostic-with-code
            (compiler-diagnostic-from-span
              "primary.tl"
              (token.SourceSpan 2 3 2 9)
              "wide primary")
            "E7777")
          (CompilerDiagnosticSpan "" 4 5 4 8)
          (CompilerDiagnosticSomeString "borrow remains live"))]
      [rendered : String (json.json-stringify (lsp-compiler-diagnostic diag))]
      [related-key : String "\"relatedInformation\""]
      [related-message : String "\"message\":\"borrow remains live\""]
      [related-uri-prefix : String "\"uri\":\"file:///"]
      [related-uri-suffix : String "/primary.tl\""]
      [primary-line : String "\"line\":1"]
      [primary-end : String "\"character\":8"]
      [secondary-line : String "\"line\":3"]
      [secondary-end : String "\"character\":7"]
      (and
        (string.string-contains (& rendered) (& related-key))
        (string.string-contains (& rendered) (& related-message))
        (string.string-contains (& rendered) (& related-uri-prefix))
        (string.string-contains (& rendered) (& related-uri-suffix))
        (string.string-contains (& rendered) (& primary-line))
        (string.string-contains (& rendered) (& primary-end))
        (string.string-contains (& rendered) (& secondary-line))
        (string.string-contains (& rendered) (& secondary-end))))))

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
      (not (string.string-eq err1 ""))
      (string.string-contains (& err1) (& needle)))))

(define (lsp-validate-forms-line-context-ok?) : bool
  (match (lsp-validate-forms-result "(let [x : badtype] 1)")
    [(LspValidationResult.Valid) false]
    [(LspValidationResult.Invalid line col msg ctx)
      (and
        (= line 1)
        (= col 1)
        (not (string.string-eq msg ""))
        (not (string.string-eq ctx "")))]))

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
      (unless (lsp-documents-cache-bound-smoke-ok?) (return 12))
      42)))

(define (lsp-diagnostic-uri
  [root-uri : String]
  [root-path : String]
  [diag : CompilerDiagnostic]) : String
  (let
    [diag-path : String (compiler-diagnostic-path diag)]
    (if (or
      (string.string-eq diag-path "")
      (string.string-eq diag-path root-path))
      root-uri
      (lsp-resolved-path-to-file-uri diag-path))))

(define (lsp-publish-diagnostics [uri : String] [diagnostics : json.JsonList]) : unit
  (lsp-write-json
    (lsp-json-object
      (lsp-json-rpc-member
        (lsp-json-member
          "method"
          (json.JsonString "textDocument/publishDiagnostics")
          (lsp-json-member
            "params"
            (lsp-json-object2
              "uri"
              (json.JsonString uri)
              "diagnostics"
              (lsp-json-array diagnostics))
            json.JsonMemberListNil))))))

(define (lsp-publish-uri-diagnostic [uri : String] [message : String]) : unit
  (lsp-publish-diagnostics
    uri
    (lsp-json-list-cons (lsp-diagnostic 1 1 message "") json.JsonListNil)))

(define (lsp-clear-stale-diagnostic
  [docs : LspDocuments]
  [uri : String]
  [next-diagnostic-uri : String]) : unit
  (match (lsp-documents-lookup docs uri)
    [(LspDocumentLookup.Found _ _ old-diagnostic-uri)
      (if (or
        (string.string-eq old-diagnostic-uri "")
        (string.string-eq old-diagnostic-uri uri)
        (string.string-eq old-diagnostic-uri next-diagnostic-uri))
        unit
        (lsp-publish-diagnostics old-diagnostic-uri json.JsonListNil))]
    [(LspDocumentLookup.Missing) unit]))

(define (lsp-clear-close-diagnostics [docs : LspDocuments] [uri : String]) : unit
  (match (lsp-documents-lookup docs uri)
    [(LspDocumentLookup.Found _ _ old-diagnostic-uri)
      (begin
        (lsp-publish-diagnostics uri json.JsonListNil)
        (if (or
          (string.string-eq old-diagnostic-uri "")
          (string.string-eq old-diagnostic-uri uri))
          unit
          (lsp-publish-diagnostics old-diagnostic-uri json.JsonListNil)))]
    [(LspDocumentLookup.Missing) (lsp-publish-diagnostics uri json.JsonListNil)]))

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
  [code : String]) : json.Json
  (lsp-json-object
    (lsp-json-member
      "range"
      (lsp-range line col)
      (lsp-json-member
        "severity"
        (lsp-json-number 2)
        (lsp-json-member
          "source"
          (json.JsonString "typelisp-lint")
          (lsp-json-member
            "code"
            (json.JsonString code)
            (lsp-json-member
              "message"
              (json.JsonString message)
              json.JsonMemberListNil)))))))

(define (lsp-lint-finding-diagnostic [finding : LintFinding]) : json.Json
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
  [acc : json.JsonList]) : json.JsonList
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
  [stdlib-roots : vector.StringVec]) : json.JsonList
  (lsp-lint-findings-to-json
    text
    (selfhost-lint-source-with-roots path text stdlib-roots)
    0
    json.JsonListNil))

(define (lsp-analyze-document
  [uri : String]
  [path : String]
  [text : String]
  [stdlib-roots : vector.StringVec]) : String
  (let
    [lint-diags : json.JsonList (lsp-lint-diagnostics path text stdlib-roots)]
    (match (compiler-check-source-with-roots path text stdlib-roots)
      [(ResultCompilerCheck.Ok _)
        (begin
          (lsp-publish-diagnostics uri lint-diags)
          "")]
      [(ResultCompilerCheck.Err diag)
        (let
          [diag-uri : String (lsp-diagnostic-uri uri path (box-get diag))]
          (if (string.string-eq diag-uri uri)
            (begin
              (lsp-publish-diagnostics
                uri
                (lsp-json-list-cons
                  (lsp-compiler-diagnostic (box-get diag))
                  lint-diags))
              uri)
            (begin
              (lsp-publish-diagnostics uri lint-diags)
              (lsp-publish-diagnostics
                diag-uri
                (lsp-json-list-cons
                  (lsp-compiler-diagnostic (box-get diag))
                  json.JsonListNil))
              diag-uri)))])))

(define (lsp-first-change-text [params : json.Json]) : LspJsonText
  (let
    [key : String "contentChanges"]
    (match (json.json-object-get params (& key))
      [(json.JsonFound value)
        (match value
          [(json.JsonArray items)
            (match (box-get items)
              [(json.JsonListNil) LspJsonText.Missing]
              [(json.JsonListCons first _) (lsp-json-string-field first "text")])]
          [_ LspJsonText.Missing])]
      [(json.JsonMissing) LspJsonText.Missing])))

(define (lsp-did-open
  [params : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : LspHandleResult
  (let
    [key : String "textDocument"]
    (match (json.json-object-get params (& key))
      [(json.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(LspJsonText.Ok uri)
            (let
              [text : String (lsp-json-string-field-default document "text" "")]
              (match (lsp-file-uri-to-path uri)
                [(LspUriPath.Ok path)
                  (let
                    [diagnostic-uri : String
                      (lsp-analyze-document uri path text stdlib-roots)]
                    (begin
                      (lsp-clear-stale-diagnostic docs uri diagnostic-uri)
                      (LspHandleResult.Continue
                        (lsp-documents-set docs uri path text diagnostic-uri))))]
                [(LspUriPath.Err message)
                  (begin
                    (lsp-publish-uri-diagnostic uri message)
                    (LspHandleResult.Continue docs))]))]
          [(LspJsonText.Missing) (LspHandleResult.Continue docs)])]
      [(json.JsonMissing) (LspHandleResult.Continue docs)])))

(define (lsp-did-change
  [params : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : LspHandleResult
  (let
    [key : String "textDocument"]
    (match (json.json-object-get params (& key))
      [(json.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(LspJsonText.Ok uri)
            (match (lsp-first-change-text params)
              [(LspJsonText.Ok text)
                (match (lsp-file-uri-to-path uri)
                  [(LspUriPath.Ok path)
                    (let
                      [diagnostic-uri : String
                        (lsp-analyze-document uri path text stdlib-roots)]
                      (begin
                        (lsp-clear-stale-diagnostic docs uri diagnostic-uri)
                        (LspHandleResult.Continue
                          (lsp-documents-set docs uri path text diagnostic-uri))))]
                  [(LspUriPath.Err message)
                    (begin
                      (lsp-publish-uri-diagnostic uri message)
                      (LspHandleResult.Continue docs))])]
              [(LspJsonText.Missing)
                (match (lsp-documents-lookup docs uri)
                  [(LspDocumentLookup.Found path text _)
                    (begin
                      (lsp-analyze-document uri path text stdlib-roots)
                      (LspHandleResult.Continue docs))]
                  [(LspDocumentLookup.Missing) (LspHandleResult.Continue docs)])])]
          [(LspJsonText.Missing) (LspHandleResult.Continue docs)])]
      [(json.JsonMissing) (LspHandleResult.Continue docs)])))

(define (lsp-did-close [params : json.Json] [docs : LspDocuments]) : LspHandleResult
  (let
    [key : String "textDocument"]
    (match (json.json-object-get params (& key))
      [(json.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(LspJsonText.Ok uri)
            (begin
              (lsp-clear-close-diagnostics docs uri)
              (LspHandleResult.Continue (lsp-documents-remove docs uri)))]
          [(LspJsonText.Missing) (LspHandleResult.Continue docs)])]
      [(json.JsonMissing) (LspHandleResult.Continue docs)])))

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
      (while (and (< j n) (lsp-ws? (string.string-ref text j)))
        (set! j (+ j 1)))
      j)))

(define (lsp-scan-ident [text : String] [i : i64] [n : i64]) : i64
  (let
    [j : i64 i]
    (begin
      (while (and (< j n) (lsp-ident-char? (string.string-ref text j)))
        (set! j (+ j 1)))
      j)))

(define (lsp-skip-line [text : String] [i : i64] [n : i64]) : i64
  (let
    [j : i64 i]
    (begin
      (while (and (< j n) (not (= (string.string-ref text j) '\n')))
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
          [c : char (string.string-ref text j)]
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
      [payload : char (string.string-ref text (+ i 1))]
      (cond
        [(= payload '\\')
          (if (and
            (< (+ i 3) n)
            (lsp-apostrophe-char-escape? (string.string-ref text (+ i 2)))
            (= (string.string-ref text (+ i 3)) '\''))
            (+ i 4)
            (+ i 1))]
        [(or (= payload '\'') (= payload '\n') (= payload '\r')) (+ i 1)]
        [else
          (if (and (< (+ i 2) n) (= (string.string-ref text (+ i 2)) '\''))
            (+ i 3)
            (+ i 1))]))
    (+ i 1)))

;; Maximal identifier token covering `off`, or "" when `off` is not on one.
(define (lsp-symbol-at-offset [text : String] [off : i64]) : String
  (let
    [n : i64 (string.string-length text)]
    (if (or (< off 0) (>= off n))
      ""
      (if (not (lsp-ident-char? (string.string-ref text off)))
        ""
        (let
          [start : i64 off]
          [end : i64 (lsp-scan-ident text off n)]
          (begin
            (while (and
              (> start 0)
              (lsp-ident-char? (string.string-ref text (- start 1))))
              (set! start (- start 1)))
            (string.substring text start (- end start))))))))

;; Base name of a possibly module-qualified symbol (`core/cond` -> `cond`,
;; `core.cond` -> `cond`).
(define (lsp-symbol-base [s : String]) : String
  (let
    [n : i64 (string.string-length s)]
    [i : i64 0]
    [k : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (or
            (= (string.string-ref s i) '/')
            (= (string.string-ref s i) '.'))
            (set! k i)
            unit)
          (set! i (+ i 1))))
      (if (>= k 0)
        (string.substring s (+ k 1) (- n (+ k 1)))
        s))))

;; Byte offset of a 0-based (line, character) position, clamped to the line.
(define (lsp-offset-at-position [text : String] [line0 : i64] [char0 : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [ln : i64 0]
    [col : i64 0]
    (begin
      (while (and (< i n) (< ln line0))
        (begin
          (if (= (string.string-ref text i) '\n')
            (set! ln (+ ln 1))
            unit)
          (set! i (+ i 1))))
      (while (and
        (< i n)
        (< col char0)
        (not (= (string.string-ref text i) '\n')))
        (begin
          (set! i (+ i 1))
          (set! col (+ col 1))))
      i)))

;; 1-based line/column of a byte offset.
(define (lsp-line-col-at-offset [text : String] [off : i64]) : LspLineCol
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [line : i64 1]
    [col : i64 1]
    (begin
      (while (and (< i n) (< i off))
        (begin
          (if (= (string.string-ref text i) '\n')
            (begin
              (set! line (+ line 1))
              (set! col 1))
            (set! col (+ col 1)))
          (set! i (+ i 1))))
      (LspLineCol line col))))

(define (lsp-line-col-cache-at-offset!
  [cache : LspLineColCache]
  [text : String]
  [off : i64]) : LspLineCol
  (if (= off (struct-get cache offset))
    (LspLineCol (struct-get cache line) (struct-get cache col))
    (let
      [n : i64 (string.string-length text)]
      [resume : bool
        (and (>= (struct-get cache offset) 0) (< (struct-get cache offset) off))]
      [start : i64
        (if resume
          (struct-get cache offset)
          0)]
      [line : i64
        (if resume
          (struct-get cache line)
          1)]
      [col : i64
        (if resume
          (struct-get cache col)
          1)]
      [i : i64 start]
      (begin
        (while (and (< i n) (< i off))
          (begin
            (if (= (string.string-ref text i) '\n')
              (begin
                (set! line (+ line 1))
                (set! col 1))
              (set! col (+ col 1)))
            (set! i (+ i 1))))
        (set! (struct-get cache offset) off)
        (set! (struct-get cache line) line)
        (set! (struct-get cache col) col)
        (LspLineCol line col)))))

(define (lsp-def-keyword? [kw : String]) : bool
  (or
    (string.string-eq kw "define")
    (string.string-eq kw "defmacro")
    (string.string-eq kw "defstruct")
    (string.string-eq kw "defenum")
    (string.string-eq kw "defdispatch")
    (string.string-eq kw "extern")))

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
        [kw : String (string.substring text after-open (- kw-end after-open))]
        (if (lsp-def-keyword? kw)
          (let
            [after-kw : i64 (lsp-skip-space text kw-end n)]
            [name-start : i64
              (if (and (< after-kw n) (= (string.string-ref text after-kw) '('))
                (lsp-skip-space text (+ after-kw 1) n)
                after-kw)]
            (if (< name-start n)
              (if (lsp-ident-char? (string.string-ref text name-start))
                name-start
                -1)
              -1))
          -1)))))

;; Byte offset of the definition of `needle` in `text`, or -1. Strings,
;; character literals, and `;` comments are skipped so embedded source never
;; matches.
(define (lsp-find-def-offset-in [text : String] [needle : String]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< i n) (< found 0))
        (let
          [c : char (string.string-ref text i)]
          (cond
            [(= c ';') (set! i (lsp-skip-line text i n))]
            [(= c '\'') (set! i (lsp-skip-apostrophe-char-literal text i n))]
            [(= c '"') (set! i (lsp-skip-string text i n))]
            [(= c '(')
              (let
                [name-off : i64 (lsp-def-name-offset-at text i n)]
                (if (>= name-off 0)
                  (if (string.string-eq
                    (lsp-symbol-at-offset text name-off)
                    needle)
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
          [c : char (string.string-ref text i)]
          (if (= c '"')
            (set! i (lsp-skip-string text i end))
            (if (= c '(')
              (let
                [vs : i64 (lsp-skip-space text (+ i 1) end)]
                [ve : i64 (lsp-scan-ident text vs end)]
                (if (string.string-eq
                  (string.substring text vs (- ve vs))
                  needle)
                  (set! result vs)
                  (set! i (lsp-skip-paren-group text i end))))
              (set! i (+ i 1))))))
      result)))

;; Offset of the enum variant named `needle` (within its defenum), or -1.
(define (lsp-find-variant-offset-in [text : String] [needle : String]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [result : i64 -1]
    (begin
      (while (and (< i n) (< result 0))
        (let
          [c : char (string.string-ref text i)]
          (cond
            [(= c ';') (set! i (lsp-skip-line text i n))]
            [(= c '\'') (set! i (lsp-skip-apostrophe-char-literal text i n))]
            [(= c '"') (set! i (lsp-skip-string text i n))]
            [(= c '(')
              (let
                [kw-start : i64 (lsp-skip-space text (+ i 1) n)]
                [kw-end : i64 (lsp-scan-ident text kw-start n)]
                (if (string.string-eq
                  (string.substring text kw-start (- kw-end kw-start))
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
    (LspDefLocation.Found
      uri
      (struct-get lc line)
      (struct-get lc col)
      (string.string-length needle))))

(define (lsp-find-definition-in-docs
  [docs : LspDocuments]
  [current-uri : String]
  [needle : String]
  [idx : i64]) : LspDefLocation
  (if (>= idx (lsp-documents-len (& docs)))
    LspDefLocation.Missing
    (let
      [doc : LspDocument
        (lsp-documents-get (& docs) idx (lsp-document-fallback))]
      (if (string.string-eq (struct-get doc uri) current-uri)
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
(define (lsp-dotted-import-tl-suffix? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    (if (< n 3)
      false
      (string.string-eq (string.substring name (- n 3) 3) ".tl"))))

(define (lsp-dotted-import-name-valid? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    [i : i64 0]
    [ok : bool (and (> n 0) (not (lsp-dotted-import-tl-suffix? name)))]
    [last-was-dot : bool true]
    (begin
      (while ok
        (if (< i n)
          (let
            [c : char (string.string-ref name i)]
            (if (or
              (string.char-eq c '/')
              (string.char-eq c '\\')
              (string.char-eq c ':'))
              (set! ok false)
              (if (string.char-eq c '.')
                (if last-was-dot
                  (set! ok false)
                  (begin
                    (set! last-was-dot true)
                    (set! i (+ i 1))))
                (begin
                  (set! last-was-dot false)
                  (set! i (+ i 1))))))
          (set! ok false)))
      (and (= i n) (not last-was-dot)))))

(define (lsp-resolve-module-import-target
  [path : String]
  [module-name : String]
  [stdlib-roots : vector.StringVec]) : String
  (match (compiler-load-resolve-module-import-with-roots
    path
    (compiler-load-dirname path)
    module-name
    stdlib-roots)
    [(ResultPkgResolve.Ok resolved) (compiler-load-normalize-path resolved)]
    [(ResultPkgResolve.Err _) module-name]))

(define (lsp-resolve-import-target-at
  [text : String]
  [path : String]
  [stdlib-roots : vector.StringVec]
  [operand-start : i64]) : LspImportTarget
  (let
    [n : i64 (string.string-length text)]
    (if (>= operand-start n)
      LspImportTarget.Missing
      (let
        [c : char (string.string-ref text operand-start)]
        (cond
          [(= c '"')
            (let
              [str-end : i64 (lsp-skip-string text operand-start n)]
              [content-start : i64 (+ operand-start 1)]
              [content-end : i64 (- str-end 1)]
              [spec : String
                (string.substring
                  text
                  content-start
                  (- content-end content-start))]
              [resolved : String
                (compiler-load-normalize-path
                  (compiler-load-resolve-import-with-roots
                    path
                    spec
                    stdlib-roots))]
              (LspImportTarget.Found resolved content-start content-end))]
          [(lsp-ident-char? c)
            (let
              [module-end : i64 (lsp-scan-ident text operand-start n)]
              [module-name : String
                (string.substring
                  text
                  operand-start
                  (- module-end operand-start))]
              (if (lsp-dotted-import-name-valid? module-name)
                (LspImportTarget.Found
                  (lsp-resolve-module-import-target
                    path
                    module-name
                    stdlib-roots)
                  operand-start
                  module-end)
                LspImportTarget.Missing))]
          [else LspImportTarget.Missing])))))

;; Collect every import target from the document, skipping strings and comments
;; so embedded source never yields a false import.
(define (lsp-collect-import-targets
  [text : String]
  [path : String]
  [stdlib-roots : vector.StringVec]
  [acc : vector.StringVec]) : vector.StringVec
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [out : vector.StringVec acc]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref text i)]
          (cond
            [(= c ';') (set! i (lsp-skip-line text i n))]
            [(= c '"') (set! i (lsp-skip-string text i n))]
            [(= c '(')
              (let
                [kw-start : i64 (lsp-skip-space text (+ i 1) n)]
                [kw-end : i64 (lsp-scan-ident text kw-start n)]
                (if (and
                  (> kw-end kw-start)
                  (string.string-eq
                    (string.substring text kw-start (- kw-end kw-start))
                    "import"))
                  (let
                    [operand-start : i64 (lsp-skip-space text kw-end n)]
                    (match (lsp-resolve-import-target-at
                      text
                      path
                      stdlib-roots
                      operand-start)
                      [(LspImportTarget.Found resolved _ end)
                        (begin
                          (set! out (vector.string-vec-push out resolved))
                          (set! i end))]
                      [(LspImportTarget.Missing) (set! i (+ i 1))]))
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
      out)))

(define (lsp-import-target-at-offset
  [text : String]
  [path : String]
  [stdlib-roots : vector.StringVec]
  [off : i64]) : LspImportTarget
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [target : LspImportTarget LspImportTarget.Missing]
    (begin
      (while (and
        (< i n)
        (match target
          [(LspImportTarget.Found _ _ _) false]
          [(LspImportTarget.Missing) true]))
        (let
          [c : char (string.string-ref text i)]
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
                  (string.string-eq
                    (string.substring text kw-start (- kw-end kw-start))
                    "import"))
                  (let
                    [operand-start : i64 (lsp-skip-space text kw-end n)]
                    (match (lsp-resolve-import-target-at
                      text
                      path
                      stdlib-roots
                      operand-start)
                      [(LspImportTarget.Found resolved start end)
                        (begin
                          (if (and (>= off start) (< off end))
                            (set!
                              target
                              (LspImportTarget.Found resolved start end))
                            unit)
                          (set! i end))]
                      [(LspImportTarget.Missing) (set! i (+ i 1))]))
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
      target)))

(defstruct LspModuleSet
  (paths vector.StringVec)
  (texts vector.StringVec))

(define (lsp-string-vec-contains? [v : vector.StringVec] [s : String]) : bool
  (let
    [n : i64 (vector.string-vec-len v)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (if (string.string-eq (vector.string-vec-get v i "") s)
          (set! found true)
          (set! i (+ i 1))))
      found)))

;; Add a resolved module path (and its source) to the set if new and under cap.
(define (lsp-module-set-add-path [set : LspModuleSet] [resolved : String]) : LspModuleSet
  (let
    [paths : vector.StringVec (struct-get set paths)]
    [texts : vector.StringVec (struct-get set texts)]
    (if (and
      (< (vector.string-vec-len paths) 512)
      (not (lsp-string-vec-contains? paths resolved)))
      (LspModuleSet
        (vector.string-vec-push paths resolved)
        (vector.string-vec-push texts (io.read-file-or (& resolved) "")))
      set)))

;; Add every module `text` imports (resolved like the loader) to the set.
(define (lsp-module-set-add-imports
  [importer-path : String]
  [text : String]
  [stdlib-roots : vector.StringVec]
  [set : LspModuleSet]) : LspModuleSet
  (let
    [paths : vector.StringVec
      (lsp-collect-import-targets
        text
        importer-path
        stdlib-roots
        (vector.string-vec-new))]
    [out : LspModuleSet set]
    [j : i64 0]
    (begin
      (while (< j (vector.string-vec-len paths))
        (begin
          (set!
            out
            (lsp-module-set-add-path out (vector.string-vec-get paths j "")))
          (set! j (+ j 1))))
      out)))

;; Every module transitively reachable from the document (plus the core
;; prelude), each read once. Shared by go-to-definition and hover.
(define (lsp-transitive-modules
  [start-path : String]
  [start-text : String]
  [stdlib-roots : vector.StringVec]) : LspModuleSet
  (let
    [seeded : LspModuleSet
      (lsp-module-set-add-path
        (LspModuleSet (vector.string-vec-new) (vector.string-vec-new))
        (compiler-load-normalize-path
          (compiler-load-resolve-import-with-roots
            start-path
            "stdlib/core_macros.tl"
            stdlib-roots)))]
    [set : LspModuleSet
      (lsp-module-set-add-imports start-path start-text stdlib-roots seeded)]
    [i : i64 0]
    (begin
      (while (< i (vector.string-vec-len (struct-get set paths)))
        (let
          [src : String (vector.string-vec-get (struct-get set texts) i "")]
          (begin
            (if (string.string-eq src "")
              unit
              (set!
                set
                (lsp-module-set-add-imports
                  (vector.string-vec-get (struct-get set paths) i "")
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
  (if (>= idx (vector.string-vec-len (struct-get set paths)))
    LspDefLocation.Missing
    (let
      [src : String (vector.string-vec-get (struct-get set texts) idx "")]
      [off : i64 (lsp-find-def-or-variant-offset-in src needle)]
      (if (>= off 0)
        (lsp-def-loc-from
          (lsp-resolved-path-to-file-uri
            (vector.string-vec-get (struct-get set paths) idx ""))
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
  [stdlib-roots : vector.StringVec]
  [needle : String]) : LspDefLocation
  (let
    [off : i64 (lsp-find-def-or-variant-offset-in current-text needle)]
    (if (>= off 0)
      (lsp-def-loc-from current-uri current-text off needle)
      (match (lsp-find-definition-in-docs docs current-uri needle 0)
        [(LspDefLocation.Found def-uri def-line def-col def-len)
          (LspDefLocation.Found def-uri def-line def-col def-len)]
        [(LspDefLocation.Missing)
          (lsp-find-definition-in-modules
            (lsp-transitive-modules current-path current-text stdlib-roots)
            needle
            0)]))))

(define (lsp-json-int-field-default
  [value : json.Json]
  [key : String]
  [fallback : i64]) : i64
  (match (json.json-object-get value (& key))
    [(json.JsonFound field)
      (match field
        [(json.JsonNumber text)
          (match (json.json-number->i64 (& text))
            [(json.OkJsonNumberI64 number) number]
            [(json.ErrJsonNumberI64 _) fallback])]
        [_ fallback])]
    [(json.JsonMissing) fallback]))

(define (lsp-definition-location
  [uri : String]
  [line : i64]
  [col : i64]
  [len : i64]) : json.Json
  (lsp-json-object2
    "uri"
    (json.JsonString uri)
    "range"
    (lsp-json-object2
      "start"
      (lsp-position line col)
      "end"
      (lsp-position line (+ col len)))))

(define (lsp-definition-respond
  [id : json.Json]
  [uri : String]
  [position : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : unit
  (match (lsp-documents-lookup docs uri)
    [(LspDocumentLookup.Found path text _)
      (let
        [line0 : i64 (lsp-json-int-field-default position "line" 0)]
        [char0 : i64 (lsp-json-int-field-default position "character" 0)]
        [off : i64 (lsp-offset-at-position text line0 char0)]
        [import-target : LspImportTarget
          (lsp-import-target-at-offset text path stdlib-roots off)]
        [sym : String (lsp-symbol-at-offset text off)]
        (match import-target
          [(LspImportTarget.Found resolved _ _)
            (lsp-write-response
              id
              (lsp-definition-location
                (lsp-resolved-path-to-file-uri resolved)
                1
                1
                1))]
          [(LspImportTarget.Missing)
            (if (string.string-eq sym "")
              (lsp-write-response id json.JsonNull)
              (match (lsp-find-definition
                docs
                uri
                path
                text
                stdlib-roots
                (lsp-symbol-base sym))
                [(LspDefLocation.Found def-uri def-line def-col def-len)
                  (lsp-write-response
                    id
                    (lsp-definition-location def-uri def-line def-col def-len))]
                [(LspDefLocation.Missing) (lsp-write-response id json.JsonNull)]))]))]
    [(LspDocumentLookup.Missing) (lsp-write-response id json.JsonNull)]))

(define (lsp-handle-definition
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json.json-object-get params (& td-key))
      [(json.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(LspJsonText.Ok uri)
            (let
              [pos-key : String "position"]
              (match (json.json-object-get params (& pos-key))
                [(json.JsonFound position)
                  (lsp-definition-respond id uri position docs stdlib-roots)]
                [(json.JsonMissing) (lsp-write-response id json.JsonNull)]))]
          [(LspJsonText.Missing) (lsp-write-response id json.JsonNull)])]
      [(json.JsonMissing) (lsp-write-response id json.JsonNull)])))

(define (lsp-definition-smoke-basic?) : bool
  (let
    [src : String
      "(define (foo [x : i64]) : i64 x)\n(define (bar) : i64 (foo 1))\n"]
    [off : i64 (lsp-offset-at-position src 1 22)]
    [sym : String (lsp-symbol-at-offset src off)]
    (if (not (string.string-eq sym "foo"))
      false
      (match (lsp-find-definition
        (lsp-documents-new)
        "file:///smoke.tl"
        "smoke.tl"
        src
        (vector.string-vec-new)
        (lsp-symbol-base sym))
        [(LspDefLocation.Found _ line col len)
          (and (= line 1) (= col 10) (= len 3))]
        [(LspDefLocation.Missing) false]))))

(define (lsp-definition-smoke-skips-strings?) : bool
  (let
    [src : String
      "(define greeting : String \"(define decoy 1)\")\n(define (use) : i64 0)\n"]
    (match (lsp-find-definition
      (lsp-documents-new)
      "file:///smoke.tl"
      "smoke.tl"
      src
      (vector.string-vec-new)
      "decoy")
      [(LspDefLocation.Found _ _ _ _) false]
      [(LspDefLocation.Missing) true])))

(define (lsp-definition-smoke-skips-char-literals?) : bool
  (let
    [src : String
      "(define (quote-char) : char '\"')\n(define (apostrophe-quote-char) : char '\"')\n(define (target) : i64 1)\n(define (use) : i64 (target))\n"]
    (match (lsp-find-definition
      (lsp-documents-new)
      "file:///smoke.tl"
      "smoke.tl"
      src
      (vector.string-vec-new)
      "target")
      [(LspDefLocation.Found _ line col len)
        (and (= line 3) (= col 10) (= len 6))]
      [(LspDefLocation.Missing) false])))

(define (lsp-definition-smoke-qualified-base?) : bool
  (and
    (string.string-eq (lsp-symbol-base "core/cond") "cond")
    (string.string-eq (lsp-symbol-base "core.cond") "cond")))

(define (lsp-definition-smoke-stdlib-symbol?) : bool
  (let
    [src : String
      "(import stdlib.io)\n(define (main) : i64 (io.panic \"boom\"))\n"]
    [stdlib-suffix : String "/stdlib/io.tl"]
    [off : i64 (lsp-offset-at-position src 1 23)]
    [sym : String (lsp-symbol-at-offset src off)]
    (if (not (string.string-eq sym "io.panic"))
      false
      (match (lsp-find-definition
        (lsp-documents-new)
        "file:///smoke.tl"
        "smoke.tl"
        src
        (vector.string-vec-new)
        (lsp-symbol-base sym))
        [(LspDefLocation.Found def-uri line _ len)
          (and
            (not (string.string-eq def-uri "file:///stdlib/io.tl"))
            (string.string-contains (& def-uri) (& stdlib-suffix))
            (> line 0)
            (= len 5))]
        [(LspDefLocation.Missing) false]))))

(define (lsp-definition-smoke-ok?) : bool
  (and
    (lsp-definition-smoke-basic?)
    (lsp-definition-smoke-skips-strings?)
    (lsp-definition-smoke-skips-char-literals?)
    (lsp-definition-smoke-qualified-base?)
    (lsp-definition-smoke-stdlib-symbol?)))

;; --------------------------------------------------------------------------
;; Completion (textDocument/completion).
;;
;; Offers the language's special forms, builtins, and primitive types, plus the
;; top-level names defined in any open document. The client filters by the
;; typed prefix, so the full candidate set is returned.
;; --------------------------------------------------------------------------
(define (lsp-completion-keywords) : String
  "define lambda let if begin while set! return match foreach cond when unless and or with-arena with-escape with-scratch try unsafe quote quasiquote unquote ann init cast type defstruct defenum defmacro defdispatch import export extern module comptime comptime-decl include-str include-bin test spmd-reduce spmd-scan spmd-broadcast spmd-shuffle program-index program-count")

(define (lsp-completion-builtins) : String
  "ptr-null ptr-read ptr-write! ptr-offset ptr-cast ptr->int int->ptr ptr-null? ptr-addr-of make-array array-ref array-set! array-push! array-data tuple-ref struct-get string-data string-from-bytes program-argc program-argv program-envp cpuid-eax cpuid-ebx cpuid-ecx cpuid-edx xgetbv syscall box box-get array tuple")

(define (lsp-completion-types) : String
  "i64 i32 i16 i8 u64 u32 u16 u8 f64 f32 bool char String str unit never Array Tuple Box Ptr MutPtr")

(define (lsp-split-spaces [s : String]) : vector.StringVec
  (let
    [n : i64 (string.string-length s)]
    [i : i64 0]
    [start : i64 0]
    [acc : vector.StringVec (vector.string-vec-new)]
    (begin
      (while (< i n)
        (begin
          (if (= (string.string-ref s i) ' ')
            (begin
              (if (> i start)
                (set!
                  acc
                  (vector.string-vec-push
                    acc
                    (string.substring s start (- i start))))
                unit)
              (set! start (+ i 1)))
            unit)
          (set! i (+ i 1))))
      (if (> n start)
        (set!
          acc
          (vector.string-vec-push acc (string.substring s start (- n start))))
        unit)
      acc)))

(define (lsp-completion-item [label : String] [kind : i64]) : json.Json
  (lsp-json-object2
    "label"
    (json.JsonString label)
    "kind"
    (lsp-json-number kind)))

(define (lsp-completion-items-from
  [labels : vector.StringVec]
  [kind : i64]
  [idx : i64]
  [acc : json.JsonList]) : json.JsonList
  (if (>= idx (vector.string-vec-len labels))
    acc
    (lsp-completion-items-from
      labels
      kind
      (+ idx 1)
      (lsp-json-list-cons
        (lsp-completion-item (vector.string-vec-get labels idx "") kind)
        acc))))

;; Collect every top-level definition name in `text`, skipping strings/comments.
(define (lsp-collect-def-names [text : String] [acc : vector.StringVec]) : vector.StringVec
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [out : vector.StringVec acc]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref text i)]
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
                      (vector.string-vec-push
                        out
                        (lsp-symbol-at-offset text name-off)))
                    unit)
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
      out)))

(define (lsp-collect-def-names-all
  [docs : LspDocuments]
  [idx : i64]
  [acc : vector.StringVec]) : vector.StringVec
  (if (>= idx (lsp-documents-len (& docs)))
    acc
    (lsp-collect-def-names-all
      docs
      (+ idx 1)
      (lsp-collect-def-names
        (struct-get
          (lsp-documents-get (& docs) idx (lsp-document-fallback))
          text)
        acc))))

(define (lsp-completion-respond [id : json.Json] [docs : LspDocuments]) : unit
  (let
    [names : vector.StringVec
      (lsp-collect-def-names-all docs 0 (vector.string-vec-new))]
    [items : json.JsonList
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
              json.JsonListNil))))]
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
      (while (and (>= p 0) (lsp-ws? (string.string-ref text p)))
        (set! p (- p 1)))
      (if (< p 0)
        false
        (if (not (lsp-ident-char? (string.string-ref text p)))
          false
          (begin
            (while (and (>= p 0) (lsp-ident-char? (string.string-ref text p)))
              (set! p (- p 1)))
            (while (and (>= p 0) (lsp-ws? (string.string-ref text p)))
              (set! p (- p 1)))
            (and (>= p 0) (= (string.string-ref text p) '['))))))))

(define (lsp-inlay-range-line
  [range : json.Json]
  [which : String]
  [fallback : i64]) : i64
  (match (json.json-object-get range (& which))
    [(json.JsonFound endpoint)
      (lsp-json-int-field-default endpoint "line" fallback)]
    [(json.JsonMissing) fallback]))

(define (lsp-inlay-hint-json [line : i64] [col : i64] [ty : String]) : json.Json
  (lsp-json-object4
    "position"
    (lsp-position line col)
    "label"
    (json.JsonString (string.string-append ": " ty))
    "kind"
    (lsp-json-number 1)
    "paddingRight"
    (json.JsonBool true)))

(define (lsp-inlay-build [text : String] [start-line : i64] [end-line : i64]) : json.JsonList
  (let
    [size : i64 (tc-inlay-hints-size)]
    [i : i64 0]
    [acc : json.JsonList json.JsonListNil]
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
  [id : json.Json]
  [uri : String]
  [range : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : unit
  (match (lsp-documents-lookup docs uri)
    [(LspDocumentLookup.Found path text _)
      (let
        [start-line : i64 (lsp-inlay-range-line range "start" 0)]
        [end-line : i64 (lsp-inlay-range-line range "end" 1000000000)]
        (begin
          (tc-inlay-hints-enable!)
          (match (compiler-check-source-with-roots path text stdlib-roots)
            [(ResultCompilerCheck.Ok _) unit]
            [(ResultCompilerCheck.Err _) unit])
          (let
            [hints : json.JsonList (lsp-inlay-build text start-line end-line)]
            (begin
              (tc-inlay-hints-disable!)
              (lsp-write-response id (lsp-json-array hints))))))]
    [(LspDocumentLookup.Missing)
      (lsp-write-response id (lsp-json-array json.JsonListNil))]))

(define (lsp-handle-inlay
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json.json-object-get params (& td-key))
      [(json.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(LspJsonText.Ok uri)
            (let
              [range-key : String "range"]
              (match (json.json-object-get params (& range-key))
                [(json.JsonFound range)
                  (lsp-inlay-respond id uri range docs stdlib-roots)]
                [(json.JsonMissing)
                  (lsp-write-response id (lsp-json-array json.JsonListNil))]))]
          [(LspJsonText.Missing)
            (lsp-write-response id (lsp-json-array json.JsonListNil))])]
      [(json.JsonMissing)
        (lsp-write-response id (lsp-json-array json.JsonListNil))])))

;; --------------------------------------------------------------------------
;; Document formatting (textDocument/formatting), enabling format-on-save.
;;
;; Reuses the `typelisp fmt` formatter (format-rules, width 80). On a parse
;; error the document is left untouched (empty edit list) so saving never
;; mangles in-progress code.
;; --------------------------------------------------------------------------
(define (lsp-formatting-edit [text : String] [formatted : String]) : json.Json
  (let
    [end : LspLineCol (lsp-line-col-at-offset text (string.string-length text))]
    (lsp-json-object2
      "range"
      (lsp-json-object2
        "start"
        (lsp-position 1 1)
        "end"
        (lsp-position (struct-get end line) (struct-get end col)))
      "newText"
      (json.JsonString formatted))))

(define (lsp-formatting-respond
  [id : json.Json]
  [uri : String]
  [docs : LspDocuments]) : unit
  (match (lsp-documents-lookup docs uri)
    [(LspDocumentLookup.Found _ text _)
      (match (format-rules-render-source-width-result text 80)
        [(ResultFormatString.Ok formatted)
          (lsp-write-response
            id
            (lsp-json-array
              (lsp-json-list-cons
                (lsp-formatting-edit text formatted)
                json.JsonListNil)))]
        [(ResultFormatString.Err _)
          (lsp-write-response id (lsp-json-array json.JsonListNil))])]
    [(LspDocumentLookup.Missing)
      (lsp-write-response id (lsp-json-array json.JsonListNil))]))

(define (lsp-format-edit-text [text : String]) : String
  (match (format-rules-render-source-width-result text 80)
    [(ResultFormatString.Ok formatted) formatted]
    [(ResultFormatString.Err _) text]))

(define (lsp-handle-formatting
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json.json-object-get params (& td-key))
      [(json.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(LspJsonText.Ok uri) (lsp-formatting-respond id uri docs)]
          [(LspJsonText.Missing)
            (lsp-write-response id (lsp-json-array json.JsonListNil))])]
      [(json.JsonMissing)
        (lsp-write-response id (lsp-json-array json.JsonListNil))])))

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
          [c : char (string.string-ref text j)]
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
  (if (and (< i n) (= (string.string-ref text i) '('))
    (lsp-skip-paren-group text i n)
    (lsp-scan-ident text i n)))

;; Validate that text is a single complete parenthesized form with no trailing content.
;; Returns true if text is non-empty, starts with '(' (after whitespace), and has a
;; matching closing ')'.
(define (lsp-text-is-valid-form [text : String]) : bool
  (let
    [n : i64 (string.string-length text)]
    (if (= n 0)
      false
      (let
        [start : i64 (lsp-skip-space text 0 n)]
        (if (or (>= start n) (not (= (string.string-ref text start) '(')))
          false
          (let
            [j : i64 start]
            [depth : i64 0]
            [done : bool false]
            (begin
              (while (and (< j n) (not done))
                (let
                  [c : char (string.string-ref text j)]
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
    [n : i64 (string.string-length text)]
    [i : i64 (lsp-skip-space text 0 n)]
    (if (= i n)
      false
      (match (lsp-validate-forms-result text)
        [(LspValidationResult.Valid) true]
        [(LspValidationResult.Invalid _ _ _ _) false]))))

;; Return a formatted error message, or empty string if valid.
(define (lsp-validate-forms-error [text : String]) : String
  (match (lsp-validate-forms-result text)
    [(LspValidationResult.Valid) ""]
    [(LspValidationResult.Invalid line col msg ctx)
      (lsp-str7
        msg
        " at line "
        (string.int->string line)
        ", col "
        (string.int->string col)
        " | "
        ctx)]))

;; Extract the line at position (1-based line)
(define (lsp-line-at [text : String] [line1 : i64]) : String
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [current-line : i64 1]
    [start : i64 0]
    [done : bool false]
    (begin
      (while (and (< i n) (not done))
        (if (= current-line line1)
          (if (or (= i n) (= (string.string-ref text i) '\n'))
            (set! done true)
            (set! i (+ i 1)))
          (begin
            (if (= (string.string-ref text i) '\n')
              (set! current-line (+ current-line 1))
              unit)
            (set! i (+ i 1))
            (set! start i))))
      (if (= current-line line1)
        (string.substring text start (- i start))
        ""))))

;; Validate forms using real parser. Returns ValidLspForms on success,
;; or InvalidLspForms with line, col, message, and context on failure.
(define (lsp-validate-forms-result [text : String]) : LspValidationResult
  (match (lex-spanned-result text)
    [(ResultSpannedTokens.Err err)
      (let
        [span : token.SourceSpan (token.source-error-span err)]
        [line : i64 (token.span-start-line span)]
        [col : i64 (token.span-start-col span)]
        [msg : String (token.source-error-message err)]
        (LspValidationResult.Invalid line col msg (lsp-line-at text line)))]
    [(ResultSpannedTokens.Ok toks)
      (let
        [cur : (Array i64) (make-array i64 1)]
        [dispatch : sym_i64_env.SymI64Env (compiler-parse-dispatch-env)]
        [done : bool false]
        [result : LspValidationResult LspValidationResult.Valid]
        (begin
          (array-set! cur 0 0)
          (while (and
            (not done)
            (not (= (peek-spanned-tag toks cur) (token.tag-end))))
            (match (read-form-spanned-result toks cur)
              [(ResultSpannedSexpr.Err err)
                (let
                  [span : token.SourceSpan (token.source-error-span err)]
                  [line : i64 (token.span-start-line span)]
                  [col : i64 (token.span-start-col span)]
                  [msg : String (token.source-error-message err)]
                  (begin
                    (set!
                      result
                      (LspValidationResult.Invalid
                        line
                        col
                        msg
                        (lsp-line-at text line)))
                    (set! done true)))]
              [(ResultSpannedSexpr.Ok sexpr)
                (match (parse-ast-decl-maybe dispatch sexpr)
                  [(ResultAstMaybeDecl.Err msg)
                    (match (parse-ast-expr dispatch sexpr)
                      [(ResultAstExpr.Err _)
                        (let
                          [span : token.SourceSpan (spanned-sexpr-span sexpr)]
                          [line : i64 (token.span-start-line span)]
                          [col : i64 (token.span-start-col span)]
                          (begin
                            (set!
                              result
                              (LspValidationResult.Invalid
                                line
                                col
                                msg
                                (lsp-line-at text line)))
                            (set! done true)))]
                      [(ResultAstExpr.Ok _) unit])]
                  [(ResultAstMaybeDecl.NoDecl)
                    (match (parse-ast-expr dispatch sexpr)
                      [(ResultAstExpr.Err msg)
                        (let
                          [span : token.SourceSpan (spanned-sexpr-span sexpr)]
                          [line : i64 (token.span-start-line span)]
                          [col : i64 (token.span-start-col span)]
                          (begin
                            (set!
                              result
                              (LspValidationResult.Invalid
                                line
                                col
                                msg
                                (lsp-line-at text line)))
                            (set! done true)))]
                      [(ResultAstExpr.Ok _) unit])]
                  [(ResultAstMaybeDecl.SomeDecl _) unit]
                  [(ResultAstMaybeDecl.Decls _) unit])]))
          result))]))

;; Find the byte offset where the body of a define/defmacro begins,
;; given the offset of the opening '(' of the form.
(define (lsp-find-body-start-offset [text : String] [form-start : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
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
      (if (and (< i n) (= (string.string-ref text i) ':'))
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
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [result : String ""]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref text i)]
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
                    (string.string-eq
                      (string.substring text name-start (- name-end name-start))
                      sym))
                    (let
                      [after : i64 (lsp-skip-space text name-end n)]
                      (if (and
                        (< after n)
                        (= (string.string-ref text after) ':'))
                        (let
                          [ty-start : i64 (lsp-skip-space text (+ after 1) n)]
                          [ty-end : i64 (lsp-scan-type text ty-start n)]
                          (set!
                            result
                            (string.substring text ty-start (- ty-end ty-start))))
                        unit))
                    unit)
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
      result)))

;; Offset of the ( that opens the definition form whose name is `needle`, or -1.
(define (lsp-find-def-form-in [text : String] [needle : String]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< i n) (< found 0))
        (let
          [c : char (string.string-ref text i)]
          (cond
            [(= c ';') (set! i (lsp-skip-line text i n))]
            [(= c '\'') (set! i (lsp-skip-apostrophe-char-literal text i n))]
            [(= c '"') (set! i (lsp-skip-string text i n))]
            [(= c '(')
              (let
                [name-off : i64 (lsp-def-name-offset-at text i n)]
                (if (>= name-off 0)
                  (if (string.string-eq
                    (lsp-symbol-at-offset text name-off)
                    needle)
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
  (if (>= idx (lsp-documents-len (& docs)))
    LspDefSource.Missing
    (let
      [doc : LspDocument
        (lsp-documents-get (& docs) idx (lsp-document-fallback))]
      (if (string.string-eq (struct-get doc uri) current-uri)
        (lsp-hover-resolve-in-docs docs current-uri needle (+ idx 1))
        (let
          [doc-text : String (struct-get doc text)]
          [off : i64 (lsp-find-def-form-in doc-text needle)]
          (if (>= off 0)
            (LspDefSource.Found doc-text off)
            (lsp-hover-resolve-in-docs docs current-uri needle (+ idx 1))))))))

(define (lsp-hover-resolve-in-modules
  [set : LspModuleSet]
  [needle : String]
  [idx : i64]) : LspDefSource
  (if (>= idx (vector.string-vec-len (struct-get set paths)))
    LspDefSource.Missing
    (let
      [src : String (vector.string-vec-get (struct-get set texts) idx "")]
      [off : i64 (lsp-find-def-form-in src needle)]
      (if (>= off 0)
        (LspDefSource.Found src off)
        (lsp-hover-resolve-in-modules set needle (+ idx 1))))))

(define (lsp-hover-resolve
  [docs : LspDocuments]
  [current-uri : String]
  [current-path : String]
  [current-text : String]
  [stdlib-roots : vector.StringVec]
  [needle : String]) : LspDefSource
  (let
    [off : i64 (lsp-find-def-form-in current-text needle)]
    (if (>= off 0)
      (LspDefSource.Found current-text off)
      (match (lsp-hover-resolve-in-docs docs current-uri needle 0)
        [(LspDefSource.Found src form-off) (LspDefSource.Found src form-off)]
        [(LspDefSource.Missing)
          (lsp-hover-resolve-in-modules
            (lsp-transitive-modules current-path current-text stdlib-roots)
            needle
            0)]))))

;; The (define ...) header up to and including the return type, e.g.
;; "(define (foo [a : i64]) : bool".
(define (lsp-define-header [text : String] [form-off : i64]) : String
  (let
    [n : i64 (string.string-length text)]
    [after-open : i64 (lsp-skip-space text (+ form-off 1) n)]
    [kw-end : i64 (lsp-scan-ident text after-open n)]
    [kw : String (string.substring text after-open (- kw-end after-open))]
    (if (or (string.string-eq kw "defenum") (string.string-eq kw "defstruct"))
      ;; Enums/structs have no (params) : ret; show the whole form (variants
      ;; or fields), so multi-line definitions render in full.
      (string.substring
        text
        form-off
        (- (lsp-skip-paren-group text form-off n) form-off))
      (let
        [j : i64 (lsp-skip-space text kw-end n)]
        (begin
          (if (and (< j n) (= (string.string-ref text j) '('))
            (set! j (lsp-skip-paren-group text j n))
            (set! j (lsp-scan-ident text j n)))
          (let
            [k : i64 (lsp-skip-space text j n)]
            (if (and (< k n) (= (string.string-ref text k) ':'))
              (set! j (lsp-scan-type text (lsp-skip-space text (+ k 1) n) n))
              unit))
          (string.substring text form-off (- j form-off)))))))

;; Start index of the line containing `pos`.
(define (lsp-line-start-before [text : String] [pos : i64]) : i64
  (let
    [i : i64 pos]
    (begin
      (while (and (> i 0) (not (= (string.string-ref text (- i 1)) '\n')))
        (set! i (- i 1)))
      i)))

;; True when the line at `line-start` is a ;: or ;# documentation comment.
(define (lsp-doc-comment-line? [text : String] [line-start : i64] [n : i64]) : bool
  (let
    [i : i64 line-start]
    (begin
      (while (and
        (< i n)
        (or
          (= (string.string-ref text i) ' ')
          (= (string.string-ref text i) '\t')))
        (set! i (+ i 1)))
      (and
        (< (+ i 1) n)
        (= (string.string-ref text i) ';')
        (or
          (= (string.string-ref text (+ i 1)) ':')
          (= (string.string-ref text (+ i 1)) '#'))))))

;; Text of a ;: / ;# doc-comment line (prefix and one space stripped).
(define (lsp-doc-comment-text [text : String] [line-start : i64] [n : i64]) : String
  (let
    [i : i64 line-start]
    (begin
      (while (and
        (< i n)
        (or
          (= (string.string-ref text i) ' ')
          (= (string.string-ref text i) '\t')))
        (set! i (+ i 1)))
      (set! i (+ i 2))
      (if (and (< i n) (= (string.string-ref text i) ' '))
        (set! i (+ i 1))
        unit)
      (let
        [end : i64 i]
        (begin
          (while (and (< end n) (not (= (string.string-ref text end) '\n')))
            (set! end (+ end 1)))
          (string.substring text i (- end i)))))))

;; Contiguous doc-comment lines immediately above the definition form, joined.
(define (lsp-doc-comments-above [text : String] [form-off : i64]) : String
  (let
    [n : i64 (string.string-length text)]
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
                (string.string-append
                  (lsp-doc-comment-text text prev-line-start n)
                  (string.string-append "\n" acc)))
              (set! line-start prev-line-start))
            (set! done true))))
      acc)))

(define (lsp-hover-markdown [body : String] [docs : String]) : String
  (if (string.string-eq docs "")
    (string.string-append "```typelisp\n" (string.string-append body "\n```"))
    (string.string-append
      "```typelisp\n"
      (string.string-append body (string.string-append "\n```\n\n" docs)))))

(define (lsp-hover-result
  [markdown : String]
  [line : i64]
  [col : i64]
  [len : i64]) : json.Json
  (lsp-json-object2
    "contents"
    (lsp-json-object2
      "kind"
      (json.JsonString "markdown")
      "value"
      (json.JsonString markdown))
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
    [found : bool false]
    (begin
      (while (and (< i end) (not found))
        (let
          [c : char (string.string-ref text i)]
          (if (= c '"')
            (set! i (lsp-skip-string text i end))
            (if (= c '(')
              (let
                [vs : i64 (lsp-skip-space text (+ i 1) end)]
                [ve : i64 (lsp-scan-ident text vs end)]
                (if (string.string-eq
                  (string.substring text vs (- ve vs))
                  needle)
                  (begin
                    (set!
                      result
                      (string.substring
                        text
                        i
                        (- (lsp-skip-paren-group text i end) i)))
                    (set! found true))
                  (set! i (lsp-skip-paren-group text i end))))
              (set! i (+ i 1))))))
      result)))

;; If `needle` names an enum variant, return its enum name and constructor form.
(define (lsp-enum-of-variant [text : String] [needle : String]) : LspVariantHit
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [enum-name : String ""]
    [variant-form : String ""]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (let
          [c : char (string.string-ref text i)]
          (cond
            [(= c ';') (set! i (lsp-skip-line text i n))]
            [(= c '\'') (set! i (lsp-skip-apostrophe-char-literal text i n))]
            [(= c '"') (set! i (lsp-skip-string text i n))]
            [(= c '(')
              (let
                [kw-start : i64 (lsp-skip-space text (+ i 1) n)]
                [kw-end : i64 (lsp-scan-ident text kw-start n)]
                (if (string.string-eq
                  (string.substring text kw-start (- kw-end kw-start))
                  "defenum")
                  (let
                    [name-start : i64 (lsp-skip-space text kw-end n)]
                    [name-end : i64 (lsp-scan-ident text name-start n)]
                    [form-end : i64 (lsp-skip-paren-group text i n)]
                    [variant : String
                      (lsp-variant-form-in text name-end form-end needle)]
                    (if (string.string-eq variant "")
                      (set! i form-end)
                      (begin
                        (set!
                          enum-name
                          (string.substring
                            text
                            name-start
                            (- name-end name-start)))
                        (set! variant-form (string.string-copy variant))
                        (set! found true))))
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
      (if found
        (LspVariantHit.Found enum-name variant-form)
        LspVariantHit.Missing))))

(define (lsp-resolve-variant-in-docs
  [docs : LspDocuments]
  [current-uri : String]
  [needle : String]
  [idx : i64]) : LspVariantHit
  (if (>= idx (lsp-documents-len (& docs)))
    LspVariantHit.Missing
    (let
      [doc : LspDocument
        (lsp-documents-get (& docs) idx (lsp-document-fallback))]
      (if (string.string-eq (struct-get doc uri) current-uri)
        (lsp-resolve-variant-in-docs docs current-uri needle (+ idx 1))
        (match (lsp-enum-of-variant (struct-get doc text) needle)
          [(LspVariantHit.Found enum-name variant-form)
            (LspVariantHit.Found enum-name variant-form)]
          [(LspVariantHit.Missing)
            (lsp-resolve-variant-in-docs docs current-uri needle (+ idx 1))])))))

(define (lsp-resolve-variant-in-modules
  [set : LspModuleSet]
  [needle : String]
  [idx : i64]) : LspVariantHit
  (if (>= idx (vector.string-vec-len (struct-get set paths)))
    LspVariantHit.Missing
    (match (lsp-enum-of-variant
      (vector.string-vec-get (struct-get set texts) idx "")
      needle)
      [(LspVariantHit.Found enum-name variant-form)
        (LspVariantHit.Found enum-name variant-form)]
      [(LspVariantHit.Missing)
        (lsp-resolve-variant-in-modules set needle (+ idx 1))])))

;; Find the enum/variant in the current document, other open documents, then
;; imported modules (same reach as go-to-definition).
(define (lsp-resolve-variant
  [docs : LspDocuments]
  [current-uri : String]
  [current-path : String]
  [current-text : String]
  [stdlib-roots : vector.StringVec]
  [needle : String]) : LspVariantHit
  (match (lsp-enum-of-variant current-text needle)
    [(LspVariantHit.Found enum-name variant-form)
      (LspVariantHit.Found enum-name variant-form)]
    [(LspVariantHit.Missing)
      (match (lsp-resolve-variant-in-docs docs current-uri needle 0)
        [(LspVariantHit.Found enum-name variant-form)
          (LspVariantHit.Found enum-name variant-form)]
        [(LspVariantHit.Missing)
          (lsp-resolve-variant-in-modules
            (lsp-transitive-modules current-path current-text stdlib-roots)
            needle
            0)])]))

;; Curated hover for builtins, operators, and special forms (no source
;; (define ...) exists for these). Returns markdown, or "" when unknown.
(define (lsp-builtin-hover [name : String]) : String
  (cond
    [(or
        (string.string-eq name "i64")
        (string.string-eq name "i32")
        (string.string-eq name "i16")
        (string.string-eq name "i8"))
      (lsp-hover-markdown
        (string.string-copy name)
        "Signed integer (two's complement) of the named bit width.")]
    [(or
        (string.string-eq name "u64")
        (string.string-eq name "u32")
        (string.string-eq name "u16")
        (string.string-eq name "u8"))
      (lsp-hover-markdown
        (string.string-copy name)
        "Unsigned integer of the named bit width.")]
    [(or (string.string-eq name "f64") (string.string-eq name "f32"))
      (lsp-hover-markdown
        (string.string-copy name)
        "IEEE-754 floating-point number (64- or 32-bit).")]
    [(string.string-eq name "bool")
      (lsp-hover-markdown "bool" "Boolean: `true` or `false`.")]
    [(string.string-eq name "char")
      (lsp-hover-markdown "char" "A character value (written like `'a'`).")]
    [(string.string-eq name "String")
      (lsp-hover-markdown "String" "Owned, heap-allocated UTF-8 string.")]
    [(string.string-eq name "str")
      (lsp-hover-markdown "str" "Borrowed string slice (used as `(& str)`).")]
    [(string.string-eq name "unit")
      (lsp-hover-markdown "unit" "The unit type; its only value is `unit`.")]
    [(string.string-eq name "never")
      (lsp-hover-markdown
        "never"
        "The empty type, for expressions that never return (e.g. `panic`).")]
    [(string.string-eq name "Array")
      (lsp-hover-markdown
        "(Array T)"
        "Dynamically sized, heap-allocated array of `T`.")]
    [(string.string-eq name "Tuple")
      (lsp-hover-markdown
        "(Tuple A B ...)"
        "Fixed-size tuple of the given element types.")]
    [(string.string-eq name "Box")
      (lsp-hover-markdown
        "(Box T)"
        "Heap-allocated `T`; used for recursive data structures.")]
    [(string.string-eq name "Ptr")
      (lsp-hover-markdown
        "(Ptr T)"
        "Raw immutable pointer to `T` (unsafe to dereference).")]
    [(string.string-eq name "MutPtr")
      (lsp-hover-markdown
        "(MutPtr T)"
        "Raw mutable pointer to `T` (unsafe to dereference).")]
    [(or
        (string.string-eq name "+")
        (string.string-eq name "-")
        (string.string-eq name "*")
        (string.string-eq name "/"))
      (lsp-hover-markdown
        (string.string-append name " : (-> num num num)")
        "Arithmetic on two integers or floats of the same numeric type.")]
    [(string.string-eq name "%")
      (lsp-hover-markdown "% : (-> int int int)" "Integer remainder (modulo).")]
    [(or (string.string-eq name "=") (string.string-eq name "!="))
      (lsp-hover-markdown
        (string.string-append name " : (-> a a bool)")
        "Equality / inequality comparison.")]
    [(or
        (string.string-eq name "<")
        (string.string-eq name "<=")
        (string.string-eq name ">")
        (string.string-eq name ">="))
      (lsp-hover-markdown
        (string.string-append name " : (-> a a bool)")
        "Ordering comparison.")]
    [(or (string.string-eq name "shl") (string.string-eq name "shr"))
      (lsp-hover-markdown
        (string.string-append name " : (-> int int int)")
        "Bit shift left / right.")]
    [(or
        (string.string-eq name "bit-and")
        (string.string-eq name "bit-or")
        (string.string-eq name "bit-xor"))
      (lsp-hover-markdown
        (string.string-append name " : (-> int int int)")
        "Bitwise and / or / xor.")]
    [(string.string-eq name "bit-not")
      (lsp-hover-markdown "bit-not : (-> int int)" "Bitwise complement.")]
    [(string.string-eq name "not")
      (lsp-hover-markdown "not : (-> bool bool)" "Logical negation.")]
    [(string.string-eq name "neg")
      (lsp-hover-markdown "neg : (-> num num)" "Numeric negation.")]
    [(string.string-eq name "string-length")
      (lsp-hover-markdown
        "string-length : (-> String i64)"
        "Number of bytes in a string.")]
    [(string.string-eq name "string-ref")
      (lsp-hover-markdown
        "string-ref : (-> String i64 char)"
        "Byte at the given index.")]
    [(string.string-eq name "string-data")
      (lsp-hover-markdown
        "string-data : (-> String (Ptr u8))"
        "Pointer to a string's bytes.")]
    [(string.string-eq name "make-array")
      (lsp-hover-markdown
        "make-array : (-> Type i64 (Array T))"
        "Allocate a zero-initialized array of the given element type and length.")]
    [(string.string-eq name "array-ref")
      (lsp-hover-markdown
        "array-ref : (-> (Array T) i64 T)"
        "Read an array element (bounds-checked).")]
    [(string.string-eq name "array-set!")
      (lsp-hover-markdown
        "array-set! : (-> (Array T) i64 T unit)"
        "Write an array element (bounds-checked).")]
    [(string.string-eq name "array-push!")
      (lsp-hover-markdown
        "array-push! : (-> (Array T) T unit)"
        "Append a value to a dynamic array.")]
    [(string.string-eq name "array-data")
      (lsp-hover-markdown
        "array-data : (-> (Array T) (Ptr T))"
        "Pointer to an array's storage.")]
    [(string.string-eq name "tuple-ref")
      (lsp-hover-markdown
        "tuple-ref : (-> Tuple i64 T)"
        "Read a tuple element by constant index.")]
    [(string.string-eq name "struct-get")
      (lsp-hover-markdown
        "struct-get : (-> Struct field T)"
        "Read a struct field by name.")]
    [(string.string-eq name "ptr-null")
      (lsp-hover-markdown
        "ptr-null : (-> (Ptr T))"
        "Null pointer of the given type.")]
    [(string.string-eq name "ptr-null?")
      (lsp-hover-markdown
        "ptr-null? : (-> (Ptr T) bool)"
        "Whether a pointer is null.")]
    [(string.string-eq name "ptr-read")
      (lsp-hover-markdown
        "ptr-read : (-> (Ptr T) i64 T)"
        "Read the element at an offset from a pointer (unsafe).")]
    [(string.string-eq name "ptr-write!")
      (lsp-hover-markdown
        "ptr-write! : (-> (MutPtr T) i64 T unit)"
        "Write the element at an offset through a pointer (unsafe).")]
    [(string.string-eq name "ptr-offset")
      (lsp-hover-markdown
        "ptr-offset : (-> (Ptr T) i64 (Ptr T))"
        "Offset a pointer by N elements (unsafe).")]
    [(string.string-eq name "ptr-cast")
      (lsp-hover-markdown
        "ptr-cast : (-> (Ptr A) Type (Ptr B))"
        "Reinterpret a pointer's element type (unsafe).")]
    [(string.string-eq name "ptr->int")
      (lsp-hover-markdown
        "ptr->int : (-> (Ptr T) u64)"
        "Pointer to integer address (unsafe).")]
    [(string.string-eq name "int->ptr")
      (lsp-hover-markdown
        "int->ptr : (-> u64 Type (Ptr T))"
        "Integer address to pointer (unsafe).")]
    [(string.string-eq name "if")
      (lsp-hover-markdown
        "(if cond then else)"
        "Conditional expression; both branches must have the same type.")]
    [(string.string-eq name "let")
      (lsp-hover-markdown
        "(let [name : T value] ... body...)"
        "Introduce local bindings, then evaluate the body expressions.")]
    [(string.string-eq name "begin")
      (lsp-hover-markdown
        "(begin expr ...)"
        "Evaluate expressions in sequence; the result is the last.")]
    [(string.string-eq name "while")
      (lsp-hover-markdown
        "(while cond body...)"
        "Loop while the condition is true.")]
    [(string.string-eq name "set!")
      (lsp-hover-markdown "(set! name value)" "Mutate an existing binding.")]
    [(string.string-eq name "match")
      (lsp-hover-markdown
        "(match value [pattern body] ...)"
        "Pattern match on an enum value.")]
    [(string.string-eq name "return")
      (lsp-hover-markdown
        "(return value)"
        "Return early from the enclosing function.")]
    [(string.string-eq name "lambda")
      (lsp-hover-markdown "(lambda [p : T] ... body...)" "Anonymous function.")]
    [(string.string-eq name "cast")
      (lsp-hover-markdown
        "(cast value : Type)"
        "Convert a value to another numeric or pointer type.")]
    [(string.string-eq name "unsafe")
      (lsp-hover-markdown
        "(unsafe body)"
        "Permit unsafe operations (raw pointers, syscalls) within the body.")]
    [else ""]))

(define (lsp-hover-respond
  [id : json.Json]
  [uri : String]
  [position : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : unit
  (match (lsp-documents-lookup docs uri)
    [(LspDocumentLookup.Found path text _)
      (let
        [line0 : i64 (lsp-json-int-field-default position "line" 0)]
        [char0 : i64 (lsp-json-int-field-default position "character" 0)]
        [off : i64 (lsp-offset-at-position text line0 char0)]
        [sym : String (lsp-symbol-at-offset text off)]
        (if (string.string-eq sym "")
          (lsp-write-response id json.JsonNull)
          (let
            [needle : String (lsp-symbol-base sym)]
            [bind-type : String (lsp-binding-type text needle off)]
            [builtin : String (lsp-builtin-hover needle)]
            (if (not (string.string-eq bind-type ""))
              (lsp-write-response
                id
                (lsp-hover-result
                  (lsp-hover-markdown
                    (string.string-append
                      needle
                      (string.string-append " : " bind-type))
                    "")
                  line0
                  char0
                  (string.string-length sym)))
              (if (not (string.string-eq builtin ""))
                (lsp-write-response
                  id
                  (lsp-hover-result
                    builtin
                    line0
                    char0
                    (string.string-length sym)))
                (match (lsp-hover-resolve
                  docs
                  uri
                  path
                  text
                  stdlib-roots
                  needle)
                  [(LspDefSource.Found def-text form-off)
                    (lsp-write-response
                      id
                      (lsp-hover-result
                        (lsp-hover-markdown
                          (lsp-define-header def-text form-off)
                          (lsp-doc-comments-above def-text form-off))
                        line0
                        char0
                        (string.string-length sym)))]
                  [(LspDefSource.Missing)
                    (match (lsp-resolve-variant
                      docs
                      uri
                      path
                      text
                      stdlib-roots
                      needle)
                      [(LspVariantHit.Found enum-name variant-form)
                        (lsp-write-response
                          id
                          (lsp-hover-result
                            (lsp-hover-markdown
                              variant-form
                              (string.string-append
                                "Variant of `"
                                (string.string-append enum-name "`.")))
                            line0
                            char0
                            (string.string-length sym)))]
                      [(LspVariantHit.Missing)
                        (lsp-write-response id json.JsonNull)])]))))))]
    [(LspDocumentLookup.Missing) (lsp-write-response id json.JsonNull)]))

(define (lsp-handle-hover
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json.json-object-get params (& td-key))
      [(json.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(LspJsonText.Ok uri)
            (let
              [pos-key : String "position"]
              (match (json.json-object-get params (& pos-key))
                [(json.JsonFound position)
                  (lsp-hover-respond id uri position docs stdlib-roots)]
                [(json.JsonMissing) (lsp-write-response id json.JsonNull)]))]
          [(LspJsonText.Missing) (lsp-write-response id json.JsonNull)])]
      [(json.JsonMissing) (lsp-write-response id json.JsonNull)])))

;; --------------------------------------------------------------------------
;; Document links (textDocument/documentLink): make import operands clickable,
;; navigating to the resolved module file.
;; --------------------------------------------------------------------------
(define (lsp-document-link-json
  [text : String]
  [resolved : String]
  [content-start : i64]
  [content-end : i64]) : json.Json
  (let
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
      (json.JsonString (lsp-resolved-path-to-file-uri resolved)))))

(define (lsp-document-links
  [text : String]
  [path : String]
  [stdlib-roots : vector.StringVec]) : json.JsonList
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [acc : json.JsonList json.JsonListNil]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref text i)]
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
                  (string.string-eq
                    (string.substring text kw-start (- kw-end kw-start))
                    "import"))
                  (let
                    [operand-start : i64 (lsp-skip-space text kw-end n)]
                    (match (lsp-resolve-import-target-at
                      text
                      path
                      stdlib-roots
                      operand-start)
                      [(LspImportTarget.Found resolved start end)
                        (begin
                          (set!
                            acc
                            (lsp-json-list-cons
                              (lsp-document-link-json text resolved start end)
                              acc))
                          (set! i end))]
                      [(LspImportTarget.Missing) (set! i (+ i 1))]))
                  (set! i (+ i 1))))]
            [else (set! i (+ i 1))])))
      acc)))

(define (lsp-document-link-respond
  [id : json.Json]
  [uri : String]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : unit
  (match (lsp-documents-lookup docs uri)
    [(LspDocumentLookup.Found path text _)
      (lsp-write-response
        id
        (lsp-json-array (lsp-document-links text path stdlib-roots)))]
    [(LspDocumentLookup.Missing)
      (lsp-write-response id (lsp-json-array json.JsonListNil))]))

(define (lsp-handle-document-link
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : unit
  (let
    [td-key : String "textDocument"]
    (match (json.json-object-get params (& td-key))
      [(json.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(LspJsonText.Ok uri)
            (lsp-document-link-respond id uri docs stdlib-roots)]
          [(LspJsonText.Missing)
            (lsp-write-response id (lsp-json-array json.JsonListNil))])]
      [(json.JsonMissing)
        (lsp-write-response id (lsp-json-array json.JsonListNil))])))

(define (lsp-maybe-write-method-not-found [message : json.Json]) : unit
  (let
    [key : String "id"]
    (match (json.json-object-get message (& key))
      [(json.JsonFound id) (lsp-write-error id -32601 "Method not found")]
      [(json.JsonMissing) unit])))

(define (lsp-decl-entry-fallback) : LspDeclEntry
  (LspDeclEntry "" "" 0 0 0 0 0 0 0))

(define (lsp-decl-kind-at [text : String] [i : i64] [n : i64]) : String
  (let
    [after-open : i64 (lsp-skip-space text (+ i 1) n)]
    [kw-end : i64 (lsp-scan-ident text after-open n)]
    (if (<= kw-end after-open)
      "unknown"
      (let
        [kw : String (string.substring text after-open (- kw-end after-open))]
        (cond
          [(string.string-eq kw "define") "function"]
          [(string.string-eq kw "defmacro") "macro"]
          [(string.string-eq kw "defstruct") "struct"]
          [(string.string-eq kw "defenum") "enum"]
          [(string.string-eq kw "defdispatch") "dispatch"]
          [(string.string-eq kw "extern") "extern"]
          [else "unknown"])))))

(define (lsp-scan-decls [text : String]) : LspDeclList
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [depth : i64 0]
    [result : LspDeclList (lsp-decl-list-with-capacity 16)]
    [lc-cache : LspLineColCache (LspLineColCache -1 1 1)]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref text i)]
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
                        [form-start-lc : LspLineCol
                          (lsp-line-col-cache-at-offset! lc-cache text i)]
                        [name-lc : LspLineCol
                          (lsp-line-col-cache-at-offset! lc-cache text name-off)]
                        [form-end-lc : LspLineCol
                          (lsp-line-col-cache-at-offset! lc-cache text form-end)]
                        (lsp-decl-list-push
                          (&mut result)
                          (LspDeclEntry
                            kind
                            name
                            (struct-get name-lc line)
                            (struct-get name-lc col)
                            (string.string-length name)
                            (struct-get form-start-lc line)
                            (struct-get form-start-lc col)
                            (struct-get form-end-lc line)
                            (struct-get form-end-lc col))))
                      unit))
                  unit)
                (set! i (+ i 1)))]
            [(= c ')')
              (begin
                (set! depth (- depth 1))
                (set! i (+ i 1)))]
            [else (set! i (+ i 1))])))
      result)))

;; Helper: extract document from params
(define (lsp-get-document [params : json.Json] [docs : LspDocuments]) : LspDocumentLookup
  (let
    [key : String "textDocument"]
    (match (json.json-object-get params (& key))
      [(json.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(LspJsonText.Ok uri) (lsp-documents-lookup docs uri)]
          [(LspJsonText.Missing) LspDocumentLookup.Missing])]
      [(json.JsonMissing) LspDocumentLookup.Missing])))

(define (lsp-get-document-decls [params : json.Json] [docs : LspDocuments]) : LspDocumentDeclsLookup
  (let
    [key : String "textDocument"]
    (match (json.json-object-get params (& key))
      [(json.JsonFound document)
        (match (lsp-json-string-field document "uri")
          [(LspJsonText.Ok uri)
            (let
              [idx : i64 (lsp-documents-find-index docs uri)]
              (if (>= idx 0)
                (let
                  [doc : LspDocument
                    (lsp-documents-get (& docs) idx (lsp-document-fallback))]
                  (LspDocumentDeclsLookup.Found
                    (struct-get doc path)
                    (struct-get doc text)
                    (struct-get doc diagnostic-uri)
                    (lsp-document-decls doc docs)))
                LspDocumentDeclsLookup.Missing))]
          [(LspJsonText.Missing) LspDocumentDeclsLookup.Missing])]
      [(json.JsonMissing) LspDocumentDeclsLookup.Missing])))

;; Helper: get cached decls or scan and cache them
(define (lsp-document-decls-cache-on-current-arena
  [doc : LspDocument]
  [docs : LspDocuments]) : LspDeclList
  (let
    [text : String (struct-get doc text)]
    [uri : String (struct-get doc uri)]
    [scanned : LspDeclList (lsp-scan-decls text)]
    [idx : i64 (lsp-documents-find-index docs uri)]
    (begin
      (if (>= idx 0)
        (begin
          (lsp-documents-set!
            (&mut docs)
            idx
            (LspDocument
              uri
              (struct-get doc path)
              text
              (struct-get doc diagnostic-uri)
              scanned
              true))
          unit)
        unit)
      scanned)))

(define (lsp-document-decls [doc : LspDocument] [docs : LspDocuments]) : LspDeclList
  (let
    [cached : LspDeclList (struct-get doc decls)]
    (if (struct-get doc decls-valid)
      cached
      (let
        [active-arena : i64 (arena.tl_arena_current)]
        (begin
          (if (> lsp-document-cache-arena 0)
            (unsafe
              (arena.tl_arena_set lsp-document-cache-arena))
            unit)
          (let
            [scanned : LspDeclList
              (lsp-document-decls-cache-on-current-arena doc docs)]
            (begin
              (if (> lsp-document-cache-arena 0)
                (unsafe
                  (arena.tl_arena_set active-arena))
                unit)
              scanned)))))))

;; Helper: build json.Json array of declaration names from LspDeclList
(define (lsp-decls-to-name-list [decls : LspDeclList] [idx : i64]) : json.JsonList
  (if (>= idx (lsp-decl-list-len (& decls)))
    json.JsonListNil
    (let
      [entry : LspDeclEntry
        (lsp-decl-list-get (& decls) idx (lsp-decl-entry-fallback))]
      [name : String (struct-get entry name)]
      (lsp-json-list-cons
        (json.JsonString name)
        (lsp-decls-to-name-list decls (+ idx 1))))))

;; Helper: build json.Json array of all declarations with metadata
(define (lsp-decls-to-json-list [decls : LspDeclList] [idx : i64]) : json.JsonList
  (if (>= idx (lsp-decl-list-len (& decls)))
    json.JsonListNil
    (let
      [entry : LspDeclEntry
        (lsp-decl-list-get (& decls) idx (lsp-decl-entry-fallback))]
      [obj : json.Json
        (lsp-json-object
          (lsp-json-member
            "kind"
            (json.JsonString (struct-get entry kind))
            (lsp-json-member
              "name"
              (json.JsonString (struct-get entry name))
              (lsp-json-member
                "line"
                (lsp-json-number (struct-get entry name-line))
                (lsp-json-member
                  "column"
                  (lsp-json-number (struct-get entry name-col))
                  (lsp-json-member
                    "length"
                    (lsp-json-number (struct-get entry name-len))
                    json.JsonMemberListNil))))))]
      (lsp-json-list-cons obj (lsp-decls-to-json-list decls (+ idx 1))))))

;; Helper: replace text from (sl,sc) to (el,ec) with new-text
;; Positions are 1-based (from scanner), convert to 0-based for offset-at-position
(define (lsp-edit-range-at-offset
  [text : String]
  [start-off : i64]
  [end-off : i64]
  [new-text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    [new-len : i64 (string.string-length new-text)]
    [removed-len : i64 (- end-off start-off)]
    [capacity : i64 (+ (- n removed-len) new-len)]
    [buf : byte_buf.ByteBuf (byte_buf.byte-buf-with-capacity capacity)]
    (begin
      (set! buf (byte_buf.byte-buf-append-string-range buf text 0 start-off))
      (set! buf (byte_buf.byte-buf-append-string buf new-text))
      (set!
        buf
        (byte_buf.byte-buf-append-string-range buf text end-off (- n end-off)))
      (byte_buf.byte-buf-to-string buf))))

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
    (lsp-edit-range-at-offset text start-off end-off new-text)))

;; tl/listFunctions - List all top-level function names in a document
(define (lsp-handle-tl-list-functions
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document-decls params docs)
    [(LspDocumentDeclsLookup.Found path text _ decls)
      (let
        [items : json.JsonList (lsp-decls-to-name-list decls 0)]
        (begin
          (lsp-write-response id (lsp-json-array items))
          (LspHandleResult.Continue docs)))]
    [(LspDocumentDeclsLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

;; tl/astDump - Return full declaration metadata
(define (lsp-handle-tl-ast-dump
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document-decls params docs)
    [(LspDocumentDeclsLookup.Found path text _ decls)
      (let
        [items : json.JsonList (lsp-decls-to-json-list decls 0)]
        (begin
          (lsp-write-response id (lsp-json-array items))
          (LspHandleResult.Continue docs)))]
    [(LspDocumentDeclsLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

;; tl/findPosition - Find the name position {line, character} of a top-level form
(define (lsp-handle-tl-find-position
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document-decls params docs)
    [(LspDocumentDeclsLookup.Found path text _ decls)
      (match (lsp-json-string-field params "name")
        [(LspJsonText.Ok name)
          (let
            [kind-param : String
              (lsp-json-string-field-default params "kind" "")]
            [i : i64 0]
            [n : i64 (lsp-decl-list-len (& decls))]
            [found : bool false]
            [result-line : i64 0]
            [result-col : i64 0]
            (begin
              (while (and (< i n) (not found))
                (let
                  [entry : LspDeclEntry
                    (lsp-decl-list-get (& decls) i (lsp-decl-entry-fallback))]
                  (if (and
                    (string.string-eq (struct-get entry name) name)
                    (or
                      (= (string.string-length kind-param) 0)
                      (string.string-eq (struct-get entry kind) kind-param)))
                    (begin
                      (set! result-line (struct-get entry name-line))
                      (set! result-col (struct-get entry name-col))
                      (set! found true)
                      unit)
                    (begin
                      (set! i (+ i 1))
                      unit))))
              (if found
                (begin
                  (lsp-write-response
                    id
                    (lsp-json-object2
                      "line"
                      (lsp-json-number (- result-line 1))
                      "character"
                      (lsp-json-number (- result-col 1))))
                  (LspHandleResult.Continue docs))
                (begin
                  (lsp-write-error id -32600 "Form not found")
                  (LspHandleResult.Continue docs)))))]
        [(LspJsonText.Missing)
          (begin
            (lsp-write-error id -32600 "Missing name parameter")
            (LspHandleResult.Continue docs))])]
    [(LspDocumentDeclsLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

;; tl/replace - legacy method name routed to position-based replacement
;; tl/deleteFunction - legacy method name routed to position-based deletion
;; Helper: get offset from LspDeclEntry start position
(define (lsp-offset-from-entry-start [text : String] [entry : LspDeclEntry]) : i64
  (lsp-offset-at-position
    text
    (- (struct-get entry form-start-line) 1)
    (- (struct-get entry form-start-col) 1)))

;; Helper: move a form after another form
(define (lsp-move-form-after
  [text : String]
  [source : LspDeclEntry]
  [dest : LspDeclEntry]) : String
  (let
    [source-start : i64 (lsp-offset-from-entry-start text source)]
    [source-end : i64 (lsp-offset-from-entry-end text source)]
    [dest-start : i64 (lsp-offset-from-entry-start text dest)]
    [dest-end : i64 (lsp-offset-from-entry-end text dest)]
    [source-text : String
      (string.substring text source-start (- source-end source-start))]
    [text-without-source : String
      (string.string-append
        (string.substring text 0 source-start)
        (string.substring
          text
          source-end
          (- (string.string-length text) source-end)))]
    [dest-end-new : i64
      (if (< source-start dest-start)
        (- dest-end (- source-end source-start))
        dest-end)]
    [before : String (string.substring text-without-source 0 dest-end-new)]
    [after : String
      (string.substring
        text-without-source
        dest-end-new
        (- (string.string-length text-without-source) dest-end-new))]
    (lsp-str4 before "
" source-text after)))

;; Helper: get offset from LspDeclEntry end position
(define (lsp-offset-from-entry-end [text : String] [entry : LspDeclEntry]) : i64
  (lsp-offset-at-position
    text
    (- (struct-get entry form-end-line) 1)
    (- (struct-get entry form-end-col) 1)))

;; Helper: resolve a structural edit target from either a position or a name param.
(define (lsp-structural-move-name [params : json.Json] [text : String]) : String
  (let
    [pos-key : String "position"]
    (match (json.json-object-get params (& pos-key))
      [(json.JsonFound position)
        (let
          [line : i64 (lsp-json-int-field-default position "line" 0)]
          [col : i64 (lsp-json-int-field-default position "character" 0)]
          (lsp-find-and-extract-name text line col))]
      [(json.JsonMissing)
        (match (lsp-json-string-field params "name")
          [(LspJsonText.Ok name) name]
          [(LspJsonText.Missing) ""])])))

(define (lsp-decl-list-find-name [decls : LspDeclList] [name : String]) : i64
  (let
    [i : i64 0]
    [n : i64 (lsp-decl-list-len (& decls))]
    [found : i64 -1]
    (begin
      (while (and (< i n) (= found -1))
        (let
          [entry : LspDeclEntry
            (lsp-decl-list-get (& decls) i (lsp-decl-entry-fallback))]
          (if (string.string-eq (struct-get entry name) name)
            (set! found i)
            (set! i (+ i 1)))))
      found)))

(define (lsp-write-structural-edit-success
  [id : json.Json]
  [docs : LspDocuments]
  [result : String]) : LspHandleResult
  (let
    [formatted : String (lsp-format-edit-text result)]
    (begin
      (lsp-write-response
        id
        (lsp-json-object2
          "success"
          (json.JsonBool true)
          "text"
          (json.JsonString formatted)))
      (LspHandleResult.Continue docs))))

(define (lsp-structural-move-after-destination
  [id : json.Json]
  [docs : LspDocuments]
  [text : String]
  [decls : LspDeclList]
  [name : String]
  [destination : String]) : LspHandleResult
  (let
    [found-idx : i64 (lsp-decl-list-find-name decls name)]
    [dest-idx : i64 (lsp-decl-list-find-name decls destination)]
    (cond
      [(= found-idx -1)
        (begin
          (lsp-write-error id -32600 "Declaration not found")
          (LspHandleResult.Continue docs))]
      [(= dest-idx -1)
        (begin
          (lsp-write-error id -32600 "Destination declaration not found")
          (LspHandleResult.Continue docs))]
      [(= found-idx dest-idx)
        (begin
          (lsp-write-error id -32600 "Cannot move declaration to itself")
          (LspHandleResult.Continue docs))]
      [else
        (let
          [found-entry : LspDeclEntry
            (lsp-decl-list-get (& decls) found-idx (lsp-decl-entry-fallback))]
          [dest-entry : LspDeclEntry
            (lsp-decl-list-get (& decls) dest-idx (lsp-decl-entry-fallback))]
          [result : String (lsp-move-form-after text found-entry dest-entry)]
          (lsp-write-structural-edit-success id docs result))])))

(define (lsp-structural-move-direction
  [id : json.Json]
  [docs : LspDocuments]
  [text : String]
  [decls : LspDeclList]
  [name : String]
  [direction : String]) : LspHandleResult
  (let
    [found-idx : i64 (lsp-decl-list-find-name decls name)]
    [n : i64 (lsp-decl-list-len (& decls))]
    [target-idx : i64
      (if (string.string-eq direction "up")
        (- found-idx 1)
        (if (string.string-eq direction "down")
          (+ found-idx 1)
          -1))]
    (cond
      [(= found-idx -1)
        (begin
          (lsp-write-error id -32600 "Declaration not found")
          (LspHandleResult.Continue docs))]
      [(or (< target-idx 0) (>= target-idx n) (= target-idx -1))
        (begin
          (lsp-write-error id -32600 "Invalid direction or cannot move further")
          (LspHandleResult.Continue docs))]
      [else
        (let
          [found-entry : LspDeclEntry
            (lsp-decl-list-get (& decls) found-idx (lsp-decl-entry-fallback))]
          [target-entry : LspDeclEntry
            (lsp-decl-list-get (& decls) target-idx (lsp-decl-entry-fallback))]
          [found-first : bool (< found-idx target-idx)]
          [first-entry : LspDeclEntry
            (if found-first
              found-entry
              target-entry)]
          [second-entry : LspDeclEntry
            (if found-first
              target-entry
              found-entry)]
          [first-start : i64 (lsp-offset-from-entry-start text first-entry)]
          [first-end : i64 (lsp-offset-from-entry-end text first-entry)]
          [second-start : i64 (lsp-offset-from-entry-start text second-entry)]
          [second-end : i64 (lsp-offset-from-entry-end text second-entry)]
          [text-before : String (string.substring text 0 first-start)]
          [second-text : String
            (string.substring text second-start (- second-end second-start))]
          [middle : String
            (string.substring text first-end (- second-start first-end))]
          [first-text : String
            (string.substring text first-start (- first-end first-start))]
          [text-after : String
            (string.substring
              text
              second-end
              (- (string.string-length text) second-end))]
          [result : String
            (lsp-str5 text-before second-text middle first-text text-after)]
          (lsp-write-structural-edit-success id docs result))])))

;; tl/move - Move a form by name or position.
(define (lsp-handle-tl-structural-move
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document-decls params docs)
    [(LspDocumentDeclsLookup.Found path text _ decls)
      (let
        [name : String (lsp-structural-move-name params text)]
        (if (= (string.string-length name) 0)
          (begin
            (lsp-write-error id -32600 "Missing name or position parameter")
            (LspHandleResult.Continue docs))
          (match (lsp-json-string-field params "destination")
            [(LspJsonText.Ok destination)
              (lsp-structural-move-after-destination
                id
                docs
                text
                decls
                name
                destination)]
            [(LspJsonText.Missing)
              (match (lsp-json-string-field params "direction")
                [(LspJsonText.Ok direction)
                  (lsp-structural-move-direction
                    id
                    docs
                    text
                    decls
                    name
                    direction)]
                [(LspJsonText.Missing)
                  (begin
                    (lsp-write-error
                      id
                      -32600
                      "Missing direction or destination parameter")
                    (LspHandleResult.Continue docs))])])))]
    [(LspDocumentDeclsLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

;; tl/expandMacro - Find the form at cursor position and return its text
;; For now, returns the top-level form by name.
;; Full macro expansion would require compiler macro expansion integration.
(define (lsp-handle-tl-expand-macro
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document-decls params docs)
    [(LspDocumentDeclsLookup.Found path text _ decls)
      (match (lsp-json-string-field params "name")
        [(LspJsonText.Ok name)
          (let
            [i : i64 0]
            [n : i64 (lsp-decl-list-len (& decls))]
            [found-idx : i64 -1]
            (begin
              (while (and (< i n) (= found-idx -1))
                (let
                  [entry : LspDeclEntry
                    (lsp-decl-list-get (& decls) i (lsp-decl-entry-fallback))]
                  (if (string.string-eq (struct-get entry name) name)
                    (set! found-idx i)
                    (set! i (+ i 1)))))
              (if (= found-idx -1)
                (begin
                  (lsp-write-error id -32600 "Form not found")
                  (LspHandleResult.Continue docs))
                (let
                  [entry : LspDeclEntry
                    (lsp-decl-list-get
                      (& decls)
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
                    (string.substring text start-off (- end-off start-off))]
                  (begin
                    (lsp-write-response
                      id
                      (lsp-json-object2
                        "success"
                        (json.JsonBool true)
                        "text"
                        (json.JsonString result)))
                    (LspHandleResult.Continue docs))))))]
        [(LspJsonText.Missing)
          (begin
            (lsp-write-error id -32600 "Missing name parameter")
            (LspHandleResult.Continue docs))])]
    [(LspDocumentDeclsLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

;; tl/check - Typecheck a document and return success/error JSON response
(define (lsp-handle-tl-check
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : LspHandleResult
  (let
    [uri : String
      (match (lsp-json-string-field params "uri")
        [(LspJsonText.Ok u) u]
        [(LspJsonText.Missing)
          (let
            [td-key : String "textDocument"]
            (match (json.json-object-get params (& td-key))
              [(json.JsonFound document)
                (match (lsp-json-string-field document "uri")
                  [(LspJsonText.Ok u) u]
                  [(LspJsonText.Missing) ""])]
              [(json.JsonMissing) ""]))])]
    (if (string.string-eq uri "")
      (begin
        (lsp-write-error id -32600 "Missing uri parameter")
        (LspHandleResult.Continue docs))
      (match (lsp-documents-lookup docs uri)
        [(LspDocumentLookup.Found path text _)
          (match (compiler-check-source-with-roots path text stdlib-roots)
            [(ResultCompilerCheck.Ok _)
              (begin
                (lsp-write-response
                  id
                  (lsp-json-object1 "success" (json.JsonBool true)))
                (LspHandleResult.Continue docs))]
            [(ResultCompilerCheck.Err diag)
              (begin
                (lsp-write-response
                  id
                  (lsp-json-object2
                    "success"
                    (json.JsonBool false)
                    "error"
                    (json.JsonString
                      (compiler-diagnostic-message (box-get diag)))))
                (LspHandleResult.Continue docs))])]
        [(LspDocumentLookup.Missing)
          (match (lsp-file-uri-to-path uri)
            [(LspUriPath.Ok path)
              (let
                [text : String (io.read-file-or (& path) "")]
                (if (string.string-eq text "")
                  (begin
                    (lsp-write-response
                      id
                      (lsp-json-object2
                        "success"
                        (json.JsonBool false)
                        "error"
                        (json.JsonString "Could not read document")))
                    (LspHandleResult.Continue docs))
                  (match (compiler-check-source-with-roots
                    path
                    text
                    stdlib-roots)
                    [(ResultCompilerCheck.Ok _)
                      (begin
                        (lsp-write-response
                          id
                          (lsp-json-object1 "success" (json.JsonBool true)))
                        (LspHandleResult.Continue docs))]
                    [(ResultCompilerCheck.Err diag)
                      (begin
                        (lsp-write-response
                          id
                          (lsp-json-object2
                            "success"
                            (json.JsonBool false)
                            "error"
                            (json.JsonString
                              (compiler-diagnostic-message (box-get diag)))))
                        (LspHandleResult.Continue docs))])))]
            [(LspUriPath.Err message)
              (begin
                (lsp-write-response
                  id
                  (lsp-json-object2
                    "success"
                    (json.JsonBool false)
                    "error"
                    (json.JsonString message)))
                (LspHandleResult.Continue docs))])]))))

(define (lsp-nearest-inlay-hint-index [line1 : i64] [col1 : i64]) : i64
  (let
    [size : i64 (tc-inlay-hints-size)]
    [i : i64 0]
    [best-idx : i64 -1]
    [best-dist : i64 999999999]
    (begin
      (while (< i size)
        (let
          [hint-line : i64 (tc-inlay-hint-line-at i)]
          [hint-col : i64 (tc-inlay-hint-col-at i)]
          [d-line : i64
            (if (< hint-line line1)
              (- line1 hint-line)
              (- hint-line line1))]
          [d-col : i64
            (if (< hint-col col1)
              (- col1 hint-col)
              (- hint-col col1))]
          [dist : i64 (+ (* d-line 1000) d-col)]
          (begin
            (if (< dist best-dist)
              (begin
                (set! best-dist dist)
                (set! best-idx i))
              unit)
            (set! i (+ i 1)))))
      best-idx)))

;; tl/getType - Type of expression at cursor
(define (lsp-handle-tl-get-type-at
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(LspDocumentLookup.Found path text _)
      (let
        [pos-key : String "position"]
        (match (json.json-object-get params (& pos-key))
          [(json.JsonFound position)
            (let
              [line0 : i64 (lsp-json-int-field-default position "line" 0)]
              [char0 : i64 (lsp-json-int-field-default position "character" 0)]
              [line1 : i64 (+ line0 1)]
              [col1 : i64 (+ char0 1)]
              (begin
                (tc-inlay-hints-enable!)
                (match (compiler-check-source-with-roots path text stdlib-roots)
                  [(ResultCompilerCheck.Ok _) unit]
                  [(ResultCompilerCheck.Err _) unit])
                (let
                  [found-idx : i64 (lsp-nearest-inlay-hint-index line1 col1)]
                  (begin
                    (tc-inlay-hints-disable!)
                    (if (= found-idx -1)
                      ;; Fallback: try to find explicit type annotation
                      (let
                        [off : i64 (lsp-offset-at-position text line0 char0)]
                        [sym : String (lsp-symbol-at-offset text off)]
                        [bind-type : String
                          (if (string.string-eq sym "")
                            ""
                            (lsp-binding-type text (lsp-symbol-base sym) off))]
                        (if (string.string-eq bind-type "")
                          (begin
                            (lsp-write-response
                              id
                              (lsp-json-object2
                                "success"
                                (json.JsonBool false)
                                "error"
                                (json.JsonString
                                  "No type information at this position")))
                            (LspHandleResult.Continue docs))
                          (begin
                            (lsp-write-response
                              id
                              (lsp-json-object2
                                "success"
                                (json.JsonBool true)
                                "type"
                                (json.JsonString bind-type)))
                            (LspHandleResult.Continue docs))))
                      (let
                        [found-type : String (tc-inlay-hint-type-at found-idx)]
                        (begin
                          (lsp-write-response
                            id
                            (lsp-json-object2
                              "success"
                              (json.JsonBool true)
                              "type"
                              (json.JsonString found-type)))
                          (LspHandleResult.Continue docs))))))))]
          [(json.JsonMissing)
            (begin
              (lsp-write-error id -32600 "Missing position parameter")
              (LspHandleResult.Continue docs))]))]
    [(LspDocumentLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

;; Helper: find all word-bounded occurrences of name in text
(define (lsp-find-references-in-text
  [text : String]
  [name : String]
  [i : i64]
  [n : i64]
  [acc : json.JsonList]) : json.JsonList
  (if (>= i n)
    acc
    (let
      [name-len : i64 (string.string-length name)]
      (if (and
        (<= (+ i name-len) n)
        (string.is-string-prefix-at (& text) (& name) i)
        (or (= i 0) (not (lsp-ident-char? (string.string-ref text (- i 1)))))
        (or
          (>= (+ i name-len) n)
          (not (lsp-ident-char? (string.string-ref text (+ i name-len))))))
        (let
          [lc : LspLineCol (lsp-line-col-at-offset text i)]
          (lsp-find-references-in-text
            text
            name
            (+ i 1)
            n
            (lsp-json-list-cons
              (lsp-position (struct-get lc line) (struct-get lc col))
              acc)))
        (lsp-find-references-in-text text name (+ i 1) n acc)))))

;; tl/findReferences - All uses of a name
(define (lsp-handle-tl-find-references
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(LspDocumentLookup.Found _ text _)
      (let
        [name-from-field : LspJsonText (lsp-json-string-field params "name")]
        [name : String
          (match name-from-field
            [(LspJsonText.Ok n) n]
            [(LspJsonText.Missing)
              (let
                [pos-key : String "position"]
                (match (json.json-object-get params (& pos-key))
                  [(json.JsonFound position)
                    (let
                      [line0 : i64
                        (lsp-json-int-field-default position "line" 0)]
                      [char0 : i64
                        (lsp-json-int-field-default position "character" 0)]
                      [off : i64 (lsp-offset-at-position text line0 char0)]
                      (lsp-symbol-at-offset text off))]
                  [(json.JsonMissing) ""]))])]
        (if (string.string-eq name "")
          (begin
            (lsp-write-error id -32600 "Missing name or position parameter")
            (LspHandleResult.Continue docs))
          (let
            [refs : json.JsonList
              (lsp-find-references-in-text
                text
                name
                0
                (string.string-length text)
                json.JsonListNil)]
            (begin
              (lsp-write-response
                id
                (lsp-json-object2
                  "success"
                  (json.JsonBool true)
                  "references"
                  (lsp-json-array refs)))
              (LspHandleResult.Continue docs)))))]
    [(LspDocumentLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

(define (lsp-tl-source-file-name? [entry : String]) : bool
  (let
    [entry-len : i64 (string.string-length entry)]
    (if (< entry-len 3)
      false
      (and
        (= (string.string-ref entry (- entry-len 3)) '.')
        (= (string.string-ref entry (- entry-len 2)) 't')
        (= (string.string-ref entry (- entry-len 1)) 'l')))))

(define (lsp-decls-contain-name? [decls : LspDeclList] [needle : String]) : bool
  (let
    [n : i64 (lsp-decl-list-len (& decls))]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (let
          [entry : LspDeclEntry
            (lsp-decl-list-get (& decls) i (lsp-decl-entry-fallback))]
          (if (string.string-eq (struct-get entry name) needle)
            (set! found true)
            (set! i (+ i 1)))))
      found)))

;; tl/projectSearch - Search for a declaration name across .tl files in a directory
(define (lsp-handle-tl-project-search
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-json-string-field params "name")
    [(LspJsonText.Ok name)
      (if (string.string-eq name "")
        (begin
          (lsp-write-error id -32600 "name cannot be empty")
          (LspHandleResult.Continue docs))
        (let
          [td-key : String "textDocument"]
          (match (json.json-object-get params (& td-key))
            [(json.JsonFound document)
              (match (lsp-json-string-field document "uri")
                [(LspJsonText.Ok uri)
                  (match (lsp-file-uri-to-path uri)
                    [(LspUriPath.Ok path)
                      (match (fs.try-read-dir-vec (& path))
                        [(fs.OkIoStringVec entries)
                          (let
                            [n : i64 (vector.string-vec-len entries)]
                            [i : i64 0]
                            [results : json.JsonList json.JsonListNil]
                            (begin
                              (while (< i n)
                                (let
                                  [entry : String
                                    (vector.string-vec-get entries i "")]
                                  (begin
                                    (if (lsp-tl-source-file-name? entry)
                                      (let
                                        [entry-path : String
                                          (fs.fs-path-join (& path) (& entry))]
                                        (match (io.try-read-file (& entry-path))
                                          [(io.OkIoString source)
                                            (if (lsp-decls-contain-name?
                                              (lsp-scan-decls source)
                                              name)
                                              (let
                                                [entry-uri : String
                                                  (lsp-path-to-file-uri
                                                    (fs.fs-path-normalize
                                                      (& entry-path)))]
                                                (set!
                                                  results
                                                  (lsp-json-list-cons
                                                    (lsp-json-object2
                                                      "uri"
                                                      (json.JsonString
                                                        entry-uri)
                                                      "name"
                                                      (json.JsonString name))
                                                    results)))
                                              unit)]
                                          [(io.ErrIoString _) unit]))
                                      unit)
                                    (set! i (+ i 1)))))
                              (lsp-write-response
                                id
                                (lsp-json-object2
                                  "success"
                                  (json.JsonBool true)
                                  "results"
                                  (lsp-json-array results)))
                              (LspHandleResult.Continue docs)))]
                        [(fs.ErrIoStringVec message)
                          (begin
                            (lsp-write-error
                              id
                              -32600
                              (lsp-str2
                                "Failed to read directory: "
                                (io.io-error-message message)))
                            (LspHandleResult.Continue docs))])]
                    [(LspUriPath.Err message)
                      (begin
                        (lsp-write-error id -32600 message)
                        (LspHandleResult.Continue docs))])]
                [(LspJsonText.Missing)
                  (begin
                    (lsp-write-error
                      id
                      -32600
                      "Missing uri in textDocument parameter")
                    (LspHandleResult.Continue docs))])]
            [(json.JsonMissing)
              (begin
                (lsp-write-error id -32600 "Missing textDocument parameter")
                (LspHandleResult.Continue docs))])))]
    [(LspJsonText.Missing)
      (begin
        (lsp-write-error id -32600 "Missing name parameter")
        (LspHandleResult.Continue docs))]))

;; tl/evalAtPoint - Evaluate expression at cursor
(define (lsp-handle-tl-eval-at-point
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(LspDocumentLookup.Found path text _)
      (let
        [result : LspEditResult (LspEditResult.Err "Not yet implemented")]
        (match result
          [(LspEditResult.Ok new-text)
            (begin
              (lsp-write-response
                id
                (lsp-json-object2
                  "success"
                  (json.JsonBool true)
                  "text"
                  (json.JsonString new-text)))
              (LspHandleResult.Continue docs))]
          [(LspEditResult.Err message)
            (begin
              (lsp-write-error id -32600 message)
              (LspHandleResult.Continue docs))]))]
    [(LspDocumentLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

;; tl/signatureHelp - Parameter types for function at cursor
(define (lsp-handle-tl-signature-help
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(LspDocumentLookup.Found path text _)
      (let
        [result : LspEditResult (LspEditResult.Err "Not yet implemented")]
        (match result
          [(LspEditResult.Ok new-text)
            (begin
              (lsp-write-response
                id
                (lsp-json-object2
                  "success"
                  (json.JsonBool true)
                  "text"
                  (json.JsonString new-text)))
              (LspHandleResult.Continue docs))]
          [(LspEditResult.Err message)
            (begin
              (lsp-write-error id -32600 message)
              (LspHandleResult.Continue docs))]))]
    [(LspDocumentLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

;; tl/appendFunction - Append a form at the end of the file
(define (lsp-handle-tl-append-function
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document-decls params docs)
    [(LspDocumentDeclsLookup.Found path text _ decls)
      (match (lsp-json-string-field params "newText")
        [(LspJsonText.Ok new-text)
          (if (not (lsp-text-is-valid-forms new-text))
            (begin
              (lsp-write-error
                id
                -32600
                (lsp-str2
                  "newText is not valid form(s): "
                  (lsp-validate-forms-error new-text)))
              (LspHandleResult.Continue docs))
            (let
              [n : i64 (lsp-decl-list-len (& decls))]
              [result : String ""]
              (begin
                (if (= n 0)
                  (set! result (lsp-str3 text "\n\n" new-text))
                  (let
                    [last-entry : LspDeclEntry
                      (lsp-decl-list-get
                        (& decls)
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
                        (lsp-str2 "\n\n" new-text)))))
                (let
                  [formatted : String (lsp-format-edit-text result)]
                  (begin
                    (lsp-write-response
                      id
                      (lsp-json-object2
                        "success"
                        (json.JsonBool true)
                        "text"
                        (json.JsonString formatted)))
                    (LspHandleResult.Continue docs))))))]
        [(LspJsonText.Missing)
          (begin
            (lsp-write-error id -32600 "Missing newText parameter")
            (LspHandleResult.Continue docs))])]
    [(LspDocumentDeclsLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

;; tl/replaceBody - legacy method name routed to position-based body replacement
(define (lsp-handle-message
  [message : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : LspHandleResult
  (match (lsp-json-string-field message "method")
    [(LspJsonText.Ok method)
      (let
        [handled : bool false]
        [result : LspHandleResult (LspHandleResult.Continue docs)]
        (begin
          (if (and (not handled) (string.string-eq method "initialize"))
            (begin
              (set! handled true)
              (let
                [key : String "id"]
                (match (json.json-object-get message (& key))
                  [(json.JsonFound id)
                    (lsp-write-response id (lsp-initialize-result))]
                  [(json.JsonMissing) unit]))
              (set! result (LspHandleResult.Continue docs)))
            unit)
          (if (and (not handled) (string.string-eq method "initialized"))
            (begin
              (set! handled true)
              (set! result (LspHandleResult.Continue docs)))
            unit)
          (if (and (not handled) (string.string-eq method "shutdown"))
            (begin
              (set! handled true)
              (let
                [key : String "id"]
                (match (json.json-object-get message (& key))
                  [(json.JsonFound id) (lsp-write-response id json.JsonNull)]
                  [(json.JsonMissing) unit]))
              (set! result (LspHandleResult.Continue docs)))
            unit)
          (if (and (not handled) (string.string-eq method "exit"))
            (begin
              (set! handled true)
              (set! result (LspHandleResult.Exit docs)))
            unit)
          (if (and
            (not handled)
            (string.string-eq method "textDocument/didOpen"))
            (begin
              (set! handled true)
              (let
                [key : String "params"]
                (match (json.json-object-get message (& key))
                  [(json.JsonFound params)
                    (set! result (lsp-did-open params docs stdlib-roots))]
                  [(json.JsonMissing)
                    (set! result (LspHandleResult.Continue docs))])))
            unit)
          (if (and
            (not handled)
            (string.string-eq method "textDocument/didChange"))
            (begin
              (set! handled true)
              (let
                [key : String "params"]
                (match (json.json-object-get message (& key))
                  [(json.JsonFound params)
                    (set! result (lsp-did-change params docs stdlib-roots))]
                  [(json.JsonMissing)
                    (set! result (LspHandleResult.Continue docs))])))
            unit)
          (if (and
            (not handled)
            (string.string-eq method "textDocument/didClose"))
            (begin
              (set! handled true)
              (let
                [key : String "params"]
                (match (json.json-object-get message (& key))
                  [(json.JsonFound params)
                    (set! result (lsp-did-close params docs))]
                  [(json.JsonMissing)
                    (set! result (LspHandleResult.Continue docs))])))
            unit)
          (if (and
            (not handled)
            (string.string-eq method "textDocument/definition"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.json-object-get message (& id-key))
                  [(json.JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.json-object-get message (& params-key))
                        [(json.JsonFound params)
                          (lsp-handle-definition id params docs stdlib-roots)]
                        [(json.JsonMissing)
                          (lsp-write-response id json.JsonNull)]))]
                  [(json.JsonMissing) unit]))
              (set! result (LspHandleResult.Continue docs)))
            unit)
          (if (and
            (not handled)
            (string.string-eq method "textDocument/completion"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.json-object-get message (& id-key))
                  [(json.JsonFound id) (lsp-completion-respond id docs)]
                  [(json.JsonMissing) unit]))
              (set! result (LspHandleResult.Continue docs)))
            unit)
          (if (and
            (not handled)
            (string.string-eq method "textDocument/inlayHint"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.json-object-get message (& id-key))
                  [(json.JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.json-object-get message (& params-key))
                        [(json.JsonFound params)
                          (lsp-handle-inlay id params docs stdlib-roots)]
                        [(json.JsonMissing)
                          (lsp-write-response
                            id
                            (lsp-json-array json.JsonListNil))]))]
                  [(json.JsonMissing) unit]))
              (set! result (LspHandleResult.Continue docs)))
            unit)
          (if (and
            (not handled)
            (string.string-eq method "textDocument/formatting"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.json-object-get message (& id-key))
                  [(json.JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.json-object-get message (& params-key))
                        [(json.JsonFound params)
                          (lsp-handle-formatting id params docs)]
                        [(json.JsonMissing)
                          (lsp-write-response
                            id
                            (lsp-json-array json.JsonListNil))]))]
                  [(json.JsonMissing) unit]))
              (set! result (LspHandleResult.Continue docs)))
            unit)
          (if (and (not handled) (string.string-eq method "textDocument/hover"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.json-object-get message (& id-key))
                  [(json.JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.json-object-get message (& params-key))
                        [(json.JsonFound params)
                          (lsp-handle-hover id params docs stdlib-roots)]
                        [(json.JsonMissing)
                          (lsp-write-response id json.JsonNull)]))]
                  [(json.JsonMissing) unit]))
              (set! result (LspHandleResult.Continue docs)))
            unit)
          (if (and
            (not handled)
            (string.string-eq method "textDocument/documentLink"))
            (begin
              (set! handled true)
              (let
                [id-key : String "id"]
                (match (json.json-object-get message (& id-key))
                  [(json.JsonFound id)
                    (let
                      [params-key : String "params"]
                      (match (json.json-object-get message (& params-key))
                        [(json.JsonFound params)
                          (lsp-handle-document-link id params docs stdlib-roots)]
                        [(json.JsonMissing)
                          (lsp-write-response
                            id
                            (lsp-json-array json.JsonListNil))]))]
                  [(json.JsonMissing) unit]))
              (set! result (LspHandleResult.Continue docs)))
            unit)
          (if (not handled)
            (begin
              (let
                [enclosing : i64 (arena.tl_arena_current)]
                [scratch : i64 (arena.tl_arena_make)]
                [old-cache-arena : i64 lsp-document-cache-arena]
                (begin
                  (set! lsp-document-cache-arena enclosing)
                  (unsafe
                    (arena.tl_arena_set scratch))
                  (lsp-handle-tool-message! method message docs stdlib-roots)
                  (let
                    [scratch-head : i64 (arena.tl_arena_current)]
                    (begin
                      (unsafe
                        (arena.tl_arena_set enclosing))
                      (set! lsp-document-cache-arena old-cache-arena)
                      (unsafe
                        (arena.tl_arena_destroy scratch-head))))))
              (set! result (LspHandleResult.Continue docs)))
            unit)
          result))]
    [(LspJsonText.Missing) (LspHandleResult.Continue docs)]))

(define (lsp-known-tool-method? [method : String]) : bool
  (or
    (string.string-eq method "tl/astDump")
    (string.string-eq method "tl/listFunctions")
    (string.string-eq method "tl/findPosition")
    (string.string-eq method "tl/replace")
    (string.string-eq method "tl/deleteFunction")
    (string.string-eq method "tl/move")
    (string.string-eq method "tl/expandMacro")
    (string.string-eq method "tl/check")
    (string.string-eq method "tl/getType")
    (string.string-eq method "tl/findReferences")
    (string.string-eq method "tl/evalAtPoint")
    (string.string-eq method "tl/appendFunction")
    (string.string-eq method "tl/replaceBody")
    (string.string-eq method "tl/signatureHelp")
    (string.string-eq method "tl/replacePattern")
    (string.string-eq method "tl/patch")
    (string.string-eq method "tl/projectSearch")
    (string.string-eq method "tl/rename")
    (string.string-eq method "tl/delete")
    (string.string-eq method "tl/insertAfter")
    (string.string-eq method "tl/read")))

(define (lsp-handle-tool-missing-params!
  [method : String]
  [message : json.Json]
  [id : json.Json]) : unit
  (cond
    [(or
        (string.string-eq method "tl/astDump")
        (string.string-eq method "tl/listFunctions"))
      (begin
        (lsp-write-response id (lsp-json-array json.JsonListNil))
        unit)]
    [(lsp-known-tool-method? method)
      (begin
        (lsp-write-error id -32600 "Missing params")
        unit)]
    [else
      (begin
        (lsp-maybe-write-method-not-found message)
        unit)]))

(define (lsp-handle-tool-with-params!
  [method : String]
  [message : json.Json]
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : unit
  (cond
    [(string.string-eq method "tl/astDump")
      (begin
        (lsp-handle-tl-ast-dump id params docs)
        unit)]
    [(string.string-eq method "tl/listFunctions")
      (begin
        (lsp-handle-tl-list-functions id params docs)
        unit)]
    [(string.string-eq method "tl/findPosition")
      (begin
        (lsp-handle-tl-find-position id params docs)
        unit)]
    [(string.string-eq method "tl/replace")
      (begin
        (lsp-handle-tl-structural-replace-at id params docs)
        unit)]
    [(string.string-eq method "tl/deleteFunction")
      (begin
        (lsp-handle-tl-delete-at id params docs)
        unit)]
    [(string.string-eq method "tl/move")
      (begin
        (lsp-handle-tl-structural-move id params docs)
        unit)]
    [(string.string-eq method "tl/expandMacro")
      (begin
        (lsp-handle-tl-expand-macro id params docs)
        unit)]
    [(string.string-eq method "tl/check")
      (let
        [old-program-cache : bool
          (compiler-load-session-program-cache-enabled?)]
        (begin
          (compiler-load-session-program-cache-disable!)
          (compiler-check-reset-pools!)
          (compiler-load-session-reset-interns!)
          (lsp-handle-tl-check id params docs stdlib-roots)
          (compiler-check-reset-pools!)
          (compiler-load-session-reset-interns!)
          (compiler-load-session-program-cache-set-enabled! old-program-cache)
          unit))]
    [(string.string-eq method "tl/getType")
      (let
        [old-program-cache : bool
          (compiler-load-session-program-cache-enabled?)]
        (begin
          (compiler-load-session-program-cache-disable!)
          (compiler-check-reset-pools!)
          (compiler-load-session-reset-interns!)
          (lsp-handle-tl-get-type-at id params docs stdlib-roots)
          (compiler-check-reset-pools!)
          (compiler-load-session-reset-interns!)
          (compiler-load-session-program-cache-set-enabled! old-program-cache)
          unit))]
    [(string.string-eq method "tl/findReferences")
      (begin
        (lsp-handle-tl-find-references id params docs)
        unit)]
    [(string.string-eq method "tl/evalAtPoint")
      (begin
        (lsp-handle-tl-eval-at-point id params docs)
        unit)]
    [(string.string-eq method "tl/appendFunction")
      (begin
        (lsp-handle-tl-append-function id params docs)
        unit)]
    [(string.string-eq method "tl/replaceBody")
      (begin
        (lsp-handle-tl-replace-body id params docs)
        unit)]
    [(string.string-eq method "tl/signatureHelp")
      (begin
        (lsp-handle-tl-signature-help id params docs)
        unit)]
    [(string.string-eq method "tl/replacePattern")
      (begin
        (lsp-handle-tl-replace-pattern-at id params docs)
        unit)]
    [(string.string-eq method "tl/patch")
      (begin
        (lsp-handle-tl-patch id params docs)
        unit)]
    [(string.string-eq method "tl/projectSearch")
      (begin
        (lsp-handle-tl-project-search id params docs)
        unit)]
    [(string.string-eq method "tl/rename")
      (begin
        (lsp-handle-tl-rename id params docs)
        unit)]
    [(string.string-eq method "tl/delete")
      (begin
        (lsp-handle-tl-delete-at id params docs)
        unit)]
    [(string.string-eq method "tl/insertAfter")
      (begin
        (lsp-handle-tl-insert-after id params docs)
        unit)]
    [(string.string-eq method "tl/read")
      (begin
        (lsp-handle-tl-read-form-at id params docs)
        unit)]
    [else
      (begin
        (lsp-maybe-write-method-not-found message)
        unit)]))

(define (lsp-handle-tool-message!
  [method : String]
  [message : json.Json]
  [docs : LspDocuments]
  [stdlib-roots : vector.StringVec]) : unit
  (let
    [id-key : String "id"]
    (match (json.json-object-get message (& id-key))
      [(json.JsonFound id)
        (let
          [params-key : String "params"]
          (match (json.json-object-get message (& params-key))
            [(json.JsonFound params)
              (lsp-handle-tool-with-params!
                method
                message
                id
                params
                docs
                stdlib-roots)]
            [(json.JsonMissing)
              (lsp-handle-tool-missing-params! method message id)]))]
      [(json.JsonMissing)
        (if (not (lsp-known-tool-method? method))
          (lsp-maybe-write-method-not-found message)
          unit)])))

(define (lsp-stdlib-roots-from [idx : i64] [count : i64]) : vector.StringVec
  (let
    [i : i64 idx]
    [roots : vector.StringVec (vector.string-vec-new)]
    (begin
      (while (< i count)
        (if (string.string-eq (io.arg i) "--stdlib-root")
          (if (< (+ i 1) count)
            (begin
              (set! roots (vector.string-vec-push roots (io.arg (+ i 1))))
              (set! i (+ i 2)))
            (set! i count))
          (set! i (+ i 1))))
      roots)))

(define (lsp-stdlib-roots [idx : i64]) : vector.StringVec
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
    [stdlib-roots : vector.StringVec (lsp-stdlib-roots-from idx count)]
    (begin
      (lsp-frame-session-cache-enable!)
      (while (not done)
        (match (lsp-frame-read-message)
          [(LspFrameRead.Ok payload)
            (let
              [text : String payload]
              (match (json.json-parse (& text))
                [(json.OkJson message)
                  (match (lsp-handle-message message docs stdlib-roots)
                    [(LspHandleResult.Continue next-docs) (set! docs next-docs)]
                    [(LspHandleResult.Exit next-docs)
                      (begin
                        (set! docs next-docs)
                        (set! done true))])]
                [(json.ErrJson message) (lsp-write-parse-error message)]))]
          [(LspFrameRead.Eof) (set! done true)]
          [(LspFrameRead.Err message)
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
    [n : i64 (string.string-length text)]
    [old-len : i64 (string.string-length old)]
    [result : String ""]
    [i : i64 0]
    (begin
      (while (<= i (- n old-len))
        (if (and
          (string.string-eq (string.substring text i old-len) old)
          (or (= i 0) (not (lsp-ident-char? (string.string-ref text (- i 1)))))
          (or
            (>= (+ i old-len) n)
            (not (lsp-ident-char? (string.string-ref text (+ i old-len))))))
          (begin
            (set! result (string.string-concat3 result new ""))
            (set! i (+ i old-len)))
          (begin
            (set!
              result
              (string.string-concat3 result (string.substring text i 1) ""))
            (set! i (+ i 1)))))
      (while (< i n)
        (begin
          (set!
            result
            (string.string-concat3 result (string.substring text i 1) ""))
          (set! i (+ i 1))))
      result)))

(define (lsp-handle-tl-rename
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(LspDocumentLookup.Found path text _)
      (let
        [old-name : String
          (let
            [pos-key : String "position"]
            (match (json.json-object-get params (& pos-key))
              [(json.JsonFound position)
                (let
                  [line : i64 (lsp-json-int-field-default position "line" 0)]
                  [col : i64
                    (lsp-json-int-field-default position "character" 0)]
                  (lsp-find-and-extract-name text line col))]
              [(json.JsonMissing)
                (match (lsp-json-string-field params "oldName")
                  [(LspJsonText.Ok n) n]
                  [(LspJsonText.Missing) ""])]))]
        (if (= (string.string-length old-name) 0)
          (begin
            (lsp-write-error id -32600 "Missing oldName or position parameter")
            (LspHandleResult.Continue docs))
          (match (lsp-json-string-field params "newName")
            [(LspJsonText.Ok new-name)
              (if (string.string-eq old-name "")
                (begin
                  (lsp-write-error id -32600 "oldName cannot be empty")
                  (LspHandleResult.Continue docs))
                (if (string.string-eq new-name "")
                  (begin
                    (lsp-write-error id -32600 "newName cannot be empty")
                    (LspHandleResult.Continue docs))
                  (let
                    [result : String
                      (lsp-replace-all-words text old-name new-name)]
                    [formatted : String (lsp-format-edit-text result)]
                    (begin
                      (lsp-write-response
                        id
                        (lsp-json-object2
                          "success"
                          (json.JsonBool true)
                          "text"
                          (json.JsonString formatted)))
                      (LspHandleResult.Continue docs)))))]
            [(LspJsonText.Missing)
              (begin
                (lsp-write-error id -32600 "Missing newName parameter")
                (LspHandleResult.Continue docs))])))]
    [(LspDocumentLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

(define (lsp-handle-tl-replace-pattern
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document-decls params docs)
    [(LspDocumentDeclsLookup.Found path text _ decls)
      (match (lsp-json-string-field params "name")
        [(LspJsonText.Ok name)
          (match (lsp-json-string-field params "oldPattern")
            [(LspJsonText.Ok old-pattern)
              (begin
                (when
                  (string.string-eq old-pattern "")
                  (begin
                    (lsp-write-error id -32600 "oldPattern cannot be empty")
                    (return (LspHandleResult.Continue docs))))
                (match (lsp-json-string-field params "newPattern")
                  [(LspJsonText.Ok new-pattern)
                    (let
                      [i : i64 0]
                      [n : i64 (lsp-decl-list-len (& decls))]
                      [found : bool false]
                      [result : String ""]
                      (begin
                        (while (and (< i n) (not found))
                          (let
                            [entry : LspDeclEntry
                              (lsp-decl-list-get
                                (& decls)
                                i
                                (lsp-decl-entry-fallback))]
                            (if (string.string-eq (struct-get entry name) name)
                              (begin
                                (set! found true)
                                (let
                                  [kind : String (struct-get entry kind)]
                                  [n2 : i64 (string.string-length text)]
                                  (if (or
                                    (string.string-eq kind "function")
                                    (string.string-eq kind "macro"))
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
                                        (=
                                          (string.string-ref text after-kw2)
                                          '('))
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
                                            (string.substring
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
                                                (lsp-str2
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
                          (if (string.string-eq result "")
                            (LspHandleResult.Continue docs)
                            (let
                              [formatted : String (lsp-format-edit-text result)]
                              (begin
                                (lsp-write-response
                                  id
                                  (lsp-json-object2
                                    "success"
                                    (json.JsonBool true)
                                    "text"
                                    (json.JsonString formatted)))
                                (LspHandleResult.Continue docs))))
                          (begin
                            (lsp-write-error id -32600 "Declaration not found")
                            (LspHandleResult.Continue docs)))))]
                  [(LspJsonText.Missing)
                    (begin
                      (lsp-write-error id -32600 "Missing newPattern parameter")
                      (LspHandleResult.Continue docs))]))]
            [(LspJsonText.Missing)
              (begin
                (lsp-write-error id -32600 "Missing oldPattern parameter")
                (LspHandleResult.Continue docs))])]
        [(LspJsonText.Missing)
          (begin
            (lsp-write-error id -32600 "Missing name parameter")
            (LspHandleResult.Continue docs))])]
    [(LspDocumentDeclsLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

(define (lsp-replace-body-text-with-decls
  [text : String]
  [name : String]
  [new-body : String]
  [decls : LspDeclList]) : LspEditResult
  (let
    [i : i64 0]
    [n : i64 (lsp-decl-list-len (& decls))]
    [found : bool false]
    [result : String ""]
    [err : String ""]
    (begin
      (while (and (< i n) (not found))
        (let
          [entry : LspDeclEntry
            (lsp-decl-list-get (& decls) i (lsp-decl-entry-fallback))]
          (if (string.string-eq (struct-get entry name) name)
            (begin
              (set! found true)
              (let
                [kind : String (struct-get entry kind)]
                [n2 : i64 (string.string-length text)]
                (if (or
                  (string.string-eq kind "function")
                  (string.string-eq kind "macro"))
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
                      (= (string.string-ref text after-kw2) '('))
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
                              (lsp-str2
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
      (unless found (return (LspEditResult.Err "Declaration not found")))
      (unless (string.string-eq err "") (return (LspEditResult.Err err)))
      (when
        (string.string-eq result "")
        (return (LspEditResult.Err "replaceBody: unknown error")))
      (LspEditResult.Ok result))))

(define (lsp-replace-body-text
  [text : String]
  [name : String]
  [new-body : String]) : LspEditResult
  (let
    [text-copy : String (string.string-copy (& text))]
    [decls : LspDeclList (lsp-scan-decls text-copy)]
    (lsp-replace-body-text-with-decls text name new-body decls)))

(define (lsp-replace-pattern-text-with-decls
  [text : String]
  [name : String]
  [old-pattern : String]
  [new-pattern : String]
  [decls : LspDeclList]) : LspEditResult
  (if (string.string-eq old-pattern "")
    (LspEditResult.Err "oldPattern cannot be empty")
    (let
      [i : i64 0]
      [n : i64 (lsp-decl-list-len (& decls))]
      [found : bool false]
      [result : String ""]
      [err : String ""]
      (begin
        (while (and (< i n) (not found))
          (let
            [entry : LspDeclEntry
              (lsp-decl-list-get (& decls) i (lsp-decl-entry-fallback))]
            (if (string.string-eq (struct-get entry name) name)
              (begin
                (set! found true)
                (let
                  [kind : String (struct-get entry kind)]
                  [n2 : i64 (string.string-length text)]
                  (if (or
                    (string.string-eq kind "function")
                    (string.string-eq kind "macro"))
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
                        (= (string.string-ref text after-kw2) '('))
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
                            (string.substring
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
                                (lsp-str2
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
        (unless found (return (LspEditResult.Err "Declaration not found")))
        (unless (string.string-eq err "") (return (LspEditResult.Err err)))
        (when
          (string.string-eq result "")
          (return (LspEditResult.Err "replacePattern: unknown error")))
        (LspEditResult.Ok result)))))

(define (lsp-replace-pattern-text
  [text : String]
  [name : String]
  [old-pattern : String]
  [new-pattern : String]) : LspEditResult
  (let
    [text-copy : String (string.string-copy (& text))]
    [decls : LspDeclList (lsp-scan-decls text-copy)]
    (lsp-replace-pattern-text-with-decls
      text
      name
      old-pattern
      new-pattern
      decls)))

(define (lsp-structural-replace-text-with-decls
  [text : String]
  [name : String]
  [new-text : String]
  [decls : LspDeclList]) : LspEditResult
  (if (not (lsp-text-is-valid-forms new-text))
    (LspEditResult.Err
      (lsp-str2
        "newText is not valid form(s): "
        (lsp-validate-forms-error new-text)))
    (let
      [i : i64 0]
      [n : i64 (lsp-decl-list-len (& decls))]
      [found : bool false]
      [result : String ""]
      (begin
        (while (and (< i n) (not found))
          (let
            [entry : LspDeclEntry
              (lsp-decl-list-get (& decls) i (lsp-decl-entry-fallback))]
            (if (string.string-eq (struct-get entry name) name)
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
          (LspEditResult.Ok result)
          (LspEditResult.Err "Declaration not found"))))))

(define (lsp-structural-replace-text
  [text : String]
  [name : String]
  [new-text : String]) : LspEditResult
  (let
    [text-copy : String (string.string-copy (& text))]
    [decls : LspDeclList (lsp-scan-decls text-copy)]
    (lsp-structural-replace-text-with-decls text name new-text decls)))

;; tl/patch - Find and replace text anywhere in the file, then validate
(define (lsp-patch-text [text : String] [old-text : String] [new-text : String]) : LspEditResult
  (let
    [n : i64 (string.string-length text)]
    [old-len : i64 (string.string-length old-text)]
    (if (string.string-eq old-text "")
      (LspEditResult.Err "oldText cannot be empty")
      (let
        [first-byte : char (string.string-ref old-text 0)]
        [i : i64 0]
        [found-at : i64 -1]
        [matches : i64 0]
        [limit : i64 (- n old-len)]
        (begin
          (while (and (<= i limit) (<= matches 1))
            (let
              [idx : i64
                (string.string-index-of-byte (& text) i (cast first-byte : u8))]
              (if (= idx -1)
                (set! i (+ limit 1))
                (if (<= idx limit)
                  (if (string.is-string-prefix-at (& text) (& old-text) idx)
                    (begin
                      (when (= found-at -1) (set! found-at idx))
                      (set! matches (+ matches 1))
                      (set! i (+ idx 1)))
                    (set! i (+ idx 1)))
                  (set! i (+ limit 1))))))
          (if (= matches 0)
            (LspEditResult.Err "oldText not found in document")
            (if (> matches 1)
              (LspEditResult.Err "oldText occurs more than once in document")
              (let
                [replaced : String
                  (string.string-replace text old-text new-text)]
                (if (not (lsp-text-is-valid-forms replaced))
                  (LspEditResult.Err
                    (lsp-str2
                      "Patch produces invalid form(s): "
                      (lsp-validate-forms-error replaced)))
                  (LspEditResult.Ok replaced))))))))))

;; tl/patch - Handler for find-and-replace patch
(define (lsp-handle-tl-patch
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(LspDocumentLookup.Found path text _)
      (match (lsp-json-string-field params "oldText")
        [(LspJsonText.Ok old-text)
          (match (lsp-json-string-field params "newText")
            [(LspJsonText.Ok new-text)
              (match (lsp-patch-text text old-text new-text)
                [(LspEditResult.Ok replaced)
                  (let
                    [formatted : String (lsp-format-edit-text replaced)]
                    (begin
                      (lsp-write-response
                        id
                        (lsp-json-object2
                          "success"
                          (json.JsonBool true)
                          "text"
                          (json.JsonString formatted)))
                      (LspHandleResult.Continue docs)))]
                [(LspEditResult.Err message)
                  (begin
                    (lsp-write-error id -32600 message)
                    (LspHandleResult.Continue docs))])]
            [(LspJsonText.Missing)
              (begin
                (lsp-write-error id -32600 "Missing newText parameter")
                (LspHandleResult.Continue docs))])]
        [(LspJsonText.Missing)
          (begin
            (lsp-write-error id -32600 "Missing oldText parameter")
            (LspHandleResult.Continue docs))])]
    [(LspDocumentLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

(define (lsp-patch-text-smoke-ok?) : bool
  (let
    [text : String "(define (foo) : i64 1)"]
    (match (lsp-patch-text text "1" "2")
      [(LspEditResult.Ok replaced)
        (string.string-eq replaced "(define (foo) : i64 2)")]
      [(LspEditResult.Err _) false])))

(define (lsp-patch-text-duplicate-ok?) : bool
  (let
    [text : String "(define (foo) : i64 1)\n(define (bar) : i64 1)"]
    [needle : String "more than once"]
    (match (lsp-patch-text text "1" "2")
      [(LspEditResult.Ok _) false]
      [(LspEditResult.Err message)
        (string.string-contains (& message) (& needle))])))

(define (lsp-patch-text-invalid-ok?) : bool
  (let
    [text : String "(define (foo) : i64 1)"]
    [needle : String "invalid form"]
    (match (lsp-patch-text text "1)" "1")
      [(LspEditResult.Ok _) false]
      [(LspEditResult.Err message)
        (string.string-contains (& message) (& needle))])))

(define (lsp-patch-text-first-byte-collisions-ok?) : bool
  (let
    [text : String "(define (aaaaa) : i64 1)\n(define (abc) : i64 2)"]
    [expected : String "(define (aaaaa) : i64 1)\n(define (renamed) : i64 2)"]
    (match (lsp-patch-text text "abc" "renamed")
      [(LspEditResult.Ok replaced) (string.string-eq replaced expected)]
      [(LspEditResult.Err _) false])))

(test
  lsp-patch-text-smoke
  (unless (lsp-patch-text-smoke-ok?) (io.panic "lsp-patch-text-smoke failed")))

(test
  lsp-patch-text-duplicate
  (unless
    (lsp-patch-text-duplicate-ok?)
    (io.panic "lsp-patch-text-duplicate failed")))

(test
  lsp-patch-text-invalid
  (unless
    (lsp-patch-text-invalid-ok?)
    (io.panic "lsp-patch-text-invalid failed")))

(test
  lsp-patch-text-first-byte-collisions
  (unless
    (lsp-patch-text-first-byte-collisions-ok?)
    (io.panic "lsp-patch-text-first-byte-collisions failed")))

(test
  lsp-validate-forms-smoke
  (unless
    (lsp-validate-forms-smoke-ok?)
    (io.panic "lsp-validate-forms-smoke failed")))

(test
  lsp-validate-forms-line-context
  (unless
    (lsp-validate-forms-line-context-ok?)
    (io.panic "lsp-validate-forms-line-context failed")))

(test
  lsp-documents-cache-bound
  (unless
    (lsp-documents-cache-bound-smoke-ok?)
    (io.panic "lsp-documents-cache-bound failed")))

;; Position-based editing helpers
;; Find start index of innermost form containing offset. Returns -1 if not found.
;; Uses string.string-ref on literal parens since char literals for parens confuse the parser.
(define (lsp-find-form-at-offset [text : String] [offset : i64]) : i64
  (if (or (< offset 0) (>= offset (string.string-length text)))
    -1
    (let
      [i : i64 offset]
      [depth : i64 0]
      [result : i64 -1]
      (begin
        (while (and (>= i 0) (= result -1))
          (let
            [c : char (string.string-ref text i)]
            (begin
              (if (= c (string.string-ref ")" 0))
                (set! depth (+ depth 1))
                (if (= c (string.string-ref "(" 0))
                  (if (= depth 0)
                    (set! result i)
                    (set! depth (- depth 1)))
                  unit))
              (set! i (- i 1)))))
        result))))

;; Find end index (exclusive) of form starting at start. Returns -1 if unterminated.
(define (lsp-find-form-end-at-offset [text : String] [start : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    (if (or
      (< start 0)
      (>= start n)
      (not (= (string.string-ref text start) (string.string-ref "(" 0))))
      -1
      (let
        [i : i64 (+ start 1)]
        [depth : i64 1]
        [result : i64 -1]
        (begin
          (while (and (< i n) (= result -1))
            (let
              [c : char (string.string-ref text i)]
              (begin
                (if (= c (string.string-ref "(" 0))
                  (set! depth (+ depth 1))
                  (if (= c (string.string-ref ")" 0))
                    (begin
                      (set! depth (- depth 1))
                      (if (= depth 0)
                        (set! result (+ i 1))
                        unit))
                    unit))
                (set! i (+ i 1)))))
          result)))))

;; Find start of the top-level form containing offset.
;; Scans forward tracking depth; a '(' at depth 0 is a top-level form.
;; Returns -1 if offset is not inside any top-level form.
(define (lsp-find-top-level-form-at-offset [text : String] [offset : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    (if (or (< offset 0) (>= offset n))
      -1
      (let
        [i : i64 0]
        [depth : i64 0]
        [current-start : i64 -1]
        [result : i64 -1]
        (begin
          (while (and (< i n) (= result -1))
            (let
              [c : char (string.string-ref text i)]
              (begin
                (if (= c (string.string-ref "(" 0))
                  (begin
                    (if (= depth 0)
                      (set! current-start i)
                      unit)
                    (set! depth (+ depth 1)))
                  (if (= c (string.string-ref ")" 0))
                    (if (> depth 0)
                      (begin
                        (set! depth (- depth 1))
                        (if (= depth 0)
                          (if (and (>= offset current-start) (<= offset i))
                            (set! result current-start)
                            unit)
                          unit))
                      unit)
                    unit))
                (set! i (+ i 1)))))
          result)))))

;; Replace top-level form at position (line, col) with new-text.
;; Any position inside a top-level form selects that entire form.
(define (lsp-replace-form-at-position
  [text : String]
  [line : i64]
  [col : i64]
  [new-text : String]) : LspEditResult
  (if (or (< line 0) (< col 0))
    (LspEditResult.Ok text)
    (let
      [offset : i64 (lsp-offset-at-position text line col)]
      (if (>= offset (string.string-length text))
        (LspEditResult.Ok text)
        (let
          [form-start : i64 (lsp-find-top-level-form-at-offset text offset)]
          (if (= form-start -1)
            (LspEditResult.Ok text)
            (let
              [form-end : i64 (lsp-find-form-end-at-offset text form-start)]
              (if (or (= form-end -1) (<= form-end offset))
                (LspEditResult.Ok text)
                (LspEditResult.Ok
                  (lsp-edit-range-at-offset text form-start form-end new-text))))))))))

;; tl/replaceAt - Replace form at position (line, character)
(define (lsp-handle-tl-structural-replace-at
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(LspDocumentLookup.Found path text _)
      (let
        [pos-key : String "position"]
        (match (json.json-object-get params (& pos-key))
          [(json.JsonFound position)
            (match (lsp-json-string-field params "newText")
              [(LspJsonText.Ok new-text)
                (let
                  [line : i64 (lsp-json-int-field-default position "line" 0)]
                  [col : i64
                    (lsp-json-int-field-default position "character" 0)]
                  (match (lsp-replace-form-at-position text line col new-text)
                    [(LspEditResult.Ok replaced)
                      (let
                        [formatted : String (lsp-format-edit-text replaced)]
                        (begin
                          (lsp-write-response
                            id
                            (lsp-json-object2
                              "success"
                              (json.JsonBool true)
                              "text"
                              (json.JsonString formatted)))
                          (LspHandleResult.Continue docs)))]
                    [(LspEditResult.Err message)
                      (begin
                        (lsp-write-error id -32600 message)
                        (LspHandleResult.Continue docs))]))]
              [(LspJsonText.Missing)
                (begin
                  (lsp-write-error id -32600 "Missing newText parameter")
                  (LspHandleResult.Continue docs))])]
          [(json.JsonMissing)
            (begin
              (lsp-write-error id -32600 "Missing position parameter")
              (LspHandleResult.Continue docs))]))]
    [(LspDocumentLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

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
      (if (>= offset (string.string-length text))
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
                    (string.substring
                      text
                      actual-start
                      (- form-end actual-start))))))))))))

;; tl/delete - Delete the form at a given position
(define (lsp-handle-tl-delete-at
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(LspDocumentLookup.Found path text _)
      (let
        [pos-key : String "position"]
        (match (json.json-object-get params (& pos-key))
          [(json.JsonFound position)
            (let
              [line : i64 (lsp-json-int-field-default position "line" 0)]
              [col : i64 (lsp-json-int-field-default position "character" 0)]
              (if (or (< line 0) (< col 0))
                (begin
                  (lsp-write-error id -32600 "No form found at position")
                  (LspHandleResult.Continue docs))
                (let
                  [offset : i64 (lsp-offset-at-position text line col)]
                  (if (>= offset (string.string-length text))
                    (begin
                      (lsp-write-error id -32600 "No form found at position")
                      (LspHandleResult.Continue docs))
                    (let
                      [form-start : i64
                        (lsp-find-top-level-form-at-offset text offset)]
                      (if (= form-start -1)
                        (begin
                          (lsp-write-error
                            id
                            -32600
                            "No form found at position")
                          (LspHandleResult.Continue docs))
                        (let
                          [form-end : i64
                            (lsp-find-form-end-at-offset text form-start)]
                          (if (= form-end -1)
                            (begin
                              (lsp-write-error
                                id
                                -32600
                                "No form found at position")
                              (LspHandleResult.Continue docs))
                            (let
                              [before : String
                                (string.substring text 0 form-start)]
                              [after : String
                                (string.substring
                                  text
                                  form-end
                                  (- (string.string-length text) form-end))]
                              [deleted : String (lsp-str2 before after)]
                              [formatted : String
                                (lsp-format-edit-text deleted)]
                              (begin
                                (lsp-write-response
                                  id
                                  (lsp-json-object2
                                    "success"
                                    (json.JsonBool true)
                                    "text"
                                    (json.JsonString formatted)))
                                (LspHandleResult.Continue docs)))))))))))]
          [(json.JsonMissing)
            (begin
              (lsp-write-error id -32600 "Missing position parameter")
              (LspHandleResult.Continue docs))]))]
    [(LspDocumentLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

;; tl/insertAfter - Insert a new form after the form at a given position
(define (lsp-handle-tl-insert-after
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(LspDocumentLookup.Found path text _)
      (match (lsp-json-string-field params "newText")
        [(LspJsonText.Ok new-text)
          (let
            [pos-key : String "position"]
            (match (json.json-object-get params (& pos-key))
              [(json.JsonFound position)
                (let
                  [line : i64 (lsp-json-int-field-default position "line" 0)]
                  [col : i64
                    (lsp-json-int-field-default position "character" 0)]
                  (if (or (< line 0) (< col 0))
                    (begin
                      (lsp-write-error id -32600 "No form found at position")
                      (LspHandleResult.Continue docs))
                    (let
                      [offset : i64 (lsp-offset-at-position text line col)]
                      (if (>= offset (string.string-length text))
                        (begin
                          (lsp-write-error
                            id
                            -32600
                            "No form found at position")
                          (LspHandleResult.Continue docs))
                        (let
                          [form-start : i64
                            (lsp-find-top-level-form-at-offset text offset)]
                          (if (= form-start -1)
                            (begin
                              (lsp-write-error
                                id
                                -32600
                                "No form found at position")
                              (LspHandleResult.Continue docs))
                            (let
                              [form-end : i64
                                (lsp-find-form-end-at-offset text form-start)]
                              (if (= form-end -1)
                                (begin
                                  (lsp-write-error
                                    id
                                    -32600
                                    "No form found at position")
                                  (LspHandleResult.Continue docs))
                                (let
                                  [before : String
                                    (string.substring text 0 form-end)]
                                  [after : String
                                    (string.substring
                                      text
                                      form-end
                                      (- (string.string-length text) form-end))]
                                  [new-doc-text : String
                                    (lsp-str4 before "\n" new-text after)]
                                  [formatted : String
                                    (lsp-format-edit-text new-doc-text)]
                                  (begin
                                    (lsp-write-response
                                      id
                                      (lsp-json-object2
                                        "success"
                                        (json.JsonBool true)
                                        "text"
                                        (json.JsonString formatted)))
                                    (LspHandleResult.Continue docs)))))))))))]
              [(json.JsonMissing)
                (begin
                  (lsp-write-error id -32600 "Missing position parameter")
                  (LspHandleResult.Continue docs))]))]
        [(LspJsonText.Missing)
          (begin
            (lsp-write-error id -32600 "Missing newText parameter")
            (LspHandleResult.Continue docs))])]
    [(LspDocumentLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

(define (lsp-is-whitespace [c : char]) : bool
  (lsp-ws? c))

;; Helper: Extract function name from a define or defmacro form.
(define (lsp-extract-define-name [text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    (begin
      (when (= n 0) (return ""))
      (let
        [open : i64 (lsp-skip-space text 0 n)]
        (begin
          (when
            (or
              (>= open n)
              (not (= (string.string-ref text open) (string.string-ref "(" 0))))
            (return ""))
          (let
            [kw-start : i64 (lsp-skip-space text (+ open 1) n)]
            [kw-end : i64 0]
            [kw : String ""]
            (begin
              (set! kw-end (lsp-scan-ident text kw-start n))
              (when (= kw-end kw-start) (return ""))
              (set! kw (string.substring text kw-start (- kw-end kw-start)))
              (when
                (not
                  (or
                    (string.string-eq kw "define")
                    (string.string-eq kw "defmacro")))
                (return ""))
              (let
                [name-start : i64 (lsp-skip-space text kw-end n)]
                (begin
                  (when (>= name-start n) (return ""))
                  (if (=
                    (string.string-ref text name-start)
                    (string.string-ref "(" 0))
                    (set! name-start (lsp-skip-space text (+ name-start 1) n))
                    unit)
                  (let
                    [name-end : i64 (lsp-scan-ident text name-start n)]
                    (if (= name-end name-start)
                      ""
                      (string.substring text name-start (- name-end name-start)))))))))))))

;; Helper: Search outward from a position to find a define/defmacro form and extract its name.
(define (lsp-find-define-name-outward [text : String] [search-offset : i64]) : String
  (if (< search-offset 0)
    ""
    (let
      [form-start : i64 (lsp-find-form-at-offset text search-offset)]
      (if (= form-start -1)
        ""
        (let
          [form-end : i64 (lsp-find-form-end-at-offset text form-start)]
          (if (= form-end -1)
            ""
            (let
              [form-text : String
                (string.substring text form-start (- form-end form-start))]
              [name : String (lsp-extract-define-name form-text)]
              (if (= (string.string-length name) 0)
                (lsp-find-define-name-outward text (- form-start 1))
                name))))))))

;; Helper: Find form at position and extract its name.
(define (lsp-find-and-extract-name [text : String] [line : i64] [col : i64]) : String
  (if (or (< line 0) (< col 0))
    ""
    (let
      [offset : i64 (lsp-offset-at-position text line col)]
      (if (>= offset (string.string-length text))
        ""
        (lsp-find-define-name-outward text offset)))))

;; tl/replaceBody - Replace body of a function by name or position
(define (lsp-handle-tl-replace-body
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document-decls params docs)
    [(LspDocumentDeclsLookup.Found path text _ decls)
      (let
        [pos-key : String "position"]
        (match (json.json-object-get params (& pos-key))
          [(json.JsonFound position)
            (let
              [line : i64 (lsp-json-int-field-default position "line" 0)]
              [col : i64 (lsp-json-int-field-default position "character" 0)]
              [name : String (lsp-find-and-extract-name text line col)]
              (if (= (string.string-length name) 0)
                (begin
                  (lsp-write-error
                    id
                    -32600
                    "Could not extract function name at position")
                  (LspHandleResult.Continue docs))
                (match (lsp-json-string-field params "newBody")
                  [(LspJsonText.Ok new-body)
                    (match (lsp-replace-body-text-with-decls
                      text
                      name
                      new-body
                      decls)
                      [(LspEditResult.Ok replaced)
                        (let
                          [formatted : String (lsp-format-edit-text replaced)]
                          (begin
                            (lsp-write-response
                              id
                              (lsp-json-object2
                                "success"
                                (json.JsonBool true)
                                "text"
                                (json.JsonString formatted)))
                            (LspHandleResult.Continue docs)))]
                      [(LspEditResult.Err message)
                        (begin
                          (lsp-write-error id -32600 message)
                          (LspHandleResult.Continue docs))])]
                  [(LspJsonText.Missing)
                    (begin
                      (lsp-write-error id -32600 "Missing newBody parameter")
                      (LspHandleResult.Continue docs))])))]
          [(json.JsonMissing)
            (match (lsp-json-string-field params "name")
              [(LspJsonText.Ok name)
                (if (= (string.string-length name) 0)
                  (begin
                    (lsp-write-error
                      id
                      -32600
                      "Missing name or position parameter")
                    (LspHandleResult.Continue docs))
                  (match (lsp-json-string-field params "newBody")
                    [(LspJsonText.Ok new-body)
                      (match (lsp-replace-body-text-with-decls
                        text
                        name
                        new-body
                        decls)
                        [(LspEditResult.Ok replaced)
                          (let
                            [formatted : String (lsp-format-edit-text replaced)]
                            (begin
                              (lsp-write-response
                                id
                                (lsp-json-object2
                                  "success"
                                  (json.JsonBool true)
                                  "text"
                                  (json.JsonString formatted)))
                              (LspHandleResult.Continue docs)))]
                        [(LspEditResult.Err message)
                          (begin
                            (lsp-write-error id -32600 message)
                            (LspHandleResult.Continue docs))])]
                    [(LspJsonText.Missing)
                      (begin
                        (lsp-write-error id -32600 "Missing newBody parameter")
                        (LspHandleResult.Continue docs))]))]
              [(LspJsonText.Missing)
                (begin
                  (lsp-write-error
                    id
                    -32600
                    "Missing name or position parameter")
                  (LspHandleResult.Continue docs))])]))]
    [(LspDocumentDeclsLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

;; tl/replacePattern - Replace pattern in function at a given position
(define (lsp-handle-tl-replace-pattern-at
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document-decls params docs)
    [(LspDocumentDeclsLookup.Found path text _ decls)
      (let
        [pos-key : String "position"]
        (match (json.json-object-get params (& pos-key))
          [(json.JsonFound position)
            (let
              [line : i64 (lsp-json-int-field-default position "line" 0)]
              [col : i64 (lsp-json-int-field-default position "character" 0)]
              [name : String (lsp-find-and-extract-name text line col)]
              (if (= (string.string-length name) 0)
                (begin
                  (lsp-write-error
                    id
                    -32600
                    "Could not extract function name at position")
                  (LspHandleResult.Continue docs))
                (match (lsp-json-string-field params "oldPattern")
                  [(LspJsonText.Ok old-pattern)
                    (match (lsp-json-string-field params "newPattern")
                      [(LspJsonText.Ok new-pattern)
                        (match (lsp-replace-pattern-text-with-decls
                          text
                          name
                          old-pattern
                          new-pattern
                          decls)
                          [(LspEditResult.Ok replaced)
                            (let
                              [formatted : String
                                (lsp-format-edit-text replaced)]
                              (begin
                                (lsp-write-response
                                  id
                                  (lsp-json-object2
                                    "success"
                                    (json.JsonBool true)
                                    "text"
                                    (json.JsonString formatted)))
                                (LspHandleResult.Continue docs)))]
                          [(LspEditResult.Err message)
                            (begin
                              (lsp-write-error id -32600 message)
                              (LspHandleResult.Continue docs))])]
                      [(LspJsonText.Missing)
                        (begin
                          (lsp-write-error
                            id
                            -32600
                            "Missing newPattern parameter")
                          (LspHandleResult.Continue docs))])]
                  [(LspJsonText.Missing)
                    (begin
                      (lsp-write-error id -32600 "Missing oldPattern parameter")
                      (LspHandleResult.Continue docs))])))]
          [(json.JsonMissing)
            (begin
              (lsp-write-error id -32600 "Missing position parameter")
              (LspHandleResult.Continue docs))]))]
    [(LspDocumentDeclsLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

;; tl/read - Read the form at a given position
(define (lsp-handle-tl-read-form-at
  [id : json.Json]
  [params : json.Json]
  [docs : LspDocuments]) : LspHandleResult
  (match (lsp-get-document params docs)
    [(LspDocumentLookup.Found path text _)
      (let
        [pos-key : String "position"]
        (match (json.json-object-get params (& pos-key))
          [(json.JsonFound position)
            (let
              [line : i64 (lsp-json-int-field-default position "line" 0)]
              [col : i64 (lsp-json-int-field-default position "character" 0)]
              [outer : i64 (lsp-json-int-field-default params "outer" 0)]
              [form-text : String
                (lsp-read-form-at-position text line col outer)]
              (if (= (string.string-length form-text) 0)
                (begin
                  (lsp-write-error id -32600 "No form found at position")
                  (LspHandleResult.Continue docs))
                (begin
                  (lsp-write-response
                    id
                    (lsp-json-object2
                      "success"
                      (json.JsonBool true)
                      "form"
                      (json.JsonString form-text)))
                  (LspHandleResult.Continue docs))))]
          [(json.JsonMissing)
            (begin
              (lsp-write-error id -32600 "Missing position parameter")
              (LspHandleResult.Continue docs))]))]
    [(LspDocumentLookup.Missing)
      (begin
        (lsp-write-error id -32600 "Document not found")
        (LspHandleResult.Continue docs))]))

(define (lsp-replace-form-at-position-smoke-ok?) : bool
  (let
    [text : String "(define (foo) : i64 1)\n(define (bar) : i64 2)"]
    (match (lsp-replace-form-at-position text 1 5 "(define (baz) : i64 3)")
      [(LspEditResult.Ok replaced)
        (string.string-eq
          replaced
          "(define (foo) : i64 1)\n(define (baz) : i64 3)")]
      [(LspEditResult.Err _) false])))

(define (lsp-find-top-level-form-at-offset-smoke-ok?) : bool
  (let
    [text : String "(define (foo) : i64\n  (+ 1 2))\n(define (bar) : i64 3)"]
    [nested-offset : i64 (lsp-offset-at-position text 1 4)]
    [second-offset : i64 (lsp-offset-at-position text 2 9)]
    (and
      (= (lsp-find-top-level-form-at-offset text nested-offset) 0)
      (=
        (lsp-find-top-level-form-at-offset text second-offset)
        (lsp-offset-at-position text 2 0))
      (= (lsp-find-top-level-form-at-offset text -1) -1)
      (=
        (lsp-find-top-level-form-at-offset text (string.string-length text))
        -1))))

(define (lsp-replace-form-at-position-nested-smoke-ok?) : bool
  (let
    [text : String "(define (foo) : i64\n  (+ 1 2))\n(define (bar) : i64 3)"]
    (match (lsp-replace-form-at-position text 1 4 "(define (baz) : i64 4)")
      [(LspEditResult.Ok replaced)
        (string.string-eq
          replaced
          "(define (baz) : i64 4)\n(define (bar) : i64 3)")]
      [(LspEditResult.Err _) false])))

(define (lsp-replace-form-at-position-noop-ok?) : bool
  (let
    [text : String "(define (foo) : i64 1)"]
    (match (lsp-replace-form-at-position text 0 22 "(define (bad) : i64 0)")
      [(LspEditResult.Ok replaced) (string.string-eq replaced text)]
      [(LspEditResult.Err _) false])))

(test
  lsp-replace-form-at-position-smoke
  (unless
    (lsp-replace-form-at-position-smoke-ok?)
    (io.panic "lsp-replace-form-at-position-smoke failed")))

(test
  lsp-find-top-level-form-at-offset-smoke
  (unless
    (lsp-find-top-level-form-at-offset-smoke-ok?)
    (io.panic "lsp-find-top-level-form-at-offset-smoke failed")))

(test
  lsp-replace-form-at-position-nested-smoke
  (unless
    (lsp-replace-form-at-position-nested-smoke-ok?)
    (io.panic "lsp-replace-form-at-position-nested-smoke failed")))

(test
  lsp-replace-form-at-position-noop
  (unless
    (lsp-replace-form-at-position-noop-ok?)
    (io.panic "lsp-replace-form-at-position-noop failed")))