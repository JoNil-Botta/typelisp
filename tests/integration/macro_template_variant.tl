;; The provider's macro template constructs the provider's enum, which this
;; module sees only as `provider.MacroTemplateShape`.
(import macro_template_variant_provider as provider)

(define (triple [x : i64]) : i64
  (* x 3))

(define (main) : i64
  (provider.macro-template-shape-sum
    (provider.macro-template-shape-map
      (provider.MacroTemplateShape.Pair 4 10)
      triple)))