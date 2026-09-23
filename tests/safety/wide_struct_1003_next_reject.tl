;; Field f1001 of a 1003-field struct (#7921) is its own i64, not field `b` of
;; the struct declared next.
(import wide_aggregates)

(wide_aggregates.wide-struct Wide 1003)

(defstruct Next
  (a bool)
  (b bool)
  (c bool)
  (d bool))

(define (probe [w : Wide]) : i64
  (if w.f1001
    42
    1))

(define (main) : i64
  0)