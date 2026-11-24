(import cpu_query_intrinsics_dep as cpu)

(define (cpuid-eax [_leaf : i64] [_subleaf : i64]) : i64
  7)

(define (cpuid-ebx [_leaf : i64] [_subleaf : i64]) : i64
  7)

(define (cpuid-ecx [_leaf : i64] [_subleaf : i64]) : i64
  7)

(define (cpuid-edx [_leaf : i64] [_subleaf : i64]) : i64
  7)

(define (main) : i64
  (if (and
    (cpu.hardware-queries-ok?)
    (= (cpuid-eax 0 0) 7)
    (= (cpuid-ebx 0 0) 7)
    (= (cpuid-ecx 0 0) 7))
    (cpuid-edx 0 0)
    1))