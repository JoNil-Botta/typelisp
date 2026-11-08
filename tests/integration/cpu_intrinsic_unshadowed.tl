;; Keep both intrinsic instructions observable without executing XGETBV on a
;; host that may not support it. The target-parity gate checks both targets.
(defmacro (read-xcr [index : Expr]) : Expr
  `(xgetbv ,index))

(define (read-xcr-direct [index : i64])
  (:export-symbol "cpu_xcr_direct") : i64
  (xgetbv index))

(define (read-xcr-template [index : i64])
  (:export-symbol "cpu_xcr_template") : i64
  (read-xcr index))

(define (read-cpu [leaf : i64] [subleaf : i64])
  (:export-symbol "cpu_leaf") : (Tuple i32 i32 i32 i32)
  (cpuid leaf subleaf))

(define (read-cpu-words [leaf : i64] [subleaf : i64])
  (:export-symbol "cpu_leaf_words") : i64
  (+
    (+ (cpuid-eax leaf subleaf) (cpuid-ebx leaf subleaf))
    (+ (cpuid-ecx leaf subleaf) (cpuid-edx leaf subleaf))))

(define (main) : i64
  (comptime
    (if false
      (xgetbv 0)
      42)))