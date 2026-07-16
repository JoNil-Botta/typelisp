;; TypeLisp port of ISPC v1.31.0 perfbench.ispc::gathers.
;; Upstream commit: c6adb4f86f5678ce6c41951b1e2b59f727455697
;; Upstream path: examples/cpu/perfbench/perfbench.ispc
;; License: BSD-3-Clause; see kernel.ispc and LICENSE.BSD-3-Clause.
;;
;; Keep offsets lane-specific and the values/sums exactly representable as
;; binary32. Five elements of backing padding admit every active offset while
;; leaving inactive tail lanes out of range if masking is lost.
(import stdlib.array)
(import stdlib.io)

(define (gathers [values : (Array f32)] [count : i64] [offsets : (Array i64)]) : f32
  (spmd-reduce
    sum
    ([i : i64 0 count])
    (cast 0.0 : f32)
    (array-ref values (+ i (array-ref offsets (program-index))))))

(define (gathers-scalar
  [values : (Array f32)]
  [count : i64]
  [offsets : (Array i64)]
  [width : i64]) : f32
  (let
    [sum : f32 (cast 0.0 : f32)]
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (set!
            sum
            (+ sum (array-ref values (+ i (array-ref offsets (% i width))))))
          (set! i (+ i 1))))
      sum)))

(define (gathers-offset [lane : i64]) : i64
  (cond
    [(= (% lane 8) 0) 0]
    [(= (% lane 8) 1) 3]
    [(= (% lane 8) 2) 1]
    [(= (% lane 8) 3) 4]
    [(= (% lane 8) 4) 2]
    [(= (% lane 8) 5) 0]
    [(= (% lane 8) 6) 4]
    [else 1]))

(define (gathers-init-offsets! [offsets : (Array i64)]) : unit
  (let
    [i : i64 0]
    (while (< i 32)
      (begin
        (array-set! offsets i (gathers-offset i))
        (set! i (+ i 1))))))

(define (gathers-value [index : i64]) : f32
  (cast (+ 1 (% (* index 5) 17)) : f32))

(define (gathers-fill-values! [values : (Array f32)] [length : i64]) : unit
  (let
    [i : i64 0]
    (while (< i length)
      (begin
        (array-set! values i (gathers-value i))
        (set! i (+ i 1))))))

(define (gathers-detect-width) : i64
  (let
    [markers : (Array f32) (array.make-array f32 32)]
    [lanes : (Array f32) (array.make-array f32 32)]
    [i : i64 0]
    [first-bits : u32 0]
    [width : i64 1]
    (begin
      (while (< i 32)
        (begin
          (array-set! markers i (cast (+ i 1) : f32))
          (set! i (+ i 1))))
      (foreach
        ([i : i64 0 32])
        (array-set! lanes i (array-ref markers (program-index))))
      (set! first-bits (io.float-f32-bits (array-ref lanes 0)))
      (while (and
        (< width 32)
        (!= (io.float-f32-bits (array-ref lanes width)) first-bits))
        (set! width (+ width 1)))
      width)))

(define (gathers-case-count [case-id : i64]) : i64
  (cond
    [(= case-id 0) 0]
    [(= case-id 1) 1]
    [(= case-id 2) 3]
    [(= case-id 3) 8]
    [(= case-id 4) 16]
    [(= case-id 5) 19]
    [else 65536]))

(define (main) : i64
  (let
    [offsets : (Array i64) (array.make-array i64 32)]
    [width : i64 (gathers-detect-width)]
    [case-id : i64 0]
    [ok : bool true]
    (begin
      (gathers-init-offsets! offsets)
      (if (or (= width 1) (= width 8) (= width 16))
        unit
        (set! ok false))
      (while (and ok (< case-id 7))
        (let
          [count : i64 (gathers-case-count case-id)]
          [length : i64 (+ count 5)]
          [values : (Array f32) (array.make-array f32 length)]
          [expected : f32 (cast 0.0 : f32)]
          [result : f32 (cast 0.0 : f32)]
          [repetition : i64 0]
          (begin
            (gathers-fill-values! values length)
            (set! expected (gathers-scalar values count offsets width))
            (while (< repetition 100)
              (begin
                (set! result (gathers values count offsets))
                (set! repetition (+ repetition 1))))
            (if (= (io.float-f32-bits result) (io.float-f32-bits expected))
              unit
              (set! ok false))
            (set! case-id (+ case-id 1)))))
      (if ok
        42
        1))))