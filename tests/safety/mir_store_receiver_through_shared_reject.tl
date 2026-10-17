;; A receiver arm selecting a place behind a shared reference cannot be
;; written.
(define (pick [c : bool] [r : (& r (Array i64 2))]) : i64
  (let
    [fixed : (Array i64 2) (array 3 4)]
    (begin
      (set!
        (array-ref
          (if c
            (deref r)
            fixed)
          0)
        40)
      0)))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    (pick true (& items))))