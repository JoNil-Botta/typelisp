;; compiler_specialize.tl - Selfhost comptime function specialization.
(import stdlib.array)
(import "compiler_parse_core.tl")
(import "compiler_ctfe.tl")
(import "compiler_diagnostic.tl")
(import "compiler_float.tl")
(import stdlib.string)
(import stdlib.hashmap)
(import (hashmap String i64) as spec_string_i64_map)
(import (hashmap String String) as spec_string_string_map)
(import compiler_builtin_ids as cbi)

(defstruct GenRegistry
  (index spec_string_i64_map.Map)
  (decls (Array AstDecl))
  (len i64))

(defenum SpecTemplate
  (Item String AstParamList AstType AstExpr))

(defenum SpecTemplateList
  (Nil)
  (Cons SpecTemplate (Box SpecTemplateList)))

(defenum SpecTemplateShadowList
  (Nil)
  (Cons String (Box SpecTemplateShadowList)))

(defenum SpecMaybeTemplate
  (None)
  (Some SpecTemplate))

(defstruct SpecTemplateEnv
  (index spec_string_i64_map.Map)
  (values (Array SpecMaybeTemplate))
  (shadowed SpecTemplateShadowList))

;; The specialization cache (key -> generated function name) is a
;; generated String -> String hashmap so lookups avoid a linear scan.
(defenum SpecState
  (State AstDeclList spec_string_string_map.Map CtfeEnv AstNodePoolContext))

(defenum SpecValueList
  (Nil)
  (Cons CompilerCtfeValue (Box SpecValueList)))

(defenum SpecValueSubst
  (Nil)
  (Cons String CompilerCtfeValue (Box SpecValueSubst)))

(defenum SpecTypeSubst
  (Nil)
  (Cons String AstType (Box SpecTypeSubst)))

(define (spec-template-cons [head : SpecTemplate] [rest : SpecTemplateList]) : SpecTemplateList
  (SpecTemplateList.Cons head (box rest)))

(define (spec-value-cons [head : CompilerCtfeValue] [rest : SpecValueList]) : SpecValueList
  (SpecValueList.Cons head (box rest)))

(define (spec-value-subst-cons
  [key : String]
  [value : CompilerCtfeValue]
  [rest : SpecValueSubst]) : SpecValueSubst
  (SpecValueSubst.Cons key value (box rest)))

(define (spec-type-subst-cons
  [key : String]
  [ty : AstType]
  [rest : SpecTypeSubst]) : SpecTypeSubst
  (SpecTypeSubst.Cons key ty (box rest)))

(defenum SpecMaybeString
  (None)
  (Some String))

(defenum SpecMaybeDecl
  (None)
  (Some AstDecl))

(defenum ResultSpecProgram
  (Ok AstProgram)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecProgramWithPaths
  (Ok AstProgram AstDeclPathList)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecDecls
  (Ok AstDeclList SpecState)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecDeclsWithPaths
  (Ok AstDeclList AstDeclPathList SpecState)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecDecl
  (Ok SpecMaybeDecl SpecState)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecExpr
  (Ok i64 SpecState)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecExprList
  (Ok AstExprList SpecState)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecExprListBuild
  (Ok SpecState)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecLetBindingList
  (Ok AstLetBindingList SpecState)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecLetBindingListBuild
  (Ok SpecState)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecMatchArmList
  (Ok AstMatchArmList SpecState)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecMatchArmListBuild
  (Ok SpecState)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecArgs
  (Ok SpecValueList AstExprList SpecState)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecEnsure
  (Ok String SpecState)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecBuild
  (Ok AstParamList SpecValueSubst SpecTypeSubst)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecSubExpr
  (Ok i64)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecSubExprList
  (Ok AstExprList)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecSubExprListBuild
  (Ok)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecSubLetBindingList
  (Ok AstLetBindingList)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecSubLetBindingListBuild
  (Ok)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecSubMatchArmList
  (Ok AstMatchArmList)
  (Err (Box CompilerDiagnostic)))

(defenum ResultSpecSubMatchArmListBuild
  (Ok)
  (Err (Box CompilerDiagnostic)))

(defenum GenMaybeEntry
  (None)
  (Some AstDecl))

(defenum ResultGenKey
  (Ok String i64)
  (Err (Box CompilerDiagnostic)))

(defenum ResultGenDecl
  (Ok AstDeclList GenRegistry String)
  (Err (Box CompilerDiagnostic)))

(defenum ResultGenDecls
  (Ok AstDeclList GenRegistry String)
  (Err (Box CompilerDiagnostic)))

(defenum ResultGenProgram
  (Ok AstProgram)
  (Err (Box CompilerDiagnostic)))

(defenum ResultGenDeclsWithPaths
  (Ok AstDeclList AstDeclPathList GenRegistry String)
  (Err (Box CompilerDiagnostic)))

(defenum ResultGenProgramWithPaths
  (Ok AstProgram AstDeclPathList)
  (Err (Box CompilerDiagnostic)))

(define (spec-diagnostic-at-expr [expr : AstExpr] [message : String]) : CompilerDiagnostic
  (match expr
    [(AstExpr.Spanned _ span)
      (compiler-diagnostic-from-ast-span "" span message)]
    [_ (compiler-diagnostic-at-start "" message)]))

(define (spec-param-comptime? [param : AstParam]) : bool
  (match param
    [(AstParam.Param _ _ is-comptime) is-comptime]))

(define (spec-param-name [param : AstParam]) : String
  (match param
    [(AstParam.Param name _ _) (intern-str name)]))

(define (spec-param-type [param : AstParam]) : AstType
  (match param
    [(AstParam.Param _ ty _) ty]))

(define (spec-state-ctfe-env [state : SpecState]) : CtfeEnv
  (match state
    [(SpecState.State _ _ env _) env]))

(define (spec-state-pools [state : SpecState]) : AstNodePoolContext
  (match state
    [(SpecState.State _ _ _ pools) pools]))

(define (spec-ctfe-eval [state : SpecState] [expr : AstExpr] [fuel : i64]) : ResultCtfe
  (let
    [pools : AstNodePoolContext (spec-state-pools state)]
    (begin
      (ast-node-pool-context-capture-active! pools)
      (ast-node-pool-context-install! pools)
      (let
        [result : ResultCtfe
          (compiler-ctfe-eval expr (spec-state-ctfe-env state) fuel)]
        (begin
          (ast-node-pool-context-capture-active! pools)
          (ast-node-pool-context-install! pools)
          result)))))

(define (spec-type-kind? [ty : AstType]) : bool
  (begin
    (cbi.compiler-builtin-refresh!)
    (match ty
      [(AstType.Var name) (= name cbi.compiler-builtin-id-fix-type)]
      [_ false])))

(define (spec-param-list-has-comptime? [params : AstParamList]) : bool
  (spec-param-list-has-comptime-at? (& params) 0))

(define (spec-param-list-has-comptime-at?
  [params : (& params AstParamList)]
  [index : i64]) : bool
  (if (>= index (ast-param-list-len params))
    false
    (if (spec-param-comptime?
      (ast-param-list-get params index (ast-param-fallback)))
      true
      (spec-param-list-has-comptime-at? params (+ index 1)))))

(define (spec-template-shadow-contains?
  [shadowed : SpecTemplateShadowList]
  [name : String]) : bool
  (match shadowed
    [(SpecTemplateShadowList.Nil) false]
    [(SpecTemplateShadowList.Cons shadow-name rest)
      (if (string.eq shadow-name name)
        true
        (spec-template-shadow-contains? (box-get rest) name))]))

(define (spec-template-list-count [templates : SpecTemplateList]) : i64
  (match templates
    [(SpecTemplateList.Nil) 0]
    [(SpecTemplateList.Cons _ rest)
      (+ 1 (spec-template-list-count (box-get rest)))]))

(define (spec-template-values-fill-empty
  [values : (Array SpecMaybeTemplate)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! values index (SpecMaybeTemplate.None))
      (spec-template-values-fill-empty values (+ index 1) count))))

(define (spec-template-index-build
  [templates : SpecTemplateList]
  [index : spec_string_i64_map.Map]
  [values : (Array SpecMaybeTemplate)]
  [slot : i64]) : spec_string_i64_map.Map
  (match templates
    [(SpecTemplateList.Nil) index]
    [(SpecTemplateList.Cons template rest)
      (match template
        [(SpecTemplate.Item name _ _ _)
          (if (spec_string_i64_map.contains-borrowed? (& index) (& name))
            (spec-template-index-build (box-get rest) index values slot)
            (begin
              (array-set! values slot (SpecMaybeTemplate.Some template))
              (let
                [next-index : spec_string_i64_map.Map index]
                (begin
                  (spec_string_i64_map.insert (&mut next-index) name slot)
                  (spec-template-index-build
                    (box-get rest)
                    next-index
                    values
                    (+ slot 1))))))])]))

(define (spec-template-env-from-list [templates : SpecTemplateList]) : SpecTemplateEnv
  (let
    [count : i64 (spec-template-list-count templates)]
    [values : (Array SpecMaybeTemplate)
      (array.make-array SpecMaybeTemplate count)]
    (begin
      (spec-template-values-fill-empty values 0 count)
      (SpecTemplateEnv
        (spec-template-index-build
          templates
          (spec_string_i64_map.with-capacity (+ (* count 2) 16))
          values
          0)
        values
        SpecTemplateShadowList.Nil))))

(define (spec-template-lookup [templates : SpecTemplateEnv] [name : String]) : SpecMaybeTemplate
  (if (spec-template-shadow-contains? (struct-get templates shadowed) name)
    (SpecMaybeTemplate.None)
    (match (spec_string_i64_map.get-borrowed
      (& (struct-get templates index))
      (& name))
      [(spec_string_i64_map.LookupFound slot)
        (array.ref (struct-get templates values) slot)]
      [(spec_string_i64_map.LookupMissing) (SpecMaybeTemplate.None)])))

(define (spec-template-env-shadow-name
  [templates : SpecTemplateEnv]
  [name : String]) : SpecTemplateEnv
  (SpecTemplateEnv
    (struct-get templates index)
    (struct-get templates values)
    (SpecTemplateShadowList.Cons name (box (struct-get templates shadowed)))))

(define (spec-template-env-shadow-params
  [templates : SpecTemplateEnv]
  [params : AstParamList]) : SpecTemplateEnv
  (spec-template-env-shadow-params-at templates (& params) 0))

(define (spec-template-env-shadow-params-at
  [templates : SpecTemplateEnv]
  [params : (& params AstParamList)]
  [index : i64]) : SpecTemplateEnv
  (if (>= index (ast-param-list-len params))
    templates
    (spec-template-env-shadow-params-at
      (spec-template-env-shadow-name
        templates
        (spec-param-name (ast-param-list-get params index (ast-param-fallback))))
      params
      (+ index 1))))

(define (spec-template-env-shadow-let-binding-names
  [templates : SpecTemplateEnv]
  [bindings : AstLetBindingList]) : SpecTemplateEnv
  (spec-template-env-shadow-let-binding-names-at templates (& bindings) 0))

(define (spec-template-env-shadow-let-binding-names-at
  [templates : SpecTemplateEnv]
  [bindings : (& bindings AstLetBindingList)]
  [index : i64]) : SpecTemplateEnv
  (if (>= index (ast-let-binding-list-len bindings))
    templates
    (match (ast-let-binding-list-get bindings index (ast-let-binding-fallback))
      [(AstLetBinding.Binding name _ _)
        (spec-template-env-shadow-let-binding-names-at
          (spec-template-env-shadow-name templates (intern-str name))
          bindings
          (+ index 1))])))

(define (spec-template-env-shadow-pattern
  [templates : SpecTemplateEnv]
  [pattern : AstPattern]) : SpecTemplateEnv
  (match pattern
    [(AstPattern.Var name _)
      (spec-template-env-shadow-name templates (intern-str name))]
    [(AstPattern.Tuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-template-env-shadow-pattern-list templates patterns))]
    [(AstPattern.Wildcard) templates]
    [(AstPattern.Binding name)
      (spec-template-env-shadow-name templates (intern-str name))]
    [(AstPattern.Variant _ patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-template-env-shadow-pattern-list templates patterns))]
    [(AstPattern.Literal _) templates]))

(define (spec-template-env-shadow-pattern-list
  [templates : SpecTemplateEnv]
  [patterns : AstPatternList]) : SpecTemplateEnv
  (spec-template-env-shadow-pattern-list-at templates (& patterns) 0))

(define (spec-template-env-shadow-pattern-list-at
  [templates : SpecTemplateEnv]
  [patterns : (& patterns AstPatternList)]
  [index : i64]) : SpecTemplateEnv
  (if (>= index (struct-get patterns len))
    templates
    (spec-template-env-shadow-pattern-list-at
      (spec-template-env-shadow-pattern
        templates
        (ast-pattern-list-get patterns index (ast-pattern-fallback)))
      patterns
      (+ index 1))))

(define (spec-collect-templates-with-pools
  [pools : AstNodePoolContext]
  [decls : AstDeclList]) : SpecTemplateList
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) (SpecTemplateList.Nil)]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Unsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDecl.DefFn name params ret body-box _)
                  (let
                    [body : AstExpr
                      (ast-node-pool-context-expr-get pools body-box)]
                    (if (spec-param-list-has-comptime? params)
                      (spec-template-cons
                        (SpecTemplate.Item (intern-str name) params ret body)
                        (spec-collect-templates-with-pools pools rest))
                      (spec-collect-templates-with-pools pools rest)))]
                [_ (spec-collect-templates-with-pools pools rest)]))]
          [(AstDecl.DefFn name params ret body-box _)
            (let
              [body : AstExpr (ast-node-pool-context-expr-get pools body-box)]
              (if (spec-param-list-has-comptime? params)
                (spec-template-cons
                  (SpecTemplate.Item (intern-str name) params ret body)
                  (spec-collect-templates-with-pools pools rest))
                (spec-collect-templates-with-pools pools rest)))]
          [_ (spec-collect-templates-with-pools pools rest)]))]))

(define (spec-collect-templates [decls : AstDeclList]) : SpecTemplateList
  (spec-collect-templates-with-pools
    (ast-node-pool-context-capture-active)
    decls))

(define (spec-cache-lookup [cache : spec_string_string_map.Map] [key : String]) : SpecMaybeString
  (match (spec_string_string_map.get-borrowed (& cache) (& key))
    [(spec_string_string_map.LookupFound name) (SpecMaybeString.Some name)]
    [(spec_string_string_map.LookupMissing) (SpecMaybeString.None)]))

(define (spec-decl-list-append-one [decls : AstDeclList] [decl : AstDecl]) : AstDeclList
  (let
    [out : AstDeclList
      (ast-decl-list-with-capacity (+ (ast-decl-list-len (& decls)) 1))]
    (begin
      (ast-decl-list-append-from (&mut out) (& decls) 0)
      (ast-decl-list-push (&mut out) decl)
      out)))

(define (spec-decl-list-append [front : AstDeclList] [back : AstDeclList]) : AstDeclList
  (let
    [out : AstDeclList
      (ast-decl-list-with-capacity
        (+ (ast-decl-list-len (& front)) (ast-decl-list-len (& back))))]
    (begin
      (ast-decl-list-append-from (&mut out) (& front) 0)
      (ast-decl-list-append-from (&mut out) (& back) 0)
      out)))

(define (spec-decl-path-list-append
  [front : AstDeclPathList]
  [back : AstDeclPathList]) : AstDeclPathList
  (let
    [out : AstDeclPathList
      (ast-decl-path-list-with-capacity
        (+ (ast-decl-path-list-len (& front)) (ast-decl-path-list-len (& back))))]
    (begin
      (ast-decl-path-list-append-from (&mut out) (& front) 0)
      (ast-decl-path-list-append-from (&mut out) (& back) 0)
      out)))

(define (gen-single-decl-list [decl : AstDecl]) : AstDeclList
  (ast-decl-cons decl (ast-decl-list-new)))

(define (spec-int-key [n : i64]) : String
  (if (< n 0)
    (string.append "m" (string.int->string (- 0 n)))
    (string.int->string n)))

(define (spec-string-key-from [text : String] [idx : i64] [n : i64]) : String
  (if (>= idx n)
    ""
    (string.append
      "_"
      (string.append
        (string.int->string (cast (string.string-ref text idx) : i64))
        (spec-string-key-from text (+ idx 1) n)))))

(define (spec-string-key [text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    (string.append
      "string_"
      (string.append (string.int->string n) (spec-string-key-from text 0 n)))))

(define (spec-type-list-key-at [types : (& types AstTypeList)] [index : i64]) : String
  (if (>= index (ast-type-list-len types))
    "nil"
    (string.append
      (spec-type-key
        (ty-node-get (ast-type-list-get types index (ast-type-id-fallback))))
      (string.append "_" (spec-type-list-key-at types (+ index 1))))))

(define (spec-type-list-key [types : AstTypeList]) : String
  (spec-type-list-key-at (& types) 0))

(define (spec-lifetime-list-key-at
  [lifetimes : (& lifetimes AstLifetimeList)]
  [index : i64]) : String
  (if (>= index (ast-lifetime-list-len lifetimes))
    "nil"
    (string.append
      (ast-lifetime-list-get lifetimes index (ast-lifetime-fallback))
      (string.append "_" (spec-lifetime-list-key-at lifetimes (+ index 1))))))

(define (spec-lifetime-list-key [lifetimes : AstLifetimeList]) : String
  (spec-lifetime-list-key-at (& lifetimes) 0))

(define (spec-type-key [ty : AstType]) : String
  (match ty
    [(AstType.I64) "i64"]
    [(AstType.I32) "i32"]
    [(AstType.I16) "i16"]
    [(AstType.I8) "i8"]
    [(AstType.U64) "u64"]
    [(AstType.U32) "u32"]
    [(AstType.U16) "u16"]
    [(AstType.U8) "u8"]
    [(AstType.F64) "f64"]
    [(AstType.F32) "f32"]
    [(AstType.Bool) "bool"]
    [(AstType.Char) "char"]
    [(AstType.String) "String"]
    [(AstType.Str) "str"]
    [(AstType.Bytes) "bytes"]
    [(AstType.Unit) "unit"]
    [(AstType.Never) "never"]
    [(AstType.Expr) "Expr"]
    [(AstType.ExprList) "ExprList"]
    [(AstType.Func args ret)
      (string.append
        "fn_"
        (string.append
          (spec-type-list-key (box-get args))
          (string.append "_to_" (spec-type-key (ty-node-get ret)))))]
    [(AstType.Tuple elems)
      (string.append "tuple_" (spec-type-list-key (box-get elems)))]
    [(AstType.Array elem count)
      (string.append
        "array_"
        (string.append
          (spec-type-key (ty-node-get elem))
          (string.append "_" (spec-int-key count))))]
    [(AstType.DynArray elem)
      (string.append "dynarray_" (spec-type-key (ty-node-get elem)))]
    [(AstType.Box elem)
      (string.append "box_" (spec-type-key (ty-node-get elem)))]
    [(AstType.Ptr elem)
      (string.append "ptr_" (spec-type-key (ty-node-get elem)))]
    [(AstType.MutPtr elem)
      (string.append "mutptr_" (spec-type-key (ty-node-get elem)))]
    [(AstType.Ref region inner)
      (string.append
        "ref_"
        (string.append
          region
          (string.append "_" (spec-type-key (ty-node-get inner)))))]
    [(AstType.MutRef region inner)
      (string.append
        "mutref_"
        (string.append
          region
          (string.append "_" (spec-type-key (ty-node-get inner)))))]
    [(AstType.Region region inner)
      (string.append
        "region_"
        (string.append
          region
          (string.append "_" (spec-type-key (ty-node-get inner)))))]
    [(AstType.Enum name) (string.append "enum_" (intern-str name))]
    [(AstType.EnumArgs name lifetimes)
      (string.append
        "enumargs_"
        (string.append
          (intern-str name)
          (string.append "_" (spec-lifetime-list-key (box-get lifetimes)))))]
    [(AstType.Struct name) (string.append "struct_" (intern-str name))]
    [(AstType.StructArgs name lifetimes)
      (string.append
        "structargs_"
        (string.append
          (intern-str name)
          (string.append "_" (spec-lifetime-list-key (box-get lifetimes)))))]
    [(AstType.Var name) (string.append "var_" (intern-str name))]
    [(AstType.VarArgs name lifetimes)
      (string.append
        "varargs_"
        (string.append
          (intern-str name)
          (string.append "_" (spec-lifetime-list-key (box-get lifetimes)))))]))

(define (spec-value-key [value : CompilerCtfeValue]) : String
  (match value
    [(CompilerCtfeValue.I64 n) (string.append "i64_" (spec-int-key n))]
    [(CompilerCtfeValue.F64 n)
      (string.append "f64_" (spec-string-key (compiler-float-format-f64 n)))]
    [(CompilerCtfeValue.F32 n)
      (string.append
        "f32_"
        (spec-string-key
          (compiler-float-format-f64 (compiler-float-round-f32-as-f64 n))))]
    [(CompilerCtfeValue.Bool b)
      (if b
        "bool_1"
        "bool_0")]
    [(CompilerCtfeValue.Char c)
      (string.append "char_" (string.int->string (cast c : i64)))]
    [(CompilerCtfeValue.String text) (spec-string-key text)]
    [(CompilerCtfeValue.Unit) "unit"]
    [(CompilerCtfeValue.Type ty) (string.append "type_" (spec-type-key ty))]
    [(CompilerCtfeValue.Expr _ _) "Expr"]
    [(CompilerCtfeValue.ExprList _) "expr-list"]
    [(CompilerCtfeValue.ExprClause _) "expr-clause"]
    [(CompilerCtfeValue.ExprClauseList _) "expr-clause-list"]
    [(CompilerCtfeValue.ExprBindingClause _) "expr-binding-clause"]
    [(CompilerCtfeValue.ExprBindingClauseList _) "expr-binding-clause-list"]
    [(CompilerCtfeValue.Pattern _) "pattern"]
    [(CompilerCtfeValue.PatternList _) "pattern-list"]
    [(CompilerCtfeValue.MatchArm _) "match-arm"]
    [(CompilerCtfeValue.MatchArmList _) "match-arm-list"]
    [(CompilerCtfeValue.TypeInfo ty)
      (string.append "typeinfo_" (spec-type-key ty))]
    [(CompilerCtfeValue.TypeInfoBox ty)
      (string.append "typeinfo-box_" (spec-type-key ty))]
    [(CompilerCtfeValue.TypeInfoList _) "typeinfo-list"]
    [(CompilerCtfeValue.TypeField _ _) "type-field"]
    [(CompilerCtfeValue.TypeFieldList _) "type-field-list"]
    [(CompilerCtfeValue.TypeVariantPayload _) "type-variant-payload"]
    [(CompilerCtfeValue.TypeVariantPayloadList _) "type-variant-payload-list"]
    [(CompilerCtfeValue.TypeVariant _ _) "type-variant"]
    [(CompilerCtfeValue.TypeVariantList _) "type-variant-list"]))

(define (spec-values-key [values : SpecValueList]) : String
  (match values
    [(SpecValueList.Nil) "none"]
    [(SpecValueList.Cons head rest)
      (string.append
        (spec-value-key head)
        (string.append "_" (spec-values-key (box-get rest))))]))

(define (spec-specialization-key [name : String] [values : SpecValueList]) : String
  (string.append name (string.append ":" (spec-values-key values))))

(define (spec-specialized-name [name : String] [values : SpecValueList]) : String
  (string.append
    "__tl_specialized_"
    (string.append name (string.append "_" (spec-values-key values)))))

(define (gen-registry-empty) : GenRegistry
  (let
    [capacity : i64 64]
    [decls : (Array AstDecl) (array.make-array AstDecl capacity)]
    (GenRegistry (spec_string_i64_map.with-capacity capacity) decls 0)))

(define (gen-registry-lookup [registry : GenRegistry] [key : String]) : GenMaybeEntry
  (match (spec_string_i64_map.get-borrowed
    (& (struct-get registry index))
    (& key))
    [(spec_string_i64_map.LookupFound slot)
      (GenMaybeEntry.Some (array.ref (struct-get registry decls) slot))]
    [(spec_string_i64_map.LookupMissing) (GenMaybeEntry.None)]))

(define (gen-registry-copy-decls
  [src : (Array AstDecl)]
  [dst : (Array AstDecl)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array.ref src index))
      (gen-registry-copy-decls src dst (+ index 1) count))))

(define (gen-registry-grow [registry : GenRegistry]) : GenRegistry
  (let
    [old-index : spec_string_i64_map.Map (struct-get registry index)]
    [old-decls : (Array AstDecl) (struct-get registry decls)]
    [old-len : i64 (struct-get registry len)]
    [old-capacity : i64 (array.length old-decls)]
    [new-capacity : i64
      (if (< old-capacity 1)
        1
        (* old-capacity 2))]
    [new-decls : (Array AstDecl) (array.make-array AstDecl new-capacity)]
    (begin
      (gen-registry-copy-decls old-decls new-decls 0 old-len)
      (GenRegistry old-index new-decls old-len))))

(define (gen-registry-insert
  [registry : GenRegistry]
  [key : String]
  [decl : AstDecl]) : GenRegistry
  (let
    [ready : GenRegistry
      (if (>=
        (struct-get registry len)
        (array.length (struct-get registry decls)))
        (gen-registry-grow registry)
        registry)]
    [slot : i64 (struct-get ready len)]
    [decls : (Array AstDecl) (struct-get ready decls)]
    [index : spec_string_i64_map.Map (struct-get ready index)]
    (begin
      (array-set! decls slot decl)
      (spec_string_i64_map.insert (&mut index) key slot)
      (GenRegistry index decls (+ slot 1)))))

(define (gen-decl-visible-name [decl : AstDecl]) : SpecMaybeString
  (match decl
    [(AstDecl.Def name _ _) (SpecMaybeString.Some (intern-str name))]
    [(AstDecl.DefFn name _ _ _ _) (SpecMaybeString.Some (intern-str name))]
    [(AstDecl.Extern name _ _ _) (SpecMaybeString.Some (intern-str name))]
    [(AstDecl.DefDispatch name _) (SpecMaybeString.Some (intern-str name))]
    [(AstDecl.DefEnum name _ _) (SpecMaybeString.Some (intern-str name))]
    [(AstDecl.DefEnumLifetimes name _ _ _)
      (SpecMaybeString.Some (intern-str name))]
    [(AstDecl.DefStruct name _ _ _) (SpecMaybeString.Some (intern-str name))]
    [(AstDecl.DefStructLifetimes name _ _ _ _)
      (SpecMaybeString.Some (intern-str name))]
    [(AstDecl.DefMacro name _ _ _) (SpecMaybeString.Some (intern-str name))]
    [(AstDecl.Unsafe inner-box) (gen-decl-visible-name (box-get inner-box))]
    [(AstDecl.ComptimeDecl _ inner-box)
      (gen-decl-visible-name (box-get inner-box))]
    [_ (SpecMaybeString.None)]))

(define (gen-maybe-type-eq? [a : AstMaybeType] [b : AstMaybeType]) : bool
  (match a
    [(AstMaybeType.No)
      (match b
        [(AstMaybeType.No) true]
        [_ false])]
    [(AstMaybeType.Some a-ty)
      (match b
        [(AstMaybeType.Some b-ty) (ctfe-type-eq a-ty b-ty)]
        [_ false])]))

(define (gen-expr-eq? [a : AstExpr] [b : AstExpr]) : bool
  (ctfe-expr-eq (ast-expr-unspan a) (ast-expr-unspan b)))

(define (gen-param-eq? [a : AstParam] [b : AstParam]) : bool
  (match a
    [(AstParam.Param a-name a-ty a-comptime)
      (match b
        [(AstParam.Param b-name b-ty b-comptime)
          (and
            (= a-name b-name)
            (ctfe-type-eq a-ty b-ty)
            (= a-comptime b-comptime))])]))

(define (gen-param-list-eq? [a : AstParamList] [b : AstParamList]) : bool
  (let
    [len : i64 (ast-param-list-len (& a))]
    (and
      (= len (ast-param-list-len (& b)))
      (gen-param-list-eq-at? (& a) (& b) len 0))))

(define (gen-param-list-eq-at?
  [a : (& a AstParamList)]
  [b : (& b AstParamList)]
  [len : i64]
  [index : i64]) : bool
  (if (>= index len)
    true
    (and
      (gen-param-eq?
        (ast-param-list-get a index (ast-param-fallback))
        (ast-param-list-get b index (ast-param-fallback)))
      (gen-param-list-eq-at? a b len (+ index 1)))))

(define (gen-macro-param-eq? [a : AstMacroParam] [b : AstMacroParam]) : bool
  (match a
    [(AstMacroParam.Param a-name a-ty a-variadic)
      (match b
        [(AstMacroParam.Param b-name b-ty b-variadic)
          (and
            (= a-name b-name)
            (ctfe-type-eq a-ty b-ty)
            (= a-variadic b-variadic))])]))

(define (gen-macro-param-list-eq?
  [a : AstMacroParamList]
  [b : AstMacroParamList]) : bool
  (let
    [len : i64 (ast-macro-param-list-len (& a))]
    (and
      (= len (ast-macro-param-list-len (& b)))
      (gen-macro-param-list-eq-at? (& a) (& b) len 0))))

(define (gen-macro-param-list-eq-at?
  [a : (& a AstMacroParamList)]
  [b : (& b AstMacroParamList)]
  [len : i64]
  [index : i64]) : bool
  (if (>= index len)
    true
    (and
      (gen-macro-param-eq?
        (ast-macro-param-list-get a index (ast-macro-param-fallback))
        (ast-macro-param-list-get b index (ast-macro-param-fallback)))
      (gen-macro-param-list-eq-at? a b len (+ index 1)))))

(define (gen-field-cleanup-eq? [a : AstFieldCleanup] [b : AstFieldCleanup]) : bool
  (match a
    [(AstFieldCleanup.No)
      (match b
        [(AstFieldCleanup.No) true]
        [_ false])]
    [(AstFieldCleanup.Fn a-name)
      (match b
        [(AstFieldCleanup.Fn b-name) (= a-name b-name)]
        [_ false])]
    [(AstFieldCleanup.Owned)
      (match b
        [(AstFieldCleanup.Owned) true]
        [_ false])]))

(define (gen-field-def-eq? [a : AstFieldDef] [b : AstFieldDef]) : bool
  (match a
    [(AstFieldDef.Def a-name a-ty a-cleanup)
      (match b
        [(AstFieldDef.Def b-name b-ty b-cleanup)
          (and
            (= a-name b-name)
            (ctfe-type-eq a-ty b-ty)
            (gen-field-cleanup-eq? a-cleanup b-cleanup))])]))

(define (gen-field-list-eq? [a : AstFieldDefList] [b : AstFieldDefList]) : bool
  (if (= (struct-get (& a) len) (struct-get (& b) len))
    (gen-field-list-eq-at (& a) (& b) 0)
    false))

(define (gen-field-list-eq-at
  [a : (& a AstFieldDefList)]
  [b : (& b AstFieldDefList)]
  [index : i64]) : bool
  (if (>= index (struct-get a len))
    true
    (and
      (gen-field-def-eq?
        (ast-field-def-list-get a index (ast-field-def-fallback))
        (ast-field-def-list-get b index (ast-field-def-fallback)))
      (gen-field-list-eq-at a b (+ index 1)))))

(define (gen-struct-repr-eq? [a : AstStructRepr] [b : AstStructRepr]) : bool
  (match a
    [(AstStructRepr.Default)
      (match b
        [(AstStructRepr.Default) true]
        [_ false])]
    [(AstStructRepr.C)
      (match b
        [(AstStructRepr.C) true]
        [_ false])]))

(define (gen-struct-cleanup-eq? [a : AstStructCleanup] [b : AstStructCleanup]) : bool
  (match a
    [(AstStructCleanup.No)
      (match b
        [(AstStructCleanup.No) true]
        [_ false])]
    [(AstStructCleanup.Fn a-name)
      (match b
        [(AstStructCleanup.Fn b-name) (= a-name b-name)]
        [_ false])]))

(define (gen-enum-cleanup-eq? [a : AstEnumCleanup] [b : AstEnumCleanup]) : bool
  (match a
    [(AstEnumCleanup.No)
      (match b
        [(AstEnumCleanup.No) true]
        [_ false])]
    [(AstEnumCleanup.Fn a-name)
      (match b
        [(AstEnumCleanup.Fn b-name) (= a-name b-name)]
        [_ false])]))

(define (gen-variant-payload-cleanup-eq?
  [a : AstVariantPayloadCleanup]
  [b : AstVariantPayloadCleanup]) : bool
  (match a
    [(AstVariantPayloadCleanup.No)
      (match b
        [(AstVariantPayloadCleanup.No) true]
        [_ false])]
    [(AstVariantPayloadCleanup.Fn a-name)
      (match b
        [(AstVariantPayloadCleanup.Fn b-name) (= a-name b-name)]
        [_ false])]
    [(AstVariantPayloadCleanup.Owned)
      (match b
        [(AstVariantPayloadCleanup.Owned) true]
        [_ false])]))

(define (gen-variant-payload-cleanup-list-eq?
  [a : AstVariantPayloadCleanupList]
  [b : AstVariantPayloadCleanupList]) : bool
  (if (= (struct-get (& a) len) (struct-get (& b) len))
    (gen-variant-payload-cleanup-list-eq-at? (& a) (& b) 0)
    false))

(define (gen-variant-payload-cleanup-list-eq-at?
  [a : (& a AstVariantPayloadCleanupList)]
  [b : (& b AstVariantPayloadCleanupList)]
  [index : i64]) : bool
  (if (>= index (struct-get a len))
    true
    (and
      (gen-variant-payload-cleanup-eq?
        (ast-variant-payload-cleanup-list-get
          a
          index
          (ast-variant-payload-cleanup-fallback))
        (ast-variant-payload-cleanup-list-get
          b
          index
          (ast-variant-payload-cleanup-fallback)))
      (gen-variant-payload-cleanup-list-eq-at? a b (+ index 1)))))

(define (gen-variant-def-eq? [a : AstVariantDef] [b : AstVariantDef]) : bool
  (match a
    [(AstVariantDef.Def a-name a-payloads a-cleanups)
      (match b
        [(AstVariantDef.Def b-name b-payloads b-cleanups)
          (and
            (= a-name b-name)
            (ctfe-type-list-eq a-payloads b-payloads)
            (gen-variant-payload-cleanup-list-eq? a-cleanups b-cleanups))])]))

(define (gen-variant-list-eq? [a : AstVariantDefList] [b : AstVariantDefList]) : bool
  (if (= (struct-get (& a) len) (struct-get (& b) len))
    (gen-variant-list-eq-at? (& a) (& b) 0)
    false))

(define (gen-variant-list-eq-at?
  [a : (& a AstVariantDefList)]
  [b : (& b AstVariantDefList)]
  [index : i64]) : bool
  (if (>= index (struct-get a len))
    true
    (and
      (gen-variant-def-eq?
        (ast-variant-def-list-get a index (ast-variant-def-fallback))
        (ast-variant-def-list-get b index (ast-variant-def-fallback)))
      (gen-variant-list-eq-at? a b (+ index 1)))))

(define (gen-fn-export-eq? [a : AstFnExport] [b : AstFnExport]) : bool
  (match a
    [(AstFnExport.No)
      (match b
        [(AstFnExport.No) true]
        [_ false])]
    [(AstFnExport.Export a-symbol)
      (match b
        [(AstFnExport.Export b-symbol) (= a-symbol b-symbol)]
        [_ false])]))

(define (gen-import-kind-eq? [a : AstImportKind] [b : AstImportKind]) : bool
  (match a
    [(AstImportKind.Path)
      (match b
        [(AstImportKind.Path) true]
        [_ false])]
    [(AstImportKind.Module)
      (match b
        [(AstImportKind.Module) true]
        [_ false])]
    [(AstImportKind.Macro _ _)
      (match b
        [(AstImportKind.Macro _ _) true]
        [_ false])]
    [(AstImportKind.MacroDecls _ _)
      (match b
        [(AstImportKind.MacroDecls _ _) true]
        [_ false])]))

(define (gen-maybe-module-name-eq?
  [a : AstMaybeModuleName]
  [b : AstMaybeModuleName]) : bool
  (match a
    [(AstMaybeModuleName.No)
      (match b
        [(AstMaybeModuleName.No) true]
        [_ false])]
    [(AstMaybeModuleName.Some a-name)
      (match b
        [(AstMaybeModuleName.Some b-name) (string.eq a-name b-name)]
        [_ false])]))

(define (gen-maybe-import-alias-eq?
  [a : AstMaybeImportAlias]
  [b : AstMaybeImportAlias]) : bool
  (match a
    [(AstMaybeImportAlias.No)
      (match b
        [(AstMaybeImportAlias.No) true]
        [_ false])]
    [(AstMaybeImportAlias.Some a-name)
      (match b
        [(AstMaybeImportAlias.Some b-name) (string.eq a-name b-name)]
        [_ false])]))

(define (gen-import-spec-eq? [a : AstImportSpec] [b : AstImportSpec]) : bool
  (match a
    [(AstImportSpec.Spec a-kind a-path a-module a-alias _)
      (match b
        [(AstImportSpec.Spec b-kind b-path b-module b-alias _)
          (and
            (gen-import-kind-eq? a-kind b-kind)
            (string.eq a-path b-path)
            (gen-maybe-module-name-eq? a-module b-module)
            (gen-maybe-import-alias-eq? a-alias b-alias))])]))

(define (gen-decl-list-eq? [a : AstDeclList] [b : AstDeclList]) : bool
  (match (ast-decl-list-step a)
    [(AstDeclListStep.Nil)
      (match (ast-decl-list-step b)
        [(AstDeclListStep.Nil) true]
        [_ false])]
    [(AstDeclListStep.Cons a-head a-rest)
      (match (ast-decl-list-step b)
        [(AstDeclListStep.Cons b-head b-rest)
          (and (gen-decl-eq? a-head b-head) (gen-decl-list-eq? a-rest b-rest))]
        [_ false])]))

(define (gen-decl-eq? [a : AstDecl] [b : AstDecl]) : bool
  (match a
    [(AstDecl.Def a-name a-ty a-value-box)
      (let
        [a-value : AstExpr (ast-node-get a-value-box)]
        (match b
          [(AstDecl.Def b-name b-ty b-value-box)
            (let
              [b-value : AstExpr (ast-node-get b-value-box)]
              (and
                (= a-name b-name)
                (gen-maybe-type-eq? a-ty b-ty)
                (gen-expr-eq? a-value b-value)))]
          [_ false]))]
    [(AstDecl.DefFn a-name a-params a-ret a-body-box a-export)
      (let
        [a-body : AstExpr (ast-node-get a-body-box)]
        (match b
          [(AstDecl.DefFn b-name b-params b-ret b-body-box b-export)
            (let
              [b-body : AstExpr (ast-node-get b-body-box)]
              (and
                (= a-name b-name)
                (gen-param-list-eq? a-params b-params)
                (ctfe-type-eq a-ret b-ret)
                (gen-expr-eq? a-body b-body)
                (gen-fn-export-eq? a-export b-export)))]
          [_ false]))]
    [(AstDecl.DefEnum a-name a-cleanup a-variants)
      (match b
        [(AstDecl.DefEnum b-name b-cleanup b-variants)
          (and
            (= a-name b-name)
            (gen-enum-cleanup-eq? a-cleanup b-cleanup)
            (gen-variant-list-eq? a-variants b-variants))]
        [_ false])]
    [(AstDecl.DefEnumLifetimes a-name a-lifetimes a-cleanup a-variants)
      (match b
        [(AstDecl.DefEnumLifetimes b-name b-lifetimes b-cleanup b-variants)
          (and
            (= a-name b-name)
            (ctfe-lifetime-list-eq a-lifetimes b-lifetimes)
            (gen-enum-cleanup-eq? a-cleanup b-cleanup)
            (gen-variant-list-eq? a-variants b-variants))]
        [_ false])]
    [(AstDecl.DefStruct a-name a-repr a-cleanup a-fields)
      (match b
        [(AstDecl.DefStruct b-name b-repr b-cleanup b-fields)
          (and
            (= a-name b-name)
            (gen-struct-repr-eq? a-repr b-repr)
            (gen-struct-cleanup-eq? a-cleanup b-cleanup)
            (gen-field-list-eq? a-fields b-fields))]
        [_ false])]
    [(AstDecl.DefStructLifetimes a-name a-lifetimes a-repr a-cleanup a-fields)
      (match b
        [(AstDecl.DefStructLifetimes
            b-name
            b-lifetimes
            b-repr
            b-cleanup
            b-fields)
          (and
            (= a-name b-name)
            (ctfe-lifetime-list-eq a-lifetimes b-lifetimes)
            (gen-struct-repr-eq? a-repr b-repr)
            (gen-struct-cleanup-eq? a-cleanup b-cleanup)
            (gen-field-list-eq? a-fields b-fields))]
        [_ false])]
    [(AstDecl.DefMacro a-name a-params a-ret a-body-box)
      (let
        [a-body : AstExpr (ast-node-get a-body-box)]
        (match b
          [(AstDecl.DefMacro b-name b-params b-ret b-body-box)
            (let
              [b-body : AstExpr (ast-node-get b-body-box)]
              (and
                (= a-name b-name)
                (gen-macro-param-list-eq? a-params b-params)
                (ctfe-type-eq a-ret b-ret)
                (gen-expr-eq? a-body b-body)))]
          [_ false]))]
    [(AstDecl.Import a-spec)
      (match b
        [(AstDecl.Import b-spec) (gen-import-spec-eq? a-spec b-spec)]
        [_ false])]
    [(AstDecl.IncludeStr a-name a-path)
      (match b
        [(AstDecl.IncludeStr b-name b-path)
          (and (string.eq a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(AstDecl.IncludeBin a-name a-path)
      (match b
        [(AstDecl.IncludeBin b-name b-path)
          (and (string.eq a-name b-name) (string.eq a-path b-path))]
        [_ false])]
    [(AstDecl.Test a-name a-body-box _)
      (let
        [a-body : AstExpr (ast-node-get a-body-box)]
        (match b
          [(AstDecl.Test b-name b-body-box _)
            (let
              [b-body : AstExpr (ast-node-get b-body-box)]
              (and (= a-name b-name) (gen-expr-eq? a-body b-body)))]
          [_ false]))]
    [(AstDecl.Module a-name)
      (match b
        [(AstDecl.Module b-name) (= a-name b-name)]
        [_ false])]
    [(AstDecl.ModuleBody a-name a-body-box)
      (match b
        [(AstDecl.ModuleBody b-name b-body-box)
          (and
            (= a-name b-name)
            (gen-decl-list-eq? (box-get a-body-box) (box-get b-body-box)))]
        [_ false])]
    [(AstDecl.ComptimeDecl _ a-inner-box)
      (let
        [a-inner : AstDecl (box-get a-inner-box)]
        (match b
          [(AstDecl.ComptimeDecl _ b-inner-box)
            (gen-decl-eq? a-inner (box-get b-inner-box))]
          [_ (gen-decl-eq? a-inner b)]))]
    [(AstDecl.Unsafe a-inner-box)
      (let
        [a-inner : AstDecl (box-get a-inner-box)]
        (match b
          [(AstDecl.Unsafe b-inner-box)
            (gen-decl-eq? a-inner (box-get b-inner-box))]
          [_ (gen-decl-eq? a-inner b)]))]
    [_ false]))

(define (gen-key-exprs [exprs : AstExprList] [env : CtfeEnv] [fuel : i64]) : ResultGenKey
  (gen-key-exprs-at (& exprs) 0 env fuel))

(define (gen-key-exprs-at
  [exprs : (& exprs AstExprList)]
  [index : i64]
  [env : CtfeEnv]
  [fuel : i64]) : ResultGenKey
  (if (>= index (struct-get exprs len))
    (ResultGenKey.Ok "none" fuel)
    (let
      [head-id : i64 (ast-expr-list-get exprs index 0)]
      [head-expr : AstExpr (ast-node-get head-id)]
      (match (compiler-ctfe-eval head-expr env fuel)
        [(ResultCtfe.Ok value head-fuel)
          (match value
            [(CompilerCtfeValue.String text)
              (match (gen-key-exprs-at exprs (+ index 1) env head-fuel)
                [(ResultGenKey.Ok tail tail-fuel)
                  (ResultGenKey.Ok
                    (string.append
                      (spec-string-key text)
                      (string.append "_" tail))
                    tail-fuel)]
                [(ResultGenKey.Err diag) (ResultGenKey.Err diag)])]
            [_
              (ResultGenKey.Err
                (box
                  (spec-diagnostic-at-expr
                    head-expr
                    "generated-decl: key expression must evaluate to String")))])]
        [(ResultCtfe.Err diag) (ResultGenKey.Err diag)]))))

(define (gen-full-key
  [module : String]
  [generator : String]
  [item : String]
  [arg-key : String]) : String
  (string.append
    "generated:"
    (string.append
      (spec-string-key module)
      (string.append
        ":"
        (string.append
          (spec-string-key generator)
          (string.append
            ":"
            (string.append (spec-string-key item) (string.append ":" arg-key))))))))

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

(define (gen-qualified-local-name-start-from
  [name : String]
  [index : i64]
  [n : i64]
  [start : i64]) : i64
  (if (>= index n)
    start
    (gen-qualified-local-name-start-from
      name
      (+ index 1)
      n
      (if (= (cast (string.string-ref name index) : i64) 46)
        (+ index 1)
        start))))

(define (gen-qualified-local-name-start [name : String]) : i64
  (gen-qualified-local-name-start-from name 0 (string.string-length name) 0))

(define (gen-qualified-local-name [name : String]) : String
  (let
    [n : i64 (string.string-length name)]
    [start : i64 (gen-qualified-local-name-start name)]
    (string.substring name start (- n start))))

(define (gen-qualified-function-prefix
  [item-name : String]
  [local-prefix : String]) : String
  (let
    [start : i64 (gen-qualified-local-name-start item-name)]
    (if (= start 0)
      local-prefix
      (string.append (string.substring item-name 0 start) local-prefix))))

(define (gen-item-mismatch-diag [expected : String] [actual : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start
    ""
    (string.append
      "generated-decl: metadata item "
      (string.append expected (string.append " does not match payload " actual)))))

(define (gen-incompatible-diag [item : String] [key : String]) : CompilerDiagnostic
  (compiler-diagnostic-with-note
    (compiler-diagnostic-with-note
      (compiler-diagnostic-at-start
        ""
        (string.append
          "generated-decl: duplicate generated key for "
          (string.append item " has incompatible payload")))
      (string.append "conflicting generated item: " item))
    (string.append "generated identity: " key)))

(define (gen-register-generated-decl
  [template : AstDecl]
  [module : String]
  [generator : String]
  [item : String]
  [args : AstExprList]
  [arg-key : String]
  [registry : GenRegistry]) : ResultGenDecl
  (let
    [key : String (gen-registration-key module generator item arg-key)]
    (match (gen-registry-lookup registry key)
      [(GenMaybeEntry.None)
        (ResultGenDecl.Ok
          (gen-single-decl-list
            (ast-decl-comptime-decl-with-meta
              (AstGeneratedDeclMeta.Some generator item args key)
              template))
          (gen-registry-insert registry key template)
          module)]
      [(GenMaybeEntry.Some existing)
        (if (gen-decl-eq? existing template)
          (ResultGenDecl.Ok (ast-decl-list-new) registry module)
          (ResultGenDecl.Err (box (gen-incompatible-diag item key))))])))

(define (gen-metadata-arg-key
  [meta-key : String]
  [args : AstExprList]
  [env : CtfeEnv]) : ResultGenKey
  (if (> (string.string-length meta-key) 0)
    (ResultGenKey.Ok meta-key (ctfe-fuel-limit))
    (gen-key-exprs args env (ctfe-fuel-limit))))

(define (gen-rewrite-decl
  [decl : AstDecl]
  [module : String]
  [registry : GenRegistry]
  [env : CtfeEnv]) : ResultGenDecl
  (match decl
    [(AstDecl.Module name)
      (ResultGenDecl.Ok (gen-single-decl-list decl) registry (intern-str name))]
    [(AstDecl.ComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (match meta
          [(AstGeneratedDeclMeta.No)
            (ResultGenDecl.Ok (gen-single-decl-list decl) registry module)]
          [(AstGeneratedDeclMeta.Some generator item args meta-key)
            (if (not (gen-metadata-key-normalizable? meta-key))
              (ResultGenDecl.Ok (gen-single-decl-list decl) registry module)
              (match (gen-decl-visible-name template)
                [(SpecMaybeString.None)
                  (ResultGenDecl.Err
                    (box
                      (compiler-diagnostic-at-start
                        ""
                        "generated-decl: generated payload must declare a visible item")))]
                [(SpecMaybeString.Some actual)
                  (if (not (string.eq item actual))
                    (ResultGenDecl.Err
                      (box (gen-item-mismatch-diag item actual)))
                    (match (gen-metadata-arg-key meta-key args env)
                      [(ResultGenKey.Ok arg-key _)
                        (gen-register-generated-decl
                          template
                          module
                          generator
                          item
                          args
                          arg-key
                          registry)]
                      [(ResultGenKey.Err diag) (ResultGenDecl.Err diag)]))]))]))]
    [_ (ResultGenDecl.Ok (gen-single-decl-list decl) registry module)]))

(define (gen-rewrite-decls
  [decls : AstDeclList]
  [module : String]
  [registry : GenRegistry]
  [env : CtfeEnv]) : ResultGenDecls
  (let
    [count : i64 (ast-decl-list-len (& decls))]
    [cursor : AstDeclList decls]
    [out : AstDeclList (ast-decl-list-with-capacity count)]
    [cur-registry : GenRegistry registry]
    [cur-module : String module]
    [result : ResultGenDecls
      (ResultGenDecls.Err
        (box
          (compiler-diagnostic-simple
            "<internal>"
            1
            1
            "generated-decl normalization did not finish")))]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast-decl-list-step cursor)
          [(AstDeclListStep.Nil)
            (begin
              (set! result (ResultGenDecls.Ok out cur-registry cur-module))
              (set! done true))]
          [(AstDeclListStep.Cons decl rest)
            (match (gen-rewrite-decl decl cur-module cur-registry env)
              [(ResultGenDecl.Ok rewritten-decls decl-registry decl-module)
                (begin
                  (ast-decl-list-append-from (&mut out) (& rewritten-decls) 0)
                  (set! cur-registry decl-registry)
                  (set! cur-module decl-module)
                  (set! cursor rest))]
              [(ResultGenDecl.Err diag)
                (begin
                  (set! result (ResultGenDecls.Err diag))
                  (set! done true))])]))
      result)))

(define (gen-path-list-head-or [paths : AstDeclPathList] [fallback : String]) : String
  (match (ast-decl-path-list-step paths)
    [(AstDeclPathListStep.Cons path _) path]
    [(AstDeclPathListStep.Nil) fallback]))

(define (gen-path-list-tail [paths : AstDeclPathList]) : AstDeclPathList
  (match (ast-decl-path-list-step paths)
    [(AstDeclPathListStep.Cons _ rest-box)
      (let
        [rest : AstDeclPathList rest-box]
        rest)]
    [(AstDeclPathListStep.Nil) (ast-decl-path-list-new)]))

(define (gen-path-list-for-decls
  [decls : AstDeclList]
  [path : String]
  [rest-paths : AstDeclPathList]) : AstDeclPathList
  (let
    [out : AstDeclPathList
      (ast-decl-path-list-with-capacity
        (+
          (ast-decl-list-len (& decls))
          (ast-decl-path-list-len (& rest-paths))))]
    [index : i64 0]
    [count : i64 (ast-decl-list-len (& decls))]
    (begin
      (while (< index count)
        (begin
          (ast-decl-path-list-push (&mut out) path)
          (set! index (+ index 1))))
      (ast-decl-path-list-append-from (&mut out) (& rest-paths) 0)
      out)))

(define (gen-path-list-push-for-decls
  [out : (&mut out AstDeclPathList)]
  [decls : AstDeclList]
  [path : String]
  [index : i64]) : unit
  (if (>= index (ast-decl-list-len (& decls)))
    unit
    (begin
      (ast-decl-path-list-push out path)
      (gen-path-list-push-for-decls out decls path (+ index 1)))))

(define (gen-rewrite-decls-with-paths
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [fallback-path : String]
  [module : String]
  [registry : GenRegistry]
  [env : CtfeEnv]) : ResultGenDeclsWithPaths
  (let
    [count : i64 (ast-decl-list-len (& decls))]
    [decl-cursor : AstDeclList decls]
    [path-cursor : AstDeclPathList paths]
    [out : AstDeclList (ast-decl-list-with-capacity count)]
    [out-paths : AstDeclPathList (ast-decl-path-list-with-capacity count)]
    [cur-registry : GenRegistry registry]
    [cur-module : String module]
    [result : ResultGenDeclsWithPaths
      (ResultGenDeclsWithPaths.Err
        (box
          (compiler-diagnostic-simple
            "<internal>"
            1
            1
            "generated-decl normalization with paths did not finish")))]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast-decl-list-step decl-cursor)
          [(AstDeclListStep.Nil)
            (begin
              (set!
                result
                (ResultGenDeclsWithPaths.Ok
                  out
                  out-paths
                  cur-registry
                  cur-module))
              (set! done true))]
          [(AstDeclListStep.Cons decl rest)
            (let
              [decl-path : String
                (gen-path-list-head-or path-cursor fallback-path)]
              (match (gen-rewrite-decl decl cur-module cur-registry env)
                [(ResultGenDecl.Ok rewritten-decls decl-registry decl-module)
                  (begin
                    (ast-decl-list-append-from (&mut out) (& rewritten-decls) 0)
                    (gen-path-list-push-for-decls
                      (&mut out-paths)
                      rewritten-decls
                      decl-path
                      0)
                    (set! cur-registry decl-registry)
                    (set! cur-module decl-module)
                    (set! decl-cursor rest)
                    (set! path-cursor (gen-path-list-tail path-cursor)))]
                [(ResultGenDecl.Err diag)
                  (begin
                    (set! result (ResultGenDeclsWithPaths.Err diag))
                    (set! done true))]))]))
      result)))

(define (gen-normalize-program-active [program : AstProgram]) : ResultGenProgram
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [env : CtfeEnv
          (ctfe-env-with-reflections (ctfe-reflections-from-program program))]
        (match (gen-rewrite-decls decls "" (gen-registry-empty) env)
          [(ResultGenDecls.Ok rewritten _ _)
            (ResultGenProgram.Ok (ast-program rewritten))]
          [(ResultGenDecls.Err diag) (ResultGenProgram.Err diag)]))]))

(define (gen-normalize-program-with-paths-active
  [program : AstProgram]
  [paths : AstDeclPathList]
  [fallback-path : String]) : ResultGenProgramWithPaths
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [env : CtfeEnv
          (ctfe-env-with-reflections (ctfe-reflections-from-program program))]
        (match (gen-rewrite-decls-with-paths
          decls
          paths
          fallback-path
          ""
          (gen-registry-empty)
          env)
          [(ResultGenDeclsWithPaths.Ok rewritten rewritten-paths _ _)
            (ResultGenProgramWithPaths.Ok
              (ast-program rewritten)
              rewritten-paths)]
          [(ResultGenDeclsWithPaths.Err diag)
            (ResultGenProgramWithPaths.Err diag)]))]))

(define (gen-normalize-program-with-pools
  [program : AstProgram]
  [pools : AstNodePoolContext]) : ResultGenProgram
  (let
    [prev : AstNodePoolContext (ast-node-pool-context-capture-active)]
    (begin
      (ast-node-pool-context-install! pools)
      (let
        [result : ResultGenProgram (gen-normalize-program-active program)]
        (begin
          (ast-node-pool-context-capture-active! pools)
          (ast-node-pool-context-install! prev)
          result)))))

(define (gen-normalize-program-with-paths-and-pools
  [program : AstProgram]
  [paths : AstDeclPathList]
  [fallback-path : String]
  [pools : AstNodePoolContext]) : ResultGenProgramWithPaths
  (let
    [prev : AstNodePoolContext (ast-node-pool-context-capture-active)]
    (begin
      (ast-node-pool-context-install! pools)
      (let
        [result : ResultGenProgramWithPaths
          (gen-normalize-program-with-paths-active program paths fallback-path)]
        (begin
          (ast-node-pool-context-capture-active! pools)
          (ast-node-pool-context-install! prev)
          result)))))

(define (gen-normalize-program [program : AstProgram]) : ResultGenProgram
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultGenProgram (gen-normalize-program-with-pools program pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (gen-normalize-program-with-paths
  [program : AstProgram]
  [paths : AstDeclPathList]
  [fallback-path : String]) : ResultGenProgramWithPaths
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultGenProgramWithPaths
      (gen-normalize-program-with-paths-and-pools
        program
        paths
        fallback-path
        pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (gen-decl-needs-normalize? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Unsafe inner-box) (gen-decl-needs-normalize? (box-get inner-box))]
    [(AstDecl.ComptimeDecl meta template-box)
      (match meta
        [(AstGeneratedDeclMeta.Some _ _ _ key)
          (gen-metadata-key-normalizable? key)]
        [(AstGeneratedDeclMeta.No)
          (gen-decl-needs-normalize? (box-get template-box))])]
    [_ false]))

(define (gen-decls-needed? [decls : AstDeclList]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) false]
    [(AstDeclListStep.Cons decl rest)
      (if (gen-decl-needs-normalize? decl)
        true
        (gen-decls-needed? rest))]))

(define (spec-value-runtime-type-matches?
  [value : CompilerCtfeValue]
  [ty : AstType]) : bool
  (begin
    (cbi.compiler-builtin-refresh!)
    (match value
    [(CompilerCtfeValue.I64 _) (ctfe-type-eq ty (AstType.I64))]
    [(CompilerCtfeValue.F64 _) (ctfe-type-eq ty (AstType.F64))]
    [(CompilerCtfeValue.F32 _) (ctfe-type-eq ty (AstType.F32))]
    [(CompilerCtfeValue.Bool _) (ctfe-type-eq ty (AstType.Bool))]
    [(CompilerCtfeValue.Char _) (ctfe-type-eq ty (AstType.Char))]
    [(CompilerCtfeValue.String _) (ctfe-type-eq ty (AstType.String))]
    [(CompilerCtfeValue.Unit) (ctfe-type-eq ty (AstType.Unit))]
    [(CompilerCtfeValue.Type _) false]
    [(CompilerCtfeValue.Expr _ _) (ctfe-type-eq ty (AstType.Expr))]
    [(CompilerCtfeValue.ExprList _) (ctfe-type-eq ty (AstType.ExprList))]
    [(CompilerCtfeValue.ExprClause _)
      (ctfe-type-eq ty (AstType.Var cbi.compiler-builtin-id-fix-ExprClause))]
    [(CompilerCtfeValue.ExprClauseList _)
      (ctfe-type-eq ty (AstType.Var cbi.compiler-builtin-id-fix-ExprClauseList))]
    [(CompilerCtfeValue.ExprBindingClause _)
      (ctfe-type-eq ty (AstType.Var cbi.compiler-builtin-id-fix-ExprBindingClause))]
    [(CompilerCtfeValue.ExprBindingClauseList _)
      (ctfe-type-eq ty (AstType.Var cbi.compiler-builtin-id-fix-ExprBindingClauseList))]
    [(CompilerCtfeValue.Pattern _)
      (ctfe-type-eq ty (AstType.Var cbi.compiler-builtin-id-fix-Pattern))]
    [(CompilerCtfeValue.PatternList _)
      (ctfe-type-eq ty (AstType.Var cbi.compiler-builtin-id-fix-PatternList))]
    [(CompilerCtfeValue.MatchArm _)
      (ctfe-type-eq ty (AstType.Var cbi.compiler-builtin-id-fix-MatchArm))]
    [(CompilerCtfeValue.MatchArmList _)
      (ctfe-type-eq ty (AstType.Var cbi.compiler-builtin-id-fix-MatchArmList))]
    [(CompilerCtfeValue.TypeInfo _) false]
    [(CompilerCtfeValue.TypeInfoBox _) false]
    [(CompilerCtfeValue.TypeInfoList _) false]
    [(CompilerCtfeValue.TypeField _ _) false]
    [(CompilerCtfeValue.TypeFieldList _) false]
    [(CompilerCtfeValue.TypeVariantPayload _) false]
    [(CompilerCtfeValue.TypeVariantPayloadList _) false]
    [(CompilerCtfeValue.TypeVariant _ _) false]
    [(CompilerCtfeValue.TypeVariantList _) false])))

(define (spec-value-type-label [value : CompilerCtfeValue]) : String
  (match value
    [(CompilerCtfeValue.I64 _) "i64"]
    [(CompilerCtfeValue.F64 _) "f64"]
    [(CompilerCtfeValue.F32 _) "f32"]
    [(CompilerCtfeValue.Bool _) "bool"]
    [(CompilerCtfeValue.Char _) "char"]
    [(CompilerCtfeValue.String _) "String"]
    [(CompilerCtfeValue.Unit) "unit"]
    [(CompilerCtfeValue.Type _) "type"]
    [(CompilerCtfeValue.Expr _ _) "Expr"]
    [(CompilerCtfeValue.ExprList _) "expr-list"]
    [(CompilerCtfeValue.ExprClause _) "ExprClause"]
    [(CompilerCtfeValue.ExprClauseList _) "ExprClauseList"]
    [(CompilerCtfeValue.ExprBindingClause _) "ExprBindingClause"]
    [(CompilerCtfeValue.ExprBindingClauseList _) "ExprBindingClauseList"]
    [(CompilerCtfeValue.Pattern _) "Pattern"]
    [(CompilerCtfeValue.PatternList _) "PatternList"]
    [(CompilerCtfeValue.MatchArm _) "MatchArm"]
    [(CompilerCtfeValue.MatchArmList _) "MatchArmList"]
    [(CompilerCtfeValue.TypeInfo _) "TypeInfo"]
    [(CompilerCtfeValue.TypeInfoBox _) "TypeInfoBox"]
    [(CompilerCtfeValue.TypeInfoList _) "TypeInfoList"]
    [(CompilerCtfeValue.TypeField _ _) "TypeField"]
    [(CompilerCtfeValue.TypeFieldList _) "TypeFieldList"]
    [(CompilerCtfeValue.TypeVariantPayload _) "TypeVariantPayload"]
    [(CompilerCtfeValue.TypeVariantPayloadList _) "TypeVariantPayloadList"]
    [(CompilerCtfeValue.TypeVariant _ _) "TypeVariant"]
    [(CompilerCtfeValue.TypeVariantList _) "TypeVariantList"]))

(define (spec-type-subst-lookup [subs : SpecTypeSubst] [name : String]) : SpecMaybeString
  (match subs
    [(SpecTypeSubst.Nil) (SpecMaybeString.None)]
    [(SpecTypeSubst.Cons key _ rest)
      (if (string.eq key name)
        (SpecMaybeString.Some key)
        (spec-type-subst-lookup (box-get rest) name))]))

(define (spec-type-subst-type [subs : SpecTypeSubst] [name : String]) : AstType
  (match subs
    [(SpecTypeSubst.Nil) (AstType.Var (intern name))]
    [(SpecTypeSubst.Cons key ty rest)
      (if (string.eq key name)
        ty
        (spec-type-subst-type (box-get rest) name))]))

(define (spec-value-subst-lookup [subs : SpecValueSubst] [name : String]) : SpecMaybeString
  (match subs
    [(SpecValueSubst.Nil) (SpecMaybeString.None)]
    [(SpecValueSubst.Cons key _ rest)
      (if (string.eq key name)
        (SpecMaybeString.Some key)
        (spec-value-subst-lookup (box-get rest) name))]))

(define (spec-value-subst-value [subs : SpecValueSubst] [name : String]) : CompilerCtfeValue
  (match subs
    [(SpecValueSubst.Nil) (CompilerCtfeValue.Unit)]
    [(SpecValueSubst.Cons key value rest)
      (if (string.eq key name)
        value
        (spec-value-subst-value (box-get rest) name))]))

(define (spec-value-subst-remove-name [subs : SpecValueSubst] [name : String]) : SpecValueSubst
  (match subs
    [(SpecValueSubst.Nil) SpecValueSubst.Nil]
    [(SpecValueSubst.Cons key value rest)
      (if (string.eq key name)
        (spec-value-subst-remove-name (box-get rest) name)
        (spec-value-subst-cons
          key
          value
          (spec-value-subst-remove-name (box-get rest) name)))]))

(define (spec-value-subst-remove-params
  [subs : SpecValueSubst]
  [params : AstParamList]) : SpecValueSubst
  (spec-value-subst-remove-params-at subs (& params) 0))

(define (spec-value-subst-remove-params-at
  [subs : SpecValueSubst]
  [params : (& params AstParamList)]
  [index : i64]) : SpecValueSubst
  (if (>= index (ast-param-list-len params))
    subs
    (spec-value-subst-remove-params-at
      (spec-value-subst-remove-name
        subs
        (spec-param-name (ast-param-list-get params index (ast-param-fallback))))
      params
      (+ index 1))))

(define (spec-value-subst-remove-let-binding-names
  [subs : SpecValueSubst]
  [bindings : AstLetBindingList]) : SpecValueSubst
  (spec-value-subst-remove-let-binding-names-at subs (& bindings) 0))

(define (spec-value-subst-remove-let-binding-names-at
  [subs : SpecValueSubst]
  [bindings : (& bindings AstLetBindingList)]
  [index : i64]) : SpecValueSubst
  (if (>= index (ast-let-binding-list-len bindings))
    subs
    (match (ast-let-binding-list-get bindings index (ast-let-binding-fallback))
      [(AstLetBinding.Binding name _ _)
        (spec-value-subst-remove-let-binding-names-at
          (spec-value-subst-remove-name subs (intern-str name))
          bindings
          (+ index 1))])))

(define (spec-value-subst-remove-pattern
  [subs : SpecValueSubst]
  [pattern : AstPattern]) : SpecValueSubst
  (match pattern
    [(AstPattern.Var name _)
      (spec-value-subst-remove-name subs (intern-str name))]
    [(AstPattern.Tuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-value-subst-remove-pattern-list subs patterns))]
    [(AstPattern.Wildcard) subs]
    [(AstPattern.Binding name)
      (spec-value-subst-remove-name subs (intern-str name))]
    [(AstPattern.Variant _ patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-value-subst-remove-pattern-list subs patterns))]
    [(AstPattern.Literal _) subs]))

(define (spec-value-subst-remove-pattern-list
  [subs : SpecValueSubst]
  [patterns : AstPatternList]) : SpecValueSubst
  (spec-value-subst-remove-pattern-list-at subs (& patterns) 0))

(define (spec-value-subst-remove-pattern-list-at
  [subs : SpecValueSubst]
  [patterns : (& patterns AstPatternList)]
  [index : i64]) : SpecValueSubst
  (if (>= index (struct-get patterns len))
    subs
    (spec-value-subst-remove-pattern-list-at
      (spec-value-subst-remove-pattern
        subs
        (ast-pattern-list-get patterns index (ast-pattern-fallback)))
      patterns
      (+ index 1))))

(define (spec-type-subst-remove-name [subs : SpecTypeSubst] [name : String]) : SpecTypeSubst
  (match subs
    [(SpecTypeSubst.Nil) SpecTypeSubst.Nil]
    [(SpecTypeSubst.Cons key ty rest)
      (if (string.eq key name)
        (spec-type-subst-remove-name (box-get rest) name)
        (spec-type-subst-cons
          key
          ty
          (spec-type-subst-remove-name (box-get rest) name)))]))

(define (spec-type-subst-remove-params
  [subs : SpecTypeSubst]
  [params : AstParamList]) : SpecTypeSubst
  (spec-type-subst-remove-params-at subs (& params) 0))

(define (spec-type-subst-remove-params-at
  [subs : SpecTypeSubst]
  [params : (& params AstParamList)]
  [index : i64]) : SpecTypeSubst
  (if (>= index (ast-param-list-len params))
    subs
    (spec-type-subst-remove-params-at
      (spec-type-subst-remove-name
        subs
        (spec-param-name (ast-param-list-get params index (ast-param-fallback))))
      params
      (+ index 1))))

(define (spec-type-subst-remove-let-binding-names
  [subs : SpecTypeSubst]
  [bindings : AstLetBindingList]) : SpecTypeSubst
  (spec-type-subst-remove-let-binding-names-at subs (& bindings) 0))

(define (spec-type-subst-remove-let-binding-names-at
  [subs : SpecTypeSubst]
  [bindings : (& bindings AstLetBindingList)]
  [index : i64]) : SpecTypeSubst
  (if (>= index (ast-let-binding-list-len bindings))
    subs
    (match (ast-let-binding-list-get bindings index (ast-let-binding-fallback))
      [(AstLetBinding.Binding name _ _)
        (spec-type-subst-remove-let-binding-names-at
          (spec-type-subst-remove-name subs (intern-str name))
          bindings
          (+ index 1))])))

(define (spec-type-subst-remove-pattern
  [subs : SpecTypeSubst]
  [pattern : AstPattern]) : SpecTypeSubst
  (match pattern
    [(AstPattern.Var name _)
      (spec-type-subst-remove-name subs (intern-str name))]
    [(AstPattern.Tuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-type-subst-remove-pattern-list subs patterns))]
    [(AstPattern.Wildcard) subs]
    [(AstPattern.Binding name)
      (spec-type-subst-remove-name subs (intern-str name))]
    [(AstPattern.Variant _ patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-type-subst-remove-pattern-list subs patterns))]
    [(AstPattern.Literal _) subs]))

(define (spec-type-subst-remove-pattern-list
  [subs : SpecTypeSubst]
  [patterns : AstPatternList]) : SpecTypeSubst
  (spec-type-subst-remove-pattern-list-at subs (& patterns) 0))

(define (spec-type-subst-remove-pattern-list-at
  [subs : SpecTypeSubst]
  [patterns : (& patterns AstPatternList)]
  [index : i64]) : SpecTypeSubst
  (if (>= index (struct-get patterns len))
    subs
    (spec-type-subst-remove-pattern-list-at
      (spec-type-subst-remove-pattern
        subs
        (ast-pattern-list-get patterns index (ast-pattern-fallback)))
      patterns
      (+ index 1))))

(define (spec-substitute-type [ty : AstType] [subs : SpecTypeSubst]) : AstType
  (match ty
    [(AstType.Func args ret)
      (ast-ty-func
        (spec-substitute-type-list (box-get args) subs)
        (spec-substitute-type (ty-node-get ret) subs))]
    [(AstType.Tuple elems)
      (ast-ty-tuple (spec-substitute-type-list (box-get elems) subs))]
    [(AstType.Array elem count)
      (ast-ty-array (spec-substitute-type (ty-node-get elem) subs) count)]
    [(AstType.DynArray elem)
      (ast-ty-dyn-array (spec-substitute-type (ty-node-get elem) subs))]
    [(AstType.Box elem)
      (ast-ty-box (spec-substitute-type (ty-node-get elem) subs))]
    [(AstType.Ptr elem)
      (ast-ty-ptr (spec-substitute-type (ty-node-get elem) subs))]
    [(AstType.MutPtr elem)
      (ast-ty-mut-ptr (spec-substitute-type (ty-node-get elem) subs))]
    [(AstType.Ref region inner)
      (ast-ty-ref region (spec-substitute-type (ty-node-get inner) subs))]
    [(AstType.MutRef region inner)
      (ast-ty-mut-ref region (spec-substitute-type (ty-node-get inner) subs))]
    [(AstType.Region region inner)
      (ast-ty-region region (spec-substitute-type (ty-node-get inner) subs))]
    [(AstType.EnumArgs name lifetimes)
      (ast-ty-enum-args name (box-get lifetimes))]
    [(AstType.StructArgs name lifetimes)
      (ast-ty-struct-args name (box-get lifetimes))]
    [(AstType.VarArgs name lifetimes)
      (match (spec-type-subst-lookup subs (intern-str name))
        [(SpecMaybeString.Some _) (spec-type-subst-type subs (intern-str name))]
        [(SpecMaybeString.None) (ast-ty-var-args name (box-get lifetimes))])]
    [(AstType.Var name)
      (match (spec-type-subst-lookup subs (intern-str name))
        [(SpecMaybeString.Some _) (spec-type-subst-type subs (intern-str name))]
        [(SpecMaybeString.None) ty])]
    [_ ty]))

(define (spec-substitute-type-list-into
  [types : (& types AstTypeList)]
  [subs : SpecTypeSubst]
  [out : (&mut out AstTypeList)]
  [index : i64]) : unit
  (if (>= index (ast-type-list-len types))
    unit
    (begin
      (ast-type-list-push
        out
        (ast-node-pool-reader-type-push
          (spec-substitute-type
            (ty-node-get (ast-type-list-get types index (ast-type-id-fallback)))
            subs)))
      (spec-substitute-type-list-into types subs out (+ index 1)))))

(define (spec-substitute-type-list [types : AstTypeList] [subs : SpecTypeSubst]) : AstTypeList
  (let
    [out : AstTypeList
      (ast-type-list-with-capacity (ast-type-list-len (& types)))]
    (begin
      (spec-substitute-type-list-into (& types) subs (&mut out) 0)
      out)))

(define (spec-substitute-maybe-type [ty : AstMaybeType] [subs : SpecTypeSubst]) : AstMaybeType
  (match ty
    [(AstMaybeType.No) AstMaybeType.No]
    [(AstMaybeType.Some inner)
      (AstMaybeType.Some (spec-substitute-type inner subs))]))

(define (spec-substitute-param-types
  [params : AstParamList]
  [subs : SpecTypeSubst]) : AstParamList
  (let
    [out : AstParamList
      (ast-param-list-with-capacity (ast-param-list-len (& params)))]
    (begin
      (spec-substitute-param-types-into (& params) subs 0 (&mut out))
      out)))

(define (spec-substitute-param-types-into
  [params : (& params AstParamList)]
  [subs : SpecTypeSubst]
  [index : i64]
  [out : (&mut out AstParamList)]) : unit
  (if (>= index (ast-param-list-len params))
    unit
    (begin
      (match (ast-param-list-get params index (ast-param-fallback))
        [(AstParam.Param name ty _)
          (ast-param-list-push
            out
            (AstParam.Param name (spec-substitute-type ty subs) false))])
      (spec-substitute-param-types-into params subs (+ index 1) out))))

(define (spec-ctfe-value-to-expr [value : CompilerCtfeValue] [origin : AstExpr]) : ResultSpecSubExpr
  (match value
    [(CompilerCtfeValue.I64 n)
      (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.Literal (ast-lit-int n))))]
    [(CompilerCtfeValue.F64 n)
      (ResultSpecSubExpr.Ok
        (ast-node-push
          (AstExpr.Literal (AstLiteral.Float (compiler-float-format-f64 n)))))]
    [(CompilerCtfeValue.F32 n)
      (ResultSpecSubExpr.Ok
        (ast-expr-ann
          (ast-node-push
            (AstExpr.Literal
              (AstLiteral.Float
                (compiler-float-format-f64 (compiler-float-round-f32-as-f64 n)))))
          (AstType.F32)))]
    [(CompilerCtfeValue.Bool b)
      (ResultSpecSubExpr.Ok
        (ast-node-push (AstExpr.Literal (AstLiteral.Bool b))))]
    [(CompilerCtfeValue.Char c)
      (ResultSpecSubExpr.Ok
        (ast-node-push (AstExpr.Literal (AstLiteral.Char c))))]
    [(CompilerCtfeValue.String _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time String value into runtime expression")))]
    [(CompilerCtfeValue.Unit)
      (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.Literal (AstLiteral.Unit))))]
    [(CompilerCtfeValue.Type ty)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            (string.append
              "cannot substitute compile-time type value "
              (string.append (spec-type-key ty) " into runtime expression")))))]
    [(CompilerCtfeValue.Expr _ _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time Expr value into runtime expression")))]
    [(CompilerCtfeValue.ExprList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprList value into runtime expression")))]
    [(CompilerCtfeValue.ExprClause _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprClause value into runtime expression")))]
    [(CompilerCtfeValue.ExprClauseList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprClauseList value into runtime expression")))]
    [(CompilerCtfeValue.ExprBindingClause _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprBindingClause value into runtime expression")))]
    [(CompilerCtfeValue.ExprBindingClauseList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprBindingClauseList value into runtime expression")))]
    [(CompilerCtfeValue.Pattern _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time Pattern value into runtime expression")))]
    [(CompilerCtfeValue.PatternList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time PatternList value into runtime expression")))]
    [(CompilerCtfeValue.MatchArm _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time MatchArm value into runtime expression")))]
    [(CompilerCtfeValue.MatchArmList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time MatchArmList value into runtime expression")))]
    [(CompilerCtfeValue.TypeInfo _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeInfo value into runtime expression")))]
    [(CompilerCtfeValue.TypeInfoBox _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeInfo box value into runtime expression")))]
    [(CompilerCtfeValue.TypeInfoList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeInfoList value into runtime expression")))]
    [(CompilerCtfeValue.TypeField _ _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeField value into runtime expression")))]
    [(CompilerCtfeValue.TypeFieldList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeFieldList value into runtime expression")))]
    [(CompilerCtfeValue.TypeVariantPayload _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariantPayload value into runtime expression")))]
    [(CompilerCtfeValue.TypeVariantPayloadList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariantPayloadList value into runtime expression")))]
    [(CompilerCtfeValue.TypeVariant _ _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariant value into runtime expression")))]
    [(CompilerCtfeValue.TypeVariantList _)
      (ResultSpecSubExpr.Err
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariantList value into runtime expression")))]))

(define (spec-expr-var-name [expr : AstExpr]) : SpecMaybeString
  (match (ast-expr-unspan expr)
    [(AstExpr.Var name) (SpecMaybeString.Some (intern-str name))]
    [_ (SpecMaybeString.None)]))

(define (spec-rewrite-expr-list
  [exprs : AstExprList]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecExprList
  (let
    [out : AstExprList (ast-expr-list-with-capacity (struct-get (& exprs) len))]
    (match (spec-rewrite-expr-list-at (& exprs) 0 templates state (&mut out))
      [(ResultSpecExprListBuild.Ok next-state)
        (ResultSpecExprList.Ok out next-state)]
      [(ResultSpecExprListBuild.Err diag) (ResultSpecExprList.Err diag)])))

(define (spec-rewrite-expr-list-at
  [exprs : (& exprs AstExprList)]
  [index : i64]
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [out : (&mut out AstExprList)]) : ResultSpecExprListBuild
  (if (>= index (struct-get exprs len))
    (ResultSpecExprListBuild.Ok state)
    (let
      [head : AstExpr (ast-node-get (ast-expr-list-get exprs index 0))]
      (match (spec-rewrite-expr head templates state)
        [(ResultSpecExpr.Ok rewritten-head head-state)
          (begin
            (ast-expr-list-push out rewritten-head)
            (spec-rewrite-expr-list-at
              exprs
              (+ index 1)
              templates
              head-state
              out))]
        [(ResultSpecExpr.Err diag) (ResultSpecExprListBuild.Err diag)]))))

(define (spec-rewrite-let-bindings
  [bindings : AstLetBindingList]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecLetBindingList
  (let
    [out : AstLetBindingList
      (ast-let-binding-list-with-capacity
        (ast-let-binding-list-len (& bindings)))]
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
  [bindings : (& bindings AstLetBindingList)]
  [index : i64]
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [out : (&mut out AstLetBindingList)]) : ResultSpecLetBindingListBuild
  (if (>= index (ast-let-binding-list-len bindings))
    (ResultSpecLetBindingListBuild.Ok state)
    (match (ast-let-binding-list-get bindings index (ast-let-binding-fallback))
      [(AstLetBinding.Binding name ty value-box)
        (let
          [value : AstExpr (ast-node-get value-box)]
          (match (spec-rewrite-expr value templates state)
            [(ResultSpecExpr.Ok rewritten-value value-state)
              (begin
                (ast-let-binding-list-push
                  out
                  (ast-let-binding-id name ty rewritten-value))
                (spec-rewrite-let-bindings-at
                  bindings
                  (+ index 1)
                  (spec-template-env-shadow-name templates (intern-str name))
                  value-state
                  out))]
            [(ResultSpecExpr.Err diag) (ResultSpecLetBindingListBuild.Err diag)]))])))

(define (spec-rewrite-match-arms
  [arms : AstMatchArmList]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecMatchArmList
  (let
    [out : AstMatchArmList
      (ast-match-arm-list-with-capacity (struct-get (& arms) len))]
    (match (spec-rewrite-match-arms-at (& arms) 0 templates state (&mut out))
      [(ResultSpecMatchArmListBuild.Ok next-state)
        (ResultSpecMatchArmList.Ok out next-state)]
      [(ResultSpecMatchArmListBuild.Err diag) (ResultSpecMatchArmList.Err diag)])))

(define (spec-rewrite-match-arms-at
  [arms : (& arms AstMatchArmList)]
  [index : i64]
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [out : (&mut out AstMatchArmList)]) : ResultSpecMatchArmListBuild
  (if (>= index (struct-get arms len))
    (ResultSpecMatchArmListBuild.Ok state)
    (match (ast-match-arm-list-get arms index (ast-match-arm-fallback))
      [(AstMatchArm.Arm pattern body-box)
        (let
          [body : AstExpr (ast-node-get body-box)]
          (match (spec-rewrite-expr
            body
            (spec-template-env-shadow-pattern templates pattern)
            state)
            [(ResultSpecExpr.Ok rewritten-body body-state)
              (begin
                (ast-match-arm-list-push
                  out
                  (ast-match-arm pattern rewritten-body))
                (spec-rewrite-match-arms-at
                  arms
                  (+ index 1)
                  templates
                  body-state
                  out))]
            [(ResultSpecExpr.Err diag) (ResultSpecMatchArmListBuild.Err diag)]))])))

(define (spec-rewrite-specialized-call
  [template : SpecTemplate]
  [args : AstExprList]
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [origin : AstExpr]) : ResultSpecExpr
  (match template
    [(SpecTemplate.Item name params _ _)
      (match (spec-rewrite-specialized-args params args templates state name)
        [(ResultSpecArgs.Ok values runtime-args args-state)
          (match (spec-ensure-specialization
            template
            values
            templates
            args-state
            origin)
            [(ResultSpecEnsure.Ok specialized-name ensure-state)
              (ResultSpecExpr.Ok
                (ast-expr-call
                  (ast-node-push (AstExpr.Var (intern specialized-name)))
                  runtime-args)
                ensure-state)]
            [(ResultSpecEnsure.Err diag) (ResultSpecExpr.Err diag)])]
        [(ResultSpecArgs.Err diag) (ResultSpecExpr.Err diag)])]))

(define (spec-rewrite-specialized-args
  [params : AstParamList]
  [args : AstExprList]
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
  [params : (& params AstParamList)]
  [args : (& args AstExprList)]
  [index : i64]
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [fn-name : String]) : ResultSpecArgs
  (cond
    [(>= index (ast-param-list-len params))
      (if (>= index (struct-get args len))
        (ResultSpecArgs.Ok SpecValueList.Nil (ast-expr-list-new) state)
        (ResultSpecArgs.Err
          (box (compiler-diagnostic-at-start "" "specialize: arity mismatch"))))]
    [(>= index (struct-get args len))
      (ResultSpecArgs.Err
        (box (compiler-diagnostic-at-start "" "specialize: arity mismatch")))]
    [else
      (let
        [arg : AstExpr (ast-node-get (ast-expr-list-get args index 0))]
        (match (ast-param-list-get params index (ast-param-fallback))
          [(AstParam.Param param-name param-ty is-comptime)
            (if is-comptime
              (match (spec-ctfe-eval state arg (ctfe-fuel-limit))
                [(ResultCtfe.Ok value _)
                  (if (spec-type-kind? param-ty)
                    (match value
                      [(CompilerCtfeValue.Type _)
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
                              (string.append
                                "comptime argument '"
                                (string.append
                                  (intern-str param-name)
                                  (string.append
                                    "' for function '"
                                    (string.append
                                      fn-name
                                      "' must be a type value such as `(type i64)`")))))))])
                    (if (spec-value-runtime-type-matches? value param-ty)
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
                            (string.append
                              "comptime argument '"
                              (string.append
                                (intern-str param-name)
                                (string.append
                                  "' for function '"
                                  (string.append
                                    fn-name
                                    (string.append
                                      "' has type "
                                      (string.append
                                        (spec-value-type-label value)
                                        (string.append
                                          ", expected "
                                          (spec-type-key param-ty)))))))))))))]
                [(ResultCtfe.Err diag) (ResultSpecArgs.Err diag)])
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
                        (ast-expr-cons rewritten-arg rest-runtime)
                        rest-state)]
                    [(ResultSpecArgs.Err diag) (ResultSpecArgs.Err diag)])]
                [(ResultSpecExpr.Err diag) (ResultSpecArgs.Err diag)]))]))]))

(define (spec-build-specialization
  [params : AstParamList]
  [values : SpecValueList]) : ResultSpecBuild
  (spec-build-specialization-at (& params) 0 values))

(define (spec-build-specialization-at
  [params : (& params AstParamList)]
  [index : i64]
  [values : SpecValueList]) : ResultSpecBuild
  (if (>= index (ast-param-list-len params))
    (match values
      [(SpecValueList.Nil)
        (ResultSpecBuild.Ok
          (ast-param-list-new)
          SpecValueSubst.Nil
          SpecTypeSubst.Nil)]
      [_
        (ResultSpecBuild.Err
          (box (compiler-diagnostic-at-start "" "specialize: value mismatch")))])
    (match (ast-param-list-get params index (ast-param-fallback))
      [(AstParam.Param name ty is-comptime)
        (if is-comptime
          (match values
            [(SpecValueList.Cons value rest-values)
              (match (spec-build-specialization-at
                params
                (+ index 1)
                (box-get rest-values))
                [(ResultSpecBuild.Ok runtime value-subs type-subs)
                  (if (spec-type-kind? ty)
                    (match value
                      [(CompilerCtfeValue.Type actual-ty)
                        (ResultSpecBuild.Ok
                          runtime
                          value-subs
                          (spec-type-subst-cons
                            (intern-str name)
                            actual-ty
                            type-subs))]
                      [_
                        (ResultSpecBuild.Err
                          (box
                            (compiler-diagnostic-at-start
                              ""
                              "specialize: expected type value")))])
                    (ResultSpecBuild.Ok
                      runtime
                      (spec-value-subst-cons (intern-str name) value value-subs)
                      type-subs))]
                [(ResultSpecBuild.Err diag) (ResultSpecBuild.Err diag)])]
            [_
              (ResultSpecBuild.Err
                (box
                  (compiler-diagnostic-at-start "" "specialize: value mismatch")))])
          (match (spec-build-specialization-at params (+ index 1) values)
            [(ResultSpecBuild.Ok runtime value-subs type-subs)
              (ResultSpecBuild.Ok
                (ast-param-cons (AstParam.Param name ty false) runtime)
                value-subs
                type-subs)]
            [(ResultSpecBuild.Err diag) (ResultSpecBuild.Err diag)]))])))

(define (spec-ensure-specialization
  [template : SpecTemplate]
  [values : SpecValueList]
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [_origin : AstExpr]) : ResultSpecEnsure
  (match template
    [(SpecTemplate.Item name params ret body)
      (match state
        [(SpecState.State generated cache ctfe-env pools)
          (let
            [key : String (spec-specialization-key name values)]
            (match (spec-cache-lookup cache key)
              [(SpecMaybeString.Some cached-name)
                (ResultSpecEnsure.Ok cached-name state)]
              [(SpecMaybeString.None)
                (let
                  [generated-name : String (spec-specialized-name name values)]
                  (match (spec-build-specialization params values)
                    [(ResultSpecBuild.Ok runtime-params value-subs type-subs)
                      (match (spec-substitute-types-expr body type-subs)
                        [(ResultSpecSubExpr.Ok typed-body)
                          (match (spec-substitute-values-expr
                            (ast-node-get typed-body)
                            value-subs)
                            [(ResultSpecSubExpr.Ok valued-body)
                              (let
                                [next-cache : spec_string_string_map.Map cache]
                                (begin
                                  (spec_string_string_map.insert
                                    (&mut next-cache)
                                    key
                                    generated-name)
                                  (let
                                    [cached-state : SpecState
                                      (SpecState.State
                                        generated
                                        next-cache
                                        ctfe-env
                                        pools)]
                                    (match (spec-rewrite-expr
                                      (ast-node-get valued-body)
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
                                              generated-name
                                              (SpecState.State
                                                (spec-decl-list-append-one
                                                  rewritten-generated
                                                  (ast-decl-def-fn
                                                    generated-name
                                                    (spec-substitute-param-types
                                                      runtime-params
                                                      type-subs)
                                                    (spec-substitute-type
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

(define (spec-rewrite-expr
  [expr : AstExpr]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecExpr
  (match expr
    [(AstExpr.Spanned inner-box span)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten rewritten-state)
            (ResultSpecExpr.Ok
              (ast-expr-spanned rewritten span)
              rewritten-state)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Literal _) (ResultSpecExpr.Ok (ast-node-push expr) state)]
    [(AstExpr.Var _) (ResultSpecExpr.Ok (ast-node-push expr) state)]
    [(AstExpr.TypeLiteral _) (ResultSpecExpr.Ok (ast-node-push expr) state)]
    [(AstExpr.Init _) (ResultSpecExpr.Ok (ast-node-push expr) state)]
    [(AstExpr.Binary op left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (match (spec-rewrite-expr left templates state)
          [(ResultSpecExpr.Ok rewritten-left left-state)
            (match (spec-rewrite-expr right templates left-state)
              [(ResultSpecExpr.Ok rewritten-right right-state)
                (ResultSpecExpr.Ok
                  (ast-expr-binary op rewritten-left rewritten-right)
                  right-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Unary op inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten rewritten-state)
            (ResultSpecExpr.Ok (ast-expr-unary op rewritten) rewritten-state)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Call func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (match (spec-expr-var-name func)
          [(SpecMaybeString.Some name)
            (match (spec-template-lookup templates name)
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
                          (ast-expr-call rewritten-func rewritten-args)
                          args-state)]
                      [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])])]
          [(SpecMaybeString.None)
            (match (spec-rewrite-expr func templates state)
              [(ResultSpecExpr.Ok rewritten-func func-state)
                (match (spec-rewrite-expr-list args templates func-state)
                  [(ResultSpecExprList.Ok rewritten-args args-state)
                    (ResultSpecExpr.Ok
                      (ast-expr-call rewritten-func rewritten-args)
                      args-state)]
                  [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]))]
    [(AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (match (spec-rewrite-expr cond templates state)
          [(ResultSpecExpr.Ok rewritten-cond cond-state)
            (match (spec-rewrite-expr then-branch templates cond-state)
              [(ResultSpecExpr.Ok rewritten-then then-state)
                (match (spec-rewrite-expr else-branch templates then-state)
                  [(ResultSpecExpr.Ok rewritten-else else-state)
                    (ResultSpecExpr.Ok
                      (ast-expr-if rewritten-cond rewritten-then rewritten-else)
                      else-state)]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
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
                      (ast-expr-let rewritten-bindings rewritten-body)
                      body-state)]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecLetBindingList.Err diag) (ResultSpecExpr.Err diag)]))])]
    [(AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda.Lambda params ret body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-rewrite-expr
              body
              (spec-template-env-shadow-params templates params)
              state)
              [(ResultSpecExpr.Ok rewritten-body body-state)
                (ResultSpecExpr.Ok
                  (ast-expr-lambda params ret rewritten-body)
                  body-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))])]
    [(AstExpr.Tuple exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok (ast-node-push (AstExpr.Tuple rewritten)) state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(AstExpr.TupleRef inner-box index)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-tuple-ref rewritten index) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Array exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok (ast-node-push (AstExpr.Array rewritten)) state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(AstExpr.DynArray exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok
            (ast-node-push (AstExpr.DynArray rewritten))
            state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(AstExpr.MakeArray elem-ty len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (match (spec-rewrite-expr len templates state)
          [(ResultSpecExpr.Ok rewritten-len state2)
            (ResultSpecExpr.Ok
              (ast-expr-make-array elem-ty rewritten-len)
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.ArrayRef array-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-rewrite-expr array templates state)
          [(ResultSpecExpr.Ok rewritten-array array-state)
            (match (spec-rewrite-expr index templates array-state)
              [(ResultSpecExpr.Ok rewritten-index index-state)
                (ResultSpecExpr.Ok
                  (ast-expr-array-ref rewritten-array rewritten-index)
                  index-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.ArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr array templates state)
          [(ResultSpecExpr.Ok rewritten-array array-state)
            (match (spec-rewrite-expr index templates array-state)
              [(ResultSpecExpr.Ok rewritten-index index-state)
                (match (spec-rewrite-expr value templates index-state)
                  [(ResultSpecExpr.Ok rewritten-value value-state)
                    (ResultSpecExpr.Ok
                      (ast-expr-array-set
                        rewritten-array
                        rewritten-index
                        rewritten-value)
                      value-state)]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.ArrayTake array-box live-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [live : AstExpr (ast-node-get live-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-rewrite-expr array templates state)
          [(ResultSpecExpr.Ok rewritten-array array-state)
            (match (spec-rewrite-expr live templates array-state)
              [(ResultSpecExpr.Ok rewritten-live live-state)
                (match (spec-rewrite-expr index templates live-state)
                  [(ResultSpecExpr.Ok rewritten-index index-state)
                    (ResultSpecExpr.Ok
                      (ast-expr-array-take
                        rewritten-array
                        rewritten-live
                        rewritten-index)
                      index-state)]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.ArrayPush array-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr array templates state)
          [(ResultSpecExpr.Ok rewritten-array array-state)
            (match (spec-rewrite-expr value templates array-state)
              [(ResultSpecExpr.Ok rewritten-value value-state)
                (ResultSpecExpr.Ok
                  (ast-expr-array-push rewritten-array rewritten-value)
                  value-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.StringRef text-box index-box)
      (let
        [text : AstExpr (ast-node-get text-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-rewrite-expr text templates state)
          [(ResultSpecExpr.Ok rewritten-text text-state)
            (match (spec-rewrite-expr index templates text-state)
              [(ResultSpecExpr.Ok rewritten-index index-state)
                (ResultSpecExpr.Ok
                  (ast-expr-string-ref rewritten-text rewritten-index)
                  index-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.While cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (match (spec-rewrite-expr cond templates state)
          [(ResultSpecExpr.Ok rewritten-cond cond-state)
            (match (spec-rewrite-expr body templates cond-state)
              [(ResultSpecExpr.Ok rewritten-body body-state)
                (ResultSpecExpr.Ok
                  (ast-expr-while rewritten-cond rewritten-body)
                  body-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Begin exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok (ast-node-push (AstExpr.Begin rewritten)) state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(AstExpr.Unsafe exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok (ast-node-push (AstExpr.Unsafe rewritten)) state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(AstExpr.Set name value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr value templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-set-id name rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Ann inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-ann rewritten ty) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Cast inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-cast rewritten ty) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee-box arms)
          (let
            [scrutinee : AstExpr (ast-node-get scrutinee-box)]
            (match (spec-rewrite-expr scrutinee templates state)
              [(ResultSpecExpr.Ok rewritten-scrutinee scrutinee-state)
                (match (spec-rewrite-match-arms arms templates scrutinee-state)
                  [(ResultSpecMatchArmList.Ok rewritten-arms arms-state)
                    (ResultSpecExpr.Ok
                      (ast-expr-match rewritten-scrutinee rewritten-arms)
                      arms-state)]
                  [(ResultSpecMatchArmList.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))])]
    [(AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(AstForeach.Foreach index index-ty start-box end-box body-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-rewrite-expr start templates state)
              [(ResultSpecExpr.Ok rewritten-start start-state)
                (match (spec-rewrite-expr end templates start-state)
                  [(ResultSpecExpr.Ok rewritten-end end-state)
                    (match (spec-rewrite-expr
                      body
                      (spec-template-env-shadow-name
                        templates
                        (intern-str index))
                      end-state)
                      [(ResultSpecExpr.Ok rewritten-body body-state)
                        (ResultSpecExpr.Ok
                          (ast-expr-foreach-id
                            index
                            index-ty
                            rewritten-start
                            rewritten-end
                            rewritten-body)
                          body-state)]
                      [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
                  [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))])]
    [(AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce.Reduce
            op
            index
            index-ty
            start-box
            end-box
            init-box
            value-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [init : AstExpr (ast-node-get init-box)]
            [value : AstExpr (ast-node-get value-box)]
            (match (spec-rewrite-expr start templates state)
              [(ResultSpecExpr.Ok rewritten-start start-state)
                (match (spec-rewrite-expr end templates start-state)
                  [(ResultSpecExpr.Ok rewritten-end end-state)
                    (match (spec-rewrite-expr init templates end-state)
                      [(ResultSpecExpr.Ok rewritten-init init-state)
                        (match (spec-rewrite-expr
                          value
                          (spec-template-env-shadow-name
                            templates
                            (intern-str index))
                          init-state)
                          [(ResultSpecExpr.Ok rewritten-value value-state)
                            (ResultSpecExpr.Ok
                              (ast-expr-spmd-reduce-id
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
    [(AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan.Scan
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
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [init : AstExpr (ast-node-get init-box)]
            [value : AstExpr (ast-node-get value-box)]
            [body : AstExpr (ast-node-get body-box)]
            [value-templates : SpecTemplateEnv
              (spec-template-env-shadow-name templates (intern-str index))]
            [body-templates : SpecTemplateEnv
              (spec-template-env-shadow-name
                value-templates
                (intern-str prefix))]
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
                                  (ast-expr-spmd-scan-id
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
    [(AstExpr.SpmdBroadcast value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (spec-rewrite-expr value templates state)
          [(ResultSpecExpr.Ok rewritten-value value-state)
            (match (spec-rewrite-expr lane templates value-state)
              [(ResultSpecExpr.Ok rewritten-lane lane-state)
                (ResultSpecExpr.Ok
                  (ast-expr-spmd-broadcast rewritten-value rewritten-lane)
                  lane-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.SpmdShuffle value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (spec-rewrite-expr value templates state)
          [(ResultSpecExpr.Ok rewritten-value value-state)
            (match (spec-rewrite-expr lane templates value-state)
              [(ResultSpecExpr.Ok rewritten-lane lane-state)
                (ResultSpecExpr.Ok
                  (ast-expr-spmd-shuffle rewritten-value rewritten-lane)
                  lane-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.StructGet receiver-box field)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (match (spec-rewrite-expr receiver templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-struct-get-id rewritten field) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.StructSet receiver-box field value-box)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr receiver templates state)
          [(ResultSpecExpr.Ok rewritten-receiver receiver-state)
            (match (spec-rewrite-expr value templates receiver-state)
              [(ResultSpecExpr.Ok rewritten-value value-state)
                (ResultSpecExpr.Ok
                  (ast-expr-struct-set-id
                    rewritten-receiver
                    field
                    rewritten-value)
                  value-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.WithRegion region body)
      (match (spec-rewrite-expr-list body templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok
            (ast-node-push (AstExpr.WithRegion region rewritten))
            state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(AstExpr.WithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (match (spec-rewrite-expr scratch templates state)
          [(ResultSpecExpr.Ok rewritten-scratch scratch-state)
            (match (spec-rewrite-expr-list body templates scratch-state)
              [(ResultSpecExprList.Ok rewritten-body body-state)
                (ResultSpecExpr.Ok
                  (ast-expr-with-escape rewritten-scratch rewritten-body)
                  body-state)]
              [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.WithScratch body)
      (match (spec-rewrite-expr-list body templates state)
        [(ResultSpecExprList.Ok rewritten-body body-state)
          (ResultSpecExpr.Ok (ast-expr-with-scratch rewritten-body) body-state)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(AstExpr.InArena arena-box body)
      (let
        [arena : AstExpr (ast-node-get arena-box)]
        (match (spec-rewrite-expr arena templates state)
          [(ResultSpecExpr.Ok rewritten-arena arena-state)
            (match (spec-rewrite-expr-list body templates arena-state)
              [(ResultSpecExprList.Ok rewritten-body body-state)
                (ResultSpecExpr.Ok
                  (ast-expr-in-arena rewritten-arena rewritten-body)
                  body-state)]
              [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (ResultSpecExpr.Ok
            (ast-node-push
              (AstExpr.WithResource
                (box (AstWithResource.WithResource bindings body))))
            state)])]
    [(AstExpr.Box inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-box rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.BoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-box-get rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.BoxTake inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-box-take rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.BoxSet inner-box value-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten-inner inner-state)
            (match (spec-rewrite-expr value templates inner-state)
              [(ResultSpecExpr.Ok rewritten-value value-state)
                (ResultSpecExpr.Ok
                  (ast-expr-box-set rewritten-inner rewritten-value)
                  value-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Comptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-comptime rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Try inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-try rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Return inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-return rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Break) (ResultSpecExpr.Ok (ast-expr-break) state)]
    [(AstExpr.Continue) (ResultSpecExpr.Ok (ast-expr-continue) state)]
    [(AstExpr.PtrNull ty)
      (ResultSpecExpr.Ok (ast-node-push (AstExpr.PtrNull ty)) state)]
    [(AstExpr.PtrNullCheck inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-ptr-null-check rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.PtrAddrOf place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (match (spec-rewrite-expr place templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-ptr-addr-of-id rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.PtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-ptr-read rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.PtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(ResultSpecExpr.Ok rewritten-ptr ptr-state)
            (match (spec-rewrite-expr value templates ptr-state)
              [(ResultSpecExpr.Ok rewritten-value value-state)
                (ResultSpecExpr.Ok
                  (ast-expr-ptr-write rewritten-ptr rewritten-value)
                  value-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.PtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(ResultSpecExpr.Ok rewritten-ptr ptr-state)
            (match (spec-rewrite-expr offset templates ptr-state)
              [(ResultSpecExpr.Ok rewritten-offset offset-state)
                (ResultSpecExpr.Ok
                  (ast-expr-ptr-offset rewritten-ptr rewritten-offset)
                  offset-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.PtrCast ptr-box ty)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-ptr-cast rewritten ty) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.PtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-ptr-to-int rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.IntToPtr value-box ty)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr value templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-int-to-ptr rewritten ty) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.StringData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-string-data rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.StringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(ResultSpecExpr.Ok rewritten-ptr ptr-state)
            (match (spec-rewrite-expr len templates ptr-state)
              [(ResultSpecExpr.Ok rewritten-len len-state)
                (ResultSpecExpr.Ok
                  (ast-expr-string-from-bytes rewritten-ptr rewritten-len)
                  len-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.ArrayData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-array-data rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.BinaryData bytes)
      (ResultSpecExpr.Ok (ast-node-push (AstExpr.BinaryData bytes)) state)]
    [(AstExpr.SpmdProgramIndex)
      (ResultSpecExpr.Ok (ast-expr-spmd-program-index) state)]
    [(AstExpr.SpmdProgramCount)
      (ResultSpecExpr.Ok (ast-expr-spmd-program-count) state)]
    [(AstExpr.ProgramArgc)
      (ResultSpecExpr.Ok (ast-node-push (AstExpr.ProgramArgc)) state)]
    [(AstExpr.ProgramArgv)
      (ResultSpecExpr.Ok (ast-node-push (AstExpr.ProgramArgv)) state)]
    [(AstExpr.ProgramEnvp)
      (ResultSpecExpr.Ok (ast-node-push (AstExpr.ProgramEnvp)) state)]
    [(AstExpr.CpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-rewrite-expr leaf templates state)
          [(ResultSpecExpr.Ok rewritten-leaf leaf-state)
            (match (spec-rewrite-expr subleaf templates leaf-state)
              [(ResultSpecExpr.Ok rewritten-subleaf subleaf-state)
                (ResultSpecExpr.Ok
                  (ast-expr-cpuid-eax rewritten-leaf rewritten-subleaf)
                  subleaf-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.CpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-rewrite-expr leaf templates state)
          [(ResultSpecExpr.Ok rewritten-leaf leaf-state)
            (match (spec-rewrite-expr subleaf templates leaf-state)
              [(ResultSpecExpr.Ok rewritten-subleaf subleaf-state)
                (ResultSpecExpr.Ok
                  (ast-expr-cpuid-ebx rewritten-leaf rewritten-subleaf)
                  subleaf-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.CpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-rewrite-expr leaf templates state)
          [(ResultSpecExpr.Ok rewritten-leaf leaf-state)
            (match (spec-rewrite-expr subleaf templates leaf-state)
              [(ResultSpecExpr.Ok rewritten-subleaf subleaf-state)
                (ResultSpecExpr.Ok
                  (ast-expr-cpuid-ecx rewritten-leaf rewritten-subleaf)
                  subleaf-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.CpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-rewrite-expr leaf templates state)
          [(ResultSpecExpr.Ok rewritten-leaf leaf-state)
            (match (spec-rewrite-expr subleaf templates leaf-state)
              [(ResultSpecExpr.Ok rewritten-subleaf subleaf-state)
                (ResultSpecExpr.Ok
                  (ast-expr-cpuid-edx rewritten-leaf rewritten-subleaf)
                  subleaf-state)]
              [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)])]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Xgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-rewrite-expr index templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-xgetbv rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Syscall args)
      (match (spec-rewrite-expr-list args templates state)
        [(ResultSpecExprList.Ok rewritten-args args-state)
          (ResultSpecExpr.Ok (ast-expr-syscall rewritten-args) args-state)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(AstExpr.Quote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-quote rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Quasiquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-quasiquote rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.Unquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-unquote rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.UnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecExpr.Ok (ast-expr-unquote-splicing rewritten) state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecExpr.Err diag)]))]
    [(AstExpr.BracketClause items)
      (match (spec-rewrite-expr-list items templates state)
        [(ResultSpecExprList.Ok rewritten state2)
          (ResultSpecExpr.Ok (ast-expr-bracket-clause rewritten) state2)]
        [(ResultSpecExprList.Err diag) (ResultSpecExpr.Err diag)])]
    [(AstExpr.Borrow _ _ _) (ResultSpecExpr.Ok (ast-node-push expr) state)]))

(define (spec-ptr-addr-of-place-value-conflict
  [place : AstExpr]
  [subs : SpecValueSubst]) : SpecMaybeString
  (match (ast-expr-unspan place)
    [(AstExpr.Var name) (spec-value-subst-lookup subs (intern-str name))]
    [(AstExpr.StructGet receiver-box _)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (spec-ptr-addr-of-place-value-conflict receiver subs))]
    [(AstExpr.ArrayRef array-box _)
      (let
        [array : AstExpr (ast-node-get array-box)]
        (spec-ptr-addr-of-place-value-conflict array subs))]
    [_ (SpecMaybeString.None)]))

(define (spec-substitute-values-expr [expr : AstExpr] [subs : SpecValueSubst]) : ResultSpecSubExpr
  (match expr
    [(AstExpr.Spanned inner-box span)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-spanned rewritten span))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.ArrayTake array-box live-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [live : AstExpr (ast-node-get live-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-values-expr array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-values-expr live subs)
              [(ResultSpecSubExpr.Ok rewritten-live)
                (match (spec-substitute-values-expr index subs)
                  [(ResultSpecSubExpr.Ok rewritten-index)
                    (ResultSpecSubExpr.Ok
                      (ast-expr-array-take
                        rewritten-array
                        rewritten-live
                        rewritten-index))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Var name)
      (let
        [name-str : String (intern-str name)]
        (match (spec-value-subst-lookup subs name-str)
          [(SpecMaybeString.Some _)
            (spec-ctfe-value-to-expr
              (spec-value-subst-value subs name-str)
              expr)]
          [(SpecMaybeString.None) (ResultSpecSubExpr.Ok (ast-node-push expr))]))]
    [(AstExpr.Literal _) (ResultSpecSubExpr.Ok (ast-node-push expr))]
    [(AstExpr.TypeLiteral _) (ResultSpecSubExpr.Ok (ast-node-push expr))]
    [(AstExpr.Init _) (ResultSpecSubExpr.Ok (ast-node-push expr))]
    [(AstExpr.Binary op left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (match (spec-substitute-values-expr left subs)
          [(ResultSpecSubExpr.Ok rewritten-left)
            (match (spec-substitute-values-expr right subs)
              [(ResultSpecSubExpr.Ok rewritten-right)
                (ResultSpecSubExpr.Ok
                  (ast-expr-binary op rewritten-left rewritten-right))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Unary op inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-unary op rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Call func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (match (spec-substitute-values-expr func subs)
          [(ResultSpecSubExpr.Ok rewritten-func)
            (match (spec-substitute-values-expr-list args subs)
              [(ResultSpecSubExprList.Ok rewritten-args)
                (ResultSpecSubExpr.Ok
                  (ast-expr-call rewritten-func rewritten-args))]
              [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (match (spec-substitute-values-expr cond subs)
          [(ResultSpecSubExpr.Ok rewritten-cond)
            (match (spec-substitute-values-expr then-branch subs)
              [(ResultSpecSubExpr.Ok rewritten-then)
                (match (spec-substitute-values-expr else-branch subs)
                  [(ResultSpecSubExpr.Ok rewritten-else)
                    (ResultSpecSubExpr.Ok
                      (ast-expr-if rewritten-cond rewritten-then rewritten-else))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-substitute-values-let-bindings bindings subs)
              [(ResultSpecSubLetBindingList.Ok rewritten-bindings)
                (match (spec-substitute-values-expr
                  body
                  (spec-value-subst-remove-let-binding-names subs bindings))
                  [(ResultSpecSubExpr.Ok rewritten-body)
                    (ResultSpecSubExpr.Ok
                      (ast-expr-let rewritten-bindings rewritten-body))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubLetBindingList.Err diag)
                (ResultSpecSubExpr.Err diag)]))])]
    [(AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda.Lambda params ret body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-substitute-values-expr
              body
              (spec-value-subst-remove-params subs params))
              [(ResultSpecSubExpr.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast-expr-lambda params ret rewritten-body))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(AstExpr.Tuple exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.Tuple rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.TupleRef inner-box index)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-tuple-ref rewritten index))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Array exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.Array rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.DynArray exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.DynArray rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.MakeArray elem-ty len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (match (spec-substitute-values-expr len subs)
          [(ResultSpecSubExpr.Ok rewritten-len)
            (ResultSpecSubExpr.Ok (ast-expr-make-array elem-ty rewritten-len))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.ArrayRef array-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-values-expr array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-values-expr index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (ResultSpecSubExpr.Ok
                  (ast-expr-array-ref rewritten-array rewritten-index))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.ArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-values-expr array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-values-expr index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (match (spec-substitute-values-expr value subs)
                  [(ResultSpecSubExpr.Ok rewritten-value)
                    (ResultSpecSubExpr.Ok
                      (ast-expr-array-set
                        rewritten-array
                        rewritten-index
                        rewritten-value))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.ArrayTake array-box live-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [live : AstExpr (ast-node-get live-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-values-expr array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-values-expr live subs)
              [(ResultSpecSubExpr.Ok rewritten-live)
                (match (spec-substitute-values-expr index subs)
                  [(ResultSpecSubExpr.Ok rewritten-index)
                    (ResultSpecSubExpr.Ok
                      (ast-expr-array-take
                        rewritten-array
                        rewritten-live
                        rewritten-index))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.ArrayPush array-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-values-expr array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-values-expr value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast-expr-array-push rewritten-array rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.StringRef text-box index-box)
      (let
        [text : AstExpr (ast-node-get text-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-values-expr text subs)
          [(ResultSpecSubExpr.Ok rewritten-text)
            (match (spec-substitute-values-expr index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (ResultSpecSubExpr.Ok
                  (ast-expr-string-ref rewritten-text rewritten-index))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.While cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (match (spec-substitute-values-expr cond subs)
          [(ResultSpecSubExpr.Ok rewritten-cond)
            (match (spec-substitute-values-expr body subs)
              [(ResultSpecSubExpr.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast-expr-while rewritten-cond rewritten-body))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Begin exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.Begin rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.Unsafe exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.Unsafe rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.Set name value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-value-subst-lookup subs (intern-str name))
          [(SpecMaybeString.Some _)
            (ResultSpecSubExpr.Err
              (box
                (spec-diagnostic-at-expr
                  expr
                  (string.append
                    "cannot assign to comptime parameter '"
                    (string.append (intern-str name) "'")))))]
          [(SpecMaybeString.None)
            (match (spec-substitute-values-expr value subs)
              [(ResultSpecSubExpr.Ok rewritten)
                (ResultSpecSubExpr.Ok (ast-expr-set-id name rewritten))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]))]
    [(AstExpr.Ann inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-ann rewritten ty))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Cast inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-cast rewritten ty))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee-box arms)
          (let
            [scrutinee : AstExpr (ast-node-get scrutinee-box)]
            (match (spec-substitute-values-expr scrutinee subs)
              [(ResultSpecSubExpr.Ok rewritten-scrutinee)
                (match (spec-substitute-values-match-arms arms subs)
                  [(ResultSpecSubMatchArmList.Ok rewritten-arms)
                    (ResultSpecSubExpr.Ok
                      (ast-expr-match rewritten-scrutinee rewritten-arms))]
                  [(ResultSpecSubMatchArmList.Err diag)
                    (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(AstForeach.Foreach index index-ty start-box end-box body-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-substitute-values-expr start subs)
              [(ResultSpecSubExpr.Ok rewritten-start)
                (match (spec-substitute-values-expr end subs)
                  [(ResultSpecSubExpr.Ok rewritten-end)
                    (match (spec-substitute-values-expr
                      body
                      (spec-value-subst-remove-name subs (intern-str index)))
                      [(ResultSpecSubExpr.Ok rewritten-body)
                        (ResultSpecSubExpr.Ok
                          (ast-expr-foreach-id
                            index
                            index-ty
                            rewritten-start
                            rewritten-end
                            rewritten-body))]
                      [(ResultSpecSubExpr.Err diag)
                        (ResultSpecSubExpr.Err diag)])]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce.Reduce
            op
            index
            index-ty
            start-box
            end-box
            init-box
            value-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [init : AstExpr (ast-node-get init-box)]
            [value : AstExpr (ast-node-get value-box)]
            (match (spec-substitute-values-expr start subs)
              [(ResultSpecSubExpr.Ok rewritten-start)
                (match (spec-substitute-values-expr end subs)
                  [(ResultSpecSubExpr.Ok rewritten-end)
                    (match (spec-substitute-values-expr init subs)
                      [(ResultSpecSubExpr.Ok rewritten-init)
                        (match (spec-substitute-values-expr
                          value
                          (spec-value-subst-remove-name subs (intern-str index)))
                          [(ResultSpecSubExpr.Ok rewritten-value)
                            (ResultSpecSubExpr.Ok
                              (ast-expr-spmd-reduce-id
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
    [(AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan.Scan
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
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [init : AstExpr (ast-node-get init-box)]
            [value : AstExpr (ast-node-get value-box)]
            [body : AstExpr (ast-node-get body-box)]
            [value-subs : SpecValueSubst
              (spec-value-subst-remove-name subs (intern-str index))]
            [body-subs : SpecValueSubst
              (spec-value-subst-remove-name value-subs (intern-str prefix))]
            (match (spec-substitute-values-expr start subs)
              [(ResultSpecSubExpr.Ok rewritten-start)
                (match (spec-substitute-values-expr end subs)
                  [(ResultSpecSubExpr.Ok rewritten-end)
                    (match (spec-substitute-values-expr init subs)
                      [(ResultSpecSubExpr.Ok rewritten-init)
                        (match (spec-substitute-values-expr value value-subs)
                          [(ResultSpecSubExpr.Ok rewritten-value)
                            (match (spec-substitute-values-expr body body-subs)
                              [(ResultSpecSubExpr.Ok rewritten-body)
                                (ResultSpecSubExpr.Ok
                                  (ast-expr-spmd-scan-id
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
    [(AstExpr.SpmdBroadcast value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (spec-substitute-values-expr value subs)
          [(ResultSpecSubExpr.Ok rewritten-value)
            (match (spec-substitute-values-expr lane subs)
              [(ResultSpecSubExpr.Ok rewritten-lane)
                (ResultSpecSubExpr.Ok
                  (ast-expr-spmd-broadcast rewritten-value rewritten-lane))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.SpmdShuffle value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (spec-substitute-values-expr value subs)
          [(ResultSpecSubExpr.Ok rewritten-value)
            (match (spec-substitute-values-expr lane subs)
              [(ResultSpecSubExpr.Ok rewritten-lane)
                (ResultSpecSubExpr.Ok
                  (ast-expr-spmd-shuffle rewritten-value rewritten-lane))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.StructGet receiver-box field)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (match (spec-substitute-values-expr receiver subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-struct-get-id rewritten field))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.StructSet receiver-box field value-box)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-values-expr receiver subs)
          [(ResultSpecSubExpr.Ok rewritten-receiver)
            (match (spec-substitute-values-expr value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast-expr-struct-set-id
                    rewritten-receiver
                    field
                    rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.WithRegion region body)
      (match (spec-substitute-values-expr-list body subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (ast-node-push (AstExpr.WithRegion region rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.WithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (match (spec-substitute-values-expr scratch subs)
          [(ResultSpecSubExpr.Ok rewritten-scratch)
            (match (spec-substitute-values-expr-list body subs)
              [(ResultSpecSubExprList.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast-expr-with-escape rewritten-scratch rewritten-body))]
              [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.WithScratch body)
      (match (spec-substitute-values-expr-list body subs)
        [(ResultSpecSubExprList.Ok rewritten-body)
          (ResultSpecSubExpr.Ok (ast-expr-with-scratch rewritten-body))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.InArena arena-box body)
      (let
        [arena : AstExpr (ast-node-get arena-box)]
        (match (spec-substitute-values-expr arena subs)
          [(ResultSpecSubExpr.Ok rewritten-arena)
            (match (spec-substitute-values-expr-list body subs)
              [(ResultSpecSubExprList.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast-expr-in-arena rewritten-arena rewritten-body))]
              [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (ResultSpecSubExpr.Ok
            (ast-node-push
              (AstExpr.WithResource
                (box (AstWithResource.WithResource bindings body)))))])]
    [(AstExpr.Box inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-box rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.BoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-box-get rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.BoxTake inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-box-take rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.BoxSet inner-box value-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten-inner)
            (match (spec-substitute-values-expr value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast-expr-box-set rewritten-inner rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Comptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-comptime rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Try inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-try rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Return inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-return rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Break) (ResultSpecSubExpr.Ok (ast-expr-break))]
    [(AstExpr.Continue) (ResultSpecSubExpr.Ok (ast-expr-continue))]
    [(AstExpr.PtrNull ty)
      (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.PtrNull ty)))]
    [(AstExpr.PtrNullCheck inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-ptr-null-check rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.PtrAddrOf place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (match (spec-ptr-addr-of-place-value-conflict place subs)
          [(SpecMaybeString.Some name)
            (ResultSpecSubExpr.Err
              (box
                (spec-diagnostic-at-expr
                  expr
                  (string.append
                    "cannot take address of comptime value parameter '"
                    (string.append name "'")))))]
          [(SpecMaybeString.None)
            (match (spec-substitute-values-expr place subs)
              [(ResultSpecSubExpr.Ok rewritten)
                (ResultSpecSubExpr.Ok (ast-expr-ptr-addr-of-id rewritten))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]))]
    [(AstExpr.PtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-ptr-read rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.PtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(ResultSpecSubExpr.Ok rewritten-ptr)
            (match (spec-substitute-values-expr value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast-expr-ptr-write rewritten-ptr rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.PtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(ResultSpecSubExpr.Ok rewritten-ptr)
            (match (spec-substitute-values-expr offset subs)
              [(ResultSpecSubExpr.Ok rewritten-offset)
                (ResultSpecSubExpr.Ok
                  (ast-expr-ptr-offset rewritten-ptr rewritten-offset))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.PtrCast ptr-box ty)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-ptr-cast rewritten ty))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.PtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-ptr-to-int rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.IntToPtr value-box ty)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-values-expr value subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-int-to-ptr rewritten ty))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.StringData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-string-data rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.StringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(ResultSpecSubExpr.Ok rewritten-ptr)
            (match (spec-substitute-values-expr len subs)
              [(ResultSpecSubExpr.Ok rewritten-len)
                (ResultSpecSubExpr.Ok
                  (ast-expr-string-from-bytes rewritten-ptr rewritten-len))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.ArrayData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-array-data rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.BinaryData bytes)
      (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.BinaryData bytes)))]
    [(AstExpr.SpmdProgramIndex)
      (ResultSpecSubExpr.Ok (ast-expr-spmd-program-index))]
    [(AstExpr.SpmdProgramCount)
      (ResultSpecSubExpr.Ok (ast-expr-spmd-program-count))]
    [(AstExpr.ProgramArgc)
      (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.ProgramArgc)))]
    [(AstExpr.ProgramArgv)
      (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.ProgramArgv)))]
    [(AstExpr.ProgramEnvp)
      (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.ProgramEnvp)))]
    [(AstExpr.CpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-values-expr leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-values-expr subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast-expr-cpuid-eax rewritten-leaf rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.CpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-values-expr leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-values-expr subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast-expr-cpuid-ebx rewritten-leaf rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.CpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-values-expr leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-values-expr subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast-expr-cpuid-ecx rewritten-leaf rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.CpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-values-expr leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-values-expr subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast-expr-cpuid-edx rewritten-leaf rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Xgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-values-expr index subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-xgetbv rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Syscall args)
      (match (spec-substitute-values-expr-list args subs)
        [(ResultSpecSubExprList.Ok rewritten-args)
          (ResultSpecSubExpr.Ok (ast-expr-syscall rewritten-args))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.Quote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-quote rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Quasiquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-quasiquote rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Unquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-unquote rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.UnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-unquote-splicing rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.BracketClause items)
      (match (spec-substitute-values-expr-list items subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok (ast-expr-bracket-clause rewritten))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.Borrow _ _ _) (ResultSpecSubExpr.Ok (ast-node-push expr))]))

(define (spec-substitute-values-expr-list
  [exprs : AstExprList]
  [subs : SpecValueSubst]) : ResultSpecSubExprList
  (let
    [out : AstExprList (ast-expr-list-with-capacity (struct-get (& exprs) len))]
    (match (spec-substitute-values-expr-list-at (& exprs) 0 subs (&mut out))
      [(ResultSpecSubExprListBuild.Ok) (ResultSpecSubExprList.Ok out)]
      [(ResultSpecSubExprListBuild.Err diag) (ResultSpecSubExprList.Err diag)])))

(define (spec-substitute-values-expr-list-at
  [exprs : (& exprs AstExprList)]
  [index : i64]
  [subs : SpecValueSubst]
  [out : (&mut out AstExprList)]) : ResultSpecSubExprListBuild
  (if (>= index (struct-get exprs len))
    (ResultSpecSubExprListBuild.Ok)
    (let
      [head : AstExpr (ast-node-get (ast-expr-list-get exprs index 0))]
      (match (spec-substitute-values-expr head subs)
        [(ResultSpecSubExpr.Ok rewritten-head)
          (begin
            (ast-expr-list-push out rewritten-head)
            (spec-substitute-values-expr-list-at exprs (+ index 1) subs out))]
        [(ResultSpecSubExpr.Err diag) (ResultSpecSubExprListBuild.Err diag)]))))

(define (spec-substitute-values-let-bindings
  [bindings : AstLetBindingList]
  [subs : SpecValueSubst]) : ResultSpecSubLetBindingList
  (let
    [out : AstLetBindingList
      (ast-let-binding-list-with-capacity
        (ast-let-binding-list-len (& bindings)))]
    (match (spec-substitute-values-let-bindings-at
      (& bindings)
      0
      subs
      (&mut out))
      [(ResultSpecSubLetBindingListBuild.Ok)
        (ResultSpecSubLetBindingList.Ok out)]
      [(ResultSpecSubLetBindingListBuild.Err diag)
        (ResultSpecSubLetBindingList.Err diag)])))

(define (spec-substitute-values-let-bindings-at
  [bindings : (& bindings AstLetBindingList)]
  [index : i64]
  [subs : SpecValueSubst]
  [out : (&mut out AstLetBindingList)]) : ResultSpecSubLetBindingListBuild
  (if (>= index (ast-let-binding-list-len bindings))
    (ResultSpecSubLetBindingListBuild.Ok)
    (match (ast-let-binding-list-get bindings index (ast-let-binding-fallback))
      [(AstLetBinding.Binding name ty value-box)
        (let
          [value : AstExpr (ast-node-get value-box)]
          (match (spec-substitute-values-expr value subs)
            [(ResultSpecSubExpr.Ok rewritten-value)
              (begin
                (ast-let-binding-list-push
                  out
                  (ast-let-binding-id name ty rewritten-value))
                (spec-substitute-values-let-bindings-at
                  bindings
                  (+ index 1)
                  (spec-value-subst-remove-name subs (intern-str name))
                  out))]
            [(ResultSpecSubExpr.Err diag)
              (ResultSpecSubLetBindingListBuild.Err diag)]))])))

(define (spec-substitute-values-match-arms
  [arms : AstMatchArmList]
  [subs : SpecValueSubst]) : ResultSpecSubMatchArmList
  (let
    [out : AstMatchArmList
      (ast-match-arm-list-with-capacity (struct-get (& arms) len))]
    (match (spec-substitute-values-match-arms-at (& arms) 0 subs (&mut out))
      [(ResultSpecSubMatchArmListBuild.Ok) (ResultSpecSubMatchArmList.Ok out)]
      [(ResultSpecSubMatchArmListBuild.Err diag)
        (ResultSpecSubMatchArmList.Err diag)])))

(define (spec-substitute-values-match-arms-at
  [arms : (& arms AstMatchArmList)]
  [index : i64]
  [subs : SpecValueSubst]
  [out : (&mut out AstMatchArmList)]) : ResultSpecSubMatchArmListBuild
  (if (>= index (struct-get arms len))
    (ResultSpecSubMatchArmListBuild.Ok)
    (match (ast-match-arm-list-get arms index (ast-match-arm-fallback))
      [(AstMatchArm.Arm pattern body-box)
        (let
          [body : AstExpr (ast-node-get body-box)]
          (match (spec-substitute-values-expr
            body
            (spec-value-subst-remove-pattern subs pattern))
            [(ResultSpecSubExpr.Ok rewritten-body)
              (begin
                (ast-match-arm-list-push
                  out
                  (ast-match-arm pattern rewritten-body))
                (spec-substitute-values-match-arms-at arms (+ index 1) subs out))]
            [(ResultSpecSubExpr.Err diag)
              (ResultSpecSubMatchArmListBuild.Err diag)]))])))

(define (spec-substitute-types-expr [expr : AstExpr] [subs : SpecTypeSubst]) : ResultSpecSubExpr
  (match expr
    [(AstExpr.Spanned inner-box span)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-spanned rewritten span))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Var name)
      (match (spec-type-subst-lookup subs (intern-str name))
        [(SpecMaybeString.Some _)
          (ResultSpecSubExpr.Err
            (box
              (spec-diagnostic-at-expr
                expr
                (string.append
                  "type-valued comptime parameter '"
                  (string.append
                    (intern-str name)
                    "' cannot be used as a runtime value")))))]
        [(SpecMaybeString.None) (ResultSpecSubExpr.Ok (ast-node-push expr))])]
    [(AstExpr.Literal _) (ResultSpecSubExpr.Ok (ast-node-push expr))]
    [(AstExpr.TypeLiteral ty)
      (ResultSpecSubExpr.Ok
        (ast-node-push (AstExpr.TypeLiteral (spec-substitute-type ty subs))))]
    [(AstExpr.Init maybe-ty)
      (ResultSpecSubExpr.Ok
        (ast-expr-init-maybe (spec-substitute-maybe-type maybe-ty subs)))]
    [(AstExpr.MakeArray elem-ty len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (match (spec-substitute-types-expr len subs)
          [(ResultSpecSubExpr.Ok rewritten-len)
            (ResultSpecSubExpr.Ok
              (ast-expr-make-array
                (spec-substitute-type elem-ty subs)
                rewritten-len))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Ann inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast-expr-ann rewritten (spec-substitute-type ty subs)))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Cast inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast-expr-cast rewritten (spec-substitute-type ty subs)))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Lambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda.Lambda params ret body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-substitute-types-expr
              body
              (spec-type-subst-remove-params subs params))
              [(ResultSpecSubExpr.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast-expr-lambda
                    (spec-substitute-param-types params subs)
                    (spec-substitute-maybe-type ret subs)
                    rewritten-body))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(AstExpr.Foreach fe-box)
      (match (box-get fe-box)
        [(AstForeach.Foreach index index-ty start-box end-box body-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-substitute-types-expr start subs)
              [(ResultSpecSubExpr.Ok rewritten-start)
                (match (spec-substitute-types-expr end subs)
                  [(ResultSpecSubExpr.Ok rewritten-end)
                    (match (spec-substitute-types-expr
                      body
                      (spec-type-subst-remove-name subs (intern-str index)))
                      [(ResultSpecSubExpr.Ok rewritten-body)
                        (ResultSpecSubExpr.Ok
                          (ast-expr-foreach-id
                            index
                            (spec-substitute-type index-ty subs)
                            rewritten-start
                            rewritten-end
                            rewritten-body))]
                      [(ResultSpecSubExpr.Err diag)
                        (ResultSpecSubExpr.Err diag)])]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(AstExpr.SpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce.Reduce
            op
            index
            index-ty
            start-box
            end-box
            init-box
            value-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [init : AstExpr (ast-node-get init-box)]
            [value : AstExpr (ast-node-get value-box)]
            (match (spec-substitute-types-expr start subs)
              [(ResultSpecSubExpr.Ok rewritten-start)
                (match (spec-substitute-types-expr end subs)
                  [(ResultSpecSubExpr.Ok rewritten-end)
                    (match (spec-substitute-types-expr init subs)
                      [(ResultSpecSubExpr.Ok rewritten-init)
                        (match (spec-substitute-types-expr
                          value
                          (spec-type-subst-remove-name subs (intern-str index)))
                          [(ResultSpecSubExpr.Ok rewritten-value)
                            (ResultSpecSubExpr.Ok
                              (ast-expr-spmd-reduce-id
                                op
                                index
                                (spec-substitute-type index-ty subs)
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
    [(AstExpr.SpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan.Scan
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
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [init : AstExpr (ast-node-get init-box)]
            [value : AstExpr (ast-node-get value-box)]
            [body : AstExpr (ast-node-get body-box)]
            [value-subs : SpecTypeSubst
              (spec-type-subst-remove-name subs (intern-str index))]
            [body-subs : SpecTypeSubst
              (spec-type-subst-remove-name value-subs (intern-str prefix))]
            (match (spec-substitute-types-expr start subs)
              [(ResultSpecSubExpr.Ok rewritten-start)
                (match (spec-substitute-types-expr end subs)
                  [(ResultSpecSubExpr.Ok rewritten-end)
                    (match (spec-substitute-types-expr init subs)
                      [(ResultSpecSubExpr.Ok rewritten-init)
                        (match (spec-substitute-types-expr value value-subs)
                          [(ResultSpecSubExpr.Ok rewritten-value)
                            (match (spec-substitute-types-expr body body-subs)
                              [(ResultSpecSubExpr.Ok rewritten-body)
                                (ResultSpecSubExpr.Ok
                                  (ast-expr-spmd-scan-id
                                    op
                                    index
                                    (spec-substitute-type index-ty subs)
                                    rewritten-start
                                    rewritten-end
                                    prefix
                                    (spec-substitute-type prefix-ty subs)
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
    [(AstExpr.SpmdBroadcast value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (spec-substitute-types-expr value subs)
          [(ResultSpecSubExpr.Ok rewritten-value)
            (match (spec-substitute-types-expr lane subs)
              [(ResultSpecSubExpr.Ok rewritten-lane)
                (ResultSpecSubExpr.Ok
                  (ast-expr-spmd-broadcast rewritten-value rewritten-lane))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.SpmdShuffle value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (spec-substitute-types-expr value subs)
          [(ResultSpecSubExpr.Ok rewritten-value)
            (match (spec-substitute-types-expr lane subs)
              [(ResultSpecSubExpr.Ok rewritten-lane)
                (ResultSpecSubExpr.Ok
                  (ast-expr-spmd-shuffle rewritten-value rewritten-lane))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Binary op left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (match (spec-substitute-types-expr left subs)
          [(ResultSpecSubExpr.Ok rewritten-left)
            (match (spec-substitute-types-expr right subs)
              [(ResultSpecSubExpr.Ok rewritten-right)
                (ResultSpecSubExpr.Ok
                  (ast-expr-binary op rewritten-left rewritten-right))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Unary op inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-unary op rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Call func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (match (spec-substitute-types-expr func subs)
          [(ResultSpecSubExpr.Ok rewritten-func)
            (match (spec-substitute-types-expr-list args subs)
              [(ResultSpecSubExprList.Ok rewritten-args)
                (ResultSpecSubExpr.Ok
                  (ast-expr-call rewritten-func rewritten-args))]
              [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.If cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (match (spec-substitute-types-expr cond subs)
          [(ResultSpecSubExpr.Ok rewritten-cond)
            (match (spec-substitute-types-expr then-branch subs)
              [(ResultSpecSubExpr.Ok rewritten-then)
                (match (spec-substitute-types-expr else-branch subs)
                  [(ResultSpecSubExpr.Ok rewritten-else)
                    (ResultSpecSubExpr.Ok
                      (ast-expr-if rewritten-cond rewritten-then rewritten-else))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Let let-box)
      (match (box-get let-box)
        [(AstLet.Let bindings body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-substitute-types-let-bindings bindings subs)
              [(ResultSpecSubLetBindingList.Ok rewritten-bindings)
                (match (spec-substitute-types-expr
                  body
                  (spec-type-subst-remove-let-binding-names subs bindings))
                  [(ResultSpecSubExpr.Ok rewritten-body)
                    (ResultSpecSubExpr.Ok
                      (ast-expr-let rewritten-bindings rewritten-body))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubLetBindingList.Err diag)
                (ResultSpecSubExpr.Err diag)]))])]
    [(AstExpr.Tuple exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.Tuple rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.TupleRef inner-box index)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-tuple-ref rewritten index))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Array exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.Array rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.DynArray exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.DynArray rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.ArrayRef array-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-types-expr array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-types-expr index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (ResultSpecSubExpr.Ok
                  (ast-expr-array-ref rewritten-array rewritten-index))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.ArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-types-expr array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-types-expr index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (match (spec-substitute-types-expr value subs)
                  [(ResultSpecSubExpr.Ok rewritten-value)
                    (ResultSpecSubExpr.Ok
                      (ast-expr-array-set
                        rewritten-array
                        rewritten-index
                        rewritten-value))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.ArrayTake array-box live-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [live : AstExpr (ast-node-get live-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-types-expr array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-types-expr live subs)
              [(ResultSpecSubExpr.Ok rewritten-live)
                (match (spec-substitute-types-expr index subs)
                  [(ResultSpecSubExpr.Ok rewritten-index)
                    (ResultSpecSubExpr.Ok
                      (ast-expr-array-take
                        rewritten-array
                        rewritten-live
                        rewritten-index))]
                  [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.ArrayPush array-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-types-expr array subs)
          [(ResultSpecSubExpr.Ok rewritten-array)
            (match (spec-substitute-types-expr value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast-expr-array-push rewritten-array rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.StringRef text-box index-box)
      (let
        [text : AstExpr (ast-node-get text-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-types-expr text subs)
          [(ResultSpecSubExpr.Ok rewritten-text)
            (match (spec-substitute-types-expr index subs)
              [(ResultSpecSubExpr.Ok rewritten-index)
                (ResultSpecSubExpr.Ok
                  (ast-expr-string-ref rewritten-text rewritten-index))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.While cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (match (spec-substitute-types-expr cond subs)
          [(ResultSpecSubExpr.Ok rewritten-cond)
            (match (spec-substitute-types-expr body subs)
              [(ResultSpecSubExpr.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast-expr-while rewritten-cond rewritten-body))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Begin exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.Begin rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.Unsafe exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.Unsafe rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.Set name value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-type-subst-lookup subs (intern-str name))
          [(SpecMaybeString.Some _)
            (ResultSpecSubExpr.Err
              (box
                (spec-diagnostic-at-expr
                  expr
                  (string.append
                    "type-valued comptime parameter '"
                    (string.append (intern-str name) "' cannot be assigned")))))]
          [(SpecMaybeString.None)
            (match (spec-substitute-types-expr value subs)
              [(ResultSpecSubExpr.Ok rewritten)
                (ResultSpecSubExpr.Ok (ast-expr-set-id name rewritten))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]))]
    [(AstExpr.Match match-box)
      (match (box-get match-box)
        [(AstMatch.Match scrutinee-box arms)
          (let
            [scrutinee : AstExpr (ast-node-get scrutinee-box)]
            (match (spec-substitute-types-expr scrutinee subs)
              [(ResultSpecSubExpr.Ok rewritten-scrutinee)
                (match (spec-substitute-types-match-arms arms subs)
                  [(ResultSpecSubMatchArmList.Ok rewritten-arms)
                    (ResultSpecSubExpr.Ok
                      (ast-expr-match rewritten-scrutinee rewritten-arms))]
                  [(ResultSpecSubMatchArmList.Err diag)
                    (ResultSpecSubExpr.Err diag)])]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))])]
    [(AstExpr.StructGet receiver-box field)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (match (spec-substitute-types-expr receiver subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-struct-get-id rewritten field))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.StructSet receiver-box field value-box)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-types-expr receiver subs)
          [(ResultSpecSubExpr.Ok rewritten-receiver)
            (match (spec-substitute-types-expr value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast-expr-struct-set-id
                    rewritten-receiver
                    field
                    rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.WithRegion region body)
      (match (spec-substitute-types-expr-list body subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok
            (ast-node-push (AstExpr.WithRegion region rewritten)))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.WithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (match (spec-substitute-types-expr scratch subs)
          [(ResultSpecSubExpr.Ok rewritten-scratch)
            (match (spec-substitute-types-expr-list body subs)
              [(ResultSpecSubExprList.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast-expr-with-escape rewritten-scratch rewritten-body))]
              [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.WithScratch body)
      (match (spec-substitute-types-expr-list body subs)
        [(ResultSpecSubExprList.Ok rewritten-body)
          (ResultSpecSubExpr.Ok (ast-expr-with-scratch rewritten-body))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.InArena arena-box body)
      (let
        [arena : AstExpr (ast-node-get arena-box)]
        (match (spec-substitute-types-expr arena subs)
          [(ResultSpecSubExpr.Ok rewritten-arena)
            (match (spec-substitute-types-expr-list body subs)
              [(ResultSpecSubExprList.Ok rewritten-body)
                (ResultSpecSubExpr.Ok
                  (ast-expr-in-arena rewritten-arena rewritten-body))]
              [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.WithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource.WithResource bindings body)
          (ResultSpecSubExpr.Ok
            (ast-node-push
              (AstExpr.WithResource
                (box (AstWithResource.WithResource bindings body)))))])]
    [(AstExpr.Box inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-box rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.BoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-box-get rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.BoxTake inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-box-take rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.BoxSet inner-box value-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten-inner)
            (match (spec-substitute-types-expr value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast-expr-box-set rewritten-inner rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Comptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-comptime rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Try inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-try rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Return inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-return rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Break) (ResultSpecSubExpr.Ok (ast-expr-break))]
    [(AstExpr.Continue) (ResultSpecSubExpr.Ok (ast-expr-continue))]
    [(AstExpr.PtrNull ty)
      (ResultSpecSubExpr.Ok
        (ast-node-push (AstExpr.PtrNull (spec-substitute-type ty subs))))]
    [(AstExpr.PtrNullCheck inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-ptr-null-check rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.PtrAddrOf place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (match (spec-substitute-types-expr place subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-ptr-addr-of-id rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.PtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-ptr-read rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.PtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(ResultSpecSubExpr.Ok rewritten-ptr)
            (match (spec-substitute-types-expr value subs)
              [(ResultSpecSubExpr.Ok rewritten-value)
                (ResultSpecSubExpr.Ok
                  (ast-expr-ptr-write rewritten-ptr rewritten-value))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.PtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(ResultSpecSubExpr.Ok rewritten-ptr)
            (match (spec-substitute-types-expr offset subs)
              [(ResultSpecSubExpr.Ok rewritten-offset)
                (ResultSpecSubExpr.Ok
                  (ast-expr-ptr-offset rewritten-ptr rewritten-offset))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.PtrCast ptr-box ty)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast-expr-ptr-cast rewritten (spec-substitute-type ty subs)))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.PtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-ptr-to-int rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.IntToPtr value-box ty)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-types-expr value subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok
              (ast-expr-int-to-ptr rewritten (spec-substitute-type ty subs)))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.StringData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-string-data rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.StringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(ResultSpecSubExpr.Ok rewritten-ptr)
            (match (spec-substitute-types-expr len subs)
              [(ResultSpecSubExpr.Ok rewritten-len)
                (ResultSpecSubExpr.Ok
                  (ast-expr-string-from-bytes rewritten-ptr rewritten-len))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.ArrayData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-array-data rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.BinaryData bytes)
      (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.BinaryData bytes)))]
    [(AstExpr.SpmdProgramIndex)
      (ResultSpecSubExpr.Ok (ast-expr-spmd-program-index))]
    [(AstExpr.SpmdProgramCount)
      (ResultSpecSubExpr.Ok (ast-expr-spmd-program-count))]
    [(AstExpr.ProgramArgc)
      (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.ProgramArgc)))]
    [(AstExpr.ProgramArgv)
      (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.ProgramArgv)))]
    [(AstExpr.ProgramEnvp)
      (ResultSpecSubExpr.Ok (ast-node-push (AstExpr.ProgramEnvp)))]
    [(AstExpr.CpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-types-expr leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-types-expr subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast-expr-cpuid-eax rewritten-leaf rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.CpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-types-expr leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-types-expr subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast-expr-cpuid-ebx rewritten-leaf rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.CpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-types-expr leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-types-expr subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast-expr-cpuid-ecx rewritten-leaf rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.CpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-types-expr leaf subs)
          [(ResultSpecSubExpr.Ok rewritten-leaf)
            (match (spec-substitute-types-expr subleaf subs)
              [(ResultSpecSubExpr.Ok rewritten-subleaf)
                (ResultSpecSubExpr.Ok
                  (ast-expr-cpuid-edx rewritten-leaf rewritten-subleaf))]
              [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)])]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Xgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-types-expr index subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-xgetbv rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Syscall args)
      (match (spec-substitute-types-expr-list args subs)
        [(ResultSpecSubExprList.Ok rewritten-args)
          (ResultSpecSubExpr.Ok (ast-expr-syscall rewritten-args))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.Quote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-quote rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Quasiquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-quasiquote rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.Unquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-unquote rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.UnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(ResultSpecSubExpr.Ok rewritten)
            (ResultSpecSubExpr.Ok (ast-expr-unquote-splicing rewritten))]
          [(ResultSpecSubExpr.Err diag) (ResultSpecSubExpr.Err diag)]))]
    [(AstExpr.BracketClause items)
      (match (spec-substitute-types-expr-list items subs)
        [(ResultSpecSubExprList.Ok rewritten)
          (ResultSpecSubExpr.Ok (ast-expr-bracket-clause rewritten))]
        [(ResultSpecSubExprList.Err diag) (ResultSpecSubExpr.Err diag)])]
    [(AstExpr.Borrow _ _ _) (ResultSpecSubExpr.Ok (ast-node-push expr))]))

(define (spec-substitute-types-expr-list
  [exprs : AstExprList]
  [subs : SpecTypeSubst]) : ResultSpecSubExprList
  (let
    [out : AstExprList (ast-expr-list-with-capacity (struct-get (& exprs) len))]
    (match (spec-substitute-types-expr-list-at (& exprs) 0 subs (&mut out))
      [(ResultSpecSubExprListBuild.Ok) (ResultSpecSubExprList.Ok out)]
      [(ResultSpecSubExprListBuild.Err diag) (ResultSpecSubExprList.Err diag)])))

(define (spec-substitute-types-expr-list-at
  [exprs : (& exprs AstExprList)]
  [index : i64]
  [subs : SpecTypeSubst]
  [out : (&mut out AstExprList)]) : ResultSpecSubExprListBuild
  (if (>= index (struct-get exprs len))
    (ResultSpecSubExprListBuild.Ok)
    (let
      [head : AstExpr (ast-node-get (ast-expr-list-get exprs index 0))]
      (match (spec-substitute-types-expr head subs)
        [(ResultSpecSubExpr.Ok rewritten-head)
          (begin
            (ast-expr-list-push out rewritten-head)
            (spec-substitute-types-expr-list-at exprs (+ index 1) subs out))]
        [(ResultSpecSubExpr.Err diag) (ResultSpecSubExprListBuild.Err diag)]))))

(define (spec-substitute-types-let-bindings
  [bindings : AstLetBindingList]
  [subs : SpecTypeSubst]) : ResultSpecSubLetBindingList
  (let
    [out : AstLetBindingList
      (ast-let-binding-list-with-capacity
        (ast-let-binding-list-len (& bindings)))]
    (match (spec-substitute-types-let-bindings-at
      (& bindings)
      0
      subs
      (&mut out))
      [(ResultSpecSubLetBindingListBuild.Ok)
        (ResultSpecSubLetBindingList.Ok out)]
      [(ResultSpecSubLetBindingListBuild.Err diag)
        (ResultSpecSubLetBindingList.Err diag)])))

(define (spec-substitute-types-let-bindings-at
  [bindings : (& bindings AstLetBindingList)]
  [index : i64]
  [subs : SpecTypeSubst]
  [out : (&mut out AstLetBindingList)]) : ResultSpecSubLetBindingListBuild
  (if (>= index (ast-let-binding-list-len bindings))
    (ResultSpecSubLetBindingListBuild.Ok)
    (match (ast-let-binding-list-get bindings index (ast-let-binding-fallback))
      [(AstLetBinding.Binding name ty value-box)
        (let
          [value : AstExpr (ast-node-get value-box)]
          (match (spec-substitute-types-expr value subs)
            [(ResultSpecSubExpr.Ok rewritten-value)
              (begin
                (ast-let-binding-list-push
                  out
                  (ast-let-binding-id
                    name
                    (spec-substitute-maybe-type ty subs)
                    rewritten-value))
                (spec-substitute-types-let-bindings-at
                  bindings
                  (+ index 1)
                  (spec-type-subst-remove-name subs (intern-str name))
                  out))]
            [(ResultSpecSubExpr.Err diag)
              (ResultSpecSubLetBindingListBuild.Err diag)]))])))

(define (spec-substitute-types-match-arms
  [arms : AstMatchArmList]
  [subs : SpecTypeSubst]) : ResultSpecSubMatchArmList
  (let
    [out : AstMatchArmList
      (ast-match-arm-list-with-capacity (struct-get (& arms) len))]
    (match (spec-substitute-types-match-arms-at (& arms) 0 subs (&mut out))
      [(ResultSpecSubMatchArmListBuild.Ok) (ResultSpecSubMatchArmList.Ok out)]
      [(ResultSpecSubMatchArmListBuild.Err diag)
        (ResultSpecSubMatchArmList.Err diag)])))

(define (spec-substitute-types-match-arms-at
  [arms : (& arms AstMatchArmList)]
  [index : i64]
  [subs : SpecTypeSubst]
  [out : (&mut out AstMatchArmList)]) : ResultSpecSubMatchArmListBuild
  (if (>= index (struct-get arms len))
    (ResultSpecSubMatchArmListBuild.Ok)
    (match (ast-match-arm-list-get arms index (ast-match-arm-fallback))
      [(AstMatchArm.Arm pattern body-box)
        (let
          [body : AstExpr (ast-node-get body-box)]
          (match (spec-substitute-types-expr
            body
            (spec-type-subst-remove-pattern subs pattern))
            [(ResultSpecSubExpr.Ok rewritten-body)
              (begin
                (ast-match-arm-list-push
                  out
                  (ast-match-arm pattern rewritten-body))
                (spec-substitute-types-match-arms-at arms (+ index 1) subs out))]
            [(ResultSpecSubExpr.Err diag)
              (ResultSpecSubMatchArmListBuild.Err diag)]))])))

(define (spec-rewrite-decl
  [decl : AstDecl]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecDecl
  (match decl
    [(AstDecl.Def name ty value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr value templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecDecl.Ok
              (SpecMaybeDecl.Some (ast-decl-def-id name ty rewritten))
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecDecl.Err diag)]))]
    [(AstDecl.DefFn name params ret body-box export)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (if (spec-param-list-has-comptime? params)
          (ResultSpecDecl.Ok (SpecMaybeDecl.None) state)
          (match (spec-rewrite-expr
            body
            (spec-template-env-shadow-params templates params)
            state)
            [(ResultSpecExpr.Ok rewritten state2)
              (ResultSpecDecl.Ok
                (SpecMaybeDecl.Some
                  (ast-decl-def-fn-export-id name params ret rewritten export))
                state2)]
            [(ResultSpecExpr.Err diag) (ResultSpecDecl.Err diag)])))]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (match (spec-rewrite-decl inner templates state)
          [(ResultSpecDecl.Ok maybe state2)
            (match maybe
              [(SpecMaybeDecl.Some rewritten)
                (ResultSpecDecl.Ok
                  (SpecMaybeDecl.Some (ast-decl-unsafe rewritten))
                  state2)]
              [(SpecMaybeDecl.None)
                (ResultSpecDecl.Ok SpecMaybeDecl.None state2)])]
          [(ResultSpecDecl.Err diag) (ResultSpecDecl.Err diag)]))]
    [(AstDecl.DefMacro name params ret body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (spec-rewrite-expr body templates state)
          [(ResultSpecExpr.Ok rewritten state2)
            (ResultSpecDecl.Ok
              (SpecMaybeDecl.Some
                (ast-decl-def-macro-id name params ret rewritten))
              state2)]
          [(ResultSpecExpr.Err diag) (ResultSpecDecl.Err diag)]))]
    [_ (ResultSpecDecl.Ok (SpecMaybeDecl.Some decl) state)]))

(define (spec-rewrite-decls
  [decls : AstDeclList]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecDecls
  (let
    [count : i64 (ast-decl-list-len (& decls))]
    [cursor : AstDeclList decls]
    [out : AstDeclList (ast-decl-list-with-capacity count)]
    [cur-state : SpecState state]
    [result : ResultSpecDecls
      (ResultSpecDecls.Err
        (box
          (compiler-diagnostic-simple
            "<internal>"
            1
            1
            "specialization rewrite did not finish")))]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast-decl-list-step cursor)
          [(AstDeclListStep.Nil)
            (begin
              (set! result (ResultSpecDecls.Ok out cur-state))
              (set! done true))]
          [(AstDeclListStep.Cons decl rest)
            (match (spec-rewrite-decl decl templates cur-state)
              [(ResultSpecDecl.Ok maybe-decl decl-state)
                (begin
                  (set! cur-state decl-state)
                  (match maybe-decl
                    [(SpecMaybeDecl.None) unit]
                    [(SpecMaybeDecl.Some rewritten-decl)
                      (ast-decl-list-push (&mut out) rewritten-decl)])
                  (set! cursor rest))]
              [(ResultSpecDecl.Err diag)
                (begin
                  (set! result (ResultSpecDecls.Err diag))
                  (set! done true))])]))
      result)))

(define (spec-rewrite-decls-with-paths
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [fallback-path : String]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecDeclsWithPaths
  (let
    [count : i64 (ast-decl-list-len (& decls))]
    [decl-cursor : AstDeclList decls]
    [path-cursor : AstDeclPathList paths]
    [out : AstDeclList (ast-decl-list-with-capacity count)]
    [out-paths : AstDeclPathList (ast-decl-path-list-with-capacity count)]
    [cur-state : SpecState state]
    [result : ResultSpecDeclsWithPaths
      (ResultSpecDeclsWithPaths.Err
        (box
          (compiler-diagnostic-simple
            "<internal>"
            1
            1
            "specialization rewrite with paths did not finish")))]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast-decl-list-step decl-cursor)
          [(AstDeclListStep.Nil)
            (begin
              (set!
                result
                (ResultSpecDeclsWithPaths.Ok out out-paths cur-state))
              (set! done true))]
          [(AstDeclListStep.Cons decl rest)
            (let
              [decl-path : String
                (gen-path-list-head-or path-cursor fallback-path)]
              (match (spec-rewrite-decl decl templates cur-state)
                [(ResultSpecDecl.Ok maybe-decl decl-state)
                  (begin
                    (set! cur-state decl-state)
                    (match maybe-decl
                      [(SpecMaybeDecl.None) unit]
                      [(SpecMaybeDecl.Some rewritten-decl)
                        (begin
                          (ast-decl-list-push (&mut out) rewritten-decl)
                          (ast-decl-path-list-push (&mut out-paths) decl-path))])
                    (set! decl-cursor rest)
                    (set! path-cursor (gen-path-list-tail path-cursor)))]
                [(ResultSpecDecl.Err diag)
                  (begin
                    (set! result (ResultSpecDeclsWithPaths.Err diag))
                    (set! done true))]))]))
      result)))

(define (spec-generated-paths [decls : AstDeclList] [fallback-path : String]) : AstDeclPathList
  (if (string.eq fallback-path "")
    (ast-decl-path-list-new)
    (gen-path-list-for-decls decls fallback-path (ast-decl-path-list-new))))

(define (compiler-specialize-program-active [program : AstProgram]) : ResultSpecProgram
  (match (gen-normalize-program-active program)
    [(ResultGenProgram.Ok normalized)
      (match normalized
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            [templates : SpecTemplateList (spec-collect-templates decls)]
            (match templates
              [(SpecTemplateList.Nil) (ResultSpecProgram.Ok normalized)]
              [_
                (match (spec-rewrite-decls
                  decls
                  (spec-template-env-from-list templates)
                  (SpecState.State
                    (ast-decl-list-new)
                    (spec_string_string_map.with-capacity 64)
                    (ctfe-env-with-reflections
                      (ctfe-reflections-from-program normalized))
                    (ast-node-pool-context-capture-active)))
                  [(ResultSpecDecls.Ok rewritten state)
                    (match state
                      [(SpecState.State generated _ _ _)
                        (ResultSpecProgram.Ok
                          (ast-program
                            (spec-decl-list-append rewritten generated)))])]
                  [(ResultSpecDecls.Err diag) (ResultSpecProgram.Err diag)])]))])]
    [(ResultGenProgram.Err diag) (ResultSpecProgram.Err diag)]))

(define (compiler-specialize-program-with-paths-active
  [program : AstProgram]
  [paths : AstDeclPathList]
  [fallback-path : String]) : ResultSpecProgramWithPaths
  (match (gen-normalize-program-with-paths-active program paths fallback-path)
    [(ResultGenProgramWithPaths.Ok normalized normalized-paths)
      (match normalized
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            [templates : SpecTemplateList (spec-collect-templates decls)]
            (match templates
              [(SpecTemplateList.Nil)
                (ResultSpecProgramWithPaths.Ok normalized normalized-paths)]
              [_
                (match (spec-rewrite-decls-with-paths
                  decls
                  normalized-paths
                  fallback-path
                  (spec-template-env-from-list templates)
                  (SpecState.State
                    (ast-decl-list-new)
                    (spec_string_string_map.with-capacity 64)
                    (ctfe-env-with-reflections
                      (ctfe-reflections-from-program normalized))
                    (ast-node-pool-context-capture-active)))
                  [(ResultSpecDeclsWithPaths.Ok rewritten rewritten-paths state)
                    (match state
                      [(SpecState.State generated _ _ _)
                        (ResultSpecProgramWithPaths.Ok
                          (ast-program
                            (spec-decl-list-append rewritten generated))
                          (spec-decl-path-list-append
                            rewritten-paths
                            (spec-generated-paths generated fallback-path)))])]
                  [(ResultSpecDeclsWithPaths.Err diag)
                    (ResultSpecProgramWithPaths.Err diag)])]))])]
    [(ResultGenProgramWithPaths.Err diag) (ResultSpecProgramWithPaths.Err diag)]))

(define (compiler-specialize-program-with-pools
  [program : AstProgram]
  [pools : AstNodePoolContext]) : ResultSpecProgram
  (let
    [prev : AstNodePoolContext (ast-node-pool-context-capture-active)]
    (begin
      (ast-node-pool-context-install! pools)
      (let
        [result : ResultSpecProgram
          (compiler-specialize-program-active program)]
        (begin
          (ast-node-pool-context-capture-active! pools)
          (ast-node-pool-context-install! prev)
          result)))))

(define (compiler-specialize-program-with-paths-and-pools
  [program : AstProgram]
  [paths : AstDeclPathList]
  [fallback-path : String]
  [pools : AstNodePoolContext]) : ResultSpecProgramWithPaths
  (let
    [prev : AstNodePoolContext (ast-node-pool-context-capture-active)]
    (begin
      (ast-node-pool-context-install! pools)
      (let
        [result : ResultSpecProgramWithPaths
          (compiler-specialize-program-with-paths-active
            program
            paths
            fallback-path)]
        (begin
          (ast-node-pool-context-capture-active! pools)
          (ast-node-pool-context-install! prev)
          result)))))

(define (compiler-specialize-program [program : AstProgram]) : ResultSpecProgram
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultSpecProgram
      (compiler-specialize-program-with-pools program pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (compiler-specialize-program-with-paths
  [program : AstProgram]
  [paths : AstDeclPathList]
  [fallback-path : String]) : ResultSpecProgramWithPaths
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultSpecProgramWithPaths
      (compiler-specialize-program-with-paths-and-pools
        program
        paths
        fallback-path
        pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (compiler-specialize-needed-with-pools
  [program : AstProgram]
  [pools : AstNodePoolContext]) : bool
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (if (gen-decls-needed? decls)
          true
          (match (spec-collect-templates-with-pools pools decls)
            [(SpecTemplateList.Nil) false]
            [_ true])))]))

(define (compiler-specialize-needed? [program : AstProgram]) : bool
  (compiler-specialize-needed-with-pools
    program
    (ast-node-pool-context-capture-active)))

(define (compiler-specialize-decl-list-defines?
  [decls : AstDeclList]
  [name : String]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) false]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Unsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDecl.DefFn fn-name _ _ _ _)
                  (if (string.eq (intern-str fn-name) name)
                    true
                    (compiler-specialize-decl-list-defines? rest name))]
                [(AstDecl.ComptimeDecl _ template-box)
                  (let
                    [template : AstDecl (box-get template-box)]
                    (match template
                      [(AstDecl.DefFn fn-name _ _ _ _)
                        (if (string.eq (intern-str fn-name) name)
                          true
                          (compiler-specialize-decl-list-defines? rest name))]
                      [_ (compiler-specialize-decl-list-defines? rest name)]))]
                [_ (compiler-specialize-decl-list-defines? rest name)]))]
          [(AstDecl.DefFn fn-name _ _ _ _)
            (if (string.eq (intern-str fn-name) name)
              true
              (compiler-specialize-decl-list-defines? rest name))]
          [(AstDecl.ComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDecl.DefFn fn-name _ _ _ _)
                  (if (string.eq (intern-str fn-name) name)
                    true
                    (compiler-specialize-decl-list-defines? rest name))]
                [_ (compiler-specialize-decl-list-defines? rest name)]))]
          [_ (compiler-specialize-decl-list-defines? rest name)]))]))

(define (compiler-specialize-type-param-source) : String
  "(define (alloc [comptime T : type] [n : i64]) : (Array i64)
  (make-array T n))
(define (main) : (Array i64)
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
  (+ (let ([scale : i64 3]) scale) (scale 2 7)))")

(define (compiler-specialize-type-shadow-source) : String
  "(define (pick [comptime T : type] [x : i64]) : i64
  (let ([T : i64 x]) T))
(define (main) : i64 (pick (type i64) 7))")

(define (compiler-specialize-type-param-ok?) : bool
  (match (parse-ast-source (compiler-specialize-type-param-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok specialized)
          (match specialized
            [(AstProgram.Program decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                (and
                  (not (compiler-specialize-decl-list-defines? decls "alloc"))
                  (compiler-specialize-decl-list-defines?
                    decls
                    "__tl_specialized_alloc_type_i64_none")))])]
        [(ResultSpecProgram.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-specialize-runtime-type-use-rejected?) : bool
  (match (parse-ast-source (compiler-specialize-runtime-type-use-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok _) false]
        [(ResultSpecProgram.Err _) true])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-specialize-template-shadow-ok?) : bool
  (match (parse-ast-source (compiler-specialize-template-shadow-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok _) true]
        [(ResultSpecProgram.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-specialize-template-shadow-sibling-ok?) : bool
  (match (parse-ast-source (compiler-specialize-template-shadow-sibling-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok specialized)
          (match specialized
            [(AstProgram.Program decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                [original : bool
                  (compiler-specialize-decl-list-defines? decls "scale")]
                [generated : bool
                  (compiler-specialize-decl-list-defines?
                    decls
                    "__tl_specialized_scale_i64_2_none")]
                (and (not original) generated))])]
        [(ResultSpecProgram.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-specialize-type-shadow-ok?) : bool
  (match (parse-ast-source (compiler-specialize-type-shadow-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok specialized)
          (match specialized
            [(AstProgram.Program decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                (compiler-specialize-decl-list-defines?
                  decls
                  "__tl_specialized_pick_type_i64_none"))])]
        [(ResultSpecProgram.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-specialize-raw-pointer-type-ok?) : bool
  (let
    [subs : SpecTypeSubst
      (spec-type-subst-cons "T" (AstType.I64) SpecTypeSubst.Nil)]
    (and
      (string.eq (spec-type-key (ast-ty-ptr (AstType.I64))) "ptr_i64")
      (string.eq
        (spec-type-key (ast-ty-mut-ptr (ast-ty-ptr (AstType.U8))))
        "mutptr_ptr_u8")
      (ctfe-type-eq
        (spec-substitute-type (ast-ty-mut-ptr (AstType.Var cbi.compiler-builtin-id-fix-T)) subs)
        (ast-ty-mut-ptr (AstType.I64))))))

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
        (CompilerCtfeValue.Type (AstType.I64))
        (SpecValueList.Nil))]
    [vals-bool : SpecValueList
      (spec-value-cons
        (CompilerCtfeValue.Type (AstType.Bool))
        (SpecValueList.Nil))]
    [vals-multi : SpecValueList
      (spec-value-cons
        (CompilerCtfeValue.Type (AstType.I64))
        (spec-value-cons (CompilerCtfeValue.I64 5) (SpecValueList.Nil)))]
    [vals-string : SpecValueList
      (spec-value-cons (CompilerCtfeValue.String "a b") (SpecValueList.Nil))]
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
      (string.eq (spec-value-key (CompilerCtfeValue.I64 (- 0 3))) "i64_m3")
      (string.eq
        (spec-specialized-name "name" vals-string)
        "__tl_specialized_name_string_3_97_32_98_none"))))

;: Count function declarations named `name` in `decls` (specialized decls are
;: emitted as ordinary `AstDecl.DefFn`s, so reuse means a count of exactly 1).
(define (compiler-specialize-decl-list-count-defs
  [decls : AstDeclList]
  [name : String]) : i64
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) 0]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Unsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDecl.DefFn fn-name _ _ _ _)
                  (if (string.eq (intern-str fn-name) name)
                    (+ 1 (compiler-specialize-decl-list-count-defs rest name))
                    (compiler-specialize-decl-list-count-defs rest name))]
                [(AstDecl.ComptimeDecl _ template-box)
                  (let
                    [template : AstDecl (box-get template-box)]
                    (match template
                      [(AstDecl.DefFn fn-name _ _ _ _)
                        (if (string.eq (intern-str fn-name) name)
                          (+
                            1
                            (compiler-specialize-decl-list-count-defs rest name))
                          (compiler-specialize-decl-list-count-defs rest name))]
                      [_ (compiler-specialize-decl-list-count-defs rest name)]))]
                [_ (compiler-specialize-decl-list-count-defs rest name)]))]
          [(AstDecl.DefFn fn-name _ _ _ _)
            (if (string.eq (intern-str fn-name) name)
              (+ 1 (compiler-specialize-decl-list-count-defs rest name))
              (compiler-specialize-decl-list-count-defs rest name))]
          [(AstDecl.ComptimeDecl _ inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDecl.DefFn fn-name _ _ _ _)
                  (if (string.eq (intern-str fn-name) name)
                    (+ 1 (compiler-specialize-decl-list-count-defs rest name))
                    (compiler-specialize-decl-list-count-defs rest name))]
                [_ (compiler-specialize-decl-list-count-defs rest name)]))]
          [_ (compiler-specialize-decl-list-count-defs rest name)]))]))

(define (compiler-specialize-decl-list-count-visible
  [decls : AstDeclList]
  [name : String]) : i64
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) 0]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
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
  "(define (alloc [comptime T : type] [n : i64]) : (Array i64)
  (make-array T n))
(define (main) : (Array i64)
  (begin (alloc (type i64) 4) (alloc (type i64) 8)))")

;: Specialization reuse (mirrors src/specialize.rs reuse coverage): two
;: identical `alloc (type i64)` requests collapse to a single shared
;: `__tl_specialized_alloc_type_i64_none` decl (the cache dedups by key) and the
;: `alloc` template is removed.
(define (compiler-specialize-reuse-ok?) : bool
  (match (parse-ast-source (compiler-specialize-reuse-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok specialized)
          (match specialized
            [(AstProgram.Program decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                (and
                  (not (compiler-specialize-decl-list-defines? decls "alloc"))
                  (=
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "__tl_specialized_alloc_type_i64_none")
                    1)))])]
        [(ResultSpecProgram.Err _) false])]
    [(ResultAstProgram.Err _) false]))

;: Type substitution (mirrors src/specialize.rs substitution coverage):
;: `spec-substitute-type` replaces a mapped type variable with its bound type,
;: recurses through compound types (Ptr/DynArray/function), and leaves an
;: unmapped variable unchanged (the SpecMaybeString.None lookup branch). Complements
;: the single MutPtr case embedded in `compiler-specialize-raw-pointer-type-ok?`.
(define (compiler-specialize-subst-ok?) : bool
  (let
    [subs : SpecTypeSubst
      (spec-type-subst-cons "T" (AstType.I64) SpecTypeSubst.Nil)]
    (and
      (string.eq
        (spec-type-key (spec-substitute-type (AstType.Var cbi.compiler-builtin-id-fix-T) subs))
        "i64")
      (string.eq
        (spec-type-key
          (spec-substitute-type (ast-ty-ptr (AstType.Var cbi.compiler-builtin-id-fix-T)) subs))
        "ptr_i64")
      (string.eq
        (spec-type-key
          (spec-substitute-type
            (ast-ty-dyn-array (AstType.Var cbi.compiler-builtin-id-fix-T))
            subs))
        "dynarray_i64")
      (string.eq
        (spec-type-key
          (spec-substitute-type
            (ast-ty-func
              (ast-type-cons (AstType.Var cbi.compiler-builtin-id-fix-T) (ast-type-list-new))
              (AstType.Var cbi.compiler-builtin-id-fix-T))
            subs))
        "fn_i64_nil_to_i64")
      (string.eq
        (spec-type-key (spec-substitute-type (AstType.Var cbi.compiler-builtin-id-fix-U) subs))
        "var_U"))))

;: Value (comptime-argument) substitution (mirrors src/specialize.rs
;: substitution coverage): `spec-substitute-values-expr` replaces a variable
;: bound to a comptime value with that value's literal, leaves unmapped
;: variables and literals unchanged, and recurses through compound expressions.
(define (compiler-specialize-value-subst-ok?) : bool
  (let
    [subs : SpecValueSubst
      (spec-value-subst-cons "x" (CompilerCtfeValue.I64 5) SpecValueSubst.Nil)]
    (and
      ;; mapped variable x -> integer literal 5
      (match (spec-substitute-values-expr (AstExpr.Var cbi.compiler-builtin-id-fix-x) subs)
        [(ResultSpecSubExpr.Ok e)
          (match (ast-node-get e)
            [(AstExpr.Literal lit)
              (match lit
                [(AstLiteral.Int n _) (= n 5)]
                [_ false])]
            [_ false])]
        [(ResultSpecSubExpr.Err _) false])
      ;; unmapped variable y -> unchanged
      (match (spec-substitute-values-expr (AstExpr.Var cbi.compiler-builtin-id-fix-y) subs)
        [(ResultSpecSubExpr.Ok e)
          (match (ast-node-get e)
            [(AstExpr.Var name) (string.eq (intern-str name) "y")]
            [_ false])]
        [(ResultSpecSubExpr.Err _) false])
      ;; recursion through `if`: x in the condition becomes 5, unmapped y stays
      (match (spec-substitute-values-expr
        (AstExpr.If
          (ast-node-push (AstExpr.Var cbi.compiler-builtin-id-fix-x))
          (ast-node-push (AstExpr.Literal (ast-lit-int 1)))
          (ast-node-push (AstExpr.Var cbi.compiler-builtin-id-fix-y)))
        subs)
        [(ResultSpecSubExpr.Ok e)
          (match (ast-node-get e)
            [(AstExpr.If cond-box _ else-branch-box)
              (let
                [cond : AstExpr (ast-node-get cond-box)]
                [else-branch : AstExpr (ast-node-get else-branch-box)]
                (and
                  (match cond
                    [(AstExpr.Literal lit)
                      (match lit
                        [(AstLiteral.Int n _) (= n 5)]
                        [_ false])]
                    [_ false])
                  (match else-branch
                    [(AstExpr.Var name) (string.eq (intern-str name) "y")]
                    [_ false])))]
            [_ false])]
        [(ResultSpecSubExpr.Err _) false]))))

(define (compiler-specialize-boxed-tails-ok?) : bool
  (let
    [templates : SpecTemplateList
      (spec-template-cons
        (SpecTemplate.Item
          "first"
          (ast-param-list-new)
          (AstType.I64)
          (AstExpr.Literal (ast-lit-int 1)))
        (spec-template-cons
          (SpecTemplate.Item
            "second"
            (ast-param-list-new)
            (AstType.Bool)
            (AstExpr.Literal (AstLiteral.Bool true)))
          SpecTemplateList.Nil))]
    [template-env : SpecTemplateEnv (spec-template-env-from-list templates)]
    [cache : spec_string_string_map.Map
      (let
        [seed-cache : spec_string_string_map.Map
          (spec_string_string_map.with-capacity 8)]
        (begin
          (spec_string_string_map.insert
            (&mut seed-cache)
            "two"
            "generated-two")
          (spec_string_string_map.insert
            (&mut seed-cache)
            "one"
            "generated-one")
          seed-cache))]
    [values : SpecValueList
      (spec-value-cons
        (CompilerCtfeValue.I64 1)
        (spec-value-cons (CompilerCtfeValue.Bool true) SpecValueList.Nil))]
    [value-subs : SpecValueSubst
      (spec-value-subst-cons
        "x"
        (CompilerCtfeValue.I64 1)
        (spec-value-subst-cons
          "flag"
          (CompilerCtfeValue.Bool true)
          SpecValueSubst.Nil))]
    [type-subs : SpecTypeSubst
      (spec-type-subst-cons
        "T"
        (AstType.I64)
        (spec-type-subst-cons "U" (AstType.Bool) SpecTypeSubst.Nil))]
    (and
      (match (spec-template-lookup template-env "second")
        [(SpecMaybeTemplate.Some template)
          (match template
            [(SpecTemplate.Item name _ _ _) (string.eq name "second")])]
        [(SpecMaybeTemplate.None) false])
      (match (spec-cache-lookup cache "two")
        [(SpecMaybeString.Some name) (string.eq name "generated-two")]
        [(SpecMaybeString.None) false])
      (string.eq (spec-values-key values) "i64_1_bool_1_none")
      (match (spec-value-subst-value value-subs "flag")
        [(CompilerCtfeValue.Bool flag) flag]
        [_ false])
      (ctfe-type-eq (spec-type-subst-type type-subs "U") (AstType.Bool)))))

(define (compiler-specialize-reflection-string-param-source) : String
  "(defstruct Point (x i64))
(define (tag-helper [comptime key : String] [x : i64]) : i64 x)
(define (main) : i64 (tag-helper (type-key (type Point)) 7))")

(define (compiler-specialize-reflection-string-param-ok?) : bool
  (match (parse-ast-source (compiler-specialize-reflection-string-param-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok specialized)
          (match specialized
            [(AstProgram.Program decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                (compiler-specialize-decl-list-defines?
                  decls
                  "__tl_specialized_tag-helper_string_12_115_116_114_117_99_116_95_80_111_105_110_116_none"))])]
        [(ResultSpecProgram.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-reuse-source) : String
  "(comptime-decl (:generated sample-family Box_String \"String\")
  (defstruct Box_String (value String)))
(comptime-decl (:generated sample-family Box_String \"String\")
  (defstruct Box_String (value String)))")

(define (compiler-generated-decl-function-reuse-source) : String
  "(comptime-decl (:generated function-family make-box-string \"String\")
  (define (make-box-string [value : String]) : String value))
(comptime-decl (:generated function-family make-box-string \"String\")
  (define (make-box-string [value : String]) : String value))")

(define (compiler-generated-decl-incompatible-source) : String
  "(comptime-decl (:generated sample-family Box_String \"String\")
  (defstruct Box_String (value String)))
(comptime-decl (:generated sample-family Box_String \"String\")
  (defstruct Box_String (value i64)))")

(define (compiler-generated-decl-item-mismatch-source) : String
  "(comptime-decl (:generated sample-family Expected \"String\")
  (defstruct Actual (value String)))")

(define (compiler-generated-decl-non-string-key-source) : String
  "(comptime-decl (:generated sample-family Box_String 7)
  (defstruct Box_String (value String)))")

(define (compiler-generated-decl-duplicate-visible-source) : String
  "(comptime-decl (:generated sample-family Box_String \"String\")
  (defstruct Box_String (value String)))
(comptime-decl (:generated sample-family Box_String \"Bytes\")
  (defstruct Box_String (value String)))")

(define (compiler-generated-decl-expected-string-key) : String
  (gen-full-key
    ""
    "sample-family"
    "Box_String"
    (string.append (spec-string-key "String") "_none")))

(define (compiler-generated-decl-cross-module-reuse-source) : String
  "(module sample.family)
(comptime-decl (:generated sample-family Box_String \"String\")
  (defstruct Box_String (value String)))
(module app)
(module sample.family)
(comptime-decl (:generated sample-family Box_String \"String\")
  (defstruct Box_String (value String)))")

(define (compiler-generated-decl-cross-module-distinct-source) : String
  "(module sample.left)
(comptime-decl (:generated sample-family Box_String \"String\")
  (defstruct Box_String (value String)))
(module sample.right)
(comptime-decl (:generated sample-family Box_String \"String\")
  (defstruct Box_String (value String)))")

(define (compiler-generated-decl-visible-count
  [source : String]
  [name : String]) : i64
  (match (parse-ast-source source)
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok normalized)
          (match normalized
            [(AstProgram.Program decls-box)
              (compiler-specialize-decl-list-count-visible
                (box-get decls-box)
                name)])]
        [(ResultSpecProgram.Err _) -1])]
    [(ResultAstProgram.Err _) -1]))

(define (compiler-generated-decl-reuse-ok?) : bool
  (match (parse-ast-source (compiler-generated-decl-reuse-source))
    [(ResultAstProgram.Ok program)
      (and
        (compiler-specialize-needed? program)
        (match (compiler-specialize-program program)
          [(ResultSpecProgram.Ok normalized)
            (match normalized
              [(AstProgram.Program decls-box)
                (let
                  [decls : AstDeclList (box-get decls-box)]
                  (=
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "Box_String")
                    1))])]
          [(ResultSpecProgram.Err _) false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-function-reuse-ok?) : bool
  (match (parse-ast-source (compiler-generated-decl-function-reuse-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok normalized)
          (match normalized
            [(AstProgram.Program decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                (=
                  (compiler-specialize-decl-list-count-defs
                    decls
                    "make-box-string")
                  1))])]
        [(ResultSpecProgram.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-incompatible-rejected?) : bool
  (match (parse-ast-source (compiler-generated-decl-incompatible-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok _) false]
        [(ResultSpecProgram.Err _) true])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-incompatible-note-ok?) : bool
  (match (parse-ast-source (compiler-generated-decl-incompatible-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok _) false]
        [(ResultSpecProgram.Err diag)
          (match (compiler-diagnostic-notes (box-get diag))
            [(CompilerDiagnosticNoteCons note _)
              (string.eq
                note
                (string.append
                  "generated identity: "
                  (compiler-generated-decl-expected-string-key)))]
            [(CompilerDiagnosticNoteNil) false])])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-item-mismatch-rejected?) : bool
  (match (parse-ast-source (compiler-generated-decl-item-mismatch-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok _) false]
        [(ResultSpecProgram.Err _) true])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-non-string-key-rejected?) : bool
  (match (parse-ast-source (compiler-generated-decl-non-string-key-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok _) false]
        [(ResultSpecProgram.Err _) true])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-duplicate-visible-left-for-symbols?) : bool
  (match (parse-ast-source (compiler-generated-decl-duplicate-visible-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok normalized)
          (match normalized
            [(AstProgram.Program decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                (=
                  (compiler-specialize-decl-list-count-visible
                    decls
                    "Box_String")
                  2))])]
        [(ResultSpecProgram.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-generated-decl-cross-module-reuse-ok?) : bool
  (=
    (compiler-generated-decl-visible-count
      (compiler-generated-decl-cross-module-reuse-source)
      "Box_String")
    1))

(define (compiler-generated-decl-cross-module-distinct-ok?) : bool
  (=
    (compiler-generated-decl-visible-count
      (compiler-generated-decl-cross-module-distinct-source)
      "Box_String")
    2))

(define (compiler-generated-decl-origin-preserved-ok?) : bool
  (match (parse-ast-source (compiler-generated-decl-reuse-source))
    [(ResultAstProgram.Ok program)
      (match (compiler-specialize-program program)
        [(ResultSpecProgram.Ok normalized)
          (match normalized
            [(AstProgram.Program decls-box)
              (match (ast-decl-list-step (box-get decls-box))
                [(AstDeclListStep.Cons decl _)
                  (match decl
                    [(AstDecl.ComptimeDecl meta template-box)
                      (and
                        (match meta
                          [(AstGeneratedDeclMeta.Some generator item _ key)
                            (and
                              (string.eq generator "sample-family")
                              (string.eq item "Box_String")
                              (string.eq
                                key
                                (compiler-generated-decl-expected-string-key)))]
                          [(AstGeneratedDeclMeta.No) false])
                        (match (box-get template-box)
                          [(AstDecl.DefStruct name _ _ _)
                            (string.eq (intern-str name) "Box_String")]
                          [_ false]))]
                    [_ false])]
                [(AstDeclListStep.Nil) false])])]
        [(ResultSpecProgram.Err _) false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-generated-registry-map-ok?) : bool
  (let
    [decl : AstDecl
      (ast-decl-def-struct
        "RegistryBox"
        AstStructRepr.Default
        AstStructCleanup.No
        (ast-field-def-list-new))]
    [registry : GenRegistry
      (gen-registry-insert (gen-registry-empty) "generated-key" decl)]
    (match (gen-registry-lookup registry "generated-key")
      [(GenMaybeEntry.Some found) (gen-decl-eq? found decl)]
      [(GenMaybeEntry.None) false])))

(define (compiler-specialize-self-test) : i64
  (begin
    (unless (compiler-specialize-type-param-ok?) (return 0))
    (unless (compiler-specialize-runtime-type-use-rejected?) (return 0))
    (unless (compiler-specialize-template-shadow-ok?) (return 0))
    (unless (compiler-specialize-template-shadow-sibling-ok?) (return 0))
    (unless (compiler-specialize-type-shadow-ok?) (return 0))
    (unless (compiler-specialize-raw-pointer-type-ok?) (return 0))
    (unless (compiler-specialize-name-key-ok?) (return 0))
    (unless (compiler-specialize-reuse-ok?) (return 0))
    (unless (compiler-specialize-subst-ok?) (return 0))
    (unless (compiler-specialize-value-subst-ok?) (return 0))
    (unless (compiler-specialize-boxed-tails-ok?) (return 0))
    (unless (compiler-specialize-reflection-string-param-ok?) (return 0))
    (unless (compiler-generated-decl-reuse-ok?) (return 0))
    (unless (compiler-generated-decl-function-reuse-ok?) (return 0))
    (unless (compiler-generated-decl-incompatible-rejected?) (return 0))
    (unless (compiler-generated-decl-incompatible-note-ok?) (return 0))
    (unless (compiler-generated-decl-item-mismatch-rejected?) (return 0))
    (unless (compiler-generated-decl-non-string-key-rejected?) (return 0))
    (unless
      (compiler-generated-decl-duplicate-visible-left-for-symbols?)
      (return 0))
    (unless (compiler-generated-decl-cross-module-reuse-ok?) (return 0))
    (unless (compiler-generated-decl-cross-module-distinct-ok?) (return 0))
    (unless (compiler-generated-decl-origin-preserved-ok?) (return 0))
    (unless (compiler-generated-registry-map-ok?) (return 0))
    1))