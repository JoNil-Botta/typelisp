;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that a typed scalar `for` carrier of
;; arena data stored into an arena-local is accepted; runs to 42.
(define (probe [p : (& r i64)]) : i64
  (with-arena
    ar
    (let
      [x : (Box i64) (box 42)]
      [saved : (& ar i64) (& ar (deref x))]
      [items : (Array (& ar i64) 1) (array saved)]
      (for [r : (& ar i64) items]
        (let
          [alias : (& ar i64) r]
          (set! saved alias)))
      (deref saved))))

(define (main) : i64
  (let
    [seed : i64 0]
    (probe (& seed))))