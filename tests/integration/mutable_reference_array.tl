(import stdlib.array)

(define (put-first [items : (&mut items (Array i64))] [value : i64]) : unit
  (array.array-set! items 0 value))

(define (push-tail [items : (&mut items (Array i64))] [value : i64]) : unit
  (array.array-push! items value))

(define (put-fixed [items : (&mut items (Array i64 2))] [value : i64]) : unit
  (array.array-set! items 1 value))

(defstruct ArrayBag
  (items (Array i64)))

(defstruct ArrayBagHandle
  (:lifetimes bag)
  (items (&mut bag (Array i64)))
  (index i64))

(define (array-bag-handle [bag : (&mut bag ArrayBag)] [index : i64]) : (ArrayBagHandle
    bag)
  (ArrayBagHandle (&mut (struct-get bag items)) index))

(define (array-bag-handle-write [handle : (ArrayBagHandle bag)] [value : i64]) : unit
  (array.array-set! (struct-get handle items) (struct-get handle index) value))

(define (array-bag-handle-read [handle : (ArrayBagHandle bag)]) : i64
  (+
    (array.array-length (struct-get handle items))
    (array.array-ref (struct-get handle items) (struct-get handle index))))

(define (array-bag-handle-score) : i64
  (let
    [items : (Array i64) (array.make-array i64 2)]
    (begin
      (array.array-set! items 0 7)
      (array.array-set! items 1 9)
      (let
        [bag : ArrayBag (ArrayBag items)]
        [handle : (ArrayBagHandle bag) (array-bag-handle (&mut bag) 1)]
        (begin
          (array-bag-handle-write handle 40)
          (array-bag-handle-read handle))))))

(define (main) : i64
  (let
    [items : (Array i64) (array.make-array i64 1)]
    [fixed : (Array i64 2) (array 0 0)]
    (begin
      (array.array-set! items 0 1)
      (put-first (&mut items) 40)
      (push-tail (&mut items) 2)
      (put-fixed (&mut fixed) 41)
      (if (and
        (= (array.array-length items) 2)
        (= (array-bag-handle-score) 42)
        (= (array.array-ref items 0) 40)
        (= (array.array-ref items 1) 2)
        (= (array.array-ref fixed 1) 41))
        42
        1))))