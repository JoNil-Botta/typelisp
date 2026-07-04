;; lsp_frame_smoke.tl - Runnable smoke for LSP diagnostic metadata adapters.
(import stdlib.fs)
(import stdlib.io)
(import stdlib.json)
(import stdlib.string)
(import stdlib.vector as svec)
(import "../lsp_frame_core.tl")

(define (lsp-smoke-string-vec-contains?
  [items : svec.StringVec]
  [needle : String]) : bool
  (let
    [idx : i64 0]
    [found : bool false]
    (begin
      (while (< idx (svec.string-vec-len (& items)))
        (if (string.eq (svec.string-vec-get (& items) idx "") needle)
          (begin
            (set! found true)
            (set! idx (svec.string-vec-len (& items))))
          (set! idx (+ idx 1))))
      found)))

(define (lsp-completion-smoke-ok?) : bool
  (let
    [src : String
      "(define (square [x : i64]) : i64 (* x x)) (define answer : i64 42)"]
    [names : svec.StringVec (lsp-collect-def-names src (svec.string-vec-new))]
    [keywords : svec.StringVec (lsp-split-spaces (lsp-completion-keywords))]
    [builtins : svec.StringVec (lsp-split-spaces (lsp-completion-builtins))]
    [types : svec.StringVec (lsp-split-spaces (lsp-completion-types))]
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
      (match (compiler-check-source-with-roots
        "ok.tl"
        ok-src
        (svec.string-vec-new))
        [(ResultCompilerCheck.Ok _) true]
        [(ResultCompilerCheck.Err _) false])]
    [bad-result : bool
      (match (compiler-check-source-with-roots
        "bad.tl"
        bad-src
        (svec.string-vec-new))
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
        (match (compiler-check-source-with-roots
          "test.tl"
          src
          (svec.string-vec-new))
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
        42))))