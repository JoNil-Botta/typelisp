;; A view's packed data pointer keeps the backing array reachable. A later
;; temporary array must not reuse that storage before the view is consumed.
(defstruct PointerPair
  (data (Ptr i64))
  (tag i64))

(define (shared-view) : bool
  (let
    [items : (Array i64 2) (array 17 25)]
    [view : (& items (Slice i64)) (slice-view items 0 2)]
    [copy : (& items (Slice i64))
      (unsafe
        (ptr-read
          (ptr-cast
            (__tl_array-data (array view))
            : (Ptr (& items (Slice i64))))))]
    (and
      (= (array-length copy) 2)
      (= (array-ref copy 0) 17)
      (= (array-ref copy 1) 25))))

(define (mutable-view) : bool
  (let
    [items : (Array i64 2) (array 17 25)]
    [result : i64
      (let
        [view : (&mut items (Slice i64)) (slice-mut-view items 0 2)]
        [copy : (&mut items (Slice i64))
          (unsafe
            (ptr-read
              (ptr-cast
                (__tl_array-data (array view))
                : (Ptr (&mut items (Slice i64))))))]
        (set! (array-ref copy 0) (+ (array-ref copy 0) 1))
        (+ (array-ref copy 0) (array-ref copy 1)))]
    (and (= result 43) (= (array-ref items 0) 18) (= (array-ref items 1) 25))))

(define (nested-view) : bool
  (let
    [items : (Array i64 2) (array 17 25)]
    [view : (& items (Slice i64)) (slice-view items 0 2)]
    [alias : (& items (Slice i64)) view]
    [nested : (Tuple (& items (Slice i64))) (tuple alias)]
    [copy : (Tuple (& items (Slice i64)))
      (unsafe
        (ptr-read
          (ptr-cast
            (__tl_array-data (array nested))
            : (Ptr (Tuple (& items (Slice i64)))))))]
    [last : (& items (Slice i64)) (tuple-ref copy 0)]
    (= (+ (array-ref last 0) (array-ref last 1)) 42)))

(define (nominal-pointer) : bool
  (let
    [items : (Array i64 2) (array 17 25)]
    [pair : PointerPair
      (PointerPair
        (unsafe
          (ptr-cast (__tl_array-data items) : (Ptr i64)))
        42)]
    [copy : PointerPair
      (unsafe
        (ptr-read (ptr-cast (__tl_array-data (array pair)) : (Ptr PointerPair))))]
    (and
      (= copy.tag 42)
      (=
        (unsafe
          (ptr-read copy.data))
        17)
      (=
        (unsafe
          (ptr-read (ptr-offset copy.data 1)))
        25))))

(define (two-views) : bool
  (let
    [first : (Array i64 2) (array 17 25)]
    [left : (& first (Slice i64)) (slice-view first 0 2)]
    [second : (Array i64 2) (array 20 22)]
    [right : (& second (Slice i64)) (slice-view second 0 2)]
    [left-copy : (& first (Slice i64))
      (unsafe
        (ptr-read
          (ptr-cast
            (__tl_array-data (array left))
            : (Ptr (& first (Slice i64))))))]
    [right-copy : (& second (Slice i64))
      (unsafe
        (ptr-read
          (ptr-cast
            (__tl_array-data (array right))
            : (Ptr (& second (Slice i64))))))]
    (and
      (= (array-ref left-copy 0) 17)
      (= (array-ref left-copy 1) 25)
      (= (array-ref right-copy 0) 20)
      (= (array-ref right-copy 1) 22))))

(define (main) : i64
  (cond
    [(not (shared-view)) 1]
    [(not (mutable-view)) 2]
    [(not (nested-view)) 3]
    [(not (nominal-pointer)) 4]
    [(not (two-views)) 5]
    [else 42]))