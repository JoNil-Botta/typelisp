(define (read [v : (& i64)]) : i64
  (deref v))

(define (get-read) : (-> (& a i64) i64)
  read)

(define (outer [mk : (-> (-> (& a i64) i64))]) : i64
  (let
    [g : (-> (& z i64) i64) (mk)]
    [x : i64 1]
    (g (& x))))

(define (main) : i64
  (outer get-read))