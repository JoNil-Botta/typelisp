;# stdlib/cpu.tl - host CPU SIMD ISA detection via the cpuid/xgetbv primitives.
;#
;# A SIMD ISA is reported "runnable" only when BOTH the CPUID feature bit AND
;# the OS XSAVE state enablement (XCR0 via XGETBV) are present -- i.e. the
;# running host can actually execute it, not merely that the CPU advertises
;# the feature.
;#
;# `(cpuid leaf subleaf)` returns a (Tuple i32 i32 i32 i32) of (eax ebx ecx edx);
;# `(xgetbv index)` returns the 64-bit XCR value. Register values are widened to
;# i64 before bit testing; single-bit tests use `(bit-and (shr v n) 1)` so the
;# sign of the widening cast is irrelevant.
;#
;# Usage: `(import stdlib.cpu)`
;: Return CPUID EAX for `leaf` and `subleaf`.
(define (cpuid-eax32 [leaf : i64] [subleaf : i64]) : i32
  (cast (cpuid-eax leaf subleaf) : i32))

;: Return CPUID EBX for `leaf` and `subleaf`.
(define (cpuid-ebx32 [leaf : i64] [subleaf : i64]) : i32
  (cast (cpuid-ebx leaf subleaf) : i32))

;: Return CPUID ECX for `leaf` and `subleaf`.
(define (cpuid-ecx32 [leaf : i64] [subleaf : i64]) : i32
  (cast (cpuid-ecx leaf subleaf) : i32))

;: Return CPUID EDX for `leaf` and `subleaf`.
(define (cpuid-edx32 [leaf : i64] [subleaf : i64]) : i32
  (cast (cpuid-edx leaf subleaf) : i32))

;: Return CPUID registers for `leaf` and `subleaf` as (eax ebx ecx edx).
(define (cpuid [leaf : i64] [subleaf : i64]) : (Tuple i32 i32 i32 i32)
  (tuple
    (cpuid-eax32 leaf subleaf)
    (cpuid-ebx32 leaf subleaf)
    (cpuid-ecx32 leaf subleaf)
    (cpuid-edx32 leaf subleaf)))

;: CPUID.1:ECX bit 27 = OSXSAVE: the OS enabled XSAVE and the XGETBV instruction.
(define (osxsave?) : bool
  (let
    [r1 : (Tuple i32 i32 i32 i32) (cpuid 1 0)]
    (= (bit-and (shr (cast (tuple-ref r1 2) : i64) 27) 1) 1)))

;: XCR0 (XGETBV index 0). Reading XCR0 is only valid once OSXSAVE is set, so
;: return 0 otherwise (matching the C probe's `osxsave ? xgetbv0() : 0`).
(define (xcr0) : i64
  (if (osxsave?)
    (xgetbv 0)
    0))

;: Highest standard CPUID leaf (CPUID.0:EAX). Leaf 7 carries the AVX2 and
;: AVX-512 feature bits, so it must be available before they are queried.
(define (max-leaf) : i64
  (let
    [r0 : (Tuple i32 i32 i32 i32) (cpuid 0 0)]
    (cast (tuple-ref r0 0) : i64)))

;: XCR0 bit1 = SSE/XMM, bit2 = AVX/YMM. 0x6 means YMM state is enabled.
(define (ymm-enabled?) : bool
  (= (bit-and (xcr0) 0x6) 0x6))

;: XCR0 0xe6 = SSE | AVX | opmask | ZMM_Hi256 | Hi16_ZMM: ZMM state is enabled.
(define (zmm-enabled?) : bool
  (= (bit-and (xcr0) 0xe6) 0xe6))

;: CPUID.7.0:EBX bit 5 = AVX2.
(define (has-avx2?) : bool
  (if (>= (max-leaf) 7)
    (let
      [r7 : (Tuple i32 i32 i32 i32) (cpuid 7 0)]
      (= (bit-and (shr (cast (tuple-ref r7 1) : i64) 5) 1) 1))
    false))

;: CPUID.7.0:EBX bit 16 = AVX512F.
(define (has-avx512f?) : bool
  (if (>= (max-leaf) 7)
    (let
      [r7 : (Tuple i32 i32 i32 i32) (cpuid 7 0)]
      (= (bit-and (shr (cast (tuple-ref r7 1) : i64) 16) 1) 1))
    false))

;: CPUID.7.0:EBX bit 17 = AVX512DQ.
(define (has-avx512dq?) : bool
  (if (>= (max-leaf) 7)
    (let
      [r7 : (Tuple i32 i32 i32 i32) (cpuid 7 0)]
      (= (bit-and (shr (cast (tuple-ref r7 1) : i64) 17) 1) 1))
    false))

;: CPUID.7.0:EBX bit 30 = AVX512BW.
(define (has-avx512bw?) : bool
  (if (>= (max-leaf) 7)
    (let
      [r7 : (Tuple i32 i32 i32 i32) (cpuid 7 0)]
      (= (bit-and (shr (cast (tuple-ref r7 1) : i64) 30) 1) 1))
    false))

;: AVX2 is runnable when the CPU advertises it and the OS has enabled YMM state.
(define (runs-avx2?) : bool
  (if (has-avx2?)
    (ymm-enabled?)
    false))

;: AVX-512 Foundation is runnable when advertised and ZMM/opmask state is enabled.
(define (runs-avx512f?) : bool
  (if (has-avx512f?)
    (zmm-enabled?)
    false))

;: AVX-512DQ is runnable when Foundation, DQ, and ZMM/opmask state are enabled.
(define (runs-avx512dq?) : bool
  (if (runs-avx512f?)
    (has-avx512dq?)
    false))

;: AVX-512BW is runnable when Foundation, BW, and ZMM/opmask state are enabled.
(define (runs-avx512bw?) : bool
  (if (runs-avx512f?)
    (has-avx512bw?)
    false))

;: The compiler's AVX-512 backend is runnable only when every extension it may
;: emit is available. DQ is required for i64/u64 `vpmullq`; BW is required for
;: byte/word lane operations.
(define (runs-avx512?) : bool
  (and (runs-avx512bw?) (runs-avx512dq?)))

;: Inline test failure helper.
(define (test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test boolean assertion.
(define (test-assert [ok : bool]) : unit
  (if ok
    unit
    (test-fail)))

(test
  cpu-api
  (begin
    ;; CPUID.0:EAX (max standard leaf) is a small non-negative integer.
    (test-assert (>= (max-leaf) 0))
    ;; "runnable" always implies the underlying CPUID feature bit.
    (test-assert
      (if (runs-avx2?)
        (has-avx2?)
        true))
    (test-assert
      (if (runs-avx512f?)
        (has-avx512f?)
        true))
    (test-assert
      (if (runs-avx512dq?)
        (has-avx512dq?)
        true))
    (test-assert
      (if (runs-avx512bw?)
        (has-avx512bw?)
        true))
    (test-assert
      (if (runs-avx512bw?)
        (runs-avx512f?)
        true))
    (test-assert
      (if (runs-avx512dq?)
        (runs-avx512f?)
        true))
    (test-assert
      (if (runs-avx512?)
        (and (runs-avx512bw?) (runs-avx512dq?))
        true))
    ;; XCR0 ZMM enablement (0xe6) is a superset of YMM enablement (0x6).
    (test-assert
      (if (zmm-enabled?)
        (ymm-enabled?)
        true))
    ;; AVX-512F requires AVX2, so a runnable AVX-512F host is always a runnable
    ;; AVX2 host.
    (test-assert
      (if (runs-avx512f?)
        (runs-avx2?)
        true))
    ;; A runnable ISA requires OS XSAVE enablement.
    (test-assert
      (if (runs-avx2?)
        (osxsave?)
        true))))