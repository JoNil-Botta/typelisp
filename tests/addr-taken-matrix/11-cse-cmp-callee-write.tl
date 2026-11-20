;; CSE of a compare on v across a callee that stores through &v.
;; Expected exit 40 at --opt-level 0, 1 and 2.
(define (store30 [p : (MutPtr i64)])
  (unsafe
    (ptr-write! p 30)))

(define (main) : i64
  (let
    [v : i64 11]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [t1 : bool (< v 20)]
    (store30 p)
    (let
      [t2 : bool (< v 20)]
      (if (= t1 t2)
        7
        40))))