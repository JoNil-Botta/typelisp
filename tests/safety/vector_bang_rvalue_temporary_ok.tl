;: Generated vector bang mutators follow the ordinary rule: a temporary receiver
;: is a borrowed call-argument temporary (SPEC section 3.10).
(import stdlib.vector)
(import (vector.vector i64) as ivec)

(define (main) : unit
  (ivec.push! (ivec.new) 1))