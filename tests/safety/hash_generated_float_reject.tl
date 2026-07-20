(import stdlib.hash)
(import (hash.hash f64) as float_hash)

(define (main) : i64
  (float_hash.hash 1.0))