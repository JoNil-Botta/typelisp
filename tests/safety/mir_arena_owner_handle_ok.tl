;; An owner read as its handle (an `in-arena` target, a bare `Arena`
;; argument) is borrowed, not moved: the destroy still consumes it.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner (arena.make)]
    [first (in-arena owner (string.append "ab" "c"))]
    [handle : i64 (arena.raw-handle owner)]
    [second (in-arena owner (string.append "d" "ef"))]
    [total : i64 (+ (string.string-length first) (string.string-length second))]
    (begin
      (arena.destroy-safe! owner)
      (+ total (- 36 (* 0 handle))))))