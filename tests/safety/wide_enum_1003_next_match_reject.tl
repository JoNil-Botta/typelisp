;; A match arm on a variant past the former 1000-member registry stride
;; (#7921) binds that variant's own i64 payload, not the bool payload of the
;; enum declared next.
(import wide_aggregates)

(wide_aggregates.wide-enum Big 1003)

(defenum Small
  (A bool)
  (B bool))

(define (probe [value : Big]) : i64
  (match value
    [(Big.V1001 flag)
      (if flag
        42
        1)]
    [_ 0]))

(define (main) : i64
  0)