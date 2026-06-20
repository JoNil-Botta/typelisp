(define (read-len [items : (& items (Array i64))]) : i64
  (array-length items))

(define (push-with-len [items : (&mut items (Array i64))] [value : i64]) : unit
  (array-push! items value))

(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    (begin
      (array-set! items 0 40)
      (push-with-len (&mut items) (read-len (& items)))
      (push-with-len (&mut items) (array-length items))
      (if (and
        (= (array-length items) 3)
        (= (array-ref items 0) 40)
        (= (array-ref items 1) 1)
        (= (array-ref items 2) 2))
        42
        1))))