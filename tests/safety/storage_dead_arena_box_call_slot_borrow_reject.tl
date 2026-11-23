;; #9288: borrowing an arena-tagged `Box` binder returned from a helper
;; borrows its local stack slot, not its arena contents, so escaping must
;; fail E0205.
(import stdlib.arena)

(define (mk-box [a : (arena.Arena r)]) : (in r (Box i64))
  (in-arena a (box (ann 42 : i64))))

(define (mk [a : (arena.Arena r)]) : (& r (Box i64))
  (let
    [cell (mk-box a)]
    (& cell)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [r (mk owner)]
    (deref (deref r))))