;; comptime_mut_call_builders.tl - compact generated mutable-call builders.
(import stdlib.comptime)
(import stdlib.test)

(defmacro (counter-module) : Module
  (let
    [clear-ref-name : comptime.Expr
      (comptime.expr-string "generated.mut_call_counter.clear-ref!")]
    [add-ref-name : comptime.Expr
      (comptime.expr-string "generated.mut_call_counter.add-ref!")]
    [assign-plus-ref-name : comptime.Expr
      (comptime.expr-string "generated.mut_call_counter.assign-plus-ref!")]
    `(module
      generated.mut_call_counter
      (import stdlib.comptime)
      (defstruct Counter
        (value i64))
      (define (clear-ref! [target : (&mut owner Counter)]) : unit
        (set! target.value 0))
      (define (add-ref! [target : (&mut owner Counter)] [delta : i64]) : unit
        (set! target.value (+ target.value delta)))
      (define (assign-plus-ref!
        [target : (&mut owner Counter)]
        [value : i64]
        [offset : i64]) : unit
        (set! target.value (+ value offset)))
      (defmacro (clear! [place : comptime.Expr]) : unit
        (comptime.expr-mut-call0 (expr-var ,clear-ref-name) place))
      (defmacro (add! [place : comptime.Expr] [delta : comptime.Expr]) : unit
        (comptime.expr-mut-call1 (expr-var ,add-ref-name) place delta))
      (defmacro (assign-plus!
        [place : comptime.Expr]
        [value : comptime.Expr]
        [offset : comptime.Expr]) : unit
        (comptime.expr-mut-call2
          (expr-var ,assign-plus-ref-name)
          place
          value
          offset)))))

(import (counter-module) as counter)

(test
  comptime-mut-call-builders-preserve-borrow-and-argument-order
  (let
    [item : counter.Counter (counter.Counter 7)]
    [evaluations : i64 0]
    (begin
      (counter.clear! item)
      (test.assert-i64-eq
        item.value
        0
        "zero-argument mutable call clears place")
      (counter.add!
        item
        (begin
          (set! evaluations (+ evaluations 1))
          evaluations))
      (test.assert-i64-eq
        item.value
        1
        "one-argument mutable call updates place")
      (counter.assign-plus!
        item
        (begin
          (set! evaluations (+ evaluations 1))
          (* evaluations 10))
        (begin
          (set! evaluations (+ evaluations 1))
          evaluations))
      (test.assert-i64-eq
        evaluations
        3
        "ordinary arguments evaluate once in order")
      (test.assert-i64-eq
        item.value
        23
        "two-argument mutable call receives ordered values"))))