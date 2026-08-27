;: SPEC safe-code contract: private dynamic-buffer mutable borrows reserve
;: before activation (#3581 keeps this surface staged).

(define (read-len [items : (& items (__tl_dyn-array i64))]) : i64
  (array-length items))

(define (push-with-len
  [items : (&mut items (__tl_dyn-array i64))]
  [value : i64]) : unit
  (__tl_array-push! items value))

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (push-with-len (&mut items) (read-len (& items)))
      (push-with-len (&mut items) (array-length items))
      (array-length items))))