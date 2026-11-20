;; switch formation: the address-taken local is a parameter, copied before a
;; callee stores through its address, then the switch reads the copy.
;; Expected exit 20 at --opt-level 0, 1 and 2.
(define (store3 [p : (MutPtr i64)])
  (unsafe
    (ptr-write! p 3)))

(define (pick [v : i64]) : i64
  (let
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [c : i64 v]
    (store3 p)
    (cond
      [(= c 0) 5]
      [(= c 1) 10]
      [(= c 2) 20]
      [(= c 3) 30]
      [(= c 4) 50]
      [else 40])))

(define (main) : i64
  (pick 2))