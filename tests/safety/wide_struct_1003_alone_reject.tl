;; Field f1002 of a 1003-field struct with no declaration after it (#7921)
;; resolves to its own i64 field.
(import wide_aggregates)

(wide_aggregates.wide-struct Wide 1003)

(define (probe [w : Wide]) : i64
  (if w.f1002
    42
    1))

(define (main) : i64
  0)