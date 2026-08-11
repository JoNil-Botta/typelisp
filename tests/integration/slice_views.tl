;; Checked, bounds-safe subviews over fixed arrays, dynamic arrays, and
;; already-borrowed Slice references.  The fixture returns 42 only when the
;; shared/mutable paths, reference forms, nested views, aggregate stride, and
;; argument evaluation order all agree.
(import stdlib.array)

(defstruct SliceViewTriple
  (a i64)
  (b i64)
  (c i64))

(define (slice-view-sum [s : (& s (Slice i64))]) : i64
  (+ (array-length s) (+ (array-ref s 0) (array-ref s 1))))

(define (slice-view-write [s : (&mut s (Slice i64))] [value : i64]) : i64
  (begin
    (set! (array-ref s 0) value)
    (array-ref s 0)))

(define (slice-view-triple-sum [s : (& s (Slice SliceViewTriple))]) : i64
  (let
    [value : SliceViewTriple (array-ref s 0)]
    (+ value.a (+ value.b value.c))))

(define (slice-view-triple-write
  [s : (&mut s (Slice SliceViewTriple))]
  [value : SliceViewTriple]) : i64
  (begin
    (set! (array-ref s 0) value)
    (let
      [stored : SliceViewTriple (array-ref s 0)]
      (+ stored.a (+ stored.b stored.c)))))

(define slice-view-source-calls : i64
  0)
(define slice-view-start-calls : i64
  0)
(define slice-view-len-calls : i64
  0)
(define slice-view-order-state : i64
  0)

(define (slice-view-counted-source [source : (& source (Array i64 4))]) : (&
    source
    (Array i64 4))
  (if (= slice-view-order-state 0)
    (begin
      (set! slice-view-order-state 1)
      (set! slice-view-source-calls (+ slice-view-source-calls 1))
      source)
    (begin
      (set! slice-view-order-state -1)
      (set! slice-view-source-calls (+ slice-view-source-calls 1))
      source)))

(define (slice-view-counted-start) : i64
  (if (= slice-view-order-state 1)
    (begin
      (set! slice-view-order-state 2)
      (set! slice-view-start-calls (+ slice-view-start-calls 1))
      1)
    (begin
      (set! slice-view-order-state -1)
      (set! slice-view-start-calls (+ slice-view-start-calls 1))
      1)))

(define (slice-view-counted-len) : i64
  (if (= slice-view-order-state 2)
    (begin
      (set! slice-view-order-state 3)
      (set! slice-view-len-calls (+ slice-view-len-calls 1))
      2)
    (begin
      (set! slice-view-order-state -1)
      (set! slice-view-len-calls (+ slice-view-len-calls 1))
      2)))

(define (main) : i64
  (let
    [fixed : (Array i64 4) (array 10 20 30 40)]
    [fixed-score : i64 (slice-view-sum (slice-view fixed 1 2))]
    [fixed-ref-score : i64 (slice-view-sum (slice-view (& fixed) 0 2))]
    [fixed-mut-score : i64 (slice-view-write (slice-mut-view fixed 1 2) 77)]
    [fixed-mut-ref-score : i64
      (slice-view-write (slice-mut-view (&mut fixed) 0 1) 88)]
    [dynamic : (__tl_dyn-array i64) (array.make-array i64 4)]
    (begin
      (set! (array-ref dynamic 0) 3)
      (set! (array-ref dynamic 1) 6)
      (set! (array-ref dynamic 2) 9)
      (set! (array-ref dynamic 3) 12)
      (let
        [dynamic-score : i64 (slice-view-sum (slice-view dynamic 1 2))]
        [dynamic-ref-score : i64 (slice-view-sum (slice-view (& dynamic) 0 2))]
        [dynamic-mut-score : i64
          (slice-view-write (slice-mut-view dynamic 1 2) 66)]
        [dynamic-mut-ref-score : i64
          (slice-view-write (slice-mut-view (&mut dynamic) 0 1) 99)]
        [shared-slice : (& fixed (Slice i64)) (slice-view fixed 0 4)]
        [nested-score : i64 (slice-view-sum (slice-view shared-slice 1 2))]
        [empty-score : i64 (array-length (slice-view fixed 4 0))]
        [mut-back : (Array i64 3) (array 5 6 7)]
        [mut-parent-child-score : i64
          (let
            [parent : (&mut mut-back (Slice i64)) (slice-mut-view mut-back 0 3)]
            (slice-view-write (slice-mut-view parent 1 1) 123))]
        [mut-back-score : i64 (array-ref mut-back 1)]
        [triples : (Array SliceViewTriple 3)
          (array
            (SliceViewTriple 1 2 3)
            (SliceViewTriple 4 5 6)
            (SliceViewTriple 7 8 9))]
        [triple-score : i64 (slice-view-triple-sum (slice-view triples 1 2))]
        [triple-mut-score : i64
          (slice-view-triple-write
            (slice-mut-view triples 1 1)
            (SliceViewTriple 20 21 22))]
        [order-score : i64
          (begin
            (set! slice-view-source-calls 0)
            (set! slice-view-start-calls 0)
            (set! slice-view-len-calls 0)
            (set! slice-view-order-state 0)
            (slice-view-sum
              (slice-view
                (slice-view-counted-source (& fixed))
                (slice-view-counted-start)
                (slice-view-counted-len))))]
        (if (and
          (= fixed-score 52)
          (= fixed-ref-score 32)
          (= fixed-mut-score 77)
          (= fixed-mut-ref-score 88)
          (= dynamic-score 17)
          (= dynamic-ref-score 11)
          (= dynamic-mut-score 66)
          (= dynamic-mut-ref-score 99)
          (= nested-score 109)
          (= empty-score 0)
          (= mut-parent-child-score 123)
          (= mut-back-score 123)
          (= triple-score 15)
          (= triple-mut-score 63)
          (= order-score 109)
          (= slice-view-source-calls 1)
          (= slice-view-start-calls 1)
          (= slice-view-len-calls 1)
          (= slice-view-order-state 3))
          42
          1)))))