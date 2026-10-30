(define (apply-fixed-local [p : (& a i64)] [cb : (-> (& a i64) i64)]) : i64
  (let
    [x : i64 3]
    (cb (& x))))

(define (main) : i64
  0)