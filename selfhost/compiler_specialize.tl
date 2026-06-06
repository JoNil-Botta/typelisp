;; compiler_specialize.tl - Selfhost comptime function specialization (#832).
(import "../stdlib/io.tl")

(import "../stdlib/text_buf.tl")

(import "compiler_ctfe.tl")

(import "compiler_diagnostic.tl")

(import "compiler_parse_core.tl")

(defenum SpecTemplate
  (SpecTemplate String AstParamList AstType AstExpr))

(defenum SpecTemplateList
  (SpecTemplateNil)
  (SpecTemplateCons SpecTemplate (Box SpecTemplateList)))

(defenum SpecCache
  (SpecCacheNil)
  (SpecCacheCons String String (Box SpecCache)))

(defenum SpecState
  (SpecState AstDeclList SpecCache CtfeEnv))

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

(define (spec-cache-cons [key : String] [name : String] [rest : SpecCache]) : SpecCache
  (SpecCacheCons key name (box rest)))

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

(defenum SpecMaybeTemplate
  (SpecNoTemplate)
  (SpecSomeTemplate SpecTemplate))

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
  (OkSpecExpr AstExpr SpecState)
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
  (OkSpecSubExpr AstExpr)
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

(defenum GenRegistry
  (GenRegistryNil)
  (GenRegistryCons String AstDecl (Box GenRegistry)))

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
    [(AstParam name _ _) name]))

(define (spec-param-type [param : AstParam]) : AstType
  (match param
    [(AstParam _ ty _) ty]))

(define (spec-state-ctfe-env [state : SpecState]) : CtfeEnv
  (match state
    [(SpecState _ _ env) env]))

(define (spec-type-kind? [ty : AstType]) : bool
  (match ty
    [(AstTyVar name) (string-eq name "type")]
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

(define (spec-template-lookup [templates : SpecTemplateList] [name : String]) : SpecMaybeTemplate
  (match templates
    [(SpecTemplateNil) (SpecNoTemplate)]
    [(SpecTemplateCons template rest)
      (match template
        [(SpecTemplate template-name _ _ _)
          (if (string-eq template-name name)
            (SpecSomeTemplate template)
            (spec-template-lookup (box-get rest) name))])]))

(define (spec-template-list-remove-name
  [templates : SpecTemplateList]
  [name : String]) : SpecTemplateList
  (match templates
    [(SpecTemplateNil) (SpecTemplateNil)]
    [(SpecTemplateCons template rest)
      (match template
        [(SpecTemplate template-name _ _ _)
          (if (string-eq template-name name)
            (spec-template-list-remove-name (box-get rest) name)
            (spec-template-cons
              template
              (spec-template-list-remove-name (box-get rest) name)))])]))

(define (spec-template-list-remove-params
  [templates : SpecTemplateList]
  [params : AstParamList]) : SpecTemplateList
  (match params
    [(AstParamNil) templates]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (spec-template-list-remove-params
          (spec-template-list-remove-name templates (spec-param-name param))
          rest))]))

(define (spec-template-list-remove-let-binding-names
  [templates : SpecTemplateList]
  [bindings : AstLetBindingList]) : SpecTemplateList
  (match bindings
    [(AstLetBindingNil) templates]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name _ _)
            (spec-template-list-remove-let-binding-names
              (spec-template-list-remove-name templates name)
              rest)]))]))

(define (spec-template-list-remove-pattern
  [templates : SpecTemplateList]
  [pattern : AstPattern]) : SpecTemplateList
  (match pattern
    [(AstPatVar name _) (spec-template-list-remove-name templates name)]
    [(AstPatTuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-template-list-remove-pattern-list templates patterns))]
    [(AstPatWildcard) templates]
    [(AstPatBinding name) (spec-template-list-remove-name templates name)]
    [(AstPatVariant _ patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-template-list-remove-pattern-list templates patterns))]
    [(AstPatLiteral _) templates]))

(define (spec-template-list-remove-pattern-list
  [templates : SpecTemplateList]
  [patterns : AstPatternList]) : SpecTemplateList
  (match patterns
    [(AstPatternNil) templates]
    [(AstPatternCons pattern rest)
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest : AstPatternList (box-get rest)]
        (spec-template-list-remove-pattern-list
          (spec-template-list-remove-pattern templates pattern)
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
                [(AstDeclDefFn name params ret body-box)
                  (let
                    [body : AstExpr (box-get body-box)]
                    (if (spec-param-list-has-comptime? params)
                      (spec-template-cons
                        (SpecTemplate name params ret body)
                        (spec-collect-templates rest))
                      (spec-collect-templates rest)))]
                [_ (spec-collect-templates rest)]))]
          [(AstDeclDefFn name params ret body-box)
            (let
              [body : AstExpr (box-get body-box)]
              (if (spec-param-list-has-comptime? params)
                (spec-template-cons
                  (SpecTemplate name params ret body)
                  (spec-collect-templates rest))
                (spec-collect-templates rest)))]
          [_ (spec-collect-templates rest)]))]))

(define (spec-cache-lookup [cache : SpecCache] [key : String]) : SpecMaybeString
  (match cache
    [(SpecCacheNil) (SpecNoString)]
    [(SpecCacheCons cached-key name rest)
      (if (string-eq cached-key key)
        (SpecSomeString name)
        (spec-cache-lookup (box-get rest) key))]))

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
        [head : AstType (box-get head)]
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
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyExpr) "Expr"]
    [(AstTyExprList) "ExprList"]
    [(AstTyFunc args ret)
      (string-append
        "fn_"
        (string-append
          (spec-type-list-key args)
          (string-append "_to_" (spec-type-key (box-get ret)))))]
    [(AstTyTuple elems) (string-append "tuple_" (spec-type-list-key elems))]
    [(AstTyArray elem count)
      (string-append
        "array_"
        (string-append
          (spec-type-key (box-get elem))
          (string-append "_" (spec-int-key count))))]
    [(AstTyDynArray elem)
      (string-append "dynarray_" (spec-type-key (box-get elem)))]
    [(AstTyBox elem) (string-append "box_" (spec-type-key (box-get elem)))]
    [(AstTyPtr elem) (string-append "ptr_" (spec-type-key (box-get elem)))]
    [(AstTyMutPtr elem)
      (string-append "mutptr_" (spec-type-key (box-get elem)))]
    [(AstTyRef region inner)
      (string-append
        "ref_"
        (string-append
          region
          (string-append "_" (spec-type-key (box-get inner)))))]
    [(AstTyMutRef region inner)
      (string-append
        "mutref_"
        (string-append
          region
          (string-append "_" (spec-type-key (box-get inner)))))]
    [(AstTyRegion region inner)
      (string-append
        "region_"
        (string-append
          region
          (string-append "_" (spec-type-key (box-get inner)))))]
    [(AstTyEnum name) (string-append "enum_" name)]
    [(AstTyEnumArgs name lifetimes)
      (string-append
        "enumargs_"
        (string-append
          name
          (string-append "_" (spec-lifetime-list-key lifetimes))))]
    [(AstTyStruct name) (string-append "struct_" name)]
    [(AstTyStructArgs name lifetimes)
      (string-append
        "structargs_"
        (string-append
          name
          (string-append "_" (spec-lifetime-list-key lifetimes))))]
    [(AstTyVar name) (string-append "var_" name)]
    [(AstTyVarArgs name lifetimes)
      (string-append
        "varargs_"
        (string-append
          name
          (string-append "_" (spec-lifetime-list-key lifetimes))))]))

(define (spec-value-key [value : CompilerCtfeValue]) : String
  (match value
    [(CtfeI64 n) (string-append "i64_" (spec-int-key n))]
    [(CtfeBool b)
      (if b
        "bool_1"
        "bool_0")]
    [(CtfeChar c) (string-append "char_" (int->string (cast c : i64)))]
    [(CtfeString text) (spec-string-key text)]
    [(CtfeUnit) "unit"]
    [(CtfeType ty) (string-append "type_" (spec-type-key ty))]
    [(CtfeExpr _ _) "Expr"]
    [(CtfeExprList _) "expr-list"]))

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

(define (gen-registry-cons [key : String] [decl : AstDecl] [rest : GenRegistry]) : GenRegistry
  (GenRegistryCons key decl (box rest)))

(define (gen-registry-lookup [registry : GenRegistry] [key : String]) : GenMaybeEntry
  (match registry
    [(GenRegistryNil) (GenNoEntry)]
    [(GenRegistryCons cached-key decl rest)
      (if (string-eq cached-key key)
        (GenSomeEntry decl)
        (gen-registry-lookup (box-get rest) key))]))

(define (gen-decl-visible-name [decl : AstDecl]) : SpecMaybeString
  (match decl
    [(AstDeclDef name _ _) (SpecSomeString name)]
    [(AstDeclDefFn name _ _ _) (SpecSomeString name)]
    [(AstDeclDefEnum name _) (SpecSomeString name)]
    [(AstDeclDefEnumLifetimes name _ _) (SpecSomeString name)]
    [(AstDeclDefStruct name _ _ _) (SpecSomeString name)]
    [(AstDeclDefStructLifetimes name _ _ _ _) (SpecSomeString name)]
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
            (string-eq a-name b-name)
            (and (ctfe-type-eq a-ty b-ty) (= a-comptime b-comptime)))])]))

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

(define (gen-field-cleanup-eq? [a : AstFieldCleanup] [b : AstFieldCleanup]) : bool
  (match a
    [(AstFieldNoCleanup)
      (match b
        [(AstFieldNoCleanup) true]
        [_ false])]
    [(AstFieldCleanupFn a-name)
      (match b
        [(AstFieldCleanupFn b-name) (string-eq a-name b-name)]
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
            (string-eq a-name b-name)
            (and
              (ctfe-type-eq a-ty b-ty)
              (gen-field-cleanup-eq? a-cleanup b-cleanup)))])]))

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
        [(AstStructCleanupFn b-name) (string-eq a-name b-name)]
        [_ false])]))

(define (gen-variant-def-eq? [a : AstVariantDef] [b : AstVariantDef]) : bool
  (match a
    [(AstVariantDef a-name a-payloads)
      (match b
        [(AstVariantDef b-name b-payloads)
          (and
            (string-eq a-name b-name)
            (ctfe-type-list-eq a-payloads b-payloads))])]))

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

(define (gen-decl-eq? [a : AstDecl] [b : AstDecl]) : bool
  (match a
    [(AstDeclDef a-name a-ty a-value-box)
      (let
        [a-value : AstExpr (box-get a-value-box)]
        (match b
          [(AstDeclDef b-name b-ty b-value-box)
            (let
              [b-value : AstExpr (box-get b-value-box)]
              (and
                (string-eq a-name b-name)
                (and
                  (gen-maybe-type-eq? a-ty b-ty)
                  (gen-expr-eq? a-value b-value))))]
          [_ false]))]
    [(AstDeclDefFn a-name a-params a-ret a-body-box)
      (let
        [a-body : AstExpr (box-get a-body-box)]
        (match b
          [(AstDeclDefFn b-name b-params b-ret b-body-box)
            (let
              [b-body : AstExpr (box-get b-body-box)]
              (and
                (string-eq a-name b-name)
                (and
                  (gen-param-list-eq? a-params b-params)
                  (and (ctfe-type-eq a-ret b-ret) (gen-expr-eq? a-body b-body)))))]
          [_ false]))]
    [(AstDeclDefEnum a-name a-variants)
      (match b
        [(AstDeclDefEnum b-name b-variants)
          (and
            (string-eq a-name b-name)
            (gen-variant-list-eq? a-variants b-variants))]
        [_ false])]
    [(AstDeclDefEnumLifetimes a-name a-lifetimes a-variants)
      (match b
        [(AstDeclDefEnumLifetimes b-name b-lifetimes b-variants)
          (and
            (string-eq a-name b-name)
            (and
              (ctfe-lifetime-list-eq a-lifetimes b-lifetimes)
              (gen-variant-list-eq? a-variants b-variants)))]
        [_ false])]
    [(AstDeclDefStruct a-name a-repr a-cleanup a-fields)
      (match b
        [(AstDeclDefStruct b-name b-repr b-cleanup b-fields)
          (and
            (string-eq a-name b-name)
            (and
              (gen-struct-repr-eq? a-repr b-repr)
              (and
                (gen-struct-cleanup-eq? a-cleanup b-cleanup)
                (gen-field-list-eq? a-fields b-fields))))]
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
            (string-eq a-name b-name)
            (and
              (ctfe-lifetime-list-eq a-lifetimes b-lifetimes)
              (and
                (gen-struct-repr-eq? a-repr b-repr)
                (and
                  (gen-struct-cleanup-eq? a-cleanup b-cleanup)
                  (gen-field-list-eq? a-fields b-fields)))))]
        [_ false])]
    [(AstDeclComptimeDecl _ a-inner-box)
      (let
        [a-inner : AstDecl (box-get a-inner-box)]
        (match b
          [(AstDeclComptimeDecl _ b-inner-box)
            (gen-decl-eq? a-inner (box-get b-inner-box))]
          [_ (gen-decl-eq? a-inner b)]))]
    [_ false]))

(define (gen-key-exprs [exprs : AstExprList] [env : CtfeEnv] [fuel : i64]) : ResultGenKey
  (match exprs
    [(AstExprNil) (OkGenKey "none" fuel)]
    [(AstExprCons head rest)
      (let
        [head-expr : AstExpr (box-get head)]
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

(defenum GenHashmapArgs
  (GenHashmapArgs String String String))

(defenum ResultGenHashmapArgs
  (OkGenHashmapArgs GenHashmapArgs)
  (ErrGenHashmapArgs CompilerDiagnostic))

(defenum ResultGenHashmapSource
  (OkGenHashmapSource String)
  (ErrGenHashmapSource CompilerDiagnostic))

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
                    [key-expr : AstExpr (box-get key-expr-box)]
                    [value-expr : AstExpr (box-get value-expr-box)]
                    [descriptor-expr : AstExpr (box-get descriptor-expr-box)]
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

(define (gen-hashmap-type-info [type-key : String] [role : String]) : ResultGenHashmapTypeInfo
  (if (string-eq type-key "String")
    (OkGenHashmapTypeInfo (GenHashmapTypeInfo "String" "String" "string"))
    (if (string-eq type-key "i64")
      (OkGenHashmapTypeInfo (GenHashmapTypeInfo "i64" "I64" "i64"))
      (ErrGenHashmapTypeInfo
        (gen-hashmap-diag
          (string-append
            "hashmap-family: unsupported "
            (string-append role (string-append " type " type-key))))))))

(define (gen-hashmap-family-marker-fields? [fields : AstFieldDefList]) : bool
  (match fields
    [(AstFieldDefCons field rest-box)
      (match field
        [(AstFieldDef name ty cleanup)
          (and
            (string-eq name "__hashmap_family_request")
            (and
              (ctfe-type-eq ty (AstTyI64))
              (and
                (match cleanup
                  [(AstFieldNoCleanup) true]
                  [_ false])
                (match (box-get rest-box)
                  [(AstFieldDefNil) true]
                  [_ false]))))])]
    [_ false]))

(define (gen-hashmap-family-marker-name [decl : AstDecl]) : SpecMaybeString
  (match decl
    [(AstDeclDefStruct name repr cleanup fields)
      (match repr
        [(AstStructReprDefault)
          (match cleanup
            [(AstStructNoCleanup)
              (if (gen-hashmap-family-marker-fields? fields)
                (SpecSomeString name)
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
    [insert-result : String (string-append map-name "InsertResult")]
    [insert-ok : String (string-append map-name "InsertOk")]
    [insert-full : String (string-append map-name "InsertFull")]
    [remove-result : String (string-append map-name "RemoveResult")]
    [remove-ok : String (string-append map-name "RemoveOk")]
    [remove-missing : String (string-append map-name "RemoveMissing")]
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
          "-bucket-index [hash : i64] [capacity : i64]) : i64\n"))
      (set!
        buf
        (gen-tb3 buf "  (% (" prefix "-hash-normalize hash) capacity))\n"))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-next-index [index : i64] [capacity : i64]) : i64\n"))
      (set! buf (gen-tb2 buf "  (% (+ index 1) capacity))\n" ""))
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
          "  (let\n    [left-len : i64 (string-length left)]\n    [right-len : i64 (string-length right)]\n    (if (not (= left-len right-len))\n      false\n      (let\n        [i : i64 0]\n        [same : bool true]\n        (begin\n          (while (and same (< i left-len))\n            (if (= (cast (string-ref left i) : i64) (cast (string-ref right i) : i64))\n              (set! i (+ i 1))\n              (set! same false)))\n          same)))))\n"
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
      (set! buf (gen-tb2 buf probe "\n  (if (>= steps capacity)\n"))
      (set!
        buf
        (gen-tb5
          buf
          "    (if (>= first-tombstone 0)\n      ("
          probe-absent
          " first-tombstone)\n      ("
          probe-full
          "))\n"))
      (set! buf (gen-tb2 buf "    (match (array-ref slots index)\n      [(" ""))
      (set! buf (gen-tb5 buf empty ")\n        (" probe-absent " (" prefix))
      (set!
        buf
        (gen-tb3
          buf
          "-insert-slot first-tombstone index))]\n      [("
          tombstone
          ")\n"))
      (set! buf (gen-tb3 buf "        (" prefix "-probe-borrowed-from\n"))
      (set!
        buf
        (gen-tb3
          buf
          "          slots\n          capacity\n          key\n          hash\n          ("
          prefix
          "-next-index index capacity)\n"))
      (set!
        buf
        (gen-tb2
          buf
          "          (+ steps 1)\n          (if (>= first-tombstone 0)\n            first-tombstone\n            index))]\n      [("
          ""))
      (set!
        buf
        (gen-tb4
          buf
          occupied
          " slot-key _ slot-hash)\n        (if (if (= slot-hash hash)\n          ("
          prefix
          "-key-eq? (& slot-key) key)\n"))
      (set!
        buf
        (gen-tb5
          buf
          "          false)\n          ("
          probe-found
          " index)\n          ("
          prefix
          "-probe-borrowed-from\n"))
      (set!
        buf
        (gen-tb3
          buf
          "            slots\n            capacity\n            key\n            hash\n            ("
          prefix
          "-next-index index capacity)\n"))
      (set!
        buf
        (gen-tb2
          buf
          "            (+ steps 1)\n            first-tombstone))])))\n"
          ""))
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
          "-bucket-index hash capacity)\n"))
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
        (gen-tb6
          buf
          " "
          value-type
          "))\n(defenum "
          insert-result
          "\n  ("
          insert-ok))
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
      (set! buf (gen-tb5 buf ")\n  (" remove-missing " " map-name "))\n"))
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
      (set! buf (gen-tb2 buf map-name "\n  (let\n    [slots : (Array "))
      (set! buf (gen-tb4 buf slot ") (make-array " slot " capacity)]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "    (begin\n      ("
          prefix
          "-fill-empty slots 0 capacity)\n      ("
          map-name))
      (set! buf (gen-tb2 buf " slots 0 0))))\n" ""))
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
          " key value hash))\n            ("
          insert-ok))
      (set!
        buf
        (gen-tb5
          buf
          "\n              ("
          map-name
          "\n                slots\n                (+ ("
          prefix
          "-len map) 1)\n"))
      (set!
        buf
        (gen-tb4
          buf
          "                (if reused-tombstone\n                  (- ("
          prefix
          "-deleted map) 1)\n                  ("
          prefix))
      (set!
        buf
        (gen-tb5
          buf
          "-deleted map))))))]\n      [("
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
        (gen-tb4 buf "))\n          (" remove-ok "\n            (" map-name))
      (set!
        buf
        (gen-tb4
          buf
          "\n              slots\n              (- ("
          prefix
          "-len map) 1)\n              (+ ("
          prefix))
      (set!
        buf
        (gen-tb5
          buf
          "-deleted map) 1))))]\n      [("
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
          " key value hash)\n          (match ("
          prefix
          "-probe-borrowed dst dst-capacity (& key) hash)\n"))
      (set!
        buf
        (gen-tb5
          buf
          "            [("
          probe-absent
          " slot)\n              (array-set! dst slot ("
          occupied
          " key value hash))]\n"))
      (set!
        buf
        (gen-tb5
          buf
          "            [("
          probe-found
          " slot)\n              (array-set! dst slot ("
          occupied
          " key value hash))]\n"))
      (set!
        buf
        (gen-tb5
          buf
          "            [("
          probe-full
          ") unit])]\n        [("
          empty
          ") unit]\n        [("))
      (set! buf (gen-tb3 buf tombstone ") unit])\n      (" prefix))
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
        (gen-tb5
          buf
          "    [dst : (Array "
          slot
          ") (make-array "
          slot
          " new-capacity)]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "    (begin\n      ("
          prefix
          "-fill-empty dst 0 new-capacity)\n      ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-rehash-from src dst new-capacity 0 old-capacity)\n      ("
          map-name
          " dst ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-len map) 0))))\n(define ("
          prefix
          "-grow-capacity [capacity : i64]) : i64\n"))
      (set!
        buf
        (gen-tb2 buf "  (if (< capacity 4)\n    8\n    (* capacity 2)))\n" ""))
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
      (set!
        buf
        (gen-tb4 buf "          [(" insert-full " u) u])])))\n(defenum " entry))
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

(define (gen-hashmap-source-i64-key
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
    [insert-result : String (string-append map-name "InsertResult")]
    [insert-ok : String (string-append map-name "InsertOk")]
    [insert-full : String (string-append map-name "InsertFull")]
    [remove-result : String (string-append map-name "RemoveResult")]
    [remove-ok : String (string-append map-name "RemoveOk")]
    [remove-missing : String (string-append map-name "RemoveMissing")]
    [entry : String (string-append map-name "Entry")]
    [entry-none : String (string-append map-name "EntryNone")]
    [entry-some : String (string-append map-name "EntrySome")]
    [buf : TextBuf (text-buf-empty)]
    (begin
      (set! buf (gen-tb5 buf "(defenum " slot "\n  (" empty ")\n  ("))
      (set! buf (gen-tb5 buf tombstone ")\n  (" occupied " i64 " value-type))
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
        (gen-tb3 buf "(define (" prefix "-hash-key [key : i64]) : i64\n"))
      (set! buf (gen-tb3 buf "  (" prefix "-hash-normalize key))\n"))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-bucket-index [hash : i64] [capacity : i64]) : i64\n"))
      (set!
        buf
        (gen-tb3 buf "  (% (" prefix "-hash-normalize hash) capacity))\n"))
      (set!
        buf
        (gen-tb3
          buf
          "(define ("
          prefix
          "-next-index [index : i64] [capacity : i64]) : i64\n"))
      (set! buf (gen-tb2 buf "  (% (+ index 1) capacity))\n" ""))
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
        (gen-tb2
          buf
          "  [key : i64]\n  [hash : i64]\n  [index : i64]\n  [steps : i64]\n  [first-tombstone : i64]) : "
          ""))
      (set! buf (gen-tb2 buf probe "\n  (if (>= steps capacity)\n"))
      (set!
        buf
        (gen-tb5
          buf
          "    (if (>= first-tombstone 0)\n      ("
          probe-absent
          " first-tombstone)\n      ("
          probe-full
          "))\n"))
      (set! buf (gen-tb2 buf "    (match (array-ref slots index)\n      [(" ""))
      (set! buf (gen-tb5 buf empty ")\n        (" probe-absent " (" prefix))
      (set!
        buf
        (gen-tb3
          buf
          "-insert-slot first-tombstone index))]\n      [("
          tombstone
          ")\n"))
      (set! buf (gen-tb3 buf "        (" prefix "-probe-from\n"))
      (set!
        buf
        (gen-tb3
          buf
          "          slots\n          capacity\n          key\n          hash\n          ("
          prefix
          "-next-index index capacity)\n"))
      (set!
        buf
        (gen-tb2
          buf
          "          (+ steps 1)\n          (if (>= first-tombstone 0)\n            first-tombstone\n            index))]\n      [("
          ""))
      (set!
        buf
        (gen-tb2
          buf
          occupied
          " slot-key _ slot-hash)\n        (if (if (= slot-hash hash)\n          (= slot-key key)\n"))
      (set!
        buf
        (gen-tb5
          buf
          "          false)\n          ("
          probe-found
          " index)\n          ("
          prefix
          "-probe-from\n"))
      (set!
        buf
        (gen-tb3
          buf
          "            slots\n            capacity\n            key\n            hash\n            ("
          prefix
          "-next-index index capacity)\n"))
      (set!
        buf
        (gen-tb2
          buf
          "            (+ steps 1)\n            first-tombstone))])))\n"
          ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-probe\n"))
      (set!
        buf
        (gen-tb3 buf "  [slots : (Array " slot ")]\n  [capacity : i64]\n"))
      (set! buf (gen-tb2 buf "  [key : i64]\n  [hash : i64]) : " ""))
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
          "-bucket-index hash capacity)\n"))
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
        (gen-tb6
          buf
          " "
          value-type
          "))\n(defenum "
          insert-result
          "\n  ("
          insert-ok))
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
      (set! buf (gen-tb5 buf ")\n  (" remove-missing " " map-name "))\n"))
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
      (set! buf (gen-tb2 buf map-name "\n  (let\n    [slots : (Array "))
      (set! buf (gen-tb4 buf slot ") (make-array " slot " capacity)]\n"))
      (set!
        buf
        (gen-tb4
          buf
          "    (begin\n      ("
          prefix
          "-fill-empty slots 0 capacity)\n      ("
          map-name))
      (set! buf (gen-tb2 buf " slots 0 0))))\n" ""))
      (set! buf (gen-tb3 buf "(define (" prefix "-get [map : "))
      (set!
        buf
        (gen-tb5
          buf
          map-name
          "] [key : i64]) : "
          lookup
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
      (set! buf (gen-tb3 buf "(define (" prefix "-contains? [map : "))
      (set!
        buf
        (gen-tb4
          buf
          map-name
          "] [key : i64]) : bool\n  (match ("
          prefix
          "-get map key)\n"))
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
      (set!
        buf
        (gen-tb4
          buf
          "-insert [map : "
          map-name
          "] [key : i64] [value : "
          value-type))
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
          " key value hash))\n            ("
          insert-ok))
      (set!
        buf
        (gen-tb5
          buf
          "\n              ("
          map-name
          "\n                slots\n                (+ ("
          prefix
          "-len map) 1)\n"))
      (set!
        buf
        (gen-tb4
          buf
          "                (if reused-tombstone\n                  (- ("
          prefix
          "-deleted map) 1)\n                  ("
          prefix))
      (set!
        buf
        (gen-tb5
          buf
          "-deleted map))))))]\n      [("
          probe-full
          ") ("
          insert-full
          " map)])))\n"))
      (set! buf (gen-tb3 buf "(define (" prefix "-remove [map : "))
      (set!
        buf
        (gen-tb5
          buf
          map-name
          "] [key : i64]) : "
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
        (gen-tb4 buf "))\n          (" remove-ok "\n            (" map-name))
      (set!
        buf
        (gen-tb4
          buf
          "\n              slots\n              (- ("
          prefix
          "-len map) 1)\n              (+ ("
          prefix))
      (set!
        buf
        (gen-tb5
          buf
          "-deleted map) 1))))]\n      [("
          probe-absent
          " _) ("
          remove-missing
          " map)]\n"))
      (set!
        buf
        (gen-tb5 buf "      [(" probe-full ") (" remove-missing " map)])))\n"))
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
          " key value hash)\n          (match ("
          prefix
          "-probe dst dst-capacity key hash)\n"))
      (set!
        buf
        (gen-tb5
          buf
          "            [("
          probe-absent
          " slot)\n              (array-set! dst slot ("
          occupied
          " key value hash))]\n"))
      (set!
        buf
        (gen-tb5
          buf
          "            [("
          probe-found
          " slot)\n              (array-set! dst slot ("
          occupied
          " key value hash))]\n"))
      (set!
        buf
        (gen-tb5
          buf
          "            [("
          probe-full
          ") unit])]\n        [("
          empty
          ") unit]\n        [("))
      (set! buf (gen-tb3 buf tombstone ") unit])\n      (" prefix))
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
        (gen-tb5
          buf
          "    [dst : (Array "
          slot
          ") (make-array "
          slot
          " new-capacity)]\n"))
      (set!
        buf
        (gen-tb3
          buf
          "    (begin\n      ("
          prefix
          "-fill-empty dst 0 new-capacity)\n      ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-rehash-from src dst new-capacity 0 old-capacity)\n      ("
          map-name
          " dst ("))
      (set!
        buf
        (gen-tb4
          buf
          prefix
          "-len map) 0))))\n(define ("
          prefix
          "-grow-capacity [capacity : i64]) : i64\n"))
      (set!
        buf
        (gen-tb2 buf "  (if (< capacity 4)\n    8\n    (* capacity 2)))\n" ""))
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
          "] [key : i64] [value : "
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
      (set!
        buf
        (gen-tb4 buf "          [(" insert-full " u) u])])))\n(defenum " entry))
      (set!
        buf
        (gen-tb6 buf "\n  (" entry-none ")\n  (" entry-some " i64 " value-type))
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
  [value-type-key : String]
  [descriptor : String]
  [key-info : GenHashmapTypeInfo]
  [value-info : GenHashmapTypeInfo]) : ResultGenHashmapSource
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
  [descriptor : String]) : ResultGenHashmapSource
  (match (gen-hashmap-type-info key-type-key "key")
    [(OkGenHashmapTypeInfo key-info)
      (match (gen-hashmap-type-info value-type-key "value")
        [(OkGenHashmapTypeInfo value-info)
          (gen-hashmap-source-for-info
            map-name
            key-type-key
            value-type-key
            descriptor
            key-info
            value-info)]
        [(ErrGenHashmapTypeInfo diag) (ErrGenHashmapSource diag)])]
    [(ErrGenHashmapTypeInfo _)
      (ErrGenHashmapSource
        (gen-hashmap-diag
          (string-append
            "hashmap-family: unsupported key descriptor "
            (string-append
              descriptor
              (string-append " for key type " key-type-key)))))]))

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
          (gen-registry-cons key template registry)
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
          (ErrGenDecl
            (gen-hashmap-diag
              "hashmap-family: generated payload must declare a visible item"))]
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
            descriptor)
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

(define (gen-rewrite-decl
  [decl : AstDecl]
  [module : String]
  [registry : GenRegistry]
  [env : CtfeEnv]) : ResultGenDecl
  (match decl
    [(AstDeclModule name) (OkGenDecl (gen-single-decl-list decl) registry name)]
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
                      (if (string-eq generator "stdlib/hashmap-family")
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
                              registry)])
                        (gen-register-generated-decl
                          template
                          module
                          generator
                          item
                          args
                          arg-key
                          registry))]
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

(define (gen-normalize-program [program : AstProgram]) : ResultGenProgram
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [env : CtfeEnv
          (ctfe-env-with-reflections (ctfe-reflections-from-program program))]
        (match (gen-rewrite-decls decls "" GenRegistryNil env)
          [(OkGenDecls rewritten _ _) (OkGenProgram (ast-program rewritten))]
          [(ErrGenDecls diag) (ErrGenProgram diag)]))]))

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
    [(CtfeBool _) (ctfe-type-eq ty (AstTyBool))]
    [(CtfeChar _) (ctfe-type-eq ty (AstTyChar))]
    [(CtfeString _) (ctfe-type-eq ty (AstTyString))]
    [(CtfeUnit) (ctfe-type-eq ty (AstTyUnit))]
    [(CtfeType _) false]
    [(CtfeExpr _ _) (ctfe-type-eq ty (AstTyExpr))]
    [(CtfeExprList _) (ctfe-type-eq ty (AstTyExprList))]))

(define (spec-value-type-label [value : CompilerCtfeValue]) : String
  (match value
    [(CtfeI64 _) "i64"]
    [(CtfeBool _) "bool"]
    [(CtfeChar _) "char"]
    [(CtfeString _) "String"]
    [(CtfeUnit) "unit"]
    [(CtfeType _) "type"]
    [(CtfeExpr _ _) "Expr"]
    [(CtfeExprList _) "expr-list"]))

(define (spec-type-subst-lookup [subs : SpecTypeSubst] [name : String]) : SpecMaybeString
  (match subs
    [(SpecTypeSubstNil) (SpecNoString)]
    [(SpecTypeSubstCons key _ rest)
      (if (string-eq key name)
        (SpecSomeString key)
        (spec-type-subst-lookup (box-get rest) name))]))

(define (spec-type-subst-type [subs : SpecTypeSubst] [name : String]) : AstType
  (match subs
    [(SpecTypeSubstNil) (AstTyVar name)]
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
              (spec-value-subst-remove-name subs name)
              rest)]))]))

(define (spec-value-subst-remove-pattern
  [subs : SpecValueSubst]
  [pattern : AstPattern]) : SpecValueSubst
  (match pattern
    [(AstPatVar name _) (spec-value-subst-remove-name subs name)]
    [(AstPatTuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-value-subst-remove-pattern-list subs patterns))]
    [(AstPatWildcard) subs]
    [(AstPatBinding name) (spec-value-subst-remove-name subs name)]
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
              (spec-type-subst-remove-name subs name)
              rest)]))]))

(define (spec-type-subst-remove-pattern
  [subs : SpecTypeSubst]
  [pattern : AstPattern]) : SpecTypeSubst
  (match pattern
    [(AstPatVar name _) (spec-type-subst-remove-name subs name)]
    [(AstPatTuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (spec-type-subst-remove-pattern-list subs patterns))]
    [(AstPatWildcard) subs]
    [(AstPatBinding name) (spec-type-subst-remove-name subs name)]
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
        (spec-substitute-type (box-get ret) subs))]
    [(AstTyTuple elems) (AstTyTuple (spec-substitute-type-list elems subs))]
    [(AstTyArray elem count)
      (ast-ty-array (spec-substitute-type (box-get elem) subs) count)]
    [(AstTyDynArray elem)
      (ast-ty-dyn-array (spec-substitute-type (box-get elem) subs))]
    [(AstTyBox elem) (ast-ty-box (spec-substitute-type (box-get elem) subs))]
    [(AstTyPtr elem) (ast-ty-ptr (spec-substitute-type (box-get elem) subs))]
    [(AstTyMutPtr elem)
      (ast-ty-mut-ptr (spec-substitute-type (box-get elem) subs))]
    [(AstTyRef region inner)
      (ast-ty-ref region (spec-substitute-type (box-get inner) subs))]
    [(AstTyMutRef region inner)
      (ast-ty-mut-ref region (spec-substitute-type (box-get inner) subs))]
    [(AstTyRegion region inner)
      (ast-ty-region region (spec-substitute-type (box-get inner) subs))]
    [(AstTyEnumArgs name lifetimes) (AstTyEnumArgs name lifetimes)]
    [(AstTyStructArgs name lifetimes) (AstTyStructArgs name lifetimes)]
    [(AstTyVarArgs name lifetimes)
      (match (spec-type-subst-lookup subs name)
        [(SpecSomeString _) (spec-type-subst-type subs name)]
        [(SpecNoString) (AstTyVarArgs name lifetimes)])]
    [(AstTyVar name)
      (match (spec-type-subst-lookup subs name)
        [(SpecSomeString _) (spec-type-subst-type subs name)]
        [(SpecNoString) ty])]
    [_ ty]))

(define (spec-substitute-type-list [types : AstTypeList] [subs : SpecTypeSubst]) : AstTypeList
  (match types
    [(AstTypeNil) AstTypeNil]
    [(AstTypeCons head rest)
      (let
        [head : AstType (box-get head)]
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
    [(CtfeI64 n) (OkSpecSubExpr (AstExprLiteral (AstLitInt n)))]
    [(CtfeBool b) (OkSpecSubExpr (AstExprLiteral (AstLitBool b)))]
    [(CtfeChar c) (OkSpecSubExpr (AstExprLiteral (AstLitChar c)))]
    [(CtfeString _)
      (ErrSpecSubExpr
        (spec-diagnostic-at-expr
          origin
          "cannot substitute compile-time String value into runtime expression"))]
    [(CtfeUnit) (OkSpecSubExpr (AstExprLiteral (AstLitUnit)))]
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
          "cannot substitute compile-time ExprList value into runtime expression"))]))

(define (spec-expr-var-name [expr : AstExpr]) : SpecMaybeString
  (match (ast-expr-unspan expr)
    [(AstExprVar name) (SpecSomeString name)]
    [_ (SpecNoString)]))

(define (spec-rewrite-expr-list
  [exprs : AstExprList]
  [templates : SpecTemplateList]
  [state : SpecState]) : ResultSpecExprList
  (match exprs
    [(AstExprNil) (OkSpecExprList AstExprNil state)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (box-get head)]
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
  [templates : SpecTemplateList]
  [state : SpecState]) : ResultSpecLetBindingList
  (match bindings
    [(AstLetBindingNil) (OkSpecLetBindingList AstLetBindingNil state)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name ty value-box)
            (let
              [value : AstExpr (box-get value-box)]
              (match (spec-rewrite-expr value templates state)
                [(OkSpecExpr rewritten-value value-state)
                  (match (spec-rewrite-let-bindings
                    rest
                    (spec-template-list-remove-name templates name)
                    value-state)
                    [(OkSpecLetBindingList rewritten-rest rest-state)
                      (OkSpecLetBindingList
                        (ast-let-binding-cons
                          (ast-let-binding name ty rewritten-value)
                          rewritten-rest)
                        rest-state)]
                    [(ErrSpecLetBindingList diag) (ErrSpecLetBindingList diag)])]
                [(ErrSpecExpr diag) (ErrSpecLetBindingList diag)]))]))]))

(define (spec-rewrite-match-arms
  [arms : AstMatchArmList]
  [templates : SpecTemplateList]
  [state : SpecState]) : ResultSpecMatchArmList
  (match arms
    [(AstMatchArmNil) (OkSpecMatchArmList AstMatchArmNil state)]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (box-get body-box)]
              (match (spec-rewrite-expr
                body
                (spec-template-list-remove-pattern templates pattern)
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
  [templates : SpecTemplateList]
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
                (ast-expr-call (AstExprVar specialized-name) runtime-args)
                ensure-state)]
            [(ErrSpecEnsure diag) (ErrSpecExpr diag)])]
        [(ErrSpecArgs diag) (ErrSpecExpr diag)])]))

(define (spec-rewrite-specialized-args
  [params : AstParamList]
  [args : AstExprList]
  [templates : SpecTemplateList]
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
              [arg : AstExpr (box-get arg)]
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
                                      param-name
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
                                    param-name
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
                              (spec-type-subst-cons name actual-ty type-subs))]
                          [_
                            (ErrSpecBuild
                              (compiler-diagnostic-at-start
                                ""
                                "specialize: expected type value"))])
                        (OkSpecBuild
                          runtime
                          (spec-value-subst-cons name value value-subs)
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
  [templates : SpecTemplateList]
  [state : SpecState]
  [origin : AstExpr]) : ResultSpecEnsure
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
                            typed-body
                            value-subs)
                            [(OkSpecSubExpr valued-body)
                              (let
                                [cached-state : SpecState
                                  (SpecState
                                    generated
                                    (spec-cache-cons key generated-name cache)
                                    ctfe-env)]
                                (match (spec-rewrite-expr
                                  valued-body
                                  (spec-template-list-remove-params
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
  [templates : SpecTemplateList]
  [state : SpecState]) : ResultSpecExpr
  (match expr
    [(AstExprSpanned inner-box span)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten rewritten-state)
            (OkSpecExpr (ast-expr-spanned rewritten span) rewritten-state)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprLiteral _) (OkSpecExpr expr state)]
    [(AstExprVar _) (OkSpecExpr expr state)]
    [(AstExprTypeLiteral _) (OkSpecExpr expr state)]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
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
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten rewritten-state)
            (OkSpecExpr (ast-expr-unary op rewritten) rewritten-state)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
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
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
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
        [body : AstExpr (box-get body-box)]
        (match (spec-rewrite-let-bindings bindings templates state)
          [(OkSpecLetBindingList rewritten-bindings binding-state)
            (match (spec-rewrite-expr
              body
              (spec-template-list-remove-let-binding-names templates bindings)
              binding-state)
              [(OkSpecExpr rewritten-body body-state)
                (OkSpecExpr
                  (ast-expr-let rewritten-bindings rewritten-body)
                  body-state)]
              [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
          [(ErrSpecLetBindingList diag) (ErrSpecExpr diag)]))]
    [(AstExprLambda params ret body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (match (spec-rewrite-expr
          body
          (spec-template-list-remove-params templates params)
          state)
          [(OkSpecExpr rewritten-body body-state)
            (OkSpecExpr (ast-expr-lambda params ret rewritten-body) body-state)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprTuple exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(OkSpecExprList rewritten state2)
          (OkSpecExpr (AstExprTuple rewritten) state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprTupleRef inner-box index)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-tuple-ref rewritten index) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprArray exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(OkSpecExprList rewritten state2)
          (OkSpecExpr (AstExprArray rewritten) state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprMakeArray elem-ty len-box)
      (let
        [len : AstExpr (box-get len-box)]
        (match (spec-rewrite-expr len templates state)
          [(OkSpecExpr rewritten-len state2)
            (OkSpecExpr (ast-expr-make-array elem-ty rewritten-len) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
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
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        [value : AstExpr (box-get value-box)]
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
        [array : AstExpr (box-get array-box)]
        [value : AstExpr (box-get value-box)]
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
        [text : AstExpr (box-get text-box)]
        [index : AstExpr (box-get index-box)]
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
        [cond : AstExpr (box-get cond-box)]
        [body : AstExpr (box-get body-box)]
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
          (OkSpecExpr (AstExprBegin rewritten) state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprUnsafe exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(OkSpecExprList rewritten state2)
          (OkSpecExpr (AstExprUnsafe rewritten) state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprSet name value-box)
      (let
        [value : AstExpr (box-get value-box)]
        (match (spec-rewrite-expr value templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-set name rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprAnn inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-ann rewritten ty) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-cast rewritten ty) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (box-get scrutinee-box)]
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
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [body : AstExpr (box-get body-box)]
        (match (spec-rewrite-expr start templates state)
          [(OkSpecExpr rewritten-start start-state)
            (match (spec-rewrite-expr end templates start-state)
              [(OkSpecExpr rewritten-end end-state)
                (match (spec-rewrite-expr
                  body
                  (spec-template-list-remove-name templates index)
                  end-state)
                  [(OkSpecExpr rewritten-body body-state)
                    (OkSpecExpr
                      (ast-expr-foreach
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
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [init : AstExpr (box-get init-box)]
        [value : AstExpr (box-get value-box)]
        (match (spec-rewrite-expr start templates state)
          [(OkSpecExpr rewritten-start start-state)
            (match (spec-rewrite-expr end templates start-state)
              [(OkSpecExpr rewritten-end end-state)
                (match (spec-rewrite-expr init templates end-state)
                  [(OkSpecExpr rewritten-init init-state)
                    (match (spec-rewrite-expr
                      value
                      (spec-template-list-remove-name templates index)
                      init-state)
                      [(OkSpecExpr rewritten-value value-state)
                        (OkSpecExpr
                          (ast-expr-spmd-reduce
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
    [(AstExprStructGet receiver-box field)
      (let
        [receiver : AstExpr (box-get receiver-box)]
        (match (spec-rewrite-expr receiver templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-struct-get rewritten field) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprWithRegion region body)
      (match (spec-rewrite-expr-list body templates state)
        [(OkSpecExprList rewritten state2)
          (OkSpecExpr (AstExprWithRegion region rewritten) state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (box-get scratch-box)]
        (match (spec-rewrite-expr scratch templates state)
          [(OkSpecExpr rewritten-scratch scratch-state)
            (match (spec-rewrite-expr-list body templates scratch-state)
              [(OkSpecExprList rewritten-body body-state)
                (OkSpecExpr
                  (ast-expr-with-escape rewritten-scratch rewritten-body)
                  body-state)]
              [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprWithResource bindings body)
      (OkSpecExpr (AstExprWithResource bindings body) state)]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-box rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-box-get rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-comptime rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-try rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-return rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprPtrNull ty) (OkSpecExpr (AstExprPtrNull ty) state)]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-ptr-null-check rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-ptr-read rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [value : AstExpr (box-get value-box)]
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
        [ptr : AstExpr (box-get ptr-box)]
        [offset : AstExpr (box-get offset-box)]
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
        [ptr : AstExpr (box-get ptr-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-ptr-cast rewritten ty) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (match (spec-rewrite-expr ptr templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-ptr-to-int rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprIntToPtr value-box ty)
      (let
        [value : AstExpr (box-get value-box)]
        (match (spec-rewrite-expr value templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-int-to-ptr rewritten ty) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-string-data rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [len : AstExpr (box-get len-box)]
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
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-array-data rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprProgramArgc) (OkSpecExpr (AstExprProgramArgc) state)]
    [(AstExprProgramArgv) (OkSpecExpr (AstExprProgramArgv) state)]
    [(AstExprProgramEnvp) (OkSpecExpr (AstExprProgramEnvp) state)]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [index : AstExpr (box-get index-box)]
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
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-quote rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprQuasiquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-quasiquote rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-unquote rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-rewrite-expr inner templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecExpr (ast-expr-unquote-splicing rewritten) state2)]
          [(ErrSpecExpr diag) (ErrSpecExpr diag)]))]
    [(AstExprBorrow _ _) (OkSpecExpr expr state)]))

(define (spec-substitute-values-expr [expr : AstExpr] [subs : SpecValueSubst]) : ResultSpecSubExpr
  (match expr
    [(AstExprSpanned inner-box span)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-spanned rewritten span))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprVar name)
      (match (spec-value-subst-lookup subs name)
        [(SpecSomeString _)
          (spec-ctfe-value-to-expr (spec-value-subst-value subs name) expr)]
        [(SpecNoString) (OkSpecSubExpr expr)])]
    [(AstExprLiteral _) (OkSpecSubExpr expr)]
    [(AstExprTypeLiteral _) (OkSpecSubExpr expr)]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
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
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-unary op rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
        (match (spec-substitute-values-expr func subs)
          [(OkSpecSubExpr rewritten-func)
            (match (spec-substitute-values-expr-list args subs)
              [(OkSpecSubExprList rewritten-args)
                (OkSpecSubExpr (ast-expr-call rewritten-func rewritten-args))]
              [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
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
        [body : AstExpr (box-get body-box)]
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
        [body : AstExpr (box-get body-box)]
        (match (spec-substitute-values-expr
          body
          (spec-value-subst-remove-params subs params))
          [(OkSpecSubExpr rewritten-body)
            (OkSpecSubExpr (ast-expr-lambda params ret rewritten-body))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprTuple exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(OkSpecSubExprList rewritten) (OkSpecSubExpr (AstExprTuple rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprTupleRef inner-box index)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-tuple-ref rewritten index))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprArray exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(OkSpecSubExprList rewritten) (OkSpecSubExpr (AstExprArray rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprMakeArray elem-ty len-box)
      (let
        [len : AstExpr (box-get len-box)]
        (match (spec-substitute-values-expr len subs)
          [(OkSpecSubExpr rewritten-len)
            (OkSpecSubExpr (ast-expr-make-array elem-ty rewritten-len))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
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
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        [value : AstExpr (box-get value-box)]
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
        [array : AstExpr (box-get array-box)]
        [value : AstExpr (box-get value-box)]
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
        [text : AstExpr (box-get text-box)]
        [index : AstExpr (box-get index-box)]
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
        [cond : AstExpr (box-get cond-box)]
        [body : AstExpr (box-get body-box)]
        (match (spec-substitute-values-expr cond subs)
          [(OkSpecSubExpr rewritten-cond)
            (match (spec-substitute-values-expr body subs)
              [(OkSpecSubExpr rewritten-body)
                (OkSpecSubExpr (ast-expr-while rewritten-cond rewritten-body))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBegin exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(OkSpecSubExprList rewritten) (OkSpecSubExpr (AstExprBegin rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprUnsafe exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (AstExprUnsafe rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprSet name value-box)
      (let
        [value : AstExpr (box-get value-box)]
        (match (spec-value-subst-lookup subs name)
          [(SpecSomeString _)
            (ErrSpecSubExpr
              (spec-diagnostic-at-expr
                expr
                (string-append
                  "cannot assign to comptime parameter '"
                  (string-append name "'"))))]
          [(SpecNoString)
            (match (spec-substitute-values-expr value subs)
              [(OkSpecSubExpr rewritten)
                (OkSpecSubExpr (ast-expr-set name rewritten))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]))]
    [(AstExprAnn inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ann rewritten ty))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-cast rewritten ty))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (box-get scrutinee-box)]
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
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [body : AstExpr (box-get body-box)]
        (match (spec-substitute-values-expr start subs)
          [(OkSpecSubExpr rewritten-start)
            (match (spec-substitute-values-expr end subs)
              [(OkSpecSubExpr rewritten-end)
                (match (spec-substitute-values-expr
                  body
                  (spec-value-subst-remove-name subs index))
                  [(OkSpecSubExpr rewritten-body)
                    (OkSpecSubExpr
                      (ast-expr-foreach
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
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [init : AstExpr (box-get init-box)]
        [value : AstExpr (box-get value-box)]
        (match (spec-substitute-values-expr start subs)
          [(OkSpecSubExpr rewritten-start)
            (match (spec-substitute-values-expr end subs)
              [(OkSpecSubExpr rewritten-end)
                (match (spec-substitute-values-expr init subs)
                  [(OkSpecSubExpr rewritten-init)
                    (match (spec-substitute-values-expr
                      value
                      (spec-value-subst-remove-name subs index))
                      [(OkSpecSubExpr rewritten-value)
                        (OkSpecSubExpr
                          (ast-expr-spmd-reduce
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
    [(AstExprStructGet receiver-box field)
      (let
        [receiver : AstExpr (box-get receiver-box)]
        (match (spec-substitute-values-expr receiver subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-struct-get rewritten field))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprWithRegion region body)
      (match (spec-substitute-values-expr-list body subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (AstExprWithRegion region rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (box-get scratch-box)]
        (match (spec-substitute-values-expr scratch subs)
          [(OkSpecSubExpr rewritten-scratch)
            (match (spec-substitute-values-expr-list body subs)
              [(OkSpecSubExprList rewritten-body)
                (OkSpecSubExpr
                  (ast-expr-with-escape rewritten-scratch rewritten-body))]
              [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprWithResource bindings body)
      (OkSpecSubExpr (AstExprWithResource bindings body))]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten) (OkSpecSubExpr (ast-expr-box rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-box-get rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-comptime rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten) (OkSpecSubExpr (ast-expr-try rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-return rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrNull ty) (OkSpecSubExpr (AstExprPtrNull ty))]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-null-check rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-read rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [value : AstExpr (box-get value-box)]
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
        [ptr : AstExpr (box-get ptr-box)]
        [offset : AstExpr (box-get offset-box)]
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
        [ptr : AstExpr (box-get ptr-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-cast rewritten ty))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (match (spec-substitute-values-expr ptr subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-to-int rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprIntToPtr value-box ty)
      (let
        [value : AstExpr (box-get value-box)]
        (match (spec-substitute-values-expr value subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-int-to-ptr rewritten ty))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-string-data rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [len : AstExpr (box-get len-box)]
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
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-array-data rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprProgramArgc) (OkSpecSubExpr (AstExprProgramArgc))]
    [(AstExprProgramArgv) (OkSpecSubExpr (AstExprProgramArgv))]
    [(AstExprProgramEnvp) (OkSpecSubExpr (AstExprProgramEnvp))]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [index : AstExpr (box-get index-box)]
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
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten) (OkSpecSubExpr (ast-expr-quote rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprQuasiquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-quasiquote rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-unquote rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-values-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-unquote-splicing rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBorrow _ _) (OkSpecSubExpr expr)]))

(define (spec-substitute-values-expr-list
  [exprs : AstExprList]
  [subs : SpecValueSubst]) : ResultSpecSubExprList
  (match exprs
    [(AstExprNil) (OkSpecSubExprList AstExprNil)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (box-get head)]
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
              [value : AstExpr (box-get value-box)]
              (match (spec-substitute-values-expr value subs)
                [(OkSpecSubExpr rewritten-value)
                  (match (spec-substitute-values-let-bindings
                    rest
                    (spec-value-subst-remove-name subs name))
                    [(OkSpecSubLetBindingList rewritten-rest)
                      (OkSpecSubLetBindingList
                        (ast-let-binding-cons
                          (ast-let-binding name ty rewritten-value)
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
              [body : AstExpr (box-get body-box)]
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
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-spanned rewritten span))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprVar name)
      (match (spec-type-subst-lookup subs name)
        [(SpecSomeString _)
          (ErrSpecSubExpr
            (spec-diagnostic-at-expr
              expr
              (string-append
                "type-valued comptime parameter '"
                (string-append name "' cannot be used as a runtime value"))))]
        [(SpecNoString) (OkSpecSubExpr expr)])]
    [(AstExprLiteral _) (OkSpecSubExpr expr)]
    [(AstExprTypeLiteral ty)
      (OkSpecSubExpr (AstExprTypeLiteral (spec-substitute-type ty subs)))]
    [(AstExprMakeArray elem-ty len-box)
      (let
        [len : AstExpr (box-get len-box)]
        (match (spec-substitute-types-expr len subs)
          [(OkSpecSubExpr rewritten-len)
            (OkSpecSubExpr
              (ast-expr-make-array
                (spec-substitute-type elem-ty subs)
                rewritten-len))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprAnn inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr
              (ast-expr-ann rewritten (spec-substitute-type ty subs)))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr
              (ast-expr-cast rewritten (spec-substitute-type ty subs)))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprLambda params ret body-box)
      (let
        [body : AstExpr (box-get body-box)]
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
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [body : AstExpr (box-get body-box)]
        (match (spec-substitute-types-expr start subs)
          [(OkSpecSubExpr rewritten-start)
            (match (spec-substitute-types-expr end subs)
              [(OkSpecSubExpr rewritten-end)
                (match (spec-substitute-types-expr
                  body
                  (spec-type-subst-remove-name subs index))
                  [(OkSpecSubExpr rewritten-body)
                    (OkSpecSubExpr
                      (ast-expr-foreach
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
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [init : AstExpr (box-get init-box)]
        [value : AstExpr (box-get value-box)]
        (match (spec-substitute-types-expr start subs)
          [(OkSpecSubExpr rewritten-start)
            (match (spec-substitute-types-expr end subs)
              [(OkSpecSubExpr rewritten-end)
                (match (spec-substitute-types-expr init subs)
                  [(OkSpecSubExpr rewritten-init)
                    (match (spec-substitute-types-expr
                      value
                      (spec-type-subst-remove-name subs index))
                      [(OkSpecSubExpr rewritten-value)
                        (OkSpecSubExpr
                          (ast-expr-spmd-reduce
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
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
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
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-unary op rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
        (match (spec-substitute-types-expr func subs)
          [(OkSpecSubExpr rewritten-func)
            (match (spec-substitute-types-expr-list args subs)
              [(OkSpecSubExprList rewritten-args)
                (OkSpecSubExpr (ast-expr-call rewritten-func rewritten-args))]
              [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
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
        [body : AstExpr (box-get body-box)]
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
        [(OkSpecSubExprList rewritten) (OkSpecSubExpr (AstExprTuple rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprTupleRef inner-box index)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-tuple-ref rewritten index))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprArray exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(OkSpecSubExprList rewritten) (OkSpecSubExpr (AstExprArray rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
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
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        [value : AstExpr (box-get value-box)]
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
        [array : AstExpr (box-get array-box)]
        [value : AstExpr (box-get value-box)]
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
        [text : AstExpr (box-get text-box)]
        [index : AstExpr (box-get index-box)]
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
        [cond : AstExpr (box-get cond-box)]
        [body : AstExpr (box-get body-box)]
        (match (spec-substitute-types-expr cond subs)
          [(OkSpecSubExpr rewritten-cond)
            (match (spec-substitute-types-expr body subs)
              [(OkSpecSubExpr rewritten-body)
                (OkSpecSubExpr (ast-expr-while rewritten-cond rewritten-body))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBegin exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(OkSpecSubExprList rewritten) (OkSpecSubExpr (AstExprBegin rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprUnsafe exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (AstExprUnsafe rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprSet name value-box)
      (let
        [value : AstExpr (box-get value-box)]
        (match (spec-type-subst-lookup subs name)
          [(SpecSomeString _)
            (ErrSpecSubExpr
              (spec-diagnostic-at-expr
                expr
                (string-append
                  "type-valued comptime parameter '"
                  (string-append name "' cannot be assigned"))))]
          [(SpecNoString)
            (match (spec-substitute-types-expr value subs)
              [(OkSpecSubExpr rewritten)
                (OkSpecSubExpr (ast-expr-set name rewritten))]
              [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (box-get scrutinee-box)]
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
        [receiver : AstExpr (box-get receiver-box)]
        (match (spec-substitute-types-expr receiver subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-struct-get rewritten field))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprWithRegion region body)
      (match (spec-substitute-types-expr-list body subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (AstExprWithRegion region rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (box-get scratch-box)]
        (match (spec-substitute-types-expr scratch subs)
          [(OkSpecSubExpr rewritten-scratch)
            (match (spec-substitute-types-expr-list body subs)
              [(OkSpecSubExprList rewritten-body)
                (OkSpecSubExpr
                  (ast-expr-with-escape rewritten-scratch rewritten-body))]
              [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprWithResource bindings body)
      (OkSpecSubExpr (AstExprWithResource bindings body))]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten) (OkSpecSubExpr (ast-expr-box rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-box-get rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-comptime rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten) (OkSpecSubExpr (ast-expr-try rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-return rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrNull ty)
      (OkSpecSubExpr (AstExprPtrNull (spec-substitute-type ty subs)))]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-null-check rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-read rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [value : AstExpr (box-get value-box)]
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
        [ptr : AstExpr (box-get ptr-box)]
        [offset : AstExpr (box-get offset-box)]
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
        [ptr : AstExpr (box-get ptr-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr
              (ast-expr-ptr-cast rewritten (spec-substitute-type ty subs)))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (match (spec-substitute-types-expr ptr subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-ptr-to-int rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprIntToPtr value-box ty)
      (let
        [value : AstExpr (box-get value-box)]
        (match (spec-substitute-types-expr value subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr
              (ast-expr-int-to-ptr rewritten (spec-substitute-type ty subs)))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-string-data rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [len : AstExpr (box-get len-box)]
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
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-array-data rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprProgramArgc) (OkSpecSubExpr (AstExprProgramArgc))]
    [(AstExprProgramArgv) (OkSpecSubExpr (AstExprProgramArgv))]
    [(AstExprProgramEnvp) (OkSpecSubExpr (AstExprProgramEnvp))]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [index : AstExpr (box-get index-box)]
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
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten) (OkSpecSubExpr (ast-expr-quote rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprQuasiquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-quasiquote rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-unquote rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (spec-substitute-types-expr inner subs)
          [(OkSpecSubExpr rewritten)
            (OkSpecSubExpr (ast-expr-unquote-splicing rewritten))]
          [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)]))]
    [(AstExprBorrow _ _) (OkSpecSubExpr expr)]))

(define (spec-substitute-types-expr-list
  [exprs : AstExprList]
  [subs : SpecTypeSubst]) : ResultSpecSubExprList
  (match exprs
    [(AstExprNil) (OkSpecSubExprList AstExprNil)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (box-get head)]
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
              [value : AstExpr (box-get value-box)]
              (match (spec-substitute-types-expr value subs)
                [(OkSpecSubExpr rewritten-value)
                  (match (spec-substitute-types-let-bindings
                    rest
                    (spec-type-subst-remove-name subs name))
                    [(OkSpecSubLetBindingList rewritten-rest)
                      (OkSpecSubLetBindingList
                        (ast-let-binding-cons
                          (ast-let-binding
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
              [body : AstExpr (box-get body-box)]
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
  [templates : SpecTemplateList]
  [state : SpecState]) : ResultSpecDecl
  (match decl
    [(AstDeclDef name ty value-box)
      (let
        [value : AstExpr (box-get value-box)]
        (match (spec-rewrite-expr value templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecDecl (SpecSomeDecl (ast-decl-def name ty rewritten)) state2)]
          [(ErrSpecExpr diag) (ErrSpecDecl diag)]))]
    [(AstDeclDefFn name params ret body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (if (spec-param-list-has-comptime? params)
          (OkSpecDecl (SpecNoDecl) state)
          (match (spec-rewrite-expr
            body
            (spec-template-list-remove-params templates params)
            state)
            [(OkSpecExpr rewritten state2)
              (OkSpecDecl
                (SpecSomeDecl (ast-decl-def-fn name params ret rewritten))
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
        [body : AstExpr (box-get body-box)]
        (match (spec-rewrite-expr body templates state)
          [(OkSpecExpr rewritten state2)
            (OkSpecDecl
              (SpecSomeDecl (ast-decl-def-macro name params ret rewritten))
              state2)]
          [(ErrSpecExpr diag) (ErrSpecDecl diag)]))]
    [_ (OkSpecDecl (SpecSomeDecl decl) state)]))

(define (spec-rewrite-decls
  [decls : AstDeclList]
  [templates : SpecTemplateList]
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
                  templates
                  (SpecState
                    AstDeclNil
                    SpecCacheNil
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
                [(AstDeclDefFn fn-name _ _ _)
                  (if (string-eq fn-name name)
                    true
                    (compiler-specialize-decl-list-defines? rest name))]
                [(AstDeclComptimeDecl _ template-box)
                  (let
                    [template : AstDecl (box-get template-box)]
                    (match template
                      [(AstDeclDefFn fn-name _ _ _)
                        (if (string-eq fn-name name)
                          true
                          (compiler-specialize-decl-list-defines? rest name))]
                      [_ (compiler-specialize-decl-list-defines? rest name)]))]
                [_ (compiler-specialize-decl-list-defines? rest name)]))]
          [(AstDeclDefFn fn-name _ _ _)
            (if (string-eq fn-name name)
              true
              (compiler-specialize-decl-list-defines? rest name))]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDeclDefFn fn-name _ _ _)
                  (if (string-eq fn-name name)
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
      (and
        (string-eq
          (spec-type-key (ast-ty-mut-ptr (ast-ty-ptr (AstTyU8))))
          "mutptr_ptr_u8")
        (ctfe-type-eq
          (spec-substitute-type (ast-ty-mut-ptr (AstTyVar "T")) subs)
          (ast-ty-mut-ptr (AstTyI64)))))))

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
      (and
        (string-eq
          (spec-specialized-name "alloc" vals-i64)
          (spec-specialized-name "alloc" vals-i64))
        (and
          (string-eq
            (spec-specialization-key "alloc" vals-i64)
            "alloc:type_i64_none")
          (and
            (not
              (string-eq
                (spec-specialized-name "alloc" vals-i64)
                (spec-specialized-name "alloc" vals-bool)))
            (and
              (string-eq
                (spec-specialized-name "pair" vals-multi)
                "__tl_specialized_pair_type_i64_i64_5_none")
              (and
                (string-eq (spec-value-key (CtfeI64 (- 0 3))) "i64_m3")
                (string-eq
                  (spec-specialized-name "name" vals-string)
                  "__tl_specialized_name_string_3_97_32_98_none")))))))))

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
                [(AstDeclDefFn fn-name _ _ _)
                  (if (string-eq fn-name name)
                    (+ 1 (compiler-specialize-decl-list-count-defs rest name))
                    (compiler-specialize-decl-list-count-defs rest name))]
                [(AstDeclComptimeDecl _ template-box)
                  (let
                    [template : AstDecl (box-get template-box)]
                    (match template
                      [(AstDeclDefFn fn-name _ _ _)
                        (if (string-eq fn-name name)
                          (+
                            1
                            (compiler-specialize-decl-list-count-defs rest name))
                          (compiler-specialize-decl-list-count-defs rest name))]
                      [_ (compiler-specialize-decl-list-count-defs rest name)]))]
                [_ (compiler-specialize-decl-list-count-defs rest name)]))]
          [(AstDeclDefFn fn-name _ _ _)
            (if (string-eq fn-name name)
              (+ 1 (compiler-specialize-decl-list-count-defs rest name))
              (compiler-specialize-decl-list-count-defs rest name))]
          [(AstDeclComptimeDecl _ inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDeclDefFn fn-name _ _ _)
                  (if (string-eq fn-name name)
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
        (spec-type-key (spec-substitute-type (AstTyVar "T") subs))
        "i64")
      (and
        (string-eq
          (spec-type-key
            (spec-substitute-type (ast-ty-ptr (AstTyVar "T")) subs))
          "ptr_i64")
        (and
          (string-eq
            (spec-type-key
              (spec-substitute-type (ast-ty-dyn-array (AstTyVar "T")) subs))
            "dynarray_i64")
          (and
            (string-eq
              (spec-type-key
                (spec-substitute-type
                  (ast-ty-func
                    (ast-type-cons (AstTyVar "T") AstTypeNil)
                    (AstTyVar "T"))
                  subs))
              "fn_i64_nil_to_i64")
            (string-eq
              (spec-type-key (spec-substitute-type (AstTyVar "U") subs))
              "var_U")))))))

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
      (match (spec-substitute-values-expr (AstExprVar "x") subs)
        [(OkSpecSubExpr e)
          (match e
            [(AstExprLiteral lit)
              (match lit
                [(AstLitInt n) (= n 5)]
                [_ false])]
            [_ false])]
        [(ErrSpecSubExpr _) false])
      (and
        ;; unmapped variable y -> unchanged
        (match (spec-substitute-values-expr (AstExprVar "y") subs)
          [(OkSpecSubExpr e)
            (match e
              [(AstExprVar name) (string-eq name "y")]
              [_ false])]
          [(ErrSpecSubExpr _) false])
        ;; recursion through `if`: x in the condition becomes 5, unmapped y stays
        (match (spec-substitute-values-expr
          (ast-expr-if
            (AstExprVar "x")
            (AstExprLiteral (AstLitInt 1))
            (AstExprVar "y"))
          subs)
          [(OkSpecSubExpr e)
            (match e
              [(AstExprIf cond-box _ else-branch-box)
                (let
                  [cond : AstExpr (box-get cond-box)]
                  [else-branch : AstExpr (box-get else-branch-box)]
                  (and
                    (match cond
                      [(AstExprLiteral lit)
                        (match lit
                          [(AstLitInt n) (= n 5)]
                          [_ false])]
                      [_ false])
                    (match else-branch
                      [(AstExprVar name) (string-eq name "y")]
                      [_ false])))]
              [_ false])]
          [(ErrSpecSubExpr _) false])))))

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
    [cache : SpecCache
      (spec-cache-cons
        "one"
        "generated-one"
        (spec-cache-cons "two" "generated-two" SpecCacheNil))]
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
      (match (spec-template-lookup templates "second")
        [(SpecSomeTemplate template)
          (match template
            [(SpecTemplate name _ _ _) (string-eq name "second")])]
        [(SpecNoTemplate) false])
      (and
        (match (spec-cache-lookup cache "two")
          [(SpecSomeString name) (string-eq name "generated-two")]
          [(SpecNoString) false])
        (and
          (string-eq (spec-values-key values) "i64_1_bool_1_none")
          (and
            (match (spec-value-subst-value value-subs "flag")
              [(CtfeBool flag) flag]
              [_ false])
            (ctfe-type-eq (spec-type-subst-type type-subs "U") (AstTyBool))))))))

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
  "(comptime-decl (:generated stdlib/hashmap-family StringStringMap (type-key (type String)) (type-key (type String)) \"stdlib/hashmap/string-key-v1\")
  (defstruct StringStringMap (__hashmap_family_request i64)))
(comptime-decl (:generated stdlib/hashmap-family I64I64Map (type-key (type i64)) (type-key (type i64)) \"stdlib/hashmap/i64-key-v1\")
  (defstruct I64I64Map (__hashmap_family_request i64)))
(comptime-decl (:generated stdlib/hashmap-family I64StringMap (type-key (type i64)) (type-key (type String)) \"stdlib/hashmap/i64-key-v1\")
  (defstruct I64StringMap (__hashmap_family_request i64)))
(comptime-decl (:generated stdlib/hashmap-family I64StringMap (type-key (type i64)) (type-key (type String)) \"stdlib/hashmap/i64-key-v1\")
  (defstruct I64StringMap (__hashmap_family_request i64)))")

(define (compiler-generated-hashmap-family-unsupported-key-source) : String
  "(comptime-decl (:generated stdlib/hashmap-family BoolStringMap (type-key (type bool)) (type-key (type String)) \"stdlib/hashmap/i64-key-v1\")
  (defstruct BoolStringMap (__hashmap_family_request i64)))")

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
                  (and
                    (= option-helper-count 1)
                    (and
                      (= result-count 1)
                      (and (= result-helper-count 1) (= nominal-result-count 1))))))])]
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
                  (and
                    (= box-count 1)
                    (and (= maybe-count 1) (= score-count 1))))])]
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
                  [len-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "i64-string-map-len")]
                  [put-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "i64-string-map-put")]
                  [string-map-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "StringStringMap")]
                  [string-borrowed-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "string-string-map-get-borrowed")]
                  [i64-map-count : i64
                    (compiler-specialize-decl-list-count-visible
                      decls
                      "I64I64Map")]
                  [i64-put-count : i64
                    (compiler-specialize-decl-list-count-defs
                      decls
                      "i64-i64-map-put")]
                  (and
                    (= slot-count 1)
                    (and
                      (= map-count 1)
                      (and
                        (= entry-count 1)
                        (and
                          (= len-count 1)
                          (and
                            (= put-count 1)
                            (and
                              (= string-map-count 1)
                              (and
                                (= string-borrowed-count 1)
                                (and (= i64-map-count 1) (= i64-put-count 1))))))))))])]
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
                              (and
                                (string-eq item "Option_String")
                                (string-eq
                                  key
                                  (compiler-generated-decl-expected-string-key))))]
                          [(AstNoGeneratedDeclMeta) false])
                        (match (box-get template-box)
                          [(AstDeclDefStruct name _ _ _)
                            (string-eq name "Option_String")]
                          [_ false]))]
                    [_ false])]
                [(AstDeclNil) false])])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-specialize-self-test) : i64
  (begin
    (unless (compiler-specialize-type-param-ok?) (return 0))
    (unless (compiler-specialize-runtime-type-use-rejected?) (return 0))
    (unless (compiler-specialize-template-shadow-ok?) (return 0))
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
    (unless (compiler-generated-hashmap-family-bundle-ok?) (return 0))
    (unless
      (compiler-generated-hashmap-family-unsupported-key-rejected?)
      (return 0))
    (unless (compiler-generated-decl-origin-preserved-ok?) (return 0))
    1))