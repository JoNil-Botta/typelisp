;: A positive based literal with the i64 sign bit set is not accepted as i64.
(define too-large : i64
  0x8000000000000000)

(define (main) : i64
  too-large)