;; Integer ranks describe the input table, with both zeros at rank 2 and NaNs
;; outside the ordered ranks. Expected masks never use float comparisons.
;; Selects and masked stores also preserve NaN payloads and either sign of zero.
(import stdlib.math)
(import stdlib.test)

(define (expected-mask [pair : i64]) : i64
  (let
    [ranks : (Array i64 6) (array 2 2 3 1 4 0)]
    [a : i64 (/ pair 10)]
    [b : i64 (% pair 10)]
    (cond
      [(or (>= a 6) (>= b 6)) 2]
      [(= (array-ref ranks a) (array-ref ranks b)) 41]
      [(< (array-ref ranks a) (array-ref ranks b)) 14]
      [else 50])))

(defmacro (comparison-case
  [name : Expr]
  [float-ty : type]
  [bits-ty : type]
  [from-bits : Expr]
  [to-bits : Expr]
  [sign : Expr]
  [infinity : Expr]
  [one : Expr]
  [nan : Expr]) : Decls
  `(define (,name [n : i64] [offset : i64]) : bool
    (let
      [bits : (Array ,bits-ty 10)
        (array
          (cast 0 : ,bits-ty)
          ,sign
          ,one
          (bit-or ,sign ,one)
          ,infinity
          (bit-or ,sign ,infinity)
          ,nan
          (bit-or ,sign ,nan)
          (+ ,infinity 1)
          (bit-or ,sign (+ ,infinity 1)))]
      [left : (__tl_dyn-array ,float-ty) (__tl_make-array ,float-ty 112)]
      [right : (__tl_dyn-array ,float-ty) (__tl_make-array ,float-ty 112)]
      [eq-out : (__tl_dyn-array bool) (__tl_make-array bool 112)]
      [ne-out : (__tl_dyn-array bool) (__tl_make-array bool 112)]
      [lt-out : (__tl_dyn-array bool) (__tl_make-array bool 112)]
      [le-out : (__tl_dyn-array bool) (__tl_make-array bool 112)]
      [gt-out : (__tl_dyn-array bool) (__tl_make-array bool 112)]
      [ge-out : (__tl_dyn-array bool) (__tl_make-array bool 112)]
      [selected : (__tl_dyn-array ,float-ty) (__tl_make-array ,float-ty 112)]
      [masked : (__tl_dyn-array ,float-ty) (__tl_make-array ,float-ty 112)]
      [i : i64 0]
      [ok : bool true]
      (while (< i 112)
        (let
          [pair : i64 (% (+ i offset) 100)]
          (set! (array-ref left i) (,from-bits (array-ref bits (/ pair 10))))
          (set! (array-ref right i) (,from-bits (array-ref bits (% pair 10)))))
        (set! (array-ref eq-out i) true)
        (set! (array-ref ne-out i) true)
        (set! (array-ref lt-out i) true)
        (set! (array-ref le-out i) true)
        (set! (array-ref gt-out i) true)
        (set! (array-ref ge-out i) true)
        (set! (array-ref selected i) (,from-bits ,nan))
        (set! (array-ref masked i) (,from-bits ,nan))
        (set! i (+ i 1)))
      (foreach
        ([j : i64 0 n])
        (begin
          (set! (array-ref eq-out j) (= (array-ref left j) (array-ref right j)))
          (set!
            (array-ref ne-out j)
            (!= (array-ref left j) (array-ref right j)))
          (set! (array-ref lt-out j) (< (array-ref left j) (array-ref right j)))
          (set!
            (array-ref le-out j)
            (<= (array-ref left j) (array-ref right j)))
          (set! (array-ref gt-out j) (> (array-ref left j) (array-ref right j)))
          (set!
            (array-ref ge-out j)
            (>= (array-ref left j) (array-ref right j)))
          (set!
            (array-ref selected j)
            (if (> (array-ref left j) (array-ref right j))
              (array-ref left j)
              (array-ref right j)))))
      (foreach
        ([j : i64 0 n])
        (if (>= (array-ref left j) (array-ref right j))
          (set!
            (array-ref masked j)
            (if (> (array-ref left j) (array-ref right j))
              (array-ref left j)
              (array-ref right j)))
          (begin)))
      (set! i 0)
      (while (< i 112)
        (let
          [a : ,bits-ty (,to-bits (array-ref left i))]
          [b : ,bits-ty (,to-bits (array-ref right i))]
          [mask : i64 (expected-mask (% (+ i offset) 100))]
          [active : bool (< i n)]
          [chosen : ,bits-ty
            (if (!= (bit-and mask 16) 0)
              a
              b)]
          (unless
            (and
              (= (array-ref eq-out i) (or (not active) (!= (bit-and mask 1) 0)))
              (= (array-ref ne-out i) (or (not active) (!= (bit-and mask 2) 0)))
              (= (array-ref lt-out i) (or (not active) (!= (bit-and mask 4) 0)))
              (= (array-ref le-out i) (or (not active) (!= (bit-and mask 8) 0)))
              (=
                (array-ref gt-out i)
                (or (not active) (!= (bit-and mask 16) 0)))
              (=
                (array-ref ge-out i)
                (or (not active) (!= (bit-and mask 32) 0)))
              (=
                (,to-bits (array-ref selected i))
                (if active
                  chosen
                  ,nan))
              (=
                (,to-bits (array-ref masked i))
                (if (and active (!= (bit-and mask 32) 0))
                  chosen
                  ,nan)))
            (set! ok false)))
        (set! i (+ i 1)))
      ok)))

(comparison-case
  check-f64
  f64
  u64
  math.f64-from-bits
  math.f64-to-bits
  0x8000000000000000
  0x7ff0000000000000
  0x3ff0000000000000
  0x7ff8000000000042)

(comparison-case
  check-f32
  f32
  u32
  math.f32-from-bits
  math.f32-to-bits
  0x80000000
  0x7f800000
  0x3f800000
  0x7fc00042)

(define (comparison-matrix) : bool
  (let
    [lengths : (Array i64 7) (array 0 1 4 8 16 19 101)]
    [l : i64 0]
    [ok : bool true]
    (while (< l 7)
      (let
        [offset : i64 0]
        (while (< offset 100)
          (unless (check-f64 (array-ref lengths l) offset) (set! ok false))
          (unless (check-f32 (array-ref lengths l) offset) (set! ok false))
          (set! offset (+ offset 1))))
      (set! l (+ l 1)))
    ok))

(define (main) : i64
  (if (comparison-matrix)
    42
    1))

(test
  packed-floating-comparisons
  (test.assert-true (comparison-matrix) "packed float comparison matrix"))