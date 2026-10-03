;; foreach-active has only its scalar reference lowering until #8307. Both SIMD
;; modes must reject it with the focused diagnostic, never run the gang through
;; a scalar fallback; the scalar run checks the serialized result.
(define (main) : i64
  (let
    [idx : (Array i64 8) (array 2 0 2 5 2 0 7 2)]
    [counts : (Array i64 8) (make-array i64 8)]
    [odd : i64 0]
    (foreach
      ([i : i64 0 8])
      (if (= (% i 2) 1)
        (foreach-active
          [lane : i64]
          (let
            [bucket : i64 (lane-value (array-ref idx i))]
            (set! (array-ref counts bucket) (+ (array-ref counts bucket) 1))
            (set! odd (+ odd 1))))
        unit))
    (if (and
      (= (array-ref counts 0) 2)
      (= (array-ref counts 5) 1)
      (= (array-ref counts 2) 1)
      (= odd 4))
      42
      1)))