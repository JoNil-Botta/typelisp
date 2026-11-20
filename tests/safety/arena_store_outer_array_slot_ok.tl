;; Writing an i64 through a `&mut` into an existing slot of an outer DynArray
;; inside with-arena stores no allocation, so the Copy exemption keeps it
;; accepted (#9806 twin).
(define (put-first [items : (&mut items (__tl_dyn-array i64))]) : unit
  (set! (array-ref items 0) 3))

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array 1 2)]
    (begin
      (with-arena r (put-first (&mut items)))
      (if (= (array-ref items 0) 3)
        42
        7))))