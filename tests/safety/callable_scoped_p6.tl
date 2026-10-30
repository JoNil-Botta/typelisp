(define (apply-anchored [anchor : (& outer i64)] [f : (-> (& outer i64) i64)]) : i64
  (let
    [x : i64 1]
    (+ (f (& x)) (deref anchor))))

(define (main) : i64
  0)