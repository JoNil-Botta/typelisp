;; a local stays live in a register across a call that stores to its slot.
;; Expected exit 78 at --opt-level 0, 1 and 2.
(define (store5 [p : (MutPtr i64)])
  (unsafe
    (ptr-write! p 5)))

(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64 (+ v v)]
    (store5 p)
    (+ 1 (- a v))))