;; compiler_float.tl - Shared deterministic float helpers for the selfhost
;; compiler. The parser accepts the current source grammar
;; `[-]?[0-9]+\.[0-9]+` plus canonical integer spellings emitted by the
;; compiler float formatter.
(import "../stdlib/core_macros.tl" module stdlib.core_macros as core)

(import "../stdlib/io.tl")

(import "../stdlib/string.tl")

(defenum CompilerFloatMaybeF64
  (CompilerFloatNoF64)
  (CompilerFloatSomeF64 f64))

(defenum CompilerFloatMaybeDecimal
  (CompilerFloatNoDecimal)
  (CompilerFloatSomeDecimal bool BigNum i64))

(define (compiler-float-decimal-digit? [c : char]) : bool
  (and (>= c #0') (<= c #9')))

(define (compiler-float-decimal-digit-value [c : char]) : i64
  (- (cast c : i64) (cast #0' : i64)))

(define (compiler-float-exponent-char? [c : char]) : bool
  (or (= c #e') (= c #E')))

(define (compiler-float-bn-append-digit [value : BigNum] [digit : i64]) : BigNum
  (bn-add (bn-mul-u32 value (cast 10 : u64)) (bn-from-u64 (cast digit : u64))))

(define (compiler-float-parse-decimal [text : String]) : CompilerFloatMaybeDecimal
  (let
    [n : i64 (string-length text)]
    [index : i64 0]
    [negative : bool false]
    [significand : BigNum (bn-zero)]
    [int-digits : i64 0]
    [frac-digits : i64 0]
    [exp-negative : bool false]
    [exp-value : i64 0]
    [exp-digits : i64 0]
    (if (= n 0)
      (CompilerFloatNoDecimal)
      (begin
        (if (= (string-ref text 0) #-')
          (begin
            (set! negative true)
            (set! index 1))
          unit)
        (while (and
          (< index n)
          (compiler-float-decimal-digit? (string-ref text index)))
          (let
            [digit : i64
              (compiler-float-decimal-digit-value (string-ref text index))]
            (begin
              (set!
                significand
                (compiler-float-bn-append-digit significand digit))
              (set! int-digits (+ int-digits 1))
              (set! index (+ index 1)))))
        (core/cond
          (= (+ int-digits frac-digits) 0)
          (CompilerFloatNoDecimal)
          (= index n)
          (CompilerFloatSomeDecimal negative significand 0)
          (= (string-ref text index) #.')
          (begin
            (set! index (+ index 1))
            (while (and
              (< index n)
              (compiler-float-decimal-digit? (string-ref text index)))
              (let
                [digit : i64
                  (compiler-float-decimal-digit-value (string-ref text index))]
                (begin
                  (set!
                    significand
                    (compiler-float-bn-append-digit significand digit))
                  (set! frac-digits (+ frac-digits 1))
                  (set! index (+ index 1)))))
            (if (= frac-digits 0)
              (CompilerFloatNoDecimal)
              (begin
                (if (and
                  (< index n)
                  (compiler-float-exponent-char? (string-ref text index)))
                  (begin
                    (set! index (+ index 1))
                    (if (and (< index n) (= (string-ref text index) #-'))
                      (begin
                        (set! exp-negative true)
                        (set! index (+ index 1)))
                      (if (and (< index n) (= (string-ref text index) #+'))
                        (set! index (+ index 1))
                        unit))
                    (while (and
                      (< index n)
                      (compiler-float-decimal-digit? (string-ref text index)))
                      (let
                        [digit : i64
                          (compiler-float-decimal-digit-value
                            (string-ref text index))]
                        (begin
                          (when
                            (< exp-value 4000)
                            (set! exp-value (+ (* exp-value 10) digit)))
                          (set! exp-digits (+ exp-digits 1))
                          (set! index (+ index 1)))))
                    (when (= exp-digits 0) (set! index (+ n 1))))
                  unit)
                (if (!= index n)
                  (CompilerFloatNoDecimal)
                  (CompilerFloatSomeDecimal
                    negative
                    significand
                    (-
                      (if exp-negative
                        (- 0 exp-value)
                        exp-value)
                      frac-digits))))))
          (compiler-float-exponent-char? (string-ref text index))
          (begin
            (set! index (+ index 1))
            (if (and (< index n) (= (string-ref text index) #-'))
              (begin
                (set! exp-negative true)
                (set! index (+ index 1)))
              (if (and (< index n) (= (string-ref text index) #+'))
                (set! index (+ index 1))
                unit))
            (while (and
              (< index n)
              (compiler-float-decimal-digit? (string-ref text index)))
              (let
                [digit : i64
                  (compiler-float-decimal-digit-value (string-ref text index))]
                (begin
                  (when
                    (< exp-value 4000)
                    (set! exp-value (+ (* exp-value 10) digit)))
                  (set! exp-digits (+ exp-digits 1))
                  (set! index (+ index 1)))))
            (if (or (= exp-digits 0) (!= index n))
              (CompilerFloatNoDecimal)
              (CompilerFloatSomeDecimal
                negative
                significand
                (if exp-negative
                  (- 0 exp-value)
                  exp-value))))
          (CompilerFloatNoDecimal))))))

(define (compiler-float-bn-bit-length [value : BigNum]) : i64
  (let
    [len : i64 (struct-get value len)]
    (if (= len 0)
      0
      (+
        (* (- len 1) 32)
        (+ (ftoa-msb-index (array-ref (struct-get value limbs) (- len 1))) 1)))))

(define (compiler-float-ratio-floor-log2 [num : BigNum] [den : BigNum]) : i64
  (let
    [estimate : i64
      (- (compiler-float-bn-bit-length num) (compiler-float-bn-bit-length den))]
    [ok : bool
      (if (>= estimate 0)
        (>= (bn-cmp num (bn-shl-bits den estimate)) 0)
        (>= (bn-cmp (bn-shl-bits num (- 0 estimate)) den) 0))]
    (if ok
      estimate
      (- estimate 1))))

(define (compiler-float-round-div-u64 [num : BigNum] [den : BigNum]) : u64
  (let
    [q : u64 (bn-div-floor-u64 num den)]
    [twice-num : BigNum (bn-shl-bits num 1)]
    [mid : BigNum (bn-mul-u64 den (+ (* (cast 2 : u64) q) (cast 1 : u64)))]
    [cmp : i64 (bn-cmp twice-num mid)]
    (core/cond
      (> cmp 0)
      (+ q (cast 1 : u64))
      (= cmp 0)
      (if (= (bit-and q (cast 1 : u64)) (cast 1 : u64))
        (+ q (cast 1 : u64))
        q)
      q)))

(define (compiler-float-round-scaled-u64
  [num : BigNum]
  [den : BigNum]
  [shift : i64]) : u64
  (if (>= shift 0)
    (compiler-float-round-div-u64 (bn-shl-bits num shift) den)
    (compiler-float-round-div-u64 num (bn-shl-bits den (- 0 shift)))))

(define (compiler-float-f64-from-bits [bits : u64]) : f64
  (let
    [buf : (Array u64) (make-array u64 1)]
    (begin
      (array-set! buf 0 bits)
      (unsafe
        (ptr-read (ptr-cast (array-data buf) : (Ptr f64)))))))

(define (compiler-float-decimal-to-f64
  [negative : bool]
  [significand : BigNum]
  [decimal-exp : i64]) : CompilerFloatMaybeF64
  (let
    [sign-bit : u64
      (if negative
        (cast 0x8000000000000000 : u64)
        (cast 0 : u64))]
    [num : BigNum significand]
    [den : BigNum (bn-from-u64 (cast 1 : u64))]
    (if (= (struct-get num len) 0)
      (CompilerFloatSomeF64 (compiler-float-f64-from-bits sign-bit))
      (begin
        (if (>= decimal-exp 0)
          (set! num (bn-mul-pow10 num decimal-exp))
          (set! den (bn-mul-pow10 den (- 0 decimal-exp))))
        (let
          [e : i64 (compiler-float-ratio-floor-log2 num den)]
          [two52 : u64 (cast 0x10000000000000 : u64)]
          [two53 : u64 (cast 0x20000000000000 : u64)]
          (core/cond
            (> e 1023)
            (CompilerFloatNoF64)
            (>= e -1022)
            (let
              [m0 : u64 (compiler-float-round-scaled-u64 num den (- 52 e))]
              [m : u64 m0]
              [exp : i64 e]
              (begin
                (when
                  (= m two53)
                  (begin
                    (set! m two52)
                    (set! exp (+ exp 1))))
                (if (> exp 1023)
                  (CompilerFloatNoF64)
                  (CompilerFloatSomeF64
                    (compiler-float-f64-from-bits
                      (bit-or
                        sign-bit
                        (bit-or (shl (cast (+ exp 1023) : u64) 52) (- m two52))))))))
            (let
              [m : u64 (compiler-float-round-scaled-u64 num den 1074)]
              (if (= m (cast 0 : u64))
                (CompilerFloatSomeF64 (compiler-float-f64-from-bits sign-bit))
                (if (>= m two52)
                  (CompilerFloatSomeF64
                    (compiler-float-f64-from-bits
                      (bit-or sign-bit (shl (cast 1 : u64) 52))))
                  (CompilerFloatSomeF64
                    (compiler-float-f64-from-bits (bit-or sign-bit m))))))))))))

(define (compiler-float-parse-f64 [text : String]) : CompilerFloatMaybeF64
  (match (compiler-float-parse-decimal text)
    [(CompilerFloatSomeDecimal negative significand decimal-exp)
      (compiler-float-decimal-to-f64 negative significand decimal-exp)]
    [(CompilerFloatNoDecimal) (CompilerFloatNoF64)]))

(define (compiler-float-f64-bits [value : f64]) : u64
  (let
    [buf : (Array f64) (make-array f64 1)]
    [bits : u64 (cast 0 : u64)]
    (begin
      (array-set! buf 0 value)
      (set!
        bits
        (unsafe
          (ptr-read (ptr-cast (array-data buf) : (Ptr u64)))))
      bits)))

(define (compiler-float-f64-finite? [value : f64]) : bool
  (let
    [bits : u64 (compiler-float-f64-bits value)]
    [expf : u64 (bit-and (shr bits 52) (cast 0x7ff : u64))]
    (not (= expf (cast 0x7ff : u64)))))

(define (compiler-float-round-f32-as-f64 [value : f64]) : f64
  (cast (cast value : f32) : f64))

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