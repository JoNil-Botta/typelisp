;; compiler_ctfe.tl - Selfhost compile-time function evaluation (CTFE) for
;; expression-position `(comptime expr)`.
;;
;; Supported compile-time value types are i64, f64/f32, bool, char, unit, type
;; values, and Expr / list aggregates.
;;
;; Evaluation threads persistent environment snapshots through recursion, and
;; the step budget ("fuel") through results, so the evaluator stays
;; deterministic without a mutable fuel counter.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as ctfe_key_map)
(import stdlib.arena)
(import stdlib.byte_buf_core)
(import compiler_ast_types as ast)
(import compiler_comptime_diagnostics_core as comptime_diagnostics)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_diagnostic as cdiag)
(import compiler_float as cfloat)
(import stdlib.string)
(import stdlib.result)
(import compiler_owned_view as owned_view)

(define (ctfe-builtin-reset!) : unit
  unit)

(defstruct CompilerCtfeMacroStateData
  (result-hygiene-free-node i64)
  (result-may-contain-macro bool)
  (visible-macro-name-set ctfe_key_map.Map)
  (module-macro-export-keys ctfe_key_map.Map)
  (module-value-type-ids ctfe_key_map.Map)
  (module-value-reflection-enabled bool)
  (source-names ci.InternSourceNameSessionHandle)
  ;; Hash-table backing arrays outlive per-file scratch arenas. Growth switches
  ;; to this owning compiler-job arena before publishing a replacement array.
  (map-storage-arena i64))

(defstruct CompilerCtfeMacroState
  (address i64))

(define (compiler-ctfe-macro-state-new) : CompilerCtfeMacroState
  (let
    [cell : (__tl_dyn-array CompilerCtfeMacroStateData)
      (__tl_make-array CompilerCtfeMacroStateData 1)]
    (begin
      (set!
        (array-ref cell 0)
        (CompilerCtfeMacroStateData
          -1
          false
          (ctfe_key_map.with-capacity 1)
          (ctfe_key_map.with-capacity 1)
          (ctfe_key_map.with-capacity 1)
          false
          (ci.InternSourceNameSessionHandle 0)
          (arena.tl_arena_current)))
      (CompilerCtfeMacroState
        (cast
          (unsafe
            (ptr->int
              (ptr-cast
                (__tl_array-data cell)
                : (Ptr CompilerCtfeMacroStateData))))
          : i64)))))

(define (compiler-ctfe-macro-state-ptr [state : CompilerCtfeMacroState]) : (MutPtr
    CompilerCtfeMacroStateData)
  (unsafe
    (int->ptr (cast state.address : u64) : (MutPtr CompilerCtfeMacroStateData))))

(define (compiler-ctfe-macro-state-view [state : CompilerCtfeMacroState]) : (Ptr
    CompilerCtfeMacroStateData)
  (unsafe
    (int->ptr (cast state.address : u64) : (Ptr CompilerCtfeMacroStateData))))

(define (compiler-ctfe-macro-state-data [state : CompilerCtfeMacroState]) : CompilerCtfeMacroStateData
  (unsafe
    (ptr-read
      (int->ptr (cast state.address : u64) : (Ptr CompilerCtfeMacroStateData)))))

(define (compiler-ctfe-macro-state-data-set!
  [state : CompilerCtfeMacroState]
  [data : CompilerCtfeMacroStateData]) : unit
  (unsafe
    (ptr-write!
      (int->ptr
        (cast state.address : u64)
        : (MutPtr CompilerCtfeMacroStateData))
      data)))

(define (compiler-ctfe-macro-state-bind-source-names!
  [state : CompilerCtfeMacroState]
  [source-names : ci.InternSourceNameSessionHandle]) : unit
  (unsafe
    (set!
      (deref (compiler-ctfe-macro-state-ptr state)).source-names
      source-names)))

(define (compiler-ctfe-macro-state-structural-session
  [state : CompilerCtfeMacroState]) : cis.InternStructuralSessionHandle
  (cis.intern-structural-session-handle-from-source-names
    (unsafe
      (deref (compiler-ctfe-macro-state-view state)).source-names)))

(define (compiler-ctfe-key-map-grow-for-state-if-needed!
  [state : CompilerCtfeMacroState]
  [map : (&mut map ctfe_key_map.Map)]) : unit
  (if (ctfe_key_map.needs-grow? map)
    (in-arena
      (arena.Arena
        (unsafe
          (deref (compiler-ctfe-macro-state-view state)).map-storage-arena))
      (ctfe_key_map.grow! map))
    unit))

;; Standalone APIs and direct CTFE tests are serial compatibility surfaces.
;; Production compiler jobs pass their own explicit state through CtfeEnv.
(define compiler-ctfe-serial-macro-state-address : i64
  (__tl-project-field (compiler-ctfe-macro-state-new) address))

(define (compiler-ctfe-serial-macro-state) : CompilerCtfeMacroState
  (CompilerCtfeMacroState compiler-ctfe-serial-macro-state-address))

;; A generic syntax intrinsic can prove that its result contains only captured
;; caller expressions plus hygiene-inert syntax. Publish that exact root to the
;; expression-macro handoff so it can reuse the tree instead of cloning it.
(define (ctfe-result-hygiene-free-reset-for-state!
  [state : CompilerCtfeMacroState]) : unit
  (unsafe
    (set!
      (deref (compiler-ctfe-macro-state-ptr state)).result-hygiene-free-node
      -1)))

(define (ctfe-result-hygiene-free-note-for-state!
  [state : CompilerCtfeMacroState]
  [node : i64]) : unit
  (unsafe
    (set!
      (deref (compiler-ctfe-macro-state-ptr state)).result-hygiene-free-node
      node)))

(define (ctfe-result-hygiene-free-node-id-for-state
  [state : CompilerCtfeMacroState]) : i64
  (unsafe
    (deref (compiler-ctfe-macro-state-view state)).result-hygiene-free-node))

(define (ctfe-result-hygiene-free-reset!) : unit
  (ctfe-result-hygiene-free-reset-for-state! (compiler-ctfe-serial-macro-state)))

(define (ctfe-result-hygiene-free-node-id) : i64
  (ctfe-result-hygiene-free-node-id-for-state
    (compiler-ctfe-serial-macro-state)))

;; Transformer construction records only the event that can make an otherwise
;; expanded syntax value need another macro walk: creating a call whose callee
;; base name is visible as a macro at this splice point. The flag is monotonic
;; for one transformer evaluation. Captured operands have already completed
;; their own fixpoint walk before binding; every newly created call flows
;; through the helpers below.
(define (ctfe-visible-macro-names-reset-for-state!
  [state : CompilerCtfeMacroState]) : unit
  (let
    [data : CompilerCtfeMacroStateData (compiler-ctfe-macro-state-data state)]
    (begin
      (in-arena
        (arena.Arena data.map-storage-arena)
        (if (< (ctfe_key_map.capacity (& data.visible-macro-name-set)) 128)
          (set! data.visible-macro-name-set (ctfe_key_map.with-capacity 128))
          (ctfe_key_map.clear-ref! (&mut data.visible-macro-name-set))))
      (compiler-ctfe-macro-state-data-set! state data))))

(define (ctfe-visible-macro-name-add-for-state!
  [state : CompilerCtfeMacroState]
  [name-id : i64]) : unit
  (let
    [data : CompilerCtfeMacroStateData (compiler-ctfe-macro-state-data state)]
    (begin
      (compiler-ctfe-key-map-grow-for-state-if-needed!
        state
        (&mut data.visible-macro-name-set))
      (ctfe_key_map.insert-ref! (&mut data.visible-macro-name-set) name-id 1)
      (compiler-ctfe-macro-state-data-set! state data))))

(define (ctfe-result-macro-provenance-reset-for-state!
  [state : CompilerCtfeMacroState]) : unit
  (unsafe
    (set!
      (deref (compiler-ctfe-macro-state-ptr state)).result-may-contain-macro
      false)))

(define (ctfe-result-may-contain-macro-note-for-state!
  [state : CompilerCtfeMacroState]) : unit
  (unsafe
    (set!
      (deref (compiler-ctfe-macro-state-ptr state)).result-may-contain-macro
      true)))

(define (ctfe-result-may-contain-macro-for-state?
  [state : CompilerCtfeMacroState]) : bool
  (unsafe
    (deref (compiler-ctfe-macro-state-view state)).result-may-contain-macro))

(define (ctfe-visible-macro-names-reset!) : unit
  (ctfe-visible-macro-names-reset-for-state! (compiler-ctfe-serial-macro-state)))

(define (ctfe-visible-macro-name-add! [name-id : i64]) : unit
  (ctfe-visible-macro-name-add-for-state!
    (compiler-ctfe-serial-macro-state)
    name-id))

(define (ctfe-result-macro-provenance-reset!) : unit
  (ctfe-result-macro-provenance-reset-for-state!
    (compiler-ctfe-serial-macro-state)))

(define (ctfe-result-may-contain-macro?) : bool
  (ctfe-result-may-contain-macro-for-state? (compiler-ctfe-serial-macro-state)))

(define (ctfe-macro-provenance-callee-base-name-id
  [session : cis.InternStructuralSessionHandle]
  [name-id : i64]) : i64
  (cond
    [(ci.intern-composite-triple-id? name-id)
      (ci.intern-composite-right-id-unchecked name-id)]
    [(ci.intern-composite-pair-id? name-id)
      (ci.intern-composite-right-id-unchecked name-id)]
    [else
      (let
        [source-id : i64
          (cis.intern-structural-session-syntax-source-name-id-or
            session
            name-id
            name-id)]
        [base-id : i64
          (if (and
            (ci.intern-renderable-id? source-id)
            (ci.intern-qualified? source-id))
            (ci.intern-qualified-base-id source-id)
            source-id)]
        (if (and (ci.intern-renderable-id? base-id) (ci.intern-dotted? base-id))
          (ci.intern-dotted-final-id base-id)
          base-id))]))

(define (ctfe-result-macro-provenance-call-head-with-pools?
  [state : CompilerCtfeMacroState]
  [pools : ast.AstNodePoolContext]
  [callee-node : i64]) : bool
  (match (ast.ast-expr-unspan-with-pools
    pools
    (ast.ast-node-pool-context-expr-get pools callee-node))
    [(ast.AstExpr.Var name-id)
      (let
        [base-id : i64
          (ctfe-macro-provenance-callee-base-name-id
            (compiler-ctfe-macro-state-structural-session state)
            name-id)]
        [data : CompilerCtfeMacroStateData
          (compiler-ctfe-macro-state-data state)]
        (or
          (ctfe_key_map.contains? (& data.visible-macro-name-set) base-id)
          (= base-id cbi.compiler-builtin-id-fix-when)
          (= base-id cbi.compiler-builtin-id-fix-unless)))]
    [_ false]))

(define (ctfe-result-macro-provenance-note-call-head-with-pools!
  [state : CompilerCtfeMacroState]
  [pools : ast.AstNodePoolContext]
  [callee-node : i64]) : unit
  (if (ctfe-result-macro-provenance-call-head-with-pools?
    state
    pools
    callee-node)
    (ctfe-result-may-contain-macro-note-for-state! state)
    unit))

(define (ctfe-ast-expr-call-with-provenance
  [state : CompilerCtfeMacroState]
  [pools : ast.AstNodePoolContext]
  [callee-node : i64]
  [args : ast.AstExprList]) : i64
  (let
    [node : i64 (ast.ast-expr-call-with-pools pools callee-node args)]
    (begin
      (ctfe-result-macro-provenance-note-call-head-with-pools!
        state
        pools
        callee-node)
      node)))

(define (ctfe-hygiene-inert-literal-node?
  [pools : ast.AstNodePoolContext]
  [node : i64]) : bool
  (match (ast.ast-expr-unspan-with-pools
    (& pools)
    (ast.ast-node-pool-context-expr-get (& pools) node))
    [(ast.AstExpr.Literal _) true]
    [_ false]))

;; Stable opaque key for String-only private metadata. It cannot change if a
;; genuinely generated identifier is materialized later in the compilation.
;; Qualified source and generated names can have different opaque ids while
;; carrying the same parser-assigned module/base identities. Metadata indexes
;; use that structural pair so both representations select the same entry.
(define (ctfe-qualified-name-key-id [module-id : i64] [base-id : i64]) : i64
  (ci.intern-composite-pair-id module-id base-id))

(define (ctfe-name-id-key [name-id : i64]) : i64
  (if (and (ci.intern-renderable-id? name-id) (ci.intern-qualified? name-id))
    (ctfe-qualified-name-key-id
      (ci.intern-qualified-module-id name-id)
      (ci.intern-qualified-base-id name-id))
    name-id))

;; Macro construction can deliberately create a spelling that did not occur in
;; the parsed source. Generated ids live outside the source-name hash table; the
;; structural key and spelling check make hash collisions explicit.
(define (ctfe-generated-name-first-dot [name : (& name str)]) : i64
  (let
    [index : i64 0]
    [len : i64 (string.string-length name)]
    [first-dot : i64 -1]
    (begin
      (while (and (< index len) (< first-dot 0))
        (begin
          (if (string.char-eq (string.string-ref name index) '.')
            (set! first-dot index)
            unit)
          (set! index (+ index 1))))
      first-dot)))

(define (ctfe-generated-name-last-dot [name : (& name str)]) : i64
  (let
    [index : i64 0]
    [len : i64 (string.string-length name)]
    [last-dot : i64 -1]
    (begin
      (while (< index len)
        (begin
          (if (string.char-eq (string.string-ref name index) '.')
            (set! last-dot index)
            unit)
          (set! index (+ index 1))))
      last-dot)))

(define (ctfe-generated-name-store [name : String]) : i64
  (let
    [first-dot : i64 (ctfe-generated-name-first-dot name)]
    (if (> first-dot 0)
      (let
        [name-len : i64 (string.string-length name)]
        [last-dot : i64 (ctfe-generated-name-last-dot name)]
        [tail-start : i64 (+ first-dot 1)]
        [leading-id : i64
          (ctfe-materialize-generated-name-id
            (string.substring name 0 first-dot))]
        [prefix-id : i64
          (if (= last-dot first-dot)
            leading-id
            (ctfe-materialize-generated-name-id
              (string.substring name 0 last-dot)))]
        [tail-id : i64
          (ctfe-materialize-generated-name-id
            (string.substring name tail-start (- name-len tail-start)))]
        (ci.intern-generated-canonical-dotted-name
          name
          leading-id
          prefix-id
          tail-id))
      (ci.intern-generated-canonical-name name))))

(define (ctfe-materialize-generated-name-id [name : String]) : i64
  (ctfe-generated-name-store name))

(define (ctfe-pat-binding-id [name-id : i64]) : ast.AstPattern
  (ast.ast-pat-binding-id name-id))

(define (ctfe-pat-variant-id [name-id : i64] [items : ast.AstPatternList]) : ast.AstPattern
  (ast.ast-pat-variant-id name-id items))

(define (ctfe-builtin-refresh!) : unit
  (cbi.compiler-builtin-refresh!))

(defmacro (ctfe-builtin [spelling : Expr]) : i64
  `(cbi.compiler-builtin-ctfe ,spelling))

;; Call dispatch and comptime-helper classification refresh the builtin table
;; once before consulting their ID predicates below. Those predicates stay
;; warm; predicates used from other contexts retain an explicit refresh.
(define (ctfe-builtin-id-any2? [name-id : i64] [a : i64] [b : i64]) : bool
  (or (= name-id a) (= name-id b)))

(define (ctfe-builtin-id-any3? [name-id : i64] [a : i64] [b : i64] [c : i64]) : bool
  (or (= name-id a) (ctfe-builtin-id-any2? name-id b c)))

(define (ctfe-builtin-id-any4?
  [name-id : i64]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]) : bool
  (or (= name-id a) (ctfe-builtin-id-any3? name-id b c d)))

(define (ctfe-builtin-size-align-id? [name-id : i64]) : bool
  (ctfe-builtin-id-any2?
    name-id
    (ctfe-builtin "size-of")
    (ctfe-builtin "align-of")))

(define (ctfe-builtin-offset-of-id? [name-id : i64]) : bool
  (= name-id (ctfe-builtin "offset-of")))

(define (ctfe-builtin-string-eq-id? [name-id : i64]) : bool
  (ctfe-builtin-id-any3?
    name-id
    (ctfe-builtin "__tl_string_eq")
    (ctfe-builtin "string-eq")
    (ctfe-builtin "string=?")))

(define (ctfe-builtin-string-length-id? [name-id : i64]) : bool
  (ctfe-builtin-id-any3?
    name-id
    (ctfe-builtin "__tl_string_length")
    (ctfe-builtin "string-length")
    (ctfe-builtin "length")))

(define (ctfe-builtin-string-ref-id? [name-id : i64]) : bool
  (ctfe-builtin-id-any3?
    name-id
    (ctfe-builtin "__tl_string_ref")
    (ctfe-builtin "string-ref")
    (ctfe-builtin "char-at")))

(define (ctfe-builtin-string-to-int-id? [name-id : i64]) : bool
  (ctfe-builtin-id-any2?
    name-id
    (ctfe-builtin "__tl_string_to_int")
    (ctfe-builtin ">int")))

(define (ctfe-builtin-string-build-id? [name-id : i64]) : bool
  (ctfe-builtin-id-any2?
    name-id
    (ctfe-builtin "string-append")
    (ctfe-builtin "string-concat")))

(define (ctfe-builtin-int-to-string-id? [name-id : i64]) : bool
  (= name-id (ctfe-builtin "int->string")))

(define (ctfe-builtin-comptime-error-id? [name-id : i64]) : bool
  (= name-id (ctfe-builtin "comptime-error")))

(define (ctfe-builtin-reflection-primary-id? [name-id : i64]) : bool
  (or
    (ctfe-builtin-id-any4?
      name-id
      (ctfe-builtin "type-info")
      (ctfe-builtin "type-kind")
      (ctfe-builtin "type-key")
      (ctfe-builtin "type-nominal-module"))
    (ctfe-builtin-id-any4?
      name-id
      (ctfe-builtin "type-nominal-name")
      (ctfe-builtin "struct-field-count")
      (ctfe-builtin "enum-variant-count")
      (ctfe-builtin "array-element-type"))
    (ctfe-builtin-id-any4?
      name-id
      (ctfe-builtin "array-length")
      (ctfe-builtin "array-dynamic?")
      (ctfe-builtin "tuple-element-count")
      (ctfe-builtin "function-param-count"))
    (= name-id (ctfe-builtin "function-return-type"))
    (= name-id (ctfe-builtin "box-element-type"))
    (= name-id (ctfe-builtin "reference-element-type"))
    (= name-id (ctfe-builtin "type-expr"))
    (ctfe-builtin-id-any3?
      name-id
      (ctfe-builtin "type-cleanup-owning?")
      (ctfe-builtin "type-cleanup-function")
      (ctfe-builtin "type-declared-align"))))

(define (ctfe-builtin-reflection-secondary-id? [name-id : i64]) : bool
  (or
    (ctfe-builtin-id-any4?
      name-id
      (ctfe-builtin "struct-field-name")
      (ctfe-builtin "struct-field-type")
      (ctfe-builtin "enum-variant-name")
      (ctfe-builtin "enum-variant-payload-count"))
    (ctfe-builtin-id-any4?
      name-id
      (ctfe-builtin "enum-variant-payload-type")
      (ctfe-builtin "tuple-element-type")
      (ctfe-builtin "function-param-type")
      (ctfe-builtin "struct-field-declared-align"))))

(define (ctfe-builtin-reflection-id? [name-id : i64]) : bool
  (or
    (ctfe-builtin-reflection-primary-id? name-id)
    (ctfe-builtin-reflection-secondary-id? name-id)))

(define (ctfe-builtin-module-value-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (ctfe-builtin-id-any2?
      name-id
      (ctfe-builtin "module-value?")
      (ctfe-builtin "module-value-type"))))

(define (ctfe-builtin-direct-inspector-id? [name-id : i64]) : bool
  (or
    (ctfe-builtin-id-any4?
      name-id
      (ctfe-builtin "expr-bool?")
      (ctfe-builtin "expr-bool-value")
      (ctfe-builtin "expr-if?")
      (ctfe-builtin "expr-if-cond"))
    (ctfe-builtin-id-any4?
      name-id
      (ctfe-builtin "expr-if-then")
      (ctfe-builtin "expr-if-else")
      (ctfe-builtin "expr-clause-first")
      (ctfe-builtin "expr-clause-second"))))

(define (ctfe-builtin-sequence-length-id? [name-id : i64]) : bool
  (ctfe-builtin-id-any3?
    name-id
    (ctfe-builtin "expr-list-length")
    (ctfe-builtin "expr-clause-list-length")
    (ctfe-builtin "expr-binding-clause-list-length")))

(define (ctfe-builtin-sequence-nth-id? [name-id : i64]) : bool
  (ctfe-builtin-id-any3?
    name-id
    (ctfe-builtin "expr-list-nth")
    (ctfe-builtin "expr-clause-list-nth")
    (ctfe-builtin "expr-binding-clause-list-nth")))

(define (ctfe-builtin-expr-clause-list-inspector-id? [name-id : i64]) : bool
  (= name-id (ctfe-builtin "expr-clause-list->expr-list")))

(define (ctfe-builtin-expr-binding-clause-list-inspector-id? [name-id : i64]) : bool
  (= name-id (ctfe-builtin "expr-binding-clause-list->expr-list")))

(define (ctfe-builtin-expr-binding-clause-inspector-id? [name-id : i64]) : bool
  (ctfe-builtin-id-any4?
    name-id
    (ctfe-builtin "expr-binding-clause-name")
    (ctfe-builtin "expr-binding-clause-has-type?")
    (ctfe-builtin "expr-binding-clause-type")
    (ctfe-builtin "expr-binding-clause-init")))

(define (ctfe-builtin-inspector-id? [name-id : i64]) : bool
  (or
    (ctfe-builtin-direct-inspector-id? name-id)
    (ctfe-builtin-sequence-length-id? name-id)
    (ctfe-builtin-sequence-nth-id? name-id)
    (ctfe-builtin-expr-binding-clause-inspector-id? name-id)))

(define (ctfe-comptime-syntax-helper-id? [name-id : i64]) : bool
  (begin
    (ctfe-builtin-refresh!)
    (or
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin "string-append")
        (ctfe-builtin "string-concat")
        (ctfe-builtin "int->string")
        (ctfe-builtin "comptime-error"))
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin "expr-bool")
        (ctfe-builtin "expr-int")
        (ctfe-builtin "expr-string")
        (ctfe-builtin "expr-var"))
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin "expr-struct-get")
        (ctfe-builtin "expr-tuple-ref")
        (ctfe-builtin "expr-struct-set")
        (ctfe-builtin "expr-splice"))
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin "expr-if")
        (ctfe-builtin "pattern-wildcard")
        (ctfe-builtin "pattern-binding")
        (ctfe-builtin "pattern-variant"))
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin "pattern-list-empty")
        (ctfe-builtin "pattern-list-cons")
        (ctfe-builtin "match-arm")
        (ctfe-builtin "match-arm-list-empty"))
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin "match-arm-list-cons")
        (ctfe-builtin "expr-match")
        (ctfe-builtin "expr-type")
        (ctfe-builtin "type-info"))
      (ctfe-builtin-id-any4?
        name-id
        (ctfe-builtin "module-name")
        (ctfe-builtin "module-export-macro?")
        (ctfe-builtin "module-hook")
        (ctfe-builtin "pattern-list-bindings"))
      (ctfe-builtin-id-any2?
        name-id
        (ctfe-builtin "pattern-binding-typed")
        (ctfe-builtin "expr-resource-scope"))
      (ctfe-builtin-id-any2?
        name-id
        (ctfe-builtin "expr-let-scope")
        (ctfe-builtin "expr-set-var"))
      (ctfe-builtin-id-any3?
        name-id
        (ctfe-builtin "expr-begin-unit")
        (ctfe-builtin "expr-not")
        (ctfe-builtin "expr-while"))
      (= name-id (ctfe-builtin "syntax-name-fresh"))
      (= name-id (ctfe-builtin "type-expr"))
      (ctfe-builtin-id-any3?
        name-id
        (ctfe-builtin "expr-borrow")
        (ctfe-builtin "expr-array-ref")
        (ctfe-builtin "expr-replace"))
      (ctfe-builtin-inspector-id? name-id)
      (ctfe-builtin-expr-clause-list-inspector-id? name-id)
      (ctfe-builtin-expr-binding-clause-list-inspector-id? name-id))))

(defmacro (ctfe-private-string-length [text : Expr]) : i64
  `(__tl_string_length ,text))

(defmacro (ctfe-private-string-ref [text : Expr] [index : Expr]) : char
  `(__tl_string_ref ,text ,index))

;; A compile-time value. Scalars; Expr / ExprList aggregates
;; for macro transformers; TypeInfo pseudo-values back the
;; stdlib-owned reflection surface.
(defenum CompilerCtfeValue
  (I64 i64)
  (F64 f64)
  (F32 f64)
  (Bool bool)
  (Char char)
  ;; String values keep the identity assigned when their text entered CTFE.
  ;; Parsed literals retain their source ID; computed values receive a
  ;; generated-domain ID at the operation that creates them.
  (String String i64)
  ;; Identifier text produced by syntax inspection retains the parser or
  ;; generated identity of that syntax node. String operations intentionally
  ;; return String because their result is newly computed text.
  (Name String i64)
  (Unit)
  (Type ast.AstType)
  ;; A user-facing `Expr` code fragment plus its internally checked produced
  ;; type. The type is not part of the source-level Expr type.
  (Expr i64 ast.AstType)
  ;; Macro arguments can reside in a newer caller pool than the transformer's
  ;; definition body. Keep that ownership with syntax selected from a captured
  ;; variadic argument so CTFE builders never overwrite the caller's nodes.
  (CapturedExpr i64 ast.AstType ast.AstNodePoolContext)
  (ExprList ast.AstExprList)
  (CapturedExprList ast.AstExprList ast.AstNodePoolContext)
  (ExprClause ast.AstExprClause)
  (CapturedExprClause ast.AstExprClause ast.AstNodePoolContext)
  (ExprClauseList ast.AstExprClauseList)
  (CapturedExprClauseList ast.AstExprClauseList ast.AstNodePoolContext)
  (ExprBindingClause ast.AstExprBindingClause)
  (ExprBindingClauseList ast.AstExprBindingClauseList)
  (Pattern ast.AstPattern)
  (PatternList ast.AstPatternList)
  (MatchArm ast.AstMatchArm)
  (MatchArmList ast.AstMatchArmList)
  (LetBinding ast.AstLetBinding)
  (LetBindingList ast.AstLetBindingList)
  (TypeInfo ast.AstType)
  (TypeInfoBox ast.AstType)
  (TypeInfoList ast.AstTypeList)
  (TypeField String ast.AstType)
  (TypeFieldList CtfeReflectFieldList)
  (TypeVariantPayload ast.AstType)
  (TypeVariantPayloadList ast.AstTypeList)
  (TypeVariant String ast.AstTypeList)
  (TypeVariantList CtfeReflectVariantList))

;; CTFE environments own copied values, but captured syntax pool contexts are
;; identity-bearing shared state cells. The compiler-generated aggregate clone
;; recursively clones those cells into the current macro arena, leaving
;; captured syntax pointed at storage destroyed with the generation. Keep
;; ordinary payload cloning while sharing only the captured pool owners.
(define (ctfe-value-owned-copy [value : (& value CompilerCtfeValue)]) : CompilerCtfeValue
  (match (owned_view.compiler-owned-reference-shared-view value)
    [(CompilerCtfeValue.I64 n) (CompilerCtfeValue.I64 n)]
    [(CompilerCtfeValue.F64 n) (CompilerCtfeValue.F64 n)]
    [(CompilerCtfeValue.F32 n) (CompilerCtfeValue.F32 n)]
    [(CompilerCtfeValue.Bool enabled) (CompilerCtfeValue.Bool enabled)]
    [(CompilerCtfeValue.Char ch) (CompilerCtfeValue.Char ch)]
    [(CompilerCtfeValue.String text identity)
      (CompilerCtfeValue.String (string.copy text) identity)]
    [(CompilerCtfeValue.Name text identity)
      (CompilerCtfeValue.Name (string.copy text) identity)]
    [(CompilerCtfeValue.Unit) CompilerCtfeValue.Unit]
    [(CompilerCtfeValue.Type ty) (CompilerCtfeValue.Type (clone ty))]
    [(CompilerCtfeValue.Expr node ty) (CompilerCtfeValue.Expr node (clone ty))]
    [(CompilerCtfeValue.CapturedExpr node ty pools)
      (CompilerCtfeValue.CapturedExpr node (clone ty) pools)]
    [(CompilerCtfeValue.ExprList items)
      (CompilerCtfeValue.ExprList (clone items))]
    [(CompilerCtfeValue.CapturedExprList items pools)
      (CompilerCtfeValue.CapturedExprList (clone items) pools)]
    [(CompilerCtfeValue.ExprClause clause)
      (CompilerCtfeValue.ExprClause (clone clause))]
    [(CompilerCtfeValue.CapturedExprClause clause pools)
      (CompilerCtfeValue.CapturedExprClause (clone clause) pools)]
    [(CompilerCtfeValue.ExprClauseList clauses)
      (CompilerCtfeValue.ExprClauseList (clone clauses))]
    [(CompilerCtfeValue.CapturedExprClauseList clauses pools)
      (CompilerCtfeValue.CapturedExprClauseList (clone clauses) pools)]
    [(CompilerCtfeValue.ExprBindingClause binding)
      (CompilerCtfeValue.ExprBindingClause (clone binding))]
    [(CompilerCtfeValue.ExprBindingClauseList bindings)
      (CompilerCtfeValue.ExprBindingClauseList (clone bindings))]
    [(CompilerCtfeValue.Pattern pattern)
      (CompilerCtfeValue.Pattern (clone pattern))]
    [(CompilerCtfeValue.PatternList patterns)
      (CompilerCtfeValue.PatternList (clone patterns))]
    [(CompilerCtfeValue.MatchArm arm) (CompilerCtfeValue.MatchArm (clone arm))]
    [(CompilerCtfeValue.MatchArmList arms)
      (CompilerCtfeValue.MatchArmList (clone arms))]
    [(CompilerCtfeValue.LetBinding binding)
      (CompilerCtfeValue.LetBinding (clone binding))]
    [(CompilerCtfeValue.LetBindingList bindings)
      (CompilerCtfeValue.LetBindingList (clone bindings))]
    [(CompilerCtfeValue.TypeInfo ty) (CompilerCtfeValue.TypeInfo (clone ty))]
    [(CompilerCtfeValue.TypeInfoBox ty)
      (CompilerCtfeValue.TypeInfoBox (clone ty))]
    [(CompilerCtfeValue.TypeInfoList types)
      (CompilerCtfeValue.TypeInfoList (clone types))]
    [(CompilerCtfeValue.TypeField name ty)
      (CompilerCtfeValue.TypeField (string.copy name) (clone ty))]
    [(CompilerCtfeValue.TypeFieldList fields)
      (CompilerCtfeValue.TypeFieldList (clone fields))]
    [(CompilerCtfeValue.TypeVariantPayload ty)
      (CompilerCtfeValue.TypeVariantPayload (clone ty))]
    [(CompilerCtfeValue.TypeVariantPayloadList types)
      (CompilerCtfeValue.TypeVariantPayloadList (clone types))]
    [(CompilerCtfeValue.TypeVariant name payloads)
      (CompilerCtfeValue.TypeVariant (string.copy name) (clone payloads))]
    [(CompilerCtfeValue.TypeVariantList variants)
      (CompilerCtfeValue.TypeVariantList (clone variants))]))

(define (ctfe-name-source-id-for-session
  [session : cis.InternStructuralSessionHandle]
  [name-id : i64]) : i64
  (cis.intern-structural-session-syntax-source-name-id-or session name-id -1))

(define (ctfe-name-text-for-session
  [session : cis.InternStructuralSessionHandle]
  [name-id : i64]) : String
  (let
    [source-id : i64 (ctfe-name-source-id-for-session session name-id)]
    (if (ci.intern-renderable-id? source-id)
      (ci.intern-str source-id)
      "<structural-name>")))

(define (ctfe-name-value-for-session
  [session : cis.InternStructuralSessionHandle]
  [name-id : i64]) : CompilerCtfeValue
  (CompilerCtfeValue.Name (ctfe-name-text-for-session session name-id) name-id))

(define (ctfe-name-value-for-source-names
  [source-names : ci.InternSourceNameSessionHandle]
  [name-id : i64]) : CompilerCtfeValue
  (ctfe-name-value-for-session
    (cis.intern-structural-session-handle-from-source-names source-names)
    name-id))

;; Standalone CTFE APIs and direct tests use the installed source-name owner.
;; Production evaluation passes its job-owned structural session explicitly.
(define (ctfe-name-value [name-id : i64]) : CompilerCtfeValue
  (ctfe-name-value-for-source-names
    (ci.intern-source-name-session-capture-active-handle)
    name-id))

(define (ctfe-generated-string-value [text : String]) : CompilerCtfeValue
  (CompilerCtfeValue.String
    (string.copy text)
    (ctfe-materialize-generated-name-id text)))

(define (ctfe-source-string-value-for-session
  [session : cis.InternStructuralSessionHandle]
  [string-id : i64]) : CompilerCtfeValue
  ;; Syntax inspection can intentionally turn an identity-bearing Name into a
  ;; string literal. Preserve that identity while rendering its spelling
  ;; through the compile job's structural session instead of indexing the
  ;; ordinary intern pool with an opaque table handle.
  (CompilerCtfeValue.String
    (ctfe-name-text-for-session session string-id)
    string-id))

(define (ctfe-source-string-value-for-source-names
  [source-names : ci.InternSourceNameSessionHandle]
  [string-id : i64]) : CompilerCtfeValue
  (ctfe-source-string-value-for-session
    (cis.intern-structural-session-handle-from-source-names source-names)
    string-id))

(define (ctfe-source-string-value [string-id : i64]) : CompilerCtfeValue
  (ctfe-source-string-value-for-source-names
    (ci.intern-source-name-session-capture-active-handle)
    string-id))

(cfg
  test
  (test
    ctfe-source-string-structural-identity
    (let
      [installed : ci.InternCompatState (ci.intern-compat-state-capture-active)]
      [intern-state : ci.InternCompatState (ci.intern-compat-state-new)]
      [source-name-id : i64
        (ci.intern-compat-state-intern
          (&mut intern-state)
          "ctfe-structural-string")]
      [_install : unit (ci.intern-compat-state-install! intern-state)]
      [source-names : ci.InternSourceNameSessionHandle
        (ci.intern-source-name-session-handle-from-state (& intern-state))]
      [session : cis.InternStructuralSessionHandle
        (cis.intern-structural-session-handle-from-source-names source-names)]
      [string-id : i64
        (cis.intern-macro-global-identity-raw
          (cis.intern-structural-session-macro-global-identity
            session
            cis.InternMacroGlobalRole.Context
            source-name-id
            source-name-id))]
      [value : CompilerCtfeValue
        (ctfe-source-string-value-for-session session string-id)]
      [ok : bool
        (match value
          [(CompilerCtfeValue.String text identity)
            (and
              (string.eq text "ctfe-structural-string")
              (= identity string-id))]
          [_ false])]
      (begin
        (ci.intern-compat-state-install! installed)
        (if ok
          unit
          (begin
            (/ 1 0)
            unit))))))

(define (ctfe-generated-leading-dot-suffix-id [suffix-id : i64]) : i64
  (let
    [suffix : String (ci.intern-str suffix-id)]
    ;; This helper also runs through the native comptime host table, whose
    ;; active intern table may differ from the compiler builtin cache (as in
    ;; the standalone ABI smoke). Resolve the empty anchor in that table.
    [empty-id : i64 (ci.intern "")]
    [prefix-id : i64
      (if (ci.intern-dotted? suffix-id)
        (ctfe-generated-leading-dot-suffix-id
          (ci.intern-dotted-prefix-id suffix-id))
        empty-id)]
    (ci.intern-generated-canonical-dotted-name
      (str_cat.str-cat "." suffix)
      empty-id
      prefix-id
      suffix-id)))

(define (ctfe-generated-dotted-append-member-id
  [prefix-id : i64]
  [member-id : i64]) : i64
  (let
    [prefix : String (ci.intern-str prefix-id)]
    [member : String (ci.intern-str member-id)]
    [tail-id : i64
      (if (ci.intern-dotted? prefix-id)
        (ctfe-generated-dotted-append-member-id
          (ci.intern-dotted-tail-id prefix-id)
          member-id)
        member-id)]
    (ci.intern-generated-canonical-dotted-name
      (str_cat.str-cat prefix "." member)
      (if (ci.intern-dotted? prefix-id)
        (ci.intern-leading-dot-id prefix-id)
        prefix-id)
      prefix-id
      tail-id)))

(define (ctfe-generated-dotted-append-suffix-id
  [prefix-id : i64]
  [suffix-id : i64]) : i64
  (if (ci.intern-dotted? suffix-id)
    (ctfe-generated-dotted-append-suffix-id
      (ctfe-generated-dotted-append-member-id
        prefix-id
        (ci.intern-leading-dot-id suffix-id))
      (ci.intern-dotted-tail-id suffix-id))
    (ctfe-generated-dotted-append-member-id prefix-id suffix-id)))

(define (ctfe-generated-string-append-value
  [left : String]
  [left-id : i64]
  [right : String]
  [right-id : i64]) : CompilerCtfeValue
  (let
    [text : String (str_cat.str-cat (string.copy left) (string.copy right))]
    [right-len : i64 (string.string-length right)]
    (cond
      [(and
          (= (string.string-length left) 1)
          (= (cast (string.string-ref left 0) : i64) 46)
          (> right-len 0)
          (ci.intern-renderable-id? right-id))
        (CompilerCtfeValue.String
          text
          (ctfe-generated-leading-dot-suffix-id right-id))]
      [(and
          (> (string.string-length left) 0)
          (> right-len 1)
          (= (cast (string.string-ref right 0) : i64) 46)
          (ci.intern-renderable-id? left-id)
          (not (= (ci.intern-first-dot left-id) 0))
          (ci.intern-renderable-id? right-id)
          (= (ci.intern-first-dot right-id) 0))
        (let
          [suffix-id : i64 (ci.intern-dotted-tail-id right-id)]
          (if (>= suffix-id 0)
            (CompilerCtfeValue.String
              text
              (ctfe-generated-dotted-append-suffix-id left-id suffix-id))
            (ctfe-generated-string-value text)))]
      [else (ctfe-generated-string-value text)])))

;; Public String-to-syntax constructors must resolve parsed names by spelling.
;; This is a read-only lookup at the language API boundary, not interning or an
;; internal generated-ID recovery path. Names absent from the parsed source keep
;; their generated identity.
(define (ctfe-string-syntax-name-id
  [source-names : ci.InternSourceNameSessionHandle]
  [text : String]
  [string-id : i64]) : i64
  (let
    [session : ci.InternSourceNameSession
      (ci.intern-source-name-session-handle-session source-names)]
    (match (ci.intern-source-name-session-resolve
      session
      (ci.intern-source-name-session-identity session string-id)
      text)
      [(ci.InternSourceNameResolution.ParsedIdentity source-id) source-id]
      [(ci.InternSourceNameResolution.GeneratedIdentity generated-id lookup)
        (match lookup
          [(ci.InternLookupFound source-id) source-id]
          [(ci.InternLookupMissing) generated-id])]
      [(ci.InternSourceNameResolution.WrongOwner) string-id]
      [(ci.InternSourceNameResolution.StaleGeneration) string-id]
      [(ci.InternSourceNameResolution.InvalidIdentity) string-id])))

(define (ctfe-untyped-expr-type-id) : i64
  -3)

(define (ctfe-untyped-expr-type) : ast.AstType
  (ast.AstType.Var (ctfe-untyped-expr-type-id)))

(define (ctfe-untyped-expr-type? [ty : (& ty ast.AstType)]) : bool
  (match ty
    [(ast.AstType.Var name) (= (deref name) (ctfe-untyped-expr-type-id))]
    [_ false]))

(define (ctfe-captured-expr-type-id) : i64
  -4)

;; Binding-clause syntax has no pool-bearing value variant of its own. Carry a
;; caller source-path identity beside its produced type until the initializer is
;; projected as an Expr; the projection can then allocate the diagnostic-only
;; origin marker in the transformer's installed syntax pool instead of placing
;; a foreign wrapper directly in the captured clause.
(define (ctfe-caller-origin-expr-type-id) : i64
  -5)

(define (ctfe-caller-origin-expr-type-path-id [ty : ast.AstType]) : i64
  (match ty
    [(ast.AstType.Region name provenance-id)
      (if (= name (ctfe-caller-origin-expr-type-id))
        (ci.intern-composite-left-id-unchecked provenance-id)
        -1)]
    [_ -1]))

(define (ctfe-caller-origin-expr-type-inner-with-pools
  [pools : ast.AstNodePoolContext]
  [ty : ast.AstType]) : ast.AstType
  (match (clone ty)
    [(ast.AstType.Region name provenance-id)
      (if (= name (ctfe-caller-origin-expr-type-id))
        (ast.ast-node-pool-context-type-get
          pools
          (ci.intern-composite-right-id-unchecked provenance-id))
        ty)]
    [_ ty]))

(define (ctfe-caller-origin-expr-node-with-pools
  [pools : ast.AstNodePoolContext]
  [node : i64]
  [ty : ast.AstType]) : i64
  (let
    [path-id : i64 (ctfe-caller-origin-expr-type-path-id ty)]
    (if (< path-id 0)
      node
      (match (ast.ast-node-pool-context-expr-get pools node)
        [(ast.AstExpr.Spanned inner span)
          (ast.ast-expr-spanned-with-pools
            pools
            (ast.ast-node-pool-context-expr-push
              pools
              (ast.AstExpr.MacroExpansion
                inner
                (ci.intern-composite-pair-id -1 path-id)
                -1))
            span)]
        [_ node]))))

(define (ctfe-captured-expr-type-with-pools
  [pools : ast.AstNodePoolContext]
  [ty : ast.AstType]) : ast.AstType
  (ast.AstType.Region
    (ctfe-captured-expr-type-id)
    (ast.ast-node-pool-context-type-push pools ty)))

(define (ctfe-captured-expr-type? [ty : ast.AstType]) : bool
  (match ty
    [(ast.AstType.Region name _) (= name (ctfe-captured-expr-type-id))]
    [_ false]))

(define (ctfe-captured-expr-type-inner-with-pools
  [pools : ast.AstNodePoolContext]
  [ty : ast.AstType]) : ast.AstType
  (let
    [inner : ast.AstType
      (ctfe-caller-origin-expr-type-inner-with-pools pools ty)]
    (match (clone inner)
      [(ast.AstType.Region name captured)
        (if (= name (ctfe-captured-expr-type-id))
          (ast.ast-node-pool-context-type-get pools captured)
          inner)]
      [_ inner])))

(define (ctfe-stdlib-comptime-type-id [name-id : i64]) : ast.AstType
  (ast.AstType.Var
    (ctfe-qualified-name-key-id
      cbi.compiler-builtin-id-fix-stdlib_dot_comptime
      name-id)))

(define (ctfe-type-info-source-type) : ast.AstType
  (ctfe-stdlib-comptime-type-id cbi.compiler-builtin-id-fix-TypeInfo))

(define (ctfe-type-info-box-source-type [pools : ast.AstNodePoolContext]) : ast.AstType
  (ast.ast-ty-box-with-pools pools (ctfe-type-info-source-type)))

(defstruct CtfeValueSeq
  (slots (__tl_dyn-array CompilerCtfeValue))
  (len i64))

(defenum CtfeMaybeSyntaxPools
  (None)
  (Some ast.AstNodePoolContext))

(define (ctfe-value-syntax-pools [value : CompilerCtfeValue]) : CtfeMaybeSyntaxPools
  (match value
    [(CompilerCtfeValue.CapturedExpr _ _ pools)
      (CtfeMaybeSyntaxPools.Some pools)]
    [(CompilerCtfeValue.CapturedExprList _ pools)
      (CtfeMaybeSyntaxPools.Some pools)]
    [(CompilerCtfeValue.CapturedExprClause _ pools)
      (CtfeMaybeSyntaxPools.Some pools)]
    [(CompilerCtfeValue.CapturedExprClauseList _ pools)
      (CtfeMaybeSyntaxPools.Some pools)]
    [_ (CtfeMaybeSyntaxPools.None)]))

;; Native transformer callbacks build syntax in an explicitly selected host
;; pool, but most callback results use the plain syntax variants. Attach that
;; ownership at the host boundary so the typechecker installs the right pool
;; before hygiene and rewalk. Preserve an already captured value's owner.
(define (ctfe-capture-syntax-value-with-pools
  [value : CompilerCtfeValue]
  [pools : ast.AstNodePoolContext]) : CompilerCtfeValue
  (match (ctfe-value-owned-copy (& value))
    [(CompilerCtfeValue.Expr node ty)
      (CompilerCtfeValue.CapturedExpr node ty pools)]
    [(CompilerCtfeValue.ExprList items)
      (CompilerCtfeValue.CapturedExprList items pools)]
    [(CompilerCtfeValue.ExprClause clause)
      (CompilerCtfeValue.CapturedExprClause clause pools)]
    [(CompilerCtfeValue.ExprClauseList clauses)
      (CompilerCtfeValue.CapturedExprClauseList clauses pools)]
    [_ value]))

;; CTFE-owned type layout metadata. The typechecker/lowerer build this from
;; their `TcContext` without making CTFE import typecheck.
;;
;; Storage disposition:
;; - CtfeLayoutFieldList, CtfeLayoutInfoList, CtfeReflectFieldList,
;;   CtfeReflectVariantList, and CtfeReflectInfoList are vector-backed
;;   generated-collection families. The historical `List` names are retained so
;;   callers do not need a public naming churn while the representation changes.
;; - CtfeEnv bindings occupy an indexed append-only arena. Snapshot handles keep
;;   a head index, and every binding keeps its parent index, preserving lexical
;;   shadowing and cheap push/pop without one heap object per binding.
;; - AST-owned lists such as AstExprList, AstTypeList, and AstParamList remain
;;   frontend data structures and are tracked separately.
(defenum CtfeLayoutField
  (Field String i64))

(defstruct CtfeLayoutFieldList
  (slots (__tl_dyn-array CtfeLayoutField))
  (key-ids (__tl_dyn-array i64))
  (len i64))

(defenum CtfeLayoutInfo
  (Info String bool i64 i64 CtfeLayoutFieldList))

(defstruct CtfeLayoutInfoList
  (slots (__tl_dyn-array CtfeLayoutInfo))
  (index ctfe_key_map.Map)
  (len i64))

(defenum CtfeMaybeLayoutInfo
  (None)
  (Some CtfeLayoutInfo))

(defenum CtfeMaybeFieldName
  (None)
  (Some i64))

;; CTFE-owned type reflection metadata. Typecheck and specialization build this
;; from `AstProgram` and pass it into CTFE without making CTFE import either pass.
(defenum CtfeReflectField
  (Field i64 ast.AstType))

(defstruct CtfeReflectFieldList
  (slots (__tl_dyn-array CtfeReflectField))
  (len i64))

(defenum CtfeReflectVariant
  (Variant i64 ast.AstTypeList))

(defstruct CtfeReflectVariantList
  (slots (__tl_dyn-array CtfeReflectVariant))
  (len i64))

(defenum CtfeReflectCleanup
  (No)
  (Fn String i64))

(defenum CtfeReflectInfo
  (Struct String String String i64 CtfeReflectCleanup CtfeReflectFieldList i64)
  (Enum String String String i64 CtfeReflectCleanup CtfeReflectVariantList i64))

;; Declared `(:align N)` values of the `(:repr c)` structs that have any, as
;; flat entries: canonical key, field count, the struct's own value, then one
;; value per field (0 when absent). Structs without declared alignment have no
;; entry, so a reflection table pays nothing for them.
(defstruct CtfeReflectAlignTable
  (words (__tl_dyn-array i64))
  (len i64))

(defstruct CtfeReflectInfoList
  (slots (__tl_dyn-array CtfeReflectInfo))
  (index ctfe_key_map.Map)
  (len i64)
  (aligns CtfeReflectAlignTable))

(defenum CtfeMaybeReflectInfo
  (None)
  (Some CtfeReflectInfo))

;; Name -> value environment plus immutable type metadata tables. A snapshot is
;; an arena handle and the newest binding index. Branches may append to the same
;; arena in any order because each binding stores its snapshot's previous head,
;; rather than assuming adjacent indices form a chain. Mutable CTFE `let`
;; bindings rewrite their stable arena slot; immutable bindings never do.
;; Fixed-size binding segments make growth append-only even under bump allocation:
;; only the small segment directory may be copied.
;; `syntax-pools` remains snapshot-local so captured caller syntax selects its
;; owning pool in O(1).
(defstruct CtfeEnvBinding
  (key i64)
  (value CompilerCtfeValue)
  (ty ast.AstType)
  (parent i64)
  (mutable-local bool))

(defstruct CtfeEnvArena
  (segments (__tl_dyn-array (__tl_dyn-array CtfeEnvBinding)))
  (segment-count i64)
  (len i64)
  (owner-arena i64))

;; Type literals of one comptime evaluation resolved by the typechecker in
;; their module's scope: the literal with type id `written[i]` denotes the type
;; with id `resolved[i]` in the same pool, the declaration identity its written
;; type names (`other.Point` through an import alias, say). The evaluator
;; itself has no import scope.
(defstruct CtfeTypeLiteralResolutions
  (written ast.AstTypeList)
  (resolved ast.AstTypeList))

(define (ctfe-type-literal-resolutions-empty) : CtfeTypeLiteralResolutions
  (CtfeTypeLiteralResolutions (ast.ast-type-list-new) (ast.ast-type-list-new)))

(defstruct CtfeEnvMetadata
  (pools ast.AstNodePoolContext)
  (layouts CtfeLayoutInfoList)
  (reflections CtfeReflectInfoList)
  (source-names ci.InternSourceNameSessionHandle)
  ;; The boxed CtfeTypeLiteralResolutions of one comptime evaluation, or 0.
  (type-literals u64))

;; The binding arena and the metadata are boxed and shared by every snapshot of
;; an environment; the environment keeps the two box pointers as addresses, so
;; it is a Copy handle with the layout it had when it held the boxes.
(defstruct CtfeEnv
  (arena-store u64)
  (head i64)
  (syntax-pools CtfeMaybeSyntaxPools)
  (metadata u64)
  (macro-state CompilerCtfeMacroState))

(define (ctfe-env-arena-box-new [store : CtfeEnvArena]) : u64
  (let
    [boxed : (Box CtfeEnvArena) (box store)]
    (unsafe
      (ptr-read (ptr-cast (ptr-addr-of boxed) : (Ptr u64))))))

(define (ctfe-env-metadata-box-new [metadata : CtfeEnvMetadata]) : u64
  (let
    [boxed : (Box CtfeEnvMetadata) (box metadata)]
    (unsafe
      (ptr-read (ptr-cast (ptr-addr-of boxed) : (Ptr u64))))))

;; The shared arena box itself, for in-place updates through `__tl-box-place`.
(define (ctfe-env-arena-box [address : u64]) : (Box CtfeEnvArena)
  (unsafe
    (ptr-read (ptr-cast (ptr-addr-of address) : (Ptr (Box CtfeEnvArena))))))

(define (ctfe-env-arena-read [address : u64]) : CtfeEnvArena
  (unsafe
    (ptr-read (int->ptr address : (Ptr CtfeEnvArena)))))

(define (ctfe-env-metadata-read [address : u64]) : CtfeEnvMetadata
  (unsafe
    (ptr-read (int->ptr address : (Ptr CtfeEnvMetadata)))))

(defstruct CtfeEnvRef
  (:lifetimes env)
  (value (& env CtfeEnv)))

(defstruct CtfeExprRef
  (:lifetimes expr)
  (value (& expr ast.AstExpr)))

(define (ctfe-env-arena-segment-capacity) : i64
  8)

(define (ctfe-env-arena-new) : CtfeEnvArena
  (CtfeEnvArena
    (__tl_make-array (__tl_dyn-array CtfeEnvBinding) 1)
    0
    0
    (arena.tl_arena_current)))

(define (ctfe-env-new
  [pools : ast.AstNodePoolContext]
  [layouts : CtfeLayoutInfoList]
  [reflections : CtfeReflectInfoList]
  [source-names : ci.InternSourceNameSessionHandle]
  [macro-state : CompilerCtfeMacroState]) : CtfeEnv
  (begin
    (compiler-ctfe-macro-state-bind-source-names! macro-state source-names)
    (CtfeEnv
      (ctfe-env-arena-box-new (ctfe-env-arena-new))
      -1
      (CtfeMaybeSyntaxPools.None)
      (ctfe-env-metadata-box-new
        (CtfeEnvMetadata pools layouts reflections source-names 0))
      macro-state)))

(define (ctfe-env-empty-with-pools-and-source-names-and-macro-state
  [pools : ast.AstNodePoolContext]
  [source-names : ci.InternSourceNameSessionHandle]
  [macro-state : CompilerCtfeMacroState]) : CtfeEnv
  (ctfe-env-new
    pools
    (ctfe-layout-info-list-empty)
    (ctfe-reflect-info-list-empty)
    source-names
    macro-state))

(define (ctfe-env-empty-with-pools-and-source-names
  [pools : ast.AstNodePoolContext]
  [source-names : ci.InternSourceNameSessionHandle]) : CtfeEnv
  (ctfe-env-empty-with-pools-and-source-names-and-macro-state
    pools
    source-names
    (compiler-ctfe-serial-macro-state)))

(define (ctfe-env-empty-with-pools [pools : ast.AstNodePoolContext]) : CtfeEnv
  (ctfe-env-empty-with-pools-and-source-names
    pools
    (ci.intern-source-name-session-capture-active-handle)))

(define (ctfe-env-empty) : CtfeEnv
  (ctfe-env-empty-with-pools (ast.ast-node-pool-context-capture-active)))

(define (ctfe-env-with-layouts-and-pools
  [layouts : CtfeLayoutInfoList]
  [pools : ast.AstNodePoolContext]) : CtfeEnv
  (ctfe-env-new
    pools
    layouts
    (ctfe-reflect-info-list-empty)
    (ci.intern-source-name-session-capture-active-handle)
    (compiler-ctfe-serial-macro-state)))

(define (ctfe-env-with-reflections-and-pools
  [reflections : CtfeReflectInfoList]
  [pools : ast.AstNodePoolContext]) : CtfeEnv
  (ctfe-env-new
    pools
    (ctfe-layout-info-list-empty)
    reflections
    (ci.intern-source-name-session-capture-active-handle)
    (compiler-ctfe-serial-macro-state)))

(define (ctfe-env-with-reflections-and-pools-and-source-names
  [reflections : CtfeReflectInfoList]
  [pools : ast.AstNodePoolContext]
  [source-names : ci.InternSourceNameSessionHandle]) : CtfeEnv
  (ctfe-env-new
    pools
    (ctfe-layout-info-list-empty)
    reflections
    source-names
    (compiler-ctfe-serial-macro-state)))

(define (ctfe-env-with-metadata-and-pools-and-source-names-and-macro-state
  [layouts : CtfeLayoutInfoList]
  [reflections : CtfeReflectInfoList]
  [pools : ast.AstNodePoolContext]
  [source-names : ci.InternSourceNameSessionHandle]
  [macro-state : CompilerCtfeMacroState]) : CtfeEnv
  (ctfe-env-new pools layouts reflections source-names macro-state))

(define (ctfe-env-arena-segments-copy-range!
  [dst : (&mut dst (__tl_dyn-array (__tl_dyn-array CtfeEnvBinding)))]
  [src : (& src (__tl_dyn-array (__tl_dyn-array CtfeEnvBinding)))]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set! (array-ref dst index) (array-ref src index))
        (set! index (+ index 1))))))

(define (ctfe-env-arena-add-segment! [store : (&mut store CtfeEnvArena)]) : unit
  (let
    [count : i64 store.segment-count]
    [capacity : i64 (array-length store.segments)]
    [owner : i64 store.owner-arena]
    (in-arena
      (arena.Arena owner)
      (begin
        (if (< count capacity)
          unit
          (let
            [bigger : (__tl_dyn-array (__tl_dyn-array CtfeEnvBinding))
              (__tl_make-array
                (__tl_dyn-array CtfeEnvBinding)
                (if (< capacity 1)
                  1
                  (* capacity 2)))]
            (begin
              (ctfe-env-arena-segments-copy-range!
                (&mut bigger)
                (& store.segments)
                count)
              (set! store.segments bigger))))
        (set!
          (array-ref store.segments count)
          (__tl_make-array CtfeEnvBinding (ctfe-env-arena-segment-capacity)))
        (set! store.segment-count (+ count 1))))))

(define (ctfe-env-arena-ensure-index!
  [store : (&mut store CtfeEnvArena)]
  [index : i64]) : unit
  (let
    [segment-index : i64 (/ index (ctfe-env-arena-segment-capacity))]
    (while (>= segment-index store.segment-count)
      (ctfe-env-arena-add-segment! store))))

(define (ctfe-env-arena-write-index!
  [store : (&mut store CtfeEnvArena)]
  [index : i64]
  [binding : CtfeEnvBinding]) : unit
  (let
    [segment-index : i64 (/ index (ctfe-env-arena-segment-capacity))]
    [offset : i64 (- index (* segment-index (ctfe-env-arena-segment-capacity)))]
    [segment : (__tl_dyn-array CtfeEnvBinding)
      (ast.ast-array-shared-view store.segments segment-index)]
    (set! (array-ref segment offset) binding)))

(define (ctfe-env-arena-binding-at
  [store : (& store CtfeEnvArena)]
  [index : i64]) : CtfeEnvBinding
  (let
    [segment-index : i64 (/ index (ctfe-env-arena-segment-capacity))]
    [offset : i64 (- index (* segment-index (ctfe-env-arena-segment-capacity)))]
    [segment : (__tl_dyn-array CtfeEnvBinding)
      (ast.ast-array-shared-view store.segments segment-index)]
    (unsafe
      (ptr-read (ptr-offset (__tl_array-data segment) offset)))))

(define (ctfe-env-arena-push!
  [store : (&mut store CtfeEnvArena)]
  [binding : CtfeEnvBinding]) : i64
  (let
    [index : i64 store.len]
    (begin
      (ctfe-env-arena-ensure-index! store index)
      (ctfe-env-arena-write-index! store index binding)
      (set! store.len (+ index 1))
      index)))

(define (ctfe-env-append-binding
  [env : CtfeEnv]
  [name-id : i64]
  [value : CompilerCtfeValue]
  [ty : ast.AstType]
  [mutable-local : bool]) : CtfeEnv
  (let
    [store : (Box CtfeEnvArena) (ctfe-env-arena-box env.arena-store)]
    [syntax-pools
      : CtfeMaybeSyntaxPools
      ;; Provenance inspection must not clone a syntax value: cloning its pool
      ;; context creates detached state cells, so later builder nodes advance a
      ;; succession of snapshots instead of the environment's retained cursor.
      (ctfe-env-syntax-pools-for-value
        (& env)
        (owned_view.compiler-owned-shared-view value))]
    [index : i64
      (ctfe-env-arena-push!
        (&mut (__tl-box-place store))
        (CtfeEnvBinding name-id value ty env.head mutable-local))]
    (CtfeEnv env.arena-store index syntax-pools env.metadata env.macro-state)))

(define (ctfe-env-extend-id
  [env : CtfeEnv]
  [name-id : i64]
  [value : CompilerCtfeValue]) : CtfeEnv
  (let
    [value-ty : ast.AstType
      (ctfe-value-default-cast-type (ctfe-env-pools env) (& value))]
    (ctfe-env-append-binding env name-id value value-ty false)))

(define (ctfe-env-extend-typed-id
  [env : CtfeEnv]
  [name-id : i64]
  [value : CompilerCtfeValue]
  [ty : ast.AstType]) : CtfeEnv
  (ctfe-env-append-binding env name-id value ty false))

;; Only CTFE lexical `let` bindings receive mutable slots. This keeps compiler
;; metadata, macro parameters, and all runtime-only forms outside the mutation
;; surface while still allowing iterative compile-time syntax construction.
(define (ctfe-env-extend-local-typed-id
  [env : CtfeEnv]
  [name-id : i64]
  [value : CompilerCtfeValue]
  [ty : ast.AstType]) : CtfeEnv
  (ctfe-env-append-binding env name-id value ty true))

(define (ctfe-layout-field-list-with-capacity [capacity : i64]) : CtfeLayoutFieldList
  (CtfeLayoutFieldList
    (__tl_make-array CtfeLayoutField capacity)
    (__tl_make-array i64 capacity)
    0))

(define (ctfe-layout-field-list-empty) : CtfeLayoutFieldList
  (ctfe-layout-field-list-with-capacity 0))

(define (ctfe-layout-field-list-ref
  [items : (& items CtfeLayoutFieldList)]
  [index : i64]) : CtfeLayoutField
  (ast.ast-array-shared-view items.slots index))

(define (ctfe-layout-field-list-push-id
  [items : CtfeLayoutFieldList]
  [value : CtfeLayoutField]
  [key-id : i64]) : CtfeLayoutFieldList
  (let
    [n : i64 items.len]
    [slots : (__tl_dyn-array CtfeLayoutField) items.slots]
    [key-ids : (__tl_dyn-array i64) items.key-ids]
    (begin
      (set! (array-ref slots n) value)
      (set! (array-ref key-ids n) key-id)
      (CtfeLayoutFieldList slots key-ids (+ n 1)))))

(define (ctfe-layout-info-list-with-capacity [capacity : i64]) : CtfeLayoutInfoList
  (CtfeLayoutInfoList
    (__tl_make-array CtfeLayoutInfo capacity)
    (ctfe_key_map.with-capacity (+ (* capacity 2) 1))
    0))

(define (ctfe-layout-info-list-empty) : CtfeLayoutInfoList
  (ctfe-layout-info-list-with-capacity 0))

(define (ctfe-metadata-grown-capacity [current : i64] [required : i64]) : i64
  (let
    [capacity : i64
      (if (< current 4)
        4
        current)]
    (begin
      (while (< capacity required)
        (set! capacity (* capacity 2)))
      capacity)))

(define (ctfe-layout-info-list-ensure-capacity
  [items : CtfeLayoutInfoList]
  [required : i64]) : CtfeLayoutInfoList
  (let
    [slots : (__tl_dyn-array CtfeLayoutInfo) items.slots]
    [capacity : i64 (array-length slots)]
    [len : i64 items.len]
    (if (<= required capacity)
      items
      (let
        [grown : (__tl_dyn-array CtfeLayoutInfo)
          (__tl_make-array
            CtfeLayoutInfo
            (ctfe-metadata-grown-capacity capacity required))]
        [index : i64 0]
        (begin
          (while (< index len)
            (begin
              (set! (array-ref grown index) (array-ref slots index))
              (set! index (+ index 1))))
          ;; The id map grows independently on insert. Preserve it so the
          ;; copied vector retains every first-wins slot without rebuilding a
          ;; second key list solely for capacity changes.
          (CtfeLayoutInfoList grown items.index len))))))

(define (ctfe-layout-info-list-contains-key-id?
  [items : CtfeLayoutInfoList]
  [key-id : i64]) : bool
  (ctfe_key_map.contains? (& items.index) key-id))

(define (ctfe-layout-info-list-ref [items : CtfeLayoutInfoList] [index : i64]) : CtfeLayoutInfo
  (array-ref items.slots index))

(define (ctfe-layout-info-list-push-id
  [items : CtfeLayoutInfoList]
  [value : CtfeLayoutInfo]
  [name-id : i64]) : CtfeLayoutInfoList
  (let
    [n : i64 items.len]
    [slots : (__tl_dyn-array CtfeLayoutInfo) items.slots]
    [index : ctfe_key_map.Map items.index]
    (begin
      (set! (array-ref slots n) value)
      (ctfe_key_map.insert-ref! (&mut index) name-id n)
      (CtfeLayoutInfoList slots index (+ n 1)))))

(define (ctfe-reflect-field-list-with-capacity [capacity : i64]) : CtfeReflectFieldList
  (CtfeReflectFieldList (__tl_make-array CtfeReflectField capacity) 0))

(define (ctfe-reflect-field-list-ref
  [items : CtfeReflectFieldList]
  [index : i64]) : CtfeReflectField
  (array-ref items.slots index))

(define (ctfe-reflect-field-list-push
  [items : CtfeReflectFieldList]
  [value : CtfeReflectField]) : CtfeReflectFieldList
  (let
    [n : i64 items.len]
    [slots : (__tl_dyn-array CtfeReflectField) items.slots]
    (begin
      (set! (array-ref slots n) value)
      (CtfeReflectFieldList slots (+ n 1)))))

(define (ctfe-reflect-variant-list-with-capacity [capacity : i64]) : CtfeReflectVariantList
  (CtfeReflectVariantList (__tl_make-array CtfeReflectVariant capacity) 0))

(define (ctfe-reflect-variant-list-ref
  [items : CtfeReflectVariantList]
  [index : i64]) : CtfeReflectVariant
  (array-ref items.slots index))

(define (ctfe-reflect-variant-list-push
  [items : CtfeReflectVariantList]
  [value : CtfeReflectVariant]) : CtfeReflectVariantList
  (let
    [n : i64 items.len]
    [slots : (__tl_dyn-array CtfeReflectVariant) items.slots]
    (begin
      (set! (array-ref slots n) value)
      (CtfeReflectVariantList slots (+ n 1)))))

(define (ctfe-reflect-info-list-with-capacity [capacity : i64]) : CtfeReflectInfoList
  (CtfeReflectInfoList
    (__tl_make-array CtfeReflectInfo capacity)
    (ctfe_key_map.with-capacity (+ (* capacity 2) 1))
    0
    (CtfeReflectAlignTable (__tl_make-array i64 0) 0)))

;; Record a struct's declared alignments under its canonical key.
(define (ctfe-reflect-info-list-add-aligns
  [items : CtfeReflectInfoList]
  [key-id : i64]
  [repr : (& repr ast.AstStructRepr)]
  [field-count : i64]) : CtfeReflectInfoList
  (let
    [aligns : CtfeReflectAlignTable items.aligns]
    [start : i64 aligns.len]
    [needed : i64 (+ start (+ 3 field-count))]
    [words : (__tl_dyn-array i64)
      (if (<= needed (array-length aligns.words))
        aligns.words
        (let
          [grown : (__tl_dyn-array i64)
            (__tl_make-array
              i64
              (ctfe-metadata-grown-capacity (array-length aligns.words) needed))]
          [index : i64 0]
          (begin
            (while (< index start)
              (begin
                (set! (array-ref grown index) (array-ref aligns.words index))
                (set! index (+ index 1))))
            grown)))]
    [field : i64 0]
    (begin
      (set! (array-ref words start) key-id)
      (set! (array-ref words (+ start 1)) field-count)
      (set!
        (array-ref words (+ start 2))
        (ast.ast-struct-repr-declared-align repr))
      (while (< field field-count)
        (begin
          (set!
            (array-ref words (+ (+ start 3) field))
            (ast.ast-struct-repr-field-declared-align repr field))
          (set! field (+ field 1))))
      (CtfeReflectInfoList
        items.slots
        items.index
        items.len
        (CtfeReflectAlignTable words needed)))))

;; The declared alignment of the struct with canonical key `key-id`: its own
;; value for `field` -1, otherwise that field's. 0 when it declares none.
(define (ctfe-reflect-declared-align
  [items : (& items CtfeReflectInfoList)]
  [key-id : i64]
  [field : i64]) : i64
  (let
    [words : (__tl_dyn-array i64) items.aligns.words]
    [len : i64 items.aligns.len]
    [cursor : i64 0]
    [found : i64 0]
    (begin
      (while (< cursor len)
        (let
          [count : i64 (array-ref words (+ cursor 1))]
          (begin
            (when
              (and (= (array-ref words cursor) key-id) (< field count))
              (begin
                (set! found (array-ref words (+ (+ cursor 3) field)))
                (set! cursor len)))
            (set! cursor (+ cursor (+ 3 count))))))
      found)))

(define (ctfe-reflect-info-list-empty) : CtfeReflectInfoList
  (ctfe-reflect-info-list-with-capacity 0))

(define (ctfe-reflect-info-list-ensure-capacity
  [items : CtfeReflectInfoList]
  [required : i64]) : CtfeReflectInfoList
  (let
    [slots : (__tl_dyn-array CtfeReflectInfo) items.slots]
    [capacity : i64 (array-length slots)]
    [len : i64 items.len]
    (if (<= required capacity)
      items
      (let
        [grown : (__tl_dyn-array CtfeReflectInfo)
          (__tl_make-array
            CtfeReflectInfo
            (ctfe-metadata-grown-capacity capacity required))]
        [index : i64 0]
        (begin
          (while (< index len)
            (begin
              (set! (array-ref grown index) (array-ref slots index))
              (set! index (+ index 1))))
          (CtfeReflectInfoList grown items.index len items.aligns))))))

(define (ctfe-reflect-info-list-contains-key-id?
  [items : CtfeReflectInfoList]
  [key-id : i64]) : bool
  (ctfe_key_map.contains? (& items.index) key-id))

(define (ctfe-reflect-info-list-ref
  [items : (& items CtfeReflectInfoList)]
  [index : i64]) : CtfeReflectInfo
  (clone (array-ref items.slots index)))

(define (ctfe-reflect-info-list-push-id
  [items : CtfeReflectInfoList]
  [value : CtfeReflectInfo]
  [key-id : i64]) : CtfeReflectInfoList
  (let
    [n : i64 items.len]
    [slots : (__tl_dyn-array CtfeReflectInfo) items.slots]
    [index : ctfe_key_map.Map items.index]
    [aligns : CtfeReflectAlignTable items.aligns]
    (begin
      (set! (array-ref slots n) value)
      (ctfe_key_map.insert-ref! (&mut index) key-id n)
      (CtfeReflectInfoList slots index (+ n 1) aligns))))

;; Retained as a compatibility hook for callers that delimit metadata builds.
;; Each metadata list now owns its id index, so no shared String-derived set is
;; reset here.
(define (ctfe-build-seen-reset!) : unit
  unit)

(define (ctfe-layout-info-list-add-if-missing-id
  [layouts : CtfeLayoutInfoList]
  [info : CtfeLayoutInfo]
  [name-id : i64]) : CtfeLayoutInfoList
  (if (ctfe_key_map.contains? (& layouts.index) name-id)
    layouts
    (ctfe-layout-info-list-push-id layouts info name-id)))

(define (ctfe-layout-info-lookup-id-from
  [layouts : CtfeLayoutInfoList]
  [name-id : i64]
  [_index : i64]) : CtfeMaybeLayoutInfo
  (match (ctfe_key_map.get (& layouts.index) name-id)
    [(ctfe_key_map.LookupFound slot)
      (CtfeMaybeLayoutInfo.Some (ctfe-layout-info-list-ref layouts slot))]
    [(ctfe_key_map.LookupMissing) (CtfeMaybeLayoutInfo.None)]))

(define (ctfe-layout-info-lookup-name-id
  [layouts : CtfeLayoutInfoList]
  [name-id : i64]) : CtfeMaybeLayoutInfo
  (ctfe-layout-info-lookup-id-from layouts (ctfe-name-id-key name-id) 0))

(define (ctfe-layout-field-offset-id-from
  [fields : (& fields CtfeLayoutFieldList)]
  [name-id : i64]
  [index : i64]) : i64
  (if (>= index fields.len)
    -1
    (let
      [field : CtfeLayoutField (ctfe-layout-field-list-ref fields index)]
      (match field
        [(CtfeLayoutField.Field _ offset)
          (if (= (array-ref fields.key-ids index) name-id)
            offset
            (ctfe-layout-field-offset-id-from fields name-id (+ index 1)))]))))

(define (ctfe-layout-field-offset-id
  [fields : (& fields CtfeLayoutFieldList)]
  [name-id : i64]) : i64
  (ctfe-layout-field-offset-id-from fields name-id 0))

(define (ctfe-env-shared-view [env : (& env CtfeEnv)]) : CtfeEnv
  (let
    [cell : (CtfeEnvRef env) (CtfeEnvRef env)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr CtfeEnv))))))

(define (ctfe-env-layouts [env : (& env CtfeEnv)]) : CtfeLayoutInfoList
  (let
    [view : CtfeEnv (ctfe-env-shared-view env)]
    [metadata : CtfeEnvMetadata (ctfe-env-metadata-read view.metadata)]
    metadata.layouts))

(define (ctfe-env-reflections [env : (& env CtfeEnv)]) : CtfeReflectInfoList
  (let
    [view : CtfeEnv (ctfe-env-shared-view env)]
    [metadata : CtfeEnvMetadata (ctfe-env-metadata-read view.metadata)]
    metadata.reflections))

;; Pool contexts are mutable state cells, not owned values. Keep this accessor
;; syntax-level so its explicit shallow read reaches the consumer directly;
;; returning an `AstNodePoolContext` through a function's owned-value boundary
;; would detach the cells under by-value ownership.
(define (ctfe-env-pools-address [env : (& env CtfeEnv)]) : u64
  (let
    [cell : (CtfeEnvRef env) (CtfeEnvRef env)]
    [env-address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    ;; CtfeEnv word 6 is the metadata box pointer, and `pools` is the first
    ;; field of that boxed payload.
    (unsafe
      (ptr-read (ptr-offset (int->ptr env-address : (Ptr u64)) 6)))))

(defmacro (ctfe-env-pools [env : Expr]) : ast.AstNodePoolContext
  `(unsafe
    (ptr-read
      (int->ptr (ctfe-env-pools-address ,env) : (Ptr ast.AstNodePoolContext)))))

;; A caller pool can be a newer snapshot of the transformer's backing tables.
;; Advance the owning context before appending provenance wrappers, while the
;; pool primitive's storage check keeps unrelated syntax domains isolated.
(define (ctfe-env-adopt-active-pools! [env : (& env CtfeEnv)]) : unit
  (let
    [owner-address : u64 (ctfe-env-pools-address env)]
    [syntax-address : u64 (ctfe-env-syntax-pool-context-address-live env)]
    (begin
      (ast.ast-node-pool-context-adopt-newer-cells!
        (ctfe-pool-context-cell-address-at owner-address 0)
        (ctfe-pool-context-cell-address-at owner-address 1)
        (ctfe-pool-context-cell-address-at syntax-address 0)
        (ctfe-pool-context-cell-address-at syntax-address 1))
      (if (ast.ast-node-pool-has-active-context?)
        (ast.ast-node-pool-context-adopt-newer-cells!
          (ctfe-pool-context-cell-address-at owner-address 0)
          (ctfe-pool-context-cell-address-at owner-address 1)
          (ast.ast-node-pool-active-context-expr-cell-address)
          (ast.ast-node-pool-active-context-type-cell-address))
        unit))))

(define (ctfe-env-publish-owning-pools! [env : (& env CtfeEnv)]) : unit
  (let
    [owner-address : u64 (ctfe-env-pools-address env)]
    [syntax-address : u64 (ctfe-env-syntax-pool-context-address-live env)]
    (begin
      (ast.ast-node-pool-context-adopt-newer-cells!
        (ctfe-pool-context-cell-address-at syntax-address 0)
        (ctfe-pool-context-cell-address-at syntax-address 1)
        (ctfe-pool-context-cell-address-at owner-address 0)
        (ctfe-pool-context-cell-address-at owner-address 1))
      (if (ast.ast-node-pool-has-active-context?)
        (ast.ast-node-pool-context-adopt-newer-cells!
          (ast.ast-node-pool-active-context-expr-cell-address)
          (ast.ast-node-pool-active-context-type-cell-address)
          (ctfe-pool-context-cell-address-at owner-address 0)
          (ctfe-pool-context-cell-address-at owner-address 1))
        unit))))

(define (ctfe-env-source-names [env : (& env CtfeEnv)]) : ci.InternSourceNameSessionHandle
  (let
    [view : CtfeEnv (ctfe-env-shared-view env)]
    [metadata : CtfeEnvMetadata (ctfe-env-metadata-read view.metadata)]
    metadata.source-names))

(define (ctfe-env-structural-session [env : (& env CtfeEnv)]) : cis.InternStructuralSessionHandle
  (cis.intern-structural-session-handle-from-source-names
    (ctfe-env-source-names env)))

(define (ctfe-env-macro-state [env : (& env CtfeEnv)]) : CompilerCtfeMacroState
  (let
    [view : CtfeEnv (ctfe-env-shared-view env)]
    view.macro-state))

;; A transformer reads its definition body from `ctfe-env-pools`, but syntax
;; selected from a variadic caller argument may belong to a newer pool. Carry
;; that pool on every environment extension so generated nodes and captured
;; children always share ownership without rescanning lexical locals.
(define (ctfe-env-syntax-pools-address [env : (& env CtfeEnv)]) : u64
  (let
    [cell : (CtfeEnvRef env) (CtfeEnvRef env)]
    [env-address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    ;; The inline CtfeMaybeSyntaxPools begins at word 2 of CtfeEnv.
    (+ env-address 16)))

(defmacro (ctfe-env-syntax-pools-live [env : Expr]) : CtfeMaybeSyntaxPools
  `(unsafe
    (ptr-read
      (int->ptr
        (ctfe-env-syntax-pools-address ,env)
        : (Ptr CtfeMaybeSyntaxPools)))))

;; Public read boundary. Internal builders use the macro above so mutations
;; reach the retained state cell before any owned-value return can detach it.
(define (ctfe-env-syntax-pools [env : (& env CtfeEnv)]) : CtfeMaybeSyntaxPools
  (ctfe-env-syntax-pools-live env))

(defmacro (ctfe-env-syntax-pool-context-live [env : Expr]) : ast.AstNodePoolContext
  `(unsafe
    (ptr-read
      (int->ptr
        (ctfe-env-syntax-pool-context-address-live ,env)
        : (Ptr ast.AstNodePoolContext)))))

;; Mutation cannot cross the aggregate match/binding above: under ordinary
;; by-value ownership, binding the `Some` payload detaches its dynamic-array
;; state cells. Builders that append to the retained syntax pool therefore
;; select the inline context by address and pass only its scalar cell pointers.
;; `None` is variant zero; `Some` stores AstNodePoolContext immediately after
;; the discriminant.
(define (ctfe-env-syntax-pool-context-address-live [env : (& env CtfeEnv)]) : u64
  (let
    [syntax-address : u64 (ctfe-env-syntax-pools-address env)]
    [tag : i64
      (unsafe
        (ptr-read (int->ptr syntax-address : (Ptr i64))))]
    (if (= tag 0)
      (ctfe-env-pools-address env)
      (+ syntax-address 8))))

(define (ctfe-pool-context-cell-address-at
  [pools-address : u64]
  [field-index : i64]) : u64
  (let
    [fields : (Ptr u64)
      (unsafe
        (int->ptr pools-address : (Ptr u64)))]
    [array-descriptor : u64
      (unsafe
        (ptr-read (ptr-offset fields field-index)))]
    (unsafe
      (ptr-read (int->ptr array-descriptor : (Ptr u64))))))

(define (ctfe-env-syntax-expr-cell-address-live [env : (& env CtfeEnv)]) : u64
  (ctfe-pool-context-cell-address-at
    (ctfe-env-syntax-pool-context-address-live env)
    0))

(define (ctfe-env-syntax-type-cell-address-live [env : (& env CtfeEnv)]) : u64
  (ctfe-pool-context-cell-address-at
    (ctfe-env-syntax-pool-context-address-live env)
    1))

(define (ctfe-syntax-pools-for-value
  [current : CtfeMaybeSyntaxPools]
  [value : CompilerCtfeValue]) : CtfeMaybeSyntaxPools
  (match (ctfe-value-syntax-pools value)
    [(CtfeMaybeSyntaxPools.Some pools) (CtfeMaybeSyntaxPools.Some pools)]
    [(CtfeMaybeSyntaxPools.None) current]))

(define (ctfe-env-syntax-pools-for-value
  [env : (& env CtfeEnv)]
  [value : CompilerCtfeValue]) : CtfeMaybeSyntaxPools
  (ctfe-syntax-pools-for-value (ctfe-env-syntax-pools-live env) value))

(define (ctfe-env-syntax-pool-context [env : (& env CtfeEnv)]) : ast.AstNodePoolContext
  (ctfe-env-syntax-pool-context-live env))

(define (ctfe-syntax-ast-push [env : (& env CtfeEnv)] [node : ast.AstExpr]) : i64
  (begin
    (ctfe-env-adopt-active-pools! env)
    (ctfe-env-publish-owning-pools! env)
    (let
      [pushed : i64
        (ast.ast-node-pool-context-expr-push-cells
          (ctfe-env-syntax-expr-cell-address-live env)
          (ctfe-env-syntax-type-cell-address-live env)
          node)]
      (begin
        (ctfe-env-adopt-active-pools! env)
        (ctfe-env-publish-owning-pools! env)
        pushed))))

(define (ctfe-syntax-expr-value
  [env : (& env CtfeEnv)]
  [node : i64]
  [ty : ast.AstType]) : CompilerCtfeValue
  (begin
    ;; Direct builders append through retained syntax cells. Publish their new
    ;; cursor before another caller/captured branch can reuse the same row.
    (ctfe-env-adopt-active-pools! env)
    (ctfe-env-publish-owning-pools! env)
    (match (ctfe-env-syntax-pools-live env)
      [(CtfeMaybeSyntaxPools.Some pools)
        (CompilerCtfeValue.CapturedExpr node ty pools)]
      [(CtfeMaybeSyntaxPools.None) (CompilerCtfeValue.Expr node ty)])))

(define (ctfe-syntax-expr-push
  [env : (& env CtfeEnv)]
  [node : ast.AstExpr]
  [ty : ast.AstType]) : CompilerCtfeValue
  (ctfe-syntax-expr-value env (ctfe-syntax-ast-push env node) ty))

;; `env` evaluating one comptime expression whose type literals the caller
;; resolved in `resolutions`.
(define (ctfe-env-with-type-literals
  [env : CtfeEnv]
  [resolutions : CtfeTypeLiteralResolutions]) : CtfeEnv
  (let
    [env-view : CtfeEnv env]
    [metadata : CtfeEnvMetadata (ctfe-env-metadata-read env-view.metadata)]
    [boxed : (Box CtfeTypeLiteralResolutions) (box resolutions)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of boxed) : (Ptr u64))))]
    (CtfeEnv
      env.arena-store
      env.head
      env.syntax-pools
      (ctfe-env-metadata-box-new
        (CtfeEnvMetadata
          metadata.pools
          metadata.layouts
          metadata.reflections
          metadata.source-names
          address))
      env.macro-state)))

;; The type a TypeLiteral with type id `id` denotes: the caller's resolution
;; when it recorded one, otherwise the written type.
(define (ctfe-type-literal-type [env : (& env CtfeEnv)] [id : i64]) : ast.AstType
  (let
    [view : CtfeEnv (ctfe-env-shared-view env)]
    [metadata : CtfeEnvMetadata (ctfe-env-metadata-read view.metadata)]
    [address : u64 metadata.type-literals]
    (if (= address (cast 0 : u64))
      (ctfe-ty-get env id)
      (let
        [resolutions : CtfeTypeLiteralResolutions
          (unsafe
            (ptr-read (int->ptr address : (Ptr CtfeTypeLiteralResolutions))))]
        [count : i64 (ast.ast-type-list-len (& resolutions.written))]
        [index : i64 0]
        [resolved : i64 id]
        (begin
          (while (< index count)
            (if (= (ast.ast-type-list-get (& resolutions.written) index -1) id)
              (begin
                (set!
                  resolved
                  (ast.ast-type-list-get (& resolutions.resolved) index id))
                (set! index count))
              (set! index (+ index 1))))
          (ctfe-ty-get env resolved))))))

(define (ctfe-env-rebase-pools [env : CtfeEnv] [pools : ast.AstNodePoolContext]) : CtfeEnv
  (let
    [env-view : CtfeEnv env]
    [metadata : CtfeEnvMetadata (ctfe-env-metadata-read env-view.metadata)]
    (CtfeEnv
      env.arena-store
      env.head
      env.syntax-pools
      (ctfe-env-metadata-box-new
        (CtfeEnvMetadata
          pools
          metadata.layouts
          metadata.reflections
          metadata.source-names
          metadata.type-literals))
      env.macro-state)))

;; Binding-clause syntax values predate the pool-bearing CapturedExpr variants.
;; For the stdlib binding-prefix transformer, their child IDs come from a newer
;; snapshot of the definition/caller pool. Keep that pool both as the evaluator's
;; read view and as syntax-construction provenance so the produced root carries
;; it back through macro expansion. Callers must not pass an unrelated pool.
(define (ctfe-env-rebase-syntax-pools
  [env : CtfeEnv]
  [pools : ast.AstNodePoolContext]) : CtfeEnv
  (let
    [env-view : CtfeEnv env]
    [metadata : CtfeEnvMetadata (ctfe-env-metadata-read env-view.metadata)]
    (CtfeEnv
      env.arena-store
      env.head
      (CtfeMaybeSyntaxPools.Some pools)
      (ctfe-env-metadata-box-new
        (CtfeEnvMetadata
          pools
          metadata.layouts
          metadata.reflections
          metadata.source-names
          metadata.type-literals))
      env.macro-state)))

(define (ctfe-ast-get [env : (& env CtfeEnv)] [id : i64]) : ast.AstExpr
  (let
    [pools : ast.AstNodePoolContext (ctfe-env-pools env)]
    (ast.ast-node-pool-context-expr-get pools id)))

(define (ctfe-ast-push [env : (& env CtfeEnv)] [node : ast.AstExpr]) : i64
  (ast.ast-node-pool-context-expr-push (ctfe-env-pools env) node))

(define (ctfe-expr-unspan [env : (& env CtfeEnv)] [expr : ast.AstExpr]) : ast.AstExpr
  (match (clone expr)
    [(ast.AstExpr.Spanned inner-id _)
      (ctfe-expr-unspan env (ctfe-ast-get env inner-id))]
    [(ast.AstExpr.MacroExpansion inner-id _ _)
      (ctfe-expr-unspan env (ctfe-ast-get env inner-id))]
    [_ expr]))

(define (ctfe-ty-get [env : (& env CtfeEnv)] [id : i64]) : ast.AstType
  (let
    [pools : ast.AstNodePoolContext (ctfe-env-pools env)]
    (ast.ast-node-pool-context-type-get pools id)))

;: Intern `ty` in the env's own type pool and return its AstTypeId. Type ids
;; are only meaningful inside the pool that issued them, so an AstExpr built
;; for this env must carry ids pushed here rather than ids copied in from a
;; caller pool.
(define (ctfe-ty-push [env : (& env CtfeEnv)] [ty : ast.AstType]) : i64
  (ast.ast-node-pool-context-type-push (ctfe-env-pools env) ty))

;; Lookup result for an environment probe.
(defenum CtfeMaybeValue
  (None)
  (Some CompilerCtfeValue))

(define (ctfe-env-lookup-id-from [env : (& env CtfeEnv)] [name-id : i64]) : CtfeMaybeValue
  (let
    [view : CtfeEnv (ctfe-env-shared-view env)]
    [store : CtfeEnvArena (ctfe-env-arena-read view.arena-store)]
    [index : i64 env.head]
    [searching? : bool true]
    [result : CtfeMaybeValue (CtfeMaybeValue.None)]
    (begin
      (while (and searching? (>= index 0))
        (let
          [binding : CtfeEnvBinding (ctfe-env-arena-binding-at store index)]
          (if (= binding.key name-id)
            (begin
              (set! result (CtfeMaybeValue.Some binding.value))
              (set! searching? false))
            (set! index binding.parent))))
      result)))

(define (ctfe-env-lookup-id [env : (& env CtfeEnv)] [name-id : i64]) : CtfeMaybeValue
  (ctfe-env-lookup-id-from env name-id))

(define (ctfe-env-lookup-type-id-from [env : (& env CtfeEnv)] [name-id : i64]) : ast.AstMaybeType
  (let
    [view : CtfeEnv (ctfe-env-shared-view env)]
    [store : CtfeEnvArena (ctfe-env-arena-read view.arena-store)]
    [index : i64 env.head]
    [searching? : bool true]
    [result : ast.AstMaybeType (ast.AstMaybeType.No)]
    (begin
      (while (and searching? (>= index 0))
        (let
          [binding : CtfeEnvBinding (ctfe-env-arena-binding-at store index)]
          (if (= binding.key name-id)
            (begin
              (set! result (ast.AstMaybeType.Some binding.ty))
              (set! searching? false))
            (set! index binding.parent))))
      result)))

(define (ctfe-env-lookup-type-id [env : (& env CtfeEnv)] [name-id : i64]) : ast.AstMaybeType
  (ctfe-env-lookup-type-id-from env name-id))

;; Set the nearest CTFE-local binding. Finding an immutable binding with the
;; same name stops the search, matching ordinary lexical shadowing rules.
(define (ctfe-env-set-local-id!
  [env : CtfeEnv]
  [name-id : i64]
  [value : CompilerCtfeValue]) : bool
  (let
    [store : (Box CtfeEnvArena) (ctfe-env-arena-box env.arena-store)]
    [index : i64 env.head]
    [searching? : bool true]
    [updated? : bool false]
    (begin
      (while (and searching? (>= index 0))
        (let
          [binding : CtfeEnvBinding
            (ctfe-env-arena-binding-at (__tl-box-place store) index)]
          (if (= binding.key name-id)
            (begin
              (if binding.mutable-local
                (begin
                  (set! binding.value value)
                  (ctfe-env-arena-write-index!
                    (&mut (__tl-box-place store))
                    index
                    binding)
                  (set! updated? true))
                unit)
              (set! searching? false))
            (set! index binding.parent))))
      updated?)))

(define (ctfe-string-prefix? [text : String] [prefix : String]) : bool
  (let
    [text-len : i64 (ctfe-private-string-length text)]
    [prefix-len : i64 (ctfe-private-string-length prefix)]
    (if (< text-len prefix-len)
      false
      (let
        [i : i64 0]
        [same : bool true]
        (begin
          (while (and same (< i prefix-len))
            (if (=
              (cast (ctfe-private-string-ref text i) : i64)
              (cast (ctfe-private-string-ref prefix i) : i64))
              (set! i (+ i 1))
              (set! same false)))
          same)))))

(define (ctfe-string-slice-eq? [text : String] [start : i64] [needle : String]) : bool
  (let
    [text-len : i64 (ctfe-private-string-length text)]
    [needle-len : i64 (ctfe-private-string-length needle)]
    (if (or (< start 0) (> (+ start needle-len) text-len))
      false
      (let
        [i : i64 0]
        [same : bool true]
        (begin
          (while (and same (< i needle-len))
            (if (=
              (cast (ctfe-private-string-ref text (+ start i)) : i64)
              (cast (ctfe-private-string-ref needle i) : i64))
              (set! i (+ i 1))
              (set! same false)))
          same)))))

(define (ctfe-string-eq-after-prefix?
  [name : String]
  [prefix : String]
  [base : String]) : bool
  (let
    [name-len : i64 (ctfe-private-string-length name)]
    [prefix-len : i64 (ctfe-private-string-length prefix)]
    [base-len : i64 (ctfe-private-string-length base)]
    (and
      (= name-len (+ prefix-len base-len))
      (ctfe-string-prefix? (string.copy name) (string.copy prefix))
      (ctfe-string-slice-eq? name prefix-len base))))

(define (ctfe-string-suffix-with-prefix?
  [name : String]
  [prefix : String]
  [base : String]) : bool
  (let
    [name-len : i64 (ctfe-private-string-length name)]
    [prefix-len : i64 (ctfe-private-string-length prefix)]
    [base-len : i64 (ctfe-private-string-length base)]
    [start : i64 (- name-len (+ prefix-len base-len))]
    (and
      (>= start 0)
      (ctfe-string-slice-eq? (string.copy name) start prefix)
      (ctfe-string-slice-eq? name (+ start prefix-len) base))))

(define (ctfe-string-has-module-separator? [name : String]) : bool
  (let
    [i : i64 0]
    [n : i64 (ctfe-private-string-length name)]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (let
          [c : i64 (cast (ctfe-private-string-ref name i) : i64)]
          (if (or (= c 46) (= c 47))
            (set! found true)
            (set! i (+ i 1)))))
      found)))

(define (ctfe-string-contains-string-token? [name : String]) : bool
  (let
    [i : i64 0]
    [n : i64 (ctfe-private-string-length name)]
    [found : bool false]
    (begin
      (while (and (not found) (<= (+ i 6) n))
        (if (and
          (= (cast (ctfe-private-string-ref name i) : i64) 115)
          (= (cast (ctfe-private-string-ref name (+ i 1)) : i64) 116)
          (= (cast (ctfe-private-string-ref name (+ i 2)) : i64) 114)
          (= (cast (ctfe-private-string-ref name (+ i 3)) : i64) 105)
          (= (cast (ctfe-private-string-ref name (+ i 4)) : i64) 110)
          (= (cast (ctfe-private-string-ref name (+ i 5)) : i64) 103))
          (set! found true)
          (set! i (+ i 1))))
      found)))

(define (ctfe-string-helper-candidate-name-id? [name : String] [name-id : i64]) : bool
  (or
    (ctfe-string-contains-string-token? name)
    (ctfe-builtin-string-ref-id? name-id)
    (ctfe-builtin-string-length-id? name-id)))

(define (ctfe-hygiene-enabled-id) : i64
  -2)

(define (ctfe-hygiene-global-prefix) : String
  "__tl_macro_global$")

(define (ctfe-hygiene-enabled? [env : (& env CtfeEnv)]) : bool
  (match (ctfe-env-lookup-id env (ctfe-hygiene-enabled-id))
    [(CtfeMaybeValue.Some value)
      (match (ctfe-value-owned-copy (& value))
        [(CompilerCtfeValue.Bool enabled) enabled]
        [_ false])]
    [(CtfeMaybeValue.None) false]))

(define (ctfe-quote-name-id [env : (& env CtfeEnv)] [name : i64]) : i64
  (if (ctfe-hygiene-enabled? env)
    (if (cis.intern-structural-session-template-source-id?
      (ctfe-env-structural-session env)
      name)
      name
      (if (ci.intern-renderable-id? name)
        (cis.intern-template-source-identity-raw
          (cis.intern-structural-session-template-source-identity
            (ctfe-env-structural-session env)
            name))
        name))
    name))

(define (ctfe-hygiene-global-name? [name : String]) : bool
  (ctfe-string-prefix? name (ctfe-hygiene-global-prefix)))

(define (ctfe-hygiene-global-base [name : String]) : String
  (string.substring
    name
    (ctfe-private-string-length (ctfe-hygiene-global-prefix))
    (-
      (ctfe-private-string-length name)
      (ctfe-private-string-length (ctfe-hygiene-global-prefix)))))

(define (ctfe-hygiene-context-separator-index [payload : String]) : i64
  (let
    [i : i64 0]
    [n : i64 (ctfe-private-string-length payload)]
    [found : i64 -1]
    (begin
      (while (and (< i n) (< found 0))
        (if (= (cast (ctfe-private-string-ref payload i) : i64) 124)
          (set! found i)
          (set! i (+ i 1))))
      found)))

(define (ctfe-hygiene-global-call-name [name : String]) : String
  (if (ctfe-hygiene-global-name? (string.copy name))
    (let
      [payload : String (ctfe-hygiene-global-base name)]
      [sep : i64 (ctfe-hygiene-context-separator-index (string.copy payload))]
      (if (< sep 0)
        payload
        (let
          [start : i64 (+ sep 1)]
          (string.substring
            payload
            start
            (- (ctfe-private-string-length payload) start)))))
    name))

(define (ctfe-symbol-module-key [module : String] [name : String]) : String
  (if (= (ctfe-private-string-length module) 0)
    name
    (str_cat.str-cat module "/" name)))

(define (ctfe-module-macro-export-key-id [module-id : i64] [name-id : i64]) : i64
  (ctfe-qualified-name-key-id module-id name-id))

(define (ctfe-module-macro-export-reset-for-state!
  [state : CompilerCtfeMacroState]) : unit
  (let
    [data : CompilerCtfeMacroStateData (compiler-ctfe-macro-state-data state)]
    (begin
      (in-arena
        (arena.Arena data.map-storage-arena)
        (if (< (ctfe_key_map.capacity (& data.module-macro-export-keys)) 256)
          (set! data.module-macro-export-keys (ctfe_key_map.with-capacity 256))
          (ctfe_key_map.clear-ref! (&mut data.module-macro-export-keys))))
      (compiler-ctfe-macro-state-data-set! state data))))

(define (ctfe-module-macro-export-add-id-for-state!
  [state : CompilerCtfeMacroState]
  [module-id : i64]
  [name-id : i64]) : unit
  (let
    [data : CompilerCtfeMacroStateData (compiler-ctfe-macro-state-data state)]
    (begin
      (compiler-ctfe-key-map-grow-for-state-if-needed!
        state
        (&mut data.module-macro-export-keys))
      (ctfe_key_map.insert-ref!
        (&mut data.module-macro-export-keys)
        (ctfe-module-macro-export-key-id module-id name-id)
        1)
      (compiler-ctfe-macro-state-data-set! state data))))

(define (ctfe-module-macro-export-id-for-state?
  [state : CompilerCtfeMacroState]
  [module-id : i64]
  [name-id : i64]) : bool
  (let
    [data : CompilerCtfeMacroStateData (compiler-ctfe-macro-state-data state)]
    (ctfe_key_map.contains?
      (& data.module-macro-export-keys)
      (ctfe-module-macro-export-key-id module-id name-id))))

(define (ctfe-module-macro-export-reset!) : unit
  (ctfe-module-macro-export-reset-for-state! (compiler-ctfe-serial-macro-state)))

(define (ctfe-module-macro-export-add-id! [module-id : i64] [name-id : i64]) : unit
  (ctfe-module-macro-export-add-id-for-state!
    (compiler-ctfe-serial-macro-state)
    module-id
    name-id))

;; Public value signatures are indexed separately from CtfeEnv. Keeping this
;; reset-scoped side table avoids widening every immutable CTFE environment
;; node. Values are type-pool handles, so the map retains only two i64s per
;; public signature and identical top-level types remain hash-consed.
(defenum CtfeMaybeModuleValueType
  (None)
  (Some ast.AstType))

(define (ctfe-module-value-reflection-enable-for-state!
  [state : CompilerCtfeMacroState]
  [enabled : bool]) : unit
  (unsafe
    (set!
      (deref (compiler-ctfe-macro-state-ptr state)).module-value-reflection-enabled
      enabled)))

(define (ctfe-module-value-reset-for-state! [state : CompilerCtfeMacroState]) : unit
  (let
    [data : CompilerCtfeMacroStateData (compiler-ctfe-macro-state-data state)]
    [minimum-capacity : i64
      (if data.module-value-reflection-enabled
        1024
        1)]
    (begin
      (in-arena
        (arena.Arena data.map-storage-arena)
        (if (<
          (ctfe_key_map.capacity (& data.module-value-type-ids))
          minimum-capacity)
          (set!
            data.module-value-type-ids
            (ctfe_key_map.with-capacity minimum-capacity))
          (ctfe_key_map.clear-ref! (&mut data.module-value-type-ids))))
      (compiler-ctfe-macro-state-data-set! state data))))

(define (ctfe-module-value-add-id-for-state!
  [state : CompilerCtfeMacroState]
  [module-id : i64]
  [name-id : i64]
  [ty : ast.AstType]) : unit
  (let
    [data : CompilerCtfeMacroStateData (compiler-ctfe-macro-state-data state)]
    (if data.module-value-reflection-enabled
      (begin
        (compiler-ctfe-key-map-grow-for-state-if-needed!
          state
          (&mut data.module-value-type-ids))
        (ctfe_key_map.insert-ref!
          (&mut data.module-value-type-ids)
          (ctfe-qualified-name-key-id module-id name-id)
          (ast.ty-node-push ty))
        (compiler-ctfe-macro-state-data-set! state data))
      unit)))

(define (ctfe-module-value-type-id-for-state
  [state : CompilerCtfeMacroState]
  [module-id : i64]
  [name-id : i64]) : CtfeMaybeModuleValueType
  (let
    [data : CompilerCtfeMacroStateData (compiler-ctfe-macro-state-data state)]
    (if data.module-value-reflection-enabled
      (match (ctfe_key_map.get
        (& data.module-value-type-ids)
        (ctfe-qualified-name-key-id module-id name-id))
        [(ctfe_key_map.LookupFound type-id)
          (CtfeMaybeModuleValueType.Some (ast.ty-node-get type-id))]
        [(ctfe_key_map.LookupMissing) (CtfeMaybeModuleValueType.None)])
      (CtfeMaybeModuleValueType.None))))

(define (ctfe-reflect-info-list-add-if-missing-id
  [infos : CtfeReflectInfoList]
  [info : CtfeReflectInfo]
  [key-id : i64]) : CtfeReflectInfoList
  (if (ctfe_key_map.contains? (& infos.index) key-id)
    infos
    (ctfe-reflect-info-list-push-id infos info key-id)))

(define (ctfe-reflect-info-lookup-id-from
  [infos : (& infos CtfeReflectInfoList)]
  [key-id : i64]
  [_index : i64]) : CtfeMaybeReflectInfo
  (match (ctfe_key_map.get (& infos.index) key-id)
    [(ctfe_key_map.LookupFound slot)
      (CtfeMaybeReflectInfo.Some (ctfe-reflect-info-list-ref infos slot))]
    [(ctfe_key_map.LookupMissing) (CtfeMaybeReflectInfo.None)]))

(define (ctfe-reflect-info-lookup-name-id
  [infos : (& infos CtfeReflectInfoList)]
  [name-id : i64]) : CtfeMaybeReflectInfo
  (ctfe-reflect-info-lookup-id-from infos (ctfe-name-id-key name-id) 0))

(define (ctfe-reflect-field-def-count [fields : (& fields ast.AstFieldDefList)]) : i64
  fields.len)

(define (ctfe-reflect-field-list-from-fields-into
  [fields : (& fields ast.AstFieldDefList)]
  [index : i64]
  [out : CtfeReflectFieldList]) : CtfeReflectFieldList
  (if (>= index fields.len)
    out
    (match (ast.ast-field-def-list-get
      fields
      index
      (ast.ast-field-def-fallback))
      [(ast.AstFieldDef.Def name ty _)
        (ctfe-reflect-field-list-from-fields-into
          fields
          (+ index 1)
          (ctfe-reflect-field-list-push
            out
            (CtfeReflectField.Field (ci.intern-syntax-id-value name) ty)))])))

(define (ctfe-reflect-field-list-from-fields [fields : ast.AstFieldDefList]) : CtfeReflectFieldList
  (ctfe-reflect-field-list-from-fields-into
    (& fields)
    0
    (ctfe-reflect-field-list-with-capacity
      (ctfe-reflect-field-def-count fields))))

(define (ctfe-reflect-variant-def-count
  [variants : (& variants ast.AstVariantDefList)]) : i64
  variants.len)

(define (ctfe-reflect-variant-list-from-variants-into
  [variants : (& variants ast.AstVariantDefList)]
  [index : i64]
  [out : CtfeReflectVariantList]) : CtfeReflectVariantList
  (if (>= index variants.len)
    out
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def name payloads _)
        (ctfe-reflect-variant-list-from-variants-into
          variants
          (+ index 1)
          (ctfe-reflect-variant-list-push
            out
            (CtfeReflectVariant.Variant name payloads)))])))

(define (ctfe-reflect-variant-list-from-variants
  [variants : ast.AstVariantDefList]) : CtfeReflectVariantList
  (ctfe-reflect-variant-list-from-variants-into
    (& variants)
    0
    (ctfe-reflect-variant-list-with-capacity
      (ctfe-reflect-variant-def-count variants))))

(define (ctfe-reflect-info-add-alias
  [infos : CtfeReflectInfoList]
  [info : CtfeReflectInfo]
  [alias : String]
  [alias-id : i64]) : CtfeReflectInfoList
  (match info
    [(CtfeReflectInfo.Struct _ module name canonical-id cleanup fields markers)
      (ctfe-reflect-info-list-add-if-missing-id
        infos
        (CtfeReflectInfo.Struct
          alias
          module
          name
          canonical-id
          cleanup
          fields
          markers)
        alias-id)]
    [(CtfeReflectInfo.Enum _ module name canonical-id cleanup variants markers)
      (ctfe-reflect-info-list-add-if-missing-id
        infos
        (CtfeReflectInfo.Enum
          alias
          module
          name
          canonical-id
          cleanup
          variants
          markers)
        alias-id)]))

(define (ctfe-reflect-struct-cleanup
  [module : String]
  [module-id : i64]
  [cleanup : ast.AstStructCleanup]) : CtfeReflectCleanup
  (match cleanup
    [(ast.AstStructCleanup.No) CtfeReflectCleanup.No]
    [(ast.AstStructCleanup.Fn name)
      (CtfeReflectCleanup.Fn
        (ctfe-symbol-module-key
          (string.copy module)
          (ci.intern-syntax-name-text-or
            (ci.intern-syntax-id-value name)
            "<structural-name>"))
        (if (= (string.string-length module) 0)
          (ci.intern-syntax-id-value name)
          (ctfe-qualified-name-key-id
            module-id
            (ci.intern-syntax-id-value name))))]))

(define (ctfe-reflect-enum-cleanup
  [module : String]
  [module-id : i64]
  [cleanup : ast.AstEnumCleanup]) : CtfeReflectCleanup
  (match cleanup
    [(ast.AstEnumCleanup.No) CtfeReflectCleanup.No]
    [(ast.AstEnumCleanup.Fn name)
      (CtfeReflectCleanup.Fn
        (ctfe-symbol-module-key
          (string.copy module)
          (ci.intern-syntax-name-text-or
            (ci.intern-syntax-id-value name)
            "<structural-name>"))
        (if (= (string.string-length module) 0)
          (ci.intern-syntax-id-value name)
          (ctfe-qualified-name-key-id
            module-id
            (ci.intern-syntax-id-value name))))]))

(define (ctfe-reflect-info-add-names
  [infos : CtfeReflectInfoList]
  [info : CtfeReflectInfo]
  [key-id : i64]
  [name : String]
  [name-id : i64]
  [module : String]) : CtfeReflectInfoList
  (let
    [with-key : CtfeReflectInfoList
      (ctfe-reflect-info-list-add-if-missing-id infos (clone info) key-id)]
    (if (= (string.string-length module) 0)
      with-key
      (ctfe-reflect-info-add-alias with-key info name name-id))))

(define (ctfe-reflections-add-struct
  [infos : CtfeReflectInfoList]
  [module : String]
  [module-id : i64]
  [name : i64]
  [cleanup : ast.AstStructCleanup]
  [markers : i64]
  [repr : (& repr ast.AstStructRepr)]
  [fields : ast.AstFieldDefList]) : CtfeReflectInfoList
  (let
    [name-str : String (ci.intern-syntax-name-text-or name "<structural-name>")]
    [key : String
      (if (= (string.string-length module) 0)
        (string.copy name-str)
        (str_cat.str-cat (string.copy module) "/" (string.copy name-str)))]
    [key-id : i64
      (if (= (string.string-length module) 0)
        name
        (ctfe-qualified-name-key-id module-id name))]
    [info : CtfeReflectInfo
      (CtfeReflectInfo.Struct
        key
        (string.copy module)
        (string.copy name-str)
        key-id
        (ctfe-reflect-struct-cleanup (string.copy module) module-id cleanup)
        (ctfe-reflect-field-list-from-fields
          (ast.ast-global-shared-view fields))
        markers)]
    [with-aligns : CtfeReflectInfoList
      (if (and
        (ast.ast-struct-repr-declares-align? repr)
        (not (ctfe_key_map.contains? (& infos.index) key-id)))
        (ctfe-reflect-info-list-add-aligns infos key-id repr fields.len)
        infos)]
    (ctfe-reflect-info-add-names with-aligns info key-id name-str name module)))

(define (ctfe-reflections-add-enum
  [infos : CtfeReflectInfoList]
  [module : String]
  [module-id : i64]
  [name : i64]
  [cleanup : ast.AstEnumCleanup]
  [markers : i64]
  [variants : ast.AstVariantDefList]) : CtfeReflectInfoList
  (let
    [name-str : String (ci.intern-syntax-name-text-or name "<structural-name>")]
    [key : String
      (if (= (string.string-length module) 0)
        (string.copy name-str)
        (str_cat.str-cat (string.copy module) "/" (string.copy name-str)))]
    [key-id : i64
      (if (= (string.string-length module) 0)
        name
        (ctfe-qualified-name-key-id module-id name))]
    [info : CtfeReflectInfo
      (CtfeReflectInfo.Enum
        key
        (string.copy module)
        (string.copy name-str)
        key-id
        (ctfe-reflect-enum-cleanup (string.copy module) module-id cleanup)
        (ctfe-reflect-variant-list-from-variants variants)
        markers)]
    (ctfe-reflect-info-add-names infos info key-id name-str name module)))

(define (ctfe-reflections-from-decls
  [decls : ast.AstDeclList]
  [module : String]
  [module-id : i64]
  [infos : CtfeReflectInfoList]) : CtfeReflectInfoList
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [index : i64 0]
    [current-module : String module]
    [current-module-id : i64 module-id]
    [current-infos : CtfeReflectInfoList infos]
    ;; One match on the backing slot instead of a borrowed tag test followed by
    ;; an `ast-decl-list-ref` re-read: the SRET read copied the whole 104 B row
    ;; for every declaration that passed the test, and the borrowed test was a
    ;; second out-of-line call. A match on the slot projection loads the tag and
    ;; only the fields an arm binds.
    [decl-slots : (__tl_dyn-array ast.AstDecl) decls.slots]
    [decl-offset : i64 decls.offset]
    (begin
      (while (< index count)
        (begin
          (match (array-ref decl-slots (+ decl-offset index))
            [(ast.AstDecl.Module next-module)
              (begin
                (set!
                  current-module
                  (ci.intern-syntax-name-text-or
                    next-module
                    "<structural-module>"))
                (set! current-module-id next-module))]
            [(ast.AstDecl.DefStruct decl-meta name repr cleanup fields)
              (set!
                current-infos
                (ctfe-reflections-add-struct
                  current-infos
                  (string.copy current-module)
                  current-module-id
                  name
                  cleanup
                  (ast.ast-decl-meta-aggregate-markers decl-meta)
                  (& repr)
                  fields))]
            [(ast.AstDecl.DefStructLifetimes
                decl-meta
                name
                _
                repr
                cleanup
                fields)
              (set!
                current-infos
                (ctfe-reflections-add-struct
                  current-infos
                  (string.copy current-module)
                  current-module-id
                  name
                  cleanup
                  (ast.ast-decl-meta-aggregate-markers decl-meta)
                  (& repr)
                  fields))]
            [(ast.AstDecl.DefEnum decl-meta name cleanup variants)
              (set!
                current-infos
                (ctfe-reflections-add-enum
                  current-infos
                  (string.copy current-module)
                  current-module-id
                  name
                  cleanup
                  (ast.ast-decl-meta-aggregate-markers decl-meta)
                  variants))]
            [(ast.AstDecl.DefEnumLifetimes decl-meta name _ cleanup variants)
              (set!
                current-infos
                (ctfe-reflections-add-enum
                  current-infos
                  (string.copy current-module)
                  current-module-id
                  name
                  cleanup
                  (ast.ast-decl-meta-aggregate-markers decl-meta)
                  variants))]
            [_ unit])
          (set! index (+ index 1))))
      current-infos)))

(define (ctfe-metadata-decl-capacity [decls : ast.AstDeclList]) : i64
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [index : i64 0]
    [capacity : i64 1]
    (begin
      (while (< index count)
        (begin
          (match (ast.ast-decl-list-ref-borrowed (& decls) index)
            [(ast.AstDecl.DefStruct decl-meta _ _ _ _)
              (set! capacity (+ capacity 2))]
            [(ast.AstDecl.DefStructLifetimes decl-meta _ _ _ _ _)
              (set! capacity (+ capacity 2))]
            [(ast.AstDecl.DefEnum decl-meta _ _ _)
              (set! capacity (+ capacity 2))]
            [(ast.AstDecl.DefEnumLifetimes decl-meta _ _ _ _)
              (set! capacity (+ capacity 2))]
            [_ unit])
          (set! index (+ index 1))))
      capacity)))

(define (ctfe-reflections-from-program [program : ast.AstProgram]) : CtfeReflectInfoList
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        [capacity : i64 (ctfe-metadata-decl-capacity (clone decls))]
        (begin
          (ctfe-build-seen-reset!)
          (ctfe-reflections-from-decls
            decls
            ""
            cbi.compiler-builtin-id-fix-empty
            (ctfe-reflect-info-list-with-capacity
              ;; Splice extension grows this owner-arena vector geometrically;
              ;; reserve only the known program surface here.
              capacity))))]))

;; Result of evaluating a sub-expression: either a value (carrying the remaining
;; fuel) or a diagnostic. Fuel is threaded so each evaluation step decrements a
;; shared budget across all sub-evaluations.
(defenum ResultCtfe
  (Ok CompilerCtfeValue i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum CtfePatternMatch
  (No)
  (Matched CtfeEnv))

(defenum ResultCtfeQuoteExpr
  (Ok i64 ast.AstType i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeQuoteExprList
  (Ok ast.AstExprList i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeQuoteType
  (Ok ast.AstType i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeQuoteTypeList
  (Ok ast.AstTypeList i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeQuoteLifetimeList
  (Ok ast.AstLifetimeList)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeQuoteMaybeType
  (Ok ast.AstMaybeType i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeQuoteParams
  (Ok ast.AstParamList i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeQuoteParamsBuild
  (Ok i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeQuoteLetBindings
  (Ok ast.AstLetBindingList i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeQuoteLetBindingsBuild
  (Ok i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeQuoteResourceBindings
  (Ok ast.AstResourceBindingList i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeQuoteResourceBindingsBuild
  (Ok i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeQuoteArms
  (Ok ast.AstMatchArmList i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeQuoteArmsBuild
  (Ok i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(define (ctfe-fuel-limit) : i64
  100000)

(define (ctfe-fuel-diagnostic-message) : String
  (comptime_diagnostics.compiler-comptime-fuel-diagnostic-message))

;; Build a diagnostic anchored at the (possibly spanned) expression.
(define (ctfe-diagnostic-at-expr [expr : ast.AstExpr] [message : String]) : cdiag.CompilerDiagnostic
  (match expr
    [(ast.AstExpr.Spanned _ span)
      (cdiag.compiler-diagnostic-from-ast-span "" span message)]
    [_ (cdiag.compiler-diagnostic-at-start "" message)]))

;; Human-readable tag for the unsupported-form diagnostic.
(define (ctfe-describe-expr [expr : ast.AstExpr]) : String
  (match expr
    [(ast.AstExpr.Spanned _ _) "expression"]
    [(ast.AstExpr.MacroExpansion _ _ _) "macro expansion"]
    [(ast.AstExpr.Literal _) "literal"]
    [(ast.AstExpr.Var _) "variable reference"]
    [(ast.AstExpr.Binary _ _ _) "binary operation"]
    [(ast.AstExpr.Unary _ _) "unary operation"]
    [(ast.AstExpr.Call _ _) "function call"]
    [(ast.AstExpr.BracketClause _) "bracket clause"]
    [(ast.AstExpr.TypeLiteral _) "type literal"]
    [(ast.AstExpr.If _ _ _) "if"]
    [(ast.AstExpr.Let _) "let"]
    [(ast.AstExpr.Lambda _) "lambda"]
    [(ast.AstExpr.Tuple _) "tuple"]
    [(ast.AstExpr.TupleRef _ _) "tuple-ref"]
    [(ast.AstExpr.Array _) "array"]
    [(ast.AstExpr.DynArray _) "__tl_make-array"]
    [(ast.AstExpr.FixedMakeArray _ _) "make-array"]
    [(ast.AstExpr.MakeArray _ _) "__tl_make-array"]
    [(ast.AstExpr.ArrayRef _ _) "array-ref"]
    [(ast.AstExpr.ArraySet _ _ _) "array-set!"]
    [(ast.AstExpr.ArrayTake _ _ _) "__tl_array-take!"]
    [(ast.AstExpr.Replace _ _) "replace!"]
    [(ast.AstExpr.ArrayPush _ _) "__tl_array-push!"]
    [(ast.AstExpr.StringRef _ _) "string-ref"]
    [(ast.AstExpr.While _ _) "while"]
    [(ast.AstExpr.ForOwnedState _) "scalar for owned-array state"]
    [(ast.AstExpr.ForOwnedStep _) "scalar for owned-array step"]
    [(ast.AstExpr.Begin _) "begin"]
    [(ast.AstExpr.Unsafe _) "unsafe"]
    [(ast.AstExpr.Set _ _) "set!"]
    [(ast.AstExpr.Ann _ _) "type annotation"]
    [(ast.AstExpr.Cast _ _) "cast"]
    [(ast.AstExpr.Borrow mutable _ _)
      (if mutable
        "mutable borrow"
        "borrow")]
    [(ast.AstExpr.Match _) "match"]
    [(ast.AstExpr.Foreach _) "foreach"]
    [(ast.AstExpr.SpmdReduce _) "spmd-reduce"]
    [(ast.AstExpr.SpmdScan _) "spmd-scan"]
    [(ast.AstExpr.SpmdCompact _) "spmd-compact"]
    [(ast.AstExpr.SpmdBroadcast _ _) "spmd-broadcast"]
    [(ast.AstExpr.SpmdShuffle _ _) "spmd-shuffle"]
    [(ast.AstExpr.SpmdProgramIndex) "program-index"]
    [(ast.AstExpr.SpmdProgramCount) "program-count"]
    [(ast.AstExpr.ForeachActive _ _) "foreach-active"]
    [(ast.AstExpr.LaneValue _) "lane-value"]
    [(ast.AstExpr.StructGet _ _) "struct-get"]
    [(ast.AstExpr.StructSet _ _ _) "set!"]
    [(ast.AstExpr.WithRegion _ _) "with-arena"]
    [(ast.AstExpr.WithEscape _ _) "with-escape"]
    [(ast.AstExpr.WithScratch _) "with-scratch"]
    [(ast.AstExpr.InArena _ _) "in-arena"]
    [(ast.AstExpr.WithResource _) "with"]
    [(ast.AstExpr.Init _) "init"]
    [(ast.AstExpr.Comptime _) "comptime"]
    [(ast.AstExpr.Quote _) "quote"]
    [(ast.AstExpr.Quasiquote _) "quasiquote"]
    [(ast.AstExpr.Unquote _) "unquote"]
    [(ast.AstExpr.UnquoteSplicing _) "unquote-splicing"]
    [(ast.AstExpr.Try _) "try"]
    [(ast.AstExpr.Return _) "return"]
    [(ast.AstExpr.Break) "break"]
    [(ast.AstExpr.Continue) "continue"]
    [(ast.AstExpr.PtrNull _) "ptr-null"]
    [(ast.AstExpr.PtrNullCheck _) "ptr-null?"]
    [(ast.AstExpr.PtrAddrOf _) "ptr-addr-of"]
    [(ast.AstExpr.PtrRead _) "ptr-read"]
    [(ast.AstExpr.PtrWrite _ _) "ptr-write!"]
    [(ast.AstExpr.PtrOffset _ _) "ptr-offset"]
    [(ast.AstExpr.PtrCast _ _) "ptr-cast"]
    [(ast.AstExpr.PtrToInt _) "ptr->int"]
    [(ast.AstExpr.IntToPtr _ _) "int->ptr"]
    [(ast.AstExpr.Box _) "box"]
    [(ast.AstExpr.BoxGet _) "box-get"]
    [(ast.AstExpr.BoxTake _) "box-take"]
    [(ast.AstExpr.BoxSet _ _) "set!"]
    [(ast.AstExpr.StringData _) "string-data"]
    [(ast.AstExpr.StringFromBytes _ _) "string-from-bytes"]
    [(ast.AstExpr.ArrayData _) "__tl_array-data"]
    [(ast.AstExpr.BinaryData _) "binary-data"]
    [(ast.AstExpr.ProgramArgc) "program-argc"]
    [(ast.AstExpr.ProgramArgv) "program-argv"]
    [(ast.AstExpr.ProgramEnvp) "program-envp"]
    [(ast.AstExpr.CpuIdEax _ _) "cpuid-eax"]
    [(ast.AstExpr.CpuIdEbx _ _) "cpuid-ebx"]
    [(ast.AstExpr.CpuIdEcx _ _) "cpuid-ecx"]
    [(ast.AstExpr.CpuIdEdx _ _) "cpuid-edx"]
    [(ast.AstExpr.Xgetbv _) "xgetbv"]
    [(ast.AstExpr.Syscall _) "syscall"]))

;; Promote a char to its i64 code point so the i64 comparison primitives drive
;; char ordering/equality, matching Rust's code-point comparison.
(define (ctfe-char-code [c : char]) : i64
  (cast c : i64))

;; --- literals ---------------------------------------------------------------
(define (ctfe-eval-literal
  [lit : ast.AstLiteral]
  [expr : ast.AstExpr]
  [session : cis.InternStructuralSessionHandle]
  [fuel : i64]) : ResultCtfe
  (match lit
    [(ast.AstLiteral.Int n text)
      (ResultCtfe.Ok
        (CompilerCtfeValue.I64 (ast.ast-int-literal-value-or-payload n text))
        fuel)]
    [(ast.AstLiteral.Bool b) (ResultCtfe.Ok (CompilerCtfeValue.Bool b) fuel)]
    [(ast.AstLiteral.Char c) (ResultCtfe.Ok (CompilerCtfeValue.Char c) fuel)]
    [(ast.AstLiteral.Unit) (ResultCtfe.Ok (CompilerCtfeValue.Unit) fuel)]
    [(ast.AstLiteral.Float text)
      (match (cfloat.compiler-float-parse-f64 (string.copy text))
        [(CompilerFloatSomeF64 value)
          (if (cfloat.compiler-float-f64-finite? value)
            (ResultCtfe.Ok (CompilerCtfeValue.F64 value) fuel)
            (ResultCtfe.Err
              (box
                (ctfe-diagnostic-at-expr
                  expr
                  (cdiag.compiler-diagnostic-typecheck-tagged
                    (cdiag.CompilerTypecheckKind.TypeMismatch)
                    "comptime: non-finite f64 literal is not supported")))))]
        [(CompilerFloatNoF64)
          (if (cfloat.compiler-float-decimal-syntax? text)
            (ResultCtfe.Err
              (box
                (ctfe-diagnostic-at-expr
                  expr
                  (cdiag.compiler-diagnostic-typecheck-tagged
                    (cdiag.CompilerTypecheckKind.TypeMismatch)
                    "comptime: non-finite f64 literal is not supported"))))
            (ResultCtfe.Err
              (box
                (ctfe-diagnostic-at-expr expr "comptime: invalid f64 literal"))))])]
    [(ast.AstLiteral.String string-id)
      (ResultCtfe.Ok
        (ctfe-source-string-value-for-session session string-id)
        fuel)]))

;; --- binary operators -------------------------------------------------------
;; i64 arithmetic/bitwise/shift and i64 comparisons.
(define (ctfe-eval-bin-i64
  [op : ast.AstBinOp]
  [a : i64]
  [b : i64]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(ast.AstBinOp.Add) (ResultCtfe.Ok (CompilerCtfeValue.I64 (+ a b)) fuel)]
    [(ast.AstBinOp.Sub) (ResultCtfe.Ok (CompilerCtfeValue.I64 (- a b)) fuel)]
    [(ast.AstBinOp.Mul) (ResultCtfe.Ok (CompilerCtfeValue.I64 (* a b)) fuel)]
    [(ast.AstBinOp.Div)
      (if (= b 0)
        (ResultCtfe.Err
          (box (ctfe-diagnostic-at-expr expr "division by zero in comptime")))
        (ResultCtfe.Ok (CompilerCtfeValue.I64 (/ a b)) fuel))]
    [(ast.AstBinOp.Mod)
      (if (= b 0)
        (ResultCtfe.Err
          (box (ctfe-diagnostic-at-expr expr "modulo by zero in comptime")))
        (ResultCtfe.Ok (CompilerCtfeValue.I64 (% a b)) fuel))]
    [(ast.AstBinOp.Eq) (ResultCtfe.Ok (CompilerCtfeValue.Bool (= a b)) fuel)]
    [(ast.AstBinOp.Ne) (ResultCtfe.Ok (CompilerCtfeValue.Bool (!= a b)) fuel)]
    [(ast.AstBinOp.Lt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (< a b)) fuel)]
    [(ast.AstBinOp.Le) (ResultCtfe.Ok (CompilerCtfeValue.Bool (<= a b)) fuel)]
    [(ast.AstBinOp.Gt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (> a b)) fuel)]
    [(ast.AstBinOp.Ge) (ResultCtfe.Ok (CompilerCtfeValue.Bool (>= a b)) fuel)]
    [(ast.AstBinOp.BitAnd)
      (ResultCtfe.Ok (CompilerCtfeValue.I64 (bit-and a b)) fuel)]
    [(ast.AstBinOp.BitOr)
      (ResultCtfe.Ok (CompilerCtfeValue.I64 (bit-or a b)) fuel)]
    [(ast.AstBinOp.BitXor)
      (ResultCtfe.Ok (CompilerCtfeValue.I64 (bit-xor a b)) fuel)]
    [(ast.AstBinOp.Shl) (ResultCtfe.Ok (CompilerCtfeValue.I64 (shl a b)) fuel)]
    [(ast.AstBinOp.Shr) (ResultCtfe.Ok (CompilerCtfeValue.I64 (shr a b)) fuel)]
    [(ast.AstBinOp.And)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "'and' in comptime requires bool operands")))]
    [(ast.AstBinOp.Or)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "'or' in comptime requires bool operands")))]))

(define (ctfe-f64-result [value : f64] [expr : ast.AstExpr] [fuel : i64]) : ResultCtfe
  (if (cfloat.compiler-float-f64-finite? value)
    (ResultCtfe.Ok (CompilerCtfeValue.F64 value) fuel)
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.TypeMismatch)
            "comptime: non-finite f64 result is not supported"))))))

(define (ctfe-f32-result [value : f64] [expr : ast.AstExpr] [fuel : i64]) : ResultCtfe
  (let
    [rounded : f64 (cfloat.compiler-float-round-f32-as-f64 value)]
    (if (cfloat.compiler-float-f64-finite? rounded)
      (ResultCtfe.Ok (CompilerCtfeValue.F32 rounded) fuel)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            (cdiag.compiler-diagnostic-typecheck-tagged
              (cdiag.CompilerTypecheckKind.TypeMismatch)
              "comptime: non-finite f32 result is not supported")))))))

;; Finite f64 arithmetic and comparisons. Non-finite results are rejected until
;; TypeLisp specifies NaN payload and infinity serialization across backends.
(define (ctfe-eval-bin-f64
  [op : ast.AstBinOp]
  [a : f64]
  [b : f64]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(ast.AstBinOp.Add) (ctfe-f64-result (+ a b) expr fuel)]
    [(ast.AstBinOp.Sub) (ctfe-f64-result (- a b) expr fuel)]
    [(ast.AstBinOp.Mul) (ctfe-f64-result (* a b) expr fuel)]
    [(ast.AstBinOp.Div)
      (if (= b 0.0)
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr expr "float division by zero in comptime")))
        (ctfe-f64-result (/ a b) expr fuel))]
    [(ast.AstBinOp.Eq) (ResultCtfe.Ok (CompilerCtfeValue.Bool (= a b)) fuel)]
    [(ast.AstBinOp.Ne) (ResultCtfe.Ok (CompilerCtfeValue.Bool (!= a b)) fuel)]
    [(ast.AstBinOp.Lt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (< a b)) fuel)]
    [(ast.AstBinOp.Le) (ResultCtfe.Ok (CompilerCtfeValue.Bool (<= a b)) fuel)]
    [(ast.AstBinOp.Gt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (> a b)) fuel)]
    [(ast.AstBinOp.Ge) (ResultCtfe.Ok (CompilerCtfeValue.Bool (>= a b)) fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on f64 in compile-time evaluation")))]))

(define (ctfe-eval-bin-f32
  [op : ast.AstBinOp]
  [a : f64]
  [b : f64]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(ast.AstBinOp.Add) (ctfe-f32-result (+ a b) expr fuel)]
    [(ast.AstBinOp.Sub) (ctfe-f32-result (- a b) expr fuel)]
    [(ast.AstBinOp.Mul) (ctfe-f32-result (* a b) expr fuel)]
    [(ast.AstBinOp.Div)
      (if (= b 0.0)
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr expr "float division by zero in comptime")))
        (ctfe-f32-result (/ a b) expr fuel))]
    [(ast.AstBinOp.Eq) (ResultCtfe.Ok (CompilerCtfeValue.Bool (= a b)) fuel)]
    [(ast.AstBinOp.Ne) (ResultCtfe.Ok (CompilerCtfeValue.Bool (!= a b)) fuel)]
    [(ast.AstBinOp.Lt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (< a b)) fuel)]
    [(ast.AstBinOp.Le) (ResultCtfe.Ok (CompilerCtfeValue.Bool (<= a b)) fuel)]
    [(ast.AstBinOp.Gt) (ResultCtfe.Ok (CompilerCtfeValue.Bool (> a b)) fuel)]
    [(ast.AstBinOp.Ge) (ResultCtfe.Ok (CompilerCtfeValue.Bool (>= a b)) fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on f32 in compile-time evaluation")))]))

;; bool comparisons and boolean connectives.
(define (ctfe-eval-bin-bool
  [op : ast.AstBinOp]
  [a : bool]
  [b : bool]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(ast.AstBinOp.Eq)
      (ResultCtfe.Ok
        (CompilerCtfeValue.Bool (or (and a b) (and (not a) (not b))))
        fuel)]
    [(ast.AstBinOp.Ne)
      (ResultCtfe.Ok
        (CompilerCtfeValue.Bool (not (or (and a b) (and (not a) (not b)))))
        fuel)]
    [(ast.AstBinOp.And) (ResultCtfe.Ok (CompilerCtfeValue.Bool (and a b)) fuel)]
    [(ast.AstBinOp.Or) (ResultCtfe.Ok (CompilerCtfeValue.Bool (or a b)) fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on bool in compile-time evaluation")))]))

;; char comparisons via code-point ordering.
(define (ctfe-eval-bin-char
  [op : ast.AstBinOp]
  [a : char]
  [b : char]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (let
    [ca : i64 (ctfe-char-code a)]
    [cb : i64 (ctfe-char-code b)]
    (match op
      [(ast.AstBinOp.Eq)
        (ResultCtfe.Ok (CompilerCtfeValue.Bool (= ca cb)) fuel)]
      [(ast.AstBinOp.Ne)
        (ResultCtfe.Ok (CompilerCtfeValue.Bool (!= ca cb)) fuel)]
      [(ast.AstBinOp.Lt)
        (ResultCtfe.Ok (CompilerCtfeValue.Bool (< ca cb)) fuel)]
      [(ast.AstBinOp.Le)
        (ResultCtfe.Ok (CompilerCtfeValue.Bool (<= ca cb)) fuel)]
      [(ast.AstBinOp.Gt)
        (ResultCtfe.Ok (CompilerCtfeValue.Bool (> ca cb)) fuel)]
      [(ast.AstBinOp.Ge)
        (ResultCtfe.Ok (CompilerCtfeValue.Bool (>= ca cb)) fuel)]
      [_
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr
              expr
              "this operation is not supported on char in compile-time evaluation")))])))

;; string comparisons (only `==`/`!=`).
(define (ctfe-eval-bin-string
  [op : ast.AstBinOp]
  [a : String]
  [b : String]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(ast.AstBinOp.Eq)
      (ResultCtfe.Ok (CompilerCtfeValue.Bool (string.eq a b)) fuel)]
    [(ast.AstBinOp.Ne)
      (ResultCtfe.Ok (CompilerCtfeValue.Bool (not (string.eq a b))) fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on String in compile-time evaluation")))]))

;; unit comparisons (only `==`/`!=`).
(define (ctfe-eval-bin-unit
  [op : ast.AstBinOp]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(ast.AstBinOp.Eq) (ResultCtfe.Ok (CompilerCtfeValue.Bool true) fuel)]
    [(ast.AstBinOp.Ne) (ResultCtfe.Ok (CompilerCtfeValue.Bool false) fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on unit in compile-time evaluation")))]))

(define (ctfe-eval-bin-type-info
  [op : ast.AstBinOp]
  [a : ast.AstType]
  [b : ast.AstType]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match op
    [(ast.AstBinOp.Eq)
      (ResultCtfe.Ok
        (CompilerCtfeValue.Bool (ctfe-type-eq-in-env env a b))
        fuel)]
    [(ast.AstBinOp.Ne)
      (ResultCtfe.Ok
        (CompilerCtfeValue.Bool (not (ctfe-type-eq-in-env env a b)))
        fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on TypeInfo in compile-time evaluation")))]))

(define (ctfe-eval-bin-comptime-metadata [label : String] [expr : ast.AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        (str_cat.str-cat
          "this operation is not supported on "
          label
          " in compile-time evaluation")))))

;; Dispatch a binary op over two already-evaluated operands.
(define (ctfe-apply-binop
  [op : ast.AstBinOp]
  [lv : CompilerCtfeValue]
  [rv : CompilerCtfeValue]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match lv
    [(CompilerCtfeValue.I64 a)
      (match rv
        [(CompilerCtfeValue.I64 b) (ctfe-eval-bin-i64 op a b expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                (ctfe-expr-shared-view expr)
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.F64 a)
      (match rv
        [(CompilerCtfeValue.F64 b) (ctfe-eval-bin-f64 op a b expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.F32 a)
      (match rv
        [(CompilerCtfeValue.F32 b) (ctfe-eval-bin-f32 op a b expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.Bool a)
      (match rv
        [(CompilerCtfeValue.Bool b) (ctfe-eval-bin-bool op a b expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.Char a)
      (match rv
        [(CompilerCtfeValue.Char b) (ctfe-eval-bin-char op a b expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.String a _)
      (match rv
        [(CompilerCtfeValue.String b _) (ctfe-eval-bin-string op a b expr fuel)]
        [(CompilerCtfeValue.Name b _) (ctfe-eval-bin-string op a b expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.Name a _)
      (match rv
        [(CompilerCtfeValue.String b _) (ctfe-eval-bin-string op a b expr fuel)]
        [(CompilerCtfeValue.Name b _) (ctfe-eval-bin-string op a b expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.Unit)
      (match rv
        [(CompilerCtfeValue.Unit) (ctfe-eval-bin-unit op expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.Type a)
      (match rv
        [(CompilerCtfeValue.Type b)
          (match op
            [(ast.AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool (ctfe-type-eq-in-env env a b))
                fuel)]
            [(ast.AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool (not (ctfe-type-eq-in-env env a b)))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on type in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.Expr a a-ty)
      (match rv
        [(CompilerCtfeValue.Expr b b-ty)
          (match op
            [(ast.AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (and
                    (ctfe-expr-eq-in-env
                      env
                      (ctfe-ast-get env a)
                      (ctfe-ast-get env b))
                    (ctfe-type-eq-in-env env a-ty b-ty)))
                fuel)]
            [(ast.AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (not
                    (and
                      (ctfe-expr-eq-in-env
                        env
                        (ctfe-ast-get env a)
                        (ctfe-ast-get env b))
                      (ctfe-type-eq-in-env env a-ty b-ty))))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on expr in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.CapturedExpr _ _ _)
      (ctfe-eval-bin-comptime-metadata "Expr" expr)]
    [(CompilerCtfeValue.ExprList a)
      (match rv
        [(CompilerCtfeValue.ExprList b)
          (match op
            [(ast.AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool (ctfe-expr-list-eq-in-env env a b))
                fuel)]
            [(ast.AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (not (ctfe-expr-list-eq-in-env env a b)))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on expr-list in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.CapturedExprList _ _)
      (ctfe-eval-bin-comptime-metadata "ExprList" expr)]
    [(CompilerCtfeValue.ExprClause a)
      (match rv
        [(CompilerCtfeValue.ExprClause b)
          (match op
            [(ast.AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool (ctfe-expr-clause-eq-in-env env a b))
                fuel)]
            [(ast.AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (not (ctfe-expr-clause-eq-in-env env a b)))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on expr-clause in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.CapturedExprClause _ _)
      (ctfe-eval-bin-comptime-metadata "ExprClause" expr)]
    [(CompilerCtfeValue.ExprClauseList a)
      (match rv
        [(CompilerCtfeValue.ExprClauseList b)
          (match op
            [(ast.AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (ctfe-expr-clause-list-eq-in-env env a b))
                fuel)]
            [(ast.AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (not (ctfe-expr-clause-list-eq-in-env env a b)))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on expr-clause-list in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.CapturedExprClauseList _ _)
      (ctfe-eval-bin-comptime-metadata "ExprClauseList" expr)]
    [(CompilerCtfeValue.ExprBindingClause a)
      (match rv
        [(CompilerCtfeValue.ExprBindingClause b)
          (match op
            [(ast.AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (ctfe-expr-binding-clause-eq-in-env env a b))
                fuel)]
            [(ast.AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (not (ctfe-expr-binding-clause-eq-in-env env a b)))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on expr-binding-clause in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.ExprBindingClauseList a)
      (match rv
        [(CompilerCtfeValue.ExprBindingClauseList b)
          (match op
            [(ast.AstBinOp.Eq)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (ctfe-expr-binding-clause-list-eq-in-env env a b))
                fuel)]
            [(ast.AstBinOp.Ne)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (not (ctfe-expr-binding-clause-list-eq-in-env env a b)))
                fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "this operation is not supported on expr-binding-clause-list in compile-time evaluation")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.Pattern _)
      (ctfe-eval-bin-comptime-metadata "Pattern" expr)]
    [(CompilerCtfeValue.PatternList _)
      (ctfe-eval-bin-comptime-metadata "PatternList" expr)]
    [(CompilerCtfeValue.MatchArm _)
      (ctfe-eval-bin-comptime-metadata "MatchArm" expr)]
    [(CompilerCtfeValue.MatchArmList _)
      (ctfe-eval-bin-comptime-metadata "MatchArmList" expr)]
    [(CompilerCtfeValue.LetBinding _)
      (ctfe-eval-bin-comptime-metadata "LetBinding" expr)]
    [(CompilerCtfeValue.LetBindingList _)
      (ctfe-eval-bin-comptime-metadata "LetBindingList" expr)]
    [(CompilerCtfeValue.TypeInfo a)
      (match rv
        [(CompilerCtfeValue.TypeInfo b)
          (ctfe-eval-bin-type-info op a b expr env fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.TypeInfoBox a)
      (match rv
        [(CompilerCtfeValue.TypeInfoBox b)
          (ctfe-eval-bin-type-info op a b expr env fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "binary operation in comptime requires matching operand types")))])]
    [(CompilerCtfeValue.TypeInfoList _)
      (ctfe-eval-bin-comptime-metadata "TypeInfoList" expr)]
    [(CompilerCtfeValue.TypeField _ _)
      (ctfe-eval-bin-comptime-metadata "TypeField" expr)]
    [(CompilerCtfeValue.TypeFieldList _)
      (ctfe-eval-bin-comptime-metadata "TypeFieldList" expr)]
    [(CompilerCtfeValue.TypeVariantPayload _)
      (ctfe-eval-bin-comptime-metadata "TypeVariantPayload" expr)]
    [(CompilerCtfeValue.TypeVariantPayloadList _)
      (ctfe-eval-bin-comptime-metadata "TypeVariantPayloadList" expr)]
    [(CompilerCtfeValue.TypeVariant _ _)
      (ctfe-eval-bin-comptime-metadata "TypeVariant" expr)]
    [(CompilerCtfeValue.TypeVariantList _)
      (ctfe-eval-bin-comptime-metadata "TypeVariantList" expr)]))

;; --- unary operators --------------------------------------------------------
(define (ctfe-apply-unop
  [op : ast.AstUnOp]
  [v : CompilerCtfeValue]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(ast.AstUnOp.Neg)
      (match v
        [(CompilerCtfeValue.I64 n)
          (ResultCtfe.Ok (CompilerCtfeValue.I64 (- 0 n)) fuel)]
        [(CompilerCtfeValue.F64 n) (ctfe-f64-result (- 0.0 n) expr fuel)]
        [(CompilerCtfeValue.F32 n) (ctfe-f32-result (- 0.0 n) expr fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "negation in comptime requires a numeric type")))])]
    [(ast.AstUnOp.Not)
      (match v
        [(CompilerCtfeValue.Bool b)
          (ResultCtfe.Ok (CompilerCtfeValue.Bool (not b)) fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr expr "'not' in comptime requires bool")))])]
    [(ast.AstUnOp.BitNot)
      (match v
        [(CompilerCtfeValue.I64 n)
          (ResultCtfe.Ok (CompilerCtfeValue.I64 (bit-not n)) fuel)]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "bitwise not in comptime requires i64")))])]))

(define (ctfe-value-default-cast-type
  [pools : ast.AstNodePoolContext]
  [value : (& value CompilerCtfeValue)]) : ast.AstType
  (match value
    [(CompilerCtfeValue.I64 _) (ast.AstType.I64)]
    [(CompilerCtfeValue.F64 _) (ast.AstType.F64)]
    [(CompilerCtfeValue.F32 _) (ast.AstType.F32)]
    [(CompilerCtfeValue.Char _) (ast.AstType.Char)]
    [(CompilerCtfeValue.Pattern _)
      (ctfe-stdlib-comptime-type-id cbi.compiler-builtin-id-fix-Pattern)]
    [(CompilerCtfeValue.PatternList _)
      (ctfe-stdlib-comptime-type-id cbi.compiler-builtin-id-fix-PatternList)]
    [(CompilerCtfeValue.MatchArm _)
      (ctfe-stdlib-comptime-type-id cbi.compiler-builtin-id-fix-MatchArm)]
    [(CompilerCtfeValue.MatchArmList _)
      (ctfe-stdlib-comptime-type-id cbi.compiler-builtin-id-fix-MatchArmList)]
    [(CompilerCtfeValue.TypeInfo _) (ctfe-type-info-source-type)]
    [(CompilerCtfeValue.TypeInfoBox _) (ctfe-type-info-box-source-type pools)]
    [(CompilerCtfeValue.TypeInfoList _)
      (ctfe-stdlib-comptime-type-id cbi.compiler-builtin-id-fix-TypeInfoList)]
    [(CompilerCtfeValue.TypeField _ _)
      (ctfe-stdlib-comptime-type-id cbi.compiler-builtin-id-fix-TypeField)]
    [(CompilerCtfeValue.TypeFieldList _)
      (ctfe-stdlib-comptime-type-id cbi.compiler-builtin-id-fix-TypeFieldList)]
    [(CompilerCtfeValue.TypeVariantPayload _)
      (ctfe-stdlib-comptime-type-id
        cbi.compiler-builtin-id-fix-TypeVariantPayload)]
    [(CompilerCtfeValue.TypeVariantPayloadList _)
      (ctfe-stdlib-comptime-type-id
        cbi.compiler-builtin-id-fix-TypeVariantPayloadList)]
    [(CompilerCtfeValue.TypeVariant _ _)
      (ctfe-stdlib-comptime-type-id cbi.compiler-builtin-id-fix-TypeVariant)]
    [(CompilerCtfeValue.TypeVariantList _)
      (ctfe-stdlib-comptime-type-id cbi.compiler-builtin-id-fix-TypeVariantList)]
    [_ (ast.AstType.Unit)]))

(define (ctfe-cast-source-type
  [inner : ast.AstExpr]
  [value : CompilerCtfeValue]
  [env : CtfeEnv]) : ast.AstType
  (match inner
    [(ast.AstExpr.Spanned inner-box _)
      (ctfe-cast-source-type (ctfe-ast-get env inner-box) value env)]
    [(ast.AstExpr.MacroExpansion inner-box _ _)
      (ctfe-cast-source-type (ctfe-ast-get env inner-box) value env)]
    [(ast.AstExpr.Ann _ ty-id) (ctfe-ty-get env ty-id)]
    [(ast.AstExpr.Cast _ ty-id) (ctfe-ty-get env ty-id)]
    [(ast.AstExpr.Var name)
      (match (ctfe-env-lookup-type-id env name)
        [(ast.AstMaybeType.Some ty) ty]
        [(ast.AstMaybeType.No)
          (ctfe-value-default-cast-type (ctfe-env-pools env) (& value))])]
    [_ (ctfe-value-default-cast-type (ctfe-env-pools env) (& value))]))

(define (ctfe-binding-type
  [maybe-ty : ast.AstMaybeType]
  [fallback : ast.AstType]
  [env : (& env CtfeEnv)]) : ast.AstType
  (let
    [reflections : CtfeReflectInfoList (ctfe-env-reflections env)]
    (match maybe-ty
      [(ast.AstMaybeType.Some ty)
        (ctfe-reflect-resolve-type-with-pools
          (ctfe-env-pools env)
          reflections
          ty)]
      [(ast.AstMaybeType.No) fallback])))

(define (ctfe-finite-cast-input [value : CompilerCtfeValue]) : cfloat.CompilerFiniteCastInput
  (match value
    [(CompilerCtfeValue.I64 n) (CompilerFiniteCastInputI64 n)]
    [(CompilerCtfeValue.F64 n) (CompilerFiniteCastInputF64 n)]
    [(CompilerCtfeValue.F32 n) (CompilerFiniteCastInputF32 n)]
    [(CompilerCtfeValue.Char c) (CompilerFiniteCastInputChar c)]
    [_ (CompilerFiniteCastNoInput)]))

(define (ctfe-finite-cast-result
  [result : cfloat.CompilerFiniteCastResult]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (match result
    [(CompilerFiniteCastResultI64 n)
      (ResultCtfe.Ok (CompilerCtfeValue.I64 n) fuel)]
    [(CompilerFiniteCastResultChar c)
      (ResultCtfe.Ok (CompilerCtfeValue.Char c) fuel)]
    [(CompilerFiniteCastResultF64 n) (ctfe-f64-result n expr fuel)]
    [(CompilerFiniteCastResultF32 n) (ctfe-f32-result n expr fuel)]
    [(CompilerFiniteCastNoResult)
      (ResultCtfe.Err
        (box (ctfe-diagnostic-at-expr expr "comptime: unsupported cast")))]))

(define (ctfe-apply-cast
  [value : CompilerCtfeValue]
  [from-ty : ast.AstType]
  [ty : ast.AstType]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (match (clone ty)
    [(ast.AstType.F64)
      (match (ctfe-value-owned-copy (& value))
        [(CompilerCtfeValue.F64 n) (ctfe-f64-result n expr fuel)]
        [(CompilerCtfeValue.F32 n) (ctfe-f64-result n expr fuel)]
        [_
          (ctfe-finite-cast-result
            (cfloat.compiler-finite-cast-fold
              (ctfe-finite-cast-input value)
              from-ty
              ty)
            expr
            fuel)])]
    [(ast.AstType.F32)
      (match (ctfe-value-owned-copy (& value))
        [(CompilerCtfeValue.F64 n) (ctfe-f32-result n expr fuel)]
        [(CompilerCtfeValue.F32 n) (ctfe-f32-result n expr fuel)]
        [_
          (ctfe-finite-cast-result
            (cfloat.compiler-finite-cast-fold
              (ctfe-finite-cast-input value)
              from-ty
              ty)
            expr
            fuel)])]
    [_
      (ctfe-finite-cast-result
        (cfloat.compiler-finite-cast-fold
          (ctfe-finite-cast-input value)
          from-ty
          ty)
        expr
        fuel)]))

(define (ctfe-eval-cast
  [inner : ast.AstExpr]
  [ty : ast.AstType]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval (clone inner) env fuel)
    [(ResultCtfe.Ok value next-fuel)
      (let
        [from-ty : ast.AstType
          (ctfe-cast-source-type inner (ctfe-value-owned-copy (& value)) env)]
        (ctfe-apply-cast value from-ty ty expr next-fuel))]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

(defenum ResultCtfeNameLookup
  (Ok i64)
  (Err String))

(defenum ResultCtfeTypeLookup
  (Ok ast.AstType)
  (Err String))

(defenum ResultCtfeTypeListLookup
  (Ok ast.AstTypeList)
  (Err String))

(defenum ResultCtfeTypeArg
  (Ok ast.AstType i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defstruct CtfeI64Arg
  (value i64)
  (fuel i64))

(import (result.result CtfeI64Arg (Box cdiag.CompilerDiagnostic)) as result_ctfe_i64_arg)

(defenum ResultCtfeStringArg
  (Ok String i64 i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultCtfeNameArg
  (Ok i64 i64)
  (Err (Box cdiag.CompilerDiagnostic)))

;; --- comptime builders shared with the native host ---------------------------
;; Interpreted CTFE evaluates a builtin's arguments; a native transformer hands
;; the same values to its host callback (compiler_embedded_stdlib_tlci). Both
;; read and build through the functions below, so the two routes share one
;; implementation and differ only in how arguments arrive and results leave.
(defenum CtfeMaybeNamed
  (Some String i64)
  (None))

(defenum CtfeMaybeNameId
  (Some i64)
  (None))

;; A builder's result, or the authored diagnostic both routes report.
(defenum CtfeBuilt
  (Ok CompilerCtfeValue)
  (Err String))

(define (ctfe-built-result
  [built : CtfeBuilt]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (match built
    [(CtfeBuilt.Ok value) (ResultCtfe.Ok value fuel)]
    [(CtfeBuilt.Err message)
      (ResultCtfe.Err (box (ctfe-diagnostic-at-expr expr message)))]))

;; Public String arguments also accept inspected Name values, which is how
;; reflected names flow through ordinary string helpers.
(define (ctfe-value-named [value : CompilerCtfeValue]) : CtfeMaybeNamed
  (match value
    [(CompilerCtfeValue.String text string-id)
      (CtfeMaybeNamed.Some text string-id)]
    [(CompilerCtfeValue.Name text name-id) (CtfeMaybeNamed.Some text name-id)]
    [_ (CtfeMaybeNamed.None)]))

;; Binding-oriented syntax constructors preserve an inspected or explicitly
;; fresh `Name` identity. Ordinary strings retain the public spelling lookup
;; used for references to caller and module names.
(define (ctfe-value-syntax-name-id
  [source-names : ci.InternSourceNameSessionHandle]
  [value : CompilerCtfeValue]) : CtfeMaybeNameId
  (match value
    [(CompilerCtfeValue.String text string-id)
      (CtfeMaybeNameId.Some
        (ctfe-string-syntax-name-id source-names text string-id))]
    [(CompilerCtfeValue.Name _ name-id) (CtfeMaybeNameId.Some name-id)]
    [_ (CtfeMaybeNameId.None)]))

;; Module indexes use the same source/generated Name identity that a String-to-
;; syntax constructor would assign. Re-interning only the evaluated text loses
;; the generated canonical identity for a declaration whose spelling never
;; occurred in parsed source, so a later computed lookup cannot find it.
(define (ctfe-value-module-index
  [source-names : ci.InternSourceNameSessionHandle]
  [value : CompilerCtfeValue]) : CtfeMaybeNamed
  (match value
    [(CompilerCtfeValue.String text string-id)
      (let
        [text-id : i64
          (ctfe-string-syntax-name-id
            source-names
            (owned_view.compiler-owned-shared-view text)
            string-id)]
        (CtfeMaybeNamed.Some text text-id))]
    [(CompilerCtfeValue.Name text name-id) (CtfeMaybeNamed.Some text name-id)]
    [_ (CtfeMaybeNamed.None)]))

(define (ctfe-reflect-info-canonical-id [info : CtfeReflectInfo]) : i64
  (match info
    [(CtfeReflectInfo.Struct _ _ _ canonical-id _ _ _) canonical-id]
    [(CtfeReflectInfo.Enum _ _ _ canonical-id _ _ _) canonical-id]))

(define (ctfe-reflect-info-nominal-name-id [info : CtfeReflectInfo]) : i64
  (let
    [canonical-id : i64 (ctfe-reflect-info-canonical-id info)]
    (if (ci.intern-composite-pair-id? canonical-id)
      (ci.intern-composite-right-id-unchecked canonical-id)
      canonical-id)))

(define (ctfe-reflect-info-nominal-module-id [info : CtfeReflectInfo]) : i64
  (let
    [canonical-id : i64 (ctfe-reflect-info-canonical-id info)]
    (if (ci.intern-composite-pair-id? canonical-id)
      (ci.intern-composite-left-id-unchecked canonical-id)
      cbi.compiler-builtin-id-fix-empty)))

(define (ctfe-reflect-resolve-type-list-with-pools
  [pools : ast.AstNodePoolContext]
  [infos : (& infos CtfeReflectInfoList)]
  [types : ast.AstTypeList]) : ast.AstTypeList
  (let
    [out : ast.AstTypeList
      (ast.ast-type-list-with-capacity (ast.ast-type-list-len (& types)))]
    (begin
      (ctfe-reflect-resolve-type-list-with-pools-into
        pools
        infos
        (& types)
        (&mut out)
        0)
      out)))

(define (ctfe-reflect-resolve-type-list-with-pools-into
  [pools : ast.AstNodePoolContext]
  [infos : (& infos CtfeReflectInfoList)]
  [types : (& types ast.AstTypeList)]
  [out : (&mut out ast.AstTypeList)]
  [index : i64]) : unit
  (if (>= index (ast.ast-type-list-len types))
    unit
    (begin
      (ast.ast-type-list-push
        out
        (ast.ast-node-pool-context-type-push
          pools
          (ctfe-reflect-resolve-type-with-pools
            pools
            infos
            (ast.ast-node-pool-context-type-get
              pools
              (ast.ast-type-list-get types index (ast.ast-type-id-fallback))))))
      (ctfe-reflect-resolve-type-list-with-pools-into
        pools
        infos
        types
        out
        (+ index 1)))))

(define (ctfe-reflect-resolve-type-with-pools
  [pools : ast.AstNodePoolContext]
  [infos : (& infos CtfeReflectInfoList)]
  [ty : ast.AstType]) : ast.AstType
  (match (clone ty)
    [(ast.AstType.Func args ret)
      (ast.ast-ty-func-with-pools
        pools
        (ctfe-reflect-resolve-type-list-with-pools pools infos (deref args))
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools ret)))]
    [(ast.AstType.Tuple elems)
      (ast.ast-ty-tuple
        (ctfe-reflect-resolve-type-list-with-pools pools infos (deref elems)))]
    [(ast.AstType.Array elem len)
      (ast.ast-ty-array-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools elem))
        len)]
    [(ast.AstType.DynArray elem)
      (ast.ast-ty-dyn-array-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools elem)))]
    [(ast.AstType.Slice elem)
      (ast.ast-ty-slice-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools elem)))]
    [(ast.AstType.Box elem)
      (ast.ast-ty-box-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools elem)))]
    [(ast.AstType.CFunc signature mode)
      (let
        [resolved : ast.AstType
          (ctfe-reflect-resolve-type-with-pools
            pools
            infos
            (ast.ast-node-pool-context-type-get pools signature))]
        (ast.AstType.CFunc
          (ast.ast-node-pool-context-type-push pools resolved)
          mode))]
    [(ast.AstType.Ptr elem)
      (ast.ast-ty-ptr-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools elem)))]
    [(ast.AstType.MutPtr elem)
      (ast.ast-ty-mut-ptr-with-pools
        pools
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools elem)))]
    [(ast.AstType.Ref region inner)
      (ast.ast-ty-ref-with-pools
        pools
        region
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools inner)))]
    [(ast.AstType.MutRef region inner)
      (ast.ast-ty-mut-ref-with-pools
        pools
        region
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools inner)))]
    [(ast.AstType.Region region inner)
      (ast.ast-ty-region-with-pools
        pools
        region
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools inner)))]
    [(ast.AstType.Invalidate lifetime inner)
      (ast.ast-ty-invalidate-with-pools
        pools
        lifetime
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools inner)))]
    [(ast.AstType.Struct name)
      (match (ctfe-reflect-info-canonical-type-lookup infos name)
        [(ast.AstMaybeType.Some canonical) canonical]
        [(ast.AstMaybeType.No) ty])]
    [(ast.AstType.Enum name)
      (match (ctfe-reflect-info-canonical-type-lookup infos name)
        [(ast.AstMaybeType.Some canonical) canonical]
        [(ast.AstMaybeType.No) ty])]
    [(ast.AstType.Var name)
      (match (ctfe-reflect-info-canonical-type-lookup infos name)
        [(ast.AstMaybeType.Some canonical) canonical]
        [(ast.AstMaybeType.No) ty])]
    [_ ty]))

;; Nominal resolution without a whole-list clone: the map lookup and the
;; canonical-id field read both work through shared views, so a nested type-key
;; walk does not deep-copy the reflection list per recursion level. Only the
;; small canonical `AstType` is returned.
(define (ctfe-reflect-info-canonical-type-lookup
  [infos : (& infos CtfeReflectInfoList)]
  [name-id : i64]) : ast.AstMaybeType
  (match (ctfe_key_map.get infos.index (ctfe-name-id-key name-id))
    [(ctfe_key_map.LookupFound slot)
      (let
        [info : CtfeReflectInfo
          (unsafe
            (ptr-read (ptr-offset (__tl_array-data infos.slots) slot)))]
        (match info
          [(CtfeReflectInfo.Struct _ _ _ canonical-id _ _ _)
            (ast.AstMaybeType.Some (ast.AstType.Struct canonical-id))]
          [(CtfeReflectInfo.Enum _ _ _ canonical-id _ _ _)
            (ast.AstMaybeType.Some (ast.AstType.Enum canonical-id))]))]
    [(ctfe_key_map.LookupMissing) (ast.AstMaybeType.No)]))

(define (ctfe-reflect-info-for-type-with-pools
  [pools : ast.AstNodePoolContext]
  [infos : (& infos CtfeReflectInfoList)]
  [ty : ast.AstType]) : CtfeMaybeReflectInfo
  (match ty
    [(ast.AstType.Struct name) (ctfe-reflect-info-lookup-name-id infos name)]
    [(ast.AstType.StructArgs name _)
      (ctfe-reflect-info-lookup-name-id infos name)]
    [(ast.AstType.Enum name) (ctfe-reflect-info-lookup-name-id infos name)]
    [(ast.AstType.EnumArgs name _)
      (ctfe-reflect-info-lookup-name-id infos name)]
    [(ast.AstType.Var name) (ctfe-reflect-info-lookup-name-id infos name)]
    [(ast.AstType.VarArgs name _) (ctfe-reflect-info-lookup-name-id infos name)]
    [(ast.AstType.Region _ inner)
      (ctfe-reflect-info-for-type-with-pools
        pools
        infos
        (ast.ast-node-pool-context-type-get pools inner))]
    [_ (CtfeMaybeReflectInfo.None)]))

(define (ctfe-int-key [n : i64]) : String
  (if (< n 0)
    (str_cat.str-cat "m" (string.int->string (- 0 n)))
    (string.int->string n)))

(define (ctfe-type-list-key-with-pools
  [pools : ast.AstNodePoolContext]
  [infos : (& infos CtfeReflectInfoList)]
  [types : ast.AstTypeList]) : String
  (ctfe-type-list-key-with-pools-at pools infos (& types) 0))

(define (ctfe-type-list-key-with-pools-at
  [pools : ast.AstNodePoolContext]
  [infos : (& infos CtfeReflectInfoList)]
  [types : (& types ast.AstTypeList)]
  [index : i64]) : String
  (if (>= index (ast.ast-type-list-len types))
    "nil"
    (str_cat.str-cat
      (ctfe-type-key-with-reflections-and-pools
        pools
        infos
        (ast.ast-node-pool-context-type-get
          pools
          (ast.ast-type-list-get types index (ast.ast-type-id-fallback))))
      "_"
      (ctfe-type-list-key-with-pools-at pools infos types (+ index 1)))))

(define (ctfe-lifetime-list-key-at
  [lifetimes : (& lifetimes ast.AstLifetimeList)]
  [index : i64]) : String
  (if (>= index (ast.ast-lifetime-list-len lifetimes))
    "nil"
    (str_cat.str-cat
      (ci.intern-str
        (ast.ast-lifetime-list-get lifetimes index (ast.ast-lifetime-fallback)))
      "_"
      (ctfe-lifetime-list-key-at lifetimes (+ index 1)))))

(define (ctfe-lifetime-list-key [lifetimes : ast.AstLifetimeList]) : String
  (ctfe-lifetime-list-key-at (& lifetimes) 0))

(define (ctfe-lifetime-list-eq
  [a : ast.AstLifetimeList]
  [b : ast.AstLifetimeList]) : bool
  (ast.ast-lifetime-list-eq? a b))

(define (ctfe-type-key-with-reflections-and-pools
  [pools : ast.AstNodePoolContext]
  [infos : (& infos CtfeReflectInfoList)]
  [ty : ast.AstType]) : String
  (match (ctfe-reflect-resolve-type-with-pools pools infos ty)
    [(ast.AstType.I64) "i64"]
    [(ast.AstType.I32) "i32"]
    [(ast.AstType.I16) "i16"]
    [(ast.AstType.I8) "i8"]
    [(ast.AstType.U64) "u64"]
    [(ast.AstType.U32) "u32"]
    [(ast.AstType.U16) "u16"]
    [(ast.AstType.U8) "u8"]
    [(ast.AstType.F64) "f64"]
    [(ast.AstType.F32) "f32"]
    [(ast.AstType.Bool) "bool"]
    [(ast.AstType.Char) "char"]
    [(ast.AstType.String) "String"]
    [(ast.AstType.Str) "str"]
    [(ast.AstType.Bytes) "bytes"]
    [(ast.AstType.Expr) "Expr"]
    [(ast.AstType.ExprList) "ExprList"]
    [(ast.AstType.Unit) "unit"]
    [(ast.AstType.Never) "never"]
    [(ast.AstType.Func args ret)
      (str_cat.str-cat
        "fn_"
        (ctfe-type-list-key-with-pools pools infos (deref args))
        "_to_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools ret)))]
    [(ast.AstType.CFunc signature mode)
      (str_cat.str-cat
        "cfn_"
        (ast.ast-c-function-mode-name mode)
        "_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools signature)))]
    [(ast.AstType.Tuple elems)
      (str_cat.str-cat
        "tuple_"
        (ctfe-type-list-key-with-pools pools infos (deref elems)))]
    [(ast.AstType.Array elem count)
      (str_cat.str-cat
        "array_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools elem))
        "_"
        (ctfe-int-key count))]
    [(ast.AstType.DynArray elem)
      (str_cat.str-cat
        "dynarray_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools elem)))]
    [(ast.AstType.Slice elem)
      (str_cat.str-cat
        "slice_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools elem)))]
    [(ast.AstType.Box elem)
      (str_cat.str-cat
        "box_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools elem)))]
    [(ast.AstType.Ptr elem)
      (str_cat.str-cat
        "ptr_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools elem)))]
    [(ast.AstType.MutPtr elem)
      (str_cat.str-cat
        "mutptr_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools elem)))]
    [(ast.AstType.Ref region inner)
      (str_cat.str-cat
        "ref_"
        (ci.intern-str region)
        "_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools inner)))]
    [(ast.AstType.MutRef region inner)
      (str_cat.str-cat
        "mutref_"
        (ci.intern-str region)
        "_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools inner)))]
    [(ast.AstType.Region region inner)
      (str_cat.str-cat
        "region_"
        (ci.intern-str region)
        "_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools inner)))]
    [(ast.AstType.Invalidate lifetime inner)
      (str_cat.str-cat
        "invalidate_"
        (ci.intern-str lifetime)
        "_"
        (ctfe-type-key-with-reflections-and-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get pools inner)))]
    [(ast.AstType.Enum name)
      (str_cat.str-cat "enum_" (ast.ast-nominal-name-id-display name))]
    [(ast.AstType.EnumArgs name lifetimes)
      (str_cat.str-cat
        "enumargs_"
        (ast.ast-nominal-name-id-display name)
        "_"
        (ctfe-lifetime-list-key (deref lifetimes)))]
    [(ast.AstType.Struct name)
      (str_cat.str-cat "struct_" (ast.ast-nominal-name-id-display name))]
    [(ast.AstType.StructArgs name lifetimes)
      (str_cat.str-cat
        "structargs_"
        (ast.ast-nominal-name-id-display name)
        "_"
        (ctfe-lifetime-list-key (deref lifetimes)))]
    [(ast.AstType.Var name) (str_cat.str-cat "var_" (ci.intern-str name))]
    [(ast.AstType.VarArgs name lifetimes)
      (str_cat.str-cat
        "varargs_"
        (ci.intern-str name)
        "_"
        (ctfe-lifetime-list-key (deref lifetimes)))]))

(define (ctfe-type-key-with-reflections
  [infos : CtfeReflectInfoList]
  [ty : ast.AstType]) : String
  (ctfe-type-key-with-reflections-and-pools
    (ast.ast-node-pool-context-capture-active)
    infos
    ty))

(define (ctfe-type-key [ty : ast.AstType]) : String
  (ctfe-type-key-with-reflections (ctfe-reflect-info-list-empty) ty))

(define (ctfe-type-kind-with-reflections-and-pools
  [pools : ast.AstNodePoolContext]
  [infos : (& infos CtfeReflectInfoList)]
  [ty : ast.AstType]) : String
  (match (ctfe-reflect-resolve-type-with-pools pools infos ty)
    [(ast.AstType.I64) "i64"]
    [(ast.AstType.I32) "i32"]
    [(ast.AstType.I16) "i16"]
    [(ast.AstType.I8) "i8"]
    [(ast.AstType.U64) "u64"]
    [(ast.AstType.U32) "u32"]
    [(ast.AstType.U16) "u16"]
    [(ast.AstType.U8) "u8"]
    [(ast.AstType.F64) "f64"]
    [(ast.AstType.F32) "f32"]
    [(ast.AstType.Bool) "bool"]
    [(ast.AstType.Char) "char"]
    [(ast.AstType.String) "string"]
    [(ast.AstType.Str) "str"]
    [(ast.AstType.Bytes) "bytes"]
    [(ast.AstType.Expr) "expr"]
    [(ast.AstType.ExprList) "expr-list"]
    [(ast.AstType.Unit) "unit"]
    [(ast.AstType.Never) "never"]
    [(ast.AstType.CFunc _ _) "c-function"]
    [(ast.AstType.Func _ _) "function"]
    [(ast.AstType.Tuple _) "tuple"]
    [(ast.AstType.Array _ _) "array"]
    [(ast.AstType.DynArray _) "dyn-array"]
    [(ast.AstType.Slice _) "slice"]
    [(ast.AstType.Box _) "box"]
    [(ast.AstType.Ptr _) "ptr"]
    [(ast.AstType.MutPtr _) "mut-ptr"]
    [(ast.AstType.Ref _ _) "ref"]
    [(ast.AstType.MutRef _ _) "mut-ref"]
    [(ast.AstType.Region _ _) "region"]
    [(ast.AstType.Invalidate _ _) "invalidate"]
    [(ast.AstType.Enum _) "enum"]
    [(ast.AstType.EnumArgs _ _) "enum"]
    [(ast.AstType.Struct _) "struct"]
    [(ast.AstType.StructArgs _ _) "struct"]
    [(ast.AstType.Var _) "type-var"]
    [(ast.AstType.VarArgs _ _) "type-var"]))

(define (ctfe-expr-shared-view [expr : (& expr ast.AstExpr)]) : ast.AstExpr
  (let
    [cell : (CtfeExprRef expr) (CtfeExprRef expr)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr ast.AstExpr))))))

(define (ctfe-eval-type-arg
  [arg : ast.AstExpr]
  [expr : (& expr ast.AstExpr)]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [name : String]) : ResultCtfeTypeArg
  (match (compiler-ctfe-eval arg env fuel)
    [(ResultCtfe.Err d) (ResultCtfeTypeArg.Err d)]
    [(ResultCtfe.Ok value arg-fuel)
      (match value
        [(CompilerCtfeValue.Type ty)
          (let
            [reflections : CtfeReflectInfoList (ctfe-env-reflections env)]
            (ResultCtfeTypeArg.Ok
              (ctfe-reflect-resolve-type-with-pools
                (ctfe-env-pools env)
                reflections
                ty)
              arg-fuel))]
        [_
          (ResultCtfeTypeArg.Err
            (box
              (ctfe-diagnostic-at-expr
                (ctfe-expr-shared-view expr)
                (str_cat.str-cat name " expects a type argument"))))])]))

(define (ctfe-eval-i64-arg
  [arg : ast.AstExpr]
  [expr : (& expr ast.AstExpr)]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [name : String]) : result_ctfe_i64_arg.Result
  (match (compiler-ctfe-eval arg env fuel)
    [(ResultCtfe.Err d) (result_ctfe_i64_arg.Err d)]
    [(ResultCtfe.Ok value arg-fuel)
      (match value
        [(CompilerCtfeValue.I64 n)
          (result_ctfe_i64_arg.Ok (CtfeI64Arg n arg-fuel))]
        [_
          (result_ctfe_i64_arg.Err
            (box
              (ctfe-diagnostic-at-expr
                (ctfe-expr-shared-view expr)
                (str_cat.str-cat name " expects an i64 index"))))])]))

(define (ctfe-string-arg-error [expr : (& expr ast.AstExpr)] [name : String]) : (Box
    cdiag.CompilerDiagnostic)
  (box
    (ctfe-diagnostic-at-expr
      (ctfe-expr-shared-view expr)
      (str_cat.str-cat name " expects a String argument"))))

(define (ctfe-eval-string-arg
  [arg : ast.AstExpr]
  [expr : (& expr ast.AstExpr)]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [name : String]) : ResultCtfeStringArg
  (match (compiler-ctfe-eval arg env fuel)
    [(ResultCtfe.Err d) (ResultCtfeStringArg.Err d)]
    [(ResultCtfe.Ok value arg-fuel)
      (match (ctfe-value-named value)
        [(CtfeMaybeNamed.Some text id)
          (ResultCtfeStringArg.Ok text id arg-fuel)]
        [(CtfeMaybeNamed.None)
          (ResultCtfeStringArg.Err (ctfe-string-arg-error expr name))])]))

(define (ctfe-eval-module-index-arg
  [arg : ast.AstExpr]
  [expr : (& expr ast.AstExpr)]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [name : String]) : ResultCtfeStringArg
  (match (compiler-ctfe-eval arg env fuel)
    [(ResultCtfe.Err d) (ResultCtfeStringArg.Err d)]
    [(ResultCtfe.Ok value arg-fuel)
      (match (ctfe-value-module-index (ctfe-env-source-names env) value)
        [(CtfeMaybeNamed.Some text id)
          (ResultCtfeStringArg.Ok text id arg-fuel)]
        [(CtfeMaybeNamed.None)
          (ResultCtfeStringArg.Err (ctfe-string-arg-error expr name))])]))

(define (ctfe-eval-syntax-name-arg
  [arg : ast.AstExpr]
  [expr : (& expr ast.AstExpr)]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [name : String]) : ResultCtfeNameArg
  (match (compiler-ctfe-eval arg env fuel)
    [(ResultCtfe.Err d) (ResultCtfeNameArg.Err d)]
    [(ResultCtfe.Ok value arg-fuel)
      (match (ctfe-value-syntax-name-id (ctfe-env-source-names env) value)
        [(CtfeMaybeNameId.Some name-id) (ResultCtfeNameArg.Ok name-id arg-fuel)]
        [(CtfeMaybeNameId.None)
          (ResultCtfeNameArg.Err (ctfe-string-arg-error expr name))])]))

(define (ctfe-expr-arg-count [args : (& args ast.AstExprList)]) : i64
  args.len)

(define (ctfe-expr-arg
  [args : (& args ast.AstExprList)]
  [index : i64]
  [env : (& env CtfeEnv)]) : ast.AstExpr
  (ctfe-ast-get env (ast.ast-expr-list-get args index 0)))

(define (ctfe-reflect-field-list-count
  [fields : (& fields CtfeReflectFieldList)]) : i64
  fields.len)

(define (ctfe-reflect-field-name-at
  [fields : CtfeReflectFieldList]
  [index : i64]) : ResultCtfeNameLookup
  (if (if (< index 0)
    true
    (>= index fields.len))
    (ResultCtfeNameLookup.Err "index out of range")
    (match (ctfe-reflect-field-list-ref fields index)
      [(CtfeReflectField.Field name _) (ResultCtfeNameLookup.Ok name)])))

(define (ctfe-reflect-field-type-at
  [fields : CtfeReflectFieldList]
  [pools : ast.AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [index : i64]) : ResultCtfeTypeLookup
  (if (if (< index 0)
    true
    (>= index fields.len))
    (ResultCtfeTypeLookup.Err "index out of range")
    (match (ctfe-reflect-field-list-ref fields index)
      [(CtfeReflectField.Field _ ty)
        (ResultCtfeTypeLookup.Ok
          (ctfe-reflect-resolve-type-with-pools pools infos ty))])))

(define (ctfe-reflect-variant-list-count
  [variants : (& variants CtfeReflectVariantList)]) : i64
  variants.len)

(define (ctfe-reflect-variant-name-at
  [variants : CtfeReflectVariantList]
  [index : i64]) : ResultCtfeNameLookup
  (if (if (< index 0)
    true
    (>= index variants.len))
    (ResultCtfeNameLookup.Err "index out of range")
    (match (ctfe-reflect-variant-list-ref variants index)
      [(CtfeReflectVariant.Variant name _) (ResultCtfeNameLookup.Ok name)])))

(define (ctfe-reflect-variant-payloads-at
  [variants : CtfeReflectVariantList]
  [index : i64]) : ResultCtfeTypeListLookup
  (if (if (< index 0)
    true
    (>= index variants.len))
    (ResultCtfeTypeListLookup.Err "index out of range")
    (match (ctfe-reflect-variant-list-ref variants index)
      [(CtfeReflectVariant.Variant _ payloads)
        (ResultCtfeTypeListLookup.Ok payloads)])))

(define (ctfe-type-list-count [types : ast.AstTypeList]) : i64
  (ast.ast-type-list-len (& types)))

(define (ctfe-type-list-ref-with-pools
  [types : ast.AstTypeList]
  [pools : ast.AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [index : i64]) : ResultCtfeTypeLookup
  (if (< index 0)
    (ResultCtfeTypeLookup.Err "index out of range")
    (if (>= index (ast.ast-type-list-len (& types)))
      (ResultCtfeTypeLookup.Err "index out of range")
      (ResultCtfeTypeLookup.Ok
        (ctfe-reflect-resolve-type-with-pools
          pools
          infos
          (ast.ast-node-pool-context-type-get
            pools
            (ast.ast-type-list-get (& types) index (ast.ast-type-id-fallback))))))))

(define (ctfe-type-info-builtin-kind? [kind : String]) : bool
  (cond
    [(string.eq kind "i64") true]
    [(string.eq kind "i32") true]
    [(string.eq kind "i16") true]
    [(string.eq kind "i8") true]
    [(string.eq kind "u64") true]
    [(string.eq kind "u32") true]
    [(string.eq kind "u16") true]
    [(string.eq kind "u8") true]
    [(string.eq kind "f64") true]
    [(string.eq kind "f32") true]
    [(string.eq kind "bool") true]
    [(string.eq kind "char") true]
    [(string.eq kind "string") true]
    [(string.eq kind "unit") true]
    [else (string.eq kind "never")]))

(define (ctfe-type-info-key-in-env [env : (& env CtfeEnv)] [ty : ast.AstType]) : String
  (let
    [reflections : CtfeReflectInfoList (ctfe-env-reflections env)]
    (ctfe-type-key-with-reflections-and-pools
      (ctfe-env-pools env)
      reflections
      ty)))

(define (ctfe-match-type-info-opaque
  [variant : i64]
  [args : ast.AstPatternList]
  [ty : ast.AstType]
  [env : CtfeEnv]) : CtfePatternMatch
  (if (ctfe-pattern-variant-name? variant "Opaque")
    (ctfe-match-pattern-list
      args
      (ctfe-value-list1
        (ctfe-generated-string-value (ctfe-type-info-key-in-env env ty)))
      env)
    (CtfePatternMatch.No)))

(define (ctfe-match-type-info-nominal
  [variant : i64]
  [args : ast.AstPatternList]
  [ty : ast.AstType]
  [env : CtfeEnv]
  [want-struct : bool]) : CtfePatternMatch
  (let
    [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
    (match (ctfe-reflect-info-for-type-with-pools
      (ctfe-env-pools env)
      infos
      (clone ty))
      [(CtfeMaybeReflectInfo.Some info)
        (match info
          [(CtfeReflectInfo.Struct _ _ _ _ _ fields _)
            (if want-struct
              (if (ctfe-pattern-variant-name? variant "Struct")
                (ctfe-match-pattern-list
                  args
                  (ctfe-value-list2
                    (ctfe-generated-string-value
                      (ctfe-type-info-key-in-env env (clone ty)))
                    (CompilerCtfeValue.TypeFieldList fields))
                  env)
                (CtfePatternMatch.No))
              (CtfePatternMatch.No))]
          [(CtfeReflectInfo.Enum _ _ _ _ _ variants _)
            (if want-struct
              (CtfePatternMatch.No)
              (if (ctfe-pattern-variant-name? variant "Enum")
                (ctfe-match-pattern-list
                  args
                  (ctfe-value-list2
                    (ctfe-generated-string-value
                      (ctfe-type-info-key-in-env env (clone ty)))
                    (CompilerCtfeValue.TypeVariantList variants))
                  env)
                (CtfePatternMatch.No)))])]
      [(CtfeMaybeReflectInfo.None)
        (ctfe-match-type-info-opaque variant args ty env)])))

(define (ctfe-match-type-info-variant
  [variant : i64]
  [args : ast.AstPatternList]
  [ty : ast.AstType]
  [env : CtfeEnv]) : CtfePatternMatch
  (let
    [pools : ast.AstNodePoolContext (ctfe-env-pools env)]
    [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
    [resolved : ast.AstType
      (ctfe-reflect-resolve-type-with-pools pools infos ty)]
    [kind : String
      (ctfe-type-kind-with-reflections-and-pools pools infos (clone resolved))]
    (match (clone resolved)
      [(ast.AstType.Array elem count)
        (if (ctfe-pattern-variant-name? variant "Array")
          (ctfe-match-pattern-list
            args
            (ctfe-value-list2
              (CompilerCtfeValue.TypeInfoBox
                (ast.ast-node-pool-context-type-get pools elem))
              (CompilerCtfeValue.I64 count))
            env)
          (CtfePatternMatch.No))]
      [(ast.AstType.DynArray elem)
        (if (ctfe-pattern-variant-name? variant "DynArray")
          (ctfe-match-pattern-list
            args
            (ctfe-value-list1
              (CompilerCtfeValue.TypeInfoBox
                (ast.ast-node-pool-context-type-get pools elem)))
            env)
          (CtfePatternMatch.No))]
      [(ast.AstType.Slice elem)
        (if (ctfe-pattern-variant-name? variant "Slice")
          (ctfe-match-pattern-list
            args
            (ctfe-value-list1
              (CompilerCtfeValue.TypeInfoBox
                (ast.ast-node-pool-context-type-get pools elem)))
            env)
          (CtfePatternMatch.No))]
      [(ast.AstType.Func params ret)
        (if (ctfe-pattern-variant-name? variant "Function")
          (ctfe-match-pattern-list
            args
            (ctfe-value-list2
              (CompilerCtfeValue.TypeInfoList (deref params))
              (CompilerCtfeValue.TypeInfoBox
                (ast.ast-node-pool-context-type-get pools ret)))
            env)
          (CtfePatternMatch.No))]
      [(ast.AstType.Tuple elems)
        (if (ctfe-pattern-variant-name? variant "Tuple")
          (ctfe-match-pattern-list
            args
            (ctfe-value-list1 (CompilerCtfeValue.TypeInfoList (deref elems)))
            env)
          (CtfePatternMatch.No))]
      [(ast.AstType.Struct _)
        (ctfe-match-type-info-nominal variant args resolved env true)]
      [(ast.AstType.StructArgs _ _)
        (ctfe-match-type-info-nominal variant args resolved env true)]
      [(ast.AstType.Enum _)
        (ctfe-match-type-info-nominal variant args resolved env false)]
      [(ast.AstType.EnumArgs _ _)
        (ctfe-match-type-info-nominal variant args resolved env false)]
      [_
        (if (ctfe-type-info-builtin-kind? (string.copy kind))
          (if (ctfe-pattern-variant-name? variant "Builtin")
            (ctfe-match-pattern-list
              args
              (ctfe-value-list1 (ctfe-generated-string-value kind))
              env)
            (CtfePatternMatch.No))
          (ctfe-match-type-info-opaque variant args resolved env))])))

;; --- core evaluator ---------------------------------------------------------
;; Evaluate `expr` under `env` with the given remaining `fuel`. Each call
;; charges one unit of fuel up front; when fuel is exhausted the evaluation
;; fails deterministically.
(define (compiler-ctfe-eval
  [expr : ast.AstExpr]
  [env : (& env CtfeEnv)]
  [fuel : i64]) : ResultCtfe
  (if (<= fuel 0)
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr (ctfe-fuel-diagnostic-message))))
    (ctfe-eval-node expr (ctfe-env-shared-view env) (- fuel 1))))

(define (ctfe-eval-node [expr : ast.AstExpr] [env : CtfeEnv] [fuel : i64]) : ResultCtfe
  (match (clone expr)
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(ast.AstExpr.MacroExpansion inner-box _ _)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(ast.AstExpr.Comptime inner-box)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(ast.AstExpr.Ann inner-box _)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(ast.AstExpr.Cast inner-box ty-id)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-cast inner (ctfe-ty-get env ty-id) expr env fuel))]
    [(ast.AstExpr.TypeLiteral ty-id)
      (let
        [reflections : CtfeReflectInfoList (ctfe-env-reflections env)]
        (ResultCtfe.Ok
          (CompilerCtfeValue.Type
            (ctfe-reflect-resolve-type-with-pools
              (ctfe-env-pools env)
              reflections
              (ctfe-type-literal-type env ty-id)))
          fuel))]
    [(ast.AstExpr.Init _)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            (clone expr)
            "comptime: init is a runtime-only expression")))]
    [(ast.AstExpr.Literal lit)
      (ctfe-eval-literal lit expr (ctfe-env-structural-session env) fuel)]
    [(ast.AstExpr.Var name) (ctfe-eval-var name expr env fuel)]
    [(ast.AstExpr.Binary op left-box right-box)
      (let
        [left : ast.AstExpr (ctfe-ast-get env left-box)]
        [right : ast.AstExpr (ctfe-ast-get env right-box)]
        (ctfe-eval-binary op left right expr env fuel))]
    [(ast.AstExpr.Unary op inner-box)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-unary op inner expr env fuel))]
    [(ast.AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : ast.AstExpr (ctfe-ast-get env cond-box)]
        [then-branch : ast.AstExpr (ctfe-ast-get env then-branch-box)]
        [else-branch : ast.AstExpr (ctfe-ast-get env else-branch-box)]
        (ctfe-eval-if cond then-branch else-branch env fuel))]
    [(ast.AstExpr.While cond-box body-box)
      (let
        [cond : ast.AstExpr (ctfe-ast-get env cond-box)]
        [body : ast.AstExpr (ctfe-ast-get env body-box)]
        (ctfe-eval-while cond body expr env fuel))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body-box)
          (let
            [body : ast.AstExpr (ctfe-ast-get env body-box)]
            (ctfe-eval-let bindings body env fuel))])]
    [(ast.AstExpr.Begin exprs) (ctfe-eval-begin exprs env fuel)]
    [(ast.AstExpr.Unsafe exprs) (ctfe-eval-begin exprs env fuel)]
    [(ast.AstExpr.Set name rhs-box)
      (let
        [rhs : ast.AstExpr (ctfe-ast-get env rhs-box)]
        (ctfe-eval-set name rhs expr env fuel))]
    [(ast.AstExpr.Replace place-box replacement-box)
      (ctfe-eval-replace
        (ctfe-ast-get env place-box)
        (ctfe-ast-get env replacement-box)
        expr
        env
        fuel)]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee-box arms)
          (let
            [scrutinee : ast.AstExpr (ctfe-ast-get env scrutinee-box)]
            (ctfe-eval-match scrutinee arms expr env fuel))])]
    [(ast.AstExpr.Call func-box args)
      (let
        [func : ast.AstExpr (ctfe-ast-get env func-box)]
        (ctfe-eval-call func args expr env fuel))]
    [(ast.AstExpr.BoxGet inner-box)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-box-get inner expr env fuel))]
    [(ast.AstExpr.BoxTake inner-box)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-box-get inner expr env fuel))]
    [(ast.AstExpr.StructGet inner-box field)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-struct-get inner field expr env fuel))]
    [(ast.AstExpr.ArrayRef array-box index-box)
      (let
        [array : ast.AstExpr (ctfe-ast-get env array-box)]
        [index : ast.AstExpr (ctfe-ast-get env index-box)]
        (ctfe-eval-array-ref array index expr env fuel))]
    [(ast.AstExpr.Quote template-box)
      (let
        [template : ast.AstExpr (ctfe-ast-get env template-box)]
        (ctfe-eval-quote template env fuel false))]
    [(ast.AstExpr.Quasiquote template-box)
      (let
        [template : ast.AstExpr (ctfe-ast-get env template-box)]
        (ctfe-eval-quote template env fuel true))]
    [(ast.AstExpr.Unquote _)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "unquote is only valid inside quasiquote")))]
    [(ast.AstExpr.UnquoteSplicing _)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "unquote-splicing is only valid inside quasiquote")))]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            (clone expr)
            (str_cat.str-cat
              "'"
              (ctfe-describe-expr expr)
              "' is not supported in compile-time evaluation"))))]))

;; Type size / alignment in bytes for CTFE layout queries. Builtins mirror the
;; lowerer ABI; user-defined names come from the layout table carried in `env`.
;; Unresolved type variables without a table entry return -1 so callers can
;; produce a source-located diagnostic instead of inventing runtime metadata.
;; References carry a type-pool id for their referent. Peel only Region
;; wrappers around that immediate referent; owning containers remain ordinary
;; one-word references.
(define (ctfe-fat-reference? [pools : ast.AstNodePoolContext] [inner : i64]) : bool
  (match (ast.ast-node-pool-context-type-get pools inner)
    [(ast.AstType.Region _ nested) (ctfe-fat-reference? pools nested)]
    [_
      (ast.ast-type-fat-referent?
        (ast.ast-node-pool-context-type-get pools inner))]))

;; A named type's recorded layout size or alignment, or `missing` when no
;; layout is recorded for it.
(define (ctfe-layout-size-or
  [layouts : CtfeLayoutInfoList]
  [name : i64]
  [missing : i64]) : i64
  (match (ctfe-layout-info-lookup-name-id layouts name)
    [(CtfeMaybeLayoutInfo.Some info)
      (match info
        [(CtfeLayoutInfo.Info _ _ size _ _) size])]
    [(CtfeMaybeLayoutInfo.None) missing]))

(define (ctfe-layout-align-or
  [layouts : CtfeLayoutInfoList]
  [name : i64]
  [missing : i64]) : i64
  (match (ctfe-layout-info-lookup-name-id layouts name)
    [(CtfeMaybeLayoutInfo.Some info)
      (match info
        [(CtfeLayoutInfo.Info _ _ _ align _) align])]
    [(CtfeMaybeLayoutInfo.None) missing]))

(define (ctfe-type-size-with-pools
  [pools : ast.AstNodePoolContext]
  [layouts : CtfeLayoutInfoList]
  [ty : ast.AstType]) : i64
  (match ty
    [(ast.AstType.I64) 8]
    [(ast.AstType.U64) 8]
    [(ast.AstType.F64) 8]
    [(ast.AstType.I32) 4]
    [(ast.AstType.U32) 4]
    [(ast.AstType.F32) 4]
    [(ast.AstType.I16) 2]
    [(ast.AstType.U16) 2]
    [(ast.AstType.I8) 1]
    [(ast.AstType.U8) 1]
    [(ast.AstType.Bool) 1]
    [(ast.AstType.Char) 1]
    [(ast.AstType.Unit) 0]
    [(ast.AstType.Never) 0]
    [(ast.AstType.Str) -1]
    [(ast.AstType.Bytes) -1]
    [(ast.AstType.Expr) -1]
    [(ast.AstType.ExprList) -1]
    [(ast.AstType.CFunc _ _) 8]
    [(ast.AstType.Func _ _) 8]
    [(ast.AstType.Tuple _) 8]
    [(ast.AstType.Array elem count)
      (let
        [elem-size : i64
          (ctfe-type-size-with-pools
            pools
            layouts
            (ast.ast-node-pool-context-type-get pools elem))]
        (if (< elem-size 0)
          -1
          (* elem-size count)))]
    [(ast.AstType.DynArray _) 8]
    ;; Bare slices remain unsized; only borrowed Slice references have layout.
    [(ast.AstType.Slice _) -1]
    [(ast.AstType.Box _) 8]
    [(ast.AstType.Ptr _) 8]
    [(ast.AstType.MutPtr _) 8]
    [(ast.AstType.Ref _ inner)
      (if (ctfe-fat-reference? pools inner)
        16
        8)]
    [(ast.AstType.MutRef _ inner)
      (if (ctfe-fat-reference? pools inner)
        16
        8)]
    [(ast.AstType.Region _ inner)
      (ctfe-type-size-with-pools
        pools
        layouts
        (ast.ast-node-pool-context-type-get pools inner))]
    [(ast.AstType.Invalidate _ inner)
      (ctfe-type-size-with-pools
        pools
        layouts
        (ast.ast-node-pool-context-type-get pools inner))]
    ;; An enum occupies its 8-byte tag plus max-aligned payload storage inline,
    ;; exactly like a struct occupies its fields, so its size comes from the
    ;; recorded layout rather than from the tag width. Returning the tag width
    ;; here reported 8 for every enum while `offset-of` on a struct field of the
    ;; same type reported the real inline size.
    [(ast.AstType.Enum name) (ctfe-layout-size-or layouts name -1)]
    [(ast.AstType.EnumArgs name _) (ctfe-layout-size-or layouts name -1)]
    [(ast.AstType.Struct name) (ctfe-layout-size-or layouts name 8)]
    [(ast.AstType.StructArgs name _) (ctfe-layout-size-or layouts name 8)]
    [(ast.AstType.String) 8]
    [(ast.AstType.Var name) (ctfe-layout-size-or layouts name -1)]
    [(ast.AstType.VarArgs name _) (ctfe-layout-size-or layouts name -1)]))

(define (ctfe-type-align-with-pools
  [pools : ast.AstNodePoolContext]
  [layouts : CtfeLayoutInfoList]
  [ty : ast.AstType]) : i64
  (match ty
    [(ast.AstType.I64) 8]
    [(ast.AstType.U64) 8]
    [(ast.AstType.F64) 8]
    [(ast.AstType.I32) 4]
    [(ast.AstType.U32) 4]
    [(ast.AstType.F32) 4]
    [(ast.AstType.I16) 2]
    [(ast.AstType.U16) 2]
    [(ast.AstType.I8) 1]
    [(ast.AstType.U8) 1]
    [(ast.AstType.Bool) 1]
    [(ast.AstType.Char) 1]
    [(ast.AstType.Unit) 1]
    [(ast.AstType.Never) 1]
    [(ast.AstType.Str) -1]
    [(ast.AstType.Bytes) -1]
    [(ast.AstType.Expr) -1]
    [(ast.AstType.ExprList) -1]
    [(ast.AstType.CFunc _ _) 8]
    [(ast.AstType.Func _ _) 8]
    [(ast.AstType.Tuple _) 8]
    [(ast.AstType.Array elem _)
      (ctfe-type-align-with-pools
        pools
        layouts
        (ast.ast-node-pool-context-type-get pools elem))]
    [(ast.AstType.DynArray _) 8]
    [(ast.AstType.Slice _) -1]
    [(ast.AstType.Box _) 8]
    [(ast.AstType.Ptr _) 8]
    [(ast.AstType.MutPtr _) 8]
    [(ast.AstType.Ref _ _) 8]
    [(ast.AstType.MutRef _ _) 8]
    [(ast.AstType.Region _ inner)
      (ctfe-type-align-with-pools
        pools
        layouts
        (ast.ast-node-pool-context-type-get pools inner))]
    [(ast.AstType.Invalidate _ inner)
      (ctfe-type-align-with-pools
        pools
        layouts
        (ast.ast-node-pool-context-type-get pools inner))]
    [(ast.AstType.Enum _) 8]
    [(ast.AstType.EnumArgs _ _) 8]
    [(ast.AstType.Struct name) (ctfe-layout-align-or layouts name 8)]
    [(ast.AstType.StructArgs name _) (ctfe-layout-align-or layouts name 8)]
    [(ast.AstType.String) 8]
    [(ast.AstType.Var name) (ctfe-layout-align-or layouts name -1)]
    [(ast.AstType.VarArgs name _) (ctfe-layout-align-or layouts name -1)]))

(define (ctfe-layout-query-value-with-pools
  [pools : ast.AstNodePoolContext]
  [name : String]
  [layouts : CtfeLayoutInfoList]
  [ty : ast.AstType]) : i64
  (if (string.eq name "size-of")
    (ctfe-type-size-with-pools pools layouts ty)
    (ctfe-type-align-with-pools pools layouts ty)))

;; Evaluate `(size-of (type T))` / `(align-of (type T))` to an `i64` in comptime.
(define (ctfe-eval-size-align-query
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Err d) (ResultCtfe.Err d)]
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.Type ty)
              (let
                [answer : i64
                  (ctfe-layout-query-value-with-pools
                    (ctfe-env-pools env)
                    (string.copy name)
                    (ctfe-env-layouts env)
                    ty)]
                (if (< answer 0)
                  (ResultCtfe.Err
                    (box
                      (ctfe-diagnostic-at-expr
                        expr
                        (str_cat.str-cat name " expects a known type argument"))))
                  (ResultCtfe.Ok (CompilerCtfeValue.I64 answer) arg-fuel)))]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    (str_cat.str-cat name " expects a type argument"))))])]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (str_cat.str-cat name " expects exactly one type argument"))))))

(define (ctfe-offset-field-name [expr : ast.AstExpr] [env : (& env CtfeEnv)]) : CtfeMaybeFieldName
  (match expr
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-offset-field-name inner env))]
    [(ast.AstExpr.MacroExpansion inner-box _ _)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-offset-field-name inner env))]
    [(ast.AstExpr.Var name) (CtfeMaybeFieldName.Some name)]
    [_ (CtfeMaybeFieldName.None)]))

(define (ctfe-layout-info-for-type-with-pools
  [pools : ast.AstNodePoolContext]
  [layouts : CtfeLayoutInfoList]
  [ty : ast.AstType]) : CtfeMaybeLayoutInfo
  (match ty
    [(ast.AstType.Struct name) (ctfe-layout-info-lookup-name-id layouts name)]
    [(ast.AstType.StructArgs name _)
      (ctfe-layout-info-lookup-name-id layouts name)]
    [(ast.AstType.Enum name) (ctfe-layout-info-lookup-name-id layouts name)]
    [(ast.AstType.EnumArgs name _)
      (ctfe-layout-info-lookup-name-id layouts name)]
    [(ast.AstType.Var name) (ctfe-layout-info-lookup-name-id layouts name)]
    [(ast.AstType.Region _ inner)
      (ctfe-layout-info-for-type-with-pools
        pools
        layouts
        (ast.ast-node-pool-context-type-get pools inner))]
    [_ (CtfeMaybeLayoutInfo.None)]))

;; Evaluate `(offset-of (type Struct) field)` to the field byte offset.
;; The field name is intentionally syntactic: a bare variable names the field
;; and is not resolved as a runtime/comptime variable.
(define (ctfe-eval-offset-from-layout
  [field-name-id : i64]
  [info : CtfeLayoutInfo]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (match info
    [(CtfeLayoutInfo.Info _ repr-c? _ _ fields)
      (if repr-c?
        (let
          [offset : i64 (ctfe-layout-field-offset-id fields field-name-id)]
          (if (< offset 0)
            (ResultCtfe.Err
              (box
                (ctfe-diagnostic-at-expr
                  expr
                  (str_cat.str-cat
                    "offset-of unknown field "
                    (ci.intern-str field-name-id)))))
            (ResultCtfe.Ok (CompilerCtfeValue.I64 offset) fuel)))
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr
              expr
              "offset-of requires struct layout type"))))]))

(define (ctfe-eval-offset-from-type
  [ty : ast.AstType]
  [field-name-id : i64]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (ctfe-layout-info-for-type-with-pools
    (ctfe-env-pools env)
    (ctfe-env-layouts env)
    ty)
    [(CtfeMaybeLayoutInfo.Some info)
      (ctfe-eval-offset-from-layout field-name-id info expr fuel)]
    [(CtfeMaybeLayoutInfo.None)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr expr "offset-of requires struct layout type")))]))

(define (ctfe-eval-offset-value
  [value : CompilerCtfeValue]
  [field-arg : ast.AstExpr]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match value
    [(CompilerCtfeValue.Type ty)
      (match (ctfe-offset-field-name field-arg env)
        [(CtfeMaybeFieldName.Some field-name-id)
          (ctfe-eval-offset-from-type ty field-name-id expr env fuel)]
        [(CtfeMaybeFieldName.None)
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr expr "offset-of expects a field name")))])]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            (cdiag.compiler-diagnostic-typecheck-tagged
              (cdiag.CompilerTypecheckKind.ArityMismatch)
              "offset-of expects a type argument"))))]))

(define (ctfe-eval-offset-query
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [type-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [field-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval type-arg env fuel)
        [(ResultCtfe.Err d) (ResultCtfe.Err d)]
        [(ResultCtfe.Ok value arg-fuel)
          (ctfe-eval-offset-value value field-arg expr env arg-fuel)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "offset-of expects exactly one type argument and one field name"))))))

(define (ctfe-reflection-requires [name : String] [kind : String]) : CtfeBuilt
  (CtfeBuilt.Err (str_cat.str-cat name " requires " kind)))

(define (ctfe-reflection-type-result
  [name : String]
  [lookup : ResultCtfeTypeLookup]) : CtfeBuilt
  (match lookup
    [(ResultCtfeTypeLookup.Ok ty) (CtfeBuilt.Ok (CompilerCtfeValue.Type ty))]
    [(ResultCtfeTypeLookup.Err message)
      (CtfeBuilt.Err (str_cat.str-cat name " " message))]))

(define (ctfe-reflect-info-cleanup [info : CtfeReflectInfo]) : CtfeReflectCleanup
  (match info
    [(CtfeReflectInfo.Struct _ _ _ _ cleanup _ _) cleanup]
    [(CtfeReflectInfo.Enum _ _ _ _ cleanup _ _) cleanup]))

(define (ctfe-struct-field-reflection? [name : (& name str)]) : bool
  (or
    (string.eq name "struct-field-count")
    (string.eq name "struct-field-name")
    (string.eq name "struct-field-type")
    (string.eq name "struct-field-declared-align")))

;; The reflection queries answered from a nominal type's declaration metadata.
(define (ctfe-nominal-reflection
  [name : String]
  [pools : ast.AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [session : cis.InternStructuralSessionHandle]
  [found : CtfeMaybeReflectInfo]
  [index : i64]
  [second-index : i64]) : CtfeBuilt
  (match found
    [(CtfeMaybeReflectInfo.None)
      (cond
        [(string.eq name "type-cleanup-owning?")
          (CtfeBuilt.Ok (CompilerCtfeValue.Bool false))]
        ;; Only a `(:repr c)` struct can declare an alignment.
        [(string.eq name "type-declared-align")
          (CtfeBuilt.Ok (CompilerCtfeValue.I64 0))]
        [(string.eq name "type-cleanup-function")
          (ctfe-reflection-requires name "cleanup-owning type")]
        [(or
            (string.eq name "type-nominal-module")
            (string.eq name "type-nominal-name"))
          (ctfe-reflection-requires name "struct or enum type")]
        [(ctfe-struct-field-reflection? name)
          (ctfe-reflection-requires name "struct type")]
        [else (ctfe-reflection-requires name "enum type")])]
    [(CtfeMaybeReflectInfo.Some info)
      (cond
        [(string.eq name "type-declared-align")
          (CtfeBuilt.Ok
            (CompilerCtfeValue.I64
              (match info
                [(CtfeReflectInfo.Struct _ _ _ canonical-id _ _ _)
                  (ctfe-reflect-declared-align (& infos) canonical-id -1)]
                [(CtfeReflectInfo.Enum _ _ _ _ _ _ _) 0])))]
        [(string.eq name "type-cleanup-owning?")
          (CtfeBuilt.Ok
            (CompilerCtfeValue.Bool
              (match (ctfe-reflect-info-cleanup (clone info))
                [(CtfeReflectCleanup.No) false]
                [(CtfeReflectCleanup.Fn _ _) true])))]
        [(string.eq name "type-cleanup-function")
          (match (ctfe-reflect-info-cleanup (clone info))
            [(CtfeReflectCleanup.Fn cleanup-name cleanup-name-id)
              (CtfeBuilt.Ok
                (CompilerCtfeValue.String cleanup-name cleanup-name-id))]
            [(CtfeReflectCleanup.No)
              (ctfe-reflection-requires name "cleanup-owning type")])]
        [(string.eq name "type-nominal-module")
          (CtfeBuilt.Ok
            (ctfe-name-value-for-session
              session
              (ctfe-reflect-info-nominal-module-id info)))]
        [(string.eq name "type-nominal-name")
          (CtfeBuilt.Ok
            (ctfe-name-value-for-session
              session
              (ctfe-reflect-info-nominal-name-id info)))]
        [(ctfe-struct-field-reflection? name)
          (match info
            [(CtfeReflectInfo.Struct _ _ _ canonical-id _ fields _)
              (cond
                [(string.eq name "struct-field-declared-align")
                  (if (or
                    (< index 0)
                    (>= index (ctfe-reflect-field-list-count (& fields))))
                    (CtfeBuilt.Err (str_cat.str-cat name " index out of range"))
                    (CtfeBuilt.Ok
                      (CompilerCtfeValue.I64
                        (ctfe-reflect-declared-align
                          (& infos)
                          canonical-id
                          index))))]
                [(string.eq name "struct-field-count")
                  (CtfeBuilt.Ok
                    (CompilerCtfeValue.I64
                      (ctfe-reflect-field-list-count fields)))]
                [(string.eq name "struct-field-name")
                  (match (ctfe-reflect-field-name-at fields index)
                    [(ResultCtfeNameLookup.Ok field-name)
                      (CtfeBuilt.Ok
                        (ctfe-name-value-for-session session field-name))]
                    [(ResultCtfeNameLookup.Err message)
                      (CtfeBuilt.Err (str_cat.str-cat name " " message))])]
                [else
                  (ctfe-reflection-type-result
                    name
                    (ctfe-reflect-field-type-at fields pools infos index))])]
            [_ (ctfe-reflection-requires name "struct type")])]
        [else
          (match info
            [(CtfeReflectInfo.Enum _ _ _ _ _ variants _)
              (cond
                [(string.eq name "enum-variant-count")
                  (CtfeBuilt.Ok
                    (CompilerCtfeValue.I64
                      (ctfe-reflect-variant-list-count variants)))]
                [(string.eq name "enum-variant-name")
                  (match (ctfe-reflect-variant-name-at variants index)
                    [(ResultCtfeNameLookup.Ok variant-name)
                      (CtfeBuilt.Ok
                        (ctfe-name-value-for-session session variant-name))]
                    [(ResultCtfeNameLookup.Err message)
                      (CtfeBuilt.Err (str_cat.str-cat name " " message))])]
                [else
                  (match (ctfe-reflect-variant-payloads-at variants index)
                    [(ResultCtfeTypeListLookup.Ok payloads)
                      (if (string.eq name "enum-variant-payload-count")
                        (CtfeBuilt.Ok
                          (CompilerCtfeValue.I64
                            (ctfe-type-list-count payloads)))
                        (ctfe-reflection-type-result
                          name
                          (ctfe-type-list-ref-with-pools
                            payloads
                            pools
                            infos
                            second-index)))]
                    [(ResultCtfeTypeListLookup.Err message)
                      (CtfeBuilt.Err (str_cat.str-cat name " " message))])])]
            [_ (ctfe-reflection-requires name "enum type")])])]))

;; One type reflection query, named by its builtin, over an evaluated type and
;; the index operands of the indexed queries (`struct-field-name` and the
;; like; `enum-variant-payload-type` takes two).
(define (ctfe-type-reflection
  [name : String]
  [pools : ast.AstNodePoolContext]
  [infos : CtfeReflectInfoList]
  [session : cis.InternStructuralSessionHandle]
  [ty : ast.AstType]
  [index : i64]
  [second-index : i64]) : CtfeBuilt
  (cond
    [(string.eq name "type-info")
      (CtfeBuilt.Ok
        (CompilerCtfeValue.TypeInfo
          (ctfe-reflect-resolve-type-with-pools pools infos ty)))]
    [(string.eq name "type-kind")
      (CtfeBuilt.Ok
        (ctfe-generated-string-value
          (ctfe-type-kind-with-reflections-and-pools pools infos ty)))]
    [(string.eq name "type-key")
      (CtfeBuilt.Ok
        (ctfe-generated-string-value
          (ctfe-type-key-with-reflections-and-pools pools infos ty)))]
    [(or
        (string.eq name "tuple-element-count")
        (string.eq name "tuple-element-type"))
      (match (ctfe-reflect-resolve-type-with-pools pools infos ty)
        [(ast.AstType.Tuple elems)
          (if (string.eq name "tuple-element-count")
            (CtfeBuilt.Ok
              (CompilerCtfeValue.I64 (ctfe-type-list-count (deref elems))))
            (ctfe-reflection-type-result
              name
              (ctfe-type-list-ref-with-pools (deref elems) pools infos index)))]
        [_ (ctfe-reflection-requires name "tuple type")])]
    [(string.eq name "array-element-type")
      (match ty
        [(ast.AstType.Array elem _)
          (CtfeBuilt.Ok
            (CompilerCtfeValue.Type
              (ast.ast-node-pool-context-type-get pools elem)))]
        [(ast.AstType.DynArray elem)
          (CtfeBuilt.Ok
            (CompilerCtfeValue.Type
              (ast.ast-node-pool-context-type-get pools elem)))]
        [(ast.AstType.Slice elem)
          (CtfeBuilt.Ok
            (CompilerCtfeValue.Type
              (ast.ast-node-pool-context-type-get pools elem)))]
        [_ (ctfe-reflection-requires name "array type")])]
    [(string.eq name "box-element-type")
      (match ty
        [(ast.AstType.Box elem)
          (CtfeBuilt.Ok
            (CompilerCtfeValue.Type
              (ast.ast-node-pool-context-type-get pools elem)))]
        [_ (ctfe-reflection-requires name "box type")])]
    [(string.eq name "reference-element-type")
      (match ty
        [(ast.AstType.Ref _ elem)
          (CtfeBuilt.Ok
            (CompilerCtfeValue.Type
              (ast.ast-node-pool-context-type-get pools elem)))]
        [(ast.AstType.MutRef _ elem)
          (CtfeBuilt.Ok
            (CompilerCtfeValue.Type
              (ast.ast-node-pool-context-type-get pools elem)))]
        [_ (ctfe-reflection-requires name "reference type")])]
    [(string.eq name "array-length")
      (match ty
        [(ast.AstType.Array _ count)
          (CtfeBuilt.Ok (CompilerCtfeValue.I64 count))]
        [_ (ctfe-reflection-requires name "fixed array type")])]
    [(string.eq name "array-dynamic?")
      (match ty
        [(ast.AstType.Array _ _) (CtfeBuilt.Ok (CompilerCtfeValue.Bool false))]
        [(ast.AstType.DynArray _) (CtfeBuilt.Ok (CompilerCtfeValue.Bool true))]
        [_ (ctfe-reflection-requires name "array type")])]
    [(or
        (string.eq name "function-param-count")
        (string.eq name "function-return-type")
        (string.eq name "function-param-type"))
      (match ty
        [(ast.AstType.Func params ret)
          (cond
            [(string.eq name "function-param-count")
              (CtfeBuilt.Ok
                (CompilerCtfeValue.I64 (ctfe-type-list-count (deref params))))]
            [(string.eq name "function-return-type")
              (CtfeBuilt.Ok
                (CompilerCtfeValue.Type
                  (ast.ast-node-pool-context-type-get pools ret)))]
            [else
              (ctfe-reflection-type-result
                name
                (ctfe-type-list-ref-with-pools (deref params) pools infos index))])]
        [_ (ctfe-reflection-requires name "function type")])]
    [else
      (let
        [found : CtfeMaybeReflectInfo
          (ctfe-reflect-info-for-type-with-pools pools infos ty)]
        (ctfe-nominal-reflection
          name
          pools
          infos
          session
          found
          index
          second-index))]))

(define (ctfe-eval-type-reflection-at
  [name : String]
  [ty : ast.AstType]
  [index : i64]
  [second-index : i64]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (ctfe-built-result
    (ctfe-type-reflection
      name
      (ctfe-env-pools env)
      (ctfe-env-reflections env)
      (ctfe-env-structural-session env)
      ty
      index
      second-index)
    expr
    fuel))

(define (ctfe-eval-one-type-reflection
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (match (ctfe-eval-type-arg
      (ctfe-expr-arg args 0 env)
      expr
      env
      fuel
      (string.copy name))
      [(ResultCtfeTypeArg.Err d) (ResultCtfe.Err d)]
      [(ResultCtfeTypeArg.Ok ty arg-fuel)
        (ctfe-eval-type-reflection-at name ty 0 0 expr env arg-fuel)])
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (str_cat.str-cat name " expects exactly one type argument"))))))

;; The indexed queries take one i64 index after the type, and
;; enum-variant-payload-type a variant index and a payload index.
(define (ctfe-eval-indexed-type-reflection
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (let
    [payload? : bool (string.eq name "enum-variant-payload-type")]
    (if (=
      (ctfe-expr-arg-count args)
      (if payload?
        3
        2))
      (match (ctfe-eval-type-arg
        (ctfe-expr-arg args 0 env)
        expr
        env
        fuel
        (string.copy name))
        [(ResultCtfeTypeArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeTypeArg.Ok ty type-fuel)
          (match (ctfe-eval-i64-arg
            (ctfe-expr-arg args 1 env)
            expr
            env
            type-fuel
            (string.copy name))
            [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
            [(result_ctfe_i64_arg.Ok first)
              (if payload?
                (match (ctfe-eval-i64-arg
                  (ctfe-expr-arg args 2 env)
                  expr
                  env
                  first.fuel
                  (string.copy name))
                  [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
                  [(result_ctfe_i64_arg.Ok second)
                    (ctfe-eval-type-reflection-at
                      name
                      ty
                      first.value
                      second.value
                      expr
                      env
                      second.fuel)])
                (ctfe-eval-type-reflection-at
                  name
                  ty
                  first.value
                  0
                  expr
                  env
                  first.fuel))])])
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            (if payload?
              "enum-variant-payload-type expects exactly one type argument, one variant index, and one payload index"
              (str_cat.str-cat
                name
                " expects exactly one type argument and one index"))))))))

(define (ctfe-eval-reflection-query
  [name : String]
  [name-id : i64]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (let
    [_ctfe-builtin-refresh : unit (ctfe-builtin-refresh!)]
    (cond
      [(ctfe-builtin-reflection-primary-id? name-id)
        (ctfe-eval-one-type-reflection name args expr env fuel)]
      [(ctfe-builtin-reflection-secondary-id? name-id)
        (ctfe-eval-indexed-type-reflection name args expr env fuel)]
      [else (ctfe-unsupported-form expr)])))

(define (ctfe-eval-string-eq-call
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [left : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [right : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg left expr env fuel (string.copy name))
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeStringArg.Ok l _ left-fuel)
          (match (ctfe-eval-string-arg right expr env left-fuel name)
            [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
            [(ResultCtfeStringArg.Ok r _ right-fuel)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool (string.eq l r))
                right-fuel)])]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "string-eq expects two strings")))))

(define (ctfe-eval-string-append-call
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [left : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [right : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg left expr env fuel (string.copy name))
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeStringArg.Ok l left-id left-fuel)
          (match (ctfe-eval-string-arg right expr env left-fuel name)
            [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
            [(ResultCtfeStringArg.Ok r right-id right-fuel)
              (ResultCtfe.Ok
                (ctfe-generated-string-append-value l left-id r right-id)
                right-fuel)])]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "string-append expects two strings")))))

;; `comptime.string-slice` is the bounded byte-range operation needed by
;; literal-parsing macros. It operates only on comptime strings, never on a
;; runtime String value.
(define (ctfe-eval-comptime-string-slice-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 3)
    (let
      [text-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [start-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      [len-arg : ast.AstExpr (ctfe-expr-arg args 2 env)]
      (match (ctfe-eval-string-arg text-arg expr env fuel "string-slice")
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeStringArg.Ok text _ text-fuel)
          (match (ctfe-eval-i64-arg start-arg expr env text-fuel "string-slice")
            [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
            [(result_ctfe_i64_arg.Ok start-value)
              (match (ctfe-eval-i64-arg
                len-arg
                expr
                env
                start-value.fuel
                "string-slice")
                [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
                [(result_ctfe_i64_arg.Ok len-value)
                  (let
                    [start : i64 start-value.value]
                    [len : i64 len-value.value]
                    [text-len : i64 (string.string-length text)]
                    (if (or (< start 0) (< len 0) (> (+ start len) text-len))
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "string-slice range out of bounds")))
                      (ResultCtfe.Ok
                        (ctfe-generated-string-value
                          (string.substring text start len))
                        len-value.fuel)))])])]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "string-slice expects a string, start, and length")))))

(define (ctfe-eval-string-length-call
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-string-arg arg expr env fuel name)
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeStringArg.Ok text _ arg-fuel)
          (ResultCtfe.Ok
            (CompilerCtfeValue.I64 (string.string-length text))
            arg-fuel)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "string-length expects one string")))))

(define (ctfe-eval-string-ref-call
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [text : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [index : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg text expr env fuel (string.copy name))
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeStringArg.Ok s _ text-fuel)
          (ctfe-eval-string-ref-index s index expr env text-fuel name)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "string-ref expects a string and index")))))

(define (ctfe-eval-string-ref-index
  [text : String]
  [index-expr : ast.AstExpr]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [name : String]) : ResultCtfe
  (match (ctfe-eval-i64-arg index-expr origin env fuel name)
    [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
    [(result_ctfe_i64_arg.Ok index-arg-value)
      (if (or
        (< index-arg-value.value 0)
        (>= index-arg-value.value (string.string-length text)))
        (ResultCtfe.Err
          (box
            (ctfe-diagnostic-at-expr origin "string-ref index out of bounds")))
        (ResultCtfe.Ok
          (CompilerCtfeValue.Char
            (string.string-ref text index-arg-value.value))
          index-arg-value.fuel))]))

(define (ctfe-eval-string-to-int-call
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-string-arg arg expr env fuel name)
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeStringArg.Ok text _ arg-fuel)
          (ResultCtfe.Ok (CompilerCtfeValue.I64 (string.>int text)) arg-fuel)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "string.>int expects one string")))))

(define (ctfe-eval-int-to-string-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-i64-arg arg expr env fuel "string.int->string")
        [(result_ctfe_i64_arg.Err d) (ResultCtfe.Err d)]
        [(result_ctfe_i64_arg.Ok arg-value)
          (ResultCtfe.Ok
            (ctfe-generated-string-value (string.int->string arg-value.value))
            arg-value.fuel)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "string.int->string expects one i64")))))

;; User-facing stdlib.comptime helpers. Constructors, dense sequence helpers,
;; and provenance-sensitive reflection helpers remain CTFE bridge calls while
;; CTFE lacks general stdlib function calls and syntax values still carry
;; compiler-owned provenance/type metadata. Simple public inspectors are routed
;; through source-shaped match bodies below so their behavior follows the
;; ordinary stdlib.comptime definitions.
(define (ctfe-stdlib-string-helper-name? [name : (& name str)] [base : String]) : bool
  (and
    (ctfe-string-has-module-separator? (string.copy name))
    (or
      (ctfe-string-eq-after-prefix?
        (string.copy name)
        "string."
        (string.copy base))
      (ctfe-string-eq-after-prefix?
        (string.copy name)
        "string/"
        (string.copy base))
      (ctfe-string-eq-after-prefix?
        (string.copy name)
        "stdlib.string."
        (string.copy base))
      (ctfe-string-eq-after-prefix?
        (string.copy name)
        "stdlib.string/"
        (string.copy base))
      (ctfe-string-eq-after-prefix?
        (string.copy name)
        "stdlib/string."
        (string.copy base))
      (ctfe-string-eq-after-prefix?
        (string.copy name)
        "stdlib/string/"
        (string.copy base))
      (ctfe-string-eq-after-prefix?
        (string.copy name)
        "stdlib/string.tl."
        (string.copy base))
      (ctfe-string-eq-after-prefix?
        (string.copy name)
        "stdlib/string.tl/"
        (string.copy base))
      (ctfe-string-suffix-with-prefix?
        (string.copy name)
        "/stdlib/string.tl."
        (string.copy base))
      (ctfe-string-suffix-with-prefix?
        (string.copy name)
        "/stdlib/string.tl/"
        base))))

(define (ctfe-comptime-helper-base-after-prefix
  [name : String]
  [prefix : String]) : String
  (string.substring
    name
    (ctfe-private-string-length prefix)
    (- (ctfe-private-string-length name) (ctfe-private-string-length prefix))))

(define (ctfe-comptime-helper-lookup-name [name : String]) : String
  (cond
    [(ctfe-string-prefix? (string.copy name) "comptime.")
      (ctfe-comptime-helper-base-after-prefix name "comptime.")]
    [(ctfe-string-prefix? (string.copy name) "comptime/")
      (ctfe-comptime-helper-base-after-prefix name "comptime/")]
    [(ctfe-string-prefix? (string.copy name) "stdlib.comptime.")
      (ctfe-comptime-helper-base-after-prefix name "stdlib.comptime.")]
    [(ctfe-string-prefix? (string.copy name) "stdlib.comptime/")
      (ctfe-comptime-helper-base-after-prefix name "stdlib.comptime/")]
    [(ctfe-string-prefix? (string.copy name) "stdlib/comptime.")
      (ctfe-comptime-helper-base-after-prefix name "stdlib/comptime.")]
    [(ctfe-string-prefix? (string.copy name) "stdlib/comptime/")
      (ctfe-comptime-helper-base-after-prefix name "stdlib/comptime/")]
    [else name]))

(define (ctfe-comptime-error-helper-name? [name : String]) : bool
  (and
    (ctfe-string-has-module-separator? (string.copy name))
    (string.eq (ctfe-comptime-helper-lookup-name name) "error")))

(define (ctfe-string-eq-helper-name-id? [name : String] [name-id : i64]) : bool
  (or
    (ctfe-builtin-string-eq-id? name-id)
    (ctfe-stdlib-string-helper-name? name "eq")
    (ctfe-stdlib-string-helper-name? name "string-eq")
    (ctfe-stdlib-string-helper-name? name "string=?")))

(define (ctfe-string-length-helper-name-id? [name : String] [name-id : i64]) : bool
  (or
    (ctfe-builtin-string-length-id? name-id)
    (ctfe-stdlib-string-helper-name? name "string-length")))

(define (ctfe-string-ref-helper-name-id? [name : String] [name-id : i64]) : bool
  (or
    (ctfe-builtin-string-ref-id? name-id)
    (ctfe-stdlib-string-helper-name? name "string-ref")
    (ctfe-stdlib-string-helper-name? name "char-at")))

(define (ctfe-string-to-int-helper-name-id? [name : String] [name-id : i64]) : bool
  (or
    (ctfe-builtin-string-to-int-id? name-id)
    (ctfe-stdlib-string-helper-name? name ">int")))

;; Names recognized as comptime helper/accessor calls. `expr-list-length` and
;; `expr-list-nth` (and their clause/binding-clause variants) are handled by the
;; direct builtins in `ctfe-eval-call`. They stay listed here so the typechecker
;; recognizes them as comptime syntax operations. The list-like `empty?`/head/
;; tail operations were removed in favor of `length`/`nth` indexed access.
(define (ctfe-comptime-helper-leaf-id [name-id : i64]) : i64
  (if (not (ci.intern-renderable-id? name-id))
    name-id
    (let
      [base-id : i64
        (if (ci.intern-qualified? name-id)
          (ci.intern-qualified-base-id name-id)
          name-id)]
      [dotted-id : i64 (ci.intern-dotted-final-id base-id)]
      (if (>= dotted-id 0)
        dotted-id
        base-id))))

(define (ctfe-comptime-helper-call-name-id [name-id : i64]) : i64
  (begin
    (ctfe-builtin-refresh!)
    (let
      [leaf-id : i64 (ctfe-comptime-helper-leaf-id name-id)]
      (cond
        [(= leaf-id (ctfe-builtin "append")) (ctfe-builtin "string-append")]
        [(= leaf-id (ctfe-builtin "concat")) (ctfe-builtin "string-concat")]
        [(= leaf-id (ctfe-builtin ">int")) (ctfe-builtin ">int")]
        ;; Only comptime-qualified `error` aliases comptime-error. Keep this
        ;; uncommon ambiguity on the spelling path instead of slowing every
        ;; helper lookup.
        [(= leaf-id (ctfe-builtin "error"))
          (if (ctfe-comptime-error-helper-name? (ci.intern-str name-id))
            (ctfe-builtin "comptime-error")
            leaf-id)]
        [else leaf-id]))))

(define (ctfe-eval-comptime-error-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [message-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-string-arg message-arg expr env fuel "comptime-error")
        [(ResultCtfeStringArg.Ok message _ _next-fuel)
          (ResultCtfe.Err (box (ctfe-diagnostic-at-expr expr message)))]
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "comptime-error expects exactly one arg"))))))

(define (ctfe-eval-expr-bool-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.Bool b)
              (ResultCtfe.Ok
                (ctfe-syntax-expr-push
                  env
                  (ast.AstExpr.Literal (ast.AstLiteral.Bool b))
                  (ast.AstType.Bool))
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box (ctfe-diagnostic-at-expr expr "expr-bool expects bool")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "expr-bool expects exactly one arg"))))))

(define (ctfe-eval-expr-splice-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.Expr node ty)
              (ResultCtfe.Ok (CompilerCtfeValue.Expr node ty) arg-fuel)]
            [(CompilerCtfeValue.CapturedExpr node ty pools)
              (ResultCtfe.Ok
                (CompilerCtfeValue.CapturedExpr node ty pools)
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box (ctfe-diagnostic-at-expr expr "expr-splice expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "expr-splice expects exactly one arg"))))))

;; `(expr-int n)` builds an i64 literal Expr from a comptime integer, letting a
;; macro splice a computed count or index as a literal (unquote requires an Expr,
;; so a bare i64 cannot be spliced directly).
(define (ctfe-eval-expr-int-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.I64 n)
              (ResultCtfe.Ok
                (ctfe-syntax-expr-push
                  env
                  (ast.AstExpr.Literal (ast.ast-lit-int n))
                  (ast.AstType.I64))
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box (ctfe-diagnostic-at-expr expr "expr-int expects i64")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "expr-int expects exactly one arg"))))))

;; `(expr-string text)` builds a String literal Expr from a comptime string.
(define (ctfe-eval-expr-string-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match (ctfe-value-named value)
            [(CtfeMaybeNamed.Some _ string-id)
              (ResultCtfe.Ok
                (ctfe-syntax-expr-push
                  env
                  (ast.AstExpr.Literal (ast.AstLiteral.String string-id))
                  (ast.AstType.String))
                arg-fuel)]
            [(CtfeMaybeNamed.None)
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr expr "expr-string expects String")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "expr-string expects exactly one arg"))))))

;; Compiler-build-only LZSS compression for explicit embedded stdlib inputs.
;; The loader performs this transform at the declaration boundary so macro
;; expansion never constructs source-sized syntax trees.
(defstruct CtfeEmbeddedStdlibLzssMatch
  (offset i64)
  (len i64))

;; Raw byte read for the compressor. Every call site is guarded so `index`
;; stays inside the source string, matching the checked string.string-ref
;; accessor path it replaced.
(define (ctfe-embedded-stdlib-lzss-byte [data : (Ptr u8)] [index : i64]) : i64
  (cast
    (unsafe
      (ptr-read (ptr-offset data index)))
    : i64))

;; Unaligned 8-byte read; caller guarantees index+8 is within the source.
(define (ctfe-embedded-stdlib-lzss-word [data : (Ptr u8)] [index : i64]) : i64
  (unsafe
    (ptr-read (ptr-cast (ptr-offset data index) : (Ptr i64)))))

;; The weighted trigram sum is at most 255*251 + 255*31 + 255 = 72165 and never
;; negative, so masking with 65535 reproduces the `% 65536` bucket exactly while
;; avoiding the signed-remainder sequence the modulo lowers to.
(define (ctfe-embedded-stdlib-lzss-hash [data : (Ptr u8)] [index : i64]) : i64
  (bit-and
    (+
      (* (ctfe-embedded-stdlib-lzss-byte data index) 251)
      (* (ctfe-embedded-stdlib-lzss-byte data (+ index 1)) 31)
      (ctfe-embedded-stdlib-lzss-byte data (+ index 2)))
    65535))

(define (ctfe-embedded-stdlib-array-fill!
  [items : (&mut items (__tl_dyn-array i64))]
  [value : i64]) : unit
  (let
    [index : i64 0]
    (while (< index (array-length items))
      (begin
        (set! (array-ref items index) value)
        (set! index (+ index 1))))))

;; `head` and `previous` are the raw element storage of the two index arrays the
;; compressor owns for the length of one compression. Both subscripts are
;; statically in range: the hash is masked to 0..65535 and `head` has 65536
;; slots, and the guard above keeps `index` inside 0..source-len-3 while
;; `previous` has source-len slots.
(define (ctfe-embedded-stdlib-lzss-insert!
  [data : (Ptr u8)]
  [source-len : i64]
  [head : (MutPtr i64)]
  [previous : (MutPtr i64)]
  [index : i64]) : unit
  (if (> (+ index 2) (- source-len 1))
    unit
    (let
      [slot : (MutPtr i64)
        (unsafe
          (ptr-offset head (ctfe-embedded-stdlib-lzss-hash data index)))]
      (unsafe
        (begin
          (ptr-write! (ptr-offset previous index) (ptr-read slot))
          (ptr-write! slot index))))))

;; Same stores as calling insert! for each position in the range, with the
;; per-position guard turned into the loop bound: insert! indexes exactly the
;; positions with index + 2 <= source-len - 1, that is index < source-len - 2.
(define (ctfe-embedded-stdlib-lzss-insert-range!
  [data : (Ptr u8)]
  [source-len : i64]
  [head : (MutPtr i64)]
  [previous : (MutPtr i64)]
  [start : i64]
  [count : i64]) : unit
  (let
    [index : i64 start]
    [limit : i64 (- source-len 2)]
    [end : i64
      (let
        [stop : i64 (+ start count)]
        (if (< stop limit)
          stop
          limit))]
    (while (< index end)
      (let
        [slot : (MutPtr i64)
          (unsafe
            (ptr-offset head (ctfe-embedded-stdlib-lzss-hash data index)))]
        (begin
          (unsafe
            (begin
              (ptr-write! (ptr-offset previous index) (ptr-read slot))
              (ptr-write! slot index)))
          (set! index (+ index 1)))))))

;; Longest common prefix of the candidate and cursor spans, capped by `cap`
;; (= min(18, source-len - index)). Words compare 8 bytes at a time; the byte
;; tail finds the first mismatch inside a differing word or finishes the
;; sub-word remainder. Word reads stay in bounds because length+8 <= cap
;; implies index+length+8 <= source-len (and candidate < index).
(define (ctfe-embedded-stdlib-lzss-match-len
  [data : (Ptr u8)]
  [cap : i64]
  [candidate : i64]
  [index : i64]) : i64
  (let
    [length : i64 0]
    [words-done : bool false]
    [tail-done : bool false]
    (begin
      (while (and (not words-done) (<= (+ length 8) cap))
        (if (=
          (ctfe-embedded-stdlib-lzss-word data (+ candidate length))
          (ctfe-embedded-stdlib-lzss-word data (+ index length)))
          (set! length (+ length 8))
          (set! words-done true)))
      (while (and (not tail-done) (< length cap))
        (if (=
          (ctfe-embedded-stdlib-lzss-byte data (+ candidate length))
          (ctfe-embedded-stdlib-lzss-byte data (+ index length)))
          (set! length (+ length 1))
          (set! tail-done true)))
      length)))

(define (ctfe-embedded-stdlib-lzss-find-match
  [data : (Ptr u8)]
  [source-len : i64]
  [head : (Ptr i64)]
  [previous : (Ptr i64)]
  [index : i64]) : CtfeEmbeddedStdlibLzssMatch
  (if (> (+ index 2) (- source-len 1))
    (CtfeEmbeddedStdlibLzssMatch 0 0)
    (let
      [candidate : i64
        (unsafe
          (ptr-read
            (ptr-offset head (ctfe-embedded-stdlib-lzss-hash data index))))]
      [best-offset : i64 0]
      [best-len : i64 0]
      [cap : i64
        (let
          [avail : i64 (- source-len index)]
          (if (< avail 18)
            avail
            18))]
      ;; `floor` folds the two chain-walk stops into one compare: a chain link
      ;; is -1 at the end, so `candidate >= max(0, index-4096)` holds exactly
      ;; when `candidate >= 0` and `index - candidate <= 4096` both hold.
      [floor : i64
        (let
          [oldest : i64 (- index 4096)]
          (if (< oldest 0)
            0
            oldest))]
      ;; A local view of the chain array: reading it through the parameter
      ;; keeps reloading the spilled pointer inside the scan below.
      [chain : (Ptr i64)
        (unsafe
          (ptr-offset previous 0))]
      (begin
        ;; best-len < cap exits once no candidate can improve the match; the
        ;; replaced best-len < 18 condition kept walking candidates that could
        ;; not win. It also bounds both reads below: index+best-len is under
        ;; source-len whenever the body runs.
        (while (< best-len cap)
          (let
            ;; The cursor side of the one-byte filter is fixed for the whole
            ;; scan, so hoist the read out of it.
            [probe : i64
              (ctfe-embedded-stdlib-lzss-byte data (+ index best-len))]
            (begin
              ;; A candidate can only beat best-len by matching at offset
              ;; best-len too, so one byte probe skips most full scans without
              ;; changing which candidate wins. Rejected candidates leave every
              ;; other loop variable alone, so the scan for the next surviving
              ;; candidate is its own loop over `candidate` -- that keeps the
              ;; many chain links that lose the probe off the merge path the
              ;; wider loop needs for best-len and best-offset.
              (while (and
                (>= candidate floor)
                (not
                  (=
                    (ctfe-embedded-stdlib-lzss-byte data (+ candidate best-len))
                    probe)))
                (set!
                  candidate
                  (unsafe
                    (ptr-read (ptr-offset chain candidate)))))
              (if (< candidate floor)
                (return (CtfeEmbeddedStdlibLzssMatch best-offset best-len))
                (let
                  [length : i64
                    (ctfe-embedded-stdlib-lzss-match-len
                      data
                      cap
                      candidate
                      index)]
                  (begin
                    (when
                      (> length best-len)
                      (begin
                        (set! best-len length)
                        (set! best-offset (- index candidate))))
                    (set!
                      candidate
                      (unsafe
                        (ptr-read (ptr-offset chain candidate))))))))))
        (CtfeEmbeddedStdlibLzssMatch best-offset best-len)))))

(define (ctfe-embedded-stdlib-lzss-compress [source : String]) : String
  (let
    [source-len : i64 (string.string-length source)]
    [data : (Ptr u8)
      (unsafe
        (string-data (& source)))]
    [head : (__tl_dyn-array i64) (__tl_make-array i64 65536)]
    ;; `previous` needs no -1 fill: chain reads only visit indices already
    ;; written by insert! (head points at an inserted index, and previous[i]
    ;; is stored when i is inserted), so its initial contents are never read.
    [previous : (__tl_dyn-array i64) (__tl_make-array i64 source-len)]
    ;; Both index arrays keep a fixed length for the whole compression, so their
    ;; element storage never moves and the raw views below stay valid until the
    ;; owners drop at the end of this let.
    [head-slots : (MutPtr i64)
      (unsafe
        (__tl_array-data head))]
    [previous-slots : (MutPtr i64)
      (unsafe
        (__tl_array-data previous))]
    [head-view : (Ptr i64)
      (unsafe
        (ptr-cast head-slots : (Ptr i64)))]
    [previous-view : (Ptr i64)
      (unsafe
        (ptr-cast previous-slots : (Ptr i64)))]
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity
        (+ source-len (+ (/ source-len 8) 1)))]
    [index : i64 0]
    (begin
      (ctfe-embedded-stdlib-array-fill! (&mut head) -1)
      (while (< index source-len)
        (let
          [flag-index : i64 (byte_buf_core.byte-buf-builder-len (& out))]
          [flags : i64 0]
          [bit : i64 0]
          (begin
            (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0 : u8))
            (while (and (< bit 8) (< index source-len))
              (match (ctfe-embedded-stdlib-lzss-find-match
                data
                source-len
                head-view
                previous-view
                index)
                [(CtfeEmbeddedStdlibLzssMatch offset length)
                  (if (>= length 3)
                    (let
                      [packed : i64 (+ (shl (- offset 1) 4) (- length 3))]
                      (begin
                        (byte_buf_core.byte-buf-builder-push
                          (&mut out)
                          (cast (shr packed 8) : u8))
                        (byte_buf_core.byte-buf-builder-push
                          (&mut out)
                          (cast (bit-and packed 255) : u8))
                        (ctfe-embedded-stdlib-lzss-insert-range!
                          data
                          source-len
                          head-slots
                          previous-slots
                          index
                          length)
                        (set! index (+ index length))))
                    (begin
                      (set! flags (bit-or flags (shl 1 bit)))
                      (byte_buf_core.byte-buf-builder-push
                        (&mut out)
                        (cast (ctfe-embedded-stdlib-lzss-byte data index) : u8))
                      (ctfe-embedded-stdlib-lzss-insert!
                        data
                        source-len
                        head-slots
                        previous-slots
                        index)
                      (set! index (+ index 1))))])
              (set! bit (+ bit 1)))
            (set! (array-ref out.slots flag-index) (cast flags : u8)))))
      (byte_buf_core.byte-buf-builder-to-string (& out)))))

(define (ctfe-embedded-stdlib-compressed-prefix) : String
  "__typelisp_embedded_stdlib_lzss_v1__")

(define (ctfe-embedded-stdlib-binary-data-bytes [source : String]) : String
  (str_cat.str-cat
    (ctfe-embedded-stdlib-compressed-prefix)
    (string.int->string (string.string-length source))
    "\n"
    (ctfe-embedded-stdlib-lzss-compress source)))

;; `(expr-binary-data bytes)` builds an opaque static private
;; `(__tl_dyn-array u8)` payload.
(define (ctfe-eval-expr-binary-data-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.String bytes _)
              (ResultCtfe.Ok
                (ctfe-syntax-expr-push
                  env
                  (ast.AstExpr.BinaryData bytes)
                  (ast.ast-ty-dyn-array-with-pools
                    (ctfe-env-pools env)
                    (ast.AstType.U8)))
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-binary-data expects String")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "expr-binary-data expects exactly one arg"))))))

;; String-literal inspection intentionally uses helpers instead of growing the
;; verified public `Expr` enum. This keeps older stage0 compilers able to read
;; the declaration while exposing only the stable literal surface macros need.
(define (ctfe-eval-expr-string-inspector-call
  [extract? : bool]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.String text string-id)
              (if extract?
                (ResultCtfe.Ok
                  (CompilerCtfeValue.String text string-id)
                  arg-fuel)
                (ResultCtfe.Ok (CompilerCtfeValue.Bool true) arg-fuel))]
            [(CompilerCtfeValue.Name text name-id)
              (if extract?
                (ResultCtfe.Ok (CompilerCtfeValue.String text name-id) arg-fuel)
                (ResultCtfe.Ok (CompilerCtfeValue.Bool true) arg-fuel))]
            [(CompilerCtfeValue.Expr node _)
              (match (ctfe-expr-unspan env (ctfe-ast-get env node))
                [(ast.AstExpr.Literal (ast.AstLiteral.String string-id))
                  (if extract?
                    (ResultCtfe.Ok
                      (ctfe-source-string-value-for-session
                        (ctfe-env-structural-session env)
                        string-id)
                      arg-fuel)
                    (ResultCtfe.Ok (CompilerCtfeValue.Bool true) arg-fuel))]
                [_
                  (if extract?
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "expr-string-value expects a string literal Expr")))
                    (ResultCtfe.Ok (CompilerCtfeValue.Bool false) arg-fuel))])]
            [_
              (if extract?
                (ResultCtfe.Err
                  (box
                    (ctfe-diagnostic-at-expr
                      expr
                      "expr-string-value expects a string literal Expr")))
                (ResultCtfe.Ok (CompilerCtfeValue.Bool false) arg-fuel))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "expr-string inspector expects exactly one arg"))))))

;; `(expr-var name)` builds a variable-reference Expr from a comptime string.
(define (ctfe-eval-expr-var-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match (ctfe-value-syntax-name-id (ctfe-env-source-names env) value)
            [(CtfeMaybeNameId.Some name-id)
              (ResultCtfe.Ok
                (ctfe-syntax-expr-push
                  env
                  (ast.AstExpr.Var name-id)
                  (ctfe-untyped-expr-type))
                arg-fuel)]
            [(CtfeMaybeNameId.None)
              (ResultCtfe.Err
                (box (ctfe-diagnostic-at-expr expr "expr-var expects String")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "expr-var expects exactly one arg"))))))

(define (ctfe-eval-module-name-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-string-arg arg expr env fuel "module-name")
        [(ResultCtfeStringArg.Ok module module-id next-fuel)
          (ResultCtfe.Ok (CompilerCtfeValue.String module module-id) next-fuel)]
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "module-name expects exactly one arg"))))))

(define (ctfe-eval-module-export-macro-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [module-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [name-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg
        module-arg
        expr
        env
        fuel
        "module-export-macro?")
        [(ResultCtfeStringArg.Ok module module-id module-fuel)
          (match (ctfe-eval-string-arg
            name-arg
            expr
            env
            module-fuel
            "module-export-macro?")
            [(ResultCtfeStringArg.Ok name name-id name-fuel)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (or
                    (string.eq module "")
                    (ctfe-module-macro-export-id-for-state?
                      (ctfe-env-macro-state env)
                      module-id
                      name-id)))
                name-fuel)]
            [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)])]
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "module-export-macro? expects exactly two args")))))

;; Look up a module value by its resolved identities. `query-kind` 0 answers
;; module-value?, 1 its public signature (module-value-type), and 2 a reference
;; to it (module-value-expr).
(define (ctfe-module-value
  [state : CompilerCtfeMacroState]
  [pools : ast.AstNodePoolContext]
  [query-kind : i64]
  [module : String]
  [module-id : i64]
  [name : String]
  [name-id : i64]) : CtfeBuilt
  (match (ctfe-module-value-type-id-for-state state module-id name-id)
    [(CtfeMaybeModuleValueType.Some ty)
      (CtfeBuilt.Ok
        (cond
          [(= query-kind 0) (CompilerCtfeValue.Bool true)]
          [(= query-kind 1) (CompilerCtfeValue.Type ty)]
          [else
            (CompilerCtfeValue.Expr
              (ast.ast-node-pool-context-expr-push
                pools
                (ast.AstExpr.Var
                  (if (string.eq module "")
                    name-id
                    (if (or
                      (ci.intern-generated-canonical-id? module-id)
                      (ci.intern-generated-canonical-id? name-id))
                      (ctfe-generated-dotted-append-member-id module-id name-id)
                      (ci.intern
                        (str_cat.str-cat module (str_cat.str-cat "." name)))))))
              (ctfe-untyped-expr-type))]))]
    [(CtfeMaybeModuleValueType.None)
      (if (= query-kind 0)
        (CtfeBuilt.Ok (CompilerCtfeValue.Bool false))
        (CtfeBuilt.Err
          (str_cat.str-cat
            (if (= query-kind 1)
              "module-value-type"
              "module-value-expr")
            ": module "
            module
            " does not define value "
            name)))]))

(define (ctfe-eval-module-value-call
  [query-name : String]
  [query-kind : i64]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [module-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [name-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-module-index-arg
        module-arg
        expr
        env
        fuel
        (owned_view.compiler-owned-shared-view query-name))
        [(ResultCtfeStringArg.Ok module module-id module-fuel)
          (match (ctfe-eval-module-index-arg
            name-arg
            expr
            env
            module-fuel
            query-name)
            [(ResultCtfeStringArg.Ok name name-id name-fuel)
              (ctfe-built-result
                (ctfe-module-value
                  (ctfe-env-macro-state env)
                  (ctfe-env-pools env)
                  query-kind
                  module
                  module-id
                  name
                  name-id)
                expr
                name-fuel)]
            [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)])]
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (str_cat.str-cat query-name " expects exactly two args"))))))

;; Owner-module formatting accepts only an immutable shared borrow of the
;; nominal value and a String result. Borrowed field projections expose one
;; Region wrapper around the nominal type; compare that wrapper's element so
;; the protocol behaves identically for lvalues, projections, and rvalues.
(define (ctfe-function-shared-borrow-returns-string?
  [env : CtfeEnv]
  [signature : ast.AstType]
  [value-type : ast.AstType]) : bool
  (let
    [expected-type : ast.AstType
      (match (owned_view.compiler-owned-shared-view value-type)
        [(ast.AstType.Region _ inner) (ctfe-ty-get env inner)]
        [_ value-type])]
    (match signature
      [(ast.AstType.Func params ret)
        (let
          [param-list : ast.AstTypeList (deref params)]
          (if (=
            (ctfe-type-list-count
              (owned_view.compiler-owned-shared-view param-list))
            1)
            (let
              [parameter : ast.AstType
                (ctfe-ty-get
                  env
                  (ast.ast-type-list-get
                    (& param-list)
                    0
                    (ast.ast-type-id-fallback)))]
              (match parameter
                [(ast.AstType.Ref _ inner)
                  (and
                    (ctfe-type-eq-in-env
                      env
                      (ctfe-ty-get env inner)
                      expected-type)
                    (ctfe-type-eq-in-env
                      env
                      (ctfe-ty-get env ret)
                      (ast.AstType.String)))]
                [_ false]))
            false))]
      [_ false])))

(define (ctfe-eval-function-shared-borrow-returns-string-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [signature-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [value-type-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-type-arg
        signature-arg
        expr
        env
        fuel
        "function-shared-borrow-returns-string?")
        [(ResultCtfeTypeArg.Err d) (ResultCtfe.Err d)]
        [(ResultCtfeTypeArg.Ok signature signature-fuel)
          (match (ctfe-eval-type-arg
            value-type-arg
            expr
            env
            signature-fuel
            "function-shared-borrow-returns-string?")
            [(ResultCtfeTypeArg.Err d) (ResultCtfe.Err d)]
            [(ResultCtfeTypeArg.Ok value-type value-type-fuel)
              (ResultCtfe.Ok
                (CompilerCtfeValue.Bool
                  (ctfe-function-shared-borrow-returns-string?
                    env
                    signature
                    value-type))
                value-type-fuel)])]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "function-shared-borrow-returns-string? expects exactly two type arguments")))))

(define (ctfe-module-hook-missing-message [module : String] [name : String]) : String
  (str_cat.str-cat
    "typecheck: strategy module "
    module
    " does not export hook "
    name))

;; Resolve a named macro hook: a successful lookup is one canonical qualified
;; Var expression.
(define (ctfe-module-hook
  [state : CompilerCtfeMacroState]
  [pools : ast.AstNodePoolContext]
  [module : String]
  [module-id : i64]
  [name : String]
  [name-id : i64]) : CtfeBuilt
  (if (or
    (string.eq module "")
    (ctfe-module-macro-export-id-for-state? state module-id name-id))
    (CtfeBuilt.Ok
      (CompilerCtfeValue.Expr
        (ast.ast-node-pool-context-expr-push
          pools
          (ast.AstExpr.Var
            (if (string.eq module "")
              name-id
              (ci.intern-composite-pair-id module-id name-id))))
        (ctfe-untyped-expr-type)))
    (CtfeBuilt.Err (ctfe-module-hook-missing-message module name))))

(define (ctfe-eval-module-hook-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [module-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [name-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg module-arg expr env fuel "module-hook")
        [(ResultCtfeStringArg.Ok module module-id module-fuel)
          (match (ctfe-eval-string-arg
            name-arg
            expr
            env
            module-fuel
            "module-hook")
            [(ResultCtfeStringArg.Ok name name-id name-fuel)
              (ctfe-built-result
                (ctfe-module-hook
                  (ctfe-env-macro-state env)
                  (ctfe-env-pools env)
                  module
                  module-id
                  name
                  name-id)
                expr
                name-fuel)]
            [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)])]
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "module-hook expects exactly two args")))))

;; `(expr-struct-get target field)` builds a struct-get Expr whose field name is
;; computed at macro CTFE. The expanded program typechecks the field access.
(define (ctfe-eval-expr-struct-get-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [target-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [field-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval target-arg env fuel)
        [(ResultCtfe.Ok target-val target-fuel)
          (match target-val
            [(CompilerCtfeValue.Expr target-node _)
              (match (compiler-ctfe-eval field-arg env target-fuel)
                [(ResultCtfe.Ok field-val field-fuel)
                  (match (ctfe-value-syntax-name-id
                    (ctfe-env-source-names env)
                    field-val)
                    [(CtfeMaybeNameId.Some field-id)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.Expr
                          (ast.ast-expr-struct-get-id-with-pools
                            (ctfe-env-pools env)
                            target-node
                            field-id)
                          (ctfe-untyped-expr-type))
                        field-fuel)]
                    [(CtfeMaybeNameId.None)
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-struct-get field expects String")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-struct-get target expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "expr-struct-get expects exactly two args")))))

;; `(expr-tuple-ref target index)` builds a tuple-ref Expr whose index is
;; computed at macro CTFE. The expanded program typechecks the tuple access.
(define (ctfe-eval-expr-tuple-ref-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [target-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [index-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval target-arg env fuel)
        [(ResultCtfe.Ok target-val target-fuel)
          (match target-val
            [(CompilerCtfeValue.Expr target-node _)
              (match (compiler-ctfe-eval index-arg env target-fuel)
                [(ResultCtfe.Ok index-val index-fuel)
                  (match index-val
                    [(CompilerCtfeValue.I64 index)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.Expr
                          (ast.ast-expr-tuple-ref-with-pools
                            (ctfe-env-pools env)
                            target-node
                            index)
                          (ctfe-untyped-expr-type))
                        index-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-tuple-ref index expects i64")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-tuple-ref target expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "expr-tuple-ref expects exactly two args")))))

(define (ctfe-expr-lambda1-node
  [pools : ast.AstNodePoolContext]
  [name-id : i64]
  [parameter-type : ast.AstType]
  [body-node : i64]) : i64
  (let
    [params : ast.AstParamList (ast.ast-param-list-with-capacity 1)]
    (begin
      (ast.ast-param-list-push
        (&mut params)
        (ast.AstParam.Param name-id parameter-type false))
      (ast.ast-expr-lambda-with-pools
        pools
        params
        (ast.AstMaybeType.No)
        body-node))))

;; `(expr-lambda1 name parameter-type body)` builds a one-parameter lambda
;; around a body assembled from syntax builders. The binding name preserves a
;; `syntax-name-fresh` identity and the reflected type remains opaque.
(define (ctfe-eval-expr-lambda1-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 3)
    (let
      [name-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [type-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      [body-arg : ast.AstExpr (ctfe-expr-arg args 2 env)]
      (match (ctfe-eval-syntax-name-arg name-arg expr env fuel "expr-lambda1")
        [(ResultCtfeNameArg.Ok name-id name-fuel)
          (match (ctfe-eval-type-arg type-arg expr env name-fuel "expr-lambda1")
            [(ResultCtfeTypeArg.Ok parameter-type type-fuel)
              (match (compiler-ctfe-eval body-arg env type-fuel)
                [(ResultCtfe.Ok body-value body-fuel)
                  (let
                    [body-node : i64
                      (ctfe-syntax-expr-value-node body-value (& env))]
                    (if (< body-node 0)
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-lambda1 body expects Expr")))
                      (ResultCtfe.Ok
                        (ctfe-syntax-expr-value
                          env
                          (ctfe-expr-lambda1-node
                            (ctfe-env-syntax-pool-context env)
                            name-id
                            parameter-type
                            body-node)
                          (ctfe-untyped-expr-type))
                        body-fuel)))]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [(ResultCtfeTypeArg.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfeNameArg.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "expr-lambda1 expects exactly three args")))))

;; `(expr-struct-set target field value)` builds a struct field assignment whose
;; field name is computed at macro CTFE. The expanded program typechecks the
;; assignment target and value.
(define (ctfe-eval-expr-struct-set-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 3)
    (let
      [target-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [field-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      [value-arg : ast.AstExpr (ctfe-expr-arg args 2 env)]
      (match (compiler-ctfe-eval target-arg env fuel)
        [(ResultCtfe.Ok target-val target-fuel)
          (match target-val
            [(CompilerCtfeValue.Expr target-node _)
              (match (compiler-ctfe-eval field-arg env target-fuel)
                [(ResultCtfe.Ok field-val field-fuel)
                  (match (ctfe-value-syntax-name-id
                    (ctfe-env-source-names env)
                    field-val)
                    [(CtfeMaybeNameId.Some field-id)
                      (match (compiler-ctfe-eval value-arg env field-fuel)
                        [(ResultCtfe.Ok value-val value-fuel)
                          (match value-val
                            [(CompilerCtfeValue.Expr value-node _)
                              (ResultCtfe.Ok
                                (CompilerCtfeValue.Expr
                                  (ast.ast-expr-struct-set-id-with-pools
                                    (ctfe-env-pools env)
                                    target-node
                                    field-id
                                    value-node)
                                  (ast.AstType.Unit))
                                value-fuel)]
                            [_
                              (ResultCtfe.Err
                                (box
                                  (ctfe-diagnostic-at-expr
                                    expr
                                    "expr-struct-set value expects Expr")))])]
                        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
                    [(CtfeMaybeNameId.None)
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-struct-set field expects String")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-struct-set target expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "expr-struct-set expects exactly three args")))))

;; `expr-borrow` and `expr-mut-borrow` build explicit inferred-lifetime borrow
;; syntax nodes. The generated program owns the ordinary place and borrow checks.
(define (ctfe-eval-expr-borrow-call
  [mutable : bool]
  [builder-name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [place-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval place-arg env fuel)
        [(ResultCtfe.Ok place-value place-fuel)
          (let
            [place-node : i64 (ctfe-syntax-expr-value-node place-value (& env))]
            (if (>= place-node 0)
              (ResultCtfe.Ok
                (ctfe-syntax-expr-value
                  env
                  (ast.ast-expr-borrow-with-pools
                    (ctfe-env-syntax-pool-context-live env)
                    mutable
                    ast.AstBorrowLifetime.Inferred
                    place-node)
                  (ctfe-untyped-expr-type))
                place-fuel)
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    (str_cat.str-cat builder-name " expects Expr"))))))]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (str_cat.str-cat builder-name " expects exactly one arg"))))))

;; `(expr-array-ref target index)` builds an ordinary checked array-reference
;; syntax node without attaching the macro implementation's source location.
(define (ctfe-eval-expr-array-ref-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [target-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [index-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval target-arg env fuel)
        [(ResultCtfe.Ok target-value target-fuel)
          (let
            [target-node : i64
              (ctfe-syntax-expr-value-node target-value (& env))]
            (if (>= target-node 0)
              (match (compiler-ctfe-eval index-arg env target-fuel)
                [(ResultCtfe.Ok index-value index-fuel)
                  (let
                    [index-node : i64
                      (ctfe-syntax-expr-value-node index-value (& env))]
                    (if (>= index-node 0)
                      (ResultCtfe.Ok
                        (ctfe-syntax-expr-value
                          env
                          (ast.ast-expr-array-ref-with-pools
                            (ctfe-env-pools env)
                            target-node
                            index-node)
                          (ctfe-untyped-expr-type))
                        index-fuel)
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-array-ref index expects Expr")))))]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-array-ref target expects Expr")))))]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "expr-array-ref expects exactly two args")))))

;; `(expr-replace place replacement)` builds the dedicated replacement node;
;; ownership and place validity are checked after macro expansion.
(define (ctfe-eval-expr-replace-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [place-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [replacement-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval place-arg env fuel)
        [(ResultCtfe.Ok place-value place-fuel)
          (let
            [place-node : i64 (ctfe-syntax-expr-value-node place-value (& env))]
            (if (>= place-node 0)
              (match (compiler-ctfe-eval replacement-arg env place-fuel)
                [(ResultCtfe.Ok replacement-value replacement-fuel)
                  (let
                    [replacement-node : i64
                      (ctfe-syntax-expr-value-node replacement-value (& env))]
                    (if (>= replacement-node 0)
                      (ResultCtfe.Ok
                        (ctfe-syntax-expr-value
                          env
                          (ast.ast-expr-replace-with-pools
                            (ctfe-env-pools env)
                            place-node
                            replacement-node)
                          (ctfe-untyped-expr-type))
                        replacement-fuel)
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-replace replacement expects Expr")))))]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-replace place expects Expr")))))]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "expr-replace expects exactly two args")))))

;; Build the ordered, persistent syntax-list values used by expression calls.
(define (ctfe-eval-expr-list-empty-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 0)
    (ResultCtfe.Ok (CompilerCtfeValue.ExprList (ast.ast-expr-list-new)) fuel)
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-list-empty expects no args")))))

(define (ctfe-eval-expr-list-cons-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [head-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [tail-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval head-arg env fuel)
        [(ResultCtfe.Ok head-value head-fuel)
          (let
            [head-node : i64 (ctfe-syntax-expr-value-node head-value (& env))]
            (if (>= head-node 0)
              (match (compiler-ctfe-eval tail-arg env head-fuel)
                [(ResultCtfe.Ok tail-value tail-fuel)
                  (match tail-value
                    [(CompilerCtfeValue.ExprList tail)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.ExprList
                          (ast.ast-expr-cons head-node tail))
                        tail-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-list-cons tail expects ExprList")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-list-cons head expects Expr")))))]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "expr-list-cons expects exactly two args")))))

;; `(expr-call callee args)` preserves the supplied argument order and builds
;; ordinary call syntax. Typechecking of that call happens after macro expansion.
(define (ctfe-eval-expr-call-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [callee-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [args-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval callee-arg env fuel)
        [(ResultCtfe.Ok callee-value callee-fuel)
          (let
            [callee-node : i64
              (ctfe-syntax-expr-value-node callee-value (& env))]
            (if (>= callee-node 0)
              (match (compiler-ctfe-eval args-arg env callee-fuel)
                [(ResultCtfe.Ok args-value args-fuel)
                  (match args-value
                    [(CompilerCtfeValue.ExprList call-args)
                      (ResultCtfe.Ok
                        (ctfe-syntax-expr-value
                          env
                          (ctfe-ast-expr-call-with-provenance
                            (ctfe-env-macro-state env)
                            (ctfe-env-syntax-pool-context-live env)
                            callee-node
                            call-args)
                          (ctfe-untyped-expr-type))
                        args-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-call args expects ExprList")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr expr "expr-call callee expects Expr")))))]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-call expects exactly two args")))))

;; Shared-borrow calls may lend an existing place directly. A temporary needs a
;; lexical owner for the duration of the call, so synthesize one inferred local
;; and call through that local. This preserves single evaluation without moving
;; caller-owned lvalues.
(define (ctfe-expr-borrowable-place-node-with-pools?
  [pools : (& pools ast.AstNodePoolContext)]
  [node : i64]) : bool
  (match (ast.ast-expr-unspan-with-pools
    pools
    (ast.ast-node-pool-context-expr-get pools node))
    [(ast.AstExpr.Var _) true]
    [(ast.AstExpr.StructGet receiver _)
      (ctfe-expr-borrowable-place-node-with-pools? pools receiver)]
    [(ast.AstExpr.TupleRef receiver _)
      (ctfe-expr-borrowable-place-node-with-pools? pools receiver)]
    [(ast.AstExpr.ArrayRef receiver _)
      (ctfe-expr-borrowable-place-node-with-pools? pools receiver)]
    [(ast.AstExpr.BoxGet receiver)
      (ctfe-expr-borrowable-place-node-with-pools? pools receiver)]
    [(ast.AstExpr.BoxTake receiver)
      (ctfe-expr-borrowable-place-node-with-pools? pools receiver)]
    [_ false]))

(define (ctfe-expr-shared-call1-node-with-pools
  [state : CompilerCtfeMacroState]
  [pools : ast.AstNodePoolContext]
  [callee-node : i64]
  [value-node : i64]) : i64
  (if (ctfe-expr-borrowable-place-node-with-pools? (& pools) value-node)
    (ctfe-ast-expr-call-with-provenance
      state
      pools
      callee-node
      (ast.ast-expr-cons value-node (ast.ast-expr-list-new)))
    (let
      [value-name : i64
        (ctfe-materialize-generated-name-id "__tl_shared_call_value")]
      [bindings : ast.AstLetBindingList (ast.ast-let-binding-list-new)]
      [local-node : i64
        (ast.ast-node-pool-context-expr-push pools (ast.AstExpr.Var value-name))]
      [call-node : i64
        (ctfe-ast-expr-call-with-provenance
          state
          pools
          callee-node
          (ast.ast-expr-cons local-node (ast.ast-expr-list-new)))]
      (begin
        (ast.ast-let-binding-list-push
          (&mut bindings)
          (ast.ast-let-binding-id value-name ast.AstMaybeType.No value-node))
        (ast.ast-expr-let-with-pools pools bindings call-node)))))

(define (ctfe-eval-expr-shared-call1-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [callee-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [value-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval callee-arg env fuel)
        [(ResultCtfe.Ok callee-value callee-fuel)
          (let
            [callee-node : i64
              (ctfe-syntax-expr-value-node callee-value (& env))]
            (if (< callee-node 0)
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-shared-call1 callee expects Expr")))
              (match (compiler-ctfe-eval value-arg env callee-fuel)
                [(ResultCtfe.Ok value value-fuel)
                  (let
                    [value-node : i64
                      (ctfe-syntax-expr-value-node value (& env))]
                    (if (< value-node 0)
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-shared-call1 value expects Expr")))
                      (ResultCtfe.Ok
                        (ctfe-syntax-expr-value
                          env
                          (ctfe-expr-shared-call1-node-with-pools
                            (ctfe-env-macro-state env)
                            (ctfe-env-syntax-pool-context env)
                            callee-node
                            value-node)
                          (ctfe-untyped-expr-type))
                        value-fuel)))]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])))]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "expr-shared-call1 expects exactly two args")))))

;; Build a call whose receiver is an explicit inferred-lifetime mutable borrow.
(define (ctfe-expr-mut-call-result
  [callee : i64]
  [place : i64]
  [tail : ast.AstExprList]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (ResultCtfe.Ok
    (CompilerCtfeValue.Expr
      (ctfe-ast-expr-call-with-provenance
        (ctfe-env-macro-state env)
        (ctfe-env-pools env)
        callee
        (ast.ast-expr-cons
          (ast.ast-expr-borrow-with-pools
            (ctfe-env-pools env)
            true
            ast.AstBorrowLifetime.Inferred
            place)
          tail))
      (ctfe-untyped-expr-type))
    fuel))

;; Fixed public arities avoid temporary ExprList values in generated macro
;; bodies while evaluating every captured expression in source order.
(define (ctfe-eval-expr-mut-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [ordinary-count : i64]
  [arity-message : String]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) (+ ordinary-count 2))
    (let
      [callee-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [place-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval callee-arg env fuel)
        [(ResultCtfe.Ok callee-value callee-fuel)
          (match callee-value
            [(CompilerCtfeValue.Expr callee _)
              (match (compiler-ctfe-eval place-arg env callee-fuel)
                [(ResultCtfe.Ok place-value place-fuel)
                  (match place-value
                    [(CompilerCtfeValue.Expr place _)
                      (if (= ordinary-count 0)
                        (ctfe-expr-mut-call-result
                          callee
                          place
                          (ast.ast-expr-list-new)
                          env
                          place-fuel)
                        (match (compiler-ctfe-eval
                          (ctfe-expr-arg args 2 env)
                          env
                          place-fuel)
                          [(ResultCtfe.Ok first-value first-fuel)
                            (match first-value
                              [(CompilerCtfeValue.Expr first _)
                                (if (= ordinary-count 1)
                                  (ctfe-expr-mut-call-result
                                    callee
                                    place
                                    (ast.ast-expr-cons
                                      first
                                      (ast.ast-expr-list-new))
                                    env
                                    first-fuel)
                                  (match (compiler-ctfe-eval
                                    (ctfe-expr-arg args 3 env)
                                    env
                                    first-fuel)
                                    [(ResultCtfe.Ok second-value second-fuel)
                                      (match second-value
                                        [(CompilerCtfeValue.Expr second _)
                                          (ctfe-expr-mut-call-result
                                            callee
                                            place
                                            (ast.ast-expr-cons
                                              first
                                              (ast.ast-expr-cons
                                                second
                                                (ast.ast-expr-list-new)))
                                            env
                                            second-fuel)]
                                        [_
                                          (ResultCtfe.Err
                                            (box
                                              (ctfe-diagnostic-at-expr
                                                expr
                                                "expr-mut-call arguments expect Expr")))])]
                                    [(ResultCtfe.Err diag)
                                      (ResultCtfe.Err diag)]))]
                              [_
                                (ResultCtfe.Err
                                  (box
                                    (ctfe-diagnostic-at-expr
                                      expr
                                      "expr-mut-call arguments expect Expr")))])]
                          [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-mut-call place expects Expr")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-mut-call callee expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err (box (ctfe-diagnostic-at-expr expr arity-message)))))

;; `(expr-type e)`: the reflected type a typechecked Expr carries.
(define (ctfe-expr-type-value
  [pools : ast.AstNodePoolContext]
  [reflections : (& reflections CtfeReflectInfoList)]
  [ty : ast.AstType]) : CtfeBuilt
  (let
    [actual-ty : ast.AstType
      (ctfe-captured-expr-type-inner-with-pools pools ty)]
    (if (ctfe-untyped-expr-type? actual-ty)
      (CtfeBuilt.Err "expr-type requires a typechecked Expr")
      (CtfeBuilt.Ok
        (CompilerCtfeValue.Type
          (ctfe-reflect-resolve-type-with-pools pools reflections actual-ty))))))

(define (ctfe-eval-expr-type-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (let
            [reflections : CtfeReflectInfoList (ctfe-env-reflections env)]
            (match value
              [(CompilerCtfeValue.Expr _ ty)
                (ctfe-built-result
                  (ctfe-expr-type-value (ctfe-env-pools env) reflections ty)
                  expr
                  arg-fuel)]
              [(CompilerCtfeValue.CapturedExpr _ ty pools)
                (ctfe-built-result
                  (ctfe-expr-type-value pools reflections ty)
                  expr
                  arg-fuel)]
              [_
                (ResultCtfe.Err
                  (box (ctfe-diagnostic-at-expr expr "expr-type expects Expr")))]))]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "expr-type expects exactly one arg"))))))

;; Convert one already-resolved reflected type value back into opaque type-
;; literal syntax. The new expression and its type node are allocated together
;; in the active syntax pool. This matters when the reflected value came from a
;; captured ExprList owned by a caller snapshot: its child type IDs still name
;; that snapshot, so the result retains the same explicit captured-syntax
;; provenance instead of copying IDs into an unrelated pool. The AstType itself
;; is preserved verbatim, so nominal identity and lifetime substitutions never
;; pass through display syntax, re-resolution, or type-key text.
(define (ctfe-eval-type-expr-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.Type ty)
              (let
                [pools : ast.AstNodePoolContext
                  (ctfe-env-syntax-pool-context env)]
                (ResultCtfe.Ok
                  (ctfe-syntax-expr-value
                    env
                    (ast.ast-expr-type-literal-with-pools pools ty)
                    (ast.AstType.Expr))
                  arg-fuel))]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    (cdiag.compiler-diagnostic-typecheck-tagged
                      (cdiag.CompilerTypecheckKind.ArityMismatch)
                      "type-expr expects a type argument"))))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "type-expr expects exactly one type argument"))))))

(define (ctfe-eval-expr-clause-list-inspector-call
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.ExprClauseList clauses)
              (ResultCtfe.Ok
                (CompilerCtfeValue.ExprList
                  (ctfe-expr-clause-list->expr-list-in-env env clauses))
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    (str_cat.str-cat name " expects ExprClauseList"))))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (str_cat.str-cat name " expects exactly one arg"))))))

(define (ctfe-eval-expr-binding-clause-list-inspector-call
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.ExprBindingClauseList clauses)
              (ResultCtfe.Ok
                (CompilerCtfeValue.ExprList
                  (ctfe-expr-binding-clause-list->expr-list-in-env env clauses))
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    (str_cat.str-cat name " expects ExprBindingClauseList"))))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (str_cat.str-cat name " expects exactly one arg"))))))

;; Binding-clause inspectors are direct CTFE operations. Reading the value
;; directly preserves the captured initializer node without allocating a
;; temporary expression in the macro definition pool.
(define (ctfe-eval-expr-binding-clause-inspector-call
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.ExprBindingClause clause)
              (cond
                [(string.eq name "expr-binding-clause-name")
                  (ResultCtfe.Ok
                    (ctfe-name-value-for-session
                      (ctfe-env-structural-session env)
                      (ci.intern-syntax-id-value
                        (ctfe-expr-binding-clause-name-id clause)))
                    arg-fuel)]
                [(string.eq name "expr-binding-clause-has-type?")
                  (ResultCtfe.Ok
                    (CompilerCtfeValue.Bool
                      (ctfe-expr-binding-clause-has-type? clause))
                    arg-fuel)]
                [(string.eq name "expr-binding-clause-type")
                  (ResultCtfe.Ok
                    (CompilerCtfeValue.Expr
                      (ctfe-expr-binding-clause-type clause)
                      (ctfe-untyped-expr-type))
                    arg-fuel)]
                [else
                  (begin
                    (ctfe-env-adopt-active-pools! (& env))
                    (let
                      [produced : ast.AstType (clone clause.init-produced)]
                      [pools : ast.AstNodePoolContext (ctfe-env-pools env)]
                      [init-node : i64
                        (ctfe-caller-origin-expr-node-with-pools
                          pools
                          (ctfe-expr-binding-clause-init clause)
                          (clone produced))]
                      [init-ty : ast.AstType
                        (ctfe-caller-origin-expr-type-inner-with-pools
                          pools
                          produced)]
                      (begin
                        (ctfe-env-publish-owning-pools! (& env))
                        (ResultCtfe.Ok
                          (CompilerCtfeValue.Expr init-node init-ty)
                          arg-fuel))))])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    (str_cat.str-cat name " expects ExprBindingClause"))))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (str_cat.str-cat name " expects exactly one arg"))))))

;; `(expr-list-length seq)` and its clause/binding-clause variants return the
;; element count as a comptime i64, exactly matching `seq.len`.
;; Exposed as a direct builtin so macros get O(1) length. The checked-in stdlib
;; body is exercised by the source-parity smoke test.
(define (ctfe-eval-comptime-sequence-length-call
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval arg env fuel)
        [(ResultCtfe.Ok value arg-fuel)
          (match value
            [(CompilerCtfeValue.ExprList nodes)
              (ResultCtfe.Ok
                (CompilerCtfeValue.I64 (ctfe-expr-list-length nodes))
                arg-fuel)]
            [(CompilerCtfeValue.CapturedExprList nodes _)
              (ResultCtfe.Ok
                (CompilerCtfeValue.I64 (ctfe-expr-list-length nodes))
                arg-fuel)]
            [(CompilerCtfeValue.ExprClauseList clauses)
              (ResultCtfe.Ok
                (CompilerCtfeValue.I64 (ctfe-expr-clause-list-length clauses))
                arg-fuel)]
            [(CompilerCtfeValue.CapturedExprClauseList clauses _)
              (ResultCtfe.Ok
                (CompilerCtfeValue.I64 (ctfe-expr-clause-list-length clauses))
                arg-fuel)]
            [(CompilerCtfeValue.ExprBindingClauseList clauses)
              (ResultCtfe.Ok
                (CompilerCtfeValue.I64
                  (ctfe-expr-binding-clause-list-length clauses))
                arg-fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    (str_cat.str-cat name " expects a comptime sequence"))))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (str_cat.str-cat name " expects exactly one arg"))))))

;; `(expr-list-nth seq index)` and its clause/binding-clause variants return the
;; indexed element, exactly matching `(array-ref seq.items index)`.
;; Delegates valid indexes to `ctfe-eval-array-ref-value`, which produces the
;; correct Expr / ExprClause / ExprBindingClause value. Bounds diagnostics are
;; named after the public helper, as in the checked-in stdlib body. Arguments
;; are evaluated sequence-then-index, matching the stdlib body evaluation order.
(define (ctfe-comptime-sequence-length-or-negative
  [value : (& value CompilerCtfeValue)]) : i64
  (match value
    [(CompilerCtfeValue.ExprList items) (ctfe-expr-list-length items)]
    [(CompilerCtfeValue.CapturedExprList items _) (ctfe-expr-list-length items)]
    [(CompilerCtfeValue.ExprClauseList items)
      (ctfe-expr-clause-list-length items)]
    [(CompilerCtfeValue.CapturedExprClauseList items _)
      (ctfe-expr-clause-list-length items)]
    [(CompilerCtfeValue.ExprBindingClauseList items)
      (ctfe-expr-binding-clause-list-length items)]
    [_ -1]))

(define (ctfe-comptime-sequence-index-error
  [name : String]
  [expr : ast.AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        (str_cat.str-cat name " index out of range")))))

(define (ctfe-eval-comptime-sequence-nth-call
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [seq-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [index-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval seq-arg env fuel)
        [(ResultCtfe.Ok seq-value seq-fuel)
          (match (compiler-ctfe-eval index-arg env seq-fuel)
            [(ResultCtfe.Ok index-value index-fuel)
              (match index-value
                [(CompilerCtfeValue.I64 index)
                  (let
                    [length : i64
                      (ctfe-comptime-sequence-length-or-negative seq-value)]
                    (if (or (< index 0) (and (>= length 0) (>= index length)))
                      (ctfe-comptime-sequence-index-error name expr)
                      (ctfe-eval-array-ref-value
                        seq-value
                        index
                        expr
                        env
                        index-fuel)))]
                [_
                  (ResultCtfe.Err
                    (box
                      (ctfe-diagnostic-at-expr
                        expr
                        (str_cat.str-cat name " index must be i64"))))])]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (str_cat.str-cat name " expects a sequence and an index"))))))

;; The comptime Type of a captured type-literal node, seen through the
;; transparent source wrappers.
(define (ctfe-expr-type-literal-value
  [pools : ast.AstNodePoolContext]
  [node : i64]) : CtfeBuilt
  (match (ast.ast-node-pool-context-expr-get pools node)
    [(ast.AstExpr.TypeLiteral ty-id)
      (CtfeBuilt.Ok
        (CompilerCtfeValue.Type
          (ast.ast-node-pool-context-type-get pools ty-id)))]
    [(ast.AstExpr.Spanned inner _) (ctfe-expr-type-literal-value pools inner)]
    [(ast.AstExpr.MacroExpansion inner _ _)
      (ctfe-expr-type-literal-value pools inner)]
    [_ (CtfeBuilt.Err "expr-list-type-nth expects a captured type literal")]))

(define (ctfe-expr-list-type-at
  [pools : ast.AstNodePoolContext]
  [nodes : (& nodes ast.AstExprList)]
  [index : i64]) : CtfeBuilt
  (if (or (< index 0) (>= index (ctfe-expr-list-length nodes)))
    (CtfeBuilt.Err "array-ref index out of range")
    (ctfe-expr-type-literal-value pools (ctfe-expr-list-nth nodes index))))

;; `(expr-list-type-nth items index)`: a captured list's elements live in its
;; caller pools; any other list reads `pools`.
(define (ctfe-expr-list-type-nth
  [items : CompilerCtfeValue]
  [index : i64]
  [pools : ast.AstNodePoolContext]) : CtfeBuilt
  (match items
    [(CompilerCtfeValue.ExprList nodes)
      (ctfe-expr-list-type-at pools nodes index)]
    [(CompilerCtfeValue.CapturedExprList nodes captured)
      (ctfe-expr-list-type-at captured nodes index)]
    [_ (CtfeBuilt.Err "expr-list-type-nth expects an ExprList")]))

(define (ctfe-eval-expr-list-type-nth-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [items-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [index-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval items-arg env fuel)
        [(ResultCtfe.Ok items items-fuel)
          (match (compiler-ctfe-eval index-arg env items-fuel)
            [(ResultCtfe.Ok index-value index-fuel)
              (match index-value
                [(CompilerCtfeValue.I64 index)
                  (ctfe-built-result
                    (ctfe-expr-list-type-nth items index (ctfe-env-pools env))
                    expr
                    index-fuel)]
                [_
                  (ResultCtfe.Err
                    (box
                      (ctfe-diagnostic-at-expr
                        expr
                        "expr-list-type-nth index must be i64")))])]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "expr-list-type-nth expects an ExprList and index")))))

(define (ctfe-expr-if-condition-type-ok?
  [env : (& env CtfeEnv)]
  [ty : ast.AstType]) : bool
  (or
    (ctfe-type-eq-in-env env (clone ty) (ast.AstType.Bool))
    (ctfe-untyped-expr-type? ty)))

(define (ctfe-expr-if-branch-types-compatible?
  [env : (& env CtfeEnv)]
  [then-ty : ast.AstType]
  [else-ty : ast.AstType]) : bool
  (or
    (ctfe-type-eq-in-env env (clone then-ty) (clone else-ty))
    (ctfe-untyped-expr-type? then-ty)
    (ctfe-untyped-expr-type? else-ty)))

(define (ctfe-expr-if-result-type
  [env : (& env CtfeEnv)]
  [then-ty : ast.AstType]
  [else-ty : ast.AstType]) : ast.AstType
  (if (ctfe-type-eq-in-env env (clone then-ty) else-ty)
    then-ty
    (ctfe-untyped-expr-type)))

(define (ctfe-eval-expr-if-call-plain
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 3)
    (let
      [cond-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [then-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      [else-arg : ast.AstExpr (ctfe-expr-arg args 2 env)]
      (match (compiler-ctfe-eval cond-arg env fuel)
        [(ResultCtfe.Ok cond-val cond-fuel)
          (match cond-val
            [(CompilerCtfeValue.Expr cond-node cond-ty)
              (if (ctfe-expr-if-condition-type-ok? env cond-ty)
                (match (compiler-ctfe-eval then-arg env cond-fuel)
                  [(ResultCtfe.Ok then-val then-fuel)
                    (match then-val
                      [(CompilerCtfeValue.Expr then-node then-ty)
                        (match (compiler-ctfe-eval else-arg env then-fuel)
                          [(ResultCtfe.Ok else-val else-fuel)
                            (match else-val
                              [(CompilerCtfeValue.Expr else-node else-ty)
                                (if (ctfe-expr-if-branch-types-compatible?
                                  env
                                  (clone then-ty)
                                  (clone else-ty))
                                  (ResultCtfe.Ok
                                    (CompilerCtfeValue.Expr
                                      (ast.ast-expr-if-with-pools
                                        (ctfe-env-pools env)
                                        cond-node
                                        then-node
                                        else-node)
                                      (ctfe-expr-if-result-type
                                        env
                                        then-ty
                                        else-ty))
                                    else-fuel)
                                  (ResultCtfe.Err
                                    (box
                                      (ctfe-diagnostic-at-expr
                                        expr
                                        "expr-if branch types must match"))))]
                              [_
                                (ResultCtfe.Err
                                  (box
                                    (ctfe-diagnostic-at-expr
                                      expr
                                      "expr-if else branch expects Expr")))])]
                          [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
                      [_
                        (ResultCtfe.Err
                          (box
                            (ctfe-diagnostic-at-expr
                              expr
                              "expr-if then branch expects Expr")))])]
                  [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])
                (ResultCtfe.Err
                  (box
                    (ctfe-diagnostic-at-expr
                      expr
                      "expr-if condition must produce bool"))))]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-if condition expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-if expects exactly three args")))))

;; A captured variadic macro argument retains its caller pool. The iterative
;; core builders construct every participating Expr in that same pool, so an
;; `expr-if` can link the nodes without touching the transformer's older body
;; pool. Ordinary CTFE stays on the established plain implementation above.
(define (ctfe-newest-syntax-pools
  [left : ast.AstNodePoolContext]
  [right : ast.AstNodePoolContext]) : ast.AstNodePoolContext
  (let
    [left-exprs : i64 (ast.ast-node-pool-context-expr-len left)]
    [right-exprs : i64 (ast.ast-node-pool-context-expr-len right)]
    (if (or
      (> right-exprs left-exprs)
      (and
        (= right-exprs left-exprs)
        (>
          (ast.ast-node-pool-context-type-len right)
          (ast.ast-node-pool-context-type-len left))))
      right
      left)))

(define (ctfe-eval-expr-if-call-captured
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 3)
    (let
      [cond-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [then-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      [else-arg : ast.AstExpr (ctfe-expr-arg args 2 env)]
      (match (compiler-ctfe-eval cond-arg env fuel)
        [(ResultCtfe.Ok cond-val cond-fuel)
          (match cond-val
            [(CompilerCtfeValue.CapturedExpr cond-node cond-ty pools)
              (if (ctfe-expr-if-condition-type-ok? env cond-ty)
                (match (compiler-ctfe-eval then-arg env cond-fuel)
                  [(ResultCtfe.Ok then-val then-fuel)
                    (match then-val
                      [(CompilerCtfeValue.CapturedExpr
                          then-node
                          then-ty
                          then-pools)
                        (match (compiler-ctfe-eval else-arg env then-fuel)
                          [(ResultCtfe.Ok else-val else-fuel)
                            (match else-val
                              [(CompilerCtfeValue.CapturedExpr
                                  else-node
                                  else-ty
                                  else-pools)
                                (if (ctfe-expr-if-branch-types-compatible?
                                  env
                                  (clone then-ty)
                                  (clone else-ty))
                                  (let
                                    [build-pools : ast.AstNodePoolContext
                                      (ctfe-newest-syntax-pools
                                        (ctfe-newest-syntax-pools
                                          pools
                                          then-pools)
                                        else-pools)]
                                    (ResultCtfe.Ok
                                      (CompilerCtfeValue.CapturedExpr
                                        (ast.ast-expr-if-with-pools
                                          build-pools
                                          cond-node
                                          then-node
                                          else-node)
                                        (ctfe-expr-if-result-type
                                          env
                                          then-ty
                                          else-ty)
                                        build-pools)
                                      else-fuel))
                                  (ResultCtfe.Err
                                    (box
                                      (ctfe-diagnostic-at-expr
                                        expr
                                        "expr-if branch types must match"))))]
                              [_
                                (ResultCtfe.Err
                                  (box
                                    (ctfe-diagnostic-at-expr
                                      expr
                                      "expr-if else branch expects Expr")))])]
                          [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
                      [_
                        (ResultCtfe.Err
                          (box
                            (ctfe-diagnostic-at-expr
                              expr
                              "expr-if then branch expects Expr")))])]
                  [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])
                (ResultCtfe.Err
                  (box
                    (ctfe-diagnostic-at-expr
                      expr
                      "expr-if condition must produce bool"))))]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-if condition expects Expr")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-if expects exactly three args")))))

(define (ctfe-eval-expr-if-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (ctfe-env-syntax-pools-live env)
    [(CtfeMaybeSyntaxPools.Some _)
      (ctfe-eval-expr-if-call-captured args expr env fuel)]
    [(CtfeMaybeSyntaxPools.None)
      (ctfe-eval-expr-if-call-plain args expr env fuel)]))

;; Fold a captured expression sequence directly into an `if` chain. This is a
;; sequence operation rather than a macro-name hook: any user transformer can
;; choose either branch orientation and arbitrary terminal syntax. Charge one
;; CTFE fuel unit per constructed `if`, matching an explicit iterative builder.
;; An `if` chain folded over a sequence, charging one CTFE fuel unit per
;; constructed `if`; `node` is -1 when the fuel ran out first.
(defstruct CtfeFold
  (node i64)
  (fuel i64))

(define (ctfe-fold-result
  [fold : CtfeFold]
  [expr : ast.AstExpr]
  [value : CompilerCtfeValue]) : ResultCtfe
  (if (< fold.node 0)
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "compile-time evaluation limit exceeded")))
    (ResultCtfe.Ok value fold.fuel)))

;; `(expr-list-fold-if items when-true when-false continue-on-true?)` folds right
;; to left: each item becomes the condition of an `if` whose continuing branch
;; is the chain built so far.
(define (ctfe-expr-list-fold-if-node
  [pools : ast.AstNodePoolContext]
  [items : (& items ast.AstExprList)]
  [when-true-node : i64]
  [when-false-node : i64]
  [continue-on-true : bool]
  [fuel : i64]) : CtfeFold
  (let
    [index : i64 (- (ctfe-expr-list-length items) 1)]
    [out-node : i64
      (if continue-on-true
        when-true-node
        when-false-node)]
    [remaining-fuel : i64 fuel]
    (begin
      (while (and (>= index 0) (> remaining-fuel 0))
        (begin
          (set!
            out-node
            (ast.ast-expr-if-with-pools
              pools
              (ctfe-expr-list-nth items index)
              (if continue-on-true
                out-node
                when-true-node)
              (if continue-on-true
                when-false-node
                out-node)))
          (set! index (- index 1))
          (set! remaining-fuel (- remaining-fuel 1))))
      (CtfeFold
        (if (>= index 0)
          -1
          out-node)
        remaining-fuel))))

(define (ctfe-expr-list-fold-if-terminal-type-error [expr : ast.AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        "expr-list-fold-if terminal branch types must match"))))

(define (ctfe-eval-expr-list-fold-if-values
  [items-value : CompilerCtfeValue]
  [when-true-value : CompilerCtfeValue]
  [when-false-value : CompilerCtfeValue]
  [continue-on-true : bool]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match items-value
    [(CompilerCtfeValue.ExprList items)
      (match when-true-value
        [(CompilerCtfeValue.Expr when-true-node when-true-ty)
          (match when-false-value
            [(CompilerCtfeValue.Expr when-false-node when-false-ty)
              (if (ctfe-expr-if-branch-types-compatible?
                env
                (clone when-true-ty)
                (clone when-false-ty))
                (let
                  [fold : CtfeFold
                    (ctfe-expr-list-fold-if-node
                      (ctfe-env-pools env)
                      (& items)
                      when-true-node
                      when-false-node
                      continue-on-true
                      fuel)]
                  (ctfe-fold-result
                    fold
                    expr
                    (CompilerCtfeValue.Expr
                      fold.node
                      (ctfe-expr-if-result-type env when-true-ty when-false-ty))))
                (ctfe-expr-list-fold-if-terminal-type-error expr))]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-list-fold-if terminal branches must be Expr")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "expr-list-fold-if terminal branches must be Expr")))])]
    [(CompilerCtfeValue.CapturedExprList items pools)
      (match when-true-value
        [(CompilerCtfeValue.CapturedExpr
            when-true-node
            when-true-ty
            when-true-pools)
          (match when-false-value
            [(CompilerCtfeValue.CapturedExpr
                when-false-node
                when-false-ty
                when-false-pools)
              (if (ctfe-expr-if-branch-types-compatible?
                env
                (clone when-true-ty)
                (clone when-false-ty))
                (let
                  [build-pools : ast.AstNodePoolContext
                    (ctfe-newest-syntax-pools
                      (ctfe-newest-syntax-pools pools when-true-pools)
                      when-false-pools)]
                  [fold : CtfeFold
                    (ctfe-expr-list-fold-if-node
                      build-pools
                      items
                      when-true-node
                      when-false-node
                      continue-on-true
                      fuel)]
                  (begin
                    (if (and
                      (>= fold.node 0)
                      (ctfe-hygiene-inert-literal-node?
                        build-pools
                        when-true-node)
                      (ctfe-hygiene-inert-literal-node?
                        build-pools
                        when-false-node))
                      (ctfe-result-hygiene-free-note-for-state!
                        (ctfe-env-macro-state env)
                        fold.node)
                      unit)
                    (ctfe-fold-result
                      fold
                      expr
                      (CompilerCtfeValue.CapturedExpr
                        fold.node
                        (ctfe-expr-if-result-type
                          env
                          when-true-ty
                          when-false-ty)
                        build-pools))))
                (ctfe-expr-list-fold-if-terminal-type-error expr))]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-list-fold-if terminal branches must be Expr")))])]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "expr-list-fold-if terminal branches must be Expr")))])]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr expr "expr-list-fold-if expects an ExprList")))]))

(define (ctfe-eval-expr-list-fold-if-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 4)
    (let
      [items-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [when-true-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      [when-false-arg : ast.AstExpr (ctfe-expr-arg args 2 env)]
      [continue-arg : ast.AstExpr (ctfe-expr-arg args 3 env)]
      (match (compiler-ctfe-eval items-arg env fuel)
        [(ResultCtfe.Ok items-value items-fuel)
          (match (compiler-ctfe-eval when-true-arg env items-fuel)
            [(ResultCtfe.Ok when-true-value when-true-fuel)
              (match (compiler-ctfe-eval when-false-arg env when-true-fuel)
                [(ResultCtfe.Ok when-false-value when-false-fuel)
                  (match (compiler-ctfe-eval continue-arg env when-false-fuel)
                    [(ResultCtfe.Ok continue-value continue-fuel)
                      (match continue-value
                        [(CompilerCtfeValue.Bool continue-on-true)
                          (ctfe-eval-expr-list-fold-if-values
                            items-value
                            when-true-value
                            when-false-value
                            continue-on-true
                            expr
                            env
                            continue-fuel)]
                        [_
                          (ResultCtfe.Err
                            (box
                              (ctfe-diagnostic-at-expr
                                expr
                                "expr-list-fold-if continuation must be bool")))])]
                    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-list-fold-if expects four args")))))

(define (ctfe-expr-else-with-pools?
  [pools : (& pools ast.AstNodePoolContext)]
  [node : i64]) : bool
  (match (ast.ast-expr-unspan-with-pools
    pools
    (ast.ast-node-pool-context-expr-get pools node))
    [(ast.AstExpr.Var name) (= name cbi.compiler-builtin-id-fix-else)]
    [_ false]))

;; `(expr-clause-list-fold-if clauses missing else-not-final)`: the final clause
;; seeds the chain (its result when it is an `else` clause, `missing`
;; otherwise), then right to left each clause wraps an `if`, and a non-final
;; `else` collapses to `else-not-final`.
(define (ctfe-expr-clause-list-fold-if-node
  [pools : ast.AstNodePoolContext]
  [items : (& items ast.AstExprClauseList)]
  [missing-node : i64]
  [else-not-final-node : i64]
  [fuel : i64]) : CtfeFold
  (let
    [final-index : i64 (- (ctfe-expr-clause-list-length items) 1)]
    [index : i64 final-index]
    [out-node : i64 missing-node]
    [remaining-fuel : i64 fuel]
    (begin
      (while (and (>= index 0) (> remaining-fuel 0))
        (let
          [clause : ast.AstExprClause (ctfe-expr-clause-list-nth items index)]
          [test-node : i64 (ctfe-expr-clause-first clause)]
          [else? : bool (ctfe-expr-else-with-pools? (& pools) test-node)]
          (begin
            (set!
              out-node
              (cond
                [(= index final-index)
                  (if else?
                    (ctfe-expr-clause-second clause)
                    out-node)]
                [else? else-not-final-node]
                [else
                  (ast.ast-expr-if-with-pools
                    pools
                    test-node
                    (ctfe-expr-clause-second clause)
                    out-node)]))
            (set! index (- index 1))
            (set! remaining-fuel (- remaining-fuel 1)))))
      (CtfeFold
        (if (>= index 0)
          -1
          out-node)
        remaining-fuel))))

(define (ctfe-expr-clause-list-fold-if-terminal-error [expr : ast.AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        "expr-clause-list-fold-if terminal values must be Expr"))))

(define (ctfe-eval-expr-clause-list-fold-if-values
  [items-value : CompilerCtfeValue]
  [missing-value : CompilerCtfeValue]
  [else-not-final-value : CompilerCtfeValue]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match items-value
    [(CompilerCtfeValue.ExprClauseList items)
      (match missing-value
        [(CompilerCtfeValue.Expr missing-node missing-ty)
          (match else-not-final-value
            [(CompilerCtfeValue.Expr else-not-final-node _)
              (if (= (ctfe-expr-clause-list-length items) 0)
                (ResultCtfe.Ok
                  (CompilerCtfeValue.Expr missing-node missing-ty)
                  fuel)
                (let
                  [fold : CtfeFold
                    (ctfe-expr-clause-list-fold-if-node
                      (ctfe-env-pools env)
                      items
                      missing-node
                      else-not-final-node
                      fuel)]
                  (ctfe-fold-result
                    fold
                    expr
                    (CompilerCtfeValue.Expr fold.node (ctfe-untyped-expr-type)))))]
            [_ (ctfe-expr-clause-list-fold-if-terminal-error expr)])]
        [_ (ctfe-expr-clause-list-fold-if-terminal-error expr)])]
    [(CompilerCtfeValue.CapturedExprClauseList items pools)
      (match missing-value
        [(CompilerCtfeValue.CapturedExpr missing-node missing-ty _)
          (match else-not-final-value
            [(CompilerCtfeValue.CapturedExpr else-not-final-node _ _)
              (if (= (ctfe-expr-clause-list-length items) 0)
                (ResultCtfe.Ok
                  (CompilerCtfeValue.CapturedExpr missing-node missing-ty pools)
                  fuel)
                (let
                  [fold : CtfeFold
                    (ctfe-expr-clause-list-fold-if-node
                      pools
                      items
                      missing-node
                      else-not-final-node
                      fuel)]
                  (begin
                    (if (and
                      (>= fold.node 0)
                      (ctfe-hygiene-inert-literal-node? pools missing-node)
                      (ctfe-hygiene-inert-literal-node?
                        pools
                        else-not-final-node))
                      (ctfe-result-hygiene-free-note-for-state!
                        (ctfe-env-macro-state env)
                        fold.node)
                      unit)
                    (ctfe-fold-result
                      fold
                      expr
                      (CompilerCtfeValue.CapturedExpr
                        fold.node
                        (ctfe-untyped-expr-type)
                        pools)))))]
            [_ (ctfe-expr-clause-list-fold-if-terminal-error expr)])]
        [_ (ctfe-expr-clause-list-fold-if-terminal-error expr)])]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "expr-clause-list-fold-if expects an ExprClauseList")))]))

(define (ctfe-eval-expr-clause-list-fold-if-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 3)
    (let
      [items-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [missing-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      [else-not-final-arg : ast.AstExpr (ctfe-expr-arg args 2 env)]
      (match (compiler-ctfe-eval items-arg env fuel)
        [(ResultCtfe.Ok items-value items-fuel)
          (match (compiler-ctfe-eval missing-arg env items-fuel)
            [(ResultCtfe.Ok missing-value missing-fuel)
              (match (compiler-ctfe-eval else-not-final-arg env missing-fuel)
                [(ResultCtfe.Ok else-not-final-value else-not-final-fuel)
                  (ctfe-eval-expr-clause-list-fold-if-values
                    items-value
                    missing-value
                    else-not-final-value
                    expr
                    env
                    else-not-final-fuel)]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "expr-clause-list-fold-if expects three args")))))

(define (ctfe-eval-pattern-wildcard-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 0)
    (ResultCtfe.Ok (CompilerCtfeValue.Pattern ast.AstPattern.Wildcard) fuel)
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "pattern-wildcard expects exactly zero args")))))

(define (ctfe-eval-pattern-binding-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [name-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-syntax-name-arg
        name-arg
        expr
        env
        fuel
        "pattern-binding")
        [(ResultCtfeNameArg.Ok name-id next-fuel)
          (ResultCtfe.Ok
            (CompilerCtfeValue.Pattern (ctfe-pat-binding-id name-id))
            next-fuel)]
        [(ResultCtfeNameArg.Err d) (ResultCtfe.Err d)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "pattern-binding expects exactly one arg"))))))

(define (ctfe-pattern-binding-type-value
  [value : CompilerCtfeValue]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (match value
    [(CompilerCtfeValue.Type ty) (ResultCtfeQuoteType.Ok ty fuel)]
    [(CompilerCtfeValue.Expr node _)
      (ctfe-expr-to-type (ctfe-ast-get env node) expr env fuel)]
    [(CompilerCtfeValue.CapturedExpr node _ pools)
      (ctfe-expr-to-type
        (ast.ast-node-pool-context-expr-get pools node)
        expr
        (ctfe-env-rebase-pools env pools)
        fuel)]
    [_
      (ResultCtfeQuoteType.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "pattern-binding-typed type expects captured type syntax")))]))

(define (ctfe-eval-pattern-binding-typed-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [name-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [type-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-syntax-name-arg
        name-arg
        expr
        env
        fuel
        "pattern-binding-typed")
        [(ResultCtfeNameArg.Ok name-id name-fuel)
          (match (compiler-ctfe-eval type-arg env name-fuel)
            [(ResultCtfe.Ok type-value type-fuel)
              (match (ctfe-pattern-binding-type-value
                type-value
                expr
                env
                type-fuel)
                [(ResultCtfeQuoteType.Ok ty next-fuel)
                  (ResultCtfe.Ok
                    (CompilerCtfeValue.Pattern
                      (ast.AstPattern.Var name-id (ast.AstMaybeType.Some ty)))
                    next-fuel)]
                [(ResultCtfeQuoteType.Err diag) (ResultCtfe.Err diag)])]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfeNameArg.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "pattern-binding-typed expects exactly two args")))))

;; A computed variant pattern resolves its String or Name spelling the way a
;; variant reference in source does.
(define (ctfe-pattern-variant
  [source-names : ci.InternSourceNameSessionHandle]
  [name : String]
  [name-id : i64]
  [payloads : ast.AstPatternList]) : ast.AstPattern
  (ctfe-pat-variant-id
    (ctfe-string-syntax-name-id source-names name name-id)
    payloads))

(define (ctfe-eval-pattern-variant-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [name-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [payloads-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg name-arg expr env fuel "pattern-variant")
        [(ResultCtfeStringArg.Ok name name-id name-fuel)
          (match (compiler-ctfe-eval payloads-arg env name-fuel)
            [(ResultCtfe.Ok payloads-val payloads-fuel)
              (match payloads-val
                [(CompilerCtfeValue.PatternList payloads)
                  (ResultCtfe.Ok
                    (CompilerCtfeValue.Pattern
                      (ctfe-pattern-variant
                        (ctfe-env-source-names env)
                        name
                        name-id
                        payloads))
                    payloads-fuel)]
                [_
                  (ResultCtfe.Err
                    (box
                      (ctfe-diagnostic-at-expr
                        expr
                        "pattern-variant expects PatternList payloads")))])]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfeStringArg.Err d) (ResultCtfe.Err d)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "pattern-variant expects exactly two args")))))

(define (ctfe-eval-pattern-list-empty-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 0)
    (ResultCtfe.Ok
      (CompilerCtfeValue.PatternList (ast.ast-pattern-list-new))
      fuel)
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "pattern-list-empty expects exactly zero args")))))

(define (ctfe-eval-pattern-list-cons-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [head-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [rest-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval head-arg env fuel)
        [(ResultCtfe.Ok head-val head-fuel)
          (match head-val
            [(CompilerCtfeValue.Pattern head-pattern)
              (match (compiler-ctfe-eval rest-arg env head-fuel)
                [(ResultCtfe.Ok rest-val rest-fuel)
                  (match rest-val
                    [(CompilerCtfeValue.PatternList rest-patterns)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.PatternList
                          (ast.ast-pattern-cons head-pattern rest-patterns))
                        rest-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "pattern-list-cons tail expects PatternList")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "pattern-list-cons head expects Pattern")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "pattern-list-cons expects exactly two args")))))

(define (ctfe-pattern-list-bindings-build
  [env : CtfeEnv]
  [prefix : String]
  [count : i64]) : ast.AstPatternList
  (let
    [patterns : ast.AstPatternList (ast.ast-pattern-list-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (ast.ast-pattern-list-push
            (&mut patterns)
            (let
              [name : String
                (str_cat.str-cat
                  (string.copy prefix)
                  (string.int->string index))]
              [name-id : i64
                (ctfe-materialize-generated-name-id (string.copy name))]
              (ctfe-pat-binding-id
                (ctfe-string-syntax-name-id
                  (ctfe-env-source-names env)
                  name
                  name-id))))
          (set! index (+ index 1))))
      patterns)))

(define (ctfe-eval-pattern-list-bindings-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [prefix-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [count-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-string-arg
        prefix-arg
        expr
        env
        fuel
        "pattern-list-bindings")
        [(ResultCtfeStringArg.Ok prefix _ prefix-fuel)
          (match (ctfe-eval-i64-arg
            count-arg
            expr
            env
            prefix-fuel
            "pattern-list-bindings")
            [(result_ctfe_i64_arg.Ok count-value)
              (let
                [count : i64 count-value.value]
                [count-fuel : i64 count-value.fuel]
                (cond
                  [(< count 0)
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "pattern-list-bindings count must be non-negative")))]
                  [(> count count-fuel)
                    (ResultCtfe.Err
                      (box
                        (ctfe-diagnostic-at-expr
                          expr
                          "compile-time evaluation limit exceeded")))]
                  [else
                    (ResultCtfe.Ok
                      (CompilerCtfeValue.PatternList
                        (ctfe-pattern-list-bindings-build env prefix count))
                      (- count-fuel count))]))]
            [(result_ctfe_i64_arg.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfeStringArg.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "pattern-list-bindings expects exactly two args")))))

(define (ctfe-eval-match-arm-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [pattern-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [body-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval pattern-arg env fuel)
        [(ResultCtfe.Ok pattern-val pattern-fuel)
          (match pattern-val
            [(CompilerCtfeValue.Pattern pattern)
              (match (compiler-ctfe-eval body-arg env pattern-fuel)
                [(ResultCtfe.Ok body-val body-fuel)
                  (let
                    [body-node : i64
                      (ctfe-syntax-expr-value-node body-val (& env))]
                    (if (>= body-node 0)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.MatchArm
                          (ast.ast-match-arm pattern body-node))
                        body-fuel)
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "match-arm body expects Expr")))))]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "match-arm pattern expects Pattern")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "match-arm expects exactly two args")))))

(define (ctfe-eval-match-arm-list-empty-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 0)
    (ResultCtfe.Ok
      (CompilerCtfeValue.MatchArmList (ast.ast-match-arm-list-new))
      fuel)
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "match-arm-list-empty expects exactly zero args")))))

(define (ctfe-eval-match-arm-list-cons-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [head-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [rest-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval head-arg env fuel)
        [(ResultCtfe.Ok head-val head-fuel)
          (match head-val
            [(CompilerCtfeValue.MatchArm head-arm)
              (match (compiler-ctfe-eval rest-arg env head-fuel)
                [(ResultCtfe.Ok rest-val rest-fuel)
                  (match rest-val
                    [(CompilerCtfeValue.MatchArmList rest-arms)
                      (ResultCtfe.Ok
                        (CompilerCtfeValue.MatchArmList
                          (ast.ast-match-arm-cons head-arm rest-arms))
                        rest-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "match-arm-list-cons tail expects MatchArmList")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "match-arm-list-cons head expects MatchArm")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "match-arm-list-cons expects exactly two args")))))

(define (ctfe-eval-expr-match-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [scrutinee-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [arms-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval scrutinee-arg env fuel)
        [(ResultCtfe.Ok scrutinee-val scrutinee-fuel)
          (let
            [scrutinee-node : i64
              (ctfe-syntax-expr-value-node scrutinee-val (& env))]
            (if (>= scrutinee-node 0)
              (match (compiler-ctfe-eval arms-arg env scrutinee-fuel)
                [(ResultCtfe.Ok arms-val arms-fuel)
                  (match arms-val
                    [(CompilerCtfeValue.MatchArmList arms)
                      (ResultCtfe.Ok
                        (ctfe-syntax-expr-value
                          env
                          (ast.ast-expr-match-with-pools
                            (ctfe-env-syntax-pool-context-live env)
                            scrutinee-node
                            arms)
                          (ctfe-untyped-expr-type))
                        arms-fuel)]
                    [_
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-match arms expects MatchArmList")))])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-match scrutinee expects Expr")))))]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-match expects exactly two args")))))

(define (ctfe-syntax-expr-value-node
  [value : CompilerCtfeValue]
  [env : (& env CtfeEnv)]) : i64
  (match value
    [(CompilerCtfeValue.Expr node _)
      (begin
        ;; Plain evaluator expressions can be appended through the active
        ;; parser/transform context while the macro's owning and captured
        ;; syntax snapshots lag behind it. Pull that cursor into the owner,
        ;; then publish it before a syntax builder appends a parent node.
        (ctfe-env-adopt-active-pools! env)
        (ctfe-env-publish-owning-pools! env)
        node)]
    [(CompilerCtfeValue.CapturedExpr node _ pools)
      (begin
        (ctfe-env-adopt-captured-pools! env pools)
        node)]
    [_ -1]))

;; The single-binding scopes built by `for`: `(expr-resource-scope name init
;; cleanup body move-aware?)`, `(expr-let-scope name init body)` and
;; `(expr-shared-let-scope name init body)`.
(define (ctfe-with-resource-expr
  [name-id : i64]
  [init-node : i64]
  [cleanup-node : i64]
  [body-node : i64]
  [move-aware? : bool]) : ast.AstExpr
  (let
    [bindings : ast.AstResourceBindingList (ast.ast-resource-binding-list-new)]
    [body : ast.AstExprList (ast.ast-expr-list-with-capacity 1)]
    (begin
      (ast.ast-resource-binding-list-push
        (&mut bindings)
        (ast.AstResourceBinding.Binding
          name-id
          init-node
          cleanup-node
          move-aware?))
      (ast.ast-expr-list-push (&mut body) body-node)
      (ast.AstExpr.WithResource
        (box (ast.AstWithResource.WithResource bindings body))))))

(define (ctfe-expr-let-scope-node
  [pools : ast.AstNodePoolContext]
  [name-id : i64]
  [init-node : i64]
  [body-node : i64]) : i64
  (let
    [bindings : ast.AstLetBindingList (ast.ast-let-binding-list-new)]
    (begin
      (ast.ast-let-binding-list-push
        (&mut bindings)
        (ast.ast-let-binding-id name-id ast.AstMaybeType.No init-node))
      (ast.ast-expr-let-with-pools pools bindings body-node))))

;; A reusable shared-reference binding that does not move a caller-owned
;; place: an rvalue first gets a hidden lexical owner, mirroring
;; `expr-shared-call1` while allowing multiple uses in `body`.
(define (ctfe-expr-shared-let-scope-node
  [pools : ast.AstNodePoolContext]
  [name-id : i64]
  [init-node : i64]
  [body-node : i64]) : i64
  (let
    [direct? : bool
      (ctfe-expr-borrowable-place-node-with-pools? (& pools) init-node)]
    [owner-name : i64
      (ctfe-materialize-generated-name-id "__tl_shared_scope_value")]
    [owner-node : i64
      (ast.ast-node-pool-context-expr-push pools (ast.AstExpr.Var owner-name))]
    [borrow-node : i64
      (ast.ast-expr-borrow-with-pools
        pools
        false
        ast.AstBorrowLifetime.Inferred
        (if direct?
          init-node
          owner-node))]
    [borrow-body : i64
      (ctfe-expr-let-scope-node pools name-id borrow-node body-node)]
    (if direct?
      borrow-body
      (ctfe-expr-let-scope-node pools owner-name init-node borrow-body))))

(define (ctfe-eval-expr-resource-scope-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 5)
    (let
      [name-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [init-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      [cleanup-arg : ast.AstExpr (ctfe-expr-arg args 2 env)]
      [body-arg : ast.AstExpr (ctfe-expr-arg args 3 env)]
      [move-aware-arg : ast.AstExpr (ctfe-expr-arg args 4 env)]
      (match (ctfe-eval-syntax-name-arg
        name-arg
        expr
        env
        fuel
        "expr-resource-scope")
        [(ResultCtfeNameArg.Ok name-id name-fuel)
          (match (compiler-ctfe-eval init-arg env name-fuel)
            [(ResultCtfe.Ok init-value init-fuel)
              (match (compiler-ctfe-eval cleanup-arg env init-fuel)
                [(ResultCtfe.Ok cleanup-value cleanup-fuel)
                  (match (compiler-ctfe-eval body-arg env cleanup-fuel)
                    [(ResultCtfe.Ok body-value body-fuel)
                      (match (compiler-ctfe-eval move-aware-arg env body-fuel)
                        [(ResultCtfe.Ok move-aware-value next-fuel)
                          (match move-aware-value
                            [(CompilerCtfeValue.Bool move-aware?)
                              (let
                                [init-node : i64
                                  (ctfe-syntax-expr-value-node
                                    init-value
                                    (& env))]
                                [cleanup-node : i64
                                  (ctfe-syntax-expr-value-node
                                    cleanup-value
                                    (& env))]
                                [body-node : i64
                                  (ctfe-syntax-expr-value-node
                                    body-value
                                    (& env))]
                                (if (or
                                  (< init-node 0)
                                  (< cleanup-node 0)
                                  (< body-node 0))
                                  (ResultCtfe.Err
                                    (box
                                      (ctfe-diagnostic-at-expr
                                        expr
                                        (cdiag.compiler-diagnostic-typecheck-tagged
                                          (cdiag.CompilerTypecheckKind.TypeMismatch)
                                          "expr-resource-scope init, cleanup, and body expect Expr"))))
                                  (ResultCtfe.Ok
                                    (ctfe-syntax-expr-value
                                      env
                                      (ctfe-syntax-ast-push
                                        env
                                        (ctfe-with-resource-expr
                                          name-id
                                          init-node
                                          cleanup-node
                                          body-node
                                          move-aware?))
                                      (ctfe-untyped-expr-type))
                                    next-fuel)))]
                            [_
                              (ResultCtfe.Err
                                (box
                                  (ctfe-diagnostic-at-expr
                                    expr
                                    "expr-resource-scope move-aware expects bool")))])]
                        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
                    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfeNameArg.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "expr-resource-scope expects exactly five args")))))

(define (ctfe-eval-syntax-expr-args
  [args : ast.AstExprList]
  [index : i64]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [builder-name : String]) : ResultCtfeQuoteExprList
  (if (>= index (ctfe-expr-arg-count args))
    (ResultCtfeQuoteExprList.Ok (ast.ast-expr-list-new) fuel)
    (match (compiler-ctfe-eval (ctfe-expr-arg args index env) env fuel)
      [(ResultCtfe.Ok value value-fuel)
        (let
          [node : i64 (ctfe-syntax-expr-value-node value (& env))]
          (if (< node 0)
            (ResultCtfeQuoteExprList.Err
              (box
                (ctfe-diagnostic-at-expr
                  expr
                  (str_cat.str-cat builder-name " expects Expr arguments"))))
            (match (ctfe-eval-syntax-expr-args
              args
              (+ index 1)
              expr
              env
              value-fuel
              builder-name)
              [(ResultCtfeQuoteExprList.Ok rest next-fuel)
                (ResultCtfeQuoteExprList.Ok
                  (ast.ast-expr-cons node rest)
                  next-fuel)]
              [(ResultCtfeQuoteExprList.Err diag)
                (ResultCtfeQuoteExprList.Err diag)])))]
      [(ResultCtfe.Err diag) (ResultCtfeQuoteExprList.Err diag)])))

;; The `for` loop-protocol nodes: mode 0 is expr-for-owned-state over four Expr
;; nodes, mode 1 expr-for-owned-step over five, and mode 2
;; expr-for-owned-step-typed over six.
(define (ctfe-expr-for-owned-arity [mode : i64]) : i64
  (match mode
    [0 4]
    [1 5]
    [2 6]
    [_ -1]))

(define (ctfe-expr-for-owned-node
  [pools : ast.AstNodePoolContext]
  [mode : i64]
  [nodes : (& nodes ast.AstExprList)]) : i64
  (if (= mode 0)
    (ast.ast-expr-for-owned-state-with-pools
      pools
      (ast.ast-expr-list-get nodes 0 0)
      (ast.ast-expr-list-get nodes 1 0)
      (ast.ast-expr-list-get nodes 2 0)
      (ast.ast-expr-list-get nodes 3 0))
    (ast.ast-expr-for-owned-step-with-pools
      pools
      (ast.ast-expr-list-get nodes 0 0)
      (ast.ast-expr-list-get nodes 1 0)
      (ast.ast-expr-list-get nodes 2 0)
      (if (= mode 2)
        (ast.ast-expr-list-get nodes 3 0)
        -1)
      (ast.ast-expr-list-get
        nodes
        (if (= mode 2)
          4
          3)
        0)
      (ast.ast-expr-list-get
        nodes
        (if (= mode 2)
          5
          4)
        0))))

(define (ctfe-eval-expr-for-owned-call
  [mode : i64]
  [builder-name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (let
    [expected-count : i64 (ctfe-expr-for-owned-arity mode)]
    (if (= (ctfe-expr-arg-count args) expected-count)
      (match (ctfe-eval-syntax-expr-args args 0 expr env fuel builder-name)
        [(ResultCtfeQuoteExprList.Ok nodes next-fuel)
          (ResultCtfe.Ok
            (ctfe-syntax-expr-value
              env
              (ctfe-expr-for-owned-node
                (ctfe-env-syntax-pool-context-live env)
                mode
                (& nodes))
              (ctfe-untyped-expr-type))
            next-fuel)]
        [(ResultCtfeQuoteExprList.Err diag) (ResultCtfe.Err diag)])
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            (str_cat.str-cat
              builder-name
              " expects exactly "
              (string.int->string expected-count)
              " args")))))))

(define (ctfe-eval-expr-let-scope-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 3)
    (let
      [name-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [init-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      [body-arg : ast.AstExpr (ctfe-expr-arg args 2 env)]
      (match (ctfe-eval-syntax-name-arg name-arg expr env fuel "expr-let-scope")
        [(ResultCtfeNameArg.Ok name-id name-fuel)
          (match (compiler-ctfe-eval init-arg env name-fuel)
            [(ResultCtfe.Ok init-value init-fuel)
              (match (compiler-ctfe-eval body-arg env init-fuel)
                [(ResultCtfe.Ok body-value next-fuel)
                  (let
                    [init-node : i64
                      (ctfe-syntax-expr-value-node init-value (& env))]
                    [body-node : i64
                      (ctfe-syntax-expr-value-node body-value (& env))]
                    (if (or (< init-node 0) (< body-node 0))
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-let-scope init and body expect Expr")))
                      (ResultCtfe.Ok
                        (ctfe-syntax-expr-value
                          env
                          (ctfe-expr-let-scope-node
                            (ctfe-env-syntax-pool-context-live env)
                            name-id
                            init-node
                            body-node)
                          (ctfe-untyped-expr-type))
                        next-fuel)))]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfeNameArg.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "expr-let-scope expects exactly three args")))))

(define (ctfe-eval-expr-shared-let-scope-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 3)
    (let
      [name-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [init-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      [body-arg : ast.AstExpr (ctfe-expr-arg args 2 env)]
      (match (ctfe-eval-syntax-name-arg
        name-arg
        expr
        env
        fuel
        "expr-shared-let-scope")
        [(ResultCtfeNameArg.Ok name-id name-fuel)
          (match (compiler-ctfe-eval init-arg env name-fuel)
            [(ResultCtfe.Ok init-value init-fuel)
              (match (compiler-ctfe-eval body-arg env init-fuel)
                [(ResultCtfe.Ok body-value next-fuel)
                  (let
                    [init-node : i64
                      (ctfe-syntax-expr-value-node init-value (& env))]
                    [body-node : i64
                      (ctfe-syntax-expr-value-node body-value (& env))]
                    (if (or (< init-node 0) (< body-node 0))
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-shared-let-scope init and body expect Expr")))
                      (ResultCtfe.Ok
                        (ctfe-syntax-expr-value
                          env
                          (ctfe-expr-shared-let-scope-node
                            (ctfe-env-syntax-pool-context env)
                            name-id
                            init-node
                            body-node)
                          (ctfe-untyped-expr-type))
                        next-fuel)))]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfeNameArg.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          "expr-shared-let-scope expects exactly three args")))))

(define (ctfe-eval-expr-set-var-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [name-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [value-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (ctfe-eval-syntax-name-arg name-arg expr env fuel "expr-set-var")
        [(ResultCtfeNameArg.Ok name-id name-fuel)
          (match (compiler-ctfe-eval value-arg env name-fuel)
            [(ResultCtfe.Ok value next-fuel)
              (let
                [value-node : i64 (ctfe-syntax-expr-value-node value (& env))]
                (if (>= value-node 0)
                  (ResultCtfe.Ok
                    (ctfe-syntax-expr-value
                      env
                      (ast.ast-expr-set-id-with-pools
                        (ctfe-env-syntax-pool-context-live env)
                        name-id
                        value-node)
                      (ast.AstType.Unit))
                    next-fuel)
                  (ResultCtfe.Err
                    (box
                      (ctfe-diagnostic-at-expr
                        expr
                        "expr-set-var value expects Expr")))))]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
        [(ResultCtfeNameArg.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr expr "expr-set-var expects exactly two args")))))

(define (ctfe-expr-begin-unit-node
  [items : ast.AstExprList]
  [pools : ast.AstNodePoolContext]) : i64
  (let
    [out : ast.AstExprList (ast.ast-expr-list-with-capacity (+ items.len 1))]
    (begin
      (ast.ast-expr-list-append-from (&mut out) (& items) 0)
      (ast.ast-expr-list-push
        (&mut out)
        (ast.ast-node-pool-context-expr-push
          pools
          (ast.AstExpr.Literal (ast.AstLiteral.Unit))))
      (ast.ast-node-pool-context-expr-push pools (ast.AstExpr.Begin out)))))

(define (ctfe-eval-expr-begin-unit-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [items-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval items-arg env fuel)
        [(ResultCtfe.Ok items-value next-fuel)
          (match items-value
            [(CompilerCtfeValue.CapturedExprList items pools)
              (ResultCtfe.Ok
                (CompilerCtfeValue.CapturedExpr
                  (ctfe-expr-begin-unit-node items pools)
                  ;; Preserve the captured pool owner in the returned value.
                  (ast.AstType.Unit)
                  pools)
                next-fuel)]
            [(CompilerCtfeValue.ExprList items)
              (let
                [pools : ast.AstNodePoolContext
                  (ctfe-env-syntax-pool-context-live env)]
                (ResultCtfe.Ok
                  (CompilerCtfeValue.CapturedExpr
                    (ctfe-expr-begin-unit-node items pools)
                    (ast.AstType.Unit)
                    pools)
                  next-fuel))]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-begin-unit expects ExprList")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "expr-begin-unit expects exactly one arg"))))))

(define (ctfe-eval-expr-not-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [value-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (compiler-ctfe-eval value-arg env fuel)
        [(ResultCtfe.Ok value next-fuel)
          (let
            [value-node : i64 (ctfe-syntax-expr-value-node value (& env))]
            (if (>= value-node 0)
              (ResultCtfe.Ok
                (ctfe-syntax-expr-value
                  env
                  (ast.ast-expr-unary-with-pools
                    (ctfe-env-syntax-pool-context-live env)
                    (ast.AstUnOp.Not)
                    value-node)
                  (ast.AstType.Bool))
                next-fuel)
              (ResultCtfe.Err
                (box (ctfe-diagnostic-at-expr expr "expr-not expects Expr")))))]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "expr-not expects exactly one arg"))))))

(define (ctfe-eval-expr-while-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 2)
    (let
      [condition-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      [body-arg : ast.AstExpr (ctfe-expr-arg args 1 env)]
      (match (compiler-ctfe-eval condition-arg env fuel)
        [(ResultCtfe.Ok condition-value condition-fuel)
          (let
            [condition-node : i64
              (ctfe-syntax-expr-value-node condition-value (& env))]
            (if (>= condition-node 0)
              (match (compiler-ctfe-eval body-arg env condition-fuel)
                [(ResultCtfe.Ok body-value next-fuel)
                  (let
                    [body-node : i64
                      (ctfe-syntax-expr-value-node body-value (& env))]
                    (if (>= body-node 0)
                      (ResultCtfe.Ok
                        (ctfe-syntax-expr-value
                          env
                          (ast.ast-expr-while-with-pools
                            (ctfe-env-syntax-pool-context-live env)
                            condition-node
                            body-node)
                          (ast.AstType.Unit))
                        next-fuel)
                      (ResultCtfe.Err
                        (box
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-while body expects Expr")))))]
                [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "expr-while condition expects Expr")))))]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr expr "expr-while expects exactly two args")))))

;; `(syntax-name-fresh text)`: the generated syntax identity for a spelling.
(define (ctfe-syntax-name-fresh [text : String]) : CompilerCtfeValue
  (CompilerCtfeValue.Name
    (string.copy text)
    (ctfe-materialize-generated-name-id text)))

(define (ctfe-eval-syntax-name-fresh-call
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (let
      [text-arg : ast.AstExpr (ctfe-expr-arg args 0 env)]
      (match (ctfe-eval-string-arg text-arg expr env fuel "syntax-name-fresh")
        [(ResultCtfeStringArg.Ok text _ next-fuel)
          (ResultCtfe.Ok (ctfe-syntax-name-fresh text) next-fuel)]
        [(ResultCtfeStringArg.Err diag) (ResultCtfe.Err diag)]))
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (cdiag.compiler-diagnostic-typecheck-tagged
            (cdiag.CompilerTypecheckKind.ArityMismatch)
            "syntax-name-fresh expects exactly one arg"))))))

(define (ctfe-direct-inspector-expr-result
  [node : i64]
  [ty : ast.AstType]
  [pools : ast.AstNodePoolContext]
  [captured? : bool]) : CompilerCtfeValue
  (if captured?
    (CompilerCtfeValue.CapturedExpr node ty pools)
    (CompilerCtfeValue.Expr node ty)))

(define (ctfe-direct-inspector-expr-call-with-pools
  [name : String]
  [node : i64]
  [ty : ast.AstType]
  [pools : ast.AstNodePoolContext]
  [captured? : bool]
  [fuel : i64]) : ResultCtfe
  (let
    [inspected : ast.AstExpr
      (ast.ast-expr-unspan-with-pools
        pools
        (ast.ast-node-pool-context-expr-get pools node))]
    (cond
      [(string.eq name "expr-bool?")
        (ResultCtfe.Ok
          (CompilerCtfeValue.Bool
            (match inspected
              [(ast.AstExpr.Literal (ast.AstLiteral.Bool _)) true]
              [_ false]))
          fuel)]
      [(string.eq name "expr-bool-value")
        (ResultCtfe.Ok
          (CompilerCtfeValue.Bool
            (match inspected
              [(ast.AstExpr.Literal (ast.AstLiteral.Bool found)) found]
              [_ false]))
          fuel)]
      [(string.eq name "expr-if?")
        (ResultCtfe.Ok
          (CompilerCtfeValue.Bool
            (match inspected
              [(ast.AstExpr.If _ _ _) true]
              [_ false]))
          fuel)]
      [else
        (match inspected
          [(ast.AstExpr.If cond then-expr else-expr)
            (ResultCtfe.Ok
              (ctfe-direct-inspector-expr-result
                (cond
                  [(string.eq name "expr-if-cond") cond]
                  [(string.eq name "expr-if-then") then-expr]
                  [else else-expr])
                (if (string.eq name "expr-if-cond")
                  (ast.AstType.Bool)
                  ty)
                pools
                captured?)
              fuel)]
          [_
            (ResultCtfe.Ok
              (ctfe-direct-inspector-expr-result node ty pools captured?)
              fuel)])])))

(define (ctfe-direct-inspector-clause-result
  [node : i64]
  [pools : ast.AstNodePoolContext]
  [captured? : bool]) : CompilerCtfeValue
  (if captured?
    (CompilerCtfeValue.CapturedExpr node (ctfe-untyped-expr-type) pools)
    (CompilerCtfeValue.Expr node (ctfe-untyped-expr-type))))

(define (ctfe-direct-inspector-clause-call
  [name : String]
  [clause : ast.AstExprClause]
  [pools : ast.AstNodePoolContext]
  [captured? : bool]
  [fuel : i64]) : ResultCtfe
  (ResultCtfe.Ok
    (ctfe-direct-inspector-clause-result
      (if (string.eq name "expr-clause-first")
        clause.first
        clause.second)
      pools
      captured?)
    fuel))

(define (ctfe-direct-inspector-clause-name? [name : (& name str)]) : bool
  (or
    (string.eq name "expr-clause-first")
    (string.eq name "expr-clause-second")))

(define (ctfe-direct-inspector-type-error
  [name : String]
  [expected : String]
  [expr : ast.AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr expr (str_cat.str-cat name " expects " expected)))))

(define (ctfe-eval-comptime-direct-inspector-value
  [name : String]
  [value : CompilerCtfeValue]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (ctfe-direct-inspector-clause-name? name)
    (match value
      [(CompilerCtfeValue.ExprClause clause)
        (ctfe-direct-inspector-clause-call
          name
          clause
          (ctfe-env-pools env)
          false
          fuel)]
      [(CompilerCtfeValue.CapturedExprClause clause pools)
        (ctfe-direct-inspector-clause-call name clause pools true fuel)]
      [_ (ctfe-direct-inspector-type-error name "ExprClause" expr)])
    (match value
      [(CompilerCtfeValue.Expr node ty)
        (ctfe-direct-inspector-expr-call-with-pools
          name
          node
          ty
          (ctfe-env-pools env)
          false
          fuel)]
      [(CompilerCtfeValue.CapturedExpr node ty pools)
        (ctfe-direct-inspector-expr-call-with-pools
          name
          node
          ty
          pools
          true
          fuel)]
      [_ (ctfe-direct-inspector-type-error name "Expr" expr)])))

(define (ctfe-eval-comptime-direct-inspector-call
  [name : String]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (= (ctfe-expr-arg-count args) 1)
    (match (compiler-ctfe-eval (ctfe-expr-arg args 0 env) env fuel)
      [(ResultCtfe.Ok value next-fuel)
        (ctfe-eval-comptime-direct-inspector-value
          name
          value
          expr
          env
          next-fuel)]
      [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])
    (ResultCtfe.Err
      (box
        (ctfe-diagnostic-at-expr
          expr
          (str_cat.str-cat name " expects exactly one arg"))))))

;; Dispatch a comptime call. Layout and reflection queries are compile-time-only
;; compiler metadata; selected String and Expr helpers make that metadata usable
;; in generator decisions without lowering it as runtime values.
(define (ctfe-unsupported-call
  [expr : ast.AstExpr]
  [raw-name : String]
  [raw-id : i64]
  [call-name : String]
  [call-id : i64]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        (str_cat.str-cat
          "unsupported compile-time call "
          raw-name
          "#"
          (string.int->string raw-id)
          " resolved as "
          call-name
          "#"
          (string.int->string call-id))))))

(define (ctfe-float-sqrt-unsupported [expr : ast.AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        "compile-time square root is not supported; use __tl_float_sqrt at runtime"))))

(define (ctfe-eval-call
  [func : ast.AstExpr]
  [args : ast.AstExprList]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match func
    [(ast.AstExpr.Spanned inner-box _)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-call inner args expr env fuel))]
    [(ast.AstExpr.MacroExpansion inner-box _ _)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (ctfe-eval-call inner args expr env fuel))]
    [(ast.AstExpr.Var name)
      (let
        [raw-id : i64
          (match (cis.intern-structural-session-macro-global-record-for-raw
            (ctfe-env-structural-session env)
            name)
            [(cis.InternMaybeMacroGlobalRecord.Some record)
              record.source-name-id]
            [(cis.InternMaybeMacroGlobalRecord.No) name])]
        [call-id : i64 (ctfe-comptime-helper-call-name-id raw-id)]
        (cond
          [(= call-id (ctfe-builtin "expr-bool"))
            (ctfe-eval-expr-bool-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-var"))
            (ctfe-eval-expr-var-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-list-fold-if"))
            (ctfe-eval-expr-list-fold-if-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-clause-list-fold-if"))
            (ctfe-eval-expr-clause-list-fold-if-call args expr env fuel)]
          [(= call-id (ctfe-builtin "string-slice"))
            (ctfe-eval-comptime-string-slice-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-int"))
            (ctfe-eval-expr-int-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-string"))
            (ctfe-eval-expr-string-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-binary-data"))
            (ctfe-eval-expr-binary-data-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-string?"))
            (ctfe-eval-expr-string-inspector-call false args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-string-value"))
            (ctfe-eval-expr-string-inspector-call true args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-struct-get"))
            (ctfe-eval-expr-struct-get-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-tuple-ref"))
            (ctfe-eval-expr-tuple-ref-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-struct-set"))
            (ctfe-eval-expr-struct-set-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-mut-borrow"))
            (ctfe-eval-expr-borrow-call
              true
              "expr-mut-borrow"
              args
              expr
              env
              fuel)]
          [(= call-id (ctfe-builtin "expr-borrow"))
            (ctfe-eval-expr-borrow-call false "expr-borrow" args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-array-ref"))
            (ctfe-eval-expr-array-ref-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-replace"))
            (ctfe-eval-expr-replace-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-call"))
            (ctfe-eval-expr-call-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-list-empty"))
            (ctfe-eval-expr-list-empty-call args expr fuel)]
          [(= call-id (ctfe-builtin "expr-list-cons"))
            (ctfe-eval-expr-list-cons-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-mut-call0"))
            (ctfe-eval-expr-mut-call
              args
              expr
              env
              fuel
              0
              "expr-mut-call0 expects exactly two args")]
          [(= call-id (ctfe-builtin "expr-mut-call1"))
            (ctfe-eval-expr-mut-call
              args
              expr
              env
              fuel
              1
              "expr-mut-call1 expects exactly three args")]
          [(= call-id (ctfe-builtin "expr-mut-call2"))
            (ctfe-eval-expr-mut-call
              args
              expr
              env
              fuel
              2
              "expr-mut-call2 expects exactly four args")]
          [(= call-id (ctfe-builtin "expr-splice"))
            (ctfe-eval-expr-splice-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-if"))
            (ctfe-eval-expr-if-call args expr env fuel)]
          [(= call-id (ctfe-builtin "pattern-wildcard"))
            (ctfe-eval-pattern-wildcard-call args expr fuel)]
          [(= call-id (ctfe-builtin "pattern-binding"))
            (ctfe-eval-pattern-binding-call args expr env fuel)]
          [(= call-id (ctfe-builtin "pattern-binding-typed"))
            (ctfe-eval-pattern-binding-typed-call args expr env fuel)]
          [(= call-id (ctfe-builtin "pattern-variant"))
            (ctfe-eval-pattern-variant-call args expr env fuel)]
          [(= call-id (ctfe-builtin "pattern-list-empty"))
            (ctfe-eval-pattern-list-empty-call args expr fuel)]
          [(= call-id (ctfe-builtin "pattern-list-cons"))
            (ctfe-eval-pattern-list-cons-call args expr env fuel)]
          [(= call-id (ctfe-builtin "pattern-list-bindings"))
            (ctfe-eval-pattern-list-bindings-call args expr env fuel)]
          [(= call-id (ctfe-builtin "match-arm"))
            (ctfe-eval-match-arm-call args expr env fuel)]
          [(= call-id (ctfe-builtin "match-arm-list-empty"))
            (ctfe-eval-match-arm-list-empty-call args expr fuel)]
          [(= call-id (ctfe-builtin "match-arm-list-cons"))
            (ctfe-eval-match-arm-list-cons-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-match"))
            (ctfe-eval-expr-match-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-resource-scope"))
            (ctfe-eval-expr-resource-scope-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-let-scope"))
            (ctfe-eval-expr-let-scope-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-set-var"))
            (ctfe-eval-expr-set-var-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-begin-unit"))
            (ctfe-eval-expr-begin-unit-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-not"))
            (ctfe-eval-expr-not-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-while"))
            (ctfe-eval-expr-while-call args expr env fuel)]
          [(= call-id (ctfe-builtin "syntax-name-fresh"))
            (ctfe-eval-syntax-name-fresh-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-type"))
            (ctfe-eval-expr-type-call args expr env fuel)]
          [(= call-id (ctfe-builtin "type-expr"))
            (ctfe-eval-type-expr-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-lambda1"))
            (ctfe-eval-expr-lambda1-call args expr env fuel)]
          [(= call-id (ctfe-builtin "module-name"))
            (ctfe-eval-module-name-call args expr env fuel)]
          [(= call-id (ctfe-builtin "module-export-macro?"))
            (ctfe-eval-module-export-macro-call args expr env fuel)]
          [(= call-id (ctfe-builtin "module-hook"))
            (ctfe-eval-module-hook-call args expr env fuel)]
          [(= call-id (ctfe-builtin "module-value?"))
            (ctfe-eval-module-value-call "module-value?" 0 args expr env fuel)]
          [(= call-id (ctfe-builtin "module-value-type"))
            (ctfe-eval-module-value-call
              "module-value-type"
              1
              args
              expr
              env
              fuel)]
          [(= call-id (ctfe-builtin "module-value-expr"))
            (ctfe-eval-module-value-call
              "module-value-expr"
              2
              args
              expr
              env
              fuel)]
          [(= call-id (ctfe-builtin "function-shared-borrow-returns-string?"))
            (ctfe-eval-function-shared-borrow-returns-string-call
              args
              expr
              env
              fuel)]
          [(= call-id (ctfe-builtin "expr-shared-call1"))
            (ctfe-eval-expr-shared-call1-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-shared-let-scope"))
            (ctfe-eval-expr-shared-let-scope-call args expr env fuel)]
          [(= call-id (ctfe-builtin "expr-list-type-nth"))
            (ctfe-eval-expr-list-type-nth-call args expr env fuel)]
          [else
            (let
              [raw-name : String (ci.intern-str raw-id)]
              [lookup-name : String
                (ctfe-hygiene-global-call-name
                  (owned_view.compiler-owned-shared-view raw-name))]
              [lookup-id : i64 raw-id]
              [call-name : String
                (if (= call-id lookup-id)
                  (owned_view.compiler-owned-shared-view lookup-name)
                  (ci.intern-str call-id))]
              [string-helper-candidate : bool
                (ctfe-string-helper-candidate-name-id?
                  (owned_view.compiler-owned-shared-view lookup-name)
                  lookup-id)]
              (cond
                [(or
                    (string.eq call-name "expr-for-owned-state")
                    (string.eq lookup-name "expr-for-owned-state"))
                  (ctfe-eval-expr-for-owned-call
                    0
                    "expr-for-owned-state"
                    args
                    expr
                    env
                    fuel)]
                [(or
                    (string.eq call-name "expr-for-owned-step")
                    (string.eq lookup-name "expr-for-owned-step"))
                  (ctfe-eval-expr-for-owned-call
                    1
                    "expr-for-owned-step"
                    args
                    expr
                    env
                    fuel)]
                [(or
                    (string.eq call-name "expr-for-owned-step-typed")
                    (string.eq lookup-name "expr-for-owned-step-typed"))
                  (ctfe-eval-expr-for-owned-call
                    2
                    "expr-for-owned-step-typed"
                    args
                    expr
                    env
                    fuel)]
                [(ctfe-builtin-size-align-id? lookup-id)
                  (ctfe-eval-size-align-query lookup-name args expr env fuel)]
                [(ctfe-builtin-offset-of-id? lookup-id)
                  (ctfe-eval-offset-query args expr env fuel)]
                [(ctfe-builtin-reflection-id? call-id)
                  (ctfe-eval-reflection-query
                    call-name
                    call-id
                    args
                    expr
                    env
                    fuel)]
                [(and
                    string-helper-candidate
                    (ctfe-string-eq-helper-name-id?
                      (owned_view.compiler-owned-shared-view lookup-name)
                      lookup-id))
                  (ctfe-eval-string-eq-call lookup-name args expr env fuel)]
                [(ctfe-builtin-string-build-id? call-id)
                  (ctfe-eval-string-append-call call-name args expr env fuel)]
                [(and
                    string-helper-candidate
                    (ctfe-string-length-helper-name-id?
                      (owned_view.compiler-owned-shared-view lookup-name)
                      lookup-id))
                  (ctfe-eval-string-length-call lookup-name args expr env fuel)]
                [(and
                    string-helper-candidate
                    (ctfe-string-ref-helper-name-id?
                      (owned_view.compiler-owned-shared-view lookup-name)
                      lookup-id))
                  (ctfe-eval-string-ref-call lookup-name args expr env fuel)]
                [(and
                    string-helper-candidate
                    (ctfe-string-to-int-helper-name-id?
                      (owned_view.compiler-owned-shared-view lookup-name)
                      lookup-id))
                  (ctfe-eval-string-to-int-call lookup-name args expr env fuel)]
                [(ctfe-builtin-int-to-string-id? call-id)
                  (ctfe-eval-int-to-string-call args expr env fuel)]
                [(ctfe-builtin-sequence-length-id? call-id)
                  (ctfe-eval-comptime-sequence-length-call
                    call-name
                    args
                    expr
                    env
                    fuel)]
                [(ctfe-builtin-sequence-nth-id? call-id)
                  (ctfe-eval-comptime-sequence-nth-call
                    call-name
                    args
                    expr
                    env
                    fuel)]
                [(ctfe-builtin-expr-binding-clause-inspector-id? call-id)
                  (ctfe-eval-expr-binding-clause-inspector-call
                    call-name
                    args
                    expr
                    env
                    fuel)]
                [(ctfe-builtin-direct-inspector-id? call-id)
                  (ctfe-eval-comptime-direct-inspector-call
                    call-name
                    args
                    expr
                    env
                    fuel)]
                [(ctfe-builtin-expr-clause-list-inspector-id? call-id)
                  (ctfe-eval-expr-clause-list-inspector-call
                    call-name
                    args
                    expr
                    env
                    fuel)]
                [(ctfe-builtin-expr-binding-clause-list-inspector-id? call-id)
                  (ctfe-eval-expr-binding-clause-list-inspector-call
                    call-name
                    args
                    expr
                    env
                    fuel)]
                [(ctfe-builtin-comptime-error-id? call-id)
                  (ctfe-eval-comptime-error-call args expr env fuel)]
                [(cbi.compiler-builtin-typecheck-float-sqrt-id? lookup-id)
                  (ctfe-float-sqrt-unsupported expr)]
                [else
                  (ctfe-unsupported-call expr raw-name raw-id call-name call-id)]))]))]
    [_ (ctfe-unsupported-form expr)]))

;; Shared "unsupported compile-time form" diagnostic for ordinary calls.
(define (ctfe-unsupported-form [expr : ast.AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        (clone expr)
        (str_cat.str-cat
          "'"
          (ctfe-describe-expr expr)
          "' is not supported in compile-time evaluation")))))

(define (ctfe-eval-var
  [name-id : i64]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (let
    [source-id : i64
      (cis.intern-structural-session-syntax-source-name-id-or
        (ctfe-env-structural-session env)
        name-id
        name-id)]
    (if (and
      (ci.intern-renderable-id? source-id)
      (not (ci.intern-qualified? source-id))
      (ci.intern-dotted? source-id))
      (let
        [root-id : i64 (ci.intern-leading-dot-id source-id)]
        (match (ctfe-env-lookup-id env root-id)
          [(CtfeMaybeValue.Some _)
            (ctfe-eval-dotted-var-source source-id expr env fuel)]
          [(CtfeMaybeValue.None) (ctfe-eval-var-direct name-id expr env fuel)]))
      (ctfe-eval-var-direct name-id expr env fuel))))

(define (ctfe-eval-var-direct
  [name-id : i64]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (ctfe-env-lookup-id env name-id)
    [(CtfeMaybeValue.Some value) (ResultCtfe.Ok value fuel)]
    [(CtfeMaybeValue.None)
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            (str_cat.str-cat
              "compile-time evaluation cannot reference runtime variable '"
              (ci.intern-str name-id)
              "'"))))]))

;; Dotted public places remain parser-owned Var nodes until semantic context can
;; distinguish a bound leading local from a module-qualified name. CTFE has the
;; same context in its value environment: once the leading name is bound,
;; reconstruct the projection chain from intern metadata and use the existing
;; well-known stdlib.comptime field evaluator at each step.
(define (ctfe-eval-dotted-var-source
  [source-id : i64]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (ci.intern-dotted? source-id)
    (if (<= fuel 0)
      (ResultCtfe.Err
        (box (ctfe-diagnostic-at-expr expr (ctfe-fuel-diagnostic-message))))
      (match (ctfe-eval-dotted-var-source
        (ci.intern-dotted-prefix-id source-id)
        (clone expr)
        env
        (- fuel 1))
        [(ResultCtfe.Ok value next-fuel)
          (ctfe-eval-struct-get-value
            value
            (ci.intern-dotted-final-id source-id)
            expr
            next-fuel)]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))
    (ctfe-eval-var-direct source-id expr env fuel)))

(define (ctfe-eval-box-get-value
  [value : CompilerCtfeValue]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (match value
    [(CompilerCtfeValue.TypeInfoBox ty)
      (ResultCtfe.Ok (CompilerCtfeValue.TypeInfo ty) fuel)]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            expr
            "box-get in compile-time evaluation requires a TypeInfo box")))]))

(define (ctfe-eval-box-get
  [inner : ast.AstExpr]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval inner env fuel)
    [(ResultCtfe.Ok value next-fuel)
      (ctfe-eval-box-get-value value expr next-fuel)]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

(define (ctfe-comptime-field-error [field : i64] [expr : ast.AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        (str_cat.str-cat
          "unsupported stdlib.comptime field '"
          (ci.intern-str field)
          "'")))))

(define (ctfe-comptime-struct-get-type-error [expr : ast.AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        "struct-get in compile-time evaluation requires a stdlib.comptime well-known value"))))

(define (ctfe-pattern-list-length [lst : (& lst ast.AstPatternList)]) : i64
  lst.len)

(define (ctfe-pattern-list-nth [lst : ast.AstPatternList] [index : i64]) : ast.AstPattern
  (ast.ast-pattern-list-get (& lst) index ast.AstPattern.Wildcard))

(define (ctfe-match-arm-empty-default [env : CtfeEnv]) : ast.AstMatchArm
  (ast.ast-match-arm
    ast.AstPattern.Wildcard
    (ctfe-ast-push env (ast.AstExpr.Literal (ast.AstLiteral.Unit)))))

(define (ctfe-match-arm-list-length [lst : (& lst ast.AstMatchArmList)]) : i64
  lst.len)

(define (ctfe-match-arm-list-nth
  [lst : ast.AstMatchArmList]
  [index : i64]
  [env : CtfeEnv]) : ast.AstMatchArm
  (ast.ast-match-arm-list-get (& lst) index (ctfe-match-arm-empty-default env)))

(define (ctfe-eval-struct-get-value-with-pools
  [value : CompilerCtfeValue]
  [field : i64]
  [expr : ast.AstExpr]
  [pools : ast.AstNodePoolContext]
  [session : cis.InternStructuralSessionHandle]
  [fuel : i64]) : ResultCtfe
  (let
    [field-kind : i64 field]
    (match value
      [(CompilerCtfeValue.ExprList nodes)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-items)
            (ResultCtfe.Ok (CompilerCtfeValue.ExprList nodes) fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-len)
            (ResultCtfe.Ok
              (CompilerCtfeValue.I64 (ctfe-expr-list-length nodes))
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.CapturedExprList nodes pools)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-items)
            (ResultCtfe.Ok
              (CompilerCtfeValue.CapturedExprList nodes pools)
              fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-len)
            (ResultCtfe.Ok
              (CompilerCtfeValue.I64 (ctfe-expr-list-length nodes))
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.ExprClause clause)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-first)
            (ResultCtfe.Ok
              (CompilerCtfeValue.Expr
                (ctfe-expr-clause-first clause)
                (ctfe-untyped-expr-type))
              fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-second)
            (ResultCtfe.Ok
              (CompilerCtfeValue.Expr
                (ctfe-expr-clause-second clause)
                (ctfe-untyped-expr-type))
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.CapturedExprClause clause pools)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-first)
            (ResultCtfe.Ok
              (CompilerCtfeValue.CapturedExpr
                (ctfe-expr-clause-first clause)
                (ctfe-untyped-expr-type)
                pools)
              fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-second)
            (ResultCtfe.Ok
              (CompilerCtfeValue.CapturedExpr
                (ctfe-expr-clause-second clause)
                (ctfe-untyped-expr-type)
                pools)
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.ExprClauseList clauses)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-items)
            (ResultCtfe.Ok (CompilerCtfeValue.ExprClauseList clauses) fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-len)
            (ResultCtfe.Ok
              (CompilerCtfeValue.I64 (ctfe-expr-clause-list-length clauses))
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.CapturedExprClauseList clauses pools)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-items)
            (ResultCtfe.Ok
              (CompilerCtfeValue.CapturedExprClauseList clauses pools)
              fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-len)
            (ResultCtfe.Ok
              (CompilerCtfeValue.I64 (ctfe-expr-clause-list-length clauses))
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.ExprBindingClause clause)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-name)
            (ResultCtfe.Ok
              (ctfe-name-value-for-session
                session
                (ci.intern-syntax-id-value
                  (ctfe-expr-binding-clause-name-id clause)))
              fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-has_type)
            (ResultCtfe.Ok
              (CompilerCtfeValue.Bool
                (ctfe-expr-binding-clause-has-type? clause))
              fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-ty)
            (ResultCtfe.Ok
              (CompilerCtfeValue.Expr
                (ctfe-expr-binding-clause-type clause)
                (ctfe-untyped-expr-type))
              fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-init)
            (let
              [produced : ast.AstType (clone clause.init-produced)]
              (ResultCtfe.Ok
                (CompilerCtfeValue.Expr
                  (ctfe-caller-origin-expr-node-with-pools
                    pools
                    (ctfe-expr-binding-clause-init clause)
                    (clone produced))
                  (ctfe-caller-origin-expr-type-inner-with-pools pools produced))
                fuel))]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.ExprBindingClauseList clauses)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-items)
            (ResultCtfe.Ok
              (CompilerCtfeValue.ExprBindingClauseList clauses)
              fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-len)
            (ResultCtfe.Ok
              (CompilerCtfeValue.I64
                (ctfe-expr-binding-clause-list-length clauses))
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.PatternList patterns)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-items)
            (ResultCtfe.Ok (CompilerCtfeValue.PatternList patterns) fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-len)
            (ResultCtfe.Ok
              (CompilerCtfeValue.I64 (ctfe-pattern-list-length patterns))
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.MatchArm arm)
        (match arm
          [(ast.AstMatchArm.Arm pattern body)
            (cond
              [(= field-kind cbi.compiler-builtin-id-fix-pattern)
                (ResultCtfe.Ok (CompilerCtfeValue.Pattern pattern) fuel)]
              [(= field-kind cbi.compiler-builtin-id-fix-body)
                (ResultCtfe.Ok
                  (CompilerCtfeValue.Expr body (ctfe-untyped-expr-type))
                  fuel)]
              [else (ctfe-comptime-field-error field expr)])])]
      [(CompilerCtfeValue.MatchArmList arms)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-items)
            (ResultCtfe.Ok (CompilerCtfeValue.MatchArmList arms) fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-len)
            (ResultCtfe.Ok
              (CompilerCtfeValue.I64 (ctfe-match-arm-list-length arms))
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.TypeInfoList items)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-items)
            (ResultCtfe.Ok (CompilerCtfeValue.TypeInfoList items) fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-len)
            (ResultCtfe.Ok
              (CompilerCtfeValue.I64 (ctfe-type-list-count items))
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.TypeField name ty)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-name)
            (ResultCtfe.Ok (ctfe-generated-string-value name) fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-ty)
            (ResultCtfe.Ok (CompilerCtfeValue.TypeInfo ty) fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.TypeFieldList fields)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-items)
            (ResultCtfe.Ok (CompilerCtfeValue.TypeFieldList fields) fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-len)
            (ResultCtfe.Ok
              (CompilerCtfeValue.I64 (ctfe-reflect-field-list-count fields))
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.TypeVariantPayload ty)
        (if (= field-kind cbi.compiler-builtin-id-fix-ty)
          (ResultCtfe.Ok (CompilerCtfeValue.TypeInfo ty) fuel)
          (ctfe-comptime-field-error field expr))]
      [(CompilerCtfeValue.TypeVariantPayloadList payloads)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-items)
            (ResultCtfe.Ok
              (CompilerCtfeValue.TypeVariantPayloadList payloads)
              fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-len)
            (ResultCtfe.Ok
              (CompilerCtfeValue.I64 (ctfe-type-list-count payloads))
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.TypeVariant name payloads)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-name)
            (ResultCtfe.Ok (ctfe-generated-string-value name) fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-payloads)
            (ResultCtfe.Ok
              (CompilerCtfeValue.TypeVariantPayloadList payloads)
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [(CompilerCtfeValue.TypeVariantList variants)
        (cond
          [(= field-kind cbi.compiler-builtin-id-fix-items)
            (ResultCtfe.Ok (CompilerCtfeValue.TypeVariantList variants) fuel)]
          [(= field-kind cbi.compiler-builtin-id-fix-len)
            (ResultCtfe.Ok
              (CompilerCtfeValue.I64 (ctfe-reflect-variant-list-count variants))
              fuel)]
          [else (ctfe-comptime-field-error field expr)])]
      [_ (ctfe-comptime-struct-get-type-error expr)])))

(define (ctfe-eval-struct-get-value
  [value : CompilerCtfeValue]
  [field : i64]
  [expr : ast.AstExpr]
  [fuel : i64]) : ResultCtfe
  (ctfe-eval-struct-get-value-with-pools
    value
    field
    expr
    (ast.ast-node-pool-context-capture-active)
    (cis.intern-structural-session-handle-from-source-names
      (ci.intern-source-name-session-capture-active-handle))
    fuel))

(define (ctfe-eval-struct-get
  [inner : ast.AstExpr]
  [field : i64]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval inner env fuel)
    [(ResultCtfe.Ok value next-fuel)
      (ctfe-eval-struct-get-value-with-pools
        value
        field
        expr
        (ctfe-env-pools env)
        (ctfe-env-structural-session env)
        next-fuel)]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

(define (ctfe-comptime-array-index-error [expr : ast.AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box (ctfe-diagnostic-at-expr expr "array-ref index out of range"))))

(define (ctfe-comptime-array-type-error [expr : ast.AstExpr]) : ResultCtfe
  (ResultCtfe.Err
    (box
      (ctfe-diagnostic-at-expr
        expr
        "array-ref in compile-time evaluation requires stdlib.comptime sequence items"))))

(define (ctfe-eval-array-ref-value
  [array : CompilerCtfeValue]
  [index : i64]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match array
    [(CompilerCtfeValue.ExprList nodes)
      (if (or (< index 0) (>= index (ctfe-expr-list-length nodes)))
        (ctfe-comptime-array-index-error expr)
        (ResultCtfe.Ok
          (CompilerCtfeValue.Expr
            (ctfe-expr-list-nth nodes index)
            (ctfe-untyped-expr-type))
          fuel))]
    [(CompilerCtfeValue.CapturedExprList nodes pools)
      (if (or (< index 0) (>= index (ctfe-expr-list-length nodes)))
        (ctfe-comptime-array-index-error expr)
        (ResultCtfe.Ok
          (CompilerCtfeValue.CapturedExpr
            (ctfe-expr-list-nth nodes index)
            (ctfe-untyped-expr-type)
            pools)
          fuel))]
    [(CompilerCtfeValue.ExprClauseList clauses)
      (if (or (< index 0) (>= index (ctfe-expr-clause-list-length clauses)))
        (ctfe-comptime-array-index-error expr)
        (ResultCtfe.Ok
          (CompilerCtfeValue.ExprClause
            (ctfe-expr-clause-list-nth clauses index))
          fuel))]
    [(CompilerCtfeValue.CapturedExprClauseList clauses pools)
      (if (or (< index 0) (>= index (ctfe-expr-clause-list-length clauses)))
        (ctfe-comptime-array-index-error expr)
        (ResultCtfe.Ok
          (CompilerCtfeValue.CapturedExprClause
            (ctfe-expr-clause-list-nth clauses index)
            pools)
          fuel))]
    [(CompilerCtfeValue.ExprBindingClauseList clauses)
      (if (or
        (< index 0)
        (>= index (ctfe-expr-binding-clause-list-length (& clauses))))
        (ctfe-comptime-array-index-error expr)
        (ResultCtfe.Ok
          (CompilerCtfeValue.ExprBindingClause
            (ctfe-expr-binding-clause-list-nth clauses index))
          fuel))]
    [(CompilerCtfeValue.PatternList patterns)
      (if (or (< index 0) (>= index (ctfe-pattern-list-length patterns)))
        (ctfe-comptime-array-index-error expr)
        (ResultCtfe.Ok
          (CompilerCtfeValue.Pattern (ctfe-pattern-list-nth patterns index))
          fuel))]
    [(CompilerCtfeValue.MatchArmList arms)
      (if (or (< index 0) (>= index (ctfe-match-arm-list-length arms)))
        (ctfe-comptime-array-index-error expr)
        (ResultCtfe.Ok
          (CompilerCtfeValue.MatchArm (ctfe-match-arm-list-nth arms index env))
          fuel))]
    [(CompilerCtfeValue.TypeInfoList items)
      (match (ctfe-type-list-ref-with-pools
        items
        (ctfe-env-pools env)
        (ctfe-env-reflections env)
        index)
        [(ResultCtfeTypeLookup.Ok ty)
          (ResultCtfe.Ok (CompilerCtfeValue.TypeInfo ty) fuel)]
        [(ResultCtfeTypeLookup.Err _) (ctfe-comptime-array-index-error expr)])]
    [(CompilerCtfeValue.TypeFieldList fields)
      (if (or (< index 0) (>= index (ctfe-reflect-field-list-count fields)))
        (ctfe-comptime-array-index-error expr)
        (match (ctfe-reflect-field-list-ref fields index)
          [(CtfeReflectField.Field name ty)
            (let
              [reflections : CtfeReflectInfoList (ctfe-env-reflections env)]
              (ResultCtfe.Ok
                (CompilerCtfeValue.TypeField
                  (ci.intern-str name)
                  (ctfe-reflect-resolve-type-with-pools
                    (ctfe-env-pools env)
                    reflections
                    ty))
                fuel))]))]
    [(CompilerCtfeValue.TypeVariantPayloadList payloads)
      (match (ctfe-type-list-ref-with-pools
        payloads
        (ctfe-env-pools env)
        (ctfe-env-reflections env)
        index)
        [(ResultCtfeTypeLookup.Ok ty)
          (ResultCtfe.Ok (CompilerCtfeValue.TypeVariantPayload ty) fuel)]
        [(ResultCtfeTypeLookup.Err _) (ctfe-comptime-array-index-error expr)])]
    [(CompilerCtfeValue.TypeVariantList variants)
      (if (or (< index 0) (>= index (ctfe-reflect-variant-list-count variants)))
        (ctfe-comptime-array-index-error expr)
        (match (ctfe-reflect-variant-list-ref variants index)
          [(CtfeReflectVariant.Variant name payloads)
            (ResultCtfe.Ok
              (CompilerCtfeValue.TypeVariant (ci.intern-str name) payloads)
              fuel)]))]
    [_ (ctfe-comptime-array-type-error expr)]))

(define (ctfe-eval-array-ref
  [array : ast.AstExpr]
  [index : ast.AstExpr]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval array env fuel)
    [(ResultCtfe.Ok array-value array-fuel)
      (match (compiler-ctfe-eval index env array-fuel)
        [(ResultCtfe.Ok index-value index-fuel)
          (match index-value
            [(CompilerCtfeValue.I64 index)
              (ctfe-eval-array-ref-value array-value index expr env index-fuel)]
            [_
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    expr
                    "array-ref index must be i64 in compile-time evaluation")))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

(define (ctfe-eval-binary
  [op : ast.AstBinOp]
  [left : ast.AstExpr]
  [right : ast.AstExpr]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval left env fuel)
    [(ResultCtfe.Ok lv left-fuel)
      (match (compiler-ctfe-eval right env left-fuel)
        [(ResultCtfe.Ok rv right-fuel)
          (ctfe-apply-binop op lv rv expr env right-fuel)]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

(define (ctfe-eval-unary
  [op : ast.AstUnOp]
  [inner : ast.AstExpr]
  [expr : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval inner env fuel)
    [(ResultCtfe.Ok v inner-fuel) (ctfe-apply-unop op v expr inner-fuel)]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

(define (ctfe-eval-if
  [cond : ast.AstExpr]
  [then-branch : ast.AstExpr]
  [else-branch : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval (clone cond) env fuel)
    [(ResultCtfe.Ok cond-value cond-fuel)
      (match cond-value
        [(CompilerCtfeValue.Bool b)
          (if b
            (compiler-ctfe-eval then-branch env cond-fuel)
            (compiler-ctfe-eval else-branch env cond-fuel))]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                cond
                "comptime 'if' condition must be bool")))])]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

;; CTFE loops evaluate only compiler-owned values, share the normal evaluator
;; fuel counter, and return unit. A non-terminating loop therefore reaches the
;; existing deterministic fuel diagnostic instead of relying on host state.
(define (ctfe-eval-while
  [cond : ast.AstExpr]
  [body : ast.AstExpr]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval (clone cond) env fuel)
    [(ResultCtfe.Ok cond-value cond-fuel)
      (match cond-value
        [(CompilerCtfeValue.Bool keep-going)
          (if keep-going
            (match (compiler-ctfe-eval (clone body) env cond-fuel)
              [(ResultCtfe.Ok _ body-fuel)
                (ctfe-eval-while cond body origin env body-fuel)]
              [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])
            (ResultCtfe.Ok (CompilerCtfeValue.Unit) cond-fuel))]
        [_
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                origin
                "comptime 'while' condition must be bool")))])]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

;; CTFE assignment is intentionally limited to the mutable cells created for
;; lexical `let` bindings above. The right-hand side has already been evaluated
;; to a CompilerCtfeValue, so this cannot materialize or mutate a runtime value.
(define (ctfe-eval-set
  [name-id : i64]
  [rhs : ast.AstExpr]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval rhs env fuel)
    [(ResultCtfe.Ok value rhs-fuel)
      (begin
        ;; Mutable macro locals can retain syntax assembled in a newer captured
        ;; snapshot. Publish that cursor before the next sibling expression is
        ;; evaluated, otherwise it can allocate the same node id and overwrite
        ;; the value just stored.
        (match (owned_view.compiler-owned-shared-view value)
          [(CompilerCtfeValue.CapturedExpr _ _ pools)
            (ctfe-env-adopt-captured-pools! (& env) pools)]
          [(CompilerCtfeValue.CapturedExprList _ pools)
            (ctfe-env-adopt-captured-pools! (& env) pools)]
          [(CompilerCtfeValue.CapturedExprClause _ pools)
            (ctfe-env-adopt-captured-pools! (& env) pools)]
          [(CompilerCtfeValue.CapturedExprClauseList _ pools)
            (ctfe-env-adopt-captured-pools! (& env) pools)]
          [_ unit])
        (if (ctfe-env-set-local-id! env name-id value)
          (ResultCtfe.Ok (CompilerCtfeValue.Unit) rhs-fuel)
          (ResultCtfe.Err
            (box
              (ctfe-diagnostic-at-expr
                origin
                "comptime set! requires a local let binding")))))]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

(define (ctfe-eval-replace
  [place : ast.AstExpr]
  [replacement : ast.AstExpr]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (ctfe-expr-unspan env place)
    [(ast.AstExpr.Var name-id)
      (match (compiler-ctfe-eval replacement env fuel)
        [(ResultCtfe.Ok value replacement-fuel)
          (match (ctfe-env-lookup-id env name-id)
            [(CtfeMaybeValue.Some old)
              (if (ctfe-env-set-local-id! env name-id value)
                (ResultCtfe.Ok old replacement-fuel)
                (ResultCtfe.Err
                  (box
                    (ctfe-diagnostic-at-expr
                      origin
                      (cdiag.compiler-diagnostic-typecheck-tagged
                        (cdiag.CompilerTypecheckKind.Place)
                        "comptime replace! requires a mutable local let binding")))))]
            [(CtfeMaybeValue.None)
              (ResultCtfe.Err
                (box
                  (ctfe-diagnostic-at-expr
                    origin
                    (cdiag.compiler-diagnostic-typecheck-tagged
                      (cdiag.CompilerTypecheckKind.Place)
                      "comptime replace! requires a mutable local let binding"))))])]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)])]
    [_
      (ResultCtfe.Err
        (box
          (ctfe-diagnostic-at-expr
            origin
            "comptime replace! currently supports local let bindings only")))]))

;; Evaluate `let` bindings sequentially, threading both fuel and the extended
;; environment. The original `env` is preserved for siblings because each
;; binding extends a fresh copy threaded forward.
(define (ctfe-eval-let
  [bindings : ast.AstLetBindingList]
  [body : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (ctfe-eval-let-at (& bindings) 0 body env fuel))

(define (ctfe-eval-let-at
  [bindings : (& bindings ast.AstLetBindingList)]
  [index : i64]
  [body : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (>= index (ast.ast-let-binding-list-len bindings))
    (compiler-ctfe-eval body env fuel)
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name maybe-ty value-expr-box)
        (let
          [value-expr : ast.AstExpr (ctfe-ast-get env value-expr-box)]
          (match (compiler-ctfe-eval (clone value-expr) env fuel)
            [(ResultCtfe.Ok value value-fuel)
              (ctfe-eval-let-at
                bindings
                (+ index 1)
                body
                (ctfe-env-extend-local-typed-id
                  env
                  name
                  (ctfe-value-owned-copy (& value))
                  (ctfe-binding-type
                    maybe-ty
                    (ctfe-cast-source-type value-expr value env)
                    env))
                value-fuel)]
            [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))])))

;; Evaluate a `begin` to the value of its last expression; an empty body is
;; unit.
(define (ctfe-eval-begin-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (>= index exprs.len)
    (ResultCtfe.Ok (CompilerCtfeValue.Unit) fuel)
    (let
      [head : ast.AstExpr
        (ctfe-ast-get env (ast.ast-expr-list-get exprs index 0))]
      (match (compiler-ctfe-eval head env fuel)
        [(ResultCtfe.Ok value head-fuel)
          (if (= (+ index 1) exprs.len)
            (ResultCtfe.Ok value head-fuel)
            (ctfe-eval-begin-at exprs (+ index 1) env head-fuel))]
        [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))))

(define (ctfe-eval-begin [exprs : ast.AstExprList] [env : CtfeEnv] [fuel : i64]) : ResultCtfe
  (ctfe-eval-begin-at (& exprs) 0 env fuel))

;; Evaluate a small CTFE-owned `match` subset. Runtime enum/struct values still
;; have no CTFE representation; this covers scalar values and the public
;; stdlib.comptime syntax pseudo-values backed by CompilerCtfeValue.Expr/CompilerCtfeValue.ExprList.
(define (ctfe-value-seq-with-capacity [capacity : i64]) : CtfeValueSeq
  (CtfeValueSeq (__tl_make-array CompilerCtfeValue capacity) 0))

(define (ctfe-value-seq-push [items : CtfeValueSeq] [value : CompilerCtfeValue]) : CtfeValueSeq
  (let
    [n : i64 items.len]
    [slots : (__tl_dyn-array CompilerCtfeValue) items.slots]
    (begin
      (set! (array-ref slots n) value)
      (CtfeValueSeq slots (+ n 1)))))

(define (ctfe-value-list1 [a : CompilerCtfeValue]) : CtfeValueSeq
  (ctfe-value-seq-push (ctfe-value-seq-with-capacity 1) a))

(define (ctfe-value-list2 [a : CompilerCtfeValue] [b : CompilerCtfeValue]) : CtfeValueSeq
  (ctfe-value-seq-push
    (ctfe-value-seq-push (ctfe-value-seq-with-capacity 2) a)
    b))

(define (ctfe-value-list3
  [a : CompilerCtfeValue]
  [b : CompilerCtfeValue]
  [c : CompilerCtfeValue]) : CtfeValueSeq
  (ctfe-value-seq-push
    (ctfe-value-seq-push
      (ctfe-value-seq-push (ctfe-value-seq-with-capacity 3) a)
      b)
    c))

(define (ctfe-string-suffix? [text : String] [suffix : String]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [suffix-len : i64 (string.string-length suffix)]
    (if (< text-len suffix-len)
      false
      (string.eq
        (string.substring text (- text-len suffix-len) suffix-len)
        suffix))))

(define (ctfe-pattern-variant-name? [name : i64] [expected : String]) : bool
  (let
    [actual : String (ci.intern-str name)]
    (or
      (string.eq (string.copy actual) (string.copy expected))
      (ctfe-string-suffix?
        (string.copy actual)
        (str_cat.str-cat "." (string.copy expected)))
      (ctfe-string-suffix? actual (str_cat.str-cat "/" expected)))))

(define (ctfe-literal-matches-value?
  [lit : ast.AstLiteral]
  [session : cis.InternStructuralSessionHandle]
  [value : CompilerCtfeValue]) : bool
  (match lit
    [(ast.AstLiteral.Int n text)
      (match value
        [(CompilerCtfeValue.I64 actual)
          (= actual (ast.ast-int-literal-value-or-payload n text))]
        [_ false])]
    [(ast.AstLiteral.Bool b)
      (match value
        [(CompilerCtfeValue.Bool actual) (= actual b)]
        [_ false])]
    [(ast.AstLiteral.Char c)
      (match value
        [(CompilerCtfeValue.Char actual) (= actual c)]
        [_ false])]
    [(ast.AstLiteral.Unit)
      (match value
        [(CompilerCtfeValue.Unit) true]
        [_ false])]
    [(ast.AstLiteral.Float text)
      (match (cfloat.compiler-float-parse-f64 text)
        [(CompilerFloatSomeF64 want)
          (match value
            [(CompilerCtfeValue.F64 actual) (= actual want)]
            [(CompilerCtfeValue.F32 actual) (= actual want)]
            [_ false])]
        [(CompilerFloatNoF64) false])]
    [(ast.AstLiteral.String string-id)
      (let
        [text : String (ctfe-name-text-for-session session string-id)]
        (match value
          [(CompilerCtfeValue.String actual _) (string.eq actual text)]
          [(CompilerCtfeValue.Name actual _) (string.eq actual text)]
          [_ false]))]))

(define (ctfe-match-pattern-list
  [patterns : ast.AstPatternList]
  [values : CtfeValueSeq]
  [env : CtfeEnv]) : CtfePatternMatch
  (ctfe-match-pattern-list-at (& patterns) 0 values env))

(define (ctfe-match-pattern-list-at
  [patterns : (& patterns ast.AstPatternList)]
  [index : i64]
  [values : CtfeValueSeq]
  [env : CtfeEnv]) : CtfePatternMatch
  (if (>= index patterns.len)
    (if (= index values.len)
      (CtfePatternMatch.Matched env)
      (CtfePatternMatch.No))
    (if (>= index values.len)
      (CtfePatternMatch.No)
      (let
        [value : CompilerCtfeValue
          (ast.ast-array-shared-view values.slots index)]
        [value-ty : ast.AstType
          (ctfe-value-default-cast-type (ctfe-env-pools env) (& value))]
        (match (ctfe-match-pattern
          (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback))
          value
          value-ty
          env)
          [(CtfePatternMatch.Matched next-env)
            (ctfe-match-pattern-list-at patterns (+ index 1) values next-env)]
          [(CtfePatternMatch.No) (CtfePatternMatch.No)])))))

(define (ctfe-match-expr-variant
  [variant : i64]
  [args : ast.AstPatternList]
  [node : i64]
  [ty : ast.AstType]
  [env : CtfeEnv]) : CtfePatternMatch
  (match (ctfe-expr-unspan env (ctfe-ast-get env node))
    [(ast.AstExpr.Literal lit)
      (match lit
        [(ast.AstLiteral.Bool b)
          (if (ctfe-pattern-variant-name? variant "Bool")
            (ctfe-match-pattern-list
              args
              (ctfe-value-list1 (CompilerCtfeValue.Bool b))
              env)
            (CtfePatternMatch.No))]
        [(ast.AstLiteral.Int n text)
          (if (ctfe-pattern-variant-name? variant "Int")
            (ctfe-match-pattern-list
              args
              (ctfe-value-list1
                (CompilerCtfeValue.I64
                  (ast.ast-int-literal-value-or-payload n text)))
              env)
            (CtfePatternMatch.No))]
        [_ (CtfePatternMatch.No)])]
    [(ast.AstExpr.Var name)
      (if (ctfe-pattern-variant-name? variant "Var")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1
            (ctfe-name-value-for-session (ctfe-env-structural-session env) name))
          env)
        (CtfePatternMatch.No))]
    [(ast.AstExpr.If cond then-branch else-branch)
      (if (ctfe-pattern-variant-name? variant "If")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list3
            (CompilerCtfeValue.Expr cond (ast.AstType.Bool))
            (CompilerCtfeValue.Expr then-branch (clone ty))
            (CompilerCtfeValue.Expr else-branch ty))
          env)
        (CtfePatternMatch.No))]
    [(ast.AstExpr.Call callee args-list)
      (if (ctfe-pattern-variant-name? variant "Call")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list2
            (CompilerCtfeValue.Expr callee (ctfe-untyped-expr-type))
            (CompilerCtfeValue.ExprList args-list))
          env)
        (CtfePatternMatch.No))]
    [(ast.AstExpr.Begin exprs)
      (if (ctfe-pattern-variant-name? variant "Begin")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1 (CompilerCtfeValue.ExprList exprs))
          env)
        (CtfePatternMatch.No))]
    [(ast.AstExpr.Quote inner)
      (if (ctfe-pattern-variant-name? variant "Quote")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1
            (CompilerCtfeValue.Expr inner (ctfe-untyped-expr-type)))
          env)
        (CtfePatternMatch.No))]
    [(ast.AstExpr.Quasiquote inner)
      (if (ctfe-pattern-variant-name? variant "Quasiquote")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1
            (CompilerCtfeValue.Expr inner (ctfe-untyped-expr-type)))
          env)
        (CtfePatternMatch.No))]
    [(ast.AstExpr.Unquote inner)
      (if (ctfe-pattern-variant-name? variant "Unquote")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1
            (CompilerCtfeValue.Expr inner (ctfe-untyped-expr-type)))
          env)
        (CtfePatternMatch.No))]
    [(ast.AstExpr.UnquoteSplicing inner)
      (if (ctfe-pattern-variant-name? variant "UnquoteSplicing")
        (ctfe-match-pattern-list
          args
          (ctfe-value-list1
            (CompilerCtfeValue.Expr inner (ctfe-untyped-expr-type)))
          env)
        (CtfePatternMatch.No))]
    [_ (CtfePatternMatch.No)]))

(define (ctfe-match-pattern
  [pattern : ast.AstPattern]
  [value : CompilerCtfeValue]
  [value-ty : ast.AstType]
  [env : CtfeEnv]) : CtfePatternMatch
  (match (clone pattern)
    [(ast.AstPattern.Wildcard) (CtfePatternMatch.Matched env)]
    [(ast.AstPattern.Binding name)
      (CtfePatternMatch.Matched
        (ctfe-env-extend-typed-id env name value value-ty))]
    [(ast.AstPattern.Var name maybe-ty)
      (CtfePatternMatch.Matched
        (ctfe-env-extend-typed-id
          env
          name
          value
          (ctfe-binding-type maybe-ty value-ty env)))]
    [(ast.AstPattern.Literal lit)
      (if (ctfe-literal-matches-value?
        lit
        (ctfe-env-structural-session env)
        value)
        (CtfePatternMatch.Matched env)
        (CtfePatternMatch.No))]
    [(ast.AstPattern.Variant variant args-box)
      (let
        [args : ast.AstPatternList (deref args-box)]
        (match value
          [(CompilerCtfeValue.Expr node ty)
            (ctfe-match-expr-variant variant args node ty env)]
          [(CompilerCtfeValue.CapturedExpr node ty pools)
            (ctfe-match-expr-variant
              variant
              args
              node
              ty
              (ctfe-env-rebase-pools env pools))]
          [(CompilerCtfeValue.TypeInfo ty)
            (ctfe-match-type-info-variant variant args ty env)]
          [(CompilerCtfeValue.TypeInfoBox ty)
            (if (ctfe-pattern-variant-name? variant "box")
              (ctfe-match-pattern-list
                args
                (ctfe-value-list1 (CompilerCtfeValue.TypeInfo ty))
                env)
              (CtfePatternMatch.No))]
          [(CompilerCtfeValue.ExprClause clause)
            (if (ctfe-pattern-variant-name? variant "ExprClause")
              (ctfe-match-pattern-list
                args
                (ctfe-value-list2
                  (CompilerCtfeValue.Expr
                    (ctfe-expr-clause-first clause)
                    (ctfe-untyped-expr-type))
                  (CompilerCtfeValue.Expr
                    (ctfe-expr-clause-second clause)
                    (ctfe-untyped-expr-type)))
                env)
              (CtfePatternMatch.No))]
          [(CompilerCtfeValue.CapturedExprClause clause pools)
            (if (ctfe-pattern-variant-name? variant "ExprClause")
              (ctfe-match-pattern-list
                args
                (ctfe-value-list2
                  (CompilerCtfeValue.CapturedExpr
                    (ctfe-expr-clause-first clause)
                    (ctfe-untyped-expr-type)
                    (ast.ast-node-pool-context-clone pools))
                  (CompilerCtfeValue.CapturedExpr
                    (ctfe-expr-clause-second clause)
                    (ctfe-untyped-expr-type)
                    pools))
                env)
              (CtfePatternMatch.No))]
          [_ (CtfePatternMatch.No)]))]
    [(ast.AstPattern.Tuple _) (CtfePatternMatch.No)]
    [(ast.AstPattern.Array _) (CtfePatternMatch.No)]
    ;; Comptime values have no Slice representation.
    [(ast.AstPattern.Slice _ _) (CtfePatternMatch.No)]))

(define (ctfe-eval-match-arms
  [value : CompilerCtfeValue]
  [value-ty : ast.AstType]
  [arms : ast.AstMatchArmList]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (ctfe-eval-match-arms-at value value-ty (& arms) 0 origin env fuel))

(define (ctfe-eval-match-arms-at
  [value : CompilerCtfeValue]
  [value-ty : ast.AstType]
  [arms : (& arms ast.AstMatchArmList)]
  [index : i64]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (>= index arms.len)
    (ResultCtfe.Err
      (box (ctfe-diagnostic-at-expr origin "comptime: no matching match arm")))
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm pattern body-box)
        (match (ctfe-match-pattern
          pattern
          (ctfe-value-owned-copy (& value))
          (clone value-ty)
          env)
          [(CtfePatternMatch.Matched arm-env)
            (compiler-ctfe-eval (ctfe-ast-get env body-box) arm-env fuel)]
          [(CtfePatternMatch.No)
            (ctfe-eval-match-arms-at
              value
              value-ty
              arms
              (+ index 1)
              origin
              env
              fuel)])])))

(define (ctfe-eval-match
  [scrutinee : ast.AstExpr]
  [arms : ast.AstMatchArmList]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval (clone scrutinee) env fuel)
    [(ResultCtfe.Ok value scrutinee-fuel)
      (ctfe-eval-match-arms
        (ctfe-value-owned-copy (& value))
        (ctfe-cast-source-type scrutinee value env)
        arms
        origin
        env
        scrutinee-fuel)]
    [(ResultCtfe.Err diag) (ResultCtfe.Err diag)]))

;; --- quote / quasiquote -----------------------------------------------------
(define (ctfe-quote-literal-type [lit : ast.AstLiteral]) : ast.AstType
  (match lit
    [(ast.AstLiteral.Int _ _) (ast.AstType.I64)]
    [(ast.AstLiteral.Float _) (ast.AstType.F64)]
    [(ast.AstLiteral.Bool _) (ast.AstType.Bool)]
    [(ast.AstLiteral.Char _) (ast.AstType.Char)]
    [(ast.AstLiteral.String _) (ast.AstType.String)]
    [(ast.AstLiteral.Unit) (ast.AstType.Unit)]))

(define (ctfe-expr-list-append
  [left : ast.AstExprList]
  [right : ast.AstExprList]) : ast.AstExprList
  (let
    [out : ast.AstExprList
      (ast.ast-expr-list-with-capacity (+ left.len right.len))]
    (begin
      (ast.ast-expr-list-append-from (&mut out) (& left) 0)
      (ast.ast-expr-list-append-from (&mut out) (& right) 0)
      out)))

(define (ctfe-quote-if-type
  [cond-ty : ast.AstType]
  [then-ty : ast.AstType]
  [else-ty : ast.AstType]) : ast.AstType
  (if (and
    (ctfe-type-eq cond-ty (ast.AstType.Bool))
    (ctfe-type-eq (clone then-ty) else-ty))
    then-ty
    (ast.AstType.Expr)))

;; A captured syntax value can be used as an ordinary quote child only when its
;; node IDs address the same backing pools as the quote environment. Snapshot
;; contexts use distinct state cells, so compare the actual slot storage.
(define (ctfe-node-pools-share-storage?
  [left : ast.AstNodePoolContext]
  [right : ast.AstNodePoolContext]) : bool
  (and
    (=
      (ast.ast-node-pool-context-expr-segment-bases (& left))
      (ast.ast-node-pool-context-expr-segment-bases (& right)))
    (=
      (ast.ast-node-pool-context-type-segment-bases (& left))
      (ast.ast-node-pool-context-type-segment-bases (& right)))))

(define (ctfe-env-adopt-captured-pools!
  [env : (& env CtfeEnv)]
  [captured : ast.AstNodePoolContext]) : unit
  (let
    [owner-address : u64 (ctfe-env-pools-address env)]
    [syntax-address : u64 (ctfe-env-syntax-pool-context-address-live env)]
    [captured-expr-cell-address : u64
      (ast.ast-pool-cell-data captured.expr-pool)]
    [captured-type-cell-address : u64
      (ast.ast-pool-cell-data captured.type-pool)]
    (begin
      (ast.ast-node-pool-context-adopt-newer-cells!
        (ctfe-pool-context-cell-address-at owner-address 0)
        (ctfe-pool-context-cell-address-at owner-address 1)
        captured-expr-cell-address
        captured-type-cell-address)
      (ast.ast-node-pool-context-adopt-newer-cells!
        (ctfe-pool-context-cell-address-at syntax-address 0)
        (ctfe-pool-context-cell-address-at syntax-address 1)
        captured-expr-cell-address
        captured-type-cell-address)
      (ctfe-env-publish-owning-pools! env))))

(define (ctfe-eval-unquote-expr
  [inner : ast.AstExpr]
  [origin : ast.AstExpr]
  [env : (& env CtfeEnv)]
  [fuel : i64]) : ResultCtfeQuoteExpr
  (match (compiler-ctfe-eval inner env fuel)
    [(ResultCtfe.Ok value next-fuel)
      (match value
        [(CompilerCtfeValue.Expr node ty)
          (begin
            (if (ast.ast-node-pool-has-active-context?)
              (let
                [active-pools : ast.AstNodePoolContext
                  (ast.ast-node-pool-context-active-live)]
                (if (ctfe-node-pools-share-storage?
                  active-pools
                  (ctfe-env-pools env))
                  (ctfe-env-adopt-captured-pools! env active-pools)
                  unit))
              unit)
            (ResultCtfeQuoteExpr.Ok node ty next-fuel))]
        [(CompilerCtfeValue.Type ty)
          (ResultCtfeQuoteExpr.Ok
            (ctfe-type-to-expr ty env)
            (ast.AstType.Expr)
            next-fuel)]
        [(CompilerCtfeValue.CapturedExpr node ty pools)
          (if (ctfe-node-pools-share-storage? pools (ctfe-env-pools env))
            (begin
              (ctfe-env-adopt-captured-pools! env pools)
              (ResultCtfeQuoteExpr.Ok node ty next-fuel))
            (ResultCtfeQuoteExpr.Err
              (box (ctfe-diagnostic-at-expr origin "unquote expects Expr"))))]
        [_
          (ResultCtfeQuoteExpr.Err
            (box (ctfe-diagnostic-at-expr origin "unquote expects Expr")))])]
    [(ResultCtfe.Err diag) (ResultCtfeQuoteExpr.Err diag)]))

(define (ctfe-eval-unquote-splice
  [inner : ast.AstExpr]
  [origin : ast.AstExpr]
  [env : (& env CtfeEnv)]
  [fuel : i64]) : ResultCtfeQuoteExprList
  (match (compiler-ctfe-eval inner env fuel)
    [(ResultCtfe.Ok value next-fuel)
      (match value
        [(CompilerCtfeValue.ExprList exprs)
          (ResultCtfeQuoteExprList.Ok exprs next-fuel)]
        [(CompilerCtfeValue.CapturedExprList exprs pools)
          (if (ctfe-node-pools-share-storage? pools (ctfe-env-pools env))
            (begin
              (ctfe-env-adopt-captured-pools! env pools)
              (ResultCtfeQuoteExprList.Ok exprs next-fuel))
            (ResultCtfeQuoteExprList.Err
              (box
                (ctfe-diagnostic-at-expr
                  origin
                  "unquote-splicing expects ExprList"))))]
        [_
          (ResultCtfeQuoteExprList.Err
            (box
              (ctfe-diagnostic-at-expr
                origin
                "unquote-splicing expects ExprList")))])]
    [(ResultCtfe.Err diag) (ResultCtfeQuoteExprList.Err diag)]))

(define (ctfe-type-name-id-to-type [name-id : i64]) : ast.AstType
  (cond
    [(= name-id (ctfe-builtin "i64")) (ast.AstType.I64)]
    [(= name-id (ctfe-builtin "i32")) (ast.AstType.I32)]
    [(= name-id (ctfe-builtin "i16")) (ast.AstType.I16)]
    [(= name-id (ctfe-builtin "i8")) (ast.AstType.I8)]
    [(= name-id (ctfe-builtin "u64")) (ast.AstType.U64)]
    [(= name-id (ctfe-builtin "u32")) (ast.AstType.U32)]
    [(= name-id (ctfe-builtin "u16")) (ast.AstType.U16)]
    [(= name-id (ctfe-builtin "u8")) (ast.AstType.U8)]
    [(= name-id (ctfe-builtin "f64")) (ast.AstType.F64)]
    [(= name-id (ctfe-builtin "f32")) (ast.AstType.F32)]
    [(= name-id (ctfe-builtin "bool")) (ast.AstType.Bool)]
    [(= name-id (ctfe-builtin "char")) (ast.AstType.Char)]
    [(= name-id (ctfe-builtin "String")) (ast.AstType.String)]
    [(= name-id (ctfe-builtin "str")) (ast.AstType.Str)]
    [(= name-id (ctfe-builtin "bytes")) (ast.AstType.Bytes)]
    [(= name-id (ctfe-builtin "unit")) (ast.AstType.Unit)]
    [(= name-id (ctfe-builtin "never")) (ast.AstType.Never)]
    [(= name-id cbi.compiler-builtin-id-fix-Expr) (ast.AstType.Expr)]
    [(= name-id cbi.compiler-builtin-id-fix-ExprList) (ast.AstType.ExprList)]
    [else (ast.AstType.Var name-id)]))

(define (ctfe-internal-resolved-struct-type-marker-id) : i64
  (ctfe-builtin "__typelisp internal resolved struct type"))

(define (ctfe-internal-resolved-enum-type-marker-id) : i64
  (ctfe-builtin "__typelisp internal resolved enum type"))

(define (ctfe-type-syntax-name-id [name : i64] [env : (& env CtfeEnv)]) : i64
  (ctfe-ast-push env (ast.AstExpr.Var name)))

(define (ctfe-type-syntax-call-id
  [name-id : i64]
  [args : ast.AstExprList]
  [env : (& env CtfeEnv)]) : i64
  (ctfe-ast-expr-call-with-provenance
    (ctfe-env-macro-state env)
    (ctfe-env-pools env)
    (ctfe-ast-push env (ast.AstExpr.Var name-id))
    args))

(define (ctfe-resolved-nominal-type-to-expr
  [marker-id : i64]
  [name-id : i64]
  [lifetimes : ast.AstLifetimeList]
  [env : (& env CtfeEnv)]) : i64
  (ctfe-type-syntax-call-id
    marker-id
    (ast.ast-expr-cons
      (ctfe-ast-push env (ast.AstExpr.Var name-id))
      (ctfe-lifetime-list-to-expr-list lifetimes env))
    env))

(define (ctfe-type-list-to-expr-list-at
  [types : (& types ast.AstTypeList)]
  [env : (& env CtfeEnv)]
  [index : i64]) : ast.AstExprList
  (if (>= index (ast.ast-type-list-len types))
    (ast.ast-expr-list-new)
    (ast.ast-expr-cons
      (ctfe-type-to-expr
        (ctfe-ty-get
          env
          (ast.ast-type-list-get types index (ast.ast-type-id-fallback)))
        env)
      (ctfe-type-list-to-expr-list-at types env (+ index 1)))))

(define (ctfe-type-list-to-expr-list
  [types : ast.AstTypeList]
  [env : (& env CtfeEnv)]) : ast.AstExprList
  (ctfe-type-list-to-expr-list-at (& types) env 0))

(define (ctfe-lifetime-list-to-expr-list
  [lifetimes : ast.AstLifetimeList]
  [env : (& env CtfeEnv)]) : ast.AstExprList
  (ctfe-lifetime-list-to-expr-list-at (& lifetimes) env 0))

(define (ctfe-lifetime-list-to-expr-list-at
  [lifetimes : (& lifetimes ast.AstLifetimeList)]
  [env : (& env CtfeEnv)]
  [index : i64]) : ast.AstExprList
  (if (>= index (ast.ast-lifetime-list-len lifetimes))
    (ast.ast-expr-list-new)
    (ast.ast-expr-cons
      (ctfe-type-syntax-name-id
        (ast.ast-lifetime-list-get lifetimes index (ast.ast-lifetime-fallback))
        env)
      (ctfe-lifetime-list-to-expr-list-at lifetimes env (+ index 1)))))

(define (ctfe-func-type-to-expr-list
  [args : ast.AstTypeList]
  [ret : ast.AstType]
  [env : (& env CtfeEnv)]) : ast.AstExprList
  (ctfe-func-type-to-expr-list-at (& args) ret env 0))

(define (ctfe-func-type-to-expr-list-at
  [args : (& args ast.AstTypeList)]
  [ret : ast.AstType]
  [env : (& env CtfeEnv)]
  [index : i64]) : ast.AstExprList
  (if (>= index (ast.ast-type-list-len args))
    (ast.ast-expr-cons (ctfe-type-to-expr ret env) (ast.ast-expr-list-new))
    (ast.ast-expr-cons
      (ctfe-type-to-expr
        (ctfe-ty-get
          env
          (ast.ast-type-list-get args index (ast.ast-type-id-fallback)))
        env)
      (ctfe-func-type-to-expr-list-at args ret env (+ index 1)))))

(define (ctfe-type-to-expr [ty : ast.AstType] [env : (& env CtfeEnv)]) : i64
  (match ty
    [(ast.AstType.I64) (ctfe-type-syntax-name-id (ctfe-builtin "i64") env)]
    [(ast.AstType.I32) (ctfe-type-syntax-name-id (ctfe-builtin "i32") env)]
    [(ast.AstType.I16) (ctfe-type-syntax-name-id (ctfe-builtin "i16") env)]
    [(ast.AstType.I8) (ctfe-type-syntax-name-id (ctfe-builtin "i8") env)]
    [(ast.AstType.U64) (ctfe-type-syntax-name-id (ctfe-builtin "u64") env)]
    [(ast.AstType.U32) (ctfe-type-syntax-name-id (ctfe-builtin "u32") env)]
    [(ast.AstType.U16) (ctfe-type-syntax-name-id (ctfe-builtin "u16") env)]
    [(ast.AstType.U8) (ctfe-type-syntax-name-id (ctfe-builtin "u8") env)]
    [(ast.AstType.F64) (ctfe-type-syntax-name-id (ctfe-builtin "f64") env)]
    [(ast.AstType.F32) (ctfe-type-syntax-name-id (ctfe-builtin "f32") env)]
    [(ast.AstType.Bool) (ctfe-type-syntax-name-id (ctfe-builtin "bool") env)]
    [(ast.AstType.Char) (ctfe-type-syntax-name-id (ctfe-builtin "char") env)]
    [(ast.AstType.String)
      (ctfe-type-syntax-name-id (ctfe-builtin "String") env)]
    [(ast.AstType.Str) (ctfe-type-syntax-name-id (ctfe-builtin "str") env)]
    [(ast.AstType.Bytes) (ctfe-type-syntax-name-id (ctfe-builtin "bytes") env)]
    [(ast.AstType.Unit) (ctfe-type-syntax-name-id (ctfe-builtin "unit") env)]
    [(ast.AstType.Never) (ctfe-type-syntax-name-id (ctfe-builtin "never") env)]
    [(ast.AstType.Expr)
      (ctfe-type-syntax-name-id cbi.compiler-builtin-id-fix-Expr env)]
    [(ast.AstType.ExprList)
      (ctfe-type-syntax-name-id cbi.compiler-builtin-id-fix-ExprList env)]
    [(ast.AstType.Func args ret)
      (ctfe-type-syntax-call-id
        (ctfe-builtin "->")
        (ctfe-func-type-to-expr-list (deref args) (ctfe-ty-get env ret) env)
        env)]
    [(ast.AstType.CFunc signature mode)
      (ctfe-type-syntax-call-id
        (ctfe-builtin "CFunc")
        (ast.ast-expr-cons
          (ctfe-type-syntax-name-id
            ;; The four mode spellings occupy consecutive slots in mode-key
            ;; order, starting at "nullable".
            (cbi.compiler-builtin-ctfe-ref
              (+
                (cbi.compiler-builtin-ctfe-slot "nullable")
                (ast.ast-c-function-mode-key mode)))
            env)
          (ast.ast-expr-cons
            (ctfe-type-to-expr (ctfe-ty-get env signature) env)
            (ast.ast-expr-list-new)))
        env)]
    [(ast.AstType.Tuple elems)
      (ctfe-type-syntax-call-id
        (ctfe-builtin "Tuple")
        (ctfe-type-list-to-expr-list (deref elems) env)
        env)]
    [(ast.AstType.Array elem count)
      (ctfe-type-syntax-call-id
        (ctfe-builtin "Array")
        (ast.ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          (ast.ast-expr-cons
            (ctfe-ast-push env (ast.AstExpr.Literal (ast.ast-lit-int count)))
            (ast.ast-expr-list-new)))
        env)]
    [(ast.AstType.DynArray elem)
      (ctfe-type-syntax-call-id
        (ctfe-builtin "__tl_dyn-array")
        (ast.ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          (ast.ast-expr-list-new))
        env)]
    [(ast.AstType.Slice elem)
      (ctfe-type-syntax-call-id
        cbi.compiler-builtin-id-comptime-type-info-slice-variant
        (ast.ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          (ast.ast-expr-list-new))
        env)]
    [(ast.AstType.Box elem)
      (ctfe-type-syntax-call-id
        cbi.compiler-builtin-id-fix-Box
        (ast.ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          (ast.ast-expr-list-new))
        env)]
    [(ast.AstType.Ptr elem)
      (ctfe-type-syntax-call-id
        (ctfe-builtin "Ptr")
        (ast.ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          (ast.ast-expr-list-new))
        env)]
    [(ast.AstType.MutPtr elem)
      (ctfe-type-syntax-call-id
        (ctfe-builtin "MutPtr")
        (ast.ast-expr-cons
          (ctfe-type-to-expr (ctfe-ty-get env elem) env)
          (ast.ast-expr-list-new))
        env)]
    [(ast.AstType.Ref region elem)
      (ctfe-type-syntax-call-id
        (ctfe-builtin "&")
        (ast.ast-expr-cons
          (ctfe-type-syntax-name-id region env)
          (ast.ast-expr-cons
            (ctfe-type-to-expr (ctfe-ty-get env elem) env)
            (ast.ast-expr-list-new)))
        env)]
    [(ast.AstType.MutRef region elem)
      (ctfe-type-syntax-call-id
        (ctfe-builtin "&mut")
        (ast.ast-expr-cons
          (ctfe-type-syntax-name-id region env)
          (ast.ast-expr-cons
            (ctfe-type-to-expr (ctfe-ty-get env elem) env)
            (ast.ast-expr-list-new)))
        env)]
    [(ast.AstType.Region region elem)
      (ctfe-type-syntax-call-id
        (ctfe-builtin "in")
        (ast.ast-expr-cons
          (ctfe-type-syntax-name-id region env)
          (ast.ast-expr-cons
            (ctfe-type-to-expr (ctfe-ty-get env elem) env)
            (ast.ast-expr-list-new)))
        env)]
    [(ast.AstType.Invalidate lifetime elem)
      (ctfe-type-syntax-call-id
        (cbi.compiler-builtin-ctfe ":invalidate")
        (ast.ast-expr-cons
          (ctfe-type-syntax-name-id lifetime env)
          (ast.ast-expr-cons
            (ctfe-type-to-expr (ctfe-ty-get env elem) env)
            (ast.ast-expr-list-new)))
        env)]
    [(ast.AstType.Enum name)
      (ctfe-resolved-nominal-type-to-expr
        (ctfe-internal-resolved-enum-type-marker-id)
        name
        (ast.ast-lifetime-list-new)
        env)]
    [(ast.AstType.EnumArgs name lifetimes)
      (ctfe-resolved-nominal-type-to-expr
        (ctfe-internal-resolved-enum-type-marker-id)
        name
        (deref lifetimes)
        env)]
    [(ast.AstType.Struct name)
      (ctfe-resolved-nominal-type-to-expr
        (ctfe-internal-resolved-struct-type-marker-id)
        name
        (ast.ast-lifetime-list-new)
        env)]
    [(ast.AstType.StructArgs name lifetimes)
      (ctfe-resolved-nominal-type-to-expr
        (ctfe-internal-resolved-struct-type-marker-id)
        name
        (deref lifetimes)
        env)]
    [(ast.AstType.Var name) (ctfe-type-syntax-name-id name env)]
    [(ast.AstType.VarArgs name lifetimes)
      (ctfe-type-syntax-call-id
        name
        (ctfe-lifetime-list-to-expr-list (deref lifetimes) env)
        env)]))

(define (ctfe-type-expr-error [origin : ast.AstExpr]) : ResultCtfeQuoteType
  (ResultCtfeQuoteType.Err
    (box
      (ctfe-diagnostic-at-expr origin "type unquote expects a type expression"))))

(define (ctfe-expr-list-to-type-list
  [exprs : ast.AstExprList]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteTypeList
  (ctfe-expr-list-to-type-list-at (& exprs) 0 origin env fuel))

(define (ctfe-expr-list-to-type-list-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteTypeList
  (if (>= index exprs.len)
    (ResultCtfeQuoteTypeList.Ok (ast.ast-type-list-new) fuel)
    (let
      [head-expr : ast.AstExpr
        (ctfe-ast-get env (ast.ast-expr-list-get exprs index 0))]
      (match (ctfe-expr-to-type head-expr (clone origin) env fuel)
        [(ResultCtfeQuoteType.Ok head-ty head-fuel)
          (match (ctfe-expr-list-to-type-list-at
            exprs
            (+ index 1)
            origin
            env
            head-fuel)
            [(ResultCtfeQuoteTypeList.Ok tail tail-fuel)
              (ResultCtfeQuoteTypeList.Ok
                (ast.ast-type-cons-with-pools (ctfe-env-pools env) head-ty tail)
                tail-fuel)]
            [(ResultCtfeQuoteTypeList.Err diag)
              (ResultCtfeQuoteTypeList.Err diag)])]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteTypeList.Err diag)]))))

(define (ctfe-expr-unary-type
  [name : i64]
  [args : ast.AstExprList]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (if (= args.len 1)
    (let
      [elem-expr : ast.AstExpr
        (ctfe-ast-get env (ast.ast-expr-list-get (& args) 0 0))]
      (match (ctfe-expr-to-type elem-expr (clone origin) env fuel)
        [(ResultCtfeQuoteType.Ok elem-ty next-fuel)
          (ResultCtfeQuoteType.Ok
            (cond
              [(or
                  (= name (ctfe-builtin "Array"))
                  (= name (ctfe-builtin "__tl_dyn-array")))
                (ast.ast-ty-dyn-array-with-pools (ctfe-env-pools env) elem-ty)]
              [(= name cbi.compiler-builtin-id-comptime-type-info-slice-variant)
                (ast.ast-ty-slice-with-pools (ctfe-env-pools env) elem-ty)]
              [(= name cbi.compiler-builtin-id-fix-Box)
                (ast.ast-ty-box-with-pools (ctfe-env-pools env) elem-ty)]
              [(= name (ctfe-builtin "Ptr"))
                (ast.ast-ty-ptr-with-pools (ctfe-env-pools env) elem-ty)]
              [(= name (ctfe-builtin "MutPtr"))
                (ast.ast-ty-mut-ptr-with-pools (ctfe-env-pools env) elem-ty)]
              [else elem-ty])
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)]))
    (ctfe-type-expr-error origin)))

(define (ctfe-expr-array-type
  [args : ast.AstExprList]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (if (or (= args.len 1) (= args.len 2))
    (let
      [elem-expr : ast.AstExpr
        (ctfe-ast-get env (ast.ast-expr-list-get (& args) 0 0))]
      (match (ctfe-expr-to-type elem-expr (clone origin) env fuel)
        [(ResultCtfeQuoteType.Ok elem-ty elem-fuel)
          (if (= args.len 1)
            (ResultCtfeQuoteType.Ok
              (ast.ast-ty-dyn-array-with-pools (ctfe-env-pools env) elem-ty)
              elem-fuel)
            (let
              [len-expr : ast.AstExpr
                (ctfe-ast-get env (ast.ast-expr-list-get (& args) 1 0))]
              (match (ctfe-expr-unspan env len-expr)
                [(ast.AstExpr.Literal (ast.AstLiteral.Int count text))
                  (ResultCtfeQuoteType.Ok
                    (ast.ast-ty-array-with-pools
                      (ctfe-env-pools env)
                      elem-ty
                      (ast.ast-int-literal-value-or-payload count text))
                    elem-fuel)]
                [_ (ctfe-type-expr-error origin)])))]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)]))
    (ctfe-type-expr-error origin)))

(define (ctfe-expr-func-type
  [args : ast.AstExprList]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (ctfe-expr-func-type-at (& args) 0 origin env fuel))

(define (ctfe-expr-func-type-at
  [args : (& args ast.AstExprList)]
  [index : i64]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (if (>= index args.len)
    (ctfe-type-expr-error origin)
    (let
      [head-expr : ast.AstExpr
        (ctfe-ast-get env (ast.ast-expr-list-get args index 0))]
      (if (= (+ index 1) args.len)
        (match (ctfe-expr-to-type head-expr origin env fuel)
          [(ResultCtfeQuoteType.Ok ret-ty next-fuel)
            (ResultCtfeQuoteType.Ok
              (ast.ast-ty-func-with-pools
                (ctfe-env-pools env)
                (ast.ast-type-list-new)
                ret-ty)
              next-fuel)]
          [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])
        (match (ctfe-expr-to-type head-expr (clone origin) env fuel)
          [(ResultCtfeQuoteType.Ok arg-ty arg-fuel)
            (match (ctfe-expr-func-type-at
              args
              (+ index 1)
              (clone origin)
              env
              arg-fuel)
              [(ResultCtfeQuoteType.Ok tail-fn next-fuel)
                (match tail-fn
                  [(ast.AstType.Func tail-args ret)
                    (ResultCtfeQuoteType.Ok
                      (ast.ast-ty-func-with-pools
                        (ctfe-env-pools env)
                        (ast.ast-type-cons-with-pools
                          (ctfe-env-pools env)
                          arg-ty
                          (deref tail-args))
                        (ctfe-ty-get env ret))
                      next-fuel)]
                  [_ (ctfe-type-expr-error origin)])]
              [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
          [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])))))

(defenum CtfeMaybeLifetimeSyntaxName
  (None)
  (Some i64))

(define (ctfe-lifetime-syntax-name [expr : ast.AstExpr]) : CtfeMaybeLifetimeSyntaxName
  (match expr
    [(ast.AstExpr.Var name) (CtfeMaybeLifetimeSyntaxName.Some name)]
    [(ast.AstExpr.Literal (ast.AstLiteral.String name-id))
      (CtfeMaybeLifetimeSyntaxName.Some name-id)]
    [_ (CtfeMaybeLifetimeSyntaxName.None)]))

(define (ctfe-expr-reference-type
  [args : ast.AstExprList]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [mutable : bool]) : ResultCtfeQuoteType
  (if (= args.len 2)
    (let
      [region-expr : ast.AstExpr
        (ctfe-ast-get env (ast.ast-expr-list-get (& args) 0 0))]
      [inner-expr : ast.AstExpr
        (ctfe-ast-get env (ast.ast-expr-list-get (& args) 1 0))]
      (match (ctfe-lifetime-syntax-name (ctfe-expr-unspan env region-expr))
        [(CtfeMaybeLifetimeSyntaxName.Some region)
          (match (ctfe-expr-to-type inner-expr origin env fuel)
            [(ResultCtfeQuoteType.Ok inner-ty next-fuel)
              (ResultCtfeQuoteType.Ok
                (if mutable
                  (ast.ast-ty-mut-ref-with-pools
                    (ctfe-env-pools env)
                    region
                    inner-ty)
                  (ast.ast-ty-ref-with-pools
                    (ctfe-env-pools env)
                    region
                    inner-ty))
                next-fuel)]
            [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
        [(CtfeMaybeLifetimeSyntaxName.None) (ctfe-type-expr-error origin)]))
    (ctfe-type-expr-error origin)))

(define (ctfe-expr-region-type
  [args : ast.AstExprList]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [invalidate? : bool]) : ResultCtfeQuoteType
  (if (= args.len 2)
    (let
      [region-expr : ast.AstExpr
        (ctfe-ast-get env (ast.ast-expr-list-get (& args) 0 0))]
      [inner-expr : ast.AstExpr
        (ctfe-ast-get env (ast.ast-expr-list-get (& args) 1 0))]
      (match (ctfe-lifetime-syntax-name (ctfe-expr-unspan env region-expr))
        [(CtfeMaybeLifetimeSyntaxName.Some region)
          (match (ctfe-expr-to-type inner-expr origin env fuel)
            [(ResultCtfeQuoteType.Ok inner-ty next-fuel)
              (ResultCtfeQuoteType.Ok
                (if invalidate?
                  (ast.ast-ty-invalidate-with-pools
                    (ctfe-env-pools env)
                    region
                    inner-ty)
                  (ast.ast-ty-region-with-pools
                    (ctfe-env-pools env)
                    region
                    inner-ty))
                next-fuel)]
            [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
        [(CtfeMaybeLifetimeSyntaxName.None) (ctfe-type-expr-error origin)]))
    (ctfe-type-expr-error origin)))

(define (ctfe-expr-list-to-lifetime-list
  [exprs : ast.AstExprList]
  [env : CtfeEnv]
  [origin : ast.AstExpr]) : ResultCtfeQuoteLifetimeList
  (ctfe-expr-list-to-lifetime-list-at (& exprs) 0 env origin))

(define (ctfe-expr-list-to-lifetime-list-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [env : CtfeEnv]
  [origin : ast.AstExpr]) : ResultCtfeQuoteLifetimeList
  (if (>= index exprs.len)
    (ResultCtfeQuoteLifetimeList.Ok (ast.ast-lifetime-list-new))
    (let
      [head-expr : ast.AstExpr
        (ctfe-ast-get env (ast.ast-expr-list-get exprs index 0))]
      (match (ctfe-lifetime-syntax-name (ctfe-expr-unspan env head-expr))
        [(CtfeMaybeLifetimeSyntaxName.Some name)
          (let
            [tail
              (try
                (ctfe-expr-list-to-lifetime-list-at
                  exprs
                  (+ index 1)
                  env
                  origin))]
            (ResultCtfeQuoteLifetimeList.Ok (ast.ast-lifetime-cons name tail)))]
        [(CtfeMaybeLifetimeSyntaxName.None)
          (ResultCtfeQuoteLifetimeList.Err
            (box
              (ctfe-diagnostic-at-expr
                origin
                "type unquote expects a type expression")))]))))

(define (ctfe-expr-resolved-nominal-type
  [args : ast.AstExprList]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [is-struct : bool]) : ResultCtfeQuoteType
  (if (> args.len 0)
    (let
      [name-expr : ast.AstExpr
        (ctfe-ast-get env (ast.ast-expr-list-get (& args) 0 0))]
      [lifetime-exprs : ast.AstExprList
        (ast.ast-expr-list-tail-from-ref (& args) 1)]
      (match (ctfe-expr-unspan env name-expr)
        [(ast.AstExpr.Var name-id)
          (let
            [lifetimes
              (try (ctfe-expr-list-to-lifetime-list lifetime-exprs env origin))]
            (ResultCtfeQuoteType.Ok
              (if is-struct
                (if (ast.ast-lifetime-list-empty? (& lifetimes))
                  (ast.AstType.Struct name-id)
                  (ast.ast-ty-struct-args name-id lifetimes))
                (if (ast.ast-lifetime-list-empty? (& lifetimes))
                  (ast.AstType.Enum name-id)
                  (ast.ast-ty-enum-args name-id lifetimes)))
              fuel))]
        [_ (ctfe-type-expr-error origin)]))
    (ctfe-type-expr-error origin)))

(define (ctfe-expr-c-function-type
  [args : ast.AstExprList]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (if (= args.len 2)
    (let
      [mode-expr : ast.AstExpr
        (ctfe-expr-unspan
          env
          (ctfe-ast-get env (ast.ast-expr-list-get (& args) 0 0)))]
      [mode : i64
        (match mode-expr
          [(ast.AstExpr.Var name)
            (cond
              [(= name (ctfe-builtin "nullable")) 0]
              [(= name (ctfe-builtin "non-null")) 1]
              [(= name (ctfe-builtin "unsafe-nullable")) 2]
              [(= name (ctfe-builtin "unsafe-non-null")) 3]
              [else -1])]
          [_ -1])]
      (if (< mode 0)
        (ctfe-type-expr-error origin)
        (match (ctfe-expr-to-type
          (ctfe-ast-get env (ast.ast-expr-list-get (& args) 1 0))
          (clone origin)
          env
          fuel)
          [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)]
          [(ResultCtfeQuoteType.Ok shape next-fuel)
            (match shape
              [(ast.AstType.Func params result)
                (ResultCtfeQuoteType.Ok
                  (ast.AstType.CFunc
                    (ast.ast-node-pool-context-type-push
                      (ctfe-env-pools env)
                      (ast.AstType.Func params result))
                    (cond
                      [(= mode 0) ast.AstCFunctionMode.Nullable]
                      [(= mode 1) ast.AstCFunctionMode.NonNull]
                      [(= mode 2) ast.AstCFunctionMode.UnsafeNullable]
                      [else ast.AstCFunctionMode.UnsafeNonNull]))
                  next-fuel)]
              [_ (ctfe-type-expr-error origin)])])))
    (ctfe-type-expr-error origin)))

(define (ctfe-expr-to-type
  [expr : ast.AstExpr]
  [origin : ast.AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteType
  (match (ctfe-expr-unspan env expr)
    [(ast.AstExpr.TypeLiteral ty-id)
      (ResultCtfeQuoteType.Ok (ctfe-ty-get env ty-id) fuel)]
    [(ast.AstExpr.Var name)
      (ResultCtfeQuoteType.Ok (ctfe-type-name-id-to-type name) fuel)]
    [(ast.AstExpr.Call func-box args)
      (let
        [func : ast.AstExpr (ctfe-ast-get env func-box)]
        (match (ctfe-expr-unspan env func)
          [(ast.AstExpr.Var name)
            (cond
              [(= name (ctfe-internal-resolved-struct-type-marker-id))
                (ctfe-expr-resolved-nominal-type args origin env fuel true)]
              [(= name (ctfe-internal-resolved-enum-type-marker-id))
                (ctfe-expr-resolved-nominal-type args origin env fuel false)]
              [(= name (ctfe-builtin "->"))
                (ctfe-expr-func-type args origin env fuel)]
              [(= name (ctfe-builtin "CFunc"))
                (ctfe-expr-c-function-type args origin env fuel)]
              [(= name (ctfe-builtin "Array"))
                (ctfe-expr-array-type args origin env fuel)]
              [(or
                  (= name (ctfe-builtin "__tl_dyn-array"))
                  (=
                    name
                    cbi.compiler-builtin-id-comptime-type-info-slice-variant)
                  (= name cbi.compiler-builtin-id-fix-Box)
                  (= name (ctfe-builtin "Ptr"))
                  (= name (ctfe-builtin "MutPtr")))
                (ctfe-expr-unary-type name args origin env fuel)]
              [(= name (ctfe-builtin "&"))
                (ctfe-expr-reference-type args origin env fuel false)]
              [(= name (ctfe-builtin "&mut"))
                (ctfe-expr-reference-type args origin env fuel true)]
              [(= name (ctfe-builtin "in"))
                (ctfe-expr-region-type args origin env fuel false)]
              [(= name (cbi.compiler-builtin-ctfe ":invalidate"))
                (ctfe-expr-region-type args origin env fuel true)]
              [(= name (ctfe-builtin "Tuple"))
                (match (ctfe-expr-list-to-type-list args origin env fuel)
                  [(ResultCtfeQuoteTypeList.Ok elems next-fuel)
                    (ResultCtfeQuoteType.Ok (ast.ast-ty-tuple elems) next-fuel)]
                  [(ResultCtfeQuoteTypeList.Err diag)
                    (ResultCtfeQuoteType.Err diag)])]
              [else (ctfe-type-expr-error origin)])]
          [_ (ctfe-type-expr-error origin)]))]
    [_ (ctfe-type-expr-error origin)]))

(define (ctfe-quote-type-unquote
  [lifetimes : ast.AstLifetimeList]
  [env : (& env CtfeEnv)]
  [origin : ast.AstExpr]
  [fuel : i64]) : ResultCtfeQuoteType
  (if (= (ast.ast-lifetime-list-len (& lifetimes)) 1)
    (let
      [name : i64
        (ast.ast-lifetime-list-get (& lifetimes) 0 (ast.ast-lifetime-fallback))]
      (match (ctfe-env-lookup-id env name)
        [(CtfeMaybeValue.Some value)
          (match value
            [(CompilerCtfeValue.Type ty) (ResultCtfeQuoteType.Ok ty fuel)]
            [(CompilerCtfeValue.Expr node _)
              (let
                [node-expr : ast.AstExpr (ctfe-ast-get env node)]
                (ctfe-expr-to-type
                  node-expr
                  origin
                  (ctfe-env-shared-view env)
                  fuel))]
            [(CompilerCtfeValue.CapturedExpr node _ pools)
              (ctfe-expr-to-type
                (ast.ast-node-pool-context-expr-get pools node)
                origin
                (ctfe-env-rebase-pools (ctfe-env-shared-view env) pools)
                fuel)]
            [_
              (ResultCtfeQuoteType.Err
                (box
                  (ctfe-diagnostic-at-expr
                    origin
                    (cdiag.compiler-diagnostic-typecheck-tagged
                      (cdiag.CompilerTypecheckKind.TypeMismatch)
                      "type unquote expects a type value"))))])]
        [(CtfeMaybeValue.None)
          (ResultCtfeQuoteType.Err
            (box
              (ctfe-diagnostic-at-expr
                origin
                "type unquote references an unbound type parameter")))]))
    (if (= (ast.ast-lifetime-list-len (& lifetimes)) 0)
      (ctfe-type-expr-error origin)
      (ResultCtfeQuoteType.Err
        (box
          (ctfe-diagnostic-at-expr
            origin
            (cdiag.compiler-diagnostic-typecheck-tagged
              (cdiag.CompilerTypecheckKind.ArityMismatch)
              "type unquote expects exactly one type parameter")))))))

(define (ctfe-quote-type-var [name : i64] [env : (& env CtfeEnv)] [fuel : i64]) : ResultCtfeQuoteType
  (match (ctfe-env-lookup-id env name)
    [(CtfeMaybeValue.Some value)
      (match value
        [(CompilerCtfeValue.Type ty) (ResultCtfeQuoteType.Ok ty fuel)]
        [_ (ResultCtfeQuoteType.Ok (ast.AstType.Var name) fuel)])]
    [(CtfeMaybeValue.None) (ResultCtfeQuoteType.Ok (ast.AstType.Var name) fuel)]))

(define (ctfe-quote-type-list
  [types : ast.AstTypeList]
  [env : (& env CtfeEnv)]
  [origin : ast.AstExpr]
  [fuel : i64]) : ResultCtfeQuoteTypeList
  (ctfe-quote-type-list-at (& types) env origin fuel 0))

(define (ctfe-quote-type-list-at
  [types : (& types ast.AstTypeList)]
  [env : (& env CtfeEnv)]
  [origin : ast.AstExpr]
  [fuel : i64]
  [index : i64]) : ResultCtfeQuoteTypeList
  (if (>= index (ast.ast-type-list-len types))
    (ResultCtfeQuoteTypeList.Ok (ast.ast-type-list-new) fuel)
    (let
      [head : ast.AstType
        (ctfe-ty-get
          env
          (ast.ast-type-list-get types index (ast.ast-type-id-fallback)))]
      (match (ctfe-quote-type head env (clone origin) fuel)
        [(ResultCtfeQuoteType.Ok quoted-head head-fuel)
          (match (ctfe-quote-type-list-at
            types
            env
            origin
            head-fuel
            (+ index 1))
            [(ResultCtfeQuoteTypeList.Ok quoted-rest rest-fuel)
              (ResultCtfeQuoteTypeList.Ok
                (ast.ast-type-cons-with-pools
                  (ctfe-env-pools env)
                  quoted-head
                  quoted-rest)
                rest-fuel)]
            [(ResultCtfeQuoteTypeList.Err diag)
              (ResultCtfeQuoteTypeList.Err diag)])]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteTypeList.Err diag)]))))

(define (ctfe-quote-type
  [ty : ast.AstType]
  [env : (& env CtfeEnv)]
  [origin : ast.AstExpr]
  [fuel : i64]) : ResultCtfeQuoteType
  (match (clone ty)
    [(ast.AstType.Func args ret)
      (match (ctfe-quote-type-list (deref args) env (clone origin) fuel)
        [(ResultCtfeQuoteTypeList.Ok quoted-args args-fuel)
          (match (ctfe-quote-type (ctfe-ty-get env ret) env origin args-fuel)
            [(ResultCtfeQuoteType.Ok quoted-ret ret-fuel)
              (ResultCtfeQuoteType.Ok
                (ast.ast-ty-func-with-pools
                  (ctfe-env-pools env)
                  quoted-args
                  quoted-ret)
                ret-fuel)]
            [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
        [(ResultCtfeQuoteTypeList.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(ast.AstType.Tuple elems)
      (match (ctfe-quote-type-list (deref elems) env origin fuel)
        [(ResultCtfeQuoteTypeList.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok (ast.ast-ty-tuple quoted) next-fuel)]
        [(ResultCtfeQuoteTypeList.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(ast.AstType.Array elem count)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast.ast-ty-array-with-pools (ctfe-env-pools env) quoted count)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(ast.AstType.DynArray elem)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast.ast-ty-dyn-array-with-pools (ctfe-env-pools env) quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(ast.AstType.Slice elem)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast.ast-ty-slice-with-pools (ctfe-env-pools env) quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(ast.AstType.Box elem)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast.ast-ty-box-with-pools (ctfe-env-pools env) quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(ast.AstType.CFunc signature mode)
      (match (ctfe-quote-type (ctfe-ty-get env signature) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast.AstType.CFunc
              (ast.ast-node-pool-context-type-push (ctfe-env-pools env) quoted)
              mode)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(ast.AstType.Ptr elem)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast.ast-ty-ptr-with-pools (ctfe-env-pools env) quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(ast.AstType.MutPtr elem)
      (match (ctfe-quote-type (ctfe-ty-get env elem) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast.ast-ty-mut-ptr-with-pools (ctfe-env-pools env) quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(ast.AstType.Ref region inner)
      (match (ctfe-quote-type (ctfe-ty-get env inner) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast.ast-ty-ref-with-pools (ctfe-env-pools env) region quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(ast.AstType.MutRef region inner)
      (match (ctfe-quote-type (ctfe-ty-get env inner) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast.ast-ty-mut-ref-with-pools (ctfe-env-pools env) region quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(ast.AstType.Region region inner)
      (match (ctfe-quote-type (ctfe-ty-get env inner) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast.ast-ty-region-with-pools (ctfe-env-pools env) region quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(ast.AstType.Invalidate lifetime inner)
      (match (ctfe-quote-type (ctfe-ty-get env inner) env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteType.Ok
            (ast.ast-ty-invalidate-with-pools
              (ctfe-env-pools env)
              lifetime
              quoted)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteType.Err diag)])]
    [(ast.AstType.VarArgs name lifetimes)
      (if (= name cbi.compiler-builtin-id-fix-unquote)
        (ctfe-quote-type-unquote (deref lifetimes) env origin fuel)
        (ResultCtfeQuoteType.Ok ty fuel))]
    [(ast.AstType.Var name) (ctfe-quote-type-var name env fuel)]
    [_ (ResultCtfeQuoteType.Ok ty fuel)]))

(define (ctfe-quote-maybe-type
  [maybe-ty : ast.AstMaybeType]
  [env : (& env CtfeEnv)]
  [origin : ast.AstExpr]
  [fuel : i64]) : ResultCtfeQuoteMaybeType
  (match maybe-ty
    [(ast.AstMaybeType.No)
      (ResultCtfeQuoteMaybeType.Ok ast.AstMaybeType.No fuel)]
    [(ast.AstMaybeType.Some ty)
      (match (ctfe-quote-type ty env origin fuel)
        [(ResultCtfeQuoteType.Ok quoted next-fuel)
          (ResultCtfeQuoteMaybeType.Ok (ast.AstMaybeType.Some quoted) next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteMaybeType.Err diag)])]))

(define (ctfe-quote-expr-list
  [exprs : ast.AstExprList]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteExprList
  (ctfe-quote-expr-list-at (& exprs) 0 env fuel quasiquote))

(define (ctfe-quote-expr-list-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteExprList
  (if (>= index exprs.len)
    (ResultCtfeQuoteExprList.Ok (ast.ast-expr-list-new) fuel)
    (let
      [head : ast.AstExpr
        (ctfe-ast-get env (ast.ast-expr-list-get exprs index 0))]
      (match (ctfe-expr-unspan env (clone head))
        [(ast.AstExpr.UnquoteSplicing inner-box)
          (let
            [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
            (if quasiquote
              (match (ctfe-eval-unquote-splice inner head env fuel)
                [(ResultCtfeQuoteExprList.Ok splice splice-fuel)
                  (match (ctfe-quote-expr-list-at
                    exprs
                    (+ index 1)
                    env
                    splice-fuel
                    quasiquote)
                    [(ResultCtfeQuoteExprList.Ok quoted-rest rest-fuel)
                      (ResultCtfeQuoteExprList.Ok
                        (ctfe-expr-list-append splice quoted-rest)
                        rest-fuel)]
                    [(ResultCtfeQuoteExprList.Err diag)
                      (ResultCtfeQuoteExprList.Err diag)])]
                [(ResultCtfeQuoteExprList.Err diag)
                  (ResultCtfeQuoteExprList.Err diag)])
              (match (ctfe-quote-expr head env fuel quasiquote)
                [(ResultCtfeQuoteExpr.Ok quoted-head _ head-fuel)
                  (match (ctfe-quote-expr-list-at
                    exprs
                    (+ index 1)
                    env
                    head-fuel
                    quasiquote)
                    [(ResultCtfeQuoteExprList.Ok quoted-rest rest-fuel)
                      (ResultCtfeQuoteExprList.Ok
                        (ast.ast-expr-cons quoted-head quoted-rest)
                        rest-fuel)]
                    [(ResultCtfeQuoteExprList.Err diag)
                      (ResultCtfeQuoteExprList.Err diag)])]
                [(ResultCtfeQuoteExpr.Err diag)
                  (ResultCtfeQuoteExprList.Err diag)])))]
        [_
          (match (ctfe-quote-expr head env fuel quasiquote)
            [(ResultCtfeQuoteExpr.Ok quoted-head _ head-fuel)
              (match (ctfe-quote-expr-list-at
                exprs
                (+ index 1)
                env
                head-fuel
                quasiquote)
                [(ResultCtfeQuoteExprList.Ok quoted-rest rest-fuel)
                  (ResultCtfeQuoteExprList.Ok
                    (ast.ast-expr-cons quoted-head quoted-rest)
                    rest-fuel)]
                [(ResultCtfeQuoteExprList.Err diag)
                  (ResultCtfeQuoteExprList.Err diag)])]
            [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExprList.Err diag)])]))))

(define (ctfe-quote-param-list
  [params : ast.AstParamList]
  [env : (& env CtfeEnv)]
  [origin : ast.AstExpr]
  [fuel : i64]) : ResultCtfeQuoteParams
  (let
    [out : ast.AstParamList
      (ast.ast-param-list-with-capacity (ast.ast-param-list-len (& params)))]
    [out-fuel
      (try (ctfe-quote-param-list-into (& params) 0 env origin fuel (&mut out)))]
    (ResultCtfeQuoteParams.Ok out out-fuel)))

(define (ctfe-quote-param-list-into
  [params : (& params ast.AstParamList)]
  [index : i64]
  [env : (& env CtfeEnv)]
  [origin : ast.AstExpr]
  [fuel : i64]
  [out : (&mut out ast.AstParamList)]) : ResultCtfeQuoteParamsBuild
  (if (>= index (ast.ast-param-list-len params))
    (ResultCtfeQuoteParamsBuild.Ok fuel)
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param name ty comptime?)
        (match (ctfe-quote-type ty env (clone origin) fuel)
          [(ResultCtfeQuoteType.Ok quoted-ty next-fuel)
            (begin
              (ast.ast-param-list-push
                out
                (ast.AstParam.Param
                  (ctfe-quote-name-id env name)
                  quoted-ty
                  comptime?))
              (ctfe-quote-param-list-into
                params
                (+ index 1)
                env
                origin
                next-fuel
                out))]
          [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteParamsBuild.Err diag)])])))

(define (ctfe-quote-pattern-list
  [patterns : ast.AstPatternList]
  [env : (& env CtfeEnv)]) : ast.AstPatternList
  (let
    [out : ast.AstPatternList (ast.ast-pattern-list-with-capacity patterns.len)]
    (begin
      (ctfe-quote-pattern-list-into (& patterns) 0 env (&mut out))
      out)))

(define (ctfe-quote-pattern-list-into
  [patterns : (& patterns ast.AstPatternList)]
  [index : i64]
  [env : (& env CtfeEnv)]
  [out : (&mut out ast.AstPatternList)]) : unit
  (if (>= index patterns.len)
    unit
    (begin
      (ast.ast-pattern-list-push
        out
        (ctfe-quote-pattern
          (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback))
          env))
      (ctfe-quote-pattern-list-into patterns (+ index 1) env out))))

(define (ctfe-quote-pattern [pattern : ast.AstPattern] [env : (& env CtfeEnv)]) : ast.AstPattern
  (match pattern
    [(ast.AstPattern.Var name maybe-ty)
      (ast.AstPattern.Var (ctfe-quote-name-id env name) maybe-ty)]
    [(ast.AstPattern.Tuple patterns-box)
      (let
        [patterns : ast.AstPatternList (deref patterns-box)]
        (ast.ast-pat-tuple (ctfe-quote-pattern-list patterns env)))]
    [(ast.AstPattern.Array patterns-box)
      (let
        [patterns : ast.AstPatternList (deref patterns-box)]
        (ast.ast-pat-array (ctfe-quote-pattern-list patterns env)))]
    [(ast.AstPattern.Slice items-box has-rest)
      (let
        [items : ast.AstPatternList (deref items-box)]
        (ast.ast-pat-slice (ctfe-quote-pattern-list items env) has-rest))]
    [(ast.AstPattern.Wildcard) ast.AstPattern.Wildcard]
    [(ast.AstPattern.Binding name)
      (ast.AstPattern.Binding (ctfe-quote-name-id env name))]
    [(ast.AstPattern.Variant name args-box)
      (let
        [args : ast.AstPatternList (deref args-box)]
        (ast.ast-pat-variant-id
          (ctfe-quote-name-id env name)
          (ctfe-quote-pattern-list args env)))]
    [(ast.AstPattern.Literal lit) (ast.AstPattern.Literal lit)]))

(define (ctfe-quote-let-binding-list
  [bindings : ast.AstLetBindingList]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteLetBindings
  (let
    [out : ast.AstLetBindingList
      (ast.ast-let-binding-list-with-capacity
        (ast.ast-let-binding-list-len (& bindings)))]
    [out-fuel
      (try
        (ctfe-quote-let-binding-list-into
          (& bindings)
          0
          env
          fuel
          quasiquote
          (&mut out)))]
    (ResultCtfeQuoteLetBindings.Ok out out-fuel)))

(define (ctfe-quote-let-binding-list-into
  [bindings : (& bindings ast.AstLetBindingList)]
  [index : i64]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [quasiquote : bool]
  [out : (&mut out ast.AstLetBindingList)]) : ResultCtfeQuoteLetBindingsBuild
  (if (>= index (ast.ast-let-binding-list-len bindings))
    (ResultCtfeQuoteLetBindingsBuild.Ok fuel)
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name maybe-ty init-box)
        (let
          [init : ast.AstExpr (ctfe-ast-get env init-box)]
          (match (ctfe-quote-maybe-type maybe-ty env (clone init) fuel)
            [(ResultCtfeQuoteMaybeType.Ok quoted-ty type-fuel)
              (match (ctfe-quote-expr init env type-fuel quasiquote)
                [(ResultCtfeQuoteExpr.Ok quoted-init _ init-fuel)
                  (begin
                    (ast.ast-let-binding-list-push
                      out
                      (ast.ast-let-binding-id
                        (ctfe-quote-name-id env name)
                        quoted-ty
                        quoted-init))
                    (ctfe-quote-let-binding-list-into
                      bindings
                      (+ index 1)
                      env
                      init-fuel
                      quasiquote
                      out))]
                [(ResultCtfeQuoteExpr.Err diag)
                  (ResultCtfeQuoteLetBindingsBuild.Err diag)])]
            [(ResultCtfeQuoteMaybeType.Err diag)
              (ResultCtfeQuoteLetBindingsBuild.Err diag)]))])))

(define (ctfe-quote-resource-binding-list
  [bindings : ast.AstResourceBindingList]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteResourceBindings
  (let
    [out : ast.AstResourceBindingList
      (ast.ast-resource-binding-list-with-capacity
        (ast.ast-resource-binding-list-len (& bindings)))]
    [out-fuel
      (try
        (ctfe-quote-resource-binding-list-into
          (& bindings)
          0
          env
          fuel
          quasiquote
          (&mut out)))]
    (ResultCtfeQuoteResourceBindings.Ok out out-fuel)))

(define (ctfe-quote-resource-binding-list-into
  [bindings : (& bindings ast.AstResourceBindingList)]
  [index : i64]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [quasiquote : bool]
  [out : (&mut out ast.AstResourceBindingList)]) : ResultCtfeQuoteResourceBindingsBuild
  (if (>= index (ast.ast-resource-binding-list-len bindings))
    (ResultCtfeQuoteResourceBindingsBuild.Ok fuel)
    (match (ast.ast-resource-binding-list-get
      bindings
      index
      (ast.ast-resource-binding-fallback))
      [(ast.AstResourceBinding.Binding name init-box cleanup-box move-aware?)
        (let
          [init : ast.AstExpr (ctfe-ast-get env init-box)]
          [cleanup : ast.AstExpr (ctfe-ast-get env cleanup-box)]
          (match (ctfe-quote-expr init env fuel quasiquote)
            [(ResultCtfeQuoteExpr.Ok quoted-init _ init-fuel)
              (match (ctfe-quote-expr cleanup env init-fuel quasiquote)
                [(ResultCtfeQuoteExpr.Ok quoted-cleanup _ cleanup-fuel)
                  (begin
                    (ast.ast-resource-binding-list-push
                      out
                      (ast.AstResourceBinding.Binding
                        (ctfe-quote-name-id env name)
                        quoted-init
                        quoted-cleanup
                        move-aware?))
                    (ctfe-quote-resource-binding-list-into
                      bindings
                      (+ index 1)
                      env
                      cleanup-fuel
                      quasiquote
                      out))]
                [(ResultCtfeQuoteExpr.Err diag)
                  (ResultCtfeQuoteResourceBindingsBuild.Err diag)])]
            [(ResultCtfeQuoteExpr.Err diag)
              (ResultCtfeQuoteResourceBindingsBuild.Err diag)]))])))

(define (ctfe-quote-arm-list
  [arms : ast.AstMatchArmList]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteArms
  (let
    [out : ast.AstMatchArmList (ast.ast-match-arm-list-with-capacity arms.len)]
    [out-fuel
      (try (ctfe-quote-arm-list-into (& arms) 0 env fuel quasiquote (&mut out)))]
    (ResultCtfeQuoteArms.Ok out out-fuel)))

(define (ctfe-quote-arm-list-into
  [arms : (& arms ast.AstMatchArmList)]
  [index : i64]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [quasiquote : bool]
  [out : (&mut out ast.AstMatchArmList)]) : ResultCtfeQuoteArmsBuild
  (if (>= index arms.len)
    (ResultCtfeQuoteArmsBuild.Ok fuel)
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm pattern body-box)
        (let
          [body : ast.AstExpr (ctfe-ast-get env body-box)]
          (match (ctfe-quote-expr body env fuel quasiquote)
            [(ResultCtfeQuoteExpr.Ok quoted-body _ body-fuel)
              (begin
                (ast.ast-match-arm-list-push
                  out
                  (ast.ast-match-arm
                    (ctfe-quote-pattern pattern env)
                    quoted-body))
                (ctfe-quote-arm-list-into
                  arms
                  (+ index 1)
                  env
                  body-fuel
                  quasiquote
                  out))]
            [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteArmsBuild.Err diag)]))])))

(define (ctfe-quote-preserve-unquoted-source-span?
  [template : ast.AstExpr]
  [result-node : i64]
  [env : (& env CtfeEnv)]) : bool
  (match (ctfe-expr-unspan env template)
    [(ast.AstExpr.Unquote _)
      (match (ctfe-ast-get env result-node)
        [(ast.AstExpr.Spanned _ _) true]
        [_ false])]
    [_ false]))

(define (ctfe-for-owned-state-exprs
  [source-name : i64]
  [index-name : i64]
  [source : i64]
  [body : i64]) : ast.AstExprList
  (let
    [out : ast.AstExprList (ast.ast-expr-list-with-capacity 4)]
    (begin
      (ast.ast-expr-list-push (&mut out) source-name)
      (ast.ast-expr-list-push (&mut out) index-name)
      (ast.ast-expr-list-push (&mut out) source)
      (ast.ast-expr-list-push (&mut out) body)
      out)))

(define (ctfe-for-owned-step-exprs
  [source-name : i64]
  [index-name : i64]
  [binding-name : i64]
  [expected-type : i64]
  [done-name : i64]
  [body : i64]) : ast.AstExprList
  (let
    [out : ast.AstExprList (ast.ast-expr-list-with-capacity 6)]
    (begin
      (ast.ast-expr-list-push (&mut out) source-name)
      (ast.ast-expr-list-push (&mut out) index-name)
      (ast.ast-expr-list-push (&mut out) binding-name)
      (if (>= expected-type 0)
        (ast.ast-expr-list-push (&mut out) expected-type)
        unit)
      (ast.ast-expr-list-push (&mut out) done-name)
      (ast.ast-expr-list-push (&mut out) body)
      out)))

;; Quote an arm's child expressions in payload order, threading the fuel, and
;; build the quoted node with `builder`: the pools, the `pre` arguments, then
;; the quoted children. The children are read before any is quoted and the
;; first error is the result, exactly as the hand-written arms did.
(defmacro (ctfe-quote-children-1
  [env : Expr]
  [fuel : Expr]
  [quasiquote : Expr]
  [builder : Expr]
  [a : Expr]
  [pre : Expr ...]) : Expr
  `(let
    [a-node : ast.AstExpr (ctfe-ast-get ,env ,a)]
    (match (ctfe-quote-expr a-node ,env ,fuel ,quasiquote)
      [(ResultCtfeQuoteExpr.Ok quoted-a _ a-fuel)
        (ResultCtfeQuoteExpr.Ok
          (,builder (ctfe-env-pools ,env) ,@pre quoted-a)
          (ast.AstType.Expr)
          a-fuel)]
      [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])))

(defmacro (ctfe-quote-children-2
  [env : Expr]
  [fuel : Expr]
  [quasiquote : Expr]
  [builder : Expr]
  [a : Expr]
  [b : Expr]
  [pre : Expr ...]) : Expr
  `(let
    [a-node : ast.AstExpr (ctfe-ast-get ,env ,a)]
    [b-node : ast.AstExpr (ctfe-ast-get ,env ,b)]
    (match (ctfe-quote-expr a-node ,env ,fuel ,quasiquote)
      [(ResultCtfeQuoteExpr.Ok quoted-a _ a-fuel)
        (match (ctfe-quote-expr b-node ,env a-fuel ,quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-b _ b-fuel)
            (ResultCtfeQuoteExpr.Ok
              (,builder (ctfe-env-pools ,env) ,@pre quoted-a quoted-b)
              (ast.AstType.Expr)
              b-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
      [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])))

(defmacro (ctfe-quote-children-3
  [env : Expr]
  [fuel : Expr]
  [quasiquote : Expr]
  [builder : Expr]
  [a : Expr]
  [b : Expr]
  [c : Expr]
  [pre : Expr ...]) : Expr
  `(let
    [a-node : ast.AstExpr (ctfe-ast-get ,env ,a)]
    [b-node : ast.AstExpr (ctfe-ast-get ,env ,b)]
    [c-node : ast.AstExpr (ctfe-ast-get ,env ,c)]
    (match (ctfe-quote-expr a-node ,env ,fuel ,quasiquote)
      [(ResultCtfeQuoteExpr.Ok quoted-a _ a-fuel)
        (match (ctfe-quote-expr b-node ,env a-fuel ,quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-b _ b-fuel)
            (match (ctfe-quote-expr c-node ,env b-fuel ,quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-c _ c-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (,builder
                    (ctfe-env-pools ,env)
                    ,@pre
                    quoted-a
                    quoted-b
                    quoted-c)
                  (ast.AstType.Expr)
                  c-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
      [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])))

;; The same for an arm whose only child is an expression list.
(defmacro (ctfe-quote-items
  [env : Expr]
  [fuel : Expr]
  [quasiquote : Expr]
  [builder : Expr]
  [items : Expr]
  [pre : Expr ...]) : Expr
  `(match (ctfe-quote-expr-list ,items ,env ,fuel ,quasiquote)
    [(ResultCtfeQuoteExprList.Ok quoted-items items-fuel)
      (ResultCtfeQuoteExpr.Ok
        (,builder (ctfe-env-pools ,env) ,@pre quoted-items)
        (ast.AstType.Expr)
        items-fuel)]
    [(ResultCtfeQuoteExprList.Err diag) (ResultCtfeQuoteExpr.Err diag)]))

(defmacro (ctfe-pools-push-variant
  [pools : Expr]
  [variant : Expr]
  [items : Expr]) : Expr
  `(ast.ast-node-pool-context-expr-push ,pools (,variant ,items)))

(define (ctfe-quote-expr
  [expr : ast.AstExpr]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteExpr
  (match (clone expr)
    [(ast.AstExpr.Spanned inner-box span)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr (clone inner) env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok node ty next-fuel)
            ;; An unquoted macro argument is already source-spanned at its
            ;; call site. Preserve that origin rather than covering it with
            ;; the template's quasiquote span, while retaining the template
            ;; span for synthetic expressions with no caller origin.
            (if (and
              quasiquote
              (ctfe-quote-preserve-unquoted-source-span? inner node env))
              (ResultCtfeQuoteExpr.Ok node ty next-fuel)
              (ResultCtfeQuoteExpr.Ok
                ;; The pool records this as canonical when `node` has no source
                ;; owner, or as a sparse ReSpan when a template view genuinely
                ;; differs. The unquoted branch above never manufactures that
                ;; alternate view: caller syntax keeps caller provenance.
                (ast.ast-expr-source-view-with-pools
                  (ctfe-env-pools env)
                  node
                  span)
                ty
                next-fuel))]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.MacroExpansion inner-box provenance-id macro-name-id)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok node ty next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ctfe-ast-push
                env
                (ast.AstExpr.MacroExpansion node provenance-id macro-name-id))
              ty
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.Literal lit)
      (ResultCtfeQuoteExpr.Ok
        (ctfe-ast-push env expr)
        (ctfe-quote-literal-type lit)
        fuel)]
    [(ast.AstExpr.Var name)
      (ResultCtfeQuoteExpr.Ok
        (ctfe-ast-push env (ast.AstExpr.Var (ctfe-quote-name-id env name)))
        (ast.AstType.Expr)
        fuel)]
    [(ast.AstExpr.Binary op left-box right-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-binary-with-pools
        left-box
        right-box
        op)]
    [(ast.AstExpr.Unary op inner-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-unary-with-pools
        inner-box
        op)]
    [(ast.AstExpr.Call func-box args)
      (let
        [func : ast.AstExpr (ctfe-ast-get env func-box)]
        (match (ctfe-quote-expr func env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-func _ func-fuel)
            (match (ctfe-quote-expr-list args env func-fuel quasiquote)
              [(ResultCtfeQuoteExprList.Ok quoted-args args-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ctfe-ast-expr-call-with-provenance
                    (ctfe-env-macro-state env)
                    (ctfe-env-pools env)
                    quoted-func
                    quoted-args)
                  (ast.AstType.Expr)
                  args-fuel)]
              [(ResultCtfeQuoteExprList.Err diag)
                (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.BracketClause items)
      (ctfe-quote-items
        env
        fuel
        quasiquote
        ast.ast-expr-bracket-clause-with-pools
        items)]
    [(ast.AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : ast.AstExpr (ctfe-ast-get env cond-box)]
        [then-branch : ast.AstExpr (ctfe-ast-get env then-branch-box)]
        [else-branch : ast.AstExpr (ctfe-ast-get env else-branch-box)]
        (match (ctfe-quote-expr cond env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-cond cond-ty cond-fuel)
            (match (ctfe-quote-expr then-branch env cond-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-then then-ty then-fuel)
                (match (ctfe-quote-expr else-branch env then-fuel quasiquote)
                  [(ResultCtfeQuoteExpr.Ok quoted-else else-ty else-fuel)
                    (ResultCtfeQuoteExpr.Ok
                      (ast.ast-expr-if-with-pools
                        (ctfe-env-pools env)
                        quoted-cond
                        quoted-then
                        quoted-else)
                      (ctfe-quote-if-type cond-ty then-ty else-ty)
                      else-fuel)]
                  [(ResultCtfeQuoteExpr.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.Let let-box)
      (match (__tl-box-place let-box)
        [(ast.AstLet.Let bindings body-box)
          (let
            [body : ast.AstExpr (ctfe-ast-get env body-box)]
            (match (ctfe-quote-let-binding-list bindings env fuel quasiquote)
              [(ResultCtfeQuoteLetBindings.Ok quoted-bindings bindings-fuel)
                (match (ctfe-quote-expr body env bindings-fuel quasiquote)
                  [(ResultCtfeQuoteExpr.Ok quoted-body body-ty body-fuel)
                    (ResultCtfeQuoteExpr.Ok
                      (ast.ast-expr-let-with-pools
                        (ctfe-env-pools env)
                        quoted-bindings
                        quoted-body)
                      body-ty
                      body-fuel)]
                  [(ResultCtfeQuoteExpr.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteLetBindings.Err diag)
                (ResultCtfeQuoteExpr.Err diag)]))])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(ast.AstLambda.Lambda params maybe-ret body-box)
          (let
            [body : ast.AstExpr (ctfe-ast-get env body-box)]
            (match (ctfe-quote-param-list params env (clone expr) fuel)
              [(ResultCtfeQuoteParams.Ok quoted-params params-fuel)
                (match (ctfe-quote-maybe-type maybe-ret env expr params-fuel)
                  [(ResultCtfeQuoteMaybeType.Ok quoted-ret ret-fuel)
                    (match (ctfe-quote-expr body env ret-fuel quasiquote)
                      [(ResultCtfeQuoteExpr.Ok quoted-body _ next-fuel)
                        (ResultCtfeQuoteExpr.Ok
                          (ast.ast-expr-lambda-with-pools
                            (ctfe-env-pools env)
                            quoted-params
                            quoted-ret
                            quoted-body)
                          (ast.AstType.Expr)
                          next-fuel)]
                      [(ResultCtfeQuoteExpr.Err diag)
                        (ResultCtfeQuoteExpr.Err diag)])]
                  [(ResultCtfeQuoteMaybeType.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteParams.Err diag) (ResultCtfeQuoteExpr.Err diag)]))])]
    [(ast.AstExpr.Tuple exprs)
      (ctfe-quote-items
        env
        fuel
        quasiquote
        ctfe-pools-push-variant
        exprs
        ast.AstExpr.Tuple)]
    [(ast.AstExpr.Array exprs)
      (ctfe-quote-items
        env
        fuel
        quasiquote
        ctfe-pools-push-variant
        exprs
        ast.AstExpr.Array)]
    [(ast.AstExpr.DynArray exprs)
      (ctfe-quote-items
        env
        fuel
        quasiquote
        ctfe-pools-push-variant
        exprs
        ast.AstExpr.DynArray)]
    [(ast.AstExpr.Begin exprs)
      (ctfe-quote-items
        env
        fuel
        quasiquote
        ctfe-pools-push-variant
        exprs
        ast.AstExpr.Begin)]
    [(ast.AstExpr.Unsafe exprs)
      (ctfe-quote-items
        env
        fuel
        quasiquote
        ctfe-pools-push-variant
        exprs
        ast.AstExpr.Unsafe)]
    [(ast.AstExpr.While cond-box body-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-while-with-pools
        cond-box
        body-box)]
    [(ast.AstExpr.ForOwnedState payload)
      (match (ctfe-quote-expr-list
        (ctfe-for-owned-state-exprs
          (ast.ast-for-owned-state-source-name (& payload))
          (ast.ast-for-owned-state-index-name (& payload))
          (ast.ast-for-owned-state-source (& payload))
          (ast.ast-for-owned-state-body (& payload)))
        env
        fuel
        quasiquote)
        [(ResultCtfeQuoteExprList.Ok quoted next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ast.ast-expr-for-owned-state-with-pools
              (ctfe-env-pools env)
              (ast.ast-expr-list-get (& quoted) 0 0)
              (ast.ast-expr-list-get (& quoted) 1 0)
              (ast.ast-expr-list-get (& quoted) 2 0)
              (ast.ast-expr-list-get (& quoted) 3 0))
            (ast.AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteExprList.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(ast.AstExpr.ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        (match (ctfe-quote-expr-list
          (ctfe-for-owned-step-exprs
            (ast.ast-for-owned-step-source-name (& payload))
            (ast.ast-for-owned-step-index-name (& payload))
            (ast.ast-for-owned-step-binding-name (& payload))
            expected-type
            (ast.ast-for-owned-step-done-name (& payload))
            (ast.ast-for-owned-step-body (& payload)))
          env
          fuel
          quasiquote)
          [(ResultCtfeQuoteExprList.Ok quoted next-fuel)
            (let
              [typed? : bool (>= expected-type 0)]
              [done-index : i64
                (if typed?
                  4
                  3)]
              [body-index : i64
                (if typed?
                  5
                  4)]
              (ResultCtfeQuoteExpr.Ok
                (ast.ast-expr-for-owned-step-with-pools
                  (ctfe-env-pools env)
                  (ast.ast-expr-list-get (& quoted) 0 0)
                  (ast.ast-expr-list-get (& quoted) 1 0)
                  (ast.ast-expr-list-get (& quoted) 2 0)
                  (if typed?
                    (ast.ast-expr-list-get (& quoted) 3 0)
                    -1)
                  (ast.ast-expr-list-get (& quoted) done-index 0)
                  (ast.ast-expr-list-get (& quoted) body-index 0))
                (ast.AstType.Expr)
                next-fuel))]
          [(ResultCtfeQuoteExprList.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.Set name rhs-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-set-id-with-pools
        rhs-box
        (ctfe-quote-name-id env name))]
    [(ast.AstExpr.Ann inner-box ty-id)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ expr-fuel)
            (match (ctfe-quote-type (ctfe-ty-get env ty-id) env expr expr-fuel)
              [(ResultCtfeQuoteType.Ok quoted-ty next-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast.ast-expr-ann-with-pools
                    (ctfe-env-pools env)
                    quoted
                    (clone quoted-ty))
                  quoted-ty
                  next-fuel)]
              [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.Cast inner-box ty-id)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ expr-fuel)
            (match (ctfe-quote-type (ctfe-ty-get env ty-id) env expr expr-fuel)
              [(ResultCtfeQuoteType.Ok quoted-ty next-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast.ast-expr-cast-with-pools
                    (ctfe-env-pools env)
                    quoted
                    (clone quoted-ty))
                  quoted-ty
                  next-fuel)]
              [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.TypeLiteral ty-id)
      (match (ctfe-quote-type (ctfe-ty-get env ty-id) env expr fuel)
        [(ResultCtfeQuoteType.Ok quoted-ty next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ctfe-ast-push
              env
              (ast.AstExpr.TypeLiteral (ctfe-ty-push env quoted-ty)))
            (ast.AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(ast.AstExpr.Borrow mutable lifetime-id place-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-borrow-with-pools
        place-box
        mutable
        (ast.ast-borrow-lifetime-from-id lifetime-id))]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrut-box arms)
          (let
            [scrut : ast.AstExpr (ctfe-ast-get env scrut-box)]
            (match (ctfe-quote-expr scrut env fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-scrut _ scrut-fuel)
                (match (ctfe-quote-arm-list arms env scrut-fuel quasiquote)
                  [(ResultCtfeQuoteArms.Ok quoted-arms arms-fuel)
                    (ResultCtfeQuoteExpr.Ok
                      (ast.ast-expr-match-with-pools
                        (ctfe-env-pools env)
                        quoted-scrut
                        quoted-arms)
                      (ast.AstType.Expr)
                      arms-fuel)]
                  [(ResultCtfeQuoteArms.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))])]
    [(ast.AstExpr.Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(ast.AstForeach.Foreach index index-ty start-box end-box body-box)
          (let
            [start : ast.AstExpr (ctfe-ast-get env start-box)]
            [end : ast.AstExpr (ctfe-ast-get env end-box)]
            [body : ast.AstExpr (ctfe-ast-get env body-box)]
            (match (ctfe-quote-expr start env fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-start _ start-fuel)
                (match (ctfe-quote-expr end env start-fuel quasiquote)
                  [(ResultCtfeQuoteExpr.Ok quoted-end _ end-fuel)
                    (match (ctfe-quote-expr body env end-fuel quasiquote)
                      [(ResultCtfeQuoteExpr.Ok quoted-body _ body-fuel)
                        (ResultCtfeQuoteExpr.Ok
                          (ast.ast-expr-foreach-id-with-pools
                            (ctfe-env-pools env)
                            (ctfe-quote-name-id env index)
                            index-ty
                            quoted-start
                            quoted-end
                            quoted-body)
                          (ast.AstType.Expr)
                          body-fuel)]
                      [(ResultCtfeQuoteExpr.Err diag)
                        (ResultCtfeQuoteExpr.Err diag)])]
                  [(ResultCtfeQuoteExpr.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(ast.AstSpmdReduce.Reduce
            op
            index
            index-ty
            start-box
            end-box
            init-box
            value-box)
          (let
            [start : ast.AstExpr (ctfe-ast-get env start-box)]
            [end : ast.AstExpr (ctfe-ast-get env end-box)]
            [init : ast.AstExpr (ctfe-ast-get env init-box)]
            [value : ast.AstExpr (ctfe-ast-get env value-box)]
            (match (ctfe-quote-expr start env fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-start _ start-fuel)
                (match (ctfe-quote-expr end env start-fuel quasiquote)
                  [(ResultCtfeQuoteExpr.Ok quoted-end _ end-fuel)
                    (match (ctfe-quote-expr init env end-fuel quasiquote)
                      [(ResultCtfeQuoteExpr.Ok quoted-init _ init-fuel)
                        (match (ctfe-quote-expr value env init-fuel quasiquote)
                          [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
                            (ResultCtfeQuoteExpr.Ok
                              (ast.ast-expr-spmd-reduce-id-with-pools
                                (ctfe-env-pools env)
                                op
                                (ctfe-quote-name-id env index)
                                index-ty
                                quoted-start
                                quoted-end
                                quoted-init
                                quoted-value)
                              (ast.AstType.Expr)
                              value-fuel)]
                          [(ResultCtfeQuoteExpr.Err diag)
                            (ResultCtfeQuoteExpr.Err diag)])]
                      [(ResultCtfeQuoteExpr.Err diag)
                        (ResultCtfeQuoteExpr.Err diag)])]
                  [(ResultCtfeQuoteExpr.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))])]
    [(ast.AstExpr.SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(ast.AstSpmdScan.Scan
            op
            index
            index-ty
            start-box
            end-box
            prefix
            prefix-ty
            init-box
            value-box
            body-box)
          (let
            [start : ast.AstExpr (ctfe-ast-get env start-box)]
            [end : ast.AstExpr (ctfe-ast-get env end-box)]
            [init : ast.AstExpr (ctfe-ast-get env init-box)]
            [value : ast.AstExpr (ctfe-ast-get env value-box)]
            [body : ast.AstExpr (ctfe-ast-get env body-box)]
            (match (ctfe-quote-expr start env fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-start _ start-fuel)
                (match (ctfe-quote-expr end env start-fuel quasiquote)
                  [(ResultCtfeQuoteExpr.Ok quoted-end _ end-fuel)
                    (match (ctfe-quote-expr init env end-fuel quasiquote)
                      [(ResultCtfeQuoteExpr.Ok quoted-init _ init-fuel)
                        (match (ctfe-quote-expr value env init-fuel quasiquote)
                          [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
                            (match (ctfe-quote-expr
                              body
                              env
                              value-fuel
                              quasiquote)
                              [(ResultCtfeQuoteExpr.Ok quoted-body _ body-fuel)
                                (ResultCtfeQuoteExpr.Ok
                                  (ast.ast-expr-spmd-scan-id-with-pools
                                    (ctfe-env-pools env)
                                    op
                                    (ctfe-quote-name-id env index)
                                    index-ty
                                    quoted-start
                                    quoted-end
                                    (ctfe-quote-name-id env prefix)
                                    prefix-ty
                                    quoted-init
                                    quoted-value
                                    quoted-body)
                                  (ast.AstType.Expr)
                                  body-fuel)]
                              [(ResultCtfeQuoteExpr.Err diag)
                                (ResultCtfeQuoteExpr.Err diag)])]
                          [(ResultCtfeQuoteExpr.Err diag)
                            (ResultCtfeQuoteExpr.Err diag)])]
                      [(ResultCtfeQuoteExpr.Err diag)
                        (ResultCtfeQuoteExpr.Err diag)])]
                  [(ResultCtfeQuoteExpr.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))])]
    [(ast.AstExpr.SpmdCompact compact-box)
      (match (__tl-box-place compact-box)
        [(ast.AstSpmdCompact.Compact
            index
            index-ty
            start-box
            end-box
            slot
            slot-ty
            init-box
            keep-box
            body-box)
          (let
            [start : ast.AstExpr (ctfe-ast-get env start-box)]
            [end : ast.AstExpr (ctfe-ast-get env end-box)]
            [init : ast.AstExpr (ctfe-ast-get env init-box)]
            [keep : ast.AstExpr (ctfe-ast-get env keep-box)]
            [body : ast.AstExpr (ctfe-ast-get env body-box)]
            (match (ctfe-quote-expr start env fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-start _ start-fuel)
                (match (ctfe-quote-expr end env start-fuel quasiquote)
                  [(ResultCtfeQuoteExpr.Ok quoted-end _ end-fuel)
                    (match (ctfe-quote-expr init env end-fuel quasiquote)
                      [(ResultCtfeQuoteExpr.Ok quoted-init _ init-fuel)
                        (match (ctfe-quote-expr keep env init-fuel quasiquote)
                          [(ResultCtfeQuoteExpr.Ok quoted-keep _ keep-fuel)
                            (match (ctfe-quote-expr
                              body
                              env
                              keep-fuel
                              quasiquote)
                              [(ResultCtfeQuoteExpr.Ok quoted-body _ body-fuel)
                                (ResultCtfeQuoteExpr.Ok
                                  (ast.ast-expr-spmd-compact-id-with-pools
                                    (ctfe-env-pools env)
                                    (ctfe-quote-name-id env index)
                                    index-ty
                                    quoted-start
                                    quoted-end
                                    (ctfe-quote-name-id env slot)
                                    slot-ty
                                    quoted-init
                                    quoted-keep
                                    quoted-body)
                                  (ast.AstType.Expr)
                                  body-fuel)]
                              [(ResultCtfeQuoteExpr.Err diag)
                                (ResultCtfeQuoteExpr.Err diag)])]
                          [(ResultCtfeQuoteExpr.Err diag)
                            (ResultCtfeQuoteExpr.Err diag)])]
                      [(ResultCtfeQuoteExpr.Err diag)
                        (ResultCtfeQuoteExpr.Err diag)])]
                  [(ResultCtfeQuoteExpr.Err diag)
                    (ResultCtfeQuoteExpr.Err diag)])]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))])]
    [(ast.AstExpr.SpmdBroadcast value-box lane-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-spmd-broadcast-with-pools
        value-box
        lane-box)]
    [(ast.AstExpr.SpmdShuffle value-box lane-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-spmd-shuffle-with-pools
        value-box
        lane-box)]
    [(ast.AstExpr.SpmdProgramIndex)
      (ResultCtfeQuoteExpr.Ok
        (ast.ast-expr-spmd-program-index-with-pools (ctfe-env-pools env))
        (ast.AstType.Expr)
        fuel)]
    [(ast.AstExpr.SpmdProgramCount)
      (ResultCtfeQuoteExpr.Ok
        (ast.ast-expr-spmd-program-count-with-pools (ctfe-env-pools env))
        (ast.AstType.Expr)
        fuel)]
    [(ast.AstExpr.StructGet inner-box field)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast.ast-expr-struct-get-id-with-pools
                (ctfe-env-pools env)
                quoted
                field)
              (ast.AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.StructSet inner-box field value-box)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        [value : ast.AstExpr (ctfe-ast-get env value-box)]
        (if (= field (ast.ast-expr-unquote-set-target-field-id))
          (match (ctfe-expr-unspan env (clone inner))
            [(ast.AstExpr.Unquote target-box)
              (if quasiquote
                (let
                  [target : ast.AstExpr (ctfe-ast-get env target-box)]
                  (match (ctfe-eval-unquote-expr target (clone inner) env fuel)
                    [(ResultCtfeQuoteExpr.Ok quoted-target _ target-fuel)
                      (match (ctfe-quote-expr value env target-fuel quasiquote)
                        [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
                          (match (ctfe-expr-unspan
                            env
                            (ctfe-ast-get env quoted-target))
                            [(ast.AstExpr.Var name)
                              (ResultCtfeQuoteExpr.Ok
                                (ast.ast-expr-set-id-with-pools
                                  (ctfe-env-pools env)
                                  name
                                  quoted-value)
                                (ast.AstType.Expr)
                                value-fuel)]
                            [(ast.AstExpr.StructGet receiver-box target-field)
                              (ResultCtfeQuoteExpr.Ok
                                (ast.ast-expr-struct-set-id-with-pools
                                  (ctfe-env-pools env)
                                  receiver-box
                                  target-field
                                  quoted-value)
                                (ast.AstType.Expr)
                                value-fuel)]
                            [(ast.AstExpr.BoxGet receiver-box)
                              (ResultCtfeQuoteExpr.Ok
                                (ast.ast-expr-box-set-with-pools
                                  (ctfe-env-pools env)
                                  receiver-box
                                  quoted-value)
                                (ast.AstType.Expr)
                                value-fuel)]
                            [_
                              (ResultCtfeQuoteExpr.Err
                                (box
                                  (ctfe-diagnostic-at-expr
                                    inner
                                    "quasiquote set! target must evaluate to a name, struct field place, or box place")))])]
                        [(ResultCtfeQuoteExpr.Err diag)
                          (ResultCtfeQuoteExpr.Err diag)])]
                    [(ResultCtfeQuoteExpr.Err diag)
                      (ResultCtfeQuoteExpr.Err diag)]))
                (ResultCtfeQuoteExpr.Err
                  (box
                    (ctfe-diagnostic-at-expr
                      inner
                      "unquote set! target is only valid inside quasiquote"))))]
            [_
              (ResultCtfeQuoteExpr.Err
                (box
                  (ctfe-diagnostic-at-expr
                    inner
                    "internal unquote set! target must be an unquote form")))])
          (match (ctfe-quote-expr inner env fuel quasiquote)
            [(ResultCtfeQuoteExpr.Ok quoted-inner _ inner-fuel)
              (match (ctfe-quote-expr value env inner-fuel quasiquote)
                [(ResultCtfeQuoteExpr.Ok quoted-value _ value-fuel)
                  (ResultCtfeQuoteExpr.Ok
                    (ast.ast-expr-struct-set-id-with-pools
                      (ctfe-env-pools env)
                      quoted-inner
                      field
                      quoted-value)
                    (ast.AstType.Expr)
                    value-fuel)]
                [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
            [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])))]
    [(ast.AstExpr.TupleRef tuple-expr-box index)
      (let
        [tuple-expr : ast.AstExpr (ctfe-ast-get env tuple-expr-box)]
        (match (ctfe-quote-expr tuple-expr env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast.ast-expr-tuple-ref-with-pools
                (ctfe-env-pools env)
                quoted
                index)
              (ast.AstType.Expr)
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.FixedMakeArray ty-id len-box)
      (let
        [len : ast.AstExpr (ctfe-ast-get env len-box)]
        (match (ctfe-quote-type (ctfe-ty-get env ty-id) env expr fuel)
          [(ResultCtfeQuoteType.Ok quoted-ty type-fuel)
            (match (ctfe-quote-expr len env type-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-len _ next-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast.ast-expr-fixed-make-array-with-pools
                    (ctfe-env-pools env)
                    quoted-ty
                    quoted-len)
                  (ast.AstType.Expr)
                  next-fuel)]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.MakeArray ty-id len-box)
      (let
        [len : ast.AstExpr (ctfe-ast-get env len-box)]
        (match (ctfe-quote-type (ctfe-ty-get env ty-id) env expr fuel)
          [(ResultCtfeQuoteType.Ok quoted-ty type-fuel)
            (match (ctfe-quote-expr len env type-fuel quasiquote)
              [(ResultCtfeQuoteExpr.Ok quoted-len _ next-fuel)
                (let
                  [result : i64
                    (ast.ast-expr-make-array-with-pools
                      (ctfe-env-pools env)
                      quoted-ty
                      quoted-len)]
                  (ResultCtfeQuoteExpr.Ok result (ast.AstType.Expr) next-fuel))]
              [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.ArrayRef array-box index-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-array-ref-with-pools
        array-box
        index-box)]
    [(ast.AstExpr.ArraySet array-box index-box value-box)
      (ctfe-quote-children-3
        env
        fuel
        quasiquote
        ast.ast-expr-array-set-with-pools
        array-box
        index-box
        value-box)]
    [(ast.AstExpr.ArrayTake array-box live-box index-box)
      (ctfe-quote-children-3
        env
        fuel
        quasiquote
        ast.ast-expr-array-take-with-pools
        array-box
        live-box
        index-box)]
    [(ast.AstExpr.Replace place-box replacement-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-replace-with-pools
        place-box
        replacement-box)]
    [(ast.AstExpr.ArrayPush array-box value-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-array-push-with-pools
        array-box
        value-box)]
    [(ast.AstExpr.StringRef text-box index-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-string-ref-with-pools
        text-box
        index-box)]
    [(ast.AstExpr.WithRegion name body)
      (match (ctfe-quote-expr-list body env fuel quasiquote)
        [(ResultCtfeQuoteExprList.Ok quoted-body next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ctfe-ast-push
              env
              (ast.AstExpr.WithRegion (ctfe-quote-name-id env name) quoted-body))
            (ast.AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteExprList.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(ast.AstExpr.WithEscape scratch-box body)
      (let
        [scratch : ast.AstExpr (ctfe-ast-get env scratch-box)]
        (match (ctfe-quote-expr scratch env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-scratch _ scratch-fuel)
            (match (ctfe-quote-expr-list body env scratch-fuel quasiquote)
              [(ResultCtfeQuoteExprList.Ok quoted-body body-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast.ast-expr-with-escape-with-pools
                    (ctfe-env-pools env)
                    quoted-scratch
                    quoted-body)
                  (ast.AstType.Expr)
                  body-fuel)]
              [(ResultCtfeQuoteExprList.Err diag)
                (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.WithScratch body)
      (ctfe-quote-items
        env
        fuel
        quasiquote
        ast.ast-expr-with-scratch-with-pools
        body)]
    [(ast.AstExpr.InArena arena-box body)
      (let
        [arena : ast.AstExpr (ctfe-ast-get env arena-box)]
        (match (ctfe-quote-expr arena env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted-arena _ arena-fuel)
            (match (ctfe-quote-expr-list body env arena-fuel quasiquote)
              [(ResultCtfeQuoteExprList.Ok quoted-body body-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast.ast-expr-in-arena-with-pools
                    (ctfe-env-pools env)
                    quoted-arena
                    quoted-body)
                  (ast.AstType.Expr)
                  body-fuel)]
              [(ResultCtfeQuoteExprList.Err diag)
                (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (match (ctfe-quote-resource-binding-list bindings env fuel quasiquote)
            [(ResultCtfeQuoteResourceBindings.Ok quoted-bindings bindings-fuel)
              (match (ctfe-quote-expr-list body env bindings-fuel quasiquote)
                [(ResultCtfeQuoteExprList.Ok quoted-body body-fuel)
                  (ResultCtfeQuoteExpr.Ok
                    (ctfe-ast-push
                      env
                      (ast.AstExpr.WithResource
                        (box
                          (ast.AstWithResource.WithResource
                            quoted-bindings
                            quoted-body))))
                    (ast.AstType.Expr)
                    body-fuel)]
                [(ResultCtfeQuoteExprList.Err diag)
                  (ResultCtfeQuoteExpr.Err diag)])]
            [(ResultCtfeQuoteResourceBindings.Err diag)
              (ResultCtfeQuoteExpr.Err diag)])])]
    [(ast.AstExpr.Box inner-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-box-with-pools
        inner-box)]
    [(ast.AstExpr.BoxGet inner-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-box-get-with-pools
        inner-box)]
    [(ast.AstExpr.BoxTake inner-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-box-take-with-pools
        inner-box)]
    [(ast.AstExpr.BoxSet inner-box value-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-box-set-with-pools
        inner-box
        value-box)]
    [(ast.AstExpr.Comptime inner-box)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted ty next-fuel)
            (ResultCtfeQuoteExpr.Ok
              (ast.ast-expr-comptime-with-pools (ctfe-env-pools env) quoted)
              ty
              next-fuel)]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.Return inner-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-return-with-pools
        inner-box)]
    [(ast.AstExpr.Try inner-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-try-with-pools
        inner-box)]
    [(ast.AstExpr.Break)
      (ResultCtfeQuoteExpr.Ok
        (ast.ast-expr-break-with-pools (ctfe-env-pools env))
        (ast.AstType.Expr)
        fuel)]
    [(ast.AstExpr.Continue)
      (ResultCtfeQuoteExpr.Ok
        (ast.ast-expr-continue-with-pools (ctfe-env-pools env))
        (ast.AstType.Expr)
        fuel)]
    [(ast.AstExpr.Init maybe-ty-id)
      (match (ctfe-quote-maybe-type
        (ast.ast-maybe-type-from-id-with-pools (ctfe-env-pools env) maybe-ty-id)
        env
        expr
        fuel)
        [(ResultCtfeQuoteMaybeType.Ok quoted-ty next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ast.ast-expr-init-maybe-with-pools (ctfe-env-pools env) quoted-ty)
            (ast.AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteMaybeType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(ast.AstExpr.PtrNull ty-id)
      (match (ctfe-quote-type (ctfe-ty-get env ty-id) env expr fuel)
        [(ResultCtfeQuoteType.Ok quoted-ty next-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ctfe-ast-push
              env
              (ast.AstExpr.PtrNull (ctfe-ty-push env quoted-ty)))
            (ast.AstType.Expr)
            next-fuel)]
        [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(ast.AstExpr.PtrNullCheck ptr-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-ptr-null-check-with-pools
        ptr-box)]
    [(ast.AstExpr.PtrAddrOf place-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-ptr-addr-of-id-with-pools
        place-box)]
    [(ast.AstExpr.PtrRead ptr-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-ptr-read-with-pools
        ptr-box)]
    [(ast.AstExpr.PtrWrite ptr-box value-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-ptr-write-with-pools
        ptr-box
        value-box)]
    [(ast.AstExpr.PtrOffset ptr-box offset-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-ptr-offset-with-pools
        ptr-box
        offset-box)]
    [(ast.AstExpr.PtrCast ptr-box ty-id)
      (let
        [ptr : ast.AstExpr (ctfe-ast-get env ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ expr-fuel)
            (match (ctfe-quote-type (ctfe-ty-get env ty-id) env expr expr-fuel)
              [(ResultCtfeQuoteType.Ok quoted-ty next-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast.ast-expr-ptr-cast-with-pools
                    (ctfe-env-pools env)
                    quoted
                    quoted-ty)
                  (ast.AstType.Expr)
                  next-fuel)]
              [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.PtrToInt ptr-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-ptr-to-int-with-pools
        ptr-box)]
    [(ast.AstExpr.IntToPtr value-box ty-id)
      (let
        [value : ast.AstExpr (ctfe-ast-get env value-box)]
        (match (ctfe-quote-expr value env fuel quasiquote)
          [(ResultCtfeQuoteExpr.Ok quoted _ expr-fuel)
            (match (ctfe-quote-type (ctfe-ty-get env ty-id) env expr expr-fuel)
              [(ResultCtfeQuoteType.Ok quoted-ty next-fuel)
                (ResultCtfeQuoteExpr.Ok
                  (ast.ast-expr-int-to-ptr-with-pools
                    (ctfe-env-pools env)
                    quoted
                    quoted-ty)
                  (ast.AstType.Expr)
                  next-fuel)]
              [(ResultCtfeQuoteType.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
          [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)]))]
    [(ast.AstExpr.StringData inner-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-string-data-with-pools
        inner-box)]
    [(ast.AstExpr.StringFromBytes ptr-box len-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-string-from-bytes-with-pools
        ptr-box
        len-box)]
    [(ast.AstExpr.ArrayData inner-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-array-data-with-pools
        inner-box)]
    [(ast.AstExpr.BinaryData bytes)
      (ResultCtfeQuoteExpr.Ok
        (ctfe-ast-push env (ast.AstExpr.BinaryData bytes))
        (ast.AstType.Expr)
        fuel)]
    [(ast.AstExpr.CpuIdEax leaf-box subleaf-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-cpuid-eax-with-pools
        leaf-box
        subleaf-box)]
    [(ast.AstExpr.CpuIdEbx leaf-box subleaf-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-cpuid-ebx-with-pools
        leaf-box
        subleaf-box)]
    [(ast.AstExpr.CpuIdEcx leaf-box subleaf-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-cpuid-ecx-with-pools
        leaf-box
        subleaf-box)]
    [(ast.AstExpr.CpuIdEdx leaf-box subleaf-box)
      (ctfe-quote-children-2
        env
        fuel
        quasiquote
        ast.ast-expr-cpuid-edx-with-pools
        leaf-box
        subleaf-box)]
    [(ast.AstExpr.Xgetbv index-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-xgetbv-with-pools
        index-box)]
    [(ast.AstExpr.Syscall args)
      (ctfe-quote-items
        env
        fuel
        quasiquote
        ast.ast-expr-syscall-with-pools
        args)]
    [(ast.AstExpr.ForeachActive lane body-box)
      (match (ctfe-quote-expr (ctfe-ast-get env body-box) env fuel quasiquote)
        [(ResultCtfeQuoteExpr.Ok quoted-body _ body-fuel)
          (ResultCtfeQuoteExpr.Ok
            (ast.ast-expr-foreach-active-with-pools
              (ctfe-env-pools env)
              (ctfe-quote-name-id env lane)
              quoted-body)
            (ast.AstType.Expr)
            body-fuel)]
        [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])]
    [(ast.AstExpr.LaneValue value-box)
      (ctfe-quote-children-1
        env
        fuel
        quasiquote
        ast.ast-expr-lane-value-with-pools
        value-box)]
    [(ast.AstExpr.Unquote inner-box)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (if quasiquote
          (ctfe-eval-unquote-expr inner expr env fuel)
          (match (ctfe-quote-expr inner env fuel quasiquote)
            [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
              (ResultCtfeQuoteExpr.Ok
                (ast.ast-expr-unquote-with-pools (ctfe-env-pools env) quoted)
                (ast.AstType.Expr)
                next-fuel)]
            [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])))]
    [(ast.AstExpr.UnquoteSplicing inner-box)
      (let
        [inner : ast.AstExpr (ctfe-ast-get env inner-box)]
        (if quasiquote
          (ResultCtfeQuoteExpr.Err
            (box
              (ctfe-diagnostic-at-expr
                expr
                "unquote-splicing is only valid in a quasiquote list")))
          (match (ctfe-quote-expr inner env fuel quasiquote)
            [(ResultCtfeQuoteExpr.Ok quoted _ next-fuel)
              (ResultCtfeQuoteExpr.Ok
                (ast.ast-expr-unquote-splicing-with-pools
                  (ctfe-env-pools env)
                  quoted)
                (ast.AstType.Expr)
                next-fuel)]
            [(ResultCtfeQuoteExpr.Err diag) (ResultCtfeQuoteExpr.Err diag)])))]
    [_
      (ResultCtfeQuoteExpr.Ok (ctfe-ast-push env expr) (ast.AstType.Expr) fuel)]))

(define (ctfe-eval-quote
  [template : ast.AstExpr]
  [env : (& env CtfeEnv)]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfe
  (let
    ;; A transformer body is read from its definition snapshot, while an
    ;; unquoted parameter may carry a newer snapshot of the same backing pool.
    ;; Quote construction must append through that newer live state cell or a
    ;; parent can overwrite its just-produced child. Rebase once here so every
    ;; recursive expression and type constructor uses the captured pool while
    ;; retaining access to the shared definition nodes.
    [quote-env : CtfeEnv
      (match (ctfe-env-syntax-pools-live env)
        [(CtfeMaybeSyntaxPools.Some pools)
          (ctfe-env-rebase-syntax-pools (ctfe-env-shared-view env) pools)]
        [(CtfeMaybeSyntaxPools.None) (ctfe-env-shared-view env)])]
    (match (ctfe-quote-expr template (& quote-env) fuel quasiquote)
      [(ResultCtfeQuoteExpr.Ok node ty next-fuel)
        (ResultCtfe.Ok (CompilerCtfeValue.Expr node ty) next-fuel)]
      [(ResultCtfeQuoteExpr.Err diag) (ResultCtfe.Err diag)])))

;; --- expr constructors and inspectors ----------------------------------------
;; Macro transformers need to build and pattern-match AST nodes at comptime.
;; These constructors / inspectors cover the forms needed by v1 macros
;; (and, or, when, unless, cond): literals, variables, if, and call.
;; EQ -------------------------------------------------------------------------
(define (ctfe-literal-eq
  [session : cis.InternStructuralSessionHandle]
  [a : ast.AstLiteral]
  [b : ast.AstLiteral]) : bool
  (match a
    [(ast.AstLiteral.Int a-n a-text)
      (match b
        [(ast.AstLiteral.Int b-n b-text)
          (=
            (ast.ast-int-literal-value-or-payload a-n a-text)
            (ast.ast-int-literal-value-or-payload b-n b-text))]
        [_ false])]
    [(ast.AstLiteral.Bool a-b)
      (match b
        [(ast.AstLiteral.Bool b-b) (= a-b b-b)]
        [_ false])]
    [(ast.AstLiteral.Char a-c)
      (match b
        [(ast.AstLiteral.Char b-c) (= a-c b-c)]
        [_ false])]
    [(ast.AstLiteral.Float a-text)
      (match b
        [(ast.AstLiteral.Float b-text) (string.eq a-text b-text)]
        [_ false])]
    [(ast.AstLiteral.String a-id)
      (match b
        [(ast.AstLiteral.String b-id)
          (string.eq
            (ctfe-name-text-for-session session a-id)
            (ctfe-name-text-for-session session b-id))]
        [_ false])]
    [(ast.AstLiteral.Unit)
      (match b
        [(ast.AstLiteral.Unit) true]
        [_ false])]
    [_ false]))

(define (ctfe-maybe-type-eq-in-env
  [env : (& env CtfeEnv)]
  [a : ast.AstMaybeType]
  [b : ast.AstMaybeType]) : bool
  (match a
    [(ast.AstMaybeType.No)
      (match b
        [(ast.AstMaybeType.No) true]
        [_ false])]
    [(ast.AstMaybeType.Some a-ty)
      (match b
        [(ast.AstMaybeType.Some b-ty) (ctfe-type-eq-in-env env a-ty b-ty)]
        [_ false])]))

(define (ctfe-pattern-eq-in-env
  [env : CtfeEnv]
  [a : ast.AstPattern]
  [b : ast.AstPattern]) : bool
  (match a
    [(ast.AstPattern.Var a-name a-ty)
      (match b
        [(ast.AstPattern.Var b-name b-ty)
          (and (= a-name b-name) (ctfe-maybe-type-eq-in-env env a-ty b-ty))]
        [_ false])]
    [(ast.AstPattern.Tuple a-items-box)
      (let
        [a-items : ast.AstPatternList (deref a-items-box)]
        (match b
          [(ast.AstPattern.Tuple b-items-box)
            (ctfe-pattern-list-eq-in-env env a-items (deref b-items-box))]
          [_ false]))]
    [(ast.AstPattern.Array a-items-box)
      (let
        [a-items : ast.AstPatternList (deref a-items-box)]
        (match b
          [(ast.AstPattern.Array b-items-box)
            (ctfe-pattern-list-eq-in-env env a-items (deref b-items-box))]
          [_ false]))]
    [(ast.AstPattern.Slice a-items-box a-rest)
      (let
        [a-items : ast.AstPatternList (deref a-items-box)]
        (match b
          [(ast.AstPattern.Slice b-items-box b-rest)
            (and
              (= a-rest b-rest)
              (ctfe-pattern-list-eq-in-env env a-items (deref b-items-box)))]
          [_ false]))]
    [(ast.AstPattern.Wildcard)
      (match b
        [(ast.AstPattern.Wildcard) true]
        [_ false])]
    [(ast.AstPattern.Binding a-name)
      (match b
        [(ast.AstPattern.Binding b-name) (= a-name b-name)]
        [_ false])]
    [(ast.AstPattern.Variant a-name a-items-box)
      (let
        [a-items : ast.AstPatternList (deref a-items-box)]
        (match b
          [(ast.AstPattern.Variant b-name b-items-box)
            (and
              (= a-name b-name)
              (ctfe-pattern-list-eq-in-env env a-items (deref b-items-box)))]
          [_ false]))]
    [(ast.AstPattern.Literal a-lit)
      (match b
        [(ast.AstPattern.Literal b-lit)
          (ctfe-literal-eq (ctfe-env-structural-session (& env)) a-lit b-lit)]
        [_ false])]))

(define (ctfe-pattern-list-eq-in-env
  [env : CtfeEnv]
  [a : ast.AstPatternList]
  [b : ast.AstPatternList]) : bool
  (and (= a.len b.len) (ctfe-pattern-list-eq-in-env-at env (& a) (& b) 0)))

(define (ctfe-pattern-list-eq-in-env-at
  [env : CtfeEnv]
  [a : (& a ast.AstPatternList)]
  [b : (& b ast.AstPatternList)]
  [index : i64]) : bool
  (if (>= index a.len)
    true
    (and
      (ctfe-pattern-eq-in-env
        env
        (ast.ast-pattern-list-get a index (ast.ast-pattern-fallback))
        (ast.ast-pattern-list-get b index (ast.ast-pattern-fallback)))
      (ctfe-pattern-list-eq-in-env-at env a b (+ index 1)))))

(define (ctfe-expr-eq-inner-in-env
  [env : CtfeEnv]
  [a : ast.AstExpr]
  [b : ast.AstExpr]) : bool
  ;; Structural equality through the AstExpr child schema. The operands are
  ;; unspanned, so neither is Spanned or MacroExpansion; for-owned planner
  ;; forms never compare equal.
  (if (ast.ast-expr-for-owned? (& a))
    false
    (ast.ast-expr-children-eq?
      a
      b
      ctfe-expr-id-eq-in-env
      ctfe-type-id-eq-in-env
      ctfe-type-eq-in-env
      ctfe-pattern-eq-in-env
      ctfe-literal-eq-in-env
      env)))

(define (ctfe-expr-id-eq-in-env [env : CtfeEnv] [a : i64] [b : i64]) : bool
  (ctfe-expr-eq-in-env env (ctfe-ast-get env a) (ctfe-ast-get env b)))

(define (ctfe-type-id-eq-in-env [env : CtfeEnv] [a : i64] [b : i64]) : bool
  (ctfe-type-eq-in-env env (ctfe-ty-get env a) (ctfe-ty-get env b)))

(define (ctfe-literal-eq-in-env
  [env : CtfeEnv]
  [a : ast.AstLiteral]
  [b : ast.AstLiteral]) : bool
  (ctfe-literal-eq (ctfe-env-structural-session (& env)) a b))

(define (ctfe-expr-eq-in-env
  [env : CtfeEnv]
  [a : ast.AstExpr]
  [b : ast.AstExpr]) : bool
  (ctfe-expr-eq-inner-in-env
    env
    (ctfe-expr-unspan env a)
    (ctfe-expr-unspan env b)))

(define (ctfe-expr-list-eq-in-env
  [env : CtfeEnv]
  [a : ast.AstExprList]
  [b : ast.AstExprList]) : bool
  (ast.ast-expr-list-eq? a b ctfe-expr-id-eq-in-env env))

(define (ctfe-expr-clause-eq-in-env
  [env : CtfeEnv]
  [a : ast.AstExprClause]
  [b : ast.AstExprClause]) : bool
  (let
    [a-first : ast.AstExpr (ctfe-ast-get env (ctfe-expr-clause-first a))]
    [b-first : ast.AstExpr (ctfe-ast-get env (ctfe-expr-clause-first b))]
    [a-second : ast.AstExpr (ctfe-ast-get env (ctfe-expr-clause-second a))]
    [b-second : ast.AstExpr (ctfe-ast-get env (ctfe-expr-clause-second b))]
    (and
      (ctfe-expr-eq-in-env env a-first b-first)
      (ctfe-expr-eq-in-env env a-second b-second))))

(define (ctfe-expr-clause-list-eq-in-env
  [env : CtfeEnv]
  [a : ast.AstExprClauseList]
  [b : ast.AstExprClauseList]) : bool
  (if (= a.len b.len)
    (ctfe-expr-clause-list-eq-at-in-env env (& a) (& b) 0)
    false))

(define (ctfe-expr-clause-list-eq-at-in-env
  [env : CtfeEnv]
  [a : (& a ast.AstExprClauseList)]
  [b : (& b ast.AstExprClauseList)]
  [index : i64]) : bool
  (if (>= index a.len)
    true
    (and
      (ctfe-expr-clause-eq-in-env
        env
        (ast.ast-expr-clause-list-get a index (ast.ast-expr-clause-fallback))
        (ast.ast-expr-clause-list-get b index (ast.ast-expr-clause-fallback)))
      (ctfe-expr-clause-list-eq-at-in-env env a b (+ index 1)))))

(define (ctfe-expr-binding-clause-eq-in-env
  [env : CtfeEnv]
  [a : ast.AstExprBindingClause]
  [b : ast.AstExprBindingClause]) : bool
  (let
    [a-ty : ast.AstExpr (ctfe-ast-get env a.ty)]
    [b-ty : ast.AstExpr (ctfe-ast-get env b.ty)]
    [a-init : ast.AstExpr (ctfe-ast-get env a.init)]
    [b-init : ast.AstExpr (ctfe-ast-get env b.init)]
    (and
      (ci.intern-syntax-id-eq? a.name b.name)
      (= a.has-type b.has-type)
      (ctfe-expr-eq-in-env env a-ty b-ty)
      (ctfe-expr-eq-in-env env a-init b-init))))

(define (ctfe-expr-binding-clause-list-eq-in-env
  [env : CtfeEnv]
  [a : ast.AstExprBindingClauseList]
  [b : ast.AstExprBindingClauseList]) : bool
  (if (= a.len b.len)
    (ctfe-expr-binding-clause-list-eq-at-in-env env (& a) (& b) 0)
    false))

(define (ctfe-expr-binding-clause-list-eq-at-in-env
  [env : CtfeEnv]
  [a : (& a ast.AstExprBindingClauseList)]
  [b : (& b ast.AstExprBindingClauseList)]
  [index : i64]) : bool
  (if (>= index a.len)
    true
    (and
      (ctfe-expr-binding-clause-eq-in-env
        env
        (ast.ast-expr-binding-clause-list-get
          a
          index
          (ast.ast-expr-binding-clause-fallback))
        (ast.ast-expr-binding-clause-list-get
          b
          index
          (ast.ast-expr-binding-clause-fallback)))
      (ctfe-expr-binding-clause-list-eq-at-in-env env a b (+ index 1)))))

(define (ctfe-expr-eq [a : ast.AstExpr] [b : ast.AstExpr]) : bool
  (ctfe-expr-eq-in-env (ctfe-env-empty) a b))

(define (ctfe-expr-list-length [lst : (& lst ast.AstExprList)]) : i64
  lst.len)

(define (ctfe-expr-clause-first [clause : (& clause ast.AstExprClause)]) : i64
  clause.first)

(define (ctfe-expr-clause-second [clause : (& clause ast.AstExprClause)]) : i64
  clause.second)

(define (ctfe-expr-clause-list-length [lst : (& lst ast.AstExprClauseList)]) : i64
  lst.len)

(define (ctfe-expr-clause-list-nth
  [lst : (& lst ast.AstExprClauseList)]
  [index : i64]) : ast.AstExprClause
  (if (or (< index 0) (>= index lst.len))
    (ast.ast-expr-clause
      (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit)))
      (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit))))
    (ast.ast-expr-clause-list-get lst index (ast.ast-expr-clause-fallback))))

(define (ctfe-expr-clause-as-bracket-expr-in-env
  [env : CtfeEnv]
  [clause : ast.AstExprClause]) : i64
  (ast.ast-expr-bracket-clause-with-pools
    (ctfe-env-pools env)
    (ast.ast-expr-cons
      (ctfe-expr-clause-first clause)
      (ast.ast-expr-cons
        (ctfe-expr-clause-second clause)
        (ast.ast-expr-list-new)))))

(define (ctfe-expr-clause-list->expr-list-in-env
  [env : CtfeEnv]
  [lst : ast.AstExprClauseList]) : ast.AstExprList
  (let
    [out : ast.AstExprList (ast.ast-expr-list-with-capacity lst.len)]
    (begin
      (ctfe-expr-clause-list->expr-list-into env (& lst) 0 (&mut out))
      out)))

(define (ctfe-expr-clause-list->expr-list-into
  [env : CtfeEnv]
  [lst : (& lst ast.AstExprClauseList)]
  [index : i64]
  [out : (&mut out ast.AstExprList)]) : unit
  (if (>= index lst.len)
    unit
    (begin
      (ast.ast-expr-list-push
        out
        (ctfe-expr-clause-as-bracket-expr-in-env
          env
          (ast.ast-expr-clause-list-get
            lst
            index
            (ast.ast-expr-clause-fallback))))
      (ctfe-expr-clause-list->expr-list-into env lst (+ index 1) out))))

(define (ctfe-expr-binding-clause-name-id [clause : ast.AstExprBindingClause]) : ci.InternSyntaxId
  clause.name)

(define (ctfe-expr-binding-clause-has-type? [clause : ast.AstExprBindingClause]) : bool
  clause.has-type)

(define (ctfe-expr-binding-clause-type [clause : ast.AstExprBindingClause]) : i64
  clause.ty)

(define (ctfe-expr-binding-clause-init [clause : ast.AstExprBindingClause]) : i64
  clause.init)

(define (ctfe-expr-binding-clause-list-length
  [lst : (& lst ast.AstExprBindingClauseList)]) : i64
  lst.len)

(define (ctfe-expr-binding-clause-empty-default) : ast.AstExprBindingClause
  (let
    [unit-expr : i64
      (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit)))]
    (ast.ast-expr-binding-clause-id
      (ci.intern-syntax-id-from-raw 0)
      false
      unit-expr
      unit-expr
      (ctfe-untyped-expr-type)
      (ast.ast-source-span 0 0 0 0))))

(define (ctfe-expr-binding-clause-list-nth
  [lst : ast.AstExprBindingClauseList]
  [index : i64]) : ast.AstExprBindingClause
  (if (or (< index 0) (>= index lst.len))
    (ctfe-expr-binding-clause-empty-default)
    (ast.ast-expr-binding-clause-list-get
      (& lst)
      index
      (ast.ast-expr-binding-clause-fallback))))

(define (ctfe-expr-binding-clause-as-bracket-expr-in-env
  [env : CtfeEnv]
  [clause : ast.AstExprBindingClause]) : i64
  (let
    [name-expr : i64
      (ctfe-ast-push
        env
        (ast.AstExpr.Var (ci.intern-syntax-id-value clause.name)))]
    [bracket : i64
      (if clause.has-type
        (ast.ast-expr-bracket-clause-with-pools
          (ctfe-env-pools env)
          (ast.ast-expr-cons
            name-expr
            (ast.ast-expr-cons
              (ctfe-ast-push
                env
                (ast.AstExpr.Var cbi.compiler-builtin-id-fix-colon))
              (ast.ast-expr-cons
                clause.ty
                (ast.ast-expr-cons clause.init (ast.ast-expr-list-new))))))
        (ast.ast-expr-bracket-clause-with-pools
          (ctfe-env-pools env)
          (ast.ast-expr-cons
            name-expr
            (ast.ast-expr-cons clause.init (ast.ast-expr-list-new)))))]
    [span-pools : ast.AstNodePoolContext (ctfe-env-pools env)]
    (ast.ast-expr-spanned-with-pools span-pools bracket clause.span)))

(define (ctfe-expr-binding-clause-list->expr-list-in-env
  [env : CtfeEnv]
  [lst : ast.AstExprBindingClauseList]) : ast.AstExprList
  (let
    [out : ast.AstExprList (ast.ast-expr-list-with-capacity lst.len)]
    (begin
      (ctfe-expr-binding-clause-list->expr-list-into env (& lst) 0 (&mut out))
      out)))

(define (ctfe-expr-binding-clause-list->expr-list-into
  [env : CtfeEnv]
  [lst : (& lst ast.AstExprBindingClauseList)]
  [index : i64]
  [out : (&mut out ast.AstExprList)]) : unit
  (if (>= index lst.len)
    unit
    (begin
      (ast.ast-expr-list-push
        out
        (ctfe-expr-binding-clause-as-bracket-expr-in-env
          env
          (ast.ast-expr-binding-clause-list-get
            lst
            index
            (ast.ast-expr-binding-clause-fallback))))
      (ctfe-expr-binding-clause-list->expr-list-into env lst (+ index 1) out))))

;; INSPECTORS (predicates) -----------------------------------------------------
(define (ctfe-expr-if-in-env? [env : CtfeEnv] [e : i64]) : bool
  (match (ctfe-ast-get env e)
    [(ast.AstExpr.If _ _ _) true]
    [_ false]))

;; INSPECTORS (extractors) -----------------------------------------------------
(define (ctfe-expr-if-cond-in-env [env : CtfeEnv] [e : i64]) : i64
  (match (ctfe-ast-get env e)
    [(ast.AstExpr.If c _ _) c]
    [_ (ctfe-ast-push env (ast.AstExpr.Literal (ast.AstLiteral.Unit)))]))

(define (ctfe-expr-if-then-in-env [env : CtfeEnv] [e : i64]) : i64
  (match (ctfe-ast-get env e)
    [(ast.AstExpr.If _ t _) t]
    [_ (ctfe-ast-push env (ast.AstExpr.Literal (ast.AstLiteral.Unit)))]))

(define (ctfe-expr-if-else-in-env [env : CtfeEnv] [e : i64]) : i64
  (match (ctfe-ast-get env e)
    [(ast.AstExpr.If _ _ el) el]
    [_ (ctfe-ast-push env (ast.AstExpr.Literal (ast.AstLiteral.Unit)))]))

(define (ctfe-expr-list-nth [lst : (& lst ast.AstExprList)] [index : i64]) : i64
  (if (or (< index 0) (>= index lst.len))
    (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit)))
    (ast.ast-expr-list-get lst index 0)))

;; --- folding ----------------------------------------------------------------
;; Convert a folded compile-time value into the AST literal that lowering then
;; materializes through the ordinary literal path. Expr / ExprList values are
;; compile-time only and have no runtime literal form; this is used for scalar
;; value lowering.
(define (ctfe-value-to-literal [value : CompilerCtfeValue]) : ast.AstLiteral
  (match value
    [(CompilerCtfeValue.I64 n) (ast.ast-lit-int n)]
    [(CompilerCtfeValue.F64 n)
      (ast.AstLiteral.Float (cfloat.compiler-float-format-f64 n))]
    [(CompilerCtfeValue.F32 n)
      (ast.AstLiteral.Float
        (cfloat.compiler-float-format-f64
          (cfloat.compiler-float-round-f32-as-f64 n)))]
    [(CompilerCtfeValue.Bool b) (ast.AstLiteral.Bool b)]
    [(CompilerCtfeValue.Char c) (ast.AstLiteral.Char c)]
    [(CompilerCtfeValue.String _ string-id) (ast.AstLiteral.String string-id)]
    [(CompilerCtfeValue.Name _ name-id) (ast.AstLiteral.String name-id)]
    [(CompilerCtfeValue.Unit) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.Type _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.Expr _ _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.CapturedExpr _ _ _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.ExprList _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.CapturedExprList _ _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.ExprClause _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.CapturedExprClause _ _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.ExprClauseList _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.CapturedExprClauseList _ _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.ExprBindingClause _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.ExprBindingClauseList _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.Pattern _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.PatternList _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.MatchArm _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.MatchArmList _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.LetBinding _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.LetBindingList _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeInfo _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeInfoBox _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeInfoList _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeField _ _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeFieldList _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeVariantPayload _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeVariantPayloadList _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeVariant _ _) (ast.AstLiteral.Unit)]
    [(CompilerCtfeValue.TypeVariantList _) (ast.AstLiteral.Unit)]))

(define (ctfe-value-to-literal-for-type
  [value : CompilerCtfeValue]
  [ty : ast.AstType]) : ast.AstLiteral
  (match ty
    [(ast.AstType.F32)
      (match (ctfe-value-owned-copy (& value))
        [(CompilerCtfeValue.F64 n)
          (ast.AstLiteral.Float
            (cfloat.compiler-float-format-f64
              (cfloat.compiler-float-round-f32-as-f64 n)))]
        [_ (ctfe-value-to-literal value)])]
    [(ast.AstType.Region _ inner)
      (ctfe-value-to-literal-for-type value (ast.ty-node-get inner))]
    [_ (ctfe-value-to-literal value)]))

(define (ctfe-type-list-eq-in-env
  [env : (& env CtfeEnv)]
  [a : ast.AstTypeList]
  [b : ast.AstTypeList]) : bool
  (let
    [pools : ast.AstNodePoolContext (ctfe-env-pools env)]
    [seg-bases : i64 (ast.ast-node-pool-context-type-segment-bases pools)]
    (ast.ast-type-id-list-eq? a b ast.ast-type-seg-ids-eq? seg-bases)))

(define (ctfe-type-eq-in-env
  [env : (& env CtfeEnv)]
  [a : ast.AstType]
  [b : ast.AstType]) : bool
  (ast.ast-type-eq-with-pools? (ctfe-env-pools env) a b))

(define (ctfe-type-list-eq [a : ast.AstTypeList] [b : ast.AstTypeList]) : bool
  (let
    [env : CtfeEnv (ctfe-env-empty)]
    (ctfe-type-list-eq-in-env env a b)))

(define (ctfe-type-eq [a : ast.AstType] [b : ast.AstType]) : bool
  (let
    [env : CtfeEnv (ctfe-env-empty)]
    (ctfe-type-eq-in-env env a b)))