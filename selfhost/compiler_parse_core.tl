;; compiler_parse_core.tl - Sexpr -> real compiler AST parser (#335).
;;
;; This module targets `compiler_ast_types.tl`, not the smaller
;; compile_smoke AST. It stays parser-only: later #27 work can reuse the
;; parsed `AstProgram` for typechecking/lowering once those selfhost passes
;; exist.
(import "../stdlib/io.tl")

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

(defenum ResultAstLifetimeList
  (OkAstLifetimeList AstLifetimeList)
  (ErrAstLifetimeList String))

(defenum ResultAstParam
  (OkAstParam AstParam)
  (ErrAstParam String))

(defenum ResultAstParamList
  (OkAstParamList AstParamList)
  (ErrAstParamList String))

(defenum ResultAstMacroParam
  (OkAstMacroParam AstMacroParam)
  (ErrAstMacroParam String))

(defenum ResultAstMacroParamList
  (OkAstMacroParamList AstMacroParamList)
  (ErrAstMacroParamList String))

(defenum ResultAstFieldDef
  (OkAstFieldDef AstFieldDef)
  (ErrAstFieldDef String))

(defenum ResultAstFieldDefList
  (OkAstFieldDefList AstFieldDefList)
  (ErrAstFieldDefList String))

(defenum ResultAstFieldCleanup
  (OkAstFieldCleanup AstFieldCleanup)
  (ErrAstFieldCleanup String))

(defenum ResultAstStructRepr
  (OkAstStructRepr AstStructRepr)
  (ErrAstStructRepr String))

(defenum ResultAstStructCleanup
  (OkAstStructCleanup AstStructCleanup)
  (ErrAstStructCleanup String))

(defenum ResultAstStructDefParts
  (OkAstStructDefParts
    AstLifetimeList
    AstStructRepr
    AstStructCleanup
    AstFieldDefList)
  (ErrAstStructDefParts String))

(defenum ResultAstEnumDefParts
  (OkAstEnumDefParts AstLifetimeList AstVariantDefList)
  (ErrAstEnumDefParts String))

(defenum ResultAstExternAbi
  (OkAstExternAbi AstExternAbi)
  (ErrAstExternAbi String))

(defenum ResultAstExternSymbol
  (OkAstExternSymbol String)
  (ErrAstExternSymbol String))

(defenum ResultAstExternParts
  (OkAstExternParts AstExternMetadata AstType)
  (ErrAstExternParts String))

(defenum ResultAstVariantDef
  (OkAstVariantDef AstVariantDef)
  (ErrAstVariantDef String))

(defenum ResultAstVariantDefList
  (OkAstVariantDefList AstVariantDefList)
  (ErrAstVariantDefList String))

(defenum ResultAstDispatchIsa
  (OkAstDispatchIsa AstDispatchIsa)
  (ErrAstDispatchIsa String))

(defenum ResultAstDispatchVariant
  (OkAstDispatchVariant AstDispatchVariant)
  (ErrAstDispatchVariant String))

(defenum ResultAstDispatchVariantList
  (OkAstDispatchVariantList AstDispatchVariantList)
  (ErrAstDispatchVariantList String))

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

(defstruct AstExprPair
  (first AstExpr)
  (second AstExpr))

(defenum ResultAstExprPair
  (OkAstExprPair AstExprPair)
  (ErrAstExprPair String))

(defenum ResultAstExprList
  (OkAstExprList AstExprList)
  (ErrAstExprList String))

(defenum ResultAstGeneratedDeclMeta
  (OkAstGeneratedDeclMeta AstGeneratedDeclMeta)
  (ErrAstGeneratedDeclMeta String))

(defenum ResultAstExportItem
  (OkAstExportItem AstExportItem)
  (ErrAstExportItem String))

(defenum ResultAstExportItemList
  (OkAstExportItemList AstExportItemList)
  (ErrAstExportItemList String))

(defenum ResultAstDecl
  (OkAstDecl AstDecl)
  (ErrAstDecl String))

(defenum ResultAstMaybeDecl
  (OkAstNoDecl)
  (OkAstSomeDecl AstDecl)
  (ErrAstMaybeDecl String))

(defenum ResultAstDeclList
  (OkAstDeclList AstDeclList)
  (ErrAstDeclList String))

(defenum ResultAstMaybeExpr
  (OkAstNoExpr)
  (OkAstSomeExpr AstExpr)
  (ErrAstMaybeExpr String))

(defenum ResultCompilerCfg
  (OkCompilerCfg bool)
  (ErrCompilerCfg String))

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

(define (compiler-cfg-key [name : String]) : String
  (string-append "cfg:" name))

(define (compiler-cfg-empty) : SymI64Env
  (sym-i64-empty))

(define (compiler-cfg-enable [cfgs : SymI64Env] [name : String]) : SymI64Env
  (sym-i64-bind cfgs (compiler-cfg-key name) 1))

(define (compiler-cfg-merge [base : SymI64Env] [cfgs : SymI64Env]) : SymI64Env
  (match cfgs
    [(SymI64Nil) base]
    [(SymI64Bind name value _ _ rest)
      (sym-i64-bind (compiler-cfg-merge base (box-get rest)) name value)]))

(define (compiler-cfg-enabled? [dispatch : SymI64Env] [name : String]) : bool
  (sym-i64-contains dispatch (compiler-cfg-key name)))

(define (compiler-cfg-eval-list-all
  [dispatch : SymI64Env]
  [predicates : SpannedSexpr]) : ResultCompilerCfg
  (match predicates
    [(SpSNil _) (OkCompilerCfg true)]
    [(SpSCons head tail _)
      (match (compiler-cfg-eval dispatch (box-get head))
        [(OkCompilerCfg enabled)
          (if enabled
            (compiler-cfg-eval-list-all dispatch (box-get tail))
            (OkCompilerCfg false))]
        [(ErrCompilerCfg message) (ErrCompilerCfg message)])]
    [_ (ErrCompilerCfg "parse: cfg all expects predicates")]))

(define (compiler-cfg-eval-list-any
  [dispatch : SymI64Env]
  [predicates : SpannedSexpr]) : ResultCompilerCfg
  (match predicates
    [(SpSNil _) (OkCompilerCfg false)]
    [(SpSCons head tail _)
      (match (compiler-cfg-eval dispatch (box-get head))
        [(OkCompilerCfg enabled)
          (if enabled
            (OkCompilerCfg true)
            (compiler-cfg-eval-list-any dispatch (box-get tail)))]
        [(ErrCompilerCfg message) (ErrCompilerCfg message)])]
    [_ (ErrCompilerCfg "parse: cfg any expects predicates")]))

(define (compiler-cfg-eval-not
  [dispatch : SymI64Env]
  [predicates : SpannedSexpr]) : ResultCompilerCfg
  (match predicates
    [(SpSCons pred tail _)
      (match (box-get tail)
        [(SpSNil _)
          (match (compiler-cfg-eval dispatch (box-get pred))
            [(OkCompilerCfg enabled) (OkCompilerCfg (not enabled))]
            [(ErrCompilerCfg message) (ErrCompilerCfg message)])]
        [_ (ErrCompilerCfg "parse: cfg not expects exactly one predicate")])]
    [_ (ErrCompilerCfg "parse: cfg not expects exactly one predicate")]))

(define (compiler-cfg-eval [dispatch : SymI64Env] [predicate : SpannedSexpr]) : ResultCompilerCfg
  (match predicate
    [(SpSSym name _) (OkCompilerCfg (compiler-cfg-enabled? dispatch name))]
    [(SpSCons head predicates _)
      (match (box-get head)
        [(SpSSym op _)
          (cond
            [(string-eq op "all")
              (compiler-cfg-eval-list-all dispatch (box-get predicates))]
            [(string-eq op "any")
              (compiler-cfg-eval-list-any dispatch (box-get predicates))]
            [(string-eq op "not")
              (compiler-cfg-eval-not dispatch (box-get predicates))]
            [else
              (ErrCompilerCfg
                "parse: cfg predicate expects a name, all, any, or not")])]
        [_ (ErrCompilerCfg "parse: malformed cfg predicate")])]
    [_ (ErrCompilerCfg "parse: malformed cfg predicate")]))

(define (compiler-parse-abstraction-policy-message) : String
  "parse: TypeLisp does not support source-level generics or traits; use comptime-decl and comptime-generated concrete declarations instead (#893/#913/#970/#902)")

(define (compiler-parse-generic-type-policy-message [name : String]) : String
  (string-append
    "parse: unknown type constructor "
    (string-append
      name
      "; TypeLisp has no source-level generic type constructors; use comptime-decl and comptime-generated concrete declarations instead (#893/#913/#970/#902)")))

(define (compiler-parse-policy-form? [name : String]) : bool
  (cond
    [(string-eq name "defgeneric") true]
    [(string-eq name "generic") true]
    [(string-eq name "deftrait") true]
    [(string-eq name "trait") true]
    [(string-eq name "interface") true]
    [(string-eq name "impl") true]
    [else (string-eq name "where")]))

(define (ast-source-span-from-source-span [span : SourceSpan]) : AstSourceSpan
  (AstSourceSpan
    (span-start-line span)
    (span-start-col span)
    (span-end-line span)
    (span-end-col span)))

(define (ast-expr-wrap-span [expr : AstExpr] [s : SpannedSexpr]) : AstExpr
  (ast-expr-spanned
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

(define (compiler-parse-tag-ty-str) : i64
  116)

(define (compiler-parse-tag-unit) : i64
  113)

(define (compiler-parse-tag-ty-never) : i64
  114)

(define (compiler-parse-tag-ty-expr) : i64
  115)

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

(define (compiler-parse-tag-ty-box) : i64
  138)

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

(define (compiler-parse-tag-expr-array-push) : i64
  262)

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

(define (compiler-parse-tag-expr-return) : i64
  270)

(define (compiler-parse-tag-expr-when) : i64
  271)

(define (compiler-parse-tag-expr-unless) : i64
  272)

(define (compiler-parse-tag-expr-ptr-null) : i64
  252)

(define (compiler-parse-tag-expr-ptr-null-check) : i64
  253)

(define (compiler-parse-tag-expr-with-resource) : i64
  255)

(define (compiler-parse-tag-expr-ptr-read) : i64
  256)

(define (compiler-parse-tag-expr-ptr-write) : i64
  257)

(define (compiler-parse-tag-expr-ptr-offset) : i64
  258)

(define (compiler-parse-tag-expr-ptr-cast) : i64
  259)

(define (compiler-parse-tag-expr-ptr-to-int) : i64
  260)

(define (compiler-parse-tag-expr-int-to-ptr) : i64
  261)

(define (compiler-parse-tag-expr-box) : i64
  263)

(define (compiler-parse-tag-expr-box-get) : i64
  264)

(define (compiler-parse-tag-expr-string-data) : i64
  276)

(define (compiler-parse-tag-expr-string-from-bytes) : i64
  277)

(define (compiler-parse-tag-expr-array-data) : i64
  278)

(define (compiler-parse-tag-expr-program-argc) : i64
  279)

(define (compiler-parse-tag-expr-program-argv) : i64
  280)

(define (compiler-parse-tag-expr-program-envp) : i64
  281)

(define (compiler-parse-tag-expr-cpuid-eax) : i64
  282)

(define (compiler-parse-tag-expr-cpuid-ebx) : i64
  283)

(define (compiler-parse-tag-expr-cpuid-ecx) : i64
  284)

(define (compiler-parse-tag-expr-cpuid-edx) : i64
  285)

(define (compiler-parse-tag-expr-xgetbv) : i64
  286)

(define (compiler-parse-tag-expr-quote) : i64
  265)

(define (compiler-parse-tag-expr-quasiquote) : i64
  266)

(define (compiler-parse-tag-expr-unquote) : i64
  267)

(define (compiler-parse-tag-expr-unquote-splicing) : i64
  268)

(define (compiler-parse-tag-expr-with-escape) : i64
  269)

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

(define (compiler-parse-tag-decl-defmacro) : i64
  408)

(define (compiler-parse-tag-decl-export) : i64
  409)

(define (compiler-parse-tag-decl-include-str) : i64
  410)

(define (compiler-parse-tag-decl-defdispatch) : i64
  411)

(define (compiler-parse-dispatch-binops [e : SymI64Env]) : SymI64Env
  (let
    [e1 : SymI64Env (sym-i64-bind e "+" (compiler-parse-tag-bin-add))]
    [e2 : SymI64Env (sym-i64-bind e1 "-" (compiler-parse-tag-bin-sub))]
    [e3 : SymI64Env (sym-i64-bind e2 "*" (compiler-parse-tag-bin-mul))]
    [e4 : SymI64Env (sym-i64-bind e3 "/" (compiler-parse-tag-bin-div))]
    [e5 : SymI64Env (sym-i64-bind e4 "%" (compiler-parse-tag-bin-mod))]
    [e6 : SymI64Env (sym-i64-bind e5 "=" (compiler-parse-tag-bin-eq))]
    [e7 : SymI64Env (sym-i64-bind e6 "!=" (compiler-parse-tag-bin-ne))]
    [e8 : SymI64Env (sym-i64-bind e7 "<" (compiler-parse-tag-bin-lt))]
    [e9 : SymI64Env (sym-i64-bind e8 "<=" (compiler-parse-tag-bin-le))]
    [e10 : SymI64Env (sym-i64-bind e9 ">" (compiler-parse-tag-bin-gt))]
    [e11 : SymI64Env (sym-i64-bind e10 ">=" (compiler-parse-tag-bin-ge))]
    [e12 : SymI64Env (sym-i64-bind e11 "and" (compiler-parse-tag-bin-and))]
    [e13 : SymI64Env (sym-i64-bind e12 "or" (compiler-parse-tag-bin-or))]
    [e14 : SymI64Env
      (sym-i64-bind e13 "bit-and" (compiler-parse-tag-bin-bit-and))]
    [e15 : SymI64Env
      (sym-i64-bind e14 "bit-or" (compiler-parse-tag-bin-bit-or))]
    [e16 : SymI64Env
      (sym-i64-bind e15 "bit-xor" (compiler-parse-tag-bin-bit-xor))]
    [e17 : SymI64Env (sym-i64-bind e16 "shl" (compiler-parse-tag-bin-shl))]
    (sym-i64-bind e17 "shr" (compiler-parse-tag-bin-shr))))

(define (compiler-parse-dispatch-unops [e : SymI64Env]) : SymI64Env
  (let
    [e1 : SymI64Env (sym-i64-bind e "not" (compiler-parse-tag-un-not))]
    [e2 : SymI64Env (sym-i64-bind e1 "neg" (compiler-parse-tag-un-neg))]
    (sym-i64-bind e2 "bit-not" (compiler-parse-tag-un-bit-not))))

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
      (set! out (sym-i64-bind out "str" (compiler-parse-tag-ty-str)))
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
      (set! out (sym-i64-bind out "Box" (compiler-parse-tag-ty-box)))
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
      (set!
        out
        (sym-i64-bind out "array-push!" (compiler-parse-tag-expr-array-push)))
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
        (sym-i64-bind out "with-escape" (compiler-parse-tag-expr-with-escape)))
      (set!
        out
        (sym-i64-bind out "type" (compiler-parse-tag-expr-type-literal)))
      (set! out (sym-i64-bind out "try" (compiler-parse-tag-expr-try)))
      (set! out (sym-i64-bind out "return" (compiler-parse-tag-expr-return)))
      (set!
        out
        (sym-i64-bind out "ptr-null" (compiler-parse-tag-expr-ptr-null)))
      (set!
        out
        (sym-i64-bind out "ptr-null?" (compiler-parse-tag-expr-ptr-null-check)))
      (set!
        out
        (sym-i64-bind out "ptr-read" (compiler-parse-tag-expr-ptr-read)))
      (set!
        out
        (sym-i64-bind out "ptr-write!" (compiler-parse-tag-expr-ptr-write)))
      (set!
        out
        (sym-i64-bind out "ptr-offset" (compiler-parse-tag-expr-ptr-offset)))
      (set!
        out
        (sym-i64-bind out "ptr-cast" (compiler-parse-tag-expr-ptr-cast)))
      (set!
        out
        (sym-i64-bind out "ptr->int" (compiler-parse-tag-expr-ptr-to-int)))
      (set!
        out
        (sym-i64-bind out "int->ptr" (compiler-parse-tag-expr-int-to-ptr)))
      (set! out (sym-i64-bind out "box" (compiler-parse-tag-expr-box)))
      (set! out (sym-i64-bind out "box-get" (compiler-parse-tag-expr-box-get)))
      (set!
        out
        (sym-i64-bind out "string-data" (compiler-parse-tag-expr-string-data)))
      (set!
        out
        (sym-i64-bind
          out
          "string-from-bytes"
          (compiler-parse-tag-expr-string-from-bytes)))
      (set!
        out
        (sym-i64-bind out "array-data" (compiler-parse-tag-expr-array-data)))
      (set!
        out
        (sym-i64-bind out "program-argc" (compiler-parse-tag-expr-program-argc)))
      (set!
        out
        (sym-i64-bind out "program-argv" (compiler-parse-tag-expr-program-argv)))
      (set!
        out
        (sym-i64-bind out "program-envp" (compiler-parse-tag-expr-program-envp)))
      (set!
        out
        (sym-i64-bind out "cpuid-eax" (compiler-parse-tag-expr-cpuid-eax)))
      (set!
        out
        (sym-i64-bind out "cpuid-ebx" (compiler-parse-tag-expr-cpuid-ebx)))
      (set!
        out
        (sym-i64-bind out "cpuid-ecx" (compiler-parse-tag-expr-cpuid-ecx)))
      (set!
        out
        (sym-i64-bind out "cpuid-edx" (compiler-parse-tag-expr-cpuid-edx)))
      (set! out (sym-i64-bind out "xgetbv" (compiler-parse-tag-expr-xgetbv)))
      (set!
        out
        (sym-i64-bind out "with" (compiler-parse-tag-expr-with-resource)))
      (set! out (sym-i64-bind out "quote" (compiler-parse-tag-expr-quote)))
      (set!
        out
        (sym-i64-bind out "quasiquote" (compiler-parse-tag-expr-quasiquote)))
      (set! out (sym-i64-bind out "unquote" (compiler-parse-tag-expr-unquote)))
      (set!
        out
        (sym-i64-bind
          out
          "unquote-splicing"
          (compiler-parse-tag-expr-unquote-splicing)))
      out)))

(define (compiler-parse-dispatch-patterns [e : SymI64Env]) : SymI64Env
  (let
    [e1 : SymI64Env (sym-i64-bind e "true" (compiler-parse-tag-lit-true))]
    [e2 : SymI64Env (sym-i64-bind e1 "false" (compiler-parse-tag-lit-false))]
    (sym-i64-bind e2 "_" (compiler-parse-tag-pattern-wildcard))))

(define (compiler-parse-dispatch-decls [e : SymI64Env]) : SymI64Env
  (let
    [e1 : SymI64Env (sym-i64-bind e "define" (compiler-parse-tag-decl-define))]
    [e2 : SymI64Env (sym-i64-bind e1 "extern" (compiler-parse-tag-decl-extern))]
    [e3 : SymI64Env
      (sym-i64-bind e2 "defenum" (compiler-parse-tag-decl-defenum))]
    [e4 : SymI64Env
      (sym-i64-bind e3 "defstruct" (compiler-parse-tag-decl-defstruct))]
    [e5 : SymI64Env (sym-i64-bind e4 "import" (compiler-parse-tag-decl-import))]
    [e6 : SymI64Env
      (sym-i64-bind e5 "comptime-decl" (compiler-parse-tag-decl-comptime-decl))]
    [e7 : SymI64Env (sym-i64-bind e6 "module" (compiler-parse-tag-decl-module))]
    [e8 : SymI64Env (sym-i64-bind e7 "test" (compiler-parse-tag-decl-test))]
    [e9 : SymI64Env
      (sym-i64-bind e8 "defmacro" (compiler-parse-tag-decl-defmacro))]
    [e10 : SymI64Env
      (sym-i64-bind e9 "export" (compiler-parse-tag-decl-export))]
    [e11 : SymI64Env
      (sym-i64-bind e10 "include-str" (compiler-parse-tag-decl-include-str))]
    (sym-i64-bind e11 "defdispatch" (compiler-parse-tag-decl-defdispatch))))

(define (compiler-parse-dispatch-env) : SymI64Env
  (compiler-parse-dispatch-decls
    (compiler-parse-dispatch-patterns
      (compiler-parse-dispatch-exprs
        (compiler-parse-dispatch-types
          (compiler-parse-dispatch-unops
            (compiler-parse-dispatch-binops (sym-i64-empty))))))))

(define (compiler-parse-dispatch-tag [dispatch : SymI64Env] [name : String]) : i64
  (let
    [n : i64 (string-length name)]
    (cond
      [(= n 1)
        (cond
          [(string-eq name "+") (compiler-parse-tag-bin-add)]
          [(string-eq name "-") (compiler-parse-tag-bin-sub)]
          [(string-eq name "*") (compiler-parse-tag-bin-mul)]
          [(string-eq name "/") (compiler-parse-tag-bin-div)]
          [(string-eq name "%") (compiler-parse-tag-bin-mod)]
          [(string-eq name "=") (compiler-parse-tag-bin-eq)]
          [(string-eq name "<") (compiler-parse-tag-bin-lt)]
          [(string-eq name ">") (compiler-parse-tag-bin-gt)]
          [(string-eq name "&") (compiler-parse-tag-ty-ref)]
          [(string-eq name "_") (compiler-parse-tag-pattern-wildcard)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 2)
        (cond
          [(string-eq name "!=") (compiler-parse-tag-bin-ne)]
          [(string-eq name "<=") (compiler-parse-tag-bin-le)]
          [(string-eq name ">=") (compiler-parse-tag-bin-ge)]
          [(string-eq name "or") (compiler-parse-tag-bin-or)]
          [(string-eq name "i8") (compiler-parse-tag-ty-i8)]
          [(string-eq name "u8") (compiler-parse-tag-ty-u8)]
          [(string-eq name "->") (compiler-parse-tag-ty-func)]
          [(string-eq name "in") (compiler-parse-tag-ty-region)]
          [(string-eq name "if") (compiler-parse-tag-expr-if)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 3)
        (cond
          [(string-eq name "and") (compiler-parse-tag-bin-and)]
          [(string-eq name "shl") (compiler-parse-tag-bin-shl)]
          [(string-eq name "shr") (compiler-parse-tag-bin-shr)]
          [(string-eq name "not") (compiler-parse-tag-un-not)]
          [(string-eq name "neg") (compiler-parse-tag-un-neg)]
          [(string-eq name "i64") (compiler-parse-tag-ty-i64)]
          [(string-eq name "i32") (compiler-parse-tag-ty-i32)]
          [(string-eq name "i16") (compiler-parse-tag-ty-i16)]
          [(string-eq name "u64") (compiler-parse-tag-ty-u64)]
          [(string-eq name "u32") (compiler-parse-tag-ty-u32)]
          [(string-eq name "u16") (compiler-parse-tag-ty-u16)]
          [(string-eq name "f64") (compiler-parse-tag-ty-f64)]
          [(string-eq name "f32") (compiler-parse-tag-ty-f32)]
          [(string-eq name "str") (compiler-parse-tag-ty-str)]
          [(string-eq name "Ptr") (compiler-parse-tag-ty-ptr)]
          [(string-eq name "Box") (compiler-parse-tag-ty-box)]
          [(string-eq name "let") (compiler-parse-tag-expr-let)]
          [(string-eq name "ann") (compiler-parse-tag-expr-ann)]
          [(string-eq name "try") (compiler-parse-tag-expr-try)]
          [(string-eq name "box") (compiler-parse-tag-expr-box)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 4)
        (cond
          [(string-eq name "bool") (compiler-parse-tag-ty-bool)]
          [(string-eq name "char") (compiler-parse-tag-ty-char)]
          [(string-eq name "unit") (compiler-parse-tag-unit)]
          [(string-eq name "&mut") (compiler-parse-tag-ty-mut-ref)]
          [(string-eq name "set!") (compiler-parse-tag-expr-set)]
          [(string-eq name "cast") (compiler-parse-tag-expr-cast)]
          [(string-eq name "cond") (compiler-parse-tag-expr-cond)]
          [(string-eq name "type") (compiler-parse-tag-expr-type-literal)]
          [(string-eq name "with") (compiler-parse-tag-expr-with-resource)]
          [(string-eq name "true") (compiler-parse-tag-lit-true)]
          [(string-eq name "test") (compiler-parse-tag-decl-test)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 5)
        (cond
          [(string-eq name "never") (compiler-parse-tag-ty-never)]
          [(string-eq name "Tuple") (compiler-parse-tag-ty-tuple)]
          [(string-eq name "Array") (compiler-parse-tag-ty-array)]
          [(string-eq name "while") (compiler-parse-tag-expr-while)]
          [(string-eq name "begin") (compiler-parse-tag-expr-begin)]
          [(string-eq name "tuple") (compiler-parse-tag-expr-tuple)]
          [(string-eq name "array") (compiler-parse-tag-expr-array)]
          [(string-eq name "match") (compiler-parse-tag-expr-match)]
          [(string-eq name "quote") (compiler-parse-tag-expr-quote)]
          [(string-eq name "false") (compiler-parse-tag-lit-false)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 6)
        (cond
          [(string-eq name "bit-or") (compiler-parse-tag-bin-bit-or)]
          [(string-eq name "String") (compiler-parse-tag-ty-string)]
          [(string-eq name "MutPtr") (compiler-parse-tag-ty-mut-ptr)]
          [(string-eq name "lambda") (compiler-parse-tag-expr-lambda)]
          [(string-eq name "unsafe") (compiler-parse-tag-expr-unsafe)]
          [(string-eq name "return") (compiler-parse-tag-expr-return)]
          [(string-eq name "xgetbv") (compiler-parse-tag-expr-xgetbv)]
          [(string-eq name "define") (compiler-parse-tag-decl-define)]
          [(string-eq name "extern") (compiler-parse-tag-decl-extern)]
          [(string-eq name "import") (compiler-parse-tag-decl-import)]
          [(string-eq name "module") (compiler-parse-tag-decl-module)]
          [(string-eq name "export") (compiler-parse-tag-decl-export)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 7)
        (cond
          [(string-eq name "bit-and") (compiler-parse-tag-bin-bit-and)]
          [(string-eq name "bit-xor") (compiler-parse-tag-bin-bit-xor)]
          [(string-eq name "bit-not") (compiler-parse-tag-un-bit-not)]
          [(string-eq name "foreach") (compiler-parse-tag-expr-foreach)]
          [(string-eq name "box-get") (compiler-parse-tag-expr-box-get)]
          [(string-eq name "unquote") (compiler-parse-tag-expr-unquote)]
          [(string-eq name "defenum") (compiler-parse-tag-decl-defenum)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 8)
        (cond
          [(string-eq name "comptime") (compiler-parse-tag-expr-comptime)]
          [(string-eq name "ptr-null") (compiler-parse-tag-expr-ptr-null)]
          [(string-eq name "ptr-read") (compiler-parse-tag-expr-ptr-read)]
          [(string-eq name "ptr-cast") (compiler-parse-tag-expr-ptr-cast)]
          [(string-eq name "ptr->int") (compiler-parse-tag-expr-ptr-to-int)]
          [(string-eq name "int->ptr") (compiler-parse-tag-expr-int-to-ptr)]
          [(string-eq name "defmacro") (compiler-parse-tag-decl-defmacro)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 9)
        (cond
          [(string-eq name "tuple-ref") (compiler-parse-tag-expr-tuple-ref)]
          [(string-eq name "array-ref") (compiler-parse-tag-expr-array-ref)]
          [(string-eq name "ptr-null?")
            (compiler-parse-tag-expr-ptr-null-check)]
          [(string-eq name "cpuid-eax") (compiler-parse-tag-expr-cpuid-eax)]
          [(string-eq name "cpuid-ebx") (compiler-parse-tag-expr-cpuid-ebx)]
          [(string-eq name "cpuid-ecx") (compiler-parse-tag-expr-cpuid-ecx)]
          [(string-eq name "cpuid-edx") (compiler-parse-tag-expr-cpuid-edx)]
          [(string-eq name "defstruct") (compiler-parse-tag-decl-defstruct)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 10)
        (cond
          [(string-eq name "make-array") (compiler-parse-tag-expr-make-array)]
          [(string-eq name "array-set!") (compiler-parse-tag-expr-array-set)]
          [(string-eq name "array-data") (compiler-parse-tag-expr-array-data)]
          [(string-eq name "struct-get") (compiler-parse-tag-expr-struct-get)]
          [(string-eq name "with-arena") (compiler-parse-tag-expr-with-region)]
          [(string-eq name "ptr-write!") (compiler-parse-tag-expr-ptr-write)]
          [(string-eq name "ptr-offset") (compiler-parse-tag-expr-ptr-offset)]
          [(string-eq name "quasiquote") (compiler-parse-tag-expr-quasiquote)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 11)
        (cond
          [(string-eq name "array-push!") (compiler-parse-tag-expr-array-push)]
          [(string-eq name "spmd-reduce") (compiler-parse-tag-expr-spmd-reduce)]
          [(string-eq name "with-escape") (compiler-parse-tag-expr-with-escape)]
          [(string-eq name "string-data") (compiler-parse-tag-expr-string-data)]
          [(string-eq name "include-str") (compiler-parse-tag-decl-include-str)]
          [(string-eq name "defdispatch") (compiler-parse-tag-decl-defdispatch)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 12)
        (cond
          [(string-eq name "program-argc")
            (compiler-parse-tag-expr-program-argc)]
          [(string-eq name "program-argv")
            (compiler-parse-tag-expr-program-argv)]
          [(string-eq name "program-envp")
            (compiler-parse-tag-expr-program-envp)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 13)
        (cond
          [(string-eq name "comptime-decl")
            (compiler-parse-tag-decl-comptime-decl)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 16)
        (cond
          [(string-eq name "unquote-splicing")
            (compiler-parse-tag-expr-unquote-splicing)]
          [else (compiler-parse-tag-unknown)])]
      [(= n 17)
        (cond
          [(string-eq name "string-from-bytes")
            (compiler-parse-tag-expr-string-from-bytes)]
          [else (compiler-parse-tag-unknown)])]
      [else (compiler-parse-tag-unknown)])))

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

(define (compiler-parse-and-or-binop-tag? [tag : i64]) : bool
  (or (= tag (compiler-parse-tag-bin-and)) (= tag (compiler-parse-tag-bin-or))))

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
      (match (parse-ast-type dispatch (box-get head))
        [(OkAstType parsed-head)
          (match (parse-ast-type-list dispatch (box-get tail))
            [(OkAstTypeList parsed-tail)
              (OkAstTypeList (ast-type-cons parsed-head parsed-tail))]
            [(ErrAstTypeList message) (ErrAstTypeList message)])]
        [(ErrAstType message) (ErrAstTypeList message)])]
    [_ (ErrAstTypeList "parse: malformed type list")]))

(define (parse-ast-lifetime-name? [dispatch : SymI64Env] [name : String]) : bool
  (let
    [tag : i64 (compiler-parse-dispatch-tag dispatch name)]
    (not
      (or
        (and
          (>= tag (compiler-parse-tag-ty-i64))
          (<= tag (compiler-parse-tag-ty-str)))
        (and
          (>= tag (compiler-parse-tag-ty-func))
          (<= tag (compiler-parse-tag-ty-box)))))))

(define (parse-ast-lifetime-list
  [dispatch : SymI64Env]
  [s : Sexpr]
  [message : String]) : ResultAstLifetimeList
  (match s
    [(SNil) (OkAstLifetimeList AstLifetimeNil)]
    [(SCons head tail)
      (match (box-get head)
        [(SSym name)
          (if (parse-ast-lifetime-name? dispatch name)
            (match (parse-ast-lifetime-list dispatch (box-get tail) message)
              [(OkAstLifetimeList parsed-tail)
                (OkAstLifetimeList (ast-lifetime-cons name parsed-tail))]
              [(ErrAstLifetimeList parse-message)
                (ErrAstLifetimeList parse-message)])
            (ErrAstLifetimeList message))]
        [_ (ErrAstLifetimeList message)])]
    [(SCons _ _) (ErrAstLifetimeList message)]
    [_ (ErrAstLifetimeList message)]))

(define (parse-ast-lifetime-list-nonempty
  [dispatch : SymI64Env]
  [s : Sexpr]
  [message : String]) : ResultAstLifetimeList
  (match s
    [(SNil) (ErrAstLifetimeList message)]
    [_ (parse-ast-lifetime-list dispatch s message)]))

(define (parse-ast-func-type-parts [dispatch : SymI64Env] [s : Sexpr]) : ResultAstFuncTypeParts
  (match s
    [(SCons arg rest)
      (match (box-get rest)
        [(SNil)
          (match (parse-ast-type dispatch (box-get arg))
            [(OkAstType parsed-ret) (OkAstFuncTypeParts AstTypeNil parsed-ret)]
            [(ErrAstType message) (ErrAstFuncTypeParts message)])]
        [_
          (match (parse-ast-type dispatch (box-get arg))
            [(OkAstType parsed-arg)
              (match (parse-ast-func-type-parts dispatch (box-get rest))
                [(OkAstFuncTypeParts parsed-args parsed-ret)
                  (OkAstFuncTypeParts
                    (ast-type-cons parsed-arg parsed-args)
                    parsed-ret)]
                [(ErrAstFuncTypeParts message) (ErrAstFuncTypeParts message)])]
            [(ErrAstType message) (ErrAstFuncTypeParts message)])])]
    [_ (ErrAstFuncTypeParts "parse: function type needs at least return type")]))

(define (parse-ast-reference-type
  [dispatch : SymI64Env]
  [rest : Sexpr]
  [mutable : bool]) : ResultAstType
  (match rest
    [(SCons region-node tail)
      (match (box-get tail)
        [(SCons inner end)
          (match (box-get end)
            [(SNil)
              (match (box-get region-node)
                [(SSym region)
                  (match (parse-ast-type dispatch (box-get inner))
                    [(OkAstType inner-ty)
                      (if mutable
                        (OkAstType (ast-ty-mut-ref region inner-ty))
                        (OkAstType (ast-ty-ref region inner-ty)))]
                    [(ErrAstType message) (ErrAstType message)])]
                [_
                  (ErrAstType "parse: reference lifetime must be an identifier")])]
            [_
              (ErrAstType
                (if mutable
                  "parse: &mut expects lifetime and exactly one type"
                  "parse: & expects lifetime and exactly one type"))])]
        [_
          (ErrAstType
            (if mutable
              "parse: &mut expects lifetime and exactly one type"
              "parse: & expects lifetime and exactly one type"))])]
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
        (cond
          [(= tag (compiler-parse-tag-ty-i64)) (OkAstType (AstTyI64))]
          [(= tag (compiler-parse-tag-ty-i32)) (OkAstType (AstTyI32))]
          [(= tag (compiler-parse-tag-ty-i16)) (OkAstType (AstTyI16))]
          [(= tag (compiler-parse-tag-ty-i8)) (OkAstType (AstTyI8))]
          [(= tag (compiler-parse-tag-ty-u64)) (OkAstType (AstTyU64))]
          [(= tag (compiler-parse-tag-ty-u32)) (OkAstType (AstTyU32))]
          [(= tag (compiler-parse-tag-ty-u16)) (OkAstType (AstTyU16))]
          [(= tag (compiler-parse-tag-ty-u8)) (OkAstType (AstTyU8))]
          [(= tag (compiler-parse-tag-ty-f64)) (OkAstType (AstTyF64))]
          [(= tag (compiler-parse-tag-ty-f32)) (OkAstType (AstTyF32))]
          [(= tag (compiler-parse-tag-ty-bool)) (OkAstType (AstTyBool))]
          [(= tag (compiler-parse-tag-ty-char)) (OkAstType (AstTyChar))]
          [(= tag (compiler-parse-tag-ty-string)) (OkAstType (AstTyString))]
          [(= tag (compiler-parse-tag-ty-str)) (OkAstType (AstTyStr))]
          [(= tag (compiler-parse-tag-unit)) (OkAstType (AstTyUnit))]
          [(= tag (compiler-parse-tag-ty-never)) (OkAstType (AstTyNever))]
          [(= tag (compiler-parse-tag-ty-expr)) (OkAstType (AstTyExpr))]
          [else (OkAstType (AstTyVar name))]))]
    [(SCons head-node rest-box)
      (match (box-get head-node)
        [(SSym head)
          (let
            [rest : Sexpr (box-get rest-box)]
            [tag : i64 (compiler-parse-dispatch-tag dispatch head)]
            (cond
              [(= tag (compiler-parse-tag-ty-func))
                (match (parse-ast-func-type-parts dispatch rest)
                  [(OkAstFuncTypeParts args ret)
                    (OkAstType (ast-ty-func args ret))]
                  [(ErrAstFuncTypeParts message) (ErrAstType message)])]
              [(= tag (compiler-parse-tag-ty-tuple))
                (match (parse-ast-type-list dispatch rest)
                  [(OkAstTypeList elems) (OkAstType (AstTyTuple elems))]
                  [(ErrAstTypeList message) (ErrAstType message)])]
              [(= tag (compiler-parse-tag-ty-array))
                (match rest
                  [(SCons elem tail)
                    (match (box-get tail)
                      [(SNil)
                        (match (parse-ast-type dispatch (box-get elem))
                          [(OkAstType elem-ty)
                            (OkAstType (ast-ty-dyn-array elem-ty))]
                          [(ErrAstType message) (ErrAstType message)])]
                      [(SCons size-node end)
                        (match (box-get end)
                          [(SNil)
                            (match (box-get size-node)
                              [(SInt size)
                                (match (parse-ast-type dispatch (box-get elem))
                                  [(OkAstType elem-ty)
                                    (OkAstType (ast-ty-array elem-ty size))]
                                  [(ErrAstType message) (ErrAstType message)])]
                              [_
                                (ErrAstType "parse: array size must be integer")])]
                          [_ (ErrAstType "parse: malformed array type")])]
                      [_ (ErrAstType "parse: malformed array type")])]
                  [_ (ErrAstType "parse: malformed array type")])]
              [(= tag (compiler-parse-tag-ty-ptr))
                (match rest
                  [(SCons elem tail)
                    (match (box-get tail)
                      [(SNil)
                        (match (parse-ast-type dispatch (box-get elem))
                          [(OkAstType elem-ty) (OkAstType (ast-ty-ptr elem-ty))]
                          [(ErrAstType message) (ErrAstType message)])]
                      [_ (ErrAstType "parse: Ptr expects exactly one type")])]
                  [_ (ErrAstType "parse: Ptr expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-mut-ptr))
                (match rest
                  [(SCons elem tail)
                    (match (box-get tail)
                      [(SNil)
                        (match (parse-ast-type dispatch (box-get elem))
                          [(OkAstType elem-ty)
                            (OkAstType (ast-ty-mut-ptr elem-ty))]
                          [(ErrAstType message) (ErrAstType message)])]
                      [_ (ErrAstType "parse: MutPtr expects exactly one type")])]
                  [_ (ErrAstType "parse: MutPtr expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-box))
                (match rest
                  [(SCons elem tail)
                    (match (box-get tail)
                      [(SNil)
                        (match (parse-ast-type dispatch (box-get elem))
                          [(OkAstType elem-ty) (OkAstType (ast-ty-box elem-ty))]
                          [(ErrAstType message) (ErrAstType message)])]
                      [_ (ErrAstType "parse: Box expects exactly one type")])]
                  [_ (ErrAstType "parse: Box expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-ref))
                (parse-ast-reference-type dispatch rest false)]
              [(= tag (compiler-parse-tag-ty-mut-ref))
                (parse-ast-reference-type dispatch rest true)]
              [(= tag (compiler-parse-tag-ty-region))
                (match rest
                  [(SCons region-node tail)
                    (match (box-get tail)
                      [(SCons inner end)
                        (match (box-get end)
                          [(SNil)
                            (match (box-get region-node)
                              [(SSym region)
                                (match (parse-ast-type dispatch (box-get inner))
                                  [(OkAstType inner-ty)
                                    (OkAstType (ast-ty-region region inner-ty))]
                                  [(ErrAstType message) (ErrAstType message)])]
                              [_
                                (ErrAstType
                                  "parse: region name must be an identifier")])]
                          [_ (ErrAstType "parse: malformed region type")])]
                      [_ (ErrAstType "parse: malformed region type")])]
                  [_ (ErrAstType "parse: malformed region type")])]
              [else
                (match (parse-ast-lifetime-list-nonempty
                  dispatch
                  rest
                  (compiler-parse-generic-type-policy-message head))
                  [(OkAstLifetimeList lifetimes)
                    (OkAstType (AstTyVarArgs head lifetimes))]
                  [(ErrAstLifetimeList message) (ErrAstType message)])]))]
        [_ (ErrAstType "parse: expected type")])]
    [_ (ErrAstType "parse: expected type")]))

(define (parse-ast-param [dispatch : SymI64Env] [s : Sexpr]) : ResultAstParam
  (match s
    [(SCons first rest)
      (match (box-get first)
        [(SSym first-name)
          (if (string-eq first-name "comptime")
            (match (box-get rest)
              [(SCons name-node after-name)
                (match (box-get name-node)
                  [(SSym name)
                    (match (box-get after-name)
                      [(SCons colon rest2)
                        (match (box-get rest2)
                          [(SCons ty end)
                            (match (box-get end)
                              [(SNil)
                                (if (sexpr-colon? (box-get colon))
                                  (match (parse-ast-type dispatch (box-get ty))
                                    [(OkAstType parsed-ty)
                                      (OkAstParam
                                        (AstParam name parsed-ty true))]
                                    [(ErrAstType message) (ErrAstParam message)])
                                  (ErrAstParam
                                    "parse: expected ':' in parameter"))]
                              [_ (ErrAstParam "parse: malformed parameter")])]
                          [_ (ErrAstParam "parse: malformed parameter")])]
                      [_ (ErrAstParam "parse: malformed parameter")])]
                  [_ (ErrAstParam "parse: malformed parameter")])]
              [_ (ErrAstParam "parse: malformed parameter")])
            (match (box-get rest)
              [(SCons colon rest2)
                (match (box-get rest2)
                  [(SCons ty end)
                    (match (box-get end)
                      [(SNil)
                        (if (sexpr-colon? (box-get colon))
                          (match (parse-ast-type dispatch (box-get ty))
                            [(OkAstType parsed-ty)
                              (OkAstParam (AstParam first-name parsed-ty false))]
                            [(ErrAstType message) (ErrAstParam message)])
                          (ErrAstParam "parse: expected ':' in parameter"))]
                      [_ (ErrAstParam "parse: malformed parameter")])]
                  [_ (ErrAstParam "parse: malformed parameter")])]
              [_ (ErrAstParam "parse: malformed parameter")]))]
        [_ (ErrAstParam "parse: malformed parameter")])]
    [_ (ErrAstParam "parse: malformed parameter")]))

(define (ast-param-list-has-comptime? [params : AstParamList]) : bool
  (match params
    [(AstParamNil) false]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam _ _ is-comptime)
            (if is-comptime
              true
              (ast-param-list-has-comptime? rest))]))]))

(define (ast-macro-param-variadic? [param : AstMacroParam]) : bool
  (match param
    [(AstMacroParam _ _ variadic) variadic]))

(define (parse-ast-macro-param [dispatch : SymI64Env] [s : Sexpr]) : ResultAstMacroParam
  (match s
    [(SCons name-node rest)
      (match (box-get name-node)
        [(SSym name)
          (if (string-eq name "comptime")
            (ErrAstMacroParam
              "parse: defmacro operands are already compile-time")
            (match (box-get rest)
              [(SCons colon rest2)
                (match (box-get rest2)
                  [(SCons ty rest3)
                    (if (sexpr-colon? (box-get colon))
                      (match (box-get rest3)
                        [(SNil)
                          (match (parse-ast-type dispatch (box-get ty))
                            [(OkAstType parsed-ty)
                              (OkAstMacroParam
                                (AstMacroParam name parsed-ty false))]
                            [(ErrAstType message) (ErrAstMacroParam message)])]
                        [(SCons dots end)
                          (match (box-get end)
                            [(SNil)
                              (match (box-get dots)
                                [(SSym dots-name)
                                  (if (string-eq dots-name "...")
                                    (match (parse-ast-type
                                      dispatch
                                      (box-get ty))
                                      [(OkAstType parsed-ty)
                                        (OkAstMacroParam
                                          (AstMacroParam name parsed-ty true))]
                                      [(ErrAstType message)
                                        (ErrAstMacroParam message)])
                                    (ErrAstMacroParam
                                      "parse: malformed macro operand"))]
                                [_
                                  (ErrAstMacroParam
                                    "parse: malformed macro operand")])]
                            [_
                              (ErrAstMacroParam
                                "parse: malformed macro operand")])]
                        [_ (ErrAstMacroParam "parse: malformed macro operand")])
                      (ErrAstMacroParam "parse: expected ':' in macro operand"))]
                  [_ (ErrAstMacroParam "parse: malformed macro operand")])]
              [_ (ErrAstMacroParam "parse: malformed macro operand")]))]
        [_ (ErrAstMacroParam "parse: malformed macro operand")])]
    [_ (ErrAstMacroParam "parse: malformed macro operand")]))

(define (parse-ast-macro-param-list [dispatch : SymI64Env] [s : Sexpr]) : ResultAstMacroParamList
  (match s
    [(SNil) (OkAstMacroParamList AstMacroParamNil)]
    [(SCons head tail)
      (match (parse-ast-macro-param dispatch (box-get head))
        [(OkAstMacroParam parsed-head)
          (if (ast-macro-param-variadic? parsed-head)
            (match (box-get tail)
              [(SNil)
                (OkAstMacroParamList
                  (ast-macro-param-cons parsed-head AstMacroParamNil))]
              [_
                (ErrAstMacroParamList
                  "parse: variadic macro operand must be final")])
            (match (parse-ast-macro-param-list dispatch (box-get tail))
              [(OkAstMacroParamList parsed-tail)
                (OkAstMacroParamList
                  (ast-macro-param-cons parsed-head parsed-tail))]
              [(ErrAstMacroParamList message) (ErrAstMacroParamList message)]))]
        [(ErrAstMacroParam message) (ErrAstMacroParamList message)])]
    [_ (ErrAstMacroParamList "parse: malformed macro operand list")]))

(define (parse-ast-param-list [dispatch : SymI64Env] [s : Sexpr]) : ResultAstParamList
  (match s
    [(SNil) (OkAstParamList AstParamNil)]
    [(SCons head tail)
      (match (parse-ast-param dispatch (box-get head))
        [(OkAstParam parsed-head)
          (match (parse-ast-param-list dispatch (box-get tail))
            [(OkAstParamList parsed-tail)
              (OkAstParamList (ast-param-cons parsed-head parsed-tail))]
            [(ErrAstParamList message) (ErrAstParamList message)])]
        [(ErrAstParam message) (ErrAstParamList message)])]
    [_ (ErrAstParamList "parse: malformed parameter list")]))

(define (parse-ast-field-cleanup [s : Sexpr]) : ResultAstFieldCleanup
  (match s
    [(SCons key-node tail)
      (match (box-get key-node)
        [(SSym key)
          (cond
            [(string-eq key ":cleanup")
              (match (box-get tail)
                [(SCons cleanup-node end)
                  (match (box-get end)
                    [(SNil)
                      (match (box-get cleanup-node)
                        [(SSym cleanup-fn)
                          (OkAstFieldCleanup (AstFieldCleanupFn cleanup-fn))]
                        [_
                          (ErrAstFieldCleanup
                            "parse: malformed field :cleanup metadata")])]
                    [_
                      (ErrAstFieldCleanup
                        "parse: malformed field :cleanup metadata")])]
                [_
                  (ErrAstFieldCleanup
                    "parse: malformed field :cleanup metadata")])]
            [(string-eq key ":owned")
              (match (box-get tail)
                [(SNil) (OkAstFieldCleanup (AstFieldOwnedCleanup))]
                [_
                  (ErrAstFieldCleanup "parse: malformed field :owned metadata")])]
            [(compiler-parse-metadata-key? key)
              (ErrAstFieldCleanup
                (string-append "parse: unknown field metadata " key))]
            [else
              (ErrAstFieldCleanup "parse: malformed field cleanup metadata")])]
        [_ (ErrAstFieldCleanup "parse: malformed field cleanup metadata")])]
    [_ (ErrAstFieldCleanup "parse: malformed field cleanup metadata")]))

(define (parse-ast-field-def
  [dispatch : SymI64Env]
  [s : Sexpr]
  [allow-cleanup : bool]) : ResultAstFieldDef
  (match s
    [(SCons name-node tail)
      (match (box-get name-node)
        [(SSym name)
          (match (box-get tail)
            [(SCons ty rest)
              (match (box-get rest)
                [(SNil)
                  (match (parse-ast-type dispatch (box-get ty))
                    [(OkAstType parsed-ty)
                      (OkAstFieldDef
                        (AstFieldDef name parsed-ty (AstFieldNoCleanup)))]
                    [(ErrAstType message) (ErrAstFieldDef message)])]
                [(SCons cleanup-meta extra)
                  (match (box-get extra)
                    [(SNil)
                      (if allow-cleanup
                        (match (parse-ast-type dispatch (box-get ty))
                          [(OkAstType parsed-ty)
                            (match (parse-ast-field-cleanup
                              (box-get cleanup-meta))
                              [(OkAstFieldCleanup parsed-cleanup)
                                (OkAstFieldDef
                                  (AstFieldDef name parsed-ty parsed-cleanup))]
                              [(ErrAstFieldCleanup message)
                                (ErrAstFieldDef message)])]
                          [(ErrAstType message) (ErrAstFieldDef message)])
                        (ErrAstFieldDef
                          "parse: field cleanup metadata requires struct :cleanup metadata"))]
                    [_
                      (ErrAstFieldDef "parse: duplicate field cleanup metadata")])]
                [_ (ErrAstFieldDef "parse: malformed field definition")])]
            [_ (ErrAstFieldDef "parse: malformed field definition")])]
        [_ (ErrAstFieldDef "parse: malformed field definition")])]
    [_ (ErrAstFieldDef "parse: malformed field definition")]))

(define (parse-ast-field-def-list
  [dispatch : SymI64Env]
  [s : Sexpr]
  [allow-cleanup : bool]) : ResultAstFieldDefList
  (match s
    [(SNil) (OkAstFieldDefList AstFieldDefNil)]
    [(SCons head tail)
      (match (parse-ast-field-def dispatch (box-get head) allow-cleanup)
        [(OkAstFieldDef parsed-head)
          (match (parse-ast-field-def-list
            dispatch
            (box-get tail)
            allow-cleanup)
            [(OkAstFieldDefList parsed-tail)
              (OkAstFieldDefList (ast-field-def-cons parsed-head parsed-tail))]
            [(ErrAstFieldDefList message) (ErrAstFieldDefList message)])]
        [(ErrAstFieldDef message) (ErrAstFieldDefList message)])]
    [_ (ErrAstFieldDefList "parse: malformed field list")]))

(define (compiler-parse-metadata-key? [name : String]) : bool
  (and (> (string-length name) 0) (= (string-ref name 0) #:')))

(define (parse-ast-aggregate-lifetimes-tail [tail : Sexpr]) : ResultAstLifetimeList
  (parse-ast-lifetime-list-nonempty
    (compiler-parse-dispatch-env)
    tail
    "parse: :lifetimes metadata expects at least one lifetime identifier"))

(define (parse-ast-defstruct-repr-tail [tail : Sexpr]) : ResultAstStructRepr
  (match tail
    [(SCons name-node end)
      (match (box-get end)
        [(SNil)
          (match (box-get name-node)
            [(SSym name)
              (if (string-eq name "c")
                (OkAstStructRepr (AstStructReprC))
                (if (string-eq name "packed")
                  (ErrAstStructRepr "parse: packed repr is reserved")
                  (ErrAstStructRepr
                    (string-append "parse: unknown struct repr " name))))]
            [_ (ErrAstStructRepr "parse: malformed :repr metadata")])]
        [_ (ErrAstStructRepr "parse: malformed :repr metadata")])]
    [_ (ErrAstStructRepr "parse: malformed :repr metadata")]))

(define (parse-ast-defstruct-cleanup-tail [tail : Sexpr]) : ResultAstStructCleanup
  (match tail
    [(SCons cleanup-node end)
      (match (box-get end)
        [(SNil)
          (match (box-get cleanup-node)
            [(SSym cleanup-fn)
              (OkAstStructCleanup (AstStructCleanupFn cleanup-fn))]
            [_
              (ErrAstStructCleanup
                "parse: malformed defstruct :cleanup metadata")])]
        [_ (ErrAstStructCleanup "parse: malformed defstruct :cleanup metadata")])]
    [_ (ErrAstStructCleanup "parse: malformed defstruct :cleanup metadata")]))

(define (parse-ast-defstruct-field-item
  [dispatch : SymI64Env]
  [head : SpannedSexpr]
  [tail : SpannedSexpr]
  [lifetimes : AstLifetimeList]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [seen-lifetimes : bool]
  [seen-repr : bool]
  [seen-cleanup : bool]) : ResultAstStructDefParts
  (match (parse-ast-field-def
    dispatch
    (spanned-sexpr-form head)
    (ast-struct-cleanup? cleanup))
    [(OkAstFieldDef parsed-field)
      (match (parse-ast-defstruct-items
        dispatch
        tail
        lifetimes
        repr
        cleanup
        seen-lifetimes
        seen-repr
        seen-cleanup
        true)
        [(OkAstStructDefParts
            parsed-lifetimes
            parsed-repr
            parsed-cleanup
            parsed-rest)
          (OkAstStructDefParts
            parsed-lifetimes
            parsed-repr
            parsed-cleanup
            (ast-field-def-cons parsed-field parsed-rest))]
        [(ErrAstStructDefParts message) (ErrAstStructDefParts message)])]
    [(ErrAstFieldDef message) (ErrAstStructDefParts message)]))

(define (parse-ast-defstruct-items
  [dispatch : SymI64Env]
  [items : SpannedSexpr]
  [lifetimes : AstLifetimeList]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [seen-lifetimes : bool]
  [seen-repr : bool]
  [seen-cleanup : bool]
  [seen-field : bool]) : ResultAstStructDefParts
  (match items
    [(SpSNil _) (OkAstStructDefParts lifetimes repr cleanup AstFieldDefNil)]
    [(SpSCons head tail _)
      (match (spanned-sexpr-form (box-get head))
        [(SCons key-node after-key)
          (match (box-get key-node)
            [(SSym key)
              (cond
                [(string-eq key ":lifetimes")
                  (if seen-field
                    (ErrAstStructDefParts
                      "parse: defstruct metadata must appear before fields")
                    (if seen-lifetimes
                      (ErrAstStructDefParts
                        "parse: duplicate defstruct :lifetimes metadata")
                      (match (parse-ast-aggregate-lifetimes-tail
                        (box-get after-key))
                        [(OkAstLifetimeList next-lifetimes)
                          (parse-ast-defstruct-items
                            dispatch
                            (box-get tail)
                            next-lifetimes
                            repr
                            cleanup
                            true
                            seen-repr
                            seen-cleanup
                            false)]
                        [(ErrAstLifetimeList message)
                          (ErrAstStructDefParts message)])))]
                [(string-eq key ":repr")
                  (if seen-field
                    (ErrAstStructDefParts
                      "parse: defstruct metadata must appear before fields")
                    (if seen-repr
                      (ErrAstStructDefParts
                        "parse: duplicate defstruct :repr metadata")
                      (match (parse-ast-defstruct-repr-tail (box-get after-key))
                        [(OkAstStructRepr next-repr)
                          (if (and
                            (ast-struct-repr-c? next-repr)
                            (ast-struct-cleanup? cleanup))
                            (ErrAstStructDefParts
                              "parse: defstruct cannot combine :repr c with :cleanup metadata")
                            (parse-ast-defstruct-items
                              dispatch
                              (box-get tail)
                              lifetimes
                              next-repr
                              cleanup
                              seen-lifetimes
                              true
                              seen-cleanup
                              false))]
                        [(ErrAstStructRepr message)
                          (ErrAstStructDefParts message)])))]
                [(string-eq key ":cleanup")
                  (if seen-field
                    (ErrAstStructDefParts
                      "parse: defstruct metadata must appear before fields")
                    (if seen-cleanup
                      (ErrAstStructDefParts
                        "parse: duplicate defstruct :cleanup metadata")
                      (match (parse-ast-defstruct-cleanup-tail
                        (box-get after-key))
                        [(OkAstStructCleanup next-cleanup)
                          (if (ast-struct-repr-c? repr)
                            (ErrAstStructDefParts
                              "parse: defstruct cannot combine :repr c with :cleanup metadata")
                            (parse-ast-defstruct-items
                              dispatch
                              (box-get tail)
                              lifetimes
                              repr
                              next-cleanup
                              seen-lifetimes
                              seen-repr
                              true
                              false))]
                        [(ErrAstStructCleanup message)
                          (ErrAstStructDefParts message)])))]
                [(compiler-parse-metadata-key? key)
                  (if seen-field
                    (ErrAstStructDefParts
                      "parse: defstruct metadata must appear before fields")
                    (if (string-eq key ":packed")
                      (ErrAstStructDefParts "parse: packed repr is reserved")
                      (ErrAstStructDefParts
                        (string-append "parse: unknown defstruct metadata " key))))]
                [else
                  (parse-ast-defstruct-field-item
                    dispatch
                    (box-get head)
                    (box-get tail)
                    lifetimes
                    repr
                    cleanup
                    seen-lifetimes
                    seen-repr
                    seen-cleanup)])]
            [_
              (parse-ast-defstruct-field-item
                dispatch
                (box-get head)
                (box-get tail)
                lifetimes
                repr
                cleanup
                seen-lifetimes
                seen-repr
                seen-cleanup)])]
        [_
          (parse-ast-defstruct-field-item
            dispatch
            (box-get head)
            (box-get tail)
            lifetimes
            repr
            cleanup
            seen-lifetimes
            seen-repr
            seen-cleanup)])]
    [_ (ErrAstStructDefParts "parse: malformed field list")]))

(define (compiler-parse-type-list-has-metadata? [s : Sexpr]) : bool
  (match s
    [(SNil) false]
    [(SCons head rest)
      (match (box-get head)
        [(SCons key-node _)
          (match (box-get key-node)
            [(SSym key)
              (if (compiler-parse-metadata-key? key)
                true
                (compiler-parse-type-list-has-metadata? (box-get rest)))]
            [_ (compiler-parse-type-list-has-metadata? (box-get rest))])]
        [_ (compiler-parse-type-list-has-metadata? (box-get rest))])]
    [_ false]))

(define (parse-ast-variant-def [dispatch : SymI64Env] [s : Sexpr]) : ResultAstVariantDef
  (match s
    [(SCons name-node fields)
      (match (box-get name-node)
        [(SSym name)
          (if (compiler-parse-metadata-key? name)
            (if (string-eq name ":cleanup")
              (ErrAstVariantDef "parse: defenum cleanup metadata is reserved")
              (ErrAstVariantDef
                (string-append "parse: unknown defenum metadata " name)))
            (if (compiler-parse-type-list-has-metadata? (box-get fields))
              (ErrAstVariantDef
                "parse: enum payload cleanup metadata is reserved")
              (match (parse-ast-type-list dispatch (box-get fields))
                [(OkAstTypeList parsed-fields)
                  (OkAstVariantDef (AstVariantDef name parsed-fields))]
                [(ErrAstTypeList message) (ErrAstVariantDef message)])))]
        [_ (ErrAstVariantDef "parse: malformed variant definition")])]
    [_ (ErrAstVariantDef "parse: malformed variant definition")]))

(define (parse-ast-variant-def-list [dispatch : SymI64Env] [s : Sexpr]) : ResultAstVariantDefList
  (match s
    [(SNil) (OkAstVariantDefList AstVariantDefNil)]
    [(SCons head tail)
      (match (parse-ast-variant-def dispatch (box-get head))
        [(OkAstVariantDef parsed-head)
          (match (parse-ast-variant-def-list dispatch (box-get tail))
            [(OkAstVariantDefList parsed-tail)
              (OkAstVariantDefList
                (ast-variant-def-cons parsed-head parsed-tail))]
            [(ErrAstVariantDefList message) (ErrAstVariantDefList message)])]
        [(ErrAstVariantDef message) (ErrAstVariantDefList message)])]
    [_ (ErrAstVariantDefList "parse: malformed variant list")]))

(define (parse-ast-dispatch-isa [name : String]) : ResultAstDispatchIsa
  (cond
    [(string-eq name "scalar") (OkAstDispatchIsa (AstDispatchScalar))]
    [(string-eq name "avx2") (OkAstDispatchIsa (AstDispatchAvx2))]
    [(string-eq name "avx512") (OkAstDispatchIsa (AstDispatchAvx512))]
    [else
      (ErrAstDispatchIsa (string-append "parse: unknown defdispatch ISA " name))]))

(define (parse-ast-dispatch-variant [s : SpannedSexpr]) : ResultAstDispatchVariant
  (match s
    [(SpSCons isa-node rest _)
      (match (box-get isa-node)
        [(SpSSym isa-name _)
          (match (box-get rest)
            [(SpSCons fn-node end _)
              (match (box-get end)
                [(SpSNil _)
                  (match (box-get fn-node)
                    [(SpSSym fn-name _)
                      (match (parse-ast-dispatch-isa isa-name)
                        [(OkAstDispatchIsa isa)
                          (OkAstDispatchVariant
                            (AstDispatchVariant isa fn-name))]
                        [(ErrAstDispatchIsa message)
                          (ErrAstDispatchVariant message)])]
                    [_
                      (ErrAstDispatchVariant
                        "parse: malformed defdispatch variant")])]
                [_
                  (ErrAstDispatchVariant "parse: malformed defdispatch variant")])]
            [_ (ErrAstDispatchVariant "parse: malformed defdispatch variant")])]
        [_ (ErrAstDispatchVariant "parse: malformed defdispatch variant")])]
    [_ (ErrAstDispatchVariant "parse: malformed defdispatch variant")]))

(define (parse-ast-dispatch-variant-list [variants : SpannedSexpr]) : ResultAstDispatchVariantList
  (match variants
    [(SpSNil _) (OkAstDispatchVariantList AstDispatchVariantNil)]
    [(SpSCons head rest _)
      (match (parse-ast-dispatch-variant (box-get head))
        [(OkAstDispatchVariant parsed)
          (match (parse-ast-dispatch-variant-list (box-get rest))
            [(OkAstDispatchVariantList parsed-rest)
              (OkAstDispatchVariantList
                (ast-dispatch-variant-cons parsed parsed-rest))]
            [(ErrAstDispatchVariantList message)
              (ErrAstDispatchVariantList message)])]
        [(ErrAstDispatchVariant message) (ErrAstDispatchVariantList message)])]
    [_ (ErrAstDispatchVariantList "parse: malformed defdispatch variant list")]))

(define (parse-ast-defenum-variant-item
  [dispatch : SymI64Env]
  [head : SpannedSexpr]
  [tail : SpannedSexpr]
  [lifetimes : AstLifetimeList]
  [seen-lifetimes : bool]) : ResultAstEnumDefParts
  (match (parse-ast-variant-def dispatch (spanned-sexpr-form head))
    [(OkAstVariantDef parsed-variant)
      (match (parse-ast-defenum-items
        dispatch
        tail
        lifetimes
        seen-lifetimes
        true)
        [(OkAstEnumDefParts parsed-lifetimes parsed-rest)
          (OkAstEnumDefParts
            parsed-lifetimes
            (ast-variant-def-cons parsed-variant parsed-rest))]
        [(ErrAstEnumDefParts message) (ErrAstEnumDefParts message)])]
    [(ErrAstVariantDef message) (ErrAstEnumDefParts message)]))

(define (parse-ast-defenum-items
  [dispatch : SymI64Env]
  [items : SpannedSexpr]
  [lifetimes : AstLifetimeList]
  [seen-lifetimes : bool]
  [seen-variant : bool]) : ResultAstEnumDefParts
  (match items
    [(SpSNil _) (OkAstEnumDefParts lifetimes AstVariantDefNil)]
    [(SpSCons head tail _)
      (match (spanned-sexpr-form (box-get head))
        [(SCons key-node after-key)
          (match (box-get key-node)
            [(SSym key)
              (cond
                [(not (compiler-parse-metadata-key? key))
                  (parse-ast-defenum-variant-item
                    dispatch
                    (box-get head)
                    (box-get tail)
                    lifetimes
                    seen-lifetimes)]
                [(not (string-eq key ":lifetimes"))
                  (if (string-eq key ":cleanup")
                    (ErrAstEnumDefParts
                      "parse: defenum cleanup metadata is reserved")
                    (ErrAstEnumDefParts
                      (string-append "parse: unknown defenum metadata " key)))]
                [seen-variant
                  (ErrAstEnumDefParts
                    "parse: defenum metadata must appear before variants")]
                [seen-lifetimes
                  (ErrAstEnumDefParts
                    "parse: duplicate defenum :lifetimes metadata")]
                [else
                  (match (parse-ast-aggregate-lifetimes-tail
                    (box-get after-key))
                    [(OkAstLifetimeList next-lifetimes)
                      (parse-ast-defenum-items
                        dispatch
                        (box-get tail)
                        next-lifetimes
                        true
                        false)]
                    [(ErrAstLifetimeList message) (ErrAstEnumDefParts message)])])]
            [_
              (parse-ast-defenum-variant-item
                dispatch
                (box-get head)
                (box-get tail)
                lifetimes
                seen-lifetimes)])]
        [_
          (parse-ast-defenum-variant-item
            dispatch
            (box-get head)
            (box-get tail)
            lifetimes
            seen-lifetimes)])]
    [_ (ErrAstEnumDefParts "parse: malformed variant list")]))

(define (parse-ast-pattern-list [dispatch : SymI64Env] [s : Sexpr]) : ResultAstPatternList
  (match s
    [(SNil) (OkAstPatternList AstPatternNil)]
    [(SCons head tail)
      (match (parse-ast-pattern dispatch (box-get head))
        [(OkAstPattern parsed-head)
          (match (parse-ast-pattern-list dispatch (box-get tail))
            [(OkAstPatternList parsed-tail)
              (OkAstPatternList (ast-pattern-cons parsed-head parsed-tail))]
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
        (cond
          [(= tag (compiler-parse-tag-pattern-wildcard))
            (OkAstPattern AstPatWildcard)]
          [(= tag (compiler-parse-tag-lit-true))
            (OkAstPattern (AstPatLiteral (AstLitBool true)))]
          [(= tag (compiler-parse-tag-lit-false))
            (OkAstPattern (AstPatLiteral (AstLitBool false)))]
          [else (OkAstPattern (AstPatBinding name))]))]
    [(SCons name-node args)
      (match (box-get name-node)
        [(SSym name)
          (match (parse-ast-pattern-list dispatch (box-get args))
            [(OkAstPatternList parsed-args)
              (OkAstPattern (ast-pat-variant name parsed-args))]
            [(ErrAstPatternList message) (ErrAstPattern message)])]
        [_ (ErrAstPattern "parse: expected pattern")])]
    [_ (ErrAstPattern "parse: expected pattern")]))

(define (parse-ast-cfg-expr-maybe [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstMaybeExpr
  (match rest
    [(SpSCons pred then-tail _)
      (match (box-get then-tail)
        [(SpSCons then-expr rest-tail _)
          (match (box-get rest-tail)
            [(SpSNil _)
              (match (compiler-cfg-eval dispatch (box-get pred))
                [(OkCompilerCfg enabled)
                  (if enabled
                    (match (parse-ast-expr dispatch (box-get then-expr))
                      [(OkAstExpr parsed) (OkAstSomeExpr parsed)]
                      [(ErrAstExpr message) (ErrAstMaybeExpr message)])
                    (OkAstNoExpr))]
                [(ErrCompilerCfg message) (ErrAstMaybeExpr message)])]
            [(SpSCons else-expr end _)
              (match (box-get end)
                [(SpSNil _)
                  (match (compiler-cfg-eval dispatch (box-get pred))
                    [(OkCompilerCfg enabled)
                      (match (parse-ast-expr
                        dispatch
                        (if enabled
                          (box-get then-expr)
                          (box-get else-expr)))
                        [(OkAstExpr parsed) (OkAstSomeExpr parsed)]
                        [(ErrAstExpr message) (ErrAstMaybeExpr message)])]
                    [(ErrCompilerCfg message) (ErrAstMaybeExpr message)])]
                [_
                  (ErrAstMaybeExpr
                    "parse: cfg expression expects predicate and expression")])]
            [_
              (ErrAstMaybeExpr
                "parse: cfg expression expects predicate and expression")])]
        [_
          (ErrAstMaybeExpr
            "parse: cfg expression expects predicate and expression")])]
    [_
      (ErrAstMaybeExpr "parse: cfg expression expects predicate and expression")]))

(define (parse-ast-cfg-expr [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-cfg-expr-maybe dispatch rest)
    [(OkAstSomeExpr expr) (OkAstExpr expr)]
    [(OkAstNoExpr) (OkAstExpr (AstExprLiteral AstLitUnit))]
    [(ErrAstMaybeExpr message) (ErrAstExpr message)]))

(define (parse-ast-expr-list [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstExprList
  (match s
    [(SpSNil _) (OkAstExprList AstExprNil)]
    [(SpSCons head tail _)
      (match (box-get head)
        [(SpSCons op-node cfg-rest _)
          (match (box-get op-node)
            [(SpSSym op _)
              (if (string-eq op "cfg")
                (match (parse-ast-cfg-expr-maybe dispatch (box-get cfg-rest))
                  [(OkAstSomeExpr parsed-head)
                    (match (parse-ast-expr-list dispatch (box-get tail))
                      [(OkAstExprList parsed-tail)
                        (OkAstExprList (ast-expr-cons parsed-head parsed-tail))]
                      [(ErrAstExprList message) (ErrAstExprList message)])]
                  [(OkAstNoExpr) (parse-ast-expr-list dispatch (box-get tail))]
                  [(ErrAstMaybeExpr message) (ErrAstExprList message)])
                (match (parse-ast-expr dispatch (box-get head))
                  [(OkAstExpr parsed-head)
                    (match (parse-ast-expr-list dispatch (box-get tail))
                      [(OkAstExprList parsed-tail)
                        (OkAstExprList (ast-expr-cons parsed-head parsed-tail))]
                      [(ErrAstExprList message) (ErrAstExprList message)])]
                  [(ErrAstExpr message) (ErrAstExprList message)]))]
            [_
              (match (parse-ast-expr dispatch (box-get head))
                [(OkAstExpr parsed-head)
                  (match (parse-ast-expr-list dispatch (box-get tail))
                    [(OkAstExprList parsed-tail)
                      (OkAstExprList (ast-expr-cons parsed-head parsed-tail))]
                    [(ErrAstExprList message) (ErrAstExprList message)])]
                [(ErrAstExpr message) (ErrAstExprList message)])])]
        [_
          (match (parse-ast-expr dispatch (box-get head))
            [(OkAstExpr parsed-head)
              (match (parse-ast-expr-list dispatch (box-get tail))
                [(OkAstExprList parsed-tail)
                  (OkAstExprList (ast-expr-cons parsed-head parsed-tail))]
                [(ErrAstExprList message) (ErrAstExprList message)])]
            [(ErrAstExpr message) (ErrAstExprList message)])])]
    [_ (ErrAstExprList "parse: malformed expression list")]))

(define (parse-ast-spanned-list-exactly-two? [s : SpannedSexpr]) : bool
  (match s
    [(SpSCons _ tail _)
      (match (box-get tail)
        [(SpSCons _ end _)
          (match (box-get end)
            [(SpSNil _) true]
            [_ false])]
        [_ false])]
    [_ false]))

(define (parse-ast-binary
  [dispatch : SymI64Env]
  [op : AstBinOp]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons left right-tail _)
      (match (box-get right-tail)
        [(SpSCons right end _)
          (match (box-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (box-get left))
                [(OkAstExpr parsed-left)
                  (match (parse-ast-expr dispatch (box-get right))
                    [(OkAstExpr parsed-right)
                      (OkAstExpr (ast-expr-binary op parsed-left parsed-right))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [(ErrAstExpr message) (ErrAstExpr message)])]
            [_ (ErrAstExpr "parse: malformed binary expression")])]
        [_ (ErrAstExpr "parse: malformed binary expression")])]
    [_ (ErrAstExpr "parse: malformed binary expression")]))

(define (parse-ast-unary
  [dispatch : SymI64Env]
  [op : AstUnOp]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (box-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (box-get expr))
            [(OkAstExpr parsed-expr)
              (OkAstExpr (ast-expr-unary op parsed-expr))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: malformed unary expression")])]
    [_ (ErrAstExpr "parse: malformed unary expression")]))

(define (parse-ast-if [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons cond then-tail _)
      (match (box-get then-tail)
        [(SpSCons then-branch else-tail _)
          (match (box-get else-tail)
            [(SpSCons else-branch end _)
              (match (box-get end)
                [(SpSNil _)
                  (match (parse-ast-expr dispatch (box-get cond))
                    [(OkAstExpr parsed-cond)
                      (match (parse-ast-expr dispatch (box-get then-branch))
                        [(OkAstExpr parsed-then)
                          (match (parse-ast-expr dispatch (box-get else-branch))
                            [(OkAstExpr parsed-else)
                              (OkAstExpr
                                (ast-expr-if
                                  parsed-cond
                                  parsed-then
                                  parsed-else))]
                            [(ErrAstExpr message) (ErrAstExpr message)])]
                        [(ErrAstExpr message) (ErrAstExpr message)])]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [_ (ErrAstExpr "parse: malformed if")])]
            [_ (ErrAstExpr "parse: malformed if")])]
        [_ (ErrAstExpr "parse: malformed if")])]
    [_ (ErrAstExpr "parse: malformed if")]))

(define (parse-ast-unit-expr) : AstExpr
  (AstExprLiteral AstLitUnit))

(define (parse-ast-expr-list-append-unit [exprs : AstExprList]) : AstExprList
  (match exprs
    [(AstExprNil) (ast-expr-cons (parse-ast-unit-expr) AstExprNil)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (box-get head)]
        [rest : AstExprList (box-get rest)]
        (ast-expr-cons head (parse-ast-expr-list-append-unit rest)))]))

(define (parse-ast-when-like-error [is-unless : bool]) : String
  (if is-unless
    "parse: unless expects a condition and at least one body expression"
    "parse: when expects a condition and at least one body expression"))

(define (parse-ast-when-like
  [dispatch : SymI64Env]
  [rest : SpannedSexpr]
  [is-unless : bool]) : ResultAstExpr
  (match rest
    [(SpSCons cond body _)
      (match (box-get body)
        [(SpSNil _) (ErrAstExpr (parse-ast-when-like-error is-unless))]
        [_
          (match (parse-ast-expr dispatch (box-get cond))
            [(OkAstExpr parsed-cond)
              (match (parse-ast-expr-list dispatch (box-get body))
                [(OkAstExprList parsed-body)
                  (let
                    [unit-expr : AstExpr (parse-ast-unit-expr)]
                    [body-expr : AstExpr
                      (AstExprBegin
                        (parse-ast-expr-list-append-unit parsed-body))]
                    (if is-unless
                      (OkAstExpr (ast-expr-if parsed-cond unit-expr body-expr))
                      (OkAstExpr (ast-expr-if parsed-cond body-expr unit-expr))))]
                [(ErrAstExprList message) (ErrAstExpr message)])]
            [(ErrAstExpr message) (ErrAstExpr message)])])]
    [_ (ErrAstExpr (parse-ast-when-like-error is-unless))]))

(define (parse-ast-when [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (parse-ast-when-like dispatch rest false))

(define (parse-ast-unless [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (parse-ast-when-like dispatch rest true))

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
              (OkAstExpr (ast-expr-if parsed-cond parsed-body parsed-else))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [(ErrAstExpr message) (ErrAstExpr message)]))

(define (parse-ast-cond-arm
  [dispatch : SymI64Env]
  [arm : SpannedSexpr]
  [rest : SpannedSexpr]
  [has-test : bool]) : ResultAstExpr
  (match arm
    [(SpSBracketList items _)
      (parse-ast-cond-arm dispatch (box-get items) rest has-test)]
    [(SpSCons head body-tail _)
      (match (box-get body-tail)
        [(SpSCons body end _)
          (match (box-get end)
            [(SpSNil _)
              (match (box-get head)
                [(SpSSym name _)
                  (if (string-eq name "else")
                    (if has-test
                      (match rest
                        [(SpSNil _) (parse-ast-expr dispatch (box-get body))]
                        [_ (ErrAstExpr "parse: cond else arm must be final")])
                      (match rest
                        [(SpSNil _)
                          (ErrAstExpr
                            "parse: cond requires at least one test arm")]
                        [_ (ErrAstExpr "parse: cond else arm must be final")]))
                    (parse-ast-cond-test-arm
                      dispatch
                      (box-get head)
                      (box-get body)
                      rest))]
                [_
                  (parse-ast-cond-test-arm
                    dispatch
                    (box-get head)
                    (box-get body)
                    rest)])]
            [_ (ErrAstExpr "parse: malformed cond arm")])]
        [_ (ErrAstExpr "parse: malformed cond arm")])]
    [_ (ErrAstExpr "parse: malformed cond arm")]))

(define (parse-ast-cond-arms
  [dispatch : SymI64Env]
  [arms : SpannedSexpr]
  [has-test : bool]) : ResultAstExpr
  (match arms
    [(SpSNil _) (ErrAstExpr "parse: cond requires final else arm")]
    [(SpSCons arm rest _)
      (parse-ast-cond-arm dispatch (box-get arm) (box-get rest) has-test)]
    [_ (ErrAstExpr "parse: malformed cond")]))

(define (parse-ast-cond [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (parse-ast-cond-arms dispatch rest false))

(define (parse-ast-cond-legacy-form? [rest : SpannedSexpr]) : bool
  (match rest
    [(SpSNil _) true]
    [(SpSCons head _ _)
      (match (box-get head)
        [(SpSBracketList _ _) true]
        [_ false])]
    [_ false]))

(define (parse-ast-cond-or-call
  [dispatch : SymI64Env]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstExpr
  (if (parse-ast-cond-legacy-form? rest)
    (parse-ast-cond dispatch rest)
    (parse-ast-call dispatch head rest)))

(define (parse-ast-while [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons cond body-tail _)
      (match (box-get body-tail)
        [(SpSCons body end _)
          (match (box-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (box-get cond))
                [(OkAstExpr parsed-cond)
                  (match (parse-ast-expr dispatch (box-get body))
                    [(OkAstExpr parsed-body)
                      (OkAstExpr (ast-expr-while parsed-cond parsed-body))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [(ErrAstExpr message) (ErrAstExpr message)])]
            [_ (ErrAstExpr "parse: malformed while")])]
        [_ (ErrAstExpr "parse: malformed while")])]
    [_ (ErrAstExpr "parse: malformed while")]))

(define (parse-ast-set [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons name-node value-tail _)
      (match (box-get name-node)
        [(SpSSym name _)
          (match (box-get value-tail)
            [(SpSCons value end _)
              (match (box-get end)
                [(SpSNil _)
                  (match (parse-ast-expr dispatch (box-get value))
                    [(OkAstExpr parsed-value)
                      (OkAstExpr (ast-expr-set name parsed-value))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [_ (ErrAstExpr "parse: malformed set!")])]
            [_ (ErrAstExpr "parse: malformed set!")])]
        [_ (ErrAstExpr "parse: malformed set!")])]
    [_ (ErrAstExpr "parse: malformed set!")]))

(define (parse-ast-ann-like
  [dispatch : SymI64Env]
  [is-cast : bool]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr colon-tail _)
      (match (box-get colon-tail)
        [(SpSCons colon ty-tail _)
          (match (box-get ty-tail)
            [(SpSCons ty end _)
              (match (box-get end)
                [(SpSNil _)
                  (if (sexpr-colon? (spanned-sexpr-form (box-get colon)))
                    (match (parse-ast-expr dispatch (box-get expr))
                      [(OkAstExpr parsed-expr)
                        (match (parse-ast-type
                          dispatch
                          (spanned-sexpr-form (box-get ty)))
                          [(OkAstType parsed-ty)
                            (if is-cast
                              (OkAstExpr (ast-expr-cast parsed-expr parsed-ty))
                              (OkAstExpr (ast-expr-ann parsed-expr parsed-ty)))]
                          [(ErrAstType message) (ErrAstExpr message)])]
                      [(ErrAstExpr message) (ErrAstExpr message)])
                    (ErrAstExpr "parse: expected ':' in annotation"))]
                [_ (ErrAstExpr "parse: malformed annotation")])]
            [_ (ErrAstExpr "parse: malformed annotation")])]
        [_ (ErrAstExpr "parse: malformed annotation")])]
    [_ (ErrAstExpr "parse: malformed annotation")]))

(define (parse-ast-let-binding [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstLetBinding
  (match s
    [(SpSBracketList items _) (parse-ast-let-binding dispatch (box-get items))]
    [(SpSCons name-node tail _)
      (match (box-get name-node)
        [(SpSSym name _)
          (match (box-get tail)
            [(SpSCons second rest _)
              (match (box-get rest)
                [(SpSNil _)
                  (match (parse-ast-expr dispatch (box-get second))
                    [(OkAstExpr parsed-value)
                      (OkAstLetBinding
                        (ast-let-binding name AstNoType parsed-value))]
                    [(ErrAstExpr message) (ErrAstLetBinding message)])]
                [(SpSCons ty value-tail _)
                  (match (box-get value-tail)
                    [(SpSCons value end _)
                      (match (box-get end)
                        [(SpSNil _)
                          (if (sexpr-colon?
                            (spanned-sexpr-form (box-get second)))
                            (match (parse-ast-type
                              dispatch
                              (spanned-sexpr-form (box-get ty)))
                              [(OkAstType parsed-ty)
                                (match (parse-ast-expr dispatch (box-get value))
                                  [(OkAstExpr parsed-value)
                                    (OkAstLetBinding
                                      (ast-let-binding
                                        name
                                        (AstSomeType parsed-ty)
                                        parsed-value))]
                                  [(ErrAstExpr message)
                                    (ErrAstLetBinding message)])]
                              [(ErrAstType message) (ErrAstLetBinding message)])
                            (ErrAstLetBinding
                              "parse: expected ':' in let binding"))]
                        [_ (ErrAstLetBinding "parse: malformed let binding")])]
                    [_ (ErrAstLetBinding "parse: malformed let binding")])]
                [_ (ErrAstLetBinding "parse: malformed let binding")])]
            [_ (ErrAstLetBinding "parse: malformed let binding")])]
        [_ (ErrAstLetBinding "parse: malformed let binding")])]
    [_ (ErrAstLetBinding "parse: malformed let binding")]))

(define (parse-ast-let-binding-list [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstLetBindingList
  (match s
    [(SpSNil _) (OkAstLetBindingList AstLetBindingNil)]
    [(SpSCons head tail _)
      (match (parse-ast-let-binding dispatch (box-get head))
        [(OkAstLetBinding parsed-head)
          (match (parse-ast-let-binding-list dispatch (box-get tail))
            [(OkAstLetBindingList parsed-tail)
              (OkAstLetBindingList
                (ast-let-binding-cons parsed-head parsed-tail))]
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
      (match (box-get head)
        [(SpSBracketList _ _)
          (match (parse-ast-let-binding dispatch (box-get head))
            [(OkAstLetBinding parsed-head)
              (match (parse-ast-let-flat-tail dispatch (box-get tail))
                [(OkAstLetParts parsed-tail parsed-body)
                  (OkAstLetParts
                    (ast-let-binding-cons parsed-head parsed-tail)
                    parsed-body)]
                [(ErrAstLetParts message) (ErrAstLetParts message)])]
            [(ErrAstLetBinding message) (ErrAstLetParts message)])]
        [_
          (match (box-get tail)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (box-get head))
                [(OkAstExpr parsed-body)
                  (OkAstLetParts AstLetBindingNil parsed-body)]
                [(ErrAstExpr message) (ErrAstLetParts message)])]
            [_ (ErrAstLetParts "parse: let expects exactly one body")])])]
    [(SpSNil _) (ErrAstLetParts "parse: let missing body")]
    [_ (ErrAstLetParts "parse: malformed let")]))

(define (parse-ast-let-flat [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons head _ _)
      (match (box-get head)
        [(SpSBracketList _ _)
          (match (parse-ast-let-flat-tail dispatch rest)
            [(OkAstLetParts parsed-bindings parsed-body)
              (if (ast-let-binding-list-empty? parsed-bindings)
                (ErrAstExpr "parse: let requires at least one binding")
                (OkAstExpr (ast-expr-let parsed-bindings parsed-body)))]
            [(ErrAstLetParts message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: let requires at least one binding")])]
    [_ (ErrAstExpr "parse: malformed let")]))

(define (parse-ast-let [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons bindings tail _)
      (match (box-get bindings)
        [(SpSBracketList _ _) (parse-ast-let-flat dispatch rest)]
        [_
          (match (box-get tail)
            [(SpSCons body end _)
              (match (box-get end)
                [(SpSNil _)
                  (match (parse-ast-let-binding-list
                    dispatch
                    (box-get bindings))
                    [(OkAstLetBindingList parsed-bindings)
                      (if (ast-let-binding-list-empty? parsed-bindings)
                        (ErrAstExpr "parse: let requires at least one binding")
                        (match (parse-ast-expr dispatch (box-get body))
                          [(OkAstExpr parsed-body)
                            (OkAstExpr
                              (ast-expr-let parsed-bindings parsed-body))]
                          [(ErrAstExpr message) (ErrAstExpr message)]))]
                    [(ErrAstLetBindingList message) (ErrAstExpr message)])]
                [_ (ErrAstExpr "parse: let requires at least one binding")])]
            [_ (ErrAstExpr "parse: let requires at least one binding")])])]
    [(SpSCons _ _ _) (ErrAstExpr "parse: let requires at least one binding")]
    [_ (ErrAstExpr "parse: malformed let")]))

(define (parse-ast-lambda [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons params tail _)
      (match (box-get tail)
        [(SpSCons second rest-tail _)
          (match (box-get rest-tail)
            [(SpSNil _)
              (match (parse-ast-param-list
                dispatch
                (spanned-sexpr-form (box-get params)))
                [(OkAstParamList parsed-params)
                  (if (ast-param-list-has-comptime? parsed-params)
                    (ErrAstExpr
                      "comptime parameters are only supported on top-level function definitions")
                    (match (parse-ast-expr dispatch (box-get second))
                      [(OkAstExpr parsed-body)
                        (OkAstExpr
                          (ast-expr-lambda parsed-params AstNoType parsed-body))]
                      [(ErrAstExpr message) (ErrAstExpr message)]))]
                [(ErrAstParamList message) (ErrAstExpr message)])]
            [(SpSCons ret body-tail _)
              (match (box-get body-tail)
                [(SpSCons body end _)
                  (match (box-get end)
                    [(SpSNil _)
                      (if (sexpr-colon? (spanned-sexpr-form (box-get second)))
                        (match (parse-ast-param-list
                          dispatch
                          (spanned-sexpr-form (box-get params)))
                          [(OkAstParamList parsed-params)
                            (if (ast-param-list-has-comptime? parsed-params)
                              (ErrAstExpr
                                "comptime parameters are only supported on top-level function definitions")
                              (match (parse-ast-type
                                dispatch
                                (spanned-sexpr-form (box-get ret)))
                                [(OkAstType parsed-ret)
                                  (match (parse-ast-expr
                                    dispatch
                                    (box-get body))
                                    [(OkAstExpr parsed-body)
                                      (OkAstExpr
                                        (ast-expr-lambda
                                          parsed-params
                                          (AstSomeType parsed-ret)
                                          parsed-body))]
                                    [(ErrAstExpr message) (ErrAstExpr message)])]
                                [(ErrAstType message) (ErrAstExpr message)]))]
                          [(ErrAstParamList message) (ErrAstExpr message)])
                        (ErrAstExpr "parse: expected ':' in lambda"))]
                    [_ (ErrAstExpr "parse: malformed lambda")])]
                [_ (ErrAstExpr "parse: malformed lambda")])]
            [_ (ErrAstExpr "parse: malformed lambda")])]
        [_ (ErrAstExpr "parse: malformed lambda")])]
    [_ (ErrAstExpr "parse: malformed lambda")]))

(define (parse-ast-tuple-ref [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr index-tail _)
      (match (box-get index-tail)
        [(SpSCons index-node end _)
          (match (box-get end)
            [(SpSNil _)
              (match (box-get index-node)
                [(SpSInt index _)
                  (match (parse-ast-expr dispatch (box-get expr))
                    [(OkAstExpr parsed-expr)
                      (OkAstExpr (ast-expr-tuple-ref parsed-expr index))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [_ (ErrAstExpr "parse: tuple-ref index must be integer")])]
            [_ (ErrAstExpr "parse: malformed tuple-ref")])]
        [_ (ErrAstExpr "parse: malformed tuple-ref")])]
    [_ (ErrAstExpr "parse: malformed tuple-ref")]))

(define (parse-ast-make-array [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons elem-ty len-tail _)
      (match (box-get len-tail)
        [(SpSCons len end _)
          (match (box-get end)
            [(SpSNil _)
              (match (parse-ast-type
                dispatch
                (spanned-sexpr-form (box-get elem-ty)))
                [(OkAstType parsed-ty)
                  (match (parse-ast-expr dispatch (box-get len))
                    [(OkAstExpr parsed-len)
                      (OkAstExpr (ast-expr-make-array parsed-ty parsed-len))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [(ErrAstType message) (ErrAstExpr message)])]
            [_ (ErrAstExpr "parse: malformed make-array")])]
        [_ (ErrAstExpr "parse: malformed make-array")])]
    [_ (ErrAstExpr "parse: malformed make-array")]))

(define (parse-ast-array-ref-like
  [dispatch : SymI64Env]
  [is-string : bool]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr index-tail _)
      (match (box-get index-tail)
        [(SpSCons index end _)
          (match (box-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (box-get expr))
                [(OkAstExpr parsed-expr)
                  (match (parse-ast-expr dispatch (box-get index))
                    [(OkAstExpr parsed-index)
                      (if is-string
                        (OkAstExpr
                          (ast-expr-string-ref parsed-expr parsed-index))
                        (OkAstExpr
                          (ast-expr-array-ref parsed-expr parsed-index)))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [(ErrAstExpr message) (ErrAstExpr message)])]
            [_ (ErrAstExpr "parse: malformed ref expression")])]
        [_ (ErrAstExpr "parse: malformed ref expression")])]
    [_ (ErrAstExpr "parse: malformed ref expression")]))

(define (parse-ast-array-set [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr index-tail _)
      (match (box-get index-tail)
        [(SpSCons index value-tail _)
          (match (box-get value-tail)
            [(SpSCons value end _)
              (match (box-get end)
                [(SpSNil _)
                  (match (parse-ast-expr dispatch (box-get expr))
                    [(OkAstExpr parsed-expr)
                      (match (parse-ast-expr dispatch (box-get index))
                        [(OkAstExpr parsed-index)
                          (match (parse-ast-expr dispatch (box-get value))
                            [(OkAstExpr parsed-value)
                              (OkAstExpr
                                (ast-expr-array-set
                                  parsed-expr
                                  parsed-index
                                  parsed-value))]
                            [(ErrAstExpr message) (ErrAstExpr message)])]
                        [(ErrAstExpr message) (ErrAstExpr message)])]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [_ (ErrAstExpr "parse: malformed array-set!")])]
            [_ (ErrAstExpr "parse: malformed array-set!")])]
        [_ (ErrAstExpr "parse: malformed array-set!")])]
    [_ (ErrAstExpr "parse: malformed array-set!")]))

(define (parse-ast-array-push [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr value-tail _)
      (match (box-get value-tail)
        [(SpSCons value end _)
          (match (box-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (box-get expr))
                [(OkAstExpr parsed-expr)
                  (match (parse-ast-expr dispatch (box-get value))
                    [(OkAstExpr parsed-value)
                      (OkAstExpr (ast-expr-array-push parsed-expr parsed-value))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [(ErrAstExpr message) (ErrAstExpr message)])]
            [_ (ErrAstExpr "parse: malformed array-push!")])]
        [_ (ErrAstExpr "parse: malformed array-push!")])]
    [_ (ErrAstExpr "parse: malformed array-push!")]))

(define (parse-ast-borrow [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons first tail _)
      (match (box-get tail)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (box-get first))
            [(OkAstExpr parsed-place)
              (OkAstExpr
                (ast-expr-borrow AstBorrowLifetimeInferred parsed-place))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [(SpSCons place end _)
          (match (box-get end)
            [(SpSNil _)
              (match (box-get first)
                [(SpSSym name _)
                  (match (parse-ast-expr dispatch (box-get place))
                    [(OkAstExpr parsed-place)
                      (OkAstExpr
                        (ast-expr-borrow
                          (AstBorrowLifetimeNamed name)
                          parsed-place))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [_ (ErrAstExpr "parse: borrow lifetime must be an identifier")])]
            [_
              (ErrAstExpr "parse: borrow expects a place or lifetime and place")])]
        [_ (ErrAstExpr "parse: borrow expects a place or lifetime and place")])]
    [_ (ErrAstExpr "parse: borrow expects a place or lifetime and place")]))

(define (parse-ast-struct-get [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr field-tail _)
      (match (box-get field-tail)
        [(SpSCons field-node end _)
          (match (box-get end)
            [(SpSNil _)
              (match (box-get field-node)
                [(SpSSym field _)
                  (match (parse-ast-expr dispatch (box-get expr))
                    [(OkAstExpr parsed-expr)
                      (OkAstExpr (ast-expr-struct-get parsed-expr field))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [_ (ErrAstExpr "parse: malformed struct-get")])]
            [_ (ErrAstExpr "parse: malformed struct-get")])]
        [_ (ErrAstExpr "parse: malformed struct-get")])]
    [_ (ErrAstExpr "parse: malformed struct-get")]))

;; `(comptime expr)` (#718) wraps exactly one inner expression for compile-time
;; evaluation; evaluation itself is reserved for #719.
(define (parse-ast-comptime [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (box-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (box-get expr))
            [(OkAstExpr parsed-expr)
              (OkAstExpr (ast-expr-comptime parsed-expr))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: comptime expects exactly one expression")])]
    [_ (ErrAstExpr "parse: comptime expects exactly one expression")]))

(define (parse-ast-type-literal [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons ty end _)
      (match (box-get end)
        [(SpSNil _)
          (match (parse-ast-type dispatch (spanned-sexpr-form (box-get ty)))
            [(OkAstType parsed-ty) (OkAstExpr (AstExprTypeLiteral parsed-ty))]
            [(ErrAstType message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: type expects exactly one type")])]
    [_ (ErrAstExpr "parse: type expects exactly one type")]))

(define (parse-ast-reduce-op [name : String]) : ResultAstReduceOp
  (cond
    [(string-eq name "sum") (OkAstReduceOp (AstReduceSum))]
    [(string-eq name "min") (OkAstReduceOp (AstReduceMin))]
    [(string-eq name "max") (OkAstReduceOp (AstReduceMax))]
    [(string-eq name "all") (OkAstReduceOp (AstReduceAll))]
    [(string-eq name "any") (OkAstReduceOp (AstReduceAny))]
    [else
      (ErrAstReduceOp
        (string-append
          "parse: unsupported spmd-reduce operator `"
          (string-append name "`; expected one of sum, min, max, all, any")))]))

(define (parse-ast-spmd-reduce-binding
  [dispatch : SymI64Env]
  [op : AstReduceOp]
  [binding : SpannedSexpr]
  [init : SpannedSexpr]
  [value : SpannedSexpr]) : ResultAstExpr
  (match binding
    [(SpSBracketList items _)
      (parse-ast-spmd-reduce-binding dispatch op (box-get items) init value)]
    [(SpSCons index-node colon-tail _)
      (match (box-get index-node)
        [(SpSSym index _)
          (match (box-get colon-tail)
            [(SpSCons colon index-ty-tail _)
              (match (box-get index-ty-tail)
                [(SpSCons index-ty start-tail _)
                  (match (box-get start-tail)
                    [(SpSCons start end-tail _)
                      (match (box-get end-tail)
                        [(SpSCons end finish _)
                          (match (box-get finish)
                            [(SpSNil _)
                              (if (sexpr-colon?
                                (spanned-sexpr-form (box-get colon)))
                                (match (parse-ast-type
                                  dispatch
                                  (spanned-sexpr-form (box-get index-ty)))
                                  [(OkAstType parsed-index-ty)
                                    (match (parse-ast-expr
                                      dispatch
                                      (box-get start))
                                      [(OkAstExpr parsed-start)
                                        (match (parse-ast-expr
                                          dispatch
                                          (box-get end))
                                          [(OkAstExpr parsed-end)
                                            (match (parse-ast-expr
                                              dispatch
                                              init)
                                              [(OkAstExpr parsed-init)
                                                (match (parse-ast-expr
                                                  dispatch
                                                  value)
                                                  [(OkAstExpr parsed-value)
                                                    (OkAstExpr
                                                      (ast-expr-spmd-reduce
                                                        op
                                                        index
                                                        parsed-index-ty
                                                        parsed-start
                                                        parsed-end
                                                        parsed-init
                                                        parsed-value))]
                                                  [(ErrAstExpr message)
                                                    (ErrAstExpr message)])]
                                              [(ErrAstExpr message)
                                                (ErrAstExpr message)])]
                                          [(ErrAstExpr message)
                                            (ErrAstExpr message)])]
                                      [(ErrAstExpr message)
                                        (ErrAstExpr message)])]
                                  [(ErrAstType message) (ErrAstExpr message)])
                                (ErrAstExpr
                                  "parse: expected ':' in spmd-reduce"))]
                            [_ (ErrAstExpr "parse: malformed spmd-reduce")])]
                        [_ (ErrAstExpr "parse: malformed spmd-reduce")])]
                    [_ (ErrAstExpr "parse: malformed spmd-reduce")])]
                [_ (ErrAstExpr "parse: malformed spmd-reduce")])]
            [_ (ErrAstExpr "parse: malformed spmd-reduce")])]
        [_ (ErrAstExpr "parse: malformed spmd-reduce")])]
    [_ (ErrAstExpr "parse: malformed spmd-reduce")]))

(define (parse-ast-spmd-reduce [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons op-node binding-tail _)
      (match (box-get op-node)
        [(SpSSym op-name _)
          (match (box-get binding-tail)
            [(SpSCons binding-list init-tail _)
              (match (box-get binding-list)
                [(SpSCons binding binding-list-end _)
                  (match (box-get binding-list-end)
                    [(SpSNil _)
                      (match (box-get init-tail)
                        [(SpSCons init value-tail _)
                          (match (box-get value-tail)
                            [(SpSCons value end _)
                              (match (box-get end)
                                [(SpSNil _)
                                  (match (parse-ast-reduce-op op-name)
                                    [(OkAstReduceOp op)
                                      (parse-ast-spmd-reduce-binding
                                        dispatch
                                        op
                                        (box-get binding)
                                        (box-get init)
                                        (box-get value))]
                                    [(ErrAstReduceOp message)
                                      (ErrAstExpr message)])]
                                [_ (ErrAstExpr "parse: malformed spmd-reduce")])]
                            [_ (ErrAstExpr "parse: malformed spmd-reduce")])]
                        [_ (ErrAstExpr "parse: malformed spmd-reduce")])]
                    [_ (ErrAstExpr "parse: malformed spmd-reduce")])]
                [_ (ErrAstExpr "parse: malformed spmd-reduce")])]
            [_ (ErrAstExpr "parse: malformed spmd-reduce")])]
        [_ (ErrAstExpr "parse: malformed spmd-reduce")])]
    [(SpSCons _ _ _) (ErrAstExpr "parse: malformed spmd-reduce")]
    [_ (ErrAstExpr "parse: malformed spmd-reduce")]))

(define (parse-ast-try [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (box-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (box-get expr))
            [(OkAstExpr parsed-expr) (OkAstExpr (ast-expr-try parsed-expr))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: try expects exactly one expression")])]
    [_ (ErrAstExpr "parse: try expects exactly one expression")]))

(define (parse-ast-return [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (box-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (box-get expr))
            [(OkAstExpr parsed-expr) (OkAstExpr (ast-expr-return parsed-expr))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: return expects exactly one expression")])]
    [_ (ErrAstExpr "parse: return expects exactly one expression")]))

(define (parse-ast-box-like
  [dispatch : SymI64Env]
  [rest : SpannedSexpr]
  [is-get : bool]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (box-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (box-get expr))
            [(OkAstExpr parsed-expr)
              (if is-get
                (OkAstExpr (ast-expr-box-get parsed-expr))
                (OkAstExpr (ast-expr-box parsed-expr)))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_
          (ErrAstExpr
            (if is-get
              "parse: box-get expects exactly one expression"
              "parse: box expects exactly one expression"))])]
    [_
      (ErrAstExpr
        (if is-get
          "parse: box-get expects exactly one expression"
          "parse: box expects exactly one expression"))]))

;; `(ptr-null : T)` - a colon followed by a pointer type, no leading expression.
;; The parser accepts any type here; the typechecker rejects non-pointer `T`.
(define (parse-ast-ptr-null [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons colon ty-tail _)
      (match (box-get ty-tail)
        [(SpSCons ty end _)
          (match (box-get end)
            [(SpSNil _)
              (if (sexpr-colon? (spanned-sexpr-form (box-get colon)))
                (match (parse-ast-type
                  dispatch
                  (spanned-sexpr-form (box-get ty)))
                  [(OkAstType parsed-ty) (OkAstExpr (AstExprPtrNull parsed-ty))]
                  [(ErrAstType message) (ErrAstExpr message)])
                (ErrAstExpr "parse: expected ':' in ptr-null"))]
            [_
              (ErrAstExpr
                "parse: ptr-null expects (ptr-null : T) with a pointer type T")])]
        [_
          (ErrAstExpr
            "parse: ptr-null expects (ptr-null : T) with a pointer type T")])]
    [_
      (ErrAstExpr
        "parse: ptr-null expects (ptr-null : T) with a pointer type T")]))

;; `(ptr-null? p)` - a single pointer operand.
(define (parse-ast-ptr-null-check [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (box-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (box-get expr))
            [(OkAstExpr parsed-expr)
              (OkAstExpr (ast-expr-ptr-null-check parsed-expr))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: ptr-null? expects exactly one expression")])]
    [_ (ErrAstExpr "parse: ptr-null? expects exactly one expression")]))

(define (parse-ast-ptr-read [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (box-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (box-get expr))
            [(OkAstExpr parsed-expr)
              (OkAstExpr (ast-expr-ptr-read parsed-expr))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: ptr-read expects exactly one expression")])]
    [_ (ErrAstExpr "parse: ptr-read expects exactly one expression")]))

(define (parse-ast-ptr-write [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons ptr value-tail _)
      (match (box-get value-tail)
        [(SpSCons value end _)
          (match (box-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (box-get ptr))
                [(OkAstExpr parsed-ptr)
                  (match (parse-ast-expr dispatch (box-get value))
                    [(OkAstExpr parsed-value)
                      (OkAstExpr (ast-expr-ptr-write parsed-ptr parsed-value))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [(ErrAstExpr message) (ErrAstExpr message)])]
            [_ (ErrAstExpr "parse: ptr-write! expects exactly two expressions")])]
        [_ (ErrAstExpr "parse: ptr-write! expects exactly two expressions")])]
    [_ (ErrAstExpr "parse: ptr-write! expects exactly two expressions")]))

(define (parse-ast-ptr-offset [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons ptr offset-tail _)
      (match (box-get offset-tail)
        [(SpSCons offset end _)
          (match (box-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (box-get ptr))
                [(OkAstExpr parsed-ptr)
                  (match (parse-ast-expr dispatch (box-get offset))
                    [(OkAstExpr parsed-offset)
                      (OkAstExpr (ast-expr-ptr-offset parsed-ptr parsed-offset))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [(ErrAstExpr message) (ErrAstExpr message)])]
            [_ (ErrAstExpr "parse: ptr-offset expects exactly two expressions")])]
        [_ (ErrAstExpr "parse: ptr-offset expects exactly two expressions")])]
    [_ (ErrAstExpr "parse: ptr-offset expects exactly two expressions")]))

(define (parse-ast-ptr-cast-like
  [dispatch : SymI64Env]
  [is-int-to-ptr : bool]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr colon-tail _)
      (match (box-get colon-tail)
        [(SpSCons colon ty-tail _)
          (match (box-get ty-tail)
            [(SpSCons ty end _)
              (match (box-get end)
                [(SpSNil _)
                  (if (sexpr-colon? (spanned-sexpr-form (box-get colon)))
                    (match (parse-ast-expr dispatch (box-get expr))
                      [(OkAstExpr parsed-expr)
                        (match (parse-ast-type
                          dispatch
                          (spanned-sexpr-form (box-get ty)))
                          [(OkAstType parsed-ty)
                            (if is-int-to-ptr
                              (OkAstExpr
                                (ast-expr-int-to-ptr parsed-expr parsed-ty))
                              (OkAstExpr
                                (ast-expr-ptr-cast parsed-expr parsed-ty)))]
                          [(ErrAstType message) (ErrAstExpr message)])]
                      [(ErrAstExpr message) (ErrAstExpr message)])
                    (ErrAstExpr "parse: expected ':' in pointer cast"))]
                [_
                  (ErrAstExpr
                    "parse: pointer cast expects (form expr : pointer-type)")])]
            [_
              (ErrAstExpr
                "parse: pointer cast expects (form expr : pointer-type)")])]
        [_
          (ErrAstExpr "parse: pointer cast expects (form expr : pointer-type)")])]
    [_ (ErrAstExpr "parse: pointer cast expects (form expr : pointer-type)")]))

(define (parse-ast-ptr-to-int [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (box-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (box-get expr))
            [(OkAstExpr parsed-expr)
              (OkAstExpr (ast-expr-ptr-to-int parsed-expr))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: ptr->int expects exactly one expression")])]
    [_ (ErrAstExpr "parse: ptr->int expects exactly one expression")]))

(define (parse-ast-one-expr
  [dispatch : SymI64Env]
  [rest : SpannedSexpr]
  [name : String]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (box-get end)
        [(SpSNil _) (parse-ast-expr dispatch (box-get expr))]
        [_
          (ErrAstExpr
            (string-append
              "parse: "
              (string-append name " expects exactly one expression")))])]
    [_
      (ErrAstExpr
        (string-append
          "parse: "
          (string-append name " expects exactly one expression")))]))

(define (parse-ast-two-exprs
  [dispatch : SymI64Env]
  [rest : SpannedSexpr]
  [name : String]) : ResultAstExprPair
  (match rest
    [(SpSCons first second-tail _)
      (match (box-get second-tail)
        [(SpSCons second end _)
          (match (box-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (box-get first))
                [(OkAstExpr parsed-first)
                  (match (parse-ast-expr dispatch (box-get second))
                    [(OkAstExpr parsed-second)
                      (OkAstExprPair (AstExprPair parsed-first parsed-second))]
                    [(ErrAstExpr message) (ErrAstExprPair message)])]
                [(ErrAstExpr message) (ErrAstExprPair message)])]
            [_
              (ErrAstExprPair
                (string-append
                  "parse: "
                  (string-append name " expects exactly two expressions")))])]
        [_
          (ErrAstExprPair
            (string-append
              "parse: "
              (string-append name " expects exactly two expressions")))])]
    [_
      (ErrAstExprPair
        (string-append
          "parse: "
          (string-append name " expects exactly two expressions")))]))

(define (parse-ast-string-data [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-one-expr dispatch rest "string-data")
    [(OkAstExpr expr) (OkAstExpr (ast-expr-string-data expr))]
    [(ErrAstExpr message) (ErrAstExpr message)]))

(define (parse-ast-string-from-bytes
  [dispatch : SymI64Env]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-two-exprs dispatch rest "string-from-bytes")
    [(OkAstExprPair pair)
      (OkAstExpr
        (ast-expr-string-from-bytes
          (struct-get pair first)
          (struct-get pair second)))]
    [(ErrAstExprPair message) (ErrAstExpr message)]))

(define (parse-ast-array-data [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-one-expr dispatch rest "array-data")
    [(OkAstExpr expr) (OkAstExpr (ast-expr-array-data expr))]
    [(ErrAstExpr message) (ErrAstExpr message)]))

(define (parse-ast-no-arg-low-level
  [rest : SpannedSexpr]
  [name : String]
  [expr : AstExpr]) : ResultAstExpr
  (match rest
    [(SpSNil _) (OkAstExpr expr)]
    [_
      (ErrAstExpr
        (string-append "parse: " (string-append name " expects no arguments")))]))

(define (parse-ast-cpuid-like
  [dispatch : SymI64Env]
  [tag : i64]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-two-exprs dispatch rest "cpuid")
    [(OkAstExprPair pair)
      (let
        [leaf : AstExpr (struct-get pair first)]
        [subleaf : AstExpr (struct-get pair second)]
        (cond
          [(= tag (compiler-parse-tag-expr-cpuid-eax))
            (OkAstExpr (ast-expr-cpuid-eax leaf subleaf))]
          [(= tag (compiler-parse-tag-expr-cpuid-ebx))
            (OkAstExpr (ast-expr-cpuid-ebx leaf subleaf))]
          [(= tag (compiler-parse-tag-expr-cpuid-ecx))
            (OkAstExpr (ast-expr-cpuid-ecx leaf subleaf))]
          [else (OkAstExpr (ast-expr-cpuid-edx leaf subleaf))]))]
    [(ErrAstExprPair message) (ErrAstExpr message)]))

(define (parse-ast-xgetbv [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-one-expr dispatch rest "xgetbv")
    [(OkAstExpr expr) (OkAstExpr (ast-expr-xgetbv expr))]
    [(ErrAstExpr message) (ErrAstExpr message)]))

(define (parse-ast-with-region [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSNil _)
      (ErrAstExpr "parse: with-arena requires a region name before its body")]
    [(SpSCons _ _ _)
      (match rest
        [(SpSCons region-node body _)
          (match (box-get region-node)
            [(SpSSym region _)
              (match (box-get body)
                [(SpSNil _)
                  (ErrAstExpr
                    (string-append
                      "parse: with-arena '"
                      (string-append region "' requires a non-empty body")))]
                [_
                  (match (parse-ast-expr-list dispatch (box-get body))
                    [(OkAstExprList exprs)
                      (OkAstExpr (AstExprWithRegion region exprs))]
                    [(ErrAstExprList message) (ErrAstExpr message)])])]
            [_
              (ErrAstExpr "parse: with-arena region name must be an identifier")])]
        [_ (ErrAstExpr "parse: malformed with-arena")])]
    [_ (ErrAstExpr "parse: malformed with-arena")]))

(define (parse-ast-with-escape [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSNil _)
      (ErrAstExpr "parse: with-escape requires a scratch arena before its body")]
    [(SpSCons scratch body _)
      (match (box-get body)
        [(SpSNil _) (ErrAstExpr "parse: with-escape requires a non-empty body")]
        [_
          (match (parse-ast-expr dispatch (box-get scratch))
            [(OkAstExpr parsed-scratch)
              (match (parse-ast-expr-list dispatch (box-get body))
                [(OkAstExprList exprs)
                  (OkAstExpr (ast-expr-with-escape parsed-scratch exprs))]
                [(ErrAstExprList message) (ErrAstExpr message)])]
            [(ErrAstExpr message) (ErrAstExpr message)])])]
    [_ (ErrAstExpr "parse: malformed with-escape")]))

(define (parse-ast-resource-binding-items
  [dispatch : SymI64Env]
  [items : SpannedSexpr]) : ResultAstResourceBinding
  (match items
    [(SpSCons _ _ _)
      (match items
        [(SpSCons name-node rest _)
          (match (box-get name-node)
            [(SpSSym name _)
              (match (box-get rest)
                [(SpSNil _)
                  (ErrAstResourceBinding
                    "parse: with binding is missing initializer")]
                [(SpSCons init tail _)
                  (match (box-get tail)
                    [(SpSNil _)
                      (ErrAstResourceBinding
                        "parse: with binding is missing cleanup function")]
                    [(SpSCons cleanup extra _)
                      (match (box-get extra)
                        [(SpSNil _)
                          (match (parse-ast-expr dispatch (box-get init))
                            [(OkAstExpr parsed-init)
                              (match (parse-ast-expr dispatch (box-get cleanup))
                                [(OkAstExpr parsed-cleanup)
                                  (OkAstResourceBinding
                                    (ast-resource-binding
                                      name
                                      parsed-init
                                      parsed-cleanup))]
                                [(ErrAstExpr message)
                                  (ErrAstResourceBinding message)])]
                            [(ErrAstExpr message)
                              (ErrAstResourceBinding message)])]
                        [_
                          (ErrAstResourceBinding
                            "parse: with binding has too many fields")])]
                    [_ (ErrAstResourceBinding "parse: malformed with binding")])]
                [_ (ErrAstResourceBinding "parse: malformed with binding")])]
            [_
              (ErrAstResourceBinding
                "parse: with binding name must be an identifier")])]
        [_ (ErrAstResourceBinding "parse: malformed with binding")])]
    [_ (ErrAstResourceBinding "parse: malformed with binding")]))

(define (parse-ast-resource-binding
  [dispatch : SymI64Env]
  [binding : SpannedSexpr]) : ResultAstResourceBinding
  (match binding
    [(SpSBracketList items _)
      (parse-ast-resource-binding-items dispatch (box-get items))]
    [_ (ErrAstResourceBinding "parse: with binding must use bracket syntax")]))

(define (parse-ast-resource-binding-list
  [dispatch : SymI64Env]
  [bindings : SpannedSexpr]) : ResultAstResourceBindingList
  (match bindings
    [(SpSNil _) (OkAstResourceBindingList AstResourceBindingNil)]
    [(SpSCons head rest _)
      (match (parse-ast-resource-binding dispatch (box-get head))
        [(OkAstResourceBinding parsed-head)
          (match (parse-ast-resource-binding-list dispatch (box-get rest))
            [(OkAstResourceBindingList parsed-rest)
              (OkAstResourceBindingList
                (ast-resource-binding-cons parsed-head parsed-rest))]
            [(ErrAstResourceBindingList message)
              (ErrAstResourceBindingList message)])]
        [(ErrAstResourceBinding message) (ErrAstResourceBindingList message)])]
    [_ (ErrAstResourceBindingList "parse: malformed with binding list")]))

(define (parse-ast-with-resource [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSNil _)
      (ErrAstExpr "parse: with requires a binding list before its body")]
    [(SpSCons bindings body _)
      (match (box-get bindings)
        [(SpSNil _)
          (ErrAstExpr "parse: with requires a non-empty binding list")]
        [(SpSCons _ _ _)
          (match (box-get body)
            [(SpSNil _) (ErrAstExpr "parse: with requires a non-empty body")]
            [_
              (match (parse-ast-resource-binding-list
                dispatch
                (box-get bindings))
                [(OkAstResourceBindingList parsed-bindings)
                  (match (parse-ast-expr-list dispatch (box-get body))
                    [(OkAstExprList parsed-body)
                      (OkAstExpr
                        (AstExprWithResource parsed-bindings parsed-body))]
                    [(ErrAstExprList message) (ErrAstExpr message)])]
                [(ErrAstResourceBindingList message) (ErrAstExpr message)])])]
        [_ (ErrAstExpr "parse: malformed with binding list")])]
    [_ (ErrAstExpr "parse: malformed with")]))

(define (parse-ast-match-arm [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstMatchArm
  (match s
    [(SpSBracketList items _) (parse-ast-match-arm dispatch (box-get items))]
    [(SpSCons pattern body-tail _)
      (match (box-get body-tail)
        [(SpSCons body end _)
          (match (box-get end)
            [(SpSNil _)
              (match (parse-ast-pattern
                dispatch
                (spanned-sexpr-form (box-get pattern)))
                [(OkAstPattern parsed-pattern)
                  (match (parse-ast-expr dispatch (box-get body))
                    [(OkAstExpr parsed-body)
                      (OkAstMatchArm (ast-match-arm parsed-pattern parsed-body))]
                    [(ErrAstExpr message) (ErrAstMatchArm message)])]
                [(ErrAstPattern message) (ErrAstMatchArm message)])]
            [_ (ErrAstMatchArm "parse: malformed match arm")])]
        [_ (ErrAstMatchArm "parse: malformed match arm")])]
    [_ (ErrAstMatchArm "parse: malformed match arm")]))

(define (parse-ast-match-arm-list [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstMatchArmList
  (match s
    [(SpSNil _) (OkAstMatchArmList AstMatchArmNil)]
    [(SpSCons head tail _)
      (match (parse-ast-match-arm dispatch (box-get head))
        [(OkAstMatchArm parsed-head)
          (match (parse-ast-match-arm-list dispatch (box-get tail))
            [(OkAstMatchArmList parsed-tail)
              (OkAstMatchArmList (ast-match-arm-cons parsed-head parsed-tail))]
            [(ErrAstMatchArmList message) (ErrAstMatchArmList message)])]
        [(ErrAstMatchArm message) (ErrAstMatchArmList message)])]
    [_ (ErrAstMatchArmList "parse: malformed match arm list")]))

(define (parse-ast-match [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons scrutinee arms _)
      (match (parse-ast-expr dispatch (box-get scrutinee))
        [(OkAstExpr parsed-scrutinee)
          (match (parse-ast-match-arm-list dispatch (box-get arms))
            [(OkAstMatchArmList parsed-arms)
              (OkAstExpr (ast-expr-match parsed-scrutinee parsed-arms))]
            [(ErrAstMatchArmList message) (ErrAstExpr message)])]
        [(ErrAstExpr message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed match")]))

(define (parse-ast-foreach-binding
  [dispatch : SymI64Env]
  [binding : SpannedSexpr]
  [body : SpannedSexpr]) : ResultAstExpr
  (match binding
    [(SpSBracketList items _)
      (parse-ast-foreach-binding dispatch (box-get items) body)]
    [(SpSCons index-node colon-tail _)
      (match (box-get index-node)
        [(SpSSym index _)
          (match (box-get colon-tail)
            [(SpSCons colon index-ty-tail _)
              (match (box-get index-ty-tail)
                [(SpSCons index-ty start-tail _)
                  (match (box-get start-tail)
                    [(SpSCons start end-tail _)
                      (match (box-get end-tail)
                        [(SpSCons end finish _)
                          (match (box-get finish)
                            [(SpSNil _)
                              (if (sexpr-colon?
                                (spanned-sexpr-form (box-get colon)))
                                (match (parse-ast-type
                                  dispatch
                                  (spanned-sexpr-form (box-get index-ty)))
                                  [(OkAstType parsed-index-ty)
                                    (match (parse-ast-expr
                                      dispatch
                                      (box-get start))
                                      [(OkAstExpr parsed-start)
                                        (match (parse-ast-expr
                                          dispatch
                                          (box-get end))
                                          [(OkAstExpr parsed-end)
                                            (match (parse-ast-expr
                                              dispatch
                                              body)
                                              [(OkAstExpr parsed-body)
                                                (OkAstExpr
                                                  (ast-expr-foreach
                                                    index
                                                    parsed-index-ty
                                                    parsed-start
                                                    parsed-end
                                                    parsed-body))]
                                              [(ErrAstExpr message)
                                                (ErrAstExpr message)])]
                                          [(ErrAstExpr message)
                                            (ErrAstExpr message)])]
                                      [(ErrAstExpr message)
                                        (ErrAstExpr message)])]
                                  [(ErrAstType message) (ErrAstExpr message)])
                                (ErrAstExpr "parse: expected ':' in foreach"))]
                            [_ (ErrAstExpr "parse: malformed foreach binding")])]
                        [_ (ErrAstExpr "parse: malformed foreach binding")])]
                    [_ (ErrAstExpr "parse: malformed foreach binding")])]
                [_ (ErrAstExpr "parse: malformed foreach binding")])]
            [_ (ErrAstExpr "parse: malformed foreach binding")])]
        [_ (ErrAstExpr "parse: malformed foreach binding")])]
    [_ (ErrAstExpr "parse: malformed foreach binding")]))

(define (parse-ast-foreach [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons binding-list body-tail _)
      (match (box-get binding-list)
        [(SpSCons binding binding-end _)
          (match (box-get binding-end)
            [(SpSNil _)
              (match (box-get body-tail)
                [(SpSCons body end _)
                  (match (box-get end)
                    [(SpSNil _)
                      (parse-ast-foreach-binding
                        dispatch
                        (box-get binding)
                        (box-get body))]
                    [_ (ErrAstExpr "parse: malformed foreach")])]
                [_ (ErrAstExpr "parse: malformed foreach")])]
            [_ (ErrAstExpr "parse: malformed foreach")])]
        [_ (ErrAstExpr "parse: malformed foreach")])]
    [_ (ErrAstExpr "parse: malformed foreach")]))

(define (parse-ast-call
  [dispatch : SymI64Env]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr dispatch head)
    [(OkAstExpr parsed-head)
      (match (parse-ast-expr-list dispatch rest)
        [(OkAstExprList parsed-args)
          (OkAstExpr (ast-expr-call parsed-head parsed-args))]
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

(define (parse-ast-quote-like
  [dispatch : SymI64Env]
  [tag : i64]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (box-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (box-get expr))
            [(OkAstExpr parsed)
              (cond
                [(= tag (compiler-parse-tag-expr-quote))
                  (OkAstExpr (ast-expr-quote parsed))]
                [(= tag (compiler-parse-tag-expr-quasiquote))
                  (OkAstExpr (ast-expr-quasiquote parsed))]
                [(= tag (compiler-parse-tag-expr-unquote))
                  (OkAstExpr (ast-expr-unquote parsed))]
                [else (OkAstExpr (ast-expr-unquote-splicing parsed))])]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: quote form expects exactly one expression")])]
    [_ (ErrAstExpr "parse: quote form expects exactly one expression")]))

(define (parse-ast-list-expr-tag
  [dispatch : SymI64Env]
  [tag : i64]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstExpr
  (cond
    [(= tag (compiler-parse-tag-expr-if)) (parse-ast-if dispatch rest)]
    [(= tag (compiler-parse-tag-expr-let)) (parse-ast-let dispatch rest)]
    [(= tag (compiler-parse-tag-expr-lambda)) (parse-ast-lambda dispatch rest)]
    [(= tag (compiler-parse-tag-expr-while)) (parse-ast-while dispatch rest)]
    [(= tag (compiler-parse-tag-expr-begin)) (parse-ast-begin dispatch rest)]
    [(= tag (compiler-parse-tag-expr-unsafe)) (parse-ast-unsafe dispatch rest)]
    [(= tag (compiler-parse-tag-expr-set)) (parse-ast-set dispatch rest)]
    [(= tag (compiler-parse-tag-expr-ann))
      (parse-ast-ann-like dispatch false rest)]
    [(= tag (compiler-parse-tag-expr-cast))
      (parse-ast-ann-like dispatch true rest)]
    [(= tag (compiler-parse-tag-expr-tuple)) (parse-ast-tuple dispatch rest)]
    [(= tag (compiler-parse-tag-expr-tuple-ref))
      (parse-ast-tuple-ref dispatch rest)]
    [(= tag (compiler-parse-tag-expr-array)) (parse-ast-array dispatch rest)]
    [(= tag (compiler-parse-tag-expr-make-array))
      (parse-ast-make-array dispatch rest)]
    [(= tag (compiler-parse-tag-expr-array-ref))
      (parse-ast-array-ref-like dispatch false rest)]
    [(= tag (compiler-parse-tag-expr-array-set))
      (parse-ast-array-set dispatch rest)]
    [(= tag (compiler-parse-tag-expr-array-push))
      (parse-ast-array-push dispatch rest)]
    [(= tag (compiler-parse-tag-expr-match)) (parse-ast-match dispatch rest)]
    [(= tag (compiler-parse-tag-expr-foreach))
      (parse-ast-foreach dispatch rest)]
    [(= tag (compiler-parse-tag-expr-spmd-reduce))
      (parse-ast-spmd-reduce dispatch rest)]
    [(= tag (compiler-parse-tag-expr-struct-get))
      (parse-ast-struct-get dispatch rest)]
    [(= tag (compiler-parse-tag-expr-comptime))
      (parse-ast-comptime dispatch rest)]
    [(= tag (compiler-parse-tag-expr-type-literal))
      (parse-ast-type-literal dispatch rest)]
    [(= tag (compiler-parse-tag-expr-with-region))
      (parse-ast-with-region dispatch rest)]
    [(= tag (compiler-parse-tag-expr-with-escape))
      (parse-ast-with-escape dispatch rest)]
    [(= tag (compiler-parse-tag-expr-with-resource))
      (parse-ast-with-resource dispatch rest)]
    [(= tag (compiler-parse-tag-expr-quote))
      (parse-ast-quote-like dispatch tag rest)]
    [(= tag (compiler-parse-tag-expr-quasiquote))
      (parse-ast-quote-like dispatch tag rest)]
    [(= tag (compiler-parse-tag-expr-unquote))
      (parse-ast-quote-like dispatch tag rest)]
    [(= tag (compiler-parse-tag-expr-unquote-splicing))
      (parse-ast-quote-like dispatch tag rest)]
    [(= tag (compiler-parse-tag-expr-try)) (parse-ast-try dispatch rest)]
    [(= tag (compiler-parse-tag-expr-return)) (parse-ast-return dispatch rest)]
    [(= tag (compiler-parse-tag-expr-box))
      (parse-ast-box-like dispatch rest false)]
    [(= tag (compiler-parse-tag-expr-box-get))
      (parse-ast-box-like dispatch rest true)]
    [(= tag (compiler-parse-tag-expr-string-data))
      (parse-ast-string-data dispatch rest)]
    [(= tag (compiler-parse-tag-expr-string-from-bytes))
      (parse-ast-string-from-bytes dispatch rest)]
    [(= tag (compiler-parse-tag-expr-array-data))
      (parse-ast-array-data dispatch rest)]
    [(= tag (compiler-parse-tag-expr-program-argc))
      (parse-ast-no-arg-low-level rest "program-argc" (AstExprProgramArgc))]
    [(= tag (compiler-parse-tag-expr-program-argv))
      (parse-ast-no-arg-low-level rest "program-argv" (AstExprProgramArgv))]
    [(= tag (compiler-parse-tag-expr-program-envp))
      (parse-ast-no-arg-low-level rest "program-envp" (AstExprProgramEnvp))]
    [(= tag (compiler-parse-tag-expr-cpuid-eax))
      (parse-ast-cpuid-like dispatch tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-ebx))
      (parse-ast-cpuid-like dispatch tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-ecx))
      (parse-ast-cpuid-like dispatch tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-edx))
      (parse-ast-cpuid-like dispatch tag rest)]
    [(= tag (compiler-parse-tag-expr-xgetbv)) (parse-ast-xgetbv dispatch rest)]
    [(= tag (compiler-parse-tag-expr-ptr-null))
      (parse-ast-ptr-null dispatch rest)]
    [(= tag (compiler-parse-tag-expr-ptr-null-check))
      (parse-ast-ptr-null-check dispatch rest)]
    [(= tag (compiler-parse-tag-decl-comptime-decl))
      (ErrAstExpr
        "parse: comptime-decl is only valid as a top-level declaration")]
    [else (parse-ast-call dispatch head rest)]))

(define (parse-ast-list-expr
  [dispatch : SymI64Env]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match head
    [(SpSSym op _)
      (let
        [tag : i64 (compiler-parse-dispatch-tag dispatch op)]
        (cond
          [(= tag (compiler-parse-tag-expr-ptr-read))
            (parse-ast-ptr-read dispatch rest)]
          [(= tag (compiler-parse-tag-expr-ptr-write))
            (parse-ast-ptr-write dispatch rest)]
          [(= tag (compiler-parse-tag-expr-ptr-offset))
            (parse-ast-ptr-offset dispatch rest)]
          [(= tag (compiler-parse-tag-expr-ptr-cast))
            (parse-ast-ptr-cast-like dispatch false rest)]
          [(= tag (compiler-parse-tag-expr-ptr-to-int))
            (parse-ast-ptr-to-int dispatch rest)]
          [(= tag (compiler-parse-tag-expr-int-to-ptr))
            (parse-ast-ptr-cast-like dispatch true rest)]
          [(= tag (compiler-parse-tag-expr-cond))
            (parse-ast-cond-or-call dispatch head rest)]
          [(ast-unop-tag? tag)
            (parse-ast-unary dispatch (ast-unop-from-tag tag) rest)]
          [(ast-binop-tag? tag)
            (if (and
              (compiler-parse-and-or-binop-tag? tag)
              (not (parse-ast-spanned-list-exactly-two? rest)))
              (parse-ast-call dispatch head rest)
              (parse-ast-binary dispatch (ast-binop-from-tag tag) rest))]
          [(= tag (compiler-parse-tag-ty-ref)) (parse-ast-borrow dispatch rest)]
          [(= tag (compiler-parse-tag-ty-mut-ref))
            (ErrAstExpr
              "parse: mutable borrow expressions are not implemented (#806)")]
          [else (parse-ast-list-expr-tag dispatch tag head rest)]))]
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
        (cond
          [(= tag (compiler-parse-tag-lit-true))
            (OkAstExpr
              (ast-expr-wrap-span (AstExprLiteral (AstLitBool true)) s))]
          [(= tag (compiler-parse-tag-lit-false))
            (OkAstExpr
              (ast-expr-wrap-span (AstExprLiteral (AstLitBool false)) s))]
          [(= tag (compiler-parse-tag-unit))
            (OkAstExpr (ast-expr-wrap-span (AstExprLiteral AstLitUnit) s))]
          [else (OkAstExpr (ast-expr-wrap-span (AstExprVar name) s))]))]
    [(SpSCons head rest _)
      (match (box-get head)
        [(SpSSym op _)
          (if (string-eq op "cfg")
            (match (parse-ast-cfg-expr dispatch (box-get rest))
              [(OkAstExpr parsed) (OkAstExpr (ast-expr-wrap-span parsed s))]
              [(ErrAstExpr message) (ErrAstExpr message)])
            (match (parse-ast-list-expr dispatch (box-get head) (box-get rest))
              [(OkAstExpr parsed) (OkAstExpr (ast-expr-wrap-span parsed s))]
              [(ErrAstExpr message) (ErrAstExpr message)]))]
        [_
          (match (parse-ast-list-expr dispatch (box-get head) (box-get rest))
            [(OkAstExpr parsed) (OkAstExpr (ast-expr-wrap-span parsed s))]
            [(ErrAstExpr message) (ErrAstExpr message)])])]
    [_ (ErrAstExpr "parse: malformed expression")]))

(define (parse-ast-define-value
  [dispatch : SymI64Env]
  [name : String]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons first tail _)
      (match (box-get tail)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (box-get first))
            [(OkAstExpr parsed-value)
              (OkAstDecl (ast-decl-def name AstNoType parsed-value))]
            [(ErrAstExpr message) (ErrAstDecl message)])]
        [(SpSCons ty value-tail _)
          (match (box-get value-tail)
            [(SpSCons value end _)
              (match (box-get end)
                [(SpSNil _)
                  (if (sexpr-colon? (spanned-sexpr-form (box-get first)))
                    (match (parse-ast-type
                      dispatch
                      (spanned-sexpr-form (box-get ty)))
                      [(OkAstType parsed-ty)
                        (match (parse-ast-expr dispatch (box-get value))
                          [(OkAstExpr parsed-value)
                            (OkAstDecl
                              (ast-decl-def
                                name
                                (AstSomeType parsed-ty)
                                parsed-value))]
                          [(ErrAstExpr message) (ErrAstDecl message)])]
                      [(ErrAstType message) (ErrAstDecl message)])
                    (ErrAstDecl "parse: expected ':' in definition"))]
                [_ (ErrAstDecl "parse: malformed value definition")])]
            [_ (ErrAstDecl "parse: malformed value definition")])]
        [_ (ErrAstDecl "parse: malformed value definition")])]
    [_ (ErrAstDecl "parse: malformed value definition")]))

(define (parse-ast-define-fn
  [dispatch : SymI64Env]
  [name : String]
  [params : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons first tail _)
      (match (box-get tail)
        [(SpSNil _)
          (match (parse-ast-param-list dispatch (spanned-sexpr-form params))
            [(OkAstParamList parsed-params)
              (match (parse-ast-expr dispatch (box-get first))
                [(OkAstExpr parsed-body)
                  (OkAstDecl
                    (ast-decl-def-fn name parsed-params (AstTyUnit) parsed-body))]
                [(ErrAstExpr message) (ErrAstDecl message)])]
            [(ErrAstParamList message) (ErrAstDecl message)])]
        [(SpSCons ret body-tail _)
          (match (box-get body-tail)
            [(SpSCons body end _)
              (match (box-get end)
                [(SpSNil _)
                  (if (sexpr-colon? (spanned-sexpr-form (box-get first)))
                    (match (parse-ast-param-list
                      dispatch
                      (spanned-sexpr-form params))
                      [(OkAstParamList parsed-params)
                        (match (parse-ast-type
                          dispatch
                          (spanned-sexpr-form (box-get ret)))
                          [(OkAstType parsed-ret)
                            (match (parse-ast-expr dispatch (box-get body))
                              [(OkAstExpr parsed-body)
                                (OkAstDecl
                                  (ast-decl-def-fn
                                    name
                                    parsed-params
                                    parsed-ret
                                    parsed-body))]
                              [(ErrAstExpr message) (ErrAstDecl message)])]
                          [(ErrAstType message) (ErrAstDecl message)])]
                      [(ErrAstParamList message) (ErrAstDecl message)])
                    (ErrAstDecl "parse: expected ':' in function definition"))]
                [_ (ErrAstDecl "parse: malformed function definition")])]
            [_ (ErrAstDecl "parse: malformed function definition")])]
        [_ (ErrAstDecl "parse: malformed function definition")])]
    [_ (ErrAstDecl "parse: malformed function definition")]))

(define (parse-ast-define [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons head after-name _)
      (match (box-get head)
        [(SpSSym name _)
          (parse-ast-define-value dispatch name (box-get after-name))]
        [(SpSCons name-node params _)
          (match (box-get name-node)
            [(SpSSym name _)
              (parse-ast-define-fn
                dispatch
                name
                (box-get params)
                (box-get after-name))]
            [_ (ErrAstDecl "parse: malformed define")])]
        [_ (ErrAstDecl "parse: malformed define")])]
    [_ (ErrAstDecl "parse: malformed define")]))

(define (parse-ast-defmacro [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons header after-header _)
      (match (box-get header)
        [(SpSCons name-node params _)
          (match (box-get name-node)
            [(SpSSym name _)
              (match (box-get after-header)
                [(SpSCons colon ret-tail _)
                  (match (box-get ret-tail)
                    [(SpSCons ret body-tail _)
                      (match (box-get body-tail)
                        [(SpSCons body end _)
                          (match (box-get end)
                            [(SpSNil _)
                              (if (sexpr-colon?
                                (spanned-sexpr-form (box-get colon)))
                                (match (parse-ast-macro-param-list
                                  dispatch
                                  (spanned-sexpr-form (box-get params)))
                                  [(OkAstMacroParamList parsed-params)
                                    (match (parse-ast-type
                                      dispatch
                                      (spanned-sexpr-form (box-get ret)))
                                      [(OkAstType parsed-ret)
                                        (match (parse-ast-expr
                                          dispatch
                                          (box-get body))
                                          [(OkAstExpr parsed-body)
                                            (OkAstDecl
                                              (ast-decl-def-macro
                                                name
                                                parsed-params
                                                parsed-ret
                                                parsed-body))]
                                          [(ErrAstExpr message)
                                            (ErrAstDecl message)])]
                                      [(ErrAstType message)
                                        (ErrAstDecl message)])]
                                  [(ErrAstMacroParamList message)
                                    (ErrAstDecl message)])
                                (ErrAstDecl
                                  "parse: expected ':' in macro definition"))]
                            [_ (ErrAstDecl "parse: malformed defmacro")])]
                        [_ (ErrAstDecl "parse: malformed defmacro")])]
                    [_ (ErrAstDecl "parse: malformed defmacro")])]
                [_ (ErrAstDecl "parse: malformed defmacro")])]
            [_ (ErrAstDecl "parse: malformed defmacro")])]
        [_ (ErrAstDecl "parse: malformed defmacro")])]
    [_ (ErrAstDecl "parse: malformed defmacro")]))

(define (parse-ast-extern-abi-tail [tail : Sexpr]) : ResultAstExternAbi
  (match tail
    [(SCons name-node rest)
      (match (box-get name-node)
        [(SSym name)
          (match (box-get rest)
            [(SNil)
              (if (string-eq name "c")
                (OkAstExternAbi (AstExternAbiC))
                (ErrAstExternAbi
                  (string-append "parse: unknown extern ABI " name)))]
            [(SCons fixed-node end)
              (match (box-get end)
                [(SNil)
                  (match (box-get fixed-node)
                    [(SInt fixed-count)
                      (if (string-eq name "c-varargs")
                        (if (>= fixed-count 0)
                          (OkAstExternAbi (AstExternAbiCVarargs fixed-count))
                          (ErrAstExternAbi
                            "parse: extern c-varargs fixed argument count must be nonnegative"))
                        (ErrAstExternAbi
                          (string-append "parse: unknown extern ABI " name)))]
                    [_
                      (ErrAstExternAbi "parse: malformed extern :abi metadata")])]
                [_ (ErrAstExternAbi "parse: malformed extern :abi metadata")])]
            [_ (ErrAstExternAbi "parse: malformed extern :abi metadata")])]
        [_ (ErrAstExternAbi "parse: malformed extern :abi metadata")])]
    [_ (ErrAstExternAbi "parse: malformed extern :abi metadata")]))

(define (parse-ast-extern-string-tail [key : String] [tail : Sexpr]) : ResultAstExternSymbol
  (match tail
    [(SCons value-node end)
      (match (box-get end)
        [(SNil)
          (match (box-get value-node)
            [(SStr value)
              (if (> (string-length value) 0)
                (OkAstExternSymbol value)
                (ErrAstExternSymbol
                  (string-append
                    "parse: extern "
                    (string-append key " must not be empty"))))]
            [_
              (ErrAstExternSymbol
                (string-append
                  "parse: malformed extern "
                  (string-append key " metadata")))])]
        [_
          (ErrAstExternSymbol
            (string-append
              "parse: malformed extern "
              (string-append key " metadata")))])]
    [_
      (ErrAstExternSymbol
        (string-append
          "parse: malformed extern "
          (string-append key " metadata")))]))

(define (parse-ast-extern-symbol-tail [tail : Sexpr]) : ResultAstExternSymbol
  (parse-ast-extern-string-tail ":symbol" tail))

(define (parse-ast-extern-items
  [dispatch : SymI64Env]
  [items : SpannedSexpr]
  [abi : AstExternAbi]
  [symbol : String]
  [link-inputs : AstExternLinkInputList]
  [seen-abi : bool]
  [seen-symbol : bool]) : ResultAstExternParts
  (match items
    [(SpSCons head tail _)
      (if (sexpr-colon? (spanned-sexpr-form (box-get head)))
        (match (box-get tail)
          [(SpSCons ty end _)
            (match (box-get end)
              [(SpSNil _)
                (match (parse-ast-type
                  dispatch
                  (spanned-sexpr-form (box-get ty)))
                  [(OkAstType parsed-ty)
                    (OkAstExternParts
                      (AstExternMetadata abi symbol link-inputs)
                      parsed-ty)]
                  [(ErrAstType message) (ErrAstExternParts message)])]
              [_ (ErrAstExternParts "parse: malformed extern")])]
          [_ (ErrAstExternParts "parse: malformed extern")])
        (match (spanned-sexpr-form (box-get head))
          [(SCons key-node after-key)
            (match (box-get key-node)
              [(SSym key)
                (cond
                  [(string-eq key ":abi")
                    (if seen-abi
                      (ErrAstExternParts
                        "parse: duplicate extern :abi metadata")
                      (match (parse-ast-extern-abi-tail (box-get after-key))
                        [(OkAstExternAbi parsed-abi)
                          (parse-ast-extern-items
                            dispatch
                            (box-get tail)
                            parsed-abi
                            symbol
                            link-inputs
                            true
                            seen-symbol)]
                        [(ErrAstExternAbi message) (ErrAstExternParts message)]))]
                  [(string-eq key ":symbol")
                    (if seen-symbol
                      (ErrAstExternParts
                        "parse: duplicate extern :symbol metadata")
                      (match (parse-ast-extern-symbol-tail (box-get after-key))
                        [(OkAstExternSymbol parsed-symbol)
                          (parse-ast-extern-items
                            dispatch
                            (box-get tail)
                            abi
                            parsed-symbol
                            link-inputs
                            seen-abi
                            true)]
                        [(ErrAstExternSymbol message)
                          (ErrAstExternParts message)]))]
                  [(string-eq key ":link-lib")
                    (match (parse-ast-extern-string-tail
                      ":link-lib"
                      (box-get after-key))
                      [(OkAstExternSymbol value)
                        (parse-ast-extern-items
                          dispatch
                          (box-get tail)
                          abi
                          symbol
                          (ast-extern-link-input-list-append
                            link-inputs
                            (AstExternLinkLib value))
                          seen-abi
                          seen-symbol)]
                      [(ErrAstExternSymbol message) (ErrAstExternParts message)])]
                  [(string-eq key ":link-search")
                    (match (parse-ast-extern-string-tail
                      ":link-search"
                      (box-get after-key))
                      [(OkAstExternSymbol value)
                        (parse-ast-extern-items
                          dispatch
                          (box-get tail)
                          abi
                          symbol
                          (ast-extern-link-input-list-append
                            link-inputs
                            (AstExternLinkSearch value))
                          seen-abi
                          seen-symbol)]
                      [(ErrAstExternSymbol message) (ErrAstExternParts message)])]
                  [(string-eq key ":link-arg")
                    (match (parse-ast-extern-string-tail
                      ":link-arg"
                      (box-get after-key))
                      [(OkAstExternSymbol value)
                        (parse-ast-extern-items
                          dispatch
                          (box-get tail)
                          abi
                          symbol
                          (ast-extern-link-input-list-append
                            link-inputs
                            (AstExternLinkArg value))
                          seen-abi
                          seen-symbol)]
                      [(ErrAstExternSymbol message) (ErrAstExternParts message)])]
                  [(compiler-parse-metadata-key? key)
                    (ErrAstExternParts
                      (string-append "parse: unknown extern metadata " key))]
                  [else (ErrAstExternParts "parse: expected ':' in extern")])]
              [_ (ErrAstExternParts "parse: expected ':' in extern")])]
          [_ (ErrAstExternParts "parse: expected ':' in extern")]))]
    [_ (ErrAstExternParts "parse: malformed extern")]))

(define (parse-ast-extern [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons name-node after-name _)
      (match (box-get name-node)
        [(SpSSym name _)
          (match (parse-ast-extern-items
            dispatch
            (box-get after-name)
            (AstExternAbiC)
            name
            AstExternLinkInputNil
            false
            false)
            [(OkAstExternParts metadata parsed-ty)
              (OkAstDecl (AstDeclExtern name metadata parsed-ty))]
            [(ErrAstExternParts message) (ErrAstDecl message)])]
        [_ (ErrAstDecl "parse: malformed extern")])]
    [_ (ErrAstDecl "parse: malformed extern")]))

(define (parse-ast-defenum [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons name-node variants _)
      (match (box-get name-node)
        [(SpSSym name _)
          (match (parse-ast-defenum-items
            dispatch
            (box-get variants)
            AstLifetimeNil
            false
            false)
            [(OkAstEnumDefParts lifetimes parsed-variants)
              (match parsed-variants
                [(AstVariantDefNil)
                  (ErrAstDecl "parse: defenum needs at least one variant")]
                [_
                  (match lifetimes
                    [(AstLifetimeNil)
                      (OkAstDecl (AstDeclDefEnum name parsed-variants))]
                    [_
                      (OkAstDecl
                        (AstDeclDefEnumLifetimes name lifetimes parsed-variants))])])]
            [(ErrAstEnumDefParts message) (ErrAstDecl message)])]
        [_ (ErrAstDecl "parse: malformed defenum")])]
    [_ (ErrAstDecl "parse: malformed defenum")]))

(define (parse-ast-defstruct [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons name-node fields _)
      (match (box-get name-node)
        [(SpSSym name _)
          (match (parse-ast-defstruct-items
            dispatch
            (box-get fields)
            AstLifetimeNil
            (AstStructReprDefault)
            (AstStructNoCleanup)
            false
            false
            false
            false)
            [(OkAstStructDefParts lifetimes repr cleanup parsed-fields)
              (match parsed-fields
                [(AstFieldDefNil)
                  (ErrAstDecl "parse: defstruct needs at least one field")]
                [_
                  (match lifetimes
                    [(AstLifetimeNil)
                      (OkAstDecl
                        (AstDeclDefStruct name repr cleanup parsed-fields))]
                    [_
                      (OkAstDecl
                        (AstDeclDefStructLifetimes
                          name
                          lifetimes
                          repr
                          cleanup
                          parsed-fields))])])]
            [(ErrAstStructDefParts message) (ErrAstDecl message)])]
        [_ (ErrAstDecl "parse: malformed defstruct")])]
    [_ (ErrAstDecl "parse: malformed defstruct")]))

(define (parse-ast-defdispatch [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons name-node variants _)
      (match (box-get name-node)
        [(SpSSym name _)
          (match (parse-ast-dispatch-variant-list (box-get variants))
            [(OkAstDispatchVariantList parsed-variants)
              (match parsed-variants
                [(AstDispatchVariantNil)
                  (ErrAstDecl "parse: defdispatch needs at least one variant")]
                [_ (OkAstDecl (AstDeclDefDispatch name parsed-variants))])]
            [(ErrAstDispatchVariantList message) (ErrAstDecl message)])]
        [_ (ErrAstDecl "parse: malformed defdispatch")])]
    [_ (ErrAstDecl "parse: malformed defdispatch")]))

(define (parse-ast-module [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons name-node end _)
      (match (box-get end)
        [(SpSNil _)
          (match (box-get name-node)
            [(SpSSym name _) (OkAstDecl (AstDeclModule name))]
            [_ (ErrAstDecl "parse: malformed module")])]
        [_ (ErrAstDecl "parse: malformed module")])]
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
    [(SpSCons as-node alias-tail _)
      (match (box-get as-node)
        [(SpSSym as-name _)
          (match (box-get alias-tail)
            [(SpSCons alias-node end _)
              (match (box-get end)
                [(SpSNil _)
                  (match (box-get alias-node)
                    [(SpSSym alias _)
                      (if (or
                        (string-eq as-name "as")
                        (string-eq as-name ":as"))
                        (parse-ast-import-spec
                          path
                          module-name
                          (AstSomeImportAlias alias))
                        (ErrAstDecl "parse: malformed import"))]
                    [_ (ErrAstDecl "parse: malformed import")])]
                [_ (ErrAstDecl "parse: malformed import")])]
            [_ (ErrAstDecl "parse: malformed import")])]
        [_ (ErrAstDecl "parse: malformed import")])]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-import-module-tail [path : String] [tail : SpannedSexpr]) : ResultAstDecl
  (match tail
    [(SpSCons module-name-node after-module _)
      (match (box-get module-name-node)
        [(SpSSym module-name _)
          (match (box-get after-module)
            [(SpSNil _)
              (parse-ast-import-spec
                path
                (AstSomeModuleName module-name)
                AstNoImportAlias)]
            [_
              (parse-ast-import-alias
                path
                (AstSomeModuleName module-name)
                (box-get after-module))])]
        [_ (ErrAstDecl "parse: malformed import")])]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-import-tail [path : String] [tail : SpannedSexpr]) : ResultAstDecl
  (match tail
    [(SpSNil _) (parse-ast-import-spec path AstNoModuleName AstNoImportAlias)]
    [(SpSCons head-node after-head _)
      (match (box-get head-node)
        [(SpSSym head _)
          (if (string-eq head "as")
            (parse-ast-import-alias path AstNoModuleName tail)
            (if (string-eq head "module")
              (parse-ast-import-module-tail path (box-get after-head))
              (ErrAstDecl "parse: malformed import")))]
        [_ (ErrAstDecl "parse: malformed import")])]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-import [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons path-node tail _)
      (match (box-get path-node)
        [(SpSStr path _) (parse-ast-import-tail path (box-get tail))]
        [_ (ErrAstDecl "parse: malformed import")])]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-include-str [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSNil _) (ErrAstDecl "parse: include-str expects name and string path")]
    [(SpSCons name-node tail _)
      (match (box-get name-node)
        [(SpSSym name _)
          (match (box-get tail)
            [(SpSCons path-node after-path _)
              (match (box-get path-node)
                [(SpSStr path _)
                  (match (box-get after-path)
                    [(SpSNil _) (OkAstDecl (AstDeclIncludeStr name path))]
                    [_
                      (ErrAstDecl
                        "parse: include-str expects exactly two operands")])]
                [_ (ErrAstDecl "parse: include-str path must be a string")])]
            [(SpSNil _)
              (ErrAstDecl "parse: include-str expects name and string path")]
            [_ (ErrAstDecl "parse: include-str expects exactly two operands")])]
        [_ (ErrAstDecl "parse: include-str name must be a symbol")])]
    [_ (ErrAstDecl "parse: malformed include-str")]))

(define (parse-ast-export-item [item : SpannedSexpr]) : ResultAstExportItem
  (match item
    [(SpSCons kind-node rest _)
      (match (box-get kind-node)
        [(SpSSym kind _)
          (cond
            [(string-eq kind "value")
              (match (box-get rest)
                [(SpSCons name-node end _)
                  (match (box-get end)
                    [(SpSNil _)
                      (match (box-get name-node)
                        [(SpSSym name _)
                          (OkAstExportItem (AstExportValue name))]
                        [_ (ErrAstExportItem "parse: malformed export item")])]
                    [_ (ErrAstExportItem "parse: malformed export item")])]
                [_ (ErrAstExportItem "parse: malformed export item")])]
            [(string-eq kind "type")
              (match (box-get rest)
                [(SpSCons name-node end _)
                  (match (box-get end)
                    [(SpSNil _)
                      (match (box-get name-node)
                        [(SpSSym name _) (OkAstExportItem (AstExportType name))]
                        [_ (ErrAstExportItem "parse: malformed export item")])]
                    [_ (ErrAstExportItem "parse: malformed export item")])]
                [_ (ErrAstExportItem "parse: malformed export item")])]
            [(string-eq kind "macro")
              (match (box-get rest)
                [(SpSCons name-node end _)
                  (match (box-get end)
                    [(SpSNil _)
                      (match (box-get name-node)
                        [(SpSSym name _)
                          (OkAstExportItem (AstExportMacro name))]
                        [_ (ErrAstExportItem "parse: malformed export item")])]
                    [_ (ErrAstExportItem "parse: malformed export item")])]
                [_ (ErrAstExportItem "parse: malformed export item")])]
            [(string-eq kind "constructor")
              (match (box-get rest)
                [(SpSCons name-node end _)
                  (match (box-get end)
                    [(SpSNil _)
                      (match (box-get name-node)
                        [(SpSSym name _)
                          (OkAstExportItem (AstExportConstructor name))]
                        [_ (ErrAstExportItem "parse: malformed export item")])]
                    [_ (ErrAstExportItem "parse: malformed export item")])]
                [_ (ErrAstExportItem "parse: malformed export item")])]
            [(string-eq kind "field")
              (match (box-get rest)
                [(SpSCons type-node field-tail _)
                  (match (box-get field-tail)
                    [(SpSCons field-node end _)
                      (match (box-get end)
                        [(SpSNil _)
                          (match (box-get type-node)
                            [(SpSSym type-name _)
                              (match (box-get field-node)
                                [(SpSSym field-name _)
                                  (OkAstExportItem
                                    (AstExportField type-name field-name))]
                                [_
                                  (ErrAstExportItem
                                    "parse: malformed export item")])]
                            [_
                              (ErrAstExportItem "parse: malformed export item")])]
                        [_ (ErrAstExportItem "parse: malformed export item")])]
                    [_ (ErrAstExportItem "parse: malformed export item")])]
                [_ (ErrAstExportItem "parse: malformed export item")])]
            [(string-eq kind "variant")
              (match (box-get rest)
                [(SpSCons name-node end _)
                  (match (box-get end)
                    [(SpSNil _)
                      (match (box-get name-node)
                        [(SpSSym name _)
                          (OkAstExportItem (AstExportVariant name))]
                        [_ (ErrAstExportItem "parse: malformed export item")])]
                    [_ (ErrAstExportItem "parse: malformed export item")])]
                [_ (ErrAstExportItem "parse: malformed export item")])]
            [else (ErrAstExportItem "parse: unknown export item kind")])]
        [_ (ErrAstExportItem "parse: malformed export item")])]
    [_ (ErrAstExportItem "parse: malformed export item")]))

(define (parse-ast-export-item-list [items : SpannedSexpr]) : ResultAstExportItemList
  (match items
    [(SpSNil _) (OkAstExportItemList AstExportItemNil)]
    [(SpSCons item rest _)
      (match (parse-ast-export-item (box-get item))
        [(OkAstExportItem parsed)
          (match (parse-ast-export-item-list (box-get rest))
            [(OkAstExportItemList parsed-rest)
              (OkAstExportItemList (ast-export-item-cons parsed parsed-rest))]
            [(ErrAstExportItemList message) (ErrAstExportItemList message)])]
        [(ErrAstExportItem message) (ErrAstExportItemList message)])]
    [_ (ErrAstExportItemList "parse: malformed export item")]))

(define (parse-ast-export [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSNil _) (ErrAstDecl "parse: export needs at least one item")]
    [_
      (match (parse-ast-export-item-list rest)
        [(OkAstExportItemList items) (OkAstDecl (AstDeclExport items))]
        [(ErrAstExportItemList message) (ErrAstDecl message)])]))

(define (parse-ast-test-body [exprs : AstExprList]) : AstExpr
  (match exprs
    [(AstExprCons only rest)
      (let
        [only : AstExpr (box-get only)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil) only]
          [_ (AstExprBegin exprs)]))]
    [_ (AstExprBegin exprs)]))

(define (parse-ast-test
  [dispatch : SymI64Env]
  [rest : SpannedSexpr]
  [form-span : AstSourceSpan]) : ResultAstDecl
  (match rest
    [(SpSCons name-node body-forms _)
      (match (box-get name-node)
        [(SpSSym name _)
          (match (box-get body-forms)
            [(SpSNil _)
              (ErrAstDecl "parse: test needs at least one expression")]
            [_
              (match (parse-ast-expr-list dispatch (box-get body-forms))
                [(OkAstExprList exprs)
                  (OkAstDecl
                    (ast-decl-test name (parse-ast-test-body exprs) form-span))]
                [(ErrAstExprList message) (ErrAstDecl message)])])]
        [_ (ErrAstDecl "parse: malformed test")])]
    [_ (ErrAstDecl "parse: malformed test")]))

(define (parse-ast-comptime-decl-payload-message) : String
  "parse: comptime-decl accepts only defstruct, defenum, or define")

(define (parse-ast-generated-decl-meta
  [dispatch : SymI64Env]
  [meta : SpannedSexpr]) : ResultAstGeneratedDeclMeta
  (match meta
    [(SpSCons head-node meta-rest _)
      (match (box-get head-node)
        [(SpSSym head _)
          (if (string-eq head ":generated")
            (match (box-get meta-rest)
              [(SpSCons generator-node item-tail _)
                (match (box-get generator-node)
                  [(SpSSym generator-name _)
                    (match (box-get item-tail)
                      [(SpSCons item-node arg-key-forms _)
                        (match (box-get item-node)
                          [(SpSSym item-name _)
                            (match (parse-ast-expr-list
                              dispatch
                              (box-get arg-key-forms))
                              [(OkAstExprList arg-keys)
                                (OkAstGeneratedDeclMeta
                                  (AstSomeGeneratedDeclMeta
                                    generator-name
                                    item-name
                                    arg-keys
                                    ""))]
                              [(ErrAstExprList message)
                                (ErrAstGeneratedDeclMeta message)])]
                          [_
                            (ErrAstGeneratedDeclMeta
                              "parse: :generated metadata expects generator name, item name, and argument key expressions")])]
                      [_
                        (ErrAstGeneratedDeclMeta
                          "parse: :generated metadata expects generator name, item name, and argument key expressions")])]
                  [_
                    (ErrAstGeneratedDeclMeta
                      "parse: :generated metadata expects generator name, item name, and argument key expressions")])]
              [_
                (ErrAstGeneratedDeclMeta
                  "parse: :generated metadata expects generator name, item name, and argument key expressions")])
            (ErrAstGeneratedDeclMeta
              "parse: comptime-decl metadata must be :generated"))]
        [_
          (ErrAstGeneratedDeclMeta
            "parse: comptime-decl metadata must be :generated")])]
    [_
      (ErrAstGeneratedDeclMeta
        "parse: comptime-decl metadata must be :generated")]))

(define (parse-ast-comptime-decl-payload
  [dispatch : SymI64Env]
  [template : SpannedSexpr]) : ResultAstDecl
  (match template
    [(SpSCons head-node template-rest _)
      (match (box-get head-node)
        [(SpSSym head _)
          (let
            [tag : i64 (compiler-parse-dispatch-tag dispatch head)]
            (cond
              [(= tag (compiler-parse-tag-decl-define))
                (parse-ast-define dispatch (box-get template-rest))]
              [(= tag (compiler-parse-tag-decl-defenum))
                (parse-ast-defenum dispatch (box-get template-rest))]
              [(= tag (compiler-parse-tag-decl-defstruct))
                (parse-ast-defstruct dispatch (box-get template-rest))]
              [else (ErrAstDecl (parse-ast-comptime-decl-payload-message))]))]
        [_ (ErrAstDecl (parse-ast-comptime-decl-payload-message))])]
    [_ (ErrAstDecl (parse-ast-comptime-decl-payload-message))]))

(define (parse-ast-comptime-decl-with-meta
  [dispatch : SymI64Env]
  [meta : AstGeneratedDeclMeta]
  [template : SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-comptime-decl-payload dispatch template)
    [(OkAstDecl decl) (OkAstDecl (ast-decl-comptime-decl-with-meta meta decl))]
    [(ErrAstDecl message) (ErrAstDecl message)]))

(define (parse-ast-comptime-decl [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons first tail _)
      (match (box-get tail)
        [(SpSNil _)
          (parse-ast-comptime-decl-with-meta
            dispatch
            AstNoGeneratedDeclMeta
            (box-get first))]
        [(SpSCons template end _)
          (match (box-get end)
            [(SpSNil _)
              (match (parse-ast-generated-decl-meta dispatch (box-get first))
                [(OkAstGeneratedDeclMeta parsed-meta)
                  (parse-ast-comptime-decl-with-meta
                    dispatch
                    parsed-meta
                    (box-get template))]
                [(ErrAstGeneratedDeclMeta message) (ErrAstDecl message)])]
            [_
              (ErrAstDecl
                "parse: comptime-decl expects one template or generated metadata plus one template")])]
        [_
          (ErrAstDecl
            "parse: comptime-decl expects one template or generated metadata plus one template")])]
    [_
      (ErrAstDecl
        "parse: comptime-decl expects one template or generated metadata plus one template")]))

(define (parse-ast-unsafe-decl [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons inner end _)
      (match (box-get end)
        [(SpSNil _)
          (match (parse-ast-decl dispatch (box-get inner))
            [(OkAstDecl decl)
              (match decl
                [(AstDeclDefFn _ _ _ _) (OkAstDecl (ast-decl-unsafe decl))]
                [(AstDeclExtern _ _ _) (OkAstDecl (ast-decl-unsafe decl))]
                [_
                  (ErrAstDecl
                    "parse: unsafe declaration accepts only function define or extern")])]
            [(ErrAstDecl message) (ErrAstDecl message)])]
        [_
          (ErrAstDecl
            "parse: unsafe declaration expects exactly one declaration")])]
    [_ (ErrAstDecl "parse: unsafe declaration expects exactly one declaration")]))

(define (parse-ast-decl [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstDecl
  (match s
    [(SpSCons head-node rest _)
      (match (box-get head-node)
        [(SpSSym head _)
          (let
            [tag : i64 (compiler-parse-dispatch-tag dispatch head)]
            (cond
              [(= tag (compiler-parse-tag-decl-define))
                (parse-ast-define dispatch (box-get rest))]
              [(= tag (compiler-parse-tag-decl-extern))
                (parse-ast-extern dispatch (box-get rest))]
              [(= tag (compiler-parse-tag-decl-defenum))
                (parse-ast-defenum dispatch (box-get rest))]
              [(= tag (compiler-parse-tag-decl-defstruct))
                (parse-ast-defstruct dispatch (box-get rest))]
              [(= tag (compiler-parse-tag-decl-defdispatch))
                (parse-ast-defdispatch (box-get rest))]
              [(= tag (compiler-parse-tag-decl-defmacro))
                (parse-ast-defmacro dispatch (box-get rest))]
              [(= tag (compiler-parse-tag-decl-import))
                (parse-ast-import (box-get rest))]
              [(= tag (compiler-parse-tag-decl-include-str))
                (parse-ast-include-str (box-get rest))]
              [(= tag (compiler-parse-tag-decl-module))
                (parse-ast-module (box-get rest))]
              [(= tag (compiler-parse-tag-decl-export))
                (parse-ast-export (box-get rest))]
              [(= tag (compiler-parse-tag-decl-comptime-decl))
                (parse-ast-comptime-decl dispatch (box-get rest))]
              [(= tag (compiler-parse-tag-expr-unsafe))
                (parse-ast-unsafe-decl dispatch (box-get rest))]
              [(= tag (compiler-parse-tag-decl-test))
                (parse-ast-test
                  dispatch
                  (box-get rest)
                  (ast-source-span-from-source-span (spanned-sexpr-span s)))]
              [(compiler-parse-policy-form? head)
                (ErrAstDecl (compiler-parse-abstraction-policy-message))]
              [else (ErrAstDecl "parse: expected declaration")]))]
        [_ (ErrAstDecl "parse: malformed declaration")])]
    [_ (ErrAstDecl "parse: malformed declaration")]))

(define (parse-ast-decl-maybe [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstMaybeDecl
  (match s
    [(SpSCons head-node rest _)
      (match (box-get head-node)
        [(SpSSym head _)
          (if (string-eq head "cfg")
            (match (box-get rest)
              [(SpSCons pred decl-tail _)
                (match (box-get decl-tail)
                  [(SpSCons decl-form end _)
                    (match (box-get end)
                      [(SpSNil _)
                        (match (compiler-cfg-eval dispatch (box-get pred))
                          [(OkCompilerCfg enabled)
                            (if enabled
                              (parse-ast-decl-maybe
                                dispatch
                                (box-get decl-form))
                              (OkAstNoDecl))]
                          [(ErrCompilerCfg message) (ErrAstMaybeDecl message)])]
                      [_
                        (ErrAstMaybeDecl
                          "parse: cfg declaration expects predicate and declaration")])]
                  [_
                    (ErrAstMaybeDecl
                      "parse: cfg declaration expects predicate and declaration")])]
              [_
                (ErrAstMaybeDecl
                  "parse: cfg declaration expects predicate and declaration")])
            (match (parse-ast-decl dispatch s)
              [(OkAstDecl decl) (OkAstSomeDecl decl)]
              [(ErrAstDecl message) (ErrAstMaybeDecl message)]))]
        [_
          (match (parse-ast-decl dispatch s)
            [(OkAstDecl decl) (OkAstSomeDecl decl)]
            [(ErrAstDecl message) (ErrAstMaybeDecl message)])])]
    [_ (ErrAstMaybeDecl "parse: malformed declaration")]))

(define (parse-ast-program-forms
  [dispatch : SymI64Env]
  [toks : (Array SpannedToken)]
  [cur : (Array i64)]) : ResultAstDeclList
  (if (= (peek-spanned-tag toks cur) (tag-end))
    (OkAstDeclList AstDeclNil)
    (match (read-form-spanned-result toks cur)
      [(OkSpannedSexpr form)
        (match (parse-ast-decl-maybe dispatch form)
          [(OkAstSomeDecl decl)
            (match (parse-ast-program-forms dispatch toks cur)
              [(OkAstDeclList rest) (OkAstDeclList (ast-decl-cons decl rest))]
              [(ErrAstDeclList message) (ErrAstDeclList message)])]
          [(OkAstNoDecl) (parse-ast-program-forms dispatch toks cur)]
          [(ErrAstMaybeDecl message) (ErrAstDeclList message)])]
      [(ErrSpannedSexpr err) (ErrAstDeclList (source-error-message err))])))

(define (parse-ast-program-dispatch) : SymI64Env
  (compiler-parse-dispatch-env))

(define (parse-ast-program-dispatch-with-cfg [cfgs : SymI64Env]) : SymI64Env
  (compiler-cfg-merge (compiler-parse-dispatch-env) cfgs))

(define (parse-ast-program-with-cfg
  [toks : (Array SpannedToken)]
  [cfgs : SymI64Env]) : ResultAstProgram
  (let
    [cur : (Array i64) (make-array i64 1)]
    [dispatch : SymI64Env (parse-ast-program-dispatch-with-cfg cfgs)]
    (begin
      (array-set! cur 0 0)
      (match (parse-ast-program-forms dispatch toks cur)
        [(OkAstDeclList decls) (OkAstProgram (ast-program decls))]
        [(ErrAstDeclList message) (ErrAstProgram message)]))))

(define (parse-ast-program [toks : (Array SpannedToken)]) : ResultAstProgram
  (parse-ast-program-with-cfg toks (compiler-cfg-empty)))

(define (parse-ast-source [src : String]) : ResultAstProgram
  (parse-ast-source-with-cfg src (compiler-cfg-empty)))

(define (parse-ast-source-with-cfg [src : String] [cfgs : SymI64Env]) : ResultAstProgram
  (match (lex-spanned-result src)
    [(OkSpannedTokens toks) (parse-ast-program-with-cfg toks cfgs)]
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
        (match (parse-ast-decl-maybe dispatch spanned-form)
          [(OkAstSomeDecl decl)
            (match (parse-ast-program-forms-diagnostic path dispatch toks cur)
              [(OkAstDeclListDiagnostic rest)
                (OkAstDeclListDiagnostic (ast-decl-cons decl rest))]
              [(ErrAstDeclListDiagnostic diag) (ErrAstDeclListDiagnostic diag)])]
          [(OkAstNoDecl)
            (parse-ast-program-forms-diagnostic path dispatch toks cur)]
          [(ErrAstMaybeDecl message)
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
  (parse-ast-program-diagnostic-with-cfg path toks (compiler-cfg-empty)))

(define (parse-ast-program-diagnostic-with-cfg
  [path : String]
  [toks : (Array SpannedToken)]
  [cfgs : SymI64Env]) : ResultAstProgramDiagnostic
  (let
    [cur : (Array i64) (make-array i64 1)]
    [dispatch : SymI64Env (parse-ast-program-dispatch-with-cfg cfgs)]
    (begin
      (array-set! cur 0 0)
      (match (parse-ast-program-forms-diagnostic path dispatch toks cur)
        [(OkAstDeclListDiagnostic decls)
          (OkAstProgramDiagnostic (ast-program decls))]
        [(ErrAstDeclListDiagnostic diag) (ErrAstProgramDiagnostic diag)]))))

(define (parse-ast-source-diagnostic [path : String] [src : String]) : ResultAstProgramDiagnostic
  (parse-ast-source-diagnostic-with-cfg path src (compiler-cfg-empty)))

(define (parse-ast-source-diagnostic-with-cfg
  [path : String]
  [src : String]
  [cfgs : SymI64Env]) : ResultAstProgramDiagnostic
  (match (lex-spanned-result src)
    [(OkSpannedTokens toks)
      (parse-ast-program-diagnostic-with-cfg path toks cfgs)]
    [(ErrSpannedTokens err)
      (ErrAstProgramDiagnostic (compiler-diagnostic-from-source-error path err))]))

(define (ast-decl-list-count [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons _ rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (+ 1 (ast-decl-list-count rest)))]))

(define (ast-decl-list-tag-sum [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (+ (ast-decl-tag decl) (ast-decl-list-tag-sum rest)))]))

(define (compiler-parse-expr-list-count [exprs : AstExprList]) : i64
  (match exprs
    [(AstExprNil) 0]
    [(AstExprCons _ rest)
      (let
        [rest : AstExprList (box-get rest)]
        (+ 1 (compiler-parse-expr-list-count rest)))]))

(define (compiler-parse-resource-binding-count
  [bindings : AstResourceBindingList]) : i64
  (match bindings
    [(AstResourceBindingNil) 0]
    [(AstResourceBindingCons _ rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (+ 1 (compiler-parse-resource-binding-count rest)))]))

(define (ast-first-import-ok? [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclCons (AstDeclImport (AstImportSpec path _ _)) _)
      (string-eq path "stdlib/test.tl")]
    [_ false]))

(define (ast-first-include-str-ok? [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclCons (AstDeclIncludeStr name path) _)
      (and (string-eq name "payload") (string-eq path "data.txt"))]
    [_ false]))

(define (compiler-parse-module-decl-ok?) : bool
  (match (parse-ast-source "(module std.io)")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclModule name) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil) (string-eq name "std.io")]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-import-metadata-ok?) : bool
  (match (parse-ast-source "(import \"stdlib/io.tl\" module std.io :as io)")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons
              (AstDeclImport
                (AstImportSpec
                  path
                  (AstSomeModuleName module-name)
                  (AstSomeImportAlias alias)))
              rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq path "stdlib/io.tl")
                    (and
                      (string-eq module-name "std.io")
                      (string-eq alias "io")))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-include-str-ok?) : bool
  (match (parse-ast-source "(include-str payload \"data.txt\")")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (ast-first-include-str-ok? decls))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-include-str-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(include-str)"
      "parse: include-str expects name and string path")
    (and
      (compiler-parse-error-ok?
        "(include-str \"name\" \"data.txt\")"
        "parse: include-str name must be a symbol")
      (and
        (compiler-parse-error-ok?
          "(include-str payload data.txt)"
          "parse: include-str path must be a string")
        (and
          (compiler-parse-error-ok?
            "(include-str payload \"data.txt\" extra)"
            "parse: include-str expects exactly two operands")
          (compiler-parse-error-ok?
            "(include-str payload)"
            "parse: include-str expects name and string path"))))))

(define (compiler-parse-export-items-shape-ok? [items : AstExportItemList]) : bool
  (match items
    [(AstExportItemCons (AstExportValue value-name) rest0)
      (let
        [rest0 : AstExportItemList (box-get rest0)]
        (match rest0
          [(AstExportItemCons (AstExportType type-name) rest1)
            (let
              [rest1 : AstExportItemList (box-get rest1)]
              (match rest1
                [(AstExportItemCons (AstExportMacro macro-name) rest2)
                  (let
                    [rest2 : AstExportItemList (box-get rest2)]
                    (match rest2
                      [(AstExportItemCons
                          (AstExportConstructor ctor-name)
                          rest3)
                        (let
                          [rest3 : AstExportItemList (box-get rest3)]
                          (match rest3
                            [(AstExportItemCons
                                (AstExportField field-type field-name)
                                rest4)
                              (let
                                [rest4 : AstExportItemList (box-get rest4)]
                                (match rest4
                                  [(AstExportItemCons
                                      (AstExportVariant variant-name)
                                      rest5)
                                    (let
                                      [rest5 : AstExportItemList
                                        (box-get rest5)]
                                      (match rest5
                                        [(AstExportItemNil)
                                          (and
                                            (string-eq value-name "make-point")
                                            (and
                                              (string-eq type-name "Point")
                                              (and
                                                (string-eq macro-name "and2")
                                                (and
                                                  (string-eq ctor-name "Point")
                                                  (and
                                                    (string-eq
                                                      field-type
                                                      "Point")
                                                    (and
                                                      (string-eq field-name "x")
                                                      (string-eq
                                                        variant-name
                                                        "Some")))))))]
                                        [_ false]))]
                                  [_ false]))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-export-decl-ok?) : bool
  (match (parse-ast-source
    "(export
  (value make-point)
  (type Point)
  (macro and2)
  (constructor Point)
  (field Point x)
  (variant Some))")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclExport items) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil) (compiler-parse-export-items-shape-ok? items)]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-defdispatch-variants-ok?
  [variants : AstDispatchVariantList]) : bool
  (match variants
    [(AstDispatchVariantCons
        (AstDispatchVariant (AstDispatchScalar) scalar-name)
        rest0)
      (let
        [rest0 : AstDispatchVariantList (box-get rest0)]
        (match rest0
          [(AstDispatchVariantCons
              (AstDispatchVariant (AstDispatchAvx2) avx2-name)
              rest1)
            (let
              [rest1 : AstDispatchVariantList (box-get rest1)]
              (match rest1
                [(AstDispatchVariantCons
                    (AstDispatchVariant (AstDispatchAvx512) avx512-name)
                    rest2)
                  (let
                    [rest2 : AstDispatchVariantList (box-get rest2)]
                    (match rest2
                      [(AstDispatchVariantNil)
                        (and
                          (string-eq scalar-name "dot-scalar")
                          (and
                            (string-eq avx2-name "dot-avx2")
                            (string-eq avx512-name "dot-avx512")))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-defdispatch-shape-ok?) : bool
  (match (parse-ast-source
    "(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefDispatch name variants) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq name "dot")
                    (compiler-parse-defdispatch-variants-ok? variants))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-defdispatch-scalar-only-ok?) : bool
  (match (parse-ast-source "(defdispatch id (scalar id-scalar))")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefDispatch name variants) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq name "id")
                    (match variants
                      [(AstDispatchVariantCons
                          (AstDispatchVariant (AstDispatchScalar) scalar-name)
                          variant-rest)
                        (let
                          [variant-rest : AstDispatchVariantList
                            (box-get variant-rest)]
                          (match variant-rest
                            [(AstDispatchVariantNil)
                              (string-eq scalar-name "id-scalar")]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-defdispatch-tests-ok?) : bool
  (and
    (compiler-parse-defdispatch-shape-ok?)
    (and
      (compiler-parse-defdispatch-scalar-only-ok?)
      (and
        (compiler-parse-error-ok?
          "(defdispatch dot)"
          "parse: defdispatch needs at least one variant")
        (and
          (compiler-parse-error-ok?
            "(defdispatch dot (sse2 dot-sse2))"
            "parse: unknown defdispatch ISA sse2")
          (compiler-parse-error-ok?
            "(defdispatch dot (scalar))"
            "parse: malformed defdispatch variant"))))))

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
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclDefFn name _ _ body-box)
            (let
              [body : AstExpr (box-get body-box)]
              (if (string-eq name "main")
                (ast-expr-inner-tag body)
                (ast-main-body-tag rest)))]
          [_ (ast-main-body-tag rest)]))]))

(define (compiler-parse-nested-expr-span-ok?) : bool
  (match (parse-ast-source "(define (main) : i64 (+ 1 (* 2 3)))")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box) _)
            (let
              [body : AstExpr (box-get body-box)]
              (match body
                [(AstExprSpanned inner-box body-span)
                  (let
                    [inner : AstExpr (box-get inner-box)]
                    (match inner
                      [(AstExprBinary _ _ right-box)
                        (let
                          [right : AstExpr (box-get right-box)]
                          (match right
                            [(AstExprSpanned right-inner-box right-span)
                              (let
                                [right-inner : AstExpr
                                  (box-get right-inner-box)]
                                (match right-inner
                                  [(AstExprBinary _ _ _)
                                    (and
                                      (=
                                        (ast-source-span-start-line body-span)
                                        1)
                                      (and
                                        (=
                                          (ast-source-span-start-line
                                            right-span)
                                          1)
                                        (>
                                          (ast-source-span-start-col right-span)
                                          (ast-source-span-start-col body-span))))]
                                  [_ false]))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
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
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn name _ (AstTyF64) body-box) _)
            (let
              [body : AstExpr (box-get body-box)]
              (and
                (string-eq name "main")
                (match (ast-expr-unspan body)
                  [(AstExprLiteral (AstLitFloat text)) (string-eq text "1.5")]
                  [_ false])))]
          [_ false]))]
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
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (+
          (ast-decl-list-count decls)
          (+
            (ast-decl-list-tag-sum decls)
            (+
              (ast-main-body-tag decls)
              (if (ast-first-import-ok? decls)
                1
                0)))))]))

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
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn name _ (AstTyI64) body-box) _)
            (let
              [body : AstExpr (box-get body-box)]
              (and
                (string-eq name "main")
                (match (ast-expr-unspan body)
                  [(AstExprWithRegion region _) (string-eq region "r")]
                  [_ false])))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-raw-pointer-source) : String
  "(extern raw-map : (-> (Ptr i64) (MutPtr (Ptr u8))))")

(define (compiler-parse-type-ptr-u8? [ty : AstType]) : bool
  (match ty
    [(AstTyPtr elem)
      (match (box-get elem)
        [(AstTyU8) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-ptr-i64? [ty : AstType]) : bool
  (match ty
    [(AstTyPtr elem)
      (match (box-get elem)
        [(AstTyI64) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-mut-ptr-u8? [ty : AstType]) : bool
  (match ty
    [(AstTyMutPtr elem)
      (match (box-get elem)
        [(AstTyU8) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-mut-ptr-ptr-u8? [ty : AstType]) : bool
  (match ty
    [(AstTyMutPtr elem) (compiler-parse-type-ptr-u8? (box-get elem))]
    [_ false]))

(define (compiler-parse-type-ref-string? [ty : AstType] [region : String]) : bool
  (match ty
    [(AstTyRef actual inner)
      (and
        (string-eq actual region)
        (match (box-get inner)
          [(AstTyString) true]
          [_ false]))]
    [_ false]))

(define (compiler-parse-type-ref-str? [ty : AstType] [region : String]) : bool
  (match ty
    [(AstTyRef actual inner)
      (and
        (string-eq actual region)
        (match (box-get inner)
          [(AstTyStr) true]
          [_ false]))]
    [_ false]))

(define (compiler-parse-type-mut-ref-dyn-array-i64?
  [ty : AstType]
  [region : String]) : bool
  (match ty
    [(AstTyMutRef actual inner)
      (and
        (string-eq actual region)
        (match (box-get inner)
          [(AstTyDynArray elem)
            (match (box-get elem)
              [(AstTyI64) true]
              [_ false])]
          [_ false]))]
    [_ false]))

(define (compiler-parse-extern-metadata-source) : String
  "(extern local-call (:abi c) (:symbol \"foreign_exact\") (:link-lib \"m\") (:link-search \"native/lib\") (:link-arg \"-Wl,--as-needed\") : (-> i64 i64))")

(define (compiler-parse-extern-varargs-metadata-source) : String
  "(extern snprintf (:abi c-varargs 3) (:symbol \"snprintf\") : (-> (MutPtr u8) i64 (Ptr u8) f64 i32))")

(define (compiler-parse-raw-pointer-ops-source) : String
  "(define (main [p : (MutPtr i64)] [n : u64]) : u64
  (unsafe
    (ptr-write! p (ptr-read p))
    (ptr->int (ptr-cast (ptr-offset (int->ptr n : (MutPtr i64)) 1) : (Ptr i64)))))")

(define (compiler-parse-raw-pointer-ok?) : bool
  (match (parse-ast-source (compiler-parse-raw-pointer-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclExtern name _ ty) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq name "raw-map")
                    (match ty
                      [(AstTyFunc args ret)
                        (match args
                          [(AstTypeCons first tail)
                            (let
                              [first : AstType (box-get first)]
                              [tail : AstTypeList (box-get tail)]
                              (and
                                (compiler-parse-type-ptr-i64? first)
                                (match tail
                                  [(AstTypeNil)
                                    (compiler-parse-type-mut-ptr-ptr-u8?
                                      (box-get ret))]
                                  [_ false])))]
                          [_ false])]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-extern-link-inputs-ok?
  [inputs : AstExternLinkInputList]) : bool
  (match inputs
    [(AstExternLinkInputCons (AstExternLinkLib lib) rest0)
      (let
        [rest0 : AstExternLinkInputList (box-get rest0)]
        (match rest0
          [(AstExternLinkInputCons (AstExternLinkSearch dir) rest1)
            (let
              [rest1 : AstExternLinkInputList (box-get rest1)]
              (match rest1
                [(AstExternLinkInputCons (AstExternLinkArg arg-value) rest2)
                  (let
                    [rest2 : AstExternLinkInputList (box-get rest2)]
                    (match rest2
                      [(AstExternLinkInputNil)
                        (and
                          (string-eq lib "m")
                          (and
                            (string-eq dir "native/lib")
                            (string-eq arg-value "-Wl,--as-needed")))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-extern-metadata-ok?) : bool
  (match (parse-ast-source (compiler-parse-extern-metadata-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclExtern name metadata ty) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq name "local-call")
                    (and
                      (string-eq
                        (ast-extern-metadata-symbol metadata)
                        "foreign_exact")
                      (and
                        (ast-extern-abi-c? (ast-extern-metadata-abi metadata))
                        (and
                          (compiler-parse-extern-link-inputs-ok?
                            (ast-extern-metadata-link-inputs metadata))
                          (match ty
                            [(AstTyFunc args ret)
                              (match args
                                [(AstTypeCons first tail)
                                  (let
                                    [first : AstType (box-get first)]
                                    [tail : AstTypeList (box-get tail)]
                                    (and
                                      (match first
                                        [(AstTyI64) true]
                                        [_ false])
                                      (match tail
                                        [(AstTypeNil)
                                          (match (box-get ret)
                                            [(AstTyI64) true]
                                            [_ false])]
                                        [_ false])))]
                                [_ false])]
                            [_ false])))))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-extern-varargs-metadata-ok?) : bool
  (match (parse-ast-source (compiler-parse-extern-varargs-metadata-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclExtern name metadata ty) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq name "snprintf")
                    (and
                      (string-eq
                        (ast-extern-metadata-symbol metadata)
                        "snprintf")
                      (and
                        (match (ast-extern-metadata-abi metadata)
                          [(AstExternAbiCVarargs fixed-count) (= fixed-count 3)]
                          [_ false])
                        (match ty
                          [(AstTyFunc args ret)
                            (match args
                              [(AstTypeCons first rest0)
                                (let
                                  [first : AstType (box-get first)]
                                  [rest0 : AstTypeList (box-get rest0)]
                                  (and
                                    (compiler-parse-type-mut-ptr-u8? first)
                                    (match rest0
                                      [(AstTypeCons second rest1)
                                        (let
                                          [second : AstType (box-get second)]
                                          [rest1 : AstTypeList (box-get rest1)]
                                          (and
                                            (match second
                                              [(AstTyI64) true]
                                              [_ false])
                                            (match rest1
                                              [(AstTypeCons third rest2)
                                                (let
                                                  [third : AstType
                                                    (box-get third)]
                                                  [rest2 : AstTypeList
                                                    (box-get rest2)]
                                                  (and
                                                    (compiler-parse-type-ptr-u8?
                                                      third)
                                                    (match rest2
                                                      [(AstTypeCons
                                                          fourth
                                                          rest3)
                                                        (let
                                                          [fourth : AstType
                                                            (box-get fourth)]
                                                          [rest3 : AstTypeList
                                                            (box-get rest3)]
                                                          (and
                                                            (match fourth
                                                              [(AstTyF64) true]
                                                              [_ false])
                                                            (match rest3
                                                              [(AstTypeNil)
                                                                (match (box-get
                                                                  ret)
                                                                  [(AstTyI32)
                                                                    true]
                                                                  [_ false])]
                                                              [_ false])))]
                                                      [_ false])))]
                                              [_ false])))]
                                      [_ false])))]
                              [_ false])]
                          [_ false]))))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-raw-pointer-ops-ok?) : bool
  (compiler-parse-ok? (compiler-parse-raw-pointer-ops-source)))

(define (compiler-parse-box-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : (Box i64) (box 7))")
    (and
      (compiler-parse-ok? "(define (main [b : (Box i64)]) : i64 (box-get b))")
      (compiler-parse-ok?
        "(define (main) : i64 (with-arena r (let ([b : (in r (Box i64)) (box 7)]) (box-get b))))"))))

(define (compiler-parse-reference-source) : String
  "(define (use [s : (& r String)] [view : (& r str)] [items : (&mut phase (Array i64))]) : unit unit)")

(define (compiler-parse-reference-ok?) : bool
  (match (parse-ast-source (compiler-parse-reference-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ params _ _) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match params
                    [(AstParamCons (AstParam _ first-ty false) rest0)
                      (let
                        [rest0 : AstParamList (box-get rest0)]
                        (and
                          (compiler-parse-type-ref-string? first-ty "r")
                          (match rest0
                            [(AstParamCons (AstParam _ second-ty false) rest1)
                              (let
                                [rest1 : AstParamList (box-get rest1)]
                                (and
                                  (compiler-parse-type-ref-str? second-ty "r")
                                  (match rest1
                                    [(AstParamCons
                                        (AstParam _ third-ty false)
                                        rest2)
                                      (let
                                        [rest2 : AstParamList (box-get rest2)]
                                        (match rest2
                                          [(AstParamNil)
                                            (compiler-parse-type-mut-ref-dyn-array-i64?
                                              third-ty
                                              "phase")]
                                          [_ false]))]
                                    [_ false])))]
                            [_ false])))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-borrow-source) : String
  "(define (main [x : i64]) : i64
  (begin
    (& x)
    (& x x)
    x))")

(define (compiler-parse-borrow-ok?) : bool
  (match (parse-ast-source (compiler-parse-borrow-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box) rest)
            (let
              [body : AstExpr (box-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match (ast-expr-unspan body)
                    [(AstExprBegin exprs)
                      (match exprs
                        [(AstExprCons first rest0)
                          (let
                            [first : AstExpr (box-get first)]
                            [rest0 : AstExprList (box-get rest0)]
                            (match rest0
                              [(AstExprCons second _)
                                (let
                                  [second : AstExpr (box-get second)]
                                  (match (ast-expr-unspan first)
                                    [(AstExprBorrow
                                        AstBorrowLifetimeInferred
                                        first-place-box)
                                      (let
                                        [first-place : AstExpr
                                          (box-get first-place-box)]
                                        (match (ast-expr-unspan first-place)
                                          [(AstExprVar first-name)
                                            (if (string-eq first-name "x")
                                              (match (ast-expr-unspan second)
                                                [(AstExprBorrow
                                                    (AstBorrowLifetimeNamed
                                                      lifetime)
                                                    second-place-box)
                                                  (let
                                                    [second-place : AstExpr
                                                      (box-get second-place-box)]
                                                    (match (ast-expr-unspan
                                                      second-place)
                                                      [(AstExprVar second-name)
                                                        (and
                                                          (string-eq
                                                            lifetime
                                                            "x")
                                                          (string-eq
                                                            second-name
                                                            "x"))]
                                                      [_ false]))]
                                                [_ false])
                                              false)]
                                          [_ false]))]
                                    [_ false]))]
                              [_ false]))]
                        [_ false])]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-try-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (read) : ResultI64 (OkI64 42))
(define (main) : ResultI64 (OkI64 (try (read))))")

(define (compiler-parse-try-ok?) : bool
  (match (parse-ast-source (compiler-parse-try-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons _ rest0)
            (let
              [rest0 : AstDeclList (box-get rest0)]
              (match rest0
                [(AstDeclCons _ rest1)
                  (let
                    [rest1 : AstDeclList (box-get rest1)]
                    (match rest1
                      [(AstDeclCons (AstDeclDefFn _ _ _ body-box) rest2)
                        (let
                          [body : AstExpr (box-get body-box)]
                          [rest2 : AstDeclList (box-get rest2)]
                          (match rest2
                            [(AstDeclNil)
                              (match (ast-expr-unspan body)
                                [(AstExprCall _ args)
                                  (match args
                                    [(AstExprCons arg rest)
                                      (let
                                        [arg : AstExpr (box-get arg)]
                                        [rest : AstExprList (box-get rest)]
                                        (match rest
                                          [(AstExprNil)
                                            (match (ast-expr-unspan arg)
                                              [(AstExprTry _) true]
                                              [_ false])]
                                          [_ false]))]
                                    [_ false])]
                                [_ false])]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-return-source) : String
  "(define (main) : i64 (return 42))")

(define (compiler-parse-return-ok?) : bool
  (match (parse-ast-source (compiler-parse-return-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box) rest)
            (let
              [body : AstExpr (box-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match (ast-expr-unspan body)
                    [(AstExprReturn inner-box)
                      (let
                        [inner : AstExpr (box-get inner-box)]
                        (match (ast-expr-unspan inner)
                          [(AstExprLiteral (AstLitInt 42)) true]
                          [_ false]))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-unit-expr? [expr : AstExpr]) : bool
  (match (ast-expr-unspan expr)
    [(AstExprLiteral AstLitUnit) true]
    [_ false]))

(define (compiler-parse-return-then-unit-begin? [expr : AstExpr]) : bool
  (match (ast-expr-unspan expr)
    [(AstExprBegin exprs)
      (match exprs
        [(AstExprCons first rest0)
          (let
            [first : AstExpr (box-get first)]
            [rest0 : AstExprList (box-get rest0)]
            (match rest0
              [(AstExprCons last rest1)
                (let
                  [last : AstExpr (box-get last)]
                  [rest1 : AstExprList (box-get rest1)]
                  (match rest1
                    [(AstExprNil)
                      (and
                        (match (ast-expr-unspan first)
                          [(AstExprReturn _) true]
                          [_ false])
                        (compiler-parse-unit-expr? last))]
                    [_ false]))]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (compiler-parse-call-head-name? [expr : AstExpr] [name : String]) : bool
  (match (ast-expr-unspan expr)
    [(AstExprVar found) (string-eq found name)]
    [_ false]))

(define (compiler-parse-return-expr? [expr : AstExpr]) : bool
  (match (ast-expr-unspan expr)
    [(AstExprReturn _) true]
    [_ false]))

(define (compiler-parse-guard-call-args-ok? [args : AstExprList]) : bool
  (match args
    [(AstExprCons cond rest0)
      (let
        [cond : AstExpr (box-get cond)]
        [rest0 : AstExprList (box-get rest0)]
        (and
          (compiler-parse-call-head-name? cond "ok")
          (match rest0
            [(AstExprCons body-arg rest1)
              (let
                [body-arg : AstExpr (box-get body-arg)]
                [rest1 : AstExprList (box-get rest1)]
                (and
                  (match rest1
                    [(AstExprNil) true]
                    [_ false])
                  (compiler-parse-return-expr? body-arg)))]
            [_ false])))]
    [_ false]))

(define (compiler-parse-call-arg-count [args : AstExprList]) : i64
  (match args
    [(AstExprNil) 0]
    [(AstExprCons _ rest)
      (let
        [rest : AstExprList (box-get rest)]
        (+ 1 (compiler-parse-call-arg-count rest)))]))

(define (compiler-parse-call-body-ok?
  [source : String]
  [name : String]
  [want-args : i64]
  [check-guard-args : bool]) : bool
  (match (parse-ast-source source)
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box) rest)
            (let
              [body : AstExpr (box-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match (ast-expr-unspan body)
                    [(AstExprCall func-box args)
                      (let
                        [func : AstExpr (box-get func-box)]
                        (and
                          (compiler-parse-call-head-name? func name)
                          (and
                            (= (compiler-parse-call-arg-count args) want-args)
                            (if check-guard-args
                              (compiler-parse-guard-call-args-ok? args)
                              true))))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-guard-forms-ok?) : bool
  (and
    (compiler-parse-call-body-ok?
      "(define (main [ok : bool]) : unit (when ok (return unit)))"
      "when"
      2
      true)
    (compiler-parse-call-body-ok?
      "(define (main [ok : bool]) : unit (unless ok (return unit)))"
      "unless"
      2
      true)))

(define (compiler-parse-flat-cond-call-ok?) : bool
  (compiler-parse-call-body-ok?
    "(define (main) : i64 (cond true 1 0))"
    "cond"
    3
    false))

(define (compiler-parse-and-or-macro-call-candidates-ok?) : bool
  (and
    (compiler-parse-call-body-ok? "(define (main) : bool (and))" "and" 0 false)
    (and
      (compiler-parse-call-body-ok?
        "(define (main [x : bool]) : bool (and x))"
        "and"
        1
        false)
      (and
        (compiler-parse-call-body-ok?
          "(define (main [x : bool] [y : bool] [z : bool]) : bool (and x y z))"
          "and"
          3
          false)
        (compiler-parse-call-body-ok?
          "(define (main [x : bool] [y : bool] [z : bool]) : bool (or x y z))"
          "or"
          3
          false)))))

(define (compiler-parse-comptime-decl-source) : String
  "(comptime-decl (defstruct Point (x i64) (y i64)))
(comptime-decl (defenum Maybe (None) (Some i64)))
(comptime-decl (:generated option-family Option_String \"String\")
  (define option-size : i64 8))
(comptime-decl (:generated function-family make-option-string \"String\")
  (define (make-option [x : i64]) : i64 x))")

(define (compiler-parse-no-generated-meta-ok? [meta : AstGeneratedDeclMeta]) : bool
  (match meta
    [(AstNoGeneratedDeclMeta) true]
    [_ false]))

(define (compiler-parse-generated-meta-ok?
  [meta : AstGeneratedDeclMeta]
  [want-generator : String]
  [want-item : String]
  [want-arg-count : i64]) : bool
  (match meta
    [(AstSomeGeneratedDeclMeta generator-name item-name arg-keys _)
      (and
        (string-eq generator-name want-generator)
        (and
          (string-eq item-name want-item)
          (= (compiler-parse-expr-list-count arg-keys) want-arg-count)))]
    [_ false]))

(define (compiler-parse-comptime-defstruct-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (and
          (compiler-parse-no-generated-meta-ok? meta)
          (match template
            [(AstDeclDefStruct name _ _ fields)
              (and
                (string-eq name "Point")
                (= (compiler-parse-field-count fields) 2))]
            [_ false])))]
    [_ false]))

(define (compiler-parse-comptime-defenum-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (and
          (compiler-parse-no-generated-meta-ok? meta)
          (match template
            [(AstDeclDefEnum name _) (string-eq name "Maybe")]
            [_ false])))]
    [_ false]))

(define (compiler-parse-comptime-define-value-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (and
          (compiler-parse-generated-meta-ok?
            meta
            "option-family"
            "Option_String"
            1)
          (match template
            [(AstDeclDef name _ value-box)
              (let
                [value : AstExpr (box-get value-box)]
                (and
                  (string-eq name "option-size")
                  (match (ast-expr-unspan value)
                    [(AstExprLiteral (AstLitInt actual)) (= actual 8)]
                    [_ false])))]
            [_ false])))]
    [_ false]))

(define (compiler-parse-comptime-define-fn-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (and
          (compiler-parse-generated-meta-ok?
            meta
            "function-family"
            "make-option-string"
            1)
          (match template
            [(AstDeclDefFn name _ (AstTyI64) _) (string-eq name "make-option")]
            [_ false])))]
    [_ false]))

(define (compiler-parse-comptime-decl-ok?) : bool
  (match (parse-ast-source (compiler-parse-comptime-decl-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons first rest1-box)
            (let
              [rest1 : AstDeclList (box-get rest1-box)]
              (match rest1
                [(AstDeclCons second rest2-box)
                  (let
                    [rest2 : AstDeclList (box-get rest2-box)]
                    (match rest2
                      [(AstDeclCons third rest3-box)
                        (let
                          [rest3 : AstDeclList (box-get rest3-box)]
                          (match rest3
                            [(AstDeclCons fourth rest4-box)
                              (let
                                [rest4 : AstDeclList (box-get rest4-box)]
                                (match rest4
                                  [(AstDeclNil)
                                    (and
                                      (= (ast-decl-list-count decls) 4)
                                      (and
                                        (= (ast-decl-list-tag-sum decls) 32)
                                        (and
                                          (compiler-parse-comptime-defstruct-ok?
                                            first)
                                          (and
                                            (compiler-parse-comptime-defenum-ok?
                                              second)
                                            (and
                                              (compiler-parse-comptime-define-value-ok?
                                                third)
                                              (compiler-parse-comptime-define-fn-ok?
                                                fourth))))))]
                                  [_ false]))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-unsafe-decl-source) : String
  "(unsafe (define (danger [x : i64]) : i64 x))
(unsafe (extern raw-call : (-> i64 i64)))")

(define (compiler-parse-unsafe-decl-ok?) : bool
  (match (parse-ast-source (compiler-parse-unsafe-decl-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons first tail)
            (let
              [tail : AstDeclList (box-get tail)]
              (match first
                [(AstDeclUnsafe first-inner-box)
                  (let
                    [first-inner : AstDecl (box-get first-inner-box)]
                    (match first-inner
                      [(AstDeclDefFn name _ (AstTyI64) _)
                        (match tail
                          [(AstDeclCons second AstDeclNil)
                            (match second
                              [(AstDeclUnsafe second-inner-box)
                                (let
                                  [second-inner : AstDecl
                                    (box-get second-inner-box)]
                                  (match second-inner
                                    [(AstDeclExtern extern-name _ extern-ty)
                                      (and
                                        (string-eq name "danger")
                                        (and
                                          (string-eq extern-name "raw-call")
                                          (match extern-ty
                                            [(AstTyFunc _ ret)
                                              (match (box-get ret)
                                                [(AstTyI64) true]
                                                [_ false])]
                                            [_ false])))]
                                    [_ false]))]
                              [_ false])]
                          [_ false])]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-field-count [fields : AstFieldDefList]) : i64
  (match fields
    [(AstFieldDefNil) 0]
    [(AstFieldDefCons _ rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (+ 1 (compiler-parse-field-count rest)))]))

(define (compiler-parse-field-cleanup-score [cleanup : AstFieldCleanup]) : i64
  (match cleanup
    [(AstFieldNoCleanup) 0]
    [(AstFieldCleanupFn _) 10]
    [(AstFieldOwnedCleanup) 100]))

(define (compiler-parse-field-cleanup-list-score [fields : AstFieldDefList]) : i64
  (match fields
    [(AstFieldDefNil) 0]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef _ _ cleanup)
            (+
              (compiler-parse-field-cleanup-score cleanup)
              (compiler-parse-field-cleanup-list-score rest))]))]))

(define (compiler-parse-struct-cleanup-source) : String
  "(defstruct Resource
  (:cleanup close-resource)
  (fd i64 (:cleanup close-fd))
  (child i64 (:owned))
  (status i64))")

(define (compiler-parse-struct-cleanup-ok?) : bool
  (match (parse-ast-source (compiler-parse-struct-cleanup-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefStruct name repr cleanup fields) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq name "Resource")
                    (and
                      (match repr
                        [(AstStructReprDefault) true]
                        [_ false])
                      (and
                        (match cleanup
                          [(AstStructCleanupFn cleanup-name)
                            (string-eq cleanup-name "close-resource")]
                          [_ false])
                        (and
                          (= (compiler-parse-field-count fields) 3)
                          (=
                            (compiler-parse-field-cleanup-list-score fields)
                            110)))))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-comptime-struct-cleanup-source) : String
  "(comptime-decl
  (defstruct Resource
    (:cleanup close-resource)
    (fd i64 (:cleanup close-fd))))")

(define (compiler-parse-comptime-struct-cleanup-ok?) : bool
  (match (parse-ast-source (compiler-parse-comptime-struct-cleanup-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclComptimeDecl _ template-box) rest)
            (let
              [template : AstDecl (box-get template-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match template
                    [(AstDeclDefStruct _ repr cleanup fields)
                      (and
                        (match repr
                          [(AstStructReprDefault) true]
                          [_ false])
                        (and
                          (ast-struct-cleanup? cleanup)
                          (=
                            (compiler-parse-field-cleanup-list-score fields)
                            10)))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-cleanup-metadata-ok?) : bool
  (and
    (compiler-parse-struct-cleanup-ok?)
    (compiler-parse-comptime-struct-cleanup-ok?)))

(define (compiler-parse-repr-c-source) : String
  "(defstruct Stat
  (:repr c)
  (size i64)
  (mtime i64))")

(define (compiler-parse-repr-c-ok?) : bool
  (match (parse-ast-source (compiler-parse-repr-c-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefStruct name repr _ fields) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq name "Stat")
                    (and
                      (ast-struct-repr-c? repr)
                      (= (compiler-parse-field-count fields) 2)))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-comptime-repr-c-source) : String
  "(comptime-decl (defstruct Stat (:repr c) (size i64)))")

(define (compiler-parse-comptime-repr-c-ok?) : bool
  (match (parse-ast-source (compiler-parse-comptime-repr-c-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclComptimeDecl _ template-box) rest)
            (let
              [template : AstDecl (box-get template-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match template
                    [(AstDeclDefStruct _ repr _ fields)
                      (and
                        (ast-struct-repr-c? repr)
                        (= (compiler-parse-field-count fields) 1))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-inline-test-source) : String
  "(test parser-basic
  (+ 1 2)
  3)")

(define (compiler-parse-inline-test-ok?) : bool
  (match (parse-ast-source (compiler-parse-inline-test-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclTest name body-box span) tail)
            (let
              [body : AstExpr (box-get body-box)]
              [tail : AstDeclList (box-get tail)]
              (match tail
                [(AstDeclNil)
                  (and
                    (string-eq name "parser-basic")
                    (and
                      (= (ast-source-span-start-line span) 1)
                      (match (ast-expr-unspan body)
                        [(AstExprBegin exprs)
                          (= (compiler-parse-expr-list-count exprs) 2)]
                        [_ false])))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-comptime-decl-bad-payload-source) : String
  "(comptime-decl (extern x : (-> i64)))")

(define (compiler-parse-comptime-decl-expression-source) : String
  "(define (main) : i64 (comptime-decl (defstruct Point (x i64))))")

(define (compiler-parse-comptime-decl-extra-source) : String
  "(comptime-decl
  (:generated option-family Option_String)
  (defstruct Point (x i64))
  (defenum Maybe (None)))")

(define (compiler-parse-comptime-decl-bad-metadata-source) : String
  "(comptime-decl (:bad option-family Option_String) (defstruct Point (x i64)))")

(define (compiler-parse-comptime-decl-malformed-metadata-source) : String
  "(comptime-decl (:generated option-family) (defstruct Point (x i64)))")

(define (compiler-parse-comptime-decl-invalid-payload-ok? [src : String]) : bool
  (compiler-parse-error-ok? src (parse-ast-comptime-decl-payload-message)))

(define (compiler-parse-comptime-decl-invalid-payloads-ok?) : bool
  (and
    (compiler-parse-comptime-decl-invalid-payload-ok?
      (compiler-parse-comptime-decl-bad-payload-source))
    (and
      (compiler-parse-comptime-decl-invalid-payload-ok?
        "(comptime-decl (defmacro (m [x : bool]) : bool x))")
      (and
        (compiler-parse-comptime-decl-invalid-payload-ok?
          "(comptime-decl (module nested))")
        (and
          (compiler-parse-comptime-decl-invalid-payload-ok?
            "(comptime-decl (import \"x.tl\"))")
          (and
            (compiler-parse-comptime-decl-invalid-payload-ok?
              "(comptime-decl (export (value x)))")
            (and
              (compiler-parse-comptime-decl-invalid-payload-ok?
                "(comptime-decl (cfg feature (define x : i64 1)))")
              (and
                (compiler-parse-comptime-decl-invalid-payload-ok?
                  "(comptime-decl (test t 1))")
                (compiler-parse-comptime-decl-invalid-payload-ok?
                  "(comptime-decl (comptime-decl (defstruct X (x i64))))")))))))))

(define (compiler-parse-malformed-module-source) : String
  "(module)")

(define (compiler-parse-empty-export-source) : String
  "(export)")

(define (compiler-parse-malformed-export-item-source) : String
  "(export (field Point))")

(define (compiler-parse-unknown-export-kind-source) : String
  "(export (namespace x))")

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

(define (compiler-parse-malformed-return-source) : String
  "(define (main) : i64 (return 1 2))")

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

(define (compiler-parse-cleanup-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close) (:cleanup close2) (x i64))"
      "parse: duplicate defstruct :cleanup metadata")
    (and
      (compiler-parse-error-ok?
        "(defstruct Bad (x i64 (:cleanup close-x)))"
        "parse: field cleanup metadata requires struct :cleanup metadata")
      (and
        (compiler-parse-error-ok?
          "(defstruct Bad (:repr c) (:cleanup close) (x i64))"
          "parse: defstruct cannot combine :repr c with :cleanup metadata")
        (and
          (compiler-parse-error-ok?
            "(defstruct Bad (:cleanup close) (:repr c) (x i64))"
            "parse: defstruct cannot combine :repr c with :cleanup metadata")
          (and
            (compiler-parse-error-ok?
              "(defstruct Bad (:cleanup) (x i64))"
              "parse: malformed defstruct :cleanup metadata")
            (and
              (compiler-parse-error-ok?
                "(defstruct Bad (:cleanup close) (x i64 (:cleanup)))"
                "parse: malformed field :cleanup metadata")
              (and
                (compiler-parse-error-ok?
                  "(defstruct Bad (:cleanup close) (x i64 (:cleanup close-x) (:owned)))"
                  "parse: duplicate field cleanup metadata")
                (and
                  (compiler-parse-error-ok?
                    "(defenum Bad (:cleanup close) (A))"
                    "parse: defenum cleanup metadata is reserved")
                  (compiler-parse-error-ok?
                    "(defenum Bad (A i64 (:cleanup close)))"
                    "parse: enum payload cleanup metadata is reserved"))))))))))

(define (compiler-parse-comptime-decl-error-tests-ok?) : bool
  (and
    (compiler-parse-comptime-decl-invalid-payloads-ok?)
    (and
      (compiler-parse-error-ok?
        (compiler-parse-comptime-decl-expression-source)
        "parse: comptime-decl is only valid as a top-level declaration")
      (and
        (compiler-parse-error-ok?
          (compiler-parse-comptime-decl-extra-source)
          "parse: comptime-decl expects one template or generated metadata plus one template")
        (and
          (compiler-parse-error-ok?
            (compiler-parse-comptime-decl-bad-metadata-source)
            "parse: comptime-decl metadata must be :generated")
          (compiler-parse-error-ok?
            (compiler-parse-comptime-decl-malformed-metadata-source)
            "parse: :generated metadata expects generator name, item name, and argument key expressions"))))))

(define (compiler-parse-unsafe-decl-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(unsafe)"
      "parse: unsafe declaration expects exactly one declaration")
    (and
      (compiler-parse-error-ok?
        "(unsafe (define value : i64 1))"
        "parse: unsafe declaration accepts only function define or extern")
      (and
        (compiler-parse-error-ok?
          "(unsafe (defstruct Bad (x i64)))"
          "parse: unsafe declaration accepts only function define or extern")
        (compiler-parse-error-ok?
          "(unsafe (extern a : (-> i64)) (extern b : (-> i64)))"
          "parse: unsafe declaration expects exactly one declaration")))))

(define (compiler-parse-export-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      (compiler-parse-empty-export-source)
      "parse: export needs at least one item")
    (and
      (compiler-parse-error-ok?
        (compiler-parse-malformed-export-item-source)
        "parse: malformed export item")
      (compiler-parse-error-ok?
        (compiler-parse-unknown-export-kind-source)
        "parse: unknown export item kind"))))

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
      (and
        (compiler-parse-error-ok?
          "(define (main [p : (Ptr (Array))]) : unit unit)"
          "parse: malformed array type")
        (and
          (compiler-parse-error-ok?
            "(define (main [p : (Ptr i64)]) : i64 (ptr-read))"
            "parse: ptr-read expects exactly one expression")
          (and
            (compiler-parse-error-ok?
              "(define (main [p : (MutPtr i64)]) : unit (ptr-write! p))"
              "parse: ptr-write! expects exactly two expressions")
            (compiler-parse-error-ok?
              "(define (main [p : (Ptr i64)]) : (Ptr u8) (ptr-cast p (Ptr u8)))"
              "parse: pointer cast expects (form expr : pointer-type)")))))))

(define (compiler-parse-box-error-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-parse-error-ok?
        "(define (main [p : (Box)]) : unit unit)"
        "parse: Box expects exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [p : (Box i64 bool)]) : unit unit)"
        "parse: Box expects exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main) : (Box i64) (box))"
        "parse: box expects exactly one expression")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [b : (Box i64)]) : i64 (box-get b b))"
        "parse: box-get expects exactly one expression")
        unit
        (set! ok false))
      ok)))

(define (compiler-parse-extern-metadata-error-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-parse-error-ok?
        "(extern f (:abi stdcall) : (-> i64))"
        "parse: unknown extern ABI stdcall")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern f (:symbol bad) : (-> i64))"
        "parse: malformed extern :symbol metadata")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern f (:link-lib bad) : (-> i64))"
        "parse: malformed extern :link-lib metadata")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern f (:link-arg \"\") : (-> i64))"
        "parse: extern :link-arg must not be empty")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern f (:abi c) (:abi c) : (-> i64))"
        "parse: duplicate extern :abi metadata")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern f (:abi c-varargs) : (-> i64))"
        "parse: unknown extern ABI c-varargs")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern f (:abi c-varargs -1) : (-> i64))"
        "parse: extern c-varargs fixed argument count must be nonnegative")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern f (:link \"x\") : (-> i64))"
        "parse: unknown extern metadata :link")
        unit
        (set! ok false))
      ok)))

(define (compiler-parse-reference-error-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-parse-error-ok?
        "(define (main [p : (&)]) : unit unit)"
        "parse: & expects lifetime and exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [p : (& r)]) : unit unit)"
        "parse: & expects lifetime and exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [p : (& 1 i64)]) : unit unit)"
        "parse: reference lifetime must be an identifier")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [p : (& r i64 i64)]) : unit unit)"
        "parse: & expects lifetime and exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [p : (&mut phase)]) : unit unit)"
        "parse: &mut expects lifetime and exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [x : i64]) : unit (&))"
        "parse: borrow expects a place or lifetime and place")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [x : i64]) : unit (& x x x))"
        "parse: borrow expects a place or lifetime and place")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [x : i64]) : unit (& 1 x))"
        "parse: borrow lifetime must be an identifier")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [x : i64]) : unit (&mut x))"
        "parse: mutable borrow expressions are not implemented (#806)")
        unit
        (set! ok false))
      ok)))

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
                (and
                  (compiler-parse-error-ok?
                    (compiler-parse-malformed-try-source)
                    "parse: try expects exactly one expression")
                  (compiler-parse-error-ok?
                    (compiler-parse-malformed-return-source)
                    "parse: return expects exactly one expression"))))))))))

(define (compiler-parse-error-tests-ok?) : bool
  (and
    (compiler-parse-special-form-error-tests-ok?)
    (and
      (compiler-parse-comptime-decl-error-tests-ok?)
      (and
        (compiler-parse-unsafe-decl-error-tests-ok?)
        (and
          (compiler-parse-repr-c-error-tests-ok?)
          (and
            (compiler-parse-cleanup-error-tests-ok?)
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
                        (and
                          (compiler-parse-extern-metadata-error-tests-ok?)
                          (and
                            (compiler-parse-box-error-tests-ok?)
                            (compiler-parse-reference-error-tests-ok?)))))))))))))))

;; Top-level declaration parsing (#1072 / #1041): accept value/function `define`,
;; `extern`, `defenum`, `defstruct`, and `import`; reject malformed forms with
;; stable diagnostics. Migrated from src/parser.rs declaration coverage.
(define (compiler-parse-ok? [src : String]) : bool
  (match (parse-ast-source src)
    [(OkAstProgram _) true]
    [(ErrAstProgram _) false]))

(define (compiler-parse-cfg-decl-count-ok?
  [src : String]
  [cfgs : SymI64Env]
  [want : i64]) : bool
  (match (parse-ast-source-with-cfg src cfgs)
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (= (ast-decl-list-count decls) want))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-cfg-error? [src : String] [cfgs : SymI64Env]) : bool
  (match (parse-ast-source-with-cfg src cfgs)
    [(OkAstProgram _) false]
    [(ErrAstProgram _) true]))

(define (compiler-parse-cfg-tests-ok?) : bool
  (let
    [feature-cfg : SymI64Env
      (compiler-cfg-enable (compiler-cfg-empty) "feature")]
    [windows-feature-cfg : SymI64Env
      (compiler-cfg-enable feature-cfg "windows")]
    (and
      (compiler-parse-cfg-decl-count-ok?
        "(cfg feature (define answer : i64 42))"
        (compiler-cfg-empty)
        0)
      (and
        (compiler-parse-cfg-decl-count-ok?
          "(cfg feature (define answer : i64 42))"
          feature-cfg
          1)
        (and
          (compiler-parse-cfg-decl-count-ok?
            "(cfg feature (define))"
            (compiler-cfg-empty)
            0)
          (and
            (compiler-parse-cfg-decl-count-ok?
              "(cfg (all feature windows) (define answer : i64 42))"
              windows-feature-cfg
              1)
            (and
              (compiler-parse-cfg-decl-count-ok?
                "(cfg (any missing feature) (define answer : i64 42))"
                feature-cfg
                1)
              (and
                (compiler-parse-cfg-decl-count-ok?
                  "(cfg (not missing) (define answer : i64 42))"
                  feature-cfg
                  1)
                (and
                  (compiler-parse-cfg-decl-count-ok?
                    "(define (main) : i64 (begin (cfg feature (if)) 42))"
                    (compiler-cfg-empty)
                    1)
                  (and
                    (compiler-parse-cfg-decl-count-ok?
                      "(define (main) : i64 (cfg feature (if) 42))"
                      (compiler-cfg-empty)
                      1)
                    (compiler-parse-cfg-error?
                      "(define (main) : i64 (cfg feature (if) 42))"
                      feature-cfg)))))))))))

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
                (compiler-parse-include-str-ok?)
                (and
                  (compiler-parse-include-str-errors-ok?)
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
                              "parse: malformed import")))))))))))))))

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
            (and
              (compiler-parse-ok? "(define (f) : Point (Point 1 2))")
              (and
                (compiler-parse-ok?
                  "(defstruct RefBox (:lifetimes a) (value (& a i64)))")
                (and
                  (compiler-parse-ok?
                    "(defenum RefOption (:lifetimes a) (SomeRef (& a i64)) (NoRef))")
                  (compiler-parse-ok?
                    "(define (f [box : (RefBox n)]) : (& n i64) (struct-get box value))"))))))))))

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

(define (compiler-parse-with-escape-shape-ok?) : bool
  (match (parse-ast-source
    "(define (main) : String (with-escape (arena-make) (int->string 42)))")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box) rest)
            (let
              [body : AstExpr (box-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match (ast-expr-unspan body)
                    [(AstExprWithEscape scratch-box body-exprs)
                      (let
                        [scratch : AstExpr (box-get scratch-box)]
                        (match (ast-expr-unspan scratch)
                          [(AstExprCall callee-box AstExprNil)
                            (let
                              [callee : AstExpr (box-get callee-box)]
                              (match (ast-expr-unspan callee)
                                [(AstExprVar name)
                                  (and
                                    (string-eq name "arena-make")
                                    (match body-exprs
                                      [(AstExprCons _ tail)
                                        (let
                                          [tail : AstExprList (box-get tail)]
                                          (match tail
                                            [(AstExprNil) true]
                                            [_ false]))]
                                      [_ false]))]
                                [_ false]))]
                          [_ false]))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-with-escape-tests-ok?) : bool
  (and
    (compiler-parse-with-escape-shape-ok?)
    (and
      (compiler-parse-ok?
        "(define (main) : i64 (let ([scratch : i64 (arena-make)]) (with-escape scratch 1 2 3)))")
      (and
        (compiler-parse-error-ok?
          "(define (main) : i64 (with-escape))"
          "parse: with-escape requires a scratch arena before its body")
        (compiler-parse-error-ok?
          "(define (main) : i64 (with-escape (arena-make)))"
          "parse: with-escape requires a non-empty body")))))

(define (compiler-parse-resource-with-source) : String
  "(define (main) : i64
  (with ([h (open-handle) close-handle]
         [tmp (open-temp) close-temp])
    (use h)
    (with ([inner (open-inner tmp) close-inner])
      42)))")

(define (compiler-parse-resource-with-shape-ok?) : bool
  (match (parse-ast-source (compiler-parse-resource-with-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box) rest)
            (let
              [body : AstExpr (box-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match (ast-expr-unspan body)
                    [(AstExprWithResource bindings body-exprs)
                      (and
                        (= (compiler-parse-resource-binding-count bindings) 2)
                        (and
                          (= (compiler-parse-expr-list-count body-exprs) 2)
                          (match body-exprs
                            [(AstExprCons _ tail)
                              (let
                                [tail : AstExprList (box-get tail)]
                                (match tail
                                  [(AstExprCons nested done-box)
                                    (let
                                      [nested : AstExpr (box-get nested)]
                                      [done : AstExprList (box-get done-box)]
                                      (match done
                                        [(AstExprNil)
                                          (match (ast-expr-unspan nested)
                                            [(AstExprWithResource
                                                nested-bindings
                                                nested-body)
                                              (and
                                                (=
                                                  (compiler-parse-resource-binding-count
                                                    nested-bindings)
                                                  1)
                                                (=
                                                  (compiler-parse-expr-list-count
                                                    nested-body)
                                                  1))]
                                            [_ false])]
                                        [_ false]))]
                                  [_ false]))]
                            [_ false])))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
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

(define (compiler-parse-quote-syntax-shape-ok?) : bool
  (match (parse-ast-source
    "(define (mk [e : Expr]) : Expr `(if ,e true false))")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ _ ret-ty body-box) rest)
            (let
              [body : AstExpr (box-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (match ret-ty
                      [(AstTyVar name) (string-eq name "Expr")]
                      [_ false])
                    (match (ast-expr-unspan body)
                      [(AstExprQuasiquote template-box)
                        (let
                          [template : AstExpr (box-get template-box)]
                          (match (ast-expr-unspan template)
                            [(AstExprIf cond-box _ _)
                              (let
                                [cond : AstExpr (box-get cond-box)]
                                (match (ast-expr-unspan cond)
                                  [(AstExprUnquote unquoted-box)
                                    (let
                                      [unquoted : AstExpr
                                        (box-get unquoted-box)]
                                      (match (ast-expr-unspan unquoted)
                                        [(AstExprVar name) (string-eq name "e")]
                                        [_ false]))]
                                  [_ false]))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-quote-syntax-tests-ok?) : bool
  (and
    (compiler-parse-quote-syntax-shape-ok?)
    (and
      (compiler-parse-ok? "(define x : Expr '(+ 1 2))")
      (and
        (compiler-parse-ok? "(define x : Expr `(begin ,@xs))")
        (compiler-parse-error-ok?
          "(define x : Expr (quote))"
          "parse: quote form expects exactly one expression")))))

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
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ params _ _) _)
            (ast-param-list-has-comptime? params)]
          [_ false]))]
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

(define (compiler-parse-defmacro-shape-ok?) : bool
  (match (parse-ast-source
    "(defmacro (all [first : bool] [rest : bool ...]) : bool first)")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefMacro name params (AstTyBool) _) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq name "all")
                    (match params
                      [(AstMacroParamCons
                          (AstMacroParam first (AstTyBool) false)
                          tail)
                        (let
                          [tail : AstMacroParamList (box-get tail)]
                          (match tail
                            [(AstMacroParamCons
                                (AstMacroParam rest (AstTyBool) true)
                                AstMacroParamNil)
                              (and
                                (string-eq first "first")
                                (string-eq rest "rest"))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-defmacro-tests-ok?) : bool
  (and
    (compiler-parse-defmacro-shape-ok?)
    (and
      (compiler-parse-ok?
        "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool (expr-if lhs rhs (expr-bool false)))")
      (compiler-parse-error-ok?
        "(defmacro (bad [rest : bool ...] [x : bool]) : bool rest)"
        "parse: variadic macro operand must be final"))))

(define (compiler-parse-shape-tests-front-ok? [program : AstProgram]) : bool
  (and
    (= (compiler-parse-smoke-score program) 36)
    (and
      (compiler-parse-nested-expr-span-ok?)
      (and
        (compiler-parse-error-span-ok?)
        (and
          (compiler-parse-float-literal-ok?)
          (and (compiler-parse-region-ok?) (compiler-parse-arena-ok?)))))))

(define (compiler-parse-shape-tests-middle-ok?) : bool
  (and
    (compiler-parse-comptime-decl-ok?)
    (and
      (compiler-parse-unsafe-decl-ok?)
      (and
        (compiler-parse-module-decl-ok?)
        (and
          (compiler-parse-import-metadata-ok?)
          (and
            (compiler-parse-export-decl-ok?)
            (and
              (compiler-parse-defdispatch-tests-ok?)
              (and
                (compiler-parse-flat-let-call-body-ok?)
                (and (compiler-parse-inline-test-ok?) (compiler-parse-try-ok?))))))))))

(define (compiler-parse-error-suite-front-ok?) : bool
  (and
    (compiler-parse-error-tests-ok?)
    (and
      (compiler-parse-declaration-tests-ok?)
      (and
        (compiler-parse-let-tests-ok?)
        (and
          (compiler-parse-spmd-tests-ok?)
          (and
            (compiler-parse-pattern-tests-ok?)
            (compiler-parse-pattern-string-char-tests-ok?)))))))

(define (compiler-parse-error-suite-middle-ok?) : bool
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
            (compiler-parse-comptime-param-tests-ok?)))))))

(define (compiler-parse-error-suite-back-ok?) : bool
  (and
    (compiler-parse-defmacro-tests-ok?)
    (and
      (compiler-parse-resource-with-tests-ok?)
      (and
        (compiler-parse-with-escape-tests-ok?)
        (and
          (compiler-parse-quote-syntax-tests-ok?)
          (compiler-parse-export-error-tests-ok?))))))

(define (compiler-parse-smoke-shapes [program : AstProgram]) : unit
  (begin
    (if (compiler-parse-shape-tests-front-ok? program)
      unit
      (panic "parse: compiler AST front shape tests failed"))
    (if (compiler-parse-shape-tests-middle-ok?)
      unit
      (panic "parse: compiler AST middle shape tests failed"))
    (if (compiler-parse-repr-c-ok?)
      unit
      (panic "parse: repr c shape test failed"))
    (if (compiler-parse-cleanup-metadata-ok?)
      unit
      (panic "parse: cleanup metadata shape test failed"))
    (if (compiler-parse-raw-pointer-ok?)
      unit
      (panic "parse: raw pointer shape test failed"))
    (if (compiler-parse-extern-metadata-ok?)
      unit
      (panic "parse: extern metadata shape test failed"))
    (if (compiler-parse-extern-varargs-metadata-ok?)
      unit
      (panic "parse: extern c-varargs metadata shape test failed"))
    (if (compiler-parse-raw-pointer-ops-ok?)
      unit
      (panic "parse: raw pointer ops shape test failed"))
    (if (compiler-parse-box-ok?)
      unit
      (panic "parse: box shape test failed"))
    (if (compiler-parse-reference-ok?)
      unit
      (panic "parse: reference shape test failed"))
    (if (compiler-parse-borrow-ok?)
      unit
      (panic "parse: borrow shape test failed"))
    (if (compiler-parse-resource-with-shape-ok?)
      unit
      (panic "parse: resource with shape test failed"))
    (if (compiler-parse-with-escape-shape-ok?)
      unit
      (panic "parse: with-escape shape test failed"))
    (if (compiler-parse-quote-syntax-shape-ok?)
      unit
      (panic "parse: quote syntax shape test failed"))
    unit))

(define (compiler-parse-smoke-errors) : unit
  (begin
    (if (compiler-parse-error-suite-front-ok?)
      unit
      (panic "parse: front error-path self-tests failed"))
    (if (compiler-parse-error-suite-middle-ok?)
      unit
      (panic "parse: middle error-path self-tests failed"))
    (if (compiler-parse-error-suite-back-ok?)
      unit
      (panic "parse: back error-path self-tests failed"))
    unit))

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
                      (compiler-parse-unsafe-decl-ok?)
                      (and
                        (compiler-parse-module-decl-ok?)
                        (and
                          (compiler-parse-import-metadata-ok?)
                          (and
                            (compiler-parse-export-decl-ok?)
                            (and
                              (compiler-parse-defdispatch-tests-ok?)
                              (and
                                (compiler-parse-flat-let-call-body-ok?)
                                (and
                                  (compiler-parse-inline-test-ok?)
                                  (and
                                    (compiler-parse-try-ok?)
                                    (and
                                      (and
                                        (compiler-parse-return-ok?)
                                        (and
                                          (compiler-parse-guard-forms-ok?)
                                          (and
                                            (compiler-parse-flat-cond-call-ok?)
                                            (compiler-parse-and-or-macro-call-candidates-ok?))))
                                      (and
                                        (compiler-parse-repr-c-ok?)
                                        (and
                                          (compiler-parse-cleanup-metadata-ok?)
                                          (and
                                            (compiler-parse-raw-pointer-ok?)
                                            (and
                                              (compiler-parse-extern-metadata-ok?)
                                              (and
                                                (compiler-parse-raw-pointer-ops-ok?)
                                                (and
                                                  (compiler-parse-box-ok?)
                                                  (and
                                                    (compiler-parse-reference-ok?)
                                                    (and
                                                      (compiler-parse-borrow-ok?)
                                                      (and
                                                        (compiler-parse-resource-with-shape-ok?)
                                                        (compiler-parse-quote-syntax-shape-ok?))))))))))))))))))))))))))
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
                                (and
                                  (compiler-parse-defmacro-tests-ok?)
                                  (and
                                    (compiler-parse-resource-with-tests-ok?)
                                    (and
                                      (compiler-parse-quote-syntax-tests-ok?)
                                      (and
                                        (compiler-parse-export-error-tests-ok?)
                                        (compiler-parse-cfg-tests-ok?)))))))))))))))))
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