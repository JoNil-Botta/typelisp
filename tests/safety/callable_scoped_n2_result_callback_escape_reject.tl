(define (run [k : (& o i64)] [mk : (-> (-> (& a i64) (& a i64)))]) : (& o i64)
  (let
    [g : (-> (& z i64) (& z i64)) (mk)]
    [x : i64 1]
    (g (& x))))

(define (main) : i64
  0)