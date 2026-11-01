;: A by-value match moves only in arms that bind a non-Copy payload: the End
;: arm binds only a Copy count and leaves the cursor initialized for the next
;: loop test.
(defenum Chain
  (End i64)
  (Next (__tl_dyn-array i64) (Box Chain)))

(define (count [start : Chain]) : i64
  (let
    [cursor : Chain start]
    [more : bool true]
    [total : i64 0]
    (begin
      (while more
        (match cursor
          [(Chain.End extra)
            (begin
              (set! total (+ total extra))
              (set! more false))]
          [(Chain.Next items rest)
            (begin
              (set! total (+ total (array-length items)))
              (set! cursor (deref rest)))]))
      total)))

(define (main) : i64
  (count (Chain.Next (__tl_make-array i64 42) (box (Chain.End 0)))))