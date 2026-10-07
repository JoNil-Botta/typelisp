;; lsp_frame_core_tests.tl - White-box tests for the LSP frame: documents, the
;; semantic snapshot cache, diagnostics, completion and call contexts,
;; signatures, rename, text patches and the structural form editors.
(import stdlib.iterator)
(import compiler_owned_view as owned_view)
(import stdlib.io)
(import stdlib.json)
(import stdlib.vector)
(import (vector.vector String) as lsp_svec)
(import compiler_semantic_index as sem)
(cfg test (import compiler_semantic_index_tests as sem_tests))
(import compiler_diagnostic as cdiag)
(import compiler_load)
(import lsp_vector_families as lvf)
(import (vector.vector lvf.LspDeclEntry core) as lsp_decl_vec)
(import (vector.vector lvf.LspDocument core) as lsp_document_vec)
(import stdlib.string)
(import source_text_core as source_text)
(cfg test (import token))
(import lsp_frame_core as lsp)

;; Percent-decoding a file URI yields bytes (#8376): `%XX` is byte XX, so the
;; encoder's output for a non-ASCII path decodes back to the same path.
(define (lsp-percent-decode-is? [text : String] [want : String]) : bool
  (match (lsp.lsp-percent-decode text)
    [(Ok decoded) (string.eq decoded want)]
    [(Err _) false]))

(define (lsp-percent-decode-error-is? [text : String] [want : String]) : bool
  (match (lsp.lsp-percent-decode text)
    [(Ok _) false]
    [(Err message) (string.eq message want)]))

(define (lsp-file-uri-round-trips? [path : String]) : bool
  (let
    [uri : String (lsp.lsp-path-to-file-uri (string.copy (& path)))]
    (match (lsp.lsp-file-uri-to-path (& uri))
      [(Ok decoded) (string.eq decoded path)]
      [(Err _) false])))

(define (lsp-percent-decode-bytes-ok?) : bool
  (and
    (lsp-percent-decode-is? "/tmp/%c3%a5/u.tl" "/tmp/å/u.tl")
    (lsp-percent-decode-is? "/tmp/%C3%A5/u.tl" "/tmp/å/u.tl")
    (lsp-percent-decode-is? "a%20b%26c%2Fd" "a b&c/d")
    (lsp-percent-decode-is? "plain" "plain")
    (lsp-percent-decode-error-is?
      "/tmp/%4"
      "lsp: invalid percent escape in file URI")
    (lsp-percent-decode-error-is?
      "/tmp/%"
      "lsp: invalid percent escape in file URI")
    (lsp-percent-decode-error-is?
      "/tmp/%zz/u.tl"
      "lsp: invalid percent escape in file URI")
    (lsp-percent-decode-error-is?
      "/tmp/%ff/u.tl"
      "lsp: file URI path is not valid UTF-8")
    (lsp-percent-decode-error-is?
      "/tmp/%c3/u.tl"
      "lsp: file URI path is not valid UTF-8")
    (lsp-percent-decode-error-is?
      "/tmp/%00/u.tl"
      "lsp: file URI path is not valid UTF-8")
    (lsp-file-uri-round-trips? "/tmp/å b&c/café.tl")
    (lsp-file-uri-round-trips? "/tmp/x/ascii.tl")))

(define (lsp-diagnostic-uris-single [uri : String]) : lvf.LspDiagnosticUris
  (lsp.lsp-diagnostic-uris-add (lsp.lsp-diagnostic-uris-empty) uri))

(define (lsp-documents-smoke-add [docs : lsp_document_vec.Vec] [uri : String]) : lsp_document_vec.Vec
  (lsp.lsp-documents-set
    docs
    (owned_view.compiler-owned-shared-view uri)
    (owned_view.compiler-owned-shared-view uri)
    uri
    (lsp.lsp-diagnostic-uris-empty)))

(define (lsp-documents-smoke-missing?
  [docs : (& docs lsp_document_vec.Vec)]
  [uri : String]) : bool
  (match (lsp.lsp-documents-lookup docs uri)
    [(Found _ _ _) false]
    [(Missing) true]))

(define (lsp-documents-smoke-text-eq?
  [docs : (& docs lsp_document_vec.Vec)]
  [uri : String]
  [expected-text : String]) : bool
  (match (lsp.lsp-documents-lookup docs uri)
    [(Found _ text _) (string.eq text expected-text)]
    [(Missing) false]))

(define (lsp-documents-smoke-check-cache-ok?
  [docs : (& docs lsp_document_vec.Vec)]
  [uri : (& uri str)]) : bool
  (let
    [idx : i64 (lsp.lsp-documents-find-index docs uri)]
    (if (< idx 0)
      false
      (let
        [doc : lvf.LspDocument
          (lsp_document_vec.get (& docs) idx (lsp.lsp-document-fallback))]
        (match doc.check-cache
          [(LspCheckCacheOk) true]
          [_ false])))))

(define (lsp-documents-smoke-check-cache-invalid?
  [docs : lsp_document_vec.Vec]
  [uri : String]) : bool
  (let
    [idx : i64 (lsp.lsp-documents-find-index docs uri)]
    (if (< idx 0)
      false
      (let
        [doc : lvf.LspDocument
          (lsp_document_vec.get (& docs) idx (lsp.lsp-document-fallback))]
        (match doc.check-cache
          [(LspCheckCacheInvalid) true]
          [_ false])))))

(define (lsp-documents-check-cache-smoke-ok?) : bool
  (let
    [uri : String "file:///cached.tl"]
    [docs : lsp_document_vec.Vec
      (lsp.lsp-documents-set
        (lsp_document_vec.new)
        (owned_view.compiler-owned-shared-view uri)
        "cached.tl"
        "same"
        (lsp.lsp-diagnostic-uris-empty))]
    (lsp.lsp-documents-set-check-cache! (&mut docs) uri LspCheckCacheOk)
    (let
      [preserved-docs : lsp_document_vec.Vec
        (lsp.lsp-documents-set
          docs
          (owned_view.compiler-owned-shared-view uri)
          "cached.tl"
          "same"
          (lsp.lsp-diagnostic-uris-empty))]
      (if (not (lsp-documents-smoke-check-cache-ok? preserved-docs uri))
        false
        (let
          [invalidated-docs : lsp_document_vec.Vec
            (lsp.lsp-documents-set
              preserved-docs
              (owned_view.compiler-owned-shared-view uri)
              "cached.tl"
              "changed"
              (lsp.lsp-diagnostic-uris-empty))]
          (lsp-documents-smoke-check-cache-invalid? invalidated-docs uri))))))

(define (lsp-documents-open-retention-smoke-ok?) : bool
  (let
    [docs : lsp_document_vec.Vec (lsp_document_vec.new)]
    [empty-docs : lsp_document_vec.Vec (lsp_document_vec.new)]
    ;; Dropping an empty canonical vector is a no-op; removing below covers
    ;; the non-empty direct-len path after shift-left mutation.
    (lvf.lsp-documents-drop-last! (&mut empty-docs))
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
      (lsp.lsp-documents-set
        docs
        "file:///doc10.tl"
        "doc10.tl"
        "updated"
        (lsp-diagnostic-uris-single "diag10")))
    (set! docs (lsp-documents-smoke-add docs "file:///doc16.tl"))
    (and
      (= (lsp_document_vec.len (& docs)) 17)
      (lsp-documents-smoke-text-eq? docs "file:///doc00.tl" "file:///doc00.tl")
      (lsp-documents-smoke-text-eq? docs "file:///doc01.tl" "file:///doc01.tl")
      (lsp-documents-smoke-text-eq? docs "file:///doc10.tl" "updated")
      (lsp-documents-smoke-text-eq? docs "file:///doc16.tl" "file:///doc16.tl")
      (= (lsp_document_vec.len (& empty-docs)) 0)
      (let
        [trimmed : lsp_document_vec.Vec
          (lsp.lsp-documents-remove docs "file:///doc08.tl")]
        [shifted : lvf.LspDocument
          (lsp_document_vec.get (& trimmed) 8 (lsp.lsp-document-fallback))]
        [last : lvf.LspDocument
          (lsp_document_vec.get (& trimmed) 15 (lsp.lsp-document-fallback))]
        (and
          (= (lsp_document_vec.len (& trimmed)) 16)
          (lsp-documents-smoke-missing? trimmed "file:///doc08.tl")
          (string.eq shifted.uri "file:///doc09.tl")
          (string.eq last.uri "file:///doc16.tl"))))))

(cfg
  test
  (define (lsp-semantic-smoke-current?
    [doc : (& doc lvf.LspDocument)]
    [version : i64]) : bool
    (match (lsp.lsp-document-semantic-snapshot-status doc)
      [(Current snapshot-version complete)
        (and (= snapshot-version version) complete)]
      [_ false])))

(cfg
  test
  (define (lsp-semantic-smoke-stale?
    [doc : (& doc lvf.LspDocument)]
    [version : i64]) : bool
    (match (lsp.lsp-document-semantic-snapshot-status doc)
      [(Stale snapshot-version complete)
        (and (= snapshot-version version) complete)]
      [_ false])))

(cfg
  test
  (define (lsp-semantic-smoke-current-partial?
    [doc : (& doc lvf.LspDocument)]
    [version : i64]) : bool
    (match (lsp.lsp-document-semantic-snapshot-status doc)
      [(Current snapshot-version complete)
        (and (= snapshot-version version) (not complete))]
      [_ false])))

(cfg
  test
  (define (lsp-semantic-smoke-query-ok?
    [docs : (& docs lsp_document_vec.Vec)]
    [uri : (& uri str)]
    [path : String]
    [version : i64]
    [complete : bool]) : bool
    (let
      [doc-index : i64 (lsp.lsp-documents-find-index docs uri)]
      (if (< doc-index 0)
        false
        (let
          [doc : lvf.LspDocument
            (lsp_document_vec.get docs doc-index (lsp.lsp-document-fallback))]
          [index : sem.CompilerSemanticSourceIndex doc.semantic.index]
          [use-index : i64
            (sem_tests.compiler-semantic-source-index-find-record
              (& index)
              path
              "imported-value"
              Use
              -1)]
          [use-record : sem.CompilerSemanticRecord
            (sem.compiler-semantic-source-index-get (& index) use-index)]
          [use-byte : i64 use-record.span.start-byte]
          [query-ok : bool true]
          [iteration : i64 0]
          ;; Warm navigation is a pure read of the retained owner. Repeating
          ;; the shared query catches accidental rechecks, file reads, or
          ;; per-request semantic-index ownership changes.
          (while (and query-ok (< iteration 1000))
            (match (lsp.lsp-document-semantic-symbol-query (& doc) use-byte)
              [(Found cursor definition)
                (unless
                  (and
                    (sem.compiler-semantic-symbol-id-eq?
                      cursor.symbol
                      definition.symbol)
                    (lsp.lsp-semantic-record-exact-editable? cursor)
                    (lsp.lsp-semantic-record-exact-editable? definition)
                    (not (string.eq definition.span.path path)))
                  (set! query-ok false))]
              [(Missing) (set! query-ok false)])
            (let
              [highlights : lsp.LspDocumentHighlightResults
                (lsp.lsp-document-highlights-at (& doc) use-byte)]
              (unless
                (and
                  (= highlights.len 1)
                  (=
                    highlights.record-visits
                    (sem.compiler-semantic-source-index-len (& index)))
                  (= (array-ref highlights.slots 0).kind 2))
                (set! query-ok false)))
            (+= iteration 1))
          (and
            (if complete
              (lsp-semantic-smoke-current? (& doc) version)
              (lsp-semantic-smoke-current-partial? (& doc) version))
            (>= use-index 0)
            query-ok
            (= iteration 1000)))))))

(cfg
  test
  (define (lsp-semantic-smoke-install
    [docs : lsp_document_vec.Vec]
    [uri : String]
    [path : String]
    [source : String]
    [version : i64]
    [index : sem.CompilerSemanticSourceIndex]) : lsp_document_vec.Vec
    (lsp.lsp-documents-set-semantic-index
      (lsp.lsp-documents-set-check-cache
        (lsp.lsp-documents-set-versioned
          docs
          (owned_view.compiler-owned-shared-view uri)
          path
          source
          version
          (lsp.lsp-diagnostic-uris-empty))
        uri
        LspCheckCacheOk)
      uri
      version
      index)))

(cfg
  test
  (define (lsp-semantic-smoke-server-transfer-ok?
    [docs : lsp_document_vec.Vec]
    [uri : (& uri str)]
    [path : String]
    [version : i64]
    [baseline : i64]) : bool
    (let
      [empty-state : lvf.LspServerState (lsp.lsp-server-state-new)]
      (match (lsp.lsp-server-state-copy-document-result
        empty-state
        (Continue docs)
        false)
        [(Exit unexpected)
          (lsp.lsp-server-state-destroy! unexpected)
          false]
        [(Continue first-state)
          (let
            [first-docs : lsp_document_vec.Vec
              (owned_view.compiler-owned-shared-view first-state.documents)]
            [first-ok : bool
              (and
                (=
                  (sem_tests.compiler-semantic-source-index-live-owner-count)
                  (+ baseline 1))
                (lsp-semantic-smoke-query-ok?
                  first-docs
                  uri
                  (owned_view.compiler-owned-shared-view path)
                  version
                  true))]
            (match (lsp.lsp-server-state-copy-document-result
              first-state
              (Continue first-docs)
              false)
              [(Exit unexpected)
                (lsp.lsp-server-state-destroy! unexpected)
                false]
              [(Continue second-state)
                (let
                  [second-docs : lsp_document_vec.Vec
                    (owned_view.compiler-owned-shared-view
                      second-state.documents)]
                  [second-ok : bool
                    (lsp-semantic-smoke-query-ok?
                      second-docs
                      uri
                      path
                      version
                      true)]
                  (lsp.lsp-server-state-destroy! second-state)
                  (and
                    first-ok
                    second-ok
                    (=
                      (sem_tests.compiler-semantic-source-index-live-owner-count)
                      baseline)))]))]))))

(cfg
  test
  (define (lsp-semantic-snapshot-lifecycle-smoke-ok?) : bool
    (let
      [baseline : i64
        (sem_tests.compiler-semantic-source-index-live-owner-count)]
      [uri : String "file:///lsp-semantic-snapshot-smoke.tl"]
      [path : String "src/tests/lsp_semantic_snapshot_smoke.tl"]
      [source1 : String
        "(module lsp.semantic.snapshot.smoke)\n(import semantic.index.import_dep as dep)\n(define answer : i64 1)\n(define (use) : i64 (+ answer dep.imported-value))\n"]
      [invalid-source : String
        "(module lsp.semantic.snapshot.smoke)\n(import semantic.index.import_dep as dep)\n(define answer : i64 true)\n(define (use) : i64 (+ answer dep.imported-value))\n"]
      [source2 : String
        "(module lsp.semantic.snapshot.smoke)\n(import semantic.index.import_dep as dep)\n(define answer : i64 2)\n(define (use) : i64 (+ answer dep.imported-value))\n"]
      [source3 : String
        "(module lsp.semantic.snapshot.smoke)\n(import semantic.index.import_dep as dep)\n(define answer : i64 3)\n(define (use) : i64 (+ answer dep.imported-value))\n"]
      [roots : lsp_svec.Vec (lsp_svec.new)]
      [docs : lsp_document_vec.Vec (lsp_document_vec.new)]
      (match (sem.compiler-check-source-index-with-roots-and-cfg
        (owned_view.compiler-owned-shared-view path)
        (owned_view.compiler-owned-shared-view source1)
        (owned_view.compiler-owned-shared-view roots)
        (lsp.lsp-language-cfgs))
        [(Err _) false]
        [(Partial _ unexpected)
          (sem.compiler-semantic-source-index-release! (&mut unexpected))
          false]
        [(Ok _ first)
          (set!
            docs
            (lsp-semantic-smoke-install
              docs
              (owned_view.compiler-owned-shared-view uri)
              (owned_view.compiler-owned-shared-view path)
              source1
              1
              first))
          (let
            [first-ok : bool
              (and
                (=
                  (sem_tests.compiler-semantic-source-index-live-owner-count)
                  (+ baseline 1))
                (lsp-semantic-smoke-query-ok?
                  docs
                  uri
                  (owned_view.compiler-owned-shared-view path)
                  1
                  true))]
            (set!
              docs
              (lsp.lsp-documents-set-versioned
                docs
                (owned_view.compiler-owned-shared-view uri)
                (owned_view.compiler-owned-shared-view path)
                (owned_view.compiler-owned-shared-view invalid-source)
                2
                (lsp.lsp-diagnostic-uris-empty)))
            (let
              [stale-doc-index : i64 (lsp.lsp-documents-find-index docs uri)]
              [stale-doc : lvf.LspDocument
                (lsp_document_vec.get
                  (& docs)
                  stale-doc-index
                  (lsp.lsp-document-fallback))]
              [stale-highlights : lsp.LspDocumentHighlightResults
                (lsp.lsp-document-highlights-at (& stale-doc) 1)]
              [stale-ok : bool
                (and
                  (lsp-semantic-smoke-stale? (& stale-doc) 1)
                  (= (lsp.lsp-document-semantic-record-at (& stale-doc) 0) -1)
                  (= stale-highlights.len 0)
                  (= stale-highlights.record-visits 0)
                  (=
                    (sem_tests.compiler-semantic-source-index-live-owner-count)
                    (+ baseline 1)))]
              [invalid-ok : bool
                (match (sem.compiler-check-source-index-with-roots-and-cfg
                  (owned_view.compiler-owned-shared-view path)
                  invalid-source
                  (owned_view.compiler-owned-shared-view roots)
                  (lsp.lsp-language-cfgs))
                  [(Err _) false]
                  [(Partial diagnostics current)
                    (let
                      [diagnostic-list : cdiag.CompilerDiagnosticList
                        (deref diagnostics)]
                      [first-diagnostic : cdiag.CompilerDiagnostic
                        (cdiag.compiler-diagnostic-list-first diagnostic-list)]
                      (set!
                        docs
                        (lsp.lsp-documents-set-semantic-index
                          (lsp.lsp-documents-set-check-cache
                            docs
                            uri
                            (LspCheckCacheErr
                              (cdiag.compiler-diagnostic-message
                                first-diagnostic)))
                          uri
                          2
                          current))
                      (let
                        [partial-doc-index : i64
                          (lsp.lsp-documents-find-index docs uri)]
                        [partial-doc : lvf.LspDocument
                          (lsp_document_vec.get
                            (& docs)
                            partial-doc-index
                            (lsp.lsp-document-fallback))]
                        (and
                          (lsp-semantic-smoke-current-partial?
                            (& partial-doc)
                            2)
                          (lsp-semantic-smoke-query-ok?
                            docs
                            uri
                            (owned_view.compiler-owned-shared-view path)
                            2
                            false)
                          (=
                            (sem_tests.compiler-semantic-source-index-live-owner-count)
                            (+ baseline 1)))))]
                  [(Ok _ unexpected)
                    (sem.compiler-semantic-source-index-release!
                      (&mut unexpected))
                    false])]
              (match (sem.compiler-check-source-index-with-roots-and-cfg
                (owned_view.compiler-owned-shared-view path)
                (owned_view.compiler-owned-shared-view source2)
                (owned_view.compiler-owned-shared-view roots)
                (lsp.lsp-language-cfgs))
                [(Err _)
                  (lsp.lsp-documents-release-all! (&mut docs))
                  false]
                [(Partial _ unexpected)
                  (sem.compiler-semantic-source-index-release!
                    (&mut unexpected))
                  (lsp.lsp-documents-release-all! (&mut docs))
                  false]
                [(Ok _ second)
                  (set!
                    docs
                    (lsp-semantic-smoke-install
                      docs
                      (owned_view.compiler-owned-shared-view uri)
                      (owned_view.compiler-owned-shared-view path)
                      source2
                      3
                      second))
                  (let
                    [replacement-ok : bool
                      (and
                        (=
                          (sem_tests.compiler-semantic-source-index-live-owner-count)
                          (+ baseline 1))
                        (lsp-semantic-smoke-query-ok?
                          docs
                          uri
                          (owned_view.compiler-owned-shared-view path)
                          3
                          true))]
                    (set!
                      docs
                      (lsp.lsp-documents-remove
                        docs
                        (owned_view.compiler-owned-shared-view uri)))
                    (let
                      [close-ok : bool
                        (and
                          (lsp-documents-smoke-missing?
                            docs
                            (owned_view.compiler-owned-shared-view uri))
                          (=
                            (sem_tests.compiler-semantic-source-index-live-owner-count)
                            baseline))]
                      (match (sem.compiler-check-source-index-with-roots-and-cfg
                        (owned_view.compiler-owned-shared-view path)
                        (owned_view.compiler-owned-shared-view source3)
                        roots
                        (lsp.lsp-language-cfgs))
                        [(Err _) false]
                        [(Partial _ unexpected)
                          (sem.compiler-semantic-source-index-release!
                            (&mut unexpected))
                          false]
                        [(Ok _ third)
                          (set!
                            docs
                            (lsp-semantic-smoke-install
                              docs
                              (owned_view.compiler-owned-shared-view uri)
                              (owned_view.compiler-owned-shared-view path)
                              source3
                              4
                              third))
                          (let
                            [server-transfer-ok : bool
                              (lsp-semantic-smoke-server-transfer-ok?
                                docs
                                uri
                                path
                                4
                                baseline)]
                            (and
                              first-ok
                              stale-ok
                              invalid-ok
                              replacement-ok
                              close-ok
                              server-transfer-ok
                              (=
                                (sem_tests.compiler-semantic-source-index-live-owner-count)
                                baseline)))])))])))]))))

(define (lsp-compiler-diagnostic
  [fallback-path : String]
  [fallback-text : String]
  [diag : cdiag.CompilerDiagnostic]) : json.Json
  (let
    [span : cdiag.CompilerDiagnosticSpan
      (cdiag.compiler-diagnostic-primary-span diag)]
    [path : String (cdiag.compiler-diagnostic-span-path span)]
    [text : String
      (lsp.lsp-source-for-compiler-span
        fallback-path
        (owned_view.compiler-owned-shared-view fallback-text)
        span)]
    [labels : cdiag.CompilerDiagnosticLabelList
      (cdiag.compiler-diagnostic-secondary-spans diag)]
    [range : json.Json
      (lsp.lsp-range-from-compiler-span fallback-path fallback-text span)]
    [message : String (cdiag.compiler-diagnostic-message diag)]
    [code : String (cdiag.compiler-diagnostic-code-or-empty diag)]
    (if (= (cdiag.compiler-diagnostic-label-list-count labels) 0)
      (lsp.lsp-diagnostic-with-range range message code)
      (lsp.lsp-diagnostic-with-range-tail
        range
        code
        (lsp.lsp-json-member
          "relatedInformation"
          (lsp.lsp-json-array
            (lsp.lsp-diagnostic-related-information-list path text labels))
          (lsp.lsp-diagnostic-message-tail message))))))

(define (lsp-compiler-diagnostic-code-ok?
  [diag : cdiag.CompilerDiagnostic]
  [want : String]) : bool
  (match (let
    [value (lsp-compiler-diagnostic "" "" diag)]
    (lsp.lsp-json-string-field value "code"))
    [(Ok code) (string.eq code want)]
    [(Missing) false]))

(define (lsp-compiler-diagnostic-uncoded-ok? [diag : cdiag.CompilerDiagnostic]) : bool
  (match (let
    [value (lsp-compiler-diagnostic "" "" diag)]
    (lsp.lsp-json-string-field value "code"))
    [(Ok _) false]
    [(Missing) true]))

(cfg
  test
  (define (lsp-compiler-diagnostic-related-ok?) : bool
    (let
      [diag : cdiag.CompilerDiagnostic
        (cdiag.compiler-diagnostic-with-secondary
          (cdiag.compiler-diagnostic-with-code
            (cdiag.compiler-diagnostic-from-span
              "primary.tl"
              (token.SourceSpan 2 3 2 9)
              "wide primary")
            "E7777")
          (cdiag.CompilerDiagnosticSpan "" 4 5 4 8)
          (CompilerDiagnosticSomeString "borrow remains live"))]
      [source : String "\n  abcdefghij\n\n    abcdefghij"]
      [rendered : String
        (json.stringify (lsp-compiler-diagnostic "primary.tl" source diag))]
      [related-key : String "\"relatedInformation\""]
      [related-message : String "\"message\":\"borrow remains live\""]
      [related-uri-prefix : String "\"uri\":\"file:///"]
      [related-uri-suffix : String "/primary.tl\""]
      [primary-line : String "\"line\":1"]
      [primary-end : String "\"character\":8"]
      [secondary-line : String "\"line\":3"]
      [secondary-end : String "\"character\":7"]
      (and
        (string.contains (& rendered) (& related-key))
        (string.contains (& rendered) (& related-message))
        (string.contains (& rendered) (& related-uri-prefix))
        (string.contains (& rendered) (& related-uri-suffix))
        (string.contains (& rendered) (& primary-line))
        (string.contains (& rendered) (& primary-end))
        (string.contains (& rendered) (& secondary-line))
        (string.contains (& rendered) (& secondary-end))))))

(define (lsp-validate-forms-smoke-ok?) : bool
  (let
    [valid1 : bool (lsp.lsp-text-is-valid-forms "(define (foo) : i64 1)")]
    [valid2 : bool
      (lsp.lsp-text-is-valid-forms
        "(define (foo) : i64 1)\n(define (bar) : i64 2)")]
    [err1 : String (lsp.lsp-validate-forms-error "(define (foo) : i64 1")]
    [needle : String "unterminated"]
    (and
      valid1
      valid2
      (not (string.eq err1 ""))
      (string.contains (& err1) (& needle)))))

(define (lsp-validate-forms-line-context-ok?) : bool
  (match (lsp.lsp-validate-forms-result "(let [x : badtype] 1)")
    [(Valid) false]
    [(Invalid line col msg ctx)
      (and
        (= line 1)
        (= col 1)
        (not (string.eq msg ""))
        (not (string.eq ctx "")))]))

(define (lsp-diagnostic-metadata-smoke) : i64
  (let
    [parse-diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-code
        (cdiag.compiler-diagnostic-simple "parse.tl" 2 3 "missing paren")
        (cdiag.compiler-diagnostic-code-parse))]
    [typecheck-diag : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-code
        (cdiag.compiler-diagnostic-simple "type.tl" 4 5 "not assignable")
        (cdiag.compiler-diagnostic-code-typecheck))]
    [uncoded : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-simple
        "plain.tl"
        1
        1
        "typecheck: prefix text only")]
    (begin
      (unless
        (lsp-compiler-diagnostic-code-ok?
          parse-diag
          (cdiag.compiler-diagnostic-code-parse))
        (return 1))
      (unless
        (lsp-compiler-diagnostic-code-ok?
          typecheck-diag
          (cdiag.compiler-diagnostic-code-typecheck))
        (return 2))
      (unless (lsp-compiler-diagnostic-uncoded-ok? uncoded) (return 3))
      (cfg test (unless (lsp-compiler-diagnostic-related-ok?) (return 4)) unit)
      (unless (lsp-frame-session-cache-smoke-ok?) (return 5))
      (unless (lsp-definition-smoke-ok?) (return 6))
      (cfg test (unless (lsp-validate-forms-smoke-ok?) (return 7)) unit)
      (cfg test (unless (lsp-validate-forms-line-context-ok?) (return 8)) unit)
      (unless (lsp-documents-open-retention-smoke-ok?) (return 12))
      (unless (lsp-documents-check-cache-smoke-ok?) (return 13))
      (unless
        (lsp-typecheck-tool-session-preserves-program-cache-ok?)
        (return 14))
      42)))

(define (lsp-call-context-at-position
  [text : String]
  [line0 : i64]
  [char0 : i64]) : lsp.LspCallContextLookup
  (if (or (< line0 0) (< char0 0))
    Missing
    (lsp.lsp-call-context-at-offset
      (owned_view.compiler-owned-shared-view text)
      (lsp.lsp-offset-at-position text line0 char0))))

(define (lsp-call-context-is?
  [lookup : lsp.LspCallContextLookup]
  [form-start : i64]
  [head-start : i64]
  [head-end : i64]
  [active-argument : i64]) : bool
  (match lookup
    [(Found context)
      (and
        (= context.form-start form-start)
        (= context.head-start head-start)
        (= context.head-end head-end)
        (= context.active-argument active-argument))]
    [(Missing) false]))

(define (lsp-call-context-missing? [lookup : lsp.LspCallContextLookup]) : bool
  (match lookup
    [(Found _) false]
    [(Missing) true]))

(define (lsp-completion-context-kind-code [kind : lsp.LspCompletionContextKind]) : i64
  (match kind
    [(Value) 0]
    [(CallHead) 1]
    [(Type) 2]
    [(ImportPathOrItem) 3]
    [(ImportAlias) 4]
    [(DottedMember) 5]
    [(Field) 6]
    [(Suppressed) 7]))

(define (lsp-completion-context-is?
  [lookup : lsp.LspCompletionContextLookup]
  [kind : i64]
  [cursor-byte : i64]
  [replace-start : i64]
  [token-start : i64]
  [token : String]
  [prefix : String]
  [receiver : String]
  [head : String]
  [form-start : i64]
  [active-argument : i64]) : bool
  (match lookup
    [(Found context)
      (and
        (= (lsp-completion-context-kind-code context.kind) kind)
        (= context.cursor-byte cursor-byte)
        (= context.replace-start replace-start)
        (= context.replace-end cursor-byte)
        (= context.token-start token-start)
        (string.eq context.token token)
        (string.eq context.prefix prefix)
        (string.eq context.receiver receiver)
        (string.eq context.head head)
        (= context.form-start form-start)
        (= context.active-argument active-argument))]
    [(Missing) false]))

(define (lsp-completion-context-at-end-is?
  [text : String]
  [kind : i64]
  [replace-start : i64]
  [token-start : i64]
  [token : String]
  [prefix : String]
  [receiver : String]
  [head : String]
  [form-start : i64]
  [active-argument : i64]) : bool
  (let
    [cursor-byte : i64 (string.string-length text)]
    (lsp-completion-context-is?
      (lsp.lsp-completion-context-at-offset text cursor-byte)
      kind
      cursor-byte
      replace-start
      token-start
      token
      prefix
      receiver
      head
      form-start
      active-argument)))

(define (lsp-completion-context-missing?
  [lookup : lsp.LspCompletionContextLookup]) : bool
  (match lookup
    [(Found _) false]
    [(Missing) true]))

(test
  lsp-completion-context-basic
  (unless
    (and
      (lsp-completion-context-at-end-is? "" 0 0 0 "" "" "" "" -1 -1)
      (lsp-completion-context-at-end-is?
        "alpha"
        0
        0
        0
        "alpha"
        "alpha"
        ""
        ""
        -1
        -1)
      (lsp-completion-context-at-end-is? "(pri" 1 1 1 "pri" "pri" "" "pri" 0 0)
      (lsp-completion-context-at-end-is? "(:" 1 1 1 ":" ":" "" ":" 0 0)
      (lsp-completion-context-at-end-is? "(emit " 0 6 6 "" "" "" "emit" 0 0)
      (lsp-completion-context-at-end-is?
        "(outer [x y"
        0
        10
        10
        "y"
        "y"
        ""
        "outer"
        0
        0)
      (lsp-completion-context-at-end-is? ")))(sa" 1 4 4 "sa" "sa" "" "sa" 3 0)
      (lsp-completion-context-missing?
        (lsp.lsp-completion-context-at-offset "alpha" -1))
      (lsp-completion-context-missing?
        (lsp.lsp-completion-context-at-offset "alpha" 6)))
    (io.panic "lsp-completion-context-basic failed")))

(test
  lsp-completion-context-syntax
  (unless
    (and
      (lsp-completion-context-at-end-is?
        "(outer [x : i6"
        2
        12
        12
        "i6"
        "i6"
        ""
        "outer"
        0
        0)
      (lsp-completion-context-at-end-is?
        "(define (f) : i6"
        2
        14
        14
        "i6"
        "i6"
        ""
        "define"
        0
        2)
      (lsp-completion-context-at-end-is?
        "(define (f) : "
        2
        14
        14
        ""
        ""
        ""
        "define"
        0
        2)
      (lsp-completion-context-at-end-is?
        "(define (f) : (Pt"
        2
        15
        15
        "Pt"
        "Pt"
        ""
        "Pt"
        14
        0)
      (lsp-completion-context-at-end-is?
        "(import stdlib.io"
        3
        15
        8
        "stdlib.io"
        "io"
        "stdlib"
        "import"
        0
        0)
      (lsp-completion-context-at-end-is?
        "(import stdlib.io.*"
        3
        18
        8
        "stdlib.io.*"
        "*"
        "stdlib.io"
        "import"
        0
        0)
      (lsp-completion-context-at-end-is?
        "(import stdlib.io as al"
        4
        21
        21
        "al"
        "al"
        ""
        "import"
        0
        2)
      (lsp-completion-context-at-end-is? "(import " 3 8 8 "" "" "" "import" 0 0)
      (lsp-completion-context-at-end-is?
        "(use data.va"
        5
        10
        5
        "data.va"
        "va"
        "data"
        "use"
        0
        0)
      (lsp-completion-context-at-end-is?
        "(__tl_struct-get value fi"
        6
        23
        23
        "fi"
        "fi"
        ""
        "__tl_struct-get"
        0
        1)
      (lsp-completion-context-at-end-is?
        "(struct-set value fi"
        6
        18
        18
        "fi"
        "fi"
        ""
        "struct-set"
        0
        1))
    (io.panic "lsp-completion-context-syntax failed")))

(test
  lsp-completion-context-literals
  (unless
    (and
      (lsp-completion-context-at-end-is?
        "(outer ; tail"
        7
        13
        13
        ""
        ""
        ""
        "outer"
        0
        0)
      (lsp-completion-context-at-end-is?
        "(outer ; tail\n"
        0
        14
        14
        ""
        ""
        ""
        "outer"
        0
        0)
      (lsp-completion-context-at-end-is?
        "(outer \"ta"
        7
        10
        10
        ""
        ""
        ""
        "outer"
        0
        0)
      (lsp-completion-context-at-end-is?
        "(outer \"ta\" "
        0
        12
        12
        ""
        ""
        ""
        "outer"
        0
        1)
      (lsp-completion-context-at-end-is?
        "(outer \"x \\\" y"
        7
        14
        14
        ""
        ""
        ""
        "outer"
        0
        0)
      (lsp-completion-context-at-end-is?
        "(outer \"x \\\" y\" "
        0
        16
        16
        ""
        ""
        ""
        "outer"
        0
        1)
      (lsp-completion-context-at-end-is?
        "(outer \"tail\\"
        7
        13
        13
        ""
        ""
        ""
        "outer"
        0
        0)
      (lsp-completion-context-at-end-is?
        "(outer 'sym"
        7
        8
        8
        "sym"
        "sym"
        ""
        "outer"
        0
        0)
      (lsp-completion-context-at-end-is?
        "(outer '(sym"
        7
        9
        9
        "sym"
        "sym"
        ""
        "sym"
        8
        0)
      (lsp-completion-context-at-end-is?
        "(outer '(sym) "
        0
        14
        14
        ""
        ""
        ""
        "outer"
        0
        1)
      (lsp-completion-context-at-end-is?
        "(outer ')' "
        0
        11
        11
        ""
        ""
        ""
        "outer"
        0
        1)
      (lsp-completion-context-at-end-is?
        "(outer `(sym ,value"
        7
        14
        14
        "value"
        "value"
        ""
        "sym"
        8
        0)
      (lsp-completion-context-at-end-is?
        "(outer [x ))"
        0
        12
        12
        ""
        ""
        ""
        ""
        -1
        -1))
    (io.panic "lsp-completion-context-literals failed")))

(test
  lsp-completion-context-position
  (unless
    (let
      [unicode : String "😀 (fo"]
      [crlf : String "x\r\n(fo"]
      [utf16-ok : bool false]
      [utf8-ok : bool false]
      [middle-missing : bool false]
      [crlf-ok : bool false]
      (lsp.lsp-position-encoding-use-utf16!)
      (set!
        utf16-ok
        (lsp-completion-context-is?
          (lsp.lsp-completion-context-at-position
            (owned_view.compiler-owned-shared-view unicode)
            0
            6)
          1
          8
          6
          6
          "fo"
          "fo"
          ""
          "fo"
          5
          0))
      (set!
        middle-missing
        (and
          (lsp-completion-context-missing?
            (lsp.lsp-completion-context-at-position
              (owned_view.compiler-owned-shared-view unicode)
              0
              1))
          (lsp-completion-context-missing?
            (lsp.lsp-completion-context-at-position
              (owned_view.compiler-owned-shared-view unicode)
              0
              7))
          (lsp-completion-context-missing?
            (lsp.lsp-completion-context-at-position
              (owned_view.compiler-owned-shared-view unicode)
              1
              0))))
      (set!
        crlf-ok
        (lsp-completion-context-is?
          (lsp.lsp-completion-context-at-position crlf 1 3)
          1
          6
          4
          4
          "fo"
          "fo"
          ""
          "fo"
          3
          0))
      (lsp.lsp-position-encoding-use-utf8!)
      (set!
        utf8-ok
        (lsp-completion-context-is?
          (lsp.lsp-completion-context-at-position unicode 0 8)
          1
          8
          6
          6
          "fo"
          "fo"
          ""
          "fo"
          5
          0))
      (lsp.lsp-position-encoding-use-utf16!)
      (and utf16-ok utf8-ok middle-missing crlf-ok))
    (io.panic "lsp-completion-context-position failed")))

(test
  lsp-call-context-boundaries
  (unless
    (and
      (lsp-call-context-is? (lsp.lsp-call-context-at-offset "(zero)" 5) 0 1 5 0)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(one value)" 10)
        0
        1
        4
        0)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(one value )" 11)
        0
        1
        4
        1)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(many a b c)" 11)
        0
        1
        5
        2)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(many a b c )" 12)
        0
        1
        5
        3)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(define (f) : (Ptr i64) " 24)
        0
        1
        7
        3)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(head tail)" 5)
        0
        1
        5
        0)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(head tail)" 6)
        0
        1
        5
        0)
      (lsp-call-context-missing?
        (lsp.lsp-call-context-at-offset "(head tail)" 4))
      (lsp-call-context-missing?
        (lsp.lsp-call-context-at-offset "(head tail)" 11))
      (lsp-call-context-missing?
        (lsp.lsp-call-context-at-offset "(head tail)" -1))
      (lsp-call-context-missing?
        (lsp.lsp-call-context-at-offset "(head tail)" 12)))
    (io.panic "lsp-call-context-boundaries failed")))

(test
  lsp-call-context-nesting
  (unless
    (and
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer (inner x " 16)
        7
        8
        13
        1)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer [x y " 12)
        0
        1
        6
        0)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer (inner x))" 16)
        0
        1
        6
        0)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer (inner x) " 17)
        0
        1
        6
        1)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(multi\n first\n second " 22)
        0
        1
        6
        2))
    (io.panic "lsp-call-context-nesting failed")))

(test
  lsp-call-context-lexical-and-malformed
  (unless
    (and
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer \"x ) \\\" y\" next " 23)
        0
        1
        6
        2)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer \"line\n) still\" next " 27)
        0
        1
        6
        2)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer first ; ) ]\n second " 27)
        0
        1
        6
        2)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer '(' ')' '[' ']' " 23)
        0
        1
        6
        4)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer 'x `(inner y) ,z ,@w " 28)
        0
        1
        6
        4)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer a ' " 11)
        0
        1
        6
        1)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer a 'x " 12)
        0
        1
        6
        2)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer [x]tail" 14)
        0
        1
        6
        1)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer \"tail\\" 13)
        0
        1
        6
        0)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer x ; ]" 12)
        0
        1
        6
        1)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset "(outer first ] (later x " 24)
        15
        16
        21
        1)
      (lsp-call-context-is?
        (lsp.lsp-call-context-at-offset ")))(safe x " 11)
        3
        4
        8
        1)
      (lsp-call-context-missing?
        (lsp.lsp-call-context-at-offset "(outer [x ))" 12)))
    (io.panic "lsp-call-context-lexical-and-malformed failed")))

(define (lsp-definition-smoke-ok?) : bool
  (and
    (= (sem.compiler-semantic-source-utf16-col-at-offset "λ€𝄞foo" 9) 5)
    (= (sem.compiler-semantic-source-utf16-col-at-offset "λ€𝄞foo" 12) 8)
    (not (lsp.lsp-symbol-in-quoted-data? "(if true false)" 1))
    (lsp.lsp-symbol-in-quoted-data? "(quote if)" 7)
    (lsp.lsp-symbol-in-quoted-data? "(quote (if true false))" 8)
    (lsp.lsp-symbol-in-quoted-data? "'if" 1)
    (lsp.lsp-symbol-in-quoted-data? "`if" 1)))

(test
  lsp.lsp-signature-type-components
  (unless
    (let
      [parts : lsp_svec.Vec
        (lsp.lsp-signature-type-components
          "(-> i64 (Tuple i64 bool) (-> bool bool) unit)")]
      [zero : lsp_svec.Vec (lsp.lsp-signature-type-components "(-> i64)")]
      [plain : lsp_svec.Vec (lsp.lsp-signature-type-components "i64")]
      [unbalanced : lsp_svec.Vec
        (lsp.lsp-signature-type-components "(-> (Tuple i64 bool i64)")]
      (and
        (= (lsp_svec.len (& parts)) 4)
        (string.eq (lsp_svec.get (& parts) 0 "") "i64")
        (string.eq (lsp_svec.get (& parts) 1 "") "(Tuple i64 bool)")
        (string.eq (lsp_svec.get (& parts) 2 "") "(-> bool bool)")
        (string.eq (lsp_svec.get (& parts) 3 "") "unit")
        (= (lsp_svec.len (& zero)) 1)
        (string.eq (lsp_svec.get (& zero) 0 "") "i64")
        (= (lsp_svec.len (& plain)) 0)
        (= (lsp_svec.len (& unbalanced)) 0)))
    (io.panic "lsp-signature-type-components failed")))

(test
  lsp-signature-label-offsets
  (unless
    (let
      [labels : lsp_svec.Vec (lsp_svec.new)]
      (lsp_svec.push-ref! (&mut labels) "[λ : i64]")
      (lsp_svec.push-ref! (&mut labels) "(Tuple i64 bool)")
      (let
        [rendered : String
          (json.stringify
            (lsp.lsp-json-array
              (lsp.lsp-signature-parameter-information-list
                (& labels)
                0
                (lsp.lsp-signature-utf16-length "(λ-call"))))]
        (string.eq rendered "[{\"label\":[8,17]},{\"label\":[18,34]}]")))
    (io.panic "lsp-signature-label-offsets failed")))

(test
  lsp-signature-active-parameter
  (unless
    (let
      [index : sem.CompilerSemanticSourceIndex
        (sem.compiler-semantic-source-index-empty)]
      [definition : sem.CompilerSemanticRecord
        (sem.compiler-semantic-record-fallback)]
      [two : lsp_svec.Vec (lsp_svec.new)]
      [zero : lsp_svec.Vec (lsp_svec.new)]
      (lsp_svec.push-ref! (&mut two) "i64")
      (lsp_svec.push-ref! (&mut two) "bool")
      (lsp_svec.push-ref! (&mut two) "unit")
      (lsp_svec.push-ref! (&mut zero) "i64")
      (let
        [active : String
          (json.stringify
            (lsp.lsp-signature-help-result
              (& index)
              "(call"
              (lsp.LspCallContext 0 1 5 1)
              (lsp.lsp-global-shared-view definition)
              (& two)))]
        [excess : String
          (json.stringify
            (lsp.lsp-signature-help-result
              (& index)
              "(call"
              (lsp.LspCallContext 0 1 5 2)
              (lsp.lsp-global-shared-view definition)
              (& two)))]
        [empty : String
          (json.stringify
            (lsp.lsp-signature-help-result
              (& index)
              "(zero"
              (lsp.LspCallContext 0 1 5 0)
              definition
              (& zero)))]
        [active-needle : String "\"activeParameter\":1"]
        [field-needle : String "activeParameter"]
        (and
          (string.contains (& active) (& active-needle))
          (not (string.contains (& excess) (& field-needle)))
          (not (string.contains (& empty) (& field-needle))))))
    (io.panic "lsp-signature-active-parameter failed")))

(test
  lsp-signature-capability
  (unless
    (let
      [rendered : String (json.stringify (lsp.lsp-initialize-result))]
      [expected : String
        "\"signatureHelpProvider\":{\"triggerCharacters\":[\" \"],\"retriggerCharacters\":[\")\"]}"]
      (string.contains (& rendered) (& expected)))
    (io.panic "lsp-signature-capability failed")))

(define (lsp-completion-test-candidate
  [label : String]
  [match-rank : i64]
  [source-rank : i64]
  [namespace-rank : i64]
  [stable-key : String]) : lsp.LspCompletionCandidate
  (let
    [insert-text : String (string.copy (& label))]
    (lsp.LspCompletionCandidate
      match-rank
      source-rank
      namespace-rank
      6
      label
      ""
      ""
      ""
      ""
      0
      0
      stable-key
      insert-text)))

(define (lsp-completion-provider-smoke-ok?) : bool
  (let
    [ordered : lsp.LspCompletionResults (lsp.lsp-completion-results-new)]
    [capped : lsp.LspCompletionResults (lsp.lsp-completion-results-new)]
    (lsp.lsp-completion-results-insert!
      (&mut ordered)
      (lsp-completion-test-candidate "beta" 1 1 0 "beta"))
    (lsp.lsp-completion-results-insert!
      (&mut ordered)
      (lsp-completion-test-candidate "alpha" 1 2 0 "alpha-import"))
    (lsp.lsp-completion-results-insert!
      (&mut ordered)
      (lsp-completion-test-candidate "alpha" 1 0 0 "alpha-local"))
    ;; A repeated stable semantic identity never produces another item.
    (lsp.lsp-completion-results-insert!
      (&mut ordered)
      (lsp-completion-test-candidate "duplicate-label" 0 0 0 "alpha-local"))
    (for [index (iterator.range 0 (+ lsp.lsp-completion-result-limit 1))]
      (lsp.lsp-completion-results-insert!
        (&mut capped)
        (lsp-completion-test-candidate
          (lsp.lsp-str3 "item-" (string.int->string index) "")
          1
          4
          0
          (lsp.lsp-str3 "cap-" (string.int->string index) ""))))
    (and
      (= ordered.len 3)
      (string.eq
        (lsp.lsp-completion-results-get (& ordered) 0).stable-key
        "alpha-local")
      (string.eq
        (lsp.lsp-completion-results-get (& ordered) 1).stable-key
        "beta")
      (string.eq
        (lsp.lsp-completion-results-get (& ordered) 2).stable-key
        "alpha-import")
      (= capped.len lsp.lsp-completion-result-limit)
      capped.incomplete
      (string.eq
        (lsp.lsp-completion-module-next-segment "stdlib.string" "")
        "stdlib")
      (string.eq
        (lsp.lsp-completion-module-next-segment "stdlib.string" "stdlib")
        "string")
      (string.eq
        (lsp.lsp-completion-module-next-segment
          "compiler.parse.core"
          "compiler")
        "parse")
      (string.eq
        (lsp.lsp-completion-module-next-segment "stdlib.string" "compiler")
        "")
      (string.eq
        (lsp.lsp-completion-rendered-type-owner-name "app.main/AB")
        "app.main/AB")
      (string.eq
        (lsp.lsp-completion-rendered-type-owner-name "(& app.main/AB)")
        "app.main/AB")
      (string.eq
        (lsp.lsp-completion-rendered-type-owner-name "(& lifetime app.main/AB)")
        "app.main/AB")
      (string.eq
        (lsp.lsp-completion-rendered-type-owner-name
          "(Region phase (& lifetime (app.main/RefBox lifetime)))")
        "app.main/RefBox"))))

(test
  lsp-completion-provider-ranking-dedup-cap
  (unless
    (lsp-completion-provider-smoke-ok?)
    (io.panic "lsp-completion-provider-ranking-dedup-cap failed")))

(test
  lsp-rename-module-move-probe
  (unless
    (and
      (match (lsp.lsp-rename-module-move-from-probe
        "/workspace/old.tl"
        "/outside/new.tl"
        false
        (OkIoBool false))
        [(Err message)
          (string.eq
            message
            "Renamed module path would leave the editable workspace")]
        [(Ok _) false])
      (match (lsp.lsp-rename-module-move-from-probe
        "/workspace/old.tl"
        "/workspace/new.tl"
        true
        (ErrIoBool (IoInvalidPath "/workspace/new.tl")))
        [(Err message)
          (string.eq message "Cannot validate the renamed module destination")]
        [(Ok _) false])
      (match (lsp.lsp-rename-module-move-from-probe
        "/workspace/old.tl"
        "/workspace/new.tl"
        true
        (OkIoBool true))
        [(Err message)
          (string.eq message "Renamed module source path already exists")]
        [(Ok _) false])
      (match (lsp.lsp-rename-module-move-from-probe
        "/workspace/old.tl"
        "/workspace/new.tl"
        true
        (OkIoBool false))
        [(Ok move)
          (match move
            [(Found old-path new-path)
              (and
                (string.eq old-path "/workspace/old.tl")
                (string.eq new-path "/workspace/new.tl"))]
            [(Missing) false])]
        [(Err _) false]))
    (io.panic "lsp-rename-module-move-probe failed")))

(test
  lsp-rename-module-move-append
  (unless
    (let
      [missing-changes : json.JsonSeq
        (lsp.lsp-rename-append-module-move
          (lsp.lsp-json-list-cons
            (lsp.lsp-json-object1 "kind" (JsonString "text"))
            (json.list-empty))
          Missing)]
      [found-changes : json.JsonSeq
        (lsp.lsp-rename-append-module-move
          (lsp.lsp-json-list-cons
            (lsp.lsp-json-object1 "kind" (JsonString "text"))
            (json.list-empty))
          (Found "/old.tl" "/new.tl"))]
      [missing-count : i64
        (json.list-count (lsp.lsp-global-shared-view missing-changes))]
      [found-count : i64
        (json.list-count (lsp.lsp-global-shared-view found-changes))]
      [missing-rendered : String
        (json.stringify (lsp.lsp-json-array missing-changes))]
      [found-rendered : String
        (json.stringify (lsp.lsp-json-array found-changes))]
      (and
        (= missing-count 1)
        (= found-count 2)
        (string.eq missing-rendered "[{\"kind\":\"text\"}]")
        (string.eq
          found-rendered
          "[{\"kind\":\"text\"},{\"kind\":\"rename\",\"oldUri\":\"file:///old.tl\",\"newUri\":\"file:///new.tl\"}]")))
    (io.panic "lsp-rename-module-move-append failed")))

(define (lsp-workspace-index-declaration-count
  [index : (& index lvf.LspWorkspaceIndex)]) : i64
  (let
    [count : i64 0]
    (for [source-index
      (iterator.range 0 (lsp.lsp-workspace-sources-len (& index.sources)))]
      (let
        [source : lvf.LspWorkspaceSource
          (lsp.lsp-workspace-sources-get (& index.sources) source-index)]
        (+= count (lsp_decl_vec.len (& source.decls)))))
    count))

(define (lsp-workspace-index-declaration-at
  [index : (& index lvf.LspWorkspaceIndex)]
  [wanted : i64]) : lvf.LspWorkspaceDeclLookup
  (if (< wanted 0)
    Missing
    (let
      [source-index : i64 0]
      [offset : i64 wanted]
      [result : lvf.LspWorkspaceDeclLookup Missing]
      [done : bool false]
      (while (and
        (< source-index (lsp.lsp-workspace-sources-len (& index.sources)))
        (not done))
        (let
          [source : lvf.LspWorkspaceSource
            (lsp.lsp-workspace-sources-get (& index.sources) source-index)]
          [decls : lsp_decl_vec.Vec source.decls]
          [count : i64 (lsp_decl_vec.len (& decls))]
          (if (< offset count)
            (begin
              (set!
                result
                (Found
                  (lvf.LspWorkspaceDeclRow
                    source.root-uri
                    source.root-path
                    source.uri
                    source.path
                    source.module
                    source.explicit-module
                    source.overlay
                    (lsp_decl_vec.get
                      (& decls)
                      offset
                      (lsp.lsp-decl-entry-fallback)))))
              (set! done true))
            (begin
              (-= offset count)
              (+= source-index 1)))))
      result)))

(define (lsp-server-state-declaration-count
  [state : (& state lvf.LspServerState)]) : i64
  (lsp-workspace-index-declaration-count (& state.workspace)))

(define (lsp-server-state-declaration-at
  [state : (& state lvf.LspServerState)]
  [index : i64]) : lvf.LspWorkspaceDeclLookup
  (lsp-workspace-index-declaration-at (& state.workspace) index))

(define (lsp-document-symbols-for-text [text : String]) : json.Json
  (lsp.lsp-document-symbols-json (lsp.lsp-scan-decls text)))

(define (lsp-typecheck-tool-session-preserves-program-cache-ok?) : bool
  (compiler_load.compiler-load-session-cache-disable-for-test!)
  (compiler_load.compiler-load-session-cache-enable!)
  (compiler_load.compiler-load-session-program-cache-enable!)
  (lsp.lsp-typecheck-tool-session-before!)
  (lsp.lsp-typecheck-tool-session-after!)
  (let
    [enabled-ok : bool
      (compiler_load.compiler-load-session-program-cache-enabled?)]
    (compiler_load.compiler-load-session-program-cache-disable!)
    (lsp.lsp-typecheck-tool-session-before!)
    (lsp.lsp-typecheck-tool-session-after!)
    (let
      [disabled-ok : bool
        (not (compiler_load.compiler-load-session-program-cache-enabled?))]
      (compiler_load.compiler-load-session-cache-disable-for-test!)
      (and enabled-ok disabled-ok))))

(define (lsp-frame-session-cache-smoke-ok?) : bool
  (compiler_load.compiler-load-session-cache-disable-for-test!)
  (lsp.lsp-frame-session-cache-enable!)
  (let
    [ok : bool (compiler_load.compiler-load-session-cache-enabled?)]
    (compiler_load.compiler-load-session-cache-disable-for-test!)
    ok))

(test
  lsp-patch-text-smoke
  (unless
    (let
      [text : String "(define (foo) : i64 1)"]
      (match (lsp.lsp-patch-text text "1" "2")
        [(Ok replaced) (string.eq replaced "(define (foo) : i64 2)")]
        [(Err _) false]))
    (io.panic "lsp-patch-text-smoke failed")))

(test
  lsp-patch-text-duplicate
  (unless
    (let
      [text : String "(define (foo) : i64 1)\n(define (bar) : i64 1)"]
      [needle : String "more than once"]
      (match (lsp.lsp-patch-text text "1" "2")
        [(Ok _) false]
        [(Err message) (string.contains (& message) (& needle))]))
    (io.panic "lsp-patch-text-duplicate failed")))

(test
  lsp-patch-text-invalid
  (unless
    (let
      [text : String "(define (foo) : i64 1)"]
      [needle : String "invalid form"]
      (match (lsp.lsp-patch-text text "1)" "1")
        [(Ok _) false]
        [(Err message) (string.contains (& message) (& needle))]))
    (io.panic "lsp-patch-text-invalid failed")))

(test
  lsp-patch-text-first-byte-collisions
  (unless
    (let
      [text : String "(define (aaaaa) : i64 1)\n(define (abc) : i64 2)"]
      [expected : String "(define (aaaaa) : i64 1)\n(define (renamed) : i64 2)"]
      (match (lsp.lsp-patch-text text "abc" "renamed")
        [(Ok replaced) (string.eq replaced expected)]
        [(Err _) false]))
    (io.panic "lsp-patch-text-first-byte-collisions failed")))

(test
  lsp-diagnostic-uris-dense
  (unless
    (let
      [empty : lvf.LspDiagnosticUris (lsp.lsp-diagnostic-uris-empty)]
      [one : lvf.LspDiagnosticUris
        (lsp.lsp-diagnostic-uris-add
          (owned_view.compiler-owned-shared-view empty)
          "one")]
      [duplicate : lvf.LspDiagnosticUris
        (lsp.lsp-diagnostic-uris-add
          (owned_view.compiler-owned-shared-view one)
          "one")]
      [two : lvf.LspDiagnosticUris
        (lsp.lsp-diagnostic-uris-add
          (owned_view.compiler-owned-shared-view duplicate)
          "two")]
      [many0 : lvf.LspDiagnosticUris (lsp.lsp-diagnostic-uris-add two "three")]
      [many1 : lvf.LspDiagnosticUris (lsp.lsp-diagnostic-uris-add many0 "four")]
      [many : lvf.LspDiagnosticUris (lsp.lsp-diagnostic-uris-add many1 "five")]
      (and
        (= (lsp.lsp-diagnostic-uris-len empty) 0)
        (= (lsp.lsp-diagnostic-uris-len one) 1)
        (= (lsp.lsp-diagnostic-uris-len duplicate) 1)
        (= (lsp.lsp-diagnostic-uris-len many) 5)
        (lsp.lsp-diagnostic-uris-contains?
          (owned_view.compiler-owned-shared-view many)
          "one")
        (lsp.lsp-diagnostic-uris-contains?
          (owned_view.compiler-owned-shared-view many)
          "five")
        (not
          (lsp.lsp-diagnostic-uris-contains?
            (owned_view.compiler-owned-shared-view many)
            "missing"))
        (string.eq
          (lsp.lsp-diagnostic-uris-get
            (owned_view.compiler-owned-shared-view many)
            0)
          "one")
        (string.eq (lsp.lsp-diagnostic-uris-get many 4) "five")))
    (io.panic "lsp diagnostic URI empty/one/many/duplicate smoke failed")))

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
  lsp-documents-open-retention
  (unless
    (lsp-documents-open-retention-smoke-ok?)
    (io.panic "lsp-documents-open-retention failed")))

(test
  lsp-semantic-snapshot-lifecycle
  (unless
    (lsp-semantic-snapshot-lifecycle-smoke-ok?)
    (io.panic "lsp-semantic-snapshot-lifecycle failed")))

(test
  lsp-declaration-context-smoke
  (unless
    (let
      [text : String
        "(define (n00) : i64 0)\n(define (n01) : i64 1)\n(define (n02) : i64 2)\n(define (n03) : i64 3)\n(define (n04) : i64 4)\n(define (n05) : i64 5)\n(define (n06) : i64 6)\n(define (n07) : i64 7)\n(define (n08) : i64 8)\n(define (n09) : i64 9)\n(define (n10) : i64 10)\n(define (n11) : i64 11)\n(define (n12) : i64 12)\n(define (n13) : i64 13)\n(define (n14) : i64 14)\n(define (n15) : i64 15)\n(define (n16) : i64 16)\n(define (n17) : i64 17)\n(define (n18) : i64 18)\n(define (n19) : i64 19)\n(define (n20) : i64 20)\n(define (n21) : i64 21)\n(define (n22) : i64 22)\n(define (n23) : i64 23)\n(define (n24) : i64 24)\n(define (n25) : i64 25)\n(define (n26) : i64 26)\n(define (n27) : i64 27)\n(define (n28) : i64 28)\n(define (n29) : i64 29)\n(define (n30) : i64 30)\n(define (n31) : i64 31)\n(define (n32) : i64 32)\n(define (n33) : i64 33)\n"]
      [decls : lsp_decl_vec.Vec (lsp.lsp-scan-decls text)]
      [context-text : String
        (json.stringify (lsp.lsp-declaration-context-json decls "n3x"))]
      [all-name-count-fragment : String "\"allNameCount\":34"]
      [truncated-fragment : String "\"allNamesTruncated\":true"]
      [limit-fragment : String "\"allNameLimit\":32"]
      [similar-fragment : String "\"similarNames\":[\"n30\""]
      (and
        (lsp.lsp-decl-name-similar? "foz" "foo")
        (not (lsp.lsp-decl-name-similar? "zzz" "foo"))
        (string.contains (& context-text) (& all-name-count-fragment))
        (string.contains (& context-text) (& truncated-fragment))
        (string.contains (& context-text) (& limit-fragment))
        (string.contains (& context-text) (& similar-fragment))))
    (io.panic "lsp-declaration-context-smoke failed")))

;; Find start of the top-level form containing offset.
;; Scans forward tracking depth; a '(' at depth 0 is a top-level form.
;; Returns -1 if offset is not inside any top-level form.
(define (lsp-find-top-level-form-at-offset [text : (& text str)] [offset : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    (if (or (< offset 0) (>= offset n))
      -1
      (let
        [i : i64 0]
        [depth : i64 0]
        [current-start : i64 -1]
        [result : i64 -1]
        (while (and (< i n) (= result -1))
          (let
            [c : char (string.string-ref text i)]
            (if (= c (string.string-ref "(" 0))
              (begin
                (if (= depth 0)
                  (set! current-start i)
                  unit)
                (+= depth 1))
              (if (= c (string.string-ref ")" 0))
                (when
                  (> depth 0)
                  (-= depth 1)
                  (if (= depth 0)
                    (if (and (>= offset current-start) (<= offset i))
                      (set! result current-start)
                      unit)
                    unit))
                unit))
            (+= i 1)))
        result))))

(define (lsp-replace-form-at-position
  [text : String]
  [line : i64]
  [col : i64]
  [new-text : String]) : lsp.LspEditResult
  (lsp.lsp-replace-form-at-position-with-decls
    (owned_view.compiler-owned-shared-view text)
    (lsp.lsp-scan-decls text)
    line
    col
    new-text))

(define (lsp-is-whitespace [c : char]) : bool
  (source_text.source-text-space? c))

;; Helper: Extract function name from a define or defmacro form.
(define (lsp-extract-define-name [text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    (when (= n 0) (return ""))
    (let
      [open : i64 (source_text.source-text-skip-space text 0 n)]
      (when
        (or
          (>= open n)
          (not (= (string.string-ref text open) (string.string-ref "(" 0))))
        (return ""))
      (let
        [kw-start : i64 (source_text.source-text-skip-space text (+ open 1) n)]
        [kw-end : i64 0]
        [kw : String ""]
        (set! kw-end (lsp.lsp-scan-ident text kw-start n))
        (when (= kw-end kw-start) (return ""))
        (set! kw (string.substring text kw-start (- kw-end kw-start)))
        (when
          (not (or (string.eq kw "define") (string.eq kw "defmacro")))
          (return ""))
        (let
          [name-start : i64 (source_text.source-text-skip-space text kw-end n)]
          (when (>= name-start n) (return ""))
          (if (= (string.string-ref text name-start) (string.string-ref "(" 0))
            (set!
              name-start
              (source_text.source-text-skip-space text (+ name-start 1) n))
            unit)
          (let
            [name-end : i64 (lsp.lsp-scan-ident text name-start n)]
            (if (= name-end name-start)
              ""
              (string.substring text name-start (- name-end name-start)))))))))

;; Helper: Search outward from a position to find a define/defmacro form and extract its name.
(define (lsp-find-define-name-outward [text : String] [search-offset : i64]) : String
  (if (< search-offset 0)
    ""
    (let
      [form-start : i64
        (lsp.lsp-find-form-at-offset
          (owned_view.compiler-owned-shared-view text)
          search-offset)]
      (if (= form-start -1)
        ""
        (let
          [form-end : i64
            (lsp.lsp-find-form-end-at-offset
              (owned_view.compiler-owned-shared-view text)
              form-start)]
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
      [offset : i64 (lsp.lsp-offset-at-position text line col)]
      (if (>= offset (string.string-length text))
        ""
        (lsp-find-define-name-outward text offset)))))

(define (lsp-test-scan-decls [text : (& text str)]) : lsp_decl_vec.Vec
  (let
    [copy : String (string.copy text)]
    (lsp.lsp-scan-decls copy)))

(define (lsp-test-path1 [a : String]) : json.JsonSeq
  (lsp.lsp-json-list-cons (JsonString a) (json.list-empty)))

(define (lsp-test-path3 [a : String] [b : String] [c : String]) : json.JsonSeq
  (lsp.lsp-json-list-cons
    (JsonString a)
    (lsp.lsp-json-list-cons
      (JsonString b)
      (lsp.lsp-json-list-cons (JsonString c) (json.list-empty)))))

(define (lsp-test-path4 [a : String] [b : String] [c : String] [d : String]) : json.JsonSeq
  (lsp.lsp-json-list-cons
    (JsonString a)
    (lsp.lsp-json-list-cons
      (JsonString b)
      (lsp.lsp-json-list-cons
        (JsonString c)
        (lsp.lsp-json-list-cons (JsonString d) (json.list-empty))))))

(define (lsp-nested-path-test-text) : String
  "(define (foo [x : i64]) : i64
  (let [value : i64 1]
    (match x
      [(Ok value) value]
      [_ value])))")

(define (lsp-workspace-symbol-test-decl [name : String] [line : i64]) : lvf.LspDeclEntry
  (let
    [name-length : i64 (string.string-length name)]
    (lvf.LspDeclEntry
      "function"
      name
      line
      2
      name-length
      line
      1
      line
      (+ name-length 2)
      12)))

(define (lsp-workspace-symbol-test-source
  [uri : String]
  [module : String]
  [decls : lsp_decl_vec.Vec]) : lvf.LspWorkspaceSource
  (lvf.LspWorkspaceSource
    "file:///workspace"
    "/workspace"
    (string.copy (& uri))
    uri
    module
    true
    false
    decls))

(define (lsp-workspace-symbol-test-candidate-name
  [results : (& results lsp.LspWorkspaceSymbolResults)]
  [index : i64]) : String
  (let
    [candidate : lsp.LspWorkspaceSymbolCandidate
      (lsp.lsp-workspace-symbol-results-get results index)]
    (string.copy (& candidate.row.decl.name))))

(define (lsp-workspace-symbol-test-candidate-module
  [results : (& results lsp.LspWorkspaceSymbolResults)]
  [index : i64]) : String
  (let
    [candidate : lsp.LspWorkspaceSymbolCandidate
      (lsp.lsp-workspace-symbol-results-get results index)]
    (string.copy (& candidate.row.module))))

(define (lsp-workspace-symbol-test-candidate-line
  [results : (& results lsp.LspWorkspaceSymbolResults)]
  [index : i64]) : i64
  (let
    [candidate : lsp.LspWorkspaceSymbolCandidate
      (lsp.lsp-workspace-symbol-results-get results index)]
    candidate.row.decl.name-line))

(test
  lsp-workspace-symbol-ranking
  (unless
    (let
      [z-decls : lsp_decl_vec.Vec (lsp_decl_vec.new)]
      [a-decls : lsp_decl_vec.Vec (lsp_decl_vec.new)]
      [sources : lvf.LspWorkspaceSources (lsp.lsp-workspace-sources-new)]
      ;; Deliberately insert in the reverse of the required result order.
      (lsp_decl_vec.push-ref!
        (&mut z-decls)
        (lsp-workspace-symbol-test-decl "mytarget" 4))
      (lsp_decl_vec.push-ref!
        (&mut z-decls)
        (lsp-workspace-symbol-test-decl "targetPrefix" 3))
      (lsp_decl_vec.push-ref!
        (&mut z-decls)
        (lsp-workspace-symbol-test-decl "target" 2))
      (lsp_decl_vec.push-ref!
        (&mut z-decls)
        (lsp-workspace-symbol-test-decl "Target" 1))
      (lsp_decl_vec.push-ref!
        (&mut a-decls)
        (lsp-workspace-symbol-test-decl "target" 5))
      (lsp.lsp-workspace-sources-push!
        (&mut sources)
        (lsp-workspace-symbol-test-source "file:///z.tl" "z.module" z-decls))
      (lsp.lsp-workspace-sources-push!
        (&mut sources)
        (lsp-workspace-symbol-test-source "file:///a.tl" "a.module" a-decls))
      (let
        [workspace : lvf.LspWorkspaceIndex
          (lvf.LspWorkspaceIndex (lsp.lsp-workspace-roots-new) sources)]
        [ranked : lsp.LspWorkspaceSymbolResults
          (lsp.lsp-workspace-symbol-query (& workspace) "target")]
        [all : lsp.LspWorkspaceSymbolResults
          (lsp.lsp-workspace-symbol-query (& workspace) "")]
        [rendered : String
          (json.stringify
            (lsp.lsp-workspace-symbol-result-json (& workspace) "target"))]
        [exact-rendered : String
          (json.stringify
            (lsp.lsp-project-search-result-json (& workspace) "target"))]
        [prefix-needle : String "targetPrefix"]
        [substring-needle : String "mytarget"]
        [location-needle : String "\"location\":{\"uri\":\"file:///a.tl\""]
        [container-needle : String "\"containerName\":\"a.module\""]
        (and
          (= (lsp.lsp-workspace-symbol-results-len (& ranked)) 4)
          (string.eq
            (lsp-workspace-symbol-test-candidate-name (& ranked) 0)
            "target")
          (string.eq
            (lsp-workspace-symbol-test-candidate-module (& ranked) 0)
            "a.module")
          (string.eq
            (lsp-workspace-symbol-test-candidate-name (& ranked) 1)
            "target")
          (string.eq
            (lsp-workspace-symbol-test-candidate-module (& ranked) 1)
            "z.module")
          (string.eq
            (lsp-workspace-symbol-test-candidate-name (& ranked) 2)
            "targetPrefix")
          (string.eq
            (lsp-workspace-symbol-test-candidate-name (& ranked) 3)
            "mytarget")
          (= (lsp.lsp-workspace-symbol-results-len (& all)) 5)
          (string.eq
            (lsp-workspace-symbol-test-candidate-name (& all) 0)
            "Target")
          (string.contains (& rendered) (& location-needle))
          (string.contains (& rendered) (& container-needle))
          (not (string.contains (& exact-rendered) (& prefix-needle)))
          (not (string.contains (& exact-rendered) (& substring-needle))))))
    (io.panic "lsp-workspace-symbol-ranking failed")))

(test
  lsp-workspace-symbol-cap-dedup
  (unless
    (let
      [decls : lsp_decl_vec.Vec (lsp_decl_vec.with-capacity 301)]
      (for [index (iterator.range 0 300)]
        (lsp_decl_vec.push-ref!
          (&mut decls)
          (lsp-workspace-symbol-test-decl "same" (+ index 1))))
      ;; Exact duplicate source identities collapse to one result.
      (lsp_decl_vec.push-ref!
        (&mut decls)
        (lsp-workspace-symbol-test-decl "same" 1))
      (let
        [sources : lvf.LspWorkspaceSources (lsp.lsp-workspace-sources-new)]
        (lsp.lsp-workspace-sources-push!
          (&mut sources)
          (lsp-workspace-symbol-test-source "file:///many.tl" "many" decls))
        (let
          [workspace : lvf.LspWorkspaceIndex
            (lvf.LspWorkspaceIndex (lsp.lsp-workspace-roots-new) sources)]
          [results : lsp.LspWorkspaceSymbolResults
            (lsp.lsp-workspace-symbol-query (& workspace) "same")]
          (and
            (=
              (lsp.lsp-workspace-symbol-results-len (& results))
              lsp.lsp-workspace-symbol-result-limit)
            (= (lsp-workspace-symbol-test-candidate-line (& results) 0) 1)
            (= (lsp-workspace-symbol-test-candidate-line (& results) 255) 256)))))
    (io.panic "lsp-workspace-symbol-cap-dedup failed")))

(test
  lsp-replace-form-at-position-smoke
  (unless
    (let
      [text : String "(define (foo) : i64 1)\n(define (bar) : i64 2)"]
      (match (lsp-replace-form-at-position text 1 5 "(define (baz) : i64 3)")
        [(Ok replaced)
          (string.eq replaced "(define (foo) : i64 1)\n(define (baz) : i64 3)")]
        [(Err _) false]))
    (io.panic "lsp-replace-form-at-position-smoke failed")))

(test
  lsp-find-top-level-form-at-offset-smoke
  (unless
    (let
      [text : String "(define (foo) : i64\n  (+ 1 2))\n(define (bar) : i64 3)"]
      [text-length : i64 (string.string-length text)]
      [nested-offset : i64 (lsp.lsp-offset-at-position text 1 4)]
      [second-offset : i64 (lsp.lsp-offset-at-position text 2 9)]
      (and
        (= (lsp-find-top-level-form-at-offset text nested-offset) 0)
        (=
          (lsp-find-top-level-form-at-offset text second-offset)
          (lsp.lsp-offset-at-position text 2 0))
        (= (lsp-find-top-level-form-at-offset text -1) -1)
        (= (lsp-find-top-level-form-at-offset text text-length) -1)))
    (io.panic "lsp-find-top-level-form-at-offset-smoke failed")))

(test
  lsp-replace-form-at-position-nested-smoke
  (unless
    (let
      [text : String "(define (foo) : i64\n  (+ 1 2))\n(define (bar) : i64 3)"]
      (match (lsp-replace-form-at-position text 1 4 "(define (baz) : i64 4)")
        [(Ok replaced)
          (string.eq replaced "(define (baz) : i64 4)\n(define (bar) : i64 3)")]
        [(Err _) false]))
    (io.panic "lsp-replace-form-at-position-nested-smoke failed")))

(test
  lsp-replace-form-at-position-noop
  (unless
    (let
      [text : String "(define (foo) : i64 1)"]
      (match (lsp-replace-form-at-position text 0 22 "(define (bad) : i64 0)")
        [(Ok _) false]
        [(Err message) (string.eq message "No form found at position")]))
    (io.panic "lsp-replace-form-at-position-noop failed")))

(test
  lsp-structural-replace-by-name-smoke
  (unless
    (let
      [text : String "(define (foo) : i64 1)\n(define (bar) : i64 2)"]
      [decls : lsp_decl_vec.Vec (lsp-test-scan-decls text)]
      (match (lsp.lsp-structural-replace-text-with-decls
        text
        "bar"
        "(define (bar) : i64 42)"
        decls)
        [(Ok replaced)
          (string.eq replaced "(define (foo) : i64 1)\n(define (bar) : i64 42)")]
        [(Err _) false]))
    (io.panic "lsp-structural-replace-by-name-smoke failed")))

(test
  lsp-delete-form-by-name-smoke
  (unless
    (let
      [text : String "(define (foo) : i64 1)\n(define (bar) : i64 2)"]
      [decls : lsp_decl_vec.Vec (lsp-test-scan-decls text)]
      (match (lsp.lsp-delete-form-by-name-with-decls text "bar" decls)
        [(Ok deleted) (string.eq deleted "(define (foo) : i64 1)\n")]
        [(Err _) false]))
    (io.panic "lsp-delete-form-by-name-smoke failed")))

(test
  lsp-read-form-by-name-smoke
  (unless
    (let
      [text : String "(define (foo) : i64 1)\n(define (bar) : i64 2)"]
      [decls : lsp_decl_vec.Vec (lsp-test-scan-decls text)]
      (match (lsp.lsp-read-form-by-name-with-decls text "bar" decls)
        [(Ok form-text) (string.eq form-text "(define (bar) : i64 2)")]
        [(Err _) false]))
    (io.panic "lsp-read-form-by-name-smoke failed")))

(test
  lsp-replace-pattern-by-name-smoke
  (unless
    (let
      [text : String "(define (foo) : i64 1)\n(define (bar) : i64 2)"]
      [decls : lsp_decl_vec.Vec (lsp-test-scan-decls text)]
      (match (lsp.lsp-replace-pattern-text-with-decls text "bar" "2" "4" decls)
        [(Ok replaced)
          (string.eq replaced "(define (foo) : i64 1)\n(define (bar) : i64 4)")]
        [(Err _) false]))
    (io.panic "lsp-replace-pattern-by-name-smoke failed")))

(test
  lsp-find-path-nested-smoke
  (unless
    (let
      [text : String (lsp-nested-path-test-text)]
      [decls : lsp_decl_vec.Vec (lsp-test-scan-decls text)]
      [path : json.JsonSeq (lsp-test-path4 "foo" "let" "match" "Ok")]
      [needle : String "(Ok value)"]
      (match (lsp.lsp-lookup-form-path text decls path)
        [(Found start end name)
          (let
            [form-text : String (string.substring text start (- end start))]
            (and
              (string.eq name "Ok")
              (string.contains (& form-text) (& needle))))]
        [(Err _) false]))
    (io.panic "lsp-find-path-nested-smoke failed")))

(test
  lsp-replace-form-by-path-smoke
  (unless
    (let
      [text : String (lsp-nested-path-test-text)]
      [decls : lsp_decl_vec.Vec (lsp-test-scan-decls text)]
      [path : json.JsonSeq (lsp-test-path3 "foo" "let" "match")]
      [new-text : String "(+ x 1)"]
      [old-match : String "(match x"]
      (match (lsp.lsp-replace-form-by-path-with-decls
        text
        path
        (owned_view.compiler-owned-shared-view new-text)
        decls)
        [(Ok replaced)
          (and
            (string.contains (& replaced) (& new-text))
            (not (string.contains (& replaced) (& old-match))))]
        [(Err _) false]))
    (io.panic "lsp-replace-form-by-path-smoke failed")))

(test
  lsp-replace-body-by-path-smoke
  (unless
    (let
      [text : String (lsp-nested-path-test-text)]
      [decls : lsp_decl_vec.Vec (lsp-test-scan-decls text)]
      [path : json.JsonSeq (lsp-test-path1 "foo")]
      [new-body : String "(+ x 2)"]
      [old-match : String "(match x"]
      (match (lsp.lsp-replace-body-by-path-with-decls
        text
        path
        (owned_view.compiler-owned-shared-view new-body)
        decls)
        [(Ok replaced)
          (and
            (string.contains (& replaced) (& new-body))
            (not (string.contains (& replaced) (& old-match))))]
        [(Err _) false]))
    (io.panic "lsp-replace-body-by-path-smoke failed")))