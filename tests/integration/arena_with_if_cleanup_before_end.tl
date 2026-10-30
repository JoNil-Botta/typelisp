;; Refs #9502 Refs #9493. Cleanup precedes the end on both branches.
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
    [o (arena.make)]
    [expected-text : String
      (if flag
        "owner-text"
        "b-text")]
    [result : i64
      (with
        ([held
            (if flag
              (in-arena o (TextOwner (string.append "owner" "-text")))
              (in-arena o (TextOwner (string.append "b" "-text"))))
            cleanup-text-owner])
        (if (string.string=? (& held.text) (& expected-text))
          42
          7))]
    (arena.destroy-safe! o)
    result))

(define (main) : i64
  (if (and (= (exercise true) 42) (= (exercise false) 42))
    42
    7))