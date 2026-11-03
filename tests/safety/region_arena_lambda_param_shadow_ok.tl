;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that a lambda parameter named `r` inside
;; an arena is an ordinary binder; runs to 42.
(define (probe [p : (& r i64)]) : i64
  (with-arena
    ar
    (let
      [x : (in ar (Box i64)) (box 40)]
      [f
        (lambda ([r : i64]) : i64
          (deref (& r r)))]
      (+ (f 2) (deref (& ar (deref x)))))))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s))))