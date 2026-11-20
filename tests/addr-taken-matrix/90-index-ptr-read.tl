;; the array index is read through the address-taken index's pointer.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [items : (Array i64 16) (array 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)]
    [v : i64 3]
    [pv : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i 3)
      (set!
        acc
        (+
          acc
          (array-ref
            items
            (unsafe
              (ptr-read pv)))))
      (unsafe
        (ptr-write! pv (- v 1)))
      (set! i (+ i 1)))
    (+ acc 33)))