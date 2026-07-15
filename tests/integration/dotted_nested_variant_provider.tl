;; Provider for the transitive dotted-module nested-variant regression.
(defenum DottedNestedVariant
  (None)
  (Some i64))

(defenum DottedNestedEnvelope
  (Wrap DottedNestedVariant))

(defenum DottedNestedRoot
  (Root DottedNestedEnvelope))

(define (dotted-nested-variant-some [value : i64]) : DottedNestedRoot
  (DottedNestedRoot.Root
    (DottedNestedEnvelope.Wrap (DottedNestedVariant.Some value))))