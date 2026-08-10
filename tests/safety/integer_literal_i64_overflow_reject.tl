;: A positive decimal literal one past i64::MAX is rejected before lowering.
(define too-large : i64
  9223372036854775808)

(define (main) : i64
  too-large)