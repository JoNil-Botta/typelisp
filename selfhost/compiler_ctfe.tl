;; Compile-time function evaluation (CTFE) for expression-position

;; `(comptime expr)` (#719). Mirrors the scalar subset of the Rust reference

;; `src/ctfe.rs`: only `i64` / `bool` / `char` / `unit` values are produced.

;; Floating point (#735), strings, runtime-variable references, and every

;; side-effecting / aggregate / call / loop form are rejected with a clear

;; diagnostic rather than panicking. Evaluation is bounded by a deterministic

;; per-step fuel counter so it always terminates.

(import "compiler_ast_types.tl")

(import "compiler_diagnostic.tl")

;; A compile-time scalar value. No `CtfeF64` in this slice (tracked by #735).

(defenum CompilerCtfeValue
  (CtfeI64 i64)
  (CtfeBool bool)
  (CtfeChar char)
  (CtfeUnit))

;; Immutable `String -> CompilerCtfeValue` binding chain, newest first.

(defenum CompilerCtfeEnv
  (CtfeEnvNil)
  (CtfeEnvBind String CompilerCtfeValue CompilerCtfeEnv))

;; Evaluation result. `OkCtfe` carries the value and the remaining fuel, so the

;; per-step limit threads functionally through the recursion.

(defenum ResultCtfe
  (OkCtfe CompilerCtfeValue i64)
  (ErrCtfe CompilerDiagnostic))

;; Result of evaluating a `let` binding group: the extended environment plus the

;; remaining fuel, or a diagnostic.

(defenum ResultCtfeEnv
  (OkCtfeEnv CompilerCtfeEnv i64)
  (ErrCtfeEnv CompilerDiagnostic))

(defenum MaybeCtfeValue
  (NoneCtfeValue)
  (SomeCtfeValue CompilerCtfeValue))

(defenum MaybeCtfeBool
  (NoneCtfeBool)
  (SomeCtfeBool bool))

;; Per-`comptime` step budget, matching the Rust evaluator's 10,000.

(define (compiler-ctfe-initial-fuel) : i64
  10000)

(define (ctfe-env-empty) : CompilerCtfeEnv
  (CtfeEnvNil))

(define (ctfe-env-lookup [env : CompilerCtfeEnv] [name : String]) : MaybeCtfeValue
  (match env
    [(CtfeEnvNil) (NoneCtfeValue)]
    [(CtfeEnvBind key value rest)
      (if (string-eq key name)
        (SomeCtfeValue value)
        (ctfe-env-lookup rest name))]))

;; Construct an evaluation error with a start-of-file diagnostic (the loader

;; fills in the real path; the comptime lower site supplies span context).

(define (ctfe-err [message : String]) : ResultCtfe
  (ErrCtfe (compiler-diagnostic-at-start "" message)))

(define (ctfe-value-type-name [value : CompilerCtfeValue]) : String
  (match value
    [(CtfeI64 _) "i64"]
    [(CtfeBool _) "bool"]
    [(CtfeChar _) "char"]
    [(CtfeUnit) "unit"]))

(define (ctfe-binop-name [op : AstBinOp]) : String
  (match op
    [(AstBinAdd) "+"]
    [(AstBinSub) "-"]
    [(AstBinMul) "*"]
    [(AstBinDiv) "/"]
    [(AstBinMod) "%"]
    [(AstBinEq) "=="]
    [(AstBinNe) "!="]
    [(AstBinLt) "<"]
    [(AstBinLe) "<="]
    [(AstBinGt) ">"]
    [(AstBinGe) ">="]
    [(AstBinAnd) "and"]
    [(AstBinOr) "or"]
    [(AstBinBitAnd) "bit-and"]
    [(AstBinBitOr) "bit-or"]
    [(AstBinBitXor) "bit-xor"]
    [(AstBinShl) "shl"]
    [(AstBinShr) "shr"]))

;; Short human name for an unsupported expression form, for diagnostics.

(define (ctfe-describe-expr [expr : AstExpr]) : String
  (match expr
    [(AstExprSpanned _ _) "expression"]
    [(AstExprLiteral _) "literal"]
    [(AstExprVar _) "variable reference"]
    [(AstExprBinary _ _ _) "binary operation"]
    [(AstExprUnary _ _) "unary operation"]
    [(AstExprCall _ _) "function call"]
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
    [(AstExprStructGet _ _) "struct-get"]
    [(AstExprComptime _) "comptime"]))

;; i64 arithmetic + bitwise ops. Division/modulo by zero are rejected (the

;; runtime would trap); the others wrap two's-complement like the runtime ops.

(define (ctfe-i64-arith [op : AstBinOp] [a : i64] [b : i64] [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinAdd) (OkCtfe (CtfeI64 (+ a b)) fuel)]
    [(AstBinSub) (OkCtfe (CtfeI64 (- a b)) fuel)]
    [(AstBinMul) (OkCtfe (CtfeI64 (* a b)) fuel)]
    [(AstBinDiv)
      (if (= b 0)
        (ctfe-err "division by zero in comptime")
        (OkCtfe (CtfeI64 (/ a b)) fuel))]
    [(AstBinMod)
      (if (= b 0)
        (ctfe-err "modulo by zero in comptime")
        (OkCtfe (CtfeI64 (% a b)) fuel))]
    [(AstBinBitAnd) (OkCtfe (CtfeI64 (bit-and a b)) fuel)]
    [(AstBinBitOr) (OkCtfe (CtfeI64 (bit-or a b)) fuel)]
    [(AstBinBitXor) (OkCtfe (CtfeI64 (bit-xor a b)) fuel)]
    [(AstBinShl) (OkCtfe (CtfeI64 (shl a b)) fuel)]
    [(AstBinShr) (OkCtfe (CtfeI64 (shr a b)) fuel)]
    [_ (ctfe-err "internal: non-arithmetic op in ctfe-i64-arith")]))

(define (ctfe-require-i64-pair
  [op : AstBinOp]
  [lv : CompilerCtfeValue]
  [rv : CompilerCtfeValue]
  [fuel : i64]) : ResultCtfe
  (match lv
    [(CtfeI64 a)
      (match rv
        [(CtfeI64 b) (ctfe-i64-arith op a b fuel)]
        [_
          (ctfe-err
            (string-append
              (ctfe-binop-name op)
              " in comptime requires i64 operands"))])]
    [_
      (ctfe-err
        (string-append
          (ctfe-binop-name op)
          " in comptime requires i64 operands"))]))

;; Structural equality over matching scalar kinds. `NoneCtfeBool` signals a

;; type mismatch (incomparable kinds).

(define (ctfe-values-equal [a : CompilerCtfeValue] [b : CompilerCtfeValue]) : MaybeCtfeBool
  (match a
    [(CtfeI64 x)
      (match b
        [(CtfeI64 y) (SomeCtfeBool (= x y))]
        [_ (NoneCtfeBool)])]
    [(CtfeBool x)
      (match b
        [(CtfeBool y)
          (SomeCtfeBool
            (if x
              y
              (not y)))]
        [_ (NoneCtfeBool)])]
    [(CtfeChar x)
      (match b
        [(CtfeChar y) (SomeCtfeBool (= x y))]
        [_ (NoneCtfeBool)])]
    [(CtfeUnit)
      (match b
        [(CtfeUnit) (SomeCtfeBool true)]
        [_ (NoneCtfeBool)])]))

(define (ctfe-equality
  [op : AstBinOp]
  [lv : CompilerCtfeValue]
  [rv : CompilerCtfeValue]
  [fuel : i64]
  [negate : bool]) : ResultCtfe
  (match (ctfe-values-equal lv rv)
    [(SomeCtfeBool eq)
      (OkCtfe
        (CtfeBool
          (if negate
            (not eq)
            eq))
        fuel)]
    [(NoneCtfeBool)
      (ctfe-err
        (string-append
          (ctfe-binop-name op)
          " in comptime requires matching scalar types"))]))

;; Ordered comparison of two i64 magnitudes (chars compare via their codes).

(define (ctfe-order-result [op : AstBinOp] [a : i64] [b : i64] [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinLt) (OkCtfe (CtfeBool (< a b)) fuel)]
    [(AstBinLe) (OkCtfe (CtfeBool (<= a b)) fuel)]
    [(AstBinGt) (OkCtfe (CtfeBool (> a b)) fuel)]
    [(AstBinGe) (OkCtfe (CtfeBool (>= a b)) fuel)]
    [_ (ctfe-err "internal: non-order op in ctfe-order-result")]))

(define (ctfe-ordered
  [op : AstBinOp]
  [lv : CompilerCtfeValue]
  [rv : CompilerCtfeValue]
  [fuel : i64]) : ResultCtfe
  (match lv
    [(CtfeI64 a)
      (match rv
        [(CtfeI64 b) (ctfe-order-result op a b fuel)]
        [_
          (ctfe-err
            (string-append
              (ctfe-binop-name op)
              " in comptime requires matching ordered types"))])]
    [(CtfeChar a)
      (match rv
        [(CtfeChar b) (ctfe-order-result op (cast a : i64) (cast b : i64) fuel)]
        [_
          (ctfe-err
            (string-append
              (ctfe-binop-name op)
              " in comptime requires matching ordered types"))])]
    [_
      (ctfe-err
        (string-append
          (ctfe-binop-name op)
          " in comptime requires ordered i64 or char operands"))]))

(define (ctfe-bool-op
  [op : AstBinOp]
  [lv : CompilerCtfeValue]
  [rv : CompilerCtfeValue]
  [fuel : i64]) : ResultCtfe
  (match lv
    [(CtfeBool a)
      (match rv
        [(CtfeBool b)
          (match op
            [(AstBinAnd) (OkCtfe (CtfeBool (and a b)) fuel)]
            [(AstBinOr) (OkCtfe (CtfeBool (or a b)) fuel)]
            [_ (ctfe-err "internal: non-bool op in ctfe-bool-op")])]
        [_
          (ctfe-err
            (string-append
              (ctfe-binop-name op)
              " in comptime requires bool operands"))])]
    [_
      (ctfe-err
        (string-append
          (ctfe-binop-name op)
          " in comptime requires bool operands"))]))

(define (ctfe-apply-binary
  [op : AstBinOp]
  [lv : CompilerCtfeValue]
  [rv : CompilerCtfeValue]
  [fuel : i64]) : ResultCtfe
  (match op
    [(AstBinAdd) (ctfe-require-i64-pair op lv rv fuel)]
    [(AstBinSub) (ctfe-require-i64-pair op lv rv fuel)]
    [(AstBinMul) (ctfe-require-i64-pair op lv rv fuel)]
    [(AstBinDiv) (ctfe-require-i64-pair op lv rv fuel)]
    [(AstBinMod) (ctfe-require-i64-pair op lv rv fuel)]
    [(AstBinBitAnd) (ctfe-require-i64-pair op lv rv fuel)]
    [(AstBinBitOr) (ctfe-require-i64-pair op lv rv fuel)]
    [(AstBinBitXor) (ctfe-require-i64-pair op lv rv fuel)]
    [(AstBinShl) (ctfe-require-i64-pair op lv rv fuel)]
    [(AstBinShr) (ctfe-require-i64-pair op lv rv fuel)]
    [(AstBinEq) (ctfe-equality op lv rv fuel false)]
    [(AstBinNe) (ctfe-equality op lv rv fuel true)]
    [(AstBinLt) (ctfe-ordered op lv rv fuel)]
    [(AstBinLe) (ctfe-ordered op lv rv fuel)]
    [(AstBinGt) (ctfe-ordered op lv rv fuel)]
    [(AstBinGe) (ctfe-ordered op lv rv fuel)]
    [(AstBinAnd) (ctfe-bool-op op lv rv fuel)]
    [(AstBinOr) (ctfe-bool-op op lv rv fuel)]))

(define (ctfe-apply-unary [op : AstUnOp] [v : CompilerCtfeValue] [fuel : i64]) : ResultCtfe
  (match op
    [(AstUnNeg)
      (match v
        [(CtfeI64 n) (OkCtfe (CtfeI64 (- 0 n)) fuel)]
        [_
          (ctfe-err
            (string-append
              "negation in comptime requires i64, got "
              (ctfe-value-type-name v)))])]
    [(AstUnNot)
      (match v
        [(CtfeBool b) (OkCtfe (CtfeBool (not b)) fuel)]
        [_
          (ctfe-err
            (string-append
              "'not' in comptime requires bool, got "
              (ctfe-value-type-name v)))])]
    [(AstUnBitNot)
      (match v
        [(CtfeI64 n) (OkCtfe (CtfeI64 (bit-not n)) fuel)]
        [_
          (ctfe-err
            (string-append
              "bitwise not in comptime requires i64, got "
              (ctfe-value-type-name v)))])]))

(define (ctfe-eval-literal [lit : AstLiteral] [fuel : i64]) : ResultCtfe
  (match lit
    [(AstLitInt n) (OkCtfe (CtfeI64 n) fuel)]
    [(AstLitBool b) (OkCtfe (CtfeBool b) fuel)]
    [(AstLitChar c) (OkCtfe (CtfeChar c) fuel)]
    [(AstLitUnit) (OkCtfe (CtfeUnit) fuel)]
    [(AstLitString _)
      (ctfe-err "strings are not supported in compile-time evaluation")]
    [(AstLitFloat _)
      (ctfe-err
        "f64 values are not supported in compile-time evaluation yet (#735)")]))

;; Evaluate a `(comptime expr)` body. `env` holds comptime `let` bindings (empty

;; at the comptime boundary); `fuel` bounds the number of evaluation steps.

(define (compiler-ctfe-eval
  [expr : AstExpr]
  [env : CompilerCtfeEnv]
  [fuel : i64]) : ResultCtfe
  (if (<= fuel 0)
    (ctfe-err "compile-time evaluation limit exceeded")
    (let ([rest : i64 (- fuel 1)])
      (match expr
        [(AstExprSpanned inner _) (compiler-ctfe-eval inner env rest)]
        [(AstExprAnn inner _) (compiler-ctfe-eval inner env rest)]
        [(AstExprComptime inner) (compiler-ctfe-eval inner env rest)]
        [(AstExprLiteral lit) (ctfe-eval-literal lit rest)]
        [(AstExprVar name)
          (match (ctfe-env-lookup env name)
            [(SomeCtfeValue v) (OkCtfe v rest)]
            [(NoneCtfeValue)
              (ctfe-err
                (string-append
                  "compile-time evaluation cannot reference runtime variable '"
                  (string-append name "'")))])]
        [(AstExprBinary op lhs rhs)
          (match (compiler-ctfe-eval lhs env rest)
            [(OkCtfe lv f1)
              (match (compiler-ctfe-eval rhs env f1)
                [(OkCtfe rv f2) (ctfe-apply-binary op lv rv f2)]
                [(ErrCtfe d) (ErrCtfe d)])]
            [(ErrCtfe d) (ErrCtfe d)])]
        [(AstExprUnary op inner)
          (match (compiler-ctfe-eval inner env rest)
            [(OkCtfe v f1) (ctfe-apply-unary op v f1)]
            [(ErrCtfe d) (ErrCtfe d)])]
        [(AstExprIf cond then-branch else-branch)
          (match (compiler-ctfe-eval cond env rest)
            [(OkCtfe cv f1)
              (match cv
                [(CtfeBool b)
                  (if b
                    (compiler-ctfe-eval then-branch env f1)
                    (compiler-ctfe-eval else-branch env f1))]
                [_
                  (ctfe-err
                    (string-append
                      "comptime 'if' condition must be bool, got "
                      (ctfe-value-type-name cv)))])]
            [(ErrCtfe d) (ErrCtfe d)])]
        [(AstExprLet bindings body)
          (match (ctfe-eval-let-bindings bindings env rest)
            [(OkCtfeEnv next-env f1) (compiler-ctfe-eval body next-env f1)]
            [(ErrCtfeEnv d) (ErrCtfe d)])]
        [(AstExprBegin exprs) (ctfe-eval-begin exprs env rest)]
        [_
          (ctfe-err
            (string-append
              (ctfe-describe-expr expr)
              " is not supported in compile-time evaluation"))]))))

;; Evaluate `let` bindings sequentially: each initializer sees the bindings

;; before it, mirroring the runtime `let`.

(define (ctfe-eval-let-bindings
  [bindings : AstLetBindingList]
  [env : CompilerCtfeEnv]
  [fuel : i64]) : ResultCtfeEnv
  (match bindings
    [(AstLetBindingNil) (OkCtfeEnv env fuel)]
    [(AstLetBindingCons binding rest-bindings)
      (match binding
        [(AstLetBinding name _ value-expr)
          (match (compiler-ctfe-eval value-expr env fuel)
            [(OkCtfe v f1)
              (ctfe-eval-let-bindings rest-bindings (CtfeEnvBind name v env) f1)]
            [(ErrCtfe d) (ErrCtfeEnv d)])])]))

;; Evaluate a `begin` sequence, returning the last value (`unit` if empty).

(define (ctfe-eval-begin
  [exprs : AstExprList]
  [env : CompilerCtfeEnv]
  [fuel : i64]) : ResultCtfe
  (match exprs
    [(AstExprNil) (OkCtfe (CtfeUnit) fuel)]
    [(AstExprCons head tail)
      (match (compiler-ctfe-eval head env fuel)
        [(OkCtfe v f1)
          (match tail
            [(AstExprNil) (OkCtfe v f1)]
            [(AstExprCons _ _) (ctfe-eval-begin tail env f1)])]
        [(ErrCtfe d) (ErrCtfe d)])]))

;; --- self-test -------------------------------------------------------------

(define (ctfe-int [n : i64]) : AstExpr
  (AstExprLiteral (AstLitInt n)))

(define (ctfe-bool-lit [b : bool]) : AstExpr
  (AstExprLiteral (AstLitBool b)))

(define (ctfe-str-lit [s : String]) : AstExpr
  (AstExprLiteral (AstLitString s)))

(define (ctfe-run [expr : AstExpr]) : ResultCtfe
  (compiler-ctfe-eval expr (ctfe-env-empty) (compiler-ctfe-initial-fuel)))

(define (ctfe-result-is-i64? [r : ResultCtfe] [expected : i64]) : bool
  (match r
    [(OkCtfe v _)
      (match v
        [(CtfeI64 n) (= n expected)]
        [_ false])]
    [(ErrCtfe _) false]))

(define (ctfe-result-is-bool? [r : ResultCtfe] [expected : bool]) : bool
  (match r
    [(OkCtfe v _)
      (match v
        [(CtfeBool b)
          (if expected
            b
            (not b))]
        [_ false])]
    [(ErrCtfe _) false]))

(define (ctfe-result-is-err? [r : ResultCtfe]) : bool
  (match r
    [(OkCtfe _ _) false]
    [(ErrCtfe _) true]))

(define (ctfe-bin [op : AstBinOp] [a : AstExpr] [b : AstExpr]) : AstExpr
  (AstExprBinary op a b))

;; `(+ 1 2)` => 3, `(* 4 5)` => 20, `(- 3 10)` => -7, `(/ 1 0)` rejected,

;; `(< 1 2)` => true, `(bit-and 6 3)` => 2.

(define (compiler-ctfe-fold-ok?) : bool
  (and
    (ctfe-result-is-i64?
      (ctfe-run (ctfe-bin (AstBinAdd) (ctfe-int 1) (ctfe-int 2)))
      3)
    (and
      (ctfe-result-is-i64?
        (ctfe-run (ctfe-bin (AstBinMul) (ctfe-int 4) (ctfe-int 5)))
        20)
      (and
        (ctfe-result-is-i64?
          (ctfe-run (ctfe-bin (AstBinSub) (ctfe-int 3) (ctfe-int 10)))
          -7)
        (and
          (ctfe-result-is-err?
            (ctfe-run (ctfe-bin (AstBinDiv) (ctfe-int 1) (ctfe-int 0))))
          (and
            (ctfe-result-is-bool?
              (ctfe-run (ctfe-bin (AstBinLt) (ctfe-int 1) (ctfe-int 2)))
              true)
            (ctfe-result-is-i64?
              (ctfe-run (ctfe-bin (AstBinBitAnd) (ctfe-int 6) (ctfe-int 3)))
              2)))))))

;; `if` takes only the chosen branch (the untaken branch is a string literal

;; that would error if evaluated); `let` binds sequentially; `begin` yields the

;; last value.

(define (compiler-ctfe-control-ok?) : bool
  (and
    (ctfe-result-is-i64?
      (ctfe-run
        (AstExprIf (ctfe-bool-lit true) (ctfe-int 10) (ctfe-str-lit "x")))
      10)
    (and
      (ctfe-result-is-i64?
        (ctfe-run
          (AstExprIf (ctfe-bool-lit false) (ctfe-str-lit "x") (ctfe-int 20)))
        20)
      (and
        (ctfe-result-is-i64?
          (ctfe-run
            (AstExprLet
              (AstLetBindingCons
                (AstLetBinding "x" (AstNoType) (ctfe-int 5))
                (AstLetBindingNil))
              (ctfe-bin (AstBinMul) (AstExprVar "x") (AstExprVar "x"))))
          25)
        (ctfe-result-is-i64?
          (ctfe-run
            (AstExprBegin
              (AstExprCons
                (ctfe-int 1)
                (AstExprCons
                  (ctfe-int 2)
                  (AstExprCons (ctfe-int 3) (AstExprNil))))))
          3)))))

;; Runtime variables, strings, floats, and unsupported forms are rejected.

(define (compiler-ctfe-reject-ok?) : bool
  (and
    (ctfe-result-is-err? (ctfe-run (AstExprVar "y")))
    (and
      (ctfe-result-is-err? (ctfe-run (ctfe-str-lit "hi")))
      (and
        (ctfe-result-is-err? (ctfe-run (AstExprLiteral (AstLitFloat "1.5"))))
        (ctfe-result-is-err?
          (ctfe-run (AstExprCall (AstExprVar "f") (AstExprNil))))))))

;; Fuel is finite and deterministic: `(+ 1 2)` needs more than one step, so a

;; one-unit budget is exhausted.

(define (compiler-ctfe-fuel-ok?) : bool
  (ctfe-result-is-err?
    (compiler-ctfe-eval
      (ctfe-bin (AstBinAdd) (ctfe-int 1) (ctfe-int 2))
      (ctfe-env-empty)
      1)))

(define (compiler-ctfe-self-test) : i64
  (if (compiler-ctfe-fold-ok?)
    (if (compiler-ctfe-control-ok?)
      (if (compiler-ctfe-reject-ok?)
        (if (compiler-ctfe-fuel-ok?)
          42
          4)
        3)
      2)
    1))