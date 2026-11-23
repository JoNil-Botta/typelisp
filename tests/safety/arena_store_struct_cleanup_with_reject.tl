;; Implicit-cleanup arena escape: `with` binding using a struct `:cleanup`
;; disposer inside `with-arena` stores an allocation into a global.
(import stdlib.string)

(define g : String
  "init")

(define (leak-fd [_fd : i64]) : unit
  (set! g (string.append "hello" "world")))

(defstruct Guard
  (:cleanup close-guard)
  (fd i64 (:cleanup leak-fd)))

(define (main) : i64
  (with-arena r (with ([x (Guard 1) close-guard]) x.fd))
  (if (string.eq (& g) "helloworld")
    42
    7))