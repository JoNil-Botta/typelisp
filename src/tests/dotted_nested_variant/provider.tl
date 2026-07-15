(module dotted_nested_variant.provider)

(defenum Inner
  (None)
  (Some i64))

(defenum Middle
  (Empty)
  (Wrap Inner))

(defenum Outer
  (Empty)
  (Wrap Middle))