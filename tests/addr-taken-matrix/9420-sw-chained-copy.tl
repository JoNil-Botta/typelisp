;; switch formation: the copy fact is two Movs deep, and the store through &v
;; sits between the copies and the switch.
;; Expected exit 20 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 2]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [c : i64 v]
    [d : i64 c]
    (unsafe
      (ptr-write! p 3))
    (cond
      [(= d 0) 5]
      [(= d 1) 10]
      [(= d 2) 20]
      [(= d 3) 30]
      [(= d 4) 50]
      [else 40])))