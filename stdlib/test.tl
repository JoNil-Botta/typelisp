;# Minimal TypeLisp test assertion helpers.
;#
;# Provides assertion helpers for TypeLisp fixtures using only compiler/runtime
;# primitives: `panic`, `string-eq`, and `cast`.
;#
;# Usage: `(import "stdlib/test.tl")`
;#
;# ```typelisp
;# (import "stdlib/test.tl")
;# (define (main) : i64
;#   (begin
;#     (assert-true true "expected true")
;#     42))
;# ```
;: Assert that `condition` is true, panicking with `message` when it is false.
(define (assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (panic message)))

;: Assert that `condition` is false, panicking with `message` when it is true.
(define (assert-false [condition : bool] [message : String]) : unit
  (assert-true (not condition) message))

;: Assert that two bool values are equal.
;:
;: Successful assertions do not allocate. Failures call `panic` with the
;: caller-provided message.
(define (assert-bool-eq [actual : bool] [expected : bool] [message : String]) : unit
  (assert-true (= actual expected) message))

;: Assert that two i64 values are equal.
(define (assert-i64-eq [actual : i64] [expected : i64] [message : String]) : unit
  (assert-true (= actual expected) message))

;: Assert that two i32 values are equal.
(define (assert-i32-eq [actual : i32] [expected : i32] [message : String]) : unit
  (assert-true (= actual expected) message))

;: Assert that two f64 values are equal.
(define (assert-f64-eq [actual : f64] [expected : f64] [message : String]) : unit
  (assert-true (= actual expected) message))

;: Assert that two char values have the same scalar code.
(define (assert-char-eq [actual : char] [expected : char] [message : String]) : unit
  (assert-true (= (cast actual : i64) (cast expected : i64)) message))

;: Assert that two String values compare equal without allocating on success.
;:
;: ```typelisp
;: (import "stdlib/test.tl")
;: (define (test-doc-assert) : unit
;:   (assert-string-eq "ok" "ok" "strings should match"))
;: ```
(define (assert-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-true (string-eq actual expected) message))