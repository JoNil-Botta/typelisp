;: SPEC safe-code contract: raw pointer dereference is not safe code.
(define (main [p : (Ptr i64)]) : i64
  (ptr-read p))