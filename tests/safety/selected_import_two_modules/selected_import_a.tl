;; The first module to select the item materializes its own alias binding.
(module selected_import_a)

(import selected_import_dep.value)

(define (fa) : i64
  (value))