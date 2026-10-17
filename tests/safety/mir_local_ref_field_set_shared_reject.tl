;: An element write into a field reached through a local shared reference.
(defstruct Cache
  (ready (__tl_dyn-array bool)))

(define (main) : i64
  (let
    [cache : Cache (Cache (__tl_make-array bool 1))]
    [r : (& cache Cache) (& cache)]
    (begin
      (set! (array-ref r.ready 0) true)
      0)))