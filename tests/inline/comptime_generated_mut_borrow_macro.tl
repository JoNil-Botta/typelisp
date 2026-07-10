;; comptime_generated_mut_borrow_macro.tl - public comptime constructors let a
;; module macro generate a qualified place-taking macro without nested quotes.
(import stdlib.comptime)
(import stdlib.test)

(defmacro (counter-module) : Module
  (let
    [empty : comptime.ExprList (comptime.expr-list-empty)]
    [place : comptime.Expr (comptime.expr-var "place")]
    [value : comptime.Expr (comptime.expr-var "value")]
    [empty-call : comptime.Expr
      (comptime.expr-call (comptime.expr-var "expr-list-empty") empty)]
    [borrow : comptime.Expr
      (comptime.expr-call
        (comptime.expr-var "expr-mut-borrow")
        (comptime.expr-list-cons place empty))]
    [tail : comptime.Expr
      (comptime.expr-call
        (comptime.expr-var "expr-list-cons")
        (comptime.expr-list-cons
          value
          (comptime.expr-list-cons empty-call empty)))]
    [args : comptime.Expr
      (comptime.expr-call
        (comptime.expr-var "expr-list-cons")
        (comptime.expr-list-cons borrow (comptime.expr-list-cons tail empty)))]
    [callee : comptime.Expr
      (comptime.expr-call
        (comptime.expr-var "expr-var")
        (comptime.expr-list-cons
          (comptime.expr-string "generated.counter.assign-ref")
          empty))]
    [body : comptime.Expr
      (comptime.expr-call
        (comptime.expr-var "expr-call")
        (comptime.expr-list-cons callee (comptime.expr-list-cons args empty)))]
    `(module
      generated.counter
      (import stdlib.comptime)
      (defstruct Counter
        (value i64))
      (define (assign-ref [target : (&mut owner Counter)] [next : i64]) : unit
        (set! target.value next))
      (defmacro (assign! [place : comptime.Expr] [value : comptime.Expr]) : unit
        ,body))))

(import (counter-module) as counter)

(test
  generated-module-macro-expands-explicit-mutable-borrow-call
  (let
    [item : counter.Counter (counter.Counter 0)]
    [evaluations : i64 0]
    (begin
      (counter.assign!
        item
        (begin
          (set! evaluations (+ evaluations 1))
          42))
      (test.assert-i64-eq
        item.value
        42
        "generated macro mutates its caller place")
      (test.assert-i64-eq
        evaluations
        1
        "generated macro evaluates its value once"))))