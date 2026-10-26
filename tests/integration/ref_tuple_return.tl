;: A tuple holding a reference derived from a reference parameter carries the
;: caller's lifetime back.
(define (make-ref-tuple [n : (& n i64)]) : (Tuple (& n i64) i64)
  (tuple n 7))

(define (use [n : i64]) : i64
  (let
    [pair : (Tuple (& n i64) i64) (make-ref-tuple (& n))]
    (+ (deref (tuple-ref pair 0)) (- (tuple-ref pair 1) 6))))

(define (main) : i64
  (use 41))