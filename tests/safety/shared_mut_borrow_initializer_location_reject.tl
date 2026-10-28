(define copied : i64
  (let
    [state : i64 1]
    [shared : (& state i64) (& state)]
    (deref (&mut shared))))

(define (main) : i64
  copied)