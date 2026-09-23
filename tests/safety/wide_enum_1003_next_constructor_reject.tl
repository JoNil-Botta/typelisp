;; Constructor of a variant past the former 1000-member registry stride
;; (#7921): Big.V1001 takes its own i64 payload and builds a Big, not the bool
;; payload of the enum declared next.
(import wide_aggregates)

(wide_aggregates.wide-enum Big 1003)

(defenum Small
  (A bool)
  (B bool))

(define (probe) : Big
  (Big.V1001 true))

(define (main) : i64
  0)