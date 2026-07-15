;; TypeLisp port of ISPC v1.31.0 point_transform.ispc::transform_points.
;; Upstream commit: c6adb4f86f5678ce6c41951b1e2b59f727455697
;; Upstream path: examples/cpu/point_transform_ctypes/point_transform.ispc
;; License: BSD-3-Clause; see kernel.ispc and LICENSE.BSD-3-Clause.
;;
;; The upstream uniform sin(rotation)/cos(rotation) prelude is factored out in
;; both implementations. The kernel receives the same exact f32 sin/cos values;
;; no transcendental or host-libm work is part of correctness or measurement.
(import stdlib.array)
(import stdlib.io)

(define (transform-points
  [points-x : (Array f32)]
  [points-y : (Array f32)]
  [result-x : (Array f32)]
  [result-y : (Array f32)]
  [scale-x : f32]
  [scale-y : f32]
  [translate-x : f32]
  [translate-y : f32]
  [sin-theta : f32]
  [cos-theta : f32]
  [strength : f32]
  [count : i64]) : unit
  ;; Keep both destinations in one map, matching the derived ISPC kernel. The
  ;; SIMD lowering shares the repeated scaled x/y input subexpressions.
  (foreach
    ([i : i64 0 count])
    (begin
      (array-set!
        result-x
        i
        (+
          (+
            (* (* (array-ref points-x i) scale-x) cos-theta)
            (*
              (* (* (array-ref points-y i) scale-y) sin-theta)
              (cast -1.0 : f32)))
          (* translate-x strength)))
      (array-set!
        result-y
        i
        (+
          (+
            (* (* (array-ref points-x i) scale-x) sin-theta)
            (* (* (array-ref points-y i) scale-y) cos-theta))
          (* translate-y strength))))))

(define (transform-points-scalar
  [points-x : (Array f32)]
  [points-y : (Array f32)]
  [result-x : (Array f32)]
  [result-y : (Array f32)]
  [scale-x : f32]
  [scale-y : f32]
  [translate-x : f32]
  [translate-y : f32]
  [sin-theta : f32]
  [cos-theta : f32]
  [strength : f32]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (let
        [x : f32 (* (array-ref points-x i) scale-x)]
        [y : f32 (* (array-ref points-y i) scale-y)]
        [x-rot : f32 (- (* x cos-theta) (* y sin-theta))]
        [y-rot : f32 (+ (* x sin-theta) (* y cos-theta))]
        (begin
          (array-set! result-x i (+ x-rot (* translate-x strength)))
          (array-set! result-y i (+ y-rot (* translate-y strength)))
          (set! i (+ i 1)))))))

(define (point-transform-case-count [case-id : i64]) : i64
  (cond
    [(= case-id 0) 0]
    [(= case-id 1) 3]
    [(= case-id 2) 8]
    [(= case-id 3) 16]
    [else 19]))

(define (point-transform-input-x [case-id : i64] [index : i64]) : f32
  (cond
    [(= case-id 1) (cast (- index 2) : f32)]
    [(= case-id 2) (cast (- index 4) : f32)]
    [(= case-id 3) (* (cast (- index 8) : f32) (cast 0.25 : f32))]
    [else (* (cast (- index 9) : f32) (cast -0.375 : f32))]))

(define (point-transform-input-y [case-id : i64] [index : i64]) : f32
  (cond
    [(= case-id 1) (cast (- (* index 2) 1) : f32)]
    [(= case-id 2) (cast (- 3 index) : f32)]
    [(= case-id 3) (* (cast (- (% index 5) 2) : f32) (cast 0.5 : f32))]
    [else (* (cast (- (% index 7) 3) : f32) (cast 1.25 : f32))]))

(define (point-transform-scale-x [case-id : i64]) : f32
  (cond
    [(= case-id 1) (cast 2.0 : f32)]
    [(= case-id 2) (cast -1.0 : f32)]
    [(= case-id 3) (cast 1.25 : f32)]
    [else (cast -1.5 : f32)]))

(define (point-transform-scale-y [case-id : i64]) : f32
  (cond
    [(= case-id 1) (cast -0.5 : f32)]
    [(= case-id 2) (cast 2.0 : f32)]
    [(= case-id 3) (cast -0.75 : f32)]
    [else (cast 0.25 : f32)]))

(define (point-transform-translate-x [case-id : i64]) : f32
  (cond
    [(= case-id 1) (cast 4.0 : f32)]
    [(= case-id 2) (cast 1.0 : f32)]
    [(= case-id 3) (cast -2.5 : f32)]
    [else (cast 4.0 : f32)]))

(define (point-transform-translate-y [case-id : i64]) : f32
  (cond
    [(= case-id 1) (cast -8.0 : f32)]
    [(= case-id 2) (cast -3.0 : f32)]
    [(= case-id 3) (cast 3.5 : f32)]
    [else (cast -6.0 : f32)]))

(define (point-transform-sin-theta [case-id : i64]) : f32
  (cond
    [(< case-id 3) (cast 0.0 : f32)]
    [(= case-id 3) (cast 0.6000000238418579 : f32)]
    [else (cast -0.7071067690849304 : f32)]))

(define (point-transform-cos-theta [case-id : i64]) : f32
  (cond
    [(< case-id 3) (cast 1.0 : f32)]
    [(= case-id 3) (cast 0.800000011920929 : f32)]
    [else (cast 0.7071067690849304 : f32)]))

(define (point-transform-strength [case-id : i64]) : f32
  (cond
    [(= case-id 1) (cast 0.0 : f32)]
    [(= case-id 2) (cast 1.0 : f32)]
    [(= case-id 3) (cast 0.375 : f32)]
    [else (cast 1.25 : f32)]))

(define (point-transform-fill-inputs
  [points-x : (Array f32)]
  [points-y : (Array f32)]
  [case-id : i64]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (array-set! points-x i (point-transform-input-x case-id i))
        (array-set! points-y i (point-transform-input-y case-id i))
        (set! i (+ i 1))))))

(define (point-transform-fill
  [values : (Array f32)]
  [count : i64]
  [value : f32]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (array-set! values i value)
        (set! i (+ i 1))))))

(define (point-transform-ulp-distance [left : f32] [right : f32]) : i64
  (let
    [left-bits : u32 (io.float-f32-bits left)]
    [right-bits : u32 (io.float-f32-bits right)]
    [left-mag : i64 (cast (bit-and left-bits (cast 0x7fffffff : u32)) : i64)]
    [right-mag : i64 (cast (bit-and right-bits (cast 0x7fffffff : u32)) : i64)]
    [same-sign : bool
      (=
        (bit-and left-bits (cast 0x80000000 : u32))
        (bit-and right-bits (cast 0x80000000 : u32)))]
    (if same-sign
      (if (> left-mag right-mag)
        (- left-mag right-mag)
        (- right-mag left-mag))
      (+ left-mag right-mag))))

(define (point-transform-close? [got : f32] [want : f32] [max-ulp : i64]) : bool
  (and
    (io.float-f32-finite? got)
    (io.float-f32-finite? want)
    (<= (point-transform-ulp-distance got want) max-ulp)))

(define (point-transform-fixed-exact?
  [case-id : i64]
  [index : i64]
  [got-x : f32]
  [got-y : f32]) : bool
  (cond
    [(= case-id 1)
      (and
        (= got-x (cast (- (* index 2) 4) : f32))
        (= got-y (- (cast 0.5 : f32) (cast index : f32))))]
    [(= case-id 2)
      (and
        (= got-x (cast (- 5 index) : f32))
        (= got-y (cast (- 3 (* index 2)) : f32)))]
    [else true]))

(define (point-transform-case-ok?
  [case-id : i64]
  [points-x : (Array f32)]
  [points-y : (Array f32)]
  [got-x : (Array f32)]
  [got-y : (Array f32)]
  [want-x : (Array f32)]
  [want-y : (Array f32)]) : bool
  (let
    [count : i64 (point-transform-case-count case-id)]
    [sentinel : f32 (cast 12345.0 : f32)]
    [scale-x : f32 (point-transform-scale-x case-id)]
    [scale-y : f32 (point-transform-scale-y case-id)]
    [translate-x : f32 (point-transform-translate-x case-id)]
    [translate-y : f32 (point-transform-translate-y case-id)]
    [sin-theta : f32 (point-transform-sin-theta case-id)]
    [cos-theta : f32 (point-transform-cos-theta case-id)]
    [strength : f32 (point-transform-strength case-id)]
    [repetition : i64 0]
    [i : i64 0]
    [ok : bool true]
    [max-ulp : i64
      (if (< case-id 3)
        0
        2)]
    (begin
      (point-transform-fill-inputs points-x points-y case-id count)
      (point-transform-fill got-x (+ count 1) sentinel)
      (point-transform-fill got-y (+ count 1) sentinel)
      (point-transform-fill want-x (+ count 1) sentinel)
      (point-transform-fill want-y (+ count 1) sentinel)
      (transform-points-scalar
        points-x
        points-y
        want-x
        want-y
        scale-x
        scale-y
        translate-x
        translate-y
        sin-theta
        cos-theta
        strength
        count)
      (while (< repetition 100)
        (begin
          (transform-points
            points-x
            points-y
            got-x
            got-y
            scale-x
            scale-y
            translate-x
            translate-y
            sin-theta
            cos-theta
            strength
            count)
          (set! repetition (+ repetition 1))))
      (while (and ok (< i count))
        (begin
          (if (and
            (point-transform-close?
              (array-ref got-x i)
              (array-ref want-x i)
              max-ulp)
            (point-transform-close?
              (array-ref got-y i)
              (array-ref want-y i)
              max-ulp)
            (point-transform-fixed-exact?
              case-id
              i
              (array-ref got-x i)
              (array-ref got-y i)))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      (and
        ok
        (=
          (io.float-f32-bits (array-ref got-x count))
          (io.float-f32-bits sentinel))
        (=
          (io.float-f32-bits (array-ref got-y count))
          (io.float-f32-bits sentinel))))))

(define (main) : i64
  (let
    [capacity : i64 20]
    [points-x : (Array f32) (array.make-array f32 capacity)]
    [points-y : (Array f32) (array.make-array f32 capacity)]
    [got-x : (Array f32) (array.make-array f32 capacity)]
    [got-y : (Array f32) (array.make-array f32 capacity)]
    [want-x : (Array f32) (array.make-array f32 capacity)]
    [want-y : (Array f32) (array.make-array f32 capacity)]
    [case-id : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< case-id 5))
        (begin
          (if (point-transform-case-ok?
            case-id
            points-x
            points-y
            got-x
            got-y
            want-x
            want-y)
            unit
            (set! ok false))
          (set! case-id (+ case-id 1))))
      (if ok
        42
        1))))