;; The body never mentions the owner after the destroy, but its cleanup, which
;; drops the arena-backed String itself, still runs when the `with` scope ends.
(import stdlib.arena)
(import stdlib.string)

(define (drop-text [text : String]) : unit
  (let
    [_ : i64 (string.string-length (& text))]
    unit))

(defstruct TextOwner
  (:cleanup cleanup-text-owner)
  (text String (:cleanup drop-text)))

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    (with
      ([owner
          (in-arena scratch (TextOwner (string.concat "ab" "cd")))
          cleanup-text-owner])
      (begin
        (arena.destroy-safe! scratch)
        42))))