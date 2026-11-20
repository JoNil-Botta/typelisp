;; #9493: a `with` owner initialized by an `if` keeps the arena region of its
;; arms, so destroying the arena while the owner lives is rejected.
(import stdlib.arena)
(import stdlib.string)

(define (drop-text [text : String]) : unit
  (let
    [_ : i64 (string.string-length (& text))]
    unit))

(defstruct TextOwner
  (:cleanup cleanup-text-owner)
  (text String (:cleanup drop-text)))

(define (main) : i64
  (let
    [o (arena.make)]
    [flag : bool (= (string.string-length "ab") 2)]
    (with
      ([w
          (if flag
            (in-arena o (TextOwner (string.append "owner" "-text")))
            (in-arena o (TextOwner (string.append "p" "-text"))))
          cleanup-text-owner])
      (begin
        (arena.destroy-safe! o)
        (if (string.string=? (& w.text) "owner-text")
          42
          7)))))