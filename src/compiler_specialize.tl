;; compiler_specialize.tl - Selfhost comptime function specialization.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.array)
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

(defenum SpecTemplateShadowList
  (Nil)
  (Cons i64 (Box SpecTemplateShadowList)))

(defenum SpecMaybeTemplate
  (None)
  (Some SpecTemplate))

(defstruct SpecTemplateEnv
  (index spec_id_i64_map.Map)
  (values (__tl_dyn-array SpecMaybeTemplate))
  (shadowed SpecTemplateShadowList))

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
(defstruct SpecOwnerContext
  (pools ast.AstNodePoolContext)
  (expr-segment-bases i64)
  (intern-state spec_ci.InternCompatState)
  (generated-symbol-records (__tl_dyn-array SpecGeneratedSymbolRecords)))

(define (spec-owner-context-new
  [pools : ast.AstNodePoolContext]
  [intern-state : spec_ci.InternCompatState]) : SpecOwnerContext
  (let
    [records : (__tl_dyn-array SpecGeneratedSymbolRecords)
      (array.make-array SpecGeneratedSymbolRecords 1)]
    (begin
      (array-set!
        records
        0
        (SpecGeneratedSymbolRecords
          (array.make-array SpecGeneratedSymbolRecord 0)
          0))
      (SpecOwnerContext
        pools
        (ast.ast-node-pool-context-expr-segment-bases pools)
        intern-state
        records))))

(define (spec-generated-symbol-records-copy-range
  [dst : (&mut dst (__tl_dyn-array SpecGeneratedSymbolRecord))]
  [src : (& src (__tl_dyn-array SpecGeneratedSymbolRecord))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array.ref src index))
      (spec-generated-symbol-records-copy-range dst src (+ index 1) count))))

(define (spec-generated-symbol-records-grow!
  [records : (&mut records SpecGeneratedSymbolRecords)]) : unit
  (let
    [count : i64 (struct-get records len)]
    [bigger : (__tl_dyn-array SpecGeneratedSymbolRecord)
      (array.make-array SpecGeneratedSymbolRecord (+ (* count 2) 8))]
    (begin
      (spec-generated-symbol-records-copy-range
        (&mut bigger)
        (& (struct-get records slots))
        0
        count)
      (set! (struct-get records slots) bigger))))

(define (spec-generated-symbol-records-push!
  [records : (&mut records SpecGeneratedSymbolRecords)]
  [item : SpecGeneratedSymbolRecord]) : unit
  (begin
    (if (< (struct-get records len) (array.length (struct-get records slots)))
      unit
      (spec-generated-symbol-records-grow! records))
    (let
      [count : i64 (struct-get records len)]
      (begin
        (array-set! (struct-get records slots) count item)
        (set! (struct-get records len) (+ count 1))))))

(define (spec-owner-pools [owner : SpecOwnerContext]) : ast.AstNodePoolContext
  (struct-get owner pools))

(define (spec-owner-intern-state [owner : SpecOwnerContext]) : spec_ci.InternCompatState
  (struct-get owner intern-state))

(define (spec-owner-expr-get [owner : SpecOwnerContext] [id : i64]) : ast.AstExpr
  (ast.ast-expr-segment-bases-get (struct-get owner expr-segment-bases) id))

(define (spec-owner-type-get [owner : SpecOwnerContext] [id : i64]) : ast.AstType
  (ast.ast-node-pool-context-type-get (struct-get owner pools) id))

(define (spec-owner-expr-push [owner : SpecOwnerContext] [node : ast.AstExpr]) : i64
  (ast.ast-node-pool-context-expr-push (struct-get owner pools) node))

(define (spec-owner-type-push [owner : SpecOwnerContext] [node : ast.AstType]) : i64
  (ast.ast-node-pool-context-type-push (struct-get owner pools) node))

(define (spec-owner-ctfe-env
  [owner : SpecOwnerContext]
  [reflections : ctfe.CtfeReflectInfoList]) : ctfe.CtfeEnv
  (ctfe.ctfe-env-with-reflections-and-pools-and-source-names
    reflections
    (spec-owner-pools owner)
    (spec_ci.intern-source-name-session-handle-from-state
      (spec-owner-intern-state owner))))

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
  `(struct-get ,key value))

(cfg
  compile-profile
  (define spec-profile-structural-key-created : i64
    0))
(cfg
  compile-profile
  (define spec-profile-structural-key-reused : i64
    0))
(cfg
  compile-profile
  (define spec-profile-name-render-calls : i64
    0))
(cfg
  compile-profile
  (define spec-profile-name-render-cache-hits : i64
    0))
(cfg
  compile-profile
  (define spec-profile-name-render-cache-misses : i64
    0))
(cfg
  compile-profile
  (define spec-profile-generated-text-materialized : i64
    0))

(define (spec-profile-reset!) : unit
  (cfg
    compile-profile
    (begin
      (set! spec-profile-structural-key-created 0)
      (set! spec-profile-structural-key-reused 0)
      (set! spec-profile-name-render-calls 0)
      (set! spec-profile-name-render-cache-hits 0)
      (set! spec-profile-name-render-cache-misses 0)
      (set! spec-profile-generated-text-materialized 0))
    unit))

(define (spec-profile-note-generated-text-materialized) : unit
  (cfg
    compile-profile
    (set!
      spec-profile-generated-text-materialized
      (+ spec-profile-generated-text-materialized 1))
    unit))

(define (spec-profile-note-structural-key [_created? : bool]) : unit
  (cfg
    compile-profile
    (if _created?
      (set!
        spec-profile-structural-key-created
        (+ spec-profile-structural-key-created 1))
      (set!
        spec-profile-structural-key-reused
        (+ spec-profile-structural-key-reused 1)))
    unit))

(define (spec-profile-note-name-render [_cache-hit? : bool]) : unit
  (cfg
    compile-profile
    (begin
      (set! spec-profile-name-render-calls (+ spec-profile-name-render-calls 1))
      (if _cache-hit?
        (set!
          spec-profile-name-render-cache-hits
          (+ spec-profile-name-render-cache-hits 1))
        (set!
          spec-profile-name-render-cache-misses
          (+ spec-profile-name-render-cache-misses 1))))
    unit))

(cfg
  compile-profile
  (define (spec-profile-structural-key-created-value) : i64
    spec-profile-structural-key-created))

(cfg
  compile-profile
  (define (spec-profile-structural-key-reused-value) : i64
    spec-profile-structural-key-reused))

(cfg
  compile-profile
  (define (spec-profile-name-render-calls-value) : i64
    spec-profile-name-render-calls))

(cfg
  compile-profile
  (define (spec-profile-name-render-cache-hits-value) : i64
    spec-profile-name-render-cache-hits))

(cfg
  compile-profile
  (define (spec-profile-name-render-cache-misses-value) : i64
    spec-profile-name-render-cache-misses))

(cfg
  compile-profile
  (define (spec-profile-generated-text-materialized-value) : i64
    spec-profile-generated-text-materialized))

(defenum SpecValueBinding
  (Bind i64 ctfe.CompilerCtfeValue))

(defstruct SpecValueSubst
  (slots (__tl_dyn-array SpecValueBinding))
  (len i64))

(defenum SpecTypeBinding
  (Bind i64 ast.AstType))

(defstruct SpecTypeSubst
  (slots (__tl_dyn-array SpecTypeBinding))
  (len i64))

(define (spec-template-list-new) : SpecTemplateList
  (SpecTemplateList (array.make-array SpecTemplate 0) 0))

(define (spec-template-list-copy-range
  [dst : (&mut dst (__tl_dyn-array SpecTemplate))]
  [src : (& src (__tl_dyn-array SpecTemplate))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array.ref src index))
      (spec-template-list-copy-range dst src (+ index 1) count))))

(define (spec-template-list-grow
  [templates : (&mut templates SpecTemplateList)]) : unit
  (let
    [count : i64 (struct-get templates len)]
    [bigger : (__tl_dyn-array SpecTemplate)
      (array.make-array SpecTemplate (+ (* count 2) 8))]
    (begin
      (spec-template-list-copy-range
        (&mut bigger)
        (& (struct-get templates slots))
        0
        count)
      (set! (struct-get templates slots) bigger))))

(define (spec-template-list-push
  [templates : (&mut templates SpecTemplateList)]
  [item : SpecTemplate]) : unit
  (begin
    (if (<
      (struct-get templates len)
      (array.length (struct-get templates slots)))
      unit
      (spec-template-list-grow templates))
    (let
      [count : i64 (struct-get templates len)]
      (begin
        (array-set! (struct-get templates slots) count item)
        (set! (struct-get templates len) (+ count 1))))))

(define (spec-value-list-new) : SpecValueList
  (SpecValueList (array.make-array ctfe.CompilerCtfeValue 0) 0))

(define (spec-value-cons [head : ctfe.CompilerCtfeValue] [rest : SpecValueList]) : SpecValueList
  (let
    [count : i64 (struct-get rest len)]
    [slots : (__tl_dyn-array ctfe.CompilerCtfeValue)
      (array.make-array ctfe.CompilerCtfeValue (+ count 1))]
    [at : i64 0]
    (begin
      (array-set! slots 0 head)
      (while (< at count)
        (begin
          (array-set! slots (+ at 1) (array.ref (struct-get rest slots) at))
          (set! at (+ at 1))))
      (SpecValueList slots (+ count 1)))))

(define (spec-value-subst-new) : SpecValueSubst
  (SpecValueSubst (array.make-array SpecValueBinding 0) 0))

(define (spec-value-subst-cons
  [key-id : i64]
  [value : ctfe.CompilerCtfeValue]
  [rest : SpecValueSubst]) : SpecValueSubst
  (let
    [count : i64 (struct-get rest len)]
    [slots : (__tl_dyn-array SpecValueBinding)
      (array.make-array SpecValueBinding (+ count 1))]
    [at : i64 0]
    (begin
      (array-set! slots 0 (SpecValueBinding.Bind key-id value))
      (while (< at count)
        (begin
          (array-set! slots (+ at 1) (array.ref (struct-get rest slots) at))
          (set! at (+ at 1))))
      (SpecValueSubst slots (+ count 1)))))

(define (spec-type-subst-new) : SpecTypeSubst
  (SpecTypeSubst (array.make-array SpecTypeBinding 0) 0))

(define (spec-type-subst-cons
  [key-id : i64]
  [ty : ast.AstType]
  [rest : SpecTypeSubst]) : SpecTypeSubst
  (let
    [count : i64 (struct-get rest len)]
    [slots : (__tl_dyn-array SpecTypeBinding)
      (array.make-array SpecTypeBinding (+ count 1))]
    [at : i64 0]
    (begin
      (array-set! slots 0 (SpecTypeBinding.Bind key-id ty))
      (while (< at count)
        (begin
          (array-set! slots (+ at 1) (array.ref (struct-get rest slots) at))
          (set! at (+ at 1))))
      (SpecTypeSubst slots (+ count 1)))))

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
    [(ast.AstExpr.Spanned _ span)
      (cdiag.compiler-diagnostic-from-ast-span "" span message)]
    [_ (cdiag.compiler-diagnostic-at-start "" message)]))

(define (spec-expr-maybe-span-with-owner
  [owner : SpecOwnerContext]
  [expr : ast.AstExpr]) : SpecMaybeSourceSpan
  (match expr
    [(ast.AstExpr.Spanned _ span) (SpecMaybeSourceSpan.Some span)]
    [(ast.AstExpr.Unary _ inner)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner inner))]
    [(ast.AstExpr.Ann inner _)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner inner))]
    [(ast.AstExpr.Cast inner _)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner inner))]
    [(ast.AstExpr.Borrow _ _ inner)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner inner))]
    [_ (SpecMaybeSourceSpan.None)]))

(define (spec-expr-list-maybe-span-at-with-owner
  [owner : SpecOwnerContext]
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]) : SpecMaybeSourceSpan
  (if (>= index (ast.ast-expr-list-len exprs))
    (SpecMaybeSourceSpan.None)
    (match (spec-expr-maybe-span-with-owner
      owner
      (spec-owner-expr-get owner (ast.ast-expr-list-get exprs index 0)))
      [(SpecMaybeSourceSpan.Some span) (SpecMaybeSourceSpan.Some span)]
      [(SpecMaybeSourceSpan.None)
        (spec-expr-list-maybe-span-at-with-owner owner exprs (+ index 1))])))

(define (spec-expr-list-maybe-span-with-owner
  [owner : SpecOwnerContext]
  [exprs : ast.AstExprList]) : SpecMaybeSourceSpan
  (spec-expr-list-maybe-span-at-with-owner owner (& exprs) 0))

(define (spec-decl-maybe-span-with-owner
  [owner : SpecOwnerContext]
  [decl : ast.AstDecl]) : SpecMaybeSourceSpan
  (match decl
    [(ast.AstDecl.Def decl-meta _ _ body)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner body))]
    [(ast.AstDecl.DefFn decl-meta _ _ _ body _)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner body))]
    [(ast.AstDecl.DefMacro decl-meta _ _ _ body)
      (spec-expr-maybe-span-with-owner owner (spec-owner-expr-get owner body))]
    [(ast.AstDecl.Test _ _ span) (SpecMaybeSourceSpan.Some span)]
    [(ast.AstDecl.Unsafe inner-box)
      (spec-decl-maybe-span-with-owner owner (box-get inner-box))]
    [_ (SpecMaybeSourceSpan.None)]))

(define (spec-generated-origin-diagnostic-with-owner
  [owner : SpecOwnerContext]
  [template : ast.AstDecl]
  [args : ast.AstExprList]
  [message : String]) : cdiag.CompilerDiagnostic
  (match (spec-decl-maybe-span-with-owner owner template)
    [(SpecMaybeSourceSpan.Some span)
      (cdiag.compiler-diagnostic-from-ast-span "" span message)]
    [(SpecMaybeSourceSpan.None)
      (match (spec-expr-list-maybe-span-with-owner owner args)
        [(SpecMaybeSourceSpan.Some span)
          (cdiag.compiler-diagnostic-from-ast-span "" span message)]
        [(SpecMaybeSourceSpan.None)
          (cdiag.compiler-diagnostic-at-start "" message)])]))

(define (spec-generated-context-diagnostic-with-owner
  [_owner : SpecOwnerContext]
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
    [(ast.AstParam.Param _ _ is-comptime _) is-comptime]))

(define (spec-param-name-id [param : ast.AstParam]) : i64
  (match param
    [(ast.AstParam.Param name _ _ _) name]))

(define (spec-state-ctfe-env [state : SpecState]) : ctfe.CtfeEnv
  (match state
    [(SpecState.State _ _ env _) env]))

(define (spec-state-owner [state : SpecState]) : SpecOwnerContext
  (match state
    [(SpecState.State _ _ _ owner) owner]))

(define (spec-state-pools [state : SpecState]) : ast.AstNodePoolContext
  (spec-owner-pools (spec-state-owner state)))

(define (spec-state-intern [state : SpecState]) : spec_ci.InternCompatState
  (spec-owner-intern-state (spec-state-owner state)))

(define (spec-state-expr-get [state : SpecState] [id : i64]) : ast.AstExpr
  (spec-owner-expr-get (spec-state-owner state) id))

(define (spec-ctfe-eval [state : SpecState] [expr : ast.AstExpr] [fuel : i64]) : ctfe.ResultCtfe
  (ctfe.compiler-ctfe-eval expr (spec-state-ctfe-env state) fuel))

(define (spec-type-kind? [ty : ast.AstType]) : bool
  (begin
    (cbi.compiler-builtin-refresh!)
    (match ty
      [(ast.AstType.Var name) (= name cbi.compiler-builtin-id-fix-type)]
      [_ false])))

(define (spec-param-list-has-comptime? [params : ast.AstParamList]) : bool
  (spec-param-list-has-comptime-at? (& params) 0))

(define (spec-param-list-has-comptime-at?
  [params : (& params ast.AstParamList)]
  [index : i64]) : bool
  (if (>= index (ast.ast-param-list-len params))
    false
    (if (spec-param-comptime?
      (ast.ast-param-list-get params index (ast.ast-param-fallback)))
      true
      (spec-param-list-has-comptime-at? params (+ index 1)))))

(define (spec-template-shadow-contains?
  [shadowed : SpecTemplateShadowList]
  [name-id : i64]) : bool
  (match shadowed
    [(SpecTemplateShadowList.Nil) false]
    [(SpecTemplateShadowList.Cons shadow-name rest)
      (if (= shadow-name name-id)
        true
        (spec-template-shadow-contains? (box-get rest) name-id))]))

(define (spec-template-values-fill-empty
  [values : (__tl_dyn-array SpecMaybeTemplate)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! values index (SpecMaybeTemplate.None))
      (spec-template-values-fill-empty values (+ index 1) count))))

(define (spec-template-index-build
  [templates : SpecTemplateList]
  [index : spec_id_i64_map.Map (:consume)]
  [values : (__tl_dyn-array SpecMaybeTemplate)]
  [at : i64]
  [slot : i64]) : spec_id_i64_map.Map
  (if (>= at (struct-get templates len))
    index
    (let
      [template : SpecTemplate (array.ref (struct-get templates slots) at)]
      (match template
        [(SpecTemplate.Item name _ _ _)
          (if (spec_id_i64_map.contains? (& index) name)
            (spec-template-index-build templates index values (+ at 1) slot)
            (begin
              (array-set! values slot (SpecMaybeTemplate.Some template))
              (let
                [next-index : spec_id_i64_map.Map index]
                (begin
                  (spec_id_i64_map.insert-ref! (&mut next-index) name slot)
                  (spec-template-index-build
                    templates
                    next-index
                    values
                    (+ at 1)
                    (+ slot 1))))))]))))

(define (spec-template-env-from-list [templates : SpecTemplateList]) : SpecTemplateEnv
  (let
    [count : i64 (struct-get templates len)]
    [values : (__tl_dyn-array SpecMaybeTemplate)
      (array.make-array SpecMaybeTemplate count)]
    (begin
      (spec-template-values-fill-empty values 0 count)
      (SpecTemplateEnv
        (spec-template-index-build
          templates
          (spec_id_i64_map.with-capacity (+ (* count 2) 16))
          values
          0
          0)
        values
        SpecTemplateShadowList.Nil))))

(define (spec-template-lookup [templates : SpecTemplateEnv] [name-id : i64]) : SpecMaybeTemplate
  (if (spec-template-shadow-contains? (struct-get templates shadowed) name-id)
    (SpecMaybeTemplate.None)
    (match (spec_id_i64_map.get (& (struct-get templates index)) name-id)
      [(spec_id_i64_map.LookupFound slot)
        (array.ref (struct-get templates values) slot)]
      [(spec_id_i64_map.LookupMissing) (SpecMaybeTemplate.None)])))

(define (spec-template-env-shadow-name
  [templates : SpecTemplateEnv]
  [name-id : i64]) : SpecTemplateEnv
  (SpecTemplateEnv
    (struct-get templates index)
    (struct-get templates values)
    (SpecTemplateShadowList.Cons name-id (box (struct-get templates shadowed)))))

(define (spec-template-env-shadow-params
  [templates : SpecTemplateEnv]
  [params : ast.AstParamList]) : SpecTemplateEnv
  (spec-template-env-shadow-params-at templates (& params) 0))

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
  [templates : SpecTemplateEnv]
  [bindings : ast.AstLetBindingList]) : SpecTemplateEnv
  (spec-template-env-shadow-let-binding-names-at templates (& bindings) 0))

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
      [(ast.AstLetBinding.Binding name _ _)
        (spec-template-env-shadow-let-binding-names-at
          (spec-template-env-shadow-name templates name)
          bindings
          (+ index 1))])))

(define (spec-template-env-shadow-pattern
  [templates : SpecTemplateEnv]
  [pattern : ast.AstPattern]) : SpecTemplateEnv
  (match pattern
    [(ast.AstPattern.Var name _) (spec-template-env-shadow-name templates name)]
    [(ast.AstPattern.Tuple patterns-box)
      (let
        [patterns : ast.AstPatternList (box-get patterns-box)]
        (spec-template-env-shadow-pattern-list templates patterns))]
    [(ast.AstPattern.Array patterns-box)
      (let
        [patterns : ast.AstPatternList (box-get patterns-box)]
        (spec-template-env-shadow-pattern-list templates patterns))]
    [(ast.AstPattern.Wildcard) templates]
    [(ast.AstPattern.Binding name)
      (spec-template-env-shadow-name templates name)]
    [(ast.AstPattern.Variant _ patterns-box)
      (let
        [patterns : ast.AstPatternList (box-get patterns-box)]
        (spec-template-env-shadow-pattern-list templates patterns))]
    [(ast.AstPattern.Literal _) templates]))

(define (spec-template-env-shadow-pattern-list
  [templates : SpecTemplateEnv]
  [patterns : ast.AstPatternList]) : SpecTemplateEnv
  (spec-template-env-shadow-pattern-list-at templates (& patterns) 0))

(define (spec-template-env-shadow-pattern-list-at
  [templates : SpecTemplateEnv]
  [patterns : (& patterns ast.AstPatternList)]
  [index : i64]) : SpecTemplateEnv
  (if (>= index (struct-get patterns len))
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
    (begin
      (while (not done)
        (match (ast.ast-decl-list-step cursor)
          [(ast.AstDeclListStep.Nil) (set! done true)]
          [(ast.AstDeclListStep.Cons decl rest)
            (begin
              (match decl
                [(ast.AstDecl.Unsafe inner-box)
                  (match (box-get inner-box)
                    [(ast.AstDecl.DefFn decl-meta name params ret body-box _)
                      (if (spec-param-list-has-comptime? params)
                        (spec-template-list-push
                          (&mut out)
                          (SpecTemplate.Item
                            name
                            params
                            ret
                            (ast.ast-node-pool-context-expr-get pools body-box)))
                        unit)]
                    [_ unit])]
                [(ast.AstDecl.DefFn decl-meta name params ret body-box _)
                  (if (spec-param-list-has-comptime? params)
                    (spec-template-list-push
                      (&mut out)
                      (SpecTemplate.Item
                        name
                        params
                        ret
                        (ast.ast-node-pool-context-expr-get pools body-box)))
                    unit)]
                [_ unit])
              (set! cursor rest))]))
      out)))

(define (spec-cache-lookup [cache : spec_id_i64_map.Map] [name-id : i64]) : SpecMaybeId
  (match (spec_id_i64_map.get (& cache) name-id)
    [(spec_id_i64_map.LookupFound cached-name-id)
      (SpecMaybeId.Some cached-name-id)]
    [(spec_id_i64_map.LookupMissing) (SpecMaybeId.None)]))

(define (spec-decl-list-append-one
  [decls : ast.AstDeclList]
  [decl : ast.AstDecl]) : ast.AstDeclList
  (let
    [out : ast.AstDeclList
      (ast.ast-decl-list-with-capacity (+ (ast.ast-decl-list-len (& decls)) 1))]
    (begin
      (ast.ast-decl-list-append-from (&mut out) (& decls) 0)
      (ast.ast-decl-list-push (&mut out) decl)
      out)))

(define (spec-decl-list-append
  [front : ast.AstDeclList]
  [back : ast.AstDeclList]) : ast.AstDeclList
  (let
    [out : ast.AstDeclList
      (ast.ast-decl-list-with-capacity
        (+ (ast.ast-decl-list-len (& front)) (ast.ast-decl-list-len (& back))))]
    (begin
      (ast.ast-decl-list-append-from (&mut out) (& front) 0)
      (ast.ast-decl-list-append-from (&mut out) (& back) 0)
      out)))

(define (spec-decl-path-list-append
  [front : ast.AstDeclPathList]
  [back : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [out : ast.AstDeclPathList
      (ast.ast-decl-path-list-with-capacity
        (+
          (ast.ast-decl-path-list-len (& front))
          (ast.ast-decl-path-list-len (& back))))]
    (begin
      (ast.ast-decl-path-list-append-from (&mut out) (& front) 0)
      (ast.ast-decl-path-list-append-from (&mut out) (& back) 0)
      out)))

(define (gen-single-decl-list [decl : ast.AstDecl]) : ast.AstDeclList
  (ast.ast-decl-cons decl (ast.ast-decl-list-new)))

(define (spec-int-key [n : i64]) : String
  (if (< n 0)
    (str_cat.str-cat "m" (string.int->string (- 0 n)))
    (string.int->string n)))

;; Build the "_<code>" tail into `buf` without re-copying the accumulated
;; prefix per character. The old recursive string.append form cost O(n^2) per
;; key, and macro-identity-key-sexpr applies this to already-encoded sub-keys,
;; which made deep syntax identities allocate gigabytes on a self-compile.
(define (spec-string-key-from-into
  [text : String]
  [idx : i64]
  [n : i64]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (if (>= idx n)
    buf
    (spec-string-key-from-into
      text
      (+ idx 1)
      n
      (text_buf.append-int
        (text_buf.append buf "_")
        (cast (string.string-ref text idx) : i64)))))

(define (spec-string-key [text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    (text_buf.render
      (spec-string-key-from-into
        text
        0
        n
        (text_buf.append-int (text_buf.append (text_buf.empty) "string_") n)))))

(define (spec-type-list-key-at
  [types : (& types ast.AstTypeList)]
  [index : i64]) : String
  (if (>= index (ast.ast-type-list-len types))
    "nil"
    (str_cat.str-cat
      (spec-type-key
        (ast.ty-node-get
          (ast.ast-type-list-get types index (ast.ast-type-id-fallback))))
      "_"
      (spec-type-list-key-at types (+ index 1)))))

(define (spec-type-list-key [types : ast.AstTypeList]) : String
  (spec-type-list-key-at (& types) 0))

(define (spec-lifetime-list-key-at
  [lifetimes : (& lifetimes ast.AstLifetimeList)]
  [index : i64]) : String
  (if (>= index (ast.ast-lifetime-list-len lifetimes))
    "nil"
    (str_cat.str-cat
      (spec_ci.intern-str
        (ast.ast-lifetime-list-get lifetimes index (ast.ast-lifetime-fallback)))
      "_"
      (spec-lifetime-list-key-at lifetimes (+ index 1)))))

(define (spec-lifetime-list-key [lifetimes : ast.AstLifetimeList]) : String
  (spec-lifetime-list-key-at (& lifetimes) 0))

(define (spec-type-key [ty : ast.AstType]) : String
  (match ty
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
    [(ast.AstType.Unit) "unit"]
    [(ast.AstType.Never) "never"]
    [(ast.AstType.Expr) "Expr"]
    [(ast.AstType.ExprList) "ExprList"]
    [(ast.AstType.Func args ret)
      (str_cat.str-cat
        "fn_"
        (spec-type-list-key (box-get args))
        "_to_"
        (spec-type-key (ast.ty-node-get ret)))]
    [(ast.AstType.Tuple elems)
      (str_cat.str-cat "tuple_" (spec-type-list-key (box-get elems)))]
    [(ast.AstType.Array elem count)
      (str_cat.str-cat
        "array_"
        (spec-type-key (ast.ty-node-get elem))
        "_"
        (spec-int-key count))]
    [(ast.AstType.DynArray elem)
      (str_cat.str-cat "dynarray_" (spec-type-key (ast.ty-node-get elem)))]
    [(ast.AstType.Slice elem)
      (str_cat.str-cat "slice_" (spec-type-key (ast.ty-node-get elem)))]
    [(ast.AstType.Box elem)
      (str_cat.str-cat "box_" (spec-type-key (ast.ty-node-get elem)))]
    [(ast.AstType.Ptr elem)
      (str_cat.str-cat "ptr_" (spec-type-key (ast.ty-node-get elem)))]
    [(ast.AstType.MutPtr elem)
      (str_cat.str-cat "mutptr_" (spec-type-key (ast.ty-node-get elem)))]
    [(ast.AstType.Ref region inner)
      (str_cat.str-cat
        "ref_"
        (spec_ci.intern-str region)
        "_"
        (spec-type-key (ast.ty-node-get inner)))]
    [(ast.AstType.MutRef region inner)
      (str_cat.str-cat
        "mutref_"
        (spec_ci.intern-str region)
        "_"
        (spec-type-key (ast.ty-node-get inner)))]
    [(ast.AstType.Region region inner)
      (str_cat.str-cat
        "region_"
        (spec_ci.intern-str region)
        "_"
        (spec-type-key (ast.ty-node-get inner)))]
    [(ast.AstType.Enum name)
      (str_cat.str-cat "enum_" (ast.ast-nominal-name-id-display name))]
    [(ast.AstType.EnumArgs name lifetimes)
      (str_cat.str-cat
        "enumargs_"
        (ast.ast-nominal-name-id-display name)
        "_"
        (spec-lifetime-list-key (box-get lifetimes)))]
    [(ast.AstType.Struct name)
      (str_cat.str-cat "struct_" (ast.ast-nominal-name-id-display name))]
    [(ast.AstType.StructArgs name lifetimes)
      (str_cat.str-cat
        "structargs_"
        (ast.ast-nominal-name-id-display name)
        "_"
        (spec-lifetime-list-key (box-get lifetimes)))]
    [(ast.AstType.Var name) (str_cat.str-cat "var_" (spec_ci.intern-str name))]
    [(ast.AstType.VarArgs name lifetimes)
      (str_cat.str-cat
        "varargs_"
        (spec_ci.intern-str name)
        "_"
        (spec-lifetime-list-key (box-get lifetimes)))]
    [(ast.AstType.Consume inner)
      (str_cat.str-cat "consume_" (spec-type-key (ast.ty-node-get inner)))]))

(define (spec-type-list-key-at-with-owner
  [owner : SpecOwnerContext]
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
  [owner : SpecOwnerContext]
  [types : ast.AstTypeList]) : String
  (spec-type-list-key-at-with-owner owner (& types) 0))

(define (spec-lifetime-list-key-at-with-owner
  [owner : SpecOwnerContext]
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
  [owner : SpecOwnerContext]
  [lifetimes : ast.AstLifetimeList]) : String
  (spec-lifetime-list-key-at-with-owner owner (& lifetimes) 0))

(define (spec-type-key-with-owner [owner : SpecOwnerContext] [ty : ast.AstType]) : String
  (match ty
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
    [(ast.AstType.Unit) "unit"]
    [(ast.AstType.Never) "never"]
    [(ast.AstType.Expr) "Expr"]
    [(ast.AstType.ExprList) "ExprList"]
    [(ast.AstType.Func args ret)
      (str_cat.str-cat
        "fn_"
        (spec-type-list-key-with-owner owner (box-get args))
        "_to_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner ret)))]
    [(ast.AstType.Tuple elems)
      (str_cat.str-cat
        "tuple_"
        (spec-type-list-key-with-owner owner (box-get elems)))]
    [(ast.AstType.Array elem count)
      (str_cat.str-cat
        "array_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner elem))
        "_"
        (spec-int-key count))]
    [(ast.AstType.DynArray elem)
      (str_cat.str-cat
        "dynarray_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner elem)))]
    [(ast.AstType.Slice elem)
      (str_cat.str-cat
        "slice_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner elem)))]
    [(ast.AstType.Box elem)
      (str_cat.str-cat
        "box_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner elem)))]
    [(ast.AstType.Ptr elem)
      (str_cat.str-cat
        "ptr_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner elem)))]
    [(ast.AstType.MutPtr elem)
      (str_cat.str-cat
        "mutptr_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner elem)))]
    [(ast.AstType.Ref region inner)
      (str_cat.str-cat
        "ref_"
        (spec_ci.intern-compat-state-str (spec-owner-intern-state owner) region)
        "_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner inner)))]
    [(ast.AstType.MutRef region inner)
      (str_cat.str-cat
        "mutref_"
        (spec_ci.intern-compat-state-str (spec-owner-intern-state owner) region)
        "_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner inner)))]
    [(ast.AstType.Region region inner)
      (str_cat.str-cat
        "region_"
        (spec_ci.intern-compat-state-str (spec-owner-intern-state owner) region)
        "_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner inner)))]
    [(ast.AstType.Enum name)
      (str_cat.str-cat
        "enum_"
        (ast.ast-nominal-name-id-display-with-intern-state
          (spec-owner-intern-state owner)
          name))]
    [(ast.AstType.EnumArgs name lifetimes)
      (str_cat.str-cat
        "enumargs_"
        (ast.ast-nominal-name-id-display-with-intern-state
          (spec-owner-intern-state owner)
          name)
        "_"
        (spec-lifetime-list-key-with-owner owner (box-get lifetimes)))]
    [(ast.AstType.Struct name)
      (str_cat.str-cat
        "struct_"
        (ast.ast-nominal-name-id-display-with-intern-state
          (spec-owner-intern-state owner)
          name))]
    [(ast.AstType.StructArgs name lifetimes)
      (str_cat.str-cat
        "structargs_"
        (ast.ast-nominal-name-id-display-with-intern-state
          (spec-owner-intern-state owner)
          name)
        "_"
        (spec-lifetime-list-key-with-owner owner (box-get lifetimes)))]
    [(ast.AstType.Var name)
      (str_cat.str-cat
        "var_"
        (spec_ci.intern-compat-state-str (spec-owner-intern-state owner) name))]
    [(ast.AstType.VarArgs name lifetimes)
      (str_cat.str-cat
        "varargs_"
        (spec_ci.intern-compat-state-str (spec-owner-intern-state owner) name)
        "_"
        (spec-lifetime-list-key-with-owner owner (box-get lifetimes)))]
    [(ast.AstType.Consume inner)
      (str_cat.str-cat
        "consume_"
        (spec-type-key-with-owner owner (spec-owner-type-get owner inner)))]))

(define (spec-value-key [value : ctfe.CompilerCtfeValue]) : String
  (match value
    [(ctfe.CompilerCtfeValue.I64 n) (str_cat.str-cat "i64_" (spec-int-key n))]
    [(ctfe.CompilerCtfeValue.F64 n)
      (str_cat.str-cat
        "f64_"
        (spec-string-key (cfloat.compiler-float-format-f64 n)))]
    [(ctfe.CompilerCtfeValue.F32 n)
      (str_cat.str-cat
        "f32_"
        (spec-string-key
          (cfloat.compiler-float-format-f64
            (cfloat.compiler-float-round-f32-as-f64 n))))]
    [(ctfe.CompilerCtfeValue.Bool b)
      (if b
        "bool_1"
        "bool_0")]
    [(ctfe.CompilerCtfeValue.Char c)
      (str_cat.str-cat "char_" (string.int->string (cast c : i64)))]
    [(ctfe.CompilerCtfeValue.String text _) (spec-string-key text)]
    [(ctfe.CompilerCtfeValue.Name text _) (spec-string-key text)]
    [(ctfe.CompilerCtfeValue.Unit) "unit"]
    [(ctfe.CompilerCtfeValue.Type ty)
      (str_cat.str-cat "type_" (spec-type-key ty))]
    [(ctfe.CompilerCtfeValue.Expr _ _) "Expr"]
    [(ctfe.CompilerCtfeValue.CapturedExpr _ _ _) "Expr"]
    [(ctfe.CompilerCtfeValue.ExprList _) "expr-list"]
    [(ctfe.CompilerCtfeValue.CapturedExprList _ _) "expr-list"]
    [(ctfe.CompilerCtfeValue.ExprClause _) "expr-clause"]
    [(ctfe.CompilerCtfeValue.CapturedExprClause _ _) "expr-clause"]
    [(ctfe.CompilerCtfeValue.ExprClauseList _) "expr-clause-list"]
    [(ctfe.CompilerCtfeValue.CapturedExprClauseList _ _) "expr-clause-list"]
    [(ctfe.CompilerCtfeValue.ExprBindingClause _) "expr-binding-clause"]
    [(ctfe.CompilerCtfeValue.ExprBindingClauseList _)
      "expr-binding-clause-list"]
    [(ctfe.CompilerCtfeValue.Pattern _) "pattern"]
    [(ctfe.CompilerCtfeValue.PatternList _) "pattern-list"]
    [(ctfe.CompilerCtfeValue.MatchArm _) "match-arm"]
    [(ctfe.CompilerCtfeValue.MatchArmList _) "match-arm-list"]
    [(ctfe.CompilerCtfeValue.LetBinding _) "let-binding"]
    [(ctfe.CompilerCtfeValue.LetBindingList _) "let-binding-list"]
    [(ctfe.CompilerCtfeValue.TypeInfo ty)
      (str_cat.str-cat "typeinfo_" (spec-type-key ty))]
    [(ctfe.CompilerCtfeValue.TypeInfoBox ty)
      (str_cat.str-cat "typeinfo-box_" (spec-type-key ty))]
    [(ctfe.CompilerCtfeValue.TypeInfoList _) "typeinfo-list"]
    [(ctfe.CompilerCtfeValue.TypeField _ _) "type-field"]
    [(ctfe.CompilerCtfeValue.TypeFieldList _) "type-field-list"]
    [(ctfe.CompilerCtfeValue.TypeVariantPayload _) "type-variant-payload"]
    [(ctfe.CompilerCtfeValue.TypeVariantPayloadList _)
      "type-variant-payload-list"]
    [(ctfe.CompilerCtfeValue.TypeVariant _ _) "type-variant"]
    [(ctfe.CompilerCtfeValue.TypeVariantList _) "type-variant-list"]))

(define (spec-values-key [values : SpecValueList]) : String
  (spec-values-key-at values 0))

(define (spec-values-key-at [values : SpecValueList] [at : i64]) : String
  (if (>= at (struct-get values len))
    "none"
    (str_cat.str-cat
      (spec-value-key (array.ref (struct-get values slots) at))
      "_"
      (spec-values-key-at values (+ at 1)))))

(define (spec-specialization-key [name : String] [values : SpecValueList]) : String
  (str_cat.str-cat name ":" (spec-values-key values)))

(define (spec-specialized-name [name : String] [values : SpecValueList]) : String
  (str_cat.str-cat "__tl_specialized_" name "_" (spec-values-key values)))

(define (spec-value-key-with-owner
  [owner : SpecOwnerContext]
  [value : ctfe.CompilerCtfeValue]) : String
  (match value
    [(ctfe.CompilerCtfeValue.I64 n) (str_cat.str-cat "i64_" (spec-int-key n))]
    [(ctfe.CompilerCtfeValue.F64 n)
      (str_cat.str-cat
        "f64_"
        (spec-string-key (cfloat.compiler-float-format-f64 n)))]
    [(ctfe.CompilerCtfeValue.F32 n)
      (str_cat.str-cat
        "f32_"
        (spec-string-key
          (cfloat.compiler-float-format-f64
            (cfloat.compiler-float-round-f32-as-f64 n))))]
    [(ctfe.CompilerCtfeValue.Bool b)
      (if b
        "bool_1"
        "bool_0")]
    [(ctfe.CompilerCtfeValue.Char c)
      (str_cat.str-cat "char_" (string.int->string (cast c : i64)))]
    [(ctfe.CompilerCtfeValue.String text _) (spec-string-key text)]
    [(ctfe.CompilerCtfeValue.Name text _) (spec-string-key text)]
    [(ctfe.CompilerCtfeValue.Unit) "unit"]
    [(ctfe.CompilerCtfeValue.Type ty)
      (str_cat.str-cat "type_" (spec-type-key-with-owner owner ty))]
    [(ctfe.CompilerCtfeValue.Expr _ _) "Expr"]
    [(ctfe.CompilerCtfeValue.CapturedExpr _ _ _) "Expr"]
    [(ctfe.CompilerCtfeValue.ExprList _) "expr-list"]
    [(ctfe.CompilerCtfeValue.CapturedExprList _ _) "expr-list"]
    [(ctfe.CompilerCtfeValue.ExprClause _) "expr-clause"]
    [(ctfe.CompilerCtfeValue.CapturedExprClause _ _) "expr-clause"]
    [(ctfe.CompilerCtfeValue.ExprClauseList _) "expr-clause-list"]
    [(ctfe.CompilerCtfeValue.CapturedExprClauseList _ _) "expr-clause-list"]
    [(ctfe.CompilerCtfeValue.ExprBindingClause _) "expr-binding-clause"]
    [(ctfe.CompilerCtfeValue.ExprBindingClauseList _)
      "expr-binding-clause-list"]
    [(ctfe.CompilerCtfeValue.Pattern _) "pattern"]
    [(ctfe.CompilerCtfeValue.PatternList _) "pattern-list"]
    [(ctfe.CompilerCtfeValue.MatchArm _) "match-arm"]
    [(ctfe.CompilerCtfeValue.MatchArmList _) "match-arm-list"]
    [(ctfe.CompilerCtfeValue.LetBinding _) "let-binding"]
    [(ctfe.CompilerCtfeValue.LetBindingList _) "let-binding-list"]
    [(ctfe.CompilerCtfeValue.TypeInfo ty)
      (str_cat.str-cat "typeinfo_" (spec-type-key-with-owner owner ty))]
    [(ctfe.CompilerCtfeValue.TypeInfoBox ty)
      (str_cat.str-cat "typeinfo-box_" (spec-type-key-with-owner owner ty))]
    [(ctfe.CompilerCtfeValue.TypeInfoList _) "typeinfo-list"]
    [(ctfe.CompilerCtfeValue.TypeField _ _) "type-field"]
    [(ctfe.CompilerCtfeValue.TypeFieldList _) "type-field-list"]
    [(ctfe.CompilerCtfeValue.TypeVariantPayload _) "type-variant-payload"]
    [(ctfe.CompilerCtfeValue.TypeVariantPayloadList _)
      "type-variant-payload-list"]
    [(ctfe.CompilerCtfeValue.TypeVariant _ _) "type-variant"]
    [(ctfe.CompilerCtfeValue.TypeVariantList _) "type-variant-list"]))

(define (spec-values-key-with-owner-at
  [owner : SpecOwnerContext]
  [values : SpecValueList]
  [at : i64]) : String
  (if (>= at (struct-get values len))
    "none"
    (str_cat.str-cat
      (spec-value-key-with-owner owner (array.ref (struct-get values slots) at))
      "_"
      (spec-values-key-with-owner-at owner values (+ at 1)))))

(define (spec-values-key-with-owner
  [owner : SpecOwnerContext]
  [values : SpecValueList]) : String
  (spec-values-key-with-owner-at owner values 0))

(define (spec-specialized-name-with-owner
  [owner : SpecOwnerContext]
  [name : String]
  [values : SpecValueList]) : String
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
  [owner : SpecOwnerContext]
  [tag : i64]
  [left : i64]
  [right : i64]) : SpecStructuralKey
  (let
    [intern-state : spec_ci.InternCompatState (spec-owner-intern-state owner)]
    [before : i64 (spec_ci.intern-compat-state-structural-count intern-state)]
    [raw : i64
      (spec_ci.intern-compat-state-composite-triple-id
        intern-state
        tag
        left
        right)]
    (begin
      (spec-profile-note-structural-key
        (> (spec_ci.intern-compat-state-structural-count intern-state) before))
      (SpecStructuralKey raw))))

(define (spec-structural-content-atom-with-owner
  [owner : SpecOwnerContext]
  [text : String]) : i64
  ;; The enclosing structural tag defines the value domain. Canonicalizing the
  ;; bytes here deliberately ignores parser/generated provenance, matching the
  ;; old rendered-key equivalence without using a mangled String as identity.
  (spec_ci.intern-compat-state-intern (spec-owner-intern-state owner) text))

(define (spec-structural-generated-text-atom-with-owner
  [owner : SpecOwnerContext]
  [text : String]) : i64
  (let
    [intern-state : spec_ci.InternCompatState (spec-owner-intern-state owner)]
    (begin
      (match (spec_ci.intern-compat-state-lookup intern-state text)
        [(spec_ci.InternLookupFound _) unit]
        [(spec_ci.InternLookupMissing)
          (spec-profile-note-generated-text-materialized)])
      (spec_ci.intern-compat-state-intern intern-state text))))

(define (spec-type-list-structural-key-at-with-owner
  [owner : SpecOwnerContext]
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
  [owner : SpecOwnerContext]
  [types : ast.AstTypeList]) : SpecStructuralKey
  (spec-type-list-structural-key-at-with-owner owner (& types) 0))

(define (spec-lifetime-list-structural-key-at-with-owner
  [owner : SpecOwnerContext]
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
  [owner : SpecOwnerContext]
  [lifetimes : ast.AstLifetimeList]) : SpecStructuralKey
  (spec-lifetime-list-structural-key-at-with-owner owner (& lifetimes) 0))

(define (spec-type-structural-key-with-owner
  [owner : SpecOwnerContext]
  [ty : ast.AstType]) : SpecStructuralKey
  (match ty
    [(ast.AstType.I64) (spec-structural-node-with-owner owner -100 0 0)]
    [(ast.AstType.I32) (spec-structural-node-with-owner owner -101 0 0)]
    [(ast.AstType.I16) (spec-structural-node-with-owner owner -102 0 0)]
    [(ast.AstType.I8) (spec-structural-node-with-owner owner -103 0 0)]
    [(ast.AstType.U64) (spec-structural-node-with-owner owner -104 0 0)]
    [(ast.AstType.U32) (spec-structural-node-with-owner owner -105 0 0)]
    [(ast.AstType.U16) (spec-structural-node-with-owner owner -106 0 0)]
    [(ast.AstType.U8) (spec-structural-node-with-owner owner -107 0 0)]
    [(ast.AstType.F64) (spec-structural-node-with-owner owner -108 0 0)]
    [(ast.AstType.F32) (spec-structural-node-with-owner owner -109 0 0)]
    [(ast.AstType.Bool) (spec-structural-node-with-owner owner -110 0 0)]
    [(ast.AstType.Char) (spec-structural-node-with-owner owner -111 0 0)]
    [(ast.AstType.String) (spec-structural-node-with-owner owner -112 0 0)]
    [(ast.AstType.Str) (spec-structural-node-with-owner owner -113 0 0)]
    [(ast.AstType.Bytes) (spec-structural-node-with-owner owner -114 0 0)]
    [(ast.AstType.Unit) (spec-structural-node-with-owner owner -115 0 0)]
    [(ast.AstType.Never) (spec-structural-node-with-owner owner -116 0 0)]
    [(ast.AstType.Expr) (spec-structural-node-with-owner owner -117 0 0)]
    [(ast.AstType.ExprList) (spec-structural-node-with-owner owner -118 0 0)]
    [(ast.AstType.Func args ret)
      (let
        [arg-key : SpecStructuralKey
          (spec-type-list-structural-key-with-owner owner (box-get args))]
        [ret-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner ret))]
        (spec-structural-node-with-owner
          owner
          -119
          (spec-structural-key-raw arg-key)
          (spec-structural-key-raw ret-key)))]
    [(ast.AstType.Tuple elems)
      (let
        [elem-key : SpecStructuralKey
          (spec-type-list-structural-key-with-owner owner (box-get elems))]
        (spec-structural-node-with-owner
          owner
          -120
          (spec-structural-key-raw elem-key)
          0))]
    [(ast.AstType.Array elem count)
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
    [(ast.AstType.DynArray elem)
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
    [(ast.AstType.Slice elem)
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
    [(ast.AstType.Box elem)
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
    [(ast.AstType.Ptr elem)
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
    [(ast.AstType.MutPtr elem)
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
    [(ast.AstType.Ref region inner)
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
    [(ast.AstType.MutRef region inner)
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
    [(ast.AstType.Region region inner)
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
    [(ast.AstType.Enum name)
      (spec-structural-node-with-owner
        owner
        -130
        (spec-structural-content-atom-with-owner
          owner
          (ast.ast-nominal-name-id-display-with-intern-state
            (spec-owner-intern-state owner)
            name))
        0)]
    [(ast.AstType.EnumArgs name lifetimes)
      (let
        [lifetime-key : SpecStructuralKey
          (spec-lifetime-list-structural-key-with-owner
            owner
            (box-get lifetimes))]
        (spec-structural-node-with-owner
          owner
          -131
          (spec-structural-content-atom-with-owner
            owner
            (ast.ast-nominal-name-id-display-with-intern-state
              (spec-owner-intern-state owner)
              name))
          (spec-structural-key-raw lifetime-key)))]
    [(ast.AstType.Struct name)
      (spec-structural-node-with-owner
        owner
        -132
        (spec-structural-content-atom-with-owner
          owner
          (ast.ast-nominal-name-id-display-with-intern-state
            (spec-owner-intern-state owner)
            name))
        0)]
    [(ast.AstType.StructArgs name lifetimes)
      (let
        [lifetime-key : SpecStructuralKey
          (spec-lifetime-list-structural-key-with-owner
            owner
            (box-get lifetimes))]
        (spec-structural-node-with-owner
          owner
          -133
          (spec-structural-content-atom-with-owner
            owner
            (ast.ast-nominal-name-id-display-with-intern-state
              (spec-owner-intern-state owner)
              name))
          (spec-structural-key-raw lifetime-key)))]
    [(ast.AstType.Var name)
      (spec-structural-node-with-owner
        owner
        -134
        (spec-structural-content-atom-with-owner
          owner
          (spec_ci.intern-compat-state-str (spec-owner-intern-state owner) name))
        0)]
    [(ast.AstType.VarArgs name lifetimes)
      (let
        [lifetime-key : SpecStructuralKey
          (spec-lifetime-list-structural-key-with-owner
            owner
            (box-get lifetimes))]
        (spec-structural-node-with-owner
          owner
          -135
          (spec-structural-content-atom-with-owner
            owner
            (spec_ci.intern-compat-state-str
              (spec-owner-intern-state owner)
              name))
          (spec-structural-key-raw lifetime-key)))]
    [(ast.AstType.Consume inner)
      (let
        [inner-key : SpecStructuralKey
          (spec-type-structural-key-with-owner
            owner
            (spec-owner-type-get owner inner))]
        (spec-structural-node-with-owner
          owner
          -136
          (spec-structural-key-raw inner-key)
          0))]))

(define (spec-value-structural-key-with-owner
  [owner : SpecOwnerContext]
  [value : ctfe.CompilerCtfeValue]) : SpecStructuralKey
  (match value
    [(ctfe.CompilerCtfeValue.I64 n)
      (spec-structural-node-with-owner owner -200 n 0)]
    [(ctfe.CompilerCtfeValue.F64 n)
      (spec-structural-node-with-owner
        owner
        -201
        (spec-structural-content-atom-with-owner
          owner
          (cfloat.compiler-float-format-f64 n))
        0)]
    [(ctfe.CompilerCtfeValue.F32 n)
      (spec-structural-node-with-owner
        owner
        -202
        (spec-structural-content-atom-with-owner
          owner
          (cfloat.compiler-float-format-f64
            (cfloat.compiler-float-round-f32-as-f64 n)))
        0)]
    [(ctfe.CompilerCtfeValue.Bool b)
      (spec-structural-node-with-owner
        owner
        -203
        (if b
          1
          0)
        0)]
    [(ctfe.CompilerCtfeValue.Char c)
      (spec-structural-node-with-owner owner -204 (cast c : i64) 0)]
    [(ctfe.CompilerCtfeValue.String text _)
      (spec-structural-node-with-owner
        owner
        -205
        (spec-structural-generated-text-atom-with-owner owner text)
        0)]
    [(ctfe.CompilerCtfeValue.Name text _)
      ;; String and Name intentionally share the old content equivalence.
      (spec-structural-node-with-owner
        owner
        -205
        (spec-structural-generated-text-atom-with-owner owner text)
        0)]
    [(ctfe.CompilerCtfeValue.Unit)
      (spec-structural-node-with-owner owner -206 0 0)]
    [(ctfe.CompilerCtfeValue.Type ty)
      (let
        [type-key : SpecStructuralKey
          (spec-type-structural-key-with-owner owner ty)]
        (spec-structural-node-with-owner
          owner
          -207
          (spec-structural-key-raw type-key)
          0))]
    [(ctfe.CompilerCtfeValue.Expr _ _)
      (spec-structural-node-with-owner owner -208 0 0)]
    [(ctfe.CompilerCtfeValue.CapturedExpr _ _ _)
      (spec-structural-node-with-owner owner -208 0 0)]
    [(ctfe.CompilerCtfeValue.ExprList _)
      (spec-structural-node-with-owner owner -209 0 0)]
    [(ctfe.CompilerCtfeValue.CapturedExprList _ _)
      (spec-structural-node-with-owner owner -209 0 0)]
    [(ctfe.CompilerCtfeValue.ExprClause _)
      (spec-structural-node-with-owner owner -210 0 0)]
    [(ctfe.CompilerCtfeValue.CapturedExprClause _ _)
      (spec-structural-node-with-owner owner -210 0 0)]
    [(ctfe.CompilerCtfeValue.ExprClauseList _)
      (spec-structural-node-with-owner owner -211 0 0)]
    [(ctfe.CompilerCtfeValue.CapturedExprClauseList _ _)
      (spec-structural-node-with-owner owner -211 0 0)]
    [(ctfe.CompilerCtfeValue.ExprBindingClause _)
      (spec-structural-node-with-owner owner -212 0 0)]
    [(ctfe.CompilerCtfeValue.ExprBindingClauseList _)
      (spec-structural-node-with-owner owner -213 0 0)]
    [(ctfe.CompilerCtfeValue.Pattern _)
      (spec-structural-node-with-owner owner -214 0 0)]
    [(ctfe.CompilerCtfeValue.PatternList _)
      (spec-structural-node-with-owner owner -215 0 0)]
    [(ctfe.CompilerCtfeValue.MatchArm _)
      (spec-structural-node-with-owner owner -216 0 0)]
    [(ctfe.CompilerCtfeValue.MatchArmList _)
      (spec-structural-node-with-owner owner -217 0 0)]
    [(ctfe.CompilerCtfeValue.LetBinding _)
      (spec-structural-node-with-owner owner -218 0 0)]
    [(ctfe.CompilerCtfeValue.LetBindingList _)
      (spec-structural-node-with-owner owner -219 0 0)]
    [(ctfe.CompilerCtfeValue.TypeInfo ty)
      (let
        [type-key : SpecStructuralKey
          (spec-type-structural-key-with-owner owner ty)]
        (spec-structural-node-with-owner
          owner
          -220
          (spec-structural-key-raw type-key)
          0))]
    [(ctfe.CompilerCtfeValue.TypeInfoBox ty)
      (let
        [type-key : SpecStructuralKey
          (spec-type-structural-key-with-owner owner ty)]
        (spec-structural-node-with-owner
          owner
          -221
          (spec-structural-key-raw type-key)
          0))]
    [(ctfe.CompilerCtfeValue.TypeInfoList _)
      (spec-structural-node-with-owner owner -222 0 0)]
    [(ctfe.CompilerCtfeValue.TypeField _ _)
      (spec-structural-node-with-owner owner -223 0 0)]
    [(ctfe.CompilerCtfeValue.TypeFieldList _)
      (spec-structural-node-with-owner owner -224 0 0)]
    [(ctfe.CompilerCtfeValue.TypeVariantPayload _)
      (spec-structural-node-with-owner owner -225 0 0)]
    [(ctfe.CompilerCtfeValue.TypeVariantPayloadList _)
      (spec-structural-node-with-owner owner -226 0 0)]
    [(ctfe.CompilerCtfeValue.TypeVariant _ _)
      (spec-structural-node-with-owner owner -227 0 0)]
    [(ctfe.CompilerCtfeValue.TypeVariantList _)
      (spec-structural-node-with-owner owner -228 0 0)]))

(define (spec-values-structural-key-at-with-owner
  [owner : SpecOwnerContext]
  [values : SpecValueList]
  [index : i64]) : SpecStructuralKey
  (if (>= index (struct-get values len))
    (SpecStructuralKey 0)
    (let
      [head : SpecStructuralKey
        (spec-value-structural-key-with-owner
          owner
          (array.ref (struct-get values slots) index))]
      [tail : SpecStructuralKey
        (spec-values-structural-key-at-with-owner owner values (+ index 1))]
      (spec-structural-node-with-owner
        owner
        -3
        (spec-structural-key-raw head)
        (spec-structural-key-raw tail)))))

(define (spec-values-structural-key-with-owner
  [owner : SpecOwnerContext]
  [values : SpecValueList]) : SpecStructuralKey
  (spec-values-structural-key-at-with-owner owner values 0))

(define (spec-specialization-structural-key-with-owner
  [owner : SpecOwnerContext]
  [template-name : String]
  [values : SpecValueList]) : SpecStructuralKey
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
  [owner : SpecOwnerContext]
  [key : SpecStructuralKey]
  [template-name : String]
  [values : SpecValueList]) : String
  (let
    [raw : i64 (spec-structural-key-raw key)]
    [cached : String
      (spec_ci.intern-compat-state-composite-rendered-name
        (spec-owner-intern-state owner)
        raw)]
    (if (> (string.string-length cached) 0)
      (begin
        (spec-profile-note-name-render true)
        cached)
      (let
        [rendered : String
          (spec-specialized-name-with-owner owner template-name values)]
        (begin
          (spec-profile-note-name-render false)
          (spec_ci.intern-compat-state-composite-rendered-name-record!
            (spec-owner-intern-state owner)
            raw
            rendered))))))

(define (spec-reserve-specialized-symbol-with-owner
  [owner : SpecOwnerContext]
  [key : SpecStructuralKey]
  [template-name : String]
  [values : SpecValueList]) : i64
  (let
    [handle : i64
      (spec_ci.intern-compat-state-generated-symbol-handle
        (spec-owner-intern-state owner))]
    [records : (__tl_dyn-array SpecGeneratedSymbolRecords)
      (struct-get owner generated-symbol-records)]
    [record-list : SpecGeneratedSymbolRecords (array-ref records 0)]
    (begin
      (spec-generated-symbol-records-push!
        (&mut record-list)
        (SpecGeneratedSymbolRecord
          (spec-structural-key-raw key)
          handle
          template-name
          values))
      (array-set! records 0 record-list)
      handle)))

(define (spec-materialize-generated-symbol-records-with-owner!
  [owner : SpecOwnerContext]
  [records : SpecGeneratedSymbolRecords]) : unit
  (let
    [index : i64 0]
    (while (< index (struct-get records len))
      (let
        [record : SpecGeneratedSymbolRecord
          (array.ref (struct-get records slots) index)]
        (begin
          (spec_ci.intern-compat-state-generated-symbol-materialize!
            (spec-owner-intern-state owner)
            (struct-get record handle)
            (spec-render-specialized-name-with-owner
              owner
              (SpecStructuralKey (struct-get record structural-key))
              (struct-get record template-name)
              (struct-get record values)))
          (set! index (+ index 1)))))))

(define (spec-materialize-owner-generated-symbols! [owner : SpecOwnerContext]) : unit
  (let
    [records : (__tl_dyn-array SpecGeneratedSymbolRecords)
      (struct-get owner generated-symbol-records)]
    [record-list : SpecGeneratedSymbolRecords (array-ref records 0)]
    (begin
      (spec-materialize-generated-symbol-records-with-owner! owner record-list)
      (set! (struct-get record-list len) 0)
      (array-set! records 0 record-list))))

(define (gen-registry-empty) : GenRegistry
  (let
    [capacity : i64 64]
    [decls : (__tl_dyn-array ast.AstDecl)
      (array.make-array ast.AstDecl capacity)]
    (GenRegistry (spec_id_i64_map.with-capacity capacity) decls 0)))

(define (gen-registry-structural-key-with-owner
  [owner : SpecOwnerContext]
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
  [registry : GenRegistry]
  [key : SpecStructuralKey]) : GenMaybeEntry
  (match (spec_id_i64_map.get
    (& (struct-get registry index))
    (spec-structural-key-raw key))
    [(spec_id_i64_map.LookupFound slot)
      (GenMaybeEntry.Some (array.ref (struct-get registry decls) slot))]
    [(spec_id_i64_map.LookupMissing) (GenMaybeEntry.None)]))

(define (gen-registry-copy-decls
  [src : (__tl_dyn-array ast.AstDecl)]
  [dst : (__tl_dyn-array ast.AstDecl)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array.ref src index))
      (gen-registry-copy-decls src dst (+ index 1) count))))

(define (gen-registry-grow [registry : GenRegistry]) : GenRegistry
  (let
    [old-index : spec_id_i64_map.Map (struct-get registry index)]
    [old-decls : (__tl_dyn-array ast.AstDecl) (struct-get registry decls)]
    [old-len : i64 (struct-get registry len)]
    [old-capacity : i64 (array.length old-decls)]
    [new-capacity : i64
      (if (< old-capacity 1)
        1
        (* old-capacity 2))]
    [new-decls : (__tl_dyn-array ast.AstDecl)
      (array.make-array ast.AstDecl new-capacity)]
    (begin
      (gen-registry-copy-decls old-decls new-decls 0 old-len)
      (GenRegistry old-index new-decls old-len))))

(define (gen-registry-insert-with-owner
  [registry : GenRegistry]
  [key : SpecStructuralKey]
  [decl : ast.AstDecl]) : GenRegistry
  (let
    [ready : GenRegistry
      (if (>=
        (struct-get registry len)
        (array.length (struct-get registry decls)))
        (gen-registry-grow registry)
        registry)]
    [slot : i64 (struct-get ready len)]
    [decls : (__tl_dyn-array ast.AstDecl) (struct-get ready decls)]
    [index : spec_id_i64_map.Map (struct-get ready index)]
    (begin
      (array-set! decls slot decl)
      (spec_id_i64_map.insert-ref!
        (&mut index)
        (spec-structural-key-raw key)
        slot)
      (GenRegistry index decls (+ slot 1)))))

(define (gen-decl-visible-name-id [decl : ast.AstDecl]) : SpecMaybeId
  (match decl
    [(ast.AstDecl.Def decl-meta name _ _) (SpecMaybeId.Some name)]
    [(ast.AstDecl.DefFn decl-meta name _ _ _ _) (SpecMaybeId.Some name)]
    [(ast.AstDecl.Extern decl-meta name _ _ _) (SpecMaybeId.Some name)]
    [(ast.AstDecl.DefDispatch decl-meta name _) (SpecMaybeId.Some name)]
    [(ast.AstDecl.DefEnum decl-meta name _ _) (SpecMaybeId.Some name)]
    [(ast.AstDecl.DefEnumLifetimes decl-meta name _ _ _)
      (SpecMaybeId.Some name)]
    [(ast.AstDecl.DefStruct decl-meta name _ _ _) (SpecMaybeId.Some name)]
    [(ast.AstDecl.DefStructLifetimes decl-meta name _ _ _ _)
      (SpecMaybeId.Some name)]
    [(ast.AstDecl.DefMacro decl-meta name _ _ _) (SpecMaybeId.Some name)]
    [(ast.AstDecl.Unsafe inner-box)
      (gen-decl-visible-name-id (box-get inner-box))]
    [_ (SpecMaybeId.None)]))

(define (gen-decl-visible-name [decl : ast.AstDecl]) : SpecMaybeString
  (match (gen-decl-visible-name-id decl)
    [(SpecMaybeId.Some name-id)
      (SpecMaybeString.Some (spec_ci.intern-str name-id))]
    [(SpecMaybeId.None) (SpecMaybeString.None)]))

(define (gen-maybe-type-eq? [a : ast.AstMaybeType] [b : ast.AstMaybeType]) : bool
  (match a
    [(ast.AstMaybeType.No)
      (match b
        [(ast.AstMaybeType.No) true]
        [_ false])]
    [(ast.AstMaybeType.Some a-ty)
      (match b
        [(ast.AstMaybeType.Some b-ty) (ctfe.ctfe-type-eq a-ty b-ty)]
        [_ false])]))

(define (gen-expr-eq? [a : ast.AstExpr] [b : ast.AstExpr]) : bool
  (ctfe.ctfe-expr-eq (ast.ast-expr-unspan a) (ast.ast-expr-unspan b)))

(define (gen-param-eq? [a : ast.AstParam] [b : ast.AstParam]) : bool
  (match a
    [(ast.AstParam.Param a-name a-ty a-comptime a-consume)
      (match b
        [(ast.AstParam.Param b-name b-ty b-comptime b-consume)
          (and
            (= a-name b-name)
            (= a-consume b-consume)
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
    [(ast.AstMacroParam.Param a-name a-ty a-variadic a-type-kinds)
      (match b
        [(ast.AstMacroParam.Param b-name b-ty b-variadic b-type-kinds)
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
    [(ast.AstFieldCleanup.No)
      (match b
        [(ast.AstFieldCleanup.No) true]
        [_ false])]
    [(ast.AstFieldCleanup.Fn a-name)
      (match b
        [(ast.AstFieldCleanup.Fn b-name) (= a-name b-name)]
        [_ false])]
    [(ast.AstFieldCleanup.Owned)
      (match b
        [(ast.AstFieldCleanup.Owned) true]
        [_ false])]))

(define (gen-field-def-eq? [a : ast.AstFieldDef] [b : ast.AstFieldDef]) : bool
  (match a
    [(ast.AstFieldDef.Def a-name a-ty a-cleanup)
      (match b
        [(ast.AstFieldDef.Def b-name b-ty b-cleanup)
          (and
            (= a-name b-name)
            (ctfe.ctfe-type-eq a-ty b-ty)
            (gen-field-cleanup-eq? a-cleanup b-cleanup))])]))

(define (gen-field-list-eq? [a : ast.AstFieldDefList] [b : ast.AstFieldDefList]) : bool
  (if (= (struct-get (& a) len) (struct-get (& b) len))
    (gen-field-list-eq-at (& a) (& b) 0)
    false))

(define (gen-field-list-eq-at
  [a : (& a ast.AstFieldDefList)]
  [b : (& b ast.AstFieldDefList)]
  [index : i64]) : bool
  (if (>= index (struct-get a len))
    true
    (and
      (gen-field-def-eq?
        (ast.ast-field-def-list-get a index (ast.ast-field-def-fallback))
        (ast.ast-field-def-list-get b index (ast.ast-field-def-fallback)))
      (gen-field-list-eq-at a b (+ index 1)))))

(define (gen-struct-repr-eq? [a : ast.AstStructRepr] [b : ast.AstStructRepr]) : bool
  (match a
    [(ast.AstStructRepr.Default)
      (match b
        [(ast.AstStructRepr.Default) true]
        [_ false])]
    [(ast.AstStructRepr.C)
      (match b
        [(ast.AstStructRepr.C) true]
        [_ false])]))

(define (gen-struct-cleanup-eq?
  [a : ast.AstStructCleanup]
  [b : ast.AstStructCleanup]) : bool
  (match a
    [(ast.AstStructCleanup.No)
      (match b
        [(ast.AstStructCleanup.No) true]
        [_ false])]
    [(ast.AstStructCleanup.Fn a-name)
      (match b
        [(ast.AstStructCleanup.Fn b-name) (= a-name b-name)]
        [_ false])]))

(define (gen-enum-cleanup-eq? [a : ast.AstEnumCleanup] [b : ast.AstEnumCleanup]) : bool
  (match a
    [(ast.AstEnumCleanup.No)
      (match b
        [(ast.AstEnumCleanup.No) true]
        [_ false])]
    [(ast.AstEnumCleanup.Fn a-name)
      (match b
        [(ast.AstEnumCleanup.Fn b-name) (= a-name b-name)]
        [_ false])]))

(define (gen-variant-payload-cleanup-eq?
  [a : ast.AstVariantPayloadCleanup]
  [b : ast.AstVariantPayloadCleanup]) : bool
  (match a
    [(ast.AstVariantPayloadCleanup.No)
      (match b
        [(ast.AstVariantPayloadCleanup.No) true]
        [_ false])]
    [(ast.AstVariantPayloadCleanup.Fn a-name)
      (match b
        [(ast.AstVariantPayloadCleanup.Fn b-name) (= a-name b-name)]
        [_ false])]
    [(ast.AstVariantPayloadCleanup.Owned)
      (match b
        [(ast.AstVariantPayloadCleanup.Owned) true]
        [_ false])]))

(define (gen-variant-payload-cleanup-list-eq?
  [a : ast.AstVariantPayloadCleanupList]
  [b : ast.AstVariantPayloadCleanupList]) : bool
  (if (= (struct-get (& a) len) (struct-get (& b) len))
    (gen-variant-payload-cleanup-list-eq-at? (& a) (& b) 0)
    false))

(define (gen-variant-payload-cleanup-list-eq-at?
  [a : (& a ast.AstVariantPayloadCleanupList)]
  [b : (& b ast.AstVariantPayloadCleanupList)]
  [index : i64]) : bool
  (if (>= index (struct-get a len))
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
    [(ast.AstVariantDef.Def a-name a-payloads a-cleanups)
      (match b
        [(ast.AstVariantDef.Def b-name b-payloads b-cleanups)
          (and
            (= a-name b-name)
            (ctfe.ctfe-type-list-eq a-payloads b-payloads)
            (gen-variant-payload-cleanup-list-eq? a-cleanups b-cleanups))])]))

(define (gen-variant-list-eq?
  [a : ast.AstVariantDefList]
  [b : ast.AstVariantDefList]) : bool
  (if (= (struct-get (& a) len) (struct-get (& b) len))
    (gen-variant-list-eq-at? (& a) (& b) 0)
    false))

(define (gen-variant-list-eq-at?
  [a : (& a ast.AstVariantDefList)]
  [b : (& b ast.AstVariantDefList)]
  [index : i64]) : bool
  (if (>= index (struct-get a len))
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
    [(ast.AstSpmdParamClass.Uniform)
      (match b
        [(ast.AstSpmdParamClass.Uniform) true]
        [_ false])]
    [(ast.AstSpmdParamClass.Varying)
      (match b
        [(ast.AstSpmdParamClass.Varying) true]
        [_ false])]))

(define (gen-spmd-result-class-eq?
  [a : ast.AstSpmdResultClass]
  [b : ast.AstSpmdResultClass]) : bool
  (match a
    [(ast.AstSpmdResultClass.Unit)
      (match b
        [(ast.AstSpmdResultClass.Unit) true]
        [_ false])]
    [(ast.AstSpmdResultClass.Uniform)
      (match b
        [(ast.AstSpmdResultClass.Uniform) true]
        [_ false])]
    [(ast.AstSpmdResultClass.Varying)
      (match b
        [(ast.AstSpmdResultClass.Varying) true]
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
        (ast.ast-spmd-param-class-list-get
          a
          index
          ast.AstSpmdParamClass.Uniform)
        (ast.ast-spmd-param-class-list-get
          b
          index
          ast.AstSpmdParamClass.Uniform))
      (gen-spmd-param-class-list-eq-at? a b (+ index 1)))))

(define (gen-spmd-specialization-fallback) : ast.AstSpmdSpecialization
  (ast.AstSpmdSpecialization
    2
    (box (ast.ast-spmd-param-class-list-new))
    ast.AstSpmdResultClass.Unit
    -1))

(define (gen-spmd-specialization-eq?
  [a : ast.AstSpmdSpecialization]
  [b : ast.AstSpmdSpecialization]) : bool
  (and
    (= (struct-get a lanes) (struct-get b lanes))
    (gen-spmd-param-class-list-eq-at?
      (& (box-get (struct-get a args)))
      (& (box-get (struct-get b args)))
      0)
    (gen-spmd-result-class-eq? (struct-get a result) (struct-get b result))
    (= (struct-get a index-param) (struct-get b index-param))))

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
    [(ast.AstFnMetadata.No)
      (match b
        [(ast.AstFnMetadata.No) true]
        [_ false])]
    [(ast.AstFnMetadata.Export a-symbol)
      (match b
        [(ast.AstFnMetadata.Export b-symbol) (= a-symbol b-symbol)]
        [_ false])]
    [(ast.AstFnMetadata.SpmdCallable a-items)
      (match b
        [(ast.AstFnMetadata.SpmdCallable b-items)
          (gen-spmd-specialization-list-eq-at?
            (& (box-get a-items))
            (& (box-get b-items))
            0)]
        [_ false])]))

(define (gen-import-kind-eq? [a : ast.AstImportKind] [b : ast.AstImportKind]) : bool
  (match a
    [(ast.AstImportKind.Module)
      (match b
        [(ast.AstImportKind.Module) true]
        [_ false])]
    [(ast.AstImportKind.Macro _ _)
      (match b
        [(ast.AstImportKind.Macro _ _) true]
        [_ false])]
    [(ast.AstImportKind.MacroDecls _ _)
      (match b
        [(ast.AstImportKind.MacroDecls _ _) true]
        [_ false])]))

(define (gen-maybe-module-name-eq?
  [a : ast.AstMaybeModuleName]
  [b : ast.AstMaybeModuleName]) : bool
  (match a
    [(ast.AstMaybeModuleName.No)
      (match b
        [(ast.AstMaybeModuleName.No) true]
        [_ false])]
    [(ast.AstMaybeModuleName.Some a-name)
      (match b
        [(ast.AstMaybeModuleName.Some b-name) (= a-name b-name)]
        [_ false])]))

(define (gen-maybe-import-alias-eq?
  [a : ast.AstMaybeImportAlias]
  [b : ast.AstMaybeImportAlias]) : bool
  (match a
    [(ast.AstMaybeImportAlias.No)
      (match b
        [(ast.AstMaybeImportAlias.No) true]
        [_ false])]
    [(ast.AstMaybeImportAlias.Some a-name)
      (match b
        [(ast.AstMaybeImportAlias.Some b-name) (= a-name b-name)]
        [_ false])]))

(define (gen-import-spec-eq? [a : ast.AstImportSpec] [b : ast.AstImportSpec]) : bool
  (match a
    [(ast.AstImportSpec.Spec a-kind a-path a-module a-alias _)
      (match b
        [(ast.AstImportSpec.Spec b-kind b-path b-module b-alias _)
          (and
            (gen-import-kind-eq? a-kind b-kind)
            (string.eq a-path b-path)
            (gen-maybe-module-name-eq? a-module b-module)
            (gen-maybe-import-alias-eq? a-alias b-alias))])]))

(define (gen-decl-list-eq? [a : ast.AstDeclList] [b : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step a)
    [(ast.AstDeclListStep.Nil)
      (match (ast.ast-decl-list-step b)
        [(ast.AstDeclListStep.Nil) true]
        [_ false])]
    [(ast.AstDeclListStep.Cons a-head a-rest)
      (match (ast.ast-decl-list-step b)
        [(ast.AstDeclListStep.Cons b-head b-rest)
          (and (gen-decl-eq? a-head b-head) (gen-decl-list-eq? a-rest b-rest))]
        [_ false])]))

(define (gen-decl-eq? [a : ast.AstDecl] [b : ast.AstDecl]) : bool
  (match a
    [(ast.AstDecl.Def decl-meta a-name a-ty a-value-box)
      (let
        [a-value : ast.AstExpr (ast.ast-node-get a-value-box)]
        (match b
          [(ast.AstDecl.Def decl-meta b-name b-ty b-value-box)
            (let
              [b-value : ast.AstExpr (ast.ast-node-get b-value-box)]
              (and
                (= a-name b-name)
                (gen-maybe-type-eq? a-ty b-ty)
                (gen-expr-eq? a-value b-value)))]
          [_ false]))]
    [(ast.AstDecl.DefFn decl-meta a-name a-params a-ret a-body-box a-metadata)
      (let
        [a-body : ast.AstExpr (ast.ast-node-get a-body-box)]
        (match b
          [(ast.AstDecl.DefFn
              decl-meta
              b-name
              b-params
              b-ret
              b-body-box
              b-metadata)
            (let
              [b-body : ast.AstExpr (ast.ast-node-get b-body-box)]
              (and
                (= a-name b-name)
                (gen-param-list-eq? a-params b-params)
                (ctfe.ctfe-type-eq a-ret b-ret)
                (gen-expr-eq? a-body b-body)
                (gen-fn-metadata-eq? a-metadata b-metadata)))]
          [_ false]))]
    [(ast.AstDecl.DefEnum decl-meta a-name a-cleanup a-variants)
      (match b
        [(ast.AstDecl.DefEnum decl-meta b-name b-cleanup b-variants)
          (and
            (= a-name b-name)
            (gen-enum-cleanup-eq? a-cleanup b-cleanup)
            (gen-variant-list-eq? a-variants b-variants))]
        [_ false])]
    [(ast.AstDecl.DefEnumLifetimes
        decl-meta
        a-name
        a-lifetimes
        a-cleanup
        a-variants)
      (match b
        [(ast.AstDecl.DefEnumLifetimes
            decl-meta
            b-name
            b-lifetimes
            b-cleanup
            b-variants)
          (and
            (= a-name b-name)
            (ctfe.ctfe-lifetime-list-eq a-lifetimes b-lifetimes)
            (gen-enum-cleanup-eq? a-cleanup b-cleanup)
            (gen-variant-list-eq? a-variants b-variants))]
        [_ false])]
    [(ast.AstDecl.DefStruct decl-meta a-name a-repr a-cleanup a-fields)
      (match b
        [(ast.AstDecl.DefStruct decl-meta b-name b-repr b-cleanup b-fields)
          (and
            (= a-name b-name)
            (gen-struct-repr-eq? a-repr b-repr)
            (gen-struct-cleanup-eq? a-cleanup b-cleanup)
            (gen-field-list-eq? a-fields b-fields))]
        [_ false])]
    [(ast.AstDecl.DefStructLifetimes
        decl-meta
        a-name
        a-lifetimes
        a-repr
        a-cleanup
        a-fields)
      (match b
        [(ast.AstDecl.DefStructLifetimes
            _
            b-name
            b-lifetimes
            b-repr
            b-cleanup
            b-fields)
          (and
            (= a-name b-name)
            (ctfe.ctfe-lifetime-list-eq a-lifetimes b-lifetimes)
            (gen-struct-repr-eq? a-repr b-repr)
            (gen-struct-cleanup-eq? a-cleanup b-cleanup)
            (gen-field-list-eq? a-fields b-fields))]
        [_ false])]
    [(ast.AstDecl.DefMacro decl-meta a-name a-params a-ret a-body-box)
      (let
        [a-body : ast.AstExpr (ast.ast-node-get a-body-box)]
        (match b
          [(ast.AstDecl.DefMacro decl-meta b-name b-params b-ret b-body-box)
            (let
              [b-body : ast.AstExpr (ast.ast-node-get b-body-box)]
              (and
                (= a-name b-name)
                (gen-macro-param-list-eq? a-params b-params)
                (ctfe.ctfe-type-eq a-ret b-ret)
                (gen-expr-eq? a-body b-body)))]
          [_ false]))]
    [(ast.AstDecl.Import decl-meta a-spec)
      (match b
        [(ast.AstDecl.Import decl-meta b-spec)
          (gen-import-spec-eq? a-spec b-spec)]
        [_ false])]
    [(ast.AstDecl.IncludeStr a-name a-path)
      (match b
        [(ast.AstDecl.IncludeStr b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(ast.AstDecl.IncludeStrComptime a-name a-path)
      (match b
        [(ast.AstDecl.IncludeStrComptime b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(ast.AstDecl.IncludeStrLzss a-name a-path)
      (match b
        [(ast.AstDecl.IncludeStrLzss b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(ast.AstDecl.IncludeBin a-name a-path)
      (match b
        [(ast.AstDecl.IncludeBin b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(ast.AstDecl.Test a-name a-body-box _)
      (let
        [a-body : ast.AstExpr (ast.ast-node-get a-body-box)]
        (match b
          [(ast.AstDecl.Test b-name b-body-box _)
            (let
              [b-body : ast.AstExpr (ast.ast-node-get b-body-box)]
              (and (= a-name b-name) (gen-expr-eq? a-body b-body)))]
          [_ false]))]
    [(ast.AstDecl.Module a-name)
      (match b
        [(ast.AstDecl.Module b-name) (= a-name b-name)]
        [_ false])]
    [(ast.AstDecl.ModuleBody a-name a-body-box)
      (match b
        [(ast.AstDecl.ModuleBody b-name b-body-box)
          (and
            (= a-name b-name)
            (gen-decl-list-eq? (box-get a-body-box) (box-get b-body-box)))]
        [_ false])]
    [(ast.AstDecl.Unsafe a-inner-box)
      (let
        [a-inner : ast.AstDecl (box-get a-inner-box)]
        (match b
          [(ast.AstDecl.Unsafe b-inner-box)
            (gen-decl-eq? a-inner (box-get b-inner-box))]
          [_ (gen-decl-eq? a-inner b)]))]
    [_ false]))

;; Explicit generated-declaration equality.  The compatibility equality above
;; remains for serial/test callers; production normalization routes through
;; these workers so every expression/type read is resolved by the job owner.
(define (gen-maybe-type-eq-with-owner
  [_owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : ast.AstMaybeType]
  [b : ast.AstMaybeType]) : bool
  (match a
    [(ast.AstMaybeType.No)
      (match b
        [(ast.AstMaybeType.No) true]
        [_ false])]
    [(ast.AstMaybeType.Some a-ty)
      (match b
        [(ast.AstMaybeType.Some b-ty) (ctfe.ctfe-type-eq-in-env env a-ty b-ty)]
        [_ false])]))

(define (gen-expr-eq-with-owner
  [owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : ast.AstExpr]
  [b : ast.AstExpr]) : bool
  (ctfe.ctfe-expr-eq-in-env
    env
    (ast.ast-expr-unspan-with-pools (spec-owner-pools owner) a)
    (ast.ast-expr-unspan-with-pools (spec-owner-pools owner) b)))

(define (gen-param-eq-with-owner
  [_owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : ast.AstParam]
  [b : ast.AstParam]) : bool
  (match a
    [(ast.AstParam.Param a-name a-ty a-comptime a-consume)
      (match b
        [(ast.AstParam.Param b-name b-ty b-comptime b-consume)
          (and
            (= a-name b-name)
            (= a-consume b-consume)
            (ctfe.ctfe-type-eq-in-env env a-ty b-ty)
            (= a-comptime b-comptime))])]))

(define (gen-param-list-eq-at-with-owner
  [owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
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
  [owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : ast.AstParamList]
  [b : ast.AstParamList]) : bool
  (let
    [len : i64 (ast.ast-param-list-len (& a))]
    (and
      (= len (ast.ast-param-list-len (& b)))
      (gen-param-list-eq-at-with-owner owner env (& a) (& b) len 0))))

(define (gen-macro-param-eq-with-owner
  [_owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : ast.AstMacroParam]
  [b : ast.AstMacroParam]) : bool
  (match a
    [(ast.AstMacroParam.Param a-name a-ty a-variadic a-type-kinds)
      (match b
        [(ast.AstMacroParam.Param b-name b-ty b-variadic b-type-kinds)
          (and
            (= a-name b-name)
            (ctfe.ctfe-type-eq-in-env env a-ty b-ty)
            (= a-variadic b-variadic)
            (ast.ast-macro-type-kind-list-eq? (& a-type-kinds) (& b-type-kinds)))])]))

(define (gen-macro-param-list-eq-at-with-owner
  [owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
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
  [owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : ast.AstMacroParamList]
  [b : ast.AstMacroParamList]) : bool
  (let
    [len : i64 (ast.ast-macro-param-list-len (& a))]
    (and
      (= len (ast.ast-macro-param-list-len (& b)))
      (gen-macro-param-list-eq-at-with-owner owner env (& a) (& b) len 0))))

(define (gen-field-def-eq-with-owner
  [_owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : ast.AstFieldDef]
  [b : ast.AstFieldDef]) : bool
  (match a
    [(ast.AstFieldDef.Def a-name a-ty a-cleanup)
      (match b
        [(ast.AstFieldDef.Def b-name b-ty b-cleanup)
          (and
            (= a-name b-name)
            (ctfe.ctfe-type-eq-in-env env a-ty b-ty)
            (gen-field-cleanup-eq? a-cleanup b-cleanup))])]))

(define (gen-field-list-eq-at-with-owner
  [owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : (& a ast.AstFieldDefList)]
  [b : (& b ast.AstFieldDefList)]
  [index : i64]) : bool
  (if (>= index (struct-get a len))
    true
    (and
      (gen-field-def-eq-with-owner
        owner
        env
        (ast.ast-field-def-list-get a index (ast.ast-field-def-fallback))
        (ast.ast-field-def-list-get b index (ast.ast-field-def-fallback)))
      (gen-field-list-eq-at-with-owner owner env a b (+ index 1)))))

(define (gen-field-list-eq-with-owner
  [owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : ast.AstFieldDefList]
  [b : ast.AstFieldDefList]) : bool
  (and
    (= (struct-get (& a) len) (struct-get (& b) len))
    (gen-field-list-eq-at-with-owner owner env (& a) (& b) 0)))

(define (gen-variant-def-eq-with-owner
  [_owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : ast.AstVariantDef]
  [b : ast.AstVariantDef]) : bool
  (match a
    [(ast.AstVariantDef.Def a-name a-payloads a-cleanups)
      (match b
        [(ast.AstVariantDef.Def b-name b-payloads b-cleanups)
          (and
            (= a-name b-name)
            (ctfe.ctfe-type-list-eq-in-env env a-payloads b-payloads)
            (gen-variant-payload-cleanup-list-eq? a-cleanups b-cleanups))])]))

(define (gen-variant-list-eq-at-with-owner
  [owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : (& a ast.AstVariantDefList)]
  [b : (& b ast.AstVariantDefList)]
  [index : i64]) : bool
  (if (>= index (struct-get a len))
    true
    (and
      (gen-variant-def-eq-with-owner
        owner
        env
        (ast.ast-variant-def-list-get a index (ast.ast-variant-def-fallback))
        (ast.ast-variant-def-list-get b index (ast.ast-variant-def-fallback)))
      (gen-variant-list-eq-at-with-owner owner env a b (+ index 1)))))

(define (gen-variant-list-eq-with-owner
  [owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : ast.AstVariantDefList]
  [b : ast.AstVariantDefList]) : bool
  (and
    (= (struct-get (& a) len) (struct-get (& b) len))
    (gen-variant-list-eq-at-with-owner owner env (& a) (& b) 0)))

(define (gen-fn-metadata-eq-with-owner
  [_owner : SpecOwnerContext]
  [_env : ctfe.CtfeEnv]
  [a : ast.AstFnMetadata]
  [b : ast.AstFnMetadata]) : bool
  (match a
    [(ast.AstFnMetadata.No)
      (match b
        [(ast.AstFnMetadata.No) true]
        [_ false])]
    [(ast.AstFnMetadata.Export a-symbol)
      (match b
        [(ast.AstFnMetadata.Export b-symbol) (= a-symbol b-symbol)]
        [_ false])]
    [(ast.AstFnMetadata.SpmdCallable a-items)
      (match b
        [(ast.AstFnMetadata.SpmdCallable b-items)
          (gen-spmd-specialization-list-eq-at?
            (& (box-get a-items))
            (& (box-get b-items))
            0)]
        [_ false])]))

(define (gen-decl-list-eq-with-owner
  [owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : ast.AstDeclList]
  [b : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step a)
    [(ast.AstDeclListStep.Nil)
      (match (ast.ast-decl-list-step b)
        [(ast.AstDeclListStep.Nil) true]
        [_ false])]
    [(ast.AstDeclListStep.Cons a-head a-rest)
      (match (ast.ast-decl-list-step b)
        [(ast.AstDeclListStep.Cons b-head b-rest)
          (and
            (gen-decl-eq-with-owner owner env a-head b-head)
            (gen-decl-list-eq-with-owner owner env a-rest b-rest))]
        [_ false])]))

(define (gen-decl-eq-with-owner
  [owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
  [a : ast.AstDecl]
  [b : ast.AstDecl]) : bool
  (match a
    [(ast.AstDecl.Def _ a-name a-ty a-value-box)
      (let
        [a-value : ast.AstExpr (spec-owner-expr-get owner a-value-box)]
        (match b
          [(ast.AstDecl.Def _ b-name b-ty b-value-box)
            (and
              (= a-name b-name)
              (gen-maybe-type-eq-with-owner owner env a-ty b-ty)
              (gen-expr-eq-with-owner
                owner
                env
                a-value
                (spec-owner-expr-get owner b-value-box)))]
          [_ false]))]
    [(ast.AstDecl.DefFn _ a-name a-params a-ret a-body-box a-metadata)
      (match b
        [(ast.AstDecl.DefFn _ b-name b-params b-ret b-body-box b-metadata)
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
    [(ast.AstDecl.DefEnum _ a-name a-cleanup a-variants)
      (match b
        [(ast.AstDecl.DefEnum _ b-name b-cleanup b-variants)
          (and
            (= a-name b-name)
            (gen-enum-cleanup-eq? a-cleanup b-cleanup)
            (gen-variant-list-eq-with-owner owner env a-variants b-variants))]
        [_ false])]
    [(ast.AstDecl.DefEnumLifetimes _ a-name a-lifetimes a-cleanup a-variants)
      (match b
        [(ast.AstDecl.DefEnumLifetimes
            _
            b-name
            b-lifetimes
            b-cleanup
            b-variants)
          (and
            (= a-name b-name)
            (ctfe.ctfe-lifetime-list-eq a-lifetimes b-lifetimes)
            (gen-enum-cleanup-eq? a-cleanup b-cleanup)
            (gen-variant-list-eq-with-owner owner env a-variants b-variants))]
        [_ false])]
    [(ast.AstDecl.DefStruct _ a-name a-repr a-cleanup a-fields)
      (match b
        [(ast.AstDecl.DefStruct _ b-name b-repr b-cleanup b-fields)
          (and
            (= a-name b-name)
            (gen-struct-repr-eq? a-repr b-repr)
            (gen-struct-cleanup-eq? a-cleanup b-cleanup)
            (gen-field-list-eq-with-owner owner env a-fields b-fields))]
        [_ false])]
    [(ast.AstDecl.DefStructLifetimes
        _
        a-name
        a-lifetimes
        a-repr
        a-cleanup
        a-fields)
      (match b
        [(ast.AstDecl.DefStructLifetimes
            _
            b-name
            b-lifetimes
            b-repr
            b-cleanup
            b-fields)
          (and
            (= a-name b-name)
            (ctfe.ctfe-lifetime-list-eq a-lifetimes b-lifetimes)
            (gen-struct-repr-eq? a-repr b-repr)
            (gen-struct-cleanup-eq? a-cleanup b-cleanup)
            (gen-field-list-eq-with-owner owner env a-fields b-fields))]
        [_ false])]
    [(ast.AstDecl.DefMacro _ a-name a-params a-ret a-body-box)
      (match b
        [(ast.AstDecl.DefMacro _ b-name b-params b-ret b-body-box)
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
    [(ast.AstDecl.Import _ a-spec)
      (match b
        [(ast.AstDecl.Import _ b-spec) (gen-import-spec-eq? a-spec b-spec)]
        [_ false])]
    [(ast.AstDecl.IncludeStr a-name a-path)
      (match b
        [(ast.AstDecl.IncludeStr b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(ast.AstDecl.IncludeStrComptime a-name a-path)
      (match b
        [(ast.AstDecl.IncludeStrComptime b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(ast.AstDecl.IncludeStrLzss a-name a-path)
      (match b
        [(ast.AstDecl.IncludeStrLzss b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(ast.AstDecl.IncludeBin a-name a-path)
      (match b
        [(ast.AstDecl.IncludeBin b-name b-path)
          (and (= a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(ast.AstDecl.Test a-name a-body-box _)
      (match b
        [(ast.AstDecl.Test b-name b-body-box _)
          (and
            (= a-name b-name)
            (gen-expr-eq-with-owner
              owner
              env
              (spec-owner-expr-get owner a-body-box)
              (spec-owner-expr-get owner b-body-box)))]
        [_ false])]
    [(ast.AstDecl.Module a-name)
      (match b
        [(ast.AstDecl.Module b-name) (= a-name b-name)]
        [_ false])]
    [(ast.AstDecl.ModuleBody a-name a-body-box)
      (match b
        [(ast.AstDecl.ModuleBody b-name b-body-box)
          (and
            (= a-name b-name)
            (gen-decl-list-eq-with-owner
              owner
              env
              (box-get a-body-box)
              (box-get b-body-box)))]
        [_ false])]
    [(ast.AstDecl.Unsafe a-inner-box)
      (match b
        [(ast.AstDecl.Unsafe b-inner-box)
          (gen-decl-eq-with-owner
            owner
            env
            (box-get a-inner-box)
            (box-get b-inner-box))]
        [_ (gen-decl-eq-with-owner owner env (box-get a-inner-box) b)])]
    [_ false]))

(define (gen-key-exprs-with-owner
  [owner : SpecOwnerContext]
  [exprs : ast.AstExprList]
  [env : ctfe.CtfeEnv]
  [fuel : i64]) : ResultGenKey
  (gen-key-exprs-at-with-owner owner (& exprs) 0 env fuel))

(define (gen-key-exprs-at-with-owner
  [owner : SpecOwnerContext]
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [env : ctfe.CtfeEnv]
  [fuel : i64]) : ResultGenKey
  (if (>= index (struct-get exprs len))
    (ResultGenKey.Ok "none" fuel)
    (let
      [head-id : i64 (ast.ast-expr-list-get exprs index 0)]
      [head-expr : ast.AstExpr (spec-owner-expr-get owner head-id)]
      (match (ctfe.compiler-ctfe-eval head-expr env fuel)
        [(ctfe.ResultCtfe.Ok value head-fuel)
          (match value
            [(ctfe.CompilerCtfeValue.String text _)
              (match (gen-key-exprs-at-with-owner
                owner
                exprs
                (+ index 1)
                env
                head-fuel)
                [(ResultGenKey.Ok tail tail-fuel)
                  (ResultGenKey.Ok
                    (str_cat.str-cat (spec-string-key text) "_" tail)
                    tail-fuel)]
                [(ResultGenKey.Err diag) (ResultGenKey.Err diag)])]
            [(ctfe.CompilerCtfeValue.Name text _)
              (match (gen-key-exprs-at-with-owner
                owner
                exprs
                (+ index 1)
                env
                head-fuel)
                [(ResultGenKey.Ok tail tail-fuel)
                  (ResultGenKey.Ok
                    (str_cat.str-cat (spec-string-key text) "_" tail)
                    tail-fuel)]
                [(ResultGenKey.Err diag) (ResultGenKey.Err diag)])]
            [_
              (ResultGenKey.Err
                (box
                  (spec-diagnostic-at-expr
                    head-expr
                    "generated-decl: key expression must evaluate to String")))])]
        [(ctfe.ResultCtfe.Err diag) (ResultGenKey.Err diag)]))))

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

(define (gen-key-prefix? [key : String] [prefix : String]) : bool
  (let
    [prefix-len : i64 (string.string-length prefix)]
    (if (< (string.string-length key) prefix-len)
      false
      (string.eq (string.substring key 0 prefix-len) prefix))))

(define (gen-full-key? [key : String]) : bool
  (gen-key-prefix? key "generated:"))

(define (gen-decls-macro-key? [key : String]) : bool
  (gen-key-prefix? key "decls:"))

(define (gen-metadata-key-normalizable? [key : String]) : bool
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
          item
          " has incompatible payload"))
      (str_cat.str-cat "conflicting generated item: " item))
    (str_cat.str-cat "generated identity: " key)))

(define (gen-register-generated-decl-with-owner
  [owner : SpecOwnerContext]
  [env : ctfe.CtfeEnv]
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
        generator
        item
        arg-key)]
    (match (gen-registry-lookup-with-owner registry structural-key)
      [(GenMaybeEntry.None)
        (let
          ;; AstGeneratedDeclMeta is a persisted diagnostic/output boundary and
          ;; still carries the stable textual identity. Registry identity above
          ;; is already structural and never probes this rendered spelling.
          [key : String (gen-registration-key module generator item arg-key)]
          (ResultGenDecl.Ok
            (gen-single-decl-list
              (ast.ast-decl-comptime-decl-with-meta
                (ast.AstGeneratedDeclMeta.Some generator item args key)
                template))
            (gen-registry-insert-with-owner registry structural-key template)
            module-id))]
      [(GenMaybeEntry.Some existing)
        (if (gen-decl-eq-with-owner owner env existing template)
          (ResultGenDecl.Ok (ast.ast-decl-list-new) registry module-id)
          (let
            [key : String (gen-registration-key module generator item arg-key)]
            (ResultGenDecl.Err
              (box
                (spec-generated-context-diagnostic-with-owner
                  owner
                  (spec-generated-origin-diagnostic-with-owner
                    owner
                    template
                    args
                    (str_cat.str-cat
                      "generated-decl: duplicate generated key for "
                      item
                      " has incompatible payload"))
                  generator
                  item
                  key)))))])))

(define (gen-metadata-arg-key-with-owner
  [owner : SpecOwnerContext]
  [meta-key : String]
  [args : ast.AstExprList]
  [env : ctfe.CtfeEnv]) : ResultGenKey
  (if (> (string.string-length meta-key) 0)
    (ResultGenKey.Ok meta-key (ctfe.ctfe-fuel-limit))
    (gen-key-exprs-with-owner owner args env (ctfe.ctfe-fuel-limit))))

(define (gen-decl-runtime-template [decl : ast.AstDecl]) : ast.AstDecl
  (ast.ast-decl-with-meta (ast.ast-decl-meta-runtime-shared-view) decl))

(define (gen-rewrite-generated-decl-with-owner
  [owner : SpecOwnerContext]
  [decl : ast.AstDecl]
  [module-id : i64]
  [registry : GenRegistry]
  [env : ctfe.CtfeEnv]
  [generator : String]
  [item : String]
  [args : ast.AstExprList]
  [meta-key : String]) : ResultGenDecl
  (match (gen-decl-visible-name-id (gen-decl-runtime-template decl))
    [(SpecMaybeId.None)
      (ResultGenDecl.Err
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
    [(SpecMaybeId.Some actual-id)
      (let
        [actual-name : String
          (spec_ci.intern-compat-state-str
            (spec-owner-intern-state owner)
            actual-id)]
        (if (not (string.eq item actual-name))
          (ResultGenDecl.Err
            (box
              (spec-generated-context-diagnostic-with-owner
                owner
                (spec-generated-origin-diagnostic-with-owner
                  owner
                  (gen-decl-runtime-template decl)
                  args
                  (str_cat.str-cat
                    "generated-decl: metadata item "
                    item
                    " does not match payload "
                    actual-name))
                generator
                item
                meta-key)))
          (match (gen-metadata-arg-key-with-owner owner meta-key args env)
            [(ResultGenKey.Ok arg-key _)
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
            [(ResultGenKey.Err diag)
              (ResultGenDecl.Err
                (box
                  (spec-generated-context-diagnostic-with-owner
                    owner
                    (box-get diag)
                    generator
                    item
                    meta-key)))])))]))

(define (gen-rewrite-decl-with-owner
  [owner : SpecOwnerContext]
  [decl : ast.AstDecl]
  [module-id : i64]
  [registry : GenRegistry]
  [env : ctfe.CtfeEnv]) : ResultGenDecl
  (match decl
    [(ast.AstDecl.Module name)
      (ResultGenDecl.Ok (gen-single-decl-list decl) registry name)]
    [_
      (match (ast.ast-decl-generated-meta decl)
        [(ast.AstGeneratedDeclMeta.No)
          (ResultGenDecl.Ok (gen-single-decl-list decl) registry module-id)]
        [(ast.AstGeneratedDeclMeta.Some generator item args meta-key)
          (if (not (gen-metadata-key-normalizable? meta-key))
            (ResultGenDecl.Ok (gen-single-decl-list decl) registry module-id)
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
    [(ast.AstDeclPathListStep.Cons path _) path]
    [(ast.AstDeclPathListStep.Nil) fallback]))

(define (gen-path-list-tail [paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (match (ast.ast-decl-path-list-step paths)
    [(ast.AstDeclPathListStep.Cons _ rest-box)
      (let
        [rest : ast.AstDeclPathList rest-box]
        rest)]
    [(ast.AstDeclPathListStep.Nil) (ast.ast-decl-path-list-new)]))

(define (gen-path-list-for-decls
  [decls : ast.AstDeclList]
  [path : String]
  [owner-id : i64]
  [rest-paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [out : ast.AstDeclPathList
      (ast.ast-decl-path-list-with-capacity
        (+
          (ast.ast-decl-list-len (& decls))
          (ast.ast-decl-path-list-len (& rest-paths))))]
    [index : i64 0]
    [count : i64 (ast.ast-decl-list-len (& decls))]
    (begin
      (while (< index count)
        (begin
          (ast.ast-decl-path-list-push-with-owner-id (&mut out) path owner-id)
          (set! index (+ index 1))))
      (ast.ast-decl-path-list-append-from (&mut out) (& rest-paths) 0)
      out)))

(define (gen-path-list-push-for-decls
  [out : (&mut out ast.AstDeclPathList)]
  [decls : ast.AstDeclList]
  [path : String]
  [owner-id : i64]
  [index : i64]) : unit
  (if (>= index (ast.ast-decl-list-len (& decls)))
    unit
    (begin
      (ast.ast-decl-path-list-push-with-owner-id out path owner-id)
      (gen-path-list-push-for-decls out decls path owner-id (+ index 1)))))

(define (gen-rewrite-decls-with-owner
  [owner : SpecOwnerContext]
  [decls : ast.AstDeclList]
  [module-id : i64]
  [registry : GenRegistry]
  [env : ctfe.CtfeEnv]) : ResultGenDecls
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [cursor : ast.AstDeclList decls]
    [out : ast.AstDeclList (ast.ast-decl-list-with-capacity count)]
    [out-origins : parser.CompilerParseDeclOriginAliasVec
      (parser.compiler-parse-decl-origin-alias-vec-with-capacity count)]
    [cur-registry : GenRegistry registry]
    [cur-module-id : i64 module-id]
    [result : ResultGenDecls
      (ResultGenDecls.Err
        (box
          (cdiag.compiler-diagnostic-simple
            "<internal>"
            1
            1
            "generated-decl normalization did not finish")))]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast.ast-decl-list-step cursor)
          [(ast.AstDeclListStep.Nil)
            (begin
              (parser.compiler-parse-decl-origin-alias-vec-register!
                (& out)
                (& out-origins))
              (set! result (ResultGenDecls.Ok out cur-registry cur-module-id))
              (set! done true))]
          [(ast.AstDeclListStep.Cons decl rest)
            (match (gen-rewrite-decl-with-owner
              owner
              decl
              cur-module-id
              cur-registry
              env)
              [(ResultGenDecl.Ok rewritten-decls decl-registry decl-module)
                (let
                  [out-start : i64 (ast.ast-decl-list-len (& out))]
                  [rewritten-count : i64
                    (ast.ast-decl-list-len (& rewritten-decls))]
                  (begin
                    (parser.compiler-parse-decl-origin-alias-vec-push-key-slot!
                      (&mut out-origins)
                      out-start
                      rewritten-count
                      (parser.compiler-parse-decl-list-storage-key (& rest))
                      (- (struct-get rest offset) 1)
                      decl
                      (!= rewritten-count 1))
                    (ast.ast-decl-list-append-from
                      (&mut out)
                      (& rewritten-decls)
                      0)
                    (set! cur-registry decl-registry)
                    (set! cur-module-id decl-module)
                    (set! cursor rest)))]
              [(ResultGenDecl.Err diag)
                (begin
                  (set! result (ResultGenDecls.Err diag))
                  (set! done true))])]))
      result)))

(define (gen-rewrite-decls-with-paths-and-owner
  [owner : SpecOwnerContext]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [module-id : i64]
  [registry : GenRegistry]
  [env : ctfe.CtfeEnv]) : ResultGenDeclsWithPaths
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
      (ResultGenDeclsWithPaths.Err
        (box
          (cdiag.compiler-diagnostic-simple
            "<internal>"
            1
            1
            "generated-decl normalization with paths did not finish")))]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast.ast-decl-list-step decl-cursor)
          [(ast.AstDeclListStep.Nil)
            (begin
              (parser.compiler-parse-decl-origin-alias-vec-register!
                (& out)
                (& out-origins))
              (set!
                result
                (ResultGenDeclsWithPaths.Ok
                  out
                  out-paths
                  cur-registry
                  cur-module-id))
              (set! done true))]
          [(ast.AstDeclListStep.Cons decl rest)
            (let
              [decl-path : String
                (gen-path-list-head-or path-cursor fallback-path)]
              [owner-id : i64
                (ast.ast-decl-path-list-owner-id
                  (& path-cursor)
                  0
                  cbi.compiler-builtin-id-fix-empty)]
              (match (gen-rewrite-decl-with-owner
                owner
                decl
                cur-module-id
                cur-registry
                env)
                [(ResultGenDecl.Ok rewritten-decls decl-registry decl-module)
                  (let
                    [out-start : i64 (ast.ast-decl-list-len (& out))]
                    [rewritten-count : i64
                      (ast.ast-decl-list-len (& rewritten-decls))]
                    (begin
                      (parser.compiler-parse-decl-origin-alias-vec-push-key-slot!
                        (&mut out-origins)
                        out-start
                        rewritten-count
                        (parser.compiler-parse-decl-list-storage-key (& rest))
                        (- (struct-get rest offset) 1)
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
                        0)
                      (set! cur-registry decl-registry)
                      (set! cur-module-id decl-module)
                      (set! decl-cursor rest)
                      (set! path-cursor (gen-path-list-tail path-cursor))))]
                [(ResultGenDecl.Err diag)
                  (begin
                    (set!
                      result
                      (ResultGenDeclsWithPaths.Err
                        (box
                          (cdiag.compiler-diagnostic-with-path
                            (box-get diag)
                            decl-path))))
                    (set! done true))]))]))
      result)))

(define (gen-normalize-program-with-pools-and-intern-state
  [program : ast.AstProgram]
  [owner : SpecOwnerContext]) : ResultGenProgram
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (box-get decls-box)]
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
          [(ResultGenDecls.Ok rewritten _ _)
            (ResultGenProgram.Ok (ast.ast-program rewritten))]
          [(ResultGenDecls.Err diag) (ResultGenProgram.Err diag)]))]))

(define (gen-normalize-program-with-paths-and-pools-and-intern-state
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [owner : SpecOwnerContext]) : ResultGenProgramWithPaths
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (box-get decls-box)]
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
          [(ResultGenDeclsWithPaths.Ok rewritten rewritten-paths _ _)
            (ResultGenProgramWithPaths.Ok
              (ast.ast-program rewritten)
              rewritten-paths)]
          [(ResultGenDeclsWithPaths.Err diag)
            (ResultGenProgramWithPaths.Err diag)]))]))

;; Legacy normalization adapters. They capture the active compatibility views
;; once, route all work through the owner entrypoint above, preserve the
;; owner's mutated pool cells while restoring the prior ambient context, and
;; publish the owner's interner on both success and error paths.
(define (gen-normalize-program-with-pools
  [program : ast.AstProgram]
  [pools : ast.AstNodePoolContext]) : ResultGenProgram
  (let
    [previous-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [intern-state : spec_ci.InternCompatState
      (spec_ci.intern-compat-state-capture-active)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      (spec_ci.intern-compat-state-install! intern-state)
      (let
        [result : ResultGenProgram
          (gen-normalize-program-with-pools-and-intern-state
            program
            (spec-owner-context-new pools intern-state))]
        (begin
          (ast.ast-node-pool-context-install! previous-pools)
          (spec_ci.intern-compat-state-install! intern-state)
          result)))))

(define (gen-normalize-program-with-paths-and-pools
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [pools : ast.AstNodePoolContext]) : ResultGenProgramWithPaths
  (let
    [previous-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [intern-state : spec_ci.InternCompatState
      (spec_ci.intern-compat-state-capture-active)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      (spec_ci.intern-compat-state-install! intern-state)
      (let
        [result : ResultGenProgramWithPaths
          (gen-normalize-program-with-paths-and-pools-and-intern-state
            program
            paths
            fallback-path
            (spec-owner-context-new pools intern-state))]
        (begin
          (ast.ast-node-pool-context-install! previous-pools)
          (spec_ci.intern-compat-state-install! intern-state)
          result)))))

(define (gen-normalize-program [program : ast.AstProgram]) : ResultGenProgram
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultGenProgram (gen-normalize-program-with-pools program pools)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (gen-decl-needs-normalize? [decl : ast.AstDecl]) : bool
  (match (ast.ast-decl-generated-meta decl)
    [(ast.AstGeneratedDeclMeta.Some _ _ _ key)
      (gen-metadata-key-normalizable? key)]
    [(ast.AstGeneratedDeclMeta.No) false]))

(define (gen-decls-needed? [decls : ast.AstDeclList]) : bool
  (let
    [cursor : ast.AstDeclList decls]
    [needed : bool false]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast.ast-decl-list-step cursor)
          [(ast.AstDeclListStep.Nil) (set! done true)]
          [(ast.AstDeclListStep.Cons decl rest)
            (if (gen-decl-needs-normalize? decl)
              (begin
                (set! needed true)
                (set! done true))
              (set! cursor rest))]))
      needed)))

(define (spec-value-runtime-type-matches?
  [state : SpecState]
  [value : ctfe.CompilerCtfeValue]
  [ty : ast.AstType]) : bool
  (begin
    (cbi.compiler-builtin-refresh!)
    (match value
      [(ctfe.CompilerCtfeValue.I64 _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.I64))]
      [(ctfe.CompilerCtfeValue.F64 _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.F64))]
      [(ctfe.CompilerCtfeValue.F32 _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.F32))]
      [(ctfe.CompilerCtfeValue.Bool _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Bool))]
      [(ctfe.CompilerCtfeValue.Char _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Char))]
      [(ctfe.CompilerCtfeValue.String _ _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.String))]
      [(ctfe.CompilerCtfeValue.Name _ _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.String))]
      [(ctfe.CompilerCtfeValue.Unit)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Unit))]
      [(ctfe.CompilerCtfeValue.Type _) false]
      [(ctfe.CompilerCtfeValue.Expr _ _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Expr))]
      [(ctfe.CompilerCtfeValue.CapturedExpr _ _ _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Expr))]
      [(ctfe.CompilerCtfeValue.ExprList _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.ExprList))]
      [(ctfe.CompilerCtfeValue.CapturedExprList _ _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.ExprList))]
      [(ctfe.CompilerCtfeValue.ExprClause _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Var cbi.compiler-builtin-id-fix-ExprClause))]
      [(ctfe.CompilerCtfeValue.CapturedExprClause _ _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Var cbi.compiler-builtin-id-fix-ExprClause))]
      [(ctfe.CompilerCtfeValue.ExprClauseList _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Var cbi.compiler-builtin-id-fix-ExprClauseList))]
      [(ctfe.CompilerCtfeValue.CapturedExprClauseList _ _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Var cbi.compiler-builtin-id-fix-ExprClauseList))]
      [(ctfe.CompilerCtfeValue.ExprBindingClause _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Var cbi.compiler-builtin-id-fix-ExprBindingClause))]
      [(ctfe.CompilerCtfeValue.ExprBindingClauseList _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Var cbi.compiler-builtin-id-fix-ExprBindingClauseList))]
      [(ctfe.CompilerCtfeValue.Pattern _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Var cbi.compiler-builtin-id-fix-Pattern))]
      [(ctfe.CompilerCtfeValue.PatternList _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Var cbi.compiler-builtin-id-fix-PatternList))]
      [(ctfe.CompilerCtfeValue.MatchArm _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Var cbi.compiler-builtin-id-fix-MatchArm))]
      [(ctfe.CompilerCtfeValue.MatchArmList _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Var cbi.compiler-builtin-id-fix-MatchArmList))]
      [(ctfe.CompilerCtfeValue.LetBinding _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Var cbi.compiler-builtin-id-fix-LetBinding))]
      [(ctfe.CompilerCtfeValue.LetBindingList _)
        (ctfe.ctfe-type-eq-in-env
          (spec-state-ctfe-env state)
          ty
          (ast.AstType.Var cbi.compiler-builtin-id-fix-LetBindingList))]
      [(ctfe.CompilerCtfeValue.TypeInfo _) false]
      [(ctfe.CompilerCtfeValue.TypeInfoBox _) false]
      [(ctfe.CompilerCtfeValue.TypeInfoList _) false]
      [(ctfe.CompilerCtfeValue.TypeField _ _) false]
      [(ctfe.CompilerCtfeValue.TypeFieldList _) false]
      [(ctfe.CompilerCtfeValue.TypeVariantPayload _) false]
      [(ctfe.CompilerCtfeValue.TypeVariantPayloadList _) false]
      [(ctfe.CompilerCtfeValue.TypeVariant _ _) false]
      [(ctfe.CompilerCtfeValue.TypeVariantList _) false])))

(define (spec-value-type-label [value : ctfe.CompilerCtfeValue]) : String
  (match value
    [(ctfe.CompilerCtfeValue.I64 _) "i64"]
    [(ctfe.CompilerCtfeValue.F64 _) "f64"]
    [(ctfe.CompilerCtfeValue.F32 _) "f32"]
    [(ctfe.CompilerCtfeValue.Bool _) "bool"]
    [(ctfe.CompilerCtfeValue.Char _) "char"]
    [(ctfe.CompilerCtfeValue.String _ _) "String"]
    [(ctfe.CompilerCtfeValue.Name _ _) "String"]
    [(ctfe.CompilerCtfeValue.Unit) "unit"]
    [(ctfe.CompilerCtfeValue.Type _) "type"]
    [(ctfe.CompilerCtfeValue.Expr _ _) "Expr"]
    [(ctfe.CompilerCtfeValue.CapturedExpr _ _ _) "Expr"]
    [(ctfe.CompilerCtfeValue.ExprList _) "expr-list"]
    [(ctfe.CompilerCtfeValue.CapturedExprList _ _) "expr-list"]
    [(ctfe.CompilerCtfeValue.ExprClause _) "ExprClause"]
    [(ctfe.CompilerCtfeValue.CapturedExprClause _ _) "ExprClause"]
    [(ctfe.CompilerCtfeValue.ExprClauseList _) "ExprClauseList"]
    [(ctfe.CompilerCtfeValue.CapturedExprClauseList _ _) "ExprClauseList"]
    [(ctfe.CompilerCtfeValue.ExprBindingClause _) "ExprBindingClause"]
    [(ctfe.CompilerCtfeValue.ExprBindingClauseList _) "ExprBindingClauseList"]
    [(ctfe.CompilerCtfeValue.Pattern _) "Pattern"]
    [(ctfe.CompilerCtfeValue.PatternList _) "PatternList"]
    [(ctfe.CompilerCtfeValue.MatchArm _) "MatchArm"]
    [(ctfe.CompilerCtfeValue.MatchArmList _) "MatchArmList"]
    [(ctfe.CompilerCtfeValue.LetBinding _) "LetBinding"]
    [(ctfe.CompilerCtfeValue.LetBindingList _) "LetBindingList"]
    [(ctfe.CompilerCtfeValue.TypeInfo _) "TypeInfo"]
    [(ctfe.CompilerCtfeValue.TypeInfoBox _) "TypeInfoBox"]
    [(ctfe.CompilerCtfeValue.TypeInfoList _) "TypeInfoList"]
    [(ctfe.CompilerCtfeValue.TypeField _ _) "TypeField"]
    [(ctfe.CompilerCtfeValue.TypeFieldList _) "TypeFieldList"]
    [(ctfe.CompilerCtfeValue.TypeVariantPayload _) "TypeVariantPayload"]
    [(ctfe.CompilerCtfeValue.TypeVariantPayloadList _) "TypeVariantPayloadList"]
    [(ctfe.CompilerCtfeValue.TypeVariant _ _) "TypeVariant"]
    [(ctfe.CompilerCtfeValue.TypeVariantList _) "TypeVariantList"]))

;; Head-first scan: slot 0 is the newest binding, so the first hit is the one
;; that shadows. Returns -1 when the name is unbound.
(define (spec-type-subst-find [subs : SpecTypeSubst] [name-id : i64] [at : i64]) : i64
  (if (>= at (struct-get subs len))
    (- 0 1)
    (match (array.ref (struct-get subs slots) at)
      [(SpecTypeBinding.Bind key-id _)
        (if (= key-id name-id)
          at
          (spec-type-subst-find subs name-id (+ at 1)))])))

(define (spec-type-subst-lookup [subs : SpecTypeSubst] [name-id : i64]) : SpecMaybeId
  (if (< (spec-type-subst-find subs name-id 0) 0)
    (SpecMaybeId.None)
    (SpecMaybeId.Some name-id)))

(define (spec-type-subst-type [subs : SpecTypeSubst] [name-id : i64]) : ast.AstType
  (let
    [at : i64 (spec-type-subst-find subs name-id 0)]
    (if (< at 0)
      (ast.AstType.Var name-id)
      (match (array.ref (struct-get subs slots) at)
        [(SpecTypeBinding.Bind _ ty) ty]))))

(define (spec-value-subst-find
  [subs : SpecValueSubst]
  [name-id : i64]
  [at : i64]) : i64
  (if (>= at (struct-get subs len))
    (- 0 1)
    (match (array.ref (struct-get subs slots) at)
      [(SpecValueBinding.Bind key-id _)
        (if (= key-id name-id)
          at
          (spec-value-subst-find subs name-id (+ at 1)))])))

(define (spec-value-subst-lookup [subs : SpecValueSubst] [name-id : i64]) : SpecMaybeId
  (if (< (spec-value-subst-find subs name-id 0) 0)
    (SpecMaybeId.None)
    (SpecMaybeId.Some name-id)))

(define (spec-value-subst-value [subs : SpecValueSubst] [name-id : i64]) : ctfe.CompilerCtfeValue
  (let
    [at : i64 (spec-value-subst-find subs name-id 0)]
    (if (< at 0)
      (ctfe.CompilerCtfeValue.Unit)
      (match (array.ref (struct-get subs slots) at)
        [(SpecValueBinding.Bind _ value) value]))))

;; An unbound name leaves the environment alone, so the hot inner-scope walk
;; shares the outer buffer instead of rebuilding it.
(define (spec-value-subst-remove-name [subs : SpecValueSubst] [name-id : i64]) : SpecValueSubst
  (if (< (spec-value-subst-find subs name-id 0) 0)
    subs
    (let
      [slots : (__tl_dyn-array SpecValueBinding)
        (array.make-array SpecValueBinding (struct-get subs len))]
      [at : i64 0]
      [kept : i64 0]
      (begin
        (while (< at (struct-get subs len))
          (begin
            (match (array.ref (struct-get subs slots) at)
              [(SpecValueBinding.Bind key-id _)
                (if (= key-id name-id)
                  unit
                  (begin
                    (array-set!
                      slots
                      kept
                      (array.ref (struct-get subs slots) at))
                    (set! kept (+ kept 1))))])
            (set! at (+ at 1))))
        (SpecValueSubst slots kept)))))

(define (spec-value-subst-remove-params
  [subs : SpecValueSubst]
  [params : ast.AstParamList]) : SpecValueSubst
  (spec-value-subst-remove-params-at subs (& params) 0))

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
  [subs : SpecValueSubst]
  [bindings : ast.AstLetBindingList]) : SpecValueSubst
  (spec-value-subst-remove-let-binding-names-at subs (& bindings) 0))

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
      [(ast.AstLetBinding.Binding name _ _)
        (spec-value-subst-remove-let-binding-names-at
          (spec-value-subst-remove-name subs name)
          bindings
          (+ index 1))])))

(define (spec-value-subst-remove-pattern
  [subs : SpecValueSubst]
  [pattern : ast.AstPattern]) : SpecValueSubst
  (match pattern
    [(ast.AstPattern.Var name _) (spec-value-subst-remove-name subs name)]
    [(ast.AstPattern.Tuple patterns-box)
      (let
        [patterns : ast.AstPatternList (box-get patterns-box)]
        (spec-value-subst-remove-pattern-list subs patterns))]
    [(ast.AstPattern.Array patterns-box)
      (let
        [patterns : ast.AstPatternList (box-get patterns-box)]
        (spec-value-subst-remove-pattern-list subs patterns))]
    [(ast.AstPattern.Wildcard) subs]
    [(ast.AstPattern.Binding name) (spec-value-subst-remove-name subs name)]
    [(ast.AstPattern.Variant _ patterns-box)
      (let
        [patterns : ast.AstPatternList (box-get patterns-box)]
        (spec-value-subst-remove-pattern-list subs patterns))]
    [(ast.AstPattern.Literal _) subs]))

(define (spec-value-subst-remove-pattern-list
  [subs : SpecValueSubst]
  [patterns : ast.AstPatternList]) : SpecValueSubst
  (spec-value-subst-remove-pattern-list-at subs (& patterns) 0))

(define (spec-value-subst-remove-pattern-list-at
  [subs : SpecValueSubst]
  [patterns : (& patterns ast.AstPatternList)]
  [index : i64]) : SpecValueSubst
  (if (>= index (struct-get patterns len))
    subs
    (spec-value-subst-remove-pattern-list-at
      (spec-value-subst-remove-pattern
        subs
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback)))
      patterns
      (+ index 1))))

(define (spec-type-subst-remove-name [subs : SpecTypeSubst] [name-id : i64]) : SpecTypeSubst
  (if (< (spec-type-subst-find subs name-id 0) 0)
    subs
    (let
      [slots : (__tl_dyn-array SpecTypeBinding)
        (array.make-array SpecTypeBinding (struct-get subs len))]
      [at : i64 0]
      [kept : i64 0]
      (begin
        (while (< at (struct-get subs len))
          (begin
            (match (array.ref (struct-get subs slots) at)
              [(SpecTypeBinding.Bind key-id _)
                (if (= key-id name-id)
                  unit
                  (begin
                    (array-set!
                      slots
                      kept
                      (array.ref (struct-get subs slots) at))
                    (set! kept (+ kept 1))))])
            (set! at (+ at 1))))
        (SpecTypeSubst slots kept)))))

(define (spec-type-subst-remove-params
  [subs : SpecTypeSubst]
  [params : ast.AstParamList]) : SpecTypeSubst
  (spec-type-subst-remove-params-at subs (& params) 0))

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
  [subs : SpecTypeSubst]
  [bindings : ast.AstLetBindingList]) : SpecTypeSubst
  (spec-type-subst-remove-let-binding-names-at subs (& bindings) 0))

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
      [(ast.AstLetBinding.Binding name _ _)
        (spec-type-subst-remove-let-binding-names-at
          (spec-type-subst-remove-name subs name)
          bindings
          (+ index 1))])))

(define (spec-type-subst-remove-pattern
  [subs : SpecTypeSubst]
  [pattern : ast.AstPattern]) : SpecTypeSubst
  (match pattern
    [(ast.AstPattern.Var name _) (spec-type-subst-remove-name subs name)]
    [(ast.AstPattern.Tuple patterns-box)
      (let
        [patterns : ast.AstPatternList (box-get patterns-box)]
        (spec-type-subst-remove-pattern-list subs patterns))]
    [(ast.AstPattern.Array patterns-box)
      (let
        [patterns : ast.AstPatternList (box-get patterns-box)]
        (spec-type-subst-remove-pattern-list subs patterns))]
    [(ast.AstPattern.Wildcard) subs]
    [(ast.AstPattern.Binding name) (spec-type-subst-remove-name subs name)]
    [(ast.AstPattern.Variant _ patterns-box)
      (let
        [patterns : ast.AstPatternList (box-get patterns-box)]
        (spec-type-subst-remove-pattern-list subs patterns))]
    [(ast.AstPattern.Literal _) subs]))

(define (spec-type-subst-remove-pattern-list
  [subs : SpecTypeSubst]
  [patterns : ast.AstPatternList]) : SpecTypeSubst
  (spec-type-subst-remove-pattern-list-at subs (& patterns) 0))

(define (spec-type-subst-remove-pattern-list-at
  [subs : SpecTypeSubst]
  [patterns : (& patterns ast.AstPatternList)]
  [index : i64]) : SpecTypeSubst
  (if (>= index (struct-get patterns len))
    subs
    (spec-type-subst-remove-pattern-list-at
      (spec-type-subst-remove-pattern
        subs
        (ast.ast-pattern-list-get patterns index (ast.ast-pattern-fallback)))
      patterns
      (+ index 1))))

(define (spec-substitute-type-with-owner
  [owner : SpecOwnerContext]
  [ty : ast.AstType]
  [subs : SpecTypeSubst]) : ast.AstType
  (match ty
    [(ast.AstType.Func args ret)
      (ast.ast-ty-func-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-list-with-owner owner (box-get args) subs)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner ret)
          subs))]
    [(ast.AstType.Tuple elems)
      (ast.AstType.Tuple
        (box (spec-substitute-type-list-with-owner owner (box-get elems) subs)))]
    [(ast.AstType.Array elem count)
      (ast.ast-ty-array-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner elem)
          subs)
        count)]
    [(ast.AstType.DynArray elem)
      (ast.ast-ty-dyn-array-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner elem)
          subs))]
    [(ast.AstType.Slice elem)
      (ast.ast-ty-slice-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner elem)
          subs))]
    [(ast.AstType.Box elem)
      (ast.ast-ty-box-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner elem)
          subs))]
    [(ast.AstType.Ptr elem)
      (ast.ast-ty-ptr-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner elem)
          subs))]
    [(ast.AstType.MutPtr elem)
      (ast.ast-ty-mut-ptr-with-pools
        (spec-owner-pools owner)
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner elem)
          subs))]
    [(ast.AstType.Ref region inner)
      (ast.ast-ty-ref-with-pools
        (spec-owner-pools owner)
        region
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner inner)
          subs))]
    [(ast.AstType.MutRef region inner)
      (ast.ast-ty-mut-ref-with-pools
        (spec-owner-pools owner)
        region
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner inner)
          subs))]
    [(ast.AstType.Region region inner)
      (ast.ast-ty-region-with-pools
        (spec-owner-pools owner)
        region
        (spec-substitute-type-with-owner
          owner
          (spec-owner-type-get owner inner)
          subs))]
    [(ast.AstType.EnumArgs name lifetimes)
      (ast.AstType.EnumArgs name lifetimes)]
    [(ast.AstType.StructArgs name lifetimes)
      (ast.AstType.StructArgs name lifetimes)]
    [(ast.AstType.VarArgs name lifetimes)
      (match (spec-type-subst-lookup subs name)
        [(SpecMaybeId.Some _) (spec-type-subst-type subs name)]
        [(SpecMaybeId.None) (ast.AstType.VarArgs name lifetimes)])]
    [(ast.AstType.Var name)
      (match (spec-type-subst-lookup subs name)
        [(SpecMaybeId.Some _) (spec-type-subst-type subs name)]
        [(SpecMaybeId.None) ty])]
    [_ ty]))

(define (spec-substitute-type-list-into-with-owner
  [owner : SpecOwnerContext]
  [types : (& types ast.AstTypeList)]
  [subs : SpecTypeSubst]
  [out : (&mut out ast.AstTypeList)]
  [index : i64]) : unit
  (if (>= index (ast.ast-type-list-len types))
    unit
    (begin
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
      (spec-substitute-type-list-into-with-owner
        owner
        types
        subs
        out
        (+ index 1)))))

(define (spec-substitute-type-list-with-owner
  [owner : SpecOwnerContext]
  [types : ast.AstTypeList]
  [subs : SpecTypeSubst]) : ast.AstTypeList
  (let
    [out : ast.AstTypeList
      (ast.ast-type-list-with-capacity (ast.ast-type-list-len (& types)))]
    (begin
      (spec-substitute-type-list-into-with-owner
        owner
        (& types)
        subs
        (&mut out)
        0)
      out)))

(define (spec-substitute-maybe-type-with-owner
  [owner : SpecOwnerContext]
  [ty : ast.AstMaybeType]
  [subs : SpecTypeSubst]) : ast.AstMaybeType
  (match ty
    [(ast.AstMaybeType.No) ast.AstMaybeType.No]
    [(ast.AstMaybeType.Some inner)
      (ast.AstMaybeType.Some (spec-substitute-type-with-owner owner inner subs))]))

(define (spec-substitute-param-types-with-owner
  [owner : SpecOwnerContext]
  [params : ast.AstParamList]
  [subs : SpecTypeSubst]) : ast.AstParamList
  (let
    [out : ast.AstParamList
      (ast.ast-param-list-with-capacity (ast.ast-param-list-len (& params)))]
    (begin
      (spec-substitute-param-types-into-with-owner
        owner
        (& params)
        subs
        0
        (&mut out))
      out)))

(define (spec-substitute-param-types-into-with-owner
  [owner : SpecOwnerContext]
  [params : (& params ast.AstParamList)]
  [subs : SpecTypeSubst]
  [index : i64]
  [out : (&mut out ast.AstParamList)]) : unit
  (if (>= index (ast.ast-param-list-len params))
    unit
    (begin
      (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
        [(ast.AstParam.Param name ty _ consume?)
          (ast.ast-param-list-push
            out
            (ast.AstParam.Param
              name
              (spec-substitute-type-with-owner owner ty subs)
              false
              consume?))])
      (spec-substitute-param-types-into-with-owner
        owner
        params
        subs
        (+ index 1)
        out))))

;; Self-test compatibility shim for the removed ambient type worker.  No
;; production entrypoint calls this name; it only lets legacy unit assertions
;; exercise the owner implementation without maintaining a second graph.
(define (spec-substitute-type [ty : ast.AstType] [subs : SpecTypeSubst]) : ast.AstType
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [intern-state : spec_ci.InternCompatState
      (spec_ci.intern-compat-state-capture-active)]
    [owner : SpecOwnerContext (spec-owner-context-new pools intern-state)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      (spec_ci.intern-compat-state-install! intern-state)
      (let
        [result : ast.AstType (spec-substitute-type-with-owner owner ty subs)]
        (begin
          (ast.ast-node-pool-context-install! pools)
          (spec_ci.intern-compat-state-install! intern-state)
          result)))))

(define (spec-ctfe-value-to-expr-with-owner
  [owner : SpecOwnerContext]
  [value : ctfe.CompilerCtfeValue]
  [origin : ast.AstExpr]) : ResultSpecSubExpr
  (match value
    [(ctfe.CompilerCtfeValue.I64 n)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push owner (ast.AstExpr.Literal (ast.ast-lit-int n))))]
    [(ctfe.CompilerCtfeValue.F64 n)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push
          owner
          (ast.AstExpr.Literal
            (ast.AstLiteral.Float (cfloat.compiler-float-format-f64 n)))))]
    [(ctfe.CompilerCtfeValue.F32 n)
      (ResultSpecSubExpr.Ok
        (ast.ast-expr-ann-with-pools
          (spec-owner-pools owner)
          (spec-owner-expr-push
            owner
            (ast.AstExpr.Literal
              (ast.AstLiteral.Float
                (cfloat.compiler-float-format-f64
                  (cfloat.compiler-float-round-f32-as-f64 n)))))
          (ast.AstType.F32)))]
    [(ctfe.CompilerCtfeValue.Bool b)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push
          owner
          (ast.AstExpr.Literal (ast.AstLiteral.Bool b))))]
    [(ctfe.CompilerCtfeValue.Char c)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push
          owner
          (ast.AstExpr.Literal (ast.AstLiteral.Char c))))]
    [(ctfe.CompilerCtfeValue.String _ _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time String value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.Name _ _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time String value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.Unit)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push owner (ast.AstExpr.Literal (ast.AstLiteral.Unit))))]
    [(ctfe.CompilerCtfeValue.Type ty)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            (str_cat.str-cat
              "cannot substitute compile-time type value "
              (spec-type-key-with-owner owner ty)
              " into runtime expression"))))]
    [(ctfe.CompilerCtfeValue.Expr _ _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time Expr value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.CapturedExpr _ _ _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time Expr value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.ExprList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprList value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.CapturedExprList _ _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprList value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.ExprClause _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprClause value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.CapturedExprClause _ _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprClause value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.ExprClauseList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprClauseList value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.CapturedExprClauseList _ _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprClauseList value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.ExprBindingClause _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprBindingClause value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.ExprBindingClauseList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprBindingClauseList value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.Pattern _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time Pattern value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.PatternList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time PatternList value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.MatchArm _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time MatchArm value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.MatchArmList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time MatchArmList value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.LetBinding _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time LetBinding value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.LetBindingList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time LetBindingList value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.TypeInfo _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeInfo value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.TypeInfoBox _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeInfo box value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.TypeInfoList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeInfoList value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.TypeField _ _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeField value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.TypeFieldList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeFieldList value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.TypeVariantPayload _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariantPayload value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.TypeVariantPayloadList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariantPayloadList value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.TypeVariant _ _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariant value into runtime expression")))]
    [(ctfe.CompilerCtfeValue.TypeVariantList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariantList value into runtime expression")))]))

(define (spec-expr-var-name-id-with-owner
  [owner : SpecOwnerContext]
  [expr : ast.AstExpr]) : SpecMaybeId
  (match (ast.ast-expr-unspan-with-pools (spec-owner-pools owner) expr)
    [(ast.AstExpr.Var name) (SpecMaybeId.Some name)]
    [_ (SpecMaybeId.None)]))

(define (spec-rewrite-expr-list
  [exprs : ast.AstExprList]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecExprList
  (let
    [out : ast.AstExprList
      (ast.ast-expr-list-with-capacity (struct-get (& exprs) len))]
    (match (spec-rewrite-expr-list-at (& exprs) 0 templates state (&mut out))
      [(ResultSpecExprListBuild.Ok next-state)
        (ResultSpecExprList.Ok out next-state)]
      [(ResultSpecExprListBuild.Err diag) (ResultSpecExprList.Err diag)])))

(define (spec-rewrite-expr-list-at
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [out : (&mut out ast.AstExprList)]) : ResultSpecExprListBuild
  (if (>= index (struct-get exprs len))
    (ResultSpecExprListBuild.Ok state)
    (let
      [head : ast.AstExpr
        (spec-state-expr-get state (ast.ast-expr-list-get exprs index 0))]
      (match (spec-rewrite-expr head templates state)
        [(ResultSpecExpr.Ok rewritten-head head-state)
          (begin
            (ast.ast-expr-list-push out rewritten-head)
            (spec-rewrite-expr-list-at
              exprs
              (+ index 1)
              templates
              head-state
              out))]
        [(ResultSpecExpr.Err diag) (ResultSpecExprListBuild.Err diag)]))))

(define (spec-rewrite-let-bindings
  [bindings : ast.AstLetBindingList]
  [templates : SpecTemplateEnv]
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
      [(ResultSpecLetBindingListBuild.Ok next-state)
        (ResultSpecLetBindingList.Ok out next-state)]
      [(ResultSpecLetBindingListBuild.Err diag)
        (ResultSpecLetBindingList.Err diag)])))

(define (spec-rewrite-let-bindings-at
  [bindings : (& bindings ast.AstLetBindingList)]
  [index : i64]
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [out : (&mut out ast.AstLetBindingList)]) : ResultSpecLetBindingListBuild
  (if (>= index (ast.ast-let-binding-list-len bindings))
    (ResultSpecLetBindingListBuild.Ok state)
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name ty value-box)
        (let
          [value : ast.AstExpr (spec-state-expr-get state value-box)]
          (match (spec-rewrite-expr value templates state)
            [(ResultSpecExpr.Ok rewritten-value value-state)
              (begin
                (ast.ast-let-binding-list-push
                  out
                  (ast.ast-let-binding-id name ty rewritten-value))
                (spec-rewrite-let-bindings-at
                  bindings
                  (+ index 1)
                  (spec-template-env-shadow-name templates name)
                  value-state
                  out))]
            [(ResultSpecExpr.Err diag) (ResultSpecLetBindingListBuild.Err diag)]))])))

(define (spec-rewrite-match-arms
  [arms : ast.AstMatchArmList]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecMatchArmList
  (let
    [out : ast.AstMatchArmList
      (ast.ast-match-arm-list-with-capacity (struct-get (& arms) len))]
    (match (spec-rewrite-match-arms-at (& arms) 0 templates state (&mut out))
      [(ResultSpecMatchArmListBuild.Ok next-state)
        (ResultSpecMatchArmList.Ok out next-state)]
      [(ResultSpecMatchArmListBuild.Err diag) (ResultSpecMatchArmList.Err diag)])))

(define (spec-rewrite-match-arms-at
  [arms : (& arms ast.AstMatchArmList)]
  [index : i64]
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [out : (&mut out ast.AstMatchArmList)]) : ResultSpecMatchArmListBuild
  (if (>= index (struct-get arms len))
    (ResultSpecMatchArmListBuild.Ok state)
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm pattern body-box)
        (let
          [body : ast.AstExpr (spec-state-expr-get state body-box)]
          (match (spec-rewrite-expr
            body
            (spec-template-env-shadow-pattern templates pattern)
            state)
            [(ResultSpecExpr.Ok rewritten-body body-state)
              (begin
                (ast.ast-match-arm-list-push
                  out
                  (ast.ast-match-arm pattern rewritten-body))
                (spec-rewrite-match-arms-at
                  arms
                  (+ index 1)
                  templates
                  body-state
                  out))]
            [(ResultSpecExpr.Err diag) (ResultSpecMatchArmListBuild.Err diag)]))])))

(define (spec-rewrite-specialized-call
  [template : SpecTemplate]
  [args : ast.AstExprList]
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [origin : ast.AstExpr]) : ResultSpecExpr
  (match template
    [(SpecTemplate.Item name-id params _ _)
      (let
        [name : String
          (spec_ci.intern-compat-state-str (spec-state-intern state) name-id)]
        (match (spec-rewrite-specialized-args params args templates state name)
          [(ResultSpecArgs.Ok values runtime-args args-state)
            (match (spec-ensure-specialization
              template
              values
              templates
              args-state
              origin)
              [(ResultSpecEnsure.Ok specialized-name-id ensure-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-call-with-pools
                    (spec-state-pools state)
                    (spec-owner-expr-push
                      (spec-state-owner state)
                      (ast.AstExpr.Var specialized-name-id))
                    runtime-args)
                  ensure-state)]
              [(ResultSpecEnsure.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecArgs.Err diag) (ResultSpecExpr.Err diag)]))]))

(define (spec-rewrite-specialized-args
  [params : ast.AstParamList]
  [args : ast.AstExprList]
  [templates : SpecTemplateEnv]
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
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [fn-name : String]) : ResultSpecArgs
  (cond
    [(>= index (ast.ast-param-list-len params))
      (if (>= index (struct-get args len))
        (ResultSpecArgs.Ok (spec-value-list-new) (ast.ast-expr-list-new) state)
        (ResultSpecArgs.Err
          (box
            (cdiag.compiler-diagnostic-at-start "" "specialize: arity mismatch"))))]
    [(>= index (struct-get args len))
      (ResultSpecArgs.Err
        (box
          (cdiag.compiler-diagnostic-at-start "" "specialize: arity mismatch")))]
    [else
      (let
        [arg : ast.AstExpr
          (spec-state-expr-get state (ast.ast-expr-list-get args index 0))]
        (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
          [(ast.AstParam.Param param-name param-ty is-comptime _)
            (if is-comptime
              (match (spec-ctfe-eval state arg (ctfe.ctfe-fuel-limit))
                [(ctfe.ResultCtfe.Ok value _)
                  (if (spec-type-kind? param-ty)
                    (match value
                      [(ctfe.CompilerCtfeValue.Type _)
                        (match (spec-rewrite-specialized-args-at
                          params
                          args
                          (+ index 1)
                          templates
                          state
                          fn-name)
                          [(ResultSpecArgs.Ok
                              rest-values
                              rest-runtime
                              rest-state)
                            (ResultSpecArgs.Ok
                              (spec-value-cons value rest-values)
                              rest-runtime
                              rest-state)]
                          [(ResultSpecArgs.Err diag) (ResultSpecArgs.Err diag)])]
                      [_
                        (ResultSpecArgs.Err
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
                    (if (spec-value-runtime-type-matches? state value param-ty)
                      (match (spec-rewrite-specialized-args-at
                        params
                        args
                        (+ index 1)
                        templates
                        state
                        fn-name)
                        [(ResultSpecArgs.Ok rest-values rest-runtime rest-state)
                          (ResultSpecArgs.Ok
                            (spec-value-cons value rest-values)
                            rest-runtime
                            rest-state)]
                        [(ResultSpecArgs.Err diag) (ResultSpecArgs.Err diag)])
                      (ResultSpecArgs.Err
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
                [(ctfe.ResultCtfe.Err diag) (ResultSpecArgs.Err diag)])
              (match (spec-rewrite-expr arg templates state)
                [(ResultSpecExpr.Ok rewritten-arg arg-state)
                  (match (spec-rewrite-specialized-args-at
                    params
                    args
                    (+ index 1)
                    templates
                    arg-state
                    fn-name)
                    [(ResultSpecArgs.Ok values rest-runtime rest-state)
                      (ResultSpecArgs.Ok
                        values
                        (ast.ast-expr-cons rewritten-arg rest-runtime)
                        rest-state)]
                    [(ResultSpecArgs.Err diag) (ResultSpecArgs.Err diag)])]
                [(ResultSpecExpr.Err diag) (ResultSpecArgs.Err diag)]))]))]))

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
    (if (>= at (struct-get values len))
      (ResultSpecBuild.Ok
        (ast.ast-param-list-new)
        (spec-value-subst-new)
        (spec-type-subst-new))
      (ResultSpecBuild.Err
        (box
          (cdiag.compiler-diagnostic-at-start "" "specialize: value mismatch"))))
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param name ty is-comptime consume?)
        (if is-comptime
          (if (< at (struct-get values len))
            (let
              [value : ctfe.CompilerCtfeValue
                (array.ref (struct-get values slots) at)]
              (match (spec-build-specialization-at
                params
                (+ index 1)
                values
                (+ at 1))
                [(ResultSpecBuild.Ok runtime value-subs type-subs)
                  (if (spec-type-kind? ty)
                    (match value
                      [(ctfe.CompilerCtfeValue.Type actual-ty)
                        (ResultSpecBuild.Ok
                          runtime
                          value-subs
                          (spec-type-subst-cons name actual-ty type-subs))]
                      [_
                        (ResultSpecBuild.Err
                          (box
                            (cdiag.compiler-diagnostic-at-start
                              ""
                              "specialize: expected type value")))])
                    (ResultSpecBuild.Ok
                      runtime
                      (spec-value-subst-cons name value value-subs)
                      type-subs))]
                [(ResultSpecBuild.Err diag) (ResultSpecBuild.Err diag)]))
            (ResultSpecBuild.Err
              (box
                (cdiag.compiler-diagnostic-at-start
                  ""
                  "specialize: value mismatch"))))
          (match (spec-build-specialization-at params (+ index 1) values at)
            [(ResultSpecBuild.Ok runtime value-subs type-subs)
              (ResultSpecBuild.Ok
                (ast.ast-param-cons
                  (ast.AstParam.Param name ty false consume?)
                  runtime)
                value-subs
                type-subs)]
            [(ResultSpecBuild.Err diag) (ResultSpecBuild.Err diag)]))])))

;; AstDecl names carry generated ids allocated outside the source-name table.
(define (spec-materialize-generated-name-id [name : String]) : i64
  (spec_ci.intern-generated-name name))

(define (spec-ensure-specialization
  [template : SpecTemplate]
  [values : SpecValueList]
  [templates : SpecTemplateEnv]
  [state : SpecState (:consume)]
  [_origin : ast.AstExpr]) : ResultSpecEnsure
  (match template
    [(SpecTemplate.Item name-id params ret body)
      (match state
        [(SpecState.State generated cache ctfe-env pools)
          (let
            [name : String
              (spec_ci.intern-compat-state-str
                (spec-state-intern state)
                name-id)]
            [structural-key : SpecStructuralKey
              (spec-specialization-structural-key-with-owner
                (spec-state-owner state)
                name
                values)]
            [cache-key-id : i64 (spec-structural-key-raw structural-key)]
            (match (spec_id_i64_map.get (& cache) cache-key-id)
              [(spec_id_i64_map.LookupFound cached-name-id)
                (ResultSpecEnsure.Ok cached-name-id state)]
              [(spec_id_i64_map.LookupMissing)
                (let
                  [generated-name-id : i64
                    (spec-reserve-specialized-symbol-with-owner
                      pools
                      structural-key
                      name
                      values)]
                  (match (spec-build-specialization params values)
                    [(ResultSpecBuild.Ok runtime-params value-subs type-subs)
                      (match (spec-substitute-types-expr-with-owner
                        (spec-state-owner state)
                        body
                        type-subs)
                        [(ResultSpecSubExpr.Ok typed-body)
                          (match (spec-substitute-values-expr-with-owner
                            (spec-state-owner state)
                            (spec-state-expr-get state typed-body)
                            value-subs)
                            [(ResultSpecSubExpr.Ok valued-body)
                              (let
                                [next-cache : spec_id_i64_map.Map cache]
                                (begin
                                  (spec_id_i64_map.insert-ref!
                                    (&mut next-cache)
                                    cache-key-id
                                    generated-name-id)
                                  (let
                                    [cached-state : SpecState
                                      (SpecState.State
                                        generated
                                        next-cache
                                        ctfe-env
                                        pools)]
                                    (match (spec-rewrite-expr
                                      (spec-state-expr-get state valued-body)
                                      (spec-template-env-shadow-params
                                        templates
                                        runtime-params)
                                      cached-state)
                                      [(ResultSpecExpr.Ok
                                          rewritten-body
                                          rewritten-state)
                                        (match rewritten-state
                                          [(SpecState.State
                                              rewritten-generated
                                              rewritten-cache
                                              rewritten-ctfe-env
                                              rewritten-pools)
                                            (ResultSpecEnsure.Ok
                                              generated-name-id
                                              (SpecState.State
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
                                      [(ResultSpecExpr.Err diag)
                                        (ResultSpecEnsure.Err diag)]))))]
                            [(ResultSpecSubExpr.Err diag)
                              (ResultSpecEnsure.Err diag)])]
                        [(ResultSpecSubExpr.Err diag)
                          (ResultSpecEnsure.Err diag)])]
                    [(ResultSpecBuild.Err diag) (ResultSpecEnsure.Err diag)]))]))])]))

(define (spec-for-owned-state-exprs
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

(define (spec-for-owned-step-exprs
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

(define (spec-rewrite-expr
  [expr : ast.AstExpr]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecExpr
  (match expr
    [(ast.AstExpr.Spanned inner-box span)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten rewritten-state)
            (ResultSpecExpr.Ok
              (ast.ast-expr-spanned-with-pools
                (spec-state-pools state)
                rewritten
                span)
              rewritten-state)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.MacroExpansion inner-box provenance-id macro-name-id)
      (match (spec-rewrite-expr
        (spec-state-expr-get state inner-box)
        templates
        state)
        [(ResultSpecExpr.Ok rewritten rewritten-state)
          (ResultSpecExpr.Ok
            (spec-owner-expr-push
              (spec-state-owner rewritten-state)
              (ast.AstExpr.MacroExpansion rewritten provenance-id macro-name-id))
            rewritten-state)]
        [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
    [(ast.AstExpr.Literal _)
      (ResultSpecExpr.Ok
        (spec-owner-expr-push (spec-state-owner state) expr)
        state)]
    [(ast.AstExpr.Var _)
      (ResultSpecExpr.Ok
        (spec-owner-expr-push (spec-state-owner state) expr)
        state)]
    [(ast.AstExpr.TypeLiteral _)
      (ResultSpecExpr.Ok
        (spec-owner-expr-push (spec-state-owner state) expr)
        state)]
    [(ast.AstExpr.Init _)
      (ResultSpecExpr.Ok
        (spec-owner-expr-push (spec-state-owner state) expr)
        state)]
    [(ast.AstExpr.Binary op left-box right-box)
      (let
        [left : ast.AstExpr (spec-state-expr-get state left-box)]
        [right : ast.AstExpr (spec-state-expr-get state right-box)]
        (match (spec-rewrite-expr left templates state)
          [(ResultSpecExpr.Ok rewritten-left left-state)
            (match (spec-rewrite-expr right templates left-state)
              [(ResultSpecExpr.Ok rewritten-right right-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-binary-with-pools
                    (spec-state-pools state)
                    op
                    rewritten-left
                    rewritten-right)
                  right-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Unary op inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten rewritten-state)
            (ResultSpecExpr.Ok
              (ast.ast-expr-unary-with-pools
                (spec-state-pools state)
                op
                rewritten)
              rewritten-state)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Call func-box args)
      (let
        [func : ast.AstExpr (spec-state-expr-get state func-box)]
        (match (spec-expr-var-name-id-with-owner (spec-state-owner state) func)
          [(SpecMaybeId.Some name-id)
            (match (spec-template-lookup templates name-id)
              [(SpecMaybeTemplate.Some template)
                (spec-rewrite-specialized-call
                  template
                  args
                  templates
                  state
                  expr)]
              [(SpecMaybeTemplate.None)
                (match (spec-rewrite-expr func templates state)
                  [(ResultSpecExpr.Ok rewritten-func func-state)
                    (match (spec-rewrite-expr-list args templates func-state)
                      [(ResultSpecExprList.Ok rewritten-args args-state)
                        (ResultSpecExpr.Ok
                          (ast.ast-expr-call-with-pools
                            (spec-state-pools state)
                            rewritten-func
                            rewritten-args)
                          args-state)]
                      [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])])]
          [(SpecMaybeId.None)
            (match (spec-rewrite-expr func templates state)
              [(ResultSpecExpr.Ok rewritten-func func-state)
                (match (spec-rewrite-expr-list args templates func-state)
                  [(ResultSpecExprList.Ok rewritten-args args-state)
                    (ResultSpecExpr.Ok
                      (ast.ast-expr-call-with-pools
                        (spec-state-pools state)
                        rewritten-func
                        rewritten-args)
                      args-state)]
                  [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]))]
    [(ast.AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : ast.AstExpr (spec-state-expr-get state cond-box)]
        [then-branch : ast.AstExpr (spec-state-expr-get state then-branch-box)]
        [else-branch : ast.AstExpr (spec-state-expr-get state else-branch-box)]
        (match (spec-rewrite-expr cond templates state)
          [(ResultSpecExpr.Ok rewritten-cond cond-state)
            (match (spec-rewrite-expr then-branch templates cond-state)
              [(ResultSpecExpr.Ok rewritten-then then-state)
                (match (spec-rewrite-expr else-branch templates then-state)
                  [(ResultSpecExpr.Ok rewritten-else else-state)
                    (ResultSpecExpr.Ok
                      (ast.ast-expr-if-with-pools
                        (spec-state-pools state)
                        rewritten-cond
                        rewritten-then
                        rewritten-else)
                      else-state)]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Let let-box)
      (match (box-get let-box)
        [(ast.AstLet.Let bindings body-box)
          (let
            [body : ast.AstExpr (spec-state-expr-get state body-box)]
            (match (spec-rewrite-let-bindings bindings templates state)
              [(ResultSpecLetBindingList.Ok rewritten-bindings binding-state)
                (match (spec-rewrite-expr
                  body
                  (spec-template-env-shadow-let-binding-names
                    templates
                    bindings)
                  binding-state)
                  [(ResultSpecExpr.Ok rewritten-body body-state)
                    (ResultSpecExpr.Ok
                      (ast.ast-expr-let-with-pools
                        (spec-state-pools state)
                        rewritten-bindings
                        rewritten-body)
                      body-state)]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecLetBindingList.Err diag) (ResultSpecExpr.Err diag)]))])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(ast.AstLambda.Lambda params ret body-box)
          (let
            [body : ast.AstExpr (spec-state-expr-get state body-box)]
            (match (spec-rewrite-expr
              body
              (spec-template-env-shadow-params templates params)
              state)
              [(ResultSpecExpr.Ok rewritten-body body-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-lambda-with-pools
                    (spec-state-pools state)
                    params
                    ret
                    rewritten-body)
                  body-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))])]
    [(ast.AstExpr.Tuple exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok
            (spec-owner-expr-push
              (spec-state-owner state)
              (ast.AstExpr.Tuple rewritten))
            state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(ast.AstExpr.TupleRef inner-box index)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-tuple-ref-with-pools
                (spec-state-pools state)
                rewritten
                index)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Array exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok
            (spec-owner-expr-push
              (spec-state-owner state)
              (ast.AstExpr.Array rewritten))
            state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(ast.AstExpr.DynArray exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok
            (spec-owner-expr-push
              (spec-state-owner state)
              (ast.AstExpr.DynArray rewritten))
            state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(ast.AstExpr.MakeArray elem-ty-id len-box)
      (let
        [len : ast.AstExpr (spec-state-expr-get state len-box)]
        (match (spec-rewrite-expr len templates state)
          [(ResultSpecExpr.Ok rewritten-len state2)
            (ResultSpecExpr.Ok
              (spec-owner-expr-push
                (spec-state-owner state)
                (ast.AstExpr.MakeArray elem-ty-id rewritten-len))
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.ArrayRef array-box index-box)
      (let
        [array : ast.AstExpr (spec-state-expr-get state array-box)]
        [index : ast.AstExpr (spec-state-expr-get state index-box)]
        (match (spec-rewrite-expr array templates state)
          [(ResultSpecExpr.Ok rewritten-array array-state)
            (match (spec-rewrite-expr index templates array-state)
              [(ResultSpecExpr.Ok rewritten-index index-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-array-ref-with-pools
                    (spec-state-pools state)
                    rewritten-array
                    rewritten-index)
                  index-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.ArraySet array-box index-box value-box)
      (let
        [array : ast.AstExpr (spec-state-expr-get state array-box)]
        [index : ast.AstExpr (spec-state-expr-get state index-box)]
        [value : ast.AstExpr (spec-state-expr-get state value-box)]
        (match (spec-rewrite-expr array templates state)
          [(ResultSpecExpr.Ok rewritten-array array-state)
            (match (spec-rewrite-expr index templates array-state)
              [(ResultSpecExpr.Ok rewritten-index index-state)
                (match (spec-rewrite-expr value templates index-state)
                  [(ResultSpecExpr.Ok rewritten-value value-state)
                    (ResultSpecExpr.Ok
                      (ast.ast-expr-array-set-with-pools
                        (spec-state-pools state)
                        rewritten-array
                        rewritten-index
                        rewritten-value)
                      value-state)]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.ArrayTake array-box live-box index-box)
      (let
        [array : ast.AstExpr (spec-state-expr-get state array-box)]
        [live : ast.AstExpr (spec-state-expr-get state live-box)]
        [index : ast.AstExpr (spec-state-expr-get state index-box)]
        (match (spec-rewrite-expr array templates state)
          [(ResultSpecExpr.Ok rewritten-array array-state)
            (match (spec-rewrite-expr live templates array-state)
              [(ResultSpecExpr.Ok rewritten-live live-state)
                (match (spec-rewrite-expr index templates live-state)
                  [(ResultSpecExpr.Ok rewritten-index index-state)
                    (ResultSpecExpr.Ok
                      (ast.ast-expr-array-take-with-pools
                        (spec-state-pools state)
                        rewritten-array
                        rewritten-live
                        rewritten-index)
                      index-state)]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.FixedArrayTake array-box index-box)
      (let
        [array : ast.AstExpr (spec-state-expr-get state array-box)]
        [index : ast.AstExpr (spec-state-expr-get state index-box)]
        (match (spec-rewrite-expr array templates state)
          [(ResultSpecExpr.Ok rewritten-array array-state)
            (match (spec-rewrite-expr index templates array-state)
              [(ResultSpecExpr.Ok rewritten-index index-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-fixed-array-take-with-pools
                    (spec-state-pools state)
                    rewritten-array
                    rewritten-index)
                  index-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.ArrayPush array-box value-box)
      (let
        [array : ast.AstExpr (spec-state-expr-get state array-box)]
        [value : ast.AstExpr (spec-state-expr-get state value-box)]
        (match (spec-rewrite-expr array templates state)
          [(ResultSpecExpr.Ok rewritten-array array-state)
            (match (spec-rewrite-expr value templates array-state)
              [(ResultSpecExpr.Ok rewritten-value value-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-array-push-with-pools
                    (spec-state-pools state)
                    rewritten-array
                    rewritten-value)
                  value-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.StringRef text-box index-box)
      (let
        [text : ast.AstExpr (spec-state-expr-get state text-box)]
        [index : ast.AstExpr (spec-state-expr-get state index-box)]
        (match (spec-rewrite-expr text templates state)
          [(ResultSpecExpr.Ok rewritten-text text-state)
            (match (spec-rewrite-expr index templates text-state)
              [(ResultSpecExpr.Ok rewritten-index index-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-string-ref-with-pools
                    (spec-state-pools state)
                    rewritten-text
                    rewritten-index)
                  index-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.While cond-box body-box)
      (let
        [cond : ast.AstExpr (spec-state-expr-get state cond-box)]
        [body : ast.AstExpr (spec-state-expr-get state body-box)]
        (match (spec-rewrite-expr cond templates state)
          [(ResultSpecExpr.Ok rewritten-cond cond-state)
            (match (spec-rewrite-expr body templates cond-state)
              [(ResultSpecExpr.Ok rewritten-body body-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-while-with-pools
                    (spec-state-pools state)
                    rewritten-cond
                    rewritten-body)
                  body-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.ForOwnedState payload)
      (match (spec-rewrite-expr-list
        (spec-for-owned-state-exprs
          (ast.ast-for-owned-state-source-name (& payload))
          (ast.ast-for-owned-state-index-name (& payload))
          (ast.ast-for-owned-state-source (& payload))
          (ast.ast-for-owned-state-body (& payload)))
        templates
        state)
        [(ResultSpecExprList.Ok rewritten rewritten-state)
          (ResultSpecExpr.Ok
            (ast.ast-expr-for-owned-state-with-pools
              (spec-state-pools state)
              (ast.ast-expr-list-get (& rewritten) 0 0)
              (ast.ast-expr-list-get (& rewritten) 1 0)
              (ast.ast-expr-list-get (& rewritten) 2 0)
              (ast.ast-expr-list-get (& rewritten) 3 0))
            rewritten-state)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(ast.AstExpr.ForOwnedStep payload)
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
          state)
          [(ResultSpecExprList.Ok rewritten rewritten-state)
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
              (ResultSpecExpr.Ok
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
          [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Begin exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok
            (spec-owner-expr-push
              (spec-state-owner state)
              (ast.AstExpr.Begin rewritten))
            state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(ast.AstExpr.Unsafe exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok
            (spec-owner-expr-push
              (spec-state-owner state)
              (ast.AstExpr.Unsafe rewritten))
            state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(ast.AstExpr.Set name value-box)
      (let
        [value : ast.AstExpr (spec-state-expr-get state value-box)]
        (match (spec-rewrite-expr value templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-set-id-with-pools
                (spec-state-pools state)
                name
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Ann inner-box ty-id)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-ann-with-pools-id
                (spec-state-pools state)
                rewritten
                ty-id)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Cast inner-box ty-id)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-cast-with-pools-id
                (spec-state-pools state)
                rewritten
                ty-id)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Match match-box)
      (match (box-get match-box)
        [(ast.AstMatch.Match scrutinee-box arms)
          (let
            [scrutinee : ast.AstExpr (spec-state-expr-get state scrutinee-box)]
            (match (spec-rewrite-expr scrutinee templates state)
              [(ResultSpecExpr.Ok rewritten-scrutinee scrutinee-state)
                (match (spec-rewrite-match-arms arms templates scrutinee-state)
                  [(ResultSpecMatchArmList.Ok rewritten-arms arms-state)
                    (ResultSpecExpr.Ok
                      (ast.ast-expr-match-with-pools
                        (spec-state-pools state)
                        rewritten-scrutinee
                        rewritten-arms)
                      arms-state)]
                  [(ResultSpecMatchArmList.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))])]
    [(ast.AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(ast.AstForeach.Foreach index index-ty start-box end-box body-box)
          (let
            [start : ast.AstExpr (spec-state-expr-get state start-box)]
            [end : ast.AstExpr (spec-state-expr-get state end-box)]
            [body : ast.AstExpr (spec-state-expr-get state body-box)]
            (match (spec-rewrite-expr start templates state)
              [(ResultSpecExpr.Ok rewritten-start start-state)
                (match (spec-rewrite-expr end templates start-state)
                  [(ResultSpecExpr.Ok rewritten-end end-state)
                    (match (spec-rewrite-expr
                      body
                      (spec-template-env-shadow-name templates index)
                      end-state)
                      [(ResultSpecExpr.Ok rewritten-body body-state)
                        (ResultSpecExpr.Ok
                          (ast.ast-expr-foreach-id-with-pools
                            (spec-state-pools state)
                            index
                            index-ty
                            rewritten-start
                            rewritten-end
                            rewritten-body)
                          body-state)]
                      [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(ast.AstSpmdReduce.Reduce
            op
            index
            index-ty
            start-box
            end-box
            init-box
            value-box)
          (let
            [start : ast.AstExpr (spec-state-expr-get state start-box)]
            [end : ast.AstExpr (spec-state-expr-get state end-box)]
            [init : ast.AstExpr (spec-state-expr-get state init-box)]
            [value : ast.AstExpr (spec-state-expr-get state value-box)]
            (match (spec-rewrite-expr start templates state)
              [(ResultSpecExpr.Ok rewritten-start start-state)
                (match (spec-rewrite-expr end templates start-state)
                  [(ResultSpecExpr.Ok rewritten-end end-state)
                    (match (spec-rewrite-expr init templates end-state)
                      [(ResultSpecExpr.Ok rewritten-init init-state)
                        (match (spec-rewrite-expr
                          value
                          (spec-template-env-shadow-name templates index)
                          init-state)
                          [(ResultSpecExpr.Ok rewritten-value value-state)
                            (ResultSpecExpr.Ok
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
                          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
                      [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))])]
    [(ast.AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
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
            [start : ast.AstExpr (spec-state-expr-get state start-box)]
            [end : ast.AstExpr (spec-state-expr-get state end-box)]
            [init : ast.AstExpr (spec-state-expr-get state init-box)]
            [value : ast.AstExpr (spec-state-expr-get state value-box)]
            [body : ast.AstExpr (spec-state-expr-get state body-box)]
            [value-templates : SpecTemplateEnv
              (spec-template-env-shadow-name templates index)]
            [body-templates : SpecTemplateEnv
              (spec-template-env-shadow-name value-templates prefix)]
            (match (spec-rewrite-expr start templates state)
              [(ResultSpecExpr.Ok rewritten-start start-state)
                (match (spec-rewrite-expr end templates start-state)
                  [(ResultSpecExpr.Ok rewritten-end end-state)
                    (match (spec-rewrite-expr init templates end-state)
                      [(ResultSpecExpr.Ok rewritten-init init-state)
                        (match (spec-rewrite-expr
                          value
                          value-templates
                          init-state)
                          [(ResultSpecExpr.Ok rewritten-value value-state)
                            (match (spec-rewrite-expr
                              body
                              body-templates
                              value-state)
                              [(ResultSpecExpr.Ok rewritten-body body-state)
                                (ResultSpecExpr.Ok
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
                              [(ResultSpecExpr.Err diag)
                                (ResultSpecExpr.Err diag)])]
                          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
                      [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))])]
    [(ast.AstExpr.SpmdBroadcast value-box lane-box)
      (let
        [value : ast.AstExpr (spec-state-expr-get state value-box)]
        [lane : ast.AstExpr (spec-state-expr-get state lane-box)]
        (match (spec-rewrite-expr value templates state)
          [(ResultSpecExpr.Ok rewritten-value value-state)
            (match (spec-rewrite-expr lane templates value-state)
              [(ResultSpecExpr.Ok rewritten-lane lane-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-spmd-broadcast-with-pools
                    (spec-state-pools state)
                    rewritten-value
                    rewritten-lane)
                  lane-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.SpmdShuffle value-box lane-box)
      (let
        [value : ast.AstExpr (spec-state-expr-get state value-box)]
        [lane : ast.AstExpr (spec-state-expr-get state lane-box)]
        (match (spec-rewrite-expr value templates state)
          [(ResultSpecExpr.Ok rewritten-value value-state)
            (match (spec-rewrite-expr lane templates value-state)
              [(ResultSpecExpr.Ok rewritten-lane lane-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-spmd-shuffle-with-pools
                    (spec-state-pools state)
                    rewritten-value
                    rewritten-lane)
                  lane-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.StructGet receiver-box field)
      (let
        [receiver : ast.AstExpr (spec-state-expr-get state receiver-box)]
        (match (spec-rewrite-expr receiver templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-struct-get-id-with-pools
                (spec-state-pools state)
                rewritten
                field)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.StructSet receiver-box field value-box)
      (let
        [receiver : ast.AstExpr (spec-state-expr-get state receiver-box)]
        [value : ast.AstExpr (spec-state-expr-get state value-box)]
        (match (spec-rewrite-expr receiver templates state)
          [(ResultSpecExpr.Ok rewritten-receiver receiver-state)
            (match (spec-rewrite-expr value templates receiver-state)
              [(ResultSpecExpr.Ok rewritten-value value-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-struct-set-id-with-pools
                    (spec-state-pools state)
                    rewritten-receiver
                    field
                    rewritten-value)
                  value-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.WithRegion region body)
      (match (spec-rewrite-expr-list body templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok
            (spec-owner-expr-push
              (spec-state-owner state)
              (ast.AstExpr.WithRegion region rewritten))
            state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(ast.AstExpr.WithEscape scratch-box body)
      (let
        [scratch : ast.AstExpr (spec-state-expr-get state scratch-box)]
        (match (spec-rewrite-expr scratch templates state)
          [(ResultSpecExpr.Ok rewritten-scratch scratch-state)
            (match (spec-rewrite-expr-list body templates scratch-state)
              [(ResultSpecExprList.Ok rewritten-body body-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-with-escape-with-pools
                    (spec-state-pools state)
                    rewritten-scratch
                    rewritten-body)
                  body-state)]
              [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.WithScratch body)
      (match (spec-rewrite-expr-list body templates state)
        [(ResultSpecExprList.Ok rewritten-body body-state)
          (ResultSpecExpr.Ok
            (ast.ast-expr-with-scratch-with-pools
              (spec-state-pools state)
              rewritten-body)
            body-state)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(ast.AstExpr.InArena arena-box body)
      (let
        [arena : ast.AstExpr (spec-state-expr-get state arena-box)]
        (match (spec-rewrite-expr arena templates state)
          [(ResultSpecExpr.Ok rewritten-arena arena-state)
            (match (spec-rewrite-expr-list body templates arena-state)
              [(ResultSpecExprList.Ok rewritten-body body-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-in-arena-with-pools
                    (spec-state-pools state)
                    rewritten-arena
                    rewritten-body)
                  body-state)]
              [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (ResultSpecExpr.Ok
            (spec-owner-expr-push
              (spec-state-owner state)
              (ast.AstExpr.WithResource
                (box (ast.AstWithResource.WithResource bindings body))))
            state)])]
    [(ast.AstExpr.Box inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-box-with-pools (spec-state-pools state) rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.BoxGet inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-box-get-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.BoxTake inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-box-take-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.BoxSet inner-box value-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        [value : ast.AstExpr (spec-state-expr-get state value-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten-inner inner-state)
            (match (spec-rewrite-expr value templates inner-state)
              [(ResultSpecExpr.Ok rewritten-value value-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-box-set-with-pools
                    (spec-state-pools state)
                    rewritten-inner
                    rewritten-value)
                  value-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Comptime inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-comptime-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Try inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-try-with-pools (spec-state-pools state) rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Return inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-return-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Break)
      (ResultSpecExpr.Ok
        (ast.ast-expr-break-with-pools (spec-state-pools state))
        state)]
    [(ast.AstExpr.Continue)
      (ResultSpecExpr.Ok
        (ast.ast-expr-continue-with-pools (spec-state-pools state))
        state)]
    [(ast.AstExpr.PtrNull ty-id)
      (ResultSpecExpr.Ok
        (spec-owner-expr-push
          (spec-state-owner state)
          (ast.AstExpr.PtrNull ty-id))
        state)]
    [(ast.AstExpr.PtrNullCheck inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-ptr-null-check-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.PtrAddrOf place-box)
      (let
        [place : ast.AstExpr (spec-state-expr-get state place-box)]
        (match (spec-rewrite-expr place templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-ptr-addr-of-id-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.PtrRead ptr-box)
      (let
        [ptr : ast.AstExpr (spec-state-expr-get state ptr-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-ptr-read-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.PtrWrite ptr-box value-box)
      (let
        [ptr : ast.AstExpr (spec-state-expr-get state ptr-box)]
        [value : ast.AstExpr (spec-state-expr-get state value-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(ResultSpecExpr.Ok rewritten-ptr ptr-state)
            (match (spec-rewrite-expr value templates ptr-state)
              [(ResultSpecExpr.Ok rewritten-value value-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-ptr-write-with-pools
                    (spec-state-pools state)
                    rewritten-ptr
                    rewritten-value)
                  value-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.PtrOffset ptr-box offset-box)
      (let
        [ptr : ast.AstExpr (spec-state-expr-get state ptr-box)]
        [offset : ast.AstExpr (spec-state-expr-get state offset-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(ResultSpecExpr.Ok rewritten-ptr ptr-state)
            (match (spec-rewrite-expr offset templates ptr-state)
              [(ResultSpecExpr.Ok rewritten-offset offset-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-ptr-offset-with-pools
                    (spec-state-pools state)
                    rewritten-ptr
                    rewritten-offset)
                  offset-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.PtrCast ptr-box ty-id)
      (let
        [ptr : ast.AstExpr (spec-state-expr-get state ptr-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (spec-owner-expr-push
                (spec-state-owner state)
                (ast.AstExpr.PtrCast rewritten ty-id))
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.PtrToInt ptr-box)
      (let
        [ptr : ast.AstExpr (spec-state-expr-get state ptr-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-ptr-to-int-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.IntToPtr value-box ty-id)
      (let
        [value : ast.AstExpr (spec-state-expr-get state value-box)]
        (match (spec-rewrite-expr value templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (spec-owner-expr-push
                (spec-state-owner state)
                (ast.AstExpr.IntToPtr rewritten ty-id))
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.StringData inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-string-data-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.StringFromBytes ptr-box len-box)
      (let
        [ptr : ast.AstExpr (spec-state-expr-get state ptr-box)]
        [len : ast.AstExpr (spec-state-expr-get state len-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(ResultSpecExpr.Ok rewritten-ptr ptr-state)
            (match (spec-rewrite-expr len templates ptr-state)
              [(ResultSpecExpr.Ok rewritten-len len-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-string-from-bytes-with-pools
                    (spec-state-pools state)
                    rewritten-ptr
                    rewritten-len)
                  len-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.ArrayData inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-array-data-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.BinaryData bytes)
      (ResultSpecExpr.Ok
        (spec-owner-expr-push
          (spec-state-owner state)
          (ast.AstExpr.BinaryData bytes))
        state)]
    [(ast.AstExpr.SpmdProgramIndex)
      (ResultSpecExpr.Ok
        (ast.ast-expr-spmd-program-index-with-pools (spec-state-pools state))
        state)]
    [(ast.AstExpr.SpmdProgramCount)
      (ResultSpecExpr.Ok
        (ast.ast-expr-spmd-program-count-with-pools (spec-state-pools state))
        state)]
    [(ast.AstExpr.ProgramArgc)
      (ResultSpecExpr.Ok
        (spec-owner-expr-push
          (spec-state-owner state)
          (ast.AstExpr.ProgramArgc))
        state)]
    [(ast.AstExpr.ProgramArgv)
      (ResultSpecExpr.Ok
        (spec-owner-expr-push
          (spec-state-owner state)
          (ast.AstExpr.ProgramArgv))
        state)]
    [(ast.AstExpr.ProgramEnvp)
      (ResultSpecExpr.Ok
        (spec-owner-expr-push
          (spec-state-owner state)
          (ast.AstExpr.ProgramEnvp))
        state)]
    [(ast.AstExpr.CpuIdEax leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (spec-state-expr-get state leaf-box)]
        [subleaf : ast.AstExpr (spec-state-expr-get state subleaf-box)]
        (match (spec-rewrite-expr leaf templates state)
          [(ResultSpecExpr.Ok rewritten-leaf leaf-state)
            (match (spec-rewrite-expr subleaf templates leaf-state)
              [(ResultSpecExpr.Ok rewritten-subleaf subleaf-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-cpuid-eax-with-pools
                    (spec-state-pools state)
                    rewritten-leaf
                    rewritten-subleaf)
                  subleaf-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.CpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (spec-state-expr-get state leaf-box)]
        [subleaf : ast.AstExpr (spec-state-expr-get state subleaf-box)]
        (match (spec-rewrite-expr leaf templates state)
          [(ResultSpecExpr.Ok rewritten-leaf leaf-state)
            (match (spec-rewrite-expr subleaf templates leaf-state)
              [(ResultSpecExpr.Ok rewritten-subleaf subleaf-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-cpuid-ebx-with-pools
                    (spec-state-pools state)
                    rewritten-leaf
                    rewritten-subleaf)
                  subleaf-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.CpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (spec-state-expr-get state leaf-box)]
        [subleaf : ast.AstExpr (spec-state-expr-get state subleaf-box)]
        (match (spec-rewrite-expr leaf templates state)
          [(ResultSpecExpr.Ok rewritten-leaf leaf-state)
            (match (spec-rewrite-expr subleaf templates leaf-state)
              [(ResultSpecExpr.Ok rewritten-subleaf subleaf-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-cpuid-ecx-with-pools
                    (spec-state-pools state)
                    rewritten-leaf
                    rewritten-subleaf)
                  subleaf-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.CpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (spec-state-expr-get state leaf-box)]
        [subleaf : ast.AstExpr (spec-state-expr-get state subleaf-box)]
        (match (spec-rewrite-expr leaf templates state)
          [(ResultSpecExpr.Ok rewritten-leaf leaf-state)
            (match (spec-rewrite-expr subleaf templates leaf-state)
              [(ResultSpecExpr.Ok rewritten-subleaf subleaf-state)
                (ResultSpecExpr.Ok
                  (ast.ast-expr-cpuid-edx-with-pools
                    (spec-state-pools state)
                    rewritten-leaf
                    rewritten-subleaf)
                  subleaf-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Xgetbv index-box)
      (let
        [index : ast.AstExpr (spec-state-expr-get state index-box)]
        (match (spec-rewrite-expr index templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-xgetbv-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Syscall args)
      (match (spec-rewrite-expr-list args templates state)
        [(ResultSpecExprList.Ok rewritten-args args-state)
          (ResultSpecExpr.Ok
            (ast.ast-expr-syscall-with-pools
              (spec-state-pools state)
              rewritten-args)
            args-state)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(ast.AstExpr.Quote inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-quote-with-pools (spec-state-pools state) rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Quasiquote inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-quasiquote-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.Unquote inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-unquote-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.UnquoteSplicing inner-box)
      (let
        [inner : ast.AstExpr (spec-state-expr-get state inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok
              (ast.ast-expr-unquote-splicing-with-pools
                (spec-state-pools state)
                rewritten)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(ast.AstExpr.BracketClause items)
      (match (spec-rewrite-expr-list items templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok
            (ast.ast-expr-bracket-clause-with-pools
              (spec-state-pools state)
              rewritten)
            state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(ast.AstExpr.Borrow _ _ _)
      (ResultSpecExpr.Ok
        (spec-owner-expr-push (spec-state-owner state) expr)
        state)]))

(define (spec-ptr-addr-of-place-value-conflict-with-owner
  [owner : SpecOwnerContext]
  [place : ast.AstExpr]
  [subs : SpecValueSubst]) : SpecMaybeId
  (match (ast.ast-expr-unspan-with-pools (spec-owner-pools owner) place)
    [(ast.AstExpr.Var name) (spec-value-subst-lookup subs name)]
    [(ast.AstExpr.StructGet receiver-box _)
      (spec-ptr-addr-of-place-value-conflict-with-owner
        owner
        (spec-owner-expr-get owner receiver-box)
        subs)]
    [(ast.AstExpr.ArrayRef array-box _)
      (spec-ptr-addr-of-place-value-conflict-with-owner
        owner
        (spec-owner-expr-get owner array-box)
        subs)]
    [_ (SpecMaybeId.None)]))

(define (spec-substitute-values-expr-with-owner
  [owner : SpecOwnerContext]
  [expr : ast.AstExpr]
  [subs : SpecValueSubst]) : ResultSpecSubExpr
  (match expr
    [(ast.AstExpr.Spanned inner-box span)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-spanned-with-pools
                (spec-owner-pools owner)
                rewritten
                span))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.MacroExpansion inner-box provenance-id macro-name-id)
      (match (spec-substitute-values-expr-with-owner
        owner
        (spec-owner-expr-get owner inner-box)
        subs)
        [(ResultSpecSubExpr.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push
              owner
              (ast.AstExpr.MacroExpansion rewritten provenance-id macro-name-id)))]
        [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.ArrayTake array-box live-box index-box)
      (let
        [array : ast.AstExpr (spec-owner-expr-get owner array-box)]
        [live : ast.AstExpr (spec-owner-expr-get owner live-box)]
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        (match (spec-substitute-values-expr-with-owner owner array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-values-expr-with-owner owner live subs)
              [(ResultSpecSubExpr.Ok rewritten-live)
                (match (spec-substitute-values-expr-with-owner owner index subs)
                  [(ResultSpecSubExpr.Ok rewritten-index)
                    (ResultSpecSubExpr.Ok
                      (ast.ast-expr-array-take-with-pools
                        (spec-owner-pools owner)
                        rewritten-array
                        rewritten-live
                        rewritten-index))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.FixedArrayTake array-box index-box)
      (let
        [array : ast.AstExpr (spec-owner-expr-get owner array-box)]
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        (match (spec-substitute-values-expr-with-owner owner array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-values-expr-with-owner owner index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-fixed-array-take-with-pools
                    (spec-owner-pools owner)
                    rewritten-array
                    rewritten-index))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Var name)
      (match (spec-value-subst-lookup subs name)
        [(SpecMaybeId.Some _)
          (spec-ctfe-value-to-expr-with-owner
            owner
            (spec-value-subst-value subs name)
            expr)]
        [(SpecMaybeId.None)
          (ResultSpecSubExpr.Ok (spec-owner-expr-push owner expr))])]
    [(ast.AstExpr.Literal _)
      (ResultSpecSubExpr.Ok (spec-owner-expr-push owner expr))]
    [(ast.AstExpr.TypeLiteral _)
      (ResultSpecSubExpr.Ok (spec-owner-expr-push owner expr))]
    [(ast.AstExpr.Init _)
      (ResultSpecSubExpr.Ok (spec-owner-expr-push owner expr))]
    [(ast.AstExpr.Binary op left-box right-box)
      (let
        [left : ast.AstExpr (spec-owner-expr-get owner left-box)]
        [right : ast.AstExpr (spec-owner-expr-get owner right-box)]
        (match (spec-substitute-values-expr-with-owner owner left subs)
          [(ResultSpecSubExpr.Ok rewritten-left)
            (match (spec-substitute-values-expr-with-owner owner right subs)
              [(ResultSpecSubExpr.Ok rewritten-right)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-binary-with-pools
                    (spec-owner-pools owner)
                    op
                    rewritten-left
                    rewritten-right))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Unary op inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-unary-with-pools
                (spec-owner-pools owner)
                op
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Call func-box args)
      (let
        [func : ast.AstExpr (spec-owner-expr-get owner func-box)]
        (match (spec-substitute-values-expr-with-owner owner func subs)
          [(ResultSpecSubExpr.Ok rewritten-func)
            (match (spec-substitute-values-expr-list-with-owner owner args subs)
              [(ResultSpecSubExprList.Ok rewritten-args)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-call-with-pools
                    (spec-owner-pools owner)
                    rewritten-func
                    rewritten-args))]
              [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : ast.AstExpr (spec-owner-expr-get owner cond-box)]
        [then-branch : ast.AstExpr (spec-owner-expr-get owner then-branch-box)]
        [else-branch : ast.AstExpr (spec-owner-expr-get owner else-branch-box)]
        (match (spec-substitute-values-expr-with-owner owner cond subs)
          [(ResultSpecSubExpr.Ok rewritten-cond)
            (match (spec-substitute-values-expr-with-owner
              owner
              then-branch
              subs)
              [(ResultSpecSubExpr.Ok rewritten-then)
                (match (spec-substitute-values-expr-with-owner
                  owner
                  else-branch
                  subs)
                  [(ResultSpecSubExpr.Ok rewritten-else)
                    (ResultSpecSubExpr.Ok
                      (ast.ast-expr-if-with-pools
                        (spec-owner-pools owner)
                        rewritten-cond
                        rewritten-then
                        rewritten-else))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Let let-box)
      (match (box-get let-box)
        [(ast.AstLet.Let bindings body-box)
          (let
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            (match (spec-substitute-values-let-bindings-with-owner
              owner
              bindings
              subs)
              [(ResultSpecSubLetBindingList.Ok rewritten-bindings)
                (match (spec-substitute-values-expr-with-owner
                  owner
                  body
                  (spec-value-subst-remove-let-binding-names subs bindings))
                  [(ResultSpecSubExpr.Ok rewritten-body)
                    (ResultSpecSubExpr.Ok
                      (ast.ast-expr-let-with-pools
                        (spec-owner-pools owner)
                        rewritten-bindings
                        rewritten-body))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubLetBindingList.Err diag)
                (ResultSpecSubExpr.Err diag)]))])]
    [(ast.AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(ast.AstLambda.Lambda params ret body-box)
          (let
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            (match (spec-substitute-values-expr-with-owner
              owner
              body
              (spec-value-subst-remove-params subs params))
              [(ResultSpecSubExpr.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-lambda-with-pools
                    (spec-owner-pools owner)
                    params
                    ret
                    rewritten-body))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(ast.AstExpr.Tuple exprs)
      (match (spec-substitute-values-expr-list-with-owner owner exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push owner (ast.AstExpr.Tuple rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.TupleRef inner-box index)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-tuple-ref-with-pools
                (spec-owner-pools owner)
                rewritten
                index))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Array exprs)
      (match (spec-substitute-values-expr-list-with-owner owner exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push owner (ast.AstExpr.Array rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.DynArray exprs)
      (match (spec-substitute-values-expr-list-with-owner owner exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push owner (ast.AstExpr.DynArray rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.MakeArray elem-ty-id len-box)
      (let
        [len : ast.AstExpr (spec-owner-expr-get owner len-box)]
        (match (spec-substitute-values-expr-with-owner owner len subs)
          [(ResultSpecSubExpr.Ok rewritten-len)
            (ResultSpecSubExpr.Ok
              (spec-owner-expr-push
                owner
                (ast.AstExpr.MakeArray elem-ty-id rewritten-len)))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.ArrayRef array-box index-box)
      (let
        [array : ast.AstExpr (spec-owner-expr-get owner array-box)]
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        (match (spec-substitute-values-expr-with-owner owner array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-values-expr-with-owner owner index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-array-ref-with-pools
                    (spec-owner-pools owner)
                    rewritten-array
                    rewritten-index))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.ArraySet array-box index-box value-box)
      (let
        [array : ast.AstExpr (spec-owner-expr-get owner array-box)]
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-substitute-values-expr-with-owner owner array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-values-expr-with-owner owner index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (match (spec-substitute-values-expr-with-owner owner value subs)
                  [(ResultSpecSubExpr.Ok rewritten-value)
                    (ResultSpecSubExpr.Ok
                      (ast.ast-expr-array-set-with-pools
                        (spec-owner-pools owner)
                        rewritten-array
                        rewritten-index
                        rewritten-value))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.ArrayTake array-box live-box index-box)
      (let
        [array : ast.AstExpr (spec-owner-expr-get owner array-box)]
        [live : ast.AstExpr (spec-owner-expr-get owner live-box)]
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        (match (spec-substitute-values-expr-with-owner owner array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-values-expr-with-owner owner live subs)
              [(ResultSpecSubExpr.Ok rewritten-live)
                (match (spec-substitute-values-expr-with-owner owner index subs)
                  [(ResultSpecSubExpr.Ok rewritten-index)
                    (ResultSpecSubExpr.Ok
                      (ast.ast-expr-array-take-with-pools
                        (spec-owner-pools owner)
                        rewritten-array
                        rewritten-live
                        rewritten-index))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.FixedArrayTake array-box index-box)
      (let
        [array : ast.AstExpr (spec-owner-expr-get owner array-box)]
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        (match (spec-substitute-values-expr-with-owner owner array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-values-expr-with-owner owner index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-fixed-array-take-with-pools
                    (spec-owner-pools owner)
                    rewritten-array
                    rewritten-index))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.ArrayPush array-box value-box)
      (let
        [array : ast.AstExpr (spec-owner-expr-get owner array-box)]
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-substitute-values-expr-with-owner owner array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-values-expr-with-owner owner value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-array-push-with-pools
                    (spec-owner-pools owner)
                    rewritten-array
                    rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.StringRef text-box index-box)
      (let
        [text : ast.AstExpr (spec-owner-expr-get owner text-box)]
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        (match (spec-substitute-values-expr-with-owner owner text subs)
          [(ResultSpecSubExpr.Ok rewritten-text)
            (match (spec-substitute-values-expr-with-owner owner index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-string-ref-with-pools
                    (spec-owner-pools owner)
                    rewritten-text
                    rewritten-index))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.While cond-box body-box)
      (let
        [cond : ast.AstExpr (spec-owner-expr-get owner cond-box)]
        [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
        (match (spec-substitute-values-expr-with-owner owner cond subs)
          [(ResultSpecSubExpr.Ok rewritten-cond)
            (match (spec-substitute-values-expr-with-owner owner body subs)
              [(ResultSpecSubExpr.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-while-with-pools
                    (spec-owner-pools owner)
                    rewritten-cond
                    rewritten-body))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.ForOwnedState payload)
      (match (spec-substitute-values-expr-list-with-owner
        owner
        (spec-for-owned-state-exprs
          (ast.ast-for-owned-state-source-name (& payload))
          (ast.ast-for-owned-state-index-name (& payload))
          (ast.ast-for-owned-state-source (& payload))
          (ast.ast-for-owned-state-body (& payload)))
        subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (ast.ast-expr-for-owned-state-with-pools
              (spec-owner-pools owner)
              (ast.ast-expr-list-get (& rewritten) 0 0)
              (ast.ast-expr-list-get (& rewritten) 1 0)
              (ast.ast-expr-list-get (& rewritten) 2 0)
              (ast.ast-expr-list-get (& rewritten) 3 0)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        (match (spec-substitute-values-expr-list-with-owner
          owner
          (spec-for-owned-step-exprs
            (ast.ast-for-owned-step-source-name (& payload))
            (ast.ast-for-owned-step-index-name (& payload))
            (ast.ast-for-owned-step-binding-name (& payload))
            expected-type
            (ast.ast-for-owned-step-done-name (& payload))
            (ast.ast-for-owned-step-body (& payload)))
          subs)
          [(ResultSpecSubExprList.Ok rewritten)
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
              (ResultSpecSubExpr.Ok
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
          [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Begin exprs)
      (match (spec-substitute-values-expr-list-with-owner owner exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push owner (ast.AstExpr.Begin rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.Unsafe exprs)
      (match (spec-substitute-values-expr-list-with-owner owner exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push owner (ast.AstExpr.Unsafe rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.Set name value-box)
      (let
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-value-subst-lookup subs name)
          [(SpecMaybeId.Some _)
            (ResultSpecSubExpr.Err
              (box
                (spec-diagnostic-at-expr
                  expr
                  (str_cat.str-cat
                    "cannot assign to comptime parameter '"
                    (spec_ci.intern-compat-state-str
                      (spec-owner-intern-state owner)
                      name)
                    "'"))))]
          [(SpecMaybeId.None)
            (match (spec-substitute-values-expr-with-owner owner value subs)
              [(ResultSpecSubExpr.Ok rewritten)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-set-id-with-pools
                    (spec-owner-pools owner)
                    name
                    rewritten))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]))]
    [(ast.AstExpr.Ann inner-box ty-id)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-ann-with-pools-id
                (spec-owner-pools owner)
                rewritten
                ty-id))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Cast inner-box ty-id)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-cast-with-pools-id
                (spec-owner-pools owner)
                rewritten
                ty-id))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Match match-box)
      (match (box-get match-box)
        [(ast.AstMatch.Match scrutinee-box arms)
          (let
            [scrutinee : ast.AstExpr (spec-owner-expr-get owner scrutinee-box)]
            (match (spec-substitute-values-expr-with-owner owner scrutinee subs)
              [(ResultSpecSubExpr.Ok rewritten-scrutinee)
                (match (spec-substitute-values-match-arms-with-owner
                  owner
                  arms
                  subs)
                  [(ResultSpecSubMatchArmList.Ok rewritten-arms)
                    (ResultSpecSubExpr.Ok
                      (ast.ast-expr-match-with-pools
                        (spec-owner-pools owner)
                        rewritten-scrutinee
                        rewritten-arms))]
                  [(ResultSpecSubMatchArmList.Err diag)
                    (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(ast.AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(ast.AstForeach.Foreach index index-ty start-box end-box body-box)
          (let
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            (match (spec-substitute-values-expr-with-owner owner start subs)
              [(ResultSpecSubExpr.Ok rewritten-start)
                (match (spec-substitute-values-expr-with-owner owner end subs)
                  [(ResultSpecSubExpr.Ok rewritten-end)
                    (match (spec-substitute-values-expr-with-owner
                      owner
                      body
                      (spec-value-subst-remove-name subs index))
                      [(ResultSpecSubExpr.Ok rewritten-body)
                        (ResultSpecSubExpr.Ok
                          (ast.ast-expr-foreach-id-with-pools
                            (spec-owner-pools owner)
                            index
                            index-ty
                            rewritten-start
                            rewritten-end
                            rewritten-body))]
                      [(ResultSpecSubExpr.Err diag)
                        (ResultSpecSubExpr.Err diag)])]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(ast.AstSpmdReduce.Reduce
            op
            index
            index-ty
            start-box
            end-box
            init-box
            value-box)
          (let
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [init : ast.AstExpr (spec-owner-expr-get owner init-box)]
            [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
            (match (spec-substitute-values-expr-with-owner owner start subs)
              [(ResultSpecSubExpr.Ok rewritten-start)
                (match (spec-substitute-values-expr-with-owner owner end subs)
                  [(ResultSpecSubExpr.Ok rewritten-end)
                    (match (spec-substitute-values-expr-with-owner
                      owner
                      init
                      subs)
                      [(ResultSpecSubExpr.Ok rewritten-init)
                        (match (spec-substitute-values-expr-with-owner
                          owner
                          value
                          (spec-value-subst-remove-name subs index))
                          [(ResultSpecSubExpr.Ok rewritten-value)
                            (ResultSpecSubExpr.Ok
                              (ast.ast-expr-spmd-reduce-id-with-pools
                                (spec-owner-pools owner)
                                op
                                index
                                index-ty
                                rewritten-start
                                rewritten-end
                                rewritten-init
                                rewritten-value))]
                          [(ResultSpecSubExpr.Err diag)
                            (ResultSpecSubExpr.Err diag)])]
                      [(ResultSpecSubExpr.Err diag)
                        (ResultSpecSubExpr.Err diag)])]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(ast.AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
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
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [init : ast.AstExpr (spec-owner-expr-get owner init-box)]
            [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            [value-subs : SpecValueSubst
              (spec-value-subst-remove-name subs index)]
            [body-subs : SpecValueSubst
              (spec-value-subst-remove-name value-subs prefix)]
            (match (spec-substitute-values-expr-with-owner owner start subs)
              [(ResultSpecSubExpr.Ok rewritten-start)
                (match (spec-substitute-values-expr-with-owner owner end subs)
                  [(ResultSpecSubExpr.Ok rewritten-end)
                    (match (spec-substitute-values-expr-with-owner
                      owner
                      init
                      subs)
                      [(ResultSpecSubExpr.Ok rewritten-init)
                        (match (spec-substitute-values-expr-with-owner
                          owner
                          value
                          value-subs)
                          [(ResultSpecSubExpr.Ok rewritten-value)
                            (match (spec-substitute-values-expr-with-owner
                              owner
                              body
                              body-subs)
                              [(ResultSpecSubExpr.Ok rewritten-body)
                                (ResultSpecSubExpr.Ok
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
                                    rewritten-body))]
                              [(ResultSpecSubExpr.Err diag)
                                (ResultSpecSubExpr.Err diag)])]
                          [(ResultSpecSubExpr.Err diag)
                            (ResultSpecSubExpr.Err diag)])]
                      [(ResultSpecSubExpr.Err diag)
                        (ResultSpecSubExpr.Err diag)])]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(ast.AstExpr.SpmdBroadcast value-box lane-box)
      (let
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        [lane : ast.AstExpr (spec-owner-expr-get owner lane-box)]
        (match (spec-substitute-values-expr-with-owner owner value subs)
          [(ResultSpecSubExpr.Ok rewritten-value)
            (match (spec-substitute-values-expr-with-owner owner lane subs)
              [(ResultSpecSubExpr.Ok rewritten-lane)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-spmd-broadcast-with-pools
                    (spec-owner-pools owner)
                    rewritten-value
                    rewritten-lane))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.SpmdShuffle value-box lane-box)
      (let
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        [lane : ast.AstExpr (spec-owner-expr-get owner lane-box)]
        (match (spec-substitute-values-expr-with-owner owner value subs)
          [(ResultSpecSubExpr.Ok rewritten-value)
            (match (spec-substitute-values-expr-with-owner owner lane subs)
              [(ResultSpecSubExpr.Ok rewritten-lane)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-spmd-shuffle-with-pools
                    (spec-owner-pools owner)
                    rewritten-value
                    rewritten-lane))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.StructGet receiver-box field)
      (let
        [receiver : ast.AstExpr (spec-owner-expr-get owner receiver-box)]
        (match (spec-substitute-values-expr-with-owner owner receiver subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-struct-get-id-with-pools
                (spec-owner-pools owner)
                rewritten
                field))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.StructSet receiver-box field value-box)
      (let
        [receiver : ast.AstExpr (spec-owner-expr-get owner receiver-box)]
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-substitute-values-expr-with-owner owner receiver subs)
          [(ResultSpecSubExpr.Ok rewritten-receiver)
            (match (spec-substitute-values-expr-with-owner owner value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-struct-set-id-with-pools
                    (spec-owner-pools owner)
                    rewritten-receiver
                    field
                    rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.WithRegion region body)
      (match (spec-substitute-values-expr-list-with-owner owner body subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push
              owner
              (ast.AstExpr.WithRegion region rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.WithEscape scratch-box body)
      (let
        [scratch : ast.AstExpr (spec-owner-expr-get owner scratch-box)]
        (match (spec-substitute-values-expr-with-owner owner scratch subs)
          [(ResultSpecSubExpr.Ok rewritten-scratch)
            (match (spec-substitute-values-expr-list-with-owner owner body subs)
              [(ResultSpecSubExprList.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-with-escape-with-pools
                    (spec-owner-pools owner)
                    rewritten-scratch
                    rewritten-body))]
              [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.WithScratch body)
      (match (spec-substitute-values-expr-list-with-owner owner body subs)
        [(ResultSpecSubExprList.Ok rewritten-body)
          (ResultSpecSubExpr.Ok
            (ast.ast-expr-with-scratch-with-pools
              (spec-owner-pools owner)
              rewritten-body))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.InArena arena-box body)
      (let
        [arena : ast.AstExpr (spec-owner-expr-get owner arena-box)]
        (match (spec-substitute-values-expr-with-owner owner arena subs)
          [(ResultSpecSubExpr.Ok rewritten-arena)
            (match (spec-substitute-values-expr-list-with-owner owner body subs)
              [(ResultSpecSubExprList.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-in-arena-with-pools
                    (spec-owner-pools owner)
                    rewritten-arena
                    rewritten-body))]
              [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push
              owner
              (ast.AstExpr.WithResource
                (box (ast.AstWithResource.WithResource bindings body)))))])]
    [(ast.AstExpr.Box inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-box-with-pools (spec-owner-pools owner) rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.BoxGet inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-box-get-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.BoxTake inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-box-take-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.BoxSet inner-box value-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten-inner)
            (match (spec-substitute-values-expr-with-owner owner value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-box-set-with-pools
                    (spec-owner-pools owner)
                    rewritten-inner
                    rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Comptime inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-comptime-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Try inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-try-with-pools (spec-owner-pools owner) rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Return inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-return-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Break)
      (ResultSpecSubExpr.Ok
        (ast.ast-expr-break-with-pools (spec-owner-pools owner)))]
    [(ast.AstExpr.Continue)
      (ResultSpecSubExpr.Ok
        (ast.ast-expr-continue-with-pools (spec-owner-pools owner)))]
    [(ast.AstExpr.PtrNull ty-id)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push owner (ast.AstExpr.PtrNull ty-id)))]
    [(ast.AstExpr.PtrNullCheck inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-ptr-null-check-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.PtrAddrOf place-box)
      (let
        [place : ast.AstExpr (spec-owner-expr-get owner place-box)]
        (match (spec-ptr-addr-of-place-value-conflict-with-owner
          owner
          place
          subs)
          [(SpecMaybeId.Some name-id)
            (ResultSpecSubExpr.Err
              (box
                (spec-diagnostic-at-expr
                  expr
                  (str_cat.str-cat
                    "cannot take address of comptime value parameter '"
                    (spec_ci.intern-compat-state-str
                      (spec-owner-intern-state owner)
                      name-id)
                    "'"))))]
          [(SpecMaybeId.None)
            (match (spec-substitute-values-expr-with-owner owner place subs)
              [(ResultSpecSubExpr.Ok rewritten)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-ptr-addr-of-id-with-pools
                    (spec-owner-pools owner)
                    rewritten))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]))]
    [(ast.AstExpr.PtrRead ptr-box)
      (let
        [ptr : ast.AstExpr (spec-owner-expr-get owner ptr-box)]
        (match (spec-substitute-values-expr-with-owner owner ptr subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-ptr-read-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.PtrWrite ptr-box value-box)
      (let
        [ptr : ast.AstExpr (spec-owner-expr-get owner ptr-box)]
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-substitute-values-expr-with-owner owner ptr subs)
          [(ResultSpecSubExpr.Ok rewritten-ptr)
            (match (spec-substitute-values-expr-with-owner owner value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-ptr-write-with-pools
                    (spec-owner-pools owner)
                    rewritten-ptr
                    rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.PtrOffset ptr-box offset-box)
      (let
        [ptr : ast.AstExpr (spec-owner-expr-get owner ptr-box)]
        [offset : ast.AstExpr (spec-owner-expr-get owner offset-box)]
        (match (spec-substitute-values-expr-with-owner owner ptr subs)
          [(ResultSpecSubExpr.Ok rewritten-ptr)
            (match (spec-substitute-values-expr-with-owner owner offset subs)
              [(ResultSpecSubExpr.Ok rewritten-offset)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-ptr-offset-with-pools
                    (spec-owner-pools owner)
                    rewritten-ptr
                    rewritten-offset))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.PtrCast ptr-box ty-id)
      (let
        [ptr : ast.AstExpr (spec-owner-expr-get owner ptr-box)]
        (match (spec-substitute-values-expr-with-owner owner ptr subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (spec-owner-expr-push owner (ast.AstExpr.PtrCast rewritten ty-id)))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.PtrToInt ptr-box)
      (let
        [ptr : ast.AstExpr (spec-owner-expr-get owner ptr-box)]
        (match (spec-substitute-values-expr-with-owner owner ptr subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-ptr-to-int-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.IntToPtr value-box ty-id)
      (let
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-substitute-values-expr-with-owner owner value subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (spec-owner-expr-push
                owner
                (ast.AstExpr.IntToPtr rewritten ty-id)))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.StringData inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-string-data-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.StringFromBytes ptr-box len-box)
      (let
        [ptr : ast.AstExpr (spec-owner-expr-get owner ptr-box)]
        [len : ast.AstExpr (spec-owner-expr-get owner len-box)]
        (match (spec-substitute-values-expr-with-owner owner ptr subs)
          [(ResultSpecSubExpr.Ok rewritten-ptr)
            (match (spec-substitute-values-expr-with-owner owner len subs)
              [(ResultSpecSubExpr.Ok rewritten-len)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-string-from-bytes-with-pools
                    (spec-owner-pools owner)
                    rewritten-ptr
                    rewritten-len))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.ArrayData inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-array-data-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.BinaryData bytes)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push owner (ast.AstExpr.BinaryData bytes)))]
    [(ast.AstExpr.SpmdProgramIndex)
      (ResultSpecSubExpr.Ok
        (ast.ast-expr-spmd-program-index-with-pools (spec-owner-pools owner)))]
    [(ast.AstExpr.SpmdProgramCount)
      (ResultSpecSubExpr.Ok
        (ast.ast-expr-spmd-program-count-with-pools (spec-owner-pools owner)))]
    [(ast.AstExpr.ProgramArgc)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push owner (ast.AstExpr.ProgramArgc)))]
    [(ast.AstExpr.ProgramArgv)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push owner (ast.AstExpr.ProgramArgv)))]
    [(ast.AstExpr.ProgramEnvp)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push owner (ast.AstExpr.ProgramEnvp)))]
    [(ast.AstExpr.CpuIdEax leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (spec-owner-expr-get owner leaf-box)]
        [subleaf : ast.AstExpr (spec-owner-expr-get owner subleaf-box)]
        (match (spec-substitute-values-expr-with-owner owner leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-values-expr-with-owner owner subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-cpuid-eax-with-pools
                    (spec-owner-pools owner)
                    rewritten-leaf
                    rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.CpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (spec-owner-expr-get owner leaf-box)]
        [subleaf : ast.AstExpr (spec-owner-expr-get owner subleaf-box)]
        (match (spec-substitute-values-expr-with-owner owner leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-values-expr-with-owner owner subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-cpuid-ebx-with-pools
                    (spec-owner-pools owner)
                    rewritten-leaf
                    rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.CpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (spec-owner-expr-get owner leaf-box)]
        [subleaf : ast.AstExpr (spec-owner-expr-get owner subleaf-box)]
        (match (spec-substitute-values-expr-with-owner owner leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-values-expr-with-owner owner subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-cpuid-ecx-with-pools
                    (spec-owner-pools owner)
                    rewritten-leaf
                    rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.CpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (spec-owner-expr-get owner leaf-box)]
        [subleaf : ast.AstExpr (spec-owner-expr-get owner subleaf-box)]
        (match (spec-substitute-values-expr-with-owner owner leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-values-expr-with-owner owner subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-cpuid-edx-with-pools
                    (spec-owner-pools owner)
                    rewritten-leaf
                    rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Xgetbv index-box)
      (let
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        (match (spec-substitute-values-expr-with-owner owner index subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-xgetbv-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Syscall args)
      (match (spec-substitute-values-expr-list-with-owner owner args subs)
        [(ResultSpecSubExprList.Ok rewritten-args)
          (ResultSpecSubExpr.Ok
            (ast.ast-expr-syscall-with-pools
              (spec-owner-pools owner)
              rewritten-args))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.Quote inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-quote-with-pools (spec-owner-pools owner) rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Quasiquote inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-quasiquote-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Unquote inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-unquote-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.UnquoteSplicing inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-values-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-unquote-splicing-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.BracketClause items)
      (match (spec-substitute-values-expr-list-with-owner owner items subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (ast.ast-expr-bracket-clause-with-pools
              (spec-owner-pools owner)
              rewritten))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.Borrow _ _ _)
      (ResultSpecSubExpr.Ok (spec-owner-expr-push owner expr))]))

(define (spec-substitute-values-expr-list-with-owner
  [owner : SpecOwnerContext]
  [exprs : ast.AstExprList]
  [subs : SpecValueSubst]) : ResultSpecSubExprList
  (let
    [out : ast.AstExprList
      (ast.ast-expr-list-with-capacity (struct-get (& exprs) len))]
    (match (spec-substitute-values-expr-list-at-with-owner
      owner
      (& exprs)
      0
      subs
      (&mut out))
      [(ResultSpecSubExprListBuild.Ok) (ResultSpecSubExprList.Ok out)]
      [(ResultSpecSubExprListBuild.Err diag) (ResultSpecSubExprList.Err diag)])))

(define (spec-substitute-values-expr-list-at-with-owner
  [owner : SpecOwnerContext]
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [subs : SpecValueSubst]
  [out : (&mut out ast.AstExprList)]) : ResultSpecSubExprListBuild
  (if (>= index (struct-get exprs len))
    (ResultSpecSubExprListBuild.Ok)
    (let
      [head : ast.AstExpr
        (spec-owner-expr-get owner (ast.ast-expr-list-get exprs index 0))]
      (match (spec-substitute-values-expr-with-owner owner head subs)
        [(ResultSpecSubExpr.Ok rewritten-head)
          (begin
            (ast.ast-expr-list-push out rewritten-head)
            (spec-substitute-values-expr-list-at-with-owner
              owner
              exprs
              (+ index 1)
              subs
              out))]
        [(ResultSpecSubExpr.Err diag) (ResultSpecSubExprListBuild.Err diag)]))))

(define (spec-substitute-values-let-bindings-with-owner
  [owner : SpecOwnerContext]
  [bindings : ast.AstLetBindingList]
  [subs : SpecValueSubst]) : ResultSpecSubLetBindingList
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
      [(ResultSpecSubLetBindingListBuild.Ok)
        (ResultSpecSubLetBindingList.Ok out)]
      [(ResultSpecSubLetBindingListBuild.Err diag)
        (ResultSpecSubLetBindingList.Err diag)])))

(define (spec-substitute-values-let-bindings-at-with-owner
  [owner : SpecOwnerContext]
  [bindings : (& bindings ast.AstLetBindingList)]
  [index : i64]
  [subs : SpecValueSubst]
  [out : (&mut out ast.AstLetBindingList)]) : ResultSpecSubLetBindingListBuild
  (if (>= index (ast.ast-let-binding-list-len bindings))
    (ResultSpecSubLetBindingListBuild.Ok)
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name ty value-box)
        (let
          [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
          (match (spec-substitute-values-expr-with-owner owner value subs)
            [(ResultSpecSubExpr.Ok rewritten-value)
              (begin
                (ast.ast-let-binding-list-push
                  out
                  (ast.ast-let-binding-id name ty rewritten-value))
                (spec-substitute-values-let-bindings-at-with-owner
                  owner
                  bindings
                  (+ index 1)
                  (spec-value-subst-remove-name subs name)
                  out))]
            [(ResultSpecSubExpr.Err diag)
              (ResultSpecSubLetBindingListBuild.Err diag)]))])))

(define (spec-substitute-values-match-arms-with-owner
  [owner : SpecOwnerContext]
  [arms : ast.AstMatchArmList]
  [subs : SpecValueSubst]) : ResultSpecSubMatchArmList
  (let
    [out : ast.AstMatchArmList
      (ast.ast-match-arm-list-with-capacity (struct-get (& arms) len))]
    (match (spec-substitute-values-match-arms-at-with-owner
      owner
      (& arms)
      0
      subs
      (&mut out))
      [(ResultSpecSubMatchArmListBuild.Ok) (ResultSpecSubMatchArmList.Ok out)]
      [(ResultSpecSubMatchArmListBuild.Err diag)
        (ResultSpecSubMatchArmList.Err diag)])))

(define (spec-substitute-values-match-arms-at-with-owner
  [owner : SpecOwnerContext]
  [arms : (& arms ast.AstMatchArmList)]
  [index : i64]
  [subs : SpecValueSubst]
  [out : (&mut out ast.AstMatchArmList)]) : ResultSpecSubMatchArmListBuild
  (if (>= index (struct-get arms len))
    (ResultSpecSubMatchArmListBuild.Ok)
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm pattern body-box)
        (let
          [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
          (match (spec-substitute-values-expr-with-owner
            owner
            body
            (spec-value-subst-remove-pattern subs pattern))
            [(ResultSpecSubExpr.Ok rewritten-body)
              (begin
                (ast.ast-match-arm-list-push
                  out
                  (ast.ast-match-arm pattern rewritten-body))
                (spec-substitute-values-match-arms-at-with-owner
                  owner
                  arms
                  (+ index 1)
                  subs
                  out))]
            [(ResultSpecSubExpr.Err diag)
              (ResultSpecSubMatchArmListBuild.Err diag)]))])))

;; Self-test compatibility shim for the removed ambient value worker. The
;; production specialization graph calls only the owner-routed implementation.
(define (spec-substitute-values-expr
  [expr : ast.AstExpr]
  [subs : SpecValueSubst]) : ResultSpecSubExpr
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [intern-state : spec_ci.InternCompatState
      (spec_ci.intern-compat-state-capture-active)]
    [owner : SpecOwnerContext (spec-owner-context-new pools intern-state)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      (spec_ci.intern-compat-state-install! intern-state)
      (let
        [result : ResultSpecSubExpr
          (spec-substitute-values-expr-with-owner owner expr subs)]
        (begin
          (ast.ast-node-pool-context-install! pools)
          (spec_ci.intern-compat-state-install! intern-state)
          result)))))

(define (spec-substitute-types-expr-with-owner
  [owner : SpecOwnerContext]
  [expr : ast.AstExpr]
  [subs : SpecTypeSubst]) : ResultSpecSubExpr
  (match expr
    [(ast.AstExpr.Spanned inner-box span)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-spanned-with-pools
                (spec-owner-pools owner)
                rewritten
                span))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.MacroExpansion inner-box provenance-id macro-name-id)
      (match (spec-substitute-types-expr-with-owner
        owner
        (spec-owner-expr-get owner inner-box)
        subs)
        [(ResultSpecSubExpr.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push
              owner
              (ast.AstExpr.MacroExpansion rewritten provenance-id macro-name-id)))]
        [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.Var name)
      (match (spec-type-subst-lookup subs name)
        [(SpecMaybeId.Some _)
          (ResultSpecSubExpr.Err
            (box
              (spec-diagnostic-at-expr
                expr
                (str_cat.str-cat
                  "type-valued comptime parameter '"
                  (spec_ci.intern-compat-state-str
                    (spec-owner-intern-state owner)
                    name)
                  "' cannot be used as a runtime value"))))]
        [(SpecMaybeId.None)
          (ResultSpecSubExpr.Ok (spec-owner-expr-push owner expr))])]
    [(ast.AstExpr.Literal _)
      (ResultSpecSubExpr.Ok (spec-owner-expr-push owner expr))]
    [(ast.AstExpr.TypeLiteral ty-id)
      (ResultSpecSubExpr.Ok
        (ast.ast-expr-type-literal-with-pools
          (spec-owner-pools owner)
          (spec-substitute-type-with-owner
            owner
            (spec-owner-type-get owner ty-id)
            subs)))]
    [(ast.AstExpr.Init maybe-ty-id)
      (ResultSpecSubExpr.Ok
        (ast.ast-expr-init-maybe-with-pools
          (spec-owner-pools owner)
          (spec-substitute-maybe-type-with-owner
            owner
            (ast.ast-maybe-type-from-id-with-pools
              (spec-owner-pools owner)
              maybe-ty-id)
            subs)))]
    [(ast.AstExpr.MakeArray elem-ty-id len-box)
      (let
        [len : ast.AstExpr (spec-owner-expr-get owner len-box)]
        (match (spec-substitute-types-expr-with-owner owner len subs)
          [(ResultSpecSubExpr.Ok rewritten-len)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-make-array-with-pools
                (spec-owner-pools owner)
                (spec-substitute-type-with-owner
                  owner
                  (spec-owner-type-get owner elem-ty-id)
                  subs)
                rewritten-len))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Ann inner-box ty-id)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-ann-with-pools
                (spec-owner-pools owner)
                rewritten
                (spec-substitute-type-with-owner
                  owner
                  (spec-owner-type-get owner ty-id)
                  subs)))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Cast inner-box ty-id)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-cast-with-pools
                (spec-owner-pools owner)
                rewritten
                (spec-substitute-type-with-owner
                  owner
                  (spec-owner-type-get owner ty-id)
                  subs)))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(ast.AstLambda.Lambda params ret body-box)
          (let
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            (match (spec-substitute-types-expr-with-owner
              owner
              body
              (spec-type-subst-remove-params subs params))
              [(ResultSpecSubExpr.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-lambda-with-pools
                    (spec-owner-pools owner)
                    (spec-substitute-param-types-with-owner owner params subs)
                    (spec-substitute-maybe-type-with-owner owner ret subs)
                    rewritten-body))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(ast.AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(ast.AstForeach.Foreach index index-ty start-box end-box body-box)
          (let
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            (match (spec-substitute-types-expr-with-owner owner start subs)
              [(ResultSpecSubExpr.Ok rewritten-start)
                (match (spec-substitute-types-expr-with-owner owner end subs)
                  [(ResultSpecSubExpr.Ok rewritten-end)
                    (match (spec-substitute-types-expr-with-owner
                      owner
                      body
                      (spec-type-subst-remove-name subs index))
                      [(ResultSpecSubExpr.Ok rewritten-body)
                        (ResultSpecSubExpr.Ok
                          (ast.ast-expr-foreach-id-with-pools
                            (spec-owner-pools owner)
                            index
                            (spec-substitute-type-with-owner
                              owner
                              index-ty
                              subs)
                            rewritten-start
                            rewritten-end
                            rewritten-body))]
                      [(ResultSpecSubExpr.Err diag)
                        (ResultSpecSubExpr.Err diag)])]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(ast.AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(ast.AstSpmdReduce.Reduce
            op
            index
            index-ty
            start-box
            end-box
            init-box
            value-box)
          (let
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [init : ast.AstExpr (spec-owner-expr-get owner init-box)]
            [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
            (match (spec-substitute-types-expr-with-owner owner start subs)
              [(ResultSpecSubExpr.Ok rewritten-start)
                (match (spec-substitute-types-expr-with-owner owner end subs)
                  [(ResultSpecSubExpr.Ok rewritten-end)
                    (match (spec-substitute-types-expr-with-owner
                      owner
                      init
                      subs)
                      [(ResultSpecSubExpr.Ok rewritten-init)
                        (match (spec-substitute-types-expr-with-owner
                          owner
                          value
                          (spec-type-subst-remove-name subs index))
                          [(ResultSpecSubExpr.Ok rewritten-value)
                            (ResultSpecSubExpr.Ok
                              (ast.ast-expr-spmd-reduce-id-with-pools
                                (spec-owner-pools owner)
                                op
                                index
                                (spec-substitute-type-with-owner
                                  owner
                                  index-ty
                                  subs)
                                rewritten-start
                                rewritten-end
                                rewritten-init
                                rewritten-value))]
                          [(ResultSpecSubExpr.Err diag)
                            (ResultSpecSubExpr.Err diag)])]
                      [(ResultSpecSubExpr.Err diag)
                        (ResultSpecSubExpr.Err diag)])]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(ast.AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
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
            [start : ast.AstExpr (spec-owner-expr-get owner start-box)]
            [end : ast.AstExpr (spec-owner-expr-get owner end-box)]
            [init : ast.AstExpr (spec-owner-expr-get owner init-box)]
            [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            [value-subs : SpecTypeSubst
              (spec-type-subst-remove-name subs index)]
            [body-subs : SpecTypeSubst
              (spec-type-subst-remove-name value-subs prefix)]
            (match (spec-substitute-types-expr-with-owner owner start subs)
              [(ResultSpecSubExpr.Ok rewritten-start)
                (match (spec-substitute-types-expr-with-owner owner end subs)
                  [(ResultSpecSubExpr.Ok rewritten-end)
                    (match (spec-substitute-types-expr-with-owner
                      owner
                      init
                      subs)
                      [(ResultSpecSubExpr.Ok rewritten-init)
                        (match (spec-substitute-types-expr-with-owner
                          owner
                          value
                          value-subs)
                          [(ResultSpecSubExpr.Ok rewritten-value)
                            (match (spec-substitute-types-expr-with-owner
                              owner
                              body
                              body-subs)
                              [(ResultSpecSubExpr.Ok rewritten-body)
                                (ResultSpecSubExpr.Ok
                                  (ast.ast-expr-spmd-scan-id-with-pools
                                    (spec-owner-pools owner)
                                    op
                                    index
                                    (spec-substitute-type-with-owner
                                      owner
                                      index-ty
                                      subs)
                                    rewritten-start
                                    rewritten-end
                                    prefix
                                    (spec-substitute-type-with-owner
                                      owner
                                      prefix-ty
                                      subs)
                                    rewritten-init
                                    rewritten-value
                                    rewritten-body))]
                              [(ResultSpecSubExpr.Err diag)
                                (ResultSpecSubExpr.Err diag)])]
                          [(ResultSpecSubExpr.Err diag)
                            (ResultSpecSubExpr.Err diag)])]
                      [(ResultSpecSubExpr.Err diag)
                        (ResultSpecSubExpr.Err diag)])]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(ast.AstExpr.SpmdBroadcast value-box lane-box)
      (let
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        [lane : ast.AstExpr (spec-owner-expr-get owner lane-box)]
        (match (spec-substitute-types-expr-with-owner owner value subs)
          [(ResultSpecSubExpr.Ok rewritten-value)
            (match (spec-substitute-types-expr-with-owner owner lane subs)
              [(ResultSpecSubExpr.Ok rewritten-lane)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-spmd-broadcast-with-pools
                    (spec-owner-pools owner)
                    rewritten-value
                    rewritten-lane))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.SpmdShuffle value-box lane-box)
      (let
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        [lane : ast.AstExpr (spec-owner-expr-get owner lane-box)]
        (match (spec-substitute-types-expr-with-owner owner value subs)
          [(ResultSpecSubExpr.Ok rewritten-value)
            (match (spec-substitute-types-expr-with-owner owner lane subs)
              [(ResultSpecSubExpr.Ok rewritten-lane)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-spmd-shuffle-with-pools
                    (spec-owner-pools owner)
                    rewritten-value
                    rewritten-lane))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Binary op left-box right-box)
      (let
        [left : ast.AstExpr (spec-owner-expr-get owner left-box)]
        [right : ast.AstExpr (spec-owner-expr-get owner right-box)]
        (match (spec-substitute-types-expr-with-owner owner left subs)
          [(ResultSpecSubExpr.Ok rewritten-left)
            (match (spec-substitute-types-expr-with-owner owner right subs)
              [(ResultSpecSubExpr.Ok rewritten-right)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-binary-with-pools
                    (spec-owner-pools owner)
                    op
                    rewritten-left
                    rewritten-right))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Unary op inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-unary-with-pools
                (spec-owner-pools owner)
                op
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Call func-box args)
      (let
        [func : ast.AstExpr (spec-owner-expr-get owner func-box)]
        (match (spec-substitute-types-expr-with-owner owner func subs)
          [(ResultSpecSubExpr.Ok rewritten-func)
            (match (spec-substitute-types-expr-list-with-owner owner args subs)
              [(ResultSpecSubExprList.Ok rewritten-args)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-call-with-pools
                    (spec-owner-pools owner)
                    rewritten-func
                    rewritten-args))]
              [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : ast.AstExpr (spec-owner-expr-get owner cond-box)]
        [then-branch : ast.AstExpr (spec-owner-expr-get owner then-branch-box)]
        [else-branch : ast.AstExpr (spec-owner-expr-get owner else-branch-box)]
        (match (spec-substitute-types-expr-with-owner owner cond subs)
          [(ResultSpecSubExpr.Ok rewritten-cond)
            (match (spec-substitute-types-expr-with-owner
              owner
              then-branch
              subs)
              [(ResultSpecSubExpr.Ok rewritten-then)
                (match (spec-substitute-types-expr-with-owner
                  owner
                  else-branch
                  subs)
                  [(ResultSpecSubExpr.Ok rewritten-else)
                    (ResultSpecSubExpr.Ok
                      (ast.ast-expr-if-with-pools
                        (spec-owner-pools owner)
                        rewritten-cond
                        rewritten-then
                        rewritten-else))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Let let-box)
      (match (box-get let-box)
        [(ast.AstLet.Let bindings body-box)
          (let
            [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
            (match (spec-substitute-types-let-bindings-with-owner
              owner
              bindings
              subs)
              [(ResultSpecSubLetBindingList.Ok rewritten-bindings)
                (match (spec-substitute-types-expr-with-owner
                  owner
                  body
                  (spec-type-subst-remove-let-binding-names subs bindings))
                  [(ResultSpecSubExpr.Ok rewritten-body)
                    (ResultSpecSubExpr.Ok
                      (ast.ast-expr-let-with-pools
                        (spec-owner-pools owner)
                        rewritten-bindings
                        rewritten-body))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubLetBindingList.Err diag)
                (ResultSpecSubExpr.Err diag)]))])]
    [(ast.AstExpr.Tuple exprs)
      (match (spec-substitute-types-expr-list-with-owner owner exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push owner (ast.AstExpr.Tuple rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.TupleRef inner-box index)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-tuple-ref-with-pools
                (spec-owner-pools owner)
                rewritten
                index))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Array exprs)
      (match (spec-substitute-types-expr-list-with-owner owner exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push owner (ast.AstExpr.Array rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.DynArray exprs)
      (match (spec-substitute-types-expr-list-with-owner owner exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push owner (ast.AstExpr.DynArray rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.ArrayRef array-box index-box)
      (let
        [array : ast.AstExpr (spec-owner-expr-get owner array-box)]
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        (match (spec-substitute-types-expr-with-owner owner array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-types-expr-with-owner owner index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-array-ref-with-pools
                    (spec-owner-pools owner)
                    rewritten-array
                    rewritten-index))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.ArraySet array-box index-box value-box)
      (let
        [array : ast.AstExpr (spec-owner-expr-get owner array-box)]
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-substitute-types-expr-with-owner owner array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-types-expr-with-owner owner index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (match (spec-substitute-types-expr-with-owner owner value subs)
                  [(ResultSpecSubExpr.Ok rewritten-value)
                    (ResultSpecSubExpr.Ok
                      (ast.ast-expr-array-set-with-pools
                        (spec-owner-pools owner)
                        rewritten-array
                        rewritten-index
                        rewritten-value))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.ArrayTake array-box live-box index-box)
      (let
        [array : ast.AstExpr (spec-owner-expr-get owner array-box)]
        [live : ast.AstExpr (spec-owner-expr-get owner live-box)]
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        (match (spec-substitute-types-expr-with-owner owner array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-types-expr-with-owner owner live subs)
              [(ResultSpecSubExpr.Ok rewritten-live)
                (match (spec-substitute-types-expr-with-owner owner index subs)
                  [(ResultSpecSubExpr.Ok rewritten-index)
                    (ResultSpecSubExpr.Ok
                      (ast.ast-expr-array-take-with-pools
                        (spec-owner-pools owner)
                        rewritten-array
                        rewritten-live
                        rewritten-index))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.FixedArrayTake array-box index-box)
      (let
        [array : ast.AstExpr (spec-owner-expr-get owner array-box)]
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        (match (spec-substitute-types-expr-with-owner owner array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-types-expr-with-owner owner index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-fixed-array-take-with-pools
                    (spec-owner-pools owner)
                    rewritten-array
                    rewritten-index))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.ArrayPush array-box value-box)
      (let
        [array : ast.AstExpr (spec-owner-expr-get owner array-box)]
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-substitute-types-expr-with-owner owner array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-types-expr-with-owner owner value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-array-push-with-pools
                    (spec-owner-pools owner)
                    rewritten-array
                    rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.StringRef text-box index-box)
      (let
        [text : ast.AstExpr (spec-owner-expr-get owner text-box)]
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        (match (spec-substitute-types-expr-with-owner owner text subs)
          [(ResultSpecSubExpr.Ok rewritten-text)
            (match (spec-substitute-types-expr-with-owner owner index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-string-ref-with-pools
                    (spec-owner-pools owner)
                    rewritten-text
                    rewritten-index))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.While cond-box body-box)
      (let
        [cond : ast.AstExpr (spec-owner-expr-get owner cond-box)]
        [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
        (match (spec-substitute-types-expr-with-owner owner cond subs)
          [(ResultSpecSubExpr.Ok rewritten-cond)
            (match (spec-substitute-types-expr-with-owner owner body subs)
              [(ResultSpecSubExpr.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-while-with-pools
                    (spec-owner-pools owner)
                    rewritten-cond
                    rewritten-body))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.ForOwnedState payload)
      (match (spec-substitute-types-expr-list-with-owner
        owner
        (spec-for-owned-state-exprs
          (ast.ast-for-owned-state-source-name (& payload))
          (ast.ast-for-owned-state-index-name (& payload))
          (ast.ast-for-owned-state-source (& payload))
          (ast.ast-for-owned-state-body (& payload)))
        subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (ast.ast-expr-for-owned-state-with-pools
              (spec-owner-pools owner)
              (ast.ast-expr-list-get (& rewritten) 0 0)
              (ast.ast-expr-list-get (& rewritten) 1 0)
              (ast.ast-expr-list-get (& rewritten) 2 0)
              (ast.ast-expr-list-get (& rewritten) 3 0)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.ForOwnedStep payload)
      (let
        [expected-type : i64 (ast.ast-for-owned-step-expected-type (& payload))]
        (match (spec-substitute-types-expr-list-with-owner
          owner
          (spec-for-owned-step-exprs
            (ast.ast-for-owned-step-source-name (& payload))
            (ast.ast-for-owned-step-index-name (& payload))
            (ast.ast-for-owned-step-binding-name (& payload))
            expected-type
            (ast.ast-for-owned-step-done-name (& payload))
            (ast.ast-for-owned-step-body (& payload)))
          subs)
          [(ResultSpecSubExprList.Ok rewritten)
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
              (ResultSpecSubExpr.Ok
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
          [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Begin exprs)
      (match (spec-substitute-types-expr-list-with-owner owner exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push owner (ast.AstExpr.Begin rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.Unsafe exprs)
      (match (spec-substitute-types-expr-list-with-owner owner exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push owner (ast.AstExpr.Unsafe rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.Set name value-box)
      (let
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-type-subst-lookup subs name)
          [(SpecMaybeId.Some _)
            (ResultSpecSubExpr.Err
              (box
                (spec-diagnostic-at-expr
                  expr
                  (str_cat.str-cat
                    "type-valued comptime parameter '"
                    (spec_ci.intern-compat-state-str
                      (spec-owner-intern-state owner)
                      name)
                    "' cannot be assigned"))))]
          [(SpecMaybeId.None)
            (match (spec-substitute-types-expr-with-owner owner value subs)
              [(ResultSpecSubExpr.Ok rewritten)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-set-id-with-pools
                    (spec-owner-pools owner)
                    name
                    rewritten))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]))]
    [(ast.AstExpr.Match match-box)
      (match (box-get match-box)
        [(ast.AstMatch.Match scrutinee-box arms)
          (let
            [scrutinee : ast.AstExpr (spec-owner-expr-get owner scrutinee-box)]
            (match (spec-substitute-types-expr-with-owner owner scrutinee subs)
              [(ResultSpecSubExpr.Ok rewritten-scrutinee)
                (match (spec-substitute-types-match-arms-with-owner
                  owner
                  arms
                  subs)
                  [(ResultSpecSubMatchArmList.Ok rewritten-arms)
                    (ResultSpecSubExpr.Ok
                      (ast.ast-expr-match-with-pools
                        (spec-owner-pools owner)
                        rewritten-scrutinee
                        rewritten-arms))]
                  [(ResultSpecSubMatchArmList.Err diag)
                    (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(ast.AstExpr.StructGet receiver-box field)
      (let
        [receiver : ast.AstExpr (spec-owner-expr-get owner receiver-box)]
        (match (spec-substitute-types-expr-with-owner owner receiver subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-struct-get-id-with-pools
                (spec-owner-pools owner)
                rewritten
                field))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.StructSet receiver-box field value-box)
      (let
        [receiver : ast.AstExpr (spec-owner-expr-get owner receiver-box)]
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-substitute-types-expr-with-owner owner receiver subs)
          [(ResultSpecSubExpr.Ok rewritten-receiver)
            (match (spec-substitute-types-expr-with-owner owner value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-struct-set-id-with-pools
                    (spec-owner-pools owner)
                    rewritten-receiver
                    field
                    rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.WithRegion region body)
      (match (spec-substitute-types-expr-list-with-owner owner body subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push
              owner
              (ast.AstExpr.WithRegion region rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.WithEscape scratch-box body)
      (let
        [scratch : ast.AstExpr (spec-owner-expr-get owner scratch-box)]
        (match (spec-substitute-types-expr-with-owner owner scratch subs)
          [(ResultSpecSubExpr.Ok rewritten-scratch)
            (match (spec-substitute-types-expr-list-with-owner owner body subs)
              [(ResultSpecSubExprList.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-with-escape-with-pools
                    (spec-owner-pools owner)
                    rewritten-scratch
                    rewritten-body))]
              [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.WithScratch body)
      (match (spec-substitute-types-expr-list-with-owner owner body subs)
        [(ResultSpecSubExprList.Ok rewritten-body)
          (ResultSpecSubExpr.Ok
            (ast.ast-expr-with-scratch-with-pools
              (spec-owner-pools owner)
              rewritten-body))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.InArena arena-box body)
      (let
        [arena : ast.AstExpr (spec-owner-expr-get owner arena-box)]
        (match (spec-substitute-types-expr-with-owner owner arena subs)
          [(ResultSpecSubExpr.Ok rewritten-arena)
            (match (spec-substitute-types-expr-list-with-owner owner body subs)
              [(ResultSpecSubExprList.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-in-arena-with-pools
                    (spec-owner-pools owner)
                    rewritten-arena
                    rewritten-body))]
              [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(ast.AstWithResource.WithResource bindings body)
          (ResultSpecSubExpr.Ok
            (spec-owner-expr-push
              owner
              (ast.AstExpr.WithResource
                (box (ast.AstWithResource.WithResource bindings body)))))])]
    [(ast.AstExpr.Box inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-box-with-pools (spec-owner-pools owner) rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.BoxGet inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-box-get-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.BoxTake inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-box-take-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.BoxSet inner-box value-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten-inner)
            (match (spec-substitute-types-expr-with-owner owner value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-box-set-with-pools
                    (spec-owner-pools owner)
                    rewritten-inner
                    rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Comptime inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-comptime-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Try inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-try-with-pools (spec-owner-pools owner) rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Return inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-return-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Break)
      (ResultSpecSubExpr.Ok
        (ast.ast-expr-break-with-pools (spec-owner-pools owner)))]
    [(ast.AstExpr.Continue)
      (ResultSpecSubExpr.Ok
        (ast.ast-expr-continue-with-pools (spec-owner-pools owner)))]
    [(ast.AstExpr.PtrNull ty-id)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push
          owner
          (ast.AstExpr.PtrNull
            (spec-owner-type-push
              owner
              (spec-substitute-type-with-owner
                owner
                (spec-owner-type-get owner ty-id)
                subs)))))]
    [(ast.AstExpr.PtrNullCheck inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-ptr-null-check-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.PtrAddrOf place-box)
      (let
        [place : ast.AstExpr (spec-owner-expr-get owner place-box)]
        (match (spec-substitute-types-expr-with-owner owner place subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-ptr-addr-of-id-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.PtrRead ptr-box)
      (let
        [ptr : ast.AstExpr (spec-owner-expr-get owner ptr-box)]
        (match (spec-substitute-types-expr-with-owner owner ptr subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-ptr-read-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.PtrWrite ptr-box value-box)
      (let
        [ptr : ast.AstExpr (spec-owner-expr-get owner ptr-box)]
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-substitute-types-expr-with-owner owner ptr subs)
          [(ResultSpecSubExpr.Ok rewritten-ptr)
            (match (spec-substitute-types-expr-with-owner owner value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-ptr-write-with-pools
                    (spec-owner-pools owner)
                    rewritten-ptr
                    rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.PtrOffset ptr-box offset-box)
      (let
        [ptr : ast.AstExpr (spec-owner-expr-get owner ptr-box)]
        [offset : ast.AstExpr (spec-owner-expr-get owner offset-box)]
        (match (spec-substitute-types-expr-with-owner owner ptr subs)
          [(ResultSpecSubExpr.Ok rewritten-ptr)
            (match (spec-substitute-types-expr-with-owner owner offset subs)
              [(ResultSpecSubExpr.Ok rewritten-offset)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-ptr-offset-with-pools
                    (spec-owner-pools owner)
                    rewritten-ptr
                    rewritten-offset))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.PtrCast ptr-box ty-id)
      (let
        [ptr : ast.AstExpr (spec-owner-expr-get owner ptr-box)]
        (match (spec-substitute-types-expr-with-owner owner ptr subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-ptr-cast-with-pools
                (spec-owner-pools owner)
                rewritten
                (spec-substitute-type-with-owner
                  owner
                  (spec-owner-type-get owner ty-id)
                  subs)))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.PtrToInt ptr-box)
      (let
        [ptr : ast.AstExpr (spec-owner-expr-get owner ptr-box)]
        (match (spec-substitute-types-expr-with-owner owner ptr subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-ptr-to-int-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.IntToPtr value-box ty-id)
      (let
        [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
        (match (spec-substitute-types-expr-with-owner owner value subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-int-to-ptr-with-pools
                (spec-owner-pools owner)
                rewritten
                (spec-substitute-type-with-owner
                  owner
                  (spec-owner-type-get owner ty-id)
                  subs)))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.StringData inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-string-data-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.StringFromBytes ptr-box len-box)
      (let
        [ptr : ast.AstExpr (spec-owner-expr-get owner ptr-box)]
        [len : ast.AstExpr (spec-owner-expr-get owner len-box)]
        (match (spec-substitute-types-expr-with-owner owner ptr subs)
          [(ResultSpecSubExpr.Ok rewritten-ptr)
            (match (spec-substitute-types-expr-with-owner owner len subs)
              [(ResultSpecSubExpr.Ok rewritten-len)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-string-from-bytes-with-pools
                    (spec-owner-pools owner)
                    rewritten-ptr
                    rewritten-len))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.ArrayData inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-array-data-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.BinaryData bytes)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push owner (ast.AstExpr.BinaryData bytes)))]
    [(ast.AstExpr.SpmdProgramIndex)
      (ResultSpecSubExpr.Ok
        (ast.ast-expr-spmd-program-index-with-pools (spec-owner-pools owner)))]
    [(ast.AstExpr.SpmdProgramCount)
      (ResultSpecSubExpr.Ok
        (ast.ast-expr-spmd-program-count-with-pools (spec-owner-pools owner)))]
    [(ast.AstExpr.ProgramArgc)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push owner (ast.AstExpr.ProgramArgc)))]
    [(ast.AstExpr.ProgramArgv)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push owner (ast.AstExpr.ProgramArgv)))]
    [(ast.AstExpr.ProgramEnvp)
      (ResultSpecSubExpr.Ok
        (spec-owner-expr-push owner (ast.AstExpr.ProgramEnvp)))]
    [(ast.AstExpr.CpuIdEax leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (spec-owner-expr-get owner leaf-box)]
        [subleaf : ast.AstExpr (spec-owner-expr-get owner subleaf-box)]
        (match (spec-substitute-types-expr-with-owner owner leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-types-expr-with-owner owner subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-cpuid-eax-with-pools
                    (spec-owner-pools owner)
                    rewritten-leaf
                    rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.CpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (spec-owner-expr-get owner leaf-box)]
        [subleaf : ast.AstExpr (spec-owner-expr-get owner subleaf-box)]
        (match (spec-substitute-types-expr-with-owner owner leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-types-expr-with-owner owner subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-cpuid-ebx-with-pools
                    (spec-owner-pools owner)
                    rewritten-leaf
                    rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.CpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (spec-owner-expr-get owner leaf-box)]
        [subleaf : ast.AstExpr (spec-owner-expr-get owner subleaf-box)]
        (match (spec-substitute-types-expr-with-owner owner leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-types-expr-with-owner owner subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-cpuid-ecx-with-pools
                    (spec-owner-pools owner)
                    rewritten-leaf
                    rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.CpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : ast.AstExpr (spec-owner-expr-get owner leaf-box)]
        [subleaf : ast.AstExpr (spec-owner-expr-get owner subleaf-box)]
        (match (spec-substitute-types-expr-with-owner owner leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-types-expr-with-owner owner subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast.ast-expr-cpuid-edx-with-pools
                    (spec-owner-pools owner)
                    rewritten-leaf
                    rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Xgetbv index-box)
      (let
        [index : ast.AstExpr (spec-owner-expr-get owner index-box)]
        (match (spec-substitute-types-expr-with-owner owner index subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-xgetbv-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Syscall args)
      (match (spec-substitute-types-expr-list-with-owner owner args subs)
        [(ResultSpecSubExprList.Ok rewritten-args)
          (ResultSpecSubExpr.Ok
            (ast.ast-expr-syscall-with-pools
              (spec-owner-pools owner)
              rewritten-args))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.Quote inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-quote-with-pools (spec-owner-pools owner) rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Quasiquote inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-quasiquote-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.Unquote inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-unquote-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.UnquoteSplicing inner-box)
      (let
        [inner : ast.AstExpr (spec-owner-expr-get owner inner-box)]
        (match (spec-substitute-types-expr-with-owner owner inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast.ast-expr-unquote-splicing-with-pools
                (spec-owner-pools owner)
                rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(ast.AstExpr.BracketClause items)
      (match (spec-substitute-types-expr-list-with-owner owner items subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (ast.ast-expr-bracket-clause-with-pools
              (spec-owner-pools owner)
              rewritten))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(ast.AstExpr.Borrow _ _ _)
      (ResultSpecSubExpr.Ok (spec-owner-expr-push owner expr))]))

(define (spec-substitute-types-expr-list-with-owner
  [owner : SpecOwnerContext]
  [exprs : ast.AstExprList]
  [subs : SpecTypeSubst]) : ResultSpecSubExprList
  (let
    [out : ast.AstExprList
      (ast.ast-expr-list-with-capacity (struct-get (& exprs) len))]
    (match (spec-substitute-types-expr-list-at-with-owner
      owner
      (& exprs)
      0
      subs
      (&mut out))
      [(ResultSpecSubExprListBuild.Ok) (ResultSpecSubExprList.Ok out)]
      [(ResultSpecSubExprListBuild.Err diag) (ResultSpecSubExprList.Err diag)])))

(define (spec-substitute-types-expr-list-at-with-owner
  [owner : SpecOwnerContext]
  [exprs : (& exprs ast.AstExprList)]
  [index : i64]
  [subs : SpecTypeSubst]
  [out : (&mut out ast.AstExprList)]) : ResultSpecSubExprListBuild
  (if (>= index (struct-get exprs len))
    (ResultSpecSubExprListBuild.Ok)
    (let
      [head : ast.AstExpr
        (spec-owner-expr-get owner (ast.ast-expr-list-get exprs index 0))]
      (match (spec-substitute-types-expr-with-owner owner head subs)
        [(ResultSpecSubExpr.Ok rewritten-head)
          (begin
            (ast.ast-expr-list-push out rewritten-head)
            (spec-substitute-types-expr-list-at-with-owner
              owner
              exprs
              (+ index 1)
              subs
              out))]
        [(ResultSpecSubExpr.Err diag) (ResultSpecSubExprListBuild.Err diag)]))))

(define (spec-substitute-types-let-bindings-with-owner
  [owner : SpecOwnerContext]
  [bindings : ast.AstLetBindingList]
  [subs : SpecTypeSubst]) : ResultSpecSubLetBindingList
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
      [(ResultSpecSubLetBindingListBuild.Ok)
        (ResultSpecSubLetBindingList.Ok out)]
      [(ResultSpecSubLetBindingListBuild.Err diag)
        (ResultSpecSubLetBindingList.Err diag)])))

(define (spec-substitute-types-let-bindings-at-with-owner
  [owner : SpecOwnerContext]
  [bindings : (& bindings ast.AstLetBindingList)]
  [index : i64]
  [subs : SpecTypeSubst]
  [out : (&mut out ast.AstLetBindingList)]) : ResultSpecSubLetBindingListBuild
  (if (>= index (ast.ast-let-binding-list-len bindings))
    (ResultSpecSubLetBindingListBuild.Ok)
    (match (ast.ast-let-binding-list-get
      bindings
      index
      (ast.ast-let-binding-fallback))
      [(ast.AstLetBinding.Binding name ty value-box)
        (let
          [value : ast.AstExpr (spec-owner-expr-get owner value-box)]
          (match (spec-substitute-types-expr-with-owner owner value subs)
            [(ResultSpecSubExpr.Ok rewritten-value)
              (begin
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
                  (spec-type-subst-remove-name subs name)
                  out))]
            [(ResultSpecSubExpr.Err diag)
              (ResultSpecSubLetBindingListBuild.Err diag)]))])))

(define (spec-substitute-types-match-arms-with-owner
  [owner : SpecOwnerContext]
  [arms : ast.AstMatchArmList]
  [subs : SpecTypeSubst]) : ResultSpecSubMatchArmList
  (let
    [out : ast.AstMatchArmList
      (ast.ast-match-arm-list-with-capacity (struct-get (& arms) len))]
    (match (spec-substitute-types-match-arms-at-with-owner
      owner
      (& arms)
      0
      subs
      (&mut out))
      [(ResultSpecSubMatchArmListBuild.Ok) (ResultSpecSubMatchArmList.Ok out)]
      [(ResultSpecSubMatchArmListBuild.Err diag)
        (ResultSpecSubMatchArmList.Err diag)])))

(define (spec-substitute-types-match-arms-at-with-owner
  [owner : SpecOwnerContext]
  [arms : (& arms ast.AstMatchArmList)]
  [index : i64]
  [subs : SpecTypeSubst]
  [out : (&mut out ast.AstMatchArmList)]) : ResultSpecSubMatchArmListBuild
  (if (>= index (struct-get arms len))
    (ResultSpecSubMatchArmListBuild.Ok)
    (match (ast.ast-match-arm-list-get arms index (ast.ast-match-arm-fallback))
      [(ast.AstMatchArm.Arm pattern body-box)
        (let
          [body : ast.AstExpr (spec-owner-expr-get owner body-box)]
          (match (spec-substitute-types-expr-with-owner
            owner
            body
            (spec-type-subst-remove-pattern subs pattern))
            [(ResultSpecSubExpr.Ok rewritten-body)
              (begin
                (ast.ast-match-arm-list-push
                  out
                  (ast.ast-match-arm pattern rewritten-body))
                (spec-substitute-types-match-arms-at-with-owner
                  owner
                  arms
                  (+ index 1)
                  subs
                  out))]
            [(ResultSpecSubExpr.Err diag)
              (ResultSpecSubMatchArmListBuild.Err diag)]))])))

(define (spec-rewrite-decl-with-owner
  [owner : SpecOwnerContext]
  [decl : ast.AstDecl]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecDecl
  (match decl
    [(ast.AstDecl.Def decl-meta name ty value-box)
      (let
        [value : ast.AstExpr (spec-state-expr-get state value-box)]
        (match (spec-rewrite-expr value templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecDecl.Ok
              (SpecMaybeDecl.Some (ast.ast-decl-def-id name ty rewritten))
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecDecl.Err diag)]))]
    [(ast.AstDecl.DefFn decl-meta name params ret body-box metadata)
      (let
        [body : ast.AstExpr (spec-state-expr-get state body-box)]
        (if (spec-param-list-has-comptime? params)
          (ResultSpecDecl.Ok (SpecMaybeDecl.None) state)
          (match (spec-rewrite-expr
            body
            (spec-template-env-shadow-params templates params)
            state)
            [(ResultSpecExpr.Ok rewritten state2)
              (ResultSpecDecl.Ok
                (SpecMaybeDecl.Some
                  (ast.ast-decl-def-fn-metadata-id
                    name
                    params
                    ret
                    rewritten
                    metadata))
                state2)]
            [(ResultSpecExpr.Err diag) (ResultSpecDecl.Err diag)])))]
    [(ast.AstDecl.Unsafe inner-box)
      (let
        [inner : ast.AstDecl (box-get inner-box)]
        (match (spec-rewrite-decl-with-owner owner inner templates state)
          [(ResultSpecDecl.Ok maybe state2)
            (match maybe
              [(SpecMaybeDecl.Some rewritten)
                (ResultSpecDecl.Ok
                  (SpecMaybeDecl.Some (ast.ast-decl-unsafe rewritten))
                  state2)]
              [(SpecMaybeDecl.None)
                (ResultSpecDecl.Ok SpecMaybeDecl.None state2)])]
          [(ResultSpecDecl.Err diag) (ResultSpecDecl.Err diag)]))]
    [(ast.AstDecl.DefMacro decl-meta name params ret body-box)
      (let
        [body : ast.AstExpr (spec-state-expr-get state body-box)]
        (match (spec-rewrite-expr body templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecDecl.Ok
              (SpecMaybeDecl.Some
                (ast.ast-decl-def-macro-id name params ret rewritten))
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecDecl.Err diag)]))]
    [_ (ResultSpecDecl.Ok (SpecMaybeDecl.Some decl) state)]))

(define (spec-rewrite-decls-with-owner
  [owner : SpecOwnerContext]
  [decls : ast.AstDeclList]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecDecls
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [cursor : ast.AstDeclList decls]
    [out : ast.AstDeclList (ast.ast-decl-list-with-capacity count)]
    [out-origins : parser.CompilerParseDeclOriginAliasVec
      (parser.compiler-parse-decl-origin-alias-vec-with-capacity count)]
    [cur-state : SpecState state]
    [result : ResultSpecDecls
      (ResultSpecDecls.Err
        (box
          (cdiag.compiler-diagnostic-simple
            "<internal>"
            1
            1
            "specialization rewrite did not finish")))]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast.ast-decl-list-step cursor)
          [(ast.AstDeclListStep.Nil)
            (begin
              (parser.compiler-parse-decl-origin-alias-vec-register!
                (& out)
                (& out-origins))
              (set! result (ResultSpecDecls.Ok out cur-state))
              (set! done true))]
          [(ast.AstDeclListStep.Cons decl rest)
            (match (spec-rewrite-decl-with-owner owner decl templates cur-state)
              [(ResultSpecDecl.Ok maybe-decl decl-state)
                (begin
                  (set! cur-state decl-state)
                  (match maybe-decl
                    [(SpecMaybeDecl.None) unit]
                    [(SpecMaybeDecl.Some rewritten-decl)
                      (begin
                        (ast.ast-decl-list-push (&mut out) rewritten-decl)
                        (parser.compiler-parse-decl-origin-alias-vec-push-key-slot!
                          (&mut out-origins)
                          (- (ast.ast-decl-list-len (& out)) 1)
                          1
                          (parser.compiler-parse-decl-list-storage-key (& rest))
                          (- (struct-get rest offset) 1)
                          decl
                          false))])
                  (set! cursor rest))]
              [(ResultSpecDecl.Err diag)
                (begin
                  (set! result (ResultSpecDecls.Err diag))
                  (set! done true))])]))
      result)))

(define (spec-rewrite-decls-with-paths-with-owner
  [owner : SpecOwnerContext]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [templates : SpecTemplateEnv]
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
      (ResultSpecDeclsWithPaths.Err
        (box
          (cdiag.compiler-diagnostic-simple
            "<internal>"
            1
            1
            "specialization rewrite with paths did not finish")))]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast.ast-decl-list-step decl-cursor)
          [(ast.AstDeclListStep.Nil)
            (begin
              (parser.compiler-parse-decl-origin-alias-vec-register!
                (& out)
                (& out-origins))
              (set!
                result
                (ResultSpecDeclsWithPaths.Ok out out-paths cur-state))
              (set! done true))]
          [(ast.AstDeclListStep.Cons decl rest)
            (let
              [decl-path : String
                (gen-path-list-head-or path-cursor fallback-path)]
              [owner-id : i64
                (ast.ast-decl-path-list-owner-id
                  (& path-cursor)
                  0
                  cbi.compiler-builtin-id-fix-empty)]
              (match (spec-rewrite-decl-with-owner
                owner
                decl
                templates
                cur-state)
                [(ResultSpecDecl.Ok maybe-decl decl-state)
                  (begin
                    (set! cur-state decl-state)
                    (match maybe-decl
                      [(SpecMaybeDecl.None) unit]
                      [(SpecMaybeDecl.Some rewritten-decl)
                        (begin
                          (ast.ast-decl-list-push (&mut out) rewritten-decl)
                          (parser.compiler-parse-decl-origin-alias-vec-push-key-slot!
                            (&mut out-origins)
                            (- (ast.ast-decl-list-len (& out)) 1)
                            1
                            (parser.compiler-parse-decl-list-storage-key
                              (& rest))
                            (- (struct-get rest offset) 1)
                            decl
                            false)
                          (ast.ast-decl-path-list-push-with-owner-id
                            (&mut out-paths)
                            decl-path
                            owner-id))])
                    (set! decl-cursor rest)
                    (set! path-cursor (gen-path-list-tail path-cursor)))]
                [(ResultSpecDecl.Err diag)
                  (begin
                    (set! result (ResultSpecDeclsWithPaths.Err diag))
                    (set! done true))]))]))
      result)))

(define (spec-generated-paths
  [decls : ast.AstDeclList]
  [fallback-path : String]) : ast.AstDeclPathList
  (if (string.eq fallback-path "")
    (ast.ast-decl-path-list-new)
    (gen-path-list-for-decls
      decls
      fallback-path
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
    (match (gen-normalize-program-with-pools-and-intern-state program owner)
      [(ResultGenProgram.Ok normalized)
        (match normalized
          [(ast.AstProgram.Program decls-box)
            (let
              [decls : ast.AstDeclList (box-get decls-box)]
              [templates : SpecTemplateList
                (spec-collect-templates-with-pools
                  (spec-owner-pools owner)
                  decls)]
              [ctfe-env : ctfe.CtfeEnv
                (spec-owner-ctfe-env
                  owner
                  (ctfe.ctfe-reflections-from-program normalized))]
              (if (= (struct-get templates len) 0)
                (ResultSpecProgram.Ok normalized)
                (match (spec-rewrite-decls-with-owner
                  owner
                  decls
                  (spec-template-env-from-list templates)
                  (SpecState.State
                    (ast.ast-decl-list-new)
                    (spec_id_i64_map.with-capacity 64)
                    ctfe-env
                    owner))
                  [(ResultSpecDecls.Ok rewritten state)
                    (match state
                      [(SpecState.State generated _ _ _)
                        (begin
                          (spec-materialize-owner-generated-symbols! owner)
                          (ResultSpecProgram.Ok
                            (ast.ast-program
                              (spec-decl-list-append rewritten generated))))])]
                  [(ResultSpecDecls.Err diag) (ResultSpecProgram.Err diag)])))])]
      [(ResultGenProgram.Err diag) (ResultSpecProgram.Err diag)])))

(define (compiler-specialize-program-with-paths-and-pools-and-intern-state
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]
  [pools : ast.AstNodePoolContext]
  [intern-state : spec_ci.InternCompatState]) : ResultSpecProgramWithPaths
  (let
    [owner : SpecOwnerContext (spec-owner-context-new pools intern-state)]
    (match (gen-normalize-program-with-paths-and-pools-and-intern-state
      program
      paths
      fallback-path
      owner)
      [(ResultGenProgramWithPaths.Ok normalized normalized-paths)
        (match normalized
          [(ast.AstProgram.Program decls-box)
            (let
              [decls : ast.AstDeclList (box-get decls-box)]
              [templates : SpecTemplateList
                (spec-collect-templates-with-pools
                  (spec-owner-pools owner)
                  decls)]
              [ctfe-env : ctfe.CtfeEnv
                (spec-owner-ctfe-env
                  owner
                  (ctfe.ctfe-reflections-from-program normalized))]
              (if (= (struct-get templates len) 0)
                (ResultSpecProgramWithPaths.Ok normalized normalized-paths)
                (match (spec-rewrite-decls-with-paths-with-owner
                  owner
                  decls
                  normalized-paths
                  fallback-path
                  (spec-template-env-from-list templates)
                  (SpecState.State
                    (ast.ast-decl-list-new)
                    (spec_id_i64_map.with-capacity 64)
                    ctfe-env
                    owner))
                  [(ResultSpecDeclsWithPaths.Ok rewritten rewritten-paths state)
                    (match state
                      [(SpecState.State generated _ _ _)
                        (begin
                          (spec-materialize-owner-generated-symbols! owner)
                          (ResultSpecProgramWithPaths.Ok
                            (ast.ast-program
                              (spec-decl-list-append rewritten generated))
                            (spec-decl-path-list-append
                              rewritten-paths
                              (spec-generated-paths generated fallback-path))))])]
                  [(ResultSpecDeclsWithPaths.Err diag)
                    (ResultSpecProgramWithPaths.Err diag)])))])]
      [(ResultGenProgramWithPaths.Err diag)
        (ResultSpecProgramWithPaths.Err diag)])))

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
    (begin
      (ast.ast-node-pool-context-install! pools)
      (spec_ci.intern-compat-state-install! intern-state)
      (let
        [result : ResultSpecProgram
          (compiler-specialize-program-with-pools-and-intern-state
            program
            pools
            intern-state)]
        (begin
          (ast.ast-node-pool-context-install! previous-pools)
          (spec_ci.intern-compat-state-install! intern-state)
          result)))))

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
    (begin
      (ast.ast-node-pool-context-install! pools)
      (spec_ci.intern-compat-state-install! intern-state)
      (let
        [result : ResultSpecProgramWithPaths
          (compiler-specialize-program-with-paths-and-pools-and-intern-state
            program
            paths
            fallback-path
            pools
            intern-state)]
        (begin
          (ast.ast-node-pool-context-install! previous-pools)
          (spec_ci.intern-compat-state-install! intern-state)
          result)))))

(define (compiler-specialize-program [program : ast.AstProgram]) : ResultSpecProgram
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultSpecProgram
      (compiler-specialize-program-with-pools program pools)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (compiler-specialize-program-with-paths
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]) : ResultSpecProgramWithPaths
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultSpecProgramWithPaths
      (compiler-specialize-program-with-paths-and-pools
        program
        paths
        fallback-path
        pools)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (compiler-specialize-needed-with-pools
  [program : ast.AstProgram]
  [pools : ast.AstNodePoolContext]) : bool
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (box-get decls-box)]
        (if (gen-decls-needed? decls)
          true
          (let
            [templates : SpecTemplateList
              (spec-collect-templates-with-pools pools decls)]
            (> (struct-get templates len) 0))))]))

(define (compiler-specialize-needed? [program : ast.AstProgram]) : bool
  (compiler-specialize-needed-with-pools
    program
    (ast.ast-node-pool-context-capture-active)))

(define (compiler-specialize-decl-list-defines?
  [decls : ast.AstDeclList]
  [name : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) false]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (ast.ast-decl-unwrapped decl)
          [(ast.AstDecl.DefFn decl-meta fn-name _ _ _ _)
            (if (string.eq (spec_ci.intern-str fn-name) name)
              true
              (compiler-specialize-decl-list-defines? rest name))]
          [_ (compiler-specialize-decl-list-defines? rest name)]))]))

(define (compiler-specialize-type-param-source) : String
  "(define (alloc [comptime T : type] [n : i64]) : (__tl_dyn-array i64)
  (make-array T n))
(define (main) : (__tl_dyn-array i64)
  (alloc (type i64) 4))")

(define (compiler-specialize-runtime-type-use-source) : String
  "(define (bad [comptime T : type] [n : i64]) : i64 T)
(define (main) : i64 (bad (type i64) 4))")

(define (compiler-specialize-template-shadow-source) : String
  "(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))
(define (use-shadow [scale : (-> i64 i64)]) : i64 (scale 7))")

(define (compiler-specialize-template-shadow-sibling-source) : String
  "(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))
(define (main) : i64
  (+ (let [scale : i64 3] scale) (scale 2 7)))")

(define (compiler-specialize-type-shadow-source) : String
  "(define (pick [comptime T : type] [x : i64]) : i64
  (let [T : i64 x] T))
(define (main) : i64 (pick (type i64) 7))")

(define (compiler-specialize-type-param-ok?) : bool
  (match (parser.parse-ast-source (compiler-specialize-type-param-source))
    [(parser.ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok specialized)
          (match specialized
            [(ast.AstProgram.Program decls-box)
              (let
                [decls : ast.AstDeclList (box-get decls-box)]
                (and
                  (not (compiler-specialize-decl-list-defines? decls "alloc"))
                  (compiler-specialize-decl-list-defines?
                    decls
                    "__tl_specialized_alloc_type_i64_none")))])]
        [(ResultSpecProgram.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-specialize-runtime-type-use-rejected?) : bool
  (match (parser.parse-ast-source (compiler-specialize-runtime-type-use-source))
    [(parser.ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok _) false]
        [(ResultSpecProgram.Err _) true])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-specialize-template-shadow-ok?) : bool
  (match (parser.parse-ast-source (compiler-specialize-template-shadow-source))
    [(parser.ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok _) true]
        [(ResultSpecProgram.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-specialize-template-shadow-sibling-ok?) : bool
  (match (parser.parse-ast-source
    (compiler-specialize-template-shadow-sibling-source))
    [(parser.ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok specialized)
          (match specialized
            [(ast.AstProgram.Program decls-box)
              (let
                [decls : ast.AstDeclList (box-get decls-box)]
                [original : bool
                  (compiler-specialize-decl-list-defines? decls "scale")]
                [generated : bool
                  (compiler-specialize-decl-list-defines?
                    decls
                    "__tl_specialized_scale_i64_2_none")]
                (and (not original) generated))])]
        [(ResultSpecProgram.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-specialize-type-shadow-ok?) : bool
  (match (parser.parse-ast-source (compiler-specialize-type-shadow-source))
    [(parser.ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok specialized)
          (match specialized
            [(ast.AstProgram.Program decls-box)
              (let
                [decls : ast.AstDeclList (box-get decls-box)]
                (compiler-specialize-decl-list-defines?
                  decls
                  "__tl_specialized_pick_type_i64_none"))])]
        [(ResultSpecProgram.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-specialize-raw-pointer-type-ok?) : bool
  (let
    [subs : SpecTypeSubst
      (spec-type-subst-cons
        cbi.compiler-builtin-id-fix-T
        (ast.AstType.I64)
        (spec-type-subst-new))]
    (and
      (string.eq (spec-type-key (ast.ast-ty-ptr (ast.AstType.I64))) "ptr_i64")
      (string.eq
        (spec-type-key (ast.ast-ty-mut-ptr (ast.ast-ty-ptr (ast.AstType.U8))))
        "mutptr_ptr_u8")
      (ctfe.ctfe-type-eq
        (spec-substitute-type
          (ast.ast-ty-mut-ptr (ast.AstType.Var cbi.compiler-builtin-id-fix-T))
          subs)
        (ast.ast-ty-mut-ptr (ast.AstType.I64))))))

(define (compiler-specialize-owner-slice-type-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [intern-state : spec_ci.InternCompatState (spec_ci.intern-compat-state-new)]
    [owner : SpecOwnerContext (spec-owner-context-new pools intern-state)]
    [slice-i64 : ast.AstType
      (ast.ast-ty-slice-with-pools pools ast.AstType.I64)]
    [slice-t : ast.AstType
      (ast.ast-ty-slice-with-pools
        pools
        (ast.AstType.Var cbi.compiler-builtin-id-fix-T))]
    [subs : SpecTypeSubst
      (spec-type-subst-cons
        cbi.compiler-builtin-id-fix-T
        ast.AstType.I64
        (spec-type-subst-new))]
    [substituted : ast.AstType
      (spec-substitute-type-with-owner owner slice-t subs)]
    (and
      (string.eq (spec-type-key-with-owner owner slice-i64) "slice_i64")
      (match substituted
        [(ast.AstType.Slice elem)
          (match (spec-owner-type-get owner elem)
            [(ast.AstType.I64) true]
            [_ false])]
        [_ false]))))

;: Deterministic specialized name + stable specialization key (mirrors
;: src/specialize.rs deterministic-names / stable-keys coverage). The mangling
;: is a pure function of the template name and comptime argument values, so
;: identical args produce identical names, distinct type args never collide,
;: multi-value ordering is stable, and negative scalars / arbitrary strings
;: encode without punctuation that could break generated identifiers.
(define (compiler-specialize-name-key-ok?) : bool
  (let
    [vals-i64 : SpecValueList
      (spec-value-cons
        (ctfe.CompilerCtfeValue.Type (ast.AstType.I64))
        (spec-value-list-new))]
    [vals-bool : SpecValueList
      (spec-value-cons
        (ctfe.CompilerCtfeValue.Type (ast.AstType.Bool))
        (spec-value-list-new))]
    [vals-multi : SpecValueList
      (spec-value-cons
        (ctfe.CompilerCtfeValue.Type (ast.AstType.I64))
        (spec-value-cons (ctfe.CompilerCtfeValue.I64 5) (spec-value-list-new)))]
    [vals-string : SpecValueList
      (spec-value-cons
        (ctfe.ctfe-generated-string-value "a b")
        (spec-value-list-new))]
    (and
      (string.eq
        (spec-specialized-name "alloc" vals-i64)
        "__tl_specialized_alloc_type_i64_none")
      (string.eq
        (spec-specialized-name "alloc" vals-i64)
        (spec-specialized-name "alloc" vals-i64))
      (string.eq
        (spec-specialization-key "alloc" vals-i64)
        "alloc:type_i64_none")
      (not
        (string.eq
          (spec-specialized-name "alloc" vals-i64)
          (spec-specialized-name "alloc" vals-bool)))
      (string.eq
        (spec-specialized-name "pair" vals-multi)
        "__tl_specialized_pair_type_i64_i64_5_none")
      (string.eq (spec-value-key (ctfe.CompilerCtfeValue.I64 (- 0 3))) "i64_m3")
      (string.eq
        (spec-specialized-name "name" vals-string)
        "__tl_specialized_name_string_3_97_32_98_none"))))

(define (compiler-specialize-structural-key-ok?) : bool
  (let
    [pools-a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 32 32)]
    [pools-b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 32 32)]
    [intern-a : spec_ci.InternCompatState (spec_ci.intern-compat-state-new)]
    [intern-b : spec_ci.InternCompatState (spec_ci.intern-compat-state-new)]
    [owner-a : SpecOwnerContext (spec-owner-context-new pools-a intern-a)]
    [owner-b : SpecOwnerContext (spec-owner-context-new pools-b intern-b)]
    [nested-a : ast.AstType
      (ast.ast-ty-ptr-with-pools
        pools-a
        (ast.ast-ty-array-with-pools pools-a (ast.AstType.I64) 7))]
    [nested-b : ast.AstType
      (ast.ast-ty-ptr-with-pools
        pools-b
        (ast.ast-ty-array-with-pools pools-b (ast.AstType.I64) 7))]
    [values-a : SpecValueList
      (spec-value-cons
        (ctfe.CompilerCtfeValue.Type nested-a)
        (spec-value-cons
          (ctfe.CompilerCtfeValue.I64 -3)
          (spec-value-cons
            (ctfe.CompilerCtfeValue.String "a b" 1)
            (spec-value-list-new))))]
    [values-a-name : SpecValueList
      (spec-value-cons
        (ctfe.CompilerCtfeValue.Type nested-a)
        (spec-value-cons
          (ctfe.CompilerCtfeValue.I64 -3)
          (spec-value-cons
            (ctfe.CompilerCtfeValue.Name "a b" 999)
            (spec-value-list-new))))]
    [values-b : SpecValueList
      (spec-value-cons
        (ctfe.CompilerCtfeValue.Type nested-b)
        (spec-value-cons
          (ctfe.CompilerCtfeValue.I64 -3)
          (spec-value-cons
            (ctfe.CompilerCtfeValue.Name "a b" 4)
            (spec-value-list-new))))]
    [key-a : SpecStructuralKey
      (spec-specialization-structural-key-with-owner owner-a "alloc" values-a)]
    [count-after-first : i64
      (spec_ci.intern-compat-state-structural-count intern-a)]
    [key-a-again : SpecStructuralKey
      (spec-specialization-structural-key-with-owner
        owner-a
        "alloc"
        values-a-name)]
    [count-after-repeat : i64
      (spec_ci.intern-compat-state-structural-count intern-a)]
    [different : SpecStructuralKey
      (spec-specialization-structural-key-with-owner
        owner-a
        "alloc"
        (spec-value-cons
          (ctfe.CompilerCtfeValue.Type nested-a)
          (spec-value-cons
            (ctfe.CompilerCtfeValue.I64 -4)
            (spec-value-cons
              (ctfe.CompilerCtfeValue.String "a b" 1)
              (spec-value-list-new)))))]
    [key-b : SpecStructuralKey
      (spec-specialization-structural-key-with-owner owner-b "alloc" values-b)]
    [render-before : String
      (spec_ci.intern-compat-state-composite-rendered-name
        intern-a
        (spec-structural-key-raw key-a))]
    [symbol-handle : i64
      (spec-reserve-specialized-symbol-with-owner
        owner-a
        key-a
        "alloc"
        values-a)]
    [symbol-before : String
      (spec_ci.intern-compat-state-str intern-a symbol-handle)]
    [_materialized : unit (spec-materialize-owner-generated-symbols! owner-a)]
    [rendered : String (spec_ci.intern-compat-state-str intern-a symbol-handle)]
    [rendered-again : String
      (spec-render-specialized-name-with-owner owner-a key-a "alloc" values-a)]
    [old-raw : i64 (spec-structural-key-raw key-a)]
    (and
      (> count-after-first 0)
      (= count-after-first count-after-repeat)
      (= (spec-structural-key-raw key-a) (spec-structural-key-raw key-a-again))
      (not
        (= (spec-structural-key-raw key-a) (spec-structural-key-raw different)))
      (not (= (spec-structural-key-raw key-a) (spec-structural-key-raw key-b)))
      (string.eq render-before "")
      (string.eq symbol-before "")
      (spec_ci.intern-compat-state-generated-id-active? intern-a symbol-handle)
      (not (= symbol-handle (spec-structural-key-raw key-a)))
      (string.eq
        rendered
        "__tl_specialized_alloc_type_ptr_array_i64_7_i64_m3_string_3_97_32_98_none")
      (string.eq rendered rendered-again)
      (begin
        (spec_ci.intern-compat-state-reset-to! intern-a 0)
        (and
          (not
            (spec_ci.intern-compat-state-generated-id-active?
              intern-a
              symbol-handle))
          (not
            (=
              old-raw
              (spec-structural-key-raw
                (spec-specialization-structural-key-with-owner
                  owner-a
                  "alloc"
                  (spec-value-cons
                    (ctfe.CompilerCtfeValue.I64 -3)
                    (spec-value-list-new)))))))))))

;: Count function declarations named `name` in `decls` (specialized decls are
;: emitted as ordinary `AstDecl.DefFn`s, so reuse means a count of exactly 1).
(define (compiler-specialize-decl-list-count-defs
  [decls : ast.AstDeclList]
  [name : String]) : i64
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) 0]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (ast.ast-decl-unwrapped decl)
          [(ast.AstDecl.DefFn decl-meta fn-name _ _ _ _)
            (if (string.eq (spec_ci.intern-str fn-name) name)
              (+ 1 (compiler-specialize-decl-list-count-defs rest name))
              (compiler-specialize-decl-list-count-defs rest name))]
          [_ (compiler-specialize-decl-list-count-defs rest name)]))]))

(define (compiler-specialize-decl-list-count-visible
  [decls : ast.AstDeclList]
  [name : String]) : i64
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) 0]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        [tail-count : i64
          (compiler-specialize-decl-list-count-visible rest name)]
        (match (gen-decl-visible-name decl)
          [(SpecMaybeString.Some found)
            (if (string.eq found name)
              (+ 1 tail-count)
              tail-count)]
          [(SpecMaybeString.None) tail-count]))]))

;: Two call sites that request the SAME specialization (`alloc` at `type i64`)
;: must share one generated decl via the specialization cache, not emit two.
(define (compiler-specialize-reuse-source) : String
  "(define (alloc [comptime T : type] [n : i64]) : (__tl_dyn-array i64)
  (make-array T n))
(define (main) : (__tl_dyn-array i64)
  (begin (alloc (type i64) 4) (alloc (type i64) 8)))")

;: Specialization reuse (mirrors src/specialize.rs reuse coverage): two
;: identical `alloc (type i64)` requests collapse to a single shared
;: `__tl_specialized_alloc_type_i64_none` decl (the cache dedups by key) and the
;: `alloc` template is removed.
(define (compiler-specialize-reuse-ok?) : bool
  (match (parser.parse-ast-source (compiler-specialize-reuse-source))
    [(parser.ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok specialized)
          (match specialized
            [(ast.AstProgram.Program decls-box)
              (let
                [decls : ast.AstDeclList (box-get decls-box)]
                (and
                  (not (compiler-specialize-decl-list-defines? decls "alloc"))
                  (=
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "__tl_specialized_alloc_type_i64_none")
                    1)))])]
        [(ResultSpecProgram.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

;: Type substitution (mirrors src/specialize.rs substitution coverage):
;: `spec-substitute-type` replaces a mapped type variable with its bound type,
;: recurses through compound types (Ptr/DynArray/function), and leaves an
;: unmapped variable unchanged (the SpecMaybeId.None lookup branch). Complements
;: the single MutPtr case embedded in `compiler-specialize-raw-pointer-type-ok?`.
(define (compiler-specialize-subst-ok?) : bool
  (let
    [subs : SpecTypeSubst
      (spec-type-subst-cons
        cbi.compiler-builtin-id-fix-T
        (ast.AstType.I64)
        (spec-type-subst-new))]
    (and
      (string.eq
        (spec-type-key
          (spec-substitute-type
            (ast.AstType.Var cbi.compiler-builtin-id-fix-T)
            subs))
        "i64")
      (string.eq
        (spec-type-key
          (spec-substitute-type
            (ast.ast-ty-ptr (ast.AstType.Var cbi.compiler-builtin-id-fix-T))
            subs))
        "ptr_i64")
      (string.eq
        (spec-type-key
          (spec-substitute-type
            (ast.ast-ty-dyn-array
              (ast.AstType.Var cbi.compiler-builtin-id-fix-T))
            subs))
        "dynarray_i64")
      (string.eq
        (spec-type-key
          (spec-substitute-type
            (ast.ast-ty-func
              (ast.ast-type-cons
                (ast.AstType.Var cbi.compiler-builtin-id-fix-T)
                (ast.ast-type-list-new))
              (ast.AstType.Var cbi.compiler-builtin-id-fix-T))
            subs))
        "fn_i64_nil_to_i64")
      (string.eq
        (spec-type-key
          (spec-substitute-type
            (ast.AstType.Var cbi.compiler-builtin-id-fix-U)
            subs))
        "var_U"))))

;: Value (comptime-argument) substitution (mirrors src/specialize.rs
;: substitution coverage): `spec-substitute-values-expr` replaces a variable
;: bound to a comptime value with that value's literal, leaves unmapped
;: variables and literals unchanged, and recurses through compound expressions.
(define (compiler-specialize-value-subst-ok?) : bool
  (let
    [subs : SpecValueSubst
      (spec-value-subst-cons
        cbi.compiler-builtin-id-fix-x
        (ctfe.CompilerCtfeValue.I64 5)
        (spec-value-subst-new))]
    (and
      ;; mapped variable x -> integer literal 5
      (match (spec-substitute-values-expr
        (ast.AstExpr.Var cbi.compiler-builtin-id-fix-x)
        subs)
        [(ResultSpecSubExpr.Ok e)
          (match (ast.ast-node-get e)
            [(ast.AstExpr.Literal lit)
              (match lit
                [(ast.AstLiteral.Int n _) (= n 5)]
                [_ false])]
            [_ false])]
        [(ResultSpecSubExpr.Err _) false])
      ;; unmapped variable y -> unchanged
      (match (spec-substitute-values-expr
        (ast.AstExpr.Var cbi.compiler-builtin-id-fix-y)
        subs)
        [(ResultSpecSubExpr.Ok e)
          (match (ast.ast-node-get e)
            [(ast.AstExpr.Var name) (string.eq (spec_ci.intern-str name) "y")]
            [_ false])]
        [(ResultSpecSubExpr.Err _) false])
      ;; recursion through `if`: x in the condition becomes 5, unmapped y stays
      (match (spec-substitute-values-expr
        (ast.AstExpr.If
          (ast.ast-node-push (ast.AstExpr.Var cbi.compiler-builtin-id-fix-x))
          (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 1)))
          (ast.ast-node-push (ast.AstExpr.Var cbi.compiler-builtin-id-fix-y)))
        subs)
        [(ResultSpecSubExpr.Ok e)
          (match (ast.ast-node-get e)
            [(ast.AstExpr.If cond-box _ else-branch-box)
              (let
                [cond : ast.AstExpr (ast.ast-node-get cond-box)]
                [else-branch : ast.AstExpr (ast.ast-node-get else-branch-box)]
                (and
                  (match cond
                    [(ast.AstExpr.Literal lit)
                      (match lit
                        [(ast.AstLiteral.Int n _) (= n 5)]
                        [_ false])]
                    [_ false])
                  (match else-branch
                    [(ast.AstExpr.Var name)
                      (string.eq (spec_ci.intern-str name) "y")]
                    [_ false])))]
            [_ false])]
        [(ResultSpecSubExpr.Err _) false]))))

(define (compiler-specialize-boxed-tails-ok?) : bool
  (let
    [templates : SpecTemplateList
      (let
        [out : SpecTemplateList (spec-template-list-new)]
        (begin
          (spec-template-list-push
            (&mut out)
            (SpecTemplate.Item
              cbi.compiler-builtin-id-fix-x
              (ast.ast-param-list-new)
              (ast.AstType.I64)
              (ast.AstExpr.Literal (ast.ast-lit-int 1))))
          (spec-template-list-push
            (&mut out)
            (SpecTemplate.Item
              cbi.compiler-builtin-id-fix-second
              (ast.ast-param-list-new)
              (ast.AstType.Bool)
              (ast.AstExpr.Literal (ast.AstLiteral.Bool true))))
          out))]
    [template-env : SpecTemplateEnv (spec-template-env-from-list templates)]
    [cache : spec_id_i64_map.Map
      (let
        [seed-cache : spec_id_i64_map.Map (spec_id_i64_map.with-capacity 8)]
        (begin
          (spec_id_i64_map.insert-ref!
            (&mut seed-cache)
            cbi.compiler-builtin-id-fix-second
            cbi.compiler-builtin-id-fix-second)
          (spec_id_i64_map.insert-ref!
            (&mut seed-cache)
            cbi.compiler-builtin-id-fix-x
            cbi.compiler-builtin-id-fix-x)
          seed-cache))]
    [values : SpecValueList
      (spec-value-cons
        (ctfe.CompilerCtfeValue.I64 1)
        (spec-value-cons
          (ctfe.CompilerCtfeValue.Bool true)
          (spec-value-list-new)))]
    [value-subs : SpecValueSubst
      (spec-value-subst-cons
        cbi.compiler-builtin-id-fix-x
        (ctfe.CompilerCtfeValue.I64 1)
        (spec-value-subst-cons
          cbi.compiler-builtin-id-fix-flag
          (ctfe.CompilerCtfeValue.Bool true)
          (spec-value-subst-new)))]
    [type-subs : SpecTypeSubst
      (spec-type-subst-cons
        cbi.compiler-builtin-id-fix-T
        (ast.AstType.I64)
        (spec-type-subst-cons
          cbi.compiler-builtin-id-fix-U
          (ast.AstType.Bool)
          (spec-type-subst-new)))]
    (and
      (match (spec-template-lookup
        template-env
        cbi.compiler-builtin-id-fix-second)
        [(SpecMaybeTemplate.Some template)
          (match template
            [(SpecTemplate.Item name _ _ _)
              (= name cbi.compiler-builtin-id-fix-second)])]
        [(SpecMaybeTemplate.None) false])
      (match (spec-cache-lookup cache cbi.compiler-builtin-id-fix-second)
        [(SpecMaybeId.Some name-id)
          (= name-id cbi.compiler-builtin-id-fix-second)]
        [(SpecMaybeId.None) false])
      (string.eq (spec-values-key values) "i64_1_bool_1_none")
      (match (spec-value-subst-value
        value-subs
        cbi.compiler-builtin-id-fix-flag)
        [(ctfe.CompilerCtfeValue.Bool flag) flag]
        [_ false])
      (ctfe.ctfe-type-eq
        (spec-type-subst-type type-subs cbi.compiler-builtin-id-fix-U)
        (ast.AstType.Bool)))))

(define (compiler-specialize-reflection-string-param-source) : String
  "(defstruct Point (x i64))
(define (tag-helper [comptime key : String] [x : i64]) : i64 x)
(define (main) : i64 (tag-helper (type-key (type Point)) 7))")

(define (compiler-specialize-reflection-string-param-ok?) : bool
  (match (parser.parse-ast-source
    (compiler-specialize-reflection-string-param-source))
    [(parser.ResultAstProgram.Ok program)
      (let
        [pools-before : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        [expr-len-before : i64
          (ast.ast-node-pool-context-expr-len pools-before)]
        [specialized-result : ResultSpecProgram
          (compiler-specialize-program program)]
        (match specialized-result
          [(ResultSpecProgram.Ok specialized)
            (let
              [pools-after : ast.AstNodePoolContext
                (ast.ast-node-pool-context-capture-active)]
              (and
                (>
                  (ast.ast-node-pool-context-expr-len pools-after)
                  expr-len-before)
                (match specialized
                  [(ast.AstProgram.Program decls-box)
                    (let
                      [decls : ast.AstDeclList (box-get decls-box)]
                      (compiler-specialize-decl-list-defines?
                        decls
                        "__tl_specialized_tag-helper_string_12_115_116_114_117_99_116_95_80_111_105_110_116_none"))])))]
          [(ResultSpecProgram.Err _) false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-reuse-source) : String
  "(defstruct Box_String (value String))
(defstruct Box_String (value String))")

(define (compiler-generated-decl-function-reuse-source) : String
  "(define (make-box-string [value : String]) : String value)
(define (make-box-string [value : String]) : String value)")

(define (compiler-generated-decl-incompatible-source) : String
  "(defstruct Box_String (value String))
(defstruct Box_String (value i64))")

(define (compiler-generated-decl-expected-string-key) : String
  (gen-full-key
    ""
    "sample-family"
    "Box_String"
    (str_cat.str-cat (spec-string-key "String") "_none")))

(define (compiler-generated-decl-mark!
  [program : ast.AstProgram]
  [index : i64]
  [generator : String]
  [item : String]
  [arg : String]) : unit
  (if (< index 0)
    unit
    (match program
      [(ast.AstProgram.Program decls-box)
        (let
          [decls : ast.AstDeclList (box-get decls-box)]
          [args : ast.AstExprList (ast.ast-expr-list-new)]
          (begin
            (ast.ast-expr-list-push
              (&mut args)
              (ast.ast-node-push
                (ast.AstExpr.Literal (ast.ast-lit-generated-string arg))))
            (array-set!
              (struct-get decls slots)
              (+ (struct-get decls offset) index)
              (ast.ast-decl-comptime-decl-with-meta
                (ast.AstGeneratedDeclMeta.Some generator item args "")
                (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback))))))])))

(define (compiler-generated-decl-pair
  [source : String]
  [first-index : i64]
  [generator : String]
  [item : String]
  [first-arg : String]
  [second-index : i64]
  [second-arg : String]) : parser.ResultAstProgram
  (match (parser.parse-ast-source source)
    [(parser.ResultAstProgram.Ok program)
      (begin
        (compiler-generated-decl-mark!
          program
          first-index
          generator
          item
          first-arg)
        (compiler-generated-decl-mark!
          program
          second-index
          generator
          item
          second-arg)
        (parser.ResultAstProgram.Ok program))]
    [(parser.ResultAstProgram.Err message)
      (parser.ResultAstProgram.Err message)]))

(define (compiler-generated-decl-reuse-program) : parser.ResultAstProgram
  (compiler-generated-decl-pair
    (compiler-generated-decl-reuse-source)
    0
    "sample-family"
    "Box_String"
    "String"
    1
    "String"))

(define (compiler-generated-decl-function-reuse-program) : parser.ResultAstProgram
  (compiler-generated-decl-pair
    (compiler-generated-decl-function-reuse-source)
    0
    "function-family"
    "make-box-string"
    "String"
    1
    "String"))

(define (compiler-generated-decl-incompatible-program) : parser.ResultAstProgram
  (compiler-generated-decl-pair
    (compiler-generated-decl-incompatible-source)
    0
    "sample-family"
    "Box_String"
    "String"
    1
    "String"))

(define (compiler-generated-decl-reuse-ok?) : bool
  (match (compiler-generated-decl-reuse-program)
    [(parser.ResultAstProgram.Ok program)
      (and
        (compiler-specialize-needed? program)
        (match (compiler-specialize-program program)
          [(ResultSpecProgram.Ok normalized)
            (match normalized
              [(ast.AstProgram.Program decls-box)
                (let
                  [decls : ast.AstDeclList (box-get decls-box)]
                  (=
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "Box_String")
                    1))])]
          [(ResultSpecProgram.Err _) false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-function-reuse-ok?) : bool
  (match (compiler-generated-decl-function-reuse-program)
    [(parser.ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok normalized)
          (match normalized
            [(ast.AstProgram.Program decls-box)
              (let
                [decls : ast.AstDeclList (box-get decls-box)]
                (=
                  (compiler-specialize-decl-list-count-defs
                    decls
                    "make-box-string")
                  1))])]
        [(ResultSpecProgram.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-incompatible-rejected?) : bool
  (match (compiler-generated-decl-incompatible-program)
    [(parser.ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok _) false]
        [(ResultSpecProgram.Err _) true])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-incompatible-note-ok?) : bool
  (match (compiler-generated-decl-incompatible-program)
    [(parser.ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok _) false]
        [(ResultSpecProgram.Err diag)
          (let
            [value : cdiag.CompilerDiagnostic (box-get diag)]
            [notes : cdiag.CompilerDiagnosticNoteList
              (cdiag.compiler-diagnostic-notes value)]
            (and
              (string.eq
                (cdiag.compiler-diagnostic-message value)
                "generated-decl: duplicate generated key for Box_String has incompatible payload")
              (= (cdiag.compiler-diagnostic-note-list-count notes) 2)
              (string.eq
                (cdiag.compiler-diagnostic-note-list-get notes 0)
                (str_cat.str-cat
                  "generated identity: "
                  (compiler-generated-decl-expected-string-key)))
              (string.eq
                (cdiag.compiler-diagnostic-note-list-get notes 1)
                "generated declaration: Box_String from sample-family")))])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-incompatible-path-ok?) : bool
  (match (compiler-generated-decl-incompatible-program)
    [(parser.ResultAstProgram.Ok program)
      (match (compiler-specialize-program-with-paths
        program
        (ast.ast-decl-root-path-cons
          "generated/first.tl"
          (ast.ast-decl-root-path-cons
            "generated/second.tl"
            (ast.ast-decl-path-list-new)))
        "generated/fallback.tl")
        [(ResultSpecProgramWithPaths.Ok _ _) false]
        [(ResultSpecProgramWithPaths.Err diag)
          (let
            [value : cdiag.CompilerDiagnostic (box-get diag)]
            (string.eq
              (cdiag.compiler-diagnostic-path value)
              "generated/second.tl"))])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-origin-preserved-ok?) : bool
  (match (compiler-generated-decl-reuse-program)
    [(parser.ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok normalized)
          (match normalized
            [(ast.AstProgram.Program decls-box)
              (match (ast.ast-decl-list-step (box-get decls-box))
                [(ast.AstDeclListStep.Cons decl _)
                  (and
                    (match (ast.ast-decl-generated-meta decl)
                      [(ast.AstGeneratedDeclMeta.Some generator item _ key)
                        (and
                          (string.eq generator "sample-family")
                          (string.eq item "Box_String")
                          (string.eq
                            key
                            (compiler-generated-decl-expected-string-key)))]
                      [(ast.AstGeneratedDeclMeta.No) false])
                    (match decl
                      [(ast.AstDecl.DefStruct decl-meta name _ _ _)
                        (string.eq (spec_ci.intern-str name) "Box_String")]
                      [_ false]))]
                [(ast.AstDeclListStep.Nil) false])])]
        [(ResultSpecProgram.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-generated-registry-map-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [intern-state : spec_ci.InternCompatState (spec_ci.intern-compat-state-new)]
    [owner : SpecOwnerContext (spec-owner-context-new pools intern-state)]
    [name-id : i64 (spec-materialize-generated-name-id "RegistryBox")]
    [decl : ast.AstDecl
      (ast.ast-decl-def-struct-id
        name-id
        ast.AstStructRepr.Default
        ast.AstStructCleanup.No
        (ast.ast-field-def-list-new))]
    [key : SpecStructuralKey
      (gen-registry-structural-key-with-owner
        owner
        -1
        cbi.compiler-builtin-id-fix-x
        "registry-test"
        "RegistryBox"
        "generated-key")]
    [registry : GenRegistry
      (gen-registry-insert-with-owner (gen-registry-empty) key decl)]
    (match (gen-registry-lookup-with-owner registry key)
      [(GenMaybeEntry.Some found) (gen-decl-eq? found decl)]
      [(GenMaybeEntry.None) false])))

(define (compiler-generated-decl-spmd-metadata-distinct-ok?) : bool
  (let
    [a-classes : ast.AstSpmdParamClassList (ast.ast-spmd-param-class-list-new)]
    [b-classes : ast.AstSpmdParamClassList (ast.ast-spmd-param-class-list-new)]
    [a-items : ast.AstSpmdSpecializationList
      (ast.ast-spmd-specialization-list-new)]
    [b-items : ast.AstSpmdSpecializationList
      (ast.ast-spmd-specialization-list-new)]
    [generated-id : i64 (spec_ci.intern-generated-canonical-name "generated")]
    [body : i64 (ast.ast-node-push (ast.AstExpr.Literal (ast.ast-lit-int 0)))]
    (begin
      (ast.ast-spmd-param-class-list-push
        (&mut a-classes)
        ast.AstSpmdParamClass.Varying)
      (ast.ast-spmd-param-class-list-push
        (&mut b-classes)
        ast.AstSpmdParamClass.Varying)
      (ast.ast-spmd-specialization-list-push
        (&mut a-items)
        (ast.AstSpmdSpecialization
          8
          (box a-classes)
          ast.AstSpmdResultClass.Varying
          0))
      (ast.ast-spmd-specialization-list-push
        (&mut b-items)
        (ast.AstSpmdSpecialization
          16
          (box b-classes)
          ast.AstSpmdResultClass.Varying
          0))
      (not
        (gen-decl-eq?
          (ast.ast-decl-def-fn-metadata-id
            generated-id
            (ast.ast-param-list-new)
            (ast.AstType.I64)
            body
            (ast.ast-fn-metadata-full
              ast.AstFnExport.No
              (ast.AstSpmdCallable.Callable a-items)))
          (ast.ast-decl-def-fn-metadata-id
            generated-id
            (ast.ast-param-list-new)
            (ast.AstType.I64)
            body
            (ast.ast-fn-metadata-full
              ast.AstFnExport.No
              (ast.AstSpmdCallable.Callable b-items))))))))

(define (compiler-specialize-generated-symbol-records-growth-ok?) : bool
  (let
    [count : i64 32]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 32 32)]
    [intern-state : spec_ci.InternCompatState (spec_ci.intern-compat-state-new)]
    [owner : SpecOwnerContext (spec-owner-context-new pools intern-state)]
    [handles : (__tl_dyn-array i64) (array.make-array i64 count)]
    [index : i64 0]
    [ok : bool true]
    (begin
      ;; Cross several recipe-buffer growth boundaries while every generated
      ;; handle still has no rendered spelling.
      (while (< index count)
        (let
          [values : SpecValueList
            (spec-value-cons
              (ctfe.CompilerCtfeValue.I64 index)
              (spec-value-list-new))]
          [key : SpecStructuralKey
            (spec-specialization-structural-key-with-owner owner "wide" values)]
          [handle : i64
            (spec-reserve-specialized-symbol-with-owner owner key "wide" values)]
          (begin
            (array-set! handles index handle)
            (if (string.eq
              (spec_ci.intern-compat-state-str intern-state handle)
              "")
              unit
              (set! ok false))
            (set! index (+ index 1)))))
      (spec-materialize-owner-generated-symbols! owner)
      (set! index 0)
      (while (and ok (< index count))
        (let
          [values : SpecValueList
            (spec-value-cons
              (ctfe.CompilerCtfeValue.I64 index)
              (spec-value-list-new))]
          (begin
            (if (string.eq
              (spec_ci.intern-compat-state-str
                intern-state
                (array.ref handles index))
              (spec-specialized-name-with-owner owner "wide" values))
              unit
              (set! ok false))
            (set! index (+ index 1)))))
      (and
        ok
        (=
          (struct-get
            (array-ref (struct-get owner generated-symbol-records) 0)
            len)
          0)))))

(define (compiler-specialize-self-test) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (unless (compiler-specialize-type-param-ok?) (return 0))
    (unless (compiler-specialize-runtime-type-use-rejected?) (return 0))
    (unless (compiler-specialize-template-shadow-ok?) (return 0))
    (unless (compiler-specialize-template-shadow-sibling-ok?) (return 0))
    (unless (compiler-specialize-type-shadow-ok?) (return 0))
    (unless (compiler-specialize-raw-pointer-type-ok?) (return 0))
    (unless (compiler-specialize-owner-slice-type-ok?) (return 0))
    (unless (compiler-specialize-name-key-ok?) (return 0))
    (unless (compiler-specialize-structural-key-ok?) (return 0))
    (unless (compiler-specialize-reuse-ok?) (return 0))
    (unless (compiler-specialize-subst-ok?) (return 0))
    (unless (compiler-specialize-value-subst-ok?) (return 0))
    (unless (compiler-specialize-boxed-tails-ok?) (return 0))
    (unless (compiler-specialize-reflection-string-param-ok?) (return 0))
    (unless (compiler-generated-decl-reuse-ok?) (return 0))
    (unless (compiler-generated-decl-function-reuse-ok?) (return 0))
    (unless (compiler-generated-decl-incompatible-rejected?) (return 0))
    (unless (compiler-generated-decl-incompatible-note-ok?) (return 0))
    (unless (compiler-generated-decl-incompatible-path-ok?) (return 0))
    (unless (compiler-generated-decl-origin-preserved-ok?) (return 0))
    (unless (compiler-generated-registry-map-ok?) (return 0))
    (unless (compiler-generated-decl-spmd-metadata-distinct-ok?) (return 0))
    (unless
      (compiler-specialize-generated-symbol-records-growth-ok?)
      (return 0))
    1))