;; The wide-aggregate generator used by the #7921 rows only accepts an integer
;; literal width; anything else is reported instead of declaring nothing.
(import wide_aggregates)

(wide_aggregates.wide-struct Wide "1002")

(define (main) : i64
  0)