;; TypeLisp port of ISPC v1.31.0 mandelbrot.ispc::mandelbrot_ispc.
;; Upstream commit: c6adb4f86f5678ce6c41951b1e2b59f727455697
;; Upstream path: examples/cpu/mandelbrot/mandelbrot.ispc
;; License: BSD-3-Clause; see kernel.ispc and LICENSE.BSD-3-Clause.
;;
;; ISPC uses `unmasked` updates after a lane breaks out of mandel's loop.
;; TypeLisp retires a lane permanently when its varying while condition turns
;; false, so only active lanes update z. The returned iteration count is the
;; only observable helper state, making the two contracts equivalent here.
(import stdlib.vector)
(import (vector.vector i32) as i32v)
(import (vector.vector f32) as f32v)

(define (mandelbrot-row
  [iterations : (&mut iterations (Slice i32))]
  [remaining : (&mut remaining (Slice i32))]
  [output : (&mut output (Slice i32))]
  [x-values : (&mut x-values (Slice f32))]
  [y-values : (&mut y-values (Slice f32))]
  [z-re : (&mut z-re (Slice f32))]
  [z-im : (&mut z-im (Slice f32))]
  [width : i64]
  [max-iterations : i32]
  [escape-radius : f32]) : unit
  (foreach
    ([i : i64 0 width])
    (let
      [x : f32 (array-ref x-values i)]
      [y : f32 (array-ref y-values i)]
      (begin
        (set! (array-ref z-re i) x)
        (set! (array-ref z-im i) y)
        (set! (array-ref iterations i) 0)
        (set! (array-ref remaining i) max-iterations)
        (while (> (array-ref remaining i) 0)
          (if (>
            (+
              (* (array-ref z-re i) (array-ref z-re i))
              (* (array-ref z-im i) (array-ref z-im i)))
            escape-radius)
            (set! (array-ref remaining i) 0)
            (let
              [old-re : f32 (array-ref z-re i)]
              [old-im : f32 (array-ref z-im i)]
              [new-re : f32 (- (* old-re old-re) (* old-im old-im))]
              [new-im : f32 (* (+ old-re old-re) old-im)]
              (begin
                (set! (array-ref z-re i) (+ x new-re))
                (set! (array-ref z-im i) (+ y new-im))
                (set! (array-ref iterations i) (+ (array-ref iterations i) 1))
                (set! (array-ref remaining i) (+ (array-ref remaining i) -1))))))
        (set! (array-ref output i) (array-ref iterations i))))))

(define (mandelbrot
  [x0 : f32]
  [y0 : f32]
  [x1 : f32]
  [y1 : f32]
  [width : i64]
  [height : i64]
  [max-iterations : i32]
  [output : (&mut output (Slice i32))]
  [row-output : (&mut row-output (Slice i32))]
  [x-values : (&mut x-values (Slice f32))]
  [y-values : (&mut y-values (Slice f32))]
  [z-re : (&mut z-re (Slice f32))]
  [z-im : (&mut z-im (Slice f32))]
  [iterations : (&mut iterations (Slice i32))]
  [remaining : (&mut remaining (Slice i32))]) : unit
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
              (set! (array-ref x-values i) (+ x0 (* (cast i : f32) dx)))
              (set! (array-ref y-values i) (+ y0 (* (cast j : f32) dy)))
              (set! i (+ i 1)))))
        (let
          [kernel : (->
            (&mut iterations (Slice i32))
            (&mut remaining (Slice i32))
            (&mut output (Slice i32))
            (&mut x-values (Slice f32))
            (&mut y-values (Slice f32))
            (&mut z-re (Slice f32))
            (&mut z-im (Slice f32))
            i64
            i32
            f32
            unit)
            mandelbrot-row]
          (kernel
            iterations
            remaining
            row-output
            x-values
            y-values
            z-re
            z-im
            width
            max-iterations
            (cast 4.0 : f32)))
        (let
          [i : i64 0]
          (while (< i width)
            (begin
              (set!
                (array-ref output (+ i (* j width)))
                (array-ref row-output i))
              (set! i (+ i 1)))))
        (set! j (+ j 1))))))

(define (expected-value [case-id : i64] [index : i64]) : i32
  (cond
    [(= case-id 2) 0]
    [(= case-id 3) 17]
    [(= case-id 4) (cond [(= index 0) 0] [(= index 1) 2] [else 12])]
    [(= case-id 5)
      (cond
        [(< index 2) 0]
        [(= index 2) 1]
        [(< index 8) 2]
        [(= index 8) 3]
        [(= index 9) 4]
        [(= index 10) 12]
        [(< index 13) 3]
        [(= index 13) 2]
        [(= index 14) 1]
        [else 1])]
    [(= case-id 6)
      (cond
        [(< index 2) 0]
        [(< index 4) 1]
        [(< index 9) 2]
        [(< index 11) 3]
        [(= index 11) 5]
        [(= index 12) 8]
        [(= index 13) 4]
        [(= index 14) 3]
        [(= index 15) 2]
        [else 1])]
    [else 0]))

(define (fill-expected!
  [values : (&mut values (Slice i32))]
  [case-id : i64]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (set! (array-ref values i) (expected-value case-id i))
        (set! i (+ i 1))))))

(define (buffers-equal
  [left : (& left (Slice i32))]
  [right : (& right (Slice i32))]
  [count : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i count)
        (begin
          (if (!= (array-ref left i) (array-ref right i))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (checksum [values : (& values (Slice i32))] [count : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! sum (+ sum (* (+ i 1) (cast (+ (array-ref values i) 1) : i64))))
          (set! i (+ i 1))))
      sum)))

(define (mandelbrot-i32-buffer [capacity : i64]) : i32v.Vec
  (let
    [out : i32v.Vec (i32v.with-capacity capacity)]
    [index : i64 0]
    (begin
      (while (< index capacity)
        (begin
          (i32v.push (&mut out) 0)
          (set! index (+ index 1))))
      out)))

(define (mandelbrot-f32-buffer [capacity : i64]) : f32v.Vec
  (let
    [out : f32v.Vec (f32v.with-capacity capacity)]
    [index : i64 0]
    (begin
      (while (< index capacity)
        (begin
          (f32v.push (&mut out) (cast 0.0 : f32))
          (set! index (+ index 1))))
      out)))

(define (run-case
  [case-id : i64]
  [x0 : f32]
  [y0 : f32]
  [x1 : f32]
  [y1 : f32]
  [width : i64]
  [height : i64]
  [max-iterations : i32]
  [expected-checksum : i64]) : bool
  (let
    [count : i64 (* width height)]
    [capacity : i64 (+ count 1)]
    [sentinel : i32 -1431655766]
    [got : i32v.Vec (mandelbrot-i32-buffer capacity)]
    [want : i32v.Vec (mandelbrot-i32-buffer capacity)]
    [row-output : i32v.Vec (mandelbrot-i32-buffer width)]
    [x-values : f32v.Vec (mandelbrot-f32-buffer width)]
    [y-values : f32v.Vec (mandelbrot-f32-buffer width)]
    [z-re : f32v.Vec (mandelbrot-f32-buffer width)]
    [z-im : f32v.Vec (mandelbrot-f32-buffer width)]
    [iterations : i32v.Vec (mandelbrot-i32-buffer width)]
    [remaining : i32v.Vec (mandelbrot-i32-buffer width)]
    ;; Construct one live-prefix view per owned buffer. These borrows remain
    ;; stable across every row; no hot-path call rebuilds or copies storage.
    [got-view : (&mut got (Slice i32)) (i32v.view-mut (&mut got))]
    [want-view : (&mut want (Slice i32)) (i32v.view-mut (&mut want))]
    [row-output-view : (&mut row-output (Slice i32))
      (i32v.view-mut (&mut row-output))]
    [x-values-view : (&mut x-values (Slice f32))
      (f32v.view-mut (&mut x-values))]
    [y-values-view : (&mut y-values (Slice f32))
      (f32v.view-mut (&mut y-values))]
    [z-re-view : (&mut z-re (Slice f32)) (f32v.view-mut (&mut z-re))]
    [z-im-view : (&mut z-im (Slice f32)) (f32v.view-mut (&mut z-im))]
    [iterations-view : (&mut iterations (Slice i32))
      (i32v.view-mut (&mut iterations))]
    [remaining-view : (&mut remaining (Slice i32))
      (i32v.view-mut (&mut remaining))]
    (begin
      (set! (array-ref got-view count) sentinel)
      (set! (array-ref want-view count) sentinel)
      (fill-expected! want-view case-id count)
      (mandelbrot
        x0
        y0
        x1
        y1
        width
        height
        max-iterations
        got-view
        row-output-view
        x-values-view
        y-values-view
        z-re-view
        z-im-view
        iterations-view
        remaining-view)
      (and
        (buffers-equal
          (slice-view got-view 0 count)
          (slice-view want-view 0 count)
          count)
        (= (array-ref got-view count) sentinel)
        (= (array-ref want-view count) sentinel)
        (= (checksum (slice-view got-view 0 count) count) expected-checksum)))))

(define (main) : i64
  (if (and
    (run-case
      0
      (cast -2.0 : f32)
      (cast -1.0 : f32)
      (cast 1.0 : f32)
      (cast 1.0 : f32)
      0
      3
      12
      0)
    (run-case
      1
      (cast -2.0 : f32)
      (cast -1.0 : f32)
      (cast 1.0 : f32)
      (cast 1.0 : f32)
      3
      0
      12
      0)
    (run-case
      2
      (cast 3.0 : f32)
      (cast 3.0 : f32)
      (cast 4.0 : f32)
      (cast 4.0 : f32)
      1
      1
      17
      1)
    (run-case
      3
      (cast 0.0 : f32)
      (cast 0.0 : f32)
      (cast 1.0 : f32)
      (cast 1.0 : f32)
      1
      1
      17
      18)
    (run-case
      4
      (cast -2.0 : f32)
      (cast -1.0 : f32)
      (cast 1.0 : f32)
      (cast 1.0 : f32)
      3
      1
      12
      46)
    (run-case
      5
      (cast -2.0 : f32)
      (cast -1.0 : f32)
      (cast 1.0 : f32)
      (cast 1.0 : f32)
      16
      1
      24
      532)
    (run-case
      6
      (cast -2.0 : f32)
      (cast -1.0 : f32)
      (cast 1.0 : f32)
      (cast 1.0 : f32)
      19
      1
      32
      681)
    (run-case
      7
      (cast -2.0 : f32)
      (cast -1.0 : f32)
      (cast 1.0 : f32)
      (cast 1.0 : f32)
      5
      1
      0
      15))
    42
    1))