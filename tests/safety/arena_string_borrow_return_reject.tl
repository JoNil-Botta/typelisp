;; #7962: an arena-branded `(in r String)` keeps a 16-byte stack descriptor
;; until #8090 makes `(& r str)` a 16B value, so returning `(& r str)` borrowed
;; from a local `(in r String)` must fail E0205.
(import stdlib.arena)
(import stdlib.string)

(define (mk-str-outside [a : (arena.Arena r)]) : (& r str)
  (let
    [s (in-arena a (string.copy "world"))]
    (& s)))

(define (main) : i64
  (let
    [outer (arena.make)]
    [r (mk-str-outside outer)]
    (string.string-length r)))