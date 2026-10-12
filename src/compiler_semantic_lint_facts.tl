(import compiler_check_core as check)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import sym_i64_env)
(import stdlib.arena)
(import stdlib.hashmap)
(import stdlib.string)
(import compiler_ast_types as ast)
(import compiler_typecheck_core as tc)
(import compiler_symbols as csym)
(import compiler_intern as ci)
(import compiler_parse_core as parser)
(import stdlib.option)
(import (option.option i64) as option_i64)
(import compiler_owned_view as owned_view)
(import (hashmap.hashmap i64 i64) as fact_index)
(import (hashmap.hashmap (Tuple i64 i64) i64) as binding_index)
(import (hashmap.hashmap (Tuple i64 i64 i64) i64) as slot_index)

(defenum CompilerSemanticFactReliability
  (Reliable)
  (Unresolved)
  (Poisoned)
  (Dependent))

(defenum CompilerSemanticFactProvenance
  (Unknown)
  (Source)
  (MacroArgument)
  (Synthetic)
  (CheckedGenerated))

(defenum CompilerSemanticTryFact
  (NotTry)
  (Compatible)
  (Incompatible String)
  (Missing))

(defenum CompilerSemanticFactIdentityKind
  (None)
  (Value)
  (Function)
  (Variant)
  (CoreOperation)
  (Parameter)
  (Local)
  (Field)
  (Struct)
  (Enum))

;; Ordinals identify declarations within this snapshot. Owned owner/name/path
;; and token provenance let consumers derive persistent anchors without
;; retaining an intern table or a mutable checker environment.
(defstruct CompilerSemanticFactIdentity
  (kind CompilerSemanticFactIdentityKind)
  (module String)
  (name String)
  (path String)
  (declaration i64)
  (local i64)
  (scope i64)
  (span ast.AstSourceSpan)
  (handle i64)
  (function i64))

(defstruct CompilerSemanticFactType
  (text String)
  (nominal CompilerSemanticFactIdentity))

(defstruct CompilerSemanticFactFunction
  (identity CompilerSemanticFactIdentity)
  (body i64)
  (return-type CompilerSemanticFactType))

(defstruct CompilerSemanticExpressionFact
  (expression i64)
  (resolved-type CompilerSemanticFactType)
  (resolved-value CompilerSemanticFactIdentity)
  (function i64)
  (scope i64)
  (path String)
  (span ast.AstSourceSpan)
  (provenance CompilerSemanticFactProvenance)
  (reliability CompilerSemanticFactReliability)
  (early-exit-allowed bool)
  (try-fact CompilerSemanticTryFact))

;; Only owned text, scalar identities and immutable source spans cross the
;; callback boundary. No AstType node ids, TcContext, TcTypeEnv or parser
;; sidecars are stored in the consumer-facing value.
(defstruct CompilerSemanticFactStorage
  (expressions (__tl_dyn-array CompilerSemanticExpressionFact))
  (expression-count i64)
  (expression-index fact_index.Map)
  (functions (__tl_dyn-array CompilerSemanticFactFunction))
  (function-count i64)
  (bindings (__tl_dyn-array CompilerSemanticFactIdentity))
  (binding-count i64))

(defstruct CompilerSemanticFactFrame
  (expression i64)
  (function i64)
  (scope i64)
  (forbidden bool)
  (provenance CompilerSemanticFactProvenance)
  (path String)
  (member-handle i64)
  (reference-key i64)
  (global-reference bool)
  (reference-binding i64)
  (binding-site ast.AstSourceSpan))

(defstruct CompilerSemanticFactRecorderData
  (owner arena.Arena)
  (facts CompilerSemanticFactStorage)
  (request-path String)
  (source-provenance CompilerSemanticFactProvenance)
  (recording bool)
  (current-path String)
  (current-function i64)
  (current-scope i64)
  (frames (__tl_dyn-array CompilerSemanticFactFrame))
  (frame-count i64)
  (expansions (__tl_dyn-array CompilerSemanticFactFrame))
  (expansion-depth i64)
  (function-parents (__tl_dyn-array i64))
  (function-depth i64)
  (spmd-functions (__tl_dyn-array i64))
  (spmd-depth i64)
  (function-index fact_index.Map)
  ;; Scoped carriers have distinct per-job lookup epochs. Imports may shift
  ;; slots, so slot/generation alone cannot identify a declaration.
  (slot-bindings slot_index.Map)
  (persistent-bindings binding_index.Map)
  (origins (__tl_dyn-array parser.CompilerParseSemanticOrigin))
  (origin-used (__tl_dyn-array bool))
  (declaration-origins (__tl_dyn-array CompilerSemanticFactIdentity))
  (declaration-origin-index fact_index.Map)
  (generated bool)
  (sealed bool))

(defstruct CompilerSemanticFactRecorder
  (address i64))

(defenum CompilerSemanticFactLookup
  (Missing)
  (Found CompilerSemanticExpressionFact))

(define (compiler-semantic-fact-identity-empty) : CompilerSemanticFactIdentity
  (CompilerSemanticFactIdentity
    CompilerSemanticFactIdentityKind.None
    ""
    ""
    ""
    -1
    -1
    -1
    (ast.ast-source-span 0 0 0 0)
    -1
    -1))

(define (compiler-semantic-fact-type-empty) : CompilerSemanticFactType
  (CompilerSemanticFactType "" (compiler-semantic-fact-identity-empty)))

(define (compiler-semantic-facts-new) : CompilerSemanticFactStorage
  (CompilerSemanticFactStorage
    (__tl_make-array CompilerSemanticExpressionFact 16)
    0
    (fact_index.with-capacity 32)
    (__tl_make-array CompilerSemanticFactFunction 4)
    0
    (__tl_make-array CompilerSemanticFactIdentity 16)
    0))

(define (compiler-semantic-fact-recorder-new
  [path : String]
  [checked-generated-source : bool]) : CompilerSemanticFactRecorder
  (let
    [cell : (__tl_dyn-array CompilerSemanticFactRecorderData)
      (__tl_make-array CompilerSemanticFactRecorderData 1)]
    (set!
      (array-ref cell 0)
      (CompilerSemanticFactRecorderData
        (arena.current)
        (compiler-semantic-facts-new)
        path
        (if checked-generated-source
          CompilerSemanticFactProvenance.CheckedGenerated
          CompilerSemanticFactProvenance.Source)
        false
        ""
        -1
        -1
        (__tl_make-array CompilerSemanticFactFrame 0)
        0
        (__tl_make-array CompilerSemanticFactFrame 0)
        0
        (__tl_make-array i64 0)
        0
        (__tl_make-array i64 0)
        0
        (fact_index.with-capacity 32)
        (slot_index.with-capacity 32)
        (binding_index.with-capacity 32)
        (__tl_make-array parser.CompilerParseSemanticOrigin 0)
        (__tl_make-array bool 0)
        (__tl_make-array CompilerSemanticFactIdentity 0)
        (fact_index.with-capacity 32)
        false
        false))
    (CompilerSemanticFactRecorder
      (cast
        (unsafe
          (ptr->int (__tl_array-data cell)))
        : i64))))

(define (compiler-semantic-fact-recorder-data
  [recorder : CompilerSemanticFactRecorder]) : CompilerSemanticFactRecorderData
  (unsafe
    (ptr-read
      (int->ptr
        (cast recorder.address : u64)
        : (Ptr CompilerSemanticFactRecorderData)))))

(define (compiler-semantic-fact-recorder-data-set!
  [recorder : CompilerSemanticFactRecorder]
  [data : CompilerSemanticFactRecorderData]) : unit
  (unsafe
    (ptr-write!
      (int->ptr
        (cast recorder.address : u64)
        : (MutPtr CompilerSemanticFactRecorderData))
      data)))

(define (compiler-semantic-facts-find-index
  [facts : (& facts CompilerSemanticFactStorage)]
  [expression : i64]) : i64
  (fact_index.get-value-or (& facts.expression-index) expression -1))

(defstruct CompilerSemanticFacts
  (address i64))

(defenum CompilerSemanticFunctionLookup
  (Missing)
  (Found CompilerSemanticFactFunction))

(defenum CompilerSemanticBindingLookup
  (Missing)
  (Found CompilerSemanticFactIdentity))

;; The public capability contains no writable buffers. Selected records are
;; cloned into the consumer's active arena; reading the underlying storage
;; directly requires the same unsafe proof as other compiler state handles.
(unsafe
  (define (compiler-semantic-facts-storage
    [facts : (& facts CompilerSemanticFacts)]) : CompilerSemanticFactStorage
    (compiler-semantic-fact-recorder-data
      (CompilerSemanticFactRecorder facts.address)).facts))

(define (compiler-semantic-facts-expression-count
  [facts : (& facts CompilerSemanticFacts)]) : i64
  (unsafe
    (compiler-semantic-facts-storage facts)).expression-count)

(define (compiler-semantic-facts-function-count
  [facts : (& facts CompilerSemanticFacts)]) : i64
  (unsafe
    (compiler-semantic-facts-storage facts)).function-count)

(define (compiler-semantic-facts-binding-count
  [facts : (& facts CompilerSemanticFacts)]) : i64
  (unsafe
    (compiler-semantic-facts-storage facts)).binding-count)

(define (compiler-semantic-facts-expression-at
  [facts : (& facts CompilerSemanticFacts)]
  [index : i64]) : CompilerSemanticFactLookup
  (let
    [storage : CompilerSemanticFactStorage
      (unsafe
        (compiler-semantic-facts-storage facts))]
    (if (and (>= index 0) (< index storage.expression-count))
      (CompilerSemanticFactLookup.Found
        (clone (array-ref storage.expressions index)))
      CompilerSemanticFactLookup.Missing)))

(define (compiler-semantic-facts-lookup
  [facts : (& facts CompilerSemanticFacts)]
  [expression : i64]) : CompilerSemanticFactLookup
  (let
    [storage : CompilerSemanticFactStorage
      (unsafe
        (compiler-semantic-facts-storage facts))]
    (compiler-semantic-facts-expression-at
      facts
      (compiler-semantic-facts-find-index (& storage) expression))))

(define (compiler-semantic-facts-function-at
  [facts : (& facts CompilerSemanticFacts)]
  [index : i64]) : CompilerSemanticFunctionLookup
  (let
    [storage : CompilerSemanticFactStorage
      (unsafe
        (compiler-semantic-facts-storage facts))]
    (if (and (>= index 0) (< index storage.function-count))
      (CompilerSemanticFunctionLookup.Found
        (clone (array-ref storage.functions index)))
      CompilerSemanticFunctionLookup.Missing)))

(define (compiler-semantic-facts-binding-at
  [facts : (& facts CompilerSemanticFacts)]
  [index : i64]) : CompilerSemanticBindingLookup
  (let
    [storage : CompilerSemanticFactStorage
      (unsafe
        (compiler-semantic-facts-storage facts))]
    (if (and (>= index 0) (< index storage.binding-count))
      (CompilerSemanticBindingLookup.Found
        (clone (array-ref storage.bindings index)))
      CompilerSemanticBindingLookup.Missing)))

(define (compiler-semantic-fact-editable?
  [fact : (& fact CompilerSemanticExpressionFact)]) : bool
  (and
    (> fact.span.start-line 0)
    (match fact.reliability
      [(CompilerSemanticFactReliability.Reliable) true]
      [_ false])
    (match fact.provenance
      [(CompilerSemanticFactProvenance.Source) true]
      [(CompilerSemanticFactProvenance.MacroArgument) true]
      [(CompilerSemanticFactProvenance.CheckedGenerated) true]
      [_ false])))

(define (compiler-semantic-fact-recorder-grow!
  [recorder : CompilerSemanticFactRecorder]) : unit
  (let
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    [old : (__tl_dyn-array CompilerSemanticExpressionFact)
      data.facts.expressions]
    (in-arena
      data.owner
      (let
        [next : (__tl_dyn-array CompilerSemanticExpressionFact)
          (__tl_make-array
            CompilerSemanticExpressionFact
            (* 2 (array-length old)))]
        [index : i64 0]
        (while (< index data.facts.expression-count)
          (set!
            (array-ref next index)
            (owned_view.compiler-owned-array-element-shared-view old index))
          (set! index (+ index 1)))
        (set! data.facts.expressions next)
        (compiler-semantic-fact-recorder-data-set! recorder data)))))

(define (compiler-semantic-fact-recorder-store!
  [recorder : CompilerSemanticFactRecorder]
  [fact : CompilerSemanticExpressionFact]) : unit
  (let
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    [existing : i64
      (compiler-semantic-facts-find-index (& data.facts) fact.expression)]
    (unless
      data.sealed
      (if (>= existing 0)
        (set! (array-ref data.facts.expressions existing) fact)
        (begin
          (when
            (>=
              data.facts.expression-count
              (array-length data.facts.expressions))
            (compiler-semantic-fact-recorder-grow! recorder))
          (let
            [ready : CompilerSemanticFactRecorderData
              (compiler-semantic-fact-recorder-data recorder)]
            [index : i64 ready.facts.expression-count]
            (in-arena
              ready.owner
              (set! (array-ref ready.facts.expressions index) fact)
              (fact_index.insert-ref!
                (&mut ready.facts.expression-index)
                fact.expression
                index)
              (set! ready.facts.expression-count (+ index 1))
              (compiler-semantic-fact-recorder-data-set! recorder ready))))))))

(define (compiler-semantic-fact-direct-nominal-name [ty : ast.AstType]) : i64
  (match ty
    [(ast.AstType.Struct name) name]
    [(ast.AstType.StructArgs name _) name]
    [(ast.AstType.Enum name) name]
    [(ast.AstType.EnumArgs name _) name]
    [_ -1]))

(define (compiler-semantic-fact-handle-identity
  [ctx : tc.TcContext]
  [handle : i64]
  [fallback-path : String]) : CompilerSemanticFactIdentity
  (if (not (csym.compiler-symbols-handle-found? handle))
    (compiler-semantic-fact-identity-empty)
    (let
      [tag : i64 (csym.compiler-symbol-handle-kind handle)]
      [member : bool
        (or
          (= tag (csym.compiler-symbol-kind-enum-variant))
          (= tag (csym.compiler-symbol-kind-struct-field)))]
      [declaration : i64
        (if member
          (csym.compiler-registry-handle-owner-index handle)
          (csym.compiler-symbol-handle-index handle))]
      [symbols : (& ctx csym.CompilerSymbols) (tc.tc-context-symbols ctx)]
      [module : i64
        (csym.compiler-symbols-owner-module-id-at-index-or
          symbols
          declaration
          -1)]
      [path-id : i64
        (csym.compiler-symbols-provenance-id-at-index-or symbols declaration -1)]
      [name : i64
        (csym.compiler-symbols-decl-name-id-at-index symbols declaration)]
      [kind : CompilerSemanticFactIdentityKind
        (cond
          [(= tag (csym.compiler-symbol-kind-defstruct))
            CompilerSemanticFactIdentityKind.Struct]
          [(= tag (csym.compiler-symbol-kind-defenum))
            CompilerSemanticFactIdentityKind.Enum]
          [(= tag (csym.compiler-symbol-kind-enum-variant))
            CompilerSemanticFactIdentityKind.Variant]
          [(= tag (csym.compiler-symbol-kind-struct-field))
            CompilerSemanticFactIdentityKind.Field]
          [(or
              (= tag (csym.compiler-symbol-kind-function-define))
              (= tag (csym.compiler-symbol-kind-extern))
              (= tag (csym.compiler-symbol-kind-defdispatch)))
            CompilerSemanticFactIdentityKind.Function]
          [else CompilerSemanticFactIdentityKind.Value])]
      (CompilerSemanticFactIdentity
        kind
        (if (>= module 0)
          (tc.macro-decl-module-display module)
          "")
        (if (>= name 0)
          (ci.intern-str name)
          "")
        (if (>= path-id 0)
          (ci.intern-str path-id)
          fallback-path)
        declaration
        (if member
          (csym.compiler-registry-handle-child-index handle)
          -1)
        -1
        (ast.ast-decl-span-fallback)
        handle
        -1))))

(define (compiler-semantic-fact-span-before?
  [left : ast.AstSourceSpan]
  [right : ast.AstSourceSpan]) : bool
  (or
    (< left.start-line right.start-line)
    (and
      (= left.start-line right.start-line)
      (< left.start-col right.start-col))))

(define (compiler-semantic-fact-span-contains?
  [outer : ast.AstSourceSpan]
  [inner : ast.AstSourceSpan]) : bool
  (and
    (> inner.start-line 0)
    (not (compiler-semantic-fact-span-before? inner outer))
    (or
      (< inner.end-line outer.end-line)
      (and (= inner.end-line outer.end-line) (<= inner.end-col outer.end-col)))))

(define (compiler-semantic-fact-recorder-declaration!
  [recorder : CompilerSemanticFactRecorder]
  [ctx : tc.TcContext]
  [storage : i64]
  [slot : i64]
  [path : String]
  [decl : ast.AstDecl]) : unit
  (let
    [run : parser.CompilerParseMaybeSemanticOriginRun
      (parser.compiler-parse-semantic-origin-run-key-slot storage slot)]
    [_declaration-origin : unit
      (compiler-semantic-fact-declaration-origins!
        recorder
        ctx
        (owned_view.compiler-owned-shared-view decl)
        (owned_view.compiler-owned-shared-view path)
        run)]
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    [_select : unit
      (set!
        data.recording
        (and
          (string.eq (& data.request-path) (& path))
          (match (ast.ast-decl-unwrapped (& decl))
            [(ast.AstDecl.DefMacro _ _ _ _ _) false]
            [_ true])))]
    (in-arena
      data.owner
      (unless
        data.recording
        (begin
          (compiler-semantic-fact-recorder-data-set! recorder data)
          (return unit)))
      (set! data.current-path (string.copy (& path)))
      (set!
        data.generated
        (match (ast.ast-decl-generated-meta (& decl))
          [(ast.AstGeneratedDeclMeta.No) false]
          [(ast.AstGeneratedDeclMeta.Some _ _ _ _) true]))
      (set! data.origins (__tl_make-array parser.CompilerParseSemanticOrigin 0))
      (set! data.origin-used (__tl_make-array bool 0))
      (match run
        [(parser.CompilerParseMaybeSemanticOriginRun.None) unit]
        [(parser.CompilerParseMaybeSemanticOriginRun.Some origins)
          (let
            [i : i64 0]
            (while (<
              i
              (parser.compiler-parse-semantic-origin-run-len (& origins)))
              (__tl_array-push!
                data.origins
                (parser.compiler-parse-semantic-origin-run-get
                  (& origins)
                  i
                  (parser.compiler-parse-semantic-origin-fallback)))
              (__tl_array-push! data.origin-used false)
              (set! i (+ i 1))))])
      ;; The declaration's name precedes parameters and body bindings.
      (when
        (> (array-length data.origin-used) 0)
        (match (array-ref data.origins 0).kind
          [(parser.CompilerParseSemanticOriginKind.ValueName)
            (set! (array-ref data.origin-used 0) true)]
          [_ unit]))
      (compiler-semantic-fact-recorder-data-set! recorder data))))

(define (compiler-semantic-fact-declaration-origins!
  [recorder : CompilerSemanticFactRecorder]
  [ctx : tc.TcContext]
  [decl : ast.AstDecl]
  [path : String]
  [run : parser.CompilerParseMaybeSemanticOriginRun]) : unit
  (match (owned_view.compiler-owned-shared-view decl)
    [(ast.AstDecl.Unsafe inner)
      (compiler-semantic-fact-declaration-origins!
        recorder
        ctx
        (ast.ast-decl-box-shared-view inner)
        path
        run)]
    [_
      (let
        [data : CompilerSemanticFactRecorderData
          (compiler-semantic-fact-recorder-data recorder)]
        [name : i64
          (match (csym.compiler-symbol-owner-decl-name-id
            (owned_view.compiler-owned-shared-view decl))
            [(option_i64.Some id) id]
            [(option_i64.None) -1])]
        [nominal : bool
          (match decl
            [(ast.AstDecl.DefStruct _ _ _ _ _) true]
            [(ast.AstDecl.DefStructLifetimes _ _ _ _ _ _) true]
            [(ast.AstDecl.DefEnum _ _ _ _) true]
            [(ast.AstDecl.DefEnumLifetimes _ _ _ _ _) true]
            [_ false])]
        [nominal-name : i64
          (if nominal
            (tc.tc-check-decl-scoped-name-id ctx name)
            -1)]
        [handle : i64
          (if (< name 0)
            -1
            (if nominal
              (csym.compiler-symbols-lookup-type-id-or
                (tc.tc-context-symbols ctx)
                nominal-name
                (csym.compiler-symbols-missing-handle))
              (match (csym.compiler-symbols-lookup-value-in-module-id
                (tc.tc-context-symbols ctx)
                (tc.tc-context-module-id ctx)
                name)
                [(option_i64.Some id) id]
                [(option_i64.None) -1])))]
        (match run
          [(parser.CompilerParseMaybeSemanticOriginRun.None) unit]
          [(parser.CompilerParseMaybeSemanticOriginRun.Some origins)
            (let
              [i : i64 0]
              (while (< i origins.count)
                (let
                  [origin : parser.CompilerParseSemanticOrigin
                    (parser.compiler-parse-semantic-origin-run-get
                      (& origins)
                      i
                      (parser.compiler-parse-semantic-origin-fallback))]
                  [origin-handle : i64
                    (match origin.kind
                      [(parser.CompilerParseSemanticOriginKind.TypeDefinition)
                        handle]
                      [(parser.CompilerParseSemanticOriginKind.ValueName)
                        (if (and (= i 0) (= origin.written-name name))
                          handle
                          -1)]
                      [(parser.CompilerParseSemanticOriginKind.StructFieldDefinition)
                        (csym.compiler-registries-lookup-struct-field-id-or
                          (tc.tc-context-registries ctx)
                          nominal-name
                          origin.written-name
                          -1)]
                      [(parser.CompilerParseSemanticOriginKind.EnumVariantDefinition)
                        (tc.tc-variant-name-handle
                          ctx
                          nominal-name
                          origin.written-name)]
                      [_ -1])]
                  (when
                    (>= origin-handle 0)
                    (let
                      [identity : CompilerSemanticFactIdentity
                        (compiler-semantic-fact-handle-identity
                          ctx
                          origin-handle
                          (owned_view.compiler-owned-shared-view path))]
                      (in-arena
                        data.owner
                        (set! identity.span origin.span)
                        (set! identity.path (string.copy (& path)))
                        (when
                          (or
                            (= origin-handle handle)
                            (=
                              (csym.compiler-symbol-handle-kind origin-handle)
                              (csym.compiler-symbol-kind-enum-variant))
                            (=
                              (csym.compiler-symbol-handle-kind origin-handle)
                              (csym.compiler-symbol-kind-struct-field)))
                          (set!
                            identity.name
                            (string.copy (ci.intern-str origin.written-name))))
                        (let
                          [index : i64 (array-length data.declaration-origins)]
                          (__tl_array-push!
                            data.declaration-origins
                            (clone identity))
                          (fact_index.insert-ref!
                            (&mut data.declaration-origin-index)
                            origin-handle
                            index)))))
                  (set! i (+ i 1)))))])
        (compiler-semantic-fact-recorder-data-set! recorder data))]))

(define (compiler-semantic-fact-binding-span!
  [recorder : CompilerSemanticFactRecorder]
  [ctx : tc.TcContext]
  [name : i64]) : ast.AstSourceSpan
  (if (let
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    (or
      (< data.current-function 0)
      data.generated
      (and
        (> data.frame-count 0)
        (match (array-ref data.frames (- data.frame-count 1)).provenance
          [(CompilerSemanticFactProvenance.Synthetic) true]
          [(CompilerSemanticFactProvenance.Unknown) true]
          [_ false]))))
    (ast.ast-decl-span-fallback)
    (let
      [data : CompilerSemanticFactRecorderData
        (compiler-semantic-fact-recorder-data recorder)]
      [pools : ast.AstNodePoolContext (tc.tc-context-pools ctx)]
      [expression : i64
        (if (> data.frame-count 0)
          (array-ref data.frames (- data.frame-count 1)).expression
          -1)]
      [parameter : bool
        (or
          (= data.frame-count 0)
          (!=
            (array-ref data.frames (- data.frame-count 1)).function
            data.current-function))]
      [site : i64
        (if parameter
          (array-ref data.facts.functions data.current-function).body
          (match (ast.ast-expr-unspan-with-pools
            (& pools)
            (& (tc.tc-context-expr-get ctx expression)))
            [(ast.AstExpr.Foreach payload)
              (match (ast.ast-foreach-box-shared-view payload)
                [(ast.AstForeach.Foreach index _ start _ _)
                  (if (= index name)
                    start
                    -1)]
                [(ast.AstForeach.Foreach2
                    outer
                    _
                    outer-start
                    _
                    inner
                    _
                    inner-start
                    _
                    _)
                  (cond
                    [(= outer name) outer-start]
                    [(= inner name) inner-start]
                    [else -1])])]
            [(ast.AstExpr.ForeachActive lane body)
              (if (= lane name)
                body
                -1)]
            [(ast.AstExpr.SpmdReduce payload)
              (match (ast.ast-spmd-reduce-box-shared-view payload)
                [(ast.AstSpmdReduce.Reduce _ index _ start _ _ _)
                  (if (= index name)
                    start
                    -1)])]
            [(ast.AstExpr.SpmdScan payload)
              (match (ast.ast-spmd-scan-box-shared-view payload)
                [(ast.AstSpmdScan.Scan _ index _ start _ prefix _ init _ _)
                  (cond [(= index name) start] [(= prefix name) init] [else -1])])]
            [(ast.AstExpr.SpmdCompact payload)
              (match (ast.ast-spmd-compact-box-shared-view payload)
                [(ast.AstSpmdCompact.Compact index _ start _ slot _ init _ _)
                  (cond [(= index name) start] [(= slot name) init] [else -1])])]
            [_ -1]))]
      [explicit : ast.AstSourceSpan
        (if (or parameter (= data.frame-count 0))
          (ast.ast-decl-span-fallback)
          (array-ref data.frames (- data.frame-count 1)).binding-site)]
      [anchor : ast.AstSourceSpan
        (if (> explicit.start-line 0)
          explicit
          (if (< site 0)
            (ast.ast-decl-span-fallback)
            (match (tc.tc-expr-id-maybe-span
              (tc.tc-context-expr-bases ctx)
              site)
              [(tc.TcMaybeAstSourceSpan.Some span) span]
              [_ (ast.ast-decl-span-fallback)])))]
      [limit : ast.AstSourceSpan
        (if (< expression 0)
          (ast.ast-decl-span-fallback)
          (match (tc.tc-expr-id-maybe-span
            (tc.tc-context-expr-bases ctx)
            expression)
            [(tc.TcMaybeAstSourceSpan.Some span) span]
            [_ (ast.ast-decl-span-fallback)]))]
      [selected : i64 -1]
      [i : i64 0]
      ;; The checker supplies the initializer, so the nearest preceding token
      ;; is stable across rechecks and excludes bindings inside that initializer.
      ;; Without such an anchor, consume only exact parser tokens in this scope.
      (while (< i (array-length data.origins))
        (let
          [origin : parser.CompilerParseSemanticOrigin
            (array-ref data.origins i)]
          (when
            (and
              (= origin.written-name name)
              (match origin.kind
                [(parser.CompilerParseSemanticOriginKind.BindingDefinition)
                  true]
                [_ false])
              (or
                (= limit.start-line 0)
                (compiler-semantic-fact-span-contains? limit origin.span))
              (if (> anchor.start-line 0)
                (or
                  (< origin.span.end-line anchor.start-line)
                  (and
                    (= origin.span.end-line anchor.start-line)
                    (<= origin.span.end-col anchor.start-col)))
                (not (array-ref data.origin-used i))))
            (when
              (or
                (< selected 0)
                (and
                  (> anchor.start-line 0)
                  (compiler-semantic-fact-span-before?
                    (array-ref data.origins selected).span
                    origin.span)))
              (set! selected i)))
          (set! i (+ i 1))))
      (if (>= selected 0)
        (begin
          (set! (array-ref data.origin-used selected) true)
          (array-ref data.origins selected).span)
        (ast.ast-decl-span-fallback)))))

(define (compiler-semantic-fact-recorder-binding!
  [recorder : CompilerSemanticFactRecorder]
  [ctx : tc.TcContext]
  [epoch : i64]
  [slot : i64]
  [generation : i64]
  [name : i64]) : unit
  (let
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    [span : ast.AstSourceSpan
      (compiler-semantic-fact-binding-span! recorder ctx name)]
    (when
      (>= data.current-function 0)
      (in-arena
        data.owner
        (let
          [text : String
            (string.copy
              (tc.tc-env-key-name-text-for-session
                (tc.tc-context-structural-session ctx)
                name))]
          [index : i64 -1]
          [i : i64 0]
          ;; A source body may be checked again for its SPMD form. Reuse
          ;; the same owned declaration, while publishing the new slot's
          ;; generation. Distinct shadow tokens never share this identity.
          (while (and
            (> span.start-line 0)
            (< i data.facts.binding-count)
            (< index 0))
            (let
              [previous : CompilerSemanticFactIdentity
                (owned_view.compiler-owned-array-element-shared-view
                  data.facts.bindings
                  i)]
              (when
                (and
                  (= previous.function data.current-function)
                  (= previous.scope data.current-scope)
                  (= previous.span.start-line span.start-line)
                  (= previous.span.start-col span.start-col)
                  (= previous.span.end-line span.end-line)
                  (= previous.span.end-col span.end-col)
                  (string.eq (& previous.name) (& text)))
                (set! index i))
              (set! i (+ i 1))))
          (when
            (< index 0)
            (set! index data.facts.binding-count)
            (when
              (>= index (array-length data.facts.bindings))
              (__tl_array-push!
                data.facts.bindings
                (compiler-semantic-fact-identity-empty)))
            (set!
              (array-ref data.facts.bindings index)
              (CompilerSemanticFactIdentity
                (if (or
                  (= data.frame-count 0)
                  (!=
                    (array-ref data.frames (- data.frame-count 1)).function
                    data.current-function))
                  CompilerSemanticFactIdentityKind.Parameter
                  CompilerSemanticFactIdentityKind.Local)
                (string.copy (tc.tc-context-module ctx))
                text
                (string.copy (& data.current-path))
                (array-ref data.facts.functions data.current-function).identity.declaration
                index
                data.current-scope
                span
                -1
                data.current-function))
            (set! data.facts.binding-count (+ index 1)))
          (slot_index.insert-ref!
            (&mut data.slot-bindings)
            (tuple epoch slot generation)
            index)
          (compiler-semantic-fact-recorder-data-set! recorder data))))))

(define (compiler-semantic-fact-reset-binding-origins!
  [recorder : CompilerSemanticFactRecorder]
  [ctx : tc.TcContext]
  [expression : i64]) : unit
  (let
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    [limit : ast.AstSourceSpan
      (match (tc.tc-expr-id-maybe-span
        (tc.tc-context-expr-bases ctx)
        expression)
        [(tc.TcMaybeAstSourceSpan.Some span) span]
        [_ (ast.ast-decl-span-fallback)])]
    [i : i64 0]
    (while (< i (array-length data.origins))
      (let
        [origin : parser.CompilerParseSemanticOrigin (array-ref data.origins i)]
        (when
          (and
            (compiler-semantic-fact-span-contains? limit origin.span)
            (match origin.kind
              [(parser.CompilerParseSemanticOriginKind.BindingDefinition) true]
              [_ false]))
          (set! (array-ref data.origin-used i) false))
        (set! i (+ i 1))))))

(define (compiler-semantic-fact-core-operation [name : i64]) : CompilerSemanticFactIdentity
  (CompilerSemanticFactIdentity
    CompilerSemanticFactIdentityKind.CoreOperation
    ""
    (ci.intern-str name)
    ""
    -1
    -1
    -1
    (ast.ast-decl-span-fallback)
    -1
    -1))

(define (compiler-semantic-fact-reference-identity
  [recorder : CompilerSemanticFactRecorder]
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]) : CompilerSemanticFactIdentity
  (let
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    [frame : CompilerSemanticFactFrame
      (owned_view.compiler-owned-array-element-shared-view
        data.frames
        (- data.frame-count 1))]
    [key : i64 frame.reference-key]
    [slot : i64
      (if (and
        (>= key 0)
        (not frame.global-reference)
        (tc.tc-type-env-scoped-runtime-active? env))
        (tc.tc-type-env-scoped-runtime-lookup-index env key)
        -1)]
    [binding : i64
      (if (>= slot 0)
        (slot_index.get-value-or
          (& data.slot-bindings)
          (tuple
            (tc.tc-type-env-scoped-runtime-lookup-epoch env)
            slot
            (tc.tc-type-env-scoped-runtime-slot-generation env slot))
          -1)
        -1)]
    (cond
      [(and
          (>= frame.reference-binding 0)
          (< frame.reference-binding data.facts.binding-count))
        (clone (array-ref data.facts.bindings frame.reference-binding))]
      [(>= frame.member-handle 0)
        (compiler-semantic-fact-handle-identity
          ctx
          frame.member-handle
          (owned_view.compiler-owned-shared-view data.current-path))]
      [(and (>= slot 0) (>= binding 0) (< binding data.facts.binding-count))
        (clone (array-ref data.facts.bindings binding))]
      [(>= slot 0) (compiler-semantic-fact-identity-empty)]
      [(>= key 0)
        (match (csym.compiler-symbols-lookup-value-id
          (tc.tc-context-symbols ctx)
          key)
          [(option_i64.Some handle)
            (compiler-semantic-fact-handle-identity
              ctx
              handle
              (owned_view.compiler-owned-shared-view data.current-path))]
          [(option_i64.None) (compiler-semantic-fact-identity-empty)])]
      [else (compiler-semantic-fact-identity-empty)])))

(define (compiler-semantic-fact-expression-identity
  [recorder : CompilerSemanticFactRecorder]
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]
  [expression : i64]) : CompilerSemanticFactIdentity
  (let
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    [pools : ast.AstNodePoolContext (tc.tc-context-pools ctx)]
    [expr : ast.AstExpr
      (ast.ast-expr-unspan-with-pools
        (& pools)
        (& (tc.tc-context-expr-get ctx expression)))]
    (match expr
      [(ast.AstExpr.Var _)
        (compiler-semantic-fact-reference-identity recorder ctx env)]
      [(ast.AstExpr.Call _ _)
        (compiler-semantic-fact-reference-identity recorder ctx env)]
      [(ast.AstExpr.Binary operation _ _)
        (compiler-semantic-fact-core-operation
          (tc.macro-binop-symbol-id operation))]
      [(ast.AstExpr.Unary operation _)
        (compiler-semantic-fact-core-operation
          (tc.macro-unop-symbol-id operation))]
      [(ast.AstExpr.StructGet _ _)
        (compiler-semantic-fact-handle-identity
          ctx
          (if (> data.frame-count 0)
            (array-ref data.frames (- data.frame-count 1)).member-handle
            -1)
          (owned_view.compiler-owned-shared-view data.current-path))]
      [_ (compiler-semantic-fact-identity-empty)])))

(define (compiler-semantic-fact-try-query
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]
  [expression : i64]
  [forbidden : bool]) : CompilerSemanticTryFact
  (let
    [pools : ast.AstNodePoolContext (tc.tc-context-pools ctx)]
    [expr : ast.AstExpr
      (ast.ast-expr-unspan-with-pools
        (& pools)
        (& (tc.tc-context-expr-get ctx expression)))]
    (match expr
      [(ast.AstExpr.Try operand)
        (match (tc.tc-semantic-recorded-type ctx operand)
          [(tc.TcBodyTypeFact.Miss) CompilerSemanticTryFact.Missing]
          [(tc.TcBodyTypeFact.Hit ty)
            (match (tc.tc-current-return-type env)
              [(tc.ResultTcType.Err _) CompilerSemanticTryFact.Missing]
              [(tc.ResultTcType.Ok ret)
                (match (tc.tc-try-query
                  ctx
                  ty
                  ret
                  (if forbidden
                    tc.TcTryEarlyExitContext.TcTryEarlyExitForbiddenSpmd
                    tc.TcTryEarlyExitContext.TcTryEarlyExitAllowed))
                  [(tc.TcTryQueryResult.TcTryQueryCompatible _ _)
                    CompilerSemanticTryFact.Compatible]
                  [(tc.TcTryQueryResult.TcTryQueryIncompatible _ _ reason)
                    (CompilerSemanticTryFact.Incompatible
                      (tc.tc-try-incompatibility-message reason))])])])]
      [_ CompilerSemanticTryFact.NotTry])))

(define (compiler-semantic-fact-recorder-function-enter!
  [recorder : CompilerSemanticFactRecorder]
  [ctx : tc.TcContext]
  [name : i64]
  [body : i64]
  [ret : ast.AstMaybeType]) : unit
  (let
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    [pools : ast.AstNodePoolContext (tc.tc-context-pools ctx)]
    [owner : i64 (ast.ast-node-pool-context-expr-source-owner (& pools) body)]
    [key : i64
      (if (>= owner 0)
        owner
        body)]
    [existing : i64
      (if (>= key 0)
        (fact_index.get-value-or (& data.function-index) key -1)
        -1)]
    [identity : CompilerSemanticFactIdentity
      (if (< name 0)
        (compiler-semantic-fact-identity-empty)
        (match (csym.compiler-symbols-lookup-value-in-module-id
          (tc.tc-context-symbols ctx)
          (tc.tc-context-module-id ctx)
          name)
          [(option_i64.Some handle)
            (compiler-semantic-fact-handle-identity
              ctx
              handle
              (owned_view.compiler-owned-shared-view data.current-path))]
          [(option_i64.None) (compiler-semantic-fact-identity-empty)]))]
    [return-type : CompilerSemanticFactType
      (match ret
        [(ast.AstMaybeType.Some ty)
          (compiler-semantic-fact-type
            ctx
            ty
            (owned_view.compiler-owned-shared-view data.current-path))]
        [(ast.AstMaybeType.No) (compiler-semantic-fact-type-empty)])]
    [_binding-origins : unit
      (when
        (and (>= existing 0) (> data.frame-count 0))
        (compiler-semantic-fact-reset-binding-origins!
          recorder
          ctx
          (array-ref data.frames (- data.frame-count 1)).expression))]
    (in-arena
      data.owner
      (when
        (< name 0)
        (set! identity.kind CompilerSemanticFactIdentityKind.Function)
        (set! identity.module (string.copy (tc.tc-context-module ctx)))
        (set! identity.path (string.copy (& data.current-path)))
        (set! identity.scope data.current-scope)
        (set!
          identity.span
          (if (> data.frame-count 0)
            (match (tc.tc-expr-id-maybe-span
              (tc.tc-context-expr-bases ctx)
              (array-ref data.frames (- data.frame-count 1)).expression)
              [(tc.TcMaybeAstSourceSpan.Some span) span]
              [_ (ast.ast-decl-span-fallback)])
            (ast.ast-decl-span-fallback))))
      (when
        (>= data.function-depth (array-length data.function-parents))
        (__tl_array-push! data.function-parents -1))
      (set!
        (array-ref data.function-parents data.function-depth)
        data.current-function)
      (set! data.function-depth (+ data.function-depth 1))
      (set!
        data.current-function
        (if (>= existing 0)
          existing
          data.facts.function-count))
      (set! data.current-scope body)
      (when
        (< existing 0)
        (when
          (>= data.facts.function-count (array-length data.facts.functions))
          (__tl_array-push!
            data.facts.functions
            (CompilerSemanticFactFunction
              (compiler-semantic-fact-identity-empty)
              -1
              (compiler-semantic-fact-type-empty))))
        (set!
          (array-ref data.facts.functions data.facts.function-count)
          (CompilerSemanticFactFunction
            (clone identity)
            body
            (clone return-type)))
        (set! data.facts.function-count (+ data.facts.function-count 1))
        (when
          (>= key 0)
          (fact_index.insert-ref!
            (&mut data.function-index)
            key
            data.current-function)))
      (compiler-semantic-fact-recorder-data-set! recorder data))))

(define (compiler-semantic-fact-recorder-function-leave!
  [recorder : CompilerSemanticFactRecorder]
  [ctx : tc.TcContext]
  [result : tc.ResultTcType]) : unit
  (let
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    (when
      (and (>= data.current-function 0) (> data.function-depth 0))
      (begin
        (match result
          [(tc.ResultTcType.Ok (ast.AstType.Func _ return-box))
            (let
              [ret : CompilerSemanticFactType
                (compiler-semantic-fact-type
                  ctx
                  (tc.tc-context-type-get ctx return-box)
                  (owned_view.compiler-owned-shared-view data.current-path))]
              (in-arena
                data.owner
                (set!
                  (array-ref data.facts.functions data.current-function).return-type
                  (clone ret))))]
          [_ unit])
        (set! data.function-depth (- data.function-depth 1))
        (set!
          data.current-function
          (array-ref data.function-parents data.function-depth))
        (set!
          data.current-scope
          (if (> data.frame-count 0)
            (array-ref data.frames (- data.frame-count 1)).scope
            -1))
        (compiler-semantic-fact-recorder-data-set! recorder data)))))

(define (compiler-semantic-fact-source-provenance
  [ctx : tc.TcContext]
  [expression : i64]
  [fallback : CompilerSemanticFactProvenance]) : CompilerSemanticFactProvenance
  (match (tc.tc-context-expr-get ctx expression)
    [(ast.AstExpr.Spanned inner _)
      (compiler-semantic-fact-source-provenance ctx inner fallback)]
    [(ast.AstExpr.MacroExpansion inner provenance name)
      (if (>= name 0)
        CompilerSemanticFactProvenance.Synthetic
        (if (and
          (>= (tc.macro-expansion-origin-path-id provenance) 0)
          (match (tc.tc-expr-id-maybe-span (tc.tc-context-expr-bases ctx) inner)
            [(tc.TcMaybeAstSourceSpan.Some span) (> span.start-line 0)]
            [_ false]))
          CompilerSemanticFactProvenance.MacroArgument
          CompilerSemanticFactProvenance.Unknown))]
    [_ fallback]))

(define (compiler-semantic-fact-recorder-enter!
  [recorder : CompilerSemanticFactRecorder]
  [ctx : tc.TcContext]
  [expression : i64]) : unit
  (let
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    [pools : ast.AstNodePoolContext (tc.tc-context-pools ctx)]
    [same-function : bool
      (and
        (> data.frame-count 0)
        (=
          (array-ref data.frames (- data.frame-count 1)).function
          data.current-function))]
    [forbidden : bool
      (or
        (and
          (> data.spmd-depth 0)
          (=
            (array-ref data.spmd-functions (- data.spmd-depth 1))
            data.current-function))
        (and
          same-function
          (or
            (array-ref data.frames (- data.frame-count 1)).forbidden
            (match (ast.ast-expr-unspan-with-pools
              (& pools)
              (&
                (tc.tc-context-expr-get
                  ctx
                  (array-ref data.frames (- data.frame-count 1)).expression)))
              [(ast.AstExpr.Foreach payload)
                (match (ast.ast-foreach-box-shared-view payload)
                  [(ast.AstForeach.Foreach _ _ _ _ body)
                    (or
                      (= expression body)
                      (=
                        (ast.ast-node-pool-context-expr-source-owner
                          (& pools)
                          expression)
                        body))]
                  [(ast.AstForeach.Foreach2 _ _ _ _ _ _ _ _ body)
                    (or
                      (= expression body)
                      (=
                        (ast.ast-node-pool-context-expr-source-owner
                          (& pools)
                          expression)
                        body))])]
              [(ast.AstExpr.SpmdReduce payload)
                (match (ast.ast-spmd-reduce-box-shared-view payload)
                  [(ast.AstSpmdReduce.Reduce _ _ _ _ _ _ value)
                    (or
                      (= expression value)
                      (=
                        (ast.ast-node-pool-context-expr-source-owner
                          (& pools)
                          expression)
                        value))])]
              [(ast.AstExpr.SpmdScan payload)
                (match (ast.ast-spmd-scan-box-shared-view payload)
                  [(ast.AstSpmdScan.Scan _ _ _ _ _ _ _ _ value body)
                    (or
                      (= expression value)
                      (= expression body)
                      (=
                        (ast.ast-node-pool-context-expr-source-owner
                          (& pools)
                          expression)
                        value)
                      (=
                        (ast.ast-node-pool-context-expr-source-owner
                          (& pools)
                          expression)
                        body))])]
              [(ast.AstExpr.SpmdCompact payload)
                (match (ast.ast-spmd-compact-box-shared-view payload)
                  [(ast.AstSpmdCompact.Compact _ _ _ _ _ _ _ keep body)
                    (or
                      (= expression keep)
                      (= expression body)
                      (=
                        (ast.ast-node-pool-context-expr-source-owner
                          (& pools)
                          expression)
                        keep)
                      (=
                        (ast.ast-node-pool-context-expr-source-owner
                          (& pools)
                          expression)
                        body))])]
              [_ false]))))]
    [scope : i64
      (match (ast.ast-expr-unspan-with-pools
        (& pools)
        (& (tc.tc-context-expr-get ctx expression)))
        [(ast.AstExpr.Let payload)
          (match (ast.ast-let-box-shared-view payload)
            [(ast.AstLet.Let _ body) body])]
        [(ast.AstExpr.Match _) expression]
        [(ast.AstExpr.Foreach _) expression]
        [(ast.AstExpr.ForeachActive _ body) body]
        [(ast.AstExpr.SpmdReduce _) expression]
        [(ast.AstExpr.SpmdScan _) expression]
        [(ast.AstExpr.SpmdCompact _) expression]
        [(ast.AstExpr.WithResource _) expression]
        [(ast.AstExpr.WithRegion _ _) expression]
        [_ data.current-scope])]
    [fallback : CompilerSemanticFactProvenance
      (if (> data.expansion-depth 0)
        (array-ref data.expansions (- data.expansion-depth 1)).provenance
        (if same-function
          (array-ref data.frames (- data.frame-count 1)).provenance
          (match (tc.tc-expr-id-maybe-span
            (tc.tc-context-expr-bases ctx)
            expression)
            [(tc.TcMaybeAstSourceSpan.Some span)
              (if (> span.start-line 0)
                (if data.generated
                  CompilerSemanticFactProvenance.Synthetic
                  data.source-provenance)
                CompilerSemanticFactProvenance.Unknown)]
            [_ CompilerSemanticFactProvenance.Unknown])))]
    [provenance : CompilerSemanticFactProvenance
      (compiler-semantic-fact-source-provenance ctx expression fallback)]
    [_binding-origins : unit
      (when
        (!= scope data.current-scope)
        (compiler-semantic-fact-reset-binding-origins! recorder ctx expression))]
    (in-arena
      data.owner
      (when
        (>= data.frame-count (array-length data.frames))
        (__tl_array-push!
          data.frames
          (CompilerSemanticFactFrame
            -1
            -1
            -1
            false
            CompilerSemanticFactProvenance.Unknown
            ""
            -1
            -1
            false
            -1
            (ast.ast-decl-span-fallback))))
      (set!
        (array-ref data.frames data.frame-count)
        (CompilerSemanticFactFrame
          expression
          data.current-function
          scope
          forbidden
          provenance
          (if (> data.expansion-depth 0)
            (string.copy
              (& (array-ref data.expansions (- data.expansion-depth 1)).path))
            (string.copy (& data.current-path)))
          -1
          -1
          false
          -1
          (ast.ast-decl-span-fallback)))
      (set! data.frame-count (+ data.frame-count 1))
      (set! data.current-scope scope)
      (compiler-semantic-fact-recorder-data-set! recorder data))))

(define (compiler-semantic-fact-recorder-observe!
  [address : i64]
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]
  [event : tc.TcSemanticEvent]) : unit
  (let
    [recorder : CompilerSemanticFactRecorder
      (CompilerSemanticFactRecorder address)]
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    (match (owned_view.compiler-owned-shared-view event)
      [(tc.TcSemanticEvent.Declaration decls slot path decl)
        (compiler-semantic-fact-recorder-declaration!
          recorder
          ctx
          decls
          slot
          path
          decl)]
      [_
        (when
          data.recording
          (match event
            [(tc.TcSemanticEvent.BindingSite initializer)
              (when
                (> data.frame-count 0)
                (set!
                  (array-ref data.frames (- data.frame-count 1)).binding-site
                  (match initializer
                    [(tc.TcMaybeAstSourceSpan.Some span) span]
                    [_ (ast.ast-decl-span-fallback)])))]
            [(tc.TcSemanticEvent.BindingMaterialized
                epoch
                slot
                generation
                store
                node)
              (let
                [binding : i64
                  (slot_index.get-value-or
                    (& data.slot-bindings)
                    (tuple epoch slot generation)
                    -1)]
                (when
                  (>= binding 0)
                  (in-arena
                    data.owner
                    (binding_index.insert-ref!
                      (&mut data.persistent-bindings)
                      (tuple store node)
                      binding)
                    (compiler-semantic-fact-recorder-data-set! recorder data))))]
            [(tc.TcSemanticEvent.BindingImported
                epoch
                slot
                generation
                store
                node)
              (let
                [binding : i64
                  (binding_index.get-value-or
                    (& data.persistent-bindings)
                    (tuple store node)
                    -1)]
                (when
                  (>= binding 0)
                  (in-arena
                    data.owner
                    (slot_index.insert-ref!
                      (&mut data.slot-bindings)
                      (tuple epoch slot generation)
                      binding)
                    (compiler-semantic-fact-recorder-data-set! recorder data))))]
            [(tc.TcSemanticEvent.PersistentReference store node)
              (when
                (> data.frame-count 0)
                (set!
                  (array-ref data.frames (- data.frame-count 1)).reference-binding
                  (binding_index.get-value-or
                    (& data.persistent-bindings)
                    (tuple store node)
                    -1)))]
            [(tc.TcSemanticEvent.SpmdEnter)
              (in-arena
                data.owner
                (when
                  (>= data.spmd-depth (array-length data.spmd-functions))
                  (__tl_array-push! data.spmd-functions -1))
                (set!
                  (array-ref data.spmd-functions data.spmd-depth)
                  data.current-function)
                (set! data.spmd-depth (+ data.spmd-depth 1))
                (compiler-semantic-fact-recorder-data-set! recorder data))]
            [(tc.TcSemanticEvent.SpmdLeave)
              (when
                (> data.spmd-depth 0)
                (set! data.spmd-depth (- data.spmd-depth 1))
                (compiler-semantic-fact-recorder-data-set! recorder data))]
            [(tc.TcSemanticEvent.ScopeEnter scope)
              (set! data.current-scope scope)
              (compiler-semantic-fact-recorder-data-set! recorder data)]
            [(tc.TcSemanticEvent.ScopeLeave)
              (set!
                data.current-scope
                (if (> data.frame-count 0)
                  (array-ref data.frames (- data.frame-count 1)).scope
                  -1))
              (compiler-semantic-fact-recorder-data-set! recorder data)]
            [(tc.TcSemanticEvent.Reference key global)
              (when
                (> data.frame-count 0)
                (set!
                  (array-ref data.frames (- data.frame-count 1)).reference-key
                  key)
                (set!
                  (array-ref data.frames (- data.frame-count 1)).global-reference
                  global))]
            [(tc.TcSemanticEvent.ResolvedMember handle)
              (when
                (> data.frame-count 0)
                (set!
                  (array-ref data.frames (- data.frame-count 1)).member-handle
                  handle))]
            [(tc.TcSemanticEvent.ExpansionEnter path name span)
              (in-arena
                data.owner
                (when
                  (>= data.expansion-depth (array-length data.expansions))
                  (__tl_array-push!
                    data.expansions
                    (CompilerSemanticFactFrame
                      -1
                      -1
                      -1
                      false
                      CompilerSemanticFactProvenance.Unknown
                      ""
                      -1
                      -1
                      false
                      -1
                      (ast.ast-decl-span-fallback))))
                (set!
                  (array-ref data.expansions data.expansion-depth)
                  (CompilerSemanticFactFrame
                    -1
                    -1
                    -1
                    false
                    (if (>= name 0)
                      CompilerSemanticFactProvenance.Synthetic
                      (if (and (>= path 0) (> span.start-line 0))
                        CompilerSemanticFactProvenance.MacroArgument
                        CompilerSemanticFactProvenance.Unknown))
                    (if (>= path 0)
                      (string.copy (ci.intern-str path))
                      (string.copy (& data.current-path)))
                    -1
                    -1
                    false
                    -1
                    (ast.ast-decl-span-fallback)))
                (set! data.expansion-depth (+ data.expansion-depth 1))
                (compiler-semantic-fact-recorder-data-set! recorder data))]
            [(tc.TcSemanticEvent.ExpansionLeave)
              (when
                (> data.expansion-depth 0)
                (set! data.expansion-depth (- data.expansion-depth 1))
                (compiler-semantic-fact-recorder-data-set! recorder data))]
            [(tc.TcSemanticEvent.ExpressionEnter expression)
              (compiler-semantic-fact-recorder-enter! recorder ctx expression)]
            [(tc.TcSemanticEvent.Expression expression result dependent)
              (compiler-semantic-fact-recorder-expression!
                recorder
                ctx
                env
                expression
                result
                dependent)]
            [(tc.TcSemanticEvent.Declaration _ _ _ _) unit]
            [(tc.TcSemanticEvent.FunctionEnter name body _ ret)
              (compiler-semantic-fact-recorder-function-enter!
                recorder
                ctx
                name
                body
                ret)]
            [(tc.TcSemanticEvent.FunctionLeave result)
              (compiler-semantic-fact-recorder-function-leave!
                recorder
                ctx
                result)]
            [(tc.TcSemanticEvent.Binding epoch slot generation name _ _)
              (compiler-semantic-fact-recorder-binding!
                recorder
                ctx
                epoch
                slot
                generation
                name)
              (when
                (> data.frame-count 0)
                (set!
                  (array-ref data.frames (- data.frame-count 1)).binding-site
                  (ast.ast-decl-span-fallback)))]))])))

(define (compiler-semantic-fact-recorder-observer
  [recorder : CompilerSemanticFactRecorder]) : tc.TcSemanticObserver
  (tc.tc-semantic-observer-new
    recorder.address
    compiler-semantic-fact-recorder-observe!))

(define (compiler-semantic-fact-recorder-finish!
  [recorder : CompilerSemanticFactRecorder]) : CompilerSemanticFacts
  (let
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    (compiler-semantic-fact-complete-identities! (&mut data))
    (set! data.sealed true)
    ;; Parser identities are only recording scratch. The published records
    ;; contain owned spellings and spans, never these generation-bound ids.
    (set! data.origins (__tl_make-array parser.CompilerParseSemanticOrigin 0))
    (set! data.origin-used (__tl_make-array bool 0))
    (compiler-semantic-fact-recorder-data-set!
      recorder
      (owned_view.compiler-owned-shared-view data))
    (CompilerSemanticFacts recorder.address)))

(define (compiler-semantic-fact-complete-identity
  [data : (& data CompilerSemanticFactRecorderData)]
  [identity : CompilerSemanticFactIdentity]) : CompilerSemanticFactIdentity
  (let
    [index : i64
      (fact_index.get-value-or
        (& data.declaration-origin-index)
        identity.handle
        -1)]
    (if (and (>= index 0) (< index (array-length data.declaration-origins)))
      (clone (array-ref data.declaration-origins index))
      identity)))

(define (compiler-semantic-fact-complete-identities!
  [data : (&mut data CompilerSemanticFactRecorderData)]) : unit
  (let
    [i : i64 0]
    (in-arena
      data.owner
      (while (< i data.facts.expression-count)
        (let
          [fact : CompilerSemanticExpressionFact
            (owned_view.compiler-owned-array-element-shared-view
              data.facts.expressions
              i)]
          (set!
            fact.resolved-value
            (compiler-semantic-fact-complete-identity
              (& data)
              fact.resolved-value))
          (set!
            fact.resolved-type.nominal
            (compiler-semantic-fact-complete-identity
              (& data)
              fact.resolved-type.nominal))
          (set! (array-ref data.facts.expressions i) fact)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i data.facts.function-count)
        (let
          [function : CompilerSemanticFactFunction
            (owned_view.compiler-owned-array-element-shared-view
              data.facts.functions
              i)]
          (set!
            function.identity
            (compiler-semantic-fact-complete-identity
              (& data)
              function.identity))
          (set!
            function.return-type.nominal
            (compiler-semantic-fact-complete-identity
              (& data)
              function.return-type.nominal))
          (set! (array-ref data.facts.functions i) function)
          (set! i (+ i 1)))))))

(define (compiler-semantic-fact-type
  [ctx : tc.TcContext]
  [ty : ast.AstType]
  [path : String]) : CompilerSemanticFactType
  (let
    [resolved : ast.AstType ty]
    [name : i64
      (compiler-semantic-fact-direct-nominal-name
        (owned_view.compiler-owned-shared-view resolved))]
    [identity : CompilerSemanticFactIdentity
      (if (>= name 0)
        (compiler-semantic-fact-handle-identity
          ctx
          (tc.tc-resolve-type-name-symbol-lookup-id
            (tc.tc-job-state-nominal-cache (tc.tc-context-job-state ctx))
            (tc.tc-context-symbols ctx)
            (ast.ast-nominal-name-id-key name))
          path)
        (compiler-semantic-fact-identity-empty))]
    (CompilerSemanticFactType (tc.tc-type-render resolved) identity)))

(define (compiler-semantic-fact-recorder-expression!
  [recorder : CompilerSemanticFactRecorder]
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]
  [expression : i64]
  [result : tc.ResultTcType]
  [dependent : bool]) : unit
  (let
    [data : CompilerSemanticFactRecorderData
      (compiler-semantic-fact-recorder-data recorder)]
    [span : ast.AstSourceSpan
      (match (tc.tc-expr-id-maybe-span
        (tc.tc-context-expr-bases ctx)
        expression)
        [(tc.TcMaybeAstSourceSpan.Some source) source]
        [(tc.TcMaybeAstSourceSpan.No) (ast.ast-source-span 0 0 0 0)])]
    [ty : CompilerSemanticFactType
      (match (owned_view.compiler-owned-shared-view result)
        [(tc.ResultTcType.Ok resolved)
          (if (tc.tc-poison-type?
            (owned_view.compiler-owned-shared-view resolved))
            (compiler-semantic-fact-type-empty)
            (compiler-semantic-fact-type
              ctx
              resolved
              (owned_view.compiler-owned-shared-view data.current-path)))]
        [(tc.ResultTcType.Err _) (compiler-semantic-fact-type-empty)])]
    [reliability : CompilerSemanticFactReliability
      (match result
        [(tc.ResultTcType.Err _)
          (if dependent
            CompilerSemanticFactReliability.Dependent
            CompilerSemanticFactReliability.Unresolved)]
        [(tc.ResultTcType.Ok resolved)
          (cond
            [(tc.tc-poison-type? resolved)
              CompilerSemanticFactReliability.Poisoned]
            [dependent CompilerSemanticFactReliability.Dependent]
            [else CompilerSemanticFactReliability.Reliable])])]
    [value : CompilerSemanticFactIdentity
      (if (>= data.frame-count 1)
        (compiler-semantic-fact-expression-identity recorder ctx env expression)
        (compiler-semantic-fact-identity-empty))]
    [frame : CompilerSemanticFactFrame
      (if (> data.frame-count 0)
        (owned_view.compiler-owned-array-element-shared-view
          data.frames
          (- data.frame-count 1))
        (CompilerSemanticFactFrame
          expression
          data.current-function
          data.current-scope
          false
          CompilerSemanticFactProvenance.Unknown
          ""
          -1
          -1
          false
          -1
          (ast.ast-decl-span-fallback)))]
    [pools : ast.AstNodePoolContext (tc.tc-context-pools ctx)]
    [source-owner : i64
      (ast.ast-node-pool-context-expr-source-owner (& pools) expression)]
    [provenance : CompilerSemanticFactProvenance
      (if (> span.start-line 0)
        frame.provenance
        (match frame.provenance
          [(CompilerSemanticFactProvenance.Synthetic)
            CompilerSemanticFactProvenance.Synthetic]
          [_ CompilerSemanticFactProvenance.Unknown]))]
    [try-fact : CompilerSemanticTryFact
      (compiler-semantic-fact-try-query ctx env expression frame.forbidden)]
    (in-arena
      data.owner
      (let
        [fact : CompilerSemanticExpressionFact
          (CompilerSemanticExpressionFact
            expression
            (clone ty)
            (clone value)
            frame.function
            frame.scope
            (string.copy (& frame.path))
            span
            provenance
            reliability
            (and (>= frame.function 0) (not frame.forbidden))
            (clone try-fact))]
        (compiler-semantic-fact-recorder-store!
          recorder
          (owned_view.compiler-owned-shared-view fact))
        (when
          (and (>= source-owner 0) (!= source-owner expression))
          (set! fact.expression source-owner)
          (compiler-semantic-fact-recorder-store! recorder fact)))
      (let
        [ready : CompilerSemanticFactRecorderData
          (compiler-semantic-fact-recorder-data recorder)]
        (when
          (> ready.frame-count 0)
          (set! ready.frame-count (- ready.frame-count 1)))
        (set!
          ready.current-scope
          (if (> ready.frame-count 0)
            (array-ref ready.frames (- ready.frame-count 1)).scope
            (if (>= ready.current-function 0)
              (array-ref ready.facts.functions ready.current-function).body
              -1)))
        (compiler-semantic-fact-recorder-data-set! recorder ready)))))

;; The collector is opt-in at the import boundary as well as at runtime. The
;; ordinary CLI imports the checked pipeline without loading these records.
(defstruct CompilerSemanticCheckRequest
  (input check.CompilerSemanticCheckInput)
  (stdlib-roots svec.Vec)
  (cfgs sym_i64_env.SymI64Env)
  (job-state tc.TcJobState)
  (facts-arena arena.Arena)
  (checked-generated-source bool)
  (consumer-context i64)
  (consumer (-> i64 (& facts CompilerSemanticFacts) unit)))

(defstruct CompilerSemanticConsumerHandoff
  (recorder CompilerSemanticFactRecorder)
  (facts-arena arena.Arena)
  (context i64)
  (consumer (-> i64 (& facts CompilerSemanticFacts) unit)))

(define (compiler-semantic-consumer-handoff [context : i64]) : unit
  (let
    [handoff : CompilerSemanticConsumerHandoff
      (unsafe
        (ptr-read
          (int->ptr
            (cast context : u64)
            : (Ptr CompilerSemanticConsumerHandoff))))]
    [facts : CompilerSemanticFacts
      (in-arena
        handoff.facts-arena
        (compiler-semantic-fact-recorder-finish! handoff.recorder))]
    (handoff.consumer handoff.context (& facts))))

(define (compiler-check-semantic-request
  [request : CompilerSemanticCheckRequest]) : check.ResultCompilerCheck
  (let
    [entry-path : String
      (match (owned_view.compiler-owned-shared-view request.input)
        [(check.CompilerSemanticCheckInput.Source path _) path]
        [(check.CompilerSemanticCheckInput.File path) path]
        [(check.CompilerSemanticCheckInput.PackageEntry path _ _ _) path])]
    [recorder : CompilerSemanticFactRecorder
      (in-arena
        request.facts-arena
        (compiler-semantic-fact-recorder-new
          (clone entry-path)
          request.checked-generated-source))]
    [observer : tc.TcSemanticObserver
      (in-arena
        request.facts-arena
        (compiler-semantic-fact-recorder-observer recorder))]
    [handoff : (__tl_dyn-array CompilerSemanticConsumerHandoff)
      (in-arena
        request.facts-arena
        (__tl_make-array
          (CompilerSemanticConsumerHandoff
            recorder
            request.facts-arena
            request.consumer-context
            request.consumer)))]
    (check.compiler-check-observed-request
      (check.CompilerObservedCheckRequest
        request.input
        request.stdlib-roots
        request.cfgs
        request.job-state
        observer
        (unsafe
          (cast (ptr->int (__tl_array-data handoff)) : i64))
        compiler-semantic-consumer-handoff))))