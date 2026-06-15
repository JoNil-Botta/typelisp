(import stdlib.test)

(import stdlib.cpu)

;; Host-independent invariants for the cpuid/xgetbv-based SIMD detector. The
;; concrete avx2/avx512f/avx512bw answers depend on the running CPU, so this fixture only
;; asserts relationships that hold on every x86-64 host (vacuously on hosts
;; without the feature) while exercising the whole detection path so a broken
;; cpuid/xgetbv lowering shows up as a build/run failure.
(define (main) : i64
  (begin
    ;; CPUID.0:EAX (max standard leaf) is a small non-negative integer.
    (test.assert-true (>= (cpu.cpu-max-leaf) 0) "cpu-max-leaf is non-negative")
    ;; "runnable" always implies the underlying CPUID feature bit.
    (test.assert-true
      (if (cpu.cpu-runs-avx2?)
        (cpu.cpu-has-avx2?)
        true)
      "runs-avx2 implies has-avx2")
    (test.assert-true
      (if (cpu.cpu-runs-avx512f?)
        (cpu.cpu-has-avx512f?)
        true)
      "runs-avx512f implies has-avx512f")
    (test.assert-true
      (if (cpu.cpu-runs-avx512bw?)
        (cpu.cpu-has-avx512bw?)
        true)
      "runs-avx512bw implies has-avx512bw")
    (test.assert-true
      (if (cpu.cpu-runs-avx512bw?)
        (cpu.cpu-runs-avx512f?)
        true)
      "runs-avx512bw implies runs-avx512f")
    ;; XCR0 ZMM enablement (0xe6) is a superset of YMM enablement (0x6).
    (test.assert-true
      (if (cpu.cpu-zmm-enabled?)
        (cpu.cpu-ymm-enabled?)
        true)
      "zmm-enabled implies ymm-enabled")
    ;; AVX-512F requires AVX2, so a runnable AVX-512F host is always a runnable
    ;; AVX2 host.
    (test.assert-true
      (if (cpu.cpu-runs-avx512f?)
        (cpu.cpu-runs-avx2?)
        true)
      "runs-avx512f implies runs-avx2")
    ;; A runnable ISA requires OS XSAVE enablement.
    (test.assert-true
      (if (cpu.cpu-runs-avx2?)
        (cpu.cpu-osxsave?)
        true)
      "runs-avx2 implies osxsave")
    42))