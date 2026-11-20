;; #9445: the `with` owner lives in a younger `with-arena` scope but holds a
;; value fed from `o`. A constructor result carries its fields' arena regions,
;; so the owner's type names `o` and the :invalidate call sees it.
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
    [t (in-arena o (string.append "owner" "-text"))]
    (with-arena
      scratch
      (with
        ([w (TextOwner t) cleanup-text-owner])
        (begin
          (release o)
          (if (string.string=? (& w.text) "owner-text")
            42
            7))))))