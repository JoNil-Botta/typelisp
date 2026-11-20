;; #9041: a macro-expanded destroy discharges an `(:invalidate r)` parameter.
(import stdlib.arena)

(defmacro (kill [a : Expr]) : Expr
  `(arena.destroy-safe! ,a))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (kill owner))

(define (main) : i64
  (let
    [owner (arena.make)]
    (begin
      (release owner)
      42)))