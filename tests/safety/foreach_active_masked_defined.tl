;: foreach-active is accepted in masked if and cond arms, varying match arms,
;: varying while bodies and nested masks; masked-out lanes run nothing.
(define (main) : i64
  (let
    [picked : i64 0]
    [deep : i64 0]
    [matched : i64 0]
    [steps : i64 0]
    [work : (Array i64 4) (array 0 1 2 3)]
    (begin
      (foreach
        ([i : i64 0 12])
        (cond
          [(< i 3) (foreach-active [lane : i64] (set! picked (+ picked 1)))]
          [(= (% i 3) 0)
            (if (> i 6)
              (foreach-active [lane : i64] (set! deep (+ deep (lane-value i))))
              unit)]
          [else unit]))
      (foreach
        ([i : i64 0 6])
        (match (% i 3)
          [1
            (foreach-active
              [lane : i64]
              (set! matched (+ matched (lane-value i))))]
          [_ unit]))
      (foreach
        ([i : i64 0 4])
        (while (> (array-ref work i) 0)
          (begin
            (foreach-active [lane : i64] (set! steps (+ steps 1)))
            (set! (array-ref work i) (- (array-ref work i) 1)))))
      (if (and (= picked 3) (= deep 9) (= matched 5) (= steps 6))
        42
        1))))