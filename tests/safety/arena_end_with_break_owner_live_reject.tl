;; A `break` leaving a with that destroys `o` runs the `with`-owner check of
;; a direct destroy: `w`, allocated in `o`, is cleaned up after it.
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
    (begin
      (while true
        (with
          ([w
              (in-arena o (TextOwner (string.append "owner" "-text")))
              cleanup-text-owner])
          (with ([a o arena.destroy-safe!]) (break))))
      42)))