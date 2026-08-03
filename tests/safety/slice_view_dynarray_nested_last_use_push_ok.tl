;; A nested shared child over dynamic storage releases the owner before growth.
(import stdlib.array)

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 1)]
    (begin
      (array-set! items 0 7)
      (let
        [parent : (& items (Slice i64)) (slice-view items 0 1)]
        [child : (& items (Slice i64)) (slice-view parent 0 1)]
        (begin
          (array-ref child 0)
          (array-push! items 35)
          (if (= (array-length items) 2)
            42
            1))))))