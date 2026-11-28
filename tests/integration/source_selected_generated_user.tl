;; Generated selected and wildcard aliases both belong to their importer.
(import source_selected_generated_dep.generated-answer as renamed-answer)
(import source_selected_generated_dep.*)
(import source_selected_generated_dep as dep)

(define (check-imports) : i64
  (if (= (generated-answer) (dep.generated-answer))
    (renamed-answer)
    1))