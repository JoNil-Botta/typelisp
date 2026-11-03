(define (keep [program : (& program i64)]) : (& program i64)
  program)

(define (main) : i64
  (let
    [local : i64 1]
    (deref (keep (& local)))))