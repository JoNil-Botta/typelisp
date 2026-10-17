;; A store whose receiver selects its place through control flow writes the
;; selected place (SPEC 5.10): `items` is still borrowed by `r`, which is used
;; after the store.
(define (pick [c : bool]) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    [fixed : (Array i64 2) (array 3 4)]
    [r : (& items (Array i64 2)) (& items)]
    (begin
      (set!
        (array-ref
          (if c
            items
            fixed)
          0)
        40)
      (array-ref (deref r) 0))))

(define (main) : i64
  (pick true))