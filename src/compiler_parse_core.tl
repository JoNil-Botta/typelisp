;; compiler_parse_core.tl - Sexpr -> real compiler AST parser.
;;
;; This module targets `compiler_ast_types.tl`, not the smaller
;; compile_smoke AST. It stays parser-only: the later selfhost passes consume
;; the parsed `AstProgram` for typechecking/lowering.
(import stdlib.array)
(import stdlib.io)
(import compiler_intern as ci)
(import "compiler_ast_types.tl")
(import "compiler_diagnostic.tl")
(import "read.tl")
(import sym_i64_env)
(import stdlib.string)
(import stdlib.option)
(import token)
(import (option i64) as option_i64)

(defenum ResultAstType
  (Ok AstType)
  (Err String))

(defenum ResultAstReduceOp
  (Ok AstReduceOp)
  (Err String))

(defenum ResultAstFuncTypeParts
  (Ok AstTypeList AstType)
  (Err String))

(defenum ResultAstTypeList
  (Ok AstTypeList)
  (Err String))

(defenum ResultAstTypeListBuild
  (Ok)
  (Err String))

(defenum ResultAstLifetimeList
  (Ok AstLifetimeList)
  (Err String))

(defenum ResultAstLifetimeListBuild
  (Ok)
  (Err String))

(defenum ResultAstParam
  (Ok AstParam)
  (Err String))

(defenum ResultAstParamList
  (Ok AstParamList)
  (Err String))

(defenum ResultAstParamListBuild
  (Ok)
  (Err String))

(defenum ResultAstMacroParam
  (Ok AstMacroParam)
  (Err String))

(defenum ResultAstMacroParamList
  (Ok AstMacroParamList)
  (Err String))

(defenum ResultAstMacroParamListBuild
  (Ok)
  (Err String))

(defenum ResultAstFieldDef
  (Ok AstFieldDef)
  (Err String))

(defenum ResultAstFieldDefList
  (Ok AstFieldDefList)
  (Err String))

(defenum ResultAstFieldDefListBuild
  (Ok)
  (Err String))

(defenum ResultAstFieldCleanup
  (Ok AstFieldCleanup)
  (Err String))

(defenum ResultAstStructRepr
  (Ok AstStructRepr)
  (Err String))

(defenum ResultAstStructCleanup
  (Ok AstStructCleanup)
  (Err String))

(defenum ResultAstEnumCleanup
  (Ok AstEnumCleanup)
  (Err String))

(defenum ResultAstVariantPayloadCleanup
  (Ok AstVariantPayloadCleanup)
  (Err String))

(defenum ResultAstVariantPayloadParts
  (Ok AstTypeList AstVariantPayloadCleanupList)
  (Err String))

(defenum ResultAstStructDefParts
  (Ok AstLifetimeList AstStructRepr AstStructCleanup AstFieldDefList)
  (Err String))

(defenum ResultAstEnumDefParts
  (Ok AstLifetimeList AstEnumCleanup AstVariantDefList)
  (Err String))

(defenum ResultAstExternAbi
  (Ok AstExternAbi)
  (Err String))

(defenum ResultAstExternSymbol
  (Ok String)
  (Err String))

(defenum ResultAstFnExport
  (Ok AstFnExport)
  (Err String))

(defenum ResultAstExternParts
  (Ok AstExternAbi String bool AstType)
  (Err String))

(defenum AstExternHeadItem
  (Param AstType)
  (VarargsOpen)
  (VarargsTyped AstType))

(defenum ResultAstExternHeadItem
  (Ok AstExternHeadItem)
  (Err String))

(defenum ResultAstExternHeader
  (Ok String AstTypeList AstExternAbi)
  (Err String))

(defenum ResultAstVariantDef
  (Ok AstVariantDef)
  (Err String))

(defenum ResultAstVariantDefList
  (Ok AstVariantDefList)
  (Err String))

(defenum ResultAstVariantDefListBuild
  (Ok)
  (Err String))

(defenum ResultAstDispatchIsa
  (Ok AstDispatchIsa)
  (Err String))

(defenum ResultAstDispatchVariant
  (Ok AstDispatchVariant)
  (Err String))

(defenum ResultAstDispatchVariantList
  (Ok AstDispatchVariantList)
  (Err String))

(defenum ResultAstDispatchVariantListBuild
  (Ok)
  (Err String))

(defenum ResultAstPattern
  (Ok AstPattern)
  (Err String))

(defenum ResultAstPatternList
  (Ok AstPatternList)
  (Err String))

(defenum ResultAstPatternListBuild
  (Ok)
  (Err String))

(defenum ResultAstLetBinding
  (Ok AstLetBinding)
  (Err String))

(defenum ResultAstLetBindingList
  (Ok AstLetBindingList)
  (Err String))

(defenum ResultAstLetBindingListBuild
  (Ok)
  (Err String))

(defenum ResultAstResourceBinding
  (Ok AstResourceBinding)
  (Err String))

(defenum ResultAstResourceBindingList
  (Ok AstResourceBindingList)
  (Err String))

(defenum ResultAstResourceBindingListBuild
  (Ok)
  (Err String))

(defenum ResultAstLetParts
  (Ok AstLetBindingList i64)
  (Err String))

(defenum ResultAstMatchArm
  (Ok AstMatchArm)
  (Err String))

(defenum ResultAstMatchArmList
  (Ok AstMatchArmList)
  (Err String))

(defenum ResultAstMatchArmListBuild
  (Ok)
  (Err String))

(defenum ResultAstExpr
  (Ok i64)
  (Err String))

(defstruct AstExprPair
  (first i64)
  (second i64))

(defenum ResultAstExprPair
  (Ok AstExprPair)
  (Err String))

(defenum ResultAstExprList
  (Ok AstExprList)
  (Err String))

(defenum ResultAstExprListBuild
  (Ok)
  (Err String))

(defenum ResultAstGeneratedDeclMeta
  (Ok AstGeneratedDeclMeta)
  (Err String))

(defenum ResultAstDecl
  (Ok AstDecl)
  (Err String))

(defenum ResultAstMaybeDecl
  (NoDecl)
  (SomeDecl AstDecl)
  (Decls AstDeclList)
  (Err String))

(defenum ResultAstDeclList
  (Ok AstDeclList)
  (Err String))

(defenum ResultParseAstDeclVec
  (Ok)
  (Err String))

(defenum ResultParseAstDeclVecDiagnostic
  (Ok)
  (Err (Box CompilerDiagnostic)))

(defenum ResultAstMaybeExpr
  (NoExpr)
  (SomeExpr i64)
  (Err String))

(defenum ResultCompilerCfg
  (Ok bool)
  (Err String))

(defenum ResultAstProgram
  (Ok AstProgram)
  (Err String))

(defenum AstReplItem
  (AstReplDecl AstDecl)
  (AstReplExpr i64))

(defenum ResultAstReplItem
  (Ok AstReplItem)
  (Err String))

(defenum ResultAstDeclListDiagnostic
  (Ok AstDeclList)
  (Err (Box CompilerDiagnostic)))

(defenum ResultAstProgramDiagnostic
  (Ok AstProgram)
  (Err (Box CompilerDiagnostic)))

(define (sexpr-colon? [s : Sexpr]) : bool
  (match s
    [(Sexpr.Sym text) (string.eq text ":")]
    [_ false]))

(define (compiler-cfg-key [name : String]) : String
  (string.append "cfg:" name))

(define (compiler-cfg-private-dynamic-buffer-key) : String
  "cfg:feature-compiler-private-dynamic-buffer")

(define (compiler-cfg-empty) : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-empty))

(define (compiler-cfg-enable [cfgs : sym_i64_env.SymI64Env] [name : String]) : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-bind cfgs (compiler-cfg-key name) 1))

(define (compiler-cfg-enable-private-dynamic-buffer
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-bind cfgs (compiler-cfg-private-dynamic-buffer-key) 1))

(define (compiler-cfg-merge
  [base : sym_i64_env.SymI64Env]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (match cfgs
    [(sym_i64_env.SymI64Nil) base]
    [(sym_i64_env.SymI64Bind name-id value rest)
      (sym_i64_env.sym-i64-bind
        (compiler-cfg-merge base (box-get rest))
        (intern-str name-id)
        value)]))

(define (compiler-cfg-enabled?
  [dispatch : sym_i64_env.SymI64Env]
  [name : String]) : bool
  (sym_i64_env.sym-i64-contains dispatch (compiler-cfg-key name)))

(define (compiler-cfg-private-dynamic-buffer-enabled?
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (sym_i64_env.sym-i64-contains cfgs (compiler-cfg-private-dynamic-buffer-key)))

(define (compiler-cfg-eval-list-all
  [dispatch : sym_i64_env.SymI64Env]
  [predicates : SpannedSexpr]) : ResultCompilerCfg
  (match predicates
    [(SpannedSexpr.Nil _) (ResultCompilerCfg.Ok true)]
    [(SpannedSexpr.Cons head tail _)
      (match (compiler-cfg-eval dispatch (sp-node-get head))
        [(ResultCompilerCfg.Ok enabled)
          (if enabled
            (compiler-cfg-eval-list-all dispatch (sp-node-get tail))
            (ResultCompilerCfg.Ok false))]
        [(ResultCompilerCfg.Err message) (ResultCompilerCfg.Err message)])]
    [_ (ResultCompilerCfg.Err "parse: cfg all expects predicates")]))

(define (compiler-cfg-eval-list-any
  [dispatch : sym_i64_env.SymI64Env]
  [predicates : SpannedSexpr]) : ResultCompilerCfg
  (match predicates
    [(SpannedSexpr.Nil _) (ResultCompilerCfg.Ok false)]
    [(SpannedSexpr.Cons head tail _)
      (match (compiler-cfg-eval dispatch (sp-node-get head))
        [(ResultCompilerCfg.Ok enabled)
          (if enabled
            (ResultCompilerCfg.Ok true)
            (compiler-cfg-eval-list-any dispatch (sp-node-get tail)))]
        [(ResultCompilerCfg.Err message) (ResultCompilerCfg.Err message)])]
    [_ (ResultCompilerCfg.Err "parse: cfg any expects predicates")]))

(define (compiler-cfg-eval-not
  [dispatch : sym_i64_env.SymI64Env]
  [predicates : SpannedSexpr]) : ResultCompilerCfg
  (match predicates
    [(SpannedSexpr.Cons pred tail _)
      (match (sp-node-get tail)
        [(SpannedSexpr.Nil _)
          (match (compiler-cfg-eval dispatch (sp-node-get pred))
            [(ResultCompilerCfg.Ok enabled)
              (ResultCompilerCfg.Ok (not enabled))]
            [(ResultCompilerCfg.Err message) (ResultCompilerCfg.Err message)])]
        [_
          (ResultCompilerCfg.Err "parse: cfg not expects exactly one predicate")])]
    [_ (ResultCompilerCfg.Err "parse: cfg not expects exactly one predicate")]))

(define (compiler-cfg-eval
  [dispatch : sym_i64_env.SymI64Env]
  [predicate : SpannedSexpr]) : ResultCompilerCfg
  (match predicate
    [(SpannedSexpr.Sym name _)
      (ResultCompilerCfg.Ok (compiler-cfg-enabled? dispatch name))]
    [(SpannedSexpr.Cons head predicates _)
      (match (sp-node-get head)
        [(SpannedSexpr.Sym op _)
          (cond
            [(string.eq op "all")
              (compiler-cfg-eval-list-all dispatch (sp-node-get predicates))]
            [(string.eq op "any")
              (compiler-cfg-eval-list-any dispatch (sp-node-get predicates))]
            [(string.eq op "not")
              (compiler-cfg-eval-not dispatch (sp-node-get predicates))]
            [else
              (ResultCompilerCfg.Err
                "parse: cfg predicate expects a name, all, any, or not")])]
        [_ (ResultCompilerCfg.Err "parse: malformed cfg predicate")])]
    [_ (ResultCompilerCfg.Err "parse: malformed cfg predicate")]))

(define (compiler-parse-abstraction-policy-message) : String
  "parse: TypeLisp does not support source-level generics or traits; use comptime-decl and comptime-generated concrete declarations instead")

(define (compiler-parse-generic-type-policy-message [name : String]) : String
  (cond
    [(string.eq name "varying")
      "parse: public SPMD varying source types are deferred; varying is inferred inside foreach"]
    [(string.eq name "Varying")
      "parse: public SPMD varying source types are deferred; varying is inferred inside foreach"]
    [(string.eq name "Vector")
      "parse: public SPMD vector source types are deferred; vector values remain compiler-internal"]
    [(string.eq name "vector")
      "parse: public SPMD vector source types are deferred; vector values remain compiler-internal"]
    [(string.eq name "Mask")
      "parse: public SPMD mask source types are deferred; masks remain compiler-internal"]
    [(string.eq name "mask")
      "parse: public SPMD mask source types are deferred; masks remain compiler-internal"]
    [else
      (string.append
        "parse: unknown type constructor "
        (string.append
          name
          "; TypeLisp has no source-level generic type constructors; use comptime-decl and comptime-generated concrete declarations instead"))]))

(define (compiler-parse-policy-form? [name : String]) : bool
  (cond
    [(string.eq name "defgeneric") true]
    [(string.eq name "generic") true]
    [(string.eq name "deftrait") true]
    [(string.eq name "trait") true]
    [(string.eq name "interface") true]
    [(string.eq name "impl") true]
    [else (string.eq name "where")]))

(define (ast-source-span-from-source-span [span : token.SourceSpan]) : AstSourceSpan
  (ast-source-span
    (token.span-start-line span)
    (token.span-start-col span)
    (token.span-end-line span)
    (token.span-end-col span)))

;; Parser result enums still carry message strings; diagnostic parsing records
;; the first failing spanned subform here while that message bubbles outward.
(define parse-ast-error-span-active : bool
  false)
(define parse-ast-error-span-start-line : i64
  0)
(define parse-ast-error-span-start-col : i64
  0)
(define parse-ast-error-span-end-line : i64
  0)
(define parse-ast-error-span-end-col : i64
  0)

(define (parse-ast-error-span-clear!) : unit
  (begin
    (set! parse-ast-error-span-active false)
    unit))

(define (parse-ast-error-span-note! [span : token.SourceSpan]) : unit
  (if parse-ast-error-span-active
    unit
    (begin
      (set! parse-ast-error-span-active true)
      (set! parse-ast-error-span-start-line (token.span-start-line span))
      (set! parse-ast-error-span-start-col (token.span-start-col span))
      (set! parse-ast-error-span-end-line (token.span-end-line span))
      (set! parse-ast-error-span-end-col (token.span-end-col span))
      unit)))

(define (parse-ast-error-span-current [fallback : token.SourceSpan]) : token.SourceSpan
  (if parse-ast-error-span-active
    (token.SourceSpan
      parse-ast-error-span-start-line
      parse-ast-error-span-start-col
      parse-ast-error-span-end-line
      parse-ast-error-span-end-col)
    fallback))

(define (parse-ast-error-span-note-expr
  [s : SpannedSexpr]
  [result : ResultAstExpr]) : ResultAstExpr
  (match result
    [(ResultAstExpr.Err _)
      (begin
        (parse-ast-error-span-note! (spanned-sexpr-span s))
        result)]
    [_ result]))

(define (parse-ast-error-span-note-let-binding
  [s : SpannedSexpr]
  [result : ResultAstLetBinding]) : ResultAstLetBinding
  (match result
    [(ResultAstLetBinding.Err _)
      (begin
        (parse-ast-error-span-note! (spanned-sexpr-span s))
        result)]
    [_ result]))

(define (parse-ast-error-span-note-decl
  [s : SpannedSexpr]
  [result : ResultAstDecl]) : ResultAstDecl
  (match result
    [(ResultAstDecl.Err _)
      (begin
        (parse-ast-error-span-note! (spanned-sexpr-span s))
        result)]
    [_ result]))

(define (parse-ast-error-span-note-maybe-decl
  [s : SpannedSexpr]
  [result : ResultAstMaybeDecl]) : ResultAstMaybeDecl
  (match result
    [(ResultAstMaybeDecl.Err _)
      (begin
        (parse-ast-error-span-note! (spanned-sexpr-span s))
        result)]
    [_ result]))

(define (ast-expr-wrap-span
  [pools : AstNodePoolContext]
  [expr : i64]
  [s : SpannedSexpr]) : i64
  (ast-expr-spanned-with-pools
    pools
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

(define (compiler-parse-tag-ty-dyn-array) : i64
  139)

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

(define (compiler-parse-tag-expr-array-take) : i64
  303)

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

(define compiler-parse-current-load-has-type-literal : bool
  false)

(define (compiler-parse-type-literal-tracking-reset!) : unit
  (set! compiler-parse-current-load-has-type-literal false))

(define (compiler-parse-type-literal-tracking-mark!) : unit
  (set! compiler-parse-current-load-has-type-literal true))

(define (compiler-parse-current-load-has-type-literal?) : bool
  compiler-parse-current-load-has-type-literal)

(define (compiler-parse-tag-expr-init) : i64
  288)

(define (compiler-parse-tag-expr-spmd-reduce) : i64
  250)

(define (compiler-parse-tag-expr-spmd-scan) : i64
  294)

(define (compiler-parse-tag-expr-spmd-broadcast) : i64
  290)

(define (compiler-parse-tag-expr-spmd-shuffle) : i64
  297)

(define (compiler-parse-tag-expr-spmd-program-index) : i64
  295)

(define (compiler-parse-tag-expr-spmd-program-count) : i64
  296)

(define (compiler-parse-tag-expr-try) : i64
  251)

(define (compiler-parse-tag-expr-return) : i64
  270)

(define (compiler-parse-tag-expr-break) : i64
  298)

(define (compiler-parse-tag-expr-continue) : i64
  299)

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

(define (compiler-parse-tag-decl-include-str) : i64
  410)

(define (compiler-parse-tag-decl-include-bin) : i64
  413)

(define (compiler-parse-tag-decl-defdispatch) : i64
  411)

;; Parser syntax is a closed set, but the general-purpose scoped symbol
;; environment stores it as a 133-node immutable list. Most parsed symbols are
;; ordinary user names, so a miss used to walk that whole list. Keep the
;; environment as the source of truth for cfg evaluation and nonstandard test
;; dispatches, while indexing a complete parser dispatch once per intern
;; generation for constant-time tag lookup.
;;
;; Keys store intern-id+1 so zero remains the empty-slot sentinel. Capacity is a
;; power of two and comfortably below a 0.5 load factor for the closed syntax
;; set, making the mask-and-linear-probe path short without a hashmap module
;; dependency or per-module allocation.
(define compiler-parse-dispatch-index-capacity : i64
  512)
(define compiler-parse-dispatch-index-keys : (Array i64)
  (array.make-array i64 512))
(define compiler-parse-dispatch-index-tags : (Array i64)
  (array.make-array i64 512))
(define compiler-parse-dispatch-index-generation : i64
  -1)
(define compiler-parse-dispatch-index-pool-data-addr : i64
  -1)
(define compiler-parse-dispatch-index-marker-id : i64
  -1)
(define compiler-parse-dispatch-index-ready : bool
  false)

(define (compiler-parse-dispatch-index-clear!) : unit
  (let
    [i : i64 0]
    (while (< i compiler-parse-dispatch-index-capacity)
      (begin
        (array-set! compiler-parse-dispatch-index-keys i 0)
        (set! i (+ i 1))))))

(define (compiler-parse-dispatch-index-current?) : bool
  (and
    (= compiler-parse-dispatch-index-generation (intern-generation))
    (=
      compiler-parse-dispatch-index-pool-data-addr
      (ci.intern-active-pool-data-addr))))

(define (compiler-parse-dispatch-index-insert! [name-id : i64] [tag : i64]) : bool
  (let
    [encoded : i64 (+ name-id 1)]
    [slot : i64 (bit-and name-id (- compiler-parse-dispatch-index-capacity 1))]
    [steps : i64 0]
    (begin
      (while (< steps compiler-parse-dispatch-index-capacity)
        (let
          [present : i64 (array-ref compiler-parse-dispatch-index-keys slot)]
          (if (or (= present 0) (= present encoded))
            (begin
              (array-set! compiler-parse-dispatch-index-keys slot encoded)
              (array-set! compiler-parse-dispatch-index-tags slot tag)
              (return true))
            (begin
              (set!
                slot
                (bit-and
                  (+ slot 1)
                  (- compiler-parse-dispatch-index-capacity 1)))
              (set! steps (+ steps 1))))))
      false)))

(define (compiler-parse-dispatch-index-populate!
  [dispatch : sym_i64_env.SymI64Env]) : unit
  (let
    [generation : i64 (intern-generation)]
    [pool-data-addr : i64 (ci.intern-active-pool-data-addr)]
    (if (and
      (= compiler-parse-dispatch-index-generation generation)
      (= compiler-parse-dispatch-index-pool-data-addr pool-data-addr))
      unit
      (let
        [cursor : sym_i64_env.SymI64Env dispatch]
        [done : bool false]
        (begin
          (compiler-parse-dispatch-index-clear!)
          (set! compiler-parse-dispatch-index-marker-id -1)
          (set! compiler-parse-dispatch-index-ready true)
          (while (and compiler-parse-dispatch-index-ready (not done))
            (match cursor
              [(sym_i64_env.SymI64Nil) (set! done true)]
              [(sym_i64_env.SymI64Bind name-id tag rest)
                (begin
                  (if (= tag (compiler-parse-tag-decl-defdispatch))
                    (set! compiler-parse-dispatch-index-marker-id name-id)
                    unit)
                  (if (compiler-parse-dispatch-index-insert! name-id tag)
                    (set! cursor (box-get rest))
                    (set! compiler-parse-dispatch-index-ready false)))]))
          (if (< compiler-parse-dispatch-index-marker-id 0)
            (set! compiler-parse-dispatch-index-ready false)
            unit)
          (set! compiler-parse-dispatch-index-generation generation)
          (set! compiler-parse-dispatch-index-pool-data-addr pool-data-addr))))))

;; A complete dispatch naturally starts with the defdispatch binding. Derived
;; cfg dispatches repeat that same binding at the head as a semantics-neutral
;; marker; partial/custom environments retain the exact linked-list fallback.
(define (compiler-parse-dispatch-indexed? [dispatch : sym_i64_env.SymI64Env]) : bool
  (and
    compiler-parse-dispatch-index-ready
    (compiler-parse-dispatch-index-current?)
    (match dispatch
      [(sym_i64_env.SymI64Bind name-id tag _)
        (and
          (= name-id compiler-parse-dispatch-index-marker-id)
          (= tag (compiler-parse-tag-decl-defdispatch)))]
      [(sym_i64_env.SymI64Nil) false])))

(define (compiler-parse-dispatch-index-mark [dispatch : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (if (and
    compiler-parse-dispatch-index-ready
    (compiler-parse-dispatch-index-current?))
    (sym_i64_env.sym-i64-bind-id
      dispatch
      compiler-parse-dispatch-index-marker-id
      (compiler-parse-tag-decl-defdispatch))
    dispatch))

(define (compiler-parse-dispatch-index-lookup-id [name-id : i64]) : i64
  (let
    [encoded : i64 (+ name-id 1)]
    [slot : i64 (bit-and name-id (- compiler-parse-dispatch-index-capacity 1))]
    [steps : i64 0]
    (begin
      (while (< steps compiler-parse-dispatch-index-capacity)
        (let
          [present : i64 (array-ref compiler-parse-dispatch-index-keys slot)]
          (cond
            [(= present 0) (return (compiler-parse-tag-unknown))]
            [(= present encoded)
              (return (array-ref compiler-parse-dispatch-index-tags slot))]
            [else
              (begin
                (set!
                  slot
                  (bit-and
                    (+ slot 1)
                    (- compiler-parse-dispatch-index-capacity 1)))
                (set! steps (+ steps 1)))])))
      (compiler-parse-tag-unknown))))

(define (compiler-parse-dispatch-binops [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [e1 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e "+" (compiler-parse-tag-bin-add))]
    [e2 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e1 "-" (compiler-parse-tag-bin-sub))]
    [e3 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e2 "*" (compiler-parse-tag-bin-mul))]
    [e4 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e3 "/" (compiler-parse-tag-bin-div))]
    [e5 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e4 "%" (compiler-parse-tag-bin-mod))]
    [e6 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e5 "=" (compiler-parse-tag-bin-eq))]
    [e7 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e6 "!=" (compiler-parse-tag-bin-ne))]
    [e8 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e7 "<" (compiler-parse-tag-bin-lt))]
    [e9 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e8 "<=" (compiler-parse-tag-bin-le))]
    [e10 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e9 ">" (compiler-parse-tag-bin-gt))]
    [e11 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e10 ">=" (compiler-parse-tag-bin-ge))]
    [e12 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e11 "bit-and" (compiler-parse-tag-bin-bit-and))]
    [e13 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e12 "bit-or" (compiler-parse-tag-bin-bit-or))]
    [e14 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e13 "bit-xor" (compiler-parse-tag-bin-bit-xor))]
    [e15 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e14 "shl" (compiler-parse-tag-bin-shl))]
    (sym_i64_env.sym-i64-bind e15 "shr" (compiler-parse-tag-bin-shr))))

(define (compiler-parse-dispatch-unops [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [e1 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e "not" (compiler-parse-tag-un-not))]
    [e2 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e1 "neg" (compiler-parse-tag-un-neg))]
    (sym_i64_env.sym-i64-bind e2 "bit-not" (compiler-parse-tag-un-bit-not))))

(define (compiler-parse-dispatch-types [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [out : sym_i64_env.SymI64Env e]
    (begin
      (set!
        out
        (sym_i64_env.sym-i64-bind out "i64" (compiler-parse-tag-ty-i64)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "i32" (compiler-parse-tag-ty-i32)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "i16" (compiler-parse-tag-ty-i16)))
      (set! out (sym_i64_env.sym-i64-bind out "i8" (compiler-parse-tag-ty-i8)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "u64" (compiler-parse-tag-ty-u64)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "u32" (compiler-parse-tag-ty-u32)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "u16" (compiler-parse-tag-ty-u16)))
      (set! out (sym_i64_env.sym-i64-bind out "u8" (compiler-parse-tag-ty-u8)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "f64" (compiler-parse-tag-ty-f64)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "f32" (compiler-parse-tag-ty-f32)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "bool" (compiler-parse-tag-ty-bool)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "char" (compiler-parse-tag-ty-char)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "String" (compiler-parse-tag-ty-string)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "str" (compiler-parse-tag-ty-str)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "bytes" (compiler-parse-tag-ty-bytes)))
      (set! out (sym_i64_env.sym-i64-bind out "unit" (compiler-parse-tag-unit)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "never" (compiler-parse-tag-ty-never)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "->" (compiler-parse-tag-ty-func)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "Tuple" (compiler-parse-tag-ty-tuple)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "Array" (compiler-parse-tag-ty-array)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "in" (compiler-parse-tag-ty-region)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "Ptr" (compiler-parse-tag-ty-ptr)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "MutPtr" (compiler-parse-tag-ty-mut-ptr)))
      (set! out (sym_i64_env.sym-i64-bind out "&" (compiler-parse-tag-ty-ref)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "&mut" (compiler-parse-tag-ty-mut-ref)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "Box" (compiler-parse-tag-ty-box)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "__tl_dyn-array"
          (compiler-parse-tag-ty-dyn-array)))
      out)))

(define (compiler-parse-dispatch-private-types [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [indexed : bool (compiler-parse-dispatch-indexed? e)]
    [out : sym_i64_env.SymI64Env (compiler-cfg-enable-private-dynamic-buffer e)]
    (if indexed
      (compiler-parse-dispatch-index-mark out)
      out)))

(define (compiler-parse-dispatch-exprs [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [out : sym_i64_env.SymI64Env e]
    (begin
      (set!
        out
        (sym_i64_env.sym-i64-bind out "if" (compiler-parse-tag-expr-if)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "let" (compiler-parse-tag-expr-let)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "lambda" (compiler-parse-tag-expr-lambda)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "while" (compiler-parse-tag-expr-while)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "begin" (compiler-parse-tag-expr-begin)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "unsafe" (compiler-parse-tag-expr-unsafe)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "set!" (compiler-parse-tag-expr-set)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "ann" (compiler-parse-tag-expr-ann)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "cast" (compiler-parse-tag-expr-cast)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "tuple" (compiler-parse-tag-expr-tuple)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "tuple-ref"
          (compiler-parse-tag-expr-tuple-ref)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "array" (compiler-parse-tag-expr-array)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "make-array"
          (compiler-parse-tag-expr-make-array)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "__tl_make-array"
          (compiler-parse-tag-expr-make-array)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "array-ref"
          (compiler-parse-tag-expr-array-ref)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "__tl_array-ref"
          (compiler-parse-tag-expr-array-ref)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "array-set!"
          (compiler-parse-tag-expr-array-set)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "__tl_array-set!"
          (compiler-parse-tag-expr-array-set)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "array-push!"
          (compiler-parse-tag-expr-array-push)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "__tl_array-push!"
          (compiler-parse-tag-expr-array-push)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "array-take!"
          (compiler-parse-tag-expr-array-take)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "__tl_array-take!"
          (compiler-parse-tag-expr-array-take)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "match" (compiler-parse-tag-expr-match)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "foreach"
          (compiler-parse-tag-expr-foreach)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "spmd-reduce"
          (compiler-parse-tag-expr-spmd-reduce)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "spmd-scan"
          (compiler-parse-tag-expr-spmd-scan)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "spmd-broadcast"
          (compiler-parse-tag-expr-spmd-broadcast)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "spmd-shuffle"
          (compiler-parse-tag-expr-spmd-shuffle)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "program-index"
          (compiler-parse-tag-expr-spmd-program-index)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "program-count"
          (compiler-parse-tag-expr-spmd-program-count)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "struct-get"
          (compiler-parse-tag-expr-struct-get)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "comptime"
          (compiler-parse-tag-expr-comptime)))
      ;; `with-arena` is the canonical scoped-arena spelling.
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "with-arena"
          (compiler-parse-tag-expr-with-region)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "with-escape"
          (compiler-parse-tag-expr-with-escape)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "with-scratch"
          (compiler-parse-tag-expr-with-scratch)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "in-arena"
          (compiler-parse-tag-expr-in-arena)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "type"
          (compiler-parse-tag-expr-type-literal)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "init" (compiler-parse-tag-expr-init)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "try" (compiler-parse-tag-expr-try)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "return" (compiler-parse-tag-expr-return)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "break" (compiler-parse-tag-expr-break)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "continue"
          (compiler-parse-tag-expr-continue)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "ptr-null"
          (compiler-parse-tag-expr-ptr-null)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "ptr-null?"
          (compiler-parse-tag-expr-ptr-null-check)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "ptr-read"
          (compiler-parse-tag-expr-ptr-read)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "ptr-write!"
          (compiler-parse-tag-expr-ptr-write)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "ptr-offset"
          (compiler-parse-tag-expr-ptr-offset)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "ptr-cast"
          (compiler-parse-tag-expr-ptr-cast)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "ptr->int"
          (compiler-parse-tag-expr-ptr-to-int)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "int->ptr"
          (compiler-parse-tag-expr-int-to-ptr)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "ptr-addr-of"
          (compiler-parse-tag-expr-ptr-addr-of)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "box" (compiler-parse-tag-expr-box)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "box-get"
          (compiler-parse-tag-expr-box-get)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "box-take"
          (compiler-parse-tag-expr-box-take)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "string-data"
          (compiler-parse-tag-expr-string-data)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "string-from-bytes"
          (compiler-parse-tag-expr-string-from-bytes)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "array-data"
          (compiler-parse-tag-expr-array-data)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "program-argc"
          (compiler-parse-tag-expr-program-argc)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "program-argv"
          (compiler-parse-tag-expr-program-argv)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "program-envp"
          (compiler-parse-tag-expr-program-envp)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "cpuid-eax"
          (compiler-parse-tag-expr-cpuid-eax)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "cpuid-ebx"
          (compiler-parse-tag-expr-cpuid-ebx)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "cpuid-ecx"
          (compiler-parse-tag-expr-cpuid-ecx)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "cpuid-edx"
          (compiler-parse-tag-expr-cpuid-edx)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "xgetbv" (compiler-parse-tag-expr-xgetbv)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "syscall"
          (compiler-parse-tag-expr-syscall)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "with"
          (compiler-parse-tag-expr-with-resource)))
      (set!
        out
        (sym_i64_env.sym-i64-bind out "quote" (compiler-parse-tag-expr-quote)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "quasiquote"
          (compiler-parse-tag-expr-quasiquote)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "unquote"
          (compiler-parse-tag-expr-unquote)))
      (set!
        out
        (sym_i64_env.sym-i64-bind
          out
          "unquote-splicing"
          (compiler-parse-tag-expr-unquote-splicing)))
      out)))

(define (compiler-parse-dispatch-patterns [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [e1 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e "true" (compiler-parse-tag-lit-true))]
    [e2 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e1 "false" (compiler-parse-tag-lit-false))]
    (sym_i64_env.sym-i64-bind e2 "_" (compiler-parse-tag-pattern-wildcard))))

(define (compiler-parse-dispatch-decls [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [e1 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e "define" (compiler-parse-tag-decl-define))]
    [e2 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e1 "extern" (compiler-parse-tag-decl-extern))]
    [e3 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e2 "defenum" (compiler-parse-tag-decl-defenum))]
    [e4 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind
        e3
        "defstruct"
        (compiler-parse-tag-decl-defstruct))]
    [e5 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e4 "import" (compiler-parse-tag-decl-import))]
    [e6 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind
        e5
        "comptime-decl"
        (compiler-parse-tag-decl-comptime-decl))]
    [e7 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind
        e6
        "comptime-decls"
        (compiler-parse-tag-decl-comptime-decls))]
    [e8 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e7 "module" (compiler-parse-tag-decl-module))]
    [e9 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind e8 "test" (compiler-parse-tag-decl-test))]
    [e10 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind
        e9
        "defmacro"
        (compiler-parse-tag-decl-defmacro))]
    [e12 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind
        e10
        "include-str"
        (compiler-parse-tag-decl-include-str))]
    [e13 : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind
        e12
        "include-bin"
        (compiler-parse-tag-decl-include-bin))]
    (sym_i64_env.sym-i64-bind
      e13
      "defdispatch"
      (compiler-parse-tag-decl-defdispatch))))

(define (compiler-parse-dispatch-env) : sym_i64_env.SymI64Env
  (let
    [dispatch : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-decls
        (compiler-parse-dispatch-patterns
          (compiler-parse-dispatch-exprs
            (compiler-parse-dispatch-types
              (compiler-parse-dispatch-unops
                (compiler-parse-dispatch-binops (sym_i64_env.sym-i64-empty)))))))]
    (begin
      (compiler-parse-dispatch-index-populate! dispatch)
      dispatch)))

(define (compiler-parse-dispatch-tag
  [dispatch : sym_i64_env.SymI64Env]
  [name : String]) : i64
  (let
    [name-id : i64 (intern name)]
    (if (compiler-parse-dispatch-indexed? dispatch)
      (compiler-parse-dispatch-index-lookup-id name-id)
      (match (sym_i64_env.sym-i64-lookup-id dispatch name-id)
        [(option_i64.Some tag) tag]
        [(option_i64.None) (compiler-parse-tag-unknown)]))))

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

(define (ast-binop? [dispatch : sym_i64_env.SymI64Env] [name : String]) : bool
  (ast-binop-tag? (compiler-parse-dispatch-tag dispatch name)))

(define (ast-left-fold-binop-tag? [tag : i64]) : bool
  (or
    (= tag (compiler-parse-tag-bin-add))
    (= tag (compiler-parse-tag-bin-mul))
    (= tag (compiler-parse-tag-bin-bit-and))
    (= tag (compiler-parse-tag-bin-bit-or))
    (= tag (compiler-parse-tag-bin-bit-xor))))

(define (ast-binop-from-tag [tag : i64]) : AstBinOp
  (cond
    [(= tag (compiler-parse-tag-bin-add)) (AstBinOp.Add)]
    [(= tag (compiler-parse-tag-bin-sub)) (AstBinOp.Sub)]
    [(= tag (compiler-parse-tag-bin-mul)) (AstBinOp.Mul)]
    [(= tag (compiler-parse-tag-bin-div)) (AstBinOp.Div)]
    [(= tag (compiler-parse-tag-bin-mod)) (AstBinOp.Mod)]
    [(= tag (compiler-parse-tag-bin-eq)) (AstBinOp.Eq)]
    [(= tag (compiler-parse-tag-bin-ne)) (AstBinOp.Ne)]
    [(= tag (compiler-parse-tag-bin-lt)) (AstBinOp.Lt)]
    [(= tag (compiler-parse-tag-bin-le)) (AstBinOp.Le)]
    [(= tag (compiler-parse-tag-bin-gt)) (AstBinOp.Gt)]
    [(= tag (compiler-parse-tag-bin-ge)) (AstBinOp.Ge)]
    [(= tag (compiler-parse-tag-bin-bit-and)) (AstBinOp.BitAnd)]
    [(= tag (compiler-parse-tag-bin-bit-or)) (AstBinOp.BitOr)]
    [(= tag (compiler-parse-tag-bin-bit-xor)) (AstBinOp.BitXor)]
    [(= tag (compiler-parse-tag-bin-shl)) (AstBinOp.Shl)]
    [else (AstBinOp.Shr)]))

(define (ast-binop-from-name [dispatch : sym_i64_env.SymI64Env] [name : String]) : AstBinOp
  (ast-binop-from-tag (compiler-parse-dispatch-tag dispatch name)))

(define (ast-unop-tag? [tag : i64]) : bool
  (if (= tag (compiler-parse-tag-un-not))
    true
    (if (= tag (compiler-parse-tag-un-neg))
      true
      (= tag (compiler-parse-tag-un-bit-not)))))

(define (ast-unop? [dispatch : sym_i64_env.SymI64Env] [name : String]) : bool
  (ast-unop-tag? (compiler-parse-dispatch-tag dispatch name)))

(define (ast-unop-from-tag [tag : i64]) : AstUnOp
  (if (= tag (compiler-parse-tag-un-not))
    (AstUnOp.Not)
    (if (= tag (compiler-parse-tag-un-neg))
      (AstUnOp.Neg)
      (AstUnOp.BitNot))))

(define (ast-unop-from-name [dispatch : sym_i64_env.SymI64Env] [name : String]) : AstUnOp
  (ast-unop-from-tag (compiler-parse-dispatch-tag dispatch name)))

(define (parse-ast-type-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [out : (&mut out AstTypeList)]) : ResultAstTypeListBuild
  (match s
    [(Sexpr.Nil) (ResultAstTypeListBuild.Ok)]
    [(Sexpr.Cons head tail)
      (match (parse-ast-type dispatch pools (box-get head))
        [(ResultAstType.Ok parsed-head)
          (begin
            (ast-type-list-push
              out
              (ast-node-pool-context-type-push pools parsed-head))
            (parse-ast-type-list dispatch pools (box-get tail) out))]
        [(ResultAstType.Err message) (ResultAstTypeListBuild.Err message)])]
    [_ (ResultAstTypeListBuild.Err "parse: malformed type list")]))

(define (parse-ast-type-list-result
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]) : ResultAstTypeList
  (let
    [out : AstTypeList (ast-type-list-new)]
    (match (parse-ast-type-list dispatch pools s (&mut out))
      [(ResultAstTypeListBuild.Ok) (ResultAstTypeList.Ok out)]
      [(ResultAstTypeListBuild.Err message) (ResultAstTypeList.Err message)])))

(define (parse-ast-lifetime-name?
  [dispatch : sym_i64_env.SymI64Env]
  [name : String]) : bool
  (let
    [tag : i64 (compiler-parse-dispatch-tag dispatch name)]
    (not
      (or
        (and
          (>= tag (compiler-parse-tag-ty-i64))
          (<= tag (compiler-parse-tag-ty-bytes)))
        (and
          (>= tag (compiler-parse-tag-ty-func))
          (<= tag (compiler-parse-tag-ty-dyn-array)))))))

(define (parse-ast-lifetime-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [message : String]
  [out : (&mut out AstLifetimeList)]) : ResultAstLifetimeListBuild
  (match s
    [(Sexpr.Nil) (ResultAstLifetimeListBuild.Ok)]
    [(Sexpr.Cons head tail)
      (match (box-get head)
        [(Sexpr.Sym name)
          (if (parse-ast-lifetime-name? dispatch name)
            (begin
              (ast-lifetime-list-push out name)
              (parse-ast-lifetime-list
                dispatch
                pools
                (box-get tail)
                message
                out))
            (ResultAstLifetimeListBuild.Err message))]
        [_ (ResultAstLifetimeListBuild.Err message)])]
    [(Sexpr.Cons _ _) (ResultAstLifetimeListBuild.Err message)]
    [_ (ResultAstLifetimeListBuild.Err message)]))

(define (parse-ast-lifetime-list-result
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [message : String]) : ResultAstLifetimeList
  (let
    [out : AstLifetimeList (ast-lifetime-list-new)]
    (match (parse-ast-lifetime-list dispatch pools s message (&mut out))
      [(ResultAstLifetimeListBuild.Ok) (ResultAstLifetimeList.Ok out)]
      [(ResultAstLifetimeListBuild.Err parse-message)
        (ResultAstLifetimeList.Err parse-message)])))

(define (parse-ast-lifetime-list-nonempty
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [message : String]) : ResultAstLifetimeList
  (match s
    [(Sexpr.Nil) (ResultAstLifetimeList.Err message)]
    [_ (parse-ast-lifetime-list-result dispatch pools s message)]))

(define (parse-ast-func-type-parts
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]) : ResultAstFuncTypeParts
  (match s
    [(Sexpr.Cons arg rest)
      (match (box-get rest)
        [(Sexpr.Nil)
          (match (parse-ast-type dispatch pools (box-get arg))
            [(ResultAstType.Ok parsed-ret)
              (ResultAstFuncTypeParts.Ok (ast-type-list-new) parsed-ret)]
            [(ResultAstType.Err message) (ResultAstFuncTypeParts.Err message)])]
        [_
          (match (parse-ast-type dispatch pools (box-get arg))
            [(ResultAstType.Ok parsed-arg)
              (match (parse-ast-func-type-parts dispatch pools (box-get rest))
                [(ResultAstFuncTypeParts.Ok parsed-args parsed-ret)
                  (ResultAstFuncTypeParts.Ok
                    (ast-type-cons-with-pools pools parsed-arg parsed-args)
                    parsed-ret)]
                [(ResultAstFuncTypeParts.Err message)
                  (ResultAstFuncTypeParts.Err message)])]
            [(ResultAstType.Err message) (ResultAstFuncTypeParts.Err message)])])]
    [_
      (ResultAstFuncTypeParts.Err
        "parse: function type needs at least return type")]))

;; Macro output uses these non-lexer-spellable symbols to carry already-resolved
;; aggregate type operands through declaration-shaped quasiquote output.
(define (parse-internal-resolved-struct-type-marker) : String
  "__typelisp internal resolved struct type")

(define (parse-internal-resolved-enum-type-marker) : String
  "__typelisp internal resolved enum type")

(define (parse-ast-resolved-nominal-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : Sexpr]
  [is-struct : bool]) : ResultAstType
  (match rest
    [(Sexpr.Cons name-node lifetimes-box)
      (match (box-get name-node)
        [(Sexpr.Str name)
          (match (parse-ast-lifetime-list-result
            dispatch
            pools
            (box-get lifetimes-box)
            "parse: malformed internal resolved type")
            [(ResultAstLifetimeList.Ok lifetimes)
              (ResultAstType.Ok
                (if is-struct
                  (if (ast-lifetime-list-empty? (& lifetimes))
                    (AstType.Struct (intern name))
                    (ast-ty-struct-args (intern name) lifetimes))
                  (if (ast-lifetime-list-empty? (& lifetimes))
                    (AstType.Enum (intern name))
                    (ast-ty-enum-args (intern name) lifetimes))))]
            [(ResultAstLifetimeList.Err message) (ResultAstType.Err message)])]
        [_ (ResultAstType.Err "parse: malformed internal resolved type")])]
    [_ (ResultAstType.Err "parse: malformed internal resolved type")]))

(define (parse-ast-reference-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : Sexpr]
  [mutable : bool]) : ResultAstType
  (match rest
    [(Sexpr.Cons first tail)
      (match (box-get tail)
        ;; The parser is context-free. An empty lifetime marker is legal in
        ;; the AST, but the typechecker only accepts it while normalizing a
        ;; function signature into hidden signature-local lifetimes.
        [(Sexpr.Nil)
          (match (parse-ast-type dispatch pools (box-get first))
            [(ResultAstType.Ok inner-ty)
              (if mutable
                (ResultAstType.Ok (ast-ty-mut-ref-with-pools pools "" inner-ty))
                (ResultAstType.Ok (ast-ty-ref-with-pools pools "" inner-ty)))]
            [(ResultAstType.Err message) (ResultAstType.Err message)])]
        [(Sexpr.Cons inner end)
          (match (box-get end)
            [(Sexpr.Nil)
              (match (box-get first)
                [(Sexpr.Sym region)
                  (match (parse-ast-type dispatch pools (box-get inner))
                    [(ResultAstType.Ok inner-ty)
                      (if mutable
                        (ResultAstType.Ok
                          (ast-ty-mut-ref-with-pools pools region inner-ty))
                        (ResultAstType.Ok
                          (ast-ty-ref-with-pools pools region inner-ty)))]
                    [(ResultAstType.Err message) (ResultAstType.Err message)])]
                [_
                  (ResultAstType.Err
                    "parse: reference lifetime must be an identifier")])]
            [_
              (ResultAstType.Err
                (if mutable
                  "parse: &mut expects an optional lifetime and exactly one type"
                  "parse: & expects an optional lifetime and exactly one type"))])]
        [_
          (ResultAstType.Err
            (if mutable
              "parse: &mut expects an optional lifetime and exactly one type"
              "parse: & expects an optional lifetime and exactly one type"))])]
    [_
      (ResultAstType.Err
        (if mutable
          "parse: &mut expects an optional lifetime and exactly one type"
          "parse: & expects an optional lifetime and exactly one type"))]))

(define (parse-ast-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]) : ResultAstType
  (match s
    [(Sexpr.Sym name)
      (let
        [tag : i64 (compiler-parse-dispatch-tag dispatch name)]
        (cond
          [(= tag (compiler-parse-tag-ty-i64)) (ResultAstType.Ok (AstType.I64))]
          [(= tag (compiler-parse-tag-ty-i32)) (ResultAstType.Ok (AstType.I32))]
          [(= tag (compiler-parse-tag-ty-i16)) (ResultAstType.Ok (AstType.I16))]
          [(= tag (compiler-parse-tag-ty-i8)) (ResultAstType.Ok (AstType.I8))]
          [(= tag (compiler-parse-tag-ty-u64)) (ResultAstType.Ok (AstType.U64))]
          [(= tag (compiler-parse-tag-ty-u32)) (ResultAstType.Ok (AstType.U32))]
          [(= tag (compiler-parse-tag-ty-u16)) (ResultAstType.Ok (AstType.U16))]
          [(= tag (compiler-parse-tag-ty-u8)) (ResultAstType.Ok (AstType.U8))]
          [(= tag (compiler-parse-tag-ty-f64)) (ResultAstType.Ok (AstType.F64))]
          [(= tag (compiler-parse-tag-ty-f32)) (ResultAstType.Ok (AstType.F32))]
          [(= tag (compiler-parse-tag-ty-bool))
            (ResultAstType.Ok (AstType.Bool))]
          [(= tag (compiler-parse-tag-ty-char))
            (ResultAstType.Ok (AstType.Char))]
          [(= tag (compiler-parse-tag-ty-string))
            (ResultAstType.Ok (AstType.String))]
          [(= tag (compiler-parse-tag-ty-str)) (ResultAstType.Ok (AstType.Str))]
          [(= tag (compiler-parse-tag-ty-bytes))
            (ResultAstType.Ok (AstType.Bytes))]
          [(= tag (compiler-parse-tag-unit)) (ResultAstType.Ok (AstType.Unit))]
          [(= tag (compiler-parse-tag-ty-never))
            (ResultAstType.Ok (AstType.Never))]
          [(= tag (compiler-parse-tag-ty-expr))
            (ResultAstType.Ok (AstType.Expr))]
          [else (ResultAstType.Ok (AstType.Var (intern name)))]))]
    [(Sexpr.Cons head-node rest-box)
      (match (box-get head-node)
        [(Sexpr.Sym head)
          (let
            [rest : Sexpr (box-get rest-box)]
            [tag : i64 (compiler-parse-dispatch-tag dispatch head)]
            (cond
              [(string.eq head (parse-internal-resolved-struct-type-marker))
                (parse-ast-resolved-nominal-type dispatch pools rest true)]
              [(string.eq head (parse-internal-resolved-enum-type-marker))
                (parse-ast-resolved-nominal-type dispatch pools rest false)]
              [(= tag (compiler-parse-tag-ty-func))
                (match (parse-ast-func-type-parts dispatch pools rest)
                  [(ResultAstFuncTypeParts.Ok args ret)
                    (ResultAstType.Ok (ast-ty-func-with-pools pools args ret))]
                  [(ResultAstFuncTypeParts.Err message)
                    (ResultAstType.Err message)])]
              [(= tag (compiler-parse-tag-ty-tuple))
                (match (parse-ast-type-list-result dispatch pools rest)
                  [(ResultAstTypeList.Ok elems)
                    (ResultAstType.Ok (ast-ty-tuple elems))]
                  [(ResultAstTypeList.Err message) (ResultAstType.Err message)])]
              [(= tag (compiler-parse-tag-ty-array))
                (match rest
                  [(Sexpr.Cons elem tail)
                    (match (box-get tail)
                      [(Sexpr.Nil)
                        (match (parse-ast-type dispatch pools (box-get elem))
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast-ty-dyn-array-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [(Sexpr.Cons size-node end)
                        (match (box-get end)
                          [(Sexpr.Nil)
                            (match (box-get size-node)
                              [(Sexpr.Int size _)
                                (match (parse-ast-type
                                  dispatch
                                  pools
                                  (box-get elem))
                                  [(ResultAstType.Ok elem-ty)
                                    (ResultAstType.Ok
                                      (ast-ty-array-with-pools
                                        pools
                                        elem-ty
                                        size))]
                                  [(ResultAstType.Err message)
                                    (ResultAstType.Err message)])]
                              [_
                                (ResultAstType.Err
                                  "parse: array size must be integer")])]
                          [_ (ResultAstType.Err "parse: malformed array type")])]
                      [_ (ResultAstType.Err "parse: malformed array type")])]
                  [_ (ResultAstType.Err "parse: malformed array type")])]
              [(= tag (compiler-parse-tag-ty-dyn-array))
                (if (not
                  (compiler-cfg-private-dynamic-buffer-enabled? dispatch))
                  (ResultAstType.Err
                    (compiler-parse-generic-type-policy-message
                      "__tl_dyn-array"))
                  (match rest
                    [(Sexpr.Cons elem tail)
                      (match (box-get tail)
                        [(Sexpr.Nil)
                          (match (parse-ast-type dispatch pools (box-get elem))
                            [(ResultAstType.Ok elem-ty)
                              (ResultAstType.Ok
                                (ast-ty-dyn-array-with-pools pools elem-ty))]
                            [(ResultAstType.Err message)
                              (ResultAstType.Err message)])]
                        [_
                          (ResultAstType.Err
                            "parse: __tl_dyn-array expects exactly one type")])]
                    [_
                      (ResultAstType.Err
                        "parse: __tl_dyn-array expects exactly one type")]))]
              [(= tag (compiler-parse-tag-ty-ptr))
                (match rest
                  [(Sexpr.Cons elem tail)
                    (match (box-get tail)
                      [(Sexpr.Nil)
                        (match (parse-ast-type dispatch pools (box-get elem))
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast-ty-ptr-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [_
                        (ResultAstType.Err
                          "parse: Ptr expects exactly one type")])]
                  [_ (ResultAstType.Err "parse: Ptr expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-mut-ptr))
                (match rest
                  [(Sexpr.Cons elem tail)
                    (match (box-get tail)
                      [(Sexpr.Nil)
                        (match (parse-ast-type dispatch pools (box-get elem))
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast-ty-mut-ptr-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [_
                        (ResultAstType.Err
                          "parse: MutPtr expects exactly one type")])]
                  [_
                    (ResultAstType.Err "parse: MutPtr expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-box))
                (match rest
                  [(Sexpr.Cons elem tail)
                    (match (box-get tail)
                      [(Sexpr.Nil)
                        (match (parse-ast-type dispatch pools (box-get elem))
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast-ty-box-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [_
                        (ResultAstType.Err
                          "parse: Box expects exactly one type")])]
                  [_ (ResultAstType.Err "parse: Box expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-ref))
                (parse-ast-reference-type dispatch pools rest false)]
              [(= tag (compiler-parse-tag-ty-mut-ref))
                (parse-ast-reference-type dispatch pools rest true)]
              [(= tag (compiler-parse-tag-ty-region))
                (match rest
                  [(Sexpr.Cons region-node tail)
                    (match (box-get tail)
                      [(Sexpr.Cons inner end)
                        (match (box-get end)
                          [(Sexpr.Nil)
                            (match (box-get region-node)
                              [(Sexpr.Sym region)
                                (match (parse-ast-type
                                  dispatch
                                  pools
                                  (box-get inner))
                                  [(ResultAstType.Ok inner-ty)
                                    (ResultAstType.Ok
                                      (ast-ty-region-with-pools
                                        pools
                                        region
                                        inner-ty))]
                                  [(ResultAstType.Err message)
                                    (ResultAstType.Err message)])]
                              [_
                                (ResultAstType.Err
                                  "parse: region name must be an identifier")])]
                          [_ (ResultAstType.Err "parse: malformed region type")])]
                      [_ (ResultAstType.Err "parse: malformed region type")])]
                  [_ (ResultAstType.Err "parse: malformed region type")])]
              [else
                (match (parse-ast-lifetime-list-nonempty
                  dispatch
                  pools
                  rest
                  (compiler-parse-generic-type-policy-message head))
                  [(ResultAstLifetimeList.Ok lifetimes)
                    (ResultAstType.Ok (ast-ty-var-args (intern head) lifetimes))]
                  [(ResultAstLifetimeList.Err message)
                    (ResultAstType.Err message)])]))]
        [_ (ResultAstType.Err "parse: expected type")])]
    [_ (ResultAstType.Err "parse: expected type")]))

(define (parse-ast-type-spanned
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]) : ResultAstType
  (let
    [result : ResultAstType
      (parse-ast-type dispatch pools (spanned-sexpr-form s))]
    (match result
      [(ResultAstType.Err _)
        (begin
          (parse-ast-error-span-note! (spanned-sexpr-span s))
          result)]
      [_ result])))

(define (parse-ast-param
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]) : ResultAstParam
  (match s
    [(Sexpr.Cons first rest)
      (match (box-get first)
        [(Sexpr.Sym first-name)
          (if (string.eq first-name "comptime")
            (match (box-get rest)
              [(Sexpr.Cons name-node after-name)
                (match (box-get name-node)
                  [(Sexpr.Sym name)
                    (match (box-get after-name)
                      [(Sexpr.Cons colon rest2)
                        (match (box-get rest2)
                          [(Sexpr.Cons ty end)
                            (match (box-get end)
                              [(Sexpr.Nil)
                                (if (sexpr-colon? (box-get colon))
                                  (match (parse-ast-type
                                    dispatch
                                    pools
                                    (box-get ty))
                                    [(ResultAstType.Ok parsed-ty)
                                      (ResultAstParam.Ok
                                        (ast-param name parsed-ty true))]
                                    [(ResultAstType.Err message)
                                      (ResultAstParam.Err message)])
                                  (ResultAstParam.Err
                                    "parse: expected ':' in parameter"))]
                              [_
                                (ResultAstParam.Err
                                  "parse: malformed parameter")])]
                          [_ (ResultAstParam.Err "parse: malformed parameter")])]
                      [_ (ResultAstParam.Err "parse: malformed parameter")])]
                  [_ (ResultAstParam.Err "parse: malformed parameter")])]
              [_ (ResultAstParam.Err "parse: malformed parameter")])
            (match (box-get rest)
              [(Sexpr.Cons colon rest2)
                (match (box-get rest2)
                  [(Sexpr.Cons ty end)
                    (match (box-get end)
                      [(Sexpr.Nil)
                        (if (sexpr-colon? (box-get colon))
                          (match (parse-ast-type dispatch pools (box-get ty))
                            [(ResultAstType.Ok parsed-ty)
                              (ResultAstParam.Ok
                                (ast-param first-name parsed-ty false))]
                            [(ResultAstType.Err message)
                              (ResultAstParam.Err message)])
                          (ResultAstParam.Err
                            "parse: expected ':' in parameter"))]
                      [_ (ResultAstParam.Err "parse: malformed parameter")])]
                  [_ (ResultAstParam.Err "parse: malformed parameter")])]
              [_ (ResultAstParam.Err "parse: malformed parameter")]))]
        [_ (ResultAstParam.Err "parse: malformed parameter")])]
    [_ (ResultAstParam.Err "parse: malformed parameter")]))

(define (ast-param-list-has-comptime? [params : AstParamList]) : bool
  (ast-param-list-has-comptime-at? (& params) 0))

(define (ast-param-list-has-comptime-at?
  [params : (& params AstParamList)]
  [index : i64]) : bool
  (if (>= index (ast-param-list-len params))
    false
    (match (ast-param-list-get params index (ast-param-fallback))
      [(AstParam.Param _ _ is-comptime)
        (if is-comptime
          true
          (ast-param-list-has-comptime-at? params (+ index 1)))])))

(define (ast-macro-param-variadic? [param : AstMacroParam]) : bool
  (match param
    [(AstMacroParam.Param _ _ variadic) variadic]))

(define (parse-ast-macro-param
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]) : ResultAstMacroParam
  (match s
    [(Sexpr.Cons name-node rest)
      (match (box-get name-node)
        [(Sexpr.Sym name)
          (if (string.eq name "comptime")
            (ResultAstMacroParam.Err
              "parse: defmacro operands are already compile-time")
            (match (box-get rest)
              [(Sexpr.Cons colon rest2)
                (match (box-get rest2)
                  [(Sexpr.Cons ty rest3)
                    (if (sexpr-colon? (box-get colon))
                      (match (box-get rest3)
                        [(Sexpr.Nil)
                          (match (parse-ast-type dispatch pools (box-get ty))
                            [(ResultAstType.Ok parsed-ty)
                              (ResultAstMacroParam.Ok
                                (ast-macro-param name parsed-ty false))]
                            [(ResultAstType.Err message)
                              (ResultAstMacroParam.Err message)])]
                        [(Sexpr.Cons dots end)
                          (match (box-get end)
                            [(Sexpr.Nil)
                              (match (box-get dots)
                                [(Sexpr.Sym dots-name)
                                  (if (string.eq dots-name "...")
                                    (match (parse-ast-type
                                      dispatch
                                      pools
                                      (box-get ty))
                                      [(ResultAstType.Ok parsed-ty)
                                        (ResultAstMacroParam.Ok
                                          (ast-macro-param name parsed-ty true))]
                                      [(ResultAstType.Err message)
                                        (ResultAstMacroParam.Err message)])
                                    (ResultAstMacroParam.Err
                                      "parse: malformed macro operand"))]
                                [_
                                  (ResultAstMacroParam.Err
                                    "parse: malformed macro operand")])]
                            [_
                              (ResultAstMacroParam.Err
                                "parse: malformed macro operand")])]
                        [_
                          (ResultAstMacroParam.Err
                            "parse: malformed macro operand")])
                      (ResultAstMacroParam.Err
                        "parse: expected ':' in macro operand"))]
                  [_ (ResultAstMacroParam.Err "parse: malformed macro operand")])]
              [_ (ResultAstMacroParam.Err "parse: malformed macro operand")]))]
        [_ (ResultAstMacroParam.Err "parse: malformed macro operand")])]
    [_ (ResultAstMacroParam.Err "parse: malformed macro operand")]))

(define (parse-ast-macro-param-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]) : ResultAstMacroParamList
  (let
    [out : AstMacroParamList (ast-macro-param-list-new)]
    (match (parse-ast-macro-param-list-into dispatch pools s (&mut out))
      [(ResultAstMacroParamListBuild.Ok) (ResultAstMacroParamList.Ok out)]
      [(ResultAstMacroParamListBuild.Err message)
        (ResultAstMacroParamList.Err message)])))

(define (parse-ast-macro-param-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [out : (&mut out AstMacroParamList)]) : ResultAstMacroParamListBuild
  (match s
    [(Sexpr.Nil) ResultAstMacroParamListBuild.Ok]
    [(Sexpr.Cons head tail)
      (match (parse-ast-macro-param dispatch pools (box-get head))
        [(ResultAstMacroParam.Ok parsed-head)
          (if (ast-macro-param-variadic? parsed-head)
            (match (box-get tail)
              [(Sexpr.Nil)
                (begin
                  (ast-macro-param-list-push out parsed-head)
                  ResultAstMacroParamListBuild.Ok)]
              [_
                (ResultAstMacroParamListBuild.Err
                  "parse: variadic macro operand must be final")])
            (begin
              (ast-macro-param-list-push out parsed-head)
              (parse-ast-macro-param-list-into
                dispatch
                pools
                (box-get tail)
                out)))]
        [(ResultAstMacroParam.Err message)
          (ResultAstMacroParamListBuild.Err message)])]
    [_ (ResultAstMacroParamListBuild.Err "parse: malformed macro operand list")]))

(define (parse-ast-param-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]) : ResultAstParamList
  (let
    [out : AstParamList (ast-param-list-new)]
    (match (parse-ast-param-list-into dispatch pools s (&mut out))
      [(ResultAstParamListBuild.Ok) (ResultAstParamList.Ok out)]
      [(ResultAstParamListBuild.Err message) (ResultAstParamList.Err message)])))

(define (parse-ast-param-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [out : (&mut out AstParamList)]) : ResultAstParamListBuild
  (match s
    [(Sexpr.Nil) ResultAstParamListBuild.Ok]
    [(Sexpr.Cons head tail)
      (match (parse-ast-param dispatch pools (box-get head))
        [(ResultAstParam.Ok parsed-head)
          (begin
            (ast-param-list-push out parsed-head)
            (parse-ast-param-list-into dispatch pools (box-get tail) out))]
        [(ResultAstParam.Err message) (ResultAstParamListBuild.Err message)])]
    [_ (ResultAstParamListBuild.Err "parse: malformed parameter list")]))

(define (parse-ast-field-cleanup [s : Sexpr]) : ResultAstFieldCleanup
  (match s
    [(Sexpr.Cons key-node tail)
      (match (box-get key-node)
        [(Sexpr.Sym key)
          (cond
            [(string.eq key ":cleanup")
              (match (box-get tail)
                [(Sexpr.Cons cleanup-node end)
                  (match (box-get end)
                    [(Sexpr.Nil)
                      (match (box-get cleanup-node)
                        [(Sexpr.Sym cleanup-fn)
                          (ResultAstFieldCleanup.Ok
                            (ast-field-cleanup-fn cleanup-fn))]
                        [_
                          (ResultAstFieldCleanup.Err
                            "parse: malformed field :cleanup metadata")])]
                    [_
                      (ResultAstFieldCleanup.Err
                        "parse: malformed field :cleanup metadata")])]
                [_
                  (ResultAstFieldCleanup.Err
                    "parse: malformed field :cleanup metadata")])]
            [(string.eq key ":owned")
              (match (box-get tail)
                [(Sexpr.Nil) (ResultAstFieldCleanup.Ok (AstFieldCleanup.Owned))]
                [_
                  (ResultAstFieldCleanup.Err
                    "parse: malformed field :owned metadata")])]
            [(compiler-parse-metadata-key? key)
              (ResultAstFieldCleanup.Err
                (string.append "parse: unknown field metadata " key))]
            [else
              (ResultAstFieldCleanup.Err
                "parse: malformed field cleanup metadata")])]
        [_
          (ResultAstFieldCleanup.Err "parse: malformed field cleanup metadata")])]
    [_ (ResultAstFieldCleanup.Err "parse: malformed field cleanup metadata")]))

(define (parse-ast-variant-payload-cleanup [s : Sexpr]) : ResultAstVariantPayloadCleanup
  (match s
    [(Sexpr.Cons key-node tail)
      (match (box-get key-node)
        [(Sexpr.Sym key)
          (cond
            [(string.eq key ":cleanup")
              (match (box-get tail)
                [(Sexpr.Cons cleanup-node end)
                  (match (box-get end)
                    [(Sexpr.Nil)
                      (match (box-get cleanup-node)
                        [(Sexpr.Sym cleanup-fn)
                          (ResultAstVariantPayloadCleanup.Ok
                            (ast-variant-payload-cleanup-fn cleanup-fn))]
                        [_
                          (ResultAstVariantPayloadCleanup.Err
                            "parse: malformed enum payload :cleanup metadata")])]
                    [_
                      (ResultAstVariantPayloadCleanup.Err
                        "parse: malformed enum payload :cleanup metadata")])]
                [_
                  (ResultAstVariantPayloadCleanup.Err
                    "parse: malformed enum payload :cleanup metadata")])]
            [(string.eq key ":owned")
              (match (box-get tail)
                [(Sexpr.Nil)
                  (ResultAstVariantPayloadCleanup.Ok
                    (AstVariantPayloadCleanup.Owned))]
                [_
                  (ResultAstVariantPayloadCleanup.Err
                    "parse: malformed enum payload :owned metadata")])]
            [(compiler-parse-metadata-key? key)
              (ResultAstVariantPayloadCleanup.Err
                (string.append "parse: unknown enum payload metadata " key))]
            [else
              (ResultAstVariantPayloadCleanup.Err
                "parse: malformed enum payload cleanup metadata")])]
        [_
          (ResultAstVariantPayloadCleanup.Err
            "parse: malformed enum payload cleanup metadata")])]
    [_
      (ResultAstVariantPayloadCleanup.Err
        "parse: malformed enum payload cleanup metadata")]))

(define (parse-ast-field-def
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [allow-cleanup : bool]) : ResultAstFieldDef
  (match s
    [(Sexpr.Cons name-node tail)
      (match (box-get name-node)
        [(Sexpr.Sym name)
          (match (box-get tail)
            [(Sexpr.Cons ty rest)
              (match (box-get rest)
                [(Sexpr.Nil)
                  (match (parse-ast-type dispatch pools (box-get ty))
                    [(ResultAstType.Ok parsed-ty)
                      (ResultAstFieldDef.Ok
                        (ast-field-def name parsed-ty (AstFieldCleanup.No)))]
                    [(ResultAstType.Err message)
                      (ResultAstFieldDef.Err message)])]
                [(Sexpr.Cons cleanup-meta extra)
                  (match (box-get extra)
                    [(Sexpr.Nil)
                      (if allow-cleanup
                        (match (parse-ast-type dispatch pools (box-get ty))
                          [(ResultAstType.Ok parsed-ty)
                            (match (parse-ast-field-cleanup
                              (box-get cleanup-meta))
                              [(ResultAstFieldCleanup.Ok parsed-cleanup)
                                (ResultAstFieldDef.Ok
                                  (ast-field-def name parsed-ty parsed-cleanup))]
                              [(ResultAstFieldCleanup.Err message)
                                (ResultAstFieldDef.Err message)])]
                          [(ResultAstType.Err message)
                            (ResultAstFieldDef.Err message)])
                        (ResultAstFieldDef.Err
                          "parse: field cleanup metadata requires struct :cleanup metadata"))]
                    [_
                      (ResultAstFieldDef.Err
                        "parse: duplicate field cleanup metadata")])]
                [_ (ResultAstFieldDef.Err "parse: malformed field definition")])]
            [_ (ResultAstFieldDef.Err "parse: malformed field definition")])]
        [_ (ResultAstFieldDef.Err "parse: malformed field definition")])]
    [_ (ResultAstFieldDef.Err "parse: malformed field definition")]))

(define (parse-ast-field-def-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [allow-cleanup : bool]
  [out : (&mut out AstFieldDefList)]) : ResultAstFieldDefListBuild
  (match s
    [(Sexpr.Nil) (ResultAstFieldDefListBuild.Ok)]
    [(Sexpr.Cons head tail)
      (match (parse-ast-field-def dispatch pools (box-get head) allow-cleanup)
        [(ResultAstFieldDef.Ok parsed-head)
          (begin
            (ast-field-def-list-push out parsed-head)
            (parse-ast-field-def-list-into
              dispatch
              pools
              (box-get tail)
              allow-cleanup
              out))]
        [(ResultAstFieldDef.Err message)
          (ResultAstFieldDefListBuild.Err message)])]
    [_ (ResultAstFieldDefListBuild.Err "parse: malformed field list")]))

(define (parse-ast-field-def-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [allow-cleanup : bool]) : ResultAstFieldDefList
  (let
    [out : AstFieldDefList (ast-field-def-list-new)]
    (match (parse-ast-field-def-list-into
      dispatch
      pools
      s
      allow-cleanup
      (&mut out))
      [(ResultAstFieldDefListBuild.Ok) (ResultAstFieldDefList.Ok out)]
      [(ResultAstFieldDefListBuild.Err message)
        (ResultAstFieldDefList.Err message)])))

(define (compiler-parse-metadata-key? [name : String]) : bool
  (and (> (string.string-length name) 0) (= (string.string-ref name 0) ':')))

(define (parse-ast-aggregate-lifetimes-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [tail : Sexpr]) : ResultAstLifetimeList
  (parse-ast-lifetime-list-nonempty
    dispatch
    pools
    tail
    "parse: :lifetimes metadata expects at least one lifetime identifier"))

(define (parse-ast-defstruct-repr-tail [tail : Sexpr]) : ResultAstStructRepr
  (match tail
    [(Sexpr.Cons name-node end)
      (match (box-get end)
        [(Sexpr.Nil)
          (match (box-get name-node)
            [(Sexpr.Sym name)
              (if (string.eq name "c")
                (ResultAstStructRepr.Ok (AstStructRepr.C))
                (if (string.eq name "packed")
                  (ResultAstStructRepr.Err "parse: packed repr is reserved")
                  (ResultAstStructRepr.Err
                    (string.append "parse: unknown struct repr " name))))]
            [_ (ResultAstStructRepr.Err "parse: malformed :repr metadata")])]
        [_ (ResultAstStructRepr.Err "parse: malformed :repr metadata")])]
    [_ (ResultAstStructRepr.Err "parse: malformed :repr metadata")]))

(define (parse-ast-defstruct-cleanup-tail [tail : Sexpr]) : ResultAstStructCleanup
  (match tail
    [(Sexpr.Cons cleanup-node end)
      (match (box-get end)
        [(Sexpr.Nil)
          (match (box-get cleanup-node)
            [(Sexpr.Sym cleanup-fn)
              (ResultAstStructCleanup.Ok (ast-struct-cleanup-fn cleanup-fn))]
            [_
              (ResultAstStructCleanup.Err
                "parse: malformed defstruct :cleanup metadata")])]
        [_
          (ResultAstStructCleanup.Err
            "parse: malformed defstruct :cleanup metadata")])]
    [_
      (ResultAstStructCleanup.Err
        "parse: malformed defstruct :cleanup metadata")]))

(define (parse-ast-defenum-cleanup-tail [tail : Sexpr]) : ResultAstEnumCleanup
  (match tail
    [(Sexpr.Cons cleanup-node end)
      (match (box-get end)
        [(Sexpr.Nil)
          (match (box-get cleanup-node)
            [(Sexpr.Sym cleanup-fn)
              (ResultAstEnumCleanup.Ok (ast-enum-cleanup-fn cleanup-fn))]
            [_
              (ResultAstEnumCleanup.Err
                "parse: malformed defenum :cleanup metadata")])]
        [_
          (ResultAstEnumCleanup.Err
            "parse: malformed defenum :cleanup metadata")])]
    [_ (ResultAstEnumCleanup.Err "parse: malformed defenum :cleanup metadata")]))

(define (parse-ast-defstruct-field-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : SpannedSexpr]
  [tail : SpannedSexpr]
  [lifetimes : AstLifetimeList]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]
  [seen-lifetimes : bool]
  [seen-repr : bool]
  [seen-cleanup : bool]) : ResultAstStructDefParts
  (match (parse-ast-field-def
    dispatch
    pools
    (spanned-sexpr-form head)
    (ast-struct-cleanup? cleanup))
    [(ResultAstFieldDef.Ok parsed-field)
      (let
        [next-fields : AstFieldDefList fields]
        (begin
          (ast-field-def-list-push (&mut next-fields) parsed-field)
          (parse-ast-defstruct-items
            dispatch
            pools
            tail
            lifetimes
            repr
            cleanup
            next-fields
            seen-lifetimes
            seen-repr
            seen-cleanup
            true)))]
    [(ResultAstFieldDef.Err message) (ResultAstStructDefParts.Err message)]))

(define (parse-ast-defstruct-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : SpannedSexpr]
  [lifetimes : AstLifetimeList]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]
  [seen-lifetimes : bool]
  [seen-repr : bool]
  [seen-cleanup : bool]
  [seen-field : bool]) : ResultAstStructDefParts
  (match items
    [(SpannedSexpr.Nil _)
      (ResultAstStructDefParts.Ok lifetimes repr cleanup fields)]
    [(SpannedSexpr.Cons head tail _)
      (match (spanned-sexpr-form (sp-node-get head))
        [(Sexpr.Cons key-node after-key)
          (match (box-get key-node)
            [(Sexpr.Sym key)
              (cond
                [(string.eq key ":lifetimes")
                  (if seen-field
                    (ResultAstStructDefParts.Err
                      "parse: defstruct metadata must appear before fields")
                    (if seen-lifetimes
                      (ResultAstStructDefParts.Err
                        "parse: duplicate defstruct :lifetimes metadata")
                      (match (parse-ast-aggregate-lifetimes-tail
                        dispatch
                        pools
                        (box-get after-key))
                        [(ResultAstLifetimeList.Ok next-lifetimes)
                          (parse-ast-defstruct-items
                            dispatch
                            pools
                            (sp-node-get tail)
                            next-lifetimes
                            repr
                            cleanup
                            fields
                            true
                            seen-repr
                            seen-cleanup
                            false)]
                        [(ResultAstLifetimeList.Err message)
                          (ResultAstStructDefParts.Err message)])))]
                [(string.eq key ":repr")
                  (if seen-field
                    (ResultAstStructDefParts.Err
                      "parse: defstruct metadata must appear before fields")
                    (if seen-repr
                      (ResultAstStructDefParts.Err
                        "parse: duplicate defstruct :repr metadata")
                      (match (parse-ast-defstruct-repr-tail (box-get after-key))
                        [(ResultAstStructRepr.Ok next-repr)
                          (if (and
                            (ast-struct-repr-c? next-repr)
                            (ast-struct-cleanup? cleanup))
                            (ResultAstStructDefParts.Err
                              "parse: defstruct cannot combine :repr c with :cleanup metadata")
                            (parse-ast-defstruct-items
                              dispatch
                              pools
                              (sp-node-get tail)
                              lifetimes
                              next-repr
                              cleanup
                              fields
                              seen-lifetimes
                              true
                              seen-cleanup
                              false))]
                        [(ResultAstStructRepr.Err message)
                          (ResultAstStructDefParts.Err message)])))]
                [(string.eq key ":cleanup")
                  (if seen-field
                    (ResultAstStructDefParts.Err
                      "parse: defstruct metadata must appear before fields")
                    (if seen-cleanup
                      (ResultAstStructDefParts.Err
                        "parse: duplicate defstruct :cleanup metadata")
                      (match (parse-ast-defstruct-cleanup-tail
                        (box-get after-key))
                        [(ResultAstStructCleanup.Ok next-cleanup)
                          (if (ast-struct-repr-c? repr)
                            (ResultAstStructDefParts.Err
                              "parse: defstruct cannot combine :repr c with :cleanup metadata")
                            (parse-ast-defstruct-items
                              dispatch
                              pools
                              (sp-node-get tail)
                              lifetimes
                              repr
                              next-cleanup
                              fields
                              seen-lifetimes
                              seen-repr
                              true
                              false))]
                        [(ResultAstStructCleanup.Err message)
                          (ResultAstStructDefParts.Err message)])))]
                [(compiler-parse-metadata-key? key)
                  (if seen-field
                    (ResultAstStructDefParts.Err
                      "parse: defstruct metadata must appear before fields")
                    (if (string.eq key ":packed")
                      (ResultAstStructDefParts.Err
                        "parse: packed repr is reserved")
                      (ResultAstStructDefParts.Err
                        (string.append "parse: unknown defstruct metadata " key))))]
                [else
                  (parse-ast-defstruct-field-item
                    dispatch
                    pools
                    (sp-node-get head)
                    (sp-node-get tail)
                    lifetimes
                    repr
                    cleanup
                    fields
                    seen-lifetimes
                    seen-repr
                    seen-cleanup)])]
            [_
              (parse-ast-defstruct-field-item
                dispatch
                pools
                (sp-node-get head)
                (sp-node-get tail)
                lifetimes
                repr
                cleanup
                fields
                seen-lifetimes
                seen-repr
                seen-cleanup)])]
        [_
          (parse-ast-defstruct-field-item
            dispatch
            pools
            (sp-node-get head)
            (sp-node-get tail)
            lifetimes
            repr
            cleanup
            fields
            seen-lifetimes
            seen-repr
            seen-cleanup)])]
    [_ (ResultAstStructDefParts.Err "parse: malformed field list")]))

(define (compiler-parse-type-list-has-metadata? [s : Sexpr]) : bool
  (match s
    [(Sexpr.Nil) false]
    [(Sexpr.Cons head rest)
      (match (box-get head)
        [(Sexpr.Cons key-node _)
          (match (box-get key-node)
            [(Sexpr.Sym key)
              (if (compiler-parse-metadata-key? key)
                true
                (compiler-parse-type-list-has-metadata? (box-get rest)))]
            [_ (compiler-parse-type-list-has-metadata? (box-get rest))])]
        [_ (compiler-parse-type-list-has-metadata? (box-get rest))])]
    [_ false]))

(define (compiler-parse-metadata-sexpr? [s : Sexpr]) : bool
  (match s
    [(Sexpr.Cons key-node _)
      (match (box-get key-node)
        [(Sexpr.Sym key) (compiler-parse-metadata-key? key)]
        [_ false])]
    [_ false]))

(define (parse-ast-variant-payload-parts
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [allow-cleanup : bool]) : ResultAstVariantPayloadParts
  (match s
    [(Sexpr.Nil)
      (ResultAstVariantPayloadParts.Ok
        (ast-type-list-new)
        (ast-variant-payload-cleanup-list-new))]
    [(Sexpr.Cons ty-node rest)
      (let
        [ty-form : Sexpr (box-get ty-node)]
        [rest-form : Sexpr (box-get rest)]
        (if (compiler-parse-metadata-sexpr? ty-form)
          (ResultAstVariantPayloadParts.Err
            "parse: enum payload cleanup metadata must follow a payload type")
          (match (parse-ast-type dispatch pools ty-form)
            [(ResultAstType.Ok parsed-ty)
              (match rest-form
                [(Sexpr.Nil)
                  (ResultAstVariantPayloadParts.Ok
                    (ast-type-cons-with-pools
                      pools
                      parsed-ty
                      (ast-type-list-new))
                    (ast-variant-payload-cleanup-cons
                      (AstVariantPayloadCleanup.No)
                      (ast-variant-payload-cleanup-list-new)))]
                [(Sexpr.Cons cleanup-node after-cleanup)
                  (let
                    [cleanup-form : Sexpr (box-get cleanup-node)]
                    (if (compiler-parse-metadata-sexpr? cleanup-form)
                      (if allow-cleanup
                        (match (parse-ast-variant-payload-cleanup cleanup-form)
                          [(ResultAstVariantPayloadCleanup.Ok parsed-cleanup)
                            (match (parse-ast-variant-payload-parts
                              dispatch
                              pools
                              (box-get after-cleanup)
                              allow-cleanup)
                              [(ResultAstVariantPayloadParts.Ok
                                  parsed-rest
                                  cleanup-rest)
                                (ResultAstVariantPayloadParts.Ok
                                  (ast-type-cons-with-pools
                                    pools
                                    parsed-ty
                                    parsed-rest)
                                  (ast-variant-payload-cleanup-cons
                                    parsed-cleanup
                                    cleanup-rest))]
                              [(ResultAstVariantPayloadParts.Err message)
                                (ResultAstVariantPayloadParts.Err message)])]
                          [(ResultAstVariantPayloadCleanup.Err message)
                            (ResultAstVariantPayloadParts.Err message)])
                        (ResultAstVariantPayloadParts.Err
                          "parse: enum payload cleanup metadata requires enum :cleanup metadata"))
                      (match (parse-ast-variant-payload-parts
                        dispatch
                        pools
                        rest-form
                        allow-cleanup)
                        [(ResultAstVariantPayloadParts.Ok
                            parsed-rest
                            cleanup-rest)
                          (ResultAstVariantPayloadParts.Ok
                            (ast-type-cons-with-pools
                              pools
                              parsed-ty
                              parsed-rest)
                            (ast-variant-payload-cleanup-cons
                              (AstVariantPayloadCleanup.No)
                              cleanup-rest))]
                        [(ResultAstVariantPayloadParts.Err message)
                          (ResultAstVariantPayloadParts.Err message)])))]
                [_
                  (ResultAstVariantPayloadParts.Err
                    "parse: malformed enum payload list")])]
            [(ResultAstType.Err message)
              (ResultAstVariantPayloadParts.Err message)])))]
    [_ (ResultAstVariantPayloadParts.Err "parse: malformed enum payload list")]))

(define (parse-ast-variant-def
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [allow-cleanup : bool]) : ResultAstVariantDef
  (match s
    [(Sexpr.Cons name-node fields)
      (match (box-get name-node)
        [(Sexpr.Sym name)
          (if (compiler-parse-metadata-key? name)
            (if (string.eq name ":cleanup")
              (ResultAstVariantDef.Err
                "parse: defenum metadata must appear before variants")
              (ResultAstVariantDef.Err
                (string.append "parse: unknown defenum metadata " name)))
            (match (parse-ast-variant-payload-parts
              dispatch
              pools
              (box-get fields)
              allow-cleanup)
              [(ResultAstVariantPayloadParts.Ok parsed-fields parsed-cleanups)
                (ResultAstVariantDef.Ok
                  (ast-variant-def name parsed-fields parsed-cleanups))]
              [(ResultAstVariantPayloadParts.Err message)
                (ResultAstVariantDef.Err message)]))]
        [_ (ResultAstVariantDef.Err "parse: malformed variant definition")])]
    [_ (ResultAstVariantDef.Err "parse: malformed variant definition")]))

(define (parse-ast-variant-def-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [allow-cleanup : bool]
  [out : (&mut out AstVariantDefList)]) : ResultAstVariantDefListBuild
  (match s
    [(Sexpr.Nil) (ResultAstVariantDefListBuild.Ok)]
    [(Sexpr.Cons head tail)
      (match (parse-ast-variant-def dispatch pools (box-get head) allow-cleanup)
        [(ResultAstVariantDef.Ok parsed-head)
          (begin
            (ast-variant-def-list-push out parsed-head)
            (parse-ast-variant-def-list-into
              dispatch
              pools
              (box-get tail)
              allow-cleanup
              out))]
        [(ResultAstVariantDef.Err message)
          (ResultAstVariantDefListBuild.Err message)])]
    [_ (ResultAstVariantDefListBuild.Err "parse: malformed variant list")]))

(define (parse-ast-variant-def-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [allow-cleanup : bool]) : ResultAstVariantDefList
  (let
    [out : AstVariantDefList (ast-variant-def-list-new)]
    (match (parse-ast-variant-def-list-into
      dispatch
      pools
      s
      allow-cleanup
      (&mut out))
      [(ResultAstVariantDefListBuild.Ok) (ResultAstVariantDefList.Ok out)]
      [(ResultAstVariantDefListBuild.Err message)
        (ResultAstVariantDefList.Err message)])))

(define (parse-ast-dispatch-isa [name : String]) : ResultAstDispatchIsa
  (cond
    [(string.eq name "scalar")
      (ResultAstDispatchIsa.Ok (AstDispatchIsa.Scalar))]
    [(string.eq name "avx2") (ResultAstDispatchIsa.Ok (AstDispatchIsa.Avx2))]
    [(string.eq name "avx512")
      (ResultAstDispatchIsa.Ok (AstDispatchIsa.Avx512))]
    [else
      (ResultAstDispatchIsa.Err
        (string.append "parse: unknown defdispatch ISA " name))]))

(define (parse-ast-dispatch-variant [s : SpannedSexpr]) : ResultAstDispatchVariant
  (match s
    [(SpannedSexpr.Cons isa-node rest _)
      (match (sp-node-get isa-node)
        [(SpannedSexpr.Sym isa-name _)
          (match (sp-node-get rest)
            [(SpannedSexpr.Cons fn-node end _)
              (match (sp-node-get end)
                [(SpannedSexpr.Nil _)
                  (match (sp-node-get fn-node)
                    [(SpannedSexpr.Sym fn-name _)
                      (match (parse-ast-dispatch-isa isa-name)
                        [(ResultAstDispatchIsa.Ok isa)
                          (ResultAstDispatchVariant.Ok
                            (AstDispatchVariant.Variant isa fn-name))]
                        [(ResultAstDispatchIsa.Err message)
                          (ResultAstDispatchVariant.Err message)])]
                    [_
                      (ResultAstDispatchVariant.Err
                        "parse: malformed defdispatch variant")])]
                [_
                  (ResultAstDispatchVariant.Err
                    "parse: malformed defdispatch variant")])]
            [_
              (ResultAstDispatchVariant.Err
                "parse: malformed defdispatch variant")])]
        [_
          (ResultAstDispatchVariant.Err "parse: malformed defdispatch variant")])]
    [_ (ResultAstDispatchVariant.Err "parse: malformed defdispatch variant")]))

(define (parse-ast-dispatch-variant-list-into
  [variants : SpannedSexpr]
  [out : (&mut out AstDispatchVariantList)]) : ResultAstDispatchVariantListBuild
  (match variants
    [(SpannedSexpr.Nil _) (ResultAstDispatchVariantListBuild.Ok)]
    [(SpannedSexpr.Cons head rest _)
      (match (parse-ast-dispatch-variant (sp-node-get head))
        [(ResultAstDispatchVariant.Ok parsed)
          (begin
            (ast-dispatch-variant-list-push out parsed)
            (parse-ast-dispatch-variant-list-into (sp-node-get rest) out))]
        [(ResultAstDispatchVariant.Err message)
          (ResultAstDispatchVariantListBuild.Err message)])]
    [_
      (ResultAstDispatchVariantListBuild.Err
        "parse: malformed defdispatch variant list")]))

(define (parse-ast-dispatch-variant-list [variants : SpannedSexpr]) : ResultAstDispatchVariantList
  (let
    [out : AstDispatchVariantList (ast-dispatch-variant-list-new)]
    (match (parse-ast-dispatch-variant-list-into variants (&mut out))
      [(ResultAstDispatchVariantListBuild.Ok)
        (ResultAstDispatchVariantList.Ok out)]
      [(ResultAstDispatchVariantListBuild.Err message)
        (ResultAstDispatchVariantList.Err message)])))

(define (parse-ast-defenum-variant-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : SpannedSexpr]
  [tail : SpannedSexpr]
  [lifetimes : AstLifetimeList]
  [cleanup : AstEnumCleanup]
  [seen-lifetimes : bool]
  [seen-cleanup : bool]) : ResultAstEnumDefParts
  (match (parse-ast-variant-def
    dispatch
    pools
    (spanned-sexpr-form head)
    (ast-enum-cleanup? cleanup))
    [(ResultAstVariantDef.Ok parsed-variant)
      (match (parse-ast-defenum-items
        dispatch
        pools
        tail
        lifetimes
        cleanup
        seen-lifetimes
        seen-cleanup
        true)
        [(ResultAstEnumDefParts.Ok parsed-lifetimes parsed-cleanup parsed-rest)
          (ResultAstEnumDefParts.Ok
            parsed-lifetimes
            parsed-cleanup
            (ast-variant-def-cons parsed-variant parsed-rest))]
        [(ResultAstEnumDefParts.Err message)
          (ResultAstEnumDefParts.Err message)])]
    [(ResultAstVariantDef.Err message) (ResultAstEnumDefParts.Err message)]))

(define (parse-ast-defenum-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : SpannedSexpr]
  [lifetimes : AstLifetimeList]
  [cleanup : AstEnumCleanup]
  [seen-lifetimes : bool]
  [seen-cleanup : bool]
  [seen-variant : bool]) : ResultAstEnumDefParts
  (match items
    [(SpannedSexpr.Nil _)
      (ResultAstEnumDefParts.Ok lifetimes cleanup (ast-variant-def-list-new))]
    [(SpannedSexpr.Cons head tail _)
      (match (spanned-sexpr-form (sp-node-get head))
        [(Sexpr.Cons key-node after-key)
          (match (box-get key-node)
            [(Sexpr.Sym key)
              (cond
                [(not (compiler-parse-metadata-key? key))
                  (parse-ast-defenum-variant-item
                    dispatch
                    pools
                    (sp-node-get head)
                    (sp-node-get tail)
                    lifetimes
                    cleanup
                    seen-lifetimes
                    seen-cleanup)]
                [seen-variant
                  (ResultAstEnumDefParts.Err
                    "parse: defenum metadata must appear before variants")]
                [(string.eq key ":lifetimes")
                  (if seen-lifetimes
                    (ResultAstEnumDefParts.Err
                      "parse: duplicate defenum :lifetimes metadata")
                    (match (parse-ast-aggregate-lifetimes-tail
                      dispatch
                      pools
                      (box-get after-key))
                      [(ResultAstLifetimeList.Ok next-lifetimes)
                        (parse-ast-defenum-items
                          dispatch
                          pools
                          (sp-node-get tail)
                          next-lifetimes
                          cleanup
                          true
                          seen-cleanup
                          false)]
                      [(ResultAstLifetimeList.Err message)
                        (ResultAstEnumDefParts.Err message)]))]
                [(string.eq key ":cleanup")
                  (if seen-cleanup
                    (ResultAstEnumDefParts.Err
                      "parse: duplicate defenum :cleanup metadata")
                    (match (parse-ast-defenum-cleanup-tail (box-get after-key))
                      [(ResultAstEnumCleanup.Ok next-cleanup)
                        (parse-ast-defenum-items
                          dispatch
                          pools
                          (sp-node-get tail)
                          lifetimes
                          next-cleanup
                          seen-lifetimes
                          true
                          false)]
                      [(ResultAstEnumCleanup.Err message)
                        (ResultAstEnumDefParts.Err message)]))]
                [else
                  (ResultAstEnumDefParts.Err
                    (string.append "parse: unknown defenum metadata " key))])]
            [_
              (parse-ast-defenum-variant-item
                dispatch
                pools
                (sp-node-get head)
                (sp-node-get tail)
                lifetimes
                cleanup
                seen-lifetimes
                seen-cleanup)])]
        [_
          (parse-ast-defenum-variant-item
            dispatch
            pools
            (sp-node-get head)
            (sp-node-get tail)
            lifetimes
            cleanup
            seen-lifetimes
            seen-cleanup)])]
    [_ (ResultAstEnumDefParts.Err "parse: malformed variant list")]))

(define (parse-ast-pattern-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]
  [out : (&mut out AstPatternList)]) : ResultAstPatternListBuild
  (match s
    [(Sexpr.Nil) (ResultAstPatternListBuild.Ok)]
    [(Sexpr.Cons head tail)
      (match (parse-ast-pattern dispatch pools (box-get head))
        [(ResultAstPattern.Ok parsed-head)
          (begin
            (ast-pattern-list-push out parsed-head)
            (parse-ast-pattern-list-into dispatch pools (box-get tail) out))]
        [(ResultAstPattern.Err message) (ResultAstPatternListBuild.Err message)])]
    [_ (ResultAstPatternListBuild.Err "parse: malformed pattern list")]))

(define (parse-ast-pattern-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]) : ResultAstPatternList
  (let
    [out : AstPatternList (ast-pattern-list-new)]
    (match (parse-ast-pattern-list-into dispatch pools s (&mut out))
      [(ResultAstPatternListBuild.Ok) (ResultAstPatternList.Ok out)]
      [(ResultAstPatternListBuild.Err message)
        (ResultAstPatternList.Err message)])))

(define (parse-ast-pattern
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : Sexpr]) : ResultAstPattern
  (match s
    [(Sexpr.Int n text)
      (ResultAstPattern.Ok (AstPattern.Literal (AstLiteral.Int n text)))]
    [(Sexpr.Float text)
      (ResultAstPattern.Ok (AstPattern.Literal (AstLiteral.Float text)))]
    [(Sexpr.Str text)
      (ResultAstPattern.Ok (AstPattern.Literal (AstLiteral.String text)))]
    [(Sexpr.Char c)
      (ResultAstPattern.Ok (AstPattern.Literal (AstLiteral.Char c)))]
    [(Sexpr.Sym name)
      (let
        [tag : i64 (compiler-parse-dispatch-tag dispatch name)]
        (cond
          [(= tag (compiler-parse-tag-pattern-wildcard))
            (ResultAstPattern.Ok AstPattern.Wildcard)]
          [(= tag (compiler-parse-tag-lit-true))
            (ResultAstPattern.Ok (AstPattern.Literal (AstLiteral.Bool true)))]
          [(= tag (compiler-parse-tag-lit-false))
            (ResultAstPattern.Ok (AstPattern.Literal (AstLiteral.Bool false)))]
          [else (ResultAstPattern.Ok (ast-pat-binding name))]))]
    [(Sexpr.Cons name-node args)
      (match (box-get name-node)
        [(Sexpr.Sym name)
          (match (parse-ast-pattern-list dispatch pools (box-get args))
            [(ResultAstPatternList.Ok parsed-args)
              (ResultAstPattern.Ok (ast-pat-variant name parsed-args))]
            [(ResultAstPatternList.Err message) (ResultAstPattern.Err message)])]
        [_ (ResultAstPattern.Err "parse: expected pattern")])]
    [_ (ResultAstPattern.Err "parse: expected pattern")]))

(define (parse-ast-cfg-expr-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstMaybeExpr
  (match rest
    [(SpannedSexpr.Cons pred then-tail _)
      (match (sp-node-get then-tail)
        [(SpannedSexpr.Cons then-expr rest-tail _)
          (match (sp-node-get rest-tail)
            [(SpannedSexpr.Nil _)
              (match (compiler-cfg-eval dispatch (sp-node-get pred))
                [(ResultCompilerCfg.Ok enabled)
                  (if enabled
                    (match (parse-ast-expr-with-pools
                      dispatch
                      pools
                      (sp-node-get then-expr))
                      [(ResultAstExpr.Ok parsed)
                        (ResultAstMaybeExpr.SomeExpr parsed)]
                      [(ResultAstExpr.Err message)
                        (ResultAstMaybeExpr.Err message)])
                    (ResultAstMaybeExpr.NoExpr))]
                [(ResultCompilerCfg.Err message)
                  (ResultAstMaybeExpr.Err message)])]
            [(SpannedSexpr.Cons else-expr end _)
              (match (sp-node-get end)
                [(SpannedSexpr.Nil _)
                  (match (compiler-cfg-eval dispatch (sp-node-get pred))
                    [(ResultCompilerCfg.Ok enabled)
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        (if enabled
                          (sp-node-get then-expr)
                          (sp-node-get else-expr)))
                        [(ResultAstExpr.Ok parsed)
                          (ResultAstMaybeExpr.SomeExpr parsed)]
                        [(ResultAstExpr.Err message)
                          (ResultAstMaybeExpr.Err message)])]
                    [(ResultCompilerCfg.Err message)
                      (ResultAstMaybeExpr.Err message)])]
                [_
                  (ResultAstMaybeExpr.Err
                    "parse: cfg expression expects predicate and expression")])]
            [_
              (ResultAstMaybeExpr.Err
                "parse: cfg expression expects predicate and expression")])]
        [_
          (ResultAstMaybeExpr.Err
            "parse: cfg expression expects predicate and expression")])]
    [_
      (ResultAstMaybeExpr.Err
        "parse: cfg expression expects predicate and expression")]))

(define (parse-ast-cfg-expr
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-cfg-expr-maybe dispatch pools rest)
    [(ResultAstMaybeExpr.SomeExpr expr) (ResultAstExpr.Ok expr)]
    [(ResultAstMaybeExpr.NoExpr)
      (ResultAstExpr.Ok
        (ast-node-pool-context-expr-push
          pools
          (AstExpr.Literal AstLiteral.Unit)))]
    [(ResultAstMaybeExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-expr-list-item-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : SpannedSexpr]) : ResultAstMaybeExpr
  (match head
    [(SpannedSexpr.Cons op-node cfg-rest _)
      (match (sp-node-get op-node)
        [(SpannedSexpr.Sym op _)
          (if (string.eq op "cfg")
            (parse-ast-cfg-expr-maybe dispatch pools (sp-node-get cfg-rest))
            (match (parse-ast-expr-with-pools dispatch pools head)
              [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
              [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)]))]
        [_
          (match (parse-ast-expr-with-pools dispatch pools head)
            [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
            [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])])]
    [_
      (match (parse-ast-expr-with-pools dispatch pools head)
        [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
        [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])]))

(define (parse-ast-expr-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]
  [out : (&mut out AstExprList)]) : ResultAstExprListBuild
  (match s
    [(SpannedSexpr.Nil _) (ResultAstExprListBuild.Ok)]
    [(SpannedSexpr.Cons head tail _)
      (match (parse-ast-expr-list-item-maybe dispatch pools (sp-node-get head))
        [(ResultAstMaybeExpr.SomeExpr parsed-head)
          (begin
            (ast-expr-list-push out parsed-head)
            (parse-ast-expr-list-into dispatch pools (sp-node-get tail) out))]
        [(ResultAstMaybeExpr.NoExpr)
          (parse-ast-expr-list-into dispatch pools (sp-node-get tail) out)]
        [(ResultAstMaybeExpr.Err message) (ResultAstExprListBuild.Err message)])]
    [_ (ResultAstExprListBuild.Err "parse: malformed expression list")]))

(define (parse-ast-expr-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]) : ResultAstExprList
  (let
    [out : AstExprList (ast-expr-list-new)]
    (match (parse-ast-expr-list-into dispatch pools s (&mut out))
      [(ResultAstExprListBuild.Ok) (ResultAstExprList.Ok out)]
      [(ResultAstExprListBuild.Err message) (ResultAstExprList.Err message)])))

(define (parse-ast-body-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]
  [missing-message : String]) : ResultAstExpr
  (match s
    [(SpannedSexpr.Nil _) (ResultAstExpr.Err missing-message)]
    [_
      (match (parse-ast-expr-list dispatch pools s)
        [(ResultAstExprList.Ok exprs)
          (let
            [n : i64 (struct-get (& exprs) len)]
            (cond
              [(= n 0) (ResultAstExpr.Err missing-message)]
              [(= n 1) (ResultAstExpr.Ok (ast-expr-list-get (& exprs) 0 0))]
              [else
                (ResultAstExpr.Ok
                  (ast-node-pool-context-expr-push pools (AstExpr.Begin exprs)))]))]
        [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]))

(define (parse-ast-call-bracket-clause
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]
  [items : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools items)
    [(ResultAstExprList.Ok parsed-items)
      (ResultAstExpr.Ok
        (ast-expr-wrap-span
          pools
          (ast-expr-bracket-clause-with-pools pools parsed-items)
          s))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-call-arg-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : SpannedSexpr]) : ResultAstMaybeExpr
  (match head
    [(SpannedSexpr.BracketList items _)
      (match (parse-ast-call-bracket-clause
        dispatch
        pools
        head
        (sp-node-get items))
        [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
        [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])]
    [(SpannedSexpr.Cons op-node cfg-rest _)
      (match (sp-node-get op-node)
        [(SpannedSexpr.Sym op _)
          (if (string.eq op "cfg")
            (parse-ast-cfg-expr-maybe dispatch pools (sp-node-get cfg-rest))
            (match (parse-ast-expr-with-pools dispatch pools head)
              [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
              [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)]))]
        [_
          (match (parse-ast-expr-with-pools dispatch pools head)
            [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
            [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])])]
    [_
      (match (parse-ast-expr-with-pools dispatch pools head)
        [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
        [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])]))

(define (parse-ast-call-arg-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]
  [out : (&mut out AstExprList)]) : ResultAstExprListBuild
  (match s
    [(SpannedSexpr.Nil _) (ResultAstExprListBuild.Ok)]
    [(SpannedSexpr.Cons head tail _)
      (match (parse-ast-call-arg-maybe dispatch pools (sp-node-get head))
        [(ResultAstMaybeExpr.SomeExpr parsed-head)
          (begin
            (ast-expr-list-push out parsed-head)
            (parse-ast-call-arg-list-into dispatch pools (sp-node-get tail) out))]
        [(ResultAstMaybeExpr.NoExpr)
          (parse-ast-call-arg-list-into dispatch pools (sp-node-get tail) out)]
        [(ResultAstMaybeExpr.Err message) (ResultAstExprListBuild.Err message)])]
    [_ (ResultAstExprListBuild.Err "parse: malformed call argument list")]))

(define (parse-ast-call-arg-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]) : ResultAstExprList
  (let
    [out : AstExprList (ast-expr-list-new)]
    (match (parse-ast-call-arg-list-into dispatch pools s (&mut out))
      [(ResultAstExprListBuild.Ok) (ResultAstExprList.Ok out)]
      [(ResultAstExprListBuild.Err message) (ResultAstExprList.Err message)])))

(define (parse-ast-binary
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstBinOp]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons left right-tail _)
      (match (sp-node-get right-tail)
        [(SpannedSexpr.Cons right end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (sp-node-get left))
                [(ResultAstExpr.Ok parsed-left)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get right))
                    [(ResultAstExpr.Ok parsed-right)
                      (ResultAstExpr.Ok
                        (ast-expr-binary-with-pools
                          pools
                          op
                          parsed-left
                          parsed-right))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed binary expression")])]
        [_ (ResultAstExpr.Err "parse: malformed binary expression")])]
    [_ (ResultAstExpr.Err "parse: malformed binary expression")]))

(define (parse-ast-binary-left-fold-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstBinOp]
  [acc : i64]
  [tail : SpannedSexpr]) : ResultAstExpr
  (match tail
    [(SpannedSexpr.Nil _) (ResultAstExpr.Ok acc)]
    [(SpannedSexpr.Cons expr rest _)
      (match (parse-ast-expr-with-pools dispatch pools (sp-node-get expr))
        [(ResultAstExpr.Ok parsed-expr)
          (parse-ast-binary-left-fold-tail
            dispatch
            pools
            op
            (ast-expr-binary-with-pools pools op acc parsed-expr)
            (sp-node-get rest))]
        [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed binary expression")]))

(define (parse-ast-binary-left-fold
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstBinOp]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons left right-tail _)
      (match (sp-node-get right-tail)
        [(SpannedSexpr.Cons right tail _)
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get left))
            [(ResultAstExpr.Ok parsed-left)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (sp-node-get right))
                [(ResultAstExpr.Ok parsed-right)
                  (parse-ast-binary-left-fold-tail
                    dispatch
                    pools
                    op
                    (ast-expr-binary-with-pools
                      pools
                      op
                      parsed-left
                      parsed-right)
                    (sp-node-get tail))]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: malformed binary expression")])]
    [_ (ResultAstExpr.Err "parse: malformed binary expression")]))

(define (parse-ast-unary
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstUnOp]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr end _)
      (match (sp-node-get end)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast-expr-unary-with-pools pools op parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: malformed unary expression")])]
    [_ (ResultAstExpr.Err "parse: malformed unary expression")]))

(define (parse-ast-if-missing-else-message) : String
  "parse: if is missing its else branch")

(define (parse-ast-if-arity-message) : String
  "parse: if expects condition, then branch, and else branch")

(define (parse-ast-if-example-note) : String
  "example: (if condition then-expr else-expr)")

(define (parse-ast-if-one-sided-note) : String
  "use (when condition body...) or (unless condition body...) for one-sided conditionals")

(define (parse-ast-if-message? [message : String]) : bool
  (or
    (string.eq message (parse-ast-if-missing-else-message))
    (string.eq message (parse-ast-if-arity-message))))

(define (parse-ast-if-diagnostic-notes [diag : CompilerDiagnostic]) : CompilerDiagnostic
  (compiler-diagnostic-with-note
    (compiler-diagnostic-with-note diag (parse-ast-if-one-sided-note))
    (parse-ast-if-example-note)))

(define (parse-ast-if
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons cond then-tail _)
      (match (sp-node-get then-tail)
        [(SpannedSexpr.Cons then-branch else-tail _)
          (match (sp-node-get else-tail)
            [(SpannedSexpr.Cons else-branch end _)
              (match (sp-node-get end)
                [(SpannedSexpr.Nil _)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get cond))
                    [(ResultAstExpr.Ok parsed-cond)
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        (sp-node-get then-branch))
                        [(ResultAstExpr.Ok parsed-then)
                          (match (parse-ast-expr-with-pools
                            dispatch
                            pools
                            (sp-node-get else-branch))
                            [(ResultAstExpr.Ok parsed-else)
                              (ResultAstExpr.Ok
                                (ast-expr-if-with-pools
                                  pools
                                  parsed-cond
                                  parsed-then
                                  parsed-else))]
                            [(ResultAstExpr.Err message)
                              (ResultAstExpr.Err message)])]
                        [(ResultAstExpr.Err message)
                          (ResultAstExpr.Err message)])]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err (parse-ast-if-arity-message))])]
            [_ (ResultAstExpr.Err (parse-ast-if-missing-else-message))])]
        [_ (ResultAstExpr.Err (parse-ast-if-arity-message))])]
    [_ (ResultAstExpr.Err (parse-ast-if-arity-message))]))

(define (parse-ast-while
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons cond body-tail _)
      (match (parse-ast-expr-with-pools dispatch pools (sp-node-get cond))
        [(ResultAstExpr.Ok parsed-cond)
          (match (parse-ast-body-tail
            dispatch
            pools
            (sp-node-get body-tail)
            "parse: malformed while")
            [(ResultAstExpr.Ok parsed-body)
              (ResultAstExpr.Ok
                (ast-expr-while-with-pools pools parsed-cond parsed-body))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed while")]))

(define (parse-ast-set
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons target-node value-tail _)
      (match (sp-node-get value-tail)
        [(SpannedSexpr.Cons value end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (sp-node-get value))
                [(ResultAstExpr.Ok parsed-value)
                  (match (sp-node-get target-node)
                    [(SpannedSexpr.Sym name _)
                      (ResultAstExpr.Ok
                        (ast-expr-set-with-pools pools name parsed-value))]
                    [_
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        (sp-node-get target-node))
                        [(ResultAstExpr.Ok parsed-target)
                          (match (ast-expr-unspan-with-pools
                            pools
                            (ast-node-pool-context-expr-get pools parsed-target))
                            [(AstExpr.StructGet receiver-box field)
                              (ResultAstExpr.Ok
                                (ast-expr-struct-set-id-with-pools
                                  pools
                                  receiver-box
                                  field
                                  parsed-value))]
                            [(AstExpr.BoxGet receiver-box)
                              (ResultAstExpr.Ok
                                (ast-expr-box-set-with-pools
                                  pools
                                  receiver-box
                                  parsed-value))]
                            [(AstExpr.Unquote _)
                              (ResultAstExpr.Ok
                                (ast-expr-struct-set-id-with-pools
                                  pools
                                  parsed-target
                                  (ast-expr-unquote-set-target-field-id)
                                  parsed-value))]
                            [_
                              (ResultAstExpr.Err
                                "parse: set! target must be a name, struct field place, or box place")])]
                        [(ResultAstExpr.Err message)
                          (ResultAstExpr.Err message)])])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed set!")])]
        [_ (ResultAstExpr.Err "parse: malformed set!")])]
    [_ (ResultAstExpr.Err "parse: malformed set!")]))

(define (parse-ast-ann-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [is-cast : bool]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr colon-tail _)
      (match (sp-node-get colon-tail)
        [(SpannedSexpr.Cons colon ty-tail _)
          (match (sp-node-get ty-tail)
            [(SpannedSexpr.Cons ty end _)
              (match (sp-node-get end)
                [(SpannedSexpr.Nil _)
                  (if (sexpr-colon? (spanned-sexpr-form (sp-node-get colon)))
                    (match (parse-ast-expr-with-pools
                      dispatch
                      pools
                      (sp-node-get expr))
                      [(ResultAstExpr.Ok parsed-expr)
                        (match (parse-ast-type-spanned
                          dispatch
                          pools
                          (sp-node-get ty))
                          [(ResultAstType.Ok parsed-ty)
                            (if is-cast
                              (ResultAstExpr.Ok
                                (ast-expr-cast-with-pools
                                  pools
                                  parsed-expr
                                  parsed-ty))
                              (ResultAstExpr.Ok
                                (ast-expr-ann-with-pools
                                  pools
                                  parsed-expr
                                  parsed-ty)))]
                          [(ResultAstType.Err message)
                            (ResultAstExpr.Err message)])]
                      [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])
                    (ResultAstExpr.Err "parse: expected ':' in annotation"))]
                [_ (ResultAstExpr.Err "parse: malformed annotation")])]
            [_ (ResultAstExpr.Err "parse: malformed annotation")])]
        [_ (ResultAstExpr.Err "parse: malformed annotation")])]
    [_ (ResultAstExpr.Err "parse: malformed annotation")]))

(define (parse-ast-let-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]) : ResultAstLetBinding
  (let
    [result : ResultAstLetBinding
      (match s
        [(SpannedSexpr.BracketList items _)
          (parse-ast-let-binding dispatch pools (sp-node-get items))]
        [(SpannedSexpr.Cons name-node tail _)
          (match (sp-node-get name-node)
            [(SpannedSexpr.Sym name _)
              (match (sp-node-get tail)
                [(SpannedSexpr.Cons second rest _)
                  (match (sp-node-get rest)
                    [(SpannedSexpr.Nil _)
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        (sp-node-get second))
                        [(ResultAstExpr.Ok parsed-value)
                          (ResultAstLetBinding.Ok
                            (ast-let-binding name AstMaybeType.No parsed-value))]
                        [(ResultAstExpr.Err message)
                          (ResultAstLetBinding.Err message)])]
                    [(SpannedSexpr.Cons ty value-tail _)
                      (match (sp-node-get value-tail)
                        [(SpannedSexpr.Cons value end _)
                          (match (sp-node-get end)
                            [(SpannedSexpr.Nil _)
                              (if (sexpr-colon?
                                (spanned-sexpr-form (sp-node-get second)))
                                (match (parse-ast-type-spanned
                                  dispatch
                                  pools
                                  (sp-node-get ty))
                                  [(ResultAstType.Ok parsed-ty)
                                    (match (parse-ast-expr-with-pools
                                      dispatch
                                      pools
                                      (sp-node-get value))
                                      [(ResultAstExpr.Ok parsed-value)
                                        (ResultAstLetBinding.Ok
                                          (ast-let-binding
                                            name
                                            (AstMaybeType.Some parsed-ty)
                                            parsed-value))]
                                      [(ResultAstExpr.Err message)
                                        (ResultAstLetBinding.Err message)])]
                                  [(ResultAstType.Err message)
                                    (ResultAstLetBinding.Err message)])
                                (ResultAstLetBinding.Err
                                  "parse: expected ':' in let binding"))]
                            [_
                              (ResultAstLetBinding.Err
                                "parse: malformed let binding")])]
                        [_
                          (ResultAstLetBinding.Err
                            "parse: malformed let binding")])]
                    [_ (ResultAstLetBinding.Err "parse: malformed let binding")])]
                [_ (ResultAstLetBinding.Err "parse: malformed let binding")])]
            [_ (ResultAstLetBinding.Err "parse: malformed let binding")])]
        [_ (ResultAstLetBinding.Err "parse: malformed let binding")])]
    (parse-ast-error-span-note-let-binding s result)))

(define (parse-ast-let-binding-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]
  [out : (&mut out AstLetBindingList)]) : ResultAstLetBindingListBuild
  (match s
    [(SpannedSexpr.Nil _) (ResultAstLetBindingListBuild.Ok)]
    [(SpannedSexpr.Cons head tail _)
      (match (parse-ast-let-binding dispatch pools (sp-node-get head))
        [(ResultAstLetBinding.Ok parsed-head)
          (begin
            (ast-let-binding-list-push out parsed-head)
            (parse-ast-let-binding-list-into
              dispatch
              pools
              (sp-node-get tail)
              out))]
        [(ResultAstLetBinding.Err message)
          (ResultAstLetBindingListBuild.Err message)])]
    [_ (ResultAstLetBindingListBuild.Err "parse: malformed let binding list")]))

(define (parse-ast-let-binding-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]) : ResultAstLetBindingList
  (let
    [out : AstLetBindingList (ast-let-binding-list-new)]
    (match (parse-ast-let-binding-list-into dispatch pools s (&mut out))
      [(ResultAstLetBindingListBuild.Ok) (ResultAstLetBindingList.Ok out)]
      [(ResultAstLetBindingListBuild.Err message)
        (ResultAstLetBindingList.Err message)])))

(define (parse-ast-let-flat-tail-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]
  [out : (&mut out AstLetBindingList)]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons head tail _)
      (match (sp-node-get head)
        [(SpannedSexpr.BracketList _ _)
          (match (parse-ast-let-binding dispatch pools (sp-node-get head))
            [(ResultAstLetBinding.Ok parsed-head)
              (begin
                (ast-let-binding-list-push out parsed-head)
                (parse-ast-let-flat-tail-into
                  dispatch
                  pools
                  (sp-node-get tail)
                  out))]
            [(ResultAstLetBinding.Err message) (ResultAstExpr.Err message)])]
        [_ (parse-ast-body-tail dispatch pools rest "parse: let missing body")])]
    [(SpannedSexpr.Nil _) (ResultAstExpr.Err "parse: let missing body")]
    [_ (ResultAstExpr.Err "parse: malformed let")]))

(define (parse-ast-let-flat-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstLetParts
  (let
    [out : AstLetBindingList (ast-let-binding-list-new)]
    (match (parse-ast-let-flat-tail-into dispatch pools rest (&mut out))
      [(ResultAstExpr.Ok parsed-body) (ResultAstLetParts.Ok out parsed-body)]
      [(ResultAstExpr.Err message) (ResultAstLetParts.Err message)])))

(define (parse-ast-let-flat
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons head _ _)
      (match (sp-node-get head)
        [(SpannedSexpr.BracketList items _)
          (match (sp-node-get items)
            [(SpannedSexpr.Nil _)
              (match rest
                [(SpannedSexpr.Cons _ body-tail _)
                  (parse-ast-body-tail
                    dispatch
                    pools
                    (sp-node-get body-tail)
                    "parse: let missing body")]
                [_ (ResultAstExpr.Err "parse: malformed let")])]
            [_
              (match (parse-ast-let-flat-tail dispatch pools rest)
                [(ResultAstLetParts.Ok parsed-bindings parsed-body)
                  (ResultAstExpr.Ok
                    (ast-expr-let-with-pools pools parsed-bindings parsed-body))]
                [(ResultAstLetParts.Err message) (ResultAstExpr.Err message)])])]
        [_ (ResultAstExpr.Err "parse: let requires at least one binding")])]
    [_ (ResultAstExpr.Err "parse: malformed let")]))

(define (parse-ast-let
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons bindings tail _)
      (match (sp-node-get bindings)
        [(SpannedSexpr.BracketList _ _)
          (parse-ast-let-flat dispatch pools rest)]
        [(SpannedSexpr.Nil _)
          (parse-ast-body-tail
            dispatch
            pools
            (sp-node-get tail)
            "parse: let missing body")]
        [(SpannedSexpr.Cons _ _ _)
          (match (parse-ast-let-binding-list
            dispatch
            pools
            (sp-node-get bindings))
            [(ResultAstLetBindingList.Ok parsed-bindings)
              (match (parse-ast-body-tail
                dispatch
                pools
                (sp-node-get tail)
                "parse: let missing body")
                [(ResultAstExpr.Ok parsed-body)
                  (if (ast-let-binding-list-empty? (& parsed-bindings))
                    (ResultAstExpr.Ok parsed-body)
                    (ResultAstExpr.Ok
                      (ast-expr-let-with-pools
                        pools
                        parsed-bindings
                        parsed-body)))]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [(ResultAstLetBindingList.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: let requires at least one binding")])]
    [_ (ResultAstExpr.Err "parse: malformed let")]))

(define (parse-ast-lambda
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons params tail _)
      (match (parse-ast-param-list
        dispatch
        pools
        (spanned-sexpr-form (sp-node-get params)))
        [(ResultAstParamList.Ok parsed-params)
          (if (ast-param-list-has-comptime? parsed-params)
            (ResultAstExpr.Err
              "comptime parameters are only supported on top-level function definitions")
            (match (sp-node-get tail)
              [(SpannedSexpr.Cons first rest-tail _)
                (if (sexpr-colon? (spanned-sexpr-form (sp-node-get first)))
                  (match (sp-node-get rest-tail)
                    [(SpannedSexpr.Cons ret body-tail _)
                      (match (parse-ast-type-spanned
                        dispatch
                        pools
                        (sp-node-get ret))
                        [(ResultAstType.Ok parsed-ret)
                          (match (parse-ast-body-tail
                            dispatch
                            pools
                            (sp-node-get body-tail)
                            "parse: malformed lambda")
                            [(ResultAstExpr.Ok parsed-body)
                              (ResultAstExpr.Ok
                                (ast-expr-lambda-with-pools
                                  pools
                                  parsed-params
                                  (AstMaybeType.Some parsed-ret)
                                  parsed-body))]
                            [(ResultAstExpr.Err message)
                              (ResultAstExpr.Err message)])]
                        [(ResultAstType.Err message)
                          (ResultAstExpr.Err message)])]
                    [_ (ResultAstExpr.Err "parse: malformed lambda")])
                  (match (parse-ast-body-tail
                    dispatch
                    pools
                    (sp-node-get tail)
                    "parse: malformed lambda")
                    [(ResultAstExpr.Ok parsed-body)
                      (ResultAstExpr.Ok
                        (ast-expr-lambda-with-pools
                          pools
                          parsed-params
                          AstMaybeType.No
                          parsed-body))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))]
              [_ (ResultAstExpr.Err "parse: malformed lambda")]))]
        [(ResultAstParamList.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed lambda")]))

(define (parse-ast-tuple-ref
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr index-tail _)
      (match (sp-node-get index-tail)
        [(SpannedSexpr.Cons index-node end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (sp-node-get index-node)
                [(SpannedSexpr.Int index _ _)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get expr))
                    [(ResultAstExpr.Ok parsed-expr)
                      (ResultAstExpr.Ok
                        (ast-expr-tuple-ref-with-pools pools parsed-expr index))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err "parse: tuple-ref index must be integer")])]
            [_ (ResultAstExpr.Err "parse: malformed tuple-ref")])]
        [_ (ResultAstExpr.Err "parse: malformed tuple-ref")])]
    [_ (ResultAstExpr.Err "parse: malformed tuple-ref")]))

(define (parse-ast-dyn-array-literal
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok exprs)
      (ResultAstExpr.Ok (ast-expr-dyn-array-with-pools pools exprs))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-make-array
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons elem-ty len-tail _)
      (match (sp-node-get len-tail)
        [(SpannedSexpr.Cons len end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (parse-ast-type-spanned
                dispatch
                pools
                (sp-node-get elem-ty))
                [(ResultAstType.Ok parsed-ty)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get len))
                    [(ResultAstExpr.Ok parsed-len)
                      (ResultAstExpr.Ok
                        (ast-expr-make-array-with-pools
                          pools
                          parsed-ty
                          parsed-len))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstType.Err _)
                  (parse-ast-dyn-array-literal dispatch pools rest)])]
            [_ (parse-ast-dyn-array-literal dispatch pools rest)])]
        [_ (parse-ast-dyn-array-literal dispatch pools rest)])]
    [_ (parse-ast-dyn-array-literal dispatch pools rest)]))

(define (parse-ast-array-ref-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [is-string : bool]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr index-tail _)
      (match (sp-node-get index-tail)
        [(SpannedSexpr.Cons index end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (sp-node-get expr))
                [(ResultAstExpr.Ok parsed-expr)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get index))
                    [(ResultAstExpr.Ok parsed-index)
                      (if is-string
                        (ResultAstExpr.Ok
                          (ast-expr-string-ref-with-pools
                            pools
                            parsed-expr
                            parsed-index))
                        (ResultAstExpr.Ok
                          (ast-expr-array-ref-with-pools
                            pools
                            parsed-expr
                            parsed-index)))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed ref expression")])]
        [_ (ResultAstExpr.Err "parse: malformed ref expression")])]
    [_ (ResultAstExpr.Err "parse: malformed ref expression")]))

(define (parse-ast-array-set
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr index-tail _)
      (match (sp-node-get index-tail)
        [(SpannedSexpr.Cons index value-tail _)
          (match (sp-node-get value-tail)
            [(SpannedSexpr.Cons value end _)
              (match (sp-node-get end)
                [(SpannedSexpr.Nil _)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get expr))
                    [(ResultAstExpr.Ok parsed-expr)
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        (sp-node-get index))
                        [(ResultAstExpr.Ok parsed-index)
                          (match (parse-ast-expr-with-pools
                            dispatch
                            pools
                            (sp-node-get value))
                            [(ResultAstExpr.Ok parsed-value)
                              (ResultAstExpr.Ok
                                (ast-expr-array-set-with-pools
                                  pools
                                  parsed-expr
                                  parsed-index
                                  parsed-value))]
                            [(ResultAstExpr.Err message)
                              (ResultAstExpr.Err message)])]
                        [(ResultAstExpr.Err message)
                          (ResultAstExpr.Err message)])]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err "parse: malformed array-set!")])]
            [_ (ResultAstExpr.Err "parse: malformed array-set!")])]
        [_ (ResultAstExpr.Err "parse: malformed array-set!")])]
    [_ (ResultAstExpr.Err "parse: malformed array-set!")]))

(define (parse-ast-array-push
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr value-tail _)
      (match (sp-node-get value-tail)
        [(SpannedSexpr.Cons value end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (sp-node-get expr))
                [(ResultAstExpr.Ok parsed-expr)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get value))
                    [(ResultAstExpr.Ok parsed-value)
                      (ResultAstExpr.Ok
                        (ast-expr-array-push-with-pools
                          pools
                          parsed-expr
                          parsed-value))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed array-push!")])]
        [_ (ResultAstExpr.Err "parse: malformed array-push!")])]
    [_ (ResultAstExpr.Err "parse: malformed array-push!")]))

(define (parse-ast-array-take
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons array live-tail _)
      (match (sp-node-get live-tail)
        [(SpannedSexpr.Cons live index-tail _)
          (match (sp-node-get index-tail)
            [(SpannedSexpr.Cons index end _)
              (match (sp-node-get end)
                [(SpannedSexpr.Nil _)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get array))
                    [(ResultAstExpr.Ok parsed-array)
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        (sp-node-get live))
                        [(ResultAstExpr.Ok parsed-live)
                          (match (parse-ast-expr-with-pools
                            dispatch
                            pools
                            (sp-node-get index))
                            [(ResultAstExpr.Ok parsed-index)
                              (ResultAstExpr.Ok
                                (ast-expr-array-take-with-pools
                                  pools
                                  parsed-array
                                  parsed-live
                                  parsed-index))]
                            [(ResultAstExpr.Err message)
                              (ResultAstExpr.Err message)])]
                        [(ResultAstExpr.Err message)
                          (ResultAstExpr.Err message)])]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err "parse: malformed array-take!")])]
            [_ (ResultAstExpr.Err "parse: malformed array-take!")])]
        [_ (ResultAstExpr.Err "parse: malformed array-take!")])]
    [_ (ResultAstExpr.Err "parse: malformed array-take!")]))

(define (parse-ast-borrow
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [mutable : bool]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons first tail _)
      (match (sp-node-get tail)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get first))
            [(ResultAstExpr.Ok parsed-place)
              (ResultAstExpr.Ok
                (ast-expr-borrow-with-pools
                  pools
                  mutable
                  AstBorrowLifetime.Inferred
                  parsed-place))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [(SpannedSexpr.Cons place end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (sp-node-get first)
                [(SpannedSexpr.Sym name _)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get place))
                    [(ResultAstExpr.Ok parsed-place)
                      (ResultAstExpr.Ok
                        (ast-expr-borrow-with-pools
                          pools
                          mutable
                          (AstBorrowLifetime.Named name)
                          parsed-place))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_
                  (ResultAstExpr.Err
                    "parse: borrow lifetime must be an identifier")])]
            [_
              (ResultAstExpr.Err
                "parse: borrow expects a place or lifetime and place")])]
        [_
          (ResultAstExpr.Err
            "parse: borrow expects a place or lifetime and place")])]
    [_
      (ResultAstExpr.Err "parse: borrow expects a place or lifetime and place")]))

(define (parse-ast-struct-get
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr field-tail _)
      (match (sp-node-get field-tail)
        [(SpannedSexpr.Cons field-node end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (sp-node-get field-node)
                [(SpannedSexpr.Sym field _)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get expr))
                    [(ResultAstExpr.Ok parsed-expr)
                      (ResultAstExpr.Ok
                        (ast-expr-struct-get-with-pools pools parsed-expr field))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err "parse: malformed struct-get")])]
            [_ (ResultAstExpr.Err "parse: malformed struct-get")])]
        [_ (ResultAstExpr.Err "parse: malformed struct-get")])]
    [_ (ResultAstExpr.Err "parse: malformed struct-get")]))

;; `(comptime expr)` wraps exactly one inner expression for compile-time
;; evaluation; evaluation itself happens in CTFE, not the parser.
(define (parse-ast-comptime
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr end _)
      (match (sp-node-get end)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast-expr-comptime-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: comptime expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: comptime expects exactly one expression")]))

(define (parse-ast-type-literal
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons ty end _)
      (match (sp-node-get end)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-type-spanned dispatch pools (sp-node-get ty))
            [(ResultAstType.Ok parsed-ty)
              (begin
                (compiler-parse-type-literal-tracking-mark!)
                (ResultAstExpr.Ok
                  (ast-node-pool-context-expr-push
                    pools
                    (AstExpr.TypeLiteral parsed-ty))))]
            [(ResultAstType.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: type expects exactly one type")])]
    [_ (ResultAstExpr.Err "parse: type expects exactly one type")]))

(define (parse-ast-reduce-op [name : String]) : ResultAstReduceOp
  (cond
    [(string.eq name "sum") (ResultAstReduceOp.Ok (AstReduceOp.Sum))]
    [(string.eq name "min") (ResultAstReduceOp.Ok (AstReduceOp.Min))]
    [(string.eq name "max") (ResultAstReduceOp.Ok (AstReduceOp.Max))]
    [(string.eq name "all") (ResultAstReduceOp.Ok (AstReduceOp.All))]
    [(string.eq name "any") (ResultAstReduceOp.Ok (AstReduceOp.Any))]
    [else
      (ResultAstReduceOp.Err
        (string.append
          "parse: unsupported spmd-reduce operator `"
          (string.append name "`; expected one of sum, min, max, all, any")))]))

(define (parse-ast-scan-op [name : String]) : ResultAstReduceOp
  (cond
    [(string.eq name "sum") (ResultAstReduceOp.Ok (AstReduceOp.Sum))]
    [(string.eq name "min") (ResultAstReduceOp.Ok (AstReduceOp.Min))]
    [(string.eq name "max") (ResultAstReduceOp.Ok (AstReduceOp.Max))]
    [(string.eq name "all") (ResultAstReduceOp.Ok (AstReduceOp.All))]
    [(string.eq name "any") (ResultAstReduceOp.Ok (AstReduceOp.Any))]
    [else
      (ResultAstReduceOp.Err
        (string.append
          "parse: unsupported spmd-scan operator `"
          (string.append name "`; expected one of sum, min, max, all, any")))]))

(define (parse-ast-spmd-reduce-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstReduceOp]
  [binding : SpannedSexpr]
  [init : SpannedSexpr]
  [value : SpannedSexpr]) : ResultAstExpr
  (match binding
    [(SpannedSexpr.BracketList items _)
      (parse-ast-spmd-reduce-binding
        dispatch
        pools
        op
        (sp-node-get items)
        init
        value)]
    [(SpannedSexpr.Cons index-node colon-tail _)
      (match (sp-node-get index-node)
        [(SpannedSexpr.Sym index _)
          (match (sp-node-get colon-tail)
            [(SpannedSexpr.Cons colon index-ty-tail _)
              (match (sp-node-get index-ty-tail)
                [(SpannedSexpr.Cons index-ty start-tail _)
                  (match (sp-node-get start-tail)
                    [(SpannedSexpr.Cons start end-tail _)
                      (match (sp-node-get end-tail)
                        [(SpannedSexpr.Cons end finish _)
                          (match (sp-node-get finish)
                            [(SpannedSexpr.Nil _)
                              (if (sexpr-colon?
                                (spanned-sexpr-form (sp-node-get colon)))
                                (match (parse-ast-type-spanned
                                  dispatch
                                  pools
                                  (sp-node-get index-ty))
                                  [(ResultAstType.Ok parsed-index-ty)
                                    (match (parse-ast-expr-with-pools
                                      dispatch
                                      pools
                                      (sp-node-get start))
                                      [(ResultAstExpr.Ok parsed-start)
                                        (match (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          (sp-node-get end))
                                          [(ResultAstExpr.Ok parsed-end)
                                            (match (parse-ast-expr-with-pools
                                              dispatch
                                              pools
                                              init)
                                              [(ResultAstExpr.Ok parsed-init)
                                                (match (parse-ast-expr-with-pools
                                                  dispatch
                                                  pools
                                                  value)
                                                  [(ResultAstExpr.Ok
                                                      parsed-value)
                                                    (ResultAstExpr.Ok
                                                      (ast-expr-spmd-reduce-with-pools
                                                        pools
                                                        op
                                                        index
                                                        parsed-index-ty
                                                        parsed-start
                                                        parsed-end
                                                        parsed-init
                                                        parsed-value))]
                                                  [(ResultAstExpr.Err message)
                                                    (ResultAstExpr.Err message)])]
                                              [(ResultAstExpr.Err message)
                                                (ResultAstExpr.Err message)])]
                                          [(ResultAstExpr.Err message)
                                            (ResultAstExpr.Err message)])]
                                      [(ResultAstExpr.Err message)
                                        (ResultAstExpr.Err message)])]
                                  [(ResultAstType.Err message)
                                    (ResultAstExpr.Err message)])
                                (ResultAstExpr.Err
                                  "parse: expected ':' in spmd-reduce"))]
                            [_
                              (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                        [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                    [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")]))

(define (parse-ast-spmd-reduce
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons op-node binding-tail _)
      (match (sp-node-get op-node)
        [(SpannedSexpr.Sym op-name _)
          (match (sp-node-get binding-tail)
            [(SpannedSexpr.Cons binding-list init-tail _)
              (match (sp-node-get binding-list)
                [(SpannedSexpr.Cons binding binding-list-end _)
                  (match (sp-node-get binding-list-end)
                    [(SpannedSexpr.Nil _)
                      (match (sp-node-get init-tail)
                        [(SpannedSexpr.Cons init value-tail _)
                          (match (sp-node-get value-tail)
                            [(SpannedSexpr.Cons value end _)
                              (match (sp-node-get end)
                                [(SpannedSexpr.Nil _)
                                  (match (parse-ast-reduce-op op-name)
                                    [(ResultAstReduceOp.Ok op)
                                      (parse-ast-spmd-reduce-binding
                                        dispatch
                                        pools
                                        op
                                        (sp-node-get binding)
                                        (sp-node-get init)
                                        (sp-node-get value))]
                                    [(ResultAstReduceOp.Err message)
                                      (ResultAstExpr.Err message)])]
                                [_
                                  (ResultAstExpr.Err
                                    "parse: malformed spmd-reduce")])]
                            [_
                              (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                        [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                    [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
    [(SpannedSexpr.Cons _ _ _)
      (ResultAstExpr.Err "parse: malformed spmd-reduce")]
    [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")]))

(define (parse-ast-spmd-scan
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons op-node binding-tail _)
      (match (sp-node-get op-node)
        [(SpannedSexpr.Sym op-name _)
          (match (sp-node-get binding-tail)
            [(SpannedSexpr.Cons binding-list value-tail _)
              (match (sp-node-get binding-list)
                [(SpannedSexpr.Cons range-binding prefix-tail _)
                  (match (sp-node-get prefix-tail)
                    [(SpannedSexpr.Cons prefix-binding binding-end _)
                      (match (sp-node-get binding-end)
                        [(SpannedSexpr.Nil _)
                          (match (sp-node-get value-tail)
                            [(SpannedSexpr.Cons value body-tail _)
                              (match (sp-node-get body-tail)
                                [(SpannedSexpr.Cons body end _)
                                  (match (sp-node-get end)
                                    [(SpannedSexpr.Nil _)
                                      (match (parse-ast-scan-op op-name)
                                        [(ResultAstReduceOp.Ok op)
                                          (parse-ast-spmd-scan-bindings
                                            dispatch
                                            pools
                                            op
                                            (sp-node-get range-binding)
                                            (sp-node-get prefix-binding)
                                            (sp-node-get value)
                                            (sp-node-get body))]
                                        [(ResultAstReduceOp.Err message)
                                          (ResultAstExpr.Err message)])]
                                    [_
                                      (ResultAstExpr.Err
                                        "parse: malformed spmd-scan")])]
                                [_
                                  (ResultAstExpr.Err
                                    "parse: malformed spmd-scan")])]
                            [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
                        [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
                    [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
                [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
    [(SpannedSexpr.Cons _ _ _) (ResultAstExpr.Err "parse: malformed spmd-scan")]
    [_ (ResultAstExpr.Err "parse: malformed spmd-scan")]))

(define (parse-ast-spmd-scan-bindings
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstReduceOp]
  [range-binding : SpannedSexpr]
  [prefix-binding : SpannedSexpr]
  [value : SpannedSexpr]
  [body : SpannedSexpr]) : ResultAstExpr
  (match range-binding
    [(SpannedSexpr.BracketList items _)
      (parse-ast-spmd-scan-bindings
        dispatch
        pools
        op
        (sp-node-get items)
        prefix-binding
        value
        body)]
    [(SpannedSexpr.Cons index-node colon-tail _)
      (match (sp-node-get index-node)
        [(SpannedSexpr.Sym index _)
          (match (sp-node-get colon-tail)
            [(SpannedSexpr.Cons colon index-ty-tail _)
              (match (sp-node-get index-ty-tail)
                [(SpannedSexpr.Cons index-ty start-tail _)
                  (match (sp-node-get start-tail)
                    [(SpannedSexpr.Cons start end-tail _)
                      (match (sp-node-get end-tail)
                        [(SpannedSexpr.Cons end finish _)
                          (match (sp-node-get finish)
                            [(SpannedSexpr.Nil _)
                              (if (sexpr-colon?
                                (spanned-sexpr-form (sp-node-get colon)))
                                (match (parse-ast-type-spanned
                                  dispatch
                                  pools
                                  (sp-node-get index-ty))
                                  [(ResultAstType.Ok parsed-index-ty)
                                    (parse-ast-spmd-scan-prefix-binding
                                      dispatch
                                      pools
                                      op
                                      index
                                      parsed-index-ty
                                      (sp-node-get start)
                                      (sp-node-get end)
                                      prefix-binding
                                      value
                                      body)]
                                  [(ResultAstType.Err message)
                                    (ResultAstExpr.Err message)])
                                (ResultAstExpr.Err
                                  "parse: expected ':' in spmd-scan range binding"))]
                            [_
                              (ResultAstExpr.Err
                                "parse: malformed spmd-scan range binding")])]
                        [_
                          (ResultAstExpr.Err
                            "parse: malformed spmd-scan range binding")])]
                    [_
                      (ResultAstExpr.Err
                        "parse: malformed spmd-scan range binding")])]
                [_
                  (ResultAstExpr.Err "parse: malformed spmd-scan range binding")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-scan range binding")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-scan range binding")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-scan range binding")]))

(define (parse-ast-spmd-scan-prefix-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstReduceOp]
  [index : String]
  [index-ty : AstType]
  [start : SpannedSexpr]
  [end : SpannedSexpr]
  [prefix-binding : SpannedSexpr]
  [value : SpannedSexpr]
  [body : SpannedSexpr]) : ResultAstExpr
  (match prefix-binding
    [(SpannedSexpr.BracketList items _)
      (parse-ast-spmd-scan-prefix-binding
        dispatch
        pools
        op
        index
        index-ty
        start
        end
        (sp-node-get items)
        value
        body)]
    [(SpannedSexpr.Cons prefix-node colon-tail _)
      (match (sp-node-get prefix-node)
        [(SpannedSexpr.Sym prefix _)
          (match (sp-node-get colon-tail)
            [(SpannedSexpr.Cons colon prefix-ty-tail _)
              (match (sp-node-get prefix-ty-tail)
                [(SpannedSexpr.Cons prefix-ty init-tail _)
                  (match (sp-node-get init-tail)
                    [(SpannedSexpr.Cons init finish _)
                      (match (sp-node-get finish)
                        [(SpannedSexpr.Nil _)
                          (if (sexpr-colon?
                            (spanned-sexpr-form (sp-node-get colon)))
                            (match (parse-ast-type-spanned
                              dispatch
                              pools
                              (sp-node-get prefix-ty))
                              [(ResultAstType.Ok parsed-prefix-ty)
                                (match (parse-ast-expr-with-pools
                                  dispatch
                                  pools
                                  start)
                                  [(ResultAstExpr.Ok parsed-start)
                                    (match (parse-ast-expr-with-pools
                                      dispatch
                                      pools
                                      end)
                                      [(ResultAstExpr.Ok parsed-end)
                                        (match (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          (sp-node-get init))
                                          [(ResultAstExpr.Ok parsed-init)
                                            (match (parse-ast-expr-with-pools
                                              dispatch
                                              pools
                                              value)
                                              [(ResultAstExpr.Ok parsed-value)
                                                (match (parse-ast-expr-with-pools
                                                  dispatch
                                                  pools
                                                  body)
                                                  [(ResultAstExpr.Ok
                                                      parsed-body)
                                                    (ResultAstExpr.Ok
                                                      (ast-expr-spmd-scan-with-pools
                                                        pools
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
                                                  [(ResultAstExpr.Err message)
                                                    (ResultAstExpr.Err message)])]
                                              [(ResultAstExpr.Err message)
                                                (ResultAstExpr.Err message)])]
                                          [(ResultAstExpr.Err message)
                                            (ResultAstExpr.Err message)])]
                                      [(ResultAstExpr.Err message)
                                        (ResultAstExpr.Err message)])]
                                  [(ResultAstExpr.Err message)
                                    (ResultAstExpr.Err message)])]
                              [(ResultAstType.Err message)
                                (ResultAstExpr.Err message)])
                            (ResultAstExpr.Err
                              "parse: expected ':' in spmd-scan prefix binding"))]
                        [_
                          (ResultAstExpr.Err
                            "parse: malformed spmd-scan prefix binding")])]
                    [_
                      (ResultAstExpr.Err
                        "parse: malformed spmd-scan prefix binding")])]
                [_
                  (ResultAstExpr.Err
                    "parse: malformed spmd-scan prefix binding")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-scan prefix binding")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-scan prefix binding")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-scan prefix binding")]))

(define (parse-ast-spmd-broadcast
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons value-node lane-tail _)
      (match (sp-node-get lane-tail)
        [(SpannedSexpr.Cons lane-node end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (sp-node-get value-node))
                [(ResultAstExpr.Ok value)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get lane-node))
                    [(ResultAstExpr.Ok lane)
                      (ResultAstExpr.Ok
                        (ast-expr-spmd-broadcast-with-pools pools value lane))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-broadcast")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-broadcast")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-broadcast")]))

(define (parse-ast-spmd-shuffle
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons value-node lane-tail _)
      (match (sp-node-get lane-tail)
        [(SpannedSexpr.Cons lane-node end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (sp-node-get value-node))
                [(ResultAstExpr.Ok value)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get lane-node))
                    [(ResultAstExpr.Ok lane)
                      (ResultAstExpr.Ok
                        (ast-expr-spmd-shuffle-with-pools pools value lane))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-shuffle")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-shuffle")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-shuffle")]))

(define (parse-ast-try
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr end _)
      (match (sp-node-get end)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok (ast-expr-try-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: try expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: try expects exactly one expression")]))

(define (parse-ast-return
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr end _)
      (match (sp-node-get end)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok (ast-expr-return-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: return expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: return expects exactly one expression")]))

(define (parse-ast-box-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]
  [is-get : bool]
  [is-take : bool]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr end _)
      (match (sp-node-get end)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (if is-get
                (ResultAstExpr.Ok
                  (ast-expr-box-get-with-pools pools parsed-expr))
                (if is-take
                  (ResultAstExpr.Ok
                    (ast-expr-box-take-with-pools pools parsed-expr))
                  (ResultAstExpr.Ok (ast-expr-box-with-pools pools parsed-expr))))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_
          (ResultAstExpr.Err
            (if is-get
              "parse: box-get expects exactly one expression"
              (if is-take
                "parse: box-take expects exactly one expression"
                "parse: box expects exactly one expression")))])]
    [_
      (ResultAstExpr.Err
        (if is-get
          "parse: box-get expects exactly one expression"
          (if is-take
            "parse: box-take expects exactly one expression"
            "parse: box expects exactly one expression")))]))

;; `(ptr-null : T)` - a colon followed by a pointer type, no leading expression.
;; The parser accepts any type here; the typechecker rejects non-pointer `T`.
(define (parse-ast-ptr-null
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons colon ty-tail _)
      (match (sp-node-get ty-tail)
        [(SpannedSexpr.Cons ty end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (if (sexpr-colon? (spanned-sexpr-form (sp-node-get colon)))
                (match (parse-ast-type-spanned dispatch pools (sp-node-get ty))
                  [(ResultAstType.Ok parsed-ty)
                    (ResultAstExpr.Ok
                      (ast-node-pool-context-expr-push
                        pools
                        (AstExpr.PtrNull parsed-ty)))]
                  [(ResultAstType.Err message) (ResultAstExpr.Err message)])
                (ResultAstExpr.Err "parse: expected ':' in ptr-null"))]
            [_
              (ResultAstExpr.Err
                "parse: ptr-null expects (ptr-null : T) with a pointer type T")])]
        [_
          (ResultAstExpr.Err
            "parse: ptr-null expects (ptr-null : T) with a pointer type T")])]
    [_
      (ResultAstExpr.Err
        "parse: ptr-null expects (ptr-null : T) with a pointer type T")]))

;; `(init : T)` carries an explicit target type. Bare `(init)` is contextual
;; and must be checked/lowered in a position with an expected type.
(define (parse-ast-init
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Nil _)
      (ResultAstExpr.Ok (ast-expr-init-contextual-with-pools pools))]
    [(SpannedSexpr.Cons colon ty-tail _)
      (match (sp-node-get ty-tail)
        [(SpannedSexpr.Cons ty end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (if (sexpr-colon? (spanned-sexpr-form (sp-node-get colon)))
                (match (parse-ast-type-spanned dispatch pools (sp-node-get ty))
                  [(ResultAstType.Ok parsed-ty)
                    (ResultAstExpr.Ok
                      (ast-expr-init-with-pools pools parsed-ty))]
                  [(ResultAstType.Err message) (ResultAstExpr.Err message)])
                (ResultAstExpr.Err "parse: expected ':' in init"))]
            [_ (ResultAstExpr.Err "parse: init expects (init : T)")])]
        [_ (ResultAstExpr.Err "parse: init expects (init : T)")])]
    [_ (ResultAstExpr.Err "parse: init expects (init : T)")]))

;; `(ptr-null? p)` - a single pointer operand.
(define (parse-ast-ptr-null-check
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr end _)
      (match (sp-node-get end)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast-expr-ptr-null-check-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_
          (ResultAstExpr.Err "parse: ptr-null? expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: ptr-null? expects exactly one expression")]))

(define (parse-ast-ptr-read
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr end _)
      (match (sp-node-get end)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast-expr-ptr-read-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: ptr-read expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: ptr-read expects exactly one expression")]))

(define (parse-ast-ptr-addr-of
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons place end _)
      (match (sp-node-get end)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get place))
            [(ResultAstExpr.Ok parsed-place)
              (ResultAstExpr.Ok
                (ast-expr-ptr-addr-of-id-with-pools pools parsed-place))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_
          (ResultAstExpr.Err
            "parse: ptr-addr-of expects exactly one addressable place")])]
    [_
      (ResultAstExpr.Err
        "parse: ptr-addr-of expects exactly one addressable place")]))

(define (parse-ast-ptr-write
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons ptr value-tail _)
      (match (sp-node-get value-tail)
        [(SpannedSexpr.Cons value end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (sp-node-get ptr))
                [(ResultAstExpr.Ok parsed-ptr)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get value))
                    [(ResultAstExpr.Ok parsed-value)
                      (ResultAstExpr.Ok
                        (ast-expr-ptr-write-with-pools
                          pools
                          parsed-ptr
                          parsed-value))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_
              (ResultAstExpr.Err
                "parse: ptr-write! expects exactly two expressions")])]
        [_
          (ResultAstExpr.Err
            "parse: ptr-write! expects exactly two expressions")])]
    [_ (ResultAstExpr.Err "parse: ptr-write! expects exactly two expressions")]))

(define (parse-ast-ptr-offset
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons ptr offset-tail _)
      (match (sp-node-get offset-tail)
        [(SpannedSexpr.Cons offset end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (sp-node-get ptr))
                [(ResultAstExpr.Ok parsed-ptr)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get offset))
                    [(ResultAstExpr.Ok parsed-offset)
                      (ResultAstExpr.Ok
                        (ast-expr-ptr-offset-with-pools
                          pools
                          parsed-ptr
                          parsed-offset))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_
              (ResultAstExpr.Err
                "parse: ptr-offset expects exactly two expressions")])]
        [_
          (ResultAstExpr.Err
            "parse: ptr-offset expects exactly two expressions")])]
    [_ (ResultAstExpr.Err "parse: ptr-offset expects exactly two expressions")]))

(define (parse-ast-ptr-cast-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [is-int-to-ptr : bool]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr colon-tail _)
      (match (sp-node-get colon-tail)
        [(SpannedSexpr.Cons colon ty-tail _)
          (match (sp-node-get ty-tail)
            [(SpannedSexpr.Cons ty end _)
              (match (sp-node-get end)
                [(SpannedSexpr.Nil _)
                  (if (sexpr-colon? (spanned-sexpr-form (sp-node-get colon)))
                    (match (parse-ast-expr-with-pools
                      dispatch
                      pools
                      (sp-node-get expr))
                      [(ResultAstExpr.Ok parsed-expr)
                        (match (parse-ast-type-spanned
                          dispatch
                          pools
                          (sp-node-get ty))
                          [(ResultAstType.Ok parsed-ty)
                            (if is-int-to-ptr
                              (ResultAstExpr.Ok
                                (ast-expr-int-to-ptr-with-pools
                                  pools
                                  parsed-expr
                                  parsed-ty))
                              (ResultAstExpr.Ok
                                (ast-expr-ptr-cast-with-pools
                                  pools
                                  parsed-expr
                                  parsed-ty)))]
                          [(ResultAstType.Err message)
                            (ResultAstExpr.Err message)])]
                      [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])
                    (ResultAstExpr.Err "parse: expected ':' in pointer cast"))]
                [_
                  (ResultAstExpr.Err
                    "parse: pointer cast expects (form expr : pointer-type)")])]
            [_
              (ResultAstExpr.Err
                "parse: pointer cast expects (form expr : pointer-type)")])]
        [_
          (ResultAstExpr.Err
            "parse: pointer cast expects (form expr : pointer-type)")])]
    [_
      (ResultAstExpr.Err
        "parse: pointer cast expects (form expr : pointer-type)")]))

(define (parse-ast-ptr-to-int
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr end _)
      (match (sp-node-get end)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast-expr-ptr-to-int-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: ptr->int expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: ptr->int expects exactly one expression")]))

(define (parse-ast-one-expr
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]
  [name : String]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr end _)
      (match (sp-node-get end)
        [(SpannedSexpr.Nil _)
          (parse-ast-expr-with-pools dispatch pools (sp-node-get expr))]
        [_
          (ResultAstExpr.Err
            (string.append
              "parse: "
              (string.append name " expects exactly one expression")))])]
    [_
      (ResultAstExpr.Err
        (string.append
          "parse: "
          (string.append name " expects exactly one expression")))]))

(define (parse-ast-two-exprs
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]
  [name : String]) : ResultAstExprPair
  (match rest
    [(SpannedSexpr.Cons first second-tail _)
      (match (sp-node-get second-tail)
        [(SpannedSexpr.Cons second end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (sp-node-get first))
                [(ResultAstExpr.Ok parsed-first)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get second))
                    [(ResultAstExpr.Ok parsed-second)
                      (ResultAstExprPair.Ok
                        (AstExprPair parsed-first parsed-second))]
                    [(ResultAstExpr.Err message)
                      (ResultAstExprPair.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExprPair.Err message)])]
            [_
              (ResultAstExprPair.Err
                (string.append
                  "parse: "
                  (string.append name " expects exactly two expressions")))])]
        [_
          (ResultAstExprPair.Err
            (string.append
              "parse: "
              (string.append name " expects exactly two expressions")))])]
    [_
      (ResultAstExprPair.Err
        (string.append
          "parse: "
          (string.append name " expects exactly two expressions")))]))

(define (parse-ast-string-data
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-one-expr dispatch pools rest "string-data")
    [(ResultAstExpr.Ok expr)
      (ResultAstExpr.Ok (ast-expr-string-data-with-pools pools expr))]
    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-string-from-bytes
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-two-exprs dispatch pools rest "string-from-bytes")
    [(ResultAstExprPair.Ok pair)
      (ResultAstExpr.Ok
        (ast-expr-string-from-bytes-with-pools
          pools
          (struct-get pair first)
          (struct-get pair second)))]
    [(ResultAstExprPair.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-array-data
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-one-expr dispatch pools rest "array-data")
    [(ResultAstExpr.Ok expr)
      (ResultAstExpr.Ok (ast-expr-array-data-with-pools pools expr))]
    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-no-arg-low-level
  [rest : SpannedSexpr]
  [name : String]
  [expr : i64]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Nil _) (ResultAstExpr.Ok expr)]
    [_
      (ResultAstExpr.Err
        (string.append "parse: " (string.append name " expects no arguments")))]))

(define (parse-ast-cpuid-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [tag : i64]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-two-exprs dispatch pools rest "cpuid")
    [(ResultAstExprPair.Ok pair)
      (let
        [leaf : i64 (struct-get pair first)]
        [subleaf : i64 (struct-get pair second)]
        (cond
          [(= tag (compiler-parse-tag-expr-cpuid-eax))
            (ResultAstExpr.Ok
              (ast-expr-cpuid-eax-with-pools pools leaf subleaf))]
          [(= tag (compiler-parse-tag-expr-cpuid-ebx))
            (ResultAstExpr.Ok
              (ast-expr-cpuid-ebx-with-pools pools leaf subleaf))]
          [(= tag (compiler-parse-tag-expr-cpuid-ecx))
            (ResultAstExpr.Ok
              (ast-expr-cpuid-ecx-with-pools pools leaf subleaf))]
          [else
            (ResultAstExpr.Ok
              (ast-expr-cpuid-edx-with-pools pools leaf subleaf))]))]
    [(ResultAstExprPair.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-xgetbv
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-one-expr dispatch pools rest "xgetbv")
    [(ResultAstExpr.Ok expr)
      (ResultAstExpr.Ok (ast-expr-xgetbv-with-pools pools expr))]
    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-syscall-count [args : AstExprList]) : i64
  (struct-get (& args) len))

;; `(syscall number a0 .. a5)`: the syscall number followed by up to six
;; arguments (1 to 7 operands total). Typechecking requires an enclosing
;; `(unsafe ...)` context before this lowers to a raw `syscall` instruction.
(define (parse-ast-syscall
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok args)
      (let
        [count : i64 (parse-ast-syscall-count args)]
        (if (< count 1)
          (ResultAstExpr.Err "parse: syscall requires a syscall number")
          (if (> count 7)
            (ResultAstExpr.Err
              "parse: syscall takes at most 7 operands (number plus six arguments)")
            (ResultAstExpr.Ok (ast-expr-syscall-with-pools pools args)))))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-with-region
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Nil _)
      (ResultAstExpr.Err
        "parse: with-arena requires a region name before its body")]
    [(SpannedSexpr.Cons _ _ _)
      (match rest
        [(SpannedSexpr.Cons region-node body _)
          (match (sp-node-get region-node)
            [(SpannedSexpr.Sym region _)
              (match (sp-node-get body)
                [(SpannedSexpr.Nil _)
                  (ResultAstExpr.Err
                    (string.append
                      "parse: with-arena '"
                      (string.append region "' requires a non-empty body")))]
                [_
                  (match (parse-ast-expr-list dispatch pools (sp-node-get body))
                    [(ResultAstExprList.Ok exprs)
                      (ResultAstExpr.Ok
                        (ast-node-pool-context-expr-push
                          pools
                          (AstExpr.WithRegion region exprs)))]
                    [(ResultAstExprList.Err message)
                      (ResultAstExpr.Err message)])])]
            [_
              (ResultAstExpr.Err
                "parse: with-arena region name must be an identifier")])]
        [_ (ResultAstExpr.Err "parse: malformed with-arena")])]
    [_ (ResultAstExpr.Err "parse: malformed with-arena")]))

(define (parse-ast-with-escape
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Nil _)
      (ResultAstExpr.Err
        "parse: with-escape requires a scratch arena before its body")]
    [(SpannedSexpr.Cons scratch body _)
      (match (sp-node-get body)
        [(SpannedSexpr.Nil _)
          (ResultAstExpr.Err "parse: with-escape requires a non-empty body")]
        [_
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (sp-node-get scratch))
            [(ResultAstExpr.Ok parsed-scratch)
              (match (parse-ast-expr-list dispatch pools (sp-node-get body))
                [(ResultAstExprList.Ok exprs)
                  (ResultAstExpr.Ok
                    (ast-expr-with-escape-with-pools pools parsed-scratch exprs))]
                [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])])]
    [_ (ResultAstExpr.Err "parse: malformed with-escape")]))

(define (parse-ast-with-scratch
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Nil _)
      (ResultAstExpr.Err "parse: with-scratch requires a non-empty body")]
    [(SpannedSexpr.Cons _ _ _)
      (match (parse-ast-expr-list dispatch pools rest)
        [(ResultAstExprList.Ok exprs)
          (ResultAstExpr.Ok (ast-expr-with-scratch-with-pools pools exprs))]
        [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed with-scratch")]))

(define (parse-ast-in-arena
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Nil _)
      (ResultAstExpr.Err "parse: in-arena requires an arena before its body")]
    [(SpannedSexpr.Cons arena body _)
      (match (sp-node-get body)
        [(SpannedSexpr.Nil _)
          (ResultAstExpr.Err "parse: in-arena requires a non-empty body")]
        [_
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get arena))
            [(ResultAstExpr.Ok parsed-arena)
              (match (parse-ast-expr-list dispatch pools (sp-node-get body))
                [(ResultAstExprList.Ok exprs)
                  (ResultAstExpr.Ok
                    (ast-expr-in-arena-with-pools pools parsed-arena exprs))]
                [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])])]
    [_ (ResultAstExpr.Err "parse: malformed in-arena")]))

(define (parse-ast-resource-binding-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : SpannedSexpr]) : ResultAstResourceBinding
  (match items
    [(SpannedSexpr.Cons _ _ _)
      (match items
        [(SpannedSexpr.Cons name-node rest _)
          (match (sp-node-get name-node)
            [(SpannedSexpr.Sym name _)
              (match (sp-node-get rest)
                [(SpannedSexpr.Nil _)
                  (ResultAstResourceBinding.Err
                    "parse: with binding is missing initializer")]
                [(SpannedSexpr.Cons init tail _)
                  (match (sp-node-get tail)
                    [(SpannedSexpr.Nil _)
                      (ResultAstResourceBinding.Err
                        "parse: with binding is missing cleanup function")]
                    [(SpannedSexpr.Cons cleanup extra _)
                      (match (sp-node-get extra)
                        [(SpannedSexpr.Nil _)
                          (match (parse-ast-expr-with-pools
                            dispatch
                            pools
                            (sp-node-get init))
                            [(ResultAstExpr.Ok parsed-init)
                              (match (parse-ast-expr-with-pools
                                dispatch
                                pools
                                (sp-node-get cleanup))
                                [(ResultAstExpr.Ok parsed-cleanup)
                                  (ResultAstResourceBinding.Ok
                                    (ast-resource-binding
                                      name
                                      parsed-init
                                      parsed-cleanup))]
                                [(ResultAstExpr.Err message)
                                  (ResultAstResourceBinding.Err message)])]
                            [(ResultAstExpr.Err message)
                              (ResultAstResourceBinding.Err message)])]
                        [_
                          (ResultAstResourceBinding.Err
                            "parse: with binding has too many fields")])]
                    [_
                      (ResultAstResourceBinding.Err
                        "parse: malformed with binding")])]
                [_
                  (ResultAstResourceBinding.Err "parse: malformed with binding")])]
            [_
              (ResultAstResourceBinding.Err
                "parse: with binding name must be an identifier")])]
        [_ (ResultAstResourceBinding.Err "parse: malformed with binding")])]
    [_ (ResultAstResourceBinding.Err "parse: malformed with binding")]))

(define (parse-ast-resource-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [binding : SpannedSexpr]) : ResultAstResourceBinding
  (match binding
    [(SpannedSexpr.BracketList items _)
      (parse-ast-resource-binding-items dispatch pools (sp-node-get items))]
    [_
      (ResultAstResourceBinding.Err
        "parse: with binding must use bracket syntax")]))

(define (parse-ast-resource-binding-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [bindings : SpannedSexpr]
  [out : (&mut out AstResourceBindingList)]) : ResultAstResourceBindingListBuild
  (match bindings
    [(SpannedSexpr.Nil _) (ResultAstResourceBindingListBuild.Ok)]
    [(SpannedSexpr.Cons head rest _)
      (match (parse-ast-resource-binding dispatch pools (sp-node-get head))
        [(ResultAstResourceBinding.Ok parsed-head)
          (begin
            (ast-resource-binding-list-push out parsed-head)
            (parse-ast-resource-binding-list-into
              dispatch
              pools
              (sp-node-get rest)
              out))]
        [(ResultAstResourceBinding.Err message)
          (ResultAstResourceBindingListBuild.Err message)])]
    [_
      (ResultAstResourceBindingListBuild.Err
        "parse: malformed with binding list")]))

(define (parse-ast-resource-binding-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [bindings : SpannedSexpr]) : ResultAstResourceBindingList
  (let
    [out : AstResourceBindingList (ast-resource-binding-list-new)]
    (match (parse-ast-resource-binding-list-into
      dispatch
      pools
      bindings
      (&mut out))
      [(ResultAstResourceBindingListBuild.Ok)
        (ResultAstResourceBindingList.Ok out)]
      [(ResultAstResourceBindingListBuild.Err message)
        (ResultAstResourceBindingList.Err message)])))

(define (parse-ast-with-resource
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Nil _)
      (ResultAstExpr.Err "parse: with requires a binding list before its body")]
    [(SpannedSexpr.Cons bindings body _)
      (match (sp-node-get bindings)
        [(SpannedSexpr.Nil _)
          (ResultAstExpr.Err "parse: with requires a non-empty binding list")]
        [(SpannedSexpr.Cons _ _ _)
          (match (sp-node-get body)
            [(SpannedSexpr.Nil _)
              (ResultAstExpr.Err "parse: with requires a non-empty body")]
            [_
              (match (parse-ast-resource-binding-list
                dispatch
                pools
                (sp-node-get bindings))
                [(ResultAstResourceBindingList.Ok parsed-bindings)
                  (match (parse-ast-expr-list dispatch pools (sp-node-get body))
                    [(ResultAstExprList.Ok parsed-body)
                      (ResultAstExpr.Ok
                        (ast-node-pool-context-expr-push
                          pools
                          (AstExpr.WithResource
                            (box
                              (AstWithResource.WithResource
                                parsed-bindings
                                parsed-body)))))]
                    [(ResultAstExprList.Err message)
                      (ResultAstExpr.Err message)])]
                [(ResultAstResourceBindingList.Err message)
                  (ResultAstExpr.Err message)])])]
        [_ (ResultAstExpr.Err "parse: malformed with binding list")])]
    [_ (ResultAstExpr.Err "parse: malformed with")]))

(define (parse-ast-match-arm
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]) : ResultAstMatchArm
  (match s
    [(SpannedSexpr.BracketList items _)
      (parse-ast-match-arm dispatch pools (sp-node-get items))]
    [(SpannedSexpr.Cons pattern body-tail _)
      (match (sp-node-get body-tail)
        [(SpannedSexpr.Cons body end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (parse-ast-pattern
                dispatch
                pools
                (spanned-sexpr-form (sp-node-get pattern)))
                [(ResultAstPattern.Ok parsed-pattern)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (sp-node-get body))
                    [(ResultAstExpr.Ok parsed-body)
                      (ResultAstMatchArm.Ok
                        (ast-match-arm parsed-pattern parsed-body))]
                    [(ResultAstExpr.Err message)
                      (ResultAstMatchArm.Err message)])]
                [(ResultAstPattern.Err message) (ResultAstMatchArm.Err message)])]
            [_ (ResultAstMatchArm.Err "parse: malformed match arm")])]
        [_ (ResultAstMatchArm.Err "parse: malformed match arm")])]
    [_ (ResultAstMatchArm.Err "parse: malformed match arm")]))

(define (parse-ast-match-arm-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]
  [out : (&mut out AstMatchArmList)]) : ResultAstMatchArmListBuild
  (match s
    [(SpannedSexpr.Nil _) (ResultAstMatchArmListBuild.Ok)]
    [(SpannedSexpr.Cons head tail _)
      (match (parse-ast-match-arm dispatch pools (sp-node-get head))
        [(ResultAstMatchArm.Ok parsed-head)
          (begin
            (ast-match-arm-list-push out parsed-head)
            (parse-ast-match-arm-list-into
              dispatch
              pools
              (sp-node-get tail)
              out))]
        [(ResultAstMatchArm.Err message)
          (ResultAstMatchArmListBuild.Err message)])]
    [_ (ResultAstMatchArmListBuild.Err "parse: malformed match arm list")]))

(define (parse-ast-match-arm-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]) : ResultAstMatchArmList
  (let
    [out : AstMatchArmList (ast-match-arm-list-new)]
    (match (parse-ast-match-arm-list-into dispatch pools s (&mut out))
      [(ResultAstMatchArmListBuild.Ok) (ResultAstMatchArmList.Ok out)]
      [(ResultAstMatchArmListBuild.Err message)
        (ResultAstMatchArmList.Err message)])))

(define (parse-ast-match
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons scrutinee arms _)
      (match (parse-ast-expr-with-pools dispatch pools (sp-node-get scrutinee))
        [(ResultAstExpr.Ok parsed-scrutinee)
          (match (parse-ast-match-arm-list dispatch pools (sp-node-get arms))
            [(ResultAstMatchArmList.Ok parsed-arms)
              (ResultAstExpr.Ok
                (ast-expr-match-with-pools pools parsed-scrutinee parsed-arms))]
            [(ResultAstMatchArmList.Err message) (ResultAstExpr.Err message)])]
        [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed match")]))

(define (parse-ast-foreach-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [binding : SpannedSexpr]
  [body : SpannedSexpr]) : ResultAstExpr
  (match binding
    [(SpannedSexpr.BracketList items _)
      (parse-ast-foreach-binding dispatch pools (sp-node-get items) body)]
    [(SpannedSexpr.Cons index-node colon-tail _)
      (match (sp-node-get index-node)
        [(SpannedSexpr.Sym index _)
          (match (sp-node-get colon-tail)
            [(SpannedSexpr.Cons colon index-ty-tail _)
              (match (sp-node-get index-ty-tail)
                [(SpannedSexpr.Cons index-ty start-tail _)
                  (match (sp-node-get start-tail)
                    [(SpannedSexpr.Cons start end-tail _)
                      (match (sp-node-get end-tail)
                        [(SpannedSexpr.Cons end finish _)
                          (match (sp-node-get finish)
                            [(SpannedSexpr.Nil _)
                              (if (sexpr-colon?
                                (spanned-sexpr-form (sp-node-get colon)))
                                (match (parse-ast-type-spanned
                                  dispatch
                                  pools
                                  (sp-node-get index-ty))
                                  [(ResultAstType.Ok parsed-index-ty)
                                    (match (parse-ast-expr-with-pools
                                      dispatch
                                      pools
                                      (sp-node-get start))
                                      [(ResultAstExpr.Ok parsed-start)
                                        (match (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          (sp-node-get end))
                                          [(ResultAstExpr.Ok parsed-end)
                                            (match (parse-ast-expr-with-pools
                                              dispatch
                                              pools
                                              body)
                                              [(ResultAstExpr.Ok parsed-body)
                                                (ResultAstExpr.Ok
                                                  (ast-expr-foreach-with-pools
                                                    pools
                                                    index
                                                    parsed-index-ty
                                                    parsed-start
                                                    parsed-end
                                                    parsed-body))]
                                              [(ResultAstExpr.Err message)
                                                (ResultAstExpr.Err message)])]
                                          [(ResultAstExpr.Err message)
                                            (ResultAstExpr.Err message)])]
                                      [(ResultAstExpr.Err message)
                                        (ResultAstExpr.Err message)])]
                                  [(ResultAstType.Err message)
                                    (ResultAstExpr.Err message)])
                                (ResultAstExpr.Err
                                  "parse: expected ':' in foreach"))]
                            [_
                              (ResultAstExpr.Err
                                "parse: malformed foreach binding")])]
                        [_
                          (ResultAstExpr.Err "parse: malformed foreach binding")])]
                    [_ (ResultAstExpr.Err "parse: malformed foreach binding")])]
                [_ (ResultAstExpr.Err "parse: malformed foreach binding")])]
            [_ (ResultAstExpr.Err "parse: malformed foreach binding")])]
        [_ (ResultAstExpr.Err "parse: malformed foreach binding")])]
    [_ (ResultAstExpr.Err "parse: malformed foreach binding")]))

(define (parse-ast-foreach
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons binding-list body-tail _)
      (match (sp-node-get binding-list)
        [(SpannedSexpr.Cons binding binding-end _)
          (match (sp-node-get binding-end)
            [(SpannedSexpr.Nil _)
              (match (sp-node-get body-tail)
                [(SpannedSexpr.Cons body end _)
                  (match (sp-node-get end)
                    [(SpannedSexpr.Nil _)
                      (parse-ast-foreach-binding
                        dispatch
                        pools
                        (sp-node-get binding)
                        (sp-node-get body))]
                    [_ (ResultAstExpr.Err "parse: malformed foreach")])]
                [_ (ResultAstExpr.Err "parse: malformed foreach")])]
            [_ (ResultAstExpr.Err "parse: malformed foreach")])]
        [_ (ResultAstExpr.Err "parse: malformed foreach")])]
    [_ (ResultAstExpr.Err "parse: malformed foreach")]))

(define (parse-ast-call
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-with-pools dispatch pools head)
    [(ResultAstExpr.Ok parsed-head)
      (match (parse-ast-call-arg-list dispatch pools rest)
        [(ResultAstExprList.Ok parsed-args)
          (ResultAstExpr.Ok
            (ast-expr-call-with-pools pools parsed-head parsed-args))]
        [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]
    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-begin
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok exprs)
      (ResultAstExpr.Ok
        (ast-node-pool-context-expr-push pools (AstExpr.Begin exprs)))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

;; `(unsafe expr+)` parses like `begin` but requires a non-empty body. It has
;; the same behavior as `begin`; it marks an unsafe context for later raw-pointer
;; ops.
(define (parse-ast-unsafe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Nil _)
      (ResultAstExpr.Err "parse: unsafe requires a non-empty body")]
    [_
      (match (parse-ast-expr-list dispatch pools rest)
        [(ResultAstExprList.Ok exprs)
          (ResultAstExpr.Ok
            (ast-node-pool-context-expr-push pools (AstExpr.Unsafe exprs)))]
        [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]))

(define (parse-ast-tuple
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok exprs)
      (ResultAstExpr.Ok
        (ast-node-pool-context-expr-push pools (AstExpr.Tuple exprs)))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-array
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok exprs)
      (ResultAstExpr.Ok
        (ast-node-pool-context-expr-push pools (AstExpr.Array exprs)))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-quote-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [tag : i64]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match rest
    [(SpannedSexpr.Cons expr end _)
      (match (sp-node-get end)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get expr))
            [(ResultAstExpr.Ok parsed)
              (cond
                [(= tag (compiler-parse-tag-expr-quote))
                  (ResultAstExpr.Ok (ast-expr-quote-with-pools pools parsed))]
                [(= tag (compiler-parse-tag-expr-quasiquote))
                  (ResultAstExpr.Ok
                    (ast-expr-quasiquote-with-pools pools parsed))]
                [(= tag (compiler-parse-tag-expr-unquote))
                  (ResultAstExpr.Ok (ast-expr-unquote-with-pools pools parsed))]
                [else
                  (ResultAstExpr.Ok
                    (ast-expr-unquote-splicing-with-pools pools parsed))])]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_
          (ResultAstExpr.Err "parse: quote form expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: quote form expects exactly one expression")]))

(define (parse-ast-list-expr-tag
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [tag : i64]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstExpr
  (cond
    [(= tag (compiler-parse-tag-expr-if)) (parse-ast-if dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-let)) (parse-ast-let dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-lambda))
      (parse-ast-lambda dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-while))
      (parse-ast-while dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-begin))
      (parse-ast-begin dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-unsafe))
      (parse-ast-unsafe dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-set)) (parse-ast-set dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-ann))
      (parse-ast-ann-like dispatch pools false rest)]
    [(= tag (compiler-parse-tag-expr-cast))
      (parse-ast-ann-like dispatch pools true rest)]
    [(= tag (compiler-parse-tag-expr-tuple))
      (parse-ast-tuple dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-tuple-ref))
      (parse-ast-tuple-ref dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array))
      (parse-ast-array dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-make-array))
      (parse-ast-make-array dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array-ref))
      (parse-ast-array-ref-like dispatch pools false rest)]
    [(= tag (compiler-parse-tag-expr-array-set))
      (parse-ast-array-set dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array-push))
      (parse-ast-array-push dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array-take))
      (parse-ast-array-take dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-match))
      (parse-ast-match dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-foreach))
      (parse-ast-foreach dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-reduce))
      (parse-ast-spmd-reduce dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-scan))
      (parse-ast-spmd-scan dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-broadcast))
      (parse-ast-spmd-broadcast dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-shuffle))
      (parse-ast-spmd-shuffle dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-program-index))
      (parse-ast-no-arg-low-level
        rest
        "program-index"
        (ast-expr-spmd-program-index-with-pools pools))]
    [(= tag (compiler-parse-tag-expr-spmd-program-count))
      (parse-ast-no-arg-low-level
        rest
        "program-count"
        (ast-expr-spmd-program-count-with-pools pools))]
    [(= tag (compiler-parse-tag-expr-struct-get))
      (parse-ast-struct-get dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-comptime))
      (parse-ast-comptime dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-type-literal))
      (parse-ast-type-literal dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-with-region))
      (parse-ast-with-region dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-with-escape))
      (parse-ast-with-escape dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-with-scratch))
      (parse-ast-with-scratch dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-in-arena))
      (parse-ast-in-arena dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-with-resource))
      (parse-ast-with-resource dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-quote))
      (parse-ast-quote-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-quasiquote))
      (parse-ast-quote-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-unquote))
      (parse-ast-quote-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-unquote-splicing))
      (parse-ast-quote-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-try)) (parse-ast-try dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-return))
      (parse-ast-return dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-break))
      (parse-ast-no-arg-low-level
        rest
        "break"
        (ast-expr-break-with-pools pools))]
    [(= tag (compiler-parse-tag-expr-continue))
      (parse-ast-no-arg-low-level
        rest
        "continue"
        (ast-expr-continue-with-pools pools))]
    [(= tag (compiler-parse-tag-expr-box))
      (parse-ast-box-like dispatch pools rest false false)]
    [(= tag (compiler-parse-tag-expr-box-get))
      (parse-ast-box-like dispatch pools rest true false)]
    [(= tag (compiler-parse-tag-expr-box-take))
      (parse-ast-box-like dispatch pools rest false true)]
    [(= tag (compiler-parse-tag-expr-string-data))
      (parse-ast-string-data dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-string-from-bytes))
      (parse-ast-string-from-bytes dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array-data))
      (parse-ast-array-data dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-program-argc))
      (parse-ast-no-arg-low-level
        rest
        "program-argc"
        (ast-node-pool-context-expr-push pools (AstExpr.ProgramArgc)))]
    [(= tag (compiler-parse-tag-expr-program-argv))
      (parse-ast-no-arg-low-level
        rest
        "program-argv"
        (ast-node-pool-context-expr-push pools (AstExpr.ProgramArgv)))]
    [(= tag (compiler-parse-tag-expr-program-envp))
      (parse-ast-no-arg-low-level
        rest
        "program-envp"
        (ast-node-pool-context-expr-push pools (AstExpr.ProgramEnvp)))]
    [(= tag (compiler-parse-tag-expr-cpuid-eax))
      (parse-ast-cpuid-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-ebx))
      (parse-ast-cpuid-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-ecx))
      (parse-ast-cpuid-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-edx))
      (parse-ast-cpuid-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-xgetbv))
      (parse-ast-xgetbv dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-syscall))
      (parse-ast-syscall dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-init))
      (parse-ast-init dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-ptr-null))
      (parse-ast-ptr-null dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-ptr-null-check))
      (parse-ast-ptr-null-check dispatch pools rest)]
    [(= tag (compiler-parse-tag-decl-comptime-decl))
      (ResultAstExpr.Err
        "parse: comptime-decl is only valid as a top-level declaration")]
    [(= tag (compiler-parse-tag-decl-comptime-decls))
      (ResultAstExpr.Err (parse-ast-comptime-decls-removed-message))]
    [else (parse-ast-call dispatch pools head rest)]))

(define (parse-ast-list-expr
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstExpr
  (match head
    [(SpannedSexpr.Sym op _)
      (if (string.eq op "init")
        (match rest
          [(SpannedSexpr.Cons first _ _)
            (if (sexpr-colon? (spanned-sexpr-form (sp-node-get first)))
              (parse-ast-init dispatch pools rest)
              (parse-ast-call dispatch pools head rest))]
          [(SpannedSexpr.Nil _) (parse-ast-init dispatch pools rest)]
          [_ (parse-ast-call dispatch pools head rest)])
        (let
          [tag : i64 (compiler-parse-dispatch-tag dispatch op)]
          (cond
            [(= tag (compiler-parse-tag-expr-ptr-addr-of))
              (parse-ast-ptr-addr-of dispatch pools rest)]
            [(= tag (compiler-parse-tag-expr-ptr-read))
              (parse-ast-ptr-read dispatch pools rest)]
            [(= tag (compiler-parse-tag-expr-ptr-write))
              (parse-ast-ptr-write dispatch pools rest)]
            [(= tag (compiler-parse-tag-expr-ptr-offset))
              (parse-ast-ptr-offset dispatch pools rest)]
            [(= tag (compiler-parse-tag-expr-ptr-cast))
              (parse-ast-ptr-cast-like dispatch pools false rest)]
            [(= tag (compiler-parse-tag-expr-ptr-to-int))
              (parse-ast-ptr-to-int dispatch pools rest)]
            [(= tag (compiler-parse-tag-expr-int-to-ptr))
              (parse-ast-ptr-cast-like dispatch pools true rest)]
            [(ast-unop-tag? tag)
              (parse-ast-unary dispatch pools (ast-unop-from-tag tag) rest)]
            [(ast-binop-tag? tag)
              (if (ast-left-fold-binop-tag? tag)
                (parse-ast-binary-left-fold
                  dispatch
                  pools
                  (ast-binop-from-tag tag)
                  rest)
                (parse-ast-binary dispatch pools (ast-binop-from-tag tag) rest))]
            [(= tag (compiler-parse-tag-ty-ref))
              (parse-ast-borrow dispatch pools false rest)]
            [(= tag (compiler-parse-tag-ty-mut-ref))
              (parse-ast-borrow dispatch pools true rest)]
            [else (parse-ast-list-expr-tag dispatch pools tag head rest)])))]
    [_ (parse-ast-call dispatch pools head rest)]))

(define (parse-ast-expr-with-pools
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]) : ResultAstExpr
  (let
    [result : ResultAstExpr
      (match s
        [(SpannedSexpr.Int n text _)
          (ResultAstExpr.Ok
            (ast-expr-wrap-span
              pools
              (ast-node-pool-context-expr-push
                pools
                (AstExpr.Literal (AstLiteral.Int n text)))
              s))]
        [(SpannedSexpr.Float text _)
          (ResultAstExpr.Ok
            (ast-expr-wrap-span
              pools
              (ast-node-pool-context-expr-push
                pools
                (AstExpr.Literal (AstLiteral.Float text)))
              s))]
        [(SpannedSexpr.Str text _)
          (ResultAstExpr.Ok
            (ast-expr-wrap-span
              pools
              (ast-node-pool-context-expr-push
                pools
                (AstExpr.Literal (AstLiteral.String text)))
              s))]
        [(SpannedSexpr.Char c _)
          (ResultAstExpr.Ok
            (ast-expr-wrap-span
              pools
              (ast-node-pool-context-expr-push
                pools
                (AstExpr.Literal (AstLiteral.Char c)))
              s))]
        [(SpannedSexpr.Sym name _)
          (let
            [tag : i64 (compiler-parse-dispatch-tag dispatch name)]
            (cond
              [(= tag (compiler-parse-tag-lit-true))
                (ResultAstExpr.Ok
                  (ast-expr-wrap-span
                    pools
                    (ast-node-pool-context-expr-push
                      pools
                      (AstExpr.Literal (AstLiteral.Bool true)))
                    s))]
              [(= tag (compiler-parse-tag-lit-false))
                (ResultAstExpr.Ok
                  (ast-expr-wrap-span
                    pools
                    (ast-node-pool-context-expr-push
                      pools
                      (AstExpr.Literal (AstLiteral.Bool false)))
                    s))]
              [(= tag (compiler-parse-tag-unit))
                (ResultAstExpr.Ok
                  (ast-expr-wrap-span
                    pools
                    (ast-node-pool-context-expr-push
                      pools
                      (AstExpr.Literal AstLiteral.Unit))
                    s))]
              [else
                (ResultAstExpr.Ok
                  (ast-expr-wrap-span
                    pools
                    (ast-node-pool-context-expr-push
                      pools
                      (AstExpr.Var (intern name)))
                    s))]))]
        [(SpannedSexpr.Cons head rest _)
          (match (sp-node-get head)
            [(SpannedSexpr.Sym op _)
              (if (string.eq op "cfg")
                (match (parse-ast-cfg-expr dispatch pools (sp-node-get rest))
                  [(ResultAstExpr.Ok parsed)
                    (ResultAstExpr.Ok (ast-expr-wrap-span pools parsed s))]
                  [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])
                (match (parse-ast-list-expr
                  dispatch
                  pools
                  (sp-node-get head)
                  (sp-node-get rest))
                  [(ResultAstExpr.Ok parsed)
                    (ResultAstExpr.Ok (ast-expr-wrap-span pools parsed s))]
                  [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))]
            [_
              (match (parse-ast-list-expr
                dispatch
                pools
                (sp-node-get head)
                (sp-node-get rest))
                [(ResultAstExpr.Ok parsed)
                  (ResultAstExpr.Ok (ast-expr-wrap-span pools parsed s))]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])])]
        [_ (ResultAstExpr.Err "parse: malformed expression")])]
    (parse-ast-error-span-note-expr s result)))

(define (parse-ast-expr [dispatch : sym_i64_env.SymI64Env] [s : SpannedSexpr]) : ResultAstExpr
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstExpr (parse-ast-expr-with-pools dispatch pools s)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-define-value
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [name : String]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Cons first tail _)
      (match (sp-node-get tail)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools (sp-node-get first))
            [(ResultAstExpr.Ok parsed-value)
              (ResultAstDecl.Ok
                (ast-decl-def name AstMaybeType.No parsed-value))]
            [(ResultAstExpr.Err message) (ResultAstDecl.Err message)])]
        [(SpannedSexpr.Cons ty value-tail _)
          (match (sp-node-get value-tail)
            [(SpannedSexpr.Cons value end _)
              (match (sp-node-get end)
                [(SpannedSexpr.Nil _)
                  (if (sexpr-colon? (spanned-sexpr-form (sp-node-get first)))
                    (match (parse-ast-type-spanned
                      dispatch
                      pools
                      (sp-node-get ty))
                      [(ResultAstType.Ok parsed-ty)
                        (match (parse-ast-expr-with-pools
                          dispatch
                          pools
                          (sp-node-get value))
                          [(ResultAstExpr.Ok parsed-value)
                            (ResultAstDecl.Ok
                              (ast-decl-def
                                name
                                (AstMaybeType.Some parsed-ty)
                                parsed-value))]
                          [(ResultAstExpr.Err message)
                            (ResultAstDecl.Err message)])]
                      [(ResultAstType.Err message) (ResultAstDecl.Err message)])
                    (ResultAstDecl.Err "parse: expected ':' in definition"))]
                [_ (ResultAstDecl.Err "parse: malformed value definition")])]
            [_ (ResultAstDecl.Err "parse: malformed value definition")])]
        [_ (ResultAstDecl.Err "parse: malformed value definition")])]
    [_ (ResultAstDecl.Err "parse: malformed value definition")]))

(define (parse-ast-define-fn-export-tail [tail : Sexpr]) : ResultAstFnExport
  (match tail
    [(Sexpr.Cons value-node end)
      (match (box-get end)
        [(Sexpr.Nil)
          (match (box-get value-node)
            [(Sexpr.Str value)
              (if (> (string.string-length value) 0)
                (ResultAstFnExport.Ok (ast-fn-export value))
                (ResultAstFnExport.Err
                  "parse: define :export-symbol must not be empty"))]
            [_
              (ResultAstFnExport.Err
                "parse: malformed define :export-symbol metadata")])]
        [_
          (ResultAstFnExport.Err
            "parse: malformed define :export-symbol metadata")])]
    [_
      (ResultAstFnExport.Err "parse: malformed define :export-symbol metadata")]))

(define (parse-ast-define-fn-metadata? [item : SpannedSexpr]) : bool
  (match (spanned-sexpr-form item)
    [(Sexpr.Cons key-node _)
      (match (box-get key-node)
        [(Sexpr.Sym key) (compiler-parse-metadata-key? key)]
        [_ false])]
    [_ false]))

(define (parse-ast-define-fn-finish
  [name : String]
  [params : AstParamList]
  [ret : AstType]
  [body : i64]
  [export : AstFnExport]) : ResultAstDecl
  (match export
    [(AstFnExport.No)
      (ResultAstDecl.Ok (ast-decl-def-fn-export name params ret body export))]
    [(AstFnExport.Export _)
      (if (ast-param-list-has-comptime? params)
        (ResultAstDecl.Err
          "parse: define :export-symbol cannot be used on functions with comptime parameters")
        (ResultAstDecl.Ok (ast-decl-def-fn-export name params ret body export)))]))

(define (parse-ast-define-fn-rest
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [name : String]
  [params : AstParamList]
  [export : AstFnExport]
  [seen-export : bool]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Cons first tail _)
      (if (sexpr-colon? (spanned-sexpr-form (sp-node-get first)))
        (match (sp-node-get tail)
          [(SpannedSexpr.Cons ret body-tail _)
            (match (parse-ast-type-spanned dispatch pools (sp-node-get ret))
              [(ResultAstType.Ok parsed-ret)
                (match (parse-ast-body-tail
                  dispatch
                  pools
                  (sp-node-get body-tail)
                  "parse: malformed function definition")
                  [(ResultAstExpr.Ok parsed-body)
                    (parse-ast-define-fn-finish
                      name
                      params
                      parsed-ret
                      parsed-body
                      export)]
                  [(ResultAstExpr.Err message) (ResultAstDecl.Err message)])]
              [(ResultAstType.Err message) (ResultAstDecl.Err message)])]
          [_ (ResultAstDecl.Err "parse: malformed function definition")])
        (if (parse-ast-define-fn-metadata? (sp-node-get first))
          (match (spanned-sexpr-form (sp-node-get first))
            [(Sexpr.Cons key-node after-key)
              (match (box-get key-node)
                [(Sexpr.Sym key)
                  (if (string.eq key ":export-symbol")
                    (if seen-export
                      (ResultAstDecl.Err
                        "parse: duplicate define :export-symbol metadata")
                      (match (parse-ast-define-fn-export-tail
                        (box-get after-key))
                        [(ResultAstFnExport.Ok parsed-export)
                          (parse-ast-define-fn-rest
                            dispatch
                            pools
                            name
                            params
                            parsed-export
                            true
                            (sp-node-get tail))]
                        [(ResultAstFnExport.Err message)
                          (ResultAstDecl.Err message)]))
                    (if (compiler-parse-metadata-key? key)
                      (ResultAstDecl.Err
                        (string.append "parse: unknown define metadata " key))
                      (ResultAstDecl.Err
                        "parse: malformed define :export-symbol metadata")))]
                [_ (ResultAstDecl.Err "parse: malformed function definition")])]
            [_ (ResultAstDecl.Err "parse: malformed function definition")])
          (match (parse-ast-body-tail
            dispatch
            pools
            rest
            "parse: malformed function definition")
            [(ResultAstExpr.Ok parsed-body)
              (parse-ast-define-fn-finish
                name
                params
                (AstType.Unit)
                parsed-body
                export)]
            [(ResultAstExpr.Err message) (ResultAstDecl.Err message)])))]
    [_ (ResultAstDecl.Err "parse: malformed function definition")]))

(define (parse-ast-define-fn
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [name : String]
  [params : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-param-list dispatch pools (spanned-sexpr-form params))
    [(ResultAstParamList.Ok parsed-params)
      (parse-ast-define-fn-rest
        dispatch
        pools
        name
        parsed-params
        AstFnExport.No
        false
        rest)]
    [(ResultAstParamList.Err message) (ResultAstDecl.Err message)]))

(define (parse-ast-define
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Cons head after-name _)
      (match (sp-node-get head)
        [(SpannedSexpr.Sym name _)
          (parse-ast-define-value dispatch pools name (sp-node-get after-name))]
        [(SpannedSexpr.Cons name-node params _)
          (match (sp-node-get name-node)
            [(SpannedSexpr.Sym name _)
              (parse-ast-define-fn
                dispatch
                pools
                name
                (sp-node-get params)
                (sp-node-get after-name))]
            [_ (ResultAstDecl.Err "parse: malformed define")])]
        [_ (ResultAstDecl.Err "parse: malformed define")])]
    [_ (ResultAstDecl.Err "parse: malformed define")]))

(define (parse-ast-defmacro
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Cons header after-header _)
      (match (sp-node-get header)
        [(SpannedSexpr.Cons name-node params _)
          (match (sp-node-get name-node)
            [(SpannedSexpr.Sym name _)
              (match (sp-node-get after-header)
                [(SpannedSexpr.Cons colon ret-tail _)
                  (match (sp-node-get ret-tail)
                    [(SpannedSexpr.Cons ret body-tail _)
                      (match (sp-node-get body-tail)
                        [(SpannedSexpr.Cons body end _)
                          (match (sp-node-get end)
                            [(SpannedSexpr.Nil _)
                              (if (sexpr-colon?
                                (spanned-sexpr-form (sp-node-get colon)))
                                (match (parse-ast-macro-param-list
                                  dispatch
                                  pools
                                  (spanned-sexpr-form (sp-node-get params)))
                                  [(ResultAstMacroParamList.Ok parsed-params)
                                    (match (parse-ast-type-spanned
                                      dispatch
                                      pools
                                      (sp-node-get ret))
                                      [(ResultAstType.Ok parsed-ret)
                                        (match (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          (sp-node-get body))
                                          [(ResultAstExpr.Ok parsed-body)
                                            (ResultAstDecl.Ok
                                              (ast-decl-def-macro
                                                name
                                                parsed-params
                                                parsed-ret
                                                parsed-body))]
                                          [(ResultAstExpr.Err message)
                                            (ResultAstDecl.Err message)])]
                                      [(ResultAstType.Err message)
                                        (ResultAstDecl.Err message)])]
                                  [(ResultAstMacroParamList.Err message)
                                    (ResultAstDecl.Err message)])
                                (ResultAstDecl.Err
                                  "parse: expected ':' in macro definition"))]
                            [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
                        [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
                    [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
                [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
            [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
        [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
    [_ (ResultAstDecl.Err "parse: malformed defmacro")]))

(define (parse-ast-extern-varargs-typed-name? [name : String]) : bool
  (if (> (string.string-length name) 3)
    (string.eq (string.substring name 0 3) "...")
    false))

(define (parse-ast-extern-varargs-tail-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [name : String]) : ResultAstType
  (if (parse-ast-extern-varargs-typed-name? name)
    (parse-ast-type
      dispatch
      pools
      (Sexpr.Sym (string.substring name 3 (- (string.string-length name) 3))))
    (ResultAstType.Err "parse: expected typed extern varargs tail")))

(define (parse-ast-extern-head-fixed-param
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [item : SpannedSexpr]) : ResultAstExternHeadItem
  (match (parse-ast-param dispatch pools (spanned-sexpr-form item))
    [(ResultAstParam.Ok param)
      (match param
        [(AstParam.Param _ ty comptime?)
          (if comptime?
            (ResultAstExternHeadItem.Err
              "parse: extern parameters cannot be comptime")
            (ResultAstExternHeadItem.Ok (AstExternHeadItem.Param ty)))])]
    [(ResultAstParam.Err message) (ResultAstExternHeadItem.Err message)]))

(define (parse-ast-extern-head-bracket-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [item : SpannedSexpr]
  [items : SpannedSexpr]) : ResultAstExternHeadItem
  (match items
    [(SpannedSexpr.Cons _ after-name _)
      (match (sp-node-get after-name)
        [(SpannedSexpr.Cons colon after-colon _)
          (match (sp-node-get after-colon)
            [(SpannedSexpr.Cons ty-node end _)
              (match (sp-node-get end)
                [(SpannedSexpr.Nil _)
                  (if (sexpr-colon? (spanned-sexpr-form (sp-node-get colon)))
                    (match (sp-node-get ty-node)
                      [(SpannedSexpr.Sym ty-name _)
                        (if (string.eq ty-name "...")
                          (ResultAstExternHeadItem.Err
                            "parse: extern typed varargs tail needs a type")
                          (if (parse-ast-extern-varargs-typed-name? ty-name)
                            (match (parse-ast-extern-varargs-tail-type
                              dispatch
                              pools
                              ty-name)
                              [(ResultAstType.Ok tail-ty)
                                (ResultAstExternHeadItem.Ok
                                  (AstExternHeadItem.VarargsTyped tail-ty))]
                              [(ResultAstType.Err message)
                                (ResultAstExternHeadItem.Err message)])
                            (parse-ast-extern-head-fixed-param
                              dispatch
                              pools
                              item)))]
                      [_
                        (parse-ast-extern-head-fixed-param dispatch pools item)])
                    (parse-ast-extern-head-fixed-param dispatch pools item))]
                [_ (parse-ast-extern-head-fixed-param dispatch pools item)])]
            [_ (parse-ast-extern-head-fixed-param dispatch pools item)])]
        [_ (parse-ast-extern-head-fixed-param dispatch pools item)])]
    [_ (parse-ast-extern-head-fixed-param dispatch pools item)]))

(define (parse-ast-extern-head-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [item : SpannedSexpr]) : ResultAstExternHeadItem
  (match item
    [(SpannedSexpr.Sym name _)
      (if (string.eq name "...")
        (ResultAstExternHeadItem.Ok (AstExternHeadItem.VarargsOpen))
        (if (parse-ast-extern-varargs-typed-name? name)
          (ResultAstExternHeadItem.Err
            "parse: typed extern varargs tail must use bracket syntax")
          (ResultAstExternHeadItem.Err "parse: malformed extern function head")))]
    [(SpannedSexpr.BracketList items _)
      (parse-ast-extern-head-bracket-item
        dispatch
        pools
        item
        (sp-node-get items))]
    [_ (ResultAstExternHeadItem.Err "parse: malformed extern function head")]))

(define (parse-ast-extern-head-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : SpannedSexpr]) : ResultAstExternHeader
  (match items
    [(SpannedSexpr.Nil _)
      (ResultAstExternHeader.Ok "" (ast-type-list-new) (AstExternAbi.C))]
    [(SpannedSexpr.Cons item tail _)
      (let
        [item : SpannedSexpr (sp-node-get item)]
        [tail : SpannedSexpr (sp-node-get tail)]
        (match (parse-ast-extern-head-item dispatch pools item)
          [(ResultAstExternHeadItem.Ok parsed-item)
            (match parsed-item
              [(AstExternHeadItem.Param ty)
                (match (parse-ast-extern-head-items dispatch pools tail)
                  [(ResultAstExternHeader.Ok _ parsed-tail parsed-abi)
                    (ResultAstExternHeader.Ok
                      ""
                      (ast-type-cons-with-pools pools ty parsed-tail)
                      parsed-abi)]
                  [(ResultAstExternHeader.Err message)
                    (ResultAstExternHeader.Err message)])]
              [(AstExternHeadItem.VarargsOpen)
                (match tail
                  [(SpannedSexpr.Nil _)
                    (ResultAstExternHeader.Ok
                      ""
                      (ast-type-list-new)
                      (AstExternAbi.CVarargsOpen))]
                  [_
                    (ResultAstExternHeader.Err
                      "parse: extern varargs tail must be final")])]
              [(AstExternHeadItem.VarargsTyped tail-ty)
                (match tail
                  [(SpannedSexpr.Nil _)
                    (ResultAstExternHeader.Ok
                      ""
                      (ast-type-list-new)
                      (AstExternAbi.CVarargsTyped tail-ty))]
                  [_
                    (ResultAstExternHeader.Err
                      "parse: extern varargs tail must be final")])])]
          [(ResultAstExternHeadItem.Err message)
            (ResultAstExternHeader.Err message)]))]
    [_ (ResultAstExternHeader.Err "parse: malformed extern function head")]))

(define (parse-ast-extern-header
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : SpannedSexpr]) : ResultAstExternHeader
  (match head
    [(SpannedSexpr.Cons name-node params _)
      (match (sp-node-get name-node)
        [(SpannedSexpr.Sym name _)
          (match (parse-ast-extern-head-items
            dispatch
            pools
            (sp-node-get params))
            [(ResultAstExternHeader.Ok _ param-types abi)
              (ResultAstExternHeader.Ok name param-types abi)]
            [(ResultAstExternHeader.Err message)
              (ResultAstExternHeader.Err message)])]
        [_ (ResultAstExternHeader.Err "parse: malformed extern function head")])]
    [_ (ResultAstExternHeader.Err "parse: malformed extern function head")]))

(define (parse-ast-extern-c-varargs-legacy-message) : String
  "parse: legacy :abi c-varargs metadata is retired; use function-head ... or ...T varargs")

(define (parse-ast-extern-abi-tail [tail : Sexpr]) : ResultAstExternAbi
  (match tail
    [(Sexpr.Cons name-node rest)
      (match (box-get name-node)
        [(Sexpr.Sym name)
          (match (box-get rest)
            [(Sexpr.Nil)
              (if (string.eq name "c")
                (ResultAstExternAbi.Ok (AstExternAbi.C))
                (if (string.eq name "c-varargs")
                  (ResultAstExternAbi.Err
                    (parse-ast-extern-c-varargs-legacy-message))
                  (ResultAstExternAbi.Err
                    (string.append "parse: unknown extern ABI " name))))]
            [(Sexpr.Cons fixed-node end)
              (match (box-get end)
                [(Sexpr.Nil)
                  (match (box-get fixed-node)
                    [(Sexpr.Int _ _)
                      (if (string.eq name "c-varargs")
                        (ResultAstExternAbi.Err
                          (parse-ast-extern-c-varargs-legacy-message))
                        (ResultAstExternAbi.Err
                          (string.append "parse: unknown extern ABI " name)))]
                    [_
                      (ResultAstExternAbi.Err
                        "parse: malformed extern :abi metadata")])]
                [_
                  (ResultAstExternAbi.Err
                    "parse: malformed extern :abi metadata")])]
            [_ (ResultAstExternAbi.Err "parse: malformed extern :abi metadata")])]
        [_ (ResultAstExternAbi.Err "parse: malformed extern :abi metadata")])]
    [_ (ResultAstExternAbi.Err "parse: malformed extern :abi metadata")]))

(define (parse-ast-extern-string-tail [key : String] [tail : Sexpr]) : ResultAstExternSymbol
  (match tail
    [(Sexpr.Cons value-node end)
      (match (box-get end)
        [(Sexpr.Nil)
          (match (box-get value-node)
            [(Sexpr.Str value)
              (if (> (string.string-length value) 0)
                (ResultAstExternSymbol.Ok value)
                (ResultAstExternSymbol.Err
                  (string.append
                    "parse: extern "
                    (string.append key " must not be empty"))))]
            [_
              (ResultAstExternSymbol.Err
                (string.append
                  "parse: malformed extern "
                  (string.append key " metadata")))])]
        [_
          (ResultAstExternSymbol.Err
            (string.append
              "parse: malformed extern "
              (string.append key " metadata")))])]
    [_
      (ResultAstExternSymbol.Err
        (string.append
          "parse: malformed extern "
          (string.append key " metadata")))]))

(define (parse-ast-extern-symbol-tail [tail : Sexpr]) : ResultAstExternSymbol
  (parse-ast-extern-string-tail ":symbol" tail))

(define (parse-ast-extern-abi-combine
  [base : AstExternAbi]
  [parsed : AstExternAbi]) : ResultAstExternAbi
  (if (ast-extern-abi-c-varargs? base)
    (match parsed
      [(AstExternAbi.C) (ResultAstExternAbi.Ok base)]
      [_
        (ResultAstExternAbi.Err
          "parse: extern varargs tail cannot be combined with another ABI")])
    (ResultAstExternAbi.Ok parsed)))

(define (parse-ast-extern-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : SpannedSexpr]
  [abi : AstExternAbi]
  [symbol : String]
  [link-inputs : (&mut link-inputs AstExternLinkInputList)]
  [seen-abi : bool]
  [seen-symbol : bool]) : ResultAstExternParts
  (match items
    [(SpannedSexpr.Cons head tail _)
      (if (sexpr-colon? (spanned-sexpr-form (sp-node-get head)))
        (match (sp-node-get tail)
          [(SpannedSexpr.Cons ty end _)
            (match (sp-node-get end)
              [(SpannedSexpr.Nil _)
                (match (parse-ast-type-spanned dispatch pools (sp-node-get ty))
                  [(ResultAstType.Ok parsed-ty)
                    (ResultAstExternParts.Ok abi symbol seen-abi parsed-ty)]
                  [(ResultAstType.Err message)
                    (ResultAstExternParts.Err message)])]
              [_ (ResultAstExternParts.Err "parse: malformed extern")])]
          [_ (ResultAstExternParts.Err "parse: malformed extern")])
        (match (spanned-sexpr-form (sp-node-get head))
          [(Sexpr.Cons key-node after-key)
            (match (box-get key-node)
              [(Sexpr.Sym key)
                (cond
                  [(string.eq key ":abi")
                    (if seen-abi
                      (ResultAstExternParts.Err
                        "parse: duplicate extern :abi metadata")
                      (match (parse-ast-extern-abi-tail (box-get after-key))
                        [(ResultAstExternAbi.Ok parsed-abi)
                          (parse-ast-extern-items
                            dispatch
                            pools
                            (sp-node-get tail)
                            parsed-abi
                            symbol
                            link-inputs
                            true
                            seen-symbol)]
                        [(ResultAstExternAbi.Err message)
                          (ResultAstExternParts.Err message)]))]
                  [(string.eq key ":symbol")
                    (if seen-symbol
                      (ResultAstExternParts.Err
                        "parse: duplicate extern :symbol metadata")
                      (match (parse-ast-extern-symbol-tail (box-get after-key))
                        [(ResultAstExternSymbol.Ok parsed-symbol)
                          (parse-ast-extern-items
                            dispatch
                            pools
                            (sp-node-get tail)
                            abi
                            parsed-symbol
                            link-inputs
                            seen-abi
                            true)]
                        [(ResultAstExternSymbol.Err message)
                          (ResultAstExternParts.Err message)]))]
                  [(string.eq key ":link-lib")
                    (match (parse-ast-extern-string-tail
                      ":link-lib"
                      (box-get after-key))
                      [(ResultAstExternSymbol.Ok value)
                        (begin
                          (ast-extern-link-input-list-push
                            link-inputs
                            (AstExternLinkInput.Lib value))
                          (parse-ast-extern-items
                            dispatch
                            pools
                            (sp-node-get tail)
                            abi
                            symbol
                            link-inputs
                            seen-abi
                            seen-symbol))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(string.eq key ":link-search")
                    (match (parse-ast-extern-string-tail
                      ":link-search"
                      (box-get after-key))
                      [(ResultAstExternSymbol.Ok value)
                        (begin
                          (ast-extern-link-input-list-push
                            link-inputs
                            (AstExternLinkInput.Search value))
                          (parse-ast-extern-items
                            dispatch
                            pools
                            (sp-node-get tail)
                            abi
                            symbol
                            link-inputs
                            seen-abi
                            seen-symbol))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(string.eq key ":link-arg")
                    (match (parse-ast-extern-string-tail
                      ":link-arg"
                      (box-get after-key))
                      [(ResultAstExternSymbol.Ok value)
                        (begin
                          (ast-extern-link-input-list-push
                            link-inputs
                            (AstExternLinkInput.Arg value))
                          (parse-ast-extern-items
                            dispatch
                            pools
                            (sp-node-get tail)
                            abi
                            symbol
                            link-inputs
                            seen-abi
                            seen-symbol))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(compiler-parse-metadata-key? key)
                    (ResultAstExternParts.Err
                      (string.append "parse: unknown extern metadata " key))]
                  [else
                    (ResultAstExternParts.Err "parse: expected ':' in extern")])]
              [_ (ResultAstExternParts.Err "parse: expected ':' in extern")])]
          [_ (ResultAstExternParts.Err "parse: expected ':' in extern")]))]
    [_ (ResultAstExternParts.Err "parse: malformed extern")]))

(define (parse-ast-extern-head-finish
  [pools : AstNodePoolContext]
  [abi : AstExternAbi]
  [symbol : String]
  [seen-abi : bool]
  [param-types : AstTypeList]
  [ret : AstType]) : ResultAstExternParts
  (ResultAstExternParts.Ok
    abi
    symbol
    seen-abi
    (ast-ty-func-with-pools pools param-types ret)))

(define (parse-ast-extern-head-post-ret
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : SpannedSexpr]
  [abi : AstExternAbi]
  [symbol : String]
  [link-inputs : (&mut link-inputs AstExternLinkInputList)]
  [seen-abi : bool]
  [seen-symbol : bool]
  [param-types : AstTypeList]
  [ret : AstType]) : ResultAstExternParts
  (match items
    [(SpannedSexpr.Nil _)
      (parse-ast-extern-head-finish pools abi symbol seen-abi param-types ret)]
    [(SpannedSexpr.Cons head tail _)
      (match (spanned-sexpr-form (sp-node-get head))
        [(Sexpr.Cons key-node after-key)
          (match (box-get key-node)
            [(Sexpr.Sym key)
              (cond
                [(string.eq key ":abi")
                  (if seen-abi
                    (ResultAstExternParts.Err
                      "parse: duplicate extern :abi metadata")
                    (match (parse-ast-extern-abi-tail (box-get after-key))
                      [(ResultAstExternAbi.Ok parsed-abi)
                        (match (parse-ast-extern-abi-combine abi parsed-abi)
                          [(ResultAstExternAbi.Ok combined-abi)
                            (parse-ast-extern-head-post-ret
                              dispatch
                              pools
                              (sp-node-get tail)
                              combined-abi
                              symbol
                              link-inputs
                              true
                              seen-symbol
                              param-types
                              ret)]
                          [(ResultAstExternAbi.Err message)
                            (ResultAstExternParts.Err message)])]
                      [(ResultAstExternAbi.Err message)
                        (ResultAstExternParts.Err message)]))]
                [(string.eq key ":symbol")
                  (if seen-symbol
                    (ResultAstExternParts.Err
                      "parse: duplicate extern :symbol metadata")
                    (match (parse-ast-extern-symbol-tail (box-get after-key))
                      [(ResultAstExternSymbol.Ok parsed-symbol)
                        (parse-ast-extern-head-post-ret
                          dispatch
                          pools
                          (sp-node-get tail)
                          abi
                          parsed-symbol
                          link-inputs
                          seen-abi
                          true
                          param-types
                          ret)]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)]))]
                [(string.eq key ":link-lib")
                  (match (parse-ast-extern-string-tail
                    ":link-lib"
                    (box-get after-key))
                    [(ResultAstExternSymbol.Ok value)
                      (begin
                        (ast-extern-link-input-list-push
                          link-inputs
                          (AstExternLinkInput.Lib value))
                        (parse-ast-extern-head-post-ret
                          dispatch
                          pools
                          (sp-node-get tail)
                          abi
                          symbol
                          link-inputs
                          seen-abi
                          seen-symbol
                          param-types
                          ret))]
                    [(ResultAstExternSymbol.Err message)
                      (ResultAstExternParts.Err message)])]
                [(string.eq key ":link-search")
                  (match (parse-ast-extern-string-tail
                    ":link-search"
                    (box-get after-key))
                    [(ResultAstExternSymbol.Ok value)
                      (begin
                        (ast-extern-link-input-list-push
                          link-inputs
                          (AstExternLinkInput.Search value))
                        (parse-ast-extern-head-post-ret
                          dispatch
                          pools
                          (sp-node-get tail)
                          abi
                          symbol
                          link-inputs
                          seen-abi
                          seen-symbol
                          param-types
                          ret))]
                    [(ResultAstExternSymbol.Err message)
                      (ResultAstExternParts.Err message)])]
                [(string.eq key ":link-arg")
                  (match (parse-ast-extern-string-tail
                    ":link-arg"
                    (box-get after-key))
                    [(ResultAstExternSymbol.Ok value)
                      (begin
                        (ast-extern-link-input-list-push
                          link-inputs
                          (AstExternLinkInput.Arg value))
                        (parse-ast-extern-head-post-ret
                          dispatch
                          pools
                          (sp-node-get tail)
                          abi
                          symbol
                          link-inputs
                          seen-abi
                          seen-symbol
                          param-types
                          ret))]
                    [(ResultAstExternSymbol.Err message)
                      (ResultAstExternParts.Err message)])]
                [(compiler-parse-metadata-key? key)
                  (ResultAstExternParts.Err
                    (string.append "parse: unknown extern metadata " key))]
                [else (ResultAstExternParts.Err "parse: malformed extern")])]
            [_ (ResultAstExternParts.Err "parse: malformed extern")])]
        [_ (ResultAstExternParts.Err "parse: malformed extern")])]
    [_ (ResultAstExternParts.Err "parse: malformed extern")]))

(define (parse-ast-extern-head-rest
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : SpannedSexpr]
  [abi : AstExternAbi]
  [symbol : String]
  [link-inputs : (&mut link-inputs AstExternLinkInputList)]
  [seen-abi : bool]
  [seen-symbol : bool]
  [param-types : AstTypeList]) : ResultAstExternParts
  (match items
    [(SpannedSexpr.Cons head tail _)
      (if (sexpr-colon? (spanned-sexpr-form (sp-node-get head)))
        (match (sp-node-get tail)
          [(SpannedSexpr.Cons ret end _)
            (match (sp-node-get end)
              [(SpannedSexpr.Nil _)
                (match (parse-ast-type-spanned dispatch pools (sp-node-get ret))
                  [(ResultAstType.Ok parsed-ret)
                    (parse-ast-extern-head-finish
                      pools
                      abi
                      symbol
                      seen-abi
                      param-types
                      parsed-ret)]
                  [(ResultAstType.Err message)
                    (ResultAstExternParts.Err message)])]
              [_
                (match (parse-ast-type-spanned dispatch pools (sp-node-get ret))
                  [(ResultAstType.Ok parsed-ret)
                    (parse-ast-extern-head-post-ret
                      dispatch
                      pools
                      (sp-node-get end)
                      abi
                      symbol
                      link-inputs
                      seen-abi
                      seen-symbol
                      param-types
                      parsed-ret)]
                  [(ResultAstType.Err message)
                    (ResultAstExternParts.Err message)])])]
          [_ (ResultAstExternParts.Err "parse: malformed extern")])
        (match (spanned-sexpr-form (sp-node-get head))
          [(Sexpr.Cons key-node after-key)
            (match (box-get key-node)
              [(Sexpr.Sym key)
                (cond
                  [(string.eq key ":abi")
                    (if seen-abi
                      (ResultAstExternParts.Err
                        "parse: duplicate extern :abi metadata")
                      (match (parse-ast-extern-abi-tail (box-get after-key))
                        [(ResultAstExternAbi.Ok parsed-abi)
                          (match (parse-ast-extern-abi-combine abi parsed-abi)
                            [(ResultAstExternAbi.Ok combined-abi)
                              (parse-ast-extern-head-rest
                                dispatch
                                pools
                                (sp-node-get tail)
                                combined-abi
                                symbol
                                link-inputs
                                true
                                seen-symbol
                                param-types)]
                            [(ResultAstExternAbi.Err message)
                              (ResultAstExternParts.Err message)])]
                        [(ResultAstExternAbi.Err message)
                          (ResultAstExternParts.Err message)]))]
                  [(string.eq key ":symbol")
                    (if seen-symbol
                      (ResultAstExternParts.Err
                        "parse: duplicate extern :symbol metadata")
                      (match (parse-ast-extern-symbol-tail (box-get after-key))
                        [(ResultAstExternSymbol.Ok parsed-symbol)
                          (parse-ast-extern-head-rest
                            dispatch
                            pools
                            (sp-node-get tail)
                            abi
                            parsed-symbol
                            link-inputs
                            seen-abi
                            true
                            param-types)]
                        [(ResultAstExternSymbol.Err message)
                          (ResultAstExternParts.Err message)]))]
                  [(string.eq key ":link-lib")
                    (match (parse-ast-extern-string-tail
                      ":link-lib"
                      (box-get after-key))
                      [(ResultAstExternSymbol.Ok value)
                        (begin
                          (ast-extern-link-input-list-push
                            link-inputs
                            (AstExternLinkInput.Lib value))
                          (parse-ast-extern-head-rest
                            dispatch
                            pools
                            (sp-node-get tail)
                            abi
                            symbol
                            link-inputs
                            seen-abi
                            seen-symbol
                            param-types))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(string.eq key ":link-search")
                    (match (parse-ast-extern-string-tail
                      ":link-search"
                      (box-get after-key))
                      [(ResultAstExternSymbol.Ok value)
                        (begin
                          (ast-extern-link-input-list-push
                            link-inputs
                            (AstExternLinkInput.Search value))
                          (parse-ast-extern-head-rest
                            dispatch
                            pools
                            (sp-node-get tail)
                            abi
                            symbol
                            link-inputs
                            seen-abi
                            seen-symbol
                            param-types))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(string.eq key ":link-arg")
                    (match (parse-ast-extern-string-tail
                      ":link-arg"
                      (box-get after-key))
                      [(ResultAstExternSymbol.Ok value)
                        (begin
                          (ast-extern-link-input-list-push
                            link-inputs
                            (AstExternLinkInput.Arg value))
                          (parse-ast-extern-head-rest
                            dispatch
                            pools
                            (sp-node-get tail)
                            abi
                            symbol
                            link-inputs
                            seen-abi
                            seen-symbol
                            param-types))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(compiler-parse-metadata-key? key)
                    (ResultAstExternParts.Err
                      (string.append "parse: unknown extern metadata " key))]
                  [else
                    (ResultAstExternParts.Err "parse: expected ':' in extern")])]
              [_ (ResultAstExternParts.Err "parse: expected ':' in extern")])]
          [_ (ResultAstExternParts.Err "parse: expected ':' in extern")]))]
    [_ (ResultAstExternParts.Err "parse: malformed extern")]))

(define (parse-ast-extern-function-head
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : SpannedSexpr]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-extern-header dispatch pools head)
    [(ResultAstExternHeader.Ok name param-types abi)
      (let
        [link-inputs : AstExternLinkInputList (ast-extern-link-input-list-new)]
        (match (parse-ast-extern-head-rest
          dispatch
          pools
          rest
          abi
          name
          (&mut link-inputs)
          false
          false
          param-types)
          [(ResultAstExternParts.Ok parsed-abi parsed-symbol explicit-abi ty)
            (ResultAstDecl.Ok
              (ast-decl-extern
                name
                (AstExternKind.Function)
                (AstExternMetadata.Metadata
                  parsed-abi
                  parsed-symbol
                  link-inputs
                  explicit-abi)
                ty))]
          [(ResultAstExternParts.Err message) (ResultAstDecl.Err message)]))]
    [(ResultAstExternHeader.Err message) (ResultAstDecl.Err message)]))

(define (parse-ast-extern
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Cons name-node after-name _)
      (match (sp-node-get name-node)
        [(SpannedSexpr.Sym name _)
          (let
            [link-inputs : AstExternLinkInputList
              (ast-extern-link-input-list-new)]
            (match (parse-ast-extern-items
              dispatch
              pools
              (sp-node-get after-name)
              (AstExternAbi.C)
              name
              (&mut link-inputs)
              false
              false)
              [(ResultAstExternParts.Ok
                  parsed-abi
                  parsed-symbol
                  explicit-abi
                  parsed-ty)
                (ResultAstDecl.Ok
                  (ast-decl-extern
                    name
                    (AstExternKind.Value)
                    (AstExternMetadata.Metadata
                      parsed-abi
                      parsed-symbol
                      link-inputs
                      explicit-abi)
                    parsed-ty))]
              [(ResultAstExternParts.Err message) (ResultAstDecl.Err message)]))]
        [_
          (parse-ast-extern-function-head
            dispatch
            pools
            (sp-node-get name-node)
            (sp-node-get after-name))])]
    [_ (ResultAstDecl.Err "parse: malformed extern")]))

(define (parse-ast-defenum
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Cons name-node variants _)
      (match (sp-node-get name-node)
        [(SpannedSexpr.Sym name _)
          (match (parse-ast-defenum-items
            dispatch
            pools
            (sp-node-get variants)
            (ast-lifetime-list-new)
            (AstEnumCleanup.No)
            false
            false
            false)
            [(ResultAstEnumDefParts.Ok lifetimes cleanup parsed-variants)
              (if (ast-variant-def-list-empty? (& parsed-variants))
                (ResultAstDecl.Err "parse: defenum needs at least one variant")
                (if (ast-lifetime-list-empty? (& lifetimes))
                  (ResultAstDecl.Ok
                    (ast-decl-def-enum name cleanup parsed-variants))
                  (ResultAstDecl.Ok
                    (ast-decl-def-enum-lifetimes
                      name
                      lifetimes
                      cleanup
                      parsed-variants))))]
            [(ResultAstEnumDefParts.Err message) (ResultAstDecl.Err message)])]
        [_ (ResultAstDecl.Err "parse: malformed defenum")])]
    [_ (ResultAstDecl.Err "parse: malformed defenum")]))

(define (parse-ast-defstruct
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Cons name-node fields _)
      (match (sp-node-get name-node)
        [(SpannedSexpr.Sym name _)
          (match (parse-ast-defstruct-items
            dispatch
            pools
            (sp-node-get fields)
            (ast-lifetime-list-new)
            (AstStructRepr.Default)
            (AstStructCleanup.No)
            (ast-field-def-list-new)
            false
            false
            false
            false)
            [(ResultAstStructDefParts.Ok lifetimes repr cleanup parsed-fields)
              (if (ast-field-def-list-empty? (& parsed-fields))
                (ResultAstDecl.Err "parse: defstruct needs at least one field")
                (if (ast-lifetime-list-empty? (& lifetimes))
                  (ResultAstDecl.Ok
                    (ast-decl-def-struct name repr cleanup parsed-fields))
                  (ResultAstDecl.Ok
                    (ast-decl-def-struct-lifetimes
                      name
                      lifetimes
                      repr
                      cleanup
                      parsed-fields))))]
            [(ResultAstStructDefParts.Err message) (ResultAstDecl.Err message)])]
        [_ (ResultAstDecl.Err "parse: malformed defstruct")])]
    [_ (ResultAstDecl.Err "parse: malformed defstruct")]))

(define (parse-ast-defdispatch [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Cons name-node variants _)
      (match (sp-node-get name-node)
        [(SpannedSexpr.Sym name _)
          (match (parse-ast-dispatch-variant-list (sp-node-get variants))
            [(ResultAstDispatchVariantList.Ok parsed-variants)
              (if (ast-dispatch-variant-list-empty? (& parsed-variants))
                (ResultAstDecl.Err
                  "parse: defdispatch needs at least one variant")
                (ResultAstDecl.Ok (ast-decl-def-dispatch name parsed-variants)))]
            [(ResultAstDispatchVariantList.Err message)
              (ResultAstDecl.Err message)])]
        [_ (ResultAstDecl.Err "parse: malformed defdispatch")])]
    [_ (ResultAstDecl.Err "parse: malformed defdispatch")]))

(define (parse-ast-module-body-forms-into-vec
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [forms : SpannedSexpr]
  [out : (&mut out ParseAstDeclVec)]) : ResultParseAstDeclVec
  (match forms
    [(SpannedSexpr.Nil _) (ResultParseAstDeclVec.Ok)]
    [(SpannedSexpr.Cons form rest _)
      (match (parse-ast-decl-maybe-with-pools dispatch pools (sp-node-get form))
        [(ResultAstMaybeDecl.SomeDecl decl)
          (begin
            (parse-ast-decl-vec-push-with-span
              out
              decl
              (ast-source-span-from-source-span
                (spanned-sexpr-span (sp-node-get form))))
            (parse-ast-module-body-forms-into-vec
              dispatch
              pools
              (sp-node-get rest)
              out))]
        [(ResultAstMaybeDecl.Decls decls)
          (begin
            (parse-ast-decl-vec-push-list! out decls)
            (parse-ast-module-body-forms-into-vec
              dispatch
              pools
              (sp-node-get rest)
              out))]
        [(ResultAstMaybeDecl.NoDecl)
          (parse-ast-module-body-forms-into-vec
            dispatch
            pools
            (sp-node-get rest)
            out)]
        [(ResultAstMaybeDecl.Err message) (ResultParseAstDeclVec.Err message)])]
    [_ (ResultParseAstDeclVec.Err "parse: malformed module")]))

(define (parse-ast-module-body
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [name : String]
  [body : SpannedSexpr]) : ResultAstDecl
  (let
    [out : ParseAstDeclVec (parse-ast-decl-vec-new)]
    (match (parse-ast-module-body-forms-into-vec dispatch pools body (&mut out))
      [(ResultParseAstDeclVec.Ok)
        (ResultAstDecl.Ok
          (ast-decl-module-body name (parse-ast-decl-vec-to-list (& out))))]
      [(ResultParseAstDeclVec.Err message) (ResultAstDecl.Err message)])))

(define (parse-ast-module
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Cons name-node end _)
      (match (sp-node-get name-node)
        [(SpannedSexpr.Sym name _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _) (ResultAstDecl.Ok (ast-decl-module name))]
            [_ (parse-ast-module-body dispatch pools name (sp-node-get end))])]
        [_ (ResultAstDecl.Err "parse: malformed module")])]
    [_ (ResultAstDecl.Err "parse: malformed module")]))

(define (parse-ast-import-spec
  [kind : AstImportKind]
  [path : String]
  [module-name : AstMaybeModuleName]
  [alias : AstMaybeImportAlias]
  [span : AstSourceSpan]) : ResultAstDecl
  (ResultAstDecl.Ok
    (AstDecl.Import (AstImportSpec.Spec kind path module-name alias span))))

(define (parse-ast-import-alias
  [kind : AstImportKind]
  [path : String]
  [module-name : AstMaybeModuleName]
  [tail : SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match tail
    [(SpannedSexpr.Cons as-node alias-tail _)
      (match (sp-node-get as-node)
        [(SpannedSexpr.Sym as-name _)
          (match (sp-node-get alias-tail)
            [(SpannedSexpr.Cons alias-node end _)
              (match (sp-node-get end)
                [(SpannedSexpr.Nil _)
                  (match (sp-node-get alias-node)
                    [(SpannedSexpr.Sym alias _)
                      (if (or
                        (string.eq as-name "as")
                        (string.eq as-name ":as"))
                        (parse-ast-import-spec
                          kind
                          path
                          module-name
                          (AstMaybeImportAlias.Some alias)
                          span)
                        (ResultAstDecl.Err "parse: malformed import"))]
                    [_ (ResultAstDecl.Err "parse: malformed import")])]
                [_ (ResultAstDecl.Err "parse: malformed import")])]
            [_ (ResultAstDecl.Err "parse: malformed import")])]
        [_ (ResultAstDecl.Err "parse: malformed import")])]
    [_ (ResultAstDecl.Err "parse: malformed import")]))

(define (parse-ast-import-module-tail
  [path : String]
  [tail : SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match tail
    [(SpannedSexpr.Cons module-name-node after-module _)
      (match (sp-node-get module-name-node)
        [(SpannedSexpr.Sym module-name _)
          (match (sp-node-get after-module)
            [(SpannedSexpr.Nil _)
              (parse-ast-import-spec
                (AstImportKind.Path)
                path
                (AstMaybeModuleName.Some module-name)
                AstMaybeImportAlias.No
                span)]
            [_
              (parse-ast-import-alias
                (AstImportKind.Path)
                path
                (AstMaybeModuleName.Some module-name)
                (sp-node-get after-module)
                span)])]
        [_ (ResultAstDecl.Err "parse: malformed import")])]
    [_ (ResultAstDecl.Err "parse: malformed import")]))

(define (parse-ast-import-tail
  [path : String]
  [tail : SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match tail
    [(SpannedSexpr.Nil _)
      (parse-ast-import-spec
        (AstImportKind.Path)
        path
        AstMaybeModuleName.No
        AstMaybeImportAlias.No
        span)]
    [(SpannedSexpr.Cons head-node after-head _)
      (match (sp-node-get head-node)
        [(SpannedSexpr.Sym head _)
          (if (string.eq head "as")
            (parse-ast-import-alias
              (AstImportKind.Path)
              path
              AstMaybeModuleName.No
              tail
              span)
            (if (string.eq head "module")
              (parse-ast-import-module-tail path (sp-node-get after-head) span)
              (ResultAstDecl.Err "parse: malformed import")))]
        [_ (ResultAstDecl.Err "parse: malformed import")])]
    [_ (ResultAstDecl.Err "parse: malformed import")]))

(define (parse-ast-import-macro-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [call-form : SpannedSexpr]
  [tail : SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match (parse-ast-expr-with-pools dispatch pools call-form)
    [(ResultAstExpr.Ok call-expr)
      (match (ast-expr-unspan-with-pools
        pools
        (ast-node-pool-context-expr-get pools call-expr))
        [(AstExpr.Call _ _)
          (match tail
            [(SpannedSexpr.Nil _)
              (parse-ast-import-spec
                (AstImportKind.Macro call-expr AstMaybeModuleName.No)
                ""
                AstMaybeModuleName.No
                AstMaybeImportAlias.No
                span)]
            [(SpannedSexpr.Cons head-node _ _)
              (match (sp-node-get head-node)
                [(SpannedSexpr.Sym head _)
                  (if (or (string.eq head "as") (string.eq head ":as"))
                    (parse-ast-import-alias
                      (AstImportKind.Macro call-expr AstMaybeModuleName.No)
                      ""
                      AstMaybeModuleName.No
                      tail
                      span)
                    (ResultAstDecl.Err "parse: malformed import"))]
                [_ (ResultAstDecl.Err "parse: malformed import")])]
            [_ (ResultAstDecl.Err "parse: malformed import")])]
        [_ (ResultAstDecl.Err "parse: import macro operand must be a call")])]
    [(ResultAstExpr.Err message) (ResultAstDecl.Err message)]))

(define (parse-ast-dotted-import-tl-suffix? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    (if (< n 3)
      false
      (string.eq (string.substring name (- n 3) 3) ".tl"))))

(define (parse-ast-dotted-import-name-valid? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    [i : i64 0]
    [ok : bool (and (> n 0) (not (parse-ast-dotted-import-tl-suffix? name)))]
    [last-was-dot : bool true]
    (begin
      (while ok
        (if (< i n)
          (let
            [c : char (string.string-ref name i)]
            (if (or
              (string.char-eq c '/')
              (string.char-eq c '\\')
              (string.char-eq c ':'))
              (set! ok false)
              (if (string.char-eq c '.')
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
    [n : i64 (string.string-length name)]
    [i : i64 0]
    [start : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (string.char-eq (string.string-ref name i) '.')
            (set! start (+ i 1))
            unit)
          (set! i (+ i 1))))
      (string.substring name start (- n start)))))

(define (parse-ast-dotted-import-tail
  [module-name : String]
  [tail : SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (if (not (parse-ast-dotted-import-name-valid? module-name))
    (ResultAstDecl.Err "parse: invalid dotted import module name")
    (match tail
      [(SpannedSexpr.Nil _)
        (parse-ast-import-spec
          (AstImportKind.Module)
          module-name
          (AstMaybeModuleName.Some module-name)
          (AstMaybeImportAlias.Some
            (parse-ast-dotted-import-default-alias module-name))
          span)]
      [(SpannedSexpr.Cons head-node _ _)
        (match (sp-node-get head-node)
          [(SpannedSexpr.Sym head _)
            (if (or (string.eq head "as") (string.eq head ":as"))
              (parse-ast-import-alias
                (AstImportKind.Module)
                module-name
                (AstMaybeModuleName.Some module-name)
                tail
                span)
              (ResultAstDecl.Err "parse: malformed import"))]
          [_ (ResultAstDecl.Err "parse: malformed import")])]
      [_ (ResultAstDecl.Err "parse: malformed import")])))

(define (parse-ast-import
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Cons path-node tail _)
      (match (sp-node-get path-node)
        [(SpannedSexpr.Str path _)
          (parse-ast-import-tail path (sp-node-get tail) span)]
        [(SpannedSexpr.Sym module-name _)
          (parse-ast-dotted-import-tail module-name (sp-node-get tail) span)]
        [(SpannedSexpr.Cons _ _ _)
          (parse-ast-import-macro-tail
            dispatch
            pools
            (sp-node-get path-node)
            (sp-node-get tail)
            span)]
        [_ (ResultAstDecl.Err "parse: malformed import")])]
    [_ (ResultAstDecl.Err "parse: malformed import")]))

(define (parse-ast-include-str [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Nil _)
      (ResultAstDecl.Err "parse: include-str expects name and string path")]
    [(SpannedSexpr.Cons name-node tail _)
      (match (sp-node-get name-node)
        [(SpannedSexpr.Sym name _)
          (match (sp-node-get tail)
            [(SpannedSexpr.Cons path-node after-path _)
              (match (sp-node-get path-node)
                [(SpannedSexpr.Str path _)
                  (match (sp-node-get after-path)
                    [(SpannedSexpr.Nil _)
                      (ResultAstDecl.Ok (AstDecl.IncludeStr name path))]
                    [_
                      (ResultAstDecl.Err
                        "parse: include-str expects exactly two operands")])]
                [_
                  (ResultAstDecl.Err "parse: include-str path must be a string")])]
            [(SpannedSexpr.Nil _)
              (ResultAstDecl.Err
                "parse: include-str expects name and string path")]
            [_
              (ResultAstDecl.Err
                "parse: include-str expects exactly two operands")])]
        [_ (ResultAstDecl.Err "parse: include-str name must be a symbol")])]
    [_ (ResultAstDecl.Err "parse: malformed include-str")]))

(define (parse-ast-include-bin [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Nil _)
      (ResultAstDecl.Err "parse: include-bin expects name and string path")]
    [(SpannedSexpr.Cons name-node tail _)
      (match (sp-node-get name-node)
        [(SpannedSexpr.Sym name _)
          (match (sp-node-get tail)
            [(SpannedSexpr.Cons path-node after-path _)
              (match (sp-node-get path-node)
                [(SpannedSexpr.Str path _)
                  (match (sp-node-get after-path)
                    [(SpannedSexpr.Nil _)
                      (ResultAstDecl.Ok (AstDecl.IncludeBin name path))]
                    [_
                      (ResultAstDecl.Err
                        "parse: include-bin expects exactly two operands")])]
                [_
                  (ResultAstDecl.Err "parse: include-bin path must be a string")])]
            [(SpannedSexpr.Nil _)
              (ResultAstDecl.Err
                "parse: include-bin expects name and string path")]
            [_
              (ResultAstDecl.Err
                "parse: include-bin expects exactly two operands")])]
        [_ (ResultAstDecl.Err "parse: include-bin name must be a symbol")])]
    [_ (ResultAstDecl.Err "parse: malformed include-bin")]))

(define (parse-ast-test-body [pools : AstNodePoolContext] [exprs : AstExprList]) : i64
  (if (= (struct-get (& exprs) len) 1)
    (ast-expr-list-get (& exprs) 0 0)
    (ast-node-pool-context-expr-push pools (AstExpr.Begin exprs))))

(define (parse-ast-test
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]
  [form-span : AstSourceSpan]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Cons name-node body-forms _)
      (match (sp-node-get name-node)
        [(SpannedSexpr.Sym name _)
          (match (sp-node-get body-forms)
            [(SpannedSexpr.Nil _)
              (ResultAstDecl.Err "parse: test needs at least one expression")]
            [_
              (match (parse-ast-expr-list
                dispatch
                pools
                (sp-node-get body-forms))
                [(ResultAstExprList.Ok exprs)
                  (ResultAstDecl.Ok
                    (ast-decl-test
                      name
                      (parse-ast-test-body pools exprs)
                      form-span))]
                [(ResultAstExprList.Err message) (ResultAstDecl.Err message)])])]
        [_ (ResultAstDecl.Err "parse: malformed test")])]
    [_ (ResultAstDecl.Err "parse: malformed test")]))

(define (parse-ast-comptime-decl-payload-message) : String
  "parse: comptime-decl accepts only defstruct, defenum, or define")

(define (parse-ast-comptime-decls-removed-message) : String
  "parse: comptime-decls is removed; use a declaration-emitting macro instead")

(define (parse-ast-generated-decl-meta
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [meta : SpannedSexpr]) : ResultAstGeneratedDeclMeta
  (match meta
    [(SpannedSexpr.Cons head-node meta-rest _)
      (match (sp-node-get head-node)
        [(SpannedSexpr.Sym head _)
          (if (string.eq head ":generated")
            (match (sp-node-get meta-rest)
              [(SpannedSexpr.Cons generator-node item-tail _)
                (match (sp-node-get generator-node)
                  [(SpannedSexpr.Sym generator-name _)
                    (match (sp-node-get item-tail)
                      [(SpannedSexpr.Cons item-node arg-key-forms _)
                        (match (sp-node-get item-node)
                          [(SpannedSexpr.Sym item-name _)
                            (match (parse-ast-expr-list
                              dispatch
                              pools
                              (sp-node-get arg-key-forms))
                              [(ResultAstExprList.Ok arg-keys)
                                (ResultAstGeneratedDeclMeta.Ok
                                  (AstGeneratedDeclMeta.Some
                                    generator-name
                                    item-name
                                    arg-keys
                                    ""))]
                              [(ResultAstExprList.Err message)
                                (ResultAstGeneratedDeclMeta.Err message)])]
                          [_
                            (ResultAstGeneratedDeclMeta.Err
                              "parse: :generated metadata expects generator name, item name, and argument key expressions")])]
                      [_
                        (ResultAstGeneratedDeclMeta.Err
                          "parse: :generated metadata expects generator name, item name, and argument key expressions")])]
                  [_
                    (ResultAstGeneratedDeclMeta.Err
                      "parse: :generated metadata expects generator name, item name, and argument key expressions")])]
              [_
                (ResultAstGeneratedDeclMeta.Err
                  "parse: :generated metadata expects generator name, item name, and argument key expressions")])
            (ResultAstGeneratedDeclMeta.Err
              "parse: comptime-decl metadata must be :generated"))]
        [_
          (ResultAstGeneratedDeclMeta.Err
            "parse: comptime-decl metadata must be :generated")])]
    [_
      (ResultAstGeneratedDeclMeta.Err
        "parse: comptime-decl metadata must be :generated")]))

(define (parse-ast-comptime-decl-payload
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [template : SpannedSexpr]) : ResultAstDecl
  (match template
    [(SpannedSexpr.Cons head-node template-rest _)
      (match (sp-node-get head-node)
        [(SpannedSexpr.Sym head _)
          (let
            [tag : i64 (compiler-parse-dispatch-tag dispatch head)]
            (cond
              [(= tag (compiler-parse-tag-decl-define))
                (parse-ast-define dispatch pools (sp-node-get template-rest))]
              [(= tag (compiler-parse-tag-decl-defenum))
                (parse-ast-defenum dispatch pools (sp-node-get template-rest))]
              [(= tag (compiler-parse-tag-decl-defstruct))
                (parse-ast-defstruct dispatch pools (sp-node-get template-rest))]
              [else
                (ResultAstDecl.Err (parse-ast-comptime-decl-payload-message))]))]
        [_ (ResultAstDecl.Err (parse-ast-comptime-decl-payload-message))])]
    [_ (ResultAstDecl.Err (parse-ast-comptime-decl-payload-message))]))

(define (parse-ast-comptime-decl-with-meta
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [meta : AstGeneratedDeclMeta]
  [template : SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-comptime-decl-payload dispatch pools template)
    [(ResultAstDecl.Ok decl)
      (ResultAstDecl.Ok (ast-decl-comptime-decl-with-meta meta decl))]
    [(ResultAstDecl.Err message) (ResultAstDecl.Err message)]))

(define (parse-ast-comptime-decl
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Cons first tail _)
      (match (sp-node-get tail)
        [(SpannedSexpr.Nil _)
          (parse-ast-comptime-decl-with-meta
            dispatch
            pools
            AstGeneratedDeclMeta.No
            (sp-node-get first))]
        [(SpannedSexpr.Cons template end _)
          (match (sp-node-get end)
            [(SpannedSexpr.Nil _)
              (match (parse-ast-generated-decl-meta
                dispatch
                pools
                (sp-node-get first))
                [(ResultAstGeneratedDeclMeta.Ok parsed-meta)
                  (parse-ast-comptime-decl-with-meta
                    dispatch
                    pools
                    parsed-meta
                    (sp-node-get template))]
                [(ResultAstGeneratedDeclMeta.Err message)
                  (ResultAstDecl.Err message)])]
            [_
              (ResultAstDecl.Err
                "parse: comptime-decl expects one template or generated metadata plus one template")])]
        [_
          (ResultAstDecl.Err
            "parse: comptime-decl expects one template or generated metadata plus one template")])]
    [_
      (ResultAstDecl.Err
        "parse: comptime-decl expects one template or generated metadata plus one template")]))

(define (parse-ast-unsafe-decl
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : SpannedSexpr]) : ResultAstDecl
  (match rest
    [(SpannedSexpr.Cons inner end _)
      (match (sp-node-get end)
        [(SpannedSexpr.Nil _)
          (match (parse-ast-decl dispatch pools (sp-node-get inner))
            [(ResultAstDecl.Ok decl)
              (match decl
                [(AstDecl.DefFn _ _ _ _ _)
                  (ResultAstDecl.Ok (ast-decl-unsafe decl))]
                [(AstDecl.Extern _ _ _ _)
                  (ResultAstDecl.Ok (ast-decl-unsafe decl))]
                [_
                  (ResultAstDecl.Err
                    "parse: unsafe declaration accepts only function define or extern")])]
            [(ResultAstDecl.Err message) (ResultAstDecl.Err message)])]
        [_
          (ResultAstDecl.Err
            "parse: unsafe declaration expects exactly one declaration")])]
    [_
      (ResultAstDecl.Err
        "parse: unsafe declaration expects exactly one declaration")]))

(define (parse-ast-module-macro-call
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [form : SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-expr-with-pools dispatch pools form)
    [(ResultAstExpr.Ok call-expr)
      (match (ast-expr-unspan-with-pools
        pools
        (ast-node-pool-context-expr-get pools call-expr))
        [(AstExpr.Call _ _)
          (parse-ast-import-spec
            (AstImportKind.MacroDecls call-expr AstMaybeModuleName.No)
            ""
            AstMaybeModuleName.No
            AstMaybeImportAlias.No
            (ast-source-span-from-source-span (spanned-sexpr-span form)))]
        [_ (ResultAstDecl.Err "parse: expected declaration")])]
    [(ResultAstExpr.Err message) (ResultAstDecl.Err message)]))

(define (parse-ast-decl
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]) : ResultAstDecl
  (let
    [result : ResultAstDecl
      (match s
        [(SpannedSexpr.Cons head-node rest _)
          (match (sp-node-get head-node)
            [(SpannedSexpr.Sym head _)
              (let
                [tag : i64 (compiler-parse-dispatch-tag dispatch head)]
                (cond
                  [(= tag (compiler-parse-tag-decl-define))
                    (parse-ast-define dispatch pools (sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-extern))
                    (parse-ast-extern dispatch pools (sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-defenum))
                    (parse-ast-defenum dispatch pools (sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-defstruct))
                    (parse-ast-defstruct dispatch pools (sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-defdispatch))
                    (parse-ast-defdispatch (sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-defmacro))
                    (parse-ast-defmacro dispatch pools (sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-import))
                    (parse-ast-import
                      dispatch
                      pools
                      (sp-node-get rest)
                      (ast-source-span-from-source-span (spanned-sexpr-span s)))]
                  [(= tag (compiler-parse-tag-decl-include-str))
                    (parse-ast-include-str (sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-include-bin))
                    (parse-ast-include-bin (sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-module))
                    (parse-ast-module dispatch pools (sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-comptime-decl))
                    (parse-ast-comptime-decl dispatch pools (sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-comptime-decls))
                    (ResultAstDecl.Err
                      (parse-ast-comptime-decls-removed-message))]
                  [(= tag (compiler-parse-tag-expr-unsafe))
                    (parse-ast-unsafe-decl dispatch pools (sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-test))
                    (parse-ast-test
                      dispatch
                      pools
                      (sp-node-get rest)
                      (ast-source-span-from-source-span (spanned-sexpr-span s)))]
                  [(compiler-parse-policy-form? head)
                    (ResultAstDecl.Err
                      (compiler-parse-abstraction-policy-message))]
                  [else (parse-ast-module-macro-call dispatch pools s)]))]
            [_ (ResultAstDecl.Err "parse: malformed declaration")])]
        [_ (ResultAstDecl.Err "parse: malformed declaration")])]
    (parse-ast-error-span-note-decl s result)))

(define (parse-ast-decl-maybe-with-pools
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : SpannedSexpr]) : ResultAstMaybeDecl
  (let
    [result : ResultAstMaybeDecl
      (match s
        [(SpannedSexpr.Cons head-node rest _)
          (match (sp-node-get head-node)
            [(SpannedSexpr.Sym head _)
              (if (string.eq head "cfg")
                (match (sp-node-get rest)
                  [(SpannedSexpr.Cons pred decl-tail _)
                    (match (sp-node-get decl-tail)
                      [(SpannedSexpr.Cons decl-form end _)
                        (match (sp-node-get end)
                          [(SpannedSexpr.Nil _)
                            (match (compiler-cfg-eval
                              dispatch
                              (sp-node-get pred))
                              [(ResultCompilerCfg.Ok enabled)
                                (if enabled
                                  (parse-ast-decl-maybe-with-pools
                                    dispatch
                                    pools
                                    (sp-node-get decl-form))
                                  (ResultAstMaybeDecl.NoDecl))]
                              [(ResultCompilerCfg.Err message)
                                (ResultAstMaybeDecl.Err message)])]
                          [_
                            (ResultAstMaybeDecl.Err
                              "parse: cfg declaration expects predicate and declaration")])]
                      [_
                        (ResultAstMaybeDecl.Err
                          "parse: cfg declaration expects predicate and declaration")])]
                  [_
                    (ResultAstMaybeDecl.Err
                      "parse: cfg declaration expects predicate and declaration")])
                (if (=
                  (compiler-parse-dispatch-tag dispatch head)
                  (compiler-parse-tag-decl-comptime-decls))
                  (ResultAstMaybeDecl.Err
                    (parse-ast-comptime-decls-removed-message))
                  (match (parse-ast-decl dispatch pools s)
                    [(ResultAstDecl.Ok decl) (ResultAstMaybeDecl.SomeDecl decl)]
                    [(ResultAstDecl.Err message)
                      (ResultAstMaybeDecl.Err message)])))]
            [_
              (match (parse-ast-decl dispatch pools s)
                [(ResultAstDecl.Ok decl) (ResultAstMaybeDecl.SomeDecl decl)]
                [(ResultAstDecl.Err message) (ResultAstMaybeDecl.Err message)])])]
        [_ (ResultAstMaybeDecl.Err "parse: malformed declaration")])]
    (parse-ast-error-span-note-maybe-decl s result)))

(define (parse-ast-decl-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [s : SpannedSexpr]) : ResultAstMaybeDecl
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstMaybeDecl
      (parse-ast-decl-maybe-with-pools dispatch pools s)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(defstruct ParseAstDeclVec
  (slots (Array AstDecl))
  (spans (Array AstSourceSpan))
  (len i64))

(define (parse-ast-decl-vec-fallback) : AstDecl
  (AstDecl.Module (intern "<parse-ast-decl-vec-fallback>")))

(define (parse-ast-decl-vec-with-capacity [capacity : i64]) : ParseAstDeclVec
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (ParseAstDeclVec (make-array AstDecl cap) (make-array AstSourceSpan cap) 0)))

(define (parse-ast-decl-vec-new) : ParseAstDeclVec
  (parse-ast-decl-vec-with-capacity 16))

(define (parse-ast-decl-vec-len [v : (& v ParseAstDeclVec)]) : i64
  (struct-get v len))

(define (parse-ast-decl-vec-capacity [v : (& v ParseAstDeclVec)]) : i64
  (array-length (struct-get v slots)))

(define (parse-ast-decl-vec-get
  [v : (& v ParseAstDeclVec)]
  [index : i64]
  [fallback : AstDecl]) : AstDecl
  (if (and (>= index 0) (< index (parse-ast-decl-vec-len v)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (parse-ast-decl-vec-span-get
  [v : (& v ParseAstDeclVec)]
  [index : i64]
  [fallback : AstSourceSpan]) : AstSourceSpan
  (if (and (>= index 0) (< index (parse-ast-decl-vec-len v)))
    (array-ref (struct-get v spans) index)
    fallback))

(define (parse-ast-decl-vec-copy-range
  [dst : (&mut dst (Array AstDecl))]
  [src : (& src (Array AstDecl))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (parse-ast-decl-vec-copy-range dst src (+ index 1) count))))

(define (parse-ast-decl-vec-span-copy-range
  [dst : (&mut dst (Array AstSourceSpan))]
  [src : (& src (Array AstSourceSpan))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (parse-ast-decl-vec-span-copy-range dst src (+ index 1) count))))

(define (parse-ast-decl-vec-grow [v : (&mut v ParseAstDeclVec)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstDecl) (make-array AstDecl new-cap)]
    [bigger-spans : (Array AstSourceSpan) (make-array AstSourceSpan new-cap)]
    (begin
      (parse-ast-decl-vec-copy-range (&mut bigger) (& (struct-get v slots)) 0 n)
      (parse-ast-decl-vec-span-copy-range
        (&mut bigger-spans)
        (& (struct-get v spans))
        0
        n)
      (set! (struct-get v slots) bigger)
      (set! (struct-get v spans) bigger-spans))))

(define (parse-ast-decl-vec-push-with-span
  [v : (&mut v ParseAstDeclVec)]
  [value : AstDecl]
  [span : AstSourceSpan]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (parse-ast-decl-vec-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (array-set! (struct-get v spans) index span)
        (set! (struct-get v len) (+ index 1))))))

(define (parse-ast-decl-vec-push
  [v : (&mut v ParseAstDeclVec)]
  [value : AstDecl]) : unit
  (parse-ast-decl-vec-push-with-span v value (ast-decl-span-fallback)))

(define (parse-ast-decl-vec-push-list!
  [out : (&mut out ParseAstDeclVec)]
  [decls : AstDeclList]) : unit
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) unit]
    [(AstDeclListStep.Cons head rest)
      (begin
        (parse-ast-decl-vec-push out head)
        (parse-ast-decl-vec-push-list! out rest))]))

(define (parse-ast-decl-vec-copy-to-list
  [items : (& items ParseAstDeclVec)]
  [index : i64]
  [out : (&mut out AstDeclList)]) : unit
  (if (>= index (parse-ast-decl-vec-len items))
    unit
    (begin
      (ast-decl-list-push
        out
        (parse-ast-decl-vec-get items index (parse-ast-decl-vec-fallback)))
      (parse-ast-decl-vec-copy-to-list items (+ index 1) out))))

(define (parse-ast-decl-vec-to-list [items : (& items ParseAstDeclVec)]) : AstDeclList
  (let
    [out : AstDeclList
      (ast-decl-list-with-capacity (parse-ast-decl-vec-len items))]
    (begin
      (parse-ast-decl-vec-copy-to-list items 0 (&mut out))
      out)))

(define (parse-ast-program-forms-into-vec
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]
  [out : (&mut out ParseAstDeclVec)]) : ResultParseAstDeclVec
  (if (= (peek-spanned-tag toks cur) (token.tag-end))
    (ResultParseAstDeclVec.Ok)
    (let
      ;; The spanned tree for one top-level form is dead once its AstDecl is
      ;; built (the decl carries AST-pool ids + spans by value, no sp ids), so
      ;; truncate the spanned pool back to here before reading the next form.
      ;; Bounds the spanned pool to a single form so it never has to grow.
      [mark : i64 (sp-node-pool-len)]
      (match (read-form-spanned-result toks cur)
        [(ResultSpannedSexpr.Ok form)
          (match (parse-ast-decl-maybe-with-pools dispatch pools form)
            [(ResultAstMaybeDecl.SomeDecl decl)
              (begin
                (parse-ast-decl-vec-push-with-span
                  out
                  decl
                  (ast-source-span-from-source-span (spanned-sexpr-span form)))
                (sp-node-pool-truncate! mark)
                (parse-ast-program-forms-into-vec dispatch pools toks cur out))]
            [(ResultAstMaybeDecl.Decls decls)
              (begin
                (sp-node-pool-truncate! mark)
                (parse-ast-decl-vec-push-list! out decls)
                (parse-ast-program-forms-into-vec dispatch pools toks cur out))]
            [(ResultAstMaybeDecl.NoDecl)
              (begin
                (sp-node-pool-truncate! mark)
                (parse-ast-program-forms-into-vec dispatch pools toks cur out))]
            [(ResultAstMaybeDecl.Err message)
              (ResultParseAstDeclVec.Err message)])]
        [(ResultSpannedSexpr.Err err)
          (ResultParseAstDeclVec.Err (token.source-error-message err))]))))

(define (parse-ast-program-forms
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]) : ResultAstDeclList
  (let
    [out : ParseAstDeclVec (parse-ast-decl-vec-new)]
    [result : ResultParseAstDeclVec
      (parse-ast-program-forms-into-vec dispatch pools toks cur (&mut out))]
    (match result
      [(ResultParseAstDeclVec.Ok)
        (ResultAstDeclList.Ok (parse-ast-decl-vec-to-list (& out)))]
      [(ResultParseAstDeclVec.Err message) (ResultAstDeclList.Err message)])))

(define (parse-ast-program-dispatch) : sym_i64_env.SymI64Env
  (compiler-parse-dispatch-env))

(define (parse-ast-program-dispatch-with-cfg [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (match cfgs
    [(sym_i64_env.SymI64Nil) (compiler-parse-dispatch-env)]
    [_
      (compiler-parse-dispatch-index-mark
        (compiler-cfg-merge (compiler-parse-dispatch-env) cfgs))]))

(define (parse-ast-program-with-cfg-and-pools
  [toks : (Array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgram
  (let
    [cur : (Array i64) (array.make-array i64 1)]
    [dispatch : sym_i64_env.SymI64Env
      (parse-ast-program-dispatch-with-cfg cfgs)]
    (begin
      (sp-node-pool-reset!)
      (array-set! cur 0 0)
      (match (parse-ast-program-forms dispatch pools toks cur)
        [(ResultAstDeclList.Ok decls) (ResultAstProgram.Ok (ast-program decls))]
        [(ResultAstDeclList.Err message) (ResultAstProgram.Err message)]))))

(define (parse-ast-program-with-cfg
  [toks : (Array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgram
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstProgram
      (parse-ast-program-with-cfg-and-pools toks cfgs pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-program [toks : (Array token.SpannedToken)]) : ResultAstProgram
  (parse-ast-program-with-cfg toks (compiler-cfg-empty)))

(define (parse-ast-source [src : String]) : ResultAstProgram
  (parse-ast-source-with-cfg src (compiler-cfg-empty)))

(define (parse-ast-source-with-cfg-and-pools
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgram
  (match (lex-spanned-result src)
    [(ResultSpannedTokens.Ok toks)
      (parse-ast-program-with-cfg-and-pools toks cfgs pools)]
    [(ResultSpannedTokens.Err err)
      (ResultAstProgram.Err (token.source-error-message err))]))

(define (parse-ast-source-with-cfg
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgram
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstProgram
      (parse-ast-source-with-cfg-and-pools src cfgs pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-repl-module-macro-call-decl? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Import
        (AstImportSpec.Spec
          (AstImportKind.MacroDecls _ _)
          path
          (AstMaybeModuleName.No)
          (AstMaybeImportAlias.No)
          _))
      (string.eq path "")]
    [_ false]))

(define (parse-ast-repl-expr-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [form : SpannedSexpr]) : ResultAstReplItem
  (match (parse-ast-expr-with-pools dispatch pools form)
    [(ResultAstExpr.Ok expr) (ResultAstReplItem.Ok (AstReplExpr expr))]
    [(ResultAstExpr.Err message) (ResultAstReplItem.Err message)]))

(define (parse-ast-repl-source-with-pools
  [src : String]
  [pools : AstNodePoolContext]) : ResultAstReplItem
  (match (lex-spanned-result src)
    [(ResultSpannedTokens.Ok toks)
      (let
        [cur : (Array i64) (array.make-array i64 1)]
        [dispatch : sym_i64_env.SymI64Env (parse-ast-program-dispatch)]
        (begin
          (sp-node-pool-reset!)
          (array-set! cur 0 0)
          (if (= (peek-spanned-tag toks cur) (token.tag-end))
            (ResultAstReplItem.Err "parse: expected REPL input")
            (match (read-form-spanned-result toks cur)
              [(ResultSpannedSexpr.Ok form)
                (if (= (peek-spanned-tag toks cur) (token.tag-end))
                  (match (parse-ast-decl dispatch pools form)
                    [(ResultAstDecl.Ok decl)
                      (if (parse-ast-repl-module-macro-call-decl? decl)
                        (parse-ast-repl-expr-item dispatch pools form)
                        (ResultAstReplItem.Ok (AstReplDecl decl)))]
                    [(ResultAstDecl.Err _)
                      (parse-ast-repl-expr-item dispatch pools form)])
                  (ResultAstReplItem.Err
                    "parse: trailing tokens after REPL input"))]
              [(ResultSpannedSexpr.Err err)
                (ResultAstReplItem.Err (token.source-error-message err))]))))]
    [(ResultSpannedTokens.Err err)
      (ResultAstReplItem.Err (token.source-error-message err))]))

(define (parse-ast-repl-source [src : String]) : ResultAstReplItem
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstReplItem (parse-ast-repl-source-with-pools src pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-canonical-diagnostic [diag : CompilerDiagnostic]) : CompilerDiagnostic
  (let
    [canonical : CompilerDiagnostic
      (compiler-diagnostic-with-category
        (compiler-diagnostic-with-code diag (compiler-diagnostic-code-parse))
        "parse")]
    (if (parse-ast-if-message? (compiler-diagnostic-message canonical))
      (parse-ast-if-diagnostic-notes canonical)
      canonical)))

(define (parse-ast-program-forms-diagnostic-into-vec
  [path : String]
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]
  [out : (&mut out ParseAstDeclVec)]) : ResultParseAstDeclVecDiagnostic
  (if (= (peek-spanned-tag toks cur) (token.tag-end))
    (ResultParseAstDeclVecDiagnostic.Ok)
    (let
      ;; Bound the spanned pool to a single top-level form (see
      ;; parse-ast-program-forms): the decl carries no sp ids, so truncate back
      ;; before reading the next form.
      [mark : i64 (sp-node-pool-len)]
      (match (read-form-spanned-result toks cur)
        [(ResultSpannedSexpr.Ok spanned-form)
          (begin
            (parse-ast-error-span-clear!)
            (match (parse-ast-decl-maybe-with-pools dispatch pools spanned-form)
              [(ResultAstMaybeDecl.SomeDecl decl)
                (begin
                  (parse-ast-decl-vec-push-with-span
                    out
                    decl
                    (ast-source-span-from-source-span
                      (spanned-sexpr-span spanned-form)))
                  (sp-node-pool-truncate! mark)
                  (parse-ast-program-forms-diagnostic-into-vec
                    path
                    dispatch
                    pools
                    toks
                    cur
                    out))]
              [(ResultAstMaybeDecl.Decls decls)
                (begin
                  (sp-node-pool-truncate! mark)
                  (parse-ast-decl-vec-push-list! out decls)
                  (parse-ast-program-forms-diagnostic-into-vec
                    path
                    dispatch
                    pools
                    toks
                    cur
                    out))]
              [(ResultAstMaybeDecl.NoDecl)
                (begin
                  (sp-node-pool-truncate! mark)
                  (parse-ast-program-forms-diagnostic-into-vec
                    path
                    dispatch
                    pools
                    toks
                    cur
                    out))]
              [(ResultAstMaybeDecl.Err message)
                (ResultParseAstDeclVecDiagnostic.Err
                  (box
                    (parse-ast-canonical-diagnostic
                      (compiler-diagnostic-from-span
                        path
                        (parse-ast-error-span-current
                          (spanned-sexpr-span spanned-form))
                        message))))]))]
        [(ResultSpannedSexpr.Err err)
          (ResultParseAstDeclVecDiagnostic.Err
            (box
              (parse-ast-canonical-diagnostic
                (compiler-diagnostic-from-source-error path err))))]))))

(define (parse-ast-program-forms-diagnostic
  [path : String]
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]) : ResultAstDeclListDiagnostic
  (let
    [out : ParseAstDeclVec (parse-ast-decl-vec-new)]
    [result : ResultParseAstDeclVecDiagnostic
      (parse-ast-program-forms-diagnostic-into-vec
        path
        dispatch
        pools
        toks
        cur
        (&mut out))]
    (match result
      [(ResultParseAstDeclVecDiagnostic.Ok)
        (ResultAstDeclListDiagnostic.Ok (parse-ast-decl-vec-to-list (& out)))]
      [(ResultParseAstDeclVecDiagnostic.Err diag)
        (ResultAstDeclListDiagnostic.Err diag)])))

(define (parse-ast-program-diagnostic
  [path : String]
  [toks : (Array token.SpannedToken)]) : ResultAstProgramDiagnostic
  (parse-ast-program-diagnostic-with-cfg path toks (compiler-cfg-empty)))

(define (parse-ast-program-diagnostic-with-cfg-and-pools
  [path : String]
  [toks : (Array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (let
    [cur : (Array i64) (array.make-array i64 1)]
    [dispatch : sym_i64_env.SymI64Env
      (parse-ast-program-dispatch-with-cfg cfgs)]
    (begin
      (sp-node-pool-reset!)
      (array-set! cur 0 0)
      (match (parse-ast-program-forms-diagnostic path dispatch pools toks cur)
        [(ResultAstDeclListDiagnostic.Ok decls)
          (ResultAstProgramDiagnostic.Ok (ast-program decls))]
        [(ResultAstDeclListDiagnostic.Err diag)
          (ResultAstProgramDiagnostic.Err diag)]))))

(define (parse-ast-program-diagnostic-with-cfg
  [path : String]
  [toks : (Array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstProgramDiagnostic
      (parse-ast-program-diagnostic-with-cfg-and-pools path toks cfgs pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-source-diagnostic [path : String] [src : String]) : ResultAstProgramDiagnostic
  (parse-ast-source-diagnostic-with-cfg path src (compiler-cfg-empty)))

(define (parse-ast-source-diagnostic-with-cfg-and-pools
  [path : String]
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (match (lex-spanned-result src)
    [(ResultSpannedTokens.Ok toks)
      (parse-ast-program-diagnostic-with-cfg-and-pools path toks cfgs pools)]
    [(ResultSpannedTokens.Err err)
      (ResultAstProgramDiagnostic.Err
        (box
          (parse-ast-canonical-diagnostic
            (compiler-diagnostic-from-source-error path err))))]))

(define (parse-ast-source-diagnostic-with-cfg
  [path : String]
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstProgramDiagnostic
      (parse-ast-source-diagnostic-with-cfg-and-pools path src cfgs pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (ast-decl-list-count [decls : AstDeclList]) : i64
  (ast-decl-list-len (& decls)))

(define (ast-decl-list-tag-sum [decls : AstDeclList]) : i64
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) 0]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (+ (ast-decl-tag decl) (ast-decl-list-tag-sum rest)))]))

(define (compiler-parse-expr-list-count [exprs : AstExprList]) : i64
  (struct-get (& exprs) len))

(define (compiler-parse-macro-call-node-ok?
  [call-expr : i64]
  [name : String]
  [want-args : i64]) : bool
  (match (ast-expr-unspan (ast-node-get call-expr))
    [(AstExpr.Call head args)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        (and
          (= (compiler-parse-expr-list-count args) want-args)
          (match (ast-expr-unspan head-expr)
            [(AstExpr.Var found) (string.eq (intern-str found) name)]
            [_ false])))]
    [_ false]))

(define (compiler-parse-resource-binding-count
  [bindings : AstResourceBindingList]) : i64
  (ast-resource-binding-list-len (& bindings)))

(define (ast-first-import-ok? [decls : AstDeclList]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Cons
        (AstDecl.Import (AstImportSpec.Spec (AstImportKind.Path) path _ _ _))
        _)
      (string.eq path "stdlib/test.tl")]
    [_ false]))

(define (ast-first-include-str-ok? [decls : AstDeclList]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Cons (AstDecl.IncludeStr name path) _)
      (and (string.eq name "payload") (string.eq path "data.txt"))]
    [_ false]))

(define (ast-first-include-bin-ok? [decls : AstDeclList]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Cons (AstDecl.IncludeBin name path) _)
      (and (string.eq name "payload") (string.eq path "data.bin"))]
    [_ false]))

(define (compiler-parse-module-decl-ok?) : bool
  (match (parse-ast-source "(module std.io)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.Module name) rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil) (= name (intern "std.io"))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-module-body-ok?) : bool
  (match (parse-ast-source "(module local.helper (define value : i64 1))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.ModuleBody name body-box) rest)
            (let
              [rest : AstDeclList rest]
              [body : AstDeclList (box-get body-box)]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-decl-list-step body)
                    [(AstDeclListStep.Cons
                        (AstDecl.Def value-name _ _)
                        body-rest)
                      (let
                        [body-rest : AstDeclList body-rest]
                        (and
                          (= name (intern "local.helper"))
                          (= value-name (intern "value"))
                          (match (ast-decl-list-step body-rest)
                            [(AstDeclListStep.Nil) true]
                            [_ false])))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-module-body-malformed-ok?) : bool
  (match (parse-ast-source "(module local.helper (define bad))")
    [(ResultAstProgram.Ok _) false]
    [(ResultAstProgram.Err message)
      (string.eq message "parse: malformed value definition")]))

(define (compiler-parse-import-metadata-ok?) : bool
  (match (parse-ast-source "(import \"stdlib/tl\" module std.io :as io)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.Import
                (AstImportSpec.Spec
                  (AstImportKind.Path)
                  path
                  (AstMaybeModuleName.Some module-name)
                  (AstMaybeImportAlias.Some alias)
                  _))
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (string.eq path "stdlib/tl")
                    (string.eq module-name "std.io")
                    (string.eq alias "io"))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-explicit-alias-ok?) : bool
  (match (parse-ast-source "(import stdlib.core_macros :as core)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.Import
                (AstImportSpec.Spec
                  (AstImportKind.Module)
                  module-path
                  (AstMaybeModuleName.Some module-name)
                  (AstMaybeImportAlias.Some alias)
                  _))
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (string.eq module-path "stdlib.core_macros")
                    (string.eq module-name "stdlib.core_macros")
                    (string.eq alias "core"))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-default-alias-ok?) : bool
  (match (parse-ast-source "(import stdlib.core_macros)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.Import
                (AstImportSpec.Spec
                  (AstImportKind.Module)
                  module-path
                  (AstMaybeModuleName.Some module-name)
                  (AstMaybeImportAlias.Some alias)
                  _))
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (string.eq module-path "stdlib.core_macros")
                    (string.eq module-name "stdlib.core_macros")
                    (string.eq alias "core_macros"))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-metadata-ok?) : bool
  (and
    (compiler-parse-dotted-import-explicit-alias-ok?)
    (compiler-parse-dotted-import-default-alias-ok?)))

(define (compiler-parse-module-macro-call-ok?) : bool
  (match (parse-ast-source "(point-vec i64)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.Import
                (AstImportSpec.Spec
                  (AstImportKind.MacroDecls call-expr _)
                  path
                  (AstMaybeModuleName.No)
                  (AstMaybeImportAlias.No)
                  _))
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (string.eq path "")
                    (compiler-parse-macro-call-node-ok? call-expr "point-vec" 1))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-macro-import-ok?) : bool
  (match (parse-ast-source "(import (vector i64) as svec)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.Import
                (AstImportSpec.Spec
                  (AstImportKind.Macro call-expr _)
                  path
                  (AstMaybeModuleName.No)
                  (AstMaybeImportAlias.Some alias)
                  _))
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (string.eq path "")
                    (string.eq alias "svec")
                    (compiler-parse-macro-call-node-ok? call-expr "vector" 1))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

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
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (ast-first-include-str-ok? decls))]
    [(ResultAstProgram.Err _) false]))

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
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (ast-first-include-bin-ok? decls))]
    [(ResultAstProgram.Err _) false]))

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

(define (compiler-parse-defdispatch-variants-ok?
  [variants : AstDispatchVariantList]) : bool
  (if (= (struct-get (& variants) len) 3)
    (match (ast-dispatch-variant-list-get
      (& variants)
      0
      (ast-dispatch-variant-fallback))
      [(AstDispatchVariant.Variant (AstDispatchIsa.Scalar) scalar-name)
        (match (ast-dispatch-variant-list-get
          (& variants)
          1
          (ast-dispatch-variant-fallback))
          [(AstDispatchVariant.Variant (AstDispatchIsa.Avx2) avx2-name)
            (match (ast-dispatch-variant-list-get
              (& variants)
              2
              (ast-dispatch-variant-fallback))
              [(AstDispatchVariant.Variant (AstDispatchIsa.Avx512) avx512-name)
                (and
                  (string.eq scalar-name "dot-scalar")
                  (string.eq avx2-name "dot-avx2")
                  (string.eq avx512-name "dot-avx512"))]
              [_ false])]
          [_ false])]
      [_ false])
    false))

(define (compiler-parse-defdispatch-shape-ok?) : bool
  (match (parse-ast-source
    "(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefDispatch name variants) rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (intern "dot"))
                    (compiler-parse-defdispatch-variants-ok? variants))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-defdispatch-scalar-only-ok?) : bool
  (match (parse-ast-source "(defdispatch id (scalar id-scalar))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefDispatch name variants) rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (intern "id"))
                    (= (struct-get (& variants) len) 1)
                    (match (ast-dispatch-variant-list-get
                      (& variants)
                      0
                      (ast-dispatch-variant-fallback))
                      [(AstDispatchVariant.Variant
                          (AstDispatchIsa.Scalar)
                          scalar-name)
                        (string.eq scalar-name "id-scalar")]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

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

(define (ast-expr-inner-tag [expr : AstExpr]) : i64
  (ast-expr-tag (ast-expr-unspan expr)))

(define (ast-main-body-tag [decls : AstDeclList]) : i64
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) 0]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.DefFn name _ _ body-box _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (if (= name (intern "main"))
                (ast-expr-inner-tag body)
                (ast-main-body-tag rest)))]
          [_ (ast-main-body-tag rest)]))]))

(define (compiler-parse-nested-expr-span-ok?) : bool
  (match (parse-ast-source "(define (main) : i64 (+ 1 (* 2 3)))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn _ _ _ body-box _) _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (match body
                [(AstExpr.Spanned inner-box body-span)
                  (let
                    [inner : AstExpr (ast-node-get inner-box)]
                    (match inner
                      [(AstExpr.Binary _ _ right-box)
                        (let
                          [right : AstExpr (ast-node-get right-box)]
                          (match right
                            [(AstExpr.Spanned right-inner-box right-span)
                              (let
                                [right-inner : AstExpr
                                  (ast-node-get right-inner-box)]
                                (match right-inner
                                  [(AstExpr.Binary _ _ _)
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
        [(ResultAstProgram.Err message)
          (string.eq message "parse: malformed define")]
        [_ false])
      (match (lex-spanned-result src)
        [(ResultSpannedTokens.Ok toks)
          (let
            [cur : (Array i64) (make-array i64 1)]
            (begin
              (array-set! cur 0 0)
              (match (read-form-spanned-result toks cur)
                [(ResultSpannedSexpr.Ok form)
                  (let
                    [span : token.SourceSpan (spanned-sexpr-span form)]
                    (and
                      (= (token.span-start-line span) 1)
                      (= (token.span-start-col span) 1)))]
                [(ResultSpannedSexpr.Err _) false])))]
        [(ResultSpannedTokens.Err _) false]))))

(define (compiler-parse-reader-diagnostic-ok?
  [path : String]
  [src : String]
  [want : String]
  [line : i64]
  [col : i64]) : bool
  (match (parse-ast-source-diagnostic path src)
    [(ResultAstProgramDiagnostic.Err diag)
      (and
        (string.eq (compiler-diagnostic-path (box-get diag)) path)
        (= (compiler-diagnostic-line (box-get diag)) line)
        (= (compiler-diagnostic-col (box-get diag)) col)
        (string.eq (compiler-diagnostic-message (box-get diag)) want))]
    [(ResultAstProgramDiagnostic.Ok _) false]))

(define (compiler-parse-diagnostic-location-ok?
  [path : String]
  [src : String]
  [want : String]
  [line : i64]
  [col : i64]) : bool
  (match (parse-ast-source-diagnostic path src)
    [(ResultAstProgramDiagnostic.Err diag)
      (and
        (string.eq (compiler-diagnostic-path (box-get diag)) path)
        (= (compiler-diagnostic-line (box-get diag)) line)
        (= (compiler-diagnostic-col (box-get diag)) col)
        (string.eq (compiler-diagnostic-message (box-get diag)) want))]
    [(ResultAstProgramDiagnostic.Ok _) false]))

(define (compiler-parse-nested-diagnostic-spans-ok?) : bool
  (and
    (compiler-parse-diagnostic-location-ok?
      "bad-define.tl"
      "(define)"
      "parse: malformed define"
      1
      1)
    (compiler-parse-diagnostic-location-ok?
      "nested-binary.tl"
      "(define (main) : i64
  (+ 1))"
      "parse: malformed binary expression"
      2
      3)
    (compiler-parse-diagnostic-location-ok?
      "nested-let.tl"
      "(define (main) : i64
  (let [x : i64 1]))"
      "parse: let missing body"
      2
      3)
    (compiler-parse-diagnostic-location-ok?
      "annotation-type.tl"
      "(define (main) : i64
  (cast 1 : (Ptr)))"
      "parse: Ptr expects exactly one type"
      2
      13)
    (compiler-parse-diagnostic-location-ok?
      "let-binding.tl"
      "(define (main) : i64
  (let [x : i64] x))"
      "parse: malformed let binding"
      2
      8)))

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
      8)
    (compiler-parse-reader-diagnostic-ok?
      "wrong-close-bracket.tl"
      "[define)"
      "reader: mismatched delimiter: expected ']' but found ')' at 1:8"
      1
      8)))

(define (compiler-parse-float-literal-ok?) : bool
  (match (parse-ast-source "(define (main) : f64 1.5)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn name _ (AstType.F64) body-box _)
              _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (and
                (= name (intern "main"))
                (match (ast-expr-unspan body)
                  [(AstExpr.Literal (AstLiteral.Float text))
                    (string.eq text "1.5")]
                  [_ false])))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-smoke-source) : String
  "(import \"stdlib/test.tl\")
(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(extern (io.print-string [arg0 : String]) : unit)
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
    [(AstProgram.Program decls-box)
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
;; messages so a regression that drops or relabels an error is caught.
(define (compiler-parse-error-ok? [src : String] [want : String]) : bool
  (match (parse-ast-source src)
    [(ResultAstProgram.Err message) (string.eq message want)]
    [(ResultAstProgram.Ok _) false]))

(define (compiler-parse-error-ok-with-cfg?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [want : String]) : bool
  (match (parse-ast-source-with-cfg src cfgs)
    [(ResultAstProgram.Err message) (string.eq message want)]
    [(ResultAstProgram.Ok _) false]))

(define (compiler-parse-diagnostic-code-ok?) : bool
  (match (parse-ast-source-diagnostic
    "parse-code.tl"
    (compiler-parse-malformed-binary-source))
    [(ResultAstProgramDiagnostic.Err diag)
      (match (compiler-diagnostic-code (box-get diag))
        [(CompilerDiagnosticSomeString code)
          (and
            (string.eq code (compiler-diagnostic-code-parse))
            (match (compiler-diagnostic-category (box-get diag))
              [(CompilerDiagnosticSomeString category)
                (string.eq category "parse")]
              [CompilerDiagnosticNoString false]))]
        [CompilerDiagnosticNoString false])]
    [(ResultAstProgramDiagnostic.Ok _) false]))

;; Minimal complete programs that lex cleanly but reach a specific parser
;; rejection, one per representative special form.
(define (compiler-parse-malformed-binary-source) : String
  "(define (main) : i64 (+ 1))")

(define (compiler-parse-malformed-if-source) : String
  "(define (main) : i64 (if true 1))")

(define (compiler-parse-if-missing-else-diagnostic-notes-ok?) : bool
  (match (parse-ast-source-diagnostic
    "missing-if-else.tl"
    (compiler-parse-malformed-if-source))
    [(ResultAstProgramDiagnostic.Err diag)
      (let
        [rendered : String (compiler-diagnostic-render (box-get diag))]
        [message-needle : String "parse: if is missing its else branch"]
        [example-needle : String "example: (if condition then-expr else-expr)"]
        [when-needle : String "when condition body..."]
        [unless-needle : String "unless condition body..."]
        (and
          (string.contains (& rendered) (& message-needle))
          (string.contains (& rendered) (& example-needle))
          (string.contains (& rendered) (& when-needle))
          (string.contains (& rendered) (& unless-needle))))]
    [(ResultAstProgramDiagnostic.Ok _) false]))

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
    [(ResultAstProgram.Ok _) true]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-arena-source) : String
  "(define (main) : i64
  (with-arena r 5))")

;; `with-arena` is the canonical spelling. Assert it parses to
;; the `AstExpr.WithRegion` form, not an unbound call.
(define (compiler-parse-arena-ok?) : bool
  (match (parse-ast-source (compiler-parse-arena-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn name _ (AstType.I64) body-box _)
              _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (and
                (= name (intern "main"))
                (match (ast-expr-unspan body)
                  [(AstExpr.WithRegion region _) (string.eq region "r")]
                  [_ false])))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-raw-pointer-source) : String
  "(extern (raw-map [arg0 : (Ptr i64)]) : (MutPtr (Ptr u8)))")

(define (compiler-parse-type-ptr-u8? [ty : AstType]) : bool
  (match ty
    [(AstType.Ptr elem)
      (match (ty-node-get elem)
        [(AstType.U8) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-ptr-i64? [ty : AstType]) : bool
  (match ty
    [(AstType.Ptr elem)
      (match (ty-node-get elem)
        [(AstType.I64) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-mut-ptr-u8? [ty : AstType]) : bool
  (match ty
    [(AstType.MutPtr elem)
      (match (ty-node-get elem)
        [(AstType.U8) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-mut-ptr-ptr-u8? [ty : AstType]) : bool
  (match ty
    [(AstType.MutPtr elem) (compiler-parse-type-ptr-u8? (ty-node-get elem))]
    [_ false]))

(define (compiler-parse-type-ref-string? [ty : AstType] [region : String]) : bool
  (match ty
    [(AstType.Ref actual inner)
      (and
        (string.eq actual region)
        (match (ty-node-get inner)
          [(AstType.String) true]
          [_ false]))]
    [_ false]))

(define (compiler-parse-type-ref-str? [ty : AstType] [region : String]) : bool
  (match ty
    [(AstType.Ref actual inner)
      (and
        (string.eq actual region)
        (match (ty-node-get inner)
          [(AstType.Str) true]
          [_ false]))]
    [_ false]))

(define (compiler-parse-type-mut-ref-dyn-array-i64?
  [ty : AstType]
  [region : String]) : bool
  (match ty
    [(AstType.MutRef actual inner)
      (and
        (string.eq actual region)
        (match (ty-node-get inner)
          [(AstType.DynArray elem)
            (match (ty-node-get elem)
              [(AstType.I64) true]
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
  (ast-param-list-len (& params)))

(define (compiler-parse-type-list-count [types : AstTypeList]) : i64
  (ast-type-list-len (& types)))

(define (compiler-parse-raw-pointer-ops-source) : String
  "(define (main [p : (MutPtr i64)] [n : u64]) : u64
  (unsafe
    (ptr-write! p (ptr-read p))
    (ptr->int (ptr-cast (ptr-offset (int->ptr n : (MutPtr i64)) 1) : (Ptr i64)))))")

(define (compiler-parse-raw-pointer-ok?) : bool
  (match (parse-ast-source (compiler-parse-raw-pointer-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.Extern name _ _ ty) rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (intern "raw-map"))
                    (match ty
                      [(AstType.Func args ret)
                        (let
                          [args-list : AstTypeList (box-get args)]
                          (and
                            (= (ast-type-list-len (& args-list)) 1)
                            (compiler-parse-type-ptr-i64?
                              (ty-node-get
                                (ast-type-list-get
                                  (& args-list)
                                  0
                                  (ast-type-id-fallback))))
                            (compiler-parse-type-mut-ptr-ptr-u8?
                              (ty-node-get ret))))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-extern-link-inputs-ok?
  [inputs : AstExternLinkInputList]) : bool
  (and
    (= (ast-extern-link-input-list-len (& inputs)) 3)
    (match (ast-extern-link-input-list-get
      (& inputs)
      0
      (ast-extern-link-input-fallback))
      [(AstExternLinkInput.Lib lib) (string.eq lib "m")]
      [_ false])
    (match (ast-extern-link-input-list-get
      (& inputs)
      1
      (ast-extern-link-input-fallback))
      [(AstExternLinkInput.Search dir) (string.eq dir "native/lib")]
      [_ false])
    (match (ast-extern-link-input-list-get
      (& inputs)
      2
      (ast-extern-link-input-fallback))
      [(AstExternLinkInput.Arg arg-value)
        (string.eq arg-value "-Wl,--as-needed")]
      [_ false])))

(define (compiler-parse-extern-metadata-ok?) : bool
  (match (parse-ast-source (compiler-parse-extern-metadata-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.Extern name _ metadata ty) rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (intern "local-call"))
                    (string.eq
                      (ast-extern-metadata-symbol metadata)
                      "foreign_exact")
                    (ast-extern-abi-c? (ast-extern-metadata-abi metadata))
                    (compiler-parse-extern-link-inputs-ok?
                      (ast-extern-metadata-link-inputs metadata))
                    (match ty
                      [(AstType.Func args ret)
                        (let
                          [args-list : AstTypeList (box-get args)]
                          (and
                            (= (ast-type-list-len (& args-list)) 1)
                            (match (ty-node-get
                              (ast-type-list-get
                                (& args-list)
                                0
                                (ast-type-id-fallback)))
                              [(AstType.I64) true]
                              [_ false])
                            (match (ty-node-get ret)
                              [(AstType.I64) true]
                              [_ false])))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-extern-varargs-metadata-rejected-ok?) : bool
  (compiler-parse-error-ok?
    (compiler-parse-extern-varargs-metadata-source)
    (parse-ast-extern-c-varargs-legacy-message)))

(define (compiler-parse-extern-head-typed-varargs-decl-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Extern name _ metadata ty)
      (and
        (= name (intern "snprintf"))
        (match (ast-extern-metadata-abi metadata)
          [(AstExternAbi.CVarargsTyped tail-ty)
            (match tail-ty
              [(AstType.F64) true]
              [_ false])]
          [_ false])
        (match ty
          [(AstType.Func args ret)
            (let
              [args-list : AstTypeList (box-get args)]
              (and
                (= (compiler-parse-type-list-count args-list) 3)
                (match (ty-node-get ret)
                  [(AstType.I32) true]
                  [_ false])
                (compiler-parse-type-mut-ptr-u8?
                  (ty-node-get
                    (ast-type-list-get (& args-list) 0 (ast-type-id-fallback))))
                (match (ty-node-get
                  (ast-type-list-get (& args-list) 1 (ast-type-id-fallback)))
                  [(AstType.I64) true]
                  [_ false])
                (compiler-parse-type-ptr-u8?
                  (ty-node-get
                    (ast-type-list-get (& args-list) 2 (ast-type-id-fallback))))))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-extern-head-open-varargs-decl-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Extern name _ metadata ty)
      (and
        (= name (intern "printf"))
        (match (ast-extern-metadata-abi metadata)
          [(AstExternAbi.CVarargsOpen) true]
          [_ false])
        (match ty
          [(AstType.Func args ret)
            (let
              [args-list : AstTypeList (box-get args)]
              (and
                (= (compiler-parse-type-list-count args-list) 1)
                (match (ty-node-get ret)
                  [(AstType.I32) true]
                  [_ false])
                (compiler-parse-type-ptr-u8?
                  (ty-node-get
                    (ast-type-list-get (& args-list) 0 (ast-type-id-fallback))))))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-i64-type? [ty : AstType]) : bool
  (match ty
    [(AstType.I64) true]
    [_ false]))

(define (compiler-parse-two-i64-types? [args : AstTypeList]) : bool
  (and
    (= (ast-type-list-len (& args)) 2)
    (compiler-parse-i64-type?
      (ty-node-get (ast-type-list-get (& args) 0 (ast-type-id-fallback))))
    (compiler-parse-i64-type?
      (ty-node-get (ast-type-list-get (& args) 1 (ast-type-id-fallback))))))

(define (compiler-parse-extern-head-fixed-decl-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Extern name _ metadata ty)
      (and
        (= name (intern "local-add"))
        (string.eq (ast-extern-metadata-symbol metadata) "foreign_add_exact")
        (match ty
          [(AstType.Func args ret)
            (and
              (= (compiler-parse-type-list-count (box-get args)) 2)
              (compiler-parse-i64-type? (ty-node-get ret))
              (compiler-parse-two-i64-types? (box-get args)))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-extern-function-head-varargs-ok?) : bool
  (match (parse-ast-source (compiler-parse-extern-function-head-varargs-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (match (ast-decl-list-step (box-get decls-box))
        [(AstDeclListStep.Cons first rest0)
          (let
            [rest0 : AstDeclList rest0]
            (match (ast-decl-list-step rest0)
              [(AstDeclListStep.Cons second rest1)
                (let
                  [rest1 : AstDeclList rest1]
                  (match (ast-decl-list-step rest1)
                    [(AstDeclListStep.Cons third rest2)
                      (let
                        [rest2 : AstDeclList rest2]
                        (match (ast-decl-list-step rest2)
                          [(AstDeclListStep.Nil)
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-define-export-symbol-ok?) : bool
  (match (parse-ast-source (compiler-parse-define-export-symbol-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn name params ret _ export) rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (intern "_write"))
                    (= (compiler-parse-param-list-count params) 3)
                    (match ret
                      [(AstType.I32) true]
                      [_ false])
                    (match export
                      [(AstFnExport.Export symbol) (= symbol (intern "_write"))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-raw-pointer-ops-ok?) : bool
  (compiler-parse-ok? (compiler-parse-raw-pointer-ops-source)))

(define (compiler-parse-init-ok?) : bool
  (match (parse-ast-source "(define (main) : i64 (init : i64))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (match (ast-decl-list-step (box-get decls-box))
        [(AstDeclListStep.Cons (AstDecl.DefFn _ _ _ body-box _) done-box)
          (let
            [done : AstDeclList done-box]
            (and
              (ast-decl-list-empty? (& done))
              (match (ast-expr-unspan (ast-node-get body-box))
                [(AstExpr.Init ty)
                  (match ty
                    [(AstMaybeType.Some inner)
                      (match inner
                        [(AstType.I64) true]
                        [_ false])]
                    [_ false])]
                [_ false])))]
        [_ false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-contextual-init-ok?) : bool
  (match (parse-ast-source
    "(define (init) : i64 7) (define (main) : i64 (init))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (match (ast-decl-list-step (box-get decls-box))
        [(AstDeclListStep.Cons _ rest)
          (match (ast-decl-list-step rest)
            [(AstDeclListStep.Cons (AstDecl.DefFn _ _ _ body-box _) done-box)
              (let
                [done : AstDeclList done-box]
                (and
                  (ast-decl-list-empty? (& done))
                  (match (ast-expr-unspan (ast-node-get body-box))
                    [(AstExpr.Init ty)
                      (match ty
                        [(AstMaybeType.No) true]
                        [_ false])]
                    [_ false])))]
            [_ false])]
        [_ false])]
    [(ResultAstProgram.Err _) false]))

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
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn _ params _ _ _) rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= (ast-param-list-len (& params)) 3)
                    (match (ast-param-list-get
                      (& params)
                      0
                      (ast-param-fallback))
                      [(AstParam.Param _ first-ty false)
                        (compiler-parse-type-ref-string? first-ty "r")]
                      [_ false])
                    (match (ast-param-list-get
                      (& params)
                      1
                      (ast-param-fallback))
                      [(AstParam.Param _ second-ty false)
                        (compiler-parse-type-ref-str? second-ty "r")]
                      [_ false])
                    (match (ast-param-list-get
                      (& params)
                      2
                      (ast-param-fallback))
                      [(AstParam.Param _ third-ty false)
                        (compiler-parse-type-mut-ref-dyn-array-i64?
                          third-ty
                          "phase")]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-borrow-source) : String
  "(define (main [x : i64]) : i64
  (begin
    (& x)
    (& x x)
    (&mut x)
    x))")

(define (compiler-parse-borrow-inferred-var? [expr : AstExpr] [name : String]) : bool
  (match (ast-expr-unspan expr)
    [(AstExpr.Borrow false AstBorrowLifetime.Inferred place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (match (ast-expr-unspan place)
          [(AstExpr.Var place-name) (string.eq (intern-str place-name) name)]
          [_ false]))]
    [_ false]))

(define (compiler-parse-mut-borrow-inferred-var?
  [expr : AstExpr]
  [name : String]) : bool
  (match (ast-expr-unspan expr)
    [(AstExpr.Borrow true AstBorrowLifetime.Inferred place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (match (ast-expr-unspan place)
          [(AstExpr.Var place-name) (string.eq (intern-str place-name) name)]
          [_ false]))]
    [_ false]))

(define (compiler-parse-borrow-named-var?
  [expr : AstExpr]
  [lifetime : String]
  [name : String]) : bool
  (match (ast-expr-unspan expr)
    [(AstExpr.Borrow false (AstBorrowLifetime.Named actual-lifetime) place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (match (ast-expr-unspan place)
          [(AstExpr.Var place-name)
            (and
              (string.eq actual-lifetime lifetime)
              (string.eq (intern-str place-name) name))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-borrow-ok?) : bool
  (match (parse-ast-source (compiler-parse-borrow-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.Begin exprs)
                      (if (>= (struct-get (& exprs) len) 2)
                        (let
                          [first : AstExpr
                            (ast-node-get (ast-expr-list-get (& exprs) 0 0))]
                          [second : AstExpr
                            (ast-node-get (ast-expr-list-get (& exprs) 1 0))]
                          (match (ast-expr-unspan first)
                            [(AstExpr.Borrow
                                _
                                AstBorrowLifetime.Inferred
                                first-place-box)
                              (let
                                [first-place : AstExpr
                                  (ast-node-get first-place-box)]
                                (match (ast-expr-unspan first-place)
                                  [(AstExpr.Var first-name)
                                    (if (string.eq (intern-str first-name) "x")
                                      (match (ast-expr-unspan second)
                                        [(AstExpr.Borrow
                                            _
                                            (AstBorrowLifetime.Named lifetime)
                                            second-place-box)
                                          (let
                                            [second-place : AstExpr
                                              (ast-node-get second-place-box)]
                                            (match (ast-expr-unspan
                                              second-place)
                                              [(AstExpr.Var second-name)
                                                (and
                                                  (string.eq lifetime "x")
                                                  (string.eq
                                                    (intern-str second-name)
                                                    "x"))]
                                              [_ false]))]
                                        [_ false])
                                      false)]
                                  [_ false]))]
                            [_ false]))
                        false)]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-try-source) : String
  "(define (main) : i64 (wrap (try (read))))")

(define (compiler-parse-try-ok?) : bool
  (match (parse-ast-source (compiler-parse-try-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.Call _ args)
                      (if (= (struct-get (& args) len) 1)
                        (let
                          [arg : AstExpr
                            (ast-node-get (ast-expr-list-get (& args) 0 0))]
                          (match (ast-expr-unspan arg)
                            [(AstExpr.Try _) true]
                            [_ false]))
                        false)]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-return-source) : String
  "(define (main) : i64 (return 42))")

(define (compiler-parse-return-ok?) : bool
  (match (parse-ast-source (compiler-parse-return-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.Return inner-box)
                      (let
                        [inner : AstExpr (ast-node-get inner-box)]
                        (match (ast-expr-unspan inner)
                          [(AstExpr.Literal (AstLiteral.Int 42 _)) true]
                          [_ false]))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-unit-expr? [expr : AstExpr]) : bool
  (match (ast-expr-unspan expr)
    [(AstExpr.Literal AstLiteral.Unit) true]
    [_ false]))

(define (compiler-parse-return-then-unit-begin? [expr : AstExpr]) : bool
  (match (ast-expr-unspan expr)
    [(AstExpr.Begin exprs)
      (if (= (struct-get (& exprs) len) 2)
        (let
          [first : AstExpr (ast-node-get (ast-expr-list-get (& exprs) 0 0))]
          [last : AstExpr (ast-node-get (ast-expr-list-get (& exprs) 1 0))]
          (and
            (match (ast-expr-unspan first)
              [(AstExpr.Return _) true]
              [_ false])
            (compiler-parse-unit-expr? last)))
        false)]
    [_ false]))

(define (compiler-parse-call-head-name? [expr : AstExpr] [name : String]) : bool
  (match (ast-expr-unspan expr)
    [(AstExpr.Var found) (string.eq (intern-str found) name)]
    [_ false]))

(define (compiler-parse-return-expr? [expr : AstExpr]) : bool
  (match (ast-expr-unspan expr)
    [(AstExpr.Return _) true]
    [_ false]))

(define (compiler-parse-guard-call-args-ok? [args : AstExprList]) : bool
  (if (= (struct-get (& args) len) 2)
    (let
      [cond : AstExpr (ast-node-get (ast-expr-list-get (& args) 0 0))]
      [body-arg : AstExpr (ast-node-get (ast-expr-list-get (& args) 1 0))]
      (and
        (compiler-parse-call-head-name? cond "ok")
        (compiler-parse-return-expr? body-arg)))
    false))

(define (compiler-parse-call-arg-count [args : AstExprList]) : i64
  (struct-get (& args) len))

(define (compiler-parse-call-body-ok?
  [source : String]
  [name : String]
  [want-args : i64]
  [check-guard-args : bool]) : bool
  (match (parse-ast-source source)
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.Call func-box args)
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
    [(ResultAstProgram.Err _) false]))

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
(comptime-decl (:generated sample-family Box_String \"String\")
  (define box-size : i64 8))
(comptime-decl (:generated function-family make-box-string \"String\")
  (define (make-box [x : i64]) : i64 x))")

(define (compiler-parse-no-generated-meta-ok? [meta : AstGeneratedDeclMeta]) : bool
  (match meta
    [(AstGeneratedDeclMeta.No) true]
    [_ false]))

(define (compiler-parse-generated-meta-ok?
  [meta : AstGeneratedDeclMeta]
  [want-generator : String]
  [want-item : String]
  [want-arg-count : i64]) : bool
  (match meta
    [(AstGeneratedDeclMeta.Some generator-name item-name arg-keys _)
      (and
        (string.eq generator-name want-generator)
        (string.eq item-name want-item)
        (= (compiler-parse-expr-list-count arg-keys) want-arg-count))]
    [_ false]))

(define (compiler-parse-comptime-defstruct-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.ComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (and
          (compiler-parse-no-generated-meta-ok? meta)
          (match template
            [(AstDecl.DefStruct name _ _ fields)
              (and
                (= name (intern "Point"))
                (= (compiler-parse-field-count fields) 2))]
            [_ false])))]
    [_ false]))

(define (compiler-parse-comptime-defenum-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.ComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (and
          (compiler-parse-no-generated-meta-ok? meta)
          (match template
            [(AstDecl.DefEnum name _ _) (= name (intern "Maybe"))]
            [_ false])))]
    [_ false]))

(define (compiler-parse-comptime-define-value-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.ComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (and
          (compiler-parse-generated-meta-ok?
            meta
            "sample-family"
            "Box_String"
            1)
          (match template
            [(AstDecl.Def name _ value-box)
              (let
                [value : AstExpr (ast-node-get value-box)]
                (and
                  (= name (intern "box-size"))
                  (match (ast-expr-unspan value)
                    [(AstExpr.Literal (AstLiteral.Int actual _)) (= actual 8)]
                    [_ false])))]
            [_ false])))]
    [_ false]))

(define (compiler-parse-comptime-define-fn-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.ComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (and
          (compiler-parse-generated-meta-ok?
            meta
            "function-family"
            "make-box-string"
            1)
          (match template
            [(AstDecl.DefFn name _ (AstType.I64) _ _)
              (= name (intern "make-box"))]
            [_ false])))]
    [_ false]))

(define (compiler-parse-comptime-decl-ok?) : bool
  (match (parse-ast-source (compiler-parse-comptime-decl-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons first rest1-box)
            (let
              [rest1 : AstDeclList rest1-box]
              (match (ast-decl-list-step rest1)
                [(AstDeclListStep.Cons second rest2-box)
                  (let
                    [rest2 : AstDeclList rest2-box]
                    (match (ast-decl-list-step rest2)
                      [(AstDeclListStep.Cons third rest3-box)
                        (let
                          [rest3 : AstDeclList rest3-box]
                          (match (ast-decl-list-step rest3)
                            [(AstDeclListStep.Cons fourth rest4-box)
                              (let
                                [rest4 : AstDeclList rest4-box]
                                (match (ast-decl-list-step rest4)
                                  [(AstDeclListStep.Nil)
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-unsafe-decl-source) : String
  "(unsafe (define (danger [x : i64]) : i64 x))
(unsafe (extern (raw-call [arg0 : i64]) : i64))")

(define (compiler-parse-unsafe-decl-ok?) : bool
  (match (parse-ast-source (compiler-parse-unsafe-decl-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons first tail)
            (let
              [tail : AstDeclList tail]
              (match first
                [(AstDecl.Unsafe first-inner-box)
                  (let
                    [first-inner : AstDecl (box-get first-inner-box)]
                    (match first-inner
                      [(AstDecl.DefFn name _ (AstType.I64) _ _)
                        (match (ast-decl-list-step tail)
                          [(AstDeclListStep.Cons second done-box)
                            (let
                              [done : AstDeclList done-box]
                              (and
                                (ast-decl-list-empty? (& done))
                                (match second
                                  [(AstDecl.Unsafe second-inner-box)
                                    (let
                                      [second-inner : AstDecl
                                        (box-get second-inner-box)]
                                      (match second-inner
                                        [(AstDecl.Extern
                                            extern-name
                                            _
                                            _
                                            extern-ty)
                                          (and
                                            (= name (intern "danger"))
                                            (= extern-name (intern "raw-call"))
                                            (match extern-ty
                                              [(AstType.Func _ ret)
                                                (match (ty-node-get ret)
                                                  [(AstType.I64) true]
                                                  [_ false])]
                                              [_ false]))]
                                        [_ false]))]
                                  [_ false])))]
                          [_ false])]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-field-count [fields : AstFieldDefList]) : i64
  (struct-get (& fields) len))

(define (compiler-parse-field-cleanup-score [cleanup : AstFieldCleanup]) : i64
  (match cleanup
    [(AstFieldCleanup.No) 0]
    [(AstFieldCleanup.Fn _) 10]
    [(AstFieldCleanup.Owned) 100]))

(define (compiler-parse-field-cleanup-list-score [fields : AstFieldDefList]) : i64
  (compiler-parse-field-cleanup-list-score-at (& fields) 0))

(define (compiler-parse-field-cleanup-list-score-at
  [fields : (& fields AstFieldDefList)]
  [index : i64]) : i64
  (if (>= index (struct-get fields len))
    0
    (match (ast-field-def-list-get fields index (ast-field-def-fallback))
      [(AstFieldDef.Def _ _ cleanup)
        (+
          (compiler-parse-field-cleanup-score cleanup)
          (compiler-parse-field-cleanup-list-score-at fields (+ index 1)))])))

(define (compiler-parse-variant-payload-cleanup-score
  [cleanup : AstVariantPayloadCleanup]) : i64
  (match cleanup
    [(AstVariantPayloadCleanup.No) 0]
    [(AstVariantPayloadCleanup.Fn _) 10]
    [(AstVariantPayloadCleanup.Owned) 100]))

(define (compiler-parse-variant-payload-cleanup-list-score
  [cleanups : AstVariantPayloadCleanupList]) : i64
  (compiler-parse-variant-payload-cleanup-list-score-at (& cleanups) 0))

(define (compiler-parse-variant-payload-cleanup-list-score-at
  [cleanups : (& cleanups AstVariantPayloadCleanupList)]
  [index : i64]) : i64
  (if (>= index (struct-get cleanups len))
    0
    (+
      (compiler-parse-variant-payload-cleanup-score
        (ast-variant-payload-cleanup-list-get
          cleanups
          index
          (ast-variant-payload-cleanup-fallback)))
      (compiler-parse-variant-payload-cleanup-list-score-at
        cleanups
        (+ index 1)))))

(define (compiler-parse-variant-list-cleanup-score
  [variants : AstVariantDefList]) : i64
  (compiler-parse-variant-list-cleanup-score-at (& variants) 0))

(define (compiler-parse-variant-list-cleanup-score-at
  [variants : (& variants AstVariantDefList)]
  [index : i64]) : i64
  (if (>= index (struct-get variants len))
    0
    (match (ast-variant-def-list-get variants index (ast-variant-def-fallback))
      [(AstVariantDef.Def _ _ cleanups)
        (+
          (compiler-parse-variant-payload-cleanup-list-score cleanups)
          (compiler-parse-variant-list-cleanup-score-at variants (+ index 1)))])))

(define (compiler-parse-struct-cleanup-source) : String
  "(defstruct Resource
  (:cleanup close-resource)
  (fd i64 (:cleanup close-fd))
  (child i64 (:owned))
  (status i64))")

(define (compiler-parse-struct-cleanup-ok?) : bool
  (match (parse-ast-source (compiler-parse-struct-cleanup-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefStruct name repr cleanup fields)
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (intern "Resource"))
                    (match repr
                      [(AstStructRepr.Default) true]
                      [_ false])
                    (match cleanup
                      [(AstStructCleanup.Fn cleanup-name)
                        (= cleanup-name (intern "close-resource"))]
                      [_ false])
                    (= (compiler-parse-field-count fields) 3)
                    (= (compiler-parse-field-cleanup-list-score fields) 110))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-enum-cleanup-source) : String
  "(defenum Resource
  (:cleanup close-resource)
  (File i64 (:cleanup close-fd) Child (:owned) i64))")

(define (compiler-parse-enum-cleanup-ok?) : bool
  (match (parse-ast-source (compiler-parse-enum-cleanup-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefEnum name cleanup variants) rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (intern "Resource"))
                    (match cleanup
                      [(AstEnumCleanup.Fn cleanup-name)
                        (= cleanup-name (intern "close-resource"))]
                      [_ false])
                    (= (compiler-parse-variant-list-cleanup-score variants) 110))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-comptime-struct-cleanup-source) : String
  "(comptime-decl
  (defstruct Resource
    (:cleanup close-resource)
    (fd i64 (:cleanup close-fd))))")

(define (compiler-parse-comptime-struct-cleanup-ok?) : bool
  (match (parse-ast-source (compiler-parse-comptime-struct-cleanup-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.ComptimeDecl _ template-box) rest)
            (let
              [template : AstDecl (box-get template-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match template
                    [(AstDecl.DefStruct _ repr cleanup fields)
                      (and
                        (match repr
                          [(AstStructRepr.Default) true]
                          [_ false])
                        (ast-struct-cleanup? cleanup)
                        (= (compiler-parse-field-cleanup-list-score fields) 10))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

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
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefStruct name repr _ fields) rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (intern "Stat"))
                    (ast-struct-repr-c? repr)
                    (= (compiler-parse-field-count fields) 2))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-comptime-repr-c-source) : String
  "(comptime-decl (defstruct Stat (:repr c) (size i64)))")

(define (compiler-parse-comptime-repr-c-ok?) : bool
  (match (parse-ast-source (compiler-parse-comptime-repr-c-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.ComptimeDecl _ template-box) rest)
            (let
              [template : AstDecl (box-get template-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match template
                    [(AstDecl.DefStruct _ repr _ fields)
                      (and
                        (ast-struct-repr-c? repr)
                        (= (compiler-parse-field-count fields) 1))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-inline-test-source) : String
  "(test parser-basic
  (+ 1 2)
  3)")

(define (compiler-parse-inline-test-ok?) : bool
  (match (parse-ast-source (compiler-parse-inline-test-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.Test name body-box span) tail)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [tail : AstDeclList tail]
              (match (ast-decl-list-step tail)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (intern "parser-basic"))
                    (= (ast-source-span-start-line span) 1)
                    (match (ast-expr-unspan body)
                      [(AstExpr.Begin exprs)
                        (= (compiler-parse-expr-list-count exprs) 2)]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-comptime-decl-bad-payload-source) : String
  "(comptime-decl (extern (x) : i64))")

(define (compiler-parse-comptime-decl-expression-source) : String
  "(define (main) : i64 (comptime-decl (defstruct Point (x i64))))")

(define (compiler-parse-comptime-decl-extra-source) : String
  "(comptime-decl
  (:generated sample-family Box_String)
  (defstruct Point (x i64))
  (defenum Maybe (None)))")

(define (compiler-parse-comptime-decl-bad-metadata-source) : String
  "(comptime-decl (:bad sample-family Box_String) (defstruct Point (x i64)))")

(define (compiler-parse-comptime-decl-malformed-metadata-source) : String
  "(comptime-decl (:generated sample-family) (defstruct Point (x i64)))")

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
      "(comptime-decl (cfg feature (define x : i64 1)))")
    (compiler-parse-comptime-decl-invalid-payload-ok?
      "(comptime-decl (test t 1))")
    (compiler-parse-comptime-decl-invalid-payload-ok?
      "(comptime-decl (comptime-decl (defstruct X (x i64))))")))

(define (compiler-parse-malformed-module-source) : String
  "(module)")

(define (compiler-parse-malformed-import-source) : String
  "(import \"stdlib/tl\" as)")

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
      (parse-ast-comptime-decls-removed-message))
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decls-empty-source)
      (parse-ast-comptime-decls-removed-message))
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decls-bad-metadata-source)
      (parse-ast-comptime-decls-removed-message))
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decls-malformed-metadata-source)
      (parse-ast-comptime-decls-removed-message))
    (compiler-parse-error-ok?
      (compiler-parse-comptime-decls-bad-payload-source)
      (parse-ast-comptime-decls-removed-message))))

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
    [(ResultAstProgram.Ok _) true]
    [(ResultAstProgram.Err _) false]))

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
      "(define (main) : i64 (let []))"
      "parse: let missing body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let ()))"
      "parse: let missing body")))

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
      "parse: ptr-addr-of expects exactly one addressable place")
    (compiler-parse-error-ok?
      "(define (main [x : i64] [y : i64]) : (MutPtr i64) (unsafe (ptr-addr-of x y)))"
      "parse: ptr-addr-of expects exactly one addressable place")
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
        "parse: & expects an optional lifetime and exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-ok? "(define (main [p : (& r)]) : unit unit)")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [p : (& 1 i64)]) : unit unit)"
        "parse: reference lifetime must be an identifier")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [p : (& r i64 i64)]) : unit unit)"
        "parse: & expects an optional lifetime and exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-ok? "(define (main [p : (&mut phase)]) : unit unit)")
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
      "parse: if is missing its else branch")
    (compiler-parse-if-missing-else-diagnostic-notes-ok?)
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
    [(not (compiler-parse-nested-diagnostic-spans-ok?)) false]
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

;; Top-level declaration parsing: accept value/function `define`,
;; `extern`, `defenum`, `defstruct`, and `import`; reject malformed forms with
;; stable diagnostics. Migrated from src/parser.rs declaration coverage.
(define (compiler-parse-ok? [src : String]) : bool
  (match (parse-ast-source src)
    [(ResultAstProgram.Ok _) true]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-ok-with-cfg?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (match (parse-ast-source-with-cfg src cfgs)
    [(ResultAstProgram.Ok _) true]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-cfg-decl-count-ok?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [want : i64]) : bool
  (match (parse-ast-source-with-cfg src cfgs)
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (= (ast-decl-list-count decls) want))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-cfg-error?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (match (parse-ast-source-with-cfg src cfgs)
    [(ResultAstProgram.Ok _) false]
    [(ResultAstProgram.Err _) true]))

(define (compiler-parse-cfg-tests-ok?) : bool
  (let
    [feature-cfg : sym_i64_env.SymI64Env
      (compiler-cfg-enable (compiler-cfg-empty) "feature")]
    [windows-feature-cfg : sym_i64_env.SymI64Env
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
    (compiler-parse-ok? "(import \"stdlib/tl\")")
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

;; enum/struct expression coverage: defenum empty rejection,
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
;; let-binding parsing: accept untyped, multi-binding, legacy
;; parenthesized binding forms, and empty-binding body wrappers. Completes the
;; let family alongside the existing flat-let accept and let error tests.
(define (compiler-parse-let-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (let [x 1] x))")
    (compiler-parse-ok?
      "(define (main) : i64 (let [x : i64 1] [y : i64 2] (+ x y)))")
    (compiler-parse-ok? "(define (main) : i64 (let ([x : i64 1]) x))")
    (compiler-parse-ok? "(define (main) : i64 (let [] 0))")
    (compiler-parse-ok? "(define (main) : i64 (let () 0))")))

(define (compiler-parse-implicit-body-tail-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (let [x : i64 1] x (+ x 1)))")
    (compiler-parse-ok? "(define (main) : i64 (let ([x : i64 1]) x (+ x 1)))")
    (compiler-parse-ok? "(define (main) : i64 (let [] 1 2))")
    (compiler-parse-ok? "(define (main) : i64 (let () 1 2))")
    (compiler-parse-ok?
      "(define (main) : i64 (begin (while false unit unit) 0))")
    (compiler-parse-ok? "(define (main) : i64 unit 42)")
    (compiler-parse-ok? "(define (main) : i64 ((lambda () : i64 unit 42)))")))

(define (compiler-parse-spmd-tests-ok?) : bool
  (and
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : i64 0 3]) unit) 0))")
    (compiler-parse-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))")
    (compiler-parse-ok?
      "(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (array-set! out i (spmd-broadcast (array-ref xs i) 0))) 0))")
    (compiler-parse-ok?
      "(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (array-set! out i (spmd-shuffle (array-ref xs i) i))) 0))")
    (compiler-parse-ok?
      "(define (main [out : (Array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (array-set! out i (+ (program-index) (program-count)))) 0))")
    ;; An empty range, a non-i64 index type, and expression
    ;; start/end bounds all parse (range semantics are checked later).
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : i64 5 5]) unit) 0))")
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : u32 0 3]) unit) 0))")
    (compiler-parse-ok?
      "(define (main [n : i64]) : i64 (begin (foreach ([i : i64 (+ 0 1) (* n 2)]) unit) 0))")
    ;; An unknown reduce operator is rejected by the parser.
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
      "parse: malformed spmd-broadcast")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-shuffle 1))"
      "parse: malformed spmd-shuffle")
    (compiler-parse-error-ok?
      "(define (main) : i64 (program-index 0))"
      "parse: program-index expects no arguments")
    (compiler-parse-error-ok?
      "(define (main) : i64 (program-count 0))"
      "parse: program-count expects no arguments")))

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

;; pattern literals: string literal arms, nested string payload,
;; char literals in pattern and value position.
(define (compiler-parse-pattern-string-char-tests-ok?) : bool
  (and
    ;; string literal arms
    (compiler-parse-ok?
      "(define (f [s : String]) : i64 (match s [\"if\" 10] [\"let\" 20] [_ 0]))")
    ;; nested string payload
    (compiler-parse-ok?
      "(defenum Token (TIdent String))\n(define (f [t : Token]) : i64 (match t [(TIdent \"if\") 1] [_ 0]))")
    ;; char literal in pattern (space + literal char)
    (compiler-parse-ok?
      "(define (f [c : char]) : i64 (match c [' ' 1] ['a' 2] [_ 0]))")
    ;; escaped char literal in value position
    (compiler-parse-ok? "(define (f) : char '\\n')")))

;
;; operator parsing: accept unary (not/neg/bit-not), binary
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
      "(define (main [a : i64] [b : i64] [c : i64] [d : i64]) : i64 (begin (+ a b c d) (* a b c d)))")
    (compiler-parse-ok?
      "(define (main [a : i64] [b : i64] [p : bool]) : i64 (begin (bit-and a b) (bit-or a b) (bit-xor a b) (shl a b) (shr a b) (if (not p) 1 0)))")
    (compiler-parse-ok?
      "(define (main [a : i64] [b : i64] [c : i64] [d : i64]) : i64 (begin (bit-and a b c d) (bit-or a b c d) (bit-xor a b c d)))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (not))"
      "parse: malformed unary expression")
    (compiler-parse-error-ok?
      "(define (main [a : i64]) : i64 (+ a))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main) : i64 (+))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main [a : i64]) : i64 (* a))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main) : i64 (*))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main [a : i64]) : i64 (bit-and a))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main) : i64 (bit-or))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main [a : i64] [b : i64] [c : i64]) : i64 (shl a b c))"
      "parse: malformed binary expression")))

(define (compiler-parse-type-literal-tests-ok?) : bool
  (let
    [private-cfg : sym_i64_env.SymI64Env
      (compiler-cfg-enable
        (compiler-cfg-empty)
        "feature-compiler-private-dynamic-buffer")]
    (and
      (compiler-parse-ok? "(define (main) : i64 (begin (type i64) 0))")
      (compiler-parse-ok? "(define (main) : i64 (begin (type (Array i64)) 0))")
      (compiler-parse-error-ok?
        "(define (main) : i64 (begin (type (__tl_dyn-array i64)) 0))"
        "parse: unknown type constructor __tl_dyn-array; TypeLisp has no source-level generic type constructors; use comptime-decl and comptime-generated concrete declarations instead")
      (compiler-parse-ok-with-cfg?
        "(define (main) : i64 (begin (type (__tl_dyn-array i64)) 0))"
        private-cfg)
      (compiler-parse-ok? "(define (main) : i64 (begin (type (-> i64 i64)) 0))")
      (compiler-parse-error-ok-with-cfg?
        "(define (main) : i64 (begin (type (__tl_dyn-array i64 4)) 0))"
        private-cfg
        "parse: __tl_dyn-array expects exactly one type")
      (compiler-parse-error-ok?
        "(define (main) : i64 (type))"
        "parse: type expects exactly one type")
      (compiler-parse-error-ok?
        "(define (main) : i64 (type i64 bool))"
        "parse: type expects exactly one type"))))

;; region parsing: `(with-arena <ident> body+)` accepts (basic,
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
    "(define (main) : String (with-escape (arena-make) (string.int->string 42)))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.WithEscape scratch-box body-exprs)
                      (let
                        [scratch : AstExpr (ast-node-get scratch-box)]
                        (match (ast-expr-unspan scratch)
                          [(AstExpr.Call callee-box call-args)
                            (let
                              [callee : AstExpr (ast-node-get callee-box)]
                              (match (ast-expr-unspan callee)
                                [(AstExpr.Var name)
                                  (and
                                    (= (struct-get (& call-args) len) 0)
                                    (string.eq (intern-str name) "arena-make")
                                    (= (struct-get (& body-exprs) len) 1))]
                                [_ false]))]
                          [_ false]))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-with-escape-tests-ok?) : bool
  (and
    (compiler-parse-with-escape-shape-ok?)
    (compiler-parse-ok?
      "(define (main) : i64 (let ([scratch : Arena (arena-make)]) (with-escape scratch 1 2 3)))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-escape))"
      "parse: with-escape requires a scratch arena before its body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-escape (arena-make)))"
      "parse: with-escape requires a non-empty body")))

(define (compiler-parse-with-scratch-shape-ok?) : bool
  (match (parse-ast-source
    "(define (main) : String (with-scratch (string.int->string 41) (string.int->string 42)))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.WithScratch body-exprs)
                      (= (struct-get (& body-exprs) len) 2)]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-with-scratch-tests-ok?) : bool
  (and
    (compiler-parse-with-scratch-shape-ok?)
    (compiler-parse-ok? "(define (main) : i64 (with-scratch 1 2 3))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-scratch))"
      "parse: with-scratch requires a non-empty body")))

(define (compiler-parse-in-arena-shape-ok?) : bool
  (match (parse-ast-source
    "(define (main [arena : Arena]) : i64 (in-arena arena 1 2))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.InArena arena-box body-exprs)
                      (let
                        [arena : AstExpr (ast-node-get arena-box)]
                        (match (ast-expr-unspan arena)
                          [(AstExpr.Var name)
                            (and
                              (string.eq (intern-str name) "arena")
                              (= (struct-get (& body-exprs) len) 2))]
                          [_ false]))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-in-arena-tests-ok?) : bool
  (and
    (compiler-parse-in-arena-shape-ok?)
    (compiler-parse-ok?
      "(define (main) : i64 (let ([arena : Arena (arena-current)]) (in-arena arena 1 2 3)))")
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
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn _ _ _ body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.WithResource wr-box)
                      (match (box-get wr-box)
                        [(AstWithResource.WithResource bindings body-exprs)
                          (if (and
                            (=
                              (compiler-parse-resource-binding-count bindings)
                              2)
                            (= (compiler-parse-expr-list-count body-exprs) 2))
                            (let
                              [nested : AstExpr
                                (ast-node-get
                                  (ast-expr-list-get (& body-exprs) 1 0))]
                              (match (ast-expr-unspan nested)
                                [(AstExpr.WithResource nested-wr-box)
                                  (match (box-get nested-wr-box)
                                    [(AstWithResource.WithResource
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
                                [_ false]))
                            false)])]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

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
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn _ _ ret-ty body-box _) rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (match ret-ty
                      [(AstType.Var name) (string.eq (intern-str name) "Expr")]
                      [_ false])
                    (match (ast-expr-unspan body)
                      [(AstExpr.Quasiquote template-box)
                        (let
                          [template : AstExpr (ast-node-get template-box)]
                          (match (ast-expr-unspan template)
                            [(AstExpr.If cond-box _ _)
                              (let
                                [cond : AstExpr (ast-node-get cond-box)]
                                (match (ast-expr-unspan cond)
                                  [(AstExpr.Unquote unquoted-box)
                                    (let
                                      [unquoted : AstExpr
                                        (ast-node-get unquoted-box)]
                                      (match (ast-expr-unspan unquoted)
                                        [(AstExpr.Var name)
                                          (string.eq (intern-str name) "e")]
                                        [_ false]))]
                                  [_ false]))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-quote-syntax-tests-ok?) : bool
  (and
    (compiler-parse-quote-syntax-shape-ok?)
    (compiler-parse-ok? "(define x : Expr '(+ 1 2))")
    (compiler-parse-ok? "(define x : Expr `(begin ,@xs))")
    (compiler-parse-ok?
      "(define (mk [target : Expr]) : Expr `(set! ,target 1))")
    (compiler-parse-error-ok?
      "(define x : Expr (quote))"
      "parse: quote form expects exactly one expression")))

;; REPL-item parsing: `parse-ast-repl-source` accepts a single
;; top-level declaration, a parenthesized expression, or a bare expression, and
;; rejects trailing tokens and a malformed expression. Mirrors the Rust
;; parser's `parse_repl_item` tests.
(define (compiler-parse-repl-decl-ok? [src : String]) : bool
  (match (parse-ast-repl-source src)
    [(ResultAstReplItem.Ok item)
      (match item
        [(AstReplDecl _) true]
        [(AstReplExpr _) false])]
    [(ResultAstReplItem.Err _) false]))

(define (compiler-parse-repl-expr-ok? [src : String]) : bool
  (match (parse-ast-repl-source src)
    [(ResultAstReplItem.Ok item)
      (match item
        [(AstReplExpr _) true]
        [(AstReplDecl _) false])]
    [(ResultAstReplItem.Err _) false]))

(define (compiler-parse-repl-error-ok? [src : String] [expected : String]) : bool
  (match (parse-ast-repl-source src)
    [(ResultAstReplItem.Ok _) false]
    [(ResultAstReplItem.Err message) (string.eq message expected)]))

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

;; comptime function-parameter parsing: `[comptime n : i64]`
;; and the type-valued `[comptime T : type]` parse as top-level function
;; parameters marked comptime; a comptime parameter on a lambda is rejected
;; (comptime params are top-level-only). Mirrors the Rust parser's
;; test_parse_comptime_function_param / _type_valued_comptime_param /
;; _comptime_lambda_param_rejected.
(define (compiler-parse-first-fn-has-comptime-param? [src : String]) : bool
  (match (parse-ast-source src)
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn _ params _ _ _) _)
            (ast-param-list-has-comptime? params)]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

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
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefMacro name params (AstType.Bool) _)
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (intern "all"))
                    (= (ast-macro-param-list-len (& params)) 2)
                    (match (ast-macro-param-list-get
                      (& params)
                      0
                      (ast-macro-param-fallback))
                      [(AstMacroParam.Param first (AstType.Bool) false)
                        (= first (intern "first"))]
                      [_ false])
                    (match (ast-macro-param-list-get
                      (& params)
                      1
                      (ast-macro-param-fallback))
                      [(AstMacroParam.Param rest (AstType.Bool) true)
                        (= rest (intern "rest"))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-defmacro-tests-ok?) : bool
  (and
    (compiler-parse-defmacro-shape-ok?)
    (compiler-parse-ok?
      "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool (expr-if lhs rhs (expr-bool false)))")
    (compiler-parse-error-ok?
      "(defmacro (bad [rest : bool ...] [x : bool]) : bool rest)"
      "parse: variadic macro operand must be final")))

(define (compiler-parse-dispatch-index-env-matches?
  [dispatch : sym_i64_env.SymI64Env]) : bool
  (let
    [ok : bool (compiler-parse-dispatch-indexed? dispatch)]
    [cursor : sym_i64_env.SymI64Env dispatch]
    [done : bool false]
    (begin
      (while (and ok (not done))
        (match cursor
          [(sym_i64_env.SymI64Nil) (set! done true)]
          [(sym_i64_env.SymI64Bind name-id tag rest)
            (if (= (compiler-parse-dispatch-index-lookup-id name-id) tag)
              (set! cursor (box-get rest))
              (set! ok false))]))
      (and ok done))))

(define (compiler-parse-dispatch-index-ok?) : bool
  (let
    [full : sym_i64_env.SymI64Env (compiler-parse-dispatch-env)]
    [partial : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-binops (sym_i64_env.sym-i64-empty))]
    [cfgs : sym_i64_env.SymI64Env
      (compiler-cfg-enable (compiler-cfg-empty) "dispatch-index-test")]
    [configured : sym_i64_env.SymI64Env
      (parse-ast-program-dispatch-with-cfg cfgs)]
    [private : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-private-types full)]
    (and
      (compiler-parse-dispatch-index-env-matches? full)
      (= (compiler-parse-dispatch-tag full "if") (compiler-parse-tag-expr-if))
      (=
        (compiler-parse-dispatch-tag full "not-parser-syntax")
        (compiler-parse-tag-unknown))
      (not (compiler-parse-dispatch-indexed? partial))
      (= (compiler-parse-dispatch-tag partial "+") (compiler-parse-tag-bin-add))
      (=
        (compiler-parse-dispatch-tag partial "if")
        (compiler-parse-tag-unknown))
      (compiler-parse-dispatch-indexed? configured)
      (compiler-cfg-enabled? configured "dispatch-index-test")
      (compiler-parse-dispatch-indexed? private)
      (compiler-cfg-private-dynamic-buffer-enabled? private))))

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
    (compiler-parse-dispatch-index-ok?)
    (compiler-parse-comptime-decl-ok?)
    (compiler-parse-unsafe-decl-ok?)
    (compiler-parse-module-decl-ok?)
    (compiler-parse-import-metadata-ok?)
    (compiler-parse-dotted-import-metadata-ok?)
    (compiler-parse-module-macro-surface-ok?)
    (compiler-parse-defdispatch-tests-ok?)
    (compiler-parse-flat-let-call-body-ok?)
    (compiler-parse-implicit-body-tail-ok?)
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
    (compiler-parse-define-export-metadata-error-tests-ok?)
    (compiler-parse-dotted-import-errors-ok?)))

(define (compiler-parse-smoke-shapes [program : AstProgram]) : unit
  (begin
    (if (compiler-parse-shape-tests-front-ok? program)
      unit
      (io.panic "parse: compiler AST front shape tests failed"))
    (if (compiler-parse-shape-tests-middle-ok?)
      unit
      (io.panic "parse: compiler AST middle shape tests failed"))
    (if (compiler-parse-repr-c-ok?)
      unit
      (io.panic "parse: repr c shape test failed"))
    (if (compiler-parse-cleanup-metadata-ok?)
      unit
      (io.panic "parse: cleanup metadata shape test failed"))
    (if (compiler-parse-raw-pointer-ok?)
      unit
      (io.panic "parse: raw pointer shape test failed"))
    (if (compiler-parse-extern-metadata-ok?)
      unit
      (io.panic "parse: extern metadata shape test failed"))
    (if (compiler-parse-extern-varargs-metadata-rejected-ok?)
      unit
      (io.panic "parse: extern c-varargs metadata retirement test failed"))
    (if (compiler-parse-extern-function-head-varargs-ok?)
      unit
      (io.panic "parse: extern function-head varargs shape test failed"))
    (if (compiler-parse-define-export-symbol-ok?)
      unit
      (io.panic "parse: define export-symbol shape test failed"))
    (if (compiler-parse-raw-pointer-ops-ok?)
      unit
      (io.panic "parse: raw pointer ops shape test failed"))
    (if (compiler-parse-init-ok?)
      unit
      (io.panic "parse: init shape test failed"))
    (if (compiler-parse-contextual-init-ok?)
      unit
      (io.panic "parse: contextual init shape test failed"))
    (if (compiler-parse-init-call-name-ok?)
      unit
      (io.panic "parse: init call name compatibility test failed"))
    (if (compiler-parse-box-ok?)
      unit
      (io.panic "parse: box shape test failed"))
    (if (compiler-parse-reference-ok?)
      unit
      (io.panic "parse: reference shape test failed"))
    (if (compiler-parse-borrow-ok?)
      unit
      (io.panic "parse: borrow shape test failed"))
    (if (compiler-parse-resource-with-shape-ok?)
      unit
      (io.panic "parse: resource with shape test failed"))
    (if (compiler-parse-with-escape-shape-ok?)
      unit
      (io.panic "parse: with-escape shape test failed"))
    (if (compiler-parse-with-scratch-shape-ok?)
      unit
      (io.panic "parse: with-scratch shape test failed"))
    (if (compiler-parse-in-arena-shape-ok?)
      unit
      (io.panic "parse: in-arena shape test failed"))
    (if (compiler-parse-quote-syntax-shape-ok?)
      unit
      (io.panic "parse: quote syntax shape test failed"))
    unit))

(define (compiler-parse-smoke-errors) : unit
  (begin
    (if (compiler-parse-error-suite-front-ok?)
      unit
      (io.panic "parse: front error-path self-tests failed"))
    (if (compiler-parse-error-suite-middle-ok?)
      unit
      (io.panic "parse: middle error-path self-tests failed"))
    (if (compiler-parse-error-suite-back-ok?)
      unit
      (io.panic "parse: back error-path self-tests failed"))
    unit))

(define (compiler-parse-smoke) : i64
  (match (parse-ast-source (compiler-parse-smoke-source))
    [(ResultAstProgram.Ok program)
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
        (compiler-parse-module-body-ok?)
        (compiler-parse-module-body-malformed-ok?)
        (compiler-parse-import-metadata-ok?)
        (compiler-parse-dotted-import-metadata-ok?)
        (compiler-parse-module-macro-surface-ok?)
        (compiler-parse-defdispatch-tests-ok?)
        (compiler-parse-flat-let-call-body-ok?)
        (compiler-parse-implicit-body-tail-ok?)
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
          (compiler-parse-dotted-import-errors-ok?)
          (compiler-parse-cfg-tests-ok?))
          42
          (io.panic "parse: error-path self-tests failed"))
        (io.panic "parse: compiler AST smoke score mismatch"))]
    [(ResultAstProgram.Err message) (io.panic message)]))