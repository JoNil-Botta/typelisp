;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that a store through a differently named
;; local, and one in an arena that never collided, are accepted.
(define (distinct-name [p : (& r i64)]) : i64
  (with-arena
    ar
    (let
      [x : (Box i64) (box 30)]
      [saved : (& ar i64) (& ar (deref x))]
      [local : (& ar i64) (& ar (deref x))]
      [alias : (& ar i64) local]
      (set! saved alias)
      (+ (deref saved) (deref p)))))

(define (non-colliding [p : (& outer i64)]) : i64
  (with-arena
    r
    (let
      [x : (Box i64) (box 30)]
      [saved : (& r i64) (& r (deref x))]
      [r : (& r i64) (& r (deref x))]
      [alias : (& r i64) r]
      (set! saved alias)
      (+ (deref saved) (deref p)))))

(define (main) : i64
  0)