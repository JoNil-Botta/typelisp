;; A Slice view of arena-backed dynamic storage cannot escape with-arena.
(import stdlib.array)

(define (bad [seed : (& outer (Slice i64))]) : (& outer (Slice i64))
  (begin
    (array-length seed)
    (with-arena
      phase
      (let
        [items : (__tl_dyn-array i64) (array.make-array i64 1)]
        (slice-view (& phase items) 0 1)))))

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 1)]
    (array-length (bad (slice-view items 0 1)))))