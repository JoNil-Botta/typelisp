;; #7962: an arena-branded `(in r String)` keeps a 16-byte stack descriptor
;; until #8090 makes `(& r str)` a 16B value, so borrowing it inside an inner
;; scope and escaping that scope as `(& outer str)` must fail E0205.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [outer (arena.make)]
    [r : (& outer str)
      (with-arena
        inner
        (let
          [s (in-arena outer (string.copy "world"))]
          (& s)))]
    (string.string-length r)))