;; #8805 shape 2, #8815: a scratch-body allocation passed by value to a
;; callee that stores its parameter into a global.
(import stdlib.string)

(define g : String
  "")

(define (stash [s : String]) : unit
  (set! g s))

(define (main) : i64
  (with-scratch (stash (string.int->string 1234567)) 0)
  (if (string.eq (& g) "1234567")
    100
    7))