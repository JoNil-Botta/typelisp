;; compiler_specialize.tl - Selfhost comptime function specialization.
(import stdlib.str_cat_runtime as str_cat)
(import compiler_parse_core as parser)
(import compiler_ast_types as ast)
(import compiler_ctfe as ctfe)
(import compiler_diagnostic as cdiag)
(import compiler_float as cfloat)
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as spec_id_i64_map)
(import compiler_intern as spec_ci)
(import compiler_builtin_ids as cbi)
(import compiler_owned_view as owned_view)

(define (compiler-specialize-decl-list-defines?
  [decls : (& decls ast.AstDeclList)]
  [name : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(Nil) false]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (ast.ast-decl-unwrapped decl)
          [(DefFn decl-meta fn-name _ _ _ _)
            (if (string.eq (spec_ci.intern-str fn-name) name)
              true
              (compiler-specialize-decl-list-defines? rest name))]
          [_ (compiler-specialize-decl-list-defines? rest name)]))]))

(import compiler_profile_state as profile_state)
(cfg (any compile-profile test) (import compiler_profile_counters as counters))

;; Specialization contexts are immutable handles over arena-backed compiler
;; storage. Recursive helpers borrow the handle and make shallow views only when
;; an owned value must cross an existing by-value API boundary.
(defmacro (spec-place-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(defmacro (spec-array-shared-view [items : Expr] [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (__tl_array-data ,items) ,index))))

(defmacro (spec-array-address [items : Expr]) : Expr
  `(let
    [shared-ref (& ,items)]
    (unsafe
      (ptr-read (ptr-cast (__tl_array-data (array shared-ref)) : (Ptr u64))))))

(defstruct GenRegistry
  (index spec_id_i64_map.Map)
  (decls (__tl_dyn-array ast.AstDecl))
  (len i64))

(defenum SpecTemplate
  (Item i64 ast.AstParamList ast.AstType ast.AstExpr))

;; Templates are collected once per program and then only counted and indexed,
;; so the collection is one contiguous buffer plus a live count.
(defstruct SpecTemplateList
  (slots (__tl_dyn-array SpecTemplate))
  (len i64))

(defenum SpecMaybeTemplate
  (None)
  (Some SpecTemplate))

;; Shadow snapshots form a persistent tree of dense slots. Each lexical child
;; appends one `(template slot, parent, depth)` record; siblings retain their
;; own head index without allocating a boxed name chain. `counts` caches the
;; currently activated head so template lookup stays O(1), while `scratch`
;; switches between retained sibling/nested snapshots without allocating.
(defstruct SpecTemplateShadowStateData
  (slots (__tl_dyn-array i64))
  (parents (__tl_dyn-array i64))
  (depths (__tl_dyn-array i64))
  (counts (__tl_dyn-array i64))
  (scratch (__tl_dyn-array i64))
  (len i64)
  (active-head i64))

(defstruct SpecTemplateShadowState
  (address i64))

(defstruct SpecTemplateEnvData
  (index spec_id_i64_map.Map)
  (values (__tl_dyn-array SpecMaybeTemplate))
  (shadow-state SpecTemplateShadowState)
  (shadow-head i64))

(defstruct SpecTemplateEnv
  (address u64))

(define (spec-template-env-new
  [index : spec_id_i64_map.Map]
  [values : (__tl_dyn-array SpecMaybeTemplate)]
  [shadow-state : SpecTemplateShadowState]
  [shadow-head : i64]) : SpecTemplateEnv
  (let
    [cell : (__tl_dyn-array SpecTemplateEnvData)
      (__tl_make-array
        (SpecTemplateEnvData index values shadow-state shadow-head))]
    (SpecTemplateEnv
      (unsafe
        (ptr->int (__tl_array-data cell))))))

(define (spec-template-env-data [templates : SpecTemplateEnv]) : SpecTemplateEnvData
  (unsafe
    (ptr-read (int->ptr templates.address : (Ptr SpecTemplateEnvData)))))

;; Comptime argument vectors and the two substitution environments keep their
;; head at slot 0, so every lookup scans forward from the newest binding and
;; shadowing still resolves head-first. `cons` copies into a right-sized buffer
;; so an inner instantiation can never write into the slot of an outer subst
;; that is still in use; the lists are one entry per comptime parameter.
(defstruct SpecValueList
  (slots (__tl_dyn-array ctfe.CompilerCtfeValue))
  (len i64))

;; A generated function symbol is a normal one-word name handle backed by this
;; session-owned structural recipe until the specialization-to-lowering text
;; boundary materializes its deterministic spelling. Recipes form a transient
;; queue, not persistent snapshots, so keep them in one dense growable buffer.
(defstruct SpecGeneratedSymbolRecord
  (structural-key i64)
  (handle i64)
  (template-name String)
  (values SpecValueList))

(defstruct SpecGeneratedSymbolRecords
  (slots (__tl_dyn-array SpecGeneratedSymbolRecord))
  (len i64))

;; All production specialization work is anchored to one compile-job owner.
;; Expression reads use the stable segment-bases snapshot; pushes and type
;; reads/construction continue through the explicit pool context because the
;; type segment table may be replaced by hash-consing growth.
(cfg
  (any compile-profile test)
  (defstruct SpecOwnerContext
    (pools (__tl_dyn-array ast.AstNodePoolContext))
    (expr-segment-bases i64)
    (intern-state (__tl_dyn-array spec_ci.InternCompatState))
    (generated-symbol-records (__tl_dyn-array SpecGeneratedSymbolRecords))
    (profile-metrics profile_state.CompilerProfileMetrics)))

(cfg
  (not (any compile-profile test))
  (defstruct SpecOwnerContext
    (pools (__tl_dyn-array ast.AstNodePoolContext))
    (expr-segment-bases i64)
    (intern-state (__tl_dyn-array spec_ci.InternCompatState))
    (generated-symbol-records (__tl_dyn-array SpecGeneratedSymbolRecords))))

(define (spec-owner-context-new-with-profile-state
  [pools : ast.AstNodePoolContext]
  [intern-state : spec_ci.InternCompatState]
  [_state : profile_state.CompilerProfileState]) : SpecOwnerContext
  (let
    [expr-segment-bases : i64
      (ast.ast-node-pool-context-expr-segment-bases pools)]
    [records : (__tl_dyn-array SpecGeneratedSymbolRecords)
      (__tl_make-array SpecGeneratedSymbolRecords 1)]
    (begin
      (set!
        (array-ref records 0)
        (SpecGeneratedSymbolRecords
          (__tl_make-array SpecGeneratedSymbolRecord 0)
          0))
      (cfg
        (any compile-profile test)
        (SpecOwnerContext
          (__tl_make-array pools)
          expr-segment-bases
          (__tl_make-array intern-state)
          records
          (profile_state.compiler-profile-state-metrics _state))
        (SpecOwnerContext
          (__tl_make-array pools)
          expr-segment-bases
          (__tl_make-array intern-state)
          records)))))

(define (spec-owner-context-new
  [pools : ast.AstNodePoolContext]
  [intern-state : (& intern-state spec_ci.InternCompatState)]) : SpecOwnerContext
  (cfg
    (any compile-profile test)
    (spec-owner-context-new-with-profile-state
      pools
      (owned_view.compiler-owned-reference-shared-view intern-state)
      (profile_state.compiler-profile-state-new))
    (let
      [intern-state : spec_ci.InternCompatState
        (owned_view.compiler-owned-reference-shared-view intern-state)]
      [expr-segment-bases : i64
        (ast.ast-node-pool-context-expr-segment-bases (& pools))]
      [records : (__tl_dyn-array SpecGeneratedSymbolRecords)
        (__tl_make-array SpecGeneratedSymbolRecords 1)]
      (set!
        (array-ref records 0)
        (SpecGeneratedSymbolRecords
          (__tl_make-array SpecGeneratedSymbolRecord 0)
          0))
      (SpecOwnerContext
        (__tl_make-array pools)
        expr-segment-bases
        (__tl_make-array intern-state)
        records))))

(define (spec-generated-symbol-records-copy-range
  [dst : (&mut dst (__tl_dyn-array SpecGeneratedSymbolRecord))]
  [src : (& src (__tl_dyn-array SpecGeneratedSymbolRecord))]
  [index : i64]
  [count : i64]) : unit
  (unless
    (>= index count)
    (set! (array-ref dst index) (array-ref src index))
    (spec-generated-symbol-records-copy-range dst src (+ index 1) count)))

(define (spec-generated-symbol-records-grow!
  [records : (&mut records SpecGeneratedSymbolRecords)]) : unit
  (let
    [count : i64 records.len]
    [bigger : (__tl_dyn-array SpecGeneratedSymbolRecord)
      (__tl_make-array SpecGeneratedSymbolRecord (+ (* count 2) 8))]
    (spec-generated-symbol-records-copy-range
      (&mut bigger)
      (& records.slots)
      0
      count)
    (set! records.slots bigger)))

(define (spec-generated-symbol-records-push!
  [records : (&mut records SpecGeneratedSymbolRecords)]
  [item : SpecGeneratedSymbolRecord]) : unit
  (if (< records.len (array-length records.slots))
    unit
    (spec-generated-symbol-records-grow! records))
  (let
    [count : i64 records.len]
    (set! (array-ref records.slots count) item)
    (set! records.len (+ count 1))))

(define (spec-generated-symbol-records-clear!
  [records : (&mut records SpecGeneratedSymbolRecords)]) : unit
  (set! records.len 0))

(define (spec-owner-pools [owner : (& owner SpecOwnerContext)]) : ast.AstNodePoolContext
  (owned_view.compiler-owned-array-element-shared-view owner.pools 0))

(define (spec-owner-intern-state [owner : (& owner SpecOwnerContext)]) : spec_ci.InternCompatState
  (owned_view.compiler-owned-array-element-shared-view owner.intern-state 0))

(cfg
  (any compile-profile test)
  (define (spec-owner-profile-metrics [owner : (& owner SpecOwnerContext)]) : profile_state.CompilerProfileMetrics
    (owned_view.compiler-owned-reference-shared-view (& owner.profile-metrics))))

(define (spec-owner-expr-get [owner : (& owner SpecOwnerContext)] [id : i64]) : ast.AstExpr
  (ast.ast-expr-segment-bases-get owner.expr-segment-bases id))

(define (spec-owner-type-get [owner : (& owner SpecOwnerContext)] [id : i64]) : ast.AstType
  (ast.ast-node-pool-context-type-get (& (array-ref owner.pools 0)) id))

(define (spec-owner-expr-push
  [owner : (& owner SpecOwnerContext)]
  [node : ast.AstExpr]) : i64
  (ast.ast-node-pool-context-expr-push
    (owned_view.compiler-owned-array-element-shared-view owner.pools 0)
    node))

(define (spec-owner-type-push
  [owner : (& owner SpecOwnerContext)]
  [node : ast.AstType]) : i64
  (ast.ast-node-pool-context-type-push
    (owned_view.compiler-owned-array-element-shared-view owner.pools 0)
    node))

(define (spec-owner-ctfe-env
  [owner : (& owner SpecOwnerContext)]
  [reflections : ctfe.CtfeReflectInfoList]) : ctfe.CtfeEnv
  (let
    [intern-state : spec_ci.InternCompatState (spec-owner-intern-state owner)]
    (ctfe.ctfe-env-with-reflections-and-pools-and-source-names
      reflections
      (spec-owner-pools owner)
      (spec_ci.intern-source-name-session-handle-from-state intern-state))))

;; The specialization cache maps a canonical structural-key handle directly to
;; its session-owned generated-symbol handle.
(defenum SpecState
  (State ast.AstDeclList spec_id_i64_map.Map ctfe.CtfeEnv SpecOwnerContext))

;; Specialization identity is a one-word handle into the compile session's
;; canonical structural table. The handle is intentionally distinct from an
;; interned renderable name: cache lookup must never require mangling text.
(defstruct SpecStructuralKey
  (value i64))

(defmacro (spec-structural-key-raw [key : Expr]) : i64
  `(__tl-project-field-name ,key "value"))

(cfg
  (any compile-profile test)
  (counters.defslots
    spec-profile
    39
    (spec-profile-structural-key-created-metric
      "lower.specialization.structural_keys.created"
      live)
    (spec-profile-structural-key-reused-metric
      "lower.specialization.structural_keys.reused"
      live)
    (spec-profile-generated-text-materialized-metric
      "lower.specialization.generated_text.materialized"
      live)
    (spec-profile-name-render-calls-metric
      "lower.specialization.render.calls"
      live)
    (spec-profile-name-render-cache-hits-metric
      "lower.specialization.render.cache_hits"
      live)
    (spec-profile-name-render-cache-misses-metric
      "lower.specialization.render.cache_misses"
      live)))

(define (spec-profile-reset! [_state : profile_state.CompilerProfileState]) : unit
  (cfg
    (any compile-profile test)
    (profile_state.compiler-profile-state-metric-reset-range!
      _state
      spec-profile-structural-key-created-metric
      spec-profile-end)
    unit))

(define (spec-profile-note-generated-text-materialized
  [_metrics : profile_state.CompilerProfileMetrics]) : unit
  (cfg
    (any compile-profile test)
    (profile_state.compiler-profile-metrics-add!
      _metrics
      spec-profile-generated-text-materialized-metric
      1)
    unit))

(define (spec-profile-note-structural-key
  [_metrics : profile_state.CompilerProfileMetrics]
  [_created? : bool]) : unit
  (cfg
    (any compile-profile test)
    (if _created?
      (profile_state.compiler-profile-metrics-add!
        _metrics
        spec-profile-structural-key-created-metric
        1)
      (profile_state.compiler-profile-metrics-add!
        _metrics
        spec-profile-structural-key-reused-metric
        1))
    unit))

(define (spec-profile-note-name-render
  [_metrics : profile_state.CompilerProfileMetrics]
  [_cache-hit? : bool]) : unit
  (cfg
    (any compile-profile test)
    (begin
      (profile_state.compiler-profile-metrics-add!
        (owned_view.compiler-owned-shared-view _metrics)
        spec-profile-name-render-calls-metric
        1)
      (if _cache-hit?
        (profile_state.compiler-profile-metrics-add!
          _metrics
          spec-profile-name-render-cache-hits-metric
          1)
        (profile_state.compiler-profile-metrics-add!
          _metrics
          spec-profile-name-render-cache-misses-metric
          1)))
    unit))

(defenum SpecValueBinding
  (Bind i64 ctfe.CompilerCtfeValue))

(defstruct SpecValueSubst
  (slots-address u64)
  (len i64))

(defenum SpecTypeBinding
  (Bind i64 ast.AstType))

(defstruct SpecTypeSubst
  (slots-address u64)
  (len i64))

(define (spec-value-subst-from-slots
  [slots : (__tl_dyn-array SpecValueBinding)]
  [len : i64]) : SpecValueSubst
  (SpecValueSubst
    (unsafe
      (ptr->int (__tl_array-data slots)))
    len))

(define (spec-type-subst-from-slots
  [slots : (__tl_dyn-array SpecTypeBinding)]
  [len : i64]) : SpecTypeSubst
  (SpecTypeSubst
    (unsafe
      (ptr->int (__tl_array-data slots)))
    len))

(define (spec-value-subst-at [subs : (& subs SpecValueSubst)] [index : i64]) : SpecValueBinding
  (unsafe
    (ptr-read
      (ptr-offset (int->ptr subs.slots-address : (Ptr SpecValueBinding)) index))))

(define (spec-type-subst-at [subs : (& subs SpecTypeSubst)] [index : i64]) : SpecTypeBinding
  (unsafe
    (ptr-read
      (ptr-offset (int->ptr subs.slots-address : (Ptr SpecTypeBinding)) index))))

(define (spec-template-list-new) : SpecTemplateList
  (SpecTemplateList (__tl_make-array SpecTemplate 0) 0))

(define (spec-template-list-copy-range
  [dst : (&mut dst (__tl_dyn-array SpecTemplate))]
  [src : (& src (__tl_dyn-array SpecTemplate))]
  [index : i64]
  [count : i64]) : unit
  (unless
    (>= index count)
    (set! (array-ref dst index) (array-ref src index))
    (spec-template-list-copy-range dst src (+ index 1) count)))

(define (spec-template-list-grow
  [templates : (&mut templates SpecTemplateList)]) : unit
  (let
    [count : i64 templates.len]
    [bigger : (__tl_dyn-array SpecTemplate)
      (__tl_make-array SpecTemplate (+ (* count 2) 8))]
    (spec-template-list-copy-range (&mut bigger) (& templates.slots) 0 count)
    (set! templates.slots bigger)))

(define (spec-template-list-push
  [templates : (&mut templates SpecTemplateList)]
  [item : SpecTemplate]) : unit
  (if (< templates.len (array-length templates.slots))
    unit
    (spec-template-list-grow templates))
  (let
    [count : i64 templates.len]
    (set! (array-ref templates.slots count) item)
    (set! templates.len (+ count 1))))

(define (spec-value-list-new) : SpecValueList
  (SpecValueList (__tl_make-array ctfe.CompilerCtfeValue 0) 0))

(define (spec-value-cons [head : ctfe.CompilerCtfeValue] [rest : SpecValueList]) : SpecValueList
  (let
    [count : i64 rest.len]
    [slots : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (__tl_make-array ctfe.CompilerCtfeValue (+ count 1))]
    [at : i64 0]
    (set! (array-ref slots 0) head)
    (while (< at count)
      (set! (array-ref slots (+ at 1)) (array-ref rest.slots at))
      (set! at (+ at 1)))
    (SpecValueList slots (+ count 1))))

(define (spec-value-subst-new) : SpecValueSubst
  (spec-value-subst-from-slots (__tl_make-array SpecValueBinding 0) 0))

(define (spec-value-subst-cons
  [key-id : i64]
  [value : ctfe.CompilerCtfeValue]
  [rest : SpecValueSubst]) : SpecValueSubst
  (let
    [count : i64 rest.len]
    [slots : (__tl_dyn-array SpecValueBinding)
      (__tl_make-array SpecValueBinding (+ count 1))]
    [at : i64 0]
    (set! (array-ref slots 0) (SpecValueBinding.Bind key-id value))
    (while (< at count)
      (set! (array-ref slots (+ at 1)) (spec-value-subst-at (& rest) at))
      (set! at (+ at 1)))
    (spec-value-subst-from-slots slots (+ count 1))))

(define (spec-type-subst-new) : SpecTypeSubst
  (spec-type-subst-from-slots (__tl_make-array SpecTypeBinding 0) 0))

(define (spec-value-subst-shared-view [subs : (& subs SpecValueSubst)]) : SpecValueSubst
  (SpecValueSubst subs.slots-address subs.len))

(define (spec-type-subst-shared-view [subs : (& subs SpecTypeSubst)]) : SpecTypeSubst
  (SpecTypeSubst subs.slots-address subs.len))

(define (spec-type-subst-cons
  [key-id : i64]
  [ty : ast.AstType]
  [rest : SpecTypeSubst]) : SpecTypeSubst
  (let
    [count : i64 rest.len]
    [slots : (__tl_dyn-array SpecTypeBinding)
      (__tl_make-array SpecTypeBinding (+ count 1))]
    [at : i64 0]
    (set! (array-ref slots 0) (SpecTypeBinding.Bind key-id ty))
    (while (< at count)
      (set! (array-ref slots (+ at 1)) (spec-type-subst-at (& rest) at))
      (set! at (+ at 1)))
    (spec-type-subst-from-slots slots (+ count 1))))

(defenum SpecMaybeString
  (None)
  (Some String))

(defenum SpecMaybeId
  (None)
  (Some i64))

(defenum SpecMaybeDecl
  (None)
  (Some ast.AstDecl))

(defenum SpecMaybeSourceSpan
  (None)
  (Some ast.AstSourceSpan))

(defenum ResultSpecProgram
  (Ok ast.AstProgram)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecProgramWithPaths
  (Ok ast.AstProgram ast.AstDeclPathList)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecDecls
  (Ok ast.AstDeclList SpecState)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecDeclsWithPaths
  (Ok ast.AstDeclList ast.AstDeclPathList SpecState)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecDecl
  (Ok SpecMaybeDecl SpecState)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecExpr
  (Ok i64 SpecState)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecExprList
  (Ok ast.AstExprList SpecState)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecExprListBuild
  (Ok SpecState)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecLetBindingList
  (Ok ast.AstLetBindingList SpecState)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecLetBindingListBuild
  (Ok SpecState)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecMatchArmList
  (Ok ast.AstMatchArmList SpecState)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecMatchArmListBuild
  (Ok SpecState)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecArgs
  (Ok SpecValueList ast.AstExprList SpecState)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecEnsure
  (Ok i64 SpecState)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecBuild
  (Ok ast.AstParamList SpecValueSubst SpecTypeSubst)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecSubExpr
  (Ok i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecSubExprList
  (Ok ast.AstExprList)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecSubExprListBuild
  (Ok)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecSubLetBindingList
  (Ok ast.AstLetBindingList)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecSubLetBindingListBuild
  (Ok)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecSubMatchArmList
  (Ok ast.AstMatchArmList)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultSpecSubMatchArmListBuild
  (Ok)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum GenMaybeEntry
  (None)
  (Some ast.AstDecl))

(defenum ResultGenKey
  (Ok String i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultGenDecl
  (Ok ast.AstDeclList GenRegistry i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultGenDecls
  (Ok ast.AstDeclList GenRegistry i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultGenProgram
  (Ok ast.AstProgram)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultGenDeclsWithPaths
  (Ok ast.AstDeclList ast.AstDeclPathList GenRegistry i64)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultGenProgramWithPaths
  (Ok ast.AstProgram ast.AstDeclPathList)
  (Err (Box cdiag.CompilerDiagnostic)))

(define (spec-diagnostic-at-expr [expr : ast.AstExpr] [message : String]) : cdiag.CompilerDiagnostic
  (match expr
    [(Spanned _ span) (cdiag.compiler-diagnostic-from-ast-span "" span message)]
    [_ (cdiag.compiler-diagnostic-at-start "" message)]))

(define (spec-expr-maybe-span-with-owner
  [owner : (& owner SpecOwnerContext)]
  [expr : ast.AstExpr]) : SpecMaybeSourceSpan
  (match expr
    [(Spanned _ span) (Some span)]
    [(Unary _ inner)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner inner))]
    [(Ann inner _)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner inner))]
    [(Cast inner _)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner inner))]
    [(Borrow _ _ inner)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner inner))]
    [_ (None)]))

(define (spec-expr-list-maybe-span-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]) : SpecMaybeSourceSpan
  (if (>= index (ast.ast-expr-list-len exprs))
    (None)
    (match (spec-expr-maybe-span-with-owner
      owner
      (spec-owner-expr-get owner (ast.ast-expr-list-get exprs index 0)))
      [(Some span) (Some span)]
      [(None) (spec-expr-list-maybe-span-at-with-owner owner exprs (+ index 1))])))

(define (spec-expr-list-maybe-span-with-owner
  [owner : (& owner SpecOwnerContext)]
  [exprs : ast.AstExprList]) : SpecMaybeSourceSpan
  (spec-expr-list-maybe-span-at-with-owner owner (& exprs) 0))

(define (spec-decl-maybe-span-with-owner
  [owner : (& owner SpecOwnerContext)]
  [decl : ast.AstDecl]) : SpecMaybeSourceSpan
  (match decl
    [(Def decl-meta _ _ body)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner body))]
    [(DefFn decl-meta _ _ _ body _)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner body))]
    [(DefMacro decl-meta _ _ _ body)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner body))]
    [(Test _ _ _ span) (Some span)]
    [(Unsafe inner-box)
      (spec-decl-maybe-span-with-owner
        owner
        (ast.ast-decl-box-shared-view inner-box))]
    [_ (None)]))

(define (spec-generated-origin-diagnostic-with-owner
  [owner : (& owner SpecOwnerContext)]
  [template : ast.AstDecl]
  [args : ast.AstExprList]
  [message : String]) : cdiag.CompilerDiagnostic
  (match (spec-decl-maybe-span-with-owner owner template)
    [(Some span) (cdiag.compiler-diagnostic-from-ast-span "" span message)]
    [(None)
      (match (spec-expr-list-maybe-span-with-owner owner args)
        [(Some span) (cdiag.compiler-diagnostic-from-ast-span "" span message)]
        [(None) (cdiag.compiler-diagnostic-at-start "" message)])]))

(define (spec-generated-context-diagnostic-with-owner
  [_owner : (& _owner SpecOwnerContext)]
  [diag : cdiag.CompilerDiagnostic]
  [generator : String]
  [item : String]
  [key : String]) : cdiag.CompilerDiagnostic
  (let
    [with-declaration : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-note
        diag
        (str_cat.str-cat "generated declaration: " item " from " generator))]
    (if (> (string.string-length key) 0)
      (cdiag.compiler-diagnostic-with-note
        with-declaration
        (str_cat.str-cat "generated identity: " key))
      with-declaration)))

(define (spec-param-comptime? [param : ast.AstParam]) : bool
  (match param
    [(Param _ _ is-comptime) is-comptime]))

(define (spec-param-name-id [param : ast.AstParam]) : i64
  (match param
    [(Param name _ _) name]))

(define (spec-state-ctfe-env [state : (& state SpecState)]) : ctfe.CtfeEnv
  (match state
    [(SpecState.State _ _ env _) (owned_view.compiler-owned-pattern-copy env)]))

(define (spec-state-owner [state : (& state SpecState)]) : (&
    state
    SpecOwnerContext)
  (match state
    [(State _ _ _ owner) owner]))

(define (spec-state-pools [state : (& state SpecState)]) : ast.AstNodePoolContext
  (spec-owner-pools (spec-state-owner state)))

(define (spec-state-intern [state : (& state SpecState)]) : spec_ci.InternCompatState
  (spec-owner-intern-state (spec-state-owner state)))

(define (spec-state-expr-get [state : (& state SpecState)] [id : i64]) : ast.AstExpr
  (spec-owner-expr-get (spec-state-owner state) id))

(define (spec-ctfe-eval
  [state : (& state SpecState)]
  [expr : ast.AstExpr]
  [fuel : i64]) : ctfe.ResultCtfe
  (let
    [ctfe-env : ctfe.CtfeEnv (spec-state-ctfe-env state)]
    (ctfe.compiler-ctfe-eval expr ctfe-env fuel)))

(define (spec-type-kind? [ty : ast.AstType]) : bool
  (cbi.compiler-builtin-refresh!)
  (match ty
    [(Var name) (= name cbi.compiler-builtin-id-fix-type)]
    [_ false]))

(define (spec-param-list-has-comptime? [params : (& params ast.AstParamList)]) : bool
  (spec-param-list-has-comptime-at? params 0))

(define (spec-param-list-has-comptime-at?
  [params : (& params ast.AstParamList)]
  [index : i64]) : bool
  (if (>= index (ast.ast-param-list-len params))
    false
    (if (spec-param-comptime?
      (ast.ast-param-list-get params index (ast.ast-param-fallback)))
      true
      (spec-param-list-has-comptime-at? params (+ index 1)))))

(define (spec-template-shadow-copy-range
  [dst : (&mut dst (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [index : i64]
  [count : i64]) : unit
  (unless
    (>= index count)
    (set! (array-ref dst index) (array-ref src index))
    (spec-template-shadow-copy-range dst src (+ index 1) count)))

(define (spec-template-shadow-fill-zero
  [slots : (&mut slots (__tl_dyn-array i64))]
  [index : i64]) : unit
  (unless
    (>= index (array-length slots))
    (set! (array-ref slots index) 0)
    (spec-template-shadow-fill-zero slots (+ index 1))))

(define (spec-template-shadow-state-view [state : SpecTemplateShadowState]) : (Ptr
    SpecTemplateShadowStateData)
  (unsafe
    (int->ptr (cast state.address : u64) : (Ptr SpecTemplateShadowStateData))))

(define (spec-template-shadow-state-data [state : SpecTemplateShadowState]) : SpecTemplateShadowStateData
  (unsafe
    (ptr-read
      (int->ptr (cast state.address : u64) : (Ptr SpecTemplateShadowStateData)))))

(define (spec-template-shadow-state-data-set!
  [state : SpecTemplateShadowState]
  [data : SpecTemplateShadowStateData]) : unit
  (unsafe
    (ptr-write!
      (int->ptr
        (cast state.address : u64)
        : (MutPtr SpecTemplateShadowStateData))
      data)))

(define (spec-template-shadow-state-new [template-count : i64]) : SpecTemplateShadowState
  (let
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 template-count)]
    [cell : (__tl_dyn-array SpecTemplateShadowStateData)
      (__tl_make-array SpecTemplateShadowStateData 1)]
    (spec-template-shadow-fill-zero (&mut counts) 0)
    (set!
      (array-ref cell 0)
      (SpecTemplateShadowStateData
        (__tl_make-array i64 8)
        (__tl_make-array i64 8)
        (__tl_make-array i64 8)
        counts
        (__tl_make-array i64 8)
        0
        -1))
    (SpecTemplateShadowState
      (cast
        (unsafe
          (ptr->int
            (ptr-cast
              (__tl_array-data cell)
              : (Ptr SpecTemplateShadowStateData))))
        : i64))))

(define (spec-template-shadow-state-grow-records
  [data : SpecTemplateShadowStateData]) : SpecTemplateShadowStateData
  (let
    [count : i64 data.len]
    [next-capacity : i64 (+ (* (array-length data.slots) 2) 8)]
    [next-slots : (__tl_dyn-array i64) (__tl_make-array i64 next-capacity)]
    [next-parents : (__tl_dyn-array i64) (__tl_make-array i64 next-capacity)]
    [next-depths : (__tl_dyn-array i64) (__tl_make-array i64 next-capacity)]
    (spec-template-shadow-copy-range (&mut next-slots) (& data.slots) 0 count)
    (spec-template-shadow-copy-range
      (&mut next-parents)
      (& data.parents)
      0
      count)
    (spec-template-shadow-copy-range (&mut next-depths) (& data.depths) 0 count)
    (SpecTemplateShadowStateData
      next-slots
      next-parents
      next-depths
      data.counts
      data.scratch
      data.len
      data.active-head)))

(define (spec-template-shadow-state-grow-scratch
  [data : SpecTemplateShadowStateData]
  [count : i64]) : SpecTemplateShadowStateData
  (let
    [next : (__tl_dyn-array i64)
      (__tl_make-array i64 (+ (* (array-length data.scratch) 2) 8))]
    (spec-template-shadow-copy-range (&mut next) (& data.scratch) 0 count)
    (SpecTemplateShadowStateData
      data.slots
      data.parents
      data.depths
      data.counts
      next
      data.len
      data.active-head)))

(define (spec-template-shadow-state-depth
  [data : (& data SpecTemplateShadowStateData)]
  [head : i64]) : i64
  (if (< head 0)
    0
    (array-ref data.depths head)))

(define (spec-template-shadow-state-append
  [state : SpecTemplateShadowState]
  [parent : i64]
  [slot : i64]) : i64
  (let
    [data : SpecTemplateShadowStateData (spec-template-shadow-state-data state)]
    (if (< data.len (array-length data.slots))
      unit
      (set! data (spec-template-shadow-state-grow-records data)))
    (let
      [index : i64 data.len]
      (set! (array-ref data.slots index) slot)
      (set! (array-ref data.parents index) parent)
      (set!
        (array-ref data.depths index)
        (+ (spec-template-shadow-state-depth (& data) parent) 1))
      (set! data.len (+ index 1))
      (spec-template-shadow-state-data-set! state data)
      index)))

(define (spec-template-shadow-state-activate!
  [state : SpecTemplateShadowState]
  [wanted-head : i64]) : unit
  (let
    [data : SpecTemplateShadowStateData (spec-template-shadow-state-data state)]
    [current : i64 data.active-head]
    [wanted : i64 wanted-head]
    [scratch-len : i64 0]
    ;; Walk both retained snapshots to their common parent. Remove the old
    ;; path immediately and record the new path leaf-first in reusable dense
    ;; scratch storage, then apply it parent-first.
    (while (not (= current wanted))
      (let
        [current-depth : i64
          (spec-template-shadow-state-depth (& data) current)]
        [wanted-depth : i64 (spec-template-shadow-state-depth (& data) wanted)]
        (if (and (>= current-depth wanted-depth) (>= current 0))
          (let
            [slot : i64 (array-ref data.slots current)]
            (set!
              (array-ref data.counts slot)
              (- (array-ref data.counts slot) 1))
            (set! current (array-ref data.parents current)))
          unit)
        (when
          (and (>= wanted-depth current-depth) (>= wanted 0))
          (if (< scratch-len (array-length data.scratch))
            unit
            (set!
              data
              (spec-template-shadow-state-grow-scratch data scratch-len)))
          (set! (array-ref data.scratch scratch-len) wanted)
          (set! scratch-len (+ scratch-len 1))
          (set! wanted (array-ref data.parents wanted)))))
    (while (> scratch-len 0)
      (let
        [next-index : i64 (- scratch-len 1)]
        [node : i64 (array-ref data.scratch next-index)]
        [slot : i64 (array-ref data.slots node)]
        (set! (array-ref data.counts slot) (+ (array-ref data.counts slot) 1))
        (set! scratch-len next-index)))
    (set! data.active-head wanted-head)
    (spec-template-shadow-state-data-set! state data)))

(define (spec-template-shadow-state-slot-shadowed?
  [state : SpecTemplateShadowState]
  [head : i64]
  [slot : i64]) : bool
  (spec-template-shadow-state-activate! state head)
  (>
    (array-ref
      (unsafe
        (deref (spec-template-shadow-state-view state)).counts)
      slot)
    0))

(define (spec-template-values-fill-empty
  [values : (&mut values (__tl_dyn-array SpecMaybeTemplate))]
  [index : i64]
  [count : i64]) : unit
  (unless
    (>= index count)
    (set! (array-ref values index) (SpecMaybeTemplate.None))
    (spec-template-values-fill-empty values (+ index 1) count)))

(define (spec-template-index-build
  [templates : SpecTemplateList]
  [index : spec_id_i64_map.Map]
  [values : (&mut values (__tl_dyn-array SpecMaybeTemplate))]
  [at : i64]
  [slot : i64]) : spec_id_i64_map.Map
  (if (>= at templates.len)
    index
    (let
      [template : SpecTemplate (spec-array-shared-view templates.slots at)]
      (match (spec-place-shared-view template)
        [(Item name _ _ _)
          (if (spec_id_i64_map.contains? (& index) name)
            (spec-template-index-build templates index values (+ at 1) slot)
            (begin
              (set! (array-ref values slot) (SpecMaybeTemplate.Some template))
              (let
                [next-index : spec_id_i64_map.Map index]
                (spec_id_i64_map.insert-ref! (&mut next-index) name slot)
                (spec-template-index-build
                  templates
                  next-index
                  values
                  (+ at 1)
                  (+ slot 1)))))]))))

(define (spec-template-env-from-list [templates : SpecTemplateList]) : SpecTemplateEnv
  (let
    [count : i64 templates.len]
    [values : (__tl_dyn-array SpecMaybeTemplate)
      (__tl_make-array SpecMaybeTemplate count)]
    (spec-template-values-fill-empty (&mut values) 0 count)
    (spec-template-env-new
      (spec-template-index-build
        templates
        (spec_id_i64_map.with-capacity (+ (* count 2) 16))
        (&mut values)
        0
        0)
      values
      (spec-template-shadow-state-new count)
      -1)))

(define (spec-template-env-shared-view
  [templates : (& templates SpecTemplateEnv)]) : SpecTemplateEnv
  (SpecTemplateEnv templates.address))

(define (spec-template-lookup
  [templates : (& templates SpecTemplateEnv)]
  [name-id : i64]) : SpecMaybeTemplate
  (let
    [data : SpecTemplateEnvData
      (spec-template-env-data (SpecTemplateEnv templates.address))]
    (match (spec_id_i64_map.get (& data.index) name-id)
      [(LookupFound slot)
        (if (spec-template-shadow-state-slot-shadowed?
          data.shadow-state
          data.shadow-head
          slot)
          (None)
          (spec-array-shared-view data.values slot))]
      [(LookupMissing) (None)])))

(define (spec-template-env-shadow-name
  [templates : (& templates SpecTemplateEnv)]
  [name-id : i64]) : SpecTemplateEnv
  (let
    [data : SpecTemplateEnvData
      (spec-template-env-data (SpecTemplateEnv templates.address))]
    (match (spec_id_i64_map.get (& data.index) name-id)
      [(LookupFound slot)
        (spec-template-env-new
          data.index
          data.values
          data.shadow-state
          (spec-template-shadow-state-append
            data.shadow-state
            data.shadow-head
            slot))]
      ;; Names that cannot select a template need no shadow record.
      [(LookupMissing) (SpecTemplateEnv templates.address)])))

(define (spec-template-env-shadow-params
  [templates : (& templates SpecTemplateEnv)]
  [params : (& params ast.AstParamList)]) : SpecTemplateEnv
  (spec-template-env-shadow-params-at
    (spec-template-env-shared-view templates)
    params
    0))

(define (spec-template-env-shadow-params-at
  [templates : SpecTemplateEnv]
  [params : (& params ast.AstParamList)]
  [index : i64]) : SpecTemplateEnv
  (if (>= index (ast.ast-param-list-len params))
    templates
    (spec-template-env-shadow-params-at
      (spec-template-env-shadow-name
        templates
        (spec-param-name-id
          (ast.ast-param-list-get params index (ast.ast-param-fallback))))
      params
      (+ index 1))))

(define (spec-template-env-shadow-let-binding-names
  [templates : (& templates SpecTemplateEnv)]
  [bindings : (& bindings ast.AstLetBindingList)]) : SpecTemplateEnv
  (spec-template-env-shadow-let-binding-names-at
    (spec-template-env-shared-view templates)
    bindings
    0))

(define (spec-template-env-shadow-let-binding-names-at
  [templates : SpecTemplateEnv]
  [bindings : (& bindings ast.AstLetBindingList)]
  [index : i64]) : SpecTemplateEnv
  (if (>= index (ast.ast-let-binding-list-len bindings))
    templates
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(Binding name _ _)
        (spec-template-env-shadow-let-binding-names-at
          (spec-template-env-shadow-name templates name)
          bindings
          (+ index 1))])))

(define (spec-template-env-shadow-pattern
  [templates : (& templates SpecTemplateEnv)]
  [pattern : ast.AstPattern]) : SpecTemplateEnv
  (match pattern
    [(Var name _) (spec-template-env-shadow-name templates name)]
    [(Tuple patterns-box)
      (let
        [patterns : ast.AstPatternList
          (ast.ast-pattern-list-box-shared-view patterns-box)]
        (spec-template-env-shadow-pattern-list templates patterns))]
    [(Array patterns-box)
      (let
        [patterns : ast.AstPatternList
          (ast.ast-pattern-list-box-shared-view patterns-box)]
        (spec-template-env-shadow-pattern-list templates patterns))]
    [(Slice patterns-box _)
      (let
        [patterns : ast.AstPatternList
          (ast.ast-pattern-list-box-shared-view patterns-box)]
        (spec-template-env-shadow-pattern-list templates patterns))]
    [(Wildcard) (spec-template-env-shared-view templates)]
    [(Binding name) (spec-template-env-shadow-name templates name)]
    [(Variant _ patterns-box)
      (let
        [patterns : ast.AstPatternList
          (ast.ast-pattern-list-box-shared-view patterns-box)]
        (spec-template-env-shadow-pattern-list templates patterns))]
    [(Literal _) (spec-template-env-shared-view templates)]))

(define (spec-template-env-shadow-pattern-list
  [templates : (& templates SpecTemplateEnv)]
  [patterns : ast.AstPatternList]) : SpecTemplateEnv
  (spec-template-env-shadow-pattern-list-at
    (spec-template-env-shared-view templates)
    (& patterns)
    0))

(define (spec-template-env-shadow-pattern-list-at
  [templates : SpecTemplateEnv]
  [patterns : (& patterns ast.AstPatternList)]
  [index : i64]) : SpecTemplateEnv
  (if (>= index patterns.len)
    templates
    (spec-template-env-shadow-pattern-list-at
      (spec-template-env-shadow-pattern
        templates
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback)))
      patterns
      (+ index 1))))

(define (spec-collect-templates-with-pools
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]) : SpecTemplateList
  (let
    [cursor : ast.AstDeclList decls]
    [out : SpecTemplateList (spec-template-list-new)]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step cursor)
        [(Nil) (set! done true)]
        [(Cons decl rest)
          (match decl
            [(Unsafe inner-box)
              (match (ast.ast-decl-box-shared-view inner-box)
                [(DefFn decl-meta name params ret body-box _)
                  (if (spec-param-list-has-comptime? params)
                    (spec-template-list-push
                      (&mut out)
                      (Item
                        name
                        params
                        ret
                        (ast.ast-node-pool-context-expr-get pools body-box)))
                    unit)]
                [_ unit])]
            [(DefFn decl-meta name params ret body-box _)
              (if (spec-param-list-has-comptime? params)
                (spec-template-list-push
                  (&mut out)
                  (Item
                    name
                    params
                    ret
                    (ast.ast-node-pool-context-expr-get pools body-box)))
                unit)]
            [_ unit])
          (set! cursor rest)]))
    out))

(define (spec-decl-list-append-one
  [decls : ast.AstDeclList]
  [decl : ast.AstDecl]) : ast.AstDeclList
  (let
    [out : ast.AstDeclList
      (ast.ast-decl-list-with-capacity (+ (ast.ast-decl-list-len (& decls)) 1))]
    (ast.ast-decl-list-append-from (&mut out) (& decls) 0)
    (ast.ast-decl-list-push (&mut out) decl)
    out))

(define (spec-decl-list-append
  [front : ast.AstDeclList]
  [back : (& back ast.AstDeclList)]) : ast.AstDeclList
  (let
    [out : ast.AstDeclList
      (ast.ast-decl-list-with-capacity
        (+ (ast.ast-decl-list-len (& front)) (ast.ast-decl-list-len back)))]
    (ast.ast-decl-list-append-from (&mut out) (& front) 0)
    (ast.ast-decl-list-append-from (&mut out) back 0)
    out))

(define (spec-decl-path-list-append
  [front : ast.AstDeclPathList]
  [back : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [out : ast.AstDeclPathList
      (ast.ast-decl-path-list-with-capacity
        (+
          (ast.ast-decl-path-list-len (& front))
          (ast.ast-decl-path-list-len (& back))))]
    (ast.ast-decl-path-list-append-from (&mut out) (& front) 0)
    (ast.ast-decl-path-list-append-from (&mut out) (& back) 0)
    out))

(define (gen-single-decl-list [decl : ast.AstDecl]) : ast.AstDeclList
  (ast.ast-decl-cons decl (ast.ast-decl-list-new)))

(define (spec-int-key [n : i64]) : String
  (if (< n 0)
    (str_cat.str-cat "m" (string.int->string (- 0 n)))
    (string.int->string n)))

;; Build the "_<code>" tail into `buf` without re-copying the accumulated
;; prefix per character. A recursive string.append form costs O(n^2) per key,
;; and macro-identity-key-sexpr applies this to already-encoded sub-keys, so
;; deep syntax identities would allocate quadratically.
(define (spec-string-key-from-into
  [text : String]
  [idx : i64]
  [n : i64]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (if (>= idx n)
    buf
    (let
      [code : i64 (cast (string.string-ref text idx) : i64)]
      [next-buf : text_buf.TextBuf
        (text_buf.append-int (text_buf.append buf "_") code)]
      (spec-string-key-from-into text (+ idx 1) n next-buf))))

(define (spec-string-key [text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    (text_buf.render
      (spec-string-key-from-into
        text
        0
        n
        (text_buf.append-int (text_buf.append (text_buf.empty) "string_") n)))))

(define (spec-type-list-key-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [types : (& types ast.AstTypeList)]
  [index : i64]) : String
  (if (>= index (ast.ast-type-list-len types))
    "nil"
    (str_cat.str-cat
      (spec-type-key-with-owner
        owner
        (spec-owner-type-get
          owner
          (ast.ast-type-list-get types index (ast.ast-type-id-fallback))))
      "_"
      (spec-type-list-key-at-with-owner owner types (+ index 1)))))

(define (spec-type-list-key-with-owner
  [owner : (& owner SpecOwnerContext)]
  [types : ast.AstTypeList]) : String
  (spec-type-list-key-at-with-owner owner (& types) 0))

(define (spec-lifetime-list-key-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [lifetimes : (& lifetimes ast.AstLifetimeList)]
  [index : i64]) : String
  (if (>= index (ast.ast-lifetime-list-len lifetimes))
    "nil"
    (str_cat.str-cat
      (spec_ci.intern-compat-state-str
        (spec-owner-intern-state owner)
        (ast.ast-lifetime-list-get lifetimes index (ast.ast-lifetime-fallback)))
      "_"
      (spec-lifetime-list-key-at-with-owner owner lifetimes (+ index 1)))))

(define (spec-lifetime-list-key-with-owner
  [owner : (& owner SpecOwnerContext)]
  [lifetimes : ast.AstLifetimeList]) : String
  (spec-lifetime-list-key-at-with-owner owner (& lifetimes) 0))

(define (spec-type-key-with-owner
  [owner : (& owner SpecOwnerContext)]
  [ty : ast.AstType]) : String
  (match ty
    [(I64) "i64"]
    [(I32) "i32"]
    [(I16) "i16"]
    [(I8) "i8"]
    [(U64) "u64"]
    [(U32) "u32"]
    [(U16) "u16"]
    [(U8) "u8"]
    [(F64) "f64"]
    [(F32) "f32"]
    [(Bool) "bool"]
    [(Char) "char"]
    [(String) "String"]
    [(Str) "str"]
    [(Bytes) "bytes"]
    [(Unit) "unit"]
    [(Never) "never"]
    [(Expr) "Expr"]
    [(ExprList) "ExprList"]
    [(Func args ret)
      (str_cat.str-cat
        "fn_"
        (spec-type-list-key-with-owner
          owner
          (ast.ast-type-list-box-shared-view args))
        "_to_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner ret)))]
    [(CFunc signature mode)
      (str_cat.str-cat
        "cfn_"
        (ast.ast-c-function-mode-name mode)
        "_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner signature)))]
    [(Tuple elems)
      (str_cat.str-cat
        "tuple_"
        (spec-type-list-key-with-owner
          owner
          (ast.ast-type-list-box-shared-view elems)))]
    [(Array elem count)
      (str_cat.str-cat
        "array_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner elem))
        "_"
        (spec-int-key count))]
    [(DynArray elem)
      (str_cat.str-cat
        "dynarray_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner elem)))]
    [(Slice elem)
      (str_cat.str-cat
        "slice_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner elem)))]
    [(Box elem)
      (str_cat.str-cat
        "box_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner elem)))]
    [(Ptr elem)
      (str_cat.str-cat
        "ptr_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner elem)))]
    [(MutPtr elem)
      (str_cat.str-cat
        "mutptr_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner elem)))]
    [(Ref region inner)
      (str_cat.str-cat
        "ref_"
        (spec_ci.intern-compat-state-str (spec-owner-intern-state owner) region)
        "_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner inner)))]
    [(MutRef region inner)
      (str_cat.str-cat
        "mutref_"
        (spec_ci.intern-compat-state-str (spec-owner-intern-state owner) region)
        "_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner inner)))]
    [(Region region inner)
      (str_cat.str-cat
        "region_"
        (spec_ci.intern-compat-state-str (spec-owner-intern-state owner) region)
        "_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner inner)))]
    [(Invalidate lifetime inner)
      (str_cat.str-cat
        "invalidate_"
        (spec_ci.intern-compat-state-str
          (spec-owner-intern-state owner)
          lifetime)
        "_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner inner)))]
    [(Enum name)
      (str_cat.str-cat
        "enum_"
        (ast.ast-nominal-name-id-display-with-intern-state
          (spec-owner-intern-state owner)
          name))]
    [(EnumArgs name lifetimes)
      (str_cat.str-cat
        "enumargs_"
        (ast.ast-nominal-name-id-display-with-intern-state
          (spec-owner-intern-state owner)
          name)
        "_"
        (spec-lifetime-list-key-with-owner
          owner
          (ast.ast-lifetime-list-box-shared-view lifetimes)))]
    [(Struct name)
      (str_cat.str-cat
        "struct_"
        (ast.ast-nominal-name-id-display-with-intern-state
          (spec-owner-intern-state owner)
          name))]
    [(StructArgs name lifetimes)
      (str_cat.str-cat
        "structargs_"
        (ast.ast-nominal-name-id-display-with-intern-state
          (spec-owner-intern-state owner)
          name)
        "_"
        (spec-lifetime-list-key-with-owner
          owner
          (ast.ast-lifetime-list-box-shared-view lifetimes)))]
    [(Var name)
      (str_cat.str-cat
        "var_"
        (spec_ci.intern-compat-state-str (spec-owner-intern-state owner) name))]
    [(VarArgs name lifetimes)
      (str_cat.str-cat
        "varargs_"
        (spec_ci.intern-compat-state-str (spec-owner-intern-state owner) name)
        "_"
        (spec-lifetime-list-key-with-owner
          owner
          (ast.ast-lifetime-list-box-shared-view lifetimes)))]))

(define (spec-value-key-with-owner
  [owner : (& owner SpecOwnerContext)]
  [value : ctfe.CompilerCtfeValue]) : String
  (match value
    [(I64 n) (str_cat.str-cat "i64_" (spec-int-key n))]
    [(F64 n)
      (str_cat.str-cat
        "f64_"
        (spec-string-key (cfloat.compiler-float-format-f64 n)))]
    [(F32 n)
      (str_cat.str-cat
        "f32_"
        (spec-string-key
          (cfloat.compiler-float-format-f64
            (cfloat.compiler-float-round-f32-as-f64 n))))]
    [(Bool b)
      (if b
        "bool_1"
        "bool_0")]
    [(Char c) (str_cat.str-cat "char_" (string.int->string (cast c : i64)))]
    [(String text _) (spec-string-key text)]
    [(Name text _) (spec-string-key text)]
    [(Unit) "unit"]
    [(Type ty) (str_cat.str-cat "type_" (spec-type-key-with-owner owner ty))]
    [(Expr _ _) "Expr"]
    [(CapturedExpr _ _ _) "Expr"]
    [(ExprList _) "expr-list"]
    [(CapturedExprList _ _) "expr-list"]
    [(ExprClause _) "expr-clause"]
    [(CapturedExprClause _ _) "expr-clause"]
    [(ExprClauseList _) "expr-clause-list"]
    [(CapturedExprClauseList _ _) "expr-clause-list"]
    [(ExprBindingClause _) "expr-binding-clause"]
    [(ExprBindingClauseList _) "expr-binding-clause-list"]
    [(Pattern _) "pattern"]
    [(PatternList _) "pattern-list"]
    [(MatchArm _) "match-arm"]
    [(MatchArmList _) "match-arm-list"]
    [(LetBinding _) "let-binding"]
    [(LetBindingList _) "let-binding-list"]
    [(TypeInfo ty)
      (str_cat.str-cat "typeinfo_" (spec-type-key-with-owner owner ty))]
    [(TypeInfoBox ty)
      (str_cat.str-cat "typeinfo-box_" (spec-type-key-with-owner owner ty))]
    [(TypeInfoList _) "typeinfo-list"]
    [(TypeField _ _) "type-field"]
    [(TypeFieldList _) "type-field-list"]
    [(TypeVariantPayload _) "type-variant-payload"]
    [(TypeVariantPayloadList _) "type-variant-payload-list"]
    [(TypeVariant _ _) "type-variant"]
    [(TypeVariantList _) "type-variant-list"]))

(define (spec-values-key-with-owner-at
  [owner : (& owner SpecOwnerContext)]
  [values : (& values SpecValueList)]
  [at : i64]) : String
  (if (>= at values.len)
    "none"
    (str_cat.str-cat
      (spec-value-key-with-owner owner (spec-array-shared-view values.slots at))
      "_"
      (spec-values-key-with-owner-at owner values (+ at 1)))))

(define (spec-values-key-with-owner
  [owner : (& owner SpecOwnerContext)]
  [values : (& values SpecValueList)]) : String
  (spec-values-key-with-owner-at owner values 0))

(define (spec-specialized-name-with-owner
  [owner : (& owner SpecOwnerContext)]
  [name : String]
  [values : (& values SpecValueList)]) : String
  (str_cat.str-cat
    "__tl_specialized_"
    name
    "_"
    (spec-values-key-with-owner owner values)))

;; Structural specialization records use only the pair/triple record kinds
;; supplied by compiler_intern. A negative tag in the left lane gives every
;; node an explicit domain; the remaining lanes contain scalar payloads,
;; content atoms, or other session-owned structural handles.
(define (spec-structural-node-with-owner
  [owner : (& owner SpecOwnerContext)]
  [tag : i64]
  [left : i64]
  [right : i64]) : SpecStructuralKey
  (let
    [intern-state : spec_ci.InternCompatState (spec-owner-intern-state owner)]
    [_before : i64 (spec_ci.intern-compat-state-structural-count intern-state)]
    [raw : i64
      (spec_ci.intern-compat-state-composite-triple-id
        (&mut intern-state)
        tag
        left
        right)]
    (begin
      (cfg
        (any compile-profile test)
        (spec-profile-note-structural-key
          (spec-owner-profile-metrics owner)
          (>
            (spec_ci.intern-compat-state-structural-count intern-state)
            _before))
        unit)
      (SpecStructuralKey raw))))

(define (spec-structural-content-atom-with-owner
  [owner : (& owner SpecOwnerContext)]
  [text : String]) : i64
  ;; The enclosing structural tag defines the value domain. Canonicalizing the
  ;; bytes here deliberately ignores parser/generated provenance, matching the
  ;; old rendered-key equivalence without using a mangled String as identity.
  (let
    [intern-state : spec_ci.InternCompatState (spec-owner-intern-state owner)]
    (spec_ci.intern-compat-state-intern (&mut intern-state) text)))

(define (spec-structural-generated-text-atom-with-owner
  [owner : (& owner SpecOwnerContext)]
  [text : String]) : i64
  (let
    [intern-state : spec_ci.InternCompatState (spec-owner-intern-state owner)]
    (match (spec_ci.intern-compat-state-lookup intern-state text)
      [(InternLookupFound _) unit]
      [(InternLookupMissing)
        (cfg
          (any compile-profile test)
          (spec-profile-note-generated-text-materialized
            (spec-owner-profile-metrics owner))
          unit)])
    (spec_ci.intern-compat-state-intern (&mut intern-state) text)))

(define (spec-type-list-structural-key-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [types : (& types ast.AstTypeList)]
  [index : i64]) : SpecStructuralKey
  (if (>= index (ast.ast-type-list-len types))
    (SpecStructuralKey 0)
    (let
      [head : SpecStructuralKey
        (spec-type-structural-key-with-owner
          owner
          (spec-owner-type-get
            owner
            (ast.ast-type-list-get types index (ast.ast-type-id-fallback))))]
      [tail : SpecStructuralKey
        (spec-type-list-structural-key-at-with-owner owner types (+ index 1))]
      (spec-structural-node-with-owner
        owner
        -1
        (spec-structural-key-raw head)
        (spec-structural-key-raw tail)))))

(define (spec-type-list-structural-key-with-owner
  [owner : (& owner SpecOwnerContext)]
  [types : ast.AstTypeList]) : SpecStructuralKey
  (spec-type-list-structural-key-at-with-owner owner (& types) 0))

(define (spec-lifetime-list-structural-key-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [lifetimes : (& lifetimes ast.AstLifetimeList)]
  [index : i64]) : SpecStructuralKey
  (if (>= index (ast.ast-lifetime-list-len lifetimes))
    (SpecStructuralKey 0)
    (let
      [name-id : i64
        (ast.ast-lifetime-list-get lifetimes index (ast.ast-lifetime-fallback))]
      [atom : i64
        (spec-structural-content-atom-with-owner
          owner
          (spec_ci.intern-compat-state-str
            (spec-owner-intern-state owner)
            name-id))]
      [tail : SpecStructuralKey
        (spec-lifetime-list-structural-key-at-with-owner
          owner
          lifetimes
          (+ index 1))]
      (spec-structural-node-with-owner
        owner
        -2
        atom
        (spec-structural-key-raw tail)))))

(define (spec-lifetime-list-structural-key-with-owner
  [owner : (& owner SpecOwnerContext)]
  [lifetimes : ast.AstLifetimeList]) : SpecStructuralKey
  (spec-lifetime-list-structural-key-at-with-owner owner (& lifetimes) 0))

(define (spec-type-structural-key-with-owner
  [owner : (& owner SpecOwnerContext)]
  [ty : ast.AstType]) : SpecStructuralKey
  (match ty
    [(I64) (spec-structural-node-with-owner owner -100 0 0)]
    [(I32) (spec-structural-node-with-owner owner -101 0 0)]
    [(I16) (spec-structural-node-with-owner owner -102 0 0)]
    [(I8) (spec-structural-node-with-owner owner -103 0 0)]
    [(U64) (spec-structural-node-with-owner owner -104 0 0)]
    [(U32) (spec-structural-node-with-owner owner -105 0 0)]
    [(U16) (spec-structural-node-with-owner owner -106 0 0)]
    [(U8) (spec-structural-node-with-owner owner -107 0 0)]
    [(F64) (spec-structural-node-with-owner owner -108 0 0)]
    [(F32) (spec-structural-node-with-owner owner -109 0 0)]
    [(Bool) (spec-structural-node-with-owner owner -110 0 0)]
    [(Char) (spec-structural-node-with-owner owner -111 0 0)]
    [(String) (spec-structural-node-with-owner owner -112 0 0)]
    [(Str) (spec-structural-node-with-owner owner -113 0 0)]
    [(Bytes) (spec-structural-node-with-owner owner -114 0 0)]
    [(Unit) (spec-structural-node-with-owner owner -115 0 0)]
    [(Never) (spec-structural-node-with-owner owner -116 0 0)]
    [(Expr) (spec-structural-node-with-owner owner -117 0 0)]
    [(ExprList) (spec-structural-node-with-owner owner -118 0 0)]
    [(Func args ret)
      (let
        [arg-key : SpecStructuralKey
          (spec-type-list-structural-key-with-owner
            owner
            (ast.ast-type-list-box-shared-view args))]
        [ret-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner ret))]
        (spec-structural-node-with-owner
          owner
          -119
          (spec-structural-key-raw arg-key)
          (spec-structural-key-raw ret-key)))]
    [(CFunc signature mode)
      (let
        [signature-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner signature))]
        (spec-structural-node-with-owner
          owner
          -138
          (spec-structural-key-raw signature-key)
          (ast.ast-c-function-mode-key mode)))]
    [(Tuple elems)
      (let
        [elem-key : SpecStructuralKey
          (spec-type-list-structural-key-with-owner
            owner
            (ast.ast-type-list-box-shared-view elems))]
        (spec-structural-node-with-owner
          owner
          -120
          (spec-structural-key-raw elem-key)
          0))]
    [(Array elem count)
      (let
        [elem-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner elem))]
        (spec-structural-node-with-owner
          owner
          -121
          (spec-structural-key-raw elem-key)
          count))]
    [(DynArray elem)
      (let
        [elem-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner elem))]
        (spec-structural-node-with-owner
          owner
          -122
          (spec-structural-key-raw elem-key)
          0))]
    [(Slice elem)
      (let
        [elem-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner elem))]
        (spec-structural-node-with-owner
          owner
          -123
          (spec-structural-key-raw elem-key)
          0))]
    [(Box elem)
      (let
        [elem-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner elem))]
        (spec-structural-node-with-owner
          owner
          -124
          (spec-structural-key-raw elem-key)
          0))]
    [(Ptr elem)
      (let
        [elem-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner elem))]
        (spec-structural-node-with-owner
          owner
          -125
          (spec-structural-key-raw elem-key)
          0))]
    [(MutPtr elem)
      (let
        [elem-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner elem))]
        (spec-structural-node-with-owner
          owner
          -126
          (spec-structural-key-raw elem-key)
          0))]
    [(Ref region inner)
      (let
        [inner-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner inner))]
        (spec-structural-node-with-owner
          owner
          -127
          (spec-structural-content-atom-with-owner
            owner
            (spec_ci.intern-compat-state-str
              (spec-owner-intern-state owner)
              region))
          (spec-structural-key-raw inner-key)))]
    [(MutRef region inner)
      (let
        [inner-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner inner))]
        (spec-structural-node-with-owner
          owner
          -128
          (spec-structural-content-atom-with-owner
            owner
            (spec_ci.intern-compat-state-str
              (spec-owner-intern-state owner)
              region))
          (spec-structural-key-raw inner-key)))]
    [(Region region inner)
      (let
        [inner-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner inner))]
        (spec-structural-node-with-owner
          owner
          -129
          (spec-structural-content-atom-with-owner
            owner
            (spec_ci.intern-compat-state-str
              (spec-owner-intern-state owner)
              region))
          (spec-structural-key-raw inner-key)))]
    [(Invalidate lifetime inner)
      (let
        [inner-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner inner))]
        (spec-structural-node-with-owner
          owner
          -139
          (spec-structural-content-atom-with-owner
            owner
            (spec_ci.intern-compat-state-str
              (spec-owner-intern-state owner)
              lifetime))
          (spec-structural-key-raw inner-key)))]
    [(Enum name)
      (spec-structural-node-with-owner
        owner
        -130
        (spec-structural-content-atom-with-owner
          owner
          (ast.ast-nominal-name-id-display-with-intern-state
            (spec-owner-intern-state owner)
            name))
        0)]
    [(EnumArgs name lifetimes)
      (let
        [lifetime-key : SpecStructuralKey
          (spec-lifetime-list-structural-key-with-owner
            owner
            (ast.ast-lifetime-list-box-shared-view lifetimes))]
        (spec-structural-node-with-owner
          owner
          -131
          (spec-structural-content-atom-with-owner
            owner
            (ast.ast-nominal-name-id-display-with-intern-state
              (spec-owner-intern-state owner)
              name))
          (spec-structural-key-raw lifetime-key)))]
    [(Struct name)
      (spec-structural-node-with-owner
        owner
        -132
        (spec-structural-content-atom-with-owner
          owner
          (ast.ast-nominal-name-id-display-with-intern-state
            (spec-owner-intern-state owner)
            name))
        0)]
    [(StructArgs name lifetimes)
      (let
        [lifetime-key : SpecStructuralKey
          (spec-lifetime-list-structural-key-with-owner
            owner
            (ast.ast-lifetime-list-box-shared-view lifetimes))]
        (spec-structural-node-with-owner
          owner
          -133
          (spec-structural-content-atom-with-owner
            owner
            (ast.ast-nominal-name-id-display-with-intern-state
              (spec-owner-intern-state owner)
              name))
          (spec-structural-key-raw lifetime-key)))]
    [(Var name)
      (spec-structural-node-with-owner
        owner
        -134
        (spec-structural-content-atom-with-owner
          owner
          (spec_ci.intern-compat-state-str (spec-owner-intern-state owner) name))
        0)]
    [(VarArgs name lifetimes)
      (let
        [lifetime-key : SpecStructuralKey
          (spec-lifetime-list-structural-key-with-owner
            owner
            (ast.ast-lifetime-list-box-shared-view lifetimes))]
        (spec-structural-node-with-owner
          owner
          -135
          (spec-structural-content-atom-with-owner
            owner
            (spec_ci.intern-compat-state-str
              (spec-owner-intern-state owner)
              name))
          (spec-structural-key-raw lifetime-key)))]))

(define (spec-value-structural-key-with-owner
  [owner : (& owner SpecOwnerContext)]
  [value : ctfe.CompilerCtfeValue]) : SpecStructuralKey
  (match value
    [(I64 n) (spec-structural-node-with-owner owner -200 n 0)]
    [(F64 n)
      (spec-structural-node-with-owner
        owner
        -201
        (spec-structural-content-atom-with-owner
          owner
          (cfloat.compiler-float-format-f64 n))
        0)]
    [(F32 n)
      (spec-structural-node-with-owner
        owner
        -202
        (spec-structural-content-atom-with-owner
          owner
          (cfloat.compiler-float-format-f64
            (cfloat.compiler-float-round-f32-as-f64 n)))
        0)]
    [(Bool b)
      (spec-structural-node-with-owner
        owner
        -203
        (if b
          1
          0)
        0)]
    [(Char c) (spec-structural-node-with-owner owner -204 (cast c : i64) 0)]
    [(String text _)
      (spec-structural-node-with-owner
        owner
        -205
        (spec-structural-generated-text-atom-with-owner owner text)
        0)]
    [(Name text _)
      ;; String and Name intentionally share the old content equivalence.
      (spec-structural-node-with-owner
        owner
        -205
        (spec-structural-generated-text-atom-with-owner owner text)
        0)]
    [(Unit) (spec-structural-node-with-owner owner -206 0 0)]
    [(Type ty)
      (let
        [type-key : SpecStructuralKey
          (spec-type-structural-key-with-owner owner ty)]
        (spec-structural-node-with-owner
          owner
          -207
          (spec-structural-key-raw type-key)
          0))]
    [(Expr _ _) (spec-structural-node-with-owner owner -208 0 0)]
    [(CapturedExpr _ _ _) (spec-structural-node-with-owner owner -208 0 0)]
    [(ExprList _) (spec-structural-node-with-owner owner -209 0 0)]
    [(CapturedExprList _ _) (spec-structural-node-with-owner owner -209 0 0)]
    [(ExprClause _) (spec-structural-node-with-owner owner -210 0 0)]
    [(CapturedExprClause _ _) (spec-structural-node-with-owner owner -210 0 0)]
    [(ExprClauseList _) (spec-structural-node-with-owner owner -211 0 0)]
    [(CapturedExprClauseList _ _)
      (spec-structural-node-with-owner owner -211 0 0)]
    [(ExprBindingClause _) (spec-structural-node-with-owner owner -212 0 0)]
    [(ExprBindingClauseList _) (spec-structural-node-with-owner owner -213 0 0)]
    [(Pattern _) (spec-structural-node-with-owner owner -214 0 0)]
    [(PatternList _) (spec-structural-node-with-owner owner -215 0 0)]
    [(MatchArm _) (spec-structural-node-with-owner owner -216 0 0)]
    [(MatchArmList _) (spec-structural-node-with-owner owner -217 0 0)]
    [(LetBinding _) (spec-structural-node-with-owner owner -218 0 0)]
    [(LetBindingList _) (spec-structural-node-with-owner owner -219 0 0)]
    [(TypeInfo ty)
      (let
        [type-key : SpecStructuralKey
          (spec-type-structural-key-with-owner owner ty)]
        (spec-structural-node-with-owner
          owner
          -220
          (spec-structural-key-raw type-key)
          0))]
    [(TypeInfoBox ty)
      (let
        [type-key : SpecStructuralKey
          (spec-type-structural-key-with-owner owner ty)]
        (spec-structural-node-with-owner
          owner
          -221
          (spec-structural-key-raw type-key)
          0))]
    [(TypeInfoList _) (spec-structural-node-with-owner owner -222 0 0)]
    [(TypeField _ _) (spec-structural-node-with-owner owner -223 0 0)]
    [(TypeFieldList _) (spec-structural-node-with-owner owner -224 0 0)]
    [(TypeVariantPayload _) (spec-structural-node-with-owner owner -225 0 0)]
    [(TypeVariantPayloadList _)
      (spec-structural-node-with-owner owner -226 0 0)]
    [(TypeVariant _ _) (spec-structural-node-with-owner owner -227 0 0)]
    [(TypeVariantList _) (spec-structural-node-with-owner owner -228 0 0)]))

(define (spec-values-structural-key-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [values : (& values SpecValueList)]
  [index : i64]) : SpecStructuralKey
  (if (>= index values.len)
    (SpecStructuralKey 0)
    (let
      [head : SpecStructuralKey
        (spec-value-structural-key-with-owner
          owner
          (spec-array-shared-view values.slots index))]
      [tail : SpecStructuralKey
        (spec-values-structural-key-at-with-owner owner values (+ index 1))]
      (spec-structural-node-with-owner
        owner
        -3
        (spec-structural-key-raw head)
        (spec-structural-key-raw tail)))))

(define (spec-values-structural-key-with-owner
  [owner : (& owner SpecOwnerContext)]
  [values : (& values SpecValueList)]) : SpecStructuralKey
  (spec-values-structural-key-at-with-owner owner values 0))

(define (spec-specialization-structural-key-with-owner
  [owner : (& owner SpecOwnerContext)]
  [template-name : String]
  [values : (& values SpecValueList)]) : SpecStructuralKey
  (let
    ;; InternCompatState lazily initializes on its first content operation;
    ;; perform that before allocating structural children because initialization
    ;; also starts a fresh structural generation.
    [template-atom : i64
      (spec-structural-content-atom-with-owner owner template-name)]
    [values-key : SpecStructuralKey
      (spec-values-structural-key-with-owner owner values)]
    (spec-structural-node-with-owner
      owner
      -300
      template-atom
      (spec-structural-key-raw values-key))))

(define (spec-render-specialized-name-with-owner
  [owner : (& owner SpecOwnerContext)]
  [key : SpecStructuralKey]
  [template-name : String]
  [values : SpecValueList]) : String
  (let
    [intern-state : spec_ci.InternCompatState (spec-owner-intern-state owner)]
    [raw : i64 (spec-structural-key-raw key)]
    [cached : String
      (spec_ci.intern-compat-state-composite-rendered-name intern-state raw)]
    (if (> (string.string-length cached) 0)
      (begin
        (cfg
          (any compile-profile test)
          (spec-profile-note-name-render
            (spec-owner-profile-metrics owner)
            true)
          unit)
        cached)
      (let
        [rendered : String
          (spec-specialized-name-with-owner owner template-name values)]
        (begin
          (cfg
            (any compile-profile test)
            (spec-profile-note-name-render
              (spec-owner-profile-metrics owner)
              false)
            unit)
          (spec_ci.intern-compat-state-composite-rendered-name-record!
            (&mut intern-state)
            raw
            rendered))))))

(define (spec-reserve-specialized-symbol-with-owner
  [owner : (& owner SpecOwnerContext)]
  [key : SpecStructuralKey]
  [template-name : String]
  [values : SpecValueList]) : i64
  (let
    [intern-state : spec_ci.InternCompatState (spec-owner-intern-state owner)]
    [handle : i64
      (spec_ci.intern-compat-state-generated-symbol-handle (&mut intern-state))]
    (spec-generated-symbol-records-push!
      (&mut (array-ref owner.generated-symbol-records 0))
      (SpecGeneratedSymbolRecord
        (spec-structural-key-raw key)
        handle
        template-name
        values))
    handle))

(define (spec-materialize-generated-symbol-records-with-owner!
  [owner : (& owner SpecOwnerContext)]
  [records : (& records SpecGeneratedSymbolRecords)]) : unit
  (let
    [intern-state : spec_ci.InternCompatState (spec-owner-intern-state owner)]
    [index : i64 0]
    (while (< index records.len)
      (let
        [record : SpecGeneratedSymbolRecord
          (spec-array-shared-view records.slots index)]
        (spec_ci.intern-compat-state-generated-symbol-materialize!
          (&mut intern-state)
          record.handle
          (spec-render-specialized-name-with-owner
            owner
            (SpecStructuralKey record.structural-key)
            record.template-name
            record.values))
        (set! index (+ index 1))))))

(define (spec-materialize-owner-generated-symbols!
  [owner : (& owner SpecOwnerContext)]) : unit
  (spec-materialize-generated-symbol-records-with-owner!
    owner
    (& (array-ref owner.generated-symbol-records 0)))
  (spec-generated-symbol-records-clear!
    (&mut (array-ref owner.generated-symbol-records 0))))

(define (gen-registry-empty) : GenRegistry
  (let
    [capacity : i64 64]
    [decls : (__tl_dyn-array ast.AstDecl)
      (__tl_make-array ast.AstDecl capacity)]
    (GenRegistry (spec_id_i64_map.with-capacity capacity) decls 0)))

(define (gen-registry-structural-key-with-owner
  [owner : (& owner SpecOwnerContext)]
  [module-id : i64]
  [_item-id : i64]
  [generator : String]
  [item : String]
  [arg-key : String]) : SpecStructuralKey
  (if (gen-full-key? arg-key)
    ;; An explicitly supplied full key is already the complete identity. Keep
    ;; its bytes as one tagged content atom without reparsing provenance.
    (spec-structural-node-with-owner
      owner
      -400
      (spec-structural-content-atom-with-owner owner arg-key)
      0)
    (let
      [module-atom : i64
        (spec-structural-content-atom-with-owner
          owner
          (if (< module-id 0)
            ""
            (spec_ci.intern-compat-state-str
              (spec-owner-intern-state owner)
              module-id)))]
      [generator-atom : i64
        (spec-structural-content-atom-with-owner owner generator)]
      [item-atom : i64 (spec-structural-content-atom-with-owner owner item)]
      [arg-atom : i64 (spec-structural-content-atom-with-owner owner arg-key)]
      [scope : SpecStructuralKey
        (spec-structural-node-with-owner owner -401 module-atom generator-atom)]
      [payload : SpecStructuralKey
        (spec-structural-node-with-owner owner -402 item-atom arg-atom)]
      (spec-structural-node-with-owner
        owner
        -403
        (spec-structural-key-raw scope)
        (spec-structural-key-raw payload)))))

(define (gen-registry-lookup-with-owner
  [registry : (& registry GenRegistry)]
  [key : SpecStructuralKey]) : GenMaybeEntry
  (match (spec_id_i64_map.get (& registry.index) (spec-structural-key-raw key))
    [(LookupFound slot) (Some (spec-array-shared-view registry.decls slot))]
    [(LookupMissing) (None)]))

(define (gen-registry-copy-decls
  [src-address : u64]
  [dst : (&mut dst (__tl_dyn-array ast.AstDecl))]
  [index : i64]
  [count : i64]) : unit
  (unless
    (>= index count)
    (set!
      (array-ref dst index)
      (unsafe
        (ptr-read
          (ptr-offset
            (int->ptr
              (ptr-read (int->ptr src-address : (Ptr u64)))
              : (Ptr ast.AstDecl))
            index))))
    (gen-registry-copy-decls src-address dst (+ index 1) count)))

(define (gen-registry-grow [registry : GenRegistry]) : GenRegistry
  (let
    [old-index : spec_id_i64_map.Map registry.index]
    [old-decls : (__tl_dyn-array ast.AstDecl) registry.decls]
    [old-len : i64 registry.len]
    [old-capacity : i64 (array-length old-decls)]
    [new-capacity : i64
      (if (< old-capacity 1)
        1
        (* old-capacity 2))]
    [new-decls : (__tl_dyn-array ast.AstDecl)
      (__tl_make-array ast.AstDecl new-capacity)]
    (gen-registry-copy-decls
      (spec-array-address old-decls)
      (&mut new-decls)
      0
      old-len)
    (GenRegistry old-index new-decls old-len)))

(define (gen-registry-insert-with-owner
  [registry : GenRegistry]
  [key : SpecStructuralKey]
  [decl : ast.AstDecl]) : GenRegistry
  (let
    [ready : GenRegistry
      (if (>= registry.len (array-length registry.decls))
        (gen-registry-grow registry)
        registry)]
    [slot : i64 ready.len]
    [decls : (__tl_dyn-array ast.AstDecl) ready.decls]
    [index : spec_id_i64_map.Map ready.index]
    (set! (array-ref decls slot) decl)
    (spec_id_i64_map.insert-ref!
      (&mut index)
      (spec-structural-key-raw key)
      slot)
    (GenRegistry index decls (+ slot 1))))

(define (gen-decl-visible-name-id [decl : ast.AstDecl]) : SpecMaybeId
  (match decl
    [(Def decl-meta name _ _) (Some name)]
    [(DefFn decl-meta name _ _ _ _) (Some name)]
    [(Extern decl-meta name _ _ _) (Some name)]
    [(DefDispatch decl-meta name _) (Some name)]
    [(DefEnum decl-meta name _ _) (Some name)]
    [(DefEnumLifetimes decl-meta name _ _ _) (Some name)]
    [(DefStruct decl-meta name _ _ _) (Some name)]
    [(DefStructLifetimes decl-meta name _ _ _ _) (Some name)]
    [(DefMacro decl-meta name _ _ _) (Some name)]
    [(Unsafe inner-box)
      (gen-decl-visible-name-id (ast.ast-decl-box-shared-view inner-box))]
    [_ (None)]))

(define (gen-decl-visible-name [decl : ast.AstDecl]) : SpecMaybeString
  (match (gen-decl-visible-name-id decl)
    [(Some name-id) (Some (spec_ci.intern-str name-id))]
    [(None) (None)]))

(define (gen-maybe-type-eq? [a : ast.AstMaybeType] [b : ast.AstMaybeType]) : bool
  (match a
    [(No)
      (match b
        [(No) true]
        [_ false])]
    [(Some a-ty)
      (match b
        [(Some b-ty) (ctfe.ctfe-type-eq a-ty b-ty)]
        [_ false])]))

(define (gen-expr-eq? [a : ast.AstExpr] [b : ast.AstExpr]) : bool
  (ctfe.ctfe-expr-eq (ast.ast-expr-unspan a) (ast.ast-expr-unspan b)))

(define (gen-param-eq? [a : ast.AstParam] [b : ast.AstParam]) : bool
  (match a
    [(Param a-name a-ty a-comptime)
      (match b
        [(Param b-name b-ty b-comptime)
          (and
            (= a-name b-name)
            (ctfe.ctfe-type-eq a-ty b-ty)
            (= a-comptime b-comptime))])]))

(define (gen-param-list-eq? [a : ast.AstParamList] [b : ast.AstParamList]) : bool
  (let
    [len : i64 (ast.ast-param-list-len (& a))]
    (and
      (= len (ast.ast-param-list-len (& b)))
      (gen-param-list-eq-at? (& a) (& b) len 0))))

(define (gen-param-list-eq-at?
  [a : (& a ast.AstParamList)]
  [b : (& b ast.AstParamList)]
  [len : i64]
  [index : i64]) : bool
  (if (>= index len)
    true
    (and
      (gen-param-eq?
        (ast.ast-param-list-get a index (ast.ast-param-fallback))
        (ast.ast-param-list-get b index (ast.ast-param-fallback)))
      (gen-param-list-eq-at? a b len (+ index 1)))))

(define (gen-macro-param-eq? [a : ast.AstMacroParam] [b : ast.AstMacroParam]) : bool
  (match a
    [(Param a-name a-ty a-variadic a-type-kinds)
      (match b
        [(Param b-name b-ty b-variadic b-type-kinds)
          (and
            (= a-name b-name)
            (ctfe.ctfe-type-eq a-ty b-ty)
            (= a-variadic b-variadic)
            (ast.ast-macro-type-kind-list-eq? (& a-type-kinds) (& b-type-kinds)))])]))

(define (gen-macro-param-list-eq?
  [a : ast.AstMacroParamList]
  [b : ast.AstMacroParamList]) : bool
  (let
    [len : i64 (ast.ast-macro-param-list-len (& a))]
    (and
      (= len (ast.ast-macro-param-list-len (& b)))
      (gen-macro-param-list-eq-at? (& a) (& b) len 0))))

(define (gen-macro-param-list-eq-at?
  [a : (& a ast.AstMacroParamList)]
  [b : (& b ast.AstMacroParamList)]
  [len : i64]
  [index : i64]) : bool
  (if (>= index len)
    true
    (and
      (gen-macro-param-eq?
        (ast.ast-macro-param-list-get a index (ast.ast-macro-param-fallback))
        (ast.ast-macro-param-list-get b index (ast.ast-macro-param-fallback)))
      (gen-macro-param-list-eq-at? a b len (+ index 1)))))

(define (gen-field-cleanup-eq?
  [a : ast.AstFieldCleanup]
  [b : ast.AstFieldCleanup]) : bool
  (match a
    [(No)
      (match b
        [(No) true]
        [_ false])]
    [(Fn a-name)
      (match b
        [(Fn b-name) (= a-name b-name)]
        [_ false])]
    [(Owned)
      (match b
        [(Owned) true]
        [_ false])]))

(define (gen-field-def-eq? [a : ast.AstFieldDef] [b : ast.AstFieldDef]) : bool
  (match a
    [(Def a-name a-ty a-cleanup)
      (match b
        [(Def b-name b-ty b-cleanup)
          (and
            (spec_ci.intern-syntax-id-eq? a-name b-name)
            (ctfe.ctfe-type-eq a-ty b-ty)
            (gen-field-cleanup-eq? a-cleanup b-cleanup))])]))

(define (gen-field-list-eq? [a : ast.AstFieldDefList] [b : ast.AstFieldDefList]) : bool
  (if (= a.len b.len)
    (gen-field-list-eq-at (& a) (& b) 0)
    false))

(define (gen-field-list-eq-at
  [a : (& a ast.AstFieldDefList)]
  [b : (& b ast.AstFieldDefList)]
  [index : i64]) : bool
  (if (>= index a.len)
    true
    (and
      (gen-field-def-eq?
        (ast.ast-field-def-list-get a index (ast.ast-field-def-fallback))
        (ast.ast-field-def-list-get b index (ast.ast-field-def-fallback)))
      (gen-field-list-eq-at a b (+ index 1)))))

(define (gen-struct-repr-eq? [a : ast.AstStructRepr] [b : ast.AstStructRepr]) : bool
  (match a
    [(Default)
      (match b
        [(Default) true]
        [_ false])]
    [(C a-align a-fields)
      (match b
        [(C b-align b-fields)
          (and
            (= a-align b-align)
            (=
              (ast.ast-field-aligns-len (& a-fields))
              (ast.ast-field-aligns-len (& b-fields)))
            (gen-field-aligns-eq-at (& a-fields) (& b-fields) 0))]
        [_ false])]))

(define (gen-field-aligns-eq-at
  [a : (& a ast.AstFieldAligns)]
  [b : (& b ast.AstFieldAligns)]
  [index : i64]) : bool
  (or
    (>= index (ast.ast-field-aligns-len a))
    (and
      (= (ast.ast-field-aligns-ref a index) (ast.ast-field-aligns-ref b index))
      (gen-field-aligns-eq-at a b (+ index 1)))))

(define (gen-struct-cleanup-eq?
  [a : ast.AstStructCleanup]
  [b : ast.AstStructCleanup]) : bool
  (match a
    [(No)
      (match b
        [(No) true]
        [_ false])]
    [(Fn a-name)
      (match b
        [(Fn b-name) (= a-name b-name)]
        [_ false])]))

(define (gen-enum-cleanup-eq? [a : ast.AstEnumCleanup] [b : ast.AstEnumCleanup]) : bool
  (match a
    [(No)
      (match b
        [(No) true]
        [_ false])]
    [(Fn a-name)
      (match b
        [(Fn b-name) (= a-name b-name)]
        [_ false])]))

(define (gen-variant-payload-cleanup-eq?
  [a : ast.AstVariantPayloadCleanup]
  [b : ast.AstVariantPayloadCleanup]) : bool
  (match a
    [(No)
      (match b
        [(No) true]
        [_ false])]
    [(Fn a-name)
      (match b
        [(Fn b-name) (= a-name b-name)]
        [_ false])]
    [(Owned)
      (match b
        [(Owned) true]
        [_ false])]))

(define (gen-variant-payload-cleanup-list-eq?
  [a : ast.AstVariantPayloadCleanupList]
  [b : ast.AstVariantPayloadCleanupList]) : bool
  (if (= a.len b.len)
    (gen-variant-payload-cleanup-list-eq-at? (& a) (& b) 0)
    false))

(define (gen-variant-payload-cleanup-list-eq-at?
  [a : (& a ast.AstVariantPayloadCleanupList)]
  [b : (& b ast.AstVariantPayloadCleanupList)]
  [index : i64]) : bool
  (if (>= index a.len)
    true
    (and
      (gen-variant-payload-cleanup-eq?
        (ast.ast-variant-payload-cleanup-list-get
          a
          index
          (ast.ast-variant-payload-cleanup-fallback))
        (ast.ast-variant-payload-cleanup-list-get
          b
          index
          (ast.ast-variant-payload-cleanup-fallback)))
      (gen-variant-payload-cleanup-list-eq-at? a b (+ index 1)))))

(define (gen-variant-def-eq? [a : ast.AstVariantDef] [b : ast.AstVariantDef]) : bool
  (match a
    [(Def a-name a-payloads a-cleanups)
      (match b
        [(Def b-name b-payloads b-cleanups)
          (and
            (= a-name b-name)
            (ctfe.ctfe-type-list-eq a-payloads b-payloads)
            (gen-variant-payload-cleanup-list-eq? a-cleanups b-cleanups))])]))

(define (gen-variant-list-eq?
  [a : ast.AstVariantDefList]
  [b : ast.AstVariantDefList]) : bool
  (if (= a.len b.len)
    (gen-variant-list-eq-at? (& a) (& b) 0)
    false))

(define (gen-variant-list-eq-at?
  [a : (& a ast.AstVariantDefList)]
  [b : (& b ast.AstVariantDefList)]
  [index : i64]) : bool
  (if (>= index a.len)
    true
    (and
      (gen-variant-def-eq?
        (ast.ast-variant-def-list-get a index (ast.ast-variant-def-fallback))
        (ast.ast-variant-def-list-get b index (ast.ast-variant-def-fallback)))
      (gen-variant-list-eq-at? a b (+ index 1)))))

(define (gen-spmd-param-class-eq?
  [a : ast.AstSpmdParamClass]
  [b : ast.AstSpmdParamClass]) : bool
  (match a
    [(Uniform)
      (match b
        [(Uniform) true]
        [_ false])]
    [(Varying)
      (match b
        [(Varying) true]
        [_ false])]))

(define (gen-spmd-result-class-eq?
  [a : ast.AstSpmdResultClass]
  [b : ast.AstSpmdResultClass]) : bool
  (match a
    [(Unit)
      (match b
        [(Unit) true]
        [_ false])]
    [(Uniform)
      (match b
        [(Uniform) true]
        [_ false])]
    [(Varying)
      (match b
        [(Varying) true]
        [_ false])]))

(define (gen-spmd-param-class-list-eq-at?
  [a : (& a ast.AstSpmdParamClassList)]
  [b : (& b ast.AstSpmdParamClassList)]
  [index : i64]) : bool
  (if (>= index (ast.ast-spmd-param-class-list-len a))
    (=
      (ast.ast-spmd-param-class-list-len a)
      (ast.ast-spmd-param-class-list-len b))
    (and
      (< index (ast.ast-spmd-param-class-list-len b))
      (gen-spmd-param-class-eq?
        (ast.ast-spmd-param-class-list-get a index Uniform)
        (ast.ast-spmd-param-class-list-get b index Uniform))
      (gen-spmd-param-class-list-eq-at? a b (+ index 1)))))

(define (gen-spmd-specialization-fallback) : ast.AstSpmdSpecialization
  (ast.AstSpmdSpecialization
    2
    (box (ast.ast-spmd-param-class-list-new))
    Unit
    -1))

(define (gen-spmd-specialization-eq?
  [a : ast.AstSpmdSpecialization]
  [b : ast.AstSpmdSpecialization]) : bool
  (and
    (= a.lanes b.lanes)
    (gen-spmd-param-class-list-eq-at?
      (& (__tl-box-place a.args))
      (& (__tl-box-place b.args))
      0)
    (gen-spmd-result-class-eq? a.result b.result)
    (= a.index-param b.index-param)))

(define (gen-spmd-specialization-list-eq-at?
  [a : (& a ast.AstSpmdSpecializationList)]
  [b : (& b ast.AstSpmdSpecializationList)]
  [index : i64]) : bool
  (if (>= index (ast.ast-spmd-specialization-list-len a))
    (=
      (ast.ast-spmd-specialization-list-len a)
      (ast.ast-spmd-specialization-list-len b))
    (and
      (< index (ast.ast-spmd-specialization-list-len b))
      (gen-spmd-specialization-eq?
        (ast.ast-spmd-specialization-list-get
          a
          index
          (gen-spmd-specialization-fallback))
        (ast.ast-spmd-specialization-list-get
          b
          index
          (gen-spmd-specialization-fallback)))
      (gen-spmd-specialization-list-eq-at? a b (+ index 1)))))

(define (gen-fn-metadata-eq? [a : ast.AstFnMetadata] [b : ast.AstFnMetadata]) : bool
  (match a
    [(No)
      (match b
        [(No) true]
        [_ false])]
    [(Export a-symbol)
      (match b
        [(Export b-symbol) (spec_ci.intern-id-eq? a-symbol b-symbol)]
        [_ false])]
    [(SpmdCallable a-items)
      (match b
        [(SpmdCallable b-items)
          (gen-spmd-specialization-list-eq-at?
            (& (__tl-box-place a-items))
            (& (__tl-box-place b-items))
            0)]
        [_ false])]))

(define (gen-import-kind-eq? [a : ast.AstImportKind] [b : ast.AstImportKind]) : bool
  (match a
    [(Module)
      (match b
        [(Module) true]
        [_ false])]
    [(ModuleAll)
      (match b
        [(ModuleAll) true]
        [_ false])]
    [(ModuleItem a-item)
      (match b
        [(ModuleItem b-item) (= a-item b-item)]
        [_ false])]
    [(Macro _ _)
      (match b
        [(Macro _ _) true]
        [_ false])]
    [(MacroDecls _ _)
      (match b
        [(MacroDecls _ _) true]
        [_ false])]))

(define (gen-maybe-module-name-eq?
  [a : ast.AstMaybeModuleName]
  [b : ast.AstMaybeModuleName]) : bool
  (match a
    [(No)
      (match b
        [(No) true]
        [_ false])]
    [(Some a-name)
      (match b
        [(Some b-name) (= a-name b-name)]
        [_ false])]))

(define (gen-maybe-import-alias-eq?
  [a : ast.AstMaybeImportAlias]
  [b : ast.AstMaybeImportAlias]) : bool
  (match a
    [(No)
      (match b
        [(No) true]
        [_ false])]
    [(Some a-name)
      (match b
        [(Some b-name) (= a-name b-name)]
        [_ false])]))

(define (gen-import-spec-eq? [a : ast.AstImportSpec] [b : ast.AstImportSpec]) : bool
  (match a
    [(Spec a-kind a-path a-module a-alias _)
      (match b
        [(Spec b-kind b-path b-module b-alias _)
          (and
            (gen-import-kind-eq? a-kind b-kind)
            (string.eq a-path b-path)
            (gen-maybe-module-name-eq? a-module b-module)
            (gen-maybe-import-alias-eq? a-alias b-alias))])]))

(define (gen-decl-list-eq? [a : ast.AstDeclList] [b : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step a)
    [(Nil)
      (match (ast.ast-decl-list-step b)
        [(Nil) true]
        [_ false])]
    [(Cons a-head a-rest)
      (match (ast.ast-decl-list-step b)
        [(Cons b-head b-rest)
          (and (gen-decl-eq? a-head b-head) (gen-decl-list-eq? a-rest b-rest))]
        [_ false])]))

(define (gen-test-metadata-eq?
  [a : (& a ast.AstTestMetadata)]
  [b : (& b ast.AstTestMetadata)]) : bool
  (and
    (= (ast.ast-test-metadata-slow? a) (ast.ast-test-metadata-slow? b))
    (match (ast.ast-test-metadata-ignore-reason a)
      [(No)
        (match (ast.ast-test-metadata-ignore-reason b)
          [(No) true]
          [_ false])]
      [(Some a-reason)
        (match (ast.ast-test-metadata-ignore-reason b)
          [(Some b-reason) (string.eq a-reason b-reason)]
          [_ false])])))

;; Generated identity permits reuse only when declaration semantics agree.
;; Marker flags affect nominal semantics even though they do not affect ABI.
(define (gen-aggregate-markers-eq? [a : ast.AstDeclMeta] [b : ast.AstDeclMeta]) : bool
  (=
    (ast.ast-decl-meta-aggregate-markers a)
    (ast.ast-decl-meta-aggregate-markers b)))

(define (gen-decl-eq? [a : ast.AstDecl] [b : ast.AstDecl]) : bool
  (match a
    [(Def decl-meta a-name a-ty a-value-box)
      (let
        [a-value : ast.AstExpr (ast.ast-node-get a-value-box)]
        (match b
          [(Def decl-meta b-name b-ty b-value-box)
            (let
              [b-value : ast.AstExpr (ast.ast-node-get b-value-box)]
              (and
                (= a-name b-name)
                (gen-maybe-type-eq? a-ty b-ty)
                (gen-expr-eq? a-value b-value)))]
          [_ false]))]
    [(DefFn decl-meta a-name a-params a-ret a-body-box a-metadata)
      (let
        [a-body : ast.AstExpr (ast.ast-node-get a-body-box)]
        (match b
          [(DefFn decl-meta b-name b-params b-ret b-body-box b-metadata)
            (let
              [b-body : ast.AstExpr (ast.ast-node-get b-body-box)]
              (and
                (= a-name b-name)
                (gen-param-list-eq? a-params b-params)
                (ctfe.ctfe-type-eq a-ret b-ret)
                (gen-expr-eq? a-body b-body)
                (gen-fn-metadata-eq? a-metadata b-metadata)))]
          [_ false]))]
    [(DefEnum a-meta a-name a-cleanup a-variants)
      (match b
        [(DefEnum b-meta b-name b-cleanup b-variants)
          (and
            (gen-aggregate-markers-eq? a-meta b-meta)
            (= a-name b-name)
            (gen-enum-cleanup-eq? a-cleanup b-cleanup)
            (gen-variant-list-eq? a-variants b-variants))]
        [_ false])]
    [(DefEnumLifetimes a-meta a-name a-lifetimes a-cleanup a-variants)
      (match b
        [(DefEnumLifetimes b-meta b-name b-lifetimes b-cleanup b-variants)
          (and
            (gen-aggregate-markers-eq? a-meta b-meta)
            (= a-name b-name)
            (ctfe.ctfe-lifetime-list-eq a-lifetimes b-lifetimes)
            (gen-enum-cleanup-eq? a-cleanup b-cleanup)
            (gen-variant-list-eq? a-variants b-variants))]
        [_ false])]
    [(DefStruct a-meta a-name a-repr a-cleanup a-fields)
      (match b
        [(DefStruct b-meta b-name b-repr b-cleanup b-fields)
          (and
            (gen-aggregate-markers-eq? a-meta b-meta)
            (= a-name b-name)
            (gen-struct-repr-eq? a-repr b-repr)
            (gen-struct-cleanup-eq? a-cleanup b-cleanup)
            (gen-field-list-eq? a-fields b-fields))]
        [_ false])]
    [(DefStructLifetimes a-meta a-name a-lifetimes a-repr a-cleanup a-fields)
      (match b
        [(DefStructLifetimes
            b-meta
            b-name
            b-lifetimes
            b-repr
            b-cleanup
            b-fields)
          (and
            (gen-aggregate-markers-eq? a-meta b-meta)
            (= a-name b-name)
            (ctfe.ctfe-lifetime-list-eq a-lifetimes b-lifetimes)
            (gen-struct-repr-eq? a-repr b-repr)
            (gen-struct-cleanup-eq? a-cleanup b-cleanup)
            (gen-field-list-eq? a-fields b-fields))]
        [_ false])]
    [(DefMacro decl-meta a-name a-params a-ret a-body-box)
      (let
        [a-body : ast.AstExpr (ast.ast-node-get a-body-box)]
        (match b
          [(DefMacro decl-meta b-name b-params b-ret b-body-box)
            (let
              [b-body : ast.AstExpr (ast.ast-node-get b-body-box)]
              (and
                (= a-name b-name)
                (gen-macro-param-list-eq? a-params b-params)
                (ctfe.ctfe-type-eq a-ret b-ret)
                (gen-expr-eq? a-body b-body)))]
          [_ false]))]
    [(Import decl-meta a-spec)
      (match b
        [(Import decl-meta b-spec) (gen-import-spec-eq? a-spec b-spec)]
        [_ false])]
    [(IncludeStr a-name a-path)
      (match b
        [(IncludeStr b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(IncludeStrComptime a-name a-path)
      (match b
        [(IncludeStrComptime b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(IncludeStrLzss a-name a-path)
      (match b
        [(IncludeStrLzss b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(IncludeBin a-name a-path)
      (match b
        [(IncludeBin b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(Test a-name a-body-box a-metadata _)
      (let
        [a-body : ast.AstExpr (ast.ast-node-get a-body-box)]
        (match b
          [(Test b-name b-body-box b-metadata _)
            (let
              [b-body : ast.AstExpr (ast.ast-node-get b-body-box)]
              (and
                (= a-name b-name)
                (gen-test-metadata-eq? a-metadata b-metadata)
                (gen-expr-eq? a-body b-body)))]
          [_ false]))]
    [(Module a-name)
      (match b
        [(Module b-name) (= a-name b-name)]
        [_ false])]
    [(ModuleBody a-name a-body-box)
      (match b
        [(ModuleBody b-name b-body-box)
          (and
            (= a-name b-name)
            (gen-decl-list-eq?
              (ast.ast-decl-list-box-shared-view a-body-box)
              (ast.ast-decl-list-box-shared-view b-body-box)))]
        [_ false])]
    [(Unsafe a-inner-box)
      (let
        [a-inner : ast.AstDecl (ast.ast-decl-box-shared-view a-inner-box)]
        (match (ast.ast-place-shared-view b)
          [(Unsafe b-inner-box)
            (gen-decl-eq? a-inner (ast.ast-decl-box-shared-view b-inner-box))]
          [_ (gen-decl-eq? a-inner b)]))]
    [_ false]))

;; Explicit generated-declaration equality.  The compatibility equality above
;; remains for serial/test callers; production normalization routes through
;; these workers so every expression/type read is resolved by the job owner.
(define (gen-maybe-type-eq-with-owner
  [_owner : (& _owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : ast.AstMaybeType]
  [b : ast.AstMaybeType]) : bool
  (match a
    [(No)
      (match b
        [(No) true]
        [_ false])]
    [(Some a-ty)
      (match b
        [(Some b-ty) (ctfe.ctfe-type-eq-in-env env a-ty b-ty)]
        [_ false])]))

(define (gen-expr-eq-with-owner
  [owner : (& owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : ast.AstExpr]
  [b : ast.AstExpr]) : bool
  (let
    [pools : ast.AstNodePoolContext (spec-owner-pools owner)]
    (ctfe.ctfe-expr-eq-in-env
      (ctfe.ctfe-env-shared-view env)
      (ast.ast-expr-unspan-with-pools pools a)
      (ast.ast-expr-unspan-with-pools pools b))))

(define (gen-param-eq-with-owner
  [_owner : (& _owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : ast.AstParam]
  [b : ast.AstParam]) : bool
  (match a
    [(Param a-name a-ty a-comptime)
      (match b
        [(Param b-name b-ty b-comptime)
          (and
            (= a-name b-name)
            (ctfe.ctfe-type-eq-in-env env a-ty b-ty)
            (= a-comptime b-comptime))])]))

(define (gen-param-list-eq-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : (& a ast.AstParamList)]
  [b : (& b ast.AstParamList)]
  [len : i64]
  [index : i64]) : bool
  (if (>= index len)
    true
    (and
      (gen-param-eq-with-owner
        owner
        env
        (ast.ast-param-list-get a index (ast.ast-param-fallback))
        (ast.ast-param-list-get b index (ast.ast-param-fallback)))
      (gen-param-list-eq-at-with-owner owner env a b len (+ index 1)))))

(define (gen-param-list-eq-with-owner
  [owner : (& owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : ast.AstParamList]
  [b : ast.AstParamList]) : bool
  (let
    [len : i64 (ast.ast-param-list-len (& a))]
    (and
      (= len (ast.ast-param-list-len (& b)))
      (gen-param-list-eq-at-with-owner owner env (& a) (& b) len 0))))

(define (gen-macro-param-eq-with-owner
  [_owner : (& _owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : ast.AstMacroParam]
  [b : ast.AstMacroParam]) : bool
  (match a
    [(Param a-name a-ty a-variadic a-type-kinds)
      (match b
        [(Param b-name b-ty b-variadic b-type-kinds)
          (and
            (= a-name b-name)
            (ctfe.ctfe-type-eq-in-env env a-ty b-ty)
            (= a-variadic b-variadic)
            (ast.ast-macro-type-kind-list-eq? (& a-type-kinds) (& b-type-kinds)))])]))

(define (gen-macro-param-list-eq-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : (& a ast.AstMacroParamList)]
  [b : (& b ast.AstMacroParamList)]
  [len : i64]
  [index : i64]) : bool
  (if (>= index len)
    true
    (and
      (gen-macro-param-eq-with-owner
        owner
        env
        (ast.ast-macro-param-list-get a index (ast.ast-macro-param-fallback))
        (ast.ast-macro-param-list-get b index (ast.ast-macro-param-fallback)))
      (gen-macro-param-list-eq-at-with-owner owner env a b len (+ index 1)))))

(define (gen-macro-param-list-eq-with-owner
  [owner : (& owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : ast.AstMacroParamList]
  [b : ast.AstMacroParamList]) : bool
  (let
    [len : i64 (ast.ast-macro-param-list-len (& a))]
    (and
      (= len (ast.ast-macro-param-list-len (& b)))
      (gen-macro-param-list-eq-at-with-owner owner env (& a) (& b) len 0))))

(define (gen-field-def-eq-with-owner
  [_owner : (& _owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : ast.AstFieldDef]
  [b : ast.AstFieldDef]) : bool
  (match a
    [(Def a-name a-ty a-cleanup)
      (match b
        [(Def b-name b-ty b-cleanup)
          (and
            (spec_ci.intern-syntax-id-eq? a-name b-name)
            (ctfe.ctfe-type-eq-in-env env a-ty b-ty)
            (gen-field-cleanup-eq? a-cleanup b-cleanup))])]))

(define (gen-field-list-eq-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : (& a ast.AstFieldDefList)]
  [b : (& b ast.AstFieldDefList)]
  [index : i64]) : bool
  (if (>= index a.len)
    true
    (and
      (gen-field-def-eq-with-owner
        owner
        env
        (ast.ast-field-def-list-get a index (ast.ast-field-def-fallback))
        (ast.ast-field-def-list-get b index (ast.ast-field-def-fallback)))
      (gen-field-list-eq-at-with-owner owner env a b (+ index 1)))))

(define (gen-field-list-eq-with-owner
  [owner : (& owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : ast.AstFieldDefList]
  [b : ast.AstFieldDefList]) : bool
  (and
    (= a.len b.len)
    (gen-field-list-eq-at-with-owner owner env (& a) (& b) 0)))

(define (gen-variant-def-eq-with-owner
  [_owner : (& _owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : ast.AstVariantDef]
  [b : ast.AstVariantDef]) : bool
  (match a
    [(Def a-name a-payloads a-cleanups)
      (match b
        [(Def b-name b-payloads b-cleanups)
          (and
            (= a-name b-name)
            (ctfe.ctfe-type-list-eq-in-env env a-payloads b-payloads)
            (gen-variant-payload-cleanup-list-eq? a-cleanups b-cleanups))])]))

(define (gen-variant-list-eq-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : (& a ast.AstVariantDefList)]
  [b : (& b ast.AstVariantDefList)]
  [index : i64]) : bool
  (if (>= index a.len)
    true
    (and
      (gen-variant-def-eq-with-owner
        owner
        env
        (ast.ast-variant-def-list-get a index (ast.ast-variant-def-fallback))
        (ast.ast-variant-def-list-get b index (ast.ast-variant-def-fallback)))
      (gen-variant-list-eq-at-with-owner owner env a b (+ index 1)))))

(define (gen-variant-list-eq-with-owner
  [owner : (& owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : ast.AstVariantDefList]
  [b : ast.AstVariantDefList]) : bool
  (and
    (= a.len b.len)
    (gen-variant-list-eq-at-with-owner owner env (& a) (& b) 0)))

(define (gen-fn-metadata-eq-with-owner
  [_owner : (& _owner SpecOwnerContext)]
  [_env : (& _env ctfe.CtfeEnv)]
  [a : ast.AstFnMetadata]
  [b : ast.AstFnMetadata]) : bool
  (match a
    [(No)
      (match b
        [(No) true]
        [_ false])]
    [(Export a-symbol)
      (match b
        [(Export b-symbol) (spec_ci.intern-id-eq? a-symbol b-symbol)]
        [_ false])]
    [(SpmdCallable a-items)
      (match b
        [(SpmdCallable b-items)
          (gen-spmd-specialization-list-eq-at?
            (& (__tl-box-place a-items))
            (& (__tl-box-place b-items))
            0)]
        [_ false])]))

(define (gen-decl-list-eq-with-owner
  [owner : (& owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : ast.AstDeclList]
  [b : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step a)
    [(Nil)
      (match (ast.ast-decl-list-step b)
        [(Nil) true]
        [_ false])]
    [(Cons a-head a-rest)
      (match (ast.ast-decl-list-step b)
        [(Cons b-head b-rest)
          (and
            (gen-decl-eq-with-owner owner env a-head b-head)
            (gen-decl-list-eq-with-owner owner env a-rest b-rest))]
        [_ false])]))

(define (gen-decl-eq-with-owner
  [owner : (& owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [a : ast.AstDecl]
  [b : ast.AstDecl]) : bool
  (match a
    [(Def _ a-name a-ty a-value-box)
      (let
        [a-value : ast.AstExpr (spec-owner-expr-get owner a-value-box)]
        (match b
          [(Def _ b-name b-ty b-value-box)
            (and
              (= a-name b-name)
              (gen-maybe-type-eq-with-owner owner env a-ty b-ty)
              (gen-expr-eq-with-owner
                owner
                env
                a-value
                (spec-owner-expr-get owner b-value-box)))]
          [_ false]))]
    [(DefFn _ a-name a-params a-ret a-body-box a-metadata)
      (match b
        [(DefFn _ b-name b-params b-ret b-body-box b-metadata)
          (and
            (= a-name b-name)
            (gen-param-list-eq-with-owner owner env a-params b-params)
            (ctfe.ctfe-type-eq-in-env env a-ret b-ret)
            (gen-expr-eq-with-owner
              owner
              env
              (spec-owner-expr-get owner a-body-box)
              (spec-owner-expr-get owner b-body-box))
            (gen-fn-metadata-eq-with-owner owner env a-metadata b-metadata))]
        [_ false])]
    [(DefEnum a-meta a-name a-cleanup a-variants)
      (match b
        [(DefEnum b-meta b-name b-cleanup b-variants)
          (and
            (gen-aggregate-markers-eq? a-meta b-meta)
            (= a-name b-name)
            (gen-enum-cleanup-eq? a-cleanup b-cleanup)
            (gen-variant-list-eq-with-owner owner env a-variants b-variants))]
        [_ false])]
    [(DefEnumLifetimes a-meta a-name a-lifetimes a-cleanup a-variants)
      (match b
        [(DefEnumLifetimes b-meta b-name b-lifetimes b-cleanup b-variants)
          (and
            (gen-aggregate-markers-eq? a-meta b-meta)
            (= a-name b-name)
            (ctfe.ctfe-lifetime-list-eq a-lifetimes b-lifetimes)
            (gen-enum-cleanup-eq? a-cleanup b-cleanup)
            (gen-variant-list-eq-with-owner owner env a-variants b-variants))]
        [_ false])]
    [(DefStruct a-meta a-name a-repr a-cleanup a-fields)
      (match b
        [(DefStruct b-meta b-name b-repr b-cleanup b-fields)
          (and
            (gen-aggregate-markers-eq? a-meta b-meta)
            (= a-name b-name)
            (gen-struct-repr-eq? a-repr b-repr)
            (gen-struct-cleanup-eq? a-cleanup b-cleanup)
            (gen-field-list-eq-with-owner owner env a-fields b-fields))]
        [_ false])]
    [(DefStructLifetimes a-meta a-name a-lifetimes a-repr a-cleanup a-fields)
      (match b
        [(DefStructLifetimes
            b-meta
            b-name
            b-lifetimes
            b-repr
            b-cleanup
            b-fields)
          (and
            (gen-aggregate-markers-eq? a-meta b-meta)
            (= a-name b-name)
            (ctfe.ctfe-lifetime-list-eq a-lifetimes b-lifetimes)
            (gen-struct-repr-eq? a-repr b-repr)
            (gen-struct-cleanup-eq? a-cleanup b-cleanup)
            (gen-field-list-eq-with-owner owner env a-fields b-fields))]
        [_ false])]
    [(DefMacro _ a-name a-params a-ret a-body-box)
      (match b
        [(DefMacro _ b-name b-params b-ret b-body-box)
          (and
            (= a-name b-name)
            (gen-macro-param-list-eq-with-owner owner env a-params b-params)
            (ctfe.ctfe-type-eq-in-env env a-ret b-ret)
            (gen-expr-eq-with-owner
              owner
              env
              (spec-owner-expr-get owner a-body-box)
              (spec-owner-expr-get owner b-body-box)))]
        [_ false])]
    [(Import _ a-spec)
      (match b
        [(Import _ b-spec) (gen-import-spec-eq? a-spec b-spec)]
        [_ false])]
    [(IncludeStr a-name a-path)
      (match b
        [(IncludeStr b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(IncludeStrComptime a-name a-path)
      (match b
        [(IncludeStrComptime b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(IncludeStrLzss a-name a-path)
      (match b
        [(IncludeStrLzss b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(IncludeBin a-name a-path)
      (match b
        [(IncludeBin b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(Test a-name a-body-box a-metadata _)
      (match b
        [(Test b-name b-body-box b-metadata _)
          (and
            (= a-name b-name)
            (gen-test-metadata-eq? a-metadata b-metadata)
            (gen-expr-eq-with-owner
              owner
              env
              (spec-owner-expr-get owner a-body-box)
              (spec-owner-expr-get owner b-body-box)))]
        [_ false])]
    [(Module a-name)
      (match b
        [(Module b-name) (= a-name b-name)]
        [_ false])]
    [(ModuleBody a-name a-body-box)
      (match b
        [(ModuleBody b-name b-body-box)
          (and
            (= a-name b-name)
            (gen-decl-list-eq-with-owner
              owner
              env
              (ast.ast-decl-list-box-shared-view a-body-box)
              (ast.ast-decl-list-box-shared-view b-body-box)))]
        [_ false])]
    [(Unsafe a-inner-box)
      (match (ast.ast-place-shared-view b)
        [(Unsafe b-inner-box)
          (gen-decl-eq-with-owner
            owner
            env
            (ast.ast-decl-box-shared-view a-inner-box)
            (ast.ast-decl-box-shared-view b-inner-box))]
        [_
          (gen-decl-eq-with-owner
            owner
            env
            (ast.ast-decl-box-shared-view a-inner-box)
            b)])]
    [_ false]))

(define (gen-key-exprs-with-owner
  [owner : (& owner SpecOwnerContext)]
  [exprs : (& exprs ast.AstExprList)]
  [env : (& env ctfe.CtfeEnv)]
  [fuel : i64]) : ResultGenKey
  (gen-key-exprs-at-with-owner owner exprs 0 env fuel))

(define (gen-key-exprs-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [env : (& env ctfe.CtfeEnv)]
  [fuel : i64]) : ResultGenKey
  (if (>= index exprs.len)
    (Ok "none" fuel)
    (let
      [head-id : i64 (ast.ast-expr-list-get exprs index 0)]
      [head-expr : ast.AstExpr (spec-owner-expr-get owner head-id)]
      (match (ctfe.compiler-ctfe-eval
        (ast.ast-place-shared-view head-expr)
        env
        fuel)
        [(Ok value head-fuel)
          (match value
            [(String text _)
              (match (gen-key-exprs-at-with-owner
                owner
                exprs
                (+ index 1)
                env
                head-fuel)
                [(Ok tail tail-fuel)
                  (Ok
                    (str_cat.str-cat (spec-string-key text) "_" tail)
                    tail-fuel)]
                [(Err diag) (Err diag)])]
            [(Name text _)
              (match (gen-key-exprs-at-with-owner
                owner
                exprs
                (+ index 1)
                env
                head-fuel)
                [(Ok tail tail-fuel)
                  (Ok
                    (str_cat.str-cat (spec-string-key text) "_" tail)
                    tail-fuel)]
                [(Err diag) (Err diag)])]
            [_
              (Err
                (box
                  (spec-diagnostic-at-expr
                    head-expr
                    "generated-decl: key expression must evaluate to String")))])]
        [(Err diag) (Err diag)]))))

(define (gen-full-key
  [module : String]
  [generator : String]
  [item : String]
  [arg-key : String]) : String
  (str_cat.str-cat
    "generated:"
    (spec-string-key module)
    ":"
    (spec-string-key generator)
    ":"
    (spec-string-key item)
    ":"
    arg-key))

(define (gen-key-prefix? [key : (& key str)] [prefix : String]) : bool
  (let
    [prefix-len : i64 (string.string-length prefix)]
    (if (< (string.string-length key) prefix-len)
      false
      (string.eq (string.substring key 0 prefix-len) prefix))))

(define (gen-full-key? [key : (& key str)]) : bool
  (gen-key-prefix? key "generated:"))

(define (gen-decls-macro-key? [key : (& key str)]) : bool
  (gen-key-prefix? key "decls:"))

(define (gen-metadata-key-normalizable? [key : (& key str)]) : bool
  (or (string.eq key "") (gen-full-key? key) (gen-decls-macro-key? key)))

(define (gen-registration-key
  [module : String]
  [generator : String]
  [item : String]
  [arg-key : String]) : String
  (if (gen-full-key? arg-key)
    arg-key
    (gen-full-key module generator item arg-key)))

(define (gen-incompatible-diag [item : String] [key : String]) : cdiag.CompilerDiagnostic
  (cdiag.compiler-diagnostic-with-note
    (cdiag.compiler-diagnostic-with-note
      (cdiag.compiler-diagnostic-at-start
        ""
        (str_cat.str-cat
          "generated-decl: duplicate generated key for "
          (spec-place-shared-view item)
          " has incompatible payload"))
      (str_cat.str-cat "conflicting generated item: " item))
    (str_cat.str-cat "generated identity: " key)))

(define (gen-register-generated-decl-with-owner
  [owner : (& owner SpecOwnerContext)]
  [env : (& env ctfe.CtfeEnv)]
  [template : ast.AstDecl]
  [module-id : i64]
  [item-id : i64]
  [generator : String]
  [item : String]
  [args : ast.AstExprList]
  [arg-key : String]
  [registry : GenRegistry]) : ResultGenDecl
  (let
    [module : String
      (if (< module-id 0)
        ""
        (spec_ci.intern-compat-state-str
          (spec-owner-intern-state owner)
          module-id))]
    [structural-key : SpecStructuralKey
      (gen-registry-structural-key-with-owner
        owner
        module-id
        item-id
        (spec-place-shared-view generator)
        (spec-place-shared-view item)
        (spec-place-shared-view arg-key))]
    (match (gen-registry-lookup-with-owner registry structural-key)
      [(None)
        (let
          ;; AstGeneratedDeclMeta is a persisted diagnostic/output boundary and
          ;; still carries the stable textual identity. Registry identity above
          ;; is already structural and never probes this rendered spelling.
          [key : String
            (gen-registration-key
              module
              (spec-place-shared-view generator)
              (spec-place-shared-view item)
              arg-key)]
          (Ok
            (gen-single-decl-list
              (ast.ast-decl-comptime-decl-with-meta
                (Some generator item args key)
                (ast.ast-place-shared-view template)))
            (gen-registry-insert-with-owner registry structural-key template)
            module-id))]
      [(Some existing)
        (if (gen-decl-eq-with-owner
          owner
          env
          existing
          (ast.ast-place-shared-view template))
          (Ok (ast.ast-decl-list-new) registry module-id)
          (let
            [key : String
              (gen-registration-key
                module
                (spec-place-shared-view generator)
                (spec-place-shared-view item)
                arg-key)]
            (Err
              (box
                (spec-generated-context-diagnostic-with-owner
                  owner
                  (spec-generated-origin-diagnostic-with-owner
                    owner
                    template
                    args
                    (str_cat.str-cat
                      "generated-decl: duplicate generated key for "
                      (spec-place-shared-view item)
                      " has incompatible payload"))
                  generator
                  item
                  key)))))])))

(define (gen-metadata-arg-key-with-owner
  [owner : (& owner SpecOwnerContext)]
  [meta-key : String]
  [args : (& args ast.AstExprList)]
  [env : (& env ctfe.CtfeEnv)]) : ResultGenKey
  (if (> (string.string-length meta-key) 0)
    (Ok meta-key (ctfe.ctfe-fuel-limit))
    (gen-key-exprs-with-owner owner args env (ctfe.ctfe-fuel-limit))))

(define (gen-decl-runtime-template [decl : ast.AstDecl]) : ast.AstDecl
  ;; Strip generation provenance, not the aggregate's semantic marker flags.
  (ast.ast-decl-with-meta
    (ast.ast-decl-meta-runtime-with-aggregate-markers
      (ast.ast-decl-aggregate-markers decl))
    decl))

(define (gen-rewrite-generated-decl-with-owner
  [owner : (& owner SpecOwnerContext)]
  [decl : ast.AstDecl]
  [module-id : i64]
  [registry : GenRegistry]
  [env : (& env ctfe.CtfeEnv)]
  [generator : String]
  [item : String]
  [args : ast.AstExprList]
  [meta-key : String]) : ResultGenDecl
  (match (gen-decl-visible-name-id (ast.ast-place-shared-view decl))
    [(None)
      (Err
        (box
          (spec-generated-context-diagnostic-with-owner
            owner
            (spec-generated-origin-diagnostic-with-owner
              owner
              (gen-decl-runtime-template decl)
              args
              "generated-decl: generated payload must declare a visible item")
            generator
            item
            meta-key)))]
    [(Some actual-id)
      (let
        [actual-name : String
          (spec_ci.intern-compat-state-str
            (spec-owner-intern-state owner)
            actual-id)]
        (if (not (string.eq item actual-name))
          (Err
            (box
              (spec-generated-context-diagnostic-with-owner
                owner
                (spec-generated-origin-diagnostic-with-owner
                  owner
                  (gen-decl-runtime-template decl)
                  args
                  (str_cat.str-cat
                    "generated-decl: metadata item "
                    (spec-place-shared-view item)
                    " does not match payload "
                    actual-name))
                generator
                item
                meta-key)))
          (match (gen-metadata-arg-key-with-owner
            owner
            (spec-place-shared-view meta-key)
            args
            env)
            [(Ok arg-key _)
              (gen-register-generated-decl-with-owner
                owner
                env
                (gen-decl-runtime-template decl)
                module-id
                actual-id
                generator
                item
                args
                arg-key
                registry)]
            [(Err diag)
              (Err
                (box
                  (spec-generated-context-diagnostic-with-owner
                    owner
                    (cdiag.compiler-diagnostic-box-shared-view diag)
                    generator
                    item
                    meta-key)))])))]))

(define (gen-rewrite-decl-with-owner
  [owner : (& owner SpecOwnerContext)]
  [decl : ast.AstDecl]
  [module-id : i64]
  [registry : GenRegistry]
  [env : (& env ctfe.CtfeEnv)]) : ResultGenDecl
  (match (ast.ast-place-shared-view decl)
    [(Module name) (Ok (gen-single-decl-list decl) registry name)]
    [_
      (match (ast.ast-decl-generated-meta decl)
        [(No) (Ok (gen-single-decl-list decl) registry module-id)]
        [(Some generator item args meta-key)
          (if (not (gen-metadata-key-normalizable? meta-key))
            (Ok (gen-single-decl-list decl) registry module-id)
            (gen-rewrite-generated-decl-with-owner
              owner
              decl
              module-id
              registry
              env
              generator
              item
              args
              meta-key))])]))

(define (gen-path-list-head-or
  [paths : ast.AstDeclPathList]
  [fallback : String]) : String
  (match (ast.ast-decl-path-list-step paths)
    [(Cons path _) path]
    [(Nil) fallback]))

(define (gen-path-list-tail [paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (match (ast.ast-decl-path-list-step paths)
    [(Cons _ rest-box)
      (let
        [rest : ast.AstDeclPathList rest-box]
        rest)]
    [(Nil) (ast.ast-decl-path-list-new)]))

(define (gen-path-list-for-decls
  [decls : ast.AstDeclList]
  [path : String]
  [owner-id : i64]
  [provenance-id : i64]
  [rest-paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [out : ast.AstDeclPathList
      (ast.ast-decl-path-list-with-capacity
        (+
          (ast.ast-decl-list-len (& decls))
          (ast.ast-decl-path-list-len (& rest-paths))))]
    [index : i64 0]
    [count : i64 (ast.ast-decl-list-len (& decls))]
    (while (< index count)
      (ast.ast-decl-path-list-push-with-owner-and-provenance-id
        (&mut out)
        (spec-place-shared-view path)
        owner-id
        provenance-id)
      (set! index (+ index 1)))
    (ast.ast-decl-path-list-append-from (&mut out) (& rest-paths) 0)
    out))

(define (gen-path-list-push-for-decls
  [out : (&mut out ast.AstDeclPathList)]
  [decls : ast.AstDeclList]
  [path : String]
  [owner-id : i64]
  [provenance-id : i64]
  [index : i64]) : unit
  (unless
    (>= index (ast.ast-decl-list-len (& decls)))
    (ast.ast-decl-path-list-push-with-owner-and-provenance-id
      out
      (spec-place-shared-view path)
      owner-id
      provenance-id)
    (gen-path-list-push-for-decls
      out
      decls
      path
      owner-id
      provenance-id
      (+ index 1))))

(define (gen-rewrite-decls-with-owner
  [owner : (& owner SpecOwnerContext)]
  [decls : ast.AstDeclList]
  [module-id : i64]
  [registry : GenRegistry]
  [env : (& env ctfe.CtfeEnv)]) : ResultGenDecls
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [cursor : ast.AstDeclList decls]
    [out : ast.AstDeclList (ast.ast-decl-list-with-capacity count)]
    [out-origins : parser.CompilerParseDeclOriginAliasVec
      (parser.compiler-parse-decl-origin-alias-vec-with-capacity count)]
    [cur-registry : GenRegistry registry]
    [cur-module-id : i64 module-id]
    [result : ResultGenDecls
      (Err
        (box
          (cdiag.compiler-diagnostic-simple
            "<internal>"
            1
            1
            "generated-decl normalization did not finish")))]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step cursor)
        [(Nil)
          (parser.compiler-parse-decl-origin-alias-vec-register!
            (& out)
            (& out-origins))
          (set!
            result
            (Ok
              (ast.ast-place-shared-view out)
              (spec-place-shared-view cur-registry)
              cur-module-id))
          (set! done true)]
        [(Cons decl rest)
          (match (gen-rewrite-decl-with-owner
            owner
            (ast.ast-place-shared-view decl)
            cur-module-id
            (spec-place-shared-view cur-registry)
            env)
            [(Ok rewritten-decls decl-registry decl-module)
              (let
                [out-start : i64 (ast.ast-decl-list-len (& out))]
                [rewritten-count : i64
                  (ast.ast-decl-list-len (& rewritten-decls))]
                (parser.compiler-parse-decl-origin-alias-vec-push-key-slot!
                  (&mut out-origins)
                  out-start
                  rewritten-count
                  (parser.compiler-parse-decl-list-storage-key (& rest))
                  (- rest.offset 1)
                  decl
                  (!= rewritten-count 1))
                (ast.ast-decl-list-append-from (&mut out) (& rewritten-decls) 0)
                (set! cur-registry decl-registry)
                (set! cur-module-id decl-module)
                (set! cursor rest))]
            [(Err diag)
              (set! result (Err diag))
              (set! done true)])]))
    result))

(define (gen-rewrite-decls-with-paths-and-owner
  [owner : (& owner SpecOwnerContext)]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [module-id : i64]
  [registry : GenRegistry]
  [env : (& env ctfe.CtfeEnv)]) : ResultGenDeclsWithPaths
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [decl-cursor : ast.AstDeclList decls]
    [path-cursor : ast.AstDeclPathList paths]
    [out : ast.AstDeclList (ast.ast-decl-list-with-capacity count)]
    [out-paths : ast.AstDeclPathList
      (ast.ast-decl-path-list-with-capacity count)]
    [out-origins : parser.CompilerParseDeclOriginAliasVec
      (parser.compiler-parse-decl-origin-alias-vec-with-capacity count)]
    [cur-registry : GenRegistry registry]
    [cur-module-id : i64 module-id]
    [result : ResultGenDeclsWithPaths
      (Err
        (box
          (cdiag.compiler-diagnostic-simple
            "<internal>"
            1
            1
            "generated-decl normalization with paths did not finish")))]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step decl-cursor)
        [(Nil)
          (parser.compiler-parse-decl-origin-alias-vec-register!
            (& out)
            (& out-origins))
          (set!
            result
            (Ok
              (ast.ast-place-shared-view out)
              (spec-place-shared-view out-paths)
              (spec-place-shared-view cur-registry)
              cur-module-id))
          (set! done true)]
        [(Cons decl rest)
          (let
            [decl-path : String
              (gen-path-list-head-or
                (spec-place-shared-view path-cursor)
                (spec-place-shared-view fallback-path))]
            [owner-id : i64
              (ast.ast-decl-path-list-owner-id
                (& path-cursor)
                0
                cbi.compiler-builtin-id-fix-empty)]
            [provenance-id : i64
              (ast.ast-decl-path-list-provenance-id
                (& path-cursor)
                0
                cbi.compiler-builtin-id-fix-empty)]
            (match (gen-rewrite-decl-with-owner
              owner
              (ast.ast-place-shared-view decl)
              cur-module-id
              (spec-place-shared-view cur-registry)
              env)
              [(Ok rewritten-decls decl-registry decl-module)
                (let
                  [out-start : i64 (ast.ast-decl-list-len (& out))]
                  [rewritten-count : i64
                    (ast.ast-decl-list-len (& rewritten-decls))]
                  (parser.compiler-parse-decl-origin-alias-vec-push-key-slot!
                    (&mut out-origins)
                    out-start
                    rewritten-count
                    (parser.compiler-parse-decl-list-storage-key (& rest))
                    (- rest.offset 1)
                    decl
                    (!= rewritten-count 1))
                  (ast.ast-decl-list-append-from
                    (&mut out)
                    (& rewritten-decls)
                    0)
                  (gen-path-list-push-for-decls
                    (&mut out-paths)
                    rewritten-decls
                    decl-path
                    owner-id
                    provenance-id
                    0)
                  (set! cur-registry decl-registry)
                  (set! cur-module-id decl-module)
                  (set! decl-cursor rest)
                  (set! path-cursor (gen-path-list-tail path-cursor)))]
              [(Err diag)
                (set!
                  result
                  (Err
                    (box
                      (cdiag.compiler-diagnostic-with-fallback-path
                        (cdiag.compiler-diagnostic-box-shared-view diag)
                        decl-path))))
                (set! done true)]))]))
    result))

(define (gen-normalize-program-with-pools-and-intern-state
  [program : ast.AstProgram]
  [owner : (& owner SpecOwnerContext)]) : ResultGenProgram
  (match (ast.ast-place-shared-view program)
    [(Program decls-box)
      (let
        [decls : ast.AstDeclList (ast.ast-decl-list-box-shared-view decls-box)]
        [env : ctfe.CtfeEnv
          (spec-owner-ctfe-env
            owner
            (ctfe.ctfe-reflections-from-program program))]
        (match (gen-rewrite-decls-with-owner
          owner
          decls
          -1
          (gen-registry-empty)
          env)
          [(Ok rewritten _ _) (Ok (ast.ast-program rewritten))]
          [(Err diag) (Err diag)]))]))

(define (gen-normalize-program-with-paths-and-pools-and-intern-state
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [owner : (& owner SpecOwnerContext)]) : ResultGenProgramWithPaths
  (match (ast.ast-place-shared-view program)
    [(Program decls-box)
      (let
        [decls : ast.AstDeclList (ast.ast-decl-list-box-shared-view decls-box)]
        [env : ctfe.CtfeEnv
          (spec-owner-ctfe-env
            owner
            (ctfe.ctfe-reflections-from-program program))]
        (match (gen-rewrite-decls-with-paths-and-owner
          owner
          decls
          paths
          fallback-path
          -1
          (gen-registry-empty)
          env)
          [(Ok rewritten rewritten-paths _ _)
            (Ok (ast.ast-program rewritten) rewritten-paths)]
          [(Err diag) (Err diag)]))]))

;; Legacy normalization adapter. It captures the active compatibility views
;; once, routes all work through the owner entrypoint above, preserves the
;; owner's mutated pool cells while restoring the prior ambient context, and
;; publishes the owner's interner on both success and error paths.
(define (gen-normalize-program-with-pools
  [program : ast.AstProgram]
  [pools : ast.AstNodePoolContext]) : ResultGenProgram
  (let
    [previous-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [intern-state : spec_ci.InternCompatState
      (spec_ci.intern-compat-state-capture-active)]
    (ast.ast-node-pool-context-install! pools)
    (spec_ci.intern-compat-state-install! intern-state)
    (let
      [owner : SpecOwnerContext (spec-owner-context-new pools intern-state)]
      [result : ResultGenProgram
        (gen-normalize-program-with-pools-and-intern-state program owner)]
      (ast.ast-node-pool-context-install! previous-pools)
      (spec_ci.intern-compat-state-install! intern-state)
      result)))

(define (gen-normalize-program [program : ast.AstProgram]) : ResultGenProgram
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultGenProgram (gen-normalize-program-with-pools program pools)]
    (ast.ast-node-pool-context-install! pools)
    result))

(define (gen-decl-needs-normalize? [decl : ast.AstDecl]) : bool
  (match (ast.ast-decl-generated-meta decl)
    [(Some _ _ _ key) (gen-metadata-key-normalizable? key)]
    [(No) false]))

(define (gen-decls-needed? [decls : ast.AstDeclList]) : bool
  (let
    [cursor : ast.AstDeclList decls]
    [needed : bool false]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step cursor)
        [(Nil) (set! done true)]
        [(Cons decl rest)
          (if (gen-decl-needs-normalize? decl)
            (begin
              (set! needed true)
              (set! done true))
            (set! cursor rest))]))
    needed))

(define (spec-value-runtime-type-matches?
  [state : SpecState]
  [value : ctfe.CompilerCtfeValue]
  [ty : ast.AstType]) : bool
  (let
    [env : ctfe.CtfeEnv (spec-state-ctfe-env state)]
    (cbi.compiler-builtin-refresh!)
    (match value
      [(I64 _) (ctfe.ctfe-type-eq-in-env env ty (I64))]
      [(F64 _) (ctfe.ctfe-type-eq-in-env env ty (F64))]
      [(F32 _) (ctfe.ctfe-type-eq-in-env env ty (F32))]
      [(Bool _) (ctfe.ctfe-type-eq-in-env env ty (Bool))]
      [(Char _) (ctfe.ctfe-type-eq-in-env env ty (Char))]
      [(String _ _) (ctfe.ctfe-type-eq-in-env env ty (String))]
      [(Name _ _) (ctfe.ctfe-type-eq-in-env env ty (String))]
      [(Unit) (ctfe.ctfe-type-eq-in-env env ty (Unit))]
      [(Type _) false]
      [(Expr _ _) (ctfe.ctfe-type-eq-in-env env ty (Expr))]
      [(CapturedExpr _ _ _) (ctfe.ctfe-type-eq-in-env env ty (Expr))]
      [(ExprList _) (ctfe.ctfe-type-eq-in-env env ty (ExprList))]
      [(CapturedExprList _ _) (ctfe.ctfe-type-eq-in-env env ty (ExprList))]
      [(ExprClause _)
        (ctfe.ctfe-type-eq-in-env
          env
          ty
          (Var cbi.compiler-builtin-id-fix-ExprClause))]
      [(CapturedExprClause _ _)
        (ctfe.ctfe-type-eq-in-env
          env
          ty
          (Var cbi.compiler-builtin-id-fix-ExprClause))]
      [(ExprClauseList _)
        (ctfe.ctfe-type-eq-in-env
          env
          ty
          (Var cbi.compiler-builtin-id-fix-ExprClauseList))]
      [(CapturedExprClauseList _ _)
        (ctfe.ctfe-type-eq-in-env
          env
          ty
          (Var cbi.compiler-builtin-id-fix-ExprClauseList))]
      [(ExprBindingClause _)
        (ctfe.ctfe-type-eq-in-env
          env
          ty
          (Var cbi.compiler-builtin-id-fix-ExprBindingClause))]
      [(ExprBindingClauseList _)
        (ctfe.ctfe-type-eq-in-env
          env
          ty
          (Var cbi.compiler-builtin-id-fix-ExprBindingClauseList))]
      [(Pattern _)
        (ctfe.ctfe-type-eq-in-env
          env
          ty
          (Var cbi.compiler-builtin-id-fix-Pattern))]
      [(PatternList _)
        (ctfe.ctfe-type-eq-in-env
          env
          ty
          (Var cbi.compiler-builtin-id-fix-PatternList))]
      [(MatchArm _)
        (ctfe.ctfe-type-eq-in-env
          env
          ty
          (Var cbi.compiler-builtin-id-fix-MatchArm))]
      [(MatchArmList _)
        (ctfe.ctfe-type-eq-in-env
          env
          ty
          (Var cbi.compiler-builtin-id-fix-MatchArmList))]
      [(LetBinding _)
        (ctfe.ctfe-type-eq-in-env
          env
          ty
          (Var cbi.compiler-builtin-id-fix-LetBinding))]
      [(LetBindingList _)
        (ctfe.ctfe-type-eq-in-env
          env
          ty
          (Var cbi.compiler-builtin-id-fix-LetBindingList))]
      [(TypeInfo _) false]
      [(TypeInfoBox _) false]
      [(TypeInfoList _) false]
      [(TypeField _ _) false]
      [(TypeFieldList _) false]
      [(TypeVariantPayload _) false]
      [(TypeVariantPayloadList _) false]
      [(TypeVariant _ _) false]
      [(TypeVariantList _) false])))

(define (spec-value-type-label [value : ctfe.CompilerCtfeValue]) : String
  (match value
    [(I64 _) "i64"]
    [(F64 _) "f64"]
    [(F32 _) "f32"]
    [(Bool _) "bool"]
    [(Char _) "char"]
    [(String _ _) "String"]
    [(Name _ _) "String"]
    [(Unit) "unit"]
    [(Type _) "type"]
    [(Expr _ _) "Expr"]
    [(CapturedExpr _ _ _) "Expr"]
    [(ExprList _) "expr-list"]
    [(CapturedExprList _ _) "expr-list"]
    [(ExprClause _) "ExprClause"]
    [(CapturedExprClause _ _) "ExprClause"]
    [(ExprClauseList _) "ExprClauseList"]
    [(CapturedExprClauseList _ _) "ExprClauseList"]
    [(ExprBindingClause _) "ExprBindingClause"]
    [(ExprBindingClauseList _) "ExprBindingClauseList"]
    [(Pattern _) "Pattern"]
    [(PatternList _) "PatternList"]
    [(MatchArm _) "MatchArm"]
    [(MatchArmList _) "MatchArmList"]
    [(LetBinding _) "LetBinding"]
    [(LetBindingList _) "LetBindingList"]
    [(TypeInfo _) "TypeInfo"]
    [(TypeInfoBox _) "TypeInfoBox"]
    [(TypeInfoList _) "TypeInfoList"]
    [(TypeField _ _) "TypeField"]
    [(TypeFieldList _) "TypeFieldList"]
    [(TypeVariantPayload _) "TypeVariantPayload"]
    [(TypeVariantPayloadList _) "TypeVariantPayloadList"]
    [(TypeVariant _ _) "TypeVariant"]
    [(TypeVariantList _) "TypeVariantList"]))

;; Head-first scan: slot 0 is the newest binding, so the first hit is the one
;; that shadows. Returns -1 when the name is unbound.
(define (spec-type-subst-find
  [subs : (& subs SpecTypeSubst)]
  [name-id : i64]
  [at : i64]) : i64
  (if (>= at subs.len)
    (- 0 1)
    (match (spec-type-subst-at subs at)
      [(Bind key-id _)
        (if (= key-id name-id)
          at
          (spec-type-subst-find subs name-id (+ at 1)))])))

(define (spec-type-subst-lookup [subs : (& subs SpecTypeSubst)] [name-id : i64]) : SpecMaybeId
  (if (< (spec-type-subst-find subs name-id 0) 0)
    (None)
    (Some name-id)))

(define (spec-type-subst-type [subs : (& subs SpecTypeSubst)] [name-id : i64]) : ast.AstType
  (let
    [at : i64 (spec-type-subst-find subs name-id 0)]
    (if (< at 0)
      (Var name-id)
      (match (spec-type-subst-at subs at)
        [(Bind _ ty) ty]))))

(define (spec-value-subst-find
  [subs : (& subs SpecValueSubst)]
  [name-id : i64]
  [at : i64]) : i64
  (if (>= at subs.len)
    (- 0 1)
    (match (spec-value-subst-at subs at)
      [(Bind key-id _)
        (if (= key-id name-id)
          at
          (spec-value-subst-find subs name-id (+ at 1)))])))

(define (spec-value-subst-lookup
  [subs : (& subs SpecValueSubst)]
  [name-id : i64]) : SpecMaybeId
  (if (< (spec-value-subst-find subs name-id 0) 0)
    (None)
    (Some name-id)))

(define (spec-value-subst-value
  [subs : (& subs SpecValueSubst)]
  [name-id : i64]) : ctfe.CompilerCtfeValue
  (let
    [at : i64 (spec-value-subst-find subs name-id 0)]
    (if (< at 0)
      (Unit)
      (match (spec-value-subst-at subs at)
        [(Bind _ value) value]))))

;; An unbound name leaves the environment alone, so the hot inner-scope walk
;; shares the outer buffer instead of rebuilding it.
(define (spec-value-subst-remove-name
  [subs : (& subs SpecValueSubst)]
  [name-id : i64]) : SpecValueSubst
  (if (< (spec-value-subst-find subs name-id 0) 0)
    (spec-value-subst-shared-view subs)
    (let
      [slots : (__tl_dyn-array SpecValueBinding)
        (__tl_make-array SpecValueBinding subs.len)]
      [at : i64 0]
      [kept : i64 0]
      (while (< at subs.len)
        (match (spec-value-subst-at subs at)
          [(Bind key-id _)
            (unless
              (= key-id name-id)
              (set! (array-ref slots kept) (spec-value-subst-at subs at))
              (set! kept (+ kept 1)))])
        (set! at (+ at 1)))
      (spec-value-subst-from-slots slots kept))))

(define (spec-value-subst-remove-params
  [subs : (& subs SpecValueSubst)]
  [params : (& params ast.AstParamList)]) : SpecValueSubst
  (spec-value-subst-remove-params-at
    (spec-value-subst-shared-view subs)
    params
    0))

(define (spec-value-subst-remove-params-at
  [subs : SpecValueSubst]
  [params : (& params ast.AstParamList)]
  [index : i64]) : SpecValueSubst
  (if (>= index (ast.ast-param-list-len params))
    subs
    (spec-value-subst-remove-params-at
      (spec-value-subst-remove-name
        subs
        (spec-param-name-id
          (ast.ast-param-list-get params index (ast.ast-param-fallback))))
      params
      (+ index 1))))

(define (spec-value-subst-remove-let-binding-names
  [subs : (& subs SpecValueSubst)]
  [bindings : ast.AstLetBindingList]) : SpecValueSubst
  (spec-value-subst-remove-let-binding-names-at
    (spec-value-subst-shared-view subs)
    (& bindings)
    0))

(define (spec-value-subst-remove-let-binding-names-at
  [subs : SpecValueSubst]
  [bindings : (& bindings ast.AstLetBindingList)]
  [index : i64]) : SpecValueSubst
  (if (>= index (ast.ast-let-binding-list-len bindings))
    subs
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(Binding name _ _)
        (spec-value-subst-remove-let-binding-names-at
          (spec-value-subst-remove-name subs name)
          bindings
          (+ index 1))])))

(define (spec-value-subst-remove-pattern
  [subs : (& subs SpecValueSubst)]
  [pattern : ast.AstPattern]) : SpecValueSubst
  (match pattern
    [(Var name _) (spec-value-subst-remove-name subs name)]
    [(Tuple patterns-box)
      (let
        [patterns : ast.AstPatternList
          (ast.ast-pattern-list-box-shared-view patterns-box)]
        (spec-value-subst-remove-pattern-list subs patterns))]
    [(Array patterns-box)
      (let
        [patterns : ast.AstPatternList
          (ast.ast-pattern-list-box-shared-view patterns-box)]
        (spec-value-subst-remove-pattern-list subs patterns))]
    [(Slice patterns-box _)
      (let
        [patterns : ast.AstPatternList
          (ast.ast-pattern-list-box-shared-view patterns-box)]
        (spec-value-subst-remove-pattern-list subs patterns))]
    [(Wildcard) (spec-value-subst-shared-view subs)]
    [(Binding name) (spec-value-subst-remove-name subs name)]
    [(Variant _ patterns-box)
      (let
        [patterns : ast.AstPatternList
          (ast.ast-pattern-list-box-shared-view patterns-box)]
        (spec-value-subst-remove-pattern-list subs patterns))]
    [(Literal _) (spec-value-subst-shared-view subs)]))

(define (spec-value-subst-remove-pattern-list
  [subs : (& subs SpecValueSubst)]
  [patterns : ast.AstPatternList]) : SpecValueSubst
  (spec-value-subst-remove-pattern-list-at
    (spec-value-subst-shared-view subs)
    (& patterns)
    0))

(define (spec-value-subst-remove-pattern-list-at
  [subs : SpecValueSubst]
  [patterns : (& patterns ast.AstPatternList)]
  [index : i64]) : SpecValueSubst
  (if (>= index patterns.len)
    subs
    (spec-value-subst-remove-pattern-list-at
      (spec-value-subst-remove-pattern
        subs
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback)))
      patterns
      (+ index 1))))

(define (spec-type-subst-remove-name
  [subs : (& subs SpecTypeSubst)]
  [name-id : i64]) : SpecTypeSubst
  (if (< (spec-type-subst-find subs name-id 0) 0)
    (spec-type-subst-shared-view subs)
    (let
      [slots : (__tl_dyn-array SpecTypeBinding)
        (__tl_make-array SpecTypeBinding subs.len)]
      [at : i64 0]
      [kept : i64 0]
      (while (< at subs.len)
        (match (spec-type-subst-at subs at)
          [(Bind key-id _)
            (unless
              (= key-id name-id)
              (set! (array-ref slots kept) (spec-type-subst-at subs at))
              (set! kept (+ kept 1)))])
        (set! at (+ at 1)))
      (spec-type-subst-from-slots slots kept))))

(define (spec-type-subst-remove-params
  [subs : (& subs SpecTypeSubst)]
  [params : (& params ast.AstParamList)]) : SpecTypeSubst
  (spec-type-subst-remove-params-at (spec-type-subst-shared-view subs) params 0))

(define (spec-type-subst-remove-params-at
  [subs : SpecTypeSubst]
  [params : (& params ast.AstParamList)]
  [index : i64]) : SpecTypeSubst
  (if (>= index (ast.ast-param-list-len params))
    subs
    (spec-type-subst-remove-params-at
      (spec-type-subst-remove-name
        subs
        (spec-param-name-id
          (ast.ast-param-list-get params index (ast.ast-param-fallback))))
      params
      (+ index 1))))

(define (spec-type-subst-remove-let-binding-names
  [subs : (& subs SpecTypeSubst)]
  [bindings : (& bindings ast.AstLetBindingList)]) : SpecTypeSubst
  (spec-type-subst-remove-let-binding-names-at
    (spec-type-subst-shared-view subs)
    bindings
    0))

(define (spec-type-subst-remove-let-binding-names-at
  [subs : SpecTypeSubst]
  [bindings : (& bindings ast.AstLetBindingList)]
  [index : i64]) : SpecTypeSubst
  (if (>= index (ast.ast-let-binding-list-len bindings))
    subs
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(Binding name _ _)
        (spec-type-subst-remove-let-binding-names-at
          (spec-type-subst-remove-name subs name)
          bindings
          (+ index 1))])))

(define (spec-type-subst-remove-pattern
  [subs : (& subs SpecTypeSubst)]
  [pattern : ast.AstPattern]) : SpecTypeSubst
  (match pattern
    [(Var name _) (spec-type-subst-remove-name subs name)]
    [(Tuple patterns-box)
      (let
        [patterns : ast.AstPatternList
          (ast.ast-pattern-list-box-shared-view patterns-box)]
        (spec-type-subst-remove-pattern-list subs patterns))]
    [(Array patterns-box)
      (let
        [patterns : ast.AstPatternList
          (ast.ast-pattern-list-box-shared-view patterns-box)]
        (spec-type-subst-remove-pattern-list subs patterns))]
    [(Slice patterns-box _)
      (let
        [patterns : ast.AstPatternList
          (ast.ast-pattern-list-box-shared-view patterns-box)]
        (spec-type-subst-remove-pattern-list subs patterns))]
    [(Wildcard) (spec-type-subst-shared-view subs)]
    [(Binding name) (spec-type-subst-remove-name subs name)]
    [(Variant _ patterns-box)
      (let
        [patterns : ast.AstPatternList
          (ast.ast-pattern-list-box-shared-view patterns-box)]
        (spec-type-subst-remove-pattern-list subs patterns))]
    [(Literal _) (spec-type-subst-shared-view subs)]))

(define (spec-type-subst-remove-pattern-list
  [subs : (& subs SpecTypeSubst)]
  [patterns : ast.AstPatternList]) : SpecTypeSubst
  (spec-type-subst-remove-pattern-list-at
    (spec-type-subst-shared-view subs)
    (& patterns)
    0))

(define (spec-type-subst-remove-pattern-list-at
  [subs : SpecTypeSubst]
  [patterns : (& patterns ast.AstPatternList)]
  [index : i64]) : SpecTypeSubst
  (if (>= index patterns.len)
    subs
    (spec-type-subst-remove-pattern-list-at
      (spec-type-subst-remove-pattern
        subs
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback)))
      patterns
      (+ index 1))))

(define (spec-substitute-type-with-owner
  [owner : (& owner SpecOwnerContext)]
  [ty : ast.AstType]
  [subs : (& subs SpecTypeSubst)]) : ast.AstType
  (match (ast.ast-place-shared-view ty)
    [(Func args ret)
      (ast.ast-ty-func-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-list-with-owner
          owner
          (ast.ast-type-list-box-shared-view args)
          subs)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner ret)
          subs))]
    [(Tuple elems)
      (Tuple
        (box
          (spec-substitute-type-list-with-owner
            owner
            (ast.ast-type-list-box-shared-view elems)
            subs)))]
    [(Array elem count)
      (ast.ast-ty-array-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner elem)
          subs)
        count)]
    [(DynArray elem)
      (ast.ast-ty-dyn-array-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner elem)
          subs))]
    [(Slice elem)
      (ast.ast-ty-slice-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner elem)
          subs))]
    [(Box elem)
      (ast.ast-ty-box-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner elem)
          subs))]
    [(CFunc signature mode)
      (CFunc
        (ast.ast-node-pool-context-type-push
          (spec-owner-pools owner)
          (spec-substitute-type-with-owner
            owner
            (spec-owner-type-get owner signature)
            subs))
        mode)]
    [(Ptr elem)
      (ast.ast-ty-ptr-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner elem)
          subs))]
    [(MutPtr elem)
      (ast.ast-ty-mut-ptr-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner elem)
          subs))]
    [(Ref region inner)
      (ast.ast-ty-ref-with-pools
        (spec-owner-pools owner)
        region
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner inner)
          subs))]
    [(MutRef region inner)
      (ast.ast-ty-mut-ref-with-pools
        (spec-owner-pools owner)
        region
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner inner)
          subs))]
    [(Region region inner)
      (ast.ast-ty-region-with-pools
        (spec-owner-pools owner)
        region
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner inner)
          subs))]
    [(Invalidate lifetime inner)
      (ast.ast-ty-invalidate-with-pools
        (spec-owner-pools owner)
        lifetime
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner inner)
          subs))]
    [(EnumArgs name lifetimes) (EnumArgs name lifetimes)]
    [(StructArgs name lifetimes) (StructArgs name lifetimes)]
    [(VarArgs name lifetimes)
      (match (spec-type-subst-lookup subs name)
        [(Some _) (spec-type-subst-type subs name)]
        [(None) (VarArgs name lifetimes)])]
    [(Var name)
      (match (spec-type-subst-lookup subs name)
        [(Some _) (spec-type-subst-type subs name)]
        [(None) ty])]
    [_ ty]))

(define (spec-substitute-type-list-into-with-owner
  [owner : (& owner SpecOwnerContext)]
  [types : (& types ast.AstTypeList)]
  [subs : (& subs SpecTypeSubst)]
  [out : (&mut out ast.AstTypeList)]
  [index : i64]) : unit
  (unless
    (>= index (ast.ast-type-list-len types))
    (ast.ast-type-list-push
      out
      (spec-owner-type-push
        owner
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get
            owner
            (ast.ast-type-list-get types index (ast.ast-type-id-fallback)))
          subs)))
    (spec-substitute-type-list-into-with-owner owner types subs out (+ index 1))))

(define (spec-substitute-type-list-with-owner
  [owner : (& owner SpecOwnerContext)]
  [types : ast.AstTypeList]
  [subs : (& subs SpecTypeSubst)]) : ast.AstTypeList
  (let
    [out : ast.AstTypeList
      (ast.ast-type-list-with-capacity (ast.ast-type-list-len (& types)))]
    (spec-substitute-type-list-into-with-owner
      owner
      (& types)
      subs
      (&mut out)
      0)
    out))

(define (spec-substitute-maybe-type-with-owner
  [owner : (& owner SpecOwnerContext)]
  [ty : ast.AstMaybeType]
  [subs : (& subs SpecTypeSubst)]) : ast.AstMaybeType
  (match ty
    [(No) No]
    [(Some inner) (Some (spec-substitute-type-with-owner owner inner subs))]))

(define (spec-substitute-param-types-with-owner
  [owner : (& owner SpecOwnerContext)]
  [params : ast.AstParamList]
  [subs : (& subs SpecTypeSubst)]) : ast.AstParamList
  (let
    [out : ast.AstParamList
      (ast.ast-param-list-with-capacity (ast.ast-param-list-len (& params)))]
    (spec-substitute-param-types-into-with-owner
      owner
      (& params)
      subs
      0
      (&mut out))
    out))

(define (spec-substitute-param-types-into-with-owner
  [owner : (& owner SpecOwnerContext)]
  [params : (& params ast.AstParamList)]
  [subs : (& subs SpecTypeSubst)]
  [index : i64]
  [out : (&mut out ast.AstParamList)]) : unit
  (unless
    (>= index (ast.ast-param-list-len params))
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(Param name ty _)
        (ast.ast-param-list-push
          out
          (ast.AstParam.Param
            name
            (spec-substitute-type-with-owner owner ty subs)
            false))])
    (spec-substitute-param-types-into-with-owner
      owner
      params
      subs
      (+ index 1)
      out)))

(define (spec-ctfe-value-to-expr-with-owner
  [owner : (& owner SpecOwnerContext)]
  [value : ctfe.CompilerCtfeValue]
  [origin : ast.AstExpr]) : ResultSpecSubExpr
  (match value
    [(I64 n) (Ok (spec-owner-expr-push owner (Literal (ast.ast-lit-int n))))]
    [(F64 n)
      (Ok
        (spec-owner-expr-push
          owner
          (Literal (Float (cfloat.compiler-float-format-f64 n)))))]
    [(F32 n)
      (Ok
        (ast.ast-expr-ann-with-pools
          (spec-owner-pools owner)
          (spec-owner-expr-push
            owner
            (Literal
              (Float
                (cfloat.compiler-float-format-f64
                  (cfloat.compiler-float-round-f32-as-f64 n)))))
          (F32)))]
    [(Bool b) (Ok (spec-owner-expr-push owner (Literal (Bool b))))]
    [(Char c) (Ok (spec-owner-expr-push owner (Literal (Char c))))]
    [(String _ _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time String value into runtime expression")))]
    [(Name _ _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time String value into runtime expression")))]
    [(Unit) (Ok (spec-owner-expr-push owner (Literal (Unit))))]
    [(Type ty)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            (str_cat.str-cat
              "cannot substitute compile-time type value "
              (spec-type-key-with-owner owner ty)
              " into runtime expression"))))]
    [(Expr _ _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time Expr value into runtime expression")))]
    [(CapturedExpr _ _ _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time Expr value into runtime expression")))]
    [(ExprList _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprList value into runtime expression")))]
    [(CapturedExprList _ _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprList value into runtime expression")))]
    [(ExprClause _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprClause value into runtime expression")))]
    [(CapturedExprClause _ _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprClause value into runtime expression")))]
    [(ExprClauseList _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprClauseList value into runtime expression")))]
    [(CapturedExprClauseList _ _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprClauseList value into runtime expression")))]
    [(ExprBindingClause _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprBindingClause value into runtime expression")))]
    [(ExprBindingClauseList _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprBindingClauseList value into runtime expression")))]
    [(Pattern _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time Pattern value into runtime expression")))]
    [(PatternList _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time PatternList value into runtime expression")))]
    [(MatchArm _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time MatchArm value into runtime expression")))]
    [(MatchArmList _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time MatchArmList value into runtime expression")))]
    [(LetBinding _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time LetBinding value into runtime expression")))]
    [(LetBindingList _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time LetBindingList value into runtime expression")))]
    [(TypeInfo _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeInfo value into runtime expression")))]
    [(TypeInfoBox _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeInfo box value into runtime expression")))]
    [(TypeInfoList _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeInfoList value into runtime expression")))]
    [(TypeField _ _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeField value into runtime expression")))]
    [(TypeFieldList _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeFieldList value into runtime expression")))]
    [(TypeVariantPayload _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariantPayload value into runtime expression")))]
    [(TypeVariantPayloadList _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariantPayloadList value into runtime expression")))]
    [(TypeVariant _ _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariant value into runtime expression")))]
    [(TypeVariantList _)
      (Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariantList value into runtime expression")))]))

(define (spec-expr-var-name-id-with-owner
  [owner : (& owner SpecOwnerContext)]
  [expr : ast.AstExpr]) : SpecMaybeId
  (let
    [pools : ast.AstNodePoolContext (spec-owner-pools owner)]
    (match (ast.ast-expr-unspan-with-pools pools expr)
      [(Var name) (Some name)]
      [_ (None)])))

(define (spec-rewrite-expr-list
  [exprs : ast.AstExprList]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]) : ResultSpecExprList
  (let
    [out : ast.AstExprList (ast.ast-expr-list-with-capacity exprs.len)]
    (match (spec-rewrite-expr-list-at (& exprs) 0 templates state (&mut out))
      [(Ok next-state) (Ok out next-state)]
      [(Err diag) (Err diag)])))

(define (spec-rewrite-expr-list-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]
  [out : (&mut out ast.AstExprList)]) : ResultSpecExprListBuild
  (if (>= index exprs.len)
    (Ok state)
    (let
      [head : ast.AstExpr
        (spec-state-expr-get state (ast.ast-expr-list-get exprs index 0))]
      (match (spec-rewrite-expr head templates state)
        [(Ok rewritten-head head-state)
          (ast.ast-expr-list-push out rewritten-head)
          (spec-rewrite-expr-list-at exprs (+ index 1) templates head-state out)]
        [(Err diag) (Err diag)]))))

(define (spec-rewrite-let-bindings
  [bindings : ast.AstLetBindingList]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]) : ResultSpecLetBindingList
  (let
    [out : ast.AstLetBindingList
      (ast.ast-let-binding-list-with-capacity
        (ast.ast-let-binding-list-len (& bindings)))]
    (match (spec-rewrite-let-bindings-at
      (& bindings)
      0
      templates
      state
      (&mut out))
      [(Ok next-state) (Ok out next-state)]
      [(Err diag) (Err diag)])))

(define (spec-rewrite-let-bindings-at
  [bindings : (& bindings ast.AstLetBindingList)]
  [index : i64]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]
  [out : (&mut out ast.AstLetBindingList)]) : ResultSpecLetBindingListBuild
  (if (>= index (ast.ast-let-binding-list-len bindings))
    (Ok state)
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(Binding name ty value-box)
        (let
          [value : ast.AstExpr (spec-state-expr-get state value-box)]
          [next-templates : SpecTemplateEnv
            (spec-template-env-shadow-name templates name)]
          (match (spec-rewrite-expr value templates state)
            [(Ok rewritten-value value-state)
              (ast.ast-let-binding-list-push
                out
                (ast.ast-let-binding-id name ty rewritten-value))
              (spec-rewrite-let-bindings-at
                bindings
                (+ index 1)
                next-templates
                value-state
                out)]
            [(Err diag) (Err diag)]))])))

(define (spec-rewrite-match-arms
  [arms : ast.AstMatchArmList]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]) : ResultSpecMatchArmList
  (let
    [out : ast.AstMatchArmList (ast.ast-match-arm-list-with-capacity arms.len)]
    (match (spec-rewrite-match-arms-at (& arms) 0 templates state (&mut out))
      [(Ok next-state) (Ok out next-state)]
      [(Err diag) (Err diag)])))

(define (spec-rewrite-match-arms-at
  [arms : (& arms ast.AstMatchArmList)]
  [index : i64]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]
  [out : (&mut out ast.AstMatchArmList)]) : ResultSpecMatchArmListBuild
  (if (>= index arms.len)
    (Ok state)
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(Arm pattern body-box)
        (let
          [body : ast.AstExpr (spec-state-expr-get state body-box)]
          [body-templates : SpecTemplateEnv
            (spec-template-env-shadow-pattern
              templates
              (ast.ast-place-shared-view pattern))]
          (match (spec-rewrite-expr body body-templates state)
            [(Ok rewritten-body body-state)
              (ast.ast-match-arm-list-push
                out
                (ast.ast-match-arm pattern rewritten-body))
              (spec-rewrite-match-arms-at
                arms
                (+ index 1)
                templates
                body-state
                out)]
            [(Err diag) (Err diag)]))])))

(define (spec-rewrite-specialized-call
  [template : SpecTemplate]
  [args : ast.AstExprList]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]
  [origin : ast.AstExpr]) : ResultSpecExpr
  (match (spec-place-shared-view template)
    [(Item name-id params _ _)
      (let
        [name : String
          (spec_ci.intern-compat-state-str (spec-state-intern state) name-id)]
        (match (spec-rewrite-specialized-args
          params
          args
          templates
          (spec-place-shared-view state)
          name)
          [(Ok values runtime-args args-state)
            (match (spec-ensure-specialization
              template
              values
              templates
              args-state
              origin)
              [(Ok specialized-name-id ensure-state)
                (Ok
                  (ast.ast-expr-call-with-pools
                    (spec-state-pools state)
                    (spec-owner-expr-push
                      (spec-state-owner state)
                      (Var specialized-name-id))
                    runtime-args)
                  ensure-state)]
              [(Err diag) (Err diag)])]
          [(Err diag) (Err diag)]))]))

(define (spec-rewrite-specialized-args
  [params : ast.AstParamList]
  [args : ast.AstExprList]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]
  [fn-name : String]) : ResultSpecArgs
  (spec-rewrite-specialized-args-at
    (& params)
    (& args)
    0
    templates
    state
    fn-name))

(define (spec-rewrite-specialized-args-at
  [params : (& params ast.AstParamList)]
  [args : (& args ast.AstExprList)]
  [index : i64]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]
  [fn-name : String]) : ResultSpecArgs
  (cond
    [(>= index (ast.ast-param-list-len params))
      (if (>= index args.len)
        (Ok (spec-value-list-new) (ast.ast-expr-list-new) state)
        (Err
          (box
            (cdiag.compiler-diagnostic-at-start "" "specialize: arity mismatch"))))]
    [(>= index args.len)
      (Err
        (box
          (cdiag.compiler-diagnostic-at-start "" "specialize: arity mismatch")))]
    [else
      (let
        [arg : ast.AstExpr
          (spec-state-expr-get state (ast.ast-expr-list-get args index 0))]
        (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
          [(Param param-name param-ty is-comptime)
            (if is-comptime
              (match (spec-ctfe-eval
                state
                (ast.ast-place-shared-view arg)
                (ctfe.ctfe-fuel-limit))
                [(Ok value _)
                  (if (spec-type-kind? (ast.ast-place-shared-view param-ty))
                    (match (spec-place-shared-view value)
                      [(Type _)
                        (match (spec-rewrite-specialized-args-at
                          params
                          args
                          (+ index 1)
                          templates
                          state
                          fn-name)
                          [(Ok rest-values rest-runtime rest-state)
                            (Ok
                              (spec-value-cons value rest-values)
                              rest-runtime
                              rest-state)]
                          [(Err diag) (Err diag)])]
                      [_
                        (Err
                          (box
                            (spec-diagnostic-at-expr
                              arg
                              (str_cat.str-cat
                                "comptime argument '"
                                (spec_ci.intern-compat-state-str
                                  (spec-state-intern state)
                                  param-name)
                                "' for function '"
                                fn-name
                                "' must be a type value such as `(type i64)`"))))])
                    (if (spec-value-runtime-type-matches?
                      (spec-place-shared-view state)
                      (spec-place-shared-view value)
                      (ast.ast-place-shared-view param-ty))
                      (match (spec-rewrite-specialized-args-at
                        params
                        args
                        (+ index 1)
                        templates
                        state
                        fn-name)
                        [(Ok rest-values rest-runtime rest-state)
                          (Ok
                            (spec-value-cons value rest-values)
                            rest-runtime
                            rest-state)]
                        [(Err diag) (Err diag)])
                      (Err
                        (box
                          (spec-diagnostic-at-expr
                            arg
                            (str_cat.str-cat
                              "comptime argument '"
                              (spec_ci.intern-compat-state-str
                                (spec-state-intern state)
                                param-name)
                              "' for function '"
                              fn-name
                              "' has type "
                              (spec-value-type-label value)
                              ", expected "
                              (spec-type-key-with-owner
                                (spec-state-owner state)
                                param-ty)))))))]
                [(Err diag) (Err diag)])
              (match (spec-rewrite-expr arg templates state)
                [(Ok rewritten-arg arg-state)
                  (match (spec-rewrite-specialized-args-at
                    params
                    args
                    (+ index 1)
                    templates
                    arg-state
                    fn-name)
                    [(Ok values rest-runtime rest-state)
                      (Ok
                        values
                        (ast.ast-expr-cons rewritten-arg rest-runtime)
                        rest-state)]
                    [(Err diag) (Err diag)])]
                [(Err diag) (Err diag)]))]))]))

(define (spec-build-specialization
  [params : ast.AstParamList]
  [values : SpecValueList]) : ResultSpecBuild
  (spec-build-specialization-at (& params) 0 values 0))

(define (spec-build-specialization-at
  [params : (& params ast.AstParamList)]
  [index : i64]
  [values : SpecValueList]
  [at : i64]) : ResultSpecBuild
  (if (>= index (ast.ast-param-list-len params))
    (if (>= at values.len)
      (Ok (ast.ast-param-list-new) (spec-value-subst-new) (spec-type-subst-new))
      (Err
        (box
          (cdiag.compiler-diagnostic-at-start "" "specialize: value mismatch"))))
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(Param name ty is-comptime)
        (if is-comptime
          (if (< at values.len)
            (let
              [value : ctfe.CompilerCtfeValue
                (spec-array-shared-view values.slots at)]
              (match (spec-build-specialization-at
                params
                (+ index 1)
                values
                (+ at 1))
                [(Ok runtime value-subs type-subs)
                  (if (spec-type-kind? ty)
                    (match value
                      [(Type actual-ty)
                        (Ok
                          runtime
                          value-subs
                          (spec-type-subst-cons name actual-ty type-subs))]
                      [_
                        (Err
                          (box
                            (cdiag.compiler-diagnostic-at-start
                              ""
                              "specialize: expected type value")))])
                    (Ok
                      runtime
                      (spec-value-subst-cons name value value-subs)
                      type-subs))]
                [(Err diag) (Err diag)]))
            (Err
              (box
                (cdiag.compiler-diagnostic-at-start
                  ""
                  "specialize: value mismatch"))))
          (match (spec-build-specialization-at params (+ index 1) values at)
            [(Ok runtime value-subs type-subs)
              (Ok
                (ast.ast-param-cons (Param name ty false) runtime)
                value-subs
                type-subs)]
            [(Err diag) (Err diag)]))])))

(define (spec-ensure-specialization
  [template : SpecTemplate]
  [values : SpecValueList]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]
  [_origin : ast.AstExpr]) : ResultSpecEnsure
  (match template
    [(Item name-id params ret body)
      (match (spec-place-shared-view state)
        [(State generated cache ctfe-env pools)
          (let
            [name : String
              (spec_ci.intern-compat-state-str
                (spec-state-intern state)
                name-id)]
            [structural-key : SpecStructuralKey
              (spec-specialization-structural-key-with-owner
                (spec-state-owner state)
                (spec-place-shared-view name)
                values)]
            [cache-key-id : i64 (spec-structural-key-raw structural-key)]
            (match (spec_id_i64_map.get (& cache) cache-key-id)
              [(LookupFound cached-name-id) (Ok cached-name-id state)]
              [(LookupMissing)
                (let
                  [generated-name-id : i64
                    (spec-reserve-specialized-symbol-with-owner
                      pools
                      structural-key
                      name
                      (spec-place-shared-view values))]
                  (match (spec-build-specialization params values)
                    [(Ok runtime-params value-subs type-subs)
                      (match (spec-substitute-types-expr-with-owner
                        (spec-state-owner state)
                        body
                        type-subs)
                        [(Ok typed-body)
                          (match (spec-substitute-values-expr-with-owner
                            (spec-state-owner state)
                            (spec-state-expr-get state typed-body)
                            value-subs)
                            [(Ok valued-body)
                              (let
                                [next-cache : spec_id_i64_map.Map cache]
                                (spec_id_i64_map.insert-ref!
                                  (&mut next-cache)
                                  cache-key-id
                                  generated-name-id)
                                (let
                                  [cached-state : SpecState
                                    (State generated next-cache ctfe-env pools)]
                                  [body-templates : SpecTemplateEnv
                                    (spec-template-env-shadow-params
                                      templates
                                      runtime-params)]
                                  (match (spec-rewrite-expr
                                    (spec-state-expr-get state valued-body)
                                    body-templates
                                    cached-state)
                                    [(Ok rewritten-body rewritten-state)
                                      (match (spec-place-shared-view
                                        rewritten-state)
                                        [(State
                                            rewritten-generated
                                            rewritten-cache
                                            rewritten-ctfe-env
                                            rewritten-pools)
                                          (Ok
                                            generated-name-id
                                            (State
                                              (spec-decl-list-append-one
                                                rewritten-generated
                                                (ast.ast-decl-def-fn-id
                                                  generated-name-id
                                                  (spec-substitute-param-types-with-owner
                                                    (spec-state-owner
                                                      rewritten-state)
                                                    runtime-params
                                                    type-subs)
                                                  (spec-substitute-type-with-owner
                                                    (spec-state-owner
                                                      rewritten-state)
                                                    ret
                                                    type-subs)
                                                  rewritten-body))
                                              rewritten-cache
                                              rewritten-ctfe-env
                                              rewritten-pools))])]
                                    [(Err diag) (Err diag)])))]
                            [(Err diag) (Err diag)])]
                        [(Err diag) (Err diag)])]
                    [(Err diag) (Err diag)]))]))])]))

(define (spec-for-owned-state-exprs
  [source-name : i64]
  [index-name : i64]
  [source : i64]
  [body : i64]) : ast.AstExprList
  (let
    [out : ast.AstExprList (ast.ast-expr-list-with-capacity 4)]
    (ast.ast-expr-list-push (&mut out) source-name)
    (ast.ast-expr-list-push (&mut out) index-name)
    (ast.ast-expr-list-push (&mut out) source)
    (ast.ast-expr-list-push (&mut out) body)
    out))

(define (spec-for-owned-step-exprs
  [source-name : i64]
  [index-name : i64]
  [binding-name : i64]
  [expected-type : i64]
  [done-name : i64]
  [body : i64]) : ast.AstExprList
  (let
    [out : ast.AstExprList (ast.ast-expr-list-with-capacity 6)]
    (ast.ast-expr-list-push (&mut out) source-name)
    (ast.ast-expr-list-push (&mut out) index-name)
    (ast.ast-expr-list-push (&mut out) binding-name)
    (if (>= expected-type 0)
      (ast.ast-expr-list-push (&mut out) expected-type)
      unit)
    (ast.ast-expr-list-push (&mut out) done-name)
    (ast.ast-expr-list-push (&mut out) body)
    out))

(define (spec-rewrite-expr
  [expr : ast.AstExpr]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]) : ResultSpecExpr
  (match (ast.ast-place-shared-view expr)
    [(Call func-box args)
      (let
        [func : ast.AstExpr (spec-state-expr-get state func-box)]
        (match (spec-expr-var-name-id-with-owner
          (spec-state-owner state)
          (ast.ast-place-shared-view func))
          [(Some name-id)
            (match (spec-template-lookup templates name-id)
              [(Some template)
                (spec-rewrite-specialized-call
                  template
                  args
                  templates
                  state
                  expr)]
              [(None)
                (match (spec-rewrite-expr
                  func
                  templates
                  (spec-place-shared-view state))
                  [(Ok rewritten-func func-state)
                    (match (spec-rewrite-expr-list args templates func-state)
                      [(Ok rewritten-args args-state)
                        (Ok
                          (ast.ast-expr-call-with-pools
                            (spec-state-pools state)
                            rewritten-func
                            rewritten-args)
                          args-state)]
                      [(Err diag) (Err diag)])]
                  [(Err diag) (Err diag)])])]
          [(None)
            (match (spec-rewrite-expr
              func
              templates
              (spec-place-shared-view state))
              [(Ok rewritten-func func-state)
                (match (spec-rewrite-expr-list args templates func-state)
                  [(Ok rewritten-args args-state)
                    (Ok
                      (ast.ast-expr-call-with-pools
                        (spec-state-pools state)
                        rewritten-func
                        rewritten-args)
                      args-state)]
                  [(Err diag) (Err diag)])]
              [(Err diag) (Err diag)])]))]
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let bindings body-box)
          (let
            [body : ast.AstExpr (spec-state-expr-get state body-box)]
            [body-templates : SpecTemplateEnv
              (spec-template-env-shadow-let-binding-names templates bindings)]
            (match (spec-rewrite-let-bindings
              bindings
              templates
              (spec-place-shared-view state))
              [(Ok rewritten-bindings binding-state)
                (match (spec-rewrite-expr body body-templates binding-state)
                  [(Ok rewritten-body body-state)
                    (Ok
                      (ast.ast-expr-let-with-pools
                        (spec-state-pools state)
                        rewritten-bindings
                        rewritten-body)
                      body-state)]
                  [(Err diag) (Err diag)])]
              [(Err diag) (Err diag)]))])]
    [(Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(Lambda params ret body-box)
          (let
            [body : ast.AstExpr (spec-state-expr-get state body-box)]
            [body-templates : SpecTemplateEnv
              (spec-template-env-shadow-params templates params)]
            (match (spec-rewrite-expr
              body
              body-templates
              (spec-place-shared-view state))
              [(Ok rewritten-body body-state)
                (Ok
                  (ast.ast-expr-lambda-with-pools
                    (spec-state-pools state)
                    params
                    ret
                    rewritten-body)
                  body-state)]
              [(Err diag) (Err diag)]))])]
    [(ForOwnedState payload)
      (match (spec-rewrite-expr-list
        (spec-for-owned-state-exprs
          (ast.ast-for-owned-state-source-name (& payload))
          (ast.ast-for-owned-state-index-name (& payload))
          (ast.ast-for-owned-state-source (& payload))
          (ast.ast-for-owned-state-body (& payload)))
        templates
        (spec-place-shared-view state))
        [(Ok rewritten rewritten-state)
          (Ok
            (ast.ast-expr-for-owned-state-with-pools
              (spec-state-pools state)
              (ast.ast-expr-list-get (& rewritten) 0 0)
              (ast.ast-expr-list-get (& rewritten) 1 0)
              (ast.ast-expr-list-get (& rewritten) 2 0)
              (ast.ast-expr-list-get (& rewritten) 3 0))
            rewritten-state)]
        [(Err diag) (Err diag)])]
    [(ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        (match (spec-rewrite-expr-list
          (spec-for-owned-step-exprs
            (ast.ast-for-owned-step-source-name (& payload))
            (ast.ast-for-owned-step-index-name (& payload))
            (ast.ast-for-owned-step-binding-name (& payload))
            expected-type
            (ast.ast-for-owned-step-done-name (& payload))
            (ast.ast-for-owned-step-body (& payload)))
          templates
          (spec-place-shared-view state))
          [(Ok rewritten rewritten-state)
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
              (Ok
                (ast.ast-expr-for-owned-step-with-pools
                  (spec-state-pools state)
                  (ast.ast-expr-list-get (& rewritten) 0 0)
                  (ast.ast-expr-list-get (& rewritten) 1 0)
                  (ast.ast-expr-list-get (& rewritten) 2 0)
                  (if typed?
                    (ast.ast-expr-list-get (& rewritten) 3 0)
                    -1)
                  (ast.ast-expr-list-get (& rewritten) done-index 0)
                  (ast.ast-expr-list-get (& rewritten) body-index 0))
                rewritten-state))]
          [(Err diag) (Err diag)]))]
    [(Match match-box)
      (match (__tl-box-place match-box)
        [(Match scrutinee-box arms)
          (let
            [scrutinee : ast.AstExpr (spec-state-expr-get state scrutinee-box)]
            (match (spec-rewrite-expr
              scrutinee
              templates
              (spec-place-shared-view state))
              [(Ok rewritten-scrutinee scrutinee-state)
                (match (spec-rewrite-match-arms arms templates scrutinee-state)
                  [(Ok rewritten-arms arms-state)
                    (Ok
                      (ast.ast-expr-match-with-pools
                        (spec-state-pools state)
                        rewritten-scrutinee
                        rewritten-arms)
                      arms-state)]
                  [(Err diag) (Err diag)])]
              [(Err diag) (Err diag)]))])]
    [(Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(Foreach index index-ty start-box end-box body-box)
          (let
            [start : ast.AstExpr (spec-state-expr-get state start-box)]
            [end : ast.AstExpr (spec-state-expr-get state end-box)]
            [body : ast.AstExpr (spec-state-expr-get state body-box)]
            [body-templates : SpecTemplateEnv
              (spec-template-env-shadow-name templates index)]
            (match (spec-rewrite-expr
              start
              templates
              (spec-place-shared-view state))
              [(Ok rewritten-start start-state)
                (match (spec-rewrite-expr end templates start-state)
                  [(Ok rewritten-end end-state)
                    (match (spec-rewrite-expr body body-templates end-state)
                      [(Ok rewritten-body body-state)
                        (Ok
                          (ast.ast-expr-foreach-id-with-pools
                            (spec-state-pools state)
                            index
                            index-ty
                            rewritten-start
                            rewritten-end
                            rewritten-body)
                          body-state)]
                      [(Err diag) (Err diag)])]
                  [(Err diag) (Err diag)])]
              [(Err diag) (Err diag)]))]
        [(Foreach2
            outer
            outer-ty
            outer-start-box
            outer-end-box
            inner
            inner-ty
            inner-start-box
            inner-end-box
            body-box)
          (let
            [outer-start : ast.AstExpr
              (spec-state-expr-get state outer-start-box)]
            [outer-end : ast.AstExpr (spec-state-expr-get state outer-end-box)]
            [inner-start : ast.AstExpr
              (spec-state-expr-get state inner-start-box)]
            [inner-end : ast.AstExpr (spec-state-expr-get state inner-end-box)]
            [body : ast.AstExpr (spec-state-expr-get state body-box)]
            [outer-templates : SpecTemplateEnv
              (spec-template-env-shadow-name templates outer)]
            [body-templates : SpecTemplateEnv
              (spec-template-env-shadow-name outer-templates inner)]
            (match (spec-rewrite-expr
              outer-start
              templates
              (spec-place-shared-view state))
              [(Ok rewritten-outer-start state0)
                (match (spec-rewrite-expr outer-end templates state0)
                  [(Ok rewritten-outer-end state1)
                    (match (spec-rewrite-expr inner-start templates state1)
                      [(Ok rewritten-inner-start state2)
                        (match (spec-rewrite-expr inner-end templates state2)
                          [(Ok rewritten-inner-end state3)
                            (match (spec-rewrite-expr
                              body
                              body-templates
                              state3)
                              [(Ok rewritten-body body-state)
                                (Ok
                                  (ast.ast-expr-foreach2-id-with-pools
                                    (spec-state-pools state)
                                    outer
                                    outer-ty
                                    rewritten-outer-start
                                    rewritten-outer-end
                                    inner
                                    inner-ty
                                    rewritten-inner-start
                                    rewritten-inner-end
                                    rewritten-body)
                                  body-state)]
                              [(Err diag) (Err diag)])]
                          [(Err diag) (Err diag)])]
                      [(Err diag) (Err diag)])]
                  [(Err diag) (Err diag)])]
              [(Err diag) (Err diag)]))])]
    [(ForeachActive lane body-box)
      (let
        [body : ast.AstExpr (spec-state-expr-get state body-box)]
        [body-templates : SpecTemplateEnv
          (spec-template-env-shadow-name templates lane)]
        (match (spec-rewrite-expr
          body
          body-templates
          (spec-place-shared-view state))
          [(Ok rewritten-body body-state)
            (Ok
              (ast.ast-expr-foreach-active-with-pools
                (spec-state-pools state)
                lane
                rewritten-body)
              body-state)]
          [(Err diag) (Err diag)]))]
    [(SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(Reduce op index index-ty start-box end-box init-box value-box)
          (let
            [start : ast.AstExpr (spec-state-expr-get state start-box)]
            [end : ast.AstExpr (spec-state-expr-get state end-box)]
            [init : ast.AstExpr (spec-state-expr-get state init-box)]
            [value : ast.AstExpr (spec-state-expr-get state value-box)]
            [value-templates : SpecTemplateEnv
              (spec-template-env-shadow-name templates index)]
            (match (spec-rewrite-expr
              start
              templates
              (spec-place-shared-view state))
              [(Ok rewritten-start start-state)
                (match (spec-rewrite-expr end templates start-state)
                  [(Ok rewritten-end end-state)
                    (match (spec-rewrite-expr init templates end-state)
                      [(Ok rewritten-init init-state)
                        (match (spec-rewrite-expr
                          value
                          value-templates
                          init-state)
                          [(Ok rewritten-value value-state)
                            (Ok
                              (ast.ast-expr-spmd-reduce-id-with-pools
                                (spec-state-pools state)
                                op
                                index
                                index-ty
                                rewritten-start
                                rewritten-end
                                rewritten-init
                                rewritten-value)
                              value-state)]
                          [(Err diag) (Err diag)])]
                      [(Err diag) (Err diag)])]
                  [(Err diag) (Err diag)])]
              [(Err diag) (Err diag)]))])]
    [(SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(Scan
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
            [start : ast.AstExpr (spec-state-expr-get state start-box)]
            [end : ast.AstExpr (spec-state-expr-get state end-box)]
            [init : ast.AstExpr (spec-state-expr-get state init-box)]
            [value : ast.AstExpr (spec-state-expr-get state value-box)]
            [body : ast.AstExpr (spec-state-expr-get state body-box)]
            [value-templates : SpecTemplateEnv
              (spec-template-env-shadow-name templates index)]
            [body-templates : SpecTemplateEnv
              (spec-template-env-shadow-name value-templates prefix)]
            (match (spec-rewrite-expr
              start
              templates
              (spec-place-shared-view state))
              [(Ok rewritten-start start-state)
                (match (spec-rewrite-expr end templates start-state)
                  [(Ok rewritten-end end-state)
                    (match (spec-rewrite-expr init templates end-state)
                      [(Ok rewritten-init init-state)
                        (match (spec-rewrite-expr
                          value
                          value-templates
                          init-state)
                          [(Ok rewritten-value value-state)
                            (match (spec-rewrite-expr
                              body
                              body-templates
                              value-state)
                              [(Ok rewritten-body body-state)
                                (Ok
                                  (ast.ast-expr-spmd-scan-id-with-pools
                                    (spec-state-pools state)
                                    op
                                    index
                                    index-ty
                                    rewritten-start
                                    rewritten-end
                                    prefix
                                    prefix-ty
                                    rewritten-init
                                    rewritten-value
                                    rewritten-body)
                                  body-state)]
                              [(Err diag) (Err diag)])]
                          [(Err diag) (Err diag)])]
                      [(Err diag) (Err diag)])]
                  [(Err diag) (Err diag)])]
              [(Err diag) (Err diag)]))])]
    [(SpmdCompact compact-box)
      (match (__tl-box-place compact-box)
        [(Compact
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
            [start : ast.AstExpr (spec-state-expr-get state start-box)]
            [end : ast.AstExpr (spec-state-expr-get state end-box)]
            [init : ast.AstExpr (spec-state-expr-get state init-box)]
            [keep : ast.AstExpr (spec-state-expr-get state keep-box)]
            [body : ast.AstExpr (spec-state-expr-get state body-box)]
            [keep-templates : SpecTemplateEnv
              (spec-template-env-shadow-name templates index)]
            [body-templates : SpecTemplateEnv
              (spec-template-env-shadow-name keep-templates slot)]
            (match (spec-rewrite-expr
              start
              templates
              (spec-place-shared-view state))
              [(Ok rewritten-start start-state)
                (match (spec-rewrite-expr end templates start-state)
                  [(Ok rewritten-end end-state)
                    (match (spec-rewrite-expr init templates end-state)
                      [(Ok rewritten-init init-state)
                        (match (spec-rewrite-expr
                          keep
                          keep-templates
                          init-state)
                          [(Ok rewritten-keep keep-state)
                            (match (spec-rewrite-expr
                              body
                              body-templates
                              keep-state)
                              [(Ok rewritten-body body-state)
                                (Ok
                                  (ast.ast-expr-spmd-compact-id-with-pools
                                    (spec-state-pools state)
                                    index
                                    index-ty
                                    rewritten-start
                                    rewritten-end
                                    slot
                                    slot-ty
                                    rewritten-init
                                    rewritten-keep
                                    rewritten-body)
                                  body-state)]
                              [(Err diag) (Err diag)])]
                          [(Err diag) (Err diag)])]
                      [(Err diag) (Err diag)])]
                  [(Err diag) (Err diag)])]
              [(Err diag) (Err diag)]))])]
    [(WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(WithResource bindings body)
          (spec-rewrite-resource bindings body templates state)])]
    [(Borrow _ _ _)
      (Ok (spec-owner-expr-push (spec-state-owner state) expr) state)]
    [_
      (match (spec-rewrite-expr-list
        (ast.ast-expr-child-ids (ast.ast-place-shared-view expr))
        templates
        (spec-place-shared-view state))
        [(Ok ids next-state)
          (Ok
            (spec-owner-expr-push
              (spec-state-owner state)
              (ast.ast-expr-with-child-ids expr (& ids)))
            next-state)]
        [(Err diag) (Err diag)])]))

(define (spec-ptr-addr-of-place-value-conflict-with-owner
  [owner : (& owner SpecOwnerContext)]
  [place : ast.AstExpr]
  [subs : (& subs SpecValueSubst)]) : SpecMaybeId
  (let
    [pools : ast.AstNodePoolContext (spec-owner-pools owner)]
    (match (ast.ast-expr-unspan-with-pools pools place)
      [(Var name) (spec-value-subst-lookup subs name)]
      [(StructGet receiver-box _)
        (spec-ptr-addr-of-place-value-conflict-with-owner
          owner
          (spec-owner-expr-get owner receiver-box)
          subs)]
      [(ArrayRef array-box _)
        (spec-ptr-addr-of-place-value-conflict-with-owner
          owner
          (spec-owner-expr-get owner array-box)
          subs)]
      [_ (None)])))

;; Resource scopes are sequential: the current name is absent from its own
;; initializer and cleanup, and shadows templates only in later bindings/body.
(define (spec-rewrite-resource
  [bindings : ast.AstResourceBindingList]
  [body : ast.AstExprList]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]) : ResultSpecExpr
  (let
    [out : ast.AstResourceBindingList
      (ast.ast-resource-binding-list-with-capacity bindings.len)]
    [scope : SpecTemplateEnv (spec-template-env-shared-view templates)]
    [index : i64 0]
    (while (< index bindings.len)
      (match (ast.ast-resource-binding-list-get
        (& bindings)
        index
        (ast.ast-resource-binding-fallback))
        [(Binding name init cleanup move-aware?)
          (match (spec-rewrite-expr
            (spec-state-expr-get (& state) init)
            (& scope)
            (spec-place-shared-view state))
            [(Err diag) (return (Err diag))]
            [(Ok next-init init-state)
              (match (spec-rewrite-expr
                (spec-state-expr-get (& init-state) cleanup)
                (& scope)
                init-state)
                [(Err diag) (return (Err diag))]
                [(Ok next-cleanup cleanup-state)
                  (ast.ast-resource-binding-list-push
                    (&mut out)
                    (ast.AstResourceBinding.Binding
                      name
                      next-init
                      next-cleanup
                      move-aware?))
                  (set! state cleanup-state)
                  (set! scope (spec-template-env-shadow-name scope name))
                  (set! index (+ index 1))])])]))
    (match (spec-rewrite-expr-list body (& scope) state)
      [(Err diag) (Err diag)]
      [(Ok next-body body-state)
        (Ok
          (spec-owner-expr-push
            (spec-state-owner (& body-state))
            (WithResource
              (box (ast.AstWithResource.WithResource out next-body))))
          body-state)])))

(define (spec-substitute-values-resource-with-owner
  [owner : (& owner SpecOwnerContext)]
  [bindings : ast.AstResourceBindingList]
  [body : ast.AstExprList]
  [subs : (& subs SpecValueSubst)]) : ResultSpecSubExpr
  (let
    [out : ast.AstResourceBindingList
      (ast.ast-resource-binding-list-with-capacity bindings.len)]
    [scope : SpecValueSubst (spec-value-subst-shared-view subs)]
    [index : i64 0]
    (while (< index bindings.len)
      (match (ast.ast-resource-binding-list-get
        (& bindings)
        index
        (ast.ast-resource-binding-fallback))
        [(Binding name init cleanup move-aware?)
          (match (spec-substitute-values-expr-with-owner
            owner
            (spec-owner-expr-get owner init)
            (& scope))
            [(Err diag) (return (Err diag))]
            [(Ok next-init)
              (match (spec-substitute-values-expr-with-owner
                owner
                (spec-owner-expr-get owner cleanup)
                (& scope))
                [(Err diag) (return (Err diag))]
                [(Ok next-cleanup)
                  (ast.ast-resource-binding-list-push
                    (&mut out)
                    (ast.AstResourceBinding.Binding
                      name
                      next-init
                      next-cleanup
                      move-aware?))
                  (set! scope (spec-value-subst-remove-name (& scope) name))
                  (set! index (+ index 1))])])]))
    (let
      [next-body : ast.AstExprList
        (try (spec-substitute-values-expr-list-with-owner owner body (& scope)))]
      (Ok
        (spec-owner-expr-push
          owner
          (WithResource (box (ast.AstWithResource.WithResource out next-body))))))))

(define (spec-substitute-types-resource-with-owner
  [owner : (& owner SpecOwnerContext)]
  [bindings : ast.AstResourceBindingList]
  [body : ast.AstExprList]
  [subs : (& subs SpecTypeSubst)]) : ResultSpecSubExpr
  (let
    [out : ast.AstResourceBindingList
      (ast.ast-resource-binding-list-with-capacity bindings.len)]
    [scope : SpecTypeSubst (spec-type-subst-shared-view subs)]
    [index : i64 0]
    (while (< index bindings.len)
      (match (ast.ast-resource-binding-list-get
        (& bindings)
        index
        (ast.ast-resource-binding-fallback))
        [(Binding name init cleanup move-aware?)
          (match (spec-substitute-types-expr-with-owner
            owner
            (spec-owner-expr-get owner init)
            (& scope))
            [(Err diag) (return (Err diag))]
            [(Ok next-init)
              (match (spec-substitute-types-expr-with-owner
                owner
                (spec-owner-expr-get owner cleanup)
                (& scope))
                [(Err diag) (return (Err diag))]
                [(Ok next-cleanup)
                  (ast.ast-resource-binding-list-push
                    (&mut out)
                    (ast.AstResourceBinding.Binding
                      name
                      next-init
                      next-cleanup
                      move-aware?))
                  (set! scope (spec-type-subst-remove-name (& scope) name))
                  (set! index (+ index 1))])])]))
    (let
      [next-body : ast.AstExprList
        (try (spec-substitute-types-expr-list-with-owner owner body (& scope)))]
      (Ok
        (spec-owner-expr-push
          owner
          (WithResource (box (ast.AstWithResource.WithResource out next-body))))))))

(define (spec-substitute-values-expr-with-owner
  [owner : (& owner SpecOwnerContext)]
  [expr : ast.AstExpr]
  [subs : (& subs SpecValueSubst)]) : ResultSpecSubExpr
  (match (ast.ast-place-shared-view expr)
    [(Var name)
      (match (spec-value-subst-lookup subs name)
        [(Some _)
          (spec-ctfe-value-to-expr-with-owner
            owner
            (spec-value-subst-value subs name)
            expr)]
        [(None) (Ok (spec-owner-expr-push owner expr))])]
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let bindings body-box)
          (let
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            (match (spec-substitute-values-let-bindings-with-owner
              owner
              (spec-place-shared-view bindings)
              subs)
              [(Ok rewritten-bindings)
                (let
                  [body-subs : SpecValueSubst
                    (spec-value-subst-remove-let-binding-names subs bindings)]
                  [rewritten-body : i64
                    (try
                      (spec-substitute-values-expr-with-owner
                        owner
                        body
                        body-subs))]
                  (Ok
                    (ast.ast-expr-let-with-pools
                      (spec-owner-pools owner)
                      rewritten-bindings
                      rewritten-body)))]
              [(Err diag) (Err diag)]))])]
    [(Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(Lambda params ret body-box)
          (let
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            [body-subs : SpecValueSubst
              (spec-value-subst-remove-params subs params)]
            [rewritten-body : i64
              (try
                (spec-substitute-values-expr-with-owner owner body body-subs))]
            (Ok
              (ast.ast-expr-lambda-with-pools
                (spec-owner-pools owner)
                params
                ret
                rewritten-body)))])]
    [(ForOwnedState payload)
      (let
        [rewritten : ast.AstExprList
          (try
            (spec-substitute-values-expr-list-with-owner
              owner
              (spec-for-owned-state-exprs
                (ast.ast-for-owned-state-source-name (& payload))
                (ast.ast-for-owned-state-index-name (& payload))
                (ast.ast-for-owned-state-source (& payload))
                (ast.ast-for-owned-state-body (& payload)))
              subs))]
        (Ok
          (ast.ast-expr-for-owned-state-with-pools
            (spec-owner-pools owner)
            (ast.ast-expr-list-get (& rewritten) 0 0)
            (ast.ast-expr-list-get (& rewritten) 1 0)
            (ast.ast-expr-list-get (& rewritten) 2 0)
            (ast.ast-expr-list-get (& rewritten) 3 0))))]
    [(ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        [rewritten : ast.AstExprList
          (try
            (spec-substitute-values-expr-list-with-owner
              owner
              (spec-for-owned-step-exprs
                (ast.ast-for-owned-step-source-name (& payload))
                (ast.ast-for-owned-step-index-name (& payload))
                (ast.ast-for-owned-step-binding-name (& payload))
                expected-type
                (ast.ast-for-owned-step-done-name (& payload))
                (ast.ast-for-owned-step-body (& payload)))
              subs))]
        [typed? : bool (>= expected-type 0)]
        [done-index : i64
          (if typed?
            4
            3)]
        [body-index : i64
          (if typed?
            5
            4)]
        (Ok
          (ast.ast-expr-for-owned-step-with-pools
            (spec-owner-pools owner)
            (ast.ast-expr-list-get (& rewritten) 0 0)
            (ast.ast-expr-list-get (& rewritten) 1 0)
            (ast.ast-expr-list-get (& rewritten) 2 0)
            (if typed?
              (ast.ast-expr-list-get (& rewritten) 3 0)
              -1)
            (ast.ast-expr-list-get (& rewritten) done-index 0)
            (ast.ast-expr-list-get (& rewritten) body-index 0))))]
    [(Set name value-box)
      (let
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-value-subst-lookup subs name)
          [(Some _)
            (Err
              (box
                (spec-diagnostic-at-expr
                  expr
                  (str_cat.str-cat
                    "cannot assign to comptime parameter '"
                    (spec_ci.intern-compat-state-str
                      (spec-owner-intern-state owner)
                      name)
                    "'"))))]
          [(None)
            (let
              [rewritten : i64
                (try (spec-substitute-values-expr-with-owner owner value subs))]
              (Ok
                (ast.ast-expr-set-id-with-pools
                  (spec-owner-pools owner)
                  name
                  rewritten)))]))]
    [(Match match-box)
      (match (__tl-box-place match-box)
        [(Match scrutinee-box arms)
          (let
            [scrutinee : ast.AstExpr (spec-owner-expr-get owner scrutinee-box)]
            [rewritten-scrutinee : i64
              (try
                (spec-substitute-values-expr-with-owner owner scrutinee subs))]
            [rewritten-arms : ast.AstMatchArmList
              (try
                (spec-substitute-values-match-arms-with-owner owner arms subs))]
            (Ok
              (ast.ast-expr-match-with-pools
                (spec-owner-pools owner)
                rewritten-scrutinee
                rewritten-arms)))])]
    [(Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(Foreach index index-ty start-box end-box body-box)
          (let
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            [body-subs : SpecValueSubst
              (spec-value-subst-remove-name subs index)]
            [rewritten-start : i64
              (try (spec-substitute-values-expr-with-owner owner start subs))]
            [rewritten-end : i64
              (try (spec-substitute-values-expr-with-owner owner end subs))]
            [rewritten-body : i64
              (try
                (spec-substitute-values-expr-with-owner owner body body-subs))]
            (Ok
              (ast.ast-expr-foreach-id-with-pools
                (spec-owner-pools owner)
                index
                index-ty
                rewritten-start
                rewritten-end
                rewritten-body)))]
        [(Foreach2
            outer
            outer-ty
            outer-start-box
            outer-end-box
            inner
            inner-ty
            inner-start-box
            inner-end-box
            body-box)
          (let
            [outer-start : ast.AstExpr
              (spec-owner-expr-get owner outer-start-box)]
            [outer-end : ast.AstExpr (spec-owner-expr-get owner outer-end-box)]
            [inner-start : ast.AstExpr
              (spec-owner-expr-get owner inner-start-box)]
            [inner-end : ast.AstExpr (spec-owner-expr-get owner inner-end-box)]
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            [outer-subs : SpecValueSubst
              (spec-value-subst-remove-name subs outer)]
            [body-subs : SpecValueSubst
              (spec-value-subst-remove-name outer-subs inner)]
            [rewritten-outer-start : i64
              (try
                (spec-substitute-values-expr-with-owner owner outer-start subs))]
            [rewritten-outer-end : i64
              (try
                (spec-substitute-values-expr-with-owner owner outer-end subs))]
            [rewritten-inner-start : i64
              (try
                (spec-substitute-values-expr-with-owner owner inner-start subs))]
            [rewritten-inner-end : i64
              (try
                (spec-substitute-values-expr-with-owner owner inner-end subs))]
            [rewritten-body : i64
              (try
                (spec-substitute-values-expr-with-owner owner body body-subs))]
            (Ok
              (ast.ast-expr-foreach2-id-with-pools
                (spec-owner-pools owner)
                outer
                outer-ty
                rewritten-outer-start
                rewritten-outer-end
                inner
                inner-ty
                rewritten-inner-start
                rewritten-inner-end
                rewritten-body)))])]
    [(ForeachActive lane body-box)
      (let
        [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
        [body-subs : SpecValueSubst (spec-value-subst-remove-name subs lane)]
        [rewritten-body : i64
          (try (spec-substitute-values-expr-with-owner owner body body-subs))]
        (Ok
          (ast.ast-expr-foreach-active-with-pools
            (spec-owner-pools owner)
            lane
            rewritten-body)))]
    [(SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(Reduce op index index-ty start-box end-box init-box value-box)
          (let
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [init : ast.AstExpr (spec-owner-expr-get owner init-box)]
            [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
            [value-subs : SpecValueSubst
              (spec-value-subst-remove-name subs index)]
            [rewritten-start : i64
              (try (spec-substitute-values-expr-with-owner owner start subs))]
            [rewritten-end : i64
              (try (spec-substitute-values-expr-with-owner owner end subs))]
            [rewritten-init : i64
              (try (spec-substitute-values-expr-with-owner owner init subs))]
            [rewritten-value : i64
              (try
                (spec-substitute-values-expr-with-owner owner value value-subs))]
            (Ok
              (ast.ast-expr-spmd-reduce-id-with-pools
                (spec-owner-pools owner)
                op
                index
                index-ty
                rewritten-start
                rewritten-end
                rewritten-init
                rewritten-value)))])]
    [(SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(Scan
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
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [init : ast.AstExpr (spec-owner-expr-get owner init-box)]
            [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            [value-subs : SpecValueSubst
              (spec-value-subst-remove-name subs index)]
            [body-subs : SpecValueSubst
              (spec-value-subst-remove-name value-subs prefix)]
            [rewritten-start : i64
              (try (spec-substitute-values-expr-with-owner owner start subs))]
            [rewritten-end : i64
              (try (spec-substitute-values-expr-with-owner owner end subs))]
            [rewritten-init : i64
              (try (spec-substitute-values-expr-with-owner owner init subs))]
            [rewritten-value : i64
              (try
                (spec-substitute-values-expr-with-owner owner value value-subs))]
            [rewritten-body : i64
              (try
                (spec-substitute-values-expr-with-owner owner body body-subs))]
            (Ok
              (ast.ast-expr-spmd-scan-id-with-pools
                (spec-owner-pools owner)
                op
                index
                index-ty
                rewritten-start
                rewritten-end
                prefix
                prefix-ty
                rewritten-init
                rewritten-value
                rewritten-body)))])]
    [(SpmdCompact compact-box)
      (match (__tl-box-place compact-box)
        [(Compact
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
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [init : ast.AstExpr (spec-owner-expr-get owner init-box)]
            [keep : ast.AstExpr (spec-owner-expr-get owner keep-box)]
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            [keep-subs : SpecValueSubst
              (spec-value-subst-remove-name subs index)]
            [body-subs : SpecValueSubst
              (spec-value-subst-remove-name keep-subs slot)]
            [rewritten-start : i64
              (try (spec-substitute-values-expr-with-owner owner start subs))]
            [rewritten-end : i64
              (try (spec-substitute-values-expr-with-owner owner end subs))]
            [rewritten-init : i64
              (try (spec-substitute-values-expr-with-owner owner init subs))]
            [rewritten-keep : i64
              (try
                (spec-substitute-values-expr-with-owner owner keep keep-subs))]
            [rewritten-body : i64
              (try
                (spec-substitute-values-expr-with-owner owner body body-subs))]
            (Ok
              (ast.ast-expr-spmd-compact-id-with-pools
                (spec-owner-pools owner)
                index
                index-ty
                rewritten-start
                rewritten-end
                slot
                slot-ty
                rewritten-init
                rewritten-keep
                rewritten-body)))])]
    [(WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(WithResource bindings body)
          (spec-substitute-values-resource-with-owner owner bindings body subs)])]
    [(PtrAddrOf place-box)
      (let
        [place : ast.AstExpr (spec-owner-expr-get owner place-box)]
        (match (spec-ptr-addr-of-place-value-conflict-with-owner
          owner
          (ast.ast-place-shared-view place)
          subs)
          [(Some name-id)
            (Err
              (box
                (spec-diagnostic-at-expr
                  expr
                  (str_cat.str-cat
                    "cannot take address of comptime value parameter '"
                    (spec_ci.intern-compat-state-str
                      (spec-owner-intern-state owner)
                      name-id)
                    "'"))))]
          [(None)
            (let
              [rewritten : i64
                (try (spec-substitute-values-expr-with-owner owner place subs))]
              (Ok
                (ast.ast-expr-ptr-addr-of-id-with-pools
                  (spec-owner-pools owner)
                  rewritten)))]))]
    [(Borrow _ _ _) (Ok (spec-owner-expr-push owner expr))]
    [_
      (match (spec-substitute-values-expr-list-with-owner
        owner
        (ast.ast-expr-child-ids (ast.ast-place-shared-view expr))
        subs)
        [(Ok ids)
          (Ok
            (spec-owner-expr-push
              owner
              (ast.ast-expr-with-child-ids expr (& ids))))]
        [(Err diag) (Err diag)])]))

(define (spec-substitute-values-expr-list-with-owner
  [owner : (& owner SpecOwnerContext)]
  [exprs : ast.AstExprList]
  [subs : (& subs SpecValueSubst)]) : ResultSpecSubExprList
  (let
    [out : ast.AstExprList (ast.ast-expr-list-with-capacity exprs.len)]
    (match (spec-substitute-values-expr-list-at-with-owner
      owner
      (& exprs)
      0
      subs
      (&mut out))
      [(Ok) (Ok out)]
      [(Err diag) (Err diag)])))

(define (spec-substitute-values-expr-list-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [subs : (& subs SpecValueSubst)]
  [out : (&mut out ast.AstExprList)]) : ResultSpecSubExprListBuild
  (if (>= index exprs.len)
    (Ok)
    (let
      [head : ast.AstExpr
        (spec-owner-expr-get owner (ast.ast-expr-list-get exprs index 0))]
      (match (spec-substitute-values-expr-with-owner owner head subs)
        [(Ok rewritten-head)
          (ast.ast-expr-list-push out rewritten-head)
          (spec-substitute-values-expr-list-at-with-owner
            owner
            exprs
            (+ index 1)
            subs
            out)]
        [(Err diag) (Err diag)]))))

(define (spec-substitute-values-let-bindings-with-owner
  [owner : (& owner SpecOwnerContext)]
  [bindings : ast.AstLetBindingList]
  [subs : (& subs SpecValueSubst)]) : ResultSpecSubLetBindingList
  (let
    [out : ast.AstLetBindingList
      (ast.ast-let-binding-list-with-capacity
        (ast.ast-let-binding-list-len (& bindings)))]
    (match (spec-substitute-values-let-bindings-at-with-owner
      owner
      (& bindings)
      0
      subs
      (&mut out))
      [(Ok) (Ok out)]
      [(Err diag) (Err diag)])))

(define (spec-substitute-values-let-bindings-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [bindings : (& bindings ast.AstLetBindingList)]
  [index : i64]
  [subs : (& subs SpecValueSubst)]
  [out : (&mut out ast.AstLetBindingList)]) : ResultSpecSubLetBindingListBuild
  (if (>= index (ast.ast-let-binding-list-len bindings))
    (Ok)
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(Binding name ty value-box)
        (let
          [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
          [next-subs : SpecValueSubst (spec-value-subst-remove-name subs name)]
          (match (spec-substitute-values-expr-with-owner owner value subs)
            [(Ok rewritten-value)
              (ast.ast-let-binding-list-push
                out
                (ast.ast-let-binding-id name ty rewritten-value))
              (spec-substitute-values-let-bindings-at-with-owner
                owner
                bindings
                (+ index 1)
                next-subs
                out)]
            [(Err diag) (Err diag)]))])))

(define (spec-substitute-values-match-arms-with-owner
  [owner : (& owner SpecOwnerContext)]
  [arms : ast.AstMatchArmList]
  [subs : (& subs SpecValueSubst)]) : ResultSpecSubMatchArmList
  (let
    [out : ast.AstMatchArmList (ast.ast-match-arm-list-with-capacity arms.len)]
    (match (spec-substitute-values-match-arms-at-with-owner
      owner
      (& arms)
      0
      subs
      (&mut out))
      [(Ok) (Ok out)]
      [(Err diag) (Err diag)])))

(define (spec-substitute-values-match-arms-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [arms : (& arms ast.AstMatchArmList)]
  [index : i64]
  [subs : (& subs SpecValueSubst)]
  [out : (&mut out ast.AstMatchArmList)]) : ResultSpecSubMatchArmListBuild
  (if (>= index arms.len)
    (Ok)
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(Arm pattern body-box)
        (let
          [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
          [body-subs : SpecValueSubst
            (spec-value-subst-remove-pattern
              subs
              (ast.ast-place-shared-view pattern))]
          (match (spec-substitute-values-expr-with-owner owner body body-subs)
            [(Ok rewritten-body)
              (ast.ast-match-arm-list-push
                out
                (ast.ast-match-arm pattern rewritten-body))
              (spec-substitute-values-match-arms-at-with-owner
                owner
                arms
                (+ index 1)
                subs
                out)]
            [(Err diag) (Err diag)]))])))

(define (spec-substitute-types-expr-with-owner
  [owner : (& owner SpecOwnerContext)]
  [expr : ast.AstExpr]
  [subs : (& subs SpecTypeSubst)]) : ResultSpecSubExpr
  (match (ast.ast-place-shared-view expr)
    [(Var name)
      (match (spec-type-subst-lookup subs name)
        [(Some _)
          (Err
            (box
              (spec-diagnostic-at-expr
                expr
                (str_cat.str-cat
                  "type-valued comptime parameter '"
                  (spec_ci.intern-compat-state-str
                    (spec-owner-intern-state owner)
                    name)
                  "' cannot be used as a runtime value"))))]
        [(None) (Ok (spec-owner-expr-push owner expr))])]
    [(TypeLiteral ty-id)
      (Ok
        (ast.ast-expr-type-literal-with-pools
          (spec-owner-pools owner)
          (spec-substitute-type-with-owner
            owner
            (spec-owner-type-get owner ty-id)
            subs)))]
    [(Init maybe-ty-id)
      (Ok
        (ast.ast-expr-init-maybe-with-pools
          (spec-owner-pools owner)
          (spec-substitute-maybe-type-with-owner
            owner
            (ast.ast-maybe-type-from-id-with-pools
              (spec-owner-pools owner)
              maybe-ty-id)
            subs)))]
    [(FixedMakeArray elem-ty-id len-box)
      (let
        [len : ast.AstExpr (spec-owner-expr-get owner len-box)]
        [rewritten-len : i64
          (try (spec-substitute-types-expr-with-owner owner len subs))]
        (Ok
          (ast.ast-expr-fixed-make-array-with-pools
            (spec-owner-pools owner)
            (spec-substitute-type-with-owner
              owner
              (spec-owner-type-get owner elem-ty-id)
              subs)
            rewritten-len)))]
    [(MakeArray elem-ty-id len-box)
      (let
        [len : ast.AstExpr (spec-owner-expr-get owner len-box)]
        [rewritten-len : i64
          (try (spec-substitute-types-expr-with-owner owner len subs))]
        (Ok
          (ast.ast-expr-make-array-with-pools
            (spec-owner-pools owner)
            (spec-substitute-type-with-owner
              owner
              (spec-owner-type-get owner elem-ty-id)
              subs)
            rewritten-len)))]
    [(Ann inner-box ty-id)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        [rewritten : i64
          (try (spec-substitute-types-expr-with-owner owner inner subs))]
        (Ok
          (ast.ast-expr-ann-with-pools
            (spec-owner-pools owner)
            rewritten
            (spec-substitute-type-with-owner
              owner
              (spec-owner-type-get owner ty-id)
              subs))))]
    [(Cast inner-box ty-id)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        [rewritten : i64
          (try (spec-substitute-types-expr-with-owner owner inner subs))]
        (Ok
          (ast.ast-expr-cast-with-pools
            (spec-owner-pools owner)
            rewritten
            (spec-substitute-type-with-owner
              owner
              (spec-owner-type-get owner ty-id)
              subs))))]
    [(Lambda lambda-box)
      (match (__tl-box-place lambda-box)
        [(Lambda params ret body-box)
          (let
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            [body-subs : SpecTypeSubst
              (spec-type-subst-remove-params subs params)]
            [rewritten-body : i64
              (try (spec-substitute-types-expr-with-owner owner body body-subs))]
            (Ok
              (ast.ast-expr-lambda-with-pools
                (spec-owner-pools owner)
                (spec-substitute-param-types-with-owner owner params subs)
                (spec-substitute-maybe-type-with-owner owner ret subs)
                rewritten-body)))])]
    [(Foreach fe-box)
      (match (__tl-box-place fe-box)
        [(Foreach index index-ty start-box end-box body-box)
          (let
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            [body-subs : SpecTypeSubst (spec-type-subst-remove-name subs index)]
            [rewritten-start : i64
              (try (spec-substitute-types-expr-with-owner owner start subs))]
            [rewritten-end : i64
              (try (spec-substitute-types-expr-with-owner owner end subs))]
            [rewritten-body : i64
              (try (spec-substitute-types-expr-with-owner owner body body-subs))]
            (Ok
              (ast.ast-expr-foreach-id-with-pools
                (spec-owner-pools owner)
                index
                (spec-substitute-type-with-owner owner index-ty subs)
                rewritten-start
                rewritten-end
                rewritten-body)))]
        [(Foreach2
            outer
            outer-ty
            outer-start-box
            outer-end-box
            inner
            inner-ty
            inner-start-box
            inner-end-box
            body-box)
          (let
            [outer-start : ast.AstExpr
              (spec-owner-expr-get owner outer-start-box)]
            [outer-end : ast.AstExpr (spec-owner-expr-get owner outer-end-box)]
            [inner-start : ast.AstExpr
              (spec-owner-expr-get owner inner-start-box)]
            [inner-end : ast.AstExpr (spec-owner-expr-get owner inner-end-box)]
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            [outer-subs : SpecTypeSubst
              (spec-type-subst-remove-name subs outer)]
            [body-subs : SpecTypeSubst
              (spec-type-subst-remove-name outer-subs inner)]
            [rewritten-outer-start : i64
              (try
                (spec-substitute-types-expr-with-owner owner outer-start subs))]
            [rewritten-outer-end : i64
              (try (spec-substitute-types-expr-with-owner owner outer-end subs))]
            [rewritten-inner-start : i64
              (try
                (spec-substitute-types-expr-with-owner owner inner-start subs))]
            [rewritten-inner-end : i64
              (try (spec-substitute-types-expr-with-owner owner inner-end subs))]
            [rewritten-body : i64
              (try (spec-substitute-types-expr-with-owner owner body body-subs))]
            (Ok
              (ast.ast-expr-foreach2-id-with-pools
                (spec-owner-pools owner)
                outer
                (spec-substitute-type-with-owner owner outer-ty subs)
                rewritten-outer-start
                rewritten-outer-end
                inner
                (spec-substitute-type-with-owner owner inner-ty subs)
                rewritten-inner-start
                rewritten-inner-end
                rewritten-body)))])]
    [(SpmdReduce reduce-box)
      (match (__tl-box-place reduce-box)
        [(Reduce op index index-ty start-box end-box init-box value-box)
          (let
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [init : ast.AstExpr (spec-owner-expr-get owner init-box)]
            [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
            [value-subs : SpecTypeSubst
              (spec-type-subst-remove-name subs index)]
            [rewritten-start : i64
              (try (spec-substitute-types-expr-with-owner owner start subs))]
            [rewritten-end : i64
              (try (spec-substitute-types-expr-with-owner owner end subs))]
            [rewritten-init : i64
              (try (spec-substitute-types-expr-with-owner owner init subs))]
            [rewritten-value : i64
              (try
                (spec-substitute-types-expr-with-owner owner value value-subs))]
            (Ok
              (ast.ast-expr-spmd-reduce-id-with-pools
                (spec-owner-pools owner)
                op
                index
                (spec-substitute-type-with-owner owner index-ty subs)
                rewritten-start
                rewritten-end
                rewritten-init
                rewritten-value)))])]
    [(SpmdScan scan-box)
      (match (__tl-box-place scan-box)
        [(Scan
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
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [init : ast.AstExpr (spec-owner-expr-get owner init-box)]
            [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            [value-subs : SpecTypeSubst
              (spec-type-subst-remove-name subs index)]
            [body-subs : SpecTypeSubst
              (spec-type-subst-remove-name value-subs prefix)]
            [rewritten-start : i64
              (try (spec-substitute-types-expr-with-owner owner start subs))]
            [rewritten-end : i64
              (try (spec-substitute-types-expr-with-owner owner end subs))]
            [rewritten-init : i64
              (try (spec-substitute-types-expr-with-owner owner init subs))]
            [rewritten-value : i64
              (try
                (spec-substitute-types-expr-with-owner owner value value-subs))]
            [rewritten-body : i64
              (try (spec-substitute-types-expr-with-owner owner body body-subs))]
            (Ok
              (ast.ast-expr-spmd-scan-id-with-pools
                (spec-owner-pools owner)
                op
                index
                (spec-substitute-type-with-owner owner index-ty subs)
                rewritten-start
                rewritten-end
                prefix
                (spec-substitute-type-with-owner owner prefix-ty subs)
                rewritten-init
                rewritten-value
                rewritten-body)))])]
    [(SpmdCompact compact-box)
      (match (__tl-box-place compact-box)
        [(Compact
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
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [init : ast.AstExpr (spec-owner-expr-get owner init-box)]
            [keep : ast.AstExpr (spec-owner-expr-get owner keep-box)]
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            [keep-subs : SpecTypeSubst (spec-type-subst-remove-name subs index)]
            [body-subs : SpecTypeSubst
              (spec-type-subst-remove-name keep-subs slot)]
            [rewritten-start : i64
              (try (spec-substitute-types-expr-with-owner owner start subs))]
            [rewritten-end : i64
              (try (spec-substitute-types-expr-with-owner owner end subs))]
            [rewritten-init : i64
              (try (spec-substitute-types-expr-with-owner owner init subs))]
            [rewritten-keep : i64
              (try (spec-substitute-types-expr-with-owner owner keep keep-subs))]
            [rewritten-body : i64
              (try (spec-substitute-types-expr-with-owner owner body body-subs))]
            (Ok
              (ast.ast-expr-spmd-compact-id-with-pools
                (spec-owner-pools owner)
                index
                (spec-substitute-type-with-owner owner index-ty subs)
                rewritten-start
                rewritten-end
                slot
                (spec-substitute-type-with-owner owner slot-ty subs)
                rewritten-init
                rewritten-keep
                rewritten-body)))])]
    [(Let let-box)
      (match (__tl-box-place let-box)
        [(Let bindings body-box)
          (let
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            [body-subs : SpecTypeSubst
              (spec-type-subst-remove-let-binding-names subs bindings)]
            [rewritten-bindings : ast.AstLetBindingList
              (try
                (spec-substitute-types-let-bindings-with-owner
                  owner
                  bindings
                  subs))]
            [rewritten-body : i64
              (try (spec-substitute-types-expr-with-owner owner body body-subs))]
            (Ok
              (ast.ast-expr-let-with-pools
                (spec-owner-pools owner)
                rewritten-bindings
                rewritten-body)))])]
    [(ForOwnedState payload)
      (let
        [rewritten : ast.AstExprList
          (try
            (spec-substitute-types-expr-list-with-owner
              owner
              (spec-for-owned-state-exprs
                (ast.ast-for-owned-state-source-name (& payload))
                (ast.ast-for-owned-state-index-name (& payload))
                (ast.ast-for-owned-state-source (& payload))
                (ast.ast-for-owned-state-body (& payload)))
              subs))]
        (Ok
          (ast.ast-expr-for-owned-state-with-pools
            (spec-owner-pools owner)
            (ast.ast-expr-list-get (& rewritten) 0 0)
            (ast.ast-expr-list-get (& rewritten) 1 0)
            (ast.ast-expr-list-get (& rewritten) 2 0)
            (ast.ast-expr-list-get (& rewritten) 3 0))))]
    [(ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        [rewritten : ast.AstExprList
          (try
            (spec-substitute-types-expr-list-with-owner
              owner
              (spec-for-owned-step-exprs
                (ast.ast-for-owned-step-source-name (& payload))
                (ast.ast-for-owned-step-index-name (& payload))
                (ast.ast-for-owned-step-binding-name (& payload))
                expected-type
                (ast.ast-for-owned-step-done-name (& payload))
                (ast.ast-for-owned-step-body (& payload)))
              subs))]
        [typed? : bool (>= expected-type 0)]
        [done-index : i64
          (if typed?
            4
            3)]
        [body-index : i64
          (if typed?
            5
            4)]
        (Ok
          (ast.ast-expr-for-owned-step-with-pools
            (spec-owner-pools owner)
            (ast.ast-expr-list-get (& rewritten) 0 0)
            (ast.ast-expr-list-get (& rewritten) 1 0)
            (ast.ast-expr-list-get (& rewritten) 2 0)
            (if typed?
              (ast.ast-expr-list-get (& rewritten) 3 0)
              -1)
            (ast.ast-expr-list-get (& rewritten) done-index 0)
            (ast.ast-expr-list-get (& rewritten) body-index 0))))]
    [(Set name value-box)
      (let
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-type-subst-lookup subs name)
          [(Some _)
            (Err
              (box
                (spec-diagnostic-at-expr
                  expr
                  (str_cat.str-cat
                    "type-valued comptime parameter '"
                    (spec_ci.intern-compat-state-str
                      (spec-owner-intern-state owner)
                      name)
                    "' cannot be assigned"))))]
          [(None)
            (let
              [rewritten : i64
                (try (spec-substitute-types-expr-with-owner owner value subs))]
              (Ok
                (ast.ast-expr-set-id-with-pools
                  (spec-owner-pools owner)
                  name
                  rewritten)))]))]
    [(Match match-box)
      (match (__tl-box-place match-box)
        [(Match scrutinee-box arms)
          (let
            [scrutinee : ast.AstExpr (spec-owner-expr-get owner scrutinee-box)]
            [rewritten-scrutinee : i64
              (try (spec-substitute-types-expr-with-owner owner scrutinee subs))]
            [rewritten-arms : ast.AstMatchArmList
              (try
                (spec-substitute-types-match-arms-with-owner owner arms subs))]
            (Ok
              (ast.ast-expr-match-with-pools
                (spec-owner-pools owner)
                rewritten-scrutinee
                rewritten-arms)))])]
    [(WithResource wr-box)
      (match (__tl-box-place wr-box)
        [(WithResource bindings body)
          (spec-substitute-types-resource-with-owner owner bindings body subs)])]
    [(PtrNull ty-id)
      (Ok
        (spec-owner-expr-push
          owner
          (PtrNull
            (spec-owner-type-push
              owner
              (spec-substitute-type-with-owner
                owner
                (spec-owner-type-get owner ty-id)
                subs)))))]
    [(PtrCast ptr-box ty-id)
      (let
        [ptr : ast.AstExpr (spec-owner-expr-get owner ptr-box)]
        [rewritten : i64
          (try (spec-substitute-types-expr-with-owner owner ptr subs))]
        (Ok
          (ast.ast-expr-ptr-cast-with-pools
            (spec-owner-pools owner)
            rewritten
            (spec-substitute-type-with-owner
              owner
              (spec-owner-type-get owner ty-id)
              subs))))]
    [(IntToPtr value-box ty-id)
      (let
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        [rewritten : i64
          (try (spec-substitute-types-expr-with-owner owner value subs))]
        (Ok
          (ast.ast-expr-int-to-ptr-with-pools
            (spec-owner-pools owner)
            rewritten
            (spec-substitute-type-with-owner
              owner
              (spec-owner-type-get owner ty-id)
              subs))))]
    [(Borrow _ _ _) (Ok (spec-owner-expr-push owner expr))]
    [_
      (match (spec-substitute-types-expr-list-with-owner
        owner
        (ast.ast-expr-child-ids (ast.ast-place-shared-view expr))
        subs)
        [(Ok ids)
          (Ok
            (spec-owner-expr-push
              owner
              (ast.ast-expr-with-child-ids expr (& ids))))]
        [(Err diag) (Err diag)])]))

(define (spec-substitute-types-expr-list-with-owner
  [owner : (& owner SpecOwnerContext)]
  [exprs : ast.AstExprList]
  [subs : (& subs SpecTypeSubst)]) : ResultSpecSubExprList
  (let
    [out : ast.AstExprList (ast.ast-expr-list-with-capacity exprs.len)]
    (match (spec-substitute-types-expr-list-at-with-owner
      owner
      (& exprs)
      0
      subs
      (&mut out))
      [(Ok) (Ok out)]
      [(Err diag) (Err diag)])))

(define (spec-substitute-types-expr-list-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [subs : (& subs SpecTypeSubst)]
  [out : (&mut out ast.AstExprList)]) : ResultSpecSubExprListBuild
  (if (>= index exprs.len)
    (Ok)
    (let
      [head : ast.AstExpr
        (spec-owner-expr-get owner (ast.ast-expr-list-get exprs index 0))]
      (match (spec-substitute-types-expr-with-owner owner head subs)
        [(Ok rewritten-head)
          (ast.ast-expr-list-push out rewritten-head)
          (spec-substitute-types-expr-list-at-with-owner
            owner
            exprs
            (+ index 1)
            subs
            out)]
        [(Err diag) (Err diag)]))))

(define (spec-substitute-types-let-bindings-with-owner
  [owner : (& owner SpecOwnerContext)]
  [bindings : ast.AstLetBindingList]
  [subs : (& subs SpecTypeSubst)]) : ResultSpecSubLetBindingList
  (let
    [out : ast.AstLetBindingList
      (ast.ast-let-binding-list-with-capacity
        (ast.ast-let-binding-list-len (& bindings)))]
    (match (spec-substitute-types-let-bindings-at-with-owner
      owner
      (& bindings)
      0
      subs
      (&mut out))
      [(Ok) (Ok out)]
      [(Err diag) (Err diag)])))

(define (spec-substitute-types-let-bindings-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [bindings : (& bindings ast.AstLetBindingList)]
  [index : i64]
  [subs : (& subs SpecTypeSubst)]
  [out : (&mut out ast.AstLetBindingList)]) : ResultSpecSubLetBindingListBuild
  (if (>= index (ast.ast-let-binding-list-len bindings))
    (Ok)
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(Binding name ty value-box)
        (let
          [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
          [next-subs : SpecTypeSubst (spec-type-subst-remove-name subs name)]
          (match (spec-substitute-types-expr-with-owner owner value subs)
            [(Ok rewritten-value)
              (ast.ast-let-binding-list-push
                out
                (ast.ast-let-binding-id
                  name
                  (spec-substitute-maybe-type-with-owner owner ty subs)
                  rewritten-value))
              (spec-substitute-types-let-bindings-at-with-owner
                owner
                bindings
                (+ index 1)
                next-subs
                out)]
            [(Err diag) (Err diag)]))])))

(define (spec-substitute-types-match-arms-with-owner
  [owner : (& owner SpecOwnerContext)]
  [arms : ast.AstMatchArmList]
  [subs : (& subs SpecTypeSubst)]) : ResultSpecSubMatchArmList
  (let
    [out : ast.AstMatchArmList (ast.ast-match-arm-list-with-capacity arms.len)]
    (match (spec-substitute-types-match-arms-at-with-owner
      owner
      (& arms)
      0
      subs
      (&mut out))
      [(Ok) (Ok out)]
      [(Err diag) (Err diag)])))

(define (spec-substitute-types-match-arms-at-with-owner
  [owner : (& owner SpecOwnerContext)]
  [arms : (& arms ast.AstMatchArmList)]
  [index : i64]
  [subs : (& subs SpecTypeSubst)]
  [out : (&mut out ast.AstMatchArmList)]) : ResultSpecSubMatchArmListBuild
  (if (>= index arms.len)
    (Ok)
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(Arm pattern body-box)
        (let
          [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
          [body-subs : SpecTypeSubst
            (spec-type-subst-remove-pattern
              subs
              (ast.ast-place-shared-view pattern))]
          (match (spec-substitute-types-expr-with-owner owner body body-subs)
            [(Ok rewritten-body)
              (ast.ast-match-arm-list-push
                out
                (ast.ast-match-arm pattern rewritten-body))
              (spec-substitute-types-match-arms-at-with-owner
                owner
                arms
                (+ index 1)
                subs
                out)]
            [(Err diag) (Err diag)]))])))

(define (spec-rewrite-decl-with-owner
  [owner : (& owner SpecOwnerContext)]
  [decl : ast.AstDecl]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]) : ResultSpecDecl
  (match (ast.ast-place-shared-view decl)
    [(Def decl-meta name ty value-box)
      (let
        [value : ast.AstExpr (spec-state-expr-get state value-box)]
        (match (spec-rewrite-expr value templates state)
          [(Ok rewritten state2)
            (Ok (Some (ast.ast-decl-def-id name ty rewritten)) state2)]
          [(Err diag) (Err diag)]))]
    [(DefFn decl-meta name params ret body-box metadata)
      (let
        [body : ast.AstExpr (spec-state-expr-get state body-box)]
        [body-templates : SpecTemplateEnv
          (spec-template-env-shadow-params templates params)]
        (if (spec-param-list-has-comptime? params)
          (Ok (None) state)
          (match (spec-rewrite-expr body body-templates state)
            [(Ok rewritten state2)
              (Ok
                (Some
                  (ast.ast-decl-def-fn-metadata-id
                    name
                    params
                    ret
                    rewritten
                    metadata))
                state2)]
            [(Err diag) (Err diag)])))]
    [(Unsafe inner-box)
      (let
        [inner : ast.AstDecl (ast.ast-decl-box-shared-view inner-box)]
        (match (spec-rewrite-decl-with-owner owner inner templates state)
          [(Ok maybe state2)
            (match maybe
              [(Some rewritten)
                (Ok (Some (ast.ast-decl-unsafe rewritten)) state2)]
              [(None) (Ok None state2)])]
          [(Err diag) (Err diag)]))]
    [(DefMacro decl-meta name params ret body-box)
      (let
        [body : ast.AstExpr (spec-state-expr-get state body-box)]
        (match (spec-rewrite-expr body templates state)
          [(Ok rewritten state2)
            (Ok
              (Some (ast.ast-decl-def-macro-id name params ret rewritten))
              state2)]
          [(Err diag) (Err diag)]))]
    [_ (Ok (Some decl) state)]))

(define (spec-rewrite-decls-with-owner
  [owner : (& owner SpecOwnerContext)]
  [decls : ast.AstDeclList]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]) : ResultSpecDecls
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [cursor : ast.AstDeclList decls]
    [out : ast.AstDeclList (ast.ast-decl-list-with-capacity count)]
    [out-origins : parser.CompilerParseDeclOriginAliasVec
      (parser.compiler-parse-decl-origin-alias-vec-with-capacity count)]
    [cur-state : SpecState state]
    [result : ResultSpecDecls
      (Err
        (box
          (cdiag.compiler-diagnostic-simple
            "<internal>"
            1
            1
            "specialization rewrite did not finish")))]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step cursor)
        [(Nil)
          (parser.compiler-parse-decl-origin-alias-vec-register!
            (& out)
            (& out-origins))
          (set!
            result
            (Ok
              (ast.ast-place-shared-view out)
              (spec-place-shared-view cur-state)))
          (set! done true)]
        [(Cons decl rest)
          (match (spec-rewrite-decl-with-owner
            owner
            (ast.ast-place-shared-view decl)
            templates
            (spec-place-shared-view cur-state))
            [(Ok maybe-decl decl-state)
              (set! cur-state decl-state)
              (match maybe-decl
                [(None) unit]
                [(Some rewritten-decl)
                  (ast.ast-decl-list-push (&mut out) rewritten-decl)
                  (parser.compiler-parse-decl-origin-alias-vec-push-key-slot!
                    (&mut out-origins)
                    (- (ast.ast-decl-list-len (& out)) 1)
                    1
                    (parser.compiler-parse-decl-list-storage-key (& rest))
                    (- rest.offset 1)
                    decl
                    false)])
              (set! cursor rest)]
            [(Err diag)
              (set! result (Err diag))
              (set! done true)])]))
    result))

(define (spec-rewrite-decls-with-paths-with-owner
  [owner : (& owner SpecOwnerContext)]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [templates : (& templates SpecTemplateEnv)]
  [state : SpecState]) : ResultSpecDeclsWithPaths
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [decl-cursor : ast.AstDeclList decls]
    [path-cursor : ast.AstDeclPathList paths]
    [out : ast.AstDeclList (ast.ast-decl-list-with-capacity count)]
    [out-paths : ast.AstDeclPathList
      (ast.ast-decl-path-list-with-capacity count)]
    [out-origins : parser.CompilerParseDeclOriginAliasVec
      (parser.compiler-parse-decl-origin-alias-vec-with-capacity count)]
    [cur-state : SpecState state]
    [result : ResultSpecDeclsWithPaths
      (Err
        (box
          (cdiag.compiler-diagnostic-simple
            "<internal>"
            1
            1
            "specialization rewrite with paths did not finish")))]
    [done : bool false]
    (while (not done)
      (match (ast.ast-decl-list-step decl-cursor)
        [(Nil)
          (parser.compiler-parse-decl-origin-alias-vec-register!
            (& out)
            (& out-origins))
          (set!
            result
            (Ok
              (ast.ast-place-shared-view out)
              (spec-place-shared-view out-paths)
              (spec-place-shared-view cur-state)))
          (set! done true)]
        [(Cons decl rest)
          (let
            [decl-path : String
              (gen-path-list-head-or
                (spec-place-shared-view path-cursor)
                (spec-place-shared-view fallback-path))]
            [owner-id : i64
              (ast.ast-decl-path-list-owner-id
                (& path-cursor)
                0
                cbi.compiler-builtin-id-fix-empty)]
            [provenance-id : i64
              (ast.ast-decl-path-list-provenance-id
                (& path-cursor)
                0
                cbi.compiler-builtin-id-fix-empty)]
            (match (spec-rewrite-decl-with-owner
              owner
              (ast.ast-place-shared-view decl)
              templates
              (spec-place-shared-view cur-state))
              [(Ok maybe-decl decl-state)
                (set! cur-state decl-state)
                (match maybe-decl
                  [(None) unit]
                  [(Some rewritten-decl)
                    (ast.ast-decl-list-push (&mut out) rewritten-decl)
                    (parser.compiler-parse-decl-origin-alias-vec-push-key-slot!
                      (&mut out-origins)
                      (- (ast.ast-decl-list-len (& out)) 1)
                      1
                      (parser.compiler-parse-decl-list-storage-key (& rest))
                      (- rest.offset 1)
                      decl
                      false)
                    (ast.ast-decl-path-list-push-with-owner-and-provenance-id
                      (&mut out-paths)
                      decl-path
                      owner-id
                      provenance-id)])
                (set! decl-cursor rest)
                (set! path-cursor (gen-path-list-tail path-cursor))]
              [(Err diag)
                (set! result (Err diag))
                (set! done true)]))]))
    result))

(define (spec-generated-paths
  [decls : ast.AstDeclList]
  [fallback-path : String]) : ast.AstDeclPathList
  (if (string.eq fallback-path "")
    (ast.ast-decl-path-list-new)
    (gen-path-list-for-decls
      decls
      fallback-path
      cbi.compiler-builtin-id-fix-empty
      cbi.compiler-builtin-id-fix-empty
      (ast.ast-decl-path-list-new))))

;; Explicit production entrypoints.  The owner is assembled once and is
;; threaded through normalization, template collection, and the rewrite
;; graph; no active pool or interner is installed on this path.
(define (compiler-specialize-program-with-pools-and-intern-state
  [program : ast.AstProgram]
  [pools : ast.AstNodePoolContext]
  [intern-state : spec_ci.InternCompatState]) : ResultSpecProgram
  (let
    [owner : SpecOwnerContext (spec-owner-context-new pools intern-state)]
    [normalized : ast.AstProgram
      (try (gen-normalize-program-with-pools-and-intern-state program owner))]
    (match (ast.ast-place-shared-view normalized)
      [(Program decls-box)
        (let
          [decls : ast.AstDeclList
            (ast.ast-decl-list-box-shared-view decls-box)]
          [templates : SpecTemplateList
            (spec-collect-templates-with-pools
              (spec-owner-pools owner)
              (ast.ast-place-shared-view decls))]
          [template-env : SpecTemplateEnv
            (spec-template-env-from-list (spec-place-shared-view templates))]
          [ctfe-env : ctfe.CtfeEnv
            (spec-owner-ctfe-env
              owner
              (ctfe.ctfe-reflections-from-program
                (ast.ast-place-shared-view normalized)))]
          (if (= templates.len 0)
            (Ok normalized)
            (match (spec-rewrite-decls-with-owner
              owner
              decls
              template-env
              (State
                (ast.ast-decl-list-new)
                (spec_id_i64_map.with-capacity 64)
                ctfe-env
                (spec-place-shared-view owner)))
              [(Ok rewritten state)
                (match state
                  [(State generated _ _ _)
                    (spec-materialize-owner-generated-symbols! owner)
                    (Ok
                      (ast.ast-program
                        (spec-decl-list-append rewritten generated)))])]
              [(Err diag) (Err diag)])))])))

(define (compiler-specialize-program-with-paths-and-pools-and-intern-state-and-profile-state
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [pools : ast.AstNodePoolContext]
  [intern-state : spec_ci.InternCompatState]
  [profile-state : profile_state.CompilerProfileState]) : ResultSpecProgramWithPaths
  (let
    [owner : SpecOwnerContext
      (spec-owner-context-new-with-profile-state
        pools
        intern-state
        profile-state)]
    (match (gen-normalize-program-with-paths-and-pools-and-intern-state
      program
      paths
      (spec-place-shared-view fallback-path)
      owner)
      [(Ok normalized normalized-paths)
        (match (ast.ast-place-shared-view normalized)
          [(Program decls-box)
            (let
              [decls : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view decls-box)]
              [templates : SpecTemplateList
                (spec-collect-templates-with-pools
                  (spec-owner-pools owner)
                  (ast.ast-place-shared-view decls))]
              [template-env : SpecTemplateEnv
                (spec-template-env-from-list (spec-place-shared-view templates))]
              [ctfe-env : ctfe.CtfeEnv
                (spec-owner-ctfe-env
                  owner
                  (ctfe.ctfe-reflections-from-program
                    (ast.ast-place-shared-view normalized)))]
              (if (= templates.len 0)
                (Ok normalized normalized-paths)
                (match (spec-rewrite-decls-with-paths-with-owner
                  owner
                  decls
                  normalized-paths
                  (spec-place-shared-view fallback-path)
                  template-env
                  (State
                    (ast.ast-decl-list-new)
                    (spec_id_i64_map.with-capacity 64)
                    ctfe-env
                    (spec-place-shared-view owner)))
                  [(Ok rewritten rewritten-paths state)
                    (match state
                      [(State generated _ _ _)
                        (spec-materialize-owner-generated-symbols! owner)
                        (Ok
                          (ast.ast-program
                            (spec-decl-list-append rewritten generated))
                          (spec-decl-path-list-append
                            rewritten-paths
                            (spec-generated-paths generated fallback-path)))])]
                  [(Err diag) (Err diag)])))])]
      [(Err diag) (Err diag)])))

(define (compiler-specialize-program-with-paths-and-pools-and-intern-state
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [pools : ast.AstNodePoolContext]
  [intern-state : spec_ci.InternCompatState]) : ResultSpecProgramWithPaths
  (compiler-specialize-program-with-paths-and-pools-and-intern-state-and-profile-state
    program
    paths
    fallback-path
    pools
    intern-state
    (profile_state.compiler-profile-state-new)))

;; Compatibility adapters for the serial compiler surface. The worker graph
;; above remains owner-routed; these adapters bridge the active pool and intern
;; views, restore the prior ambient pool context, and publish mutations on both
;; Ok and Err returns.
(define (compiler-specialize-program-with-pools
  [program : ast.AstProgram]
  [pools : ast.AstNodePoolContext]) : ResultSpecProgram
  (let
    [previous-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [intern-state : spec_ci.InternCompatState
      (spec_ci.intern-compat-state-capture-active)]
    (ast.ast-node-pool-context-install! pools)
    (spec_ci.intern-compat-state-install! intern-state)
    (let
      [result : ResultSpecProgram
        (compiler-specialize-program-with-pools-and-intern-state
          program
          pools
          (spec_ci.intern-global-shared-view intern-state))]
      (ast.ast-node-pool-context-install! previous-pools)
      (spec_ci.intern-compat-state-install! intern-state)
      result)))

(define (compiler-specialize-program-with-paths-and-pools
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [pools : ast.AstNodePoolContext]) : ResultSpecProgramWithPaths
  (let
    [previous-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [intern-state : spec_ci.InternCompatState
      (spec_ci.intern-compat-state-capture-active)]
    (ast.ast-node-pool-context-install! pools)
    (spec_ci.intern-compat-state-install! intern-state)
    (let
      [result : ResultSpecProgramWithPaths
        (compiler-specialize-program-with-paths-and-pools-and-intern-state
          program
          paths
          fallback-path
          pools
          (spec_ci.intern-global-shared-view intern-state))]
      (ast.ast-node-pool-context-install! previous-pools)
      (spec_ci.intern-compat-state-install! intern-state)
      result)))

(define (compiler-specialize-program [program : ast.AstProgram]) : ResultSpecProgram
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultSpecProgram
      (compiler-specialize-program-with-pools program pools)]
    (ast.ast-node-pool-context-install! pools)
    result))

(define (compiler-specialize-needed-with-pools
  [program : ast.AstProgram]
  [pools : ast.AstNodePoolContext]) : bool
  (match program
    [(Program decls-box)
      (let
        [decls : ast.AstDeclList (ast.ast-decl-list-box-shared-view decls-box)]
        (if (gen-decls-needed? (ast.ast-place-shared-view decls))
          true
          (let
            [templates : SpecTemplateList
              (spec-collect-templates-with-pools pools decls)]
            (> templates.len 0))))]))