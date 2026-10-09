;; #8776: with-escape rewinds its arena, so a body allocation does not take the
;; arena owner's region and cannot be stored into an owner-region binding.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [kept : String (in-arena owner (string.append "a" "b"))]
    (with-escape owner (set! kept (string.int->string 1234567)) 0)
    (with-escape owner (string.string-length (string.int->string 7777777)))
    (if (string.eq (& kept) "1234567")
      100
      7)))