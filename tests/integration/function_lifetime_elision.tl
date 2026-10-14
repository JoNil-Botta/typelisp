;; Signature-local lifetime elision: each input reference receives a hidden
;; lifetime, and an elided reference result inherits the sole input lifetime.
(defstruct ElisionItem
  (value i64))

(define (increment-and-view [item : (&mut ElisionItem)]) : (& ElisionItem)
  (set! item.value (+ item.value 1))
  (& item))

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
  (__tl-project-field (view item) value))

;; The item is boxed so `(&mut (deref holder))` borrows its heap cell: a
;; mutable borrow of a by-value local is a temporary written back after the
;; call, so a result keeping that borrow's lifetime is rejected. The view keeps
;; the mutable borrow alive (as in Rust), so it is used on its own before the
;; item is borrowed again.
(define (main) : i64
  (let
    [holder : (Box ElisionItem) (box (ElisionItem 41))]
    [view-ok : bool
      (let
        [view (increment-and-view (&mut (deref holder)))]
        [views : (Array (& holder ElisionItem) 1) (array view)]
        (and
          (= view.value 42)
          (same-value? view view)
          (= (__tl-project-field (tuple-ref (tuple-view view) 0) value) 42)
          (= (__tl-project-field (array-ref (array-view views) 0) value) 42)
          (=
            (call-view
              (lambda ([value : (& ElisionItem)]) : (& ElisionItem)
                value)
              view)
            42)))]
    [item : (& holder ElisionItem) (& (deref holder))]
    (if (and
      view-ok
      (same-value? item item)
      (= (__tl-project-field (shared-left item item) value) 42)
      (mixed-inputs? item item))
      42
      1)))