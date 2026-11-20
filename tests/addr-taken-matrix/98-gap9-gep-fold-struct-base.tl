;; gep displacement from a pointer into a struct's array field.
;; Expected exit 39 at --opt-level 0, 1 and 2.
(defstruct Row
  (items (Array i64 8)))

(define (main) : i64
  (let
    [r : Row (Row (array 1 2 3 4 5 6 7 8))]
    [j : i64 1]
    [pj : (MutPtr i64)
      (unsafe
        (ptr-addr-of j))]
    [base : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref r.items 0)))]
    [k : i64 (+ j 1)]
    (unsafe
      (ptr-write! pj 4))
    (+
      36
      (unsafe
        (ptr-read (ptr-offset base k))))))