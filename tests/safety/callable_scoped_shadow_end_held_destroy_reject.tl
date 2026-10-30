;; Refs #9098: ending an incoming owner inside a `with-arena` of its brand's
;; spelling while a `with` cleanup owner holds values from it is rejected with
;; the same diagnostic as on main.
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
        (arena.destroy-safe! owner)
        42))))

(define (main) : i64
  0)