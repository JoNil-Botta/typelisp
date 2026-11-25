;; The second module selects the same item under the same alias; its binding is
;; its own and must not be skipped because the first module already has one.
(module selected_import_b)

(import selected_import_dep.value)

(define (fb) : i64
  (+ (value) 1))