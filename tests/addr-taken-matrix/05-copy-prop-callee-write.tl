;; copy propagation across a callee that stores through &v.
;; Expected exit 37 at --opt-level 0, 1 and 2.
(define (store5 [p : (MutPtr i64)])
  (unsafe
    (ptr-write! p 5)))

(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [c : i64 v]
    (store5 p)
    (+ 1 (- c v))))