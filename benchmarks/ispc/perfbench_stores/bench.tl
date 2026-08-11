;; TypeLisp port of ISPC v1.31.0 perfbench.ispc::stores.
;; Upstream commit: c6adb4f86f5678ce6c41951b1e2b59f727455697
;; Upstream path: examples/cpu/perfbench/perfbench.ispc
;; License: BSD-3-Clause; see kernel.ispc and LICENSE.BSD-3-Clause.
;;
;; The upstream kernel converts each lane's f32 zero to i32, then converts it
;; back to f32 for the store. TypeLisp's current SIMD IR has no vector numeric
;; conversion, so this port loads/stores f32 directly and restricts zeros to
;; exactly representable integer values. The observable result is bit-exact.
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector f32) as f32v)

(define (stores
  [values : (&mut values (Slice f32))]
  [count : i64]
  [zeros : (&mut zeros (Slice f32))]
  [_result : (&mut result (Slice f32))]) : unit
  (foreach
    ([i : i64 0 count])
    (set! (array-ref values i) (array-ref zeros (program-index)))))

(define (stores-detect-width [values : (&mut values (Slice f32))]) : i64
  (let
    [first-bits : u32 (io.float-f32-bits (array-ref values 0))]
    [width : i64 1]
    (begin
      (while (and
        (< width 32)
        (!= (io.float-f32-bits (array-ref values width)) first-bits))
        (set! width (+ width 1)))
      width)))

(define (stores-case-count [case-id : i64]) : i64
  (cond
    [(= case-id 0) 0]
    [(= case-id 1) 3]
    [(= case-id 2) 4]
    [(= case-id 3) 8]
    [(= case-id 4) 16]
    [(= case-id 5) 19]
    [else 65536]))

(define (stores-zero [lane : i64]) : f32
  (cast (- (* (+ lane 1) 17) 133) : f32))

(define (stores-fill!
  [values : (&mut values (Slice f32))]
  [count : i64]
  [value : f32]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (set! (array-ref values i) value)
        (set! i (+ i 1))))))

(define (stores-init-zeros! [zeros : (&mut zeros (Slice f32))] [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (set! (array-ref zeros i) (stores-zero i))
        (set! i (+ i 1))))))

(define (stores-output-matches?
  [values : (&mut values (Slice f32))]
  [count : i64]
  [width : i64]
  [sentinel : f32]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i count))
        (begin
          (if (=
            (io.float-f32-bits (array-ref values i))
            (io.float-f32-bits (stores-zero (% i width))))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      (and
        ok
        (=
          (io.float-f32-bits (array-ref values count))
          (io.float-f32-bits sentinel))))))

(define (stores-buffer [capacity : i64]) : f32v.Vec
  (let
    [out : f32v.Vec (f32v.with-capacity capacity)]
    [index : i64 0]
    (begin
      (while (< index capacity)
        (begin
          (f32v.push (&mut out) (cast 0.0 : f32))
          (set! index (+ index 1))))
      out)))

(define (main) : i64
  (let
    [max-count : i64 65536]
    [values : f32v.Vec (stores-buffer (+ max-count 1))]
    [zeros : f32v.Vec (stores-buffer 32)]
    [result : f32v.Vec (stores-buffer 1)]
    ;; Build each backing borrow once, outside the 100-call measured loops.
    [values-view : (&mut values (Slice f32)) (f32v.view-mut (&mut values))]
    [zeros-view : (&mut zeros (Slice f32)) (f32v.view-mut (&mut zeros))]
    [result-view : (&mut result (Slice f32)) (f32v.view-mut (&mut result))]
    [width : i64 0]
    [sentinel : f32 (cast 12345.0 : f32)]
    [case-id : i64 0]
    [ok : bool true]
    (begin
      (stores-init-zeros! zeros-view 32)
      ;; Infer the f32 gang width from the backend-observable lane pattern.
      ;; Returning it in the exit code lets the harness distinguish modes.
      (stores-fill! values-view 33 sentinel)
      (stores values-view 32 zeros-view result-view)
      (set! width (stores-detect-width values-view))
      (if (or (= width 1) (= width 8) (= width 16))
        unit
        (set! ok false))
      (while (and ok (< case-id 7))
        (let
          [count : i64 (stores-case-count case-id)]
          [repetition : i64 0]
          (begin
            (stores-fill! values-view (+ count 1) sentinel)
            (while (< repetition 100)
              (begin
                (stores values-view count zeros-view result-view)
                (set! repetition (+ repetition 1))))
            (if (stores-output-matches? values-view count width sentinel)
              unit
              (set! ok false))
            (set! case-id (+ case-id 1)))))
      (if ok
        (+ 41 width)
        1))))