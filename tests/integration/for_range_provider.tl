;; A module function named `range` that returns `stdlib.iterator.I64Range` but
;; is not stdlib's: an inclusive range. `for` must run it rather than assume
;; stdlib's half-open `range`.
(import stdlib.iterator)

(define (range [first : i64] [last : i64]) : iterator.I64Range
  (iterator.range-inclusive first last))