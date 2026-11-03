;; An explicitly annotated scalar `for` item spelled like a colliding
;; with-arena region whose annotation carries that name is a self-named
;; carrier: it continues the arena, so storing it into an arena-local is
;; accepted (#9593, Sol's final review of 3bafc3d02). An inferred item cannot
;; be classified and still shadows.
(define (probe [p : (& r i64)]) : i64
  (with-arena
    r
    (let
      [x : (Box i64) (box 42)]
      [saved : (& r i64) (& r (deref x))]
      [items : (Array (& r i64) 1) (array saved)]
      (for [r : (& r i64) items]
        (let
          [alias : (& r i64) r]
          (set! saved alias)))
      (deref saved))))

(define (main) : i64
  (let
    [seed : i64 0]
    (probe (& seed))))