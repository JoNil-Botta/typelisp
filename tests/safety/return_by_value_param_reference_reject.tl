;: A borrow of a by-value parameter cannot be returned: the parameter's
;: storage belongs to the call (Rust E0515). Main accepted this signature.
(define (borrow-n [n : i64]) : (& n i64)
  (& n))

(define (main) : i64
  (deref (borrow-n 42)))