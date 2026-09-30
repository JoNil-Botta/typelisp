(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (apply [f : (-> (arena.Arena q) unit)] [owner : (arena.Arena s)]) : unit
  (f owner))

(define (main) : i64
  (let
    [owner (arena.make)]
    (begin
      (apply release owner)
      42)))