;; Focused semantic-cache tests live outside the unified CLI import closure.
(cfg test (import stdlib.arena))
(cfg test (import stdlib.io))
(cfg test (import stdlib.string))
(cfg test (import stdlib.vector))
(cfg test (import (vector.vector String) as lsp_svec))
(cfg test (import compiler_semantic_index))
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
        (lsp.lsp-server-state-copy-in-current state)]
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
        (lsp.lsp-server-state-finish-swap state draft previous)))))

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
        (lsp.lsp-server-state-copy-in-current state)]
      (begin
        (lsp.lsp-workspace-semantic-cache-invalidate-path!
          (&mut draft.semantic-cache)
          path)
        (lsp.lsp-server-state-finish-swap state draft previous)))))

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
        (lsp.lsp-server-state-copy-in-current state)]
      (begin
        (lsp.lsp-workspace-index-add-text-source!
          (&mut draft.workspace)
          lsp_vector_families.LspWorkspaceRootLookup.Missing
          path
          text
          overlay)
        (lsp.lsp-server-state-finish-swap state draft previous)))))

(cfg
  test
  (define (lsp-workspace-semantic-smoke-query-complete?
    [query : (& query lsp.LspWorkspaceSemanticQuery)]) : bool
    (match query.completeness
      [(lsp_vector_families.LspWorkspaceSemanticCompleteness.Complete) true]
      [_ false])))

(cfg
  test
  (define (lsp-workspace-semantic-smoke-query-incomplete?
    [query : (& query lsp.LspWorkspaceSemanticQuery)]) : bool
    (match query.completeness
      [(lsp_vector_families.LspWorkspaceSemanticCompleteness.CurrentlyIncomplete)
        true]
      [_ false])))

(cfg
  test
  (define (lsp-workspace-semantic-smoke-fact-at?
    [facts : (& facts lsp_vector_families.LspWorkspaceSemanticFacts)]
    [path : String]
    [role : compiler_semantic_index.CompilerSemanticRecordRole]) : bool
    (let
      [normalized : String (lsp.lsp-normalized-absolute-path path)]
      [wanted-role : i64 (lsp.lsp-workspace-semantic-role-tag (& role))]
      [index : i64 0]
      [found : bool false]
      (begin
        (while (and (< index facts.len) (not found))
          (let
            [fact : lsp_vector_families.LspWorkspaceSemanticFact
              (lsp.lsp-workspace-semantic-facts-get facts index)]
            (begin
              (if (and
                (string.eq fact.path normalized)
                (=
                  (lsp.lsp-workspace-semantic-role-tag (& fact.record.role))
                  wanted-role))
                (set! found true)
                unit)
              (set! index (+ index 1)))))
        found))))

(cfg
  test
  (define (lsp-workspace-semantic-smoke-facts-sorted?
    [facts : (& facts lsp_vector_families.LspWorkspaceSemanticFacts)]) : bool
    (let
      [index : i64 1]
      [sorted : bool true]
      (begin
        (while (and (< index facts.len) sorted)
          (begin
            (if (lsp.lsp-workspace-semantic-fact-less?
              (& (array-ref facts.slots index))
              (& (array-ref facts.slots (- index 1))))
              (set! sorted false)
              unit)
            (set! index (+ index 1))))
        sorted))))

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
    [shared-index
      : compiler_semantic_index.CompilerSemanticSourceIndex
      (:consume)]
    [open-index
      : compiler_semantic_index.CompilerSemanticSourceIndex
      (:consume)]) : bool
    (let
      [shared-uri : String (lsp.lsp-path-to-file-uri shared-path)]
      [open-uri : String (lsp.lsp-path-to-file-uri open-path)]
      [docs : lsp_document_vec.Vec
        (lsp.lsp-semantic-smoke-install
          (lsp.lsp-semantic-smoke-install
            (lsp_document_vec.new)
            shared-uri
            shared-path
            shared-text
            1
            shared-index)
          open-uri
          open-path
          open-text
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
          shared-path
          shared-text
          open-path
          open-text
          closed-path
          closed-text
          noise-path
          noise-text)]
      [roots : lsp_svec.Vec (lsp_svec.new)]
      [cold : lsp.LspWorkspaceSemanticRefreshResult
        (lsp.lsp-server-state-refresh-semantic-cache workspace-state roots)]
      [cold-state : lsp_vector_families.LspServerState cold.state]
      [shared-doc-index : i64
        (lsp.lsp-documents-find-index cold-state.documents shared-uri)]
      [shared-doc : lsp_vector_families.LspDocument
        (lsp_document_vec.get
          (& cold-state.documents)
          shared-doc-index
          (lsp.lsp-document-fallback))]
      [definition-index : i64
        (compiler_semantic_index.compiler-semantic-source-index-find-definition
          (& shared-doc.semantic.index)
          shared-path
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
        (lsp.lsp-workspace-semantic-query (& cold-state) roots canonical-key)]
      [cold-records : i64 cold.metrics.retained-records]
      [warm : lsp.LspWorkspaceSemanticRefreshResult
        (lsp.lsp-server-state-refresh-semantic-cache cold-state roots)]
      [warm-state : lsp_vector_families.LspServerState warm.state]
      [warm-query : lsp.LspWorkspaceSemanticQuery
        (lsp.lsp-workspace-semantic-query (& warm-state) roots canonical-key)]
      [invalidated-state : lsp_vector_families.LspServerState
        (lsp-workspace-semantic-smoke-invalidate-state warm-state shared-path)]
      [affected-only : bool (= invalidated-state.semantic-cache.len 1)]
      [rebuilt : lsp.LspWorkspaceSemanticRefreshResult
        (lsp.lsp-server-state-refresh-semantic-cache invalidated-state roots)]
      [final-state : lsp_vector_families.LspServerState rebuilt.state]
      [ok : bool
        (and
          (>= definition-index 0)
          (> (string.string-length canonical-key) 0)
          (= cold.metrics.source-checks 2)
          (= cold.metrics.cache-entries 2)
          (= cold.metrics.retained-owners 4)
          (> cold.metrics.retained-records 0)
          (lsp-workspace-semantic-smoke-query-complete? (& cold-query))
          (= cold-query.facts.len 3)
          (lsp-workspace-semantic-smoke-facts-sorted? (& cold-query.facts))
          (lsp-workspace-semantic-smoke-fact-at?
            (& cold-query.facts)
            shared-path
            compiler_semantic_index.CompilerSemanticRecordRole.Definition)
          (lsp-workspace-semantic-smoke-fact-at?
            (& cold-query.facts)
            open-path
            compiler_semantic_index.CompilerSemanticRecordRole.Use)
          (lsp-workspace-semantic-smoke-fact-at?
            (& cold-query.facts)
            closed-path
            compiler_semantic_index.CompilerSemanticRecordRole.Use)
          (not
            (lsp-workspace-semantic-smoke-fact-at?
              (& cold-query.facts)
              noise-path
              compiler_semantic_index.CompilerSemanticRecordRole.Definition))
          (= warm.metrics.source-checks 0)
          (= warm.metrics.retained-owners 4)
          (= warm.metrics.retained-records cold-records)
          (lsp-workspace-semantic-smoke-query-complete? (& warm-query))
          (= warm-query.facts.len cold-query.facts.len)
          (lsp-workspace-semantic-smoke-facts-sorted? (& warm-query.facts))
          affected-only
          (= rebuilt.metrics.source-checks 1)
          (= rebuilt.metrics.cache-entries 2)
          (= rebuilt.metrics.retained-owners 4))]
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
        shared-path
        shared-text
        (lsp_svec.new)
        (lsp.lsp-language-cfgs))
        [(compiler_semantic_index.ResultCompilerCheckWithSemanticIndex.Ok
            _
            shared-index)
          (match (compiler_semantic_index.compiler-check-source-index-with-roots-and-cfg
            open-path
            open-text
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
      [cold : lsp.LspWorkspaceSemanticRefreshResult
        (lsp.lsp-server-state-refresh-semantic-cache state roots)]
      [cold-state : lsp_vector_families.LspServerState cold.state]
      [query : lsp.LspWorkspaceSemanticQuery
        (lsp.lsp-workspace-semantic-query
          (& cold-state)
          roots
          "missing-canonical-key")]
      [warm : lsp.LspWorkspaceSemanticRefreshResult
        (lsp.lsp-server-state-refresh-semantic-cache cold-state roots)]
      [final-state : lsp_vector_families.LspServerState warm.state]
      [ok : bool
        (and
          (= cold.metrics.source-checks 1)
          (= cold.metrics.cache-entries 1)
          (lsp-workspace-semantic-smoke-query-incomplete? (& query))
          (= query.facts.len 0)
          (= warm.metrics.source-checks 0)
          (= warm.metrics.cache-entries 1)
          (= warm.metrics.retained-owners cold.metrics.retained-owners)
          (= warm.metrics.retained-records cold.metrics.retained-records))]
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
    [shared-index
      : compiler_semantic_index.CompilerSemanticSourceIndex
      (:consume)]) : bool
    (let
      [shared-uri : String (lsp.lsp-path-to-file-uri shared-path)]
      [docs : lsp_document_vec.Vec
        (lsp.lsp-semantic-smoke-install
          (lsp_document_vec.new)
          shared-uri
          shared-path
          shared-text
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
          shared-path
          shared-text
          true)]
      [workspace-state : lsp_vector_families.LspServerState
        (lsp-workspace-semantic-smoke-add-source-state
          overlay-state
          closed-path
          closed-text
          false)]
      [roots : lsp_svec.Vec (lsp_svec.new)]
      [cold : lsp.LspWorkspaceSemanticRefreshResult
        (lsp.lsp-server-state-refresh-semantic-cache workspace-state roots)]
      [cold-state : lsp_vector_families.LspServerState cold.state]
      [doc : lsp_vector_families.LspDocument
        (lsp_document_vec.get
          (& cold-state.documents)
          0
          (lsp.lsp-document-fallback))]
      [definition-index : i64
        (compiler_semantic_index.compiler-semantic-source-index-find-definition
          (& doc.semantic.index)
          shared-path
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
        (lsp.lsp-workspace-semantic-query (& cold-state) roots canonical-key)]
      [negative : bool
        (if (= cold-state.semantic-cache.len 1)
          (not
            (__tl-project-field
              (lsp.lsp-workspace-semantic-cache-get
                (& cold-state.semantic-cache)
                0)
              present))
          false)]
      [warm : lsp.LspWorkspaceSemanticRefreshResult
        (lsp.lsp-server-state-refresh-semantic-cache cold-state roots)]
      [final-state : lsp_vector_families.LspServerState warm.state]
      [ok : bool
        (and
          (>= definition-index 0)
          (= cold.metrics.source-checks 1)
          (= cold.metrics.cache-entries 1)
          (= cold.metrics.retained-owners 1)
          negative
          (lsp-workspace-semantic-smoke-query-incomplete? (& query))
          (= query.facts.len 1)
          (lsp-workspace-semantic-smoke-fact-at?
            (& query.facts)
            shared-path
            compiler_semantic_index.CompilerSemanticRecordRole.Definition)
          (not
            (lsp-workspace-semantic-smoke-fact-at?
              (& query.facts)
              closed-path
              compiler_semantic_index.CompilerSemanticRecordRole.Use))
          (= warm.metrics.source-checks 0)
          (= warm.metrics.cache-entries 1)
          (= warm.metrics.retained-owners 1))]
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
        shared-path
        shared-text
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