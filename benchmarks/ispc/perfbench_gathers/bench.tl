;; TypeLisp port of ISPC v1.31.0 perfbench.ispc::gathers.
;; Upstream commit: c6adb4f86f5678ce6c41951b1e2b59f727455697
;; Upstream path: examples/cpu/perfbench/perfbench.ispc
;; License: BSD-3-Clause; see kernel.ispc and LICENSE.BSD-3-Clause.
;;
;; Keep offsets lane-specific and the values/sums exactly representable as
;; binary32. Five elements of backing padding admit every active offset while
;; leaving inactive tail lanes out of range if masking is lost.
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector f32) as f32v)
(import (vector.vector i64) as i64v)

(define (gathers
  [values : (&mut values (Slice f32))]
  [count : i64]
  [offsets : (&mut offsets (Slice i64))]) : f32
  (spmd-reduce
    sum
    ([i : i64 0 count])
    (cast 0.0 : f32)
    (array-ref values (+ i (array-ref offsets (program-index))))))

(define (gathers-scalar
  [values : (&mut values (Slice f32))]
  [count : i64]
  [offsets : (&mut offsets (Slice i64))]
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

(define (gathers-init-offsets! [offsets : (&mut offsets (Slice i64))]) : unit
  (let
    [i : i64 0]
    (while (< i 32)
      (begin
        (set! (array-ref offsets i) (gathers-offset i))
        (set! i (+ i 1))))))

(define (gathers-value [index : i64]) : f32
  (cast (+ 1 (% (* index 5) 17)) : f32))

(define (gathers-fill-values!
  [values : (&mut values (Slice f32))]
  [length : i64]) : unit
  (let
    [i : i64 0]
    (while (< i length)
      (begin
        (set! (array-ref values i) (gathers-value i))
        (set! i (+ i 1))))))

(define (gathers-f32-buffer [capacity : i64]) : f32v.Vec
  (let
    [out : f32v.Vec (f32v.with-capacity capacity)]
    [index : i64 0]
    (begin
      (while (< index capacity)
        (begin
          (f32v.push (&mut out) (cast 0.0 : f32))
          (set! index (+ index 1))))
      out)))

(define (gathers-i64-buffer [capacity : i64]) : i64v.Vec
  (let
    [out : i64v.Vec (i64v.with-capacity capacity)]
    [index : i64 0]
    (begin
      (while (< index capacity)
        (begin
          (i64v.push (&mut out) 0)
          (set! index (+ index 1))))
      out)))

(define (gathers-detect-width) : i64
  (let
    [markers : f32v.Vec (gathers-f32-buffer 32)]
    [lanes : f32v.Vec (gathers-f32-buffer 32)]
    [markers-view : (&mut markers (Slice f32)) (f32v.view-mut (&mut markers))]
    [lanes-view : (&mut lanes (Slice f32)) (f32v.view-mut (&mut lanes))]
    [i : i64 0]
    [first-bits : u32 0]
    [width : i64 1]
    (begin
      (while (< i 32)
        (begin
          (set! (array-ref markers-view i) (cast (+ i 1) : f32))
          (set! i (+ i 1))))
      (foreach
        ([i : i64 0 32])
        (set! (array-ref lanes-view i) (array-ref markers-view (program-index))))
      (set! first-bits (io.float-f32-bits (array-ref lanes-view 0)))
      (while (and
        (< width 32)
        (!= (io.float-f32-bits (array-ref lanes-view width)) first-bits))
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
    [offsets : i64v.Vec (gathers-i64-buffer 32)]
    [offsets-view : (&mut offsets (Slice i64)) (i64v.view-mut (&mut offsets))]
    [width : i64 (gathers-detect-width)]
    [case-id : i64 0]
    [ok : bool true]
    (begin
      (gathers-init-offsets! offsets-view)
      (if (or (= width 1) (= width 8) (= width 16))
        unit
        (set! ok false))
      (while (and ok (< case-id 7))
        (let
          [count : i64 (gathers-case-count case-id)]
          [length : i64 (+ count 5)]
          [values : f32v.Vec (gathers-f32-buffer length)]
          ;; Reuse this one live borrow across all 100 measured calls.
          [values-view : (&mut values (Slice f32))
            (f32v.view-mut (&mut values))]
          ;; Keep the measured kernel out of line so static reports cover its body.
          [kernel : (->
            (&mut values (Slice f32))
            i64
            (&mut offsets (Slice i64))
            f32)
            gathers]
          [expected : f32 (cast 0.0 : f32)]
          [result : f32 (cast 0.0 : f32)]
          [repetition : i64 0]
          (begin
            (gathers-fill-values! values-view length)
            (set!
              expected
              (gathers-scalar values-view count offsets-view width))
            (while (< repetition 100)
              (begin
                (set! result (kernel values-view count offsets-view))
                (set! repetition (+ repetition 1))))
            (if (= (io.float-f32-bits result) (io.float-f32-bits expected))
              unit
              (set! ok false))
            (set! case-id (+ case-id 1)))))
      (if ok
        42
        1))))