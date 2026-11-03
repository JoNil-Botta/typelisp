;; An explicitly named borrow still belongs to the local value's scope.
(define (bad) : (& program i64)
  (let
    [program : i64 0]
    (& program program)))

(define (main) : i64
  0)