;; Keep gang values live across a scalar ABI call whose kernel uses vector
;; registers and across an atomic operation. Use them again in gang code.
(import stdlib.atomic)

(define (fill-scratch [dst : (&mut (Slice i64))] [seed : i64]) : i64
  (foreach
    ([j : i64 0 (length dst)])
    (let
      [value : i64 (+ seed j)]
      (foreach-active
        [lane : i64]
        (set! (array-ref dst (lane-value j)) (lane-value value)))))
  (array-ref dst 16))

(define (main) : i64
  (let
    [out : atomic.AtomicI64Buffer (atomic.i64-buffer 1)]
    [after : (__tl_dyn-array i64) (__tl_make-array i64 19)]
    [scratch : (Array i64 17) (make-array i64 17)]
    [j : i64 0]
    [ok : bool true]
    (foreach
      ([i : i64 0 19])
      (let
        [x : i64 (+ i 3)]
        [v1 : i64 (+ x 1)]
        [v2 : i64 (+ x 2)]
        [v3 : i64 (+ x 3)]
        [v4 : i64 (+ x 4)]
        [v5 : i64 (+ x 5)]
        [v6 : i64 (+ x 6)]
        [v7 : i64 (+ x 7)]
        [v8 : i64 (+ x 8)]
        [v9 : i64 (+ x 9)]
        [v10 : i64 (+ x 10)]
        [v11 : i64 (+ x 11)]
        [v12 : i64 (+ x 12)]
        [v13 : i64 (+ x 13)]
        [v14 : i64 (+ x 14)]
        [v15 : i64 (+ x 15)]
        [v16 : i64 (+ x 16)]
        [v17 : i64 (+ x 17)]
        (foreach-active
          [lane : i64]
          (set!
            ok
            (and
              ok
              (=
                (fill-scratch (&mut scratch) (lane-value i))
                (+ (lane-value i) 16))))
          (atomic.atomic-i64-add! (& out) 0 1)
          (set!
            ok
            (and
              ok
              (=
                (+
                  (+
                    (+
                      (+ (lane-value x) (lane-value v1))
                      (+ (lane-value v2) (lane-value v3)))
                    (+
                      (+ (lane-value v4) (lane-value v5))
                      (+ (lane-value v6) (+ (lane-value v7) (lane-value v8)))))
                  (+
                    (+
                      (+ (lane-value v9) (lane-value v10))
                      (+ (lane-value v11) (lane-value v12)))
                    (+
                      (+ (lane-value v13) (lane-value v14))
                      (+ (lane-value v15) (+ (lane-value v16) (lane-value v17))))))
                (+ (* 18 (+ (lane-value i) 3)) 153)))))
        (set!
          (array-ref after i)
          (+
            (+ (+ (+ x v1) (+ v2 v3)) (+ (+ v4 v5) (+ v6 (+ v7 v8))))
            (+ (+ (+ v9 v10) (+ v11 v12)) (+ (+ v13 v14) (+ v15 (+ v16 v17))))))))
    (while (< j 19)
      (set! ok (and ok (= (array-ref after j) (+ (* 18 (+ j 3)) 153))))
      (set! j (+ j 1)))
    (if (and ok (= (atomic.atomic-i64-load (& out) 0) 19))
      42
      1)))