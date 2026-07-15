;; TypeLisp port of ISPC v1.31.0 mandelbrot.ispc::mandelbrot_ispc.
;; Upstream commit: c6adb4f86f5678ce6c41951b1e2b59f727455697
;; Upstream path: examples/cpu/mandelbrot/mandelbrot.ispc
;; License: BSD-3-Clause; see kernel.ispc and LICENSE.BSD-3-Clause.
;;
;; ISPC uses `unmasked` updates after a lane breaks out of mandel's loop.
;; TypeLisp retires a lane permanently when its varying while condition turns
;; false, so only active lanes update z. The returned iteration count is the
;; only observable helper state, making the two contracts equivalent here.
(import stdlib.array)

(define (mandelbrot-row
  [iterations : (Array i32)]
  [remaining : (Array i32)]
  [output : (Array i32)]
  [x-values : (Array f32)]
  [y-values : (Array f32)]
  [z-re : (Array f32)]
  [z-im : (Array f32)]
  [width : i64]
  [max-iterations : i32]
  [escape-radius : f32]) : unit
  (foreach
    ([i : i64 0 width])
    (let
      [x : f32 (array-ref x-values i)]
      [y : f32 (array-ref y-values i)]
      (begin
        (array-set! z-re i x)
        (array-set! z-im i y)
        (array-set! iterations i 0)
        (array-set! remaining i max-iterations)
        (while (> (array-ref remaining i) 0)
          (if (>
            (+
              (* (array-ref z-re i) (array-ref z-re i))
              (* (array-ref z-im i) (array-ref z-im i)))
            escape-radius)
            (array-set! remaining i 0)
            (let
              [old-re : f32 (array-ref z-re i)]
              [old-im : f32 (array-ref z-im i)]
              [new-re : f32 (- (* old-re old-re) (* old-im old-im))]
              [new-im : f32 (* (+ old-re old-re) old-im)]
              (begin
                (array-set! z-re i (+ x new-re))
                (array-set! z-im i (+ y new-im))
                (array-set! iterations i (+ (array-ref iterations i) 1))
                (array-set! remaining i (+ (array-ref remaining i) -1))))))
        (array-set! output i (array-ref iterations i))))))

(define (mandelbrot
  [x0 : f32]
  [y0 : f32]
  [x1 : f32]
  [y1 : f32]
  [width : i64]
  [height : i64]
  [max-iterations : i32]
  [output : (Array i32)]
  [row-output : (Array i32)]
  [x-values : (Array f32)]
  [y-values : (Array f32)]
  [z-re : (Array f32)]
  [z-im : (Array f32)]
  [iterations : (Array i32)]
  [remaining : (Array i32)]) : unit
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
              (array-set! x-values i (+ x0 (* (cast i : f32) dx)))
              (array-set! y-values i (+ y0 (* (cast j : f32) dy)))
              (set! i (+ i 1)))))
        (let
          [kernel : (->
            (Array i32)
            (Array i32)
            (Array i32)
            (Array f32)
            (Array f32)
            (Array f32)
            (Array f32)
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
              (array-set! output (+ i (* j width)) (array-ref row-output i))
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

(define (fill-expected! [values : (Array i32)] [case-id : i64] [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (array-set! values i (expected-value case-id i))
        (set! i (+ i 1))))))

(define (buffers-equal [left : (Array i32)] [right : (Array i32)] [count : i64]) : bool
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

(define (checksum [values : (Array i32)] [count : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! sum (+ sum (* (+ i 1) (cast (+ (array-ref values i) 1) : i64))))
          (set! i (+ i 1))))
      sum)))

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
    [got : (Array i32) (array.make-array i32 capacity)]
    [want : (Array i32) (array.make-array i32 capacity)]
    [row-output : (Array i32) (array.make-array i32 width)]
    [x-values : (Array f32) (array.make-array f32 width)]
    [y-values : (Array f32) (array.make-array f32 width)]
    [z-re : (Array f32) (array.make-array f32 width)]
    [z-im : (Array f32) (array.make-array f32 width)]
    [iterations : (Array i32) (array.make-array i32 width)]
    [remaining : (Array i32) (array.make-array i32 width)]
    (begin
      (array-set! got count sentinel)
      (array-set! want count sentinel)
      (fill-expected! want case-id count)
      (mandelbrot
        x0
        y0
        x1
        y1
        width
        height
        max-iterations
        got
        row-output
        x-values
        y-values
        z-re
        z-im
        iterations
        remaining)
      (and
        (buffers-equal got want count)
        (= (array-ref got count) sentinel)
        (= (array-ref want count) sentinel)
        (= (checksum got count) expected-checksum)))))

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