;; CSE of (* v 2) across a callee that stores through &v.
;; Expected exit 81 at --opt-level 0, 1 and 2.
(define (store3 [p : (MutPtr i64)])
  (unsafe
    (ptr-write! p 3)))

(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [t1 : i64 (* v 2)]
    (store3 p)
    (let
      [t2 : i64 (* v 2)]
      (+ (- t1 t2) 5))))