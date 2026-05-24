;; refs #670: first executable scalar f32 slice. Exercises f32 parameters,

;; f32 locals, the f32 `+ - * /` arithmetic operators, an f32 comparison, an

;; f32 return value, contextual f32 float literals, and an `f64 -> f32 -> f64`

;; precision round-trip. Non-literal f64 -> f32 still uses an explicit cast.

;; `main` returns 42 only when every f32 result lands where IEEE-754 binary32

;; arithmetic says it should.

;; f32 parameters + arithmetic + an f32 return.

(define (addf [a : f32] [b : f32]) : f32
  (+ a b))

(define (subf [a : f32] [b : f32]) : f32
  (- a b))

(define (mulf [a : f32] [b : f32]) : f32
  (* a b))

(define (divf [a : f32] [b : f32]) : f32
  (/ a b))

;; f32 comparison through a function boundary.

(define (ltf [a : f32] [b : f32]) : bool
  (< a b))

;; Round-trip an f64 through f32 and back. Narrowing to binary32 then widening

;; back to f64 is exact for values that fit in binary32 (like 2.5).

(define (roundtrip [x : f64]) : f64
  (cast x : f32))

(define (main) : i64
  (let (
    [two : f32 2.0]
    [three : f32 3.0]
    [half : f32 0.5])
    ;; f32 locals and arithmetic: (2 + 3) = 5, (3 - 2) = 1, (2 * 3) = 6,
    ;; (3 / 2) = 1.5.
    (let (
      [sum : f32 (addf two three)]
      [diff : f32 (subf three two)]
      [prod : f32 (mulf two three)]
      [quot : f32 (divf three two)])
      ;; Build the answer from comparisons over the f32 results so the exit
      ;; code only reaches 42 if single-precision codegen is correct.
      (let (
        [a : i64
          (if (ltf diff sum)
            20
            0)]
        ;; 1 < 5  -> 20
        [b : i64
          (if (< prod sum)
            0
            13)]
        ;; 6 < 5 is false -> 13
        [c : i64
          (if (< quot two)
            9
            0)]
        ;; 1.5 < 2 -> 9
        ;; Round-trip an exactly-representable f64 (2.5) through f32 and
        ;; require exact equality on return. A correct round-trip is neither
        ;; less than nor greater than 2.5, so `rt` stays 0; any drift breaks
        ;; the exit code.
        [rt : i64
          (if (< (roundtrip 2.5) 2.5)
            100
            (if (< 2.5 (roundtrip 2.5))
              100
              0))])
        (+ rt (+ a (+ b c)))))))