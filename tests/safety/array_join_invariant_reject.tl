(define (bad [left : (&mut a (& a i64))] [right : (&mut b (& b i64))]) : unit
  (let
    [local : i64 7]
    [reference (& local)]
    [items (array left right (&mut reference))]
    unit))

(define (main) : i64
  0)