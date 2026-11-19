;; #9775 W03: an arena value used inside the with is valid.
(import stdlib.string)
(import stdlib.arena)

(define (mk) : String
  (string.int->string 42))

(define (keep) : i64
  (with
    ([a (arena.make) arena.destroy-safe!])
    (let
      [s (in-arena a (mk))]
      (+ 40 (string.string-length (& s))))))

(define (main) : i64
  (keep))