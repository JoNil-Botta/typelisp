;; Implicit-cleanup arena escape: nested `:owned` struct `:cleanup` invoked by
;; `with` inside `with-arena` stores an allocation into a global.
(import stdlib.string)

(define g : String
  "init")

(define (leak-fd [_fd : i64]) : unit
  (set! g (string.append "hello" "world")))

(defstruct Inner
  (:cleanup close-inner)
  (fd i64 (:cleanup leak-fd)))

(defstruct Outer
  (:cleanup close-outer)
  (inner Inner (:owned)))

(define (main) : i64
  (with-arena r (with ([x (Outer (Inner 1)) close-outer]) x.inner.fd))
  (if (string.eq (& g) "helloworld")
    42
    7))