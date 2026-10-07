;; compiler_specialize_tests.tl - Self-tests for comptime specialization and the
;; generated-declaration registry.
(import stdlib.iterator)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_parse_core as parser)
(import compiler_ast_types as ast)
(import compiler_ctfe as ctfe)
(import compiler_diagnostic as cdiag)
(import compiler_float as cfloat)
(import stdlib.string)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as spec_id_i64_map)
(import compiler_intern as spec_ci)
(import compiler_builtin_ids as cbi)
(import compiler_owned_view as owned_view)
(cfg test (import compiler_profile_state as profile_state))
(cfg test (import stdlib.test))
(import compiler_specialize as spec)

;; Layout queries need the struct names unqualified. Lint does not count a use
;; inside `(type ...)`.
;; lint-allow: unused-import
(import compiler_specialize.SpecTemplateShadowState)

;; lint-allow: unused-import
(import compiler_specialize.SpecTemplateShadowStateData)

(define (spec-template-env-shadow-state
  [templates : (& templates spec.SpecTemplateEnv)]) : spec.SpecTemplateShadowState
  (spec.spec-template-env-data (spec.SpecTemplateEnv templates.address)).shadow-state)

(cfg
  test
  (test
    spec-profile-job-isolation
    (let
      [left : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [right : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [left-metrics : profile_state.CompilerProfileMetrics
        (profile_state.compiler-profile-state-metrics left)]
      [right-metrics : profile_state.CompilerProfileMetrics
        (profile_state.compiler-profile-state-metrics right)]
      (spec.spec-profile-reset! left)
      (spec.spec-profile-reset! right)
      (spec.spec-profile-note-structural-key
        (profile_state.compiler-profile-state-shared-view left-metrics)
        true)
      (spec.spec-profile-note-structural-key
        (profile_state.compiler-profile-state-shared-view right-metrics)
        false)
      (spec.spec-profile-note-name-render
        (profile_state.compiler-profile-state-shared-view left-metrics)
        true)
      (spec.spec-profile-note-name-render right-metrics false)
      (spec.spec-profile-note-generated-text-materialized left-metrics)
      (spec.spec-profile-reset! right)
      (test.assert-i64-eq
        (profile_state.compiler-profile-state-metric-value
          left
          spec.spec-profile-structural-key-created-metric)
        1
        "left job retains structural-key creation")
      (test.assert-i64-eq
        (profile_state.compiler-profile-state-metric-value
          left
          spec.spec-profile-structural-key-reused-metric)
        0
        "left job does not inherit right structural-key reuse")
      (test.assert-i64-eq
        (profile_state.compiler-profile-state-metric-value
          left
          spec.spec-profile-name-render-calls-metric)
        1
        "left job retains render calls")
      (test.assert-i64-eq
        (profile_state.compiler-profile-state-metric-value
          left
          spec.spec-profile-name-render-cache-hits-metric)
        1
        "left job retains render cache hits")
      (test.assert-i64-eq
        (profile_state.compiler-profile-state-metric-value
          left
          spec.spec-profile-name-render-cache-misses-metric)
        0
        "left job does not inherit right render cache misses")
      (test.assert-i64-eq
        (profile_state.compiler-profile-state-metric-value
          left
          spec.spec-profile-generated-text-materialized-metric)
        1
        "left job retains generated text materialization")
      (test.assert-i64-eq
        (profile_state.compiler-profile-state-metric-value
          right
          spec.spec-profile-structural-key-created-metric)
        0
        "right reset is isolated from left")
      (test.assert-i64-eq
        (profile_state.compiler-profile-state-metric-value
          right
          spec.spec-profile-name-render-calls-metric)
        0
        "right render counters reset independently"))))

(define (spec-cache-lookup [cache : spec_id_i64_map.Map] [name-id : i64]) : spec.SpecMaybeId
  (match (spec_id_i64_map.get (& cache) name-id)
    [(LookupFound cached-name-id) (Some cached-name-id)]
    [(LookupMissing) (None)]))

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

(define (spec-lifetime-list-key [lifetimes : (& lifetimes ast.AstLifetimeList)]) : String
  (spec-lifetime-list-key-at (& lifetimes) 0))

(define (spec-type-key [ty : ast.AstType]) : String
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
        (spec-type-list-key (ast.ast-type-list-box-shared-view args))
        "_to_"
        (spec-type-key (ast.ty-node-get ret)))]
    [(CFunc signature mode)
      (str_cat.str-cat
        "cfn_"
        (ast.ast-c-function-mode-name mode)
        "_"
        (spec-type-key (ast.ty-node-get signature)))]
    [(Tuple elems)
      (str_cat.str-cat
        "tuple_"
        (spec-type-list-key (ast.ast-type-list-box-shared-view elems)))]
    [(Array elem count)
      (str_cat.str-cat
        "array_"
        (spec-type-key (ast.ty-node-get elem))
        "_"
        (spec.spec-int-key count))]
    [(DynArray elem)
      (str_cat.str-cat "dynarray_" (spec-type-key (ast.ty-node-get elem)))]
    [(Slice elem)
      (str_cat.str-cat "slice_" (spec-type-key (ast.ty-node-get elem)))]
    [(Box elem) (str_cat.str-cat "box_" (spec-type-key (ast.ty-node-get elem)))]
    [(Ptr elem) (str_cat.str-cat "ptr_" (spec-type-key (ast.ty-node-get elem)))]
    [(MutPtr elem)
      (str_cat.str-cat "mutptr_" (spec-type-key (ast.ty-node-get elem)))]
    [(Ref region inner)
      (str_cat.str-cat
        "ref_"
        (spec_ci.intern-str region)
        "_"
        (spec-type-key (ast.ty-node-get inner)))]
    [(MutRef region inner)
      (str_cat.str-cat
        "mutref_"
        (spec_ci.intern-str region)
        "_"
        (spec-type-key (ast.ty-node-get inner)))]
    [(Region region inner)
      (str_cat.str-cat
        "region_"
        (spec_ci.intern-str region)
        "_"
        (spec-type-key (ast.ty-node-get inner)))]
    [(Invalidate lifetime inner)
      (str_cat.str-cat
        "invalidate_"
        (spec_ci.intern-str lifetime)
        "_"
        (spec-type-key (ast.ty-node-get inner)))]
    [(Enum name)
      (str_cat.str-cat "enum_" (ast.ast-nominal-name-id-display name))]
    [(EnumArgs name lifetimes)
      (str_cat.str-cat
        "enumargs_"
        (ast.ast-nominal-name-id-display name)
        "_"
        (spec-lifetime-list-key (deref lifetimes)))]
    [(Struct name)
      (str_cat.str-cat "struct_" (ast.ast-nominal-name-id-display name))]
    [(StructArgs name lifetimes)
      (str_cat.str-cat
        "structargs_"
        (ast.ast-nominal-name-id-display name)
        "_"
        (spec-lifetime-list-key (deref lifetimes)))]
    [(Var name) (str_cat.str-cat "var_" (spec_ci.intern-str name))]
    [(VarArgs name lifetimes)
      (str_cat.str-cat
        "varargs_"
        (spec_ci.intern-str name)
        "_"
        (spec-lifetime-list-key (deref lifetimes)))]))

(define (spec-value-key [value : ctfe.CompilerCtfeValue]) : String
  (match value
    [(I64 n) (str_cat.str-cat "i64_" (spec.spec-int-key n))]
    [(F64 n)
      (str_cat.str-cat
        "f64_"
        (spec.spec-string-key (cfloat.compiler-float-format-f64 n)))]
    [(F32 n)
      (str_cat.str-cat
        "f32_"
        (spec.spec-string-key
          (cfloat.compiler-float-format-f64
            (cfloat.compiler-float-round-f32-as-f64 n))))]
    [(Bool b)
      (if b
        "bool_1"
        "bool_0")]
    [(Char c) (str_cat.str-cat "char_" (string.int->string (cast c : i64)))]
    [(String text _) (spec.spec-string-key text)]
    [(Name text _) (spec.spec-string-key text)]
    [(Unit) "unit"]
    [(Type ty) (str_cat.str-cat "type_" (spec-type-key ty))]
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
    [(TypeInfo ty) (str_cat.str-cat "typeinfo_" (spec-type-key ty))]
    [(TypeInfoBox ty) (str_cat.str-cat "typeinfo-box_" (spec-type-key ty))]
    [(TypeInfoList _) "typeinfo-list"]
    [(TypeField _ _) "type-field"]
    [(TypeFieldList _) "type-field-list"]
    [(TypeVariantPayload _) "type-variant-payload"]
    [(TypeVariantPayloadList _) "type-variant-payload-list"]
    [(TypeVariant _ _) "type-variant"]
    [(TypeVariantList _) "type-variant-list"]))

(define (spec-values-key [values : (& values spec.SpecValueList)]) : String
  (spec-values-key-at values 0))

(define (spec-values-key-at [values : (& values spec.SpecValueList)] [at : i64]) : String
  (if (>= at values.len)
    "none"
    (str_cat.str-cat
      (spec-value-key (spec.spec-array-shared-view values.slots at))
      "_"
      (spec-values-key-at values (+ at 1)))))

(define (spec-specialization-key
  [name : String]
  [values : (& values spec.SpecValueList)]) : String
  (str_cat.str-cat name ":" (spec-values-key values)))

(define (spec-specialized-name
  [name : String]
  [values : (& values spec.SpecValueList)]) : String
  (str_cat.str-cat "__tl_specialized_" name "_" (spec-values-key values)))

;; Self-test compatibility shim for the removed ambient type worker.  No
;; production entrypoint calls this name; it only lets legacy unit assertions
;; exercise the owner implementation without maintaining a second graph.
(define (spec-substitute-type
  [ty : ast.AstType]
  [subs : (& subs spec.SpecTypeSubst)]) : ast.AstType
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [intern-state : spec_ci.InternCompatState
      (spec_ci.intern-compat-state-capture-active)]
    [owner : spec.SpecOwnerContext
      (spec.spec-owner-context-new pools intern-state)]
    (ast.ast-node-pool-context-install! pools)
    (spec_ci.intern-compat-state-install! intern-state)
    (let
      [result : ast.AstType
        (spec.spec-substitute-type-with-owner owner ty subs)]
      (ast.ast-node-pool-context-install! pools)
      (spec_ci.intern-compat-state-install! intern-state)
      result)))

;; AstDecl names carry generated ids allocated outside the source-name table.
(define (spec-materialize-generated-name-id [name : String]) : i64
  (spec_ci.intern-generated-name name))

;; Self-test shim for the removed ambient value worker: the combined
;; substitution walk with no type bindings.
(define (spec-substitute-values-expr
  [expr : ast.AstExpr]
  [subs : (& subs spec.SpecValueSubst)]) : spec.ResultSpecSubExpr
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [intern-state : spec_ci.InternCompatState
      (spec_ci.intern-compat-state-capture-active)]
    [owner : spec.SpecOwnerContext
      (spec.spec-owner-context-new pools intern-state)]
    [combined : spec.SpecSubst
      (spec.SpecSubst
        (spec.spec-type-subst-new)
        (spec.spec-value-subst-shared-view subs))]
    (ast.ast-node-pool-context-install! pools)
    (spec_ci.intern-compat-state-install! intern-state)
    (let
      [result : spec.ResultSpecSubExpr
        (spec.spec-substitute-expr-with-owner owner expr (& combined))]
      (ast.ast-node-pool-context-install! pools)
      (spec_ci.intern-compat-state-install! intern-state)
      result)))

(define (compiler-specialize-program-with-paths
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [fallback-path : String]) : spec.ResultSpecProgramWithPaths
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : spec.ResultSpecProgramWithPaths
      (spec.compiler-specialize-program-with-paths-and-pools
        program
        paths
        fallback-path
        pools)]
    (ast.ast-node-pool-context-install! pools)
    result))

(define (compiler-specialize-needed? [program : ast.AstProgram]) : bool
  (spec.compiler-specialize-needed-with-pools
    program
    (ast.ast-node-pool-context-capture-active)))

(define (compiler-specialize-type-param-ok?) : bool
  (match (parser.parse-ast-source
    "(define (alloc [comptime T : type] [n : i64]) : (__tl_dyn-array i64)
  (__tl_make-array T n))
(define (main) : (__tl_dyn-array i64)
  (alloc (type i64) 4))")
    [(Ok program)
      (match (spec.compiler-specialize-program program)
        [(Ok specialized)
          (match specialized
            [(Program decls-box)
              (let
                [decls : ast.AstDeclList
                  (ast.ast-decl-list-box-shared-view decls-box)]
                (and
                  (not
                    (spec.compiler-specialize-decl-list-defines? decls "alloc"))
                  (spec.compiler-specialize-decl-list-defines?
                    decls
                    "__tl_specialized_alloc_type_i64_none")))])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-specialize-runtime-type-use-rejected?) : bool
  (match (parser.parse-ast-source
    "(define (bad [comptime T : type] [n : i64]) : i64 T)
(define (main) : i64 (bad (type i64) 4))")
    [(Ok program)
      (match (spec.compiler-specialize-program program)
        [(Ok _) false]
        [(Err _) true])]
    [(Err _) false]))

(define (compiler-specialize-template-shadow-ok?) : bool
  (match (parser.parse-ast-source
    "(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))
(define (use-shadow [scale : (-> i64 i64)]) : i64 (scale 7))")
    [(Ok program)
      (match (spec.compiler-specialize-program program)
        [(Ok _) true]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-specialize-template-shadow-sibling-ok?) : bool
  (match (parser.parse-ast-source
    "(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))
(define (main) : i64
  (+ (let [scale : i64 3] scale) (scale 2 7)))")
    [(Ok program)
      (match (spec.compiler-specialize-program program)
        [(Ok specialized)
          (match specialized
            [(Program decls-box)
              (let
                [decls : ast.AstDeclList
                  (ast.ast-decl-list-box-shared-view decls-box)]
                [original : bool
                  (spec.compiler-specialize-decl-list-defines? decls "scale")]
                [generated : bool
                  (spec.compiler-specialize-decl-list-defines?
                    decls
                    "__tl_specialized_scale_i64_2_none")]
                (and (not original) generated))])]
        [(Err _) false])]
    [(Err _) false]))

(define (spec-template-env-has-template?
  [templates : spec.SpecTemplateEnv]
  [name-id : i64]) : bool
  (match (spec.spec-template-lookup templates name-id)
    [(Some _) true]
    [(None) false]))

(define (compiler-specialize-dense-template-shadow-state-ok?) : bool
  (let
    [items : spec.SpecTemplateList (spec.spec-template-list-new)]
    [_x : unit
      (spec.spec-template-list-push
        (&mut items)
        (Item
          cbi.compiler-builtin-id-fix-x
          (ast.ast-param-list-new)
          (I64)
          (Literal (ast.ast-lit-int 1))))]
    [_second : unit
      (spec.spec-template-list-push
        (&mut items)
        (Item
          cbi.compiler-builtin-id-fix-second
          (ast.ast-param-list-new)
          (I64)
          (Literal (ast.ast-lit-int 2))))]
    [base : spec.SpecTemplateEnv
      (spec.spec-template-env-from-list
        (owned_view.compiler-owned-shared-view items))]
    [shadow-x : spec.SpecTemplateEnv
      (spec.spec-template-env-shadow-name base cbi.compiler-builtin-id-fix-x)]
    [duplicate-x : spec.SpecTemplateEnv
      (spec.spec-template-env-shadow-name
        shadow-x
        cbi.compiler-builtin-id-fix-x)]
    [sibling-second : spec.SpecTemplateEnv
      (spec.spec-template-env-shadow-name
        base
        cbi.compiler-builtin-id-fix-second)]
    [nested-both : spec.SpecTemplateEnv
      (spec.spec-template-env-shadow-name
        shadow-x
        cbi.compiler-builtin-id-fix-second)]
    [patterns : ast.AstPatternList (ast.ast-pattern-list-new)]
    [_pattern-x : unit
      (ast.ast-pattern-list-push
        (&mut patterns)
        (ast.ast-pat-binding-id cbi.compiler-builtin-id-fix-x))]
    [_pattern-second : unit
      (ast.ast-pattern-list-push
        (&mut patterns)
        (ast.ast-pat-binding-id cbi.compiler-builtin-id-fix-second))]
    [pattern-both : spec.SpecTemplateEnv
      (spec.spec-template-env-shadow-pattern base (ast.ast-pat-tuple patterns))]
    [params : ast.AstParamList (ast.ast-param-list-new)]
    [_param-x : unit
      (ast.ast-param-list-push
        (&mut params)
        (ast.ast-param-id cbi.compiler-builtin-id-fix-x (I64) false))]
    [_param-second : unit
      (ast.ast-param-list-push
        (&mut params)
        (ast.ast-param-id cbi.compiler-builtin-id-fix-second (I64) false))]
    [_param-x-again : unit
      (ast.ast-param-list-push
        (&mut params)
        (ast.ast-param-id cbi.compiler-builtin-id-fix-x (I64) false))]
    [param-both : spec.SpecTemplateEnv
      (spec.spec-template-env-shadow-params base params)]
    [bindings : ast.AstLetBindingList (ast.ast-let-binding-list-new)]
    [binding-value : i64 (ast.ast-node-push (Literal (ast.ast-lit-int 0)))]
    [_binding-x : unit
      (ast.ast-let-binding-list-push
        (&mut bindings)
        (ast.ast-let-binding-id
          cbi.compiler-builtin-id-fix-x
          (No)
          binding-value))]
    [_binding-second : unit
      (ast.ast-let-binding-list-push
        (&mut bindings)
        (ast.ast-let-binding-id
          cbi.compiler-builtin-id-fix-second
          (No)
          binding-value))]
    [_binding-x-again : unit
      (ast.ast-let-binding-list-push
        (&mut bindings)
        (ast.ast-let-binding-id
          cbi.compiler-builtin-id-fix-x
          (No)
          binding-value))]
    [binding-both : spec.SpecTemplateEnv
      (spec.spec-template-env-shadow-let-binding-names base bindings)]
    [param-then-binding : spec.SpecTemplateEnv
      (spec.spec-template-env-shadow-let-binding-names param-both bindings)]
    [unrelated : spec.SpecTemplateEnv
      (spec.spec-template-env-shadow-name base cbi.compiler-builtin-id-fix-flag)]
    [wide : spec.SpecTemplateEnv (spec.spec-template-env-from-list items)]
    [ok : bool true]
    ;; Cross multiple dense-record growth boundaries with repeated names.
    (for [index (iterator.range 0 64)]
      (set!
        wide
        (spec.spec-template-env-shadow-name
          wide
          (if (= (bit-and index 1) 0)
            cbi.compiler-builtin-id-fix-x
            cbi.compiler-builtin-id-fix-second))))
    ;; Alternate retained parents, siblings, duplicates, and nested snapshots
    ;; so the activated dense counts must roll backward and forward exactly.
    (set!
      ok
      (and
        ok
        (spec-template-env-has-template? base cbi.compiler-builtin-id-fix-x)
        (spec-template-env-has-template?
          base
          cbi.compiler-builtin-id-fix-second)
        (not
          (spec-template-env-has-template?
            shadow-x
            cbi.compiler-builtin-id-fix-x))
        (spec-template-env-has-template?
          shadow-x
          cbi.compiler-builtin-id-fix-second)
        (not
          (spec-template-env-has-template?
            duplicate-x
            cbi.compiler-builtin-id-fix-x))
        (spec-template-env-has-template?
          duplicate-x
          cbi.compiler-builtin-id-fix-second)
        (spec-template-env-has-template?
          sibling-second
          cbi.compiler-builtin-id-fix-x)
        (not
          (spec-template-env-has-template?
            sibling-second
            cbi.compiler-builtin-id-fix-second))
        (not
          (spec-template-env-has-template?
            nested-both
            cbi.compiler-builtin-id-fix-x))
        (not
          (spec-template-env-has-template?
            nested-both
            cbi.compiler-builtin-id-fix-second))
        (not
          (spec-template-env-has-template?
            pattern-both
            cbi.compiler-builtin-id-fix-x))
        (not
          (spec-template-env-has-template?
            pattern-both
            cbi.compiler-builtin-id-fix-second))
        (not
          (spec-template-env-has-template?
            param-both
            cbi.compiler-builtin-id-fix-x))
        (not
          (spec-template-env-has-template?
            param-both
            cbi.compiler-builtin-id-fix-second))
        (not
          (spec-template-env-has-template?
            binding-both
            cbi.compiler-builtin-id-fix-x))
        (not
          (spec-template-env-has-template?
            binding-both
            cbi.compiler-builtin-id-fix-second))
        (not
          (spec-template-env-has-template?
            param-then-binding
            cbi.compiler-builtin-id-fix-x))
        (not
          (spec-template-env-has-template?
            param-then-binding
            cbi.compiler-builtin-id-fix-second))
        (spec-template-env-has-template?
          unrelated
          cbi.compiler-builtin-id-fix-x)
        (not
          (spec-template-env-has-template? wide cbi.compiler-builtin-id-fix-x))
        (not
          (spec-template-env-has-template?
            wide
            cbi.compiler-builtin-id-fix-second))
        ;; Every shadow of a templated name appends one dense slot, even when
        ;; the name is already shadowed, and a missing-template name appends
        ;; none: x, x again, second, second over x, the pattern's two, and
        ;; three each for the params, the bindings and params-then-bindings
        ;; (15). The wide state grew beyond its initial capacity.
        (=
          (spec.spec-template-shadow-state-data
            (spec-template-env-shadow-state base)).len
          15)
        (=
          (spec.spec-template-shadow-state-data
            (spec-template-env-shadow-state wide)).len
          64)
        (>
          (array-length
            (spec.spec-template-shadow-state-data
              (spec-template-env-shadow-state wide)).slots)
          8)
        (= (comptime (size-of (type SpecTemplateShadowState))) 8)
        (= (comptime (size-of (type SpecTemplateShadowStateData))) 56)))
    ;; Revisit the root after the deepest snapshot to catch leaked counts.
    (and
      ok
      (spec-template-env-has-template? base cbi.compiler-builtin-id-fix-x)
      (spec-template-env-has-template? base cbi.compiler-builtin-id-fix-second))))

(define (compiler-specialize-type-shadow-ok?) : bool
  (match (parser.parse-ast-source
    "(define (pick [comptime T : type] [x : i64]) : i64
  (let [T : i64 x] T))
(define (main) : i64 (pick (type i64) 7))")
    [(Ok program)
      (match (spec.compiler-specialize-program program)
        [(Ok specialized)
          (match specialized
            [(Program decls-box)
              (let
                [decls : ast.AstDeclList
                  (ast.ast-decl-list-box-shared-view decls-box)]
                (spec.compiler-specialize-decl-list-defines?
                  decls
                  "__tl_specialized_pick_type_i64_none"))])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-specialize-raw-pointer-type-ok?) : bool
  (let
    [subs : spec.SpecTypeSubst
      (spec.spec-type-subst-cons
        cbi.compiler-builtin-id-fix-T
        (I64)
        (spec.spec-type-subst-new))]
    (and
      (string.eq (spec-type-key (ast.ast-ty-ptr (I64))) "ptr_i64")
      (string.eq
        (spec-type-key (ast.ast-ty-mut-ptr (ast.ast-ty-ptr (U8))))
        "mutptr_ptr_u8")
      (ctfe.ctfe-type-eq
        (spec-substitute-type
          (ast.ast-ty-mut-ptr (Var cbi.compiler-builtin-id-fix-T))
          subs)
        (ast.ast-ty-mut-ptr (I64))))))

(define (compiler-specialize-owner-slice-type-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [intern-state : spec_ci.InternCompatState (spec_ci.intern-compat-state-new)]
    [owner : spec.SpecOwnerContext
      (spec.spec-owner-context-new pools intern-state)]
    [slice-i64 : ast.AstType (ast.ast-ty-slice-with-pools pools I64)]
    [slice-t : ast.AstType
      (ast.ast-ty-slice-with-pools pools (Var cbi.compiler-builtin-id-fix-T))]
    [subs : spec.SpecTypeSubst
      (spec.spec-type-subst-cons
        cbi.compiler-builtin-id-fix-T
        I64
        (spec.spec-type-subst-new))]
    [substituted : ast.AstType
      (spec.spec-substitute-type-with-owner owner slice-t subs)]
    (and
      (string.eq (spec.spec-type-key-with-owner owner slice-i64) "slice_i64")
      (match substituted
        [(Slice elem)
          (match (spec.spec-owner-type-get owner elem)
            [(I64) true]
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
    [vals-i64 : spec.SpecValueList
      (spec.spec-value-cons (Type (I64)) (spec.spec-value-list-new))]
    [vals-bool : spec.SpecValueList
      (spec.spec-value-cons (Type (Bool)) (spec.spec-value-list-new))]
    [vals-multi : spec.SpecValueList
      (spec.spec-value-cons
        (Type (I64))
        (spec.spec-value-cons (I64 5) (spec.spec-value-list-new)))]
    [vals-string : spec.SpecValueList
      (spec.spec-value-cons
        (ctfe.ctfe-generated-string-value "a b")
        (spec.spec-value-list-new))]
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
      (string.eq (spec-value-key (I64 (- 0 3))) "i64_m3")
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
    [owner-a : spec.SpecOwnerContext
      (spec.spec-owner-context-new pools-a intern-a)]
    [owner-b : spec.SpecOwnerContext
      (spec.spec-owner-context-new pools-b intern-b)]
    [array-a : ast.AstType (ast.ast-ty-array-with-pools pools-a (I64) 7)]
    [array-b : ast.AstType (ast.ast-ty-array-with-pools pools-b (I64) 7)]
    [nested-a : ast.AstType (ast.ast-ty-ptr-with-pools pools-a array-a)]
    [nested-b : ast.AstType (ast.ast-ty-ptr-with-pools pools-b array-b)]
    [values-a : spec.SpecValueList
      (spec.spec-value-cons
        (Type (ast.ast-place-shared-view nested-a))
        (spec.spec-value-cons
          (I64 -3)
          (spec.spec-value-cons (String "a b" 1) (spec.spec-value-list-new))))]
    [values-a-name : spec.SpecValueList
      (spec.spec-value-cons
        (Type (ast.ast-place-shared-view nested-a))
        (spec.spec-value-cons
          (I64 -3)
          (spec.spec-value-cons (Name "a b" 999) (spec.spec-value-list-new))))]
    [values-b : spec.SpecValueList
      (spec.spec-value-cons
        (Type nested-b)
        (spec.spec-value-cons
          (I64 -3)
          (spec.spec-value-cons (Name "a b" 4) (spec.spec-value-list-new))))]
    [key-a : spec.SpecStructuralKey
      (spec.spec-specialization-structural-key-with-owner
        owner-a
        "alloc"
        values-a)]
    [count-after-first : i64
      (spec_ci.intern-compat-state-structural-count intern-a)]
    [key-a-again : spec.SpecStructuralKey
      (spec.spec-specialization-structural-key-with-owner
        owner-a
        "alloc"
        values-a-name)]
    [count-after-repeat : i64
      (spec_ci.intern-compat-state-structural-count intern-a)]
    [different-values : spec.SpecValueList
      (spec.spec-value-cons
        (Type nested-a)
        (spec.spec-value-cons
          (I64 -4)
          (spec.spec-value-cons (String "a b" 1) (spec.spec-value-list-new))))]
    [different : spec.SpecStructuralKey
      (spec.spec-specialization-structural-key-with-owner
        owner-a
        "alloc"
        different-values)]
    [key-b : spec.SpecStructuralKey
      (spec.spec-specialization-structural-key-with-owner
        owner-b
        "alloc"
        values-b)]
    [render-before : String
      (spec_ci.intern-compat-state-composite-rendered-name
        intern-a
        (spec.spec-structural-key-raw key-a))]
    [symbol-handle : i64
      (spec.spec-reserve-specialized-symbol-with-owner
        owner-a
        key-a
        "alloc"
        (spec.spec-place-shared-view values-a))]
    [symbol-before : String
      (spec_ci.intern-compat-state-str intern-a symbol-handle)]
    [_materialized : unit
      (spec.spec-materialize-owner-generated-symbols! owner-a)]
    [rendered : String (spec_ci.intern-compat-state-str intern-a symbol-handle)]
    [rendered-again : String
      (spec.spec-render-specialized-name-with-owner
        owner-a
        key-a
        "alloc"
        values-a)]
    [old-raw : i64 (spec.spec-structural-key-raw key-a)]
    [post-reset-values : spec.SpecValueList
      (spec.spec-value-cons (I64 -3) (spec.spec-value-list-new))]
    (and
      (> count-after-first 0)
      (= count-after-first count-after-repeat)
      (=
        (spec.spec-structural-key-raw key-a)
        (spec.spec-structural-key-raw key-a-again))
      (not
        (=
          (spec.spec-structural-key-raw key-a)
          (spec.spec-structural-key-raw different)))
      (not
        (=
          (spec.spec-structural-key-raw key-a)
          (spec.spec-structural-key-raw key-b)))
      (string.eq render-before "")
      (string.eq symbol-before "")
      (spec_ci.intern-compat-state-generated-id-active? intern-a symbol-handle)
      (not (= symbol-handle (spec.spec-structural-key-raw key-a)))
      (string.eq
        rendered
        "__tl_specialized_alloc_type_ptr_array_i64_7_i64_m3_string_3_97_32_98_none")
      (string.eq rendered rendered-again)
      (begin
        (spec_ci.intern-compat-state-reset-to! (&mut intern-a) 0)
        (and
          (not
            (spec_ci.intern-compat-state-generated-id-active?
              intern-a
              symbol-handle))
          (not
            (=
              old-raw
              (spec.spec-structural-key-raw
                (spec.spec-specialization-structural-key-with-owner
                  owner-a
                  "alloc"
                  post-reset-values)))))))))

;: Count function declarations named `name` in `decls` (specialized decls are
;: emitted as ordinary `AstDecl.DefFn`s, so reuse means a count of exactly 1).
(define (compiler-specialize-decl-list-count-defs
  [decls : ast.AstDeclList]
  [name : String]) : i64
  (match (ast.ast-decl-list-step decls)
    [(Nil) 0]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match (ast.ast-decl-unwrapped decl)
          [(DefFn decl-meta fn-name _ _ _ _)
            (if (string.eq (spec_ci.intern-str fn-name) name)
              (+ 1 (compiler-specialize-decl-list-count-defs rest name))
              (compiler-specialize-decl-list-count-defs rest name))]
          [_ (compiler-specialize-decl-list-count-defs rest name)]))]))

(define (compiler-specialize-decl-list-count-visible
  [decls : ast.AstDeclList]
  [name : String]) : i64
  (match (ast.ast-decl-list-step decls)
    [(Nil) 0]
    [(Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        [tail-count : i64
          (compiler-specialize-decl-list-count-visible
            rest
            (spec.spec-place-shared-view name))]
        (match (spec.gen-decl-visible-name decl)
          [(Some found)
            (if (string.eq found name)
              (+ 1 tail-count)
              tail-count)]
          [(None) tail-count]))]))

;: Two call sites that request the SAME specialization (`alloc` at `type i64`)
;: must share one generated decl via the specialization cache, not emit two.
(define (compiler-specialize-reuse-source) : String
  "(define (alloc [comptime T : type] [n : i64]) : (__tl_dyn-array i64)
  (__tl_make-array T n))
(define (main) : (__tl_dyn-array i64)
  (begin (alloc (type i64) 4) (alloc (type i64) 8)))")

;: Specialization reuse (mirrors src/specialize.rs reuse coverage): two
;: identical `alloc (type i64)` requests collapse to a single shared
;: `__tl_specialized_alloc_type_i64_none` decl (the cache dedups by key) and the
;: `alloc` template is removed.
(define (compiler-specialize-reuse-ok?) : bool
  (match (parser.parse-ast-source (compiler-specialize-reuse-source))
    [(Ok program)
      (match (spec.compiler-specialize-program program)
        [(Ok specialized)
          (match specialized
            [(Program decls-box)
              (let
                [decls : ast.AstDeclList
                  (ast.ast-decl-list-box-shared-view decls-box)]
                (and
                  (not
                    (spec.compiler-specialize-decl-list-defines? decls "alloc"))
                  (=
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "__tl_specialized_alloc_type_i64_none")
                    1)))])]
        [(Err _) false])]
    [(Err _) false]))

;: Type substitution (mirrors src/specialize.rs substitution coverage):
;: `spec-substitute-type` replaces a mapped type variable with its bound type,
;: recurses through compound types (Ptr/DynArray/function), and leaves an
;: unmapped variable unchanged (the SpecMaybeId.None lookup branch). Complements
;: the single MutPtr case embedded in `compiler-specialize-raw-pointer-type-ok?`.
(define (compiler-specialize-subst-ok?) : bool
  (let
    [subs : spec.SpecTypeSubst
      (spec.spec-type-subst-cons
        cbi.compiler-builtin-id-fix-T
        (I64)
        (spec.spec-type-subst-new))]
    (and
      (string.eq
        (spec-type-key
          (spec-substitute-type (Var cbi.compiler-builtin-id-fix-T) subs))
        "i64")
      (string.eq
        (spec-type-key
          (spec-substitute-type
            (ast.ast-ty-ptr (Var cbi.compiler-builtin-id-fix-T))
            subs))
        "ptr_i64")
      (string.eq
        (spec-type-key
          (spec-substitute-type
            (ast.ast-ty-dyn-array (Var cbi.compiler-builtin-id-fix-T))
            subs))
        "dynarray_i64")
      (string.eq
        (spec-type-key
          (spec-substitute-type
            (ast.ast-ty-func
              (ast.ast-type-cons
                (Var cbi.compiler-builtin-id-fix-T)
                (ast.ast-type-list-new))
              (Var cbi.compiler-builtin-id-fix-T))
            subs))
        "fn_i64_nil_to_i64")
      (string.eq
        (spec-type-key
          (spec-substitute-type (Var cbi.compiler-builtin-id-fix-U) subs))
        "var_U"))))

;: Value (comptime-argument) substitution (mirrors src/specialize.rs
;: substitution coverage): `spec-substitute-values-expr` replaces a variable
;: bound to a comptime value with that value's literal, leaves unmapped
;: variables and literals unchanged, and recurses through compound expressions.
(define (compiler-specialize-value-subst-ok?) : bool
  (let
    [subs : spec.SpecValueSubst
      (spec.spec-value-subst-cons
        cbi.compiler-builtin-id-fix-x
        (I64 5)
        (spec.spec-value-subst-new))]
    (and
      ;; mapped variable x -> integer literal 5
      (match (spec-substitute-values-expr
        (Var cbi.compiler-builtin-id-fix-x)
        subs)
        [(Ok e)
          (match (ast.ast-node-get e)
            [(Literal lit)
              (match lit
                [(Int n _) (= n 5)]
                [_ false])]
            [_ false])]
        [(Err _) false])
      ;; unmapped variable y -> unchanged
      (match (spec-substitute-values-expr
        (Var cbi.compiler-builtin-id-fix-y)
        subs)
        [(Ok e)
          (match (ast.ast-node-get e)
            [(Var name) (string.eq (spec_ci.intern-str name) "y")]
            [_ false])]
        [(Err _) false])
      ;; recursion through `if`: x in the condition becomes 5, unmapped y stays
      (match (spec-substitute-values-expr
        (If
          (ast.ast-node-push (Var cbi.compiler-builtin-id-fix-x))
          (ast.ast-node-push (Literal (ast.ast-lit-int 1)))
          (ast.ast-node-push (Var cbi.compiler-builtin-id-fix-y)))
        subs)
        [(Ok e)
          (match (ast.ast-node-get e)
            [(If cond-box _ else-branch-box)
              (let
                [cond : ast.AstExpr (ast.ast-node-get cond-box)]
                [else-branch : ast.AstExpr (ast.ast-node-get else-branch-box)]
                (and
                  (match cond
                    [(Literal lit)
                      (match lit
                        [(Int n _) (= n 5)]
                        [_ false])]
                    [_ false])
                  (match else-branch
                    [(Var name) (string.eq (spec_ci.intern-str name) "y")]
                    [_ false])))]
            [_ false])]
        [(Err _) false]))))

(define (compiler-specialize-boxed-tails-ok?) : bool
  (let
    [templates : spec.SpecTemplateList
      (let
        [out : spec.SpecTemplateList (spec.spec-template-list-new)]
        (spec.spec-template-list-push
          (&mut out)
          (Item
            cbi.compiler-builtin-id-fix-x
            (ast.ast-param-list-new)
            (I64)
            (Literal (ast.ast-lit-int 1))))
        (spec.spec-template-list-push
          (&mut out)
          (Item
            cbi.compiler-builtin-id-fix-second
            (ast.ast-param-list-new)
            (Bool)
            (Literal (Bool true))))
        out)]
    [template-env : spec.SpecTemplateEnv
      (spec.spec-template-env-from-list templates)]
    [cache : spec_id_i64_map.Map
      (let
        [seed-cache : spec_id_i64_map.Map (spec_id_i64_map.with-capacity 8)]
        (spec_id_i64_map.insert-ref!
          (&mut seed-cache)
          cbi.compiler-builtin-id-fix-second
          cbi.compiler-builtin-id-fix-second)
        (spec_id_i64_map.insert-ref!
          (&mut seed-cache)
          cbi.compiler-builtin-id-fix-x
          cbi.compiler-builtin-id-fix-x)
        seed-cache)]
    [values : spec.SpecValueList
      (spec.spec-value-cons
        (I64 1)
        (spec.spec-value-cons (Bool true) (spec.spec-value-list-new)))]
    [value-subs : spec.SpecValueSubst
      (spec.spec-value-subst-cons
        cbi.compiler-builtin-id-fix-x
        (I64 1)
        (spec.spec-value-subst-cons
          cbi.compiler-builtin-id-fix-flag
          (Bool true)
          (spec.spec-value-subst-new)))]
    [type-subs : spec.SpecTypeSubst
      (spec.spec-type-subst-cons
        cbi.compiler-builtin-id-fix-T
        (I64)
        (spec.spec-type-subst-cons
          cbi.compiler-builtin-id-fix-U
          (Bool)
          (spec.spec-type-subst-new)))]
    (and
      (match (spec.spec-template-lookup
        template-env
        cbi.compiler-builtin-id-fix-second)
        [(Some template)
          (match template
            [(Item name _ _ _) (= name cbi.compiler-builtin-id-fix-second)])]
        [(None) false])
      (match (spec-cache-lookup cache cbi.compiler-builtin-id-fix-second)
        [(Some name-id) (= name-id cbi.compiler-builtin-id-fix-second)]
        [(None) false])
      (string.eq (spec-values-key values) "i64_1_bool_1_none")
      (match (spec.spec-value-subst-value
        value-subs
        cbi.compiler-builtin-id-fix-flag)
        [(Bool flag) flag]
        [_ false])
      (ctfe.ctfe-type-eq
        (spec.spec-type-subst-type type-subs cbi.compiler-builtin-id-fix-U)
        (Bool)))))

(define (compiler-specialize-reflection-string-param-ok?) : bool
  (match (parser.parse-ast-source
    "(defstruct Point (x i64))
(define (tag-helper [comptime key : String] [x : i64]) : i64 x)
(define (main) : i64 (tag-helper (type-key (type Point)) 7))")
    [(Ok program)
      (let
        [pools-before : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        [expr-len-before : i64
          (ast.ast-node-pool-context-expr-len pools-before)]
        [specialized-result : spec.ResultSpecProgram
          (spec.compiler-specialize-program program)]
        (match specialized-result
          [(Ok specialized)
            (let
              [pools-after : ast.AstNodePoolContext
                (ast.ast-node-pool-context-capture-active)]
              (and
                (>
                  (ast.ast-node-pool-context-expr-len pools-after)
                  expr-len-before)
                (match specialized
                  [(Program decls-box)
                    (let
                      [decls : ast.AstDeclList
                        (ast.ast-decl-list-box-shared-view decls-box)]
                      (spec.compiler-specialize-decl-list-defines?
                        decls
                        "__tl_specialized_tag-helper_string_12_115_116_114_117_99_116_95_80_111_105_110_116_none"))])))]
          [(Err _) false]))]
    [(Err _) false]))

(define (compiler-generated-decl-expected-string-key) : String
  (spec.gen-full-key
    ""
    "sample-family"
    "Box_String"
    (str_cat.str-cat (spec.spec-string-key "String") "_none")))

(define (compiler-generated-decl-mark!
  [program : ast.AstProgram]
  [index : i64]
  [generator : String]
  [item : String]
  [arg : String]) : unit
  (if (< index 0)
    unit
    (match program
      [(Program decls-box)
        (let
          [decls : ast.AstDeclList
            (ast.ast-decl-list-box-shared-view decls-box)]
          [args : ast.AstExprList (ast.ast-expr-list-new)]
          (ast.ast-expr-list-push
            (&mut args)
            (ast.ast-node-push (Literal (ast.ast-lit-generated-string arg))))
          (set!
            (array-ref decls.slots (+ decls.offset index))
            (ast.ast-decl-comptime-decl-with-meta
              (Some generator item args "")
              (spec.spec-array-shared-view decls.slots (+ decls.offset index)))))])))

(define (compiler-generated-decl-pair
  [source : String]
  [first-index : i64]
  [generator : String]
  [item : String]
  [first-arg : String]
  [second-index : i64]
  [second-arg : String]) : parser.ResultAstProgram
  (let
    [program (try (parser.parse-ast-source source))]
    (compiler-generated-decl-mark!
      (ast.ast-place-shared-view program)
      first-index
      (spec.spec-place-shared-view generator)
      (spec.spec-place-shared-view item)
      first-arg)
    (compiler-generated-decl-mark!
      (ast.ast-place-shared-view program)
      second-index
      generator
      item
      second-arg)
    (Ok program)))

(define (compiler-generated-decl-reuse-program) : parser.ResultAstProgram
  (compiler-generated-decl-pair
    "(defstruct Box_String (value String))
(defstruct Box_String (value String))"
    0
    "sample-family"
    "Box_String"
    "String"
    1
    "String"))

(define (compiler-generated-decl-function-reuse-program) : parser.ResultAstProgram
  (compiler-generated-decl-pair
    "(define (make-box-string [value : String]) : String value)
(define (make-box-string [value : String]) : String value)"
    0
    "function-family"
    "make-box-string"
    "String"
    1
    "String"))

(define (compiler-generated-decl-incompatible-program) : parser.ResultAstProgram
  (compiler-generated-decl-pair
    "(defstruct Box_String (value String))
(defstruct Box_String (value i64))"
    0
    "sample-family"
    "Box_String"
    "String"
    1
    "String"))

(define (compiler-generated-decl-marker-pair-ok?
  [first : String]
  [second : String]
  [reuse? : bool]
  [marked? : bool]) : bool
  (match (compiler-generated-decl-pair
    (str_cat.str-cat first "\n" second)
    0
    "marker-family"
    "Marked"
    "same-key"
    1
    "same-key")
    [(Err _) false]
    [(Ok program)
      (match (ast.ast-place-shared-view program)
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            [equal? : bool
              (spec.gen-decl-eq?
                (ast.ast-decl-list-ref decls 0)
                (ast.ast-decl-list-ref decls 1))]
            (and
              (= equal? reuse?)
              (match (spec.compiler-specialize-program program)
                [(Ok normalized)
                  (and
                    reuse?
                    (match normalized
                      [(Program normalized-box)
                        (let
                          [normalized-decls : ast.AstDeclList
                            (ast.ast-decl-list-box-shared-view normalized-box)]
                          (and
                            (= (ast.ast-decl-list-len (& normalized-decls)) 1)
                            (=
                              (let
                                [decl
                                  (ast.ast-decl-list-ref normalized-decls 0)]
                                (ast.ast-decl-must-use? decl))
                              marked?)))]))]
                [(Err diag)
                  (let
                    [value : cdiag.CompilerDiagnostic
                      (cdiag.compiler-diagnostic-box-shared-view diag)]
                    (and
                      (not reuse?)
                      (string.eq
                        (cdiag.compiler-diagnostic-message value)
                        "generated-decl: duplicate generated key for Marked has incompatible payload")))])))])]))

(define (compiler-generated-decl-marker-forms-ok?
  [unmarked : String]
  [marked : String]) : bool
  (and
    (compiler-generated-decl-marker-pair-ok?
      (string.copy unmarked)
      (string.copy unmarked)
      true
      false)
    (compiler-generated-decl-marker-pair-ok?
      (string.copy marked)
      (string.copy marked)
      true
      true)
    (compiler-generated-decl-marker-pair-ok?
      (string.copy unmarked)
      (string.copy marked)
      false
      false)
    (compiler-generated-decl-marker-pair-ok? marked unmarked false false)))

(define (compiler-generated-decl-markers-distinct-ok?) : bool
  (and
    (compiler-generated-decl-marker-forms-ok?
      "(defstruct Marked (value i64))"
      "(defstruct Marked (:must-use) (value i64))")
    (compiler-generated-decl-marker-forms-ok?
      "(defenum Marked (None) (Some i64))"
      "(defenum Marked (:must-use) (None) (Some i64))")
    (compiler-generated-decl-marker-forms-ok?
      "(defstruct Marked (:lifetimes a) (value (& a i64)))"
      "(defstruct Marked (:lifetimes a) (:must-use) (value (& a i64)))")
    (compiler-generated-decl-marker-forms-ok?
      "(defenum Marked (:lifetimes a) (None) (Some (& a i64)))"
      "(defenum Marked (:lifetimes a) (:must-use) (None) (Some (& a i64)))")))

(define (compiler-generated-decl-reuse-ok?) : bool
  (match (compiler-generated-decl-reuse-program)
    [(Ok program)
      (and
        (compiler-specialize-needed? (ast.ast-place-shared-view program))
        (match (spec.compiler-specialize-program program)
          [(Ok normalized)
            (match normalized
              [(Program decls-box)
                (let
                  [decls : ast.AstDeclList
                    (ast.ast-decl-list-box-shared-view decls-box)]
                  (=
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "Box_String")
                    1))])]
          [(Err _) false]))]
    [(Err _) false]))

(define (compiler-generated-decl-function-reuse-ok?) : bool
  (match (compiler-generated-decl-function-reuse-program)
    [(Ok program)
      (match (spec.compiler-specialize-program program)
        [(Ok normalized)
          (match normalized
            [(Program decls-box)
              (let
                [decls : ast.AstDeclList
                  (ast.ast-decl-list-box-shared-view decls-box)]
                (=
                  (compiler-specialize-decl-list-count-defs
                    decls
                    "make-box-string")
                  1))])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-generated-decl-incompatible-rejected?) : bool
  (match (compiler-generated-decl-incompatible-program)
    [(Ok program)
      (match (spec.compiler-specialize-program program)
        [(Ok _) false]
        [(Err _) true])]
    [(Err _) false]))

(define (compiler-generated-decl-incompatible-note-ok?) : bool
  (match (compiler-generated-decl-incompatible-program)
    [(Ok program)
      (match (spec.compiler-specialize-program program)
        [(Ok _) false]
        [(Err diag)
          (let
            [value : cdiag.CompilerDiagnostic
              (cdiag.compiler-diagnostic-box-shared-view diag)]
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
    [(Err _) false]))

(define (compiler-generated-decl-incompatible-path-ok?) : bool
  (match (compiler-generated-decl-incompatible-program)
    [(Ok program)
      (match (compiler-specialize-program-with-paths
        program
        (ast.ast-decl-root-path-cons
          "generated/first.tl"
          (ast.ast-decl-root-path-cons
            "generated/second.tl"
            (ast.ast-decl-path-list-new)))
        "generated/fallback.tl")
        [(Ok _ _) false]
        [(Err diag)
          (let
            [value : cdiag.CompilerDiagnostic
              (cdiag.compiler-diagnostic-box-shared-view diag)]
            (string.eq
              (cdiag.compiler-diagnostic-path value)
              "generated/second.tl"))])]
    [(Err _) false]))

(define (compiler-generated-decl-origin-preserved-ok?) : bool
  (match (compiler-generated-decl-reuse-program)
    [(Ok program)
      (match (spec.compiler-specialize-program program)
        [(Ok normalized)
          (match normalized
            [(Program decls-box)
              (match (ast.ast-decl-list-step (deref decls-box))
                [(Cons decl _)
                  (and
                    (match (ast.ast-decl-generated-meta decl)
                      [(Some generator item _ key)
                        (and
                          (string.eq generator "sample-family")
                          (string.eq item "Box_String")
                          (string.eq
                            key
                            (compiler-generated-decl-expected-string-key)))]
                      [(No) false])
                    (match decl
                      [(DefStruct decl-meta name _ _ _)
                        (string.eq (spec_ci.intern-str name) "Box_String")]
                      [_ false]))]
                [(Nil) false])])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-generated-registry-map-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 8 8)]
    [intern-state : spec_ci.InternCompatState (spec_ci.intern-compat-state-new)]
    [owner : spec.SpecOwnerContext
      (spec.spec-owner-context-new pools intern-state)]
    [name-id : i64 (spec-materialize-generated-name-id "RegistryBox")]
    [decl : ast.AstDecl
      (ast.ast-decl-def-struct-id
        name-id
        Default
        No
        (ast.ast-field-def-list-new))]
    [key : spec.SpecStructuralKey
      (spec.gen-registry-structural-key-with-owner
        owner
        -1
        cbi.compiler-builtin-id-fix-x
        "registry-test"
        "RegistryBox"
        "generated-key")]
    [registry : spec.GenRegistry
      (spec.gen-registry-insert-with-owner
        (spec.gen-registry-empty)
        key
        (ast.ast-place-shared-view decl))]
    (match (spec.gen-registry-lookup-with-owner registry key)
      [(Some found) (spec.gen-decl-eq? found decl)]
      [(None) false])))

(define (compiler-generated-decl-spmd-metadata-distinct-ok?) : bool
  (let
    [a-classes : ast.AstSpmdParamClassList (ast.ast-spmd-param-class-list-new)]
    [b-classes : ast.AstSpmdParamClassList (ast.ast-spmd-param-class-list-new)]
    [a-items : ast.AstSpmdSpecializationList
      (ast.ast-spmd-specialization-list-new)]
    [b-items : ast.AstSpmdSpecializationList
      (ast.ast-spmd-specialization-list-new)]
    [generated-id : i64 (spec_ci.intern-generated-canonical-name "generated")]
    [body : i64 (ast.ast-node-push (Literal (ast.ast-lit-int 0)))]
    (ast.ast-spmd-param-class-list-push (&mut a-classes) Varying)
    (ast.ast-spmd-param-class-list-push (&mut b-classes) Varying)
    (ast.ast-spmd-specialization-list-push
      (&mut a-items)
      (ast.AstSpmdSpecialization 8 (box a-classes) Varying 0))
    (ast.ast-spmd-specialization-list-push
      (&mut b-items)
      (ast.AstSpmdSpecialization 16 (box b-classes) Varying 0))
    (not
      (spec.gen-decl-eq?
        (ast.ast-decl-def-fn-metadata-id
          generated-id
          (ast.ast-param-list-new)
          (I64)
          body
          (ast.ast-fn-metadata-full No (Callable a-items)))
        (ast.ast-decl-def-fn-metadata-id
          generated-id
          (ast.ast-param-list-new)
          (I64)
          body
          (ast.ast-fn-metadata-full No (Callable b-items)))))))

(define (compiler-generated-test-metadata-distinct-ok?) : bool
  (let
    [name : i64 (spec_ci.intern-generated-canonical-name "generated-test")]
    [body : i64 (ast.ast-node-push (Literal Unit))]
    [span : ast.AstSourceSpan (ast.ast-source-span 1 1 1 2)]
    (and
      (not
        (spec.gen-decl-eq?
          (ast.ast-decl-test-id name body span)
          (ast.ast-decl-test-metadata-id
            name
            body
            (ast.ast-test-metadata-new No true)
            span)))
      (spec.gen-decl-eq?
        (ast.ast-decl-test-metadata-id
          name
          body
          (ast.ast-test-metadata-new (Some "same reason") false)
          span)
        (ast.ast-decl-test-metadata-id
          name
          body
          (ast.ast-test-metadata-new (Some "same reason") false)
          span)))))

(define (compiler-specialize-generated-symbol-records-growth-ok?) : bool
  (let
    [count : i64 32]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 32 32)]
    [intern-state : spec_ci.InternCompatState (spec_ci.intern-compat-state-new)]
    [owner : spec.SpecOwnerContext
      (spec.spec-owner-context-new pools intern-state)]
    [handles : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    [ok : bool true]
    ;; Cross several recipe-buffer growth boundaries while every generated
    ;; handle still has no rendered spelling.
    (while (< index count)
      (let
        [values : spec.SpecValueList
          (spec.spec-value-cons (I64 index) (spec.spec-value-list-new))]
        [key : spec.SpecStructuralKey
          (spec.spec-specialization-structural-key-with-owner
            owner
            "wide"
            values)]
        [handle : i64
          (spec.spec-reserve-specialized-symbol-with-owner
            owner
            key
            "wide"
            values)]
        (set! (array-ref handles index) handle)
        (if (string.eq (spec_ci.intern-compat-state-str intern-state handle) "")
          unit
          (set! ok false))
        (+= index 1)))
    (spec.spec-materialize-owner-generated-symbols! owner)
    (set! index 0)
    (while (and ok (< index count))
      (let
        [values : spec.SpecValueList
          (spec.spec-value-cons (I64 index) (spec.spec-value-list-new))]
        (if (string.eq
          (spec_ci.intern-compat-state-str
            intern-state
            (array-ref handles index))
          (spec.spec-specialized-name-with-owner owner "wide" values))
          unit
          (set! ok false))
        (+= index 1)))
    (and
      ok
      (=
        (__tl-project-field (array-ref owner.generated-symbol-records 0) len)
        0))))

;; Resource cleanup expressions are constrained further by the typechecker;
;; these source-local tests isolate the specialization traversal itself.
(define (compiler-specialize-resource-error? [body : String]) : bool
  (match (parser.parse-ast-source
    (str_cat.str-cat
      "(define (bad [comptime T : type]) : i64 "
      body
      ") (define (main) : i64 (bad (type i64)))"))
    [(Ok program)
      (match (spec.compiler-specialize-program program)
        [(Err _) true]
        [_ false])]
    [_ false]))

(define (compiler-specialize-resource-literal? [id : i64]) : bool
  (match (ast.ast-node-get id)
    [(Literal literal)
      (match literal
        [(Int value _) (= value 5)]
        [_ false])]
    [_ false]))

(define (compiler-specialize-resource-var? [id : i64]) : bool
  (match (ast.ast-node-get id)
    [(Var name) (= name cbi.compiler-builtin-id-fix-x)]
    [_ false]))

(define (compiler-specialize-resource-subst-ok?) : bool
  (let
    [name : i64 cbi.compiler-builtin-id-fix-x]
    [var : i64 (ast.ast-node-push (Var name))]
    [bindings : ast.AstResourceBindingList (ast.ast-resource-binding-list-new)]
    [body : ast.AstExprList (ast.ast-expr-list-new)]
    [subs : spec.SpecValueSubst
      (spec.spec-value-subst-cons name (I64 5) (spec.spec-value-subst-new))]
    (ast.ast-resource-binding-list-push
      (&mut bindings)
      (ast.AstResourceBinding.Binding name var var true))
    (ast.ast-resource-binding-list-push
      (&mut bindings)
      (ast.AstResourceBinding.Binding
        cbi.compiler-builtin-id-fix-y
        var
        var
        false))
    (ast.ast-expr-list-push (&mut body) var)
    (match (spec-substitute-values-expr
      (WithResource (box (ast.AstWithResource.WithResource bindings body)))
      subs)
      [(Ok rewritten)
        (match (ast.ast-node-get rewritten)
          [(WithResource resource)
            (match (ast.ast-with-resource-box-shared-view resource)
              [(WithResource bindings body)
                (and
                  (= bindings.len 2)
                  (= body.len 1)
                  (match (ast.ast-resource-binding-list-get
                    (& bindings)
                    0
                    (ast.ast-resource-binding-fallback))
                    [(Binding actual init cleanup move-aware?)
                      (and
                        (= actual name)
                        move-aware?
                        (compiler-specialize-resource-literal? init)
                        (compiler-specialize-resource-literal? cleanup))])
                  (match (ast.ast-resource-binding-list-get
                    (& bindings)
                    1
                    (ast.ast-resource-binding-fallback))
                    [(Binding actual init cleanup move-aware?)
                      (and
                        (= actual cbi.compiler-builtin-id-fix-y)
                        (not move-aware?)
                        (compiler-specialize-resource-var? init)
                        (compiler-specialize-resource-var? cleanup))])
                  (compiler-specialize-resource-var?
                    (ast.ast-expr-list-get (& body) 0 0)))])]
          [_ false])]
      [_ false])))

(define (compiler-specialize-resource-ok?) : bool
  (and
    (compiler-specialize-resource-subst-ok?)
    (compiler-specialize-resource-error? "(with ([r T drop]) 0)")
    (compiler-specialize-resource-error? "(with ([r 0 T]) 0)")
    (compiler-specialize-resource-error? "(with ([r 0 drop]) T)")
    (match (parser.parse-ast-source
      "(define (pick [comptime n : i64]) : i64 n)
       (define (main) : i64 (with ([r 0 (pick 7)]) 0))")
      [(Ok program)
        (match (spec.compiler-specialize-program program)
          [(Ok specialized)
            (match specialized
              [(Program decls)
                (spec.compiler-specialize-decl-list-defines?
                  (deref decls)
                  "__tl_specialized_pick_i64_7_none")])]
          [_ false])]
      [_ false])))

(define (compiler-specialize-self-test) : i64
  (cbi.compiler-builtin-initialize-for-parse!)
  (unless (compiler-specialize-type-param-ok?) (return 0))
  (unless (compiler-specialize-runtime-type-use-rejected?) (return 0))
  (unless (compiler-specialize-template-shadow-ok?) (return 0))
  (unless (compiler-specialize-template-shadow-sibling-ok?) (return 0))
  (unless (compiler-specialize-dense-template-shadow-state-ok?) (return 0))
  (unless (compiler-specialize-type-shadow-ok?) (return 0))
  (unless (compiler-specialize-raw-pointer-type-ok?) (return 0))
  (unless (compiler-specialize-owner-slice-type-ok?) (return 0))
  (unless (compiler-specialize-name-key-ok?) (return 0))
  (unless (compiler-specialize-structural-key-ok?) (return 0))
  (unless (compiler-specialize-reuse-ok?) (return 0))
  (unless (compiler-specialize-subst-ok?) (return 0))
  (unless (compiler-specialize-value-subst-ok?) (return 0))
  (unless (compiler-specialize-resource-ok?) (return 0))
  (unless (compiler-specialize-boxed-tails-ok?) (return 0))
  (unless (compiler-specialize-reflection-string-param-ok?) (return 0))
  (unless (compiler-generated-decl-reuse-ok?) (return 0))
  (unless (compiler-generated-decl-markers-distinct-ok?) (return 0))
  (unless (compiler-generated-decl-function-reuse-ok?) (return 0))
  (unless (compiler-generated-decl-incompatible-rejected?) (return 0))
  (unless (compiler-generated-decl-incompatible-note-ok?) (return 0))
  (unless (compiler-generated-decl-incompatible-path-ok?) (return 0))
  (unless (compiler-generated-decl-origin-preserved-ok?) (return 0))
  (unless (compiler-generated-registry-map-ok?) (return 0))
  (unless (compiler-generated-decl-spmd-metadata-distinct-ok?) (return 0))
  (unless (compiler-generated-test-metadata-distinct-ok?) (return 0))
  (unless (compiler-specialize-generated-symbol-records-growth-ok?) (return 0))
  1)

(cfg
  test
  (test
    specialize-self-test
    (test.assert-i64-eq
      (compiler-specialize-self-test)
      1
      "every specialization self-test check passes")))

(cfg
  test
  (test
    specialize-generated-aggregate-markers
    (begin
      (cbi.compiler-builtin-initialize-for-parse!)
      (test.assert-true
        (compiler-generated-decl-markers-distinct-ok?)
        "generated aggregate marker preservation, reuse, and conflicts"))))

(cfg
  test
  (test
    specialize-resource-scopes
    (begin
      (cbi.compiler-builtin-initialize-for-parse!)
      (test.assert-true
        (compiler-specialize-resource-ok?)
        "resource traversal, sequential substitution, and metadata"))))