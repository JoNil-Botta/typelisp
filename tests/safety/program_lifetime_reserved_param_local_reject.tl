(define (takes [x : (& program i64)]) : i64
  (deref x))

(define (main) : i64
  (let
    [local : i64 1]
    (takes (& local))))