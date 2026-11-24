(defstruct Boxed
  (n i64)
  (s String))

(define (clone-boxed [x : (& r Boxed)]) : i64
  x.n)

(define (main) : i64
  (with-scratch (Boxed 42 "hello")))