;; A non-Copy field reached through a shared reference cannot initialize an
;; owned local. It must be borrowed explicitly to keep a field view.
;; The rejection precedes any later mutation of the owning aggregate.
(defstruct ViewInner
  (items (__tl_dyn-array i64))
  (count i64))

(defstruct ViewOuter
  (inner ViewInner)
  (label i64))

(define (main) : i64
  (let
    [outer : ViewOuter (ViewOuter (ViewInner (__tl_make-array i64 2) 3) 0)]
    [shared : (& outer ViewOuter) (& outer)]
    [inner : ViewInner shared.inner]
    (begin
      (set! outer.inner (ViewInner (__tl_make-array i64 5) 1))
      (array-length inner.items))))