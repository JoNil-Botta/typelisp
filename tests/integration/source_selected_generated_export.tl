;; Source selected imports whose items exist only after the provider's
;; module-scope generators have run (#7807). The qualified import of the same
;; module comes second on purpose: the selected imports must not depend on the
;; module having been seen already, and must not break it afterwards.
;; The `lint-allow` lines cover #7865: lint reports a selected import as
;; unused even when its bare name is referenced.
;; lint-allow: unused-import
(import source_selected_generated_dep.answer)

;; lint-allow: unused-import
(import source_selected_generated_dep.twice)

;; lint-allow: unused-import
(import source_selected_generated_dep.Pair)

;; lint-allow: unused-import
(import source_selected_generated_dep.Shape)

;; lint-allow: unused-import
(import source_selected_generated_dep.Line)

;; lint-allow: unused-import
(import source_selected_generated_dep.Dot)

;; lint-allow: unused-import
(import source_selected_generated_dep.scaled)

;; lint-allow: unused-import
(import source_selected_generated_dep.deep)

;; lint-allow: unused-import
(import source_selected_generated_dep.host-bias)

;; lint-allow: unused-import
(import source_selected_generated_dep.answer as again)
(import source_selected_generated_dep as dep)

(define (weight [shape : Shape]) : i64
  (match shape
    [(Dot) 0]
    [(Line n) n]))

(define (main) : i64
  (let
    [pair : Pair (Pair (twice 2) deep)]
    ;; 20 + 4 + 5 + 6 + 1 + 3 + 3 + (20 - 20)
    (+
      answer
      (+
        pair.left
        (+
          pair.right
          (+
            scaled
            (+
              host-bias
              (+
                (weight (Line 3))
                (+
                  (+ (weight (dep.Line 3)) (weight (Dot)))
                  (- again dep.answer))))))))))