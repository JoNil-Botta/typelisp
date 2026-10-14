;: `replace!` of an array element returns the reference the element held, so
;: writing its referent while that value is read later conflicts (Rust E0506,
;: #8449).
(defstruct P
  (l i64)
  (r i64))

(define (main) : i64
  (let
    [p : P (P 1 2)]
    [refs : (__tl_dyn-array (& p i64)) (init : (__tl_dyn-array (& p i64)))]
    (begin
      (__tl_array-push! refs (& p.l))
      (let
        [old : (& p i64) (replace! (array-ref refs 0) (& p.r))]
        (set! p.l 5)
        (deref old)))))