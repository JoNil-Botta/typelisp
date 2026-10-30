;; Refs #9502 Refs #9493. Either arena may supply the value; cleanup precedes both ends.
(import stdlib.arena)
(import stdlib.string)

(define (drop-text [text : String]) : unit
  (let
    [_ : i64 (string.string-length (& text))]
    unit))

(defstruct TextOwner
  (:cleanup cleanup-text-owner)
  (text String (:cleanup drop-text)))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (exercise [flag : bool]) : i64
  (let
    [first (arena.make)]
    [second (arena.make)]
    [expected-text : String
      (if flag
        "first-text"
        "second-text")]
    [result : i64
      (with
        ([held
            (if flag
              (in-arena first (TextOwner (string.append "first" "-text")))
              (in-arena second (TextOwner (string.append "second" "-text"))))
            cleanup-text-owner])
        (if (string.string=? (& held.text) (& expected-text))
          42
          7))]
    (arena.destroy-safe! first)
    (arena.destroy-safe! second)
    result))

(define (main) : i64
  (if (and (= (exercise true) 42) (= (exercise false) 42))
    42
    7))