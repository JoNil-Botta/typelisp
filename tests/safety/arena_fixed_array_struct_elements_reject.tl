;; #8985: a fixed array of arena structs keeps their region.
(import stdlib.arena)
(import stdlib.string)

(defstruct OS
  (text String)
  (n i64))

(define (keep) : (Array OS 2)
  (with-arena
    r
    (array (OS (string.int->string 42) 1) (OS (string.int->string 42) 1))))

(define (main) : i64
  (let
    [k (keep)]
    (+ 40 (string.string-length (& (array-ref k 0).text)))))