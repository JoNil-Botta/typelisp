;; refs #6053: making an input alias visible locally must not let a local owner
;; escape as though it had the input lifetime.
(define (bad [value : (& source i64)]) : (& source i64)
  (let
    [local : i64 1]
    (& source local)))