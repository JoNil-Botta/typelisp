;: A flag that ends the loop does not reinitialize the cursor an arm moved
;: out of: the loop condition still flows back to the match.
(defenum Chain
  (Leaf (__tl_dyn-array i64))
  (Next (__tl_dyn-array i64) (Box Chain)))

(define (count [start : Chain]) : i64
  (let
    [cursor : Chain start]
    [more : bool true]
    [total : i64 0]
    (begin
      (while more
        (match cursor
          [(Chain.Leaf items)
            (begin
              (set! total (+ total (array-length items)))
              (set! more false))]
          [(Chain.Next items rest)
            (begin
              (set! total (+ total (array-length items)))
              (set! cursor (deref rest)))]))
      total)))

(define (main) : i64
  0)