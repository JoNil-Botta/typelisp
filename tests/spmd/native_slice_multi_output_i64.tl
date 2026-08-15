;; Focused native-Slice multi-output map. Each straight-line result expression
;; reads both source slices at the same varying index, so lowering emits the
;; duplicate data/length extraction and source-load shape optimized by #6475.
(define (map-two-outputs
  [a : (& a (Slice i64))]
  [b : (& b (Slice i64))]
  [sums : (&mut sums (Slice i64))]
  [differences : (&mut differences (Slice i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (set! (array-ref sums i) (+ (array-ref a i) (array-ref b i)))
      (set! (array-ref differences i) (- (array-ref a i) (array-ref b i))))))

(define (outputs-ok?
  [sums : (&mut sums (Slice i64))]
  [differences : (&mut differences (Slice i64))]
  [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i n))
        (begin
          (if (and
            (= (array-ref sums i) (+ (* i 2) 105))
            (= (array-ref differences i) -101))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (let
    [a : (Array i64 24)
      (array 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24)]
    [b : (Array i64 24)
      (array
        101
        102
        103
        104
        105
        106
        107
        108
        109
        110
        111
        112
        113
        114
        115
        116
        117
        118
        119
        120
        121
        122
        123
        124)]
    [sum-storage : (Array i64 24)
      (array
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777)]
    [difference-storage : (Array i64 24)
      (array
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777
        -777)]
    [n : i64 19]
    [a-view : (& a (Slice i64)) (slice-view a 1 n)]
    [b-view : (& b (Slice i64)) (slice-view b 2 n)]
    [ok : bool
      (let
        [sum-view : (&mut sum-storage (Slice i64))
          (slice-mut-view sum-storage 2 n)]
        [difference-view : (&mut difference-storage (Slice i64))
          (slice-mut-view difference-storage 3 n)]
        (begin
          (map-two-outputs a-view b-view sum-view difference-view n)
          (outputs-ok? sum-view difference-view n)))]
    (if (and
      ok
      (= (array-ref sum-storage 0) -777)
      (= (array-ref sum-storage 1) -777)
      (= (array-ref sum-storage 21) -777)
      (= (array-ref sum-storage 23) -777)
      (= (array-ref difference-storage 0) -777)
      (= (array-ref difference-storage 2) -777)
      (= (array-ref difference-storage 22) -777)
      (= (array-ref difference-storage 23) -777))
      42
      1)))