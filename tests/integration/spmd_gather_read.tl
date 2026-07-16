(import stdlib.array)

(define (init-source [xs : (Array i64)] [source-len : i64]) : unit
  (let
    [i : i64 0]
    (while (< i source-len)
      (begin
        (array-set! xs i (+ 100 (* i 3)))
        (set! i (+ i 1))))))

(define (init-index [ix : (Array i64)] [n : i64] [source-len : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! ix i (% (+ (* i 5) 3) source-len))
        (set! i (+ i 1))))))

(define (fill-gather-foreach
  [xs : (Array i64)]
  [ix : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (array-ref xs (array-ref ix i)))))

(define (fill-gather-scalar
  [xs : (Array i64)]
  [ix : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out i (array-ref xs (array-ref ix i)))
        (set! i (+ i 1))))))

(define (eq-i64 [a : (Array i64)] [b : (Array i64)] [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (!= (array-ref a i) (array-ref b i))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (case-gather [n : i64]) : bool
  (let
    [source-len : i64 17]
    [xs : (Array i64) (array.make-array i64 source-len)]
    [ix : (Array i64) (array.make-array i64 n)]
    [got : (Array i64) (array.make-array i64 n)]
    [want : (Array i64) (array.make-array i64 n)]
    (begin
      (init-source xs source-len)
      (init-index ix n source-len)
      (fill-gather-foreach xs ix got n)
      (fill-gather-scalar xs ix want n)
      (eq-i64 got want n))))

(define (init-lane-offsets [offsets : (Array i64)]) : unit
  (let
    [i : i64 0]
    (while (< i (array-length offsets))
      (begin
        ;; Repeated, negative, zero, and positive offsets exercise the checked
        ;; logical-lane order without making an index array in memory.
        (array-set! offsets i (- (% (* i 3) 6) 3))
        (set! i (+ i 1))))))

(define (fill-lane-offset-gather
  [xs : (Array i64)]
  [offsets : (Array i64)]
  [out : (Array i64)]
  [start : i64]
  [end : i64]) : unit
  (foreach
    ([i : i64 start end])
    (array-set! out i (array-ref xs (+ i (array-ref offsets (program-index)))))))

(define (fill-reversed-lane-offset-gather
  [xs : (Array i64)]
  [offsets : (Array i64)]
  [out : (Array i64)]
  [start : i64]
  [end : i64]) : unit
  (foreach
    ([i : i64 start end])
    (array-set! out i (array-ref xs (+ (array-ref offsets (program-index)) i)))))

(define (fill-lane-offset-gather-scalar
  [xs : (Array i64)]
  [offsets : (Array i64)]
  [lane-ids : (Array i64)]
  [out : (Array i64)]
  [start : i64]
  [end : i64]) : unit
  (let
    [i : i64 start]
    (while (< i end)
      (begin
        (array-set!
          out
          i
          (array-ref xs (+ i (array-ref offsets (array-ref lane-ids i)))))
        (set! i (+ i 1))))))

(define (case-lane-offset-gather [n : i64] [reversed : bool]) : bool
  (let
    [start : i64 4]
    [end : i64 (+ start n)]
    [source-len : i64 (+ end 4)]
    [xs : (Array i64) (array.make-array i64 source-len)]
    [offset-count : i64
      (if (< n 4)
        n
        16)]
    [offsets : (Array i64) (array.make-array i64 offset-count)]
    [lane-ids : (Array i64) (array.make-array i64 source-len)]
    [got : (Array i64) (array.make-array i64 source-len)]
    [want : (Array i64) (array.make-array i64 source-len)]
    (begin
      (init-source xs source-len)
      (init-lane-offsets offsets)
      (foreach ([i : i64 start end]) (array-set! lane-ids i (program-index)))
      (if reversed
        (fill-reversed-lane-offset-gather xs offsets got start end)
        (fill-lane-offset-gather xs offsets got start end))
      (fill-lane-offset-gather-scalar xs offsets lane-ids want start end)
      (eq-i64 got want source-len))))

(define (case-numeric-gathers [n : i64]) : bool
  (let
    [source-len : i64 17]
    [ix : (Array i64) (array.make-array i64 n)]
    [xs32 : (Array i32) (array.make-array i32 source-len)]
    [got32 : (Array i32) (array.make-array i32 n)]
    [want32 : (Array i32) (array.make-array i32 n)]
    [xsf : (Array f32) (array.make-array f32 source-len)]
    [gotf : (Array f32) (array.make-array f32 n)]
    [wantf : (Array f32) (array.make-array f32 n)]
    [xsd : (Array f64) (array.make-array f64 source-len)]
    [gotd : (Array f64) (array.make-array f64 n)]
    [wantd : (Array f64) (array.make-array f64 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (init-index ix n source-len)
      (while (< i source-len)
        (begin
          (array-set! xs32 i (cast (+ 11 (* i 7)) : i32))
          (array-set! xsf i (cast (+ 21 (* i 5)) : f32))
          (array-set! xsd i (cast (+ 31 (* i 9)) : f64))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (array-set! got32 j (array-ref xs32 (array-ref ix j))))
      (foreach
        ([j : i64 0 n])
        (array-set! gotf j (array-ref xsf (array-ref ix j))))
      (foreach
        ([j : i64 0 n])
        (array-set! gotd j (array-ref xsd (array-ref ix j))))
      (set! i 0)
      (while (< i n)
        (begin
          (array-set! want32 i (array-ref xs32 (array-ref ix i)))
          (array-set! wantf i (array-ref xsf (array-ref ix i)))
          (array-set! wantd i (array-ref xsd (array-ref ix i)))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i n)
        (begin
          (if (and
            (= (array-ref got32 i) (array-ref want32 i))
            (= (array-ref gotf i) (array-ref wantf i))
            (= (array-ref gotd i) (array-ref wantd i)))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (case-numeric-lane-offset-gathers [n : i64]) : bool
  (let
    [source-len : i64 (+ n 4)]
    [offsets : (Array i64) (array.make-array i64 16)]
    [lane-ids : (Array i64) (array.make-array i64 n)]
    [xs32 : (Array i32) (array.make-array i32 source-len)]
    [got32 : (Array i32) (array.make-array i32 n)]
    [xsf : (Array f32) (array.make-array f32 source-len)]
    [gotf : (Array f32) (array.make-array f32 n)]
    [xsd : (Array f64) (array.make-array f64 source-len)]
    [gotd : (Array f64) (array.make-array f64 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i 16)
        (begin
          (array-set! offsets i (% (* i 3) 4))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i source-len)
        (begin
          (array-set! xs32 i (cast (+ 11 (* i 7)) : i32))
          (array-set! xsf i (cast (+ 21 (* i 5)) : f32))
          (array-set! xsd i (cast (+ 31 (* i 9)) : f64))
          (set! i (+ i 1))))
      (foreach ([j : i64 0 n]) (array-set! lane-ids j (program-index)))
      (foreach
        ([j : i64 0 n])
        (array-set!
          got32
          j
          (array-ref xs32 (+ j (array-ref offsets (program-index))))))
      (foreach
        ([j : i64 0 n])
        (array-set!
          gotf
          j
          (array-ref xsf (+ j (array-ref offsets (program-index))))))
      (foreach
        ([j : i64 0 n])
        (array-set!
          gotd
          j
          (array-ref xsd (+ j (array-ref offsets (program-index))))))
      (set! i 0)
      (while (< i n)
        (let
          [lane : i64 (array-ref lane-ids i)]
          [source-index : i64 (+ i (array-ref offsets lane))]
          (begin
            (if (and
              (= (array-ref got32 i) (array-ref xs32 source-index))
              (= (array-ref gotf i) (array-ref xsf source-index))
              (= (array-ref gotd i) (array-ref xsd source-index)))
              unit
              (set! ok false))
            (set! i (+ i 1)))))
      ok)))

(define (all-cases) : bool
  (let
    [ok : bool true]
    (begin
      (if (case-gather 0)
        unit
        (set! ok false))
      (if (case-gather 1)
        unit
        (set! ok false))
      (if (case-gather 3)
        unit
        (set! ok false))
      (if (case-gather 13)
        unit
        (set! ok false))
      (if (case-gather 33)
        unit
        (set! ok false))
      (if (case-numeric-gathers 33)
        unit
        (set! ok false))
      (if (case-lane-offset-gather 0 false)
        unit
        (set! ok false))
      (if (case-lane-offset-gather 3 false)
        unit
        (set! ok false))
      (if (case-lane-offset-gather 8 false)
        unit
        (set! ok false))
      (if (case-lane-offset-gather 13 true)
        unit
        (set! ok false))
      (if (case-lane-offset-gather 33 false)
        unit
        (set! ok false))
      (if (case-numeric-lane-offset-gathers 33)
        unit
        (set! ok false))
      ok)))

(define (main) : i64
  (if (all-cases)
    42
    1))