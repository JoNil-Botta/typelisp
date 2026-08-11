;; Whole-array fixed storage can be borrowed as a two-word Slice reference at
;; a typed call boundary.  This fixture keeps the calls deliberately ordinary
;; (rather than relying on any extern ABI) so both native targets exercise the
;; same structural representation.
(defstruct SliceTriple
  (a i64)
  (b i64)
  (c i64))

(define (slice-sum
  [p0 : i64]
  [p1 : i64]
  [p2 : i64]
  [p3 : i64]
  [p4 : i64]
  [s : (& s (Slice i64))]) : i64
  (+ (+ (+ p0 p1) (+ p2 p3)) (+ p4 (+ (length s) (array-ref s 0)))))

(define (slice-id [s : (& s (Slice i64))]) : (& s (Slice i64))
  s)

(define (slice-mut-sum [p0 : i64] [p1 : i64] [s : (&mut s (Slice i64))]) : i64
  (begin
    (set! (array-ref s 0) (+ p0 p1))
    (+ (array-ref s 0) (array-length s))))

(define (slice-ref-value [_value : (& value i64)]) : i64
  1)

(define (slice-borrow-element [s : (& s (Slice i64))] [index : i64]) : i64
  (let
    [selected : (& s i64) (& (array-ref s index))]
    (+ (slice-ref-value selected) (array-ref s index))))

(define (triple-sum [s : (& s (Slice SliceTriple))]) : i64
  (let
    [v : SliceTriple (array-ref s 1)]
    (+ v.a (+ v.b v.c))))

(define (triple-mut [s : (&mut s (Slice SliceTriple))]) : i64
  (begin
    (set! (array-ref s 0) (SliceTriple 7 8 9))
    (let
      [v : SliceTriple (array-ref s 0)]
      (+ v.a (+ v.b v.c)))))

(define (nested-sum [s : (& s (Slice (Array i64 2)))]) : i64
  (+ (array-ref (array-ref s 0) 1) (array-ref (array-ref s 1) 0)))

(define (slice-length [s : (& s (Slice i64))]) : i64
  (length s))

;; A noncapturing function value enters through a closure adapter. Seven Slice
;; references cross both the register/stack boundary and the adapter's hidden
;; environment slot, so every data/length word must retain its own home.
(define (slice-indirect-seven
  [a : (&mut a (Slice i64))]
  [b : (&mut b (Slice i64))]
  [c : (&mut c (Slice i64))]
  [d : (&mut d (Slice i64))]
  [e : (&mut e (Slice i64))]
  [f : (&mut f (Slice i64))]
  [g : (&mut g (Slice i64))]) : i64
  (begin
    (set! (array-ref a 0) 1)
    (set! (array-ref b 0) 2)
    (set! (array-ref c 0) 3)
    (set! (array-ref d 0) 4)
    (set! (array-ref e 0) 5)
    (set! (array-ref f 0) 6)
    (set! (array-ref g 0) 7)
    (+
      (+ (array-ref a 0) (array-ref b 0))
      (+
        (+ (array-ref c 0) (array-ref d 0))
        (+
          (+ (array-ref e 0) (array-ref f 0))
          (+ (array-ref g 0) (+ (length a) (length g))))))))

(define (slice-indirect-seven-call
  [a : (&mut a (Slice i64))]
  [b : (&mut b (Slice i64))]
  [c : (&mut c (Slice i64))]
  [d : (&mut d (Slice i64))]
  [e : (&mut e (Slice i64))]
  [f : (&mut f (Slice i64))]
  [g : (&mut g (Slice i64))]) : i64
  (let
    [fn : (->
      (&mut a (Slice i64))
      (&mut b (Slice i64))
      (&mut c (Slice i64))
      (&mut d (Slice i64))
      (&mut e (Slice i64))
      (&mut f (Slice i64))
      (&mut g (Slice i64))
      i64)
      slice-indirect-seven]
    (fn a b c d e f g)))

(define (main) : i64
  (let
    [items : (Array i64 3) (array 10 20 30)]
    [triples : (Array SliceTriple 2)
      (array (SliceTriple 1 2 3) (SliceTriple 4 5 6))]
    [rows : (Array (Array i64 2) 2) (array (array 11 12) (array 13 14))]
    [empty : (Array i64 0) (array)]
    [indirect-a : (Array i64 1) (array 0)]
    [indirect-b : (Array i64 1) (array 0)]
    [indirect-c : (Array i64 1) (array 0)]
    [indirect-d : (Array i64 1) (array 0)]
    [indirect-e : (Array i64 1) (array 0)]
    [indirect-f : (Array i64 1) (array 0)]
    [indirect-g : (Array i64 1) (array 0)]
    [indirect-score : i64
      (slice-indirect-seven-call
        (&mut indirect-a)
        (&mut indirect-b)
        (&mut indirect-c)
        (&mut indirect-d)
        (&mut indirect-e)
        (&mut indirect-f)
        (&mut indirect-g))]
    [view-score : i64
      (let
        [view : (& items (Slice i64)) (slice-id (& items))]
        (+ (length view) (array-ref view 1)))]
    [slice-score : i64 (slice-sum 1 2 3 4 5 (& items))]
    [mut-score : i64 (slice-mut-sum 6 7 (&mut items))]
    [borrow-score : i64 (slice-borrow-element (& items) 2)]
    [triple-score : i64 (triple-sum (& triples))]
    [triple-mut-score : i64 (triple-mut (&mut triples))]
    [nested-score : i64 (nested-sum (& rows))]
    (if (= indirect-score 30)
      (-
        (+
          view-score
          (+
            slice-score
            (+
              mut-score
              (+
                borrow-score
                (+
                  triple-score
                  (+ triple-mut-score (+ nested-score (slice-length (& empty)))))))))
        120)
      1)))