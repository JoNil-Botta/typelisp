;; #8681: a closure called under a scoped arena that stores an allocation of
;; that arena into a global.
(import stdlib.string)

(define g : String
  "")

(define (main) : i64
  (let
    [f : (-> unit)
      (lambda () : unit
        (set! g (string.append "a" "b")))]
    (with-arena phase (f))
    (string.string-length (& g))))