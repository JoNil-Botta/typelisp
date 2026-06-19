;# Minimal TypeLisp test assertion helpers.
;#
;# Provides assertion helpers for TypeLisp fixtures using stdlib panic and
;# non-allocating borrowed string comparison.
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
(import "io.tl")
(import "string.tl")

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

;: Assert that two borrowed text values compare equal without allocating on success.
;:
;: Messages intentionally remain owned `String` values while `panic` exposes an
;: owned-string public API.
;:
;: ```typelisp
;: (import "stdlib/test.tl")
;: (define (test-doc-assert) : unit
;:   (let
;:     [actual : String "ok"]
;:     [expected : String "ok"]
;:     (assert-string-eq (& actual) (& expected) "strings should match")))
;: ```
(define (assert-string-eq
  [actual : (& actual str)]
  [expected : (& expected str)]
  [message : String]) : unit
  (assert-true (string-eq-borrowed actual expected) message))

(test
  test-assert-success
  (let
    [actual : String "hello"]
    [expected : String "hello"]
    (begin
      (assert-true true "true should pass")
      (assert-false false "false should pass")
      (assert-bool-eq true true "bool equality should pass")
      (assert-i64-eq 42 42 "i64 equality should pass")
      (assert-i32-eq (cast 7 : i32) (cast 7 : i32) "i32 equality should pass")
      (assert-f64-eq 1.5 1.5 "f64 equality should pass")
      (assert-char-eq 'A' 'A' "char equality should pass")
      (assert-string-eq (& actual) (& expected) "string equality should pass"))))