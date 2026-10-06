;; A body whose only borrows are arguments of calls that keep no borrow past
;; the call skips the borrow check; these calls must stay accepted, including
;; one that borrows the same variable twice.
(import stdlib.string)

(defstruct Pair
  (a i64)
  (b String))

(define (total [p : (& Pair)] [q : (& Pair)]) : i64
  (+ p.a q.a))

(define (bump! [p : (&mut Pair)] [n : i64]) : unit
  (set! p.a (+ p.a n)))

(define (main) : i64
  (let
    [x : Pair (Pair 1 (string.copy "x"))]
    [y : Pair (Pair 2 (string.copy "y"))]
    [acc : i64 0]
    (bump! (&mut x) 10)
    (set! acc (+ acc (total (& x) (& y))))
    (set! acc (+ acc (total (& x) (& x))))
    (set! acc (+ acc (total (& (Pair 3 (string.copy "t"))) (& y))))
    (- acc 20)))