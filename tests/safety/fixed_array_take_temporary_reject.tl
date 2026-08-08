;: The receiver must be durable storage because the operation resets its slot.
(define (main) : i64
  (array-take! (array 7) 0))