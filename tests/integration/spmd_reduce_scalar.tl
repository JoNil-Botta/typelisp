; Scalar reference lowering for `spmd-reduce` (#499). Each reduction is checked
; against a hand-written while/set! loop (the scalar oracle) and against
; known constants, across reduction kinds, result types, and range lengths
; (0, < a likely lane width, exactly one lane, and a non-divisible tail).
; `main` returns 42 only when every case agrees.
; Compatibility exception for #3772: spmd-reduce value expressions still use
; bare `array-ref` so the purity checker sees the compiler array-read AST.
(import stdlib.vector)
(import stdlib.math)
(import (vector.vector i64) as i64v)
(import (vector.vector i32) as i32v)
(import (vector.vector f64) as f64v)
(import (vector.vector f32) as f32v)
(import (vector.vector bool) as boolv)
(import "spmd_vec_support.tl" module spmd.vec.support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)
(import (spmdv.zeroed i32 (cast 0 : i32)) as i32z)
(import (spmdv.zeroed f64 (cast 0 : f64)) as f64z)
(import (spmdv.zeroed f32 (cast 0 : f32)) as f32z)
(import (spmdv.zeroed bool false) as boolz)

(define (manual-sum [xs : (& xs i64v.Vec)] [n : i64]) : i64
  (let
    [xs-slots (i64v.slots xs)]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref xs-slots i)))
          (set! i (+ i 1))))
      acc)))

(define (reduce-sum [xs : (& xs i64v.Vec)] [n : i64]) : i64
  (let
    [xs-slots (i64v.slots xs)]
    (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs-slots i))))

(define (manual-max [xs : (& xs i64v.Vec)] [n : i64] [seed : i64]) : i64
  (let
    [xs-slots (i64v.slots xs)]
    [acc : i64 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (> (array-ref xs-slots i) acc)
            (set! acc (array-ref xs-slots i))
            (set! acc acc))
          (set! i (+ i 1))))
      acc)))

(define (reduce-max [xs : (& xs i64v.Vec)] [n : i64] [seed : i64]) : i64
  (let
    [xs-slots (i64v.slots xs)]
    (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs-slots i))))

(define (reduce-min [xs : (& xs i64v.Vec)] [n : i64] [seed : i64]) : i64
  (let
    [xs-slots (i64v.slots xs)]
    (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs-slots i))))

(define (reduce-all-bool [values : (& values boolv.Vec)] [n : i64]) : bool
  (let
    [values-slots (boolv.slots values)]
    (spmd-reduce all ([i : i64 0 n]) true (array-ref values-slots i))))

(define (reduce-any-bool [values : (& values boolv.Vec)] [n : i64]) : bool
  (let
    [values-slots (boolv.slots values)]
    (spmd-reduce any ([i : i64 0 n]) false (array-ref values-slots i))))

; f64 sum over an array of 1.0..n.
(define (reduce-sum-f64 [fs : (& fs f64v.Vec)] [n : i64]) : f64
  (let
    [fs-slots (f64v.slots fs)]
    (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref fs-slots i))))

(define (f32-from-bits [bits : u32]) : f32
  (math.f32-from-bits bits))

(define (f32-bits [value : f32]) : u32
  (math.f32-to-bits value))

(define (manual-sum-f32 [values : (& values f32v.Vec)] [n : i64] [seed : f32]) : f32
  (let
    [values-slots (f32v.slots values)]
    [acc : f32 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref values-slots i)))
          (set! i (+ i 1))))
      acc)))

(define (reduce-sum-f32 [values : (& values f32v.Vec)] [n : i64] [seed : f32]) : f32
  (let
    [values-slots (f32v.slots values)]
    (spmd-reduce sum ([i : i64 0 n]) seed (array-ref values-slots i))))

; i32 sum.
(define (reduce-sum-i32 [gs : (& gs i32v.Vec)] [n : i64]) : i32
  (let
    [gs-slots (i32v.slots gs)]
    (spmd-reduce sum ([i : i64 0 n]) (cast 0 : i32) (array-ref gs-slots i))))

(define (reduce-max-i32 [gs : (& gs i32v.Vec)] [n : i64] [seed : i32]) : i32
  (let
    [gs-slots (i32v.slots gs)]
    (spmd-reduce max ([i : i64 0 n]) seed (array-ref gs-slots i))))

(define (reduce-min-i32 [gs : (& gs i32v.Vec)] [n : i64] [seed : i32]) : i32
  (let
    [gs-slots (i32v.slots gs)]
    (spmd-reduce min ([i : i64 0 n]) seed (array-ref gs-slots i))))

; bool: are all elements positive? is any element zero?
(define (reduce-all-pos [xs : (& xs i64v.Vec)] [n : i64]) : bool
  (let
    [xs-slots (i64v.slots xs)]
    (spmd-reduce all ([i : i64 0 n]) true (> (array-ref xs-slots i) 0))))

(define (reduce-any-zero [xs : (& xs i64v.Vec)] [n : i64]) : bool
  (let
    [xs-slots (i64v.slots xs)]
    (spmd-reduce any ([i : i64 0 n]) false (= (array-ref xs-slots i) 0))))

(define (fill-i64 [xs : (&mut xs i64v.Vec)] [n : i64]) : unit
  (let
    [xs-slots (i64v.slots-mut xs)]
    (foreach ([i : i64 0 n]) (array-set! xs-slots i (+ i 1)))))

; Float casts are not supported yet, so seed the f64 array with literals.
(define (fill-f64 [fs : (&mut fs f64v.Vec)]) : unit
  (let
    [fs-slots (f64v.slots-mut fs)]
    (begin
      (array-set! fs-slots 0 1.0)
      (array-set! fs-slots 1 2.0)
      (array-set! fs-slots 2 3.0)
      (array-set! fs-slots 3 4.0)
      (array-set! fs-slots 4 5.0))))

(define (fill-f32 [values : (&mut values f32v.Vec)] [n : i64]) : unit
  (let
    [values-slots (f32v.slots-mut values)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! values-slots i (cast (+ i 1) : f32))
          (set! i (+ i 1))))
      ; Include a negative lane while keeping every value and partial sum
      ; exactly representable in binary32.
      (array-set! values-slots 1 (cast -2.0 : f32)))))

(define (fill-f32-negative-zero [values : (&mut values f32v.Vec)] [n : i64]) : unit
  (let
    [values-slots (f32v.slots-mut values)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! values-slots i (cast -0.0 : f32))
        (set! i (+ i 1))))))

(define (fill-f32-overflow [values : (&mut values f32v.Vec)] [n : i64]) : unit
  (let
    [values-slots (f32v.slots-mut values)]
    [i : i64 0]
    [max-finite : f32 (f32-from-bits (cast 0x7f7fffff : u32))]
    (begin
      (while (< i n)
        (begin
          (array-set! values-slots i (cast 0.0 : f32))
          (set! i (+ i 1))))
      (array-set! values-slots 0 max-finite)
      (array-set! values-slots 1 max-finite))))

(define (fill-i32 [gs : (&mut gs i32v.Vec)] [n : i64]) : unit
  (let
    [gs-slots (i32v.slots-mut gs)]
    (foreach ([i : i64 0 n]) (array-set! gs-slots i (cast (+ i 1) : i32)))))

(define (fill-signed-i32 [hs : (&mut hs i32v.Vec)]) : unit
  (let
    [hs-slots (i32v.slots-mut hs)]
    (begin
      (array-set! hs-slots 0 (cast 3 : i32))
      (array-set! hs-slots 1 (cast (- 0 7) : i32))
      (array-set! hs-slots 2 (cast 12 : i32))
      (array-set! hs-slots 3 (cast (- 0 1) : i32))
      (array-set! hs-slots 4 (cast 0 : i32))
      (array-set! hs-slots 5 (cast 5 : i32))
      (array-set! hs-slots 6 (cast (- 0 9) : i32))
      (array-set! hs-slots 7 (cast 8 : i32))
      (array-set! hs-slots 8 (cast (- 0 4) : i32))
      (array-set! hs-slots 9 (cast 6 : i32))
      (array-set! hs-slots 10 (cast (- 0 20) : i32)))))

(define (fill-signed-i64 [values : (&mut values i64v.Vec)]) : unit
  (let
    [values-slots (i64v.slots-mut values)]
    (begin
      (array-set! values-slots 0 3)
      (array-set! values-slots 1 -7)
      (array-set! values-slots 2 12)
      (array-set! values-slots 3 -1)
      (array-set! values-slots 4 0)
      (array-set! values-slots 5 40)
      (array-set! values-slots 6 -20)
      (array-set! values-slots 7 8)
      (array-set! values-slots 8 -4))))

(define (fill-bool [values : (&mut values boolv.Vec)] [n : i64] [value : bool]) : unit
  (let
    [values-slots (boolv.slots-mut values)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! values-slots i value)
        (set! i (+ i 1))))))

(define (check-base-reductions) : i64
  (let
    [n : i64 5]
    [xs : i64v.Vec (i64z.make 5)]
    [fs : f64v.Vec (f64z.make 5)]
    [n32 : i64 11]
    [gs : i32v.Vec (i32z.make 11)]
    [hs : i32v.Vec (i32z.make 11)]
    (begin
      (fill-i64 (&mut xs) n)
      (fill-f64 (&mut fs))
      (fill-i32 (&mut gs) n32)
      (fill-signed-i32 (&mut hs))
      (let
        [xs-slots (i64v.slots (& xs))]
        (cond
          [(!= (reduce-sum (& xs) n) (manual-sum (& xs) n)) 1]
          [(!= (reduce-sum (& xs) n) 15) 2]
          [(!= (reduce-sum (& xs) 3) 6) 3]
          [(!= (reduce-sum (& xs) 4) 10) 16]
          [(!= (spmd-reduce sum ([i : i64 0 0]) 99 (array-ref xs-slots i)) 99)
            4]
          [(!= (reduce-max (& xs) n 0) (manual-max (& xs) n 0)) 5]
          [(!= (reduce-max (& xs) n 0) 5) 6]
          [(!= (reduce-max (& xs) n 100) 100) 7]
          [(!= (reduce-min (& xs) n 1000) 1) 8]
          [(!= (reduce-min (& xs) n 0) 0) 9]
          [(!= (reduce-sum-i32 (& gs) n) (cast 15 : i32)) 10]
          [(!= (reduce-sum-i32 (& gs) 8) (cast 36 : i32)) 21]
          [(!= (reduce-sum-i32 (& gs) n32) (cast 66 : i32)) 22]
          [(< (reduce-sum-f64 (& fs) n) 14.5) 11]
          [(> (reduce-sum-f64 (& fs) n) 15.5) 12]
          [(not (reduce-all-pos (& xs) n)) 13]
          [(reduce-any-zero (& xs) n) 14]
          [(not
              (spmd-reduce
                all
                ([i : i64 0 0])
                true
                (> (array-ref xs-slots i) 0)))
            15]
          [(!= (reduce-max-i32 (& gs) n (cast 0 : i32)) (cast 5 : i32)) 17]
          [(!= (reduce-max-i32 (& gs) n (cast 100 : i32)) (cast 100 : i32)) 18]
          [(!= (reduce-min-i32 (& gs) n (cast 1000 : i32)) (cast 1 : i32)) 19]
          [(!= (reduce-min-i32 (& gs) n (cast 0 : i32)) (cast 0 : i32)) 20]
          [(!= (reduce-max-i32 (& gs) n32 (cast 0 : i32)) (cast 11 : i32)) 23]
          [(!= (reduce-min-i32 (& gs) n32 (cast 1000 : i32)) (cast 1 : i32)) 24]
          [(!= (reduce-sum-i32 (& hs) 8) (cast 11 : i32)) 25]
          [(!= (reduce-sum-i32 (& hs) n32) (cast (- 0 7) : i32)) 26]
          [(!=
              (reduce-max-i32 (& hs) n32 (cast (- 0 100) : i32))
              (cast 12 : i32))
            27]
          [(!=
              (reduce-min-i32 (& hs) n32 (cast 100 : i32))
              (cast (- 0 20) : i32))
            28]
          [else 0])))))

(define (check-f32-reductions) : i64
  (let
    [values : f32v.Vec (f32z.make 19)]
    [zeros : f32v.Vec (f32z.make 16)]
    [overflow : f32v.Vec (f32z.make 16)]
    [pos-zero : f32 (cast 0.0 : f32)]
    [neg-zero : f32 (cast -0.0 : f32)]
    (begin
      (fill-f32 (&mut values) 19)
      (fill-f32-negative-zero (&mut zeros) 16)
      (fill-f32-overflow (&mut overflow) 16)
      (cond
        [(!=
            (f32-bits (reduce-sum-f32 (& values) 0 neg-zero))
            (cast 0x80000000 : u32))
          29]
        [(!= (reduce-sum-f32 (& values) 3 pos-zero) (cast 2.0 : f32)) 30]
        [(!= (reduce-sum-f32 (& values) 8 pos-zero) (cast 32.0 : f32)) 31]
        [(!= (reduce-sum-f32 (& values) 16 pos-zero) (cast 132.0 : f32)) 32]
        [(!= (reduce-sum-f32 (& values) 19 pos-zero) (cast 186.0 : f32)) 33]
        [(!=
            (reduce-sum-f32 (& values) 19 pos-zero)
            (manual-sum-f32 (& values) 19 pos-zero))
          34]
        [(!=
            (f32-bits (reduce-sum-f32 (& zeros) 16 neg-zero))
            (cast 0x80000000 : u32))
          35]
        [(!=
            (f32-bits (reduce-sum-f32 (& overflow) 16 pos-zero))
            (cast 0x7f800000 : u32))
          36]
        [(!=
            (f32-bits (reduce-sum-f32 (& overflow) 16 pos-zero))
            (f32-bits (manual-sum-f32 (& overflow) 16 pos-zero)))
          37]
        [else 0]))))

(define (check-long-i64-reductions) : i64
  (let
    [long-xs : i64v.Vec (i64z.make 143)]
    [signed-xs : i64v.Vec (i64z.make 9)]
    (begin
      (fill-i64 (&mut long-xs) 143)
      (fill-signed-i64 (&mut signed-xs))
      (cond
        [(!= (reduce-sum (& long-xs) 143) 10296) 38]
        [(!= (reduce-sum (& long-xs) 143) (manual-sum (& long-xs) 143)) 39]
        [(!= (reduce-min (& signed-xs) 0 99) 99) 40]
        [(!= (reduce-max (& signed-xs) 0 -99) -99) 41]
        [(!= (reduce-min (& signed-xs) 3 99) -7) 62]
        [(!= (reduce-max (& signed-xs) 3 -99) 12) 43]
        [(!= (reduce-min (& signed-xs) 4 99) -7) 44]
        [(!= (reduce-max (& signed-xs) 4 -99) 12) 45]
        [(!= (reduce-min (& signed-xs) 9 99) -20) 46]
        [(!= (reduce-max (& signed-xs) 9 -99) 40) 47]
        [(!= (reduce-min (& signed-xs) 9 -100) -100) 48]
        [(!= (reduce-max (& signed-xs) 9 100) 100) 49]
        [else 0]))))

(define (check-bool-reductions) : i64
  (let
    [all-values : boolv.Vec (boolz.make 67)]
    [any-values : boolv.Vec (boolz.make 67)]
    (begin
      (fill-bool (&mut all-values) 67 true)
      (fill-bool (&mut any-values) 67 false)
      (boolv.set (&mut all-values) 40 false)
      (boolv.set (&mut any-values) 40 true)
      (cond
        [(not (reduce-all-bool (& all-values) 0)) 50]
        [(reduce-any-bool (& any-values) 0) 51]
        [(not (reduce-all-bool (& all-values) 3)) 52]
        [(reduce-any-bool (& any-values) 3) 53]
        [(not (reduce-all-bool (& all-values) 32)) 54]
        [(reduce-any-bool (& any-values) 32) 55]
        [(reduce-all-bool (& all-values) 41) 56]
        [(not (reduce-any-bool (& any-values) 41)) 57]
        [(reduce-all-bool (& all-values) 64) 58]
        [(not (reduce-any-bool (& any-values) 64)) 59]
        [(reduce-all-bool (& all-values) 67) 60]
        [(not (reduce-any-bool (& any-values) 67)) 61]
        [else 0]))))

(define (main) : i64
  (let
    [base : i64 (check-base-reductions)]
    [f32 : i64 (check-f32-reductions)]
    [long : i64 (check-long-i64-reductions)]
    [bools : i64 (check-bool-reductions)]
    (cond
      [(!= base 0) base]
      [(!= f32 0) f32]
      [(!= long 0) long]
      [(!= bools 0) bools]
      [else 42])))