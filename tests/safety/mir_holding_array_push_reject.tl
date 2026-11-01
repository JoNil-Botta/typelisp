;; An array of records holding references holds their loans.
(defstruct Item
  (:lifetimes source)
  (cell (& source i64)))

(define (bump [cell : (&mut cell i64)]) : unit
  (set! (deref cell) (+ (deref cell) 1)))

(define (main) : i64
  (let
    [value : i64 41]
    [items : (__tl_dyn-array (Item value))
      (init : (__tl_dyn-array (Item value)))]
    (begin
      (__tl_array-push! items (Item (& value)))
      (bump (&mut value))
      (array-length items))))