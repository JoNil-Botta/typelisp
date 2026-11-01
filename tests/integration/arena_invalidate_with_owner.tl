;; An `:invalidate` call (#9476) may end an arena once the `with` owners living
;; in it have run their cleanup, and may end another arena while they live.
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
    [other (arena.make)]
    [n : i64
      (with
        ([w
            (in-arena o (TextOwner (string.append "owner" "-text")))
            cleanup-text-owner])
        (begin
          (release other)
          (if (string.string=? (& w.text) "owner-text")
            42
            7)))]
    (begin
      (release o)
      n)))