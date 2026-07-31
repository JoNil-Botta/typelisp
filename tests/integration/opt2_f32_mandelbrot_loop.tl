;; #5062: opt2 must preserve all loop-carried f32 values in this scalar helper.
(define (mandel-scalar [c-re : f32] [c-im : f32] [count : i32]) : i32
  (let
    [z-re : f32 c-re]
    [z-im : f32 c-im]
    [i : i32 0]
    (begin
      (while (and
        (< i count)
        (<= (+ (* z-re z-re) (* z-im z-im)) (cast 4.0 : f32)))
        (let
          [new-re : f32 (- (* z-re z-re) (* z-im z-im))]
          [new-im : f32 (* (cast 2.0 : f32) (* z-re z-im))]
          (begin
            (set! z-re (+ c-re new-re))
            (set! z-im (+ c-im new-im))
            (set! i (+ i 1)))))
      i)))

(define (render-scalar-image!
  [x0 : f32]
  [y0 : f32]
  [x1 : f32]
  [y1 : f32]
  [width : i64]
  [height : i64]
  [limit : i32]
  [output : (__tl_dyn-array i32)]) : unit
  (let
    [dx : f32 (/ (- x1 x0) (cast width : f32))]
    [dy : f32 (/ (- y1 y0) (cast height : f32))]
    [j : i64 0]
    (while (< j height)
      (begin
        (let
          [i : i64 0]
          (while (< i width)
            (begin
              (array-set!
                output
                (+ i (* j width))
                (mandel-scalar
                  (+ x0 (* (cast i : f32) dx))
                  (+ y0 (* (cast j : f32) dy))
                  limit))
              (set! i (+ i 1)))))
        (set! j (+ j 1))))))

;; Keep the coordinates behind the image loop and distinguish a bounded cycle,
;; an immediate escape, and a point that must reach its iteration limit.
(define (main) : i64
  (let
    [output : (__tl_dyn-array i32) (make-array i32 1)]
    [bounded : i32 0]
    [immediate : i32 0]
    [maxed : i32 0]
    (begin
      (render-scalar-image!
        (cast 0.0 : f32)
        (cast -1.0 : f32)
        (cast 1.0 : f32)
        (cast 0.0 : f32)
        1
        1
        12
        output)
      (set! bounded (array-ref output 0))
      (render-scalar-image!
        (cast 3.0 : f32)
        (cast 0.0 : f32)
        (cast 4.0 : f32)
        (cast 1.0 : f32)
        1
        1
        12
        output)
      (set! immediate (array-ref output 0))
      (render-scalar-image!
        (cast 0.0 : f32)
        (cast 0.0 : f32)
        (cast 1.0 : f32)
        (cast 1.0 : f32)
        1
        1
        7
        output)
      (set! maxed (array-ref output 0))
      (if (and (= bounded 12) (= immediate 0) (= maxed 7))
        42
        (+ (cast bounded : i64) (+ (cast immediate : i64) (cast maxed : i64)))))))