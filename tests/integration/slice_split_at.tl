(define slice-split-mid-calls : i64
  0)

(define (slice-split-counted-mid) : i64
  (begin
    (set! slice-split-mid-calls (+ slice-split-mid-calls 1))
    2))

(define (slice-split-return [view : (&mut source (Slice i64))] [mid : i64]) : (Tuple
    (&mut source (Slice i64))
    (&mut source (Slice i64)))
  (slice-split-at-mut view mid))

(define (slice-split-nested-case) : bool
  (let
    [items : (Array i64 5) (array 10 20 30 40 50)]
    [split-score : i64
      (let
        [view : (&mut items (Slice i64)) (slice-mut-view items 0 5)]
        [outer : (Tuple (&mut items (Slice i64)) (&mut items (Slice i64)))
          (slice-split-at-mut view (slice-split-counted-mid))]
        [left : (&mut items (Slice i64)) (tuple-ref outer 0)]
        [right : (&mut items (Slice i64)) (tuple-ref outer 1)]
        [inner : (Tuple (&mut items (Slice i64)) (&mut items (Slice i64)))
          (slice-split-at-mut right 1)]
        [middle : (&mut items (Slice i64)) (tuple-ref inner 0)]
        [tail : (&mut items (Slice i64)) (tuple-ref inner 1)]
        (begin
          (set! (array-ref left 1) 2)
          (set! (array-ref middle 0) 3)
          (set! (array-ref tail 1) 37)
          (+ (array-ref left 1) (+ (array-ref middle 0) (array-ref tail 1)))))]
    (and
      (= split-score 42)
      (= slice-split-mid-calls 1)
      (= (array-ref items 1) 2)
      (= (array-ref items 2) 3)
      (= (array-ref items 4) 37))))

(define (slice-split-boundary-case) : bool
  (let
    [items : (Array i64 4) (array 4 8 15 16)]
    [view : (& items (Slice i64)) (slice-view items 0 4)]
    [at-zero : (Tuple (& items (Slice i64)) (& items (Slice i64)))
      (slice-split-at view 0)]
    [zero-left : (& items (Slice i64)) (tuple-ref at-zero 0)]
    [zero-right : (& items (Slice i64)) (tuple-ref at-zero 1)]
    [at-end : (Tuple (& items (Slice i64)) (& items (Slice i64)))
      (slice-split-at view 4)]
    [end-left : (& items (Slice i64)) (tuple-ref at-end 0)]
    [end-right : (& items (Slice i64)) (tuple-ref at-end 1)]
    [empty-items : (Array unit 2) (array unit unit)]
    [empty-view : (& empty-items (Slice unit)) (slice-view empty-items 0 2)]
    [empty-halves : (Tuple
      (& empty-items (Slice unit))
      (& empty-items (Slice unit)))
      (slice-split-at empty-view 1)]
    (and
      (= (array-length zero-left) 0)
      (= (array-length zero-right) 4)
      (= (array-length end-left) 4)
      (= (array-length end-right) 0)
      (= (array-ref zero-right 2) 15)
      (= (array-ref end-left 3) 16)
      (= (array-length (tuple-ref empty-halves 0)) 1)
      (= (array-length (tuple-ref empty-halves 1)) 1))))

(define (slice-split-return-case) : bool
  (let
    [items : (Array i64 4) (array 10 20 30 40)]
    [score : i64
      (let
        [view : (&mut items (Slice i64)) (slice-mut-view items 0 4)]
        [halves : (Tuple (&mut items (Slice i64)) (&mut items (Slice i64)))
          (slice-split-return view 2)]
        [left : (&mut items (Slice i64)) (tuple-ref halves 0)]
        [right : (&mut items (Slice i64)) (tuple-ref halves 1)]
        (begin
          (set! (array-ref left 0) 7)
          (set! (array-ref right 0) 35)
          (+ (array-ref left 0) (array-ref right 0))))]
    (and (= score 42) (= (array-ref items 0) 7) (= (array-ref items 2) 35))))

(define (slice-split-shared-from-mut-case) : bool
  (let
    [items : (Array i64 3) (array 6 7 8)]
    [score : i64
      (let
        [view : (&mut items (Slice i64)) (slice-mut-view items 0 3)]
        [halves : (Tuple (& items (Slice i64)) (& items (Slice i64)))
          (slice-split-at view 1)]
        (+
          (array-ref (tuple-ref halves 0) 0)
          (array-ref (tuple-ref halves 1) 0)))]
    (= score 13)))

(define (main) : i64
  (if (and
    (slice-split-nested-case)
    (slice-split-boundary-case)
    (slice-split-return-case)
    (slice-split-shared-from-mut-case))
    42
    1))