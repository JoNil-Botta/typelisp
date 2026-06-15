;# Minimal TypeLisp test assertion helpers.
;#
;# Provides assertion helpers for TypeLisp fixtures using stdlib panic and
;# non-allocating borrowed string comparison.
;#
;# Usage: `(import stdlib.test)`
;#
;# ```typelisp
;# (import stdlib.test)
;# (define (main) : i64
;#   (begin
;#     (test.assert-true true "expected true")
;#     42))
;# ```
(module stdlib.test)

(import stdlib.io as io_mod)

(import stdlib.string as string_mod)

;: Assert that `condition` is true, panicking with `message` when it is false.
(define (assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (io_mod.panic message)))

;: Assert that `condition` is false, panicking with `message` when it is true.
(define (assert-false [condition : bool] [message : String]) : unit
  (stdlib.test.assert-true (not condition) message))

;: Assert that two bool values are equal.
;:
;: Successful assertions do not allocate. Failures call `panic` with the
;: caller-provided message.
(define (assert-bool-eq [actual : bool] [expected : bool] [message : String]) : unit
  (stdlib.test.assert-true (= actual expected) message))

;: Assert that two i64 values are equal.
(define (assert-i64-eq [actual : i64] [expected : i64] [message : String]) : unit
  (stdlib.test.assert-true (= actual expected) message))

;: Assert that two i32 values are equal.
(define (assert-i32-eq [actual : i32] [expected : i32] [message : String]) : unit
  (stdlib.test.assert-true (= actual expected) message))

;: Assert that two f64 values are equal.
(define (assert-f64-eq [actual : f64] [expected : f64] [message : String]) : unit
  (stdlib.test.assert-true (= actual expected) message))

;: Assert that two char values have the same scalar code.
(define (assert-char-eq [actual : char] [expected : char] [message : String]) : unit
  (stdlib.test.assert-true
    (= (cast actual : i64) (cast expected : i64))
    message))

;: Assert that two borrowed text values compare equal without allocating on success.
;:
;: Messages intentionally remain owned `String` values while `panic` exposes an
;: owned-string public API.
;:
;: ```typelisp
;: (import stdlib.test)
;: (define (test-doc-assert) : unit
;:   (let
;:     [actual : String "ok"]
;:     [expected : String "ok"]
;:     (test.assert-string-eq (& actual) (& expected) "strings should match")))
;: ```
(define (assert-string-eq
  [actual : (& actual str)]
  [expected : (& expected str)]
  [message : String]) : unit
  (stdlib.test.assert-true
    (string_mod.string-eq-borrowed actual expected)
    message))

(test
  test-assert-success
  (let
    [actual : String "hello"]
    [expected : String "hello"]
    (begin
      (stdlib.test.assert-true true "true should pass")
      (stdlib.test.assert-false false "false should pass")
      (stdlib.test.assert-bool-eq true true "bool equality should pass")
      (stdlib.test.assert-i64-eq 42 42 "i64 equality should pass")
      (stdlib.test.assert-i32-eq
        (cast 7 : i32)
        (cast 7 : i32)
        "i32 equality should pass")
      (stdlib.test.assert-f64-eq 1.5 1.5 "f64 equality should pass")
      (stdlib.test.assert-char-eq #A' #A' "char equality should pass")
      (stdlib.test.assert-string-eq
        (& actual)
        (& expected)
        "string equality should pass"))))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value assert-true)
  (value assert-false)
  (value assert-bool-eq)
  (value assert-i64-eq)
  (value assert-i32-eq)
  (value assert-f64-eq)
  (value assert-char-eq)
  (value assert-string-eq))