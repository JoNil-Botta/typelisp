;; compiler_specialize.tl - Selfhost comptime function specialization (#832).
(import "../stdlib/io.tl")
(import "../stdlib/text_buf.tl")
(import "compiler_ctfe.tl")
(import "compiler_diagnostic.tl")
(import "compiler_float.tl")
(import "compiler_parse_core.tl")
(import "../stdlib/string.tl")
(import "../stdlib/hashmap.tl")

(defstruct GenRegistry
  (index StringI64Map)
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
  (index StringI64Map)
  (values (Array SpecMaybeTemplate))
  (shadowed SpecTemplateShadowList))

;; #2613: the specialization cache (key -> generated function name) is a
;; generated StringStringMap; the former SpecCache linked list made every
;; lookup a linear scan.
(defenum SpecState
  (SpecState AstDeclList StringStringMap CtfeEnv))

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
  (ErrSpecProgram CompilerDiagnostic))

(defenum ResultSpecDecls
  (OkSpecDecls AstDeclList SpecState)
  (ErrSpecDecls CompilerDiagnostic))

(defenum ResultSpecDecl
  (OkSpecDecl SpecMaybeDecl SpecState)
  (ErrSpecDecl CompilerDiagnostic))

(defenum ResultSpecExpr
  (OkSpecExpr i64 SpecState)
  (ErrSpecExpr CompilerDiagnostic))

(defenum ResultSpecExprList
  (OkSpecExprList AstExprList SpecState)
  (ErrSpecExprList CompilerDiagnostic))

(defenum ResultSpecLetBindingList
  (OkSpecLetBindingList AstLetBindingList SpecState)
  (ErrSpecLetBindingList CompilerDiagnostic))

(defenum ResultSpecMatchArmList
  (OkSpecMatchArmList AstMatchArmList SpecState)
  (ErrSpecMatchArmList CompilerDiagnostic))

(defenum ResultSpecArgs
  (OkSpecArgs SpecValueList AstExprList SpecState)
  (ErrSpecArgs CompilerDiagnostic))

(defenum ResultSpecEnsure
  (OkSpecEnsure String SpecState)
  (ErrSpecEnsure CompilerDiagnostic))

(defenum ResultSpecBuild
  (OkSpecBuild AstParamList SpecValueSubst SpecTypeSubst)
  (ErrSpecBuild CompilerDiagnostic))

(defenum ResultSpecSubExpr
  (OkSpecSubExpr i64)
  (ErrSpecSubExpr CompilerDiagnostic))

(defenum ResultSpecSubExprList
  (OkSpecSubExprList AstExprList)
  (ErrSpecSubExprList CompilerDiagnostic))

(defenum ResultSpecSubLetBindingList
  (OkSpecSubLetBindingList AstLetBindingList)
  (ErrSpecSubLetBindingList CompilerDiagnostic))

(defenum ResultSpecSubMatchArmList
  (OkSpecSubMatchArmList AstMatchArmList)
  (ErrSpecSubMatchArmList CompilerDiagnostic))

(defenum GenMaybeEntry
  (GenNoEntry)
  (GenSomeEntry AstDecl))

(defenum ResultGenKey
  (OkGenKey String i64)
  (ErrGenKey CompilerDiagnostic))

(defenum ResultGenDecl
  (OkGenDecl AstDeclList GenRegistry String)
  (ErrGenDecl CompilerDiagnostic))

(defenum ResultGenDecls
  (OkGenDecls AstDeclList GenRegistry String)
  (ErrGenDecls CompilerDiagnostic))

(defenum ResultGenProgram
  (OkGenProgram AstProgram)
  (ErrGenProgram CompilerDiagnostic))

(defenum ResultGenDeclsWithPaths
  (OkGenDeclsWithPaths AstDeclList AstDeclPathList GenRegistry String)
  (ErrGenDeclsWithPaths CompilerDiagnostic))

(defenum ResultGenProgramWithPaths
  (OkGenProgramWithPaths AstProgram AstDeclPathList)
  (ErrGenProgramWithPaths CompilerDiagnostic))

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
    [(SpecState _ _ env) env]))

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
      (if (string-eq shadow-name name)
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
      (array-set! values index (SpecNoTemplate))
      (spec-template-values-fill-empty values (+ index 1) count))))

(define (spec-template-index-build
  [templates : SpecTemplateList]
  [index : StringI64Map]
  [values : (Array SpecMaybeTemplate)]
  [slot : i64]) : StringI64Map
  (match templates
    [(SpecTemplateNil) index]
    [(SpecTemplateCons template rest)
      (match template
        [(SpecTemplate name _ _ _)
          (if (string-i64-map-contains? index name)
            (spec-template-index-build (box-get rest) index values slot)
            (begin
              (array-set! values slot (SpecSomeTemplate template))
              (spec-template-index-build
                (box-get rest)
                (string-i64-map-put index name slot)
                values
                (+ slot 1))))])]))

(define (spec-template-env-from-list [templates : SpecTemplateList]) : SpecTemplateEnv
  (let
    [count : i64 (spec-template-list-count templates)]
    [values : (Array SpecMaybeTemplate) (make-array SpecMaybeTemplate count)]
    (begin
      (spec-template-values-fill-empty values 0 count)
      (SpecTemplateEnv
        (spec-template-index-build
          templates
          (string-i64-map-with-capacity (+ (* count 2) 16))
          values
          0)
        values
        SpecTemplateShadowNil))))

(define (spec-template-lookup [templates : SpecTemplateEnv] [name : String]) : SpecMaybeTemplate
  (if (spec-template-shadow-contains? (struct-get templates shadowed) name)
    (SpecNoTemplate)
    (match (string-i64-map-get (struct-get templates index) name)
      [(StringI64MapFound slot) (array-ref (struct-get templates values) slot)]
      [(StringI64MapMissing) (SpecNoTemplate)])))

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

(define (spec-cache-lookup [cache : StringStringMap] [key : String]) : SpecMaybeString
  (match (string-string-map-get cache key)
    [(StringStringMapFound name) (SpecSomeString name)]
    [(StringStringMapMissing) (SpecNoString)]))

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

(define (gen-single-decl-list [decl : AstDecl]) : AstDeclList
  (ast-decl-cons decl AstDeclNil))

(define (spec-int-key [n : i64]) : String
  (if (< n 0)
    (string-append "m" (int->string (- 0 n)))
    (int->string n)))

(define (spec-string-key-from [text : String] [idx : i64] [n : i64]) : String
  (if (>= idx n)
    ""
    (string-append
      "_"
      (string-append
        (int->string (cast (string-ref text idx) : i64))
        (spec-string-key-from text (+ idx 1) n)))))

(define (spec-string-key [text : String]) : String
  (let
    [n : i64 (string-length text)]
    (string-append
      "string_"
      (string-append (int->string n) (spec-string-key-from text 0 n)))))

(define (spec-type-list-key [types : AstTypeList]) : String
  (match types
    [(AstTypeNil) "nil"]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ty-node-get head)]
        [rest : AstTypeList (box-get rest)]
        (string-append
          (spec-type-key head)
          (string-append "_" (spec-type-list-key rest))))]))

(define (spec-lifetime-list-key [lifetimes : AstLifetimeList]) : String
  (match lifetimes
    [(AstLifetimeNil) "nil"]
    [(AstLifetimeCons head rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (string-append head (string-append "_" (spec-lifetime-list-key rest))))]))

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
      (string-append
        "fn_"
        (string-append
          (spec-type-list-key args)
          (string-append "_to_" (spec-type-key (ty-node-get ret)))))]
    [(AstTyTuple elems) (string-append "tuple_" (spec-type-list-key elems))]
    [(AstTyArray elem count)
      (string-append
        "array_"
        (string-append
          (spec-type-key (ty-node-get elem))
          (string-append "_" (spec-int-key count))))]
    [(AstTyDynArray elem)
      (string-append "dynarray_" (spec-type-key (ty-node-get elem)))]
    [(AstTyBox elem) (string-append "box_" (spec-type-key (ty-node-get elem)))]
    [(AstTyPtr elem) (string-append "ptr_" (spec-type-key (ty-node-get elem)))]
    [(AstTyMutPtr elem)
      (string-append "mutptr_" (spec-type-key (ty-node-get elem)))]
    [(AstTyRef region inner)
      (string-append
        "ref_"
        (string-append
          region
          (string-append "_" (spec-type-key (ty-node-get inner)))))]
    [(AstTyMutRef region inner)
      (string-append
        "mutref_"
        (string-append
          region
          (string-append "_" (spec-type-key (ty-node-get inner)))))]
    [(AstTyRegion region inner)
      (string-append
        "region_"
        (string-append
          region
          (string-append "_" (spec-type-key (ty-node-get inner)))))]
    [(AstTyEnum name) (string-append "enum_" (intern-str name))]
    [(AstTyEnumArgs name lifetimes)
      (string-append
        "enumargs_"
        (string-append
          (intern-str name)
          (string-append "_" (spec-lifetime-list-key lifetimes))))]
    [(AstTyStruct name) (string-append "struct_" (intern-str name))]
    [(AstTyStructArgs name lifetimes)
      (string-append
        "structargs_"
        (string-append
          (intern-str name)
          (string-append "_" (spec-lifetime-list-key lifetimes))))]
    [(AstTyVar name) (string-append "var_" (intern-str name))]
    [(AstTyVarArgs name lifetimes)
      (string-append
        "varargs_"
        (string-append
          (intern-str name)
          (string-append "_" (spec-lifetime-list-key lifetimes))))]))

(define (spec-value-key [value : CompilerCtfeValue]) : String
  (match value
    [(CtfeI64 n) (string-append "i64_" (spec-int-key n))]
    [(CtfeF64 n)
      (string-append "f64_" (spec-string-key (compiler-float-format-f64 n)))]
    [(CtfeF32 n)
      (string-append
        "f32_"
        (spec-string-key
          (compiler-float-format-f64 (compiler-float-round-f32-as-f64 n))))]
    [(CtfeBool b)
      (if b
        "bool_1"
        "bool_0")]
    [(CtfeChar c) (string-append "char_" (int->string (cast c : i64)))]
    [(CtfeString text) (spec-string-key text)]
    [(CtfeUnit) "unit"]
    [(CtfeType ty) (string-append "type_" (spec-type-key ty))]
    [(CtfeExpr _ _) "Expr"]
    [(CtfeExprList _) "expr-list"]
    [(CtfeExprClause _) "expr-clause"]
    [(CtfeExprClauseList _) "expr-clause-list"]))

(define (spec-values-key [values : SpecValueList]) : String
  (match values
    [(SpecValueNil) "none"]
    [(SpecValueCons head rest)
      (string-append
        (spec-value-key head)
        (string-append "_" (spec-values-key (box-get rest))))]))

(define (spec-specialization-key [name : String] [values : SpecValueList]) : String
  (string-append name (string-append ":" (spec-values-key values))))

(define (spec-specialized-name [name : String] [values : SpecValueList]) : String
  (string-append
    "__tl_specialized_"
    (string-append name (string-append "_" (spec-values-key values)))))

(define (gen-registry-empty) : GenRegistry
  (let
    [capacity : i64 64]
    [decls : (Array AstDecl) (make-array AstDecl capacity)]
    (GenRegistry (string-i64-map-with-capacity capacity) decls 0)))

(define (gen-registry-lookup [registry : GenRegistry] [key : String]) : GenMaybeEntry
  (match (string-i64-map-get (struct-get registry index) key)
    [(StringI64MapFound slot)
      (GenSomeEntry (array-ref (struct-get registry decls) slot))]
    [(StringI64MapMissing) (GenNoEntry)]))

(define (gen-registry-copy-decls
  [src : (Array AstDecl)]
  [dst : (Array AstDecl)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (gen-registry-copy-decls src dst (+ index 1) count))))

(define (gen-registry-grow [registry : GenRegistry]) : GenRegistry
  (let
    [old-index : StringI64Map (struct-get registry index)]
    [old-decls : (Array AstDecl) (struct-get registry decls)]
    [old-len : i64 (struct-get registry len)]
    [old-capacity : i64 (array-length old-decls)]
    [new-capacity : i64
      (if (< old-capacity 1)
        1
        (* old-capacity 2))]
    [new-decls : (Array AstDecl) (make-array AstDecl new-capacity)]
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
        (array-length (struct-get registry decls)))
        (gen-registry-grow registry)
        registry)]
    [slot : i64 (struct-get ready len)]
    [decls : (Array AstDecl) (struct-get ready decls)]
    [index : StringI64Map (struct-get ready index)]
    (begin
      (array-set! decls slot decl)
      (GenRegistry (string-i64-map-put index key slot) decls (+ slot 1)))))

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

(define (gen-export-item-eq? [a : AstExportItem] [b : AstExportItem]) : bool
  (match a
    [(AstExportValue a-name)
      (match b
        [(AstExportValue b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstExportType a-name)
      (match b
        [(AstExportType b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstExportMacro a-name)
      (match b
        [(AstExportMacro b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstExportConstructor a-name)
      (match b
        [(AstExportConstructor b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstExportField a-type a-field)
      (match b
        [(AstExportField b-type b-field)
          (and (string-eq a-type b-type) (string-eq a-field b-field))]
        [_ false])]
    [(AstExportVariant a-name)
      (match b
        [(AstExportVariant b-name) (string-eq a-name b-name)]
        [_ false])]))

(define (gen-export-item-list-eq?
  [a : AstExportItemList]
  [b : AstExportItemList]) : bool
  (match a
    [(AstExportItemNil)
      (match b
        [(AstExportItemNil) true]
        [_ false])]
    [(AstExportItemCons a-head a-rest)
      (let
        [a-rest : AstExportItemList (box-get a-rest)]
        (match b
          [(AstExportItemCons b-head b-rest)
            (let
              [b-rest : AstExportItemList (box-get b-rest)]
              (and
                (gen-export-item-eq? a-head b-head)
                (gen-export-item-list-eq? a-rest b-rest)))]
          [_ false]))]))

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
    [(AstImportMacro _)
      (match b
        [(AstImportMacro _) true]
        [_ false])]
    [(AstImportMacroDecls _)
      (match b
        [(AstImportMacroDecls _) true]
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
        [(AstSomeModuleName b-name) (string-eq a-name b-name)]
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
        [(AstSomeImportAlias b-name) (string-eq a-name b-name)]
        [_ false])]))

(define (gen-import-spec-eq? [a : AstImportSpec] [b : AstImportSpec]) : bool
  (match a
    [(AstImportSpec a-kind a-path a-module a-alias _)
      (match b
        [(AstImportSpec b-kind b-path b-module b-alias _)
          (and
            (gen-import-kind-eq? a-kind b-kind)
            (string-eq a-path b-path)
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
          (and (string-eq a-name b-name) (string-eq a-path b-path))]
        [_ false])]
    [(AstDeclIncludeBin a-name a-path)
      (match b
        [(AstDeclIncludeBin b-name b-path)
          (and (string-eq a-name b-name) (string-eq a-path b-path))]
        [_ false])]
    [(AstDeclExport a-items)
      (match b
        [(AstDeclExport b-items) (gen-export-item-list-eq? a-items b-items)]
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
                      (string-append
                        (spec-string-key text)
                        (string-append "_" tail))
                      tail-fuel)]
                  [(ErrGenKey diag) (ErrGenKey diag)])]
              [_
                (ErrGenKey
                  (spec-diagnostic-at-expr
                    head-expr
                    "generated-decl: key expression must evaluate to String"))])]
          [(ErrCtfe diag) (ErrGenKey diag)]))]))

(define (gen-full-key
  [module : String]
  [generator : String]
  [item : String]
  [arg-key : String]) : String
  (string-append
    "generated:"
    (string-append
      (spec-string-key module)
      (string-append
        ":"
        (string-append
          (spec-string-key generator)
          (string-append
            ":"
            (string-append (spec-string-key item) (string-append ":" arg-key))))))))

(define (gen-item-mismatch-diag [expected : String] [actual : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start
    ""
    (string-append
      "generated-decl: metadata item "
      (string-append expected (string-append " does not match payload " actual)))))

(define (gen-incompatible-diag [item : String] [key : String]) : CompilerDiagnostic
  (compiler-diagnostic-with-note
    (compiler-diagnostic-with-note
      (compiler-diagnostic-at-start
        ""
        (string-append
          "generated-decl: duplicate generated key for "
          (string-append item " has incompatible payload")))
      (string-append "conflicting generated item: " item))
    (string-append "generated identity: " key)))

(defenum GenHashmapTypeInfo
  (GenHashmapTypeInfo String String String))

(defenum ResultGenHashmapTypeInfo
  (OkGenHashmapTypeInfo GenHashmapTypeInfo)
  (ErrGenHashmapTypeInfo CompilerDiagnostic))

(defenum ResultGenHashmapType
  (OkGenHashmapType AstType)
  (ErrGenHashmapType CompilerDiagnostic))

(defenum GenHashmapArgs
  (GenHashmapArgs String String String))

(defenum ResultGenHashmapArgs
  (OkGenHashmapArgs GenHashmapArgs)
  (ErrGenHashmapArgs CompilerDiagnostic))

(defenum ResultGenHashmapSource
  (OkGenHashmapSource String)
  (ErrGenHashmapSource CompilerDiagnostic))

(defenum GenSetArgs
  (GenSetArgs String String))

(defenum ResultGenSetArgs
  (OkGenSetArgs GenSetArgs)
  (ErrGenSetArgs CompilerDiagnostic))

(defenum ResultGenSetSource
  (OkGenSetSource String)
  (ErrGenSetSource CompilerDiagnostic))

(defenum ResultGenJsonType
  (OkGenJsonType AstType)
  (ErrGenJsonType CompilerDiagnostic))

(defenum GenJsonDeriveArgs
  (GenJsonDeriveArgs AstType))

(defenum ResultGenJsonDeriveArgs
  (OkGenJsonDeriveArgs GenJsonDeriveArgs)
  (ErrGenJsonDeriveArgs CompilerDiagnostic))

(defenum ResultGenJsonSource
  (OkGenJsonSource String)
  (ErrGenJsonSource CompilerDiagnostic))

(define (gen-tb2 [buf : TextBuf] [a : String] [b : String]) : TextBuf
  (text-buf-append (text-buf-append buf a) b))

(define (gen-tb3 [buf : TextBuf] [a : String] [b : String] [c : String]) : TextBuf
  (text-buf-append (gen-tb2 buf a b) c))

(define (gen-tb4
  [buf : TextBuf]
  [a : String]
  [b : String]
  [c : String]
  [d : String]) : TextBuf
  (text-buf-append (gen-tb3 buf a b c) d))

(define (gen-tb5
  [buf : TextBuf]
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : TextBuf
  (text-buf-append (gen-tb4 buf a b c d) e))

(define (gen-tb6
  [buf : TextBuf]
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]) : TextBuf
  (text-buf-append (gen-tb5 buf a b c d e) f))

(define (gen-tb7
  [buf : TextBuf]
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]
  [g : String]) : TextBuf
  (text-buf-append (gen-tb6 buf a b c d e f) g))

(define (gen-hashmap-diag [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start "" message))

(define (gen-hashmap-eval-string [expr : AstExpr] [env : CtfeEnv]) : ResultGenKey
  (match (compiler-ctfe-eval expr env (ctfe-fuel-limit))
    [(OkCtfe value fuel)
      (match value
        [(CtfeString text) (OkGenKey text fuel)]
        [_
          (ErrGenKey
            (spec-diagnostic-at-expr
              expr
              "hashmap-family: argument must evaluate to String"))])]
    [(ErrCtfe diag) (ErrGenKey diag)]))

(define (gen-hashmap-args [args : AstExprList] [env : CtfeEnv]) : ResultGenHashmapArgs
  (match args
    [(AstExprCons key-expr-box rest1-box)
      (match (box-get rest1-box)
        [(AstExprCons value-expr-box rest2-box)
          (match (box-get rest2-box)
            [(AstExprCons descriptor-expr-box rest3-box)
              (match (box-get rest3-box)
                [(AstExprNil)
                  (let
                    [key-expr : AstExpr (ast-node-get key-expr-box)]
                    [value-expr : AstExpr (ast-node-get value-expr-box)]
                    [descriptor-expr : AstExpr
                      (ast-node-get descriptor-expr-box)]
                    (match (gen-hashmap-eval-string key-expr env)
                      [(OkGenKey key-type _)
                        (match (gen-hashmap-eval-string value-expr env)
                          [(OkGenKey value-type _)
                            (match (gen-hashmap-eval-string descriptor-expr env)
                              [(OkGenKey descriptor _)
                                (OkGenHashmapArgs
                                  (GenHashmapArgs
                                    key-type
                                    value-type
                                    descriptor))]
                              [(ErrGenKey diag) (ErrGenHashmapArgs diag)])]
                          [(ErrGenKey diag) (ErrGenHashmapArgs diag)])]
                      [(ErrGenKey diag) (ErrGenHashmapArgs diag)]))]
                [_
                  (ErrGenHashmapArgs
                    (gen-hashmap-diag
                      "hashmap-family: expected key type, value type, and key descriptor arguments"))])]
            [_
              (ErrGenHashmapArgs
                (gen-hashmap-diag
                  "hashmap-family: expected key type, value type, and key descriptor arguments"))])]
        [_
          (ErrGenHashmapArgs
            (gen-hashmap-diag
              "hashmap-family: expected key type, value type, and key descriptor arguments"))])]
    [_
      (ErrGenHashmapArgs
        (gen-hashmap-diag
          "hashmap-family: expected key type, value type, and key descriptor arguments"))]))

(define (gen-set-diag [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start "" message))

(define (gen-set-eval-string [expr : AstExpr] [env : CtfeEnv]) : ResultGenKey
  (match (compiler-ctfe-eval expr env (ctfe-fuel-limit))
    [(OkCtfe value fuel)
      (match value
        [(CtfeString text) (OkGenKey text fuel)]
        [_
          (ErrGenKey
            (spec-diagnostic-at-expr
              expr
              "set-family: argument must evaluate to String"))])]
    [(ErrCtfe diag) (ErrGenKey diag)]))

(define (gen-set-args [args : AstExprList] [env : CtfeEnv]) : ResultGenSetArgs
  (match args
    [(AstExprCons key-expr-box rest1-box)
      (match (box-get rest1-box)
        [(AstExprCons descriptor-expr-box rest2-box)
          (match (box-get rest2-box)
            [(AstExprNil)
              (let
                [key-expr : AstExpr (ast-node-get key-expr-box)]
                [descriptor-expr : AstExpr (ast-node-get descriptor-expr-box)]
                (match (gen-set-eval-string key-expr env)
                  [(OkGenKey key-type _)
                    (match (gen-set-eval-string descriptor-expr env)
                      [(OkGenKey descriptor _)
                        (OkGenSetArgs (GenSetArgs key-type descriptor))]
                      [(ErrGenKey diag) (ErrGenSetArgs diag)])]
                  [(ErrGenKey diag) (ErrGenSetArgs diag)]))]
            [_
              (ErrGenSetArgs
                (gen-set-diag
                  "set-family: expected key type and key descriptor arguments"))])]
        [_
          (ErrGenSetArgs
            (gen-set-diag
              "set-family: expected key type and key descriptor arguments"))])]
    [_
      (ErrGenSetArgs
        (gen-set-diag
          "set-family: expected key type and key descriptor arguments"))]))

(define (gen-json-diag [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start "" message))

(define (gen-json-type-from-key [type-key : String]) : ResultGenJsonType
  (cond
    [(string-eq type-key "i64") (OkGenJsonType AstTyI64)]
    [(string-eq type-key "i32") (OkGenJsonType AstTyI32)]
    [(string-eq type-key "i16") (OkGenJsonType AstTyI16)]
    [(string-eq type-key "i8") (OkGenJsonType AstTyI8)]
    [(string-eq type-key "u64") (OkGenJsonType AstTyU64)]
    [(string-eq type-key "u32") (OkGenJsonType AstTyU32)]
    [(string-eq type-key "u16") (OkGenJsonType AstTyU16)]
    [(string-eq type-key "u8") (OkGenJsonType AstTyU8)]
    [(string-eq type-key "bool") (OkGenJsonType AstTyBool)]
    [(string-eq type-key "String") (OkGenJsonType AstTyString)]
    [else
      (match (gen-hashmap-nominal-name type-key "struct_")
        [(SpecSomeString name) (OkGenJsonType (AstTyStruct (intern name)))]
        [(SpecNoString)
          (ErrGenJsonType
            (gen-json-diag
              (string-append "json-derive: unsupported type-key " type-key)))])]))

(define (gen-json-eval-type [expr : AstExpr] [env : CtfeEnv]) : ResultGenJsonType
  (match (compiler-ctfe-eval expr env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeType ty)
          (OkGenJsonType
            (ctfe-reflect-resolve-type (ctfe-env-reflections env) ty))]
        [(CtfeString type-key) (gen-json-type-from-key type-key)]
        [_
          (ErrGenJsonType
            (spec-diagnostic-at-expr
              expr
              "json-derive: argument must evaluate to a type or type-key String"))])]
    [(ErrCtfe diag) (ErrGenJsonType diag)]))

(define (gen-json-args [args : AstExprList] [env : CtfeEnv]) : ResultGenJsonDeriveArgs
  (match args
    [(AstExprCons type-expr-box rest-box)
      (match (box-get rest-box)
        [(AstExprNil)
          (let
            [type-expr : AstExpr (ast-node-get type-expr-box)]
            (match (gen-json-eval-type type-expr env)
              [(OkGenJsonType ty) (OkGenJsonDeriveArgs (GenJsonDeriveArgs ty))]
              [(ErrGenJsonType diag) (ErrGenJsonDeriveArgs diag)]))]
        [_
          (ErrGenJsonDeriveArgs
            (gen-json-diag "json-derive: expected one struct type argument"))])]
    [_
      (ErrGenJsonDeriveArgs
        (gen-json-diag "json-derive: expected one struct type argument"))]))

(define (gen-hashmap-one-byte-string [code : i64]) : String
  (let
    [buf : (Array u8) (make-array u8 1)]
    (begin
      (array-set! buf 0 (cast code : u8))
      (unsafe
        (string-from-bytes (ptr-cast (array-data buf) : (Ptr u8)) 1)))))

(define (gen-hashmap-name-prefix-char [name : String] [index : i64]) : String
  (let
    [c : char (string-ref name index)]
    [code : i64 (cast c : i64)]
    (if (and (>= code 65) (<= code 90))
      (string-append
        (if (> index 0)
          "-"
          "")
        (gen-hashmap-one-byte-string (+ code 32)))
      (if (= code 95)
        "-"
        (substring name index 1)))))

(define (gen-hashmap-name-prefix-from [name : String] [index : i64] [n : i64]) : String
  (if (>= index n)
    ""
    (string-append
      (gen-hashmap-name-prefix-char name index)
      (gen-hashmap-name-prefix-from name (+ index 1) n))))

(define (gen-hashmap-name-prefix [name : String]) : String
  (gen-hashmap-name-prefix-from name 0 (string-length name)))

(define (gen-hashmap-nominal-name [type-key : String] [prefix : String]) : SpecMaybeString
  (let
    [prefix-len : i64 (string-length prefix)]
    [type-key-len : i64 (string-length type-key)]
    (if (and
      (> type-key-len prefix-len)
      (is-string-prefix-at (& type-key) (& prefix) 0))
      (SpecSomeString
        (substring type-key prefix-len (- type-key-len prefix-len)))
      (SpecNoString))))

(define (gen-hashmap-scalar-type-info [type-key : String] [role : String]) : ResultGenHashmapTypeInfo
  (if (string-eq type-key "String")
    (OkGenHashmapTypeInfo (GenHashmapTypeInfo "String" "String" "string"))
    (if (string-eq type-key "i64")
      (OkGenHashmapTypeInfo (GenHashmapTypeInfo "i64" "I64" "i64"))
      (ErrGenHashmapTypeInfo
        (gen-hashmap-diag
          (string-append
            "hashmap-family: unsupported "
            (string-append role (string-append " type " type-key))))))))

(define (gen-hashmap-value-type-info [type-key : String]) : ResultGenHashmapTypeInfo
  (match (gen-hashmap-scalar-type-info type-key "value")
    [(OkGenHashmapTypeInfo info) (OkGenHashmapTypeInfo info)]
    [(ErrGenHashmapTypeInfo _)
      (match (gen-hashmap-nominal-name type-key "struct_")
        [(SpecSomeString name)
          (OkGenHashmapTypeInfo
            (GenHashmapTypeInfo name name (gen-hashmap-name-prefix name)))]
        [(SpecNoString)
          (match (gen-hashmap-nominal-name type-key "enum_")
            [(SpecSomeString name)
              (OkGenHashmapTypeInfo
                (GenHashmapTypeInfo name name (gen-hashmap-name-prefix name)))]
            [(SpecNoString)
              (ErrGenHashmapTypeInfo
                (gen-hashmap-diag
                  (string-append
                    "hashmap-family: unsupported value type "
                    type-key)))])])]))

(define (gen-hashmap-nominal-type-info [type-key : String] [role : String]) : ResultGenHashmapTypeInfo
  (match (gen-hashmap-nominal-name type-key "struct_")
    [(SpecSomeString name)
      (OkGenHashmapTypeInfo
        (GenHashmapTypeInfo name name (gen-hashmap-name-prefix name)))]
    [(SpecNoString)
      (match (gen-hashmap-nominal-name type-key "enum_")
        [(SpecSomeString name)
          (OkGenHashmapTypeInfo
            (GenHashmapTypeInfo name name (gen-hashmap-name-prefix name)))]
        [(SpecNoString)
          (ErrGenHashmapTypeInfo
            (gen-hashmap-diag
              (string-append
                "hashmap-family: unsupported "
                (string-append role (string-append " type " type-key)))))])]))

(define (gen-hashmap-key-type-info [type-key : String] [descriptor : String]) : ResultGenHashmapTypeInfo
  (match (gen-hashmap-scalar-type-info type-key "key")
    [(OkGenHashmapTypeInfo info) (OkGenHashmapTypeInfo info)]
    [(ErrGenHashmapTypeInfo _)
      (if (string-eq descriptor "stdlib/hashmap/aggregate-key-v1")
        (gen-hashmap-nominal-type-info type-key "key")
        (ErrGenHashmapTypeInfo
          (gen-hashmap-diag
            (string-append
              "hashmap-family: unsupported key descriptor "
              (string-append
                descriptor
                (string-append " for key type " type-key))))))]))

(define (gen-hashmap-borrowed-value-type [value-type : String]) : String
  (if (string-eq value-type "String")
    "str"
    value-type))

(define (gen-hashmap-family-marker-fields? [fields : AstFieldDefList]) : bool
  (match fields
    [(AstFieldDefCons field rest-box)
      (match field
        [(AstFieldDef name ty cleanup)
          (and
            (string-eq (intern-str name) "__hashmap_family_request")
            (ctfe-type-eq ty (AstTyI64))
            (match cleanup
              [(AstFieldNoCleanup) true]
              [_ false])
            (match (box-get rest-box)
              [(AstFieldDefNil) true]
              [_ false]))])]
    [_ false]))

(define (gen-hashmap-family-marker-name [decl : AstDecl]) : SpecMaybeString
  (match decl
    [(AstDeclDefStruct name repr cleanup fields)
      (match repr
        [(AstStructReprDefault)
          (match cleanup
            [(AstStructNoCleanup)
              (if (gen-hashmap-family-marker-fields? fields)
                (SpecSomeString (intern-str name))
                (SpecNoString))]
            [_ (SpecNoString)])]
        [_ (SpecNoString)])]
    [_ (SpecNoString)]))

(define (gen-set-family-marker-fields? [fields : AstFieldDefList]) : bool
  (match fields
    [(AstFieldDefCons field rest-box)
      (match field
        [(AstFieldDef name ty cleanup)
          (and
            (string-eq (intern-str name) "__set_family_request")
            (ctfe-type-eq ty (AstTyI64))
            (match cleanup
              [(AstFieldNoCleanup) true]
              [_ false])
            (match (box-get rest-box)
              [(AstFieldDefNil) true]
              [_ false]))])]
    [_ false]))

(define (gen-set-family-marker-name [decl : AstDecl]) : SpecMaybeString
  (match decl
    [(AstDeclDefStruct name repr cleanup fields)
      (match repr
        [(AstStructReprDefault)
          (match cleanup
            [(AstStructNoCleanup)
              (if (gen-set-family-marker-fields? fields)
                (SpecSomeString (intern-str name))
                (SpecNoString))]
            [_ (SpecNoString)])]
        [_ (SpecNoString)])]
    [_ (SpecNoString)]))

(define (gen-json-derive-marker-fields? [fields : AstFieldDefList]) : bool
  (match fields
    [(AstFieldDefCons field rest-box)
      (match field
        [(AstFieldDef name ty cleanup)
          (and
            (string-eq (intern-str name) "__json_derive_request")
            (ctfe-type-eq ty (AstTyI64))
            (match cleanup
              [(AstFieldNoCleanup) true]
              [_ false])
            (match (box-get rest-box)
              [(AstFieldDefNil) true]
              [_ false]))])]
    [_ false]))

(define (gen-json-derive-marker-name [decl : AstDecl]) : SpecMaybeString
  (match decl
    [(AstDeclDefStruct name repr cleanup fields)
      (match repr
        [(AstStructReprDefault)
          (match cleanup
            [(AstStructNoCleanup)
              (if (gen-json-derive-marker-fields? fields)
                (SpecSomeString (intern-str name))
                (SpecNoString))]
            [_ (SpecNoString)])]
        [_ (SpecNoString)])]
    [_ (SpecNoString)]))

(define (gen-hashmap-source-string-key
  [map-name : String]
  [prefix : String]
  [value-type : String]) : String
  (let
    [slot : String (string-append map-name "Slot")]
    [empty : String (string-append map-name "Empty")]
    [tombstone : String (string-append map-name "Tombstone")]
    [occupied : String (string-append map-name "Occupied")]
    [probe : String (string-append map-name "Probe")]
    [probe-found : String (string-append map-name "ProbeFound")]
    [probe-absent : String (string-append map-name "ProbeAbsent")]
    [probe-full : String (string-append map-name "ProbeFull")]
    [lookup : String (string-append map-name "Lookup")]
    [missing : String (string-append map-name "Missing")]
    [found : String (string-append map-name "Found")]
    [borrowed-value-lookup : String
      (string-append map-name "BorrowedValueLookup")]
    [borrowed-value-missing : String
      (string-append map-name "BorrowedValueMissing")]
    [borrowed-value-found : String
      (string-append map-name "BorrowedValueFound")]
    [borrowed-value-type : String (gen-hashmap-borrowed-value-type value-type)]
    [insert-result : String (string-append map-name "InsertResult")]
    [insert-ok : String (string-append map-name "InsertOk")]
    [insert-full : String (string-append map-name "InsertFull")]
    [remove-result : String (string-append map-name "RemoveResult")]
    [remove-ok : String (string-append map-name "RemoveOk")]
    [remove-missing : String (string-append map-name "RemoveMissing")]
    [update-result : String (string-append map-name "UpdateResult")]
    [update-ok : String (string-append map-name "UpdateOk")]
    [update-missing : String (string-append map-name "UpdateMissing")]
    [entry-or-insert-result : String
      (string-append map-name "EntryOrInsertResult")]
    [entry-or-insert-found : String
      (string-append map-name "EntryOrInsertFound")]
    [entry-or-insert-inserted : String
      (string-append map-name "EntryOrInsertInserted")]
    [mut-entry-info : String (string-append map-name "MutEntryInfo")]
    [mut-entry : String (string-append map-name "MutEntry")]
    [entry : String (string-append map-name "Entry")]
    [entry-none : String (string-append map-name "EntryNone")]
    [entry-some : String (string-append map-name "EntrySome")]
    [buf : TextBuf (text-buf-empty)]
    (begin
      (set! buf (gen-tb5 buf "(defenum " slot "\n  (" empty ")\n  ("))
      (set! buf (gen-tb5 buf tombstone ")\n  (" occupied " String " value-type))
      (set! buf (gen-tb3 buf " i64))\n(defenum " probe "\n"))
      (set!
        buf
        (gen-tb5 buf "  (" probe-found " i64)\n  (" probe-absent " i64)\n"))
      (set! buf (gen-tb5 buf "  (" probe-full "))\n" "(define (" prefix))
      (set!
        buf
        (gen-tb2
          buf
          "-hash-normalize [value : i64]) : i64\n  (let\n    [m : i64 2147483647]\n    [raw : i64 (% value 2147483647)]\n    (if (< raw 0)\n      (+ raw m)\n      raw)))\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-hash-key [key : (& key str)]) : i64\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  (let\n    [n : i64 (string-length key)]\n    [i : i64 0]\n    [hash : i64 0]\n    (begin\n      (while (< i n)\n        (begin\n          (set!\n            hash\n            (%\n              (+ (+ (* hash 131) (cast (string-ref key i) : i64)) 1)\n              2147483647))\n          (set! i (+ i 1))))\n      hash)))\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-power-two-capacity? [capacity : i64]) : bool\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  (if (> capacity 0)\n    (= (bit-and capacity (- capacity 1)) 0)\n    false))\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-round-capacity [capacity : i64]) : i64\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  (let\n    [rounded : i64 1]\n    (begin\n      (while (< rounded capacity)\n        (set! rounded (* rounded 2)))\n      rounded)))\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-normalized-bucket-index\n  [hash : i64]\n  [capacity : i64]) : i64\n"))
      (set! buf (gen-tb2 buf "  (bit-and hash (- capacity 1)))\n" ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-bucket-index [hash : i64] [capacity : i64]) : i64\n"))
      (set! buf (gen-tb3 buf "  (" prefix "-normalized-bucket-index\n"))
      (set! buf (gen-tb3 buf "    (" prefix "-hash-normalize hash)\n"))
      (set! buf (gen-tb2 buf "    capacity))\n" ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-next-index [index : i64] [capacity : i64]) : i64\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  (let\n    [next : i64 (+ index 1)]\n    (if (>= next capacity)\n      0\n      next)))\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-insert-slot [first-tombstone : i64] [empty-index : i64]) : i64\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  (if (>= first-tombstone 0)\n    first-tombstone\n    empty-index))\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-key-eq? [left : (& left str)] [right : (& right str)]) : bool\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  (let\n    [left-len : i64 (string-length left)]\n    [right-len : i64 (string-length right)]\n    (if (not (= left-len right-len))\n      false\n      (let\n        [i : i64 0]\n        [same : bool true]\n        (begin\n          (while (if same (< i left-len) false)\n            (if (= (cast (string-ref left i) : i64) (cast (string-ref right i) : i64))\n              (set! i (+ i 1))\n              (set! same false)))\n          same)))))\n"
          ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-probe-borrowed-from\n"))
      (set!
        buf
        (gen-tb3 buf "  [slots : (Array " slot ")]\n  [capacity : i64]\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  [key : (& key str)]\n  [hash : i64]\n  [index : i64]\n  [steps : i64]\n  [first-tombstone : i64]) : "
          ""))
      (set!
        buf
        (gen-tb2
          buf
          probe
          "\n  (let\n    [cursor : i64 index]\n    [walked : i64 steps]\n    [first : i64 first-tombstone]\n    (begin\n      (while (< walked capacity)\n        (match (array-ref slots cursor)\n          [("))
      (set!
        buf
        (gen-tb3
          buf
          empty
          ")\n            (return\n              ("
          probe-absent))
      (set!
        buf
        (gen-tb3
          buf
          "\n                ("
          prefix
          "-insert-slot first cursor)))]\n          [("))
      (set!
        buf
        (gen-tb2
          buf
          tombstone
          ")\n            (let\n              [next : i64 (+ cursor 1)]\n              (begin\n                (if (< first 0)\n                  (set! first cursor)\n                  unit)\n                (set!\n                  cursor\n                  (if (>= next capacity)\n                    0\n                    next))\n                (set! walked (+ walked 1))))]\n          [("))
      (set!
        buf
        (gen-tb4
          buf
          occupied
          " slot-key _ slot-hash)\n            (if (if (= slot-hash hash)\n              ("
          prefix
          "-key-eq? (& slot-key) key)\n"))
      (set!
        buf
        (gen-tb5
          buf
          "              false)\n              (return ("
          probe-found
          " cursor))\n              (let\n                [next : i64 (+ cursor 1)]\n                (begin\n                  (set!\n                    cursor\n                    (if (>= next capacity)\n                      0\n                      next))\n                  (set! walked (+ walked 1)))))]))\n      (if (>= first 0)\n        ("
          probe-absent
          " first)\n        ("))
      (set! buf (gen-tb3 buf probe-full ")))))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-probe-borrowed\n"))
      (set!
        buf
        (gen-tb3 buf "  [slots : (Array " slot ")]\n  [capacity : i64]\n"))
      (set! buf (gen-tb2 buf "  [key : (& key str)]\n  [hash : i64]) : " ""))
      (set! buf (gen-tb2 buf probe "\n  (if (<= capacity 0)\n"))
      (set!
        buf
        (gen-tb5
          buf
          "    ("
          probe-full
          ")\n    ("
          prefix
          "-probe-borrowed-from\n"))
      (set!
        buf
        (gen-tb3
          buf
          "      slots\n      capacity\n      key\n      hash\n      ("
          prefix
          "-normalized-bucket-index hash capacity)\n"))
      (set! buf (gen-tb2 buf "      0\n      -1)))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-probe\n"))
      (set!
        buf
        (gen-tb3 buf "  [slots : (Array " slot ")]\n  [capacity : i64]\n"))
      (set! buf (gen-tb2 buf "  [key : String]\n  [hash : i64]) : " ""))
      (set!
        buf
        (gen-tb5
          buf
          probe
          "\n  ("
          prefix
          "-probe-borrowed slots capacity (& key) hash))\n(defstruct "
          map-name))
      (set!
        buf
        (gen-tb3
          buf
          "\n  (slots (Array "
          slot
          "))\n  (len i64)\n  (deleted i64))\n"))
      (set! buf (gen-tb6 buf "(defenum " lookup "\n  (" missing ")\n  (" found))
      (set!
        buf
        (gen-tb5
          buf
          " "
          value-type
          "))\n(defenum "
          borrowed-value-lookup
          "\n  (:lifetimes map)\n  ("))
      (set!
        buf
        (gen-tb5
          buf
          borrowed-value-missing
          ")\n  ("
          borrowed-value-found
          " (& map "
          borrowed-value-type))
      (set! buf (gen-tb4 buf ")))\n(defenum " insert-result "\n  (" insert-ok))
      (set! buf (gen-tb6 buf " " map-name ")\n  (" insert-full " " map-name))
      (set!
        buf
        (gen-tb6
          buf
          "))\n(defenum "
          remove-result
          "\n  ("
          remove-ok
          " "
          map-name))
      (set! buf (gen-tb4 buf ")\n  (" remove-missing " " map-name))
      (set!
        buf
        (gen-tb5 buf "))\n(defenum " update-result "\n  (" update-ok " "))
      (set! buf (gen-tb5 buf map-name ")\n  (" update-missing " " map-name))
      (set!
        buf
        (gen-tb5
          buf
          "))\n(defenum "
          entry-or-insert-result
          "\n  ("
          entry-or-insert-found
          " "))
      (set!
        buf
        (gen-tb5 buf map-name " " value-type ")\n  (" entry-or-insert-inserted))
      (set! buf (gen-tb6 buf " " map-name " " value-type "))\n" ""))
      (set! buf (gen-tb3 buf "(defstruct " mut-entry-info "\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  (index i64)\n  (present bool)\n  (key String)\n  (hash i64))\n"
          ""))
      (set! buf (gen-tb3 buf "(defstruct " mut-entry "\n"))
      (set!
        buf
        (gen-tb4
          buf
          "  (:lifetimes map)\n  (slots (Array "
          slot
          "))\n  (borrow (&mut map (Array "
          slot))
      (set!
        buf
        (gen-tb2
          buf
          ")))\n  (index i64)\n  (present bool)\n  (key String)\n  (hash i64))\n"
          ""))
      (set! buf (gen-tb4 buf "(define (" prefix "-slots [map : " map-name))
      (set!
        buf
        (gen-tb3 buf "]) : (Array " slot ")\n  (struct-get map slots))\n"))
      (set! buf (gen-tb4 buf "(define (" prefix "-len [map : " map-name))
      (set! buf (gen-tb2 buf "]) : i64\n  (struct-get map len))\n" ""))
      (set! buf (gen-tb4 buf "(define (" prefix "-capacity [map : " map-name))
      (set!
        buf
        (gen-tb2 buf "]) : i64\n  (array-length (struct-get map slots)))\n" ""))
      (set! buf (gen-tb4 buf "(define (" prefix "-deleted [map : " map-name))
      (set! buf (gen-tb2 buf "]) : i64\n  (struct-get map deleted))\n" ""))
      (set!
        buf
        (gen-tb3 buf "(define (" prefix "-fill-empty\n  [slots : (Array "))
      (set!
        buf
        (gen-tb2 buf slot ")]\n  [index : i64]\n  [count : i64]) : unit\n"))
      (set!
        buf
        (gen-tb3
          buf
          "  (if (>= index count)\n    unit\n    (begin\n      (array-set! slots index ("
          empty
          "))\n      ("))
      (set!
        buf
        (gen-tb3 buf prefix "-fill-empty slots (+ index 1) count))))\n" ""))
      (set!
        buf
        (gen-tb3 buf "(define (" prefix "-with-capacity [capacity : i64]) : "))
      (set!
        buf
        (gen-tb2 buf map-name "\n  (let\n    [rounded-capacity : i64 ("))
      (set!
        buf
        (gen-tb2 buf prefix "-round-capacity capacity)]\n    [slots : (Array "))
      (set!
        buf
        (gen-tb4 buf slot ") (make-array " slot " rounded-capacity)]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "    (begin\n      ("
          prefix
          "-fill-empty slots 0 rounded-capacity)\n      ("
          map-name))
      (set! buf (gen-tb2 buf " slots 0 0))))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-borrowed-value-missing\n"))
      (set!
        buf
        (gen-tb5
          buf
          "  [map : (& map "
          map-name
          ")]) : ("
          borrowed-value-lookup
          " map)\n"))
      (set! buf (gen-tb4 buf "  (" borrowed-value-missing "))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-borrowed-value-found\n"))
      (set!
        buf
        (gen-tb5
          buf
          "  [value : (& map "
          borrowed-value-type
          ")]) : ("
          borrowed-value-lookup
          " map)\n"))
      (set! buf (gen-tb4 buf "  (" borrowed-value-found " value))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-get-borrowed [map : "))
      (set! buf (gen-tb4 buf map-name "] [key : (& key str)]) : " lookup "\n"))
      (set! buf (gen-tb3 buf "  (let\n    [slots : (Array " slot ") ("))
      (set! buf (gen-tb3 buf prefix "-slots map)]\n    (match (" prefix))
      (set!
        buf
        (gen-tb3 buf "-probe-borrowed slots (" prefix "-capacity map) key ("))
      (set!
        buf
        (gen-tb4 buf prefix "-hash-key key))\n      [(" probe-found " index)\n"))
      (set!
        buf
        (gen-tb4
          buf
          "        (match (array-ref slots index)\n          [("
          occupied
          " _ value _) ("
          found))
      (set!
        buf
        (gen-tb5
          buf
          " value)]\n          [("
          empty
          ") ("
          missing
          ")]\n          [("))
      (set!
        buf
        (gen-tb7
          buf
          tombstone
          ") ("
          missing
          ")])]\n      [("
          probe-absent
          " _) ("
          missing))
      (set! buf (gen-tb5 buf ")]\n      [(" probe-full ") (" missing ")])))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-get [map : "))
      (set!
        buf
        (gen-tb5 buf map-name "] [key : String]) : " lookup "\n  (" prefix))
      (set! buf (gen-tb2 buf "-get-borrowed map (& key)))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-get-value-borrowed\n"))
      (set! buf (gen-tb4 buf "  [map : (& map " map-name ")]\n" ""))
      (set!
        buf
        (gen-tb4
          buf
          "  [key : (& key str)]) : ("
          borrowed-value-lookup
          " map)\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "  (let\n    [capacity : i64 (array-length (struct-get map slots))]\n    (if (<= capacity 0)\n      ("
          prefix
          "-borrowed-value-missing map)\n"))
      (set!
        buf
        (gen-tb3
          buf
          "      (let\n        [hash : i64 ("
          prefix
          "-hash-key key)]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "        [cursor : i64 ("
          prefix
          "-normalized-bucket-index hash capacity)]\n"))
      (set!
        buf
        (gen-tb2
          buf
          "        [walked : i64 0]\n        (begin\n          (while (< walked capacity)\n            (match (array-ref (struct-get map slots) cursor)\n              [("
          ""))
      (set! buf (gen-tb3 buf empty ")\n                (return (" prefix))
      (set!
        buf
        (gen-tb4
          buf
          "-borrowed-value-missing map))]\n              [("
          tombstone
          ")\n                (let\n                  [next : i64 (+ cursor 1)]\n                  (begin\n                    (set!\n                      cursor\n                      (if (>= next capacity)\n                        0\n                        next))\n                    (set! walked (+ walked 1))))]\n              [("
          occupied))
      (set!
        buf
        (gen-tb4
          buf
          " slot-key _ slot-hash)\n                (if (if (= slot-hash hash)\n                  ("
          prefix
          "-key-eq? (& slot-key) key)\n                  false)\n                  (match (& (array-ref (struct-get map slots) cursor))\n                    [("
          occupied))
      (set!
        buf
        (gen-tb3
          buf
          " _ value _)\n                      (return ("
          prefix
          "-borrowed-value-found value))]\n                    [("))
      (set!
        buf
        (gen-tb5
          buf
          empty
          ")\n                      (return ("
          prefix
          "-borrowed-value-missing map))]\n                    [("
          tombstone))
      (set!
        buf
        (gen-tb4
          buf
          ")\n                      (return ("
          prefix
          "-borrowed-value-missing map))])\n                  (let\n                    [next : i64 (+ cursor 1)]\n                    (begin\n                      (set!\n                        cursor\n                        (if (>= next capacity)\n                          0\n                          next))\n                      (set! walked (+ walked 1)))))]))\n          ("
          prefix))
      (set! buf (gen-tb2 buf "-borrowed-value-missing map))))))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-contains-borrowed? [map : "))
      (set!
        buf
        (gen-tb3
          buf
          map-name
          "] [key : (& key str)]) : bool\n  (match ("
          prefix))
      (set!
        buf
        (gen-tb4
          buf
          "-get-borrowed map key)\n    [("
          found
          " _) true]\n    [("
          missing))
      (set! buf (gen-tb2 buf ") false]))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-contains? [map : "))
      (set!
        buf
        (gen-tb4
          buf
          map-name
          "] [key : String]) : bool\n  ("
          prefix
          "-contains-borrowed? map (& key)))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-slot-tombstone? [slot : "))
      (set! buf (gen-tb3 buf slot "]) : bool\n  (match slot\n    [(" tombstone))
      (set!
        buf
        (gen-tb5
          buf
          ") true]\n    [("
          empty
          ") false]\n    [("
          occupied
          " _ _ _) false]))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-insert [map : "))
      (set!
        buf
        (gen-tb5
          buf
          map-name
          "] [key : String] [value : "
          value-type
          "]) : "
          insert-result))
      (set! buf (gen-tb3 buf "\n  (let\n    [slots : (Array " slot ") ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-slots map)]\n    [hash : i64 ("
          prefix
          "-hash-key (& key))]\n"))
      (set!
        buf
        (gen-tb4 buf "    (match (" prefix "-probe-borrowed slots (" prefix))
      (set!
        buf
        (gen-tb4
          buf
          "-capacity map) (& key) hash)\n      [("
          probe-found
          " index)\n        (begin\n          (array-set! slots index ("
          occupied))
      (set!
        buf
        (gen-tb5
          buf
          " key value hash))\n          ("
          insert-ok
          " map))]\n      [("
          probe-absent
          " index)\n"))
      (set!
        buf
        (gen-tb3
          buf
          "        (let\n          [reused-tombstone : bool ("
          prefix
          "-slot-tombstone? (array-ref slots index))]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "          (begin\n            (array-set! slots index ("
          occupied
          " key value hash))\n            (set!\n              (struct-get map len)\n              (+ ("
          prefix))
      (set!
        buf
        (gen-tb3
          buf
          "-len map) 1))\n            (if reused-tombstone\n              (set! (struct-get map deleted) (- ("
          prefix
          "-deleted map) 1))\n"))
      (set!
        buf
        (gen-tb7
          buf
          "              unit)\n            ("
          insert-ok
          " map)))]\n      [("
          probe-full
          ") ("
          insert-full
          " map)])))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-remove-borrowed [map : "))
      (set!
        buf
        (gen-tb5
          buf
          map-name
          "] [key : (& key str)]) : "
          remove-result
          "\n  (let\n    [slots : (Array "
          slot))
      (set!
        buf
        (gen-tb5
          buf
          ") ("
          prefix
          "-slots map)]\n    (match ("
          prefix
          "-probe-borrowed slots ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-capacity map) key ("
          prefix
          "-hash-key key))\n      [("))
      (set!
        buf
        (gen-tb3
          buf
          probe-found
          " index)\n        (begin\n          (array-set! slots index ("
          tombstone))
      (set!
        buf
        (gen-tb3
          buf
          "))\n          (set!\n            (struct-get map len)\n            (- ("
          prefix
          "-len map) 1))\n"))
      (set!
        buf
        (gen-tb3
          buf
          "          (set!\n            (struct-get map deleted)\n            (+ ("
          prefix
          "-deleted map) 1))\n"))
      (set!
        buf
        (gen-tb7
          buf
          "          ("
          remove-ok
          " map))]\n      [("
          probe-absent
          " _) ("
          remove-missing
          " map)]\n"))
      (set!
        buf
        (gen-tb5 buf "      [(" probe-full ") (" remove-missing " map)])))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-remove [map : "))
      (set!
        buf
        (gen-tb5
          buf
          map-name
          "] [key : String]) : "
          remove-result
          "\n  ("
          prefix))
      (set! buf (gen-tb2 buf "-remove-borrowed map (& key)))\n" ""))
      (set!
        buf
        (gen-tb3 buf "(define (" prefix "-update-borrowed-if-present\n"))
      (set! buf (gen-tb3 buf "  [map : " map-name "]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "  [key : (& key str)]\n  [value : "
          value-type
          "]) : "
          update-result))
      (set! buf (gen-tb3 buf "\n  (let\n    [slots : (Array " slot ") ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-slots map)]\n    [hash : i64 ("
          prefix
          "-hash-key key)]\n"))
      (set!
        buf
        (gen-tb5
          buf
          "    (match ("
          prefix
          "-probe-borrowed slots ("
          prefix
          "-capacity map) key hash)\n      [("))
      (set!
        buf
        (gen-tb4
          buf
          probe-found
          " index)\n        (match (array-ref slots index)\n          [("
          occupied
          " slot-key _ slot-hash)\n"))
      (set!
        buf
        (gen-tb3
          buf
          "            (begin\n              (array-set! slots index ("
          occupied
          " slot-key value slot-hash))\n              ("))
      (set! buf (gen-tb4 buf update-ok " map))]\n          [(" empty ") ("))
      (set!
        buf
        (gen-tb4 buf update-missing " map)]\n          [(" tombstone ") ("))
      (set!
        buf
        (gen-tb4 buf update-missing " map)])]\n      [(" probe-absent " _) ("))
      (set!
        buf
        (gen-tb4 buf update-missing " map)]\n      [(" probe-full ") ("))
      (set!
        buf
        (gen-tb4
          buf
          update-missing
          " map)])))\n(define ("
          prefix
          "-update-if-present\n"))
      (set! buf (gen-tb3 buf "  [map : " map-name "]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "  [key : String]\n  [value : "
          value-type
          "]) : "
          update-result))
      (set!
        buf
        (gen-tb4
          buf
          "\n  ("
          prefix
          "-update-borrowed-if-present map (& key) value))\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-insert-into-empty\n  [slots : (Array "))
      (set!
        buf
        (gen-tb4
          buf
          slot
          ")]\n  [capacity : i64]\n  [key : String]\n  [value : "
          value-type
          "]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "  [hash : i64]) : unit\n  (if (<= capacity 0)\n    unit\n    (let\n      [cursor : i64 ("
          prefix
          "-normalized-bucket-index hash capacity)]\n"))
      (set!
        buf
        (gen-tb5
          buf
          "      [walked : i64 0]\n      [done : bool false]\n      (begin\n        (while (if done false (< walked capacity))\n          (match (array-ref slots cursor)\n            [("
          empty
          ")\n              (begin\n                (array-set! slots cursor ("
          occupied
          " key value hash))\n                (set! done true))]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "            [_\n              (begin\n                (set! cursor ("
          prefix
          "-next-index cursor capacity))\n"))
      (set!
        buf
        (gen-tb2
          buf
          "                (set! walked (+ walked 1)))]))\n        unit))))\n"
          ""))
      (set!
        buf
        (gen-tb3 buf "(define (" prefix "-rehash-from\n  [src : (Array "))
      (set!
        buf
        (gen-tb4
          buf
          slot
          ")]\n  [dst : (Array "
          slot
          ")]\n  [dst-capacity : i64]\n  [index : i64]\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  [count : i64]) : unit\n  (if (>= index count)\n    unit\n    (begin\n      (match (array-ref src index)\n        [("
          ""))
      (set!
        buf
        (gen-tb4
          buf
          occupied
          " key value hash)\n          ("
          prefix
          "-insert-into-empty dst dst-capacity key value hash)]\n        [("))
      (set! buf (gen-tb3 buf empty ") unit]\n        [(" tombstone))
      (set! buf (gen-tb2 buf ") unit])\n      (" prefix))
      (set!
        buf
        (gen-tb2
          buf
          "-rehash-from src dst dst-capacity (+ index 1) count))))\n"
          ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-resized [map : "))
      (set!
        buf
        (gen-tb5
          buf
          map-name
          "] [new-capacity : i64]) : "
          map-name
          "\n  (let\n    [src : (Array "
          slot))
      (set!
        buf
        (gen-tb5
          buf
          ") ("
          prefix
          "-slots map)]\n    [old-capacity : i64 ("
          prefix
          "-capacity map)]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "    [requested-capacity : i64\n      (if (> ("
          prefix
          "-len map) new-capacity)\n"))
      (set!
        buf
        (gen-tb5
          buf
          "        ("
          prefix
          "-len map)\n        new-capacity)]\n    [rounded-capacity : i64 ("
          prefix
          "-round-capacity requested-capacity)]\n"))
      (set!
        buf
        (gen-tb5
          buf
          "    [dst : (Array "
          slot
          ") (make-array "
          slot
          " rounded-capacity)]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "    (begin\n      ("
          prefix
          "-fill-empty dst 0 rounded-capacity)\n      ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-rehash-from src dst rounded-capacity 0 old-capacity)\n      (set! (struct-get map slots) dst)\n      (set! (struct-get map deleted) 0)\n      map)))\n(define ("
          prefix
          "-grow-capacity [capacity : i64]) : i64\n"))
      (set!
        buf
        (gen-tb3
          buf
          "  (if (< capacity 4)\n    8\n    (* ("
          prefix
          "-round-capacity capacity) 2)))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-grow [map : "))
      (set!
        buf
        (gen-tb6 buf map-name "]) : " map-name "\n  (" prefix "-resized map ("))
      (set!
        buf
        (gen-tb4 buf prefix "-grow-capacity (" prefix "-capacity map))))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-needs-grow? [map : "))
      (set!
        buf
        (gen-tb4
          buf
          map-name
          "]) : bool\n  (let\n    [capacity : i64 ("
          prefix
          "-capacity map)]\n"))
      (set!
        buf
        (gen-tb4 buf "    [used : i64 (+ (" prefix "-len map) (" prefix))
      (set!
        buf
        (gen-tb2
          buf
          "-deleted map))]\n    (if (<= capacity 0)\n      true\n      (>= (* used 4) (* capacity 3)))))\n"
          ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-put [map : "))
      (set!
        buf
        (gen-tb5
          buf
          map-name
          "] [key : String] [value : "
          value-type
          "]) : "
          map-name))
      (set!
        buf
        (gen-tb3 buf "\n  (let\n    [grown : " map-name "\n      (if ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-needs-grow? map)\n        ("
          prefix
          "-grow map)\n"))
      (set!
        buf
        (gen-tb4
          buf
          "        map)]\n    (match ("
          prefix
          "-insert grown key value)\n      [("
          insert-ok))
      (set!
        buf
        (gen-tb4
          buf
          " updated) updated]\n      [("
          insert-full
          " full)\n        (match ("
          prefix))
      (set!
        buf
        (gen-tb5
          buf
          "-insert ("
          prefix
          "-grow full) key value)\n          [("
          insert-ok
          " u) u]\n"))
      (set! buf (gen-tb4 buf "          [(" insert-full " u) u])])))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-insert-or-update\n"))
      (set! buf (gen-tb3 buf "  [map : " map-name "]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "  [key : String]\n  [value : "
          value-type
          "]) : "
          map-name))
      (set! buf (gen-tb3 buf "\n  (" prefix "-put map key value))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-entry-or-insert\n"))
      (set! buf (gen-tb3 buf "  [map : " map-name "]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "  [key : String]\n  [default-value : "
          value-type
          "]) : "
          entry-or-insert-result))
      (set! buf (gen-tb3 buf "\n  (let\n    [slots : (Array " slot ") ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-slots map)]\n    [hash : i64 ("
          prefix
          "-hash-key (& key))]\n"))
      (set!
        buf
        (gen-tb5
          buf
          "    (match ("
          prefix
          "-probe-borrowed slots ("
          prefix
          "-capacity map) (& key) hash)\n      [("))
      (set!
        buf
        (gen-tb4
          buf
          probe-found
          " index)\n        (match (array-ref slots index)\n          [("
          occupied
          " _ value _) ("))
      (set!
        buf
        (gen-tb4
          buf
          entry-or-insert-found
          " map value)]\n          [("
          empty
          ")\n"))
      (set!
        buf
        (gen-tb5
          buf
          "            (let\n              [updated : "
          map-name
          " ("
          prefix
          "-put map key default-value)]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "              ("
          entry-or-insert-inserted
          " updated default-value))]\n          [("
          tombstone))
      (set!
        buf
        (gen-tb5
          buf
          ")\n            (let\n              [updated : "
          map-name
          " ("
          prefix
          "-put map key default-value)]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "              ("
          entry-or-insert-inserted
          " updated default-value))])]\n      [("
          probe-absent))
      (set!
        buf
        (gen-tb5
          buf
          " _)\n        (let\n          [updated : "
          map-name
          " ("
          prefix
          "-put map key default-value)]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "          ("
          entry-or-insert-inserted
          " updated default-value))]\n      [("
          probe-full))
      (set!
        buf
        (gen-tb5
          buf
          ")\n        (let\n          [updated : "
          map-name
          " ("
          prefix
          "-put map key default-value)]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "          ("
          entry-or-insert-inserted
          " updated default-value))])))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-mut-entry-info\n"))
      (set! buf (gen-tb3 buf "  [slots : (Array " slot ")]\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  [capacity : i64]\n  [key : (& key str)]) : "
          mut-entry-info))
      (set!
        buf
        (gen-tb3
          buf
          "\n  (if (<= capacity 0)\n    ("
          mut-entry-info
          " -1 false \"\" 0)\n"))
      (set!
        buf
        (gen-tb3 buf "    (let\n      [hash : i64 (" prefix "-hash-key key)]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "      [cursor : i64 ("
          prefix
          "-bucket-index hash capacity)]\n"))
      (set!
        buf
        (gen-tb2
          buf
          "      [walked : i64 0]\n      [found : i64 -1]\n      [present : bool false]\n      [entry-key : String \"\"]\n      [entry-hash : i64 0]\n      [done : bool false]\n      (begin\n        (while (if (< walked capacity) (not done) false)\n          (match (array-ref slots cursor)\n            [("
          ""))
      (set!
        buf
        (gen-tb3
          buf
          occupied
          " slot-key _ slot-hash)\n              (if (if (= slot-hash hash)\n                ("
          prefix))
      (set!
        buf
        (gen-tb3
          buf
          "-key-eq? (& slot-key) key)\n                false)\n                (begin\n                  (set! found cursor)\n                  (set! present true)\n                  (set! entry-key slot-key)\n                  (set! entry-hash slot-hash)\n                  (set! done true))\n                (begin\n                  (set! cursor ("
          prefix
          ""))
      (set!
        buf
        (gen-tb4
          buf
          "-next-index cursor capacity))\n                  (set! walked (+ walked 1))))]\n            [("
          empty
          ") (set! done true)]\n            [("
          tombstone))
      (set!
        buf
        (gen-tb3
          buf
          ")\n              (begin\n                (set! cursor ("
          prefix
          "-next-index cursor capacity))\n"))
      (set!
        buf
        (gen-tb3
          buf
          "                (set! walked (+ walked 1)))]))\n        ("
          mut-entry-info
          " found present entry-key entry-hash)))))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-mut-entry-from-info\n"))
      (set! buf (gen-tb3 buf "  [info : " mut-entry-info "]\n"))
      (set! buf (gen-tb3 buf "  [slots : (Array " slot ")]\n"))
      (set! buf (gen-tb3 buf "  [borrow : (&mut map (Array " slot "))]) : ("))
      (set! buf (gen-tb3 buf mut-entry " map)\n  (" mut-entry))
      (set!
        buf
        (gen-tb2
          buf
          "\n    slots\n    borrow\n    (struct-get info index)\n    (struct-get info present)\n    (struct-get info key)\n    (struct-get info hash)))\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "(defmacro\n  ("
          prefix
          "-get-mut-entry-borrowed [map : Expr] [key : Expr])\n"))
      (set!
        buf
        (gen-tb3 buf "  :\n  Expr\n  `(" prefix "-mut-entry-from-info\n"))
      (set! buf (gen-tb2 buf "    (" ""))
      (set! buf (gen-tb2 buf prefix "-mut-entry-info\n"))
      (set!
        buf
        (gen-tb2
          buf
          "      (struct-get ,map slots)\n      (array-length (struct-get ,map slots))\n      ,key)\n    (struct-get ,map slots)\n    (&mut (struct-get ,map slots))))\n"
          ""))
      (set!
        buf
        (gen-tb3 buf "(define (" prefix "-mut-entry-present? [entry : ("))
      (set!
        buf
        (gen-tb3
          buf
          mut-entry
          " map)]) : bool\n  (struct-get entry present))\n"
          ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-mut-entry-value-or\n"))
      (set! buf (gen-tb3 buf "  [entry : (" mut-entry " map)]\n"))
      (set! buf (gen-tb4 buf "  [fallback : " value-type "]) : " value-type))
      (set! buf (gen-tb3 buf "\n  (if (" prefix "-mut-entry-present? entry)\n"))
      (set!
        buf
        (gen-tb4
          buf
          "    (match (array-ref (struct-get entry slots) (struct-get entry index))\n      [("
          occupied
          " _ value _) value]\n      [("
          empty))
      (set!
        buf
        (gen-tb4
          buf
          ") fallback]\n      [("
          tombstone
          ") fallback])\n    fallback))\n"
          ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-mut-entry-set!\n"))
      (set! buf (gen-tb3 buf "  [entry : (" mut-entry " map)]\n"))
      (set! buf (gen-tb3 buf "  [value : " value-type "]) : unit\n"))
      (set! buf (gen-tb3 buf "  (if (" prefix "-mut-entry-present? entry)\n"))
      (set!
        buf
        (gen-tb3
          buf
          "    (array-set!\n      (struct-get entry slots)\n      (struct-get entry index)\n      ("
          occupied
          "\n        (struct-get entry key)\n        value\n        (struct-get entry hash)))\n    unit))\n(defenum "))
      (set! buf (gen-tb2 buf entry ""))
      (set!
        buf
        (gen-tb6
          buf
          "\n  ("
          entry-none
          ")\n  ("
          entry-some
          " String "
          value-type))
      (set! buf (gen-tb3 buf "))\n(define (" prefix "-next-occupied-from\n"))
      (set! buf (gen-tb3 buf "  [slots : (Array " slot ")]\n  [index : i64]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "  [capacity : i64]) : i64\n  (if (>= index capacity)\n    capacity\n    (match (array-ref slots index)\n      [("
          occupied
          " _ _ _) index]\n      [("
          empty))
      (set!
        buf
        (gen-tb4
          buf
          ")\n        ("
          prefix
          "-next-occupied-from slots (+ index 1) capacity)]\n      [("
          tombstone))
      (set!
        buf
        (gen-tb3
          buf
          ")\n        ("
          prefix
          "-next-occupied-from slots (+ index 1) capacity)])))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-next-occupied [map : "))
      (set!
        buf
        (gen-tb4
          buf
          map-name
          "] [from : i64]) : i64\n  ("
          prefix
          "-next-occupied-from\n"))
      (set!
        buf
        (gen-tb5
          buf
          "    ("
          prefix
          "-slots map)\n    (if (< from 0)\n      0\n      from)\n    ("
          prefix
          "-capacity map)))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-entry-at [map : "))
      (set!
        buf
        (gen-tb5
          buf
          map-name
          "] [index : i64]) : "
          entry
          "\n  (if (if (< index 0)\n    true\n    (>= index ("
          prefix))
      (set!
        buf
        (gen-tb5
          buf
          "-capacity map)))\n    ("
          entry-none
          ")\n    (match (array-ref ("
          prefix
          "-slots map) index)\n"))
      (set!
        buf
        (gen-tb6
          buf
          "      [("
          occupied
          " key value _) ("
          entry-some
          " key value)]\n      [("
          empty))
      (set!
        buf
        (gen-tb7
          buf
          ") ("
          entry-none
          ")]\n      [("
          tombstone
          ") ("
          entry-none
          ")])))\n"))
      (text-buf-render buf))))

(define (gen-hashmap-source-owned-key
  [map-name : String]
  [prefix : String]
  [key-type : String]
  [key-hash-source : String]
  [key-support-source : String]
  [key-eq-source : String]
  [key-eq-call-source : String]
  [key-init : String]
  [value-type : String]) : String
  (let
    [slot : String (string-append map-name "Slot")]
    [empty : String (string-append map-name "Empty")]
    [tombstone : String (string-append map-name "Tombstone")]
    [occupied : String (string-append map-name "Occupied")]
    [probe : String (string-append map-name "Probe")]
    [probe-found : String (string-append map-name "ProbeFound")]
    [probe-absent : String (string-append map-name "ProbeAbsent")]
    [probe-full : String (string-append map-name "ProbeFull")]
    [lookup : String (string-append map-name "Lookup")]
    [missing : String (string-append map-name "Missing")]
    [found : String (string-append map-name "Found")]
    [borrowed-value-lookup : String
      (string-append map-name "BorrowedValueLookup")]
    [borrowed-value-missing : String
      (string-append map-name "BorrowedValueMissing")]
    [borrowed-value-found : String
      (string-append map-name "BorrowedValueFound")]
    [borrowed-value-type : String (gen-hashmap-borrowed-value-type value-type)]
    [insert-result : String (string-append map-name "InsertResult")]
    [insert-ok : String (string-append map-name "InsertOk")]
    [insert-full : String (string-append map-name "InsertFull")]
    [remove-result : String (string-append map-name "RemoveResult")]
    [remove-ok : String (string-append map-name "RemoveOk")]
    [remove-missing : String (string-append map-name "RemoveMissing")]
    [update-result : String (string-append map-name "UpdateResult")]
    [update-ok : String (string-append map-name "UpdateOk")]
    [update-missing : String (string-append map-name "UpdateMissing")]
    [entry-or-insert-result : String
      (string-append map-name "EntryOrInsertResult")]
    [entry-or-insert-found : String
      (string-append map-name "EntryOrInsertFound")]
    [entry-or-insert-inserted : String
      (string-append map-name "EntryOrInsertInserted")]
    [mut-entry-info : String (string-append map-name "MutEntryInfo")]
    [mut-entry : String (string-append map-name "MutEntry")]
    [entry : String (string-append map-name "Entry")]
    [entry-none : String (string-append map-name "EntryNone")]
    [entry-some : String (string-append map-name "EntrySome")]
    [buf : TextBuf (text-buf-empty)]
    (begin
      (set! buf (gen-tb5 buf "(defenum " slot "\n  (" empty ")\n  ("))
      (set!
        buf
        (gen-tb7 buf tombstone ")\n  (" occupied " " key-type " " value-type))
      (set! buf (gen-tb3 buf " i64))\n(defenum " probe "\n"))
      (set!
        buf
        (gen-tb5 buf "  (" probe-found " i64)\n  (" probe-absent " i64)\n"))
      (set! buf (gen-tb5 buf "  (" probe-full "))\n" "(define (" prefix))
      (set!
        buf
        (gen-tb2
          buf
          "-hash-normalize [value : i64]) : i64\n  (let\n    [m : i64 2147483647]\n    [raw : i64 (% value 2147483647)]\n    (if (< raw 0)\n      (+ raw m)\n      raw)))\n"
          ""))
      (set! buf (text-buf-append buf key-support-source))
      (set! buf (gen-tb3 buf "(define (" prefix "-hash-key [key : "))
      (set! buf (gen-tb3 buf key-type "]) : i64\n" key-hash-source))
      (if (string-eq key-eq-source "")
        unit
        (begin
          (set! buf (gen-tb3 buf "(define (" prefix "-key-eq? [left : "))
          (set!
            buf
            (gen-tb5
              buf
              key-type
              "] [right : "
              key-type
              "]) : bool\n"
              key-eq-source))))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-power-two-capacity? [capacity : i64]) : bool\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  (if (> capacity 0)\n    (= (bit-and capacity (- capacity 1)) 0)\n    false))\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-round-capacity [capacity : i64]) : i64\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  (let\n    [rounded : i64 1]\n    (begin\n      (while (< rounded capacity)\n        (set! rounded (* rounded 2)))\n      rounded)))\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-normalized-bucket-index [hash : i64] [capacity : i64]) : i64\n"))
      (set! buf (gen-tb2 buf "  (bit-and hash (- capacity 1)))\n" ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-bucket-index [hash : i64] [capacity : i64]) : i64\n"))
      (set! buf (gen-tb3 buf "  (" prefix "-normalized-bucket-index\n"))
      (set! buf (gen-tb3 buf "    (" prefix "-hash-normalize hash)\n"))
      (set! buf (gen-tb2 buf "    capacity))\n" ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-next-index [index : i64] [capacity : i64]) : i64\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  (let\n    [next : i64 (+ index 1)]\n    (if (>= next capacity)\n      0\n      next)))\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-insert-slot [first-tombstone : i64] [empty-index : i64]) : i64\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  (if (>= first-tombstone 0)\n    first-tombstone\n    empty-index))\n"
          ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-probe-from\n"))
      (set!
        buf
        (gen-tb3 buf "  [slots : (Array " slot ")]\n  [capacity : i64]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "  [key : "
          key-type
          "]\n  [hash : i64]\n  [index : i64]\n  [steps : i64]\n  [first-tombstone : i64]) : "))
      (set!
        buf
        (gen-tb2
          buf
          probe
          "\n  (let\n    [cursor : i64 index]\n    [walked : i64 steps]\n    [first : i64 first-tombstone]\n    (begin\n      (while (< walked capacity)\n        (match (array-ref slots cursor)\n          [("))
      (set!
        buf
        (gen-tb3
          buf
          empty
          ")\n            (return\n              ("
          probe-absent))
      (set!
        buf
        (gen-tb3
          buf
          "\n                ("
          prefix
          "-insert-slot first cursor)))]\n          [("))
      (set!
        buf
        (gen-tb2
          buf
          tombstone
          ")\n            (let\n              [next : i64 (+ cursor 1)]\n              (begin\n                (if (< first 0)\n                  (set! first cursor)\n                  unit)\n                (set!\n                  cursor\n                  (if (>= next capacity)\n                    0\n                    next))\n                (set! walked (+ walked 1))))]\n          [("))
      (set!
        buf
        (gen-tb2
          buf
          occupied
          " slot-key _ slot-hash)\n            (if (if (= slot-hash hash)\n              ("))
      (set! buf (gen-tb3 buf key-eq-call-source "\n" ""))
      (set!
        buf
        (gen-tb5
          buf
          "              false)\n              (return ("
          probe-found
          " cursor))\n              (let\n                [next : i64 (+ cursor 1)]\n                (begin\n                  (set!\n                    cursor\n                    (if (>= next capacity)\n                      0\n                      next))\n                  (set! walked (+ walked 1)))))]))\n      (if (>= first 0)\n        ("
          probe-absent
          " first)\n        ("))
      (set! buf (gen-tb3 buf probe-full ")))))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-probe\n"))
      (set!
        buf
        (gen-tb3 buf "  [slots : (Array " slot ")]\n  [capacity : i64]\n"))
      (set! buf (gen-tb3 buf "  [key : " key-type "]\n  [hash : i64]) : "))
      (set! buf (gen-tb2 buf probe "\n  (if (<= capacity 0)\n"))
      (set!
        buf
        (gen-tb5 buf "    (" probe-full ")\n    (" prefix "-probe-from\n"))
      (set!
        buf
        (gen-tb3
          buf
          "      slots\n      capacity\n      key\n      hash\n      ("
          prefix
          "-normalized-bucket-index hash capacity)\n"))
      (set!
        buf
        (gen-tb4
          buf
          "      0\n      -1)))\n(defstruct "
          map-name
          "\n  (slots (Array "
          slot))
      (set! buf (gen-tb2 buf "))\n  (len i64)\n  (deleted i64))\n" ""))
      (set! buf (gen-tb6 buf "(defenum " lookup "\n  (" missing ")\n  (" found))
      (set!
        buf
        (gen-tb5
          buf
          " "
          value-type
          "))\n(defenum "
          borrowed-value-lookup
          "\n  (:lifetimes map)\n  ("))
      (set!
        buf
        (gen-tb5
          buf
          borrowed-value-missing
          ")\n  ("
          borrowed-value-found
          " (& map "
          borrowed-value-type))
      (set! buf (gen-tb4 buf ")))\n(defenum " insert-result "\n  (" insert-ok))
      (set! buf (gen-tb6 buf " " map-name ")\n  (" insert-full " " map-name))
      (set!
        buf
        (gen-tb6
          buf
          "))\n(defenum "
          remove-result
          "\n  ("
          remove-ok
          " "
          map-name))
      (set! buf (gen-tb4 buf ")\n  (" remove-missing " " map-name))
      (set!
        buf
        (gen-tb5 buf "))\n(defenum " update-result "\n  (" update-ok " "))
      (set! buf (gen-tb5 buf map-name ")\n  (" update-missing " " map-name))
      (set!
        buf
        (gen-tb5
          buf
          "))\n(defenum "
          entry-or-insert-result
          "\n  ("
          entry-or-insert-found
          " "))
      (set!
        buf
        (gen-tb5 buf map-name " " value-type ")\n  (" entry-or-insert-inserted))
      (set! buf (gen-tb6 buf " " map-name " " value-type "))\n" ""))
      (set! buf (gen-tb3 buf "(defstruct " mut-entry-info "\n"))
      (set!
        buf
        (gen-tb3
          buf
          "  (index i64)\n  (present bool)\n  (key "
          key-type
          ")\n  (hash i64))\n"))
      (set! buf (gen-tb3 buf "(defstruct " mut-entry "\n"))
      (set!
        buf
        (gen-tb4
          buf
          "  (:lifetimes map)\n  (slots (Array "
          slot
          "))\n  (borrow (&mut map (Array "
          slot))
      (set!
        buf
        (gen-tb3
          buf
          ")))\n  (index i64)\n  (present bool)\n  (key "
          key-type
          ")\n  (hash i64))\n"))
      (set! buf (gen-tb4 buf "(define (" prefix "-slots [map : " map-name))
      (set!
        buf
        (gen-tb3 buf "]) : (Array " slot ")\n  (struct-get map slots))\n"))
      (set! buf (gen-tb4 buf "(define (" prefix "-len [map : " map-name))
      (set! buf (gen-tb2 buf "]) : i64\n  (struct-get map len))\n" ""))
      (set! buf (gen-tb4 buf "(define (" prefix "-capacity [map : " map-name))
      (set!
        buf
        (gen-tb2 buf "]) : i64\n  (array-length (struct-get map slots)))\n" ""))
      (set! buf (gen-tb4 buf "(define (" prefix "-deleted [map : " map-name))
      (set! buf (gen-tb2 buf "]) : i64\n  (struct-get map deleted))\n" ""))
      (set!
        buf
        (gen-tb3 buf "(define (" prefix "-fill-empty\n  [slots : (Array "))
      (set!
        buf
        (gen-tb2 buf slot ")]\n  [index : i64]\n  [count : i64]) : unit\n"))
      (set!
        buf
        (gen-tb3
          buf
          "  (if (>= index count)\n    unit\n    (begin\n      (array-set! slots index ("
          empty
          "))\n      ("))
      (set!
        buf
        (gen-tb3 buf prefix "-fill-empty slots (+ index 1) count))))\n" ""))
      (set!
        buf
        (gen-tb3 buf "(define (" prefix "-with-capacity [capacity : i64]) : "))
      (set!
        buf
        (gen-tb2 buf map-name "\n  (let\n    [rounded-capacity : i64 ("))
      (set!
        buf
        (gen-tb2 buf prefix "-round-capacity capacity)]\n    [slots : (Array "))
      (set!
        buf
        (gen-tb4 buf slot ") (make-array " slot " rounded-capacity)]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "    (begin\n      ("
          prefix
          "-fill-empty slots 0 rounded-capacity)\n      ("
          map-name))
      (set! buf (gen-tb2 buf " slots 0 0))))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-borrowed-value-missing\n"))
      (set!
        buf
        (gen-tb5
          buf
          "  [map : (& map "
          map-name
          ")]) : ("
          borrowed-value-lookup
          " map)\n"))
      (set! buf (gen-tb4 buf "  (" borrowed-value-missing "))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-borrowed-value-found\n"))
      (set!
        buf
        (gen-tb5
          buf
          "  [value : (& map "
          borrowed-value-type
          ")]) : ("
          borrowed-value-lookup
          " map)\n"))
      (set! buf (gen-tb4 buf "  (" borrowed-value-found " value))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-get [map : "))
      (set! buf (gen-tb3 buf map-name "] [key : " key-type))
      (set! buf (gen-tb3 buf "]) : " lookup "\n  (let\n    [slots : (Array "))
      (set! buf (text-buf-append buf slot))
      (set!
        buf
        (gen-tb5
          buf
          ") ("
          prefix
          "-slots map)]\n    (match ("
          prefix
          "-probe slots ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-capacity map) key ("
          prefix
          "-hash-key key))\n      [("))
      (set!
        buf
        (gen-tb4
          buf
          probe-found
          " index)\n        (match (array-ref slots index)\n          [("
          occupied
          " _ value _) ("))
      (set!
        buf
        (gen-tb6
          buf
          found
          " value)]\n          [("
          empty
          ") ("
          missing
          ")]\n          [("))
      (set!
        buf
        (gen-tb7
          buf
          tombstone
          ") ("
          missing
          ")])]\n      [("
          probe-absent
          " _) ("
          missing))
      (set! buf (gen-tb5 buf ")]\n      [(" probe-full ") (" missing ")])))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-get-value-borrowed\n"))
      (set! buf (gen-tb4 buf "  [map : (& map " map-name ")]\n" ""))
      (set!
        buf
        (gen-tb5
          buf
          "  [key : "
          key-type
          "]) : ("
          borrowed-value-lookup
          " map)\n"))
      (set!
        buf
        (gen-tb3
          buf
          "  (let\n    [capacity : i64 (array-length (struct-get map slots))]\n    (if (<= capacity 0)\n      ("
          prefix
          "-borrowed-value-missing map)\n"))
      (set!
        buf
        (gen-tb3
          buf
          "      (let\n        [hash : i64 ("
          prefix
          "-hash-key key)]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "        [cursor : i64 ("
          prefix
          "-normalized-bucket-index hash capacity)]\n"))
      (set!
        buf
        (gen-tb2
          buf
          "        [walked : i64 0]\n        (begin\n          (while (< walked capacity)\n            (match (array-ref (struct-get map slots) cursor)\n              [("
          ""))
      (set! buf (gen-tb3 buf empty ")\n                (return (" prefix))
      (set!
        buf
        (gen-tb4
          buf
          "-borrowed-value-missing map))]\n              [("
          tombstone
          ")\n                (let\n                  [next : i64 (+ cursor 1)]\n                  (begin\n                    (set!\n                      cursor\n                      (if (>= next capacity)\n                        0\n                        next))\n                    (set! walked (+ walked 1))))]\n              [("
          occupied))
      (set!
        buf
        (text-buf-append
          buf
          " slot-key _ slot-hash)\n                (if (if (= slot-hash hash)\n                  ("))
      (set!
        buf
        (gen-tb5
          buf
          key-eq-call-source
          "\n                  false)\n                  (match (& (array-ref (struct-get map slots) cursor))\n                    [("
          occupied
          " _ value _)\n                      (return ("
          prefix))
      (set!
        buf
        (gen-tb3
          buf
          "-borrowed-value-found value))]\n                    [("
          empty
          ")\n                      (return ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-borrowed-value-missing map))]\n                    [("
          tombstone
          ")\n                      (return ("))
      (set!
        buf
        (gen-tb3
          buf
          prefix
          "-borrowed-value-missing map))])\n                  (let\n                    [next : i64 (+ cursor 1)]\n                    (begin\n                      (set!\n                        cursor\n                        (if (>= next capacity)\n                          0\n                          next))\n                      (set! walked (+ walked 1)))))]))\n          ("
          prefix))
      (set! buf (gen-tb2 buf "-borrowed-value-missing map))))))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-contains? [map : "))
      (set! buf (gen-tb3 buf map-name "] [key : " key-type))
      (set! buf (gen-tb3 buf "]) : bool\n  (match (" prefix "-get map key)\n"))
      (set!
        buf
        (gen-tb6
          buf
          "    [("
          found
          " _) true]\n    [("
          missing
          ") false]))\n(define ("
          prefix))
      (set! buf (gen-tb3 buf "-slot-tombstone? [slot : " slot "]) : bool\n"))
      (set!
        buf
        (gen-tb5
          buf
          "  (match slot\n    [("
          tombstone
          ") true]\n    [("
          empty
          ") false]\n    [("))
      (set! buf (gen-tb3 buf occupied " _ _ _) false]))\n(define (" prefix))
      (set! buf (gen-tb4 buf "-insert [map : " map-name "] [key : " key-type))
      (set! buf (gen-tb3 buf "] [value : " value-type ""))
      (set!
        buf
        (gen-tb4
          buf
          "]) : "
          insert-result
          "\n  (let\n    [slots : (Array "
          slot))
      (set!
        buf
        (gen-tb5
          buf
          ") ("
          prefix
          "-slots map)]\n    [hash : i64 ("
          prefix
          "-hash-key key)]\n"))
      (set!
        buf
        (gen-tb5
          buf
          "    (match ("
          prefix
          "-probe slots ("
          prefix
          "-capacity map) key hash)\n      [("))
      (set!
        buf
        (gen-tb3
          buf
          probe-found
          " index)\n        (begin\n          (array-set! slots index ("
          occupied))
      (set!
        buf
        (gen-tb5
          buf
          " key value hash))\n          ("
          insert-ok
          " map))]\n      [("
          probe-absent
          " index)\n"))
      (set!
        buf
        (gen-tb3
          buf
          "        (let\n          [reused-tombstone : bool ("
          prefix
          "-slot-tombstone? (array-ref slots index))]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "          (begin\n            (array-set! slots index ("
          occupied
          " key value hash))\n            (set!\n              (struct-get map len)\n              (+ ("
          prefix))
      (set!
        buf
        (gen-tb3
          buf
          "-len map) 1))\n            (if reused-tombstone\n              (set! (struct-get map deleted) (- ("
          prefix
          "-deleted map) 1))\n"))
      (set!
        buf
        (gen-tb7
          buf
          "              unit)\n            ("
          insert-ok
          " map)))]\n      [("
          probe-full
          ") ("
          insert-full
          " map)])))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-remove [map : "))
      (set! buf (gen-tb3 buf map-name "] [key : " key-type))
      (set!
        buf
        (gen-tb4
          buf
          "]) : "
          remove-result
          "\n  (let\n    [slots : (Array "
          slot))
      (set!
        buf
        (gen-tb5
          buf
          ") ("
          prefix
          "-slots map)]\n    (match ("
          prefix
          "-probe slots ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-capacity map) key ("
          prefix
          "-hash-key key))\n      [("))
      (set!
        buf
        (gen-tb3
          buf
          probe-found
          " index)\n        (begin\n          (array-set! slots index ("
          tombstone))
      (set!
        buf
        (gen-tb3
          buf
          "))\n          (set!\n            (struct-get map len)\n            (- ("
          prefix
          "-len map) 1))\n"))
      (set!
        buf
        (gen-tb3
          buf
          "          (set!\n            (struct-get map deleted)\n            (+ ("
          prefix
          "-deleted map) 1))\n"))
      (set!
        buf
        (gen-tb7
          buf
          "          ("
          remove-ok
          " map))]\n      [("
          probe-absent
          " _) ("
          remove-missing
          " map)]\n"))
      (set!
        buf
        (gen-tb5 buf "      [(" probe-full ") (" remove-missing " map)])))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-update-if-present\n"))
      (set! buf (gen-tb3 buf "  [map : " map-name "]\n"))
      (set! buf (text-buf-append buf "  [key : "))
      (set! buf (gen-tb4 buf key-type "]\n  [value : " value-type "]) : "))
      (set! buf (text-buf-append buf update-result))
      (set! buf (gen-tb3 buf "\n  (let\n    [slots : (Array " slot ") ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-slots map)]\n    [hash : i64 ("
          prefix
          "-hash-key key)]\n"))
      (set!
        buf
        (gen-tb5
          buf
          "    (match ("
          prefix
          "-probe slots ("
          prefix
          "-capacity map) key hash)\n      [("))
      (set!
        buf
        (gen-tb4
          buf
          probe-found
          " index)\n        (match (array-ref slots index)\n          [("
          occupied
          " slot-key _ slot-hash)\n"))
      (set!
        buf
        (gen-tb3
          buf
          "            (begin\n              (array-set! slots index ("
          occupied
          " slot-key value slot-hash))\n              ("))
      (set! buf (gen-tb4 buf update-ok " map))]\n          [(" empty ") ("))
      (set!
        buf
        (gen-tb4 buf update-missing " map)]\n          [(" tombstone ") ("))
      (set!
        buf
        (gen-tb4 buf update-missing " map)])]\n      [(" probe-absent " _) ("))
      (set!
        buf
        (gen-tb4 buf update-missing " map)]\n      [(" probe-full ") ("))
      (set! buf (gen-tb3 buf update-missing " map)])))\n" ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-insert-into-empty\n  [slots : (Array "))
      (set! buf (gen-tb3 buf slot ")]\n  [capacity : i64]\n  [key : " key-type))
      (set! buf (gen-tb3 buf "]\n  [value : " value-type "]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "  [hash : i64]) : unit\n  (if (<= capacity 0)\n    unit\n    (let\n      [cursor : i64 ("
          prefix
          "-normalized-bucket-index hash capacity)]\n"))
      (set!
        buf
        (gen-tb5
          buf
          "      [walked : i64 0]\n      [done : bool false]\n      (begin\n        (while (if done false (< walked capacity))\n          (match (array-ref slots cursor)\n            [("
          empty
          ")\n              (begin\n                (array-set! slots cursor ("
          occupied
          " key value hash))\n                (set! done true))]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "            [_\n              (begin\n                (set! cursor ("
          prefix
          "-next-index cursor capacity))\n"))
      (set!
        buf
        (gen-tb2
          buf
          "                (set! walked (+ walked 1)))]))\n        unit))))\n"
          ""))
      (set!
        buf
        (gen-tb3 buf "(define (" prefix "-rehash-from\n  [src : (Array "))
      (set!
        buf
        (gen-tb4
          buf
          slot
          ")]\n  [dst : (Array "
          slot
          ")]\n  [dst-capacity : i64]\n  [index : i64]\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  [count : i64]) : unit\n  (if (>= index count)\n    unit\n    (begin\n      (match (array-ref src index)\n        [("
          ""))
      (set!
        buf
        (gen-tb4
          buf
          occupied
          " key value hash)\n          ("
          prefix
          "-insert-into-empty dst dst-capacity key value hash)]\n        [("))
      (set! buf (gen-tb3 buf empty ") unit]\n        [(" tombstone))
      (set! buf (gen-tb2 buf ") unit])\n      (" prefix))
      (set!
        buf
        (gen-tb2
          buf
          "-rehash-from src dst dst-capacity (+ index 1) count))))\n"
          ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-resized [map : "))
      (set!
        buf
        (gen-tb5
          buf
          map-name
          "] [new-capacity : i64]) : "
          map-name
          "\n  (let\n    [src : (Array "
          slot))
      (set!
        buf
        (gen-tb5
          buf
          ") ("
          prefix
          "-slots map)]\n    [old-capacity : i64 ("
          prefix
          "-capacity map)]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "    [requested-capacity : i64\n      (if (> ("
          prefix
          "-len map) new-capacity)\n"))
      (set!
        buf
        (gen-tb5
          buf
          "        ("
          prefix
          "-len map)\n        new-capacity)]\n    [rounded-capacity : i64 ("
          prefix
          "-round-capacity requested-capacity)]\n"))
      (set!
        buf
        (gen-tb5
          buf
          "    [dst : (Array "
          slot
          ") (make-array "
          slot
          " rounded-capacity)]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "    (begin\n      ("
          prefix
          "-fill-empty dst 0 rounded-capacity)\n      ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-rehash-from src dst rounded-capacity 0 old-capacity)\n      (set! (struct-get map slots) dst)\n      (set! (struct-get map deleted) 0)\n      map)))\n(define ("
          prefix
          "-grow-capacity [capacity : i64]) : i64\n"))
      (set!
        buf
        (gen-tb3
          buf
          "  (if (< capacity 4)\n    8\n    (* ("
          prefix
          "-round-capacity capacity) 2)))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-grow [map : "))
      (set!
        buf
        (gen-tb6 buf map-name "]) : " map-name "\n  (" prefix "-resized map ("))
      (set!
        buf
        (gen-tb4 buf prefix "-grow-capacity (" prefix "-capacity map))))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-needs-grow? [map : "))
      (set!
        buf
        (gen-tb4
          buf
          map-name
          "]) : bool\n  (let\n    [capacity : i64 ("
          prefix
          "-capacity map)]\n"))
      (set!
        buf
        (gen-tb4 buf "    [used : i64 (+ (" prefix "-len map) (" prefix))
      (set!
        buf
        (gen-tb2
          buf
          "-deleted map))]\n    (if (<= capacity 0)\n      true\n      (>= (* used 4) (* capacity 3)))))\n"
          ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-put [map : "))
      (set! buf (gen-tb3 buf map-name "] [key : " key-type))
      (set! buf (gen-tb4 buf "] [value : " value-type "]) : " map-name))
      (set!
        buf
        (gen-tb3 buf "\n  (let\n    [grown : " map-name "\n      (if ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-needs-grow? map)\n        ("
          prefix
          "-grow map)\n"))
      (set!
        buf
        (gen-tb4
          buf
          "        map)]\n    (match ("
          prefix
          "-insert grown key value)\n      [("
          insert-ok))
      (set!
        buf
        (gen-tb4
          buf
          " updated) updated]\n      [("
          insert-full
          " full)\n        (match ("
          prefix))
      (set!
        buf
        (gen-tb5
          buf
          "-insert ("
          prefix
          "-grow full) key value)\n          [("
          insert-ok
          " u) u]\n"))
      (set! buf (gen-tb4 buf "          [(" insert-full " u) u])])))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-insert-or-update\n"))
      (set! buf (gen-tb3 buf "  [map : " map-name "]\n"))
      (set!
        buf
        (gen-tb5 buf "  [key : " key-type "]\n  [value : " value-type "]) : "))
      (set! buf (gen-tb2 buf map-name ""))
      (set! buf (gen-tb3 buf "\n  (" prefix "-put map key value))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-entry-or-insert\n"))
      (set! buf (gen-tb3 buf "  [map : " map-name "]\n"))
      (set! buf (text-buf-append buf "  [key : "))
      (set!
        buf
        (gen-tb4 buf key-type "]\n  [default-value : " value-type "]) : "))
      (set! buf (text-buf-append buf entry-or-insert-result))
      (set! buf (gen-tb3 buf "\n  (let\n    [slots : (Array " slot ") ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-slots map)]\n    [hash : i64 ("
          prefix
          "-hash-key key)]\n"))
      (set!
        buf
        (gen-tb5
          buf
          "    (match ("
          prefix
          "-probe slots ("
          prefix
          "-capacity map) key hash)\n      [("))
      (set!
        buf
        (gen-tb4
          buf
          probe-found
          " index)\n        (match (array-ref slots index)\n          [("
          occupied
          " _ value _) ("))
      (set!
        buf
        (gen-tb4
          buf
          entry-or-insert-found
          " map value)]\n          [("
          empty
          ")\n"))
      (set!
        buf
        (gen-tb5
          buf
          "            (let\n              [updated : "
          map-name
          " ("
          prefix
          "-put map key default-value)]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "              ("
          entry-or-insert-inserted
          " updated default-value))]\n          [("
          tombstone))
      (set!
        buf
        (gen-tb5
          buf
          ")\n            (let\n              [updated : "
          map-name
          " ("
          prefix
          "-put map key default-value)]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "              ("
          entry-or-insert-inserted
          " updated default-value))])]\n      [("
          probe-absent))
      (set!
        buf
        (gen-tb5
          buf
          " _)\n        (let\n          [updated : "
          map-name
          " ("
          prefix
          "-put map key default-value)]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "          ("
          entry-or-insert-inserted
          " updated default-value))]\n      [("
          probe-full))
      (set!
        buf
        (gen-tb5
          buf
          ")\n        (let\n          [updated : "
          map-name
          " ("
          prefix
          "-put map key default-value)]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "          ("
          entry-or-insert-inserted
          " updated default-value))])))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-mut-entry-info\n"))
      (set! buf (gen-tb3 buf "  [slots : (Array " slot ")]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "  [capacity : i64]\n  [key : "
          key-type
          "]) : "
          mut-entry-info))
      (set!
        buf
        (gen-tb4
          buf
          "\n  (if (<= capacity 0)\n    ("
          mut-entry-info
          " -1 false "
          key-init))
      (set! buf (gen-tb2 buf " 0)\n" ""))
      (set!
        buf
        (gen-tb3 buf "    (let\n      [hash : i64 (" prefix "-hash-key key)]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "      [cursor : i64 ("
          prefix
          "-bucket-index hash capacity)]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "      [walked : i64 0]\n      [found : i64 -1]\n      [present : bool false]\n      [entry-key : "
          key-type
          " "
          key-init))
      (set!
        buf
        (gen-tb2
          buf
          "]\n      [entry-hash : i64 0]\n      [done : bool false]\n      (begin\n        (while (if (< walked capacity) (not done) false)\n          (match (array-ref slots cursor)\n            [("
          ""))
      (set!
        buf
        (gen-tb2
          buf
          occupied
          " slot-key _ slot-hash)\n              (if (if (= slot-hash hash)\n                ("))
      (set!
        buf
        (gen-tb4
          buf
          key-eq-call-source
          "\n                false)\n                (begin\n                  (set! found cursor)\n                  (set! present true)\n                  (set! entry-key slot-key)\n                  (set! entry-hash slot-hash)\n                  (set! done true))\n                (begin\n                  (set! cursor ("
          prefix
          ""))
      (set!
        buf
        (gen-tb4
          buf
          "-next-index cursor capacity))\n                  (set! walked (+ walked 1))))]\n            [("
          empty
          ") (set! done true)]\n            [("
          tombstone))
      (set!
        buf
        (gen-tb3
          buf
          ")\n              (begin\n                (set! cursor ("
          prefix
          "-next-index cursor capacity))\n"))
      (set!
        buf
        (gen-tb3
          buf
          "                (set! walked (+ walked 1)))]))\n        ("
          mut-entry-info
          " found present entry-key entry-hash)))))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-mut-entry-from-info\n"))
      (set! buf (gen-tb3 buf "  [info : " mut-entry-info "]\n"))
      (set! buf (gen-tb3 buf "  [slots : (Array " slot ")]\n"))
      (set! buf (gen-tb3 buf "  [borrow : (&mut map (Array " slot "))]) : ("))
      (set! buf (gen-tb3 buf mut-entry " map)\n  (" mut-entry))
      (set!
        buf
        (gen-tb2
          buf
          "\n    slots\n    borrow\n    (struct-get info index)\n    (struct-get info present)\n    (struct-get info key)\n    (struct-get info hash)))\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "(defmacro\n  ("
          prefix
          "-get-mut-entry [map : Expr] [key : Expr])\n"))
      (set!
        buf
        (gen-tb3 buf "  :\n  Expr\n  `(" prefix "-mut-entry-from-info\n"))
      (set! buf (gen-tb2 buf "    (" ""))
      (set! buf (gen-tb2 buf prefix "-mut-entry-info\n"))
      (set!
        buf
        (gen-tb2
          buf
          "      (struct-get ,map slots)\n      (array-length (struct-get ,map slots))\n      ,key)\n    (struct-get ,map slots)\n    (&mut (struct-get ,map slots))))\n"
          ""))
      (set!
        buf
        (gen-tb3 buf "(define (" prefix "-mut-entry-present? [entry : ("))
      (set!
        buf
        (gen-tb3
          buf
          mut-entry
          " map)]) : bool\n  (struct-get entry present))\n"
          ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-mut-entry-value-or\n"))
      (set! buf (gen-tb3 buf "  [entry : (" mut-entry " map)]\n"))
      (set! buf (gen-tb4 buf "  [fallback : " value-type "]) : " value-type))
      (set! buf (gen-tb3 buf "\n  (if (" prefix "-mut-entry-present? entry)\n"))
      (set!
        buf
        (gen-tb4
          buf
          "    (match (array-ref (struct-get entry slots) (struct-get entry index))\n      [("
          occupied
          " _ value _) value]\n      [("
          empty))
      (set!
        buf
        (gen-tb4
          buf
          ") fallback]\n      [("
          tombstone
          ") fallback])\n    fallback))\n"
          ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-mut-entry-set!\n"))
      (set! buf (gen-tb3 buf "  [entry : (" mut-entry " map)]\n"))
      (set! buf (gen-tb3 buf "  [value : " value-type "]) : unit\n"))
      (set! buf (gen-tb3 buf "  (if (" prefix "-mut-entry-present? entry)\n"))
      (set!
        buf
        (gen-tb3
          buf
          "    (array-set!\n      (struct-get entry slots)\n      (struct-get entry index)\n      ("
          occupied
          "\n        (struct-get entry key)\n        value\n        (struct-get entry hash)))\n    unit))\n(defenum "))
      (set! buf (gen-tb2 buf entry ""))
      (set!
        buf
        (gen-tb7 buf "\n  (" entry-none ")\n  (" entry-some " " key-type ""))
      (set! buf (gen-tb3 buf " " value-type ""))
      (set! buf (gen-tb3 buf "))\n(define (" prefix "-next-occupied-from\n"))
      (set! buf (gen-tb3 buf "  [slots : (Array " slot ")]\n  [index : i64]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "  [capacity : i64]) : i64\n  (if (>= index capacity)\n    capacity\n    (match (array-ref slots index)\n      [("
          occupied
          " _ _ _) index]\n      [("
          empty))
      (set!
        buf
        (gen-tb4
          buf
          ")\n        ("
          prefix
          "-next-occupied-from slots (+ index 1) capacity)]\n      [("
          tombstone))
      (set!
        buf
        (gen-tb3
          buf
          ")\n        ("
          prefix
          "-next-occupied-from slots (+ index 1) capacity)])))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-next-occupied [map : "))
      (set!
        buf
        (gen-tb4
          buf
          map-name
          "] [from : i64]) : i64\n  ("
          prefix
          "-next-occupied-from\n"))
      (set!
        buf
        (gen-tb5
          buf
          "    ("
          prefix
          "-slots map)\n    (if (< from 0)\n      0\n      from)\n    ("
          prefix
          "-capacity map)))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-entry-at [map : "))
      (set!
        buf
        (gen-tb5
          buf
          map-name
          "] [index : i64]) : "
          entry
          "\n  (if (if (< index 0)\n    true\n    (>= index ("
          prefix))
      (set!
        buf
        (gen-tb5
          buf
          "-capacity map)))\n    ("
          entry-none
          ")\n    (match (array-ref ("
          prefix
          "-slots map) index)\n"))
      (set!
        buf
        (gen-tb6
          buf
          "      [("
          occupied
          " key value _) ("
          entry-some
          " key value)]\n      [("
          empty))
      (set!
        buf
        (gen-tb7
          buf
          ") ("
          entry-none
          ")]\n      [("
          tombstone
          ") ("
          entry-none
          ")])))\n"))
      (text-buf-render buf))))

(define (gen-hashmap-source-aggregate-key-support [prefix : String]) : String
  (let
    [buf : TextBuf (text-buf-empty)]
    (begin
      (set! buf (gen-tb3 buf "(define (" prefix "-hash-combine\n"))
      (set!
        buf
        (gen-tb3
          buf
          "  [seed : i64]\n  [component : i64]) : i64\n  ("
          prefix
          "-hash-normalize\n"))
      (set!
        buf
        (gen-tb3 buf "    (+ (+ (* (" prefix "-hash-normalize seed) 131)\n"))
      (set!
        buf
        (gen-tb3 buf "      (" prefix "-hash-normalize component)) 1)))\n"))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-string-hash [key : (& key str)]) : i64\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  (let\n    [n : i64 (string-length key)]\n    [i : i64 0]\n    [hash : i64 0]\n    (begin\n      (while (< i n)\n        (begin\n          (set!\n            hash\n            (%\n              (+ (+ (* hash 131) (cast (string-ref key i) : i64)) 1)\n              2147483647))\n          (set! i (+ i 1))))\n      hash)))\n"
          ""))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-string-key-eq? [left : (& left str)] [right : (& right str)]) : bool\n"))
      (set!
        buf
        (gen-tb2
          buf
          "  (let\n    [left-len : i64 (string-length left)]\n    [right-len : i64 (string-length right)]\n    (if (not (= left-len right-len))\n      false\n      (let\n        [i : i64 0]\n        [same : bool true]\n        (begin\n          (while (if same (< i left-len) false)\n            (if (= (cast (string-ref left i) : i64) (cast (string-ref right i) : i64))\n              (set! i (+ i 1))\n              (set! same false)))\n          same)))))\n"
          ""))
      (text-buf-render buf))))

(define (gen-hashmap-source-i64-key
  [map-name : String]
  [prefix : String]
  [value-type : String]) : String
  (gen-hashmap-source-owned-key
    map-name
    prefix
    "i64"
    (string-append "  (" (string-append prefix "-hash-normalize key))\n"))
    ""
    ""
    "= slot-key key)"
    "0"
    value-type))

(define (gen-hashmap-aggregate-type-from-key [type-key : String]) : ResultGenHashmapType
  (match (gen-hashmap-nominal-name type-key "struct_")
    [(SpecSomeString name) (OkGenHashmapType (AstTyStruct (intern name)))]
    [(SpecNoString)
      (match (gen-hashmap-nominal-name type-key "enum_")
        [(SpecSomeString name) (OkGenHashmapType (AstTyEnum (intern name)))]
        [(SpecNoString)
          (ErrGenHashmapType
            (gen-hashmap-diag
              (string-append
                "hashmap-family: aggregate key descriptor requires nominal aggregate key type, got "
                type-key)))])]))

(define (gen-hashmap-aggregate-unsupported
  [aggregate-name : String]
  [member-name : String]
  [type-key : String]) : ResultGenHashmapSource
  (ErrGenHashmapSource
    (gen-hashmap-diag
      (string-append
        "hashmap-family: unsupported aggregate key member "
        (string-append
          aggregate-name
          (string-append
            "."
            (string-append member-name (string-append " type " type-key))))))))

(define (gen-hashmap-aggregate-no-reflection [type-key : String]) : ResultGenHashmapSource
  (ErrGenHashmapSource
    (gen-hashmap-diag
      (string-append
        "hashmap-family: no reflection metadata for aggregate key "
        type-key))))

(define (gen-hashmap-aggregate-field-expr [base : String] [field-name : String]) : String
  (string-append
    "(struct-get "
    (string-append base (string-append " " (string-append field-name ")")))))

(define (gen-hashmap-aggregate-combine-expr
  [prefix : String]
  [seed : String]
  [component : String]) : String
  (string-append
    "("
    (string-append
      prefix
      (string-append
        "-hash-combine "
        (string-append seed (string-append " " (string-append component ")")))))))

(define (gen-hashmap-aggregate-payload-name
  [prefix : String]
  [variant-index : i64]
  [payload-index : i64]) : String
  (string-append
    prefix
    (string-append
      "-"
      (string-append
        (int->string variant-index)
        (string-append "-" (int->string payload-index))))))

(define (gen-hashmap-aggregate-payload-pattern-from
  [prefix : String]
  [variant-index : i64]
  [payload-index : i64]
  [payload-count : i64]) : String
  (if (>= payload-index payload-count)
    ""
    (string-append
      " "
      (string-append
        (gen-hashmap-aggregate-payload-name prefix variant-index payload-index)
        (gen-hashmap-aggregate-payload-pattern-from
          prefix
          variant-index
          (+ payload-index 1)
          payload-count)))))

(define (gen-hashmap-aggregate-payload-pattern
  [prefix : String]
  [variant-index : i64]
  [payload-count : i64]) : String
  (gen-hashmap-aggregate-payload-pattern-from
    prefix
    variant-index
    0
    payload-count))

(define (gen-hashmap-aggregate-hash-expr
  [prefix : String]
  [aggregate-name : String]
  [member-name : String]
  [infos : CtfeReflectInfoList]
  [ty : AstType]
  [expr : String]) : ResultGenHashmapSource
  (let
    [resolved : AstType (ctfe-reflect-resolve-type infos ty)]
    [type-key : String (ctfe-type-key-with-reflections infos resolved)]
    (match resolved
      [(AstTyI64)
        (OkGenHashmapSource
          (string-append
            "("
            (string-append
              prefix
              (string-append "-hash-normalize " (string-append expr ")")))))]
      [(AstTyBool)
        (OkGenHashmapSource (string-append "(if " (string-append expr " 1 0)")))]
      [(AstTyChar)
        (OkGenHashmapSource
          (string-append
            (string-append "(" prefix)
            (string-append
              "-hash-normalize (cast "
              (string-append expr " : i64))"))))]
      [(AstTyString)
        (OkGenHashmapSource
          (string-append
            "("
            (string-append
              prefix
              (string-append "-string-hash (& " (string-append expr "))")))))]
      [(AstTyStruct name)
        (match (ctfe-reflect-info-lookup infos (ctfe-type-nominal-key resolved))
          [(CtfeSomeReflectInfo info)
            (match info
              [(CtfeReflectStruct _ _ _ fields)
                (gen-hashmap-aggregate-struct-hash-from
                  fields
                  prefix
                  infos
                  (intern-str name)
                  expr
                  0
                  "0")]
              [_
                (gen-hashmap-aggregate-unsupported
                  aggregate-name
                  member-name
                  type-key)])]
          [(CtfeNoReflectInfo) (gen-hashmap-aggregate-no-reflection type-key)])]
      [(AstTyEnum name)
        (match (ctfe-reflect-info-lookup infos (ctfe-type-nominal-key resolved))
          [(CtfeSomeReflectInfo info)
            (match info
              [(CtfeReflectEnum _ _ _ variants)
                (gen-hashmap-aggregate-enum-hash-expr
                  variants
                  prefix
                  infos
                  (intern-str name)
                  expr)]
              [_
                (gen-hashmap-aggregate-unsupported
                  aggregate-name
                  member-name
                  type-key)])]
          [(CtfeNoReflectInfo) (gen-hashmap-aggregate-no-reflection type-key)])]
      [_
        (gen-hashmap-aggregate-unsupported aggregate-name member-name type-key)])))

(define (gen-hashmap-aggregate-struct-hash-from
  [fields : CtfeReflectFieldList]
  [prefix : String]
  [infos : CtfeReflectInfoList]
  [aggregate-name : String]
  [base-expr : String]
  [index : i64]
  [seed : String]) : ResultGenHashmapSource
  (if (>= index (ctfe-reflect-field-list-count fields))
    (OkGenHashmapSource seed)
    (match (ctfe-reflect-field-list-ref fields index)
      [(CtfeReflectField field-name ty)
        (let
          [field-expr : String
            (gen-hashmap-aggregate-field-expr base-expr field-name)]
          (match (gen-hashmap-aggregate-hash-expr
            prefix
            aggregate-name
            field-name
            infos
            ty
            field-expr)
            [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
            [(OkGenHashmapSource field-hash)
              (gen-hashmap-aggregate-struct-hash-from
                fields
                prefix
                infos
                aggregate-name
                base-expr
                (+ index 1)
                (gen-hashmap-aggregate-combine-expr prefix seed field-hash))]))])))

(define (gen-hashmap-aggregate-payload-hash-from
  [payloads : AstTypeList]
  [prefix : String]
  [infos : CtfeReflectInfoList]
  [aggregate-name : String]
  [variant-name : String]
  [variant-index : i64]
  [payload-index : i64]
  [seed : String]) : ResultGenHashmapSource
  (if (>= payload-index (ctfe-type-list-count payloads))
    (OkGenHashmapSource seed)
    (match (ctfe-type-list-ref payloads infos payload-index)
      [(OkCtfeTypeLookup ty)
        (let
          [payload-name : String
            (gen-hashmap-aggregate-payload-name
              "hashmap-payload"
              variant-index
              payload-index)]
          [member-name : String
            (string-append
              variant-name
              (string-append "#" (int->string payload-index)))]
          (match (gen-hashmap-aggregate-hash-expr
            prefix
            aggregate-name
            member-name
            infos
            ty
            payload-name)
            [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
            [(OkGenHashmapSource payload-hash)
              (gen-hashmap-aggregate-payload-hash-from
                payloads
                prefix
                infos
                aggregate-name
                variant-name
                variant-index
                (+ payload-index 1)
                (gen-hashmap-aggregate-combine-expr prefix seed payload-hash))]))]
      [(ErrCtfeTypeLookup message)
        (ErrGenHashmapSource (gen-hashmap-diag message))])))

(define (gen-hashmap-aggregate-enum-hash-arms
  [variants : CtfeReflectVariantList]
  [prefix : String]
  [infos : CtfeReflectInfoList]
  [aggregate-name : String]
  [index : i64]) : ResultGenHashmapSource
  (if (>= index (ctfe-reflect-variant-list-count variants))
    (OkGenHashmapSource "")
    (match (ctfe-reflect-variant-list-ref variants index)
      [(CtfeReflectVariant variant-name payloads)
        (let
          [payload-count : i64 (ctfe-type-list-count payloads)]
          [pattern : String
            (gen-hashmap-aggregate-payload-pattern
              "hashmap-payload"
              index
              payload-count)]
          [variant-seed : String
            (gen-hashmap-aggregate-combine-expr
              prefix
              "0"
              (string-append
                "("
                (string-append
                  prefix
                  (string-append
                    "-hash-normalize "
                    (string-append (int->string index) ")")))))]
          (match (gen-hashmap-aggregate-payload-hash-from
            payloads
            prefix
            infos
            aggregate-name
            variant-name
            index
            0
            variant-seed)
            [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
            [(OkGenHashmapSource body-source)
              (match (gen-hashmap-aggregate-enum-hash-arms
                variants
                prefix
                infos
                aggregate-name
                (+ index 1))
                [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
                [(OkGenHashmapSource rest-source)
                  (let
                    [buf : TextBuf (text-buf-empty)]
                    (begin
                      (set! buf (gen-tb3 buf "    [(" variant-name pattern))
                      (set! buf (gen-tb3 buf ") " body-source "]\n"))
                      (set! buf (text-buf-append buf rest-source))
                      (OkGenHashmapSource (text-buf-render buf))))])]))])))

(define (gen-hashmap-aggregate-enum-hash-expr
  [variants : CtfeReflectVariantList]
  [prefix : String]
  [infos : CtfeReflectInfoList]
  [aggregate-name : String]
  [expr : String]) : ResultGenHashmapSource
  (match (gen-hashmap-aggregate-enum-hash-arms
    variants
    prefix
    infos
    aggregate-name
    0)
    [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
    [(OkGenHashmapSource arms-source)
      (let
        [buf : TextBuf (text-buf-empty)]
        (begin
          (set! buf (gen-tb3 buf "(match " expr "\n"))
          (set! buf (text-buf-append buf arms-source))
          (set! buf (text-buf-append buf "  )"))
          (OkGenHashmapSource (text-buf-render buf))))]))

(define (gen-hashmap-aggregate-eq-expr
  [prefix : String]
  [aggregate-name : String]
  [member-name : String]
  [infos : CtfeReflectInfoList]
  [ty : AstType]
  [left-expr : String]
  [right-expr : String]) : ResultGenHashmapSource
  (let
    [resolved : AstType (ctfe-reflect-resolve-type infos ty)]
    [type-key : String (ctfe-type-key-with-reflections infos resolved)]
    (match resolved
      [(AstTyI64)
        (OkGenHashmapSource
          (string-append
            "(= "
            (string-append
              left-expr
              (string-append " " (string-append right-expr ")")))))]
      [(AstTyBool)
        (OkGenHashmapSource
          (string-append
            "(= "
            (string-append
              left-expr
              (string-append " " (string-append right-expr ")")))))]
      [(AstTyChar)
        (OkGenHashmapSource
          (string-append
            "(= "
            (string-append
              (string-append "(cast " (string-append left-expr " : i64)"))
              (string-append
                " "
                (string-append
                  (string-append "(cast " (string-append right-expr " : i64)"))
                  ")")))))]
      [(AstTyString)
        (OkGenHashmapSource
          (string-append
            "("
            (string-append
              prefix
              (string-append
                "-string-key-eq? (& "
                (string-append
                  left-expr
                  (string-append ") (& " (string-append right-expr "))")))))))]
      [(AstTyStruct name)
        (match (ctfe-reflect-info-lookup infos (ctfe-type-nominal-key resolved))
          [(CtfeSomeReflectInfo info)
            (match info
              [(CtfeReflectStruct _ _ _ fields)
                (gen-hashmap-aggregate-struct-eq-from
                  fields
                  prefix
                  infos
                  (intern-str name)
                  left-expr
                  right-expr
                  0)]
              [_
                (gen-hashmap-aggregate-unsupported
                  aggregate-name
                  member-name
                  type-key)])]
          [(CtfeNoReflectInfo) (gen-hashmap-aggregate-no-reflection type-key)])]
      [(AstTyEnum name)
        (match (ctfe-reflect-info-lookup infos (ctfe-type-nominal-key resolved))
          [(CtfeSomeReflectInfo info)
            (match info
              [(CtfeReflectEnum _ _ _ variants)
                (gen-hashmap-aggregate-enum-eq-expr
                  variants
                  prefix
                  infos
                  (intern-str name)
                  left-expr
                  right-expr)]
              [_
                (gen-hashmap-aggregate-unsupported
                  aggregate-name
                  member-name
                  type-key)])]
          [(CtfeNoReflectInfo) (gen-hashmap-aggregate-no-reflection type-key)])]
      [_
        (gen-hashmap-aggregate-unsupported aggregate-name member-name type-key)])))

(define (gen-hashmap-aggregate-and-expr [left : String] [right : String]) : String
  (string-append
    "(if "
    (string-append left (string-append " " (string-append right " false)")))))

(define (gen-hashmap-aggregate-struct-eq-from
  [fields : CtfeReflectFieldList]
  [prefix : String]
  [infos : CtfeReflectInfoList]
  [aggregate-name : String]
  [left-base : String]
  [right-base : String]
  [index : i64]) : ResultGenHashmapSource
  (if (>= index (ctfe-reflect-field-list-count fields))
    (OkGenHashmapSource "true")
    (match (ctfe-reflect-field-list-ref fields index)
      [(CtfeReflectField field-name ty)
        (let
          [left-field : String
            (gen-hashmap-aggregate-field-expr left-base field-name)]
          [right-field : String
            (gen-hashmap-aggregate-field-expr right-base field-name)]
          (match (gen-hashmap-aggregate-eq-expr
            prefix
            aggregate-name
            field-name
            infos
            ty
            left-field
            right-field)
            [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
            [(OkGenHashmapSource head-source)
              (match (gen-hashmap-aggregate-struct-eq-from
                fields
                prefix
                infos
                aggregate-name
                left-base
                right-base
                (+ index 1))
                [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
                [(OkGenHashmapSource rest-source)
                  (OkGenHashmapSource
                    (gen-hashmap-aggregate-and-expr head-source rest-source))])]))])))

(define (gen-hashmap-aggregate-payload-eq-from
  [payloads : AstTypeList]
  [prefix : String]
  [infos : CtfeReflectInfoList]
  [aggregate-name : String]
  [variant-name : String]
  [variant-index : i64]
  [payload-index : i64]) : ResultGenHashmapSource
  (if (>= payload-index (ctfe-type-list-count payloads))
    (OkGenHashmapSource "true")
    (match (ctfe-type-list-ref payloads infos payload-index)
      [(OkCtfeTypeLookup ty)
        (let
          [left-name : String
            (gen-hashmap-aggregate-payload-name
              "hashmap-left"
              variant-index
              payload-index)]
          [right-name : String
            (gen-hashmap-aggregate-payload-name
              "hashmap-right"
              variant-index
              payload-index)]
          [member-name : String
            (string-append
              variant-name
              (string-append "#" (int->string payload-index)))]
          (match (gen-hashmap-aggregate-eq-expr
            prefix
            aggregate-name
            member-name
            infos
            ty
            left-name
            right-name)
            [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
            [(OkGenHashmapSource head-source)
              (match (gen-hashmap-aggregate-payload-eq-from
                payloads
                prefix
                infos
                aggregate-name
                variant-name
                variant-index
                (+ payload-index 1))
                [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
                [(OkGenHashmapSource rest-source)
                  (OkGenHashmapSource
                    (gen-hashmap-aggregate-and-expr head-source rest-source))])]))]
      [(ErrCtfeTypeLookup message)
        (ErrGenHashmapSource (gen-hashmap-diag message))])))

(define (gen-hashmap-aggregate-enum-eq-arms
  [variants : CtfeReflectVariantList]
  [prefix : String]
  [infos : CtfeReflectInfoList]
  [aggregate-name : String]
  [right-expr : String]
  [index : i64]) : ResultGenHashmapSource
  (if (>= index (ctfe-reflect-variant-list-count variants))
    (OkGenHashmapSource "")
    (match (ctfe-reflect-variant-list-ref variants index)
      [(CtfeReflectVariant variant-name payloads)
        (let
          [payload-count : i64 (ctfe-type-list-count payloads)]
          [left-pattern : String
            (gen-hashmap-aggregate-payload-pattern
              "hashmap-left"
              index
              payload-count)]
          [right-pattern : String
            (gen-hashmap-aggregate-payload-pattern
              "hashmap-right"
              index
              payload-count)]
          (match (gen-hashmap-aggregate-payload-eq-from
            payloads
            prefix
            infos
            aggregate-name
            variant-name
            index
            0)
            [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
            [(OkGenHashmapSource body-source)
              (match (gen-hashmap-aggregate-enum-eq-arms
                variants
                prefix
                infos
                aggregate-name
                right-expr
                (+ index 1))
                [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
                [(OkGenHashmapSource rest-source)
                  (let
                    [buf : TextBuf (text-buf-empty)]
                    (begin
                      (set!
                        buf
                        (gen-tb3 buf "    [(" variant-name left-pattern))
                      (set!
                        buf
                        (gen-tb3 buf ")\n      (match " right-expr "\n"))
                      (set!
                        buf
                        (gen-tb3 buf "        [(" variant-name right-pattern))
                      (set! buf (gen-tb3 buf ") " body-source "]\n"))
                      (set! buf (text-buf-append buf "        [_ false])]\n"))
                      (set! buf (text-buf-append buf rest-source))
                      (OkGenHashmapSource (text-buf-render buf))))])]))])))

(define (gen-hashmap-aggregate-enum-eq-expr
  [variants : CtfeReflectVariantList]
  [prefix : String]
  [infos : CtfeReflectInfoList]
  [aggregate-name : String]
  [left-expr : String]
  [right-expr : String]) : ResultGenHashmapSource
  (match (gen-hashmap-aggregate-enum-eq-arms
    variants
    prefix
    infos
    aggregate-name
    right-expr
    0)
    [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
    [(OkGenHashmapSource arms-source)
      (let
        [buf : TextBuf (text-buf-empty)]
        (begin
          (set! buf (gen-tb3 buf "(match " left-expr "\n"))
          (set! buf (text-buf-append buf arms-source))
          (set! buf (text-buf-append buf "  )"))
          (OkGenHashmapSource (text-buf-render buf))))]))

(define (gen-hashmap-source-aggregate-key
  [map-name : String]
  [prefix : String]
  [key-type-key : String]
  [key-info : GenHashmapTypeInfo]
  [value-type : String]
  [infos : CtfeReflectInfoList]) : ResultGenHashmapSource
  (match (gen-hashmap-aggregate-type-from-key key-type-key)
    [(ErrGenHashmapType _)
      (gen-hashmap-descriptor-mismatch
        "stdlib/hashmap/aggregate-key-v1"
        key-type-key)]
    [(OkGenHashmapType key-ty)
      (let
        [key-type : String (gen-hashmap-type-info-source key-info)]
        [key-name : String (gen-hashmap-type-info-name key-info)]
        (match (gen-hashmap-aggregate-hash-expr
          prefix
          key-name
          "key"
          infos
          key-ty
          "key")
          [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
          [(OkGenHashmapSource hash-expr)
            (match (gen-hashmap-aggregate-eq-expr
              prefix
              key-name
              "key"
              infos
              key-ty
              "left"
              "right")
              [(ErrGenHashmapSource diag) (ErrGenHashmapSource diag)]
              [(OkGenHashmapSource eq-expr)
                (OkGenHashmapSource
                  (gen-hashmap-source-owned-key
                    map-name
                    prefix
                    key-type
                    (string-append "  " (string-append hash-expr ")\n"))
                    (gen-hashmap-source-aggregate-key-support prefix)
                    (string-append "  " (string-append eq-expr ")\n"))
                    (string-append prefix "-key-eq? slot-key key)")
                    (string-append "(init : " (string-append key-type ")"))
                    value-type))])]))]))

(define (gen-hashmap-descriptor-mismatch
  [descriptor : String]
  [key-type-key : String]) : ResultGenHashmapSource
  (ErrGenHashmapSource
    (gen-hashmap-diag
      (string-append
        "hashmap-family: descriptor "
        (string-append
          descriptor
          (string-append " does not support key type " key-type-key))))))

(define (gen-hashmap-type-info-source [info : GenHashmapTypeInfo]) : String
  (match info
    [(GenHashmapTypeInfo source _ _) source]))

(define (gen-hashmap-type-info-name [info : GenHashmapTypeInfo]) : String
  (match info
    [(GenHashmapTypeInfo _ name _) name]))

(define (gen-hashmap-type-info-prefix [info : GenHashmapTypeInfo]) : String
  (match info
    [(GenHashmapTypeInfo _ _ prefix) prefix]))

(define (gen-hashmap-source-for-info
  [map-name : String]
  [key-type-key : String]
  [_value-type-key : String]
  [descriptor : String]
  [key-info : GenHashmapTypeInfo]
  [value-info : GenHashmapTypeInfo]
  [infos : CtfeReflectInfoList]) : ResultGenHashmapSource
  (let
    [key-name : String (gen-hashmap-type-info-name key-info)]
    [key-prefix : String (gen-hashmap-type-info-prefix key-info)]
    [value-type : String (gen-hashmap-type-info-source value-info)]
    [value-name : String (gen-hashmap-type-info-name value-info)]
    [value-prefix : String (gen-hashmap-type-info-prefix value-info)]
    [expected-map : String
      (string-append key-name (string-append value-name "Map"))]
    [prefix : String
      (string-append
        key-prefix
        (string-append "-" (string-append value-prefix "-map")))]
    (cond
      [(not (string-eq map-name expected-map))
        (ErrGenHashmapSource
          (gen-hashmap-diag
            (string-append
              "hashmap-family: marker item "
              (string-append
                map-name
                (string-append " does not match generated map " expected-map)))))]
      [(string-eq descriptor "stdlib/hashmap/string-key-v1")
        (if (string-eq key-type-key "String")
          (OkGenHashmapSource
            (gen-hashmap-source-string-key map-name prefix value-type))
          (gen-hashmap-descriptor-mismatch descriptor key-type-key))]
      [(string-eq descriptor "stdlib/hashmap/i64-key-v1")
        (if (string-eq key-type-key "i64")
          (OkGenHashmapSource
            (gen-hashmap-source-i64-key map-name prefix value-type))
          (gen-hashmap-descriptor-mismatch descriptor key-type-key))]
      [(string-eq descriptor "stdlib/hashmap/aggregate-key-v1")
        (gen-hashmap-source-aggregate-key
          map-name
          prefix
          key-type-key
          key-info
          value-type
          infos)]
      [else
        (ErrGenHashmapSource
          (gen-hashmap-diag
            (string-append
              "hashmap-family: unsupported key descriptor "
              descriptor)))])))

(define (gen-hashmap-source-for
  [map-name : String]
  [key-type-key : String]
  [value-type-key : String]
  [descriptor : String]
  [env : CtfeEnv]) : ResultGenHashmapSource
  (match (gen-hashmap-key-type-info key-type-key descriptor)
    [(OkGenHashmapTypeInfo key-info)
      (match (gen-hashmap-value-type-info value-type-key)
        [(OkGenHashmapTypeInfo value-info)
          (gen-hashmap-source-for-info
            map-name
            key-type-key
            value-type-key
            descriptor
            key-info
            value-info
            (ctfe-env-reflections env))]
        [(ErrGenHashmapTypeInfo diag) (ErrGenHashmapSource diag)])]
    [(ErrGenHashmapTypeInfo diag) (ErrGenHashmapSource diag)]))

(define (gen-set-descriptor-mismatch
  [descriptor : String]
  [key-type-key : String]) : ResultGenSetSource
  (ErrGenSetSource
    (gen-set-diag
      (string-append
        "set-family: descriptor "
        (string-append
          descriptor
          (string-append " does not support key type " key-type-key))))))

(define (gen-set-key-type-info [type-key : String]) : ResultGenHashmapTypeInfo
  (if (string-eq type-key "String")
    (OkGenHashmapTypeInfo (GenHashmapTypeInfo "String" "String" "string"))
    (if (string-eq type-key "i64")
      (OkGenHashmapTypeInfo (GenHashmapTypeInfo "i64" "I64" "i64"))
      (ErrGenHashmapTypeInfo
        (gen-set-diag
          (string-append "set-family: unsupported key type " type-key))))))

(define (gen-set-source
  [set-name : String]
  [prefix : String]
  [key-type : String]
  [map-name : String]
  [map-prefix : String]
  [dummy-value : String]
  [borrowed-key? : bool]) : String
  (let
    [entry : String (string-append set-name "Entry")]
    [entry-none : String (string-append set-name "EntryNone")]
    [entry-some : String (string-append set-name "EntrySome")]
    [map-entry-none : String (string-append map-name "EntryNone")]
    [map-entry-some : String (string-append map-name "EntrySome")]
    [map-remove-ok : String (string-append map-name "RemoveOk")]
    [map-remove-missing : String (string-append map-name "RemoveMissing")]
    [buf : TextBuf (text-buf-empty)]
    (begin
      (set! buf (text-buf-append buf "(defstruct "))
      (set! buf (text-buf-append buf set-name))
      (set! buf (text-buf-append buf "\n  (map "))
      (set! buf (text-buf-append buf map-name))
      (set! buf (text-buf-append buf "))\n(defenum "))
      (set! buf (text-buf-append buf entry))
      (set! buf (text-buf-append buf "\n  ("))
      (set! buf (text-buf-append buf entry-none))
      (set! buf (text-buf-append buf ")\n  ("))
      (set! buf (text-buf-append buf entry-some))
      (set! buf (text-buf-append buf " "))
      (set! buf (text-buf-append buf key-type))
      (set! buf (text-buf-append buf "))\n(define ("))
      (set! buf (text-buf-append buf prefix))
      (set! buf (text-buf-append buf "-with-capacity [capacity : i64]) : "))
      (set! buf (text-buf-append buf set-name))
      (set! buf (text-buf-append buf "\n  ("))
      (set! buf (text-buf-append buf set-name))
      (set! buf (text-buf-append buf " ("))
      (set! buf (text-buf-append buf map-prefix))
      (set! buf (text-buf-append buf "-with-capacity capacity)))\n(define ("))
      (set! buf (text-buf-append buf prefix))
      (set! buf (text-buf-append buf "-new) : "))
      (set! buf (text-buf-append buf set-name))
      (set! buf (text-buf-append buf "\n  ("))
      (set! buf (text-buf-append buf prefix))
      (set! buf (text-buf-append buf "-with-capacity 8))\n(define ("))
      (set! buf (text-buf-append buf prefix))
      (set! buf (text-buf-append buf "-len [set : "))
      (set! buf (text-buf-append buf set-name))
      (set! buf (text-buf-append buf "]) : i64\n  ("))
      (set! buf (text-buf-append buf map-prefix))
      (set! buf (text-buf-append buf "-len (struct-get set map)))\n(define ("))
      (set! buf (text-buf-append buf prefix))
      (set! buf (text-buf-append buf "-capacity [set : "))
      (set! buf (text-buf-append buf set-name))
      (set! buf (text-buf-append buf "]) : i64\n  ("))
      (set! buf (text-buf-append buf map-prefix))
      (set! buf (text-buf-append buf "-capacity (struct-get set map)))\n"))
      (if borrowed-key?
        (begin
          (set! buf (text-buf-append buf "(define ("))
          (set! buf (text-buf-append buf prefix))
          (set! buf (text-buf-append buf "-contains-borrowed?\n  [set : "))
          (set! buf (text-buf-append buf set-name))
          (set!
            buf
            (text-buf-append buf "]\n  [key : (& key str)]) : bool\n  ("))
          (set! buf (text-buf-append buf map-prefix))
          (set!
            buf
            (text-buf-append
              buf
              "-contains-borrowed? (struct-get set map) key))\n(define ("))
          (set! buf (text-buf-append buf prefix))
          (set! buf (text-buf-append buf "-contains? [set : "))
          (set! buf (text-buf-append buf set-name))
          (set! buf (text-buf-append buf "] [key : "))
          (set! buf (text-buf-append buf key-type))
          (set! buf (text-buf-append buf "]) : bool\n  ("))
          (set! buf (text-buf-append buf prefix))
          (set! buf (text-buf-append buf "-contains-borrowed? set (& key)))\n")))
        (begin
          (set! buf (text-buf-append buf "(define ("))
          (set! buf (text-buf-append buf prefix))
          (set! buf (text-buf-append buf "-contains? [set : "))
          (set! buf (text-buf-append buf set-name))
          (set! buf (text-buf-append buf "] [key : "))
          (set! buf (text-buf-append buf key-type))
          (set! buf (text-buf-append buf "]) : bool\n  ("))
          (set! buf (text-buf-append buf map-prefix))
          (set!
            buf
            (text-buf-append buf "-contains? (struct-get set map) key))\n"))))
      (set! buf (text-buf-append buf "(define ("))
      (set! buf (text-buf-append buf prefix))
      (set! buf (text-buf-append buf "-insert [set : "))
      (set! buf (text-buf-append buf set-name))
      (set! buf (text-buf-append buf "] [key : "))
      (set! buf (text-buf-append buf key-type))
      (set! buf (text-buf-append buf "]) : "))
      (set! buf (text-buf-append buf set-name))
      (set! buf (text-buf-append buf "\n  ("))
      (set! buf (text-buf-append buf set-name))
      (set! buf (text-buf-append buf " ("))
      (set! buf (text-buf-append buf map-prefix))
      (set! buf (text-buf-append buf "-put (struct-get set map) key "))
      (set! buf (text-buf-append buf dummy-value))
      (set! buf (text-buf-append buf ")))\n"))
      (if borrowed-key?
        (begin
          (set! buf (text-buf-append buf "(define ("))
          (set! buf (text-buf-append buf prefix))
          (set! buf (text-buf-append buf "-remove-borrowed\n  [set : "))
          (set! buf (text-buf-append buf set-name))
          (set! buf (text-buf-append buf "]\n  [key : (& key str)]) : "))
          (set! buf (text-buf-append buf set-name))
          (set! buf (text-buf-append buf "\n  (match ("))
          (set! buf (text-buf-append buf map-prefix))
          (set!
            buf
            (text-buf-append
              buf
              "-remove-borrowed (struct-get set map) key)\n    [("))
          (set! buf (text-buf-append buf map-remove-ok))
          (set! buf (text-buf-append buf " map)\n      ("))
          (set! buf (text-buf-append buf set-name))
          (set! buf (text-buf-append buf " map)]\n    [("))
          (set! buf (text-buf-append buf map-remove-missing))
          (set! buf (text-buf-append buf " map)\n      ("))
          (set! buf (text-buf-append buf set-name))
          (set! buf (text-buf-append buf " map)]))\n(define ("))
          (set! buf (text-buf-append buf prefix))
          (set! buf (text-buf-append buf "-remove [set : "))
          (set! buf (text-buf-append buf set-name))
          (set! buf (text-buf-append buf "] [key : "))
          (set! buf (text-buf-append buf key-type))
          (set! buf (text-buf-append buf "]) : "))
          (set! buf (text-buf-append buf set-name))
          (set! buf (text-buf-append buf "\n  ("))
          (set! buf (text-buf-append buf prefix))
          (set! buf (text-buf-append buf "-remove-borrowed set (& key)))\n")))
        (begin
          (set! buf (text-buf-append buf "(define ("))
          (set! buf (text-buf-append buf prefix))
          (set! buf (text-buf-append buf "-remove [set : "))
          (set! buf (text-buf-append buf set-name))
          (set! buf (text-buf-append buf "] [key : "))
          (set! buf (text-buf-append buf key-type))
          (set! buf (text-buf-append buf "]) : "))
          (set! buf (text-buf-append buf set-name))
          (set! buf (text-buf-append buf "\n  (match ("))
          (set! buf (text-buf-append buf map-prefix))
          (set!
            buf
            (text-buf-append buf "-remove (struct-get set map) key)\n    [("))
          (set! buf (text-buf-append buf map-remove-ok))
          (set! buf (text-buf-append buf " map)\n      ("))
          (set! buf (text-buf-append buf set-name))
          (set! buf (text-buf-append buf " map)]\n    [("))
          (set! buf (text-buf-append buf map-remove-missing))
          (set! buf (text-buf-append buf " map)\n      ("))
          (set! buf (text-buf-append buf set-name))
          (set! buf (text-buf-append buf " map)]))\n"))))
      (set! buf (text-buf-append buf "(define ("))
      (set! buf (text-buf-append buf prefix))
      (set! buf (text-buf-append buf "-next-occupied [set : "))
      (set! buf (text-buf-append buf set-name))
      (set! buf (text-buf-append buf "] [from : i64]) : i64\n  ("))
      (set! buf (text-buf-append buf map-prefix))
      (set!
        buf
        (text-buf-append
          buf
          "-next-occupied (struct-get set map) from))\n(define ("))
      (set! buf (text-buf-append buf prefix))
      (set! buf (text-buf-append buf "-entry-at [set : "))
      (set! buf (text-buf-append buf set-name))
      (set! buf (text-buf-append buf "] [index : i64]) : "))
      (set! buf (text-buf-append buf entry))
      (set! buf (text-buf-append buf "\n  (match ("))
      (set! buf (text-buf-append buf map-prefix))
      (set!
        buf
        (text-buf-append buf "-entry-at (struct-get set map) index)\n    [("))
      (set! buf (text-buf-append buf map-entry-some))
      (set! buf (text-buf-append buf " key _) ("))
      (set! buf (text-buf-append buf entry-some))
      (set! buf (text-buf-append buf " key)]\n    [("))
      (set! buf (text-buf-append buf map-entry-none))
      (set! buf (text-buf-append buf ") ("))
      (set! buf (text-buf-append buf entry-none))
      (set! buf (text-buf-append buf ")]))\n"))
      (text-buf-render buf))))

(define (gen-set-source-for-info
  [set-name : String]
  [key-type-key : String]
  [descriptor : String]
  [key-info : GenHashmapTypeInfo]) : ResultGenSetSource
  (let
    [key-source : String (gen-hashmap-type-info-source key-info)]
    [key-name : String (gen-hashmap-type-info-name key-info)]
    [key-prefix : String (gen-hashmap-type-info-prefix key-info)]
    [expected-set : String (string-append key-name "Set")]
    [prefix : String (string-append key-prefix "-set")]
    (cond
      [(not (string-eq set-name expected-set))
        (ErrGenSetSource
          (gen-set-diag
            (string-append
              "set-family: marker item "
              (string-append
                set-name
                (string-append " does not match generated set " expected-set)))))]
      [(string-eq descriptor "stdlib/hashmap/string-key-v1")
        (if (string-eq key-type-key "String")
          (OkGenSetSource
            (gen-set-source
              set-name
              prefix
              key-source
              "StringStringMap"
              "string-string-map"
              "(init : String)"
              true))
          (gen-set-descriptor-mismatch descriptor key-type-key))]
      [(string-eq descriptor "stdlib/hashmap/i64-key-v1")
        (if (string-eq key-type-key "i64")
          (OkGenSetSource
            (gen-set-source
              set-name
              prefix
              key-source
              "I64I64Map"
              "i64-i64-map"
              "1"
              false))
          (gen-set-descriptor-mismatch descriptor key-type-key))]
      [else
        (ErrGenSetSource
          (gen-set-diag
            (string-append "set-family: unsupported key descriptor " descriptor)))])))

(define (gen-set-source-for
  [set-name : String]
  [key-type-key : String]
  [descriptor : String]) : ResultGenSetSource
  (match (gen-set-key-type-info key-type-key)
    [(OkGenHashmapTypeInfo key-info)
      (gen-set-source-for-info set-name key-type-key descriptor key-info)]
    [(ErrGenHashmapTypeInfo diag) (ErrGenSetSource diag)]))

(define (gen-json-result-name [type-name : String]) : String
  (string-append type-name "JsonResult"))

(define (gen-json-ok-name [type-name : String]) : String
  (string-append "Ok" (string-append type-name "Json")))

(define (gen-json-err-name [type-name : String]) : String
  (string-append "Err" (string-append type-name "Json")))

(define (gen-json-to-name [type-name : String]) : String
  (string-append (gen-hashmap-name-prefix type-name) "-to-json"))

(define (gen-json-from-name [type-name : String]) : String
  (string-append (gen-hashmap-name-prefix type-name) "-from-json"))

(define (gen-json-supported-int? [type-key : String]) : bool
  (or
    (string-eq type-key "i64")
    (string-eq type-key "i32")
    (string-eq type-key "i16")
    (string-eq type-key "i8")
    (string-eq type-key "u32")
    (string-eq type-key "u16")
    (string-eq type-key "u8")))

(define (gen-json-field-unsupported [field-name : String] [type-key : String]) : ResultGenJsonSource
  (ErrGenJsonSource
    (gen-json-diag
      (string-append
        "json-derive: unsupported field "
        (string-append field-name (string-append " type " type-key))))))

(define (gen-json-field-type-source
  [field-name : String]
  [infos : CtfeReflectInfoList]
  [ty : AstType]) : ResultGenJsonSource
  (let
    [resolved : AstType (ctfe-reflect-resolve-type infos ty)]
    [type-key : String (ctfe-type-key-with-reflections infos resolved)]
    (match resolved
      [(AstTyBool) (OkGenJsonSource "bool")]
      [(AstTyString) (OkGenJsonSource "String")]
      [(AstTyI64) (OkGenJsonSource "i64")]
      [(AstTyI32) (OkGenJsonSource "i32")]
      [(AstTyI16) (OkGenJsonSource "i16")]
      [(AstTyI8) (OkGenJsonSource "i8")]
      [(AstTyU32) (OkGenJsonSource "u32")]
      [(AstTyU16) (OkGenJsonSource "u16")]
      [(AstTyU8) (OkGenJsonSource "u8")]
      [(AstTyStruct name) (OkGenJsonSource (intern-str name))]
      [_ (gen-json-field-unsupported field-name type-key)])))

(define (gen-json-field-init-source
  [field-name : String]
  [infos : CtfeReflectInfoList]
  [ty : AstType]) : ResultGenJsonSource
  (match (gen-json-field-type-source field-name infos ty)
    [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
    [(OkGenJsonSource type-source)
      (let
        [type-key : String (ctfe-type-key-with-reflections infos ty)]
        (cond
          [(string-eq type-source "bool") (OkGenJsonSource "false")]
          [(string-eq type-source "String") (OkGenJsonSource "\"\"")]
          [(string-eq type-source "i64") (OkGenJsonSource "0")]
          [(gen-json-supported-int? type-key)
            (OkGenJsonSource
              (string-append "(cast 0 : " (string-append type-source ")")))]
          [else
            (OkGenJsonSource
              (string-append "(init : " (string-append type-source ")")))]))]))

(define (gen-json-field-access [field-name : String]) : String
  (string-append "(struct-get value " (string-append field-name ")")))

(define (gen-json-field-to-json-source
  [field-name : String]
  [infos : CtfeReflectInfoList]
  [ty : AstType]) : ResultGenJsonSource
  (match (gen-json-field-type-source field-name infos ty)
    [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
    [(OkGenJsonSource type-source)
      (let
        [type-key : String (ctfe-type-key-with-reflections infos ty)]
        [field-access : String (gen-json-field-access field-name)]
        (cond
          [(string-eq type-source "bool")
            (OkGenJsonSource
              (string-append "(JsonBool " (string-append field-access ")")))]
          [(string-eq type-source "String")
            (OkGenJsonSource
              (string-append "(JsonString " (string-append field-access ")")))]
          [(gen-json-supported-int? type-key)
            (OkGenJsonSource
              (if (string-eq type-key "i64")
                (string-append
                  "(json-i64->number "
                  (string-append field-access ")"))
                (string-append
                  "(json-i64->number (cast "
                  (string-append field-access " : i64))"))))]
          [else
            (match (gen-hashmap-nominal-name type-key "struct_")
              [(SpecSomeString name)
                (OkGenJsonSource
                  (string-append
                    "("
                    (string-append
                      (gen-json-to-name name)
                      (string-append " " (string-append field-access ")")))))]
              [(SpecNoString) (gen-json-field-unsupported field-name type-key)])]))]))

(define (gen-json-to-members-source-from
  [fields : CtfeReflectFieldList]
  [infos : CtfeReflectInfoList]
  [index : i64]) : ResultGenJsonSource
  (if (>= index (ctfe-reflect-field-list-count fields))
    (OkGenJsonSource "JsonMemberListNil")
    (match (ctfe-reflect-field-list-ref fields index)
      [(CtfeReflectField field-name ty)
        (match (gen-json-field-to-json-source field-name infos ty)
          [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
          [(OkGenJsonSource value-source)
            (match (gen-json-to-members-source-from fields infos (+ index 1))
              [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
              [(OkGenJsonSource rest-source)
                (let
                  [buf : TextBuf (text-buf-empty)]
                  (begin
                    (set!
                      buf
                      (gen-tb5
                        buf
                        "(JsonMemberListCons \""
                        field-name
                        "\" "
                        value-source
                        " (box "))
                    (set! buf (text-buf-append buf rest-source))
                    (set! buf (text-buf-append buf "))"))
                    (OkGenJsonSource (text-buf-render buf))))])])])))

(define (gen-json-to-members-source
  [fields : CtfeReflectFieldList]
  [infos : CtfeReflectInfoList]) : ResultGenJsonSource
  (gen-json-to-members-source-from fields infos 0))

(define (gen-json-local-name [index : i64]) : String
  (string-append "json-field-" (int->string index)))

(define (gen-json-key-name [index : i64]) : String
  (string-append "json-key-" (int->string index)))

(define (gen-json-value-name [index : i64]) : String
  (string-append "json-value-" (int->string index)))

(define (gen-json-let-bindings-source
  [fields : CtfeReflectFieldList]
  [infos : CtfeReflectInfoList]
  [index : i64]) : ResultGenJsonSource
  (if (>= index (ctfe-reflect-field-list-count fields))
    (OkGenJsonSource "")
    (match (ctfe-reflect-field-list-ref fields index)
      [(CtfeReflectField field-name ty)
        (match (gen-json-field-type-source field-name infos ty)
          [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
          [(OkGenJsonSource type-source)
            (match (gen-json-field-init-source field-name infos ty)
              [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
              [(OkGenJsonSource init-source)
                (match (gen-json-let-bindings-source fields infos (+ index 1))
                  [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
                  [(OkGenJsonSource rest-source)
                    (let
                      [buf : TextBuf (text-buf-empty)]
                      (begin
                        (set!
                          buf
                          (gen-tb7
                            buf
                            "        ["
                            (gen-json-local-name index)
                            " : "
                            type-source
                            " "
                            init-source
                            "]\n"))
                        (set! buf (text-buf-append buf rest-source))
                        (OkGenJsonSource (text-buf-render buf))))])])])])))

(define (gen-json-kind-error-source
  [err-name : String]
  [field-name : String]
  [expected : String]) : String
  (text-buf-render
    (gen-tb7
      (text-buf-empty)
      "(return ("
      err-name
      " \"json-derive: field "
      field-name
      " expected "
      expected
      "\"))")))

(define (gen-json-int-min-expr [type-key : String]) : String
  (cond
    [(string-eq type-key "i32") "(- 0 2147483648)"]
    [(string-eq type-key "i16") "(- 0 32768)"]
    [(string-eq type-key "i8") "(- 0 128)"]
    [else "0"]))

(define (gen-json-int-max-expr [type-key : String]) : String
  (cond
    [(string-eq type-key "i32") "2147483647"]
    [(string-eq type-key "i16") "32767"]
    [(string-eq type-key "i8") "127"]
    [(string-eq type-key "u32") "4294967295"]
    [(string-eq type-key "u16") "65535"]
    [(string-eq type-key "u8") "255"]
    [else "9223372036854775807"]))

(define (gen-json-int-set-source
  [local-name : String]
  [field-name : String]
  [type-source : String]
  [type-key : String]
  [err-name : String]) : String
  (if (string-eq type-key "i64")
    (string-append "(set! " (string-append local-name " parsed)"))
    (let
      [min-expr : String (gen-json-int-min-expr type-key)]
      [max-expr : String (gen-json-int-max-expr type-key)]
      [buf : TextBuf (text-buf-empty)]
      (begin
        (set!
          buf
          (gen-tb5
            buf
            "(if (if (< parsed "
            min-expr
            ") true (> parsed "
            max-expr
            "))\n        "))
        (set!
          buf
          (gen-tb7
            buf
            "(return ("
            err-name
            " \"json-derive: field "
            field-name
            " outside "
            type-source
            " range\"))\n        "))
        (set!
          buf
          (gen-tb5 buf "(set! " local-name " (cast parsed : " type-source ")))"))
        (text-buf-render buf)))))

(define (gen-json-field-invalid-source
  [err-name : String]
  [field-name : String]
  [type-source : String]) : String
  (text-buf-render
    (gen-tb7
      (text-buf-empty)
      "(return ("
      err-name
      " (string-append \"json-derive: field "
      field-name
      " invalid "
      type-source
      ": \" err)))")))

(define (gen-json-from-value-source
  [field-name : String]
  [infos : CtfeReflectInfoList]
  [ty : AstType]
  [local-name : String]
  [value-name : String]
  [err-name : String]) : ResultGenJsonSource
  (match (gen-json-field-type-source field-name infos ty)
    [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
    [(OkGenJsonSource type-source)
      (let
        [type-key : String (ctfe-type-key-with-reflections infos ty)]
        (cond
          [(string-eq type-source "bool")
            (OkGenJsonSource
              (string-append
                "(match "
                (string-append
                  value-name
                  (string-append
                    "\n        [(JsonBool parsed) (set! "
                    (string-append
                      local-name
                      (string-append
                        " parsed)]\n        [_ "
                        (string-append
                          (gen-json-kind-error-source
                            err-name
                            field-name
                            "bool")
                          "])")))))))]
          [(string-eq type-source "String")
            (OkGenJsonSource
              (string-append
                "(match "
                (string-append
                  value-name
                  (string-append
                    "\n        [(JsonString parsed) (set! "
                    (string-append
                      local-name
                      (string-append
                        " parsed)]\n        [_ "
                        (string-append
                          (gen-json-kind-error-source
                            err-name
                            field-name
                            "String")
                          "])")))))))]
          [(gen-json-supported-int? type-key)
            (let
              [set-source : String
                (gen-json-int-set-source
                  local-name
                  field-name
                  type-source
                  type-key
                  err-name)]
              [buf : TextBuf (text-buf-empty)]
              (begin
                (set! buf (gen-tb3 buf "(match " value-name "\n"))
                (set!
                  buf
                  (text-buf-append
                    buf
                    "        [(JsonNumber text)\n          (match (json-number-owned->i64 text)\n            [(OkJsonNumberI64 parsed) "))
                (set! buf (text-buf-append buf set-source))
                (set!
                  buf
                  (text-buf-append
                    buf
                    "]\n            [(ErrJsonNumberI64 err) "))
                (set!
                  buf
                  (text-buf-append
                    buf
                    (gen-json-field-invalid-source
                      err-name
                      field-name
                      type-source)))
                (set! buf (text-buf-append buf "])]\n        [_ "))
                (set!
                  buf
                  (text-buf-append
                    buf
                    (gen-json-kind-error-source err-name field-name type-source)))
                (set! buf (text-buf-append buf "])"))
                (OkGenJsonSource (text-buf-render buf))))]
          [else
            (match (gen-hashmap-nominal-name type-key "struct_")
              [(SpecSomeString nested-name)
                (let
                  [nested-from : String (gen-json-from-name nested-name)]
                  [nested-ok : String (gen-json-ok-name nested-name)]
                  [nested-err : String (gen-json-err-name nested-name)]
                  [buf : TextBuf (text-buf-empty)]
                  (begin
                    (set!
                      buf
                      (gen-tb5
                        buf
                        "(match ("
                        nested-from
                        " "
                        value-name
                        ")\n        [("))
                    (set!
                      buf
                      (gen-tb6
                        buf
                        nested-ok
                        " parsed) (set! "
                        local-name
                        " parsed)]\n        [("
                        nested-err
                        " err) "))
                    (set!
                      buf
                      (text-buf-append
                        buf
                        (gen-json-field-invalid-source
                          err-name
                          field-name
                          type-source)))
                    (set! buf (text-buf-append buf "])"))
                    (OkGenJsonSource (text-buf-render buf))))]
              [(SpecNoString) (gen-json-field-unsupported field-name type-key)])]))]))

(define (gen-json-from-field-statement-source
  [field-name : String]
  [infos : CtfeReflectInfoList]
  [ty : AstType]
  [index : i64]
  [err-name : String]) : ResultGenJsonSource
  (let
    [local-name : String (gen-json-local-name index)]
    [key-name : String (gen-json-key-name index)]
    [value-name : String (gen-json-value-name index)]
    (match (gen-json-from-value-source
      field-name
      infos
      ty
      local-name
      value-name
      err-name)
      [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
      [(OkGenJsonSource value-source)
        (let
          [buf : TextBuf (text-buf-empty)]
          (begin
            (set!
              buf
              (gen-tb6
                buf
                "          (let\n            ["
                key-name
                " : String \""
                field-name
                "\"]\n            (match (json-object-get-owned value "
                key-name))
            (set!
              buf
              (gen-tb3
                buf
                ")\n              [(JsonFound "
                value-name
                ")\n                "))
            (set! buf (text-buf-append buf value-source))
            (set!
              buf
              (gen-tb7
                buf
                "]\n              [(JsonMissing) (return ("
                err-name
                " \"json-derive: missing field "
                field-name
                "\"))]))\n"
                ""
                ""))
            (OkGenJsonSource (text-buf-render buf))))])))

(define (gen-json-from-statements-source
  [fields : CtfeReflectFieldList]
  [infos : CtfeReflectInfoList]
  [index : i64]
  [err-name : String]) : ResultGenJsonSource
  (if (>= index (ctfe-reflect-field-list-count fields))
    (OkGenJsonSource "")
    (match (ctfe-reflect-field-list-ref fields index)
      [(CtfeReflectField field-name ty)
        (match (gen-json-from-field-statement-source
          field-name
          infos
          ty
          index
          err-name)
          [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
          [(OkGenJsonSource head-source)
            (match (gen-json-from-statements-source
              fields
              infos
              (+ index 1)
              err-name)
              [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
              [(OkGenJsonSource rest-source)
                (OkGenJsonSource (string-append head-source rest-source))])])])))

(define (gen-json-constructor-args-from [index : i64] [count : i64]) : String
  (if (>= index count)
    ""
    (string-append
      " "
      (string-append
        (gen-json-local-name index)
        (gen-json-constructor-args-from (+ index 1) count)))))

(define (gen-json-from-body-source
  [type-name : String]
  [fields : CtfeReflectFieldList]
  [infos : CtfeReflectInfoList]) : ResultGenJsonSource
  (let
    [field-count : i64 (ctfe-reflect-field-list-count fields)]
    [ok-name : String (gen-json-ok-name type-name)]
    [err-name : String (gen-json-err-name type-name)]
    [args : String (gen-json-constructor-args-from 0 field-count)]
    (if (= field-count 0)
      (OkGenJsonSource
        (string-append
          "("
          (string-append
            ok-name
            (string-append " (" (string-append type-name "))")))))
      (match (gen-json-let-bindings-source fields infos 0)
        [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
        [(OkGenJsonSource bindings-source)
          (match (gen-json-from-statements-source fields infos 0 err-name)
            [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
            [(OkGenJsonSource statements-source)
              (let
                [buf : TextBuf (text-buf-empty)]
                (begin
                  (set! buf (text-buf-append buf "(let\n"))
                  (set! buf (text-buf-append buf bindings-source))
                  (set! buf (text-buf-append buf "        (begin\n"))
                  (set! buf (text-buf-append buf statements-source))
                  (set!
                    buf
                    (gen-tb7
                      buf
                      "          ("
                      ok-name
                      " ("
                      type-name
                      args
                      "))))"
                      ""))
                  (OkGenJsonSource (text-buf-render buf))))])]))))

(define (gen-json-source-for-fields
  [type-name : String]
  [fields : CtfeReflectFieldList]
  [infos : CtfeReflectInfoList]) : ResultGenJsonSource
  (let
    [result-name : String (gen-json-result-name type-name)]
    [ok-name : String (gen-json-ok-name type-name)]
    [err-name : String (gen-json-err-name type-name)]
    [to-name : String (gen-json-to-name type-name)]
    [from-name : String (gen-json-from-name type-name)]
    (match (gen-json-to-members-source fields infos)
      [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
      [(OkGenJsonSource members-source)
        (match (gen-json-from-body-source type-name fields infos)
          [(ErrGenJsonSource diag) (ErrGenJsonSource diag)]
          [(OkGenJsonSource from-body)
            (let
              [buf : TextBuf (text-buf-empty)]
              (begin
                (set!
                  buf
                  (gen-tb7
                    buf
                    "(defenum "
                    result-name
                    "\n  ("
                    ok-name
                    " "
                    type-name
                    ")\n  ("))
                (set!
                  buf
                  (gen-tb6
                    buf
                    err-name
                    " String))\n(define ("
                    to-name
                    " [value : "
                    type-name
                    "]) : Json\n  "))
                (set! buf (text-buf-append buf "(JsonObject\n    (box\n      "))
                (set! buf (text-buf-append buf members-source))
                (set! buf (text-buf-append buf ")))\n(define ("))
                (set! buf (text-buf-append buf from-name))
                (set! buf (text-buf-append buf " [value : Json]) : "))
                (set! buf (text-buf-append buf result-name))
                (set!
                  buf
                  (text-buf-append
                    buf
                    "\n  (match value\n    [(JsonObject _)\n      "))
                (set! buf (text-buf-append buf from-body))
                (set!
                  buf
                  (gen-tb5
                    buf
                    "]\n    [_ ("
                    err-name
                    " \"json-derive: expected object for "
                    type-name
                    "\")]))\n"))
                (OkGenJsonSource (text-buf-render buf))))])])))

(define (gen-json-source-for
  [request-name : String]
  [ty : AstType]
  [env : CtfeEnv]) : ResultGenJsonSource
  (let
    [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
    [resolved : AstType (ctfe-reflect-resolve-type infos ty)]
    [type-key : String (ctfe-type-key-with-reflections infos resolved)]
    (match resolved
      [(AstTyStruct name)
        (let
          [type-name : String (intern-str name)]
          [expected-request : String (string-append type-name "Json")]
          (if (not (string-eq request-name expected-request))
            (ErrGenJsonSource
              (gen-json-diag
                (string-append
                  "json-derive: marker item "
                  (string-append
                    request-name
                    (string-append
                      " does not match generated request "
                      expected-request)))))
            (match (ctfe-reflect-info-lookup
              infos
              (ctfe-type-nominal-key resolved))
              [(CtfeSomeReflectInfo info)
                (match info
                  [(CtfeReflectStruct _ _ _ fields)
                    (gen-json-source-for-fields type-name fields infos)]
                  [_ (gen-json-field-unsupported request-name type-key)])]
              [(CtfeNoReflectInfo)
                (ErrGenJsonSource
                  (gen-json-diag
                    (string-append
                      "json-derive: no reflection metadata for "
                      type-key)))])))]
      [_ (gen-json-field-unsupported request-name type-key)])))

(define (gen-register-generated-decl
  [template : AstDecl]
  [module : String]
  [generator : String]
  [item : String]
  [args : AstExprList]
  [arg-key : String]
  [registry : GenRegistry]) : ResultGenDecl
  (let
    [key : String (gen-full-key module generator item arg-key)]
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
          (ErrGenDecl (gen-incompatible-diag item key)))])))

(define (gen-register-generated-decls
  [decls : AstDeclList]
  [module : String]
  [generator : String]
  [args : AstExprList]
  [arg-key : String]
  [registry : GenRegistry]) : ResultGenDecl
  (match decls
    [(AstDeclNil) (OkGenDecl AstDeclNil registry module)]
    [(AstDeclCons decl rest-box)
      (match (gen-decl-visible-name decl)
        [(SpecNoString)
          (match decl
            [(AstDeclImport _)
              (match (gen-register-generated-decls
                (box-get rest-box)
                module
                generator
                args
                arg-key
                registry)
                [(OkGenDecl rewritten-rest rest-registry rest-module)
                  (OkGenDecl
                    (ast-decl-cons decl rewritten-rest)
                    rest-registry
                    rest-module)]
                [(ErrGenDecl diag) (ErrGenDecl diag)])]
            [_
              (ErrGenDecl
                (gen-hashmap-diag
                  "hashmap-family: generated payload must declare a visible item"))])]
        [(SpecSomeString item)
          (match (gen-register-generated-decl
            decl
            module
            generator
            item
            args
            arg-key
            registry)
            [(OkGenDecl rewritten-head head-registry _)
              (match (gen-register-generated-decls
                (box-get rest-box)
                module
                generator
                args
                arg-key
                head-registry)
                [(OkGenDecl rewritten-rest rest-registry rest-module)
                  (OkGenDecl
                    (spec-decl-list-append rewritten-head rewritten-rest)
                    rest-registry
                    rest-module)]
                [(ErrGenDecl diag) (ErrGenDecl diag)])]
            [(ErrGenDecl diag) (ErrGenDecl diag)])])]))

(define (gen-register-generated-decl-raw
  [template : AstDecl]
  [module : String]
  [generator : String]
  [item : String]
  [arg-key : String]
  [registry : GenRegistry]) : ResultGenDecl
  (let
    [key : String (gen-full-key module generator item arg-key)]
    (match (gen-registry-lookup registry key)
      [(GenNoEntry)
        (OkGenDecl
          (gen-single-decl-list template)
          (gen-registry-insert registry key template)
          module)]
      [(GenSomeEntry existing)
        (if (gen-decl-eq? existing template)
          (OkGenDecl AstDeclNil registry module)
          (ErrGenDecl (gen-incompatible-diag item key)))])))

;; JSON derive emits runtime helpers that call imported stdlib functions. Keep
;; the registry key for dedup, but leave declarations raw so the run pipeline
;; resolves them like ordinary request-site declarations.
(define (gen-register-generated-decls-raw
  [decls : AstDeclList]
  [module : String]
  [generator : String]
  [arg-key : String]
  [registry : GenRegistry]) : ResultGenDecl
  (match decls
    [(AstDeclNil) (OkGenDecl AstDeclNil registry module)]
    [(AstDeclCons decl rest-box)
      (match (gen-decl-visible-name decl)
        [(SpecNoString)
          (match decl
            [(AstDeclImport _)
              (match (gen-register-generated-decls-raw
                (box-get rest-box)
                module
                generator
                arg-key
                registry)
                [(OkGenDecl rewritten-rest rest-registry rest-module)
                  (OkGenDecl
                    (ast-decl-cons decl rewritten-rest)
                    rest-registry
                    rest-module)]
                [(ErrGenDecl diag) (ErrGenDecl diag)])]
            [_
              (ErrGenDecl
                (gen-json-diag
                  "json-derive: generated payload must declare a visible item"))])]
        [(SpecSomeString item)
          (match (gen-register-generated-decl-raw
            decl
            module
            generator
            item
            arg-key
            registry)
            [(OkGenDecl rewritten-head head-registry _)
              (match (gen-register-generated-decls-raw
                (box-get rest-box)
                module
                generator
                arg-key
                head-registry)
                [(OkGenDecl rewritten-rest rest-registry rest-module)
                  (OkGenDecl
                    (spec-decl-list-append rewritten-head rewritten-rest)
                    rest-registry
                    rest-module)]
                [(ErrGenDecl diag) (ErrGenDecl diag)])]
            [(ErrGenDecl diag) (ErrGenDecl diag)])])]))

(define (gen-hashmap-expand-family
  [map-name : String]
  [module : String]
  [generator : String]
  [args : AstExprList]
  [arg-key : String]
  [registry : GenRegistry]
  [env : CtfeEnv]) : ResultGenDecl
  (match (gen-hashmap-args args env)
    [(OkGenHashmapArgs parsed-args)
      (match parsed-args
        [(GenHashmapArgs key-type value-type descriptor)
          (match (gen-hashmap-source-for
            map-name
            key-type
            value-type
            descriptor
            env)
            [(OkGenHashmapSource source)
              (match (parse-ast-source source)
                [(OkAstProgram (AstProgram decls-box))
                  (gen-register-generated-decls
                    (box-get decls-box)
                    module
                    generator
                    args
                    arg-key
                    registry)]
                [(ErrAstProgram message)
                  (ErrGenDecl
                    (gen-hashmap-diag
                      (string-append
                        "hashmap-family: generated source did not parse: "
                        message)))])]
            [(ErrGenHashmapSource diag) (ErrGenDecl diag)])])]
    [(ErrGenHashmapArgs diag) (ErrGenDecl diag)]))

(define (gen-set-expand-family
  [set-name : String]
  [module : String]
  [generator : String]
  [args : AstExprList]
  [arg-key : String]
  [registry : GenRegistry]
  [env : CtfeEnv]) : ResultGenDecl
  (match (gen-set-args args env)
    [(OkGenSetArgs parsed-args)
      (match parsed-args
        [(GenSetArgs key-type descriptor)
          (match (gen-set-source-for set-name key-type descriptor)
            [(OkGenSetSource source)
              (match (parse-ast-source source)
                [(OkAstProgram (AstProgram decls-box))
                  (gen-register-generated-decls
                    (box-get decls-box)
                    module
                    generator
                    args
                    arg-key
                    registry)]
                [(ErrAstProgram message)
                  (ErrGenDecl
                    (gen-set-diag
                      (string-append
                        "set-family: generated source did not parse: "
                        message)))])]
            [(ErrGenSetSource diag) (ErrGenDecl diag)])])]
    [(ErrGenSetArgs diag) (ErrGenDecl diag)]))

(define (gen-json-expand-family
  [request-name : String]
  [module : String]
  [generator : String]
  [args : AstExprList]
  [arg-key : String]
  [registry : GenRegistry]
  [env : CtfeEnv]) : ResultGenDecl
  (match (gen-json-args args env)
    [(OkGenJsonDeriveArgs parsed-args)
      (match parsed-args
        [(GenJsonDeriveArgs ty)
          (match (gen-json-source-for request-name ty env)
            [(OkGenJsonSource source)
              (match (parse-ast-source source)
                [(OkAstProgram (AstProgram decls-box))
                  (gen-register-generated-decls-raw
                    (box-get decls-box)
                    module
                    generator
                    arg-key
                    registry)]
                [(ErrAstProgram message)
                  (ErrGenDecl
                    (gen-json-diag
                      (string-append
                        "json-derive: generated source did not parse: "
                        message)))])]
            [(ErrGenJsonSource diag) (ErrGenDecl diag)])])]
    [(ErrGenJsonDeriveArgs diag) (ErrGenDecl diag)]))

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
          [(AstSomeGeneratedDeclMeta generator item args _)
            (match (gen-decl-visible-name template)
              [(SpecNoString)
                (ErrGenDecl
                  (compiler-diagnostic-at-start
                    ""
                    "generated-decl: generated payload must declare a visible item"))]
              [(SpecSomeString actual)
                (if (not (string-eq item actual))
                  (ErrGenDecl (gen-item-mismatch-diag item actual))
                  (match (gen-key-exprs args env (ctfe-fuel-limit))
                    [(OkGenKey arg-key _)
                      (cond
                        [(string-eq generator "stdlib/hashmap-family")
                          (match (gen-hashmap-family-marker-name template)
                            [(SpecSomeString map-name)
                              (gen-hashmap-expand-family
                                map-name
                                module
                                generator
                                args
                                arg-key
                                registry
                                env)]
                            [(SpecNoString)
                              (gen-register-generated-decl
                                template
                                module
                                generator
                                item
                                args
                                arg-key
                                registry)])]
                        [(string-eq generator "stdlib/set-family")
                          (match (gen-set-family-marker-name template)
                            [(SpecSomeString set-name)
                              (gen-set-expand-family
                                set-name
                                module
                                generator
                                args
                                arg-key
                                registry
                                env)]
                            [(SpecNoString)
                              (gen-register-generated-decl
                                template
                                module
                                generator
                                item
                                args
                                arg-key
                                registry)])]
                        [(string-eq generator "stdlib/json-derive")
                          (match (gen-json-derive-marker-name template)
                            [(SpecSomeString request-name)
                              (gen-json-expand-family
                                request-name
                                module
                                generator
                                args
                                arg-key
                                registry
                                env)]
                            [(SpecNoString)
                              (gen-register-generated-decl
                                template
                                module
                                generator
                                item
                                args
                                arg-key
                                registry)])]
                        [else
                          (gen-register-generated-decl
                            template
                            module
                            generator
                            item
                            args
                            arg-key
                            registry)])]
                    [(ErrGenKey diag) (ErrGenDecl diag)]))])]))]
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

(define (gen-normalize-program [program : AstProgram]) : ResultGenProgram
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [env : CtfeEnv
          (ctfe-env-with-reflections (ctfe-reflections-from-program program))]
        (match (gen-rewrite-decls decls "" (gen-registry-empty) env)
          [(OkGenDecls rewritten _ _) (OkGenProgram (ast-program rewritten))]
          [(ErrGenDecls diag) (ErrGenProgram diag)]))]))

(define (gen-normalize-program-with-paths
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

(define (gen-decl-needs-normalize? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclComptimeDecl meta _)
      (match meta
        [(AstSomeGeneratedDeclMeta _ _ _ _) true]
        [(AstNoGeneratedDeclMeta) false])]
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
      (ctfe-type-eq ty (AstTyVar (intern "ExprClauseList")))]))

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
    [(CtfeExprClauseList _) "ExprClauseList"]))

(define (spec-type-subst-lookup [subs : SpecTypeSubst] [name : String]) : SpecMaybeString
  (match subs
    [(SpecTypeSubstNil) (SpecNoString)]
    [(SpecTypeSubstCons key _ rest)
      (if (string-eq key name)
        (SpecSomeString key)
        (spec-type-subst-lookup (box-get rest) name))]))

(define (spec-type-subst-type [subs : SpecTypeSubst] [name : String]) : AstType
  (match subs
    [(SpecTypeSubstNil) (AstTyVar (intern name))]
    [(SpecTypeSubstCons key ty rest)
      (if (string-eq key name)
        ty
        (spec-type-subst-type (box-get rest) name))]))

(define (spec-value-subst-lookup [subs : SpecValueSubst] [name : String]) : SpecMaybeString
  (match subs
    [(SpecValueSubstNil) (SpecNoString)]
    [(SpecValueSubstCons key _ rest)
      (if (string-eq key name)
        (SpecSomeString key)
        (spec-value-subst-lookup (box-get rest) name))]))

(define (spec-value-subst-value [subs : SpecValueSubst] [name : String]) : CompilerCtfeValue
  (match subs
    [(SpecValueSubstNil) (CtfeUnit)]
    [(SpecValueSubstCons key value rest)
      (if (string-eq key name)
        value
        (spec-value-subst-value (box-get rest) name))]))

(define (spec-value-subst-remove-name [subs : SpecValueSubst] [name : String]) : SpecValueSubst
  (match subs
    [(SpecValueSubstNil) SpecValueSubstNil]
    [(SpecValueSubstCons key value rest)
      (if (string-eq key name)
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
      (if (string-eq key name)
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
        (spec-substitute-type-list args subs)
        (spec-substitute-type (ty-node-get ret) subs))]
    [(AstTyTuple elems) (AstTyTuple (spec-substitute-type-list elems subs))]
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
    [(AstTyEnumArgs name lifetimes) (AstTyEnumArgs name lifetimes)]
    [(AstTyStructArgs name lifetimes) (AstTyStructArgs name lifetimes)]
    [(AstTyVarArgs name lifetimes)
      (match (spec-type-subst-lookup subs (intern-str name))
        [(SpecSomeString _) (spec-type-subst-type subs (intern-str name))]
        [(SpecNoString) (AstTyVarArgs name lifetimes)])]
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
    [(CtfeI64 n) (OkSpecSubExpr (ast-node-push (AstExprLiteral (AstLitInt n))))]
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
        (spec-diagnostic-at-expr
          origin
          "cannot substitute compile-time String value into runtime expression"))]
    [(CtfeUnit) (OkSpecSubExpr (ast-node-push (AstExprLiteral (AstLitUnit))))]
    [(CtfeType ty)
      (ErrSpecSubExpr
        (spec-diagnostic-at-expr
          origin
          (string-append
            "cannot substitute compile-time type value "
            (string-append (spec-type-key ty) " into runtime expression"))))]
    [(CtfeExpr _ _)
      (ErrSpecSubExpr
        (spec-diagnostic-at-expr
          origin
          "cannot substitute compile-time Expr value into runtime expression"))]
    [(CtfeExprList _)
      (ErrSpecSubExpr
        (spec-diagnostic-at-expr
          origin
          "cannot substitute compile-time ExprList value into runtime expression"))]
    [(CtfeExprClause _)
      (ErrSpecSubExpr
        (spec-diagnostic-at-expr
          origin
          "cannot substitute compile-time ExprClause value into runtime expression"))]
    [(CtfeExprClauseList _)
      (ErrSpecSubExpr
        (spec-diagnostic-at-expr
          origin
          "cannot substitute compile-time ExprClauseList value into runtime expression"))]))

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
            (compiler-diagnostic-at-start "" "specialize: arity mismatch"))])]
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
                    (match (compiler-ctfe-eval
                      arg
                      (spec-state-ctfe-env state)
                      (ctfe-fuel-limit))
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
                                (spec-diagnostic-at-expr
                                  arg
                                  (string-append
                                    "comptime argument '"
                                    (string-append
                                      (intern-str param-name)
                                      (string-append
                                        "' for function '"
                                        (string-append
                                          fn-name
                                          "' must be a type value such as `(type i64)`"))))))])
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
                              (spec-diagnostic-at-expr
                                arg
                                (string-append
                                  "comptime argument '"
                                  (string-append
                                    (intern-str param-name)
                                    (string-append
                                      "' for function '"
                                      (string-append
                                        fn-name
                                        (string-append
                                          "' has type "
                                          (string-append
                                            (spec-value-type-label value)
                                            (string-append
                                              ", expected "
                                              (spec-type-key param-ty))))))))))))]
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
              (compiler-diagnostic-at-start "" "specialize: arity mismatch"))]))]))

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
            (compiler-diagnostic-at-start "" "specialize: value mismatch"))])]
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
                              (compiler-diagnostic-at-start
                                ""
                                "specialize: expected type value"))])
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
                    (compiler-diagnostic-at-start
                      ""
                      "specialize: value mismatch"))])
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
        [(SpecState generated cache ctfe-env)
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
                                    (string-string-map-put
                                      cache
                                      key
                                      generated-name)
                                    ctfe-env)]
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
                                          rewritten-ctfe-env)
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
                                            rewritten-ctfe-env))])]
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
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (spec-rewrite-let-bindings bindings templates state)
          [(OkSpecLetBindingList rewritten-bindings binding-state)
            (match (spec-rewrite-expr
              body
              (spec-template-env-shadow-let-binding-names templates bindings)
              binding-state)
              [(OkSpecExpr rewritten-body body-state)
                (OkSpecExpr
                  (ast-expr-let rewritten-bindings rewritten-body)
                  body-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecLetBindingList diag) (ErrSpecExpr diag)]))]
    [(AstExprLambda params ret body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (spec-rewrite-expr
          body
          (spec-template-env-shadow-params templates params)
          state)
          [(OkSpecExpr rewritten-body body-state)
            (OkSpecExpr (ast-expr-lambda params ret rewritten-body) body-state)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
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
    [(AstExprMatch scrutinee-box arms)
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
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprForeach index index-ty start-box end-box body-box)
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
                  (spec-template-env-shadow-name templates (intern-str index))
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
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprSpmdReduce op index index-ty start-box end-box init-box value-box)
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
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
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
    [(AstExprWithResource bindings body)
      (OkSpecExpr (ast-node-push (AstExprWithResource bindings body)) state)]
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
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (spec-substitute-values-let-bindings bindings subs)
          [(OkSpecSubLetBindingList rewritten-bindings)
            (match (spec-substitute-values-expr
              body
              (spec-value-subst-remove-let-binding-names subs bindings))
              [(OkSpecSubExpr rewritten-body)
                (OkSpecSubExpr (ast-expr-let rewritten-bindings rewritten-body))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubLetBindingList diag) (ErrSpecSubExpr diag)]))]
    [(AstExprLambda params ret body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (spec-substitute-values-expr
          body
          (spec-value-subst-remove-params subs params))
          [(OkSpecSubExpr rewritten-body)
            (OkSpecSubExpr (ast-expr-lambda params ret rewritten-body))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
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
              (spec-diagnostic-at-expr
                expr
                (string-append
                  "cannot assign to comptime parameter '"
                  (string-append (intern-str name) "'"))))]
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
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (ast-node-get scrutinee-box)]
        (match (spec-substitute-values-expr scrutinee subs)
          [(OkSpecSubExpr rewritten-scrutinee)
            (match (spec-substitute-values-match-arms arms subs)
              [(OkSpecSubMatchArmList rewritten-arms)
                (OkSpecSubExpr
                  (ast-expr-match rewritten-scrutinee rewritten-arms))]
              [(ErrSpecSubMatchArmList diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprForeach index index-ty start-box end-box body-box)
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
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprSpmdReduce op index index-ty start-box end-box init-box value-box)
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
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
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
    [(AstExprWithResource bindings body)
      (OkSpecSubExpr (ast-node-push (AstExprWithResource bindings body)))]
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
            (spec-diagnostic-at-expr
              expr
              (string-append
                "cannot take address of comptime value parameter '"
                (string-append (intern-str name) "'"))))]
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
            (spec-diagnostic-at-expr
              expr
              (string-append
                "type-valued comptime parameter '"
                (string-append
                  (intern-str name)
                  "' cannot be used as a runtime value"))))]
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
    [(AstExprLambda params ret body-box)
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
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprForeach index index-ty start-box end-box body-box)
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
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprSpmdReduce op index index-ty start-box end-box init-box value-box)
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
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
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
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (spec-substitute-types-let-bindings bindings subs)
          [(OkSpecSubLetBindingList rewritten-bindings)
            (match (spec-substitute-types-expr
              body
              (spec-type-subst-remove-let-binding-names subs bindings))
              [(OkSpecSubExpr rewritten-body)
                (OkSpecSubExpr (ast-expr-let rewritten-bindings rewritten-body))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubLetBindingList diag) (ErrSpecSubExpr diag)]))]
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
              (spec-diagnostic-at-expr
                expr
                (string-append
                  "type-valued comptime parameter '"
                  (string-append (intern-str name) "' cannot be assigned"))))]
          [(SpecNoString)
            (match (spec-substitute-types-expr value subs)
              [(OkSpecSubExpr rewritten)
                (OkSpecSubExpr (ast-expr-set-id name rewritten))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (ast-node-get scrutinee-box)]
        (match (spec-substitute-types-expr scrutinee subs)
          [(OkSpecSubExpr rewritten-scrutinee)
            (match (spec-substitute-types-match-arms arms subs)
              [(OkSpecSubMatchArmList rewritten-arms)
                (OkSpecSubExpr
                  (ast-expr-match rewritten-scrutinee rewritten-arms))]
              [(ErrSpecSubMatchArmList diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
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
    [(AstExprWithResource bindings body)
      (OkSpecSubExpr (ast-node-push (AstExprWithResource bindings body)))]
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
            (spec-diagnostic-at-expr
              expr
              (string-append
                "type-valued comptime parameter '"
                (string-append
                  (intern-str name)
                  "' cannot be used as a runtime value"))))]
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

(define (compiler-specialize-program [program : AstProgram]) : ResultSpecProgram
  (match (gen-normalize-program program)
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
                    (string-string-map-with-capacity 64)
                    (ctfe-env-with-reflections
                      (ctfe-reflections-from-program normalized))))
                  [(OkSpecDecls rewritten state)
                    (match state
                      [(SpecState generated _ _)
                        (OkSpecProgram
                          (ast-program
                            (spec-decl-list-append rewritten generated)))])]
                  [(ErrSpecDecls diag) (ErrSpecProgram diag)])]))])]
    [(ErrGenProgram diag) (ErrSpecProgram diag)]))

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
                  (if (string-eq (intern-str fn-name) name)
                    true
                    (compiler-specialize-decl-list-defines? rest name))]
                [(AstDeclComptimeDecl _ template-box)
                  (let
                    [template : AstDecl (box-get template-box)]
                    (match template
                      [(AstDeclDefFn fn-name _ _ _ _)
                        (if (string-eq (intern-str fn-name) name)
                          true
                          (compiler-specialize-decl-list-defines? rest name))]
                      [_ (compiler-specialize-decl-list-defines? rest name)]))]
                [_ (compiler-specialize-decl-list-defines? rest name)]))]
          [(AstDeclDefFn fn-name _ _ _ _)
            (if (string-eq (intern-str fn-name) name)
              true
              (compiler-specialize-decl-list-defines? rest name))]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDeclDefFn fn-name _ _ _ _)
                  (if (string-eq (intern-str fn-name) name)
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
      (string-eq (spec-type-key (ast-ty-ptr (AstTyI64))) "ptr_i64")
      (string-eq
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
      (string-eq
        (spec-specialized-name "alloc" vals-i64)
        "__tl_specialized_alloc_type_i64_none")
      (string-eq
        (spec-specialized-name "alloc" vals-i64)
        (spec-specialized-name "alloc" vals-i64))
      (string-eq
        (spec-specialization-key "alloc" vals-i64)
        "alloc:type_i64_none")
      (not
        (string-eq
          (spec-specialized-name "alloc" vals-i64)
          (spec-specialized-name "alloc" vals-bool)))
      (string-eq
        (spec-specialized-name "pair" vals-multi)
        "__tl_specialized_pair_type_i64_i64_5_none")
      (string-eq (spec-value-key (CtfeI64 (- 0 3))) "i64_m3")
      (string-eq
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
                  (if (string-eq (intern-str fn-name) name)
                    (+ 1 (compiler-specialize-decl-list-count-defs rest name))
                    (compiler-specialize-decl-list-count-defs rest name))]
                [(AstDeclComptimeDecl _ template-box)
                  (let
                    [template : AstDecl (box-get template-box)]
                    (match template
                      [(AstDeclDefFn fn-name _ _ _ _)
                        (if (string-eq (intern-str fn-name) name)
                          (+
                            1
                            (compiler-specialize-decl-list-count-defs rest name))
                          (compiler-specialize-decl-list-count-defs rest name))]
                      [_ (compiler-specialize-decl-list-count-defs rest name)]))]
                [_ (compiler-specialize-decl-list-count-defs rest name)]))]
          [(AstDeclDefFn fn-name _ _ _ _)
            (if (string-eq (intern-str fn-name) name)
              (+ 1 (compiler-specialize-decl-list-count-defs rest name))
              (compiler-specialize-decl-list-count-defs rest name))]
          [(AstDeclComptimeDecl _ inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDeclDefFn fn-name _ _ _ _)
                  (if (string-eq (intern-str fn-name) name)
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
            (if (string-eq found name)
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
      (string-eq
        (spec-type-key (spec-substitute-type (AstTyVar (intern "T")) subs))
        "i64")
      (string-eq
        (spec-type-key
          (spec-substitute-type (ast-ty-ptr (AstTyVar (intern "T"))) subs))
        "ptr_i64")
      (string-eq
        (spec-type-key
          (spec-substitute-type (ast-ty-dyn-array (AstTyVar (intern "T"))) subs))
        "dynarray_i64")
      (string-eq
        (spec-type-key
          (spec-substitute-type
            (ast-ty-func
              (ast-type-cons (AstTyVar (intern "T")) AstTypeNil)
              (AstTyVar (intern "T")))
            subs))
        "fn_i64_nil_to_i64")
      (string-eq
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
                [(AstLitInt n) (= n 5)]
                [_ false])]
            [_ false])]
        [(ErrSpecSubExpr _) false])
      ;; unmapped variable y -> unchanged
      (match (spec-substitute-values-expr (AstExprVar (intern "y")) subs)
        [(OkSpecSubExpr e)
          (match (ast-node-get e)
            [(AstExprVar name) (string-eq (intern-str name) "y")]
            [_ false])]
        [(ErrSpecSubExpr _) false])
      ;; recursion through `if`: x in the condition becomes 5, unmapped y stays
      (match (spec-substitute-values-expr
        (AstExprIf
          (ast-node-push (AstExprVar (intern "x")))
          (ast-node-push (AstExprLiteral (AstLitInt 1)))
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
                        [(AstLitInt n) (= n 5)]
                        [_ false])]
                    [_ false])
                  (match else-branch
                    [(AstExprVar name) (string-eq (intern-str name) "y")]
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
          (AstExprLiteral (AstLitInt 1)))
        (spec-template-cons
          (SpecTemplate
            "second"
            AstParamNil
            (AstTyBool)
            (AstExprLiteral (AstLitBool true)))
          SpecTemplateNil))]
    [template-env : SpecTemplateEnv (spec-template-env-from-list templates)]
    [cache : StringStringMap
      (string-string-map-put
        (string-string-map-put
          (string-string-map-with-capacity 8)
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
            [(SpecTemplate name _ _ _) (string-eq name "second")])]
        [(SpecNoTemplate) false])
      (match (spec-cache-lookup cache "two")
        [(SpecSomeString name) (string-eq name "generated-two")]
        [(SpecNoString) false])
      (string-eq (spec-values-key values) "i64_1_bool_1_none")
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
  "(comptime-decl (:generated option-family Option_String \"String\")
  (defstruct Option_String (value String)))
(comptime-decl (:generated option-family Option_String \"String\")
  (defstruct Option_String (value String)))")

(define (compiler-generated-decl-function-reuse-source) : String
  "(comptime-decl (:generated function-family make-option-string \"String\")
  (define (make-option-string [value : String]) : String value))
(comptime-decl (:generated function-family make-option-string \"String\")
  (define (make-option-string [value : String]) : String value))")

(define (compiler-generated-decl-incompatible-source) : String
  "(comptime-decl (:generated option-family Option_String \"String\")
  (defstruct Option_String (value String)))
(comptime-decl (:generated option-family Option_String \"String\")
  (defstruct Option_String (value i64)))")

(define (compiler-generated-decl-item-mismatch-source) : String
  "(comptime-decl (:generated option-family Expected \"String\")
  (defstruct Actual (value String)))")

(define (compiler-generated-decl-non-string-key-source) : String
  "(comptime-decl (:generated option-family Option_String 7)
  (defstruct Option_String (value String)))")

(define (compiler-generated-decl-duplicate-visible-source) : String
  "(comptime-decl (:generated option-family Option_String \"String\")
  (defstruct Option_String (value String)))
(comptime-decl (:generated option-family Option_String \"Bytes\")
  (defstruct Option_String (value String)))")

(define (compiler-generated-option-result-family-source) : String
  "(defstruct Payload (value i64))
(defenum Status (StatusOk) (StatusBad i64))
(comptime-decl (:generated stdlib/option-family Option_String (type-key (type String)))
  (defenum Option_String
    (None_String)
    (Some_String String)))
(comptime-decl (:generated stdlib/option-family Option_String (type-key (type String)))
  (defenum Option_String
    (None_String)
    (Some_String String)))
(comptime-decl (:generated stdlib/option-family option-string-some? (type-key (type String)))
  (define (option-string-some? [value : Option_String]) : bool
    (match value
      [(Some_String _) true]
      [(None_String) false])))
(comptime-decl (:generated stdlib/result-family Result_I64_String (type-key (type i64)) (type-key (type String)))
  (defenum Result_I64_String
    (Ok_I64_String i64)
    (Err_I64_String String)))
(comptime-decl (:generated stdlib/result-family Result_I64_String (type-key (type i64)) (type-key (type String)))
  (defenum Result_I64_String
    (Ok_I64_String i64)
    (Err_I64_String String)))
(comptime-decl (:generated stdlib/result-family result-i64-string-value-or (type-key (type i64)) (type-key (type String)))
  (define (result-i64-string-value-or [value : Result_I64_String] [fallback : i64]) : i64
    (match value
      [(Ok_I64_String n) n]
      [(Err_I64_String _) fallback])))
(comptime-decl (:generated stdlib/result-family Result_Payload_Status (type-key (type Payload)) (type-key (type Status)))
  (defenum Result_Payload_Status
    (Ok_Payload_Status Payload)
    (Err_Payload_Status Status)))
(define (main) : i64
  (+ (if (option-string-some? (Some_String \"x\")) 1 0)
     (result-i64-string-value-or (Ok_I64_String 41) 0)))")

(define (compiler-generated-decl-bundle-source) : String
  "(comptime-decls (:generated bundle-family (type-key (type String)) \"v1\")
  (defstruct BundleBox (value String))
  (defenum BundleMaybe (BundleNone) (BundleSome String))
  (define (bundle-score [value : BundleMaybe]) : i64 1))
(comptime-decls (:generated bundle-family (type-key (type String)) \"v1\")
  (defstruct BundleBox (value String))
  (defenum BundleMaybe (BundleNone) (BundleSome String))
  (define (bundle-score [value : BundleMaybe]) : i64 1))")

(define (compiler-generated-decl-bundle-incompatible-source) : String
  "(comptime-decls (:generated bundle-family \"v1\")
  (defstruct BundleBox (value String)))
(comptime-decls (:generated bundle-family \"v1\")
  (defstruct BundleBox (value i64)))")

(define (compiler-generated-decl-bundle-cross-module-reuse-source) : String
  "(module bundle.family)
(comptime-decls (:generated bundle-family \"v1\")
  (defstruct BundleBox (value String))
  (defenum BundleMaybe (BundleNone) (BundleSome String)))
(module app)
(module bundle.family)
(comptime-decls (:generated bundle-family \"v1\")
  (defstruct BundleBox (value String))
  (defenum BundleMaybe (BundleNone) (BundleSome String)))")

(define (compiler-generated-decl-bundle-cross-module-distinct-source) : String
  "(module bundle.left)
(comptime-decls (:generated bundle-family \"v1\")
  (defstruct BundleBox (value String)))
(module bundle.right)
(comptime-decls (:generated bundle-family \"v1\")
  (defstruct BundleBox (value String)))")

(define (compiler-generated-decl-expected-string-key) : String
  (gen-full-key
    ""
    "option-family"
    "Option_String"
    (string-append (spec-string-key "String") "_none")))

(define (compiler-generated-decl-cross-module-reuse-source) : String
  "(module option.family)
(comptime-decl (:generated option-family Option_String \"String\")
  (defstruct Option_String (value String)))
(module app)
(module option.family)
(comptime-decl (:generated option-family Option_String \"String\")
  (defstruct Option_String (value String)))")

(define (compiler-generated-decl-cross-module-distinct-source) : String
  "(module option.left)
(comptime-decl (:generated option-family Option_String \"String\")
  (defstruct Option_String (value String)))
(module option.right)
(comptime-decl (:generated option-family Option_String \"String\")
  (defstruct Option_String (value String)))")

(define (compiler-generated-hashmap-descriptor-distinct-source) : String
  "(comptime-decl (:generated stdlib/hashmap-family HashMapSlot (type-key (type String)) (type-key (type String)) \"stdlib/hashmap/string-key-v1\")
  (defenum HashMapSlot (HashMapEmpty)))
(comptime-decl (:generated stdlib/hashmap-family HashMapSlot (type-key (type String)) (type-key (type String)) \"stdlib/hashmap/custom-key-v1\")
  (defenum HashMapSlot (HashMapEmpty)))")

(define (compiler-generated-hashmap-family-bundle-source) : String
  "(defstruct Payload (score i64))
(defenum Status (Ready i64) (Failed))
(defstruct HashPoint (x i64) (enabled bool) (label String) (code char))
(defenum HashTag (HashTagNone) (HashTagNumber i64) (HashTagOtherNumber i64) (HashTagText bool String char))
(defstruct HashNestedKey (point HashPoint) (tag HashTag))
(comptime-decl (:generated stdlib/hashmap-family StringStringMap (type-key (type String)) (type-key (type String)) \"stdlib/hashmap/string-key-v1\")
  (defstruct StringStringMap (__hashmap_family_request i64)))
(comptime-decl (:generated stdlib/hashmap-family I64I64Map (type-key (type i64)) (type-key (type i64)) \"stdlib/hashmap/i64-key-v1\")
  (defstruct I64I64Map (__hashmap_family_request i64)))
(comptime-decl (:generated stdlib/hashmap-family I64StringMap (type-key (type i64)) (type-key (type String)) \"stdlib/hashmap/i64-key-v1\")
  (defstruct I64StringMap (__hashmap_family_request i64)))
(comptime-decl (:generated stdlib/hashmap-family I64StringMap (type-key (type i64)) (type-key (type String)) \"stdlib/hashmap/i64-key-v1\")
  (defstruct I64StringMap (__hashmap_family_request i64)))
(comptime-decl (:generated stdlib/hashmap-family StringPayloadMap (type-key (type String)) (type-key (type Payload)) \"stdlib/hashmap/string-key-v1\")
  (defstruct StringPayloadMap (__hashmap_family_request i64)))
(comptime-decl (:generated stdlib/hashmap-family I64StatusMap (type-key (type i64)) (type-key (type Status)) \"stdlib/hashmap/i64-key-v1\")
  (defstruct I64StatusMap (__hashmap_family_request i64)))
(comptime-decl (:generated stdlib/hashmap-family HashNestedKeyI64Map (type-key (type HashNestedKey)) (type-key (type i64)) \"stdlib/hashmap/aggregate-key-v1\")
  (defstruct HashNestedKeyI64Map (__hashmap_family_request i64)))
(comptime-decl (:generated stdlib/hashmap-family StringPayloadMap (type-key (type String)) (type-key (type Payload)) \"stdlib/hashmap/string-key-v1\")
  (defstruct StringPayloadMap (__hashmap_family_request i64)))")

(define (compiler-generated-hashmap-family-unsupported-key-source) : String
  "(comptime-decl (:generated stdlib/hashmap-family BoolStringMap (type-key (type bool)) (type-key (type String)) \"stdlib/hashmap/i64-key-v1\")
  (defstruct BoolStringMap (__hashmap_family_request i64)))")

(define (compiler-generated-hashmap-family-unsupported-value-source) : String
  "(comptime-decl (:generated stdlib/hashmap-family StringBoolMap (type-key (type String)) (type-key (type bool)) \"stdlib/hashmap/string-key-v1\")
  (defstruct StringBoolMap (__hashmap_family_request i64)))")

(define (compiler-generated-hashmap-family-unsupported-aggregate-key-source) : String
  "(defstruct BadAggregateKey (score f64))
(comptime-decl (:generated stdlib/hashmap-family BadAggregateKeyI64Map (type-key (type BadAggregateKey)) (type-key (type i64)) \"stdlib/hashmap/aggregate-key-v1\")
  (defstruct BadAggregateKeyI64Map (__hashmap_family_request i64)))")

(define (compiler-generated-set-family-bundle-source) : String
  "(comptime-decl (:generated stdlib/set-family StringSet (type-key (type String)) \"stdlib/hashmap/string-key-v1\")
  (defstruct StringSet (__set_family_request i64)))
(comptime-decl (:generated stdlib/set-family I64Set (type-key (type i64)) \"stdlib/hashmap/i64-key-v1\")
  (defstruct I64Set (__set_family_request i64)))
(comptime-decl (:generated stdlib/set-family I64Set (type-key (type i64)) \"stdlib/hashmap/i64-key-v1\")
  (defstruct I64Set (__set_family_request i64)))")

(define (compiler-generated-set-family-unsupported-key-source) : String
  "(comptime-decl (:generated stdlib/set-family BoolSet (type-key (type bool)) \"stdlib/hashmap/i64-key-v1\")
  (defstruct BoolSet (__set_family_request i64)))")

(define (compiler-generated-json-derive-bundle-source) : String
  "(defstruct Address (zip i64) (city String))
(comptime-decl (:generated stdlib/json-derive AddressJson (type-key (type Address)))
  (defstruct AddressJson (__json_derive_request i64)))
(defstruct Person (name String) (age i32) (active bool) (home Address))
(comptime-decl (:generated stdlib/json-derive PersonJson (type-key (type Person)))
  (defstruct PersonJson (__json_derive_request i64)))
(comptime-decl (:generated stdlib/json-derive PersonJson (type-key (type Person)))
  (defstruct PersonJson (__json_derive_request i64)))")

(define (compiler-generated-json-derive-unsupported-source) : String
  "(defstruct BadPayload (score f64))
(comptime-decl (:generated stdlib/json-derive BadPayloadJson (type-key (type BadPayload)))
  (defstruct BadPayloadJson (__json_derive_request i64)))")

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
                      "Option_String")
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
                    "make-option-string")
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
          (match (compiler-diagnostic-notes diag)
            [(CompilerDiagnosticNoteCons note _)
              (string-eq
                note
                (string-append
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
                    "Option_String")
                  2))])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-generated-option-result-family-ok?) : bool
  (match (parse-ast-source (compiler-generated-option-result-family-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram normalized)
          (match normalized
            [(AstProgram decls-box)
              (let
                [decls : AstDeclList (box-get decls-box)]
                [option-count : i64
                  (compiler-specialize-decl-list-count-visible
                    decls
                    "Option_String")]
                [option-helper-count : i64
                  (compiler-specialize-decl-list-count-defs
                    decls
                    "option-string-some?")]
                [result-count : i64
                  (compiler-specialize-decl-list-count-visible
                    decls
                    "Result_I64_String")]
                [result-helper-count : i64
                  (compiler-specialize-decl-list-count-defs
                    decls
                    "result-i64-string-value-or")]
                [nominal-result-count : i64
                  (compiler-specialize-decl-list-count-visible
                    decls
                    "Result_Payload_Status")]
                (and
                  (= option-count 1)
                  (= option-helper-count 1)
                  (= result-count 1)
                  (= result-helper-count 1)
                  (= nominal-result-count 1)))])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-generated-decl-bundle-ok?) : bool
  (match (parse-ast-source (compiler-generated-decl-bundle-source))
    [(OkAstProgram program)
      (and
        (compiler-specialize-needed? program)
        (match (compiler-specialize-program program)
          [(OkSpecProgram normalized)
            (match normalized
              [(AstProgram decls-box)
                (let
                  [decls : AstDeclList (box-get decls-box)]
                  [box-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "BundleBox")]
                  [maybe-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "BundleMaybe")]
                  [score-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "bundle-score")]
                  (and (= box-count 1) (= maybe-count 1) (= score-count 1)))])]
          [(ErrSpecProgram _) false]))]
    [(ErrAstProgram _) false]))

(define (compiler-generated-decl-bundle-incompatible-rejected?) : bool
  (match (parse-ast-source (compiler-generated-decl-bundle-incompatible-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram _) false]
        [(ErrSpecProgram _) true])]
    [(ErrAstProgram _) false]))

(define (compiler-generated-decl-bundle-cross-module-reuse-ok?) : bool
  (=
    (compiler-generated-decl-visible-count
      (compiler-generated-decl-bundle-cross-module-reuse-source)
      "BundleBox")
    1))

(define (compiler-generated-decl-bundle-cross-module-distinct-ok?) : bool
  (=
    (compiler-generated-decl-visible-count
      (compiler-generated-decl-bundle-cross-module-distinct-source)
      "BundleBox")
    2))

(define (compiler-generated-decl-cross-module-reuse-ok?) : bool
  (=
    (compiler-generated-decl-visible-count
      (compiler-generated-decl-cross-module-reuse-source)
      "Option_String")
    1))

(define (compiler-generated-decl-cross-module-distinct-ok?) : bool
  (=
    (compiler-generated-decl-visible-count
      (compiler-generated-decl-cross-module-distinct-source)
      "Option_String")
    2))

(define (compiler-generated-hashmap-descriptor-distinct-ok?) : bool
  (=
    (compiler-generated-decl-visible-count
      (compiler-generated-hashmap-descriptor-distinct-source)
      "HashMapSlot")
    2))

(define (compiler-generated-hashmap-mask-source-ok?) : bool
  (let
    [string-source : String
      (gen-hashmap-source-string-key
        "StringStringMap"
        "string-string-map"
        "String")]
    [i64-source : String
      (gen-hashmap-source-i64-key "I64I64Map" "i64-i64-map" "i64")]
    [string-round-needle : String "string-string-map-round-capacity"]
    [i64-round-needle : String "i64-i64-map-round-capacity"]
    [mask-needle : String "(bit-and hash (- capacity 1))"]
    [modulo-needle : String "(% hash capacity)"]
    [string-mut-entry-needle : String "StringStringMapMutEntry"]
    [string-mut-entry-macro-needle : String
      "string-string-map-get-mut-entry-borrowed"]
    [i64-mut-entry-needle : String "I64I64MapMutEntry"]
    [i64-mut-entry-macro-needle : String "i64-i64-map-get-mut-entry"]
    [metadata-len-mutation-needle : String
      "(set!\n              (struct-get map len)"]
    [metadata-deleted-mutation-needle : String "(set! (struct-get map deleted)"]
    [metadata-slots-mutation-needle : String
      "(set! (struct-get map slots) dst)"]
    (and
      (string-contains (& string-source) (& string-round-needle))
      (string-contains (& i64-source) (& i64-round-needle))
      (string-contains (& string-source) (& mask-needle))
      (string-contains (& i64-source) (& mask-needle))
      (not (string-contains (& string-source) (& modulo-needle)))
      (not (string-contains (& i64-source) (& modulo-needle)))
      (string-contains (& string-source) (& string-mut-entry-needle))
      (string-contains (& string-source) (& string-mut-entry-macro-needle))
      (string-contains (& i64-source) (& i64-mut-entry-needle))
      (string-contains (& i64-source) (& i64-mut-entry-macro-needle))
      (string-contains (& string-source) (& metadata-len-mutation-needle))
      (string-contains (& i64-source) (& metadata-len-mutation-needle))
      (string-contains (& string-source) (& metadata-deleted-mutation-needle))
      (string-contains (& i64-source) (& metadata-deleted-mutation-needle))
      (string-contains (& string-source) (& metadata-slots-mutation-needle))
      (string-contains (& i64-source) (& metadata-slots-mutation-needle)))))

(define (compiler-generated-hashmap-family-bundle-ok?) : bool
  (match (parse-ast-source (compiler-generated-hashmap-family-bundle-source))
    [(OkAstProgram program)
      (and
        (compiler-specialize-needed? program)
        (match (compiler-specialize-program program)
          [(OkSpecProgram normalized)
            (match normalized
              [(AstProgram decls-box)
                (let
                  [decls : AstDeclList (box-get decls-box)]
                  [slot-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "I64StringMapSlot")]
                  [map-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "I64StringMap")]
                  [entry-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "I64StringMapEntry")]
                  [mut-entry-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "I64StringMapMutEntry")]
                  [len-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "i64-string-map-len")]
                  [put-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "i64-string-map-put")]
                  [i64-string-borrowed-value-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "i64-string-map-get-value-borrowed")]
                  [string-map-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "StringStringMap")]
                  [string-mut-entry-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "StringStringMapMutEntry")]
                  [string-borrowed-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "string-string-map-get-borrowed")]
                  [string-borrowed-value-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "string-string-map-get-value-borrowed")]
                  [string-round-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "string-string-map-round-capacity")]
                  [i64-map-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "I64I64Map")]
                  [i64-mut-entry-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "I64I64MapMutEntry")]
                  [i64-put-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "i64-i64-map-put")]
                  [i64-borrowed-value-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "i64-i64-map-get-value-borrowed")]
                  [i64-round-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "i64-i64-map-round-capacity")]
                  [i64-string-round-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "i64-string-map-round-capacity")]
                  [string-payload-map-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "StringPayloadMap")]
                  [string-payload-borrowed-value-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "string-payload-map-get-value-borrowed")]
                  [i64-status-map-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "I64StatusMap")]
                  [i64-status-put-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "i64-status-map-put")]
                  [hash-nested-key-map-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "HashNestedKeyI64Map")]
                  [hash-nested-key-put-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "hash-nested-key-i64-map-put")]
                  [hash-nested-key-hash-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "hash-nested-key-i64-map-hash-key")]
                  [hash-nested-key-eq-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "hash-nested-key-i64-map-key-eq?")]
                  [ok : bool true]
                  (begin
                    (if (= slot-count 1)
                      unit
                      (set! ok false))
                    (if (= map-count 1)
                      unit
                      (set! ok false))
                    (if (= entry-count 1)
                      unit
                      (set! ok false))
                    (if (= mut-entry-count 1)
                      unit
                      (set! ok false))
                    (if (= len-count 1)
                      unit
                      (set! ok false))
                    (if (= put-count 1)
                      unit
                      (set! ok false))
                    (if (= i64-string-borrowed-value-count 1)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "i64-string-map-update-if-present")
                      1)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "i64-string-map-insert-or-update")
                      1)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "i64-string-map-entry-or-insert")
                      1)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "i64-string-map-mut-entry-set!")
                      1)
                      unit
                      (set! ok false))
                    (if (= string-map-count 1)
                      unit
                      (set! ok false))
                    (if (= string-mut-entry-count 1)
                      unit
                      (set! ok false))
                    (if (= string-borrowed-count 1)
                      unit
                      (set! ok false))
                    (if (= string-borrowed-value-count 1)
                      unit
                      (set! ok false))
                    (if (= string-round-count 1)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "string-string-map-update-borrowed-if-present")
                      1)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "string-string-map-insert-or-update")
                      1)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "string-string-map-entry-or-insert")
                      1)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "string-string-map-mut-entry-set!")
                      1)
                      unit
                      (set! ok false))
                    (if (= i64-map-count 1)
                      unit
                      (set! ok false))
                    (if (= i64-mut-entry-count 1)
                      unit
                      (set! ok false))
                    (if (= i64-put-count 1)
                      unit
                      (set! ok false))
                    (if (= i64-borrowed-value-count 1)
                      unit
                      (set! ok false))
                    (if (= i64-round-count 1)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "i64-i64-map-update-if-present")
                      1)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "i64-i64-map-insert-or-update")
                      1)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "i64-i64-map-entry-or-insert")
                      1)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "i64-i64-map-mut-entry-set!")
                      1)
                      unit
                      (set! ok false))
                    (if (= i64-string-round-count 1)
                      unit
                      (set! ok false))
                    (if (= string-payload-map-count 1)
                      unit
                      (set! ok false))
                    (if (= string-payload-borrowed-value-count 1)
                      unit
                      (set! ok false))
                    (if (= i64-status-map-count 1)
                      unit
                      (set! ok false))
                    (if (= i64-status-put-count 1)
                      unit
                      (set! ok false))
                    (if (= hash-nested-key-map-count 1)
                      unit
                      (set! ok false))
                    (if (= hash-nested-key-put-count 1)
                      unit
                      (set! ok false))
                    (if (= hash-nested-key-hash-count 1)
                      unit
                      (set! ok false))
                    (if (= hash-nested-key-eq-count 1)
                      unit
                      (set! ok false))
                    ok))])]
          [(ErrSpecProgram _) false]))]
    [(ErrAstProgram _) false]))

(define (compiler-generated-hashmap-family-unsupported-key-rejected?) : bool
  (match (parse-ast-source
    (compiler-generated-hashmap-family-unsupported-key-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram _) false]
        [(ErrSpecProgram diag)
          (string-eq
            (compiler-diagnostic-message diag)
            "hashmap-family: unsupported key descriptor stdlib/hashmap/i64-key-v1 for key type bool")])]
    [(ErrAstProgram _) false]))

(define (compiler-generated-hashmap-family-unsupported-value-rejected?) : bool
  (match (parse-ast-source
    (compiler-generated-hashmap-family-unsupported-value-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram _) false]
        [(ErrSpecProgram diag)
          (string-eq
            (compiler-diagnostic-message diag)
            "hashmap-family: unsupported value type bool")])]
    [(ErrAstProgram _) false]))

(define (compiler-generated-hashmap-family-unsupported-aggregate-key-rejected?) : bool
  (match (parse-ast-source
    (compiler-generated-hashmap-family-unsupported-aggregate-key-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram _) false]
        [(ErrSpecProgram diag)
          (string-eq
            (compiler-diagnostic-message diag)
            "hashmap-family: unsupported aggregate key member BadAggregateKey.score type f64")])]
    [(ErrAstProgram _) false]))

(define (compiler-generated-set-family-bundle-ok?) : bool
  (match (parse-ast-source (compiler-generated-set-family-bundle-source))
    [(OkAstProgram program)
      (and
        (compiler-specialize-needed? program)
        (match (compiler-specialize-program program)
          [(OkSpecProgram normalized)
            (match normalized
              [(AstProgram decls-box)
                (let
                  [decls : AstDeclList (box-get decls-box)]
                  [string-set-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "StringSet")]
                  [string-entry-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "StringSetEntry")]
                  [string-insert-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "string-set-insert")]
                  [string-borrowed-remove-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "string-set-remove-borrowed")]
                  [i64-set-count : i64
                    (compiler-specialize-decl-list-count-visible decls "I64Set")]
                  [i64-entry-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "I64SetEntry")]
                  [i64-insert-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "i64-set-insert")]
                  [i64-remove-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "i64-set-remove")]
                  (and
                    (= string-set-count 1)
                    (= string-entry-count 1)
                    (= string-insert-count 1)
                    (= string-borrowed-remove-count 1)
                    (= i64-set-count 1)
                    (= i64-entry-count 1)
                    (= i64-insert-count 1)
                    (= i64-remove-count 1)))])]
          [(ErrSpecProgram _) false]))]
    [(ErrAstProgram _) false]))

(define (compiler-generated-set-family-unsupported-key-rejected?) : bool
  (match (parse-ast-source
    (compiler-generated-set-family-unsupported-key-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram _) false]
        [(ErrSpecProgram diag)
          (string-eq
            (compiler-diagnostic-message diag)
            "set-family: unsupported key type bool")])]
    [(ErrAstProgram _) false]))

(define (compiler-generated-json-derive-bundle-ok?) : bool
  (match (parse-ast-source (compiler-generated-json-derive-bundle-source))
    [(OkAstProgram program)
      (and
        (compiler-specialize-needed? program)
        (match (compiler-specialize-program program)
          [(OkSpecProgram normalized)
            (match normalized
              [(AstProgram decls-box)
                (let
                  [decls : AstDeclList (box-get decls-box)]
                  (and
                    (=
                      (compiler-specialize-decl-list-count-visible
                        decls
                        "AddressJsonResult")
                      1)
                    (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "address-to-json")
                      1)
                    (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "address-from-json")
                      1)
                    (=
                      (compiler-specialize-decl-list-count-visible
                        decls
                        "PersonJsonResult")
                      1)
                    (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "person-to-json")
                      1)
                    (=
                      (compiler-specialize-decl-list-count-defs
                        decls
                        "person-from-json")
                      1)))])]
          [(ErrSpecProgram _) false]))]
    [(ErrAstProgram _) false]))

(define (compiler-generated-json-derive-unsupported-rejected?) : bool
  (match (parse-ast-source (compiler-generated-json-derive-unsupported-source))
    [(OkAstProgram program)
      (match (compiler-specialize-program program)
        [(OkSpecProgram _) false]
        [(ErrSpecProgram diag)
          (string-eq
            (compiler-diagnostic-message diag)
            "json-derive: unsupported field score type f64")])]
    [(ErrAstProgram _) false]))

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
                              (string-eq generator "option-family")
                              (string-eq item "Option_String")
                              (string-eq
                                key
                                (compiler-generated-decl-expected-string-key)))]
                          [(AstNoGeneratedDeclMeta) false])
                        (match (box-get template-box)
                          [(AstDeclDefStruct name _ _ _)
                            (string-eq (intern-str name) "Option_String")]
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
    (unless (compiler-generated-option-result-family-ok?) (return 0))
    (unless (compiler-generated-decl-bundle-ok?) (return 0))
    (unless (compiler-generated-decl-bundle-incompatible-rejected?) (return 0))
    (unless (compiler-generated-decl-bundle-cross-module-reuse-ok?) (return 0))
    (unless
      (compiler-generated-decl-bundle-cross-module-distinct-ok?)
      (return 0))
    (unless (compiler-generated-decl-cross-module-reuse-ok?) (return 0))
    (unless (compiler-generated-decl-cross-module-distinct-ok?) (return 0))
    (unless (compiler-generated-hashmap-descriptor-distinct-ok?) (return 0))
    (unless (compiler-generated-hashmap-mask-source-ok?) (return 0))
    (unless (compiler-generated-hashmap-family-bundle-ok?) (return 0))
    (unless
      (compiler-generated-hashmap-family-unsupported-key-rejected?)
      (return 0))
    (unless
      (compiler-generated-hashmap-family-unsupported-value-rejected?)
      (return 0))
    (unless
      (compiler-generated-hashmap-family-unsupported-aggregate-key-rejected?)
      (return 0))
    (unless (compiler-generated-set-family-bundle-ok?) (return 0))
    (unless
      (compiler-generated-set-family-unsupported-key-rejected?)
      (return 0))
    (unless (compiler-generated-json-derive-bundle-ok?) (return 0))
    (unless (compiler-generated-json-derive-unsupported-rejected?) (return 0))
    (unless (compiler-generated-decl-origin-preserved-ok?) (return 0))
    (unless (compiler-generated-registry-map-ok?) (return 0))
    1))