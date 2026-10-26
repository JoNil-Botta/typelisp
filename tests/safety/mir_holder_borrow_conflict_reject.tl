;: A holder carrying a shared loan excludes a mutable borrow of its source
;: until its last use.
(defstruct Holder
  (:lifetimes src)
  (items (& src (__tl_dyn-array i64)))
  (count i64))

(define (grow [target : (&mut target (__tl_dyn-array i64))]) : unit
  (__tl_array-push! target 1))

(define (run) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [h : (Holder items) (Holder items 2)]
    (begin
      (grow (&mut items))
      (array-length h.items))))

(define (main) : i64
  0)