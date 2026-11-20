;; a switch on a copy of v taken before a store through &v.
;; Expected exit 20 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 2]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [c : i64 v]
    (unsafe
      (ptr-write! p 3))
    (cond [(= c 1) 10] [(= c 2) 20] [(= c 3) 30] [else 40])))