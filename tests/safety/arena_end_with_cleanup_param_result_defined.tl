;; #9775 W04: a result not allocated in the with-bound arena is valid.
(import stdlib.string)
(import stdlib.arena)

(define (mk) : String
  (string.int->string 42))

(define (keep [o : String]) : String
  (with
    ([a (arena.make) arena.destroy-safe!])
    (begin
      (in-arena a (mk))
      o)))

(define (main) : i64
  (let
    [k (keep (mk))]
    (+ 40 (string.string-length (& k)))))