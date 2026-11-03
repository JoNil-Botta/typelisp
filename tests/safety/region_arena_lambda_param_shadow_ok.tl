;; A lambda parameter spelled like a colliding arena shadows it only inside
;; the lambda body (#9593).
(define (probe [p : (& r i64)]) : i64
  (with-arena
    r
    (let
      [x : (in r (Box i64)) (box 40)]
      [f
        (lambda ([r : i64]) : i64
          (deref (& r r)))]
      (+ (f 2) (deref (& r (deref x)))))))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s))))