(module dotted_nested_variant.main)

(import dotted_nested_variant.consumer)
(import dotted_nested_variant.provider)

(define (main) : i64
  (if (=
    (consumer.score
      (provider.Outer.Wrap (provider.Middle.Wrap (provider.Inner.Some 42))))
    42)
    0
    1))