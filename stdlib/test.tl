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
(import stdlib.io)
(import stdlib.string)
(import stdlib.text_buf)

;: Assert that `condition` is true, panicking with `message` when it is false.
(define (assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (io.panic message)))

;: Assert that `condition` is false, panicking with `message` when it is true.
(define (assert-false [condition : bool] [message : String]) : unit
  (assert-true (not condition) message))

;: Panic with a consistently rendered equality failure.
(define (assert-eq-failure
  [actual : String]
  [expected : String]
  [message : String]) : never
  (io.panic (string.concat5 message ": expected " expected ", found " actual)))

;: Assert that two bool values are equal.
;:
;: Successful assertions do not allocate. Failures call `panic` with the
;: caller-provided message plus the expected and actual values.
(define (assert-bool-eq [actual : bool] [expected : bool] [message : String]) : unit
  (if (= actual expected)
    unit
    (assert-eq-failure
      (if actual
        "true"
        "false")
      (if expected
        "true"
        "false")
      message)))

;: Assert that two i64 values are equal.
(define (assert-i64-eq [actual : i64] [expected : i64] [message : String]) : unit
  (if (= actual expected)
    unit
    (assert-eq-failure
      (string.int->string actual)
      (string.int->string expected)
      message)))

;: Assert that two i32 values are equal.
(define (assert-i32-eq [actual : i32] [expected : i32] [message : String]) : unit
  (if (= actual expected)
    unit
    (assert-eq-failure
      (string.int->string (cast actual : i64))
      (string.int->string (cast expected : i64))
      message)))

;: Assert that two f64 values are equal.
(define (assert-f64-eq [actual : f64] [expected : f64] [message : String]) : unit
  (if (= actual expected)
    unit
    (assert-eq-failure
      (io.format-float-core actual)
      (io.format-float-core expected)
      message)))

;: Assert that two char values have the same scalar code.
(define (assert-char-eq [actual : char] [expected : char] [message : String]) : unit
  (if (= (cast actual : i64) (cast expected : i64))
    unit
    (assert-eq-failure
      (string.concat3 "'" (text_buf.char-string actual) "'")
      (string.concat3 "'" (text_buf.char-string expected) "'")
      message)))

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
  (if (string.eq actual expected)
    unit
    (assert-eq-failure
      (string.concat3 "\"" (string.copy actual) "\"")
      (string.concat3 "\"" (string.copy expected) "\"")
      message)))

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