(define (make [b : (&mut holder (Array (& keep i64) 1))]) : (Box (-> (& keep i64) unit))
  (box (lambda ([q : (& keep i64)]) : unit (set! (array-ref b 0) q))))
(define (main) : i64 0)
