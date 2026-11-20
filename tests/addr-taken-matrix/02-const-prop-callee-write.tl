;; constant propagation: the store to v happens in a callee handed &v.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (store5 [p : (MutPtr i64)])
  (unsafe
    (ptr-write! p 5)))

(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    (store5 p)
    (+ 1 v)))