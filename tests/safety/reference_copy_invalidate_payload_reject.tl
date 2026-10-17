(import stdlib.arena)

(defstruct Held
  (:lifetimes payload)
  (view (& payload i64))
  (padding (Array i64 4)))

(define (release-and-read
  [value : (Held payload)]
  [owner : (arena.Arena r) (:invalidate r)]) : i64
  (arena.destroy-safe! owner)
  (deref value.view))

(define (main) : i64
  (let
    [owner (arena.make)]
    [cell (in-arena owner (box (cast 42 : i64)))]
    [held (Held (& (deref cell)) (array 1 2 3 4))]
    (release-and-read (deref (& held)) owner)))