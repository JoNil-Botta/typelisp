;; compiler_float.tl - Compiler-facing wrappers for deterministic float helpers.
(import "../stdlib/io.tl")
(import "compiler_ast_types.tl")

(defenum CompilerFloatMaybeF64
  (CompilerFloatNoF64)
  (CompilerFloatSomeF64 f64))

(defenum CompilerFloatMaybeBits
  (CompilerFloatNoBits)
  (CompilerFloatSomeBits u64))

(defenum CompilerFiniteCastInput
  (CompilerFiniteCastNoInput)
  (CompilerFiniteCastInputI64 i64)
  (CompilerFiniteCastInputChar char)
  (CompilerFiniteCastInputF64 f64)
  (CompilerFiniteCastInputF32 f64))

(defenum CompilerFiniteCastMaybeI64
  (CompilerFiniteCastNoI64)
  (CompilerFiniteCastSomeI64 i64))

(defenum CompilerFiniteCastResult
  (CompilerFiniteCastNoResult)
  (CompilerFiniteCastResultI64 i64)
  (CompilerFiniteCastResultChar char)
  (CompilerFiniteCastResultF64 f64)
  (CompilerFiniteCastResultF32 f64))

(define (compiler-float-parse-f64 [text : String]) : CompilerFloatMaybeF64
  (match (io-float-parse-f64 text)
    [(IoFloatSomeF64 value) (CompilerFloatSomeF64 value)]
    [(IoFloatNoF64) (CompilerFloatNoF64)]))

(define (compiler-float-f64-from-bits [bits : u64]) : f64
  (io-float-f64-from-bits bits))

(define (compiler-float-f64-bits [value : f64]) : u64
  (io-float-f64-bits value))

(define (compiler-float-f32-from-bits [bits : u32]) : f32
  (let
    [buf : (Array u32) (make-array u32 1)]
    (begin
      (array-set! buf 0 bits)
      (unsafe
        (ptr-read (ptr-cast (array-data buf) : (Ptr f32)))))))

(define (compiler-float-f32-bits [value : f32]) : u32
  (io-float-f32-bits value))

(define (compiler-float-f32-bits-from-f64 [value : f64]) : u32
  (compiler-float-f32-bits (cast value : f32)))

(define (compiler-float-f32-bits-to-f64 [bits : u64]) : f64
  (cast (compiler-float-f32-from-bits (cast bits : u32)) : f64))

(define (compiler-float-f64-finite? [value : f64]) : bool
  (io-float-f64-finite? value))

(define (compiler-float-round-f32-as-f64 [value : f64]) : f64
  (io-float-round-f32-as-f64 value))

(define (compiler-finite-cast-integer-type? [ty : AstType]) : bool
  (match ty
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyI16) true]
    [(AstTyI8) true]
    [(AstTyU64) true]
    [(AstTyU32) true]
    [(AstTyU16) true]
    [(AstTyU8) true]
    [_ false]))

(define (compiler-finite-cast-int-or-char-type? [ty : AstType]) : bool
  (if (compiler-finite-cast-integer-type? ty)
    true
    (match ty
      [(AstTyChar) true]
      [_ false])))

(define (compiler-finite-cast-float-type? [ty : AstType]) : bool
  (match ty
    [(AstTyF64) true]
    [(AstTyF32) true]
    [_ false]))

(define (compiler-finite-cast-normalize-i64 [value : i64] [ty : AstType]) : i64
  (match ty
    [(AstTyI64) (cast (cast value : i64) : i64)]
    [(AstTyI32) (cast (cast value : i32) : i64)]
    [(AstTyI16) (cast (cast value : i16) : i64)]
    [(AstTyI8) (cast (cast value : i8) : i64)]
    [(AstTyU64) (cast (cast value : u64) : i64)]
    [(AstTyU32) (cast (cast value : u32) : i64)]
    [(AstTyU16) (cast (cast value : u16) : i64)]
    [(AstTyU8) (cast (cast value : u8) : i64)]
    [(AstTyChar) (cast (cast value : char) : i64)]
    [_ value]))

(define (compiler-finite-cast-input-to-i64
  [input : CompilerFiniteCastInput]
  [from-ty : AstType]) : CompilerFiniteCastMaybeI64
  (if (compiler-finite-cast-int-or-char-type? from-ty)
    (match input
      [(CompilerFiniteCastInputI64 value)
        (CompilerFiniteCastSomeI64
          (compiler-finite-cast-normalize-i64 value from-ty))]
      [(CompilerFiniteCastInputChar value)
        (CompilerFiniteCastSomeI64
          (compiler-finite-cast-normalize-i64 (cast value : i64) from-ty))]
      [_ (CompilerFiniteCastNoI64)])
    (CompilerFiniteCastNoI64)))

(define (compiler-finite-cast-input-to-f64
  [input : CompilerFiniteCastInput]
  [from-ty : AstType]) : CompilerFloatMaybeF64
  (match from-ty
    [(AstTyF64)
      (match input
        [(CompilerFiniteCastInputF64 value)
          (if (compiler-float-f64-finite? value)
            (CompilerFloatSomeF64 value)
            (CompilerFloatNoF64))]
        [_ (CompilerFloatNoF64)])]
    [(AstTyF32)
      (match input
        [(CompilerFiniteCastInputF32 value)
          (let
            [rounded : f64 (compiler-float-round-f32-as-f64 value)]
            (if (compiler-float-f64-finite? rounded)
              (CompilerFloatSomeF64 rounded)
              (CompilerFloatNoF64)))]
        [_ (CompilerFloatNoF64)])]
    [_ (CompilerFloatNoF64)]))

(define (compiler-finite-cast-int-to-f64 [value : i64] [from-ty : AstType]) : f64
  (match from-ty
    [(AstTyU64) (cast (cast value : u64) : f64)]
    [(AstTyU32) (cast (cast value : u32) : f64)]
    [(AstTyU16) (cast (cast value : u16) : f64)]
    [(AstTyU8) (cast (cast value : u8) : f64)]
    [(AstTyChar) (cast (cast value : char) : f64)]
    [_ (cast value : f64)]))

(define (compiler-finite-cast-int-to-float-result
  [value : i64]
  [from-ty : AstType]
  [to-ty : AstType]) : CompilerFiniteCastResult
  (let
    [as-f64 : f64 (compiler-finite-cast-int-to-f64 value from-ty)]
    (match to-ty
      [(AstTyF64)
        (if (compiler-float-f64-finite? as-f64)
          (CompilerFiniteCastResultF64 as-f64)
          (CompilerFiniteCastNoResult))]
      [(AstTyF32)
        (let
          [rounded : f64 (compiler-float-round-f32-as-f64 as-f64)]
          (if (compiler-float-f64-finite? rounded)
            (CompilerFiniteCastResultF32 rounded)
            (CompilerFiniteCastNoResult)))]
      [_ (CompilerFiniteCastNoResult)])))

(define (compiler-finite-cast-signed-min [ty : AstType]) : f64
  (match ty
    [(AstTyI64) -9223372036854775808.0]
    [(AstTyI32) -2147483648.0]
    [(AstTyI16) -32768.0]
    [(AstTyI8) -128.0]
    [_ 0.0]))

(define (compiler-finite-cast-signed-max-exclusive [ty : AstType]) : f64
  (match ty
    [(AstTyI64) 9223372036854775808.0]
    [(AstTyI32) 2147483648.0]
    [(AstTyI16) 32768.0]
    [(AstTyI8) 128.0]
    [_ 0.0]))

(define (compiler-finite-cast-unsigned-max-exclusive [ty : AstType]) : f64
  (match ty
    ;; Runtime float-to-int lowering converts through the signed 64-bit path
    ;; before typed storage, so high u64 float results stay runtime-only.
    [(AstTyU64) 9223372036854775808.0]
    [(AstTyU32) 4294967296.0]
    [(AstTyU16) 65536.0]
    [(AstTyU8) 256.0]
    [(AstTyChar) 256.0]
    [_ 0.0]))

(define (compiler-finite-cast-signed-target? [ty : AstType]) : bool
  (match ty
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyI16) true]
    [(AstTyI8) true]
    [_ false]))

(define (compiler-finite-cast-unsigned-target? [ty : AstType]) : bool
  (match ty
    [(AstTyU64) true]
    [(AstTyU32) true]
    [(AstTyU16) true]
    [(AstTyU8) true]
    [(AstTyChar) true]
    [_ false]))

(define (compiler-finite-cast-float-in-target-range?
  [value : f64]
  [to-ty : AstType]) : bool
  (cond
    [(not (compiler-float-f64-finite? value)) false]
    [(compiler-finite-cast-signed-target? to-ty)
      (and
        (>= value (compiler-finite-cast-signed-min to-ty))
        (< value (compiler-finite-cast-signed-max-exclusive to-ty)))]
    [(compiler-finite-cast-unsigned-target? to-ty)
      (and
        (>= value 0.0)
        (< value (compiler-finite-cast-unsigned-max-exclusive to-ty)))]
    [else false]))

(define (compiler-finite-cast-float-to-int-result
  [value : f64]
  [to-ty : AstType]) : CompilerFiniteCastResult
  (if (not (compiler-finite-cast-float-in-target-range? value to-ty))
    (CompilerFiniteCastNoResult)
    (match to-ty
      [(AstTyI64) (CompilerFiniteCastResultI64 (cast (cast value : i64) : i64))]
      [(AstTyI32) (CompilerFiniteCastResultI64 (cast (cast value : i32) : i64))]
      [(AstTyI16) (CompilerFiniteCastResultI64 (cast (cast value : i16) : i64))]
      [(AstTyI8) (CompilerFiniteCastResultI64 (cast (cast value : i8) : i64))]
      [(AstTyU64) (CompilerFiniteCastResultI64 (cast (cast value : u64) : i64))]
      [(AstTyU32) (CompilerFiniteCastResultI64 (cast (cast value : u32) : i64))]
      [(AstTyU16) (CompilerFiniteCastResultI64 (cast (cast value : u16) : i64))]
      [(AstTyU8) (CompilerFiniteCastResultI64 (cast (cast value : u8) : i64))]
      [(AstTyChar)
        (CompilerFiniteCastResultChar (cast (cast value : u8) : char))]
      [_ (CompilerFiniteCastNoResult)])))

(define (compiler-finite-cast-float-to-float-result
  [value : f64]
  [to-ty : AstType]) : CompilerFiniteCastResult
  (match to-ty
    [(AstTyF64)
      (if (compiler-float-f64-finite? value)
        (CompilerFiniteCastResultF64 value)
        (CompilerFiniteCastNoResult))]
    [(AstTyF32)
      (let
        [rounded : f64 (compiler-float-round-f32-as-f64 value)]
        (if (compiler-float-f64-finite? rounded)
          (CompilerFiniteCastResultF32 rounded)
          (CompilerFiniteCastNoResult)))]
    [_ (CompilerFiniteCastNoResult)]))

(define (compiler-finite-cast-int-to-int-result [value : i64] [to-ty : AstType]) : CompilerFiniteCastResult
  (match to-ty
    [(AstTyChar)
      (CompilerFiniteCastResultChar
        (cast (compiler-finite-cast-normalize-i64 value to-ty) : char))]
    [_
      (if (compiler-finite-cast-integer-type? to-ty)
        (CompilerFiniteCastResultI64
          (compiler-finite-cast-normalize-i64 value to-ty))
        (CompilerFiniteCastNoResult))]))

(define (compiler-finite-cast-fold
  [input : CompilerFiniteCastInput]
  [from-ty : AstType]
  [to-ty : AstType]) : CompilerFiniteCastResult
  (if (compiler-finite-cast-int-or-char-type? from-ty)
    (match (compiler-finite-cast-input-to-i64 input from-ty)
      [(CompilerFiniteCastSomeI64 n)
        (if (compiler-finite-cast-int-or-char-type? to-ty)
          (compiler-finite-cast-int-to-int-result n to-ty)
          (if (compiler-finite-cast-float-type? to-ty)
            (compiler-finite-cast-int-to-float-result n from-ty to-ty)
            (CompilerFiniteCastNoResult)))]
      [(CompilerFiniteCastNoI64) (CompilerFiniteCastNoResult)])
    (if (compiler-finite-cast-float-type? from-ty)
      (match (compiler-finite-cast-input-to-f64 input from-ty)
        [(CompilerFloatSomeF64 n)
          (if (compiler-finite-cast-int-or-char-type? to-ty)
            (compiler-finite-cast-float-to-int-result n to-ty)
            (if (compiler-finite-cast-float-type? to-ty)
              (compiler-finite-cast-float-to-float-result n to-ty)
              (CompilerFiniteCastNoResult)))]
        [(CompilerFloatNoF64) (CompilerFiniteCastNoResult)])
      (CompilerFiniteCastNoResult))))

(define (compiler-float-format-f64 [value : f64]) : String
  (io-format-float-core value))

(define (compiler-float-parse-f64-bits [text : String]) : CompilerFloatMaybeBits
  (match (compiler-float-parse-f64 text)
    [(CompilerFloatSomeF64 value)
      (if (compiler-float-f64-finite? value)
        (CompilerFloatSomeBits (compiler-float-f64-bits value))
        (CompilerFloatNoBits))]
    [(CompilerFloatNoF64) (CompilerFloatNoBits)]))

(define (compiler-float-parse-f32-bits [text : String]) : CompilerFloatMaybeBits
  (match (compiler-float-parse-f64 text)
    [(CompilerFloatSomeF64 value)
      (let
        [rounded : f64 (compiler-float-round-f32-as-f64 value)]
        (if (compiler-float-f64-finite? rounded)
          (CompilerFloatSomeBits
            (cast (compiler-float-f32-bits-from-f64 rounded) : u64))
          (CompilerFloatNoBits)))]
    [(CompilerFloatNoF64) (CompilerFloatNoBits)]))

(define (compiler-float-parse-bits-eq? [text : String] [want : u64]) : bool
  (match (compiler-float-parse-f64-bits text)
    [(CompilerFloatSomeBits bits) (= bits want)]
    [(CompilerFloatNoBits) false]))

(define (compiler-float-parse-f32-bits-eq? [text : String] [want : u64]) : bool
  (match (compiler-float-parse-f32-bits text)
    [(CompilerFloatSomeBits bits) (= bits want)]
    [(CompilerFloatNoBits) false]))

(define (compiler-float-self-test) : bool
  (and
    (compiler-float-parse-bits-eq? "0.1" 0x3fb999999999999a)
    (compiler-float-parse-bits-eq? "0.10000000000000001" 0x3fb999999999999a)
    (compiler-float-parse-bits-eq? "0.10000000000000002" 0x3fb999999999999b)
    (compiler-float-parse-bits-eq? "9007199254740993.0" 0x4340000000000000)
    (compiler-float-parse-bits-eq? "1e+17" 0x4376345785d8a000)
    (compiler-float-parse-bits-eq? "1e-05" 0x3ee4f8b588e368f1)
    (compiler-float-parse-bits-eq? "-0" (shl (cast 1 : u64) 63))
    (compiler-float-parse-f32-bits-eq? "1.0" 0x3f800000)
    (compiler-float-parse-f32-bits-eq? "0.1" 0x3dcccccd)
    (compiler-float-parse-f32-bits-eq? "0.10000000149011612" 0x3dcccccd)
    (compiler-float-parse-f32-bits-eq? "-0" 0x80000000)
    (match (compiler-float-parse-f64 "not-a-float")
      [(CompilerFloatSomeF64 _) false]
      [(CompilerFloatNoF64) true])))