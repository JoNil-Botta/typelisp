;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that a lambda with mixed same-named
;; parameters, in either order, checks inside an arena; runs to 42.
(define (probe [p : (& r i64)]) : i64
  (with-arena
    ar
    (let
      [f
        (lambda ([r : i64] [r : (& r i64)]) : i64
          (begin
            (& r r)
            20))]
      [g
        (lambda ([r : (& r i64)] [r : i64]) : i64
          (begin
            (& r r)
            22))]
      (+ (f 1 p) (g p 1)))))

(define (main) : i64
  (let
    [seed : i64 0]
    (probe (& seed))))