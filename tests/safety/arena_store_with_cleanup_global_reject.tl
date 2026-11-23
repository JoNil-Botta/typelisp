;; Implicit-cleanup arena escape: `with` cleanup inside `with-arena` stores
;; an active-arena allocation into a global.
(import stdlib.string)

(define g : String
  "init")

(define (leak [_x : i64]) : unit
  (set! g (string.append "hello" "world")))

(define (main) : i64
  (with-arena r (with ([x 1 leak]) 0))
  (if (string.eq (& g) "helloworld")
    42
    7))