;; #8681: the same store under `in-arena` of an owner the caller destroys.
(import stdlib.arena)
(import stdlib.string)

(define g : String
  "")

(define (stash) : unit
  (set! g (string.append "a" "b")))

(define (main) : i64
  (let
    [o (arena.make)]
    (begin
      (in-arena o (stash))
      (arena.destroy-safe! o)
      (string.string-length g))))