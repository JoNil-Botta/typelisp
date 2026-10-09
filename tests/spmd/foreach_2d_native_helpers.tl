;; The imported helper of tests/spmd/foreach_2d_native.tl (#7191): a rank-2
;; body passes it the row coordinate `y` as an ordinary uniform argument.
(define (tint [y : i64] [v : i64]) : i64
  (- (* v 5) y))