;: SPEC borrow contract: a nested lexical mutable reborrow ends with the inner
;: scope, so the outer mutable reference is usable again afterward.
;: Compatibility exception for #3772: borrow-place syntax still requires the
;: bare array-ref alias until qualified array macro calls become places.
(import stdlib.array)

(define (touch [slot : (&mut items i64)]) : unit
  unit)

(define (use [items : (&mut items (Array i64))]) : unit
  (begin
    (let
      [slot : (&mut items i64) (&mut (array-ref items 0))]
      (touch slot))
    (array.array-set! items 0 7)))

(define (main [items : (Array i64)]) : unit
  (use (&mut items)))