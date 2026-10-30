;; A call ending two arenas: the `with` owner lives in the second one.
(import stdlib.arena)
(import stdlib.string)

(define (drop-text [text : String]) : unit
  (let
    [_ : i64 (string.string-length (& text))]
    unit))

(defstruct TextOwner
  (:cleanup cleanup-text-owner)
  (text String (:cleanup drop-text)))

(define (release-both
  [a : (arena.Arena r) (:invalidate r)]
  [b : (arena.Arena s) (:invalidate s)]) : unit
  (begin
    (arena.destroy-safe! b)
    (arena.destroy-safe! a)))

(define (main) : i64
  (let
    [first (arena.make)]
    [second (arena.make)]
    (with
      ([w
          (in-arena second (TextOwner (string.append "owner" "-text")))
          cleanup-text-owner])
      (begin
        (release-both first second)
        (if (string.string=? (& w.text) "owner-text")
          42
          7)))))