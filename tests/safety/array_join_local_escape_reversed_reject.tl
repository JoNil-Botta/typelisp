(define (bad [incoming : (& a i64)]) : (Array (& a i64) 2)
  (let
    [local : i64 7]
    [items (array (& local) incoming)]
    items))

(define (main) : i64
  0)