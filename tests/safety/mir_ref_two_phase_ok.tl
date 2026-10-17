;: Two-phase call borrows: a mutable argument is reserved at its position and
;: activated at the call, so later arguments may read the place or reborrow
;: the same mutable reference for a nested call. NLL ends shared borrows at
;: their last use.
(defstruct Owned
  (items (__tl_dyn-array i64)))

(define (peek [_c : (& c Owned)]) : i64
  1)

(define (bump [_c : (&mut c Owned)]) : i64
  2)

(define (push [_c : (&mut c Owned)] [n : i64]) : i64
  n)

(define (take [_c : Owned]) : i64
  1)

(define (forward [c : (&mut c Owned)]) : i64
  (+ (bump c) (bump c) (push c (push c 1)) (peek c)))

(define (run [c : Owned] [d : Owned]) : i64
  (let
    [r : (& c Owned) (& c)]
    [n : i64 (+ (peek r) (peek r) (peek (& c)))]
    [m : i64 (+ (bump (&mut c)) (push (&mut d) (peek (& d))))]
    [k : i64 (forward (&mut d))]
    (+ n m k (take c) (take d))))

(define (main) : i64
  (+ 28 (run (Owned (__tl_make-array i64 0)) (Owned (__tl_make-array i64 0)))))