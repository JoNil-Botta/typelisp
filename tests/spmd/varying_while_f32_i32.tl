;; AVX2/AVX-512 varying while with f32 recurrence state and i32 lane counters.
(import stdlib.array)

(define (fill-recurrence
  [remaining : (Array i32)]
  [x-values : (Array f32)]
  [y-values : (Array f32)]
  [z-re : (Array f32)]
  [z-im : (Array f32)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [x : f32 (array-ref x-values i)]
      [y : f32 (array-ref y-values i)]
      (begin
        (array-set! z-re i x)
        (array-set! z-im i y)
        (while (> (array-ref remaining i) 0)
          (let
            [old-re : f32 (array-ref z-re i)]
            [old-im : f32 (array-ref z-im i)]
            [new-re : f32 (- (* old-re old-re) (* old-im old-im))]
            [new-im : f32 (* (+ old-re old-re) old-im)]
            (begin
              (array-set! z-re i (+ x new-re))
              (array-set! z-im i (+ y new-im))
              (array-set! remaining i (+ (array-ref remaining i) -1)))))))))

(define (expected-z-re [iterations : i32]) : f32
  (cond
    [(= iterations 0) (cast 1.0 : f32)]
    [(= iterations 1) (cast 2.0 : f32)]
    [(= iterations 2) (cast 5.0 : f32)]
    [else (cast 26.0 : f32)]))

(define (main) : i64
  (let
    [n : i64 19]
    [remaining : (Array i32) (array.make-array i32 n)]
    [x-values : (Array f32) (array.make-array f32 n)]
    [y-values : (Array f32) (array.make-array f32 n)]
    [z-re : (Array f32) (array.make-array f32 n)]
    [z-im : (Array f32) (array.make-array f32 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (array-set! remaining i (cast (% i 4) : i32))
          (array-set! x-values i (cast 1.0 : f32))
          (array-set! y-values i (cast 0.0 : f32))
          (set! i (+ i 1))))
      (fill-recurrence remaining x-values y-values z-re z-im n)
      (set! i 0)
      (while (< i n)
        (begin
          (if (and
            (= (array-ref remaining i) 0)
            (= (array-ref z-re i) (expected-z-re (cast (% i 4) : i32)))
            (= (array-ref z-im i) (cast 0.0 : f32)))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      (if ok
        42
        1))))