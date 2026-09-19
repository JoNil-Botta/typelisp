;; An already loaded generating module must not suppress the final check.
(import source_selected_generated_provider as provider)
(import source_selected_generated_provider.nothing as value)

(define (main) : i64
  provider.answer)