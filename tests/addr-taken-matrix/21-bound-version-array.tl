;; bounds-check versioning: the bound of a checked array walk is address-taken.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(import stdlib.io)

(define (main) : i64
  (let
    [items : (Array i64 16) (array 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)]
    [n : i64 (+ 9 (io.arg-count))]
    [pn : (MutPtr i64)
      (unsafe
        (ptr-addr-of n))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i n)
      (set! acc (+ acc (array-ref items i)))
      (unsafe
        (ptr-write! pn 4))
      (set! i (+ i 1)))
    (+ acc 32)))