;; stdlib/test.tl - Minimal TypeLisp test assertion helpers.
;;
;; Primitives required from the compiler/runtime:
;;   panic, string-eq, cast
;;
;; Usage: (import "stdlib/test.tl")

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

(define (assert-string-eq [actual : String] [expected : String] [message : String]) : unit
  (assert-true (string-eq actual expected) message))
