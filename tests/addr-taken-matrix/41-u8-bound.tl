;; u8 loop bound lowered through its address.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [n : u8 (cast 10 : u8)]
    [pn : (MutPtr u8)
      (unsafe
        (ptr-addr-of n))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i (cast n : i64))
      (set! acc (+ acc (+ i 1)))
      (unsafe
        (ptr-write! pn (cast 4 : u8)))
      (set! i (+ i 1)))
    (+ acc 32)))