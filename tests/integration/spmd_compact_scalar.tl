; Scalar-reference `spmd-compact` semantics in every backend mode (#7083).
; The SPMD gate compiles and runs this fixture in scalar, AVX2, and AVX-512
; modes; compact deliberately keeps this source-ordered scalar behavior in all
; three.
(define (ordered-bound!
  [state : (&mut state (__tl_dyn-array i64))]
  [expected : i64]
  [value : i64]) : i64
  (if (= (array-ref state 0) expected)
    (begin
      (set! (array-ref state 0) (+ expected 1))
      value)
    (- 0 1000)))

(define (write-compact-slot!
  [out : (&mut out (__tl_dyn-array i64))]
  [slot : i64]
  [offset : i64]
  [value : i64]) : unit
  (set! (array-ref out (+ slot offset)) value))

(define (case-empty) : bool
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (set! (array-ref out 0) 91)
      (and
        (=
          (spmd-compact
            ([i : i64 7 7] [slot : i64 12])
            (= (array-ref out i) 0)
            (set! (array-ref out slot) i))
          12)
        (= (array-ref out 0) 91)))))

(define (case-none) : bool
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    (begin
      (set! (array-ref out 0) 17)
      (and
        (=
          (spmd-compact
            ([i : i64 0 65] [slot : i64 3])
            false
            (set! (array-ref out slot) i))
          3)
        (= (array-ref out 0) 17)))))

(define (case-max-cursor-unselected) : bool
  (=
    (spmd-compact ([i : i64 0 9] [slot : i64 9223372036854775807]) false unit)
    9223372036854775807))

(define (case-some-multigang-tail) : bool
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 40)]
    [cursor : i64
      (spmd-compact
        ([i : i64 2 67] [slot : i64 3])
        (= (% i 3) 1)
        (set! (array-ref out slot) i))]
    (and
      (= cursor 24)
      (= (array-ref out 3) 4)
      (= (array-ref out 4) 7)
      (= (array-ref out 22) 61)
      (= (array-ref out 23) 64)
      (= (array-ref out 24) 0))))

(define (case-all) : bool
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 20)]
    [cursor : i64
      (spmd-compact
        ([i : i64 3 12] [slot : i64 5])
        true
        (set! (array-ref out slot) i))]
    (and
      (= cursor 14)
      (= (array-ref out 5) 3)
      (= (array-ref out 9) 7)
      (= (array-ref out 13) 11)
      (= (array-ref out 14) 0))))

(define (case-evaluation-order-and-affine-slots) : bool
  (let
    [state : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [exact : (__tl_dyn-array i64) (__tl_make-array i64 20)]
    [plus : (__tl_dyn-array i64) (__tl_make-array i64 20)]
    [commuted : (__tl_dyn-array i64) (__tl_make-array i64 20)]
    [minus : (__tl_dyn-array i64) (__tl_make-array i64 20)]
    [helper : (__tl_dyn-array i64) (__tl_make-array i64 20)]
    [cursor : i64
      (spmd-compact
        ([i
            : i64
            (ordered-bound! (&mut state) 0 2)
            (ordered-bound! (&mut state) 1 9)]
          [slot : i64 (ordered-bound! (&mut state) 2 4)])
        (= (% i 2) 0)
        (begin
          (set! (array-ref exact slot) i)
          (set! (array-ref plus (+ slot 1)) i)
          (set! (array-ref commuted (+ 2 slot)) i)
          (set! (array-ref minus (- slot 1)) i)
          (write-compact-slot! (&mut helper) slot 3 i)))]
    (and
      (= (array-ref state 0) 3)
      (= cursor 8)
      (= (array-ref exact 4) 2)
      (= (array-ref exact 7) 8)
      (= (array-ref plus 5) 2)
      (= (array-ref plus 8) 8)
      (= (array-ref commuted 6) 2)
      (= (array-ref commuted 9) 8)
      (= (array-ref minus 3) 2)
      (= (array-ref minus 6) 8)
      (= (array-ref helper 7) 2)
      (= (array-ref helper 10) 8))))

(define (main) : i64
  (cond
    [(not (case-empty)) 1]
    [(not (case-none)) 2]
    [(not (case-max-cursor-unselected)) 3]
    [(not (case-some-multigang-tail)) 4]
    [(not (case-all)) 5]
    [(not (case-evaluation-order-and-affine-slots)) 6]
    [else 42]))