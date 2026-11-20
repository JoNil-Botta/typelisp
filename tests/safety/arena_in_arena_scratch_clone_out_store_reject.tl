;: A with-scratch clone-out inside `in-arena owner` lands in the owner's
;: region, so it cannot be stored into a local that outlives the owner: the
;: program destroys the owner and reads reclaimed storage.
(import stdlib.arena)
(import stdlib.string)

(define (bad [seed : String]) : String
  (let
    [owner (arena.make)]
    [s : String ""]
    (begin
      (in-arena owner (set! s (with-scratch seed)))
      (unsafe
        (arena.destroy owner))
      s)))

(define (main) : i64
  (let
    [text (bad "ab")]
    (if (string.eq (& text) "ab")
      42
      7)))