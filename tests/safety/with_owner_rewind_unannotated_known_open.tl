;; KNOWN OPEN, pre-existing and unsafe: this program is accepted and reads
;; reclaimed storage. Tracked in #9479 / D-C47 S2. A branded `in-arena` allocates
;; in the brand, not in the owner's live phase, so rewinding a phase taken
;; before the `with` owner was allocated does not see the owner. Its row must
;; flip to a rejection when S2 lands.
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