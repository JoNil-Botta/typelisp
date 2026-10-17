(defstruct Wide
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define (escape [p : (& loan (in payload Wide))]) : Wide
  (deref p))

(define (main) : i64
  0)