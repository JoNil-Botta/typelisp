;; compiler_specialize.tl - Selfhost comptime function specialization (#832).
(import stdlib.array)
(import "compiler_parse_core.tl")
(import "compiler_ctfe.tl")
(import "compiler_diagnostic.tl")
(import "compiler_float.tl")
(import stdlib.string)
(import stdlib.hashmap)

(defstruct GenRegistry
  (index hashmap.StringI64Map)
  (decls (Array AstDecl))
  (len i64))

(defenum SpecTemplate
  (SpecTemplate String AstParamList AstType AstExpr))

(defenum SpecTemplateList
  (SpecTemplateNil)
  (SpecTemplateCons SpecTemplate (Box SpecTemplateList)))

(defenum SpecTemplateShadowList
  (SpecTemplateShadowNil)
  (SpecTemplateShadowCons String (Box SpecTemplateShadowList)))

(defenum SpecMaybeTemplate
  (SpecNoTemplate)
  (SpecSomeTemplate SpecTemplate))

(defstruct SpecTemplateEnv
  (index hashmap.StringI64Map)
  (values (Array SpecMaybeTemplate))
  (shadowed SpecTemplateShadowList))

;; #2613: the specialization cache (key -> generated function name) is a
;; generated hashmap.StringStringMap; the former SpecCache linked list made every
;; lookup a linear scan.
(defenum SpecState
  (SpecState AstDeclList hashmap.StringStringMap CtfeEnv AstNodePoolContext))

(defenum SpecValueList
  (SpecValueNil)
  (SpecValueCons CompilerCtfeValue (Box SpecValueList)))

(defenum SpecValueSubst
  (SpecValueSubstNil)
  (SpecValueSubstCons String CompilerCtfeValue (Box SpecValueSubst)))

(defenum SpecTypeSubst
  (SpecTypeSubstNil)
  (SpecTypeSubstCons String AstType (Box SpecTypeSubst)))

(define (spec-template-cons [head : SpecTemplate] [rest : SpecTemplateList]) : SpecTemplateList
  (SpecTemplateCons head (box rest)))

(define (spec-value-cons [head : CompilerCtfeValue] [rest : SpecValueList]) : SpecValueList
  (SpecValueCons head (box rest)))

(define (spec-value-subst-cons
  [key : String]
  [value : CompilerCtfeValue]
  [rest : SpecValueSubst]) : SpecValueSubst
  (SpecValueSubstCons key value (box rest)))

(define (spec-type-subst-cons
  [key : String]
  [ty : AstType]
  [rest : SpecTypeSubst]) : SpecTypeSubst
  (SpecTypeSubstCons key ty (box rest)))

(defenum SpecMaybeString
  (SpecNoString)
  (SpecSomeString String))

(defenum SpecMaybeDecl
  (SpecNoDecl)
  (SpecSomeDecl AstDecl))

(defenum ResultSpecProgram
  (OkSpecProgram AstProgram)
  (ErrSpecProgram (Box CompilerDiagnostic)))

(defenum ResultSpecProgramWithPaths
  (OkSpecProgramWithPaths AstProgram AstDeclPathList)
  (ErrSpecProgramWithPaths (Box CompilerDiagnostic)))

(defenum ResultSpecDecls
  (OkSpecDecls AstDeclList SpecState)
  (ErrSpecDecls (Box CompilerDiagnostic)))

(defenum ResultSpecDeclsWithPaths
  (OkSpecDeclsWithPaths AstDeclList AstDeclPathList SpecState)
  (ErrSpecDeclsWithPaths (Box CompilerDiagnostic)))

(defenum ResultSpecDecl
  (OkSpecDecl SpecMaybeDecl SpecState)
  (ErrSpecDecl (Box CompilerDiagnostic)))

(defenum ResultSpecExpr
  (OkSpecExpr i64 SpecState)
  (ErrSpecExpr (Box CompilerDiagnostic)))

(defenum ResultSpecExprList
  (OkSpecExprList AstExprList SpecState)
  (ErrSpecExprList (Box CompilerDiagnostic)))

(defenum ResultSpecLetBindingList
  (OkSpecLetBindingList AstLetBindingList SpecState)
  (ErrSpecLetBindingList (Box CompilerDiagnostic)))

(defenum ResultSpecMatchArmList
  (OkSpecMatchArmList AstMatchArmList SpecState)
  (ErrSpecMatchArmList (Box CompilerDiagnostic)))

(defenum ResultSpecArgs
  (OkSpecArgs SpecValueList AstExprList SpecState)
  (ErrSpecArgs (Box CompilerDiagnostic)))

(defenum ResultSpecEnsure
  (OkSpecEnsure String SpecState)
  (ErrSpecEnsure (Box CompilerDiagnostic)))

(defenum ResultSpecBuild
  (OkSpecBuild AstParamList SpecValueSubst SpecTypeSubst)
  (ErrSpecBuild (Box CompilerDiagnostic)))

(defenum ResultSpecSubExpr
  (OkSpecSubExpr i64)
  (ErrSpecSubExpr (Box CompilerDiagnostic)))

(defenum ResultSpecSubExprList
  (OkSpecSubExprList AstExprList)
  (ErrSpecSubExprList (Box CompilerDiagnostic)))

(defenum ResultSpecSubLetBindingList
  (OkSpecSubLetBindingList AstLetBindingList)
  (ErrSpecSubLetBindingList (Box CompilerDiagnostic)))

(defenum ResultSpecSubMatchArmList
  (OkSpecSubMatchArmList AstMatchArmList)
  (ErrSpecSubMatchArmList (Box CompilerDiagnostic)))

(defenum GenMaybeEntry
  (GenNoEntry)
  (GenSomeEntry AstDecl))

(defenum ResultGenKey
  (OkGenKey String i64)
  (ErrGenKey (Box CompilerDiagnostic)))

(defenum ResultGenDecl
  (OkGenDecl AstDeclList GenRegistry String)
  (ErrGenDecl (Box CompilerDiagnostic)))

(defenum ResultGenDecls
  (OkGenDecls AstDeclList GenRegistry String)
  (ErrGenDecls (Box CompilerDiagnostic)))

(defenum ResultGenProgram
  (OkGenProgram AstProgram)
  (ErrGenProgram (Box CompilerDiagnostic)))

(defenum ResultGenDeclsWithPaths
  (OkGenDeclsWithPaths AstDeclList AstDeclPathList GenRegistry String)
  (ErrGenDeclsWithPaths (Box CompilerDiagnostic)))

(defenum ResultGenProgramWithPaths
  (OkGenProgramWithPaths AstProgram AstDeclPathList)
  (ErrGenProgramWithPaths (Box CompilerDiagnostic)))

(define (spec-diagnostic-at-expr [expr : AstExpr] [message : String]) : CompilerDiagnostic
  (match expr
    [(AstExprSpanned _ span)
      (compiler-diagnostic-from-ast-span "" span message)]
    [_ (compiler-diagnostic-at-start "" message)]))

(define (spec-param-comptime? [param : AstParam]) : bool
  (match param
    [(AstParam _ _ is-comptime) is-comptime]))

(define (spec-param-name [param : AstParam]) : String
  (match param
    [(AstParam name _ _) (intern-str name)]))

(define (spec-param-type [param : AstParam]) : AstType
  (match param
    [(AstParam _ ty _) ty]))

(define (spec-state-ctfe-env [state : SpecState]) : CtfeEnv
  (match state
    [(SpecState _ _ env _) env]))

(define (spec-state-pools [state : SpecState]) : AstNodePoolContext
  (match state
    [(SpecState _ _ _ pools) pools]))

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
  (match ty
    [(AstTyVar name) (= name (intern "type"))]
    [_ false]))

(define (spec-param-list-has-comptime? [params : AstParamList]) : bool
  (match params
    [(AstParamNil) false]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (if (spec-param-comptime? param)
          true
          (spec-param-list-has-comptime? rest)))]))

(define (spec-template-shadow-contains?
  [shadowed : SpecTemplateShadowList]
  [name : String]) : bool
  (match shadowed
    [(SpecTemplateShadowNil) false]
    [(SpecTemplateShadowCons shadow-name rest)
      (if (string.string-eq shadow-name name)
        true
        (spec-template-shadow-contains? (box-get rest) name))]))

(define (spec-template-list-count [templates : SpecTemplateList]) : i64
  (match templates
    [(SpecTemplateNil) 0]
    [(SpecTemplateCons _ rest) (+ 1 (spec-template-list-count (box-get rest)))]))

(define (spec-template-values-fill-empty
  [values : (Array SpecMaybeTemplate)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array.array-set! values index (SpecNoTemplate))
      (spec-template-values-fill-empty values (+ index 1) count))))

(define (spec-template-index-build
  [templates : SpecTemplateList]
  [index : hashmap.StringI64Map]
  [values : (Array SpecMaybeTemplate)]
  [slot : i64]) : hashmap.StringI64Map
  (match templates
    [(SpecTemplateNil) index]
    [(SpecTemplateCons template rest)
      (match template
        [(SpecTemplate name _ _ _)
          (if (hashmap.string-i64-map-contains? index name)
            (spec-template-index-build (box-get rest) index values slot)
            (begin
              (array.array-set! values slot (SpecSomeTemplate template))
              (spec-template-index-build
                (box-get rest)
                (hashmap.string-i64-map-put index name slot)
                values
                (+ slot 1))))])]))

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
          (hashmap.string-i64-map-with-capacity (+ (* count 2) 16))
          values
          0)
        values
        SpecTemplateShadowNil))))

(define (spec-template-lookup [templates : SpecTemplateEnv] [name : String]) : SpecMaybeTemplate
  (if (spec-template-shadow-contains? (struct-get templates shadowed) name)
    (SpecNoTemplate)
    (match (hashmap.string-i64-map-get (struct-get templates index) name)
      [(hashmap.StringI64MapFound slot)
        (array.array-ref (struct-get templates values) slot)]
      [(hashmap.StringI64MapMissing) (SpecNoTemplate)])))

(define (spec-template-env-shadow-name
  [templates : SpecTemplateEnv]
  [name : String]) : SpecTemplateEnv
  (SpecTemplateEnv
    (struct-get templates index)
    (struct-get templates values)
    (SpecTemplateShadowCons name (box (struct-get templates shadowed)))))

(define (spec-template-env-shadow-params
  [templates : SpecTemplateEnv]
  [params : AstParamList]) : SpecTemplateEnv
  (match params
    [(AstParamNil) templates]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (spec-template-env-shadow-params
          (spec-template-env-shadow-name templates (spec-param-name param))
          rest))]))

(define (spec-template-env-shadow-let-binding-names
  [templates : SpecTemplateEnv]
  [bindings : AstLetBindingList]) : SpecTemplateEnv
  (match bindings
    [(AstLetBindingNil) templates]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name _ _)
            (spec-template-env-shadow-let-binding-names
              (spec-template-env-shadow-name templates (intern-str name))
              rest)]))]))

(define (spec-template-env-shadow-pattern
  [templates : SpecTemplateEnv]
  [pattern : AstPattern]) : SpecTemplateEnv
  (match pattern
    [(AstPatVar name _)
      (spec-template-env-shadow-name templates (intern-str name))]
    [(AstPatTuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-template-env-shadow-pattern-list templates patterns))]
    [(AstPatWildcard) templates]
    [(AstPatBinding name)
      (spec-template-env-shadow-name templates (intern-str name))]
    [(AstPatVariant _ patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-template-env-shadow-pattern-list templates patterns))]
    [(AstPatLiteral _) templates]))

(define (spec-template-env-shadow-pattern-list
  [templates : SpecTemplateEnv]
  [patterns : AstPatternList]) : SpecTemplateEnv
  (match patterns
    [(AstPatternNil) templates]
    [(AstPatternCons pattern rest)
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest : AstPatternList (box-get rest)]
        (spec-template-env-shadow-pattern-list
          (spec-template-env-shadow-pattern templates pattern)
          rest))]))

(define (spec-collect-templates [decls : AstDeclList]) : SpecTemplateList
  (match decls
    [(AstDeclNil) (SpecTemplateNil)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclUnsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDeclDefFn name params ret body-box _)
                  (let
                    [body : AstExpr (ast-node-get body-box)]
                    (if (spec-param-list-has-comptime? params)
                      (spec-template-cons
                        (SpecTemplate (intern-str name) params ret body)
                        (spec-collect-templates rest))
                      (spec-collect-templates rest)))]
                [_ (spec-collect-templates rest)]))]
          [(AstDeclDefFn name params ret body-box _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (if (spec-param-list-has-comptime? params)
                (spec-template-cons
                  (SpecTemplate (intern-str name) params ret body)
                  (spec-collect-templates rest))
                (spec-collect-templates rest)))]
          [_ (spec-collect-templates rest)]))]))

(define (spec-cache-lookup [cache : hashmap.StringStringMap] [key : String]) : SpecMaybeString
  (match (hashmap.string-string-map-get cache key)
    [(hashmap.StringStringMapFound name) (SpecSomeString name)]
    [(hashmap.StringStringMapMissing) (SpecNoString)]))

(define (spec-decl-list-append-one [decls : AstDeclList] [decl : AstDecl]) : AstDeclList
  (match decls
    [(AstDeclNil) (ast-decl-cons decl AstDeclNil)]
    [(AstDeclCons head rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (ast-decl-cons head (spec-decl-list-append-one rest decl)))]))

(define (spec-decl-list-append [front : AstDeclList] [back : AstDeclList]) : AstDeclList
  (match front
    [(AstDeclNil) back]
    [(AstDeclCons head rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (ast-decl-cons head (spec-decl-list-append rest back)))]))

(define (spec-decl-path-list-append
  [front : AstDeclPathList]
  [back : AstDeclPathList]) : AstDeclPathList
  (match front
    [(AstDeclPathNil) back]
    [(AstDeclPathCons head rest)
      (let
        [rest : AstDeclPathList (box-get rest)]
        (ast-decl-path-cons head (spec-decl-path-list-append rest back)))]))

(define (gen-single-decl-list [decl : AstDecl]) : AstDeclList
  (ast-decl-cons decl AstDeclNil))

(define (spec-int-key [n : i64]) : String
  (if (< n 0)
    (string.string-append "m" (string.int->string (- 0 n)))
    (string.int->string n)))

(define (spec-string-key-from [text : String] [idx : i64] [n : i64]) : String
  (if (>= idx n)
    ""
    (string.string-append
      "_"
      (string.string-append
        (string.int->string (cast (string.string-ref text idx) : i64))
        (spec-string-key-from text (+ idx 1) n)))))

(define (spec-string-key [text : String]) : String
  (let
    [n : i64 (string.string-length text)]
    (string.string-append
      "string_"
      (string.string-append
        (string.int->string n)
        (spec-string-key-from text 0 n)))))

(define (spec-type-list-key [types : AstTypeList]) : String
  (match types
    [(AstTypeNil) "nil"]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ty-node-get head)]
        [rest : AstTypeList (box-get rest)]
        (string.string-append
          (spec-type-key head)
          (string.string-append "_" (spec-type-list-key rest))))]))

(define (spec-lifetime-list-key [lifetimes : AstLifetimeList]) : String
  (match lifetimes
    [(AstLifetimeNil) "nil"]
    [(AstLifetimeCons head rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (string.string-append
          head
          (string.string-append "_" (spec-lifetime-list-key rest))))]))

(define (spec-type-key [ty : AstType]) : String
  (match ty
    [(AstTyI64) "i64"]
    [(AstTyI32) "i32"]
    [(AstTyI16) "i16"]
    [(AstTyI8) "i8"]
    [(AstTyU64) "u64"]
    [(AstTyU32) "u32"]
    [(AstTyU16) "u16"]
    [(AstTyU8) "u8"]
    [(AstTyF64) "f64"]
    [(AstTyF32) "f32"]
    [(AstTyBool) "bool"]
    [(AstTyChar) "char"]
    [(AstTyString) "String"]
    [(AstTyStr) "str"]
    [(AstTyBytes) "bytes"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyExpr) "Expr"]
    [(AstTyExprList) "ExprList"]
    [(AstTyFunc args ret)
      (string.string-append
        "fn_"
        (string.string-append
          (spec-type-list-key (box-get args))
          (string.string-append "_to_" (spec-type-key (ty-node-get ret)))))]
    [(AstTyTuple elems)
      (string.string-append "tuple_" (spec-type-list-key (box-get elems)))]
    [(AstTyArray elem count)
      (string.string-append
        "array_"
        (string.string-append
          (spec-type-key (ty-node-get elem))
          (string.string-append "_" (spec-int-key count))))]
    [(AstTyDynArray elem)
      (string.string-append "dynarray_" (spec-type-key (ty-node-get elem)))]
    [(AstTyBox elem)
      (string.string-append "box_" (spec-type-key (ty-node-get elem)))]
    [(AstTyPtr elem)
      (string.string-append "ptr_" (spec-type-key (ty-node-get elem)))]
    [(AstTyMutPtr elem)
      (string.string-append "mutptr_" (spec-type-key (ty-node-get elem)))]
    [(AstTyRef region inner)
      (string.string-append
        "ref_"
        (string.string-append
          region
          (string.string-append "_" (spec-type-key (ty-node-get inner)))))]
    [(AstTyMutRef region inner)
      (string.string-append
        "mutref_"
        (string.string-append
          region
          (string.string-append "_" (spec-type-key (ty-node-get inner)))))]
    [(AstTyRegion region inner)
      (string.string-append
        "region_"
        (string.string-append
          region
          (string.string-append "_" (spec-type-key (ty-node-get inner)))))]
    [(AstTyEnum name) (string.string-append "enum_" (intern-str name))]
    [(AstTyEnumArgs name lifetimes)
      (string.string-append
        "enumargs_"
        (string.string-append
          (intern-str name)
          (string.string-append
            "_"
            (spec-lifetime-list-key (box-get lifetimes)))))]
    [(AstTyStruct name) (string.string-append "struct_" (intern-str name))]
    [(AstTyStructArgs name lifetimes)
      (string.string-append
        "structargs_"
        (string.string-append
          (intern-str name)
          (string.string-append
            "_"
            (spec-lifetime-list-key (box-get lifetimes)))))]
    [(AstTyVar name) (string.string-append "var_" (intern-str name))]
    [(AstTyVarArgs name lifetimes)
      (string.string-append
        "varargs_"
        (string.string-append
          (intern-str name)
          (string.string-append
            "_"
            (spec-lifetime-list-key (box-get lifetimes)))))]))

(define (spec-value-key [value : CompilerCtfeValue]) : String
  (match value
    [(CtfeI64 n) (string.string-append "i64_" (spec-int-key n))]
    [(CtfeF64 n)
      (string.string-append
        "f64_"
        (spec-string-key (compiler-float-format-f64 n)))]
    [(CtfeF32 n)
      (string.string-append
        "f32_"
        (spec-string-key
          (compiler-float-format-f64 (compiler-float-round-f32-as-f64 n))))]
    [(CtfeBool b)
      (if b
        "bool_1"
        "bool_0")]
    [(CtfeChar c)
      (string.string-append "char_" (string.int->string (cast c : i64)))]
    [(CtfeString text) (spec-string-key text)]
    [(CtfeUnit) "unit"]
    [(CtfeType ty) (string.string-append "type_" (spec-type-key ty))]
    [(CtfeExpr _ _) "Expr"]
    [(CtfeExprList _) "expr-list"]
    [(CtfeExprClause _) "expr-clause"]
    [(CtfeExprClauseList _) "expr-clause-list"]
    [(CtfeExprBindingClause _) "expr-binding-clause"]
    [(CtfeExprBindingClauseList _) "expr-binding-clause-list"]
    [(CtfeTypeInfo ty) (string.string-append "typeinfo_" (spec-type-key ty))]
    [(CtfeTypeInfoBox ty)
      (string.string-append "typeinfo-box_" (spec-type-key ty))]
    [(CtfeTypeInfoList _) "typeinfo-list"]
    [(CtfeTypeField _ _) "type-field"]
    [(CtfeTypeFieldList _) "type-field-list"]
    [(CtfeTypeVariantPayload _) "type-variant-payload"]
    [(CtfeTypeVariantPayloadList _) "type-variant-payload-list"]
    [(CtfeTypeVariant _ _) "type-variant"]
    [(CtfeTypeVariantList _) "type-variant-list"]))

(define (spec-values-key [values : SpecValueList]) : String
  (match values
    [(SpecValueNil) "none"]
    [(SpecValueCons head rest)
      (string.string-append
        (spec-value-key head)
        (string.string-append "_" (spec-values-key (box-get rest))))]))

(define (spec-specialization-key [name : String] [values : SpecValueList]) : String
  (string.string-append
    name
    (string.string-append ":" (spec-values-key values))))

(define (spec-specialized-name [name : String] [values : SpecValueList]) : String
  (string.string-append
    "__tl_specialized_"
    (string.string-append
      name
      (string.string-append "_" (spec-values-key values)))))

(define (gen-registry-empty) : GenRegistry
  (let
    [capacity : i64 64]
    [decls : (Array AstDecl) (array.make-array AstDecl capacity)]
    (GenRegistry (hashmap.string-i64-map-with-capacity capacity) decls 0)))

(define (gen-registry-lookup [registry : GenRegistry] [key : String]) : GenMaybeEntry
  (match (hashmap.string-i64-map-get (struct-get registry index) key)
    [(hashmap.StringI64MapFound slot)
      (GenSomeEntry (array.array-ref (struct-get registry decls) slot))]
    [(hashmap.StringI64MapMissing) (GenNoEntry)]))

(define (gen-registry-copy-decls
  [src : (Array AstDecl)]
  [dst : (Array AstDecl)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array.array-set! dst index (array.array-ref src index))
      (gen-registry-copy-decls src dst (+ index 1) count))))

(define (gen-registry-grow [registry : GenRegistry]) : GenRegistry
  (let
    [old-index : hashmap.StringI64Map (struct-get registry index)]
    [old-decls : (Array AstDecl) (struct-get registry decls)]
    [old-len : i64 (struct-get registry len)]
    [old-capacity : i64 (array.array-length old-decls)]
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
        (array.array-length (struct-get registry decls)))
        (gen-registry-grow registry)
        registry)]
    [slot : i64 (struct-get ready len)]
    [decls : (Array AstDecl) (struct-get ready decls)]
    [index : hashmap.StringI64Map (struct-get ready index)]
    (begin
      (array.array-set! decls slot decl)
      (GenRegistry (hashmap.string-i64-map-put index key slot) decls (+ slot 1)))))

(define (gen-decl-visible-name [decl : AstDecl]) : SpecMaybeString
  (match decl
    [(AstDeclDef name _ _) (SpecSomeString (intern-str name))]
    [(AstDeclDefFn name _ _ _ _) (SpecSomeString (intern-str name))]
    [(AstDeclExtern name _ _ _) (SpecSomeString (intern-str name))]
    [(AstDeclDefDispatch name _) (SpecSomeString (intern-str name))]
    [(AstDeclDefEnum name _ _) (SpecSomeString (intern-str name))]
    [(AstDeclDefEnumLifetimes name _ _ _) (SpecSomeString (intern-str name))]
    [(AstDeclDefStruct name _ _ _) (SpecSomeString (intern-str name))]
    [(AstDeclDefStructLifetimes name _ _ _ _)
      (SpecSomeString (intern-str name))]
    [(AstDeclDefMacro name _ _ _) (SpecSomeString (intern-str name))]
    [(AstDeclUnsafe inner-box) (gen-decl-visible-name (box-get inner-box))]
    [(AstDeclComptimeDecl _ inner-box)
      (gen-decl-visible-name (box-get inner-box))]
    [_ (SpecNoString)]))

(define (gen-maybe-type-eq? [a : AstMaybeType] [b : AstMaybeType]) : bool
  (match a
    [(AstNoType)
      (match b
        [(AstNoType) true]
        [_ false])]
    [(AstSomeType a-ty)
      (match b
        [(AstSomeType b-ty) (ctfe-type-eq a-ty b-ty)]
        [_ false])]))

(define (gen-expr-eq? [a : AstExpr] [b : AstExpr]) : bool
  (ctfe-expr-eq (ast-expr-unspan a) (ast-expr-unspan b)))

(define (gen-param-eq? [a : AstParam] [b : AstParam]) : bool
  (match a
    [(AstParam a-name a-ty a-comptime)
      (match b
        [(AstParam b-name b-ty b-comptime)
          (and
            (= a-name b-name)
            (ctfe-type-eq a-ty b-ty)
            (= a-comptime b-comptime))])]))

(define (gen-param-list-eq? [a : AstParamList] [b : AstParamList]) : bool
  (match a
    [(AstParamNil)
      (match b
        [(AstParamNil) true]
        [_ false])]
    [(AstParamCons a-head a-rest)
      (let
        [a-rest : AstParamList (box-get a-rest)]
        (match b
          [(AstParamCons b-head b-rest)
            (let
              [b-rest : AstParamList (box-get b-rest)]
              (and
                (gen-param-eq? a-head b-head)
                (gen-param-list-eq? a-rest b-rest)))]
          [_ false]))]))

(define (gen-macro-param-eq? [a : AstMacroParam] [b : AstMacroParam]) : bool
  (match a
    [(AstMacroParam a-name a-ty a-variadic)
      (match b
        [(AstMacroParam b-name b-ty b-variadic)
          (and
            (= a-name b-name)
            (ctfe-type-eq a-ty b-ty)
            (= a-variadic b-variadic))])]))

(define (gen-macro-param-list-eq?
  [a : AstMacroParamList]
  [b : AstMacroParamList]) : bool
  (match a
    [(AstMacroParamNil)
      (match b
        [(AstMacroParamNil) true]
        [_ false])]
    [(AstMacroParamCons a-head a-rest)
      (let
        [a-rest : AstMacroParamList (box-get a-rest)]
        (match b
          [(AstMacroParamCons b-head b-rest)
            (let
              [b-rest : AstMacroParamList (box-get b-rest)]
              (and
                (gen-macro-param-eq? a-head b-head)
                (gen-macro-param-list-eq? a-rest b-rest)))]
          [_ false]))]))

(define (gen-field-cleanup-eq? [a : AstFieldCleanup] [b : AstFieldCleanup]) : bool
  (match a
    [(AstFieldNoCleanup)
      (match b
        [(AstFieldNoCleanup) true]
        [_ false])]
    [(AstFieldCleanupFn a-name)
      (match b
        [(AstFieldCleanupFn b-name) (= a-name b-name)]
        [_ false])]
    [(AstFieldOwnedCleanup)
      (match b
        [(AstFieldOwnedCleanup) true]
        [_ false])]))

(define (gen-field-def-eq? [a : AstFieldDef] [b : AstFieldDef]) : bool
  (match a
    [(AstFieldDef a-name a-ty a-cleanup)
      (match b
        [(AstFieldDef b-name b-ty b-cleanup)
          (and
            (= a-name b-name)
            (ctfe-type-eq a-ty b-ty)
            (gen-field-cleanup-eq? a-cleanup b-cleanup))])]))

(define (gen-field-list-eq? [a : AstFieldDefList] [b : AstFieldDefList]) : bool
  (match a
    [(AstFieldDefNil)
      (match b
        [(AstFieldDefNil) true]
        [_ false])]
    [(AstFieldDefCons a-head a-rest)
      (let
        [a-rest : AstFieldDefList (box-get a-rest)]
        (match b
          [(AstFieldDefCons b-head b-rest)
            (let
              [b-rest : AstFieldDefList (box-get b-rest)]
              (and
                (gen-field-def-eq? a-head b-head)
                (gen-field-list-eq? a-rest b-rest)))]
          [_ false]))]))

(define (gen-struct-repr-eq? [a : AstStructRepr] [b : AstStructRepr]) : bool
  (match a
    [(AstStructReprDefault)
      (match b
        [(AstStructReprDefault) true]
        [_ false])]
    [(AstStructReprC)
      (match b
        [(AstStructReprC) true]
        [_ false])]))

(define (gen-struct-cleanup-eq? [a : AstStructCleanup] [b : AstStructCleanup]) : bool
  (match a
    [(AstStructNoCleanup)
      (match b
        [(AstStructNoCleanup) true]
        [_ false])]
    [(AstStructCleanupFn a-name)
      (match b
        [(AstStructCleanupFn b-name) (= a-name b-name)]
        [_ false])]))

(define (gen-enum-cleanup-eq? [a : AstEnumCleanup] [b : AstEnumCleanup]) : bool
  (match a
    [(AstEnumNoCleanup)
      (match b
        [(AstEnumNoCleanup) true]
        [_ false])]
    [(AstEnumCleanupFn a-name)
      (match b
        [(AstEnumCleanupFn b-name) (= a-name b-name)]
        [_ false])]))

(define (gen-variant-payload-cleanup-eq?
  [a : AstVariantPayloadCleanup]
  [b : AstVariantPayloadCleanup]) : bool
  (match a
    [(AstVariantPayloadNoCleanup)
      (match b
        [(AstVariantPayloadNoCleanup) true]
        [_ false])]
    [(AstVariantPayloadCleanupFn a-name)
      (match b
        [(AstVariantPayloadCleanupFn b-name) (= a-name b-name)]
        [_ false])]
    [(AstVariantPayloadOwnedCleanup)
      (match b
        [(AstVariantPayloadOwnedCleanup) true]
        [_ false])]))

(define (gen-variant-payload-cleanup-list-eq?
  [a : AstVariantPayloadCleanupList]
  [b : AstVariantPayloadCleanupList]) : bool
  (match a
    [(AstVariantPayloadCleanupNil)
      (match b
        [(AstVariantPayloadCleanupNil) true]
        [_ false])]
    [(AstVariantPayloadCleanupCons a-head a-rest)
      (let
        [a-rest : AstVariantPayloadCleanupList (box-get a-rest)]
        (match b
          [(AstVariantPayloadCleanupCons b-head b-rest)
            (let
              [b-rest : AstVariantPayloadCleanupList (box-get b-rest)]
              (and
                (gen-variant-payload-cleanup-eq? a-head b-head)
                (gen-variant-payload-cleanup-list-eq? a-rest b-rest)))]
          [_ false]))]))

(define (gen-variant-def-eq? [a : AstVariantDef] [b : AstVariantDef]) : bool
  (match a
    [(AstVariantDef a-name a-payloads a-cleanups)
      (match b
        [(AstVariantDef b-name b-payloads b-cleanups)
          (and
            (= a-name b-name)
            (ctfe-type-list-eq a-payloads b-payloads)
            (gen-variant-payload-cleanup-list-eq? a-cleanups b-cleanups))])]))

(define (gen-variant-list-eq? [a : AstVariantDefList] [b : AstVariantDefList]) : bool
  (match a
    [(AstVariantDefNil)
      (match b
        [(AstVariantDefNil) true]
        [_ false])]
    [(AstVariantDefCons a-head a-rest)
      (let
        [a-rest : AstVariantDefList (box-get a-rest)]
        (match b
          [(AstVariantDefCons b-head b-rest)
            (let
              [b-rest : AstVariantDefList (box-get b-rest)]
              (and
                (gen-variant-def-eq? a-head b-head)
                (gen-variant-list-eq? a-rest b-rest)))]
          [_ false]))]))

(define (gen-fn-export-eq? [a : AstFnExport] [b : AstFnExport]) : bool
  (match a
    [(AstFnNoExport)
      (match b
        [(AstFnNoExport) true]
        [_ false])]
    [(AstFnExport a-symbol)
      (match b
        [(AstFnExport b-symbol) (= a-symbol b-symbol)]
        [_ false])]))

(define (gen-import-kind-eq? [a : AstImportKind] [b : AstImportKind]) : bool
  (match a
    [(AstImportPath)
      (match b
        [(AstImportPath) true]
        [_ false])]
    [(AstImportModule)
      (match b
        [(AstImportModule) true]
        [_ false])]
    [(AstImportMacro _ _)
      (match b
        [(AstImportMacro _ _) true]
        [_ false])]
    [(AstImportMacroDecls _ _)
      (match b
        [(AstImportMacroDecls _ _) true]
        [_ false])]))

(define (gen-maybe-module-name-eq?
  [a : AstMaybeModuleName]
  [b : AstMaybeModuleName]) : bool
  (match a
    [(AstNoModuleName)
      (match b
        [(AstNoModuleName) true]
        [_ false])]
    [(AstSomeModuleName a-name)
      (match b
        [(AstSomeModuleName b-name) (string.string-eq a-name b-name)]
        [_ false])]))

(define (gen-maybe-import-alias-eq?
  [a : AstMaybeImportAlias]
  [b : AstMaybeImportAlias]) : bool
  (match a
    [(AstNoImportAlias)
      (match b
        [(AstNoImportAlias) true]
        [_ false])]
    [(AstSomeImportAlias a-name)
      (match b
        [(AstSomeImportAlias b-name) (string.string-eq a-name b-name)]
        [_ false])]))

(define (gen-import-spec-eq? [a : AstImportSpec] [b : AstImportSpec]) : bool
  (match a
    [(AstImportSpec a-kind a-path a-module a-alias _)
      (match b
        [(AstImportSpec b-kind b-path b-module b-alias _)
          (and
            (gen-import-kind-eq? a-kind b-kind)
            (string.string-eq a-path b-path)
            (gen-maybe-module-name-eq? a-module b-module)
            (gen-maybe-import-alias-eq? a-alias b-alias))])]))

(define (gen-decl-eq? [a : AstDecl] [b : AstDecl]) : bool
  (match a
    [(AstDeclDef a-name a-ty a-value-box)
      (let
        [a-value : AstExpr (ast-node-get a-value-box)]
        (match b
          [(AstDeclDef b-name b-ty b-value-box)
            (let
              [b-value : AstExpr (ast-node-get b-value-box)]
              (and
                (= a-name b-name)
                (gen-maybe-type-eq? a-ty b-ty)
                (gen-expr-eq? a-value b-value)))]
          [_ false]))]
    [(AstDeclDefFn a-name a-params a-ret a-body-box a-export)
      (let
        [a-body : AstExpr (ast-node-get a-body-box)]
        (match b
          [(AstDeclDefFn b-name b-params b-ret b-body-box b-export)
            (let
              [b-body : AstExpr (ast-node-get b-body-box)]
              (and
                (= a-name b-name)
                (gen-param-list-eq? a-params b-params)
                (ctfe-type-eq a-ret b-ret)
                (gen-expr-eq? a-body b-body)
                (gen-fn-export-eq? a-export b-export)))]
          [_ false]))]
    [(AstDeclDefEnum a-name a-cleanup a-variants)
      (match b
        [(AstDeclDefEnum b-name b-cleanup b-variants)
          (and
            (= a-name b-name)
            (gen-enum-cleanup-eq? a-cleanup b-cleanup)
            (gen-variant-list-eq? a-variants b-variants))]
        [_ false])]
    [(AstDeclDefEnumLifetimes a-name a-lifetimes a-cleanup a-variants)
      (match b
        [(AstDeclDefEnumLifetimes b-name b-lifetimes b-cleanup b-variants)
          (and
            (= a-name b-name)
            (ctfe-lifetime-list-eq a-lifetimes b-lifetimes)
            (gen-enum-cleanup-eq? a-cleanup b-cleanup)
            (gen-variant-list-eq? a-variants b-variants))]
        [_ false])]
    [(AstDeclDefStruct a-name a-repr a-cleanup a-fields)
      (match b
        [(AstDeclDefStruct b-name b-repr b-cleanup b-fields)
          (and
            (= a-name b-name)
            (gen-struct-repr-eq? a-repr b-repr)
            (gen-struct-cleanup-eq? a-cleanup b-cleanup)
            (gen-field-list-eq? a-fields b-fields))]
        [_ false])]
    [(AstDeclDefStructLifetimes a-name a-lifetimes a-repr a-cleanup a-fields)
      (match b
        [(AstDeclDefStructLifetimes
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
    [(AstDeclDefMacro a-name a-params a-ret a-body-box)
      (let
        [a-body : AstExpr (ast-node-get a-body-box)]
        (match b
          [(AstDeclDefMacro b-name b-params b-ret b-body-box)
            (let
              [b-body : AstExpr (ast-node-get b-body-box)]
              (and
                (= a-name b-name)
                (gen-macro-param-list-eq? a-params b-params)
                (ctfe-type-eq a-ret b-ret)
                (gen-expr-eq? a-body b-body)))]
          [_ false]))]
    [(AstDeclImport a-spec)
      (match b
        [(AstDeclImport b-spec) (gen-import-spec-eq? a-spec b-spec)]
        [_ false])]
    [(AstDeclIncludeStr a-name a-path)
      (match b
        [(AstDeclIncludeStr b-name b-path)
          (and
            (string.string-eq a-name b-name)
            (string.string-eq a-path b-path))]
        [_ false])]
    [(AstDeclIncludeBin a-name a-path)
      (match b
        [(AstDeclIncludeBin b-name b-path)
          (and
            (string.string-eq a-name b-name)
            (string.string-eq a-path b-path))]
        [_ false])]
    [(AstDeclTest a-name a-body-box _)
      (let
        [a-body : AstExpr (ast-node-get a-body-box)]
        (match b
          [(AstDeclTest b-name b-body-box _)
            (let
              [b-body : AstExpr (ast-node-get b-body-box)]
              (and (= a-name b-name) (gen-expr-eq? a-body b-body)))]
          [_ false]))]
    [(AstDeclModule a-name)
      (match b
        [(AstDeclModule b-name) (= a-name b-name)]
        [_ false])]
    [(AstDeclComptimeDecl _ a-inner-box)
      (let
        [a-inner : AstDecl (box-get a-inner-box)]
        (match b
          [(AstDeclComptimeDecl _ b-inner-box)
            (gen-decl-eq? a-inner (box-get b-inner-box))]
          [_ (gen-decl-eq? a-inner b)]))]
    [(AstDeclUnsafe a-inner-box)
      (let
        [a-inner : AstDecl (box-get a-inner-box)]
        (match b
          [(AstDeclUnsafe b-inner-box)
            (gen-decl-eq? a-inner (box-get b-inner-box))]
          [_ (gen-decl-eq? a-inner b)]))]
    [_ false]))

(define (gen-key-exprs [exprs : AstExprList] [env : CtfeEnv] [fuel : i64]) : ResultGenKey
  (match exprs
    [(AstExprNil) (OkGenKey "none" fuel)]
    [(AstExprCons head rest)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        (match (compiler-ctfe-eval head-expr env fuel)
          [(OkCtfe value head-fuel)
            (match value
              [(CtfeString text)
                (match (gen-key-exprs (box-get rest) env head-fuel)
                  [(OkGenKey tail tail-fuel)
                    (OkGenKey
                      (string.string-append
                        (spec-string-key text)
                        (string.string-append "_" tail))
                      tail-fuel)]
                  [(ErrGenKey diag) (ErrGenKey diag)])]
              [_
                (ErrGenKey
                  (box
                    (spec-diagnostic-at-expr
                      head-expr
                      "generated-decl: key expression must evaluate to String")))])]
          [(ErrCtfe diag) (ErrGenKey diag)]))]))

(define (gen-full-key
  [module : String]
  [generator : String]
  [item : String]
  [arg-key : String]) : String
  (string.string-append
    "generated:"
    (string.string-append
      (spec-string-key module)
      (string.string-append
        ":"
        (string.string-append
          (spec-string-key generator)
          (string.string-append
            ":"
            (string.string-append
              (spec-string-key item)
              (string.string-append ":" arg-key))))))))

(define (gen-key-prefix? [key : String] [prefix : String]) : bool
  (let
    [prefix-len : i64 (string.string-length prefix)]
    (if (< (string.string-length key) prefix-len)
      false
      (string.string-eq (string.substring key 0 prefix-len) prefix))))

(define (gen-full-key? [key : String]) : bool
  (gen-key-prefix? key "generated:"))

(define (gen-decls-macro-key? [key : String]) : bool
  (gen-key-prefix? key "decls:"))

(define (gen-metadata-key-normalizable? [key : String]) : bool
  (or (string.string-eq key "") (gen-full-key? key) (gen-decls-macro-key? key)))

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
      (string.string-append (string.substring item-name 0 start) local-prefix))))

(define (gen-item-mismatch-diag [expected : String] [actual : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start
    ""
    (string.string-append
      "generated-decl: metadata item "
      (string.string-append
        expected
        (string.string-append " does not match payload " actual)))))

(define (gen-incompatible-diag [item : String] [key : String]) : CompilerDiagnostic
  (compiler-diagnostic-with-note
    (compiler-diagnostic-with-note
      (compiler-diagnostic-at-start
        ""
        (string.string-append
          "generated-decl: duplicate generated key for "
          (string.string-append item " has incompatible payload")))
      (string.string-append "conflicting generated item: " item))
    (string.string-append "generated identity: " key)))

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
      [(GenNoEntry)
        (OkGenDecl
          (gen-single-decl-list
            (ast-decl-comptime-decl-with-meta
              (AstSomeGeneratedDeclMeta generator item args key)
              template))
          (gen-registry-insert registry key template)
          module)]
      [(GenSomeEntry existing)
        (if (gen-decl-eq? existing template)
          (OkGenDecl AstDeclNil registry module)
          (ErrGenDecl (box (gen-incompatible-diag item key))))])))

(define (gen-metadata-arg-key
  [meta-key : String]
  [args : AstExprList]
  [env : CtfeEnv]) : ResultGenKey
  (if (> (string.string-length meta-key) 0)
    (OkGenKey meta-key (ctfe-fuel-limit))
    (gen-key-exprs args env (ctfe-fuel-limit))))

(define (gen-rewrite-decl
  [decl : AstDecl]
  [module : String]
  [registry : GenRegistry]
  [env : CtfeEnv]) : ResultGenDecl
  (match decl
    [(AstDeclModule name)
      (OkGenDecl (gen-single-decl-list decl) registry (intern-str name))]
    [(AstDeclComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (match meta
          [(AstNoGeneratedDeclMeta)
            (OkGenDecl (gen-single-decl-list decl) registry module)]
          [(AstSomeGeneratedDeclMeta generator item args meta-key)
            (if (not (gen-metadata-key-normalizable? meta-key))
              (OkGenDecl (gen-single-decl-list decl) registry module)
              (match (gen-decl-visible-name template)
                [(SpecNoString)
                  (ErrGenDecl
                    (box
                      (compiler-diagnostic-at-start
                        ""
                        "generated-decl: generated payload must declare a visible item")))]
                [(SpecSomeString actual)
                  (if (not (string.string-eq item actual))
                    (ErrGenDecl (box (gen-item-mismatch-diag item actual)))
                    (match (gen-metadata-arg-key meta-key args env)
                      [(OkGenKey arg-key _)
                        (gen-register-generated-decl
                          template
                          module
                          generator
                          item
                          args
                          arg-key
                          registry)]
                      [(ErrGenKey diag) (ErrGenDecl diag)]))]))]))]
    [_ (OkGenDecl (gen-single-decl-list decl) registry module)]))

(define (gen-rewrite-decls
  [decls : AstDeclList]
  [module : String]
  [registry : GenRegistry]
  [env : CtfeEnv]) : ResultGenDecls
  (match decls
    [(AstDeclNil) (OkGenDecls AstDeclNil registry module)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match (gen-rewrite-decl decl module registry env)
          [(OkGenDecl rewritten-decls decl-registry decl-module)
            (match (gen-rewrite-decls rest decl-module decl-registry env)
              [(OkGenDecls rewritten-rest rest-registry rest-module)
                (OkGenDecls
                  (spec-decl-list-append rewritten-decls rewritten-rest)
                  rest-registry
                  rest-module)]
              [(ErrGenDecls diag) (ErrGenDecls diag)])]
          [(ErrGenDecl diag) (ErrGenDecls diag)]))]))

(define (gen-path-list-head-or [paths : AstDeclPathList] [fallback : String]) : String
  (match paths
    [(AstDeclPathCons path _) path]
    [(AstDeclPathNil) fallback]))

(define (gen-path-list-tail [paths : AstDeclPathList]) : AstDeclPathList
  (match paths
    [(AstDeclPathCons _ rest-box)
      (let
        [rest : AstDeclPathList (box-get rest-box)]
        rest)]
    [(AstDeclPathNil) AstDeclPathNil]))

(define (gen-path-list-for-decls
  [decls : AstDeclList]
  [path : String]
  [rest-paths : AstDeclPathList]) : AstDeclPathList
  (match decls
    [(AstDeclNil) rest-paths]
    [(AstDeclCons _ rest-box)
      (let
        [rest : AstDeclList (box-get rest-box)]
        (ast-decl-path-cons path (gen-path-list-for-decls rest path rest-paths)))]))

(define (gen-rewrite-decls-with-paths
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [fallback-path : String]
  [module : String]
  [registry : GenRegistry]
  [env : CtfeEnv]) : ResultGenDeclsWithPaths
  (match decls
    [(AstDeclNil)
      (OkGenDeclsWithPaths AstDeclNil AstDeclPathNil registry module)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        [decl-path : String (gen-path-list-head-or paths fallback-path)]
        [rest-paths : AstDeclPathList (gen-path-list-tail paths)]
        (match (gen-rewrite-decl decl module registry env)
          [(OkGenDecl rewritten-decls decl-registry decl-module)
            (match (gen-rewrite-decls-with-paths
              rest
              rest-paths
              fallback-path
              decl-module
              decl-registry
              env)
              [(OkGenDeclsWithPaths
                  rewritten-rest
                  rewritten-rest-paths
                  rest-registry
                  rest-module)
                (OkGenDeclsWithPaths
                  (spec-decl-list-append rewritten-decls rewritten-rest)
                  (gen-path-list-for-decls
                    rewritten-decls
                    decl-path
                    rewritten-rest-paths)
                  rest-registry
                  rest-module)]
              [(ErrGenDeclsWithPaths diag) (ErrGenDeclsWithPaths diag)])]
          [(ErrGenDecl diag) (ErrGenDeclsWithPaths diag)]))]))

(define (gen-normalize-program-active [program : AstProgram]) : ResultGenProgram
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [env : CtfeEnv
          (ctfe-env-with-reflections (ctfe-reflections-from-program program))]
        (match (gen-rewrite-decls decls "" (gen-registry-empty) env)
          [(OkGenDecls rewritten _ _) (OkGenProgram (ast-program rewritten))]
          [(ErrGenDecls diag) (ErrGenProgram diag)]))]))

(define (gen-normalize-program-with-paths-active
  [program : AstProgram]
  [paths : AstDeclPathList]
  [fallback-path : String]) : ResultGenProgramWithPaths
  (match program
    [(AstProgram decls-box)
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
          [(OkGenDeclsWithPaths rewritten rewritten-paths _ _)
            (OkGenProgramWithPaths (ast-program rewritten) rewritten-paths)]
          [(ErrGenDeclsWithPaths diag) (ErrGenProgramWithPaths diag)]))]))

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
    [(AstDeclUnsafe inner-box) (gen-decl-needs-normalize? (box-get inner-box))]
    [(AstDeclComptimeDecl meta template-box)
      (match meta
        [(AstSomeGeneratedDeclMeta _ _ _ key)
          (gen-metadata-key-normalizable? key)]
        [(AstNoGeneratedDeclMeta)
          (gen-decl-needs-normalize? (box-get template-box))])]
    [_ false]))

(define (gen-decls-needed? [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclNil) false]
    [(AstDeclCons decl rest)
      (if (gen-decl-needs-normalize? decl)
        true
        (gen-decls-needed? (box-get rest)))]))

(define (spec-value-runtime-type-matches?
  [value : CompilerCtfeValue]
  [ty : AstType]) : bool
  (match value
    [(CtfeI64 _) (ctfe-type-eq ty (AstTyI64))]
    [(CtfeF64 _) (ctfe-type-eq ty (AstTyF64))]
    [(CtfeF32 _) (ctfe-type-eq ty (AstTyF32))]
    [(CtfeBool _) (ctfe-type-eq ty (AstTyBool))]
    [(CtfeChar _) (ctfe-type-eq ty (AstTyChar))]
    [(CtfeString _) (ctfe-type-eq ty (AstTyString))]
    [(CtfeUnit) (ctfe-type-eq ty (AstTyUnit))]
    [(CtfeType _) false]
    [(CtfeExpr _ _) (ctfe-type-eq ty (AstTyExpr))]
    [(CtfeExprList _) (ctfe-type-eq ty (AstTyExprList))]
    [(CtfeExprClause _) (ctfe-type-eq ty (AstTyVar (intern "ExprClause")))]
    [(CtfeExprClauseList _)
      (ctfe-type-eq ty (AstTyVar (intern "ExprClauseList")))]
    [(CtfeExprBindingClause _)
      (ctfe-type-eq ty (AstTyVar (intern "ExprBindingClause")))]
    [(CtfeExprBindingClauseList _)
      (ctfe-type-eq ty (AstTyVar (intern "ExprBindingClauseList")))]
    [(CtfeTypeInfo _) false]
    [(CtfeTypeInfoBox _) false]
    [(CtfeTypeInfoList _) false]
    [(CtfeTypeField _ _) false]
    [(CtfeTypeFieldList _) false]
    [(CtfeTypeVariantPayload _) false]
    [(CtfeTypeVariantPayloadList _) false]
    [(CtfeTypeVariant _ _) false]
    [(CtfeTypeVariantList _) false]))

(define (spec-value-type-label [value : CompilerCtfeValue]) : String
  (match value
    [(CtfeI64 _) "i64"]
    [(CtfeF64 _) "f64"]
    [(CtfeF32 _) "f32"]
    [(CtfeBool _) "bool"]
    [(CtfeChar _) "char"]
    [(CtfeString _) "String"]
    [(CtfeUnit) "unit"]
    [(CtfeType _) "type"]
    [(CtfeExpr _ _) "Expr"]
    [(CtfeExprList _) "expr-list"]
    [(CtfeExprClause _) "ExprClause"]
    [(CtfeExprClauseList _) "ExprClauseList"]
    [(CtfeExprBindingClause _) "ExprBindingClause"]
    [(CtfeExprBindingClauseList _) "ExprBindingClauseList"]
    [(CtfeTypeInfo _) "TypeInfo"]
    [(CtfeTypeInfoBox _) "TypeInfoBox"]
    [(CtfeTypeInfoList _) "TypeInfoList"]
    [(CtfeTypeField _ _) "TypeField"]
    [(CtfeTypeFieldList _) "TypeFieldList"]
    [(CtfeTypeVariantPayload _) "TypeVariantPayload"]
    [(CtfeTypeVariantPayloadList _) "TypeVariantPayloadList"]
    [(CtfeTypeVariant _ _) "TypeVariant"]
    [(CtfeTypeVariantList _) "TypeVariantList"]))

(define (spec-type-subst-lookup [subs : SpecTypeSubst] [name : String]) : SpecMaybeString
  (match subs
    [(SpecTypeSubstNil) (SpecNoString)]
    [(SpecTypeSubstCons key _ rest)
      (if (string.string-eq key name)
        (SpecSomeString key)
        (spec-type-subst-lookup (box-get rest) name))]))

(define (spec-type-subst-type [subs : SpecTypeSubst] [name : String]) : AstType
  (match subs
    [(SpecTypeSubstNil) (AstTyVar (intern name))]
    [(SpecTypeSubstCons key ty rest)
      (if (string.string-eq key name)
        ty
        (spec-type-subst-type (box-get rest) name))]))

(define (spec-value-subst-lookup [subs : SpecValueSubst] [name : String]) : SpecMaybeString
  (match subs
    [(SpecValueSubstNil) (SpecNoString)]
    [(SpecValueSubstCons key _ rest)
      (if (string.string-eq key name)
        (SpecSomeString key)
        (spec-value-subst-lookup (box-get rest) name))]))

(define (spec-value-subst-value [subs : SpecValueSubst] [name : String]) : CompilerCtfeValue
  (match subs
    [(SpecValueSubstNil) (CtfeUnit)]
    [(SpecValueSubstCons key value rest)
      (if (string.string-eq key name)
        value
        (spec-value-subst-value (box-get rest) name))]))

(define (spec-value-subst-remove-name [subs : SpecValueSubst] [name : String]) : SpecValueSubst
  (match subs
    [(SpecValueSubstNil) SpecValueSubstNil]
    [(SpecValueSubstCons key value rest)
      (if (string.string-eq key name)
        (spec-value-subst-remove-name (box-get rest) name)
        (spec-value-subst-cons
          key
          value
          (spec-value-subst-remove-name (box-get rest) name)))]))

(define (spec-value-subst-remove-params
  [subs : SpecValueSubst]
  [params : AstParamList]) : SpecValueSubst
  (match params
    [(AstParamNil) subs]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (spec-value-subst-remove-params
          (spec-value-subst-remove-name subs (spec-param-name param))
          rest))]))

(define (spec-value-subst-remove-let-binding-names
  [subs : SpecValueSubst]
  [bindings : AstLetBindingList]) : SpecValueSubst
  (match bindings
    [(AstLetBindingNil) subs]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name _ _)
            (spec-value-subst-remove-let-binding-names
              (spec-value-subst-remove-name subs (intern-str name))
              rest)]))]))

(define (spec-value-subst-remove-pattern
  [subs : SpecValueSubst]
  [pattern : AstPattern]) : SpecValueSubst
  (match pattern
    [(AstPatVar name _) (spec-value-subst-remove-name subs (intern-str name))]
    [(AstPatTuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-value-subst-remove-pattern-list subs patterns))]
    [(AstPatWildcard) subs]
    [(AstPatBinding name) (spec-value-subst-remove-name subs (intern-str name))]
    [(AstPatVariant _ patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-value-subst-remove-pattern-list subs patterns))]
    [(AstPatLiteral _) subs]))

(define (spec-value-subst-remove-pattern-list
  [subs : SpecValueSubst]
  [patterns : AstPatternList]) : SpecValueSubst
  (match patterns
    [(AstPatternNil) subs]
    [(AstPatternCons pattern rest)
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest : AstPatternList (box-get rest)]
        (spec-value-subst-remove-pattern-list
          (spec-value-subst-remove-pattern subs pattern)
          rest))]))

(define (spec-type-subst-remove-name [subs : SpecTypeSubst] [name : String]) : SpecTypeSubst
  (match subs
    [(SpecTypeSubstNil) SpecTypeSubstNil]
    [(SpecTypeSubstCons key ty rest)
      (if (string.string-eq key name)
        (spec-type-subst-remove-name (box-get rest) name)
        (spec-type-subst-cons
          key
          ty
          (spec-type-subst-remove-name (box-get rest) name)))]))

(define (spec-type-subst-remove-params
  [subs : SpecTypeSubst]
  [params : AstParamList]) : SpecTypeSubst
  (match params
    [(AstParamNil) subs]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (spec-type-subst-remove-params
          (spec-type-subst-remove-name subs (spec-param-name param))
          rest))]))

(define (spec-type-subst-remove-let-binding-names
  [subs : SpecTypeSubst]
  [bindings : AstLetBindingList]) : SpecTypeSubst
  (match bindings
    [(AstLetBindingNil) subs]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name _ _)
            (spec-type-subst-remove-let-binding-names
              (spec-type-subst-remove-name subs (intern-str name))
              rest)]))]))

(define (spec-type-subst-remove-pattern
  [subs : SpecTypeSubst]
  [pattern : AstPattern]) : SpecTypeSubst
  (match pattern
    [(AstPatVar name _) (spec-type-subst-remove-name subs (intern-str name))]
    [(AstPatTuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-type-subst-remove-pattern-list subs patterns))]
    [(AstPatWildcard) subs]
    [(AstPatBinding name) (spec-type-subst-remove-name subs (intern-str name))]
    [(AstPatVariant _ patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-type-subst-remove-pattern-list subs patterns))]
    [(AstPatLiteral _) subs]))

(define (spec-type-subst-remove-pattern-list
  [subs : SpecTypeSubst]
  [patterns : AstPatternList]) : SpecTypeSubst
  (match patterns
    [(AstPatternNil) subs]
    [(AstPatternCons pattern rest)
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest : AstPatternList (box-get rest)]
        (spec-type-subst-remove-pattern-list
          (spec-type-subst-remove-pattern subs pattern)
          rest))]))

(define (spec-substitute-type [ty : AstType] [subs : SpecTypeSubst]) : AstType
  (match ty
    [(AstTyFunc args ret)
      (ast-ty-func
        (spec-substitute-type-list (box-get args) subs)
        (spec-substitute-type (ty-node-get ret) subs))]
    [(AstTyTuple elems)
      (ast-ty-tuple (spec-substitute-type-list (box-get elems) subs))]
    [(AstTyArray elem count)
      (ast-ty-array (spec-substitute-type (ty-node-get elem) subs) count)]
    [(AstTyDynArray elem)
      (ast-ty-dyn-array (spec-substitute-type (ty-node-get elem) subs))]
    [(AstTyBox elem)
      (ast-ty-box (spec-substitute-type (ty-node-get elem) subs))]
    [(AstTyPtr elem)
      (ast-ty-ptr (spec-substitute-type (ty-node-get elem) subs))]
    [(AstTyMutPtr elem)
      (ast-ty-mut-ptr (spec-substitute-type (ty-node-get elem) subs))]
    [(AstTyRef region inner)
      (ast-ty-ref region (spec-substitute-type (ty-node-get inner) subs))]
    [(AstTyMutRef region inner)
      (ast-ty-mut-ref region (spec-substitute-type (ty-node-get inner) subs))]
    [(AstTyRegion region inner)
      (ast-ty-region region (spec-substitute-type (ty-node-get inner) subs))]
    [(AstTyEnumArgs name lifetimes) (ast-ty-enum-args name (box-get lifetimes))]
    [(AstTyStructArgs name lifetimes)
      (ast-ty-struct-args name (box-get lifetimes))]
    [(AstTyVarArgs name lifetimes)
      (match (spec-type-subst-lookup subs (intern-str name))
        [(SpecSomeString _) (spec-type-subst-type subs (intern-str name))]
        [(SpecNoString) (ast-ty-var-args name (box-get lifetimes))])]
    [(AstTyVar name)
      (match (spec-type-subst-lookup subs (intern-str name))
        [(SpecSomeString _) (spec-type-subst-type subs (intern-str name))]
        [(SpecNoString) ty])]
    [_ ty]))

(define (spec-substitute-type-list [types : AstTypeList] [subs : SpecTypeSubst]) : AstTypeList
  (match types
    [(AstTypeNil) AstTypeNil]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ty-node-get head)]
        [rest : AstTypeList (box-get rest)]
        (ast-type-cons
          (spec-substitute-type head subs)
          (spec-substitute-type-list rest subs)))]))

(define (spec-substitute-maybe-type [ty : AstMaybeType] [subs : SpecTypeSubst]) : AstMaybeType
  (match ty
    [(AstNoType) AstNoType]
    [(AstSomeType inner) (AstSomeType (spec-substitute-type inner subs))]))

(define (spec-substitute-param-types
  [params : AstParamList]
  [subs : SpecTypeSubst]) : AstParamList
  (match params
    [(AstParamNil) AstParamNil]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam name ty _)
            (ast-param-cons
              (AstParam name (spec-substitute-type ty subs) false)
              (spec-substitute-param-types rest subs))]))]))

(define (spec-ctfe-value-to-expr [value : CompilerCtfeValue] [origin : AstExpr]) : ResultSpecSubExpr
  (match value
    [(CtfeI64 n)
      (OkSpecSubExpr (ast-node-push (AstExprLiteral (ast-lit-int n))))]
    [(CtfeF64 n)
      (OkSpecSubExpr
        (ast-node-push
          (AstExprLiteral (AstLitFloat (compiler-float-format-f64 n)))))]
    [(CtfeF32 n)
      (OkSpecSubExpr
        (ast-expr-ann
          (ast-node-push
            (AstExprLiteral
              (AstLitFloat
                (compiler-float-format-f64 (compiler-float-round-f32-as-f64 n)))))
          (AstTyF32)))]
    [(CtfeBool b)
      (OkSpecSubExpr (ast-node-push (AstExprLiteral (AstLitBool b))))]
    [(CtfeChar c)
      (OkSpecSubExpr (ast-node-push (AstExprLiteral (AstLitChar c))))]
    [(CtfeString _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time String value into runtime expression")))]
    [(CtfeUnit) (OkSpecSubExpr (ast-node-push (AstExprLiteral (AstLitUnit))))]
    [(CtfeType ty)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            (string.string-append
              "cannot substitute compile-time type value "
              (string.string-append
                (spec-type-key ty)
                " into runtime expression")))))]
    [(CtfeExpr _ _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time Expr value into runtime expression")))]
    [(CtfeExprList _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprList value into runtime expression")))]
    [(CtfeExprClause _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprClause value into runtime expression")))]
    [(CtfeExprClauseList _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprClauseList value into runtime expression")))]
    [(CtfeExprBindingClause _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprBindingClause value into runtime expression")))]
    [(CtfeExprBindingClauseList _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time ExprBindingClauseList value into runtime expression")))]
    [(CtfeTypeInfo _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeInfo value into runtime expression")))]
    [(CtfeTypeInfoBox _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeInfo box value into runtime expression")))]
    [(CtfeTypeInfoList _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeInfoList value into runtime expression")))]
    [(CtfeTypeField _ _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeField value into runtime expression")))]
    [(CtfeTypeFieldList _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeFieldList value into runtime expression")))]
    [(CtfeTypeVariantPayload _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariantPayload value into runtime expression")))]
    [(CtfeTypeVariantPayloadList _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariantPayloadList value into runtime expression")))]
    [(CtfeTypeVariant _ _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariant value into runtime expression")))]
    [(CtfeTypeVariantList _)
      (ErrSpecSubExpr
        (box
          (spec-diagnostic-at-expr
            origin
            "cannot substitute compile-time TypeVariantList value into runtime expression")))]))

(define (spec-expr-var-name [expr : AstExpr]) : SpecMaybeString
  (match (ast-expr-unspan expr)
    [(AstExprVar name) (SpecSomeString (intern-str name))]
    [_ (SpecNoString)]))

(define (spec-rewrite-expr-list
  [exprs : AstExprList]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecExprList
  (match exprs
    [(AstExprNil) (OkSpecExprList AstExprNil state)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (match (spec-rewrite-expr head templates state)
          [(OkSpecExpr rewritten-head head-state)
            (match (spec-rewrite-expr-list rest templates head-state)
              [(OkSpecExprList rewritten-rest rest-state)
                (OkSpecExprList
                  (ast-expr-cons rewritten-head rewritten-rest)
                  rest-state)]
              [(ErrSpecExprList diag) (ErrSpecExprList diag)])]
          [(ErrSpecExpr diag) (ErrSpecExprList diag)]))]))

(define (spec-rewrite-let-bindings
  [bindings : AstLetBindingList]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecLetBindingList
  (match bindings
    [(AstLetBindingNil) (OkSpecLetBindingList AstLetBindingNil state)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name ty value-box)
            (let
              [value : AstExpr (ast-node-get value-box)]
              (match (spec-rewrite-expr value templates state)
                [(OkSpecExpr rewritten-value value-state)
                  (match (spec-rewrite-let-bindings
                    rest
                    (spec-template-env-shadow-name templates (intern-str name))
                    value-state)
                    [(OkSpecLetBindingList rewritten-rest rest-state)
                      (OkSpecLetBindingList
                        (ast-let-binding-cons
                          (ast-let-binding-id name ty rewritten-value)
                          rewritten-rest)
                        rest-state)]
                    [(ErrSpecLetBindingList diag) (ErrSpecLetBindingList diag)])]
                [(ErrSpecExpr diag) (ErrSpecLetBindingList diag)]))]))]))

(define (spec-rewrite-match-arms
  [arms : AstMatchArmList]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecMatchArmList
  (match arms
    [(AstMatchArmNil) (OkSpecMatchArmList AstMatchArmNil state)]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (match (spec-rewrite-expr
                body
                (spec-template-env-shadow-pattern templates pattern)
                state)
                [(OkSpecExpr rewritten-body body-state)
                  (match (spec-rewrite-match-arms rest templates body-state)
                    [(OkSpecMatchArmList rewritten-rest rest-state)
                      (OkSpecMatchArmList
                        (ast-match-arm-cons
                          (ast-match-arm pattern rewritten-body)
                          rewritten-rest)
                        rest-state)]
                    [(ErrSpecMatchArmList diag) (ErrSpecMatchArmList diag)])]
                [(ErrSpecExpr diag) (ErrSpecMatchArmList diag)]))]))]))

(define (spec-rewrite-specialized-call
  [template : SpecTemplate]
  [args : AstExprList]
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [origin : AstExpr]) : ResultSpecExpr
  (match template
    [(SpecTemplate name params _ _)
      (match (spec-rewrite-specialized-args params args templates state name)
        [(OkSpecArgs values runtime-args args-state)
          (match (spec-ensure-specialization
            template
            values
            templates
            args-state
            origin)
            [(OkSpecEnsure specialized-name ensure-state)
              (OkSpecExpr
                (ast-expr-call
                  (ast-node-push (AstExprVar (intern specialized-name)))
                  runtime-args)
                ensure-state)]
            [(ErrSpecEnsure diag) (ErrSpecExpr diag)])]
        [(ErrSpecArgs diag) (ErrSpecExpr diag)])]))

(define (spec-rewrite-specialized-args
  [params : AstParamList]
  [args : AstExprList]
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [fn-name : String]) : ResultSpecArgs
  (match params
    [(AstParamNil)
      (match args
        [(AstExprNil) (OkSpecArgs SpecValueNil AstExprNil state)]
        [_
          (ErrSpecArgs
            (box (compiler-diagnostic-at-start "" "specialize: arity mismatch")))])]
    [(AstParamCons param rest-params)
      (let
        [rest-params : AstParamList (box-get rest-params)]
        (match args
          [(AstExprCons arg rest-args)
            (let
              [arg : AstExpr (ast-node-get arg)]
              [rest-args : AstExprList (box-get rest-args)]
              (match param
                [(AstParam param-name param-ty is-comptime)
                  (if is-comptime
                    (match (spec-ctfe-eval state arg (ctfe-fuel-limit))
                      [(OkCtfe value _)
                        (if (spec-type-kind? param-ty)
                          (match value
                            [(CtfeType _)
                              (match (spec-rewrite-specialized-args
                                rest-params
                                rest-args
                                templates
                                state
                                fn-name)
                                [(OkSpecArgs
                                    rest-values
                                    rest-runtime
                                    rest-state)
                                  (OkSpecArgs
                                    (spec-value-cons value rest-values)
                                    rest-runtime
                                    rest-state)]
                                [(ErrSpecArgs diag) (ErrSpecArgs diag)])]
                            [_
                              (ErrSpecArgs
                                (box
                                  (spec-diagnostic-at-expr
                                    arg
                                    (string.string-append
                                      "comptime argument '"
                                      (string.string-append
                                        (intern-str param-name)
                                        (string.string-append
                                          "' for function '"
                                          (string.string-append
                                            fn-name
                                            "' must be a type value such as `(type i64)`")))))))])
                          (if (spec-value-runtime-type-matches? value param-ty)
                            (match (spec-rewrite-specialized-args
                              rest-params
                              rest-args
                              templates
                              state
                              fn-name)
                              [(OkSpecArgs rest-values rest-runtime rest-state)
                                (OkSpecArgs
                                  (spec-value-cons value rest-values)
                                  rest-runtime
                                  rest-state)]
                              [(ErrSpecArgs diag) (ErrSpecArgs diag)])
                            (ErrSpecArgs
                              (box
                                (spec-diagnostic-at-expr
                                  arg
                                  (string.string-append
                                    "comptime argument '"
                                    (string.string-append
                                      (intern-str param-name)
                                      (string.string-append
                                        "' for function '"
                                        (string.string-append
                                          fn-name
                                          (string.string-append
                                            "' has type "
                                            (string.string-append
                                              (spec-value-type-label value)
                                              (string.string-append
                                                ", expected "
                                                (spec-type-key param-ty)))))))))))))]
                      [(ErrCtfe diag) (ErrSpecArgs diag)])
                    (match (spec-rewrite-expr arg templates state)
                      [(OkSpecExpr rewritten-arg arg-state)
                        (match (spec-rewrite-specialized-args
                          rest-params
                          rest-args
                          templates
                          arg-state
                          fn-name)
                          [(OkSpecArgs values rest-runtime rest-state)
                            (OkSpecArgs
                              values
                              (ast-expr-cons rewritten-arg rest-runtime)
                              rest-state)]
                          [(ErrSpecArgs diag) (ErrSpecArgs diag)])]
                      [(ErrSpecExpr diag) (ErrSpecArgs diag)]))]))]
          [_
            (ErrSpecArgs
              (box
                (compiler-diagnostic-at-start "" "specialize: arity mismatch")))]))]))

(define (spec-build-specialization
  [params : AstParamList]
  [values : SpecValueList]) : ResultSpecBuild
  (match params
    [(AstParamNil)
      (match values
        [(SpecValueNil)
          (OkSpecBuild AstParamNil SpecValueSubstNil SpecTypeSubstNil)]
        [_
          (ErrSpecBuild
            (box (compiler-diagnostic-at-start "" "specialize: value mismatch")))])]
    [(AstParamCons param rest-params)
      (let
        [rest-params : AstParamList (box-get rest-params)]
        (match param
          [(AstParam name ty is-comptime)
            (if is-comptime
              (match values
                [(SpecValueCons value rest-values)
                  (match (spec-build-specialization
                    rest-params
                    (box-get rest-values))
                    [(OkSpecBuild runtime value-subs type-subs)
                      (if (spec-type-kind? ty)
                        (match value
                          [(CtfeType actual-ty)
                            (OkSpecBuild
                              runtime
                              value-subs
                              (spec-type-subst-cons
                                (intern-str name)
                                actual-ty
                                type-subs))]
                          [_
                            (ErrSpecBuild
                              (box
                                (compiler-diagnostic-at-start
                                  ""
                                  "specialize: expected type value")))])
                        (OkSpecBuild
                          runtime
                          (spec-value-subst-cons
                            (intern-str name)
                            value
                            value-subs)
                          type-subs))]
                    [(ErrSpecBuild diag) (ErrSpecBuild diag)])]
                [_
                  (ErrSpecBuild
                    (box
                      (compiler-diagnostic-at-start
                        ""
                        "specialize: value mismatch")))])
              (match (spec-build-specialization rest-params values)
                [(OkSpecBuild runtime value-subs type-subs)
                  (OkSpecBuild
                    (ast-param-cons (AstParam name ty false) runtime)
                    value-subs
                    type-subs)]
                [(ErrSpecBuild diag) (ErrSpecBuild diag)]))]))]))

(define (spec-ensure-specialization
  [template : SpecTemplate]
  [values : SpecValueList]
  [templates : SpecTemplateEnv]
  [state : SpecState]
  [_origin : AstExpr]) : ResultSpecEnsure
  (match template
    [(SpecTemplate name params ret body)
      (match state
        [(SpecState generated cache ctfe-env pools)
          (let
            [key : String (spec-specialization-key name values)]
            (match (spec-cache-lookup cache key)
              [(SpecSomeString cached-name) (OkSpecEnsure cached-name state)]
              [(SpecNoString)
                (let
                  [generated-name : String (spec-specialized-name name values)]
                  (match (spec-build-specialization params values)
                    [(OkSpecBuild runtime-params value-subs type-subs)
                      (match (spec-substitute-types-expr body type-subs)
                        [(OkSpecSubExpr typed-body)
                          (match (spec-substitute-values-expr
                            (ast-node-get typed-body)
                            value-subs)
                            [(OkSpecSubExpr valued-body)
                              (let
                                [cached-state : SpecState
                                  (SpecState
                                    generated
                                    (hashmap.string-string-map-put
                                      cache
                                      key
                                      generated-name)
                                    ctfe-env
                                    pools)]
                                (match (spec-rewrite-expr
                                  (ast-node-get valued-body)
                                  (spec-template-env-shadow-params
                                    templates
                                    runtime-params)
                                  cached-state)
                                  [(OkSpecExpr rewritten-body rewritten-state)
                                    (match rewritten-state
                                      [(SpecState
                                          rewritten-generated
                                          rewritten-cache
                                          rewritten-ctfe-env
                                          rewritten-pools)
                                        (OkSpecEnsure
                                          generated-name
                                          (SpecState
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
                                  [(ErrSpecExpr diag) (ErrSpecEnsure diag)]))]
                            [(ErrSpecSubExpr diag) (ErrSpecEnsure diag)])]
                        [(ErrSpecSubExpr diag) (ErrSpecEnsure diag)])]
                    [(ErrSpecBuild diag) (ErrSpecEnsure diag)]))]))])]))

(define (spec-rewrite-expr
  [expr : AstExpr]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecExpr
  (match expr
    [(AstExprSpanned inner-box span)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten rewritten-state)
            (OkSpecExpr (ast-expr-spanned rewritten span) rewritten-state)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprLiteral _) (OkSpecExpr (ast-node-push expr) state)]
    [(AstExprVar _) (OkSpecExpr (ast-node-push expr) state)]
    [(AstExprTypeLiteral _) (OkSpecExpr (ast-node-push expr) state)]
    [(AstExprInit _) (OkSpecExpr (ast-node-push expr) state)]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (match (spec-rewrite-expr left templates state)
          [(OkSpecExpr rewritten-left left-state)
            (match (spec-rewrite-expr right templates left-state)
              [(OkSpecExpr rewritten-right right-state)
                (OkSpecExpr
                  (ast-expr-binary op rewritten-left rewritten-right)
                  right-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten rewritten-state)
            (OkSpecExpr (ast-expr-unary op rewritten) rewritten-state)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (match (spec-expr-var-name func)
          [(SpecSomeString name)
            (match (spec-template-lookup templates name)
              [(SpecSomeTemplate template)
                (spec-rewrite-specialized-call
                  template
                  args
                  templates
                  state
                  expr)]
              [(SpecNoTemplate)
                (match (spec-rewrite-expr func templates state)
                  [(OkSpecExpr rewritten-func func-state)
                    (match (spec-rewrite-expr-list args templates func-state)
                      [(OkSpecExprList rewritten-args args-state)
                        (OkSpecExpr
                          (ast-expr-call rewritten-func rewritten-args)
                          args-state)]
                      [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
                  [(ErrSpecExpr diag) (ErrSpecExpr diag)])])]
          [(SpecNoString)
            (match (spec-rewrite-expr func templates state)
              [(OkSpecExpr rewritten-func func-state)
                (match (spec-rewrite-expr-list args templates func-state)
                  [(OkSpecExprList rewritten-args args-state)
                    (OkSpecExpr
                      (ast-expr-call rewritten-func rewritten-args)
                      args-state)]
                  [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (match (spec-rewrite-expr cond templates state)
          [(OkSpecExpr rewritten-cond cond-state)
            (match (spec-rewrite-expr then-branch templates cond-state)
              [(OkSpecExpr rewritten-then then-state)
                (match (spec-rewrite-expr else-branch templates then-state)
                  [(OkSpecExpr rewritten-else else-state)
                    (OkSpecExpr
                      (ast-expr-if rewritten-cond rewritten-then rewritten-else)
                      else-state)]
                  [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprLet let-box)
      (match (box-get let-box)
        [(AstLet bindings body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-rewrite-let-bindings bindings templates state)
              [(OkSpecLetBindingList rewritten-bindings binding-state)
                (match (spec-rewrite-expr
                  body
                  (spec-template-env-shadow-let-binding-names
                    templates
                    bindings)
                  binding-state)
                  [(OkSpecExpr rewritten-body body-state)
                    (OkSpecExpr
                      (ast-expr-let rewritten-bindings rewritten-body)
                      body-state)]
                  [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
              [(ErrSpecLetBindingList diag) (ErrSpecExpr diag)]))])]
    [(AstExprLambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda params ret body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-rewrite-expr
              body
              (spec-template-env-shadow-params templates params)
              state)
              [(OkSpecExpr rewritten-body body-state)
                (OkSpecExpr
                  (ast-expr-lambda params ret rewritten-body)
                  body-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)]))])]
    [(AstExprTuple exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(OkSpecExprList rewritten state2)
          (OkSpecExpr (ast-node-push (AstExprTuple rewritten)) state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprTupleRef inner-box index)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-tuple-ref rewritten index) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprArray exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(OkSpecExprList rewritten state2)
          (OkSpecExpr (ast-node-push (AstExprArray rewritten)) state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprMakeArray elem-ty len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (match (spec-rewrite-expr len templates state)
          [(OkSpecExpr rewritten-len state2)
            (OkSpecExpr (ast-expr-make-array elem-ty rewritten-len) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-rewrite-expr array templates state)
          [(OkSpecExpr rewritten-array array-state)
            (match (spec-rewrite-expr index templates array-state)
              [(OkSpecExpr rewritten-index index-state)
                (OkSpecExpr
                  (ast-expr-array-ref rewritten-array rewritten-index)
                  index-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr array templates state)
          [(OkSpecExpr rewritten-array array-state)
            (match (spec-rewrite-expr index templates array-state)
              [(OkSpecExpr rewritten-index index-state)
                (match (spec-rewrite-expr value templates index-state)
                  [(OkSpecExpr rewritten-value value-state)
                    (OkSpecExpr
                      (ast-expr-array-set
                        rewritten-array
                        rewritten-index
                        rewritten-value)
                      value-state)]
                  [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr array templates state)
          [(OkSpecExpr rewritten-array array-state)
            (match (spec-rewrite-expr value templates array-state)
              [(OkSpecExpr rewritten-value value-state)
                (OkSpecExpr
                  (ast-expr-array-push rewritten-array rewritten-value)
                  value-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprStringRef text-box index-box)
      (let
        [text : AstExpr (ast-node-get text-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-rewrite-expr text templates state)
          [(OkSpecExpr rewritten-text text-state)
            (match (spec-rewrite-expr index templates text-state)
              [(OkSpecExpr rewritten-index index-state)
                (OkSpecExpr
                  (ast-expr-string-ref rewritten-text rewritten-index)
                  index-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (match (spec-rewrite-expr cond templates state)
          [(OkSpecExpr rewritten-cond cond-state)
            (match (spec-rewrite-expr body templates cond-state)
              [(OkSpecExpr rewritten-body body-state)
                (OkSpecExpr
                  (ast-expr-while rewritten-cond rewritten-body)
                  body-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprBegin exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(OkSpecExprList rewritten state2)
          (OkSpecExpr (ast-node-push (AstExprBegin rewritten)) state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprUnsafe exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(OkSpecExprList rewritten state2)
          (OkSpecExpr (ast-node-push (AstExprUnsafe rewritten)) state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprSet name value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr value templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-set-id name rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprAnn inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-ann rewritten ty) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-cast rewritten ty) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprMatch match-box)
      (match (box-get match-box)
        [(AstMatch scrutinee-box arms)
          (let
            [scrutinee : AstExpr (ast-node-get scrutinee-box)]
            (match (spec-rewrite-expr scrutinee templates state)
              [(OkSpecExpr rewritten-scrutinee scrutinee-state)
                (match (spec-rewrite-match-arms arms templates scrutinee-state)
                  [(OkSpecMatchArmList rewritten-arms arms-state)
                    (OkSpecExpr
                      (ast-expr-match rewritten-scrutinee rewritten-arms)
                      arms-state)]
                  [(ErrSpecMatchArmList diag) (ErrSpecExpr diag)])]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)]))])]
    [(AstExprForeach fe-box)
      (match (box-get fe-box)
        [(AstForeach index index-ty start-box end-box body-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-rewrite-expr start templates state)
              [(OkSpecExpr rewritten-start start-state)
                (match (spec-rewrite-expr end templates start-state)
                  [(OkSpecExpr rewritten-end end-state)
                    (match (spec-rewrite-expr
                      body
                      (spec-template-env-shadow-name
                        templates
                        (intern-str index))
                      end-state)
                      [(OkSpecExpr rewritten-body body-state)
                        (OkSpecExpr
                          (ast-expr-foreach-id
                            index
                            index-ty
                            rewritten-start
                            rewritten-end
                            rewritten-body)
                          body-state)]
                      [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
                  [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)]))])]
    [(AstExprSpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce op index index-ty start-box end-box init-box value-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [init : AstExpr (ast-node-get init-box)]
            [value : AstExpr (ast-node-get value-box)]
            (match (spec-rewrite-expr start templates state)
              [(OkSpecExpr rewritten-start start-state)
                (match (spec-rewrite-expr end templates start-state)
                  [(OkSpecExpr rewritten-end end-state)
                    (match (spec-rewrite-expr init templates end-state)
                      [(OkSpecExpr rewritten-init init-state)
                        (match (spec-rewrite-expr
                          value
                          (spec-template-env-shadow-name
                            templates
                            (intern-str index))
                          init-state)
                          [(OkSpecExpr rewritten-value value-state)
                            (OkSpecExpr
                              (ast-expr-spmd-reduce-id
                                op
                                index
                                index-ty
                                rewritten-start
                                rewritten-end
                                rewritten-init
                                rewritten-value)
                              value-state)]
                          [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
                      [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
                  [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)]))])]
    [(AstExprSpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan
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
              [(OkSpecExpr rewritten-start start-state)
                (match (spec-rewrite-expr end templates start-state)
                  [(OkSpecExpr rewritten-end end-state)
                    (match (spec-rewrite-expr init templates end-state)
                      [(OkSpecExpr rewritten-init init-state)
                        (match (spec-rewrite-expr
                          value
                          value-templates
                          init-state)
                          [(OkSpecExpr rewritten-value value-state)
                            (match (spec-rewrite-expr
                              body
                              body-templates
                              value-state)
                              [(OkSpecExpr rewritten-body body-state)
                                (OkSpecExpr
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
                              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
                          [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
                      [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
                  [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)]))])]
    [(AstExprSpmdBroadcast value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (spec-rewrite-expr value templates state)
          [(OkSpecExpr rewritten-value value-state)
            (match (spec-rewrite-expr lane templates value-state)
              [(OkSpecExpr rewritten-lane lane-state)
                (OkSpecExpr
                  (ast-expr-spmd-broadcast rewritten-value rewritten-lane)
                  lane-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprSpmdShuffle value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (spec-rewrite-expr value templates state)
          [(OkSpecExpr rewritten-value value-state)
            (match (spec-rewrite-expr lane templates value-state)
              [(OkSpecExpr rewritten-lane lane-state)
                (OkSpecExpr
                  (ast-expr-spmd-shuffle rewritten-value rewritten-lane)
                  lane-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprStructGet receiver-box field)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (match (spec-rewrite-expr receiver templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-struct-get-id rewritten field) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprStructSet receiver-box field value-box)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr receiver templates state)
          [(OkSpecExpr rewritten-receiver receiver-state)
            (match (spec-rewrite-expr value templates receiver-state)
              [(OkSpecExpr rewritten-value value-state)
                (OkSpecExpr
                  (ast-expr-struct-set-id
                    rewritten-receiver
                    field
                    rewritten-value)
                  value-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprWithRegion region body)
      (match (spec-rewrite-expr-list body templates state)
        [(OkSpecExprList rewritten state2)
          (OkSpecExpr
            (ast-node-push (AstExprWithRegion region rewritten))
            state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (match (spec-rewrite-expr scratch templates state)
          [(OkSpecExpr rewritten-scratch scratch-state)
            (match (spec-rewrite-expr-list body templates scratch-state)
              [(OkSpecExprList rewritten-body body-state)
                (OkSpecExpr
                  (ast-expr-with-escape rewritten-scratch rewritten-body)
                  body-state)]
              [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprWithScratch body)
      (match (spec-rewrite-expr-list body templates state)
        [(OkSpecExprList rewritten-body body-state)
          (OkSpecExpr (ast-expr-with-scratch rewritten-body) body-state)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprInArena arena-box body)
      (let
        [arena : AstExpr (ast-node-get arena-box)]
        (match (spec-rewrite-expr arena templates state)
          [(OkSpecExpr rewritten-arena arena-state)
            (match (spec-rewrite-expr-list body templates arena-state)
              [(OkSpecExprList rewritten-body body-state)
                (OkSpecExpr
                  (ast-expr-in-arena rewritten-arena rewritten-body)
                  body-state)]
              [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprWithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource bindings body)
          (OkSpecExpr
            (ast-node-push
              (AstExprWithResource (box (AstWithResource bindings body))))
            state)])]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-box rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-box-get rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprBoxTake inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-box-take rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprBoxSet inner-box value-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten-inner inner-state)
            (match (spec-rewrite-expr value templates inner-state)
              [(OkSpecExpr rewritten-value value-state)
                (OkSpecExpr
                  (ast-expr-box-set rewritten-inner rewritten-value)
                  value-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-comptime rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-try rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-return rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprPtrNull ty) (OkSpecExpr (ast-node-push (AstExprPtrNull ty)) state)]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-ptr-null-check rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprPtrAddrOf name) (OkSpecExpr (ast-expr-ptr-addr-of-id name) state)]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-ptr-read rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(OkSpecExpr rewritten-ptr ptr-state)
            (match (spec-rewrite-expr value templates ptr-state)
              [(OkSpecExpr rewritten-value value-state)
                (OkSpecExpr
                  (ast-expr-ptr-write rewritten-ptr rewritten-value)
                  value-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(OkSpecExpr rewritten-ptr ptr-state)
            (match (spec-rewrite-expr offset templates ptr-state)
              [(OkSpecExpr rewritten-offset offset-state)
                (OkSpecExpr
                  (ast-expr-ptr-offset rewritten-ptr rewritten-offset)
                  offset-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprPtrCast ptr-box ty)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-ptr-cast rewritten ty) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-ptr-to-int rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprIntToPtr value-box ty)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr value templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-int-to-ptr rewritten ty) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-string-data rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(OkSpecExpr rewritten-ptr ptr-state)
            (match (spec-rewrite-expr len templates ptr-state)
              [(OkSpecExpr rewritten-len len-state)
                (OkSpecExpr
                  (ast-expr-string-from-bytes rewritten-ptr rewritten-len)
                  len-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprArrayData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-array-data rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprBinaryData bytes)
      (OkSpecExpr (ast-node-push (AstExprBinaryData bytes)) state)]
    [(AstExprSpmdProgramIndex) (OkSpecExpr (ast-expr-spmd-program-index) state)]
    [(AstExprSpmdProgramCount) (OkSpecExpr (ast-expr-spmd-program-count) state)]
    [(AstExprProgramArgc)
      (OkSpecExpr (ast-node-push (AstExprProgramArgc)) state)]
    [(AstExprProgramArgv)
      (OkSpecExpr (ast-node-push (AstExprProgramArgv)) state)]
    [(AstExprProgramEnvp)
      (OkSpecExpr (ast-node-push (AstExprProgramEnvp)) state)]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-rewrite-expr leaf templates state)
          [(OkSpecExpr rewritten-leaf leaf-state)
            (match (spec-rewrite-expr subleaf templates leaf-state)
              [(OkSpecExpr rewritten-subleaf subleaf-state)
                (OkSpecExpr
                  (ast-expr-cpuid-eax rewritten-leaf rewritten-subleaf)
                  subleaf-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-rewrite-expr leaf templates state)
          [(OkSpecExpr rewritten-leaf leaf-state)
            (match (spec-rewrite-expr subleaf templates leaf-state)
              [(OkSpecExpr rewritten-subleaf subleaf-state)
                (OkSpecExpr
                  (ast-expr-cpuid-ebx rewritten-leaf rewritten-subleaf)
                  subleaf-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-rewrite-expr leaf templates state)
          [(OkSpecExpr rewritten-leaf leaf-state)
            (match (spec-rewrite-expr subleaf templates leaf-state)
              [(OkSpecExpr rewritten-subleaf subleaf-state)
                (OkSpecExpr
                  (ast-expr-cpuid-ecx rewritten-leaf rewritten-subleaf)
                  subleaf-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-rewrite-expr leaf templates state)
          [(OkSpecExpr rewritten-leaf leaf-state)
            (match (spec-rewrite-expr subleaf templates leaf-state)
              [(OkSpecExpr rewritten-subleaf subleaf-state)
                (OkSpecExpr
                  (ast-expr-cpuid-edx rewritten-leaf rewritten-subleaf)
                  subleaf-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-rewrite-expr index templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-xgetbv rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprSyscall args)
      (match (spec-rewrite-expr-list args templates state)
        [(OkSpecExprList rewritten-args args-state)
          (OkSpecExpr (ast-expr-syscall rewritten-args) args-state)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprQuote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-quote rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprQuasiquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-quasiquote rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-unquote rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-unquote-splicing rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprBracketClause items)
      (match (spec-rewrite-expr-list items templates state)
        [(OkSpecExprList rewritten state2)
          (OkSpecExpr (ast-expr-bracket-clause rewritten) state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprBorrow _ _ _) (OkSpecExpr (ast-node-push expr) state)]))

(define (spec-substitute-values-expr [expr : AstExpr] [subs : SpecValueSubst]) : ResultSpecSubExpr
  (match expr
    [(AstExprSpanned inner-box span)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-spanned rewritten span))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprVar name)
      (let
        [name-str : String (intern-str name)]
        (match (spec-value-subst-lookup subs name-str)
          [(SpecSomeString _)
            (spec-ctfe-value-to-expr
              (spec-value-subst-value subs name-str)
              expr)]
          [(SpecNoString) (OkSpecSubExpr (ast-node-push expr))]))]
    [(AstExprLiteral _) (OkSpecSubExpr (ast-node-push expr))]
    [(AstExprTypeLiteral _) (OkSpecSubExpr (ast-node-push expr))]
    [(AstExprInit _) (OkSpecSubExpr (ast-node-push expr))]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (match (spec-substitute-values-expr left subs)
          [(OkSpecSubExpr rewritten-left)
            (match (spec-substitute-values-expr right subs)
              [(OkSpecSubExpr rewritten-right)
                (OkSpecSubExpr
                  (ast-expr-binary op rewritten-left rewritten-right))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-unary op rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (match (spec-substitute-values-expr func subs)
          [(OkSpecSubExpr rewritten-func)
            (match (spec-substitute-values-expr-list args subs)
              [(OkSpecSubExprList rewritten-args)
                (OkSpecSubExpr (ast-expr-call rewritten-func rewritten-args))]
              [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (match (spec-substitute-values-expr cond subs)
          [(OkSpecSubExpr rewritten-cond)
            (match (spec-substitute-values-expr then-branch subs)
              [(OkSpecSubExpr rewritten-then)
                (match (spec-substitute-values-expr else-branch subs)
                  [(OkSpecSubExpr rewritten-else)
                    (OkSpecSubExpr
                      (ast-expr-if rewritten-cond rewritten-then rewritten-else))]
                  [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprLet let-box)
      (match (box-get let-box)
        [(AstLet bindings body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-substitute-values-let-bindings bindings subs)
              [(OkSpecSubLetBindingList rewritten-bindings)
                (match (spec-substitute-values-expr
                  body
                  (spec-value-subst-remove-let-binding-names subs bindings))
                  [(OkSpecSubExpr rewritten-body)
                    (OkSpecSubExpr
                      (ast-expr-let rewritten-bindings rewritten-body))]
                  [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubLetBindingList diag) (ErrSpecSubExpr diag)]))])]
    [(AstExprLambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda params ret body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-substitute-values-expr
              body
              (spec-value-subst-remove-params subs params))
              [(OkSpecSubExpr rewritten-body)
                (OkSpecSubExpr (ast-expr-lambda params ret rewritten-body))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))])]
    [(AstExprTuple exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (ast-node-push (AstExprTuple rewritten)))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprTupleRef inner-box index)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-tuple-ref rewritten index))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprArray exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (ast-node-push (AstExprArray rewritten)))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprMakeArray elem-ty len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (match (spec-substitute-values-expr len subs)
          [(OkSpecSubExpr rewritten-len)
            (OkSpecSubExpr (ast-expr-make-array elem-ty rewritten-len))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-values-expr array subs)
          [(OkSpecSubExpr rewritten-array)
            (match (spec-substitute-values-expr index subs)
              [(OkSpecSubExpr rewritten-index)
                (OkSpecSubExpr
                  (ast-expr-array-ref rewritten-array rewritten-index))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-values-expr array subs)
          [(OkSpecSubExpr rewritten-array)
            (match (spec-substitute-values-expr index subs)
              [(OkSpecSubExpr rewritten-index)
                (match (spec-substitute-values-expr value subs)
                  [(OkSpecSubExpr rewritten-value)
                    (OkSpecSubExpr
                      (ast-expr-array-set
                        rewritten-array
                        rewritten-index
                        rewritten-value))]
                  [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-values-expr array subs)
          [(OkSpecSubExpr rewritten-array)
            (match (spec-substitute-values-expr value subs)
              [(OkSpecSubExpr rewritten-value)
                (OkSpecSubExpr
                  (ast-expr-array-push rewritten-array rewritten-value))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprStringRef text-box index-box)
      (let
        [text : AstExpr (ast-node-get text-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-values-expr text subs)
          [(OkSpecSubExpr rewritten-text)
            (match (spec-substitute-values-expr index subs)
              [(OkSpecSubExpr rewritten-index)
                (OkSpecSubExpr
                  (ast-expr-string-ref rewritten-text rewritten-index))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (match (spec-substitute-values-expr cond subs)
          [(OkSpecSubExpr rewritten-cond)
            (match (spec-substitute-values-expr body subs)
              [(OkSpecSubExpr rewritten-body)
                (OkSpecSubExpr (ast-expr-while rewritten-cond rewritten-body))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBegin exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (ast-node-push (AstExprBegin rewritten)))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprUnsafe exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (ast-node-push (AstExprUnsafe rewritten)))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprSet name value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-value-subst-lookup subs (intern-str name))
          [(SpecSomeString _)
            (ErrSpecSubExpr
              (box
                (spec-diagnostic-at-expr
                  expr
                  (string.string-append
                    "cannot assign to comptime parameter '"
                    (string.string-append (intern-str name) "'")))))]
          [(SpecNoString)
            (match (spec-substitute-values-expr value subs)
              [(OkSpecSubExpr rewritten)
                (OkSpecSubExpr (ast-expr-set-id name rewritten))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]))]
    [(AstExprAnn inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ann rewritten ty))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-cast rewritten ty))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprMatch match-box)
      (match (box-get match-box)
        [(AstMatch scrutinee-box arms)
          (let
            [scrutinee : AstExpr (ast-node-get scrutinee-box)]
            (match (spec-substitute-values-expr scrutinee subs)
              [(OkSpecSubExpr rewritten-scrutinee)
                (match (spec-substitute-values-match-arms arms subs)
                  [(OkSpecSubMatchArmList rewritten-arms)
                    (OkSpecSubExpr
                      (ast-expr-match rewritten-scrutinee rewritten-arms))]
                  [(ErrSpecSubMatchArmList diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))])]
    [(AstExprForeach fe-box)
      (match (box-get fe-box)
        [(AstForeach index index-ty start-box end-box body-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-substitute-values-expr start subs)
              [(OkSpecSubExpr rewritten-start)
                (match (spec-substitute-values-expr end subs)
                  [(OkSpecSubExpr rewritten-end)
                    (match (spec-substitute-values-expr
                      body
                      (spec-value-subst-remove-name subs (intern-str index)))
                      [(OkSpecSubExpr rewritten-body)
                        (OkSpecSubExpr
                          (ast-expr-foreach-id
                            index
                            index-ty
                            rewritten-start
                            rewritten-end
                            rewritten-body))]
                      [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
                  [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))])]
    [(AstExprSpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce op index index-ty start-box end-box init-box value-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [init : AstExpr (ast-node-get init-box)]
            [value : AstExpr (ast-node-get value-box)]
            (match (spec-substitute-values-expr start subs)
              [(OkSpecSubExpr rewritten-start)
                (match (spec-substitute-values-expr end subs)
                  [(OkSpecSubExpr rewritten-end)
                    (match (spec-substitute-values-expr init subs)
                      [(OkSpecSubExpr rewritten-init)
                        (match (spec-substitute-values-expr
                          value
                          (spec-value-subst-remove-name subs (intern-str index)))
                          [(OkSpecSubExpr rewritten-value)
                            (OkSpecSubExpr
                              (ast-expr-spmd-reduce-id
                                op
                                index
                                index-ty
                                rewritten-start
                                rewritten-end
                                rewritten-init
                                rewritten-value))]
                          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
                      [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
                  [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))])]
    [(AstExprSpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan
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
              [(OkSpecSubExpr rewritten-start)
                (match (spec-substitute-values-expr end subs)
                  [(OkSpecSubExpr rewritten-end)
                    (match (spec-substitute-values-expr init subs)
                      [(OkSpecSubExpr rewritten-init)
                        (match (spec-substitute-values-expr value value-subs)
                          [(OkSpecSubExpr rewritten-value)
                            (match (spec-substitute-values-expr body body-subs)
                              [(OkSpecSubExpr rewritten-body)
                                (OkSpecSubExpr
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
                              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
                          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
                      [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
                  [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))])]
    [(AstExprSpmdBroadcast value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (spec-substitute-values-expr value subs)
          [(OkSpecSubExpr rewritten-value)
            (match (spec-substitute-values-expr lane subs)
              [(OkSpecSubExpr rewritten-lane)
                (OkSpecSubExpr
                  (ast-expr-spmd-broadcast rewritten-value rewritten-lane))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprSpmdShuffle value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (spec-substitute-values-expr value subs)
          [(OkSpecSubExpr rewritten-value)
            (match (spec-substitute-values-expr lane subs)
              [(OkSpecSubExpr rewritten-lane)
                (OkSpecSubExpr
                  (ast-expr-spmd-shuffle rewritten-value rewritten-lane))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprStructGet receiver-box field)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (match (spec-substitute-values-expr receiver subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-struct-get-id rewritten field))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprStructSet receiver-box field value-box)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-values-expr receiver subs)
          [(OkSpecSubExpr rewritten-receiver)
            (match (spec-substitute-values-expr value subs)
              [(OkSpecSubExpr rewritten-value)
                (OkSpecSubExpr
                  (ast-expr-struct-set-id
                    rewritten-receiver
                    field
                    rewritten-value))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprWithRegion region body)
      (match (spec-substitute-values-expr-list body subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (ast-node-push (AstExprWithRegion region rewritten)))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (match (spec-substitute-values-expr scratch subs)
          [(OkSpecSubExpr rewritten-scratch)
            (match (spec-substitute-values-expr-list body subs)
              [(OkSpecSubExprList rewritten-body)
                (OkSpecSubExpr
                  (ast-expr-with-escape rewritten-scratch rewritten-body))]
              [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprWithScratch body)
      (match (spec-substitute-values-expr-list body subs)
        [(OkSpecSubExprList rewritten-body)
          (OkSpecSubExpr (ast-expr-with-scratch rewritten-body))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprInArena arena-box body)
      (let
        [arena : AstExpr (ast-node-get arena-box)]
        (match (spec-substitute-values-expr arena subs)
          [(OkSpecSubExpr rewritten-arena)
            (match (spec-substitute-values-expr-list body subs)
              [(OkSpecSubExprList rewritten-body)
                (OkSpecSubExpr
                  (ast-expr-in-arena rewritten-arena rewritten-body))]
              [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprWithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource bindings body)
          (OkSpecSubExpr
            (ast-node-push
              (AstExprWithResource (box (AstWithResource bindings body)))))])]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten) (OkSpecSubExpr (ast-expr-box rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-box-get rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBoxTake inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-box-take rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBoxSet inner-box value-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten-inner)
            (match (spec-substitute-values-expr value subs)
              [(OkSpecSubExpr rewritten-value)
                (OkSpecSubExpr
                  (ast-expr-box-set rewritten-inner rewritten-value))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-comptime rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten) (OkSpecSubExpr (ast-expr-try rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-return rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrNull ty) (OkSpecSubExpr (ast-node-push (AstExprPtrNull ty)))]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-null-check rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrAddrOf name)
      (match (spec-value-subst-lookup subs (intern-str name))
        [(SpecSomeString _)
          (ErrSpecSubExpr
            (box
              (spec-diagnostic-at-expr
                expr
                (string.string-append
                  "cannot take address of comptime value parameter '"
                  (string.string-append (intern-str name) "'")))))]
        [(SpecNoString) (OkSpecSubExpr (ast-expr-ptr-addr-of-id name))])]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-read rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(OkSpecSubExpr rewritten-ptr)
            (match (spec-substitute-values-expr value subs)
              [(OkSpecSubExpr rewritten-value)
                (OkSpecSubExpr
                  (ast-expr-ptr-write rewritten-ptr rewritten-value))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(OkSpecSubExpr rewritten-ptr)
            (match (spec-substitute-values-expr offset subs)
              [(OkSpecSubExpr rewritten-offset)
                (OkSpecSubExpr
                  (ast-expr-ptr-offset rewritten-ptr rewritten-offset))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrCast ptr-box ty)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-cast rewritten ty))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-to-int rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprIntToPtr value-box ty)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-values-expr value subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-int-to-ptr rewritten ty))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-string-data rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(OkSpecSubExpr rewritten-ptr)
            (match (spec-substitute-values-expr len subs)
              [(OkSpecSubExpr rewritten-len)
                (OkSpecSubExpr
                  (ast-expr-string-from-bytes rewritten-ptr rewritten-len))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprArrayData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-array-data rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBinaryData bytes)
      (OkSpecSubExpr (ast-node-push (AstExprBinaryData bytes)))]
    [(AstExprSpmdProgramIndex) (OkSpecSubExpr (ast-expr-spmd-program-index))]
    [(AstExprSpmdProgramCount) (OkSpecSubExpr (ast-expr-spmd-program-count))]
    [(AstExprProgramArgc) (OkSpecSubExpr (ast-node-push (AstExprProgramArgc)))]
    [(AstExprProgramArgv) (OkSpecSubExpr (ast-node-push (AstExprProgramArgv)))]
    [(AstExprProgramEnvp) (OkSpecSubExpr (ast-node-push (AstExprProgramEnvp)))]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-values-expr leaf subs)
          [(OkSpecSubExpr rewritten-leaf)
            (match (spec-substitute-values-expr subleaf subs)
              [(OkSpecSubExpr rewritten-subleaf)
                (OkSpecSubExpr
                  (ast-expr-cpuid-eax rewritten-leaf rewritten-subleaf))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-values-expr leaf subs)
          [(OkSpecSubExpr rewritten-leaf)
            (match (spec-substitute-values-expr subleaf subs)
              [(OkSpecSubExpr rewritten-subleaf)
                (OkSpecSubExpr
                  (ast-expr-cpuid-ebx rewritten-leaf rewritten-subleaf))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-values-expr leaf subs)
          [(OkSpecSubExpr rewritten-leaf)
            (match (spec-substitute-values-expr subleaf subs)
              [(OkSpecSubExpr rewritten-subleaf)
                (OkSpecSubExpr
                  (ast-expr-cpuid-ecx rewritten-leaf rewritten-subleaf))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-values-expr leaf subs)
          [(OkSpecSubExpr rewritten-leaf)
            (match (spec-substitute-values-expr subleaf subs)
              [(OkSpecSubExpr rewritten-subleaf)
                (OkSpecSubExpr
                  (ast-expr-cpuid-edx rewritten-leaf rewritten-subleaf))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-values-expr index subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-xgetbv rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprSyscall args)
      (match (spec-substitute-values-expr-list args subs)
        [(OkSpecSubExprList rewritten-args)
          (OkSpecSubExpr (ast-expr-syscall rewritten-args))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprQuote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten) (OkSpecSubExpr (ast-expr-quote rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprQuasiquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-quasiquote rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-unquote rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-unquote-splicing rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBracketClause items)
      (match (spec-substitute-values-expr-list items subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (ast-expr-bracket-clause rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprBorrow _ _ _) (OkSpecSubExpr (ast-node-push expr))]))

(define (spec-substitute-values-expr-list
  [exprs : AstExprList]
  [subs : SpecValueSubst]) : ResultSpecSubExprList
  (match exprs
    [(AstExprNil) (OkSpecSubExprList AstExprNil)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (match (spec-substitute-values-expr head subs)
          [(OkSpecSubExpr rewritten-head)
            (match (spec-substitute-values-expr-list rest subs)
              [(OkSpecSubExprList rewritten-rest)
                (OkSpecSubExprList
                  (ast-expr-cons rewritten-head rewritten-rest))]
              [(ErrSpecSubExprList diag) (ErrSpecSubExprList diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExprList diag)]))]))

(define (spec-substitute-values-let-bindings
  [bindings : AstLetBindingList]
  [subs : SpecValueSubst]) : ResultSpecSubLetBindingList
  (match bindings
    [(AstLetBindingNil) (OkSpecSubLetBindingList AstLetBindingNil)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name ty value-box)
            (let
              [value : AstExpr (ast-node-get value-box)]
              (match (spec-substitute-values-expr value subs)
                [(OkSpecSubExpr rewritten-value)
                  (match (spec-substitute-values-let-bindings
                    rest
                    (spec-value-subst-remove-name subs (intern-str name)))
                    [(OkSpecSubLetBindingList rewritten-rest)
                      (OkSpecSubLetBindingList
                        (ast-let-binding-cons
                          (ast-let-binding-id name ty rewritten-value)
                          rewritten-rest))]
                    [(ErrSpecSubLetBindingList diag)
                      (ErrSpecSubLetBindingList diag)])]
                [(ErrSpecSubExpr diag) (ErrSpecSubLetBindingList diag)]))]))]))

(define (spec-substitute-values-match-arms
  [arms : AstMatchArmList]
  [subs : SpecValueSubst]) : ResultSpecSubMatchArmList
  (match arms
    [(AstMatchArmNil) (OkSpecSubMatchArmList AstMatchArmNil)]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (match (spec-substitute-values-expr
                body
                (spec-value-subst-remove-pattern subs pattern))
                [(OkSpecSubExpr rewritten-body)
                  (match (spec-substitute-values-match-arms rest subs)
                    [(OkSpecSubMatchArmList rewritten-rest)
                      (OkSpecSubMatchArmList
                        (ast-match-arm-cons
                          (ast-match-arm pattern rewritten-body)
                          rewritten-rest))]
                    [(ErrSpecSubMatchArmList diag)
                      (ErrSpecSubMatchArmList diag)])]
                [(ErrSpecSubExpr diag) (ErrSpecSubMatchArmList diag)]))]))]))

(define (spec-substitute-types-expr [expr : AstExpr] [subs : SpecTypeSubst]) : ResultSpecSubExpr
  (match expr
    [(AstExprSpanned inner-box span)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-spanned rewritten span))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprVar name)
      (match (spec-type-subst-lookup subs (intern-str name))
        [(SpecSomeString _)
          (ErrSpecSubExpr
            (box
              (spec-diagnostic-at-expr
                expr
                (string.string-append
                  "type-valued comptime parameter '"
                  (string.string-append
                    (intern-str name)
                    "' cannot be used as a runtime value")))))]
        [(SpecNoString) (OkSpecSubExpr (ast-node-push expr))])]
    [(AstExprLiteral _) (OkSpecSubExpr (ast-node-push expr))]
    [(AstExprTypeLiteral ty)
      (OkSpecSubExpr
        (ast-node-push (AstExprTypeLiteral (spec-substitute-type ty subs))))]
    [(AstExprInit maybe-ty)
      (OkSpecSubExpr
        (ast-expr-init-maybe (spec-substitute-maybe-type maybe-ty subs)))]
    [(AstExprMakeArray elem-ty len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (match (spec-substitute-types-expr len subs)
          [(OkSpecSubExpr rewritten-len)
            (OkSpecSubExpr
              (ast-expr-make-array
                (spec-substitute-type elem-ty subs)
                rewritten-len))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprAnn inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr
              (ast-expr-ann rewritten (spec-substitute-type ty subs)))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr
              (ast-expr-cast rewritten (spec-substitute-type ty subs)))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprLambda lambda-box)
      (match (box-get lambda-box)
        [(AstLambda params ret body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-substitute-types-expr
              body
              (spec-type-subst-remove-params subs params))
              [(OkSpecSubExpr rewritten-body)
                (OkSpecSubExpr
                  (ast-expr-lambda
                    (spec-substitute-param-types params subs)
                    (spec-substitute-maybe-type ret subs)
                    rewritten-body))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))])]
    [(AstExprForeach fe-box)
      (match (box-get fe-box)
        [(AstForeach index index-ty start-box end-box body-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-substitute-types-expr start subs)
              [(OkSpecSubExpr rewritten-start)
                (match (spec-substitute-types-expr end subs)
                  [(OkSpecSubExpr rewritten-end)
                    (match (spec-substitute-types-expr
                      body
                      (spec-type-subst-remove-name subs (intern-str index)))
                      [(OkSpecSubExpr rewritten-body)
                        (OkSpecSubExpr
                          (ast-expr-foreach-id
                            index
                            (spec-substitute-type index-ty subs)
                            rewritten-start
                            rewritten-end
                            rewritten-body))]
                      [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
                  [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))])]
    [(AstExprSpmdReduce reduce-box)
      (match (box-get reduce-box)
        [(AstSpmdReduce op index index-ty start-box end-box init-box value-box)
          (let
            [start : AstExpr (ast-node-get start-box)]
            [end : AstExpr (ast-node-get end-box)]
            [init : AstExpr (ast-node-get init-box)]
            [value : AstExpr (ast-node-get value-box)]
            (match (spec-substitute-types-expr start subs)
              [(OkSpecSubExpr rewritten-start)
                (match (spec-substitute-types-expr end subs)
                  [(OkSpecSubExpr rewritten-end)
                    (match (spec-substitute-types-expr init subs)
                      [(OkSpecSubExpr rewritten-init)
                        (match (spec-substitute-types-expr
                          value
                          (spec-type-subst-remove-name subs (intern-str index)))
                          [(OkSpecSubExpr rewritten-value)
                            (OkSpecSubExpr
                              (ast-expr-spmd-reduce-id
                                op
                                index
                                (spec-substitute-type index-ty subs)
                                rewritten-start
                                rewritten-end
                                rewritten-init
                                rewritten-value))]
                          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
                      [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
                  [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))])]
    [(AstExprSpmdScan scan-box)
      (match (box-get scan-box)
        [(AstSpmdScan
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
              [(OkSpecSubExpr rewritten-start)
                (match (spec-substitute-types-expr end subs)
                  [(OkSpecSubExpr rewritten-end)
                    (match (spec-substitute-types-expr init subs)
                      [(OkSpecSubExpr rewritten-init)
                        (match (spec-substitute-types-expr value value-subs)
                          [(OkSpecSubExpr rewritten-value)
                            (match (spec-substitute-types-expr body body-subs)
                              [(OkSpecSubExpr rewritten-body)
                                (OkSpecSubExpr
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
                              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
                          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
                      [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
                  [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))])]
    [(AstExprSpmdBroadcast value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (spec-substitute-types-expr value subs)
          [(OkSpecSubExpr rewritten-value)
            (match (spec-substitute-types-expr lane subs)
              [(OkSpecSubExpr rewritten-lane)
                (OkSpecSubExpr
                  (ast-expr-spmd-broadcast rewritten-value rewritten-lane))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprSpmdShuffle value-box lane-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [lane : AstExpr (ast-node-get lane-box)]
        (match (spec-substitute-types-expr value subs)
          [(OkSpecSubExpr rewritten-value)
            (match (spec-substitute-types-expr lane subs)
              [(OkSpecSubExpr rewritten-lane)
                (OkSpecSubExpr
                  (ast-expr-spmd-shuffle rewritten-value rewritten-lane))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (match (spec-substitute-types-expr left subs)
          [(OkSpecSubExpr rewritten-left)
            (match (spec-substitute-types-expr right subs)
              [(OkSpecSubExpr rewritten-right)
                (OkSpecSubExpr
                  (ast-expr-binary op rewritten-left rewritten-right))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-unary op rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (match (spec-substitute-types-expr func subs)
          [(OkSpecSubExpr rewritten-func)
            (match (spec-substitute-types-expr-list args subs)
              [(OkSpecSubExprList rewritten-args)
                (OkSpecSubExpr (ast-expr-call rewritten-func rewritten-args))]
              [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (match (spec-substitute-types-expr cond subs)
          [(OkSpecSubExpr rewritten-cond)
            (match (spec-substitute-types-expr then-branch subs)
              [(OkSpecSubExpr rewritten-then)
                (match (spec-substitute-types-expr else-branch subs)
                  [(OkSpecSubExpr rewritten-else)
                    (OkSpecSubExpr
                      (ast-expr-if rewritten-cond rewritten-then rewritten-else))]
                  [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprLet let-box)
      (match (box-get let-box)
        [(AstLet bindings body-box)
          (let
            [body : AstExpr (ast-node-get body-box)]
            (match (spec-substitute-types-let-bindings bindings subs)
              [(OkSpecSubLetBindingList rewritten-bindings)
                (match (spec-substitute-types-expr
                  body
                  (spec-type-subst-remove-let-binding-names subs bindings))
                  [(OkSpecSubExpr rewritten-body)
                    (OkSpecSubExpr
                      (ast-expr-let rewritten-bindings rewritten-body))]
                  [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubLetBindingList diag) (ErrSpecSubExpr diag)]))])]
    [(AstExprTuple exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (ast-node-push (AstExprTuple rewritten)))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprTupleRef inner-box index)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-tuple-ref rewritten index))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprArray exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (ast-node-push (AstExprArray rewritten)))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-types-expr array subs)
          [(OkSpecSubExpr rewritten-array)
            (match (spec-substitute-types-expr index subs)
              [(OkSpecSubExpr rewritten-index)
                (OkSpecSubExpr
                  (ast-expr-array-ref rewritten-array rewritten-index))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-types-expr array subs)
          [(OkSpecSubExpr rewritten-array)
            (match (spec-substitute-types-expr index subs)
              [(OkSpecSubExpr rewritten-index)
                (match (spec-substitute-types-expr value subs)
                  [(OkSpecSubExpr rewritten-value)
                    (OkSpecSubExpr
                      (ast-expr-array-set
                        rewritten-array
                        rewritten-index
                        rewritten-value))]
                  [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-types-expr array subs)
          [(OkSpecSubExpr rewritten-array)
            (match (spec-substitute-types-expr value subs)
              [(OkSpecSubExpr rewritten-value)
                (OkSpecSubExpr
                  (ast-expr-array-push rewritten-array rewritten-value))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprStringRef text-box index-box)
      (let
        [text : AstExpr (ast-node-get text-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-types-expr text subs)
          [(OkSpecSubExpr rewritten-text)
            (match (spec-substitute-types-expr index subs)
              [(OkSpecSubExpr rewritten-index)
                (OkSpecSubExpr
                  (ast-expr-string-ref rewritten-text rewritten-index))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (match (spec-substitute-types-expr cond subs)
          [(OkSpecSubExpr rewritten-cond)
            (match (spec-substitute-types-expr body subs)
              [(OkSpecSubExpr rewritten-body)
                (OkSpecSubExpr (ast-expr-while rewritten-cond rewritten-body))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBegin exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (ast-node-push (AstExprBegin rewritten)))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprUnsafe exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (ast-node-push (AstExprUnsafe rewritten)))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprSet name value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-type-subst-lookup subs (intern-str name))
          [(SpecSomeString _)
            (ErrSpecSubExpr
              (box
                (spec-diagnostic-at-expr
                  expr
                  (string.string-append
                    "type-valued comptime parameter '"
                    (string.string-append
                      (intern-str name)
                      "' cannot be assigned")))))]
          [(SpecNoString)
            (match (spec-substitute-types-expr value subs)
              [(OkSpecSubExpr rewritten)
                (OkSpecSubExpr (ast-expr-set-id name rewritten))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]))]
    [(AstExprMatch match-box)
      (match (box-get match-box)
        [(AstMatch scrutinee-box arms)
          (let
            [scrutinee : AstExpr (ast-node-get scrutinee-box)]
            (match (spec-substitute-types-expr scrutinee subs)
              [(OkSpecSubExpr rewritten-scrutinee)
                (match (spec-substitute-types-match-arms arms subs)
                  [(OkSpecSubMatchArmList rewritten-arms)
                    (OkSpecSubExpr
                      (ast-expr-match rewritten-scrutinee rewritten-arms))]
                  [(ErrSpecSubMatchArmList diag) (ErrSpecSubExpr diag)])]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))])]
    [(AstExprStructGet receiver-box field)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (match (spec-substitute-types-expr receiver subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-struct-get-id rewritten field))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprStructSet receiver-box field value-box)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-types-expr receiver subs)
          [(OkSpecSubExpr rewritten-receiver)
            (match (spec-substitute-types-expr value subs)
              [(OkSpecSubExpr rewritten-value)
                (OkSpecSubExpr
                  (ast-expr-struct-set-id
                    rewritten-receiver
                    field
                    rewritten-value))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprWithRegion region body)
      (match (spec-substitute-types-expr-list body subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (ast-node-push (AstExprWithRegion region rewritten)))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (match (spec-substitute-types-expr scratch subs)
          [(OkSpecSubExpr rewritten-scratch)
            (match (spec-substitute-types-expr-list body subs)
              [(OkSpecSubExprList rewritten-body)
                (OkSpecSubExpr
                  (ast-expr-with-escape rewritten-scratch rewritten-body))]
              [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprWithScratch body)
      (match (spec-substitute-types-expr-list body subs)
        [(OkSpecSubExprList rewritten-body)
          (OkSpecSubExpr (ast-expr-with-scratch rewritten-body))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprInArena arena-box body)
      (let
        [arena : AstExpr (ast-node-get arena-box)]
        (match (spec-substitute-types-expr arena subs)
          [(OkSpecSubExpr rewritten-arena)
            (match (spec-substitute-types-expr-list body subs)
              [(OkSpecSubExprList rewritten-body)
                (OkSpecSubExpr
                  (ast-expr-in-arena rewritten-arena rewritten-body))]
              [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprWithResource wr-box)
      (match (box-get wr-box)
        [(AstWithResource bindings body)
          (OkSpecSubExpr
            (ast-node-push
              (AstExprWithResource (box (AstWithResource bindings body)))))])]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten) (OkSpecSubExpr (ast-expr-box rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-box-get rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBoxTake inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-box-take rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBoxSet inner-box value-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten-inner)
            (match (spec-substitute-types-expr value subs)
              [(OkSpecSubExpr rewritten-value)
                (OkSpecSubExpr
                  (ast-expr-box-set rewritten-inner rewritten-value))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-comptime rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten) (OkSpecSubExpr (ast-expr-try rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-return rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrNull ty)
      (OkSpecSubExpr
        (ast-node-push (AstExprPtrNull (spec-substitute-type ty subs))))]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-null-check rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrAddrOf name)
      (match (spec-type-subst-lookup subs (intern-str name))
        [(SpecSomeString _)
          (ErrSpecSubExpr
            (box
              (spec-diagnostic-at-expr
                expr
                (string.string-append
                  "type-valued comptime parameter '"
                  (string.string-append
                    (intern-str name)
                    "' cannot be used as a runtime value")))))]
        [(SpecNoString) (OkSpecSubExpr (ast-expr-ptr-addr-of-id name))])]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-read rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(OkSpecSubExpr rewritten-ptr)
            (match (spec-substitute-types-expr value subs)
              [(OkSpecSubExpr rewritten-value)
                (OkSpecSubExpr
                  (ast-expr-ptr-write rewritten-ptr rewritten-value))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(OkSpecSubExpr rewritten-ptr)
            (match (spec-substitute-types-expr offset subs)
              [(OkSpecSubExpr rewritten-offset)
                (OkSpecSubExpr
                  (ast-expr-ptr-offset rewritten-ptr rewritten-offset))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrCast ptr-box ty)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr
              (ast-expr-ptr-cast rewritten (spec-substitute-type ty subs)))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-to-int rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprIntToPtr value-box ty)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-substitute-types-expr value subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr
              (ast-expr-int-to-ptr rewritten (spec-substitute-type ty subs)))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-string-data rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(OkSpecSubExpr rewritten-ptr)
            (match (spec-substitute-types-expr len subs)
              [(OkSpecSubExpr rewritten-len)
                (OkSpecSubExpr
                  (ast-expr-string-from-bytes rewritten-ptr rewritten-len))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprArrayData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-array-data rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBinaryData bytes)
      (OkSpecSubExpr (ast-node-push (AstExprBinaryData bytes)))]
    [(AstExprSpmdProgramIndex) (OkSpecSubExpr (ast-expr-spmd-program-index))]
    [(AstExprSpmdProgramCount) (OkSpecSubExpr (ast-expr-spmd-program-count))]
    [(AstExprProgramArgc) (OkSpecSubExpr (ast-node-push (AstExprProgramArgc)))]
    [(AstExprProgramArgv) (OkSpecSubExpr (ast-node-push (AstExprProgramArgv)))]
    [(AstExprProgramEnvp) (OkSpecSubExpr (ast-node-push (AstExprProgramEnvp)))]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-types-expr leaf subs)
          [(OkSpecSubExpr rewritten-leaf)
            (match (spec-substitute-types-expr subleaf subs)
              [(OkSpecSubExpr rewritten-subleaf)
                (OkSpecSubExpr
                  (ast-expr-cpuid-eax rewritten-leaf rewritten-subleaf))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-types-expr leaf subs)
          [(OkSpecSubExpr rewritten-leaf)
            (match (spec-substitute-types-expr subleaf subs)
              [(OkSpecSubExpr rewritten-subleaf)
                (OkSpecSubExpr
                  (ast-expr-cpuid-ebx rewritten-leaf rewritten-subleaf))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-types-expr leaf subs)
          [(OkSpecSubExpr rewritten-leaf)
            (match (spec-substitute-types-expr subleaf subs)
              [(OkSpecSubExpr rewritten-subleaf)
                (OkSpecSubExpr
                  (ast-expr-cpuid-ecx rewritten-leaf rewritten-subleaf))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (spec-substitute-types-expr leaf subs)
          [(OkSpecSubExpr rewritten-leaf)
            (match (spec-substitute-types-expr subleaf subs)
              [(OkSpecSubExpr rewritten-subleaf)
                (OkSpecSubExpr
                  (ast-expr-cpuid-edx rewritten-leaf rewritten-subleaf))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (match (spec-substitute-types-expr index subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-xgetbv rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprSyscall args)
      (match (spec-substitute-types-expr-list args subs)
        [(OkSpecSubExprList rewritten-args)
          (OkSpecSubExpr (ast-expr-syscall rewritten-args))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprQuote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten) (OkSpecSubExpr (ast-expr-quote rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprQuasiquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-quasiquote rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-unquote rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-unquote-splicing rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBracketClause items)
      (match (spec-substitute-types-expr-list items subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (ast-expr-bracket-clause rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprBorrow _ _ _) (OkSpecSubExpr (ast-node-push expr))]))

(define (spec-substitute-types-expr-list
  [exprs : AstExprList]
  [subs : SpecTypeSubst]) : ResultSpecSubExprList
  (match exprs
    [(AstExprNil) (OkSpecSubExprList AstExprNil)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (match (spec-substitute-types-expr head subs)
          [(OkSpecSubExpr rewritten-head)
            (match (spec-substitute-types-expr-list rest subs)
              [(OkSpecSubExprList rewritten-rest)
                (OkSpecSubExprList
                  (ast-expr-cons rewritten-head rewritten-rest))]
              [(ErrSpecSubExprList diag) (ErrSpecSubExprList diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExprList diag)]))]))

(define (spec-substitute-types-let-bindings
  [bindings : AstLetBindingList]
  [subs : SpecTypeSubst]) : ResultSpecSubLetBindingList
  (match bindings
    [(AstLetBindingNil) (OkSpecSubLetBindingList AstLetBindingNil)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name ty value-box)
            (let
              [value : AstExpr (ast-node-get value-box)]
              (match (spec-substitute-types-expr value subs)
                [(OkSpecSubExpr rewritten-value)
                  (match (spec-substitute-types-let-bindings
                    rest
                    (spec-type-subst-remove-name subs (intern-str name)))
                    [(OkSpecSubLetBindingList rewritten-rest)
                      (OkSpecSubLetBindingList
                        (ast-let-binding-cons
                          (ast-let-binding-id
                            name
                            (spec-substitute-maybe-type ty subs)
                            rewritten-value)
                          rewritten-rest))]
                    [(ErrSpecSubLetBindingList diag)
                      (ErrSpecSubLetBindingList diag)])]
                [(ErrSpecSubExpr diag) (ErrSpecSubLetBindingList diag)]))]))]))

(define (spec-substitute-types-match-arms
  [arms : AstMatchArmList]
  [subs : SpecTypeSubst]) : ResultSpecSubMatchArmList
  (match arms
    [(AstMatchArmNil) (OkSpecSubMatchArmList AstMatchArmNil)]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (match (spec-substitute-types-expr
                body
                (spec-type-subst-remove-pattern subs pattern))
                [(OkSpecSubExpr rewritten-body)
                  (match (spec-substitute-types-match-arms rest subs)
                    [(OkSpecSubMatchArmList rewritten-rest)
                      (OkSpecSubMatchArmList
                        (ast-match-arm-cons
                          (ast-match-arm pattern rewritten-body)
                          rewritten-rest))]
                    [(ErrSpecSubMatchArmList diag)
                      (ErrSpecSubMatchArmList diag)])]
                [(ErrSpecSubExpr diag) (ErrSpecSubMatchArmList diag)]))]))]))

(define (spec-rewrite-decl
  [decl : AstDecl]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecDecl
  (match decl
    [(AstDeclDef name ty value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (spec-rewrite-expr value templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecDecl
              (SpecSomeDecl (ast-decl-def-id name ty rewritten))
              state2)]
          [(ErrSpecExpr diag) (ErrSpecDecl diag)]))]
    [(AstDeclDefFn name params ret body-box export)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (if (spec-param-list-has-comptime? params)
          (OkSpecDecl (SpecNoDecl) state)
          (match (spec-rewrite-expr
            body
            (spec-template-env-shadow-params templates params)
            state)
            [(OkSpecExpr rewritten state2)
              (OkSpecDecl
                (SpecSomeDecl
                  (ast-decl-def-fn-export-id name params ret rewritten export))
                state2)]
            [(ErrSpecExpr diag) (ErrSpecDecl diag)])))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (match (spec-rewrite-decl inner templates state)
          [(OkSpecDecl maybe state2)
            (match maybe
              [(SpecSomeDecl rewritten)
                (OkSpecDecl (SpecSomeDecl (ast-decl-unsafe rewritten)) state2)]
              [(SpecNoDecl) (OkSpecDecl SpecNoDecl state2)])]
          [(ErrSpecDecl diag) (ErrSpecDecl diag)]))]
    [(AstDeclDefMacro name params ret body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (spec-rewrite-expr body templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecDecl
              (SpecSomeDecl (ast-decl-def-macro-id name params ret rewritten))
              state2)]
          [(ErrSpecExpr diag) (ErrSpecDecl diag)]))]
    [_ (OkSpecDecl (SpecSomeDecl decl) state)]))

(define (spec-rewrite-decls
  [decls : AstDeclList]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecDecls
  (match decls
    [(AstDeclNil) (OkSpecDecls AstDeclNil state)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match (spec-rewrite-decl decl templates state)
          [(OkSpecDecl maybe-decl decl-state)
            (match (spec-rewrite-decls rest templates decl-state)
              [(OkSpecDecls rewritten-rest rest-state)
                (match maybe-decl
                  [(SpecNoDecl) (OkSpecDecls rewritten-rest rest-state)]
                  [(SpecSomeDecl rewritten-decl)
                    (OkSpecDecls
                      (ast-decl-cons rewritten-decl rewritten-rest)
                      rest-state)])]
              [(ErrSpecDecls diag) (ErrSpecDecls diag)])]
          [(ErrSpecDecl diag) (ErrSpecDecls diag)]))]))

(define (spec-rewrite-decls-with-paths
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [fallback-path : String]
  [templates : SpecTemplateEnv]
  [state : SpecState]) : ResultSpecDeclsWithPaths
  (match decls
    [(AstDeclNil) (OkSpecDeclsWithPaths AstDeclNil AstDeclPathNil state)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        [decl-path : String (gen-path-list-head-or paths fallback-path)]
        [rest-paths : AstDeclPathList (gen-path-list-tail paths)]
        (match (spec-rewrite-decl decl templates state)
          [(OkSpecDecl maybe-decl decl-state)
            (match (spec-rewrite-decls-with-paths
              rest
              rest-paths
              fallback-path
              templates
              decl-state)
              [(OkSpecDeclsWithPaths
                  rewritten-rest
                  rewritten-rest-paths
                  rest-state)
                (match maybe-decl
                  [(SpecNoDecl)
                    (OkSpecDeclsWithPaths
                      rewritten-rest
                      rewritten-rest-paths
                      rest-state)]
                  [(SpecSomeDecl rewritten-decl)
                    (OkSpecDeclsWithPaths
                      (ast-decl-cons rewritten-decl rewritten-rest)
                      (ast-decl-path-cons decl-path rewritten-rest-paths)
                      rest-state)])]
              [(ErrSpecDeclsWithPaths diag) (ErrSpecDeclsWithPaths diag)])]
          [(ErrSpecDecl diag) (ErrSpecDeclsWithPaths diag)]))]))

(define (spec-generated-paths [decls : AstDeclList] [fallback-path : String]) : AstDeclPathList
  (if (string.string-eq fallback-path "")
    AstDeclPathNil
    (gen-path-list-for-decls decls fallback-path AstDeclPathNil)))

(define (compiler-specialize-program-active [program : AstProgram]) : ResultSpecProgram
  (match (gen-normalize-program-active program)
    [(OkGenProgram normalized)
      (match normalized
        [(AstProgram decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            [templates : SpecTemplateList (spec-collect-templates decls)]
            (match templates
              [(SpecTemplateNil) (OkSpecProgram normalized)]
              [_
                (match (spec-rewrite-decls
                  decls
                  (spec-template-env-from-list templates)
                  (SpecState
                    AstDeclNil
                    (hashmap.string-string-map-with-capacity 64)
                    (ctfe-env-with-reflections
                      (ctfe-reflections-from-program normalized))
                    (ast-node-pool-context-capture-active)))
                  [(OkSpecDecls rewritten state)
                    (match state
                      [(SpecState generated _ _ _)
                        (OkSpecProgram
                          (ast-program
                            (spec-decl-list-append rewritten generated)))])]
                  [(ErrSpecDecls diag) (ErrSpecProgram diag)])]))])]
    [(ErrGenProgram diag) (ErrSpecProgram diag)]))

(define (compiler-specialize-program-with-paths-active
  [program : AstProgram]
  [paths : AstDeclPathList]
  [fallback-path : String]) : ResultSpecProgramWithPaths
  (match (gen-normalize-program-with-paths-active program paths fallback-path)
    [(OkGenProgramWithPaths normalized normalized-paths)
      (match normalized
        [(AstProgram decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            [templates : SpecTemplateList (spec-collect-templates decls)]
            (match templates
              [(SpecTemplateNil)
                (OkSpecProgramWithPaths normalized normalized-paths)]
              [_
                (match (spec-rewrite-decls-with-paths
                  decls
                  normalized-paths
                  fallback-path
                  (spec-template-env-from-list templates)
                  (SpecState
                    AstDeclNil
                    (hashmap.string-string-map-with-capacity 64)
                    (ctfe-env-with-reflections
                      (ctfe-reflections-from-program normalized))
                    (ast-node-pool-context-capture-active)))
                  [(OkSpecDeclsWithPaths rewritten rewritten-paths state)
                    (match state
                      [(SpecState generated _ _ _)
                        (OkSpecProgramWithPaths
                          (ast-program
                            (spec-decl-list-append rewritten generated))
                          (spec-decl-path-list-append
                            rewritten-paths
                            (spec-generated-paths generated fallback-path)))])]
                  [(ErrSpecDeclsWithPaths diag) (ErrSpecProgramWithPaths diag)])]))])]
    [(ErrGenProgramWithPaths diag) (ErrSpecProgramWithPaths diag)]))

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

(define (compiler-specialize-needed? [program : AstProgram]) : bool
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (if (gen-decls-needed? decls)
          true
          (match (spec-collect-templates decls)
            [(SpecTemplateNil) false]
            [_ true])))]))

(define (compiler-specialize-decl-list-defines?
  [decls : AstDeclList]
  [name : String]) : bool
  (match decls
    [(AstDeclNil) false]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclUnsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDeclDefFn fn-name _ _ _ _)
                  (if (string.string-eq (intern-str fn-name) name)
                    true
                    (compiler-specialize-decl-list-defines? rest name))]
                [(AstDeclComptimeDecl _ template-box)
                  (let
                    [template : AstDecl (box-get template-box)]
                    (match template
                      [(AstDeclDefFn fn-name _ _ _ _)
                        (if (string.string-eq (intern-str fn-name) name)
                          true
                          (compiler-specialize-decl-list-defines? rest name))]
                      [_ (compiler-specialize-decl-list-defines? rest name)]))]
                [_ (compiler-specialize-decl-list-defines? rest name)]))]
          [(AstDeclDefFn fn-name _ _ _ _)
            (if (string.string-eq (intern-str fn-name) name)
              true
              (compiler-specialize-decl-list-defines? rest name))]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDeclDefFn fn-name _ _ _ _)
                  (if (string.string-eq (intern-str fn-name) name)
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
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram specialized)
          (match specialized
            [(AstProgram decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                (and
                  (not (compiler-specialize-decl-list-defines? decls "alloc"))
                  (compiler-specialize-decl-list-defines?
                    decls
                    "__tl_specialized_alloc_type_i64_none")))])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-specialize-runtime-type-use-rejected?) : bool
  (match (parse-ast-source (compiler-specialize-runtime-type-use-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram _) false]
        [(ErrSpecProgram _) true])]
    [(ErrAstProgram _) false]))

(define (compiler-specialize-template-shadow-ok?) : bool
  (match (parse-ast-source (compiler-specialize-template-shadow-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram _) true]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-specialize-template-shadow-sibling-ok?) : bool
  (match (parse-ast-source (compiler-specialize-template-shadow-sibling-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram specialized)
          (match specialized
            [(AstProgram decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                [original : bool
                  (compiler-specialize-decl-list-defines? decls "scale")]
                [generated : bool
                  (compiler-specialize-decl-list-defines?
                    decls
                    "__tl_specialized_scale_i64_2_none")]
                (and (not original) generated))])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-specialize-type-shadow-ok?) : bool
  (match (parse-ast-source (compiler-specialize-type-shadow-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram specialized)
          (match specialized
            [(AstProgram decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                (compiler-specialize-decl-list-defines?
                  decls
                  "__tl_specialized_pick_type_i64_none"))])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-specialize-raw-pointer-type-ok?) : bool
  (let
    [subs : SpecTypeSubst
      (spec-type-subst-cons "T" (AstTyI64) SpecTypeSubstNil)]
    (and
      (string.string-eq (spec-type-key (ast-ty-ptr (AstTyI64))) "ptr_i64")
      (string.string-eq
        (spec-type-key (ast-ty-mut-ptr (ast-ty-ptr (AstTyU8))))
        "mutptr_ptr_u8")
      (ctfe-type-eq
        (spec-substitute-type (ast-ty-mut-ptr (AstTyVar (intern "T"))) subs)
        (ast-ty-mut-ptr (AstTyI64))))))

;: Deterministic specialized name + stable specialization key (#1043, mirrors
;: src/specialize.rs deterministic-names / stable-keys coverage). The mangling
;: is a pure function of the template name and comptime argument values, so
;: identical args produce identical names, distinct type args never collide,
;: multi-value ordering is stable, and negative scalars / arbitrary strings
;: encode without punctuation that could break generated identifiers.
(define (compiler-specialize-name-key-ok?) : bool
  (let
    [vals-i64 : SpecValueList
      (spec-value-cons (CtfeType (AstTyI64)) (SpecValueNil))]
    [vals-bool : SpecValueList
      (spec-value-cons (CtfeType (AstTyBool)) (SpecValueNil))]
    [vals-multi : SpecValueList
      (spec-value-cons
        (CtfeType (AstTyI64))
        (spec-value-cons (CtfeI64 5) (SpecValueNil)))]
    [vals-string : SpecValueList
      (spec-value-cons (CtfeString "a b") (SpecValueNil))]
    (and
      (string.string-eq
        (spec-specialized-name "alloc" vals-i64)
        "__tl_specialized_alloc_type_i64_none")
      (string.string-eq
        (spec-specialized-name "alloc" vals-i64)
        (spec-specialized-name "alloc" vals-i64))
      (string.string-eq
        (spec-specialization-key "alloc" vals-i64)
        "alloc:type_i64_none")
      (not
        (string.string-eq
          (spec-specialized-name "alloc" vals-i64)
          (spec-specialized-name "alloc" vals-bool)))
      (string.string-eq
        (spec-specialized-name "pair" vals-multi)
        "__tl_specialized_pair_type_i64_i64_5_none")
      (string.string-eq (spec-value-key (CtfeI64 (- 0 3))) "i64_m3")
      (string.string-eq
        (spec-specialized-name "name" vals-string)
        "__tl_specialized_name_string_3_97_32_98_none"))))

;: Count function declarations named `name` in `decls` (specialized decls are
;: emitted as ordinary `AstDeclDefFn`s, so reuse means a count of exactly 1).
(define (compiler-specialize-decl-list-count-defs
  [decls : AstDeclList]
  [name : String]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclUnsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDeclDefFn fn-name _ _ _ _)
                  (if (string.string-eq (intern-str fn-name) name)
                    (+ 1 (compiler-specialize-decl-list-count-defs rest name))
                    (compiler-specialize-decl-list-count-defs rest name))]
                [(AstDeclComptimeDecl _ template-box)
                  (let
                    [template : AstDecl (box-get template-box)]
                    (match template
                      [(AstDeclDefFn fn-name _ _ _ _)
                        (if (string.string-eq (intern-str fn-name) name)
                          (+
                            1
                            (compiler-specialize-decl-list-count-defs rest name))
                          (compiler-specialize-decl-list-count-defs rest name))]
                      [_ (compiler-specialize-decl-list-count-defs rest name)]))]
                [_ (compiler-specialize-decl-list-count-defs rest name)]))]
          [(AstDeclDefFn fn-name _ _ _ _)
            (if (string.string-eq (intern-str fn-name) name)
              (+ 1 (compiler-specialize-decl-list-count-defs rest name))
              (compiler-specialize-decl-list-count-defs rest name))]
          [(AstDeclComptimeDecl _ inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDeclDefFn fn-name _ _ _ _)
                  (if (string.string-eq (intern-str fn-name) name)
                    (+ 1 (compiler-specialize-decl-list-count-defs rest name))
                    (compiler-specialize-decl-list-count-defs rest name))]
                [_ (compiler-specialize-decl-list-count-defs rest name)]))]
          [_ (compiler-specialize-decl-list-count-defs rest name)]))]))

(define (compiler-specialize-decl-list-count-visible
  [decls : AstDeclList]
  [name : String]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        [tail-count : i64
          (compiler-specialize-decl-list-count-visible rest name)]
        (match (gen-decl-visible-name decl)
          [(SpecSomeString found)
            (if (string.string-eq found name)
              (+ 1 tail-count)
              tail-count)]
          [(SpecNoString) tail-count]))]))

;: Two call sites that request the SAME specialization (`alloc` at `type i64`)
;: must share one generated decl via the specialization cache, not emit two.
(define (compiler-specialize-reuse-source) : String
  "(define (alloc [comptime T : type] [n : i64]) : (Array i64)
  (make-array T n))
(define (main) : (Array i64)
  (begin (alloc (type i64) 4) (alloc (type i64) 8)))")

;: Specialization reuse (#1043, mirrors src/specialize.rs reuse coverage): two
;: identical `alloc (type i64)` requests collapse to a single shared
;: `__tl_specialized_alloc_type_i64_none` decl (the cache dedups by key) and the
;: `alloc` template is removed.
(define (compiler-specialize-reuse-ok?) : bool
  (match (parse-ast-source (compiler-specialize-reuse-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram specialized)
          (match specialized
            [(AstProgram decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                (and
                  (not (compiler-specialize-decl-list-defines? decls "alloc"))
                  (=
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "__tl_specialized_alloc_type_i64_none")
                    1)))])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

;: Type substitution (#1043, mirrors src/specialize.rs substitution coverage):
;: `spec-substitute-type` replaces a mapped type variable with its bound type,
;: recurses through compound types (Ptr/DynArray/function), and leaves an
;: unmapped variable unchanged (the SpecNoString lookup branch). Complements
;: the single MutPtr case embedded in `compiler-specialize-raw-pointer-type-ok?`.
(define (compiler-specialize-subst-ok?) : bool
  (let
    [subs : SpecTypeSubst
      (spec-type-subst-cons "T" (AstTyI64) SpecTypeSubstNil)]
    (and
      (string.string-eq
        (spec-type-key (spec-substitute-type (AstTyVar (intern "T")) subs))
        "i64")
      (string.string-eq
        (spec-type-key
          (spec-substitute-type (ast-ty-ptr (AstTyVar (intern "T"))) subs))
        "ptr_i64")
      (string.string-eq
        (spec-type-key
          (spec-substitute-type (ast-ty-dyn-array (AstTyVar (intern "T"))) subs))
        "dynarray_i64")
      (string.string-eq
        (spec-type-key
          (spec-substitute-type
            (ast-ty-func
              (ast-type-cons (AstTyVar (intern "T")) AstTypeNil)
              (AstTyVar (intern "T")))
            subs))
        "fn_i64_nil_to_i64")
      (string.string-eq
        (spec-type-key (spec-substitute-type (AstTyVar (intern "U")) subs))
        "var_U"))))

;: Value (comptime-argument) substitution (#1043, mirrors src/specialize.rs
;: substitution coverage): `spec-substitute-values-expr` replaces a variable
;: bound to a comptime value with that value's literal, leaves unmapped
;: variables and literals unchanged, and recurses through compound expressions.
(define (compiler-specialize-value-subst-ok?) : bool
  (let
    [subs : SpecValueSubst
      (spec-value-subst-cons "x" (CtfeI64 5) SpecValueSubstNil)]
    (and
      ;; mapped variable x -> integer literal 5
      (match (spec-substitute-values-expr (AstExprVar (intern "x")) subs)
        [(OkSpecSubExpr e)
          (match (ast-node-get e)
            [(AstExprLiteral lit)
              (match lit
                [(AstLitInt n _) (= n 5)]
                [_ false])]
            [_ false])]
        [(ErrSpecSubExpr _) false])
      ;; unmapped variable y -> unchanged
      (match (spec-substitute-values-expr (AstExprVar (intern "y")) subs)
        [(OkSpecSubExpr e)
          (match (ast-node-get e)
            [(AstExprVar name) (string.string-eq (intern-str name) "y")]
            [_ false])]
        [(ErrSpecSubExpr _) false])
      ;; recursion through `if`: x in the condition becomes 5, unmapped y stays
      (match (spec-substitute-values-expr
        (AstExprIf
          (ast-node-push (AstExprVar (intern "x")))
          (ast-node-push (AstExprLiteral (ast-lit-int 1)))
          (ast-node-push (AstExprVar (intern "y"))))
        subs)
        [(OkSpecSubExpr e)
          (match (ast-node-get e)
            [(AstExprIf cond-box _ else-branch-box)
              (let
                [cond : AstExpr (ast-node-get cond-box)]
                [else-branch : AstExpr (ast-node-get else-branch-box)]
                (and
                  (match cond
                    [(AstExprLiteral lit)
                      (match lit
                        [(AstLitInt n _) (= n 5)]
                        [_ false])]
                    [_ false])
                  (match else-branch
                    [(AstExprVar name) (string.string-eq (intern-str name) "y")]
                    [_ false])))]
            [_ false])]
        [(ErrSpecSubExpr _) false]))))

(define (compiler-specialize-boxed-tails-ok?) : bool
  (let
    [templates : SpecTemplateList
      (spec-template-cons
        (SpecTemplate
          "first"
          AstParamNil
          (AstTyI64)
          (AstExprLiteral (ast-lit-int 1)))
        (spec-template-cons
          (SpecTemplate
            "second"
            AstParamNil
            (AstTyBool)
            (AstExprLiteral (AstLitBool true)))
          SpecTemplateNil))]
    [template-env : SpecTemplateEnv (spec-template-env-from-list templates)]
    [cache : hashmap.StringStringMap
      (hashmap.string-string-map-put
        (hashmap.string-string-map-put
          (hashmap.string-string-map-with-capacity 8)
          "two"
          "generated-two")
        "one"
        "generated-one")]
    [values : SpecValueList
      (spec-value-cons
        (CtfeI64 1)
        (spec-value-cons (CtfeBool true) SpecValueNil))]
    [value-subs : SpecValueSubst
      (spec-value-subst-cons
        "x"
        (CtfeI64 1)
        (spec-value-subst-cons "flag" (CtfeBool true) SpecValueSubstNil))]
    [type-subs : SpecTypeSubst
      (spec-type-subst-cons
        "T"
        (AstTyI64)
        (spec-type-subst-cons "U" (AstTyBool) SpecTypeSubstNil))]
    (and
      (match (spec-template-lookup template-env "second")
        [(SpecSomeTemplate template)
          (match template
            [(SpecTemplate name _ _ _) (string.string-eq name "second")])]
        [(SpecNoTemplate) false])
      (match (spec-cache-lookup cache "two")
        [(SpecSomeString name) (string.string-eq name "generated-two")]
        [(SpecNoString) false])
      (string.string-eq (spec-values-key values) "i64_1_bool_1_none")
      (match (spec-value-subst-value value-subs "flag")
        [(CtfeBool flag) flag]
        [_ false])
      (ctfe-type-eq (spec-type-subst-type type-subs "U") (AstTyBool)))))

(define (compiler-specialize-reflection-string-param-source) : String
  "(defstruct Point (x i64))
(define (tag-helper [comptime key : String] [x : i64]) : i64 x)
(define (main) : i64 (tag-helper (type-key (type Point)) 7))")

(define (compiler-specialize-reflection-string-param-ok?) : bool
  (match (parse-ast-source (compiler-specialize-reflection-string-param-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram specialized)
          (match specialized
            [(AstProgram decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                (compiler-specialize-decl-list-defines?
                  decls
                  "__tl_specialized_tag-helper_string_12_115_116_114_117_99_116_95_80_111_105_110_116_none"))])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

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
    (string.string-append (spec-string-key "String") "_none")))

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
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram normalized)
          (match normalized
            [(AstProgram decls-box)
              (compiler-specialize-decl-list-count-visible
                (box-get decls-box)
                name)])]
        [(ErrSpecProgram _) -1])]
    [(ErrAstProgram _) -1]))

(define (compiler-generated-decl-reuse-ok?) : bool
  (match (parse-ast-source (compiler-generated-decl-reuse-source))
    [(OkAstProgram program)
      (and
        (compiler-specialize-needed? program)
        (match (compiler-specialize-program program)
          [(OkSpecProgram normalized)
            (match normalized
              [(AstProgram decls-box)
                (let
                  [decls : AstDeclList (box-get decls-box)]
                  (=
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "Box_String")
                    1))])]
          [(ErrSpecProgram _) false]))]
    [(ErrAstProgram _) false]))

(define (compiler-generated-decl-function-reuse-ok?) : bool
  (match (parse-ast-source (compiler-generated-decl-function-reuse-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram normalized)
          (match normalized
            [(AstProgram decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                (=
                  (compiler-specialize-decl-list-count-defs
                    decls
                    "make-box-string")
                  1))])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-generated-decl-incompatible-rejected?) : bool
  (match (parse-ast-source (compiler-generated-decl-incompatible-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram _) false]
        [(ErrSpecProgram _) true])]
    [(ErrAstProgram _) false]))

(define (compiler-generated-decl-incompatible-note-ok?) : bool
  (match (parse-ast-source (compiler-generated-decl-incompatible-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram _) false]
        [(ErrSpecProgram diag)
          (match (compiler-diagnostic-notes (box-get diag))
            [(CompilerDiagnosticNoteCons note _)
              (string.string-eq
                note
                (string.string-append
                  "generated identity: "
                  (compiler-generated-decl-expected-string-key)))]
            [(CompilerDiagnosticNoteNil) false])])]
    [(ErrAstProgram _) false]))

(define (compiler-generated-decl-item-mismatch-rejected?) : bool
  (match (parse-ast-source (compiler-generated-decl-item-mismatch-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram _) false]
        [(ErrSpecProgram _) true])]
    [(ErrAstProgram _) false]))

(define (compiler-generated-decl-non-string-key-rejected?) : bool
  (match (parse-ast-source (compiler-generated-decl-non-string-key-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram _) false]
        [(ErrSpecProgram _) true])]
    [(ErrAstProgram _) false]))

(define (compiler-generated-decl-duplicate-visible-left-for-symbols?) : bool
  (match (parse-ast-source (compiler-generated-decl-duplicate-visible-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram normalized)
          (match normalized
            [(AstProgram decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                (=
                  (compiler-specialize-decl-list-count-visible
                    decls
                    "Box_String")
                  2))])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

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
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram normalized)
          (match normalized
            [(AstProgram decls-box)
              (match (box-get decls-box)
                [(AstDeclCons decl _)
                  (match decl
                    [(AstDeclComptimeDecl meta template-box)
                      (and
                        (match meta
                          [(AstSomeGeneratedDeclMeta generator item _ key)
                            (and
                              (string.string-eq generator "sample-family")
                              (string.string-eq item "Box_String")
                              (string.string-eq
                                key
                                (compiler-generated-decl-expected-string-key)))]
                          [(AstNoGeneratedDeclMeta) false])
                        (match (box-get template-box)
                          [(AstDeclDefStruct name _ _ _)
                            (string.string-eq (intern-str name) "Box_String")]
                          [_ false]))]
                    [_ false])]
                [(AstDeclNil) false])])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-generated-registry-map-ok?) : bool
  (let
    [decl : AstDecl
      (ast-decl-def-struct
        "RegistryBox"
        AstStructReprDefault
        AstStructNoCleanup
        AstFieldDefNil)]
    [registry : GenRegistry
      (gen-registry-insert (gen-registry-empty) "generated-key" decl)]
    (match (gen-registry-lookup registry "generated-key")
      [(GenSomeEntry found) (gen-decl-eq? found decl)]
      [(GenNoEntry) false])))

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