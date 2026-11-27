(define (mark [cells : (&mut (Slice i64))] [slot : i64]) : unit
  (set! (array-ref cells slot) 1))

(define (visit [cells : (&mut (Slice i64))]) : i64
  (let
    [seen : i64 0]
    (foreach
      ([i : i64 0 8])
      (if (= (array-ref cells i) 1)
        (foreach-active
          [lane : i64]
          (mark cells (+ (lane-value i) 1))
          (set! seen (+ seen 1)))
        unit))
    seen))

(define (main) : i64
  (let
    [cells : (Array i64 9) (make-array i64 9)]
    (set! (array-ref cells 0) 1)
    (visit (&mut cells))))