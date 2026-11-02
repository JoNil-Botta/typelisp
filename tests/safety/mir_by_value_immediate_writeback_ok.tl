;; Immediate calls write back scalar and small-aggregate temporaries (#8897).
(defstruct Counter
  (left i64)
  (right i64))

(define (write! [place : (&mut place i64)] [value : i64]) : unit
  (set! (deref place) value))

(define (bump! [counter : (&mut counter Counter)]) : unit
  (set! counter.left (+ counter.left 1)))

(define (main) : i64
  (let
    [value : i64 0]
    [counter : Counter (Counter 39 2)]
    (write! (&mut value) 42)
    (bump! (&mut counter))
    (if (and (= value 42) (= counter.left 40) (= counter.right 2))
      42
      1)))