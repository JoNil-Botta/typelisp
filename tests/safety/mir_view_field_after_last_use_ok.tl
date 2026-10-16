;; The view's loan ends with its last use: replacing the viewed part after
;; reading a field through the view is accepted.
(defstruct ViewInner
  (items (__tl_dyn-array i64))
  (count i64))

(defstruct ViewOuter
  (inner ViewInner)
  (label i64))

(define (main) : i64
  (let
    [outer : ViewOuter (ViewOuter (ViewInner (__tl_make-array i64 40) 2) 0)]
    [shared : (& outer ViewOuter) (& outer)]
    [inner : (& outer ViewInner) (& shared.inner)]
    [length : i64 (+ (array-length inner.items) inner.count)]
    (begin
      (set! outer.inner (ViewInner (__tl_make-array i64 5) 1))
      length)))