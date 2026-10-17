;: An explicit owned annotation cannot move the non-Copy index out of a
;: shared context reference. Borrowing the field is required before using it
;: as a persistent view or passing it onward (#8449).
(defstruct Csr
  (offsets (__tl_dyn-array i64)))

(defstruct Index
  (labels (__tl_dyn-array i64))
  (preds Csr))

(defstruct Ctx
  (index Index)
  (entry i64))

(define (lookup [index : (& index Index)] [label : i64]) : i64
  (array-ref index.labels label))

(define (f [context : (& context Ctx)]) : bool
  (let
    [index : Index context.index]
    [id : i64 (lookup index context.entry)]
    [preds : Csr index.preds]
    [offsets : (__tl_dyn-array i64) preds.offsets]
    (= (- (array-ref offsets (+ id 1)) (array-ref offsets id)) 0)))

(define (main) : i64
  (let
    [c : Ctx
      (Ctx (Index (__tl_make-array i64 2) (Csr (__tl_make-array i64 2))) 0)]
    (if (f (& c))
      42
      1)))