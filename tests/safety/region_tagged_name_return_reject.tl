;; A plain scalar name returned as `(in p i64)` fails as the same position
;; with an expression does: E0205, not an unsupported form (#9737).
(define (bad [p : (& p i64)] [x : i64]) : (in p i64)
  ; Must fail: as `(+ x 1)` here does.
  x)

(define (main) : i64
  (let
    [z : i64 3]
    (bad (& z) 2)))