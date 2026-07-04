;; scripts/detect_simd_isa.tl - io.print the host CPU's runnable SIMD ISAs, one
;; lowercase token per line (`avx2`, `avx512f`, and/or `avx512bw`).
;;
;; This is the TypeLisp replacement for the retired scripts/simd_cpuid_probe.c
;; (refs #1168): scripts/detect-simd-isa.sh builds and runs it on hosts without
;; /proc/cpuinfo (Windows) so SIMD *execution* tests gate on real CPU+OS
;; capability rather than host OS. The detection logic lives in stdlib/cpu.tl.
(import stdlib.io)
(import stdlib.cpu)

(define (main) : i64
  (begin
    (if (cpu.runs-avx2?)
      (io.print-string "avx2\n")
      unit)
    (if (cpu.runs-avx512f?)
      (io.print-string "avx512f\n")
      unit)
    (if (cpu.runs-avx512bw?)
      (io.print-string "avx512bw\n")
      unit)
    0))