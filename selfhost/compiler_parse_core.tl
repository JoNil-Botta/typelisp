;; compiler_parse_core.tl - Sexpr -> real compiler AST parser (#335).
;;
;; This parser targets `compiler_ast_types.tl`, not the smaller compile-smoke
;; AST in `ast_types.tl`. It deliberately stops at syntax-to-AST conversion:
;; no typechecking, lowering, namespace resolution, or code generation happens
;; here. Malformed compiler forms return `CPErr*` values instead of panicking
;; once input has been lexed/read into `Sexpr`.

(import "compiler_ast_types.tl")
(import "read.tl")

(defenum CPResultProgram
  (CPOkProgram AstProgram)
  (CPErrProgram String))

(defenum CPResultDecl
  (CPOkDecl AstDecl)
  (CPErrDecl String))

(defenum CPResultDeclList
  (CPOkDeclList AstDeclList)
  (CPErrDeclList String))

(defenum CPResultType
  (CPOkType AstType)
  (CPErrType String))

(defenum CPResultTypeList
  (CPOkTypeList AstTypeList)
  (CPErrTypeList String))

(defenum CPResultParam
  (CPOkParam AstParam)
  (CPErrParam String))

(defenum CPResultParamList
  (CPOkParamList AstParamList)
  (CPErrParamList String))

(defenum CPResultFieldDef
  (CPOkFieldDef AstFieldDef)
  (CPErrFieldDef String))

(defenum CPResultFieldDefList
  (CPOkFieldDefList AstFieldDefList)
  (CPErrFieldDefList String))

(defenum CPResultVariantDef
  (CPOkVariantDef AstVariantDef)
  (CPErrVariantDef String))

(defenum CPResultVariantDefList
  (CPOkVariantDefList AstVariantDefList)
  (CPErrVariantDefList String))

(defenum CPResultExpr
  (CPOkExpr AstExpr)
  (CPErrExpr String))

(defenum CPResultExprList
  (CPOkExprList AstExprList)
  (CPErrExprList String))

(defenum CPResultLetBinding
  (CPOkLetBinding AstLetBinding)
  (CPErrLetBinding String))

(defenum CPResultLetBindingList
  (CPOkLetBindingList AstLetBindingList)
  (CPErrLetBindingList String))

(defenum CPResultPattern
  (CPOkPattern AstPattern)
  (CPErrPattern String))

(defenum CPResultPatternList
  (CPOkPatternList AstPatternList)
  (CPErrPatternList String))

(defenum CPResultMatchArm
  (CPOkMatchArm AstMatchArm)
  (CPErrMatchArm String))

(defenum CPResultMatchArmList
  (CPOkMatchArmList AstMatchArmList)
  (CPErrMatchArmList String))

(define (cp-is-symbol [s : Sexpr] [expected : String]) : bool
  (match s
    [(SSym actual) (string-eq actual expected)]
    [_ false]))

(define (cp-is-colon [s : Sexpr]) : bool
  (cp-is-symbol s ":"))

(define (cp-decl-list-append-one [decls : AstDeclList] [decl : AstDecl]) : AstDeclList
  (match decls
    [(AstDeclNil) (AstDeclCons decl AstDeclNil)]
    [(AstDeclCons head rest) (AstDeclCons head (cp-decl-list-append-one rest decl))]))

(define (cp-type-list-count [tys : AstTypeList]) : i64
  (match tys
    [(AstTypeNil) 0]
    [(AstTypeCons _ rest) (+ 1 (cp-type-list-count rest))]))

(define (cp-decl-list-count [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons _ rest) (+ 1 (cp-decl-list-count rest))]))

(define (cp-parse-symbol-type [name : String]) : AstType
  (if (string-eq name "i64")
      (AstTyI64)
      (if (string-eq name "i32")
          (AstTyI32)
          (if (string-eq name "i16")
              (AstTyI16)
              (if (string-eq name "i8")
                  (AstTyI8)
                  (if (string-eq name "u64")
                      (AstTyU64)
                      (if (string-eq name "u32")
                          (AstTyU32)
                          (if (string-eq name "u16")
                              (AstTyU16)
                              (if (string-eq name "u8")
                                  (AstTyU8)
                                  (if (string-eq name "f64")
                                      (AstTyF64)
                                      (if (string-eq name "f32")
                                          (AstTyF32)
                                          (if (string-eq name "bool")
                                              (AstTyBool)
                                              (if (string-eq name "char")
                                                  (AstTyChar)
                                                  (if (string-eq name "String")
                                                      (AstTyString)
                                                      (if (string-eq name "unit")
                                                          (AstTyUnit)
                                                          (AstTyVar name))))))))))))))))

(define (cp-parse-type-list [forms : Sexpr]) : CPResultTypeList
  (match forms
    [(SNil) (CPOkTypeList AstTypeNil)]
    [(SCons head rest)
     (match (cp-parse-type head)
       [(CPOkType ty)
        (match (cp-parse-type-list rest)
          [(CPOkTypeList tys) (CPOkTypeList (AstTypeCons ty tys))]
          [(CPErrTypeList message) (CPErrTypeList message)])]
       [(CPErrType message) (CPErrTypeList message)])]
    [_ (CPErrTypeList "compiler-parse: malformed type list")]))

(define (cp-parse-func-type-parts [forms : Sexpr]) : CPResultType
  (match forms
    [(SNil) (CPErrType "compiler-parse: function type needs return type")]
    [(SCons ret-form (SNil))
     (match (cp-parse-type ret-form)
       [(CPOkType ret-ty) (CPOkType (AstTyFunc AstTypeNil ret-ty))]
       [(CPErrType message) (CPErrType message)])]
    [(SCons arg-form rest)
     (match (cp-parse-type arg-form)
       [(CPOkType arg-ty)
        (match (cp-parse-func-type-parts rest)
          [(CPOkType fn-ty)
           (match fn-ty
             [(AstTyFunc args ret) (CPOkType (AstTyFunc (AstTypeCons arg-ty args) ret))]
             [_ (CPErrType "compiler-parse: internal malformed function type")])]
          [(CPErrType message) (CPErrType message)])]
       [(CPErrType message) (CPErrType message)])]
    [_ (CPErrType "compiler-parse: malformed function type")]))

(define (cp-parse-array-type [forms : Sexpr]) : CPResultType
  (match forms
    [(SCons elem-form (SNil))
     (match (cp-parse-type elem-form)
       [(CPOkType elem-ty) (CPOkType (AstTyDynArray elem-ty))]
       [(CPErrType message) (CPErrType message)])]
    [(SCons elem-form (SCons (SInt size) (SNil)))
     (match (cp-parse-type elem-form)
       [(CPOkType elem-ty) (CPOkType (AstTyArray elem-ty size))]
       [(CPErrType message) (CPErrType message)])]
    [_ (CPErrType "compiler-parse: malformed Array type")]))

(define (cp-parse-type [form : Sexpr]) : CPResultType
  (match form
    [(SSym name) (CPOkType (cp-parse-symbol-type name))]
    [(SNil) (CPOkType (AstTyUnit))]
    [(SCons (SSym head) rest)
     (if (string-eq head "->")
         (cp-parse-func-type-parts rest)
         (if (string-eq head "Tuple")
             (match (cp-parse-type-list rest)
               [(CPOkTypeList tys) (CPOkType (AstTyTuple tys))]
               [(CPErrTypeList message) (CPErrType message)])
             (if (string-eq head "Array")
                 (cp-parse-array-type rest)
                 (CPErrType "compiler-parse: expected type constructor"))))]
    [_ (CPErrType "compiler-parse: expected type")]))

(define (cp-parse-param [form : Sexpr]) : CPResultParam
  (match form
    [(SCons (SSym name) (SCons colon (SCons ty-form (SNil))))
     (if (cp-is-colon colon)
         (match (cp-parse-type ty-form)
           [(CPOkType ty) (CPOkParam (AstParam name ty))]
           [(CPErrType message) (CPErrParam message)])
         (CPErrParam "compiler-parse: parameter missing ':'"))]
    [_ (CPErrParam "compiler-parse: malformed parameter")]))

(define (cp-parse-param-list [forms : Sexpr]) : CPResultParamList
  (match forms
    [(SNil) (CPOkParamList AstParamNil)]
    [(SCons head rest)
     (match (cp-parse-param head)
       [(CPOkParam param)
        (match (cp-parse-param-list rest)
          [(CPOkParamList params) (CPOkParamList (AstParamCons param params))]
          [(CPErrParamList message) (CPErrParamList message)])]
       [(CPErrParam message) (CPErrParamList message)])]
    [_ (CPErrParamList "compiler-parse: malformed parameter list")]))

(define (cp-parse-field-def [form : Sexpr]) : CPResultFieldDef
  (match form
    [(SCons (SSym name) (SCons ty-form (SNil)))
     (match (cp-parse-type ty-form)
       [(CPOkType ty) (CPOkFieldDef (AstFieldDef name ty))]
       [(CPErrType message) (CPErrFieldDef message)])]
    [_ (CPErrFieldDef "compiler-parse: malformed struct field")]))

(define (cp-parse-field-def-list [forms : Sexpr]) : CPResultFieldDefList
  (match forms
    [(SNil) (CPOkFieldDefList AstFieldDefNil)]
    [(SCons head rest)
     (match (cp-parse-field-def head)
       [(CPOkFieldDef field)
        (match (cp-parse-field-def-list rest)
          [(CPOkFieldDefList fields) (CPOkFieldDefList (AstFieldDefCons field fields))]
          [(CPErrFieldDefList message) (CPErrFieldDefList message)])]
       [(CPErrFieldDef message) (CPErrFieldDefList message)])]
    [_ (CPErrFieldDefList "compiler-parse: malformed struct field list")]))

(define (cp-parse-variant-def [form : Sexpr]) : CPResultVariantDef
  (match form
    [(SCons (SSym name) type-forms)
     (match (cp-parse-type-list type-forms)
       [(CPOkTypeList tys) (CPOkVariantDef (AstVariantDef name tys))]
       [(CPErrTypeList message) (CPErrVariantDef message)])]
    [_ (CPErrVariantDef "compiler-parse: malformed enum variant")]))

(define (cp-parse-variant-def-list [forms : Sexpr]) : CPResultVariantDefList
  (match forms
    [(SNil) (CPOkVariantDefList AstVariantDefNil)]
    [(SCons head rest)
     (match (cp-parse-variant-def head)
       [(CPOkVariantDef variant)
        (match (cp-parse-variant-def-list rest)
          [(CPOkVariantDefList variants) (CPOkVariantDefList (AstVariantDefCons variant variants))]
          [(CPErrVariantDefList message) (CPErrVariantDefList message)])]
       [(CPErrVariantDef message) (CPErrVariantDefList message)])]
    [_ (CPErrVariantDefList "compiler-parse: malformed enum variant list")]))

(define (cp-bin-op [op : String]) : AstBinOp
  (let ([result : AstBinOp (AstBinShr)])
    (begin
      (if (string-eq op "+") (set! result (AstBinAdd)) unit)
      (if (string-eq op "-") (set! result (AstBinSub)) unit)
      (if (string-eq op "*") (set! result (AstBinMul)) unit)
      (if (string-eq op "/") (set! result (AstBinDiv)) unit)
      (if (string-eq op "%") (set! result (AstBinMod)) unit)
      (if (string-eq op "=") (set! result (AstBinEq)) unit)
      (if (string-eq op "!=") (set! result (AstBinNe)) unit)
      (if (string-eq op "<") (set! result (AstBinLt)) unit)
      (if (string-eq op "<=") (set! result (AstBinLe)) unit)
      (if (string-eq op ">") (set! result (AstBinGt)) unit)
      (if (string-eq op ">=") (set! result (AstBinGe)) unit)
      (if (string-eq op "and") (set! result (AstBinAnd)) unit)
      (if (string-eq op "or") (set! result (AstBinOr)) unit)
      (if (string-eq op "bit-and") (set! result (AstBinBitAnd)) unit)
      (if (string-eq op "bit-or") (set! result (AstBinBitOr)) unit)
      (if (string-eq op "bit-xor") (set! result (AstBinBitXor)) unit)
      (if (string-eq op "shl") (set! result (AstBinShl)) unit)
      result)))

(define (cp-is-bin-op [op : String]) : bool
  (let ([result : bool false])
    (begin
      (if (string-eq op "+") (set! result true) unit)
      (if (string-eq op "-") (set! result true) unit)
      (if (string-eq op "*") (set! result true) unit)
      (if (string-eq op "/") (set! result true) unit)
      (if (string-eq op "%") (set! result true) unit)
      (if (string-eq op "=") (set! result true) unit)
      (if (string-eq op "!=") (set! result true) unit)
      (if (string-eq op "<") (set! result true) unit)
      (if (string-eq op "<=") (set! result true) unit)
      (if (string-eq op ">") (set! result true) unit)
      (if (string-eq op ">=") (set! result true) unit)
      (if (string-eq op "and") (set! result true) unit)
      (if (string-eq op "or") (set! result true) unit)
      (if (string-eq op "bit-and") (set! result true) unit)
      (if (string-eq op "bit-or") (set! result true) unit)
      (if (string-eq op "bit-xor") (set! result true) unit)
      (if (string-eq op "shl") (set! result true) unit)
      (if (string-eq op "shr") (set! result true) unit)
      result)))

(define (cp-un-op [op : String]) : AstUnOp
  (if (string-eq op "neg")
      (AstUnNeg)
      (if (string-eq op "not")
          (AstUnNot)
          (AstUnBitNot))))

(define (cp-is-un-op [op : String]) : bool
  (if (string-eq op "neg")
      true
      (if (string-eq op "not")
          true
          (string-eq op "bit-not"))))

(define (cp-parse-expr-list [forms : Sexpr]) : CPResultExprList
  (match forms
    [(SNil) (CPOkExprList AstExprNil)]
    [(SCons head rest)
     (match (cp-parse-expr head)
       [(CPOkExpr expr)
        (match (cp-parse-expr-list rest)
          [(CPOkExprList exprs) (CPOkExprList (AstExprCons expr exprs))]
          [(CPErrExprList message) (CPErrExprList message)])]
       [(CPErrExpr message) (CPErrExprList message)])]
    [_ (CPErrExprList "compiler-parse: malformed expression list")]))

(define (cp-parse-binary [op : String] [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons left-form (SCons right-form (SNil)))
     (match (cp-parse-expr left-form)
       [(CPOkExpr left)
        (match (cp-parse-expr right-form)
          [(CPOkExpr right) (CPOkExpr (AstExprBinary (cp-bin-op op) left right))]
          [(CPErrExpr message) (CPErrExpr message)])]
       [(CPErrExpr message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed binary expression")]))

(define (cp-parse-unary [op : String] [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons arg-form (SNil))
     (match (cp-parse-expr arg-form)
       [(CPOkExpr arg) (CPOkExpr (AstExprUnary (cp-un-op op) arg))]
       [(CPErrExpr message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed unary expression")]))

(define (cp-parse-if [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons c-form (SCons t-form (SCons e-form (SNil))))
     (match (cp-parse-expr c-form)
       [(CPOkExpr c)
        (match (cp-parse-expr t-form)
          [(CPOkExpr t)
           (match (cp-parse-expr e-form)
             [(CPOkExpr e) (CPOkExpr (AstExprIf c t e))]
             [(CPErrExpr message) (CPErrExpr message)])]
          [(CPErrExpr message) (CPErrExpr message)])]
       [(CPErrExpr message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed if")]))

(define (cp-parse-while [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons c-form (SCons body-form (SNil)))
     (match (cp-parse-expr c-form)
       [(CPOkExpr c)
        (match (cp-parse-expr body-form)
          [(CPOkExpr body) (CPOkExpr (AstExprWhile c body))]
          [(CPErrExpr message) (CPErrExpr message)])]
       [(CPErrExpr message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed while")]))

(define (cp-parse-let-binding [form : Sexpr]) : CPResultLetBinding
  (match form
    [(SCons (SSym name) (SCons colon (SCons ty-form (SCons value-form (SNil)))))
     (if (cp-is-colon colon)
         (match (cp-parse-type ty-form)
           [(CPOkType ty)
            (match (cp-parse-expr value-form)
              [(CPOkExpr value) (CPOkLetBinding (AstLetBinding name (AstSomeType ty) value))]
              [(CPErrExpr message) (CPErrLetBinding message)])]
           [(CPErrType message) (CPErrLetBinding message)])
         (CPErrLetBinding "compiler-parse: malformed let binding"))]
    [(SCons (SSym name) (SCons value-form (SNil)))
     (match (cp-parse-expr value-form)
       [(CPOkExpr value) (CPOkLetBinding (AstLetBinding name (AstNoType) value))]
       [(CPErrExpr message) (CPErrLetBinding message)])]
    [_ (CPErrLetBinding "compiler-parse: malformed let binding")]))

(define (cp-parse-let-binding-list [forms : Sexpr]) : CPResultLetBindingList
  (match forms
    [(SNil) (CPOkLetBindingList AstLetBindingNil)]
    [(SCons head rest)
     (match (cp-parse-let-binding head)
       [(CPOkLetBinding binding)
        (match (cp-parse-let-binding-list rest)
          [(CPOkLetBindingList bindings) (CPOkLetBindingList (AstLetBindingCons binding bindings))]
          [(CPErrLetBindingList message) (CPErrLetBindingList message)])]
       [(CPErrLetBinding message) (CPErrLetBindingList message)])]
    [_ (CPErrLetBindingList "compiler-parse: malformed let binding list")]))

(define (cp-parse-let [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons bindings-form (SCons body-form (SNil)))
     (match (cp-parse-let-binding-list bindings-form)
       [(CPOkLetBindingList bindings)
        (match (cp-parse-expr body-form)
          [(CPOkExpr body) (CPOkExpr (AstExprLet bindings body))]
          [(CPErrExpr message) (CPErrExpr message)])]
       [(CPErrLetBindingList message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed let")]))

(define (cp-parse-lambda [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons params-form (SCons colon (SCons ret-form (SCons body-form (SNil)))))
     (if (cp-is-colon colon)
         (match (cp-parse-param-list params-form)
           [(CPOkParamList params)
            (match (cp-parse-type ret-form)
              [(CPOkType ret)
               (match (cp-parse-expr body-form)
                 [(CPOkExpr body) (CPOkExpr (AstExprLambda params (AstSomeType ret) body))]
                 [(CPErrExpr message) (CPErrExpr message)])]
              [(CPErrType message) (CPErrExpr message)])]
           [(CPErrParamList message) (CPErrExpr message)])
         (CPErrExpr "compiler-parse: malformed lambda"))]
    [(SCons params-form (SCons body-form (SNil)))
     (match (cp-parse-param-list params-form)
       [(CPOkParamList params)
        (match (cp-parse-expr body-form)
          [(CPOkExpr body) (CPOkExpr (AstExprLambda params (AstNoType) body))]
          [(CPErrExpr message) (CPErrExpr message)])]
       [(CPErrParamList message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed lambda")]))

(define (cp-parse-set [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons (SSym name) (SCons value-form (SNil)))
     (match (cp-parse-expr value-form)
       [(CPOkExpr value) (CPOkExpr (AstExprSet name value))]
       [(CPErrExpr message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed set!")]))

(define (cp-parse-ann [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons expr-form (SCons colon (SCons ty-form (SNil))))
     (if (cp-is-colon colon)
         (match (cp-parse-expr expr-form)
           [(CPOkExpr expr)
            (match (cp-parse-type ty-form)
              [(CPOkType ty) (CPOkExpr (AstExprAnn expr ty))]
              [(CPErrType message) (CPErrExpr message)])]
           [(CPErrExpr message) (CPErrExpr message)])
         (CPErrExpr "compiler-parse: annotation missing ':'"))]
    [_ (CPErrExpr "compiler-parse: malformed annotation")]))

(define (cp-parse-cast [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons expr-form (SCons colon (SCons ty-form (SNil))))
     (if (cp-is-colon colon)
         (match (cp-parse-expr expr-form)
           [(CPOkExpr expr)
            (match (cp-parse-type ty-form)
              [(CPOkType ty) (CPOkExpr (AstExprCast expr ty))]
              [(CPErrType message) (CPErrExpr message)])]
           [(CPErrExpr message) (CPErrExpr message)])
         (CPErrExpr "compiler-parse: cast missing ':'"))]
    [_ (CPErrExpr "compiler-parse: malformed cast")]))

(define (cp-parse-tuple-ref [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons expr-form (SCons (SInt index) (SNil)))
     (match (cp-parse-expr expr-form)
       [(CPOkExpr expr) (CPOkExpr (AstExprTupleRef expr index))]
       [(CPErrExpr message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed tuple-ref")]))

(define (cp-parse-make-array [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons ty-form (SCons len-form (SNil)))
     (match (cp-parse-type ty-form)
       [(CPOkType ty)
        (match (cp-parse-expr len-form)
          [(CPOkExpr len) (CPOkExpr (AstExprMakeArray ty len))]
          [(CPErrExpr message) (CPErrExpr message)])]
       [(CPErrType message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed make-array")]))

(define (cp-parse-array-ref [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons array-form (SCons index-form (SNil)))
     (match (cp-parse-expr array-form)
       [(CPOkExpr array)
        (match (cp-parse-expr index-form)
          [(CPOkExpr index) (CPOkExpr (AstExprArrayRef array index))]
          [(CPErrExpr message) (CPErrExpr message)])]
       [(CPErrExpr message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed array-ref")]))

(define (cp-parse-array-set [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons array-form (SCons index-form (SCons value-form (SNil))))
     (match (cp-parse-expr array-form)
       [(CPOkExpr array)
        (match (cp-parse-expr index-form)
          [(CPOkExpr index)
           (match (cp-parse-expr value-form)
             [(CPOkExpr value) (CPOkExpr (AstExprArraySet array index value))]
             [(CPErrExpr message) (CPErrExpr message)])]
          [(CPErrExpr message) (CPErrExpr message)])]
       [(CPErrExpr message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed array-set!")]))

(define (cp-parse-string-ref [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons string-form (SCons index-form (SNil)))
     (match (cp-parse-expr string-form)
       [(CPOkExpr string-expr)
        (match (cp-parse-expr index-form)
          [(CPOkExpr index) (CPOkExpr (AstExprStringRef string-expr index))]
          [(CPErrExpr message) (CPErrExpr message)])]
       [(CPErrExpr message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed string-ref")]))

(define (cp-parse-struct-get [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons expr-form (SCons (SSym field) (SNil)))
     (match (cp-parse-expr expr-form)
       [(CPOkExpr expr) (CPOkExpr (AstExprStructGet expr field))]
       [(CPErrExpr message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed struct-get")]))

(define (cp-parse-pattern-list [forms : Sexpr]) : CPResultPatternList
  (match forms
    [(SNil) (CPOkPatternList AstPatternNil)]
    [(SCons head rest)
     (match (cp-parse-pattern head)
       [(CPOkPattern pat)
        (match (cp-parse-pattern-list rest)
          [(CPOkPatternList pats) (CPOkPatternList (AstPatternCons pat pats))]
          [(CPErrPatternList message) (CPErrPatternList message)])]
       [(CPErrPattern message) (CPErrPatternList message)])]
    [_ (CPErrPatternList "compiler-parse: malformed pattern list")]))

(define (cp-parse-pattern [form : Sexpr]) : CPResultPattern
  (match form
    [(SNil) (CPOkPattern (AstPatLiteral (AstLitUnit)))]
    [(SInt n) (CPOkPattern (AstPatLiteral (AstLitInt n)))]
    [(SStr s) (CPOkPattern (AstPatLiteral (AstLitString s)))]
    [(SChar c) (CPOkPattern (AstPatLiteral (AstLitChar c)))]
    [(SSym name)
     (if (string-eq name "_")
         (CPOkPattern (AstPatWildcard))
         (if (string-eq name "true")
             (CPOkPattern (AstPatLiteral (AstLitBool true)))
             (if (string-eq name "false")
                 (CPOkPattern (AstPatLiteral (AstLitBool false)))
                 (CPOkPattern (AstPatBinding name)))))]
    [(SCons (SSym name) args)
     (if (string-eq name "tuple")
         (match (cp-parse-pattern-list args)
           [(CPOkPatternList pats) (CPOkPattern (AstPatTuple pats))]
           [(CPErrPatternList message) (CPErrPattern message)])
         (match (cp-parse-pattern-list args)
           [(CPOkPatternList pats) (CPOkPattern (AstPatVariant name pats))]
           [(CPErrPatternList message) (CPErrPattern message)]))]
    [_ (CPErrPattern "compiler-parse: malformed pattern")]))

(define (cp-parse-match-arm [form : Sexpr]) : CPResultMatchArm
  (match form
    [(SCons pat-form (SCons body-form (SNil)))
     (match (cp-parse-pattern pat-form)
       [(CPOkPattern pat)
        (match (cp-parse-expr body-form)
          [(CPOkExpr body) (CPOkMatchArm (AstMatchArm pat body))]
          [(CPErrExpr message) (CPErrMatchArm message)])]
       [(CPErrPattern message) (CPErrMatchArm message)])]
    [_ (CPErrMatchArm "compiler-parse: malformed match arm")]))

(define (cp-parse-match-arm-list [forms : Sexpr]) : CPResultMatchArmList
  (match forms
    [(SNil) (CPOkMatchArmList AstMatchArmNil)]
    [(SCons head rest)
     (match (cp-parse-match-arm head)
       [(CPOkMatchArm arm)
        (match (cp-parse-match-arm-list rest)
          [(CPOkMatchArmList arms) (CPOkMatchArmList (AstMatchArmCons arm arms))]
          [(CPErrMatchArmList message) (CPErrMatchArmList message)])]
       [(CPErrMatchArm message) (CPErrMatchArmList message)])]
    [_ (CPErrMatchArmList "compiler-parse: malformed match arm list")]))

(define (cp-parse-match [rest : Sexpr]) : CPResultExpr
  (match rest
    [(SCons scrut-form arms-form)
     (match (cp-parse-expr scrut-form)
       [(CPOkExpr scrutinee)
        (match (cp-parse-match-arm-list arms-form)
          [(CPOkMatchArmList arms) (CPOkExpr (AstExprMatch scrutinee arms))]
          [(CPErrMatchArmList message) (CPErrExpr message)])]
       [(CPErrExpr message) (CPErrExpr message)])]
    [_ (CPErrExpr "compiler-parse: malformed match")]))

(define (cp-parse-call [head : Sexpr] [rest : Sexpr]) : CPResultExpr
  (match (cp-parse-expr head)
    [(CPOkExpr func)
     (match (cp-parse-expr-list rest)
       [(CPOkExprList args) (CPOkExpr (AstExprCall func args))]
       [(CPErrExprList message) (CPErrExpr message)])]
    [(CPErrExpr message) (CPErrExpr message)]))

(define (cp-parse-list-expr [head : Sexpr] [rest : Sexpr]) : CPResultExpr
  (match head
    [(SSym op)
     (let ([result : CPResultExpr (cp-parse-call head rest)])
       (begin
         (if (cp-is-bin-op op) (set! result (cp-parse-binary op rest)) unit)
         (if (cp-is-un-op op) (set! result (cp-parse-unary op rest)) unit)
         (if (string-eq op "if") (set! result (cp-parse-if rest)) unit)
         (if (string-eq op "while") (set! result (cp-parse-while rest)) unit)
         (if (string-eq op "begin")
             (match (cp-parse-expr-list rest)
               [(CPOkExprList exprs) (set! result (CPOkExpr (AstExprBegin exprs)))]
               [(CPErrExprList message) (set! result (CPErrExpr message))])
             unit)
         (if (string-eq op "let") (set! result (cp-parse-let rest)) unit)
         (if (string-eq op "lambda") (set! result (cp-parse-lambda rest)) unit)
         (if (string-eq op "set!") (set! result (cp-parse-set rest)) unit)
         (if (string-eq op "ann") (set! result (cp-parse-ann rest)) unit)
         (if (string-eq op "cast") (set! result (cp-parse-cast rest)) unit)
         (if (string-eq op "tuple")
             (match (cp-parse-expr-list rest)
               [(CPOkExprList exprs) (set! result (CPOkExpr (AstExprTuple exprs)))]
               [(CPErrExprList message) (set! result (CPErrExpr message))])
             unit)
         (if (string-eq op "tuple-ref") (set! result (cp-parse-tuple-ref rest)) unit)
         (if (string-eq op "array")
             (match (cp-parse-expr-list rest)
               [(CPOkExprList exprs) (set! result (CPOkExpr (AstExprArray exprs)))]
               [(CPErrExprList message) (set! result (CPErrExpr message))])
             unit)
         (if (string-eq op "make-array") (set! result (cp-parse-make-array rest)) unit)
         (if (string-eq op "array-ref") (set! result (cp-parse-array-ref rest)) unit)
         (if (string-eq op "array-set!") (set! result (cp-parse-array-set rest)) unit)
         (if (string-eq op "string-ref") (set! result (cp-parse-string-ref rest)) unit)
         (if (string-eq op "char-at") (set! result (cp-parse-string-ref rest)) unit)
         (if (string-eq op "struct-get") (set! result (cp-parse-struct-get rest)) unit)
         (if (string-eq op "match") (set! result (cp-parse-match rest)) unit)
         result))]
    [_ (cp-parse-call head rest)]))

(define (cp-parse-expr [form : Sexpr]) : CPResultExpr
  (match form
    [(SNil) (CPOkExpr (AstExprLiteral (AstLitUnit)))]
    [(SInt n) (CPOkExpr (AstExprLiteral (AstLitInt n)))]
    [(SStr s) (CPOkExpr (AstExprLiteral (AstLitString s)))]
    [(SChar c) (CPOkExpr (AstExprLiteral (AstLitChar c)))]
    [(SSym name)
     (if (string-eq name "true")
         (CPOkExpr (AstExprLiteral (AstLitBool true)))
         (if (string-eq name "false")
             (CPOkExpr (AstExprLiteral (AstLitBool false)))
             (CPOkExpr (AstExprVar name))))]
    [(SCons head rest) (cp-parse-list-expr head rest)]
    [_ (CPErrExpr "compiler-parse: malformed expression")]))

(define (cp-parse-import [rest : Sexpr]) : CPResultDecl
  (match rest
    [(SCons (SStr path) (SNil)) (CPOkDecl (AstDeclImport path))]
    [_ (CPErrDecl "compiler-parse: malformed import")]))

(define (cp-parse-extern [rest : Sexpr]) : CPResultDecl
  (match rest
    [(SCons (SSym name) (SCons colon (SCons ty-form (SNil))))
     (if (cp-is-colon colon)
         (match (cp-parse-type ty-form)
           [(CPOkType ty) (CPOkDecl (AstDeclExtern name ty))]
           [(CPErrType message) (CPErrDecl message)])
         (CPErrDecl "compiler-parse: extern missing ':'"))]
    [_ (CPErrDecl "compiler-parse: malformed extern")]))

(define (cp-parse-defenum [rest : Sexpr]) : CPResultDecl
  (match rest
    [(SCons (SSym name) variants-form)
     (match variants-form
       [(SNil) (CPErrDecl "compiler-parse: defenum needs at least one variant")]
       [_ (match (cp-parse-variant-def-list variants-form)
            [(CPOkVariantDefList variants) (CPOkDecl (AstDeclDefEnum name variants))]
            [(CPErrVariantDefList message) (CPErrDecl message)])])]
    [_ (CPErrDecl "compiler-parse: malformed defenum")]))

(define (cp-parse-defstruct [rest : Sexpr]) : CPResultDecl
  (match rest
    [(SCons (SSym name) fields-form)
     (match fields-form
       [(SNil) (CPErrDecl "compiler-parse: defstruct needs at least one field")]
       [_ (match (cp-parse-field-def-list fields-form)
            [(CPOkFieldDefList fields) (CPOkDecl (AstDeclDefStruct name fields))]
            [(CPErrFieldDefList message) (CPErrDecl message)])])]
    [_ (CPErrDecl "compiler-parse: malformed defstruct")]))

(define (cp-parse-define [rest : Sexpr]) : CPResultDecl
  (match rest
    [(SCons (SCons (SSym name) params-form) (SCons colon (SCons ret-form (SCons body-form (SNil)))))
     (if (cp-is-colon colon)
         (match (cp-parse-param-list params-form)
           [(CPOkParamList params)
            (match (cp-parse-type ret-form)
              [(CPOkType ret)
               (match (cp-parse-expr body-form)
                 [(CPOkExpr body) (CPOkDecl (AstDeclDefFn name params ret body))]
                 [(CPErrExpr message) (CPErrDecl message)])]
              [(CPErrType message) (CPErrDecl message)])]
           [(CPErrParamList message) (CPErrDecl message)])
         (CPErrDecl "compiler-parse: function define missing ':'"))]
    [(SCons (SSym name) (SCons colon (SCons ty-form (SCons value-form (SNil)))))
     (if (cp-is-colon colon)
         (match (cp-parse-type ty-form)
           [(CPOkType ty)
            (match (cp-parse-expr value-form)
              [(CPOkExpr value) (CPOkDecl (AstDeclDef name (AstSomeType ty) value))]
              [(CPErrExpr message) (CPErrDecl message)])]
           [(CPErrType message) (CPErrDecl message)])
         (CPErrDecl "compiler-parse: value define missing ':'"))]
    [_ (CPErrDecl "compiler-parse: malformed define")]))

(define (cp-parse-decl [form : Sexpr]) : CPResultDecl
  (match form
    [(SCons (SSym head) rest)
     (if (string-eq head "define")
         (cp-parse-define rest)
         (if (string-eq head "extern")
             (cp-parse-extern rest)
             (if (string-eq head "defenum")
                 (cp-parse-defenum rest)
                 (if (string-eq head "defstruct")
                     (cp-parse-defstruct rest)
                     (if (string-eq head "import")
                         (cp-parse-import rest)
                         (CPErrDecl "compiler-parse: expected declaration"))))))]
    [_ (CPErrDecl "compiler-parse: malformed declaration")]))

(define (cp-parse-program-forms [toks : (Array Token)] [cur : (Array i64)] [decls : AstDeclList]) : CPResultProgram
  (if (= (peek-tag toks cur) (tag-end))
      (CPOkProgram (AstProgram decls))
      (let ([form : Sexpr (read-form toks cur)])
        (match (cp-parse-decl form)
          [(CPOkDecl decl) (cp-parse-program-forms toks cur (cp-decl-list-append-one decls decl))]
          [(CPErrDecl message) (CPErrProgram message)]))))

(define (parse-compiler-tokens [toks : (Array Token)]) : CPResultProgram
  (let ([cur : (Array i64) (make-array i64 1)])
    (begin
      (array-set! cur 0 0)
      (cp-parse-program-forms toks cur AstDeclNil))))

(define (parse-compiler-source [source : String]) : CPResultProgram
  (parse-compiler-tokens (lex source)))

(define (compiler-parse-smoke-source) : String
  "(import \"pkg:math/src/lib.tl\") (extern puts : (-> String i64)) (defenum Maybe (None) (Some i64) (Pair (Tuple i64 String))) (defstruct Pair (left i64) (right String)) (define total : i64 (ann (+ 1 2) : i64)) (define (main [n : i64] [name : String]) : i64 (begin (let ([a : i64 (+ n 1)] [b (tuple-ref (tuple 1 2) 0)]) (set! a (if true a 0))) (while false (set! n (- n 1))) (array-set! (make-array i64 2) 0 1) (string-ref name 0) (struct-get (Pair n name) left) (cast n : u64) (match (Some n) [(Some v) v] [_ 0]))))")

(define (compiler-parse-smoke-program-ok [program : AstProgram]) : i64
  (match program
    [(AstProgram decls)
     (match decls
       [(AstDeclCons (AstDeclImport _)
          (AstDeclCons (AstDeclExtern _ _)
            (AstDeclCons (AstDeclDefEnum _ _)
              (AstDeclCons (AstDeclDefStruct _ _)
                (AstDeclCons (AstDeclDef _ _ _)
                  (AstDeclCons (AstDeclDefFn _ _ _ _) AstDeclNil))))))
        (if (= (cp-decl-list-count decls) 6) 42 1)]
       [_ 2])]))

(define (compiler-parse-smoke) : i64
  (match (parse-compiler-source (compiler-parse-smoke-source))
    [(CPOkProgram program) (compiler-parse-smoke-program-ok program)]
    [(CPErrProgram _) 3]))
