;; Transitional bare array helper alias coverage for #3772.
;;
;; This fixture intentionally does not import `stdlib.array`. It proves the
;; parser/typechecker compatibility aliases still work until the final alias
;; removal issue removes or inverts this test.
(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    (begin
      (array-set! items 0 40)
      (array-push! items 2)
      (if (= (array-length items) 2)
        (+ (array-ref items 0) (array-ref items 1))
        1))))