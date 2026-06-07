(define (put-first [items : (&mut items (Array i64))] [value : i64]) : unit
  (array-set! items 0 value))

(define (push-tail [items : (&mut items (Array i64))] [value : i64]) : unit
  (array-push! items value))

(define (put-fixed [items : (&mut items (Array i64 2))] [value : i64]) : unit
  (array-set! items 1 value))

(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    [fixed : (Array i64 2) (array 0 0)]
    (begin
      (array-set! items 0 1)
      (put-first (&mut items) 40)
      (push-tail (&mut items) 2)
      (put-fixed (&mut fixed) 41)
      (if (and
        (= (array-length items) 2)
        (and
          (= (array-ref items 0) 40)
          (and (= (array-ref items 1) 2) (= (array-ref fixed 1) 41))))
        42
        1))))