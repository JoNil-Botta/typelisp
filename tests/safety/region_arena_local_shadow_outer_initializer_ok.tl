;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that a local's initializer may type arena
;; data with the arena, and later uses of `r` name the local; runs to 42.
(define (probe [p : (& r i64)]) : i64
  (with-arena
    ar
    (let
      [r : i64
        (let
          [t : (in ar (Box i64)) (box 40)]
          (deref t))]
      [y : (& r i64) (& r r)]
      (+ (deref y) 2))))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s))))