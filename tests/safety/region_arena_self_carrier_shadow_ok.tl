;; Self-named carriers of a colliding with-arena region (#9593, #8998 L2): a
;; let carrier and a lambda parameter carrier both continue the arena, so
;; later annotations spelled `r` still name the arena. Runs to 42.
(define (probe [p : (& r i64)]) : i64
  (with-arena
    r
    (let
      [x : (Box i64) (box 25)]
      [saved : (& r i64) (& r (deref x))]
      [r : (& r i64) (& r (deref x))]
      [alias : (& r i64) r]
      [read
        (lambda ([r : (& r i64)]) : i64
          (deref r))]
      (set! saved alias)
      (+ (read saved) (+ (deref alias) (- (deref p) 20))))))

(define (main) : i64
  (let
    [seed : i64 12]
    (probe (& seed))))