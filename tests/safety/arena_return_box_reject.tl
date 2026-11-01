(define (leak [n : i64]) : (Box i64)
  (with-arena phase (return (box n)))
  (box 0))

(define (main) : i64
  (deref (leak 42)))