;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that arena data stored through a self-
;; named carrier into an arena-local is accepted.
(define (probe [p : (& r i64)]) : i64
  (with-arena
    ar
    (let
      [x : (Box i64) (box 30)]
      [saved : (& ar i64) (& ar (deref x))]
      [r : (& ar i64) (& ar (deref x))]
      [alias : (& ar i64) r]
      (set! saved alias)
      (+ (deref saved) (deref p)))))

(define (main) : i64
  (let
    [seed : i64 12]
    (probe (& seed))))