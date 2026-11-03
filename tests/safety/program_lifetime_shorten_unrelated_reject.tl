(defstruct N
  (:lifetimes r)
  (value (& r i64)))

(define (unrelated [x : (N a)] [q : (& q i64)]) : (N q)
  x)

(define (main) : i64
  0)