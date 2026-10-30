;; Refs #9098: with-arena shadowing does not hide a held owner. The fresh
;; `with-arena r` is not the incoming owner's arena, but the `with` cleanup
;; owner `w` still holds values from the incoming owner, so ending it through
;; an `:invalidate` call is rejected as it is without the shadow.
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

(define (exercise [owner : (arena.Arena r) (:invalidate r)]) : i64
  (with
    ([w (in-arena owner (TextOwner (string.append "a" "b"))) cleanup-text-owner])
    (with-arena
      r
      (begin
        (release owner)
        42))))

(define (main) : i64
  0)