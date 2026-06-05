;; compiler_ctfe.tl - Selfhost compile-time function evaluation (CTFE) for
;; expression-position `(comptime expr)` (#719, scalar subset).
;;
;; Ports the scalar slice of the Rust reference `src/ctfe.rs`. Supported
;; compile-time value types are i64, bool, char, unit, type values, and
;; Expr / list aggregates (#1137). f64 compile-time evaluation is intentionally
;; out of scope here (the selfhost compiler stores floats as opaque text with
;; no arithmetic primitives) and is rejected with a diagnostic citing #735.
;;
;; Evaluation is purely functional: the environment is an immutable cons list
;; threaded through recursion, and the step budget ("fuel") is threaded through
;; results so the evaluator stays deterministic without a mutable counter.
(import "../stdlib/io.tl")

(import "compiler_ast_types.tl")

(import "compiler_diagnostic.tl")

;; A compile-time value. Scalar subset from #719; Expr / ExprList aggregates
;; from #1137 for macro transformers.
(defenum CompilerCtfeValue
  (CtfeI64 i64)
  (CtfeBool bool)
  (CtfeChar char)
  (CtfeString String)
  (CtfeUnit)
  (CtfeType AstType)
  ;; A user-facing `Expr` code fragment plus its internally checked produced
  ;; type. The type is not part of the source-level Expr type (#1135).
  (CtfeExpr AstExpr AstType)
  (CtfeExprList AstExprList))

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

(define (ctfe-layout-info-list-add-if-missing
  [layouts : CtfeLayoutInfoList]
  [info : CtfeLayoutInfo]) : CtfeLayoutInfoList
  (if (ctfe-layout-info-list-contains layouts (ctfe-layout-info-name info))
    layouts
    (CtfeLayoutInfoCons info (box layouts))))

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
  (if (ctfe-reflect-info-list-contains infos (ctfe-reflect-info-key info))
    infos
    (CtfeReflectInfoCons info (box infos))))

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
              (CtfeReflectField name ty)
              (box (ctfe-reflect-field-list-from-fields rest)))]))]))

(define (ctfe-reflect-variant-list-from-variants [variants : AstVariantDefList]) : CtfeReflectVariantList
  (match variants
    [(AstVariantDefNil) CtfeReflectVariantNil]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef name payloads)
            (CtfeReflectVariantCons
              (CtfeReflectVariant name payloads)
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
            (ctfe-reflections-from-decls rest next-module infos)]
          [(AstDeclDefStruct name _ _ fields)
            (let
              [key : String
                (if (= (string-length module) 0)
                  name
                  (string-append module (string-append "/" name)))]
              [info : CtfeReflectInfo
                (CtfeReflectStruct
                  key
                  module
                  name
                  (ctfe-reflect-field-list-from-fields fields))]
              (ctfe-reflections-from-decls
                rest
                module
                (ctfe-reflect-info-add-names infos info name module)))]
          [(AstDeclDefStructLifetimes name _ _ _ fields)
            (let
              [key : String
                (if (= (string-length module) 0)
                  name
                  (string-append module (string-append "/" name)))]
              [info : CtfeReflectInfo
                (CtfeReflectStruct
                  key
                  module
                  name
                  (ctfe-reflect-field-list-from-fields fields))]
              (ctfe-reflections-from-decls
                rest
                module
                (ctfe-reflect-info-add-names infos info name module)))]
          [(AstDeclDefEnum name variants)
            (let
              [key : String
                (if (= (string-length module) 0)
                  name
                  (string-append module (string-append "/" name)))]
              [info : CtfeReflectInfo
                (CtfeReflectEnum
                  key
                  module
                  name
                  (ctfe-reflect-variant-list-from-variants variants))]
              (ctfe-reflections-from-decls
                rest
                module
                (ctfe-reflect-info-add-names infos info name module)))]
          [(AstDeclDefEnumLifetimes name _ variants)
            (let
              [key : String
                (if (= (string-length module) 0)
                  name
                  (string-append module (string-append "/" name)))]
              [info : CtfeReflectInfo
                (CtfeReflectEnum
                  key
                  module
                  name
                  (ctfe-reflect-variant-list-from-variants variants))]
              (ctfe-reflections-from-decls
                rest
                module
                (ctfe-reflect-info-add-names infos info name module)))]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDeclDefStruct name _ _ fields)
                  (let
                    [key : String
                      (if (= (string-length module) 0)
                        name
                        (string-append module (string-append "/" name)))]
                    [info : CtfeReflectInfo
                      (CtfeReflectStruct
                        key
                        module
                        name
                        (ctfe-reflect-field-list-from-fields fields))]
                    (ctfe-reflections-from-decls
                      rest
                      module
                      (ctfe-reflect-info-add-names infos info name module)))]
                [(AstDeclDefStructLifetimes name _ _ _ fields)
                  (let
                    [key : String
                      (if (= (string-length module) 0)
                        name
                        (string-append module (string-append "/" name)))]
                    [info : CtfeReflectInfo
                      (CtfeReflectStruct
                        key
                        module
                        name
                        (ctfe-reflect-field-list-from-fields fields))]
                    (ctfe-reflections-from-decls
                      rest
                      module
                      (ctfe-reflect-info-add-names infos info name module)))]
                [(AstDeclDefEnum name variants)
                  (let
                    [key : String
                      (if (= (string-length module) 0)
                        name
                        (string-append module (string-append "/" name)))]
                    [info : CtfeReflectInfo
                      (CtfeReflectEnum
                        key
                        module
                        name
                        (ctfe-reflect-variant-list-from-variants variants))]
                    (ctfe-reflections-from-decls
                      rest
                      module
                      (ctfe-reflect-info-add-names infos info name module)))]
                [(AstDeclDefEnumLifetimes name _ variants)
                  (let
                    [key : String
                      (if (= (string-length module) 0)
                        name
                        (string-append module (string-append "/" name)))]
                    [info : CtfeReflectInfo
                      (CtfeReflectEnum
                        key
                        module
                        name
                        (ctfe-reflect-variant-list-from-variants variants))]
                    (ctfe-reflections-from-decls
                      rest
                      module
                      (ctfe-reflect-info-add-names infos info name module)))]
                [_ (ctfe-reflections-from-decls rest module infos)]))]
          [_ (ctfe-reflections-from-decls rest module infos)]))]))

(define (ctfe-reflections-from-program [program : AstProgram]) : CtfeReflectInfoList
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (ctfe-reflections-from-decls decls "" CtfeReflectInfoNil))]))

;; Result of evaluating a sub-expression: either a value (carrying the remaining
;; fuel) or a diagnostic. Fuel is threaded so each evaluation step decrements a
;; shared budget across all sub-evaluations, matching the spirit of the Rust
;; evaluator's per-step 10_000 fuel cap.
(defenum ResultCtfe
  (OkCtfe CompilerCtfeValue i64)
  (ErrCtfe CompilerDiagnostic))

(defenum ResultCtfeQuoteExpr
  (OkCtfeQuoteExpr AstExpr AstType i64)
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
    [(AstExprBorrow _ _) "borrow"]
    [(AstExprMatch _ _) "match"]
    [(AstExprForeach _ _ _ _ _) "foreach"]
    [(AstExprSpmdReduce _ _ _ _ _ _ _) "spmd-reduce"]
    [(AstExprStructGet _ _) "struct-get"]
    [(AstExprWithRegion _ _) "with-arena"]
    [(AstExprWithEscape _ _) "with-escape"]
    [(AstExprWithResource _ _) "with"]
    [(AstExprTypeLiteral _) "type literal"]
    [(AstExprComptime _) "comptime"]
    [(AstExprQuote _) "quote"]
    [(AstExprQuasiquote _) "quasiquote"]
    [(AstExprUnquote _) "unquote"]
    [(AstExprUnquoteSplicing _) "unquote-splicing"]
    [(AstExprTry _) "try"]
    [(AstExprReturn _) "return"]
    [(AstExprPtrNull _) "ptr-null"]
    [(AstExprPtrNullCheck _) "ptr-null?"]
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
    [(AstExprXgetbv _) "xgetbv"]))

(define (ctfe-value-type-name [value : CompilerCtfeValue]) : String
  (match value
    [(CtfeI64 _) "i64"]
    [(CtfeBool _) "bool"]
    [(CtfeChar _) "char"]
    [(CtfeString _) "String"]
    [(CtfeUnit) "unit"]
    [(CtfeType _) "type"]
    [(CtfeExpr _ _) "Expr"]
    [(CtfeExprList _) "expr-list"]))

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
    [(AstLitFloat _)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "comptime: f64 compile-time evaluation not yet supported (#735)"))]
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
                (CtfeBool (and (ctfe-expr-eq a b) (ctfe-type-eq a-ty b-ty)))
                fuel)]
            [(AstBinNe)
              (OkCtfe
                (CtfeBool
                  (not (and (ctfe-expr-eq a b) (ctfe-type-eq a-ty b-ty))))
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
    [(CtfeReflectStruct key _ _ _) (AstTyStruct key)]
    [(CtfeReflectEnum key _ _ _) (AstTyEnum key)]))

(define (ctfe-reflect-resolve-type-list
  [infos : CtfeReflectInfoList]
  [types : AstTypeList]) : AstTypeList
  (match types
    [(AstTypeNil) AstTypeNil]
    [(AstTypeCons head rest)
      (let
        [head : AstType (box-get head)]
        [rest : AstTypeList (box-get rest)]
        (ast-type-cons
          (ctfe-reflect-resolve-type infos head)
          (ctfe-reflect-resolve-type-list infos rest)))]))

(define (ctfe-reflect-resolve-type [infos : CtfeReflectInfoList] [ty : AstType]) : AstType
  (match ty
    [(AstTyFunc args ret)
      (ast-ty-func
        (ctfe-reflect-resolve-type-list infos args)
        (ctfe-reflect-resolve-type infos (box-get ret)))]
    [(AstTyTuple elems)
      (AstTyTuple (ctfe-reflect-resolve-type-list infos elems))]
    [(AstTyArray elem len)
      (ast-ty-array (ctfe-reflect-resolve-type infos (box-get elem)) len)]
    [(AstTyDynArray elem)
      (ast-ty-dyn-array (ctfe-reflect-resolve-type infos (box-get elem)))]
    [(AstTyBox elem)
      (ast-ty-box (ctfe-reflect-resolve-type infos (box-get elem)))]
    [(AstTyPtr elem)
      (ast-ty-ptr (ctfe-reflect-resolve-type infos (box-get elem)))]
    [(AstTyMutPtr elem)
      (ast-ty-mut-ptr (ctfe-reflect-resolve-type infos (box-get elem)))]
    [(AstTyRef region inner)
      (ast-ty-ref region (ctfe-reflect-resolve-type infos (box-get inner)))]
    [(AstTyMutRef region inner)
      (ast-ty-mut-ref region (ctfe-reflect-resolve-type infos (box-get inner)))]
    [(AstTyRegion region inner)
      (ast-ty-region region (ctfe-reflect-resolve-type infos (box-get inner)))]
    [(AstTyStruct name)
      (match (ctfe-reflect-info-lookup infos name)
        [(CtfeSomeReflectInfo info) (ctfe-reflect-info-canonical-type info)]
        [(CtfeNoReflectInfo) ty])]
    [(AstTyEnum name)
      (match (ctfe-reflect-info-lookup infos name)
        [(CtfeSomeReflectInfo info) (ctfe-reflect-info-canonical-type info)]
        [(CtfeNoReflectInfo) ty])]
    [(AstTyVar name)
      (match (ctfe-reflect-info-lookup infos name)
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
        [head : AstType (box-get head)]
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
            (ctfe-type-key-with-reflections infos (box-get ret)))))]
    [(AstTyTuple elems)
      (string-append "tuple_" (ctfe-type-list-key infos elems))]
    [(AstTyArray elem count)
      (string-append
        "array_"
        (string-append
          (ctfe-type-key-with-reflections infos (box-get elem))
          (string-append "_" (ctfe-int-key count))))]
    [(AstTyDynArray elem)
      (string-append
        "dynarray_"
        (ctfe-type-key-with-reflections infos (box-get elem)))]
    [(AstTyBox elem)
      (string-append
        "box_"
        (ctfe-type-key-with-reflections infos (box-get elem)))]
    [(AstTyPtr elem)
      (string-append
        "ptr_"
        (ctfe-type-key-with-reflections infos (box-get elem)))]
    [(AstTyMutPtr elem)
      (string-append
        "mutptr_"
        (ctfe-type-key-with-reflections infos (box-get elem)))]
    [(AstTyRef region inner)
      (string-append
        "ref_"
        (string-append
          region
          (string-append
            "_"
            (ctfe-type-key-with-reflections infos (box-get inner)))))]
    [(AstTyMutRef region inner)
      (string-append
        "mutref_"
        (string-append
          region
          (string-append
            "_"
            (ctfe-type-key-with-reflections infos (box-get inner)))))]
    [(AstTyRegion region inner)
      (string-append
        "region_"
        (string-append
          region
          (string-append
            "_"
            (ctfe-type-key-with-reflections infos (box-get inner)))))]
    [(AstTyEnum name) (string-append "enum_" name)]
    [(AstTyEnumArgs name lifetimes)
      (string-append
        "enumargs_"
        (string-append
          name
          (string-append "_" (ctfe-lifetime-list-key lifetimes))))]
    [(AstTyStruct name) (string-append "struct_" name)]
    [(AstTyStructArgs name lifetimes)
      (string-append
        "structargs_"
        (string-append
          name
          (string-append "_" (ctfe-lifetime-list-key lifetimes))))]
    [(AstTyVar name) (string-append "var_" name)]
    [(AstTyVarArgs name lifetimes)
      (string-append
        "varargs_"
        (string-append
          name
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
          [head : AstType (box-get head)]
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
        [inner : AstExpr (box-get inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (compiler-ctfe-eval inner env fuel))]
    [(AstExprTypeLiteral ty)
      (OkCtfe
        (CtfeType (ctfe-reflect-resolve-type (ctfe-env-reflections env) ty))
        fuel)]
    [(AstExprLiteral lit) (ctfe-eval-literal lit expr fuel)]
    [(AstExprVar name) (ctfe-eval-var name expr env fuel)]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
        (ctfe-eval-binary op left right expr env fuel))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ctfe-eval-unary op inner expr env fuel))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
        (ctfe-eval-if cond then-branch else-branch env fuel))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (ctfe-eval-let bindings body env fuel))]
    [(AstExprBegin exprs) (ctfe-eval-begin exprs env fuel)]
    [(AstExprUnsafe exprs) (ctfe-eval-begin exprs env fuel)]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
        (ctfe-eval-call func args expr env fuel))]
    [(AstExprQuote template-box)
      (let
        [template : AstExpr (box-get template-box)]
        (ctfe-eval-quote template env fuel false))]
    [(AstExprQuasiquote template-box)
      (let
        [template : AstExpr (box-get template-box)]
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
        [elem-size : i64 (ctfe-type-size layouts (box-get elem))]
        (if (< elem-size 0)
          -1
          (* elem-size count)))]
    [(AstTyDynArray _) 8]
    [(AstTyBox _) 8]
    [(AstTyPtr _) 8]
    [(AstTyMutPtr _) 8]
    [(AstTyRef _ _) 8]
    [(AstTyMutRef _ _) 8]
    [(AstTyRegion _ inner) (ctfe-type-size layouts (box-get inner))]
    [(AstTyEnum _) 8]
    [(AstTyEnumArgs _ _) 8]
    [(AstTyStruct name)
      (match (ctfe-layout-info-lookup layouts name)
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ size _ _) size])]
        [(CtfeNoLayoutInfo) 8])]
    [(AstTyStructArgs name _)
      (match (ctfe-layout-info-lookup layouts name)
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ size _ _) size])]
        [(CtfeNoLayoutInfo) 8])]
    [(AstTyString) 8]
    [(AstTyVar name)
      (match (ctfe-layout-info-lookup layouts name)
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ size _ _) size])]
        [(CtfeNoLayoutInfo) -1])]
    [(AstTyVarArgs name _)
      (match (ctfe-layout-info-lookup layouts name)
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
    [(AstTyArray elem _) (ctfe-type-align layouts (box-get elem))]
    [(AstTyDynArray _) 8]
    [(AstTyBox _) 8]
    [(AstTyPtr _) 8]
    [(AstTyMutPtr _) 8]
    [(AstTyRef _ _) 8]
    [(AstTyMutRef _ _) 8]
    [(AstTyRegion _ inner) (ctfe-type-align layouts (box-get inner))]
    [(AstTyEnum _) 8]
    [(AstTyEnumArgs _ _) 8]
    [(AstTyStruct name)
      (match (ctfe-layout-info-lookup layouts name)
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ _ align _) align])]
        [(CtfeNoLayoutInfo) 8])]
    [(AstTyStructArgs name _)
      (match (ctfe-layout-info-lookup layouts name)
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ _ align _) align])]
        [(CtfeNoLayoutInfo) 8])]
    [(AstTyString) 8]
    [(AstTyVar name)
      (match (ctfe-layout-info-lookup layouts name)
        [(CtfeSomeLayoutInfo info)
          (match info
            [(CtfeLayoutInfo _ _ _ align _) align])]
        [(CtfeNoLayoutInfo) -1])]
    [(AstTyVarArgs name _)
      (match (ctfe-layout-info-lookup layouts name)
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
        [arg : AstExpr (box-get arg)]
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
        [inner : AstExpr (box-get inner-box)]
        (ctfe-offset-field-name inner))]
    [(AstExprVar name) (CtfeSomeFieldName name)]
    [_ (CtfeNoFieldName)]))

(define (ctfe-layout-info-for-type
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : CtfeMaybeLayoutInfo
  (match ty
    [(AstTyStruct name) (ctfe-layout-info-lookup layouts name)]
    [(AstTyStructArgs name _) (ctfe-layout-info-lookup layouts name)]
    [(AstTyEnum name) (ctfe-layout-info-lookup layouts name)]
    [(AstTyEnumArgs name _) (ctfe-layout-info-lookup layouts name)]
    [(AstTyVar name) (ctfe-layout-info-lookup layouts name)]
    [(AstTyRegion _ inner) (ctfe-layout-info-for-type layouts (box-get inner))]
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
        [type-arg : AstExpr (box-get type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons field-arg rest)
            (let
              [field-arg : AstExpr (box-get field-arg)]
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
  (cond
    [(string-eq name "type-kind") true]
    [(string-eq name "type-key") true]
    [(string-eq name "type-nominal-module") true]
    [(string-eq name "type-nominal-name") true]
    [(string-eq name "struct-field-count") true]
    [(string-eq name "struct-field-name") true]
    [(string-eq name "struct-field-type") true]
    [(string-eq name "enum-variant-count") true]
    [(string-eq name "enum-variant-name") true]
    [(string-eq name "enum-variant-payload-count") true]
    [(string-eq name "enum-variant-payload-type") true]
    [(string-eq name "array-element-type") true]
    [(string-eq name "array-length") true]
    [(string-eq name "array-dynamic?") true]
    [(string-eq name "function-param-count") true]
    [(string-eq name "function-param-type") true]
    [else (string-eq name "function-return-type")]))

(define (ctfe-eval-one-type-reflection
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg rest)
      (let
        [type-arg : AstExpr (box-get type-arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (ctfe-eval-type-arg type-arg expr env fuel name)
              [(ErrCtfeTypeArg d) (ErrCtfe d)]
              [(OkCtfeTypeArg ty arg-fuel)
                (let
                  [infos : CtfeReflectInfoList (ctfe-env-reflections env)]
                  (cond
                    [(string-eq name "type-kind")
                      (OkCtfe
                        (CtfeString (ctfe-type-kind-with-reflections infos ty))
                        arg-fuel)]
                    [(string-eq name "type-key")
                      (OkCtfe
                        (CtfeString (ctfe-type-key-with-reflections infos ty))
                        arg-fuel)]
                    [(string-eq name "type-nominal-module")
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
                              "type-nominal-module requires struct or enum type"))])]
                    [(string-eq name "type-nominal-name")
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
                              "type-nominal-name requires struct or enum type"))])]
                    [(string-eq name "struct-field-count")
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
                              "struct-field-count requires struct type"))])]
                    [(string-eq name "enum-variant-count")
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
                              "enum-variant-count requires enum type"))])]
                    [(string-eq name "array-element-type")
                      (match ty
                        [(AstTyArray elem _)
                          (OkCtfe (CtfeType (box-get elem)) arg-fuel)]
                        [(AstTyDynArray elem)
                          (OkCtfe (CtfeType (box-get elem)) arg-fuel)]
                        [_
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "array-element-type requires array type"))])]
                    [(string-eq name "array-length")
                      (match ty
                        [(AstTyArray _ count) (OkCtfe (CtfeI64 count) arg-fuel)]
                        [_
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "array-length requires fixed array type"))])]
                    [(string-eq name "array-dynamic?")
                      (match ty
                        [(AstTyArray _ _) (OkCtfe (CtfeBool false) arg-fuel)]
                        [(AstTyDynArray _) (OkCtfe (CtfeBool true) arg-fuel)]
                        [_
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "array-dynamic? requires array type"))])]
                    [(string-eq name "function-param-count")
                      (match ty
                        [(AstTyFunc params _)
                          (OkCtfe
                            (CtfeI64 (ctfe-type-list-count params))
                            arg-fuel)]
                        [_
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "function-param-count requires function type"))])]
                    [(string-eq name "function-return-type")
                      (match ty
                        [(AstTyFunc _ ret)
                          (OkCtfe (CtfeType (box-get ret)) arg-fuel)]
                        [_
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "function-return-type requires function type"))])]
                    [else (ctfe-unsupported-form expr)]))])]
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
    [(AstTyStruct name) name]
    [(AstTyStructArgs name _) name]
    [(AstTyEnum name) name]
    [(AstTyEnumArgs name _) name]
    [(AstTyVar name) name]
    [(AstTyVarArgs name _) name]
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
        [type-arg : AstExpr (box-get type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons index-arg rest)
            (let
              [index-arg : AstExpr (box-get index-arg)]
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
        [type-arg : AstExpr (box-get type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons index-arg rest)
            (let
              [index-arg : AstExpr (box-get index-arg)]
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
        [type-arg : AstExpr (box-get type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons variant-arg rest1)
            (let
              [variant-arg : AstExpr (box-get variant-arg)]
              [rest1 : AstExprList (box-get rest1)]
              (match rest1
                [(AstExprCons payload-arg rest2)
                  (let
                    [payload-arg : AstExpr (box-get payload-arg)]
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
        [type-arg : AstExpr (box-get type-arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons index-arg rest)
            (let
              [index-arg : AstExpr (box-get index-arg)]
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
  (cond
    [(or
        (string-eq name "type-kind")
        (or
          (string-eq name "type-key")
          (or
            (string-eq name "type-nominal-module")
            (or
              (string-eq name "type-nominal-name")
              (or
                (string-eq name "struct-field-count")
                (or
                  (string-eq name "enum-variant-count")
                  (or
                    (string-eq name "array-element-type")
                    (or
                      (string-eq name "array-length")
                      (or
                        (string-eq name "array-dynamic?")
                        (or
                          (string-eq name "function-param-count")
                          (string-eq name "function-return-type")))))))))))
      (ctfe-eval-one-type-reflection name args expr env fuel)]
    [(or
        (string-eq name "struct-field-name")
        (string-eq name "struct-field-type"))
      (ctfe-eval-struct-field-reflection name args expr env fuel)]
    [(or
        (string-eq name "enum-variant-name")
        (string-eq name "enum-variant-payload-count"))
      (ctfe-eval-enum-variant-reflection name args expr env fuel)]
    [(string-eq name "enum-variant-payload-type")
      (ctfe-eval-enum-payload-type-reflection args expr env fuel)]
    [(string-eq name "function-param-type")
      (ctfe-eval-function-param-type-reflection args expr env fuel)]
    [else (ctfe-unsupported-form expr)]))

(define (ctfe-eval-string-eq-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons left tail)
      (let
        [left : AstExpr (box-get left)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons right rest)
            (let
              [right : AstExpr (box-get right)]
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
        [left : AstExpr (box-get left)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons right rest)
            (let
              [right : AstExpr (box-get right)]
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
        [arg : AstExpr (box-get arg)]
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
        [arg : AstExpr (box-get arg)]
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
        [arg : AstExpr (box-get arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeBool b)
                    (OkCtfe
                      (CtfeExpr (AstExprLiteral (AstLitBool b)) (AstTyBool))
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
        [arg : AstExpr (box-get arg)]
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

(define (ctfe-expr-inspector-name? [name : String]) : bool
  (or
    (string-eq name "expr-bool?")
    (or
      (string-eq name "expr-bool-value")
      (or
        (string-eq name "expr-if?")
        (or
          (string-eq name "expr-if-cond")
          (or (string-eq name "expr-if-then") (string-eq name "expr-if-else")))))))

(define (ctfe-expr-list-inspector-name? [name : String]) : bool
  (or
    (string-eq name "expr-list-empty?")
    (or (string-eq name "expr-list-head") (string-eq name "expr-list-tail"))))

(define (ctfe-eval-expr-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (box-get arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeExpr node ty)
                    (cond
                      [(string-eq name "expr-bool?")
                        (OkCtfe (CtfeBool (ctfe-expr-bool? node)) arg-fuel)]
                      [(string-eq name "expr-bool-value")
                        (if (ctfe-expr-bool? node)
                          (OkCtfe
                            (CtfeBool (ctfe-expr-bool-value node))
                            arg-fuel)
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              "expr-bool-value expects bool literal Expr")))]
                      [(string-eq name "expr-if?")
                        (OkCtfe (CtfeBool (ctfe-expr-if? node)) arg-fuel)]
                      [(ctfe-expr-if? node)
                        (cond
                          [(string-eq name "expr-if-cond")
                            (OkCtfe
                              (CtfeExpr (ctfe-expr-if-cond node) (AstTyBool))
                              arg-fuel)]
                          [(string-eq name "expr-if-then")
                            (OkCtfe
                              (CtfeExpr (ctfe-expr-if-then node) ty)
                              arg-fuel)]
                          [(string-eq name "expr-if-else")
                            (OkCtfe
                              (CtfeExpr (ctfe-expr-if-else node) ty)
                              arg-fuel)]
                          [else (ctfe-unsupported-form expr)])]
                      [else
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            (string-append name " expects if Expr")))])]
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
        [arg : AstExpr (box-get arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (compiler-ctfe-eval arg env fuel)
              [(OkCtfe value arg-fuel)
                (match value
                  [(CtfeExprList nodes)
                    (cond
                      [(string-eq name "expr-list-empty?")
                        (OkCtfe
                          (CtfeBool (ctfe-expr-list-empty? nodes))
                          arg-fuel)]
                      [(ctfe-expr-list-empty? nodes)
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            (string-append name " expects non-empty ExprList")))]
                      [(string-eq name "expr-list-head")
                        (OkCtfe
                          (CtfeExpr (ctfe-expr-list-head nodes) (AstTyExpr))
                          arg-fuel)]
                      [(string-eq name "expr-list-tail")
                        (OkCtfe
                          (CtfeExprList (ctfe-expr-list-tail nodes))
                          arg-fuel)]
                      [else (ctfe-unsupported-form expr)])]
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
                (string-append name " expects exactly one arg")))]))]
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
        [cond-arg : AstExpr (box-get cond-arg)]
        [tail1 : AstExprList (box-get tail1)]
        (match tail1
          [(AstExprCons then-arg tail2)
            (let
              [then-arg : AstExpr (box-get then-arg)]
              [tail2 : AstExprList (box-get tail2)]
              (match tail2
                [(AstExprCons else-arg rest)
                  (let
                    [else-arg : AstExpr (box-get else-arg)]
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
        [inner : AstExpr (box-get inner-box)]
        (ctfe-eval-call inner args expr env fuel))]
    [(AstExprVar name)
      (cond
        [(or (string-eq name "size-of") (string-eq name "align-of"))
          (ctfe-eval-size-align-query name args expr env fuel)]
        [(string-eq name "offset-of")
          (ctfe-eval-offset-query args expr env fuel)]
        [(ctfe-reflection-query-name? name)
          (ctfe-eval-reflection-query name args expr env fuel)]
        [(or (string-eq name "string-eq") (string-eq name "string=?"))
          (ctfe-eval-string-eq-call name args expr env fuel)]
        [(or (string-eq name "string-append") (string-eq name "string-concat"))
          (ctfe-eval-string-append-call name args expr env fuel)]
        [(or (string-eq name "string-length") (string-eq name "length"))
          (ctfe-eval-string-length-call name args expr env fuel)]
        [(string-eq name "int->string")
          (ctfe-eval-int-to-string-call args expr env fuel)]
        [(string-eq name "expr-bool")
          (ctfe-eval-expr-bool-call args expr env fuel)]
        [(string-eq name "expr-splice")
          (ctfe-eval-expr-splice-call args expr env fuel)]
        [(string-eq name "expr-if") (ctfe-eval-expr-if-call args expr env fuel)]
        [(ctfe-expr-inspector-name? name)
          (ctfe-eval-expr-inspector-call name args expr env fuel)]
        [(ctfe-expr-list-inspector-name? name)
          (ctfe-eval-expr-list-inspector-call name args expr env fuel)]
        [else (ctfe-unsupported-form expr)])]
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
              [value-expr : AstExpr (box-get value-expr-box)]
              (match (compiler-ctfe-eval value-expr env fuel)
                [(OkCtfe value value-fuel)
                  (ctfe-eval-let
                    rest
                    body
                    (ctfe-env-extend env name value)
                    value-fuel)]
                [(ErrCtfe diag) (ErrCtfe diag)]))]))]))

;; Evaluate a `begin` to the value of its last expression; an empty body is
;; unit.
(define (ctfe-eval-begin [exprs : AstExprList] [env : CtfeEnv] [fuel : i64]) : ResultCtfe
  (match exprs
    [(AstExprNil) (OkCtfe (CtfeUnit) fuel)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (box-get head)]
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
        [head : AstExpr (box-get head)]
        [rest : AstExprList (box-get rest)]
        (ast-expr-cons head (ctfe-expr-list-append rest right)))]))

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
        [head : AstExpr (box-get head)]
        [rest : AstExprList (box-get rest)]
        (match (ast-expr-unspan head)
          [(AstExprUnquoteSplicing inner-box)
            (let
              [inner : AstExpr (box-get inner-box)]
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
              (AstParam (ctfe-quote-name env name) ty comptime?)
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
    [(AstPatVar name maybe-ty) (AstPatVar (ctfe-quote-name env name) maybe-ty)]
    [(AstPatTuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (ast-pat-tuple (ctfe-quote-pattern-list patterns env)))]
    [(AstPatWildcard) AstPatWildcard]
    [(AstPatBinding name) (AstPatBinding (ctfe-quote-name env name))]
    [(AstPatVariant name args-box)
      (let
        [args : AstPatternList (box-get args-box)]
        (ast-pat-variant name (ctfe-quote-pattern-list args env)))]
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
              [init : AstExpr (box-get init-box)]
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
                          (ast-let-binding
                            (ctfe-quote-name env name)
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
              [init : AstExpr (box-get init-box)]
              [cleanup : AstExpr (box-get cleanup-box)]
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
                              (ast-resource-binding
                                (ctfe-quote-name env name)
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
              [body : AstExpr (box-get body-box)]
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
        [inner : AstExpr (box-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr node ty next-fuel)
            (OkCtfeQuoteExpr (ast-expr-spanned node span) ty next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprLiteral lit)
      (OkCtfeQuoteExpr expr (ctfe-quote-literal-type lit) fuel)]
    [(AstExprVar name)
      (OkCtfeQuoteExpr (AstExprVar (ctfe-quote-name env name)) (AstTyExpr) fuel)]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
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
        [inner : AstExpr (box-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-unary op quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
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
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
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
        [body : AstExpr (box-get body-box)]
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
        [body : AstExpr (box-get body-box)]
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
          (OkCtfeQuoteExpr (AstExprTuple quoted) (AstTyExpr) next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprArray exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted next-fuel)
          (OkCtfeQuoteExpr (AstExprArray quoted) (AstTyExpr) next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprBegin exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted next-fuel)
          (OkCtfeQuoteExpr (AstExprBegin quoted) (AstTyExpr) next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprUnsafe exprs)
      (match (ctfe-quote-expr-list exprs env fuel quasiquote)
        [(OkCtfeQuoteExprList quoted next-fuel)
          (OkCtfeQuoteExpr (AstExprUnsafe quoted) (AstTyExpr) next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [body : AstExpr (box-get body-box)]
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
        [rhs : AstExpr (box-get rhs-box)]
        (match (ctfe-quote-expr rhs env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-rhs _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-set (ctfe-quote-name env name) quoted-rhs)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprAnn inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-ann quoted ty) ty next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-cast quoted ty) ty next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprBorrow lifetime place-box)
      (let
        [place : AstExpr (box-get place-box)]
        (match (ctfe-quote-expr place env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-place _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-borrow lifetime quoted-place)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprMatch scrut-box arms)
      (let
        [scrut : AstExpr (box-get scrut-box)]
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
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [body : AstExpr (box-get body-box)]
        (match (ctfe-quote-expr start env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-start _ start-fuel)
            (match (ctfe-quote-expr end env start-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-end _ end-fuel)
                (match (ctfe-quote-expr body env end-fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-body _ body-fuel)
                    (OkCtfeQuoteExpr
                      (ast-expr-foreach
                        (ctfe-quote-name env index)
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
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [init : AstExpr (box-get init-box)]
        [value : AstExpr (box-get value-box)]
        (match (ctfe-quote-expr start env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-start _ start-fuel)
            (match (ctfe-quote-expr end env start-fuel quasiquote)
              [(OkCtfeQuoteExpr quoted-end _ end-fuel)
                (match (ctfe-quote-expr init env end-fuel quasiquote)
                  [(OkCtfeQuoteExpr quoted-init _ init-fuel)
                    (match (ctfe-quote-expr value env init-fuel quasiquote)
                      [(OkCtfeQuoteExpr quoted-value _ value-fuel)
                        (OkCtfeQuoteExpr
                          (ast-expr-spmd-reduce
                            op
                            (ctfe-quote-name env index)
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
        [inner : AstExpr (box-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-struct-get quoted field)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprTupleRef tuple-expr-box index)
      (let
        [tuple-expr : AstExpr (box-get tuple-expr-box)]
        (match (ctfe-quote-expr tuple-expr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-tuple-ref quoted index)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprMakeArray ty len-box)
      (let
        [len : AstExpr (box-get len-box)]
        (match (ctfe-quote-expr len env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-len _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-make-array ty quoted-len)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
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
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        [value : AstExpr (box-get value-box)]
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
        [array : AstExpr (box-get array-box)]
        [value : AstExpr (box-get value-box)]
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
        [text : AstExpr (box-get text-box)]
        [index : AstExpr (box-get index-box)]
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
            (AstExprWithRegion (ctfe-quote-name env name) quoted-body)
            (AstTyExpr)
            next-fuel)]
        [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (box-get scratch-box)]
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
                (AstExprWithResource quoted-bindings quoted-body)
                (AstTyExpr)
                body-fuel)]
            [(ErrCtfeQuoteExprList diag) (ErrCtfeQuoteExpr diag)])]
        [(ErrCtfeQuoteResourceBindings diag) (ErrCtfeQuoteExpr diag)])]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-box quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-box-get quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted ty next-fuel)
            (OkCtfeQuoteExpr (ast-expr-comptime quoted) ty next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-return quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-try quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrNullCheck ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-ptr-null-check quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-ptr-read quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [value : AstExpr (box-get value-box)]
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
        [ptr : AstExpr (box-get ptr-box)]
        [offset : AstExpr (box-get offset-box)]
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
        [ptr : AstExpr (box-get ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-ptr-cast quoted ty)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (match (ctfe-quote-expr ptr env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-ptr-to-int quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprIntToPtr value-box ty)
      (let
        [value : AstExpr (box-get value-box)]
        (match (ctfe-quote-expr value env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-int-to-ptr quoted ty)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-string-data quoted)
              (AstTyExpr)
              next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [len : AstExpr (box-get len-box)]
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
        [inner : AstExpr (box-get inner-box)]
        (match (ctfe-quote-expr inner env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted _ next-fuel)
            (OkCtfeQuoteExpr (ast-expr-array-data quoted) (AstTyExpr) next-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
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
        [index : AstExpr (box-get index-box)]
        (match (ctfe-quote-expr index env fuel quasiquote)
          [(OkCtfeQuoteExpr quoted-index _ index-fuel)
            (OkCtfeQuoteExpr
              (ast-expr-xgetbv quoted-index)
              (AstTyExpr)
              index-fuel)]
          [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)]))]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (if quasiquote
          (ctfe-eval-unquote-expr inner expr env fuel)
          (match (ctfe-quote-expr inner env fuel quasiquote)
            [(OkCtfeQuoteExpr quoted _ next-fuel)
              (OkCtfeQuoteExpr (ast-expr-unquote quoted) (AstTyExpr) next-fuel)]
            [(ErrCtfeQuoteExpr diag) (ErrCtfeQuoteExpr diag)])))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
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
    [_ (OkCtfeQuoteExpr expr (AstTyExpr) fuel)]))

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

(define (ctfe-expr-eq [a : AstExpr] [b : AstExpr]) : bool
  (match a
    [(AstExprLiteral a-lit)
      (match b
        [(AstExprLiteral b-lit) (ctfe-literal-eq a-lit b-lit)]
        [_ false])]
    [(AstExprVar a-name)
      (match b
        [(AstExprVar b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstExprBinary a-op a-l-box a-r-box)
      (let
        [a-l : AstExpr (box-get a-l-box)]
        [a-r : AstExpr (box-get a-r-box)]
        (match b
          [(AstExprBinary b-op b-l-box b-r-box)
            (let
              [b-l : AstExpr (box-get b-l-box)]
              [b-r : AstExpr (box-get b-r-box)]
              (and
                (ctfe-binop-eq a-op b-op)
                (and (ctfe-expr-eq a-l b-l) (ctfe-expr-eq a-r b-r))))]
          [_ false]))]
    [(AstExprUnary a-op a-in-box)
      (let
        [a-in : AstExpr (box-get a-in-box)]
        (match b
          [(AstExprUnary b-op b-in-box)
            (let
              [b-in : AstExpr (box-get b-in-box)]
              (and (ctfe-unop-eq a-op b-op) (ctfe-expr-eq a-in b-in)))]
          [_ false]))]
    [(AstExprIf a-c-box a-t-box a-e-box)
      (let
        [a-c : AstExpr (box-get a-c-box)]
        [a-t : AstExpr (box-get a-t-box)]
        [a-e : AstExpr (box-get a-e-box)]
        (match b
          [(AstExprIf b-c-box b-t-box b-e-box)
            (let
              [b-c : AstExpr (box-get b-c-box)]
              [b-t : AstExpr (box-get b-t-box)]
              [b-e : AstExpr (box-get b-e-box)]
              (and
                (ctfe-expr-eq a-c b-c)
                (and (ctfe-expr-eq a-t b-t) (ctfe-expr-eq a-e b-e))))]
          [_ false]))]
    [(AstExprCall a-fun-box a-args)
      (let
        [a-fun : AstExpr (box-get a-fun-box)]
        (match b
          [(AstExprCall b-fun-box b-args)
            (let
              [b-fun : AstExpr (box-get b-fun-box)]
              (and (ctfe-expr-eq a-fun b-fun) (ctfe-expr-list-eq a-args b-args)))]
          [_ false]))]
    [(AstExprBegin a-exprs)
      (match b
        [(AstExprBegin b-exprs) (ctfe-expr-list-eq a-exprs b-exprs)]
        [_ false])]
    [(AstExprUnsafe a-exprs)
      (match b
        [(AstExprUnsafe b-exprs) (ctfe-expr-list-eq a-exprs b-exprs)]
        [_ false])]
    [(AstExprAnn a-inner-box a-ty)
      (let
        [a-inner : AstExpr (box-get a-inner-box)]
        (match b
          [(AstExprAnn b-inner-box b-ty)
            (let
              [b-inner : AstExpr (box-get b-inner-box)]
              (and (ctfe-expr-eq a-inner b-inner) (ctfe-type-eq a-ty b-ty)))]
          [_ false]))]
    [(AstExprBorrow a-life a-place-box)
      (let
        [a-place : AstExpr (box-get a-place-box)]
        (match b
          [(AstExprBorrow b-life b-place-box)
            (let
              [b-place : AstExpr (box-get b-place-box)]
              (and
                (ctfe-borrow-lifetime-eq a-life b-life)
                (ctfe-expr-eq a-place b-place)))]
          [_ false]))]
    [(AstExprPtrRead a-ptr-box)
      (let
        [a-ptr : AstExpr (box-get a-ptr-box)]
        (match b
          [(AstExprPtrRead b-ptr-box)
            (let
              [b-ptr : AstExpr (box-get b-ptr-box)]
              (ctfe-expr-eq a-ptr b-ptr))]
          [_ false]))]
    [(AstExprPtrWrite a-ptr-box a-value-box)
      (let
        [a-ptr : AstExpr (box-get a-ptr-box)]
        [a-value : AstExpr (box-get a-value-box)]
        (match b
          [(AstExprPtrWrite b-ptr-box b-value-box)
            (let
              [b-ptr : AstExpr (box-get b-ptr-box)]
              [b-value : AstExpr (box-get b-value-box)]
              (and (ctfe-expr-eq a-ptr b-ptr) (ctfe-expr-eq a-value b-value)))]
          [_ false]))]
    [(AstExprPtrOffset a-ptr-box a-offset-box)
      (let
        [a-ptr : AstExpr (box-get a-ptr-box)]
        [a-offset : AstExpr (box-get a-offset-box)]
        (match b
          [(AstExprPtrOffset b-ptr-box b-offset-box)
            (let
              [b-ptr : AstExpr (box-get b-ptr-box)]
              [b-offset : AstExpr (box-get b-offset-box)]
              (and (ctfe-expr-eq a-ptr b-ptr) (ctfe-expr-eq a-offset b-offset)))]
          [_ false]))]
    [(AstExprPtrCast a-ptr-box a-ty)
      (let
        [a-ptr : AstExpr (box-get a-ptr-box)]
        (match b
          [(AstExprPtrCast b-ptr-box b-ty)
            (let
              [b-ptr : AstExpr (box-get b-ptr-box)]
              (and (ctfe-expr-eq a-ptr b-ptr) (ctfe-type-eq a-ty b-ty)))]
          [_ false]))]
    [(AstExprPtrToInt a-ptr-box)
      (let
        [a-ptr : AstExpr (box-get a-ptr-box)]
        (match b
          [(AstExprPtrToInt b-ptr-box)
            (let
              [b-ptr : AstExpr (box-get b-ptr-box)]
              (ctfe-expr-eq a-ptr b-ptr))]
          [_ false]))]
    [(AstExprIntToPtr a-value-box a-ty)
      (let
        [a-value : AstExpr (box-get a-value-box)]
        (match b
          [(AstExprIntToPtr b-value-box b-ty)
            (let
              [b-value : AstExpr (box-get b-value-box)]
              (and (ctfe-expr-eq a-value b-value) (ctfe-type-eq a-ty b-ty)))]
          [_ false]))]
    [(AstExprBox a-inner-box)
      (let
        [a-inner : AstExpr (box-get a-inner-box)]
        (match b
          [(AstExprBox b-inner-box)
            (let
              [b-inner : AstExpr (box-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprBoxGet a-inner-box)
      (let
        [a-inner : AstExpr (box-get a-inner-box)]
        (match b
          [(AstExprBoxGet b-inner-box)
            (let
              [b-inner : AstExpr (box-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprQuote a-inner-box)
      (let
        [a-inner : AstExpr (box-get a-inner-box)]
        (match b
          [(AstExprQuote b-inner-box)
            (let
              [b-inner : AstExpr (box-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprQuasiquote a-inner-box)
      (let
        [a-inner : AstExpr (box-get a-inner-box)]
        (match b
          [(AstExprQuasiquote b-inner-box)
            (let
              [b-inner : AstExpr (box-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprUnquote a-inner-box)
      (let
        [a-inner : AstExpr (box-get a-inner-box)]
        (match b
          [(AstExprUnquote b-inner-box)
            (let
              [b-inner : AstExpr (box-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprUnquoteSplicing a-inner-box)
      (let
        [a-inner : AstExpr (box-get a-inner-box)]
        (match b
          [(AstExprUnquoteSplicing b-inner-box)
            (let
              [b-inner : AstExpr (box-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprReturn a-inner-box)
      (let
        [a-inner : AstExpr (box-get a-inner-box)]
        (match b
          [(AstExprReturn b-inner-box)
            (let
              [b-inner : AstExpr (box-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprStringData a-inner-box)
      (let
        [a-inner : AstExpr (box-get a-inner-box)]
        (match b
          [(AstExprStringData b-inner-box)
            (let
              [b-inner : AstExpr (box-get b-inner-box)]
              (ctfe-expr-eq a-inner b-inner))]
          [_ false]))]
    [(AstExprStringFromBytes a-ptr-box a-len-box)
      (let
        [a-ptr : AstExpr (box-get a-ptr-box)]
        [a-len : AstExpr (box-get a-len-box)]
        (match b
          [(AstExprStringFromBytes b-ptr-box b-len-box)
            (let
              [b-ptr : AstExpr (box-get b-ptr-box)]
              [b-len : AstExpr (box-get b-len-box)]
              (and (ctfe-expr-eq a-ptr b-ptr) (ctfe-expr-eq a-len b-len)))]
          [_ false]))]
    [(AstExprArrayData a-inner-box)
      (let
        [a-inner : AstExpr (box-get a-inner-box)]
        (match b
          [(AstExprArrayData b-inner-box)
            (let
              [b-inner : AstExpr (box-get b-inner-box)]
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
        [a-leaf : AstExpr (box-get a-leaf-box)]
        [a-subleaf : AstExpr (box-get a-subleaf-box)]
        (match b
          [(AstExprCpuIdEax b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (box-get b-leaf-box)]
              [b-subleaf : AstExpr (box-get b-subleaf-box)]
              (and
                (ctfe-expr-eq a-leaf b-leaf)
                (ctfe-expr-eq a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExprCpuIdEbx a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (box-get a-leaf-box)]
        [a-subleaf : AstExpr (box-get a-subleaf-box)]
        (match b
          [(AstExprCpuIdEbx b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (box-get b-leaf-box)]
              [b-subleaf : AstExpr (box-get b-subleaf-box)]
              (and
                (ctfe-expr-eq a-leaf b-leaf)
                (ctfe-expr-eq a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExprCpuIdEcx a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (box-get a-leaf-box)]
        [a-subleaf : AstExpr (box-get a-subleaf-box)]
        (match b
          [(AstExprCpuIdEcx b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (box-get b-leaf-box)]
              [b-subleaf : AstExpr (box-get b-subleaf-box)]
              (and
                (ctfe-expr-eq a-leaf b-leaf)
                (ctfe-expr-eq a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExprCpuIdEdx a-leaf-box a-subleaf-box)
      (let
        [a-leaf : AstExpr (box-get a-leaf-box)]
        [a-subleaf : AstExpr (box-get a-subleaf-box)]
        (match b
          [(AstExprCpuIdEdx b-leaf-box b-subleaf-box)
            (let
              [b-leaf : AstExpr (box-get b-leaf-box)]
              [b-subleaf : AstExpr (box-get b-subleaf-box)]
              (and
                (ctfe-expr-eq a-leaf b-leaf)
                (ctfe-expr-eq a-subleaf b-subleaf)))]
          [_ false]))]
    [(AstExprXgetbv a-index-box)
      (let
        [a-index : AstExpr (box-get a-index-box)]
        (match b
          [(AstExprXgetbv b-index-box)
            (let
              [b-index : AstExpr (box-get b-index-box)]
              (ctfe-expr-eq a-index b-index))]
          [_ false]))]
    [(AstExprSpanned a-inner-box _)
      (let
        [a-inner : AstExpr (box-get a-inner-box)]
        (ctfe-expr-eq a-inner b))]
    [_ false]))

(define (ctfe-expr-list-eq [a : AstExprList] [b : AstExprList]) : bool
  (match a
    [(AstExprNil)
      (match b
        [(AstExprNil) true]
        [_ false])]
    [(AstExprCons a-head a-tail)
      (let
        [a-head : AstExpr (box-get a-head)]
        [a-tail : AstExprList (box-get a-tail)]
        (match b
          [(AstExprCons b-head b-tail)
            (let
              [b-head : AstExpr (box-get b-head)]
              [b-tail : AstExprList (box-get b-tail)]
              (and
                (ctfe-expr-eq a-head b-head)
                (ctfe-expr-list-eq a-tail b-tail)))]
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
(define (ctfe-expr-literal [lit : AstLiteral]) : AstExpr
  (AstExprLiteral lit))

(define (ctfe-expr-bool [b : bool]) : AstExpr
  (AstExprLiteral (AstLitBool b)))

(define (ctfe-expr-var [name : String]) : AstExpr
  (AstExprVar name))

(define (ctfe-expr-if
  [cond : AstExpr]
  [then-branch : AstExpr]
  [else-branch : AstExpr]) : AstExpr
  (ast-expr-if cond then-branch else-branch))

(define (ctfe-expr-call [func : AstExpr] [args : AstExprList]) : AstExpr
  (ast-expr-call func args))

(define (ctfe-expr-begin [exprs : AstExprList]) : AstExpr
  (AstExprBegin exprs))

;; LIST UTILITIES --------------------------------------------------------------
(define (ctfe-expr-list-empty) : AstExprList
  AstExprNil)

(define (ctfe-expr-list-singleton [e : AstExpr]) : AstExprList
  (ast-expr-cons e AstExprNil))

(define (ctfe-expr-list-cons [head : AstExpr] [tail : AstExprList]) : AstExprList
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

;; INSPECTORS (predicates) -----------------------------------------------------
(define (ctfe-expr-literal? [e : AstExpr]) : bool
  (match e
    [(AstExprLiteral _) true]
    [_ false]))

(define (ctfe-expr-bool? [e : AstExpr]) : bool
  (match e
    [(AstExprLiteral lit)
      (match lit
        [(AstLitBool _) true]
        [_ false])]
    [_ false]))

(define (ctfe-expr-bool-value [e : AstExpr]) : bool
  (match e
    [(AstExprLiteral lit)
      (match lit
        [(AstLitBool b) b]
        [_ false])]
    [_ false]))

(define (ctfe-expr-var? [e : AstExpr]) : bool
  (match e
    [(AstExprVar _) true]
    [_ false]))

(define (ctfe-expr-if? [e : AstExpr]) : bool
  (match e
    [(AstExprIf _ _ _) true]
    [_ false]))

(define (ctfe-expr-call? [e : AstExpr]) : bool
  (match e
    [(AstExprCall _ _) true]
    [_ false]))

;; INSPECTORS (extractors) -----------------------------------------------------
(define (ctfe-expr-literal-value [e : AstExpr]) : AstLiteral
  (match e
    [(AstExprLiteral lit) lit]
    [_ (AstLitUnit)]))

(define (ctfe-expr-var-name [e : AstExpr]) : String
  (match e
    [(AstExprVar name) name]
    [_ ""]))

(define (ctfe-expr-if-cond [e : AstExpr]) : AstExpr
  (match e
    [(AstExprIf c-box _ _)
      (let
        [c : AstExpr (box-get c-box)]
        c)]
    [_ (AstExprLiteral (AstLitUnit))]))

(define (ctfe-expr-if-then [e : AstExpr]) : AstExpr
  (match e
    [(AstExprIf _ t-box _)
      (let
        [t : AstExpr (box-get t-box)]
        t)]
    [_ (AstExprLiteral (AstLitUnit))]))

(define (ctfe-expr-if-else [e : AstExpr]) : AstExpr
  (match e
    [(AstExprIf _ _ e-box)
      (let
        [e : AstExpr (box-get e-box)]
        e)]
    [_ (AstExprLiteral (AstLitUnit))]))

(define (ctfe-expr-call-func [e : AstExpr]) : AstExpr
  (match e
    [(AstExprCall f-box _)
      (let
        [f : AstExpr (box-get f-box)]
        f)]
    [_ (AstExprLiteral (AstLitUnit))]))

(define (ctfe-expr-call-args [e : AstExpr]) : AstExprList
  (match e
    [(AstExprCall _ args) args]
    [_ AstExprNil]))

(define (ctfe-expr-list-head [lst : AstExprList]) : AstExpr
  (match lst
    [(AstExprCons head _) (box-get head)]
    [_ (AstExprLiteral (AstLitUnit))]))

(define (ctfe-expr-list-tail [lst : AstExprList]) : AstExprList
  (match lst
    [(AstExprCons _ tail)
      (let
        [tail : AstExprList (box-get tail)]
        tail)]
    [_ AstExprNil]))

;; --- folding ----------------------------------------------------------------
;; Convert a folded compile-time value into the AST literal that lowering then
;; materializes through the ordinary literal path. Expr / ExprList values are
;; compile-time only and have no runtime literal form; this is used for scalar
;; value lowering.
(define (ctfe-value-to-literal [value : CompilerCtfeValue]) : AstLiteral
  (match value
    [(CtfeI64 n) (AstLitInt n)]
    [(CtfeBool b) (AstLitBool b)]
    [(CtfeChar c) (AstLitChar c)]
    [(CtfeString text) (AstLitString text)]
    [(CtfeUnit) (AstLitUnit)]
    [(CtfeType _) (AstLitUnit)]
    [(CtfeExpr _ _) (AstLitUnit)]
    [(CtfeExprList _) (AstLitUnit)]))

(define (ctfe-type-list-eq [a : AstTypeList] [b : AstTypeList]) : bool
  (match a
    [(AstTypeNil)
      (match b
        [(AstTypeNil) true]
        [_ false])]
    [(AstTypeCons ah at)
      (let
        [ah : AstType (box-get ah)]
        [at : AstTypeList (box-get at)]
        (match b
          [(AstTypeCons bh bt)
            (let
              [bh : AstType (box-get bh)]
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
            (ctfe-type-eq (box-get a-ret) (box-get b-ret)))]
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
            (ctfe-type-eq (box-get a-elem) (box-get b-elem)))]
        [_ false])]
    [(AstTyDynArray a-elem)
      (match b
        [(AstTyDynArray b-elem)
          (ctfe-type-eq (box-get a-elem) (box-get b-elem))]
        [_ false])]
    [(AstTyBox a-elem)
      (match b
        [(AstTyBox b-elem) (ctfe-type-eq (box-get a-elem) (box-get b-elem))]
        [_ false])]
    [(AstTyPtr a-elem)
      (match b
        [(AstTyPtr b-elem) (ctfe-type-eq (box-get a-elem) (box-get b-elem))]
        [_ false])]
    [(AstTyMutPtr a-elem)
      (match b
        [(AstTyMutPtr b-elem) (ctfe-type-eq (box-get a-elem) (box-get b-elem))]
        [_ false])]
    [(AstTyRef a-region a-inner)
      (match b
        [(AstTyRef b-region b-inner)
          (and
            (string-eq a-region b-region)
            (ctfe-type-eq (box-get a-inner) (box-get b-inner)))]
        [_ false])]
    [(AstTyMutRef a-region a-inner)
      (match b
        [(AstTyMutRef b-region b-inner)
          (and
            (string-eq a-region b-region)
            (ctfe-type-eq (box-get a-inner) (box-get b-inner)))]
        [_ false])]
    [(AstTyRegion a-region a-inner)
      (match b
        [(AstTyRegion b-region b-inner)
          (and
            (string-eq a-region b-region)
            (ctfe-type-eq (box-get a-inner) (box-get b-inner)))]
        [_ false])]
    [(AstTyEnum a-name)
      (match b
        [(AstTyEnum b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstTyEnumArgs a-name a-lifetimes)
      (match b
        [(AstTyEnumArgs b-name b-lifetimes)
          (and
            (string-eq a-name b-name)
            (ctfe-lifetime-list-eq a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyStruct a-name)
      (match b
        [(AstTyStruct b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstTyStructArgs a-name a-lifetimes)
      (match b
        [(AstTyStructArgs b-name b-lifetimes)
          (and
            (string-eq a-name b-name)
            (ctfe-lifetime-list-eq a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyVar a-name)
      (match b
        [(AstTyVar b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstTyVarArgs a-name a-lifetimes)
      (match b
        [(AstTyVarArgs b-name b-lifetimes)
          (and
            (string-eq a-name b-name)
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
    (ast-expr-binary
      (AstBinEq)
      (AstExprTypeLiteral (AstTyI64))
      (AstExprTypeLiteral (AstTyI64)))
    (ctfe-env-empty)
    (ctfe-fuel-limit))
    [(OkCtfe same _)
      (match same
        [(CtfeBool same-ok)
          (match (compiler-ctfe-eval
            (ast-expr-binary
              (AstBinEq)
              (AstExprTypeLiteral (AstTyI64))
              (AstExprTypeLiteral (AstTyI32)))
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
    (ast-expr-binary
      (AstBinEq)
      (AstExprTypeLiteral (ast-ty-ptr (AstTyI64)))
      (AstExprTypeLiteral (ast-ty-ptr (AstTyI64))))
    (ctfe-env-empty)
    (ctfe-fuel-limit))
    [(OkCtfe same _)
      (match same
        [(CtfeBool same-ok)
          (match (compiler-ctfe-eval
            (ast-expr-binary
              (AstBinEq)
              (AstExprTypeLiteral (ast-ty-ptr (AstTyI64)))
              (AstExprTypeLiteral (ast-ty-mut-ptr (AstTyI64))))
            (ctfe-env-empty)
            (ctfe-fuel-limit))
            [(OkCtfe different _)
              (match different
                [(CtfeBool different-ok) (and same-ok (not different-ok))]
                [_ false])]
            [(ErrCtfe _) false])]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-call1 [name : String] [arg : AstExpr]) : AstExpr
  (ast-expr-call (AstExprVar name) (ast-expr-cons arg AstExprNil)))

(define (compiler-ctfe-call2 [name : String] [a : AstExpr] [b : AstExpr]) : AstExpr
  (ast-expr-call
    (AstExprVar name)
    (ast-expr-cons a (ast-expr-cons b AstExprNil))))

(define (compiler-ctfe-call3
  [name : String]
  [a : AstExpr]
  [b : AstExpr]
  [c : AstExpr]) : AstExpr
  (ast-expr-call
    (AstExprVar name)
    (ast-expr-cons a (ast-expr-cons b (ast-expr-cons c AstExprNil)))))

(define (compiler-ctfe-eval-i64-ok?
  [expr : AstExpr]
  [env : CtfeEnv]
  [want : i64]) : bool
  (match (compiler-ctfe-eval expr env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeI64 actual) (= actual want)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-bool-ok?
  [expr : AstExpr]
  [env : CtfeEnv]
  [want : bool]) : bool
  (match (compiler-ctfe-eval expr env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeBool actual)
          (if want
            actual
            (not actual))]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-string-ok?
  [expr : AstExpr]
  [env : CtfeEnv]
  [want : String]) : bool
  (match (compiler-ctfe-eval expr env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeString actual) (string-eq actual want)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-type-ok?
  [expr : AstExpr]
  [env : CtfeEnv]
  [want : AstType]) : bool
  (match (compiler-ctfe-eval expr env (ctfe-fuel-limit))
    [(OkCtfe value _)
      (match value
        [(CtfeType actual) (ctfe-type-eq actual want)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (compiler-ctfe-eval-error-ok?
  [expr : AstExpr]
  [env : CtfeEnv]
  [want : String]) : bool
  (match (compiler-ctfe-eval expr env (ctfe-fuel-limit))
    [(ErrCtfe diag) (string-eq (compiler-diagnostic-message diag) want)]
    [(OkCtfe _ _) false]))

(define (compiler-ctfe-layout-query-ok?) : bool
  (let
    [packet-ty : AstExpr (AstExprTypeLiteral (AstTyVar "Packet"))]
    [box-ty : AstExpr (AstExprTypeLiteral (AstTyVar "Box"))]
    [choice-ty : AstExpr (AstExprTypeLiteral (AstTyVar "Choice"))]
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
        (compiler-ctfe-call2 "offset-of" packet-ty (AstExprVar "count"))
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
        (compiler-ctfe-call2 "offset-of" box-ty (AstExprVar "x"))
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
        (compiler-ctfe-call2 "offset-of" choice-ty (AstExprVar "tag"))
        env
        "offset-of requires struct layout type")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-error-ok?
        (compiler-ctfe-call2 "offset-of" packet-ty (AstExprVar "missing"))
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
    [point-ty : AstExpr (AstExprTypeLiteral (AstTyVar "Point"))]
    [maybe-ty : AstExpr (AstExprTypeLiteral (AstTyVar "Maybe"))]
    [array-ty : AstExpr (AstExprTypeLiteral (ast-ty-array (AstTyI64) 4))]
    [dyn-array-ty : AstExpr (AstExprTypeLiteral (ast-ty-dyn-array (AstTyBool)))]
    [str-ref-ty : AstExpr (AstExprTypeLiteral (ast-ty-ref "r" (AstTyStr)))]
    [fn-ty : AstExpr
      (AstExprTypeLiteral
        (ast-ty-func
          (ast-type-cons (AstTyI64) (ast-type-cons (AstTyBool) AstTypeNil))
          (AstTyString)))]
    [ok : bool true]
    (begin
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call1 "type-kind" point-ty)
        env
        "struct")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-string-ok?
        (compiler-ctfe-call1 "type-key" (AstExprTypeLiteral (AstTyI64)))
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
          (AstExprLiteral (AstLitInt 1)))
        env
        "flag")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call2
          "struct-field-type"
          point-ty
          (AstExprLiteral (AstLitInt 0)))
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
          (AstExprLiteral (AstLitInt 1)))
        env
        "Some")
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call2
          "enum-variant-payload-count"
          maybe-ty
          (AstExprLiteral (AstLitInt 1)))
        env
        1)
        unit
        (set! ok false))
      (if (compiler-ctfe-eval-type-ok?
        (compiler-ctfe-call3
          "enum-variant-payload-type"
          maybe-ty
          (AstExprLiteral (AstLitInt 1))
          (AstExprLiteral (AstLitInt 0)))
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
          (AstExprLiteral (AstLitInt 1)))
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
(define (compiler-ctfe-expr-eq-ok?) : bool
  (let
    [true-lit : AstExpr (ctfe-expr-bool true)]
    [false-lit : AstExpr (ctfe-expr-bool false)]
    [var-x : AstExpr (ctfe-expr-var "x")]
    [if1 : AstExpr (ctfe-expr-if var-x true-lit false-lit)]
    [if2 : AstExpr (ctfe-expr-if var-x true-lit false-lit)]
    [if3 : AstExpr (ctfe-expr-if true-lit var-x false-lit)]
    (and
      (ctfe-expr-eq if1 if2)
      (and
        (not (ctfe-expr-eq if1 if3))
        (and
          (ctfe-expr-if? if1)
          (and
            (ctfe-expr-eq (ctfe-expr-if-cond if1) var-x)
            (and
              (ctfe-expr-eq (ctfe-expr-if-then if1) true-lit)
              (ctfe-expr-eq (ctfe-expr-if-else if1) false-lit))))))))

(define (compiler-ctfe-expr-list-ok?) : bool
  (let
    [a : AstExpr (ctfe-expr-bool true)]
    [b : AstExpr (ctfe-expr-bool false)]
    [lst1 : AstExprList (ctfe-expr-list-cons a (ctfe-expr-list-singleton b))]
    [lst2 : AstExprList (ctfe-expr-list-cons a (ctfe-expr-list-singleton b))]
    [lst3 : AstExprList (ctfe-expr-list-singleton a)]
    (and
      (ctfe-expr-list-eq lst1 lst2)
      (and
        (not (ctfe-expr-list-eq lst1 lst3))
        (and
          (= (ctfe-expr-list-length lst1) 2)
          (and
            (not (ctfe-expr-list-empty? lst1))
            (and
              (ctfe-expr-eq (ctfe-expr-list-head lst1) a)
              (ctfe-expr-eq (ctfe-expr-list-head (ctfe-expr-list-tail lst1)) b))))))))

(define (compiler-ctfe-expr-list-fold-sketch-ok?)
  :
  bool
  ;; Simulate the core list-recursion a macro transformer does: build a
  ;; right-leaning `if` chain from a list of conditions and a final else.
  (let
    [cond1 : AstExpr (ctfe-expr-var "a")]
    [cond2 : AstExpr (ctfe-expr-var "b")]
    [else-expr : AstExpr (ctfe-expr-bool false)]
    [conds : AstExprList
      (ctfe-expr-list-cons cond1 (ctfe-expr-list-singleton cond2))]
    ;; fold helper: single cond -> (if cond true else)
    [folded1 : AstExpr (ctfe-expr-if cond2 (ctfe-expr-bool true) else-expr)]
    ;; next: (if cond1 true (if cond2 true else))
    [folded2 : AstExpr (ctfe-expr-if cond1 (ctfe-expr-bool true) folded1)]
    [expected : AstExpr
      (ctfe-expr-if
        cond1
        (ctfe-expr-bool true)
        (ctfe-expr-if cond2 (ctfe-expr-bool true) else-expr))]
    (ctfe-expr-eq folded2 expected)))

(define (compiler-ctfe-checked-expr-constructors-ok?) : bool
  (let
    [true-lit : AstExpr (AstExprLiteral (AstLitBool true))]
    [false-lit : AstExpr (AstExprLiteral (AstLitBool false))]
    [true-expr : AstExpr (compiler-ctfe-call1 "expr-bool" true-lit)]
    [false-expr : AstExpr (compiler-ctfe-call1 "expr-bool" false-lit)]
    [spliced-false : AstExpr (compiler-ctfe-call1 "expr-splice" false-expr)]
    [if-expr : AstExpr
      (compiler-ctfe-call3 "expr-if" true-expr spliced-false true-expr)]
    (match (compiler-ctfe-eval if-expr (ctfe-env-empty) (ctfe-fuel-limit))
      [(OkCtfe value _)
        (match value
          [(CtfeExpr node checked-ty)
            (and
              (ctfe-type-eq checked-ty (AstTyBool))
              (ctfe-expr-eq node (ast-expr-if true-lit false-lit true-lit)))]
          [_ false])]
      [(ErrCtfe _) false])))

(define (compiler-ctfe-checked-expr-inspectors-ok?) : bool
  (let
    [true-lit : AstExpr (AstExprLiteral (AstLitBool true))]
    [false-lit : AstExpr (AstExprLiteral (AstLitBool false))]
    [true-expr : AstExpr (compiler-ctfe-call1 "expr-bool" true-lit)]
    [false-expr : AstExpr (compiler-ctfe-call1 "expr-bool" false-lit)]
    [if-expr : AstExpr
      (compiler-ctfe-call3 "expr-if" true-expr false-expr true-expr)]
    [if-predicate : AstExpr (compiler-ctfe-call1 "expr-if?" if-expr)]
    [bool-predicate : AstExpr (compiler-ctfe-call1 "expr-bool?" true-expr)]
    [bool-value : AstExpr (compiler-ctfe-call1 "expr-bool-value" false-expr)]
    [cond-expr : AstExpr (compiler-ctfe-call1 "expr-if-cond" if-expr)]
    [then-expr : AstExpr (compiler-ctfe-call1 "expr-if-then" if-expr)]
    [bad-cond-expr : AstExpr (compiler-ctfe-call1 "expr-if-cond" true-expr)]
    (and
      (compiler-ctfe-eval-bool-ok? if-predicate (ctfe-env-empty) true)
      (and
        (compiler-ctfe-eval-bool-ok? bool-predicate (ctfe-env-empty) true)
        (and
          (compiler-ctfe-eval-bool-ok? bool-value (ctfe-env-empty) false)
          (and
            (match (compiler-ctfe-eval
              cond-expr
              (ctfe-env-empty)
              (ctfe-fuel-limit))
              [(OkCtfe value _)
                (match value
                  [(CtfeExpr node checked-ty)
                    (and
                      (ctfe-type-eq checked-ty (AstTyBool))
                      (ctfe-expr-eq node true-lit))]
                  [_ false])]
              [(ErrCtfe _) false])
            (and
              (match (compiler-ctfe-eval
                then-expr
                (ctfe-env-empty)
                (ctfe-fuel-limit))
                [(OkCtfe value _)
                  (match value
                    [(CtfeExpr node checked-ty)
                      (and
                        (ctfe-type-eq checked-ty (AstTyBool))
                        (ctfe-expr-eq node false-lit))]
                    [_ false])]
                [(ErrCtfe _) false])
              (compiler-ctfe-eval-error-ok?
                bad-cond-expr
                (ctfe-env-empty)
                "expr-if-cond expects if Expr"))))))))

(define (compiler-ctfe-checked-expr-rejects-non-bool-cond-ok?) : bool
  (let
    [int-expr-value : CompilerCtfeValue
      (CtfeExpr (AstExprLiteral (AstLitInt 1)) (AstTyI64))]
    [env : CtfeEnv (ctfe-env-extend (ctfe-env-empty) "n" int-expr-value)]
    [spliced-int : AstExpr (compiler-ctfe-call1 "expr-splice" (AstExprVar "n"))]
    [true-expr : AstExpr
      (compiler-ctfe-call1 "expr-bool" (AstExprLiteral (AstLitBool true)))]
    [if-expr : AstExpr
      (compiler-ctfe-call3 "expr-if" spliced-int true-expr true-expr)]
    (compiler-ctfe-eval-error-ok?
      if-expr
      env
      "expr-if condition must produce bool")))

(define (compiler-ctfe-quote-syntax-ok?) : bool
  (let
    [true-lit : AstExpr (AstExprLiteral (AstLitBool true))]
    [false-lit : AstExpr (AstExprLiteral (AstLitBool false))]
    [flag-var : AstExpr (AstExprVar "flag")]
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
    [quoted-bool : AstExpr (ast-expr-quote true-lit)]
    [qq-if : AstExpr
      (ast-expr-quasiquote
        (ast-expr-if (ast-expr-unquote (AstExprVar "cond")) true-lit false-lit))]
    [qq-splice : AstExpr
      (ast-expr-quasiquote
        (AstExprBegin
          (ast-expr-cons
            (ast-expr-unquote-splicing (AstExprVar "xs"))
            AstExprNil)))]
    (and
      (match (compiler-ctfe-eval quoted-bool env (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr node ty)
              (and (ctfe-type-eq ty (AstTyBool)) (ctfe-expr-eq node true-lit))]
            [_ false])]
        [(ErrCtfe _) false])
      (and
        (match (compiler-ctfe-eval qq-if env (ctfe-fuel-limit))
          [(OkCtfe value _)
            (match value
              [(CtfeExpr node ty)
                (and
                  (ctfe-type-eq ty (AstTyBool))
                  (ctfe-expr-eq node (ast-expr-if flag-var true-lit false-lit)))]
              [_ false])]
          [(ErrCtfe _) false])
        (match (compiler-ctfe-eval qq-splice env (ctfe-fuel-limit))
          [(OkCtfe value _)
            (match value
              [(CtfeExpr node _) (ctfe-expr-eq node (AstExprBegin spliced))]
              [_ false])]
          [(ErrCtfe _) false])))))

(define (compiler-ctfe-self-test) : i64
  (begin
    (unless (compiler-ctfe-type-literal-ok?) (return 1))
    (unless (compiler-ctfe-type-comparison-ok?) (return 1))
    (unless (compiler-ctfe-raw-pointer-type-comparison-ok?) (return 1))
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