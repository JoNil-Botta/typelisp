;; stdlib/cpu.tl - host CPU SIMD ISA detection via the cpuid/xgetbv primitives.
;;
;; Mirrors the retired scripts/simd_cpuid_probe.c (refs #1168, built on the
;; #1167 cpuid/xgetbv runtime primitives). A SIMD ISA is reported "runnable"
;; only when BOTH the CPUID feature bit AND the OS XSAVE state enablement (XCR0
;; via XGETBV) are present -- i.e. the running host can actually execute it, not
;; merely that the CPU advertises the feature.
;;
;; `(cpuid leaf subleaf)` returns a (Tuple i32 i32 i32 i32) of (eax ebx ecx edx);
;; `(xgetbv index)` returns the 64-bit XCR value. Register values are widened to
;; i64 before bit testing; single-bit tests use `(bit-and (shr v n) 1)` so the
;; sign of the widening cast is irrelevant.
;; CPUID.1:ECX bit 27 = OSXSAVE: the OS enabled XSAVE and the XGETBV instruction.
(define (cpu-osxsave?) : bool
  (let
    [r1 : (Tuple i32 i32 i32 i32) (cpuid 1 0)]
    (= (bit-and (shr (cast (tuple-ref r1 2) : i64) 27) 1) 1)))

;; XCR0 (XGETBV index 0). Reading XCR0 is only valid once OSXSAVE is set, so
;; return 0 otherwise (matching the C probe's `osxsave ? xgetbv0() : 0`).
(define (cpu-xcr0) : i64
  (if (cpu-osxsave?)
    (xgetbv 0)
    0))

;; Highest standard CPUID leaf (CPUID.0:EAX). Leaf 7 carries the AVX2/AVX512F
;; feature bits, so it must be available before they are queried.
(define (cpu-max-leaf) : i64
  (let
    [r0 : (Tuple i32 i32 i32 i32) (cpuid 0 0)]
    (cast (tuple-ref r0 0) : i64)))

;; XCR0 bit1 = SSE/XMM, bit2 = AVX/YMM. 0x6 means YMM state is enabled.
(define (cpu-ymm-enabled?) : bool
  (= (bit-and (cpu-xcr0) 6) 6))

;; XCR0 0xe6 = SSE | AVX | opmask | ZMM_Hi256 | Hi16_ZMM: ZMM state is enabled.
(define (cpu-zmm-enabled?) : bool
  (= (bit-and (cpu-xcr0) 230) 230))

;; CPUID.7.0:EBX bit 5 = AVX2.
(define (cpu-has-avx2?) : bool
  (if (>= (cpu-max-leaf) 7)
    (let
      [r7 : (Tuple i32 i32 i32 i32) (cpuid 7 0)]
      (= (bit-and (shr (cast (tuple-ref r7 1) : i64) 5) 1) 1))
    false))

;; CPUID.7.0:EBX bit 16 = AVX512F.
(define (cpu-has-avx512f?) : bool
  (if (>= (cpu-max-leaf) 7)
    (let
      [r7 : (Tuple i32 i32 i32 i32) (cpuid 7 0)]
      (= (bit-and (shr (cast (tuple-ref r7 1) : i64) 16) 1) 1))
    false))

;; AVX2 is runnable when the CPU advertises it and the OS has enabled YMM state.
(define (cpu-runs-avx2?) : bool
  (and (cpu-has-avx2?) (cpu-ymm-enabled?)))

;; AVX-512 Foundation is runnable when advertised and ZMM/opmask state is enabled.
(define (cpu-runs-avx512f?) : bool
  (and (cpu-has-avx512f?) (cpu-zmm-enabled?)))