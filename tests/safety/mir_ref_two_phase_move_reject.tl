;: A reserved mutable argument cannot be moved by a later argument.
(defstruct Owned
  (items (__tl_dyn-array i64)))

(define (push [_c : (&mut c Owned)] [n : i64]) : i64
  n)

(define (take [_c : Owned]) : i64
  1)

(define (run [d : Owned]) : i64
  (push (&mut d) (take d)))

(define (main) : i64
  0)