;; See float_neg_mixed_f64_first: the same program with the widths collected in
;; the opposite order, which leaves the other sign-bit constant missing (#9690).
(define (negate-f32 [x : f32] [depth : i64]) : f32
  (if (> depth 0)
    (negate-f32 x (- depth 1))
    (neg x)))

(define (negate-f64 [x : f64] [depth : i64]) : f64
  (if (> depth 0)
    (negate-f64 x (- depth 1))
    (neg x)))

(define (main) : i64
  (if (and
    (= (negate-f64 -1.5 1) 1.5)
    (= (negate-f32 (cast -2.5 : f32) 1) (cast 2.5 : f32)))
    42
    7))