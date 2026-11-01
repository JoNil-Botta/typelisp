;; A safe destroy inside the arena it destroys, while a `with` owner also
;; holds that arena: typing's in-arena self-check reports first, before the
;; end operator's `with`-owner check.
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
      (in-arena
        o
        (begin
          (arena.destroy-safe! o)
          42)))))