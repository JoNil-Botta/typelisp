;; refs #1867/#3581: private dynamic-buffer `array-push!` of an inline
;; struct element byte-copies the whole element into the correctly-strided slot
;; instead of truncating to 8 bytes / striding by 8. main returns 42 only when
;; both pushed structs read back through array-ref with their fields intact.
(defstruct P
  (x i64)
  (y i64))

(define (main) : i64
  (let
    [a : (__tl_dyn-array P) (__tl_make-array P 0)]
    (begin
      (__tl_array-push! a (P 30 5))
      (__tl_array-push! a (P 100 7))
      (+
        (__tl-project-field (array-ref a 0) x)
        (+
          (__tl-project-field (array-ref a 0) y)
          (__tl-project-field (array-ref a 1) y))))))