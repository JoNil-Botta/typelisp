;; #9041: a macro-expanded `arena.rewind-safe!` runs the `with`-owner check of
;; a direct rewind.
(import stdlib.arena)
(import stdlib.string)

(define (drop-text [text : String]) : unit
  (let
    [_ : i64 (string.string-length (& text))]
    unit))

(defstruct TextOwner
  (:cleanup cleanup-text-owner)
  (text String (:cleanup drop-text)))

(defmacro (back [a : Expr]) : Expr
  `(arena.rewind-safe! ,a))

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [phase : arena.ArenaPhase (arena.phase scratch)]
    (with
      ([w
          (in-arena scratch (TextOwner (string.append "owner" "-text")))
          cleanup-text-owner])
      (begin
        (back phase)
        (if (string.string=? (& w.text) "owner-text")
          42
          7)))))