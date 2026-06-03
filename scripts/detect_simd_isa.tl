;; scripts/detect_simd_isa.tl - print the host CPU's runnable SIMD ISAs, one
;; lowercase token per line (`avx2` and/or `avx512f`).
;;
;; This is the TypeLisp replacement for the retired scripts/simd_cpuid_probe.c
;; (refs #1168): scripts/detect-simd-isa.sh builds and runs it on hosts without
;; /proc/cpuinfo (Windows) so SIMD *execution* tests gate on real CPU+OS
;; capability rather than host OS. The detection logic lives in stdlib/cpu.tl.
(import "stdlib/io.tl")

(import "stdlib/cpu.tl")

(define (main) : i64
  (begin
    (if (cpu-runs-avx2?)
      (print-string "avx2\n")
      unit)
    (if (cpu-runs-avx512f?)
      (print-string "avx512f\n")
      unit)
    0))
