;; compiler_parse_core.tl - Sexpr -> real TypeLisp compiler AST parser (#335).

(import "read.tl")
(import "compiler_ast_types.tl")

(defenum CpResultType
  (CpOkType AstType)
  (CpErrType String))

(defenum CpResultTypeList
  (CpOkTypeList AstTypeList)
  (CpErrTypeList String))

(defenum CpResultFuncTypeParts
  (CpOkFuncTypeParts AstTypeList AstType)
  (CpErrFuncTypeParts String))

(defenum CpResultMaybeTypeTail
  (CpOkMaybeTypeTail AstMaybeType Sexpr)
  (CpErrMaybeTypeTail String))

(defenum CpResultParam
  (CpOkParam AstParam)
  (CpErrParam String))

(defenum CpResultParamList
  (CpOkParamList AstParamList)
  (CpErrParamList String))

(defenum CpResultFieldDef
  (CpOkFieldDef AstFieldDef)
  (CpErrFieldDef String))

(defenum CpResultFieldDefList
  (CpOkFieldDefList AstFieldDefList)
  (CpErrFieldDefList String))

(defenum CpResultVariantDef
  (CpOkVariantDef AstVariantDef)
  (CpErrVariantDef String))

(defenum CpResultVariantDefList
  (CpOkVariantDefList AstVariantDefList)
  (CpErrVariantDefList String))

(defenum CpResultPattern
  (CpOkPattern AstPattern)
  (CpErrPattern String))

(defenum CpResultPatternList
  (CpOkPatternList AstPatternList)
  (CpErrPatternList String))

(defenum CpResultExpr
  (CpOkExpr AstExpr)
  (CpErrExpr String))

(defenum CpResultExprList
  (CpOkExprList AstExprList)
  (CpErrExprList String))

(defenum CpResultLetBinding
  (CpOkLetBinding AstLetBinding)
  (CpErrLetBinding String))

(defenum CpResultLetBindingList
  (CpOkLetBindingList AstLetBindingList)
  (CpErrLetBindingList String))

(defenum CpResultMatchArm
  (CpOkMatchArm AstMatchArm)
  (CpErrMatchArm String))

(defenum CpResultMatchArmList
  (CpOkMatchArmList AstMatchArmList)
  (CpErrMatchArmList String))

(defenum CpResultDecl
  (CpOkDecl AstDecl)
  (CpErrDecl String))

(defenum CpResultProgram
  (CpOkProgram AstProgram)
  (CpErrProgram String))

(define (cp-type-name [name : String]) : AstType
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
                                                          (if (string-eq name "Never")
                                                              (AstTyNever)
                                                              (AstTyVar name)))))))))))))))))

(define (compiler-parse-type [s : Sexpr]) : CpResultType
  (match s
    [(SSym name) (CpOkType (cp-type-name name))]
    [(SCons (SSym head) rest)
     (if (string-eq head "->")
         (match (cp-parse-func-type-parts rest)
           [(CpOkFuncTypeParts args ret) (CpOkType (AstTyFunc args ret))]
           [(CpErrFuncTypeParts message) (CpErrType message)])
         (if (string-eq head "Tuple")
             (match (cp-parse-type-list rest)
               [(CpOkTypeList elems) (CpOkType (AstTyTuple elems))]
               [(CpErrTypeList message) (CpErrType message)])
             (if (string-eq head "Array")
                 (cp-parse-array-type rest)
                 (CpErrType "compiler parse: expected type constructor"))))]
    [_ (CpErrType "compiler parse: expected type")]))

(define (cp-parse-array-type [rest : Sexpr]) : CpResultType
  (match rest
    [(SCons elem (SNil))
     (match (compiler-parse-type elem)
       [(CpOkType ty) (CpOkType (AstTyDynArray ty))]
       [(CpErrType message) (CpErrType message)])]
    [(SCons elem (SCons (SInt len) (SNil)))
     (match (compiler-parse-type elem)
       [(CpOkType ty) (CpOkType (AstTyArray ty len))]
       [(CpErrType message) (CpErrType message)])]
    [(SCons _ (SCons _ (SNil))) (CpErrType "compiler parse: array size must be integer")]
    [_ (CpErrType "compiler parse: malformed array type")]))

(define (cp-parse-type-list [s : Sexpr]) : CpResultTypeList
  (match s
    [(SNil) (CpOkTypeList AstTypeNil)]
    [(SCons head rest)
     (match (compiler-parse-type head)
       [(CpOkType ty)
        (match (cp-parse-type-list rest)
          [(CpOkTypeList parsed-rest) (CpOkTypeList (AstTypeCons ty parsed-rest))]
          [(CpErrTypeList message) (CpErrTypeList message)])]
       [(CpErrType message) (CpErrTypeList message)])]
    [_ (CpErrTypeList "compiler parse: malformed type list")]))

(define (cp-parse-func-type-parts [s : Sexpr]) : CpResultFuncTypeParts
  (match s
    [(SNil) (CpErrFuncTypeParts "compiler parse: function type needs return type")]
    [(SCons ret (SNil))
     (match (compiler-parse-type ret)
       [(CpOkType ty) (CpOkFuncTypeParts AstTypeNil ty)]
       [(CpErrType message) (CpErrFuncTypeParts message)])]
    [(SCons arg rest)
     (match (compiler-parse-type arg)
       [(CpOkType arg-ty)
        (match (cp-parse-func-type-parts rest)
          [(CpOkFuncTypeParts args ret)
           (CpOkFuncTypeParts (AstTypeCons arg-ty args) ret)]
          [(CpErrFuncTypeParts message) (CpErrFuncTypeParts message)])]
       [(CpErrType message) (CpErrFuncTypeParts message)])]
    [_ (CpErrFuncTypeParts "compiler parse: malformed function type")]))

(define (cp-parse-optional-type-tail [tail : Sexpr]) : CpResultMaybeTypeTail
  (match tail
    [(SCons (SSym marker) (SCons ty rest))
     (if (string-eq marker ":")
         (match (compiler-parse-type ty)
           [(CpOkType parsed-ty) (CpOkMaybeTypeTail (AstSomeType parsed-ty) rest)]
           [(CpErrType message) (CpErrMaybeTypeTail message)])
         (CpOkMaybeTypeTail AstNoType tail))]
    [_ (CpOkMaybeTypeTail AstNoType tail)]))

(define (cp-parse-param [s : Sexpr]) : CpResultParam
  (match s
    [(SCons (SSym name) (SCons (SSym marker) (SCons ty (SNil))))
     (if (string-eq marker ":")
         (match (compiler-parse-type ty)
           [(CpOkType parsed-ty) (CpOkParam (AstParam name parsed-ty))]
           [(CpErrType message) (CpErrParam message)])
         (CpErrParam "compiler parse: expected ':' in parameter"))]
    [_ (CpErrParam "compiler parse: malformed parameter")]))

(define (cp-parse-param-list [s : Sexpr]) : CpResultParamList
  (match s
    [(SNil) (CpOkParamList AstParamNil)]
    [(SCons head rest)
     (match (cp-parse-param head)
       [(CpOkParam param)
        (match (cp-parse-param-list rest)
          [(CpOkParamList parsed-rest) (CpOkParamList (AstParamCons param parsed-rest))]
          [(CpErrParamList message) (CpErrParamList message)])]
       [(CpErrParam message) (CpErrParamList message)])]
    [_ (CpErrParamList "compiler parse: malformed parameter list")]))

(define (cp-parse-field-def [s : Sexpr]) : CpResultFieldDef
  (match s
    [(SCons (SSym name) (SCons ty (SNil)))
     (match (compiler-parse-type ty)
       [(CpOkType parsed-ty) (CpOkFieldDef (AstFieldDef name parsed-ty))]
       [(CpErrType message) (CpErrFieldDef message)])]
    [_ (CpErrFieldDef "compiler parse: malformed struct field")]))

(define (cp-parse-field-def-list [s : Sexpr]) : CpResultFieldDefList
  (match s
    [(SNil) (CpOkFieldDefList AstFieldDefNil)]
    [(SCons head rest)
     (match (cp-parse-field-def head)
       [(CpOkFieldDef field)
        (match (cp-parse-field-def-list rest)
          [(CpOkFieldDefList parsed-rest) (CpOkFieldDefList (AstFieldDefCons field parsed-rest))]
          [(CpErrFieldDefList message) (CpErrFieldDefList message)])]
       [(CpErrFieldDef message) (CpErrFieldDefList message)])]
    [_ (CpErrFieldDefList "compiler parse: malformed struct field list")]))

(define (cp-parse-variant-def [s : Sexpr]) : CpResultVariantDef
  (match s
    [(SCons (SSym name) fields)
     (match (cp-parse-type-list fields)
       [(CpOkTypeList parsed-fields) (CpOkVariantDef (AstVariantDef name parsed-fields))]
       [(CpErrTypeList message) (CpErrVariantDef message)])]
    [_ (CpErrVariantDef "compiler parse: malformed enum variant")]))

(define (cp-parse-variant-def-list [s : Sexpr]) : CpResultVariantDefList
  (match s
    [(SNil) (CpOkVariantDefList AstVariantDefNil)]
    [(SCons head rest)
     (match (cp-parse-variant-def head)
       [(CpOkVariantDef variant)
        (match (cp-parse-variant-def-list rest)
          [(CpOkVariantDefList parsed-rest) (CpOkVariantDefList (AstVariantDefCons variant parsed-rest))]
          [(CpErrVariantDefList message) (CpErrVariantDefList message)])]
       [(CpErrVariantDef message) (CpErrVariantDefList message)])]
    [_ (CpErrVariantDefList "compiler parse: malformed enum variant list")]))

(define (cp-binop-tag [op : String]) : i64
  (if (string-eq op "+")
      1
      (if (string-eq op "-")
          2
          (if (string-eq op "*")
              3
              (if (string-eq op "/")
                  4
                  (if (string-eq op "%")
                      5
                      (if (string-eq op "=")
                          6
                          (if (string-eq op "!=")
                              7
                              (if (string-eq op "<")
                                  8
                                  (if (string-eq op "<=")
                                      9
                                      (if (string-eq op ">")
                                          10
                                          (if (string-eq op ">=")
                                              11
                                              (if (string-eq op "and")
                                                  12
                                                  (if (string-eq op "or")
                                                      13
                                                      (if (string-eq op "bit-and")
                                                          14
                                                          (if (string-eq op "bit-or")
                                                              15
                                                              (if (string-eq op "bit-xor")
                                                                  16
                                                                  (if (string-eq op "shl")
                                                                      17
                                                                      (if (string-eq op "shr")
                                                                          18
                                                                          0)))))))))))))))))))

(define (cp-binop-from-tag [tag : i64]) : AstBinOp
  (if (= tag 1)
      (AstBinAdd)
      (if (= tag 2)
          (AstBinSub)
          (if (= tag 3)
              (AstBinMul)
              (if (= tag 4)
                  (AstBinDiv)
                  (if (= tag 5)
                      (AstBinMod)
                      (if (= tag 6)
                          (AstBinEq)
                          (if (= tag 7)
                              (AstBinNe)
                              (if (= tag 8)
                                  (AstBinLt)
                                  (if (= tag 9)
                                      (AstBinLe)
                                      (if (= tag 10)
                                          (AstBinGt)
                                          (if (= tag 11)
                                              (AstBinGe)
                                              (if (= tag 12)
                                                  (AstBinAnd)
                                                  (if (= tag 13)
                                                      (AstBinOr)
                                                      (if (= tag 14)
                                                          (AstBinBitAnd)
                                                          (if (= tag 15)
                                                              (AstBinBitOr)
                                                              (if (= tag 16)
                                                                  (AstBinBitXor)
                                                                  (if (= tag 17)
                                                                      (AstBinShl)
                                                                      (AstBinShr)))))))))))))))))))

(define (cp-unop-tag [op : String]) : i64
  (if (string-eq op "not")
      1
      (if (string-eq op "neg")
          2
          (if (string-eq op "bit-not")
              3
              0))))

(define (cp-unop-from-tag [tag : i64]) : AstUnOp
  (if (= tag 1)
      (AstUnNot)
      (if (= tag 2)
          (AstUnNeg)
          (AstUnBitNot))))

(define (cp-symbol-expr [name : String]) : AstExpr
  (if (string-eq name "true")
      (AstExprLiteral (AstLitBool true))
      (if (string-eq name "false")
          (AstExprLiteral (AstLitBool false))
          (if (string-eq name "unit")
              (AstExprLiteral AstLitUnit)
              (AstExprVar name)))))

(define (compiler-parse-expr [s : Sexpr]) : CpResultExpr
  (match s
    [(SInt n) (CpOkExpr (AstExprLiteral (AstLitInt n)))]
    [(SStr text) (CpOkExpr (AstExprLiteral (AstLitString text)))]
    [(SChar c) (CpOkExpr (AstExprLiteral (AstLitChar c)))]
    [(SSym name) (CpOkExpr (cp-symbol-expr name))]
    [(SCons head rest) (cp-parse-list-expr head rest)]
    [_ (CpErrExpr "compiler parse: malformed expression")]))

(define (cp-parse-list-expr [head : Sexpr] [rest : Sexpr]) : CpResultExpr
  (match head
    [(SSym op)
     (if (string-eq op "if")
         (cp-parse-if rest)
         (if (string-eq op "while")
             (cp-parse-while rest)
             (if (string-eq op "begin")
                 (match (cp-parse-expr-list rest)
                   [(CpOkExprList exprs) (CpOkExpr (AstExprBegin exprs))]
                   [(CpErrExprList message) (CpErrExpr message)])
                 (if (string-eq op "let")
                     (cp-parse-let rest)
                     (if (string-eq op "lambda")
                         (cp-parse-lambda rest)
                         (if (string-eq op "set!")
                             (cp-parse-set rest)
                             (if (string-eq op "ann")
                                 (cp-parse-ann rest)
                                 (if (string-eq op "cast")
                                     (cp-parse-cast rest)
                                     (if (string-eq op "tuple")
                                         (match (cp-parse-expr-list rest)
                                           [(CpOkExprList exprs) (CpOkExpr (AstExprTuple exprs))]
                                           [(CpErrExprList message) (CpErrExpr message)])
                                         (if (string-eq op "tuple-ref")
                                             (cp-parse-tuple-ref rest)
                                             (if (string-eq op "array")
                                                 (match (cp-parse-expr-list rest)
                                                   [(CpOkExprList exprs) (CpOkExpr (AstExprArray exprs))]
                                                   [(CpErrExprList message) (CpErrExpr message)])
                                                 (if (string-eq op "make-array")
                                                     (cp-parse-make-array rest)
                                                     (if (string-eq op "array-ref")
                                                         (cp-parse-array-ref rest)
                                                         (if (string-eq op "array-set!")
                                                             (cp-parse-array-set rest)
                                                             (if (string-eq op "string-ref")
                                                                 (cp-parse-string-ref rest)
                                                                 (if (string-eq op "char-at")
                                                                     (cp-parse-string-ref rest)
                                                                     (if (string-eq op "match")
                                                                         (cp-parse-match rest)
                                                                         (if (string-eq op "struct-get")
                                                                             (cp-parse-struct-get rest)
                                                                             (cp-parse-operator-or-call op rest)))))))))))))))))))]
    [_ (cp-parse-call-with-head head rest)]))

(define (cp-parse-operator-or-call [op : String] [rest : Sexpr]) : CpResultExpr
  (let ([un-tag : i64 (cp-unop-tag op)])
    (if (!= un-tag 0)
        (cp-parse-unary (cp-unop-from-tag un-tag) rest)
        (let ([bin-tag : i64 (cp-binop-tag op)])
          (if (!= bin-tag 0)
              (cp-parse-binary (cp-binop-from-tag bin-tag) rest)
              (cp-parse-call-with-head (SSym op) rest))))))

(define (cp-parse-unary [op : AstUnOp] [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons arg (SNil))
     (match (compiler-parse-expr arg)
       [(CpOkExpr parsed-arg) (CpOkExpr (AstExprUnary op parsed-arg))]
       [(CpErrExpr message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed unary expression")]))

(define (cp-parse-binary [op : AstBinOp] [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons a (SCons b (SNil)))
     (match (compiler-parse-expr a)
       [(CpOkExpr left)
        (match (compiler-parse-expr b)
          [(CpOkExpr right) (CpOkExpr (AstExprBinary op left right))]
          [(CpErrExpr message) (CpErrExpr message)])]
       [(CpErrExpr message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed binary expression")]))

(define (cp-parse-call-with-head [head : Sexpr] [rest : Sexpr]) : CpResultExpr
  (match (compiler-parse-expr head)
    [(CpOkExpr func)
     (match (cp-parse-expr-list rest)
       [(CpOkExprList args) (CpOkExpr (AstExprCall func args))]
       [(CpErrExprList message) (CpErrExpr message)])]
    [(CpErrExpr message) (CpErrExpr message)]))

(define (cp-parse-expr-list [s : Sexpr]) : CpResultExprList
  (match s
    [(SNil) (CpOkExprList AstExprNil)]
    [(SCons head rest)
     (match (compiler-parse-expr head)
       [(CpOkExpr expr)
        (match (cp-parse-expr-list rest)
          [(CpOkExprList parsed-rest) (CpOkExprList (AstExprCons expr parsed-rest))]
          [(CpErrExprList message) (CpErrExprList message)])]
       [(CpErrExpr message) (CpErrExprList message)])]
    [_ (CpErrExprList "compiler parse: malformed expression list")]))

(define (cp-parse-if [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons c (SCons t (SCons e (SNil))))
     (match (compiler-parse-expr c)
       [(CpOkExpr cond)
        (match (compiler-parse-expr t)
          [(CpOkExpr then-expr)
           (match (compiler-parse-expr e)
             [(CpOkExpr else-expr) (CpOkExpr (AstExprIf cond then-expr else-expr))]
             [(CpErrExpr message) (CpErrExpr message)])]
          [(CpErrExpr message) (CpErrExpr message)])]
       [(CpErrExpr message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed if")]))

(define (cp-parse-while [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons c (SCons body (SNil)))
     (match (compiler-parse-expr c)
       [(CpOkExpr cond)
        (match (compiler-parse-expr body)
          [(CpOkExpr parsed-body) (CpOkExpr (AstExprWhile cond parsed-body))]
          [(CpErrExpr message) (CpErrExpr message)])]
       [(CpErrExpr message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed while")]))

(define (cp-parse-let [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons bindings (SCons body (SNil)))
     (match (cp-parse-let-binding-list bindings)
       [(CpOkLetBindingList parsed-bindings)
        (match (compiler-parse-expr body)
          [(CpOkExpr parsed-body) (CpOkExpr (AstExprLet parsed-bindings parsed-body))]
          [(CpErrExpr message) (CpErrExpr message)])]
       [(CpErrLetBindingList message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed let")]))

(define (cp-parse-let-binding [s : Sexpr]) : CpResultLetBinding
  (match s
    [(SCons (SSym name) tail)
     (match (cp-parse-optional-type-tail tail)
       [(CpOkMaybeTypeTail maybe-ty after-ty)
        (match after-ty
          [(SCons value (SNil))
           (match (compiler-parse-expr value)
             [(CpOkExpr parsed-value) (CpOkLetBinding (AstLetBinding name maybe-ty parsed-value))]
             [(CpErrExpr message) (CpErrLetBinding message)])]
          [_ (CpErrLetBinding "compiler parse: malformed let binding")])]
       [(CpErrMaybeTypeTail message) (CpErrLetBinding message)])]
    [_ (CpErrLetBinding "compiler parse: malformed let binding")]))

(define (cp-parse-let-binding-list [s : Sexpr]) : CpResultLetBindingList
  (match s
    [(SNil) (CpOkLetBindingList AstLetBindingNil)]
    [(SCons head rest)
     (match (cp-parse-let-binding head)
       [(CpOkLetBinding binding)
        (match (cp-parse-let-binding-list rest)
          [(CpOkLetBindingList parsed-rest) (CpOkLetBindingList (AstLetBindingCons binding parsed-rest))]
          [(CpErrLetBindingList message) (CpErrLetBindingList message)])]
       [(CpErrLetBinding message) (CpErrLetBindingList message)])]
    [_ (CpErrLetBindingList "compiler parse: malformed let binding list")]))

(define (cp-parse-lambda [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons params tail)
     (match (cp-parse-param-list params)
       [(CpOkParamList parsed-params) (cp-parse-lambda-tail parsed-params tail)]
       [(CpErrParamList message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed lambda")]))

(define (cp-parse-lambda-tail [params : AstParamList] [tail : Sexpr]) : CpResultExpr
  (match tail
    [(SCons (SSym marker) (SCons ret (SCons body (SNil))))
     (if (string-eq marker ":")
         (match (compiler-parse-type ret)
           [(CpOkType ret-ty)
            (match (compiler-parse-expr body)
              [(CpOkExpr parsed-body)
               (CpOkExpr (AstExprLambda params (AstSomeType ret-ty) parsed-body))]
              [(CpErrExpr message) (CpErrExpr message)])]
           [(CpErrType message) (CpErrExpr message)])
         (CpErrExpr "compiler parse: malformed lambda"))]
    [(SCons body (SNil))
     (match (compiler-parse-expr body)
       [(CpOkExpr parsed-body) (CpOkExpr (AstExprLambda params AstNoType parsed-body))]
       [(CpErrExpr message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed lambda")]))

(define (cp-parse-set [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons (SSym name) (SCons value (SNil)))
     (match (compiler-parse-expr value)
       [(CpOkExpr parsed-value) (CpOkExpr (AstExprSet name parsed-value))]
       [(CpErrExpr message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed set!")]))

(define (cp-parse-ann [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons expr (SCons (SSym marker) (SCons ty (SNil))))
     (if (string-eq marker ":")
         (match (compiler-parse-expr expr)
           [(CpOkExpr parsed-expr)
            (match (compiler-parse-type ty)
              [(CpOkType parsed-ty) (CpOkExpr (AstExprAnn parsed-expr parsed-ty))]
              [(CpErrType message) (CpErrExpr message)])]
           [(CpErrExpr message) (CpErrExpr message)])
         (CpErrExpr "compiler parse: expected ':' in annotation"))]
    [_ (CpErrExpr "compiler parse: malformed annotation")]))

(define (cp-parse-cast [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons expr (SCons (SSym marker) (SCons ty (SNil))))
     (if (string-eq marker ":")
         (match (compiler-parse-expr expr)
           [(CpOkExpr parsed-expr)
            (match (compiler-parse-type ty)
              [(CpOkType parsed-ty) (CpOkExpr (AstExprCast parsed-expr parsed-ty))]
              [(CpErrType message) (CpErrExpr message)])]
           [(CpErrExpr message) (CpErrExpr message)])
         (CpErrExpr "compiler parse: expected ':' in cast"))]
    [_ (CpErrExpr "compiler parse: malformed cast")]))

(define (cp-parse-tuple-ref [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons expr (SCons (SInt index) (SNil)))
     (match (compiler-parse-expr expr)
       [(CpOkExpr parsed-expr) (CpOkExpr (AstExprTupleRef parsed-expr index))]
       [(CpErrExpr message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed tuple-ref")]))

(define (cp-parse-make-array [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons ty (SCons len (SNil)))
     (match (compiler-parse-type ty)
       [(CpOkType elem-ty)
        (match (compiler-parse-expr len)
          [(CpOkExpr parsed-len) (CpOkExpr (AstExprMakeArray elem-ty parsed-len))]
          [(CpErrExpr message) (CpErrExpr message)])]
       [(CpErrType message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed make-array")]))

(define (cp-parse-array-ref [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons arr (SCons index (SNil)))
     (match (compiler-parse-expr arr)
       [(CpOkExpr parsed-arr)
        (match (compiler-parse-expr index)
          [(CpOkExpr parsed-index) (CpOkExpr (AstExprArrayRef parsed-arr parsed-index))]
          [(CpErrExpr message) (CpErrExpr message)])]
       [(CpErrExpr message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed array-ref")]))

(define (cp-parse-array-set [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons arr (SCons index (SCons value (SNil))))
     (match (compiler-parse-expr arr)
       [(CpOkExpr parsed-arr)
        (match (compiler-parse-expr index)
          [(CpOkExpr parsed-index)
           (match (compiler-parse-expr value)
             [(CpOkExpr parsed-value)
              (CpOkExpr (AstExprArraySet parsed-arr parsed-index parsed-value))]
             [(CpErrExpr message) (CpErrExpr message)])]
          [(CpErrExpr message) (CpErrExpr message)])]
       [(CpErrExpr message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed array-set!")]))

(define (cp-parse-string-ref [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons text (SCons index (SNil)))
     (match (compiler-parse-expr text)
       [(CpOkExpr parsed-text)
        (match (compiler-parse-expr index)
          [(CpOkExpr parsed-index) (CpOkExpr (AstExprStringRef parsed-text parsed-index))]
          [(CpErrExpr message) (CpErrExpr message)])]
       [(CpErrExpr message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed string-ref")]))

(define (cp-parse-struct-get [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons expr (SCons (SSym field) (SNil)))
     (match (compiler-parse-expr expr)
       [(CpOkExpr parsed-expr) (CpOkExpr (AstExprStructGet parsed-expr field))]
       [(CpErrExpr message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed struct-get")]))

(define (cp-parse-match [rest : Sexpr]) : CpResultExpr
  (match rest
    [(SCons scrutinee arms)
     (match (compiler-parse-expr scrutinee)
       [(CpOkExpr parsed-scrutinee)
        (match (cp-parse-match-arm-list arms)
          [(CpOkMatchArmList parsed-arms)
           (CpOkExpr (AstExprMatch parsed-scrutinee parsed-arms))]
          [(CpErrMatchArmList message) (CpErrExpr message)])]
       [(CpErrExpr message) (CpErrExpr message)])]
    [_ (CpErrExpr "compiler parse: malformed match")]))

(define (compiler-parse-pattern [s : Sexpr]) : CpResultPattern
  (match s
    [(SSym name)
     (if (string-eq name "_")
         (CpOkPattern AstPatWildcard)
         (if (string-eq name "true")
             (CpOkPattern (AstPatLiteral (AstLitBool true)))
             (if (string-eq name "false")
                 (CpOkPattern (AstPatLiteral (AstLitBool false)))
                 (if (string-eq name "unit")
                     (CpOkPattern (AstPatLiteral AstLitUnit))
                      (CpOkPattern (AstPatBinding name))))))]
    [(SInt n) (CpOkPattern (AstPatLiteral (AstLitInt n)))]
    [(SStr text) (CpOkPattern (AstPatLiteral (AstLitString text)))]
    [(SChar c) (CpOkPattern (AstPatLiteral (AstLitChar c)))]
    [(SCons (SSym head) rest)
     (match (cp-parse-pattern-list rest)
       [(CpOkPatternList args)
        (if (string-eq head "tuple")
            (CpOkPattern (AstPatTuple args))
            (CpOkPattern (AstPatVariant head args)))]
       [(CpErrPatternList message) (CpErrPattern message)])]
    [_ (CpErrPattern "compiler parse: expected pattern")]))

(define (cp-parse-pattern-list [s : Sexpr]) : CpResultPatternList
  (match s
    [(SNil) (CpOkPatternList AstPatternNil)]
    [(SCons head rest)
     (match (compiler-parse-pattern head)
       [(CpOkPattern pattern)
        (match (cp-parse-pattern-list rest)
          [(CpOkPatternList parsed-rest) (CpOkPatternList (AstPatternCons pattern parsed-rest))]
          [(CpErrPatternList message) (CpErrPatternList message)])]
       [(CpErrPattern message) (CpErrPatternList message)])]
    [_ (CpErrPatternList "compiler parse: malformed pattern list")]))

(define (cp-parse-match-arm [s : Sexpr]) : CpResultMatchArm
  (match s
    [(SCons pattern (SCons body (SNil)))
     (match (compiler-parse-pattern pattern)
       [(CpOkPattern parsed-pattern)
        (match (compiler-parse-expr body)
          [(CpOkExpr parsed-body) (CpOkMatchArm (AstMatchArm parsed-pattern parsed-body))]
          [(CpErrExpr message) (CpErrMatchArm message)])]
       [(CpErrPattern message) (CpErrMatchArm message)])]
    [_ (CpErrMatchArm "compiler parse: malformed match arm")]))

(define (cp-parse-match-arm-list [s : Sexpr]) : CpResultMatchArmList
  (match s
    [(SNil) (CpOkMatchArmList AstMatchArmNil)]
    [(SCons head rest)
     (match (cp-parse-match-arm head)
       [(CpOkMatchArm arm)
        (match (cp-parse-match-arm-list rest)
          [(CpOkMatchArmList parsed-rest) (CpOkMatchArmList (AstMatchArmCons arm parsed-rest))]
          [(CpErrMatchArmList message) (CpErrMatchArmList message)])]
       [(CpErrMatchArm message) (CpErrMatchArmList message)])]
    [_ (CpErrMatchArmList "compiler parse: malformed match arm list")]))

(define (compiler-parse-decl [s : Sexpr]) : CpResultDecl
  (match s
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
                         (CpErrDecl "compiler parse: expected declaration"))))))]
    [_ (CpErrDecl "compiler parse: malformed declaration")]))

(define (cp-parse-define [rest : Sexpr]) : CpResultDecl
  (match rest
    [(SCons (SSym name) tail) (cp-parse-value-define name tail)]
    [(SCons header tail) (cp-parse-function-define header tail)]
    [_ (CpErrDecl "compiler parse: malformed define")]))

(define (cp-parse-value-define [name : String] [tail : Sexpr]) : CpResultDecl
  (match (cp-parse-optional-type-tail tail)
    [(CpOkMaybeTypeTail maybe-ty after-ty)
     (match after-ty
       [(SCons value (SNil))
        (match (compiler-parse-expr value)
          [(CpOkExpr parsed-value) (CpOkDecl (AstDeclDef name maybe-ty parsed-value))]
          [(CpErrExpr message) (CpErrDecl message)])]
       [_ (CpErrDecl "compiler parse: malformed value define")])]
    [(CpErrMaybeTypeTail message) (CpErrDecl message)]))

(define (cp-parse-function-define [header : Sexpr] [tail : Sexpr]) : CpResultDecl
  (match header
    [(SCons (SSym name) params)
     (match (cp-parse-param-list params)
       [(CpOkParamList parsed-params)
        (cp-parse-function-define-tail name parsed-params tail)]
       [(CpErrParamList message) (CpErrDecl message)])]
    [_ (CpErrDecl "compiler parse: malformed function define header")]))

(define (cp-parse-function-define-tail [name : String] [params : AstParamList] [tail : Sexpr]) : CpResultDecl
  (match tail
    [(SCons (SSym marker) (SCons ret (SCons body (SNil))))
     (if (string-eq marker ":")
         (match (compiler-parse-type ret)
           [(CpOkType ret-ty)
            (match (compiler-parse-expr body)
              [(CpOkExpr parsed-body)
               (CpOkDecl (AstDeclDefFn name params ret-ty parsed-body))]
              [(CpErrExpr message) (CpErrDecl message)])]
           [(CpErrType message) (CpErrDecl message)])
         (CpErrDecl "compiler parse: malformed function define"))]
    [(SCons body (SNil))
     (match (compiler-parse-expr body)
       [(CpOkExpr parsed-body)
        (CpOkDecl (AstDeclDefFn name params (AstTyUnit) parsed-body))]
       [(CpErrExpr message) (CpErrDecl message)])]
    [_ (CpErrDecl "compiler parse: malformed function define")]))

(define (cp-parse-extern [rest : Sexpr]) : CpResultDecl
  (match rest
    [(SCons (SSym name) (SCons (SSym marker) (SCons ty (SNil))))
     (if (string-eq marker ":")
         (match (compiler-parse-type ty)
           [(CpOkType parsed-ty) (CpOkDecl (AstDeclExtern name parsed-ty))]
           [(CpErrType message) (CpErrDecl message)])
         (CpErrDecl "compiler parse: expected ':' in extern"))]
    [_ (CpErrDecl "compiler parse: malformed extern")]))

(define (cp-parse-defenum [rest : Sexpr]) : CpResultDecl
  (match rest
    [(SCons (SSym name) variants)
     (match variants
       [(SNil) (CpErrDecl "compiler parse: defenum needs variants")]
       [_ (match (cp-parse-variant-def-list variants)
            [(CpOkVariantDefList parsed-variants)
             (CpOkDecl (AstDeclDefEnum name parsed-variants))]
            [(CpErrVariantDefList message) (CpErrDecl message)])])]
    [_ (CpErrDecl "compiler parse: malformed defenum")]))

(define (cp-parse-defstruct [rest : Sexpr]) : CpResultDecl
  (match rest
    [(SCons (SSym name) fields)
     (match fields
       [(SNil) (CpErrDecl "compiler parse: defstruct needs fields")]
       [_ (match (cp-parse-field-def-list fields)
            [(CpOkFieldDefList parsed-fields)
             (CpOkDecl (AstDeclDefStruct name parsed-fields))]
            [(CpErrFieldDefList message) (CpErrDecl message)])])]
    [_ (CpErrDecl "compiler parse: malformed defstruct")]))

(define (cp-parse-import [rest : Sexpr]) : CpResultDecl
  (match rest
    [(SCons (SStr path) (SNil)) (CpOkDecl (AstDeclImport path))]
    [_ (CpErrDecl "compiler parse: malformed import")]))

(define (cp-decl-list-append-one [decls : AstDeclList] [decl : AstDecl]) : AstDeclList
  (match decls
    [(AstDeclNil) (AstDeclCons decl AstDeclNil)]
    [(AstDeclCons head rest) (AstDeclCons head (cp-decl-list-append-one rest decl))]))

(define (cp-parse-program-forms [toks : (Array Token)] [cur : (Array i64)] [decls : AstDeclList]) : CpResultProgram
  (if (= (peek-tag toks cur) (tag-end))
      (CpOkProgram (AstProgram decls))
      (let ([form : Sexpr (read-form toks cur)])
        (match (compiler-parse-decl form)
          [(CpOkDecl decl)
           (cp-parse-program-forms toks cur (cp-decl-list-append-one decls decl))]
          [(CpErrDecl message) (CpErrProgram message)]))))

(define (compiler-parse-program [toks : (Array Token)]) : CpResultProgram
  (let ([cur : (Array i64) (make-array i64 1)])
    (begin
      (array-set! cur 0 0)
      (cp-parse-program-forms toks cur AstDeclNil))))

(define (cp-decl-list-count [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons _ rest) (+ 1 (cp-decl-list-count rest))]))

(define (cp-decl-list-tag-sum [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons decl rest) (+ (ast-decl-tag decl) (cp-decl-list-tag-sum rest))]))

(define (cp-program-score [program : AstProgram]) : i64
  (match program
    [(AstProgram decls)
     (+ (cp-decl-list-count decls) (cp-decl-list-tag-sum decls))]))

(define (compiler-parse-smoke-source) : String
  "(import \"std.tl\")
(extern print : (-> String unit))
(defenum Option (Some i64) (None))
(defstruct Point (x i64) (y i64))
(define answer : i64 42)
(define (main [x : i64] [s : String]) : i64
  (let ([n : i64 (+ x 1)]
        [arr : (Array i64) (array 1 2 3)])
    (begin
      (set! n (array-ref arr 0))
      (match (Some n)
        [(Some v) (cast (ann (+ v 1) : i64) : i64)]
        [None 0]))))")

(define (compiler-parse-smoke) : i64
  (match (compiler-parse-program (lex (compiler-parse-smoke-source)))
    [(CpOkProgram program) (cp-program-score program)]
    [(CpErrProgram _) 0]))
