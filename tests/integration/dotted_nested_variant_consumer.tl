;; A dotted module must lower nested variants from its own dotted dependency.
(import dotted_nested_variant_provider as provider)

(define (dotted-nested-variant-value [value : provider.DottedNestedRoot]) : i64
  (match value
    [(provider.DottedNestedRoot.Root
        (provider.DottedNestedEnvelope.Wrap
          (provider.DottedNestedVariant.Some inner)))
      inner]
    [_ 0]))