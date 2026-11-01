;; The right-hand side may read the selected array: its place is borrowed
;; only at the store.
(define (pick [c : bool]) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    [fixed : (Array i64 2) (array 3 4)]
    (begin
      (set!
        (array-ref
          (if c
            items
            fixed)
          0)
        (+ (array-ref items 1) 40))
      (array-ref items 0))))

(define (main) : i64
  (pick true))