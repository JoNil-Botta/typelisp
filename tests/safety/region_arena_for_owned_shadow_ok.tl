;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that a scalar `for` item named `r` inside
;; an arena is an ordinary binder whose explicit and annotated borrows name it;
;; runs to 42.
(define (probe [p : (& r i64)]) : i64
  (with-arena
    ar
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