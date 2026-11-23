;; #9288: borrowing an arena-tagged `Box` binder itself outside `in-arena`
;; still borrows its local stack slot, not its arena contents, so escaping
;; must fail E0205.
(import stdlib.arena)

(define (mk [a : (arena.Arena r)]) : (& r (Box i64))
  (let
    [b (in-arena a (box (ann 42 : i64)))]
    (& b)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [r (mk owner)]
    (deref (deref r))))