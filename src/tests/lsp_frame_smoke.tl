;; lsp_frame_smoke.tl - Runnable smoke for LSP diagnostic metadata adapters.
(import stdlib.fs)
(import stdlib.io)
(import stdlib.arena)
(import stdlib.json)
(import stdlib.string)
(import stdlib.vector)
(import (vector String) as lsp_svec)
(import "../lsp_frame_core.tl")

(define (lsp-smoke-string-vec-contains?
  [items : lsp_svec.Vec]
  [needle : String]) : bool
  (let
    [idx : i64 0]
    [found : bool false]
    (begin
      (while (< idx (lsp_svec.len (& items)))
        (if (string.eq (lsp_svec.get (& items) idx "") needle)
          (begin
            (set! found true)
            (set! idx (lsp_svec.len (& items))))
          (set! idx (+ idx 1))))
      found)))

(define (lsp-completion-smoke-ok?) : bool
  (let
    [src : String
      "(define (square [x : i64]) : i64 (* x x)) (define answer : i64 42)"]
    [names : lsp_svec.Vec (lsp-collect-def-names src (lsp_svec.new))]
    [keywords : lsp_svec.Vec (lsp-split-spaces (lsp-completion-keywords))]
    [builtins : lsp_svec.Vec (lsp-split-spaces (lsp-completion-builtins))]
    [types : lsp_svec.Vec (lsp-split-spaces (lsp-completion-types))]
    (and
      (lsp-smoke-string-vec-contains? names "square")
      (lsp-smoke-string-vec-contains? names "answer")
      (lsp-smoke-string-vec-contains? keywords "define")
      (lsp-smoke-string-vec-contains? builtins "make-array")
      (lsp-smoke-string-vec-contains? types "i64"))))

(define (lsp-smoke-index-of [haystack : String] [needle : String]) : i64
  (let
    [n : i64 (string.string-length haystack)]
    [m : i64 (string.string-length needle)]
    [i : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< i n) (< found 0))
        (if (and
          (<= (+ i m) n)
          (string.is-string-prefix-at (& haystack) (& needle) i))
          (set! found i)
          (set! i (+ i 1))))
      found)))

(define (lsp-transcript-frame [body : String]) : String
  (lsp-str5
    "Content-Length: "
    (string.int->string (string.string-length body))
    "\r\n\r\n"
    body
    ""))

(define (lsp-transcript-run [input : String]) : LspTranscriptResult
  (lsp-frame-run-transcript (& input) (lsp_svec.new) false))

(define (lsp-transcript-result-contains?
  [result : LspTranscriptResult]
  [needle : String]) : bool
  (string.contains (& (struct-get result stdout)) (& needle)))

(define (lsp-transcript-framing-smoke-ok?) : bool
  (let
    [clean : LspTranscriptResult (lsp-transcript-run "")]
    [unterminated : LspTranscriptResult
      (lsp-transcript-run "Content-Length: 2")]
    [missing : LspTranscriptResult (lsp-transcript-run "\r\n")]
    [invalid : LspTranscriptResult
      (lsp-transcript-run "Content-Length: nope\r\n\r\n")]
    [truncated : LspTranscriptResult
      (lsp-transcript-run "Content-Length: 5\r\n\r\n{}")]
    [malformed : LspTranscriptResult
      (lsp-transcript-run (lsp-transcript-frame "{]"))]
    [parse-code : String "\"code\":-32700"]
    (and
      (= (struct-get clean status) 0)
      (string.eq (struct-get clean stdout) "")
      (string.eq (struct-get clean stderr) "")
      (= (struct-get unterminated status) 1)
      (string.eq
        (struct-get unterminated stderr)
        "lsp: EOF before header terminator")
      (lsp-transcript-result-contains? unterminated parse-code)
      (= (struct-get missing status) 1)
      (string.eq (struct-get missing stderr) "lsp: missing Content-Length")
      (lsp-transcript-result-contains? missing parse-code)
      (= (struct-get invalid status) 1)
      (string.eq (struct-get invalid stderr) "lsp: invalid Content-Length")
      (lsp-transcript-result-contains? invalid parse-code)
      (= (struct-get truncated status) 1)
      (string.eq (struct-get truncated stderr) "lsp: truncated payload")
      (lsp-transcript-result-contains? truncated parse-code)
      (= (struct-get malformed status) 0)
      (string.eq (struct-get malformed stderr) "")
      (lsp-transcript-result-contains? malformed parse-code))))

(define (lsp-transcript-order-and-id-smoke-ok?) : bool
  (let
    [initialize : String
      "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"initialize\",\"params\":{}}"]
    [shutdown : String
      "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"shutdown\"}"]
    [exit : String "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"]
    [input : String
      (string.append
        (lsp-transcript-frame initialize)
        (string.append
          (lsp-transcript-frame shutdown)
          (lsp-transcript-frame exit)))]
    [ordered : LspTranscriptResult (lsp-transcript-run input)]
    [out : String (struct-get ordered stdout)]
    [first-id : String "\"id\":41"]
    [second-id : String "\"id\":42"]
    [first-pos : i64 (lsp-smoke-index-of out first-id)]
    [second-pos : i64 (lsp-smoke-index-of out second-id)]
    [next-initialize : String
      "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"initialize\",\"params\":{}}"]
    [next-input : String
      (string.append
        (lsp-transcript-frame next-initialize)
        (lsp-transcript-frame exit))]
    [next : LspTranscriptResult (lsp-transcript-run next-input)]
    [old-id : String "\"id\":41"]
    [new-id : String "\"id\":3"]
    (and
      (= (struct-get ordered status) 0)
      (string.eq (struct-get ordered stderr) "")
      (>= first-pos 0)
      (> second-pos first-pos)
      (= (struct-get next status) 0)
      (lsp-transcript-result-contains? next new-id)
      (not (lsp-transcript-result-contains? next old-id)))))

(define (lsp-transcript-did-open [uri : String] [text : String]) : String
  (lsp-str7
    "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\""
    uri
    "\",\"languageId\":\"typelisp\",\"version\":1,\"text\":\""
    text
    "\"}}}"
    ""
    ""))

(define (lsp-transcript-check [uri : String] [id : i64]) : String
  (lsp-str5
    "{\"jsonrpc\":\"2.0\",\"id\":"
    (string.int->string id)
    ",\"method\":\"tl/check\",\"params\":{\"uri\":\""
    uri
    "\"}}"))

(define (lsp-transcript-check-session [uri : String] [text : String] [id : i64]) : LspTranscriptResult
  (let
    [exit : String "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"]
    [input : String
      (string.append
        (lsp-transcript-frame (lsp-transcript-did-open uri text))
        (string.append
          (lsp-transcript-frame (lsp-transcript-check uri id))
          (lsp-transcript-frame exit)))]
    (lsp-transcript-run input)))

(define (lsp-transcript-reset-leakage-smoke-ok?) : bool
  (let
    [path : String "target/lsp_transcript_reset_missing.tl"]
    [uri : String (lsp-resolved-path-to-file-uri path)]
    [valid-source : String "(define (same) : i64 1)"]
    [invalid-source : String "(define (same) : i64 true)"]
    [first : LspTranscriptResult
      (lsp-transcript-check-session uri valid-source 71)]
    [second : LspTranscriptResult
      (lsp-transcript-check-session uri invalid-source 72)]
    [exit : String "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"]
    [missing-input : String
      (string.append
        (lsp-transcript-frame (lsp-transcript-check uri 73))
        (lsp-transcript-frame exit))]
    [missing : LspTranscriptResult (lsp-transcript-run missing-input)]
    [success : String "\"success\":true"]
    [failure : String "\"success\":false"]
    [unreadable : String "Could not read document"]
    (and
      (= (struct-get first status) 0)
      (lsp-transcript-result-contains? first success)
      (= (struct-get second status) 0)
      (lsp-transcript-result-contains? second failure)
      (= (struct-get missing status) 0)
      (lsp-transcript-result-contains? missing unreadable)
      (not lsp-frame-memory-active)
      (= lsp-document-cache-arena 0))))

(define (lsp-transcript-arena-escape-smoke-ok?) : bool
  (let
    [home : i64 (arena.tl_arena_current)]
    [exit : String "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"]
    [result : LspTranscriptResult
      (lsp-transcript-run (lsp-transcript-frame exit))]
    (and
      (= (arena.tl_arena_current) home)
      (= (struct-get result status) 0)
      (string.eq (struct-get result stdout) "")
      (string.eq (struct-get result stderr) "")
      (not lsp-frame-memory-active))))

(define (lsp-inlay-smoke-ok?) : bool
  (let
    [src : String
      "(define (main) : i64 (let [total 41] [typed : i64 5] [next (+ total 1)] next))"]
    [total-off : i64 (lsp-smoke-index-of src "41")]
    [typed-off : i64 (lsp-smoke-index-of src "5]")]
    [next-off : i64 (lsp-smoke-index-of src "(+ total 1)")]
    (if (or (< total-off 0) (< typed-off 0) (< next-off 0))
      false
      (begin
        (tc-inlay-hints-enable!)
        (tc-inlay-hint-record! 1 (+ total-off 1) "i64")
        (tc-inlay-hint-record! 1 (+ typed-off 1) "i64")
        (tc-inlay-hint-record! 1 (+ next-off 1) "i64")
        (let
          [hints : json.JsonList (lsp-inlay-build src 0 0)]
          [rendered : String (json.stringify (lsp-json-array hints))]
          [type-label : String "\": i64\""]
          [total-pos : String "\"character\":33"]
          [next-pos : String "\"character\":59"]
          (begin
            (tc-inlay-hints-disable!)
            (and
              (= (json.list-count hints) 2)
              (string.contains (& rendered) (& type-label))
              (string.contains (& rendered) (& total-pos))
              (string.contains (& rendered) (& next-pos)))))))))

(define (lsp-formatting-smoke-ok?) : bool
  (let
    [messy : String "(define   (f)  :  i64   (+ 1   2))"]
    (match (format-rules-render-source-width-result messy 80)
      [(ResultFormatString.Ok formatted)
        (let
          [rendered : String
            (json.stringify (lsp-formatting-edit messy formatted))]
          [sig : String "(define (f) : i64"]
          [newtext-key : String "\"newText\""]
          [range-key : String "\"range\""]
          (and
            (string.contains (& formatted) (& sig))
            (string.contains (& rendered) (& newtext-key))
            (string.contains (& rendered) (& range-key))))]
      [(ResultFormatString.Err _) false])))

(define (lsp-format-edit-text-smoke-ok?) : bool
  (let
    [messy : String "(define   (f)  :  i64   (+ 1   2))"]
    [invalid : String "(define (f) : i64"]
    [formatted : String (lsp-format-edit-text messy)]
    [fallback : String (lsp-format-edit-text invalid)]
    [sig : String "(define (f) : i64"]
    (and
      (string.contains (& formatted) (& sig))
      (not (string.eq formatted messy))
      (string.eq fallback invalid))))

(define (lsp-check-smoke-ok?) : bool
  (let
    [ok-src : String "(define (main) : i64 42)"]
    [bad-src : String "(define (main) : i64 (+ 1 \"two\"))"]
    [ok-result : bool
      (match (compiler-check-source "ok.tl" ok-src)
        [(ResultCompilerCheck.Ok _) true]
        [(ResultCompilerCheck.Err _) false])]
    [bad-result : bool
      (match (compiler-check-source "bad.tl" bad-src)
        [(ResultCompilerCheck.Ok _) false]
        [(ResultCompilerCheck.Err _) true])]
    (and ok-result bad-result)))

(define (lsp-get-type-smoke-ok?) : bool
  (let
    [src : String
      "(define (main) : i32 (let [total 41] [next (+ total 1)] next))"]
    [total-off : i64 (lsp-smoke-index-of src "41")]
    (if (< total-off 0)
      false
      (begin
        (tc-inlay-hints-enable!)
        (match (compiler-check-source "test.tl" src)
          [(ResultCompilerCheck.Ok _) unit]
          [(ResultCompilerCheck.Err _) unit])
        (let
          [size : i64 (tc-inlay-hints-size)]
          [i : i64 0]
          [found-ok : bool false]
          [near-ok : bool false]
          (begin
            (while (and (< i size) (not found-ok))
              (let
                [hint-line : i64 (tc-inlay-hint-line-at i)]
                [hint-col : i64 (tc-inlay-hint-col-at i)]
                [target-line : i64 1]
                [target-col : i64 (+ total-off 1)]
                (begin
                  (if (and (= hint-line target-line) (= hint-col target-col))
                    (set! found-ok (string.eq (tc-inlay-hint-type-at i) "i32"))
                    unit)
                  (set! i (+ i 1)))))
            (let
              [near-idx : i64 (lsp-nearest-inlay-hint-index 1 (+ total-off 3))]
              (if (>= near-idx 0)
                (set!
                  near-ok
                  (string.eq (tc-inlay-hint-type-at near-idx) "i32"))
                unit))
            (tc-inlay-hints-disable!)
            (and found-ok near-ok)))))))

(define (lsp-find-references-smoke-ok?) : bool
  (let
    [src : String
      "(define (foo [x : i64]) : i64 x) (define (bar) : i64 (foo 1))"]
    [refs : json.JsonList
      (lsp-find-references-in-text
        src
        "foo"
        0
        (string.string-length src)
        json.JsonListNil)]
    [rendered : String (json.stringify (lsp-json-array refs))]
    [count-ok : bool (= (json.list-count refs) 2)]
    [needle0 : String "\"line\":0"]
    [line0-ok : bool (string.contains (& rendered) (& needle0))]
    (and count-ok line0-ok)))

(define (lsp-document-decls-cache-empty-ok?) : bool
  (let
    [uri : String "file:///tmp/cache.tl"]
    [path : String "/tmp/cache.tl"]
    [docs0 : LspDocuments (lsp-documents-new)]
    [docs1 : LspDocuments (lsp-documents-set docs0 uri path "" uri)]
    [doc1 : LspDocument (lsp-documents-get (& docs1) 0 (lsp-document-fallback))]
    [empty-decls : LspDeclList (lsp-document-decls doc1 docs1)]
    [cached-empty-doc : LspDocument
      (lsp-documents-get (& docs1) 0 (lsp-document-fallback))]
    [docs2 : LspDocuments (lsp-documents-set docs1 uri path "" "diag")]
    [same-text-doc : LspDocument
      (lsp-documents-get (& docs2) 0 (lsp-document-fallback))]
    [docs3 : LspDocuments
      (lsp-documents-set docs2 uri path "(define cached : i64 1)" "diag")]
    [changed-doc : LspDocument
      (lsp-documents-get (& docs3) 0 (lsp-document-fallback))]
    [changed-decls : LspDeclList (lsp-document-decls changed-doc docs3)]
    [cached-changed-doc : LspDocument
      (lsp-documents-get (& docs3) 0 (lsp-document-fallback))]
    (and
      (= (lsp-decl-list-len (& empty-decls)) 0)
      (struct-get cached-empty-doc decls-valid)
      (= (lsp-decl-list-len (struct-get cached-empty-doc decls)) 0)
      (struct-get same-text-doc decls-valid)
      (not (struct-get changed-doc decls-valid))
      (= (lsp-decl-list-len (& changed-decls)) 1)
      (struct-get cached-changed-doc decls-valid))))

(define (lsp-document-disk-resync-ok?) : bool
  (let
    [dir : String "target"]
    [path : String "target/lsp_disk_resync_smoke.tl"]
    [uri : String (lsp-resolved-path-to-file-uri path)]
    [stale-text : String "(define stale : i64 0)"]
    [disk-text : String "(define fresh : i64 1)"]
    [fresh-name : String "fresh"]
    [params : json.Json
      (lsp-json-object1
        "textDocument"
        (lsp-json-object1 "uri" (json.JsonString uri)))]
    [docs : LspDocuments (lsp-documents-new)]
    (begin
      (match (fs.try-mkdir-if-missing (& dir))
        [(io.OkIoUnit) unit]
        [(io.ErrIoUnit _) unit])
      (io.write-file path disk-text)
      (set! docs (lsp-documents-set docs uri path stale-text uri))
      (let
        [lookup-ok : bool
          (match (lsp-get-document params docs)
            [(LspDocumentLookup.Found _ text _)
              (string.contains (& text) (& fresh-name))]
            [(LspDocumentLookup.Missing) false])]
        [cached-doc : LspDocument
          (lsp-documents-get (& docs) 0 (lsp-document-fallback))]
        [cache-ok : bool
          (and
            (string.contains (& (struct-get cached-doc text)) (& fresh-name))
            (not (struct-get cached-doc decls-valid)))]
        [decls-ok : bool
          (match (lsp-get-document-decls params docs)
            [(LspDocumentDeclsLookup.Found _ text _ decls)
              (let
                [entry : LspDeclEntry
                  (lsp-decl-list-get (& decls) 0 (lsp-decl-entry-fallback))]
                (and
                  (string.contains (& text) (& fresh-name))
                  (= (lsp-decl-list-len (& decls)) 1)
                  (string.eq (struct-get entry name) fresh-name)))]
            [(LspDocumentDeclsLookup.Missing) false])]
        [cached-decls-doc : LspDocument
          (lsp-documents-get (& docs) 0 (lsp-document-fallback))]
        (and
          lookup-ok
          cache-ok
          decls-ok
          (struct-get cached-decls-doc decls-valid))))))

(define (lsp-edit-save-doc-smoke-ok?) : bool
  (let
    [dir : String "target"]
    [path : String "target/lsp_edit_save_doc_smoke.tl"]
    [uri : String (lsp-resolved-path-to-file-uri path)]
    [initial : String "(define (main) : i64 1)"]
    [updated : String "(define (main) : i64 42)"]
    [docs : LspDocuments
      (lsp-documents-set (lsp-documents-new) uri path initial uri)]
    (begin
      (match (fs.try-mkdir-if-missing (& dir))
        [(io.OkIoUnit) unit]
        [(io.ErrIoUnit _) unit])
      (match (lsp-tl-save-doc docs uri path uri updated)
        [(LspSaveResult.Ok next-docs)
          (let
            [disk-text : String (io.read-file path)]
            [cached-doc : LspDocument
              (lsp-documents-get (& next-docs) 0 (lsp-document-fallback))]
            (and
              (string.eq disk-text updated)
              (string.eq (struct-get cached-doc text) updated)
              (not (struct-get cached-doc decls-valid))))]
        [(LspSaveResult.Err _) false]))))

(define (lsp-scan-decls-cache-local-smoke-ok?) : bool
  (let
    [first : String "(define (alpha) : i64 1)"]
    [second : String
      ";; one\n;; two\n;; three\n\n(define (wide) : i64 2)\n(define (next) : i64 3)"]
    [first-decls : LspDeclList (lsp-scan-decls first)]
    [second-decls : LspDeclList (lsp-scan-decls second)]
    [wide : LspDeclEntry
      (lsp-decl-list-get (& second-decls) 0 (lsp-decl-entry-fallback))]
    [next : LspDeclEntry
      (lsp-decl-list-get (& second-decls) 1 (lsp-decl-entry-fallback))]
    (and
      (= (lsp-decl-list-len (& first-decls)) 1)
      (= (lsp-decl-list-len (& second-decls)) 2)
      (string.eq (struct-get wide name) "wide")
      (= (struct-get wide form-start-line) 5)
      (= (struct-get wide form-start-col) 1)
      (= (struct-get wide name-line) 5)
      (= (struct-get wide name-col) 10)
      (string.eq (struct-get next name) "next")
      (= (struct-get next form-start-line) 6)
      (= (struct-get next form-start-col) 1)
      (= (struct-get next name-line) 6)
      (= (struct-get next name-col) 10))))

(define (lsp-document-symbol-smoke-ok?) : bool
  (let
    [source : String
      "(define (fun) : i64 1)\n(define value : i64 2)\n(defstruct Pair (x i64))\n(defenum Choice (Yes))\n(defmacro make [] unit)\n(defdispatch choose [] fun)\n(extern (puts [s : ptr]) : i64)\n(extern errno : i64)\n;; (define hidden : i64 0)\n(define text : String \"(defstruct Hidden)\")"]
    [rendered : String (json.stringify (lsp-document-symbols-for-text source))]
    [capabilities : String (json.stringify (lsp-initialize-result))]
    [fun : String
      "{\"name\":\"fun\",\"kind\":12,\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":22}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":9},\"end\":{\"line\":0,\"character\":12}}}"]
    [value : String
      "{\"name\":\"value\",\"kind\":13,\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":22}},\"selectionRange\":{\"start\":{\"line\":1,\"character\":8},\"end\":{\"line\":1,\"character\":13}}}"]
    [pair : String "{\"name\":\"Pair\",\"kind\":23"]
    [choice : String "{\"name\":\"Choice\",\"kind\":10"]
    [macro : String "{\"name\":\"make\",\"kind\":12"]
    [dispatch : String "{\"name\":\"choose\",\"kind\":12"]
    [function-extern : String "{\"name\":\"puts\",\"kind\":12"]
    [data-extern : String "{\"name\":\"errno\",\"kind\":13"]
    [text-value : String "{\"name\":\"text\",\"kind\":13"]
    [hidden : String "\"name\":\"hidden\""]
    [hidden-in-string : String "\"name\":\"Hidden\""]
    [capability : String "\"documentSymbolProvider\":true"]
    (and
      (string.contains (& capabilities) (& capability))
      (string.contains (& rendered) (& fun))
      (string.contains (& rendered) (& value))
      (string.contains (& rendered) (& pair))
      (string.contains (& rendered) (& choice))
      (string.contains (& rendered) (& macro))
      (string.contains (& rendered) (& dispatch))
      (string.contains (& rendered) (& function-extern))
      (string.contains (& rendered) (& data-extern))
      (string.contains (& rendered) (& text-value))
      (not (string.contains (& rendered) (& hidden)))
      (not (string.contains (& rendered) (& hidden-in-string))))))

(define (main) : i64
  (let
    [base-result : i64 (lsp-diagnostic-metadata-smoke)]
    (if (not (= base-result 42))
      base-result
      (begin
        (unless (lsp-completion-smoke-ok?) (return 6))
        (unless (lsp-inlay-smoke-ok?) (return 7))
        (unless (lsp-formatting-smoke-ok?) (return 8))
        (unless (lsp-format-edit-text-smoke-ok?) (return 14))
        (unless (lsp-check-smoke-ok?) (return 9))
        (unless (lsp-get-type-smoke-ok?) (return 10))
        (unless (lsp-find-references-smoke-ok?) (return 11))
        (unless (lsp-document-decls-cache-empty-ok?) (return 12))
        (unless (lsp-document-disk-resync-ok?) (return 15))
        (unless (lsp-edit-save-doc-smoke-ok?) (return 16))
        (unless (lsp-scan-decls-cache-local-smoke-ok?) (return 13))
        (unless (lsp-document-symbol-smoke-ok?) (return 17))
        (unless (lsp-transcript-framing-smoke-ok?) (return 18))
        (unless (lsp-transcript-order-and-id-smoke-ok?) (return 19))
        (unless (lsp-transcript-reset-leakage-smoke-ok?) (return 20))
        (unless (lsp-transcript-arena-escape-smoke-ok?) (return 21))
        42))))