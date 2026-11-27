;; Verify `__tl_array-push!` across mutable places: local, struct field,
;; `&mut` parameter, boxed place, and nested dynamic-array element place with
;; side-effecting index and value expressions.
(defstruct Holder
  (items (__tl_dyn-array i64)))

(define (push-mut! [items : (&mut items (__tl_dyn-array i64))] [v : i64]) : unit
  (__tl_array-push! items v))

(define (push-holder! [h : (&mut h Holder)] [v : i64]) : unit
  (__tl_array-push! h.items v))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [h : Holder (Holder (__tl_make-array i64 0))]
    [boxed : (Box (__tl_dyn-array i64)) (box (__tl_make-array i64 0))]
    [rows : (__tl_dyn-array (__tl_dyn-array i64))
      (__tl_make-array (__tl_make-array 10) (__tl_make-array 20))]
    [trace : i64 0]
    (__tl_array-push! xs 1)
    (push-mut! (&mut xs) 2)
    (__tl_array-push! h.items 3)
    (push-holder! (&mut h) 4)
    (__tl_array-push! (deref boxed) 5)
    (__tl_array-push!
      (array-ref
        rows
        (begin
          (set! trace (+ (* trace 10) 1))
          1))
      (begin
        (set! trace (+ (* trace 10) 2))
        7))
    (if (and
      (= trace 12)
      (= (array-length xs) 2)
      (= (array-ref xs 0) 1)
      (= (array-ref xs 1) 2)
      (= (array-length h.items) 2)
      (= (array-ref h.items 0) 3)
      (= (array-ref h.items 1) 4)
      (= (array-length (deref boxed)) 1)
      (= (array-ref (deref boxed) 0) 5)
      (= (array-length rows) 2)
      (= (array-length (array-ref rows 0)) 1)
      (= (array-length (array-ref rows 1)) 2)
      (= (array-ref (array-ref rows 1) 0) 20)
      (= (array-ref (array-ref rows 1) 1) 7))
      42
      1)))