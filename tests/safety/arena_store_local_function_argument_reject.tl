;; A local function value passed to a helper that calls it inside an arena
;; scope is the local's value, not the harmless global of the same name.
(import stdlib.string)

(define g : String
  "")

(define (stash) : unit
  (set! g (string.append "a" "b")))

(define (helper) : unit
  unit)

(define (run [f : (-> unit)]) : unit
  (with-arena phase (f)))

(define (main) : i64
  (let
    [helper : (-> unit) stash]
    (run helper)
    (string.string-length (& g))))