(module dotted_nested_variant.consumer)

(import dotted_nested_variant.provider)

(define (score [outer : provider.Outer]) : i64
  (match outer
    [(provider.Outer.Wrap (provider.Middle.Wrap (provider.Inner.Some value)))
      value]
    [(provider.Outer.Wrap _) 1]
    [provider.Outer.Empty 0]))