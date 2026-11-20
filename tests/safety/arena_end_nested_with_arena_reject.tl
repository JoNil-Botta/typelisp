;; #9502: a `with-arena` inside `(in-arena owner ...)` is carved from the
;; owner's arena, so the owner cannot end inside it.
(import stdlib.arena)
(import stdlib.string)

(define (exercise [owner : (arena.Arena r) (:invalidate r)]) : i64
  (in-arena
    owner
    (with-arena
      s
      (let
        [t : String (string.append "abc" "def")]
        (begin
          (arena.destroy-safe! owner)
          42)))))

(define (main) : i64
  (let
    [owner (arena.make)]
    (exercise owner)))