;; A safe rewind inside the arena it rewinds, while a `with` owner also holds
;; that arena: typing's in-arena self-check reports first, before the end
;; operator's `with`-owner check.
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
    [phase : arena.ArenaPhase (arena.phase scratch)]
    (with
      ([w
          (in-arena scratch (TextOwner (string.append "owner" "-text")))
          cleanup-text-owner])
      (in-arena
        scratch
        (begin
          (arena.rewind-safe! phase)
          42)))))