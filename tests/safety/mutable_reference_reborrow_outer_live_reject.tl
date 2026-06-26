;: SPEC borrow contract: an outer mutable reference cannot be used while an
;: inner lexical reborrow is still live.
;: Compatibility exception for #3772: borrow-place syntax still requires the
;: bare array-ref alias until qualified array macro calls become places.
(import stdlib.array)

(define (bad [items : (&mut items (Array i64))]) : unit
  (let
    [slot : (&mut items i64) (&mut (array-ref items 0))]
    (array.array-set! items 0 7)))

(define (main [items : (Array i64)]) : unit
  (bad (&mut items)))