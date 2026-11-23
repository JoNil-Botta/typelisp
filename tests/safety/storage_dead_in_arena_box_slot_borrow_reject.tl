;; #9288: borrowing an arena-tagged `Box` variable itself (without `deref`)
;; borrows its local stack slot, not its arena contents, so escaping fails E0205.
(import stdlib.arena)

(define (mk [a : (arena.Arena r)]) : (& r (Box i64))
  (in-arena
    a
    (let
      [cell (box (ann 42 : i64))]
      (& cell))))

(define (main) : i64
  (let
    [owner (arena.make)]
    [r (mk owner)]
    (deref (deref r))))