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
(import "../stdlib/string.tl")

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

(defenum ResultAstEnumCleanup
  (OkAstEnumCleanup AstEnumCleanup)
  (ErrAstEnumCleanup String))

(defenum ResultAstVariantPayloadCleanup
  (OkAstVariantPayloadCleanup AstVariantPayloadCleanup)
  (ErrAstVariantPayloadCleanup String))

(defenum ResultAstVariantPayloadParts
  (OkAstVariantPayloadParts AstTypeList AstVariantPayloadCleanupList)
  (ErrAstVariantPayloadParts String))

(defenum ResultAstStructDefParts
  (OkAstStructDefParts
    AstLifetimeList
    AstStructRepr
    AstStructCleanup
    AstFieldDefList)
  (ErrAstStructDefParts String))

(defenum ResultAstEnumDefParts
  (OkAstEnumDefParts AstLifetimeList AstEnumCleanup AstVariantDefList)
  (ErrAstEnumDefParts String))

(defenum ResultAstExternAbi
  (OkAstExternAbi AstExternAbi)
  (ErrAstExternAbi String))

(defenum ResultAstExternSymbol
  (OkAstExternSymbol String)
  (ErrAstExternSymbol String))

(defenum ResultAstFnExport
  (OkAstFnExport AstFnExport)
  (ErrAstFnExport String))

(defenum ResultAstExternParts
  (OkAstExternParts AstExternMetadata AstType)
  (ErrAstExternParts String))

(defenum AstExternHeadItem
  (AstExternHeadParam AstType)
  (AstExternHeadVarargsOpen)
  (AstExternHeadVarargsTyped AstType))

(defenum ResultAstExternHeadItem
  (OkAstExternHeadItem AstExternHeadItem)
  (ErrAstExternHeadItem String))

(defenum ResultAstExternHeader
  (OkAstExternHeader String AstTypeList AstExternAbi)
  (ErrAstExternHeader String))

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
  (OkAstLetParts AstLetBindingList i64)
  (ErrAstLetParts String))

(defenum ResultAstMatchArm
  (OkAstMatchArm AstMatchArm)
  (ErrAstMatchArm String))

(defenum ResultAstMatchArmList
  (OkAstMatchArmList AstMatchArmList)
  (ErrAstMatchArmList String))

(defenum ResultAstExpr
  (OkAstExpr i64)
  (ErrAstExpr String))

(defstruct AstExprPair
  (first i64)
  (second i64))

(defenum ResultAstExprPair
  (OkAstExprPair AstExprPair)
  (ErrAstExprPair String))

(defenum ResultAstExprList
  (OkAstExprList AstExprList)
  (ErrAstExprList String))

(defenum ResultAstGeneratedDeclMeta
  (OkAstGeneratedDeclMeta AstGeneratedDeclMeta)
  (ErrAstGeneratedDeclMeta String))

(defenum ResultAstDeclName
  (OkAstDeclName String)
  (ErrAstDeclName String))

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
  (OkAstDecls AstDeclList)
  (ErrAstMaybeDecl String))

(defenum ResultAstDeclList
  (OkAstDeclList AstDeclList)
  (ErrAstDeclList String))

(defenum ResultAstMaybeExpr
  (OkAstNoExpr)
  (OkAstSomeExpr i64)
  (ErrAstMaybeExpr String))

(defenum ResultCompilerCfg
  (OkCompilerCfg bool)
  (ErrCompilerCfg String))

(defenum ResultAstProgram
  (OkAstProgram AstProgram)
  (ErrAstProgram String))

(defenum AstReplItem
  (AstReplDecl AstDecl)
  (AstReplExpr i64))

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
    [(SymI64Bind name-id value rest)
      (sym-i64-bind
        (compiler-cfg-merge base (box-get rest))
        (intern-str name-id)
        value)]))

(define (compiler-cfg-enabled? [dispatch : SymI64Env] [name : String]) : bool
  (sym-i64-contains dispatch (compiler-cfg-key name)))

(define (compiler-cfg-eval-list-all
  [dispatch : SymI64Env]
  [predicates : SpannedSexpr]) : ResultCompilerCfg
  (match predicates
    [(SpSNil _) (OkCompilerCfg true)]
    [(SpSCons head tail _)
      (match (compiler-cfg-eval dispatch (sp-node-get head))
        [(OkCompilerCfg enabled)
          (if enabled
            (compiler-cfg-eval-list-all dispatch (sp-node-get tail))
            (OkCompilerCfg false))]
        [(ErrCompilerCfg message) (ErrCompilerCfg message)])]
    [_ (ErrCompilerCfg "parse: cfg all expects predicates")]))

(define (compiler-cfg-eval-list-any
  [dispatch : SymI64Env]
  [predicates : SpannedSexpr]) : ResultCompilerCfg
  (match predicates
    [(SpSNil _) (OkCompilerCfg false)]
    [(SpSCons head tail _)
      (match (compiler-cfg-eval dispatch (sp-node-get head))
        [(OkCompilerCfg enabled)
          (if enabled
            (OkCompilerCfg true)
            (compiler-cfg-eval-list-any dispatch (sp-node-get tail)))]
        [(ErrCompilerCfg message) (ErrCompilerCfg message)])]
    [_ (ErrCompilerCfg "parse: cfg any expects predicates")]))

(define (compiler-cfg-eval-not
  [dispatch : SymI64Env]
  [predicates : SpannedSexpr]) : ResultCompilerCfg
  (match predicates
    [(SpSCons pred tail _)
      (match (sp-node-get tail)
        [(SpSNil _)
          (match (compiler-cfg-eval dispatch (sp-node-get pred))
            [(OkCompilerCfg enabled) (OkCompilerCfg (not enabled))]
            [(ErrCompilerCfg message) (ErrCompilerCfg message)])]
        [_ (ErrCompilerCfg "parse: cfg not expects exactly one predicate")])]
    [_ (ErrCompilerCfg "parse: cfg not expects exactly one predicate")]))

(define (compiler-cfg-eval [dispatch : SymI64Env] [predicate : SpannedSexpr]) : ResultCompilerCfg
  (match predicate
    [(SpSSym name _) (OkCompilerCfg (compiler-cfg-enabled? dispatch name))]
    [(SpSCons head predicates _)
      (match (sp-node-get head)
        [(SpSSym op _)
          (cond
            [(string-eq op "all")
              (compiler-cfg-eval-list-all dispatch (sp-node-get predicates))]
            [(string-eq op "any")
              (compiler-cfg-eval-list-any dispatch (sp-node-get predicates))]
            [(string-eq op "not")
              (compiler-cfg-eval-not dispatch (sp-node-get predicates))]
            [else
              (ErrCompilerCfg
                "parse: cfg predicate expects a name, all, any, or not")])]
        [_ (ErrCompilerCfg "parse: malformed cfg predicate")])]
    [_ (ErrCompilerCfg "parse: malformed cfg predicate")]))

(define (compiler-parse-abstraction-policy-message) : String
  "parse: TypeLisp does not support source-level generics or traits; use comptime-decl and comptime-generated concrete declarations instead (#893/#913/#970/#902)")

(define (compiler-parse-generic-type-policy-message [name : String]) : String
  (cond
    [(string-eq name "varying")
      "parse: public SPMD varying source types are deferred; varying is inferred inside foreach (#2764)"]
    [(string-eq name "Varying")
      "parse: public SPMD varying source types are deferred; varying is inferred inside foreach (#2764)"]
    [(string-eq name "Vector")
      "parse: public SPMD vector source types are deferred; vector values remain compiler-internal (#2764)"]
    [(string-eq name "vector")
      "parse: public SPMD vector source types are deferred; vector values remain compiler-internal (#2764)"]
    [(string-eq name "Mask")
      "parse: public SPMD mask source types are deferred; masks remain compiler-internal (#2764)"]
    [(string-eq name "mask")
      "parse: public SPMD mask source types are deferred; masks remain compiler-internal (#2764)"]
    [else
      (string-append
        "parse: unknown type constructor "
        (string-append
          name
          "; TypeLisp has no source-level generic type constructors; use comptime-decl and comptime-generated concrete declarations instead (#893/#913/#970/#902)"))]))

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

(define (ast-expr-wrap-span [expr : i64] [s : SpannedSexpr]) : i64
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

(define (compiler-parse-tag-ty-bytes) : i64
  117)

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

(define (compiler-parse-tag-expr-init) : i64
  288)

(define (compiler-parse-tag-expr-spmd-reduce) : i64
  250)

(define (compiler-parse-tag-expr-spmd-scan) : i64
  294)

(define (compiler-parse-tag-expr-spmd-broadcast) : i64
  290)

(define (compiler-parse-tag-expr-try) : i64
  251)

(define (compiler-parse-tag-expr-return) : i64
  270)

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

(define (compiler-parse-tag-expr-ptr-addr-of) : i64
  289)

(define (compiler-parse-tag-expr-box) : i64
  263)

(define (compiler-parse-tag-expr-box-get) : i64
  264)

(define (compiler-parse-tag-expr-box-take) : i64
  292)

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

(define (compiler-parse-tag-expr-syscall) : i64
  287)

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

(define (compiler-parse-tag-expr-with-scratch) : i64
  293)

(define (compiler-parse-tag-expr-in-arena) : i64
  291)

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

(define (compiler-parse-tag-decl-comptime-decls) : i64
  412)

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

(define (compiler-parse-tag-decl-include-bin) : i64
  413)

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
    [e12 : SymI64Env
      (sym-i64-bind e11 "bit-and" (compiler-parse-tag-bin-bit-and))]
    [e13 : SymI64Env
      (sym-i64-bind e12 "bit-or" (compiler-parse-tag-bin-bit-or))]
    [e14 : SymI64Env
      (sym-i64-bind e13 "bit-xor" (compiler-parse-tag-bin-bit-xor))]
    [e15 : SymI64Env (sym-i64-bind e14 "shl" (compiler-parse-tag-bin-shl))]
    (sym-i64-bind e15 "shr" (compiler-parse-tag-bin-shr))))

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
      (set! out (sym-i64-bind out "bytes" (compiler-parse-tag-ty-bytes)))
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
        (sym-i64-bind out "spmd-scan" (compiler-parse-tag-expr-spmd-scan)))
      (set!
        out
        (sym-i64-bind
          out
          "spmd-broadcast"
          (compiler-parse-tag-expr-spmd-broadcast)))
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
        (sym-i64-bind out "with-scratch" (compiler-parse-tag-expr-with-scratch)))
      (set!
        out
        (sym-i64-bind out "in-arena" (compiler-parse-tag-expr-in-arena)))
      (set!
        out
        (sym-i64-bind out "type" (compiler-parse-tag-expr-type-literal)))
      (set! out (sym-i64-bind out "init" (compiler-parse-tag-expr-init)))
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
      (set!
        out
        (sym-i64-bind out "ptr-addr-of" (compiler-parse-tag-expr-ptr-addr-of)))
      (set! out (sym-i64-bind out "box" (compiler-parse-tag-expr-box)))
      (set! out (sym-i64-bind out "box-get" (compiler-parse-tag-expr-box-get)))
      (set!
        out
        (sym-i64-bind out "box-take" (compiler-parse-tag-expr-box-take)))
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
      (set! out (sym-i64-bind out "syscall" (compiler-parse-tag-expr-syscall)))
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
    [e7 : SymI64Env
      (sym-i64-bind
        e6
        "comptime-decls"
        (compiler-parse-tag-decl-comptime-decls))]
    [e8 : SymI64Env (sym-i64-bind e7 "module" (compiler-parse-tag-decl-module))]
    [e9 : SymI64Env (sym-i64-bind e8 "test" (compiler-parse-tag-decl-test))]
    [e10 : SymI64Env
      (sym-i64-bind e9 "defmacro" (compiler-parse-tag-decl-defmacro))]
    [e11 : SymI64Env
      (sym-i64-bind e10 "export" (compiler-parse-tag-decl-export))]
    [e12 : SymI64Env
      (sym-i64-bind e11 "include-str" (compiler-parse-tag-decl-include-str))]
    [e13 : SymI64Env
      (sym-i64-bind e12 "include-bin" (compiler-parse-tag-decl-include-bin))]
    (sym-i64-bind e13 "defdispatch" (compiler-parse-tag-decl-defdispatch))))

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
  (or
    (= tag (compiler-parse-tag-bin-add))
    (= tag (compiler-parse-tag-bin-sub))
    (= tag (compiler-parse-tag-bin-mul))
    (= tag (compiler-parse-tag-bin-div))
    (= tag (compiler-parse-tag-bin-mod))
    (= tag (compiler-parse-tag-bin-eq))
    (= tag (compiler-parse-tag-bin-ne))
    (= tag (compiler-parse-tag-bin-lt))
    (= tag (compiler-parse-tag-bin-le))
    (= tag (compiler-parse-tag-bin-gt))
    (= tag (compiler-parse-tag-bin-ge))
    (= tag (compiler-parse-tag-bin-bit-and))
    (= tag (compiler-parse-tag-bin-bit-or))
    (= tag (compiler-parse-tag-bin-bit-xor))
    (= tag (compiler-parse-tag-bin-shl))
    (= tag (compiler-parse-tag-bin-shr))))

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
    [(= tag (compiler-parse-tag-bin-bit-and)) (AstBinBitAnd)]
    [(= tag (compiler-parse-tag-bin-bit-or)) (AstBinBitOr)]
    [(= tag (compiler-parse-tag-bin-bit-xor)) (AstBinBitXor)]
    [(= tag (compiler-parse-tag-bin-shl)) (AstBinShl)]
    [else (AstBinShr)]))

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
          (<= tag (compiler-parse-tag-ty-bytes)))
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
          [(= tag (compiler-parse-tag-ty-bytes)) (OkAstType (AstTyBytes))]
          [(= tag (compiler-parse-tag-unit)) (OkAstType (AstTyUnit))]
          [(= tag (compiler-parse-tag-ty-never)) (OkAstType (AstTyNever))]
          [(= tag (compiler-parse-tag-ty-expr)) (OkAstType (AstTyExpr))]
          [else (OkAstType (AstTyVar (intern name)))]))]
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
                    (OkAstType (AstTyVarArgs (intern head) lifetimes))]
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
                                        (ast-param name parsed-ty true))]
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
                              (OkAstParam
                                (ast-param first-name parsed-ty false))]
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
                                (ast-macro-param name parsed-ty false))]
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
                                          (ast-macro-param name parsed-ty true))]
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
                          (OkAstFieldCleanup (ast-field-cleanup-fn cleanup-fn))]
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

(define (parse-ast-variant-payload-cleanup [s : Sexpr]) : ResultAstVariantPayloadCleanup
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
                          (OkAstVariantPayloadCleanup
                            (ast-variant-payload-cleanup-fn cleanup-fn))]
                        [_
                          (ErrAstVariantPayloadCleanup
                            "parse: malformed enum payload :cleanup metadata")])]
                    [_
                      (ErrAstVariantPayloadCleanup
                        "parse: malformed enum payload :cleanup metadata")])]
                [_
                  (ErrAstVariantPayloadCleanup
                    "parse: malformed enum payload :cleanup metadata")])]
            [(string-eq key ":owned")
              (match (box-get tail)
                [(SNil)
                  (OkAstVariantPayloadCleanup (AstVariantPayloadOwnedCleanup))]
                [_
                  (ErrAstVariantPayloadCleanup
                    "parse: malformed enum payload :owned metadata")])]
            [(compiler-parse-metadata-key? key)
              (ErrAstVariantPayloadCleanup
                (string-append "parse: unknown enum payload metadata " key))]
            [else
              (ErrAstVariantPayloadCleanup
                "parse: malformed enum payload cleanup metadata")])]
        [_
          (ErrAstVariantPayloadCleanup
            "parse: malformed enum payload cleanup metadata")])]
    [_
      (ErrAstVariantPayloadCleanup
        "parse: malformed enum payload cleanup metadata")]))

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
                        (ast-field-def name parsed-ty (AstFieldNoCleanup)))]
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
                                  (ast-field-def name parsed-ty parsed-cleanup))]
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
              (OkAstStructCleanup (ast-struct-cleanup-fn cleanup-fn))]
            [_
              (ErrAstStructCleanup
                "parse: malformed defstruct :cleanup metadata")])]
        [_ (ErrAstStructCleanup "parse: malformed defstruct :cleanup metadata")])]
    [_ (ErrAstStructCleanup "parse: malformed defstruct :cleanup metadata")]))

(define (parse-ast-defenum-cleanup-tail [tail : Sexpr]) : ResultAstEnumCleanup
  (match tail
    [(SCons cleanup-node end)
      (match (box-get end)
        [(SNil)
          (match (box-get cleanup-node)
            [(SSym cleanup-fn)
              (OkAstEnumCleanup (ast-enum-cleanup-fn cleanup-fn))]
            [_ (ErrAstEnumCleanup "parse: malformed defenum :cleanup metadata")])]
        [_ (ErrAstEnumCleanup "parse: malformed defenum :cleanup metadata")])]
    [_ (ErrAstEnumCleanup "parse: malformed defenum :cleanup metadata")]))

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
      (match (spanned-sexpr-form (sp-node-get head))
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
                            (sp-node-get tail)
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
                              (sp-node-get tail)
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
                              (sp-node-get tail)
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
                    (sp-node-get head)
                    (sp-node-get tail)
                    lifetimes
                    repr
                    cleanup
                    seen-lifetimes
                    seen-repr
                    seen-cleanup)])]
            [_
              (parse-ast-defstruct-field-item
                dispatch
                (sp-node-get head)
                (sp-node-get tail)
                lifetimes
                repr
                cleanup
                seen-lifetimes
                seen-repr
                seen-cleanup)])]
        [_
          (parse-ast-defstruct-field-item
            dispatch
            (sp-node-get head)
            (sp-node-get tail)
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

(define (compiler-parse-metadata-sexpr? [s : Sexpr]) : bool
  (match s
    [(SCons key-node _)
      (match (box-get key-node)
        [(SSym key) (compiler-parse-metadata-key? key)]
        [_ false])]
    [_ false]))

(define (parse-ast-variant-payload-parts
  [dispatch : SymI64Env]
  [s : Sexpr]
  [allow-cleanup : bool]) : ResultAstVariantPayloadParts
  (match s
    [(SNil) (OkAstVariantPayloadParts AstTypeNil AstVariantPayloadCleanupNil)]
    [(SCons ty-node rest)
      (let
        [ty-form : Sexpr (box-get ty-node)]
        [rest-form : Sexpr (box-get rest)]
        (if (compiler-parse-metadata-sexpr? ty-form)
          (ErrAstVariantPayloadParts
            "parse: enum payload cleanup metadata must follow a payload type")
          (match (parse-ast-type dispatch ty-form)
            [(OkAstType parsed-ty)
              (match rest-form
                [(SNil)
                  (OkAstVariantPayloadParts
                    (ast-type-cons parsed-ty AstTypeNil)
                    (ast-variant-payload-cleanup-cons
                      (AstVariantPayloadNoCleanup)
                      AstVariantPayloadCleanupNil))]
                [(SCons cleanup-node after-cleanup)
                  (let
                    [cleanup-form : Sexpr (box-get cleanup-node)]
                    (if (compiler-parse-metadata-sexpr? cleanup-form)
                      (if allow-cleanup
                        (match (parse-ast-variant-payload-cleanup cleanup-form)
                          [(OkAstVariantPayloadCleanup parsed-cleanup)
                            (match (parse-ast-variant-payload-parts
                              dispatch
                              (box-get after-cleanup)
                              allow-cleanup)
                              [(OkAstVariantPayloadParts
                                  parsed-rest
                                  cleanup-rest)
                                (OkAstVariantPayloadParts
                                  (ast-type-cons parsed-ty parsed-rest)
                                  (ast-variant-payload-cleanup-cons
                                    parsed-cleanup
                                    cleanup-rest))]
                              [(ErrAstVariantPayloadParts message)
                                (ErrAstVariantPayloadParts message)])]
                          [(ErrAstVariantPayloadCleanup message)
                            (ErrAstVariantPayloadParts message)])
                        (ErrAstVariantPayloadParts
                          "parse: enum payload cleanup metadata requires enum :cleanup metadata"))
                      (match (parse-ast-variant-payload-parts
                        dispatch
                        rest-form
                        allow-cleanup)
                        [(OkAstVariantPayloadParts parsed-rest cleanup-rest)
                          (OkAstVariantPayloadParts
                            (ast-type-cons parsed-ty parsed-rest)
                            (ast-variant-payload-cleanup-cons
                              (AstVariantPayloadNoCleanup)
                              cleanup-rest))]
                        [(ErrAstVariantPayloadParts message)
                          (ErrAstVariantPayloadParts message)])))]
                [_
                  (ErrAstVariantPayloadParts
                    "parse: malformed enum payload list")])]
            [(ErrAstType message) (ErrAstVariantPayloadParts message)])))]
    [_ (ErrAstVariantPayloadParts "parse: malformed enum payload list")]))

(define (parse-ast-variant-def
  [dispatch : SymI64Env]
  [s : Sexpr]
  [allow-cleanup : bool]) : ResultAstVariantDef
  (match s
    [(SCons name-node fields)
      (match (box-get name-node)
        [(SSym name)
          (if (compiler-parse-metadata-key? name)
            (if (string-eq name ":cleanup")
              (ErrAstVariantDef
                "parse: defenum metadata must appear before variants")
              (ErrAstVariantDef
                (string-append "parse: unknown defenum metadata " name)))
            (match (parse-ast-variant-payload-parts
              dispatch
              (box-get fields)
              allow-cleanup)
              [(OkAstVariantPayloadParts parsed-fields parsed-cleanups)
                (OkAstVariantDef
                  (ast-variant-def name parsed-fields parsed-cleanups))]
              [(ErrAstVariantPayloadParts message) (ErrAstVariantDef message)]))]
        [_ (ErrAstVariantDef "parse: malformed variant definition")])]
    [_ (ErrAstVariantDef "parse: malformed variant definition")]))

(define (parse-ast-variant-def-list
  [dispatch : SymI64Env]
  [s : Sexpr]
  [allow-cleanup : bool]) : ResultAstVariantDefList
  (match s
    [(SNil) (OkAstVariantDefList AstVariantDefNil)]
    [(SCons head tail)
      (match (parse-ast-variant-def dispatch (box-get head) allow-cleanup)
        [(OkAstVariantDef parsed-head)
          (match (parse-ast-variant-def-list
            dispatch
            (box-get tail)
            allow-cleanup)
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
      (match (sp-node-get isa-node)
        [(SpSSym isa-name _)
          (match (sp-node-get rest)
            [(SpSCons fn-node end _)
              (match (sp-node-get end)
                [(SpSNil _)
                  (match (sp-node-get fn-node)
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
      (match (parse-ast-dispatch-variant (sp-node-get head))
        [(OkAstDispatchVariant parsed)
          (match (parse-ast-dispatch-variant-list (sp-node-get rest))
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
  [cleanup : AstEnumCleanup]
  [seen-lifetimes : bool]
  [seen-cleanup : bool]) : ResultAstEnumDefParts
  (match (parse-ast-variant-def
    dispatch
    (spanned-sexpr-form head)
    (ast-enum-cleanup? cleanup))
    [(OkAstVariantDef parsed-variant)
      (match (parse-ast-defenum-items
        dispatch
        tail
        lifetimes
        cleanup
        seen-lifetimes
        seen-cleanup
        true)
        [(OkAstEnumDefParts parsed-lifetimes parsed-cleanup parsed-rest)
          (OkAstEnumDefParts
            parsed-lifetimes
            parsed-cleanup
            (ast-variant-def-cons parsed-variant parsed-rest))]
        [(ErrAstEnumDefParts message) (ErrAstEnumDefParts message)])]
    [(ErrAstVariantDef message) (ErrAstEnumDefParts message)]))

(define (parse-ast-defenum-items
  [dispatch : SymI64Env]
  [items : SpannedSexpr]
  [lifetimes : AstLifetimeList]
  [cleanup : AstEnumCleanup]
  [seen-lifetimes : bool]
  [seen-cleanup : bool]
  [seen-variant : bool]) : ResultAstEnumDefParts
  (match items
    [(SpSNil _) (OkAstEnumDefParts lifetimes cleanup AstVariantDefNil)]
    [(SpSCons head tail _)
      (match (spanned-sexpr-form (sp-node-get head))
        [(SCons key-node after-key)
          (match (box-get key-node)
            [(SSym key)
              (cond
                [(not (compiler-parse-metadata-key? key))
                  (parse-ast-defenum-variant-item
                    dispatch
                    (sp-node-get head)
                    (sp-node-get tail)
                    lifetimes
                    cleanup
                    seen-lifetimes
                    seen-cleanup)]
                [seen-variant
                  (ErrAstEnumDefParts
                    "parse: defenum metadata must appear before variants")]
                [(string-eq key ":lifetimes")
                  (if seen-lifetimes
                    (ErrAstEnumDefParts
                      "parse: duplicate defenum :lifetimes metadata")
                    (match (parse-ast-aggregate-lifetimes-tail
                      (box-get after-key))
                      [(OkAstLifetimeList next-lifetimes)
                        (parse-ast-defenum-items
                          dispatch
                          (sp-node-get tail)
                          next-lifetimes
                          cleanup
                          true
                          seen-cleanup
                          false)]
                      [(ErrAstLifetimeList message)
                        (ErrAstEnumDefParts message)]))]
                [(string-eq key ":cleanup")
                  (if seen-cleanup
                    (ErrAstEnumDefParts
                      "parse: duplicate defenum :cleanup metadata")
                    (match (parse-ast-defenum-cleanup-tail (box-get after-key))
                      [(OkAstEnumCleanup next-cleanup)
                        (parse-ast-defenum-items
                          dispatch
                          (sp-node-get tail)
                          lifetimes
                          next-cleanup
                          seen-lifetimes
                          true
                          false)]
                      [(ErrAstEnumCleanup message) (ErrAstEnumDefParts message)]))]
                [else
                  (ErrAstEnumDefParts
                    (string-append "parse: unknown defenum metadata " key))])]
            [_
              (parse-ast-defenum-variant-item
                dispatch
                (sp-node-get head)
                (sp-node-get tail)
                lifetimes
                cleanup
                seen-lifetimes
                seen-cleanup)])]
        [_
          (parse-ast-defenum-variant-item
            dispatch
            (sp-node-get head)
            (sp-node-get tail)
            lifetimes
            cleanup
            seen-lifetimes
            seen-cleanup)])]
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
          [else (OkAstPattern (ast-pat-binding name))]))]
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
      (match (sp-node-get then-tail)
        [(SpSCons then-expr rest-tail _)
          (match (sp-node-get rest-tail)
            [(SpSNil _)
              (match (compiler-cfg-eval dispatch (sp-node-get pred))
                [(OkCompilerCfg enabled)
                  (if enabled
                    (match (parse-ast-expr dispatch (sp-node-get then-expr))
                      [(OkAstExpr parsed) (OkAstSomeExpr parsed)]
                      [(ErrAstExpr message) (ErrAstMaybeExpr message)])
                    (OkAstNoExpr))]
                [(ErrCompilerCfg message) (ErrAstMaybeExpr message)])]
            [(SpSCons else-expr end _)
              (match (sp-node-get end)
                [(SpSNil _)
                  (match (compiler-cfg-eval dispatch (sp-node-get pred))
                    [(OkCompilerCfg enabled)
                      (match (parse-ast-expr
                        dispatch
                        (if enabled
                          (sp-node-get then-expr)
                          (sp-node-get else-expr)))
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
    [(OkAstNoExpr) (OkAstExpr (ast-node-push (AstExprLiteral AstLitUnit)))]
    [(ErrAstMaybeExpr message) (ErrAstExpr message)]))

(define (parse-ast-expr-list [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstExprList
  (match s
    [(SpSNil _) (OkAstExprList AstExprNil)]
    [(SpSCons head tail _)
      (match (sp-node-get head)
        [(SpSCons op-node cfg-rest _)
          (match (sp-node-get op-node)
            [(SpSSym op _)
              (if (string-eq op "cfg")
                (match (parse-ast-cfg-expr-maybe
                  dispatch
                  (sp-node-get cfg-rest))
                  [(OkAstSomeExpr parsed-head)
                    (match (parse-ast-expr-list dispatch (sp-node-get tail))
                      [(OkAstExprList parsed-tail)
                        (OkAstExprList (ast-expr-cons parsed-head parsed-tail))]
                      [(ErrAstExprList message) (ErrAstExprList message)])]
                  [(OkAstNoExpr)
                    (parse-ast-expr-list dispatch (sp-node-get tail))]
                  [(ErrAstMaybeExpr message) (ErrAstExprList message)])
                (match (parse-ast-expr dispatch (sp-node-get head))
                  [(OkAstExpr parsed-head)
                    (match (parse-ast-expr-list dispatch (sp-node-get tail))
                      [(OkAstExprList parsed-tail)
                        (OkAstExprList (ast-expr-cons parsed-head parsed-tail))]
                      [(ErrAstExprList message) (ErrAstExprList message)])]
                  [(ErrAstExpr message) (ErrAstExprList message)]))]
            [_
              (match (parse-ast-expr dispatch (sp-node-get head))
                [(OkAstExpr parsed-head)
                  (match (parse-ast-expr-list dispatch (sp-node-get tail))
                    [(OkAstExprList parsed-tail)
                      (OkAstExprList (ast-expr-cons parsed-head parsed-tail))]
                    [(ErrAstExprList message) (ErrAstExprList message)])]
                [(ErrAstExpr message) (ErrAstExprList message)])])]
        [_
          (match (parse-ast-expr dispatch (sp-node-get head))
            [(OkAstExpr parsed-head)
              (match (parse-ast-expr-list dispatch (sp-node-get tail))
                [(OkAstExprList parsed-tail)
                  (OkAstExprList (ast-expr-cons parsed-head parsed-tail))]
                [(ErrAstExprList message) (ErrAstExprList message)])]
            [(ErrAstExpr message) (ErrAstExprList message)])])]
    [_ (ErrAstExprList "parse: malformed expression list")]))

(define (parse-ast-call-bracket-clause
  [dispatch : SymI64Env]
  [s : SpannedSexpr]
  [items : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch items)
    [(OkAstExprList parsed-items)
      (OkAstExpr (ast-expr-wrap-span (ast-expr-bracket-clause parsed-items) s))]
    [(ErrAstExprList message) (ErrAstExpr message)]))

(define (parse-ast-call-arg-maybe [dispatch : SymI64Env] [head : SpannedSexpr]) : ResultAstMaybeExpr
  (match head
    [(SpSBracketList items _)
      (match (parse-ast-call-bracket-clause dispatch head (sp-node-get items))
        [(OkAstExpr parsed) (OkAstSomeExpr parsed)]
        [(ErrAstExpr message) (ErrAstMaybeExpr message)])]
    [(SpSCons op-node cfg-rest _)
      (match (sp-node-get op-node)
        [(SpSSym op _)
          (if (string-eq op "cfg")
            (parse-ast-cfg-expr-maybe dispatch (sp-node-get cfg-rest))
            (match (parse-ast-expr dispatch head)
              [(OkAstExpr parsed) (OkAstSomeExpr parsed)]
              [(ErrAstExpr message) (ErrAstMaybeExpr message)]))]
        [_
          (match (parse-ast-expr dispatch head)
            [(OkAstExpr parsed) (OkAstSomeExpr parsed)]
            [(ErrAstExpr message) (ErrAstMaybeExpr message)])])]
    [_
      (match (parse-ast-expr dispatch head)
        [(OkAstExpr parsed) (OkAstSomeExpr parsed)]
        [(ErrAstExpr message) (ErrAstMaybeExpr message)])]))

(define (parse-ast-call-arg-list [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstExprList
  (match s
    [(SpSNil _) (OkAstExprList AstExprNil)]
    [(SpSCons head tail _)
      (match (parse-ast-call-arg-maybe dispatch (sp-node-get head))
        [(OkAstSomeExpr parsed-head)
          (match (parse-ast-call-arg-list dispatch (sp-node-get tail))
            [(OkAstExprList parsed-tail)
              (OkAstExprList (ast-expr-cons parsed-head parsed-tail))]
            [(ErrAstExprList message) (ErrAstExprList message)])]
        [(OkAstNoExpr) (parse-ast-call-arg-list dispatch (sp-node-get tail))]
        [(ErrAstMaybeExpr message) (ErrAstExprList message)])]
    [_ (ErrAstExprList "parse: malformed call argument list")]))

(define (parse-ast-binary
  [dispatch : SymI64Env]
  [op : AstBinOp]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons left right-tail _)
      (match (sp-node-get right-tail)
        [(SpSCons right end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (sp-node-get left))
                [(OkAstExpr parsed-left)
                  (match (parse-ast-expr dispatch (sp-node-get right))
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
      (match (sp-node-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (sp-node-get expr))
            [(OkAstExpr parsed-expr)
              (OkAstExpr (ast-expr-unary op parsed-expr))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: malformed unary expression")])]
    [_ (ErrAstExpr "parse: malformed unary expression")]))

(define (parse-ast-if [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons cond then-tail _)
      (match (sp-node-get then-tail)
        [(SpSCons then-branch else-tail _)
          (match (sp-node-get else-tail)
            [(SpSCons else-branch end _)
              (match (sp-node-get end)
                [(SpSNil _)
                  (match (parse-ast-expr dispatch (sp-node-get cond))
                    [(OkAstExpr parsed-cond)
                      (match (parse-ast-expr dispatch (sp-node-get then-branch))
                        [(OkAstExpr parsed-then)
                          (match (parse-ast-expr
                            dispatch
                            (sp-node-get else-branch))
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

(define (parse-ast-while [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons cond body-tail _)
      (match (sp-node-get body-tail)
        [(SpSCons body end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (sp-node-get cond))
                [(OkAstExpr parsed-cond)
                  (match (parse-ast-expr dispatch (sp-node-get body))
                    [(OkAstExpr parsed-body)
                      (OkAstExpr (ast-expr-while parsed-cond parsed-body))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [(ErrAstExpr message) (ErrAstExpr message)])]
            [_ (ErrAstExpr "parse: malformed while")])]
        [_ (ErrAstExpr "parse: malformed while")])]
    [_ (ErrAstExpr "parse: malformed while")]))

(define (parse-ast-set [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons target-node value-tail _)
      (match (sp-node-get value-tail)
        [(SpSCons value end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (sp-node-get value))
                [(OkAstExpr parsed-value)
                  (match (sp-node-get target-node)
                    [(SpSSym name _)
                      (OkAstExpr (ast-expr-set name parsed-value))]
                    [_
                      (match (parse-ast-expr dispatch (sp-node-get target-node))
                        [(OkAstExpr parsed-target)
                          (match (ast-expr-unspan (ast-node-get parsed-target))
                            [(AstExprStructGet receiver-box field)
                              (OkAstExpr
                                (ast-expr-struct-set-id
                                  receiver-box
                                  field
                                  parsed-value))]
                            [(AstExprBoxGet receiver-box)
                              (OkAstExpr
                                (ast-expr-box-set receiver-box parsed-value))]
                            [_
                              (ErrAstExpr
                                "parse: set! target must be a name, struct field place, or box place")])]
                        [(ErrAstExpr message) (ErrAstExpr message)])])]
                [(ErrAstExpr message) (ErrAstExpr message)])]
            [_ (ErrAstExpr "parse: malformed set!")])]
        [_ (ErrAstExpr "parse: malformed set!")])]
    [_ (ErrAstExpr "parse: malformed set!")]))

(define (parse-ast-ann-like
  [dispatch : SymI64Env]
  [is-cast : bool]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr colon-tail _)
      (match (sp-node-get colon-tail)
        [(SpSCons colon ty-tail _)
          (match (sp-node-get ty-tail)
            [(SpSCons ty end _)
              (match (sp-node-get end)
                [(SpSNil _)
                  (if (sexpr-colon? (spanned-sexpr-form (sp-node-get colon)))
                    (match (parse-ast-expr dispatch (sp-node-get expr))
                      [(OkAstExpr parsed-expr)
                        (match (parse-ast-type
                          dispatch
                          (spanned-sexpr-form (sp-node-get ty)))
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
    [(SpSBracketList items _)
      (parse-ast-let-binding dispatch (sp-node-get items))]
    [(SpSCons name-node tail _)
      (match (sp-node-get name-node)
        [(SpSSym name _)
          (match (sp-node-get tail)
            [(SpSCons second rest _)
              (match (sp-node-get rest)
                [(SpSNil _)
                  (match (parse-ast-expr dispatch (sp-node-get second))
                    [(OkAstExpr parsed-value)
                      (OkAstLetBinding
                        (ast-let-binding name AstNoType parsed-value))]
                    [(ErrAstExpr message) (ErrAstLetBinding message)])]
                [(SpSCons ty value-tail _)
                  (match (sp-node-get value-tail)
                    [(SpSCons value end _)
                      (match (sp-node-get end)
                        [(SpSNil _)
                          (if (sexpr-colon?
                            (spanned-sexpr-form (sp-node-get second)))
                            (match (parse-ast-type
                              dispatch
                              (spanned-sexpr-form (sp-node-get ty)))
                              [(OkAstType parsed-ty)
                                (match (parse-ast-expr
                                  dispatch
                                  (sp-node-get value))
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
      (match (parse-ast-let-binding dispatch (sp-node-get head))
        [(OkAstLetBinding parsed-head)
          (match (parse-ast-let-binding-list dispatch (sp-node-get tail))
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
      (match (sp-node-get head)
        [(SpSBracketList _ _)
          (match (parse-ast-let-binding dispatch (sp-node-get head))
            [(OkAstLetBinding parsed-head)
              (match (parse-ast-let-flat-tail dispatch (sp-node-get tail))
                [(OkAstLetParts parsed-tail parsed-body)
                  (OkAstLetParts
                    (ast-let-binding-cons parsed-head parsed-tail)
                    parsed-body)]
                [(ErrAstLetParts message) (ErrAstLetParts message)])]
            [(ErrAstLetBinding message) (ErrAstLetParts message)])]
        [_
          (match (sp-node-get tail)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (sp-node-get head))
                [(OkAstExpr parsed-body)
                  (OkAstLetParts AstLetBindingNil parsed-body)]
                [(ErrAstExpr message) (ErrAstLetParts message)])]
            [_ (ErrAstLetParts "parse: let expects exactly one body")])])]
    [(SpSNil _) (ErrAstLetParts "parse: let missing body")]
    [_ (ErrAstLetParts "parse: malformed let")]))

(define (parse-ast-let-flat [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons head _ _)
      (match (sp-node-get head)
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
      (match (sp-node-get bindings)
        [(SpSBracketList _ _) (parse-ast-let-flat dispatch rest)]
        [_
          (match (sp-node-get tail)
            [(SpSCons body end _)
              (match (sp-node-get end)
                [(SpSNil _)
                  (match (parse-ast-let-binding-list
                    dispatch
                    (sp-node-get bindings))
                    [(OkAstLetBindingList parsed-bindings)
                      (if (ast-let-binding-list-empty? parsed-bindings)
                        (ErrAstExpr "parse: let requires at least one binding")
                        (match (parse-ast-expr dispatch (sp-node-get body))
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
      (match (sp-node-get tail)
        [(SpSCons second rest-tail _)
          (match (sp-node-get rest-tail)
            [(SpSNil _)
              (match (parse-ast-param-list
                dispatch
                (spanned-sexpr-form (sp-node-get params)))
                [(OkAstParamList parsed-params)
                  (if (ast-param-list-has-comptime? parsed-params)
                    (ErrAstExpr
                      "comptime parameters are only supported on top-level function definitions")
                    (match (parse-ast-expr dispatch (sp-node-get second))
                      [(OkAstExpr parsed-body)
                        (OkAstExpr
                          (ast-expr-lambda parsed-params AstNoType parsed-body))]
                      [(ErrAstExpr message) (ErrAstExpr message)]))]
                [(ErrAstParamList message) (ErrAstExpr message)])]
            [(SpSCons ret body-tail _)
              (match (sp-node-get body-tail)
                [(SpSCons body end _)
                  (match (sp-node-get end)
                    [(SpSNil _)
                      (if (sexpr-colon?
                        (spanned-sexpr-form (sp-node-get second)))
                        (match (parse-ast-param-list
                          dispatch
                          (spanned-sexpr-form (sp-node-get params)))
                          [(OkAstParamList parsed-params)
                            (if (ast-param-list-has-comptime? parsed-params)
                              (ErrAstExpr
                                "comptime parameters are only supported on top-level function definitions")
                              (match (parse-ast-type
                                dispatch
                                (spanned-sexpr-form (sp-node-get ret)))
                                [(OkAstType parsed-ret)
                                  (match (parse-ast-expr
                                    dispatch
                                    (sp-node-get body))
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
      (match (sp-node-get index-tail)
        [(SpSCons index-node end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (sp-node-get index-node)
                [(SpSInt index _)
                  (match (parse-ast-expr dispatch (sp-node-get expr))
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
      (match (sp-node-get len-tail)
        [(SpSCons len end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (parse-ast-type
                dispatch
                (spanned-sexpr-form (sp-node-get elem-ty)))
                [(OkAstType parsed-ty)
                  (match (parse-ast-expr dispatch (sp-node-get len))
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
      (match (sp-node-get index-tail)
        [(SpSCons index end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (sp-node-get expr))
                [(OkAstExpr parsed-expr)
                  (match (parse-ast-expr dispatch (sp-node-get index))
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
      (match (sp-node-get index-tail)
        [(SpSCons index value-tail _)
          (match (sp-node-get value-tail)
            [(SpSCons value end _)
              (match (sp-node-get end)
                [(SpSNil _)
                  (match (parse-ast-expr dispatch (sp-node-get expr))
                    [(OkAstExpr parsed-expr)
                      (match (parse-ast-expr dispatch (sp-node-get index))
                        [(OkAstExpr parsed-index)
                          (match (parse-ast-expr dispatch (sp-node-get value))
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
      (match (sp-node-get value-tail)
        [(SpSCons value end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (sp-node-get expr))
                [(OkAstExpr parsed-expr)
                  (match (parse-ast-expr dispatch (sp-node-get value))
                    [(OkAstExpr parsed-value)
                      (OkAstExpr (ast-expr-array-push parsed-expr parsed-value))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [(ErrAstExpr message) (ErrAstExpr message)])]
            [_ (ErrAstExpr "parse: malformed array-push!")])]
        [_ (ErrAstExpr "parse: malformed array-push!")])]
    [_ (ErrAstExpr "parse: malformed array-push!")]))

(define (parse-ast-borrow
  [dispatch : SymI64Env]
  [mutable : bool]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons first tail _)
      (match (sp-node-get tail)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (sp-node-get first))
            [(OkAstExpr parsed-place)
              (OkAstExpr
                (ast-expr-borrow mutable AstBorrowLifetimeInferred parsed-place))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [(SpSCons place end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (sp-node-get first)
                [(SpSSym name _)
                  (match (parse-ast-expr dispatch (sp-node-get place))
                    [(OkAstExpr parsed-place)
                      (OkAstExpr
                        (ast-expr-borrow
                          mutable
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
      (match (sp-node-get field-tail)
        [(SpSCons field-node end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (sp-node-get field-node)
                [(SpSSym field _)
                  (match (parse-ast-expr dispatch (sp-node-get expr))
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
      (match (sp-node-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (sp-node-get expr))
            [(OkAstExpr parsed-expr)
              (OkAstExpr (ast-expr-comptime parsed-expr))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: comptime expects exactly one expression")])]
    [_ (ErrAstExpr "parse: comptime expects exactly one expression")]))

(define (parse-ast-type-literal [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons ty end _)
      (match (sp-node-get end)
        [(SpSNil _)
          (match (parse-ast-type dispatch (spanned-sexpr-form (sp-node-get ty)))
            [(OkAstType parsed-ty)
              (OkAstExpr (ast-node-push (AstExprTypeLiteral parsed-ty)))]
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

(define (parse-ast-scan-op [name : String]) : ResultAstReduceOp
  (cond
    [(string-eq name "sum") (OkAstReduceOp (AstReduceSum))]
    [(string-eq name "min") (OkAstReduceOp (AstReduceMin))]
    [(string-eq name "max") (OkAstReduceOp (AstReduceMax))]
    [(string-eq name "all") (OkAstReduceOp (AstReduceAll))]
    [(string-eq name "any") (OkAstReduceOp (AstReduceAny))]
    [else
      (ErrAstReduceOp
        (string-append
          "parse: unsupported spmd-scan operator `"
          (string-append name "`; expected one of sum, min, max, all, any")))]))

(define (parse-ast-spmd-reduce-binding
  [dispatch : SymI64Env]
  [op : AstReduceOp]
  [binding : SpannedSexpr]
  [init : SpannedSexpr]
  [value : SpannedSexpr]) : ResultAstExpr
  (match binding
    [(SpSBracketList items _)
      (parse-ast-spmd-reduce-binding dispatch op (sp-node-get items) init value)]
    [(SpSCons index-node colon-tail _)
      (match (sp-node-get index-node)
        [(SpSSym index _)
          (match (sp-node-get colon-tail)
            [(SpSCons colon index-ty-tail _)
              (match (sp-node-get index-ty-tail)
                [(SpSCons index-ty start-tail _)
                  (match (sp-node-get start-tail)
                    [(SpSCons start end-tail _)
                      (match (sp-node-get end-tail)
                        [(SpSCons end finish _)
                          (match (sp-node-get finish)
                            [(SpSNil _)
                              (if (sexpr-colon?
                                (spanned-sexpr-form (sp-node-get colon)))
                                (match (parse-ast-type
                                  dispatch
                                  (spanned-sexpr-form (sp-node-get index-ty)))
                                  [(OkAstType parsed-index-ty)
                                    (match (parse-ast-expr
                                      dispatch
                                      (sp-node-get start))
                                      [(OkAstExpr parsed-start)
                                        (match (parse-ast-expr
                                          dispatch
                                          (sp-node-get end))
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
      (match (sp-node-get op-node)
        [(SpSSym op-name _)
          (match (sp-node-get binding-tail)
            [(SpSCons binding-list init-tail _)
              (match (sp-node-get binding-list)
                [(SpSCons binding binding-list-end _)
                  (match (sp-node-get binding-list-end)
                    [(SpSNil _)
                      (match (sp-node-get init-tail)
                        [(SpSCons init value-tail _)
                          (match (sp-node-get value-tail)
                            [(SpSCons value end _)
                              (match (sp-node-get end)
                                [(SpSNil _)
                                  (match (parse-ast-reduce-op op-name)
                                    [(OkAstReduceOp op)
                                      (parse-ast-spmd-reduce-binding
                                        dispatch
                                        op
                                        (sp-node-get binding)
                                        (sp-node-get init)
                                        (sp-node-get value))]
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

(define (parse-ast-spmd-scan [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons op-node binding-tail _)
      (match (sp-node-get op-node)
        [(SpSSym op-name _)
          (match (sp-node-get binding-tail)
            [(SpSCons binding-list value-tail _)
              (match (sp-node-get binding-list)
                [(SpSCons range-binding prefix-tail _)
                  (match (sp-node-get prefix-tail)
                    [(SpSCons prefix-binding binding-end _)
                      (match (sp-node-get binding-end)
                        [(SpSNil _)
                          (match (sp-node-get value-tail)
                            [(SpSCons value body-tail _)
                              (match (sp-node-get body-tail)
                                [(SpSCons body end _)
                                  (match (sp-node-get end)
                                    [(SpSNil _)
                                      (match (parse-ast-scan-op op-name)
                                        [(OkAstReduceOp op)
                                          (parse-ast-spmd-scan-bindings
                                            dispatch
                                            op
                                            (sp-node-get range-binding)
                                            (sp-node-get prefix-binding)
                                            (sp-node-get value)
                                            (sp-node-get body))]
                                        [(ErrAstReduceOp message)
                                          (ErrAstExpr message)])]
                                    [_
                                      (ErrAstExpr "parse: malformed spmd-scan")])]
                                [_ (ErrAstExpr "parse: malformed spmd-scan")])]
                            [_ (ErrAstExpr "parse: malformed spmd-scan")])]
                        [_ (ErrAstExpr "parse: malformed spmd-scan")])]
                    [_ (ErrAstExpr "parse: malformed spmd-scan")])]
                [_ (ErrAstExpr "parse: malformed spmd-scan")])]
            [_ (ErrAstExpr "parse: malformed spmd-scan")])]
        [_ (ErrAstExpr "parse: malformed spmd-scan")])]
    [(SpSCons _ _ _) (ErrAstExpr "parse: malformed spmd-scan")]
    [_ (ErrAstExpr "parse: malformed spmd-scan")]))

(define (parse-ast-spmd-scan-bindings
  [dispatch : SymI64Env]
  [op : AstReduceOp]
  [range-binding : SpannedSexpr]
  [prefix-binding : SpannedSexpr]
  [value : SpannedSexpr]
  [body : SpannedSexpr]) : ResultAstExpr
  (match range-binding
    [(SpSBracketList items _)
      (parse-ast-spmd-scan-bindings
        dispatch
        op
        (sp-node-get items)
        prefix-binding
        value
        body)]
    [(SpSCons index-node colon-tail _)
      (match (sp-node-get index-node)
        [(SpSSym index _)
          (match (sp-node-get colon-tail)
            [(SpSCons colon index-ty-tail _)
              (match (sp-node-get index-ty-tail)
                [(SpSCons index-ty start-tail _)
                  (match (sp-node-get start-tail)
                    [(SpSCons start end-tail _)
                      (match (sp-node-get end-tail)
                        [(SpSCons end finish _)
                          (match (sp-node-get finish)
                            [(SpSNil _)
                              (if (sexpr-colon?
                                (spanned-sexpr-form (sp-node-get colon)))
                                (match (parse-ast-type
                                  dispatch
                                  (spanned-sexpr-form (sp-node-get index-ty)))
                                  [(OkAstType parsed-index-ty)
                                    (parse-ast-spmd-scan-prefix-binding
                                      dispatch
                                      op
                                      index
                                      parsed-index-ty
                                      (sp-node-get start)
                                      (sp-node-get end)
                                      prefix-binding
                                      value
                                      body)]
                                  [(ErrAstType message) (ErrAstExpr message)])
                                (ErrAstExpr
                                  "parse: expected ':' in spmd-scan range binding"))]
                            [_
                              (ErrAstExpr
                                "parse: malformed spmd-scan range binding")])]
                        [_
                          (ErrAstExpr
                            "parse: malformed spmd-scan range binding")])]
                    [_ (ErrAstExpr "parse: malformed spmd-scan range binding")])]
                [_ (ErrAstExpr "parse: malformed spmd-scan range binding")])]
            [_ (ErrAstExpr "parse: malformed spmd-scan range binding")])]
        [_ (ErrAstExpr "parse: malformed spmd-scan range binding")])]
    [_ (ErrAstExpr "parse: malformed spmd-scan range binding")]))

(define (parse-ast-spmd-scan-prefix-binding
  [dispatch : SymI64Env]
  [op : AstReduceOp]
  [index : String]
  [index-ty : AstType]
  [start : SpannedSexpr]
  [end : SpannedSexpr]
  [prefix-binding : SpannedSexpr]
  [value : SpannedSexpr]
  [body : SpannedSexpr]) : ResultAstExpr
  (match prefix-binding
    [(SpSBracketList items _)
      (parse-ast-spmd-scan-prefix-binding
        dispatch
        op
        index
        index-ty
        start
        end
        (sp-node-get items)
        value
        body)]
    [(SpSCons prefix-node colon-tail _)
      (match (sp-node-get prefix-node)
        [(SpSSym prefix _)
          (match (sp-node-get colon-tail)
            [(SpSCons colon prefix-ty-tail _)
              (match (sp-node-get prefix-ty-tail)
                [(SpSCons prefix-ty init-tail _)
                  (match (sp-node-get init-tail)
                    [(SpSCons init finish _)
                      (match (sp-node-get finish)
                        [(SpSNil _)
                          (if (sexpr-colon?
                            (spanned-sexpr-form (sp-node-get colon)))
                            (match (parse-ast-type
                              dispatch
                              (spanned-sexpr-form (sp-node-get prefix-ty)))
                              [(OkAstType parsed-prefix-ty)
                                (match (parse-ast-expr dispatch start)
                                  [(OkAstExpr parsed-start)
                                    (match (parse-ast-expr dispatch end)
                                      [(OkAstExpr parsed-end)
                                        (match (parse-ast-expr
                                          dispatch
                                          (sp-node-get init))
                                          [(OkAstExpr parsed-init)
                                            (match (parse-ast-expr
                                              dispatch
                                              value)
                                              [(OkAstExpr parsed-value)
                                                (match (parse-ast-expr
                                                  dispatch
                                                  body)
                                                  [(OkAstExpr parsed-body)
                                                    (OkAstExpr
                                                      (ast-expr-spmd-scan
                                                        op
                                                        index
                                                        index-ty
                                                        parsed-start
                                                        parsed-end
                                                        prefix
                                                        parsed-prefix-ty
                                                        parsed-init
                                                        parsed-value
                                                        parsed-body))]
                                                  [(ErrAstExpr message)
                                                    (ErrAstExpr message)])]
                                              [(ErrAstExpr message)
                                                (ErrAstExpr message)])]
                                          [(ErrAstExpr message)
                                            (ErrAstExpr message)])]
                                      [(ErrAstExpr message)
                                        (ErrAstExpr message)])]
                                  [(ErrAstExpr message) (ErrAstExpr message)])]
                              [(ErrAstType message) (ErrAstExpr message)])
                            (ErrAstExpr
                              "parse: expected ':' in spmd-scan prefix binding"))]
                        [_
                          (ErrAstExpr
                            "parse: malformed spmd-scan prefix binding")])]
                    [_ (ErrAstExpr "parse: malformed spmd-scan prefix binding")])]
                [_ (ErrAstExpr "parse: malformed spmd-scan prefix binding")])]
            [_ (ErrAstExpr "parse: malformed spmd-scan prefix binding")])]
        [_ (ErrAstExpr "parse: malformed spmd-scan prefix binding")])]
    [_ (ErrAstExpr "parse: malformed spmd-scan prefix binding")]))

(define (parse-ast-spmd-broadcast [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons value-node lane-tail _)
      (match (sp-node-get lane-tail)
        [(SpSCons lane-node end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (sp-node-get value-node))
                [(OkAstExpr value)
                  (match (parse-ast-expr dispatch (sp-node-get lane-node))
                    [(OkAstExpr lane)
                      (OkAstExpr (ast-expr-spmd-broadcast value lane))]
                    [(ErrAstExpr message) (ErrAstExpr message)])]
                [(ErrAstExpr message) (ErrAstExpr message)])]
            [_ (ErrAstExpr "parse: malformed spmd-broadcast")])]
        [_ (ErrAstExpr "parse: malformed spmd-broadcast")])]
    [_ (ErrAstExpr "parse: malformed spmd-broadcast")]))

(define (parse-ast-try [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (sp-node-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (sp-node-get expr))
            [(OkAstExpr parsed-expr) (OkAstExpr (ast-expr-try parsed-expr))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: try expects exactly one expression")])]
    [_ (ErrAstExpr "parse: try expects exactly one expression")]))

(define (parse-ast-return [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (sp-node-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (sp-node-get expr))
            [(OkAstExpr parsed-expr) (OkAstExpr (ast-expr-return parsed-expr))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: return expects exactly one expression")])]
    [_ (ErrAstExpr "parse: return expects exactly one expression")]))

(define (parse-ast-box-like
  [dispatch : SymI64Env]
  [rest : SpannedSexpr]
  [is-get : bool]
  [is-take : bool]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (sp-node-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (sp-node-get expr))
            [(OkAstExpr parsed-expr)
              (if is-get
                (OkAstExpr (ast-expr-box-get parsed-expr))
                (if is-take
                  (OkAstExpr (ast-expr-box-take parsed-expr))
                  (OkAstExpr (ast-expr-box parsed-expr))))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_
          (ErrAstExpr
            (if is-get
              "parse: box-get expects exactly one expression"
              (if is-take
                "parse: box-take expects exactly one expression"
                "parse: box expects exactly one expression")))])]
    [_
      (ErrAstExpr
        (if is-get
          "parse: box-get expects exactly one expression"
          (if is-take
            "parse: box-take expects exactly one expression"
            "parse: box expects exactly one expression")))]))

;; `(ptr-null : T)` - a colon followed by a pointer type, no leading expression.
;; The parser accepts any type here; the typechecker rejects non-pointer `T`.
(define (parse-ast-ptr-null [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons colon ty-tail _)
      (match (sp-node-get ty-tail)
        [(SpSCons ty end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (if (sexpr-colon? (spanned-sexpr-form (sp-node-get colon)))
                (match (parse-ast-type
                  dispatch
                  (spanned-sexpr-form (sp-node-get ty)))
                  [(OkAstType parsed-ty)
                    (OkAstExpr (ast-node-push (AstExprPtrNull parsed-ty)))]
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

;; `(init : T)` carries an explicit target type. Bare `(init)` is contextual
;; and must be checked/lowered in a position with an expected type.
(define (parse-ast-init [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSNil _) (OkAstExpr (ast-expr-init-contextual))]
    [(SpSCons colon ty-tail _)
      (match (sp-node-get ty-tail)
        [(SpSCons ty end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (if (sexpr-colon? (spanned-sexpr-form (sp-node-get colon)))
                (match (parse-ast-type
                  dispatch
                  (spanned-sexpr-form (sp-node-get ty)))
                  [(OkAstType parsed-ty) (OkAstExpr (ast-expr-init parsed-ty))]
                  [(ErrAstType message) (ErrAstExpr message)])
                (ErrAstExpr "parse: expected ':' in init"))]
            [_ (ErrAstExpr "parse: init expects (init : T)")])]
        [_ (ErrAstExpr "parse: init expects (init : T)")])]
    [_ (ErrAstExpr "parse: init expects (init : T)")]))

;; `(ptr-null? p)` - a single pointer operand.
(define (parse-ast-ptr-null-check [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (sp-node-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (sp-node-get expr))
            [(OkAstExpr parsed-expr)
              (OkAstExpr (ast-expr-ptr-null-check parsed-expr))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: ptr-null? expects exactly one expression")])]
    [_ (ErrAstExpr "parse: ptr-null? expects exactly one expression")]))

(define (parse-ast-ptr-read [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (sp-node-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (sp-node-get expr))
            [(OkAstExpr parsed-expr)
              (OkAstExpr (ast-expr-ptr-read parsed-expr))]
            [(ErrAstExpr message) (ErrAstExpr message)])]
        [_ (ErrAstExpr "parse: ptr-read expects exactly one expression")])]
    [_ (ErrAstExpr "parse: ptr-read expects exactly one expression")]))

(define (parse-ast-ptr-addr-of [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons name end _)
      (match (sp-node-get end)
        [(SpSNil _)
          (match (spanned-sexpr-form (sp-node-get name))
            [(SSym local) (OkAstExpr (ast-expr-ptr-addr-of local))]
            [_ (ErrAstExpr "parse: ptr-addr-of expects a local name")])]
        [_ (ErrAstExpr "parse: ptr-addr-of expects exactly one local name")])]
    [_ (ErrAstExpr "parse: ptr-addr-of expects exactly one local name")]))

(define (parse-ast-ptr-write [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons ptr value-tail _)
      (match (sp-node-get value-tail)
        [(SpSCons value end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (sp-node-get ptr))
                [(OkAstExpr parsed-ptr)
                  (match (parse-ast-expr dispatch (sp-node-get value))
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
      (match (sp-node-get offset-tail)
        [(SpSCons offset end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (sp-node-get ptr))
                [(OkAstExpr parsed-ptr)
                  (match (parse-ast-expr dispatch (sp-node-get offset))
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
      (match (sp-node-get colon-tail)
        [(SpSCons colon ty-tail _)
          (match (sp-node-get ty-tail)
            [(SpSCons ty end _)
              (match (sp-node-get end)
                [(SpSNil _)
                  (if (sexpr-colon? (spanned-sexpr-form (sp-node-get colon)))
                    (match (parse-ast-expr dispatch (sp-node-get expr))
                      [(OkAstExpr parsed-expr)
                        (match (parse-ast-type
                          dispatch
                          (spanned-sexpr-form (sp-node-get ty)))
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
      (match (sp-node-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (sp-node-get expr))
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
      (match (sp-node-get end)
        [(SpSNil _) (parse-ast-expr dispatch (sp-node-get expr))]
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
      (match (sp-node-get second-tail)
        [(SpSCons second end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (sp-node-get first))
                [(OkAstExpr parsed-first)
                  (match (parse-ast-expr dispatch (sp-node-get second))
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
  [expr : i64]) : ResultAstExpr
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
        [leaf : i64 (struct-get pair first)]
        [subleaf : i64 (struct-get pair second)]
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

(define (parse-ast-syscall-count [args : AstExprList]) : i64
  (match args
    [(AstExprNil) 0]
    [(AstExprCons _ rest) (+ 1 (parse-ast-syscall-count (box-get rest)))]))

;; `(syscall number a0 .. a5)`: the syscall number followed by up to six
;; arguments (1 to 7 operands total). Typechecking requires an enclosing
;; `(unsafe ...)` context before this lowers to a raw `syscall` instruction.
(define (parse-ast-syscall [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch rest)
    [(OkAstExprList args)
      (let
        [count : i64 (parse-ast-syscall-count args)]
        (if (< count 1)
          (ErrAstExpr "parse: syscall requires a syscall number")
          (if (> count 7)
            (ErrAstExpr
              "parse: syscall takes at most 7 operands (number plus six arguments)")
            (OkAstExpr (ast-expr-syscall args)))))]
    [(ErrAstExprList message) (ErrAstExpr message)]))

(define (parse-ast-with-region [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSNil _)
      (ErrAstExpr "parse: with-arena requires a region name before its body")]
    [(SpSCons _ _ _)
      (match rest
        [(SpSCons region-node body _)
          (match (sp-node-get region-node)
            [(SpSSym region _)
              (match (sp-node-get body)
                [(SpSNil _)
                  (ErrAstExpr
                    (string-append
                      "parse: with-arena '"
                      (string-append region "' requires a non-empty body")))]
                [_
                  (match (parse-ast-expr-list dispatch (sp-node-get body))
                    [(OkAstExprList exprs)
                      (OkAstExpr
                        (ast-node-push (AstExprWithRegion region exprs)))]
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
      (match (sp-node-get body)
        [(SpSNil _) (ErrAstExpr "parse: with-escape requires a non-empty body")]
        [_
          (match (parse-ast-expr dispatch (sp-node-get scratch))
            [(OkAstExpr parsed-scratch)
              (match (parse-ast-expr-list dispatch (sp-node-get body))
                [(OkAstExprList exprs)
                  (OkAstExpr (ast-expr-with-escape parsed-scratch exprs))]
                [(ErrAstExprList message) (ErrAstExpr message)])]
            [(ErrAstExpr message) (ErrAstExpr message)])])]
    [_ (ErrAstExpr "parse: malformed with-escape")]))

(define (parse-ast-with-scratch [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSNil _) (ErrAstExpr "parse: with-scratch requires a non-empty body")]
    [(SpSCons _ _ _)
      (match (parse-ast-expr-list dispatch rest)
        [(OkAstExprList exprs) (OkAstExpr (ast-expr-with-scratch exprs))]
        [(ErrAstExprList message) (ErrAstExpr message)])]
    [_ (ErrAstExpr "parse: malformed with-scratch")]))

(define (parse-ast-in-arena [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSNil _)
      (ErrAstExpr "parse: in-arena requires an arena before its body")]
    [(SpSCons arena body _)
      (match (sp-node-get body)
        [(SpSNil _) (ErrAstExpr "parse: in-arena requires a non-empty body")]
        [_
          (match (parse-ast-expr dispatch (sp-node-get arena))
            [(OkAstExpr parsed-arena)
              (match (parse-ast-expr-list dispatch (sp-node-get body))
                [(OkAstExprList exprs)
                  (OkAstExpr (ast-expr-in-arena parsed-arena exprs))]
                [(ErrAstExprList message) (ErrAstExpr message)])]
            [(ErrAstExpr message) (ErrAstExpr message)])])]
    [_ (ErrAstExpr "parse: malformed in-arena")]))

(define (parse-ast-resource-binding-items
  [dispatch : SymI64Env]
  [items : SpannedSexpr]) : ResultAstResourceBinding
  (match items
    [(SpSCons _ _ _)
      (match items
        [(SpSCons name-node rest _)
          (match (sp-node-get name-node)
            [(SpSSym name _)
              (match (sp-node-get rest)
                [(SpSNil _)
                  (ErrAstResourceBinding
                    "parse: with binding is missing initializer")]
                [(SpSCons init tail _)
                  (match (sp-node-get tail)
                    [(SpSNil _)
                      (ErrAstResourceBinding
                        "parse: with binding is missing cleanup function")]
                    [(SpSCons cleanup extra _)
                      (match (sp-node-get extra)
                        [(SpSNil _)
                          (match (parse-ast-expr dispatch (sp-node-get init))
                            [(OkAstExpr parsed-init)
                              (match (parse-ast-expr
                                dispatch
                                (sp-node-get cleanup))
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
      (parse-ast-resource-binding-items dispatch (sp-node-get items))]
    [_ (ErrAstResourceBinding "parse: with binding must use bracket syntax")]))

(define (parse-ast-resource-binding-list
  [dispatch : SymI64Env]
  [bindings : SpannedSexpr]) : ResultAstResourceBindingList
  (match bindings
    [(SpSNil _) (OkAstResourceBindingList AstResourceBindingNil)]
    [(SpSCons head rest _)
      (match (parse-ast-resource-binding dispatch (sp-node-get head))
        [(OkAstResourceBinding parsed-head)
          (match (parse-ast-resource-binding-list dispatch (sp-node-get rest))
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
      (match (sp-node-get bindings)
        [(SpSNil _)
          (ErrAstExpr "parse: with requires a non-empty binding list")]
        [(SpSCons _ _ _)
          (match (sp-node-get body)
            [(SpSNil _) (ErrAstExpr "parse: with requires a non-empty body")]
            [_
              (match (parse-ast-resource-binding-list
                dispatch
                (sp-node-get bindings))
                [(OkAstResourceBindingList parsed-bindings)
                  (match (parse-ast-expr-list dispatch (sp-node-get body))
                    [(OkAstExprList parsed-body)
                      (OkAstExpr
                        (ast-node-push
                          (AstExprWithResource
                            (box (AstWithResource parsed-bindings parsed-body)))))]
                    [(ErrAstExprList message) (ErrAstExpr message)])]
                [(ErrAstResourceBindingList message) (ErrAstExpr message)])])]
        [_ (ErrAstExpr "parse: malformed with binding list")])]
    [_ (ErrAstExpr "parse: malformed with")]))

(define (parse-ast-match-arm [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstMatchArm
  (match s
    [(SpSBracketList items _)
      (parse-ast-match-arm dispatch (sp-node-get items))]
    [(SpSCons pattern body-tail _)
      (match (sp-node-get body-tail)
        [(SpSCons body end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (parse-ast-pattern
                dispatch
                (spanned-sexpr-form (sp-node-get pattern)))
                [(OkAstPattern parsed-pattern)
                  (match (parse-ast-expr dispatch (sp-node-get body))
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
      (match (parse-ast-match-arm dispatch (sp-node-get head))
        [(OkAstMatchArm parsed-head)
          (match (parse-ast-match-arm-list dispatch (sp-node-get tail))
            [(OkAstMatchArmList parsed-tail)
              (OkAstMatchArmList (ast-match-arm-cons parsed-head parsed-tail))]
            [(ErrAstMatchArmList message) (ErrAstMatchArmList message)])]
        [(ErrAstMatchArm message) (ErrAstMatchArmList message)])]
    [_ (ErrAstMatchArmList "parse: malformed match arm list")]))

(define (parse-ast-match [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons scrutinee arms _)
      (match (parse-ast-expr dispatch (sp-node-get scrutinee))
        [(OkAstExpr parsed-scrutinee)
          (match (parse-ast-match-arm-list dispatch (sp-node-get arms))
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
      (parse-ast-foreach-binding dispatch (sp-node-get items) body)]
    [(SpSCons index-node colon-tail _)
      (match (sp-node-get index-node)
        [(SpSSym index _)
          (match (sp-node-get colon-tail)
            [(SpSCons colon index-ty-tail _)
              (match (sp-node-get index-ty-tail)
                [(SpSCons index-ty start-tail _)
                  (match (sp-node-get start-tail)
                    [(SpSCons start end-tail _)
                      (match (sp-node-get end-tail)
                        [(SpSCons end finish _)
                          (match (sp-node-get finish)
                            [(SpSNil _)
                              (if (sexpr-colon?
                                (spanned-sexpr-form (sp-node-get colon)))
                                (match (parse-ast-type
                                  dispatch
                                  (spanned-sexpr-form (sp-node-get index-ty)))
                                  [(OkAstType parsed-index-ty)
                                    (match (parse-ast-expr
                                      dispatch
                                      (sp-node-get start))
                                      [(OkAstExpr parsed-start)
                                        (match (parse-ast-expr
                                          dispatch
                                          (sp-node-get end))
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
      (match (sp-node-get binding-list)
        [(SpSCons binding binding-end _)
          (match (sp-node-get binding-end)
            [(SpSNil _)
              (match (sp-node-get body-tail)
                [(SpSCons body end _)
                  (match (sp-node-get end)
                    [(SpSNil _)
                      (parse-ast-foreach-binding
                        dispatch
                        (sp-node-get binding)
                        (sp-node-get body))]
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
      (match (parse-ast-call-arg-list dispatch rest)
        [(OkAstExprList parsed-args)
          (OkAstExpr (ast-expr-call parsed-head parsed-args))]
        [(ErrAstExprList message) (ErrAstExpr message)])]
    [(ErrAstExpr message) (ErrAstExpr message)]))

(define (parse-ast-begin [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch rest)
    [(OkAstExprList exprs) (OkAstExpr (ast-node-push (AstExprBegin exprs)))]
    [(ErrAstExprList message) (ErrAstExpr message)]))

;; `(unsafe expr+)` parses like `begin` but requires a non-empty body. v1 has
;; the same behavior as `begin`; it marks an unsafe context for later raw-pointer
;; ops (#955).
(define (parse-ast-unsafe [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSNil _) (ErrAstExpr "parse: unsafe requires a non-empty body")]
    [_
      (match (parse-ast-expr-list dispatch rest)
        [(OkAstExprList exprs)
          (OkAstExpr (ast-node-push (AstExprUnsafe exprs)))]
        [(ErrAstExprList message) (ErrAstExpr message)])]))

(define (parse-ast-tuple [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch rest)
    [(OkAstExprList exprs) (OkAstExpr (ast-node-push (AstExprTuple exprs)))]
    [(ErrAstExprList message) (ErrAstExpr message)]))

(define (parse-ast-array [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch rest)
    [(OkAstExprList exprs) (OkAstExpr (ast-node-push (AstExprArray exprs)))]
    [(ErrAstExprList message) (ErrAstExpr message)]))

(define (parse-ast-quote-like
  [dispatch : SymI64Env]
  [tag : i64]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpSCons expr end _)
      (match (sp-node-get end)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (sp-node-get expr))
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
    [(= tag (compiler-parse-tag-expr-spmd-scan))
      (parse-ast-spmd-scan dispatch rest)]
    [(= tag (compiler-parse-tag-expr-spmd-broadcast))
      (parse-ast-spmd-broadcast dispatch rest)]
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
    [(= tag (compiler-parse-tag-expr-with-scratch))
      (parse-ast-with-scratch dispatch rest)]
    [(= tag (compiler-parse-tag-expr-in-arena))
      (parse-ast-in-arena dispatch rest)]
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
      (parse-ast-box-like dispatch rest false false)]
    [(= tag (compiler-parse-tag-expr-box-get))
      (parse-ast-box-like dispatch rest true false)]
    [(= tag (compiler-parse-tag-expr-box-take))
      (parse-ast-box-like dispatch rest false true)]
    [(= tag (compiler-parse-tag-expr-string-data))
      (parse-ast-string-data dispatch rest)]
    [(= tag (compiler-parse-tag-expr-string-from-bytes))
      (parse-ast-string-from-bytes dispatch rest)]
    [(= tag (compiler-parse-tag-expr-array-data))
      (parse-ast-array-data dispatch rest)]
    [(= tag (compiler-parse-tag-expr-program-argc))
      (parse-ast-no-arg-low-level
        rest
        "program-argc"
        (ast-node-push (AstExprProgramArgc)))]
    [(= tag (compiler-parse-tag-expr-program-argv))
      (parse-ast-no-arg-low-level
        rest
        "program-argv"
        (ast-node-push (AstExprProgramArgv)))]
    [(= tag (compiler-parse-tag-expr-program-envp))
      (parse-ast-no-arg-low-level
        rest
        "program-envp"
        (ast-node-push (AstExprProgramEnvp)))]
    [(= tag (compiler-parse-tag-expr-cpuid-eax))
      (parse-ast-cpuid-like dispatch tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-ebx))
      (parse-ast-cpuid-like dispatch tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-ecx))
      (parse-ast-cpuid-like dispatch tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-edx))
      (parse-ast-cpuid-like dispatch tag rest)]
    [(= tag (compiler-parse-tag-expr-xgetbv)) (parse-ast-xgetbv dispatch rest)]
    [(= tag (compiler-parse-tag-expr-syscall))
      (parse-ast-syscall dispatch rest)]
    [(= tag (compiler-parse-tag-expr-init)) (parse-ast-init dispatch rest)]
    [(= tag (compiler-parse-tag-expr-ptr-null))
      (parse-ast-ptr-null dispatch rest)]
    [(= tag (compiler-parse-tag-expr-ptr-null-check))
      (parse-ast-ptr-null-check dispatch rest)]
    [(= tag (compiler-parse-tag-decl-comptime-decl))
      (ErrAstExpr
        "parse: comptime-decl is only valid as a top-level declaration")]
    [(= tag (compiler-parse-tag-decl-comptime-decls))
      (ErrAstExpr
        "parse: comptime-decls is only valid as a top-level declaration")]
    [else (parse-ast-call dispatch head rest)]))

(define (parse-ast-list-expr
  [dispatch : SymI64Env]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match head
    [(SpSSym op _)
      (if (string-eq op "init")
        (match rest
          [(SpSCons first _ _)
            (if (sexpr-colon? (spanned-sexpr-form (sp-node-get first)))
              (parse-ast-init dispatch rest)
              (parse-ast-call dispatch head rest))]
          [(SpSNil _) (parse-ast-init dispatch rest)]
          [_ (parse-ast-call dispatch head rest)])
        (let
          [tag : i64 (compiler-parse-dispatch-tag dispatch op)]
          (cond
            [(= tag (compiler-parse-tag-expr-ptr-addr-of))
              (parse-ast-ptr-addr-of rest)]
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
            [(ast-unop-tag? tag)
              (parse-ast-unary dispatch (ast-unop-from-tag tag) rest)]
            [(ast-binop-tag? tag)
              (parse-ast-binary dispatch (ast-binop-from-tag tag) rest)]
            [(= tag (compiler-parse-tag-ty-ref))
              (parse-ast-borrow dispatch false rest)]
            [(= tag (compiler-parse-tag-ty-mut-ref))
              (parse-ast-borrow dispatch true rest)]
            [else (parse-ast-list-expr-tag dispatch tag head rest)])))]
    [_ (parse-ast-call dispatch head rest)]))

(define (parse-ast-expr [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstExpr
  (match s
    [(SpSInt n _)
      (OkAstExpr
        (ast-expr-wrap-span (ast-node-push (AstExprLiteral (AstLitInt n))) s))]
    [(SpSFloat text _)
      (OkAstExpr
        (ast-expr-wrap-span
          (ast-node-push (AstExprLiteral (AstLitFloat text)))
          s))]
    [(SpSStr text _)
      (OkAstExpr
        (ast-expr-wrap-span
          (ast-node-push (AstExprLiteral (AstLitString text)))
          s))]
    [(SpSChar c _)
      (OkAstExpr
        (ast-expr-wrap-span (ast-node-push (AstExprLiteral (AstLitChar c))) s))]
    [(SpSSym name _)
      (let
        [tag : i64 (compiler-parse-dispatch-tag dispatch name)]
        (cond
          [(= tag (compiler-parse-tag-lit-true))
            (OkAstExpr
              (ast-expr-wrap-span
                (ast-node-push (AstExprLiteral (AstLitBool true)))
                s))]
          [(= tag (compiler-parse-tag-lit-false))
            (OkAstExpr
              (ast-expr-wrap-span
                (ast-node-push (AstExprLiteral (AstLitBool false)))
                s))]
          [(= tag (compiler-parse-tag-unit))
            (OkAstExpr
              (ast-expr-wrap-span (ast-node-push (AstExprLiteral AstLitUnit)) s))]
          [else
            (OkAstExpr
              (ast-expr-wrap-span (ast-node-push (AstExprVar (intern name))) s))]))]
    [(SpSCons head rest _)
      (match (sp-node-get head)
        [(SpSSym op _)
          (if (string-eq op "cfg")
            (match (parse-ast-cfg-expr dispatch (sp-node-get rest))
              [(OkAstExpr parsed) (OkAstExpr (ast-expr-wrap-span parsed s))]
              [(ErrAstExpr message) (ErrAstExpr message)])
            (match (parse-ast-list-expr
              dispatch
              (sp-node-get head)
              (sp-node-get rest))
              [(OkAstExpr parsed) (OkAstExpr (ast-expr-wrap-span parsed s))]
              [(ErrAstExpr message) (ErrAstExpr message)]))]
        [_
          (match (parse-ast-list-expr
            dispatch
            (sp-node-get head)
            (sp-node-get rest))
            [(OkAstExpr parsed) (OkAstExpr (ast-expr-wrap-span parsed s))]
            [(ErrAstExpr message) (ErrAstExpr message)])])]
    [_ (ErrAstExpr "parse: malformed expression")]))

(define (parse-ast-define-value
  [dispatch : SymI64Env]
  [name : String]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons first tail _)
      (match (sp-node-get tail)
        [(SpSNil _)
          (match (parse-ast-expr dispatch (sp-node-get first))
            [(OkAstExpr parsed-value)
              (OkAstDecl (ast-decl-def name AstNoType parsed-value))]
            [(ErrAstExpr message) (ErrAstDecl message)])]
        [(SpSCons ty value-tail _)
          (match (sp-node-get value-tail)
            [(SpSCons value end _)
              (match (sp-node-get end)
                [(SpSNil _)
                  (if (sexpr-colon? (spanned-sexpr-form (sp-node-get first)))
                    (match (parse-ast-type
                      dispatch
                      (spanned-sexpr-form (sp-node-get ty)))
                      [(OkAstType parsed-ty)
                        (match (parse-ast-expr dispatch (sp-node-get value))
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

(define (parse-ast-define-fn-export-tail [tail : Sexpr]) : ResultAstFnExport
  (match tail
    [(SCons value-node end)
      (match (box-get end)
        [(SNil)
          (match (box-get value-node)
            [(SStr value)
              (if (> (string-length value) 0)
                (OkAstFnExport (ast-fn-export value))
                (ErrAstFnExport
                  "parse: define :export-symbol must not be empty"))]
            [_
              (ErrAstFnExport "parse: malformed define :export-symbol metadata")])]
        [_ (ErrAstFnExport "parse: malformed define :export-symbol metadata")])]
    [_ (ErrAstFnExport "parse: malformed define :export-symbol metadata")]))

(define (parse-ast-define-fn-metadata? [item : SpannedSexpr]) : bool
  (match (spanned-sexpr-form item)
    [(SCons key-node _)
      (match (box-get key-node)
        [(SSym key) (compiler-parse-metadata-key? key)]
        [_ false])]
    [_ false]))

(define (parse-ast-define-fn-finish
  [name : String]
  [params : AstParamList]
  [ret : AstType]
  [body : i64]
  [export : AstFnExport]) : ResultAstDecl
  (match export
    [(AstFnNoExport)
      (OkAstDecl (ast-decl-def-fn-export name params ret body export))]
    [(AstFnExport _)
      (if (ast-param-list-has-comptime? params)
        (ErrAstDecl
          "parse: define :export-symbol cannot be used on functions with comptime parameters")
        (OkAstDecl (ast-decl-def-fn-export name params ret body export)))]))

(define (parse-ast-define-fn-rest
  [dispatch : SymI64Env]
  [name : String]
  [params : AstParamList]
  [export : AstFnExport]
  [seen-export : bool]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons first tail _)
      (if (sexpr-colon? (spanned-sexpr-form (sp-node-get first)))
        (match (sp-node-get tail)
          [(SpSCons ret body-tail _)
            (match (sp-node-get body-tail)
              [(SpSCons body end _)
                (match (sp-node-get end)
                  [(SpSNil _)
                    (match (parse-ast-type
                      dispatch
                      (spanned-sexpr-form (sp-node-get ret)))
                      [(OkAstType parsed-ret)
                        (match (parse-ast-expr dispatch (sp-node-get body))
                          [(OkAstExpr parsed-body)
                            (parse-ast-define-fn-finish
                              name
                              params
                              parsed-ret
                              parsed-body
                              export)]
                          [(ErrAstExpr message) (ErrAstDecl message)])]
                      [(ErrAstType message) (ErrAstDecl message)])]
                  [_ (ErrAstDecl "parse: malformed function definition")])]
              [_ (ErrAstDecl "parse: malformed function definition")])]
          [_ (ErrAstDecl "parse: malformed function definition")])
        (if (parse-ast-define-fn-metadata? (sp-node-get first))
          (match (spanned-sexpr-form (sp-node-get first))
            [(SCons key-node after-key)
              (match (box-get key-node)
                [(SSym key)
                  (if (string-eq key ":export-symbol")
                    (if seen-export
                      (ErrAstDecl
                        "parse: duplicate define :export-symbol metadata")
                      (match (parse-ast-define-fn-export-tail
                        (box-get after-key))
                        [(OkAstFnExport parsed-export)
                          (parse-ast-define-fn-rest
                            dispatch
                            name
                            params
                            parsed-export
                            true
                            (sp-node-get tail))]
                        [(ErrAstFnExport message) (ErrAstDecl message)]))
                    (if (compiler-parse-metadata-key? key)
                      (ErrAstDecl
                        (string-append "parse: unknown define metadata " key))
                      (ErrAstDecl
                        "parse: malformed define :export-symbol metadata")))]
                [_ (ErrAstDecl "parse: malformed function definition")])]
            [_ (ErrAstDecl "parse: malformed function definition")])
          (match (sp-node-get tail)
            [(SpSNil _)
              (match (parse-ast-expr dispatch (sp-node-get first))
                [(OkAstExpr parsed-body)
                  (parse-ast-define-fn-finish
                    name
                    params
                    (AstTyUnit)
                    parsed-body
                    export)]
                [(ErrAstExpr message) (ErrAstDecl message)])]
            [_ (ErrAstDecl "parse: expected ':' in function definition")])))]
    [_ (ErrAstDecl "parse: malformed function definition")]))

(define (parse-ast-define-fn
  [dispatch : SymI64Env]
  [name : String]
  [params : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-param-list dispatch (spanned-sexpr-form params))
    [(OkAstParamList parsed-params)
      (parse-ast-define-fn-rest
        dispatch
        name
        parsed-params
        AstFnNoExport
        false
        rest)]
    [(ErrAstParamList message) (ErrAstDecl message)]))

(define (parse-ast-define [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons head after-name _)
      (match (sp-node-get head)
        [(SpSSym name _)
          (parse-ast-define-value dispatch name (sp-node-get after-name))]
        [(SpSCons name-node params _)
          (match (sp-node-get name-node)
            [(SpSSym name _)
              (parse-ast-define-fn
                dispatch
                name
                (sp-node-get params)
                (sp-node-get after-name))]
            [_ (ErrAstDecl "parse: malformed define")])]
        [_ (ErrAstDecl "parse: malformed define")])]
    [_ (ErrAstDecl "parse: malformed define")]))

(define (parse-ast-defmacro [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons header after-header _)
      (match (sp-node-get header)
        [(SpSCons name-node params _)
          (match (sp-node-get name-node)
            [(SpSSym name _)
              (match (sp-node-get after-header)
                [(SpSCons colon ret-tail _)
                  (match (sp-node-get ret-tail)
                    [(SpSCons ret body-tail _)
                      (match (sp-node-get body-tail)
                        [(SpSCons body end _)
                          (match (sp-node-get end)
                            [(SpSNil _)
                              (if (sexpr-colon?
                                (spanned-sexpr-form (sp-node-get colon)))
                                (match (parse-ast-macro-param-list
                                  dispatch
                                  (spanned-sexpr-form (sp-node-get params)))
                                  [(OkAstMacroParamList parsed-params)
                                    (match (parse-ast-type
                                      dispatch
                                      (spanned-sexpr-form (sp-node-get ret)))
                                      [(OkAstType parsed-ret)
                                        (match (parse-ast-expr
                                          dispatch
                                          (sp-node-get body))
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

(define (parse-ast-extern-varargs-typed-name? [name : String]) : bool
  (if (> (string-length name) 3)
    (string-eq (substring name 0 3) "...")
    false))

(define (parse-ast-extern-varargs-tail-type
  [dispatch : SymI64Env]
  [name : String]) : ResultAstType
  (if (parse-ast-extern-varargs-typed-name? name)
    (parse-ast-type
      dispatch
      (SSym (substring name 3 (- (string-length name) 3))))
    (ErrAstType "parse: expected typed extern varargs tail")))

(define (parse-ast-extern-head-fixed-param
  [dispatch : SymI64Env]
  [item : SpannedSexpr]) : ResultAstExternHeadItem
  (match (parse-ast-param dispatch (spanned-sexpr-form item))
    [(OkAstParam param)
      (match param
        [(AstParam _ ty comptime?)
          (if comptime?
            (ErrAstExternHeadItem "parse: extern parameters cannot be comptime")
            (OkAstExternHeadItem (AstExternHeadParam ty)))])]
    [(ErrAstParam message) (ErrAstExternHeadItem message)]))

(define (parse-ast-extern-head-bracket-item
  [dispatch : SymI64Env]
  [item : SpannedSexpr]
  [items : SpannedSexpr]) : ResultAstExternHeadItem
  (match items
    [(SpSCons _ after-name _)
      (match (sp-node-get after-name)
        [(SpSCons colon after-colon _)
          (match (sp-node-get after-colon)
            [(SpSCons ty-node end _)
              (match (sp-node-get end)
                [(SpSNil _)
                  (if (sexpr-colon? (spanned-sexpr-form (sp-node-get colon)))
                    (match (sp-node-get ty-node)
                      [(SpSSym ty-name _)
                        (if (string-eq ty-name "...")
                          (ErrAstExternHeadItem
                            "parse: extern typed varargs tail needs a type")
                          (if (parse-ast-extern-varargs-typed-name? ty-name)
                            (match (parse-ast-extern-varargs-tail-type
                              dispatch
                              ty-name)
                              [(OkAstType tail-ty)
                                (OkAstExternHeadItem
                                  (AstExternHeadVarargsTyped tail-ty))]
                              [(ErrAstType message)
                                (ErrAstExternHeadItem message)])
                            (parse-ast-extern-head-fixed-param dispatch item)))]
                      [_ (parse-ast-extern-head-fixed-param dispatch item)])
                    (parse-ast-extern-head-fixed-param dispatch item))]
                [_ (parse-ast-extern-head-fixed-param dispatch item)])]
            [_ (parse-ast-extern-head-fixed-param dispatch item)])]
        [_ (parse-ast-extern-head-fixed-param dispatch item)])]
    [_ (parse-ast-extern-head-fixed-param dispatch item)]))

(define (parse-ast-extern-head-item
  [dispatch : SymI64Env]
  [item : SpannedSexpr]) : ResultAstExternHeadItem
  (match item
    [(SpSSym name _)
      (if (string-eq name "...")
        (OkAstExternHeadItem (AstExternHeadVarargsOpen))
        (if (parse-ast-extern-varargs-typed-name? name)
          (ErrAstExternHeadItem
            "parse: typed extern varargs tail must use bracket syntax")
          (ErrAstExternHeadItem "parse: malformed extern function head")))]
    [(SpSBracketList items _)
      (parse-ast-extern-head-bracket-item dispatch item (sp-node-get items))]
    [_ (ErrAstExternHeadItem "parse: malformed extern function head")]))

(define (parse-ast-extern-head-items
  [dispatch : SymI64Env]
  [items : SpannedSexpr]) : ResultAstExternHeader
  (match items
    [(SpSNil _) (OkAstExternHeader "" AstTypeNil (AstExternAbiC))]
    [(SpSCons item tail _)
      (let
        [item : SpannedSexpr (sp-node-get item)]
        [tail : SpannedSexpr (sp-node-get tail)]
        (match (parse-ast-extern-head-item dispatch item)
          [(OkAstExternHeadItem parsed-item)
            (match parsed-item
              [(AstExternHeadParam ty)
                (match (parse-ast-extern-head-items dispatch tail)
                  [(OkAstExternHeader _ parsed-tail parsed-abi)
                    (OkAstExternHeader
                      ""
                      (ast-type-cons ty parsed-tail)
                      parsed-abi)]
                  [(ErrAstExternHeader message) (ErrAstExternHeader message)])]
              [(AstExternHeadVarargsOpen)
                (match tail
                  [(SpSNil _)
                    (OkAstExternHeader "" AstTypeNil (AstExternAbiCVarargsOpen))]
                  [_
                    (ErrAstExternHeader
                      "parse: extern varargs tail must be final")])]
              [(AstExternHeadVarargsTyped tail-ty)
                (match tail
                  [(SpSNil _)
                    (OkAstExternHeader
                      ""
                      AstTypeNil
                      (AstExternAbiCVarargsTyped tail-ty))]
                  [_
                    (ErrAstExternHeader
                      "parse: extern varargs tail must be final")])])]
          [(ErrAstExternHeadItem message) (ErrAstExternHeader message)]))]
    [_ (ErrAstExternHeader "parse: malformed extern function head")]))

(define (parse-ast-extern-header [dispatch : SymI64Env] [head : SpannedSexpr]) : ResultAstExternHeader
  (match head
    [(SpSCons name-node params _)
      (match (sp-node-get name-node)
        [(SpSSym name _)
          (match (parse-ast-extern-head-items dispatch (sp-node-get params))
            [(OkAstExternHeader _ param-types abi)
              (OkAstExternHeader name param-types abi)]
            [(ErrAstExternHeader message) (ErrAstExternHeader message)])]
        [_ (ErrAstExternHeader "parse: malformed extern function head")])]
    [_ (ErrAstExternHeader "parse: malformed extern function head")]))

(define (parse-ast-extern-c-varargs-legacy-message) : String
  "parse: legacy :abi c-varargs metadata is retired; use function-head ... or ...T varargs")

(define (parse-ast-extern-abi-tail [tail : Sexpr]) : ResultAstExternAbi
  (match tail
    [(SCons name-node rest)
      (match (box-get name-node)
        [(SSym name)
          (match (box-get rest)
            [(SNil)
              (if (string-eq name "c")
                (OkAstExternAbi (AstExternAbiC))
                (if (string-eq name "c-varargs")
                  (ErrAstExternAbi (parse-ast-extern-c-varargs-legacy-message))
                  (ErrAstExternAbi
                    (string-append "parse: unknown extern ABI " name))))]
            [(SCons fixed-node end)
              (match (box-get end)
                [(SNil)
                  (match (box-get fixed-node)
                    [(SInt _)
                      (if (string-eq name "c-varargs")
                        (ErrAstExternAbi
                          (parse-ast-extern-c-varargs-legacy-message))
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

(define (parse-ast-extern-abi-combine
  [base : AstExternAbi]
  [parsed : AstExternAbi]) : ResultAstExternAbi
  (if (ast-extern-abi-c-varargs? base)
    (match parsed
      [(AstExternAbiC) (OkAstExternAbi base)]
      [_
        (ErrAstExternAbi
          "parse: extern varargs tail cannot be combined with another ABI")])
    (OkAstExternAbi parsed)))

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
      (if (sexpr-colon? (spanned-sexpr-form (sp-node-get head)))
        (match (sp-node-get tail)
          [(SpSCons ty end _)
            (match (sp-node-get end)
              [(SpSNil _)
                (match (parse-ast-type
                  dispatch
                  (spanned-sexpr-form (sp-node-get ty)))
                  [(OkAstType parsed-ty)
                    (OkAstExternParts
                      (AstExternMetadata abi symbol link-inputs seen-abi)
                      parsed-ty)]
                  [(ErrAstType message) (ErrAstExternParts message)])]
              [_ (ErrAstExternParts "parse: malformed extern")])]
          [_ (ErrAstExternParts "parse: malformed extern")])
        (match (spanned-sexpr-form (sp-node-get head))
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
                            (sp-node-get tail)
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
                            (sp-node-get tail)
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
                          (sp-node-get tail)
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
                          (sp-node-get tail)
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
                          (sp-node-get tail)
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

(define (parse-ast-extern-head-finish
  [abi : AstExternAbi]
  [symbol : String]
  [link-inputs : AstExternLinkInputList]
  [seen-abi : bool]
  [param-types : AstTypeList]
  [ret : AstType]) : ResultAstExternParts
  (OkAstExternParts
    (AstExternMetadata abi symbol link-inputs seen-abi)
    (ast-ty-func param-types ret)))

(define (parse-ast-extern-head-post-ret
  [dispatch : SymI64Env]
  [items : SpannedSexpr]
  [abi : AstExternAbi]
  [symbol : String]
  [link-inputs : AstExternLinkInputList]
  [seen-abi : bool]
  [seen-symbol : bool]
  [param-types : AstTypeList]
  [ret : AstType]) : ResultAstExternParts
  (match items
    [(SpSNil _)
      (parse-ast-extern-head-finish
        abi
        symbol
        link-inputs
        seen-abi
        param-types
        ret)]
    [(SpSCons head tail _)
      (match (spanned-sexpr-form (sp-node-get head))
        [(SCons key-node after-key)
          (match (box-get key-node)
            [(SSym key)
              (cond
                [(string-eq key ":abi")
                  (if seen-abi
                    (ErrAstExternParts "parse: duplicate extern :abi metadata")
                    (match (parse-ast-extern-abi-tail (box-get after-key))
                      [(OkAstExternAbi parsed-abi)
                        (match (parse-ast-extern-abi-combine abi parsed-abi)
                          [(OkAstExternAbi combined-abi)
                            (parse-ast-extern-head-post-ret
                              dispatch
                              (sp-node-get tail)
                              combined-abi
                              symbol
                              link-inputs
                              true
                              seen-symbol
                              param-types
                              ret)]
                          [(ErrAstExternAbi message)
                            (ErrAstExternParts message)])]
                      [(ErrAstExternAbi message) (ErrAstExternParts message)]))]
                [(string-eq key ":symbol")
                  (if seen-symbol
                    (ErrAstExternParts
                      "parse: duplicate extern :symbol metadata")
                    (match (parse-ast-extern-symbol-tail (box-get after-key))
                      [(OkAstExternSymbol parsed-symbol)
                        (parse-ast-extern-head-post-ret
                          dispatch
                          (sp-node-get tail)
                          abi
                          parsed-symbol
                          link-inputs
                          seen-abi
                          true
                          param-types
                          ret)]
                      [(ErrAstExternSymbol message) (ErrAstExternParts message)]))]
                [(string-eq key ":link-lib")
                  (match (parse-ast-extern-string-tail
                    ":link-lib"
                    (box-get after-key))
                    [(OkAstExternSymbol value)
                      (parse-ast-extern-head-post-ret
                        dispatch
                        (sp-node-get tail)
                        abi
                        symbol
                        (ast-extern-link-input-list-append
                          link-inputs
                          (AstExternLinkLib value))
                        seen-abi
                        seen-symbol
                        param-types
                        ret)]
                    [(ErrAstExternSymbol message) (ErrAstExternParts message)])]
                [(string-eq key ":link-search")
                  (match (parse-ast-extern-string-tail
                    ":link-search"
                    (box-get after-key))
                    [(OkAstExternSymbol value)
                      (parse-ast-extern-head-post-ret
                        dispatch
                        (sp-node-get tail)
                        abi
                        symbol
                        (ast-extern-link-input-list-append
                          link-inputs
                          (AstExternLinkSearch value))
                        seen-abi
                        seen-symbol
                        param-types
                        ret)]
                    [(ErrAstExternSymbol message) (ErrAstExternParts message)])]
                [(string-eq key ":link-arg")
                  (match (parse-ast-extern-string-tail
                    ":link-arg"
                    (box-get after-key))
                    [(OkAstExternSymbol value)
                      (parse-ast-extern-head-post-ret
                        dispatch
                        (sp-node-get tail)
                        abi
                        symbol
                        (ast-extern-link-input-list-append
                          link-inputs
                          (AstExternLinkArg value))
                        seen-abi
                        seen-symbol
                        param-types
                        ret)]
                    [(ErrAstExternSymbol message) (ErrAstExternParts message)])]
                [(compiler-parse-metadata-key? key)
                  (ErrAstExternParts
                    (string-append "parse: unknown extern metadata " key))]
                [else (ErrAstExternParts "parse: malformed extern")])]
            [_ (ErrAstExternParts "parse: malformed extern")])]
        [_ (ErrAstExternParts "parse: malformed extern")])]
    [_ (ErrAstExternParts "parse: malformed extern")]))

(define (parse-ast-extern-head-rest
  [dispatch : SymI64Env]
  [items : SpannedSexpr]
  [abi : AstExternAbi]
  [symbol : String]
  [link-inputs : AstExternLinkInputList]
  [seen-abi : bool]
  [seen-symbol : bool]
  [param-types : AstTypeList]) : ResultAstExternParts
  (match items
    [(SpSCons head tail _)
      (if (sexpr-colon? (spanned-sexpr-form (sp-node-get head)))
        (match (sp-node-get tail)
          [(SpSCons ret end _)
            (match (sp-node-get end)
              [(SpSNil _)
                (match (parse-ast-type
                  dispatch
                  (spanned-sexpr-form (sp-node-get ret)))
                  [(OkAstType parsed-ret)
                    (parse-ast-extern-head-finish
                      abi
                      symbol
                      link-inputs
                      seen-abi
                      param-types
                      parsed-ret)]
                  [(ErrAstType message) (ErrAstExternParts message)])]
              [_
                (match (parse-ast-type
                  dispatch
                  (spanned-sexpr-form (sp-node-get ret)))
                  [(OkAstType parsed-ret)
                    (parse-ast-extern-head-post-ret
                      dispatch
                      (sp-node-get end)
                      abi
                      symbol
                      link-inputs
                      seen-abi
                      seen-symbol
                      param-types
                      parsed-ret)]
                  [(ErrAstType message) (ErrAstExternParts message)])])]
          [_ (ErrAstExternParts "parse: malformed extern")])
        (match (spanned-sexpr-form (sp-node-get head))
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
                          (match (parse-ast-extern-abi-combine abi parsed-abi)
                            [(OkAstExternAbi combined-abi)
                              (parse-ast-extern-head-rest
                                dispatch
                                (sp-node-get tail)
                                combined-abi
                                symbol
                                link-inputs
                                true
                                seen-symbol
                                param-types)]
                            [(ErrAstExternAbi message)
                              (ErrAstExternParts message)])]
                        [(ErrAstExternAbi message) (ErrAstExternParts message)]))]
                  [(string-eq key ":symbol")
                    (if seen-symbol
                      (ErrAstExternParts
                        "parse: duplicate extern :symbol metadata")
                      (match (parse-ast-extern-symbol-tail (box-get after-key))
                        [(OkAstExternSymbol parsed-symbol)
                          (parse-ast-extern-head-rest
                            dispatch
                            (sp-node-get tail)
                            abi
                            parsed-symbol
                            link-inputs
                            seen-abi
                            true
                            param-types)]
                        [(ErrAstExternSymbol message)
                          (ErrAstExternParts message)]))]
                  [(string-eq key ":link-lib")
                    (match (parse-ast-extern-string-tail
                      ":link-lib"
                      (box-get after-key))
                      [(OkAstExternSymbol value)
                        (parse-ast-extern-head-rest
                          dispatch
                          (sp-node-get tail)
                          abi
                          symbol
                          (ast-extern-link-input-list-append
                            link-inputs
                            (AstExternLinkLib value))
                          seen-abi
                          seen-symbol
                          param-types)]
                      [(ErrAstExternSymbol message) (ErrAstExternParts message)])]
                  [(string-eq key ":link-search")
                    (match (parse-ast-extern-string-tail
                      ":link-search"
                      (box-get after-key))
                      [(OkAstExternSymbol value)
                        (parse-ast-extern-head-rest
                          dispatch
                          (sp-node-get tail)
                          abi
                          symbol
                          (ast-extern-link-input-list-append
                            link-inputs
                            (AstExternLinkSearch value))
                          seen-abi
                          seen-symbol
                          param-types)]
                      [(ErrAstExternSymbol message) (ErrAstExternParts message)])]
                  [(string-eq key ":link-arg")
                    (match (parse-ast-extern-string-tail
                      ":link-arg"
                      (box-get after-key))
                      [(OkAstExternSymbol value)
                        (parse-ast-extern-head-rest
                          dispatch
                          (sp-node-get tail)
                          abi
                          symbol
                          (ast-extern-link-input-list-append
                            link-inputs
                            (AstExternLinkArg value))
                          seen-abi
                          seen-symbol
                          param-types)]
                      [(ErrAstExternSymbol message) (ErrAstExternParts message)])]
                  [(compiler-parse-metadata-key? key)
                    (ErrAstExternParts
                      (string-append "parse: unknown extern metadata " key))]
                  [else (ErrAstExternParts "parse: expected ':' in extern")])]
              [_ (ErrAstExternParts "parse: expected ':' in extern")])]
          [_ (ErrAstExternParts "parse: expected ':' in extern")]))]
    [_ (ErrAstExternParts "parse: malformed extern")]))

(define (parse-ast-extern-function-head
  [dispatch : SymI64Env]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-extern-header dispatch head)
    [(OkAstExternHeader name param-types abi)
      (match (parse-ast-extern-head-rest
        dispatch
        rest
        abi
        name
        AstExternLinkInputNil
        false
        false
        param-types)
        [(OkAstExternParts metadata ty)
          (OkAstDecl (ast-decl-extern name (AstExternFunction) metadata ty))]
        [(ErrAstExternParts message) (ErrAstDecl message)])]
    [(ErrAstExternHeader message) (ErrAstDecl message)]))

(define (parse-ast-extern [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons name-node after-name _)
      (match (sp-node-get name-node)
        [(SpSSym name _)
          (match (parse-ast-extern-items
            dispatch
            (sp-node-get after-name)
            (AstExternAbiC)
            name
            AstExternLinkInputNil
            false
            false)
            [(OkAstExternParts metadata parsed-ty)
              (OkAstDecl
                (ast-decl-extern name (AstExternValue) metadata parsed-ty))]
            [(ErrAstExternParts message) (ErrAstDecl message)])]
        [_
          (parse-ast-extern-function-head
            dispatch
            (sp-node-get name-node)
            (sp-node-get after-name))])]
    [_ (ErrAstDecl "parse: malformed extern")]))

(define (parse-ast-defenum [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons name-node variants _)
      (match (sp-node-get name-node)
        [(SpSSym name _)
          (match (parse-ast-defenum-items
            dispatch
            (sp-node-get variants)
            AstLifetimeNil
            (AstEnumNoCleanup)
            false
            false
            false)
            [(OkAstEnumDefParts lifetimes cleanup parsed-variants)
              (match parsed-variants
                [(AstVariantDefNil)
                  (ErrAstDecl "parse: defenum needs at least one variant")]
                [_
                  (match lifetimes
                    [(AstLifetimeNil)
                      (OkAstDecl
                        (ast-decl-def-enum name cleanup parsed-variants))]
                    [_
                      (OkAstDecl
                        (ast-decl-def-enum-lifetimes
                          name
                          lifetimes
                          cleanup
                          parsed-variants))])])]
            [(ErrAstEnumDefParts message) (ErrAstDecl message)])]
        [_ (ErrAstDecl "parse: malformed defenum")])]
    [_ (ErrAstDecl "parse: malformed defenum")]))

(define (parse-ast-defstruct [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons name-node fields _)
      (match (sp-node-get name-node)
        [(SpSSym name _)
          (match (parse-ast-defstruct-items
            dispatch
            (sp-node-get fields)
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
                        (ast-decl-def-struct name repr cleanup parsed-fields))]
                    [_
                      (OkAstDecl
                        (ast-decl-def-struct-lifetimes
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
      (match (sp-node-get name-node)
        [(SpSSym name _)
          (match (parse-ast-dispatch-variant-list (sp-node-get variants))
            [(OkAstDispatchVariantList parsed-variants)
              (match parsed-variants
                [(AstDispatchVariantNil)
                  (ErrAstDecl "parse: defdispatch needs at least one variant")]
                [_ (OkAstDecl (ast-decl-def-dispatch name parsed-variants))])]
            [(ErrAstDispatchVariantList message) (ErrAstDecl message)])]
        [_ (ErrAstDecl "parse: malformed defdispatch")])]
    [_ (ErrAstDecl "parse: malformed defdispatch")]))

(define (parse-ast-module [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons name-node end _)
      (match (sp-node-get end)
        [(SpSNil _)
          (match (sp-node-get name-node)
            [(SpSSym name _) (OkAstDecl (ast-decl-module name))]
            [_ (ErrAstDecl "parse: malformed module")])]
        [_ (ErrAstDecl "parse: malformed module")])]
    [_ (ErrAstDecl "parse: malformed module")]))

(define (parse-ast-import-spec
  [kind : AstImportKind]
  [path : String]
  [module-name : AstMaybeModuleName]
  [alias : AstMaybeImportAlias]
  [span : AstSourceSpan]) : ResultAstDecl
  (OkAstDecl (AstDeclImport (AstImportSpec kind path module-name alias span))))

(define (parse-ast-import-alias
  [kind : AstImportKind]
  [path : String]
  [module-name : AstMaybeModuleName]
  [tail : SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match tail
    [(SpSCons as-node alias-tail _)
      (match (sp-node-get as-node)
        [(SpSSym as-name _)
          (match (sp-node-get alias-tail)
            [(SpSCons alias-node end _)
              (match (sp-node-get end)
                [(SpSNil _)
                  (match (sp-node-get alias-node)
                    [(SpSSym alias _)
                      (if (or
                        (string-eq as-name "as")
                        (string-eq as-name ":as"))
                        (parse-ast-import-spec
                          kind
                          path
                          module-name
                          (AstSomeImportAlias alias)
                          span)
                        (ErrAstDecl "parse: malformed import"))]
                    [_ (ErrAstDecl "parse: malformed import")])]
                [_ (ErrAstDecl "parse: malformed import")])]
            [_ (ErrAstDecl "parse: malformed import")])]
        [_ (ErrAstDecl "parse: malformed import")])]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-import-module-tail
  [path : String]
  [tail : SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match tail
    [(SpSCons module-name-node after-module _)
      (match (sp-node-get module-name-node)
        [(SpSSym module-name _)
          (match (sp-node-get after-module)
            [(SpSNil _)
              (parse-ast-import-spec
                (AstImportPath)
                path
                (AstSomeModuleName module-name)
                AstNoImportAlias
                span)]
            [_
              (parse-ast-import-alias
                (AstImportPath)
                path
                (AstSomeModuleName module-name)
                (sp-node-get after-module)
                span)])]
        [_ (ErrAstDecl "parse: malformed import")])]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-import-tail
  [path : String]
  [tail : SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match tail
    [(SpSNil _)
      (parse-ast-import-spec
        (AstImportPath)
        path
        AstNoModuleName
        AstNoImportAlias
        span)]
    [(SpSCons head-node after-head _)
      (match (sp-node-get head-node)
        [(SpSSym head _)
          (if (string-eq head "as")
            (parse-ast-import-alias
              (AstImportPath)
              path
              AstNoModuleName
              tail
              span)
            (if (string-eq head "module")
              (parse-ast-import-module-tail path (sp-node-get after-head) span)
              (ErrAstDecl "parse: malformed import")))]
        [_ (ErrAstDecl "parse: malformed import")])]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-import-macro-tail
  [dispatch : SymI64Env]
  [call-form : SpannedSexpr]
  [tail : SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match (parse-ast-expr dispatch call-form)
    [(OkAstExpr call-expr)
      (match (ast-expr-unspan (ast-node-get call-expr))
        [(AstExprCall _ _)
          (match tail
            [(SpSNil _)
              (parse-ast-import-spec
                (AstImportMacro call-expr)
                ""
                AstNoModuleName
                AstNoImportAlias
                span)]
            [(SpSCons head-node _ _)
              (match (sp-node-get head-node)
                [(SpSSym head _)
                  (if (or (string-eq head "as") (string-eq head ":as"))
                    (parse-ast-import-alias
                      (AstImportMacro call-expr)
                      ""
                      AstNoModuleName
                      tail
                      span)
                    (ErrAstDecl "parse: malformed import"))]
                [_ (ErrAstDecl "parse: malformed import")])]
            [_ (ErrAstDecl "parse: malformed import")])]
        [_ (ErrAstDecl "parse: import macro operand must be a call")])]
    [(ErrAstExpr message) (ErrAstDecl message)]))

(define (parse-ast-dotted-import-tl-suffix? [name : String]) : bool
  (let
    [n : i64 (string-length name)]
    (if (< n 3)
      false
      (string-eq (substring name (- n 3) 3) ".tl"))))

(define (parse-ast-dotted-import-name-valid? [name : String]) : bool
  (let
    [n : i64 (string-length name)]
    [i : i64 0]
    [ok : bool (and (> n 0) (not (parse-ast-dotted-import-tl-suffix? name)))]
    [last-was-dot : bool true]
    (begin
      (while ok
        (if (< i n)
          (let
            [c : char (string-ref name i)]
            (if (or (char-eq c #/') (char-eq c #\\') (char-eq c #:'))
              (set! ok false)
              (if (char-eq c #.')
                (if last-was-dot
                  (set! ok false)
                  (begin
                    (set! last-was-dot true)
                    (set! i (+ i 1))))
                (begin
                  (set! last-was-dot false)
                  (set! i (+ i 1))))))
          (set! ok false)))
      (and (= i n) (not last-was-dot)))))

(define (parse-ast-dotted-import-default-alias [name : String]) : String
  (let
    [n : i64 (string-length name)]
    [i : i64 0]
    [start : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (char-eq (string-ref name i) #.')
            (set! start (+ i 1))
            unit)
          (set! i (+ i 1))))
      (substring name start (- n start)))))

(define (parse-ast-dotted-import-tail
  [module-name : String]
  [tail : SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (if (not (parse-ast-dotted-import-name-valid? module-name))
    (ErrAstDecl "parse: invalid dotted import module name")
    (match tail
      [(SpSNil _)
        (parse-ast-import-spec
          (AstImportModule)
          module-name
          (AstSomeModuleName module-name)
          (AstSomeImportAlias
            (parse-ast-dotted-import-default-alias module-name))
          span)]
      [(SpSCons head-node _ _)
        (match (sp-node-get head-node)
          [(SpSSym head _)
            (if (or (string-eq head "as") (string-eq head ":as"))
              (parse-ast-import-alias
                (AstImportModule)
                module-name
                (AstSomeModuleName module-name)
                tail
                span)
              (ErrAstDecl "parse: malformed import"))]
          [_ (ErrAstDecl "parse: malformed import")])]
      [_ (ErrAstDecl "parse: malformed import")])))

(define (parse-ast-import
  [dispatch : SymI64Env]
  [rest : SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match rest
    [(SpSCons path-node tail _)
      (match (sp-node-get path-node)
        [(SpSStr path _) (parse-ast-import-tail path (sp-node-get tail) span)]
        [(SpSSym module-name _)
          (parse-ast-dotted-import-tail module-name (sp-node-get tail) span)]
        [(SpSCons _ _ _)
          (parse-ast-import-macro-tail
            dispatch
            (sp-node-get path-node)
            (sp-node-get tail)
            span)]
        [_ (ErrAstDecl "parse: malformed import")])]
    [_ (ErrAstDecl "parse: malformed import")]))

(define (parse-ast-include-str [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSNil _) (ErrAstDecl "parse: include-str expects name and string path")]
    [(SpSCons name-node tail _)
      (match (sp-node-get name-node)
        [(SpSSym name _)
          (match (sp-node-get tail)
            [(SpSCons path-node after-path _)
              (match (sp-node-get path-node)
                [(SpSStr path _)
                  (match (sp-node-get after-path)
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

(define (parse-ast-include-bin [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSNil _) (ErrAstDecl "parse: include-bin expects name and string path")]
    [(SpSCons name-node tail _)
      (match (sp-node-get name-node)
        [(SpSSym name _)
          (match (sp-node-get tail)
            [(SpSCons path-node after-path _)
              (match (sp-node-get path-node)
                [(SpSStr path _)
                  (match (sp-node-get after-path)
                    [(SpSNil _) (OkAstDecl (AstDeclIncludeBin name path))]
                    [_
                      (ErrAstDecl
                        "parse: include-bin expects exactly two operands")])]
                [_ (ErrAstDecl "parse: include-bin path must be a string")])]
            [(SpSNil _)
              (ErrAstDecl "parse: include-bin expects name and string path")]
            [_ (ErrAstDecl "parse: include-bin expects exactly two operands")])]
        [_ (ErrAstDecl "parse: include-bin name must be a symbol")])]
    [_ (ErrAstDecl "parse: malformed include-bin")]))

(define (parse-ast-export-item [item : SpannedSexpr]) : ResultAstExportItem
  (match item
    [(SpSCons kind-node rest _)
      (match (sp-node-get kind-node)
        [(SpSSym kind _)
          (cond
            [(string-eq kind "value")
              (match (sp-node-get rest)
                [(SpSCons name-node end _)
                  (match (sp-node-get end)
                    [(SpSNil _)
                      (match (sp-node-get name-node)
                        [(SpSSym name _)
                          (OkAstExportItem (AstExportValue name))]
                        [_ (ErrAstExportItem "parse: malformed export item")])]
                    [_ (ErrAstExportItem "parse: malformed export item")])]
                [_ (ErrAstExportItem "parse: malformed export item")])]
            [(string-eq kind "type")
              (match (sp-node-get rest)
                [(SpSCons name-node end _)
                  (match (sp-node-get end)
                    [(SpSNil _)
                      (match (sp-node-get name-node)
                        [(SpSSym name _) (OkAstExportItem (AstExportType name))]
                        [_ (ErrAstExportItem "parse: malformed export item")])]
                    [_ (ErrAstExportItem "parse: malformed export item")])]
                [_ (ErrAstExportItem "parse: malformed export item")])]
            [(string-eq kind "macro")
              (match (sp-node-get rest)
                [(SpSCons name-node end _)
                  (match (sp-node-get end)
                    [(SpSNil _)
                      (match (sp-node-get name-node)
                        [(SpSSym name _)
                          (OkAstExportItem (AstExportMacro name))]
                        [_ (ErrAstExportItem "parse: malformed export item")])]
                    [_ (ErrAstExportItem "parse: malformed export item")])]
                [_ (ErrAstExportItem "parse: malformed export item")])]
            [(string-eq kind "constructor")
              (match (sp-node-get rest)
                [(SpSCons name-node end _)
                  (match (sp-node-get end)
                    [(SpSNil _)
                      (match (sp-node-get name-node)
                        [(SpSSym name _)
                          (OkAstExportItem (AstExportConstructor name))]
                        [_ (ErrAstExportItem "parse: malformed export item")])]
                    [_ (ErrAstExportItem "parse: malformed export item")])]
                [_ (ErrAstExportItem "parse: malformed export item")])]
            [(string-eq kind "field")
              (match (sp-node-get rest)
                [(SpSCons type-node field-tail _)
                  (match (sp-node-get field-tail)
                    [(SpSCons field-node end _)
                      (match (sp-node-get end)
                        [(SpSNil _)
                          (match (sp-node-get type-node)
                            [(SpSSym type-name _)
                              (match (sp-node-get field-node)
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
              (match (sp-node-get rest)
                [(SpSCons name-node end _)
                  (match (sp-node-get end)
                    [(SpSNil _)
                      (match (sp-node-get name-node)
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
      (match (parse-ast-export-item (sp-node-get item))
        [(OkAstExportItem parsed)
          (match (parse-ast-export-item-list (sp-node-get rest))
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

(define (parse-ast-test-body [exprs : AstExprList]) : i64
  (match exprs
    [(AstExprCons only rest)
      (let
        [rest-list : AstExprList (box-get rest)]
        (match rest-list
          [(AstExprNil) only]
          [_ (ast-node-push (AstExprBegin exprs))]))]
    [_ (ast-node-push (AstExprBegin exprs))]))

(define (parse-ast-test
  [dispatch : SymI64Env]
  [rest : SpannedSexpr]
  [form-span : AstSourceSpan]) : ResultAstDecl
  (match rest
    [(SpSCons name-node body-forms _)
      (match (sp-node-get name-node)
        [(SpSSym name _)
          (match (sp-node-get body-forms)
            [(SpSNil _)
              (ErrAstDecl "parse: test needs at least one expression")]
            [_
              (match (parse-ast-expr-list dispatch (sp-node-get body-forms))
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
      (match (sp-node-get head-node)
        [(SpSSym head _)
          (if (string-eq head ":generated")
            (match (sp-node-get meta-rest)
              [(SpSCons generator-node item-tail _)
                (match (sp-node-get generator-node)
                  [(SpSSym generator-name _)
                    (match (sp-node-get item-tail)
                      [(SpSCons item-node arg-key-forms _)
                        (match (sp-node-get item-node)
                          [(SpSSym item-name _)
                            (match (parse-ast-expr-list
                              dispatch
                              (sp-node-get arg-key-forms))
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
      (match (sp-node-get head-node)
        [(SpSSym head _)
          (let
            [tag : i64 (compiler-parse-dispatch-tag dispatch head)]
            (cond
              [(= tag (compiler-parse-tag-decl-define))
                (parse-ast-define dispatch (sp-node-get template-rest))]
              [(= tag (compiler-parse-tag-decl-defenum))
                (parse-ast-defenum dispatch (sp-node-get template-rest))]
              [(= tag (compiler-parse-tag-decl-defstruct))
                (parse-ast-defstruct dispatch (sp-node-get template-rest))]
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
      (match (sp-node-get tail)
        [(SpSNil _)
          (parse-ast-comptime-decl-with-meta
            dispatch
            AstNoGeneratedDeclMeta
            (sp-node-get first))]
        [(SpSCons template end _)
          (match (sp-node-get end)
            [(SpSNil _)
              (match (parse-ast-generated-decl-meta
                dispatch
                (sp-node-get first))
                [(OkAstGeneratedDeclMeta parsed-meta)
                  (parse-ast-comptime-decl-with-meta
                    dispatch
                    parsed-meta
                    (sp-node-get template))]
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

(define (parse-ast-generated-decls-meta
  [dispatch : SymI64Env]
  [meta : SpannedSexpr]) : ResultAstGeneratedDeclMeta
  (match meta
    [(SpSCons head-node meta-rest _)
      (match (sp-node-get head-node)
        [(SpSSym head _)
          (if (string-eq head ":generated")
            (match (sp-node-get meta-rest)
              [(SpSCons generator-node arg-key-forms _)
                (match (sp-node-get generator-node)
                  [(SpSSym generator-name _)
                    (match (parse-ast-expr-list
                      dispatch
                      (sp-node-get arg-key-forms))
                      [(OkAstExprList arg-keys)
                        (OkAstGeneratedDeclMeta
                          (AstSomeGeneratedDeclMeta
                            generator-name
                            ""
                            arg-keys
                            ""))]
                      [(ErrAstExprList message)
                        (ErrAstGeneratedDeclMeta message)])]
                  [_
                    (ErrAstGeneratedDeclMeta
                      "parse: :generated metadata expects generator name and argument key expressions")])]
              [_
                (ErrAstGeneratedDeclMeta
                  "parse: :generated metadata expects generator name and argument key expressions")])
            (ErrAstGeneratedDeclMeta
              "parse: comptime-decls metadata must be :generated"))]
        [_
          (ErrAstGeneratedDeclMeta
            "parse: comptime-decls metadata must be :generated")])]
    [_
      (ErrAstGeneratedDeclMeta
        "parse: comptime-decls metadata must be :generated")]))

(define (parse-ast-generated-payload-name [decl : AstDecl]) : ResultAstDeclName
  (match decl
    [(AstDeclDef name _ _) (OkAstDeclName (intern-str name))]
    [(AstDeclDefFn name _ _ _ _) (OkAstDeclName (intern-str name))]
    [(AstDeclDefEnum name _ _) (OkAstDeclName (intern-str name))]
    [(AstDeclDefEnumLifetimes name _ _ _) (OkAstDeclName (intern-str name))]
    [(AstDeclDefStruct name _ _ _) (OkAstDeclName (intern-str name))]
    [(AstDeclDefStructLifetimes name _ _ _ _) (OkAstDeclName (intern-str name))]
    [_
      (ErrAstDeclName
        "parse: comptime-decls payload must declare a visible item")]))

(define (parse-ast-comptime-decls-wrap
  [meta : AstGeneratedDeclMeta]
  [template : AstDecl]) : ResultAstDecl
  (match meta
    [(AstSomeGeneratedDeclMeta generator-name _ arg-keys _)
      (match (parse-ast-generated-payload-name template)
        [(OkAstDeclName item-name)
          (OkAstDecl
            (ast-decl-comptime-decl-with-meta
              (AstSomeGeneratedDeclMeta generator-name item-name arg-keys "")
              template))]
        [(ErrAstDeclName message) (ErrAstDecl message)])]
    [(AstNoGeneratedDeclMeta)
      (ErrAstDecl "parse: comptime-decls metadata must be :generated")]))

(define (parse-ast-comptime-decls-payloads
  [dispatch : SymI64Env]
  [meta : AstGeneratedDeclMeta]
  [templates : SpannedSexpr]) : ResultAstDeclList
  (match templates
    [(SpSNil _) (OkAstDeclList AstDeclNil)]
    [(SpSCons template rest _)
      (match (parse-ast-comptime-decl-payload dispatch (sp-node-get template))
        [(OkAstDecl parsed-template)
          (match (parse-ast-comptime-decls-wrap meta parsed-template)
            [(OkAstDecl wrapped)
              (match (parse-ast-comptime-decls-payloads
                dispatch
                meta
                (sp-node-get rest))
                [(OkAstDeclList wrapped-rest)
                  (OkAstDeclList (ast-decl-cons wrapped wrapped-rest))]
                [(ErrAstDeclList message) (ErrAstDeclList message)])]
            [(ErrAstDecl message) (ErrAstDeclList message)])]
        [(ErrAstDecl message) (ErrAstDeclList message)])]
    [_
      (ErrAstDeclList
        "parse: comptime-decls expects generated metadata plus one or more templates")]))

(define (parse-ast-comptime-decls [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDeclList
  (match rest
    [(SpSCons meta payloads _)
      (match (sp-node-get payloads)
        [(SpSNil _)
          (ErrAstDeclList
            "parse: comptime-decls expects generated metadata plus one or more templates")]
        [_
          (match (parse-ast-generated-decls-meta dispatch (sp-node-get meta))
            [(OkAstGeneratedDeclMeta parsed-meta)
              (parse-ast-comptime-decls-payloads
                dispatch
                parsed-meta
                (sp-node-get payloads))]
            [(ErrAstGeneratedDeclMeta message) (ErrAstDeclList message)])])]
    [_
      (ErrAstDeclList
        "parse: comptime-decls expects generated metadata plus one or more templates")]))

(define (parse-ast-unsafe-decl [dispatch : SymI64Env] [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpSCons inner end _)
      (match (sp-node-get end)
        [(SpSNil _)
          (match (parse-ast-decl dispatch (sp-node-get inner))
            [(OkAstDecl decl)
              (match decl
                [(AstDeclDefFn _ _ _ _ _) (OkAstDecl (ast-decl-unsafe decl))]
                [(AstDeclExtern _ _ _ _) (OkAstDecl (ast-decl-unsafe decl))]
                [_
                  (ErrAstDecl
                    "parse: unsafe declaration accepts only function define or extern")])]
            [(ErrAstDecl message) (ErrAstDecl message)])]
        [_
          (ErrAstDecl
            "parse: unsafe declaration expects exactly one declaration")])]
    [_ (ErrAstDecl "parse: unsafe declaration expects exactly one declaration")]))

(define (parse-ast-module-macro-call
  [dispatch : SymI64Env]
  [form : SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-expr dispatch form)
    [(OkAstExpr call-expr)
      (match (ast-expr-unspan (ast-node-get call-expr))
        [(AstExprCall _ _)
          (parse-ast-import-spec
            (AstImportMacroDecls call-expr)
            ""
            AstNoModuleName
            AstNoImportAlias
            (ast-source-span-from-source-span (spanned-sexpr-span form)))]
        [_ (ErrAstDecl "parse: expected declaration")])]
    [(ErrAstExpr message) (ErrAstDecl message)]))

(define (parse-ast-decl [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstDecl
  (match s
    [(SpSCons head-node rest _)
      (match (sp-node-get head-node)
        [(SpSSym head _)
          (let
            [tag : i64 (compiler-parse-dispatch-tag dispatch head)]
            (cond
              [(= tag (compiler-parse-tag-decl-define))
                (parse-ast-define dispatch (sp-node-get rest))]
              [(= tag (compiler-parse-tag-decl-extern))
                (parse-ast-extern dispatch (sp-node-get rest))]
              [(= tag (compiler-parse-tag-decl-defenum))
                (parse-ast-defenum dispatch (sp-node-get rest))]
              [(= tag (compiler-parse-tag-decl-defstruct))
                (parse-ast-defstruct dispatch (sp-node-get rest))]
              [(= tag (compiler-parse-tag-decl-defdispatch))
                (parse-ast-defdispatch (sp-node-get rest))]
              [(= tag (compiler-parse-tag-decl-defmacro))
                (parse-ast-defmacro dispatch (sp-node-get rest))]
              [(= tag (compiler-parse-tag-decl-import))
                (parse-ast-import
                  dispatch
                  (sp-node-get rest)
                  (ast-source-span-from-source-span (spanned-sexpr-span s)))]
              [(= tag (compiler-parse-tag-decl-include-str))
                (parse-ast-include-str (sp-node-get rest))]
              [(= tag (compiler-parse-tag-decl-include-bin))
                (parse-ast-include-bin (sp-node-get rest))]
              [(= tag (compiler-parse-tag-decl-module))
                (parse-ast-module (sp-node-get rest))]
              [(= tag (compiler-parse-tag-decl-export))
                (parse-ast-export (sp-node-get rest))]
              [(= tag (compiler-parse-tag-decl-comptime-decl))
                (parse-ast-comptime-decl dispatch (sp-node-get rest))]
              [(= tag (compiler-parse-tag-expr-unsafe))
                (parse-ast-unsafe-decl dispatch (sp-node-get rest))]
              [(= tag (compiler-parse-tag-decl-test))
                (parse-ast-test
                  dispatch
                  (sp-node-get rest)
                  (ast-source-span-from-source-span (spanned-sexpr-span s)))]
              [(compiler-parse-policy-form? head)
                (ErrAstDecl (compiler-parse-abstraction-policy-message))]
              [else (parse-ast-module-macro-call dispatch s)]))]
        [_ (ErrAstDecl "parse: malformed declaration")])]
    [_ (ErrAstDecl "parse: malformed declaration")]))

(define (parse-ast-decl-maybe [dispatch : SymI64Env] [s : SpannedSexpr]) : ResultAstMaybeDecl
  (match s
    [(SpSCons head-node rest _)
      (match (sp-node-get head-node)
        [(SpSSym head _)
          (if (string-eq head "cfg")
            (match (sp-node-get rest)
              [(SpSCons pred decl-tail _)
                (match (sp-node-get decl-tail)
                  [(SpSCons decl-form end _)
                    (match (sp-node-get end)
                      [(SpSNil _)
                        (match (compiler-cfg-eval dispatch (sp-node-get pred))
                          [(OkCompilerCfg enabled)
                            (if enabled
                              (parse-ast-decl-maybe
                                dispatch
                                (sp-node-get decl-form))
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
            (if (=
              (compiler-parse-dispatch-tag dispatch head)
              (compiler-parse-tag-decl-comptime-decls))
              (match (parse-ast-comptime-decls dispatch (sp-node-get rest))
                [(OkAstDeclList decls) (OkAstDecls decls)]
                [(ErrAstDeclList message) (ErrAstMaybeDecl message)])
              (match (parse-ast-decl dispatch s)
                [(OkAstDecl decl) (OkAstSomeDecl decl)]
                [(ErrAstDecl message) (ErrAstMaybeDecl message)])))]
        [_
          (match (parse-ast-decl dispatch s)
            [(OkAstDecl decl) (OkAstSomeDecl decl)]
            [(ErrAstDecl message) (ErrAstMaybeDecl message)])])]
    [_ (ErrAstMaybeDecl "parse: malformed declaration")]))

(define (parse-ast-decl-list-append [front : AstDeclList] [back : AstDeclList]) : AstDeclList
  (match front
    [(AstDeclNil) back]
    [(AstDeclCons head rest)
      (ast-decl-cons head (parse-ast-decl-list-append (box-get rest) back))]))

(define (parse-ast-program-forms
  [dispatch : SymI64Env]
  [toks : (Array SpannedToken)]
  [cur : (Array i64)]) : ResultAstDeclList
  (if (= (peek-spanned-tag toks cur) (tag-end))
    (OkAstDeclList AstDeclNil)
    (let
      ;; The spanned tree for one top-level form is dead once its AstDecl is
      ;; built (the decl carries AST-pool ids + spans by value, no sp ids), so
      ;; truncate the spanned pool back to here before reading the next form.
      ;; Bounds the spanned pool to a single form so it never has to grow.
      [mark : i64 (sp-node-pool-len)]
      (match (read-form-spanned-result toks cur)
        [(OkSpannedSexpr form)
          (match (parse-ast-decl-maybe dispatch form)
            [(OkAstSomeDecl decl)
              (begin
                (sp-node-pool-truncate! mark)
                (match (parse-ast-program-forms dispatch toks cur)
                  [(OkAstDeclList rest)
                    (OkAstDeclList (ast-decl-cons decl rest))]
                  [(ErrAstDeclList message) (ErrAstDeclList message)]))]
            [(OkAstDecls decls)
              (begin
                (sp-node-pool-truncate! mark)
                (match (parse-ast-program-forms dispatch toks cur)
                  [(OkAstDeclList rest)
                    (OkAstDeclList (parse-ast-decl-list-append decls rest))]
                  [(ErrAstDeclList message) (ErrAstDeclList message)]))]
            [(OkAstNoDecl)
              (begin
                (sp-node-pool-truncate! mark)
                (parse-ast-program-forms dispatch toks cur))]
            [(ErrAstMaybeDecl message) (ErrAstDeclList message)])]
        [(ErrSpannedSexpr err) (ErrAstDeclList (source-error-message err))]))))

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
      (sp-node-pool-reset!)
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

(define (parse-ast-repl-module-macro-call-decl? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclImport
        (AstImportSpec
          (AstImportMacroDecls _)
          path
          (AstNoModuleName)
          (AstNoImportAlias)
          _))
      (string-eq path "")]
    [_ false]))

(define (parse-ast-repl-expr-item [dispatch : SymI64Env] [form : SpannedSexpr]) : ResultAstReplItem
  (match (parse-ast-expr dispatch form)
    [(OkAstExpr expr) (OkAstReplItem (AstReplExpr expr))]
    [(ErrAstExpr message) (ErrAstReplItem message)]))

(define (parse-ast-repl-source [src : String]) : ResultAstReplItem
  (match (lex-spanned-result src)
    [(OkSpannedTokens toks)
      (let
        [cur : (Array i64) (make-array i64 1)]
        [dispatch : SymI64Env (parse-ast-program-dispatch)]
        (begin
          (sp-node-pool-reset!)
          (array-set! cur 0 0)
          (if (= (peek-spanned-tag toks cur) (tag-end))
            (ErrAstReplItem "parse: expected REPL input")
            (match (read-form-spanned-result toks cur)
              [(OkSpannedSexpr form)
                (if (= (peek-spanned-tag toks cur) (tag-end))
                  (match (parse-ast-decl dispatch form)
                    [(OkAstDecl decl)
                      (if (parse-ast-repl-module-macro-call-decl? decl)
                        (parse-ast-repl-expr-item dispatch form)
                        (OkAstReplItem (AstReplDecl decl)))]
                    [(ErrAstDecl _) (parse-ast-repl-expr-item dispatch form)])
                  (ErrAstReplItem "parse: trailing tokens after REPL input"))]
              [(ErrSpannedSexpr err)
                (ErrAstReplItem (source-error-message err))]))))]
    [(ErrSpannedTokens err) (ErrAstReplItem (source-error-message err))]))

(define (parse-ast-canonical-diagnostic [diag : CompilerDiagnostic]) : CompilerDiagnostic
  (compiler-diagnostic-with-category
    (compiler-diagnostic-with-code diag (compiler-diagnostic-code-parse))
    "parse"))

(define (parse-ast-program-forms-diagnostic
  [path : String]
  [dispatch : SymI64Env]
  [toks : (Array SpannedToken)]
  [cur : (Array i64)]) : ResultAstDeclListDiagnostic
  (if (= (peek-spanned-tag toks cur) (tag-end))
    (OkAstDeclListDiagnostic AstDeclNil)
    (let
      ;; Bound the spanned pool to a single top-level form (see
      ;; parse-ast-program-forms): the decl carries no sp ids, so truncate back
      ;; before reading the next form.
      [mark : i64 (sp-node-pool-len)]
      (match (read-form-spanned-result toks cur)
        [(OkSpannedSexpr spanned-form)
          (match (parse-ast-decl-maybe dispatch spanned-form)
            [(OkAstSomeDecl decl)
              (begin
                (sp-node-pool-truncate! mark)
                (match (parse-ast-program-forms-diagnostic
                  path
                  dispatch
                  toks
                  cur)
                  [(OkAstDeclListDiagnostic rest)
                    (OkAstDeclListDiagnostic (ast-decl-cons decl rest))]
                  [(ErrAstDeclListDiagnostic diag)
                    (ErrAstDeclListDiagnostic diag)]))]
            [(OkAstDecls decls)
              (begin
                (sp-node-pool-truncate! mark)
                (match (parse-ast-program-forms-diagnostic
                  path
                  dispatch
                  toks
                  cur)
                  [(OkAstDeclListDiagnostic rest)
                    (OkAstDeclListDiagnostic
                      (parse-ast-decl-list-append decls rest))]
                  [(ErrAstDeclListDiagnostic diag)
                    (ErrAstDeclListDiagnostic diag)]))]
            [(OkAstNoDecl)
              (begin
                (sp-node-pool-truncate! mark)
                (parse-ast-program-forms-diagnostic path dispatch toks cur))]
            [(ErrAstMaybeDecl message)
              (ErrAstDeclListDiagnostic
                (parse-ast-canonical-diagnostic
                  (compiler-diagnostic-from-span
                    path
                    (spanned-sexpr-span spanned-form)
                    message)))])]
        [(ErrSpannedSexpr err)
          (ErrAstDeclListDiagnostic
            (parse-ast-canonical-diagnostic
              (compiler-diagnostic-from-source-error path err)))]))))

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
      (sp-node-pool-reset!)
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
      (ErrAstProgramDiagnostic
        (parse-ast-canonical-diagnostic
          (compiler-diagnostic-from-source-error path err)))]))

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

(define (compiler-parse-macro-call-node-ok?
  [call-expr : i64]
  [name : String]
  [want-args : i64]) : bool
  (match (ast-expr-unspan (ast-node-get call-expr))
    [(AstExprCall head args)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        (and
          (= (compiler-parse-expr-list-count args) want-args)
          (match (ast-expr-unspan head-expr)
            [(AstExprVar found) (string-eq (intern-str found) name)]
            [_ false])))]
    [_ false]))

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
    [(AstDeclCons (AstDeclImport (AstImportSpec (AstImportPath) path _ _ _)) _)
      (string-eq path "stdlib/test.tl")]
    [_ false]))

(define (ast-first-include-str-ok? [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclCons (AstDeclIncludeStr name path) _)
      (and (string-eq name "payload") (string-eq path "data.txt"))]
    [_ false]))

(define (ast-first-include-bin-ok? [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclCons (AstDeclIncludeBin name path) _)
      (and (string-eq name "payload") (string-eq path "data.bin"))]
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
                [(AstDeclNil) (= name (intern "std.io"))]
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
                  (AstImportPath)
                  path
                  (AstSomeModuleName module-name)
                  (AstSomeImportAlias alias)
                  _))
              rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq path "stdlib/io.tl")
                    (string-eq module-name "std.io")
                    (string-eq alias "io"))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-dotted-import-explicit-alias-ok?) : bool
  (match (parse-ast-source "(import stdlib.core_macros :as core)")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons
              (AstDeclImport
                (AstImportSpec
                  (AstImportModule)
                  module-path
                  (AstSomeModuleName module-name)
                  (AstSomeImportAlias alias)
                  _))
              rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq module-path "stdlib.core_macros")
                    (string-eq module-name "stdlib.core_macros")
                    (string-eq alias "core"))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-dotted-import-default-alias-ok?) : bool
  (match (parse-ast-source "(import stdlib.core_macros)")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons
              (AstDeclImport
                (AstImportSpec
                  (AstImportModule)
                  module-path
                  (AstSomeModuleName module-name)
                  (AstSomeImportAlias alias)
                  _))
              rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq module-path "stdlib.core_macros")
                    (string-eq module-name "stdlib.core_macros")
                    (string-eq alias "core_macros"))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-dotted-import-metadata-ok?) : bool
  (and
    (compiler-parse-dotted-import-explicit-alias-ok?)
    (compiler-parse-dotted-import-default-alias-ok?)))

(define (compiler-parse-module-macro-call-ok?) : bool
  (match (parse-ast-source "(point-vec i64)")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons
              (AstDeclImport
                (AstImportSpec
                  (AstImportMacroDecls call-expr)
                  path
                  (AstNoModuleName)
                  (AstNoImportAlias)
                  _))
              rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq path "")
                    (compiler-parse-macro-call-node-ok? call-expr "point-vec" 1))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-macro-import-ok?) : bool
  (match (parse-ast-source "(import (vector i64) as svec)")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons
              (AstDeclImport
                (AstImportSpec
                  (AstImportMacro call-expr)
                  path
                  (AstNoModuleName)
                  (AstSomeImportAlias alias)
                  _))
              rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (string-eq path "")
                    (string-eq alias "svec")
                    (compiler-parse-macro-call-node-ok? call-expr "vector" 1))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-module-macro-surface-ok?) : bool
  (and
    (compiler-parse-module-macro-call-ok?)
    (compiler-parse-macro-import-ok?)
    (compiler-parse-error-ok? "(import vector i64)" "parse: malformed import")))

(define (compiler-parse-dotted-import-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(import stdlib..core)"
      "parse: invalid dotted import module name")
    (compiler-parse-error-ok?
      "(import stdlib/core)"
      "parse: invalid dotted import module name")
    (compiler-parse-error-ok?
      "(import pkg:math.core)"
      "parse: invalid dotted import module name")
    (compiler-parse-error-ok?
      "(import stdlib.core_macros module stdlib.core_macros)"
      "parse: malformed import")))

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
    (compiler-parse-error-ok?
      "(include-str \"name\" \"data.txt\")"
      "parse: include-str name must be a symbol")
    (compiler-parse-error-ok?
      "(include-str payload data.txt)"
      "parse: include-str path must be a string")
    (compiler-parse-error-ok?
      "(include-str payload \"data.txt\" extra)"
      "parse: include-str expects exactly two operands")
    (compiler-parse-error-ok?
      "(include-str payload)"
      "parse: include-str expects name and string path")))

(define (compiler-parse-include-bin-ok?) : bool
  (match (parse-ast-source "(include-bin payload \"data.bin\")")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (ast-first-include-bin-ok? decls))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-include-bin-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(include-bin)"
      "parse: include-bin expects name and string path")
    (compiler-parse-error-ok?
      "(include-bin \"name\" \"data.bin\")"
      "parse: include-bin name must be a symbol")
    (compiler-parse-error-ok?
      "(include-bin payload data.bin)"
      "parse: include-bin path must be a string")
    (compiler-parse-error-ok?
      "(include-bin payload \"data.bin\" extra)"
      "parse: include-bin expects exactly two operands")
    (compiler-parse-error-ok?
      "(include-bin payload)"
      "parse: include-bin expects name and string path")))

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
                                            (string-eq type-name "Point")
                                            (string-eq macro-name "and2")
                                            (string-eq ctor-name "Point")
                                            (string-eq field-type "Point")
                                            (string-eq field-name "x")
                                            (string-eq variant-name "Some"))]
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
                          (string-eq avx2-name "dot-avx2")
                          (string-eq avx512-name "dot-avx512"))]
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
                    (= name (intern "dot"))
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
                    (= name (intern "id"))
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
    (compiler-parse-defdispatch-scalar-only-ok?)
    (compiler-parse-error-ok?
      "(defdispatch dot)"
      "parse: defdispatch needs at least one variant")
    (compiler-parse-error-ok?
      "(defdispatch dot (sse2 dot-sse2))"
      "parse: unknown defdispatch ISA sse2")
    (compiler-parse-error-ok?
      "(defdispatch dot (scalar))"
      "parse: malformed defdispatch variant")))

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
          [(AstDeclDefFn name _ _ body-box _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (if (= name (intern "main"))
                (ast-expr-inner-tag body)
                (ast-main-body-tag rest)))]
          [_ (ast-main-body-tag rest)]))]))

(define (compiler-parse-nested-expr-span-ok?) : bool
  (match (parse-ast-source "(define (main) : i64 (+ 1 (* 2 3)))")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box _) _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (match body
                [(AstExprSpanned inner-box body-span)
                  (let
                    [inner : AstExpr (ast-node-get inner-box)]
                    (match inner
                      [(AstExprBinary _ _ right-box)
                        (let
                          [right : AstExpr (ast-node-get right-box)]
                          (match right
                            [(AstExprSpanned right-inner-box right-span)
                              (let
                                [right-inner : AstExpr
                                  (ast-node-get right-inner-box)]
                                (match right-inner
                                  [(AstExprBinary _ _ _)
                                    (and
                                      (=
                                        (ast-source-span-start-line body-span)
                                        1)
                                      (=
                                        (ast-source-span-start-line right-span)
                                        1)
                                      (>
                                        (ast-source-span-start-col right-span)
                                        (ast-source-span-start-col body-span)))]
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

(define (compiler-parse-reader-diagnostic-ok?
  [path : String]
  [src : String]
  [want : String]
  [line : i64]
  [col : i64]) : bool
  (match (parse-ast-source-diagnostic path src)
    [(ErrAstProgramDiagnostic diag)
      (and
        (string-eq (compiler-diagnostic-path diag) path)
        (= (compiler-diagnostic-line diag) line)
        (= (compiler-diagnostic-col diag) col)
        (string-eq (compiler-diagnostic-message diag) want))]
    [(OkAstProgramDiagnostic _) false]))

(define (compiler-parse-reader-delimiter-diagnostics-ok?) : bool
  (and
    (compiler-parse-reader-diagnostic-ok?
      "missing-paren.tl"
      "(define (main) : i64 0"
      "reader: unterminated list: reached end of input before ')'"
      1
      1)
    (compiler-parse-reader-diagnostic-ok?
      "missing-bracket.tl"
      "["
      "reader: unterminated list: reached end of input before ']'"
      1
      1)
    (compiler-parse-reader-diagnostic-ok?
      "wrong-close-list.tl"
      "(define]"
      "reader: mismatched delimiter: expected ')' but found ']' at 1:8"
      1
      1)
    (compiler-parse-reader-diagnostic-ok?
      "wrong-close-bracket.tl"
      "[define)"
      "reader: mismatched delimiter: expected ']' but found ')' at 1:8"
      1
      1)))

(define (compiler-parse-float-literal-ok?) : bool
  (match (parse-ast-source "(define (main) : f64 1.5)")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn name _ (AstTyF64) body-box _) _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (and
                (= name (intern "main"))
                (match (ast-expr-unspan body)
                  [(AstExprLiteral (AstLitFloat text)) (string-eq text "1.5")]
                  [_ false])))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-smoke-source) : String
  "(import \"stdlib/test.tl\")
(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(extern (print-string [arg0 : String]) : unit)
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

(define (compiler-parse-diagnostic-code-ok?) : bool
  (match (parse-ast-source-diagnostic
    "parse-code.tl"
    (compiler-parse-malformed-binary-source))
    [(ErrAstProgramDiagnostic diag)
      (match (compiler-diagnostic-code diag)
        [(CompilerDiagnosticSomeString code)
          (and
            (string-eq code (compiler-diagnostic-code-parse))
            (match (compiler-diagnostic-category diag)
              [(CompilerDiagnosticSomeString category)
                (string-eq category "parse")]
              [CompilerDiagnosticNoString false]))]
        [CompilerDiagnosticNoString false])]
    [(OkAstProgramDiagnostic _) false]))

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

(define (compiler-parse-bracket-cond-source) : String
  "(define (main) : i64 (cond [(= 1 1) 1] [else 0]))")

(define (compiler-parse-qualified-bracket-cond-source) : String
  "(define (main) : i64 (core.cond [(= 1 1) 1] [else 0]))")

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
          [(AstDeclCons (AstDeclDefFn name _ (AstTyI64) body-box _) _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (and
                (= name (intern "main"))
                (match (ast-expr-unspan body)
                  [(AstExprWithRegion region _) (string-eq region "r")]
                  [_ false])))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-raw-pointer-source) : String
  "(extern (raw-map [arg0 : (Ptr i64)]) : (MutPtr (Ptr u8)))")

(define (compiler-parse-type-ptr-u8? [ty : AstType]) : bool
  (match ty
    [(AstTyPtr elem)
      (match (ty-node-get elem)
        [(AstTyU8) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-ptr-i64? [ty : AstType]) : bool
  (match ty
    [(AstTyPtr elem)
      (match (ty-node-get elem)
        [(AstTyI64) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-mut-ptr-u8? [ty : AstType]) : bool
  (match ty
    [(AstTyMutPtr elem)
      (match (ty-node-get elem)
        [(AstTyU8) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-mut-ptr-ptr-u8? [ty : AstType]) : bool
  (match ty
    [(AstTyMutPtr elem) (compiler-parse-type-ptr-u8? (ty-node-get elem))]
    [_ false]))

(define (compiler-parse-type-ref-string? [ty : AstType] [region : String]) : bool
  (match ty
    [(AstTyRef actual inner)
      (and
        (string-eq actual region)
        (match (ty-node-get inner)
          [(AstTyString) true]
          [_ false]))]
    [_ false]))

(define (compiler-parse-type-ref-str? [ty : AstType] [region : String]) : bool
  (match ty
    [(AstTyRef actual inner)
      (and
        (string-eq actual region)
        (match (ty-node-get inner)
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
        (match (ty-node-get inner)
          [(AstTyDynArray elem)
            (match (ty-node-get elem)
              [(AstTyI64) true]
              [_ false])]
          [_ false]))]
    [_ false]))

(define (compiler-parse-extern-metadata-source) : String
  "(extern (local-call [arg0 : i64]) : i64 (:abi c) (:symbol \"foreign_exact\") (:link-lib \"m\") (:link-search \"native/lib\") (:link-arg \"-Wl,--as-needed\"))")

(define (compiler-parse-extern-varargs-metadata-source) : String
  "(extern (snprintf [arg0 : (MutPtr u8)] [arg1 : i64] [arg2 : (Ptr u8)] [arg3 : f64]) : i32 (:abi c-varargs 3) (:symbol \"snprintf\"))")

(define (compiler-parse-extern-function-head-varargs-source) : String
  "(extern (snprintf [buf : (MutPtr u8)] [len : i64] [fmt : (Ptr u8)] [arg : ...f64]) : i32 (:symbol \"snprintf\"))
(extern (printf [fmt : (Ptr u8)] ...) : i32 (:symbol \"printf\"))
(extern (local-add [a : i64] [b : i64]) : i64 (:symbol \"foreign_add_exact\"))")

(define (compiler-parse-define-export-symbol-source) : String
  "(define (_write [fd : i32] [buf : (Ptr u8)] [n : i32]) (:export-symbol \"_write\") : i32
  0)")

(define (compiler-parse-param-list-count [params : AstParamList]) : i64
  (match params
    [(AstParamNil) 0]
    [(AstParamCons _ rest)
      (+ 1 (compiler-parse-param-list-count (box-get rest)))]))

(define (compiler-parse-type-list-count [types : AstTypeList]) : i64
  (match types
    [(AstTypeNil) 0]
    [(AstTypeCons _ rest) (+ 1 (compiler-parse-type-list-count (box-get rest)))]))

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
          [(AstDeclCons (AstDeclExtern name _ _ ty) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (= name (intern "raw-map"))
                    (match ty
                      [(AstTyFunc args ret)
                        (match args
                          [(AstTypeCons first tail)
                            (let
                              [first : AstType (ty-node-get first)]
                              [tail : AstTypeList (box-get tail)]
                              (and
                                (compiler-parse-type-ptr-i64? first)
                                (match tail
                                  [(AstTypeNil)
                                    (compiler-parse-type-mut-ptr-ptr-u8?
                                      (ty-node-get ret))]
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
                          (string-eq dir "native/lib")
                          (string-eq arg-value "-Wl,--as-needed"))]
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
          [(AstDeclCons (AstDeclExtern name _ metadata ty) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (= name (intern "local-call"))
                    (string-eq
                      (ast-extern-metadata-symbol metadata)
                      "foreign_exact")
                    (ast-extern-abi-c? (ast-extern-metadata-abi metadata))
                    (compiler-parse-extern-link-inputs-ok?
                      (ast-extern-metadata-link-inputs metadata))
                    (match ty
                      [(AstTyFunc args ret)
                        (match args
                          [(AstTypeCons first tail)
                            (let
                              [first : AstType (ty-node-get first)]
                              [tail : AstTypeList (box-get tail)]
                              (and
                                (match first
                                  [(AstTyI64) true]
                                  [_ false])
                                (match tail
                                  [(AstTypeNil)
                                    (match (ty-node-get ret)
                                      [(AstTyI64) true]
                                      [_ false])]
                                  [_ false])))]
                          [_ false])]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-extern-varargs-metadata-rejected-ok?) : bool
  (compiler-parse-error-ok?
    (compiler-parse-extern-varargs-metadata-source)
    (parse-ast-extern-c-varargs-legacy-message)))

(define (compiler-parse-extern-head-typed-varargs-decl-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclExtern name _ metadata ty)
      (and
        (= name (intern "snprintf"))
        (match (ast-extern-metadata-abi metadata)
          [(AstExternAbiCVarargsTyped tail-ty)
            (match tail-ty
              [(AstTyF64) true]
              [_ false])]
          [_ false])
        (match ty
          [(AstTyFunc args ret)
            (and
              (= (compiler-parse-type-list-count args) 3)
              (match (ty-node-get ret)
                [(AstTyI32) true]
                [_ false])
              (match args
                [(AstTypeCons first rest0)
                  (let
                    [first : AstType (ty-node-get first)]
                    [rest0 : AstTypeList (box-get rest0)]
                    (and
                      (compiler-parse-type-mut-ptr-u8? first)
                      (match rest0
                        [(AstTypeCons second rest1)
                          (let
                            [second : AstType (ty-node-get second)]
                            [rest1 : AstTypeList (box-get rest1)]
                            (and
                              (match second
                                [(AstTyI64) true]
                                [_ false])
                              (match rest1
                                [(AstTypeCons third rest2)
                                  (let
                                    [third : AstType (ty-node-get third)]
                                    [rest2 : AstTypeList (box-get rest2)]
                                    (and
                                      (compiler-parse-type-ptr-u8? third)
                                      (match rest2
                                        [(AstTypeNil) true]
                                        [_ false])))]
                                [_ false])))]
                        [_ false])))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-extern-head-open-varargs-decl-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclExtern name _ metadata ty)
      (and
        (= name (intern "printf"))
        (match (ast-extern-metadata-abi metadata)
          [(AstExternAbiCVarargsOpen) true]
          [_ false])
        (match ty
          [(AstTyFunc args ret)
            (and
              (= (compiler-parse-type-list-count args) 1)
              (match (ty-node-get ret)
                [(AstTyI32) true]
                [_ false])
              (match args
                [(AstTypeCons first rest)
                  (let
                    [first : AstType (ty-node-get first)]
                    [rest : AstTypeList (box-get rest)]
                    (and
                      (compiler-parse-type-ptr-u8? first)
                      (match rest
                        [(AstTypeNil) true]
                        [_ false])))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-i64-type? [ty : AstType]) : bool
  (match ty
    [(AstTyI64) true]
    [_ false]))

(define (compiler-parse-two-i64-types? [args : AstTypeList]) : bool
  (match args
    [(AstTypeCons first rest0)
      (let
        [first : AstType (ty-node-get first)]
        [rest0 : AstTypeList (box-get rest0)]
        (and
          (compiler-parse-i64-type? first)
          (match rest0
            [(AstTypeCons second rest1)
              (let
                [second : AstType (ty-node-get second)]
                [rest1 : AstTypeList (box-get rest1)]
                (and
                  (compiler-parse-i64-type? second)
                  (match rest1
                    [(AstTypeNil) true]
                    [_ false])))]
            [_ false])))]
    [_ false]))

(define (compiler-parse-extern-head-fixed-decl-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclExtern name _ metadata ty)
      (and
        (= name (intern "local-add"))
        (string-eq (ast-extern-metadata-symbol metadata) "foreign_add_exact")
        (match ty
          [(AstTyFunc args ret)
            (and
              (= (compiler-parse-type-list-count args) 2)
              (compiler-parse-i64-type? (ty-node-get ret))
              (compiler-parse-two-i64-types? args))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-extern-function-head-varargs-ok?) : bool
  (match (parse-ast-source (compiler-parse-extern-function-head-varargs-source))
    [(OkAstProgram (AstProgram decls-box))
      (match (box-get decls-box)
        [(AstDeclCons first rest0)
          (let
            [rest0 : AstDeclList (box-get rest0)]
            (match rest0
              [(AstDeclCons second rest1)
                (let
                  [rest1 : AstDeclList (box-get rest1)]
                  (match rest1
                    [(AstDeclCons third rest2)
                      (let
                        [rest2 : AstDeclList (box-get rest2)]
                        (match rest2
                          [(AstDeclNil)
                            (and
                              (compiler-parse-extern-head-typed-varargs-decl-ok?
                                first)
                              (compiler-parse-extern-head-open-varargs-decl-ok?
                                second)
                              (compiler-parse-extern-head-fixed-decl-ok? third))]
                          [_ false]))]
                    [_ false]))]
              [_ false]))]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-define-export-symbol-ok?) : bool
  (match (parse-ast-source (compiler-parse-define-export-symbol-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn name params ret _ export) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (= name (intern "_write"))
                    (= (compiler-parse-param-list-count params) 3)
                    (match ret
                      [(AstTyI32) true]
                      [_ false])
                    (match export
                      [(AstFnExport symbol) (= symbol (intern "_write"))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-raw-pointer-ops-ok?) : bool
  (compiler-parse-ok? (compiler-parse-raw-pointer-ops-source)))

(define (compiler-parse-init-ok?) : bool
  (match (parse-ast-source "(define (main) : i64 (init : i64))")
    [(OkAstProgram (AstProgram decls-box))
      (match (box-get decls-box)
        [(AstDeclCons (AstDeclDefFn _ _ _ body-box _) AstDeclNil)
          (match (ast-expr-unspan (ast-node-get body-box))
            [(AstExprInit ty)
              (match ty
                [(AstSomeType inner)
                  (match inner
                    [(AstTyI64) true]
                    [_ false])]
                [_ false])]
            [_ false])]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-contextual-init-ok?) : bool
  (match (parse-ast-source
    "(define (init) : i64 7) (define (main) : i64 (init))")
    [(OkAstProgram (AstProgram decls-box))
      (match (box-get decls-box)
        [(AstDeclCons _ rest)
          (match (box-get rest)
            [(AstDeclCons (AstDeclDefFn _ _ _ body-box _) AstDeclNil)
              (match (ast-expr-unspan (ast-node-get body-box))
                [(AstExprInit ty)
                  (match ty
                    [(AstNoType) true]
                    [_ false])]
                [_ false])]
            [_ false])]
        [_ false])]
    [(ErrAstProgram _) false]))

(define (compiler-parse-init-call-name-source) : String
  "(define (init [n : i64]) : i64 n)
(define (main) : i64 (init 7))")

(define (compiler-parse-init-call-name-ok?) : bool
  (compiler-parse-ok? (compiler-parse-init-call-name-source)))

(define (compiler-parse-box-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : (Box i64) (box 7))")
    (compiler-parse-ok? "(define (main [b : (Box i64)]) : i64 (box-get b))")
    (compiler-parse-ok?
      "(define (main) : i64 (with-arena r (let ([b : (in r (Box i64)) (box 7)]) (box-get b))))")))

(define (compiler-parse-reference-source) : String
  "(define (use [s : (& r String)] [view : (& r str)] [items : (&mut phase (Array i64))]) : unit unit)")

(define (compiler-parse-reference-ok?) : bool
  (match (parse-ast-source (compiler-parse-reference-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ params _ _ _) rest)
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
    (&mut x)
    x))")

(define (compiler-parse-borrow-inferred-var? [expr : AstExpr] [name : String]) : bool
  (match (ast-expr-unspan expr)
    [(AstExprBorrow false AstBorrowLifetimeInferred place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (match (ast-expr-unspan place)
          [(AstExprVar place-name) (string-eq (intern-str place-name) name)]
          [_ false]))]
    [_ false]))

(define (compiler-parse-mut-borrow-inferred-var?
  [expr : AstExpr]
  [name : String]) : bool
  (match (ast-expr-unspan expr)
    [(AstExprBorrow true AstBorrowLifetimeInferred place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (match (ast-expr-unspan place)
          [(AstExprVar place-name) (string-eq (intern-str place-name) name)]
          [_ false]))]
    [_ false]))

(define (compiler-parse-borrow-named-var?
  [expr : AstExpr]
  [lifetime : String]
  [name : String]) : bool
  (match (ast-expr-unspan expr)
    [(AstExprBorrow false (AstBorrowLifetimeNamed actual-lifetime) place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (match (ast-expr-unspan place)
          [(AstExprVar place-name)
            (and
              (string-eq actual-lifetime lifetime)
              (string-eq (intern-str place-name) name))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-borrow-ok?) : bool
  (match (parse-ast-source (compiler-parse-borrow-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match (ast-expr-unspan body)
                    [(AstExprBegin exprs)
                      (match exprs
                        [(AstExprCons first rest0)
                          (let
                            [first : AstExpr (ast-node-get first)]
                            [rest0 : AstExprList (box-get rest0)]
                            (match rest0
                              [(AstExprCons second rest1)
                                (let
                                  [second : AstExpr (ast-node-get second)]
                                  (match (ast-expr-unspan first)
                                    [(AstExprBorrow
                                        _
                                        AstBorrowLifetimeInferred
                                        first-place-box)
                                      (let
                                        [first-place : AstExpr
                                          (ast-node-get first-place-box)]
                                        (match (ast-expr-unspan first-place)
                                          [(AstExprVar first-name)
                                            (if (string-eq
                                              (intern-str first-name)
                                              "x")
                                              (match (ast-expr-unspan second)
                                                [(AstExprBorrow
                                                    _
                                                    (AstBorrowLifetimeNamed
                                                      lifetime)
                                                    second-place-box)
                                                  (let
                                                    [second-place : AstExpr
                                                      (ast-node-get
                                                        second-place-box)]
                                                    (match (ast-expr-unspan
                                                      second-place)
                                                      [(AstExprVar second-name)
                                                        (and
                                                          (string-eq
                                                            lifetime
                                                            "x")
                                                          (string-eq
                                                            (intern-str
                                                              second-name)
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
                      [(AstDeclCons (AstDeclDefFn _ _ _ body-box _) rest2)
                        (let
                          [body : AstExpr (ast-node-get body-box)]
                          [rest2 : AstDeclList (box-get rest2)]
                          (match rest2
                            [(AstDeclNil)
                              (match (ast-expr-unspan body)
                                [(AstExprCall _ args)
                                  (match args
                                    [(AstExprCons arg rest)
                                      (let
                                        [arg : AstExpr (ast-node-get arg)]
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
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match (ast-expr-unspan body)
                    [(AstExprReturn inner-box)
                      (let
                        [inner : AstExpr (ast-node-get inner-box)]
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
            [first : AstExpr (ast-node-get first)]
            [rest0 : AstExprList (box-get rest0)]
            (match rest0
              [(AstExprCons last rest1)
                (let
                  [last : AstExpr (ast-node-get last)]
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
    [(AstExprVar found) (string-eq (intern-str found) name)]
    [_ false]))

(define (compiler-parse-return-expr? [expr : AstExpr]) : bool
  (match (ast-expr-unspan expr)
    [(AstExprReturn _) true]
    [_ false]))

(define (compiler-parse-guard-call-args-ok? [args : AstExprList]) : bool
  (match args
    [(AstExprCons cond rest0)
      (let
        [cond : AstExpr (ast-node-get cond)]
        [rest0 : AstExprList (box-get rest0)]
        (and
          (compiler-parse-call-head-name? cond "ok")
          (match rest0
            [(AstExprCons body-arg rest1)
              (let
                [body-arg : AstExpr (ast-node-get body-arg)]
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
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match (ast-expr-unspan body)
                    [(AstExprCall func-box args)
                      (let
                        [func : AstExpr (ast-node-get func-box)]
                        (and
                          (compiler-parse-call-head-name? func name)
                          (= (compiler-parse-call-arg-count args) want-args)
                          (if check-guard-args
                            (compiler-parse-guard-call-args-ok? args)
                            true)))]
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

(define (compiler-parse-bracket-cond-call-ok?) : bool
  (and
    (compiler-parse-call-body-ok?
      (compiler-parse-bracket-cond-source)
      "cond"
      2
      false)
    (compiler-parse-call-body-ok?
      (compiler-parse-qualified-bracket-cond-source)
      "core.cond"
      2
      false)))

(define (compiler-parse-and-or-macro-call-candidates-ok?) : bool
  (and
    (compiler-parse-call-body-ok? "(define (main) : bool (and))" "and" 0 false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool]) : bool (and x))"
      "and"
      1
      false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool] [y : bool]) : bool (and x y))"
      "and"
      2
      false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool] [y : bool] [z : bool]) : bool (and x y z))"
      "and"
      3
      false)
    (compiler-parse-call-body-ok? "(define (main) : bool (or))" "or" 0 false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool]) : bool (or x))"
      "or"
      1
      false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool] [y : bool]) : bool (or x y))"
      "or"
      2
      false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool] [y : bool] [z : bool]) : bool (or x y z))"
      "or"
      3
      false)))

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
        (string-eq item-name want-item)
        (= (compiler-parse-expr-list-count arg-keys) want-arg-count))]
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
                (= name (intern "Point"))
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
            [(AstDeclDefEnum name _ _) (= name (intern "Maybe"))]
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
                [value : AstExpr (ast-node-get value-box)]
                (and
                  (= name (intern "option-size"))
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
            [(AstDeclDefFn name _ (AstTyI64) _ _)
              (= name (intern "make-option"))]
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
                                      (= (ast-decl-list-tag-sum decls) 32)
                                      (compiler-parse-comptime-defstruct-ok?
                                        first)
                                      (compiler-parse-comptime-defenum-ok?
                                        second)
                                      (compiler-parse-comptime-define-value-ok?
                                        third)
                                      (compiler-parse-comptime-define-fn-ok?
                                        fourth))]
                                  [_ false]))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-comptime-decls-source) : String
  "(comptime-decls (:generated bundle-family (type-key (type String)) \"v1\")
  (defstruct BundleBox (value String))
  (defenum BundleChoice (BundleNone) (BundleSome String))
  (define (bundle-score [value : BundleChoice]) : i64 1))")

(define (compiler-parse-comptime-decls-struct-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclComptimeDecl meta template-box)
      (and
        (compiler-parse-generated-meta-ok? meta "bundle-family" "BundleBox" 2)
        (match (box-get template-box)
          [(AstDeclDefStruct name _ _ fields)
            (and
              (= name (intern "BundleBox"))
              (= (compiler-parse-field-count fields) 1))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-comptime-decls-enum-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclComptimeDecl meta template-box)
      (and
        (compiler-parse-generated-meta-ok?
          meta
          "bundle-family"
          "BundleChoice"
          2)
        (match (box-get template-box)
          [(AstDeclDefEnum name _ _) (= name (intern "BundleChoice"))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-comptime-decls-fn-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclComptimeDecl meta template-box)
      (and
        (compiler-parse-generated-meta-ok?
          meta
          "bundle-family"
          "bundle-score"
          2)
        (match (box-get template-box)
          [(AstDeclDefFn name _ (AstTyI64) _ _)
            (= name (intern "bundle-score"))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-comptime-decls-ok?) : bool
  (match (parse-ast-source (compiler-parse-comptime-decls-source))
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
                            [(AstDeclNil)
                              (and
                                (= (ast-decl-list-count decls) 3)
                                (compiler-parse-comptime-decls-struct-ok? first)
                                (compiler-parse-comptime-decls-enum-ok? second)
                                (compiler-parse-comptime-decls-fn-ok? third))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-unsafe-decl-source) : String
  "(unsafe (define (danger [x : i64]) : i64 x))
(unsafe (extern (raw-call [arg0 : i64]) : i64))")

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
                      [(AstDeclDefFn name _ (AstTyI64) _ _)
                        (match tail
                          [(AstDeclCons second AstDeclNil)
                            (match second
                              [(AstDeclUnsafe second-inner-box)
                                (let
                                  [second-inner : AstDecl
                                    (box-get second-inner-box)]
                                  (match second-inner
                                    [(AstDeclExtern extern-name _ _ extern-ty)
                                      (and
                                        (= name (intern "danger"))
                                        (= extern-name (intern "raw-call"))
                                        (match extern-ty
                                          [(AstTyFunc _ ret)
                                            (match (ty-node-get ret)
                                              [(AstTyI64) true]
                                              [_ false])]
                                          [_ false]))]
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

(define (compiler-parse-variant-payload-cleanup-score
  [cleanup : AstVariantPayloadCleanup]) : i64
  (match cleanup
    [(AstVariantPayloadNoCleanup) 0]
    [(AstVariantPayloadCleanupFn _) 10]
    [(AstVariantPayloadOwnedCleanup) 100]))

(define (compiler-parse-variant-payload-cleanup-list-score
  [cleanups : AstVariantPayloadCleanupList]) : i64
  (match cleanups
    [(AstVariantPayloadCleanupNil) 0]
    [(AstVariantPayloadCleanupCons cleanup rest)
      (let
        [rest : AstVariantPayloadCleanupList (box-get rest)]
        (+
          (compiler-parse-variant-payload-cleanup-score cleanup)
          (compiler-parse-variant-payload-cleanup-list-score rest)))]))

(define (compiler-parse-variant-list-cleanup-score
  [variants : AstVariantDefList]) : i64
  (match variants
    [(AstVariantDefNil) 0]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef _ _ cleanups)
            (+
              (compiler-parse-variant-payload-cleanup-list-score cleanups)
              (compiler-parse-variant-list-cleanup-score rest))]))]))

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
                    (= name (intern "Resource"))
                    (match repr
                      [(AstStructReprDefault) true]
                      [_ false])
                    (match cleanup
                      [(AstStructCleanupFn cleanup-name)
                        (= cleanup-name (intern "close-resource"))]
                      [_ false])
                    (= (compiler-parse-field-count fields) 3)
                    (= (compiler-parse-field-cleanup-list-score fields) 110))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-enum-cleanup-source) : String
  "(defenum Resource
  (:cleanup close-resource)
  (File i64 (:cleanup close-fd) Child (:owned) i64))")

(define (compiler-parse-enum-cleanup-ok?) : bool
  (match (parse-ast-source (compiler-parse-enum-cleanup-source))
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefEnum name cleanup variants) rest)
            (let
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (= name (intern "Resource"))
                    (match cleanup
                      [(AstEnumCleanupFn cleanup-name)
                        (= cleanup-name (intern "close-resource"))]
                      [_ false])
                    (= (compiler-parse-variant-list-cleanup-score variants) 110))]
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
                        (ast-struct-cleanup? cleanup)
                        (= (compiler-parse-field-cleanup-list-score fields) 10))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-cleanup-metadata-ok?) : bool
  (and
    (compiler-parse-struct-cleanup-ok?)
    (compiler-parse-enum-cleanup-ok?)
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
                    (= name (intern "Stat"))
                    (ast-struct-repr-c? repr)
                    (= (compiler-parse-field-count fields) 2))]
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
              [body : AstExpr (ast-node-get body-box)]
              [tail : AstDeclList (box-get tail)]
              (match tail
                [(AstDeclNil)
                  (and
                    (= name (intern "parser-basic"))
                    (= (ast-source-span-start-line span) 1)
                    (match (ast-expr-unspan body)
                      [(AstExprBegin exprs)
                        (= (compiler-parse-expr-list-count exprs) 2)]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-comptime-decl-bad-payload-source) : String
  "(comptime-decl (extern (x) : i64))")

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

(define (compiler-parse-comptime-decls-expression-source) : String
  "(define (main) : i64
  (comptime-decls (:generated bundle-family \"v1\") (defstruct Point (x i64))))")

(define (compiler-parse-comptime-decls-empty-source) : String
  "(comptime-decls (:generated bundle-family \"v1\"))")

(define (compiler-parse-comptime-decls-bad-metadata-source) : String
  "(comptime-decls (:bad bundle-family \"v1\") (defstruct Point (x i64)))")

(define (compiler-parse-comptime-decls-malformed-metadata-source) : String
  "(comptime-decls (:generated) (defstruct Point (x i64)))")

(define (compiler-parse-comptime-decls-bad-payload-source) : String
  "(comptime-decls (:generated bundle-family \"v1\") (extern (x) : i64))")

(define (compiler-parse-comptime-decl-invalid-payload-ok? [src : String]) : bool
  (compiler-parse-error-ok? src (parse-ast-comptime-decl-payload-message)))

(define (compiler-parse-comptime-decl-invalid-payloads-ok?) : bool
  (and
    (compiler-parse-comptime-decl-invalid-payload-ok?
      (compiler-parse-comptime-decl-bad-payload-source))
    (compiler-parse-comptime-decl-invalid-payload-ok?
      "(comptime-decl (defmacro (m [x : bool]) : bool x))")
    (compiler-parse-comptime-decl-invalid-payload-ok?
      "(comptime-decl (module nested))")
    (compiler-parse-comptime-decl-invalid-payload-ok?
      "(comptime-decl (import \"x.tl\"))")
    (compiler-parse-comptime-decl-invalid-payload-ok?
      "(comptime-decl (export (value x)))")
    (compiler-parse-comptime-decl-invalid-payload-ok?
      "(comptime-decl (cfg feature (define x : i64 1)))")
    (compiler-parse-comptime-decl-invalid-payload-ok?
      "(comptime-decl (test t 1))")
    (compiler-parse-comptime-decl-invalid-payload-ok?
      "(comptime-decl (comptime-decl (defstruct X (x i64))))")))

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
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr rust) (x i64))"
      "parse: unknown struct repr rust")
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr packed) (x i64))"
      "parse: packed repr is reserved")
    (compiler-parse-error-ok?
      "(defstruct Bad (x i64) (:repr c))"
      "parse: defstruct metadata must appear before fields")
    (compiler-parse-error-ok?
      "(defstruct Bad (:layout c) (x i64))"
      "parse: unknown defstruct metadata :layout")
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr c))"
      "parse: defstruct needs at least one field")))

(define (compiler-parse-cleanup-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close) (:cleanup close2) (x i64))"
      "parse: duplicate defstruct :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (x i64 (:cleanup close-x)))"
      "parse: field cleanup metadata requires struct :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr c) (:cleanup close) (x i64))"
      "parse: defstruct cannot combine :repr c with :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close) (:repr c) (x i64))"
      "parse: defstruct cannot combine :repr c with :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup) (x i64))"
      "parse: malformed defstruct :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close) (x i64 (:cleanup)))"
      "parse: malformed field :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close) (x i64 (:cleanup close-x) (:owned)))"
      "parse: duplicate field cleanup metadata")
    (compiler-parse-error-ok?
      "(defenum Bad (:cleanup close) (:cleanup close2) (A))"
      "parse: duplicate defenum :cleanup metadata")
    (compiler-parse-error-ok?
      "(defenum Bad (:cleanup) (A))"
      "parse: malformed defenum :cleanup metadata")
    (compiler-parse-error-ok?
      "(defenum Bad (A) (:cleanup close))"
      "parse: defenum metadata must appear before variants")
    (compiler-parse-error-ok?
      "(defenum Bad (A i64 (:cleanup close)))"
      "parse: enum payload cleanup metadata requires enum :cleanup metadata")))

(define (compiler-parse-comptime-decl-error-tests-ok?) : bool
  (and
    (compiler-parse-comptime-decl-invalid-payloads-ok?)
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decl-expression-source)
      "parse: comptime-decl is only valid as a top-level declaration")
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decl-extra-source)
      "parse: comptime-decl expects one template or generated metadata plus one template")
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decl-bad-metadata-source)
      "parse: comptime-decl metadata must be :generated")
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decl-malformed-metadata-source)
      "parse: :generated metadata expects generator name, item name, and argument key expressions")))

(define (compiler-parse-comptime-decls-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decls-expression-source)
      "parse: comptime-decls is only valid as a top-level declaration")
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decls-empty-source)
      "parse: comptime-decls expects generated metadata plus one or more templates")
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decls-bad-metadata-source)
      "parse: comptime-decls metadata must be :generated")
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decls-malformed-metadata-source)
      "parse: :generated metadata expects generator name and argument key expressions")
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decls-bad-payload-source)
      (parse-ast-comptime-decl-payload-message))))

(define (compiler-parse-unsafe-decl-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(unsafe)"
      "parse: unsafe declaration expects exactly one declaration")
    (compiler-parse-error-ok?
      "(unsafe (define value : i64 1))"
      "parse: unsafe declaration accepts only function define or extern")
    (compiler-parse-error-ok?
      "(unsafe (defstruct Bad (x i64)))"
      "parse: unsafe declaration accepts only function define or extern")
    (compiler-parse-error-ok?
      "(unsafe (extern (a) : i64) (extern (b) : i64))"
      "parse: unsafe declaration expects exactly one declaration")))

(define (compiler-parse-export-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      (compiler-parse-empty-export-source)
      "parse: export needs at least one item")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-export-item-source)
      "parse: malformed export item")
    (compiler-parse-error-ok?
      (compiler-parse-unknown-export-kind-source)
      "parse: unknown export item kind")))

(define (compiler-parse-define-export-metadata-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (f) (:export-symbol \"\") : i64 0)"
      "parse: define :export-symbol must not be empty")
    (compiler-parse-error-ok?
      "(define (f) (:export-symbol bad) : i64 0)"
      "parse: malformed define :export-symbol metadata")
    (compiler-parse-error-ok?
      "(define (f) (:export-symbol \"a\") (:export-symbol \"b\") : i64 0)"
      "parse: duplicate define :export-symbol metadata")
    (compiler-parse-error-ok?
      "(define (f) (:link-lib \"m\") : i64 0)"
      "parse: unknown define metadata :link-lib")
    (compiler-parse-error-ok?
      "(define (f [comptime n : i64]) (:export-symbol \"f\") : i64 n)"
      "parse: define :export-symbol cannot be used on functions with comptime parameters")))

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
    (compiler-parse-error-ok?
      "(define (main) : i64 (let [x : i64] x))"
      "parse: malformed let binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let [x : i64 1]))"
      "parse: let missing body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let [x : i64 1] x x))"
      "parse: let expects exactly one body")))

(define (compiler-parse-abstraction-policy-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      (compiler-parse-defgeneric-policy-source)
      (compiler-parse-abstraction-policy-message))
    (compiler-parse-error-ok?
      (compiler-parse-trait-policy-source)
      (compiler-parse-abstraction-policy-message))
    (compiler-parse-error-ok?
      (compiler-parse-generic-type-policy-source)
      (compiler-parse-generic-type-policy-message "Option"))))

(define (compiler-parse-raw-pointer-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (main [p : (Ptr)]) : unit unit)"
      "parse: Ptr expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main [p : (MutPtr i64 i64)]) : unit unit)"
      "parse: MutPtr expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main [p : (Ptr (Array))]) : unit unit)"
      "parse: malformed array type")
    (compiler-parse-error-ok?
      "(define (main [p : (Ptr i64)]) : i64 (ptr-read))"
      "parse: ptr-read expects exactly one expression")
    (compiler-parse-error-ok?
      "(define (main [p : (MutPtr i64)]) : unit (ptr-write! p))"
      "parse: ptr-write! expects exactly two expressions")
    (compiler-parse-error-ok?
      "(define (main) : (MutPtr i64) (unsafe (ptr-addr-of)))"
      "parse: ptr-addr-of expects exactly one local name")
    (compiler-parse-error-ok?
      "(define (main [x : i64]) : (MutPtr i64) (unsafe (ptr-addr-of (+ x 1))))"
      "parse: ptr-addr-of expects a local name")
    (compiler-parse-error-ok?
      "(define (main [p : (Ptr i64)]) : (Ptr u8) (ptr-cast p (Ptr u8)))"
      "parse: pointer cast expects (form expr : pointer-type)")))

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
        "(extern (f) : i64 (:abi stdcall))"
        "parse: unknown extern ABI stdcall")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:symbol bad))"
        "parse: malformed extern :symbol metadata")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:link-lib bad))"
        "parse: malformed extern :link-lib metadata")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:link-arg \"\"))"
        "parse: extern :link-arg must not be empty")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:abi c) (:abi c))"
        "parse: duplicate extern :abi metadata")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:abi c-varargs))"
        (parse-ast-extern-c-varargs-legacy-message))
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:abi c-varargs -1))"
        (parse-ast-extern-c-varargs-legacy-message))
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f ... [x : i64]) : i64)"
        "parse: extern varargs tail must be final")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f [x : i64] ...) (:abi c-varargs 1) : i64)"
        (parse-ast-extern-c-varargs-legacy-message))
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:link \"x\"))"
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
      ok)))

(define (compiler-parse-special-form-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      (compiler-parse-malformed-binary-source)
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-if-source)
      "parse: malformed if")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-while-source)
      "parse: malformed while")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-set-source)
      "parse: malformed set!")
    (compiler-parse-error-ok?
      (compiler-parse-with-region-empty-source)
      "parse: with-arena 'r' requires a non-empty body")
    (compiler-parse-error-ok?
      (compiler-parse-region-type-bad-source)
      "parse: region name must be an identifier")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-try-source)
      "parse: try expects exactly one expression")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-return-source)
      "parse: return expects exactly one expression")))

(define (compiler-parse-error-tests-ok?) : bool
  (cond
    [(not (compiler-parse-diagnostic-code-ok?)) false]
    [(not (compiler-parse-special-form-error-tests-ok?)) false]
    [(not (compiler-parse-comptime-decl-error-tests-ok?)) false]
    [(not (compiler-parse-comptime-decls-error-tests-ok?)) false]
    [(not (compiler-parse-unsafe-decl-error-tests-ok?)) false]
    [(not (compiler-parse-repr-c-error-tests-ok?)) false]
    [(not (compiler-parse-cleanup-error-tests-ok?)) false]
    [(not
        (compiler-parse-error-ok?
          (compiler-parse-malformed-module-source)
          "parse: malformed module"))
      false]
    [(not
        (compiler-parse-error-ok?
          (compiler-parse-malformed-import-source)
          "parse: malformed import"))
      false]
    [(not
        (compiler-parse-error-ok?
          (compiler-parse-empty-test-source)
          "parse: test needs at least one expression"))
      false]
    [(not (compiler-parse-let-error-tests-ok?)) false]
    [(not (compiler-parse-abstraction-policy-tests-ok?)) false]
    [(not (compiler-parse-raw-pointer-error-tests-ok?)) false]
    [(not (compiler-parse-extern-metadata-error-tests-ok?)) false]
    [(not (compiler-parse-box-error-tests-ok?)) false]
    [(not (compiler-parse-reference-error-tests-ok?)) false]
    [else true]))

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
      (compiler-parse-cfg-decl-count-ok?
        "(cfg feature (define answer : i64 42))"
        feature-cfg
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg feature (define))"
        (compiler-cfg-empty)
        0)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg (all feature windows) (define answer : i64 42))"
        windows-feature-cfg
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg (any missing feature) (define answer : i64 42))"
        feature-cfg
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg (not missing) (define answer : i64 42))"
        feature-cfg
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(define (main) : i64 (begin (cfg feature (if)) 42))"
        (compiler-cfg-empty)
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(define (main) : i64 (cfg feature (if) 42))"
        (compiler-cfg-empty)
        1)
      (compiler-parse-cfg-error?
        "(define (main) : i64 (cfg feature (if) 42))"
        feature-cfg))))

(define (compiler-parse-declaration-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define answer : i64 42)")
    (compiler-parse-ok? "(define (add [a : i64] [b : i64]) : i64 (+ a b))")
    (compiler-parse-ok? "(extern (puts [arg0 : String]) : unit)")
    (compiler-parse-ok? "(defenum Maybe (Some i64) (None))")
    (compiler-parse-ok? "(defstruct Point (x i64) (y i64))")
    (compiler-parse-ok? "(import \"stdlib/io.tl\")")
    (compiler-parse-include-str-ok?)
    (compiler-parse-include-str-errors-ok?)
    (compiler-parse-include-bin-ok?)
    (compiler-parse-include-bin-errors-ok?)
    (compiler-parse-error-ok?
      "(define answer : i64)"
      "parse: malformed value definition")
    (compiler-parse-error-ok?
      "(define (main) : i64)"
      "parse: malformed function definition")
    (compiler-parse-error-ok? "(extern puts)" "parse: malformed extern")
    (compiler-parse-error-ok? "(defenum)" "parse: malformed defenum")
    (compiler-parse-error-ok? "(defstruct)" "parse: malformed defstruct")
    (compiler-parse-error-ok? "(import)" "parse: malformed import")))

;; enum/struct expression coverage (#1073): defenum empty rejection,
;; defstruct mixed field types, empty struct rejection, struct-get, and
;; struct construction-as-call.
(define (compiler-parse-enum-struct-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(defenum Empty)"
      "parse: defenum needs at least one variant")
    (compiler-parse-ok? "(defstruct Point (x i64) (y i64))")
    (compiler-parse-ok? "(defstruct Mixed (a i64) (b bool) (c f64))")
    (compiler-parse-error-ok?
      "(defstruct Empty)"
      "parse: defstruct needs at least one field")
    (compiler-parse-ok? "(define (f [p : Point]) : i64 (struct-get p x))")
    (compiler-parse-ok? "(define (f) : Point (Point 1 2))")
    (compiler-parse-ok? "(defstruct RefBox (:lifetimes a) (value (& a i64)))")
    (compiler-parse-ok?
      "(defenum RefOption (:lifetimes a) (SomeRef (& a i64)) (NoRef))")
    (compiler-parse-ok?
      "(define (f [box : (RefBox n)]) : (& n i64) (struct-get box value))")))

;
;; let-binding parsing (#1072 / #1041): accept untyped, multi-binding, and
;; legacy-parenthesized binding forms; reject an empty binding list. Completes
;; the let family alongside the existing flat-let accept and let error tests.
(define (compiler-parse-let-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (let [x 1] x))")
    (compiler-parse-ok?
      "(define (main) : i64 (let [x : i64 1] [y : i64 2] (+ x y)))")
    (compiler-parse-ok? "(define (main) : i64 (let ([x : i64 1]) x))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let [] 0))"
      "parse: malformed let binding")))

(define (compiler-parse-spmd-tests-ok?) : bool
  (and
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : i64 0 3]) unit) 0))")
    (compiler-parse-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))")
    (compiler-parse-ok?
      "(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (array-set! out i (spmd-broadcast (array-ref xs i) 0))) 0))")
    ;; #1073: an empty range, a non-i64 index type, and expression
    ;; start/end bounds all parse (range semantics are checked later).
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : i64 5 5]) unit) 0))")
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : u32 0 3]) unit) 0))")
    (compiler-parse-ok?
      "(define (main [n : i64]) : i64 (begin (foreach ([i : i64 (+ 0 1) (* n 2)]) unit) 0))")
    ;; #1073: an unknown reduce operator is rejected by the parser.
    (compiler-parse-error-ok?
      "(define (main [n : i64]) : i64 (spmd-reduce bogus ([i : i64 0 n]) 0 i))"
      "parse: unsupported spmd-reduce operator `bogus`; expected one of sum, min, max, all, any")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach ([i i64 0 3 4]) unit) 0))"
      "parse: expected ':' in foreach")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach ([i : i64 0]) unit) 0))"
      "parse: malformed foreach binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach) 0))"
      "parse: malformed foreach")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-reduce sum))"
      "parse: malformed spmd-reduce")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-broadcast 1))"
      "parse: malformed spmd-broadcast")))

(define (compiler-parse-pattern-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (match 1 [0 1] [_ 0]))")
    (compiler-parse-ok?
      "(define (main [b : bool]) : i64 (match b [true 1] [false 0]))")
    (compiler-parse-ok?
      "(defenum E (A i64) (B))
(define (main [e : E]) : i64 (match e [(A x) x] [(B) 0]))")
    (compiler-parse-ok? "(define (main) : i64 (match 5 [x x]))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (match))"
      "parse: malformed match")
    (compiler-parse-error-ok?
      "(define (main) : i64 (match 1 [_]))"
      "parse: malformed match arm")
    (compiler-parse-error-ok?
      "(define (main) : i64 (match 1 [() 0]))"
      "parse: expected pattern")))

;; pattern literals (#1073): string literal arms, nested string payload,
;; char literal in pattern, named char literal in value position.
(define (compiler-parse-pattern-string-char-tests-ok?) : bool
  (and
    ;; string literal arms
    (compiler-parse-ok?
      "(define (f [s : String]) : i64 (match s [\"if\" 10] [\"let\" 20] [_ 0]))")
    ;; nested string payload
    (compiler-parse-ok?
      "(defenum Token (TIdent String))\n(define (f [t : Token]) : i64 (match t [(TIdent \"if\") 1] [_ 0]))")
    ;; char literal in pattern (named space + literal char)
    (compiler-parse-ok?
      "(define (f [c : char]) : i64 (match c [#\\space' 1] [#a' 2] [_ 0]))")
    ;; named char literal in value position
    (compiler-parse-ok? "(define (f) : char #\\newline')")))

;
;; operator parsing (#1073 / #1041): accept unary (not/neg/bit-not), binary
;; arithmetic/comparison, and bitwise/shift operator forms; reject
;; parser-owned malformed unary/binary operator expressions. Parse-shape only;
;; operator type rules live in the typechecker tests.
(define (compiler-parse-operator-tests-ok?) : bool
  (and
    (compiler-parse-ok?
      "(define (main [a : i64] [p : bool]) : i64 (begin (neg a) (bit-not a) (if (not p) 1 0)))")
    (compiler-parse-ok?
      "(define (main [a : i64] [b : i64]) : i64 (begin (+ a b) (- a b) (* a b) (< a b) (<= a b) (> a b) (>= a b) (= a b) (!= a b)))")
    (compiler-parse-ok?
      "(define (main [a : i64] [b : i64] [p : bool]) : i64 (begin (bit-and a b) (bit-or a b) (bit-xor a b) (shl a b) (shr a b) (if (not p) 1 0)))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (not))"
      "parse: malformed unary expression")
    (compiler-parse-error-ok?
      "(define (main [a : i64]) : i64 (+ a))"
      "parse: malformed binary expression")))

(define (compiler-parse-type-literal-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (begin (type i64) 0))")
    (compiler-parse-ok? "(define (main) : i64 (begin (type (Array i64)) 0))")
    (compiler-parse-ok? "(define (main) : i64 (begin (type (-> i64 i64)) 0))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (type))"
      "parse: type expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main) : i64 (type i64 bool))"
      "parse: type expects exactly one type")))

;; region parsing (#1073 / #1041): `(with-arena <ident> body+)` accepts (basic,
;; multi-expression body, nested region) and rejects missing binder,
;; non-identifier binder, and empty body. Parse-shape + parser-owned diagnostics
;; only; region typing/lowering live in their own tests.
(define (compiler-parse-region-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (with-arena r 0))")
    (compiler-parse-ok? "(define (main) : i64 (with-arena r 1 2 0))")
    (compiler-parse-ok? "(define (main) : i64 (with-arena r (with-arena s 0)))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-arena))"
      "parse: with-arena requires a region name before its body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-arena 5 0))"
      "parse: with-arena region name must be an identifier")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-arena r))"
      "parse: with-arena 'r' requires a non-empty body")))

(define (compiler-parse-with-escape-shape-ok?) : bool
  (match (parse-ast-source
    "(define (main) : String (with-escape (arena-make) (int->string 42)))")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match (ast-expr-unspan body)
                    [(AstExprWithEscape scratch-box body-exprs)
                      (let
                        [scratch : AstExpr (ast-node-get scratch-box)]
                        (match (ast-expr-unspan scratch)
                          [(AstExprCall callee-box AstExprNil)
                            (let
                              [callee : AstExpr (ast-node-get callee-box)]
                              (match (ast-expr-unspan callee)
                                [(AstExprVar name)
                                  (and
                                    (string-eq (intern-str name) "arena-make")
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
    (compiler-parse-ok?
      "(define (main) : i64 (let ([scratch : i64 (arena-make)]) (with-escape scratch 1 2 3)))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-escape))"
      "parse: with-escape requires a scratch arena before its body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-escape (arena-make)))"
      "parse: with-escape requires a non-empty body")))

(define (compiler-parse-with-scratch-shape-ok?) : bool
  (match (parse-ast-source
    "(define (main) : String (with-scratch (int->string 41) (int->string 42)))")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match (ast-expr-unspan body)
                    [(AstExprWithScratch body-exprs)
                      (match body-exprs
                        [(AstExprCons _ tail)
                          (let
                            [tail : AstExprList (box-get tail)]
                            (match tail
                              [(AstExprCons _ end)
                                (match (box-get end)
                                  [(AstExprNil) true]
                                  [_ false])]
                              [_ false]))]
                        [_ false])]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-with-scratch-tests-ok?) : bool
  (and
    (compiler-parse-with-scratch-shape-ok?)
    (compiler-parse-ok? "(define (main) : i64 (with-scratch 1 2 3))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-scratch))"
      "parse: with-scratch requires a non-empty body")))

(define (compiler-parse-in-arena-shape-ok?) : bool
  (match (parse-ast-source
    "(define (main [arena : i64]) : i64 (in-arena arena 1 2))")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match (ast-expr-unspan body)
                    [(AstExprInArena arena-box body-exprs)
                      (let
                        [arena : AstExpr (ast-node-get arena-box)]
                        (match (ast-expr-unspan arena)
                          [(AstExprVar name)
                            (and
                              (string-eq (intern-str name) "arena")
                              (match body-exprs
                                [(AstExprCons _ tail)
                                  (let
                                    [tail : AstExprList (box-get tail)]
                                    (match tail
                                      [(AstExprCons _ end)
                                        (match (box-get end)
                                          [(AstExprNil) true]
                                          [_ false])]
                                      [_ false]))]
                                [_ false]))]
                          [_ false]))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-in-arena-tests-ok?) : bool
  (and
    (compiler-parse-in-arena-shape-ok?)
    (compiler-parse-ok?
      "(define (main) : i64 (let ([arena : i64 0]) (in-arena arena 1 2 3)))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (in-arena))"
      "parse: in-arena requires an arena before its body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (in-arena 0))"
      "parse: in-arena requires a non-empty body")))

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
          [(AstDeclCons (AstDeclDefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (match (ast-expr-unspan body)
                    [(AstExprWithResource wr-box)
                      (match (box-get wr-box)
                        [(AstWithResource bindings body-exprs)
                          (and
                            (=
                              (compiler-parse-resource-binding-count bindings)
                              2)
                            (= (compiler-parse-expr-list-count body-exprs) 2)
                            (match body-exprs
                              [(AstExprCons _ tail)
                                (let
                                  [tail : AstExprList (box-get tail)]
                                  (match tail
                                    [(AstExprCons nested done-box)
                                      (let
                                        [nested : AstExpr (ast-node-get nested)]
                                        [done : AstExprList (box-get done-box)]
                                        (match done
                                          [(AstExprNil)
                                            (match (ast-expr-unspan nested)
                                              [(AstExprWithResource
                                                  nested-wr-box)
                                                (match (box-get nested-wr-box)
                                                  [(AstWithResource
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
                                                        1))])]
                                              [_ false])]
                                          [_ false]))]
                                    [_ false]))]
                              [_ false]))])]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-resource-with-tests-ok?) : bool
  (and
    (compiler-parse-resource-with-shape-ok?)
    (compiler-parse-ok?
      "(define (main) : i64 (with ([h (open-handle) close-handle]) 42))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with))"
      "parse: with requires a binding list before its body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with () 42))"
      "parse: with requires a non-empty binding list")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([1 (open) close]) 42))"
      "parse: with binding name must be an identifier")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([h]) 42))"
      "parse: with binding is missing initializer")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([h (open)]) 42))"
      "parse: with binding is missing cleanup function")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([h (open) close extra]) 42))"
      "parse: with binding has too many fields")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([h (open) close])))"
      "parse: with requires a non-empty body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with [h (open) close] 42))"
      "parse: malformed with binding list")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ((h (open) close)) 42))"
      "parse: with binding must use bracket syntax")))

(define (compiler-parse-quote-syntax-shape-ok?) : bool
  (match (parse-ast-source
    "(define (mk [e : Expr]) : Expr `(if ,e true false))")
    [(OkAstProgram (AstProgram decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match decls
          [(AstDeclCons (AstDeclDefFn _ _ ret-ty body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList (box-get rest)]
              (match rest
                [(AstDeclNil)
                  (and
                    (match ret-ty
                      [(AstTyVar name) (string-eq (intern-str name) "Expr")]
                      [_ false])
                    (match (ast-expr-unspan body)
                      [(AstExprQuasiquote template-box)
                        (let
                          [template : AstExpr (ast-node-get template-box)]
                          (match (ast-expr-unspan template)
                            [(AstExprIf cond-box _ _)
                              (let
                                [cond : AstExpr (ast-node-get cond-box)]
                                (match (ast-expr-unspan cond)
                                  [(AstExprUnquote unquoted-box)
                                    (let
                                      [unquoted : AstExpr
                                        (ast-node-get unquoted-box)]
                                      (match (ast-expr-unspan unquoted)
                                        [(AstExprVar name)
                                          (string-eq (intern-str name) "e")]
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
    (compiler-parse-ok? "(define x : Expr '(+ 1 2))")
    (compiler-parse-ok? "(define x : Expr `(begin ,@xs))")
    (compiler-parse-error-ok?
      "(define x : Expr (quote))"
      "parse: quote form expects exactly one expression")))

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
    ;; parenthesized expression item
    (compiler-parse-repl-expr-ok? "(+ 1 2)")
    ;; unknown function-style calls are REPL expressions, not module macro decls
    (compiler-parse-repl-expr-ok? "(double 4)")
    ;; bare expression item
    (compiler-parse-repl-expr-ok? "42")
    ;; trailing tokens after a complete item are rejected
    (compiler-parse-repl-error-ok?
      "42 43"
      "parse: trailing tokens after REPL input")
    ;; a malformed expression item surfaces the expression diagnostic
    (compiler-parse-repl-error-ok? "(+ 1)" "parse: malformed binary expression")))

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
          [(AstDeclCons (AstDeclDefFn _ params _ _ _) _)
            (ast-param-list-has-comptime? params)]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-comptime-param-tests-ok?) : bool
  (and
    (compiler-parse-first-fn-has-comptime-param?
      "(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))")
    (compiler-parse-first-fn-has-comptime-param?
      "(define (alloc [comptime T : type] [n : i64]) : (Array i64) (make-array T n))")
    (compiler-parse-error-ok?
      "(define (main) : i64 ((lambda ([comptime n : i64]) n) 1))"
      "comptime parameters are only supported on top-level function definitions")))

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
                    (= name (intern "all"))
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
                                (= first (intern "first"))
                                (= rest (intern "rest")))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ErrAstProgram _) false]))

(define (compiler-parse-defmacro-tests-ok?) : bool
  (and
    (compiler-parse-defmacro-shape-ok?)
    (compiler-parse-ok?
      "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool (expr-if lhs rhs (expr-bool false)))")
    (compiler-parse-error-ok?
      "(defmacro (bad [rest : bool ...] [x : bool]) : bool rest)"
      "parse: variadic macro operand must be final")))

(define (compiler-parse-shape-tests-front-ok? [program : AstProgram]) : bool
  (and
    (= (compiler-parse-smoke-score program) 36)
    (compiler-parse-nested-expr-span-ok?)
    (compiler-parse-error-span-ok?)
    (compiler-parse-float-literal-ok?)
    (compiler-parse-region-ok?)
    (compiler-parse-arena-ok?)))

(define (compiler-parse-shape-tests-middle-ok?) : bool
  (and
    (compiler-parse-comptime-decl-ok?)
    (compiler-parse-comptime-decls-ok?)
    (compiler-parse-unsafe-decl-ok?)
    (compiler-parse-module-decl-ok?)
    (compiler-parse-import-metadata-ok?)
    (compiler-parse-dotted-import-metadata-ok?)
    (compiler-parse-module-macro-surface-ok?)
    (compiler-parse-export-decl-ok?)
    (compiler-parse-defdispatch-tests-ok?)
    (compiler-parse-flat-let-call-body-ok?)
    (compiler-parse-inline-test-ok?)
    (compiler-parse-try-ok?)))

(define (compiler-parse-error-suite-front-ok?) : bool
  (and
    (compiler-parse-error-tests-ok?)
    (compiler-parse-declaration-tests-ok?)
    (compiler-parse-let-tests-ok?)
    (compiler-parse-spmd-tests-ok?)
    (compiler-parse-pattern-tests-ok?)
    (compiler-parse-pattern-string-char-tests-ok?)))

(define (compiler-parse-error-suite-middle-ok?) : bool
  (and
    (compiler-parse-enum-struct-tests-ok?)
    (compiler-parse-operator-tests-ok?)
    (compiler-parse-type-literal-tests-ok?)
    (compiler-parse-region-tests-ok?)
    (compiler-parse-repl-tests-ok?)
    (compiler-parse-comptime-param-tests-ok?)))

(define (compiler-parse-error-suite-back-ok?) : bool
  (and
    (compiler-parse-defmacro-tests-ok?)
    (compiler-parse-resource-with-tests-ok?)
    (compiler-parse-with-escape-tests-ok?)
    (compiler-parse-with-scratch-tests-ok?)
    (compiler-parse-in-arena-tests-ok?)
    (compiler-parse-quote-syntax-tests-ok?)
    (compiler-parse-export-error-tests-ok?)
    (compiler-parse-define-export-metadata-error-tests-ok?)
    (compiler-parse-dotted-import-errors-ok?)))

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
    (if (compiler-parse-extern-varargs-metadata-rejected-ok?)
      unit
      (panic "parse: extern c-varargs metadata retirement test failed"))
    (if (compiler-parse-extern-function-head-varargs-ok?)
      unit
      (panic "parse: extern function-head varargs shape test failed"))
    (if (compiler-parse-define-export-symbol-ok?)
      unit
      (panic "parse: define export-symbol shape test failed"))
    (if (compiler-parse-raw-pointer-ops-ok?)
      unit
      (panic "parse: raw pointer ops shape test failed"))
    (if (compiler-parse-init-ok?)
      unit
      (panic "parse: init shape test failed"))
    (if (compiler-parse-contextual-init-ok?)
      unit
      (panic "parse: contextual init shape test failed"))
    (if (compiler-parse-init-call-name-ok?)
      unit
      (panic "parse: init call name compatibility test failed"))
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
    (if (compiler-parse-with-scratch-shape-ok?)
      unit
      (panic "parse: with-scratch shape test failed"))
    (if (compiler-parse-in-arena-shape-ok?)
      unit
      (panic "parse: in-arena shape test failed"))
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
        (compiler-parse-nested-expr-span-ok?)
        (compiler-parse-error-span-ok?)
        (compiler-parse-reader-delimiter-diagnostics-ok?)
        (compiler-parse-float-literal-ok?)
        (compiler-parse-region-ok?)
        (compiler-parse-arena-ok?)
        (compiler-parse-comptime-decl-ok?)
        (compiler-parse-unsafe-decl-ok?)
        (compiler-parse-module-decl-ok?)
        (compiler-parse-import-metadata-ok?)
        (compiler-parse-dotted-import-metadata-ok?)
        (compiler-parse-module-macro-surface-ok?)
        (compiler-parse-export-decl-ok?)
        (compiler-parse-defdispatch-tests-ok?)
        (compiler-parse-flat-let-call-body-ok?)
        (compiler-parse-inline-test-ok?)
        (compiler-parse-try-ok?)
        (compiler-parse-return-ok?)
        (compiler-parse-guard-forms-ok?)
        (compiler-parse-bracket-cond-call-ok?)
        (compiler-parse-and-or-macro-call-candidates-ok?)
        (compiler-parse-repr-c-ok?)
        (compiler-parse-cleanup-metadata-ok?)
        (compiler-parse-raw-pointer-ok?)
        (compiler-parse-extern-metadata-ok?)
        (compiler-parse-extern-varargs-metadata-rejected-ok?)
        (compiler-parse-extern-function-head-varargs-ok?)
        (compiler-parse-raw-pointer-ops-ok?)
        (compiler-parse-init-ok?)
        (compiler-parse-contextual-init-ok?)
        (compiler-parse-init-call-name-ok?)
        (compiler-parse-box-ok?)
        (compiler-parse-reference-ok?)
        (compiler-parse-borrow-ok?)
        (compiler-parse-resource-with-shape-ok?)
        (compiler-parse-quote-syntax-shape-ok?))
        (if (and
          (compiler-parse-error-tests-ok?)
          (compiler-parse-declaration-tests-ok?)
          (compiler-parse-let-tests-ok?)
          (compiler-parse-spmd-tests-ok?)
          (compiler-parse-pattern-tests-ok?)
          (compiler-parse-pattern-string-char-tests-ok?)
          (compiler-parse-enum-struct-tests-ok?)
          (compiler-parse-operator-tests-ok?)
          (compiler-parse-type-literal-tests-ok?)
          (compiler-parse-region-tests-ok?)
          (compiler-parse-repl-tests-ok?)
          (compiler-parse-comptime-param-tests-ok?)
          (compiler-parse-defmacro-tests-ok?)
          (compiler-parse-resource-with-tests-ok?)
          (compiler-parse-quote-syntax-tests-ok?)
          (compiler-parse-export-error-tests-ok?)
          (compiler-parse-dotted-import-errors-ok?)
          (compiler-parse-cfg-tests-ok?))
          42
          (begin
            (panic "parse: error-path self-tests failed")
            ;; lint-allow: unreachable-code
            0))
        (begin
          (panic "parse: compiler AST smoke score mismatch")
          ;; lint-allow: unreachable-code
          0))]
    [(ErrAstProgram message)
      (begin
        (panic message)
        ;; lint-allow: unreachable-code
        0)]))