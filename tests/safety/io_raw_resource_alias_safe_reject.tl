;; Import aliases preserve the unsafe effect on integer-only host resources.
(import stdlib.io as streams)

(define (main) : i64
  (streams.platform-close -1))