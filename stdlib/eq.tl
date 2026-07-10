;# Generated equality modules for scalar and string values.
;#
;# Import this module, then instantiate a comparison module for the concrete
;# type being compared:
;#
;# ```typelisp
;# (import stdlib.eq)
;# (import (eq.eq i64) as i64_eq)
;# (define (same? [left : i64] [right : i64]) : bool
;#   (i64_eq.eq? left right))
;# ```
;#
;# Each `(eq T)` import has a canonical generated-module identity derived from
;# `type-key T`, so repeated imports share one generated implementation.
(defmacro (eq [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "stdlib.eq.generated." (type-key T)))]
    [kind : String (type-kind T)]
    [body : Expr
      (match kind
        ["i64" `(= left right)]
        ["i32" `(= left right)]
        ["i16" `(= left right)]
        ["i8" `(= left right)]
        ["u64" `(= left right)]
        ["u32" `(= left right)]
        ["u16" `(= left right)]
        ["u8" `(= left right)]
        ["f64" `(= left right)]
        ["f32" `(= left right)]
        ["bool" `(= left right)]
        ["char" `(= left right)]
        ["unit" `(= left right)]
        ["string" `(__tl_string_eq left right)]
        [_
          (comptime-error
            (string-append
              "stdlib.eq: structural equality is not implemented for "
              (type-key T)))])]
    `(begin
      (module ,module-name)
      (define (eq [left : ,T] [right : ,T]) : bool
        ,body)
      (define (eq? [left : ,T] [right : ,T]) : bool
        ,body))))

(cfg test (import stdlib.test))
(cfg test (import (eq i64) as eq_i64))
(cfg test (import (eq i64) as eq_i64_again))
(cfg test (import (eq String) as eq_string))

(cfg
  test
  (test
    eq-generated-scalar-and-string-modules
    (begin
      (test.assert-true (eq_i64.eq 42 42) "i64 equality succeeds")
      (test.assert-true (not (eq_i64.eq? 42 7)) "i64 equality detects mismatch")
      (test.assert-true
        (eq_i64_again.eq? 9 9)
        "duplicate generated i64 module import succeeds")
      (test.assert-true (eq_string.eq "same" "same") "string equality succeeds")
      (test.assert-true
        (not (eq_string.eq? "left" "right"))
        "string equality detects mismatch"))))