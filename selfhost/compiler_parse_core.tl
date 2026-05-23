;; compiler_parse_core.tl - Sexpr -> real compiler AST parser (#335).
;;
;; This module targets `compiler_ast_types.tl`, not the smaller
;; compile_smoke AST. It stays parser-only: later #27 work can reuse the
;; parsed `AstProgram` for typechecking/lowering once those selfhost passes
;; exist.

(import "compiler_ast_types.tl")
(import "read.tl")

(defenum ResultAstType
  (OkAstType AstType)
  (ErrAstType String))

(defenum ResultAstFuncTypeParts
  (OkAstFuncTypeParts AstTypeList AstType)
  (ErrAstFuncTypeParts String))

(defenum ResultAstTypeList
  (OkAstTypeList AstTypeList)
  (ErrAstTypeList String))

(defenum ResultAstParam
  (OkAstParam AstParam)
  (ErrAstParam String))

(defenum ResultAstParamList
  (OkAstParamList AstParamList)
  (ErrAstParamList String))

(defenum ResultAstFieldDef
  (OkAstFieldDef AstFieldDef)
  (ErrAstFieldDef String))

(defenum ResultAstFieldDefList
  (OkAstFieldDefList AstFieldDefList)
  (ErrAstFieldDefList String))

(defenum ResultAstVariantDef
  (OkAstVariantDef AstVariantDef)
  (ErrAstVariantDef String))

(defenum ResultAstVariantDefList
  (OkAstVariantDefList AstVariantDefList)
  (ErrAstVariantDefList String))

(defenum ResultAstPattern
  (OkAstPattern AstPattern)
  (ErrAstPattern String))

(defenum ResultAstPatternList
  (OkAstPatternList AstPatternList)
  (ErrAstPatternList String))

(defenum ResultAstLetBinding
  (OkAstLetBinding AstLetBinding)
  (ErrAstLetBinding String))

(defenum ResultAstLetBindingList
  (OkAstLetBindingList AstLetBindingList)
  (ErrAstLetBindingList String))

(defenum ResultAstMatchArm
  (OkAstMatchArm AstMatchArm)
  (ErrAstMatchArm String))

(defenum ResultAstMatchArmList
  (OkAstMatchArmList AstMatchArmList)
  (ErrAstMatchArmList String))

(defenum ResultAstExpr
  (OkAstExpr AstExpr)
  (ErrAstExpr String))

(defenum ResultAstExprList
  (OkAstExprList AstExprList)
  (ErrAstExprList String))

(defenum ResultAstDecl
  (OkAstDecl AstDecl)
  (ErrAstDecl String))

(defenum ResultAstDeclList
  (OkAstDeclList AstDeclList)
  (ErrAstDeclList String))

(defenum ResultAstProgram
  (OkAstProgram AstProgram)
  (ErrAstProgram String))

(define (sexpr-colon? [s : Sexpr]) : bool
  (match s
    [(SSym text) (string-eq text ":")]
    [_ false]))

(define (ast-binop? [name : String]) : bool
  (if (string-eq name "+")
      true
      (if (string-eq name "-")
          true
          (if (string-eq name "*")
              true
              (if (string-eq name "/")
                  true
                  (if (string-eq name "%")
                      true
                      (if (string-eq name "=")
                          true
                          (if (string-eq name "!=")
                              true
                              (if (string-eq name "<")
                                  true
                                  (if (string-eq name "<=")
                                      true
                                      (if (string-eq name ">")
                                          true
                                          (if (string-eq name ">=")
                                              true
                                              (if (string-eq name "and")
                                                  true
                                                  (if (string-eq name "or")
                                                      true
                                                      (if (string-eq name "bit-and")
                                                          true
                                                          (if (string-eq name "bit-or")
                                                              true
                                                              (if (string-eq name "bit-xor")
                                                                  true
                                                                  (if (string-eq name "shl")
                                                                      true
                                                                      (string-eq name "shr")))))))))))))))))))

(define (ast-binop-from-name [name : String]) : AstBinOp
  (if (string-eq name "+")
      (AstBinAdd)
      (if (string-eq name "-")
          (AstBinSub)
          (if (string-eq name "*")
              (AstBinMul)
              (if (string-eq name "/")
                  (AstBinDiv)
                  (if (string-eq name "%")
                      (AstBinMod)
                      (if (string-eq name "=")
                          (AstBinEq)
                          (if (string-eq name "!=")
                              (AstBinNe)
                              (if (string-eq name "<")
                                  (AstBinLt)
                                  (if (string-eq name "<=")
                                      (AstBinLe)
                                      (if (string-eq name ">")
                                          (AstBinGt)
                                          (if (string-eq name ">=")
                                              (AstBinGe)
                                              (if (string-eq name "and")
                                                  (AstBinAnd)
                                                  (if (string-eq name "or")
                                                      (AstBinOr)
                                                      (if (string-eq name "bit-and")
                                                          (AstBinBitAnd)
                                                          (if (string-eq name "bit-or")
                                                              (AstBinBitOr)
                                                              (if (string-eq name "bit-xor")
                                                                  (AstBinBitXor)
                                                                  (if (string-eq name "shl")
                                                                      (AstBinShl)
                                                                      (AstBinShr)))))))))))))))))))

(define (ast-unop? [name : String]) : bool
  (if (string-eq name "not")
      true
      (if (string-eq name "neg")
          true
          (string-eq name "bit-not"))))

(define (ast-unop-from-name [name : String]) : AstUnOp
  (if (string-eq name "not")
      (AstUnNot)
      (if (string-eq name "neg")
          (AstUnNeg)
          (AstUnBitNot))))

(define (parse-ast-type-list [s : Sexpr]) : ResultAstTypeList
  (match s
    [(SNil) (OkAstTypeList AstTypeNil)]
    [(SCons head tail)
     (match (parse-ast-type head)
       [(OkAstType parsed-head)
        (match (parse-ast-type-list tail)
          [(OkAstTypeList parsed-tail)
           (OkAstTypeList (AstTypeCons parsed-head parsed-tail))]
          [(ErrAstTypeList message) (ErrAstTypeList message)])]
       [(ErrAstType message) (ErrAstTypeList message)])]
    [_ (ErrAstTypeList "parse: malformed type list")]))

(define (parse-ast-func-type-parts [s : Sexpr]) : ResultAstFuncTypeParts
  (match s
    [(SCons ret (SNil))
     (match (parse-ast-type ret)
       [(OkAstType parsed-ret)
        (OkAstFuncTypeParts AstTypeNil parsed-ret)]
       [(ErrAstType message) (ErrAstFuncTypeParts message)])]
    [(SCons arg rest)
     (match (parse-ast-type arg)
       [(OkAstType parsed-arg)
        (match (parse-ast-func-type-parts rest)
          [(OkAstFuncTypeParts parsed-args parsed-ret)
           (OkAstFuncTypeParts (AstTypeCons parsed-arg parsed-args) parsed-ret)]
          [(ErrAstFuncTypeParts message) (ErrAstFuncTypeParts message)])]
       [(ErrAstType message) (ErrAstFuncTypeParts message)])]
    [_ (ErrAstFuncTypeParts "parse: function type needs at least return type")]))

(define (parse-ast-type [s : Sexpr]) : ResultAstType
  (match s
    [(SSym name)
     (if (string-eq name "i64")
         (OkAstType (AstTyI64))
         (if (string-eq name "i32")
             (OkAstType (AstTyI32))
             (if (string-eq name "i16")
                 (OkAstType (AstTyI16))
                 (if (string-eq name "i8")
                     (OkAstType (AstTyI8))
                     (if (string-eq name "u64")
                         (OkAstType (AstTyU64))
                         (if (string-eq name "u32")
                             (OkAstType (AstTyU32))
                             (if (string-eq name "u16")
                                 (OkAstType (AstTyU16))
                                 (if (string-eq name "u8")
                                     (OkAstType (AstTyU8))
                                     (if (string-eq name "f64")
                                         (OkAstType (AstTyF64))
                                         (if (string-eq name "f32")
                                             (OkAstType (AstTyF32))
                                             (if (string-eq name "bool")
                                                 (OkAstType (AstTyBool))
                                                 (if (string-eq name "char")
                                                     (OkAstType (AstTyChar))
                                                     (if (string-eq name "String")
                                                         (OkAstType (AstTyString))
                                                         (if (string-eq name "unit")
                                                             (OkAstType (AstTyUnit))
                                                             (if (string-eq name "never")
                                                                 (OkAstType (AstTyNever))
                                                                 (OkAstType (AstTyVar name)))))))))))))))))]
    [(SCons (SSym head) rest)
     (if (string-eq head "->")
         (match (parse-ast-func-type-parts rest)
           [(OkAstFuncTypeParts args ret) (OkAstType (AstTyFunc args ret))]
           [(ErrAstFuncTypeParts message) (ErrAstType message)])
         (if (string-eq head "Tuple")
             (match (parse-ast-type-list rest)
               [(OkAstTypeList elems) (OkAstType (AstTyTuple elems))]
               [(ErrAstTypeList message) (ErrAstType message)])
             (if (string-eq head "Array")
                 (match rest
                   [(SCons elem (SNil))
                    (match (parse-ast-type elem)
                      [(OkAstType elem-ty) (OkAstType (AstTyDynArray elem-ty))]
                      [(ErrAstType message) (ErrAstType message)])]
                   [(SCons elem (SCons (SInt size) (SNil)))
                    (match (parse-ast-type elem)
                      [(OkAstType elem-ty) (OkAstType (AstTyArray elem-ty size))]
                      [(ErrAstType message) (ErrAstType message)])]
                   [(SCons _ (SCons _ (SNil))) (ErrAstType "parse: array size must be integer")]
                   [_ (ErrAstType "parse: malformed array type")])
                 (ErrAstType "parse: unknown type constructor"))))]
    [_ (ErrAstType "parse: expected type")]))

(define (parse-ast-param [s : Sexpr]) : ResultAstParam
  (match s
    [(SCons (SSym name) (SCons colon (SCons ty (SNil))))
     (if (sexpr-colon? colon)
         (match (parse-ast-type ty)
           [(OkAstType parsed-ty) (OkAstParam (AstParam name parsed-ty))]
           [(ErrAstType message) (ErrAstParam message)])
         (ErrAstParam "parse: expected ':' in parameter"))]
    [_ (ErrAstParam "parse: malformed parameter")]))

(define (parse-ast-param-list [s : Sexpr]) : ResultAstParamList
  (match s
    [(SNil) (OkAstParamList AstParamNil)]
    [(SCons head tail)
     (match (parse-ast-param head)
       [(OkAstParam parsed-head)
        (match (parse-ast-param-list tail)
          [(OkAstParamList parsed-tail)
           (OkAstParamList (AstParamCons parsed-head parsed-tail))]
          [(ErrAstParamList message) (ErrAstParamList message)])]
       [(ErrAstParam message) (ErrAstParamList message)])]
    [_ (ErrAstParamList "parse: malformed parameter list")]))

(define (parse-ast-field-def [s : Sexpr]) : ResultAstFieldDef
  (match s
    [(SCons (SSym name) (SCons ty (SNil)))
     (match (parse-ast-type ty)
       [(OkAstType parsed-ty) (OkAstFieldDef (AstFieldDef name parsed-ty))]
       [(ErrAstType message) (ErrAstFieldDef message)])]
    [_ (ErrAstFieldDef "parse: malformed field definition")]))

(define (parse-ast-field-def-list [s : Sexpr]) : ResultAstFieldDefList
  (match s
    [(SNil) (OkAstFieldDefList AstFieldDefNil)]
    [(SCons head tail)
     (match (parse-ast-field-def head)
       [(OkAstFieldDef parsed-head)
        (match (parse-ast-field-def-list tail)
          [(OkAstFieldDefList parsed-tail)
           (OkAstFieldDefList (AstFieldDefCons parsed-head parsed-tail))]
          [(ErrAstFieldDefList message) (ErrAstFieldDefList message)])]
       [(ErrAstFieldDef message) (ErrAstFieldDefList message)])]
    [_ (ErrAstFieldDefList "parse: malformed field list")]))

(define (parse-ast-variant-def [s : Sexpr]) : ResultAstVariantDef
  (match s
    [(SCons (SSym name) fields)
     (match (parse-ast-type-list fields)
       [(OkAstTypeList parsed-fields) (OkAstVariantDef (AstVariantDef name parsed-fields))]
       [(ErrAstTypeList message) (ErrAstVariantDef message)])]
    [_ (ErrAstVariantDef "parse: malformed variant definition")]))

(define (parse-ast-variant-def-list [s : Sexpr]) : ResultAstVariantDefList
  (match s
    [(SNil) (OkAstVariantDefList AstVariantDefNil)]
    [(SCons head tail)
     (match (parse-ast-variant-def head)
       [(OkAstVariantDef parsed-head)
        (match (parse-ast-variant-def-list tail)
          [(OkAstVariantDefList parsed-tail)
           (OkAstVariantDefList (AstVariantDefCons parsed-head parsed-tail))]
          [(ErrAstVariantDefList message) (ErrAstVariantDefList message)])]
       [(ErrAstVariantDef message) (ErrAstVariantDefList message)])]
    [_ (ErrAstVariantDefList "parse: malformed variant list")]))

(define (parse-ast-pattern-list [s : Sexpr]) : ResultAstPatternList
  (match s
    [(SNil) (OkAstPatternList AstPatternNil)]
    [(SCons head tail)
     (match (parse-ast-pattern head)
       [(OkAstPattern parsed-head)
        (match (parse-ast-pattern-list tail)
          [(OkAstPatternList parsed-tail)
           (OkAstPatternList (AstPatternCons parsed-head parsed-tail))]
          [(ErrAstPatternList message) (ErrAstPatternList message)])]
       [(ErrAstPattern message) (ErrAstPatternList message)])]
    [_ (ErrAstPatternList "parse: malformed pattern list")]))

(define (parse-ast-pattern [s : Sexpr]) : ResultAstPattern
  (match s
    [(SInt n) (OkAstPattern (AstPatLiteral (AstLitInt n)))]
    [(SStr text) (OkAstPattern (AstPatLiteral (AstLitString text)))]
    [(SChar c) (OkAstPattern (AstPatLiteral (AstLitChar c)))]
    [(SSym name)
     (if (string-eq name "_")
         (OkAstPattern AstPatWildcard)
         (if (string-eq name "true")
             (OkAstPattern (AstPatLiteral (AstLitBool true)))
             (if (string-eq name "false")
                 (OkAstPattern (AstPatLiteral (AstLitBool false)))
                 (OkAstPattern (AstPatBinding name)))))]
    [(SCons (SSym name) args)
     (match (parse-ast-pattern-list args)
       [(OkAstPatternList parsed-args) (OkAstPattern (AstPatVariant name parsed-args))]
       [(ErrAstPatternList message) (ErrAstPattern message)])]
    [_ (ErrAstPattern "parse: expected pattern")]))

(define (parse-ast-expr-list [s : Sexpr]) : ResultAstExprList
  (match s
    [(SNil) (OkAstExprList AstExprNil)]
    [(SCons head tail)
     (match (parse-ast-expr head)
       [(OkAstExpr parsed-head)
        (match (parse-ast-expr-list tail)
          [(OkAstExprList parsed-tail)
           (OkAstExprList (AstExprCons parsed-head parsed-tail))]
          [(ErrAstExprList message) (ErrAstExprList message)])]
       [(ErrAstExpr message) (ErrAstExprList message)])]
    [_ (ErrAstExprList "parse: malformed expression list")]))

(define (parse-ast-binary [op : AstBinOp] [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons left (SCons right (SNil)))
     (match (parse-ast-expr left)
       [(OkAstExpr parsed-left)
        (match (parse-ast-expr right)
          [(OkAstExpr parsed-right)
           (OkAstExpr (AstExprBinary op parsed-left parsed-right))]
          [(ErrAstExpr message) (ErrAstExpr message)])]
       [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed binary expression")]))

(define (parse-ast-unary [op : AstUnOp] [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons expr (SNil))
     (match (parse-ast-expr expr)
       [(OkAstExpr parsed-expr) (OkAstExpr (AstExprUnary op parsed-expr))]
       [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed unary expression")]))

(define (parse-ast-if [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons cond (SCons then-branch (SCons else-branch (SNil))))
     (match (parse-ast-expr cond)
       [(OkAstExpr parsed-cond)
        (match (parse-ast-expr then-branch)
          [(OkAstExpr parsed-then)
           (match (parse-ast-expr else-branch)
             [(OkAstExpr parsed-else)
              (OkAstExpr (AstExprIf parsed-cond parsed-then parsed-else))]
             [(ErrAstExpr message) (ErrAstExpr message)])]
          [(ErrAstExpr message) (ErrAstExpr message)])]
       [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed if")]))

(define (parse-ast-while [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons cond (SCons body (SNil)))
     (match (parse-ast-expr cond)
       [(OkAstExpr parsed-cond)
        (match (parse-ast-expr body)
          [(OkAstExpr parsed-body) (OkAstExpr (AstExprWhile parsed-cond parsed-body))]
          [(ErrAstExpr message) (ErrAstExpr message)])]
       [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed while")]))

(define (parse-ast-set [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons (SSym name) (SCons value (SNil)))
     (match (parse-ast-expr value)
       [(OkAstExpr parsed-value) (OkAstExpr (AstExprSet name parsed-value))]
       [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed set!")]))

(define (parse-ast-ann-like [is-cast : bool] [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons expr (SCons colon (SCons ty (SNil))))
     (if (sexpr-colon? colon)
         (match (parse-ast-expr expr)
           [(OkAstExpr parsed-expr)
            (match (parse-ast-type ty)
              [(OkAstType parsed-ty)
               (if is-cast
                   (OkAstExpr (AstExprCast parsed-expr parsed-ty))
                   (OkAstExpr (AstExprAnn parsed-expr parsed-ty)))]
              [(ErrAstType message) (ErrAstExpr message)])]
           [(ErrAstExpr message) (ErrAstExpr message)])
         (ErrAstExpr "parse: expected ':' in annotation"))]
    [_ (ErrAstExpr "parse: malformed annotation")]))

(define (parse-ast-let-binding [s : Sexpr]) : ResultAstLetBinding
  (match s
    [(SCons (SSym name) (SCons colon (SCons ty (SCons value (SNil)))))
     (if (sexpr-colon? colon)
         (match (parse-ast-type ty)
           [(OkAstType parsed-ty)
            (match (parse-ast-expr value)
              [(OkAstExpr parsed-value)
               (OkAstLetBinding (AstLetBinding name (AstSomeType parsed-ty) parsed-value))]
              [(ErrAstExpr message) (ErrAstLetBinding message)])]
           [(ErrAstType message) (ErrAstLetBinding message)])
         (ErrAstLetBinding "parse: expected ':' in let binding"))]
    [(SCons (SSym name) (SCons value (SNil)))
     (match (parse-ast-expr value)
       [(OkAstExpr parsed-value)
        (OkAstLetBinding (AstLetBinding name AstNoType parsed-value))]
       [(ErrAstExpr message) (ErrAstLetBinding message)])]
    [_ (ErrAstLetBinding "parse: malformed let binding")]))

(define (parse-ast-let-binding-list [s : Sexpr]) : ResultAstLetBindingList
  (match s
    [(SNil) (OkAstLetBindingList AstLetBindingNil)]
    [(SCons head tail)
     (match (parse-ast-let-binding head)
       [(OkAstLetBinding parsed-head)
        (match (parse-ast-let-binding-list tail)
          [(OkAstLetBindingList parsed-tail)
           (OkAstLetBindingList (AstLetBindingCons parsed-head parsed-tail))]
          [(ErrAstLetBindingList message) (ErrAstLetBindingList message)])]
       [(ErrAstLetBinding message) (ErrAstLetBindingList message)])]
    [_ (ErrAstLetBindingList "parse: malformed let binding list")]))

(define (parse-ast-let [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons bindings (SCons body (SNil)))
     (match (parse-ast-let-binding-list bindings)
       [(OkAstLetBindingList parsed-bindings)
        (match (parse-ast-expr body)
          [(OkAstExpr parsed-body) (OkAstExpr (AstExprLet parsed-bindings parsed-body))]
          [(ErrAstExpr message) (ErrAstExpr message)])]
       [(ErrAstLetBindingList message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed let")]))

(define (parse-ast-lambda [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons params (SCons colon (SCons ret (SCons body (SNil)))))
     (if (sexpr-colon? colon)
         (match (parse-ast-param-list params)
           [(OkAstParamList parsed-params)
            (match (parse-ast-type ret)
              [(OkAstType parsed-ret)
               (match (parse-ast-expr body)
                 [(OkAstExpr parsed-body)
                  (OkAstExpr (AstExprLambda parsed-params (AstSomeType parsed-ret) parsed-body))]
                 [(ErrAstExpr message) (ErrAstExpr message)])]
              [(ErrAstType message) (ErrAstExpr message)])]
           [(ErrAstParamList message) (ErrAstExpr message)])
         (ErrAstExpr "parse: expected ':' in lambda"))]
    [(SCons params (SCons body (SNil)))
     (match (parse-ast-param-list params)
       [(OkAstParamList parsed-params)
        (match (parse-ast-expr body)
          [(OkAstExpr parsed-body)
           (OkAstExpr (AstExprLambda parsed-params AstNoType parsed-body))]
          [(ErrAstExpr message) (ErrAstExpr message)])]
       [(ErrAstParamList message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed lambda")]))

(define (parse-ast-tuple-ref [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons expr (SCons (SInt index) (SNil)))
     (match (parse-ast-expr expr)
       [(OkAstExpr parsed-expr) (OkAstExpr (AstExprTupleRef parsed-expr index))]
       [(ErrAstExpr message) (ErrAstExpr message)])]
    [(SCons _ (SCons _ (SNil))) (ErrAstExpr "parse: tuple-ref index must be integer")]
    [_ (ErrAstExpr "parse: malformed tuple-ref")]))

(define (parse-ast-make-array [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons elem-ty (SCons len (SNil)))
     (match (parse-ast-type elem-ty)
       [(OkAstType parsed-ty)
        (match (parse-ast-expr len)
          [(OkAstExpr parsed-len) (OkAstExpr (AstExprMakeArray parsed-ty parsed-len))]
          [(ErrAstExpr message) (ErrAstExpr message)])]
       [(ErrAstType message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed make-array")]))

(define (parse-ast-array-ref-like [is-string : bool] [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons expr (SCons index (SNil)))
     (match (parse-ast-expr expr)
       [(OkAstExpr parsed-expr)
        (match (parse-ast-expr index)
          [(OkAstExpr parsed-index)
           (if is-string
               (OkAstExpr (AstExprStringRef parsed-expr parsed-index))
               (OkAstExpr (AstExprArrayRef parsed-expr parsed-index)))]
          [(ErrAstExpr message) (ErrAstExpr message)])]
       [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed ref expression")]))

(define (parse-ast-array-set [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons expr (SCons index (SCons value (SNil))))
     (match (parse-ast-expr expr)
       [(OkAstExpr parsed-expr)
        (match (parse-ast-expr index)
          [(OkAstExpr parsed-index)
           (match (parse-ast-expr value)
             [(OkAstExpr parsed-value)
              (OkAstExpr (AstExprArraySet parsed-expr parsed-index parsed-value))]
             [(ErrAstExpr message) (ErrAstExpr message)])]
          [(ErrAstExpr message) (ErrAstExpr message)])]
       [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed array-set!")]))

(define (parse-ast-struct-get [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons expr (SCons (SSym field) (SNil)))
     (match (parse-ast-expr expr)
       [(OkAstExpr parsed-expr) (OkAstExpr (AstExprStructGet parsed-expr field))]
       [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed struct-get")]))

(define (parse-ast-match-arm [s : Sexpr]) : ResultAstMatchArm
  (match s
    [(SCons pattern (SCons body (SNil)))
     (match (parse-ast-pattern pattern)
       [(OkAstPattern parsed-pattern)
        (match (parse-ast-expr body)
          [(OkAstExpr parsed-body) (OkAstMatchArm (AstMatchArm parsed-pattern parsed-body))]
          [(ErrAstExpr message) (ErrAstMatchArm message)])]
       [(ErrAstPattern message) (ErrAstMatchArm message)])]
    [_ (ErrAstMatchArm "parse: malformed match arm")]))

(define (parse-ast-match-arm-list [s : Sexpr]) : ResultAstMatchArmList
  (match s
    [(SNil) (OkAstMatchArmList AstMatchArmNil)]
    [(SCons head tail)
     (match (parse-ast-match-arm head)
       [(OkAstMatchArm parsed-head)
        (match (parse-ast-match-arm-list tail)
          [(OkAstMatchArmList parsed-tail)
           (OkAstMatchArmList (AstMatchArmCons parsed-head parsed-tail))]
          [(ErrAstMatchArmList message) (ErrAstMatchArmList message)])]
       [(ErrAstMatchArm message) (ErrAstMatchArmList message)])]
    [_ (ErrAstMatchArmList "parse: malformed match arm list")]))

(define (parse-ast-match [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons scrutinee arms)
     (match (parse-ast-expr scrutinee)
       [(OkAstExpr parsed-scrutinee)
        (match (parse-ast-match-arm-list arms)
          [(OkAstMatchArmList parsed-arms)
           (OkAstExpr (AstExprMatch parsed-scrutinee parsed-arms))]
          [(ErrAstMatchArmList message) (ErrAstExpr message)])]
       [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed match")]))

(define (parse-ast-foreach [rest : Sexpr]) : ResultAstExpr
  (match rest
    [(SCons (SCons (SCons (SSym index) (SCons colon (SCons index-ty (SCons start (SCons end (SNil)))))) (SNil)) (SCons body (SNil)))
     (if (sexpr-colon? colon)
         (match (parse-ast-type index-ty)
           [(OkAstType parsed-index-ty)
            (match (parse-ast-expr start)
              [(OkAstExpr parsed-start)
               (match (parse-ast-expr end)
                 [(OkAstExpr parsed-end)
                  (match (parse-ast-expr body)
                    [(OkAstExpr parsed-body)
                     (OkAstExpr (AstExprForeach index parsed-index-ty parsed-start parsed-end parsed-body))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                 [(ErrAstExpr message) (ErrAstExpr message)])]
              [(ErrAstExpr message) (ErrAstExpr message)])]
           [(ErrAstType message) (ErrAstExpr message)])
         (ErrAstExpr "parse: expected ':' in foreach"))]
    [_ (ErrAstExpr "parse: malformed foreach")]))

(define (parse-ast-call [head : Sexpr] [rest : Sexpr]) : ResultAstExpr
  (match (parse-ast-expr head)
    [(OkAstExpr parsed-head)
     (match (parse-ast-expr-list rest)
       [(OkAstExprList parsed-args) (OkAstExpr (AstExprCall parsed-head parsed-args))]
       [(ErrAstExprList message) (ErrAstExpr message)])]
    [(ErrAstExpr message) (ErrAstExpr message)]))

(define (parse-ast-begin [rest : Sexpr]) : ResultAstExpr
  (match (parse-ast-expr-list rest)
    [(OkAstExprList exprs) (OkAstExpr (AstExprBegin exprs))]
    [(ErrAstExprList message) (ErrAstExpr message)]))

(define (parse-ast-tuple [rest : Sexpr]) : ResultAstExpr
  (match (parse-ast-expr-list rest)
    [(OkAstExprList exprs) (OkAstExpr (AstExprTuple exprs))]
    [(ErrAstExprList message) (ErrAstExpr message)]))

(define (parse-ast-array [rest : Sexpr]) : ResultAstExpr
  (match (parse-ast-expr-list rest)
    [(OkAstExprList exprs) (OkAstExpr (AstExprArray exprs))]
    [(ErrAstExprList message) (ErrAstExpr message)]))

(define (parse-ast-list-expr-more [op : String] [head : Sexpr] [rest : Sexpr]) : ResultAstExpr
  (if (string-eq op "array-ref")
      (parse-ast-array-ref-like false rest)
      (if (string-eq op "array-set!")
          (parse-ast-array-set rest)
          (if (string-eq op "string-ref")
              (parse-ast-array-ref-like true rest)
              (if (string-eq op "char-at")
                  (parse-ast-array-ref-like true rest)
                  (if (string-eq op "match")
                      (parse-ast-match rest)
                      (if (string-eq op "foreach")
                          (parse-ast-foreach rest)
                          (if (string-eq op "struct-get")
                              (parse-ast-struct-get rest)
                              (parse-ast-call head rest)))))))))

(define (parse-ast-list-expr-aggregate [op : String] [head : Sexpr] [rest : Sexpr]) : ResultAstExpr
  (if (string-eq op "tuple")
      (parse-ast-tuple rest)
      (if (string-eq op "tuple-ref")
          (parse-ast-tuple-ref rest)
          (if (string-eq op "array")
              (parse-ast-array rest)
              (if (string-eq op "make-array")
                  (parse-ast-make-array rest)
                  (parse-ast-list-expr-more op head rest))))))

(define (parse-ast-list-expr-special [op : String] [head : Sexpr] [rest : Sexpr]) : ResultAstExpr
  (if (string-eq op "if")
      (parse-ast-if rest)
      (if (string-eq op "let")
          (parse-ast-let rest)
          (if (string-eq op "lambda")
              (parse-ast-lambda rest)
              (if (string-eq op "while")
                  (parse-ast-while rest)
                  (if (string-eq op "begin")
                      (parse-ast-begin rest)
                      (if (string-eq op "set!")
                          (parse-ast-set rest)
                          (if (string-eq op "ann")
                              (parse-ast-ann-like false rest)
                              (if (string-eq op "cast")
                                  (parse-ast-ann-like true rest)
                                  (parse-ast-list-expr-aggregate op head rest))))))))))

(define (parse-ast-list-expr [head : Sexpr] [rest : Sexpr]) : ResultAstExpr
  (match head
    [(SSym op)
     (if (ast-unop? op)
         (parse-ast-unary (ast-unop-from-name op) rest)
         (if (ast-binop? op)
             (parse-ast-binary (ast-binop-from-name op) rest)
              (parse-ast-list-expr-special op head rest)))]
    [_ (parse-ast-call head rest)]))

(define (parse-ast-expr [s : Sexpr]) : ResultAstExpr
  (match s
    [(SInt n) (OkAstExpr (AstExprLiteral (AstLitInt n)))]
    [(SStr text) (OkAstExpr (AstExprLiteral (AstLitString text)))]
    [(SChar c) (OkAstExpr (AstExprLiteral (AstLitChar c)))]
    [(SSym name)
     (if (string-eq name "true")
         (OkAstExpr (AstExprLiteral (AstLitBool true)))
         (if (string-eq name "false")
             (OkAstExpr (AstExprLiteral (AstLitBool false)))
             (if (string-eq name "unit")
                 (OkAstExpr (AstExprLiteral AstLitUnit))
                 (OkAstExpr (AstExprVar name)))))]
    [(SCons head rest) (parse-ast-list-expr head rest)]
    [_ (ErrAstExpr "parse: malformed expression")]))

(define (parse-ast-define-value [name : String] [rest : Sexpr]) : ResultAstDecl
  (match rest
    [(SCons colon (SCons ty (SCons value (SNil))))
     (if (sexpr-colon? colon)
         (match (parse-ast-type ty)
           [(OkAstType parsed-ty)
            (match (parse-ast-expr value)
              [(OkAstExpr parsed-value)
               (OkAstDecl (AstDeclDef name (AstSomeType parsed-ty) parsed-value))]
              [(ErrAstExpr message) (ErrAstDecl message)])]
           [(ErrAstType message) (ErrAstDecl message)])
         (ErrAstDecl "parse: expected ':' in definition"))]
    [(SCons value (SNil))
     (match (parse-ast-expr value)
       [(OkAstExpr parsed-value)
        (OkAstDecl (AstDeclDef name AstNoType parsed-value))]
       [(ErrAstExpr message) (ErrAstDecl message)])]
    [_ (ErrAstDecl "parse: malformed value definition")]))

(define (parse-ast-define-fn [name : String] [params : Sexpr] [rest : Sexpr]) : ResultAstDecl
  (match rest
    [(SCons colon (SCons ret (SCons body (SNil))))
     (if (sexpr-colon? colon)
         (match (parse-ast-param-list params)
           [(OkAstParamList parsed-params)
            (match (parse-ast-type ret)
              [(OkAstType parsed-ret)
               (match (parse-ast-expr body)
                 [(OkAstExpr parsed-body)
                  (OkAstDecl (AstDeclDefFn name parsed-params parsed-ret parsed-body))]
                 [(ErrAstExpr message) (ErrAstDecl message)])]
              [(ErrAstType message) (ErrAstDecl message)])]
           [(ErrAstParamList message) (ErrAstDecl message)])
         (ErrAstDecl "parse: expected ':' in function definition"))]
    [(SCons body (SNil))
     (match (parse-ast-param-list params)
       [(OkAstParamList parsed-params)
        (match (parse-ast-expr body)
          [(OkAstExpr parsed-body)
           (OkAstDecl (AstDeclDefFn name parsed-params (AstTyUnit) parsed-body))]
          [(ErrAstExpr message) (ErrAstDecl message)])]
       [(ErrAstParamList message) (ErrAstDecl message)])]
    [_ (ErrAstDecl "parse: malformed function definition")]))

(define (parse-ast-define [rest : Sexpr]) : ResultAstDecl
  (match rest
    [(SCons (SSym name) after-name) (parse-ast-define-value name after-name)]
    [(SCons (SCons (SSym name) params) after-header)
     (parse-ast-define-fn name params after-header)]
    [_ (ErrAstDecl "parse: malformed define")]))

(define (parse-ast-extern [rest : Sexpr]) : ResultAstDecl
  (match rest
    [(SCons (SSym name) (SCons colon (SCons ty (SNil))))
     (if (sexpr-colon? colon)
         (match (parse-ast-type ty)
           [(OkAstType parsed-ty) (OkAstDecl (AstDeclExtern name parsed-ty))]
           [(ErrAstType message) (ErrAstDecl message)])
         (ErrAstDecl "parse: expected ':' in extern"))]
    [_ (ErrAstDecl "parse: malformed extern")]))

(define (parse-ast-defenum [rest : Sexpr]) : ResultAstDecl
  (match rest
    [(SCons (SSym name) variants)
     (match variants
       [(SNil) (ErrAstDecl "parse: defenum needs at least one variant")]
       [_ (match (parse-ast-variant-def-list variants)
            [(OkAstVariantDefList parsed-variants)
             (OkAstDecl (AstDeclDefEnum name parsed-variants))]
            [(ErrAstVariantDefList message) (ErrAstDecl message)])])]
    [_ (ErrAstDecl "parse: malformed defenum")]))

(define (parse-ast-defstruct [rest : Sexpr]) : ResultAstDecl
  (match rest
    [(SCons (SSym name) fields)
     (match fields
       [(SNil) (ErrAstDecl "parse: defstruct needs at least one field")]
       [_ (match (parse-ast-field-def-list fields)
            [(OkAstFieldDefList parsed-fields)
             (OkAstDecl (AstDeclDefStruct name parsed-fields))]
            [(ErrAstFieldDefList message) (ErrAstDecl message)])])]
    [_ (ErrAstDecl "parse: malformed defstruct")]))

(define (parse-ast-import [rest : Sexpr]) : ResultAstDecl
  (match rest
    [(SCons (SStr path) (SNil)) (OkAstDecl (AstDeclImport path))]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-decl [s : Sexpr]) : ResultAstDecl
  (match s
    [(SCons (SSym head) rest)
     (if (string-eq head "define")
         (parse-ast-define rest)
         (if (string-eq head "extern")
             (parse-ast-extern rest)
             (if (string-eq head "defenum")
                 (parse-ast-defenum rest)
                 (if (string-eq head "defstruct")
                     (parse-ast-defstruct rest)
                     (if (string-eq head "import")
                         (parse-ast-import rest)
                         (ErrAstDecl "parse: expected declaration"))))))]
    [_ (ErrAstDecl "parse: malformed declaration")]))

(define (parse-ast-program-forms [toks : (Array Token)] [cur : (Array i64)]) : ResultAstDeclList
  (if (= (peek-tag toks cur) (tag-end))
      (OkAstDeclList AstDeclNil)
      (let ([form : Sexpr (read-form toks cur)])
        (match (parse-ast-decl form)
          [(OkAstDecl decl)
           (match (parse-ast-program-forms toks cur)
             [(OkAstDeclList rest) (OkAstDeclList (AstDeclCons decl rest))]
             [(ErrAstDeclList message) (ErrAstDeclList message)])]
          [(ErrAstDecl message) (ErrAstDeclList message)]))))

(define (parse-ast-program [toks : (Array Token)]) : ResultAstProgram
  (let ([cur : (Array i64) (make-array i64 1)])
    (begin
      (array-set! cur 0 0)
      (match (parse-ast-program-forms toks cur)
        [(OkAstDeclList decls) (OkAstProgram (AstProgram decls))]
        [(ErrAstDeclList message) (ErrAstProgram message)]))))

(define (parse-ast-source [src : String]) : ResultAstProgram
  (parse-ast-program (lex src)))

(define (ast-decl-list-count [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons _ rest) (+ 1 (ast-decl-list-count rest))]))

(define (ast-decl-list-tag-sum [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons decl rest) (+ (ast-decl-tag decl) (ast-decl-list-tag-sum rest))]))

(define (ast-first-import-ok? [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclCons (AstDeclImport path) _) (string-eq path "stdlib/test.tl")]
    [_ false]))

(define (ast-main-body-tag [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons decl rest)
     (match decl
       [(AstDeclDefFn name _ _ body)
        (if (string-eq name "main")
            (ast-expr-tag body)
            (ast-main-body-tag rest))]
       [_ (ast-main-body-tag rest)])]))

(define (compiler-parse-smoke-source) : String
  "(import \"stdlib/test.tl\")
(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(extern print-string : (-> String unit))
(define answer : i64 42)
(define (main [argc : i64] [name : String]) : i64
  (let ([x : i64 1] [arr (array 1 2 3)])
    (begin
      (set! x (+ x 41))
      (if (and (= x 42) true)
          (match (Some x) [(Some v) v] [_ 0])
          0))))")

(define (compiler-parse-smoke-score [program : AstProgram]) : i64
  (match program
    [(AstProgram decls)
     (+ (ast-decl-list-count decls)
        (+ (ast-decl-list-tag-sum decls)
           (+ (ast-main-body-tag decls)
              (if (ast-first-import-ok? decls) 1 0))))]))

(define (compiler-parse-smoke) : i64
  (match (parse-ast-source (compiler-parse-smoke-source))
    [(OkAstProgram program)
     (if (= (compiler-parse-smoke-score program) 36)
         42
         (begin
           (panic "parse: compiler AST smoke score mismatch")
           0))]
    [(ErrAstProgram message)
     (begin
       (panic message)
       0)]))
