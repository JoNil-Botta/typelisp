;; a direct read of v, a set!, then a read through &v.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64 v]
    (set! v 5)
    (let
      [b : i64
        (unsafe
          (ptr-read p))]
      (+ a b))))