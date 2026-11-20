;; a switch on v after a store through &v.
;; Expected exit 30 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 2]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    (unsafe
      (ptr-write! p 3))
    (cond [(= v 1) 10] [(= v 2) 20] [(= v 3) 30] [else 40])))