;; switch formation: the store through &v sits in an arm before the switch, so
;; the chain after the merge is still free to become a switch.
;; Expected exit 20 at --opt-level 0, 1 and 2.
(import stdlib.io)

(define (main) : i64
  (let
    [v : i64 2]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [c : i64 v]
    [_z : i64
      (if (= (io.arg-count) 1)
        (begin
          (unsafe
            (ptr-write! p 3))
          0)
        1)]
    (cond
      [(= c 0) 5]
      [(= c 1) 10]
      [(= c 2) 20]
      [(= c 3) 30]
      [(= c 4) 50]
      [else 40])))