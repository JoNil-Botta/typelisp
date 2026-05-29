;;; SPEC safe-code contract: int<->float casts have defined results.
;;; `(cast 39 : f64)` widens exactly to 39.0; the float->int cast truncates
;;; toward zero, so `(cast 3.9 : i64)` is 3. 39 + 3 = 42.
(define (main) : i64
  (let
    [widened : f64 (cast 39 : f64)]
    (+ (cast widened : i64) (cast 3.9 : i64))))