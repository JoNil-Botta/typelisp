;; compiler_float.tl - Compiler-facing wrappers for deterministic float helpers.
(import "../stdlib/io.tl")

(defenum CompilerFloatMaybeF64
  (CompilerFloatNoF64)
  (CompilerFloatSomeF64 f64))

(define (compiler-float-parse-f64 [text : String]) : CompilerFloatMaybeF64
  (match (io-float-parse-f64 text)
    [(IoFloatSomeF64 value) (CompilerFloatSomeF64 value)]
    [(IoFloatNoF64) (CompilerFloatNoF64)]))

(define (compiler-float-f64-bits [value : f64]) : u64
  (io-float-f64-bits value))

(define (compiler-float-f64-finite? [value : f64]) : bool
  (io-float-f64-finite? value))

(define (compiler-float-round-f32-as-f64 [value : f64]) : f64
  (io-float-round-f32-as-f64 value))

(define (compiler-float-format-f64 [value : f64]) : String
  (io-format-float-core value))

(define (compiler-float-parse-bits-eq? [text : String] [want : u64]) : bool
  (match (compiler-float-parse-f64 text)
    [(CompilerFloatSomeF64 value) (= (compiler-float-f64-bits value) want)]
    [(CompilerFloatNoF64) false]))

(define (compiler-float-self-test) : bool
  (and
    (compiler-float-parse-bits-eq? "0.1" (cast 0x3fb999999999999a : u64))
    (compiler-float-parse-bits-eq?
      "0.10000000000000001"
      (cast 0x3fb999999999999a : u64))
    (compiler-float-parse-bits-eq?
      "0.10000000000000002"
      (cast 0x3fb999999999999b : u64))
    (compiler-float-parse-bits-eq?
      "9007199254740993.0"
      (cast 0x4340000000000000 : u64))
    (compiler-float-parse-bits-eq? "1e+17" (cast 0x4376345785d8a000 : u64))
    (compiler-float-parse-bits-eq? "1e-05" (cast 0x3ee4f8b588e368f1 : u64))
    (compiler-float-parse-bits-eq? "-0" (cast 0x8000000000000000 : u64))
    (match (compiler-float-parse-f64 "not-a-float")
      [(CompilerFloatSomeF64 _) false]
      [(CompilerFloatNoF64) true])))