;;;; Minimal TypeLisp test assertion helpers.
;;;;
;;;; Provides assertion helpers for TypeLisp fixtures using only compiler/runtime
;;;; primitives: `panic`, `string-eq`, and `cast`.
;;;;
;;;; Usage: `(import "stdlib/test.tl")`
;;;;
;;;; ```typelisp
;;;; (import "stdlib/test.tl")
;;;; (define (main) : i64
;;;;   (begin
;;;;     (assert-true true "expected true")
;;;;     42))
;;;; ```

;;; Assert that `condition` is true, panicking with `message` when it is false.
(define (assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (panic message)))

(define (assert-false [condition : bool] [message : String]) : unit
  (assert-true (not condition) message))

(define (assert-bool-eq [actual : bool] [expected : bool] [message : String]) : unit
  (assert-true (= actual expected) message))

(define (assert-i64-eq [actual : i64] [expected : i64] [message : String]) : unit
  (assert-true (= actual expected) message))

(define (assert-i32-eq [actual : i32] [expected : i32] [message : String]) : unit
  (assert-true (= actual expected) message))

(define (assert-f64-eq [actual : f64] [expected : f64] [message : String]) : unit
  (assert-true (= actual expected) message))

(define (assert-char-eq [actual : char] [expected : char] [message : String]) : unit
  (assert-true (= (cast actual : i64) (cast expected : i64)) message))

(define (assert-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-true (string-eq actual expected) message))
