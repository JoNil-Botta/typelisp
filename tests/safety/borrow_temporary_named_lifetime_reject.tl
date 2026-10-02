;: No lifetime name can name the storage of a borrowed temporary.
(define (twice [n : (& i64)]) : i64
  (* 2 (deref n)))

(define (main) : i64
  (twice (& a 5)))