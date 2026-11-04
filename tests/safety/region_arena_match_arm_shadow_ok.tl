;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that a match binder named `r` is ordinary
;; in its arm while a sibling arm types arena data with the arena; runs to 42.
(defenum Pick
  (Take i64)
  (Skip))

(define (probe [p : (& r i64)] [v : Pick]) : i64
  (with-arena
    ar
    (match v
      [(Take r) (+ (deref (& r r)) 2)]
      [(Skip)
        (let
          [x : (in ar (Box i64)) (box 2)]
          (deref (& ar (deref x))))])))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s) (Pick.Take 40))))