;: A live mutable borrow excludes a shared borrow of its owner.
(defstruct Owned
  (items (__tl_dyn-array i64)))

(define (peek [_c : (& c Owned)]) : i64
  1)

(define (bump [_c : (&mut c Owned)]) : i64
  1)

(define (run [c : Owned]) : i64
  (let
    [r : (&mut c Owned) (&mut c)]
    [n : i64 (peek (& c))]
    (+ n (bump r))))

(define (main) : i64
  0)