;; Field f1000, the first member past the former 1000-member registry stride
;; (#7921), is its own i64 and not field `a` of the struct declared next.
(import wide_aggregates)

(wide_aggregates.wide-struct Wide 1001)

(defstruct Next
  (a bool)
  (b bool)
  (c bool)
  (d bool))

(define (probe [w : Wide]) : i64
  (if w.f1000
    42
    1))

(define (main) : i64
  0)