;; #8173: the same helper called with an unannotated, branded owner.
(import stdlib.arena)
(import stdlib.string)

(defstruct Plain
  (text String))

(define (make-plain [a : arena.Arena]) : Plain
  (in-arena a (Plain (string.append "ab" "cd"))))

(define (main) : i64
  (let
    [s (arena.make)]
    [p : Plain (make-plain s)]
    (begin
      (arena.destroy-safe! s)
      (string.string-length (& p.text)))))