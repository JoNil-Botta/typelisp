(define (my-argc) : i64
  101)

(define (my-argv [x : i64]) : i64
  (+ x 102))

(define (my-envp) : i64
  103)

(define (my-syscall [x : i64] [y : i64]) : i64
  (+ x y))