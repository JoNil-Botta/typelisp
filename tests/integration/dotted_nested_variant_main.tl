;; Keep the consumer behind another dotted import so lowering must preserve
;; the consumer module's dependency context.
(import dotted_nested_variant_consumer as consumer)
(import dotted_nested_variant_provider as root-provider)

(define (main) : i64
  (if (=
    (consumer.dotted-nested-variant-value
      (root-provider.dotted-nested-variant-some 42))
    42)
    0
    1))