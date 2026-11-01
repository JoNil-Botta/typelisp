;: A mutable borrow of a by-value (register-resident) local is a temporary
;: written back after the call: the call's result cannot keep it (SPEC
;: borrow expressions), or writes through it would be lost.
(defstruct Counter
  (len i64)
  (cap i64))

(define (id-mut [c : (&mut a Counter)]) : (&mut a Counter)
  c)

(define (bump! [c : (&mut c Counter)]) : unit
  (set! c.len (+ c.len 1)))

(define (main) : i64
  (let
    [x : Counter (Counter 40 2)]
    [r : (&mut x Counter) (id-mut (&mut x))]
    (begin
      (bump! r)
      (bump! r)
      x.len)))