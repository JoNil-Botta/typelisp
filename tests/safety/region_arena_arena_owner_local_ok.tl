;; A local arena owner spelled like a colliding with-arena region is not a
;; self-named carrier: L2 keeps an arena owner as its brand's root (#8998), so
;; it shadows the region and the body's `(& r r)` borrows the local owner
;; (#9593, Sol's final review of 3bafc3d02).
(import stdlib.arena)

(define (probe [p : (& r i64)]) : i64
  (with-arena
    r
    (let
      [f
        (lambda ([owner : (arena.Arena r)]) : i64
          (let
            [r : (arena.Arena r) owner]
            (begin
              (& r r)
              42)))]
      (f (arena.make)))))

(define (main) : i64
  (let
    [seed : i64 0]
    (probe (& seed))))