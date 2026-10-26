;: Borrow conflicts inside an `in-arena` body are rejected.
(import stdlib.arena)

(define (keep [items : (& items (__tl_dyn-array i64))] [n : i64]) : i64
  (+ (array-length items) n))

(define (overlap [target : arena.Arena] [items : (__tl_dyn-array i64)]) : i64
  (in-arena
    target
    (keep
      (& items)
      (begin
        (set! (array-ref items 0) 1)
        0))))

(define (main) : i64
  0)