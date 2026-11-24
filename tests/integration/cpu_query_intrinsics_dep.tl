(define (hardware-queries-ok?) : bool
  (let
    [registers (cpuid 0 0)]
    [osxsave (bit-and (cpuid-ecx 1 0) (shl 1 27))]
    (and
      (= (cpuid-eax 0 0) (cast (cast (tuple-ref registers 0) : u32) : i64))
      (= (cpuid-ebx 0 0) (cast (cast (tuple-ref registers 1) : u32) : i64))
      (= (cpuid-ecx 0 0) (cast (cast (tuple-ref registers 2) : u32) : i64))
      (= (cpuid-edx 0 0) (cast (cast (tuple-ref registers 3) : u32) : i64))
      (or (= osxsave 0) (= (bit-and (xgetbv (cast 0 : i32)) 1) 1)))))

(define (imported-query) : i64
  9)