;; compiler_parse_core.tl - Sexpr -> real compiler AST parser (#335).
;;
;; This module targets `compiler_ast_types.tl`, not the smaller
;; compile_smoke AST. It stays parser-only: later #27 work can reuse the
;; parsed `AstProgram` for typechecking/lowering once those selfhost passes
;; exist.
(import "compiler_ast_types.tl")

(import "compiler_diagnostic.tl")

(import "read.tl")

(import "sym_i64_env.tl")

(defenum ResultAstType
  (OkAstType AstType)
  (ErrAstType String))

(defenum ResultAstReduceOp
  (OkAstReduceOp AstReduceOp)
  (ErrAstReduceOp String))

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

(defenum ResultAstStructRepr
  (OkAstStructRepr AstStructRepr)
  (ErrAstStructRepr String))

(defenum ResultAstStructDefParts
  (OkAstStructDefParts AstStructRepr AstFieldDefList)
  (ErrAstStructDefParts String))

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

(defenum ResultAstResourceBinding
  (OkAstResourceBinding AstResourceBinding)
  (ErrAstResourceBinding String))

(defenum ResultAstResourceBindingList
  (OkAstResourceBindingList AstResourceBindingList)
  (ErrAstResourceBindingList String))

(defenum ResultAstLetParts
  (OkAstLetParts AstLetBindingList AstExpr)
  (ErrAstLetParts String))

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

(defenum AstReplItem
  (AstReplDecl AstDecl)
  (AstReplExpr AstExpr))

(defenum ResultAstReplItem
  (OkAstReplItem AstReplItem)
  (ErrAstReplItem String))

(defenum ResultAstDeclListDiagnostic
  (OkAstDeclListDiagnostic AstDeclList)
  (ErrAstDeclListDiagnostic CompilerDiagnostic))

(defenum ResultAstProgramDiagnostic
  (OkAstProgramDiagnostic AstProgram)
  (ErrAstProgramDiagnostic CompilerDiagnostic))

(define (sexpr-colon? [s : Sexpr]) : bool
  (match s
    [(SSym text) (string-eq text ":")]
    [_ false]))

(define (compiler-parse-abstraction-policy-message) : String
  "parse: TypeLisp does not support source-level generics or traits; use comptime-decl and comptime-generated concrete declarations instead (#893/#913/#483)")

(define (compiler-parse-generic-type-policy-message [name : String]) : String
  (string-append
    "parse: unknown type constructor "
    (string-append
      name
      "; TypeLisp has no source-level generic type constructors; use comptime-decl and comptime-generated concrete declarations instead (#893/#913/#483)")))

(define (compiler-parse-policy-form? [name : String]) : bool
  (if (string-eq name "defgeneric")
    true
    (if (string-eq name "generic")
      true
      (if (string-eq name "deftrait")
        true
        (if (string-eq name "trait")
          true
          (if (string-eq name "interface")
            true
            (if (string-eq name "impl")
              true
              (string-eq name "where"))))))))

(define (ast-source-span-from-source-span [span : SourceSpan]) : AstSourceSpan
  (AstSourceSpan
    (span-start-line span)
    (span-start-col span)
    (span-end-line span)
    (span-end-col span)))

(define (ast-expr-wrap-span [expr : AstExpr] [s : SpannedSexpr]) : AstExpr
  (AstExprSpanned
    expr
    (ast-source-span-from-source-span (spanned-sexpr-span s))))

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

(define (compiler-parse-tag-ty-region) : i64
  133)

(define (compiler-parse-tag-ty-ptr) : i64
  134)

(define (compiler-parse-tag-ty-mut-ptr) : i64
  135)

(define (compiler-parse-tag-ty-ref) : i64
  136)

(define (compiler-parse-tag-ty-mut-ref) : i64
  137)

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

(define (compiler-parse-tag-expr-unsafe) : i64
  254)

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

(define (compiler-parse-tag-expr-comptime) : i64
  247)

(define (compiler-parse-tag-expr-with-region) : i64
  248)

(define (compiler-parse-tag-expr-type-literal) : i64
  249)

(define (compiler-parse-tag-expr-spmd-reduce) : i64
  250)

(define (compiler-parse-tag-expr-try) : i64
  251)

(define (compiler-parse-tag-expr-ptr-null) : i64
  252)

(define (compiler-parse-tag-expr-ptr-null-check) : i64
  253)

(define (compiler-parse-tag-expr-with-resource) : i64
  255)

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

(define (compiler-parse-tag-decl-comptime-decl) : i64
  405)

(define (compiler-parse-tag-decl-module) : i64
  406)

(define (compiler-parse-tag-decl-test) : i64
  407)

(define (compiler-parse-dispatch-binops [e : SymI64Env]) : SymI64Env
  (let
    [e1 : SymI64Env (sym-i64-bind e "+" (compiler-parse-tag-bin-add))]
    (let
      [e2 : SymI64Env (sym-i64-bind e1 "-" (compiler-parse-tag-bin-sub))]
      (let
        [e3 : SymI64Env (sym-i64-bind e2 "*" (compiler-parse-tag-bin-mul))]
        (let
          [e4 : SymI64Env (sym-i64-bind e3 "/" (compiler-parse-tag-bin-div))]
          (let
            [e5 : SymI64Env (sym-i64-bind e4 "%" (compiler-parse-tag-bin-mod))]
            (let
              [e6 : SymI64Env (sym-i64-bind e5 "=" (compiler-parse-tag-bin-eq))]
              (let
                [e7 : SymI64Env
                  (sym-i64-bind e6 "!=" (compiler-parse-tag-bin-ne))]
                (let
                  [e8 : SymI64Env
                    (sym-i64-bind e7 "<" (compiler-parse-tag-bin-lt))]
                  (let
                    [e9 : SymI64Env
                      (sym-i64-bind e8 "<=" (compiler-parse-tag-bin-le))]
                    (let
                      [e10 : SymI64Env
                        (sym-i64-bind e9 ">" (compiler-parse-tag-bin-gt))]
                      (let
                        [e11 : SymI64Env
                          (sym-i64-bind e10 ">=" (compiler-parse-tag-bin-ge))]
                        (let
                          [e12 : SymI64Env
                            (sym-i64-bind
                              e11
                              "and"
                              (compiler-parse-tag-bin-and))]
                          (let
                            [e13 : SymI64Env
                              (sym-i64-bind
                                e12
                                "or"
                                (compiler-parse-tag-bin-or))]
                            (let
                              [e14 : SymI64Env
                                (sym-i64-bind
                                  e13
                                  "bit-and"
                                  (compiler-parse-tag-bin-bit-and))]
                              (let
                                [e15 : SymI64Env
                                  (sym-i64-bind
                                    e14
                                    "bit-or"
                                    (compiler-parse-tag-bin-bit-or))]
                                (let
                                  [e16 : SymI64Env
                                    (sym-i64-bind
                                      e15
                                      "bit-xor"
                                      (compiler-parse-tag-bin-bit-xor))]
                                  (let
                                    [e17 : SymI64Env
                                      (sym-i64-bind
                                        e16
                                        "shl"
                                        (compiler-parse-tag-bin-shl))]
                                    (sym-i64-bind
                                      e17
                                      "shr"
                                      (compiler-parse-tag-bin-shr))))))))))))))))))))

(define (compiler-parse-dispatch-unops [e : SymI64Env]) : SymI64Env
  (let
    [e1 : SymI64Env (sym-i64-bind e "not" (compiler-parse-tag-un-not))]
    (let
      [e2 : SymI64Env (sym-i64-bind e1 "neg" (compiler-parse-tag-un-neg))]
      (sym-i64-bind e2 "bit-not" (compiler-parse-tag-un-bit-not)))))

(define (compiler-parse-dispatch-types [e : SymI64Env]) : SymI64Env
  (let
    [out : SymI64Env e]
    (begin
      (set! out (sym-i64-bind out "i64" (compiler-parse-tag-ty-i64)))
      (set! out (sym-i64-bind out "i32" (compiler-parse-tag-ty-i32)))
      (set! out (sym-i64-bind out "i16" (compiler-parse-tag-ty-i16)))
      (set! out (sym-i64-bind out "i8" (compiler-parse-tag-ty-i8)))
      (set! out (sym-i64-bind out "u64" (compiler-parse-tag-ty-u64)))
      (set! out (sym-i64-bind out "u32" (compiler-parse-tag-ty-u32)))
      (set! out (sym-i64-bind out "u16" (compiler-parse-tag-ty-u16)))
      (set! out (sym-i64-bind out "u8" (compiler-parse-tag-ty-u8)))
      (set! out (sym-i64-bind out "f64" (compiler-parse-tag-ty-f64)))
      (set! out (sym-i64-bind out "f32" (compiler-parse-tag-ty-f32)))
      (set! out (sym-i64-bind out "bool" (compiler-parse-tag-ty-bool)))
      (set! out (sym-i64-bind out "char" (compiler-parse-tag-ty-char)))
      (set! out (sym-i64-bind out "String" (compiler-parse-tag-ty-string)))
      (set! out (sym-i64-bind out "unit" (compiler-parse-tag-unit)))
      (set! out (sym-i64-bind out "never" (compiler-parse-tag-ty-never)))
      (set! out (sym-i64-bind out "->" (compiler-parse-tag-ty-func)))
      (set! out (sym-i64-bind out "Tuple" (compiler-parse-tag-ty-tuple)))
      (set! out (sym-i64-bind out "Array" (compiler-parse-tag-ty-array)))
      (set! out (sym-i64-bind out "in" (compiler-parse-tag-ty-region)))
      (set! out (sym-i64-bind out "Ptr" (compiler-parse-tag-ty-ptr)))
      (set! out (sym-i64-bind out "MutPtr" (compiler-parse-tag-ty-mut-ptr)))
      (set! out (sym-i64-bind out "&" (compiler-parse-tag-ty-ref)))
      (set! out (sym-i64-bind out "&mut" (compiler-parse-tag-ty-mut-ref)))
      out)))

(define (compiler-parse-dispatch-exprs [e : SymI64Env]) : SymI64Env
  (let
    [out : SymI64Env e]
    (begin
      (set! out (sym-i64-bind out "if" (compiler-parse-tag-expr-if)))
      (set! out (sym-i64-bind out "let" (compiler-parse-tag-expr-let)))
      (set! out (sym-i64-bind out "lambda" (compiler-parse-tag-expr-lambda)))
      (set! out (sym-i64-bind out "while" (compiler-parse-tag-expr-while)))
      (set! out (sym-i64-bind out "begin" (compiler-parse-tag-expr-begin)))
      (set! out (sym-i64-bind out "unsafe" (compiler-parse-tag-expr-unsafe)))
      (set! out (sym-i64-bind out "set!" (compiler-parse-tag-expr-set)))
      (set! out (sym-i64-bind out "ann" (compiler-parse-tag-expr-ann)))
      (set! out (sym-i64-bind out "cast" (compiler-parse-tag-expr-cast)))
      (set! out (sym-i64-bind out "cond" (compiler-parse-tag-expr-cond)))
      (set! out (sym-i64-bind out "tuple" (compiler-parse-tag-expr-tuple)))
      (set!
        out
        (sym-i64-bind out "tuple-ref" (compiler-parse-tag-expr-tuple-ref)))
      (set! out (sym-i64-bind out "array" (compiler-parse-tag-expr-array)))
      (set!
        out
        (sym-i64-bind out "make-array" (compiler-parse-tag-expr-make-array)))
      (set!
        out
        (sym-i64-bind out "array-ref" (compiler-parse-tag-expr-array-ref)))
      (set!
        out
        (sym-i64-bind out "array-set!" (compiler-parse-tag-expr-array-set)))
      (set! out (sym-i64-bind out "match" (compiler-parse-tag-expr-match)))
      (set! out (sym-i64-bind out "foreach" (compiler-parse-tag-expr-foreach)))
      (set!
        out
        (sym-i64-bind out "spmd-reduce" (compiler-parse-tag-expr-spmd-reduce)))
      (set!
        out
        (sym-i64-bind out "struct-get" (compiler-parse-tag-expr-struct-get)))
      (set!
        out
        (sym-i64-bind out "comptime" (compiler-parse-tag-expr-comptime)))
      ;; `with-arena` is the canonical scoped-arena spelling (#801, #1118).
      (set!
        out
        (sym-i64-bind out "with-arena" (compiler-parse-tag-expr-with-region)))
      (set!
        out
        (sym-i64-bind out "type" (compiler-parse-tag-expr-type-literal)))
      (set! out (sym-i64-bind out "try" (compiler-parse-tag-expr-try)))
      (set!
        out
        (sym-i64-bind out "ptr-null" (compiler-parse-tag-expr-ptr-null)))
      (set!
        out
        (sym-i64-bind out "ptr-null?" (compiler-parse-tag-expr-ptr-null-check)))
      (set!
        out
        (sym-i64-bind out "with" (compiler-parse-tag-expr-with-resource)))
      out)))

(define (compiler-parse-dispatch-patterns [e : SymI64Env]) : SymI64Env
  (let
    [e1 : SymI64Env (sym-i64-bind e "true" (compiler-parse-tag-lit-true))]
    (let
      [e2 : SymI64Env (sym-i64-bind e1 "false" (compiler-parse-tag-lit-false))]
      (sym-i64-bind e2 "_" (compiler-parse-tag-pattern-wildcard)))))

(define (compiler-parse-dispatch-decls [e : SymI64Env]) : SymI64Env
  (let
    [e1 : SymI64Env (sym-i64-bind e "define" (compiler-parse-tag-decl-define))]
    (let
      [e2 : SymI64Env
        (sym-i64-bind e1 "extern" (compiler-parse-tag-decl-extern))]
      (let
        [e3 : SymI64Env
          (sym-i64-bind e2 "defenum" (compiler-parse-tag-decl-defenum))]
        (let
          [e4 : SymI64Env
            (sym-i64-bind e3 "defstruct" (compiler-parse-tag-decl-defstruct))]
          (let
            [e5 : SymI64Env
              (sym-i64-bind e4 "import" (compiler-parse-tag-decl-import))]
            (let
              [e6 : SymI64Env
                (sym-i64-bind
                  e5
                  "comptime-decl"
                  (compiler-parse-tag-decl-comptime-decl))]
              (let
                [e7 : SymI64Env
                  (sym-i64-bind e6 "module" (compiler-parse-tag-decl-module))]
                (sym-i64-bind e7 "test" (compiler-parse-tag-decl-test))))))))))

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
  (cond
    [(= tag (compiler-parse-tag-bin-add)) true]
    [(= tag (compiler-parse-tag-bin-sub)) true]
    [(= tag (compiler-parse-tag-bin-mul)) true]
    [(= tag (compiler-parse-tag-bin-div)) true]
    [(= tag (compiler-parse-tag-bin-mod)) true]
    [(= tag (compiler-parse-tag-bin-eq)) true]
    [(= tag (compiler-parse-tag-bin-ne)) true]
    [(= tag (compiler-parse-tag-bin-lt)) true]
    [(= tag (compiler-parse-tag-bin-le)) true]
    [(= tag (compiler-parse-tag-bin-gt)) true]
    [(= tag (compiler-parse-tag-bin-ge)) true]
    [(= tag (compiler-parse-tag-bin-and)) true]
    [(= tag (compiler-parse-tag-bin-or)) true]
    [(= tag (compiler-parse-tag-bin-bit-and)) true]
    [(= tag (compiler-parse-tag-bin-bit-or)) true]
    [(= tag (compiler-parse-tag-bin-bit-xor)) true]
    [(= tag (compiler-parse-tag-bin-shl)) true]
    [else (= tag (compiler-parse-tag-bin-shr))]))

(define (ast-binop? [dispatch : SymI64Env] [name : String]) : bool
  (ast-binop-tag? (compiler-parse-dispatch-tag dispatch name)))

(define (ast-binop-from-tag [tag : i64]) : AstBinOp
  (cond
    [(= tag (compiler-parse-tag-bin-add)) (AstBinAdd)]
    [(= tag (compiler-parse-tag-bin-sub)) (AstBinSub)]
    [(= tag (compiler-parse-tag-bin-mul)) (AstBinMul)]
    [(= tag (compiler-parse-tag-bin-div)) (AstBinDiv)]
    [(= tag (compiler-parse-tag-bin-mod)) (AstBinMod)]
    [(= tag (compiler-parse-tag-bin-eq)) (AstBinEq)]
    [(= tag (compiler-parse-tag-bin-ne)) (AstBinNe)]
    [(= tag (compiler-parse-tag-bin-lt)) (AstBinLt)]
    [(= tag (compiler-parse-tag-bin-le)) (AstBinLe)]
    [(= tag (compiler-parse-tag-bin-gt)) (AstBinGt)]
    [(= tag (compiler-parse-tag-bin-ge)) (AstBinGe)]
    [(= tag (compiler-parse-tag-bin-and)) (AstBinAnd)]
    [(= tag (compiler-parse-tag-bin-or)) (AstBinOr)]
    [(= tag (compiler-parse-tag-bin-bit-and)) (AstBinBitAnd)]
    [(= tag (compiler-parse-tag-bin-bit-or)) (AstBinBitOr)]
    [(= tag (compiler-parse-tag-bin-bit-xor)) (AstBinBitXor)]
    [(= tag (compiler-parse-tag-bin-shl)) (AstBinShl)]
    [else (AstBinShr)]))

(define (ast-binop-from-name [dispatch : SymI64Env] [name : String]) : AstBinOp
  (ast-binop-from-tag (compiler-parse-dispatch-tag dispatch name)))

(define (ast-unop-tag? [tag : i64]) : bool
  (cond
    [(= tag (compiler-parse-tag-un-not)) true]
    [(= tag (compiler-parse-tag-un-neg)) true]
    [else (= tag (compiler-parse-tag-un-bit-not))]))

(define (ast-unop? [dispatch : SymI64Env] [name : String]) : bool
  (ast-unop-tag? (compiler-parse-dispatch-tag dispatch name)))

(define (ast-unop-from-tag [tag : i64]) : AstUnOp
  (cond
    [(= tag (compiler-parse-tag-un-not)) (AstUnNot)]
    [(= tag (compiler-parse-tag-un-neg)) (AstUnNeg)]
    [else (AstUnBitNot)]))

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

(define (parse-ast-reference-type
  [dispatch : SymI64Env]
  [rest : Sexpr]
  [mutable : bool]) : ResultAstType
  (match rest
    [(SCons (SSym region) (SCons inner (SNil)))
      (match (parse-ast-type dispatch inner)
        [(OkAstType inner-ty)
          (if mutable
            (OkAstType (AstTyMutRef region inner-ty))
            (OkAstType (AstTyRef region inner-ty)))]
        [(ErrAstType message) (ErrAstType message)])]
    [(SCons _ (SCons _ (SNil)))
      (ErrAstType "parse: reference lifetime must be an identifier")]
    [_
      (ErrAstType
        (if mutable
          "parse: &mut expects lifetime and exactly one type"
          "parse: & expects lifetime and exactly one type"))]))

(define (parse-ast-type [dispatch : SymI64Env] [s : Sexpr]) : ResultAstType
  (match s
    [(SSym name)
      (let
        [tag : i64 (compiler-parse-dispatch-tag dispatch name)]
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
      (let
        [tag : i64 (compiler-parse-dispatch-tag dispatch head)]
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
              (if (= tag (compiler-parse-tag-ty-ptr))
                (match rest
                  [(SCons elem (SNil))
                    (match (parse-ast-type dispatch elem)
                      [(OkAstType elem-ty) (OkAstType (AstTyPtr elem-ty))]
                      [(ErrAstType message) (ErrAstType message)])]
                  [_ (ErrAstType "parse: Ptr expects exactly one type")])
                (if (= tag (compiler-parse-tag-ty-mut-ptr))
                  (match rest
                    [(SCons elem (SNil))
                      (match (parse-ast-type dispatch elem)
                        [(OkAstType elem-ty) (OkAstType (AstTyMutPtr elem-ty))]
                        [(ErrAstType message) (ErrAstType message)])]
                    [_ (ErrAstType "parse: MutPtr expects exactly one type")])
                  (if (= tag (compiler-parse-tag-ty-ref))
                    (parse-ast-reference-type dispatch rest false)
                    (if (= tag (compiler-parse-tag-ty-mut-ref))
                      (parse-ast-reference-type dispatch rest true)
                      (if (= tag (compiler-parse-tag-ty-region))
                        (match rest
                          [(SCons (SSym region) (SCons inner (SNil)))
                            (match (parse-ast-type dispatch inner)
                              [(OkAstType inner-ty)
                                (OkAstType (AstTyRegion region inner-ty))]
                              [(ErrAstType message) (ErrAstType message)])]
                          [(SCons _ (SCons _ (SNil)))
                            (ErrAstType
                              "parse: region name must be an identifier")]
                          [_ (ErrAstType "parse: malformed region type")])
                        (ErrAstType
                          (compiler-parse-generic-type-policy-message head)))))))))))]
    [_ (ErrAstType "parse: expected type")]))

(define (parse-ast-param [dispatch : SymI64Env] [s : Sexpr]) : ResultAstParam
  (match s
    [(SCons (SSym name) (SCons colon (SCons ty (SNil))))
      (if (sexpr-colon? colon)
        (match (parse-ast-type dispatch ty)
          [(OkAstType parsed-ty) (OkAstParam (AstParam name parsed-ty false))]
          [(ErrAstType message) (ErrAstParam message)])
        (ErrAstParam "parse: expected ':' in parameter"))]
    [(SCons (SSym marker) (SCons (SSym name) (SCons colon (SCons ty (SNil)))))
      (if (string-eq marker "comptime")
        (if (sexpr-colon? colon)
          (match (parse-ast-type dispatch ty)
            [(OkAstType parsed-ty) (OkAstParam (AstParam name parsed-ty true))]
            [(ErrAstType message) (ErrAstParam message)])
          (ErrAstParam "parse: expected ':' in parameter"))
        (ErrAstParam "parse: malformed parameter"))]
    [_ (ErrAstParam "parse: malformed parameter")]))

(define (ast-param-list-has-comptime? [params : AstParamList]) : bool
  (match params
    [(AstParamNil) false]
    [(AstParamCons param rest)
      (match param
        [(AstParam _ _ is-comptime)
          (if is-comptime
            true
            (ast-param-list-has-comptime? rest))])]))

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

(define (compiler-parse-metadata-key? [name : String]) : bool
  (and (> (string-length name) 0) (= (string-ref name 0) #:')))

(define (parse-ast-defstruct-repr-tail [tail : Sexpr]) : ResultAstStructRepr
  (match tail
    [(SCons (SSym name) (SNil))
      (if (string-eq name "c")
        (OkAstStructRepr (AstStructReprC))
        (if (string-eq name "packed")
          (ErrAstStructRepr "parse: packed repr is reserved")
          (ErrAstStructRepr (string-append "parse: unknown struct repr " name))))]
    [_ (ErrAstStructRepr "parse: malformed :repr metadata")]))

(define (parse-ast-defstruct-items
  [dispatch : SymI64Env]
  [items : SpannedSexpr]
  [repr : AstStructRepr]
  [seen-repr : bool]
  [seen-field : bool]) : ResultAstStructDefParts
  (match items
    [(SpSNil _) (OkAstStructDefParts repr AstFieldDefNil)]
    [(SpSCons head tail _)
      (match (spanned-sexpr-form head)
        [(SCons (SSym key) after-key)
          (if (string-eq key ":repr")
            (if seen-field
              (ErrAstStructDefParts
                "parse: defstruct metadata must appear before fields")
              (if seen-repr
                (ErrAstStructDefParts
                  "parse: duplicate defstruct :repr metadata")
                (match (parse-ast-defstruct-repr-tail after-key)
                  [(OkAstStructRepr next-repr)
                    (parse-ast-defstruct-items
                      dispatch
                      tail
                      next-repr
                      true
                      false)]
                  [(ErrAstStructRepr message) (ErrAstStructDefParts message)])))
            (if (compiler-parse-metadata-key? key)
              (if seen-field
                (ErrAstStructDefParts
                  "parse: defstruct metadata must appear before fields")
                (if (string-eq key ":packed")
                  (ErrAstStructDefParts "parse: packed repr is reserved")
                  (ErrAstStructDefParts
                    (string-append "parse: unknown defstruct metadata " key))))
              (match (parse-ast-field-def dispatch (spanned-sexpr-form head))
                [(OkAstFieldDef parsed-field)
                  (match (parse-ast-defstruct-items
                    dispatch
                    tail
                    repr
                    seen-repr
                    true)
                    [(OkAstStructDefParts parsed-repr parsed-rest)
                      (OkAstStructDefParts
                        parsed-repr
                        (AstFieldDefCons parsed-field parsed-rest))]
                    [(ErrAstStructDefParts message)
                      (ErrAstStructDefParts message)])]
                [(ErrAstFieldDef message) (ErrAstStructDefParts message)])))]
        [_
          (match (parse-ast-field-def dispatch (spanned-sexpr-form head))
            [(OkAstFieldDef parsed-field)
              (match (parse-ast-defstruct-items
                dispatch
                tail
                repr
                seen-repr
                true)
                [(OkAstStructDefParts parsed-repr parsed-rest)
                  (OkAstStructDefParts
                    parsed-repr
                    (AstFieldDefCons parsed-field parsed-rest))]
                [(ErrAstStructDefParts message) (ErrAstStructDefParts message)])]
            [(ErrAstFieldDef message) (ErrAstStructDefParts message)])])]
    [_ (ErrAstStructDefParts "parse: malformed field list")]))

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
    [(SFloat text) (OkAstPattern (AstPatLiteral (AstLitFloat text)))]
    [(SStr text) (OkAstPattern (AstPatLiteral (AstLitString text)))]
    [(SChar c) (OkAstPattern (AstPatLiteral (AstLitChar c)))]
    [(SSym name)
      (let
        [tag : i64 (compiler-parse-dispatch-tag dispatch name)]
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

(define (parse-ast-cond-arm
  [dispatch : SymI64Env]
  [arm : SpannedSexpr]
  [rest : SpannedSexpr]
  [has-test : bool]) : ResultAstExpr
  (match arm
    [(SpSBracketList items _) (parse-ast-cond-arm dispatch items rest has-test)]
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
    [_ (ErrAstExpr "parse: malformed cond arm")]))

(define (parse-ast-cond-arms
  [dispatch : SymI64Env]
  [arms : SpannedSexpr]
  [has-test : bool]) : ResultAstExpr
  (match arms
    [(SpSNil _) (ErrAstExpr "parse: cond requires final else arm")]
    [(SpSCons arm rest _) (parse-ast-cond-arm dispatch arm rest has-test)]
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
      (if (sexpr-colon? (spanned-sexpr-form colon))
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
    [(SpSBracketList items _) (parse-ast-let-binding dispatch items)]
    [(SpSCons
        (SpSSym name _)
        (SpSCons colon (SpSCons ty (SpSCons value (SpSNil _) _) _) _)
        _)
      (if (sexpr-colon? (spanned-sexpr-form colon))
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

(define (ast-let-binding-list-empty? [bindings : AstLetBindingList]) : bool
  (match bindings
    [(AstLetBindingNil) true]
    [_ false]))

(define (parse-ast-let-flat-tail [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstLetParts
  (match rest
    [(SpSCons head tail _)
      (match head
        [(SpSBracketList _ _)
          (match (parse-ast-let-binding dispatch head)
            [(OkAstLetBinding parsed-head)
              (match (parse-ast-let-flat-tail dispatch tail)
                [(OkAstLetParts parsed-tail parsed-body)
                  (OkAstLetParts
                    (AstLetBindingCons parsed-head parsed-tail)
                    parsed-body)]
                [(ErrAstLetParts message) (ErrAstLetParts message)])]
            [(ErrAstLetBinding message) (ErrAstLetParts message)])]
        [_
          (match tail
            [(SpSNil _)
              (match (parse-ast-expr dispatch head)
                [(OkAstExpr parsed-body)
                  (OkAstLetParts AstLetBindingNil parsed-body)]
                [(ErrAstExpr message) (ErrAstLetParts message)])]
            [_ (ErrAstLetParts "parse: let expects exactly one body")])])]
    [(SpSNil _) (ErrAstLetParts "parse: let missing body")]
    [_ (ErrAstLetParts "parse: malformed let")]))

(define (parse-ast-let-flat [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons head _ _)
      (match head
        [(SpSBracketList _ _)
          (match (parse-ast-let-flat-tail dispatch rest)
            [(OkAstLetParts parsed-bindings parsed-body)
              (if (ast-let-binding-list-empty? parsed-bindings)
                (ErrAstExpr "parse: let requires at least one binding")
                (OkAstExpr (AstExprLet parsed-bindings parsed-body)))]
            [(ErrAstLetParts message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: let requires at least one binding")])]
    [_ (ErrAstExpr "parse: malformed let")]))

(define (parse-ast-let [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons (SpSBracketList _ _) _ _) (parse-ast-let-flat dispatch rest)]
    [(SpSCons bindings (SpSCons body (SpSNil _) _) _)
      (match (parse-ast-let-binding-list dispatch bindings)
        [(OkAstLetBindingList parsed-bindings)
          (if (ast-let-binding-list-empty? parsed-bindings)
            (ErrAstExpr "parse: let requires at least one binding")
            (match (parse-ast-expr dispatch body)
              [(OkAstExpr parsed-body)
                (OkAstExpr (AstExprLet parsed-bindings parsed-body))]
              [(ErrAstExpr message) (ErrAstExpr message)]))]
        [(ErrAstLetBindingList message) (ErrAstExpr message)])]
    [(SpSCons _ _ _) (ErrAstExpr "parse: let requires at least one binding")]
    [_ (ErrAstExpr "parse: malformed let")]))

(define (parse-ast-lambda [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons
        params
        (SpSCons colon (SpSCons ret (SpSCons body (SpSNil _) _) _) _)
        _)
      (if (sexpr-colon? (spanned-sexpr-form colon))
        (match (parse-ast-param-list dispatch (spanned-sexpr-form params))
          [(OkAstParamList parsed-params)
            (if (ast-param-list-has-comptime? parsed-params)
              (ErrAstExpr
                "comptime parameters are only supported on top-level function definitions")
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
                [(ErrAstType message) (ErrAstExpr message)]))]
          [(ErrAstParamList message) (ErrAstExpr message)])
        (ErrAstExpr "parse: expected ':' in lambda"))]
    [(SpSCons params (SpSCons body (SpSNil _) _) _)
      (match (parse-ast-param-list dispatch (spanned-sexpr-form params))
        [(OkAstParamList parsed-params)
          (if (ast-param-list-has-comptime? parsed-params)
            (ErrAstExpr
              "comptime parameters are only supported on top-level function definitions")
            (match (parse-ast-expr dispatch body)
              [(OkAstExpr parsed-body)
                (OkAstExpr (AstExprLambda parsed-params AstNoType parsed-body))]
              [(ErrAstExpr message) (ErrAstExpr message)]))]
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

;; `(comptime expr)` (#718) wraps exactly one inner expression for compile-time
;; evaluation; evaluation itself is reserved for #719.
(define (parse-ast-comptime [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr (SpSNil _) _)
      (match (parse-ast-expr dispatch expr)
        [(OkAstExpr parsed-expr) (OkAstExpr (AstExprComptime parsed-expr))]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: comptime expects exactly one expression")]))

(define (parse-ast-type-literal [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons ty (SpSNil _) _)
      (match (parse-ast-type dispatch (spanned-sexpr-form ty))
        [(OkAstType parsed-ty) (OkAstExpr (AstExprTypeLiteral parsed-ty))]
        [(ErrAstType message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: type expects exactly one type")]))

(define (parse-ast-reduce-op [name : String]) : ResultAstReduceOp
  (if (string-eq name "sum")
    (OkAstReduceOp (AstReduceSum))
    (if (string-eq name "min")
      (OkAstReduceOp (AstReduceMin))
      (if (string-eq name "max")
        (OkAstReduceOp (AstReduceMax))
        (if (string-eq name "all")
          (OkAstReduceOp (AstReduceAll))
          (if (string-eq name "any")
            (OkAstReduceOp (AstReduceAny))
            (ErrAstReduceOp
              (string-append
                "parse: unsupported spmd-reduce operator `"
                (string-append
                  name
                  "`; expected one of sum, min, max, all, any")))))))))

(define (parse-ast-spmd-reduce-binding
  [dispatch : SymI64Env]
  [op : AstReduceOp]
  [binding : SpannedSexpr]
  [init : SpannedSexpr]
  [value : SpannedSexpr]) : ResultAstExpr
  (match binding
    [(SpSBracketList items _)
      (parse-ast-spmd-reduce-binding dispatch op items init value)]
    [(SpSCons
        (SpSSym index _)
        (SpSCons
          colon
          (SpSCons index-ty (SpSCons start (SpSCons end (SpSNil _) _) _) _)
          _)
        _)
      (if (sexpr-colon? (spanned-sexpr-form colon))
        (match (parse-ast-type dispatch (spanned-sexpr-form index-ty))
          [(OkAstType parsed-index-ty)
            (match (parse-ast-expr dispatch start)
              [(OkAstExpr parsed-start)
                (match (parse-ast-expr dispatch end)
                  [(OkAstExpr parsed-end)
                    (match (parse-ast-expr dispatch init)
                      [(OkAstExpr parsed-init)
                        (match (parse-ast-expr dispatch value)
                          [(OkAstExpr parsed-value)
                            (OkAstExpr
                              (AstExprSpmdReduce
                                op
                                index
                                parsed-index-ty
                                parsed-start
                                parsed-end
                                parsed-init
                                parsed-value))]
                          [(ErrAstExpr message) (ErrAstExpr message)])]
                      [(ErrAstExpr message) (ErrAstExpr message)])]
                  [(ErrAstExpr message) (ErrAstExpr message)])]
              [(ErrAstExpr message) (ErrAstExpr message)])]
          [(ErrAstType message) (ErrAstExpr message)])
        (ErrAstExpr "parse: expected ':' in spmd-reduce"))]
    [_ (ErrAstExpr "parse: malformed spmd-reduce")]))

(define (parse-ast-spmd-reduce [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons
        (SpSSym op-name _)
        (SpSCons
          (SpSCons binding (SpSNil _) _)
          (SpSCons init (SpSCons value (SpSNil _) _) _)
          _)
        _)
      (match (parse-ast-reduce-op op-name)
        [(OkAstReduceOp op)
          (parse-ast-spmd-reduce-binding dispatch op binding init value)]
        [(ErrAstReduceOp message) (ErrAstExpr message)])]
    [(SpSCons _ _ _) (ErrAstExpr "parse: malformed spmd-reduce")]
    [_ (ErrAstExpr "parse: malformed spmd-reduce")]))

(define (parse-ast-try [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr (SpSNil _) _)
      (match (parse-ast-expr dispatch expr)
        [(OkAstExpr parsed-expr) (OkAstExpr (AstExprTry parsed-expr))]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: try expects exactly one expression")]))

;; `(ptr-null : T)` - a colon followed by a pointer type, no leading expression.
;; The parser accepts any type here; the typechecker rejects non-pointer `T`.
(define (parse-ast-ptr-null [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons colon (SpSCons ty (SpSNil _) _) _)
      (if (sexpr-colon? (spanned-sexpr-form colon))
        (match (parse-ast-type dispatch (spanned-sexpr-form ty))
          [(OkAstType parsed-ty) (OkAstExpr (AstExprPtrNull parsed-ty))]
          [(ErrAstType message) (ErrAstExpr message)])
        (ErrAstExpr "parse: expected ':' in ptr-null"))]
    [_
      (ErrAstExpr
        "parse: ptr-null expects (ptr-null : T) with a pointer type T")]))

;; `(ptr-null? p)` - a single pointer operand.
(define (parse-ast-ptr-null-check [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr (SpSNil _) _)
      (match (parse-ast-expr dispatch expr)
        [(OkAstExpr parsed-expr) (OkAstExpr (AstExprPtrNullCheck parsed-expr))]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: ptr-null? expects exactly one expression")]))

(define (parse-ast-with-region [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSNil _)
      (ErrAstExpr "parse: with-arena requires a region name before its body")]
    [(SpSCons (SpSSym region _) body _)
      (match body
        [(SpSNil _)
          (ErrAstExpr
            (string-append
              "parse: with-arena '"
              (string-append region "' requires a non-empty body")))]
        [_
          (match (parse-ast-expr-list dispatch body)
            [(OkAstExprList exprs) (OkAstExpr (AstExprWithRegion region exprs))]
            [(ErrAstExprList message) (ErrAstExpr message)])])]
    [(SpSCons _ _ _)
      (ErrAstExpr "parse: with-arena region name must be an identifier")]
    [_ (ErrAstExpr "parse: malformed with-arena")]))

(define (parse-ast-resource-binding-items
  [dispatch : SymI64Env]
  [items : SpannedSexpr]) : ResultAstResourceBinding
  (match items
    [(SpSCons (SpSSym name _) rest _)
      (match rest
        [(SpSNil _)
          (ErrAstResourceBinding "parse: with binding is missing initializer")]
        [(SpSCons init tail _)
          (match tail
            [(SpSNil _)
              (ErrAstResourceBinding
                "parse: with binding is missing cleanup function")]
            [(SpSCons cleanup extra _)
              (match extra
                [(SpSNil _)
                  (match (parse-ast-expr dispatch init)
                    [(OkAstExpr parsed-init)
                      (match (parse-ast-expr dispatch cleanup)
                        [(OkAstExpr parsed-cleanup)
                          (OkAstResourceBinding
                            (AstResourceBinding name parsed-init parsed-cleanup))]
                        [(ErrAstExpr message) (ErrAstResourceBinding message)])]
                    [(ErrAstExpr message) (ErrAstResourceBinding message)])]
                [_
                  (ErrAstResourceBinding
                    "parse: with binding has too many fields")])]
            [_ (ErrAstResourceBinding "parse: malformed with binding")])]
        [_ (ErrAstResourceBinding "parse: malformed with binding")])]
    [(SpSCons _ _ _)
      (ErrAstResourceBinding "parse: with binding name must be an identifier")]
    [_ (ErrAstResourceBinding "parse: malformed with binding")]))

(define (parse-ast-resource-binding
  [dispatch : SymI64Env]
  [binding : SpannedSexpr]) : ResultAstResourceBinding
  (match binding
    [(SpSBracketList items _) (parse-ast-resource-binding-items dispatch items)]
    [_ (ErrAstResourceBinding "parse: with binding must use bracket syntax")]))

(define (parse-ast-resource-binding-list
  [dispatch : SymI64Env]
  [bindings : SpannedSexpr]) : ResultAstResourceBindingList
  (match bindings
    [(SpSNil _) (OkAstResourceBindingList AstResourceBindingNil)]
    [(SpSCons head rest _)
      (match (parse-ast-resource-binding dispatch head)
        [(OkAstResourceBinding parsed-head)
          (match (parse-ast-resource-binding-list dispatch rest)
            [(OkAstResourceBindingList parsed-rest)
              (OkAstResourceBindingList
                (AstResourceBindingCons parsed-head parsed-rest))]
            [(ErrAstResourceBindingList message)
              (ErrAstResourceBindingList message)])]
        [(ErrAstResourceBinding message) (ErrAstResourceBindingList message)])]
    [_ (ErrAstResourceBindingList "parse: malformed with binding list")]))

(define (parse-ast-with-resource [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSNil _)
      (ErrAstExpr "parse: with requires a binding list before its body")]
    [(SpSCons bindings body _)
      (match bindings
        [(SpSNil _)
          (ErrAstExpr "parse: with requires a non-empty binding list")]
        [(SpSCons _ _ _)
          (match body
            [(SpSNil _) (ErrAstExpr "parse: with requires a non-empty body")]
            [_
              (match (parse-ast-resource-binding-list dispatch bindings)
                [(OkAstResourceBindingList parsed-bindings)
                  (match (parse-ast-expr-list dispatch body)
                    [(OkAstExprList parsed-body)
                      (OkAstExpr
                        (AstExprWithResource parsed-bindings parsed-body))]
                    [(ErrAstExprList message) (ErrAstExpr message)])]
                [(ErrAstResourceBindingList message) (ErrAstExpr message)])])]
        [_ (ErrAstExpr "parse: malformed with binding list")])]
    [_ (ErrAstExpr "parse: malformed with")]))

(define (parse-ast-match-arm [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstMatchArm
  (match s
    [(SpSBracketList items _) (parse-ast-match-arm dispatch items)]
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

(define (parse-ast-foreach-binding
  [dispatch : SymI64Env]
  [binding : SpannedSexpr]
  [body : SpannedSexpr]) : ResultAstExpr
  (match binding
    [(SpSBracketList items _) (parse-ast-foreach-binding dispatch items body)]
    [(SpSCons
        (SpSSym index _)
        (SpSCons
          colon
          (SpSCons index-ty (SpSCons start (SpSCons end (SpSNil _) _) _) _)
          _)
        _)
      (if (sexpr-colon? (spanned-sexpr-form colon))
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
    [_ (ErrAstExpr "parse: malformed foreach binding")]))

(define (parse-ast-foreach [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons (SpSCons binding (SpSNil _) _) (SpSCons body (SpSNil _) _) _)
      (parse-ast-foreach-binding dispatch binding body)]
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

;; `(unsafe expr+)` parses like `begin` but requires a non-empty body. v1 has
;; the same behavior as `begin`; it marks an unsafe context for later raw-pointer
;; ops (#955).
(define (parse-ast-unsafe [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSNil _) (ErrAstExpr "parse: unsafe requires a non-empty body")]
    [_
      (match (parse-ast-expr-list dispatch rest)
        [(OkAstExprList exprs) (OkAstExpr (AstExprUnsafe exprs))]
        [(ErrAstExprList message) (ErrAstExpr message)])]))

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
            (if (= tag (compiler-parse-tag-expr-unsafe))
              (parse-ast-unsafe dispatch rest)
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
                                (if (= tag (compiler-parse-tag-expr-match))
                                  (parse-ast-match dispatch rest)
                                  (if (= tag (compiler-parse-tag-expr-foreach))
                                    (parse-ast-foreach dispatch rest)
                                    (if (=
                                      tag
                                      (compiler-parse-tag-expr-spmd-reduce))
                                      (parse-ast-spmd-reduce dispatch rest)
                                      (if (=
                                        tag
                                        (compiler-parse-tag-expr-struct-get))
                                        (parse-ast-struct-get dispatch rest)
                                        (if (=
                                          tag
                                          (compiler-parse-tag-expr-comptime))
                                          (parse-ast-comptime dispatch rest)
                                          (if (=
                                            tag
                                            (compiler-parse-tag-expr-type-literal))
                                            (parse-ast-type-literal
                                              dispatch
                                              rest)
                                            (if (=
                                              tag
                                              (compiler-parse-tag-expr-with-region))
                                              (parse-ast-with-region
                                                dispatch
                                                rest)
                                              (if (=
                                                tag
                                                (compiler-parse-tag-expr-with-resource))
                                                (parse-ast-with-resource
                                                  dispatch
                                                  rest)
                                                (if (=
                                                  tag
                                                  (compiler-parse-tag-expr-try))
                                                  (parse-ast-try dispatch rest)
                                                  (if (=
                                                    tag
                                                    (compiler-parse-tag-expr-ptr-null))
                                                    (parse-ast-ptr-null
                                                      dispatch
                                                      rest)
                                                    (if (=
                                                      tag
                                                      (compiler-parse-tag-expr-ptr-null-check))
                                                      (parse-ast-ptr-null-check
                                                        dispatch
                                                        rest)
                                                      (if (=
                                                        tag
                                                        (compiler-parse-tag-decl-comptime-decl))
                                                        (ErrAstExpr
                                                          "parse: comptime-decl is only valid as a top-level declaration")
                                                        (parse-ast-call
                                                          dispatch
                                                          head
                                                          rest)))))))))))))))))))))))))))))

(define (parse-ast-list-expr
  [dispatch : SymI64Env]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match head
    [(SpSSym op _)
      (let
        [tag : i64 (compiler-parse-dispatch-tag dispatch op)]
        (if (= tag (compiler-parse-tag-expr-cond))
          (parse-ast-cond dispatch rest)
          (if (ast-unop-tag? tag)
            (parse-ast-unary dispatch (ast-unop-from-tag tag) rest)
            (if (ast-binop-tag? tag)
              (parse-ast-binary dispatch (ast-binop-from-tag tag) rest)
              (parse-ast-list-expr-tag dispatch tag head rest)))))]
    [_ (parse-ast-call dispatch head rest)]))

(define (parse-ast-expr [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstExpr
  (match s
    [(SpSInt n _)
      (OkAstExpr (ast-expr-wrap-span (AstExprLiteral (AstLitInt n)) s))]
    [(SpSFloat text _)
      (OkAstExpr (ast-expr-wrap-span (AstExprLiteral (AstLitFloat text)) s))]
    [(SpSStr text _)
      (OkAstExpr (ast-expr-wrap-span (AstExprLiteral (AstLitString text)) s))]
    [(SpSChar c _)
      (OkAstExpr (ast-expr-wrap-span (AstExprLiteral (AstLitChar c)) s))]
    [(SpSSym name _)
      (let
        [tag : i64 (compiler-parse-dispatch-tag dispatch name)]
        (if (= tag (compiler-parse-tag-lit-true))
          (OkAstExpr (ast-expr-wrap-span (AstExprLiteral (AstLitBool true)) s))
          (if (= tag (compiler-parse-tag-lit-false))
            (OkAstExpr
              (ast-expr-wrap-span (AstExprLiteral (AstLitBool false)) s))
            (if (= tag (compiler-parse-tag-unit))
              (OkAstExpr (ast-expr-wrap-span (AstExprLiteral AstLitUnit) s))
              (OkAstExpr (ast-expr-wrap-span (AstExprVar name) s))))))]
    [(SpSCons head rest _)
      (match (parse-ast-list-expr dispatch head rest)
        [(OkAstExpr parsed) (OkAstExpr (ast-expr-wrap-span parsed s))]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed expression")]))

(define (parse-ast-define-value
  [dispatch : SymI64Env]
  [name : String]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons colon (SpSCons ty (SpSCons value (SpSNil _) _) _) _)
      (if (sexpr-colon? (spanned-sexpr-form colon))
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
  [params : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons colon (SpSCons ret (SpSCons body (SpSNil _) _) _) _)
      (if (sexpr-colon? (spanned-sexpr-form colon))
        (match (parse-ast-param-list dispatch (spanned-sexpr-form params))
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
      (match (parse-ast-param-list dispatch (spanned-sexpr-form params))
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
      (parse-ast-define-fn dispatch name params after-header)]
    [_ (ErrAstDecl "parse: malformed define")]))

(define (parse-ast-extern [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons (SpSSym name _) (SpSCons colon (SpSCons ty (SpSNil _) _) _) _)
      (if (sexpr-colon? (spanned-sexpr-form colon))
        (match (parse-ast-type dispatch (spanned-sexpr-form ty))
          [(OkAstType parsed-ty) (OkAstDecl (AstDeclExtern name parsed-ty))]
          [(ErrAstType message) (ErrAstDecl message)])
        (ErrAstDecl "parse: expected ':' in extern"))]
    [_ (ErrAstDecl "parse: malformed extern")]))

(define (parse-ast-defenum [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons (SpSSym name _) variants _)
      (match (spanned-sexpr-form variants)
        [(SNil) (ErrAstDecl "parse: defenum needs at least one variant")]
        [_
          (match (parse-ast-variant-def-list
            dispatch
            (spanned-sexpr-form variants))
            [(OkAstVariantDefList parsed-variants)
              (OkAstDecl (AstDeclDefEnum name parsed-variants))]
            [(ErrAstVariantDefList message) (ErrAstDecl message)])])]
    [_ (ErrAstDecl "parse: malformed defenum")]))

(define (parse-ast-defstruct [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons (SpSSym name _) fields _)
      (match (parse-ast-defstruct-items
        dispatch
        fields
        (AstStructReprDefault)
        false
        false)
        [(OkAstStructDefParts repr parsed-fields)
          (match parsed-fields
            [(AstFieldDefNil)
              (ErrAstDecl "parse: defstruct needs at least one field")]
            [_ (OkAstDecl (AstDeclDefStruct name repr parsed-fields))])]
        [(ErrAstStructDefParts message) (ErrAstDecl message)])]
    [_ (ErrAstDecl "parse: malformed defstruct")]))

(define (parse-ast-module [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons (SpSSym name _) (SpSNil _) _) (OkAstDecl (AstDeclModule name))]
    [_ (ErrAstDecl "parse: malformed module")]))

(define (parse-ast-import-spec
  [path : String]
  [module-name : AstMaybeModuleName]
  [alias : AstMaybeImportAlias]) : ResultAstDecl
  (OkAstDecl (AstDeclImport (AstImportSpec path module-name alias))))

(define (parse-ast-import-alias
  [path : String]
  [module-name : AstMaybeModuleName]
  [tail : SpannedSexpr]) : ResultAstDecl
  (match tail
    [(SpSCons (SpSSym as-name _) (SpSCons (SpSSym alias _) (SpSNil _) _) _)
      (if (string-eq as-name "as")
        (parse-ast-import-spec path module-name (AstSomeImportAlias alias))
        (ErrAstDecl "parse: malformed import"))]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-import-module-tail [path : String] [tail : SpannedSexpr]) : ResultAstDecl
  (match tail
    [(SpSCons (SpSSym module-name _) after-module _)
      (match after-module
        [(SpSNil _)
          (parse-ast-import-spec
            path
            (AstSomeModuleName module-name)
            AstNoImportAlias)]
        [_
          (parse-ast-import-alias
            path
            (AstSomeModuleName module-name)
            after-module)])]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-import-tail [path : String] [tail : SpannedSexpr]) : ResultAstDecl
  (match tail
    [(SpSNil _) (parse-ast-import-spec path AstNoModuleName AstNoImportAlias)]
    [(SpSCons (SpSSym head _) after-head _)
      (if (string-eq head "as")
        (parse-ast-import-alias path AstNoModuleName tail)
        (if (string-eq head "module")
          (parse-ast-import-module-tail path after-head)
          (ErrAstDecl "parse: malformed import")))]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-import [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons (SpSStr path _) tail _) (parse-ast-import-tail path tail)]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-test-body [exprs : AstExprList]) : AstExpr
  (match exprs
    [(AstExprCons only (AstExprNil)) only]
    [_ (AstExprBegin exprs)]))

(define (parse-ast-test
  [dispatch : SymI64Env]
  [rest : SpannedSexpr]
  [form-span : AstSourceSpan]) : ResultAstDecl
  (match rest
    [(SpSCons (SpSSym name _) body-forms _)
      (match body-forms
        [(SpSNil _) (ErrAstDecl "parse: test needs at least one expression")]
        [_
          (match (parse-ast-expr-list dispatch body-forms)
            [(OkAstExprList exprs)
              (OkAstDecl
                (AstDeclTest name (parse-ast-test-body exprs) form-span))]
            [(ErrAstExprList message) (ErrAstDecl message)])])]
    [_ (ErrAstDecl "parse: malformed test")]))

(define (parse-ast-comptime-decl [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons template (SpSNil _) _)
      (match template
        [(SpSCons (SpSSym head _) template-rest _)
          (let
            [tag : i64 (compiler-parse-dispatch-tag dispatch head)]
            (if (= tag (compiler-parse-tag-decl-defenum))
              (match (parse-ast-defenum dispatch template-rest)
                [(OkAstDecl decl) (OkAstDecl (AstDeclComptimeDecl decl))]
                [(ErrAstDecl message) (ErrAstDecl message)])
              (if (= tag (compiler-parse-tag-decl-defstruct))
                (match (parse-ast-defstruct dispatch template-rest)
                  [(OkAstDecl decl) (OkAstDecl (AstDeclComptimeDecl decl))]
                  [(ErrAstDecl message) (ErrAstDecl message)])
                (ErrAstDecl
                  "parse: comptime-decl accepts only defstruct or defenum"))))]
        [_
          (ErrAstDecl "parse: comptime-decl accepts only defstruct or defenum")])]
    [_ (ErrAstDecl "parse: comptime-decl expects exactly one template")]))

(define (parse-ast-decl [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstDecl
  (match s
    [(SpSCons (SpSSym head _) rest _)
      (let
        [tag : i64 (compiler-parse-dispatch-tag dispatch head)]
        (if (= tag (compiler-parse-tag-decl-define))
          (parse-ast-define dispatch rest)
          (if (= tag (compiler-parse-tag-decl-extern))
            (parse-ast-extern dispatch rest)
            (if (= tag (compiler-parse-tag-decl-defenum))
              (parse-ast-defenum dispatch rest)
              (if (= tag (compiler-parse-tag-decl-defstruct))
                (parse-ast-defstruct dispatch rest)
                (if (= tag (compiler-parse-tag-decl-import))
                  (parse-ast-import rest)
                  (if (= tag (compiler-parse-tag-decl-module))
                    (parse-ast-module rest)
                    (if (= tag (compiler-parse-tag-decl-comptime-decl))
                      (parse-ast-comptime-decl dispatch rest)
                      (if (= tag (compiler-parse-tag-decl-test))
                        (parse-ast-test
                          dispatch
                          rest
                          (ast-source-span-from-source-span
                            (spanned-sexpr-span s)))
                        (if (compiler-parse-policy-form? head)
                          (ErrAstDecl
                            (compiler-parse-abstraction-policy-message))
                          (ErrAstDecl "parse: expected declaration")))))))))))]
    [_ (ErrAstDecl "parse: malformed declaration")]))

(define (parse-ast-program-forms
  [dispatch : SymI64Env]
  [toks : (Array SpannedToken)]
  [cur : (Array i64)]) : ResultAstDeclList
  (if (= (peek-spanned-tag toks cur) (tag-end))
    (OkAstDeclList AstDeclNil)
    (match (read-form-spanned-result toks cur)
      [(OkSpannedSexpr form)
        (match (parse-ast-decl dispatch form)
          [(OkAstDecl decl)
            (match (parse-ast-program-forms dispatch toks cur)
              [(OkAstDeclList rest) (OkAstDeclList (AstDeclCons decl rest))]
              [(ErrAstDeclList message) (ErrAstDeclList message)])]
          [(ErrAstDecl message) (ErrAstDeclList message)])]
      [(ErrSpannedSexpr err) (ErrAstDeclList (source-error-message err))])))

(define (parse-ast-program-dispatch) : SymI64Env
  (compiler-parse-dispatch-env))

(define (parse-ast-program [toks : (Array SpannedToken)]) : ResultAstProgram
  (let
    [cur : (Array i64) (make-array i64 1)]
    (let
      [dispatch : SymI64Env (parse-ast-program-dispatch)]
      (begin
        (array-set! cur 0 0)
        (match (parse-ast-program-forms dispatch toks cur)
          [(OkAstDeclList decls) (OkAstProgram (AstProgram decls))]
          [(ErrAstDeclList message) (ErrAstProgram message)])))))

(define (parse-ast-source [src : String]) : ResultAstProgram
  (match (lex-spanned-result src)
    [(OkSpannedTokens toks) (parse-ast-program toks)]
    [(ErrSpannedTokens err) (ErrAstProgram (source-error-message err))]))

(define (parse-ast-repl-source [src : String]) : ResultAstReplItem
  (match (lex-spanned-result src)
    [(OkSpannedTokens toks)
      (let
        [cur : (Array i64) (make-array i64 1)]
        [dispatch : SymI64Env (parse-ast-program-dispatch)]
        (begin
          (array-set! cur 0 0)
          (if (= (peek-spanned-tag toks cur) (tag-end))
            (ErrAstReplItem "parse: expected REPL input")
            (match (read-form-spanned-result toks cur)
              [(OkSpannedSexpr form)
                (if (= (peek-spanned-tag toks cur) (tag-end))
                  (match (parse-ast-decl dispatch form)
                    [(OkAstDecl decl) (OkAstReplItem (AstReplDecl decl))]
                    [(ErrAstDecl _)
                      (match (parse-ast-expr dispatch form)
                        [(OkAstExpr expr) (OkAstReplItem (AstReplExpr expr))]
                        [(ErrAstExpr message) (ErrAstReplItem message)])])
                  (ErrAstReplItem "parse: trailing tokens after REPL input"))]
              [(ErrSpannedSexpr err)
                (ErrAstReplItem (source-error-message err))]))))]
    [(ErrSpannedTokens err) (ErrAstReplItem (source-error-message err))]))

(define (parse-ast-program-forms-diagnostic
  [path : String]
  [dispatch : SymI64Env]
  [toks : (Array SpannedToken)]
  [cur : (Array i64)]) : ResultAstDeclListDiagnostic
  (if (= (peek-spanned-tag toks cur) (tag-end))
    (OkAstDeclListDiagnostic AstDeclNil)
    (match (read-form-spanned-result toks cur)
      [(OkSpannedSexpr spanned-form)
        (match (parse-ast-decl dispatch spanned-form)
          [(OkAstDecl decl)
            (match (parse-ast-program-forms-diagnostic path dispatch toks cur)
              [(OkAstDeclListDiagnostic rest)
                (OkAstDeclListDiagnostic (AstDeclCons decl rest))]
              [(ErrAstDeclListDiagnostic diag) (ErrAstDeclListDiagnostic diag)])]
          [(ErrAstDecl message)
            (ErrAstDeclListDiagnostic
              (compiler-diagnostic-from-span
                path
                (spanned-sexpr-span spanned-form)
                message))])]
      [(ErrSpannedSexpr err)
        (ErrAstDeclListDiagnostic
          (compiler-diagnostic-from-source-error path err))])))

(define (parse-ast-program-diagnostic
  [path : String]
  [toks : (Array SpannedToken)]) : ResultAstProgramDiagnostic
  (let
    [cur : (Array i64) (make-array i64 1)]
    (let
      [dispatch : SymI64Env (parse-ast-program-dispatch)]
      (begin
        (array-set! cur 0 0)
        (match (parse-ast-program-forms-diagnostic path dispatch toks cur)
          [(OkAstDeclListDiagnostic decls)
            (OkAstProgramDiagnostic (AstProgram decls))]
          [(ErrAstDeclListDiagnostic diag) (ErrAstProgramDiagnostic diag)])))))

(define (parse-ast-source-diagnostic [path : String] [src : String]) : ResultAstProgramDiagnostic
  (match (lex-spanned-result src)
    [(OkSpannedTokens toks) (parse-ast-program-diagnostic path toks)]
    [(ErrSpannedTokens err)
      (ErrAstProgramDiagnostic (compiler-diagnostic-from-source-error path err))]))

(define (ast-decl-list-count [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons _ rest) (+ 1 (ast-decl-list-count rest))]))

(define (ast-decl-list-tag-sum [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons decl rest)
      (+ (ast-decl-tag decl) (ast-decl-list-tag-sum rest))]))

(define (compiler-parse-expr-list-count [exprs : AstExprList]) : i64
  (match exprs
    [(AstExprNil) 0]
    [(AstExprCons _ rest) (+ 1 (compiler-parse-expr-list-count rest))]))

(define (compiler-parse-resource-binding-count
  [bindings : AstResourceBindingList]) : i64
  (match bindings
    [(AstResourceBindingNil) 0]
    [(AstResourceBindingCons _ rest)
      (+ 1 (compiler-parse-resource-binding-count rest))]))

(define (ast-first-import-ok? [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclCons (AstDeclImport (AstImportSpec path _ _)) _)
      (string-eq path "stdlib/test.tl")]
    [_ false]))

(define (compiler-parse-module-decl-ok?) : bool
  (match (parse-ast-source "(module std.io)")
    [(OkAstProgram (AstProgram decls))
      (match decls
        [(AstDeclCons (AstDeclModule name) AstDeclNil)
          (string-eq name "std.io")]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-import-metadata-ok?) : bool
  (match (parse-ast-source "(import \"stdlib/io.tl\" module std.io as io)")
    [(OkAstProgram (AstProgram decls))
      (match decls
        [(AstDeclCons
            (AstDeclImport
              (AstImportSpec
                path
                (AstSomeModuleName module-name)
                (AstSomeImportAlias alias)))
            AstDeclNil)
          (and
            (string-eq path "stdlib/io.tl")
            (and (string-eq module-name "std.io") (string-eq alias "io")))]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (ast-source-span-start-line [span : AstSourceSpan]) : i64
  (struct-get span start-line))

(define (ast-source-span-start-col [span : AstSourceSpan]) : i64
  (struct-get span start-col))

(define (ast-expr-inner-tag [expr : AstExpr]) : i64
  (ast-expr-tag (ast-expr-unspan expr)))

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

(define (compiler-parse-nested-expr-span-ok?) : bool
  (match (parse-ast-source "(define (main) : i64 (+ 1 (* 2 3)))")
    [(OkAstProgram (AstProgram decls))
      (match decls
        [(AstDeclCons (AstDeclDefFn _ _ _ body) _)
          (match body
            [(AstExprSpanned (AstExprBinary _ _ right) body-span)
              (match right
                [(AstExprSpanned (AstExprBinary _ _ _) right-span)
                  (and
                    (= (ast-source-span-start-line body-span) 1)
                    (and
                      (= (ast-source-span-start-line right-span) 1)
                      (>
                        (ast-source-span-start-col right-span)
                        (ast-source-span-start-col body-span))))]
                [_ false])]
            [_ false])]
        [_ false])]
    [_ false]))

(define (compiler-parse-error-span-ok?) : bool
  (let
    [src : String "(define)"]
    (and
      (match (parse-ast-source src)
        [(ErrAstProgram message) (string-eq message "parse: malformed define")]
        [_ false])
      (match (lex-spanned-result src)
        [(OkSpannedTokens toks)
          (let
            [cur : (Array i64) (make-array i64 1)]
            (begin
              (array-set! cur 0 0)
              (match (read-form-spanned-result toks cur)
                [(OkSpannedSexpr form)
                  (let
                    [span : SourceSpan (spanned-sexpr-span form)]
                    (and
                      (= (span-start-line span) 1)
                      (= (span-start-col span) 1)))]
                [(ErrSpannedSexpr _) false])))]
        [(ErrSpannedTokens _) false]))))

(define (compiler-parse-float-literal-ok?) : bool
  (match (parse-ast-source "(define (main) : f64 1.5)")
    [(OkAstProgram (AstProgram decls))
      (match decls
        [(AstDeclCons (AstDeclDefFn name _ (AstTyF64) body) _)
          (and
            (string-eq name "main")
            (match (ast-expr-unspan body)
              [(AstExprLiteral (AstLitFloat text)) (string-eq text "1.5")]
              [_ false]))]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-smoke-source) : String
  "(import \"stdlib/test.tl\")
(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(extern print-string : (-> String unit))
(define answer : i64 42)
(define (main [argc : i64] [name : String]) : i64
  (let
    [x : i64 1]
    [arr (array 1 2 3)]
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

;; True only when `src` fails to parse with exactly the wanted diagnostic. The
;; counterpart to the success-path smoke: it pins the parser's rejection
;; messages so a regression that drops or relabels an error is caught (#655).
(define (compiler-parse-error-ok? [src : String] [want : String]) : bool
  (match (parse-ast-source src)
    [(ErrAstProgram message) (string-eq message want)]
    [(OkAstProgram _) false]))

;; Minimal complete programs that lex cleanly but reach a specific parser
;; rejection, one per representative special form.
(define (compiler-parse-malformed-binary-source) : String
  "(define (main) : i64 (+ 1))")

(define (compiler-parse-malformed-if-source) : String
  "(define (main) : i64 (if true 1))")

(define (compiler-parse-malformed-while-source) : String
  "(define (main) : i64 (while true))")

(define (compiler-parse-malformed-set-source) : String
  "(define (main) : i64 (set! x))")

(define (compiler-parse-cond-no-else-source) : String
  "(define (main) : i64 (cond))")

(define (compiler-parse-region-source) : String
  "(define (main) : (in r String)
  (with-arena r \"x\"))")

(define (compiler-parse-with-region-empty-source) : String
  "(define (main) : i64 (with-arena r))")

(define (compiler-parse-region-type-bad-source) : String
  "(define (main) : (in 1 String) 0)")

(define (compiler-parse-region-ok?) : bool
  (match (parse-ast-source (compiler-parse-region-source))
    [(OkAstProgram _) true]
    [(ErrAstProgram _) false]))

(define (compiler-parse-arena-source) : String
  "(define (main) : i64
  (with-arena r 5))")

;; `with-arena` is the canonical spelling (#801, #1118). Assert it parses to
;; the `AstExprWithRegion` form, not an unbound call.
(define (compiler-parse-arena-ok?) : bool
  (match (parse-ast-source (compiler-parse-arena-source))
    [(OkAstProgram (AstProgram decls))
      (match decls
        [(AstDeclCons (AstDeclDefFn name _ (AstTyI64) body) _)
          (and
            (string-eq name "main")
            (match (ast-expr-unspan body)
              [(AstExprWithRegion region _) (string-eq region "r")]
              [_ false]))]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-raw-pointer-source) : String
  "(extern raw-map : (-> (Ptr i64) (MutPtr (Ptr u8))))")

(define (compiler-parse-raw-pointer-ok?) : bool
  (match (parse-ast-source (compiler-parse-raw-pointer-source))
    [(OkAstProgram (AstProgram decls))
      (match decls
        [(AstDeclCons (AstDeclExtern name ty) AstDeclNil)
          (and
            (string-eq name "raw-map")
            (match ty
              [(AstTyFunc args ret)
                (match args
                  [(AstTypeCons (AstTyPtr (AstTyI64)) AstTypeNil)
                    (match ret
                      [(AstTyMutPtr (AstTyPtr (AstTyU8))) true]
                      [_ false])]
                  [_ false])]
              [_ false]))]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-reference-source) : String
  "(define (use [s : (& r String)] [items : (&mut phase (Array i64))]) : unit unit)")

(define (compiler-parse-reference-ok?) : bool
  (match (parse-ast-source (compiler-parse-reference-source))
    [(OkAstProgram (AstProgram decls))
      (match decls
        [(AstDeclCons (AstDeclDefFn _ params _ _) AstDeclNil)
          (match params
            [(AstParamCons
                (AstParam _ (AstTyRef region (AstTyString)) false)
                (AstParamCons
                  (AstParam
                    _
                    (AstTyMutRef phase (AstTyDynArray (AstTyI64)))
                    false)
                  AstParamNil))
              (and (string-eq region "r") (string-eq phase "phase"))]
            [_ false])]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-try-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (read) : ResultI64 (OkI64 42))
(define (main) : ResultI64 (OkI64 (try (read))))")

(define (compiler-parse-try-ok?) : bool
  (match (parse-ast-source (compiler-parse-try-source))
    [(OkAstProgram (AstProgram decls))
      (match decls
        [(AstDeclCons
            _
            (AstDeclCons _ (AstDeclCons (AstDeclDefFn _ _ _ body) AstDeclNil)))
          (match (ast-expr-unspan body)
            [(AstExprCall _ args)
              (match args
                [(AstExprCons arg AstExprNil)
                  (match (ast-expr-unspan arg)
                    [(AstExprTry _) true]
                    [_ false])]
                [_ false])]
            [_ false])]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-comptime-decl-source) : String
  "(comptime-decl (defstruct Point (x i64) (y i64)))
(comptime-decl (defenum Maybe (None) (Some i64)))")

(define (compiler-parse-comptime-decl-ok?) : bool
  (match (parse-ast-source (compiler-parse-comptime-decl-source))
    [(OkAstProgram (AstProgram decls))
      (and
        (= (ast-decl-list-count decls) 2)
        (= (ast-decl-list-tag-sum decls) 16))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-field-count [fields : AstFieldDefList]) : i64
  (match fields
    [(AstFieldDefNil) 0]
    [(AstFieldDefCons _ rest) (+ 1 (compiler-parse-field-count rest))]))

(define (compiler-parse-repr-c-source) : String
  "(defstruct Stat
  (:repr c)
  (size i64)
  (mtime i64))")

(define (compiler-parse-repr-c-ok?) : bool
  (match (parse-ast-source (compiler-parse-repr-c-source))
    [(OkAstProgram (AstProgram decls))
      (match decls
        [(AstDeclCons (AstDeclDefStruct name repr fields) AstDeclNil)
          (and
            (string-eq name "Stat")
            (and
              (ast-struct-repr-c? repr)
              (= (compiler-parse-field-count fields) 2)))]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-comptime-repr-c-source) : String
  "(comptime-decl (defstruct Stat (:repr c) (size i64)))")

(define (compiler-parse-comptime-repr-c-ok?) : bool
  (match (parse-ast-source (compiler-parse-comptime-repr-c-source))
    [(OkAstProgram (AstProgram decls))
      (match decls
        [(AstDeclCons (AstDeclComptimeDecl template) AstDeclNil)
          (match template
            [(AstDeclDefStruct _ repr fields)
              (and
                (ast-struct-repr-c? repr)
                (= (compiler-parse-field-count fields) 1))]
            [_ false])]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-inline-test-source) : String
  "(test parser-basic
  (+ 1 2)
  3)")

(define (compiler-parse-inline-test-ok?) : bool
  (match (parse-ast-source (compiler-parse-inline-test-source))
    [(OkAstProgram (AstProgram decls))
      (match decls
        [(AstDeclCons (AstDeclTest name body span) (AstDeclNil))
          (and
            (string-eq name "parser-basic")
            (and
              (= (ast-source-span-start-line span) 1)
              (match (ast-expr-unspan body)
                [(AstExprBegin (AstExprCons _ (AstExprCons _ (AstExprNil))))
                  true]
                [_ false])))]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-comptime-decl-bad-payload-source) : String
  "(comptime-decl (define x : i64 1))")

(define (compiler-parse-comptime-decl-expression-source) : String
  "(define (main) : i64 (comptime-decl (defstruct Point (x i64))))")

(define (compiler-parse-comptime-decl-extra-source) : String
  "(comptime-decl (defstruct Point (x i64)) (defenum Maybe (None)))")

(define (compiler-parse-malformed-module-source) : String
  "(module)")

(define (compiler-parse-malformed-import-source) : String
  "(import \"stdlib/io.tl\" as)")

(define (compiler-parse-defgeneric-policy-source) : String
  "(defgeneric Box [T] (value T))")

(define (compiler-parse-trait-policy-source) : String
  "(trait Printable (print-self : (-> Self unit)))")

(define (compiler-parse-generic-type-policy-source) : String
  "(define value : (Option i64) 0)")

(define (compiler-parse-empty-test-source) : String
  "(test empty)")

(define (compiler-parse-malformed-try-source) : String
  "(define (main) : i64 (try))")

(define (compiler-parse-repr-c-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr c) (:repr c) (x i64))"
      "parse: duplicate defstruct :repr metadata")
    (and
      (compiler-parse-error-ok?
        "(defstruct Bad (:repr rust) (x i64))"
        "parse: unknown struct repr rust")
      (and
        (compiler-parse-error-ok?
          "(defstruct Bad (:repr packed) (x i64))"
          "parse: packed repr is reserved")
        (and
          (compiler-parse-error-ok?
            "(defstruct Bad (x i64) (:repr c))"
            "parse: defstruct metadata must appear before fields")
          (and
            (compiler-parse-error-ok?
              "(defstruct Bad (:layout c) (x i64))"
              "parse: unknown defstruct metadata :layout")
            (compiler-parse-error-ok?
              "(defstruct Bad (:repr c))"
              "parse: defstruct needs at least one field")))))))

(define (compiler-parse-comptime-decl-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decl-bad-payload-source)
      "parse: comptime-decl accepts only defstruct or defenum")
    (and
      (compiler-parse-error-ok?
        (compiler-parse-comptime-decl-expression-source)
        "parse: comptime-decl is only valid as a top-level declaration")
      (compiler-parse-error-ok?
        (compiler-parse-comptime-decl-extra-source)
        "parse: comptime-decl expects exactly one template"))))

(define (compiler-parse-flat-let-call-body-ok?) : bool
  (match (parse-ast-source
    "(define (id [x : i64]) : i64 x)
(define (main) : i64 (let [x : i64 41] (id x)))")
    [(OkAstProgram _) true]
    [(ErrAstProgram _) false]))

(define (compiler-parse-let-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (main) : i64 (let 1))"
      "parse: let requires at least one binding")
    (and
      (compiler-parse-error-ok?
        "(define (main) : i64 (let [x : i64] x))"
        "parse: malformed let binding")
      (and
        (compiler-parse-error-ok?
          "(define (main) : i64 (let [x : i64 1]))"
          "parse: let missing body")
        (compiler-parse-error-ok?
          "(define (main) : i64 (let [x : i64 1] x x))"
          "parse: let expects exactly one body")))))

(define (compiler-parse-abstraction-policy-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      (compiler-parse-defgeneric-policy-source)
      (compiler-parse-abstraction-policy-message))
    (and
      (compiler-parse-error-ok?
        (compiler-parse-trait-policy-source)
        (compiler-parse-abstraction-policy-message))
      (compiler-parse-error-ok?
        (compiler-parse-generic-type-policy-source)
        (compiler-parse-generic-type-policy-message "Option")))))

(define (compiler-parse-raw-pointer-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (main [p : (Ptr)]) : unit unit)"
      "parse: Ptr expects exactly one type")
    (and
      (compiler-parse-error-ok?
        "(define (main [p : (MutPtr i64 i64)]) : unit unit)"
        "parse: MutPtr expects exactly one type")
      (compiler-parse-error-ok?
        "(define (main [p : (Ptr (Array))]) : unit unit)"
        "parse: malformed array type"))))

(define (compiler-parse-reference-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (main [p : (&)]) : unit unit)"
      "parse: & expects lifetime and exactly one type")
    (and
      (compiler-parse-error-ok?
        "(define (main [p : (& r)]) : unit unit)"
        "parse: & expects lifetime and exactly one type")
      (and
        (compiler-parse-error-ok?
          "(define (main [p : (& 1 i64)]) : unit unit)"
          "parse: reference lifetime must be an identifier")
        (and
          (compiler-parse-error-ok?
            "(define (main [p : (& r i64 i64)]) : unit unit)"
            "parse: & expects lifetime and exactly one type")
          (compiler-parse-error-ok?
            "(define (main [p : (&mut phase)]) : unit unit)"
            "parse: &mut expects lifetime and exactly one type"))))))

(define (compiler-parse-special-form-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      (compiler-parse-malformed-binary-source)
      "parse: malformed binary expression")
    (and
      (compiler-parse-error-ok?
        (compiler-parse-malformed-if-source)
        "parse: malformed if")
      (and
        (compiler-parse-error-ok?
          (compiler-parse-malformed-while-source)
          "parse: malformed while")
        (and
          (compiler-parse-error-ok?
            (compiler-parse-malformed-set-source)
            "parse: malformed set!")
          (and
            (compiler-parse-error-ok?
              (compiler-parse-cond-no-else-source)
              "parse: cond requires final else arm")
            (and
              (compiler-parse-error-ok?
                (compiler-parse-with-region-empty-source)
                "parse: with-arena 'r' requires a non-empty body")
              (and
                (compiler-parse-error-ok?
                  (compiler-parse-region-type-bad-source)
                  "parse: region name must be an identifier")
                (compiler-parse-error-ok?
                  (compiler-parse-malformed-try-source)
                  "parse: try expects exactly one expression")))))))))

(define (compiler-parse-error-tests-ok?) : bool
  (and
    (compiler-parse-special-form-error-tests-ok?)
    (and
      (compiler-parse-comptime-decl-error-tests-ok?)
      (and
        (compiler-parse-repr-c-error-tests-ok?)
        (and
          (compiler-parse-error-ok?
            (compiler-parse-malformed-module-source)
            "parse: malformed module")
          (and
            (compiler-parse-error-ok?
              (compiler-parse-malformed-import-source)
              "parse: malformed import")
            (and
              (compiler-parse-error-ok?
                (compiler-parse-empty-test-source)
                "parse: test needs at least one expression")
              (and
                (compiler-parse-let-error-tests-ok?)
                (and
                  (compiler-parse-abstraction-policy-tests-ok?)
                  (and
                    (compiler-parse-raw-pointer-error-tests-ok?)
                    (compiler-parse-reference-error-tests-ok?)))))))))))

;; Top-level declaration parsing (#1072 / #1041): accept value/function `define`,
;; `extern`, `defenum`, `defstruct`, and `import`; reject malformed forms with
;; stable diagnostics. Migrated from src/parser.rs declaration coverage.
(define (compiler-parse-ok? [src : String]) : bool
  (match (parse-ast-source src)
    [(OkAstProgram _) true]
    [(ErrAstProgram _) false]))

(define (compiler-parse-declaration-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define answer : i64 42)")
    (and
      (compiler-parse-ok? "(define (add [a : i64] [b : i64]) : i64 (+ a b))")
      (and
        (compiler-parse-ok? "(extern puts : (-> String unit))")
        (and
          (compiler-parse-ok? "(defenum Maybe (Some i64) (None))")
          (and
            (compiler-parse-ok? "(defstruct Point (x i64) (y i64))")
            (and
              (compiler-parse-ok? "(import \"stdlib/io.tl\")")
              (and
                (compiler-parse-error-ok?
                  "(define answer : i64)"
                  "parse: malformed value definition")
                (and
                  (compiler-parse-error-ok?
                    "(define (main) : i64)"
                    "parse: malformed function definition")
                  (and
                    (compiler-parse-error-ok?
                      "(extern puts)"
                      "parse: malformed extern")
                    (and
                      (compiler-parse-error-ok?
                        "(defenum)"
                        "parse: malformed defenum")
                      (and
                        (compiler-parse-error-ok?
                          "(defstruct)"
                          "parse: malformed defstruct")
                        (compiler-parse-error-ok?
                          "(import)"
                          "parse: malformed import")))))))))))))

;; enum/struct expression coverage (#1073): defenum empty rejection,
;; defstruct mixed field types, empty struct rejection, struct-get, and
;; struct construction-as-call.
(define (compiler-parse-enum-struct-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(defenum Empty)"
      "parse: defenum needs at least one variant")
    (and
      (compiler-parse-ok? "(defstruct Point (x i64) (y i64))")
      (and
        (compiler-parse-ok? "(defstruct Mixed (a i64) (b bool) (c f64))")
        (and
          (compiler-parse-error-ok?
            "(defstruct Empty)"
            "parse: defstruct needs at least one field")
          (and
            (compiler-parse-ok?
              "(define (f [p : Point]) : i64 (struct-get p x))")
            (compiler-parse-ok? "(define (f) : Point (Point 1 2))")))))))

;
;; let-binding parsing (#1072 / #1041): accept untyped, multi-binding, and
;; legacy-parenthesized binding forms; reject an empty binding list. Completes
;; the let family alongside the existing flat-let accept and let error tests.
(define (compiler-parse-let-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (let [x 1] x))")
    (and
      (compiler-parse-ok?
        "(define (main) : i64 (let [x : i64 1] [y : i64 2] (+ x y)))")
      (and
        (compiler-parse-ok? "(define (main) : i64 (let ([x : i64 1]) x))")
        (compiler-parse-error-ok?
          "(define (main) : i64 (let [] 0))"
          "parse: malformed let binding")))))

(define (compiler-parse-spmd-tests-ok?) : bool
  (and
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : i64 0 3]) unit) 0))")
    (and
      (compiler-parse-ok?
        "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))")
      (and
        ;; #1073: an empty range, a non-i64 index type, and expression
        ;; start/end bounds all parse (range semantics are checked later).
        (compiler-parse-ok?
          "(define (main) : i64 (begin (foreach ([i : i64 5 5]) unit) 0))")
        (and
          (compiler-parse-ok?
            "(define (main) : i64 (begin (foreach ([i : u32 0 3]) unit) 0))")
          (and
            (compiler-parse-ok?
              "(define (main [n : i64]) : i64 (begin (foreach ([i : i64 (+ 0 1) (* n 2)]) unit) 0))")
            (and
              ;; #1073: an unknown reduce operator is rejected by the parser.
              (compiler-parse-error-ok?
                "(define (main [n : i64]) : i64 (spmd-reduce bogus ([i : i64 0 n]) 0 i))"
                "parse: unsupported spmd-reduce operator `bogus`; expected one of sum, min, max, all, any")
              (and
                (compiler-parse-error-ok?
                  "(define (main) : i64 (begin (foreach ([i i64 0 3 4]) unit) 0))"
                  "parse: expected ':' in foreach")
                (and
                  (compiler-parse-error-ok?
                    "(define (main) : i64 (begin (foreach ([i : i64 0]) unit) 0))"
                    "parse: malformed foreach binding")
                  (and
                    (compiler-parse-error-ok?
                      "(define (main) : i64 (begin (foreach) 0))"
                      "parse: malformed foreach")
                    (compiler-parse-error-ok?
                      "(define (main) : i64 (spmd-reduce sum))"
                      "parse: malformed spmd-reduce")))))))))))

(define (compiler-parse-pattern-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (match 1 [0 1] [_ 0]))")
    (and
      (compiler-parse-ok?
        "(define (main [b : bool]) : i64 (match b [true 1] [false 0]))")
      (and
        (compiler-parse-ok?
          "(defenum E (A i64) (B))
(define (main [e : E]) : i64 (match e [(A x) x] [(B) 0]))")
        (and
          (compiler-parse-ok? "(define (main) : i64 (match 5 [x x]))")
          (and
            (compiler-parse-error-ok?
              "(define (main) : i64 (match))"
              "parse: malformed match")
            (and
              (compiler-parse-error-ok?
                "(define (main) : i64 (match 1 [_]))"
                "parse: malformed match arm")
              (compiler-parse-error-ok?
                "(define (main) : i64 (match 1 [() 0]))"
                "parse: expected pattern"))))))))

;; pattern literals (#1073): string literal arms, nested string payload,
;; char literal in pattern, named char literal in value position.
(define (compiler-parse-pattern-string-char-tests-ok?) : bool
  (and
    ;; string literal arms
    (compiler-parse-ok?
      "(define (f [s : String]) : i64 (match s [\"if\" 10] [\"let\" 20] [_ 0]))")
    (and
      ;; nested string payload
      (compiler-parse-ok?
        "(defenum Token (TIdent String))\n(define (f [t : Token]) : i64 (match t [(TIdent \"if\") 1] [_ 0]))")
      (and
        ;; char literal in pattern (named space + literal char)
        (compiler-parse-ok?
          "(define (f [c : char]) : i64 (match c [#\\space' 1] [#a' 2] [_ 0]))")
        ;; named char literal in value position
        (compiler-parse-ok? "(define (f) : char #\\newline')")))))

;
;; operator parsing (#1073 / #1041): accept unary (not/neg/bit-not), binary
;; arithmetic/comparison, and bitwise/shift/logical operator forms; reject
;; parser-owned malformed unary/binary operator expressions. Parse-shape only;
;; operator type rules live in the typechecker tests.
(define (compiler-parse-operator-tests-ok?) : bool
  (and
    (compiler-parse-ok?
      "(define (main [a : i64] [p : bool]) : i64 (begin (neg a) (bit-not a) (if (not p) 1 0)))")
    (and
      (compiler-parse-ok?
        "(define (main [a : i64] [b : i64]) : i64 (begin (+ a b) (- a b) (* a b) (< a b) (<= a b) (> a b) (>= a b) (= a b) (!= a b)))")
      (and
        (compiler-parse-ok?
          "(define (main [a : i64] [b : i64] [p : bool] [q : bool]) : i64 (begin (bit-and a b) (bit-or a b) (bit-xor a b) (shl a b) (shr a b) (if (and p q) 1 (if (or p q) 2 0))))")
        (and
          (compiler-parse-error-ok?
            "(define (main) : i64 (not))"
            "parse: malformed unary expression")
          (compiler-parse-error-ok?
            "(define (main [a : i64]) : i64 (+ a))"
            "parse: malformed binary expression"))))))

(define (compiler-parse-type-literal-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (begin (type i64) 0))")
    (and
      (compiler-parse-ok? "(define (main) : i64 (begin (type (Array i64)) 0))")
      (and
        (compiler-parse-ok?
          "(define (main) : i64 (begin (type (-> i64 i64)) 0))")
        (and
          (compiler-parse-error-ok?
            "(define (main) : i64 (type))"
            "parse: type expects exactly one type")
          (compiler-parse-error-ok?
            "(define (main) : i64 (type i64 bool))"
            "parse: type expects exactly one type"))))))

;; region parsing (#1073 / #1041): `(with-arena <ident> body+)` accepts (basic,
;; multi-expression body, nested region) and rejects missing binder,
;; non-identifier binder, and empty body. Parse-shape + parser-owned diagnostics
;; only; region typing/lowering live in their own tests.
(define (compiler-parse-region-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (with-arena r 0))")
    (and
      (compiler-parse-ok? "(define (main) : i64 (with-arena r 1 2 0))")
      (and
        (compiler-parse-ok?
          "(define (main) : i64 (with-arena r (with-arena s 0)))")
        (and
          (compiler-parse-error-ok?
            "(define (main) : i64 (with-arena))"
            "parse: with-arena requires a region name before its body")
          (and
            (compiler-parse-error-ok?
              "(define (main) : i64 (with-arena 5 0))"
              "parse: with-arena region name must be an identifier")
            (compiler-parse-error-ok?
              "(define (main) : i64 (with-arena r))"
              "parse: with-arena 'r' requires a non-empty body")))))))

(define (compiler-parse-resource-with-source) : String
  "(define (main) : i64
  (with ([h (open-handle) close-handle]
         [tmp (open-temp) close-temp])
    (use h)
    (with ([inner (open-inner tmp) close-inner])
      42)))")

(define (compiler-parse-resource-with-shape-ok?) : bool
  (match (parse-ast-source (compiler-parse-resource-with-source))
    [(OkAstProgram (AstProgram decls))
      (match decls
        [(AstDeclCons (AstDeclDefFn _ _ _ body) AstDeclNil)
          (match (ast-expr-unspan body)
            [(AstExprWithResource bindings body-exprs)
              (and
                (= (compiler-parse-resource-binding-count bindings) 2)
                (and
                  (= (compiler-parse-expr-list-count body-exprs) 2)
                  (match body-exprs
                    [(AstExprCons _ (AstExprCons nested AstExprNil))
                      (match (ast-expr-unspan nested)
                        [(AstExprWithResource nested-bindings nested-body)
                          (and
                            (=
                              (compiler-parse-resource-binding-count
                                nested-bindings)
                              1)
                            (= (compiler-parse-expr-list-count nested-body) 1))]
                        [_ false])]
                    [_ false])))]
            [_ false])]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-resource-with-tests-ok?) : bool
  (and
    (compiler-parse-resource-with-shape-ok?)
    (and
      (compiler-parse-ok?
        "(define (main) : i64 (with ([h (open-handle) close-handle]) 42))")
      (and
        (compiler-parse-error-ok?
          "(define (main) : i64 (with))"
          "parse: with requires a binding list before its body")
        (and
          (compiler-parse-error-ok?
            "(define (main) : i64 (with () 42))"
            "parse: with requires a non-empty binding list")
          (and
            (compiler-parse-error-ok?
              "(define (main) : i64 (with ([1 (open) close]) 42))"
              "parse: with binding name must be an identifier")
            (and
              (compiler-parse-error-ok?
                "(define (main) : i64 (with ([h]) 42))"
                "parse: with binding is missing initializer")
              (and
                (compiler-parse-error-ok?
                  "(define (main) : i64 (with ([h (open)]) 42))"
                  "parse: with binding is missing cleanup function")
                (and
                  (compiler-parse-error-ok?
                    "(define (main) : i64 (with ([h (open) close extra]) 42))"
                    "parse: with binding has too many fields")
                  (and
                    (compiler-parse-error-ok?
                      "(define (main) : i64 (with ([h (open) close])))"
                      "parse: with requires a non-empty body")
                    (and
                      (compiler-parse-error-ok?
                        "(define (main) : i64 (with [h (open) close] 42))"
                        "parse: malformed with binding list")
                      (compiler-parse-error-ok?
                        "(define (main) : i64 (with ((h (open) close)) 42))"
                        "parse: with binding must use bracket syntax"))))))))))))

;; REPL-item parsing (#1072 / #1041): `parse-ast-repl-source` accepts a single
;; top-level declaration, a parenthesized expression, or a bare expression, and
;; rejects trailing tokens and a malformed expression. Mirrors the Rust
;; parser's `parse_repl_item` tests.
(define (compiler-parse-repl-decl-ok? [src : String]) : bool
  (match (parse-ast-repl-source src)
    [(OkAstReplItem item)
      (match item
        [(AstReplDecl _) true]
        [(AstReplExpr _) false])]
    [(ErrAstReplItem _) false]))

(define (compiler-parse-repl-expr-ok? [src : String]) : bool
  (match (parse-ast-repl-source src)
    [(OkAstReplItem item)
      (match item
        [(AstReplExpr _) true]
        [(AstReplDecl _) false])]
    [(ErrAstReplItem _) false]))

(define (compiler-parse-repl-error-ok? [src : String] [expected : String]) : bool
  (match (parse-ast-repl-source src)
    [(OkAstReplItem _) false]
    [(ErrAstReplItem message) (string-eq message expected)]))

(define (compiler-parse-repl-tests-ok?) : bool
  (and
    ;; declaration item
    (compiler-parse-repl-decl-ok? "(define x : i64 42)")
    (and
      ;; parenthesized expression item
      (compiler-parse-repl-expr-ok? "(+ 1 2)")
      (and
        ;; bare expression item
        (compiler-parse-repl-expr-ok? "42")
        (and
          ;; trailing tokens after a complete item are rejected
          (compiler-parse-repl-error-ok?
            "42 43"
            "parse: trailing tokens after REPL input")
          ;; a malformed expression item surfaces the expression diagnostic
          (compiler-parse-repl-error-ok?
            "(+ 1)"
            "parse: malformed binary expression"))))))

;; comptime function-parameter parsing (#1072 / #1041): `[comptime n : i64]`
;; and the type-valued `[comptime T : type]` parse as top-level function
;; parameters marked comptime; a comptime parameter on a lambda is rejected
;; (comptime params are top-level-only). Mirrors the Rust parser's
;; test_parse_comptime_function_param / _type_valued_comptime_param /
;; _comptime_lambda_param_rejected.
(define (compiler-parse-first-fn-has-comptime-param? [src : String]) : bool
  (match (parse-ast-source src)
    [(OkAstProgram (AstProgram decls))
      (match decls
        [(AstDeclCons (AstDeclDefFn _ params _ _) _)
          (ast-param-list-has-comptime? params)]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-comptime-param-tests-ok?) : bool
  (and
    (compiler-parse-first-fn-has-comptime-param?
      "(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))")
    (and
      (compiler-parse-first-fn-has-comptime-param?
        "(define (alloc [comptime T : type] [n : i64]) : (Array i64) (make-array T n))")
      (compiler-parse-error-ok?
        "(define (main) : i64 ((lambda ([comptime n : i64]) n) 1))"
        "comptime parameters are only supported on top-level function definitions"))))

(define (compiler-parse-smoke) : i64
  (match (parse-ast-source (compiler-parse-smoke-source))
    [(OkAstProgram program)
      (if (and
        (= (compiler-parse-smoke-score program) 36)
        (and
          (compiler-parse-nested-expr-span-ok?)
          (and
            (compiler-parse-error-span-ok?)
            (and
              (compiler-parse-float-literal-ok?)
              (and
                (compiler-parse-region-ok?)
                (and
                  (compiler-parse-arena-ok?)
                  (and
                    (compiler-parse-comptime-decl-ok?)
                    (and
                      (compiler-parse-module-decl-ok?)
                      (and
                        (compiler-parse-import-metadata-ok?)
                        (and
                          (compiler-parse-flat-let-call-body-ok?)
                          (and
                            (compiler-parse-inline-test-ok?)
                            (and
                              (compiler-parse-try-ok?)
                              (and
                                (compiler-parse-repr-c-ok?)
                                (and
                                  (compiler-parse-raw-pointer-ok?)
                                  (and
                                    (compiler-parse-reference-ok?)
                                    (compiler-parse-resource-with-shape-ok?))))))))))))))))
        (if (and
          (compiler-parse-error-tests-ok?)
          (and
            (compiler-parse-declaration-tests-ok?)
            (and
              (compiler-parse-let-tests-ok?)
              (and
                (compiler-parse-spmd-tests-ok?)
                (and
                  (compiler-parse-pattern-tests-ok?)
                  (and
                    (compiler-parse-pattern-string-char-tests-ok?)
                    (and
                      (compiler-parse-enum-struct-tests-ok?)
                      (and
                        (compiler-parse-operator-tests-ok?)
                        (and
                          (compiler-parse-type-literal-tests-ok?)
                          (and
                            (compiler-parse-region-tests-ok?)
                            (and
                              (compiler-parse-repl-tests-ok?)
                              (and
                                (compiler-parse-comptime-param-tests-ok?)
                                (compiler-parse-resource-with-tests-ok?)))))))))))))
          42
          (begin
            (panic "parse: error-path self-tests failed")
            0))
        (begin
          (panic "parse: compiler AST smoke score mismatch")
          0))]
    [(ErrAstProgram message)
      (begin
        (panic message)
        0)]))