(import stdlib.arena)
(import stdlib.string)

(defstruct InvalidateHeldText
  (:lifetimes owner)
  (text (in owner String)))

(define (release-both
  [f
    : (->
      (:invalidate q (arena.Arena q))
      (:invalidate p (InvalidateHeldText p))
      unit)]
  [owner : (arena.Arena s) (:invalidate s)]
  [held : (InvalidateHeldText s)]) : unit
  (f owner held))

(define (main) : i64
  42)