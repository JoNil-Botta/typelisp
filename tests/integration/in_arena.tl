(import stdlib.arena)
(import stdlib.string)
(import stdlib.test)

(define (build-kept [scratch : arena.Arena]) : String
  (in-arena
    scratch
    (begin
      (test.assert-true
        (arena.eq? (arena.current) scratch)
        "in-arena active target")
      (string.append "arena:" (string.int->string 42)))))

(define (main) : i64
  (let
    [home-anchor : String (string.int->string 7)]
    [home : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    [kept : String (build-kept scratch)]
    [after : arena.Arena (arena.current)]
    [noise : String (string.append home-anchor (string.int->string 8))]
    [expected-kept : String "arena:42"]
    [expected-noise : String "78"]
    (begin
      (test.assert-true (arena.eq? after home) "in-arena restores active arena")
      (test.assert-string-eq (& kept) (& expected-kept) "in-arena kept result")
      (test.assert-string-eq
        (& noise)
        (& expected-noise)
        "enclosing arena allocation")
      42)))