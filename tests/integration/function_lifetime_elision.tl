;; Signature-local lifetime elision: each input reference receives a hidden
;; lifetime, and an elided reference result inherits the sole input lifetime.
(defstruct ElisionItem
  (value i64))

(define (increment-and-view [item : (&mut ElisionItem)]) : (& ElisionItem)
  (begin
    (set! item.value (+ item.value 1))
    (& item)))

(define (same-value? [left : (& ElisionItem)] [right : (& ElisionItem)]) : bool
  (= left.value right.value))

(define (tuple-view [item : (& ElisionItem)]) : (Tuple (& ElisionItem))
  (tuple item))

(define (array-view [items : (Array (& ElisionItem) 1)]) : (Array
    (& ElisionItem)
    1)
  items)

(define (shared-left
  [left : (& shared ElisionItem)]
  [right : (& shared ElisionItem)]) : (& ElisionItem)
  (if (= left.value right.value)
    left
    left))

(define (mixed-inputs?
  [left : (& shared ElisionItem)]
  [right : (& ElisionItem)]) : bool
  (= left.value right.value))

(define (call-view
  [view : (-> (& ElisionItem) (& ElisionItem))]
  [item : (& ElisionItem)]) : i64
  (struct-get (view item) value))

(define (main) : i64
  (let
    [item : ElisionItem (ElisionItem 41)]
    [view (increment-and-view (&mut item))]
    [views : (Array (& item ElisionItem) 1) (array view)]
    (if (and
      (= view.value 42)
      (same-value? view (& item))
      (= (struct-get (tuple-ref (tuple-view view) 0) value) 42)
      (= (struct-get (array-ref (array-view views) 0) value) 42)
      (= (struct-get (shared-left (& item) (& item)) value) 42)
      (mixed-inputs? (& item) (& item))
      (=
        (call-view
          (lambda ([value : (& ElisionItem)]) : (& ElisionItem)
            value)
          view)
        42))
      42
      1)))