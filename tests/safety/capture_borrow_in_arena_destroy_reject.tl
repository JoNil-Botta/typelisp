;; A capture borrow returned out of `in-arena`, read after `arena.destroy-safe!`
;; (#9297).
(import stdlib.arena)

(define (main) : i64
  (let
    [x : i64 42]
    [owner (arena.make)]
    ; Must fail: `(& x)` borrows the lambda's copy of `x`.
    [r : (& x i64)
      (in-arena
        owner
        ((lambda () : (& x i64)
            (& x))))]
    (arena.destroy-safe! owner)
    (deref r)))