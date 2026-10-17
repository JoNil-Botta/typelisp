(defstruct Held
  (:lifetimes payload)
  (view (& payload i64))
  (padding (Array i64 4)))

(define (escape [p : (& loan (Held payload))]) : (Held payload)
  (deref p))

(define (main) : i64
  0)