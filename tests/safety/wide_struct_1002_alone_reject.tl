;; Field f1001 of a 1002-field struct with no declaration after it (#7921)
;; resolves to its own i64 field.
(import wide_aggregates)

(wide_aggregates.wide-struct Wide 1002)

(define (probe [w : Wide]) : i64
  (if w.f1001
    42
    1))

(define (main) : i64
  0)