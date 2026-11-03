(defstruct N
  (:lifetimes r)
  (value (& r i64)))

(define (shorten [x : (N program)] [q : (& q i64)]) : (N q)
  x)

(define (main) : i64
  0)