(define (main) : i32
  (let
    [xs : (Array i64 8) (array 1 2 3 4 5 6 7 8)]
    [out : (Array i64 2) (array 0 0)]
    (begin
      (foreach ([i : i64 0 8]) (set! (array-ref out 0) (array-ref xs i)))
      (cast (array-ref out 0) : i32))))