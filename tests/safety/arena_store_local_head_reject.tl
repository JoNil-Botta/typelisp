;; A local binding naming a function value shadows a harmless global of the
;; same name: the call is a call through a function value.
(import stdlib.string)

(define g : String
  "")

(define (stash) : unit
  (set! g (string.append "a" "b")))

(define (helper) : unit
  unit)

(define (main) : i64
  (let
    [helper : (-> unit) stash]
    (with-arena phase (helper))
    (string.string-length (& g))))