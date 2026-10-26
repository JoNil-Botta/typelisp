;: Binding a non-Copy payload of a struct field by value moves it out of the
;: field, so matching the field again on the next trip uses a moved value
;: (Rust's E0382). The legacy checker accepted a field scrutinee (#8449).
(defstruct Holder
  (xs (__tl_dyn-array i64)))

(defenum Val
  (Num i64)
  (Hold Holder))

(defstruct Wrap
  (tag i64)
  (val Val))

(define (main) : i64
  (let
    [w : Wrap (Wrap 7 (Val.Hold (Holder (__tl_make-array i64 4))))]
    [i : i64 0]
    [sum : i64 0]
    (while (< i 3)
      (match w.val
        [(Val.Hold h) (set! sum (+ sum (array-length h.xs)))]
        [(Val.Num _) (set! sum (+ sum 1))])
      (set! i (+ i 1)))
    sum))