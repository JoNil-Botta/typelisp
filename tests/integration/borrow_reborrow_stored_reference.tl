;; Reborrow array elements through reference-bearing iterator state. The item
;; lifetime must be the stored source lifetime, not the iterator-state borrow.
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
    [index : i64 (struct-get iter index)]
    (if (>= index 1)
      (SharedNext.Done)
      (begin
        (set! (struct-get iter index) (+ index 1))
        (SharedNext.Item (& (array-ref (struct-get iter slots) index)))))))

(defstruct SharedHolder
  (:lifetimes source)
  (iter (SharedIter source)))

(define (shared-nested-item [holder : (&mut state (SharedHolder source))]) : (&
    source
    i64)
  (& (array-ref (struct-get (struct-get holder iter) slots) 0)))

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
  (:lifetimes source)
  (Done)
  (Item (&mut source i64)))

(define (mut-next [iter : (&mut state (MutIter source))]) : (MutNext source)
  (let
    [index : i64 (struct-get iter index)]
    (if (>= index 1)
      (MutNext.Done)
      (begin
        (set! (struct-get iter index) (+ index 1))
        (MutNext.Item (&mut (array-ref (struct-get iter slots) index)))))))

(define (main) : i64
  0)