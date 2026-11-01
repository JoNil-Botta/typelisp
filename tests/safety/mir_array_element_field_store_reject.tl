;: A reference stored into a field of an owned array element is held by the
;: array: writing its referent while the element is read later conflicts
;: (Rust E0506, #8449).
(defstruct Item
  (:lifetimes source)
  (cell (& source i64)))

(defstruct P
  (l i64)
  (r i64))

(define (main) : i64
  (let
    [p : P (P 1 2)]
    [items : (__tl_dyn-array (Item p)) (init : (__tl_dyn-array (Item p)))]
    (begin
      (__tl_array-push! items (Item (& p.l)))
      (set! (array-ref items 0).cell (& p.r))
      (set! p.r 5)
      (deref (array-ref items 0).cell))))