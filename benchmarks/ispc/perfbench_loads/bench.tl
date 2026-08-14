;; TypeLisp port of ISPC v1.31.0 perfbench.ispc::loads.
;; Upstream commit: c6adb4f86f5678ce6c41951b1e2b59f727455697
;; Upstream path: examples/cpu/perfbench/perfbench.ispc
;; License: BSD-3-Clause; see kernel.ispc and LICENSE.BSD-3-Clause.
;;
;; The source deliberately preserves f32 accumulation and horizontal-sum
;; intent. Scalar, AVX2, and AVX-512 TypeLisp modes must all pass the fixed
;; bit-pattern oracle; do not widen this case to f64.
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector f32) as f32v)

(define (loads [values : (&mut values (Slice f32))] [count : i64]) : f32
  (spmd-reduce sum ([i : i64 0 count]) (cast 0.0 : f32) (array-ref values i)))

(define (loads-scalar [values : (&mut values (Slice f32))] [count : i64]) : f32
  (let
    [sum : f32 (cast 0.0 : f32)]
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! sum (+ sum (array-ref values i)))
          (set! i (+ i 1))))
      sum)))

(define (loads-case-count [case-id : i64]) : i64
  (cond
    [(= case-id 0) 0]
    [(= case-id 1) 3]
    [(= case-id 2) 8]
    [(= case-id 3) 16]
    [(= case-id 4) 19]
    [(= case-id 5) 12]
    [else 65536]))

(define (loads-case-value [case-id : i64] [index : i64]) : f32
  (cond
    [(= case-id 1) (cast (+ index 1) : f32)]
    [(= case-id 2) (cast 1.0 : f32)]
    [(= case-id 3) (cast 1.0 : f32)]
    [(= case-id 4) (cast (- (% index 7) 3) : f32)]
    [(= case-id 5)
      (if (= (% index 2) 0)
        (cast 1024.0 : f32)
        (cast -1024.0 : f32))]
    [else (cast 1.0 : f32)]))

(define (loads-fill-case!
  [values : (&mut values (Slice f32))]
  [case-id : i64]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (set! (array-ref values i) (loads-case-value case-id i))
        (set! i (+ i 1))))))

(define (loads-buffer [capacity : i64]) : f32v.Vec
  (let
    [out : f32v.Vec (f32v.with-capacity capacity)]
    [index : i64 0]
    (begin
      (while (< index capacity)
        (begin
          (f32v.push! out (cast 0.0 : f32))
          (set! index (+ index 1))))
      out)))

(define (loads-case-expected-bits [case-id : i64]) : u32
  (cond
    [(= case-id 0) (cast 0x00000000 : u32)]
    [(= case-id 1) (cast 0x40c00000 : u32)]
    [(= case-id 2) (cast 0x41000000 : u32)]
    [(= case-id 3) (cast 0x41800000 : u32)]
    [(= case-id 4) (cast 0xc0a00000 : u32)]
    [(= case-id 5) (cast 0x00000000 : u32)]
    [else (cast 0x47800000 : u32)]))

(define (main) : i64
  (let
    [values : f32v.Vec (loads-buffer 65536)]
    [values-view : (&mut values (Slice f32)) (f32v.view-mut (&mut values))]
    ;; Keep the measured kernel out of line so static reports cover its body.
    [kernel : (-> (&mut values (Slice f32)) i64 f32) loads]
    [case-id : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< case-id 7))
        (let
          [count : i64 (loads-case-count case-id)]
          [result : f32 (cast 0.0 : f32)]
          [repetition : i64 0]
          (begin
            (loads-fill-case! values-view case-id count)
            (while (< repetition 100)
              (begin
                (set! result (kernel values-view count))
                (set! repetition (+ repetition 1))))
            (if (and
              (=
                (io.float-f32-bits (loads-scalar values-view count))
                (loads-case-expected-bits case-id))
              (= (io.float-f32-bits result) (loads-case-expected-bits case-id)))
              unit
              (set! ok false))
            (set! case-id (+ case-id 1)))))
      (if ok
        42
        1))))