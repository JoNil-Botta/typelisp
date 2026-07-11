;: Generated deque bang mutators preserve the normal mutable-place diagnostic.
(import stdlib.queue)
(import (queue.deque i64) as deque_i64)

(define (main) : unit
  (deque_i64.push-back! (deque_i64.new) 1))