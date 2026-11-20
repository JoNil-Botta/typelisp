;; a checked array index lowered by a callee.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (storeit [p : (MutPtr i64)] [x : i64])
  (unsafe
    (ptr-write! p x)))

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
      (set! acc (+ acc (array-ref items v)))
      (storeit pv (- v 1))
      (set! i (+ i 1)))
    (+ acc 33)))