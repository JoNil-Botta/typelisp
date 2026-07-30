;: SPEC borrow contract: a nested lexical mutable reborrow ends with the inner
;: scope, so the outer mutable reference is usable again afterward.
(import stdlib.array)

(define (touch [slot : (&mut items i64)]) : unit
  unit)

(define (use [items : (&mut items (__tl_dyn-array i64))]) : unit
  (begin
    (let
      [slot : (&mut items i64) (&mut (array-ref items 0))]
      (touch slot))
    (array-set! items 0 7)))

(define (main [items : (__tl_dyn-array i64)]) : unit
  (use (&mut items)))