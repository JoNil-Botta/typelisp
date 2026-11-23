(define (main) : i64
  (with-arena
    a
    (let
      [items (__tl_make-array i64 4)]
      [left (slice-mut-view items 0 2)]
      [right (slice-mut-view items 0 2)]
      (set! (array-ref left 0) 1)
      (array-ref right 0))))