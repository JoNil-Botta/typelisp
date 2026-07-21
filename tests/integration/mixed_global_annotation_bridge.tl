(import mixed_global_annotation_provider as provider)

(define (mixed-global-annotation-bridge) : i64
  (+
    (provider.mixed-global-annotation-items-len)
    (provider.mixed-global-annotation-result-value)))