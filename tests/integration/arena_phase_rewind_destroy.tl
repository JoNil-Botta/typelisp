(import stdlib.arena)
(import stdlib.string)
(import stdlib.test)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [pre : String (in-arena owner (string.append "pre" "-kept"))]
    [phase : arena.ArenaPhase (arena.phase owner)]
    [temp : String (in-arena owner (string.append "temp" "-discard"))]
    [temp-len : i64 (string.string-length temp)]
    (begin
      (arena.rewind-safe! phase)
      (let
        [post : String (in-arena owner (string.append "post" "-kept"))]
        [expected-pre : String "pre-kept"]
        [expected-post : String "post-kept"]
        (begin
          (test.assert-true
            (= temp-len 12)
            "phase temp was usable before rewind")
          (test.assert-string-eq
            (& pre)
            (& expected-pre)
            "pre-phase value survives")
          (test.assert-string-eq
            (& post)
            (& expected-post)
            "post-rewind value works")
          (arena.destroy-safe! owner)
          42)))))