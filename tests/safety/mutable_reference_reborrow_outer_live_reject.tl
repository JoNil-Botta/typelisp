;: SPEC borrow contract: an outer mutable reference cannot be used while an
;: inner lexical reborrow is still live.
(import stdlib.array)

(define (bad [items : (&mut items (__tl_dyn-array i64))]) : unit
  (let
    [slot : (&mut items i64) (&mut (array-ref items 0))]
    (array-set! items 0 7)))

(define (main [items : (__tl_dyn-array i64)]) : unit
  (bad (&mut items)))