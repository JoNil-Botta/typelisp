;; The old value replace! takes out of an arena box's contents is allocated in
;; that arena: it keeps the arena's brand and is unusable after the arena is
;; destroyed.
(import stdlib.arena)
(import stdlib.string)

(define (probe) : String
  (let
    [owner (arena.make)]
    [b (in-arena owner (box (string.append "x" "y")))]
    [old (replace! (deref b) "z")]
    (arena.destroy-safe! owner)
    old))

(define (main) : i64
  42)