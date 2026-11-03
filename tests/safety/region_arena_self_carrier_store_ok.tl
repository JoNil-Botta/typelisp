;; A local spelled like a colliding with-arena region whose own annotation
;; carries that name is a self-named carrier: it continues the arena lifetime
;; (#8998 L2), so arena data stored through it stays inside the arena and the
;; store is accepted (#9593).
(define (probe [p : (& r i64)]) : i64
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
  (let
    [seed : i64 12]
    (probe (& seed))))