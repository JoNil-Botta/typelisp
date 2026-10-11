;; #8776: `return` cannot carry a with-scratch body allocation out of the form,
;; and neither can a global store.
(import stdlib.string)

(define g : String
  "")

(define (leak) : String
  (with-scratch (return (string.int->string 1234567)) 0)
  "")

(define (main) : i64
  (with-scratch (set! g (string.int->string 7654321)) 0)
  (let
    [s : String (leak)]
    (with-scratch (string.string-length (string.int->string 1111111)))
    (if (and (string.eq (& s) "1234567") (string.eq (& g) "7654321"))
      100
      7)))