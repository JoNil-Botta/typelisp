;; Integer-bit oracle for IEEE comparisons. Every operator executes even when
;; an earlier result is wrong; counters also witness one evaluation per operand.
(import stdlib.iterator)
(import stdlib.math)

(define eval-count : i64
  0)
(define inverse-bits : i64
  0)

(define (expected-mask [left : u64] [right : u64] [sign : u64] [infinity : u64]) : i64
  (let
    [magnitude : u64 (- sign 1)]
    [a : u64 (bit-and left magnitude)]
    [b : u64 (bit-and right magnitude)]
    (if (or (> a infinity) (> b infinity))
      2
      (let
        [ka : u64
          (if (= a 0)
            sign
            (if (= (bit-and left sign) 0)
              (+ sign a)
              (- sign a)))]
        [kb : u64
          (if (= b 0)
            sign
            (if (= (bit-and right sign) 0)
              (+ sign b)
              (- sign b)))]
        (+
          (if (= ka kb)
            1
            0)
          (if (!= ka kb)
            2
            0)
          (if (< ka kb)
            4
            0)
          (if (<= ka kb)
            8
            0)
          (if (> ka kb)
            16
            0)
          (if (>= ka kb)
            32
            0))))))

(define (counted-f64 [value : f64]) : f64
  (set! eval-count (+ eval-count 1))
  value)

(define (mask-f64 [a : f64] [b : f64]) : i64
  (+
    (if (= (counted-f64 a) (counted-f64 b))
      1
      0)
    (if (!= (counted-f64 a) (counted-f64 b))
      2
      0)
    (if (< (counted-f64 a) (counted-f64 b))
      4
      0)
    (if (<= (counted-f64 a) (counted-f64 b))
      8
      0)
    (if (> (counted-f64 a) (counted-f64 b))
      16
      0)
    (if (>= (counted-f64 a) (counted-f64 b))
      32
      0)))

(define (inverse-mask-f64 [a : f64] [b : f64])
  (:export-symbol "tl_inverse_mask_f64") : i64
  (set! inverse-bits 0)
  (if (= a b)
    unit
    (+= inverse-bits 1))
  (if (!= a b)
    unit
    (+= inverse-bits 2))
  (if (< a b)
    unit
    (+= inverse-bits 4))
  (if (<= a b)
    unit
    (+= inverse-bits 8))
  (if (> a b)
    unit
    (+= inverse-bits 16))
  (if (>= a b)
    unit
    (+= inverse-bits 32))
  inverse-bits)

;; Recursion prevents inlining so each predicate also uses the bool-return path.
(define (return-f64 [a : f64] [b : f64] [op : i64]) : bool
  (cond
    [(= op 0) (= a b)]
    [(= op 1) (!= a b)]
    [(= op 2) (< a b)]
    [(= op 3) (<= a b)]
    [(= op 4) (> a b)]
    [(= op 5) (>= a b)]
    [else (return-f64 a b (- op 6))]))

(define (check-f64 [a : u64] [b : u64]) : bool
  (let
    [left : f64 (stdlib.math.f64-from-bits a)]
    [right : f64 (stdlib.math.f64-from-bits b)]
    [self-equal : bool
      (<= (bit-and (cast a : u64) 0x7fffffffffffffff) 0x7ff0000000000000)]
    [expected : i64
      (expected-mask
        (cast a : u64)
        (cast b : u64)
        0x8000000000000000
        0x7ff0000000000000)]
    (set! eval-count 0)
    (let
      [actual : i64 (mask-f64 left right)]
      ;; Keep the minimized same-variable regression: optimizers must not
      ;; assume reflexive equality or non-strict ordering for possible NaNs.
      (if (or
        (!= actual expected)
        (!= (inverse-mask-f64 left right) (- 63 expected))
        (!= eval-count 12)
        (!= (= left left) self-equal)
        (!= (!= left left) (not self-equal))
        (< left left)
        (> left left)
        (!= (<= left left) self-equal)
        (!= (>= left left) self-equal))
        false
        (let
          [op : i64 0]
          [ok : bool true]
          (while (< op 6)
            (when
              (!=
                (return-f64 left right op)
                (!= (bit-and expected (shl 1 op)) 0))
              (set! ok false))
            (set! op (+ op 1)))
          ok)))))

(define (counted-f32 [value : f32]) : f32
  (set! eval-count (+ eval-count 1))
  value)

(define (mask-f32 [a : f32] [b : f32]) : i64
  (+
    (if (= (counted-f32 a) (counted-f32 b))
      1
      0)
    (if (!= (counted-f32 a) (counted-f32 b))
      2
      0)
    (if (< (counted-f32 a) (counted-f32 b))
      4
      0)
    (if (<= (counted-f32 a) (counted-f32 b))
      8
      0)
    (if (> (counted-f32 a) (counted-f32 b))
      16
      0)
    (if (>= (counted-f32 a) (counted-f32 b))
      32
      0)))

(define (inverse-mask-f32 [a : f32] [b : f32])
  (:export-symbol "tl_inverse_mask_f32") : i64
  (set! inverse-bits 0)
  (if (= a b)
    unit
    (+= inverse-bits 1))
  (if (!= a b)
    unit
    (+= inverse-bits 2))
  (if (< a b)
    unit
    (+= inverse-bits 4))
  (if (<= a b)
    unit
    (+= inverse-bits 8))
  (if (> a b)
    unit
    (+= inverse-bits 16))
  (if (>= a b)
    unit
    (+= inverse-bits 32))
  inverse-bits)

;; Recursion prevents inlining so each predicate also uses the bool-return path.
(define (return-f32 [a : f32] [b : f32] [op : i64]) : bool
  (cond
    [(= op 0) (= a b)]
    [(= op 1) (!= a b)]
    [(= op 2) (< a b)]
    [(= op 3) (<= a b)]
    [(= op 4) (> a b)]
    [(= op 5) (>= a b)]
    [else (return-f32 a b (- op 6))]))

(define (check-f32 [a : u32] [b : u32]) : bool
  (let
    [left : f32 (stdlib.math.f32-from-bits a)]
    [right : f32 (stdlib.math.f32-from-bits b)]
    [self-equal : bool (<= (bit-and (cast a : u64) 0x7fffffff) 0x7f800000)]
    [expected : i64
      (expected-mask (cast a : u64) (cast b : u64) 0x80000000 0x7f800000)]
    (set! eval-count 0)
    (let
      [actual : i64 (mask-f32 left right)]
      ;; Keep the minimized same-variable regression: optimizers must not
      ;; assume reflexive equality or non-strict ordering for possible NaNs.
      (if (or
        (!= actual expected)
        (!= (inverse-mask-f32 left right) (- 63 expected))
        (!= eval-count 12)
        (!= (= left left) self-equal)
        (!= (!= left left) (not self-equal))
        (< left left)
        (> left left)
        (!= (<= left left) self-equal)
        (!= (>= left left) self-equal))
        false
        (let
          [op : i64 0]
          [ok : bool true]
          (while (< op 6)
            (when
              (!=
                (return-f32 left right op)
                (!= (bit-and expected (shl 1 op)) 0))
              (set! ok false))
            (set! op (+ op 1)))
          ok)))))

;; The runtime divisor is read from a table so the oracle always divides.
;; Check both signs and the limiting exponents against IEEE division bitwise.
(define (literal-div-f64 [x : f64] [kind : i64])
  (:export-symbol "tl_literal_div_f64") : f64
  (cond
    [(= kind 0) (/ (* 1.0 x) 1.0)]
    [(= kind 1) (/ x 2.0)]
    [(= kind 2) (/ x -2.0)]
    [(= kind 3) (/ x 4.49423283715579e+307)]
    [(= kind 4) (/ x -2.2250738585072014e-308)]
    [(= kind 5) (/ x 8.98846567431158e+307)]
    [(= kind 6) (/ x 1.1125369292536007e-308)]
    [else (/ x 3.0)]))

(define (check-division-f64 [bits : u64]) : bool
  (let
    [x : f64 (math.f64-from-bits bits)]
    [divisors : (Array u64 8)
      (array
        (cast 0x3ff0000000000000 : u64)
        0x4000000000000000
        0xc000000000000000
        0x7fd0000000000000
        0x8010000000000000
        0x7fe0000000000000
        0x8000000000000
        0x4008000000000000)]
    (for [kind (iterator.range 0 8)]
      (let
        [divisor : f64 (math.f64-from-bits (array-ref divisors kind))]
        (when
          (!=
            (math.f64-to-bits (literal-div-f64 x kind))
            (math.f64-to-bits (/ x divisor)))
          (return false))))
    true))

(define (literal-div-f32 [x : f32] [kind : i64])
  (:export-symbol "tl_literal_div_f32") : f32
  (cond
    [(= kind 0) (/ (* 1.0 x) 1.0)]
    [(= kind 1) (/ x 2.0)]
    [(= kind 2) (/ x -2.0)]
    [(= kind 3) (/ x 8.507059173023462e+37)]
    [(= kind 4) (/ x -1.1754943508222875e-38)]
    [(= kind 5) (/ x 1.7014118346046923e+38)]
    [(= kind 6) (/ x 5.877471754111438e-39)]
    [else (/ x 3.0)]))

(define (check-division-f32 [bits : u32]) : bool
  (let
    [x : f32 (math.f32-from-bits bits)]
    [divisors : (Array u32 8)
      (array
        (cast 0x3f800000 : u32)
        0x40000000
        0xc0000000
        0x7e800000
        0x80800000
        0x7f000000
        0x400000
        0x40400000)]
    (for [kind (iterator.range 0 8)]
      (let
        [divisor : f32 (math.f32-from-bits (array-ref divisors kind))]
        (when
          (!=
            (math.f32-to-bits (literal-div-f32 x kind))
            (math.f32-to-bits (/ x divisor)))
          (return false))))
    true))

(define (main) : i64
  (let
    ;; Signed zeros, subnormals, normal boundaries, ordered values, infinities,
    ;; quiet/signaling NaNs with distinct signs and payloads.
    [wide : (Array u64 20)
      (array
        (cast 0x0000000000000000 : u64)
        0x8000000000000000
        0x0000000000000001
        0x8000000000000001
        0x000fffffffffffff
        0x800fffffffffffff
        0x0010000000000000
        0x8010000000000000
        0x3ff0000000000000
        0xbff0000000000000
        0x7fefffffffffffff
        0xffefffffffffffff
        0x7ff0000000000000
        0xfff0000000000000
        0x7ff8000000000001
        0xfff8000000000042
        0x7ff0000000000001
        0xfff0000000000042
        0x4000000000000000
        0xc000000000000000)]
    [narrow : (Array u32 20)
      (array
        (cast 0x00000000 : u32)
        0x80000000
        0x00000001
        0x80000001
        0x007fffff
        0x807fffff
        0x00800000
        0x80800000
        0x3f800000
        0xbf800000
        0x7f7fffff
        0xff7fffff
        0x7f800000
        0xff800000
        0x7fc00001
        0xffc00042
        0x7f800001
        0xff800042
        0x40000000
        0xc0000000)]
    [i : i64 0]
    [failed : i64 0]
    (while (< i 20)
      (let
        [j : i64 0]
        (when (not (check-division-f64 (array-ref wide i))) (return 3))
        (when (not (check-division-f32 (array-ref narrow i))) (return 4))
        (while (< j 20)
          (when
            (not (check-f64 (array-ref wide i) (array-ref wide j)))
            (set! failed 1))
          (when
            (not (check-f32 (array-ref narrow i) (array-ref narrow j)))
            (set! failed 2))
          (set! j (+ j 1))))
      (set! i (+ i 1)))
    failed))