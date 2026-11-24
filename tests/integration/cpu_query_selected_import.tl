(import cpu_query_selected_import_dep as dep)
(import cpu_query_intrinsics_dep as hw)

(define (main) : i64
  (if (hw.hardware-queries-ok?)
    (dep.run-selected)
    2))