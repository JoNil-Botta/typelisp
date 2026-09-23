;; Field f2499 of a 2500-field struct with no declaration after it (#7921)
;; resolves to its own i64 field.
(import wide_aggregates)

(wide_aggregates.wide-struct Wide 2500)

(define (probe [w : Wide]) : i64
  (if w.f2499
    42
    1))

(define (main) : i64
  0)