;; CSE of (* v 7) across a direct set! of v.
;; Expected exit 15 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 3]
    [_p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64 (* v 7)]
    (set! v 5)
    (let
      [b : i64 (* v 7)]
      (+ 1 (- b a)))))