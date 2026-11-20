;; A helper may allocate temporaries through a bare arena parameter and
;; return a value that holds none (#8173 twin).
(import stdlib.arena)
(import stdlib.string)

(define (measure [a : arena.Arena]) : i64
  (let
    [s : String (in-arena a (string.append "forty" "-two!"))]
    (string.string-length (& s))))

(define (main) : i64
  (let
    [o : arena.Arena (arena.make)]
    [n : i64 (measure o)]
    (arena.destroy-safe! o)
    (+ n 32)))