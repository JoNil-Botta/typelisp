;; load-CSE: a callee stores through &v between the two loads.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (store5 [p : (MutPtr i64)])
  (unsafe
    (ptr-write! p 5)))

(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (store5 p)
    (let
      [b : i64
        (unsafe
          (ptr-read p))]
      (+ a b))))