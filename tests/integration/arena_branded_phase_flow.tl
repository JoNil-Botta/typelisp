(import stdlib.arena)
(import stdlib.string)
(import stdlib.test)

(define (rewind-both [choose : bool]) : i64
  (let
    [owner (arena.make)]
    [phase (arena.phase owner)]
    [text (in-arena phase (string.append "either" "-arm"))]
    [length : i64 (string.string-length text)]
    (if choose
      (arena.rewind-safe! phase)
      (arena.rewind-safe! phase))
    (let
      [post (in-arena owner (string.append "base" "-after-join"))]
      [answer : i64 (+ length (string.string-length post))]
      (arena.destroy-safe! owner)
      answer)))

(define (rewind-loop) : i64
  (let
    [owner (arena.make)]
    [index : i64 0]
    [total : i64 0]
    (while (< index 4)
      (let
        [phase (arena.phase owner)]
        [text (in-arena phase (string.append "loop" "-phase"))]
        [length : i64 (string.string-length text)]
        (+= total length)
        (arena.rewind-safe! phase)
        (+= index 1)
        (when (= index 2) (continue))))
    (let
      [post (in-arena owner (string.append "base" "-after-loop"))]
      [answer : i64 (+ total (string.string-length post))]
      (arena.destroy-safe! owner)
      answer)))

(define (destroy-loop) : i64
  (let
    [index : i64 0]
    (while (< index 3)
      (let
        [owner (arena.make)]
        [_phase (arena.phase owner)]
        (arena.destroy-safe! owner)
        (+= index 1)))
    index))

(define (rewind-shadowed) : i64
  (let
    [owner (arena.make)]
    [phase (arena.phase owner)]
    [text (in-arena phase (string.append "outer" "-text"))]
    [inner-length : i64
      (let
        [owner (arena.make)]
        [phase (arena.phase owner)]
        [text (in-arena phase (string.append "inner" "-text"))]
        [length : i64 (string.string-length text)]
        (arena.rewind-safe! phase)
        (arena.destroy-safe! owner)
        length)]
    [outer-length : i64 (string.string-length text)]
    (arena.rewind-safe! phase)
    (let
      [post (in-arena owner (string.append "base" "-after-shadow"))]
      [answer : i64
        (+ inner-length (+ outer-length (string.string-length post)))]
      (arena.destroy-safe! owner)
      answer)))

(define (main) : i64
  (test.assert-true (= (rewind-both true) 25) "both arms clear the live phase")
  (test.assert-true (= (rewind-both false) 25) "either rewind branch works")
  (test.assert-true
    (= (rewind-loop) 55)
    "phase is closed on fallthrough and continue")
  (test.assert-true
    (= (destroy-loop) 3)
    "destroy ends the active phase at a backedge")
  (test.assert-true
    (= (rewind-shadowed) 37)
    "same-spelled owners and tokens remain distinct")
  42)