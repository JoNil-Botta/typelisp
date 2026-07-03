(import stdlib.arena)
(import "stdlib/string.tl")
(import "stdlib/test.tl")

(define (build-kept [scratch : arena.Arena]) : String
  (in-arena
    scratch
    (begin
      (assert-true (arena.eq? (arena.current) scratch) "in-arena active target")
      (append "arena:" (int->string 42)))))

(define (main) : i64
  (let
    [home-anchor : String (int->string 7)]
    [home : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    [kept : String (build-kept scratch)]
    [after : arena.Arena (arena.current)]
    [noise : String (append home-anchor (int->string 8))]
    [expected-kept : String "arena:42"]
    [expected-noise : String "78"]
    (begin
      (assert-true (arena.eq? after home) "in-arena restores active arena")
      (assert-string-eq (& kept) (& expected-kept) "in-arena kept result")
      (assert-string-eq
        (& noise)
        (& expected-noise)
        "enclosing arena allocation")
      42)))