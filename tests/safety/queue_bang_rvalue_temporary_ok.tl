;: Generated deque bang mutators follow the ordinary rule: a temporary receiver
;: is a borrowed call-argument temporary (SPEC section 3.10).
(import stdlib.queue)
(import (queue.deque i64) as deque_i64)

(define (main) : unit
  (deque_i64.push-back! (deque_i64.new) 1))