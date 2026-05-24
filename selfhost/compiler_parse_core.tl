;; compiler_parse_core.tl - Sexpr -> real compiler AST parser (#335).

;;

;; This module targets `compiler_ast_types.tl`, not the smaller

;; compile_smoke AST. It stays parser-only: later #27 work can reuse the

;; parsed `AstProgram` for typechecking/lowering once those selfhost passes

;; exist.

(import "compiler_ast_types.tl")

(import "read.tl")

(import "sym_i64_env.tl")

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

(define (compiler-parse-tag-unknown) : i64
  0)

(define (compiler-parse-tag-bin-add) : i64
  10)

(define (compiler-parse-tag-bin-sub) : i64
  11)

(define (compiler-parse-tag-bin-mul) : i64
  12)

(define (compiler-parse-tag-bin-div) : i64
  13)

(define (compiler-parse-tag-bin-mod) : i64
  14)

(define (compiler-parse-tag-bin-eq) : i64
  15)

(define (compiler-parse-tag-bin-ne) : i64
  16)

(define (compiler-parse-tag-bin-lt) : i64
  17)

(define (compiler-parse-tag-bin-le) : i64
  18)

(define (compiler-parse-tag-bin-gt) : i64
  19)

(define (compiler-parse-tag-bin-ge) : i64
  20)

(define (compiler-parse-tag-bin-and) : i64
  21)

(define (compiler-parse-tag-bin-or) : i64
  22)

(define (compiler-parse-tag-bin-bit-and) : i64
  23)

(define (compiler-parse-tag-bin-bit-or) : i64
  24)

(define (compiler-parse-tag-bin-bit-xor) : i64
  25)

(define (compiler-parse-tag-bin-shl) : i64
  26)

(define (compiler-parse-tag-bin-shr) : i64
  27)

(define (compiler-parse-tag-un-not) : i64
  40)

(define (compiler-parse-tag-un-neg) : i64
  41)

(define (compiler-parse-tag-un-bit-not) : i64
  42)

(define (compiler-parse-tag-ty-i64) : i64
  100)

(define (compiler-parse-tag-ty-i32) : i64
  101)

(define (compiler-parse-tag-ty-i16) : i64
  102)

(define (compiler-parse-tag-ty-i8) : i64
  103)

(define (compiler-parse-tag-ty-u64) : i64
  104)

(define (compiler-parse-tag-ty-u32) : i64
  105)

(define (compiler-parse-tag-ty-u16) : i64
  106)

(define (compiler-parse-tag-ty-u8) : i64
  107)

(define (compiler-parse-tag-ty-f64) : i64
  108)

(define (compiler-parse-tag-ty-f32) : i64
  109)

(define (compiler-parse-tag-ty-bool) : i64
  110)

(define (compiler-parse-tag-ty-char) : i64
  111)

(define (compiler-parse-tag-ty-string) : i64
  112)

(define (compiler-parse-tag-unit) : i64
  113)

(define (compiler-parse-tag-ty-never) : i64
  114)

(define (compiler-parse-tag-ty-func) : i64
  130)

(define (compiler-parse-tag-ty-tuple) : i64
  131)

(define (compiler-parse-tag-ty-array) : i64
  132)

(define (compiler-parse-tag-expr-if) : i64
  200)

(define (compiler-parse-tag-expr-let) : i64
  201)

(define (compiler-parse-tag-expr-lambda) : i64
  202)

(define (compiler-parse-tag-expr-while) : i64
  203)

(define (compiler-parse-tag-expr-begin) : i64
  204)

(define (compiler-parse-tag-expr-set) : i64
  205)

(define (compiler-parse-tag-expr-ann) : i64
  206)

(define (compiler-parse-tag-expr-cast) : i64
  207)

(define (compiler-parse-tag-expr-cond) : i64
  208)

(define (compiler-parse-tag-expr-tuple) : i64
  220)

(define (compiler-parse-tag-expr-tuple-ref) : i64
  221)

(define (compiler-parse-tag-expr-array) : i64
  222)

(define (compiler-parse-tag-expr-make-array) : i64
  223)

(define (compiler-parse-tag-expr-array-ref) : i64
  240)

(define (compiler-parse-tag-expr-array-set) : i64
  241)

(define (compiler-parse-tag-expr-string-ref) : i64
  242)

(define (compiler-parse-tag-expr-char-at) : i64
  243)

(define (compiler-parse-tag-expr-match) : i64
  244)

(define (compiler-parse-tag-expr-foreach) : i64
  245)

(define (compiler-parse-tag-expr-struct-get) : i64
  246)

(define (compiler-parse-tag-lit-true) : i64
  300)

(define (compiler-parse-tag-lit-false) : i64
  301)

(define (compiler-parse-tag-pattern-wildcard) : i64
  302)

(define (compiler-parse-tag-decl-define) : i64
  400)

(define (compiler-parse-tag-decl-extern) : i64
  401)

(define (compiler-parse-tag-decl-defenum) : i64
  402)

(define (compiler-parse-tag-decl-defstruct) : i64
  403)

(define (compiler-parse-tag-decl-import) : i64
  404)

(define (compiler-parse-dispatch-binops [e : SymI64Env]) : SymI64Env
  (let ([e1 : SymI64Env (sym-i64-bind e "+" (compiler-parse-tag-bin-add))])
    (let ([e2 : SymI64Env (sym-i64-bind e1 "-" (compiler-parse-tag-bin-sub))])
      (let ([e3 : SymI64Env (sym-i64-bind e2 "*" (compiler-parse-tag-bin-mul))])
        (let ([e4
            :
            SymI64Env
            (sym-i64-bind e3 "/" (compiler-parse-tag-bin-div))])
          (let ([e5
              :
              SymI64Env
              (sym-i64-bind e4 "%" (compiler-parse-tag-bin-mod))])
            (let ([e6
                :
                SymI64Env
                (sym-i64-bind e5 "=" (compiler-parse-tag-bin-eq))])
              (let ([e7
                  :
                  SymI64Env
                  (sym-i64-bind e6 "!=" (compiler-parse-tag-bin-ne))])
                (let ([e8
                    :
                    SymI64Env
                    (sym-i64-bind e7 "<" (compiler-parse-tag-bin-lt))])
                  (let ([e9
                      :
                      SymI64Env
                      (sym-i64-bind e8 "<=" (compiler-parse-tag-bin-le))])
                    (let ([e10
                        :
                        SymI64Env
                        (sym-i64-bind e9 ">" (compiler-parse-tag-bin-gt))])
                      (let ([e11
                          :
                          SymI64Env
                          (sym-i64-bind e10 ">=" (compiler-parse-tag-bin-ge))])
                        (let ([e12
                            :
                            SymI64Env
                            (sym-i64-bind
                              e11
                              "and"
                              (compiler-parse-tag-bin-and))])
                          (let ([e13
                              :
                              SymI64Env
                              (sym-i64-bind
                                e12
                                "or"
                                (compiler-parse-tag-bin-or))])
                            (let ([e14
                                :
                                SymI64Env
                                (sym-i64-bind
                                  e13
                                  "bit-and"
                                  (compiler-parse-tag-bin-bit-and))])
                              (let ([e15
                                  :
                                  SymI64Env
                                  (sym-i64-bind
                                    e14
                                    "bit-or"
                                    (compiler-parse-tag-bin-bit-or))])
                                (let ([e16
                                    :
                                    SymI64Env
                                    (sym-i64-bind
                                      e15
                                      "bit-xor"
                                      (compiler-parse-tag-bin-bit-xor))])
                                  (let ([e17
                                      :
                                      SymI64Env
                                      (sym-i64-bind
                                        e16
                                        "shl"
                                        (compiler-parse-tag-bin-shl))])
                                    (sym-i64-bind
                                      e17
                                      "shr"
                                      (compiler-parse-tag-bin-shr))))))))))))))))))))

(define (compiler-parse-dispatch-unops [e : SymI64Env]) : SymI64Env
  (let ([e1 : SymI64Env (sym-i64-bind e "not" (compiler-parse-tag-un-not))])
    (let ([e2 : SymI64Env (sym-i64-bind e1 "neg" (compiler-parse-tag-un-neg))])
      (sym-i64-bind e2 "bit-not" (compiler-parse-tag-un-bit-not)))))

(define (compiler-parse-dispatch-types [e : SymI64Env]) : SymI64Env
  (let ([e1 : SymI64Env (sym-i64-bind e "i64" (compiler-parse-tag-ty-i64))])
    (let ([e2 : SymI64Env (sym-i64-bind e1 "i32" (compiler-parse-tag-ty-i32))])
      (let ([e3 : SymI64Env (sym-i64-bind e2 "i16" (compiler-parse-tag-ty-i16))])
        (let ([e4 : SymI64Env (sym-i64-bind e3 "i8" (compiler-parse-tag-ty-i8))])
          (let ([e5
              :
              SymI64Env
              (sym-i64-bind e4 "u64" (compiler-parse-tag-ty-u64))])
            (let ([e6
                :
                SymI64Env
                (sym-i64-bind e5 "u32" (compiler-parse-tag-ty-u32))])
              (let ([e7
                  :
                  SymI64Env
                  (sym-i64-bind e6 "u16" (compiler-parse-tag-ty-u16))])
                (let ([e8
                    :
                    SymI64Env
                    (sym-i64-bind e7 "u8" (compiler-parse-tag-ty-u8))])
                  (let ([e9
                      :
                      SymI64Env
                      (sym-i64-bind e8 "f64" (compiler-parse-tag-ty-f64))])
                    (let ([e10
                        :
                        SymI64Env
                        (sym-i64-bind e9 "f32" (compiler-parse-tag-ty-f32))])
                      (let ([e11
                          :
                          SymI64Env
                          (sym-i64-bind e10 "bool" (compiler-parse-tag-ty-bool))])
                        (let ([e12
                            :
                            SymI64Env
                            (sym-i64-bind
                              e11
                              "char"
                              (compiler-parse-tag-ty-char))])
                          (let ([e13
                              :
                              SymI64Env
                              (sym-i64-bind
                                e12
                                "String"
                                (compiler-parse-tag-ty-string))])
                            (let ([e14
                                :
                                SymI64Env
                                (sym-i64-bind
                                  e13
                                  "unit"
                                  (compiler-parse-tag-unit))])
                              (let ([e15
                                  :
                                  SymI64Env
                                  (sym-i64-bind
                                    e14
                                    "never"
                                    (compiler-parse-tag-ty-never))])
                                (let ([e16
                                    :
                                    SymI64Env
                                    (sym-i64-bind
                                      e15
                                      "->"
                                      (compiler-parse-tag-ty-func))])
                                  (let ([e17
                                      :
                                      SymI64Env
                                      (sym-i64-bind
                                        e16
                                        "Tuple"
                                        (compiler-parse-tag-ty-tuple))])
                                    (sym-i64-bind
                                      e17
                                      "Array"
                                      (compiler-parse-tag-ty-array))))))))))))))))))))

(define (compiler-parse-dispatch-exprs [e : SymI64Env]) : SymI64Env
  (let ([e1 : SymI64Env (sym-i64-bind e "if" (compiler-parse-tag-expr-if))])
    (let ([e2 : SymI64Env (sym-i64-bind e1 "let" (compiler-parse-tag-expr-let))])
      (let ([e3
          :
          SymI64Env
          (sym-i64-bind e2 "lambda" (compiler-parse-tag-expr-lambda))])
        (let ([e4
            :
            SymI64Env
            (sym-i64-bind e3 "while" (compiler-parse-tag-expr-while))])
          (let ([e5
              :
              SymI64Env
              (sym-i64-bind e4 "begin" (compiler-parse-tag-expr-begin))])
            (let ([e6
                :
                SymI64Env
                (sym-i64-bind e5 "set!" (compiler-parse-tag-expr-set))])
              (let ([e7
                  :
                  SymI64Env
                  (sym-i64-bind e6 "ann" (compiler-parse-tag-expr-ann))])
                (let ([e8
                    :
                    SymI64Env
                    (sym-i64-bind e7 "cast" (compiler-parse-tag-expr-cast))])
                  (let ([e9
                      :
                      SymI64Env
                      (sym-i64-bind e8 "cond" (compiler-parse-tag-expr-cond))])
                    (let ([e10
                        :
                        SymI64Env
                        (sym-i64-bind
                          e9
                          "tuple"
                          (compiler-parse-tag-expr-tuple))])
                      (let ([e11
                          :
                          SymI64Env
                          (sym-i64-bind
                            e10
                            "tuple-ref"
                            (compiler-parse-tag-expr-tuple-ref))])
                        (let ([e12
                            :
                            SymI64Env
                            (sym-i64-bind
                              e11
                              "array"
                              (compiler-parse-tag-expr-array))])
                          (let ([e13
                              :
                              SymI64Env
                              (sym-i64-bind
                                e12
                                "make-array"
                                (compiler-parse-tag-expr-make-array))])
                            (let ([e14
                                :
                                SymI64Env
                                (sym-i64-bind
                                  e13
                                  "array-ref"
                                  (compiler-parse-tag-expr-array-ref))])
                              (let ([e15
                                  :
                                  SymI64Env
                                  (sym-i64-bind
                                    e14
                                    "array-set!"
                                    (compiler-parse-tag-expr-array-set))])
                                (let ([e16
                                    :
                                    SymI64Env
                                    (sym-i64-bind
                                      e15
                                      "string-ref"
                                      (compiler-parse-tag-expr-string-ref))])
                                  (let ([e17
                                      :
                                      SymI64Env
                                      (sym-i64-bind
                                        e16
                                        "char-at"
                                        (compiler-parse-tag-expr-char-at))])
                                    (let ([e18
                                        :
                                        SymI64Env
                                        (sym-i64-bind
                                          e17
                                          "match"
                                          (compiler-parse-tag-expr-match))])
                                      (let ([e19
                                          :
                                          SymI64Env
                                          (sym-i64-bind
                                            e18
                                            "foreach"
                                            (compiler-parse-tag-expr-foreach))])
                                        (sym-i64-bind
                                          e19
                                          "struct-get"
                                          (compiler-parse-tag-expr-struct-get))))))))))))))))))))))

(define (compiler-parse-dispatch-patterns [e : SymI64Env]) : SymI64Env
  (let ([e1 : SymI64Env (sym-i64-bind e "true" (compiler-parse-tag-lit-true))])
    (let ([e2
        :
        SymI64Env
        (sym-i64-bind e1 "false" (compiler-parse-tag-lit-false))])
      (sym-i64-bind e2 "_" (compiler-parse-tag-pattern-wildcard)))))

(define (compiler-parse-dispatch-decls [e : SymI64Env]) : SymI64Env
  (let ([e1
      :
      SymI64Env
      (sym-i64-bind e "define" (compiler-parse-tag-decl-define))])
    (let ([e2
        :
        SymI64Env
        (sym-i64-bind e1 "extern" (compiler-parse-tag-decl-extern))])
      (let ([e3
          :
          SymI64Env
          (sym-i64-bind e2 "defenum" (compiler-parse-tag-decl-defenum))])
        (let ([e4
            :
            SymI64Env
            (sym-i64-bind e3 "defstruct" (compiler-parse-tag-decl-defstruct))])
          (sym-i64-bind e4 "import" (compiler-parse-tag-decl-import)))))))

(define (compiler-parse-dispatch-env) : SymI64Env
  (compiler-parse-dispatch-decls
    (compiler-parse-dispatch-patterns
      (compiler-parse-dispatch-exprs
        (compiler-parse-dispatch-types
          (compiler-parse-dispatch-unops
            (compiler-parse-dispatch-binops (sym-i64-empty))))))))

(define (compiler-parse-dispatch-tag [dispatch : SymI64Env] [name : String]) : i64
  (match (sym-i64-lookup dispatch name)
    [(SomeI64 tag) tag]
    [(NoneI64) (compiler-parse-tag-unknown)]))

(define (ast-binop-tag? [tag : i64]) : bool
  (if (= tag (compiler-parse-tag-bin-add))
    true
    (if (= tag (compiler-parse-tag-bin-sub))
      true
      (if (= tag (compiler-parse-tag-bin-mul))
        true
        (if (= tag (compiler-parse-tag-bin-div))
          true
          (if (= tag (compiler-parse-tag-bin-mod))
            true
            (if (= tag (compiler-parse-tag-bin-eq))
              true
              (if (= tag (compiler-parse-tag-bin-ne))
                true
                (if (= tag (compiler-parse-tag-bin-lt))
                  true
                  (if (= tag (compiler-parse-tag-bin-le))
                    true
                    (if (= tag (compiler-parse-tag-bin-gt))
                      true
                      (if (= tag (compiler-parse-tag-bin-ge))
                        true
                        (if (= tag (compiler-parse-tag-bin-and))
                          true
                          (if (= tag (compiler-parse-tag-bin-or))
                            true
                            (if (= tag (compiler-parse-tag-bin-bit-and))
                              true
                              (if (= tag (compiler-parse-tag-bin-bit-or))
                                true
                                (if (= tag (compiler-parse-tag-bin-bit-xor))
                                  true
                                  (if (= tag (compiler-parse-tag-bin-shl))
                                    true
                                    (= tag (compiler-parse-tag-bin-shr))))))))))))))))))))

(define (ast-binop? [dispatch : SymI64Env] [name : String]) : bool
  (ast-binop-tag? (compiler-parse-dispatch-tag dispatch name)))

(define (ast-binop-from-tag [tag : i64]) : AstBinOp
  (if (= tag (compiler-parse-tag-bin-add))
    (AstBinAdd)
    (if (= tag (compiler-parse-tag-bin-sub))
      (AstBinSub)
      (if (= tag (compiler-parse-tag-bin-mul))
        (AstBinMul)
        (if (= tag (compiler-parse-tag-bin-div))
          (AstBinDiv)
          (if (= tag (compiler-parse-tag-bin-mod))
            (AstBinMod)
            (if (= tag (compiler-parse-tag-bin-eq))
              (AstBinEq)
              (if (= tag (compiler-parse-tag-bin-ne))
                (AstBinNe)
                (if (= tag (compiler-parse-tag-bin-lt))
                  (AstBinLt)
                  (if (= tag (compiler-parse-tag-bin-le))
                    (AstBinLe)
                    (if (= tag (compiler-parse-tag-bin-gt))
                      (AstBinGt)
                      (if (= tag (compiler-parse-tag-bin-ge))
                        (AstBinGe)
                        (if (= tag (compiler-parse-tag-bin-and))
                          (AstBinAnd)
                          (if (= tag (compiler-parse-tag-bin-or))
                            (AstBinOr)
                            (if (= tag (compiler-parse-tag-bin-bit-and))
                              (AstBinBitAnd)
                              (if (= tag (compiler-parse-tag-bin-bit-or))
                                (AstBinBitOr)
                                (if (= tag (compiler-parse-tag-bin-bit-xor))
                                  (AstBinBitXor)
                                  (if (= tag (compiler-parse-tag-bin-shl))
                                    (AstBinShl)
                                    (AstBinShr)))))))))))))))))))

(define (ast-binop-from-name [dispatch : SymI64Env] [name : String]) : AstBinOp
  (ast-binop-from-tag (compiler-parse-dispatch-tag dispatch name)))

(define (ast-unop-tag? [tag : i64]) : bool
  (if (= tag (compiler-parse-tag-un-not))
    true
    (if (= tag (compiler-parse-tag-un-neg))
      true
      (= tag (compiler-parse-tag-un-bit-not)))))

(define (ast-unop? [dispatch : SymI64Env] [name : String]) : bool
  (ast-unop-tag? (compiler-parse-dispatch-tag dispatch name)))

(define (ast-unop-from-tag [tag : i64]) : AstUnOp
  (if (= tag (compiler-parse-tag-un-not))
    (AstUnNot)
    (if (= tag (compiler-parse-tag-un-neg))
      (AstUnNeg)
      (AstUnBitNot))))

(define (ast-unop-from-name [dispatch : SymI64Env] [name : String]) : AstUnOp
  (ast-unop-from-tag (compiler-parse-dispatch-tag dispatch name)))

(define (parse-ast-type-list [dispatch : SymI64Env] [s : Sexpr]) : ResultAstTypeList
  (match s
    [(SNil) (OkAstTypeList AstTypeNil)]
    [(SCons head tail)
      (match (parse-ast-type dispatch head)
        [(OkAstType parsed-head)
          (match (parse-ast-type-list dispatch tail)
            [(OkAstTypeList parsed-tail)
              (OkAstTypeList (AstTypeCons parsed-head parsed-tail))]
            [(ErrAstTypeList message) (ErrAstTypeList message)])]
        [(ErrAstType message) (ErrAstTypeList message)])]
    [_ (ErrAstTypeList "parse: malformed type list")]))

(define (parse-ast-func-type-parts [dispatch : SymI64Env] [s : Sexpr]) : ResultAstFuncTypeParts
  (match s
    [(SCons ret (SNil))
      (match (parse-ast-type dispatch ret)
        [(OkAstType parsed-ret) (OkAstFuncTypeParts AstTypeNil parsed-ret)]
        [(ErrAstType message) (ErrAstFuncTypeParts message)])]
    [(SCons arg rest)
      (match (parse-ast-type dispatch arg)
        [(OkAstType parsed-arg)
          (match (parse-ast-func-type-parts dispatch rest)
            [(OkAstFuncTypeParts parsed-args parsed-ret)
              (OkAstFuncTypeParts
                (AstTypeCons parsed-arg parsed-args)
                parsed-ret)]
            [(ErrAstFuncTypeParts message) (ErrAstFuncTypeParts message)])]
        [(ErrAstType message) (ErrAstFuncTypeParts message)])]
    [_ (ErrAstFuncTypeParts "parse: function type needs at least return type")]))

(define (parse-ast-type [dispatch : SymI64Env] [s : Sexpr]) : ResultAstType
  (match s
    [(SSym name)
      (let ([tag : i64 (compiler-parse-dispatch-tag dispatch name)])
        (if (= tag (compiler-parse-tag-ty-i64))
          (OkAstType (AstTyI64))
          (if (= tag (compiler-parse-tag-ty-i32))
            (OkAstType (AstTyI32))
            (if (= tag (compiler-parse-tag-ty-i16))
              (OkAstType (AstTyI16))
              (if (= tag (compiler-parse-tag-ty-i8))
                (OkAstType (AstTyI8))
                (if (= tag (compiler-parse-tag-ty-u64))
                  (OkAstType (AstTyU64))
                  (if (= tag (compiler-parse-tag-ty-u32))
                    (OkAstType (AstTyU32))
                    (if (= tag (compiler-parse-tag-ty-u16))
                      (OkAstType (AstTyU16))
                      (if (= tag (compiler-parse-tag-ty-u8))
                        (OkAstType (AstTyU8))
                        (if (= tag (compiler-parse-tag-ty-f64))
                          (OkAstType (AstTyF64))
                          (if (= tag (compiler-parse-tag-ty-f32))
                            (OkAstType (AstTyF32))
                            (if (= tag (compiler-parse-tag-ty-bool))
                              (OkAstType (AstTyBool))
                              (if (= tag (compiler-parse-tag-ty-char))
                                (OkAstType (AstTyChar))
                                (if (= tag (compiler-parse-tag-ty-string))
                                  (OkAstType (AstTyString))
                                  (if (= tag (compiler-parse-tag-unit))
                                    (OkAstType (AstTyUnit))
                                    (if (= tag (compiler-parse-tag-ty-never))
                                      (OkAstType (AstTyNever))
                                      (OkAstType (AstTyVar name))))))))))))))))))]
    [(SCons (SSym head) rest)
      (let ([tag : i64 (compiler-parse-dispatch-tag dispatch head)])
        (if (= tag (compiler-parse-tag-ty-func))
          (match (parse-ast-func-type-parts dispatch rest)
            [(OkAstFuncTypeParts args ret) (OkAstType (AstTyFunc args ret))]
            [(ErrAstFuncTypeParts message) (ErrAstType message)])
          (if (= tag (compiler-parse-tag-ty-tuple))
            (match (parse-ast-type-list dispatch rest)
              [(OkAstTypeList elems) (OkAstType (AstTyTuple elems))]
              [(ErrAstTypeList message) (ErrAstType message)])
            (if (= tag (compiler-parse-tag-ty-array))
              (match rest
                [(SCons elem (SNil))
                  (match (parse-ast-type dispatch elem)
                    [(OkAstType elem-ty) (OkAstType (AstTyDynArray elem-ty))]
                    [(ErrAstType message) (ErrAstType message)])]
                [(SCons elem (SCons (SInt size) (SNil)))
                  (match (parse-ast-type dispatch elem)
                    [(OkAstType elem-ty) (OkAstType (AstTyArray elem-ty size))]
                    [(ErrAstType message) (ErrAstType message)])]
                [(SCons _ (SCons _ (SNil)))
                  (ErrAstType "parse: array size must be integer")]
                [_ (ErrAstType "parse: malformed array type")])
              (ErrAstType "parse: unknown type constructor")))))]
    [_ (ErrAstType "parse: expected type")]))

(define (parse-ast-param [dispatch : SymI64Env] [s : Sexpr]) : ResultAstParam
  (match s
    [(SCons (SSym name) (SCons colon (SCons ty (SNil))))
      (if (sexpr-colon? colon)
        (match (parse-ast-type dispatch ty)
          [(OkAstType parsed-ty) (OkAstParam (AstParam name parsed-ty))]
          [(ErrAstType message) (ErrAstParam message)])
        (ErrAstParam "parse: expected ':' in parameter"))]
    [_ (ErrAstParam "parse: malformed parameter")]))

(define (parse-ast-param-list [dispatch : SymI64Env] [s : Sexpr]) : ResultAstParamList
  (match s
    [(SNil) (OkAstParamList AstParamNil)]
    [(SCons head tail)
      (match (parse-ast-param dispatch head)
        [(OkAstParam parsed-head)
          (match (parse-ast-param-list dispatch tail)
            [(OkAstParamList parsed-tail)
              (OkAstParamList (AstParamCons parsed-head parsed-tail))]
            [(ErrAstParamList message) (ErrAstParamList message)])]
        [(ErrAstParam message) (ErrAstParamList message)])]
    [_ (ErrAstParamList "parse: malformed parameter list")]))

(define (parse-ast-field-def [dispatch : SymI64Env] [s : Sexpr]) : ResultAstFieldDef
  (match s
    [(SCons (SSym name) (SCons ty (SNil)))
      (match (parse-ast-type dispatch ty)
        [(OkAstType parsed-ty) (OkAstFieldDef (AstFieldDef name parsed-ty))]
        [(ErrAstType message) (ErrAstFieldDef message)])]
    [_ (ErrAstFieldDef "parse: malformed field definition")]))

(define (parse-ast-field-def-list [dispatch : SymI64Env] [s : Sexpr]) : ResultAstFieldDefList
  (match s
    [(SNil) (OkAstFieldDefList AstFieldDefNil)]
    [(SCons head tail)
      (match (parse-ast-field-def dispatch head)
        [(OkAstFieldDef parsed-head)
          (match (parse-ast-field-def-list dispatch tail)
            [(OkAstFieldDefList parsed-tail)
              (OkAstFieldDefList (AstFieldDefCons parsed-head parsed-tail))]
            [(ErrAstFieldDefList message) (ErrAstFieldDefList message)])]
        [(ErrAstFieldDef message) (ErrAstFieldDefList message)])]
    [_ (ErrAstFieldDefList "parse: malformed field list")]))

(define (parse-ast-variant-def [dispatch : SymI64Env] [s : Sexpr]) : ResultAstVariantDef
  (match s
    [(SCons (SSym name) fields)
      (match (parse-ast-type-list dispatch fields)
        [(OkAstTypeList parsed-fields)
          (OkAstVariantDef (AstVariantDef name parsed-fields))]
        [(ErrAstTypeList message) (ErrAstVariantDef message)])]
    [_ (ErrAstVariantDef "parse: malformed variant definition")]))

(define (parse-ast-variant-def-list [dispatch : SymI64Env] [s : Sexpr]) : ResultAstVariantDefList
  (match s
    [(SNil) (OkAstVariantDefList AstVariantDefNil)]
    [(SCons head tail)
      (match (parse-ast-variant-def dispatch head)
        [(OkAstVariantDef parsed-head)
          (match (parse-ast-variant-def-list dispatch tail)
            [(OkAstVariantDefList parsed-tail)
              (OkAstVariantDefList (AstVariantDefCons parsed-head parsed-tail))]
            [(ErrAstVariantDefList message) (ErrAstVariantDefList message)])]
        [(ErrAstVariantDef message) (ErrAstVariantDefList message)])]
    [_ (ErrAstVariantDefList "parse: malformed variant list")]))

(define (parse-ast-pattern-list [dispatch : SymI64Env] [s : Sexpr]) : ResultAstPatternList
  (match s
    [(SNil) (OkAstPatternList AstPatternNil)]
    [(SCons head tail)
      (match (parse-ast-pattern dispatch head)
        [(OkAstPattern parsed-head)
          (match (parse-ast-pattern-list dispatch tail)
            [(OkAstPatternList parsed-tail)
              (OkAstPatternList (AstPatternCons parsed-head parsed-tail))]
            [(ErrAstPatternList message) (ErrAstPatternList message)])]
        [(ErrAstPattern message) (ErrAstPatternList message)])]
    [_ (ErrAstPatternList "parse: malformed pattern list")]))

(define (parse-ast-pattern [dispatch : SymI64Env] [s : Sexpr]) : ResultAstPattern
  (match s
    [(SInt n) (OkAstPattern (AstPatLiteral (AstLitInt n)))]
    [(SStr text) (OkAstPattern (AstPatLiteral (AstLitString text)))]
    [(SChar c) (OkAstPattern (AstPatLiteral (AstLitChar c)))]
    [(SSym name)
      (let ([tag : i64 (compiler-parse-dispatch-tag dispatch name)])
        (if (= tag (compiler-parse-tag-pattern-wildcard))
          (OkAstPattern AstPatWildcard)
          (if (= tag (compiler-parse-tag-lit-true))
            (OkAstPattern (AstPatLiteral (AstLitBool true)))
            (if (= tag (compiler-parse-tag-lit-false))
              (OkAstPattern (AstPatLiteral (AstLitBool false)))
              (OkAstPattern (AstPatBinding name))))))]
    [(SCons (SSym name) args)
      (match (parse-ast-pattern-list dispatch args)
        [(OkAstPatternList parsed-args)
          (OkAstPattern (AstPatVariant name parsed-args))]
        [(ErrAstPatternList message) (ErrAstPattern message)])]
    [_ (ErrAstPattern "parse: expected pattern")]))

(define (default-source-span) : SourceSpan
  (SourceSpan 0 0 0 0))

(define (source-span-to-ast-source-span [span : SourceSpan]) : AstSourceSpan
  (AstSourceSpan
    (span-start-line span)
    (span-start-col span)
    (span-end-line span)
    (span-end-col span)))

(define (ast-source-span-eq?
  [span : AstSourceSpan]
  [start-line : i64]
  [start-col : i64]
  [end-line : i64]
  [end-col : i64]) : bool
  (and
    (= (struct-get span start-line) start-line)
    (and
      (= (struct-get span start-col) start-col)
      (and
        (= (struct-get span end-line) end-line)
        (= (struct-get span end-col) end-col)))))

(define (spanned-ast-expr [inner : AstExpr] [span : SourceSpan]) : AstExpr
  (AstExprSpanned inner (source-span-to-ast-source-span span)))

(define (spanned-sexpr-colon? [s : SpannedSexpr]) : bool
  (match s
    [(SpSSym text _) (string-eq text ":")]
    [_ false]))

(define (sexpr->spanned-sexpr [s : Sexpr]) : SpannedSexpr
  (let ([span : SourceSpan (default-source-span)])
    (match s
      [(SInt n) (SpSInt n span)]
      [(SSym name) (SpSSym name span)]
      [(SNil) (SpSNil span)]
      [(SCons head tail)
        (SpSCons (sexpr->spanned-sexpr head) (sexpr->spanned-sexpr tail) span)]
      [(SStr text) (SpSStr text span)]
      [(SChar c) (SpSChar c span)])))

(define (ast-expr-inner-tag [expr : AstExpr]) : i64
  (match expr
    [(AstExprSpanned inner _) (ast-expr-tag inner)]
    [_ (ast-expr-tag expr)]))

(define (parse-ast-expr-list [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstExprList
  (match s
    [(SpSNil _) (OkAstExprList AstExprNil)]
    [(SpSCons head tail _)
      (match (parse-ast-expr dispatch head)
        [(OkAstExpr parsed-head)
          (match (parse-ast-expr-list dispatch tail)
            [(OkAstExprList parsed-tail)
              (OkAstExprList (AstExprCons parsed-head parsed-tail))]
            [(ErrAstExprList message) (ErrAstExprList message)])]
        [(ErrAstExpr message) (ErrAstExprList message)])]
    [_ (ErrAstExprList "parse: malformed expression list")]))

(define (parse-ast-binary
  [dispatch : SymI64Env]
  [op : AstBinOp]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons left (SpSCons right (SpSNil _) _) _)
      (match (parse-ast-expr dispatch left)
        [(OkAstExpr parsed-left)
          (match (parse-ast-expr dispatch right)
            [(OkAstExpr parsed-right)
              (OkAstExpr (AstExprBinary op parsed-left parsed-right))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed binary expression")]))

(define (parse-ast-unary
  [dispatch : SymI64Env]
  [op : AstUnOp]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr (SpSNil _) _)
      (match (parse-ast-expr dispatch expr)
        [(OkAstExpr parsed-expr) (OkAstExpr (AstExprUnary op parsed-expr))]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed unary expression")]))

(define (parse-ast-if [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons cond (SpSCons then-branch (SpSCons else-branch (SpSNil _) _) _) _)
      (match (parse-ast-expr dispatch cond)
        [(OkAstExpr parsed-cond)
          (match (parse-ast-expr dispatch then-branch)
            [(OkAstExpr parsed-then)
              (match (parse-ast-expr dispatch else-branch)
                [(OkAstExpr parsed-else)
                  (OkAstExpr (AstExprIf parsed-cond parsed-then parsed-else))]
                [(ErrAstExpr message) (ErrAstExpr message)])]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed if")]))

(define (parse-ast-cond-test-arm
  [dispatch : SymI64Env]
  [cond : SpannedSexpr]
  [body : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr dispatch cond)
    [(OkAstExpr parsed-cond)
      (match (parse-ast-expr dispatch body)
        [(OkAstExpr parsed-body)
          (match (parse-ast-cond-arms dispatch rest true)
            [(OkAstExpr parsed-else)
              (OkAstExpr (AstExprIf parsed-cond parsed-body parsed-else))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [(ErrAstExpr message) (ErrAstExpr message)]))

(define (parse-ast-cond-arms
  [dispatch : SymI64Env]
  [arms : SpannedSexpr]
  [has-test : bool]) : ResultAstExpr
  (match arms
    [(SpSNil _) (ErrAstExpr "parse: cond requires final else arm")]
    [(SpSCons arm rest _)
      (match arm
        [(SpSCons head (SpSCons body (SpSNil _) _) _)
          (match head
            [(SpSSym name _)
              (if (string-eq name "else")
                (if has-test
                  (match rest
                    [(SpSNil _) (parse-ast-expr dispatch body)]
                    [_ (ErrAstExpr "parse: cond else arm must be final")])
                  (match rest
                    [(SpSNil _)
                      (ErrAstExpr "parse: cond requires at least one test arm")]
                    [_ (ErrAstExpr "parse: cond else arm must be final")]))
                (parse-ast-cond-test-arm dispatch head body rest))]
            [_ (parse-ast-cond-test-arm dispatch head body rest)])]
        [_ (ErrAstExpr "parse: malformed cond arm")])]
    [_ (ErrAstExpr "parse: malformed cond")]))

(define (parse-ast-cond [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (parse-ast-cond-arms dispatch rest false))

(define (parse-ast-while [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons cond (SpSCons body (SpSNil _) _) _)
      (match (parse-ast-expr dispatch cond)
        [(OkAstExpr parsed-cond)
          (match (parse-ast-expr dispatch body)
            [(OkAstExpr parsed-body)
              (OkAstExpr (AstExprWhile parsed-cond parsed-body))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed while")]))

(define (parse-ast-set [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons (SpSSym name _) (SpSCons value (SpSNil _) _) _)
      (match (parse-ast-expr dispatch value)
        [(OkAstExpr parsed-value) (OkAstExpr (AstExprSet name parsed-value))]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed set!")]))

(define (parse-ast-ann-like
  [dispatch : SymI64Env]
  [is-cast : bool]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr (SpSCons colon (SpSCons ty (SpSNil _) _) _) _)
      (if (spanned-sexpr-colon? colon)
        (match (parse-ast-expr dispatch expr)
          [(OkAstExpr parsed-expr)
            (match (parse-ast-type dispatch (spanned-sexpr-form ty))
              [(OkAstType parsed-ty)
                (if is-cast
                  (OkAstExpr (AstExprCast parsed-expr parsed-ty))
                  (OkAstExpr (AstExprAnn parsed-expr parsed-ty)))]
              [(ErrAstType message) (ErrAstExpr message)])]
          [(ErrAstExpr message) (ErrAstExpr message)])
        (ErrAstExpr "parse: expected ':' in annotation"))]
    [_ (ErrAstExpr "parse: malformed annotation")]))

(define (parse-ast-let-binding [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstLetBinding
  (match s
    [(SpSCons
        (SpSSym name _)
        (SpSCons colon (SpSCons ty (SpSCons value (SpSNil _) _) _) _)
        _)
      (if (spanned-sexpr-colon? colon)
        (match (parse-ast-type dispatch (spanned-sexpr-form ty))
          [(OkAstType parsed-ty)
            (match (parse-ast-expr dispatch value)
              [(OkAstExpr parsed-value)
                (OkAstLetBinding
                  (AstLetBinding name (AstSomeType parsed-ty) parsed-value))]
              [(ErrAstExpr message) (ErrAstLetBinding message)])]
          [(ErrAstType message) (ErrAstLetBinding message)])
        (ErrAstLetBinding "parse: expected ':' in let binding"))]
    [(SpSCons (SpSSym name _) (SpSCons value (SpSNil _) _) _)
      (match (parse-ast-expr dispatch value)
        [(OkAstExpr parsed-value)
          (OkAstLetBinding (AstLetBinding name AstNoType parsed-value))]
        [(ErrAstExpr message) (ErrAstLetBinding message)])]
    [_ (ErrAstLetBinding "parse: malformed let binding")]))

(define (parse-ast-let-binding-list [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstLetBindingList
  (match s
    [(SpSNil _) (OkAstLetBindingList AstLetBindingNil)]
    [(SpSCons head tail _)
      (match (parse-ast-let-binding dispatch head)
        [(OkAstLetBinding parsed-head)
          (match (parse-ast-let-binding-list dispatch tail)
            [(OkAstLetBindingList parsed-tail)
              (OkAstLetBindingList (AstLetBindingCons parsed-head parsed-tail))]
            [(ErrAstLetBindingList message) (ErrAstLetBindingList message)])]
        [(ErrAstLetBinding message) (ErrAstLetBindingList message)])]
    [_ (ErrAstLetBindingList "parse: malformed let binding list")]))

(define (parse-ast-let [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons bindings (SpSCons body (SpSNil _) _) _)
      (match (parse-ast-let-binding-list dispatch bindings)
        [(OkAstLetBindingList parsed-bindings)
          (match (parse-ast-expr dispatch body)
            [(OkAstExpr parsed-body)
              (OkAstExpr (AstExprLet parsed-bindings parsed-body))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [(ErrAstLetBindingList message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed let")]))

(define (parse-ast-lambda [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons
        params
        (SpSCons colon (SpSCons ret (SpSCons body (SpSNil _) _) _) _)
        _)
      (if (spanned-sexpr-colon? colon)
        (match (parse-ast-param-list dispatch (spanned-sexpr-form params))
          [(OkAstParamList parsed-params)
            (match (parse-ast-type dispatch (spanned-sexpr-form ret))
              [(OkAstType parsed-ret)
                (match (parse-ast-expr dispatch body)
                  [(OkAstExpr parsed-body)
                    (OkAstExpr
                      (AstExprLambda
                        parsed-params
                        (AstSomeType parsed-ret)
                        parsed-body))]
                  [(ErrAstExpr message) (ErrAstExpr message)])]
              [(ErrAstType message) (ErrAstExpr message)])]
          [(ErrAstParamList message) (ErrAstExpr message)])
        (ErrAstExpr "parse: expected ':' in lambda"))]
    [(SpSCons params (SpSCons body (SpSNil _) _) _)
      (match (parse-ast-param-list dispatch (spanned-sexpr-form params))
        [(OkAstParamList parsed-params)
          (match (parse-ast-expr dispatch body)
            [(OkAstExpr parsed-body)
              (OkAstExpr (AstExprLambda parsed-params AstNoType parsed-body))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [(ErrAstParamList message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed lambda")]))

(define (parse-ast-tuple-ref [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr (SpSCons (SpSInt index _) (SpSNil _) _) _)
      (match (parse-ast-expr dispatch expr)
        [(OkAstExpr parsed-expr)
          (OkAstExpr (AstExprTupleRef parsed-expr index))]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [(SpSCons _ (SpSCons _ (SpSNil _) _) _)
      (ErrAstExpr "parse: tuple-ref index must be integer")]
    [_ (ErrAstExpr "parse: malformed tuple-ref")]))

(define (parse-ast-make-array [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons elem-ty (SpSCons len (SpSNil _) _) _)
      (match (parse-ast-type dispatch (spanned-sexpr-form elem-ty))
        [(OkAstType parsed-ty)
          (match (parse-ast-expr dispatch len)
            [(OkAstExpr parsed-len)
              (OkAstExpr (AstExprMakeArray parsed-ty parsed-len))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [(ErrAstType message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed make-array")]))

(define (parse-ast-array-ref-like
  [dispatch : SymI64Env]
  [is-string : bool]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr (SpSCons index (SpSNil _) _) _)
      (match (parse-ast-expr dispatch expr)
        [(OkAstExpr parsed-expr)
          (match (parse-ast-expr dispatch index)
            [(OkAstExpr parsed-index)
              (if is-string
                (OkAstExpr (AstExprStringRef parsed-expr parsed-index))
                (OkAstExpr (AstExprArrayRef parsed-expr parsed-index)))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed ref expression")]))

(define (parse-ast-array-set [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr (SpSCons index (SpSCons value (SpSNil _) _) _) _)
      (match (parse-ast-expr dispatch expr)
        [(OkAstExpr parsed-expr)
          (match (parse-ast-expr dispatch index)
            [(OkAstExpr parsed-index)
              (match (parse-ast-expr dispatch value)
                [(OkAstExpr parsed-value)
                  (OkAstExpr
                    (AstExprArraySet parsed-expr parsed-index parsed-value))]
                [(ErrAstExpr message) (ErrAstExpr message)])]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed array-set!")]))

(define (parse-ast-struct-get [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr (SpSCons (SpSSym field _) (SpSNil _) _) _)
      (match (parse-ast-expr dispatch expr)
        [(OkAstExpr parsed-expr)
          (OkAstExpr (AstExprStructGet parsed-expr field))]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed struct-get")]))

(define (parse-ast-match-arm [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstMatchArm
  (match s
    [(SpSCons pattern (SpSCons body (SpSNil _) _) _)
      (match (parse-ast-pattern dispatch (spanned-sexpr-form pattern))
        [(OkAstPattern parsed-pattern)
          (match (parse-ast-expr dispatch body)
            [(OkAstExpr parsed-body)
              (OkAstMatchArm (AstMatchArm parsed-pattern parsed-body))]
            [(ErrAstExpr message) (ErrAstMatchArm message)])]
        [(ErrAstPattern message) (ErrAstMatchArm message)])]
    [_ (ErrAstMatchArm "parse: malformed match arm")]))

(define (parse-ast-match-arm-list [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstMatchArmList
  (match s
    [(SpSNil _) (OkAstMatchArmList AstMatchArmNil)]
    [(SpSCons head tail _)
      (match (parse-ast-match-arm dispatch head)
        [(OkAstMatchArm parsed-head)
          (match (parse-ast-match-arm-list dispatch tail)
            [(OkAstMatchArmList parsed-tail)
              (OkAstMatchArmList (AstMatchArmCons parsed-head parsed-tail))]
            [(ErrAstMatchArmList message) (ErrAstMatchArmList message)])]
        [(ErrAstMatchArm message) (ErrAstMatchArmList message)])]
    [_ (ErrAstMatchArmList "parse: malformed match arm list")]))

(define (parse-ast-match [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons scrutinee arms _)
      (match (parse-ast-expr dispatch scrutinee)
        [(OkAstExpr parsed-scrutinee)
          (match (parse-ast-match-arm-list dispatch arms)
            [(OkAstMatchArmList parsed-arms)
              (OkAstExpr (AstExprMatch parsed-scrutinee parsed-arms))]
            [(ErrAstMatchArmList message) (ErrAstExpr message)])]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed match")]))

(define (parse-ast-foreach [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons
        (SpSCons
          (SpSCons
            (SpSSym index _)
            (SpSCons
              colon
              (SpSCons index-ty (SpSCons start (SpSCons end (SpSNil _) _) _) _)
              _)
            _)
          (SpSNil _)
          _)
        (SpSCons body (SpSNil _) _)
        _)
      (if (spanned-sexpr-colon? colon)
        (match (parse-ast-type dispatch (spanned-sexpr-form index-ty))
          [(OkAstType parsed-index-ty)
            (match (parse-ast-expr dispatch start)
              [(OkAstExpr parsed-start)
                (match (parse-ast-expr dispatch end)
                  [(OkAstExpr parsed-end)
                    (match (parse-ast-expr dispatch body)
                      [(OkAstExpr parsed-body)
                        (OkAstExpr
                          (AstExprForeach
                            index
                            parsed-index-ty
                            parsed-start
                            parsed-end
                            parsed-body))]
                      [(ErrAstExpr message) (ErrAstExpr message)])]
                  [(ErrAstExpr message) (ErrAstExpr message)])]
              [(ErrAstExpr message) (ErrAstExpr message)])]
          [(ErrAstType message) (ErrAstExpr message)])
        (ErrAstExpr "parse: expected ':' in foreach"))]
    [_ (ErrAstExpr "parse: malformed foreach")]))

(define (parse-ast-call
  [dispatch : SymI64Env]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr dispatch head)
    [(OkAstExpr parsed-head)
      (match (parse-ast-expr-list dispatch rest)
        [(OkAstExprList parsed-args)
          (OkAstExpr (AstExprCall parsed-head parsed-args))]
        [(ErrAstExprList message) (ErrAstExpr message)])]
    [(ErrAstExpr message) (ErrAstExpr message)]))

(define (parse-ast-begin [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch rest)
    [(OkAstExprList exprs) (OkAstExpr (AstExprBegin exprs))]
    [(ErrAstExprList message) (ErrAstExpr message)]))

(define (parse-ast-tuple [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch rest)
    [(OkAstExprList exprs) (OkAstExpr (AstExprTuple exprs))]
    [(ErrAstExprList message) (ErrAstExpr message)]))

(define (parse-ast-array [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch rest)
    [(OkAstExprList exprs) (OkAstExpr (AstExprArray exprs))]
    [(ErrAstExprList message) (ErrAstExpr message)]))

(define (parse-ast-list-expr-tag
  [dispatch : SymI64Env]
  [tag : i64]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstExpr
  (if (= tag (compiler-parse-tag-expr-if))
    (parse-ast-if dispatch rest)
    (if (= tag (compiler-parse-tag-expr-let))
      (parse-ast-let dispatch rest)
      (if (= tag (compiler-parse-tag-expr-lambda))
        (parse-ast-lambda dispatch rest)
        (if (= tag (compiler-parse-tag-expr-while))
          (parse-ast-while dispatch rest)
          (if (= tag (compiler-parse-tag-expr-begin))
            (parse-ast-begin dispatch rest)
            (if (= tag (compiler-parse-tag-expr-set))
              (parse-ast-set dispatch rest)
              (if (= tag (compiler-parse-tag-expr-ann))
                (parse-ast-ann-like dispatch false rest)
                (if (= tag (compiler-parse-tag-expr-cast))
                  (parse-ast-ann-like dispatch true rest)
                  (if (= tag (compiler-parse-tag-expr-tuple))
                    (parse-ast-tuple dispatch rest)
                    (if (= tag (compiler-parse-tag-expr-tuple-ref))
                      (parse-ast-tuple-ref dispatch rest)
                      (if (= tag (compiler-parse-tag-expr-array))
                        (parse-ast-array dispatch rest)
                        (if (= tag (compiler-parse-tag-expr-make-array))
                          (parse-ast-make-array dispatch rest)
                          (if (= tag (compiler-parse-tag-expr-array-ref))
                            (parse-ast-array-ref-like dispatch false rest)
                            (if (= tag (compiler-parse-tag-expr-array-set))
                              (parse-ast-array-set dispatch rest)
                              (if (= tag (compiler-parse-tag-expr-string-ref))
                                (parse-ast-array-ref-like dispatch true rest)
                                (if (= tag (compiler-parse-tag-expr-char-at))
                                  (parse-ast-array-ref-like dispatch true rest)
                                  (if (= tag (compiler-parse-tag-expr-match))
                                    (parse-ast-match dispatch rest)
                                    (if (=
                                      tag
                                      (compiler-parse-tag-expr-foreach))
                                      (parse-ast-foreach dispatch rest)
                                      (if (=
                                        tag
                                        (compiler-parse-tag-expr-struct-get))
                                        (parse-ast-struct-get dispatch rest)
                                        (parse-ast-call dispatch head rest)))))))))))))))))))))

(define (parse-ast-list-expr
  [dispatch : SymI64Env]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match head
    [(SpSSym op _)
      (let ([tag : i64 (compiler-parse-dispatch-tag dispatch op)])
        (if (= tag (compiler-parse-tag-expr-cond))
          (parse-ast-cond dispatch rest)
          (if (ast-unop-tag? tag)
            (parse-ast-unary dispatch (ast-unop-from-tag tag) rest)
            (if (ast-binop-tag? tag)
              (parse-ast-binary dispatch (ast-binop-from-tag tag) rest)
              (parse-ast-list-expr-tag dispatch tag head rest)))))]
    [_ (parse-ast-call dispatch head rest)]))

(define (parse-ast-expr [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstExpr
  (let ([span : SourceSpan (spanned-sexpr-span s)])
    (match s
      [(SpSInt n _)
        (OkAstExpr (spanned-ast-expr (AstExprLiteral (AstLitInt n)) span))]
      [(SpSStr text _)
        (OkAstExpr (spanned-ast-expr (AstExprLiteral (AstLitString text)) span))]
      [(SpSChar c _)
        (OkAstExpr (spanned-ast-expr (AstExprLiteral (AstLitChar c)) span))]
      [(SpSSym name _)
        (let ([tag : i64 (compiler-parse-dispatch-tag dispatch name)])
          (if (= tag (compiler-parse-tag-lit-true))
            (OkAstExpr
              (spanned-ast-expr (AstExprLiteral (AstLitBool true)) span))
            (if (= tag (compiler-parse-tag-lit-false))
              (OkAstExpr
                (spanned-ast-expr (AstExprLiteral (AstLitBool false)) span))
              (if (= tag (compiler-parse-tag-unit))
                (OkAstExpr (spanned-ast-expr (AstExprLiteral AstLitUnit) span))
                (OkAstExpr (spanned-ast-expr (AstExprVar name) span))))))]
      [(SpSCons head rest _)
        (match (parse-ast-list-expr dispatch head rest)
          [(OkAstExpr inner) (OkAstExpr (spanned-ast-expr inner span))]
          [(ErrAstExpr message) (ErrAstExpr message)])]
      [_ (ErrAstExpr "parse: malformed expression")])))

(define (parse-ast-define-value
  [dispatch : SymI64Env]
  [name : String]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons colon (SpSCons ty (SpSCons value (SpSNil _) _) _) _)
      (if (spanned-sexpr-colon? colon)
        (match (parse-ast-type dispatch (spanned-sexpr-form ty))
          [(OkAstType parsed-ty)
            (match (parse-ast-expr dispatch value)
              [(OkAstExpr parsed-value)
                (OkAstDecl
                  (AstDeclDef name (AstSomeType parsed-ty) parsed-value))]
              [(ErrAstExpr message) (ErrAstDecl message)])]
          [(ErrAstType message) (ErrAstDecl message)])
        (ErrAstDecl "parse: expected ':' in definition"))]
    [(SpSCons value (SpSNil _) _)
      (match (parse-ast-expr dispatch value)
        [(OkAstExpr parsed-value)
          (OkAstDecl (AstDeclDef name AstNoType parsed-value))]
        [(ErrAstExpr message) (ErrAstDecl message)])]
    [_ (ErrAstDecl "parse: malformed value definition")]))

(define (parse-ast-define-fn
  [dispatch : SymI64Env]
  [name : String]
  [params : Sexpr]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons colon (SpSCons ret (SpSCons body (SpSNil _) _) _) _)
      (if (spanned-sexpr-colon? colon)
        (match (parse-ast-param-list dispatch params)
          [(OkAstParamList parsed-params)
            (match (parse-ast-type dispatch (spanned-sexpr-form ret))
              [(OkAstType parsed-ret)
                (match (parse-ast-expr dispatch body)
                  [(OkAstExpr parsed-body)
                    (OkAstDecl
                      (AstDeclDefFn name parsed-params parsed-ret parsed-body))]
                  [(ErrAstExpr message) (ErrAstDecl message)])]
              [(ErrAstType message) (ErrAstDecl message)])]
          [(ErrAstParamList message) (ErrAstDecl message)])
        (ErrAstDecl "parse: expected ':' in function definition"))]
    [(SpSCons body (SpSNil _) _)
      (match (parse-ast-param-list dispatch params)
        [(OkAstParamList parsed-params)
          (match (parse-ast-expr dispatch body)
            [(OkAstExpr parsed-body)
              (OkAstDecl
                (AstDeclDefFn name parsed-params (AstTyUnit) parsed-body))]
            [(ErrAstExpr message) (ErrAstDecl message)])]
        [(ErrAstParamList message) (ErrAstDecl message)])]
    [_ (ErrAstDecl "parse: malformed function definition")]))

(define (parse-ast-define [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons (SpSSym name _) after-name _)
      (parse-ast-define-value dispatch name after-name)]
    [(SpSCons (SpSCons (SpSSym name _) params _) after-header _)
      (parse-ast-define-fn
        dispatch
        name
        (spanned-sexpr-form params)
        after-header)]
    [_ (ErrAstDecl "parse: malformed define")]))

(define (parse-ast-extern [dispatch : SymI64Env] [rest : Sexpr]) : ResultAstDecl
  (match rest
    [(SCons (SSym name) (SCons colon (SCons ty (SNil))))
      (if (sexpr-colon? colon)
        (match (parse-ast-type dispatch ty)
          [(OkAstType parsed-ty) (OkAstDecl (AstDeclExtern name parsed-ty))]
          [(ErrAstType message) (ErrAstDecl message)])
        (ErrAstDecl "parse: expected ':' in extern"))]
    [_ (ErrAstDecl "parse: malformed extern")]))

(define (parse-ast-defenum [dispatch : SymI64Env] [rest : Sexpr]) : ResultAstDecl
  (match rest
    [(SCons (SSym name) variants)
      (match variants
        [(SNil) (ErrAstDecl "parse: defenum needs at least one variant")]
        [_
          (match (parse-ast-variant-def-list dispatch variants)
            [(OkAstVariantDefList parsed-variants)
              (OkAstDecl (AstDeclDefEnum name parsed-variants))]
            [(ErrAstVariantDefList message) (ErrAstDecl message)])])]
    [_ (ErrAstDecl "parse: malformed defenum")]))

(define (parse-ast-defstruct [dispatch : SymI64Env] [rest : Sexpr]) : ResultAstDecl
  (match rest
    [(SCons (SSym name) fields)
      (match fields
        [(SNil) (ErrAstDecl "parse: defstruct needs at least one field")]
        [_
          (match (parse-ast-field-def-list dispatch fields)
            [(OkAstFieldDefList parsed-fields)
              (OkAstDecl (AstDeclDefStruct name parsed-fields))]
            [(ErrAstFieldDefList message) (ErrAstDecl message)])])]
    [_ (ErrAstDecl "parse: malformed defstruct")]))

(define (parse-ast-import [rest : Sexpr]) : ResultAstDecl
  (match rest
    [(SCons (SStr path) (SNil)) (OkAstDecl (AstDeclImport path))]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-decl [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstDecl
  (match s
    [(SpSCons (SpSSym head _) rest _)
      (let ([tag : i64 (compiler-parse-dispatch-tag dispatch head)])
        (if (= tag (compiler-parse-tag-decl-define))
          (parse-ast-define dispatch rest)
          (if (= tag (compiler-parse-tag-decl-extern))
            (parse-ast-extern dispatch (spanned-sexpr-form rest))
            (if (= tag (compiler-parse-tag-decl-defenum))
              (parse-ast-defenum dispatch (spanned-sexpr-form rest))
              (if (= tag (compiler-parse-tag-decl-defstruct))
                (parse-ast-defstruct dispatch (spanned-sexpr-form rest))
                (if (= tag (compiler-parse-tag-decl-import))
                  (parse-ast-import (spanned-sexpr-form rest))
                  (ErrAstDecl "parse: expected declaration")))))))]
    [_ (ErrAstDecl "parse: malformed declaration")]))

(define (parse-ast-program-forms
  [dispatch : SymI64Env]
  [toks : (Array Token)]
  [cur : (Array i64)]) : ResultAstDeclList
  (if (= (peek-tag toks cur) (tag-end))
    (OkAstDeclList AstDeclNil)
    (match (read-form-result toks cur)
      [(OkSexpr form)
        (match (parse-ast-decl dispatch (sexpr->spanned-sexpr form))
          [(OkAstDecl decl)
            (match (parse-ast-program-forms dispatch toks cur)
              [(OkAstDeclList rest) (OkAstDeclList (AstDeclCons decl rest))]
              [(ErrAstDeclList message) (ErrAstDeclList message)])]
          [(ErrAstDecl message) (ErrAstDeclList message)])]
      [(ErrSexpr message) (ErrAstDeclList message)])))

(define (parse-ast-program-spanned-forms
  [dispatch : SymI64Env]
  [toks : (Array SpannedToken)]
  [cur : (Array i64)]) : ResultAstDeclList
  (if (= (peek-spanned-tag toks cur) (tag-end))
    (OkAstDeclList AstDeclNil)
    (match (read-form-spanned-result toks cur)
      [(OkSpannedSexpr form)
        (match (parse-ast-decl dispatch form)
          [(OkAstDecl decl)
            (match (parse-ast-program-spanned-forms dispatch toks cur)
              [(OkAstDeclList rest) (OkAstDeclList (AstDeclCons decl rest))]
              [(ErrAstDeclList message) (ErrAstDeclList message)])]
          [(ErrAstDecl message) (ErrAstDeclList message)])]
      [(ErrSpannedSexpr err) (ErrAstDeclList (source-error-message err))])))

(define (parse-ast-program [toks : (Array Token)]) : ResultAstProgram
  (let ([cur : (Array i64) (make-array i64 1)])
    (let ([dispatch : SymI64Env (compiler-parse-dispatch-env)])
      (begin
        (array-set! cur 0 0)
        (match (parse-ast-program-forms dispatch toks cur)
          [(OkAstDeclList decls) (OkAstProgram (AstProgram decls))]
          [(ErrAstDeclList message) (ErrAstProgram message)])))))

(define (parse-ast-program-spanned [toks : (Array SpannedToken)]) : ResultAstProgram
  (let ([cur : (Array i64) (make-array i64 1)])
    (let ([dispatch : SymI64Env (compiler-parse-dispatch-env)])
      (begin
        (array-set! cur 0 0)
        (match (parse-ast-program-spanned-forms dispatch toks cur)
          [(OkAstDeclList decls) (OkAstProgram (AstProgram decls))]
          [(ErrAstDeclList message) (ErrAstProgram message)])))))

(define (parse-ast-source [src : String]) : ResultAstProgram
  (match (lex-spanned-result src)
    [(OkSpannedTokens toks) (parse-ast-program-spanned toks)]
    [(ErrSpannedTokens err) (ErrAstProgram (source-error-message err))]))

(define (ast-decl-list-count [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons _ rest) (+ 1 (ast-decl-list-count rest))]))

(define (ast-decl-list-tag-sum [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons decl rest)
      (+ (ast-decl-tag decl) (ast-decl-list-tag-sum rest))]))

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
            (ast-expr-inner-tag body)
            (ast-main-body-tag rest))]
        [_ (ast-main-body-tag rest)])]))

(define (compiler-parse-nested-span-ok?) : bool
  (match (parse-ast-source "(define (main) : i64 (+ 1 (* 2 3)))")
    [(OkAstProgram (AstProgram (AstDeclCons (AstDeclDefFn _ _ _ body) _)))
      (match body
        [(AstExprSpanned inner outer-span)
          (match inner
            [(AstExprBinary _ _ right)
              (and
                (ast-source-span-eq? outer-span 1 22 1 34)
                (match right
                  [(AstExprSpanned nested-inner nested-span)
                    (match nested-inner
                      [(AstExprBinary _ _ _)
                        (ast-source-span-eq? nested-span 1 27 1 33)]
                      [_ false])]
                  [_ false]))]
            [_ false])]
        [_ false])]
    [_ false]))

(define (compiler-parse-decl-error-span-ok?) : bool
  (match (read-spanned-result (lex-spanned "(bogus 1)"))
    [(OkSpannedSexpr form)
      (match (parse-ast-decl (compiler-parse-dispatch-env) form)
        [(ErrAstDecl message)
          (and
            (string-eq message "parse: expected declaration")
            (ast-source-span-eq?
              (source-span-to-ast-source-span (spanned-sexpr-span form))
              1
              1
              1
              9))]
        [(OkAstDecl _) false])]
    [(ErrSpannedSexpr _) false]))

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
      (cond
        [(and (= x 42) true)
         (match (Some x) [(Some v) v] [_ 0])]
        [else 0]))))")

(define (compiler-parse-smoke-score [program : AstProgram]) : i64
  (match program
    [(AstProgram decls)
      (+
        (ast-decl-list-count decls)
        (+
          (ast-decl-list-tag-sum decls)
          (+
            (ast-main-body-tag decls)
            (if (ast-first-import-ok? decls)
              1
              0))))]))

(define (compiler-parse-smoke) : i64
  (match (parse-ast-source (compiler-parse-smoke-source))
    [(OkAstProgram program)
      (if (= (compiler-parse-smoke-score program) 36)
        (if (compiler-parse-nested-span-ok?)
          (if (compiler-parse-decl-error-span-ok?)
            42
            (begin
              (panic "parse: compiler AST declaration span mismatch")
              0))
          (begin
            (panic "parse: compiler AST nested span mismatch")
            0))
        (begin
          (panic "parse: compiler AST smoke score mismatch")
          0))]
    [(ErrAstProgram message)
      (begin
        (panic message)
        0)]))