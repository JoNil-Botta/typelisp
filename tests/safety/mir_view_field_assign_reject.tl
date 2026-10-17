;; A field read through a view is reached through the view's loan: replacing
;; the viewed part while the view is still used is rejected (legacy accepted
;; it and read the replaced storage).
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
    [inner : (& outer ViewInner) (& shared.inner)]
    (begin
      (set! outer.inner (ViewInner (__tl_make-array i64 5) 1))
      (array-length inner.items))))