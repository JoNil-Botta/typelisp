;; A Slice view of local fixed storage cannot be returned with an outer lifetime.
(define (bad [seed : (& outer i64)]) : (& outer (Slice i64))
  (let
    [items : (Array i64 2) (array 10 20)]
    (slice-view items 0 2)))

(define (main) : i64
  (let
    [seed : i64 1]
    (array-ref (bad (& seed)) 0)))