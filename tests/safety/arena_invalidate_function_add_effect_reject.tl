(import stdlib.arena)
(import stdlib.string)

(define (keep [owner : (arena.Arena r)]) : unit
  unit)

(define (apply-release
  [f : (-> (:invalidate q (arena.Arena q)) unit)]
  [owner : (arena.Arena s) (:invalidate s)]) : unit
  (f owner))

(define (main) : i64
  (let
    [owner (arena.make)]
    (begin
      (apply-release keep owner)
      42)))