;; Historical compatibility-fixture path retained for harness continuity.
;;
;; Public dynamic-array aliases are rejected by parser self-tests. This fixture
;; proves the private compiler/runtime spellings retain their behavior.
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (set! (array-ref items 0) 40)
      (__tl_array-push! items 2)
      (if (= (array-length items) 2)
        (+ (array-ref items 0) (array-ref items 1))
        1))))