;: An element write into a field reached through a shared reference is a
;: mutation through that reference.
(defstruct Cache
  (ready (__tl_dyn-array bool)))

(define (reset [cache : (& cache Cache)]) : unit
  (set! (array-ref cache.ready 0) false))

(define (main) : i64
  0)