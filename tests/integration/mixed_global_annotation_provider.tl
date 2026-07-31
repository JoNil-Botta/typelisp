(import stdlib.array)

(defenum MixedGlobalAnnotationItem
  (Value i64))

(defstruct MixedGlobalAnnotationNode
  (value i64))

(defenum MixedGlobalAnnotationResult
  (Ok MixedGlobalAnnotationNode))

(define mixed-global-annotation-items : (__tl_dyn-array
    MixedGlobalAnnotationItem)
  (array.make-array MixedGlobalAnnotationItem 1))

(define (mixed-global-annotation-items-len) : i64
  (let
    [items : (__tl_dyn-array MixedGlobalAnnotationItem)
      mixed-global-annotation-items]
    (array-length items)))

(define (mixed-global-annotation-node [value : i64]) : MixedGlobalAnnotationNode
  (MixedGlobalAnnotationNode value))

(define (mixed-global-annotation-result [remaining : i64]) : MixedGlobalAnnotationResult
  (if (<= remaining 0)
    (MixedGlobalAnnotationResult.Ok (mixed-global-annotation-node 40))
    (mixed-global-annotation-result (- remaining 1))))

(define (mixed-global-annotation-result-value) : i64
  (match (mixed-global-annotation-result 1)
    [(MixedGlobalAnnotationResult.Ok node) (struct-get node value)]))