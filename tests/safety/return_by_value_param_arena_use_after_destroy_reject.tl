;: Returning a borrow of a by-value parameter let a reference into an arena
;: outlive the arena: `in-arena` placed the parameter's storage in `owner`,
;: and the reference was read after `destroy-safe!` (main read freed memory).
(import stdlib.arena)
(import stdlib.string)

(define (bad [n : i64]) : (& n i64)
  (& n))

(define (read-later [r : (& a i64)] [junk : i64]) : i64
  (+ (deref r) (- junk junk)))

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (read-later
      (in-arena owner (bad 42))
      (begin
        (arena.destroy-safe! owner)
        (string.string-length (string.int->string 99999999))))))