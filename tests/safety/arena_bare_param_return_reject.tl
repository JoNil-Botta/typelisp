;; #8173: a value allocated through a bare arena parameter cannot be returned;
;; the caller's destroy-safe! would leave it dangling.
(import stdlib.arena)
(import stdlib.string)

(defstruct Plain
  (text String))

(define (make-plain [a : arena.Arena]) : Plain
  (in-arena a (Plain (string.append "ab" "cd"))))

(define (main) : i64
  (let
    [s : arena.Arena (arena.make)]
    [p : Plain (make-plain s)]
    (begin
      (arena.destroy-safe! s)
      (string.string-length (& p.text)))))