;; #9479: a branded `in-arena` allocates in the owner's live phase, so
;; rewinding a phase taken before the `with` owner was allocated reaches the
;; owner, whose cleanup still runs when its scope ends.
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
    [o (arena.make)]
    [ph (arena.phase o)]
    (with
      ([w
          (in-arena o (TextOwner (string.append "owner" "-text")))
          cleanup-text-owner])
      (begin
        (arena.rewind-safe! ph)
        (if (string.string=? (& w.text) "owner-text")
          42
          7)))))