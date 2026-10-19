(define (store [p : (& keep i64)]
               [b : (&mut holder (Array (& keep i64) 1))]) : unit
  (let [put (lambda ([q : (& keep i64)]) : unit (set! (array-ref b 0) q))] (let [short : i64 5] (put (& short)))))
(define (main) : i64 0)
