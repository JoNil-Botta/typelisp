(import mixed_global_annotation_provider as provider)

(define (mixed-global-annotation-bridge-items) : (__tl_dyn-array
    provider.MixedGlobalAnnotationItem)
  provider.mixed-global-annotation-items)

(define (mixed-global-annotation-bridge) : i64
  (+
    (provider.mixed-global-annotation-items-len)
    (provider.mixed-global-annotation-result-value)))