(defstruct Held
  (:lifetimes payload)
  (view (& payload i64))
  (padding (Array i64 4)))

(define (escape [p : (in outer (& loan (Held payload)))]) : (in
    outer
    (Held payload))
  (deref p))

(define (main) : i64
  0)