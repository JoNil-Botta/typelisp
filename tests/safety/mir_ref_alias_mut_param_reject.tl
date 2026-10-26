;: One mutable reference cannot be passed for two mutable parameters.
(defstruct Owned
  (items (__tl_dyn-array i64)))

(define (two [_a : (&mut a Owned)] [_b : (&mut b Owned)]) : i64
  1)

(define (run [c : (&mut c Owned)]) : i64
  (two c c))

(define (main) : i64
  0)