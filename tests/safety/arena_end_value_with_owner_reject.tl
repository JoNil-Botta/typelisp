;; #9490: the function-value alias would also skip the `with`-owner check.
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
      (let
        [f arena.destroy-safe!]
        (begin
          (f o)
          (if (string.string=? (& w.text) "owner-text")
            42
            7))))))