;; compiler_ctfe.tl - Selfhost compile-time function evaluation (CTFE) for
;; expression-position `(comptime expr)` (#719, scalar subset).
;;
;; Ports the scalar slice of the Rust reference `src/ctfe.rs`. Supported
;; compile-time value types are i64, f64/f32, bool, char, unit, type values, and
;; Expr / list aggregates (#1137).
;;
;; Evaluation is purely functional: the environment is an immutable cons list
;; threaded through recursion, and the step budget ("fuel") is threaded through
;; results so the evaluator stays deterministic without a mutable counter.
(import "../stdlib/core_macros.tl" module stdlib.core_macros as core)

(import "../stdlib/io.tl")

(import "../stdlib/hashmap.tl")

(import "compiler_ast_types.tl")

(import "compiler_diagnostic.tl")

(import "compiler_float.tl")

(import "../stdlib/string.tl")

;; A compile-time value. Scalar subset from #719; Expr / ExprList aggregates
;; from #1137 for macro transformers.
(defenum CompilerCtfeValue
  (CtfeI64 i64)
  (CtfeF64 f64)
  (CtfeF32 f64)
  (CtfeBool bool)
  (CtfeChar char)
  (CtfeString String)
  (CtfeUnit)
  (CtfeType AstType)
  ;; A user-facing `Expr` code fragment plus its internally checked produced
  ;; type. The type is not part of the source-level Expr type (#1135).
  (CtfeExpr i64 AstType)
  (CtfeExprList AstExprList)
  (CtfeExprClause AstExprClause)
  (CtfeExprClauseList AstExprClauseList))

;; CTFE-owned type layout metadata. The typechecker/lowerer build this from
;; their `TcContext` without making CTFE import typecheck.
(defenum CtfeLayoutField
  (CtfeLayoutField String i64))

(defenum CtfeLayoutFieldList
  (CtfeLayoutFieldNil)
  (CtfeLayoutFieldCons CtfeLayoutField (Box CtfeLayoutFieldList)))

(defenum CtfeLayoutInfo
  (CtfeLayoutInfo String bool i64 i64 CtfeLayoutFieldList))

(defenum CtfeLayoutInfoList
  (CtfeLayoutInfoNil)
  (CtfeLayoutInfoCons CtfeLayoutInfo (Box CtfeLayoutInfoList)))

(defenum CtfeMaybeLayoutInfo
  (CtfeNoLayoutInfo)
  (CtfeSomeLayoutInfo CtfeLayoutInfo))

(defenum CtfeMaybeFieldName
  (CtfeNoFieldName)
  (CtfeSomeFieldName String))

;; CTFE-owned type reflection metadata. Typecheck and specialization build this
;; from `AstProgram` and pass it into CTFE without making CTFE import either pass.
(defenum CtfeReflectField
  (CtfeReflectField String AstType))

(defenum CtfeReflectFieldList
  (CtfeReflectFieldNil)
  (CtfeReflectFieldCons CtfeReflectField (Box CtfeReflectFieldList)))

(defenum CtfeReflectVariant
  (CtfeReflectVariant String AstTypeList))

(defenum CtfeReflectVariantList
  (CtfeReflectVariantNil)
  (CtfeReflectVariantCons CtfeReflectVariant (Box CtfeReflectVariantList)))

(defenum CtfeReflectInfo
  (CtfeReflectStruct String String String CtfeReflectFieldList)
  (CtfeReflectEnum String String String CtfeReflectVariantList))

(defenum CtfeReflectInfoList
  (CtfeReflectInfoNil)
  (CtfeReflectInfoCons CtfeReflectInfo (Box CtfeReflectInfoList)))

(defenum CtfeMaybeReflectInfo
  (CtfeNoReflectInfo)
  (CtfeSomeReflectInfo CtfeReflectInfo))

;; Immutable name -> value environment plus immutable type metadata tables. Newest
;; value binding sits at the front so lookup finds the most recent shadowing
;; binding first; metadata lives at the root and is shared by extensions.
(defenum CtfeEnv
  (CtfeEnvNil CtfeLayoutInfoList CtfeReflectInfoList)
  (CtfeEnvCons String CompilerCtfeValue (Box CtfeEnv)))

(define (ctfe-env-empty) : CtfeEnv
  (CtfeEnvNil CtfeLayoutInfoNil CtfeReflectInfoNil))

(define (ctfe-env-with-layouts [layouts : CtfeLayoutInfoList]) : CtfeEnv
  (CtfeEnvNil layouts CtfeReflectInfoNil))

(define (ctfe-env-with-reflections [reflections : CtfeReflectInfoList]) : CtfeEnv
  (CtfeEnvNil CtfeLayoutInfoNil reflections))

(define (ctfe-env-with-metadata
  [layouts : CtfeLayoutInfoList]
  [reflections : CtfeReflectInfoList]) : CtfeEnv
  (CtfeEnvNil layouts reflections))

(define (ctfe-env-extend
  [env : CtfeEnv]
  [name : String]
  [value : CompilerCtfeValue]) : CtfeEnv
  (CtfeEnvCons name value (box env)))

(define (ctfe-layout-info-name [info : CtfeLayoutInfo]) : String
  (match info
    [(CtfeLayoutInfo name _ _ _ _) name]))

(define (ctfe-layout-info-list-contains
  [layouts : CtfeLayoutInfoList]
  [name : String]) : bool
  (match layouts
    [(CtfeLayoutInfoNil) false]
    [(CtfeLayoutInfoCons info rest)
      (if (string-eq (ctfe-layout-info-name info) name)
        true
        (ctfe-layout-info-list-contains (box-get rest) name))]))

;; Per-build dedup set of keys already added to the metadata list. The reflection
;; and layout builds each register every type under its key (and module alias);
;; checking membership against the linked list was O(types^2). This hashset makes
;; each `add-if-missing` O(1), so the whole build is O(types). Reset at the start
;; of each build (layouts then reflections run sequentially in tc-ctfe-env).
(define ctfe-build-seen-keys : StringI64Map
  (string-i64-map-with-capacity 1))

(define (ctfe-build-seen-reset!) : unit
  (set! ctfe-build-seen-keys (string-i64-map-with-capacity 256)))

(define (ctfe-build-seen-add? [key : String]) : bool
  (if (string-i64-map-contains? ctfe-build-seen-keys key)
    false
    (begin
      (set!
        ctfe-build-seen-keys
        (string-i64-map-put ctfe-build-seen-keys key 1))
      true)))

(define (ctfe-layout-info-list-add-if-missing
  [layouts : CtfeLayoutInfoList]
  [info : CtfeLayoutInfo]) : CtfeLayoutInfoList
  (if (ctfe-build-seen-add? (ctfe-layout-info-name info))
    (CtfeLayoutInfoCons info (box layouts))
    layouts))

(define (ctfe-layout-info-lookup [layouts : CtfeLayoutInfoList] [name : String]) : CtfeMaybeLayoutInfo
  (match layouts
    [(CtfeLayoutInfoNil) (CtfeNoLayoutInfo)]
    [(CtfeLayoutInfoCons info rest)
      (if (string-eq (ctfe-layout-info-name info) name)
        (CtfeSomeLayoutInfo info)
        (ctfe-layout-info-lookup (box-get rest) name))]))

(define (ctfe-layout-field-offset
  [fields : CtfeLayoutFieldList]
  [name : String]) : i64
  (match fields
    [(CtfeLayoutFieldNil) -1]
    [(CtfeLayoutFieldCons field rest)
      (match field
        [(CtfeLayoutField field-name offset)
          (if (string-eq field-name name)
            offset
            (ctfe-layout-field-offset (box-get rest) name))])]))

(define (ctfe-env-layouts [env : CtfeEnv]) : CtfeLayoutInfoList
  (match env
    [(CtfeEnvNil layouts _) layouts]
    [(CtfeEnvCons _ _ rest) (ctfe-env-layouts (box-get rest))]))

(define (ctfe-env-reflections [env : CtfeEnv]) : CtfeReflectInfoList
  (match env
    [(CtfeEnvNil _ reflections) reflections]
    [(CtfeEnvCons _ _ rest) (ctfe-env-reflections (box-get rest))]))

;; Lookup result for an environment probe.
(defenum CtfeMaybeValue
  (CtfeNoValue)
  (CtfeSomeValue CompilerCtfeValue))

(define (ctfe-env-lookup [env : CtfeEnv] [name : String]) : CtfeMaybeValue
  (match env
    [(CtfeEnvNil _ _) (CtfeNoValue)]
    [(CtfeEnvCons key value rest)
      (if (string-eq key name)
        (CtfeSomeValue value)
        (ctfe-env-lookup (box-get rest) name))]))

(define (ctfe-string-prefix? [text : String] [prefix : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (< text-len prefix-len)
      false
      (string-eq (substring text 0 prefix-len) prefix))))

(define (ctfe-hygiene-enabled-name) : String
  "__tl_macro_hygiene_enabled")

(define (ctfe-hygiene-template-prefix) : String
  "__tl_macro_template$")

(define (ctfe-hygiene-enabled? [env : CtfeEnv]) : bool
  (match (ctfe-env-lookup env (ctfe-hygiene-enabled-name))
    [(CtfeSomeValue value)
      (match value
        [(CtfeBool enabled) enabled]
        [_ false])]
    [(CtfeNoValue) false]))

(define (ctfe-hygiene-template-name [name : String]) : String
  (if (ctfe-string-prefix? name (ctfe-hygiene-template-prefix))
    name
    (string-append (ctfe-hygiene-template-prefix) name)))

(define (ctfe-quote-name [env : CtfeEnv] [name : String]) : String
  (if (ctfe-hygiene-enabled? env)
    (ctfe-hygiene-template-name name)
    name))

(define (ctfe-quote-name-id [env : CtfeEnv] [name : i64]) : i64
  (intern (ctfe-quote-name env (intern-str name))))

(define (ctfe-reflect-info-key [info : CtfeReflectInfo]) : String
  (match info
    [(CtfeReflectStruct key _ _ _) key]
    [(CtfeReflectEnum key _ _ _) key]))

(define (ctfe-reflect-info-list-contains
  [infos : CtfeReflectInfoList]
  [key : String]) : bool
  (match infos
    [(CtfeReflectInfoNil) false]
    [(CtfeReflectInfoCons info rest)
      (if (string-eq (ctfe-reflect-info-key info) key)
        true
        (ctfe-reflect-info-list-contains (box-get rest) key))]))

(define (ctfe-reflect-info-list-add-if-missing
  [infos : CtfeReflectInfoList]
  [info : CtfeReflectInfo]) : CtfeReflectInfoList
  (if (ctfe-build-seen-add? (ctfe-reflect-info-key info))
    (CtfeReflectInfoCons info (box infos))
    infos))

(define (ctfe-reflect-info-lookup [infos : CtfeReflectInfoList] [key : String]) : CtfeMaybeReflectInfo
  (match infos
    [(CtfeReflectInfoNil) (CtfeNoReflectInfo)]
    [(CtfeReflectInfoCons info rest)
      (if (string-eq (ctfe-reflect-info-key info) key)
        (CtfeSomeReflectInfo info)
        (ctfe-reflect-info-lookup (box-get rest) key))]))

(define (ctfe-reflect-field-list-from-fields [fields : AstFieldDefList]) : CtfeReflectFieldList
  (match fields
    [(AstFieldDefNil) CtfeReflectFieldNil]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef name ty _)
            (CtfeReflectFieldCons
              (CtfeReflectField (intern-str name) ty)
              (box (ctfe-reflect-field-list-from-fields rest)))]))]))

(define (ctfe-reflect-variant-list-from-variants [variants : AstVariantDefList]) : CtfeReflectVariantList
  (match variants
    [(AstVariantDefNil) CtfeReflectVariantNil]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef name payloads _)
            (CtfeReflectVariantCons
              (CtfeReflectVariant (intern-str name) payloads)
              (box (ctfe-reflect-variant-list-from-variants rest)))]))]))

(define (ctfe-reflect-info-add-alias
  [infos : CtfeReflectInfoList]
  [info : CtfeReflectInfo]
  [alias : String]) : CtfeReflectInfoList
  (match info
    [(CtfeReflectStruct _ module name fields)
      (ctfe-reflect-info-list-add-if-missing
        infos
        (CtfeReflectStruct alias module name fields))]
    [(CtfeReflectEnum _ module name variants)
      (ctfe-reflect-info-list-add-if-missing
        infos
        (CtfeReflectEnum alias module name variants))]))

(define (ctfe-reflect-info-add-names
  [infos : CtfeReflectInfoList]
  [info : CtfeReflectInfo]
  [name : String]
  [module : String]) : CtfeReflectInfoList
  (let
    [with-key : CtfeReflectInfoList
      (ctfe-reflect-info-list-add-if-missing infos info)]
    (if (= (string-length module) 0)
      with-key
      (ctfe-reflect-info-add-alias with-key info name))))

(define (ctfe-reflections-from-decls
  [decls : AstDeclList]
  [module : String]
  [infos : CtfeReflectInfoList]) : CtfeReflectInfoList
  (match decls
    [(AstDeclNil) infos]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (ctfe-reflections-from-decls rest (intern-str next-module) infos)]
          [(AstDeclDefStruct name _ _ fields)
            (let
              [name-str : String (intern-str name)]
              [key : String
                (if (= (string-length module) 0)
                  name-str
                  (string-append module (string-append "/" name-str)))]
              [info : CtfeReflectInfo
                (CtfeReflectStruct
                  key
                  module
                  name-str
                  (ctfe-reflect-field-list-from-fields fields))]
              (ctfe-reflections-from-decls
                rest
                module
                (ctfe-reflect-info-add-names infos info name-str module)))]
          [(AstDeclDefStructLifetimes name _ _ _ fields)
            (let
              [name-str : String (intern-str name)]
              [key : String
                (if (= (string-length module) 0)
                  name-str
                  (string-append module (string-append "/" name-str)))]
              [info : CtfeReflectInfo
                (CtfeReflectStruct
                  key
                  module
                  name-str
                  (ctfe-reflect-field-list-from-fields fields))]
              (ctfe-reflections-from-decls
                rest
                module
                (ctfe-reflect-info-add-names infos info name-str module)))]
          [(AstDeclDefEnum name _ variants)
            (let
              [name-str : String (intern-str name)]
              [key : String
                (if (= (string-length module) 0)
                  name-str
                  (string-append module (string-append "/" name-str)))]
              [info : CtfeReflectInfo
                (CtfeReflectEnum
                  key
                  module
                  name-str
                  (ctfe-reflect-variant-list-from-variants variants))]
              (ctfe-reflections-from-decls
                rest
                module
                (ctfe-reflect-info-add-names infos info name-str module)))]
          [(AstDeclDefEnumLifetimes name _ _ variants)
            (let
              [name-str : String (intern-str name)]
              [key : String
                (if (= (string-length module) 0)
                  name-str
                  (string-append module (string-append "/" name-str)))]
              [info : CtfeReflectInfo
                (CtfeReflectEnum
                  key
                  module
                  name-str
                  (ctfe-reflect-variant-list-from-variants variants))]
              (ctfe-reflections-from-decls
                rest
                module
                (ctfe-reflect-info-add-names infos info name-str module)))]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDeclDefStruct name _ _ fields)
                  (let
                    [name-str : String (intern-str name)]
                    [key : String
                      (if (= (string-length module) 0)
                        name-str
                        (string-append module (string-append "/" name-str)))]
                    [info : CtfeReflectInfo
                      (CtfeReflectStruct
                        key
                        module
                        name-str
                        (ctfe-reflect-field-list-from-fields fields))]
                    (ctfe-reflections-from-decls
                      rest
                      module
                      (ctfe-reflect-info-add-names infos info name-str module)))]
                [(AstDeclDefStructLifetimes name _ _ _ fields)
                  (let
                    [name-str : String (intern-str name)]
                    [key : String
                      (if (= (string-length module) 0)
                        name-str
                        (string-append module (string-append "/" name-str)))]
                    [info : CtfeReflectInfo
                      (CtfeReflectStruct
                        key
                        module
                        name-str
                        (ctfe-reflect-field-list-from-fields fields))]
                    (ctfe-reflections-from-decls
                      rest
                      module
                      (ctfe-reflect-info-add-names infos info name-str module)))]
                [(AstDeclDefEnum name _ variants)
                  (let
                    [name-str : String (intern-str name)]
                    [key : String
                      (if (= (string-length module) 0)
                        name-str
                        (string-append module (string-append "/" name-str)))]
                    [info : CtfeReflectInfo
                      (CtfeReflectEnum
                        key
                        module
                        name-str
                        (ctfe-reflect-variant-list-from-variants variants))]
                    (ctfe-reflections-from-decls
                      rest
                      module
                      (ctfe-reflect-info-add-names infos info name-str module)))]
                [(AstDeclDefEnumLifetimes name _ _ variants)
                  (let
                    [name-str : String (intern-str name)]
                    [key : String
                      (if (= (string-length module) 0)
                        name-str
                        (string-append module (string-append "/" name-str)))]
                    [info : CtfeReflectInfo
                      (CtfeReflectEnum
                        key
                        module
                        name-str
                        (ctfe-reflect-variant-list-from-variants variants))]
                    (ctfe-reflections-from-decls
                      rest
                      module
                      (ctfe-reflect-info-add-names infos info name-str module)))]
                [_ (ctfe-reflections-from-decls rest module infos)]))]
          [_ (ctfe-reflections-from-decls rest module infos)]))]))

(define (ctfe-reflections-from-program [program : AstProgram]) : CtfeReflectInfoList
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (begin
          (ctfe-build-seen-reset!)
          (ctfe-reflections-from-decls decls "" CtfeReflectInfoNil)))]))

;; Result of evaluating a sub-expression: either a value (carrying the remaining
;; fuel) or a diagnostic. Fuel is threaded so each evaluation step decrements a
;; shared budget across all sub-evaluations, matching the spirit of the Rust
;; evaluator's per-step 10_000 fuel cap.
(defenum ResultCtfe
  (OkCtfe CompilerCtfeValue i64)
  (ErrCtfe CompilerDiagnostic))

(defenum ResultCtfeQuoteExpr
  (OkCtfeQuoteExpr i64 AstType i64)
  (ErrCtfeQuoteExpr CompilerDiagnostic))

(defenum ResultCtfeQuoteExprList
  (OkCtfeQuoteExprList AstExprList i64)
  (ErrCtfeQuoteExprList CompilerDiagnostic))

(defenum ResultCtfeQuoteLetBindings
  (OkCtfeQuoteLetBindings AstLetBindingList i64)
  (ErrCtfeQuoteLetBindings CompilerDiagnostic))

(defenum ResultCtfeQuoteResourceBindings
  (OkCtfeQuoteResourceBindings AstResourceBindingList i64)
  (ErrCtfeQuoteResourceBindings CompilerDiagnostic))

(defenum ResultCtfeQuotePattern
  (OkCtfeQuotePattern AstPattern)
  (ErrCtfeQuotePattern CompilerDiagnostic))

(defenum ResultCtfeQuotePatternList
  (OkCtfeQuotePatternList AstPatternList)
  (ErrCtfeQuotePatternList CompilerDiagnostic))

(defenum ResultCtfeQuoteArms
  (OkCtfeQuoteArms AstMatchArmList i64)
  (ErrCtfeQuoteArms CompilerDiagnostic))

(define (ctfe-fuel-limit) : i64
  10000)

;; Build a diagnostic anchored at the (possibly spanned) expression.
(define (ctfe-diagnostic-at-expr [expr : AstExpr] [message : String]) : CompilerDiagnostic
  (match expr
    [(AstExprSpanned _ span)
      (compiler-diagnostic-from-ast-span "" span message)]
    [_ (compiler-diagnostic-at-start "" message)]))

;; Human-readable tag for the unsupported-form diagnostic, mirroring
;; `describe_expr` in src/ctfe.rs.
(define (ctfe-describe-expr [expr : AstExpr]) : String
  (match expr
    [(AstExprSpanned _ _) "expression"]
    [(AstExprLiteral _) "literal"]
    [(AstExprVar _) "variable reference"]
    [(AstExprBinary _ _ _) "binary operation"]
    [(AstExprUnary _ _) "unary operation"]
    [(AstExprCall _ _) "function call"]
    [(AstExprBracketClause _) "bracket clause"]
    [(AstExprTypeLiteral _) "type literal"]
    [(AstExprIf _ _ _) "if"]
    [(AstExprLet _ _) "let"]
    [(AstExprLambda _ _ _) "lambda"]
    [(AstExprTuple _) "tuple"]
    [(AstExprTupleRef _ _) "tuple-ref"]
    [(AstExprArray _) "array"]
    [(AstExprMakeArray _ _) "make-array"]
    [(AstExprArrayRef _ _) "array-ref"]
    [(AstExprArraySet _ _ _) "array-set!"]
    [(AstExprArrayPush _ _) "array-push!"]
    [(AstExprStringRef _ _) "string-ref"]
    [(AstExprWhile _ _) "while"]
    [(AstExprBegin _) "begin"]
    [(AstExprUnsafe _) "unsafe"]
    [(AstExprSet _ _) "set!"]
    [(AstExprAnn _ _) "type annotation"]
    [(AstExprCast _ _) "cast"]
    [(AstExprBorrow mutable _ _)
      (if mutable
        "mutable borrow"
        "borrow")]
    [(AstExprMatch _ _) "match"]
    [(AstExprForeach _ _ _ _ _) "foreach"]
    [(AstExprSpmdReduce _ _ _ _ _ _ _) "spmd-reduce"]
    [(AstExprStructGet _ _) "struct-get"]
    [(AstExprStructSet _ _ _) "set!"]
    [(AstExprWithRegion _ _) "with-arena"]
    [(AstExprWithEscape _ _) "with-escape"]
    [(AstExprWithResource _ _) "with"]
    [(AstExprTypeLiteral _) "type literal"]
    [(AstExprInit _) "init"]
    [(AstExprComptime _) "comptime"]
    [(AstExprQuote _) "quote"]
    [(AstExprQuasiquote _) "quasiquote"]
    [(AstExprUnquote _) "unquote"]
    [(AstExprUnquoteSplicing _) "unquote-splicing"]
    [(AstExprTry _) "try"]
    [(AstExprReturn _) "return"]
    [(AstExprPtrNull _) "ptr-null"]
    [(AstExprPtrNullCheck _) "ptr-null?"]
    [(AstExprPtrAddrOf _) "ptr-addr-of"]
    [(AstExprPtrRead _) "ptr-read"]
    [(AstExprPtrWrite _ _) "ptr-write!"]
    [(AstExprPtrOffset _ _) "ptr-offset"]
    [(AstExprPtrCast _ _) "ptr-cast"]
    [(AstExprPtrToInt _) "ptr->int"]
    [(AstExprIntToPtr _ _) "int->ptr"]
    [(AstExprBox _) "box"]
    [(AstExprBoxGet _) "box-get"]
    [(AstExprStringData _) "string-data"]
    [(AstExprStringFromBytes _ _) "string-from-bytes"]
    [(AstExprArrayData _) "array-data"]
    [(AstExprProgramArgc) "program-argc"]
    [(AstExprProgramArgv) "program-argv"]
    [(AstExprProgramEnvp) "program-envp"]
    [(AstExprCpuIdEax _ _) "cpuid-eax"]
    [(AstExprCpuIdEbx _ _) "cpuid-ebx"]
    [(AstExprCpuIdEcx _ _) "cpuid-ecx"]
    [(AstExprCpuIdEdx _ _) "cpuid-edx"]
    [(AstExprXgetbv _) "xgetbv"]
    [(AstExprSyscall _) "syscall"]))

(define (ctfe-value-type-name [value : CompilerCtfeValue]) : String
  (match value
    [(CtfeI64 _) "i64"]
    [(CtfeF64 _) "f64"]
    [(CtfeF32 _) "f32"]
    [(CtfeBool _) "bool"]
    [(CtfeChar _) "char"]
    [(CtfeString _) "String"]
    [(CtfeUnit) "unit"]
    [(CtfeType _) "type"]
    [(CtfeExpr _ _) "Expr"]
    [(CtfeExprList _) "expr-list"]
    [(CtfeExprClause _) "ExprClause"]
    [(CtfeExprClauseList _) "ExprClauseList"]))

;; Promote a char to its i64 code point so the i64 comparison primitives drive
;; char ordering/equality, matching Rust's code-point comparison.
(define (ctfe-char-code [c : char]) : i64
  (cast c : i64))

;; --- literals ---------------------------------------------------------------
(define (ctfe-eval-literal [lit : AstLiteral] [expr : AstExpr] [fuel : i64]) : ResultCtfe
  (match lit
    [(AstLitInt n) (OkCtfe (CtfeI64 n) fuel)]
    [(AstLitBool b) (OkCtfe (CtfeBool b) fuel)]
    [(AstLitChar c) (OkCtfe (CtfeChar c) fuel)]
    [(AstLitUnit) (OkCtfe (CtfeUnit) fuel)]
    [(AstLitFloat text)
      (match (compiler-float-parse-f64 text)
        [(CompilerFloatSomeF64 value)
          (if (compiler-float-f64-finite? value)
            (OkCtfe (CtfeF64 value) fuel)
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                "comptime: non-finite f64 literal is not supported")))]
        [(CompilerFloatNoF64)
          (ErrCtfe
            (ctfe-diagnostic-at-expr expr "comptime: invalid f64 literal"))])]
    [(AstLitString text) (OkCtfe (CtfeString text) fuel)]))

;; --- binary operators -------------------------------------------------------
;; i64 arithmetic/bitwise/shift and i64 comparisons.
(define (ctfe-eval-bin-i64
  [op : AstBinOp]
  [a : i64]
  [b : i64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinAdd) (OkCtfe (CtfeI64 (+ a b)) fuel)]
    [(AstBinSub) (OkCtfe (CtfeI64 (- a b)) fuel)]
    [(AstBinMul) (OkCtfe (CtfeI64 (* a b)) fuel)]
    [(AstBinDiv)
      (if (= b 0)
        (ErrCtfe (ctfe-diagnostic-at-expr expr "division by zero in comptime"))
        (OkCtfe (CtfeI64 (/ a b)) fuel))]
    [(AstBinMod)
      (if (= b 0)
        (ErrCtfe (ctfe-diagnostic-at-expr expr "modulo by zero in comptime"))
        (OkCtfe (CtfeI64 (% a b)) fuel))]
    [(AstBinEq) (OkCtfe (CtfeBool (= a b)) fuel)]
    [(AstBinNe) (OkCtfe (CtfeBool (!= a b)) fuel)]
    [(AstBinLt) (OkCtfe (CtfeBool (< a b)) fuel)]
    [(AstBinLe) (OkCtfe (CtfeBool (<= a b)) fuel)]
    [(AstBinGt) (OkCtfe (CtfeBool (> a b)) fuel)]
    [(AstBinGe) (OkCtfe (CtfeBool (>= a b)) fuel)]
    [(AstBinBitAnd) (OkCtfe (CtfeI64 (bit-and a b)) fuel)]
    [(AstBinBitOr) (OkCtfe (CtfeI64 (bit-or a b)) fuel)]
    [(AstBinBitXor) (OkCtfe (CtfeI64 (bit-xor a b)) fuel)]
    [(AstBinShl) (OkCtfe (CtfeI64 (shl a b)) fuel)]
    [(AstBinShr) (OkCtfe (CtfeI64 (shr a b)) fuel)]
    [(AstBinAnd)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "'and' in comptime requires bool operands"))]
    [(AstBinOr)
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "'or' in comptime requires bool operands"))]))

(define (ctfe-f64-result [value : f64] [expr : AstExpr] [fuel : i64]) : ResultCtfe
  (if (compiler-float-f64-finite? value)
    (OkCtfe (CtfeF64 value) fuel)
    (ErrCtfe
      (ctfe-diagnostic-at-expr
        expr
        "comptime: non-finite f64 result is not supported"))))

(define (ctfe-f32-result [value : f64] [expr : AstExpr] [fuel : i64]) : ResultCtfe
  (let
    [rounded : f64 (compiler-float-round-f32-as-f64 value)]
    (if (compiler-float-f64-finite? rounded)
      (OkCtfe (CtfeF32 rounded) fuel)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "comptime: non-finite f32 result is not supported")))))

;; Finite f64 arithmetic and comparisons. Non-finite results are rejected until
;; TypeLisp specifies NaN payload and infinity serialization across backends.
(define (ctfe-eval-bin-f64
  [op : AstBinOp]
  [a : f64]
  [b : f64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinAdd) (ctfe-f64-result (+ a b) expr fuel)]
    [(AstBinSub) (ctfe-f64-result (- a b) expr fuel)]
    [(AstBinMul) (ctfe-f64-result (* a b) expr fuel)]
    [(AstBinDiv)
      (if (= b 0.0)
        (ErrCtfe
          (ctfe-diagnostic-at-expr expr "float division by zero in comptime"))
        (ctfe-f64-result (/ a b) expr fuel))]
    [(AstBinEq) (OkCtfe (CtfeBool (= a b)) fuel)]
    [(AstBinNe) (OkCtfe (CtfeBool (!= a b)) fuel)]
    [(AstBinLt) (OkCtfe (CtfeBool (< a b)) fuel)]
    [(AstBinLe) (OkCtfe (CtfeBool (<= a b)) fuel)]
    [(AstBinGt) (OkCtfe (CtfeBool (> a b)) fuel)]
    [(AstBinGe) (OkCtfe (CtfeBool (>= a b)) fuel)]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "this operation is not supported on f64 in compile-time evaluation"))]))

(define (ctfe-eval-bin-f32
  [op : AstBinOp]
  [a : f64]
  [b : f64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinAdd) (ctfe-f32-result (+ a b) expr fuel)]
    [(AstBinSub) (ctfe-f32-result (- a b) expr fuel)]
    [(AstBinMul) (ctfe-f32-result (* a b) expr fuel)]
    [(AstBinDiv)
      (if (= b 0.0)
        (ErrCtfe
          (ctfe-diagnostic-at-expr expr "float division by zero in comptime"))
        (ctfe-f32-result (/ a b) expr fuel))]
    [(AstBinEq) (OkCtfe (CtfeBool (= a b)) fuel)]
    [(AstBinNe) (OkCtfe (CtfeBool (!= a b)) fuel)]
    [(AstBinLt) (OkCtfe (CtfeBool (< a b)) fuel)]
    [(AstBinLe) (OkCtfe (CtfeBool (<= a b)) fuel)]
    [(AstBinGt) (OkCtfe (CtfeBool (> a b)) fuel)]
    [(AstBinGe) (OkCtfe (CtfeBool (>= a b)) fuel)]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "this operation is not supported on f32 in compile-time evaluation"))]))

;; bool comparisons and boolean connectives.
(define (ctfe-eval-bin-bool
  [op : AstBinOp]
  [a : bool]
  [b : bool]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinEq) (OkCtfe (CtfeBool (or (and a b) (and (not a) (not b)))) fuel)]
    [(AstBinNe)
      (OkCtfe (CtfeBool (not (or (and a b) (and (not a) (not b))))) fuel)]
    [(AstBinAnd) (OkCtfe (CtfeBool (and a b)) fuel)]
    [(AstBinOr) (OkCtfe (CtfeBool (or a b)) fuel)]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "this operation is not supported on bool in compile-time evaluation"))]))

;; char comparisons via code-point ordering.
(define (ctfe-eval-bin-char
  [op : AstBinOp]
  [a : char]
  [b : char]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (let
    [ca : i64 (ctfe-char-code a)]
    [cb : i64 (ctfe-char-code b)]
    (match op
      [(AstBinEq) (OkCtfe (CtfeBool (= ca cb)) fuel)]
      [(AstBinNe) (OkCtfe (CtfeBool (!= ca cb)) fuel)]
      [(AstBinLt) (OkCtfe (CtfeBool (< ca cb)) fuel)]
      [(AstBinLe) (OkCtfe (CtfeBool (<= ca cb)) fuel)]
      [(AstBinGt) (OkCtfe (CtfeBool (> ca cb)) fuel)]
      [(AstBinGe) (OkCtfe (CtfeBool (>= ca cb)) fuel)]
      [_
        (ErrCtfe
          (ctfe-diagnostic-at-expr
            expr
            "this operation is not supported on char in compile-time evaluation"))])))

;; string comparisons (only `==`/`!=`).
(define (ctfe-eval-bin-string
  [op : AstBinOp]
  [a : String]
  [b : String]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinEq) (OkCtfe (CtfeBool (string-eq a b)) fuel)]
    [(AstBinNe) (OkCtfe (CtfeBool (not (string-eq a b))) fuel)]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "this operation is not supported on String in compile-time evaluation"))]))

;; unit comparisons (only `==`/`!=`).
(define (ctfe-eval-bin-unit [op : AstBinOp] [expr : AstExpr] [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinEq) (OkCtfe (CtfeBool true) fuel)]
    [(AstBinNe) (OkCtfe (CtfeBool false) fuel)]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "this operation is not supported on unit in compile-time evaluation"))]))

;; Dispatch a binary op over two already-evaluated operands.
(define (ctfe-apply-binop
  [op : AstBinOp]
  [lv : CompilerCtfeValue]
  [rv : CompilerCtfeValue]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match lv
    [(CtfeI64 a)
      (match rv
        [(CtfeI64 b) (ctfe-eval-bin-i64 op a b expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeF64 a)
      (match rv
        [(CtfeF64 b) (ctfe-eval-bin-f64 op a b expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeF32 a)
      (match rv
        [(CtfeF32 b) (ctfe-eval-bin-f32 op a b expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeBool a)
      (match rv
        [(CtfeBool b) (ctfe-eval-bin-bool op a b expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeChar a)
      (match rv
        [(CtfeChar b) (ctfe-eval-bin-char op a b expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeString a)
      (match rv
        [(CtfeString b) (ctfe-eval-bin-string op a b expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeUnit)
      (match rv
        [(CtfeUnit) (ctfe-eval-bin-unit op expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeType a)
      (match rv
        [(CtfeType b)
          (match op
            [(AstBinEq) (OkCtfe (CtfeBool (ctfe-type-eq a b)) fuel)]
            [(AstBinNe) (OkCtfe (CtfeBool (not (ctfe-type-eq a b))) fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "this operation is not supported on type in compile-time evaluation"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeExpr a a-ty)
      (match rv
        [(CtfeExpr b b-ty)
          (match op
            [(AstBinEq)
              (OkCtfe
                (CtfeBool
                  (and
                    (ctfe-expr-eq (ast-node-get a) (ast-node-get b))
                    (ctfe-type-eq a-ty b-ty)))
                fuel)]
            [(AstBinNe)
              (OkCtfe
                (CtfeBool
                  (not
                    (and
                      (ctfe-expr-eq (ast-node-get a) (ast-node-get b))
                      (ctfe-type-eq a-ty b-ty))))
                fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "this operation is not supported on expr in compile-time evaluation"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeExprList a)
      (match rv
        [(CtfeExprList b)
          (match op
            [(AstBinEq) (OkCtfe (CtfeBool (ctfe-expr-list-eq a b)) fuel)]
            [(AstBinNe) (OkCtfe (CtfeBool (not (ctfe-expr-list-eq a b))) fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "this operation is not supported on expr-list in compile-time evaluation"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeExprClause a)
      (match rv
        [(CtfeExprClause b)
          (match op
            [(AstBinEq) (OkCtfe (CtfeBool (ctfe-expr-clause-eq a b)) fuel)]
            [(AstBinNe)
              (OkCtfe (CtfeBool (not (ctfe-expr-clause-eq a b))) fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "this operation is not supported on expr-clause in compile-time evaluation"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]
    [(CtfeExprClauseList a)
      (match rv
        [(CtfeExprClauseList b)
          (match op
            [(AstBinEq) (OkCtfe (CtfeBool (ctfe-expr-clause-list-eq a b)) fuel)]
            [(AstBinNe)
              (OkCtfe (CtfeBool (not (ctfe-expr-clause-list-eq a b))) fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "this operation is not supported on expr-clause-list in compile-time evaluation"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "binary operation in comptime requires matching operand types"))])]))

;; --- unary operators --------------------------------------------------------
(define (ctfe-apply-unop
  [op : AstUnOp]
  [v : CompilerCtfeValue]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstUnNeg)
      (match v
        [(CtfeI64 n) (OkCtfe (CtfeI64 (- 0 n)) fuel)]
        [(CtfeF64 n) (ctfe-f64-result (- 0.0 n) expr fuel)]
        [(CtfeF32 n) (ctfe-f32-result (- 0.0 n) expr fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "negation in comptime requires a numeric type"))])]
    [(AstUnNot)
      (match v
        [(CtfeBool b) (OkCtfe (CtfeBool (not b)) fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr expr "'not' in comptime requires bool"))])]
    [(AstUnBitNot)
      (match v
        [(CtfeI64 n) (OkCtfe (CtfeI64 (bit-not n)) fuel)]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "bitwise not in comptime requires i64"))])]))

(define (ctfe-apply-cast
  [value : CompilerCtfeValue]
  [ty : AstType]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match ty
    [(AstTyF64)
      (match value
        [(CtfeF64 _) (OkCtfe value fuel)]
        [(CtfeF32 n) (ctfe-f64-result n expr fuel)]
        [(CtfeI64 n) (ctfe-f64-result (cast n : f64) expr fuel)]
        [_
          (ErrCtfe (ctfe-diagnostic-at-expr expr "comptime: unsupported cast"))])]
    [(AstTyF32)
      (match value
        [(CtfeF64 n) (ctfe-f32-result n expr fuel)]
        [(CtfeF32 _) (OkCtfe value fuel)]
        [(CtfeI64 n) (ctfe-f32-result (cast n : f64) expr fuel)]
        [_
          (ErrCtfe (ctfe-diagnostic-at-expr expr "comptime: unsupported cast"))])]
    [(AstTyI64)
      (match value
        [(CtfeI64 _) (OkCtfe value fuel)]
        [_
          (ErrCtfe (ctfe-diagnostic-at-expr expr "comptime: unsupported cast"))])]
    [_ (ErrCtfe (ctfe-diagnostic-at-expr expr "comptime: unsupported cast"))]))

(define (ctfe-eval-cast
  [inner : AstExpr]
  [ty : AstType]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval inner env fuel)
    [(OkCtfe value next-fuel) (ctfe-apply-cast value ty expr next-fuel)]
    [(ErrCtfe diag) (ErrCtfe diag)]))

(defenum ResultCtfeStringLookup
  (OkCtfeStringLookup String)
  (ErrCtfeStringLookup String))

(defenum ResultCtfeTypeLookup
  (OkCtfeTypeLookup AstType)
  (ErrCtfeTypeLookup String))

(defenum ResultCtfeTypeListLookup
  (OkCtfeTypeListLookup AstTypeList)
  (ErrCtfeTypeListLookup String))

(defenum ResultCtfeTypeArg
  (OkCtfeTypeArg AstType i64)
  (ErrCtfeTypeArg CompilerDiagnostic))

(defenum ResultCtfeI64Arg
  (OkCtfeI64Arg i64 i64)
  (ErrCtfeI64Arg CompilerDiagnostic))

(defenum ResultCtfeStringArg
  (OkCtfeStringArg String i64)
  (ErrCtfeStringArg CompilerDiagnostic))

(define (ctfe-reflect-info-canonical-type [info : CtfeReflectInfo]) : AstType
  (match info
    [(CtfeReflectStruct key _ _ _) (AstTyStruct (intern key))]
    [(CtfeReflectEnum key _ _ _) (AstTyEnum (intern key))]))

(define (ctfe-reflect-resolve-type-list
  [infos : CtfeReflectInfoList]
  [types : AstTypeList]) : AstTypeList
  (match types
    [(AstTypeNil) AstTypeNil]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ty-node-get head)]
        [rest : AstTypeList (box-get rest)]
        (ast-type-cons
          (ctfe-reflect-resolve-type infos head)
          (ctfe-reflect-resolve-type-list infos rest)))]))

(define (ctfe-reflect-resolve-type [infos : CtfeReflectInfoList] [ty : AstType]) : AstType
  (match ty
    [(AstTyFunc args ret)
      (ast-ty-func
        (ctfe-reflect-resolve-type-list infos args)
        (ctfe-reflect-resolve-type infos (ty-node-get ret)))]
    [(AstTyTuple elems)
      (AstTyTuple (ctfe-reflect-resolve-type-list infos elems))]
    [(AstTyArray elem len)
      (ast-ty-array (ctfe-reflect-resolve-type infos (ty-node-get elem)) len)]
    [(AstTyDynArray elem)
      (ast-ty-dyn-array (ctfe-reflect-resolve-type infos (ty-node-get elem)))]
    [(AstTyBox elem)
      (ast-ty-box (ctfe-reflect-resolve-type infos (ty-node-get elem)))]
    [(AstTyPtr elem)
      (ast-ty-ptr (ctfe-reflect-resolve-type infos (ty-node-get elem)))]
    [(AstTyMutPtr elem)
      (ast-ty-mut-ptr (ctfe-reflect-resolve-type infos (ty-node-get elem)))]
    [(AstTyRef region inner)
      (ast-ty-ref region (ctfe-reflect-resolve-type infos (ty-node-get inner)))]
    [(AstTyMutRef region inner)
      (ast-ty-mut-ref
        region
        (ctfe-reflect-resolve-type infos (ty-node-get inner)))]
    [(AstTyRegion region inner)
      (ast-ty-region
        region
        (ctfe-reflect-resolve-type infos (ty-node-get inner)))]
    [(AstTyStruct name)
      (match (ctfe-reflect-info-lookup infos (intern-str name))
        [(CtfeSomeReflectInfo info) (ctfe-reflect-info-canonical-type info)]
        [(CtfeNoReflectInfo) ty])]
    [(AstTyEnum name)
      (match (ctfe-reflect-info-lookup infos (intern-str name))
        [(CtfeSomeReflectInfo info) (ctfe-reflect-info-canonical-type info)]
        [(CtfeNoReflectInfo) ty])]
    [(AstTyVar name)
      (match (ctfe-reflect-info-lookup infos (intern-str name))
        [(CtfeSomeReflectInfo info) (ctfe-reflect-info-canonical-type info)]
        [(CtfeNoReflectInfo) ty])]
    [_ ty]))

(define (ctfe-int-key [n : i64]) : String
  (if (< n 0)
    (string-append "m" (int->string (- 0 n)))
    (int->string n)))

(define (ctfe-type-list-key [infos : CtfeReflectInfoList] [types : AstTypeList]) : String
  (match types
    [(AstTypeNil) "nil"]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ty-node-get head)]
        [rest : AstTypeList (box-get rest)]
        (string-append
          (ctfe-type-key-with-reflections infos head)
          (string-append "_" (ctfe-type-list-key infos rest))))]))

(define (ctfe-lifetime-list-key [lifetimes : AstLifetimeList]) : String
  (match lifetimes
    [(AstLifetimeNil) "nil"]
    [(AstLifetimeCons head rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (string-append head (string-append "_" (ctfe-lifetime-list-key rest))))]))

(define (ctfe-lifetime-list-eq [a : AstLifetimeList] [b : AstLifetimeList]) : bool
  (match a
    [(AstLifetimeNil)
      (match b
        [(AstLifetimeNil) true]
        [_ false])]
    [(AstLifetimeCons a-head a-rest)
      (let
        [a-rest : AstLifetimeList (box-get a-rest)]
        (match b
          [(AstLifetimeCons b-head b-rest)
            (let
              [b-rest : AstLifetimeList (box-get b-rest)]
              (and
                (string-eq a-head b-head)
                (ctfe-lifetime-list-eq a-rest b-rest)))]
          [_ false]))]))

(define (ctfe-type-key-with-reflections
  [infos : CtfeReflectInfoList]
  [ty : AstType]) : String
  (match (ctfe-reflect-resolve-type infos ty)
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
    [(AstTyExpr) "Expr"]
    [(AstTyExprList) "ExprList"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyFunc args ret)
      (string-append
        "fn_"
        (string-append
          (ctfe-type-list-key infos args)
          (string-append
            "_to_"
            (ctfe-type-key-with-reflections infos (ty-node-get ret)))))]
    [(AstTyTuple elems)
      (string-append "tuple_" (ctfe-type-list-key infos elems))]
    [(AstTyArray elem count)
      (string-append
        "array_"
        (string-append
          (ctfe-type-key-with-reflections infos (ty-node-get elem))
          (string-append "_" (ctfe-int-key count))))]
    [(AstTyDynArray elem)
      (string-append
        "dynarray_"
        (ctfe-type-key-with-reflections infos (ty-node-get elem)))]
    [(AstTyBox elem)
      (string-append
        "box_"
        (ctfe-type-key-with-reflections infos (ty-node-get elem)))]
    [(AstTyPtr elem)
      (string-append
        "ptr_"
        (ctfe-type-key-with-reflections infos (ty-node-get elem)))]
    [(AstTyMutPtr elem)
      (string-append
        "mutptr_"
        (ctfe-type-key-with-reflections infos (ty-node-get elem)))]
    [(AstTyRef region inner)
      (string-append
        "ref_"
        (string-append
          region
          (string-append
            "_"
            (ctfe-type-key-with-reflections infos (ty-node-get inner)))))]
    [(AstTyMutRef region inner)
      (string-append
        "mutref_"
        (string-append
          region
          (string-append
            "_"
            (ctfe-type-key-with-reflections infos (ty-node-get inner)))))]
    [(AstTyRegion region inner)
      (string-append
        "region_"
        (string-append
          region
          (string-append
            "_"
            (ctfe-type-key-with-reflections infos (ty-node-get inner)))))]
    [(AstTyEnum name) (string-append "enum_" (intern-str name))]
    [(AstTyEnumArgs name lifetimes)
      (string-append
        "enumargs_"
        (string-append
          (intern-str name)
          (string-append "_" (ctfe-lifetime-list-key lifetimes))))]
    [(AstTyStruct name) (string-append "struct_" (intern-str name))]
    [(AstTyStructArgs name lifetimes)
      (string-append
        "structargs_"
        (string-append
          (intern-str name)
          (string-append "_" (ctfe-lifetime-list-key lifetimes))))]
    [(AstTyVar name) (string-append "var_" (intern-str name))]
    [(AstTyVarArgs name lifetimes)
      (string-append
        "varargs_"
        (string-append
          (intern-str name)
          (string-append "_" (ctfe-lifetime-list-key lifetimes))))]))

(define (ctfe-type-key [ty : AstType]) : String
  (ctfe-type-key-with-reflections CtfeReflectInfoNil ty))

(define (ctfe-type-kind-with-reflections
  [infos : CtfeReflectInfoList]
  [ty : AstType]) : String
  (match (ctfe-reflect-resolve-type infos ty)
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
    [(AstTyString) "string"]
    [(AstTyStr) "str"]
    [(AstTyExpr) "expr"]
    [(AstTyExprList) "expr-list"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyFunc _ _) "function"]
    [(AstTyTuple _) "tuple"]
    [(AstTyArray _ _) "array"]
    [(AstTyDynArray _) "dyn-array"]
    [(AstTyBox _) "box"]
    [(AstTyPtr _) "ptr"]
    [(AstTyMutPtr _) "mut-ptr"]
    [(AstTyRef _ _) "ref"]
    [(AstTyMutRef _ _) "mut-ref"]
    [(AstTyRegion _ _) "region"]
    [(AstTyEnum _) "enum"]
    [(AstTyEnumArgs _ _) "enum"]
    [(AstTyStruct _) "struct"]
    [(AstTyStructArgs _ _) "struct"]
    [(AstTyVar _) "type-var"]
    [(AstTyVarArgs _ _) "type-var"]))

(define (ctfe-eval-type-arg
  [arg : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [name : String]) : ResultCtfeTypeArg
  (match (compiler-ctfe-eval arg env fuel)
    [(ErrCtfe d) (ErrCtfeTypeArg d)]
    [(OkCtfe value arg-fuel)
      (match value
        [(CtfeType ty)
          (OkCtfeTypeArg
            (ctfe-reflect-resolve-type (ctfe-env-reflections env) ty)
            arg-fuel)]
        [_
          (ErrCtfeTypeArg
            (ctfe-diagnostic-at-expr
              expr
              (string-append name " expects a type argument")))])]))

(define (ctfe-eval-i64-arg
  [arg : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [name : String]) : ResultCtfeI64Arg
  (match (compiler-ctfe-eval arg env fuel)
    [(ErrCtfe d) (ErrCtfeI64Arg d)]
    [(OkCtfe value arg-fuel)
      (match value
        [(CtfeI64 n) (OkCtfeI64Arg n arg-fuel)]
        [_
          (ErrCtfeI64Arg
            (ctfe-diagnostic-at-expr
              expr
              (string-append name " expects an i64 index")))])]))

(define (ctfe-eval-string-arg
  [arg : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [name : String]) : ResultCtfeStringArg
  (match (compiler-ctfe-eval arg env fuel)
    [(ErrCtfe d) (ErrCtfeStringArg d)]
    [(OkCtfe value arg-fuel)
      (match value
        [(CtfeString text) (OkCtfeStringArg text arg-fuel)]
        [_
          (ErrCtfeStringArg
            (ctfe-diagnostic-at-expr
              expr
              (string-append name " expects a String argument")))])]))

(define (ctfe-reflect-field-list-count [fields : CtfeReflectFieldList]) : i64
  (match fields
    [(CtfeReflectFieldNil) 0]
    [(CtfeReflectFieldCons _ rest)
      (+ 1 (ctfe-reflect-field-list-count (box-get rest)))]))

(define (ctfe-reflect-field-name-at
  [fields : CtfeReflectFieldList]
  [index : i64]) : ResultCtfeStringLookup
  (if (< index 0)
    (ErrCtfeStringLookup "index out of range")
    (match fields
      [(CtfeReflectFieldNil) (ErrCtfeStringLookup "index out of range")]
      [(CtfeReflectFieldCons field rest)
        (if (= index 0)
          (match field
            [(CtfeReflectField name _) (OkCtfeStringLookup name)])
          (ctfe-reflect-field-name-at (box-get rest) (- index 1)))])))

(define (ctfe-reflect-field-type-at
  [fields : CtfeReflectFieldList]
  [infos : CtfeReflectInfoList]
  [index : i64]) : ResultCtfeTypeLookup
  (if (< index 0)
    (ErrCtfeTypeLookup "index out of range")
    (match fields
      [(CtfeReflectFieldNil) (ErrCtfeTypeLookup "index out of range")]
      [(CtfeReflectFieldCons field rest)
        (if (= index 0)
          (match field
            [(CtfeReflectField _ ty)
              (OkCtfeTypeLookup (ctfe-reflect-resolve-type infos ty))])
          (ctfe-reflect-field-type-at (box-get rest) infos (- index 1)))])))

(define (ctfe-reflect-variant-list-count [variants : CtfeReflectVariantList]) : i64
  (match variants
    [(CtfeReflectVariantNil) 0]
    [(CtfeReflectVariantCons _ rest)
      (+ 1 (ctfe-reflect-variant-list-count (box-get rest)))]))

(define (ctfe-reflect-variant-name-at
  [variants : CtfeReflectVariantList]
  [index : i64]) : ResultCtfeStringLookup
  (if (< index 0)
    (ErrCtfeStringLookup "index out of range")
    (match variants
      [(CtfeReflectVariantNil) (ErrCtfeStringLookup "index out of range")]
      [(CtfeReflectVariantCons variant rest)
        (if (= index 0)
          (match variant
            [(CtfeReflectVariant name _) (OkCtfeStringLookup name)])
          (ctfe-reflect-variant-name-at (box-get rest) (- index 1)))])))

(define (ctfe-reflect-variant-payloads-at
  [variants : CtfeReflectVariantList]
  [index : i64]) : ResultCtfeTypeListLookup
  (if (< index 0)
    (ErrCtfeTypeListLookup "index out of range")
    (match variants
      [(CtfeReflectVariantNil) (ErrCtfeTypeListLookup "index out of range")]
      [(CtfeReflectVariantCons variant rest)
        (if (= index 0)
          (match variant
            [(CtfeReflectVariant _ payloads) (OkCtfeTypeListLookup payloads)])
          (ctfe-reflect-variant-payloads-at (box-get rest) (- index 1)))])))

(define (ctfe-type-list-count [types : AstTypeList]) : i64
  (match types
    [(AstTypeNil) 0]
    [(AstTypeCons _ rest)
      (let
        [rest : AstTypeList (box-get rest)]
        (+ 1 (ctfe-type-list-count rest)))]))

(define (ctfe-type-list-ref
  [types : AstTypeList]
  [infos : CtfeReflectInfoList]
  [index : i64]) : ResultCtfeTypeLookup
  (if (< index 0)
    (ErrCtfeTypeLookup "index out of range")
    (match types
      [(AstTypeNil) (ErrCtfeTypeLookup "index out of range")]
      [(AstTypeCons head rest)
        (let
          [head : AstType (ty-node-get head)]
          [rest : AstTypeList (box-get rest)]
          (if (= index 0)
            (OkCtfeTypeLookup (ctfe-reflect-resolve-type infos head))
            (ctfe-type-list-ref rest infos (- index 1))))])))

;; --- core evaluator ---------------------------------------------------------
;; Evaluate `expr` under `env` with the given remaining `fuel`. Each call
;; charges one unit of fuel up front (mirroring `use_fuel`); when fuel is
;; exhausted the evaluation fails deterministically.
(define (compiler-ctfe-eval [expr : AstExpr] [env : CtfeEnv] [fuel : i64]) : ResultCtfe
  (if (<= fuel 0)
    (ErrCtfe
      (ctfe-diagnostic-at-expr expr "compile-time evaluation limit exceeded"))
    (ctfe-eval-node expr env (- fuel 1))))

(define (ctfe-eval-node [expr : AstExpr] [env : CtfeEnv] [fuel : i64]) : ResultCtfe
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (ctfe-eval-cast inner ty expr env fuel))]
    [(AstExprTypeLiteral ty)
      (OkCtfe
        (CtfeType (ctfe-reflect-resolve-type (ctfe-env-reflections env) ty))
        fuel)]
    [(AstExprInit _)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "comptime: init is a runtime-only expression"))]
    [(AstExprLiteral lit) (ctfe-eval-literal lit expr fuel)]
    [(AstExprVar name) (ctfe-eval-var (intern-str name) expr env fuel)]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (ctfe-eval-binary op left right expr env fuel))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (ctfe-eval-unary op inner expr env fuel))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (ctfe-eval-if cond then-branch else-branch env fuel))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (ctfe-eval-let bindings body env fuel))]
    [(AstExprBegin exprs) (ctfe-eval-begin exprs env fuel)]
    [(AstExprUnsafe exprs) (ctfe-eval-begin exprs env fuel)]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (ctfe-eval-call func args expr env fuel))]
    [(AstExprQuote template-box)
      (let
        [template : AstExpr (ast-node-get template-box)]
        (ctfe-eval-quote template env fuel false))]
    [(AstExprQuasiquote template-box)
      (let
        [template : AstExpr (ast-node-get template-box)]
        (ctfe-eval-quote template env fuel true))]
    [(AstExprUnquote _)
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "unquote is only valid inside quasiquote"))]
    [(AstExprUnquoteSplicing _)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "unquote-splicing is only valid inside quasiquote"))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string-append
            "'"
            (string-append
              (ctfe-describe-expr expr)
              "' is not supported in compile-time evaluation"))))]))

;; Type size / alignment in bytes for CTFE layout queries. Builtins mirror the
;; lowerer ABI; user-defined names come from the layout table carried in `env`.
;; Unresolved type variables without a table entry return -1 so callers can
;; produce a source-located diagnostic instead of inventing runtime metadata.
(define (ctfe-type-size [layouts : CtfeLayoutInfoList] [ty : AstType]) : i64
  (match ty
    [(AstTyI64) 8]
    [(AstTyU64) 8]
    [(AstTyF64) 8]
    [(AstTyI32) 4]
    [(AstTyU32) 4]
    [(AstTyF32) 4]
    [(AstTyI16) 2]
    [(AstTyU16) 2]
    [(AstTyI8) 1]
    [(AstTyU8) 1]
    [(AstTyBool) 1]
    [(AstTyChar) 1]
    [(AstTyUnit) 0]
    [(AstTyNever) 0]
    [(AstTyStr) -1]
    [(AstTyExpr) -1]
    [(AstTyExprList) -1]
    [(AstTyFunc _ _) 8]
    [(AstTyTuple _) 8]
    [(AstTyArray elem count)
      (let
        [elem-size : i64 (ctfe-type-size layouts (ty-node-get elem))]
        (if (< elem-size 0)
          -1
          (* elem-size count)))]
    [(AstTyDynArray _) 8]
    [(AstTyBox _) 8]
    [(AstTyPtr _) 8]
    [(AstTyMutPtr _) 8]
    [(AstTyRef _ _) 8]
    [(AstTyMutRef _ _) 8]
    [(AstTyRegion _ inner) (ctfe-type-size layouts (ty-node-get inner))]
    [(AstTyEnum _) 8]
    [(AstTyEnumArgs _ _) 8]
    [(AstTyStruct name)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ size _ _) size])]
        [(CtfeNoLayoutInfo) 8])]
    [(AstTyStructArgs name _)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ size _ _) size])]
        [(CtfeNoLayoutInfo) 8])]
    [(AstTyString) 8]
    [(AstTyVar name)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ size _ _) size])]
        [(CtfeNoLayoutInfo) -1])]
    [(AstTyVarArgs name _)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ size _ _) size])]
        [(CtfeNoLayoutInfo) -1])]))

(define (ctfe-type-align [layouts : CtfeLayoutInfoList] [ty : AstType]) : i64
  (match ty
    [(AstTyI64) 8]
    [(AstTyU64) 8]
    [(AstTyF64) 8]
    [(AstTyI32) 4]
    [(AstTyU32) 4]
    [(AstTyF32) 4]
    [(AstTyI16) 2]
    [(AstTyU16) 2]
    [(AstTyI8) 1]
    [(AstTyU8) 1]
    [(AstTyBool) 1]
    [(AstTyChar) 1]
    [(AstTyUnit) 1]
    [(AstTyNever) 1]
    [(AstTyStr) -1]
    [(AstTyExpr) -1]
    [(AstTyExprList) -1]
    [(AstTyFunc _ _) 8]
    [(AstTyTuple _) 8]
    [(AstTyArray elem _) (ctfe-type-align layouts (ty-node-get elem))]
    [(AstTyDynArray _) 8]
    [(AstTyBox _) 8]
    [(AstTyPtr _) 8]
    [(AstTyMutPtr _) 8]
    [(AstTyRef _ _) 8]
    [(AstTyMutRef _ _) 8]
    [(AstTyRegion _ inner) (ctfe-type-align layouts (ty-node-get inner))]
    [(AstTyEnum _) 8]
    [(AstTyEnumArgs _ _) 8]
    [(AstTyStruct name)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ _ align _) align])]
        [(CtfeNoLayoutInfo) 8])]
    [(AstTyStructArgs name _)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ _ align _) align])]
        [(CtfeNoLayoutInfo) 8])]
    [(AstTyString) 8]
    [(AstTyVar name)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ _ align _) align])]
        [(CtfeNoLayoutInfo) -1])]
    [(AstTyVarArgs name _)
      (match (ctfe-layout-info-lookup layouts (intern-str name))
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ _ align _) align])]
        [(CtfeNoLayoutInfo) -1])]))

(define (ctfe-layout-query-value
  [name : String]
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : i64
  (if (string-eq name "size-of")
    (ctfe-type-size layouts ty)
    (ctfe-type-align layouts ty)))

;; Evaluate `(size-of (type T))` / `(align-of (type T))` to an `i64` in comptime.
(define (ctfe-eval-size-align-query
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(ErrCtfe d) (ErrCtfe d)]
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeType ty)
                    (let
                      [answer : i64
                        (ctfe-layout-query-value name (ctfe-env-layouts env) ty)]
                      (if (< answer 0)
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            (string-append
                              name
                              " expects a known type argument")))
                        (OkCtfe (CtfeI64 answer) arg-fuel)))]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr
                        expr
                        (string-append name " expects a type argument")))])])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                (string-append name " expects exactly one type argument")))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string-append name " expects exactly one type argument")))]))

(define (ctfe-offset-field-name [expr : AstExpr]) : CtfeMaybeFieldName
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (ctfe-offset-field-name inner))]
    [(AstExprVar name) (CtfeSomeFieldName (intern-str name))]
    [_ (CtfeNoFieldName)]))

(define (ctfe-layout-info-for-type
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : CtfeMaybeLayoutInfo
  (match ty
    [(AstTyStruct name) (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstTyStructArgs name _)
      (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstTyEnum name) (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstTyEnumArgs name _) (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstTyVar name) (ctfe-layout-info-lookup layouts (intern-str name))]
    [(AstTyRegion _ inner)
      (ctfe-layout-info-for-type layouts (ty-node-get inner))]
    [_ (CtfeNoLayoutInfo)]))

;; Evaluate `(offset-of (type Struct) field)` to the field byte offset.
;; The field name is intentionally syntactic: a bare variable names the field
;; and is not resolved as a runtime/comptime variable.
(define (ctfe-eval-offset-from-layout
  [field-name : String]
  [info : CtfeLayoutInfo]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match info
    [(CtfeLayoutInfo _ repr-c? _ _ fields)
      (if repr-c?
        (let
          [offset : i64 (ctfe-layout-field-offset fields field-name)]
          (if (< offset 0)
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                (string-append "offset-of unknown field " field-name)))
            (OkCtfe (CtfeI64 offset) fuel)))
        (ErrCtfe
          (ctfe-diagnostic-at-expr expr "offset-of requires struct layout type")))]))

(define (ctfe-eval-offset-from-type
  [ty : AstType]
  [field-name : String]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (ctfe-layout-info-for-type (ctfe-env-layouts env) ty)
    [(CtfeSomeLayoutInfo info)
      (ctfe-eval-offset-from-layout field-name info expr fuel)]
    [(CtfeNoLayoutInfo)
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "offset-of requires struct layout type"))]))

(define (ctfe-eval-offset-value
  [value : CompilerCtfeValue]
  [field-arg : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match value
    [(CtfeType ty)
      (match (ctfe-offset-field-name field-arg)
        [(CtfeSomeFieldName field-name)
          (ctfe-eval-offset-from-type ty field-name expr env fuel)]
        [(CtfeNoFieldName)
          (ErrCtfe
            (ctfe-diagnostic-at-expr expr "offset-of expects a field name"))])]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "offset-of expects a type argument"))]))

(define (ctfe-eval-offset-query
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg tail)
      (let
        [type-arg : AstExpr (ast-node-get type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons field-arg rest)
            (let
              [field-arg : AstExpr (ast-node-get field-arg)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (compiler-ctfe-eval type-arg env fuel)
                    [(ErrCtfe d) (ErrCtfe d)]
                    [(OkCtfe value arg-fuel)
                      (ctfe-eval-offset-value value field-arg expr env arg-fuel)])]
                [_
                  (ErrCtfe
                    (ctfe-diagnostic-at-expr
                      expr
                      "offset-of expects exactly one type argument and one field name"))]))]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                "offset-of expects exactly one type argument and one field name"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "offset-of expects exactly one type argument and one field name"))]))

(define (ctfe-reflection-query-name? [name : String]) : bool
  (core/cond
    (string-eq name "type-kind")
    true
    (string-eq name "type-key")
    true
    (string-eq name "type-nominal-module")
    true
    (string-eq name "type-nominal-name")
    true
    (string-eq name "struct-field-count")
    true
    (string-eq name "struct-field-name")
    true
    (string-eq name "struct-field-type")
    true
    (string-eq name "enum-variant-count")
    true
    (string-eq name "enum-variant-name")
    true
    (string-eq name "enum-variant-payload-count")
    true
    (string-eq name "enum-variant-payload-type")
    true
    (string-eq name "array-element-type")
    true
    (string-eq name "array-length")
    true
    (string-eq name "array-dynamic?")
    true
    (string-eq name "function-param-count")
    true
    (string-eq name "function-param-type")
    true
    (string-eq name "function-return-type")))

(define (ctfe-eval-one-type-reflection
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg rest)
      (let
        [type-arg : AstExpr (ast-node-get type-arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (ctfe-eval-type-arg type-arg expr env fuel name)
              [(ErrCtfeTypeArg d) (ErrCtfe d)]
              [(OkCtfeTypeArg ty arg-fuel)
                (let
                  [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
                  (core/cond
                    (string-eq name "type-kind")
                    (OkCtfe
                      (CtfeString (ctfe-type-kind-with-reflections infos ty))
                      arg-fuel)
                    (string-eq name "type-key")
                    (OkCtfe
                      (CtfeString (ctfe-type-key-with-reflections infos ty))
                      arg-fuel)
                    (string-eq name "type-nominal-module")
                    (match (ctfe-reflect-info-lookup
                      infos
                      (ctfe-type-nominal-key ty))
                      [(CtfeSomeReflectInfo info)
                        (match info
                          [(CtfeReflectStruct _ module _ _)
                            (OkCtfe (CtfeString module) arg-fuel)]
                          [(CtfeReflectEnum _ module _ _)
                            (OkCtfe (CtfeString module) arg-fuel)])]
                      [(CtfeNoReflectInfo)
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "type-nominal-module requires struct or enum type"))])
                    (string-eq name "type-nominal-name")
                    (match (ctfe-reflect-info-lookup
                      infos
                      (ctfe-type-nominal-key ty))
                      [(CtfeSomeReflectInfo info)
                        (match info
                          [(CtfeReflectStruct _ _ nominal-name _)
                            (OkCtfe (CtfeString nominal-name) arg-fuel)]
                          [(CtfeReflectEnum _ _ nominal-name _)
                            (OkCtfe (CtfeString nominal-name) arg-fuel)])]
                      [(CtfeNoReflectInfo)
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "type-nominal-name requires struct or enum type"))])
                    (string-eq name "struct-field-count")
                    (match (ctfe-reflect-info-lookup
                      infos
                      (ctfe-type-nominal-key ty))
                      [(CtfeSomeReflectInfo info)
                        (match info
                          [(CtfeReflectStruct _ _ _ fields)
                            (OkCtfe
                              (CtfeI64 (ctfe-reflect-field-list-count fields))
                              arg-fuel)]
                          [_
                            (ErrCtfe
                              (ctfe-diagnostic-at-expr
                                expr
                                "struct-field-count requires struct type"))])]
                      [(CtfeNoReflectInfo)
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "struct-field-count requires struct type"))])
                    (string-eq name "enum-variant-count")
                    (match (ctfe-reflect-info-lookup
                      infos
                      (ctfe-type-nominal-key ty))
                      [(CtfeSomeReflectInfo info)
                        (match info
                          [(CtfeReflectEnum _ _ _ variants)
                            (OkCtfe
                              (CtfeI64
                                (ctfe-reflect-variant-list-count variants))
                              arg-fuel)]
                          [_
                            (ErrCtfe
                              (ctfe-diagnostic-at-expr
                                expr
                                "enum-variant-count requires enum type"))])]
                      [(CtfeNoReflectInfo)
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "enum-variant-count requires enum type"))])
                    (string-eq name "array-element-type")
                    (match ty
                      [(AstTyArray elem _)
                        (OkCtfe (CtfeType (ty-node-get elem)) arg-fuel)]
                      [(AstTyDynArray elem)
                        (OkCtfe (CtfeType (ty-node-get elem)) arg-fuel)]
                      [_
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "array-element-type requires array type"))])
                    (string-eq name "array-length")
                    (match ty
                      [(AstTyArray _ count) (OkCtfe (CtfeI64 count) arg-fuel)]
                      [_
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "array-length requires fixed array type"))])
                    (string-eq name "array-dynamic?")
                    (match ty
                      [(AstTyArray _ _) (OkCtfe (CtfeBool false) arg-fuel)]
                      [(AstTyDynArray _) (OkCtfe (CtfeBool true) arg-fuel)]
                      [_
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "array-dynamic? requires array type"))])
                    (string-eq name "function-param-count")
                    (match ty
                      [(AstTyFunc params _)
                        (OkCtfe
                          (CtfeI64 (ctfe-type-list-count params))
                          arg-fuel)]
                      [_
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "function-param-count requires function type"))])
                    (string-eq name "function-return-type")
                    (match ty
                      [(AstTyFunc _ ret)
                        (OkCtfe (CtfeType (ty-node-get ret)) arg-fuel)]
                      [_
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "function-return-type requires function type"))])
                    (ctfe-unsupported-form expr)))])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                (string-append name " expects exactly one type argument")))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string-append name " expects exactly one type argument")))]))

(define (ctfe-type-nominal-key [ty : AstType]) : String
  (match ty
    [(AstTyStruct name) (intern-str name)]
    [(AstTyStructArgs name _) (intern-str name)]
    [(AstTyEnum name) (intern-str name)]
    [(AstTyEnumArgs name _) (intern-str name)]
    [(AstTyVar name) (intern-str name)]
    [(AstTyVarArgs name _) (intern-str name)]
    [_ ""]))

(define (ctfe-struct-field-arity-error [name : String] [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr
      expr
      (string-append name " expects exactly one type argument and one index"))))

(define (ctfe-struct-field-kind-error [name : String] [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr expr (string-append name " requires struct type"))))

(define (ctfe-eval-struct-field-from-fields
  [name : String]
  [fields : CtfeReflectFieldList]
  [infos : CtfeReflectInfoList]
  [index : i64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (string-eq name "struct-field-name")
    (match (ctfe-reflect-field-name-at fields index)
      [(OkCtfeStringLookup field-name) (OkCtfe (CtfeString field-name) fuel)]
      [(ErrCtfeStringLookup message)
        (ErrCtfe
          (ctfe-diagnostic-at-expr
            expr
            (string-append name (string-append " " message))))])
    (match (ctfe-reflect-field-type-at fields infos index)
      [(OkCtfeTypeLookup field-ty) (OkCtfe (CtfeType field-ty) fuel)]
      [(ErrCtfeTypeLookup message)
        (ErrCtfe
          (ctfe-diagnostic-at-expr
            expr
            (string-append name (string-append " " message))))])))

(define (ctfe-eval-struct-field-from-type
  [name : String]
  [ty : AstType]
  [index : i64]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (let
    [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
    (match (ctfe-reflect-info-lookup infos (ctfe-type-nominal-key ty))
      [(CtfeSomeReflectInfo info)
        (match info
          [(CtfeReflectStruct _ _ _ fields)
            (ctfe-eval-struct-field-from-fields
              name
              fields
              infos
              index
              expr
              fuel)]
          [_ (ctfe-struct-field-kind-error name expr)])]
      [(CtfeNoReflectInfo) (ctfe-struct-field-kind-error name expr)])))

(define (ctfe-eval-struct-field-reflection
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg tail)
      (let
        [type-arg : AstExpr (ast-node-get type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons index-arg rest)
            (let
              [index-arg : AstExpr (ast-node-get index-arg)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (ctfe-eval-type-arg type-arg expr env fuel name)
                    [(ErrCtfeTypeArg d) (ErrCtfe d)]
                    [(OkCtfeTypeArg ty type-fuel)
                      (match (ctfe-eval-i64-arg
                        index-arg
                        expr
                        env
                        type-fuel
                        name)
                        [(ErrCtfeI64Arg d) (ErrCtfe d)]
                        [(OkCtfeI64Arg index index-fuel)
                          (ctfe-eval-struct-field-from-type
                            name
                            ty
                            index
                            expr
                            env
                            index-fuel)])])]
                [_ (ctfe-struct-field-arity-error name expr)]))]
          [_ (ctfe-struct-field-arity-error name expr)]))]
    [_ (ctfe-struct-field-arity-error name expr)]))

(define (ctfe-enum-variant-arity-error [name : String] [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr
      expr
      (string-append name " expects exactly one type argument and one index"))))

(define (ctfe-enum-variant-kind-error [name : String] [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr expr (string-append name " requires enum type"))))

(define (ctfe-eval-enum-variant-from-variants
  [name : String]
  [variants : CtfeReflectVariantList]
  [index : i64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (if (string-eq name "enum-variant-name")
    (match (ctfe-reflect-variant-name-at variants index)
      [(OkCtfeStringLookup variant-name)
        (OkCtfe (CtfeString variant-name) fuel)]
      [(ErrCtfeStringLookup message)
        (ErrCtfe
          (ctfe-diagnostic-at-expr
            expr
            (string-append name (string-append " " message))))])
    (match (ctfe-reflect-variant-payloads-at variants index)
      [(OkCtfeTypeListLookup payloads)
        (OkCtfe (CtfeI64 (ctfe-type-list-count payloads)) fuel)]
      [(ErrCtfeTypeListLookup message)
        (ErrCtfe
          (ctfe-diagnostic-at-expr
            expr
            (string-append name (string-append " " message))))])))

(define (ctfe-eval-enum-variant-from-type
  [name : String]
  [ty : AstType]
  [index : i64]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (let
    [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
    (match (ctfe-reflect-info-lookup infos (ctfe-type-nominal-key ty))
      [(CtfeSomeReflectInfo info)
        (match info
          [(CtfeReflectEnum _ _ _ variants)
            (ctfe-eval-enum-variant-from-variants name variants index expr fuel)]
          [_ (ctfe-enum-variant-kind-error name expr)])]
      [(CtfeNoReflectInfo) (ctfe-enum-variant-kind-error name expr)])))

(define (ctfe-eval-enum-variant-reflection
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg tail)
      (let
        [type-arg : AstExpr (ast-node-get type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons index-arg rest)
            (let
              [index-arg : AstExpr (ast-node-get index-arg)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (ctfe-eval-type-arg type-arg expr env fuel name)
                    [(ErrCtfeTypeArg d) (ErrCtfe d)]
                    [(OkCtfeTypeArg ty type-fuel)
                      (match (ctfe-eval-i64-arg
                        index-arg
                        expr
                        env
                        type-fuel
                        name)
                        [(ErrCtfeI64Arg d) (ErrCtfe d)]
                        [(OkCtfeI64Arg index index-fuel)
                          (ctfe-eval-enum-variant-from-type
                            name
                            ty
                            index
                            expr
                            env
                            index-fuel)])])]
                [_ (ctfe-enum-variant-arity-error name expr)]))]
          [_ (ctfe-enum-variant-arity-error name expr)]))]
    [_ (ctfe-enum-variant-arity-error name expr)]))

(define (ctfe-enum-payload-type-arity-error [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr
      expr
      "enum-variant-payload-type expects exactly one type argument, one variant index, and one payload index")))

(define (ctfe-enum-payload-type-kind-error [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr
      expr
      "enum-variant-payload-type requires enum type")))

(define (ctfe-eval-enum-payload-type-from-variants
  [variants : CtfeReflectVariantList]
  [infos : CtfeReflectInfoList]
  [variant-index : i64]
  [payload-index : i64]
  [expr : AstExpr]
  [fuel : i64]) : ResultCtfe
  (match (ctfe-reflect-variant-payloads-at variants variant-index)
    [(OkCtfeTypeListLookup payloads)
      (match (ctfe-type-list-ref payloads infos payload-index)
        [(OkCtfeTypeLookup payload-ty) (OkCtfe (CtfeType payload-ty) fuel)]
        [(ErrCtfeTypeLookup message)
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              (string-append "enum-variant-payload-type " message)))])]
    [(ErrCtfeTypeListLookup message)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string-append "enum-variant-payload-type " message)))]))

(define (ctfe-eval-enum-payload-type-from-type
  [ty : AstType]
  [variant-index : i64]
  [payload-index : i64]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (let
    [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
    (match (ctfe-reflect-info-lookup infos (ctfe-type-nominal-key ty))
      [(CtfeSomeReflectInfo info)
        (match info
          [(CtfeReflectEnum _ _ _ variants)
            (ctfe-eval-enum-payload-type-from-variants
              variants
              infos
              variant-index
              payload-index
              expr
              fuel)]
          [_ (ctfe-enum-payload-type-kind-error expr)])]
      [(CtfeNoReflectInfo) (ctfe-enum-payload-type-kind-error expr)])))

(define (ctfe-eval-enum-payload-type-reflection
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg tail)
      (let
        [type-arg : AstExpr (ast-node-get type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons variant-arg rest1)
            (let
              [variant-arg : AstExpr (ast-node-get variant-arg)]
              [rest1 : AstExprList (box-get rest1)]
              (match rest1
                [(AstExprCons payload-arg rest2)
                  (let
                    [payload-arg : AstExpr (ast-node-get payload-arg)]
                    [rest2 : AstExprList (box-get rest2)]
                    (match rest2
                      [(AstExprNil)
                        (match (ctfe-eval-type-arg
                          type-arg
                          expr
                          env
                          fuel
                          "enum-variant-payload-type")
                          [(ErrCtfeTypeArg d) (ErrCtfe d)]
                          [(OkCtfeTypeArg ty type-fuel)
                            (match (ctfe-eval-i64-arg
                              variant-arg
                              expr
                              env
                              type-fuel
                              "enum-variant-payload-type")
                              [(ErrCtfeI64Arg d) (ErrCtfe d)]
                              [(OkCtfeI64Arg variant-index variant-fuel)
                                (match (ctfe-eval-i64-arg
                                  payload-arg
                                  expr
                                  env
                                  variant-fuel
                                  "enum-variant-payload-type")
                                  [(ErrCtfeI64Arg d) (ErrCtfe d)]
                                  [(OkCtfeI64Arg payload-index payload-fuel)
                                    (ctfe-eval-enum-payload-type-from-type
                                      ty
                                      variant-index
                                      payload-index
                                      expr
                                      env
                                      payload-fuel)])])])]
                      [_ (ctfe-enum-payload-type-arity-error expr)]))]
                [_ (ctfe-enum-payload-type-arity-error expr)]))]
          [_ (ctfe-enum-payload-type-arity-error expr)]))]
    [_ (ctfe-enum-payload-type-arity-error expr)]))

(define (ctfe-eval-function-param-type-reflection
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg tail)
      (let
        [type-arg : AstExpr (ast-node-get type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons index-arg rest)
            (let
              [index-arg : AstExpr (ast-node-get index-arg)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (ctfe-eval-type-arg
                    type-arg
                    expr
                    env
                    fuel
                    "function-param-type")
                    [(ErrCtfeTypeArg d) (ErrCtfe d)]
                    [(OkCtfeTypeArg ty type-fuel)
                      (match (ctfe-eval-i64-arg
                        index-arg
                        expr
                        env
                        type-fuel
                        "function-param-type")
                        [(ErrCtfeI64Arg d) (ErrCtfe d)]
                        [(OkCtfeI64Arg index index-fuel)
                          (match ty
                            [(AstTyFunc params _)
                              (match (ctfe-type-list-ref
                                params
                                (ctfe-env-reflections env)
                                index)
                                [(OkCtfeTypeLookup param-ty)
                                  (OkCtfe (CtfeType param-ty) index-fuel)]
                                [(ErrCtfeTypeLookup message)
                                  (ErrCtfe
                                    (ctfe-diagnostic-at-expr
                                      expr
                                      (string-append
                                        "function-param-type "
                                        message)))])]
                            [_
                              (ErrCtfe
                                (ctfe-diagnostic-at-expr
                                  expr
                                  "function-param-type requires function type"))])])])]
                [_
                  (ErrCtfe
                    (ctfe-diagnostic-at-expr
                      expr
                      "function-param-type expects exactly one type argument and one index"))]))]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                "function-param-type expects exactly one type argument and one index"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "function-param-type expects exactly one type argument and one index"))]))

(define (ctfe-eval-reflection-query
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (core/cond
    (or
      (string-eq name "type-kind")
      (string-eq name "type-key")
      (string-eq name "type-nominal-module")
      (string-eq name "type-nominal-name")
      (string-eq name "struct-field-count")
      (string-eq name "enum-variant-count")
      (string-eq name "array-element-type")
      (string-eq name "array-length")
      (string-eq name "array-dynamic?")
      (string-eq name "function-param-count")
      (string-eq name "function-return-type"))
    (ctfe-eval-one-type-reflection name args expr env fuel)
    (or
      (string-eq name "struct-field-name")
      (string-eq name "struct-field-type"))
    (ctfe-eval-struct-field-reflection name args expr env fuel)
    (or
      (string-eq name "enum-variant-name")
      (string-eq name "enum-variant-payload-count"))
    (ctfe-eval-enum-variant-reflection name args expr env fuel)
    (string-eq name "enum-variant-payload-type")
    (ctfe-eval-enum-payload-type-reflection args expr env fuel)
    (string-eq name "function-param-type")
    (ctfe-eval-function-param-type-reflection args expr env fuel)
    (ctfe-unsupported-form expr)))

(define (ctfe-eval-string-eq-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons left tail)
      (let
        [left : AstExpr (ast-node-get left)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons right rest)
            (let
              [right : AstExpr (ast-node-get right)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (ctfe-eval-string-arg left expr env fuel name)
                    [(ErrCtfeStringArg d) (ErrCtfe d)]
                    [(OkCtfeStringArg l left-fuel)
                      (match (ctfe-eval-string-arg
                        right
                        expr
                        env
                        left-fuel
                        name)
                        [(ErrCtfeStringArg d) (ErrCtfe d)]
                        [(OkCtfeStringArg r right-fuel)
                          (OkCtfe (CtfeBool (string-eq l r)) right-fuel)])])]
                [_
                  (ErrCtfe
                    (ctfe-diagnostic-at-expr
                      expr
                      "string-eq expects two strings"))]))]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "string-eq expects two strings"))]))]
    [_ (ErrCtfe (ctfe-diagnostic-at-expr expr "string-eq expects two strings"))]))

(define (ctfe-eval-string-append-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons left tail)
      (let
        [left : AstExpr (ast-node-get left)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons right rest)
            (let
              [right : AstExpr (ast-node-get right)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (ctfe-eval-string-arg left expr env fuel name)
                    [(ErrCtfeStringArg d) (ErrCtfe d)]
                    [(OkCtfeStringArg l left-fuel)
                      (match (ctfe-eval-string-arg
                        right
                        expr
                        env
                        left-fuel
                        name)
                        [(ErrCtfeStringArg d) (ErrCtfe d)]
                        [(OkCtfeStringArg r right-fuel)
                          (OkCtfe (CtfeString (string-append l r)) right-fuel)])])]
                [_
                  (ErrCtfe
                    (ctfe-diagnostic-at-expr
                      expr
                      "string-append expects two strings"))]))]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "string-append expects two strings"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "string-append expects two strings"))]))

(define (ctfe-eval-string-length-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (ctfe-eval-string-arg arg expr env fuel name)
              [(ErrCtfeStringArg d) (ErrCtfe d)]
              [(OkCtfeStringArg text arg-fuel)
                (OkCtfe (CtfeI64 (string-length text)) arg-fuel)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "string-length expects one string"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "string-length expects one string"))]))

(define (ctfe-eval-int-to-string-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (ctfe-eval-i64-arg arg expr env fuel "int->string")
              [(ErrCtfeI64Arg d) (ErrCtfe d)]
              [(OkCtfeI64Arg n arg-fuel)
                (OkCtfe (CtfeString (int->string n)) arg-fuel)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "int->string expects one i64"))]))]
    [_ (ErrCtfe (ctfe-diagnostic-at-expr expr "int->string expects one i64"))]))

;; User-facing Expr constructors (#1135). They are CTFE-only builtins for macro
;; bodies: they build checked code fragments while carrying each fragment's
;; produced type internally.
(define (ctfe-eval-expr-bool-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeBool b)
                    (OkCtfe
                      (CtfeExpr
                        (ast-node-push (AstExprLiteral (AstLitBool b)))
                        (AstTyBool))
                      arg-fuel)]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr expr "expr-bool expects bool"))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "expr-bool expects exactly one arg"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "expr-bool expects exactly one arg"))]))

(define (ctfe-eval-expr-splice-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeExpr node ty) (OkCtfe (CtfeExpr node ty) arg-fuel)]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr expr "expr-splice expects Expr"))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                "expr-splice expects exactly one arg"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "expr-splice expects exactly one arg"))]))

;; `(expr-int n)` builds an i64 literal Expr from a comptime integer, letting a
;; macro splice a computed count or index as a literal (unquote requires an Expr,
;; so a bare i64 cannot be spliced directly).
(define (ctfe-eval-expr-int-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeI64 n)
                    (OkCtfe
                      (CtfeExpr
                        (ast-node-push (AstExprLiteral (AstLitInt n)))
                        (AstTyI64))
                      arg-fuel)]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr expr "expr-int expects i64"))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "expr-int expects exactly one arg"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "expr-int expects exactly one arg"))]))

;; `(expr-var name)` builds a variable-reference Expr from a comptime string.
(define (ctfe-eval-expr-var-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeString name)
                    (OkCtfe
                      (CtfeExpr (ctfe-expr-var name) (AstTyExpr))
                      arg-fuel)]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr expr "expr-var expects String"))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr expr "expr-var expects exactly one arg"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "expr-var expects exactly one arg"))]))

(define (ctfe-expr-inspector-name? [name : String]) : bool
  (or
    (string-eq name "expr-bool?")
    (string-eq name "expr-bool-value")
    (string-eq name "expr-if?")
    (string-eq name "expr-if-cond")
    (string-eq name "expr-if-then")
    (string-eq name "expr-if-else")))

(define (ctfe-expr-list-inspector-name? [name : String]) : bool
  (or
    (string-eq name "expr-list-empty?")
    (string-eq name "expr-list-length")
    (string-eq name "expr-list-head")
    (string-eq name "expr-list-tail")
    (string-eq name "expr-list-nth")))

(define (ctfe-expr-clause-inspector-name? [name : String]) : bool
  (or
    (string-eq name "expr-clause-first")
    (string-eq name "expr-clause-second")))

(define (ctfe-expr-clause-list-inspector-name? [name : String]) : bool
  (or
    (string-eq name "expr-clause-list-empty?")
    (string-eq name "expr-clause-list-length")
    (string-eq name "expr-clause-list-head")
    (string-eq name "expr-clause-list-tail")
    (string-eq name "expr-clause-list-nth")
    (string-eq name "expr-clause-list->expr-list")))

(define (ctfe-eval-expr-list-nth-call
  [list-arg : AstExpr]
  [index-arg : AstExpr]
  [rest : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match rest
    [(AstExprNil)
      (match (compiler-ctfe-eval list-arg env fuel)
        [(OkCtfe value list-fuel)
          (match value
            [(CtfeExprList nodes)
              (match (ctfe-eval-i64-arg
                index-arg
                expr
                env
                list-fuel
                "expr-list-nth")
                [(ErrCtfeI64Arg d) (ErrCtfe d)]
                [(OkCtfeI64Arg index index-fuel)
                  (if (or (< index 0) (>= index (ctfe-expr-list-length nodes)))
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr
                        expr
                        "expr-list-nth index out of range"))
                    (OkCtfe
                      (CtfeExpr (ctfe-expr-list-nth nodes index) (AstTyExpr))
                      index-fuel))])]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr expr "expr-list-nth expects ExprList"))])]
        [(ErrCtfe diag) (ErrCtfe diag)])]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "expr-list-nth expects exactly two args"))]))

(define (ctfe-eval-expr-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeExpr node ty)
                    (core/cond
                      (string-eq name "expr-bool?")
                      (OkCtfe (CtfeBool (ctfe-expr-bool? node)) arg-fuel)
                      (string-eq name "expr-bool-value")
                      (if (ctfe-expr-bool? node)
                        (OkCtfe (CtfeBool (ctfe-expr-bool-value node)) arg-fuel)
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-bool-value expects bool literal Expr")))
                      (string-eq name "expr-if?")
                      (OkCtfe (CtfeBool (ctfe-expr-if? node)) arg-fuel)
                      (ctfe-expr-if? node)
                      (core/cond
                        (string-eq name "expr-if-cond")
                        (OkCtfe
                          (CtfeExpr (ctfe-expr-if-cond node) (AstTyBool))
                          arg-fuel)
                        (string-eq name "expr-if-then")
                        (OkCtfe (CtfeExpr (ctfe-expr-if-then node) ty) arg-fuel)
                        (string-eq name "expr-if-else")
                        (OkCtfe (CtfeExpr (ctfe-expr-if-else node) ty) arg-fuel)
                        (ctfe-unsupported-form expr))
                      (ErrCtfe
                        (ctfe-diagnostic-at-expr
                          expr
                          (string-append name " expects if Expr"))))]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr
                        expr
                        (string-append name " expects Expr")))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                (string-append name " expects exactly one arg")))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string-append name " expects exactly one arg")))]))

(define (ctfe-eval-expr-list-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest : AstExprList (box-get rest)]
        (if (string-eq name "expr-list-nth")
          (match rest
            [(AstExprCons index-arg nth-rest)
              (ctfe-eval-expr-list-nth-call
                arg
                (ast-node-get index-arg)
                (box-get nth-rest)
                expr
                env
                fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "expr-list-nth expects exactly two args"))])
          (match rest
            [(AstExprNil)
              (match (compiler-ctfe-eval arg env fuel)
                [(OkCtfe value arg-fuel)
                  (match value
                    [(CtfeExprList nodes)
                      (core/cond
                        (string-eq name "expr-list-empty?")
                        (OkCtfe
                          (CtfeBool (ctfe-expr-list-empty? nodes))
                          arg-fuel)
                        (string-eq name "expr-list-length")
                        (OkCtfe
                          (CtfeI64 (ctfe-expr-list-length nodes))
                          arg-fuel)
                        (ctfe-expr-list-empty? nodes)
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            (string-append name " expects non-empty ExprList")))
                        (string-eq name "expr-list-head")
                        (OkCtfe
                          (CtfeExpr (ctfe-expr-list-head nodes) (AstTyExpr))
                          arg-fuel)
                        (string-eq name "expr-list-tail")
                        (OkCtfe
                          (CtfeExprList (ctfe-expr-list-tail nodes))
                          arg-fuel)
                        (ctfe-unsupported-form expr))]
                    [_
                      (ErrCtfe
                        (ctfe-diagnostic-at-expr
                          expr
                          (string-append name " expects ExprList")))])]
                [(ErrCtfe diag) (ErrCtfe diag)])]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  (string-append name " expects exactly one arg")))])))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string-append name " expects exactly one arg")))]))

(define (ctfe-eval-expr-clause-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeExprClause clause)
                    (core/cond
                      (string-eq name "expr-clause-first")
                      (OkCtfe
                        (CtfeExpr (ctfe-expr-clause-first clause) (AstTyExpr))
                        arg-fuel)
                      (string-eq name "expr-clause-second")
                      (OkCtfe
                        (CtfeExpr (ctfe-expr-clause-second clause) (AstTyExpr))
                        arg-fuel)
                      (ctfe-unsupported-form expr))]
                  [_
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr
                        expr
                        (string-append name " expects ExprClause")))])]
              [(ErrCtfe diag) (ErrCtfe diag)])]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                (string-append name " expects exactly one arg")))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string-append name " expects exactly one arg")))]))

(define (ctfe-eval-expr-clause-list-nth-call
  [list-arg : AstExpr]
  [index-arg : AstExpr]
  [rest : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match rest
    [(AstExprNil)
      (match (compiler-ctfe-eval list-arg env fuel)
        [(OkCtfe value list-fuel)
          (match value
            [(CtfeExprClauseList clauses)
              (match (ctfe-eval-i64-arg
                index-arg
                expr
                env
                list-fuel
                "expr-clause-list-nth")
                [(ErrCtfeI64Arg d) (ErrCtfe d)]
                [(OkCtfeI64Arg index index-fuel)
                  (if (or
                    (< index 0)
                    (>= index (ctfe-expr-clause-list-length clauses)))
                    (ErrCtfe
                      (ctfe-diagnostic-at-expr
                        expr
                        "expr-clause-list-nth index out of range"))
                    (OkCtfe
                      (CtfeExprClause (ctfe-expr-clause-list-nth clauses index))
                      index-fuel))])]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "expr-clause-list-nth expects ExprClauseList"))])]
        [(ErrCtfe diag) (ErrCtfe diag)])]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "expr-clause-list-nth expects exactly two args"))]))

(define (ctfe-eval-expr-clause-list-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest : AstExprList (box-get rest)]
        (if (string-eq name "expr-clause-list-nth")
          (match rest
            [(AstExprCons index-arg nth-rest)
              (ctfe-eval-expr-clause-list-nth-call
                arg
                (ast-node-get index-arg)
                (box-get nth-rest)
                expr
                env
                fuel)]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "expr-clause-list-nth expects exactly two args"))])
          (match rest
            [(AstExprNil)
              (match (compiler-ctfe-eval arg env fuel)
                [(OkCtfe value arg-fuel)
                  (match value
                    [(CtfeExprClauseList clauses)
                      (core/cond
                        (string-eq name "expr-clause-list-empty?")
                        (OkCtfe
                          (CtfeBool (ctfe-expr-clause-list-empty? clauses))
                          arg-fuel)
                        (string-eq name "expr-clause-list-length")
                        (OkCtfe
                          (CtfeI64 (ctfe-expr-clause-list-length clauses))
                          arg-fuel)
                        (string-eq name "expr-clause-list->expr-list")
                        (OkCtfe
                          (CtfeExprList
                            (ctfe-expr-clause-list->expr-list clauses))
                          arg-fuel)
                        (ctfe-expr-clause-list-empty? clauses)
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            (string-append
                              name
                              " expects non-empty ExprClauseList")))
                        (string-eq name "expr-clause-list-head")
                        (OkCtfe
                          (CtfeExprClause (ctfe-expr-clause-list-head clauses))
                          arg-fuel)
                        (string-eq name "expr-clause-list-tail")
                        (OkCtfe
                          (CtfeExprClauseList
                            (ctfe-expr-clause-list-tail clauses))
                          arg-fuel)
                        (ctfe-unsupported-form expr))]
                    [_
                      (ErrCtfe
                        (ctfe-diagnostic-at-expr
                          expr
                          (string-append name " expects ExprClauseList")))])]
                [(ErrCtfe diag) (ErrCtfe diag)])]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  (string-append name " expects exactly one arg")))])))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string-append name " expects exactly one arg")))]))

(define (ctfe-eval-expr-if-call
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons cond-arg tail1)
      (let
        [cond-arg : AstExpr (ast-node-get cond-arg)]
        [tail1 : AstExprList (box-get tail1)]
        (match tail1
          [(AstExprCons then-arg tail2)
            (let
              [then-arg : AstExpr (ast-node-get then-arg)]
              [tail2 : AstExprList (box-get tail2)]
              (match tail2
                [(AstExprCons else-arg rest)
                  (let
                    [else-arg : AstExpr (ast-node-get else-arg)]
                    [rest : AstExprList (box-get rest)]
                    (match rest
                      [(AstExprNil)
                        (match (compiler-ctfe-eval cond-arg env fuel)
                          [(OkCtfe cond-val cond-fuel)
                            (match cond-val
                              [(CtfeExpr cond-node cond-ty)
                                (if (ctfe-type-eq cond-ty (AstTyBool))
                                  (match (compiler-ctfe-eval
                                    then-arg
                                    env
                                    cond-fuel)
                                    [(OkCtfe then-val then-fuel)
                                      (match then-val
                                        [(CtfeExpr then-node then-ty)
                                          (match (compiler-ctfe-eval
                                            else-arg
                                            env
                                            then-fuel)
                                            [(OkCtfe else-val else-fuel)
                                              (match else-val
                                                [(CtfeExpr else-node else-ty)
                                                  (if (ctfe-type-eq
                                                    then-ty
                                                    else-ty)
                                                    (OkCtfe
                                                      (CtfeExpr
                                                        (ast-expr-if
                                                          cond-node
                                                          then-node
                                                          else-node)
                                                        then-ty)
                                                      else-fuel)
                                                    (ErrCtfe
                                                      (ctfe-diagnostic-at-expr
                                                        expr
                                                        "expr-if branch types must match")))]
                                                [_
                                                  (ErrCtfe
                                                    (ctfe-diagnostic-at-expr
                                                      expr
                                                      "expr-if else branch expects Expr"))])]
                                            [(ErrCtfe diag) (ErrCtfe diag)])]
                                        [_
                                          (ErrCtfe
                                            (ctfe-diagnostic-at-expr
                                              expr
                                              "expr-if then branch expects Expr"))])]
                                    [(ErrCtfe diag) (ErrCtfe diag)])
                                  (ErrCtfe
                                    (ctfe-diagnostic-at-expr
                                      expr
                                      "expr-if condition must produce bool")))]
                              [_
                                (ErrCtfe
                                  (ctfe-diagnostic-at-expr
                                    expr
                                    "expr-if condition expects Expr"))])]
                          [(ErrCtfe diag) (ErrCtfe diag)])]
                      [_
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-if expects exactly three args"))]))]
                [_
                  (ErrCtfe
                    (ctfe-diagnostic-at-expr
                      expr
                      "expr-if expects exactly three args"))]))]
          [_
            (ErrCtfe
              (ctfe-diagnostic-at-expr
                expr
                "expr-if expects exactly three args"))]))]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr expr "expr-if expects exactly three args"))]))

;; Dispatch a comptime call. Layout and reflection queries are compile-time-only
;; compiler metadata; selected String and Expr helpers make that metadata usable
;; in generator decisions without lowering it as runtime values.
(define (ctfe-eval-call
  [func : AstExpr]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match func
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (ctfe-eval-call inner args expr env fuel))]
    [(AstExprVar name)
      (core/cond
        (or
          (string-eq (intern-str name) "size-of")
          (string-eq (intern-str name) "align-of"))
        (ctfe-eval-size-align-query (intern-str name) args expr env fuel)
        (string-eq (intern-str name) "offset-of")
        (ctfe-eval-offset-query args expr env fuel)
        (ctfe-reflection-query-name? (intern-str name))
        (ctfe-eval-reflection-query (intern-str name) args expr env fuel)
        (or
          (string-eq (intern-str name) "string-eq")
          (string-eq (intern-str name) "string=?"))
        (ctfe-eval-string-eq-call (intern-str name) args expr env fuel)
        (or
          (string-eq (intern-str name) "string-append")
          (string-eq (intern-str name) "string-concat"))
        (ctfe-eval-string-append-call (intern-str name) args expr env fuel)
        (or
          (string-eq (intern-str name) "string-length")
          (string-eq (intern-str name) "length"))
        (ctfe-eval-string-length-call (intern-str name) args expr env fuel)
        (string-eq (intern-str name) "int->string")
        (ctfe-eval-int-to-string-call args expr env fuel)
        (string-eq (intern-str name) "expr-bool")
        (ctfe-eval-expr-bool-call args expr env fuel)
        (string-eq (intern-str name) "expr-int")
        (ctfe-eval-expr-int-call args expr env fuel)
        (string-eq (intern-str name) "expr-var")
        (ctfe-eval-expr-var-call args expr env fuel)
        (string-eq (intern-str name) "expr-splice")
        (ctfe-eval-expr-splice-call args expr env fuel)
        (string-eq (intern-str name) "expr-if")
        (ctfe-eval-expr-if-call args expr env fuel)
        (ctfe-expr-inspector-name? (intern-str name))
        (ctfe-eval-expr-inspector-call (intern-str name) args expr env fuel)
        (ctfe-expr-list-inspector-name? (intern-str name))
        (ctfe-eval-expr-list-inspector-call
          (intern-str name)
          args
          expr
          env
          fuel)
        (ctfe-expr-clause-inspector-name? (intern-str name))
        (ctfe-eval-expr-clause-inspector-call
          (intern-str name)
          args
          expr
          env
          fuel)
        (ctfe-expr-clause-list-inspector-name? (intern-str name))
        (ctfe-eval-expr-clause-list-inspector-call
          (intern-str name)
          args
          expr
          env
          fuel)
        (ctfe-unsupported-form expr))]
    [_ (ctfe-unsupported-form expr)]))

;; Shared "unsupported compile-time form" diagnostic for ordinary calls.
(define (ctfe-unsupported-form [expr : AstExpr]) : ResultCtfe
  (ErrCtfe
    (ctfe-diagnostic-at-expr
      expr
      (string-append
        "'"
        (string-append
          (ctfe-describe-expr expr)
          "' is not supported in compile-time evaluation")))))

(define (ctfe-eval-var
  [name : String]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (ctfe-env-lookup env name)
    [(CtfeSomeValue value) (OkCtfe value fuel)]
    [(CtfeNoValue)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string-append
            "compile-time evaluation cannot reference runtime variable '"
            (string-append name "'"))))]))

(define (ctfe-eval-binary
  [op : AstBinOp]
  [left : AstExpr]
  [right : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval left env fuel)
    [(OkCtfe lv left-fuel)
      (match (compiler-ctfe-eval right env left-fuel)
        [(OkCtfe rv right-fuel) (ctfe-apply-binop op lv rv expr right-fuel)]
        [(ErrCtfe diag) (ErrCtfe diag)])]
    [(ErrCtfe diag) (ErrCtfe diag)]))

(define (ctfe-eval-unary
  [op : AstUnOp]
  [inner : AstExpr]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval inner env fuel)
    [(OkCtfe v inner-fuel) (ctfe-apply-unop op v expr inner-fuel)]
    [(ErrCtfe diag) (ErrCtfe diag)]))

(define (ctfe-eval-if
  [cond : AstExpr]
  [then-branch : AstExpr]
  [else-branch : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match (compiler-ctfe-eval cond env fuel)
    [(OkCtfe cond-value cond-fuel)
      (match cond-value
        [(CtfeBool b)
          (if b
            (compiler-ctfe-eval then-branch env cond-fuel)
            (compiler-ctfe-eval else-branch env cond-fuel))]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              cond
              "comptime 'if' condition must be bool"))])]
    [(ErrCtfe diag) (ErrCtfe diag)]))

;; Evaluate `let` bindings sequentially, threading both fuel and the extended
;; environment. The original `env` is preserved for siblings because each
;; binding extends a fresh copy threaded forward.
(define (ctfe-eval-let
  [bindings : AstLetBindingList]
  [body : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match bindings
    [(AstLetBindingNil) (compiler-ctfe-eval body env fuel)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name _ value-expr-box)
            (let
              [value-expr : AstExpr (ast-node-get value-expr-box)]
              (match (compiler-ctfe-eval value-expr env fuel)
                [(OkCtfe value value-fuel)
                  (ctfe-eval-let
                    rest
                    body
                    (ctfe-env-extend env (intern-str name) value)
                    value-fuel)]
                [(ErrCtfe diag) (ErrCtfe diag)]))]))]))

;; Evaluate a `begin` to the value of its last expression; an empty body is
;; unit.
(define (ctfe-eval-begin [exprs : AstExprList] [env : CtfeEnv] [fuel : i64]) : ResultCtfe
  (match exprs
    [(AstExprNil) (OkCtfe (CtfeUnit) fuel)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (match (compiler-ctfe-eval head env fuel)
          [(OkCtfe value head-fuel)
            (match rest
              [(AstExprNil) (OkCtfe value head-fuel)]
              [_ (ctfe-eval-begin rest env head-fuel)])]
          [(ErrCtfe diag) (ErrCtfe diag)]))]))

;; --- quote / quasiquote -----------------------------------------------------
(define (ctfe-quote-literal-type [lit : AstLiteral]) : AstType
  (match lit
    [(AstLitInt _) (AstTyI64)]
    [(AstLitFloat _) (AstTyF64)]
    [(AstLitBool _) (AstTyBool)]
    [(AstLitChar _) (AstTyChar)]
    [(AstLitString _) (AstTyString)]
    [(AstLitUnit) (AstTyUnit)]))

(define (ctfe-expr-list-append [left : AstExprList] [right : AstExprList]) : AstExprList
  (match left
    [(AstExprNil) right]
    [(AstExprCons head rest)
      (let
        [rest-list : AstExprList (box-get rest)]
        (ast-expr-cons head (ctfe-expr-list-append rest-list right)))]))

(define (ctfe-quote-if-type
  [cond-ty : AstType]
  [then-ty : AstType]
  [else-ty : AstType]) : AstType
  (if (and (ctfe-type-eq cond-ty (AstTyBool)) (ctfe-type-eq then-ty else-ty))
    then-ty
    (AstTyExpr)))

(define (ctfe-eval-unquote-expr
  [inner : AstExpr]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteExpr
  (match (compiler-ctfe-eval inner env fuel)
    [(OkCtfe value next-fuel)
      (match value
        [(CtfeExpr node ty) (OkCtfeQuoteExpr node ty next-fuel)]
        [_
          (ErrCtfeQuoteExpr
            (ctfe-diagnostic-at-expr origin "unquote expects Expr"))])]
    [(ErrCtfe diag) (ErrCtfeQuoteExpr diag)]))

(define (ctfe-eval-unquote-splice
  [inner : AstExpr]
  [origin : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfeQuoteExprList
  (match (compiler-ctfe-eval inner env fuel)
    [(OkCtfe value next-fuel)
      (match value
        [(CtfeExprList exprs) (OkCtfeQuoteExprList exprs next-fuel)]
        [_
          (ErrCtfeQuoteExprList
            (ctfe-diagnostic-at-expr origin "unquote-splicing expects ExprList"))])]
    [(ErrCtfe diag) (ErrCtfeQuoteExprList diag)]))

(define (ctfe-quote-expr-list
  [exprs : AstExprList]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteExprList
  (match exprs
    [(AstExprNil) (OkCtfeQuoteExprList AstExprNil fuel)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (ast-node-get head)]
        [rest : AstExprList (box-get rest)]
        (match (ast-expr-unspan head)
          [(AstExprUnquoteSplicing inner-box)
            (let
              [inner : AstExpr (ast-node-get inner-box)]
              (if quasiquote
                (match (ctfe-eval-unquote-splice inner head env fuel)
                  [(OkCtfeQuoteExprList splice splice-fuel)
                    (match (ctfe-quote-expr-list
                      rest
                      env
                      splice-fuel
                      quasiquote)
                      [(OkCtfeQuoteExprList quoted-rest rest-fuel)
                        (OkCtfeQuoteExprList
                          (ctfe-expr-list-append splice quoted-rest)
                          rest-fuel)]
                      [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExprList diag)])]
                  [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExprList diag)])
                (match (ctfe-quote-expr head env fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-head _ head-fuel)
                    (match (ctfe-quote-expr-list rest env head-fuel quasiquote)
                      [(OkCtfeQuoteExprList quoted-rest rest-fuel)
                        (OkCtfeQuoteExprList
                          (ast-expr-cons quoted-head quoted-rest)
                          rest-fuel)]
                      [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExprList diag)])]
                  [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExprList diag)])))]
          [_
            (match (ctfe-quote-expr head env fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-head _ head-fuel)
                (match (ctfe-quote-expr-list rest env head-fuel quasiquote)
                  [(OkCtfeQuoteExprList quoted-rest rest-fuel)
                    (OkCtfeQuoteExprList
                      (ast-expr-cons quoted-head quoted-rest)
                      rest-fuel)]
                  [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExprList diag)])]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExprList diag)])]))]))

(define (ctfe-quote-param-list [params : AstParamList] [env : CtfeEnv]) : AstParamList
  (match params
    [(AstParamNil) AstParamNil]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam name ty comptime?)
            (ast-param-cons
              (AstParam (ctfe-quote-name-id env name) ty comptime?)
              (ctfe-quote-param-list rest env))]))]))

(define (ctfe-quote-pattern-list [patterns : AstPatternList] [env : CtfeEnv]) : AstPatternList
  (match patterns
    [(AstPatternNil) AstPatternNil]
    [(AstPatternCons pattern rest)
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest : AstPatternList (box-get rest)]
        (ast-pattern-cons
          (ctfe-quote-pattern pattern env)
          (ctfe-quote-pattern-list rest env)))]))

(define (ctfe-quote-pattern [pattern : AstPattern] [env : CtfeEnv]) : AstPattern
  (match pattern
    [(AstPatVar name maybe-ty)
      (AstPatVar (ctfe-quote-name-id env name) maybe-ty)]
    [(AstPatTuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (ast-pat-tuple (ctfe-quote-pattern-list patterns env)))]
    [(AstPatWildcard) AstPatWildcard]
    [(AstPatBinding name) (AstPatBinding (ctfe-quote-name-id env name))]
    [(AstPatVariant name args-box)
      (let
        [args : AstPatternList (box-get args-box)]
        (ast-pat-variant-id name (ctfe-quote-pattern-list args env)))]
    [(AstPatLiteral lit) (AstPatLiteral lit)]))

(define (ctfe-quote-let-binding-list
  [bindings : AstLetBindingList]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteLetBindings
  (match bindings
    [(AstLetBindingNil) (OkCtfeQuoteLetBindings AstLetBindingNil fuel)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name maybe-ty init-box)
            (let
              [init : AstExpr (ast-node-get init-box)]
              (match (ctfe-quote-expr init env fuel quasiquote)
                [(OkCtfeQuoteExpr quoted-init _ init-fuel)
                  (match (ctfe-quote-let-binding-list
                    rest
                    env
                    init-fuel
                    quasiquote)
                    [(OkCtfeQuoteLetBindings quoted-rest rest-fuel)
                      (OkCtfeQuoteLetBindings
                        (ast-let-binding-cons
                          (ast-let-binding-id
                            (ctfe-quote-name-id env name)
                            maybe-ty
                            quoted-init)
                          quoted-rest)
                        rest-fuel)]
                    [(ErrCtfeQuoteLetBindings diag)
                      (ErrCtfeQuoteLetBindings diag)])]
                [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteLetBindings diag)]))]))]))

(define (ctfe-quote-resource-binding-list
  [bindings : AstResourceBindingList]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteResourceBindings
  (match bindings
    [(AstResourceBindingNil)
      (OkCtfeQuoteResourceBindings AstResourceBindingNil fuel)]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding name init-box cleanup-box)
            (let
              [init : AstExpr (ast-node-get init-box)]
              [cleanup : AstExpr (ast-node-get cleanup-box)]
              (match (ctfe-quote-expr init env fuel quasiquote)
                [(OkCtfeQuoteExpr quoted-init _ init-fuel)
                  (match (ctfe-quote-expr cleanup env init-fuel quasiquote)
                    [(OkCtfeQuoteExpr quoted-cleanup _ cleanup-fuel)
                      (match (ctfe-quote-resource-binding-list
                        rest
                        env
                        cleanup-fuel
                        quasiquote)
                        [(OkCtfeQuoteResourceBindings quoted-rest rest-fuel)
                          (OkCtfeQuoteResourceBindings
                            (ast-resource-binding-cons
                              (ast-resource-binding-id
                                (ctfe-quote-name-id env name)
                                quoted-init
                                quoted-cleanup)
                              quoted-rest)
                            rest-fuel)]
                        [(ErrCtfeQuoteResourceBindings diag)
                          (ErrCtfeQuoteResourceBindings diag)])]
                    [(ErrCtfeQuoteExpr diag)
                      (ErrCtfeQuoteResourceBindings diag)])]
                [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteResourceBindings diag)]))]))]))

(define (ctfe-quote-arm-list
  [arms : AstMatchArmList]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteArms
  (match arms
    [(AstMatchArmNil) (OkCtfeQuoteArms AstMatchArmNil fuel)]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (match (ctfe-quote-expr body env fuel quasiquote)
                [(OkCtfeQuoteExpr quoted-body _ body-fuel)
                  (match (ctfe-quote-arm-list rest env body-fuel quasiquote)
                    [(OkCtfeQuoteArms quoted-rest rest-fuel)
                      (OkCtfeQuoteArms
                        (ast-match-arm-cons
                          (ast-match-arm
                            (ctfe-quote-pattern pattern env)
                            quoted-body)
                          quoted-rest)
                        rest-fuel)]
                    [(ErrCtfeQuoteArms diag) (ErrCtfeQuoteArms diag)])]
                [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteArms diag)]))]))]))

(define (ctfe-quote-expr
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfeQuoteExpr
  (match expr
    [(AstExprSpanned inner-box span)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr node ty next-fuel)
            (OkCtfeQuoteExpr (ast-expr-spanned node span) ty next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprLiteral lit)
      (OkCtfeQuoteExpr (ast-node-push expr) (ctfe-quote-literal-type lit) fuel)]
    [(AstExprVar name)
      (OkCtfeQuoteExpr
        (ast-node-push
          (AstExprVar (intern (ctfe-quote-name env (intern-str name)))))
        (AstTyExpr)
        fuel)]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (match (ctfe-quote-expr left env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-left _ left-fuel)
            (match (ctfe-quote-expr right env left-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-right _ right-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-binary op quoted-left quoted-right)
                  (AstTyExpr)
                  right-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-unary op quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (match (ctfe-quote-expr func env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-func _ func-fuel)
            (match (ctfe-quote-expr-list args env func-fuel quasiquote)
              [(OkCtfeQuoteExprList quoted-args args-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-call quoted-func quoted-args)
                  (AstTyExpr)
                  args-fuel)]
              [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprBracketClause items)
      (match (ctfe-quote-expr-list items env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted-items next-fuel)
          (OkCtfeQuoteExpr
            (ast-expr-bracket-clause quoted-items)
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (match (ctfe-quote-expr cond env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-cond cond-ty cond-fuel)
            (match (ctfe-quote-expr then-branch env cond-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-then then-ty then-fuel)
                (match (ctfe-quote-expr else-branch env then-fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-else else-ty else-fuel)
                    (OkCtfeQuoteExpr
                      (ast-expr-if quoted-cond quoted-then quoted-else)
                      (ctfe-quote-if-type cond-ty then-ty else-ty)
                      else-fuel)]
                  [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (ctfe-quote-let-binding-list bindings env fuel quasiquote)
          [(OkCtfeQuoteLetBindings quoted-bindings bindings-fuel)
            (match (ctfe-quote-expr body env bindings-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-body body-ty body-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-let quoted-bindings quoted-body)
                  body-ty
                  body-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteLetBindings diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprLambda params maybe-ret body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (ctfe-quote-expr body env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-body _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-lambda
                (ctfe-quote-param-list params env)
                maybe-ret
                quoted-body)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprTuple exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted next-fuel)
          (OkCtfeQuoteExpr
            (ast-node-push (AstExprTuple quoted))
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprArray exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted next-fuel)
          (OkCtfeQuoteExpr
            (ast-node-push (AstExprArray quoted))
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprBegin exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted next-fuel)
          (OkCtfeQuoteExpr
            (ast-node-push (AstExprBegin quoted))
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprUnsafe exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted next-fuel)
          (OkCtfeQuoteExpr
            (ast-node-push (AstExprUnsafe quoted))
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (match (ctfe-quote-expr cond env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-cond _ cond-fuel)
            (match (ctfe-quote-expr body env cond-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-body _ body-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-while quoted-cond quoted-body)
                  (AstTyExpr)
                  body-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprSet name rhs-box)
      (let
        [rhs : AstExpr (ast-node-get rhs-box)]
        (match (ctfe-quote-expr rhs env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-rhs _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-set-id (ctfe-quote-name-id env name) quoted-rhs)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprAnn inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-ann quoted ty) ty next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-cast quoted ty) ty next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprBorrow mutable lifetime place-box)
      (let
        [place : AstExpr (ast-node-get place-box)]
        (match (ctfe-quote-expr place env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-place _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-borrow mutable lifetime quoted-place)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprMatch scrut-box arms)
      (let
        [scrut : AstExpr (ast-node-get scrut-box)]
        (match (ctfe-quote-expr scrut env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-scrut _ scrut-fuel)
            (match (ctfe-quote-arm-list arms env scrut-fuel quasiquote)
              [(OkCtfeQuoteArms quoted-arms arms-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-match quoted-scrut quoted-arms)
                  (AstTyExpr)
                  arms-fuel)]
              [(ErrCtfeQuoteArms diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprForeach index index-ty start-box end-box body-box)
      (let
        [start : AstExpr (ast-node-get start-box)]
        [end : AstExpr (ast-node-get end-box)]
        [body : AstExpr (ast-node-get body-box)]
        (match (ctfe-quote-expr start env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-start _ start-fuel)
            (match (ctfe-quote-expr end env start-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-end _ end-fuel)
                (match (ctfe-quote-expr body env end-fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-body _ body-fuel)
                    (OkCtfeQuoteExpr
                      (ast-expr-foreach-id
                        (ctfe-quote-name-id env index)
                        index-ty
                        quoted-start
                        quoted-end
                        quoted-body)
                      (AstTyExpr)
                      body-fuel)]
                  [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprSpmdReduce op index index-ty start-box end-box init-box value-box)
      (let
        [start : AstExpr (ast-node-get start-box)]
        [end : AstExpr (ast-node-get end-box)]
        [init : AstExpr (ast-node-get init-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (ctfe-quote-expr start env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-start _ start-fuel)
            (match (ctfe-quote-expr end env start-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-end _ end-fuel)
                (match (ctfe-quote-expr init env end-fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-init _ init-fuel)
                    (match (ctfe-quote-expr value env init-fuel quasiquote)
                      [(OkCtfeQuoteExpr quoted-value _ value-fuel)
                        (OkCtfeQuoteExpr
                          (ast-expr-spmd-reduce-id
                            op
                            (ctfe-quote-name-id env index)
                            index-ty
                            quoted-start
                            quoted-end
                            quoted-init
                            quoted-value)
                          (AstTyExpr)
                          value-fuel)]
                      [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
                  [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprStructGet inner-box field)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-struct-get-id quoted field)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprStructSet inner-box field value-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-inner _ inner-fuel)
            (match (ctfe-quote-expr value env inner-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-value _ value-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-struct-set-id quoted-inner field quoted-value)
                  (AstTyExpr)
                  value-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprTupleRef tuple-expr-box index)
      (let
        [tuple-expr : AstExpr (ast-node-get tuple-expr-box)]
        (match (ctfe-quote-expr tuple-expr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-tuple-ref quoted index)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprMakeArray ty len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (match (ctfe-quote-expr len env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-len _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-make-array ty quoted-len)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (ctfe-quote-expr array env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-array _ array-fuel)
            (match (ctfe-quote-expr index env array-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-index _ index-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-array-ref quoted-array quoted-index)
                  (AstTyExpr)
                  index-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (ctfe-quote-expr array env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-array _ array-fuel)
            (match (ctfe-quote-expr index env array-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-index _ index-fuel)
                (match (ctfe-quote-expr value env index-fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-value _ value-fuel)
                    (OkCtfeQuoteExpr
                      (ast-expr-array-set
                        quoted-array
                        quoted-index
                        quoted-value)
                      (AstTyExpr)
                      value-fuel)]
                  [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (ctfe-quote-expr array env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-array _ array-fuel)
            (match (ctfe-quote-expr value env array-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-value _ value-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-array-push quoted-array quoted-value)
                  (AstTyExpr)
                  value-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprStringRef text-box index-box)
      (let
        [text : AstExpr (ast-node-get text-box)]
        [index : AstExpr (ast-node-get index-box)]
        (match (ctfe-quote-expr text env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-text _ text-fuel)
            (match (ctfe-quote-expr index env text-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-index _ index-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-string-ref quoted-text quoted-index)
                  (AstTyExpr)
                  index-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprWithRegion name body)
      (match (ctfe-quote-expr-list body env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted-body next-fuel)
          (OkCtfeQuoteExpr
            (ast-node-push
              (AstExprWithRegion (ctfe-quote-name env name) quoted-body))
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (match (ctfe-quote-expr scratch env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-scratch _ scratch-fuel)
            (match (ctfe-quote-expr-list body env scratch-fuel quasiquote)
              [(OkCtfeQuoteExprList quoted-body body-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-with-escape quoted-scratch quoted-body)
                  (AstTyExpr)
                  body-fuel)]
              [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprWithResource bindings body)
      (match (ctfe-quote-resource-binding-list bindings env fuel quasiquote)
        [(OkCtfeQuoteResourceBindings quoted-bindings bindings-fuel)
          (match (ctfe-quote-expr-list body env bindings-fuel quasiquote)
            [(OkCtfeQuoteExprList quoted-body body-fuel)
              (OkCtfeQuoteExpr
                (ast-node-push
                  (AstExprWithResource quoted-bindings quoted-body))
                (AstTyExpr)
                body-fuel)]
            [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
        [(ErrCtfeQuoteResourceBindings diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-box quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-box-get quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted ty next-fuel)
            (OkCtfeQuoteExpr (ast-expr-comptime quoted) ty next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-return quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-try quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprInit maybe-ty)
      (OkCtfeQuoteExpr (ast-expr-init-maybe maybe-ty) (AstTyExpr) fuel)]
    [(AstExprPtrNullCheck ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-ptr-null-check quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrAddrOf name)
      (OkCtfeQuoteExpr
        (ast-expr-ptr-addr-of-id (ctfe-quote-name-id env name))
        (AstTyExpr)
        fuel)]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-ptr-read quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-ptr _ ptr-fuel)
            (match (ctfe-quote-expr value env ptr-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-value _ value-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-ptr-write quoted-ptr quoted-value)
                  (AstTyExpr)
                  value-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-ptr _ ptr-fuel)
            (match (ctfe-quote-expr offset env ptr-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-offset _ offset-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-ptr-offset quoted-ptr quoted-offset)
                  (AstTyExpr)
                  offset-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrCast ptr-box ty)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-ptr-cast quoted ty)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-ptr-to-int quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprIntToPtr value-box ty)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (ctfe-quote-expr value env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-int-to-ptr quoted ty)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-string-data quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-ptr _ ptr-fuel)
            (match (ctfe-quote-expr len env ptr-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-len _ len-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-string-from-bytes quoted-ptr quoted-len)
                  (AstTyExpr)
                  len-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprArrayData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-array-data quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (ctfe-quote-expr leaf env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-leaf _ leaf-fuel)
            (match (ctfe-quote-expr subleaf env leaf-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-subleaf _ subleaf-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-cpuid-eax quoted-leaf quoted-subleaf)
                  (AstTyExpr)
                  subleaf-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (ctfe-quote-expr leaf env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-leaf _ leaf-fuel)
            (match (ctfe-quote-expr subleaf env leaf-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-subleaf _ subleaf-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-cpuid-ebx quoted-leaf quoted-subleaf)
                  (AstTyExpr)
                  subleaf-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (ctfe-quote-expr leaf env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-leaf _ leaf-fuel)
            (match (ctfe-quote-expr subleaf env leaf-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-subleaf _ subleaf-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-cpuid-ecx quoted-leaf quoted-subleaf)
                  (AstTyExpr)
                  subleaf-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (match (ctfe-quote-expr leaf env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-leaf _ leaf-fuel)
            (match (ctfe-quote-expr subleaf env leaf-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-subleaf _ subleaf-fuel)
                (OkCtfeQuoteExpr
                  (ast-expr-cpuid-edx quoted-leaf quoted-subleaf)
                  (AstTyExpr)
                  subleaf-fuel)]
              [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (match (ctfe-quote-expr index env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-index _ index-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-xgetbv quoted-index)
              (AstTyExpr)
              index-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprSyscall args)
      (match (ctfe-quote-expr-list args env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted-args args-fuel)
          (OkCtfeQuoteExpr (ast-expr-syscall quoted-args) (AstTyExpr) args-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (if quasiquote
          (ctfe-eval-unquote-expr inner expr env fuel)
          (match (ctfe-quote-expr inner env fuel quasiquote)
            [(OkCtfeQuoteExpr quoted _ next-fuel)
              (OkCtfeQuoteExpr (ast-expr-unquote quoted) (AstTyExpr) next-fuel)]
            [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (if quasiquote
          (ErrCtfeQuoteExpr
            (ctfe-diagnostic-at-expr
              expr
              "unquote-splicing is only valid in a quasiquote list"))
          (match (ctfe-quote-expr inner env fuel quasiquote)
            [(OkCtfeQuoteExpr quoted _ next-fuel)
              (OkCtfeQuoteExpr
                (ast-expr-unquote-splicing quoted)
                (AstTyExpr)
                next-fuel)]
            [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])))]
    [_ (OkCtfeQuoteExpr (ast-node-push expr) (AstTyExpr) fuel)]))

(define (ctfe-eval-quote
  [template : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]
  [quasiquote : bool]) : ResultCtfe
  (match (ctfe-quote-expr template env fuel quasiquote)
    [(OkCtfeQuoteExpr node ty next-fuel) (OkCtfe (CtfeExpr node ty) next-fuel)]
    [(ErrCtfeQuoteExpr diag) (ErrCtfe diag)]))

;; --- expr constructors and inspectors (#1137) --------------------------------
;; Macro transformers need to build and pattern-match AST nodes at comptime.
;; These constructors / inspectors cover the forms needed by v1 macros
;; (and, or, when, unless, cond): literals, variables, if, and call.
;; EQ -------------------------------------------------------------------------
(define (ctfe-literal-eq [a : AstLiteral] [b : AstLiteral]) : bool
  (match a
    [(AstLitInt a-n)
      (match b
        [(AstLitInt b-n) (= a-n b-n)]
        [_ false])]
    [(AstLitBool a-b)
      (match b
        [(AstLitBool b-b) (= a-b b-b)]
        [_ false])]
    [(AstLitChar a-c)
      (match b
        [(AstLitChar b-c) (= a-c b-c)]
        [_ false])]
    [(AstLitFloat a-text)
      (match b
        [(AstLitFloat b-text) (string-eq a-text b-text)]
        [_ false])]
    [(AstLitString a-text)
      (match b
        [(AstLitString b-text) (string-eq a-text b-text)]
        [_ false])]
    [(AstLitUnit)
      (match b
        [(AstLitUnit) true]
        [_ false])]
    [_ false]))

(define (ctfe-borrow-lifetime-eq
  [a : AstBorrowLifetime]
  [b : AstBorrowLifetime]) : bool
  (match a
    [(AstBorrowLifetimeInferred)
      (match b
        [(AstBorrowLifetimeInferred) true]
        [_ false])]
    [(AstBorrowLifetimeNamed a-name)
      (match b
        [(AstBorrowLifetimeNamed b-name) (string-eq a-name b-name)]
        [_ false])]))

(define (ctfe-maybe-type-eq [a : AstMaybeType] [b : AstMaybeType]) : bool
  (match a
    [(AstNoType)
      (match b
        [(AstNoType) true]
        [_ false])]
    [(AstSomeType a-ty)
      (match b
        [(AstSomeType b-ty) (ctfe-type-eq a-ty b-ty)]
        [_ false])]))

(define (ctfe-param-eq [a : AstParam] [b : AstParam]) : bool
  (match a
    [(AstParam a-name a-ty a-comptime)
      (match b
        [(AstParam b-name b-ty b-comptime)
          (and
            (= a-name b-name)
            (ctfe-type-eq a-ty b-ty)
            (= a-comptime b-comptime))])]))

(define (ctfe-param-list-eq [a : AstParamList] [b : AstParamList]) : bool
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
                (ctfe-param-eq a-head b-head)
                (ctfe-param-list-eq a-rest b-rest)))]
          [_ false]))]))

(define (ctfe-pattern-eq [a : AstPattern] [b : AstPattern]) : bool
  (match a
    [(AstPatVar a-name a-ty)
      (match b
        [(AstPatVar b-name b-ty)
          (and (= a-name b-name) (ctfe-maybe-type-eq a-ty b-ty))]
        [_ false])]
    [(AstPatTuple a-items-box)
      (let
        [a-items : AstPatternList (box-get a-items-box)]
        (match b
          [(AstPatTuple b-items-box)
            (ctfe-pattern-list-eq a-items (box-get b-items-box))]
          [_ false]))]
    [(AstPatWildcard)
      (match b
        [(AstPatWildcard) true]
        [_ false])]
    [(AstPatBinding a-name)
      (match b
        [(AstPatBinding b-name) (= a-name b-name)]
        [_ false])]
    [(AstPatVariant a-name a-items-box)
      (let
        [a-items : AstPatternList (box-get a-items-box)]
        (match b
          [(AstPatVariant b-name b-items-box)
            (and
              (= a-name b-name)
              (ctfe-pattern-list-eq a-items (box-get b-items-box)))]
          [_ false]))]
    [(AstPatLiteral a-lit)
      (match b
        [(AstPatLiteral b-lit) (ctfe-literal-eq a-lit b-lit)]
        [_ false])]))

(define (ctfe-pattern-list-eq [a : AstPatternList] [b : AstPatternList]) : bool
  (match a
    [(AstPatternNil)
      (match b
        [(AstPatternNil) true]
        [_ false])]
    [(AstPatternCons a-head a-tail)
      (let
        [a-head : AstPattern (box-get a-head)]
        [a-tail : AstPatternList (box-get a-tail)]
        (match b
          [(AstPatternCons b-head b-tail)
            (let
              [b-head : AstPattern (box-get b-head)]
              [b-tail : AstPatternList (box-get b-tail)]
              (and
                (ctfe-pattern-eq a-head b-head)
                (ctfe-pattern-list-eq a-tail b-tail)))]
          [_ false]))]))

(define (ctfe-let-binding-eq [a : AstLetBinding] [b : AstLetBinding]) : bool
  (match a
    [(AstLetBinding a-name a-ty a-value-box)
      (let
        [a-value : AstExpr (ast-node-get a-value-box)]
        (match b
          [(AstLetBinding b-name b-ty b-value-box)
            (let
              [b-value : AstExpr (ast-node-get b-value-box)]
              (and
                (= a-name b-name)
                (ctfe-maybe-type-eq a-ty b-ty)
                (ctfe-expr-eq a-value b-value)))]
          [_ false]))]))

(define (ctfe-let-binding-list-eq
  [a : AstLetBindingList]
  [b : AstLetBindingList]) : bool
  (match a
    [(AstLetBindingNil)
      (match b
        [(AstLetBindingNil) true]
        [_ false])]
    [(AstLetBindingCons a-head a-tail)
      (let
        [a-tail : AstLetBindingList (box-get a-tail)]
        (match b
          [(AstLetBindingCons b-head b-tail)
            (let
              [b-tail : AstLetBindingList (box-get b-tail)]
              (and
                (ctfe-let-binding-eq a-head b-head)
                (ctfe-let-binding-list-eq a-tail b-tail)))]
          [_ false]))]))

(define (ctfe-resource-binding-eq
  [a : AstResourceBinding]
  [b : AstResourceBinding]) : bool
  (match a
    [(AstResourceBinding a-name a-init-box a-cleanup-box)
      (let
        [a-init : AstExpr (ast-node-get a-init-box)]
        [a-cleanup : AstExpr (ast-node-get a-cleanup-box)]
        (match b
          [(AstResourceBinding b-name b-init-box b-cleanup-box)
            (let
              [b-init : AstExpr (ast-node-get b-init-box)]
              [b-cleanup : AstExpr (ast-node-get b-cleanup-box)]
              (and
                (= a-name b-name)
                (ctfe-expr-eq a-init b-init)
                (ctfe-expr-eq a-cleanup b-cleanup)))]
          [_ false]))]))

(define (ctfe-resource-binding-list-eq
  [a : AstResourceBindingList]
  [b : AstResourceBindingList]) : bool
  (match a
    [(AstResourceBindingNil)
      (match b
        [(AstResourceBindingNil) true]
        [_ false])]
    [(AstResourceBindingCons a-head a-tail)
      (let
        [a-tail : AstResourceBindingList (box-get a-tail)]
        (match b
          [(AstResourceBindingCons b-head b-tail)
            (let
              [b-tail : AstResourceBindingList (box-get b-tail)]
              (and
                (ctfe-resource-binding-eq a-head b-head)
                (ctfe-resource-binding-list-eq a-tail b-tail)))]
          [_ false]))]))

(define (ctfe-match-arm-eq [a : AstMatchArm] [b : AstMatchArm]) : bool
  (match a
    [(AstMatchArm a-pattern a-body-box)
      (let
        [a-body : AstExpr (ast-node-get a-body-box)]
        (match b
          [(AstMatchArm b-pattern b-body-box)
            (let
              [b-body : AstExpr (ast-node-get b-body-box)]
              (and
                (ctfe-pattern-eq a-pattern b-pattern)
                (ctfe-expr-eq a-body b-body)))]
          [_ false]))]))

(define (ctfe-match-arm-list-eq [a : AstMatchArmList] [b : AstMatchArmList]) : bool
  (match a
    [(AstMatchArmNil)
      (match b
        [(AstMatchArmNil) true]
        [_ false])]
    [(AstMatchArmCons a-head a-tail)
      (let
        [a-tail : AstMatchArmList (box-get a-tail)]
        (match b
          [(AstMatchArmCons b-head b-tail)
            (let
              [b-tail : AstMatchArmList (box-get b-tail)]
              (and
                (ctfe-match-arm-eq a-head b-head)
                (ctfe-match-arm-list-eq a-tail b-tail)))]
          [_ false]))]))

(define (ctfe-reduce-op-eq [a : AstReduceOp] [b : AstReduceOp]) : bool
  (match a
    [(AstReduceSum)
      (match b
        [(AstReduceSum) true]
        [_ false])]
    [(AstReduceMin)
      (match b
        [(AstReduceMin) true]
        [_ false])]
    [(AstReduceMax)
      (match b
        [(AstReduceMax) true]
        [_ false])]
    [(AstReduceAll)
      (match b
        [(AstReduceAll) true]
        [_ false])]
    [(AstReduceAny)
      (match b
        [(AstReduceAny) true]
        [_ false])]))

(define (ctfe-expr-eq-inner [a : AstExpr] [b : AstExpr]) : bool
  (match a
    [(AstExprLiteral a-lit)
      (match b
        [(AstExprLiteral b-lit) (ctfe-literal-eq a-lit b-lit)]
        [_ false])]
    [(AstExprVar a-name)
      (match b
        [(AstExprVar b-name)
          (string-eq (intern-str a-name) (intern-str b-name))]
        [_ false])]
    [(AstExprBinary a-op a-l-box a-r-box)
      (let
        [a-l : AstExpr (ast-node-get a-l-box)]
        [a-r : AstExpr (ast-node-get a-r-box)]
        (match b
          [(AstExprBinary b-op b-l-box b-r-box)
            (let
              [b-l : AstExpr (ast-node-get b-l-box)]
              [b-r : AstExpr (ast-node-get b-r-box)]
              (and
                (ctfe-binop-eq a-op b-op)
                (ctfe-expr-eq a-l b-l)
                (ctfe-expr-eq a-r b-r)))]
          [_ false]))]
    [(AstExprUnary a-op a-in-box)
      (let
        [a-in : AstExpr (ast-node-get a-in-box)]
        (match b
          [(AstExprUnary b-op b-in-box)
            (let
              [b-in : AstExpr (ast-node-get b-in-box)]
              (and (ctfe-unop-eq a-op b-op) (ctfe-expr-eq a-in b-in)))]
          [_ false]))]
    [(AstExprIf a-c-box a-t-box a-e-box)
      (let
        [a-c : AstExpr (ast-node-get a-c-box)]
        [a-t : AstExpr (ast-node-get a-t-box)]
        [a-e : AstExpr (ast-node-get a-e-box)]
        (match b
          [(AstExprIf b-c-box b-t-box b-e-box)
            (let
              [b-c : AstExpr (ast-node-get b-c-box)]
              [b-t : AstExpr (ast-node-get b-t-box)]
              [b-e : AstExpr (ast-node-get b-e-box)]
              (and
                (ctfe-expr-eq a-c b-c)
                (ctfe-expr-eq a-t b-t)
                (ctfe-expr-eq a-e b-e)))]
          [_ false]))]
    [(AstExprLet a-bindings a-body-box)
      (let
        [a-body : AstExpr (ast-node-get a-body-box)]
        (match b
          [(AstExprLet b-bindings b-body-box)
            (let
              [b-body : AstExpr (ast-node-get b-body-box)]
              (and
                (ctfe-let-binding-list-eq a-bindings b-bindings)
                (ctfe-expr-eq a-body b-body)))]
          [_ false]))]
    [(AstExprLambda a-params a-ret a-body-box)
      (let
        [a-body : AstExpr (ast-node-get a-body-box)]
        (match b
          [(AstExprLambda b-params b-ret b-body-box)
            (let
              [b-body : AstExpr (ast-node-get b-body-box)]
              (and
                (ctfe-param-list-eq a-params b-params)
                (ctfe-maybe-type-eq a-ret b-ret)
                (ctfe-expr-eq a-body b-body)))]
          [_ false]))]
    [(AstExprCall a-fun-box a-args)
      (let
        [a-fun : AstExpr (ast-node-get a-fun-box)]
        (match b
          [(AstExprCall b-fun-box b-args)
            (let
              [b-fun : AstExpr (ast-node-get b-fun-box)]
              (and (ctfe-expr-eq a-fun b-fun) (ctfe-expr-list-eq a-args b-args)))]
          [_ false]))]
    [(AstExprBracketClause a-items)
      (match b
        [(AstExprBracketClause b-items) (ctfe-expr-list-eq a-items b-items)]
        [_ false])]
    [(AstExprTuple a-items)
      (match b
        [(AstExprTuple b-items) (ctfe-expr-list-eq a-items b-items)]
        [_ false])]
    [(AstExprTupleRef a-inner-box a-index)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprTupleRef b-inner-box b-index)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (and (= a-index b-index) (ctfe-expr-eq a-inner b-inner)))]
          [_ false]))]
    [(AstExprArray a-items)
      (match b
        [(AstExprArray b-items) (ctfe-expr-list-eq a-items b-items)]
        [_ false])]
    [(AstExprMakeArray a-ty a-size-box)
      (let
        [a-size : AstExpr (ast-node-get a-size-box)]
        (match b
          [(AstExprMakeArray b-ty b-size-box)
            (let
              [b-size : AstExpr (ast-node-get b-size-box)]
              (and (ctfe-type-eq a-ty b-ty) (ctfe-expr-eq a-size b-size)))]
          [_ false]))]
    [(AstExprArrayRef a-target-box a-index-box)
      (let
        [a-target : AstExpr (ast-node-get a-target-box)]
        [a-index : AstExpr (ast-node-get a-index-box)]
        (match b
          [(AstExprArrayRef b-target-box b-index-box)
            (let
              [b-target : AstExpr (ast-node-get b-target-box)]
              [b-index : AstExpr (ast-node-get b-index-box)]
              (and
                (ctfe-expr-eq a-target b-target)
                (ctfe-expr-eq a-index b-index)))]
          [_ false]))]
    [(AstExprArraySet a-target-box a-index-box a-value-box)
      (let
        [a-target : AstExpr (ast-node-get a-target-box)]
        [a-index : AstExpr (ast-node-get a-index-box)]
        [a-value : AstExpr (ast-node-get a-value-box)]
        (match b
          [(AstExprArraySet b-target-box b-index-box b-value-box)
            (let
              [b-target : AstExpr (ast-node-get b-target-box)]
              [b-index : AstExpr (ast-node-get b-index-box)]
              [b-value : AstExpr (ast-node-get b-value-box)]
              (and
                (ctfe-expr-eq a-target b-target)
                (ctfe-expr-eq a-index b-index)
                (ctfe-expr-eq a-value b-value)))]
          [_ false]))]
    [(AstExprArrayPush a-target-box a-value-box)
      (let
        [a-target : AstExpr (ast-node-get a-target-box)]
        [a-value : AstExpr (ast-node-get a-value-box)]
        (match b
          [(AstExprArrayPush b-target-box b-value-box)
            (let
              [b-target : AstExpr (ast-node-get b-target-box)]
              [b-value : AstExpr (ast-node-get b-value-box)]
              (and
                (ctfe-expr-eq a-target b-target)
                (ctfe-expr-eq a-value b-value)))]
          [_ false]))]
    [(AstExprStringRef a-target-box a-index-box)
      (let
        [a-target : AstExpr (ast-node-get a-target-box)]
        [a-index : AstExpr (ast-node-get a-index-box)]
        (match b
          [(AstExprStringRef b-target-box b-index-box)
            (let
              [b-target : AstExpr (ast-node-get b-target-box)]
              [b-index : AstExpr (ast-node-get b-index-box)]
              (and
                (ctfe-expr-eq a-target b-target)
                (ctfe-expr-eq a-index b-index)))]
          [_ false]))]
    [(AstExprWhile a-cond-box a-body-box)
      (let
        [a-cond : AstExpr (ast-node-get a-cond-box)]
        [a-body : AstExpr (ast-node-get a-body-box)]
        (match b
          [(AstExprWhile b-cond-box b-body-box)
            (let
              [b-cond : AstExpr (ast-node-get b-cond-box)]
              [b-body : AstExpr (ast-node-get b-body-box)]
              (and (ctfe-expr-eq a-cond b-cond) (ctfe-expr-eq a-body b-body)))]
          [_ false]))]
    [(AstExprBegin a-exprs)
      (match b
        [(AstExprBegin b-exprs) (ctfe-expr-list-eq a-exprs b-exprs)]
        [_ false])]
    [(AstExprUnsafe a-exprs)
      (match b
        [(AstExprUnsafe b-exprs) (ctfe-expr-list-eq a-exprs b-exprs)]
        [_ false])]
    [(AstExprSet a-name a-value-box)
      (let
        [a-value : AstExpr (ast-node-get a-value-box)]
        (match b
          [(AstExprSet b-name b-value-box)
            (let
              [b-value : AstExpr (ast-node-get b-value-box)]
              (and (= a-name b-name) (ctfe-expr-eq a-value b-value)))]
          [_ false]))]
    [(AstExprAnn a-inner-box a-ty)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprAnn b-inner-box b-ty)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (and (ctfe-expr-eq a-inner b-inner) (ctfe-type-eq a-ty b-ty)))]
          [_ false]))]
    [(AstExprCast a-inner-box a-ty)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprCast b-inner-box b-ty)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (and (ctfe-expr-eq a-inner b-inner) (ctfe-type-eq a-ty b-ty)))]
          [_ false]))]
    [(AstExprBorrow a-mut a-life a-place-box)
      (let
        [a-place : AstExpr (ast-node-get a-place-box)]
        (match b
          [(AstExprBorrow b-mut b-life b-place-box)
            (let
              [b-place : AstExpr (ast-node-get b-place-box)]
              (and
                (= a-mut b-mut)
                (ctfe-borrow-lifetime-eq a-life b-life)
                (ctfe-expr-eq a-place b-place)))]
          [_ false]))]
    [(AstExprMatch a-scrut-box a-arms)
      (let
        [a-scrut : AstExpr (ast-node-get a-scrut-box)]
        (match b
          [(AstExprMatch b-scrut-box b-arms)
            (let
              [b-scrut : AstExpr (ast-node-get b-scrut-box)]
              (and
                (ctfe-expr-eq a-scrut b-scrut)
                (ctfe-match-arm-list-eq a-arms b-arms)))]
          [_ false]))]
    [(AstExprForeach a-name a-ty a-start-box a-end-box a-body-box)
      (let
        [a-start : AstExpr (ast-node-get a-start-box)]
        [a-end : AstExpr (ast-node-get a-end-box)]
        [a-body : AstExpr (ast-node-get a-body-box)]
        (match b
          [(AstExprForeach b-name b-ty b-start-box b-end-box b-body-box)
            (let
              [b-start : AstExpr (ast-node-get b-start-box)]
              [b-end : AstExpr (ast-node-get b-end-box)]
              [b-body : AstExpr (ast-node-get b-body-box)]
              (and
                (= a-name b-name)
                (ctfe-type-eq a-ty b-ty)
                (ctfe-expr-eq a-start b-start)
                (ctfe-expr-eq a-end b-end)
                (ctfe-expr-eq a-body b-body)))]
          [_ false]))]
    [(AstExprSpmdReduce
        a-op
        a-name
        a-ty
        a-start-box
        a-end-box
        a-init-box
        a-value-box)
      (let
        [a-start : AstExpr (ast-node-get a-start-box)]
        [a-end : AstExpr (ast-node-get a-end-box)]
        [a-init : AstExpr (ast-node-get a-init-box)]
        [a-value : AstExpr (ast-node-get a-value-box)]
        (match b
          [(AstExprSpmdReduce
              b-op
              b-name
              b-ty
              b-start-box
              b-end-box
              b-init-box
              b-value-box)
            (let
              [b-start : AstExpr (ast-node-get b-start-box)]
              [b-end : AstExpr (ast-node-get b-end-box)]
              [b-init : AstExpr (ast-node-get b-init-box)]
              [b-value : AstExpr (ast-node-get b-value-box)]
              (and
                (ctfe-reduce-op-eq a-op b-op)
                (= a-name b-name)
                (ctfe-type-eq a-ty b-ty)
                (ctfe-expr-eq a-start b-start)
                (ctfe-expr-eq a-end b-end)
                (ctfe-expr-eq a-init b-init)
                (ctfe-expr-eq a-value b-value)))]
          [_ false]))]
    [(AstExprStructGet a-inner-box a-field)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprStructGet b-inner-box b-field)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (and (= a-field b-field) (ctfe-expr-eq a-inner b-inner)))]
          [_ false]))]
    [(AstExprStructSet a-inner-box a-field a-value-box)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        [a-value : AstExpr (ast-node-get a-value-box)]
        (match b
          [(AstExprStructSet b-inner-box b-field b-value-box)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              [b-value : AstExpr (ast-node-get b-value-box)]
              (and
                (= a-field b-field)
                (ctfe-expr-eq a-inner b-inner)
                (ctfe-expr-eq a-value b-value)))]
          [_ false]))]
    [(AstExprWithRegion a-name a-body)
      (match b
        [(AstExprWithRegion b-name b-body)
          (and (string-eq a-name b-name) (ctfe-expr-list-eq a-body b-body))]
        [_ false])]
    [(AstExprWithEscape a-escape-box a-body)
      (let
        [a-escape : AstExpr (ast-node-get a-escape-box)]
        (match b
          [(AstExprWithEscape b-escape-box b-body)
            (let
              [b-escape : AstExpr (ast-node-get b-escape-box)]
              (and
                (ctfe-expr-eq a-escape b-escape)
                (ctfe-expr-list-eq a-body b-body)))]
          [_ false]))]
    [(AstExprWithResource a-bindings a-body)
      (match b
        [(AstExprWithResource b-bindings b-body)
          (and
            (ctfe-resource-binding-list-eq a-bindings b-bindings)
            (ctfe-expr-list-eq a-body b-body))]
        [_ false])]
    [(AstExprPtrRead a-ptr-box)
      (let
        [a-ptr : AstExpr (ast-node-get a-ptr-box)]
        (match b
          [(AstExprPtrRead b-ptr-box)
            (let
              [b-ptr : AstExpr (ast-node-get b-ptr-box)]
              (ctfe-expr-eq a-ptr b-ptr))]
          [_ false]))]
    [(AstExprPtrAddrOf a-name)
      (match b
        [(AstExprPtrAddrOf b-name) (= a-name b-name)]
        [_ false])]
    [(AstExprPtrWrite a-ptr-box a-value-box)
      (let
        [a-ptr : AstExpr (ast-node-get a-ptr-box)]
        [a-value : AstExpr (ast-node-get a-value-box)]
        (match b
          [(AstExprPtrWrite b-ptr-box b-value-box)
            (let
              [b-ptr : AstExpr (ast-node-get b-ptr-box)]
              [b-value : AstExpr (ast-node-get b-value-box)]
              (and (ctfe-expr-eq a-ptr b-ptr) (ctfe-expr-eq a-value b-value)))]
          [_ false]))]
    [(AstExprPtrOffset a-ptr-box a-offset-box)
      (let
        [a-ptr : AstExpr (ast-node-get a-ptr-box)]
        [a-offset : AstExpr (ast-node-get a-offset-box)]
        (match b
          [(AstExprPtrOffset b-ptr-box b-offset-box)
            (let
              [b-ptr : AstExpr (ast-node-get b-ptr-box)]
              [b-offset : AstExpr (ast-node-get b-offset-box)]
              (and (ctfe-expr-eq a-ptr b-ptr) (ctfe-expr-eq a-offset b-offset)))]
          [_ false]))]
    [(AstExprPtrCast a-ptr-box a-ty)
      (let
        [a-ptr : AstExpr (ast-node-get a-ptr-box)]
        (match b
          [(AstExprPtrCast b-ptr-box b-ty)
            (let
              [b-ptr : AstExpr (ast-node-get b-ptr-box)]
              (and (ctfe-expr-eq a-ptr b-ptr) (ctfe-type-eq a-ty b-ty)))]
          [_ false]))]
    [(AstExprPtrToInt a-ptr-box)
      (let
        [a-ptr : AstExpr (ast-node-get a-ptr-box)]
        (match b
          [(AstExprPtrToInt b-ptr-box)
            (let
              [b-ptr : AstExpr (ast-node-get b-ptr-box)]
              (ctfe-expr-eq a-ptr b-ptr))]
          [_ false]))]
    [(AstExprIntToPtr a-value-box a-ty)
      (let
        [a-value : AstExpr (ast-node-get a-value-box)]
        (match b
          [(AstExprIntToPtr b-value-box b-ty)
            (let
              [b-value : AstExpr (ast-node-get b-value-box)]
              (and (ctfe-expr-eq a-value b-value) (ctfe-type-eq a-ty b-ty)))]
          [_ false]))]
    [(AstExprBox a-inner-box)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprBox b-inner-box)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprBoxGet a-inner-box)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprBoxGet b-inner-box)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprTypeLiteral a-ty)
      (match b
        [(AstExprTypeLiteral b-ty) (ctfe-type-eq a-ty b-ty)]
        [_ false])]
    [(AstExprInit a-ty)
      (match b
        [(AstExprInit b-ty) (ctfe-maybe-type-eq a-ty b-ty)]
        [_ false])]
    [(AstExprComptime a-inner-box)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprComptime b-inner-box)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprQuote a-inner-box)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprQuote b-inner-box)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprQuasiquote a-inner-box)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprQuasiquote b-inner-box)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprUnquote a-inner-box)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprUnquote b-inner-box)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprUnquoteSplicing a-inner-box)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprUnquoteSplicing b-inner-box)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprTry a-inner-box)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprTry b-inner-box)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprReturn a-inner-box)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprReturn b-inner-box)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprPtrNull a-ty)
      (match b
        [(AstExprPtrNull b-ty) (ctfe-type-eq a-ty b-ty)]
        [_ false])]
    [(AstExprPtrNullCheck a-inner-box)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprPtrNullCheck b-inner-box)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprStringData a-inner-box)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprStringData b-inner-box)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprStringFromBytes a-ptr-box a-len-box)
      (let
        [a-ptr : AstExpr (ast-node-get a-ptr-box)]
        [a-len : AstExpr (ast-node-get a-len-box)]
        (match b
          [(AstExprStringFromBytes b-ptr-box b-len-box)
            (let
              [b-ptr : AstExpr (ast-node-get b-ptr-box)]
              [b-len : AstExpr (ast-node-get b-len-box)]
              (and (ctfe-expr-eq a-ptr b-ptr) (ctfe-expr-eq a-len b-len)))]
          [_ false]))]
    [(AstExprArrayData a-inner-box)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (match b
          [(AstExprArrayData b-inner-box)
            (let
              [b-inner : AstExpr (ast-node-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprProgramArgc)
      (match b
        [(AstExprProgramArgc) true]
        [_ false])]
    [(AstExprProgramArgv)
      (match b
        [(AstExprProgramArgv) true]
        [_ false])]
    [(AstExprProgramEnvp)
      (match b
        [(AstExprProgramEnvp) true]
        [_ false])]
    [(AstExprCpuIdEax a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (ast-node-get a-leaf-box)]
        [a-subleaf : AstExpr (ast-node-get a-subleaf-box)]
        (match b
          [(AstExprCpuIdEax b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (ast-node-get b-leaf-box)]
              [b-subleaf : AstExpr (ast-node-get b-subleaf-box)]
              (and
                (ctfe-expr-eq a-leaf b-leaf)
                (ctfe-expr-eq a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExprCpuIdEbx a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (ast-node-get a-leaf-box)]
        [a-subleaf : AstExpr (ast-node-get a-subleaf-box)]
        (match b
          [(AstExprCpuIdEbx b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (ast-node-get b-leaf-box)]
              [b-subleaf : AstExpr (ast-node-get b-subleaf-box)]
              (and
                (ctfe-expr-eq a-leaf b-leaf)
                (ctfe-expr-eq a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExprCpuIdEcx a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (ast-node-get a-leaf-box)]
        [a-subleaf : AstExpr (ast-node-get a-subleaf-box)]
        (match b
          [(AstExprCpuIdEcx b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (ast-node-get b-leaf-box)]
              [b-subleaf : AstExpr (ast-node-get b-subleaf-box)]
              (and
                (ctfe-expr-eq a-leaf b-leaf)
                (ctfe-expr-eq a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExprCpuIdEdx a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (ast-node-get a-leaf-box)]
        [a-subleaf : AstExpr (ast-node-get a-subleaf-box)]
        (match b
          [(AstExprCpuIdEdx b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (ast-node-get b-leaf-box)]
              [b-subleaf : AstExpr (ast-node-get b-subleaf-box)]
              (and
                (ctfe-expr-eq a-leaf b-leaf)
                (ctfe-expr-eq a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExprXgetbv a-index-box)
      (let
        [a-index : AstExpr (ast-node-get a-index-box)]
        (match b
          [(AstExprXgetbv b-index-box)
            (let
              [b-index : AstExpr (ast-node-get b-index-box)]
              (ctfe-expr-eq a-index b-index))]
          [_ false]))]
    [(AstExprSyscall a-args)
      (match b
        [(AstExprSyscall b-args) (ctfe-expr-list-eq a-args b-args)]
        [_ false])]
    [(AstExprSpanned a-inner-box _)
      (let
        [a-inner : AstExpr (ast-node-get a-inner-box)]
        (ctfe-expr-eq a-inner b))]
    [_ false]))

(define (ctfe-expr-eq [a : AstExpr] [b : AstExpr]) : bool
  (ctfe-expr-eq-inner (ast-expr-unspan a) (ast-expr-unspan b)))

(define (ctfe-expr-list-eq [a : AstExprList] [b : AstExprList]) : bool
  (match a
    [(AstExprNil)
      (match b
        [(AstExprNil) true]
        [_ false])]
    [(AstExprCons a-head a-tail)
      (let
        [a-head : AstExpr (ast-node-get a-head)]
        [a-tail : AstExprList (box-get a-tail)]
        (match b
          [(AstExprCons b-head b-tail)
            (let
              [b-head : AstExpr (ast-node-get b-head)]
              [b-tail : AstExprList (box-get b-tail)]
              (and
                (ctfe-expr-eq a-head b-head)
                (ctfe-expr-list-eq a-tail b-tail)))]
          [_ false]))]))

(define (ctfe-expr-clause-eq [a : AstExprClause] [b : AstExprClause]) : bool
  (and
    (ctfe-expr-eq
      (ast-node-get (ctfe-expr-clause-first a))
      (ast-node-get (ctfe-expr-clause-first b)))
    (ctfe-expr-eq
      (ast-node-get (ctfe-expr-clause-second a))
      (ast-node-get (ctfe-expr-clause-second b)))))

(define (ctfe-expr-clause-list-eq
  [a : AstExprClauseList]
  [b : AstExprClauseList]) : bool
  (match a
    [(AstExprClauseNil)
      (match b
        [(AstExprClauseNil) true]
        [_ false])]
    [(AstExprClauseCons a-head a-tail)
      (let
        [a-tail : AstExprClauseList (box-get a-tail)]
        (match b
          [(AstExprClauseCons b-head b-tail)
            (let
              [b-tail : AstExprClauseList (box-get b-tail)]
              (and
                (ctfe-expr-clause-eq a-head b-head)
                (ctfe-expr-clause-list-eq a-tail b-tail)))]
          [_ false]))]))

(define (ctfe-binop-eq [a : AstBinOp] [b : AstBinOp]) : bool
  (match a
    [(AstBinAdd)
      (match b
        [(AstBinAdd) true]
        [_ false])]
    [(AstBinSub)
      (match b
        [(AstBinSub) true]
        [_ false])]
    [(AstBinMul)
      (match b
        [(AstBinMul) true]
        [_ false])]
    [(AstBinDiv)
      (match b
        [(AstBinDiv) true]
        [_ false])]
    [(AstBinMod)
      (match b
        [(AstBinMod) true]
        [_ false])]
    [(AstBinEq)
      (match b
        [(AstBinEq) true]
        [_ false])]
    [(AstBinNe)
      (match b
        [(AstBinNe) true]
        [_ false])]
    [(AstBinLt)
      (match b
        [(AstBinLt) true]
        [_ false])]
    [(AstBinLe)
      (match b
        [(AstBinLe) true]
        [_ false])]
    [(AstBinGt)
      (match b
        [(AstBinGt) true]
        [_ false])]
    [(AstBinGe)
      (match b
        [(AstBinGe) true]
        [_ false])]
    [(AstBinAnd)
      (match b
        [(AstBinAnd) true]
        [_ false])]
    [(AstBinOr)
      (match b
        [(AstBinOr) true]
        [_ false])]
    [(AstBinBitAnd)
      (match b
        [(AstBinBitAnd) true]
        [_ false])]
    [(AstBinBitOr)
      (match b
        [(AstBinBitOr) true]
        [_ false])]
    [(AstBinBitXor)
      (match b
        [(AstBinBitXor) true]
        [_ false])]
    [(AstBinShl)
      (match b
        [(AstBinShl) true]
        [_ false])]
    [(AstBinShr)
      (match b
        [(AstBinShr) true]
        [_ false])]))

(define (ctfe-unop-eq [a : AstUnOp] [b : AstUnOp]) : bool
  (match a
    [(AstUnNeg)
      (match b
        [(AstUnNeg) true]
        [_ false])]
    [(AstUnNot)
      (match b
        [(AstUnNot) true]
        [_ false])]
    [(AstUnBitNot)
      (match b
        [(AstUnBitNot) true]
        [_ false])]))

;; CONSTRUCTORS ----------------------------------------------------------------
(define (ctfe-expr-literal [lit : AstLiteral]) : i64
  (ast-node-push (AstExprLiteral lit)))

(define (ctfe-expr-bool [b : bool]) : i64
  (ast-node-push (AstExprLiteral (AstLitBool b))))

(define (ctfe-expr-var [name : String]) : i64
  (ast-node-push (AstExprVar (intern name))))

(define (ctfe-expr-if [cond : i64] [then-branch : i64] [else-branch : i64]) : i64
  (ast-expr-if cond then-branch else-branch))

(define (ctfe-expr-call [func : i64] [args : AstExprList]) : i64
  (ast-expr-call func args))

(define (ctfe-expr-begin [exprs : AstExprList]) : i64
  (ast-node-push (AstExprBegin exprs)))

;; LIST UTILITIES --------------------------------------------------------------
(define (ctfe-expr-list-empty) : AstExprList
  AstExprNil)

(define (ctfe-expr-list-singleton [e : i64]) : AstExprList
  (ast-expr-cons e AstExprNil))

(define (ctfe-expr-list-cons [head : i64] [tail : AstExprList]) : AstExprList
  (ast-expr-cons head tail))

(define (ctfe-expr-list-length [lst : AstExprList]) : i64
  (match lst
    [(AstExprNil) 0]
    [(AstExprCons _ rest)
      (let
        [rest : AstExprList (box-get rest)]
        (+ 1 (ctfe-expr-list-length rest)))]))

(define (ctfe-expr-list-empty? [lst : AstExprList]) : bool
  (match lst
    [(AstExprNil) true]
    [_ false]))

(define (ctfe-expr-clause-first [clause : AstExprClause]) : i64
  (struct-get clause first))

(define (ctfe-expr-clause-second [clause : AstExprClause]) : i64
  (struct-get clause second))

(define (ctfe-expr-clause-list-length [lst : AstExprClauseList]) : i64
  (match lst
    [(AstExprClauseNil) 0]
    [(AstExprClauseCons _ rest)
      (let
        [rest : AstExprClauseList (box-get rest)]
        (+ 1 (ctfe-expr-clause-list-length rest)))]))

(define (ctfe-expr-clause-list-empty? [lst : AstExprClauseList]) : bool
  (match lst
    [(AstExprClauseNil) true]
    [_ false]))

(define (ctfe-expr-clause-list-head [lst : AstExprClauseList]) : AstExprClause
  (match lst
    [(AstExprClauseCons head _) head]
    [_
      (ast-expr-clause
        (ast-node-push (AstExprLiteral (AstLitUnit)))
        (ast-node-push (AstExprLiteral (AstLitUnit))))]))

(define (ctfe-expr-clause-list-tail [lst : AstExprClauseList]) : AstExprClauseList
  (match lst
    [(AstExprClauseCons _ tail)
      (let
        [tail : AstExprClauseList (box-get tail)]
        tail)]
    [_ AstExprClauseNil]))

(define (ctfe-expr-clause-list-nth [lst : AstExprClauseList] [index : i64]) : AstExprClause
  (match lst
    [(AstExprClauseCons head tail)
      (if (= index 0)
        head
        (ctfe-expr-clause-list-nth (box-get tail) (- index 1)))]
    [_
      (ast-expr-clause
        (ast-node-push (AstExprLiteral (AstLitUnit)))
        (ast-node-push (AstExprLiteral (AstLitUnit))))]))

(define (ctfe-expr-clause-as-bracket-expr [clause : AstExprClause]) : i64
  (ast-expr-bracket-clause
    (ast-expr-cons
      (ctfe-expr-clause-first clause)
      (ast-expr-cons (ctfe-expr-clause-second clause) AstExprNil))))

(define (ctfe-expr-clause-list->expr-list [lst : AstExprClauseList]) : AstExprList
  (match lst
    [(AstExprClauseNil) AstExprNil]
    [(AstExprClauseCons head rest)
      (ast-expr-cons
        (ctfe-expr-clause-as-bracket-expr head)
        (ctfe-expr-clause-list->expr-list (box-get rest)))]))

;; INSPECTORS (predicates) -----------------------------------------------------
(define (ctfe-expr-literal? [e : i64]) : bool
  (match (ast-node-get e)
    [(AstExprLiteral _) true]
    [_ false]))

(define (ctfe-expr-bool? [e : i64]) : bool
  (match (ast-node-get e)
    [(AstExprLiteral lit)
      (match lit
        [(AstLitBool _) true]
        [_ false])]
    [_ false]))

(define (ctfe-expr-bool-value [e : i64]) : bool
  (match (ast-node-get e)
    [(AstExprLiteral lit)
      (match lit
        [(AstLitBool b) b]
        [_ false])]
    [_ false]))

(define (ctfe-expr-var? [e : i64]) : bool
  (match (ast-node-get e)
    [(AstExprVar _) true]
    [_ false]))

(define (ctfe-expr-if? [e : i64]) : bool
  (match (ast-node-get e)
    [(AstExprIf _ _ _) true]
    [_ false]))

(define (ctfe-expr-call? [e : i64]) : bool
  (match (ast-node-get e)
    [(AstExprCall _ _) true]
    [_ false]))

;; INSPECTORS (extractors) -----------------------------------------------------
(define (ctfe-expr-literal-value [e : i64]) : AstLiteral
  (match (ast-node-get e)
    [(AstExprLiteral lit) lit]
    [_ (AstLitUnit)]))

(define (ctfe-expr-var-name [e : i64]) : String
  (match (ast-node-get e)
    [(AstExprVar name) (intern-str name)]
    [_ ""]))

(define (ctfe-expr-if-cond [e : i64]) : i64
  (match (ast-node-get e)
    [(AstExprIf c _ _) c]
    [_ (ast-node-push (AstExprLiteral (AstLitUnit)))]))

(define (ctfe-expr-if-then [e : i64]) : i64
  (match (ast-node-get e)
    [(AstExprIf _ t _) t]
    [_ (ast-node-push (AstExprLiteral (AstLitUnit)))]))

(define (ctfe-expr-if-else [e : i64]) : i64
  (match (ast-node-get e)
    [(AstExprIf _ _ el) el]
    [_ (ast-node-push (AstExprLiteral (AstLitUnit)))]))

(define (ctfe-expr-call-func [e : i64]) : i64
  (match (ast-node-get e)
    [(AstExprCall f _) f]
    [_ (ast-node-push (AstExprLiteral (AstLitUnit)))]))

(define (ctfe-expr-call-args [e : i64]) : AstExprList
  (match (ast-node-get e)
    [(AstExprCall _ args) args]
    [_ AstExprNil]))

(define (ctfe-expr-list-head [lst : AstExprList]) : i64
  (match lst
    [(AstExprCons head _) head]
    [_ (ast-node-push (AstExprLiteral (AstLitUnit)))]))

(define (ctfe-expr-list-tail [lst : AstExprList]) : AstExprList
  (match lst
    [(AstExprCons _ tail)
      (let
        [tail : AstExprList (box-get tail)]
        tail)]
    [_ AstExprNil]))

(define (ctfe-expr-list-nth [lst : AstExprList] [index : i64]) : i64
  (match lst
    [(AstExprCons head tail)
      (if (= index 0)
        head
        (ctfe-expr-list-nth (box-get tail) (- index 1)))]
    [_ (ast-node-push (AstExprLiteral (AstLitUnit)))]))

;; --- folding ----------------------------------------------------------------
;; Convert a folded compile-time value into the AST literal that lowering then
;; materializes through the ordinary literal path. Expr / ExprList values are
;; compile-time only and have no runtime literal form; this is used for scalar
;; value lowering.
(define (ctfe-value-to-literal [value : CompilerCtfeValue]) : AstLiteral
  (match value
    [(CtfeI64 n) (AstLitInt n)]
    [(CtfeF64 n) (AstLitFloat (compiler-float-format-f64 n))]
    [(CtfeF32 n)
      (AstLitFloat
        (compiler-float-format-f64 (compiler-float-round-f32-as-f64 n)))]
    [(CtfeBool b) (AstLitBool b)]
    [(CtfeChar c) (AstLitChar c)]
    [(CtfeString text) (AstLitString text)]
    [(CtfeUnit) (AstLitUnit)]
    [(CtfeType _) (AstLitUnit)]
    [(CtfeExpr _ _) (AstLitUnit)]
    [(CtfeExprList _) (AstLitUnit)]
    [(CtfeExprClause _) (AstLitUnit)]
    [(CtfeExprClauseList _) (AstLitUnit)]))

(define (ctfe-value-to-literal-for-type
  [value : CompilerCtfeValue]
  [ty : AstType]) : AstLiteral
  (match ty
    [(AstTyF32)
      (match value
        [(CtfeF64 n)
          (AstLitFloat
            (compiler-float-format-f64 (compiler-float-round-f32-as-f64 n)))]
        [_ (ctfe-value-to-literal value)])]
    [(AstTyRegion _ inner)
      (ctfe-value-to-literal-for-type value (ty-node-get inner))]
    [_ (ctfe-value-to-literal value)]))

(define (ctfe-type-list-eq [a : AstTypeList] [b : AstTypeList]) : bool
  (match a
    [(AstTypeNil)
      (match b
        [(AstTypeNil) true]
        [_ false])]
    [(AstTypeCons ah at)
      (let
        [ah : AstType (ty-node-get ah)]
        [at : AstTypeList (box-get at)]
        (match b
          [(AstTypeCons bh bt)
            (let
              [bh : AstType (ty-node-get bh)]
              [bt : AstTypeList (box-get bt)]
              (and (ctfe-type-eq ah bh) (ctfe-type-list-eq at bt)))]
          [_ false]))]))

(define (ctfe-type-eq [a : AstType] [b : AstType]) : bool
  (match a
    [(AstTyI64)
      (match b
        [(AstTyI64) true]
        [_ false])]
    [(AstTyI32)
      (match b
        [(AstTyI32) true]
        [_ false])]
    [(AstTyI16)
      (match b
        [(AstTyI16) true]
        [_ false])]
    [(AstTyI8)
      (match b
        [(AstTyI8) true]
        [_ false])]
    [(AstTyU64)
      (match b
        [(AstTyU64) true]
        [_ false])]
    [(AstTyU32)
      (match b
        [(AstTyU32) true]
        [_ false])]
    [(AstTyU16)
      (match b
        [(AstTyU16) true]
        [_ false])]
    [(AstTyU8)
      (match b
        [(AstTyU8) true]
        [_ false])]
    [(AstTyF64)
      (match b
        [(AstTyF64) true]
        [_ false])]
    [(AstTyF32)
      (match b
        [(AstTyF32) true]
        [_ false])]
    [(AstTyBool)
      (match b
        [(AstTyBool) true]
        [_ false])]
    [(AstTyChar)
      (match b
        [(AstTyChar) true]
        [_ false])]
    [(AstTyString)
      (match b
        [(AstTyString) true]
        [_ false])]
    [(AstTyStr)
      (match b
        [(AstTyStr) true]
        [_ false])]
    [(AstTyUnit)
      (match b
        [(AstTyUnit) true]
        [_ false])]
    [(AstTyNever)
      (match b
        [(AstTyNever) true]
        [_ false])]
    [(AstTyExpr)
      (match b
        [(AstTyExpr) true]
        [_ false])]
    [(AstTyExprList)
      (match b
        [(AstTyExprList) true]
        [_ false])]
    [(AstTyFunc a-args a-ret)
      (match b
        [(AstTyFunc b-args b-ret)
          (and
            (ctfe-type-list-eq a-args b-args)
            (ctfe-type-eq (ty-node-get a-ret) (ty-node-get b-ret)))]
        [_ false])]
    [(AstTyTuple a-elems)
      (match b
        [(AstTyTuple b-elems) (ctfe-type-list-eq a-elems b-elems)]
        [_ false])]
    [(AstTyArray a-elem a-count)
      (match b
        [(AstTyArray b-elem b-count)
          (and
            (= a-count b-count)
            (ctfe-type-eq (ty-node-get a-elem) (ty-node-get b-elem)))]
        [_ false])]
    [(AstTyDynArray a-elem)
      (match b
        [(AstTyDynArray b-elem)
          (ctfe-type-eq (ty-node-get a-elem) (ty-node-get b-elem))]
        [_ false])]
    [(AstTyBox a-elem)
      (match b
        [(AstTyBox b-elem)
          (ctfe-type-eq (ty-node-get a-elem) (ty-node-get b-elem))]
        [_ false])]
    [(AstTyPtr a-elem)
      (match b
        [(AstTyPtr b-elem)
          (ctfe-type-eq (ty-node-get a-elem) (ty-node-get b-elem))]
        [_ false])]
    [(AstTyMutPtr a-elem)
      (match b
        [(AstTyMutPtr b-elem)
          (ctfe-type-eq (ty-node-get a-elem) (ty-node-get b-elem))]
        [_ false])]
    [(AstTyRef a-region a-inner)
      (match b
        [(AstTyRef b-region b-inner)
          (and
            (string-eq a-region b-region)
            (ctfe-type-eq (ty-node-get a-inner) (ty-node-get b-inner)))]
        [_ false])]
    [(AstTyMutRef a-region a-inner)
      (match b
        [(AstTyMutRef b-region b-inner)
          (and
            (string-eq a-region b-region)
            (ctfe-type-eq (ty-node-get a-inner) (ty-node-get b-inner)))]
        [_ false])]
    [(AstTyRegion a-region a-inner)
      (match b
        [(AstTyRegion b-region b-inner)
          (and
            (string-eq a-region b-region)
            (ctfe-type-eq (ty-node-get a-inner) (ty-node-get b-inner)))]
        [_ false])]
    [(AstTyEnum a-name)
      (match b
        [(AstTyEnum b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyEnumArgs a-name a-lifetimes)
      (match b
        [(AstTyEnumArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ctfe-lifetime-list-eq a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyStruct a-name)
      (match b
        [(AstTyStruct b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyStructArgs a-name a-lifetimes)
      (match b
        [(AstTyStructArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ctfe-lifetime-list-eq a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyVar a-name)
      (match b
        [(AstTyVar b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyVarArgs a-name a-lifetimes)
      (match b
        [(AstTyVarArgs b-name b-lifetimes)
          (and
            (= a-name b-name)
            (ctfe-lifetime-list-eq a-lifetimes b-lifetimes))]
        [_ false])]))

(define (compiler-ctfe-type-literal-ok?) : bool
  (let
    [want : AstType (ast-ty-array (AstTyI64) 4)]
    (match (compiler-ctfe-eval
      (AstExprTypeLiteral want)
      (ctfe-env-empty)
      (ctfe-fuel-limit))
      [(OkCtfe value _)
        (match value
          [(CtfeType actual)
            (and
              (ctfe-type-eq actual want)
              (string-eq (ctfe-value-type-name value) "type"))]
          [_ false])]
      [(ErrCtfe _) false])))

(define (compiler-ctfe-type-comparison-ok?) : bool
  (match (compiler-ctfe-eval
    (AstExprBinary
      (AstBinEq)
      (ast-node-push (AstExprTypeLiteral (AstTyI64)))
      (ast-node-push (AstExprTypeLiteral (AstTyI64))))
    (ctfe-env-empty)
    (ctfe-fuel-limit))
    [(OkCtfe same _)
      (match same
        [(CtfeBool same-ok)
          (match (compiler-ctfe-eval
            (AstExprBinary
              (AstBinEq)
              (ast-node-push (AstExprTypeLiteral (AstTyI64)))
              (ast-node-push (AstExprTypeLiteral (AstTyI32))))
            (ctfe-env-empty)
            (ctfe-fuel-limit))
            [(OkCtfe different _)
              (match different
                [(CtfeBool different-ok) (and same-ok (not different-ok))]
                [_ false])]
            [(ErrCtfe _) false])]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-raw-pointer-type-comparison-ok?) : bool
  (match (compiler-ctfe-eval
    (AstExprBinary
      (AstBinEq)
      (ast-node-push (AstExprTypeLiteral (ast-ty-ptr (AstTyI64))))
      (ast-node-push (AstExprTypeLiteral (ast-ty-ptr (AstTyI64)))))
    (ctfe-env-empty)
    (ctfe-fuel-limit))
    [(OkCtfe same _)
      (match same
        [(CtfeBool same-ok)
          (match (compiler-ctfe-eval
            (AstExprBinary
              (AstBinEq)
              (ast-node-push (AstExprTypeLiteral (ast-ty-ptr (AstTyI64))))
              (ast-node-push (AstExprTypeLiteral (ast-ty-mut-ptr (AstTyI64)))))
            (ctfe-env-empty)
            (ctfe-fuel-limit))
            [(OkCtfe different _)
              (match different
                [(CtfeBool different-ok) (and same-ok (not different-ok))]
                [_ false])]
            [(ErrCtfe _) false])]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-call1 [name : String] [arg : i64]) : i64
  (ast-expr-call
    (ast-node-push (AstExprVar (intern name)))
    (ast-expr-cons arg AstExprNil)))

(define (compiler-ctfe-call2 [name : String] [a : i64] [b : i64]) : i64
  (ast-expr-call
    (ast-node-push (AstExprVar (intern name)))
    (ast-expr-cons a (ast-expr-cons b AstExprNil))))

(define (compiler-ctfe-call3 [name : String] [a : i64] [b : i64] [c : i64]) : i64
  (ast-expr-call
    (ast-node-push (AstExprVar (intern name)))
    (ast-expr-cons a (ast-expr-cons b (ast-expr-cons c AstExprNil)))))

(define (compiler-ctfe-eval-i64-ok? [expr : i64] [env : CtfeEnv] [want : i64]) : bool
  (match (compiler-ctfe-eval (ast-node-get expr) env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeI64 actual) (= actual want)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-f64-ok? [expr : i64] [env : CtfeEnv] [want : f64]) : bool
  (match (compiler-ctfe-eval (ast-node-get expr) env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeF64 actual) (= actual want)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-f32-ok? [expr : i64] [env : CtfeEnv] [want : f64]) : bool
  (match (compiler-ctfe-eval (ast-node-get expr) env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeF32 actual) (= actual want)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-bool-ok? [expr : i64] [env : CtfeEnv] [want : bool]) : bool
  (match (compiler-ctfe-eval (ast-node-get expr) env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeBool actual)
          (if want
            actual
            (not actual))]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-string-ok?
  [expr : i64]
  [env : CtfeEnv]
  [want : String]) : bool
  (match (compiler-ctfe-eval (ast-node-get expr) env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeString actual) (string-eq actual want)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-type-ok?
  [expr : i64]
  [env : CtfeEnv]
  [want : AstType]) : bool
  (match (compiler-ctfe-eval (ast-node-get expr) env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeType actual) (ctfe-type-eq actual want)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-error-ok?
  [expr : i64]
  [env : CtfeEnv]
  [want : String]) : bool
  (match (compiler-ctfe-eval (ast-node-get expr) env (ctfe-fuel-limit))
    [(ErrCtfe diag) (string-eq (compiler-diagnostic-message diag) want)]
    [(OkCtfe _ _) false]))

(define (compiler-ctfe-f64-ok?) : bool
  (let
    [one-five : i64 (ast-node-push (AstExprLiteral (AstLitFloat "1.5")))]
    [two-quarter : i64 (ast-node-push (AstExprLiteral (AstLitFloat "2.25")))]
    [zero : i64 (ast-node-push (AstExprLiteral (AstLitFloat "0.0")))]
    [one-f32 : i64 (ast-expr-cast one-five (AstTyF32))]
    [zero-f32 : i64 (ast-expr-cast zero (AstTyF32))]
    [sum-f32 : i64 (ast-node-push (AstExprBinary (AstBinAdd) one-f32 zero-f32))]
    [neg-f32 : i64 (ast-node-push (AstExprUnary (AstUnNeg) sum-f32))]
    [wide-f32 : i64 (ast-expr-cast one-f32 (AstTyF64))]
    [sum : i64 (ast-node-push (AstExprBinary (AstBinAdd) one-five two-quarter))]
    [neg : i64 (ast-node-push (AstExprUnary (AstUnNeg) sum))]
    [lt : i64
      (ast-node-push
        (AstExprBinary
          (AstBinLt)
          sum
          (ast-node-push (AstExprLiteral (AstLitFloat "4.0")))))]
    [div-zero : i64 (ast-node-push (AstExprBinary (AstBinDiv) one-five zero))]
    [env : CtfeEnv (ctfe-env-empty)]
    (and
      (compiler-ctfe-eval-f64-ok? one-five env 1.5)
      (compiler-ctfe-eval-f64-ok? sum env 3.75)
      (compiler-ctfe-eval-f64-ok? neg env -3.75)
      (compiler-ctfe-eval-f32-ok? one-f32 env 1.5)
      (compiler-ctfe-eval-f32-ok? sum-f32 env 1.5)
      (compiler-ctfe-eval-f32-ok? neg-f32 env -1.5)
      (compiler-ctfe-eval-f64-ok? wide-f32 env 1.5)
      (compiler-ctfe-eval-bool-ok? lt env true)
      (compiler-ctfe-eval-error-ok?
        div-zero
        env
        "float division by zero in comptime"))))

(define (compiler-ctfe-layout-query-ok?) : bool
  (let
    [packet-ty : i64
      (ast-node-push (AstExprTypeLiteral (AstTyVar (intern "Packet"))))]
    [box-ty : i64
      (ast-node-push (AstExprTypeLiteral (AstTyVar (intern "Box"))))]
    [choice-ty : i64
      (ast-node-push (AstExprTypeLiteral (AstTyVar (intern "Choice"))))]
    [env : CtfeEnv
      (ctfe-env-with-layouts
        (CtfeLayoutInfoCons
          (CtfeLayoutInfo
            "Packet"
            true
            16
            8
            (CtfeLayoutFieldCons
              (CtfeLayoutField "tag" 0)
              (box
                (CtfeLayoutFieldCons
                  (CtfeLayoutField "count" 8)
                  (box CtfeLayoutFieldNil)))))
          (box
            (CtfeLayoutInfoCons
              (CtfeLayoutInfo
                "Box"
                true
                8
                8
                (CtfeLayoutFieldCons
                  (CtfeLayoutField "x" 0)
                  (box CtfeLayoutFieldNil)))
              (box
                (CtfeLayoutInfoCons
                  (CtfeLayoutInfo "Choice" false 24 8 CtfeLayoutFieldNil)
                  (box CtfeLayoutInfoNil)))))))]
    [ok : bool true]
    (begin
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "size-of" packet-ty)
        env
        16)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "align-of" packet-ty)
        env
        8)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call2
          "offset-of"
          packet-ty
          (ast-node-push (AstExprVar (intern "count"))))
        env
        8)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "size-of" box-ty)
        env
        8)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call2
          "offset-of"
          box-ty
          (ast-node-push (AstExprVar (intern "x"))))
        env
        0)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "size-of" choice-ty)
        env
        24)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "align-of" choice-ty)
        env
        8)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-error-ok?
        (compiler-ctfe-call2
          "offset-of"
          choice-ty
          (ast-node-push (AstExprVar (intern "tag"))))
        env
        "offset-of requires struct layout type")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-error-ok?
        (compiler-ctfe-call2
          "offset-of"
          packet-ty
          (ast-node-push (AstExprVar (intern "missing"))))
        env
        "offset-of unknown field missing")
        unit
        (set! ok false))
      ok)))

(define (compiler-ctfe-reflection-env) : CtfeEnv
  (ctfe-env-with-reflections
    (CtfeReflectInfoCons
      (CtfeReflectStruct
        "Point"
        ""
        "Point"
        (CtfeReflectFieldCons
          (CtfeReflectField "x" (AstTyI64))
          (box
            (CtfeReflectFieldCons
              (CtfeReflectField "flag" (AstTyBool))
              (box CtfeReflectFieldNil)))))
      (box
        (CtfeReflectInfoCons
          (CtfeReflectEnum
            "Maybe"
            ""
            "Maybe"
            (CtfeReflectVariantCons
              (CtfeReflectVariant "None" AstTypeNil)
              (box
                (CtfeReflectVariantCons
                  (CtfeReflectVariant
                    "Some"
                    (ast-type-cons (AstTyString) AstTypeNil))
                  (box CtfeReflectVariantNil)))))
          (box CtfeReflectInfoNil))))))

(define (compiler-ctfe-reflection-query-ok?) : bool
  (let
    [env : CtfeEnv (compiler-ctfe-reflection-env)]
    [point-ty : i64
      (ast-node-push (AstExprTypeLiteral (AstTyVar (intern "Point"))))]
    [maybe-ty : i64
      (ast-node-push (AstExprTypeLiteral (AstTyVar (intern "Maybe"))))]
    [array-ty : i64
      (ast-node-push (AstExprTypeLiteral (ast-ty-array (AstTyI64) 4)))]
    [dyn-array-ty : i64
      (ast-node-push (AstExprTypeLiteral (ast-ty-dyn-array (AstTyBool))))]
    [str-ref-ty : i64
      (ast-node-push (AstExprTypeLiteral (ast-ty-ref "r" (AstTyStr))))]
    [fn-ty : i64
      (ast-node-push
        (AstExprTypeLiteral
          (ast-ty-func
            (ast-type-cons (AstTyI64) (ast-type-cons (AstTyBool) AstTypeNil))
            (AstTyString))))]
    [ok : bool true]
    (begin
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call1 "type-kind" point-ty)
        env
        "struct")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call1
          "type-key"
          (ast-node-push (AstExprTypeLiteral (AstTyI64))))
        env
        "i64")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call1 "type-key" str-ref-ty)
        env
        "ref_r_str")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call1 "type-nominal-name" point-ty)
        env
        "Point")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "struct-field-count" point-ty)
        env
        2)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call2
          "struct-field-name"
          point-ty
          (ast-node-push (AstExprLiteral (AstLitInt 1))))
        env
        "flag")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call2
          "struct-field-type"
          point-ty
          (ast-node-push (AstExprLiteral (AstLitInt 0))))
        env
        (AstTyI64))
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "enum-variant-count" maybe-ty)
        env
        2)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call2
          "enum-variant-name"
          maybe-ty
          (ast-node-push (AstExprLiteral (AstLitInt 1))))
        env
        "Some")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call2
          "enum-variant-payload-count"
          maybe-ty
          (ast-node-push (AstExprLiteral (AstLitInt 1))))
        env
        1)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call3
          "enum-variant-payload-type"
          maybe-ty
          (ast-node-push (AstExprLiteral (AstLitInt 1)))
          (ast-node-push (AstExprLiteral (AstLitInt 0))))
        env
        (AstTyString))
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call1 "array-element-type" array-ty)
        env
        (AstTyI64))
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "array-length" array-ty)
        env
        4)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-bool-ok?
        (compiler-ctfe-call1 "array-dynamic?" dyn-array-ty)
        env
        true)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "function-param-count" fn-ty)
        env
        2)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call2
          "function-param-type"
          fn-ty
          (ast-node-push (AstExprLiteral (AstLitInt 1))))
        env
        (AstTyBool))
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call1 "function-return-type" fn-ty)
        env
        (AstTyString))
        unit
        (set! ok false))
      ok)))

;; --- self-tests (#1137 additions) -------------------------------------------
;; Basic round-trip: build an `if` expression from bool literal constructors,
;; compare it structurally, extract its parts, and verify list ops.
;; Flat-AST test helper: the #1137 self-tests build exprs with i64-returning
;; constructors; ctfe-expr-eq takes AstExpr, so wrap node ids for the tests.
(define (ctfe-test-expr-eq [a : i64] [b : i64]) : bool
  (ctfe-expr-eq (ast-node-get a) (ast-node-get b)))

(define (compiler-ctfe-expr-eq-ok?) : bool
  (let
    [true-lit : i64 (ctfe-expr-bool true)]
    [false-lit : i64 (ctfe-expr-bool false)]
    [var-x : i64 (ctfe-expr-var "x")]
    [if1 : i64 (ctfe-expr-if var-x true-lit false-lit)]
    [if2 : i64 (ctfe-expr-if var-x true-lit false-lit)]
    [if3 : i64 (ctfe-expr-if true-lit var-x false-lit)]
    (and
      (ctfe-test-expr-eq if1 if2)
      (not (ctfe-test-expr-eq if1 if3))
      (ctfe-expr-if? if1)
      (ctfe-test-expr-eq (ctfe-expr-if-cond if1) var-x)
      (ctfe-test-expr-eq (ctfe-expr-if-then if1) true-lit)
      (ctfe-test-expr-eq (ctfe-expr-if-else if1) false-lit))))

(define (compiler-ctfe-expr-list-ok?) : bool
  (let
    [a : i64 (ctfe-expr-bool true)]
    [b : i64 (ctfe-expr-bool false)]
    [lst1 : AstExprList (ctfe-expr-list-cons a (ctfe-expr-list-singleton b))]
    [lst2 : AstExprList (ctfe-expr-list-cons a (ctfe-expr-list-singleton b))]
    [lst3 : AstExprList (ctfe-expr-list-singleton a)]
    (and
      (ctfe-expr-list-eq lst1 lst2)
      (not (ctfe-expr-list-eq lst1 lst3))
      (= (ctfe-expr-list-length lst1) 2)
      (not (ctfe-expr-list-empty? lst1))
      (ctfe-test-expr-eq (ctfe-expr-list-head lst1) a)
      (ctfe-test-expr-eq (ctfe-expr-list-head (ctfe-expr-list-tail lst1)) b)
      (ctfe-test-expr-eq (ctfe-expr-list-nth lst1 1) b))))

(define (compiler-ctfe-expr-list-fold-sketch-ok?) : bool
  ;; Simulate the core list-recursion a macro transformer does: build a
  ;; right-leaning `if` chain from a list of conditions and a final else.
  (let
    [cond1 : i64 (ctfe-expr-var "a")]
    [cond2 : i64 (ctfe-expr-var "b")]
    [else-expr : i64 (ctfe-expr-bool false)]
    [conds : AstExprList
      (ctfe-expr-list-cons cond1 (ctfe-expr-list-singleton cond2))]
    ;; fold helper: single cond -> (if cond true else)
    [folded1 : i64 (ctfe-expr-if cond2 (ctfe-expr-bool true) else-expr)]
    ;; next: (if cond1 true (if cond2 true else))
    [folded2 : i64 (ctfe-expr-if cond1 (ctfe-expr-bool true) folded1)]
    [expected : i64
      (ctfe-expr-if
        cond1
        (ctfe-expr-bool true)
        (ctfe-expr-if cond2 (ctfe-expr-bool true) else-expr))]
    (ctfe-test-expr-eq folded2 expected)))

(define (compiler-ctfe-checked-expr-constructors-ok?) : bool
  (let
    [true-lit : i64 (ast-node-push (AstExprLiteral (AstLitBool true)))]
    [false-lit : i64 (ast-node-push (AstExprLiteral (AstLitBool false)))]
    [true-expr : i64 (compiler-ctfe-call1 "expr-bool" true-lit)]
    [false-expr : i64 (compiler-ctfe-call1 "expr-bool" false-lit)]
    [spliced-false : i64 (compiler-ctfe-call1 "expr-splice" false-expr)]
    [if-expr : i64
      (compiler-ctfe-call3 "expr-if" true-expr spliced-false true-expr)]
    (match (compiler-ctfe-eval
      (ast-node-get if-expr)
      (ctfe-env-empty)
      (ctfe-fuel-limit))
      [(OkCtfe value _)
        (match value
          [(CtfeExpr node checked-ty)
            (and
              (ctfe-type-eq checked-ty (AstTyBool))
              (ctfe-test-expr-eq node (ast-expr-if true-lit false-lit true-lit)))]
          [_ false])]
      [(ErrCtfe _) false])))

(define (compiler-ctfe-checked-expr-inspectors-ok?) : bool
  (let
    [true-lit : i64 (ast-node-push (AstExprLiteral (AstLitBool true)))]
    [false-lit : i64 (ast-node-push (AstExprLiteral (AstLitBool false)))]
    [true-expr : i64 (compiler-ctfe-call1 "expr-bool" true-lit)]
    [false-expr : i64 (compiler-ctfe-call1 "expr-bool" false-lit)]
    [if-expr : i64
      (compiler-ctfe-call3 "expr-if" true-expr false-expr true-expr)]
    [if-predicate : i64 (compiler-ctfe-call1 "expr-if?" if-expr)]
    [bool-predicate : i64 (compiler-ctfe-call1 "expr-bool?" true-expr)]
    [bool-value : i64 (compiler-ctfe-call1 "expr-bool-value" false-expr)]
    [cond-expr : i64 (compiler-ctfe-call1 "expr-if-cond" if-expr)]
    [then-expr : i64 (compiler-ctfe-call1 "expr-if-then" if-expr)]
    [bad-cond-expr : i64 (compiler-ctfe-call1 "expr-if-cond" true-expr)]
    (and
      (compiler-ctfe-eval-bool-ok? if-predicate (ctfe-env-empty) true)
      (compiler-ctfe-eval-bool-ok? bool-predicate (ctfe-env-empty) true)
      (compiler-ctfe-eval-bool-ok? bool-value (ctfe-env-empty) false)
      (match (compiler-ctfe-eval
        (ast-node-get cond-expr)
        (ctfe-env-empty)
        (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr node checked-ty)
              (and
                (ctfe-type-eq checked-ty (AstTyBool))
                (ctfe-test-expr-eq node true-lit))]
            [_ false])]
        [(ErrCtfe _) false])
      (match (compiler-ctfe-eval
        (ast-node-get then-expr)
        (ctfe-env-empty)
        (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr node checked-ty)
              (and
                (ctfe-type-eq checked-ty (AstTyBool))
                (ctfe-test-expr-eq node false-lit))]
            [_ false])]
        [(ErrCtfe _) false])
      (compiler-ctfe-eval-error-ok?
        bad-cond-expr
        (ctfe-env-empty)
        "expr-if-cond expects if Expr"))))

(define (compiler-ctfe-checked-expr-rejects-non-bool-cond-ok?) : bool
  (let
    [int-expr-value : CompilerCtfeValue
      (CtfeExpr (ast-node-push (AstExprLiteral (AstLitInt 1))) (AstTyI64))]
    [env : CtfeEnv (ctfe-env-extend (ctfe-env-empty) "n" int-expr-value)]
    [spliced-int : i64
      (compiler-ctfe-call1
        "expr-splice"
        (ast-node-push (AstExprVar (intern "n"))))]
    [true-expr : i64
      (compiler-ctfe-call1
        "expr-bool"
        (ast-node-push (AstExprLiteral (AstLitBool true))))]
    [if-expr : i64
      (compiler-ctfe-call3 "expr-if" spliced-int true-expr true-expr)]
    (compiler-ctfe-eval-error-ok?
      if-expr
      env
      "expr-if condition must produce bool")))

(define (compiler-ctfe-quote-syntax-ok?) : bool
  (let
    [true-lit : i64 (ast-node-push (AstExprLiteral (AstLitBool true)))]
    [false-lit : i64 (ast-node-push (AstExprLiteral (AstLitBool false)))]
    [flag-var : i64 (ast-node-push (AstExprVar (intern "flag")))]
    [spliced : AstExprList
      (ast-expr-cons true-lit (ast-expr-cons false-lit AstExprNil))]
    [env : CtfeEnv
      (ctfe-env-extend
        (ctfe-env-extend
          (ctfe-env-empty)
          "cond"
          (CtfeExpr flag-var (AstTyBool)))
        "xs"
        (CtfeExprList spliced))]
    [quoted-bool : i64 (ast-expr-quote true-lit)]
    [qq-if : i64
      (ast-expr-quasiquote
        (ast-expr-if
          (ast-expr-unquote (ast-node-push (AstExprVar (intern "cond"))))
          true-lit
          false-lit))]
    [qq-splice : i64
      (ast-expr-quasiquote
        (ast-node-push
          (AstExprBegin
            (ast-expr-cons
              (ast-expr-unquote-splicing
                (ast-node-push (AstExprVar (intern "xs"))))
              AstExprNil))))]
    (and
      (match (compiler-ctfe-eval
        (ast-node-get quoted-bool)
        env
        (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr node ty)
              (and
                (ctfe-type-eq ty (AstTyBool))
                (ctfe-test-expr-eq node true-lit))]
            [_ false])]
        [(ErrCtfe _) false])
      (match (compiler-ctfe-eval (ast-node-get qq-if) env (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr node ty)
              (and
                (ctfe-type-eq ty (AstTyBool))
                (ctfe-test-expr-eq
                  node
                  (ast-expr-if flag-var true-lit false-lit)))]
            [_ false])]
        [(ErrCtfe _) false])
      (match (compiler-ctfe-eval (ast-node-get qq-splice) env (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr node _)
              (ctfe-test-expr-eq node (ast-node-push (AstExprBegin spliced)))]
            [_ false])]
        [(ErrCtfe _) false]))))

(define (compiler-ctfe-self-test) : i64
  (begin
    (unless (compiler-ctfe-type-literal-ok?) (return 1))
    (unless (compiler-ctfe-type-comparison-ok?) (return 1))
    (unless (compiler-ctfe-raw-pointer-type-comparison-ok?) (return 1))
    (unless (compiler-ctfe-f64-ok?) (return 1))
    (unless (compiler-ctfe-layout-query-ok?) (return 1))
    (unless (compiler-ctfe-reflection-query-ok?) (return 1))
    (unless (compiler-ctfe-expr-eq-ok?) (return 1))
    (unless (compiler-ctfe-expr-list-ok?) (return 1))
    (unless (compiler-ctfe-expr-list-fold-sketch-ok?) (return 1))
    (unless (compiler-ctfe-checked-expr-constructors-ok?) (return 1))
    (unless (compiler-ctfe-checked-expr-inspectors-ok?) (return 1))
    (unless (compiler-ctfe-checked-expr-rejects-non-bool-cond-ok?) (return 1))
    (unless (compiler-ctfe-quote-syntax-ok?) (return 1))
    42))