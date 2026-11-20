;; #9479: a match binder bound from a phase allocation carries the phase's
;; region, so the rewind ends the binder.
(import stdlib.arena)
(import stdlib.string)

(defenum Holder
  (Some String)
  (None))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    (match (in-arena owner (Holder.Some (string.append "a" "b")))
      [(Holder.Some text)
        (begin
          (arena.rewind-safe! p)
          (if (string.eq (& text) "ab")
            42
            7))]
      [Holder.None 0])))