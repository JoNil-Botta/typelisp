;; compiler_semantic_index.tl - Owned semantic source index for compiler tooling.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.arena)
(import stdlib.string)
(import stdlib.sort)
(import stdlib.vector)
(import stdlib.option)
(import sym_i64_env)
(import (vector.vector String) as svec)
(import (option.option i64) as option_i64)
(import compiler_check_core as check_core)
(import compiler_builtin_ids as cbi)
(import compiler_load as cload)
(import compiler_typecheck_api as tc_api)
(import compiler_parse_core as parse_core)
(import compiler_diagnostic as cdiag)
(import compiler_typecheck_core as tc)
(import compiler_ast_types as ast)
(import compiler_symbols as csym)
(import compiler_intern as ci)
(import compiler_intern_state as cis)

;; Tool-facing semantic data is copied into an explicitly owned arena. None of
;; these records retain TcContext, TcTypeEnv, parser sidecars, or intern-pool
;; strings, so a later check can reset compiler state without invalidating a
;; caller's last-good index.
;; Top-level symbols use local-ordinal -1 and their resolved compiler-symbol
;; handle index as declaration-ordinal. Lexical symbols use a deterministic
;; per-declaration local ordinal, so shadowed spellings remain distinct while
;; definition and use records share one dense identity inside a snapshot. These
;; numeric components are intentionally not a cross-snapshot contract; use the
;; owned canonical-key API below when correlating independently checked sources.
(defstruct CompilerSemanticSymbolId
  (module-id i64)
  (declaration-ordinal i64)
  (local-ordinal i64))

(defenum CompilerSemanticSymbolKind
  (Value)
  (Function)
  (Macro)
  (ExternValue)
  (ExternFunction)
  (Struct)
  (Enum)
  (Module)
  (Field)
  (EnumMember)
  (Parameter)
  (Local))

(defenum CompilerSemanticRecordRole
  (Definition)
  (Use))

(defenum CompilerSemanticAccess
  (None)
  (Read)
  (Write)
  (ReadWrite))

(defenum CompilerSemanticProvenance
  (EditableSource)
  (Generated String String String))

;; Policy: parsed default-library declarations are ordinary editable source
;; records when their file and exact origin are available. Compiler builtins
;; without a source occurrence do not fabricate an editable record. Macro- or
;; compiler-generated declarations retain their generator provenance, use
;; negative/non-editable spans when no user occurrence exists, and never expose
;; a generated member access as an editable rename target.
(defstruct CompilerSemanticSpan
  (path String)
  (start-byte i64)
  (end-byte i64)
  (source ast.AstSourceSpan)
  ;; LSP negotiates UTF-8 or UTF-16 character units. Retain both columns while
  ;; the owning source is available so consumers never need to reread an
  ;; imported definition's file merely to render its immutable location.
  (utf16-start-col i64)
  (utf16-end-col i64))

(defstruct CompilerSemanticRecord
  (symbol CompilerSemanticSymbolId)
  ;; Snapshot-local compact reference into `canonical-symbols`. The referenced
  ;; key owns its bytes in the source index arena and remains comparable with a
  ;; key obtained from any independently retained source index.
  (canonical-index i64)
  (role CompilerSemanticRecordRole)
  ;; Source-level binding access proven by the checked semantic walk. A
  ;; declaration has no access; unresolved syntax produces no record rather
  ;; than a guessed classification.
  (access CompilerSemanticAccess)
  (kind CompilerSemanticSymbolKind)
  (display-name String)
  ;; Empty only when the checked walk cannot reproduce a reliable local type
  ;; fact. Successful inferred lets, patterns, and resources are retained.
  (resolved-type String)
  ;; Adjacent `;:` and `;#` lines are attached to top-level definitions.
  (documentation String)
  (module-id i64)
  (span CompilerSemanticSpan)
  (editable bool)
  (provenance CompilerSemanticProvenance))

(defstruct CompilerSemanticRecordVec
  (items (__tl_dyn-array CompilerSemanticRecord))
  (live (__tl_dyn-array bool))
  (len i64))

(defenum CompilerSemanticBindingNamespace
  (Value)
  (Type)
  (Macro))

;; One immutable completion-facing row. `display-name` is the spelling visible
;; in the querying module, so a selected import may differ from the defining
;; record's spelling while retaining its stable symbol and source provenance.
(defstruct CompilerSemanticVisibleBinding
  (symbol CompilerSemanticSymbolId)
  (namespace CompilerSemanticBindingNamespace)
  (kind CompilerSemanticSymbolKind)
  (display-name String)
  (resolved-type String)
  (documentation String)
  (module-id i64)
  (definition-span CompilerSemanticSpan)
  (editable bool)
  (provenance CompilerSemanticProvenance))

(defstruct CompilerSemanticTopCandidateRef
  (namespace-tag i64)
  ;; Retained only for equality inside this immutable index. Consumers never
  ;; dereference this compiler-session intern id after construction.
  (name-id i64)
  (label-index i64)
  (record-index i64))

(defstruct CompilerSemanticSourcePathInfo
  (path String)
  (source-len i64)
  (default-module-index i64)
  (module-event-offset i64)
  (module-event-len i64)
  (scope-event-offset i64)
  (scope-event-len i64))

(defstruct CompilerSemanticModuleInfo
  (module-id i64)
  (candidate-offset i64)
  (candidate-len i64))

(defstruct CompilerSemanticModuleEvent
  (path-index i64)
  (byte-offset i64)
  (module-index i64)
  (sequence i64))

(define (compiler-semantic-scope-event-kind-end) : i64
  0)

(define (compiler-semantic-scope-event-kind-start) : i64
  1)

;; Scope events form a persistent-snapshot boundary stream. At a start byte the
;; new head becomes visible; at an end byte the parent head is restored. The
;; child head is retained only to order coincident nested exits/entries.
(defstruct CompilerSemanticScopeEvent
  (path-index i64)
  (byte-offset i64)
  (head i64)
  (kind i64)
  (child-head i64)
  (sequence i64))

(defstruct CompilerSemanticScopeEventVec
  (items (__tl_dyn-array CompilerSemanticScopeEvent))
  (live (__tl_dyn-array bool))
  (len i64))

;; Keep cold construction arrays behind one pointer. CompilerSemanticWalkState
;; is passed through every recursive AST visit, so embedding these fields there
;; would make every visit copy a much wider memory aggregate.
(defstruct CompilerSemanticVisibilityBuildStorage
  (paths (__tl_dyn-array CompilerSemanticSourcePathInfo))
  (path-len (Box i64))
  (modules (__tl_dyn-array CompilerSemanticModuleInfo))
  (module-len (Box i64))
  (module-events (__tl_dyn-array CompilerSemanticModuleEvent))
  (module-event-len (Box i64))
  (scope-events (Box CompilerSemanticScopeEventVec))
  (scope-region-count (Box i64))
  ;; Exact source coordinates for a point near the current declaration. Scope
  ;; boundaries can then translate AST line/column spans without rescanning the
  ;; whole file for every visited expression.
  (source-anchor-offset (Box i64))
  (source-anchor-line (Box i64))
  (source-anchor-col (Box i64)))

(defstruct CompilerSemanticVisibleBindingQuery
  (path-index i64)
  (module-index i64)
  (scope-head i64))

(defenum CompilerSemanticMaybeVisibleBindingQuery
  (Some CompilerSemanticVisibleBindingQuery)
  (None))

(defstruct CompilerSemanticVisibleBindingCursor
  (query CompilerSemanticVisibleBindingQuery)
  (namespace-mask i64)
  (scope-head i64)
  (binding-cursor i64)
  (top-cursor i64)
  (stage i64))

(defenum CompilerSemanticVisibleBindingStep
  (Some CompilerSemanticVisibleBinding CompilerSemanticVisibleBindingCursor)
  (Done))

(defstruct CompilerSemanticBinding
  (name-id i64)
  (symbol CompilerSemanticSymbolId)
  (kind CompilerSemanticSymbolKind)
  (display-name String)
  (resolved-type String)
  (record-index i64)
  (visible CompilerSemanticVisibleBinding)
  (parent i64))

(defstruct CompilerSemanticBindingVec
  (items (__tl_dyn-array CompilerSemanticBinding))
  (live (__tl_dyn-array bool))
  (len i64))

(defstruct CompilerSemanticSourceIndex
  (owner-arena i64)
  (records (__tl_dyn-array CompilerSemanticRecord))
  (len i64)
  ;; One opaque, length-framed owned key per resolved symbol. Occurrences retain
  ;; only `canonical-index`, avoiding repeated module/path/name strings.
  (canonical-symbols (__tl_dyn-array String))
  (canonical-symbol-len i64)
  ;; False identifies current-buffer records established by recovery. It never
  ;; denotes a caller-owned last-good snapshot.
  (complete bool)
  (paths (__tl_dyn-array CompilerSemanticSourcePathInfo))
  (path-len i64)
  (modules (__tl_dyn-array CompilerSemanticModuleInfo))
  (module-len i64)
  (module-events (__tl_dyn-array CompilerSemanticModuleEvent))
  (module-event-len i64)
  (scope-events (__tl_dyn-array CompilerSemanticScopeEvent))
  (scope-event-len i64)
  (scope-region-count i64)
  (bindings (__tl_dyn-array CompilerSemanticBinding))
  (binding-len i64)
  (top-candidates (__tl_dyn-array CompilerSemanticTopCandidateRef))
  (top-labels (__tl_dyn-array String))
  (top-visible-bindings (__tl_dyn-array CompilerSemanticVisibleBinding))
  (top-candidate-len i64))

(defenum ResultCompilerCheckWithSemanticIndex
  (Ok tc.CompilerTypecheckSummary CompilerSemanticSourceIndex)
  (Partial (Box cdiag.CompilerDiagnosticList) CompilerSemanticSourceIndex)
  (Err (Box cdiag.CompilerDiagnosticList)))

(defenum CompilerSemanticMaybeDecl
  (Some i64 CompilerSemanticSymbolKind)
  (None))

(defenum CompilerSemanticMaybeSpan
  (Some ast.AstSourceSpan)
  (None))

(defenum CompilerSemanticMaybeHandle
  (Some i64)
  (None))

(defenum CompilerSemanticMaybeOrigin
  (Some parse_core.CompilerParseSemanticOrigin)
  (None))

;; Transient open-addressed map used only while an owned index is built. The
;; dense compiler identity is safe as a lookup key while the check is live;
;; only the owned canonical strings are published.
(defstruct CompilerSemanticCanonicalBuildSlot
  (occupied bool)
  (symbol CompilerSemanticSymbolId)
  (canonical-index i64))

(defstruct CompilerSemanticCanonicalBuildResult
  (symbols (__tl_dyn-array String))
  (len i64))

;; Snapshot heads share one append-only dense store. Each appended binding
;; remembers the previous head, so child and sibling walks can extend the same
;; store without mutating a parent view or copying its active bindings.
(defstruct CompilerSemanticBindingSnapshot
  (head i64))

(defenum CompilerSemanticMaybeBinding
  (Some CompilerSemanticBinding)
  (None))

(defstruct CompilerSemanticBindResult
  (scope CompilerSemanticBindingSnapshot)
  (env tc.TcTypeEnv)
  (next-search i64))

(defstruct CompilerSemanticWalkState
  (ctx tc.TcContext)
  (top-env tc.TcTypeEnv)
  (path String)
  (source String)
  (form-start i64)
  (module-id i64)
  (declaration-ordinal i64)
  ;; Physical slot in the flattened declaration storage. Unlike the public
  ;; logical ordinal, this matches the successful checker's stable walk key even
  ;; when the retained AstProgram is a non-zero-offset list view.
  (checked-declaration-ordinal i64)
  (declaration-retains-let-facts bool)
  (generated bool)
  (provenance CompilerSemanticProvenance)
  (records (Box CompilerSemanticRecordVec))
  (bindings (Box CompilerSemanticBindingVec))
  (visibility-enabled bool)
  (path-index i64)
  (module-index i64)
  (visibility-storage (Box CompilerSemanticVisibilityBuildStorage))
  (visited-expr-ids (__tl_dyn-array i64))
  (next-local-ordinal (Box i64))
  ;; A complete checked walk must find an exact retained fact for every let.
  ;; Partial indexes deliberately omit locals after the first missing fact;
  ;; complete callers turn this flag into an owned diagnostic and no index.
  (checked-let-fact-mismatch (Box bool))
  ;; Exact parser occurrences are a contiguous run per flattened declaration.
  ;; One cursor per origin kind makes claiming an occurrence amortized O(1)
  ;; while allowing the semantic AST walk to interleave type, member, and
  ;; module references differently from the parser's capture code.
  (semantic-origin-run parse_core.CompilerParseMaybeSemanticOriginRun)
  (semantic-origin-cursors (__tl_dyn-array i64)))

(define (compiler-semantic-origin-kind-tag
  [kind : parse_core.CompilerParseSemanticOriginKind]) : i64
  (match kind
    [(parse_core.CompilerParseSemanticOriginKind.TypeDefinition) 0]
    [(parse_core.CompilerParseSemanticOriginKind.TypeName) 1]
    [(parse_core.CompilerParseSemanticOriginKind.StructFieldDefinition) 2]
    [(parse_core.CompilerParseSemanticOriginKind.EnumVariantDefinition) 3]
    [(parse_core.CompilerParseSemanticOriginKind.StructFieldUse) 4]
    [(parse_core.CompilerParseSemanticOriginKind.EnumVariantPattern) 5]
    [(parse_core.CompilerParseSemanticOriginKind.DispatchFunction) 6]
    [(parse_core.CompilerParseSemanticOriginKind.ModuleDefinition) 7]
    [(parse_core.CompilerParseSemanticOriginKind.ModulePath) 8]
    [(parse_core.CompilerParseSemanticOriginKind.ImportAlias) 9]
    [(parse_core.CompilerParseSemanticOriginKind.ValueQualifier) 10]
    [(parse_core.CompilerParseSemanticOriginKind.ValueName) 11]))

(define (compiler-semantic-origin-cursors-reset!
  [state : (& state CompilerSemanticWalkState)]) : unit
  (let
    [index : i64 0]
    (while (< index (array-length state.semantic-origin-cursors))
      (begin
        (set! (array-ref state.semantic-origin-cursors index) 0)
        (set! index (+ index 1))))))

(define (compiler-semantic-origin-take!
  [state : (& state CompilerSemanticWalkState)]
  [kind : parse_core.CompilerParseSemanticOriginKind]) : CompilerSemanticMaybeOrigin
  (match state.semantic-origin-run
    [(parse_core.CompilerParseMaybeSemanticOriginRun.None)
      CompilerSemanticMaybeOrigin.None]
    [(parse_core.CompilerParseMaybeSemanticOriginRun.Some run)
      (let
        [tag : i64 (compiler-semantic-origin-kind-tag kind)]
        [cursor : i64 (array-ref state.semantic-origin-cursors tag)]
        [count : i64
          (parse_core.compiler-parse-semantic-origin-run-len (& run))]
        (begin
          (while (< cursor count)
            (let
              [origin : parse_core.CompilerParseSemanticOrigin
                (parse_core.compiler-parse-semantic-origin-run-get
                  (& run)
                  cursor
                  (parse_core.compiler-parse-semantic-origin-fallback))]
              (begin
                (set! cursor (+ cursor 1))
                (when
                  (= (compiler-semantic-origin-kind-tag origin.kind) tag)
                  (begin
                    (set! (array-ref state.semantic-origin-cursors tag) cursor)
                    (return (CompilerSemanticMaybeOrigin.Some origin)))))))
          (set! (array-ref state.semantic-origin-cursors tag) cursor)
          CompilerSemanticMaybeOrigin.None))]))

(define (compiler-semantic-origin-take-before!
  [state : CompilerSemanticWalkState]
  [kind : parse_core.CompilerParseSemanticOriginKind]
  [ordinal-limit : i64]) : CompilerSemanticMaybeOrigin
  (match state.semantic-origin-run
    [(parse_core.CompilerParseMaybeSemanticOriginRun.None)
      CompilerSemanticMaybeOrigin.None]
    [(parse_core.CompilerParseMaybeSemanticOriginRun.Some run)
      (let
        [tag : i64 (compiler-semantic-origin-kind-tag kind)]
        [cursor : i64 (array-ref state.semantic-origin-cursors tag)]
        [count : i64
          (parse_core.compiler-parse-semantic-origin-run-len (& run))]
        (begin
          (while (< cursor count)
            (let
              [origin : parse_core.CompilerParseSemanticOrigin
                (parse_core.compiler-parse-semantic-origin-run-get
                  (& run)
                  cursor
                  (parse_core.compiler-parse-semantic-origin-fallback))]
              (if (= (compiler-semantic-origin-kind-tag origin.kind) tag)
                (if (< origin.ordinal ordinal-limit)
                  (begin
                    (set! cursor (+ cursor 1))
                    (set! (array-ref state.semantic-origin-cursors tag) cursor)
                    (return (CompilerSemanticMaybeOrigin.Some origin)))
                  (begin
                    (set! (array-ref state.semantic-origin-cursors tag) cursor)
                    (return CompilerSemanticMaybeOrigin.None)))
                (set! cursor (+ cursor 1)))))
          (set! (array-ref state.semantic-origin-cursors tag) cursor)
          CompilerSemanticMaybeOrigin.None))]))

(define (compiler-semantic-record-fallback) : CompilerSemanticRecord
  (CompilerSemanticRecord
    (CompilerSemanticSymbolId 0 -1 -1)
    -1
    CompilerSemanticRecordRole.Definition
    CompilerSemanticAccess.None
    CompilerSemanticSymbolKind.Value
    ""
    ""
    ""
    0
    (CompilerSemanticSpan "" -1 -1 (ast.ast-source-span 1 1 1 1) 1 1)
    false
    CompilerSemanticProvenance.EditableSource))

(define (compiler-semantic-binding-namespace-value-mask) : i64
  1)

(define (compiler-semantic-binding-namespace-type-mask) : i64
  2)

(define (compiler-semantic-binding-namespace-macro-mask) : i64
  4)

(define (compiler-semantic-binding-namespace-from-tag [tag : i64]) : CompilerSemanticBindingNamespace
  (cond
    [(= tag 2) CompilerSemanticBindingNamespace.Type]
    [(= tag 4) CompilerSemanticBindingNamespace.Macro]
    [else CompilerSemanticBindingNamespace.Value]))

(define (compiler-semantic-binding-namespace-selected? [mask : i64] [tag : i64]) : bool
  (not (= (bit-and mask tag) 0)))

(define (compiler-semantic-visible-binding-fallback) : CompilerSemanticVisibleBinding
  (let
    [record : CompilerSemanticRecord (compiler-semantic-record-fallback)]
    (CompilerSemanticVisibleBinding
      record.symbol
      CompilerSemanticBindingNamespace.Value
      record.kind
      record.display-name
      record.resolved-type
      record.documentation
      record.module-id
      record.span
      record.editable
      record.provenance)))

(define compiler-semantic-source-index-live-owners : i64
  0)

(define (compiler-semantic-source-index-empty) : CompilerSemanticSourceIndex
  (CompilerSemanticSourceIndex
    0
    (__tl_make-array CompilerSemanticRecord 0)
    0
    (__tl_make-array String 0)
    0
    false
    (__tl_make-array CompilerSemanticSourcePathInfo 0)
    0
    (__tl_make-array CompilerSemanticModuleInfo 0)
    0
    (__tl_make-array CompilerSemanticModuleEvent 0)
    0
    (__tl_make-array CompilerSemanticScopeEvent 0)
    0
    0
    (__tl_make-array CompilerSemanticBinding 0)
    0
    (__tl_make-array CompilerSemanticTopCandidateRef 0)
    (__tl_make-array String 0)
    (__tl_make-array CompilerSemanticVisibleBinding 0)
    0))

(define (compiler-semantic-source-index-empty-owned) : CompilerSemanticSourceIndex
  (let
    [owner : i64 (arena.tl_arena_make)]
    (begin
      (set!
        compiler-semantic-source-index-live-owners
        (+ compiler-semantic-source-index-live-owners 1))
      (in-arena
        (arena.Arena owner)
        (CompilerSemanticSourceIndex
          owner
          (__tl_make-array CompilerSemanticRecord 0)
          0
          (__tl_make-array String 0)
          0
          false
          (__tl_make-array CompilerSemanticSourcePathInfo 0)
          0
          (__tl_make-array CompilerSemanticModuleInfo 0)
          0
          (__tl_make-array CompilerSemanticModuleEvent 0)
          0
          (__tl_make-array CompilerSemanticScopeEvent 0)
          0
          0
          (__tl_make-array CompilerSemanticBinding 0)
          0
          (__tl_make-array CompilerSemanticTopCandidateRef 0)
          (__tl_make-array String 0)
          (__tl_make-array CompilerSemanticVisibleBinding 0)
          0)))))

(define (compiler-semantic-binding-snapshot-empty) : CompilerSemanticBindingSnapshot
  (CompilerSemanticBindingSnapshot -1))

(define (compiler-semantic-binding-vec-new [capacity : i64]) : CompilerSemanticBindingVec
  (CompilerSemanticBindingVec
    (__tl_make-array
      CompilerSemanticBinding
      (if (< capacity 1)
        1
        capacity))
    (__tl_make-array
      bool
      (if (< capacity 1)
        1
        capacity))
    0))

(define (compiler-semantic-binding-vec-grow!
  [bindings : (&mut bindings CompilerSemanticBindingVec)]) : unit
  (let
    [old-items : (__tl_dyn-array CompilerSemanticBinding) bindings.items]
    [old-live : (__tl_dyn-array bool) bindings.live]
    [old-capacity : i64 (array-length old-items)]
    [new-capacity : i64
      (if (< old-capacity 1)
        1
        (* old-capacity 2))]
    [new-items : (__tl_dyn-array CompilerSemanticBinding)
      (__tl_make-array CompilerSemanticBinding new-capacity)]
    [new-live : (__tl_dyn-array bool) (__tl_make-array bool new-capacity)]
    [index : i64 0]
    (begin
      (while (< index bindings.len)
        (let
          [taken : (Tuple bool CompilerSemanticBinding)
            (__tl_array-take! old-items old-live index)]
          (begin
            (if (tuple-ref taken 0)
              (begin
                (set! (array-ref new-items index) (tuple-ref taken 1))
                (set! (array-ref new-live index) true))
              unit)
            (set! index (+ index 1)))))
      (set! bindings.items new-items)
      (set! bindings.live new-live))))

(define (compiler-semantic-binding-vec-push!
  [bindings : (&mut bindings CompilerSemanticBindingVec)]
  [binding : CompilerSemanticBinding]) : i64
  (begin
    (if (>= bindings.len (array-length bindings.items))
      (compiler-semantic-binding-vec-grow! bindings)
      unit)
    (let
      [index : i64 bindings.len]
      (begin
        (set! (array-ref bindings.items index) binding)
        (set! (array-ref bindings.live index) true)
        (set! bindings.len (+ index 1))
        index))))

(define (compiler-semantic-scope-event-vec-new [capacity : i64]) : CompilerSemanticScopeEventVec
  (CompilerSemanticScopeEventVec
    (__tl_make-array
      CompilerSemanticScopeEvent
      (if (< capacity 1)
        1
        capacity))
    (__tl_make-array
      bool
      (if (< capacity 1)
        1
        capacity))
    0))

(define (compiler-semantic-scope-event-vec-grow!
  [events : (&mut events CompilerSemanticScopeEventVec)]) : unit
  (let
    [old-items : (__tl_dyn-array CompilerSemanticScopeEvent) events.items]
    [old-live : (__tl_dyn-array bool) events.live]
    [old-capacity : i64 (array-length old-items)]
    [new-capacity : i64
      (if (< old-capacity 1)
        1
        (* old-capacity 2))]
    [new-items : (__tl_dyn-array CompilerSemanticScopeEvent)
      (__tl_make-array CompilerSemanticScopeEvent new-capacity)]
    [new-live : (__tl_dyn-array bool) (__tl_make-array bool new-capacity)]
    [index : i64 0]
    (begin
      (while (< index events.len)
        (let
          [taken : (Tuple bool CompilerSemanticScopeEvent)
            (__tl_array-take! old-items old-live index)]
          (begin
            (if (tuple-ref taken 0)
              (begin
                (set! (array-ref new-items index) (tuple-ref taken 1))
                (set! (array-ref new-live index) true))
              unit)
            (set! index (+ index 1)))))
      (set! events.items new-items)
      (set! events.live new-live))))

(define (compiler-semantic-scope-event-vec-push!
  [events : (&mut events CompilerSemanticScopeEventVec)]
  [event : CompilerSemanticScopeEvent]) : unit
  (begin
    (if (>= events.len (array-length events.items))
      (compiler-semantic-scope-event-vec-grow! events)
      unit)
    (set! (array-ref events.items events.len) event)
    (set! (array-ref events.live events.len) true)
    (set! events.len (+ events.len 1))))

(define (compiler-semantic-module-index-find
  [modules : (& modules (__tl_dyn-array CompilerSemanticModuleInfo))]
  [module-len : i64]
  [module-id : i64]) : i64
  (let
    [index : i64 0]
    (begin
      (while (< index module-len)
        (if (or
          (= (array-ref modules index).module-id module-id)
          (and
            (csym.compiler-symbol-root-module-id?
              (array-ref modules index).module-id)
            (csym.compiler-symbol-root-module-id? module-id)))
          (return index)
          (set! index (+ index 1))))
      -1)))

(define (compiler-semantic-module-index-ensure!
  [state : (& state CompilerSemanticWalkState)]
  [module-id : i64]) : i64
  (let
    [module-len : i64
      (__tl-box-place
        (__tl-project-field
          (__tl-box-place state.visibility-storage)
          module-len))]
    [found : i64
      (compiler-semantic-module-index-find
        (&
          (__tl-project-field (__tl-box-place state.visibility-storage) modules))
        module-len
        module-id)]
    (if (>= found 0)
      found
      (if (>=
        module-len
        (array-length
          (__tl-project-field (__tl-box-place state.visibility-storage) modules)))
        -1
        (begin
          (set!
            (array-ref
              (__tl-project-field
                (__tl-box-place state.visibility-storage)
                modules)
              module-len)
            (CompilerSemanticModuleInfo module-id 0 0))
          (set!
            (deref
              (__tl-project-field
                (__tl-box-place state.visibility-storage)
                module-len))
            (+ module-len 1))
          module-len)))))

(define (compiler-semantic-path-index-find
  [paths : (& paths (__tl_dyn-array CompilerSemanticSourcePathInfo))]
  [path-len : i64]
  [path : String]) : i64
  (let
    [index : i64 0]
    (begin
      (while (< index path-len)
        (if (string.eq (array-ref paths index).path path)
          (return index)
          (set! index (+ index 1))))
      -1)))

(define (compiler-semantic-module-event-push!
  [state : (& state CompilerSemanticWalkState)]
  [path-index : i64]
  [byte-offset : i64]
  [module-index : i64]) : unit
  (if (or
    (not state.visibility-enabled)
    (< path-index 0)
    (< module-index 0)
    (< byte-offset 0))
    unit
    (let
      [event-index : i64
        (__tl-box-place
          (__tl-project-field
            (__tl-box-place state.visibility-storage)
            module-event-len))]
      (if (>=
        event-index
        (array-length
          (__tl-project-field
            (__tl-box-place state.visibility-storage)
            module-events)))
        unit
        (if (and
          (> event-index 0)
          (=
            (array-ref
              (__tl-project-field
                (__tl-box-place state.visibility-storage)
                module-events)
              (- event-index 1)).path-index
            path-index)
          (=
            (array-ref
              (__tl-project-field
                (__tl-box-place state.visibility-storage)
                module-events)
              (- event-index 1)).module-index
            module-index))
          unit
          (begin
            (set!
              (array-ref
                (__tl-project-field
                  (__tl-box-place state.visibility-storage)
                  module-events)
                event-index)
              (CompilerSemanticModuleEvent
                path-index
                byte-offset
                module-index
                event-index))
            (set!
              (deref
                (__tl-project-field
                  (__tl-box-place state.visibility-storage)
                  module-event-len))
              (+ event-index 1))))))))

(define (compiler-semantic-path-index-ensure!
  [state : (& state CompilerSemanticWalkState)]
  [path : (& path str)]
  [source-len : i64]
  [module-index : i64]) : i64
  (if (or (not state.visibility-enabled) (string.eq path ""))
    -1
    (let
      [normalized : String (cload.compiler-load-normalize-path path)]
      [path-len : i64
        (__tl-box-place
          (__tl-project-field
            (__tl-box-place state.visibility-storage)
            path-len))]
      [found : i64
        (compiler-semantic-path-index-find
          (&
            (__tl-project-field (__tl-box-place state.visibility-storage) paths))
          path-len
          (owned_view.compiler-owned-shared-view normalized))]
      (if (>= found 0)
        (let
          [info : CompilerSemanticSourcePathInfo
            (owned_view.compiler-owned-array-element-shared-view
              (__tl-project-field
                (__tl-box-place state.visibility-storage)
                paths)
              found)]
          (begin
            (if (> source-len info.source-len)
              (begin
                (set! info.source-len source-len)
                (set!
                  (array-ref
                    (__tl-project-field
                      (__tl-box-place state.visibility-storage)
                      paths)
                    found)
                  info))
              unit)
            found))
        (if (>=
          path-len
          (array-length
            (__tl-project-field (__tl-box-place state.visibility-storage) paths)))
          -1
          (begin
            (set!
              (array-ref
                (__tl-project-field
                  (__tl-box-place state.visibility-storage)
                  paths)
                path-len)
              (CompilerSemanticSourcePathInfo
                (string.copy (& normalized))
                source-len
                module-index
                0
                0
                0
                0))
            (set!
              (deref
                (__tl-project-field
                  (__tl-box-place state.visibility-storage)
                  path-len))
              (+ path-len 1))
            (compiler-semantic-module-event-push! state path-len 0 module-index)
            path-len))))))

(define (compiler-semantic-scope-region-add!
  [state : (& state CompilerSemanticWalkState)]
  [parent : CompilerSemanticBindingSnapshot]
  [child : CompilerSemanticBindingSnapshot]
  [start-byte : i64]
  [end-byte : i64]) : unit
  (if (or
    (not state.visibility-enabled)
    (< state.path-index 0)
    (= parent.head child.head)
    (< start-byte 0)
    (<= end-byte start-byte)
    (> end-byte (string.string-length state.source)))
    unit
    (let
      [start-sequence : i64
        (__tl-project-field
          (__tl-box-place
            (__tl-project-field
              (__tl-box-place state.visibility-storage)
              scope-events))
          len)]
      (begin
        (compiler-semantic-scope-event-vec-push!
          (&mut
            (__tl-box-place
              (__tl-project-field
                (__tl-box-place state.visibility-storage)
                scope-events)))
          (CompilerSemanticScopeEvent
            state.path-index
            start-byte
            child.head
            (compiler-semantic-scope-event-kind-start)
            child.head
            start-sequence))
        (compiler-semantic-scope-event-vec-push!
          (&mut
            (__tl-box-place
              (__tl-project-field
                (__tl-box-place state.visibility-storage)
                scope-events)))
          (CompilerSemanticScopeEvent
            state.path-index
            end-byte
            parent.head
            (compiler-semantic-scope-event-kind-end)
            child.head
            (+ start-sequence 1)))
        (set!
          (deref
            (__tl-project-field
              (__tl-box-place state.visibility-storage)
              scope-region-count))
          (+
            (__tl-box-place
              (__tl-project-field
                (__tl-box-place state.visibility-storage)
                scope-region-count))
            1))))))

(define (compiler-semantic-scope-node-region-add!
  [state : CompilerSemanticWalkState]
  [parent : CompilerSemanticBindingSnapshot]
  [child : CompilerSemanticBindingSnapshot]
  [node-id : i64]) : unit
  (let
    [start-byte : i64 (compiler-semantic-expr-start-offset state node-id -1)]
    [raw-end : i64
      (compiler-semantic-expr-visibility-end-offset
        (owned_view.compiler-owned-shared-view state)
        node-id
        -1)]
    (compiler-semantic-scope-region-add! state parent child start-byte raw-end)))

(define (compiler-semantic-record-vec-new [capacity : i64]) : CompilerSemanticRecordVec
  (CompilerSemanticRecordVec
    (__tl_make-array
      CompilerSemanticRecord
      (if (< capacity 1)
        1
        capacity))
    (__tl_make-array
      bool
      (if (< capacity 1)
        1
        capacity))
    0))

(define (compiler-semantic-record-vec-grow!
  [records : (&mut records CompilerSemanticRecordVec)]) : unit
  (let
    [old-items : (__tl_dyn-array CompilerSemanticRecord) records.items]
    [old-live : (__tl_dyn-array bool) records.live]
    [old-capacity : i64 (array-length old-items)]
    [new-capacity : i64
      (if (< old-capacity 1)
        1
        (* old-capacity 2))]
    [new-items : (__tl_dyn-array CompilerSemanticRecord)
      (__tl_make-array CompilerSemanticRecord new-capacity)]
    [new-live : (__tl_dyn-array bool) (__tl_make-array bool new-capacity)]
    [index : i64 0]
    (begin
      (while (< index records.len)
        (let
          [taken : (Tuple bool CompilerSemanticRecord)
            (__tl_array-take! old-items old-live index)]
          (begin
            (if (tuple-ref taken 0)
              (begin
                (set! (array-ref new-items index) (tuple-ref taken 1))
                (set! (array-ref new-live index) true))
              unit)
            (set! index (+ index 1)))))
      (set! records.items new-items)
      (set! records.live new-live))))

(define (compiler-semantic-record-vec-push-index!
  [records : (&mut records CompilerSemanticRecordVec)]
  [record : CompilerSemanticRecord]) : i64
  (begin
    (if (>= records.len (array-length records.items))
      (compiler-semantic-record-vec-grow! records)
      unit)
    (let
      [index : i64 records.len]
      (begin
        (set! (array-ref records.items index) record)
        (set! (array-ref records.live index) true)
        (set! records.len (+ index 1))
        index))))

(define (compiler-semantic-record-vec-push!
  [records : (&mut records CompilerSemanticRecordVec)]
  [record : CompilerSemanticRecord]) : unit
  (begin
    (compiler-semantic-record-vec-push-index! records record)
    unit))

(define (compiler-semantic-source-index-len
  [index : (& index CompilerSemanticSourceIndex)]) : i64
  index.len)

(define (compiler-semantic-source-index-get
  [index : (& index CompilerSemanticSourceIndex)]
  [record-index : i64]) : CompilerSemanticRecord
  (if (and (>= record-index 0) (< record-index index.len))
    (array-ref index.records record-index)
    (compiler-semantic-record-fallback)))

(define (compiler-semantic-source-index-complete?
  [index : (& index CompilerSemanticSourceIndex)]) : bool
  index.complete)

;; Canonical keys are opaque and versioned. Equality is their only contract;
;; consumers must not parse their length-framed representation.
(define (compiler-semantic-source-index-canonical-key
  [index : (& index CompilerSemanticSourceIndex)]
  [canonical-index : i64]) : String
  (if (and
    (>= canonical-index 0)
    (< canonical-index index.canonical-symbol-len))
    (array-ref index.canonical-symbols canonical-index)
    ""))

(define (compiler-semantic-source-index-record-canonical-key
  [index : (& index CompilerSemanticSourceIndex)]
  [record : (& record CompilerSemanticRecord)]) : String
  (compiler-semantic-source-index-canonical-key index record.canonical-index))

(define (compiler-semantic-source-index-release!
  [index : (&mut index CompilerSemanticSourceIndex)]) : unit
  (let
    [owner : i64 index.owner-arena]
    (if (> owner 0)
      (begin
        (set! index.owner-arena 0)
        (set! index.len 0)
        (set! index.canonical-symbol-len 0)
        (set! index.complete false)
        (set! index.path-len 0)
        (set! index.module-len 0)
        (set! index.module-event-len 0)
        (set! index.scope-event-len 0)
        (set! index.scope-region-count 0)
        (set! index.binding-len 0)
        (set! index.top-candidate-len 0)
        (set!
          compiler-semantic-source-index-live-owners
          (- compiler-semantic-source-index-live-owners 1))
        (unsafe
          (arena.tl_arena_destroy owner)))
      unit)))

;; Query whether this immutable snapshot was resolved with `path` in its entry
;; or import closure. LSP cache invalidation uses this instead of exposing the
;; owned path table or retaining a duplicate dependency graph.
(define (compiler-semantic-source-index-contains-path?
  [index : (& index CompilerSemanticSourceIndex)]
  [path : String]) : bool
  (let
    [normalized : String (cload.compiler-load-canonical-path path)]
    [path-index : i64 0]
    [found : bool false]
    (begin
      (while (and (< path-index index.path-len) (not found))
        (let
          [info : CompilerSemanticSourcePathInfo
            (owned_view.compiler-owned-array-element-shared-view
              index.paths
              path-index)]
          [owned-path : String (string.copy (& info.path))]
          (begin
            (if (string.eq
              (cload.compiler-load-canonical-path owned-path)
              normalized)
              (set! found true)
              unit)
            (set! path-index (+ path-index 1)))))
      found)))

(define (compiler-semantic-source-index-query
  [index : (& index CompilerSemanticSourceIndex)]
  [path : String]
  [byte-offset : i64]) : CompilerSemanticMaybeVisibleBindingQuery
  ;; Recovery indexes retain only identities and visibility boundaries proven
  ;; against the current buffer.  They are therefore safe for completion even
  ;; though consumers that require a fully checked program still distinguish
  ;; them through `compiler-semantic-source-index-complete?`.
  (if (or (<= index.owner-arena 0) (< byte-offset 0))
    CompilerSemanticMaybeVisibleBindingQuery.None
    (let
      [normalized : String (cload.compiler-load-normalize-path path)]
      [path-index : i64
        (compiler-semantic-path-index-find
          (& index.paths)
          index.path-len
          normalized)]
      (if (< path-index 0)
        CompilerSemanticMaybeVisibleBindingQuery.None
        (let
          [info : CompilerSemanticSourcePathInfo
            (owned_view.compiler-owned-array-element-shared-view
              index.paths
              path-index)]
          (if (> byte-offset info.source-len)
            CompilerSemanticMaybeVisibleBindingQuery.None
            (let
              [scope-low : i64 0]
              [scope-high : i64 info.scope-event-len]
              [module-low : i64 0]
              [module-high : i64 info.module-event-len]
              (begin
                (while (< scope-low scope-high)
                  (let
                    [mid : i64 (/ (+ scope-low scope-high) 2)]
                    [event : CompilerSemanticScopeEvent
                      (owned_view.compiler-owned-array-element-shared-view
                        index.scope-events
                        (+ info.scope-event-offset mid))]
                    (if (<= event.byte-offset byte-offset)
                      (set! scope-low (+ mid 1))
                      (set! scope-high mid))))
                (while (< module-low module-high)
                  (let
                    [mid : i64 (/ (+ module-low module-high) 2)]
                    [event : CompilerSemanticModuleEvent
                      (owned_view.compiler-owned-array-element-shared-view
                        index.module-events
                        (+ info.module-event-offset mid))]
                    (if (<= event.byte-offset byte-offset)
                      (set! module-low (+ mid 1))
                      (set! module-high mid))))
                (CompilerSemanticMaybeVisibleBindingQuery.Some
                  (CompilerSemanticVisibleBindingQuery
                    path-index
                    (if (> module-low 0)
                      (owned_view.compiler-owned-array-element-shared-view
                        index.module-events
                        (+ info.module-event-offset (- module-low 1))).module-index
                      info.default-module-index)
                    (if (> scope-low 0)
                      (owned_view.compiler-owned-array-element-shared-view
                        index.scope-events
                        (+ info.scope-event-offset (- scope-low 1))).head
                      -1)))))))))))

(define (compiler-semantic-visible-binding-owned-copy
  [record : (& record CompilerSemanticRecord)]
  [namespace-tag : i64]
  [display-name : (& display-name str)]) : CompilerSemanticVisibleBinding
  (CompilerSemanticVisibleBinding
    (CompilerSemanticSymbolId
      record.symbol.module-id
      record.symbol.declaration-ordinal
      record.symbol.local-ordinal)
    (compiler-semantic-binding-namespace-from-tag namespace-tag)
    (match record.kind
      [(CompilerSemanticSymbolKind.Value) CompilerSemanticSymbolKind.Value]
      [(CompilerSemanticSymbolKind.Function)
        CompilerSemanticSymbolKind.Function]
      [(CompilerSemanticSymbolKind.Macro) CompilerSemanticSymbolKind.Macro]
      [(CompilerSemanticSymbolKind.ExternValue)
        CompilerSemanticSymbolKind.ExternValue]
      [(CompilerSemanticSymbolKind.ExternFunction)
        CompilerSemanticSymbolKind.ExternFunction]
      [(CompilerSemanticSymbolKind.Struct) CompilerSemanticSymbolKind.Struct]
      [(CompilerSemanticSymbolKind.Enum) CompilerSemanticSymbolKind.Enum]
      [(CompilerSemanticSymbolKind.Module) CompilerSemanticSymbolKind.Module]
      [(CompilerSemanticSymbolKind.Field) CompilerSemanticSymbolKind.Field]
      [(CompilerSemanticSymbolKind.EnumMember)
        CompilerSemanticSymbolKind.EnumMember]
      [(CompilerSemanticSymbolKind.Parameter)
        CompilerSemanticSymbolKind.Parameter]
      [(CompilerSemanticSymbolKind.Local) CompilerSemanticSymbolKind.Local])
    (string.copy display-name)
    (string.copy (& record.resolved-type))
    (string.copy (& record.documentation))
    record.module-id
    (CompilerSemanticSpan
      (string.copy (& record.span.path))
      record.span.start-byte
      record.span.end-byte
      (ast.ast-source-span
        (cast record.span.source.start-line : i64)
        (cast record.span.source.start-col : i64)
        (cast record.span.source.end-line : i64)
        (cast record.span.source.end-col : i64))
      record.span.utf16-start-col
      record.span.utf16-end-col)
    record.editable
    (match record.provenance
      [(CompilerSemanticProvenance.EditableSource)
        CompilerSemanticProvenance.EditableSource]
      [(CompilerSemanticProvenance.Generated generator item key)
        (CompilerSemanticProvenance.Generated
          (string.copy (& generator))
          (string.copy (& item))
          (string.copy (& key)))])))

(define (compiler-semantic-top-visible-bindings-fill!
  [records : (& records (__tl_dyn-array CompilerSemanticRecord))]
  [candidates : (& candidates (__tl_dyn-array CompilerSemanticTopCandidateRef))]
  [labels : (& labels (__tl_dyn-array String))]
  [candidate-len : i64]
  [out : (&mut out (__tl_dyn-array CompilerSemanticVisibleBinding))]) : unit
  (let
    [index : i64 0]
    (while (< index candidate-len)
      (let
        [candidate : CompilerSemanticTopCandidateRef
          (array-ref candidates index)]
        (begin
          (set!
            (array-ref out index)
            (compiler-semantic-visible-binding-owned-copy
              (& (array-ref records candidate.record-index))
              candidate.namespace-tag
              (& (array-ref labels candidate.label-index))))
          (set! index (+ index 1)))))))

(define (compiler-semantic-binding-shadowed-before?
  [index : (& index CompilerSemanticSourceIndex)]
  [scope-head : i64]
  [binding-index : i64]
  [name-id : i64]) : bool
  (let
    [cursor : i64 scope-head]
    (begin
      (while (and (>= cursor 0) (!= cursor binding-index))
        (let
          [binding : CompilerSemanticBinding
            (owned_view.compiler-owned-array-element-shared-view
              index.bindings
              cursor)]
          (if (= binding.name-id name-id)
            (return true)
            (set! cursor binding.parent))))
      false)))

(define (compiler-semantic-source-index-local-visible-binding-get
  [index : (& index CompilerSemanticSourceIndex)]
  [binding-index : i64]) : CompilerSemanticVisibleBinding
  (if (and (>= binding-index 0) (< binding-index index.binding-len))
    (array-ref index.bindings binding-index).visible
    (compiler-semantic-visible-binding-fallback)))

(define (compiler-semantic-source-index-top-visible-binding-get
  [index : (& index CompilerSemanticSourceIndex)]
  [candidate-index : i64]) : CompilerSemanticVisibleBinding
  (if (and (>= candidate-index 0) (< candidate-index index.top-candidate-len))
    (array-ref index.top-visible-bindings candidate-index)
    (compiler-semantic-visible-binding-fallback)))

(define (compiler-semantic-scope-has-name?
  [index : (& index CompilerSemanticSourceIndex)]
  [scope-head : i64]
  [name-id : i64]) : bool
  (let
    [cursor : i64 scope-head]
    (begin
      (while (>= cursor 0)
        (let
          [binding : CompilerSemanticBinding
            (owned_view.compiler-owned-array-element-shared-view
              index.bindings
              cursor)]
          (if (= binding.name-id name-id)
            (return true)
            (set! cursor binding.parent))))
      false)))

(define (compiler-semantic-visible-binding-query-valid?
  [index : (& index CompilerSemanticSourceIndex)]
  [query : CompilerSemanticVisibleBindingQuery]) : bool
  (and
    (> index.owner-arena 0)
    (>= query.path-index 0)
    (< query.path-index index.path-len)
    (>= query.module-index 0)
    (< query.module-index index.module-len)
    (>= query.scope-head -1)
    (< query.scope-head index.binding-len)))

(define (compiler-semantic-visible-binding-cursor
  [index : (& index CompilerSemanticSourceIndex)]
  [query : CompilerSemanticVisibleBindingQuery]
  [namespace-mask : i64]) : CompilerSemanticVisibleBindingCursor
  (if (not (compiler-semantic-visible-binding-query-valid? index query))
    (CompilerSemanticVisibleBindingCursor query namespace-mask -1 -1 0 2)
    (CompilerSemanticVisibleBindingCursor
      query
      namespace-mask
      query.scope-head
      query.scope-head
      (array-ref index.modules query.module-index).candidate-offset
      0)))

(define (compiler-semantic-visible-binding-cursor-step
  [index : (& index CompilerSemanticSourceIndex)]
  [cursor : CompilerSemanticVisibleBindingCursor]) : CompilerSemanticVisibleBindingStep
  (if (not (compiler-semantic-visible-binding-query-valid? index cursor.query))
    CompilerSemanticVisibleBindingStep.Done
    (let
      [next : CompilerSemanticVisibleBindingCursor
        (CompilerSemanticVisibleBindingCursor
          (CompilerSemanticVisibleBindingQuery
            cursor.query.path-index
            cursor.query.module-index
            cursor.query.scope-head)
          cursor.namespace-mask
          cursor.scope-head
          cursor.binding-cursor
          cursor.top-cursor
          cursor.stage)]
      [module-info : CompilerSemanticModuleInfo
        (owned_view.compiler-owned-array-element-shared-view
          index.modules
          cursor.query.module-index)]
      [top-end : i64 (+ module-info.candidate-offset module-info.candidate-len)]
      (begin
        (cond
          [(or
              (< next.stage 0)
              (> next.stage 2)
              (< next.binding-cursor -1)
              (>= next.binding-cursor index.binding-len)
              (and
                (= next.stage 1)
                (or
                  (< next.top-cursor module-info.candidate-offset)
                  (> next.top-cursor top-end))))
            (return CompilerSemanticVisibleBindingStep.Done)]
          [else unit])
        (while (= next.stage 0)
          (if (< next.binding-cursor 0)
            (begin
              (set! next.stage 1)
              (set! next.top-cursor module-info.candidate-offset))
            (let
              [binding-index : i64 next.binding-cursor]
              [binding : CompilerSemanticBinding
                (owned_view.compiler-owned-array-element-shared-view
                  index.bindings
                  binding-index)]
              (begin
                (set! next.binding-cursor binding.parent)
                (cond
                  [(and
                      (compiler-semantic-binding-namespace-selected?
                        next.namespace-mask
                        (compiler-semantic-binding-namespace-value-mask))
                      (not
                        (compiler-semantic-binding-shadowed-before?
                          index
                          next.scope-head
                          binding-index
                          binding.name-id)))
                    (return
                      (CompilerSemanticVisibleBindingStep.Some
                        (compiler-semantic-source-index-local-visible-binding-get
                          index
                          binding-index)
                        next))]
                  [else unit])))))
        (while (and (= next.stage 1) (< next.top-cursor top-end))
          (let
            [candidate : CompilerSemanticTopCandidateRef
              (owned_view.compiler-owned-array-element-shared-view
                index.top-candidates
                next.top-cursor)]
            (begin
              (set! next.top-cursor (+ next.top-cursor 1))
              (cond
                [(and
                    (compiler-semantic-binding-namespace-selected?
                      next.namespace-mask
                      candidate.namespace-tag)
                    (not
                      (and
                        (=
                          candidate.namespace-tag
                          (compiler-semantic-binding-namespace-value-mask))
                        (compiler-semantic-scope-has-name?
                          index
                          next.scope-head
                          candidate.name-id))))
                  (return
                    (CompilerSemanticVisibleBindingStep.Some
                      (compiler-semantic-source-index-top-visible-binding-get
                        index
                        (- next.top-cursor 1))
                      next))]
                [else unit]))))
        (set! next.stage 2)
        CompilerSemanticVisibleBindingStep.Done))))

(define (compiler-semantic-decl-symbol [decl : ast.AstDecl]) : CompilerSemanticMaybeDecl
  (match decl
    [(ast.AstDecl.Def _ name _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Value)]
    [(ast.AstDecl.DefFn _ name _ _ _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Function)]
    [(ast.AstDecl.DefMacro _ name _ _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Macro)]
    [(ast.AstDecl.Extern _ name kind _ _)
      (CompilerSemanticMaybeDecl.Some
        name
        (match kind
          [(ast.AstExternKind.Value) CompilerSemanticSymbolKind.ExternValue]
          [(ast.AstExternKind.Function)
            CompilerSemanticSymbolKind.ExternFunction]))]
    [(ast.AstDecl.DefEnum _ name _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Enum)]
    [(ast.AstDecl.DefEnumLifetimes _ name _ _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Enum)]
    [(ast.AstDecl.DefStruct _ name _ _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Struct)]
    [(ast.AstDecl.DefStructLifetimes _ name _ _ _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Struct)]
    [(ast.AstDecl.DefDispatch _ name _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Function)]
    [(ast.AstDecl.Unsafe inner) (compiler-semantic-decl-symbol (deref inner))]
    [_ CompilerSemanticMaybeDecl.None]))

(define (compiler-semantic-source-offset
  [source : (& source str)]
  [target-line : i64]
  [target-col : i64]) : i64
  (let
    [index : i64 0]
    [line : i64 1]
    [col : i64 1]
    [len : i64 (string.string-length source)]
    (begin
      (while (and
        (< index len)
        (or (< line target-line) (and (= line target-line) (< col target-col))))
        (begin
          (if (= (string.string-ref source index) '\n')
            (begin
              (set! line (+ line 1))
              (set! col 1))
            (set! col (+ col 1)))
          (set! index (+ index 1))))
      index)))

(define (compiler-semantic-state-source-offset
  [state : CompilerSemanticWalkState]
  [target-line : i64]
  [target-col : i64]) : i64
  (let
    [storage : CompilerSemanticVisibilityBuildStorage
      (owned_view.compiler-owned-box-shared-view state.visibility-storage)]
    [anchor-offset : i64 (deref storage.source-anchor-offset)]
    [anchor-line : i64 (deref storage.source-anchor-line)]
    [anchor-col : i64 (deref storage.source-anchor-col)]
    [source-len : i64 (string.string-length state.source)]
    [usable : bool
      (and
        (>= anchor-offset 0)
        (<= anchor-offset source-len)
        (or
          (> target-line anchor-line)
          (and (= target-line anchor-line) (>= target-col anchor-col))))]
    (if (not usable)
      (compiler-semantic-source-offset state.source target-line target-col)
      (if (= target-line anchor-line)
        (let
          [offset : i64 (+ anchor-offset (- target-col anchor-col))]
          (cond
            [(< offset 0) 0]
            [(> offset source-len) source-len]
            [else offset]))
        (let
          [index : i64 anchor-offset]
          [line : i64 anchor-line]
          [col : i64 anchor-col]
          (begin
            (while (and
              (< index source-len)
              (or
                (< line target-line)
                (and (= line target-line) (< col target-col))))
              (begin
                (if (= (string.string-ref state.source index) '\n')
                  (begin
                    (set! line (+ line 1))
                    (set! col 1))
                  (set! col (+ col 1)))
                (set! index (+ index 1))))
            index))))))

(define (compiler-semantic-source-anchor-set!
  [state : (& state CompilerSemanticWalkState)]
  [offset : i64]
  [line : i64]
  [col : i64]) : unit
  (begin
    (set!
      (deref
        (__tl-project-field
          (__tl-box-place state.visibility-storage)
          source-anchor-offset))
      offset)
    (set!
      (deref
        (__tl-project-field
          (__tl-box-place state.visibility-storage)
          source-anchor-line))
      line)
    (set!
      (deref
        (__tl-project-field
          (__tl-box-place state.visibility-storage)
          source-anchor-col))
      col)))

(define (compiler-semantic-source-position
  [source : (& source str)]
  [target : i64]) : ast.AstSourceSpan
  (let
    [index : i64 0]
    [line : i64 1]
    [col : i64 1]
    [limit : i64
      (if (< target (string.string-length source))
        target
        (string.string-length source))]
    (begin
      (while (< index limit)
        (begin
          (if (= (string.string-ref source index) '\n')
            (begin
              (set! line (+ line 1))
              (set! col 1))
            (set! col (+ col 1)))
          (set! index (+ index 1))))
      (ast.ast-source-span line col line col))))

(define (compiler-semantic-utf8-continuation-byte? [c : char]) : bool
  (= (bit-and (cast c : i64) 192) 128))

(define (compiler-semantic-utf16-units-for-byte [c : char]) : i64
  (let
    [byte : i64 (cast c : i64)]
    (cond
      [(compiler-semantic-utf8-continuation-byte? c) 0]
      [(>= byte 240) 2]
      [else 1])))

;; One-based UTF-16 column at a byte offset. Scanning only the containing line
;; keeps this metadata construction bounded by line length rather than source
;; length for every semantic record.
(define (compiler-semantic-source-utf16-col-at-offset
  [source : String]
  [target : i64]) : i64
  (let
    [source-len : i64 (string.string-length source)]
    [limit : i64
      (cond [(< target 0) 0] [(> target source-len) source-len] [else target])]
    [line-start : i64 limit]
    [cursor : i64 0]
    [col : i64 1]
    (begin
      (while (and
        (> line-start 0)
        (not (= (string.string-ref source (- line-start 1)) '\n')))
        (set! line-start (- line-start 1)))
      (set! cursor line-start)
      (while (< cursor limit)
        (begin
          (set!
            col
            (+
              col
              (compiler-semantic-utf16-units-for-byte
                (string.string-ref source cursor))))
          (set! cursor (+ cursor 1))))
      col)))

(define (compiler-semantic-span-from-byte-range
  [path : (& path str)]
  [source : String]
  [start : i64]
  [end : i64]
  [source-span : ast.AstSourceSpan]) : CompilerSemanticSpan
  (CompilerSemanticSpan
    (string.copy path)
    start
    end
    source-span
    (compiler-semantic-source-utf16-col-at-offset
      (owned_view.compiler-owned-shared-view source)
      start)
    (compiler-semantic-source-utf16-col-at-offset source end)))

(define (compiler-semantic-delimiter? [c : char]) : bool
  (or
    (= c ' ')
    (= c '\t')
    (= c '\r')
    (= c '\n')
    (= c '(')
    (= c ')')
    (= c '[')
    (= c ']')
    (= c '{')
    (= c '}')))

(define (compiler-semantic-source-name-at?
  [source : (& source str)]
  [name : (& name str)]
  [start : i64]
  [limit : i64]) : bool
  (let
    [name-len : i64 (string.string-length name)]
    [offset : i64 0]
    [matches : bool true]
    (begin
      (if (or
        (> (+ start name-len) limit)
        (and
          (> start 0)
          (not
            (compiler-semantic-delimiter?
              (string.string-ref source (- start 1)))))
        (and
          (< (+ start name-len) (string.string-length source))
          (< (+ start name-len) limit)
          (not
            (compiler-semantic-delimiter?
              (string.string-ref source (+ start name-len))))))
        (set! matches false)
        unit)
      (while (and matches (< offset name-len))
        (if (=
          (string.string-ref source (+ start offset))
          (string.string-ref name offset))
          (set! offset (+ offset 1))
          (set! matches false)))
      matches)))

(define (compiler-semantic-single-quote-end
  [source : (& source str)]
  [start : i64]
  [limit : i64]) : i64
  (cond
    [(and
        (<= (+ start 2) limit)
        (not (= (string.string-ref source (+ start 1)) '\\'))
        (= (string.string-ref source (+ start 2)) '\''))
      (+ start 2)]
    [(and
        (<= (+ start 3) limit)
        (= (string.string-ref source (+ start 1)) '\\')
        (= (string.string-ref source (+ start 3)) '\''))
      (+ start 3)]
    [else -1]))

(define (compiler-semantic-double-quote-end
  [source : (& source str)]
  [start : i64]
  [limit : i64]) : i64
  (let
    [cursor : i64 (+ start 1)]
    [escaped : bool false]
    [done : bool false]
    (begin
      (while (and (not done) (< cursor limit))
        (let
          [current : char (string.string-ref source cursor)]
          (begin
            (set! cursor (+ cursor 1))
            (if (and (not escaped) (= current '"'))
              (set! done true)
              (set! escaped (and (not escaped) (= current '\\')))))))
      cursor)))

(define (compiler-semantic-name-offset-in-range
  [source : (& source str)]
  [name : (& name str)]
  [start : i64]
  [limit : i64]) : i64
  (let
    [cursor : i64
      (if (< start 0)
        0
        start)]
    [bounded-limit : i64
      (if (> limit (string.string-length source))
        (string.string-length source)
        limit)]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< cursor bounded-limit))
        (let
          [current : char (string.string-ref source cursor)]
          (cond
            [(= current ';')
              (begin
                (while (and
                  (< cursor bounded-limit)
                  (not (= (string.string-ref source cursor) '\n')))
                  (set! cursor (+ cursor 1)))
                (set! cursor (+ cursor 1)))]
            [(= current '"')
              (set!
                cursor
                (compiler-semantic-double-quote-end source cursor bounded-limit))]
            [(= current '\'')
              (let
                [char-end : i64
                  (compiler-semantic-single-quote-end
                    source
                    cursor
                    (- bounded-limit 1))]
                (if (>= char-end 0)
                  (set! cursor (+ char-end 1))
                  (set! cursor (+ cursor 1))))]
            [(compiler-semantic-source-name-at?
                source
                name
                cursor
                bounded-limit)
              (set! found cursor)]
            [else (set! cursor (+ cursor 1))])))
      found)))

(define (compiler-semantic-top-level-form-start
  [source : (& source str)]
  [before : i64]
  [search-start : i64]) : i64
  (let
    [source-len : i64 (string.string-length source)]
    [limit : i64
      (cond
        [(= source-len 0) -1]
        [(< before 0) 0]
        [(< before source-len) before]
        [else (- source-len 1)])]
    [cursor : i64
      (if (and (>= search-start 0) (<= search-start limit))
        search-start
        0)]
    [depth : i64 0]
    [found : i64 0]
    (begin
      (while (<= cursor limit)
        (let
          [current : char (string.string-ref source cursor)]
          (cond
            [(= current ';')
              (begin
                (while (and
                  (<= cursor limit)
                  (not (= (string.string-ref source cursor) '\n')))
                  (set! cursor (+ cursor 1)))
                (set! cursor (+ cursor 1)))]
            [(= current '"')
              (set!
                cursor
                (compiler-semantic-double-quote-end source cursor (+ limit 1)))]
            [(= current '\'')
              (let
                [char-end : i64
                  (compiler-semantic-single-quote-end source cursor limit)]
                (if (>= char-end 0)
                  (set! cursor (+ char-end 1))
                  (set! cursor (+ cursor 1))))]
            [(= current '(')
              (begin
                (if (= depth 0)
                  (set! found cursor)
                  unit)
                (set! depth (+ depth 1))
                (set! cursor (+ cursor 1)))]
            [(= current ')')
              (begin
                (if (> depth 0)
                  (set! depth (- depth 1))
                  unit)
                (set! cursor (+ cursor 1)))]
            [else (set! cursor (+ cursor 1))])))
      found)))

(define (compiler-semantic-definition-span
  [path : String]
  [source : String]
  [name : (& name str)]
  [origin : ast.AstSourceSpan]
  [form-start : i64]) : CompilerSemanticSpan
  (let
    [start : i64
      (if (>= form-start 0)
        form-start
        0)]
    [end : i64
      (compiler-semantic-source-offset
        source
        (ast.ast-source-span-end-line origin)
        (ast.ast-source-span-end-col origin))]
    [found : i64 (compiler-semantic-name-offset-in-range source name start end)]
    (if (< found 0)
      ;; Keep the owning form for diagnostics, but mark the name coordinates as
      ;; inexact so navigation never returns a plausible-looking whole form.
      (CompilerSemanticSpan (string.copy (& path)) start end origin -1 -1)
      (let
        [name-len : i64 (string.string-length name)]
        [position : ast.AstSourceSpan
          (compiler-semantic-source-position source found)]
        [line : i64 (ast.ast-source-span-start-line position)]
        [col : i64 (ast.ast-source-span-start-col position)]
        (compiler-semantic-span-from-byte-range
          path
          source
          found
          (+ found name-len)
          (ast.ast-source-span line col line (+ col name-len)))))))

(define (compiler-semantic-decl-origin
  [decls : (& decls ast.AstDeclList)]
  [index : i64]
  [decl : ast.AstDecl]) : parse_core.CompilerParseMaybeDeclSpan
  (match (parse_core.compiler-parse-decl-origin-span decls index)
    [(parse_core.CompilerParseMaybeDeclSpan.Some span)
      (parse_core.CompilerParseMaybeDeclSpan.Some span)]
    [(parse_core.CompilerParseMaybeDeclSpan.None)
      (let
        [maybe-span : tc.TcMaybeAstSourceSpan
          (match decl
            [(ast.AstDecl.Def _ _ _ expr)
              (tc.tc-expr-id-maybe-span-installed expr)]
            [(ast.AstDecl.DefFn _ _ _ _ body _)
              (tc.tc-expr-id-maybe-span-installed body)]
            [(ast.AstDecl.DefMacro _ _ _ _ body)
              (tc.tc-expr-id-maybe-span-installed body)]
            [(ast.AstDecl.Unsafe inner)
              (match (compiler-semantic-decl-origin decls index (deref inner))
                [(parse_core.CompilerParseMaybeDeclSpan.Some span)
                  (tc.TcMaybeAstSourceSpan.Some span)]
                [(parse_core.CompilerParseMaybeDeclSpan.None)
                  tc.TcMaybeAstSourceSpan.No])]
            [_ tc.TcMaybeAstSourceSpan.No])]
        (match maybe-span
          [(tc.TcMaybeAstSourceSpan.Some span)
            (parse_core.CompilerParseMaybeDeclSpan.Some span)]
          [(tc.TcMaybeAstSourceSpan.No)
            parse_core.CompilerParseMaybeDeclSpan.None]))]))

(define (compiler-semantic-decl-type
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]
  [decl : ast.AstDecl]
  [kind : CompilerSemanticSymbolKind]
  [name-id : i64]
  [name : String]) : String
  (match kind
    [(CompilerSemanticSymbolKind.Struct) (str_cat.str-cat "struct " name)]
    [(CompilerSemanticSymbolKind.Enum) (str_cat.str-cat "enum " name)]
    [(CompilerSemanticSymbolKind.Macro)
      (match decl
        [(ast.AstDecl.DefMacro _ _ params ret _)
          (tc.tc-type-render
            (ast.ast-ty-func
              (tc.tc-macro-param-type-list ctx params)
              (tc.tc-resolve-type ctx ret)))]
        [(ast.AstDecl.Unsafe inner)
          (compiler-semantic-decl-type ctx env (deref inner) kind name-id name)]
        [_ "macro"])]
    [_
      (match (tc.tc-lookup-visible-id ctx env name-id)
        [(tc.ResultTcType.Ok ty) (tc.tc-type-render ty)]
        [(tc.ResultTcType.Err _)
          (match (tc.tc-top-decl-type ctx decl)
            [(tc.ResultTcType.Ok ty) (tc.tc-type-render ty)]
            [(tc.ResultTcType.Err _) ""])])]))

(define (compiler-semantic-decl-provenance [decl : ast.AstDecl]) : CompilerSemanticProvenance
  (match (ast.ast-decl-generated-meta decl)
    [(ast.AstGeneratedDeclMeta.No) CompilerSemanticProvenance.EditableSource]
    [(ast.AstGeneratedDeclMeta.Some generator item _ key)
      (CompilerSemanticProvenance.Generated
        (string.copy (& generator))
        (string.copy (& item))
        (string.copy (& key)))]))

(define (compiler-semantic-decl-retains-checked-let-facts?
  [path : String]
  [decl : ast.AstDecl]) : bool
  (if (tc.tc-decl-unchecked-clone?
    (owned_view.compiler-owned-shared-view path)
    (owned_view.compiler-owned-shared-view decl))
    false
    (match decl
      ;; DefMacro templates are checked by CTFE/macro expansion rather than the
      ;; final runtime body checker that publishes retained let facts.
      [(ast.AstDecl.DefMacro _ _ _ _ _) false]
      ;; Test bodies stay in the parsed program for tooling but ordinary source
      ;; checking deliberately does not execute/typecheck them.
      [(ast.AstDecl.Test _ _ _ _) false]
      [(ast.AstDecl.Unsafe inner)
        (compiler-semantic-decl-retains-checked-let-facts? path (deref inner))]
      [_ true])))

(define (compiler-semantic-use-span-from-origin
  [path : String]
  [source : String]
  [origin : ast.AstSourceSpan]) : CompilerSemanticSpan
  (let
    [start : i64
      (compiler-semantic-source-offset
        source
        (ast.ast-source-span-start-line origin)
        (ast.ast-source-span-start-col origin))]
    [end : i64 start]
    [source-len : i64 (string.string-length source)]
    (begin
      (while (and
        (< end source-len)
        (not (compiler-semantic-delimiter? (string.string-ref source end))))
        (set! end (+ end 1)))
      (let
        [start-position : ast.AstSourceSpan
          (compiler-semantic-source-position source start)]
        [end-position : ast.AstSourceSpan
          (compiler-semantic-source-position source end)]
        (compiler-semantic-span-from-byte-range
          path
          source
          start
          end
          (ast.ast-source-span
            (ast.ast-source-span-start-line start-position)
            (ast.ast-source-span-start-col start-position)
            (ast.ast-source-span-start-line end-position)
            (ast.ast-source-span-start-col end-position)))))))

(define (compiler-semantic-exact-span-from-origin
  [state : (& state CompilerSemanticWalkState)]
  [origin : parse_core.CompilerParseSemanticOrigin]) : CompilerSemanticSpan
  (let
    [state : CompilerSemanticWalkState
      (owned_view.compiler-owned-reference-shared-view state)]
    (if (string.eq state.source "")
      (CompilerSemanticSpan
        (string.copy (& state.path))
        -1
        -1
        origin.span
        -1
        -1)
      (let
        [start : i64
          (compiler-semantic-source-offset
            state.source
            (ast.ast-source-span-start-line origin.span)
            (ast.ast-source-span-start-col origin.span))]
        [end : i64
          (compiler-semantic-source-offset
            state.source
            (ast.ast-source-span-end-line origin.span)
            (ast.ast-source-span-end-col origin.span))]
        (compiler-semantic-span-from-byte-range
          state.path
          state.source
          start
          end
          origin.span)))))

(define (compiler-semantic-name-span-in-range
  [path : (& path str)]
  [source : String]
  [name : String]
  [start : i64]
  [limit : i64]) : CompilerSemanticSpan
  (let
    [bounded-limit : i64
      (if (> limit (string.string-length source))
        (string.string-length source)
        limit)]
    [found : i64
      (compiler-semantic-name-offset-in-range source name start bounded-limit)]
    (if (< found 0)
      (CompilerSemanticSpan
        (string.copy path)
        -1
        -1
        (ast.ast-source-span 1 1 1 1)
        -1
        -1)
      (let
        [name-len : i64 (string.string-length name)]
        [position : ast.AstSourceSpan
          (compiler-semantic-source-position source found)]
        [line : i64 (ast.ast-source-span-start-line position)]
        [col : i64 (ast.ast-source-span-start-col position)]
        (compiler-semantic-span-from-byte-range
          path
          source
          found
          (+ found name-len)
          (ast.ast-source-span line col line (+ col name-len)))))))

(define (compiler-semantic-form-head-end
  [source : (& source str)]
  [start : i64]) : i64
  (let
    [cursor : i64
      (if (< start 0)
        0
        start)]
    [len : i64 (string.string-length source)]
    (begin
      (while (and
        (< cursor len)
        (or
          (= (string.string-ref source cursor) '(')
          (= (string.string-ref source cursor) ' ')
          (= (string.string-ref source cursor) '\t')
          (= (string.string-ref source cursor) '\r')
          (= (string.string-ref source cursor) '\n')))
        (set! cursor (+ cursor 1)))
      (while (and
        (< cursor len)
        (not (compiler-semantic-delimiter? (string.string-ref source cursor))))
        (set! cursor (+ cursor 1)))
      cursor)))

(define (compiler-semantic-binding-clause-end
  [source : String]
  [start : i64]
  [limit : i64]) : i64
  (let
    [cursor : i64 start]
    [depth : i64 1]
    [bounded-limit : i64
      (if (> limit (string.string-length source))
        (string.string-length source)
        limit)]
    (begin
      (while (and (> depth 0) (< cursor bounded-limit))
        (begin
          (cond
            [(= (string.string-ref source cursor) '[') (set! depth (+ depth 1))]
            [(= (string.string-ref source cursor) ']') (set! depth (- depth 1))]
            [else unit])
          (set! cursor (+ cursor 1))))
      cursor)))

(define (compiler-semantic-line-start-before
  [source : (& source str)]
  [position : i64]) : i64
  (let
    [cursor : i64 position]
    (begin
      (while (and
        (> cursor 0)
        (not (= (string.string-ref source (- cursor 1)) '\n')))
        (set! cursor (- cursor 1)))
      cursor)))

(define (compiler-semantic-doc-comment-line?
  [source : (& source str)]
  [line-start : i64]) : bool
  (let
    [cursor : i64 line-start]
    [len : i64 (string.string-length source)]
    (begin
      (while (and
        (< cursor len)
        (or
          (= (string.string-ref source cursor) ' ')
          (= (string.string-ref source cursor) '\t')))
        (set! cursor (+ cursor 1)))
      (and
        (< (+ cursor 1) len)
        (= (string.string-ref source cursor) ';')
        (or
          (= (string.string-ref source (+ cursor 1)) ':')
          (= (string.string-ref source (+ cursor 1)) '#'))))))

(define (compiler-semantic-doc-comment-text
  [source : (& source str)]
  [line-start : i64]) : String
  (let
    [cursor : i64 line-start]
    [len : i64 (string.string-length source)]
    (begin
      (while (and
        (< cursor len)
        (or
          (= (string.string-ref source cursor) ' ')
          (= (string.string-ref source cursor) '\t')))
        (set! cursor (+ cursor 1)))
      (set! cursor (+ cursor 2))
      (if (and (< cursor len) (= (string.string-ref source cursor) ' '))
        (set! cursor (+ cursor 1))
        unit)
      (let
        [end : i64 cursor]
        (begin
          (while (and (< end len) (not (= (string.string-ref source end) '\n')))
            (set! end (+ end 1)))
          (string.substring source cursor (- end cursor)))))))

(define (compiler-semantic-documentation-above
  [source : (& source str)]
  [form-start : i64]) : String
  (let
    [line-start : i64 (compiler-semantic-line-start-before source form-start)]
    [documentation : String ""]
    [done : bool false]
    (begin
      (while (and (> line-start 0) (not done))
        (let
          [previous : i64
            (compiler-semantic-line-start-before source (- line-start 1))]
          (if (compiler-semantic-doc-comment-line? source previous)
            (begin
              (set!
                documentation
                (if (string.eq documentation "")
                  (compiler-semantic-doc-comment-text source previous)
                  (str_cat.str-cat
                    (compiler-semantic-doc-comment-text source previous)
                    "\n"
                    documentation)))
              (set! line-start previous))
            (set! done true))))
      documentation)))

(define (compiler-semantic-decl-handle
  [ctx : tc.TcContext]
  [module-id : i64]
  [name-id : i64]
  [kind : CompilerSemanticSymbolKind]) : CompilerSemanticMaybeHandle
  (let
    [symbols : (& ctx csym.CompilerSymbols) (tc.tc-context-symbols ctx)]
    (match kind
      [(CompilerSemanticSymbolKind.Struct)
        (let
          [handle : i64 (compiler-semantic-type-name-handle ctx name-id)]
          (if (csym.compiler-symbols-handle-found? handle)
            (CompilerSemanticMaybeHandle.Some handle)
            CompilerSemanticMaybeHandle.None))]
      [(CompilerSemanticSymbolKind.Enum)
        (let
          [handle : i64 (compiler-semantic-type-name-handle ctx name-id)]
          (if (csym.compiler-symbols-handle-found? handle)
            (CompilerSemanticMaybeHandle.Some handle)
            CompilerSemanticMaybeHandle.None))]
      [(CompilerSemanticSymbolKind.Macro)
        (match (csym.compiler-symbols-lookup-macro-in-module-id
          symbols
          module-id
          name-id)
          [(option_i64.Some handle) (CompilerSemanticMaybeHandle.Some handle)]
          [(option_i64.None) CompilerSemanticMaybeHandle.None])]
      [_
        (match (csym.compiler-symbols-lookup-value-in-module-id
          symbols
          module-id
          name-id)
          [(option_i64.Some handle) (CompilerSemanticMaybeHandle.Some handle)]
          [(option_i64.None) CompilerSemanticMaybeHandle.None])])))

(define (compiler-semantic-use-handle [ctx : tc.TcContext] [lookup-id : i64]) : CompilerSemanticMaybeHandle
  (let
    [symbols : (& ctx csym.CompilerSymbols) (tc.tc-context-symbols ctx)]
    (match (csym.compiler-symbols-lookup-value-id symbols lookup-id)
      [(option_i64.Some handle) (CompilerSemanticMaybeHandle.Some handle)]
      [(option_i64.None)
        (match (csym.compiler-symbols-lookup-macro-id symbols lookup-id)
          [(option_i64.Some handle) (CompilerSemanticMaybeHandle.Some handle)]
          [(option_i64.None)
            (match (csym.compiler-symbols-lookup-type-id symbols lookup-id)
              [(option_i64.Some handle)
                (CompilerSemanticMaybeHandle.Some handle)]
              [(option_i64.None)
                (match (tc.tc-enum-qualified-variant-constructor-handle
                  ctx
                  lookup-id)
                  [(option_i64.Some handle)
                    (CompilerSemanticMaybeHandle.Some handle)]
                  [(option_i64.None) CompilerSemanticMaybeHandle.None])])])])))

(define (compiler-semantic-handle-module-id [ctx : tc.TcContext] [handle : i64]) : i64
  (let
    [index : i64 (csym.compiler-symbol-handle-index handle)]
    [owners : (__tl_dyn-array i64)
      (csym.compiler-symbols-owner-module-ids (tc.tc-context-symbols ctx))]
    (if (and (>= index 0) (< index (array-length owners)))
      (array-ref owners index)
      cbi.compiler-builtin-id-fix-empty)))

(define (compiler-semantic-handle-decl [ctx : tc.TcContext] [handle : i64]) : ast.AstDecl
  (let
    [index : i64 (csym.compiler-symbol-handle-index handle)]
    [decls : (__tl_dyn-array ast.AstDecl)
      (csym.compiler-symbols-decls (tc.tc-context-symbols ctx))]
    (if (and (>= index 0) (< index (array-length decls)))
      (array-ref decls index)
      (ast.ast-decl-fallback))))

(define (compiler-semantic-symbol-for-decl
  [ctx : tc.TcContext]
  [module-id : i64]
  [fallback-ordinal : i64]
  [name-id : i64]
  [kind : CompilerSemanticSymbolKind]) : CompilerSemanticSymbolId
  (match (compiler-semantic-decl-handle ctx module-id name-id kind)
    [(CompilerSemanticMaybeHandle.Some handle)
      (CompilerSemanticSymbolId
        (compiler-semantic-handle-module-id ctx handle)
        (csym.compiler-symbol-handle-index handle)
        -1)]
    [(CompilerSemanticMaybeHandle.None)
      (CompilerSemanticSymbolId module-id fallback-ordinal -1)]))

;; Registry handles include both the owning nominal declaration and the child
;; index, so same-spelled fields or variants in different types cannot collide.
(define (compiler-semantic-member-symbol
  [ctx : tc.TcContext]
  [owner-handle : i64]
  [member-handle : i64]) : CompilerSemanticSymbolId
  (CompilerSemanticSymbolId
    (compiler-semantic-handle-module-id ctx owner-handle)
    member-handle
    -1))

(define (compiler-semantic-field-owner-handle [handle : i64]) : i64
  (csym.compiler-symbol-make-handle
    (csym.compiler-symbol-kind-defstruct)
    (csym.compiler-registry-handle-owner-index handle)))

(define (compiler-semantic-canonical-kind-tag
  [kind : CompilerSemanticSymbolKind]) : i64
  (match kind
    [(CompilerSemanticSymbolKind.Value) 1]
    [(CompilerSemanticSymbolKind.Function) 2]
    [(CompilerSemanticSymbolKind.Macro) 3]
    [(CompilerSemanticSymbolKind.ExternValue) 4]
    [(CompilerSemanticSymbolKind.ExternFunction) 5]
    [(CompilerSemanticSymbolKind.Struct) 6]
    [(CompilerSemanticSymbolKind.Enum) 7]
    [(CompilerSemanticSymbolKind.Parameter) 8]
    [(CompilerSemanticSymbolKind.Local) 9]
    [(CompilerSemanticSymbolKind.Module) 10]
    [(CompilerSemanticSymbolKind.Field) 11]
    [(CompilerSemanticSymbolKind.EnumMember) 12]))

(define (compiler-semantic-canonical-namespace-tag
  [kind : CompilerSemanticSymbolKind]) : i64
  (match kind
    [(CompilerSemanticSymbolKind.Macro) 3]
    [(CompilerSemanticSymbolKind.Struct) 2]
    [(CompilerSemanticSymbolKind.Enum) 2]
    [(CompilerSemanticSymbolKind.Module) 4]
    [(CompilerSemanticSymbolKind.Field) 5]
    [(CompilerSemanticSymbolKind.EnumMember) 6]
    [_ 1]))

;; Length framing makes the opaque key injective even when source identifiers,
;; paths, or generator keys contain punctuation used by this representation.
(define (compiler-semantic-canonical-key-field [value : String]) : String
  (str_cat.str-cat (string.int->string (string.string-length value)) ":" value))

(define (compiler-semantic-canonical-top-key [record : CompilerSemanticRecord]) : String
  (let
    [module-identity : String
      (tc.macro-decl-module-display record.symbol.module-id)]
    [source-owner : String
      (if (string.eq module-identity "")
        (cload.compiler-load-normalize-path record.span.path)
        "")]
    [namespace-tag : String
      (string.int->string
        (compiler-semantic-canonical-namespace-tag record.kind))]
    [kind-tag : String
      (string.int->string (compiler-semantic-canonical-kind-tag record.kind))]
    [scoped-name : String
      (match record.kind
        [(CompilerSemanticSymbolKind.Field)
          (str_cat.str-cat
            (string.int->string
              (csym.compiler-registry-handle-owner-index
                record.symbol.declaration-ordinal))
            "/"
            record.display-name)]
        [(CompilerSemanticSymbolKind.EnumMember)
          (str_cat.str-cat
            (string.int->string
              (csym.compiler-registry-handle-owner-index
                record.symbol.declaration-ordinal))
            "/"
            record.display-name)]
        [_ (string.copy (& record.display-name))])]
    (match record.provenance
      [(CompilerSemanticProvenance.EditableSource)
        (str_cat.str-cat
          "tl-semantic-v1|d|"
          (compiler-semantic-canonical-key-field module-identity)
          (compiler-semantic-canonical-key-field source-owner)
          (compiler-semantic-canonical-key-field namespace-tag)
          (compiler-semantic-canonical-key-field kind-tag)
          (compiler-semantic-canonical-key-field scoped-name)
          "0:0:0:")]
      [(CompilerSemanticProvenance.Generated generator item key)
        (str_cat.str-cat
          "tl-semantic-v1|d|"
          (compiler-semantic-canonical-key-field module-identity)
          (compiler-semantic-canonical-key-field source-owner)
          (compiler-semantic-canonical-key-field namespace-tag)
          (compiler-semantic-canonical-key-field kind-tag)
          (compiler-semantic-canonical-key-field scoped-name)
          (compiler-semantic-canonical-key-field generator)
          (compiler-semantic-canonical-key-field item)
          (compiler-semantic-canonical-key-field key))])))

(define (compiler-semantic-canonical-local-key
  [parent-key : String]
  [record : CompilerSemanticRecord]) : String
  (str_cat.str-cat
    "tl-semantic-v1|l|"
    (compiler-semantic-canonical-key-field parent-key)
    (compiler-semantic-canonical-key-field
      (string.int->string record.symbol.local-ordinal))
    (compiler-semantic-canonical-key-field
      (string.int->string (compiler-semantic-canonical-kind-tag record.kind)))))

(define (compiler-semantic-canonical-map-capacity [record-len : i64]) : i64
  (let
    [target : i64
      (if (< record-len 1)
        1
        (* record-len 2))]
    [capacity : i64 1]
    (begin
      (while (< capacity target)
        (set! capacity (* capacity 2)))
      capacity)))

(define (compiler-semantic-canonical-symbol-hash
  [symbol : CompilerSemanticSymbolId]) : i64
  (bit-xor
    (* symbol.module-id 6364136223846793005)
    (bit-xor
      (* symbol.declaration-ordinal -7046029254386353131)
      (* (+ symbol.local-ordinal 2) 2654435761))))

(define (compiler-semantic-canonical-build
  [records : (__tl_dyn-array CompilerSemanticRecord)]
  [record-len : i64]) : CompilerSemanticCanonicalBuildResult
  (let
    [capacity : i64 (compiler-semantic-canonical-map-capacity record-len)]
    ;; Hash slots and framed-key construction are scratch-only. with-escape
    ;; clones each completed key into the source-index owner before rewinding.
    [scratch : arena.Arena (arena.make)]
    [slots : (__tl_dyn-array CompilerSemanticCanonicalBuildSlot)
      (in-arena
        scratch
        (__tl_make-array CompilerSemanticCanonicalBuildSlot capacity))]
    [symbols : (__tl_dyn-array String) (__tl_make-array String record-len)]
    [canonical-len : i64 0]
    [record-index : i64 0]
    [pass : i64 0]
    (begin
      ;; Definitions establish owner-derived keys before any use is assigned.
      ;; Top-level definitions precede their lexical definitions in the record
      ;; stream, so locals can frame the already-owned declaration key. Keep
      ;; the scratch-owned slot table in this function: passing it through an
      ;; unannotated helper would erase the checker generation that guards it.
      (while (< pass 2)
        (begin
          (set! record-index 0)
          (while (< record-index record-len)
            (let
              [record : CompilerSemanticRecord
                (owned_view.compiler-owned-array-element-shared-view
                  records
                  record-index)]
              [definition? : bool
                (match record.role
                  [(CompilerSemanticRecordRole.Definition) true]
                  [(CompilerSemanticRecordRole.Use) false])]
              (begin
                (if (or (= pass 1) definition?)
                  (let
                    [slot-index : i64
                      (bit-and
                        (compiler-semantic-canonical-symbol-hash record.symbol)
                        (- capacity 1))]
                    [slot-found : bool false]
                    [assigned : i64 -1]
                    (begin
                      (while (not slot-found)
                        (let
                          [occupied : bool
                            (array-ref slots slot-index).occupied]
                          [module-id : i64
                            (array-ref slots slot-index).symbol.module-id]
                          [declaration-ordinal : i64
                            (array-ref slots slot-index).symbol.declaration-ordinal]
                          [local-ordinal : i64
                            (array-ref slots slot-index).symbol.local-ordinal]
                          (if (or
                            (not occupied)
                            (and
                              (= module-id record.symbol.module-id)
                              (=
                                declaration-ordinal
                                record.symbol.declaration-ordinal)
                              (= local-ordinal record.symbol.local-ordinal)))
                            (set! slot-found true)
                            (set!
                              slot-index
                              (bit-and (+ slot-index 1) (- capacity 1))))))
                      (if (array-ref slots slot-index).occupied
                        (set!
                          assigned
                          (array-ref slots slot-index).canonical-index)
                        (let
                          [parent-symbol : CompilerSemanticSymbolId
                            (CompilerSemanticSymbolId
                              record.symbol.module-id
                              record.symbol.declaration-ordinal
                              -1)]
                          [parent-slot-index : i64
                            (bit-and
                              (compiler-semantic-canonical-symbol-hash
                                parent-symbol)
                              (- capacity 1))]
                          [parent-slot-found : bool false]
                          (begin
                            (while (not parent-slot-found)
                              (let
                                [occupied : bool
                                  (array-ref slots parent-slot-index).occupied]
                                [module-id : i64
                                  (array-ref slots parent-slot-index).symbol.module-id]
                                [declaration-ordinal : i64
                                  (array-ref slots parent-slot-index).symbol.declaration-ordinal]
                                [local-ordinal : i64
                                  (array-ref slots parent-slot-index).symbol.local-ordinal]
                                (if (or
                                  (not occupied)
                                  (and
                                    (= module-id parent-symbol.module-id)
                                    (=
                                      declaration-ordinal
                                      parent-symbol.declaration-ordinal)
                                    (=
                                      local-ordinal
                                      parent-symbol.local-ordinal)))
                                  (set! parent-slot-found true)
                                  (set!
                                    parent-slot-index
                                    (bit-and
                                      (+ parent-slot-index 1)
                                      (- capacity 1))))))
                            (let
                              [parent-occupied : bool
                                (array-ref slots parent-slot-index).occupied]
                              [parent-canonical-index : i64
                                (array-ref slots parent-slot-index).canonical-index]
                              [owned-key : String
                                (with-escape
                                  scratch
                                  (if (and
                                    (>= record.symbol.local-ordinal 0)
                                    parent-occupied)
                                    (compiler-semantic-canonical-local-key
                                      (owned_view.compiler-owned-array-element-shared-view
                                        symbols
                                        parent-canonical-index)
                                      (owned_view.compiler-owned-shared-view
                                        record))
                                    (compiler-semantic-canonical-top-key
                                      (owned_view.compiler-owned-shared-view
                                        record))))]
                              (begin
                                (set! assigned canonical-len)
                                (set!
                                  (array-ref symbols canonical-len)
                                  owned-key)
                                (set!
                                  (array-ref slots slot-index)
                                  (CompilerSemanticCanonicalBuildSlot
                                    true
                                    record.symbol
                                    canonical-len))
                                (set! canonical-len (+ canonical-len 1)))))))
                      (if (= pass 1)
                        (set!
                          (array-ref records record-index).canonical-index
                          assigned)
                        unit)))
                  unit)
                (set! record-index (+ record-index 1))))))
        (set! pass (+ pass 1)))
      (let
        [result : CompilerSemanticCanonicalBuildResult
          (CompilerSemanticCanonicalBuildResult symbols canonical-len)]
        (begin
          (arena.destroy-safe! scratch)
          result)))))

(define (compiler-semantic-binding-lookup
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [name-id : i64]) : CompilerSemanticMaybeBinding
  (let
    [cursor : i64 scope.head]
    [bindings : CompilerSemanticBindingVec
      (owned_view.compiler-owned-box-shared-view state.bindings)]
    [items : (__tl_dyn-array CompilerSemanticBinding) bindings.items]
    (begin
      (while (>= cursor 0)
        (let
          [binding : CompilerSemanticBinding
            (owned_view.compiler-owned-array-element-shared-view items cursor)]
          (if (= binding.name-id name-id)
            (return (CompilerSemanticMaybeBinding.Some binding))
            (set! cursor binding.parent))))
      CompilerSemanticMaybeBinding.None)))

(define (compiler-semantic-record-use-with-binding!
  [state : CompilerSemanticWalkState]
  [binding : CompilerSemanticBinding]
  [span : CompilerSemanticSpan]
  [access : CompilerSemanticAccess]) : unit
  (compiler-semantic-record-vec-push!
    (&mut (__tl-box-place state.records))
    (CompilerSemanticRecord
      binding.symbol
      -1
      CompilerSemanticRecordRole.Use
      (if state.generated
        CompilerSemanticAccess.None
        access)
      binding.kind
      (string.copy (& binding.display-name))
      (string.copy (& binding.resolved-type))
      ""
      binding.symbol.module-id
      (owned_view.compiler-owned-shared-view span)
      (and (not state.generated) (>= span.start-byte 0))
      (owned_view.compiler-owned-shared-view state.provenance))))

(define (compiler-semantic-variant-display-name
  [ctx : tc.TcContext]
  [lookup-id : i64]
  [handle : i64]) : String
  (let
    [owner-handle : i64 (csym.compiler-registry-variant-owner-handle handle)]
    [owner-decl : ast.AstDecl (compiler-semantic-handle-decl ctx owner-handle)]
    [child-index : i64 (csym.compiler-registry-handle-child-index handle)]
    (match owner-decl
      [(ast.AstDecl.DefEnum _ _ _ variants)
        (match (ast.ast-variant-def-list-get
          (& variants)
          child-index
          (ast.ast-variant-def-fallback))
          [(ast.AstVariantDef.Def name _ _) (tc.tc-env-key-name-text name)])]
      [(ast.AstDecl.DefEnumLifetimes _ _ _ _ variants)
        (match (ast.ast-variant-def-list-get
          (& variants)
          child-index
          (ast.ast-variant-def-fallback))
          [(ast.AstVariantDef.Def name _ _) (tc.tc-env-key-name-text name)])]
      [(ast.AstDecl.Unsafe inner)
        (match (__tl-box-place inner)
          [(ast.AstDecl.DefEnum _ _ _ variants)
            (match (ast.ast-variant-def-list-get
              (& variants)
              child-index
              (ast.ast-variant-def-fallback))
              [(ast.AstVariantDef.Def name _ _) (tc.tc-env-key-name-text name)])]
          [(ast.AstDecl.DefEnumLifetimes _ _ _ _ variants)
            (match (ast.ast-variant-def-list-get
              (& variants)
              child-index
              (ast.ast-variant-def-fallback))
              [(ast.AstVariantDef.Def name _ _) (tc.tc-env-key-name-text name)])]
          [_ (tc.tc-env-key-name-text lookup-id)])]
      [_ (tc.tc-env-key-name-text lookup-id)])))

(define (compiler-semantic-record-variant-use!
  [state : CompilerSemanticWalkState]
  [lookup-id : i64]
  [handle : i64]
  [span : CompilerSemanticSpan]
  [access : CompilerSemanticAccess]) : unit
  (let
    [ctx : tc.TcContext state.ctx]
    [owner-handle : i64 (csym.compiler-registry-variant-owner-handle handle)]
    [display-name : String
      (compiler-semantic-variant-display-name ctx lookup-id handle)]
    [type-text : String
      (match (tc.tc-lookup-visible-id ctx state.top-env lookup-id)
        [(tc.ResultTcType.Ok ty) (tc.tc-type-render ty)]
        [(tc.ResultTcType.Err _) ""])]
    [symbol : CompilerSemanticSymbolId
      (compiler-semantic-member-symbol ctx owner-handle handle)]
    (compiler-semantic-record-vec-push!
      (&mut (__tl-box-place state.records))
      (CompilerSemanticRecord
        symbol
        -1
        CompilerSemanticRecordRole.Use
        (if state.generated
          CompilerSemanticAccess.None
          access)
        CompilerSemanticSymbolKind.EnumMember
        (string.copy (& display-name))
        (string.copy (& type-text))
        ""
        symbol.module-id
        (owned_view.compiler-owned-shared-view span)
        (and (not state.generated) (>= span.start-byte 0))
        (owned_view.compiler-owned-shared-view state.provenance)))))

(define (compiler-semantic-record-top-use!
  [state : CompilerSemanticWalkState]
  [name-id : i64]
  [span : CompilerSemanticSpan]
  [access : CompilerSemanticAccess]) : unit
  (let
    [ctx : tc.TcContext state.ctx]
    [env : tc.TcTypeEnv state.top-env]
    [name : String (tc.tc-hygiene-name-text-id name-id)]
    (match (tc.tc-source-name-lookup-key-with-field-check-lookup
      ctx
      env
      name
      name-id
      true)
      [(tc.TcNameLookup.Ok _ lookup-id)
        (match (compiler-semantic-use-handle ctx lookup-id)
          [(CompilerSemanticMaybeHandle.Some handle)
            (let
              [module-id : i64 (compiler-semantic-handle-module-id ctx handle)]
              [handle-kind : i64 (csym.compiler-symbol-handle-kind handle)]
              [use-span : CompilerSemanticSpan
                (compiler-semantic-value-use-span!
                  (owned_view.compiler-owned-shared-view state)
                  name-id
                  span
                  module-id
                  (or
                    (= handle-kind (csym.compiler-symbol-kind-defstruct))
                    (= handle-kind (csym.compiler-symbol-kind-defenum))
                    (= handle-kind (csym.compiler-symbol-kind-enum-variant))))]
              (if (= handle-kind (csym.compiler-symbol-kind-enum-variant))
                (compiler-semantic-record-variant-use!
                  (owned_view.compiler-owned-shared-view state)
                  lookup-id
                  handle
                  use-span
                  access)
                (let
                  [decl : ast.AstDecl
                    (compiler-semantic-handle-decl ctx handle)]
                  (match (compiler-semantic-decl-symbol
                    (owned_view.compiler-owned-shared-view decl))
                    [(CompilerSemanticMaybeDecl.Some decl-name-id kind)
                      (let
                        [decl-ctx : tc.TcContext
                          (if (= module-id cbi.compiler-builtin-id-fix-empty)
                            (tc.tc-context-with-module-id
                              ctx
                              ""
                              cbi.compiler-builtin-id-fix-empty)
                            (tc.tc-context-with-module-id
                              ctx
                              (tc.macro-decl-module-display module-id)
                              module-id))]
                        [display-name : String
                          (tc.tc-env-key-name-text-for-session
                            (tc.tc-context-structural-session ctx)
                            decl-name-id)]
                        [type-text : String
                          (match (tc.tc-lookup-visible-id ctx env lookup-id)
                            [(tc.ResultTcType.Ok ty) (tc.tc-type-render ty)]
                            [(tc.ResultTcType.Err _)
                              (compiler-semantic-decl-type
                                decl-ctx
                                env
                                decl
                                kind
                                decl-name-id
                                (owned_view.compiler-owned-shared-view
                                  display-name))])]
                        (compiler-semantic-record-vec-push!
                          (&mut (__tl-box-place state.records))
                          (CompilerSemanticRecord
                            (CompilerSemanticSymbolId
                              module-id
                              (csym.compiler-symbol-handle-index handle)
                              -1)
                            -1
                            CompilerSemanticRecordRole.Use
                            (if state.generated
                              CompilerSemanticAccess.None
                              access)
                            kind
                            (string.copy (& display-name))
                            (string.copy (& type-text))
                            ""
                            module-id
                            (owned_view.compiler-owned-shared-view use-span)
                            (and
                              (not state.generated)
                              (>= use-span.start-byte 0))
                            (owned_view.compiler-owned-shared-view
                              state.provenance))))]
                    [(CompilerSemanticMaybeDecl.None) unit]))))]
          [(CompilerSemanticMaybeHandle.None) unit])]
      [(tc.TcNameLookup.Err _) unit])))

(define (compiler-semantic-record-name-use!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [name-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [span : CompilerSemanticSpan
      (match maybe-span
        [(CompilerSemanticMaybeSpan.Some origin)
          (if (string.eq state.source "")
            (CompilerSemanticSpan
              (string.copy (& state.path))
              -1
              -1
              origin
              -1
              -1)
            (compiler-semantic-use-span-from-origin
              (owned_view.compiler-owned-shared-view state.path)
              (owned_view.compiler-owned-shared-view state.source)
              origin))]
        [(CompilerSemanticMaybeSpan.None)
          (CompilerSemanticSpan
            (string.copy (& state.path))
            -1
            -1
            (ast.ast-source-span 1 1 1 1)
            -1
            -1)])]
    (match (compiler-semantic-binding-lookup
      (owned_view.compiler-owned-shared-view state)
      scope
      name-id)
      [(CompilerSemanticMaybeBinding.Some binding)
        (let
          [use-span : CompilerSemanticSpan
            (if (>= span.start-byte 0)
              span
              (match (compiler-semantic-origin-take!
                state
                parse_core.CompilerParseSemanticOriginKind.ValueQualifier)
                [(CompilerSemanticMaybeOrigin.Some origin)
                  (compiler-semantic-exact-span-from-origin state origin)]
                [(CompilerSemanticMaybeOrigin.None) span]))]
          (compiler-semantic-record-use-with-binding!
            state
            binding
            use-span
            CompilerSemanticAccess.Read))]
      [(CompilerSemanticMaybeBinding.None)
        (compiler-semantic-record-top-use!
          state
          name-id
          span
          CompilerSemanticAccess.Read)])))

(define (compiler-semantic-record-name-write-span!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [name-id : i64]
  [span : CompilerSemanticSpan]) : unit
  (match (compiler-semantic-binding-lookup
    (owned_view.compiler-owned-shared-view state)
    scope
    name-id)
    [(CompilerSemanticMaybeBinding.Some binding)
      (compiler-semantic-record-use-with-binding!
        state
        binding
        span
        CompilerSemanticAccess.Write)]
    [(CompilerSemanticMaybeBinding.None)
      (compiler-semantic-record-top-use!
        state
        name-id
        span
        CompilerSemanticAccess.Write)]))

(define (compiler-semantic-record-name-use-span!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [name-id : i64]
  [span : CompilerSemanticSpan]) : unit
  (match (compiler-semantic-binding-lookup
    (owned_view.compiler-owned-shared-view state)
    scope
    name-id)
    [(CompilerSemanticMaybeBinding.Some binding)
      (compiler-semantic-record-use-with-binding!
        state
        binding
        span
        CompilerSemanticAccess.Read)]
    [(CompilerSemanticMaybeBinding.None)
      (compiler-semantic-record-top-use!
        state
        name-id
        span
        CompilerSemanticAccess.Read)]))

(define (compiler-semantic-record-module-origin!
  [state : CompilerSemanticWalkState]
  [origin : parse_core.CompilerParseSemanticOrigin]
  [target-module-id : i64]
  [role : CompilerSemanticRecordRole]) : unit
  (let
    [display-name : String
      (tc.tc-env-key-name-text-for-session
        (tc.tc-context-structural-session state.ctx)
        origin.written-name)]
    [span : CompilerSemanticSpan
      (compiler-semantic-exact-span-from-origin state origin)]
    (compiler-semantic-record-vec-push!
      (&mut (__tl-box-place state.records))
      (CompilerSemanticRecord
        (CompilerSemanticSymbolId target-module-id -1 -1)
        -1
        role
        (match role
          [(CompilerSemanticRecordRole.Definition) CompilerSemanticAccess.None]
          [(CompilerSemanticRecordRole.Use) CompilerSemanticAccess.Read])
        CompilerSemanticSymbolKind.Module
        (string.copy (& display-name))
        (tc.macro-decl-module-display target-module-id)
        ""
        target-module-id
        (owned_view.compiler-owned-shared-view span)
        (and (not state.generated) (>= span.start-byte 0))
        (owned_view.compiler-owned-shared-view state.provenance)))))

(define (compiler-semantic-record-module-origins-before!
  [state : CompilerSemanticWalkState]
  [ordinal-limit : i64]
  [target-module-id : i64]) : unit
  (let
    [done : bool false]
    (while (not done)
      (match (compiler-semantic-origin-take-before!
        (owned_view.compiler-owned-shared-view state)
        parse_core.CompilerParseSemanticOriginKind.ModulePath
        ordinal-limit)
        [(CompilerSemanticMaybeOrigin.Some origin)
          (compiler-semantic-record-module-origin!
            (owned_view.compiler-owned-shared-view state)
            origin
            target-module-id
            CompilerSemanticRecordRole.Use)]
        [(CompilerSemanticMaybeOrigin.None) (set! done true)]))))

(define (compiler-semantic-record-value-qualifiers-before!
  [state : CompilerSemanticWalkState]
  [ordinal-limit : i64]
  [target-module-id : i64]) : CompilerSemanticMaybeOrigin
  (let
    [done : bool false]
    [first : CompilerSemanticMaybeOrigin CompilerSemanticMaybeOrigin.None]
    (begin
      (while (not done)
        (match (compiler-semantic-origin-take-before!
          (owned_view.compiler-owned-shared-view state)
          parse_core.CompilerParseSemanticOriginKind.ValueQualifier
          ordinal-limit)
          [(CompilerSemanticMaybeOrigin.Some origin)
            (begin
              (match first
                [(CompilerSemanticMaybeOrigin.None)
                  (set! first (CompilerSemanticMaybeOrigin.Some origin))]
                [(CompilerSemanticMaybeOrigin.Some _) unit])
              (compiler-semantic-record-module-origin!
                (owned_view.compiler-owned-shared-view state)
                origin
                target-module-id
                CompilerSemanticRecordRole.Use))]
          [(CompilerSemanticMaybeOrigin.None) (set! done true)]))
      first)))

(define (compiler-semantic-span-through
  [start : CompilerSemanticSpan]
  [end : CompilerSemanticSpan]) : CompilerSemanticSpan
  (CompilerSemanticSpan
    (string.copy (& start.path))
    start.start-byte
    end.end-byte
    (ast.ast-source-span
      (ast.ast-source-span-start-line start.source)
      (ast.ast-source-span-start-col start.source)
      (ast.ast-source-span-end-line end.source)
      (ast.ast-source-span-end-col end.source))
    start.utf16-start-col
    end.utf16-end-col))

(define (compiler-semantic-value-use-span!
  [state : CompilerSemanticWalkState]
  [source-name-id : i64]
  [fallback : CompilerSemanticSpan]
  [target-module-id : i64]
  [component-only : bool]) : CompilerSemanticSpan
  (let
    [session : cis.InternStructuralSessionHandle
      (tc.tc-context-structural-session state.ctx)]
    [written-id : i64 (tc.tc-dotted-name-source-id session source-name-id)]
    ;; Value/function consumers historically select the whole qualified token.
    ;; Preserve that public range from the first exact qualifier through the
    ;; exact final name while retaining separate module-component records.
    ;; Nominal constructors use their final component because their public
    ;; type/member facts are explicitly componentized.
    (if (or
      (< written-id 0)
      (>= written-id (ci.intern-capacity))
      (< (ci.intern-first-dot written-id) 0))
      fallback
      (match (compiler-semantic-origin-take!
        state
        parse_core.CompilerParseSemanticOriginKind.ValueName)
        [(CompilerSemanticMaybeOrigin.None) fallback]
        [(CompilerSemanticMaybeOrigin.Some origin)
          (let
            [final-span : CompilerSemanticSpan
              (compiler-semantic-exact-span-from-origin state origin)]
            [first-qualifier : CompilerSemanticMaybeOrigin
              (compiler-semantic-record-value-qualifiers-before!
                (owned_view.compiler-owned-shared-view state)
                origin.ordinal
                target-module-id)]
            (if component-only
              final-span
              (match first-qualifier
                [(CompilerSemanticMaybeOrigin.Some qualifier)
                  (compiler-semantic-span-through
                    (compiler-semantic-exact-span-from-origin state qualifier)
                    final-span)]
                [(CompilerSemanticMaybeOrigin.None) final-span])))]))))

(define (compiler-semantic-type-name-handle
  [ctx : tc.TcContext]
  [name-id : i64]) : i64
  (let
    [symbols : (& ctx csym.CompilerSymbols) (tc.tc-context-symbols ctx)]
    [in-module : i64
      (match (csym.compiler-symbols-lookup-type-in-module-id
        symbols
        (tc.tc-context-module-id ctx)
        name-id)
        [(option_i64.Some handle) handle]
        [(option_i64.None) (csym.compiler-symbols-missing-handle)])]
    [plain : i64
      (csym.compiler-symbols-lookup-type-id-or
        symbols
        name-id
        (csym.compiler-symbols-missing-handle))]
    (cond
      [(csym.compiler-symbols-handle-found? in-module) in-module]
      [(csym.compiler-symbols-handle-found? plain) plain]
      [else
        (match (tc.tc-dotted-type-name-lookup-from-id
          ctx
          (tc.tc-env-key-name-text-for-session
            (tc.tc-context-structural-session ctx)
            name-id)
          name-id)
          [(tc.TcNameLookup.Ok _ key-id)
            (csym.compiler-symbols-lookup-type-id-or
              symbols
              key-id
              (csym.compiler-symbols-missing-handle))]
          [(tc.TcNameLookup.Err _) (csym.compiler-symbols-missing-handle)])])))

(define (compiler-semantic-record-type-name-use!
  [state : CompilerSemanticWalkState]
  [name-id : i64]) : unit
  (match (compiler-semantic-origin-take!
    state
    parse_core.CompilerParseSemanticOriginKind.TypeName)
    [(CompilerSemanticMaybeOrigin.None) unit]
    [(CompilerSemanticMaybeOrigin.Some origin)
      (let
        [ctx : tc.TcContext state.ctx]
        [handle : i64 (compiler-semantic-type-name-handle ctx name-id)]
        (if (not (csym.compiler-symbols-handle-found? handle))
          unit
          (let
            [decl : ast.AstDecl (compiler-semantic-handle-decl ctx handle)]
            [module-id : i64 (compiler-semantic-handle-module-id ctx handle)]
            (match (compiler-semantic-decl-symbol
              (owned_view.compiler-owned-shared-view decl))
              [(CompilerSemanticMaybeDecl.None) unit]
              [(CompilerSemanticMaybeDecl.Some decl-name-id kind)
                (match kind
                  [(CompilerSemanticSymbolKind.Struct)
                    (compiler-semantic-record-type-name-use-with-kind!
                      (owned_view.compiler-owned-shared-view state)
                      origin
                      decl
                      handle
                      module-id
                      decl-name-id
                      kind)]
                  [(CompilerSemanticSymbolKind.Enum)
                    (compiler-semantic-record-type-name-use-with-kind!
                      (owned_view.compiler-owned-shared-view state)
                      origin
                      decl
                      handle
                      module-id
                      decl-name-id
                      kind)]
                  [_ unit])]))))]))

(define (compiler-semantic-record-type-name-use-with-kind!
  [state : CompilerSemanticWalkState]
  [origin : parse_core.CompilerParseSemanticOrigin]
  [decl : ast.AstDecl]
  [handle : i64]
  [module-id : i64]
  [decl-name-id : i64]
  [kind : CompilerSemanticSymbolKind]) : unit
  (let
    [ctx : tc.TcContext state.ctx]
    [decl-ctx : tc.TcContext
      (if (= module-id cbi.compiler-builtin-id-fix-empty)
        (tc.tc-context-with-module-id ctx "" cbi.compiler-builtin-id-fix-empty)
        (tc.tc-context-with-module-id
          ctx
          (tc.macro-decl-module-display module-id)
          module-id))]
    [display-name : String
      (tc.tc-env-key-name-text-for-session
        (tc.tc-context-structural-session ctx)
        decl-name-id)]
    [span : CompilerSemanticSpan
      (compiler-semantic-exact-span-from-origin state origin)]
    (begin
      (compiler-semantic-record-module-origins-before!
        (owned_view.compiler-owned-shared-view state)
        origin.ordinal
        module-id)
      (compiler-semantic-record-vec-push!
        (&mut (__tl-box-place state.records))
        (CompilerSemanticRecord
          (CompilerSemanticSymbolId
            module-id
            (csym.compiler-symbol-handle-index handle)
            -1)
          -1
          CompilerSemanticRecordRole.Use
          CompilerSemanticAccess.Read
          kind
          (string.copy (& display-name))
          (compiler-semantic-decl-type
            decl-ctx
            state.top-env
            decl
            kind
            decl-name-id
            display-name)
          ""
          module-id
          (owned_view.compiler-owned-shared-view span)
          (and (not state.generated) (>= span.start-byte 0))
          (owned_view.compiler-owned-shared-view state.provenance))))))

(define (compiler-semantic-walk-type!
  [state : (& state CompilerSemanticWalkState)]
  [ty : ast.AstType]) : unit
  (let
    [state : CompilerSemanticWalkState
      (owned_view.compiler-owned-reference-shared-view state)]
    (match (owned_view.compiler-owned-shared-view ty)
      [(ast.AstType.Struct name-id)
        (compiler-semantic-record-type-name-use! state name-id)]
      [(ast.AstType.StructArgs name-id _)
        (compiler-semantic-record-type-name-use! state name-id)]
      [(ast.AstType.Enum name-id)
        (compiler-semantic-record-type-name-use! state name-id)]
      [(ast.AstType.EnumArgs name-id _)
        (compiler-semantic-record-type-name-use! state name-id)]
      [(ast.AstType.Var name-id)
        (match (tc.tc-resolve-type state.ctx ty)
          [(ast.AstType.Struct resolved-name-id)
            (compiler-semantic-record-type-name-use! state resolved-name-id)]
          [(ast.AstType.Enum resolved-name-id)
            (compiler-semantic-record-type-name-use! state resolved-name-id)]
          [_ (compiler-semantic-record-type-name-use! state name-id)])]
      [(ast.AstType.VarArgs name-id _)
        (match (tc.tc-resolve-type state.ctx ty)
          [(ast.AstType.StructArgs resolved-name-id _)
            (compiler-semantic-record-type-name-use! state resolved-name-id)]
          [(ast.AstType.EnumArgs resolved-name-id _)
            (compiler-semantic-record-type-name-use! state resolved-name-id)]
          [_ (compiler-semantic-record-type-name-use! state name-id)])]
      [_
        (ast.ast-type-for-each-child
          (owned_view.compiler-owned-shared-view ty)
          compiler-semantic-walk-type-child!
          state)])))

(define (compiler-semantic-walk-type-child!
  [state : (& state CompilerSemanticWalkState)]
  [ty-id : i64]) : unit
  (let
    [state : CompilerSemanticWalkState
      (owned_view.compiler-owned-reference-shared-view state)]
    (compiler-semantic-walk-type!
      state
      (tc.tc-context-type-get state.ctx ty-id))))

(define (compiler-semantic-walk-type-list!
  [state : CompilerSemanticWalkState]
  [types : ast.AstTypeList]) : unit
  (let
    [index : i64 0]
    (while (< index (ast.ast-type-list-len (& types)))
      (begin
        (compiler-semantic-walk-type!
          state
          (tc.tc-context-type-get
            state.ctx
            (ast.ast-type-list-get (& types) index -1)))
        (set! index (+ index 1))))))

(define (compiler-semantic-bind-local!
  [state : (& state CompilerSemanticWalkState)]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [name-id : i64]
  [kind : CompilerSemanticSymbolKind]
  [maybe-ty : ast.AstMaybeType]
  [search-start : i64]
  [search-limit : i64]) : CompilerSemanticBindResult
  (let
    [state : CompilerSemanticWalkState
      (owned_view.compiler-owned-reference-shared-view state)]
    [name : String
      (tc.tc-env-key-name-text-for-session
        (tc.tc-type-env-structural-session env)
        name-id)]
    [binding-ty : ast.AstType
      (match (owned_view.compiler-owned-shared-view maybe-ty)
        [(ast.AstMaybeType.Some ty) ty]
        [(ast.AstMaybeType.No) (ast.AstType.Unit)])]
    [type-text : String
      (match maybe-ty
        [(ast.AstMaybeType.Some ty) (tc.tc-type-render ty)]
        [(ast.AstMaybeType.No) ""])]
    [local-ordinal : i64 (__tl-box-place state.next-local-ordinal)]
    [symbol : CompilerSemanticSymbolId
      (CompilerSemanticSymbolId
        state.module-id
        state.declaration-ordinal
        local-ordinal)]
    [span : CompilerSemanticSpan
      (if (or state.generated (string.eq state.source ""))
        (CompilerSemanticSpan
          (string.copy (& state.path))
          -1
          -1
          (ast.ast-source-span 1 1 1 1)
          -1
          -1)
        (compiler-semantic-name-span-in-range
          state.path
          state.source
          (owned_view.compiler-owned-shared-view name)
          search-start
          search-limit))]
    (begin
      (set! (deref state.next-local-ordinal) (+ local-ordinal 1))
      (let
        [record-index : i64
          (compiler-semantic-record-vec-push-index!
            (&mut (__tl-box-place state.records))
            (CompilerSemanticRecord
              symbol
              -1
              CompilerSemanticRecordRole.Definition
              CompilerSemanticAccess.None
              kind
              (string.copy (& name))
              (string.copy (& type-text))
              ""
              state.module-id
              (owned_view.compiler-owned-shared-view span)
              (and (not state.generated) (>= span.start-byte 0))
              (owned_view.compiler-owned-shared-view state.provenance)))]
        [binding : CompilerSemanticBinding
          (CompilerSemanticBinding
            name-id
            symbol
            kind
            (string.copy (& name))
            (string.copy (& type-text))
            record-index
            (compiler-semantic-visible-binding-owned-copy
              (&
                (array-ref
                  (__tl-project-field (__tl-box-place state.records) items)
                  record-index))
              (compiler-semantic-binding-namespace-value-mask)
              (& name))
            scope.head)]
        [head : i64
          (compiler-semantic-binding-vec-push!
            (&mut (__tl-box-place state.bindings))
            binding)]
        (CompilerSemanticBindResult
          (CompilerSemanticBindingSnapshot head)
          (tc.tc-bind-id env name-id binding-ty)
          (if (>= span.end-byte 0)
            span.end-byte
            search-start))))))

(define (compiler-semantic-bind-checked-let!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [bindings : (& bindings ast.AstLetBindingList)]
  [binding-index : i64]
  [body-id : i64]
  [name-id : i64]
  [maybe-ty : ast.AstMaybeType]
  [init-id : i64]
  [search-start : i64]
  [search-limit : i64]) : CompilerSemanticBindResult
  (let
    [ctx : tc.TcContext state.ctx]
    [facts : tc.TcCheckedLetBindingFactState
      (tc.tc-job-state-checked-let-binding-facts (tc.tc-context-job-state ctx))]
    (match (tc.tc-checked-let-binding-fact-lookup
      facts
      state.checked-declaration-ordinal
      body-id
      binding-index
      name-id
      init-id)
      [(tc.TcMaybeCheckedLetBindingFact.Hit binding-ty transition)
        (let
          [recorded-maybe-ty : ast.AstMaybeType
            (ast.AstMaybeType.Some
              (tc.tc-resolve-type
                ctx
                (owned_view.compiler-owned-shared-view binding-ty)))]
          [bound : CompilerSemanticBindResult
            (compiler-semantic-bind-local!
              state
              scope
              env
              name-id
              CompilerSemanticSymbolKind.Local
              recorded-maybe-ty
              search-start
              search-limit)]
          (begin
            (match maybe-ty
              [(ast.AstMaybeType.Some ty)
                (compiler-semantic-walk-type! state ty)]
              [(ast.AstMaybeType.No) unit])
            (CompilerSemanticBindResult
              bound.scope
              ;; Apply retained arena-owner and arena-phase transitions without
              ;; inspecting or typechecking the initializer again. The binding
              ;; type carries the C calling convention and pointer mode.
              (tc.tc-bind-checked-let-transition-id
                ctx
                env
                name-id
                binding-ty
                transition)
              bound.next-search)))]
      [_
        ;; Partial checks can legitimately lack a fact after their first error.
        ;; Do not fabricate an annotation-only binding: retain syntax records,
        ;; leave the environment unchanged, and make complete callers fail.
        (begin
          (if state.declaration-retains-let-facts
            (set! (deref state.checked-let-fact-mismatch) true)
            unit)
          (match maybe-ty
            [(ast.AstMaybeType.Some ty) (compiler-semantic-walk-type! state ty)]
            [(ast.AstMaybeType.No) unit])
          (CompilerSemanticBindResult scope env search-start))])))

(define (compiler-semantic-expr-start-offset
  [state : (& state CompilerSemanticWalkState)]
  [expr-id : i64]
  [fallback : i64]) : i64
  (let
    [state : CompilerSemanticWalkState
      (owned_view.compiler-owned-reference-shared-view state)]
    (match (tc.tc-expr-id-maybe-span-installed expr-id)
      [(tc.TcMaybeAstSourceSpan.Some span)
        (compiler-semantic-state-source-offset
          state
          (ast.ast-source-span-start-line span)
          (ast.ast-source-span-start-col span))]
      [(tc.TcMaybeAstSourceSpan.No) fallback])))

(define (compiler-semantic-expr-end-offset
  [state : CompilerSemanticWalkState]
  [expr-id : i64]
  [fallback : i64]) : i64
  (match (tc.tc-expr-id-maybe-span-installed expr-id)
    [(tc.TcMaybeAstSourceSpan.Some span)
      (compiler-semantic-state-source-offset
        state
        (ast.ast-source-span-end-line span)
        (ast.ast-source-span-end-col span))]
    [(tc.TcMaybeAstSourceSpan.No) fallback]))

(define (compiler-semantic-expr-visibility-end-offset
  [state : CompilerSemanticWalkState]
  [expr-id : i64]
  [fallback : i64]) : i64
  (let
    [start : i64 (compiler-semantic-expr-start-offset state expr-id fallback)]
    [raw-end : i64
      (compiler-semantic-expr-end-offset
        (owned_view.compiler-owned-shared-view state)
        expr-id
        fallback)]
    [source-len : i64 (string.string-length state.source)]
    [cursor : i64
      (cond
        [(< raw-end start) start]
        [(> raw-end source-len) source-len]
        [else raw-end])]
    (begin
      ;; Atomic expression spans may end at their first or final byte. Advance
      ;; only through the token so a sequential binder starts after its RHS.
      ;; Generated nodes can have no source span and deliberately preserve a
      ;; negative fallback; leave it for the scope-region guard instead of
      ;; indexing the source at -1.
      (while (and
        (>= cursor 0)
        (< cursor source-len)
        (not
          (compiler-semantic-delimiter? (string.string-ref state.source cursor))))
        (set! cursor (+ cursor 1)))
      cursor)))

(define (compiler-semantic-maybe-span-start
  [state : CompilerSemanticWalkState]
  [maybe-span : CompilerSemanticMaybeSpan]
  [fallback : i64]) : i64
  (match maybe-span
    [(CompilerSemanticMaybeSpan.Some span)
      (compiler-semantic-state-source-offset
        state
        (ast.ast-source-span-start-line span)
        (ast.ast-source-span-start-col span))]
    [(CompilerSemanticMaybeSpan.None) fallback]))

(define (compiler-semantic-maybe-span-end
  [state : CompilerSemanticWalkState]
  [maybe-span : CompilerSemanticMaybeSpan]
  [fallback : i64]) : i64
  (match maybe-span
    [(CompilerSemanticMaybeSpan.Some span)
      (compiler-semantic-state-source-offset
        state
        (ast.ast-source-span-end-line span)
        (ast.ast-source-span-end-col span))]
    [(CompilerSemanticMaybeSpan.None) fallback]))

(define (compiler-semantic-bind-params!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [params : ast.AstParamList]
  [search-start : i64]
  [search-limit : i64]) : CompilerSemanticBindResult
  (let
    [next-scope : CompilerSemanticBindingSnapshot scope]
    [next-env : tc.TcTypeEnv env]
    [cursor : i64 search-start]
    [index : i64 0]
    (begin
      (while (< index (ast.ast-param-list-len (& params)))
        (begin
          (match (ast.ast-param-list-get
            (& params)
            index
            (ast.ast-param-fallback))
            [(ast.AstParam.Param name ty _)
              (let
                [bound : CompilerSemanticBindResult
                  (compiler-semantic-bind-local!
                    state
                    next-scope
                    next-env
                    name
                    CompilerSemanticSymbolKind.Parameter
                    (ast.AstMaybeType.Some
                      (tc.tc-resolve-type
                        state.ctx
                        (owned_view.compiler-owned-shared-view ty)))
                    cursor
                    search-limit)]
                (begin
                  (compiler-semantic-walk-type! state ty)
                  (set! next-scope bound.scope)
                  (set! next-env bound.env)
                  (set!
                    cursor
                    (compiler-semantic-binding-clause-end
                      state.source
                      bound.next-search
                      search-limit))))])
          (set! index (+ index 1))))
      (CompilerSemanticBindResult next-scope next-env cursor))))

(define (compiler-semantic-bind-macro-params!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [params : ast.AstMacroParamList]
  [search-start : i64]
  [search-limit : i64]) : CompilerSemanticBindResult
  (let
    [next-scope : CompilerSemanticBindingSnapshot scope]
    [next-env : tc.TcTypeEnv env]
    [cursor : i64 search-start]
    [index : i64 0]
    (begin
      (while (< index (ast.ast-macro-param-list-len (& params)))
        (begin
          (match (ast.ast-macro-param-list-get
            (& params)
            index
            (ast.ast-macro-param-fallback))
            [(ast.AstMacroParam.Param name ty _ _)
              (let
                [bound : CompilerSemanticBindResult
                  (compiler-semantic-bind-local!
                    state
                    next-scope
                    next-env
                    name
                    CompilerSemanticSymbolKind.Parameter
                    (ast.AstMaybeType.Some
                      (tc.tc-resolve-type
                        state.ctx
                        (owned_view.compiler-owned-shared-view ty)))
                    cursor
                    search-limit)]
                (begin
                  (compiler-semantic-walk-type! state ty)
                  (set! next-scope bound.scope)
                  (set! next-env bound.env)
                  (set!
                    cursor
                    (compiler-semantic-binding-clause-end
                      state.source
                      bound.next-search
                      search-limit))))])
          (set! index (+ index 1))))
      (CompilerSemanticBindResult next-scope next-env cursor))))

(define (compiler-semantic-walk-expr-list!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [items : ast.AstExprList]) : unit
  (let
    [index : i64 0]
    (while (< index (ast.ast-expr-list-len (& items)))
      (begin
        (compiler-semantic-walk-node!
          state
          scope
          env
          (ast.ast-expr-list-get (& items) index 0))
        (set! index (+ index 1))))))

(define (compiler-semantic-walk-quasiquote-node!
  [state : (& state CompilerSemanticWalkState)]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [node-id : i64]) : unit
  (match (ast.ast-node-get node-id)
    [(ast.AstExpr.Unquote inner)
      (compiler-semantic-walk-node! state scope env inner)]
    [(ast.AstExpr.UnquoteSplicing inner)
      (compiler-semantic-walk-node! state scope env inner)]
    [(ast.AstExpr.Quote _) unit]
    ;; CTFE preserves a nested quasiquote wholesale. Its unquotes belong to
    ;; the future quasiquote evaluation rather than the surrounding macro.
    [(ast.AstExpr.Quasiquote _) unit]
    [(ast.AstExpr.Replace _ _) unit]
    [(ast.AstExpr.ForOwnedState _) unit]
    [(ast.AstExpr.ForOwnedStep _) unit]
    ;; Template syntax: only expression children can hold an unquote.
    [_
      (ast.ast-expr-for-each-child
        (ast.ast-node-get node-id)
        compiler-semantic-walk-quasiquote-node!
        ast.ast-child-unit
        ast.ast-child-unit
        ast.ast-child-unit
        state
        scope
        env)]))

(define (compiler-semantic-walk-let!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [bindings : ast.AstLetBindingList]
  [body-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [next-scope : CompilerSemanticBindingSnapshot scope]
    [next-env : tc.TcTypeEnv env]
    [form-start : i64
      (compiler-semantic-maybe-span-start
        (owned_view.compiler-owned-shared-view state)
        maybe-span
        0)]
    [cursor : i64 (compiler-semantic-form-head-end state.source form-start)]
    [body-start : i64
      (compiler-semantic-expr-start-offset
        state
        body-id
        (string.string-length state.source))]
    [form-end : i64
      (compiler-semantic-maybe-span-end
        (owned_view.compiler-owned-shared-view state)
        maybe-span
        (compiler-semantic-expr-end-offset
          (owned_view.compiler-owned-shared-view state)
          body-id
          body-start))]
    [index : i64 0]
    (begin
      (while (< index (ast.ast-let-binding-list-len (& bindings)))
        (begin
          (match (ast.ast-let-binding-list-get
            (& bindings)
            index
            (ast.ast-let-binding-fallback))
            [(ast.AstLetBinding.Binding name maybe-ty init-id)
              (let
                [init-start : i64
                  (compiler-semantic-expr-start-offset state init-id body-start)]
                (begin
                  (compiler-semantic-walk-node!
                    state
                    next-scope
                    next-env
                    init-id)
                  (let
                    [bound : CompilerSemanticBindResult
                      (compiler-semantic-bind-checked-let!
                        (owned_view.compiler-owned-shared-view state)
                        next-scope
                        next-env
                        (& bindings)
                        index
                        body-id
                        name
                        maybe-ty
                        init-id
                        cursor
                        init-start)]
                    (begin
                      (compiler-semantic-scope-region-add!
                        state
                        next-scope
                        bound.scope
                        (compiler-semantic-expr-visibility-end-offset
                          (owned_view.compiler-owned-shared-view state)
                          init-id
                          bound.next-search)
                        form-end)
                      (set! next-scope bound.scope)
                      (set! next-env bound.env)
                      (set!
                        cursor
                        (compiler-semantic-expr-visibility-end-offset
                          (owned_view.compiler-owned-shared-view state)
                          init-id
                          bound.next-search))))))])
          (set! index (+ index 1))))
      (compiler-semantic-walk-node! state next-scope next-env body-id))))

(define (compiler-semantic-walk-lambda!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [params : ast.AstParamList]
  [maybe-ret : ast.AstMaybeType]
  [body-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [form-start : i64
      (compiler-semantic-maybe-span-start
        (owned_view.compiler-owned-shared-view state)
        maybe-span
        0)]
    [body-start : i64
      (compiler-semantic-expr-start-offset
        state
        body-id
        (string.string-length state.source))]
    [bound : CompilerSemanticBindResult
      (compiler-semantic-bind-params!
        (owned_view.compiler-owned-shared-view state)
        scope
        env
        params
        (compiler-semantic-form-head-end state.source form-start)
        body-start)]
    (begin
      (match maybe-ret
        [(ast.AstMaybeType.Some ret) (compiler-semantic-walk-type! state ret)]
        [(ast.AstMaybeType.No) unit])
      (compiler-semantic-scope-node-region-add!
        (owned_view.compiler-owned-shared-view state)
        scope
        bound.scope
        body-id)
      (compiler-semantic-walk-node! state bound.scope bound.env body-id))))

(define (compiler-semantic-walk-foreach!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [name : i64]
  [index-ty : ast.AstType]
  [start-id : i64]
  [end-id : i64]
  [body-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (begin
    (compiler-semantic-walk-type!
      state
      (owned_view.compiler-owned-shared-view index-ty))
    (compiler-semantic-walk-node! state scope env start-id)
    (compiler-semantic-walk-node! state scope env end-id)
    (let
      [form-start : i64
        (compiler-semantic-maybe-span-start
          (owned_view.compiler-owned-shared-view state)
          maybe-span
          0)]
      [first-expr-start : i64
        (compiler-semantic-expr-start-offset
          state
          start-id
          (compiler-semantic-expr-start-offset
            state
            body-id
            (string.string-length state.source)))]
      [bound : CompilerSemanticBindResult
        (compiler-semantic-bind-local!
          state
          scope
          env
          name
          CompilerSemanticSymbolKind.Local
          (ast.AstMaybeType.Some (tc.tc-resolve-type state.ctx index-ty))
          (compiler-semantic-form-head-end state.source form-start)
          first-expr-start)]
      (begin
        (compiler-semantic-scope-node-region-add!
          (owned_view.compiler-owned-shared-view state)
          scope
          bound.scope
          body-id)
        (compiler-semantic-walk-node! state bound.scope bound.env body-id)))))

;; `(foreach-active [lane : i64] body...)` binds LANE, an i64, over the body.
(define (compiler-semantic-walk-foreach-active!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [lane : i64]
  [body-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [form-start : i64
      (compiler-semantic-maybe-span-start
        (owned_view.compiler-owned-shared-view state)
        maybe-span
        0)]
    [bound : CompilerSemanticBindResult
      (compiler-semantic-bind-local!
        state
        scope
        env
        lane
        CompilerSemanticSymbolKind.Local
        (ast.AstMaybeType.Some (ast.AstType.I64))
        (compiler-semantic-form-head-end state.source form-start)
        (compiler-semantic-expr-start-offset
          state
          body-id
          (string.string-length state.source)))]
    (begin
      (compiler-semantic-scope-node-region-add!
        (owned_view.compiler-owned-shared-view state)
        scope
        bound.scope
        body-id)
      (compiler-semantic-walk-node! state bound.scope bound.env body-id))))

(define (compiler-semantic-walk-spmd-reduce!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [index-name : i64]
  [index-ty : ast.AstType]
  [start-id : i64]
  [end-id : i64]
  [init-id : i64]
  [value-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [form-start : i64
      (compiler-semantic-maybe-span-start
        (owned_view.compiler-owned-shared-view state)
        maybe-span
        0)]
    [first-expr-start : i64
      (compiler-semantic-expr-start-offset
        state
        start-id
        (string.string-length state.source))]
    [bound : CompilerSemanticBindResult
      (compiler-semantic-bind-local!
        state
        scope
        env
        index-name
        CompilerSemanticSymbolKind.Local
        (ast.AstMaybeType.Some
          (tc.tc-resolve-type
            state.ctx
            (owned_view.compiler-owned-shared-view index-ty)))
        (compiler-semantic-form-head-end state.source form-start)
        first-expr-start)]
    (begin
      (compiler-semantic-walk-type! state index-ty)
      (compiler-semantic-walk-node! state scope env start-id)
      (compiler-semantic-walk-node! state scope env end-id)
      (compiler-semantic-walk-node! state scope env init-id)
      (compiler-semantic-scope-node-region-add!
        (owned_view.compiler-owned-shared-view state)
        scope
        bound.scope
        value-id)
      (compiler-semantic-walk-node! state bound.scope bound.env value-id))))

(define (compiler-semantic-walk-spmd-state!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [index-name : i64]
  [index-ty : ast.AstType]
  [start-id : i64]
  [end-id : i64]
  [state-name : i64]
  [state-ty : ast.AstType]
  [init-id : i64]
  [element-id : i64]
  [body-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [form-start : i64
      (compiler-semantic-maybe-span-start
        (owned_view.compiler-owned-shared-view state)
        maybe-span
        0)]
    [start-offset : i64
      (compiler-semantic-expr-start-offset
        state
        start-id
        (string.string-length state.source))]
    [index-bound : CompilerSemanticBindResult
      (compiler-semantic-bind-local!
        state
        scope
        env
        index-name
        CompilerSemanticSymbolKind.Local
        (ast.AstMaybeType.Some
          (tc.tc-resolve-type
            state.ctx
            (owned_view.compiler-owned-shared-view index-ty)))
        (compiler-semantic-form-head-end state.source form-start)
        start-offset)]
    [init-offset : i64
      (compiler-semantic-expr-start-offset
        state
        init-id
        (string.string-length state.source))]
    [state-bound : CompilerSemanticBindResult
      (compiler-semantic-bind-local!
        state
        index-bound.scope
        index-bound.env
        state-name
        CompilerSemanticSymbolKind.Local
        (ast.AstMaybeType.Some
          (tc.tc-resolve-type
            state.ctx
            (owned_view.compiler-owned-shared-view state-ty)))
        (compiler-semantic-expr-end-offset
          (owned_view.compiler-owned-shared-view state)
          end-id
          index-bound.next-search)
        init-offset)]
    (begin
      (compiler-semantic-walk-type! state index-ty)
      (compiler-semantic-walk-type! state state-ty)
      (compiler-semantic-walk-node! state scope env start-id)
      (compiler-semantic-walk-node! state scope env end-id)
      (compiler-semantic-walk-node! state scope env init-id)
      ;; The index remains active through both the element and body. The
      ;; state is a nested body-only extension, so its exit restores the
      ;; index before the enclosing index region restores the outer scope.
      (compiler-semantic-scope-region-add!
        state
        scope
        index-bound.scope
        (compiler-semantic-expr-start-offset state element-id -1)
        (compiler-semantic-expr-end-offset
          (owned_view.compiler-owned-shared-view state)
          body-id
          (string.string-length state.source)))
      (compiler-semantic-walk-node!
        state
        index-bound.scope
        index-bound.env
        element-id)
      (compiler-semantic-scope-node-region-add!
        (owned_view.compiler-owned-shared-view state)
        index-bound.scope
        state-bound.scope
        body-id)
      (compiler-semantic-walk-node!
        state
        state-bound.scope
        state-bound.env
        body-id))))

(define (compiler-semantic-walk-spmd-scan!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [index-name : i64]
  [index-ty : ast.AstType]
  [start-id : i64]
  [end-id : i64]
  [prefix-name : i64]
  [prefix-ty : ast.AstType]
  [init-id : i64]
  [value-id : i64]
  [body-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (compiler-semantic-walk-spmd-state!
    state
    scope
    env
    index-name
    index-ty
    start-id
    end-id
    prefix-name
    prefix-ty
    init-id
    value-id
    body-id
    maybe-span))

(define (compiler-semantic-walk-spmd-compact!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [index-name : i64]
  [index-ty : ast.AstType]
  [start-id : i64]
  [end-id : i64]
  [slot-name : i64]
  [slot-ty : ast.AstType]
  [init-id : i64]
  [keep-id : i64]
  [body-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (compiler-semantic-walk-spmd-state!
    state
    scope
    env
    index-name
    index-ty
    start-id
    end-id
    slot-name
    slot-ty
    init-id
    keep-id
    body-id
    maybe-span))

(define (compiler-semantic-walk-set!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [name-id : i64]
  [value-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [form-start : i64
      (compiler-semantic-maybe-span-start
        (owned_view.compiler-owned-shared-view state)
        maybe-span
        0)]
    [value-start : i64
      (compiler-semantic-expr-start-offset
        state
        value-id
        (string.string-length state.source))]
    [name : String
      (tc.tc-env-key-name-text-for-session
        (tc.tc-context-structural-session state.ctx)
        name-id)]
    [preferred-span : CompilerSemanticSpan
      (compiler-semantic-name-span-in-range
        state.path
        (owned_view.compiler-owned-shared-view state.source)
        (owned_view.compiler-owned-shared-view name)
        (compiler-semantic-form-head-end state.source form-start)
        value-start)]
    ;; Parser spans for `set!` may begin either at the form or directly at the
    ;; target binding. The ordinary form-head search handles the former; when
    ;; it has already skipped the target, retry from the retained origin so
    ;; direct writes keep an editable source span.
    [span : CompilerSemanticSpan
      (if (>= preferred-span.start-byte 0)
        preferred-span
        (compiler-semantic-name-span-in-range
          state.path
          (owned_view.compiler-owned-shared-view state.source)
          name
          form-start
          value-start))]
    (begin
      (compiler-semantic-record-name-write-span!
        (owned_view.compiler-owned-shared-view state)
        scope
        name-id
        span)
      (compiler-semantic-walk-node! state scope env value-id))))

(define (compiler-semantic-record-field-use-for-type!
  [state : CompilerSemanticWalkState]
  [receiver-ty : ast.AstType]
  [field-name-id : i64]
  [origin : parse_core.CompilerParseSemanticOrigin]
  [access : CompilerSemanticAccess]) : unit
  (match receiver-ty
    [(ast.AstType.Struct struct-name-id)
      (compiler-semantic-record-field-use-for-struct!
        state
        struct-name-id
        field-name-id
        origin
        access)]
    [(ast.AstType.StructArgs struct-name-id _)
      (compiler-semantic-record-field-use-for-struct!
        state
        struct-name-id
        field-name-id
        origin
        access)]
    [(ast.AstType.Ref _ inner)
      (compiler-semantic-record-field-use-for-type!
        (owned_view.compiler-owned-shared-view state)
        (tc.tc-context-type-get state.ctx inner)
        field-name-id
        origin
        access)]
    [(ast.AstType.MutRef _ inner)
      (compiler-semantic-record-field-use-for-type!
        (owned_view.compiler-owned-shared-view state)
        (tc.tc-context-type-get state.ctx inner)
        field-name-id
        origin
        access)]
    [_ unit]))

(define (compiler-semantic-record-field-use-for-struct!
  [state : CompilerSemanticWalkState]
  [struct-name-id : i64]
  [field-name-id : i64]
  [origin : parse_core.CompilerParseSemanticOrigin]
  [access : CompilerSemanticAccess]) : unit
  (match (csym.compiler-registries-lookup-struct-field-id
    (tc.tc-context-registries state.ctx)
    struct-name-id
    field-name-id)
    [(option_i64.None) unit]
    [(option_i64.Some handle)
      (let
        [owner-handle : i64 (compiler-semantic-field-owner-handle handle)]
        [symbol : CompilerSemanticSymbolId
          (compiler-semantic-member-symbol state.ctx owner-handle handle)]
        [display-name : String
          (tc.tc-env-key-name-text-for-session
            (tc.tc-context-structural-session state.ctx)
            field-name-id)]
        [type-text : String
          (match (tc.tc-struct-field-type-id
            state.ctx
            struct-name-id
            field-name-id)
            [(tc.ResultTcType.Ok ty) (tc.tc-type-render ty)]
            [(tc.ResultTcType.Err _) ""])]
        [span : CompilerSemanticSpan
          (compiler-semantic-exact-span-from-origin state origin)]
        (begin
          (compiler-semantic-record-module-origins-before!
            (owned_view.compiler-owned-shared-view state)
            origin.ordinal
            symbol.module-id)
          (compiler-semantic-record-vec-push!
            (&mut (__tl-box-place state.records))
            (CompilerSemanticRecord
              symbol
              -1
              CompilerSemanticRecordRole.Use
              (if state.generated
                CompilerSemanticAccess.None
                access)
              CompilerSemanticSymbolKind.Field
              (string.copy (& display-name))
              (string.copy (& type-text))
              ""
              symbol.module-id
              (owned_view.compiler-owned-shared-view span)
              (and (not state.generated) (>= span.start-byte 0))
              (owned_view.compiler-owned-shared-view state.provenance)))))]))

(define (compiler-semantic-record-field-use-with-span!
  [state : CompilerSemanticWalkState]
  [struct-name-id : i64]
  [field-name-id : i64]
  [span : CompilerSemanticSpan]
  [access : CompilerSemanticAccess]) : unit
  (match (csym.compiler-registries-lookup-struct-field-id
    (tc.tc-context-registries state.ctx)
    struct-name-id
    field-name-id)
    [(option_i64.None) unit]
    [(option_i64.Some handle)
      (let
        [owner-handle : i64 (compiler-semantic-field-owner-handle handle)]
        [symbol : CompilerSemanticSymbolId
          (compiler-semantic-member-symbol state.ctx owner-handle handle)]
        [display-name : String
          (tc.tc-env-key-name-text-for-session
            (tc.tc-context-structural-session state.ctx)
            field-name-id)]
        [type-text : String
          (match (tc.tc-struct-field-type-id
            state.ctx
            struct-name-id
            field-name-id)
            [(tc.ResultTcType.Ok ty) (tc.tc-type-render ty)]
            [(tc.ResultTcType.Err _) ""])]
        (compiler-semantic-record-vec-push!
          (&mut (__tl-box-place state.records))
          (CompilerSemanticRecord
            symbol
            -1
            CompilerSemanticRecordRole.Use
            (if state.generated
              CompilerSemanticAccess.None
              access)
            CompilerSemanticSymbolKind.Field
            (string.copy (& display-name))
            (string.copy (& type-text))
            ""
            symbol.module-id
            (owned_view.compiler-owned-shared-view span)
            (and (not state.generated) (>= span.start-byte 0))
            (owned_view.compiler-owned-shared-view state.provenance))))]))

(define (compiler-semantic-record-struct-field-use!
  [state : CompilerSemanticWalkState]
  [env : tc.TcTypeEnv]
  [target-id : i64]
  [field-name-id : i64]
  [access : CompilerSemanticAccess]) : unit
  (if (ast.ast-tuple-set-field-id? field-name-id)
    unit
    (match (compiler-semantic-origin-take!
      state
      parse_core.CompilerParseSemanticOriginKind.StructFieldUse)
      [(CompilerSemanticMaybeOrigin.None) unit]
      [(CompilerSemanticMaybeOrigin.Some origin)
        (match (tc.tc-expr-id state.ctx env target-id)
          [(tc.ResultTcType.Ok receiver-ty)
            (compiler-semantic-record-field-use-for-type!
              (owned_view.compiler-owned-shared-view state)
              (tc.tc-resolve-type state.ctx receiver-ty)
              field-name-id
              origin
              access)]
          [(tc.ResultTcType.Err _) unit])])))

(define (compiler-semantic-record-variant-pattern-use!
  [state : CompilerSemanticWalkState]
  [scrutinee-maybe-ty : ast.AstMaybeType]
  [variant-name-id : i64]) : unit
  (match (compiler-semantic-origin-take!
    state
    parse_core.CompilerParseSemanticOriginKind.EnumVariantPattern)
    [(CompilerSemanticMaybeOrigin.None) unit]
    [(CompilerSemanticMaybeOrigin.Some origin)
      (match scrutinee-maybe-ty
        [(ast.AstMaybeType.No) unit]
        [(ast.AstMaybeType.Some scrutinee-ty)
          (let
            [resolved : ast.AstType (tc.tc-resolve-type state.ctx scrutinee-ty)]
            [enum-name-id : i64
              (match resolved
                [(ast.AstType.Enum name) name]
                [(ast.AstType.EnumArgs name _) name]
                [_ -1])]
            (if (< enum-name-id 0)
              unit
              (let
                [handle : i64
                  (tc.tc-source-variant-handle-for-enum-id-or
                    state.ctx
                    enum-name-id
                    variant-name-id
                    (csym.compiler-symbols-missing-handle))]
                (if (not (csym.compiler-symbols-handle-found? handle))
                  unit
                  (let
                    [owner-handle : i64
                      (csym.compiler-registry-variant-owner-handle handle)]
                    [symbol : CompilerSemanticSymbolId
                      (compiler-semantic-member-symbol
                        state.ctx
                        owner-handle
                        handle)]
                    [display-name : String
                      (compiler-semantic-variant-display-name
                        state.ctx
                        variant-name-id
                        handle)]
                    [enum-text : String
                      (tc.tc-env-key-name-text-for-session
                        (tc.tc-context-structural-session state.ctx)
                        enum-name-id)]
                    [span : CompilerSemanticSpan
                      (compiler-semantic-exact-span-from-origin state origin)]
                    (begin
                      (compiler-semantic-record-module-origins-before!
                        (owned_view.compiler-owned-shared-view state)
                        origin.ordinal
                        symbol.module-id)
                      (compiler-semantic-record-vec-push!
                        (&mut (__tl-box-place state.records))
                        (CompilerSemanticRecord
                          symbol
                          -1
                          CompilerSemanticRecordRole.Use
                          CompilerSemanticAccess.Read
                          CompilerSemanticSymbolKind.EnumMember
                          (string.copy (& display-name))
                          (string.copy (& enum-text))
                          ""
                          symbol.module-id
                          (owned_view.compiler-owned-shared-view span)
                          (and (not state.generated) (>= span.start-byte 0))
                          (owned_view.compiler-owned-shared-view
                            state.provenance)))))))))])]))

(define (compiler-semantic-discard-variant-pattern-origin!
  [state : CompilerSemanticWalkState]) : unit
  (match (compiler-semantic-origin-take!
    state
    parse_core.CompilerParseSemanticOriginKind.EnumVariantPattern)
    [(CompilerSemanticMaybeOrigin.None) unit]
    [(CompilerSemanticMaybeOrigin.Some _) unit]))

(define (compiler-semantic-bind-pattern!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [fact-env : tc.TcTypeEnv]
  [facts-available : bool]
  [bound-names : tc.TcNameIdList]
  [pattern : ast.AstPattern]
  [scrutinee-maybe-ty : ast.AstMaybeType]
  [search-start : i64]
  [search-limit : i64]) : CompilerSemanticBindResult
  (match pattern
    [(ast.AstPattern.Var name maybe-ty)
      (if (tc.tc-name-id-list-contains bound-names name)
        (begin
          (compiler-semantic-discard-variant-pattern-origin!
            (owned_view.compiler-owned-shared-view state))
          (compiler-semantic-bind-local!
            state
            scope
            env
            name
            CompilerSemanticSymbolKind.Local
            (match maybe-ty
              [(ast.AstMaybeType.Some ty)
                ;; Preserve the existing public annotation text while the arm
                ;; body uses the checker's exact fact environment.
                (ast.AstMaybeType.Some (tc.tc-resolve-type state.ctx ty))]
              [(ast.AstMaybeType.No)
                (if facts-available
                  (match (tc.tc-lookup-visible-id state.ctx fact-env name)
                    [(tc.ResultTcType.Ok ty)
                      (ast.AstMaybeType.Some (tc.tc-resolve-type state.ctx ty))]
                    [(tc.ResultTcType.Err _) ast.AstMaybeType.No])
                  ast.AstMaybeType.No)])
            search-start
            search-limit))
        (begin
          (compiler-semantic-record-variant-pattern-use!
            state
            scrutinee-maybe-ty
            name)
          (CompilerSemanticBindResult scope env search-start)))]
    [(ast.AstPattern.Binding name)
      (if (tc.tc-name-id-list-contains bound-names name)
        (begin
          (compiler-semantic-discard-variant-pattern-origin!
            (owned_view.compiler-owned-shared-view state))
          (compiler-semantic-bind-local!
            state
            scope
            env
            name
            CompilerSemanticSymbolKind.Local
            (if facts-available
              (match (tc.tc-lookup-visible-id state.ctx fact-env name)
                [(tc.ResultTcType.Ok ty)
                  (ast.AstMaybeType.Some (tc.tc-resolve-type state.ctx ty))]
                [(tc.ResultTcType.Err _) ast.AstMaybeType.No])
              ast.AstMaybeType.No)
            search-start
            search-limit))
        (begin
          (compiler-semantic-record-variant-pattern-use!
            state
            scrutinee-maybe-ty
            name)
          (CompilerSemanticBindResult scope env search-start)))]
    [(ast.AstPattern.Tuple items)
      (compiler-semantic-bind-pattern-list!
        state
        scope
        env
        fact-env
        facts-available
        bound-names
        (deref items)
        ast.AstMaybeType.No
        search-start
        search-limit)]
    [(ast.AstPattern.Array items)
      (compiler-semantic-bind-pattern-list!
        state
        scope
        env
        fact-env
        facts-available
        bound-names
        (deref items)
        ast.AstMaybeType.No
        search-start
        search-limit)]
    [(ast.AstPattern.Variant name items)
      (begin
        (compiler-semantic-record-variant-pattern-use!
          (owned_view.compiler-owned-shared-view state)
          scrutinee-maybe-ty
          name)
        (compiler-semantic-bind-pattern-list!
          state
          scope
          env
          fact-env
          facts-available
          bound-names
          (deref items)
          ast.AstMaybeType.No
          search-start
          search-limit))]
    [_ (CompilerSemanticBindResult scope env search-start)]))

(define (compiler-semantic-bind-pattern-list!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [fact-env : tc.TcTypeEnv]
  [facts-available : bool]
  [bound-names : tc.TcNameIdList]
  [patterns : ast.AstPatternList]
  [scrutinee-maybe-ty : ast.AstMaybeType]
  [search-start : i64]
  [search-limit : i64]) : CompilerSemanticBindResult
  (let
    [next-scope : CompilerSemanticBindingSnapshot scope]
    [next-env : tc.TcTypeEnv env]
    [cursor : i64 search-start]
    [index : i64 0]
    (begin
      (while (< index (ast.ast-pattern-list-len (& patterns)))
        (let
          [bound : CompilerSemanticBindResult
            (compiler-semantic-bind-pattern!
              (owned_view.compiler-owned-shared-view state)
              next-scope
              next-env
              fact-env
              facts-available
              bound-names
              (ast.ast-pattern-list-get
                (& patterns)
                index
                (ast.ast-pattern-fallback))
              (owned_view.compiler-owned-shared-view scrutinee-maybe-ty)
              cursor
              search-limit)]
          (begin
            (set! next-scope bound.scope)
            (set! next-env bound.env)
            (set! cursor bound.next-search)
            (set! index (+ index 1)))))
      (CompilerSemanticBindResult next-scope next-env cursor))))

(define (compiler-semantic-pattern-bound-names
  [ctx : tc.TcContext]
  [scrutinee-ty : ast.AstType]
  [pattern : ast.AstPattern]) : tc.TcNameIdList
  ;; An explicitly typed pattern variable is always a binder, including when
  ;; the scrutinee is an enum. Bare enum variant names, by contrast, are not.
  (match (owned_view.compiler-owned-shared-view pattern)
    [(ast.AstPattern.Var name _)
      (tc.tc-name-id-list-add tc.TcNameIdList.Nil name)]
    [_ (tc.tc-borrow-check-pattern-bound-names ctx scrutinee-ty pattern)]))

(define (compiler-semantic-match-body-source-expr-id [body : i64]) : i64
  (let
    [inner : i64 (ast.ast-expr-span-wrapper-inner body)]
    (if (and (>= inner 0) (>= (ast.ast-expr-span-wrapper-inner inner) 0))
      inner
      body)))

(define (compiler-semantic-walk-match-arms!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [scrutinee-ty : ast.AstMaybeType]
  [arms : ast.AstMatchArmList]
  [search-start : i64]) : unit
  (let
    [index : i64 0]
    [cursor : i64 search-start]
    (while (< index (ast.ast-match-arm-list-len (& arms)))
      (begin
        (match (ast.ast-match-arm-list-get
          (& arms)
          index
          (ast.ast-match-arm-fallback))
          [(ast.AstMatchArm.Arm pattern body)
            (let
              [body-start : i64
                (compiler-semantic-expr-start-offset
                  state
                  (compiler-semantic-match-body-source-expr-id body)
                  (string.string-length state.source))]
              [saved : tc.TcTypeEnvScopedRuntimeSave
                (tc.tc-type-env-scoped-runtime-save env)]
              (begin
                (match (owned_view.compiler-owned-shared-view scrutinee-ty)
                  [(ast.AstMaybeType.Some ty)
                    (match (tc.tc-bind-match-pattern
                      state.ctx
                      env
                      (owned_view.compiler-owned-shared-view ty)
                      (owned_view.compiler-owned-shared-view pattern))
                      [(tc.ResultTcEnv.Ok fact-env)
                        (let
                          [bound : CompilerSemanticBindResult
                            (compiler-semantic-bind-pattern!
                              (owned_view.compiler-owned-shared-view state)
                              scope
                              env
                              fact-env
                              true
                              (compiler-semantic-pattern-bound-names
                                state.ctx
                                ty
                                (owned_view.compiler-owned-shared-view pattern))
                              pattern
                              (owned_view.compiler-owned-shared-view
                                scrutinee-ty)
                              cursor
                              body-start)]
                          (begin
                            (compiler-semantic-scope-node-region-add!
                              (owned_view.compiler-owned-shared-view state)
                              scope
                              bound.scope
                              (compiler-semantic-match-body-source-expr-id body))
                            (compiler-semantic-walk-node!
                              state
                              bound.scope
                              fact-env
                              body)))]
                      [(tc.ResultTcEnv.Err _)
                        (let
                          [bound : CompilerSemanticBindResult
                            (compiler-semantic-bind-pattern!
                              (owned_view.compiler-owned-shared-view state)
                              scope
                              env
                              env
                              false
                              (tc.tc-pattern-add-bound-name-ids
                                (owned_view.compiler-owned-shared-view pattern)
                                tc.TcNameIdList.Nil)
                              pattern
                              (owned_view.compiler-owned-shared-view
                                scrutinee-ty)
                              cursor
                              body-start)]
                          (begin
                            (compiler-semantic-scope-node-region-add!
                              (owned_view.compiler-owned-shared-view state)
                              scope
                              bound.scope
                              (compiler-semantic-match-body-source-expr-id body))
                            (compiler-semantic-walk-node!
                              state
                              bound.scope
                              bound.env
                              body)))])]
                  [(ast.AstMaybeType.No)
                    (let
                      [bound : CompilerSemanticBindResult
                        (compiler-semantic-bind-pattern!
                          (owned_view.compiler-owned-shared-view state)
                          scope
                          env
                          env
                          false
                          (tc.tc-pattern-add-bound-name-ids
                            (owned_view.compiler-owned-shared-view pattern)
                            tc.TcNameIdList.Nil)
                          pattern
                          (owned_view.compiler-owned-shared-view scrutinee-ty)
                          cursor
                          body-start)]
                      (begin
                        (compiler-semantic-scope-node-region-add!
                          (owned_view.compiler-owned-shared-view state)
                          scope
                          bound.scope
                          (compiler-semantic-match-body-source-expr-id body))
                        (compiler-semantic-walk-node!
                          state
                          bound.scope
                          bound.env
                          body)))])
                (tc.tc-type-env-scoped-runtime-restore! saved)
                (set!
                  cursor
                  (compiler-semantic-expr-end-offset
                    (owned_view.compiler-owned-shared-view state)
                    (compiler-semantic-match-body-source-expr-id body)
                    body-start))))])
        (set! index (+ index 1))))))

(define (compiler-semantic-walk-with-resources!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [bindings : ast.AstResourceBindingList]
  [body : ast.AstExprList]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [next-scope : CompilerSemanticBindingSnapshot scope]
    [next-env : tc.TcTypeEnv env]
    [form-start : i64
      (compiler-semantic-maybe-span-start
        (owned_view.compiler-owned-shared-view state)
        maybe-span
        0)]
    [form-end : i64
      (compiler-semantic-maybe-span-end
        (owned_view.compiler-owned-shared-view state)
        maybe-span
        (string.string-length state.source))]
    [cursor : i64 (compiler-semantic-form-head-end state.source form-start)]
    [index : i64 0]
    (begin
      (while (< index (ast.ast-resource-binding-list-len (& bindings)))
        (begin
          (match (ast.ast-resource-binding-list-get
            (& bindings)
            index
            (ast.ast-resource-binding-fallback))
            [(ast.AstResourceBinding.Binding name init cleanup _)
              (let
                [init-start : i64
                  (compiler-semantic-expr-start-offset
                    state
                    init
                    (string.string-length state.source))]
                (begin
                  (compiler-semantic-walk-node!
                    state
                    next-scope
                    next-env
                    cleanup)
                  (compiler-semantic-walk-node! state next-scope next-env init)
                  (let
                    [bound : CompilerSemanticBindResult
                      (let
                        [ctx : tc.TcContext state.ctx]
                        [expr-bases : i64 (tc.tc-context-expr-bases ctx)]
                        [cleanup-expr : ast.AstExpr
                          (ast.ast-expr-segment-bases-get expr-bases cleanup)]
                        (match (tc.tc-resource-cleanup-resource-type
                          ctx
                          next-env
                          cleanup-expr)
                          [(tc.ResultTcType.Ok expected-init-ty)
                            (match (tc.tc-expr-with-expected-or-actual-id
                              ctx
                              next-env
                              init
                              expected-init-ty)
                              [(tc.ResultTcType.Ok init-ty)
                                (let
                                  [binding-ty : ast.AstType
                                    (tc.tc-type-without-regions init-ty)]
                                  [recorded : CompilerSemanticBindResult
                                    (compiler-semantic-bind-local!
                                      state
                                      next-scope
                                      next-env
                                      name
                                      CompilerSemanticSymbolKind.Local
                                      (ast.AstMaybeType.Some
                                        (tc.tc-resolve-type
                                          ctx
                                          (owned_view.compiler-owned-shared-view
                                            binding-ty)))
                                      cursor
                                      init-start)]
                                  (CompilerSemanticBindResult
                                    recorded.scope
                                    (tc.tc-bind-id
                                      (tc.tc-bind-id
                                        next-env
                                        (tc.tc-cleanup-owner-marker-id)
                                        (ast.AstType.Var name))
                                      name
                                      binding-ty)
                                    recorded.next-search))]
                              [(tc.ResultTcType.Err _)
                                (compiler-semantic-bind-local!
                                  state
                                  next-scope
                                  next-env
                                  name
                                  CompilerSemanticSymbolKind.Local
                                  ast.AstMaybeType.No
                                  cursor
                                  init-start)])]
                          [(tc.ResultTcType.Err _)
                            (compiler-semantic-bind-local!
                              state
                              next-scope
                              next-env
                              name
                              CompilerSemanticSymbolKind.Local
                              ast.AstMaybeType.No
                              cursor
                              init-start)]))]
                    (begin
                      (let
                        [visible-start : i64
                          (compiler-semantic-expr-visibility-end-offset
                            (owned_view.compiler-owned-shared-view state)
                            cleanup
                            (compiler-semantic-expr-visibility-end-offset
                              (owned_view.compiler-owned-shared-view state)
                              init
                              bound.next-search))]
                        (compiler-semantic-scope-region-add!
                          state
                          next-scope
                          bound.scope
                          visible-start
                          form-end))
                      (set! next-scope bound.scope)
                      (set! next-env bound.env)
                      (set!
                        cursor
                        (compiler-semantic-expr-visibility-end-offset
                          (owned_view.compiler-owned-shared-view state)
                          cleanup
                          (compiler-semantic-expr-visibility-end-offset
                            (owned_view.compiler-owned-shared-view state)
                            init
                            bound.next-search)))))))])
          (set! index (+ index 1))))
      (compiler-semantic-walk-expr-list! state next-scope next-env body))))

(define (compiler-semantic-dotted-field-count [remaining-id : i64]) : i64
  (if (< remaining-id 0)
    0
    (+
      1
      (compiler-semantic-dotted-field-count
        (ci.intern-dotted-tail-id remaining-id)))))

(define (compiler-semantic-struct-name-for-type
  [state : CompilerSemanticWalkState]
  [ty : ast.AstType]) : i64
  (match (tc.tc-resolve-type state.ctx ty)
    [(ast.AstType.Struct name-id) name-id]
    [(ast.AstType.StructArgs name-id _) name-id]
    [(ast.AstType.Ref _ inner)
      (compiler-semantic-struct-name-for-type
        (owned_view.compiler-owned-shared-view state)
        (tc.tc-context-type-get state.ctx inner))]
    [(ast.AstType.MutRef _ inner)
      (compiler-semantic-struct-name-for-type
        (owned_view.compiler-owned-shared-view state)
        (tc.tc-context-type-get state.ctx inner))]
    [_ -1]))

(define (compiler-semantic-dotted-component-span
  [state : CompilerSemanticWalkState]
  [origin : ast.AstSourceSpan]
  [start : i64]
  [end : i64]
  [column-offset : i64]) : CompilerSemanticSpan
  (compiler-semantic-span-from-byte-range
    state.path
    state.source
    start
    end
    (ast.ast-source-span
      (ast.ast-source-span-start-line origin)
      (+ (ast.ast-source-span-start-col origin) column-offset)
      (ast.ast-source-span-start-line origin)
      (+ (ast.ast-source-span-start-col origin) column-offset (- end start)))))

(define (compiler-semantic-dotted-use-span!
  [state : CompilerSemanticWalkState]
  [source-name-id : i64]
  [fallback : CompilerSemanticMaybeSpan]) : CompilerSemanticMaybeSpan
  (let
    [session : cis.InternStructuralSessionHandle
      (tc.tc-context-structural-session state.ctx)]
    [written-id : i64 (tc.tc-dotted-name-source-id session source-name-id)]
    (if (or
      (< written-id 0)
      (>= written-id (ci.intern-capacity))
      (< (ci.intern-first-dot written-id) 0))
      CompilerSemanticMaybeSpan.None
      (match (compiler-semantic-origin-take!
        state
        parse_core.CompilerParseSemanticOriginKind.StructFieldUse)
        [(CompilerSemanticMaybeOrigin.Some origin)
          (CompilerSemanticMaybeSpan.Some origin.span)]
        [(CompilerSemanticMaybeOrigin.None) fallback]))))

;; Dotted syntax is ambiguous until checked resolution: the parser records a
;; field candidate for both `value.field` and `module.value`. Only consume that
;; candidate after the leading component is proven to be a struct-typed value;
;; otherwise the qualified-value walker owns the exact component origins.
(define (compiler-semantic-dotted-local-candidate?
  [state : CompilerSemanticWalkState]
  [env : tc.TcTypeEnv]
  [source-name-id : i64]) : bool
  (let
    [session : cis.InternStructuralSessionHandle
      (tc.tc-context-structural-session state.ctx)]
    [written-id : i64 (tc.tc-dotted-name-source-id session source-name-id)]
    (if (or
      (< written-id 0)
      (>= written-id (ci.intern-capacity))
      (< (ci.intern-first-dot written-id) 0))
      false
      (let
        [root-source-id : i64 (ci.intern-leading-dot-id written-id)]
        [recv-id : i64
          (tc.tc-dotted-name-with-source-id
            session
            source-name-id
            root-source-id)]
        (if (< recv-id 0)
          false
          (match (tc.tc-lookup-visible-id state.ctx env recv-id)
            [(tc.ResultTcType.Err _) false]
            [(tc.ResultTcType.Ok recv-ty)
              (>= (compiler-semantic-struct-name-for-type state recv-ty) 0)]))))))

(define (compiler-semantic-record-dotted-local-use!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [source-name-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]
  [last-access : CompilerSemanticAccess]) : bool
  (if (not
    (compiler-semantic-dotted-local-candidate?
      (owned_view.compiler-owned-shared-view state)
      env
      source-name-id))
    false
    (match (compiler-semantic-dotted-use-span!
      (owned_view.compiler-owned-shared-view state)
      source-name-id
      maybe-span)
      [(CompilerSemanticMaybeSpan.None) false]
      [(CompilerSemanticMaybeSpan.Some origin)
        (let
          [session : cis.InternStructuralSessionHandle
            (tc.tc-context-structural-session state.ctx)]
          [written-id : i64
            (tc.tc-dotted-name-source-id session source-name-id)]
          [root-source-id : i64 (ci.intern-leading-dot-id written-id)]
          [remaining-id : i64 (ci.intern-dotted-tail-id written-id)]
          [depth : i64 (compiler-semantic-dotted-field-count remaining-id)]
          (if (or (< root-source-id 0) (< remaining-id 0) (< depth 1))
            false
            (let
              [recv-id : i64
                (tc.tc-dotted-name-with-source-id
                  session
                  source-name-id
                  root-source-id)]
              [fields : (__tl_dyn-array i64) (__tl_make-array i64 depth)]
              [next-remaining : i64 remaining-id]
              [fill : i64 0]
              [recv-text : String (ci.intern-str root-source-id)]
              [expected-len : i64 (string.string-length recv-text)]
              (begin
                (while (< fill depth)
                  (let
                    [tail-id : i64 (ci.intern-dotted-tail-id next-remaining)]
                    [field : i64
                      (if (>= tail-id 0)
                        (ci.intern-leading-dot-id next-remaining)
                        next-remaining)]
                    (begin
                      (set! (array-ref fields fill) field)
                      (set!
                        expected-len
                        (+
                          expected-len
                          1
                          (string.string-length (ci.intern-str field))))
                      (set! next-remaining tail-id)
                      (set! fill (+ fill 1)))))
                (let
                  [start : i64
                    (compiler-semantic-state-source-offset
                      (owned_view.compiler-owned-shared-view state)
                      (ast.ast-source-span-start-line origin)
                      (ast.ast-source-span-start-col origin))]
                  [end : i64
                    (compiler-semantic-state-source-offset
                      (owned_view.compiler-owned-shared-view state)
                      (ast.ast-source-span-end-line origin)
                      (ast.ast-source-span-end-col origin))]
                  (if (or
                    (< depth 1)
                    (< recv-id 0)
                    (!= expected-len (- end start)))
                    false
                    (begin
                      (compiler-semantic-record-name-use-span!
                        (owned_view.compiler-owned-shared-view state)
                        scope
                        recv-id
                        (compiler-semantic-dotted-component-span
                          (owned_view.compiler-owned-shared-view state)
                          origin
                          start
                          (+ start (string.string-length recv-text))
                          0))
                      (match (tc.tc-lookup-visible-id state.ctx env recv-id)
                        [(tc.ResultTcType.Err _) unit]
                        [(tc.ResultTcType.Ok first-ty)
                          (let
                            [current-ty : ast.AstType first-ty]
                            [field-index : i64 0]
                            [cursor : i64
                              (+ start (string.string-length recv-text))]
                            [stop : bool false]
                            (while (and (not stop) (< field-index depth))
                              (let
                                [field-id : i64 (array-ref fields field-index)]
                                [field-text : String
                                  (tc.tc-env-key-name-text-for-session
                                    (tc.tc-context-structural-session state.ctx)
                                    field-id)]
                                [struct-name-id : i64
                                  (compiler-semantic-struct-name-for-type
                                    (owned_view.compiler-owned-shared-view
                                      state)
                                    (owned_view.compiler-owned-shared-view
                                      current-ty))]
                                [field-start : i64 (+ cursor 1)]
                                [field-end : i64
                                  (+
                                    field-start
                                    (string.string-length field-text))]
                                (if (< struct-name-id 0)
                                  (set! stop true)
                                  (begin
                                    (compiler-semantic-record-field-use-with-span!
                                      (owned_view.compiler-owned-shared-view
                                        state)
                                      struct-name-id
                                      field-id
                                      (compiler-semantic-dotted-component-span
                                        (owned_view.compiler-owned-shared-view
                                          state)
                                        origin
                                        field-start
                                        field-end
                                        (- field-start start))
                                      (if (= field-index (- depth 1))
                                        last-access
                                        CompilerSemanticAccess.Read))
                                    (if (< field-index (- depth 1))
                                      (match (tc.tc-struct-field-type-id
                                        state.ctx
                                        struct-name-id
                                        field-id)
                                        [(tc.ResultTcType.Ok next-ty)
                                          (set! current-ty next-ty)]
                                        [(tc.ResultTcType.Err _)
                                          (set! stop true)])
                                      unit)
                                    (set! cursor field-end)
                                    (set! field-index (+ field-index 1)))))))])
                      true)))))))])))

(define (compiler-semantic-walk-node-with-span!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [node-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [visited : (__tl_dyn-array i64)
      (owned_view.compiler-owned-shared-view state.visited-expr-ids)]
    (if (or
      (< node-id 0)
      (>= node-id (array-length visited))
      (!= (array-ref visited node-id) 0))
      unit
      (begin
        (set! (array-ref visited node-id) 1)
        (compiler-semantic-walk-expr! state scope env node-id maybe-span)))))

(define (compiler-semantic-walk-node!
  [state : (& state CompilerSemanticWalkState)]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [node-id : i64]) : unit
  (let
    [state : CompilerSemanticWalkState
      (owned_view.compiler-owned-reference-shared-view state)]
    (compiler-semantic-walk-node-with-span!
      state
      scope
      env
      node-id
      CompilerSemanticMaybeSpan.None)))

(define (compiler-semantic-walk-expr!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingSnapshot]
  [env : tc.TcTypeEnv]
  [node-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  ;; A source-span wrapper hands its span to the wrapped node. The arms below
  ;; resolve names, scopes and fields; every other variant's children are
  ;; walked through the AstExpr child schema.
  (let
    [spanned : i64 (ast.ast-expr-span-wrapper-inner node-id)]
    (if (>= spanned 0)
      (compiler-semantic-walk-node-with-span!
        state
        scope
        env
        spanned
        (match (ast.ast-expr-view-span node-id)
          [(ast.AstMaybeSourceSpan.Some span)
            (CompilerSemanticMaybeSpan.Some span)]
          [(ast.AstMaybeSourceSpan.No) maybe-span]))
      (match (ast.ast-node-get node-id)
        [(ast.AstExpr.MacroExpansion inner-id _ _)
          (compiler-semantic-walk-node-with-span!
            state
            scope
            env
            inner-id
            maybe-span)]
        [(ast.AstExpr.Var name)
          (if (compiler-semantic-record-dotted-local-use!
            (owned_view.compiler-owned-shared-view state)
            scope
            env
            name
            maybe-span
            CompilerSemanticAccess.Read)
            unit
            (compiler-semantic-record-name-use! state scope name maybe-span))]
        [(ast.AstExpr.Let payload)
          (match (__tl-box-place payload)
            [(ast.AstLet.Let bindings body)
              (compiler-semantic-walk-let!
                state
                scope
                env
                bindings
                body
                maybe-span)])]
        [(ast.AstExpr.Lambda payload)
          (match (__tl-box-place payload)
            [(ast.AstLambda.Lambda params maybe-ret body)
              (compiler-semantic-walk-lambda!
                state
                scope
                env
                params
                maybe-ret
                body
                maybe-span)])]
        [(ast.AstExpr.Set name value)
          (compiler-semantic-walk-set! state scope env name value maybe-span)]
        [(ast.AstExpr.Match payload)
          (match (__tl-box-place payload)
            [(ast.AstMatch.Match scrutinee arms)
              (begin
                (compiler-semantic-walk-node! state scope env scrutinee)
                (compiler-semantic-walk-match-arms!
                  (owned_view.compiler-owned-shared-view state)
                  scope
                  env
                  (match (tc.tc-expr-id state.ctx env scrutinee)
                    [(tc.ResultTcType.Ok ty) (ast.AstMaybeType.Some ty)]
                    [(tc.ResultTcType.Err _) ast.AstMaybeType.No])
                  arms
                  (compiler-semantic-expr-end-offset
                    (owned_view.compiler-owned-shared-view state)
                    scrutinee
                    (compiler-semantic-maybe-span-start state maybe-span 0))))])]
        [(ast.AstExpr.Foreach payload)
          (match (__tl-box-place payload)
            [(ast.AstForeach.Foreach name index-ty start end body)
              (compiler-semantic-walk-foreach!
                state
                scope
                env
                name
                index-ty
                start
                end
                body
                maybe-span)])]
        [(ast.AstExpr.ForeachActive lane body)
          (compiler-semantic-walk-foreach-active!
            state
            scope
            env
            lane
            body
            maybe-span)]
        [(ast.AstExpr.SpmdReduce payload)
          (match (__tl-box-place payload)
            [(ast.AstSpmdReduce.Reduce _ index index-ty start end init value)
              (compiler-semantic-walk-spmd-reduce!
                state
                scope
                env
                index
                index-ty
                start
                end
                init
                value
                maybe-span)])]
        [(ast.AstExpr.SpmdScan payload)
          (match (__tl-box-place payload)
            [(ast.AstSpmdScan.Scan
                _
                index
                index-ty
                start
                end
                prefix
                prefix-ty
                init
                value
                body)
              (compiler-semantic-walk-spmd-scan!
                state
                scope
                env
                index
                index-ty
                start
                end
                prefix
                prefix-ty
                init
                value
                body
                maybe-span)])]
        [(ast.AstExpr.SpmdCompact payload)
          (match (__tl-box-place payload)
            [(ast.AstSpmdCompact.Compact
                index
                index-ty
                start
                end
                slot
                slot-ty
                init
                keep
                body)
              (compiler-semantic-walk-spmd-compact!
                state
                scope
                env
                index
                index-ty
                start
                end
                slot
                slot-ty
                init
                keep
                body
                maybe-span)])]
        [(ast.AstExpr.StructGet target field)
          (begin
            (compiler-semantic-walk-node! state scope env target)
            (compiler-semantic-record-struct-field-use!
              state
              env
              target
              field
              CompilerSemanticAccess.Read))]
        [(ast.AstExpr.StructSet target field value)
          (begin
            (compiler-semantic-walk-node! state scope env target)
            (compiler-semantic-record-struct-field-use!
              (owned_view.compiler-owned-shared-view state)
              env
              target
              field
              CompilerSemanticAccess.Write)
            (compiler-semantic-walk-node! state scope env value))]
        [(ast.AstExpr.WithResource payload)
          (match (__tl-box-place payload)
            [(ast.AstWithResource.WithResource bindings body)
              (compiler-semantic-walk-with-resources!
                state
                scope
                env
                bindings
                body
                maybe-span)])]
        [(ast.AstExpr.Quote _) unit]
        [(ast.AstExpr.Quasiquote inner)
          (compiler-semantic-walk-quasiquote-node! state scope env inner)]
        [(ast.AstExpr.Replace _ _) unit]
        [(ast.AstExpr.ForOwnedState _) unit]
        [(ast.AstExpr.ForOwnedStep _) unit]
        [_
          (ast.ast-expr-for-each-child
            (ast.ast-node-get node-id)
            compiler-semantic-walk-node!
            compiler-semantic-walk-type-id!
            compiler-semantic-walk-child-type!
            ast.ast-child-unit
            state
            scope
            env)]))))

(define (compiler-semantic-walk-type-id!
  [state : (& state CompilerSemanticWalkState)]
  [_scope : CompilerSemanticBindingSnapshot]
  [_env : tc.TcTypeEnv]
  [ty-id : i64]) : unit
  (let
    [state : CompilerSemanticWalkState
      (owned_view.compiler-owned-reference-shared-view state)]
    (compiler-semantic-walk-type!
      state
      (tc.tc-context-type-get state.ctx ty-id))))

(define (compiler-semantic-walk-child-type!
  [state : (& state CompilerSemanticWalkState)]
  [_scope : CompilerSemanticBindingSnapshot]
  [_env : tc.TcTypeEnv]
  [ty : ast.AstType]) : unit
  (compiler-semantic-walk-type! state ty))

(define (compiler-semantic-decl-param-search-start
  [state : CompilerSemanticWalkState]
  [name-id : i64]
  [body-id : i64]) : i64
  (let
    [body-start : i64
      (compiler-semantic-expr-start-offset
        state
        body-id
        (string.string-length state.source))]
    [form-start : i64
      (if (>= state.form-start 0)
        state.form-start
        0)]
    [name-span : CompilerSemanticSpan
      (compiler-semantic-name-span-in-range
        state.path
        (owned_view.compiler-owned-shared-view state.source)
        (tc.tc-env-key-name-text-for-session
          (tc.tc-context-structural-session state.ctx)
          name-id)
        (compiler-semantic-form-head-end state.source form-start)
        body-start)]
    (if (>= name-span.end-byte 0)
      name-span.end-byte
      (compiler-semantic-form-head-end state.source form-start))))

(define (compiler-semantic-record-field-definition!
  [state : CompilerSemanticWalkState]
  [struct-name-id : i64]
  [field-name-id : i64]
  [field-index : i64]
  [ty : ast.AstType]) : unit
  (match (compiler-semantic-origin-take!
    state
    parse_core.CompilerParseSemanticOriginKind.StructFieldDefinition)
    [(CompilerSemanticMaybeOrigin.None) unit]
    [(CompilerSemanticMaybeOrigin.Some origin)
      (match (compiler-semantic-decl-handle
        state.ctx
        state.module-id
        struct-name-id
        CompilerSemanticSymbolKind.Struct)
        [(CompilerSemanticMaybeHandle.None) unit]
        [(CompilerSemanticMaybeHandle.Some owner-handle)
          (let
            [handle : i64
              (csym.compiler-registry-make-handle
                (csym.compiler-symbol-kind-struct-field)
                (csym.compiler-symbol-handle-index owner-handle)
                field-index)]
            [symbol : CompilerSemanticSymbolId
              (compiler-semantic-member-symbol state.ctx owner-handle handle)]
            [display-name : String
              (tc.tc-env-key-name-text-for-session
                (tc.tc-context-structural-session state.ctx)
                field-name-id)]
            [span : CompilerSemanticSpan
              (compiler-semantic-exact-span-from-origin state origin)]
            (begin
              (compiler-semantic-record-module-origins-before!
                (owned_view.compiler-owned-shared-view state)
                origin.ordinal
                symbol.module-id)
              (compiler-semantic-record-vec-push!
                (&mut (__tl-box-place state.records))
                (CompilerSemanticRecord
                  symbol
                  -1
                  CompilerSemanticRecordRole.Definition
                  CompilerSemanticAccess.None
                  CompilerSemanticSymbolKind.Field
                  (string.copy (& display-name))
                  (tc.tc-type-render (tc.tc-resolve-type state.ctx ty))
                  ""
                  symbol.module-id
                  (owned_view.compiler-owned-shared-view span)
                  (and (not state.generated) (>= span.start-byte 0))
                  (owned_view.compiler-owned-shared-view state.provenance)))))])]))

(define (compiler-semantic-walk-field-defs!
  [state : CompilerSemanticWalkState]
  [struct-name-id : i64]
  [fields : ast.AstFieldDefList]) : unit
  (let
    [index : i64 0]
    (while (< index (ast.ast-field-def-list-len (& fields)))
      (begin
        (match (ast.ast-field-def-list-get
          (& fields)
          index
          (ast.ast-field-def-fallback))
          [(ast.AstFieldDef.Def field-name-id ty _)
            (begin
              (compiler-semantic-record-field-definition!
                (owned_view.compiler-owned-shared-view state)
                struct-name-id
                (ci.intern-syntax-id-value field-name-id)
                index
                (owned_view.compiler-owned-shared-view ty))
              (compiler-semantic-walk-type! state ty))])
        (set! index (+ index 1))))))

(define (compiler-semantic-record-variant-definition!
  [state : CompilerSemanticWalkState]
  [enum-name-id : i64]
  [variant-name-id : i64]
  [variant-index : i64]) : unit
  (match (compiler-semantic-origin-take!
    state
    parse_core.CompilerParseSemanticOriginKind.EnumVariantDefinition)
    [(CompilerSemanticMaybeOrigin.None) unit]
    [(CompilerSemanticMaybeOrigin.Some origin)
      (match (compiler-semantic-decl-handle
        state.ctx
        state.module-id
        enum-name-id
        CompilerSemanticSymbolKind.Enum)
        [(CompilerSemanticMaybeHandle.None) unit]
        [(CompilerSemanticMaybeHandle.Some owner-handle)
          (let
            [handle : i64
              (csym.compiler-registry-make-handle
                (csym.compiler-symbol-kind-enum-variant)
                (csym.compiler-symbol-handle-index owner-handle)
                variant-index)]
            [symbol : CompilerSemanticSymbolId
              (compiler-semantic-member-symbol state.ctx owner-handle handle)]
            [display-name : String
              (tc.tc-env-key-name-text-for-session
                (tc.tc-context-structural-session state.ctx)
                variant-name-id)]
            [enum-text : String
              (tc.tc-env-key-name-text-for-session
                (tc.tc-context-structural-session state.ctx)
                enum-name-id)]
            [span : CompilerSemanticSpan
              (compiler-semantic-exact-span-from-origin state origin)]
            (begin
              (compiler-semantic-record-module-origins-before!
                (owned_view.compiler-owned-shared-view state)
                origin.ordinal
                symbol.module-id)
              (compiler-semantic-record-vec-push!
                (&mut (__tl-box-place state.records))
                (CompilerSemanticRecord
                  symbol
                  -1
                  CompilerSemanticRecordRole.Definition
                  CompilerSemanticAccess.None
                  CompilerSemanticSymbolKind.EnumMember
                  (string.copy (& display-name))
                  (string.copy (& enum-text))
                  ""
                  symbol.module-id
                  (owned_view.compiler-owned-shared-view span)
                  (and (not state.generated) (>= span.start-byte 0))
                  (owned_view.compiler-owned-shared-view state.provenance)))))])]))

(define (compiler-semantic-walk-variant-defs!
  [state : CompilerSemanticWalkState]
  [enum-name-id : i64]
  [variants : ast.AstVariantDefList]) : unit
  (let
    [index : i64 0]
    (while (< index (ast.ast-variant-def-list-len (& variants)))
      (begin
        (match (ast.ast-variant-def-list-get
          (& variants)
          index
          (ast.ast-variant-def-fallback))
          [(ast.AstVariantDef.Def variant-name-id payloads _)
            (begin
              (compiler-semantic-record-variant-definition!
                (owned_view.compiler-owned-shared-view state)
                enum-name-id
                variant-name-id
                index)
              (compiler-semantic-walk-type-list!
                (owned_view.compiler-owned-shared-view state)
                payloads))])
        (set! index (+ index 1))))))

(define (compiler-semantic-walk-dispatch-variants!
  [state : CompilerSemanticWalkState]
  [variants : ast.AstDispatchVariantList]) : unit
  (let
    [index : i64 0]
    (while (< index (ast.ast-dispatch-variant-list-len (& variants)))
      (begin
        (match (ast.ast-dispatch-variant-list-get
          (& variants)
          index
          (ast.ast-dispatch-variant-fallback))
          [(ast.AstDispatchVariant.Variant _ function-name-id)
            (match (compiler-semantic-origin-take!
              state
              parse_core.CompilerParseSemanticOriginKind.DispatchFunction)
              [(CompilerSemanticMaybeOrigin.None) unit]
              [(CompilerSemanticMaybeOrigin.Some origin)
                (let
                  [span : CompilerSemanticSpan
                    (compiler-semantic-exact-span-from-origin state origin)]
                  (compiler-semantic-record-top-use!
                    (owned_view.compiler-owned-shared-view state)
                    function-name-id
                    span
                    CompilerSemanticAccess.Read))])])
        (set! index (+ index 1))))))

(define (compiler-semantic-record-module-declaration!
  [state : CompilerSemanticWalkState]) : unit
  (let
    [done : bool false]
    (while (not done)
      (match (compiler-semantic-origin-take!
        state
        parse_core.CompilerParseSemanticOriginKind.ModuleDefinition)
        [(CompilerSemanticMaybeOrigin.Some origin)
          (compiler-semantic-record-module-origin!
            (owned_view.compiler-owned-shared-view state)
            origin
            state.module-id
            CompilerSemanticRecordRole.Definition)]
        [(CompilerSemanticMaybeOrigin.None) (set! done true)]))))

(define (compiler-semantic-record-import-alias-from-record!
  [state : CompilerSemanticWalkState]
  [record-index : i64]
  [origin : parse_core.CompilerParseSemanticOrigin]) : unit
  (if (< record-index 0)
    unit
    (let
      [record : CompilerSemanticRecord
        (owned_view.compiler-owned-array-element-shared-view
          (__tl-project-field (__tl-box-place state.records) items)
          record-index)]
      [span : CompilerSemanticSpan
        (compiler-semantic-exact-span-from-origin state origin)]
      (compiler-semantic-record-vec-push!
        (&mut (__tl-box-place state.records))
        (CompilerSemanticRecord
          record.symbol
          -1
          CompilerSemanticRecordRole.Definition
          CompilerSemanticAccess.None
          record.kind
          (string.copy (& record.display-name))
          (string.copy (& record.resolved-type))
          (string.copy (& record.documentation))
          record.module-id
          (owned_view.compiler-owned-shared-view span)
          (and (not state.generated) (>= span.start-byte 0))
          (owned_view.compiler-owned-shared-view state.provenance))))))

(define (compiler-semantic-selected-import-handle
  [state : (& state CompilerSemanticWalkState)]
  [target-module-id : i64]
  [item-id : i64]) : i64
  (let
    [symbols : (& state csym.CompilerSymbols) (tc.tc-context-symbols state.ctx)]
    [missing : i64 (csym.compiler-symbols-missing-handle)]
    [value-handle : i64
      (csym.compiler-symbols-lookup-value-in-module-id-or
        symbols
        target-module-id
        item-id
        missing)]
    [type-handle : i64
      (csym.compiler-symbols-lookup-type-in-module-id-or
        symbols
        target-module-id
        item-id
        missing)]
    (cond
      [(csym.compiler-symbols-handle-found? value-handle) value-handle]
      [(csym.compiler-symbols-handle-found? type-handle) type-handle]
      [else
        (csym.compiler-symbols-lookup-macro-in-module-id-or
          symbols
          target-module-id
          item-id
          missing)])))

(define (compiler-semantic-record-selected-import-use!
  [state : CompilerSemanticWalkState]
  [target-module-id : i64]
  [item-id : i64]
  [origin : parse_core.CompilerParseSemanticOrigin]) : i64
  (let
    [handle : i64
      (compiler-semantic-selected-import-handle state target-module-id item-id)]
    [before : i64 (__tl-project-field (__tl-box-place state.records) len)]
    [span : CompilerSemanticSpan
      (compiler-semantic-exact-span-from-origin state origin)]
    (if (not (csym.compiler-symbols-handle-found? handle))
      -1
      (begin
        (if (=
          (csym.compiler-symbol-handle-kind handle)
          (csym.compiler-symbol-kind-enum-variant))
          (compiler-semantic-record-variant-use!
            (owned_view.compiler-owned-shared-view state)
            item-id
            handle
            span
            CompilerSemanticAccess.Read)
          (let
            [decl : ast.AstDecl
              (compiler-semantic-handle-decl state.ctx handle)]
            (match (compiler-semantic-decl-symbol
              (owned_view.compiler-owned-shared-view decl))
              [(CompilerSemanticMaybeDecl.None) unit]
              [(CompilerSemanticMaybeDecl.Some decl-name-id decl-kind)
                (let
                  [decl-ctx : tc.TcContext
                    (tc.tc-context-with-module-id
                      state.ctx
                      (tc.macro-decl-module-display target-module-id)
                      target-module-id)]
                  [display-name : String
                    (tc.tc-env-key-name-text-for-session
                      (tc.tc-context-structural-session state.ctx)
                      decl-name-id)]
                  (compiler-semantic-record-vec-push!
                    (&mut (__tl-box-place state.records))
                    (CompilerSemanticRecord
                      (CompilerSemanticSymbolId
                        target-module-id
                        (csym.compiler-symbol-handle-index handle)
                        -1)
                      -1
                      CompilerSemanticRecordRole.Use
                      CompilerSemanticAccess.Read
                      decl-kind
                      (string.copy (& display-name))
                      (compiler-semantic-decl-type
                        decl-ctx
                        state.top-env
                        decl
                        decl-kind
                        decl-name-id
                        display-name)
                      ""
                      target-module-id
                      (owned_view.compiler-owned-shared-view span)
                      (and (not state.generated) (>= span.start-byte 0))
                      (owned_view.compiler-owned-shared-view state.provenance))))])))
        (if (> (__tl-project-field (__tl-box-place state.records) len) before)
          before
          -1)))))

(define (compiler-semantic-walk-import!
  [state : CompilerSemanticWalkState]
  [spec : ast.AstImportSpec]) : unit
  (match spec
    [(ast.AstImportSpec.Spec kind _ maybe-module maybe-alias _)
      (let
        [target-module-id : i64
          (match maybe-module
            [(ast.AstMaybeModuleName.Some module-name-id) module-name-id]
            [(ast.AstMaybeModuleName.No)
              (match maybe-alias
                [(ast.AstMaybeImportAlias.Some alias-id)
                  (tc.tc-qualified-access-target-module-id state.ctx alias-id)]
                [(ast.AstMaybeImportAlias.No) state.module-id])])]
        (match kind
          [(ast.AstImportKind.ModuleItem item-id)
            (let
              [done : bool false]
              [pending : CompilerSemanticMaybeOrigin
                CompilerSemanticMaybeOrigin.None]
              [selected-record-index : i64 -1]
              (begin
                ;; A selected import's final dotted component is the item, not
                ;; another namespace component. Keep one occurrence pending so
                ;; all preceding components become module uses and the final
                ;; one receives the checked declaration identity.
                (while (not done)
                  (match (compiler-semantic-origin-take!
                    state
                    parse_core.CompilerParseSemanticOriginKind.ModulePath)
                    [(CompilerSemanticMaybeOrigin.Some origin)
                      (begin
                        (match pending
                          [(CompilerSemanticMaybeOrigin.Some qualifier)
                            (compiler-semantic-record-module-origin!
                              (owned_view.compiler-owned-shared-view state)
                              qualifier
                              target-module-id
                              CompilerSemanticRecordRole.Use)]
                          [(CompilerSemanticMaybeOrigin.None) unit])
                        (set! pending (CompilerSemanticMaybeOrigin.Some origin)))]
                    [(CompilerSemanticMaybeOrigin.None) (set! done true)]))
                (match pending
                  [(CompilerSemanticMaybeOrigin.Some item-origin)
                    (set!
                      selected-record-index
                      (compiler-semantic-record-selected-import-use!
                        (owned_view.compiler-owned-shared-view state)
                        target-module-id
                        item-id
                        item-origin))]
                  [(CompilerSemanticMaybeOrigin.None) unit])
                (match (compiler-semantic-origin-take!
                  state
                  parse_core.CompilerParseSemanticOriginKind.ImportAlias)
                  [(CompilerSemanticMaybeOrigin.Some origin)
                    (compiler-semantic-record-import-alias-from-record!
                      state
                      selected-record-index
                      origin)]
                  [(CompilerSemanticMaybeOrigin.None) unit])))]
          [_
            (let
              [done : bool false]
              (begin
                (while (not done)
                  (match (compiler-semantic-origin-take!
                    state
                    parse_core.CompilerParseSemanticOriginKind.ModulePath)
                    [(CompilerSemanticMaybeOrigin.Some origin)
                      (compiler-semantic-record-module-origin!
                        (owned_view.compiler-owned-shared-view state)
                        origin
                        target-module-id
                        CompilerSemanticRecordRole.Use)]
                    [(CompilerSemanticMaybeOrigin.None) (set! done true)]))
                (match (compiler-semantic-origin-take!
                  state
                  parse_core.CompilerParseSemanticOriginKind.ImportAlias)
                  [(CompilerSemanticMaybeOrigin.Some origin)
                    ;; Module alias definitions share the target module's
                    ;; semantic identity with qualified uses of that alias.
                    (compiler-semantic-record-module-origin!
                      state
                      origin
                      target-module-id
                      CompilerSemanticRecordRole.Definition)]
                  [(CompilerSemanticMaybeOrigin.None) unit])))]))]))

(define (compiler-semantic-walk-decl!
  [state : CompilerSemanticWalkState]
  [decl : ast.AstDecl]) : unit
  (match decl
    [(ast.AstDecl.Def _ _ maybe-ty value)
      (begin
        (match maybe-ty
          [(ast.AstMaybeType.Some ty) (compiler-semantic-walk-type! state ty)]
          [(ast.AstMaybeType.No) unit])
        (compiler-semantic-walk-node!
          state
          (compiler-semantic-binding-snapshot-empty)
          state.top-env
          value))]
    [(ast.AstDecl.DefFn _ name params ret body _)
      (let
        [body-start : i64
          (compiler-semantic-expr-start-offset
            state
            body
            (string.string-length state.source))]
        [bound : CompilerSemanticBindResult
          (compiler-semantic-bind-params!
            (owned_view.compiler-owned-shared-view state)
            (compiler-semantic-binding-snapshot-empty)
            state.top-env
            params
            (compiler-semantic-decl-param-search-start
              (owned_view.compiler-owned-shared-view state)
              name
              body)
            body-start)]
        (begin
          (compiler-semantic-walk-type! state ret)
          (compiler-semantic-scope-node-region-add!
            (owned_view.compiler-owned-shared-view state)
            (compiler-semantic-binding-snapshot-empty)
            bound.scope
            body)
          (compiler-semantic-walk-node! state bound.scope bound.env body)))]
    [(ast.AstDecl.DefMacro _ name params ret body)
      (let
        [body-start : i64
          (compiler-semantic-expr-start-offset
            state
            body
            (string.string-length state.source))]
        [bound : CompilerSemanticBindResult
          (compiler-semantic-bind-macro-params!
            (owned_view.compiler-owned-shared-view state)
            (compiler-semantic-binding-snapshot-empty)
            state.top-env
            params
            (compiler-semantic-decl-param-search-start
              (owned_view.compiler-owned-shared-view state)
              name
              body)
            body-start)]
        (begin
          (compiler-semantic-walk-type! state ret)
          (compiler-semantic-scope-node-region-add!
            (owned_view.compiler-owned-shared-view state)
            (compiler-semantic-binding-snapshot-empty)
            bound.scope
            body)
          (compiler-semantic-walk-node! state bound.scope bound.env body)))]
    [(ast.AstDecl.Test _ body _ _)
      (compiler-semantic-walk-node!
        state
        (compiler-semantic-binding-snapshot-empty)
        state.top-env
        body)]
    [(ast.AstDecl.Extern _ _ _ _ ty) (compiler-semantic-walk-type! state ty)]
    [(ast.AstDecl.DefEnum _ name _ variants)
      (compiler-semantic-walk-variant-defs! state name variants)]
    [(ast.AstDecl.DefEnumLifetimes _ name _ _ variants)
      (compiler-semantic-walk-variant-defs! state name variants)]
    [(ast.AstDecl.DefStruct _ name _ _ fields)
      (compiler-semantic-walk-field-defs! state name fields)]
    [(ast.AstDecl.DefStructLifetimes _ name _ _ _ fields)
      (compiler-semantic-walk-field-defs! state name fields)]
    [(ast.AstDecl.DefDispatch _ _ variants)
      (compiler-semantic-walk-dispatch-variants! state variants)]
    [(ast.AstDecl.Module _)
      (compiler-semantic-record-module-declaration! state)]
    [(ast.AstDecl.ModuleBody _ _)
      (compiler-semantic-record-module-declaration! state)]
    [(ast.AstDecl.Import _ spec) (compiler-semantic-walk-import! state spec)]
    [(ast.AstDecl.Unsafe inner)
      (compiler-semantic-walk-decl! state (deref inner))]
    [_ unit]))

(define (compiler-semantic-source-for-path
  [path : String]
  [entry-path : (& entry-path str)]
  [entry-source : (& entry-source str)]) : String
  (cond
    [(string.eq path entry-path) (string.copy entry-source)]
    [(and
        (not (string.eq path ""))
        (io.file-exists? (owned_view.compiler-owned-shared-view path)))
      (byte_buf.to-string (io.read-file path))]
    [else ""]))

(define (compiler-semantic-record-macro-call-site!
  [state : CompilerSemanticWalkState]
  [sites : tc.TcMacroCallSiteState]
  [site-index : i64]
  [source : String]) : unit
  (let
    [ctx : tc.TcContext state.ctx]
    [env : tc.TcTypeEnv state.top-env]
    [name-id : i64
      (tc.tc-macro-call-site-macro-name-id-for-state sites site-index)]
    [definition-module-id : i64
      (tc.tc-macro-call-site-definition-module-id-for-state sites site-index)]
    [declaration-id : i64
      (tc.tc-macro-call-site-declaration-id-for-state sites site-index)]
    [source-span : ast.AstSourceSpan
      (tc.tc-macro-call-site-span-for-state sites site-index)]
    [site-editable : bool
      (tc.tc-macro-call-site-editable-for-state? sites site-index)]
    [display-name : String
      (tc.tc-env-key-name-text-for-session
        (tc.tc-context-structural-session ctx)
        name-id)]
    [decl-ctx : tc.TcContext
      (if (= definition-module-id cbi.compiler-builtin-id-fix-empty)
        (tc.tc-context-with-module-id ctx "" cbi.compiler-builtin-id-fix-empty)
        (tc.tc-context-with-module-id
          ctx
          (tc.macro-decl-module-display definition-module-id)
          definition-module-id))]
    [symbol : CompilerSemanticSymbolId
      (compiler-semantic-symbol-for-decl
        decl-ctx
        definition-module-id
        declaration-id
        name-id
        CompilerSemanticSymbolKind.Macro)]
    [resolved-type : String
      (match (compiler-semantic-decl-handle
        decl-ctx
        definition-module-id
        name-id
        CompilerSemanticSymbolKind.Macro)
        [(CompilerSemanticMaybeHandle.Some handle)
          (compiler-semantic-decl-type
            decl-ctx
            env
            (compiler-semantic-handle-decl decl-ctx handle)
            CompilerSemanticSymbolKind.Macro
            name-id
            (owned_view.compiler-owned-shared-view display-name))]
        [(CompilerSemanticMaybeHandle.None) "macro"])]
    [path : String (tc.tc-macro-call-site-path-for-state sites site-index)]
    [span : CompilerSemanticSpan
      (if (and site-editable (not (string.eq source "")))
        (compiler-semantic-use-span-from-origin path source source-span)
        (CompilerSemanticSpan (string.copy (& path)) -1 -1 source-span -1 -1))]
    [editable : bool (and site-editable (>= span.start-byte 0))]
    [generator : String
      (tc.tc-macro-call-site-generator-for-state sites site-index)]
    [item : String (tc.tc-macro-call-site-item-for-state sites site-index)]
    [key : String (tc.tc-macro-call-site-key-for-state sites site-index)]
    [provenance : CompilerSemanticProvenance
      (if editable
        CompilerSemanticProvenance.EditableSource
        (CompilerSemanticProvenance.Generated
          (string.copy (& generator))
          (string.copy (& item))
          (string.copy (& key))))]
    (compiler-semantic-record-vec-push!
      (&mut (__tl-box-place state.records))
      (CompilerSemanticRecord
        symbol
        -1
        CompilerSemanticRecordRole.Use
        (if editable
          CompilerSemanticAccess.Read
          CompilerSemanticAccess.None)
        CompilerSemanticSymbolKind.Macro
        (string.copy (& display-name))
        (string.copy (& resolved-type))
        ""
        symbol.module-id
        span
        editable
        provenance))))

(define (compiler-semantic-record-macro-call-sites!
  [state : CompilerSemanticWalkState]
  [entry-path : (& entry-path str)]
  [entry-source : (& entry-source str)]) : unit
  (let
    [sites : tc.TcMacroCallSiteState
      (tc.tc-job-state-macro-call-sites (tc.tc-context-job-state state.ctx))]
    [count : i64 (tc.tc-macro-call-site-count-for-state sites)]
    [index : i64 0]
    [cached : bool false]
    [cached-path : String ""]
    [cached-source : String ""]
    (while (< index count)
      (let
        [path : String (tc.tc-macro-call-site-path-for-state sites index)]
        [editable : bool
          (tc.tc-macro-call-site-editable-for-state? sites index)]
        (begin
          (if (and
            editable
            (or (not cached) (not (string.eq path cached-path))))
            (begin
              (set! cached-path (string.copy (& path)))
              (set!
                cached-source
                (compiler-semantic-source-for-path path entry-path entry-source))
              (set! cached true))
            unit)
          (compiler-semantic-record-macro-call-site!
            (owned_view.compiler-owned-shared-view state)
            sites
            index
            (if editable
              (owned_view.compiler-owned-shared-view cached-source)
              ""))
          (set! index (+ index 1)))))))

(define (compiler-semantic-i64-min [left : i64] [right : i64]) : i64
  (if (< left right)
    left
    right))

(define (compiler-semantic-scope-event-before?
  [left : CompilerSemanticScopeEvent]
  [right : CompilerSemanticScopeEvent]) : bool
  (cond
    [(< left.byte-offset right.byte-offset) true]
    [(> left.byte-offset right.byte-offset) false]
    [(< left.kind right.kind) true]
    [(> left.kind right.kind) false]
    [(= left.kind (compiler-semantic-scope-event-kind-end))
      (if (= left.child-head right.child-head)
        (< left.sequence right.sequence)
        (> left.child-head right.child-head))]
    [(= left.child-head right.child-head) (< left.sequence right.sequence)]
    [else (< left.child-head right.child-head)]))

(define (compiler-semantic-scope-events-sort-segment!
  [items : (&mut items (__tl_dyn-array CompilerSemanticScopeEvent))]
  [offset : i64]
  [len : i64]) : unit
  (if (< len 2)
    unit
    (let
      [scratch : (__tl_dyn-array CompilerSemanticScopeEvent)
        (__tl_make-array CompilerSemanticScopeEvent len)]
      [width : i64 1]
      (while (< width len)
        (let
          [run : i64 0]
          (begin
            (while (< run len)
              (let
                [mid : i64 (compiler-semantic-i64-min (+ run width) len)]
                [end : i64 (compiler-semantic-i64-min (+ run (* width 2)) len)]
                [left : i64 run]
                [right : i64 mid]
                [out : i64 run]
                (begin
                  (while (< out end)
                    (if (or
                      (>= right end)
                      (and
                        (< left mid)
                        (not
                          (compiler-semantic-scope-event-before?
                            (array-ref items (+ offset right))
                            (array-ref items (+ offset left))))))
                      (begin
                        (set!
                          (array-ref scratch out)
                          (array-ref items (+ offset left)))
                        (set! left (+ left 1)))
                      (begin
                        (set!
                          (array-ref scratch out)
                          (array-ref items (+ offset right)))
                        (set! right (+ right 1))))
                    (set! out (+ out 1)))
                  (set! run end))))
            (let
              [copy-index : i64 0]
              (while (< copy-index len)
                (begin
                  (set!
                    (array-ref items (+ offset copy-index))
                    (array-ref scratch copy-index))
                  (set! copy-index (+ copy-index 1)))))
            (set! width (* width 2))))))))

(define (compiler-semantic-module-event-before?
  [left : CompilerSemanticModuleEvent]
  [right : CompilerSemanticModuleEvent]) : bool
  (if (= left.byte-offset right.byte-offset)
    (< left.sequence right.sequence)
    (< left.byte-offset right.byte-offset)))

(define (compiler-semantic-module-events-sort-segment!
  [items : (&mut items (__tl_dyn-array CompilerSemanticModuleEvent))]
  [offset : i64]
  [len : i64]) : unit
  (if (< len 2)
    unit
    (let
      [scratch : (__tl_dyn-array CompilerSemanticModuleEvent)
        (__tl_make-array CompilerSemanticModuleEvent len)]
      [width : i64 1]
      (while (< width len)
        (let
          [run : i64 0]
          (begin
            (while (< run len)
              (let
                [mid : i64 (compiler-semantic-i64-min (+ run width) len)]
                [end : i64 (compiler-semantic-i64-min (+ run (* width 2)) len)]
                [left : i64 run]
                [right : i64 mid]
                [out : i64 run]
                (begin
                  (while (< out end)
                    (if (or
                      (>= right end)
                      (and
                        (< left mid)
                        (not
                          (compiler-semantic-module-event-before?
                            (array-ref items (+ offset right))
                            (array-ref items (+ offset left))))))
                      (begin
                        (set!
                          (array-ref scratch out)
                          (array-ref items (+ offset left)))
                        (set! left (+ left 1)))
                      (begin
                        (set!
                          (array-ref scratch out)
                          (array-ref items (+ offset right)))
                        (set! right (+ right 1))))
                    (set! out (+ out 1)))
                  (set! run end))))
            (let
              [copy-index : i64 0]
              (while (< copy-index len)
                (begin
                  (set!
                    (array-ref items (+ offset copy-index))
                    (array-ref scratch copy-index))
                  (set! copy-index (+ copy-index 1)))))
            (set! width (* width 2))))))))

(define (compiler-semantic-bucket-scope-events!
  [paths : (__tl_dyn-array CompilerSemanticSourcePathInfo)]
  [path-len : i64]
  [raw : (__tl_dyn-array CompilerSemanticScopeEvent)]
  [raw-len : i64]
  [out : (&mut out (__tl_dyn-array CompilerSemanticScopeEvent))]) : unit
  (let
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 path-len)]
    [cursors : (__tl_dyn-array i64) (__tl_make-array i64 path-len)]
    [index : i64 0]
    (begin
      (while (< index raw-len)
        (let
          [event : CompilerSemanticScopeEvent
            (owned_view.compiler-owned-array-element-shared-view raw index)]
          (begin
            (set!
              (array-ref counts event.path-index)
              (+
                (owned_view.compiler-owned-array-element-shared-view
                  counts
                  event.path-index)
                1))
            (set! index (+ index 1)))))
      (let
        [path-index : i64 0]
        [offset : i64 0]
        (while (< path-index path-len)
          (let
            [info : CompilerSemanticSourcePathInfo
              (owned_view.compiler-owned-array-element-shared-view
                paths
                path-index)]
            [count : i64
              (owned_view.compiler-owned-array-element-shared-view
                counts
                path-index)]
            (begin
              (set! info.scope-event-offset offset)
              (set! info.scope-event-len count)
              (set! (array-ref paths path-index) info)
              (set! offset (+ offset count))
              (set! path-index (+ path-index 1))))))
      (set! index 0)
      (while (< index raw-len)
        (let
          [event : CompilerSemanticScopeEvent
            (owned_view.compiler-owned-array-element-shared-view raw index)]
          [info : CompilerSemanticSourcePathInfo
            (owned_view.compiler-owned-array-element-shared-view
              paths
              event.path-index)]
          [cursor : i64
            (owned_view.compiler-owned-array-element-shared-view
              cursors
              event.path-index)]
          (begin
            (set! (array-ref out (+ info.scope-event-offset cursor)) event)
            (set! (array-ref cursors event.path-index) (+ cursor 1))
            (set! index (+ index 1)))))
      (let
        [path-index : i64 0]
        (while (< path-index path-len)
          (let
            [info : CompilerSemanticSourcePathInfo
              (owned_view.compiler-owned-array-element-shared-view
                paths
                path-index)]
            (begin
              (compiler-semantic-scope-events-sort-segment!
                out
                info.scope-event-offset
                info.scope-event-len)
              (set! path-index (+ path-index 1)))))))))

(define (compiler-semantic-bucket-module-events!
  [paths : (__tl_dyn-array CompilerSemanticSourcePathInfo)]
  [path-len : i64]
  [raw : (__tl_dyn-array CompilerSemanticModuleEvent)]
  [raw-len : i64]
  [out : (&mut out (__tl_dyn-array CompilerSemanticModuleEvent))]) : unit
  (let
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 path-len)]
    [cursors : (__tl_dyn-array i64) (__tl_make-array i64 path-len)]
    [index : i64 0]
    (begin
      (while (< index raw-len)
        (let
          [event : CompilerSemanticModuleEvent
            (owned_view.compiler-owned-array-element-shared-view raw index)]
          (begin
            (set!
              (array-ref counts event.path-index)
              (+
                (owned_view.compiler-owned-array-element-shared-view
                  counts
                  event.path-index)
                1))
            (set! index (+ index 1)))))
      (let
        [path-index : i64 0]
        [offset : i64 0]
        (while (< path-index path-len)
          (let
            [info : CompilerSemanticSourcePathInfo
              (owned_view.compiler-owned-array-element-shared-view
                paths
                path-index)]
            [count : i64
              (owned_view.compiler-owned-array-element-shared-view
                counts
                path-index)]
            (begin
              (set! info.module-event-offset offset)
              (set! info.module-event-len count)
              (set! (array-ref paths path-index) info)
              (set! offset (+ offset count))
              (set! path-index (+ path-index 1))))))
      (set! index 0)
      (while (< index raw-len)
        (let
          [event : CompilerSemanticModuleEvent
            (owned_view.compiler-owned-array-element-shared-view raw index)]
          [info : CompilerSemanticSourcePathInfo
            (owned_view.compiler-owned-array-element-shared-view
              paths
              event.path-index)]
          [cursor : i64
            (owned_view.compiler-owned-array-element-shared-view
              cursors
              event.path-index)]
          (begin
            (set! (array-ref out (+ info.module-event-offset cursor)) event)
            (set! (array-ref cursors event.path-index) (+ cursor 1))
            (set! index (+ index 1)))))
      (let
        [path-index : i64 0]
        (while (< path-index path-len)
          (let
            [info : CompilerSemanticSourcePathInfo
              (owned_view.compiler-owned-array-element-shared-view
                paths
                path-index)]
            (begin
              (compiler-semantic-module-events-sort-segment!
                out
                info.module-event-offset
                info.module-event-len)
              (set! path-index (+ path-index 1)))))))))

(define (compiler-semantic-map-key-name-for-module
  [key-id : i64]
  [module-id : i64]) : i64
  (cond
    [(csym.compiler-composite-triple-key-id? key-id) -1]
    [(csym.compiler-composite-pair-key-id? key-id)
      (if (= (csym.compiler-composite-pair-left-id key-id) module-id)
        (csym.compiler-composite-pair-right-id key-id)
        -1)]
    [(csym.compiler-symbol-root-module-id? module-id) key-id]
    [else -1]))

(define (compiler-semantic-map-kind-supported?
  [namespace-tag : i64]
  [kind : i64]) : bool
  (cond
    [(= namespace-tag (compiler-semantic-binding-namespace-value-mask))
      (or
        (= kind (csym.compiler-symbol-kind-value-define))
        (= kind (csym.compiler-symbol-kind-function-define))
        (= kind (csym.compiler-symbol-kind-extern))
        (= kind (csym.compiler-symbol-kind-defstruct))
        (= kind (csym.compiler-symbol-kind-defdispatch)))]
    [(= namespace-tag (compiler-semantic-binding-namespace-type-mask))
      (or
        (= kind (csym.compiler-symbol-kind-defenum))
        (= kind (csym.compiler-symbol-kind-defstruct)))]
    [else (= kind (csym.compiler-symbol-kind-defmacro))]))

(define (compiler-semantic-map-has-module-macro?
  [map : (& map csym.CompilerSymbolMap)]
  [module-id : i64]) : bool
  (let
    [slot : i64 0]
    (begin
      (while (< slot (array-length map.keys))
        (let
          [stored-key : i64 (array-ref map.keys slot)]
          (if (and
            (> stored-key 0)
            (>=
              (compiler-semantic-map-key-name-for-module
                (- stored-key 1)
                module-id)
              0)
            (=
              (csym.compiler-symbol-handle-kind (array-ref map.values slot))
              (csym.compiler-symbol-kind-defmacro)))
            (return true)
            (set! slot (+ slot 1)))))
      false)))

(define (compiler-semantic-top-candidate-before?
  [left : CompilerSemanticTopCandidateRef]
  [right : CompilerSemanticTopCandidateRef]
  [labels : (__tl_dyn-array String)]
  [records : (__tl_dyn-array CompilerSemanticRecord)]) : bool
  (let
    [left-label : String
      (owned_view.compiler-owned-array-element-shared-view
        labels
        left.label-index)]
    [right-label : String
      (owned_view.compiler-owned-array-element-shared-view
        labels
        right.label-index)]
    (cond
      [(< left.namespace-tag right.namespace-tag) true]
      [(> left.namespace-tag right.namespace-tag) false]
      [(sort.string-less?
          (owned_view.compiler-owned-shared-view left-label)
          (owned_view.compiler-owned-shared-view right-label))
        true]
      [(sort.string-less? right-label left-label) false]
      [else
        (let
          [left-symbol : CompilerSemanticSymbolId
            (owned_view.compiler-owned-array-element-shared-view
              records
              left.record-index).symbol]
          [right-symbol : CompilerSemanticSymbolId
            (owned_view.compiler-owned-array-element-shared-view
              records
              right.record-index).symbol]
          (cond
            [(<
                left-symbol.declaration-ordinal
                right-symbol.declaration-ordinal)
              true]
            [(>
                left-symbol.declaration-ordinal
                right-symbol.declaration-ordinal)
              false]
            [else (< left.record-index right.record-index)]))])))

(define (compiler-semantic-top-candidates-sort-segment!
  [items : (&mut items (__tl_dyn-array CompilerSemanticTopCandidateRef))]
  [labels : (__tl_dyn-array String)]
  [records : (__tl_dyn-array CompilerSemanticRecord)]
  [offset : i64]
  [len : i64]) : unit
  (if (< len 2)
    unit
    (let
      [scratch : (__tl_dyn-array CompilerSemanticTopCandidateRef)
        (__tl_make-array CompilerSemanticTopCandidateRef len)]
      [width : i64 1]
      (while (< width len)
        (let
          [run : i64 0]
          (begin
            (while (< run len)
              (let
                [mid : i64 (compiler-semantic-i64-min (+ run width) len)]
                [end : i64 (compiler-semantic-i64-min (+ run (* width 2)) len)]
                [left : i64 run]
                [right : i64 mid]
                [out : i64 run]
                (begin
                  (while (< out end)
                    (if (or
                      (>= right end)
                      (and
                        (< left mid)
                        (not
                          (compiler-semantic-top-candidate-before?
                            (array-ref items (+ offset right))
                            (array-ref items (+ offset left))
                            (owned_view.compiler-owned-shared-view labels)
                            (owned_view.compiler-owned-shared-view records)))))
                      (begin
                        (set!
                          (array-ref scratch out)
                          (array-ref items (+ offset left)))
                        (set! left (+ left 1)))
                      (begin
                        (set!
                          (array-ref scratch out)
                          (array-ref items (+ offset right)))
                        (set! right (+ right 1))))
                    (set! out (+ out 1)))
                  (set! run end))))
            (let
              [copy-index : i64 0]
              (while (< copy-index len)
                (begin
                  (set!
                    (array-ref items (+ offset copy-index))
                    (array-ref scratch copy-index))
                  (set! copy-index (+ copy-index 1)))))
            (set! width (* width 2))))))))

(define (compiler-semantic-top-candidate-count-increment!
  [counts : (&mut counts (__tl_dyn-array i64))]
  [module-index : i64]) : unit
  (let
    [count : i64 (array-ref counts module-index)]
    (if (= count 9223372036854775807)
      (io.panic "semantic index: top candidate count overflow")
      (set! (array-ref counts module-index) (+ count 1)))))

(define (compiler-semantic-top-candidate-fill-index
  [modules : (& modules (__tl_dyn-array CompilerSemanticModuleInfo))]
  [module-index : i64]
  [cursors : (& cursors (__tl_dyn-array i64))]
  [out : (& out (__tl_dyn-array CompilerSemanticTopCandidateRef))]
  [labels : (& labels (__tl_dyn-array String))]) : i64
  (let
    [info : CompilerSemanticModuleInfo (array-ref modules module-index)]
    [out-index : i64 (array-ref cursors module-index)]
    [segment-end : i64 (+ info.candidate-offset info.candidate-len)]
    (if (or
      (< out-index info.candidate-offset)
      (>= out-index segment-end)
      (>= out-index (array-length out))
      (>= out-index (array-length labels)))
      (io.panic "semantic index: top candidate count/fill mismatch")
      out-index)))

(define (compiler-semantic-top-map-walk!
  [session : cis.InternStructuralSessionHandle]
  [symbols : (& symbols csym.CompilerSymbols)]
  [map : (& map csym.CompilerSymbolMap)]
  [namespace-tag : i64]
  [modules : (& modules (__tl_dyn-array CompilerSemanticModuleInfo))]
  [module-len : i64]
  [decl-record-indices : (& decl-record-indices (__tl_dyn-array i64))]
  [counts-or-cursors : (&mut counts-or-cursors (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array CompilerSemanticTopCandidateRef))]
  [labels : (&mut labels (__tl_dyn-array String))]
  [count-only : bool]) : unit
  (let
    [slot : i64 0]
    (while (< slot (array-length map.keys))
      (let
        [stored-key : i64 (array-ref map.keys slot)]
        (begin
          (if (> stored-key 0)
            (let
              [key-id : i64 (- stored-key 1)]
              [handle : i64 (array-ref map.values slot)]
              [kind : i64 (csym.compiler-symbol-handle-kind handle)]
              [decl-index : i64 (csym.compiler-symbol-handle-index handle)]
              [owner-module-id : i64
                (csym.compiler-symbols-owner-module-id-at-index-or
                  symbols
                  decl-index
                  (csym.compiler-symbol-root-module-id))]
              [key-is-pair : bool (csym.compiler-composite-pair-key-id? key-id)]
              [module-id : i64
                (if key-is-pair
                  (csym.compiler-composite-pair-left-id key-id)
                  owner-module-id)]
              [name-id : i64
                (if key-is-pair
                  (csym.compiler-composite-pair-right-id key-id)
                  key-id)]
              [module-index : i64
                (if (or
                  (csym.compiler-composite-triple-key-id? key-id)
                  (and
                    (not key-is-pair)
                    (not (csym.compiler-symbol-root-module-id? owner-module-id))))
                  -1
                  (compiler-semantic-module-index-find
                    (& modules)
                    module-len
                    module-id))]
              (if (and
                (>= module-index 0)
                (compiler-semantic-map-kind-supported? namespace-tag kind)
                (>= decl-index 0)
                (< decl-index (array-length decl-record-indices))
                (> (array-ref decl-record-indices decl-index) 0))
                (if count-only
                  (compiler-semantic-top-candidate-count-increment!
                    counts-or-cursors
                    module-index)
                  (let
                    [out-index : i64
                      (compiler-semantic-top-candidate-fill-index
                        modules
                        module-index
                        counts-or-cursors
                        out
                        labels)]
                    [label : String
                      (tc.tc-env-key-name-text-for-session session name-id)]
                    (begin
                      (set!
                        (array-ref out out-index)
                        (CompilerSemanticTopCandidateRef
                          namespace-tag
                          name-id
                          out-index
                          (- (array-ref decl-record-indices decl-index) 1)))
                      (set!
                        (array-ref labels out-index)
                        (string.copy (& label)))
                      (set!
                        (array-ref counts-or-cursors module-index)
                        (+ out-index 1)))))
                unit))
            unit)
          (set! slot (+ slot 1)))))))

(define (compiler-semantic-module-shadows-core-macro?
  [symbols : (& symbols csym.CompilerSymbols)]
  [macros : (& macros csym.CompilerSymbolMap)]
  [module-id : i64]
  [name-id : i64]) : bool
  (let
    [handle : i64
      (csym.compiler-symbol-map-lookup-handle-id
        (& macros)
        (csym.compiler-symbol-module-key-id-by-id module-id name-id))]
    (if (< handle 0)
      false
      (if (csym.compiler-symbol-root-module-id? module-id)
        (csym.compiler-symbol-root-module-id?
          (csym.compiler-symbols-owner-module-id-at-index-or
            symbols
            (csym.compiler-symbol-handle-index handle)
            (csym.compiler-symbol-root-module-id)))
        true))))

(define (compiler-semantic-core-macro-walk!
  [session : cis.InternStructuralSessionHandle]
  [symbols : (& symbols csym.CompilerSymbols)]
  [macros : (& macros csym.CompilerSymbolMap)]
  [core-module-id : i64]
  [modules : (& modules (__tl_dyn-array CompilerSemanticModuleInfo))]
  [module-len : i64]
  [decl-record-indices : (& decl-record-indices (__tl_dyn-array i64))]
  [counts-or-cursors : (&mut counts-or-cursors (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array CompilerSemanticTopCandidateRef))]
  [labels : (&mut labels (__tl_dyn-array String))]
  [count-only : bool]) : unit
  (let
    [slot : i64 0]
    (while (< slot (array-length macros.keys))
      (let
        [stored-key : i64 (array-ref macros.keys slot)]
        (begin
          (if (> stored-key 0)
            (let
              [key-id : i64 (- stored-key 1)]
              [name-id : i64
                (compiler-semantic-map-key-name-for-module
                  key-id
                  core-module-id)]
              [handle : i64 (array-ref macros.values slot)]
              [decl-index : i64 (csym.compiler-symbol-handle-index handle)]
              (if (and
                (>= name-id 0)
                (=
                  (csym.compiler-symbol-handle-kind handle)
                  (csym.compiler-symbol-kind-defmacro))
                (>= decl-index 0)
                (< decl-index (array-length decl-record-indices))
                (> (array-ref decl-record-indices decl-index) 0))
                (let
                  [module-index : i64 0]
                  [label : String
                    (tc.tc-env-key-name-text-for-session session name-id)]
                  (while (< module-index module-len)
                    (let
                      [module-id : i64
                        (array-ref modules module-index).module-id]
                      (begin
                        (if (compiler-semantic-module-shadows-core-macro?
                          symbols
                          macros
                          module-id
                          name-id)
                          unit
                          (if count-only
                            (compiler-semantic-top-candidate-count-increment!
                              counts-or-cursors
                              module-index)
                            (let
                              [out-index : i64
                                (compiler-semantic-top-candidate-fill-index
                                  modules
                                  module-index
                                  counts-or-cursors
                                  out
                                  labels)]
                              (begin
                                (set!
                                  (array-ref out out-index)
                                  (CompilerSemanticTopCandidateRef
                                    (compiler-semantic-binding-namespace-macro-mask)
                                    name-id
                                    out-index
                                    (-
                                      (array-ref decl-record-indices decl-index)
                                      1)))
                                (set!
                                  (array-ref labels out-index)
                                  (string.copy (& label)))
                                (set!
                                  (array-ref counts-or-cursors module-index)
                                  (+ out-index 1))))))
                        (set! module-index (+ module-index 1))))))
                unit))
            unit)
          (set! slot (+ slot 1)))))))

;; Counting and filling deliberately share the two walkers and their visibility
;; predicates. Install exact per-module segments first, then allocate once; the
;; fill pass treats any map drift or predicate mismatch as an internal error.
(define (compiler-semantic-count-top-candidates!
  [ctx : tc.TcContext]
  [modules : (&mut modules (__tl_dyn-array CompilerSemanticModuleInfo))]
  [module-len : i64]
  [decl-record-indices : (& decl-record-indices (__tl_dyn-array i64))]) : i64
  (match (tc.tc-context-symbols ctx)
    [(csym.CompilerSymbols values types macros _ _ _)
      (let
        [symbols : (& ctx csym.CompilerSymbols) (tc.tc-context-symbols ctx)]
        [core-module-id : i64
          (if (compiler-semantic-map-has-module-macro?
            macros
            cbi.compiler-builtin-id-core-macros-module)
            cbi.compiler-builtin-id-core-macros-module
            cbi.compiler-builtin-id-core-macros-legacy-module)]
        [counts : (__tl_dyn-array i64) (__tl_make-array i64 module-len)]
        [unused-candidates : (__tl_dyn-array CompilerSemanticTopCandidateRef)
          (__tl_make-array CompilerSemanticTopCandidateRef 0)]
        [unused-labels : (__tl_dyn-array String) (__tl_make-array String 0)]
        [module-index : i64 0]
        [cursor : i64 0]
        (begin
          (compiler-semantic-top-map-walk!
            (tc.tc-context-structural-session ctx)
            symbols
            values
            1
            modules
            module-len
            decl-record-indices
            (&mut counts)
            (&mut unused-candidates)
            (&mut unused-labels)
            true)
          (compiler-semantic-top-map-walk!
            (tc.tc-context-structural-session ctx)
            symbols
            types
            2
            modules
            module-len
            decl-record-indices
            (&mut counts)
            (&mut unused-candidates)
            (&mut unused-labels)
            true)
          (compiler-semantic-top-map-walk!
            (tc.tc-context-structural-session ctx)
            symbols
            macros
            4
            modules
            module-len
            decl-record-indices
            (&mut counts)
            (&mut unused-candidates)
            (&mut unused-labels)
            true)
          (compiler-semantic-core-macro-walk!
            (tc.tc-context-structural-session ctx)
            symbols
            macros
            core-module-id
            modules
            module-len
            decl-record-indices
            (&mut counts)
            (&mut unused-candidates)
            (&mut unused-labels)
            true)
          (while (< module-index module-len)
            (let
              [info : CompilerSemanticModuleInfo
                (array-ref modules module-index)]
              (begin
                (if (>
                  (array-ref counts module-index)
                  (- 9223372036854775807 cursor))
                  (io.panic "semantic index: top candidate total overflow")
                  unit)
                (set! info.candidate-offset cursor)
                (set! info.candidate-len (array-ref counts module-index))
                (set! (array-ref modules module-index) info)
                (set! cursor (+ cursor info.candidate-len))
                (set! module-index (+ module-index 1)))))
          cursor))]))

(define (compiler-semantic-fill-top-candidates!
  [ctx : tc.TcContext]
  [modules : (& modules (__tl_dyn-array CompilerSemanticModuleInfo))]
  [module-len : i64]
  [decl-record-indices : (__tl_dyn-array i64)]
  [records : (__tl_dyn-array CompilerSemanticRecord)]
  [out : (&mut out (__tl_dyn-array CompilerSemanticTopCandidateRef))]
  [labels : (__tl_dyn-array String)]) : unit
  (match (tc.tc-context-symbols ctx)
    [(csym.CompilerSymbols values types macros _ _ _)
      (let
        [symbols : (& ctx csym.CompilerSymbols) (tc.tc-context-symbols ctx)]
        [core-module-id : i64
          (if (compiler-semantic-map-has-module-macro?
            macros
            cbi.compiler-builtin-id-core-macros-module)
            cbi.compiler-builtin-id-core-macros-module
            cbi.compiler-builtin-id-core-macros-legacy-module)]
        [cursors : (__tl_dyn-array i64) (__tl_make-array i64 module-len)]
        [module-index : i64 0]
        [expected-offset : i64 0]
        (begin
          (if (!= (array-length out) (array-length labels))
            (io.panic "semantic index: top candidate storage length mismatch")
            unit)
          (while (< module-index module-len)
            (let
              [info : CompilerSemanticModuleInfo
                (array-ref modules module-index)]
              (begin
                (if (or
                  (< info.candidate-len 0)
                  (!= info.candidate-offset expected-offset)
                  (> info.candidate-len (- 9223372036854775807 expected-offset)))
                  (io.panic "semantic index: invalid top candidate segment")
                  unit)
                (set! (array-ref cursors module-index) info.candidate-offset)
                (set! expected-offset (+ expected-offset info.candidate-len))
                (set! module-index (+ module-index 1)))))
          (if (!= expected-offset (array-length out))
            (io.panic
              "semantic index: top candidate storage is not exact-sized")
            unit)
          (compiler-semantic-top-map-walk!
            (tc.tc-context-structural-session ctx)
            symbols
            values
            1
            modules
            module-len
            decl-record-indices
            (&mut cursors)
            out
            (&mut labels)
            false)
          (compiler-semantic-top-map-walk!
            (tc.tc-context-structural-session ctx)
            symbols
            types
            2
            modules
            module-len
            decl-record-indices
            (&mut cursors)
            out
            (&mut labels)
            false)
          (compiler-semantic-top-map-walk!
            (tc.tc-context-structural-session ctx)
            symbols
            macros
            4
            modules
            module-len
            decl-record-indices
            (&mut cursors)
            out
            (&mut labels)
            false)
          (compiler-semantic-core-macro-walk!
            (tc.tc-context-structural-session ctx)
            symbols
            macros
            core-module-id
            modules
            module-len
            decl-record-indices
            (&mut cursors)
            out
            (&mut labels)
            false)
          (set! module-index 0)
          (while (< module-index module-len)
            (let
              [info : CompilerSemanticModuleInfo
                (array-ref modules module-index)]
              (begin
                (if (!=
                  (array-ref cursors module-index)
                  (+ info.candidate-offset info.candidate-len))
                  (io.panic "semantic index: top candidate count/fill mismatch")
                  unit)
                (compiler-semantic-top-candidates-sort-segment!
                  out
                  (owned_view.compiler-owned-shared-view labels)
                  (owned_view.compiler-owned-shared-view records)
                  info.candidate-offset
                  info.candidate-len)
                (set! module-index (+ module-index 1)))))
          unit))]))

(define (compiler-semantic-index-build-owned
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]
  [paths : ast.AstDeclPathList]
  [entry-path : String]
  [entry-source : String]
  [complete : bool]) : CompilerSemanticSourceIndex
  (let
    [owner : i64 (arena.tl_arena_make)]
    (begin
      (set!
        compiler-semantic-source-index-live-owners
        (+ compiler-semantic-source-index-live-owners 1))
      (in-arena
        (arena.Arena owner)
        (let
          [decls : ast.AstDeclList
            (match (tc.tc-context-program ctx)
              [(ast.AstProgram.Program decls-box) (deref decls-box)])]
          [decl-count : i64 (ast.ast-decl-list-len (& decls))]
          [symbol-count : i64
            (csym.compiler-symbols-decl-count (tc.tc-context-symbols (& ctx)))]
          [path-capacity : i64 (+ decl-count 4)]
          [module-capacity : i64 (+ decl-count 4)]
          [paths-out : (__tl_dyn-array CompilerSemanticSourcePathInfo)
            (__tl_make-array CompilerSemanticSourcePathInfo path-capacity)]
          [modules-out : (__tl_dyn-array CompilerSemanticModuleInfo)
            (__tl_make-array CompilerSemanticModuleInfo module-capacity)]
          [module-events-out : (__tl_dyn-array CompilerSemanticModuleEvent)
            (__tl_make-array CompilerSemanticModuleEvent (+ (* decl-count 2) 8))]
          [decl-record-indices : (__tl_dyn-array i64)
            (__tl_make-array i64 symbol-count)]
          [walk-state : CompilerSemanticWalkState
            (CompilerSemanticWalkState
              ctx
              env
              ""
              ""
              -1
              cbi.compiler-builtin-id-fix-empty
              -1
              -1
              true
              false
              CompilerSemanticProvenance.EditableSource
              (box
                (compiler-semantic-record-vec-new
                  (* (ast.ast-decl-list-len (& decls)) 2)))
              (box
                (compiler-semantic-binding-vec-new
                  (* (ast.ast-decl-list-len (& decls)) 2)))
              ;; Recovery walks already omit locals whose checked facts are
              ;; unavailable. Retain the remaining proven visibility graph so
              ;; immutable tooling can serve the current partial snapshot.
              true
              -1
              -1
              (box
                (CompilerSemanticVisibilityBuildStorage
                  (owned_view.compiler-owned-shared-view paths-out)
                  (box 0)
                  (owned_view.compiler-owned-shared-view modules-out)
                  (box 0)
                  (owned_view.compiler-owned-shared-view module-events-out)
                  (box 0)
                  (box
                    (compiler-semantic-scope-event-vec-new
                      (+ (* decl-count 2) 8)))
                  (box 0)
                  (box 0)
                  (box 1)
                  (box 1)))
              (__tl_make-array
                i64
                (ast.ast-node-pool-context-expr-len (tc.tc-context-pools ctx)))
              (box 0)
              (box false)
              parse_core.CompilerParseMaybeSemanticOriginRun.None
              (__tl_make-array i64 12))]
          [index : i64 0]
          [cached-path : String ""]
          [cached-source : String ""]
          [form-search-start : i64 0]
          (begin
            (while (< index (ast.ast-decl-list-len (& decls)))
              (let
                [decl : ast.AstDecl
                  (ast.ast-decl-list-get
                    (& decls)
                    index
                    (ast.ast-decl-fallback))]
                [path : String
                  (ast.ast-decl-path-list-get
                    (& paths)
                    index
                    (owned_view.compiler-owned-shared-view entry-path))]
                [module-id : i64
                  (ast.ast-decl-path-list-owner-id
                    (& paths)
                    index
                    cbi.compiler-builtin-id-fix-empty)]
                [decl-ctx : tc.TcContext
                  (if (= module-id cbi.compiler-builtin-id-fix-empty)
                    (tc.tc-context-with-module-id
                      ctx
                      ""
                      cbi.compiler-builtin-id-fix-empty)
                    (tc.tc-context-with-module-id
                      ctx
                      (tc.macro-decl-module-display module-id)
                      module-id))]
                [generated : bool
                  (match (ast.ast-decl-generated-meta decl)
                    [(ast.AstGeneratedDeclMeta.No) false]
                    [(ast.AstGeneratedDeclMeta.Some _ _ _ _) true])]
                [provenance : CompilerSemanticProvenance
                  (compiler-semantic-decl-provenance
                    (owned_view.compiler-owned-shared-view decl))]
                [path-changed : bool (not (string.eq path cached-path))]
                [module-changed : bool
                  (or path-changed (!= module-id walk-state.module-id))]
                (begin
                  (if path-changed
                    (begin
                      (set! cached-path (string.copy (& path)))
                      (set! form-search-start 0)
                      (set!
                        cached-source
                        (cond
                          [(string.eq path entry-path)
                            (string.copy (& entry-source))]
                          [(and
                              (not (string.eq path ""))
                              (io.file-exists?
                                (owned_view.compiler-owned-shared-view path)))
                            (byte_buf.to-string
                              (io.read-file
                                (owned_view.compiler-owned-shared-view path)))]
                          [else ""]))
                      (set! walk-state.path (string.copy (& path)))
                      (set! walk-state.source (string.copy (& cached-source))))
                    unit)
                  (set! walk-state.ctx decl-ctx)
                  (set! walk-state.top-env env)
                  (set! walk-state.form-start -1)
                  (set! walk-state.module-id module-id)
                  (if module-changed
                    (set!
                      walk-state.module-index
                      (compiler-semantic-module-index-ensure!
                        walk-state
                        module-id))
                    unit)
                  (if path-changed
                    (set!
                      walk-state.path-index
                      (compiler-semantic-path-index-ensure!
                        walk-state
                        path
                        (string.string-length cached-source)
                        walk-state.module-index))
                    unit)
                  (set! walk-state.declaration-ordinal index)
                  (set!
                    walk-state.checked-declaration-ordinal
                    (+ decls.offset index))
                  (set!
                    walk-state.declaration-retains-let-facts
                    (compiler-semantic-decl-retains-checked-let-facts?
                      (owned_view.compiler-owned-shared-view path)
                      (owned_view.compiler-owned-shared-view decl)))
                  (set! walk-state.generated generated)
                  (set! walk-state.provenance provenance)
                  (set! (deref walk-state.next-local-ordinal) 0)
                  (set!
                    walk-state.semantic-origin-run
                    (parse_core.compiler-parse-semantic-origin-run
                      (& decls)
                      index))
                  (compiler-semantic-origin-cursors-reset! walk-state)
                  (compiler-semantic-source-anchor-set! walk-state 0 1 1)
                  ;; Imports and module markers have no semantic definition row,
                  ;; but their checked path owner still changes the module that
                  ;; a cursor at that form observes.
                  (match (compiler-semantic-decl-symbol
                    (owned_view.compiler-owned-shared-view decl))
                    [(CompilerSemanticMaybeDecl.Some _ _) unit]
                    [(CompilerSemanticMaybeDecl.None)
                      (match (compiler-semantic-decl-origin
                        (& decls)
                        index
                        (owned_view.compiler-owned-shared-view decl))
                        [(parse_core.CompilerParseMaybeDeclSpan.Some origin)
                          (let
                            [form-start : i64
                              (if (or generated (string.eq cached-source ""))
                                -1
                                (compiler-semantic-top-level-form-start
                                  cached-source
                                  (compiler-semantic-source-offset
                                    cached-source
                                    (ast.ast-source-span-start-line origin)
                                    (ast.ast-source-span-start-col origin))
                                  form-search-start))]
                            (begin
                              (compiler-semantic-module-event-push!
                                walk-state
                                walk-state.path-index
                                form-start
                                walk-state.module-index)
                              (if (>= form-start 0)
                                (set! form-search-start form-start)
                                unit)))]
                        [(parse_core.CompilerParseMaybeDeclSpan.None) unit])])
                  (match (compiler-semantic-decl-symbol
                    (owned_view.compiler-owned-shared-view decl))
                    [(CompilerSemanticMaybeDecl.Some name-id kind)
                      (let
                        [name : String
                          (tc.tc-env-key-name-text-for-session
                            (tc.tc-context-structural-session walk-state.ctx)
                            name-id)]
                        [maybe-origin : parse_core.CompilerParseMaybeDeclSpan
                          (compiler-semantic-decl-origin
                            (& decls)
                            index
                            (owned_view.compiler-owned-shared-view decl))]
                        [semantic-origin : CompilerSemanticMaybeOrigin
                          (match kind
                            [(CompilerSemanticSymbolKind.Struct)
                              (compiler-semantic-origin-take!
                                walk-state
                                parse_core.CompilerParseSemanticOriginKind.TypeDefinition)]
                            [(CompilerSemanticSymbolKind.Enum)
                              (compiler-semantic-origin-take!
                                walk-state
                                parse_core.CompilerParseSemanticOriginKind.TypeDefinition)]
                            [_ CompilerSemanticMaybeOrigin.None])]
                        [form-start : i64
                          (match maybe-origin
                            [(parse_core.CompilerParseMaybeDeclSpan.Some origin)
                              (if (or generated (string.eq cached-source ""))
                                -1
                                (compiler-semantic-top-level-form-start
                                  cached-source
                                  (compiler-semantic-source-offset
                                    cached-source
                                    (ast.ast-source-span-start-line origin)
                                    (ast.ast-source-span-start-col origin))
                                  form-search-start))]
                            [(parse_core.CompilerParseMaybeDeclSpan.None)
                              (if (and
                                (not generated)
                                (not (string.eq cached-source "")))
                                0
                                -1)])]
                        [has-origin : bool
                          (match semantic-origin
                            [(CompilerSemanticMaybeOrigin.Some _) true]
                            [(CompilerSemanticMaybeOrigin.None)
                              (match maybe-origin
                                [(parse_core.CompilerParseMaybeDeclSpan.Some _)
                                  true]
                                [(parse_core.CompilerParseMaybeDeclSpan.None)
                                  (and
                                    (not generated)
                                    (not (string.eq cached-source "")))])])]
                        [span : CompilerSemanticSpan
                          (match semantic-origin
                            [(CompilerSemanticMaybeOrigin.Some origin)
                              (compiler-semantic-exact-span-from-origin
                                walk-state
                                origin)]
                            [(CompilerSemanticMaybeOrigin.None)
                              (match maybe-origin
                                [(parse_core.CompilerParseMaybeDeclSpan.Some
                                    origin)
                                  (if (string.eq cached-source "")
                                    (CompilerSemanticSpan
                                      (string.copy (& path))
                                      -1
                                      -1
                                      origin
                                      -1
                                      -1)
                                    (compiler-semantic-definition-span
                                      path
                                      (owned_view.compiler-owned-shared-view
                                        cached-source)
                                      name
                                      origin
                                      form-start))]
                                [(parse_core.CompilerParseMaybeDeclSpan.None)
                                  (if (and
                                    (not generated)
                                    (not (string.eq cached-source "")))
                                    (let
                                      [end-position : ast.AstSourceSpan
                                        (compiler-semantic-source-position
                                          cached-source
                                          (string.string-length cached-source))]
                                      (compiler-semantic-definition-span
                                        path
                                        (owned_view.compiler-owned-shared-view
                                          cached-source)
                                        name
                                        (ast.ast-source-span
                                          1
                                          1
                                          (ast.ast-source-span-start-line
                                            end-position)
                                          (ast.ast-source-span-start-col
                                            end-position))
                                        form-start))
                                    (CompilerSemanticSpan
                                      (string.copy (& path))
                                      -1
                                      -1
                                      (ast.ast-source-span 1 1 1 1)
                                      -1
                                      -1))])])]
                        [symbol : CompilerSemanticSymbolId
                          (compiler-semantic-symbol-for-decl
                            decl-ctx
                            module-id
                            index
                            name-id
                            kind)]
                        [type-text : String
                          (compiler-semantic-decl-type
                            decl-ctx
                            env
                            (owned_view.compiler-owned-shared-view decl)
                            kind
                            name-id
                            (owned_view.compiler-owned-shared-view name))]
                        [documentation : String
                          (if (and
                            (not generated)
                            (not (string.eq cached-source ""))
                            (>= span.start-byte 0))
                            (compiler-semantic-documentation-above
                              cached-source
                              form-start)
                            "")]
                        (begin
                          (match semantic-origin
                            [(CompilerSemanticMaybeOrigin.Some origin)
                              (compiler-semantic-record-module-origins-before!
                                (owned_view.compiler-owned-shared-view
                                  walk-state)
                                origin.ordinal
                                symbol.module-id)]
                            [(CompilerSemanticMaybeOrigin.None) unit])
                          (if (>= span.start-byte 0)
                            (compiler-semantic-source-anchor-set!
                              walk-state
                              span.start-byte
                              (ast.ast-source-span-start-line span.source)
                              (ast.ast-source-span-start-col span.source))
                            unit)
                          (set! walk-state.form-start form-start)
                          (compiler-semantic-module-event-push!
                            walk-state
                            walk-state.path-index
                            form-start
                            walk-state.module-index)
                          (if (>= form-start 0)
                            (set! form-search-start form-start)
                            unit)
                          ;; Local identities are anchored to the resolved
                          ;; declaration handle, not the flattened AST position.
                          (set! walk-state.module-id symbol.module-id)
                          (set!
                            walk-state.declaration-ordinal
                            symbol.declaration-ordinal)
                          (let
                            [record-index : i64
                              (compiler-semantic-record-vec-push-index!
                                (&mut (__tl-box-place walk-state.records))
                                (CompilerSemanticRecord
                                  symbol
                                  -1
                                  CompilerSemanticRecordRole.Definition
                                  CompilerSemanticAccess.None
                                  kind
                                  (string.copy (& name))
                                  (string.copy (& type-text))
                                  (string.copy (& documentation))
                                  symbol.module-id
                                  (owned_view.compiler-owned-shared-view span)
                                  (and
                                    (not generated)
                                    has-origin
                                    (>= span.start-byte 0))
                                  provenance))]
                            (if (and
                              (>= symbol.declaration-ordinal 0)
                              (< symbol.declaration-ordinal symbol-count))
                              (set!
                                (array-ref
                                  decl-record-indices
                                  symbol.declaration-ordinal)
                                (+ record-index 1))
                              unit))))]
                    [(CompilerSemanticMaybeDecl.None) unit])
                  (compiler-semantic-walk-decl!
                    (owned_view.compiler-owned-shared-view walk-state)
                    decl)
                  (set! index (+ index 1)))))
            (compiler-semantic-record-macro-call-sites!
              (owned_view.compiler-owned-shared-view walk-state)
              entry-path
              entry-source)
            (let
              [visibility-storage : CompilerSemanticVisibilityBuildStorage
                (owned_view.compiler-owned-box-shared-view
                  walk-state.visibility-storage)]
              [path-count : i64 (__tl-box-place visibility-storage.path-len)]
              [module-count : i64
                (__tl-box-place visibility-storage.module-len)]
              [top-candidate-count : i64
                (if complete
                  (compiler-semantic-count-top-candidates!
                    ctx
                    (&mut modules-out)
                    module-count
                    decl-record-indices)
                  0)]
              [top-candidates : (__tl_dyn-array CompilerSemanticTopCandidateRef)
                (__tl_make-array
                  CompilerSemanticTopCandidateRef
                  top-candidate-count)]
              [top-labels : (__tl_dyn-array String)
                (__tl_make-array String top-candidate-count)]
              [raw-scope-events : CompilerSemanticScopeEventVec
                (owned_view.compiler-owned-box-shared-view
                  visibility-storage.scope-events)]
              [scope-event-count : i64 raw-scope-events.len]
              [module-event-count : i64
                (__tl-box-place visibility-storage.module-event-len)]
              [scope-events : (__tl_dyn-array CompilerSemanticScopeEvent)
                (__tl_make-array CompilerSemanticScopeEvent scope-event-count)]
              [module-events : (__tl_dyn-array CompilerSemanticModuleEvent)
                (__tl_make-array CompilerSemanticModuleEvent module-event-count)]
              [records : CompilerSemanticRecordVec
                (owned_view.compiler-owned-box-shared-view walk-state.records)]
              [record-items : (__tl_dyn-array CompilerSemanticRecord)
                records.items]
              [record-count : i64 records.len]
              [canonical-build : CompilerSemanticCanonicalBuildResult
                (compiler-semantic-canonical-build
                  (owned_view.compiler-owned-shared-view record-items)
                  record-count)]
              [bindings : CompilerSemanticBindingVec
                (owned_view.compiler-owned-box-shared-view walk-state.bindings)]
              [binding-items : (__tl_dyn-array CompilerSemanticBinding)
                bindings.items]
              [binding-count : i64 bindings.len]
              (begin
                (compiler-semantic-bucket-scope-events!
                  (owned_view.compiler-owned-shared-view paths-out)
                  path-count
                  raw-scope-events.items
                  scope-event-count
                  (&mut scope-events))
                (compiler-semantic-bucket-module-events!
                  (owned_view.compiler-owned-shared-view paths-out)
                  path-count
                  module-events-out
                  module-event-count
                  (&mut module-events))
                (if complete
                  (compiler-semantic-fill-top-candidates!
                    ctx
                    modules-out
                    module-count
                    decl-record-indices
                    (owned_view.compiler-owned-shared-view record-items)
                    (&mut top-candidates)
                    (owned_view.compiler-owned-shared-view top-labels))
                  unit)
                (let
                  [top-visible-bindings : (__tl_dyn-array
                    CompilerSemanticVisibleBinding)
                    (__tl_make-array
                      CompilerSemanticVisibleBinding
                      top-candidate-count)]
                  (begin
                    (if complete
                      (compiler-semantic-top-visible-bindings-fill!
                        (& record-items)
                        (& top-candidates)
                        (& top-labels)
                        top-candidate-count
                        (&mut top-visible-bindings))
                      unit)
                    (let
                      [result : CompilerSemanticSourceIndex
                        (CompilerSemanticSourceIndex
                          owner
                          record-items
                          record-count
                          canonical-build.symbols
                          canonical-build.len
                          (and
                            complete
                            (not (deref walk-state.checked-let-fact-mismatch)))
                          paths-out
                          path-count
                          modules-out
                          module-count
                          module-events
                          module-event-count
                          scope-events
                          scope-event-count
                          (__tl-box-place visibility-storage.scope-region-count)
                          binding-items
                          binding-count
                          top-candidates
                          top-labels
                          top-visible-bindings
                          top-candidate-count)]
                      result)))))))))))

(define (compiler-check-program-with-paths-index-cache
  [path : String]
  [source : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]) : ResultCompilerCheckWithSemanticIndex
  (let
    [job-state : tc.TcJobState (tc.tc-serial-job-state)]
    [macro-sites : tc.TcMacroCallSiteState
      (tc.tc-job-state-macro-call-sites job-state)]
    [let-facts : tc.TcCheckedLetBindingFactState
      (tc.tc-job-state-checked-let-binding-facts job-state)]
    (begin
      (tc.tc-checked-let-binding-facts-begin! let-facts)
      (tc.tc-macro-call-site-state-set-enabled! macro-sites true)
      (cfg compile-profile (check_core.compiler-check-profile-start))
      (match (tc_api.typecheck-compiler-program-with-paths-checked-cache
        (ast.ast-program decls)
        paths
        stdlib-roots
        cfgs
        cache-scope)
        [(tc.ResultCompilerTypecheckChecked.Ok summary ctx env checked-paths)
          (let
            [_let-check-count-before : i64
              (cfg test (tc.tc-let-binding-init-type-call-count-for-test) 0)]
            [index : CompilerSemanticSourceIndex
              (compiler-semantic-index-build-owned
                ctx
                env
                checked-paths
                path
                source
                true)]
            (begin
              (cfg
                test
                (unless
                  (=
                    _let-check-count-before
                    (tc.tc-let-binding-init-type-call-count-for-test))
                  (io.panic
                    "semantic index: let initializer was typechecked during index construction"))
                unit)
              (cfg
                compile-profile
                (check_core.compiler-check-profile-finish "typecheck"))
              (tc.tc-macro-call-site-state-set-enabled! macro-sites false)
              (tc.tc-checked-let-binding-facts-finish! let-facts)
              (if (compiler-semantic-source-index-complete? (& index))
                (ResultCompilerCheckWithSemanticIndex.Ok summary index)
                (begin
                  (compiler-semantic-source-index-release! (&mut index))
                  (ResultCompilerCheckWithSemanticIndex.Err
                    (box
                      (cdiag.compiler-diagnostic-list-single
                        (tc.tc-diag-at-start
                          "semantic index: missing or inconsistent retained checked let-binding fact"))))))))]
        [(tc.ResultCompilerTypecheckChecked.Partial diag ctx env checked-paths)
          (let
            [_let-check-count-before : i64
              (cfg test (tc.tc-let-binding-init-type-call-count-for-test) 0)]
            [index : CompilerSemanticSourceIndex
              (compiler-semantic-index-build-owned
                ctx
                env
                checked-paths
                (owned_view.compiler-owned-shared-view path)
                source
                false)]
            (begin
              (cfg
                test
                (unless
                  (=
                    _let-check-count-before
                    (tc.tc-let-binding-init-type-call-count-for-test))
                  (io.panic
                    "semantic index: let initializer was typechecked during partial index construction"))
                unit)
              (cfg
                compile-profile
                (check_core.compiler-check-profile-finish "typecheck"))
              (tc.tc-macro-call-site-state-set-enabled! macro-sites false)
              (tc.tc-checked-let-binding-facts-finish! let-facts)
              (ResultCompilerCheckWithSemanticIndex.Partial
                (box
                  (check_core.compiler-check-diagnostics-with-fallback-path
                    (deref diag)
                    path))
                index)))]
        [(tc.ResultCompilerTypecheckChecked.Err diag)
          (begin
            (cfg
              compile-profile
              (check_core.compiler-check-profile-finish "typecheck"))
            (tc.tc-macro-call-site-state-set-enabled! macro-sites false)
            (tc.tc-checked-let-binding-facts-finish! let-facts)
            (ResultCompilerCheckWithSemanticIndex.Err
              (box
                (check_core.compiler-check-diagnostics-with-fallback-path
                  (deref diag)
                  path))))]))))

(define (compiler-check-loaded-with-prelude-index-cache
  [path : String]
  [source : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [loaded : cload.ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]) : ResultCompilerCheckWithSemanticIndex
  (match loaded
    [(cload.ResultCompilerLoadWithPaths.Ok
        entry-decls
        entry-paths
        entry-modules
        _)
      (begin
        (cfg compile-profile (check_core.compiler-check-profile-finish "load"))
        (compiler-check-program-with-paths-index-cache
          path
          source
          (cload.compiler-load-decl-list-append prelude-decls entry-decls)
          (cload.compiler-load-decl-path-list-append
            prelude-paths
            (ast.ast-decl-path-list-with-modules entry-paths entry-modules))
          stdlib-roots
          cfgs
          cache-scope))]
    [(cload.ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (check_core.compiler-check-profile-finish "load"))
        (ResultCompilerCheckWithSemanticIndex.Partial
          (cdiag.compiler-diagnostic-list-box-single diag)
          (compiler-semantic-source-index-empty-owned)))]))

(define (compiler-semantic-index-result-with-parse-diagnostics
  [parse-diagnostics : cdiag.CompilerDiagnosticList]
  [result : ResultCompilerCheckWithSemanticIndex]) : ResultCompilerCheckWithSemanticIndex
  (if (= (cdiag.compiler-diagnostic-list-count parse-diagnostics) 0)
    result
    (let
      [count : i64 (cdiag.compiler-diagnostic-list-count parse-diagnostics)]
      [index : i64 0]
      [owned-parse : cdiag.CompilerDiagnosticList
        (cdiag.compiler-diagnostic-list-with-capacity count)]
      (begin
        (while (< index count)
          (begin
            (cdiag.compiler-diagnostic-list-push!
              (&mut owned-parse)
              (cdiag.compiler-diagnostic-list-get parse-diagnostics index))
            (set! index (+ index 1))))
        (match result
          [(ResultCompilerCheckWithSemanticIndex.Ok _ source-index)
            (ResultCompilerCheckWithSemanticIndex.Partial
              (box owned-parse)
              (CompilerSemanticSourceIndex
                source-index.owner-arena
                source-index.records
                source-index.len
                source-index.canonical-symbols
                source-index.canonical-symbol-len
                false
                source-index.paths
                source-index.path-len
                source-index.modules
                source-index.module-len
                source-index.module-events
                source-index.module-event-len
                source-index.scope-events
                source-index.scope-event-len
                source-index.scope-region-count
                source-index.bindings
                source-index.binding-len
                source-index.top-candidates
                source-index.top-labels
                source-index.top-visible-bindings
                source-index.top-candidate-len))]
          [(ResultCompilerCheckWithSemanticIndex.Partial
              semantic-diagnostics
              source-index)
            (begin
              (check_core.compiler-check-diagnostic-list-insert-all-source-order
                (deref semantic-diagnostics)
                (&mut owned-parse))
              (ResultCompilerCheckWithSemanticIndex.Partial
                (box owned-parse)
                source-index))]
          [(ResultCompilerCheckWithSemanticIndex.Err semantic-diagnostics)
            (begin
              (check_core.compiler-check-diagnostic-list-insert-all-source-order
                (deref semantic-diagnostics)
                (&mut owned-parse))
              (ResultCompilerCheckWithSemanticIndex.Err (box owned-parse)))])))))

(define (compiler-check-source-with-prelude-index-recovery
  [path : String]
  [source : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [prelude-seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]) : ResultCompilerCheckWithSemanticIndex
  (match (parse_core.parse-ast-source-recovery-diagnostic-with-cfg
    (owned_view.compiler-owned-shared-view path)
    (owned_view.compiler-owned-shared-view source)
    cfgs)
    [(parse_core.ResultAstProgramRecovery.Fatal diagnostics)
      (begin
        (cfg compile-profile (check_core.compiler-check-profile-finish "load"))
        (ResultCompilerCheckWithSemanticIndex.Err diagnostics))]
    [(parse_core.ResultAstProgramRecovery.Parsed program diagnostics)
      (let
        [parse-identity : cload.CompilerLoadParseIdentity
          (cload.compiler-load-parse-identity
            (owned_view.compiler-owned-shared-view path)
            (cload.compiler-load-canonical-module-id-from-path path)
            ast.AstMaybeModuleName.No)]
        [loaded : cload.ResultCompilerLoadWithPaths
          (cload.compiler-load-program-with-paths-and-roots-expect-cfg
            path
            program
            prelude-seen
            (owned_view.compiler-owned-shared-view stdlib-roots)
            ast.AstMaybeModuleName.No
            cfgs
            parse-identity)]
        (compiler-semantic-index-result-with-parse-diagnostics
          (deref diagnostics)
          (compiler-check-loaded-with-prelude-index-cache
            path
            source
            prelude-decls
            prelude-paths
            loaded
            stdlib-roots
            cfgs
            cache-scope)))]))

(define (compiler-check-source-index-with-roots-and-cfg
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheckWithSemanticIndex
  (begin
    (check_core.compiler-check-reset-pools!)
    (cfg compile-profile (check_core.compiler-check-profile-start))
    (match (cload.compiler-load-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      cfgs)
      [(cload.ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (compiler-check-source-with-prelude-index-recovery
          path
          source
          prelude-decls
          (ast.ast-decl-path-list-with-modules prelude-paths prelude-modules)
          prelude-seen
          (owned_view.compiler-owned-shared-view stdlib-roots)
          cfgs
          (tc_api.compiler-typecheck-prefix-cache-scope
            "typecheck-prefix-semantic-index"
            stdlib-roots
            cfgs))]
      [(cload.ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg
            compile-profile
            (check_core.compiler-check-profile-finish "load"))
          (ResultCompilerCheckWithSemanticIndex.Err
            (cdiag.compiler-diagnostic-list-box-single diag)))])))

(define (compiler-semantic-source-index-find-editable-record-at
  [index : (& index CompilerSemanticSourceIndex)]
  [wanted-path : (& wanted-path str)]
  [byte-position : i64]) : i64
  (let
    [record-index : i64 0]
    [found : i64 -1]
    [found-priority : i64 -1]
    [found-width : i64 999999999]
    (begin
      (while (< record-index index.len)
        (let
          [record : CompilerSemanticRecord
            (owned_view.compiler-owned-array-element-shared-view
              index.records
              record-index)]
          [span : CompilerSemanticSpan record.span]
          [start : i64 span.start-byte]
          [end : i64 span.end-byte]
          [width : i64 (- end start)]
          ;; A qualified value/function retains its legacy whole-token record
          ;; alongside narrower module-component facts. Point queries keep the
          ;; value fact authoritative over the overlapping qualifier; module
          ;; components remain directly queryable where no value fact covers
          ;; them and remain enumerable for component-aware consumers.
          [priority : i64
            (match record.kind
              [(CompilerSemanticSymbolKind.Module) 0]
              [_ 1])]
          (begin
            (if (and
              record.editable
              (match record.provenance
                [(CompilerSemanticProvenance.EditableSource) true]
                [_ false])
              (>= byte-position start)
              (< byte-position end)
              (string.eq (& span.path) wanted-path)
              (or
                (> priority found-priority)
                (and (= priority found-priority) (< width found-width))))
              (begin
                (set! found record-index)
                (set! found-priority priority)
                (set! found-width width))
              unit)
            (set! record-index (+ record-index 1)))))
      found)))

;; Namespace mask used by semantic rename preflight. Struct names occupy both
;; the value (constructor) and type namespaces; every other ordinary binding
;; has one lookup namespace. Members and modules use owner-specific checks
;; below in addition to any bindings visible at the occurrence.
(define (compiler-semantic-rename-namespace-mask
  [kind : (& kind CompilerSemanticSymbolKind)]) : i64
  (match (deref kind)
    [(CompilerSemanticSymbolKind.Macro)
      (compiler-semantic-binding-namespace-macro-mask)]
    [(CompilerSemanticSymbolKind.Struct)
      (bit-or
        (compiler-semantic-binding-namespace-value-mask)
        (compiler-semantic-binding-namespace-type-mask))]
    [(CompilerSemanticSymbolKind.Enum)
      (compiler-semantic-binding-namespace-type-mask)]
    [(CompilerSemanticSymbolKind.Module) 0]
    [(CompilerSemanticSymbolKind.Field) 0]
    [(CompilerSemanticSymbolKind.EnumMember) 0]
    [_ (compiler-semantic-binding-namespace-value-mask)]))

(define (compiler-semantic-rename-symbol-eq?
  [left : (& left CompilerSemanticSymbolId)]
  [right : (& right CompilerSemanticSymbolId)]) : bool
  (and
    (= left.module-id right.module-id)
    (= left.declaration-ordinal right.declaration-ordinal)
    (= left.local-ordinal right.local-ordinal)))

(define (compiler-semantic-rename-visible-collision-at?
  [index : (& index CompilerSemanticSourceIndex)]
  [target : (& target CompilerSemanticRecord)]
  [byte-offset : i64]
  [new-name : (& new-name str)]) : bool
  (let
    [mask : i64 (compiler-semantic-rename-namespace-mask (& target.kind))]
    (if (= mask 0)
      false
      (match (compiler-semantic-source-index-query
        index
        (string.copy (& target.span.path))
        byte-offset)
        [(CompilerSemanticMaybeVisibleBindingQuery.None) false]
        [(CompilerSemanticMaybeVisibleBindingQuery.Some query)
          (let
            [cursor : CompilerSemanticVisibleBindingCursor
              (compiler-semantic-visible-binding-cursor index query mask)]
            [done : bool false]
            (begin
              (while (not done)
                (match (compiler-semantic-visible-binding-cursor-step
                  index
                  cursor)
                  [(CompilerSemanticVisibleBindingStep.Some binding next)
                    (if (and
                      (string.eq binding.display-name new-name)
                      (not
                        (compiler-semantic-rename-symbol-eq?
                          (& binding.symbol)
                          (& target.symbol))))
                      (return true)
                      (set! cursor next))]
                  [(CompilerSemanticVisibleBindingStep.Done) (set! done true)]))
              false))]))))

(define (compiler-semantic-rename-member-owner-eq?
  [left : (& left CompilerSemanticRecord)]
  [right : (& right CompilerSemanticRecord)]) : bool
  (and
    (= left.symbol.module-id right.symbol.module-id)
    (=
      (csym.compiler-registry-handle-owner-index
        left.symbol.declaration-ordinal)
      (csym.compiler-registry-handle-owner-index
        right.symbol.declaration-ordinal))))

;; Public, identity-only member lookup for immutable tooling consumers.  A
;; field or enum-member handle encodes its owning struct/enum declaration;
;; callers never need access to the compiler registry that produced it.
(define (compiler-semantic-member-symbol-owned-by?
  [owner : (& owner CompilerSemanticSymbolId)]
  [member : (& member CompilerSemanticSymbolId)]) : bool
  (and
    (= owner.module-id member.module-id)
    (=
      owner.declaration-ordinal
      (csym.compiler-registry-handle-owner-index member.declaration-ordinal))))

(define (compiler-semantic-rename-kind-eq?
  [left : (& left CompilerSemanticSymbolKind)]
  [right : (& right CompilerSemanticSymbolKind)]) : bool
  (match (deref left)
    [(CompilerSemanticSymbolKind.Value)
      (match (deref right)
        [(CompilerSemanticSymbolKind.Value) true]
        [_ false])]
    [(CompilerSemanticSymbolKind.Function)
      (match (deref right)
        [(CompilerSemanticSymbolKind.Function) true]
        [_ false])]
    [(CompilerSemanticSymbolKind.Macro)
      (match (deref right)
        [(CompilerSemanticSymbolKind.Macro) true]
        [_ false])]
    [(CompilerSemanticSymbolKind.ExternValue)
      (match (deref right)
        [(CompilerSemanticSymbolKind.ExternValue) true]
        [_ false])]
    [(CompilerSemanticSymbolKind.ExternFunction)
      (match (deref right)
        [(CompilerSemanticSymbolKind.ExternFunction) true]
        [_ false])]
    [(CompilerSemanticSymbolKind.Struct)
      (match (deref right)
        [(CompilerSemanticSymbolKind.Struct) true]
        [_ false])]
    [(CompilerSemanticSymbolKind.Enum)
      (match (deref right)
        [(CompilerSemanticSymbolKind.Enum) true]
        [_ false])]
    [(CompilerSemanticSymbolKind.Module)
      (match (deref right)
        [(CompilerSemanticSymbolKind.Module) true]
        [_ false])]
    [(CompilerSemanticSymbolKind.Field)
      (match (deref right)
        [(CompilerSemanticSymbolKind.Field) true]
        [_ false])]
    [(CompilerSemanticSymbolKind.EnumMember)
      (match (deref right)
        [(CompilerSemanticSymbolKind.EnumMember) true]
        [_ false])]
    [(CompilerSemanticSymbolKind.Parameter)
      (match (deref right)
        [(CompilerSemanticSymbolKind.Parameter) true]
        [_ false])]
    [(CompilerSemanticSymbolKind.Local)
      (match (deref right)
        [(CompilerSemanticSymbolKind.Local) true]
        [_ false])]))

;; Return true when changing one exact canonical occurrence to `new-name`
;; would capture or collide with a different checked binding. The occurrence
;; coordinates disambiguate aliases and component records that deliberately
;; share one canonical declaration identity.
(define (compiler-semantic-source-index-rename-collision?
  [index : (& index CompilerSemanticSourceIndex)]
  [canonical-key : (& canonical-key str)]
  [path : String]
  [start-byte : i64]
  [end-byte : i64]
  [new-name : (& new-name str)]) : bool
  (let
    [record-index : i64 0]
    [target-index : i64 -1]
    (begin
      (while (and (< target-index 0) (< record-index index.len))
        (let
          [record : CompilerSemanticRecord
            (compiler-semantic-source-index-get index record-index)]
          (if (and
            (string.eq record.span.path path)
            (= record.span.start-byte start-byte)
            (= record.span.end-byte end-byte)
            (string.eq
              (compiler-semantic-source-index-record-canonical-key
                index
                (& record))
              canonical-key))
            (set! target-index record-index)
            (set! record-index (+ record-index 1)))))
      (if (< target-index 0)
        false
        (let
          [target : CompilerSemanticRecord
            (compiler-semantic-source-index-get index target-index)]
          [scan : i64 0]
          (begin
            (when
              (or
                (compiler-semantic-rename-visible-collision-at?
                  index
                  (& target)
                  target.span.start-byte
                  new-name)
                (compiler-semantic-rename-visible-collision-at?
                  index
                  (& target)
                  target.span.end-byte
                  new-name))
              (return true))
            (while (< scan index.len)
              (let
                [candidate : CompilerSemanticRecord
                  (compiler-semantic-source-index-get index scan)]
                (begin
                  (when
                    (and
                      (match candidate.role
                        [(CompilerSemanticRecordRole.Definition) true]
                        [_ false])
                      (string.eq candidate.display-name new-name)
                      (not
                        (compiler-semantic-rename-symbol-eq?
                          (& candidate.symbol)
                          (& target.symbol)))
                      (cond
                        [(or
                            (match target.kind
                              [(CompilerSemanticSymbolKind.Field) true]
                              [_ false])
                            (match target.kind
                              [(CompilerSemanticSymbolKind.EnumMember) true]
                              [_ false]))
                          (and
                            (compiler-semantic-rename-kind-eq?
                              (& target.kind)
                              (& candidate.kind))
                            (compiler-semantic-rename-member-owner-eq?
                              (& target)
                              (& candidate)))]
                        [(match target.kind
                            [(CompilerSemanticSymbolKind.Module) true]
                            [_ false])
                          (and
                            (match candidate.kind
                              [(CompilerSemanticSymbolKind.Module) true]
                              [_ false])
                            (string.eq candidate.span.path target.span.path))]
                        [(or
                            (match target.kind
                              [(CompilerSemanticSymbolKind.Parameter) true]
                              [_ false])
                            (match target.kind
                              [(CompilerSemanticSymbolKind.Local) true]
                              [_ false]))
                          (and
                            (=
                              candidate.symbol.module-id
                              target.symbol.module-id)
                            (=
                              candidate.symbol.declaration-ordinal
                              target.symbol.declaration-ordinal)
                            (or
                              (match candidate.kind
                                [(CompilerSemanticSymbolKind.Parameter) true]
                                [_ false])
                              (match candidate.kind
                                [(CompilerSemanticSymbolKind.Local) true]
                                [_ false])))]
                        [else false]))
                    (return true))
                  (set! scan (+ scan 1)))))
            false))))))

(define (compiler-semantic-symbol-id-eq?
  [left : CompilerSemanticSymbolId]
  [right : CompilerSemanticSymbolId]) : bool
  (and
    (= left.module-id right.module-id)
    (= left.declaration-ordinal right.declaration-ordinal)
    (= left.local-ordinal right.local-ordinal)))

(define (compiler-semantic-source-index-find-symbol-role
  [index : (& index CompilerSemanticSourceIndex)]
  [symbol : CompilerSemanticSymbolId]
  [role : CompilerSemanticRecordRole]) : i64
  (let
    [record-index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< record-index index.len))
        (let
          [record : CompilerSemanticRecord
            (owned_view.compiler-owned-array-element-shared-view
              index.records
              record-index)]
          [record-symbol : CompilerSemanticSymbolId record.symbol]
          (begin
            (if (and
              (match role
                [(CompilerSemanticRecordRole.Definition)
                  (match record.role
                    [(CompilerSemanticRecordRole.Definition) true]
                    [_ false])]
                [(CompilerSemanticRecordRole.Use)
                  (match record.role
                    [(CompilerSemanticRecordRole.Use) true]
                    [_ false])])
              (= record-symbol.module-id symbol.module-id)
              (= record-symbol.declaration-ordinal symbol.declaration-ordinal)
              (= record-symbol.local-ordinal symbol.local-ordinal))
              (set! found record-index)
              unit)
            (set! record-index (+ record-index 1)))))
      found)))