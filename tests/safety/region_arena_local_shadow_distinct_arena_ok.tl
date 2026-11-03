;; Control: a local named `r` borrowed inside a non-colliding arena (#9593).
(define (probe [p : (& r i64)]) : i64
  (with-arena
    q
    (let
      [r : i64 42]
      (deref (& r r)))))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s))))