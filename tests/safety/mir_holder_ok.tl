;: A lifetime-parameterized aggregate built from a borrow carries its loan.
(defstruct Holder
  (:lifetimes src)
  (items (& src (__tl_dyn-array i64)))
  (count i64))

(define (count-of [h : (& h (Holder src))]) : i64
  h.count)

(define (items-of [h : (Holder src)]) : i64
  (array-length h.items))

(define (local-holder) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [h : (Holder items) (Holder items 2)]
    (+ (array-length h.items) h.count)))

(define (main) : i64
  (local-holder))