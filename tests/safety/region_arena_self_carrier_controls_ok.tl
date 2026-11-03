;; Controls for the self-named carrier fixtures (#9593): the same store with
;; a carrier named unlike the arena, and with an arena that does not collide
;; with the caller lifetime, are accepted.
(define (distinct-name [p : (& r i64)]) : i64
  (with-arena
    r
    (let
      [x : (Box i64) (box 30)]
      [saved : (& r i64) (& r (deref x))]
      [local : (& r i64) (& r (deref x))]
      [alias : (& r i64) local]
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