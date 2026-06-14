(import "stdlib/arena.tl")

(import "stdlib/string.tl")

(import "stdlib/test.tl")

(define (build-kept [scratch : i64]) : String
  (in-arena
    scratch
    (begin
      (assert-i64-eq (arena-current) scratch "in-arena active target")
      (string-append "arena:" (int->string 42)))))

(define (main) : i64
  (let
    [home-anchor : String (int->string 7)]
    [home : i64 (arena-current)]
    [scratch : i64 (arena-make)]
    [kept : String (build-kept scratch)]
    [after : i64 (arena-current)]
    [noise : String (string-append home-anchor (int->string 8))]
    [expected-kept : String "arena:42"]
    [expected-noise : String "78"]
    (begin
      (assert-i64-eq after home "in-arena restores active arena")
      (assert-string-eq (& kept) (& expected-kept) "in-arena kept result")
      (assert-string-eq
        (& noise)
        (& expected-noise)
        "enclosing arena allocation")
      42)))