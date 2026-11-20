;; A DynArray created in the same with-arena grows there: its storage and its
;; buffer share the arena's region (#9806 twin).
(define (main) : i64
  (with-arena
    r
    (let
      [items : (__tl_dyn-array i64) (__tl_make-array 1 2)]
      (begin
        (__tl_array-push! items 3)
        (if (= (array-ref items 2) 3)
          42
          7)))))