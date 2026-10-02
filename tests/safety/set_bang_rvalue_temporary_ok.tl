;: Generated set bang mutators follow the ordinary rule: a temporary receiver is
;: a borrowed call-argument temporary (SPEC section 3.10).
(import stdlib.set)
(import (set.set i64) as i64set)

(define (main) : unit
  (i64set.insert! (i64set.new) 1))