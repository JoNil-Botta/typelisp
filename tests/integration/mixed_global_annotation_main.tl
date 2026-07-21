(import "mixed_global_annotation_provider.tl")
(import "mixed_global_annotation_bridge.tl")

(define (main) : i64
  (let
    [items : (Array MixedGlobalAnnotationItem)
      (mixed-global-annotation-bridge-items)]
    (+ (array-length items) (mixed-global-annotation-bridge))))