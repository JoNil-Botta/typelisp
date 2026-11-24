;; Implicit-cleanup arena escape: borrowed temporary enum `:cleanup` runs
;; inside `with-arena` and stores an active-arena allocation into a global.
(import stdlib.string)

(define g : String
  "init")

(define (leak-fd [_fd : i64]) : unit
  (set! g (string.append "hello" "world")))

(defenum EGuard
  (:cleanup close-eguard)
  (One i64 (:cleanup leak-fd))
  (None))

(define (touch [_x : (& EGuard)]) : i64
  1)

(define (main) : i64
  (with-arena r (touch (& (EGuard.One 1))))
  (if (string.eq (& g) "helloworld")
    42
    7))