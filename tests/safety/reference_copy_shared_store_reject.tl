(defstruct Wide
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define (write [p : (& loan Wide)]) : unit
  (set! (deref p).a 42))

(define (main) : i64
  0)