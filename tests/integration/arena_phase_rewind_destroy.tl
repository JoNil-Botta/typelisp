(import "stdlib/arena.tl")
(import "stdlib/string.tl")
(import "stdlib/test.tl")

(define (main) : i64
  (let
    [owner : Arena (arena-make)]
    [pre : String (in-arena owner (string-append "pre" "-kept"))]
    [phase : ArenaPhase (arena-phase owner)]
    [temp : String (in-arena owner (string-append "temp" "-discard"))]
    [temp-len : i64 (string-length temp)]
    (begin
      (arena-rewind-safe! phase)
      (let
        [post : String (in-arena owner (string-append "post" "-kept"))]
        [expected-pre : String "pre-kept"]
        [expected-post : String "post-kept"]
        (begin
          (assert-true (= temp-len 12) "phase temp was usable before rewind")
          (assert-string-eq (& pre) (& expected-pre) "pre-phase value survives")
          (assert-string-eq
            (& post)
            (& expected-post)
            "post-rewind value works")
          (arena-destroy-safe! owner)
          42)))))