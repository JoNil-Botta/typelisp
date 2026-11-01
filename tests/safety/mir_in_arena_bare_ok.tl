;: An `in-arena` body over a bare arena handle is checked like any sequence;
;: the handle is a Copy value.
(import stdlib.arena)

(define (allocate-in [target : arena.Arena] [n : i64]) : i64
  (in-arena
    target
    (let
      [items : (__tl_dyn-array i64) (__tl_make-array i64 n)]
      (begin
        (set! (array-ref items 0) 40)
        (+ (array-ref items 0) (array-length items))))))

(define (main) : i64
  (allocate-in (arena.current) 2))