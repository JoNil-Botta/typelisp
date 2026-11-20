;; the loop bound is lowered by a callee that receives &bound.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (storeit [p : (MutPtr i64)] [x : i64])
  (unsafe
    (ptr-write! p x)))

(define (main) : i64
  (let
    [n : i64 10]
    [pn : (MutPtr i64)
      (unsafe
        (ptr-addr-of n))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i n)
      (set! acc (+ acc (+ i 1)))
      (storeit pn 4)
      (set! i (+ i 1)))
    (+ acc 32)))