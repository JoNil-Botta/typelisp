;; Reborrow array elements through reference-bearing iterator state. A shared
;; stored reference is copied out, so its item keeps the stored source
;; lifetime, not the iterator-state borrow; a mutable one lends from the
;; iterator (#8449).
(defstruct SharedIter
  (:lifetimes source)
  (slots (& source (__tl_dyn-array i64)))
  (index i64))

(defenum SharedNext
  (:lifetimes source)
  (Done)
  (Item (& source i64)))

(define (shared-next [iter : (&mut state (SharedIter source))]) : (SharedNext
    source)
  (let
    [index : i64 iter.index]
    (if (>= index 1)
      (SharedNext.Done)
      (begin
        (set! iter.index (+ index 1))
        (SharedNext.Item (& (array-ref iter.slots index)))))))

(defstruct SharedHolder
  (:lifetimes source)
  (iter (SharedIter source)))

(define (shared-nested-item [holder : (&mut state (SharedHolder source))]) : (&
    source
    i64)
  (& (array-ref holder.iter.slots 0)))

(define (shared-tuple-item
  [pair : (&mut state (Tuple (& source (__tl_dyn-array i64))))]) : (&
    source
    i64)
  (& (array-ref (tuple-ref pair 0) 0)))

(defstruct MutIter
  (:lifetimes source)
  (slots (&mut source (__tl_dyn-array i64)))
  (index i64))

(defenum MutNext
  (:lifetimes item)
  (Done)
  (Item (&mut item i64)))

;; A mutable item borrows the iterator it was reborrowed through (#8449).
(define (mut-next [iter : (&mut item (MutIter source))]) : (MutNext item)
  (let
    [index : i64 iter.index]
    (if (>= index 1)
      (MutNext.Done)
      (begin
        (set! iter.index (+ index 1))
        (MutNext.Item (&mut (array-ref iter.slots index)))))))

(define (main) : i64
  0)