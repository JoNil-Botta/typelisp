;; A `foreach-active` lane spelled like a colliding with-arena region shadows
;; the arena inside its body: explicit and annotated lane borrows name the
;; lane (#9593).
(define (probe [p : (& r i64)]) : i64
  (let
    [acc : (Array i64 1) (array 0)]
    (with-arena
      r
      (foreach
        ([i : i64 0 1])
        (foreach-active
          [r : i64]
          (let
            [x : (& r i64) (& r r)]
            [y : i64 (deref (& r))]
            (set! (array-ref acc 0) (+ 42 (- (deref x) y)))))))
    (array-ref acc 0)))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s))))