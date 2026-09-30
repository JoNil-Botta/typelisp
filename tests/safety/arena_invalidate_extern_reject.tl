(import stdlib.arena)
(import stdlib.string)

(extern (native-release [owner : (arena.Arena r) (:invalidate r)]) : unit)

(define (main) : i64
  42)