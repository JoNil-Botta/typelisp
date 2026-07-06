;; Regression for phi edge-copy staging under register pressure. The inner
;; forward edge that finds an existing slot used to scavenge %r9 for a spilled
;; merge phi while %r9 still held b0, then leave %r9 = 0. The next outer-loop
;; iteration dereferenced the null array base at opt2.
(defenum PhiForwardItem
  (PhiForwardA i64)
  (PhiForwardB i64 i64)
  (PhiForwardC i64 i64 i64))

(define (phi-forward-repro [n : i64] [items : (Array PhiForwardItem)]) : i64
  (let
    [b0 : (Array i64) (make-array i64 n)]
    [b1 : (Array i64) (make-array i64 n)]
    [b2 : (Array i64) (make-array i64 n)]
    [b3 : (Array i64) (make-array i64 n)]
    [b4 : (Array i64) (make-array i64 n)]
    [b5 : (Array i64) (make-array i64 n)]
    [b6 : (Array i64) (make-array i64 n)]
    [b7 : (Array i64) (make-array i64 n)]
    [b8 : (Array i64) (make-array i64 n)]
    [b9 : (Array i64) (make-array i64 n)]
    [c0 : i64 0]
    [c1 : i64 0]
    [c2 : i64 0]
    [c3 : i64 0]
    [i : i64 0]
    [j : i64 0]
    (begin
      (while (< i n)
        (begin
          (match (array-ref items i)
            [(PhiForwardA x) unit]
            [(PhiForwardB x y) (set! c3 y)]
            [(PhiForwardC x y z)
              (let
                [slot : i64 -1]
                [k : i64 0]
                (begin
                  (while (< k c2)
                    (if (= (array-ref b0 k) x)
                      (begin
                        (set! slot k)
                        (set! k c2))
                      (set! k (+ k 1))))
                  (if (< slot 0)
                    (begin
                      (set! slot c2)
                      (array-set! b0 c2 x)
                      (array-set! b1 c2 z)
                      (set! c2 (+ c2 1)))
                    unit)
                  (array-set! b2 c0 i)
                  (array-set! b3 c0 (+ i 1))
                  (array-set! b4 c0 (+ i 2))
                  (array-set! b5 c0 (+ i 3))
                  (array-set! b6 slot (+ i 4))
                  (array-set! b7 slot (+ i 5))
                  (array-set! b8 slot (+ i 6))
                  (array-set! b9 c1 (+ i 7))
                  (set! c0 (+ c0 1))
                  (set! c1 (+ c1 1))))])
          (set! i (+ i 1))))
      (+
        (array-ref b2 0)
        (+ (array-ref b3 0) (+ (array-ref b8 0) (+ (array-ref b9 0) (+ c3 j))))))))

(define (main) : i64
  (let
    [items : (Array PhiForwardItem) (make-array PhiForwardItem 3)]
    (begin
      (array-set! items 0 (PhiForwardC 7 8 9))
      (array-set! items 1 (PhiForwardC 7 8 9))
      (array-set! items 2 (PhiForwardC 5 6 7))
      (if (= (phi-forward-repro 3 items) 15)
        42
        1))))