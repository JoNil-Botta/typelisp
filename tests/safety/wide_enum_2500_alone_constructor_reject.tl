;; Constructor of the last variant of a 2500-variant enum with no declaration
;; after it (#7921) takes its own i64 payload.
(import wide_aggregates)

(wide_aggregates.wide-enum Big 2500)

(define (probe) : Big
  (Big.V2499 true))

(define (main) : i64
  0)