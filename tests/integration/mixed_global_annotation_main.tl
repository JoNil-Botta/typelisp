(import mixed_global_annotation_provider as provider)
(import mixed_global_annotation_bridge as bridge)

(define (main) : i64
  (let
    [items : (__tl_dyn-array provider.MixedGlobalAnnotationItem)
      (bridge.mixed-global-annotation-bridge-items)]
    (+ (array-length items) (bridge.mixed-global-annotation-bridge))))