;; #9490: the with exit that destroys `o` runs the `with`-owner check of a
;; direct destroy while `w`, allocated in it, is live.
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
    (with
      ([w
          (in-arena o (TextOwner (string.append "owner" "-text")))
          cleanup-text-owner])
      (begin
        (with ([a o arena.destroy-safe!]) unit)
        (if (string.string=? (& w.text) "owner-text")
          42
          7)))))