(import cpu_query_selected_import_other.f as xgetbv)
(import cpu_query_selected_import_other.g as cpuid-eax)
(import cpu_query_selected_import_other.h as cpuid)

(define (run-selected) : i64
  (let
    [regs (cpuid 10 20)]
    (if (and
      (= (cast (tuple-ref regs 0) : i64) 11)
      (= (cast (tuple-ref regs 1) : i64) 22)
      (= (cast (tuple-ref regs 2) : i64) 3)
      (= (cast (tuple-ref regs 3) : i64) 4)
      (= (xgetbv 0) 17)
      (= (cpuid-eax 0 0) 25))
      42
      1)))