;; stdlib/test.tl - Minimal assertion helpers for TypeLisp fixtures.
;;
;; Usage: (import "stdlib/test.tl")
;;
;; Assertions are silent on success. On failure they call `panic` with the
;; caller-supplied message, so existing harnesses observe the normal abort path.

(define (assert-true [value : bool] [message : String]) : unit
  (if value
      unit
      (panic message)))

(define (assert-false [value : bool] [message : String]) : unit
  (if value
      (panic message)
      unit))

(define (assert-bool-eq [actual : bool] [expected : bool] [message : String]) : unit
  (if (= actual expected)
      unit
      (panic message)))

(define (assert-i64-eq [actual : i64] [expected : i64] [message : String]) : unit
  (if (= actual expected)
      unit
      (panic message)))

(define (assert-char-eq [actual : char] [expected : char] [message : String]) : unit
  (if (= (cast actual : i64) (cast expected : i64))
      unit
      (panic message)))

(define (assert-string-eq [actual : String] [expected : String] [message : String]) : unit
  (if (string-eq actual expected)
      unit
      (panic message)))
