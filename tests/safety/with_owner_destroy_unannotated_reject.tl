;; A safe destroy of an unannotated `(arena.make)` owner while a `with` owner
;; lives in it; the diagnostic names the owner `o`, not its generated brand.
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
    (with
      ([w
          (in-arena o (TextOwner (string.append "owner" "-text")))
          cleanup-text-owner])
      (begin
        (arena.destroy-safe! o)
        (if (string.string=? (& w.text) "owner-text")
          42
          7)))))