;; Implicit-cleanup arena escape: borrowed temporary struct `:cleanup` runs
;; inside `with-arena` and stores an active-arena allocation into a global.
(import stdlib.string)

(define g : String
  "init")

(define (leak-fd [_fd : i64]) : unit
  (set! g (string.append "hello" "world")))

(defstruct Guard
  (:cleanup close-guard)
  (fd i64 (:cleanup leak-fd)))

(define (touch [x : (& Guard)]) : i64
  x.fd)

(define (main) : i64
  (with-arena r (touch (& (Guard 1))))
  (if (string.eq (& g) "helloworld")
    42
    7))