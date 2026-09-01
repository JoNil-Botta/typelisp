(module spmd_consumer)

(import fixture.src.lib as fixture)
(import (fixture.package-module) as fixture-generated)

(fixture.package-decls)

(define (fill [out : (__tl_dyn-array i64)] [n : i64]) : bool
  (begin
    (foreach ([i : i64 0 n]) (set! (array-ref out i) (fixture.helper i 3)))
    (and (= (array-ref out 0) 3) (= (array-ref out 12) 15))))

(define (fill-masked [out : (__tl_dyn-array i64)] [n : i64]) : bool
  (begin
    (foreach
      ([i : i64 0 n])
      (if (< i 10)
        (if (fixture.positive? i)
          (set! (array-ref out i) (fixture.shifted (+ i 1)))
          (set! (array-ref out i) 0))
        (set! (array-ref out i) 0)))
    (and
      (= (array-ref out 5) 0)
      (= (array-ref out 6) 12)
      (= (array-ref out 9) 15)
      (= (array-ref out 10) 0))))

(define (fill-uniform-result [out : (__tl_dyn-array i64)] [n : i64]) : bool
  (begin
    (foreach
      ([i : i64 0 n])
      (set! (array-ref out i) (fixture.constant (+ i 1) 7)))
    (and (= (array-ref out 0) 7) (= (array-ref out 69) 7))))

(define (fill-uniform-i16
  [input : (__tl_dyn-array i16)]
  [out : (__tl_dyn-array i16)]
  [n : i64]) : bool
  (begin
    (foreach
      ([i : i64 0 n])
      (set!
        (array-ref out i)
        (fixture.constant-i16 (array-ref input i) (cast -20000 : i16))))
    (and
      (= (array-ref out 0) (cast -20000 : i16))
      (= (array-ref out 69) (cast -20000 : i16)))))

(define (fill-uniform-u16
  [input : (__tl_dyn-array u16)]
  [out : (__tl_dyn-array u16)]
  [n : i64]) : bool
  (begin
    (foreach
      ([i : i64 0 n])
      (set!
        (array-ref out i)
        (fixture.constant-u16 (array-ref input i) (cast 50000 : u16))))
    (and
      (= (array-ref out 0) (cast 50000 : u16))
      (= (array-ref out 69) (cast 50000 : u16)))))

(define (fill-uniform-i8
  [input : (__tl_dyn-array i8)]
  [out : (__tl_dyn-array i8)]
  [n : i64]) : bool
  (begin
    (foreach
      ([i : i64 0 n])
      (set!
        (array-ref out i)
        (fixture.constant-i8 (array-ref input i) (cast -100 : i8))))
    (and
      (= (array-ref out 0) (cast -100 : i8))
      (= (array-ref out 69) (cast -100 : i8)))))

(define (fill-uniform-u8
  [input : (__tl_dyn-array u8)]
  [out : (__tl_dyn-array u8)]
  [n : i64]) : bool
  (begin
    (foreach
      ([i : i64 0 n])
      (set!
        (array-ref out i)
        (fixture.constant-u8 (array-ref input i) (cast 200 : u8))))
    (and
      (= (array-ref out 0) (cast 200 : u8))
      (= (array-ref out 69) (cast 200 : u8)))))

(define (fill-literal-uniform-result [out : (__tl_dyn-array i64)] [n : i64]) : bool
  (begin
    (foreach
      ([i : i64 0 n])
      (set! (array-ref out i) (fixture.literal-constant (+ i 1))))
    (and (= (array-ref out 0) 7) (= (array-ref out 69) 7))))

(define (fill-cast-uniform-result [out : (__tl_dyn-array i64)] [n : i64]) : bool
  (begin
    (foreach
      ([i : i64 0 n])
      (set! (array-ref out i) (fixture.cast-constant (+ i 1))))
    (and (= (array-ref out 0) 11) (= (array-ref out 69) 11))))

(define (call-unit-result [n : i64]) : unit
  (foreach ([i : i64 0 n]) (fixture.sink (+ i 1))))

(define (fill-f64
  [input : (__tl_dyn-array f64)]
  [out : (__tl_dyn-array f64)]
  [n : i64]) : bool
  (begin
    (foreach
      ([i : i64 0 n])
      (set! (array-ref out i) (fixture.add-f64 (array-ref input i) 0.5)))
    (and (= (array-ref out 0) 0.5) (= (array-ref out 69) 69.5))))

(define (fill-f32
  [input : (__tl_dyn-array f32)]
  [out : (__tl_dyn-array f32)]
  [n : i64]) : bool
  (begin
    (foreach
      ([i : i64 0 n])
      (set! (array-ref out i) (fixture.add-f32 (array-ref input i) 0.25)))
    (and (= (array-ref out 0) 0.25) (= (array-ref out 69) 69.25))))

(define (main) : i64
  (let
    [n : i64 70]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [masked : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [uniform-result : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [input-i16 : (__tl_dyn-array i16) (__tl_make-array i16 n)]
    [uniform-i16 : (__tl_dyn-array i16) (__tl_make-array i16 n)]
    [input-u16 : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [uniform-u16 : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [input-i8 : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [uniform-i8 : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [input-u8 : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [uniform-u8 : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [literal-uniform-result : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [cast-uniform-result : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [f64-input : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [f64-out : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [f32-input : (__tl_dyn-array f32) (__tl_make-array f32 n)]
    [f32-out : (__tl_dyn-array f32) (__tl_make-array f32 n)]
    [i : i64 0]
    [out-ok? : bool false]
    [masked-ok? : bool false]
    [uniform-result-ok? : bool false]
    [uniform-i16-ok? : bool false]
    [uniform-u16-ok? : bool false]
    [uniform-i8-ok? : bool false]
    [uniform-u8-ok? : bool false]
    [literal-uniform-ok? : bool false]
    [cast-uniform-ok? : bool false]
    [f64-ok? : bool false]
    [f32-ok? : bool false]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref f64-input i) (cast i : f64))
          (set! (array-ref f32-input i) (cast i : f32))
          (set! (array-ref input-i16 i) (cast i : i16))
          (set! (array-ref input-u16 i) (cast i : u16))
          (set! (array-ref input-i8 i) (cast i : i8))
          (set! (array-ref input-u8 i) (cast i : u8))
          (set! i (+ i 1))))
      (set! out-ok? (fill out n))
      (set! masked-ok? (fill-masked masked n))
      (set! uniform-result-ok? (fill-uniform-result uniform-result n))
      (set! uniform-i16-ok? (fill-uniform-i16 input-i16 uniform-i16 n))
      (set! uniform-u16-ok? (fill-uniform-u16 input-u16 uniform-u16 n))
      (set! uniform-i8-ok? (fill-uniform-i8 input-i8 uniform-i8 n))
      (set! uniform-u8-ok? (fill-uniform-u8 input-u8 uniform-u8 n))
      (set!
        literal-uniform-ok?
        (fill-literal-uniform-result literal-uniform-result n))
      (set! cast-uniform-ok? (fill-cast-uniform-result cast-uniform-result n))
      (call-unit-result n)
      (set! f64-ok? (fill-f64 f64-input f64-out n))
      (set! f32-ok? (fill-f32 f32-input f32-out n))
      (if (and
        (= (fixture.package-answer) 42)
        (= (fixture.package-increment 41) 42)
        (= (fixture.package-unsupported 42) 42)
        (= (fixture.package-unsupported 41) 41)
        (= (fixture-generated.answer) 41)
        (= (package-decl-answer) 40)
        (=
          (unsafe
            (package-unsafe-answer 42))
          42)
        (= (fixture.helper 2 3) 5)
        out-ok?
        masked-ok?
        uniform-result-ok?
        uniform-i16-ok?
        uniform-u16-ok?
        uniform-i8-ok?
        uniform-u8-ok?
        literal-uniform-ok?
        cast-uniform-ok?
        f64-ok?
        f32-ok?)
        42
        1))))