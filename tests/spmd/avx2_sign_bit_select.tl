;; AVX2 64-bit sign-bit blend (`vpsllq` + `vblendvpd` / direct `vblendvpd` for k=63)
;; and select-add/sub factoring (`select(m, x + a, x + b)` -> `x + select(m, a, b)`,
;; `select(m, x + r, x - r)` -> `x + select(m, r, -r)`).
;; Verifies exact scalar == AVX2 == AVX-512 parity across k=0, k=1, k=63,
;; all four single-bit comparison polarities, u64 lanes, edge bit patterns,
;; and non-multiple-of-4 tail lengths. Exits 42 on pass.
(define (test-bit0-factor
  [a : (& a (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]
  [r : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (array-ref a i)]
      (set!
        (array-ref out i)
        (if (= (bit-and x 1) 1)
          (+ x r)
          (- x r))))))

(define (test-bit0-ne0
  [a : (& a (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]
  [r : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (array-ref a i)]
      (set!
        (array-ref out i)
        (if (!= (bit-and x 1) 0)
          (- x r)
          (+ x r))))))

(define (test-bit1-eq0
  [a : (& a (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]
  [c1 : i64]
  [c2 : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (array-ref a i)]
      (set!
        (array-ref out i)
        (if (= (bit-and x 2) 0)
          (+ x c1)
          (+ x c2))))))

(define (test-bit1-ne2
  [a : (& a (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]
  [c1 : i64]
  [c2 : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : i64 (array-ref a i)]
      (set!
        (array-ref out i)
        (if (!= (bit-and x 2) 2)
          (- x c1)
          (- x c2))))))

(define (test-bit63-direct
  [a : (& a (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]
  [r : i64]) : unit
  (let
    [min64 : i64 (- -9223372036854775807 1)]
    (foreach
      ([i : i64 0 n])
      (let
        [x : i64 (array-ref a i)]
        (set!
          (array-ref out i)
          (if (!= (bit-and x min64) 0)
            (+ x r)
            (- x r)))))))

(define (test-bit63-eq0
  [a : (& a (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]
  [c1 : i64]
  [c2 : i64]) : unit
  (let
    [min64 : i64 (- -9223372036854775807 1)]
    (foreach
      ([i : i64 0 n])
      (let
        [x : i64 (array-ref a i)]
        (set!
          (array-ref out i)
          (if (= (bit-and x min64) 0)
            c1
            c2))))))

(define (test-u64-bit0-and-bit63
  [a : (& a (__tl_dyn-array u64))]
  [out0 : (&mut out0 (__tl_dyn-array u64))]
  [out63 : (&mut out63 (__tl_dyn-array u64))]
  [n : i64]
  [r : u64]) : unit
  (let
    [min64 : i64 (- -9223372036854775807 1)]
    [bit63 : u64 (cast min64 : u64)]
    (foreach
      ([i : i64 0 n])
      (let
        [x : u64 (array-ref a i)]
        (set!
          (array-ref out0 i)
          (if (= (bit-and x (cast 1 : u64)) (cast 1 : u64))
            (+ x r)
            (- x r)))
        (set!
          (array-ref out63 i)
          (if (!= (bit-and x bit63) (cast 0 : u64))
            (+ x r)
            (- x r)))))))

(define (main) : i64
  (let
    [n : i64 35]
    [min64 : i64 (- -9223372036854775807 1)]
    [a : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [ua : (__tl_dyn-array u64) (__tl_make-array u64 n)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [uout0 : (__tl_dyn-array u64) (__tl_make-array u64 n)]
    [uout63 : (__tl_dyn-array u64) (__tl_make-array u64 n)]
    [i : i64 0]
    (while (< i n)
      (let
        [v : i64
          (cond
            [(= i 0) 0]
            [(= i 1) 1]
            [(= i 2) 2]
            [(= i 3) 3]
            [(= i 4) -1]
            [(= i 5) -2]
            [(= i 6) -3]
            [(= i 7) min64]
            [(= i 8) 9223372036854775807]
            [(= i 9) (+ min64 1)]
            [(= i 10) (+ min64 2)]
            [(= i 11) (+ min64 3)]
            [else
              (+
                (* i 17)
                (if (= (% i 3) 0)
                  min64
                  0))])]
        (set! (array-ref a i) v)
        (set! (array-ref ua i) (cast v : u64)))
      (+= i 1))
    (test-bit0-factor (& a) (&mut out) n 13)
    (set! i 0)
    (while (< i n)
      (let
        [x : i64 (array-ref a i)]
        [want : i64
          (if (= (bit-and x 1) 1)
            (+ x 13)
            (- x 13))]
        (when (!= (array-ref out i) want) (return 1)))
      (+= i 1))
    (test-bit0-ne0 (& a) (&mut out) n 19)
    (set! i 0)
    (while (< i n)
      (let
        [x : i64 (array-ref a i)]
        [want : i64
          (if (!= (bit-and x 1) 0)
            (- x 19)
            (+ x 19))]
        (when (!= (array-ref out i) want) (return 2)))
      (+= i 1))
    (test-bit1-eq0 (& a) (&mut out) n 7 -11)
    (set! i 0)
    (while (< i n)
      (let
        [x : i64 (array-ref a i)]
        [want : i64
          (if (= (bit-and x 2) 0)
            (+ x 7)
            (+ x -11))]
        (when (!= (array-ref out i) want) (return 3)))
      (+= i 1))
    (test-bit1-ne2 (& a) (&mut out) n 5 23)
    (set! i 0)
    (while (< i n)
      (let
        [x : i64 (array-ref a i)]
        [want : i64
          (if (!= (bit-and x 2) 2)
            (- x 5)
            (- x 23))]
        (when (!= (array-ref out i) want) (return 4)))
      (+= i 1))
    (test-bit63-direct (& a) (&mut out) n 29)
    (set! i 0)
    (while (< i n)
      (let
        [x : i64 (array-ref a i)]
        [want : i64
          (if (!= (bit-and x min64) 0)
            (+ x 29)
            (- x 29))]
        (when (!= (array-ref out i) want) (return 5)))
      (+= i 1))
    (test-bit63-eq0 (& a) (&mut out) n 101 -202)
    (set! i 0)
    (while (< i n)
      (let
        [x : i64 (array-ref a i)]
        [want : i64
          (if (= (bit-and x min64) 0)
            101
            -202)]
        (when (!= (array-ref out i) want) (return 6)))
      (+= i 1))
    (test-u64-bit0-and-bit63
      (& ua)
      (&mut uout0)
      (&mut uout63)
      n
      (cast 31 : u64))
    (set! i 0)
    (while (< i n)
      (let
        [x : u64 (array-ref ua i)]
        [want0 : u64
          (if (= (bit-and x (cast 1 : u64)) (cast 1 : u64))
            (+ x (cast 31 : u64))
            (- x (cast 31 : u64)))]
        [want63 : u64
          (if (!= (bit-and x (cast min64 : u64)) (cast 0 : u64))
            (+ x (cast 31 : u64))
            (- x (cast 31 : u64)))]
        (when (!= (array-ref uout0 i) want0) (return 7))
        (when (!= (array-ref uout63 i) want63) (return 8)))
      (+= i 1))
    42))