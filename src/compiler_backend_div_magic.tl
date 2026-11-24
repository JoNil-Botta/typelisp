(defenum CompilerBackendUnsignedDivMagic
  (No)
  (RoundUp u64 i64)
  (RoundDown u64 i64))

(defstruct CompilerBackendU64DivPow2
  (quot u64)
  (rem u64)
  (overflow bool))

(defstruct CompilerBackendSignedDivMagic
  (magic u64)
  (shift i64))

(define (compiler-backend-u64-max) : u64
  (cast (- 0 1) : u64))

(define (compiler-backend-u64-div-pow2 [bits : i64] [divisor : u64]) : CompilerBackendU64DivPow2
  (let
    [i : i64 bits]
    [quot : u64 (cast 0 : u64)]
    [rem : u64 (cast 0 : u64)]
    [overflow : bool false]
    (while (>= i 0)
      (set! rem (* rem (cast 2 : u64)))
      (if (= i bits)
        (+= rem (cast 1 : u64))
        unit)
      (when
        (>= rem divisor)
        (-= rem divisor)
        (if (>= i 64)
          (set! overflow true)
          (set! quot (bit-or quot (shl (cast 1 : u64) i)))))
      (-= i 1))
    (CompilerBackendU64DivPow2 quot rem overflow)))

(define (compiler-backend-unsigned-divisor-round-up-magic [divisor : u64]) : CompilerBackendUnsignedDivMagic
  (let
    [shift : i64 0]
    [done : bool false]
    [out : CompilerBackendUnsignedDivMagic (No)]
    (while (and (not done) (< shift 64))
      (let
        [pow : CompilerBackendU64DivPow2
          (compiler-backend-u64-div-pow2 (+ 64 shift) divisor)]
        [quot : u64 pow.quot]
        [rem : u64 pow.rem]
        [overflow : bool pow.overflow]
        [limit : u64 (shl (cast 1 : u64) shift)]
        [error : u64
          (if (= rem (cast 0 : u64))
            (cast 0 : u64)
            (- divisor rem))]
        [needs-inc : bool (not (= rem (cast 0 : u64)))]
        [inc-overflow : bool
          (and needs-inc (= quot (compiler-backend-u64-max)))]
        (when
          (and (not overflow) (not inc-overflow) (< error limit))
          (set!
            out
            (RoundUp
              (if needs-inc
                (+ quot (cast 1 : u64))
                quot)
              shift))
          (set! done true))
        (+= shift 1)))
    out))

(define (compiler-backend-unsigned-divisor-round-down-magic [divisor : u64]) : CompilerBackendUnsignedDivMagic
  (let
    [shift : i64 0]
    [done : bool false]
    [out : CompilerBackendUnsignedDivMagic (No)]
    (while (and (not done) (< shift 64))
      (let
        [pow : CompilerBackendU64DivPow2
          (compiler-backend-u64-div-pow2 (+ 64 shift) divisor)]
        [quot : u64 pow.quot]
        [rem : u64 pow.rem]
        [overflow : bool pow.overflow]
        [limit : u64 (shl (cast 1 : u64) shift)]
        (when
          (and (not overflow) (<= rem limit))
          (set! out (RoundDown quot shift))
          (set! done true))
        (+= shift 1)))
    out))

(define (compiler-backend-unsigned-divisor-magic [divisor : u64]) : CompilerBackendUnsignedDivMagic
  (match (compiler-backend-unsigned-divisor-round-up-magic divisor)
    [(No) (compiler-backend-unsigned-divisor-round-down-magic divisor)]
    [(RoundUp magic shift) (RoundUp magic shift)]
    [(RoundDown magic shift) (RoundDown magic shift)]))

(define (compiler-backend-signed-divisor-magic [divisor : i64]) : CompilerBackendSignedDivMagic
  (let
    [ad : u64 (cast divisor : u64)]
    [two63 : u64 (shl (cast 1 : u64) 63)]
    [anc : u64 (- (- two63 (cast 1 : u64)) (% two63 ad))]
    [p : i64 63]
    [q1 : u64 (/ two63 anc)]
    [r1 : u64 (- two63 (* q1 anc))]
    [q2 : u64 (/ two63 ad)]
    [r2 : u64 (- two63 (* q2 ad))]
    [done : bool false]
    (while (not done)
      (+= p 1)
      (set! q1 (* q1 (cast 2 : u64)))
      (set! r1 (* r1 (cast 2 : u64)))
      (when (>= r1 anc) (+= q1 (cast 1 : u64)) (-= r1 anc))
      (set! q2 (* q2 (cast 2 : u64)))
      (set! r2 (* r2 (cast 2 : u64)))
      (when (>= r2 ad) (+= q2 (cast 1 : u64)) (-= r2 ad))
      (let
        [delta : u64 (- ad r2)]
        (if (or (< q1 delta) (and (= q1 delta) (= r1 (cast 0 : u64))))
          unit
          (set! done true))))
    (CompilerBackendSignedDivMagic (+ q2 (cast 1 : u64)) (- p 64))))

;; True when a positive signed i64 divisor lowers more cheaply as unsigned u64
;; than signed i64: powers of two (single shift/mask) and divisors whose
;; unsigned magic takes the RoundUp form (`mulq; shrq` with no `addq; adcq`
;; overflow correction and no signed `sarq $63; addq` truncation fixup).
(define (compiler-backend-unsigned-divmod-profitable? [divisor : i64]) : bool
  (if (<= divisor 0)
    false
    (let
      [d : u64 (cast divisor : u64)]
      (if (= (bit-and d (- d (cast 1 : u64))) (cast 0 : u64))
        true
        (match (compiler-backend-unsigned-divisor-magic d)
          [(RoundUp _ _) true]
          [_ false])))))