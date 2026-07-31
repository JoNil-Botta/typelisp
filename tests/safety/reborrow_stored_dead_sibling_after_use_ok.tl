;: A child-scope borrow that is dead before the returned reference is built
;: does not protect a disjoint sibling merely because both share an owner
;: lifetime.
(defstruct ReborrowDeadSiblingArrays
  (left (__tl_dyn-array i64))
  (right (__tl_dyn-array i64)))

(define (consume [value : (& owner i64)]) : unit
  unit)

(define (main) : unit
  (let
    [pair : ReborrowDeadSiblingArrays
      (ReborrowDeadSiblingArrays (make-array i64 1) (make-array i64 1))]
    (let
      [result : (& pair i64)
        (let
          [temporary : (& pair i64) (& (array-ref (struct-get pair left) 0))]
          (begin
            (consume temporary)
            (& (array-ref (struct-get pair right) 0))))]
      (begin
        (array-set! (struct-get pair left) 0 42)
        (consume result)))))