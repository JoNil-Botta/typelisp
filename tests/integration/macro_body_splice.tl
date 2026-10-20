(import stdlib.test)

(defmacro (in-let [body : Expr ...]) : Expr
  `(let
    [_value : i64 900]
    ,@body))

(defmacro (in-empty-let [body : Expr ...]) : Expr
  (quasiquote
    (let
      []
      (unquote-splicing body))))

(defmacro (in-lambda [body : Expr ...]) : Expr
  `((lambda () : i64
      ,@body)))

(defmacro (in-inferred-lambda [body : Expr ...]) : Expr
  `((lambda ()
      ,@body)))

(defmacro (in-match [value : Expr] [body : Expr ...]) : Expr
  `(match ,value
    [0 ,@body]
    [_ -1]))

(defmacro (in-cond [body : Expr ...]) : Expr
  `(cond [true ,@body] [else -1]))

(defmacro (in-while [condition : Expr] [body : Expr ...]) : Expr
  `(while ,condition
    ,@body))

(defmacro (in-nested-let [body : Expr ...]) : Expr
  `(let
    []
    (in-let ,@body)))

(defmacro (in-filtered-let [body : Expr ...]) : Expr
  `(let
    []
    (cfg body-splice-inactive unit)
    ,@body))

(defmacro (in-empty-match [body : Expr ...]) : Expr
  `(match 0
    [_ ,@body]))

(define (check-splices) : unit
  (let
    [_value : i64 42]
    [order : i64 0]
    [_cfg : unit
      (match 0
        [_ (cfg body-splice-inactive 42)])]
    (test.assert-i64-eq (in-let _value) 42 "caller hygiene")
    (test.assert-i64-eq
      (in-let
        (set! order (+ (* order 10) 1))
        (set! order (+ (* order 10) 2))
        (+ order 30))
      42
      "let sequence and final value")
    (test.assert-i64-eq order 12 "let evaluates each form once")
    (test.assert-i64-eq (in-empty-let 42) 42 "empty binding wrapper")
    (test.assert-i64-eq (in-empty-let 0 42) 42 "explicit splice spelling")
    (test.assert-i64-eq (in-lambda 42) 42 "lambda singleton")
    (test.assert-i64-eq (in-lambda 0 42) 42 "lambda sequence")
    (test.assert-i32-eq (in-inferred-lambda 0 42) 42 "inferred lambda")
    (test.assert-i64-eq (in-match 0 42) 42 "match singleton")
    (test.assert-i64-eq
      (in-match 0 (set! order 20) (+ order 22))
      42
      "match sequence")
    (test.assert-i64-eq (in-match 1 (set! order 999) 42) -1 "untaken arm")
    (test.assert-i64-eq order 20 "untaken splice is not evaluated")
    (test.assert-i64-eq (in-cond 20 42) 42 "cond body sequence")
    (test.assert-i64-eq (in-nested-let 20 42) 42 "nested expansion")
    (test.assert-i64-eq (in-filtered-let 42) 42 "inactive body form")
    (in-let)
    (in-empty-let)
    (in-inferred-lambda)
    (in-empty-match)
    (in-while (< order 22) (set! order (+ order 1)))
    (in-while (< order 42) (set! order (+ order 10)) unit)
    (in-while false (set! order 999))
    (test.assert-i64-eq order 42 "while singleton, sequence and zero trips")))

(define (main) : i64
  (check-splices)
  42)

(test lone-body-splice (check-splices))