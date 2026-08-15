(import stdlib.string)

(define (ssa-handle-inc [value : i64]) : i64
  (+ value 1))

(define (ssa-handle-twice [value : i64]) : i64
  (* value 2))

(define (ssa-handle-first-f32
  [a : f32]
  [_b : f32]
  [_c : f32]
  [_d : f32]
  [_e : f32]
  [_f : f32]
  [_g : f32]
  [_h : f32]
  [_i : f32]) : f32
  a)

(define (ssa-handle-ninth-f32
  [_a : f32]
  [_b : f32]
  [_c : f32]
  [_d : f32]
  [_e : f32]
  [_f : f32]
  [_g : f32]
  [_h : f32]
  [i : f32]) : f32
  i)

(define (ssa-handle-choose-f32x9
  [cond : bool]
  [left : (-> f32 f32 f32 f32 f32 f32 f32 f32 f32 f32)]
  [right : (-> f32 f32 f32 f32 f32 f32 f32 f32 f32 f32)]) : (->
    f32
    f32
    f32
    f32
    f32
    f32
    f32
    f32
    f32
    f32)
  (if cond
    left
    right))

(define (ssa-handle-choose-fn
  [cond : bool]
  [left : (-> i64 i64)]
  [right : (-> i64 i64)]) : (-> i64 i64)
  (let
    [selected : (-> i64 i64) left]
    (begin
      (if cond
        (set! selected right)
        (set! selected left))
      selected)))

;; Swapping both loop-carried function handles makes phi destruction preserve a
;; parallel-copy cycle. Calling both handles after the loop also checks that the
;; widened SSA values keep their indirect-call representation.
(define (ssa-handle-swap-and-call
  [count : i64]
  [first : (-> i64 i64)]
  [second : (-> i64 i64)]) : i64
  (let
    [left : (-> i64 i64) first]
    [right : (-> i64 i64) second]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [old-left : (-> i64 i64) left]
          [old-right : (-> i64 i64) right]
          (begin
            (set! left old-right)
            (set! right old-left)
            (set! index (+ index 1)))))
      (+ (* 10 (left 3)) (right 3)))))

(define (ssa-handle-string-score [cond : bool]) : i64
  (let
    [value : String
      (if cond
        "fixed"
        "ssa")]
    (string.string-length value)))

(define (ssa-handle-array-score [cond : bool]) : i64
  (let
    [value : (Array i64 2)
      (if cond
        (array 19 23)
        (array 20 22))]
    (+ (array-ref value 0) (array-ref value 1))))

(define (ssa-handle-dyn-array-score [cond : bool]) : i64
  (let
    [value : (__tl_dyn-array i64)
      (if cond
        (__tl_make-array 19 23)
        (__tl_make-array 20 22))]
    (+ (array-ref value 0) (array-ref value 1))))

(define (ssa-handle-box-score [cond : bool]) : i64
  (let
    [value : (Box i64)
      (if cond
        (box 42)
        (box 41))]
    (if cond
      (deref value)
      (+ (deref value) 1))))

(define (main) : i64
  (let
    [chosen-true : (-> i64 i64)
      (ssa-handle-choose-fn true ssa-handle-inc ssa-handle-twice)]
    [chosen-false : (-> i64 i64)
      (ssa-handle-choose-fn false ssa-handle-inc ssa-handle-twice)]
    [chosen-f32x9 : (-> f32 f32 f32 f32 f32 f32 f32 f32 f32 f32)
      (ssa-handle-choose-f32x9 true ssa-handle-first-f32 ssa-handle-ninth-f32)]
    (if (and
      (= (chosen-true 3) 6)
      (= (chosen-false 3) 4)
      (= (ssa-handle-swap-and-call 5 ssa-handle-inc ssa-handle-twice) 64)
      (= (ssa-handle-swap-and-call 4 ssa-handle-inc ssa-handle-twice) 46)
      (= (ssa-handle-string-score true) 5)
      (= (ssa-handle-string-score false) 3)
      (= (ssa-handle-array-score true) 42)
      (= (ssa-handle-array-score false) 42)
      (= (ssa-handle-dyn-array-score true) 42)
      (= (ssa-handle-dyn-array-score false) 42)
      (= (ssa-handle-box-score true) 42)
      (= (ssa-handle-box-score false) 42)
      (= (chosen-f32x9 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0) 1.0))
      42
      1)))