;; Both callbacks share the enclosing signature's one fixed a.
(define (bad [first : (-> (& a i64) i64)] [second : (-> (& a i64) i64)]) : i64
  (let
    [local : i64 1]
    (first (& local))))

(define (main) : i64
  0)