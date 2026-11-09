;; One program negating both widths needs both sign-bit constants (#9690). The
;; f64 negation is collected first here and last in float_neg_mixed_f32_first.
;; Recursion keeps each negation out of line, so it survives to the backend.
(define (negate-f64 [x : f64] [depth : i64]) : f64
  (if (> depth 0)
    (negate-f64 x (- depth 1))
    (neg x)))

(define (negate-f32 [x : f32] [depth : i64]) : f32
  (if (> depth 0)
    (negate-f32 x (- depth 1))
    (neg x)))

(define (main) : i64
  (if (and
    (= (negate-f64 -1.5 1) 1.5)
    (= (negate-f32 (cast -2.5 : f32) 1) (cast 2.5 : f32)))
    42
    7))