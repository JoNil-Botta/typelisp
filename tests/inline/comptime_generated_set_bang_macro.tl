;; A computed generated macro name that matches the language `set!` spelling
;; remains discoverable through qualified macro resolution. Bare `set!` is a
;; parser form and is unaffected.
(import stdlib.comptime)
(import stdlib.test)

(defmacro (generated-set-module) : Module
  (let
    [set-name : comptime.Expr (comptime.expr-var "set!")]
    [helper-name : comptime.Expr
      (comptime.expr-string "generated_set_bang.assign-ref!")]
    `(begin
      (module generated_set_bang)
      (defstruct Cell
        (value i64))
      (define (assign-ref! [cell : (&mut owner Cell)] [value : i64]) : unit
        (set! cell.value value))
      (defmacro (,set-name [place : Expr] [value : Expr]) : unit
        (expr-mut-call1 (expr-var ,helper-name) place value)))))

(import (generated-set-module) as generated)

(test
  computed-generated-set-bang-macro-resolves-qualified
  (let
    [cell : generated.Cell (generated.Cell 0)]
    (begin
      (generated.set! cell 42)
      (test.assert-i64-eq cell.value 42 "computed set! macro mutates place"))))