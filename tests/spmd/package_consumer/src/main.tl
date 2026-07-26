(module spmd_consumer)

(import stdlib.array)
(import "pkg:fixture/src/lib.tl" module spmd_fixture as fixture)

(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (fixture.helper i 3))))

(define (fill-masked [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 10)
      (if (fixture.positive? i)
        (array-set! out i (fixture.shifted (+ i 1)))
        (array-set! out i 0))
      (array-set! out i 0))))

(define (fill-uniform-result [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (fixture.constant (+ i 1) 7))))

(define (fill-literal-uniform-result [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (fixture.literal-constant (+ i 1)))))

(define (fill-cast-uniform-result [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (fixture.cast-constant (+ i 1)))))

(define (call-unit-result [n : i64]) : unit
  (foreach ([i : i64 0 n]) (fixture.sink (+ i 1))))

(define (fill-f64 [input : (Array f64)] [out : (Array f64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (fixture.add-f64 (array-ref input i) 0.5))))

(define (fill-f32 [input : (Array f32)] [out : (Array f32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (fixture.add-f32 (array-ref input i) 0.25))))

(define (main) : i64
  (let
    [n : i64 13]
    [out : (Array i64) (array.make-array i64 n)]
    [masked : (Array i64) (array.make-array i64 n)]
    [uniform-result : (Array i64) (array.make-array i64 n)]
    [literal-uniform-result : (Array i64) (array.make-array i64 n)]
    [cast-uniform-result : (Array i64) (array.make-array i64 n)]
    [f64-input : (Array f64) (array.make-array f64 n)]
    [f64-out : (Array f64) (array.make-array f64 n)]
    [f32-input : (Array f32) (array.make-array f32 n)]
    [f32-out : (Array f32) (array.make-array f32 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! f64-input i (cast i : f64))
          (array-set! f32-input i (cast i : f32))
          (set! i (+ i 1))))
      (fill out n)
      (fill-masked masked n)
      (fill-uniform-result uniform-result n)
      (fill-literal-uniform-result literal-uniform-result n)
      (fill-cast-uniform-result cast-uniform-result n)
      (call-unit-result n)
      (fill-f64 f64-input f64-out n)
      (fill-f32 f32-input f32-out n)
      (if (and
        (= (fixture.helper 2 3) 5)
        (= (array-ref out 0) 3)
        (= (array-ref out 12) 15)
        (= (array-ref masked 5) 0)
        (= (array-ref masked 6) 12)
        (= (array-ref masked 9) 15)
        (= (array-ref masked 10) 0)
        (= (array-ref uniform-result 0) 7)
        (= (array-ref uniform-result 12) 7)
        (= (array-ref literal-uniform-result 0) 7)
        (= (array-ref literal-uniform-result 12) 7)
        (= (array-ref cast-uniform-result 0) 11)
        (= (array-ref cast-uniform-result 12) 11)
        (= (array-ref f64-out 0) 0.5)
        (= (array-ref f64-out 12) 12.5)
        (= (array-ref f32-out 0) 0.25)
        (= (array-ref f32-out 12) 12.25))
        42
        1))))