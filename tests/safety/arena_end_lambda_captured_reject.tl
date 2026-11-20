;; #9482: a closure cannot end an arena it captures; its callers would still
;; hold the arena's values. It takes the arena as an `(:invalidate r)`
;; parameter instead.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [o (arena.make-atomic)]
    [t (in-arena o (string.append "owner" "-text"))]
    (let
      [f
        (lambda () : i64
          (arena.destroy-safe! o)
          0)]
      (begin
        (f)
        (if (string.string=? (& t) "owner-text")
          42
          7)))))