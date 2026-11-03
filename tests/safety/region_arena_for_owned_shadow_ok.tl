;; A scalar `for` item spelled like a colliding with-arena region shadows the
;; arena inside the loop body: explicit and annotated borrows name the item
;; (#9593).
(define (probe [p : (& r i64)]) : i64
  (with-arena
    r
    (let
      [acc : i64 0]
      [xs : (Array i64 2) (array 20 1)]
      (for [r xs]
        (set! acc (+ acc (deref (& r r))))
        (let
          [y : (& r i64) (& r)]
          (set! acc (+ acc (deref y)))))
      acc)))

(define (main) : i64
  (let
    [seed : i64 1]
    (probe (& seed))))