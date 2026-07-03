(import stdlib.array)
(import stdlib.arena)
(import "stdlib/string.tl")

(extern (tl_arena_poison_enable) : unit)

(define (main) : i64
  (begin
    (tl_arena_poison_enable)
    (let
      [seed : String (append "seed" "arena")]
      [base : i64 (string-length seed)]
      [mark : arena.ArenaMark (arena.mark)]
      ;; lint-allow: single-element-array-cell
      [items : (Array i64) (array.make-array i64 1)]
      (begin
        (array-set! items 0 (+ base 33))
        (unsafe
          (arena.rewind mark))
        (array-ref items 0)))))