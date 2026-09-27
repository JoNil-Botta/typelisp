;; This module declares its own `MacroTemplateShape`. The provider macro's
;; template patterns still name the provider's enum when they expand here.
(import macro_template_variant_provider as provider)

(defenum MacroTemplateShape
  (Dot i64)
  (Other))

(define (local-shape-value [shape : MacroTemplateShape]) : i64
  (match shape
    [(MacroTemplateShape.Dot a) a]
    [(MacroTemplateShape.Other) 0]))

(define (triple [x : i64]) : i64
  (* x 3))

(define (pattern-template-total) : i64
  (+
    (provider.macro-template-shape-sum
      (provider.macro-template-shape-map
        (provider.MacroTemplateShape.Pair 4 9)
        triple))
    (local-shape-value (MacroTemplateShape.Dot 3))))