;; #8776: a with-scratch body allocation stored into a global would dangle once
;; the scratch arena is destroyed.
(import stdlib.string)

(define g : String
  "")

(define (main) : i64
  (with-scratch (set! g (string.int->string 7654321)) 0)
  (with-scratch (string.string-length (string.int->string 1111111)))
  (if (string.eq (& g) "7654321")
    100
    7))