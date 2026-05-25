;; compiler_ctfe.tl - Selfhost compile-time function evaluation (CTFE) for
;; expression-position `(comptime expr)` (#719, scalar subset).
;;
;; Ports the scalar slice of the Rust reference `src/ctfe.rs`. Supported
;; compile-time value types are i64, bool, char, unit, and type values. f64 compile-time
;; evaluation is intentionally out of scope here (the selfhost compiler stores
;; floats as opaque text with no arithmetic primitives) and is rejected with a
;; diagnostic citing #735.
;;
;; Evaluation is purely functional: the environment is an immutable cons list
;; threaded through recursion, and the step budget ("fuel") is threaded through
;; results so the evaluator stays deterministic without a mutable counter.
(import "compiler_ast_types.tl")

(import "compiler_diagnostic.tl")

;; A compile-time scalar value.
(defenum CompilerCtfeValue
  (CtfeI64 i64)
  (CtfeBool bool)
  (CtfeChar char)
  (CtfeUnit)
  (CtfeType AstType))

;; Immutable name -> value environment. Newest binding sits at the front so
;; lookup finds the most recent shadowing binding first.
(defenum CtfeEnv
  (CtfeEnvNil)
  (CtfeEnvCons String CompilerCtfeValue CtfeEnv))

(define (ctfe-env-empty) : CtfeEnv
  CtfeEnvNil)

(define (ctfe-env-extend
  [env : CtfeEnv]
  [name : String]
  [value : CompilerCtfeValue]) : CtfeEnv
  (CtfeEnvCons name value env))

;; Lookup result for an environment probe.
(defenum CtfeMaybeValue
  (CtfeNoValue)
  (CtfeSomeValue CompilerCtfeValue))

(define (ctfe-env-lookup [env : CtfeEnv] [name : String]) : CtfeMaybeValue
  (match env
    [(CtfeEnvNil) (CtfeNoValue)]
    [(CtfeEnvCons key value rest)
      (if (string-eq key name)
        (CtfeSomeValue value)
        (ctfe-env-lookup rest name))]))

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
    [(AstExprSet _ _) "set!"]
    [(AstExprAnn _ _) "type annotation"]
    [(AstExprCast _ _) "cast"]
    [(AstExprMatch _ _) "match"]
    [(AstExprForeach _ _ _ _ _) "foreach"]
    [(AstExprSpmdReduce _ _ _ _ _ _ _) "spmd-reduce"]
    [(AstExprStructGet _ _) "struct-get"]
    [(AstExprWithRegion _ _) "with-region"]
    [(AstExprTypeLiteral _) "type literal"]
    [(AstExprComptime _) "comptime"]
    [(AstExprTry _) "try"]))

(define (ctfe-value-type-name [value : CompilerCtfeValue]) : String
  (match value
    [(CtfeI64 _) "i64"]
    [(CtfeBool _) "bool"]
    [(CtfeChar _) "char"]
    [(CtfeUnit) "unit"]
    [(CtfeType _) "type"]))

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
    [(AstLitString _)
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          "strings are not supported in compile-time evaluation"))]))

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
    [(AstExprTypeLiteral ty) (OkCtfe (CtfeType ty) fuel)]
    [(AstExprLiteral lit) (ctfe-eval-literal lit expr fuel)]
    [(AstExprVar name) (ctfe-eval-var name expr env fuel)]
    [(AstExprBinary op left right)
      (ctfe-eval-binary op left right expr env fuel)]
    [(AstExprUnary op inner) (ctfe-eval-unary op inner expr env fuel)]
    [(AstExprIf cond then-branch else-branch)
      (ctfe-eval-if cond then-branch else-branch env fuel)]
    [(AstExprLet bindings body) (ctfe-eval-let bindings body env fuel)]
    [(AstExprBegin exprs) (ctfe-eval-begin exprs env fuel)]
    [_
      (ErrCtfe
        (ctfe-diagnostic-at-expr
          expr
          (string-append
            "'"
            (string-append
              (ctfe-describe-expr expr)
              "' is not supported in compile-time evaluation"))))]))

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

;; --- folding ----------------------------------------------------------------
;; Convert a folded compile-time value into the AST literal that lowering then
;; materializes through the ordinary literal path.
(define (ctfe-value-to-literal [value : CompilerCtfeValue]) : AstLiteral
  (match value
    [(CtfeI64 n) (AstLitInt n)]
    [(CtfeBool b) (AstLitBool b)]
    [(CtfeChar c) (AstLitChar c)]
    [(CtfeUnit) (AstLitUnit)]
    [(CtfeType _) (AstLitUnit)]))

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

(define (compiler-ctfe-self-test) : i64
  (if (compiler-ctfe-type-literal-ok?)
    (if (compiler-ctfe-type-comparison-ok?)
      (if (compiler-ctfe-raw-pointer-type-comparison-ok?)
        42
        1)
      1)
    1))