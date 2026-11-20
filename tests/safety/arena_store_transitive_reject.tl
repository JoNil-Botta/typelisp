;; #8815: the global store is one call deeper.
(import stdlib.string)

(define g : String
  "")

(define (stash [s : String]) : unit
  (set! g s))

(define (stash2 [s : String]) : unit
  (stash s))

(define (main) : i64
  (with-scratch (stash2 (string.int->string 1234567)) 0)
  (string.string-length (& g)))