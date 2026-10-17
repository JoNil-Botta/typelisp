(defstruct Held
  (:lifetimes payload)
  (view (& payload i64))
  (padding (Array i64 4)))

(defstruct Outer
  (:lifetimes payload)
  (held (Held payload)))

(define (escape [p : (in outer (& loan (Outer payload)))]) : (in
    outer
    (Held payload))
  p.held)

(define (main) : i64
  0)