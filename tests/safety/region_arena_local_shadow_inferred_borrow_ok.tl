;; Control: the shadowing local with an inferred borrow lifetime (#9593).
(define (probe [p : (& r i64)]) : i64
  (with-arena
    r
    (let
      [r : i64 42]
      (deref (& r)))))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s))))