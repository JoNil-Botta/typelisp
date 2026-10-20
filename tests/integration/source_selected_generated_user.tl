;; A selected macro alias belongs to its importer, including non-entry modules.
(import source_selected_generated_dep.generated-answer as renamed-answer)

(define (answer) : i64
  (renamed-answer))