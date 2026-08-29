;; Focused semantic-cache tests live outside the unified CLI import closure.
(cfg test (import stdlib.arena))
(cfg test (import stdlib.io))
(cfg test (import stdlib.string))
(cfg test (import stdlib.vector))
(cfg test (import (vector.vector String) as lsp_svec))
(cfg test (import compiler_semantic_index))
(cfg test (import compiler_owned_view as owned_view))
(cfg test (import lsp_frame_core as lsp))
(cfg test (import lsp_vector_families))
(cfg
  test
  (import (vector.vector lsp_vector_families.LspDocument core) as lsp_document_vec))

(cfg
  test
  (define (lsp-workspace-semantic-smoke-workspace-state
    [state : lsp_vector_families.LspServerState]
    [shared-path : String]
    [shared-text : String]
    [open-path : String]
    [open-text : String]
    [closed-path : String]
    [closed-text : String]
    [noise-path : String]
    [noise-text : String]) : lsp_vector_families.LspServerState
    (let
      [previous : i64 (arena.tl_arena_current)]
      [owner : i64 (arena.tl_arena_make)]
      [_install : unit
        (unsafe
          (arena.tl_arena_set owner))]
      [draft : lsp_vector_families.LspServerState
        (lsp.lsp-server-state-copy-in-current
          (lsp.lsp-global-shared-view state))]
      (begin
        (lsp.lsp-workspace-index-add-text-source!
          (&mut draft.workspace)
          lsp_vector_families.LspWorkspaceRootLookup.Missing
          shared-path
          shared-text
          true)
        (lsp.lsp-workspace-index-add-text-source!
          (&mut draft.workspace)
          lsp_vector_families.LspWorkspaceRootLookup.Missing
          open-path
          open-text
          true)
        (lsp.lsp-workspace-index-add-text-source!
          (&mut draft.workspace)
          lsp_vector_families.LspWorkspaceRootLookup.Missing
          closed-path
          closed-text
          false)
        (lsp.lsp-workspace-index-add-text-source!
          (&mut draft.workspace)
          lsp_vector_families.LspWorkspaceRootLookup.Missing
          noise-path
          noise-text
          false)
        (lsp.lsp-server-state-finish-swap state draft owner previous)))))

(cfg
  test
  (define (lsp-workspace-semantic-smoke-invalidate-state
    [state : lsp_vector_families.LspServerState]
    [path : String]) : lsp_vector_families.LspServerState
    (let
      [previous : i64 (arena.tl_arena_current)]
      [owner : i64 (arena.tl_arena_make)]
      [_install : unit
        (unsafe
          (arena.tl_arena_set owner))]
      [draft : lsp_vector_families.LspServerState
        (lsp.lsp-server-state-copy-in-current
          (lsp.lsp-global-shared-view state))]
      (begin
        (lsp.lsp-workspace-semantic-cache-invalidate-path!
          (&mut draft.semantic-cache)
          path)
        (lsp.lsp-server-state-finish-swap state draft owner previous)))))

(cfg
  test
  (define (lsp-workspace-semantic-smoke-add-source-state
    [state : lsp_vector_families.LspServerState]
    [path : String]
    [text : String]
    [overlay : bool]) : lsp_vector_families.LspServerState
    (let
      [previous : i64 (arena.tl_arena_current)]
      [owner : i64 (arena.tl_arena_make)]
      [_install : unit
        (unsafe
          (arena.tl_arena_set owner))]
      [draft : lsp_vector_families.LspServerState
        (lsp.lsp-server-state-copy-in-current
          (lsp.lsp-global-shared-view state))]
      (begin
        (lsp.lsp-workspace-index-add-text-source!
          (&mut draft.workspace)
          lsp_vector_families.LspWorkspaceRootLookup.Missing
          path
          text
          overlay)
        (lsp.lsp-server-state-finish-swap state draft owner previous)))))

(cfg
  test
  (define (lsp-workspace-semantic-test-retained-owners
    [state : (& state lsp_vector_families.LspServerState)]) : i64
    (let
      [count : i64 0]
      [index : i64 0]
      (begin
        (while (< index (lsp_document_vec.len (& state.documents)))
          (begin
            (if (__tl-project-field
              (__tl-project-field
                (lsp_document_vec.get
                  (& state.documents)
                  index
                  (lsp.lsp-document-fallback))
                semantic)
              present)
              (set! count (+ count 1))
              unit)
            (set! index (+ index 1))))
        (set! index 0)
        (while (< index state.semantic-cache.len)
          (begin
            (if (>
              (array-ref state.semantic-cache.slots index).index.owner-arena
              0)
              (set! count (+ count 1))
              unit)
            (set! index (+ index 1))))
        count))))

(cfg
  test
  (define (lsp-workspace-semantic-test-retained-records
    [state : (& state lsp_vector_families.LspServerState)]) : i64
    (let
      [count : i64 0]
      [index : i64 0]
      (begin
        (while (< index (lsp_document_vec.len (& state.documents)))
          (let
            [doc : lsp_vector_families.LspDocument
              (lsp_document_vec.get
                (& state.documents)
                index
                (lsp.lsp-document-fallback))]
            [snapshot : lsp_vector_families.LspSemanticSnapshot
              (lsp.lsp-global-shared-view doc.semantic)]
            (begin
              (if snapshot.present
                (set!
                  count
                  (+
                    count
                    (compiler_semantic_index.compiler-semantic-source-index-len
                      (& snapshot.index))))
                unit)
              (set! index (+ index 1)))))
        (set! index 0)
        (while (< index state.semantic-cache.len)
          (let
            [entry : lsp_vector_families.LspWorkspaceSemanticCacheEntry
              (owned_view.compiler-owned-array-element-shared-view
                state.semantic-cache.slots
                index)]
            (begin
              (if (> entry.index.owner-arena 0)
                (set!
                  count
                  (+
                    count
                    (compiler_semantic_index.compiler-semantic-source-index-len
                      (& entry.index))))
                unit)
              (set! index (+ index 1)))))
        count))))

(cfg
  test
  (define (lsp-workspace-semantic-test-role-tag
    [role : (& role compiler_semantic_index.CompilerSemanticRecordRole)]) : i64
    (match (deref role)
      [(compiler_semantic_index.CompilerSemanticRecordRole.Definition) 0]
      [(compiler_semantic_index.CompilerSemanticRecordRole.Use) 1])))

(cfg
  test
  (define (lsp-workspace-semantic-smoke-query-complete?
    [query : (& query lsp.LspWorkspaceSemanticQuery)]) : bool
    (= query.completeness 0)))

(cfg
  test
  (define (lsp-workspace-semantic-smoke-query-incomplete?
    [query : (& query lsp.LspWorkspaceSemanticQuery)]) : bool
    (= query.completeness 2)))

(cfg
  test
  (define (lsp-workspace-semantic-smoke-fact-at?
    [facts : (& facts lsp.LspWorkspaceSemanticQuery)]
    [path : String]
    [role : compiler_semantic_index.CompilerSemanticRecordRole]) : bool
    (let
      [normalized : String (lsp.lsp-normalized-absolute-path path)]
      [wanted-role : i64 (lsp-workspace-semantic-test-role-tag (& role))]
      [index : i64 0]
      [found : bool false]
      (begin
        (while (and (< index facts.len) (not found))
          (let
            [fact : lsp_vector_families.LspWorkspaceSemanticFact
              (lsp.lsp-workspace-semantic-facts-get facts index)]
            (begin
              (if (and
                (string.eq fact.span.path normalized)
                (=
                  (lsp-workspace-semantic-test-role-tag (& fact.role))
                  wanted-role))
                (set! found true)
                unit)
              (set! index (+ index 1)))))
        found))))

(cfg
  test
  (define (lsp-workspace-semantic-cache-smoke-with-open
    [owners-before : i64]
    [shared-path : String]
    [shared-text : String]
    [open-path : String]
    [open-text : String]
    [closed-path : String]
    [closed-text : String]
    [noise-path : String]
    [noise-text : String]
    [shared-index : compiler_semantic_index.CompilerSemanticSourceIndex]
    [open-index : compiler_semantic_index.CompilerSemanticSourceIndex]) : bool
    (let
      [shared-uri : String
        (lsp.lsp-path-to-file-uri (lsp.lsp-global-shared-view shared-path))]
      [open-uri : String
        (lsp.lsp-path-to-file-uri (lsp.lsp-global-shared-view open-path))]
      [docs : lsp_document_vec.Vec
        (lsp.lsp-semantic-smoke-install
          (lsp.lsp-semantic-smoke-install
            (lsp_document_vec.new)
            (lsp.lsp-global-shared-view shared-uri)
            (lsp.lsp-global-shared-view shared-path)
            (lsp.lsp-global-shared-view shared-text)
            1
            shared-index)
          open-uri
          (lsp.lsp-global-shared-view open-path)
          (lsp.lsp-global-shared-view open-text)
          1
          open-index)]
      [empty-state : lsp_vector_families.LspServerState
        (lsp.lsp-server-state-new)]
      [document-state : lsp_vector_families.LspServerState
        (match (lsp.lsp-server-state-copy-document-result
          empty-state
          (lsp.LspDocumentHandleResult.Continue docs)
          false)
          [(lsp.LspHandleResult.Continue next) next]
          [(lsp.LspHandleResult.Exit next) next])]
      [workspace-state : lsp_vector_families.LspServerState
        (lsp-workspace-semantic-smoke-workspace-state
          document-state
          (lsp.lsp-global-shared-view shared-path)
          shared-text
          (lsp.lsp-global-shared-view open-path)
          open-text
          (lsp.lsp-global-shared-view closed-path)
          closed-text
          (lsp.lsp-global-shared-view noise-path)
          noise-text)]
      [roots : lsp_svec.Vec (lsp_svec.new)]
      [cold-state : lsp_vector_families.LspServerState
        (lsp.lsp-server-state-refresh-semantic-cache
          workspace-state
          (lsp.lsp-global-shared-view roots))]
      [shared-doc-index : i64
        (lsp.lsp-documents-find-index (& cold-state.documents) (& shared-uri))]
      [shared-doc : lsp_vector_families.LspDocument
        (lsp_document_vec.get
          (& cold-state.documents)
          shared-doc-index
          (lsp.lsp-document-fallback))]
      [definition-index : i64
        (compiler_semantic_index.compiler-semantic-source-index-find-definition
          (& shared-doc.semantic.index)
          (lsp.lsp-global-shared-view shared-path)
          "target-value")]
      [definition : compiler_semantic_index.CompilerSemanticRecord
        (compiler_semantic_index.compiler-semantic-source-index-get
          (& shared-doc.semantic.index)
          definition-index)]
      [canonical-key : String
        (compiler_semantic_index.compiler-semantic-source-index-record-canonical-key
          (& shared-doc.semantic.index)
          (& definition))]
      [cold-query : lsp.LspWorkspaceSemanticQuery
        (lsp.lsp-workspace-semantic-query
          (& cold-state)
          (lsp.lsp-global-shared-view roots)
          (lsp.lsp-global-shared-view canonical-key))]
      [cold-records : i64
        (lsp-workspace-semantic-test-retained-records (& cold-state))]
      [cold-owners : i64
        (lsp-workspace-semantic-test-retained-owners (& cold-state))]
      [cold-source-checks : i64 cold-state.semantic-cache.source-checks]
      [cold-cache-len : i64 cold-state.semantic-cache.len]
      [warm-state : lsp_vector_families.LspServerState
        (lsp.lsp-server-state-refresh-semantic-cache
          cold-state
          (lsp.lsp-global-shared-view roots))]
      [warm-query : lsp.LspWorkspaceSemanticQuery
        (lsp.lsp-workspace-semantic-query
          (& warm-state)
          (lsp.lsp-global-shared-view roots)
          (lsp.lsp-global-shared-view canonical-key))]
      [warm-records : i64
        (lsp-workspace-semantic-test-retained-records (& warm-state))]
      [warm-owners : i64
        (lsp-workspace-semantic-test-retained-owners (& warm-state))]
      [warm-source-checks : i64 warm-state.semantic-cache.source-checks]
      [invalidated-state : lsp_vector_families.LspServerState
        (lsp-workspace-semantic-smoke-invalidate-state
          warm-state
          (lsp.lsp-global-shared-view shared-path))]
      [affected-only : bool (= invalidated-state.semantic-cache.len 1)]
      [final-state : lsp_vector_families.LspServerState
        (lsp.lsp-server-state-refresh-semantic-cache invalidated-state roots)]
      [ok : bool
        (and
          (>= definition-index 0)
          (> (string.string-length canonical-key) 0)
          (= cold-source-checks 2)
          (= cold-cache-len 2)
          (= cold-owners 4)
          (> cold-records 0)
          (lsp-workspace-semantic-smoke-query-complete? (& cold-query))
          (= cold-query.len 3)
          (lsp-workspace-semantic-smoke-fact-at?
            (& cold-query)
            (lsp.lsp-global-shared-view shared-path)
            compiler_semantic_index.CompilerSemanticRecordRole.Definition)
          (lsp-workspace-semantic-smoke-fact-at?
            (& cold-query)
            (lsp.lsp-global-shared-view open-path)
            compiler_semantic_index.CompilerSemanticRecordRole.Use)
          (lsp-workspace-semantic-smoke-fact-at?
            (& cold-query)
            (lsp.lsp-global-shared-view closed-path)
            compiler_semantic_index.CompilerSemanticRecordRole.Use)
          (not
            (lsp-workspace-semantic-smoke-fact-at?
              (& cold-query)
              (lsp.lsp-global-shared-view noise-path)
              compiler_semantic_index.CompilerSemanticRecordRole.Definition))
          (= warm-source-checks 0)
          (= warm-owners 4)
          (= warm-records cold-records)
          (lsp-workspace-semantic-smoke-query-complete? (& warm-query))
          (= warm-query.len cold-query.len)
          affected-only
          (= final-state.semantic-cache.source-checks 1)
          (= final-state.semantic-cache.len 2)
          (= (lsp-workspace-semantic-test-retained-owners (& final-state)) 4))]
      (begin
        (lsp.lsp-server-state-destroy! final-state)
        (and
          ok
          (=
            owners-before
            (compiler_semantic_index.compiler-semantic-source-index-live-owner-count)))))))

(cfg
  test
  (define (lsp-workspace-semantic-cache-smoke-ok?) : bool
    (let
      [shared-path : String "src/tests/semantic/lsp_cache/shared.tl"]
      [open-path : String "src/tests/lsp_semantic_cache_open_consumer.tl"]
      [closed-path : String "src/tests/lsp_semantic_cache_closed_consumer.tl"]
      [noise-path : String "src/tests/semantic/lsp_cache/noise.tl"]
      [shared-text : String (lsp.lsp-read-file-text-or (& shared-path) "")]
      [open-text : String (lsp.lsp-read-file-text-or (& open-path) "")]
      [closed-text : String (lsp.lsp-read-file-text-or (& closed-path) "")]
      [noise-text : String (lsp.lsp-read-file-text-or (& noise-path) "")]
      [owners-before : i64
        (compiler_semantic_index.compiler-semantic-source-index-live-owner-count)]
      (match (compiler_semantic_index.compiler-check-source-index-with-roots-and-cfg
        (lsp.lsp-global-shared-view shared-path)
        (lsp.lsp-global-shared-view shared-text)
        (lsp_svec.new)
        (lsp.lsp-language-cfgs))
        [(compiler_semantic_index.ResultCompilerCheckWithSemanticIndex.Ok
            _
            shared-index)
          (match (compiler_semantic_index.compiler-check-source-index-with-roots-and-cfg
            (lsp.lsp-global-shared-view open-path)
            (lsp.lsp-global-shared-view open-text)
            (lsp_svec.new)
            (lsp.lsp-language-cfgs))
            [(compiler_semantic_index.ResultCompilerCheckWithSemanticIndex.Ok
                _
                open-index)
              (lsp-workspace-semantic-cache-smoke-with-open
                owners-before
                shared-path
                shared-text
                open-path
                open-text
                closed-path
                closed-text
                noise-path
                noise-text
                shared-index
                open-index)]
            [(compiler_semantic_index.ResultCompilerCheckWithSemanticIndex.Partial
                _
                partial)
              (begin
                (compiler_semantic_index.compiler-semantic-source-index-release!
                  (&mut partial))
                (compiler_semantic_index.compiler-semantic-source-index-release!
                  (&mut shared-index))
                false)]
            [(compiler_semantic_index.ResultCompilerCheckWithSemanticIndex.Err
                _)
              (begin
                (compiler_semantic_index.compiler-semantic-source-index-release!
                  (&mut shared-index))
                false)])]
        [(compiler_semantic_index.ResultCompilerCheckWithSemanticIndex.Partial
            _
            partial)
          (begin
            (compiler_semantic_index.compiler-semantic-source-index-release!
              (&mut partial))
            false)]
        [(compiler_semantic_index.ResultCompilerCheckWithSemanticIndex.Err _)
          false]))))

(cfg
  test
  (define (lsp-workspace-semantic-cache-incomplete-smoke-ok?) : bool
    (let
      [path : String "src/tests/semantic/lsp_cache/invalid.tl"]
      [text : String (lsp.lsp-read-file-text-or (& path) "")]
      [roots : lsp_svec.Vec (lsp_svec.new)]
      [owners-before : i64
        (compiler_semantic_index.compiler-semantic-source-index-live-owner-count)]
      [state : lsp_vector_families.LspServerState
        (lsp-workspace-semantic-smoke-add-source-state
          (lsp.lsp-server-state-new)
          path
          text
          false)]
      [cold-state : lsp_vector_families.LspServerState
        (lsp.lsp-server-state-refresh-semantic-cache
          state
          (lsp.lsp-global-shared-view roots))]
      [query : lsp.LspWorkspaceSemanticQuery
        (lsp.lsp-workspace-semantic-query
          (& cold-state)
          (lsp.lsp-global-shared-view roots)
          "missing-canonical-key")]
      [cold-owners : i64
        (lsp-workspace-semantic-test-retained-owners (& cold-state))]
      [cold-records : i64
        (lsp-workspace-semantic-test-retained-records (& cold-state))]
      [cold-source-checks : i64 cold-state.semantic-cache.source-checks]
      [cold-cache-len : i64 cold-state.semantic-cache.len]
      [final-state : lsp_vector_families.LspServerState
        (lsp.lsp-server-state-refresh-semantic-cache cold-state roots)]
      [ok : bool
        (and
          (= cold-source-checks 1)
          (= cold-cache-len 1)
          (lsp-workspace-semantic-smoke-query-incomplete? (& query))
          (= query.len 0)
          (= final-state.semantic-cache.source-checks 0)
          (= final-state.semantic-cache.len 1)
          (=
            (lsp-workspace-semantic-test-retained-owners (& final-state))
            cold-owners)
          (=
            (lsp-workspace-semantic-test-retained-records (& final-state))
            cold-records))]
      (begin
        (lsp.lsp-server-state-destroy! final-state)
        (and
          ok
          (=
            owners-before
            (compiler_semantic_index.compiler-semantic-source-index-live-owner-count)))))))

(cfg
  test
  (define (lsp-workspace-semantic-cache-overlay-smoke-with-index
    [owners-before : i64]
    [shared-path : String]
    [shared-text : String]
    [closed-path : String]
    [closed-text : String]
    [shared-index : compiler_semantic_index.CompilerSemanticSourceIndex]) : bool
    (let
      [shared-uri : String
        (lsp.lsp-path-to-file-uri (lsp.lsp-global-shared-view shared-path))]
      [docs : lsp_document_vec.Vec
        (lsp.lsp-semantic-smoke-install
          (lsp_document_vec.new)
          shared-uri
          (lsp.lsp-global-shared-view shared-path)
          (lsp.lsp-global-shared-view shared-text)
          7
          shared-index)]
      [empty-state : lsp_vector_families.LspServerState
        (lsp.lsp-server-state-new)]
      [document-state : lsp_vector_families.LspServerState
        (match (lsp.lsp-server-state-copy-document-result
          empty-state
          (lsp.LspDocumentHandleResult.Continue docs)
          false)
          [(lsp.LspHandleResult.Continue next) next]
          [(lsp.LspHandleResult.Exit next) next])]
      [overlay-state : lsp_vector_families.LspServerState
        (lsp-workspace-semantic-smoke-add-source-state
          document-state
          (lsp.lsp-global-shared-view shared-path)
          shared-text
          true)]
      [workspace-state : lsp_vector_families.LspServerState
        (lsp-workspace-semantic-smoke-add-source-state
          overlay-state
          (lsp.lsp-global-shared-view closed-path)
          closed-text
          false)]
      [roots : lsp_svec.Vec (lsp_svec.new)]
      [cold-state : lsp_vector_families.LspServerState
        (lsp.lsp-server-state-refresh-semantic-cache
          workspace-state
          (lsp.lsp-global-shared-view roots))]
      [doc : lsp_vector_families.LspDocument
        (lsp_document_vec.get
          (& cold-state.documents)
          0
          (lsp.lsp-document-fallback))]
      [definition-index : i64
        (compiler_semantic_index.compiler-semantic-source-index-find-definition
          (& doc.semantic.index)
          (lsp.lsp-global-shared-view shared-path)
          "target-value")]
      [definition : compiler_semantic_index.CompilerSemanticRecord
        (compiler_semantic_index.compiler-semantic-source-index-get
          (& doc.semantic.index)
          definition-index)]
      [canonical-key : String
        (compiler_semantic_index.compiler-semantic-source-index-record-canonical-key
          (& doc.semantic.index)
          (& definition))]
      [query : lsp.LspWorkspaceSemanticQuery
        (lsp.lsp-workspace-semantic-query
          (& cold-state)
          (lsp.lsp-global-shared-view roots)
          canonical-key)]
      [negative : bool
        (if (= cold-state.semantic-cache.len 1)
          (not
            (>
              (array-ref cold-state.semantic-cache.slots 0).index.owner-arena
              0))
          false)]
      [cold-owners : i64
        (lsp-workspace-semantic-test-retained-owners (& cold-state))]
      [cold-source-checks : i64 cold-state.semantic-cache.source-checks]
      [cold-cache-len : i64 cold-state.semantic-cache.len]
      [final-state : lsp_vector_families.LspServerState
        (lsp.lsp-server-state-refresh-semantic-cache cold-state roots)]
      [ok : bool
        (and
          (>= definition-index 0)
          (= cold-source-checks 1)
          (= cold-cache-len 1)
          (= cold-owners 1)
          negative
          (lsp-workspace-semantic-smoke-query-incomplete? (& query))
          (= query.len 1)
          (lsp-workspace-semantic-smoke-fact-at?
            (& query)
            shared-path
            compiler_semantic_index.CompilerSemanticRecordRole.Definition)
          (not
            (lsp-workspace-semantic-smoke-fact-at?
              (& query)
              closed-path
              compiler_semantic_index.CompilerSemanticRecordRole.Use))
          (= final-state.semantic-cache.source-checks 0)
          (= final-state.semantic-cache.len 1)
          (= (lsp-workspace-semantic-test-retained-owners (& final-state)) 1))]
      (begin
        (lsp.lsp-server-state-destroy! final-state)
        (and
          ok
          (=
            owners-before
            (compiler_semantic_index.compiler-semantic-source-index-live-owner-count)))))))

(cfg
  test
  (define (lsp-workspace-semantic-cache-overlay-smoke-ok?) : bool
    (let
      [shared-path : String "src/tests/semantic/lsp_cache/shared.tl"]
      [closed-path : String "src/tests/lsp_semantic_cache_closed_consumer.tl"]
      [shared-text : String
        "(module semantic.lsp_cache.shared)\n;; Unsaved authoritative overlay.\n(define target-value : i64 41)\n"]
      [closed-text : String (lsp.lsp-read-file-text-or (& closed-path) "")]
      [owners-before : i64
        (compiler_semantic_index.compiler-semantic-source-index-live-owner-count)]
      (match (compiler_semantic_index.compiler-check-source-index-with-roots-and-cfg
        (lsp.lsp-global-shared-view shared-path)
        (lsp.lsp-global-shared-view shared-text)
        (lsp_svec.new)
        (lsp.lsp-language-cfgs))
        [(compiler_semantic_index.ResultCompilerCheckWithSemanticIndex.Ok
            _
            shared-index)
          (lsp-workspace-semantic-cache-overlay-smoke-with-index
            owners-before
            shared-path
            shared-text
            closed-path
            closed-text
            shared-index)]
        [(compiler_semantic_index.ResultCompilerCheckWithSemanticIndex.Partial
            _
            partial)
          (begin
            (compiler_semantic_index.compiler-semantic-source-index-release!
              (&mut partial))
            false)]
        [(compiler_semantic_index.ResultCompilerCheckWithSemanticIndex.Err _)
          false]))))

(test
  lsp-workspace-semantic-cache
  (unless
    (lsp-workspace-semantic-cache-smoke-ok?)
    (io.panic "lsp-workspace-semantic-cache failed")))

(test
  lsp-workspace-semantic-cache-incomplete
  (unless
    (lsp-workspace-semantic-cache-incomplete-smoke-ok?)
    (io.panic "lsp-workspace-semantic-cache-incomplete failed")))

(test
  lsp-workspace-semantic-cache-overlay
  (unless
    (lsp-workspace-semantic-cache-overlay-smoke-ok?)
    (io.panic "lsp-workspace-semantic-cache-overlay failed")))