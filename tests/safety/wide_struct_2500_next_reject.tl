;; Field f2002 of a 2500-field struct (#7921) is its own i64, not field `c` of
;; the second struct declared after it.
(import wide_aggregates)

(wide_aggregates.wide-struct Wide 2500)

(defstruct Next
  (a bool)
  (b bool)
  (c bool)
  (d bool))

(defstruct Third
  (a bool)
  (b bool)
  (c bool)
  (d bool))

(define (probe [w : Wide]) : i64
  (if w.f2002
    42
    1))

(define (main) : i64
  0)