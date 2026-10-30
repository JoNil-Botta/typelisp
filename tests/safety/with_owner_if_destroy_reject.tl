;; Refs #9502 Refs #9493. The contextual if join keeps the live cleanup owner region.
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

(define (main) : i64
  (let
    [o (arena.make)]
    [flag : bool (= (string.string-length "ab") 2)]
    (with
      ([w
          (if flag
            (in-arena o (TextOwner (string.append "owner" "-text")))
            (in-arena o (TextOwner (string.append "b" "-text"))))
          cleanup-text-owner])
      (begin
        (arena.destroy-safe! o)
        (if (string.string=? (& w.text) "owner-text")
          42
          7)))))