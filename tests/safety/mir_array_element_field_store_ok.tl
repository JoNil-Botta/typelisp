;: As `mir_array_element_field_store_reject`, but the referent is written
;: after the element's last read (#8449). Main rejected this valid program.
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
      (let
        [seen : i64 (deref (array-ref items 0).cell)]
        (set! p.r 40)
        (+ seen p.r)))))