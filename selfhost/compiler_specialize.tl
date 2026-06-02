;; compiler_specialize.tl - Selfhost comptime function specialization (#832).
(import "../stdlib/io.tl")

(import "compiler_ctfe.tl")

(import "compiler_diagnostic.tl")

(import "compiler_parse_core.tl")

(defenum SpecTemplate
  (SpecTemplate String AstParamList AstType AstExpr))

(defenum SpecTemplateList
  (SpecTemplateNil)
  (SpecTemplateCons SpecTemplate SpecTemplateList))

(defenum SpecCache
  (SpecCacheNil)
  (SpecCacheCons String String SpecCache))

(defenum SpecState
  (SpecState AstDeclList SpecCache CtfeEnv))

(defenum SpecValueList
  (SpecValueNil)
  (SpecValueCons CompilerCtfeValue SpecValueList))

(defenum SpecValueSubst
  (SpecValueSubstNil)
  (SpecValueSubstCons String CompilerCtfeValue SpecValueSubst))

(defenum SpecTypeSubst
  (SpecTypeSubstNil)
  (SpecTypeSubstCons String AstType SpecTypeSubst))

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
      (if (spec-param-comptime? param)
        true
        (spec-param-list-has-comptime? rest))]))

(define (spec-template-lookup [templates : SpecTemplateList] [name : String]) : SpecMaybeTemplate
  (match templates
    [(SpecTemplateNil) (SpecNoTemplate)]
    [(SpecTemplateCons template rest)
      (match template
        [(SpecTemplate template-name _ _ _)
          (if (string-eq template-name name)
            (SpecSomeTemplate template)
            (spec-template-lookup rest name))])]))

(define (spec-template-list-remove-name
  [templates : SpecTemplateList]
  [name : String]) : SpecTemplateList
  (match templates
    [(SpecTemplateNil) (SpecTemplateNil)]
    [(SpecTemplateCons template rest)
      (match template
        [(SpecTemplate template-name _ _ _)
          (if (string-eq template-name name)
            (spec-template-list-remove-name rest name)
            (SpecTemplateCons
              template
              (spec-template-list-remove-name rest name)))])]))

(define (spec-template-list-remove-params
  [templates : SpecTemplateList]
  [params : AstParamList]) : SpecTemplateList
  (match params
    [(AstParamNil) templates]
    [(AstParamCons param rest)
      (spec-template-list-remove-params
        (spec-template-list-remove-name templates (spec-param-name param))
        rest)]))

(define (spec-template-list-remove-let-binding-names
  [templates : SpecTemplateList]
  [bindings : AstLetBindingList]) : SpecTemplateList
  (match bindings
    [(AstLetBindingNil) templates]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name _ _)
          (spec-template-list-remove-let-binding-names
            (spec-template-list-remove-name templates name)
            rest)])]))

(define (spec-template-list-remove-pattern
  [templates : SpecTemplateList]
  [pattern : AstPattern]) : SpecTemplateList
  (match pattern
    [(AstPatVar name _) (spec-template-list-remove-name templates name)]
    [(AstPatTuple patterns)
      (spec-template-list-remove-pattern-list templates patterns)]
    [(AstPatWildcard) templates]
    [(AstPatBinding name) (spec-template-list-remove-name templates name)]
    [(AstPatVariant _ patterns)
      (spec-template-list-remove-pattern-list templates patterns)]
    [(AstPatLiteral _) templates]))

(define (spec-template-list-remove-pattern-list
  [templates : SpecTemplateList]
  [patterns : AstPatternList]) : SpecTemplateList
  (match patterns
    [(AstPatternNil) templates]
    [(AstPatternCons pattern rest)
      (spec-template-list-remove-pattern-list
        (spec-template-list-remove-pattern templates pattern)
        rest)]))

(define (spec-collect-templates [decls : AstDeclList]) : SpecTemplateList
  (match decls
    [(AstDeclNil) (SpecTemplateNil)]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclDefFn name params ret body)
          (if (spec-param-list-has-comptime? params)
            (SpecTemplateCons
              (SpecTemplate name params ret body)
              (spec-collect-templates rest))
            (spec-collect-templates rest))]
        [_ (spec-collect-templates rest)])]))

(define (spec-cache-lookup [cache : SpecCache] [key : String]) : SpecMaybeString
  (match cache
    [(SpecCacheNil) (SpecNoString)]
    [(SpecCacheCons cached-key name rest)
      (if (string-eq cached-key key)
        (SpecSomeString name)
        (spec-cache-lookup rest key))]))

(define (spec-decl-list-append-one [decls : AstDeclList] [decl : AstDecl]) : AstDeclList
  (match decls
    [(AstDeclNil) (AstDeclCons decl AstDeclNil)]
    [(AstDeclCons head rest)
      (AstDeclCons head (spec-decl-list-append-one rest decl))]))

(define (spec-decl-list-append [front : AstDeclList] [back : AstDeclList]) : AstDeclList
  (match front
    [(AstDeclNil) back]
    [(AstDeclCons head rest)
      (AstDeclCons head (spec-decl-list-append rest back))]))

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
      (string-append
        (spec-type-key head)
        (string-append "_" (spec-type-list-key rest)))]))

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
          (string-append "_to_" (spec-type-key ret))))]
    [(AstTyTuple elems) (string-append "tuple_" (spec-type-list-key elems))]
    [(AstTyArray elem count)
      (string-append
        "array_"
        (string-append
          (spec-type-key elem)
          (string-append "_" (spec-int-key count))))]
    [(AstTyDynArray elem) (string-append "dynarray_" (spec-type-key elem))]
    [(AstTyBox elem) (string-append "box_" (spec-type-key elem))]
    [(AstTyPtr elem) (string-append "ptr_" (spec-type-key elem))]
    [(AstTyMutPtr elem) (string-append "mutptr_" (spec-type-key elem))]
    [(AstTyRef region inner)
      (string-append
        "ref_"
        (string-append region (string-append "_" (spec-type-key inner))))]
    [(AstTyMutRef region inner)
      (string-append
        "mutref_"
        (string-append region (string-append "_" (spec-type-key inner))))]
    [(AstTyRegion region inner)
      (string-append
        "region_"
        (string-append region (string-append "_" (spec-type-key inner))))]
    [(AstTyEnum name) (string-append "enum_" name)]
    [(AstTyStruct name) (string-append "struct_" name)]
    [(AstTyVar name) (string-append "var_" name)]))

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
        (string-append "_" (spec-values-key rest)))]))

(define (spec-specialization-key [name : String] [values : SpecValueList]) : String
  (string-append name (string-append ":" (spec-values-key values))))

(define (spec-specialized-name [name : String] [values : SpecValueList]) : String
  (string-append
    "__tl_specialized_"
    (string-append name (string-append "_" (spec-values-key values)))))

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
        (spec-type-subst-lookup rest name))]))

(define (spec-type-subst-type [subs : SpecTypeSubst] [name : String]) : AstType
  (match subs
    [(SpecTypeSubstNil) (AstTyVar name)]
    [(SpecTypeSubstCons key ty rest)
      (if (string-eq key name)
        ty
        (spec-type-subst-type rest name))]))

(define (spec-value-subst-lookup [subs : SpecValueSubst] [name : String]) : SpecMaybeString
  (match subs
    [(SpecValueSubstNil) (SpecNoString)]
    [(SpecValueSubstCons key _ rest)
      (if (string-eq key name)
        (SpecSomeString key)
        (spec-value-subst-lookup rest name))]))

(define (spec-value-subst-value [subs : SpecValueSubst] [name : String]) : CompilerCtfeValue
  (match subs
    [(SpecValueSubstNil) (CtfeUnit)]
    [(SpecValueSubstCons key value rest)
      (if (string-eq key name)
        value
        (spec-value-subst-value rest name))]))

(define (spec-value-subst-remove-name [subs : SpecValueSubst] [name : String]) : SpecValueSubst
  (match subs
    [(SpecValueSubstNil) SpecValueSubstNil]
    [(SpecValueSubstCons key value rest)
      (if (string-eq key name)
        (spec-value-subst-remove-name rest name)
        (SpecValueSubstCons key value (spec-value-subst-remove-name rest name)))]))

(define (spec-value-subst-remove-params
  [subs : SpecValueSubst]
  [params : AstParamList]) : SpecValueSubst
  (match params
    [(AstParamNil) subs]
    [(AstParamCons param rest)
      (spec-value-subst-remove-params
        (spec-value-subst-remove-name subs (spec-param-name param))
        rest)]))

(define (spec-value-subst-remove-let-binding-names
  [subs : SpecValueSubst]
  [bindings : AstLetBindingList]) : SpecValueSubst
  (match bindings
    [(AstLetBindingNil) subs]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name _ _)
          (spec-value-subst-remove-let-binding-names
            (spec-value-subst-remove-name subs name)
            rest)])]))

(define (spec-value-subst-remove-pattern
  [subs : SpecValueSubst]
  [pattern : AstPattern]) : SpecValueSubst
  (match pattern
    [(AstPatVar name _) (spec-value-subst-remove-name subs name)]
    [(AstPatTuple patterns)
      (spec-value-subst-remove-pattern-list subs patterns)]
    [(AstPatWildcard) subs]
    [(AstPatBinding name) (spec-value-subst-remove-name subs name)]
    [(AstPatVariant _ patterns)
      (spec-value-subst-remove-pattern-list subs patterns)]
    [(AstPatLiteral _) subs]))

(define (spec-value-subst-remove-pattern-list
  [subs : SpecValueSubst]
  [patterns : AstPatternList]) : SpecValueSubst
  (match patterns
    [(AstPatternNil) subs]
    [(AstPatternCons pattern rest)
      (spec-value-subst-remove-pattern-list
        (spec-value-subst-remove-pattern subs pattern)
        rest)]))

(define (spec-type-subst-remove-name [subs : SpecTypeSubst] [name : String]) : SpecTypeSubst
  (match subs
    [(SpecTypeSubstNil) SpecTypeSubstNil]
    [(SpecTypeSubstCons key ty rest)
      (if (string-eq key name)
        (spec-type-subst-remove-name rest name)
        (SpecTypeSubstCons key ty (spec-type-subst-remove-name rest name)))]))

(define (spec-type-subst-remove-params
  [subs : SpecTypeSubst]
  [params : AstParamList]) : SpecTypeSubst
  (match params
    [(AstParamNil) subs]
    [(AstParamCons param rest)
      (spec-type-subst-remove-params
        (spec-type-subst-remove-name subs (spec-param-name param))
        rest)]))

(define (spec-type-subst-remove-let-binding-names
  [subs : SpecTypeSubst]
  [bindings : AstLetBindingList]) : SpecTypeSubst
  (match bindings
    [(AstLetBindingNil) subs]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name _ _)
          (spec-type-subst-remove-let-binding-names
            (spec-type-subst-remove-name subs name)
            rest)])]))

(define (spec-type-subst-remove-pattern
  [subs : SpecTypeSubst]
  [pattern : AstPattern]) : SpecTypeSubst
  (match pattern
    [(AstPatVar name _) (spec-type-subst-remove-name subs name)]
    [(AstPatTuple patterns) (spec-type-subst-remove-pattern-list subs patterns)]
    [(AstPatWildcard) subs]
    [(AstPatBinding name) (spec-type-subst-remove-name subs name)]
    [(AstPatVariant _ patterns)
      (spec-type-subst-remove-pattern-list subs patterns)]
    [(AstPatLiteral _) subs]))

(define (spec-type-subst-remove-pattern-list
  [subs : SpecTypeSubst]
  [patterns : AstPatternList]) : SpecTypeSubst
  (match patterns
    [(AstPatternNil) subs]
    [(AstPatternCons pattern rest)
      (spec-type-subst-remove-pattern-list
        (spec-type-subst-remove-pattern subs pattern)
        rest)]))

(define (spec-substitute-type [ty : AstType] [subs : SpecTypeSubst]) : AstType
  (match ty
    [(AstTyFunc args ret)
      (AstTyFunc
        (spec-substitute-type-list args subs)
        (spec-substitute-type ret subs))]
    [(AstTyTuple elems) (AstTyTuple (spec-substitute-type-list elems subs))]
    [(AstTyArray elem count)
      (AstTyArray (spec-substitute-type elem subs) count)]
    [(AstTyDynArray elem) (AstTyDynArray (spec-substitute-type elem subs))]
    [(AstTyBox elem) (AstTyBox (spec-substitute-type elem subs))]
    [(AstTyPtr elem) (AstTyPtr (spec-substitute-type elem subs))]
    [(AstTyMutPtr elem) (AstTyMutPtr (spec-substitute-type elem subs))]
    [(AstTyRef region inner)
      (AstTyRef region (spec-substitute-type inner subs))]
    [(AstTyMutRef region inner)
      (AstTyMutRef region (spec-substitute-type inner subs))]
    [(AstTyRegion region inner)
      (AstTyRegion region (spec-substitute-type inner subs))]
    [(AstTyVar name)
      (match (spec-type-subst-lookup subs name)
        [(SpecSomeString _) (spec-type-subst-type subs name)]
        [(SpecNoString) ty])]
    [_ ty]))

(define (spec-substitute-type-list [types : AstTypeList] [subs : SpecTypeSubst]) : AstTypeList
  (match types
    [(AstTypeNil) AstTypeNil]
    [(AstTypeCons head rest)
      (AstTypeCons
        (spec-substitute-type head subs)
        (spec-substitute-type-list rest subs))]))

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
      (match param
        [(AstParam name ty _)
          (AstParamCons
            (AstParam name (spec-substitute-type ty subs) false)
            (spec-substitute-param-types rest subs))])]))

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
      (match (spec-rewrite-expr head templates state)
        [(OkSpecExpr rewritten-head head-state)
          (match (spec-rewrite-expr-list rest templates head-state)
            [(OkSpecExprList rewritten-rest rest-state)
              (OkSpecExprList
                (AstExprCons rewritten-head rewritten-rest)
                rest-state)]
            [(ErrSpecExprList diag) (ErrSpecExprList diag)])]
        [(ErrSpecExpr diag) (ErrSpecExprList diag)])]))

(define (spec-rewrite-let-bindings
  [bindings : AstLetBindingList]
  [templates : SpecTemplateList]
  [state : SpecState]) : ResultSpecLetBindingList
  (match bindings
    [(AstLetBindingNil) (OkSpecLetBindingList AstLetBindingNil state)]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name ty value)
          (match (spec-rewrite-expr value templates state)
            [(OkSpecExpr rewritten-value value-state)
              (match (spec-rewrite-let-bindings
                rest
                (spec-template-list-remove-name templates name)
                value-state)
                [(OkSpecLetBindingList rewritten-rest rest-state)
                  (OkSpecLetBindingList
                    (AstLetBindingCons
                      (AstLetBinding name ty rewritten-value)
                      rewritten-rest)
                    rest-state)]
                [(ErrSpecLetBindingList diag) (ErrSpecLetBindingList diag)])]
            [(ErrSpecExpr diag) (ErrSpecLetBindingList diag)])])]))

(define (spec-rewrite-match-arms
  [arms : AstMatchArmList]
  [templates : SpecTemplateList]
  [state : SpecState]) : ResultSpecMatchArmList
  (match arms
    [(AstMatchArmNil) (OkSpecMatchArmList AstMatchArmNil state)]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pattern body)
          (match (spec-rewrite-expr
            body
            (spec-template-list-remove-pattern templates pattern)
            state)
            [(OkSpecExpr rewritten-body body-state)
              (match (spec-rewrite-match-arms rest templates body-state)
                [(OkSpecMatchArmList rewritten-rest rest-state)
                  (OkSpecMatchArmList
                    (AstMatchArmCons
                      (AstMatchArm pattern rewritten-body)
                      rewritten-rest)
                    rest-state)]
                [(ErrSpecMatchArmList diag) (ErrSpecMatchArmList diag)])]
            [(ErrSpecExpr diag) (ErrSpecMatchArmList diag)])])]))

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
                (AstExprCall (AstExprVar specialized-name) runtime-args)
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
      (match args
        [(AstExprCons arg rest-args)
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
                            [(OkSpecArgs rest-values rest-runtime rest-state)
                              (OkSpecArgs
                                (SpecValueCons value rest-values)
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
                              (SpecValueCons value rest-values)
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
                          (AstExprCons rewritten-arg rest-runtime)
                          rest-state)]
                      [(ErrSpecArgs diag) (ErrSpecArgs diag)])]
                  [(ErrSpecExpr diag) (ErrSpecArgs diag)]))])]
        [_
          (ErrSpecArgs
            (compiler-diagnostic-at-start "" "specialize: arity mismatch"))])]))

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
      (match param
        [(AstParam name ty is-comptime)
          (if is-comptime
            (match values
              [(SpecValueCons value rest-values)
                (match (spec-build-specialization rest-params rest-values)
                  [(OkSpecBuild runtime value-subs type-subs)
                    (if (spec-type-kind? ty)
                      (match value
                        [(CtfeType actual-ty)
                          (OkSpecBuild
                            runtime
                            value-subs
                            (SpecTypeSubstCons name actual-ty type-subs))]
                        [_
                          (ErrSpecBuild
                            (compiler-diagnostic-at-start
                              ""
                              "specialize: expected type value"))])
                      (OkSpecBuild
                        runtime
                        (SpecValueSubstCons name value value-subs)
                        type-subs))]
                  [(ErrSpecBuild diag) (ErrSpecBuild diag)])]
              [_
                (ErrSpecBuild
                  (compiler-diagnostic-at-start "" "specialize: value mismatch"))])
            (match (spec-build-specialization rest-params values)
              [(OkSpecBuild runtime value-subs type-subs)
                (OkSpecBuild
                  (AstParamCons (AstParam name ty false) runtime)
                  value-subs
                  type-subs)]
              [(ErrSpecBuild diag) (ErrSpecBuild diag)]))])]))

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
                                    (SpecCacheCons key generated-name cache)
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
                                              (AstDeclDefFn
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
    [(AstExprSpanned inner span)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten rewritten-state)
          (OkSpecExpr (AstExprSpanned rewritten span) rewritten-state)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprLiteral _) (OkSpecExpr expr state)]
    [(AstExprVar _) (OkSpecExpr expr state)]
    [(AstExprTypeLiteral _) (OkSpecExpr expr state)]
    [(AstExprBinary op left right)
      (match (spec-rewrite-expr left templates state)
        [(OkSpecExpr rewritten-left left-state)
          (match (spec-rewrite-expr right templates left-state)
            [(OkSpecExpr rewritten-right right-state)
              (OkSpecExpr
                (AstExprBinary op rewritten-left rewritten-right)
                right-state)]
            [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprUnary op inner)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten rewritten-state)
          (OkSpecExpr (AstExprUnary op rewritten) rewritten-state)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprCall func args)
      (match (spec-expr-var-name func)
        [(SpecSomeString name)
          (match (spec-template-lookup templates name)
            [(SpecSomeTemplate template)
              (spec-rewrite-specialized-call template args templates state expr)]
            [(SpecNoTemplate)
              (match (spec-rewrite-expr func templates state)
                [(OkSpecExpr rewritten-func func-state)
                  (match (spec-rewrite-expr-list args templates func-state)
                    [(OkSpecExprList rewritten-args args-state)
                      (OkSpecExpr
                        (AstExprCall rewritten-func rewritten-args)
                        args-state)]
                    [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
                [(ErrSpecExpr diag) (ErrSpecExpr diag)])])]
        [(SpecNoString)
          (match (spec-rewrite-expr func templates state)
            [(OkSpecExpr rewritten-func func-state)
              (match (spec-rewrite-expr-list args templates func-state)
                [(OkSpecExprList rewritten-args args-state)
                  (OkSpecExpr
                    (AstExprCall rewritten-func rewritten-args)
                    args-state)]
                [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
            [(ErrSpecExpr diag) (ErrSpecExpr diag)])])]
    [(AstExprIf cond then-branch else-branch)
      (match (spec-rewrite-expr cond templates state)
        [(OkSpecExpr rewritten-cond cond-state)
          (match (spec-rewrite-expr then-branch templates cond-state)
            [(OkSpecExpr rewritten-then then-state)
              (match (spec-rewrite-expr else-branch templates then-state)
                [(OkSpecExpr rewritten-else else-state)
                  (OkSpecExpr
                    (AstExprIf rewritten-cond rewritten-then rewritten-else)
                    else-state)]
                [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
            [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprLet bindings body)
      (match (spec-rewrite-let-bindings bindings templates state)
        [(OkSpecLetBindingList rewritten-bindings binding-state)
          (match (spec-rewrite-expr
            body
            (spec-template-list-remove-let-binding-names templates bindings)
            binding-state)
            [(OkSpecExpr rewritten-body body-state)
              (OkSpecExpr
                (AstExprLet rewritten-bindings rewritten-body)
                body-state)]
            [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
        [(ErrSpecLetBindingList diag) (ErrSpecExpr diag)])]
    [(AstExprLambda params ret body)
      (match (spec-rewrite-expr
        body
        (spec-template-list-remove-params templates params)
        state)
        [(OkSpecExpr rewritten-body body-state)
          (OkSpecExpr (AstExprLambda params ret rewritten-body) body-state)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprTuple exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(OkSpecExprList rewritten state2)
          (OkSpecExpr (AstExprTuple rewritten) state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprTupleRef inner index)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprTupleRef rewritten index) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprArray exprs)
      (match (spec-rewrite-expr-list exprs templates state)
        [(OkSpecExprList rewritten state2)
          (OkSpecExpr (AstExprArray rewritten) state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprMakeArray elem-ty len)
      (match (spec-rewrite-expr len templates state)
        [(OkSpecExpr rewritten-len state2)
          (OkSpecExpr (AstExprMakeArray elem-ty rewritten-len) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprArrayRef array index)
      (match (spec-rewrite-expr array templates state)
        [(OkSpecExpr rewritten-array array-state)
          (match (spec-rewrite-expr index templates array-state)
            [(OkSpecExpr rewritten-index index-state)
              (OkSpecExpr
                (AstExprArrayRef rewritten-array rewritten-index)
                index-state)]
            [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprArraySet array index value)
      (match (spec-rewrite-expr array templates state)
        [(OkSpecExpr rewritten-array array-state)
          (match (spec-rewrite-expr index templates array-state)
            [(OkSpecExpr rewritten-index index-state)
              (match (spec-rewrite-expr value templates index-state)
                [(OkSpecExpr rewritten-value value-state)
                  (OkSpecExpr
                    (AstExprArraySet
                      rewritten-array
                      rewritten-index
                      rewritten-value)
                    value-state)]
                [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
            [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprArrayPush array value)
      (match (spec-rewrite-expr array templates state)
        [(OkSpecExpr rewritten-array array-state)
          (match (spec-rewrite-expr value templates array-state)
            [(OkSpecExpr rewritten-value value-state)
              (OkSpecExpr
                (AstExprArrayPush rewritten-array rewritten-value)
                value-state)]
            [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprStringRef text index)
      (match (spec-rewrite-expr text templates state)
        [(OkSpecExpr rewritten-text text-state)
          (match (spec-rewrite-expr index templates text-state)
            [(OkSpecExpr rewritten-index index-state)
              (OkSpecExpr
                (AstExprStringRef rewritten-text rewritten-index)
                index-state)]
            [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprWhile cond body)
      (match (spec-rewrite-expr cond templates state)
        [(OkSpecExpr rewritten-cond cond-state)
          (match (spec-rewrite-expr body templates cond-state)
            [(OkSpecExpr rewritten-body body-state)
              (OkSpecExpr
                (AstExprWhile rewritten-cond rewritten-body)
                body-state)]
            [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
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
    [(AstExprSet name value)
      (match (spec-rewrite-expr value templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprSet name rewritten) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprAnn inner ty)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprAnn rewritten ty) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprCast inner ty)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprCast rewritten ty) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprMatch scrutinee arms)
      (match (spec-rewrite-expr scrutinee templates state)
        [(OkSpecExpr rewritten-scrutinee scrutinee-state)
          (match (spec-rewrite-match-arms arms templates scrutinee-state)
            [(OkSpecMatchArmList rewritten-arms arms-state)
              (OkSpecExpr
                (AstExprMatch rewritten-scrutinee rewritten-arms)
                arms-state)]
            [(ErrSpecMatchArmList diag) (ErrSpecExpr diag)])]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprForeach index index-ty start end body)
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
                    (AstExprForeach
                      index
                      index-ty
                      rewritten-start
                      rewritten-end
                      rewritten-body)
                    body-state)]
                [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
            [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprSpmdReduce op index index-ty start end init value)
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
                        (AstExprSpmdReduce
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
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprStructGet receiver field)
      (match (spec-rewrite-expr receiver templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprStructGet rewritten field) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprWithRegion region body)
      (match (spec-rewrite-expr-list body templates state)
        [(OkSpecExprList rewritten state2)
          (OkSpecExpr (AstExprWithRegion region rewritten) state2)]
        [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
    [(AstExprWithEscape scratch body)
      (match (spec-rewrite-expr scratch templates state)
        [(OkSpecExpr rewritten-scratch scratch-state)
          (match (spec-rewrite-expr-list body templates scratch-state)
            [(OkSpecExprList rewritten-body body-state)
              (OkSpecExpr
                (AstExprWithEscape rewritten-scratch rewritten-body)
                body-state)]
            [(ErrSpecExprList diag) (ErrSpecExpr diag)])]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprWithResource bindings body)
      (OkSpecExpr (AstExprWithResource bindings body) state)]
    [(AstExprBox inner)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprBox rewritten) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprBoxGet inner)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprBoxGet rewritten) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprComptime inner)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprComptime rewritten) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprTry inner)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprTry rewritten) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprPtrNull ty) (OkSpecExpr (AstExprPtrNull ty) state)]
    [(AstExprPtrNullCheck inner)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprPtrNullCheck rewritten) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprPtrRead ptr)
      (match (spec-rewrite-expr ptr templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprPtrRead rewritten) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprPtrWrite ptr value)
      (match (spec-rewrite-expr ptr templates state)
        [(OkSpecExpr rewritten-ptr ptr-state)
          (match (spec-rewrite-expr value templates ptr-state)
            [(OkSpecExpr rewritten-value value-state)
              (OkSpecExpr
                (AstExprPtrWrite rewritten-ptr rewritten-value)
                value-state)]
            [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprPtrOffset ptr offset)
      (match (spec-rewrite-expr ptr templates state)
        [(OkSpecExpr rewritten-ptr ptr-state)
          (match (spec-rewrite-expr offset templates ptr-state)
            [(OkSpecExpr rewritten-offset offset-state)
              (OkSpecExpr
                (AstExprPtrOffset rewritten-ptr rewritten-offset)
                offset-state)]
            [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprPtrCast ptr ty)
      (match (spec-rewrite-expr ptr templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprPtrCast rewritten ty) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprPtrToInt ptr)
      (match (spec-rewrite-expr ptr templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprPtrToInt rewritten) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprIntToPtr value ty)
      (match (spec-rewrite-expr value templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprIntToPtr rewritten ty) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprQuote inner)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprQuote rewritten) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprQuasiquote inner)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprQuasiquote rewritten) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprUnquote inner)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprUnquote rewritten) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprUnquoteSplicing inner)
      (match (spec-rewrite-expr inner templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecExpr (AstExprUnquoteSplicing rewritten) state2)]
        [(ErrSpecExpr diag) (ErrSpecExpr diag)])]
    [(AstExprBorrow _ _) (OkSpecExpr expr state)]))

(define (spec-substitute-values-expr [expr : AstExpr] [subs : SpecValueSubst]) : ResultSpecSubExpr
  (match expr
    [(AstExprSpanned inner span)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprSpanned rewritten span))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprVar name)
      (match (spec-value-subst-lookup subs name)
        [(SpecSomeString _)
          (spec-ctfe-value-to-expr (spec-value-subst-value subs name) expr)]
        [(SpecNoString) (OkSpecSubExpr expr)])]
    [(AstExprLiteral _) (OkSpecSubExpr expr)]
    [(AstExprTypeLiteral _) (OkSpecSubExpr expr)]
    [(AstExprBinary op left right)
      (match (spec-substitute-values-expr left subs)
        [(OkSpecSubExpr rewritten-left)
          (match (spec-substitute-values-expr right subs)
            [(OkSpecSubExpr rewritten-right)
              (OkSpecSubExpr (AstExprBinary op rewritten-left rewritten-right))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprUnary op inner)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprUnary op rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprCall func args)
      (match (spec-substitute-values-expr func subs)
        [(OkSpecSubExpr rewritten-func)
          (match (spec-substitute-values-expr-list args subs)
            [(OkSpecSubExprList rewritten-args)
              (OkSpecSubExpr (AstExprCall rewritten-func rewritten-args))]
            [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprIf cond then-branch else-branch)
      (match (spec-substitute-values-expr cond subs)
        [(OkSpecSubExpr rewritten-cond)
          (match (spec-substitute-values-expr then-branch subs)
            [(OkSpecSubExpr rewritten-then)
              (match (spec-substitute-values-expr else-branch subs)
                [(OkSpecSubExpr rewritten-else)
                  (OkSpecSubExpr
                    (AstExprIf rewritten-cond rewritten-then rewritten-else))]
                [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprLet bindings body)
      (match (spec-substitute-values-let-bindings bindings subs)
        [(OkSpecSubLetBindingList rewritten-bindings)
          (match (spec-substitute-values-expr
            body
            (spec-value-subst-remove-let-binding-names subs bindings))
            [(OkSpecSubExpr rewritten-body)
              (OkSpecSubExpr (AstExprLet rewritten-bindings rewritten-body))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubLetBindingList diag) (ErrSpecSubExpr diag)])]
    [(AstExprLambda params ret body)
      (match (spec-substitute-values-expr
        body
        (spec-value-subst-remove-params subs params))
        [(OkSpecSubExpr rewritten-body)
          (OkSpecSubExpr (AstExprLambda params ret rewritten-body))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprTuple exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(OkSpecSubExprList rewritten) (OkSpecSubExpr (AstExprTuple rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprTupleRef inner index)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprTupleRef rewritten index))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprArray exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(OkSpecSubExprList rewritten) (OkSpecSubExpr (AstExprArray rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprMakeArray elem-ty len)
      (match (spec-substitute-values-expr len subs)
        [(OkSpecSubExpr rewritten-len)
          (OkSpecSubExpr (AstExprMakeArray elem-ty rewritten-len))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprArrayRef array index)
      (match (spec-substitute-values-expr array subs)
        [(OkSpecSubExpr rewritten-array)
          (match (spec-substitute-values-expr index subs)
            [(OkSpecSubExpr rewritten-index)
              (OkSpecSubExpr (AstExprArrayRef rewritten-array rewritten-index))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprArraySet array index value)
      (match (spec-substitute-values-expr array subs)
        [(OkSpecSubExpr rewritten-array)
          (match (spec-substitute-values-expr index subs)
            [(OkSpecSubExpr rewritten-index)
              (match (spec-substitute-values-expr value subs)
                [(OkSpecSubExpr rewritten-value)
                  (OkSpecSubExpr
                    (AstExprArraySet
                      rewritten-array
                      rewritten-index
                      rewritten-value))]
                [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprArrayPush array value)
      (match (spec-substitute-values-expr array subs)
        [(OkSpecSubExpr rewritten-array)
          (match (spec-substitute-values-expr value subs)
            [(OkSpecSubExpr rewritten-value)
              (OkSpecSubExpr (AstExprArrayPush rewritten-array rewritten-value))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprStringRef text index)
      (match (spec-substitute-values-expr text subs)
        [(OkSpecSubExpr rewritten-text)
          (match (spec-substitute-values-expr index subs)
            [(OkSpecSubExpr rewritten-index)
              (OkSpecSubExpr (AstExprStringRef rewritten-text rewritten-index))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprWhile cond body)
      (match (spec-substitute-values-expr cond subs)
        [(OkSpecSubExpr rewritten-cond)
          (match (spec-substitute-values-expr body subs)
            [(OkSpecSubExpr rewritten-body)
              (OkSpecSubExpr (AstExprWhile rewritten-cond rewritten-body))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprBegin exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(OkSpecSubExprList rewritten) (OkSpecSubExpr (AstExprBegin rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprUnsafe exprs)
      (match (spec-substitute-values-expr-list exprs subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (AstExprUnsafe rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprSet name value)
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
              (OkSpecSubExpr (AstExprSet name rewritten))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])])]
    [(AstExprAnn inner ty)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprAnn rewritten ty))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprCast inner ty)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprCast rewritten ty))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprMatch scrutinee arms)
      (match (spec-substitute-values-expr scrutinee subs)
        [(OkSpecSubExpr rewritten-scrutinee)
          (match (spec-substitute-values-match-arms arms subs)
            [(OkSpecSubMatchArmList rewritten-arms)
              (OkSpecSubExpr (AstExprMatch rewritten-scrutinee rewritten-arms))]
            [(ErrSpecSubMatchArmList diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprForeach index index-ty start end body)
      (match (spec-substitute-values-expr start subs)
        [(OkSpecSubExpr rewritten-start)
          (match (spec-substitute-values-expr end subs)
            [(OkSpecSubExpr rewritten-end)
              (match (spec-substitute-values-expr
                body
                (spec-value-subst-remove-name subs index))
                [(OkSpecSubExpr rewritten-body)
                  (OkSpecSubExpr
                    (AstExprForeach
                      index
                      index-ty
                      rewritten-start
                      rewritten-end
                      rewritten-body))]
                [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprSpmdReduce op index index-ty start end init value)
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
                        (AstExprSpmdReduce
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
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprStructGet receiver field)
      (match (spec-substitute-values-expr receiver subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprStructGet rewritten field))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprWithRegion region body)
      (match (spec-substitute-values-expr-list body subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (AstExprWithRegion region rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprWithEscape scratch body)
      (match (spec-substitute-values-expr scratch subs)
        [(OkSpecSubExpr rewritten-scratch)
          (match (spec-substitute-values-expr-list body subs)
            [(OkSpecSubExprList rewritten-body)
              (OkSpecSubExpr
                (AstExprWithEscape rewritten-scratch rewritten-body))]
            [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprWithResource bindings body)
      (OkSpecSubExpr (AstExprWithResource bindings body))]
    [(AstExprBox inner)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprBox rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprBoxGet inner)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprBoxGet rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprComptime inner)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprComptime rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprTry inner)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprTry rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprPtrNull ty) (OkSpecSubExpr (AstExprPtrNull ty))]
    [(AstExprPtrNullCheck inner)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprPtrNullCheck rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprPtrRead ptr)
      (match (spec-substitute-values-expr ptr subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprPtrRead rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprPtrWrite ptr value)
      (match (spec-substitute-values-expr ptr subs)
        [(OkSpecSubExpr rewritten-ptr)
          (match (spec-substitute-values-expr value subs)
            [(OkSpecSubExpr rewritten-value)
              (OkSpecSubExpr (AstExprPtrWrite rewritten-ptr rewritten-value))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprPtrOffset ptr offset)
      (match (spec-substitute-values-expr ptr subs)
        [(OkSpecSubExpr rewritten-ptr)
          (match (spec-substitute-values-expr offset subs)
            [(OkSpecSubExpr rewritten-offset)
              (OkSpecSubExpr (AstExprPtrOffset rewritten-ptr rewritten-offset))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprPtrCast ptr ty)
      (match (spec-substitute-values-expr ptr subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprPtrCast rewritten ty))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprPtrToInt ptr)
      (match (spec-substitute-values-expr ptr subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprPtrToInt rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprIntToPtr value ty)
      (match (spec-substitute-values-expr value subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprIntToPtr rewritten ty))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprQuote inner)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprQuote rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprQuasiquote inner)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprQuasiquote rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprUnquote inner)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprUnquote rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprUnquoteSplicing inner)
      (match (spec-substitute-values-expr inner subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprUnquoteSplicing rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprBorrow _ _) (OkSpecSubExpr expr)]))

(define (spec-substitute-values-expr-list
  [exprs : AstExprList]
  [subs : SpecValueSubst]) : ResultSpecSubExprList
  (match exprs
    [(AstExprNil) (OkSpecSubExprList AstExprNil)]
    [(AstExprCons head rest)
      (match (spec-substitute-values-expr head subs)
        [(OkSpecSubExpr rewritten-head)
          (match (spec-substitute-values-expr-list rest subs)
            [(OkSpecSubExprList rewritten-rest)
              (OkSpecSubExprList (AstExprCons rewritten-head rewritten-rest))]
            [(ErrSpecSubExprList diag) (ErrSpecSubExprList diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExprList diag)])]))

(define (spec-substitute-values-let-bindings
  [bindings : AstLetBindingList]
  [subs : SpecValueSubst]) : ResultSpecSubLetBindingList
  (match bindings
    [(AstLetBindingNil) (OkSpecSubLetBindingList AstLetBindingNil)]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name ty value)
          (match (spec-substitute-values-expr value subs)
            [(OkSpecSubExpr rewritten-value)
              (match (spec-substitute-values-let-bindings
                rest
                (spec-value-subst-remove-name subs name))
                [(OkSpecSubLetBindingList rewritten-rest)
                  (OkSpecSubLetBindingList
                    (AstLetBindingCons
                      (AstLetBinding name ty rewritten-value)
                      rewritten-rest))]
                [(ErrSpecSubLetBindingList diag)
                  (ErrSpecSubLetBindingList diag)])]
            [(ErrSpecSubExpr diag) (ErrSpecSubLetBindingList diag)])])]))

(define (spec-substitute-values-match-arms
  [arms : AstMatchArmList]
  [subs : SpecValueSubst]) : ResultSpecSubMatchArmList
  (match arms
    [(AstMatchArmNil) (OkSpecSubMatchArmList AstMatchArmNil)]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pattern body)
          (match (spec-substitute-values-expr
            body
            (spec-value-subst-remove-pattern subs pattern))
            [(OkSpecSubExpr rewritten-body)
              (match (spec-substitute-values-match-arms rest subs)
                [(OkSpecSubMatchArmList rewritten-rest)
                  (OkSpecSubMatchArmList
                    (AstMatchArmCons
                      (AstMatchArm pattern rewritten-body)
                      rewritten-rest))]
                [(ErrSpecSubMatchArmList diag) (ErrSpecSubMatchArmList diag)])]
            [(ErrSpecSubExpr diag) (ErrSpecSubMatchArmList diag)])])]))

(define (spec-substitute-types-expr [expr : AstExpr] [subs : SpecTypeSubst]) : ResultSpecSubExpr
  (match expr
    [(AstExprSpanned inner span)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprSpanned rewritten span))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
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
    [(AstExprMakeArray elem-ty len)
      (match (spec-substitute-types-expr len subs)
        [(OkSpecSubExpr rewritten-len)
          (OkSpecSubExpr
            (AstExprMakeArray (spec-substitute-type elem-ty subs) rewritten-len))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprAnn inner ty)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprAnn rewritten (spec-substitute-type ty subs)))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprCast inner ty)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprCast rewritten (spec-substitute-type ty subs)))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprLambda params ret body)
      (match (spec-substitute-types-expr
        body
        (spec-type-subst-remove-params subs params))
        [(OkSpecSubExpr rewritten-body)
          (OkSpecSubExpr
            (AstExprLambda
              (spec-substitute-param-types params subs)
              (spec-substitute-maybe-type ret subs)
              rewritten-body))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprForeach index index-ty start end body)
      (match (spec-substitute-types-expr start subs)
        [(OkSpecSubExpr rewritten-start)
          (match (spec-substitute-types-expr end subs)
            [(OkSpecSubExpr rewritten-end)
              (match (spec-substitute-types-expr
                body
                (spec-type-subst-remove-name subs index))
                [(OkSpecSubExpr rewritten-body)
                  (OkSpecSubExpr
                    (AstExprForeach
                      index
                      (spec-substitute-type index-ty subs)
                      rewritten-start
                      rewritten-end
                      rewritten-body))]
                [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprSpmdReduce op index index-ty start end init value)
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
                        (AstExprSpmdReduce
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
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprBinary op left right)
      (match (spec-substitute-types-expr left subs)
        [(OkSpecSubExpr rewritten-left)
          (match (spec-substitute-types-expr right subs)
            [(OkSpecSubExpr rewritten-right)
              (OkSpecSubExpr (AstExprBinary op rewritten-left rewritten-right))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprUnary op inner)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprUnary op rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprCall func args)
      (match (spec-substitute-types-expr func subs)
        [(OkSpecSubExpr rewritten-func)
          (match (spec-substitute-types-expr-list args subs)
            [(OkSpecSubExprList rewritten-args)
              (OkSpecSubExpr (AstExprCall rewritten-func rewritten-args))]
            [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprIf cond then-branch else-branch)
      (match (spec-substitute-types-expr cond subs)
        [(OkSpecSubExpr rewritten-cond)
          (match (spec-substitute-types-expr then-branch subs)
            [(OkSpecSubExpr rewritten-then)
              (match (spec-substitute-types-expr else-branch subs)
                [(OkSpecSubExpr rewritten-else)
                  (OkSpecSubExpr
                    (AstExprIf rewritten-cond rewritten-then rewritten-else))]
                [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprLet bindings body)
      (match (spec-substitute-types-let-bindings bindings subs)
        [(OkSpecSubLetBindingList rewritten-bindings)
          (match (spec-substitute-types-expr
            body
            (spec-type-subst-remove-let-binding-names subs bindings))
            [(OkSpecSubExpr rewritten-body)
              (OkSpecSubExpr (AstExprLet rewritten-bindings rewritten-body))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubLetBindingList diag) (ErrSpecSubExpr diag)])]
    [(AstExprTuple exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(OkSpecSubExprList rewritten) (OkSpecSubExpr (AstExprTuple rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprTupleRef inner index)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprTupleRef rewritten index))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprArray exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(OkSpecSubExprList rewritten) (OkSpecSubExpr (AstExprArray rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprArrayRef array index)
      (match (spec-substitute-types-expr array subs)
        [(OkSpecSubExpr rewritten-array)
          (match (spec-substitute-types-expr index subs)
            [(OkSpecSubExpr rewritten-index)
              (OkSpecSubExpr (AstExprArrayRef rewritten-array rewritten-index))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprArraySet array index value)
      (match (spec-substitute-types-expr array subs)
        [(OkSpecSubExpr rewritten-array)
          (match (spec-substitute-types-expr index subs)
            [(OkSpecSubExpr rewritten-index)
              (match (spec-substitute-types-expr value subs)
                [(OkSpecSubExpr rewritten-value)
                  (OkSpecSubExpr
                    (AstExprArraySet
                      rewritten-array
                      rewritten-index
                      rewritten-value))]
                [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprArrayPush array value)
      (match (spec-substitute-types-expr array subs)
        [(OkSpecSubExpr rewritten-array)
          (match (spec-substitute-types-expr value subs)
            [(OkSpecSubExpr rewritten-value)
              (OkSpecSubExpr (AstExprArrayPush rewritten-array rewritten-value))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprStringRef text index)
      (match (spec-substitute-types-expr text subs)
        [(OkSpecSubExpr rewritten-text)
          (match (spec-substitute-types-expr index subs)
            [(OkSpecSubExpr rewritten-index)
              (OkSpecSubExpr (AstExprStringRef rewritten-text rewritten-index))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprWhile cond body)
      (match (spec-substitute-types-expr cond subs)
        [(OkSpecSubExpr rewritten-cond)
          (match (spec-substitute-types-expr body subs)
            [(OkSpecSubExpr rewritten-body)
              (OkSpecSubExpr (AstExprWhile rewritten-cond rewritten-body))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprBegin exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(OkSpecSubExprList rewritten) (OkSpecSubExpr (AstExprBegin rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprUnsafe exprs)
      (match (spec-substitute-types-expr-list exprs subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (AstExprUnsafe rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprSet name value)
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
              (OkSpecSubExpr (AstExprSet name rewritten))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])])]
    [(AstExprMatch scrutinee arms)
      (match (spec-substitute-types-expr scrutinee subs)
        [(OkSpecSubExpr rewritten-scrutinee)
          (match (spec-substitute-types-match-arms arms subs)
            [(OkSpecSubMatchArmList rewritten-arms)
              (OkSpecSubExpr (AstExprMatch rewritten-scrutinee rewritten-arms))]
            [(ErrSpecSubMatchArmList diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprStructGet receiver field)
      (match (spec-substitute-types-expr receiver subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprStructGet rewritten field))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprWithRegion region body)
      (match (spec-substitute-types-expr-list body subs)
        [(OkSpecSubExprList rewritten)
          (OkSpecSubExpr (AstExprWithRegion region rewritten))]
        [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
    [(AstExprWithEscape scratch body)
      (match (spec-substitute-types-expr scratch subs)
        [(OkSpecSubExpr rewritten-scratch)
          (match (spec-substitute-types-expr-list body subs)
            [(OkSpecSubExprList rewritten-body)
              (OkSpecSubExpr
                (AstExprWithEscape rewritten-scratch rewritten-body))]
            [(ErrSpecSubExprList diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprWithResource bindings body)
      (OkSpecSubExpr (AstExprWithResource bindings body))]
    [(AstExprBox inner)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprBox rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprBoxGet inner)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprBoxGet rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprComptime inner)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprComptime rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprTry inner)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprTry rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprPtrNull ty)
      (OkSpecSubExpr (AstExprPtrNull (spec-substitute-type ty subs)))]
    [(AstExprPtrNullCheck inner)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprPtrNullCheck rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprPtrRead ptr)
      (match (spec-substitute-types-expr ptr subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprPtrRead rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprPtrWrite ptr value)
      (match (spec-substitute-types-expr ptr subs)
        [(OkSpecSubExpr rewritten-ptr)
          (match (spec-substitute-types-expr value subs)
            [(OkSpecSubExpr rewritten-value)
              (OkSpecSubExpr (AstExprPtrWrite rewritten-ptr rewritten-value))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprPtrOffset ptr offset)
      (match (spec-substitute-types-expr ptr subs)
        [(OkSpecSubExpr rewritten-ptr)
          (match (spec-substitute-types-expr offset subs)
            [(OkSpecSubExpr rewritten-offset)
              (OkSpecSubExpr (AstExprPtrOffset rewritten-ptr rewritten-offset))]
            [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprPtrCast ptr ty)
      (match (spec-substitute-types-expr ptr subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr
            (AstExprPtrCast rewritten (spec-substitute-type ty subs)))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprPtrToInt ptr)
      (match (spec-substitute-types-expr ptr subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprPtrToInt rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprIntToPtr value ty)
      (match (spec-substitute-types-expr value subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr
            (AstExprIntToPtr rewritten (spec-substitute-type ty subs)))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprQuote inner)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprQuote rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprQuasiquote inner)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprQuasiquote rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprUnquote inner)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten) (OkSpecSubExpr (AstExprUnquote rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprUnquoteSplicing inner)
      (match (spec-substitute-types-expr inner subs)
        [(OkSpecSubExpr rewritten)
          (OkSpecSubExpr (AstExprUnquoteSplicing rewritten))]
        [(ErrSpecSubExpr diag) (ErrSpecSubExpr diag)])]
    [(AstExprBorrow _ _) (OkSpecSubExpr expr)]))

(define (spec-substitute-types-expr-list
  [exprs : AstExprList]
  [subs : SpecTypeSubst]) : ResultSpecSubExprList
  (match exprs
    [(AstExprNil) (OkSpecSubExprList AstExprNil)]
    [(AstExprCons head rest)
      (match (spec-substitute-types-expr head subs)
        [(OkSpecSubExpr rewritten-head)
          (match (spec-substitute-types-expr-list rest subs)
            [(OkSpecSubExprList rewritten-rest)
              (OkSpecSubExprList (AstExprCons rewritten-head rewritten-rest))]
            [(ErrSpecSubExprList diag) (ErrSpecSubExprList diag)])]
        [(ErrSpecSubExpr diag) (ErrSpecSubExprList diag)])]))

(define (spec-substitute-types-let-bindings
  [bindings : AstLetBindingList]
  [subs : SpecTypeSubst]) : ResultSpecSubLetBindingList
  (match bindings
    [(AstLetBindingNil) (OkSpecSubLetBindingList AstLetBindingNil)]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name ty value)
          (match (spec-substitute-types-expr value subs)
            [(OkSpecSubExpr rewritten-value)
              (match (spec-substitute-types-let-bindings
                rest
                (spec-type-subst-remove-name subs name))
                [(OkSpecSubLetBindingList rewritten-rest)
                  (OkSpecSubLetBindingList
                    (AstLetBindingCons
                      (AstLetBinding
                        name
                        (spec-substitute-maybe-type ty subs)
                        rewritten-value)
                      rewritten-rest))]
                [(ErrSpecSubLetBindingList diag)
                  (ErrSpecSubLetBindingList diag)])]
            [(ErrSpecSubExpr diag) (ErrSpecSubLetBindingList diag)])])]))

(define (spec-substitute-types-match-arms
  [arms : AstMatchArmList]
  [subs : SpecTypeSubst]) : ResultSpecSubMatchArmList
  (match arms
    [(AstMatchArmNil) (OkSpecSubMatchArmList AstMatchArmNil)]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pattern body)
          (match (spec-substitute-types-expr
            body
            (spec-type-subst-remove-pattern subs pattern))
            [(OkSpecSubExpr rewritten-body)
              (match (spec-substitute-types-match-arms rest subs)
                [(OkSpecSubMatchArmList rewritten-rest)
                  (OkSpecSubMatchArmList
                    (AstMatchArmCons
                      (AstMatchArm pattern rewritten-body)
                      rewritten-rest))]
                [(ErrSpecSubMatchArmList diag) (ErrSpecSubMatchArmList diag)])]
            [(ErrSpecSubExpr diag) (ErrSpecSubMatchArmList diag)])])]))

(define (spec-rewrite-decl
  [decl : AstDecl]
  [templates : SpecTemplateList]
  [state : SpecState]) : ResultSpecDecl
  (match decl
    [(AstDeclDef name ty value)
      (match (spec-rewrite-expr value templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecDecl (SpecSomeDecl (AstDeclDef name ty rewritten)) state2)]
        [(ErrSpecExpr diag) (ErrSpecDecl diag)])]
    [(AstDeclDefFn name params ret body)
      (if (spec-param-list-has-comptime? params)
        (OkSpecDecl (SpecNoDecl) state)
        (match (spec-rewrite-expr
          body
          (spec-template-list-remove-params templates params)
          state)
          [(OkSpecExpr rewritten state2)
            (OkSpecDecl
              (SpecSomeDecl (AstDeclDefFn name params ret rewritten))
              state2)]
          [(ErrSpecExpr diag) (ErrSpecDecl diag)]))]
    [(AstDeclDefMacro name params ret body)
      (match (spec-rewrite-expr body templates state)
        [(OkSpecExpr rewritten state2)
          (OkSpecDecl
            (SpecSomeDecl (AstDeclDefMacro name params ret rewritten))
            state2)]
        [(ErrSpecExpr diag) (ErrSpecDecl diag)])]
    [_ (OkSpecDecl (SpecSomeDecl decl) state)]))

(define (spec-rewrite-decls
  [decls : AstDeclList]
  [templates : SpecTemplateList]
  [state : SpecState]) : ResultSpecDecls
  (match decls
    [(AstDeclNil) (OkSpecDecls AstDeclNil state)]
    [(AstDeclCons decl rest)
      (match (spec-rewrite-decl decl templates state)
        [(OkSpecDecl maybe-decl decl-state)
          (match (spec-rewrite-decls rest templates decl-state)
            [(OkSpecDecls rewritten-rest rest-state)
              (match maybe-decl
                [(SpecNoDecl) (OkSpecDecls rewritten-rest rest-state)]
                [(SpecSomeDecl rewritten-decl)
                  (OkSpecDecls
                    (AstDeclCons rewritten-decl rewritten-rest)
                    rest-state)])]
            [(ErrSpecDecls diag) (ErrSpecDecls diag)])]
        [(ErrSpecDecl diag) (ErrSpecDecls diag)])]))

(define (compiler-specialize-program [program : AstProgram]) : ResultSpecProgram
  (match program
    [(AstProgram decls)
      (let
        [templates : SpecTemplateList (spec-collect-templates decls)]
        (match templates
          [(SpecTemplateNil) (OkSpecProgram program)]
          [_
            (match (spec-rewrite-decls
              decls
              templates
              (SpecState
                AstDeclNil
                SpecCacheNil
                (ctfe-env-with-reflections
                  (ctfe-reflections-from-program program))))
              [(OkSpecDecls rewritten state)
                (match state
                  [(SpecState generated _ _)
                    (OkSpecProgram
                      (AstProgram (spec-decl-list-append rewritten generated)))])]
              [(ErrSpecDecls diag) (ErrSpecProgram diag)])]))]))

(define (compiler-specialize-needed? [program : AstProgram]) : bool
  (match program
    [(AstProgram decls)
      (match (spec-collect-templates decls)
        [(SpecTemplateNil) false]
        [_ true])]))

(define (compiler-specialize-decl-list-defines?
  [decls : AstDeclList]
  [name : String]) : bool
  (match decls
    [(AstDeclNil) false]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclDefFn fn-name _ _ _)
          (if (string-eq fn-name name)
            true
            (compiler-specialize-decl-list-defines? rest name))]
        [_ (compiler-specialize-decl-list-defines? rest name)])]))

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
            [(AstProgram decls)
              (and
                (not (compiler-specialize-decl-list-defines? decls "alloc"))
                (compiler-specialize-decl-list-defines?
                  decls
                  "__tl_specialized_alloc_type_i64_none"))])]
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
            [(AstProgram decls)
              (compiler-specialize-decl-list-defines?
                decls
                "__tl_specialized_pick_type_i64_none")])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-specialize-raw-pointer-type-ok?) : bool
  (let
    [subs : SpecTypeSubst (SpecTypeSubstCons "T" (AstTyI64) SpecTypeSubstNil)]
    (and
      (string-eq (spec-type-key (AstTyPtr (AstTyI64))) "ptr_i64")
      (and
        (string-eq
          (spec-type-key (AstTyMutPtr (AstTyPtr (AstTyU8))))
          "mutptr_ptr_u8")
        (ctfe-type-eq
          (spec-substitute-type (AstTyMutPtr (AstTyVar "T")) subs)
          (AstTyMutPtr (AstTyI64)))))))

;: Deterministic specialized name + stable specialization key (#1043, mirrors
;: src/specialize.rs deterministic-names / stable-keys coverage). The mangling
;: is a pure function of the template name and comptime argument values, so
;: identical args produce identical names, distinct type args never collide,
;: multi-value ordering is stable, and negative scalars / arbitrary strings
;: encode without punctuation that could break generated identifiers.
(define (compiler-specialize-name-key-ok?) : bool
  (let
    [vals-i64 : SpecValueList
      (SpecValueCons (CtfeType (AstTyI64)) (SpecValueNil))]
    [vals-bool : SpecValueList
      (SpecValueCons (CtfeType (AstTyBool)) (SpecValueNil))]
    [vals-multi : SpecValueList
      (SpecValueCons
        (CtfeType (AstTyI64))
        (SpecValueCons (CtfeI64 5) (SpecValueNil)))]
    [vals-string : SpecValueList
      (SpecValueCons (CtfeString "a b") (SpecValueNil))]
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
      (match decl
        [(AstDeclDefFn fn-name _ _ _)
          (if (string-eq fn-name name)
            (+ 1 (compiler-specialize-decl-list-count-defs rest name))
            (compiler-specialize-decl-list-count-defs rest name))]
        [_ (compiler-specialize-decl-list-count-defs rest name)])]))

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
            [(AstProgram decls)
              (and
                (not (compiler-specialize-decl-list-defines? decls "alloc"))
                (=
                  (compiler-specialize-decl-list-count-defs
                    decls
                    "__tl_specialized_alloc_type_i64_none")
                  1))])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

;: Type substitution (#1043, mirrors src/specialize.rs substitution coverage):
;: `spec-substitute-type` replaces a mapped type variable with its bound type,
;: recurses through compound types (Ptr/DynArray/function), and leaves an
;: unmapped variable unchanged (the SpecNoString lookup branch). Complements
;: the single MutPtr case embedded in `compiler-specialize-raw-pointer-type-ok?`.
(define (compiler-specialize-subst-ok?) : bool
  (let
    [subs : SpecTypeSubst (SpecTypeSubstCons "T" (AstTyI64) SpecTypeSubstNil)]
    (and
      (string-eq
        (spec-type-key (spec-substitute-type (AstTyVar "T") subs))
        "i64")
      (and
        (string-eq
          (spec-type-key (spec-substitute-type (AstTyPtr (AstTyVar "T")) subs))
          "ptr_i64")
        (and
          (string-eq
            (spec-type-key
              (spec-substitute-type (AstTyDynArray (AstTyVar "T")) subs))
            "dynarray_i64")
          (and
            (string-eq
              (spec-type-key
                (spec-substitute-type
                  (AstTyFunc
                    (AstTypeCons (AstTyVar "T") AstTypeNil)
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
      (SpecValueSubstCons "x" (CtfeI64 5) SpecValueSubstNil)]
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
          (AstExprIf
            (AstExprVar "x")
            (AstExprLiteral (AstLitInt 1))
            (AstExprVar "y"))
          subs)
          [(OkSpecSubExpr e)
            (match e
              [(AstExprIf cond _ else-branch)
                (and
                  (match cond
                    [(AstExprLiteral lit)
                      (match lit
                        [(AstLitInt n) (= n 5)]
                        [_ false])]
                    [_ false])
                  (match else-branch
                    [(AstExprVar name) (string-eq name "y")]
                    [_ false]))]
              [_ false])]
          [(ErrSpecSubExpr _) false])))))

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
            [(AstProgram decls)
              (compiler-specialize-decl-list-defines?
                decls
                "__tl_specialized_tag-helper_string_12_115_116_114_117_99_116_95_80_111_105_110_116_none")])]
        [(ErrSpecProgram _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-specialize-self-test) : i64
  (if (compiler-specialize-type-param-ok?)
    (if (compiler-specialize-runtime-type-use-rejected?)
      (if (compiler-specialize-template-shadow-ok?)
        (if (compiler-specialize-type-shadow-ok?)
          (if (compiler-specialize-raw-pointer-type-ok?)
            (if (compiler-specialize-name-key-ok?)
              (if (compiler-specialize-reuse-ok?)
                (if (compiler-specialize-subst-ok?)
                  (if (compiler-specialize-value-subst-ok?)
                    (if (compiler-specialize-reflection-string-param-ok?)
                      1
                      0)
                    0)
                  0)
                0)
              0)
            0)
          0)
        0)
      0)
    0))