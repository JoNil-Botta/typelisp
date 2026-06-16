(import "stdlib/test.tl")
(import "stdlib/cpu.tl")

;; Host-independent invariants for the cpuid/xgetbv-based SIMD detector. The
;; concrete avx2/avx512f/avx512bw answers depend on the running CPU, so this fixture only
;; asserts relationships that hold on every x86-64 host (vacuously on hosts
;; without the feature) while exercising the whole detection path so a broken
;; cpuid/xgetbv lowering shows up as a build/run failure.
(define (main) : i64
  (begin
    ;; CPUID.0:EAX (max standard leaf) is a small non-negative integer.
    (assert-true (>= (cpu-max-leaf) 0) "cpu-max-leaf is non-negative")
    ;; "runnable" always implies the underlying CPUID feature bit.
    (assert-true
      (if (cpu-runs-avx2?)
        (cpu-has-avx2?)
        true)
      "runs-avx2 implies has-avx2")
    (assert-true
      (if (cpu-runs-avx512f?)
        (cpu-has-avx512f?)
        true)
      "runs-avx512f implies has-avx512f")
    (assert-true
      (if (cpu-runs-avx512bw?)
        (cpu-has-avx512bw?)
        true)
      "runs-avx512bw implies has-avx512bw")
    (assert-true
      (if (cpu-runs-avx512bw?)
        (cpu-runs-avx512f?)
        true)
      "runs-avx512bw implies runs-avx512f")
    ;; XCR0 ZMM enablement (0xe6) is a superset of YMM enablement (0x6).
    (assert-true
      (if (cpu-zmm-enabled?)
        (cpu-ymm-enabled?)
        true)
      "zmm-enabled implies ymm-enabled")
    ;; AVX-512F requires AVX2, so a runnable AVX-512F host is always a runnable
    ;; AVX2 host.
    (assert-true
      (if (cpu-runs-avx512f?)
        (cpu-runs-avx2?)
        true)
      "runs-avx512f implies runs-avx2")
    ;; A runnable ISA requires OS XSAVE enablement.
    (assert-true
      (if (cpu-runs-avx2?)
        (cpu-osxsave?)
        true)
      "runs-avx2 implies osxsave")
    42))