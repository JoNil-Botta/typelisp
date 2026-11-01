;; A `match` receiver selects `items`, which a live mutable borrow holds.
(define (pick [c : bool]) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    [fixed : (Array i64 2) (array 3 4)]
    [m : (&mut items (Array i64 2)) (&mut items)]
    (begin
      (set!
        (array-ref
          (match c
            [true items]
            [false fixed])
          0)
        40)
      (set! (array-ref (deref m) 1) 7)
      0)))

(define (main) : i64
  (pick true))