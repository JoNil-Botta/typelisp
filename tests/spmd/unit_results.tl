;; Unit branches have effects but no vector payload, including at opt 0.
;; Empty ranges and both SIMD tails must leave inactive sentinel slots alone.
(define (touch-heavy [x : i64]) : unit
  (begin
    (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7)
    unit))

(define (store-heavy [out : (&mut out (__tl_dyn-array i64))] [i : i64]) : unit
  (begin
    (set! (array-ref out i) (+ (+ (+ (+ (+ (+ (+ i 1) 2) 3) 4) 5) 6) 7))
    unit))

(define (fill [out : (&mut out (__tl_dyn-array i64))] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (touch-heavy i)
      (let
        [u : unit
          (if (< i 3)
            unit
            unit)]
        u)
      (if (< i 3)
        (begin
          (set! (array-ref out i) (+ i 28))
          unit)
        (store-heavy out i))
      (if (< i 5)
        unit
        (begin
          (set! (array-ref out i) (+ (array-ref out i) 100))
          unit)))))

(define (check-length [n : i64]) : bool
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 21)]
    [i : i64 0]
    [ok : bool true]
    (while (< i 21)
      (set! (array-ref out i) (- 0 1))
      (set! i (+ i 1)))
    (fill (&mut out) n)
    (set! i 0)
    (while (< i 21)
      (let
        [expected : i64
          (if (< i n)
            (+
              (+ i 28)
              (if (< i 5)
                0
                100))
            (- 0 1))]
        (set! ok (and ok (= (array-ref out i) expected))))
      (set! i (+ i 1)))
    ok))

(define (main) : i64
  (if (and
    (check-length 0)
    (check-length 1)
    (check-length 3)
    (check-length 4)
    (check-length 5)
    (check-length 8)
    (check-length 13)
    (check-length 20))
    42
    1))