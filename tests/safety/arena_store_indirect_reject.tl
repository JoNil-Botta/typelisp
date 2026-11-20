;; #8815: a call through a function value is a call of any function whose
;; value is taken.
(import stdlib.string)

(define g : String
  "")

(define (stash [s : String]) : unit
  (set! g s))

(define (main) : i64
  (let
    [f : (-> String unit) stash]
    (with-scratch (f (string.int->string 1234567)) 0)
    (string.string-length (& g))))