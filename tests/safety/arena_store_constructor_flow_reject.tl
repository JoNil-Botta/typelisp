;; #8815: the parameter reaches the global inside a constructor.
(import stdlib.string)

(defstruct Wrap
  (s String))

(define g2 : Wrap
  (Wrap ""))

(define (stash [s : String]) : unit
  (set! g2 (Wrap s)))

(define (main) : i64
  (with-scratch (stash (string.int->string 1234567)) 0)
  (string.string-length (& g2.s)))