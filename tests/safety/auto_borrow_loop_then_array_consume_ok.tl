;: SPEC borrow contract: an implicit borrow in a loop condition ends before
;: the same owned parameter is consumed into an array after the loop.
(import stdlib.string)

(define (insert-once!
  [names : (__tl_dyn-array String)]
  [count : i64]
  [name : String]) : unit
  (let
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (if (string.eq (array-ref names index) name)
          (set! found true)
          (set! index (+ index 1))))
      (if found
        unit
        (array-set! names count name)))))

(define (main [names : (__tl_dyn-array String)] [name : String]) : unit
  (insert-once! names 0 name))