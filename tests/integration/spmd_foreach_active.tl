;; Scalar-reference `foreach-active` semantics (#8306). The body runs once per
;; active lane in increasing lane order, which on the one-lane scalar gang is
;; once per index, in index order. `lane` is 0 there, the lane program-index
;; reads. Each row of native.manifest runs one case, chosen by argv[1].
(import stdlib.io)
(import stdlib.string)
(import stdlib.atomic)

;; Colliding histogram: several indices hit the same bucket, which a gang may
;; not write in parallel but a serialized body may.
(define (histogram) : unit
  (let
    [idx : (Array i64 8) (array 3 1 3 3 0 1 7 3)]
    [counts : (Array i64 8) (make-array i64 8)]
    (begin
      (foreach
        ([i : i64 0 8])
        (foreach-active
          [lane : i64]
          (let
            [bucket : i64 (lane-value (array-ref idx i))]
            (set! (array-ref counts bucket) (+ (array-ref counts bucket) 1)))))
      (io.println
        "{} {} {} {}"
        (array-ref counts 0)
        (array-ref counts 1)
        (array-ref counts 3)
        (array-ref counts 7)))))

;; An accumulator declared outside the gang, and a body that runs a scalar
;; while loop of its own.
(define (accumulate) : unit
  (let
    [total : i64 0]
    [steps : i64 0]
    (begin
      (foreach
        ([i : i64 0 6])
        (foreach-active
          [lane : i64]
          (set! total (+ total (* (lane-value i) (lane-value i))))
          (let
            [k : i64 0]
            (while (< k (lane-value i))
              (begin
                (set! steps (+ steps 1))
                (set! k (+ k 1)))))))
      (io.println "{} {}" total steps))))

;; A masked branch serializes only its active lanes; the inactive indices run
;; nothing. The nested mask narrows the lanes again.
(define (masked) : unit
  (let
    [odd-total : i64 0]
    [deep : i64 0]
    (begin
      (foreach
        ([i : i64 0 10])
        (if (= (% i 2) 1)
          (begin
            (foreach-active
              [lane : i64]
              (set! odd-total (+ odd-total (lane-value i))))
            (if (> i 4)
              (foreach-active
                [lane : i64]
                (set! deep (+ (* deep 10) (lane-value i))))
              unit))
          unit))
      (io.println "{} {}" odd-total deep))))

;; A call per active lane, observed in lane order, and the lane numbering it
;; sees.
(define (calls) : unit
  (foreach
    ([i : i64 0 4])
    (foreach-active
      [lane : i64]
      (io.println
        "{} {} {} {}"
        (lane-value i)
        lane
        (lane-value (program-index))
        (program-count)))))

;; lane-value for each scalar lane type the gang can carry.
(define (lane-types) : unit
  (let
    [ints : (Array i32 4) (array 5 -6 7 -8)]
    [floats : (Array f64 4) (array 0.5 1.5 2.5 3.5)]
    [int-total : i32 0]
    [float-total : f64 0.0]
    [odd : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (let
          [flag : bool (= (% i 2) 1)]
          (foreach-active
            [lane : i64]
            (set! int-total (+ int-total (lane-value (array-ref ints i))))
            (set! float-total (+ float-total (lane-value (array-ref floats i))))
            (if (lane-value flag)
              (set! odd (+ odd 1))
              unit))))
      (io.println "{} {} {}" int-total (cast float-total : i64) odd))))

;; An approved extern per active lane: the gang itself may only scatter
;; atomics through a contiguous index, but the serialized body passes uniform
;; arguments, so any bucket is fine.
(define (atomics) : unit
  (let
    [buckets : atomic.AtomicI64Buffer (atomic.i64-buffer 3)]
    (begin
      (foreach
        ([i : i64 0 7])
        (foreach-active
          [lane : i64]
          (atomic.atomic-i64-add!
            (& buckets)
            (lane-value (% i 3))
            (lane-value i))))
      (io.println
        "{} {} {}"
        (atomic.atomic-i64-load (& buckets) 0)
        (atomic.atomic-i64-load (& buckets) 1)
        (atomic.atomic-i64-load (& buckets) 2)))))

;; The first index whose body faults traps, after every earlier index ran:
;; index 3 reads bucket 9 of an 8-bucket table.
(define (first-fault) : unit
  (let
    [idx : (Array i64 6) (array 0 1 2 9 4 12)]
    [table : (Array i64 8) (make-array i64 8)]
    (foreach
      ([i : i64 0 6])
      (foreach-active
        [lane : i64]
        (io.println "{}" (lane-value i))
        (set! (array-ref table (lane-value (array-ref idx i))) (lane-value i))))))

(define (main) : i64
  (let
    [mode : i64 (string.>int (io.arg 1))]
    (begin
      (cond
        [(= mode 1) (histogram)]
        [(= mode 2) (accumulate)]
        [(= mode 3) (masked)]
        [(= mode 4) (calls)]
        [(= mode 5) (lane-types)]
        [(= mode 6) (atomics)]
        [else (first-fault)])
      0)))