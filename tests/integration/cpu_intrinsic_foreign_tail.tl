(import stdlib.cpu)
(import cpu_intrinsic_builtin_provider as provider)

;; These compatible entry definitions are not visible in either imported body.
(define (xgetbv [_index : i64]) : i64
  9)

(define (cpuid [_leaf : i64] [_subleaf : i64]) : (Tuple i32 i32 i32 i32)
  (tuple -1 -1 -1 -1))

(define (main) : i64
  (when
    (cpu.osxsave?)
    (let
      [actual : i64 (provider.xcr-expression)]
      (unless (= (provider.xcr-tail) actual) (return 1))
      (unless (= (cpu.xcr0) actual) (return 2))))
  (let
    [actual : i64 (bit-and (cpuid-eax 0 0) 4294967295)]
    [tail : (Tuple i32 i32 i32 i32) (provider.leaf-tail)]
    (unless
      (= (bit-and (cast (tuple-ref tail 0) : i64) 4294967295) actual)
      (return 3))
    (unless (= (provider.leaf-expression) actual) (return 4)))
  42)
