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
  (CtfeLayoutFieldCons CtfeLayoutField CtfeLayoutFieldList))

(defenum CtfeLayoutInfo
  (CtfeLayoutInfo String bool i64 i64 CtfeLayoutFieldList))

(defenum CtfeLayoutInfoList
  (CtfeLayoutInfoNil)
  (CtfeLayoutInfoCons CtfeLayoutInfo CtfeLayoutInfoList))

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
  (CtfeReflectFieldCons CtfeReflectField CtfeReflectFieldList))

(defenum CtfeReflectVariant
  (CtfeReflectVariant String AstTypeList))

(defenum CtfeReflectVariantList
  (CtfeReflectVariantNil)
  (CtfeReflectVariantCons CtfeReflectVariant CtfeReflectVariantList))

(defenum CtfeReflectInfo
  (CtfeReflectStruct String String String CtfeReflectFieldList)
  (CtfeReflectEnum String String String CtfeReflectVariantList))

(defenum CtfeReflectInfoList
  (CtfeReflectInfoNil)
  (CtfeReflectInfoCons CtfeReflectInfo CtfeReflectInfoList))

(defenum CtfeMaybeReflectInfo
  (CtfeNoReflectInfo)
  (CtfeSomeReflectInfo CtfeReflectInfo))

;; Immutable name -> value environment plus immutable type metadata tables. Newest
;; value binding sits at the front so lookup finds the most recent shadowing
;; binding first; metadata lives at the root and is shared by extensions.
(defenum CtfeEnv
  (CtfeEnvNil CtfeLayoutInfoList CtfeReflectInfoList)
  (CtfeEnvCons String CompilerCtfeValue CtfeEnv))

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
  (CtfeEnvCons name value env))

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
        (ctfe-layout-info-list-contains rest name))]))

(define (ctfe-layout-info-list-add-if-missing
  [layouts : CtfeLayoutInfoList]
  [info : CtfeLayoutInfo]) : CtfeLayoutInfoList
  (if (ctfe-layout-info-list-contains layouts (ctfe-layout-info-name info))
    layouts
    (CtfeLayoutInfoCons info layouts)))

(define (ctfe-layout-info-lookup [layouts : CtfeLayoutInfoList] [name : String]) : CtfeMaybeLayoutInfo
  (match layouts
    [(CtfeLayoutInfoNil) (CtfeNoLayoutInfo)]
    [(CtfeLayoutInfoCons info rest)
      (if (string-eq (ctfe-layout-info-name info) name)
        (CtfeSomeLayoutInfo info)
        (ctfe-layout-info-lookup rest name))]))

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
            (ctfe-layout-field-offset rest name))])]))

(define (ctfe-env-layouts [env : CtfeEnv]) : CtfeLayoutInfoList
  (match env
    [(CtfeEnvNil layouts _) layouts]
    [(CtfeEnvCons _ _ rest) (ctfe-env-layouts rest)]))

(define (ctfe-env-reflections [env : CtfeEnv]) : CtfeReflectInfoList
  (match env
    [(CtfeEnvNil _ reflections) reflections]
    [(CtfeEnvCons _ _ rest) (ctfe-env-reflections rest)]))

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
        (ctfe-env-lookup rest name))]))

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
        (ctfe-reflect-info-list-contains rest key))]))

(define (ctfe-reflect-info-list-add-if-missing
  [infos : CtfeReflectInfoList]
  [info : CtfeReflectInfo]) : CtfeReflectInfoList
  (if (ctfe-reflect-info-list-contains infos (ctfe-reflect-info-key info))
    infos
    (CtfeReflectInfoCons info infos)))

(define (ctfe-reflect-info-lookup [infos : CtfeReflectInfoList] [key : String]) : CtfeMaybeReflectInfo
  (match infos
    [(CtfeReflectInfoNil) (CtfeNoReflectInfo)]
    [(CtfeReflectInfoCons info rest)
      (if (string-eq (ctfe-reflect-info-key info) key)
        (CtfeSomeReflectInfo info)
        (ctfe-reflect-info-lookup rest key))]))

(define (ctfe-reflect-field-list-from-fields [fields : AstFieldDefList]) : CtfeReflectFieldList
  (match fields
    [(AstFieldDefNil) CtfeReflectFieldNil]
    [(AstFieldDefCons field rest)
      (match field
        [(AstFieldDef name ty _)
          (CtfeReflectFieldCons
            (CtfeReflectField name ty)
            (ctfe-reflect-field-list-from-fields rest))])]))

(define (ctfe-reflect-variant-list-from-variants [variants : AstVariantDefList]) : CtfeReflectVariantList
  (match variants
    [(AstVariantDefNil) CtfeReflectVariantNil]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef name payloads)
          (CtfeReflectVariantCons
            (CtfeReflectVariant name payloads)
            (ctfe-reflect-variant-list-from-variants rest))])]))

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
        [(AstDeclComptimeDecl template)
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
            [_ (ctfe-reflections-from-decls rest module infos)])]
        [_ (ctfe-reflections-from-decls rest module infos)])]))

(define (ctfe-reflections-from-program [program : AstProgram]) : CtfeReflectInfoList
  (match program
    [(AstProgram decls)
      (ctfe-reflections-from-decls decls "" CtfeReflectInfoNil)]))

;; Result of evaluating a sub-expression: either a value (carrying the remaining
;; fuel) or a diagnostic. Fuel is threaded so each evaluation step decrements a
;; shared budget across all sub-evaluations, matching the spirit of the Rust
;; evaluator's per-step 10_000 fuel cap.
(defenum ResultCtfe
  (OkCtfe CompilerCtfeValue i64)
  (ErrCtfe CompilerDiagnostic))

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
    [(AstExprWithResource _ _) "with"]
    [(AstExprTypeLiteral _) "type literal"]
    [(AstExprComptime _) "comptime"]
    [(AstExprTry _) "try"]
    [(AstExprPtrNull _) "ptr-null"]
    [(AstExprPtrNullCheck _) "ptr-null?"]
    [(AstExprPtrRead _) "ptr-read"]
    [(AstExprPtrWrite _ _) "ptr-write!"]
    [(AstExprPtrOffset _ _) "ptr-offset"]
    [(AstExprPtrCast _ _) "ptr-cast"]
    [(AstExprPtrToInt _) "ptr->int"]
    [(AstExprIntToPtr _ _) "int->ptr"]))

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
      (AstTypeCons
        (ctfe-reflect-resolve-type infos head)
        (ctfe-reflect-resolve-type-list infos rest))]))

(define (ctfe-reflect-resolve-type [infos : CtfeReflectInfoList] [ty : AstType]) : AstType
  (match ty
    [(AstTyFunc args ret)
      (AstTyFunc
        (ctfe-reflect-resolve-type-list infos args)
        (ctfe-reflect-resolve-type infos ret))]
    [(AstTyTuple elems)
      (AstTyTuple (ctfe-reflect-resolve-type-list infos elems))]
    [(AstTyArray elem len)
      (AstTyArray (ctfe-reflect-resolve-type infos elem) len)]
    [(AstTyDynArray elem)
      (AstTyDynArray (ctfe-reflect-resolve-type infos elem))]
    [(AstTyPtr elem) (AstTyPtr (ctfe-reflect-resolve-type infos elem))]
    [(AstTyMutPtr elem) (AstTyMutPtr (ctfe-reflect-resolve-type infos elem))]
    [(AstTyRef region inner)
      (AstTyRef region (ctfe-reflect-resolve-type infos inner))]
    [(AstTyMutRef region inner)
      (AstTyMutRef region (ctfe-reflect-resolve-type infos inner))]
    [(AstTyRegion region inner)
      (AstTyRegion region (ctfe-reflect-resolve-type infos inner))]
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
      (string-append
        (ctfe-type-key-with-reflections infos head)
        (string-append "_" (ctfe-type-list-key infos rest)))]))

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
    [(AstTyExpr) "Expr"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyFunc args ret)
      (string-append
        "fn_"
        (string-append
          (ctfe-type-list-key infos args)
          (string-append "_to_" (ctfe-type-key-with-reflections infos ret))))]
    [(AstTyTuple elems)
      (string-append "tuple_" (ctfe-type-list-key infos elems))]
    [(AstTyArray elem count)
      (string-append
        "array_"
        (string-append
          (ctfe-type-key-with-reflections infos elem)
          (string-append "_" (ctfe-int-key count))))]
    [(AstTyDynArray elem)
      (string-append "dynarray_" (ctfe-type-key-with-reflections infos elem))]
    [(AstTyPtr elem)
      (string-append "ptr_" (ctfe-type-key-with-reflections infos elem))]
    [(AstTyMutPtr elem)
      (string-append "mutptr_" (ctfe-type-key-with-reflections infos elem))]
    [(AstTyRef region inner)
      (string-append
        "ref_"
        (string-append
          region
          (string-append "_" (ctfe-type-key-with-reflections infos inner))))]
    [(AstTyMutRef region inner)
      (string-append
        "mutref_"
        (string-append
          region
          (string-append "_" (ctfe-type-key-with-reflections infos inner))))]
    [(AstTyRegion region inner)
      (string-append
        "region_"
        (string-append
          region
          (string-append "_" (ctfe-type-key-with-reflections infos inner))))]
    [(AstTyEnum name) (string-append "enum_" name)]
    [(AstTyStruct name) (string-append "struct_" name)]
    [(AstTyVar name) (string-append "var_" name)]))

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
    [(AstTyExpr) "expr"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyFunc _ _) "function"]
    [(AstTyTuple _) "tuple"]
    [(AstTyArray _ _) "array"]
    [(AstTyDynArray _) "dyn-array"]
    [(AstTyPtr _) "ptr"]
    [(AstTyMutPtr _) "mut-ptr"]
    [(AstTyRef _ _) "ref"]
    [(AstTyMutRef _ _) "mut-ref"]
    [(AstTyRegion _ _) "region"]
    [(AstTyEnum _) "enum"]
    [(AstTyStruct _) "struct"]
    [(AstTyVar _) "type-var"]))

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
    [(CtfeReflectFieldCons _ rest) (+ 1 (ctfe-reflect-field-list-count rest))]))

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
          (ctfe-reflect-field-name-at rest (- index 1)))])))

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
          (ctfe-reflect-field-type-at rest infos (- index 1)))])))

(define (ctfe-reflect-variant-list-count [variants : CtfeReflectVariantList]) : i64
  (match variants
    [(CtfeReflectVariantNil) 0]
    [(CtfeReflectVariantCons _ rest)
      (+ 1 (ctfe-reflect-variant-list-count rest))]))

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
          (ctfe-reflect-variant-name-at rest (- index 1)))])))

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
          (ctfe-reflect-variant-payloads-at rest (- index 1)))])))

(define (ctfe-type-list-count [types : AstTypeList]) : i64
  (match types
    [(AstTypeNil) 0]
    [(AstTypeCons _ rest) (+ 1 (ctfe-type-list-count rest))]))

(define (ctfe-type-list-ref
  [types : AstTypeList]
  [infos : CtfeReflectInfoList]
  [index : i64]) : ResultCtfeTypeLookup
  (if (< index 0)
    (ErrCtfeTypeLookup "index out of range")
    (match types
      [(AstTypeNil) (ErrCtfeTypeLookup "index out of range")]
      [(AstTypeCons head rest)
        (if (= index 0)
          (OkCtfeTypeLookup (ctfe-reflect-resolve-type infos head))
          (ctfe-type-list-ref rest infos (- index 1)))])))

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
    [(AstExprSpanned inner _) (compiler-ctfe-eval inner env fuel)]
    [(AstExprComptime inner) (compiler-ctfe-eval inner env fuel)]
    [(AstExprAnn inner _) (compiler-ctfe-eval inner env fuel)]
    [(AstExprTypeLiteral ty)
      (OkCtfe
        (CtfeType (ctfe-reflect-resolve-type (ctfe-env-reflections env) ty))
        fuel)]
    [(AstExprLiteral lit) (ctfe-eval-literal lit expr fuel)]
    [(AstExprVar name) (ctfe-eval-var name expr env fuel)]
    [(AstExprBinary op left right)
      (ctfe-eval-binary op left right expr env fuel)]
    [(AstExprUnary op inner) (ctfe-eval-unary op inner expr env fuel)]
    [(AstExprIf cond then-branch else-branch)
      (ctfe-eval-if cond then-branch else-branch env fuel)]
    [(AstExprLet bindings body) (ctfe-eval-let bindings body env fuel)]
    [(AstExprBegin exprs) (ctfe-eval-begin exprs env fuel)]
    [(AstExprUnsafe exprs) (ctfe-eval-begin exprs env fuel)]
    [(AstExprCall func args) (ctfe-eval-call func args expr env fuel)]
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
    [(AstTyExpr) -1]
    [(AstTyFunc _ _) 8]
    [(AstTyTuple _) 8]
    [(AstTyArray elem count)
      (let
        [elem-size : i64 (ctfe-type-size layouts elem)]
        (if (< elem-size 0)
          -1
          (* elem-size count)))]
    [(AstTyDynArray _) 8]
    [(AstTyPtr _) 8]
    [(AstTyMutPtr _) 8]
    [(AstTyRef _ _) 8]
    [(AstTyMutRef _ _) 8]
    [(AstTyRegion _ inner) (ctfe-type-size layouts inner)]
    [(AstTyEnum _) 8]
    [(AstTyStruct name)
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
    [(AstTyExpr) -1]
    [(AstTyFunc _ _) 8]
    [(AstTyTuple _) 8]
    [(AstTyArray elem _) (ctfe-type-align layouts elem)]
    [(AstTyDynArray _) 8]
    [(AstTyPtr _) 8]
    [(AstTyMutPtr _) 8]
    [(AstTyRef _ _) 8]
    [(AstTyMutRef _ _) 8]
    [(AstTyRegion _ inner) (ctfe-type-align layouts inner)]
    [(AstTyEnum _) 8]
    [(AstTyStruct name)
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
                          (string-append name " expects a known type argument")))
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
              (string-append name " expects exactly one type argument")))])]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string-append name " expects exactly one type argument")))]))

(define (ctfe-offset-field-name [expr : AstExpr]) : CtfeMaybeFieldName
  (match expr
    [(AstExprSpanned inner _) (ctfe-offset-field-name inner)]
    [(AstExprVar name) (CtfeSomeFieldName name)]
    [_ (CtfeNoFieldName)]))

(define (ctfe-layout-info-for-type
  [layouts : CtfeLayoutInfoList]
  [ty : AstType]) : CtfeMaybeLayoutInfo
  (match ty
    [(AstTyStruct name) (ctfe-layout-info-lookup layouts name)]
    [(AstTyVar name) (ctfe-layout-info-lookup layouts name)]
    [(AstTyRegion _ inner) (ctfe-layout-info-for-type layouts inner)]
    [_ (CtfeNoLayoutInfo)]))

;; Evaluate `(offset-of (type ReprCStruct) field)` to the field byte offset.
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
          (ctfe-diagnostic-at-expr expr "offset-of requires repr c struct type")))]))

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
        (ctfe-diagnostic-at-expr expr "offset-of requires repr c struct type"))]))

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
      (match tail
        [(AstExprCons field-arg rest)
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
                  "offset-of expects exactly one type argument and one field name"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "offset-of expects exactly one type argument and one field name"))])]
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
                      [(AstTyArray elem _) (OkCtfe (CtfeType elem) arg-fuel)]
                      [(AstTyDynArray elem) (OkCtfe (CtfeType elem) arg-fuel)]
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
                      [(AstTyFunc _ ret) (OkCtfe (CtfeType ret) arg-fuel)]
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
              (string-append name " expects exactly one type argument")))])]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string-append name " expects exactly one type argument")))]))

(define (ctfe-type-nominal-key [ty : AstType]) : String
  (match ty
    [(AstTyStruct name) name]
    [(AstTyEnum name) name]
    [(AstTyVar name) name]
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
      (match tail
        [(AstExprCons index-arg rest)
          (match rest
            [(AstExprNil)
              (match (ctfe-eval-type-arg type-arg expr env fuel name)
                [(ErrCtfeTypeArg d) (ErrCtfe d)]
                [(OkCtfeTypeArg ty type-fuel)
                  (match (ctfe-eval-i64-arg index-arg expr env type-fuel name)
                    [(ErrCtfeI64Arg d) (ErrCtfe d)]
                    [(OkCtfeI64Arg index index-fuel)
                      (ctfe-eval-struct-field-from-type
                        name
                        ty
                        index
                        expr
                        env
                        index-fuel)])])]
            [_ (ctfe-struct-field-arity-error name expr)])]
        [_ (ctfe-struct-field-arity-error name expr)])]
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
      (match tail
        [(AstExprCons index-arg rest)
          (match rest
            [(AstExprNil)
              (match (ctfe-eval-type-arg type-arg expr env fuel name)
                [(ErrCtfeTypeArg d) (ErrCtfe d)]
                [(OkCtfeTypeArg ty type-fuel)
                  (match (ctfe-eval-i64-arg index-arg expr env type-fuel name)
                    [(ErrCtfeI64Arg d) (ErrCtfe d)]
                    [(OkCtfeI64Arg index index-fuel)
                      (ctfe-eval-enum-variant-from-type
                        name
                        ty
                        index
                        expr
                        env
                        index-fuel)])])]
            [_ (ctfe-enum-variant-arity-error name expr)])]
        [_ (ctfe-enum-variant-arity-error name expr)])]
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
      (match tail
        [(AstExprCons variant-arg rest1)
          (match rest1
            [(AstExprCons payload-arg rest2)
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
                [_ (ctfe-enum-payload-type-arity-error expr)])]
            [_ (ctfe-enum-payload-type-arity-error expr)])]
        [_ (ctfe-enum-payload-type-arity-error expr)])]
    [_ (ctfe-enum-payload-type-arity-error expr)]))

(define (ctfe-eval-function-param-type-reflection
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons type-arg (AstExprCons index-arg rest))
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
                              (string-append "function-param-type " message)))])]
                    [_
                      (ErrCtfe
                        (ctfe-diagnostic-at-expr
                          expr
                          "function-param-type requires function type"))])])])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr
              expr
              "function-param-type expects exactly one type argument and one index"))])]
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
    [(AstExprCons left (AstExprCons right rest))
      (match rest
        [(AstExprNil)
          (match (ctfe-eval-string-arg left expr env fuel name)
            [(ErrCtfeStringArg d) (ErrCtfe d)]
            [(OkCtfeStringArg l left-fuel)
              (match (ctfe-eval-string-arg right expr env left-fuel name)
                [(ErrCtfeStringArg d) (ErrCtfe d)]
                [(OkCtfeStringArg r right-fuel)
                  (OkCtfe (CtfeBool (string-eq l r)) right-fuel)])])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr expr "string-eq expects two strings"))])]
    [_ (ErrCtfe (ctfe-diagnostic-at-expr expr "string-eq expects two strings"))]))

(define (ctfe-eval-string-append-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons left (AstExprCons right rest))
      (match rest
        [(AstExprNil)
          (match (ctfe-eval-string-arg left expr env fuel name)
            [(ErrCtfeStringArg d) (ErrCtfe d)]
            [(OkCtfeStringArg l left-fuel)
              (match (ctfe-eval-string-arg right expr env left-fuel name)
                [(ErrCtfeStringArg d) (ErrCtfe d)]
                [(OkCtfeStringArg r right-fuel)
                  (OkCtfe (CtfeString (string-append l r)) right-fuel)])])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr expr "string-append expects two strings"))])]
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
      (match rest
        [(AstExprNil)
          (match (ctfe-eval-string-arg arg expr env fuel name)
            [(ErrCtfeStringArg d) (ErrCtfe d)]
            [(OkCtfeStringArg text arg-fuel)
              (OkCtfe (CtfeI64 (string-length text)) arg-fuel)])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr expr "string-length expects one string"))])]
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
      (match rest
        [(AstExprNil)
          (match (ctfe-eval-i64-arg arg expr env fuel "int->string")
            [(ErrCtfeI64Arg d) (ErrCtfe d)]
            [(OkCtfeI64Arg n arg-fuel)
              (OkCtfe (CtfeString (int->string n)) arg-fuel)])]
        [_
          (ErrCtfe (ctfe-diagnostic-at-expr expr "int->string expects one i64"))])]
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
            (ctfe-diagnostic-at-expr expr "expr-bool expects exactly one arg"))])]
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
            (ctfe-diagnostic-at-expr expr "expr-splice expects exactly one arg"))])]
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

(define (ctfe-eval-expr-inspector-call
  [name : String]
  [args : AstExprList]
  [expr : AstExpr]
  [env : CtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match args
    [(AstExprCons arg rest)
      (match rest
        [(AstExprNil)
          (match (compiler-ctfe-eval arg env fuel)
            [(OkCtfe value arg-fuel)
              (match value
                [(CtfeExpr node ty)
                  (if (string-eq name "expr-bool?")
                    (OkCtfe (CtfeBool (ctfe-expr-bool? node)) arg-fuel)
                    (if (string-eq name "expr-bool-value")
                      (if (ctfe-expr-bool? node)
                        (OkCtfe (CtfeBool (ctfe-expr-bool-value node)) arg-fuel)
                        (ErrCtfe
                          (ctfe-diagnostic-at-expr
                            expr
                            "expr-bool-value expects bool literal Expr")))
                      (if (string-eq name "expr-if?")
                        (OkCtfe (CtfeBool (ctfe-expr-if? node)) arg-fuel)
                        (if (ctfe-expr-if? node)
                          (if (string-eq name "expr-if-cond")
                            (OkCtfe
                              (CtfeExpr (ctfe-expr-if-cond node) (AstTyBool))
                              arg-fuel)
                            (if (string-eq name "expr-if-then")
                              (OkCtfe
                                (CtfeExpr (ctfe-expr-if-then node) ty)
                                arg-fuel)
                              (if (string-eq name "expr-if-else")
                                (OkCtfe
                                  (CtfeExpr (ctfe-expr-if-else node) ty)
                                  arg-fuel)
                                (ctfe-unsupported-form expr))))
                          (ErrCtfe
                            (ctfe-diagnostic-at-expr
                              expr
                              (string-append name " expects if Expr")))))))]
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
              (string-append name " expects exactly one arg")))])]
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
      (match tail1
        [(AstExprCons then-arg tail2)
          (match tail2
            [(AstExprCons else-arg rest)
              (match rest
                [(AstExprNil)
                  (match (compiler-ctfe-eval cond-arg env fuel)
                    [(OkCtfe cond-val cond-fuel)
                      (match cond-val
                        [(CtfeExpr cond-node cond-ty)
                          (if (ctfe-type-eq cond-ty (AstTyBool))
                            (match (compiler-ctfe-eval then-arg env cond-fuel)
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
                                            (if (ctfe-type-eq then-ty else-ty)
                                              (OkCtfe
                                                (CtfeExpr
                                                  (AstExprIf
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
                      "expr-if expects exactly three args"))])]
            [_
              (ErrCtfe
                (ctfe-diagnostic-at-expr
                  expr
                  "expr-if expects exactly three args"))])]
        [_
          (ErrCtfe
            (ctfe-diagnostic-at-expr expr "expr-if expects exactly three args"))])]
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
    [(AstExprSpanned inner _) (ctfe-eval-call inner args expr env fuel)]
    [(AstExprVar name)
      (if (or (string-eq name "size-of") (string-eq name "align-of"))
        (ctfe-eval-size-align-query name args expr env fuel)
        (if (string-eq name "offset-of")
          (ctfe-eval-offset-query args expr env fuel)
          (if (ctfe-reflection-query-name? name)
            (ctfe-eval-reflection-query name args expr env fuel)
            (if (or (string-eq name "string-eq") (string-eq name "string=?"))
              (ctfe-eval-string-eq-call name args expr env fuel)
              (if (or
                (string-eq name "string-append")
                (string-eq name "string-concat"))
                (ctfe-eval-string-append-call name args expr env fuel)
                (if (or
                  (string-eq name "string-length")
                  (string-eq name "length"))
                  (ctfe-eval-string-length-call name args expr env fuel)
                  (if (string-eq name "int->string")
                    (ctfe-eval-int-to-string-call args expr env fuel)
                    (if (string-eq name "expr-bool")
                      (ctfe-eval-expr-bool-call args expr env fuel)
                      (if (string-eq name "expr-splice")
                        (ctfe-eval-expr-splice-call args expr env fuel)
                        (if (string-eq name "expr-if")
                          (ctfe-eval-expr-if-call args expr env fuel)
                          (if (ctfe-expr-inspector-name? name)
                            (ctfe-eval-expr-inspector-call
                              name
                              args
                              expr
                              env
                              fuel)
                            (ctfe-unsupported-form expr))))))))))))]
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
      (match binding
        [(AstLetBinding name _ value-expr)
          (match (compiler-ctfe-eval value-expr env fuel)
            [(OkCtfe value value-fuel)
              (ctfe-eval-let
                rest
                body
                (ctfe-env-extend env name value)
                value-fuel)]
            [(ErrCtfe diag) (ErrCtfe diag)])])]))

;; Evaluate a `begin` to the value of its last expression; an empty body is
;; unit.
(define (ctfe-eval-begin [exprs : AstExprList] [env : CtfeEnv] [fuel : i64]) : ResultCtfe
  (match exprs
    [(AstExprNil) (OkCtfe (CtfeUnit) fuel)]
    [(AstExprCons head rest)
      (match (compiler-ctfe-eval head env fuel)
        [(OkCtfe value head-fuel)
          (match rest
            [(AstExprNil) (OkCtfe value head-fuel)]
            [_ (ctfe-eval-begin rest env head-fuel)])]
        [(ErrCtfe diag) (ErrCtfe diag)])]))

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
    [(AstExprBinary a-op a-l a-r)
      (match b
        [(AstExprBinary b-op b-l b-r)
          (and
            (ctfe-binop-eq a-op b-op)
            (and (ctfe-expr-eq a-l b-l) (ctfe-expr-eq a-r b-r)))]
        [_ false])]
    [(AstExprUnary a-op a-in)
      (match b
        [(AstExprUnary b-op b-in)
          (and (ctfe-unop-eq a-op b-op) (ctfe-expr-eq a-in b-in))]
        [_ false])]
    [(AstExprIf a-c a-t a-e)
      (match b
        [(AstExprIf b-c b-t b-e)
          (and
            (ctfe-expr-eq a-c b-c)
            (and (ctfe-expr-eq a-t b-t) (ctfe-expr-eq a-e b-e)))]
        [_ false])]
    [(AstExprCall a-fun a-args)
      (match b
        [(AstExprCall b-fun b-args)
          (and (ctfe-expr-eq a-fun b-fun) (ctfe-expr-list-eq a-args b-args))]
        [_ false])]
    [(AstExprBegin a-exprs)
      (match b
        [(AstExprBegin b-exprs) (ctfe-expr-list-eq a-exprs b-exprs)]
        [_ false])]
    [(AstExprUnsafe a-exprs)
      (match b
        [(AstExprUnsafe b-exprs) (ctfe-expr-list-eq a-exprs b-exprs)]
        [_ false])]
    [(AstExprAnn a-inner a-ty)
      (match b
        [(AstExprAnn b-inner b-ty)
          (and (ctfe-expr-eq a-inner b-inner) (ctfe-type-eq a-ty b-ty))]
        [_ false])]
    [(AstExprBorrow a-life a-place)
      (match b
        [(AstExprBorrow b-life b-place)
          (and
            (ctfe-borrow-lifetime-eq a-life b-life)
            (ctfe-expr-eq a-place b-place))]
        [_ false])]
    [(AstExprPtrRead a-ptr)
      (match b
        [(AstExprPtrRead b-ptr) (ctfe-expr-eq a-ptr b-ptr)]
        [_ false])]
    [(AstExprPtrWrite a-ptr a-value)
      (match b
        [(AstExprPtrWrite b-ptr b-value)
          (and (ctfe-expr-eq a-ptr b-ptr) (ctfe-expr-eq a-value b-value))]
        [_ false])]
    [(AstExprPtrOffset a-ptr a-offset)
      (match b
        [(AstExprPtrOffset b-ptr b-offset)
          (and (ctfe-expr-eq a-ptr b-ptr) (ctfe-expr-eq a-offset b-offset))]
        [_ false])]
    [(AstExprPtrCast a-ptr a-ty)
      (match b
        [(AstExprPtrCast b-ptr b-ty)
          (and (ctfe-expr-eq a-ptr b-ptr) (ctfe-type-eq a-ty b-ty))]
        [_ false])]
    [(AstExprPtrToInt a-ptr)
      (match b
        [(AstExprPtrToInt b-ptr) (ctfe-expr-eq a-ptr b-ptr)]
        [_ false])]
    [(AstExprIntToPtr a-value a-ty)
      (match b
        [(AstExprIntToPtr b-value b-ty)
          (and (ctfe-expr-eq a-value b-value) (ctfe-type-eq a-ty b-ty))]
        [_ false])]
    [(AstExprSpanned a-inner _) (ctfe-expr-eq a-inner b)]
    [_ false]))

(define (ctfe-expr-list-eq [a : AstExprList] [b : AstExprList]) : bool
  (match a
    [(AstExprNil)
      (match b
        [(AstExprNil) true]
        [_ false])]
    [(AstExprCons a-head a-tail)
      (match b
        [(AstExprCons b-head b-tail)
          (and (ctfe-expr-eq a-head b-head) (ctfe-expr-list-eq a-tail b-tail))]
        [_ false])]))

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
  (AstExprIf cond then-branch else-branch))

(define (ctfe-expr-call [func : AstExpr] [args : AstExprList]) : AstExpr
  (AstExprCall func args))

(define (ctfe-expr-begin [exprs : AstExprList]) : AstExpr
  (AstExprBegin exprs))

;; LIST UTILITIES --------------------------------------------------------------
(define (ctfe-expr-list-empty) : AstExprList
  AstExprNil)

(define (ctfe-expr-list-singleton [e : AstExpr]) : AstExprList
  (AstExprCons e AstExprNil))

(define (ctfe-expr-list-cons [head : AstExpr] [tail : AstExprList]) : AstExprList
  (AstExprCons head tail))

(define (ctfe-expr-list-length [lst : AstExprList]) : i64
  (match lst
    [(AstExprNil) 0]
    [(AstExprCons _ rest) (+ 1 (ctfe-expr-list-length rest))]))

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
    [(AstExprIf c _ _) c]
    [_ (AstExprLiteral (AstLitUnit))]))

(define (ctfe-expr-if-then [e : AstExpr]) : AstExpr
  (match e
    [(AstExprIf _ t _) t]
    [_ (AstExprLiteral (AstLitUnit))]))

(define (ctfe-expr-if-else [e : AstExpr]) : AstExpr
  (match e
    [(AstExprIf _ _ e) e]
    [_ (AstExprLiteral (AstLitUnit))]))

(define (ctfe-expr-call-func [e : AstExpr]) : AstExpr
  (match e
    [(AstExprCall f _) f]
    [_ (AstExprLiteral (AstLitUnit))]))

(define (ctfe-expr-call-args [e : AstExpr]) : AstExprList
  (match e
    [(AstExprCall _ args) args]
    [_ AstExprNil]))

(define (ctfe-expr-list-head [lst : AstExprList]) : AstExpr
  (match lst
    [(AstExprCons head _) head]
    [_ (AstExprLiteral (AstLitUnit))]))

(define (ctfe-expr-list-tail [lst : AstExprList]) : AstExprList
  (match lst
    [(AstExprCons _ tail) tail]
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
      (match b
        [(AstTypeCons bh bt)
          (and (ctfe-type-eq ah bh) (ctfe-type-list-eq at bt))]
        [_ false])]))

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
    [(AstTyFunc a-args a-ret)
      (match b
        [(AstTyFunc b-args b-ret)
          (and (ctfe-type-list-eq a-args b-args) (ctfe-type-eq a-ret b-ret))]
        [_ false])]
    [(AstTyTuple a-elems)
      (match b
        [(AstTyTuple b-elems) (ctfe-type-list-eq a-elems b-elems)]
        [_ false])]
    [(AstTyArray a-elem a-count)
      (match b
        [(AstTyArray b-elem b-count)
          (and (= a-count b-count) (ctfe-type-eq a-elem b-elem))]
        [_ false])]
    [(AstTyDynArray a-elem)
      (match b
        [(AstTyDynArray b-elem) (ctfe-type-eq a-elem b-elem)]
        [_ false])]
    [(AstTyPtr a-elem)
      (match b
        [(AstTyPtr b-elem) (ctfe-type-eq a-elem b-elem)]
        [_ false])]
    [(AstTyMutPtr a-elem)
      (match b
        [(AstTyMutPtr b-elem) (ctfe-type-eq a-elem b-elem)]
        [_ false])]
    [(AstTyRef a-region a-inner)
      (match b
        [(AstTyRef b-region b-inner)
          (and (string-eq a-region b-region) (ctfe-type-eq a-inner b-inner))]
        [_ false])]
    [(AstTyMutRef a-region a-inner)
      (match b
        [(AstTyMutRef b-region b-inner)
          (and (string-eq a-region b-region) (ctfe-type-eq a-inner b-inner))]
        [_ false])]
    [(AstTyRegion a-region a-inner)
      (match b
        [(AstTyRegion b-region b-inner)
          (and (string-eq a-region b-region) (ctfe-type-eq a-inner b-inner))]
        [_ false])]
    [(AstTyEnum a-name)
      (match b
        [(AstTyEnum b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstTyStruct a-name)
      (match b
        [(AstTyStruct b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstTyVar a-name)
      (match b
        [(AstTyVar b-name) (string-eq a-name b-name)]
        [_ false])]))

(define (compiler-ctfe-type-literal-ok?) : bool
  (let
    [want : AstType (AstTyArray (AstTyI64) 4)]
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
      (AstExprTypeLiteral (AstTyI64))
      (AstExprTypeLiteral (AstTyI64)))
    (ctfe-env-empty)
    (ctfe-fuel-limit))
    [(OkCtfe same _)
      (match same
        [(CtfeBool same-ok)
          (match (compiler-ctfe-eval
            (AstExprBinary
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
    (AstExprBinary
      (AstBinEq)
      (AstExprTypeLiteral (AstTyPtr (AstTyI64)))
      (AstExprTypeLiteral (AstTyPtr (AstTyI64))))
    (ctfe-env-empty)
    (ctfe-fuel-limit))
    [(OkCtfe same _)
      (match same
        [(CtfeBool same-ok)
          (match (compiler-ctfe-eval
            (AstExprBinary
              (AstBinEq)
              (AstExprTypeLiteral (AstTyPtr (AstTyI64)))
              (AstExprTypeLiteral (AstTyMutPtr (AstTyI64))))
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
  (AstExprCall (AstExprVar name) (AstExprCons arg AstExprNil)))

(define (compiler-ctfe-call2 [name : String] [a : AstExpr] [b : AstExpr]) : AstExpr
  (AstExprCall (AstExprVar name) (AstExprCons a (AstExprCons b AstExprNil))))

(define (compiler-ctfe-call3
  [name : String]
  [a : AstExpr]
  [b : AstExpr]
  [c : AstExpr]) : AstExpr
  (AstExprCall
    (AstExprVar name)
    (AstExprCons a (AstExprCons b (AstExprCons c AstExprNil)))))

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
              (CtfeLayoutFieldCons
                (CtfeLayoutField "count" 8)
                CtfeLayoutFieldNil)))
          (CtfeLayoutInfoCons
            (CtfeLayoutInfo "Box" false 8 8 CtfeLayoutFieldNil)
            CtfeLayoutInfoNil)))]
    (and
      (compiler-ctfe-eval-i64-ok?
        (compiler-ctfe-call1 "size-of" packet-ty)
        env
        16)
      (and
        (compiler-ctfe-eval-i64-ok?
          (compiler-ctfe-call1 "align-of" packet-ty)
          env
          8)
        (and
          (compiler-ctfe-eval-i64-ok?
            (compiler-ctfe-call2 "offset-of" packet-ty (AstExprVar "count"))
            env
            8)
          (and
            (compiler-ctfe-eval-i64-ok?
              (compiler-ctfe-call1 "size-of" box-ty)
              env
              8)
            (and
              (compiler-ctfe-eval-error-ok?
                (compiler-ctfe-call2 "offset-of" box-ty (AstExprVar "x"))
                env
                "offset-of requires repr c struct type")
              (compiler-ctfe-eval-error-ok?
                (compiler-ctfe-call2
                  "offset-of"
                  packet-ty
                  (AstExprVar "missing"))
                env
                "offset-of unknown field missing"))))))))

(define (compiler-ctfe-reflection-env) : CtfeEnv
  (ctfe-env-with-reflections
    (CtfeReflectInfoCons
      (CtfeReflectStruct
        "Point"
        ""
        "Point"
        (CtfeReflectFieldCons
          (CtfeReflectField "x" (AstTyI64))
          (CtfeReflectFieldCons
            (CtfeReflectField "flag" (AstTyBool))
            CtfeReflectFieldNil)))
      (CtfeReflectInfoCons
        (CtfeReflectEnum
          "Maybe"
          ""
          "Maybe"
          (CtfeReflectVariantCons
            (CtfeReflectVariant "None" AstTypeNil)
            (CtfeReflectVariantCons
              (CtfeReflectVariant "Some" (AstTypeCons (AstTyString) AstTypeNil))
              CtfeReflectVariantNil)))
        CtfeReflectInfoNil))))

(define (compiler-ctfe-reflection-query-ok?) : bool
  (let
    [env : CtfeEnv (compiler-ctfe-reflection-env)]
    [point-ty : AstExpr (AstExprTypeLiteral (AstTyVar "Point"))]
    [maybe-ty : AstExpr (AstExprTypeLiteral (AstTyVar "Maybe"))]
    [array-ty : AstExpr (AstExprTypeLiteral (AstTyArray (AstTyI64) 4))]
    [dyn-array-ty : AstExpr (AstExprTypeLiteral (AstTyDynArray (AstTyBool)))]
    [fn-ty : AstExpr
      (AstExprTypeLiteral
        (AstTyFunc
          (AstTypeCons (AstTyI64) (AstTypeCons (AstTyBool) AstTypeNil))
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
              (ctfe-expr-eq node (AstExprIf true-lit false-lit true-lit)))]
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

(define (compiler-ctfe-self-test) : i64
  (if (compiler-ctfe-type-literal-ok?)
    (if (compiler-ctfe-type-comparison-ok?)
      (if (compiler-ctfe-raw-pointer-type-comparison-ok?)
        (if (compiler-ctfe-layout-query-ok?)
          (if (compiler-ctfe-reflection-query-ok?)
            (if (compiler-ctfe-expr-eq-ok?)
              (if (compiler-ctfe-expr-list-ok?)
                (if (compiler-ctfe-expr-list-fold-sketch-ok?)
                  (if (compiler-ctfe-checked-expr-constructors-ok?)
                    (if (compiler-ctfe-checked-expr-inspectors-ok?)
                      (if (compiler-ctfe-checked-expr-rejects-non-bool-cond-ok?)
                        42
                        1)
                      1)
                    1)
                  1)
                1)
              1)
            1)
          1)
        1)
      1)
    1))