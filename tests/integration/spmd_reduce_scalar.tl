; Scalar reference lowering for `spmd-reduce` (#499). Each reduction is checked
; against a hand-written while/set! loop (the scalar oracle) and against
; known constants, across reduction kinds, result types, and range lengths
; (0, < a likely lane width, exactly one lane, and a non-divisible tail).
; `main` returns 42 only when every case agrees.
; Compatibility exception for #3772: spmd-reduce value expressions still use
; bare `array-ref` so the purity checker sees the compiler array-read AST.
(import stdlib.array)

(define (manual-sum [xs : (Array i64)] [n : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref xs i)))
          (set! i (+ i 1))))
      acc)))

(define (reduce-sum [xs : (Array i64)] [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))

(define (manual-max [xs : (Array i64)] [n : i64] [seed : i64]) : i64
  (let
    [acc : i64 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (> (array-ref xs i) acc)
            (set! acc (array-ref xs i))
            (set! acc acc))
          (set! i (+ i 1))))
      acc)))

(define (reduce-max [xs : (Array i64)] [n : i64] [seed : i64]) : i64
  (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))

(define (reduce-min [xs : (Array i64)] [n : i64] [seed : i64]) : i64
  (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))

(define (reduce-all-bool [values : (Array bool)] [n : i64]) : bool
  (spmd-reduce all ([i : i64 0 n]) true (array-ref values i)))

(define (reduce-any-bool [values : (Array bool)] [n : i64]) : bool
  (spmd-reduce any ([i : i64 0 n]) false (array-ref values i)))

; f64 sum over an array of 1.0..n.
(define (reduce-sum-f64 [fs : (Array f64)] [n : i64]) : f64
  (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref fs i)))

(define (f32-from-bits [bits : u32]) : f32
  (let
    [buf : (Array u32) (array.make-array u32 1)]
    (begin
      (array-set! buf 0 bits)
      (unsafe
        (ptr-read (ptr-cast (array-data buf) : (Ptr f32)))))))

(define (f32-bits [value : f32]) : u32
  (let
    [buf : (Array f32) (array.make-array f32 1)]
    (begin
      (array-set! buf 0 value)
      (unsafe
        (ptr-read (ptr-cast (array-data buf) : (Ptr u32)))))))

(define (manual-sum-f32 [values : (Array f32)] [n : i64] [seed : f32]) : f32
  (let
    [acc : f32 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref values i)))
          (set! i (+ i 1))))
      acc)))

(define (reduce-sum-f32 [values : (Array f32)] [n : i64] [seed : f32]) : f32
  (spmd-reduce sum ([i : i64 0 n]) seed (array-ref values i)))

; i32 sum.
(define (reduce-sum-i32 [gs : (Array i32)] [n : i64]) : i32
  (spmd-reduce sum ([i : i64 0 n]) (cast 0 : i32) (array-ref gs i)))

(define (reduce-max-i32 [gs : (Array i32)] [n : i64] [seed : i32]) : i32
  (spmd-reduce max ([i : i64 0 n]) seed (array-ref gs i)))

(define (reduce-min-i32 [gs : (Array i32)] [n : i64] [seed : i32]) : i32
  (spmd-reduce min ([i : i64 0 n]) seed (array-ref gs i)))

; bool: are all elements positive? is any element zero?
(define (reduce-all-pos [xs : (Array i64)] [n : i64]) : bool
  (spmd-reduce all ([i : i64 0 n]) true (> (array-ref xs i) 0)))

(define (reduce-any-zero [xs : (Array i64)] [n : i64]) : bool
  (spmd-reduce any ([i : i64 0 n]) false (= (array-ref xs i) 0)))

(define (fill-i64 [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! xs i (+ i 1))))

; Float casts are not supported yet, so seed the f64 array with literals.
(define (fill-f64 [fs : (Array f64)]) : unit
  (begin
    (array-set! fs 0 1.0)
    (array-set! fs 1 2.0)
    (array-set! fs 2 3.0)
    (array-set! fs 3 4.0)
    (array-set! fs 4 5.0)))

(define (fill-f32 [values : (Array f32)] [n : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! values i (cast (+ i 1) : f32))
          (set! i (+ i 1))))
      ; Include a negative lane while keeping every value and partial sum
      ; exactly representable in binary32.
      (array-set! values 1 (cast -2.0 : f32)))))

(define (fill-f32-negative-zero [values : (Array f32)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! values i (cast -0.0 : f32))
        (set! i (+ i 1))))))

(define (fill-f32-overflow [values : (Array f32)] [n : i64]) : unit
  (let
    [i : i64 0]
    [max-finite : f32 (f32-from-bits (cast 0x7f7fffff : u32))]
    (begin
      (while (< i n)
        (begin
          (array-set! values i (cast 0.0 : f32))
          (set! i (+ i 1))))
      (array-set! values 0 max-finite)
      (array-set! values 1 max-finite))))

(define (fill-i32 [gs : (Array i32)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! gs i (cast (+ i 1) : i32))))

(define (fill-signed-i32 [hs : (Array i32)]) : unit
  (begin
    (array-set! hs 0 (cast 3 : i32))
    (array-set! hs 1 (cast (- 0 7) : i32))
    (array-set! hs 2 (cast 12 : i32))
    (array-set! hs 3 (cast (- 0 1) : i32))
    (array-set! hs 4 (cast 0 : i32))
    (array-set! hs 5 (cast 5 : i32))
    (array-set! hs 6 (cast (- 0 9) : i32))
    (array-set! hs 7 (cast 8 : i32))
    (array-set! hs 8 (cast (- 0 4) : i32))
    (array-set! hs 9 (cast 6 : i32))
    (array-set! hs 10 (cast (- 0 20) : i32))))

(define (fill-signed-i64 [values : (Array i64)]) : unit
  (begin
    (array-set! values 0 3)
    (array-set! values 1 -7)
    (array-set! values 2 12)
    (array-set! values 3 -1)
    (array-set! values 4 0)
    (array-set! values 5 40)
    (array-set! values 6 -20)
    (array-set! values 7 8)
    (array-set! values 8 -4)))

(define (fill-bool [values : (Array bool)] [n : i64] [value : bool]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! values i value)
        (set! i (+ i 1))))))

(define (main) : i64
  (let
    [n : i64 5]
    [xs : (Array i64) (array.make-array i64 5)]
    [fs : (Array f64) (array.make-array f64 5)]
    [n32 : i64 11]
    [gs : (Array i32) (array.make-array i32 11)]
    [hs : (Array i32) (array.make-array i32 11)]
    [signed-xs : (Array i64) (array.make-array i64 9)]
    [all-values : (Array bool) (array.make-array bool 67)]
    [any-values : (Array bool) (array.make-array bool 67)]
    ;; Long enough to enter the x16 vector-gang unroller in both AVX2 and
    ;; AVX-512 modes, with a non-divisible scalar tail.
    [long-xs : (Array i64) (array.make-array i64 143)]
    [f32-values : (Array f32) (array.make-array f32 19)]
    [f32-zeros : (Array f32) (array.make-array f32 16)]
    [f32-overflow : (Array f32) (array.make-array f32 16)]
    [f32-pos-zero : f32 (cast 0.0 : f32)]
    [f32-neg-zero : f32 (cast -0.0 : f32)]
    (begin
      (fill-i64 xs n)
      (fill-f64 fs)
      (fill-i32 gs n32)
      (fill-signed-i32 hs)
      (fill-signed-i64 signed-xs)
      (fill-bool all-values 67 true)
      (fill-bool any-values 67 false)
      (array-set! all-values 40 false)
      (array-set! any-values 40 true)
      (fill-i64 long-xs 143)
      (fill-f32 f32-values 19)
      (fill-f32-negative-zero f32-zeros 16)
      (fill-f32-overflow f32-overflow 16)
      ; xs = [1,2,3,4,5]; gs = [1..11]; hs has mixed signed i32 values;
      ; fs = [1.0..5.0].
      (cond
        [(!= (reduce-sum xs n) (manual-sum xs n)) 1]
        [(!= (reduce-sum xs n) 15) 2]
        [(!= (reduce-sum xs 3) 6) 3]
        [(!= (reduce-sum xs 4) 10) 16]
        [(!= (spmd-reduce sum ([i : i64 0 0]) 99 (array-ref xs i)) 99) 4]
        [(!= (reduce-max xs n 0) (manual-max xs n 0)) 5]
        [(!= (reduce-max xs n 0) 5) 6]
        [(!= (reduce-max xs n 100) 100) 7]
        [(!= (reduce-min xs n 1000) 1) 8]
        [(!= (reduce-min xs n 0) 0) 9]
        [(!= (reduce-sum-i32 gs n) (cast 15 : i32)) 10]
        [(!= (reduce-sum-i32 gs 8) (cast 36 : i32)) 21]
        [(!= (reduce-sum-i32 gs n32) (cast 66 : i32)) 22]
        [(< (reduce-sum-f64 fs n) 14.5) 11]
        [(> (reduce-sum-f64 fs n) 15.5) 12]
        [(not (reduce-all-pos xs n)) 13]
        [(reduce-any-zero xs n) 14]
        [(not (spmd-reduce all ([i : i64 0 0]) true (> (array-ref xs i) 0))) 15]
        [(!= (reduce-max-i32 gs n (cast 0 : i32)) (cast 5 : i32)) 17]
        [(!= (reduce-max-i32 gs n (cast 100 : i32)) (cast 100 : i32)) 18]
        [(!= (reduce-min-i32 gs n (cast 1000 : i32)) (cast 1 : i32)) 19]
        [(!= (reduce-min-i32 gs n (cast 0 : i32)) (cast 0 : i32)) 20]
        [(!= (reduce-max-i32 gs n32 (cast 0 : i32)) (cast 11 : i32)) 23]
        [(!= (reduce-min-i32 gs n32 (cast 1000 : i32)) (cast 1 : i32)) 24]
        [(!= (reduce-sum-i32 hs 8) (cast 11 : i32)) 25]
        [(!= (reduce-sum-i32 hs n32) (cast (- 0 7) : i32)) 26]
        [(!= (reduce-max-i32 hs n32 (cast (- 0 100) : i32)) (cast 12 : i32)) 27]
        [(!= (reduce-min-i32 hs n32 (cast 100 : i32)) (cast (- 0 20) : i32)) 28]
        ; f32: empty, sub-gang, exact AVX2/AVX-512 gangs, a 16+3 tail,
        ; negative data, signed zero, and finite-input overflow.
        [(!=
            (f32-bits (reduce-sum-f32 f32-values 0 f32-neg-zero))
            (cast 0x80000000 : u32))
          29]
        [(!= (reduce-sum-f32 f32-values 3 f32-pos-zero) (cast 2.0 : f32)) 30]
        [(!= (reduce-sum-f32 f32-values 8 f32-pos-zero) (cast 32.0 : f32)) 31]
        [(!= (reduce-sum-f32 f32-values 16 f32-pos-zero) (cast 132.0 : f32)) 32]
        [(!= (reduce-sum-f32 f32-values 19 f32-pos-zero) (cast 186.0 : f32)) 33]
        [(!=
            (reduce-sum-f32 f32-values 19 f32-pos-zero)
            (manual-sum-f32 f32-values 19 f32-pos-zero))
          34]
        [(!=
            (f32-bits (reduce-sum-f32 f32-zeros 16 f32-neg-zero))
            (cast 0x80000000 : u32))
          35]
        [(!=
            (f32-bits (reduce-sum-f32 f32-overflow 16 f32-pos-zero))
            (cast 0x7f800000 : u32))
          36]
        [(!=
            (f32-bits (reduce-sum-f32 f32-overflow 16 f32-pos-zero))
            (f32-bits (manual-sum-f32 f32-overflow 16 f32-pos-zero)))
          37]
        [(!= (reduce-sum long-xs 143) 10296) 38]
        [(!= (reduce-sum long-xs 143) (manual-sum long-xs 143)) 39]
        ; AVX2 i64 min/max: empty, sub-gang, exact gang, and partial tail.
        [(!= (reduce-min signed-xs 0 99) 99) 40]
        [(!= (reduce-max signed-xs 0 -99) -99) 41]
        [(!= (reduce-min signed-xs 3 99) -7) 62]
        [(!= (reduce-max signed-xs 3 -99) 12) 43]
        [(!= (reduce-min signed-xs 4 99) -7) 44]
        [(!= (reduce-max signed-xs 4 -99) 12) 45]
        [(!= (reduce-min signed-xs 9 99) -20) 46]
        [(!= (reduce-max signed-xs 9 -99) 40) 47]
        [(!= (reduce-min signed-xs 9 -100) -100) 48]
        [(!= (reduce-max signed-xs 9 100) 100) 49]
        ; Bool all/any: empty, sub-gang, exact AVX2/AVX-512 gangs, and tail.
        [(not (reduce-all-bool all-values 0)) 50]
        [(reduce-any-bool any-values 0) 51]
        [(not (reduce-all-bool all-values 3)) 52]
        [(reduce-any-bool any-values 3) 53]
        [(not (reduce-all-bool all-values 32)) 54]
        [(reduce-any-bool any-values 32) 55]
        [(reduce-all-bool all-values 41) 56]
        [(not (reduce-any-bool any-values 41)) 57]
        [(reduce-all-bool all-values 64) 58]
        [(not (reduce-any-bool any-values 64)) 59]
        [(reduce-all-bool all-values 67) 60]
        [(not (reduce-any-bool any-values 67)) 61]
        [else 42]))))